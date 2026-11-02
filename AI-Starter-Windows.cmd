<# : batch
@echo off
setlocal
title AI Starter
set "AIS_SELF=%~f0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "iex ([IO.File]::ReadAllText($env:AIS_SELF))"
echo.
pause
exit /b
#>

# ---------------------------------------------------------------------------
# AI Starter voor Windows
#
# Installeert zonder adminrechten:
#   Git (PortableGit), Node.js (LTS), GitHub CLI (gh) en Firebase CLI
# in %LOCALAPPDATA%\AI-Starter en zet ze in het PATH van de gebruiker.
#
# Gebruik in PowerShell:  irm https://fabianb88.github.io/ai-starter/install.ps1 | iex
# Of dubbelklik AI-Starter-Windows.cmd (zelfde script).
#
# Wat al op de computer staat wordt overgeslagen. Opnieuw draaien mag altijd.
# Alles komt van de officiele bronnen (github.com, nodejs.org, npmjs.org)
# en wordt waar mogelijk gecontroleerd met de SHA-256-controlesom.
# ---------------------------------------------------------------------------

& {
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

$AisRoot = Join-Path $env:LOCALAPPDATA 'AI-Starter'
$AisTmp  = Join-Path $AisRoot '_download'
$AisUA   = @{ 'User-Agent' = 'AI-Starter' }

$AisArm = $false
if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64' -or $env:PROCESSOR_ARCHITEW6432 -eq 'ARM64') { $AisArm = $true }
else {
    try { if ((Get-CimInstance Win32_Processor | Select-Object -First 1).Architecture -eq 12) { $AisArm = $true } } catch { }
}

# ---------- hulpfuncties ----------

function Write-AisStep($t) { Write-Host ''; Write-Host "== $t" -ForegroundColor Cyan }
function Write-AisOk($t)   { Write-Host "   OK  $t" -ForegroundColor Green }
function Write-AisInfo($t) { Write-Host "   ..  $t" -ForegroundColor Gray }
function Write-AisWarn($t) { Write-Host "   !!  $t" -ForegroundColor Yellow }

function Get-AisCmd($name) {
    Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
}

function Update-AisSessionPath {
    # Neem het actuele PATH uit het register over, zodat ook een tweede run in hetzelfde venster klopt.
    $m = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $u = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = (@($m, $u) | Where-Object { $_ }) -join ';'
}

function Add-AisSessionPath($dir) {
    if (($env:Path -split ';') -notcontains $dir) { $env:Path = "$dir;$env:Path" }
}

function Add-AisUserPath($dir) {
    # Schrijft rechtstreeks in HKCU (geen admin nodig) en laat %VARIABELEN% in het bestaande PATH intact.
    $key = 'HKCU:\Environment'
    if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
    $raw = (Get-Item $key).GetValue('Path', '', 'DoNotExpandEnvironmentNames')
    $parts = @($raw -split ';' | Where-Object { $_ -ne '' })
    if ($parts -contains $dir) { return }
    $new = (@($parts) + $dir) -join ';'
    New-ItemProperty -Path $key -Name 'Path' -Value $new -PropertyType ExpandString -Force | Out-Null
}

function Get-AisText($url) {
    $c = (Invoke-WebRequest -UseBasicParsing -Uri $url -Headers $AisUA).Content
    if ($c -is [byte[]]) { $c = [Text.Encoding]::UTF8.GetString($c) }
    return [string]$c
}

function Save-AisFile($url, $dest) {
    for ($i = 1; $i -le 3; $i++) {
        try {
            Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $dest -Headers $AisUA
            return
        } catch {
            if ($i -eq 3) { throw "Download mislukt: $url ($($_.Exception.Message))" }
            Start-Sleep -Seconds (3 * $i)
        }
    }
}

function Test-AisHash($file, $sumsText, $fileName) {
    # Zoekt de regel "<sha256>  <bestandsnaam>" en vergelijkt.
    $want = $null
    foreach ($line in ($sumsText -split "`n")) {
        $l = $line.Trim()
        if ($l -match '^([0-9a-fA-F]{64})\s+\*?(.+)$' -and $Matches[2].Trim() -eq $fileName) { $want = $Matches[1]; break }
    }
    if (-not $want) { Write-AisWarn "geen controlesom gevonden voor $fileName, ik ga door zonder controle"; return }
    $have = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
    if ($have -ne $want) { throw "Controlesom klopt niet voor $fileName. Probeer het opnieuw." }
    Write-AisInfo 'controlesom klopt'
}

function Expand-AisZip($zip, $dest) {
    if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    $tar = Join-Path $env:SystemRoot 'System32\tar.exe'
    if (Test-Path $tar) {
        & $tar -xf $zip -C $dest
        if ($LASTEXITCODE -eq 0) { return }
    }
    Expand-Archive -LiteralPath $zip -DestinationPath $dest -Force
}

function Get-AisLatestRelease($repo) {
    # Volgt de doorverwijzing van /releases/latest naar /releases/tag/<versie>.
    # Geen GitHub-API nodig, dus geen limiet als een hele klas tegelijk installeert.
    $r = Invoke-WebRequest -UseBasicParsing -Uri "https://github.com/$repo/releases/latest" -Headers $AisUA
    $u = $null
    try { $u = $r.BaseResponse.ResponseUri.AbsoluteUri } catch { }
    if (-not $u) { try { $u = $r.BaseResponse.RequestMessage.RequestUri.AbsoluteUri } catch { } }
    if (-not $u -or -not ($u -match '/tag/([^/?#]+)')) { throw "Kon de nieuwste versie van $repo niet bepalen." }
    return [pscustomobject]@{ Tag = $Matches[1]; Html = [string]$r.Content }
}

function Confirm-AisDownload($file, $fileName, $sumsUrl, $sumsText) {
    # Controlesom ophalen mislukt: waarschuwen en doorgaan. Controlesom klopt niet: stoppen.
    if (-not $sumsText) {
        try { $sumsText = Get-AisText $sumsUrl } catch { Write-AisWarn 'controlesom niet op te halen, ik ga door zonder controle'; return }
    }
    Test-AisHash $file $sumsText $fileName
}

function Remove-AisDir($dir) {
    if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
}

# ---------- onderdelen ----------

function Install-AisGit {
    Write-AisStep 'Git'
    if (Get-AisCmd 'git.exe') { Write-AisOk "al aanwezig: $(& git.exe --version)"; return }

    $suffix = if ($AisArm) { 'arm64' } else { '64-bit' }
    $rel = Get-AisLatestRelease 'git-for-windows/git'
    $tag = $rel.Tag
    if (-not ($tag -match '^v(\d+\.\d+\.\d+)\.windows\.(\d+)$')) { throw "Onbekend versienummer voor Git: $tag" }
    $ver = $Matches[1]
    if ($Matches[2] -ne '1') { $ver = "$ver.$($Matches[2])" }
    $file = "PortableGit-$ver-$suffix.7z.exe"
    $base = "https://github.com/git-for-windows/git/releases/download/$tag"
    $exe  = Join-Path $AisTmp $file

    Write-AisInfo "downloaden: Git $ver"
    Save-AisFile "$base/$file" $exe
    # Git for Windows zet de controlesommen in een tabel op de releasepagina.
    $mm = [regex]::Match($rel.Html, [regex]::Escape($file) + '[\s\S]{0,300}?\b([0-9a-f]{64})\b')
    if ($mm.Success) { Test-AisHash $exe "$($mm.Groups[1].Value)  $file" $file }
    else { Write-AisWarn 'controlesom niet gevonden op de releasepagina, ik ga door zonder controle' }

    $dest = Join-Path $AisRoot 'git'
    Remove-AisDir $dest
    Write-AisInfo 'uitpakken (kan een minuut duren)'
    $p = Start-Process -FilePath $exe -ArgumentList @("-o`"$dest`"", '-y') -Wait -PassThru -WindowStyle Hidden
    if ($p.ExitCode -ne 0 -or -not (Test-Path (Join-Path $dest 'cmd\git.exe'))) { throw 'Uitpakken van Git is mislukt.' }

    # Eenmalige nabehandeling die Git Bash anders bij de eerste start doet.
    if (Test-Path (Join-Path $dest 'post-install.bat')) {
        try {
            $pp = Start-Process -FilePath (Join-Path $dest 'git-bash.exe') `
                -ArgumentList '--no-needs-console', '--hide', '--no-cd', '--command=post-install.bat' `
                -WorkingDirectory $dest -PassThru -WindowStyle Hidden
            if (-not $pp.WaitForExit(180000)) { try { $pp.Kill() } catch { } }
        } catch { Write-AisWarn 'nabehandeling van Git overgeslagen (Git werkt wel)' }
    }

    $cmdDir = Join-Path $dest 'cmd'
    Add-AisUserPath $cmdDir
    Add-AisSessionPath $cmdDir

    # Claude Code op Windows heeft Git Bash nodig; zo vindt het de portable versie.
    if (-not [Environment]::GetEnvironmentVariable('CLAUDE_CODE_GIT_BASH_PATH', 'User')) {
        [Environment]::SetEnvironmentVariable('CLAUDE_CODE_GIT_BASH_PATH', (Join-Path $dest 'bin\bash.exe'), 'User')
    }
    Write-AisOk "geinstalleerd: $(& (Join-Path $cmdDir 'git.exe') --version)"
}

function Get-AisNodeMajor {
    $c = Get-AisCmd 'node.exe'
    if (-not $c) { return 0 }
    try { $v = & $c.Source -v; if ($v -match '^v(\d+)\.') { return [int]$Matches[1] } } catch { }
    return 0
}

function Install-AisNode {
    Write-AisStep 'Node.js'
    $major = Get-AisNodeMajor
    if ($major -ge 20) { Write-AisOk "al aanwezig: node $(& node.exe -v)"; return }
    if ($major -gt 0) { Write-AisWarn "oude Node.js gevonden (v$major), ik zet een actuele LTS-versie ernaast" }

    $plat = if ($AisArm) { 'win-arm64' } else { 'win-x64' }
    $idx = Invoke-RestMethod -UseBasicParsing -Uri 'https://nodejs.org/dist/index.json' -Headers $AisUA
    $rel = $idx | Where-Object { $_.lts -and ($_.files -contains "$plat-zip") } | Select-Object -First 1
    if (-not $rel) { throw 'Geen geschikte Node.js LTS-versie gevonden.' }

    $v = $rel.version
    $name = "node-$v-$plat"
    $zip = Join-Path $AisTmp "$name.zip"
    Write-AisInfo "downloaden: Node.js $v"
    Save-AisFile "https://nodejs.org/dist/$v/$name.zip" $zip
    Confirm-AisDownload $zip "$name.zip" "https://nodejs.org/dist/$v/SHASUMS256.txt"

    $x = Join-Path $AisTmp 'node-x'
    Write-AisInfo 'uitpakken'
    Expand-AisZip $zip $x
    $dest = Join-Path $AisRoot 'node'
    Remove-AisDir $dest
    Move-Item -LiteralPath (Join-Path $x $name) -Destination $dest

    # Globale npm-pakketten (zoals firebase-tools) binnen de starter-map houden.
    $npmGlobal = Join-Path $AisRoot 'npm'
    New-Item -ItemType Directory -Force -Path $npmGlobal | Out-Null
    [IO.File]::WriteAllText((Join-Path $dest 'node_modules\npm\npmrc'), "prefix=$npmGlobal`r`n")

    Add-AisUserPath $dest
    Add-AisUserPath $npmGlobal
    Add-AisSessionPath $npmGlobal
    Add-AisSessionPath $dest
    if ($major -gt 0) { Write-AisWarn 'de oude versie kan in nieuwe vensters nog voorgaan; vraag dan IT om die te verwijderen' }
    Write-AisOk "geinstalleerd: node $(& (Join-Path $dest 'node.exe') -v)"
}

function Install-AisGh {
    Write-AisStep 'GitHub CLI'
    if (Get-AisCmd 'gh.exe') { Write-AisOk "al aanwezig: $(& gh.exe --version | Select-Object -First 1)"; return }

    $arch = if ($AisArm) { 'arm64' } else { 'amd64' }
    $tag = (Get-AisLatestRelease 'cli/cli').Tag
    $ver = $tag.TrimStart('v')
    $file = "gh_${ver}_windows_$arch.zip"
    $base = "https://github.com/cli/cli/releases/download/$tag"
    $zip = Join-Path $AisTmp $file

    Write-AisInfo "downloaden: GitHub CLI $ver"
    Save-AisFile "$base/$file" $zip
    Confirm-AisDownload $zip $file "$base/gh_${ver}_checksums.txt"

    $x = Join-Path $AisTmp 'gh-x'
    Expand-AisZip $zip $x
    $dest = Join-Path $AisRoot 'gh'
    Remove-AisDir $dest
    Move-Item -LiteralPath $x -Destination $dest
    $exe = Get-ChildItem -LiteralPath $dest -Recurse -Filter 'gh.exe' | Select-Object -First 1
    if (-not $exe) { throw 'gh.exe niet gevonden in de download.' }

    Add-AisUserPath $exe.DirectoryName
    Add-AisSessionPath $exe.DirectoryName
    Write-AisOk "geinstalleerd: $(& $exe.FullName --version | Select-Object -First 1)"
}

function Install-AisFirebase {
    Write-AisStep 'Firebase CLI'
    if (Get-AisCmd 'firebase.cmd') { Write-AisOk "al aanwezig: firebase $(& firebase.cmd --version)"; return }
    $npm = Get-AisCmd 'npm.cmd'
    if (-not $npm) { throw 'npm niet gevonden, dus Firebase kan niet worden geinstalleerd (Node.js is niet gelukt).' }

    $npmGlobal = Join-Path $AisRoot 'npm'
    New-Item -ItemType Directory -Force -Path $npmGlobal | Out-Null
    Write-AisInfo 'installeren via npm (1 tot 3 minuten)'
    & $npm.Source install -g firebase-tools --prefix "$npmGlobal" --no-fund --no-audit --no-update-notifier --loglevel=error
    if ($LASTEXITCODE -ne 0) { throw 'npm install firebase-tools is mislukt.' }

    Add-AisUserPath $npmGlobal
    Add-AisSessionPath $npmGlobal
    Write-AisOk "geinstalleerd: firebase $(& (Join-Path $npmGlobal 'firebase.cmd') --version)"
}

function Set-AisGitIdentity {
    $git = Get-AisCmd 'git.exe'
    if (-not $git) { return }
    Write-AisStep 'Git instellen'
    $name = & $git.Source config --global user.name
    if (-not $name) {
        $n = Read-Host '   Je volledige naam voor Git (Enter = overslaan)'
        if ($n) { & $git.Source config --global user.name "$n" }
    } else { Write-AisOk "naam: $name" }
    $mail = & $git.Source config --global user.email
    if (-not $mail) {
        $e = Read-Host '   Je e-mailadres voor Git, liefst hetzelfde als op GitHub (Enter = overslaan)'
        if ($e) { & $git.Source config --global user.email "$e" }
    } else { Write-AisOk "e-mail: $mail" }
    if (-not (& $git.Source config --global init.defaultBranch)) { & $git.Source config --global init.defaultBranch main }
}

function Invoke-AisLogins {
    Write-AisStep 'Inloggen (optioneel, kan later ook)'
    if (Get-AisCmd 'gh.exe') {
        $a = Read-Host '   Nu inloggen bij GitHub? (j/n)'
        if ($a -match '^[jJyY]') { & gh.exe auth login --hostname github.com --git-protocol https --web }
    }
    if (Get-AisCmd 'firebase.cmd') {
        $b = Read-Host '   Nu inloggen bij Firebase met je Google-account? (j/n)'
        if ($b -match '^[jJyY]') { & firebase.cmd login }
    }
}

function Show-AisSummary {
    Write-AisStep 'Overzicht'
    $all = $true
    $checks = @(
        @('Git',          'git.exe',      '--version'),
        @('Node.js',      'node.exe',     '-v'),
        @('npm',          'npm.cmd',      '-v'),
        @('GitHub CLI',   'gh.exe',       '--version'),
        @('Firebase CLI', 'firebase.cmd', '--version')
    )
    foreach ($c in $checks) {
        $cmd = Get-AisCmd $c[1]
        if ($cmd) {
            $out = & $cmd.Source $c[2] | Select-Object -First 1
            Write-AisOk ('{0,-13} {1}' -f $c[0], $out)
        } else {
            Write-AisWarn "$($c[0]) ontbreekt"
            $all = $false
        }
    }
    return $all
}

function Invoke-AisMain {
    Write-Host ''
    Write-Host 'AI Starter: Git, Node.js, GitHub CLI en Firebase CLI' -ForegroundColor Cyan
    Write-Host "Installatiemap: $AisRoot (geen adminrechten nodig)"

    Update-AisSessionPath
    New-Item -ItemType Directory -Force -Path $AisTmp | Out-Null

    foreach ($step in @('Install-AisGit', 'Install-AisNode', 'Install-AisGh', 'Install-AisFirebase')) {
        try { & $step } catch { Write-AisWarn $_.Exception.Message }
    }

    # Deze variabele zetten via .NET stuurt Windows ook het seintje dat het PATH is gewijzigd.
    [Environment]::SetEnvironmentVariable('AI_STARTER_HOME', $AisRoot, 'User')
    try { Remove-AisDir $AisTmp } catch { }

    Set-AisGitIdentity
    Invoke-AisLogins
    $ok = Show-AisSummary

    Write-Host ''
    if ($ok) {
        Write-Host 'Klaar. Open een NIEUW terminalvenster (en herstart VS Code) zodat alles gevonden wordt.' -ForegroundColor Green
    } else {
        Write-Host 'Niet alles is gelukt. Draai dit bestand gerust opnieuw: wat al staat wordt overgeslagen.' -ForegroundColor Yellow
        Write-Host 'Lukt het dan nog niet, maak een schermafbeelding van dit venster en stuur die naar wie je deze link gaf.' -ForegroundColor Yellow
    }
}

Invoke-AisMain
}
