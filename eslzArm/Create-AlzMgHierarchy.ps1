#Requires -Version 5.1
<#
.SYNOPSIS
    Pre-creates the ALZ management-group hierarchy under an existing top-level MG,
    so the MG-scope eslzArm.json template can be deployed without tenant-root permissions.

.DESCRIPTION
    The fork at https://github.com/mohaom/ALZ-EXManagementGroup deploys at MG scope
    (not tenant scope). ARM validates RBAC on nested deployments before resources are
    created, so newly-created child MGs inside the same deployment fail the pre-auth
    check. Running this script first creates the child MGs so inherited Owner from
    the parent MG applies, and the ARM deployment validates cleanly.

    The MG structure matches eslzArm/managementGroupTemplates/mgmtGroupStructure/mgmtGroups.json:

        <TopLevel>
        ├── <TopLevel>-platform
        │   ├── <TopLevel>-management
        │   ├── <TopLevel>-connectivity
        │   ├── <TopLevel>-identity
        │   └── <TopLevel>-security
        ├── <TopLevel>-landingzones
        │   ├── <TopLevel>-online
        │   └── <TopLevel>-corp
        ├── <TopLevel>-sandboxes
        └── <TopLevel>-decommissioned

.PARAMETER TopLevelManagementGroupPrefix
    Name (ID) of the existing top-level management group under which the ALZ
    hierarchy will be created. Example: TestMG.

.PARAMETER PlatformMgs
    Child MGs under <prefix>-platform. Defaults to the template defaults.

.PARAMETER LandingZoneMgs
    Child MGs under <prefix>-landingzones. Defaults to the template defaults.

.PARAMETER WhatIf
    Show what would be created without making changes.

.EXAMPLE
    ./Create-AlzMgHierarchy.ps1 -TopLevelManagementGroupPrefix TestMG

.EXAMPLE
    ./Create-AlzMgHierarchy.ps1 -TopLevelManagementGroupPrefix Contoso -WhatIf

.NOTES
    Requires: Azure CLI, signed in (az login), Owner (or MG Contributor) on the
    top-level MG. Idempotent — re-running is safe; existing MGs are skipped.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string]$TopLevelManagementGroupPrefix,

    [string[]]$PlatformMgs = @('management', 'connectivity', 'identity', 'security'),

    [string[]]$LandingZoneMgs = @('online', 'corp')
)

$ErrorActionPreference = 'Stop'

function Test-AzCli {
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw 'Azure CLI (az) not found on PATH. Install it from https://aka.ms/azcli and run az login.'
    }
    $acct = az account show 2>$null | ConvertFrom-Json
    if (-not $acct) {
        throw 'Not signed in. Run: az login'
    }
    Write-Host "Signed in as: $($acct.user.name)  (tenant: $($acct.tenantId))" -ForegroundColor DarkGray
}

function Invoke-AzNative {
    # PS 5.1 treats native stderr as terminating under ErrorAction=Stop; isolate it
    # and return captured output + exit code so callers can inspect it.
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & az @Args 2>&1 | Out-String
        $code   = $LASTEXITCODE
        return [pscustomobject]@{ ExitCode = $code; Output = $output }
    }
    finally {
        $ErrorActionPreference = $prevEap
        $global:LASTEXITCODE = 0
    }
}

