<#
    convert.ps1 - drives a whole client conversion from payrolls.csv.

    Usage:
      powershell -ExecutionPolicy Bypass -File convert.ps1 -TenantSlug acme
      powershell -ExecutionPolicy Bypass -File convert.ps1 -TenantSlug acme -SkipReset

    WHAT IT DOES, and what it deliberately leaves to you:

      1. Loads and validates payrolls.csv (see load-manifest.ps1).
      2. Prints the plan and waits.
      3. Resets the tenant ONCE - not per payroll, or the second payroll would
         wipe the first.
      4. For each payroll, in manifest order:
           - waits while YOU run PostgresImport against that source database
           - copies the two interim schemas into docker under the manifest's
             names, so the next PostgresImport run cannot overwrite them
           - VERIFIES the payroll number in the data matches what the manifest
             declared
      5. Seeds migration_map from the manifest.
      6. Runs the import chain (run-migration.ps1) for every mapped payroll.

    Step 4 pauses because PostgresImport always writes the SAME two schema names
    on the desktop. Ten payrolls cannot sit there at once, so each has to be
    imported and then parked in docker before the next one runs. That is the one
    part no script here can do for you.

    WRITES. It empties and repopulates the tenant. Reports come afterwards, from
    compare_report.cmd and run_report.cmd.

    role=history rows are validated and listed, then skipped - not implemented.
#>
param(
    [Parameter(Mandatory = $true)][string]$TenantSlug,
    [switch]$SkipReset,
    [string]$ManifestPath
)
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\load-settings.ps1"
. "$PSScriptRoot\load-manifest.ps1"

$cfg             = Import-PiproSettings
$dockerContainer = Get-PiproSetting $cfg 'DOCKER_CONTAINER'
$dockerDb        = Get-PiproSetting $cfg 'DOCKER_DB'
$dockerUser      = Get-PiproSetting $cfg 'DOCKER_USER'
$dockerPassword  = Get-PiproSetting $cfg 'DOCKER_PASSWORD'
$tenantSchema    = "tenant_$TenantSlug"

function Invoke-Psql {
    param([string]$Sql, [switch]$Quiet)
    $out = $Sql | docker exec -i -e "PGPASSWORD=$dockerPassword" $dockerContainer `
                  psql -U $dockerUser -d $dockerDb -v ON_ERROR_STOP=on -t -A
    if ($LASTEXITCODE -ne 0) { throw "psql failed: $Sql" }
    if (-not $Quiet) { return $out }
}

function Confirm-Step {
    param([string]$Prompt, [string]$Expect = '')
    Write-Host ""
    if ($Expect) {
        $answer = Read-Host "$Prompt (type $Expect to continue)"
        if ($answer -ne $Expect) { Write-Host "==> Stopped. Nothing further has run." -ForegroundColor Yellow; exit 0 }
    } else {
        Read-Host "$Prompt (Enter to continue, Ctrl+C to stop)" | Out-Null
    }
}

cmd /c "docker info >nul 2>&1"
if ($LASTEXITCODE -ne 0) {
    Write-Host "`n==> Docker is not running. Start Docker Desktop, then re-run.`n" -ForegroundColor Yellow
    exit 1
}

# --- 1. Manifest -----------------------------------------------------------------
$rows = if ($ManifestPath) { Import-PiproManifest -Path $ManifestPath -TenantSlug $TenantSlug }
        else               { Import-PiproManifest -TenantSlug $TenantSlug }
$current = @($rows | Where-Object { $_.role -eq 'current' })
$history = @($rows | Where-Object { $_.role -eq 'history' })

if ($current.Count -eq 0) {
    Write-Host "==> No 'current' rows for tenant '$TenantSlug'. Nothing to convert." -ForegroundColor Red
    exit 1
}

# --- 2. The plan -----------------------------------------------------------------
Write-Host ""
Write-Host "===========================================================================" -ForegroundColor Cyan
Write-Host " CONVERT  ->  $tenantSchema" -ForegroundColor Cyan
Write-Host "===========================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host (" {0,-22} {1,-16} {2,-16} {3,8} {4,8}" -f 'source database','company schema','payroll schema','payroll','target')
foreach ($r in $current) {
    Write-Host (" {0,-22} {1,-16} {2,-16} {3,8} {4,8}" -f `
        $r.source_db, $r.company_schema, $r.payroll_schema, $r.legacy_payroll_number, $r.target_payroll_id)
}
Write-Host ""
Write-Host " $($current.Count) payroll(s) to convert." -ForegroundColor Green
if ($history.Count -gt 0) {
    Write-Host " $($history.Count) history row(s) validated and SKIPPED (not implemented):" -ForegroundColor Yellow
    foreach ($h in $history) { Write-Host "    $($h.source_db)  tax year $($h.tax_year)" -ForegroundColor DarkGray }
}

