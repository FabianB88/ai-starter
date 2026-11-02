# Verwijdert alles wat de AI Starter heeft geinstalleerd.
# Gebruik in PowerShell:  irm https://fabianb88.github.io/ai-starter/uninstall.ps1 | iex
# Git-instellingen (naam, e-mail) en logins bij GitHub en Firebase blijven staan.

& {
$ErrorActionPreference = 'Stop'
$root = Join-Path $env:LOCALAPPDATA 'AI-Starter'

Write-Host ''
Write-Host 'AI Starter verwijderen' -ForegroundColor Cyan
Write-Host "Map: $root"
$a = Read-Host 'Weet je het zeker? (j/n)'
if ($a -notmatch '^[jJyY]') { Write-Host 'Afgebroken.'; return }

$key = 'HKCU:\Environment'
if (Test-Path $key) {
    $raw = (Get-Item $key).GetValue('Path', '', 'DoNotExpandEnvironmentNames')
    $keep = @($raw -split ';' | Where-Object { $_ -and -not $_.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) })
    New-ItemProperty -Path $key -Name 'Path' -Value ($keep -join ';') -PropertyType ExpandString -Force | Out-Null
}

$bash = [Environment]::GetEnvironmentVariable('CLAUDE_CODE_GIT_BASH_PATH', 'User')
if ($bash -and $bash.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
    [Environment]::SetEnvironmentVariable('CLAUDE_CODE_GIT_BASH_PATH', $null, 'User')
}
# Via .NET verwijderen stuurt Windows ook het seintje dat het PATH is gewijzigd.
[Environment]::SetEnvironmentVariable('AI_STARTER_HOME', $null, 'User')

if (Test-Path $root) {
    try { Remove-Item $root -Recurse -Force }
    catch { Write-Host 'Niet alles kon worden verwijderd. Sluit open terminals en VS Code en probeer opnieuw.' -ForegroundColor Yellow; return }
}
Write-Host 'Verwijderd. Open een nieuw terminalvenster.' -ForegroundColor Green
}
