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

function New-MgIfMissing {
    param(
        [string]$Name,
        [string]$ParentName
    )
    $parentId = "/providers/Microsoft.Management/managementGroups/$ParentName"
    if ($PSCmdlet.ShouldProcess($Name, "Create MG under $ParentName")) {
        $result = Invoke-AzNative 'account' 'management-group' 'create' `
            '--name' $Name `
            '--display-name' $Name `
            '--parent' $parentId `
            '--only-show-errors'
        if ($result.ExitCode -eq 0) {
            Write-Host "  [create] $Name under $ParentName" -ForegroundColor Green
            return
        }
        # Tolerate already-exists (idempotency). Azure CLI returns different wording
        # depending on version, so match on common phrases.
        if ($result.Output -match 'already exists|Conflict|409') {
            Write-Host "  [skip]   $Name already exists" -ForegroundColor DarkGray
            return
        }
        Write-Host $result.Output -ForegroundColor Red
        throw "Failed to create management group '$Name' (exit $($result.ExitCode))."
    }
}

Test-AzCli

# We don't verify the parent MG up front because 'management-group show' requires
# read permission at that MG (or ancestor). If the parent is missing, the first
# create call below will fail with a clear error.

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
