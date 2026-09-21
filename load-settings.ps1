<#
    load-settings.ps1 - reads settings.local.txt into a hashtable.

    Dot-source it, then call Import-PiproSettings:

        . "$PSScriptRoot\load-settings.ps1"
        $cfg = Import-PiproSettings
        $cfg['INTERIM_HOST']

    Use Get-PiproSetting for a value that must be present - it reports which
    name is missing rather than failing later with an empty connection string.
#>

function Import-PiproSettings
{
    param([string]$Path = (Join-Path $PSScriptRoot 'settings.local.txt'))

    if (-not (Test-Path $Path)) {
        Write-Host ""
        Write-Host "==> No settings file at $Path" -ForegroundColor Red
        Write-Host "    Copy settings.example.txt to settings.local.txt and fill in your" -ForegroundColor Yellow
        Write-Host "    own database details. It is gitignored, so it stays on your machine." -ForegroundColor Yellow
        Write-Host ""
        exit 1
    }

    $settings = @{}

    foreach ($line in Get-Content $Path) {
        $trimmed = $line.Trim()
        if (($trimmed -eq '') -or $trimmed.StartsWith('#')) { continue }

        $split = $trimmed.IndexOf('=')
        if ($split -lt 1) { continue }

        $settings[$trimmed.Substring(0, $split).Trim()] = $trimmed.Substring($split + 1).Trim()
    }

    return $settings
}


function Get-PiproSetting
{
    param(
        [hashtable]$Settings,
        [string]$Name,
        [switch]$AllowEmpty
    )

    $value = $Settings[$Name]

    if ((-not $AllowEmpty) -and [string]::IsNullOrWhiteSpace($value)) {
        Write-Host "==> settings.local.txt is missing a value for $Name" -ForegroundColor Red
        Write-Host "    See settings.example.txt for what it should contain." -ForegroundColor Yellow
        exit 1
    }

    return $value
}
