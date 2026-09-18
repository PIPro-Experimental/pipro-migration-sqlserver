<#
    refresh-interim.ps1 - hop 1.5. Copies the interim (desktop Postgres) schema into
    the docker Postgres, replacing the previous copy.

    WHY THIS EXISTS: PostgresImport writes to the DESKTOP Postgres, but the migration
    scripts and the parity report both read a COPY of it inside docker. Re-running the
    import does NOT change the docker copy, so a report run straight after an import
    silently re-measures the OLD data.

    DESTRUCTIVE: drops and recreates the target schema in docker. The tenant schemas
    are untouched.

    Usage:
      powershell -ExecutionPolicy Bypass -File refresh-interim.ps1
      powershell -ExecutionPolicy Bypass -File refresh-interim.ps1 -Schema airplane -DesktopPort 5433
#>
param(
    [string]$Schema       = 'airplane',
    [string]$DesktopHost  = 'host.docker.internal',
    [int]   $DesktopPort  = 5433,
    [string]$DesktopDb    = 'payroll',
    [string]$DesktopUser  = 'postgres',
    [string]$DesktopPassword
)
$ErrorActionPreference = 'Stop'

cmd /c "docker info >nul 2>&1"
if ($LASTEXITCODE -ne 0) {
    Write-Host "`n==> Docker is not running. Start Docker Desktop, then re-run.`n" -ForegroundColor Yellow
    exit 1
}

if (-not $DesktopPassword) {
    $secure = Read-Host -Prompt "Desktop Postgres password for $DesktopUser" -AsSecureString
    $DesktopPassword = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
}

# Sanity-check the source before dropping anything on the target.
Write-Host "==> Checking $DesktopDb.$Schema on $DesktopHost`:$DesktopPort ..." -ForegroundColor Cyan
$check = docker exec -e PGPASSWORD=$DesktopPassword pipro-postgres psql `
    "postgresql://$DesktopUser@$DesktopHost`:$DesktopPort/$DesktopDb" -t -A `
    -c "SELECT count(*) FROM information_schema.tables WHERE table_schema = '$Schema'"
if (($LASTEXITCODE -ne 0) -or ([int]$check -le 0)) {
    Write-Host "==> Could not read schema '$Schema' on the desktop DB. Nothing was changed." -ForegroundColor Red
    exit 1
}
Write-Host "    $check tables found." -ForegroundColor DarkGray

Write-Host "==> Replacing docker schema '$Schema' ..." -ForegroundColor Cyan
docker exec -e PGPASSWORD=$DesktopPassword pipro-postgres sh -c @"
set -e
pg_dump -h $DesktopHost -p $DesktopPort -U $DesktopUser -d $DesktopDb -n $Schema --no-owner --no-privileges -f /tmp/interim.sql
PGPASSWORD=pipro-dev-only psql -U pipro -d pipro -v ON_ERROR_STOP=on -q -c 'DROP SCHEMA IF EXISTS $Schema CASCADE'
PGPASSWORD=pipro-dev-only psql -U pipro -d pipro -v ON_ERROR_STOP=on -q -f /tmp/interim.sql
rm -f /tmp/interim.sql
"@
if ($LASTEXITCODE -ne 0) { Write-Host "==> Refresh failed." -ForegroundColor Red; exit 1 }

Write-Host "==> Verifying ..." -ForegroundColor Cyan
docker exec -e PGPASSWORD=pipro-dev-only pipro-postgres psql -U pipro -d pipro `
    -c "SELECT '$Schema' AS schema, (SELECT count(*) FROM $Schema.employees) AS employees, (SELECT count(*) FROM $Schema.employee_alpha) AS alpha, (SELECT count(*) FROM $Schema.employee_amounts) AS amounts;"

Write-Host "`n==> Done. The docker copy now matches the desktop import." -ForegroundColor Green
Write-Host "    NOTE: PostgresImport re-mints employees.employeeno on every run, so the" -ForegroundColor Yellow
Write-Host "    'emp-<surrogate>' ids in an EXISTING tenant may no longer line up. Re-run" -ForegroundColor Yellow
Write-Host "    sql/90_employee_map.sql and read its section 6 before trusting hop 2." -ForegroundColor Yellow
