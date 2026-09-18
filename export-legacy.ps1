<#
    export-legacy.ps1 - hop-0 extract. Pulls the employee tables the pay run
    reads or writes out of the legacy SQL Server and stages them in the docker
    Postgres `compare` schema, then runs sql/93_legacy_snapshot.sql to turn
    them into a canonical snapshot.

    SQL Server credentials never leave this script: sqlcmd uses the Windows
    trusted connection, so nothing is stored here or in either application.

    TIMING - THE ONE STEP THAT CANNOT BE REDONE:
      Capture -Phase before BEFORE running payroll in legacy. A run overwrites
      the before-state in place and no later query can recover it.

    Usage:
      powershell -ExecutionPolicy Bypass -File export-legacy.ps1 -Phase before
      powershell -ExecutionPolicy Bypass -File export-legacy.ps1 -Phase after -Snap legacy-after
#>
param(
    [ValidateSet('before','after')][string]$Phase = 'before',
    [string]$Snap,
    [string]$SqlServer = 'localhost,1433',
    [string]$SqlDatabase = 'pipro'
)
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
if (-not $Snap) { $Snap = "legacy-$Phase" }

# PS 5.1 prepends a UTF-8 BOM when piping to a native process (docker/psql here),
# and COPY reads that BOM as part of the first integer. This makes the pipe clean.
$OutputEncoding = New-Object System.Text.UTF8Encoding $false

$sqlcmd = 'C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\170\Tools\Binn\sqlcmd.exe'
if (-not (Test-Path $sqlcmd)) { $sqlcmd = 'sqlcmd' }
$PG = @('exec','-i','-e','PGPASSWORD=pipro-dev-only','pipro-postgres','psql','-U','pipro','-d','pipro')

cmd /c "docker info >nul 2>&1"
if ($LASTEXITCODE -ne 0) {
    Write-Host "`n==> Docker is not running. Start Docker Desktop, then re-run.`n" -ForegroundColor Yellow
    exit 1
}

# Staging tables mirror the legacy column names and types verbatim - every
# conversion (float rounding, the 1799-12-31 date epoch, the +100 refno offset)
# happens in 93, where it is documented, not here.
$staging = @'
CREATE SCHEMA IF NOT EXISTS compare;
DROP TABLE IF EXISTS compare.legacy_imf, compare.legacy_amts, compare.legacy_inds,
                     compare.legacy_refnos, compare.legacy_dates,
                     compare.legacy_parm_refnos, compare.legacy_descf;
CREATE TABLE compare.legacy_imf    (empno INT PRIMARY KEY, surname TEXT, inits TEXT);
CREATE TABLE compare.legacy_amts   (empno INT, ordinalno INT, amt DOUBLE PRECISION);
CREATE TABLE compare.legacy_inds   (empno INT, ordinalno INT, ind TEXT);
CREATE TABLE compare.legacy_refnos (empno INT, ordinalno INT, refno TEXT, refnocode TEXT);
CREATE TABLE compare.legacy_dates  (empno INT, ordinalno INT, datevalue INT);
-- The RefNoCode indirection (owner 2026-09-17): PW_Parm_RefNoNames.RefNoDescInd
-- decides whether an employee's reference value is the literal RefNo or a code
-- looked up in PW_Descf. Both are payroll-scoped.
CREATE TABLE compare.legacy_parm_refnos (payroll INT, ordinalno INT, refnoname TEXT, refnodescind TEXT);
CREATE TABLE compare.legacy_descf       (payroll INT, refno INT, desccode TEXT, description TEXT);
'@
Write-Host "==> Creating staging tables..." -ForegroundColor Cyan
$staging | docker @PG -v ON_ERROR_STOP=on | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host "==> Staging failed." -ForegroundColor Red; exit 1 }

