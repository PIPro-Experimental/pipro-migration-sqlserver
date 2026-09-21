<#
    refresh-interim.ps1 - hop 1.5. Copies the interim (desktop Postgres) schema into
    the docker Postgres, replacing the previous copy.

    WHY THIS EXISTS: PostgresImport writes to the DESKTOP Postgres, but the migration
    scripts and the parity report both read a COPY of it inside docker. Re-running the
    import does NOT change the docker copy, so a report run straight after an import
    silently re-measures the OLD data.

    VERSION MISMATCH (the reason this is not a one-liner): the desktop server is
    PostgreSQL 18 and the docker server is pinned to 16.
      * pg_dump refuses to read a server NEWER than itself, so the container's
        bundled pg_dump 16 cannot dump the desktop DB -- we use the local
        PostgreSQL 18 client instead, found automatically below.
      * Restoring 18 -> 16 is the unsupported direction. In practice the only thing
        that breaks for a plain table+data dump is the preamble line
        `SET transaction_timeout = 0;` (new in PG17), which a 16 server rejects.
        That line is stripped before the restore. This is the same incompatibility
        pipro-app's Dockerfile pins postgresql-client-16 to avoid.
      * If the restore ever fails on some OTHER unrecognized parameter, add it to
        $incompatibleSettings rather than loosening ON_ERROR_STOP.

    DESTRUCTIVE: drops and recreates the target schema in docker. Tenant schemas are
    untouched.

    Connection details live in settings.local.txt (copy settings.example.txt).
    Parameters override the file for a one-off run.

    Usage:
      powershell -ExecutionPolicy Bypass -File refresh-interim.ps1
      powershell -ExecutionPolicy Bypass -File refresh-interim.ps1 -Schema other_client
#>
param(
    [string]$Schema,
    [string]$DesktopHost,
    [int]   $DesktopPort,
    [string]$DesktopDb,
    [string]$DesktopUser,
    [string]$DesktopPassword,
    [string]$PgDumpPath
)
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\load-settings.ps1"
$cfg = Import-PiproSettings

if (-not $Schema)          { $Schema         = Get-PiproSetting $cfg 'INTERIM_SCHEMA' }
if (-not $DesktopHost)     { $DesktopHost    = Get-PiproSetting $cfg 'INTERIM_HOST' }
if (-not $DesktopPort)     { $DesktopPort    = [int](Get-PiproSetting $cfg 'INTERIM_PORT') }
if (-not $DesktopDb)       { $DesktopDb      = Get-PiproSetting $cfg 'INTERIM_DB' }
if (-not $DesktopUser)     { $DesktopUser    = Get-PiproSetting $cfg 'INTERIM_USER' }
if (-not $DesktopPassword) { $DesktopPassword = Get-PiproSetting $cfg 'INTERIM_PASSWORD' -AllowEmpty }

$dockerContainer = Get-PiproSetting $cfg 'DOCKER_CONTAINER'
$dockerDb        = Get-PiproSetting $cfg 'DOCKER_DB'
$dockerUser      = Get-PiproSetting $cfg 'DOCKER_USER'
$dockerPassword  = Get-PiproSetting $cfg 'DOCKER_PASSWORD'

# Settings emitted by a newer pg_dump that an older server will not accept.
$incompatibleSettings = @('transaction_timeout')

cmd /c "docker info >nul 2>&1"
if ($LASTEXITCODE -ne 0) {
    Write-Host "`n==> Docker is not running. Start Docker Desktop, then re-run.`n" -ForegroundColor Yellow
    exit 1
}

# --- Locate a pg_dump at least as new as the desktop server ---------------------
if (-not $PgDumpPath) {
    $candidates = Get-ChildItem 'C:\Program Files\PostgreSQL\*\bin\pg_dump.exe' -ErrorAction SilentlyContinue |
                  Sort-Object { [int]($_.Directory.Parent.Name) } -Descending
    if (-not $candidates) {
        Write-Host "==> No local pg_dump found under C:\Program Files\PostgreSQL. Pass -PgDumpPath." -ForegroundColor Red
        exit 1
    }
    $PgDumpPath = $candidates[0].FullName
}
Write-Host "==> Using $PgDumpPath" -ForegroundColor DarkGray

if (-not $DesktopPassword) {
    $secure = Read-Host -Prompt "Desktop Postgres password for $DesktopUser" -AsSecureString
    $DesktopPassword = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
}
$env:PGPASSWORD = $DesktopPassword

