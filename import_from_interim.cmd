@echo off
rem ===========================================================================
rem  import_from_interim.cmd - IMPORT ONLY. Refreshes the docker copy of the
rem  interim database and re-imports the employee slots into the tenant.
rem
rem  This script WRITES. It changes exactly two things:
rem     1. the docker '%SOURCE%' schema  - dropped and rebuilt from the desktop DB
rem     2. the tenant's employee_alpha   - deleted and repopulated
rem
rem  It reports nothing. To see whether the data is correct afterwards, run
rem  compare_report.cmd, which is read-only.
rem
rem  Each step pauses afterwards - Ctrl+C to abort. Nothing later depends on a
rem  step you abort out of.
rem ===========================================================================
setlocal
cd /d "%~dp0"

if not exist "settings.local.txt" (
    echo.
    echo     No settings.local.txt found in this folder.
    echo     Copy settings.example.txt to settings.local.txt and fill in your own
    echo     database details - it is gitignored, so it stays on your machine.
    goto :failed
)
for /f "usebackq eol=# tokens=1,* delims==" %%a in ("settings.local.txt") do set "%%a=%%b"

set TENANT=%TENANT_SCHEMA%
set SOURCE=%INTERIM_SCHEMA%
set PSQL=docker exec -i -e PGPASSWORD=%DOCKER_PASSWORD% %DOCKER_CONTAINER% psql -U %DOCKER_USER% -d %DOCKER_DB% -v ON_ERROR_STOP=on
if not defined TENANT goto :nosetting
if not defined SOURCE goto :nosetting

for /f %%d in ('powershell -NoProfile -Command "Get-Date -Format yyyy-MM-dd"') do set CUTOVER=%%d
if not defined CUTOVER (
    echo     Could not derive today's date. Edit this file to set CUTOVER by hand.
    goto :failed
)

echo.
echo ===========================================================================
echo  IMPORT   interim -^> experimental
echo  Tenant : %TENANT%      Source: %SOURCE%      Cutover: %CUTOVER%
echo ===========================================================================

docker info >nul 2>&1
if errorlevel 1 (
    echo     Docker is not running. Start Docker Desktop and re-run.
    goto :failed
)

rem --- Step 1 -----------------------------------------------------------------
echo.
echo [1/3] Refresh the docker copy of the interim DB from the desktop Postgres.
echo       PostgresImport writes to the DESKTOP db; everything here reads the
echo       docker copy. Without this, nothing downstream sees the new import.
echo.
powershell -ExecutionPolicy Bypass -File .\refresh-interim.ps1
if errorlevel 1 goto :failed
pause

rem --- Step 2 -----------------------------------------------------------------
echo.
echo [2/3] Safety gate - do the tenant's employee ids still match the interim?
echo.
echo       PostgresImport re-mints employees.employeeno on every run. The tenant's
echo       'emp-N' ids were built from the PREVIOUS run's surrogates, so if the new
echo       numbering differs, step 3 would import each employee's values onto a
echo       DIFFERENT person - silently. This counts the mismatches.
echo.
rem The query result is written to a file and read back, rather than run inside
rem the for/f itself: cmd splits on the '=' in "-e PGPASSWORD=..." when a command
rem string is parsed that way, and docker ends up reading the password as the
rem container name.
%PSQL% -t -A -c "SELECT count(*) FROM %TENANT%.employees t JOIN %SOURCE%.employees a ON btrim(a.employeeid_f01) = btrim(t.employee_code) WHERE t.id IS DISTINCT FROM concat('emp-', a.employeeno)" > "%TEMP%\pipro-gate.txt"
if errorlevel 1 goto :failed
set MISALIGNED=
for /f "usebackq delims= " %%c in ("%TEMP%\pipro-gate.txt") do set MISALIGNED=%%c
del "%TEMP%\pipro-gate.txt" >nul 2>&1
if not defined MISALIGNED (
    echo     Could not run the check. Aborting rather than guessing.
    goto :failed
)
if not "%MISALIGNED%"=="0" (
    echo.
    echo     STOP: %MISALIGNED% employees have ids that no longer match the interim
    echo     surrogates. Importing now would cross-link people. The tenant needs
    echo     rebuilding from scratch instead - do not continue.
    goto :failed
)
echo     OK - 0 misaligned. The tenant and the refreshed interim agree.
pause

rem --- Step 3 -----------------------------------------------------------------
echo.
echo ===========================================================================
echo  [3/3] DESTRUCTIVE - deletes every employee_alpha row in %TENANT%
echo        and re-imports them from the refreshed interim copy.
echo.
echo        Needed because 40_employee_slots inserts with ON CONFLICT DO NOTHING,
echo        so existing rows would otherwise survive unchanged. Only the alpha
echo        table is emptied; the other tables in that script re-run as no-ops.
echo.
echo        NOTE: this does NOT re-run 10_employees. That script mints users with
echo        no conflict guard, so re-running it on a populated tenant would leave
echo        orphan user rows and change nothing else.
echo ===========================================================================
echo.
set /p CONFIRM="Type YES to delete and re-import employee_alpha: "
if /i not "%CONFIRM%"=="YES" (
    echo     Skipped by request. Nothing was changed in the tenant.
    goto :done
)
%PSQL% -c "DELETE FROM %TENANT%.employee_alpha;"
if errorlevel 1 goto :failed
type sql\40_employee_slots.sql | %PSQL% -v legacy_company_schema=%SOURCE% -v tenant_schema=%TENANT% -v cutover=%CUTOVER% -v system_user_id=1
if errorlevel 1 goto :failed

:done
echo.
echo ===========================================================================
echo  Import finished. Nothing has been verified.
echo.
echo  Run the read-only check next:
echo      compare_report.cmd before
echo ===========================================================================
pause
exit /b 0

:nosetting
echo.
echo     settings.local.txt is missing TENANT_SCHEMA or INTERIM_SCHEMA.
echo     See settings.example.txt for the full list.
goto :failed

:failed
echo.
echo ===========================================================================
echo  FAILED on the step above. Nothing further has run.
echo  Each SQL script is wrapped in a transaction, so a failed step rolled back.
echo ===========================================================================
pause
exit /b 1