# Each extract: a SELECT against SQL Server, streamed into COPY on the Postgres
# side. Pipe-delimited because no legacy value in these columns contains a pipe
# (Ind is varchar(1), RefNo varchar(25), the rest are integers).
$extracts = @(
    @{ Table = 'compare.legacy_imf';    Cols = 'empno, surname, inits';
       Query = "SELECT EmpNo, ISNULL(Surname,''), ISNULL(Inits,'') FROM PW_IMF WHERE EmpNo > 0" },
    @{ Table = 'compare.legacy_amts';   Cols = 'empno, ordinalno, amt';
       Query = "SELECT EmpNo, OrdinalNo, Amt FROM PW_Amts WHERE EmpNo > 0" },
    @{ Table = 'compare.legacy_inds';   Cols = 'empno, ordinalno, ind';
       Query = "SELECT EmpNo, OrdinalNo, ISNULL(Ind,'') FROM PW_Inds WHERE EmpNo > 0" },
    @{ Table = 'compare.legacy_refnos'; Cols = 'empno, ordinalno, refno, refnocode';
       Query = "SELECT EmpNo, OrdinalNo, ISNULL(RefNo,''), ISNULL(RefNoCode,'') FROM PW_RefNos WHERE EmpNo > 0" },
    @{ Table = 'compare.legacy_dates';  Cols = 'empno, ordinalno, datevalue';
       Query = "SELECT EmpNo, OrdinalNo, DateValue FROM PW_Dates WHERE EmpNo > 0" },
    @{ Table = 'compare.legacy_parm_refnos'; Cols = 'payroll, ordinalno, refnoname, refnodescind';
       Query = "SELECT Payroll, OrdinalNo, ISNULL(RefNoName,''), ISNULL(RefNoDescInd,'') FROM PW_Parm_RefNoNames" },
    @{ Table = 'compare.legacy_descf'; Cols = 'payroll, refno, desccode, description';
       Query = "SELECT Payroll, RefNo, ISNULL(DescCode,''), ISNULL(Description,'') FROM PW_Descf" }
)

$tmp = Join-Path $env:TEMP "pipro-legacy-export"
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

foreach ($e in $extracts) {
    $name = ($e.Table -split '\.')[-1]
    $file = Join-Path $tmp "$name.psv"
    Write-Host "==> Extracting $name..." -ForegroundColor Cyan

    # -h -1 no headers, -W trim trailing spaces, -s| pipe delimiter.
    # SET NOCOUNT ON suppresses the row-count line.
    $out = & $sqlcmd -S $SqlServer -d $SqlDatabase -E -C -h -1 -W -s '|' `
                     -Q "SET NOCOUNT ON; $($e.Query)"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "==> sqlcmd failed for $name. Is SQL Server up on $SqlServer?" -ForegroundColor Red
        exit 1
    }

    # Drop blank lines and any stray separator row sqlcmd may emit. WriteAllLines
    # (not Out-File/Set-Content) because PS 5.1 writes a UTF-8 BOM, and COPY reads
    # the BOM as part of the first integer.
    # sqlcmd emits a UTF-8 BOM ahead of its first row; COPY reads it as part of
    # the first integer ("invalid input syntax for type integer"). Strip it.
    $rows = $out | Where-Object { $_ -match '\S' -and $_ -notmatch '^-+(\|-+)*$' } `
                 | ForEach-Object { $_ -replace "^﻿", '' }
    [System.IO.File]::WriteAllLines($file, $rows)
    Write-Host "    $($rows.Count) rows" -ForegroundColor DarkGray

    # docker cp, not a stdin pipe: PS 5.1 injects a UTF-8 BOM into native-process
    # stdin regardless of $OutputEncoding, and COPY reads it as part of the first
    # integer. Copying the file in and letting psql read it locally sidesteps that.
    cmd /c "docker cp `"$file`" pipro-postgres:/tmp/$name.psv >nul 2>&1"
    if ($LASTEXITCODE -ne 0) { Write-Host "==> docker cp failed for $name." -ForegroundColor Red; exit 1 }

    docker exec -e PGPASSWORD=pipro-dev-only pipro-postgres psql -U pipro -d pipro -v ON_ERROR_STOP=on `
        -c "\copy $($e.Table) ($($e.Cols)) FROM '/tmp/$name.psv' WITH (FORMAT csv, DELIMITER '|', QUOTE E'\b')" | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Host "==> COPY failed for $name." -ForegroundColor Red; exit 1 }
}

Write-Host "==> Building canonical snapshot '$Snap'..." -ForegroundColor Cyan
Get-Content (Join-Path $here 'sql/93_legacy_snapshot.sql') -Raw | docker @PG `
    -v ON_ERROR_STOP=on -v ("snap=" + $Snap) -v ("phase=" + $Phase)
if ($LASTEXITCODE -ne 0) { Write-Host "==> Snapshot build failed." -ForegroundColor Red; exit 1 }

Write-Host "`n==> Done. Diff it with:" -ForegroundColor Green
Write-Host "    sql/92_employee_diff.sql  -v a=$Snap -v b=interim-$Phase" -ForegroundColor Green
