<#
    compare_report.ps1 - the master-data parity report for a whole tenant, one
    payroll at a time, driven by payrolls.csv. READ-ONLY apart from the compare
    schema (and the compare.legacy_* staging tables the export rebuilds).

    Usage:
      powershell -ExecutionPolicy Bypass -File compare_report.ps1 -TenantSlug tau
      powershell -ExecutionPolicy Bypass -File compare_report.ps1 -TenantSlug tau -Phase after

    Per payroll, in manifest order, with snapshots labelled <system>-<phase>-p<payroll>:
      1. export-legacy.ps1  SQL Server (the row's source_db) -> legacy-<phase>-pN
      2. 90 employee map    this payroll's rows only
      3. 91 interim         -> interim-<phase>-pN
      4. 91 pipro           -> pipro-<phase>-pN   (this payroll's employees only)
      5. 92 hop 1           legacy vs interim
      6. 92 end to end      legacy vs pipro
         (each also checks the promoted values against the employee columns)
    A payroll is finished before the next starts: 93 rebuilds compare.promoted_ordinal
    from the database exported last, and the diffs read it.

    The full output of each payroll goes to reports\<tenant>-<phase>-p<N>.txt
    (gitignored: it names employees). The console gets the verdict summaries.

    compare_report.cmd remains the single-payroll version driven by settings.local.txt.
#>
param(
    [Parameter(Mandatory = $true)][string]$TenantSlug,
    [ValidateSet('before','after')][string]$Phase = 'before',
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

cmd /c "docker info >nul 2>&1"
if ($LASTEXITCODE -ne 0) { Write-Host "`n==> Docker is not running. Start Docker Desktop, then re-run.`n" -ForegroundColor Yellow; exit 1 }

$rows = if ($ManifestPath) { Import-PiproManifest -Path $ManifestPath -TenantSlug $TenantSlug }
        else               { Import-PiproManifest -TenantSlug $TenantSlug }
$current = @($rows | Where-Object { $_.role -eq 'current' })

# From here on, failures are judged by exit codes: psql writes NOTICEs to stderr,
# which 'Stop' would turn into a terminating error on Windows PowerShell 5.1.
$ErrorActionPreference = 'Continue'

$reportDir = Join-Path $PSScriptRoot 'reports'
New-Item -ItemType Directory -Force -Path $reportDir | Out-Null

# Runs one SQL file through psql in the container; output is appended to the log.
function Invoke-Report([string]$Script, [string[]]$Vars, [string]$Log) {
    $pargs = @('exec','-i','-e',"PGPASSWORD=$dockerPassword",$dockerContainer,'psql','-U',$dockerUser,'-d',$dockerDb,'-v','ON_ERROR_STOP=on','-P','pager=off')
    foreach ($v in $Vars) { $pargs += @('-v', $v) }
    $out = Get-Content (Join-Path $PSScriptRoot $Script) -Raw | & docker @pargs 2>&1 | ForEach-Object { "$_" }
    $ok = ($LASTEXITCODE -eq 0)
    Add-Content -Path $Log -Value $out -Encoding UTF8
    return @{ Ok = $ok; Out = $out }
}

function Get-Verdicts([string]$A, [string]$B) {
    $q = "SELECT bank || ' ' || verdict || ' ' || count(*) FROM compare.value_diff WHERE snap_a = '$A' AND snap_b = '$B' GROUP BY bank, verdict ORDER BY bank, verdict"
    (& docker exec -e "PGPASSWORD=$dockerPassword" $dockerContainer psql -U $dockerUser -d $dockerDb -t -A -c $q) -join '  |  '
}

# The promoted slots (category, gender, ID number, passport) are 'promoted' in the
# verdicts above - excluded, not checked. This is the check: legacy slot against
# the employee column it became (92 section 6).
function Get-PromotedVerdicts([string]$A, [string]$B) {
    $q = "SELECT field || ' ' || verdict || ' ' || count(*) FROM compare.promoted_diff('$A','$B') GROUP BY field, verdict ORDER BY field, verdict"
    (& docker exec -e "PGPASSWORD=$dockerPassword" $dockerContainer psql -U $dockerUser -d $dockerDb -t -A -c $q) -join '  |  '
}

Write-Host ""
Write-Host "===========================================================================" -ForegroundColor Cyan
Write-Host " PARITY REPORT  $tenantSchema   phase: $Phase   ($($current.Count) payrolls, read-only)" -ForegroundColor Cyan
Write-Host "===========================================================================" -ForegroundColor Cyan

$failed = $false
foreach ($r in $current) {
    $schema = $r.company_schema
    $found  = (& docker exec -e "PGPASSWORD=$dockerPassword" $dockerContainer psql -U $dockerUser -d $dockerDb -t -A `
                 -c "SELECT string_agg(DISTINCT payroll_f04::text, ',') FROM $schema.employees")
    $p      = ([string]$found).Trim()
    if ($p -notmatch '^\d+$') { Write-Host "==> $schema does not hold exactly one payroll ('$p'). Skipped." -ForegroundColor Red; $failed = $true; continue }
    $legacy  = "legacy-$Phase-p$p"
    $interim = "interim-$Phase-p$p"
    $pipro   = "pipro-$Phase-p$p"
    $log     = Join-Path $reportDir "$TenantSlug-$Phase-p$p.txt"
    Set-Content -Path $log -Value "Parity report $tenantSchema payroll $p ($($r.source_db) / $schema), phase $Phase, $(Get-Date -Format s)" -Encoding UTF8

    Write-Host ""
    Write-Host "--- Payroll $p   $($r.source_db) / $schema ---------------------------------" -ForegroundColor Cyan

    Write-Host "    [1/6] legacy export ($($r.source_db))" -ForegroundColor DarkGray
    $exp = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'export-legacy.ps1') -Phase $Phase -Snap $legacy -SqlDatabase $r.source_db 2>&1 | ForEach-Object { "$_" }
    Add-Content -Path $log -Value $exp -Encoding UTF8
    if ($LASTEXITCODE -ne 0) { Write-Host "    export failed - see $log" -ForegroundColor Red; $failed = $true; continue }

    $steps = @(
        @{ N = '2/6'; Label = 'employee map';       Script = 'sql/90_employee_map.sql';      Vars = @("legacy_company_schema=$schema", "tenant_schema=$tenantSchema") },
        @{ N = '3/6'; Label = "snapshot $interim";  Script = 'sql/91_employee_snapshot.sql'; Vars = @('system=interim', "phase=$Phase", "snap=$interim", "legacy_company_schema=$schema", "tenant_schema=$tenantSchema") },
        @{ N = '4/6'; Label = "snapshot $pipro";    Script = 'sql/91_employee_snapshot.sql'; Vars = @('system=pipro',   "phase=$Phase", "snap=$pipro",   "legacy_company_schema=$schema", "tenant_schema=$tenantSchema") },
        @{ N = '5/6'; Label = 'hop 1: legacy vs interim';    Script = 'sql/92_employee_diff.sql'; Vars = @("a=$legacy", "b=$interim") },
        @{ N = '6/6'; Label = 'end to end: legacy vs pipro'; Script = 'sql/92_employee_diff.sql'; Vars = @("a=$legacy", "b=$pipro") }
    )
    foreach ($s in $steps) {
        Write-Host "    [$($s.N)] $($s.Label)" -ForegroundColor DarkGray
        Add-Content -Path $log -Value "`n=================== [$($s.N)] $($s.Label) ===================" -Encoding UTF8
        $res = Invoke-Report $s.Script $s.Vars $log
        if (-not $res.Ok) {
            Write-Host "    FAILED - see $log" -ForegroundColor Red
            $res.Out | Select-Object -Last 6 | ForEach-Object { Write-Host "      $_" -ForegroundColor Red }
            $failed = $true; break
        }
        if ($s.Script -like '*90_*') {
            $map = & docker exec -e "PGPASSWORD=$dockerPassword" $dockerContainer psql -U $dockerUser -d $dockerDb -t -A `
                     -c "SELECT string_agg(status || ' ' || n, '  |  ' ORDER BY status) FROM (SELECT status, count(*) n FROM compare.employee_map WHERE tenant_schema = '$tenantSchema' AND payroll = $p GROUP BY 1) x"
            Write-Host "          map: $map"
        }
    }
    if ($failed) { continue }
    Write-Host "          hop 1      : $(Get-Verdicts $legacy $interim)"
    Write-Host "          end to end : $(Get-Verdicts $legacy $pipro)"
    Write-Host "          promoted, hop 1      : $(Get-PromotedVerdicts $legacy $interim)"
    Write-Host "          promoted, end to end : $(Get-PromotedVerdicts $legacy $pipro)"
    Write-Host "          full report: $log" -ForegroundColor DarkGray
}

Write-Host ""
if ($failed) { Write-Host "==> Finished WITH FAILURES (see above). Nothing outside the compare schema was modified." -ForegroundColor Red; exit 1 }
Write-Host "==> Finished. PASS = only 'match' and 'promoted' in every line above, and only 'match' in the promoted lines. Nothing outside the compare schema was modified." -ForegroundColor Green
