@echo off
rem ===========================================================================
rem  compare_report.cmd - READ-ONLY parity report across all three systems.
rem
rem  Usage:  compare_report.cmd [before^|after]      (default: before)
rem
rem  WHAT IT TOUCHES: nothing in the legacy SQL Server, the interim copy, or any
rem  tenant schema. It reads those and writes ONLY to the 'compare' schema - its
rem  own snapshot, map and diff tables. Safe to run at any time, as often as you
rem  like. Re-running a phase replaces that phase's snapshots.
rem
rem  PHASES: capture 'before' while every system is still in its pre-run state,
rem  then run payroll in legacy and in experimental, then capture 'after'. The
rem  before/after pair is what shows which employee values a pay run modifies.
rem
rem  Each step pauses afterwards - Ctrl+C to abort.
rem ===========================================================================
setlocal
cd /d "%~dp0"

set PHASE=%~1
if not defined PHASE set PHASE=before
if /i not "%PHASE%"=="before" if /i not "%PHASE%"=="after" (
    echo     Usage: compare_report.cmd [before^|after]
    exit /b 1
)

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

echo.
echo ===========================================================================
echo  PARITY REPORT   phase: %PHASE%      (read-only)
echo  Tenant : %TENANT%      Source: %SOURCE%
echo ===========================================================================

docker info >nul 2>&1
if errorlevel 1 (
    echo     Docker is not running. Start Docker Desktop and re-run.
    goto :failed
)

rem --- Step 1 -----------------------------------------------------------------
echo.
echo [1/6] Extract the legacy SQL Server side into the compare schema.
echo       Reads PW_IMF / PW_Amts / PW_Inds / PW_RefNos / PW_Dates and the two
echo       RefNoCode lookup tables. Nothing in SQL Server is modified.
echo.
powershell -ExecutionPolicy Bypass -File .\export-legacy.ps1 -Phase %PHASE%
if errorlevel 1 goto :failed
pause

rem --- Step 2 -----------------------------------------------------------------
echo.
echo [2/6] Employee key map + import-integrity report.
echo       Bridges legacy EmpNo -^> interim surrogate -^> pipro user id via the
echo       employee_code spine, and reports silent drops, duplicate codes and
echo       orphan rows.
echo.
type sql\90_employee_map.sql | %PSQL% -v legacy_company_schema=%SOURCE% -v tenant_schema=%TENANT%
if errorlevel 1 goto :failed
pause

rem --- Step 3 -----------------------------------------------------------------
echo.
echo [3/6] Capture the interim snapshot  (interim-%PHASE%).
echo.
type sql\91_employee_snapshot.sql | %PSQL% -v system=interim -v phase=%PHASE% -v snap=interim-%PHASE% -v legacy_company_schema=%SOURCE% -v tenant_schema=%TENANT%
if errorlevel 1 goto :failed
pause

rem --- Step 4 -----------------------------------------------------------------
echo.
echo [4/6] Capture the experimental snapshot  (pipro-%PHASE%).
echo.
type sql\91_employee_snapshot.sql | %PSQL% -v system=pipro -v phase=%PHASE% -v snap=pipro-%PHASE% -v legacy_company_schema=%SOURCE% -v tenant_schema=%TENANT%
if errorlevel 1 goto :failed
pause

rem --- Step 5 -----------------------------------------------------------------
echo.
echo [5/6] HOP 1 - legacy vs interim. Did PostgresImport carry every value?
echo.
echo       PASS = only 'match' and 'promoted'. Anything under value_differs,
echo       only_in_a or only_in_b is a defect in the java import.
echo.
type sql\92_employee_diff.sql | %PSQL% -v a=legacy-%PHASE% -v b=interim-%PHASE%
if errorlevel 1 goto :failed
pause

rem --- Step 6 -----------------------------------------------------------------
echo.
echo [6/6] END TO END - legacy vs experimental.
echo.
echo       TARGET: Q 17376 / V 5664 / D 948 all 'match', 563 'promoted',
echo       nothing differing, lost or invented.
echo.
type sql\92_employee_diff.sql | %PSQL% -v a=legacy-%PHASE% -v b=pipro-%PHASE%
if errorlevel 1 goto :failed

if /i not "%PHASE%"=="after" goto :done

rem --- After-phase extras -------------------------------------------------------
pause
echo.
echo [+] WHAT THE PAY RUN TOUCHED - legacy before vs legacy after.
echo.
echo     This is the empirical answer to whether a run writes back into pw_amts.
echo     Bank Q entirely 'match' means it does not; Y ordinals under value_differs
echo     mean something posts totals back.
echo.
type sql\92_employee_diff.sql | %PSQL% -v a=legacy-before -v b=legacy-after
if errorlevel 1 goto :failed
pause
echo.
echo [+] SAME QUESTION, EXPERIMENTAL SIDE - pipro before vs pipro after.
echo.
type sql\92_employee_diff.sql | %PSQL% -v a=pipro-before -v b=pipro-after
if errorlevel 1 goto :failed

:done
echo.
echo ===========================================================================
echo  Report finished. Nothing outside the compare schema was modified.
echo.
%PSQL% -c "SELECT snap, system, phase, taken_at FROM compare.snapshot ORDER BY phase, system;"
echo.
echo  Snapshots are kept, so any two can be diffed by hand:
echo      type sql\92_employee_diff.sql ^| %%PSQL%% -v a=^<snap^> -v b=^<snap^>
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
echo  No source, interim or tenant data was modified by this script.
echo ===========================================================================
pause
exit /b 1