# The tenant and its payrolls are provisioned by the APP, never by these scripts.
# Check they exist before doing anything destructive.
$exists = Invoke-Psql "SELECT count(*) FROM information_schema.schemata WHERE schema_name = '$tenantSchema'"
if ([int]$exists -eq 0) {
    Write-Host "`n==> No schema '$tenantSchema'. Provision the tenant through the app first.`n" -ForegroundColor Red
    exit 1
}
foreach ($r in $current) {
    $p = Invoke-Psql "SELECT count(*) FROM $tenantSchema.payrolls WHERE id = $($r.target_payroll_id)"
    if ([int]$p -eq 0) {
        Write-Host "`n==> $tenantSchema has no payrolls row with id $($r.target_payroll_id)" -ForegroundColor Red
        Write-Host "    (needed by manifest row '$($r.source_db)'). Create it through the app.`n" -ForegroundColor Yellow
        exit 1
    }
}
Write-Host " Tenant and all target payroll rows exist." -ForegroundColor Green

Confirm-Step "Proceed with this plan?"

# --- 3. Reset --------------------------------------------------------------------
if ($SkipReset) {
    Write-Host "`n==> -SkipReset given: the tenant keeps its current data." -ForegroundColor Yellow
    Write-Host "    Only use this to resume a conversion you already reset for." -ForegroundColor Yellow
} else {
    Write-Host ""
    Write-Host "---------------------------------------------------------------------------" -ForegroundColor Yellow
    Write-Host " RESET $tenantSchema - empties every employee- and run-scoped table," -ForegroundColor Yellow
    Write-Host " removes the login users this import minted, and keeps the seven" -ForegroundColor Yellow
    Write-Host " configuration tables provisioning created. Not reversible." -ForegroundColor Yellow
    Write-Host " It runs ONCE for the tenant, before any payroll." -ForegroundColor Yellow
    Write-Host "---------------------------------------------------------------------------" -ForegroundColor Yellow
    Confirm-Step "Reset $tenantSchema" -Expect 'RESET'

    Get-Content (Join-Path $PSScriptRoot 'sql/09_reset_tenant.sql') -Raw |
        docker exec -i -e "PGPASSWORD=$dockerPassword" $dockerContainer psql -U $dockerUser -d $dockerDb `
            -v ON_ERROR_STOP=on -v "tenant_schema=$tenantSchema" -v "confirm=RESET"
    if ($LASTEXITCODE -ne 0) { Write-Host "==> Reset failed." -ForegroundColor Red; exit 1 }
}

# --- 4. Per-payroll: PostgresImport, then park the schemas in docker -------------
$n = 0
foreach ($r in $current) {
    $n++
    Write-Host ""
    Write-Host "===========================================================================" -ForegroundColor Cyan
    Write-Host " PAYROLL $n of $($current.Count):  $($r.source_db)  ->  payroll $($r.legacy_payroll_number)" -ForegroundColor Cyan
    Write-Host "===========================================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host " Now, outside this script:" -ForegroundColor Yellow
    Write-Host "   1. restore '$($r.source_db)' to SQL Server" -ForegroundColor Yellow
    Write-Host "   2. run PostgresImport against it" -ForegroundColor Yellow
    Write-Host ""
    Write-Host " Then this script copies the interim schemas into docker as" -ForegroundColor DarkGray
    Write-Host "   $($r.company_schema) + $($r.payroll_schema)" -ForegroundColor DarkGray
    Write-Host " so the NEXT PostgresImport run cannot overwrite them." -ForegroundColor DarkGray
    Confirm-Step "PostgresImport finished for '$($r.source_db)'?"

    & (Join-Path $PSScriptRoot 'refresh-interim.ps1') `
        -Schema $r.company_schema -PayrollTarget $r.payroll_schema
    if ($LASTEXITCODE -ne 0) { Write-Host "==> Refresh failed for $($r.source_db)." -ForegroundColor Red; exit 1 }

    # VERIFY the declared payroll number against the data. The manifest is a
    # declaration; this is the check that makes it one.
    $found = Invoke-Psql "SELECT string_agg(DISTINCT payroll_f04::text, ',') FROM $($r.company_schema).employees"
    $found = ([string]$found).Trim()
    if ($found -ne $r.legacy_payroll_number) {
        Write-Host ""
        Write-Host "==> PAYROLL NUMBER MISMATCH for '$($r.source_db)'." -ForegroundColor Red
        Write-Host "    Manifest says $($r.legacy_payroll_number); the data says '$found'." -ForegroundColor Red
        Write-Host "    Either the wrong database was imported, or the manifest is wrong." -ForegroundColor Yellow
        Write-Host "    Stopping - importing this would attribute employees to the wrong payroll." -ForegroundColor Yellow
        exit 1
    }
    Write-Host "    payroll number $found confirmed against the data." -ForegroundColor Green
}

