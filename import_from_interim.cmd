@echo off
rem ===========================================================================
rem  import_from_interim.cmd - refresh the docker copy of the interim database,
rem  re-import the employee slots into the tenant, and run the parity report
rem  either side of the import.
rem
rem  Each step pauses afterwards. Read the output, then press a key to go on or
rem  Ctrl+C to abort -- nothing later depends on a step you skip by aborting.
rem
rem  Assumes an existing legacy snapshot named 'legacy-before' (export-legacy.ps1).
rem  The legacy DB is unchanged by this script, so that snapshot stays valid.
rem ===========================================================================
setlocal
cd /d "%~dp0"

set TENANT=tenant_test_airplane
set SOURCE=airplane
rem set DATABASE_WORD=c0sSLn5hPYUJCXMZMs0u

set PSQL=docker exec -i -e PGPASSWORD=pipro-dev-only pipro-postgres psql -U pipro -d pipro -v ON_ERROR_STOP=on

for /f %%d in ('powershell -NoProfile -Command "Get-Date -Format yyyy-MM-dd"') do set CUTOVER=%%d
if not defined CUTOVER (
    echo     Could not derive today's date. Edit this file to set CUTOVER by hand.
    goto :failed
)

echo.
echo ===========================================================================
echo  Tenant : %TENANT%
echo  Source : %SOURCE%   Cutover: %CUTOVER%
echo ===========================================================================

rem --- Step 0 -----------------------------------------------------------------
echo.
echo [0/7] Preflight - docker up, and the legacy baseline snapshot exists.
echo.
docker info >nul 2>&1
if errorlevel 1 (
    echo     Docker is not running. Start Docker Desktop and re-run.
    goto :failed
)
%PSQL% -c "SELECT snap, system, phase, taken_at FROM compare.snapshot ORDER BY system, phase;"
if errorlevel 1 goto :failed
echo.
echo     'legacy-before' must be listed above. If it is not, abort and run:
echo         powershell -ExecutionPolicy Bypass -File export-legacy.ps1 -Phase before
pause

rem --- Step 1 -----------------------------------------------------------------
echo.
echo [1/7] Refresh the docker copy of the interim DB from the desktop Postgres.
echo       PostgresImport writes to the DESKTOP db; everything here reads the
echo       docker copy. Without this the report re-measures the OLD import.
echo.
powershell -ExecutionPolicy Bypass -File .\refresh-interim.ps1
if errorlevel 1 goto :failed
pause

rem --- Step 2 -----------------------------------------------------------------
echo.
echo [2/7] Rebuild the employee key map + integrity report.
echo       PostgresImport re-mints employees.employeeno on every run, so this
echo       MUST be rebuilt after a re-import.
echo.
echo       CHECK SECTION 6 before continuing: it must say the coincidence holds,
echo       with 187 matched. If it does not, the tenant's 'emp-N' ids no longer
echo       line up with the new surrogates and step 5 would mislink employees.
echo       Abort here if so.
echo.
type sql\90_employee_map.sql | %PSQL% -v legacy_company_schema=%SOURCE% -v tenant_schema=%TENANT%
if errorlevel 1 goto :failed
pause

rem --- Step 3 -----------------------------------------------------------------
echo.
echo [3/7] Capture the interim snapshot (pre-run state).
echo.
type sql\91_employee_snapshot.sql | %PSQL% -v system=interim -v phase=before -v snap=interim-before -v legacy_company_schema=%SOURCE% -v tenant_schema=%TENANT%
if errorlevel 1 goto :failed
pause

rem --- Step 4 -----------------------------------------------------------------
echo.
echo [4/7] HOP 1 REPORT - legacy vs interim. Does the import carry every value?
echo.
echo       PASS = only 'match' and 'promoted' rows. The 374 'value_differs' at
echo       ordinals 106/107 (OFFICE and SITE) should now be gone. If they are
echo       still there, the RefNoCode fix has not taken - abort and fix the java
echo       rather than carrying the gap forward into the tenant.
echo.
type sql\92_employee_diff.sql | %PSQL% -v a=legacy-before -v b=interim-before
if errorlevel 1 goto :failed
pause

rem --- Step 5 -----------------------------------------------------------------
echo.
echo ===========================================================================
echo  [5/7] DESTRUCTIVE - deletes every employee_alpha row in %TENANT%
echo        and re-imports them from the refreshed interim copy.
echo.
echo        Needed because 40_employee_slots inserts with ON CONFLICT DO NOTHING,
echo        so the existing blank OFFICE/SITE rows would otherwise survive.
echo        Only the alpha table is touched; the other tables in that script
echo        re-run as no-ops.
echo.
echo        NOTE: this does NOT re-run 10_employees. That script mints users with
echo        no conflict guard, so re-running it on a populated tenant would leave
echo        187 orphan user rows and change nothing else.
echo ===========================================================================
echo.
set /p CONFIRM="Type YES to delete and re-import employee_alpha: "
if /i not "%CONFIRM%"=="YES" (
    echo     Skipped by request. Nothing was changed.
    goto :done
)
%PSQL% -c "DELETE FROM %TENANT%.employee_alpha;"
if errorlevel 1 goto :failed
type sql\40_employee_slots.sql | %PSQL% -v legacy_company_schema=%SOURCE% -v tenant_schema=%TENANT% -v cutover=%CUTOVER% -v system_user_id=1
if errorlevel 1 goto :failed
pause

rem --- Step 6 -----------------------------------------------------------------
echo.
echo [6/7] Re-capture the experimental (pipro) snapshot.
echo.
type sql\91_employee_snapshot.sql | %PSQL% -v system=pipro -v phase=before -v snap=pipro-before -v legacy_company_schema=%SOURCE% -v tenant_schema=%TENANT%
if errorlevel 1 goto :failed
pause

rem --- Step 7 -----------------------------------------------------------------
echo.
echo [7/7] END-TO-END REPORT - legacy vs experimental.
echo.
echo       TARGET: Q 17376 / V 5664 / D 948 all 'match', 563 'promoted',
echo       nothing under 'value_differs', 'only_in_a' or 'only_in_b'.
echo.
type sql\92_employee_diff.sql | %PSQL% -v a=legacy-before -v b=pipro-before
if errorlevel 1 goto :failed

:done
echo.
echo ===========================================================================
echo  Finished. Snapshots kept: legacy-before, interim-before, pipro-before.
echo.
echo  AFTER the pay runs, capture the 'after' side and diff the pairs:
echo    powershell -ExecutionPolicy Bypass -File export-legacy.ps1 -Phase after
echo    ...then 91 with -v phase=after -v snap=pipro-after
echo    ...then 92 with -v a=legacy-before -v b=legacy-after   (what the run touched)
echo    ...then 92 with -v a=legacy-after  -v b=pipro-after    (run parity)
echo ===========================================================================
pause
exit /b 0

:failed
echo.
echo ===========================================================================
echo  FAILED on the step above. Nothing further has run.
echo  Each SQL script is wrapped in a transaction, so a failed step rolled back.
echo ===========================================================================
pause
exit /b 1
