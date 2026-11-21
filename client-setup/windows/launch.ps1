param(
    [Parameter(Mandatory = $true)]
    [string]$RepoRoot,
    [Parameter(Mandatory = $true)]
    [string]$Username,
    [int]$RamGb = 4,
    [switch]$UseMicrosoftAuth,
    [switch]$AutoJoinServer
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$cfg = Get-Content -Raw -Encoding UTF8 (Join-Path $RepoRoot "config.json") | ConvertFrom-Json

$appBase = Join-Path $env:LOCALAPPDATA "JaToVsechnoPrcam"
$mainDir = Join-Path $appBase "mc-data"
$instanceDir = Join-Path $appBase "instance"
$binDir = Join-Path $appBase "bin"

New-Item -ItemType Directory -Force -Path $mainDir, $instanceDir, $binDir | Out-Null

Write-Host "==========================================================" -ForegroundColor DarkCyan
Write-Host "  $($cfg.server_name) - Priprava a spusteni hry" -ForegroundColor White
Write-Host "  Minecraft $($cfg.mc_version) | NeoForge $($cfg.neoforge_version) | RAM: ${RamGb} GB" -ForegroundColor Gray
Write-Host "==========================================================" -ForegroundColor DarkCyan
Write-Host ""

# 1. Synchronizace modu a konfiguraci
$syncScript = Join-Path $PSScriptRoot "sync-mods.ps1"
& $syncScript -RepoRoot $RepoRoot -InstanceDir $instanceDir

# 2. Stazeni portablemc (open-source Rust spoustec, stahne si sam i Javu 21 a NeoForge!)
$pmcVer = if ($cfg.portablemc_version) { $cfg.portablemc_version } else { "5.0.6" }
$pmcExe = Join-Path $binDir "portablemc.exe"
$pmcVerFile = Join-Path $binDir "portablemc.version"

$needPmc = $true
if ((Test-Path $pmcExe) -and (Test-Path $pmcVerFile)) {
    if ((Get-Content -Raw $pmcVerFile).Trim() -eq $pmcVer) {
        $needPmc = $false
    }
}

if ($needPmc) {
    $zipUrl = "https://github.com/theorzr/portablemc/releases/download/v$pmcVer/portablemc-$pmcVer-windows-x86_64-msvc.zip"
    $tmpZip = Join-Path $env:TEMP "portablemc-$pmcVer.zip"
    $tmpExt = Join-Path $env:TEMP "portablemc-$pmcVer-extract"

    Write-Host "[PMC] Stahuji spoustec portablemc v$pmcVer..." -ForegroundColor Cyan
    Invoke-WebRequest -Uri $zipUrl -OutFile $tmpZip -UseBasicParsing -TimeoutSec 120

    if (Test-Path $tmpExt) { Remove-Item -Recurse -Force $tmpExt }
    Expand-Archive -Path $tmpZip -DestinationPath $tmpExt -Force

    $foundExe = Get-ChildItem -Path $tmpExt -Recurse -Filter "portablemc.exe" -File | Select-Object -First 1
    if (-not $foundExe) {
        throw "V archivu portablemc nebylo nalezeno portablemc.exe!"
    }
    Copy-Item -Force $foundExe.FullName $pmcExe
    Set-Content -Path $pmcVerFile -Value $pmcVer -NoNewline
    Remove-Item -Force $tmpZip -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $tmpExt -ErrorAction SilentlyContinue
    Write-Host "[OK]  portablemc v$pmcVer pripraven." -ForegroundColor Green
}

# 3. Pokud hrac vybral originalni Microsoft ucet, overime prihlaseni
if ($UseMicrosoftAuth) {
    Write-Host "[AUTH] Kontroluji prihlaseni k Microsoft uctu..." -ForegroundColor Cyan
    $authList = & $pmcExe --main-dir $mainDir auth list 2>&1 | Out-String
    if ($authList -notmatch [regex]::Escape($Username)) {
        Write-Host "[AUTH] Oteviram prihlaseni k Microsoft uctu (postupuj dle instrukci v konzoli)..." -ForegroundColor Yellow
        & $pmcExe --main-dir $mainDir auth login
    }
}

# 4. Sestaveni parametru pro portablemc v5.0.6 (overena syntaxe: neoforge::21.1.228 + --mc-dir)
$xmsGb = if ($RamGb -ge 6) { 2 } else { 2 }
$jvmArg = "--jvm-arg=-Xms${xmsGb}G,-Xmx${RamGb}G,-XX:+UseG1GC"
$loaderSpec = "neoforge::$($cfg.neoforge_version)"

$pmcArgs = @(
    "--main-dir", $mainDir,
    "start", $loaderSpec,
    "--mc-dir", $instanceDir,
    "--jvm-policy", "system-then-mojang",
    $jvmArg,
    "-u", $Username
)

if ($UseMicrosoftAuth) {
    $pmcArgs += "-a"
}

if ($AutoJoinServer) {
    $pmcArgs += "--join-server"
    $pmcArgs += $cfg.server_ip
    $pmcArgs += "--join-server-port"
    $pmcArgs += $cfg.server_port.ToString()
}

Write-Host ""
Write-Host "[HRA] Spoustim Minecraft ($loaderSpec) jako '$Username'..." -ForegroundColor Green
Write-Host "      (Pri prvnim spusteni se automaticky stahne Java 21 + Minecraft + NeoForge, trva ~1-2 minuty.)" -ForegroundColor Gray
Write-Host ""

& $pmcExe @pmcArgs
if ($LASTEXITCODE -ne 0) {
    throw "Minecraft skoncil s chybovym kodem $LASTEXITCODE."
}
