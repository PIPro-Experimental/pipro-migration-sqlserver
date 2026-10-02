<#
    load-manifest.ps1 - reads and VALIDATES payrolls.csv.

    Dot-source it, then call Import-PiproManifest:

        . "$PSScriptRoot\load-manifest.ps1"
        $rows = Import-PiproManifest -TenantSlug acme

    Every value in the manifest was typed by a human, so nothing here is taken on
    trust that can be checked. The checks below are the ones that can be made
    before touching a database; the payroll NUMBER is verified against the data
    itself after each refresh, in convert.ps1.
#>

$script:ManifestColumns = @(
    'source_db','company_schema','payroll_schema','tenant_slug',
    'target_payroll_id','legacy_payroll_number','role','tax_year'
)

function Import-PiproManifest
{
    param(
        [string]$Path = (Join-Path $PSScriptRoot 'payrolls.csv'),
        [string]$TenantSlug
    )

    if (-not (Test-Path $Path)) {
        Write-Host ""
        Write-Host "==> No manifest at $Path" -ForegroundColor Red
        Write-Host "    Copy payrolls.example.csv to payrolls.csv and edit it." -ForegroundColor Yellow
        Write-Host ""
        exit 1
    }

    # Strip comments and blanks before handing it to the CSV parser, so the file
    # can carry its own documentation.
    $lines = Get-Content $Path | Where-Object { $_ -match '\S' -and $_.TrimStart() -notmatch '^#' }
    if ($lines.Count -lt 2) {
        Write-Host "==> $Path has a header but no rows." -ForegroundColor Red
        exit 1
    }

    $rows = $lines | ConvertFrom-Csv
    foreach ($col in $script:ManifestColumns) {
        if ($rows[0].PSObject.Properties.Name -notcontains $col) {
            Write-Host "==> Manifest is missing the '$col' column." -ForegroundColor Red
            Write-Host "    Expected: $($script:ManifestColumns -join ', ')" -ForegroundColor Yellow
            exit 1
        }
    }

    # Trim everything once, so no check has to think about whitespace.
    foreach ($r in $rows) {
        foreach ($col in $script:ManifestColumns) { $r.$col = ([string]$r.$col).Trim() }
    }

    if ($TenantSlug) {
        $rows = @($rows | Where-Object { $_.tenant_slug -eq $TenantSlug })
        if ($rows.Count -eq 0) {
            Write-Host "==> No manifest rows for tenant '$TenantSlug'." -ForegroundColor Red
            exit 1
        }
    }

    $problems = New-Object System.Collections.Generic.List[string]

    foreach ($r in $rows) {
        $where = "row '$($r.source_db)'"

        foreach ($col in @('source_db','company_schema','payroll_schema','tenant_slug',
                           'target_payroll_id','legacy_payroll_number','role')) {
            if (-not $r.$col) { $problems.Add("${where}: $col is empty") }
        }

        if ($r.role -notin @('current','history')) {
            $problems.Add("${where}: role must be 'current' or 'history', not '$($r.role)'")
        }
        if ($r.role -eq 'history' -and -not $r.tax_year) {
            $problems.Add("${where}: a history row needs a tax_year")
        }
        if ($r.role -eq 'current' -and $r.tax_year) {
            $problems.Add("${where}: a current row must not carry a tax_year")
        }
        if ($r.target_payroll_id -and $r.target_payroll_id -notmatch '^\d+$') {
            $problems.Add("${where}: target_payroll_id '$($r.target_payroll_id)' is not a number")
        }
        if ($r.legacy_payroll_number -and $r.legacy_payroll_number -notmatch '^\d+$') {
            $problems.Add("${where}: legacy_payroll_number '$($r.legacy_payroll_number)' is not a number")
        }
        # A schema literally named 'pipro' shadows 'public' for the app's own
        # 'pipro' user and makes every tenant appear to vanish.
        foreach ($col in @('company_schema','payroll_schema')) {
            if ($r.$col -eq 'pipro') {
                $problems.Add("${where}: $col must not be 'pipro' - it shadows 'public' for the app's database user")
            }
            if ($r.$col -and $r.$col -notmatch '^[a-z_][a-z0-9_]*$') {
                $problems.Add("${where}: $col '$($r.$col)' is not a plain lowercase schema name")
            }
        }
        if ($r.company_schema -and $r.company_schema -eq $r.payroll_schema) {
            $problems.Add("${where}: company_schema and payroll_schema must differ")
        }
    }

    # Cross-row uniqueness. Each of these would otherwise destroy data quietly:
    # two rows sharing a schema means the second refresh overwrites the first,
    # and two rows sharing a target payroll means the second import lands on top
    # of the first.
    function Add-DuplicateProblem($rows, $keyName, $selector) {
        $rows | Group-Object -Property $selector | Where-Object { $_.Count -gt 1 } | ForEach-Object {
            $problems.Add("duplicate $keyName '$($_.Name)' in $($_.Count) rows - each must be unique")
        }
    }
    Add-DuplicateProblem $rows 'company_schema' { $_.company_schema }
    Add-DuplicateProblem $rows 'payroll_schema' { $_.payroll_schema }
    Add-DuplicateProblem $rows 'source_db'      { $_.source_db }

    # Within one tenant: a payroll id and a legacy payroll number each identify
    # one payroll, so neither may repeat among the CURRENT rows. History rows
    # legitimately reuse both (they describe the same payroll in an earlier year).
    $current = @($rows | Where-Object { $_.role -eq 'current' })
    Add-DuplicateProblem $current 'tenant/target_payroll_id'     { "$($_.tenant_slug)/$($_.target_payroll_id)" }
    Add-DuplicateProblem $current 'tenant/legacy_payroll_number' { "$($_.tenant_slug)/$($_.legacy_payroll_number)" }

    # History rows: one row per (tenant, payroll, tax year).
    $history = @($rows | Where-Object { $_.role -eq 'history' })
    Add-DuplicateProblem $history 'tenant/payroll/tax_year' {
        "$($_.tenant_slug)/$($_.legacy_payroll_number)/$($_.tax_year)"
    }

    # A history row must describe a payroll that is actually being converted.
    foreach ($h in $history) {
        if (-not ($current | Where-Object {
                $_.tenant_slug -eq $h.tenant_slug -and
                $_.legacy_payroll_number -eq $h.legacy_payroll_number })) {
            $problems.Add("row '$($h.source_db)': history for payroll $($h.legacy_payroll_number) but that payroll has no 'current' row")
        }
    }

    # Contiguous tax years per payroll - a gap usually means a missing backup.
    foreach ($g in ($history | Group-Object { "$($_.tenant_slug)/$($_.legacy_payroll_number)" })) {
        $years = @($g.Group | ForEach-Object { [int]$_.tax_year } | Sort-Object)
        for ($i = 1; $i -lt $years.Count; $i++) {
            if ($years[$i] -ne $years[$i-1] + 1) {
                $problems.Add("payroll $($g.Name): tax years jump from $($years[$i-1]) to $($years[$i]) - a year is missing")
            }
        }
    }

    if ($problems.Count -gt 0) {
        Write-Host ""
        Write-Host "==> $Path has $($problems.Count) problem(s):" -ForegroundColor Red
        $problems | ForEach-Object { Write-Host "    - $_" -ForegroundColor Yellow }
        Write-Host ""
        exit 1
    }

    return $rows
}