# --- 5. Seed migration_map -------------------------------------------------------
Write-Host ""
Write-Host "==> Seeding migration_map from the manifest..." -ForegroundColor Cyan
$values = ($current | ForEach-Object {
    "('$($_.company_schema)','$($_.payroll_schema)','$($_.tenant_slug)',$($_.target_payroll_id),$($_.legacy_payroll_number))"
}) -join ",`n    "
Invoke-Psql @"
CREATE TABLE IF NOT EXISTS migration_map (
    legacy_company_schema TEXT PRIMARY KEY,
    legacy_payroll_schema TEXT NOT NULL,
    tenant_slug           TEXT NOT NULL,
    target_payroll_id     INTEGER NOT NULL,
    legacy_payroll_number INTEGER NOT NULL DEFAULT 1);
DELETE FROM migration_map WHERE tenant_slug = '$TenantSlug';
INSERT INTO migration_map (legacy_company_schema, legacy_payroll_schema, tenant_slug, target_payroll_id, legacy_payroll_number) VALUES
    $values;
"@ -Quiet
Invoke-Psql "SELECT legacy_company_schema || ' + ' || legacy_payroll_schema || ' -> ' || tenant_slug || ' payroll ' || target_payroll_id FROM migration_map WHERE tenant_slug = '$TenantSlug' ORDER BY target_payroll_id" |
    ForEach-Object { if ($_) { Write-Host "    $_" -ForegroundColor DarkGray } }

Confirm-Step "Run the import chain for these payroll(s)?"

# --- 6. The import chain ---------------------------------------------------------
& (Join-Path $PSScriptRoot 'run-migration.ps1')
if ($LASTEXITCODE -ne 0) { Write-Host "==> Import chain failed." -ForegroundColor Red; exit 1 }

Write-Host ""
Write-Host "===========================================================================" -ForegroundColor Green
Write-Host " Conversion finished. NOTHING HAS BEEN VERIFIED." -ForegroundColor Green
Write-Host ""
Write-Host " Check it with the read-only reports:" -ForegroundColor Green
Write-Host "     compare_report.cmd before     employee master data" -ForegroundColor Green
Write-Host "     run_report.cmd validation     run output, once both sides have run" -ForegroundColor Green
Write-Host "===========================================================================" -ForegroundColor Green