try {
    # --- Sanity-check the source before dropping anything on the target ----------
    Write-Host "==> Checking $DesktopDb.$Schema on $DesktopHost`:$DesktopPort ..." -ForegroundColor Cyan
    $psqlPath = Join-Path (Split-Path $PgDumpPath) 'psql.exe'
    $tableCount = & $psqlPath -h $DesktopHost -p $DesktopPort -U $DesktopUser -d $DesktopDb -t -A `
        -c "SELECT count(*) FROM information_schema.tables WHERE table_schema = '$Schema'"
    if (($LASTEXITCODE -ne 0) -or ([int]$tableCount -le 0)) {
        Write-Host "==> Could not read schema '$Schema' on the desktop DB. Nothing was changed." -ForegroundColor Red
        exit 1
    }
    Write-Host "    $tableCount tables found." -ForegroundColor DarkGray

    # --- Dump with the LOCAL (newer) client --------------------------------------
    $dumpFile = Join-Path $env:TEMP "interim-$Schema.sql"
    Write-Host "==> Dumping to $dumpFile ..." -ForegroundColor Cyan
    & $PgDumpPath -h $DesktopHost -p $DesktopPort -U $DesktopUser -d $DesktopDb `
                  -n $Schema --no-owner --no-privileges --no-tablespaces -f $dumpFile
    if ($LASTEXITCODE -ne 0) { Write-Host "==> pg_dump failed. Nothing was changed." -ForegroundColor Red; exit 1 }
    Write-Host ("    {0:N1} MB" -f ((Get-Item $dumpFile).Length / 1MB)) -ForegroundColor DarkGray
}
finally {
    Remove-Item Env:\PGPASSWORD -ErrorAction SilentlyContinue
}

# --- Ship it into the container and restore ---------------------------------------
Write-Host "==> Copying into the container ..." -ForegroundColor Cyan
cmd /c "docker cp `"$dumpFile`" ${dockerContainer}:/tmp/interim.sql >nul 2>&1"
if ($LASTEXITCODE -ne 0) { Write-Host "==> docker cp failed. Nothing was changed." -ForegroundColor Red; exit 1 }

$stripExpr = ($incompatibleSettings | ForEach-Object { "/^SET $_ = /d" }) -join '; '

Write-Host "==> Replacing docker schema '$Schema' ..." -ForegroundColor Cyan
docker exec $dockerContainer sh -c @"
set -e
sed -i '$stripExpr' /tmp/interim.sql
export PGPASSWORD=$dockerPassword
psql -U $dockerUser -d $dockerDb -v ON_ERROR_STOP=on -q -c 'DROP SCHEMA IF EXISTS $Schema CASCADE'
psql -U $dockerUser -d $dockerDb -v ON_ERROR_STOP=on -q -f /tmp/interim.sql
rm -f /tmp/interim.sql
"@
if ($LASTEXITCODE -ne 0) {
    Write-Host "==> Restore failed." -ForegroundColor Red
    Write-Host "    If the error names an unrecognized configuration parameter, add it to" -ForegroundColor Yellow
    Write-Host "    `$incompatibleSettings at the top of this script and re-run." -ForegroundColor Yellow
    exit 1
}

Write-Host "==> Verifying ..." -ForegroundColor Cyan
docker exec -e PGPASSWORD=$dockerPassword $dockerContainer psql -U $dockerUser -d $dockerDb `
    -c "SELECT '$Schema' AS schema, (SELECT count(*) FROM $Schema.employees) AS employees, (SELECT count(*) FROM $Schema.employee_alpha) AS alpha, (SELECT count(*) FROM $Schema.employee_amounts) AS amounts, (SELECT count(*) FROM $Schema.employee_alpha WHERE ordinalno IN (106,107) AND (reference_v IS NULL OR btrim(reference_v) = '')) AS blank_office_site;"

Write-Host "`n==> Done. The docker copy now matches the desktop import." -ForegroundColor Green
Write-Host "    blank_office_site should be 0 if the RefNoCode fix took." -ForegroundColor Green
Write-Host "    NOTE: PostgresImport re-mints employees.employeeno on every run, so the" -ForegroundColor Yellow
Write-Host "    'emp-<surrogate>' ids in an EXISTING tenant may no longer line up." -ForegroundColor Yellow
Write-Host "    import_from_interim.cmd checks that automatically before it writes." -ForegroundColor Yellow