# Fetches the full descendant tree of a parent MG and returns all descendant
# names as a hashtable for O(1) lookups. Uses 'management-group show --expand
# --recurse' which needs read permission only on the parent (which the caller
# has by definition). Cached once per parent per script run.
$script:DescendantCache = @{}
function Get-DescendantNames {
    param([string]$ParentName)
    if ($script:DescendantCache.ContainsKey($ParentName)) {
        return $script:DescendantCache[$ParentName]
    }
    $names = @{}
    $result = Invoke-AzNative 'account' 'management-group' 'show' `
        '--name' $ParentName `
        '--expand' '--recurse' `
        '--only-show-errors' '-o' 'json'
    if ($result.ExitCode -eq 0 -and $result.Output) {
        try {
            $obj = $result.Output | ConvertFrom-Json
            # Walk children recursively.
            function Walk($node, $acc) {
                if ($null -ne $node.children) {
                    foreach ($c in $node.children) {
                        $acc[$c.name] = $true
                        Walk $c $acc
                    }
                }
            }
            Walk $obj $names
        } catch {
            # Fall through — return empty set so caller falls back to create+tolerate.
        }
    }
    $script:DescendantCache[$ParentName] = $names
    return $names
}

function Test-MgExistsUnder {
    param([string]$Name, [string]$TopLevelParent)
    $tree = Get-DescendantNames -ParentName $TopLevelParent
    return $tree.ContainsKey($Name)
}

function New-MgIfMissing {
    param(
        [string]$Name,
        [string]$ParentName,
        [int]$MaxAttempts = 8,
        [int]$InitialDelaySeconds = 5
    )
    $parentId = "/providers/Microsoft.Management/managementGroups/$ParentName"

    # Fast-path: if the MG already exists in the top-level's descendant tree, skip.
    if ($script:TopLevelMgName -and (Test-MgExistsUnder -Name $Name -TopLevelParent $script:TopLevelMgName)) {
        Write-Host "  [skip]   $Name already exists" -ForegroundColor DarkGray
        return
    }

    if (-not $PSCmdlet.ShouldProcess($Name, "Create MG under $ParentName")) {
        return
    }

    $delay = $InitialDelaySeconds
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $result = Invoke-AzNative 'account' 'management-group' 'create' `
            '--name' $Name `
            '--display-name' $Name `
            '--parent' $parentId `
            '--only-show-errors'

        if ($result.ExitCode -eq 0) {
            Write-Host "  [create] $Name under $ParentName" -ForegroundColor Green
            # Add to cache so later siblings/children don't re-query.
            if ($script:TopLevelMgName -and $script:DescendantCache.ContainsKey($script:TopLevelMgName)) {
                $script:DescendantCache[$script:TopLevelMgName][$Name] = $true
            }
            return
        }
        # Tolerate already-exists (idempotency).
        if ($result.Output -match 'already exists|Conflict|409') {
            Write-Host "  [skip]   $Name already exists" -ForegroundColor DarkGray
            if ($script:TopLevelMgName -and $script:DescendantCache.ContainsKey($script:TopLevelMgName)) {
                $script:DescendantCache[$script:TopLevelMgName][$Name] = $true
            }
            return
        }
        # Retry transient auth / not-found errors - Azure auth caches lag behind
        # MG tree changes, so a parent we just created may not be visible for
        # a few seconds.
        $transient = $result.Output -match 'AuthorizationFailed|scope is invalid|NotFound|does not exist|ParentNotFound|could not be found'
        if ($transient -and $attempt -lt $MaxAttempts) {
            $waitMsg = "  [retry]  {0} (attempt {1}/{2}, waiting {3}s - auth/tree cache lag)" -f $Name, $attempt, $MaxAttempts, $delay
            Write-Host $waitMsg -ForegroundColor Yellow
            Start-Sleep -Seconds $delay
            if ($delay -lt 40) { $delay = [Math]::Min(40, [int]($delay * 1.7)) }
            continue
        }
        Write-Host $result.Output -ForegroundColor Red
        throw "Failed to create management group '$Name' (exit $($result.ExitCode)) after $attempt attempt(s)."
    }
}

Test-AzCli

# Pre-read the existing descendant tree so already-created MGs are skipped
# instantly on re-runs (avoids waiting on create API + retry backoff just to
# discover a 409). If this fails (parent missing / no read perm), we proceed
# and let the create calls surface the real error.
$script:TopLevelMgName = $TopLevelManagementGroupPrefix
$null = Get-DescendantNames -ParentName $TopLevelManagementGroupPrefix

Write-Host ""
Write-Host "Creating ALZ hierarchy under: $TopLevelManagementGroupPrefix" -ForegroundColor Cyan
Write-Host "----------------------------------------------------------"

$platformMg       = "$TopLevelManagementGroupPrefix-platform"
$landingZonesMg   = "$TopLevelManagementGroupPrefix-landingzones"
$sandboxesMg      = "$TopLevelManagementGroupPrefix-sandboxes"
$decommissionedMg = "$TopLevelManagementGroupPrefix-decommissioned"

Write-Host "Tier 1 (under $TopLevelManagementGroupPrefix):"
New-MgIfMissing -Name $platformMg       -ParentName $TopLevelManagementGroupPrefix
New-MgIfMissing -Name $landingZonesMg   -ParentName $TopLevelManagementGroupPrefix
New-MgIfMissing -Name $sandboxesMg      -ParentName $TopLevelManagementGroupPrefix
New-MgIfMissing -Name $decommissionedMg -ParentName $TopLevelManagementGroupPrefix

Write-Host ""
Write-Host "Tier 2 (under $platformMg):"
foreach ($m in $PlatformMgs) {
    New-MgIfMissing -Name "$TopLevelManagementGroupPrefix-$m" -ParentName $platformMg
}

Write-Host ""
Write-Host "Tier 2 (under $landingZonesMg):"
foreach ($m in $LandingZoneMgs) {
    New-MgIfMissing -Name "$TopLevelManagementGroupPrefix-$m" -ParentName $landingZonesMg
}

Write-Host ""
Write-Host "Done. You can now run the eslzArm.json deployment against '$TopLevelManagementGroupPrefix'." -ForegroundColor Cyan
