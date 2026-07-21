<#
    run-migration.ps1 — hop 2 driver. Loads the migration_map, then runs
    sql/10_employees.sql once per tenant with the right search_path + variables.

    PREREQUISITES (see README):
      1. Docker stack up; tenants provisioned via the app (tenant_<slug> exists,
         pipro_core_tenants populated).
      2. Legacy tables dumped into the docker DB as schemas (e.g. legacy_acme) —
         option (b). This script assumes single-DB (source + target both in docker).

    Usage:
      powershell -ExecutionPolicy Bypass -File run-migration.ps1
      powershell -ExecutionPolicy Bypass -File run-migration.ps1 -SystemUserId 1
#>
param(
    [int]$SystemUserId = 1,                                  # DECISION: created_by user for contracts
    [string]$Cutover  = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssK")
)
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$PG   = @('exec','-i','-e','PGPASSWORD=pipro-dev-only','pipro-postgres','psql','-U','pipro','-d','pipro')

# --- Docker preflight (do NOT auto-launch; the user starts it manually) --------
docker info 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "`n==> Docker is not running. Start Docker Desktop, wait for 'Engine running', then re-run.`n" -ForegroundColor Yellow
    exit 1
}

# --- Load the routing map (idempotent) -----------------------------------------
Write-Host "==> Loading migration_map..." -ForegroundColor Cyan
Get-Content (Join-Path $here 'sql/00_migration_map.sql') -Raw | docker @PG -v ON_ERROR_STOP=on | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host "==> Failed to load migration_map." -ForegroundColor Red; exit 1 }

# --- Read the map rows ----------------------------------------------------------
$raw = docker exec -e PGPASSWORD=pipro-dev-only pipro-postgres psql -U pipro -d pipro -t -A -F '|' `
        -c "SELECT legacy_schema, tenant_slug, target_payroll_id FROM migration_map ORDER BY legacy_schema"
if ($LASTEXITCODE -ne 0) { Write-Host "==> Could not read migration_map." -ForegroundColor Red; exit 1 }

$rows = $raw -split "`n" | Where-Object { $_ -match '\|' }
if (-not $rows) { Write-Host "==> migration_map is empty — edit sql/00_migration_map.sql." -ForegroundColor Yellow; exit 1 }

# --- Populate each tenant (10 core → 20 recurring) ------------------------------
$scripts = @('sql/10_employees.sql', 'sql/20_recurring.sql', 'sql/40_employee_slots.sql') | ForEach-Object { Join-Path $here $_ }
foreach ($row in $rows) {
    $c = $row.Split('|')
    $legacy = $c[0]; $slug = $c[1]; $payrollId = $c[2]
    $tenant = "tenant_$slug"
    Write-Host "==> $legacy  ->  $tenant  (payroll $payrollId)" -ForegroundColor Cyan
    foreach ($script in $scripts) {
        Get-Content $script -Raw | docker @PG `
            -v ("legacy_schema=" + $legacy) `
            -v ("tenant_schema=" + $tenant) `
            -v ("target_payroll_id=" + $payrollId) `
            -v ("cutover=" + $Cutover) `
            -v ("system_user_id=" + $SystemUserId)
        if ($LASTEXITCODE -ne 0) {
            Write-Host "==> FAILED on $tenant / $(Split-Path $script -Leaf) (rolled back). Fix and re-run.`n" -ForegroundColor Red
            exit 1
        }
    }
}
Write-Host "`n==> All tenants populated." -ForegroundColor Green
