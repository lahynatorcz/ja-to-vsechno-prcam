param(
    [Parameter(Mandatory = $true)]
    [string]$RepoRoot,
    [Parameter(Mandatory = $true)]
    [string]$InstanceDir,
    [string]$LocalModsSource = ""
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Write-Step([string]$msg) {
    Write-Host "[SYNC] $msg" -ForegroundColor Cyan
}

function Write-Ok([string]$msg) {
    Write-Host "[OK]   $msg" -ForegroundColor Green
}

function Write-WarnMsg([string]$msg) {
    Write-Host "[WARN] $msg" -ForegroundColor Yellow
}

$configPath = Join-Path $RepoRoot "config.json"
if (-not (Test-Path $configPath)) {
    throw "Chybi soubor config.json na ceste: $configPath"
}
$cfg = Get-Content -Raw -Encoding UTF8 $configPath | ConvertFrom-Json

$lockPath = Join-Path $RepoRoot "modpack\mods-lock.json"
$headers = @{}
if ($cfg.gitlab_read_token -and $cfg.gitlab_read_token.Trim() -ne "") {
    $headers["PRIVATE-TOKEN"] = $cfg.gitlab_read_token.Trim()
}

# 1. Pokud je napojeny GitLab, stahneme nejnovejsi mods-lock.json (auto-update seznamu modu!)
$hasGitlab = ($cfg.gitlab_project_id -and $cfg.gitlab_project_id.ToString().Trim() -ne "")
if ($hasGitlab) {
    $base = $cfg.gitlab_base_url.TrimEnd("/")
    $proj = $cfg.gitlab_project_id.ToString().Trim()
    $rawLockUrl = "$base/api/v4/projects/$proj/repository/files/modpack%2Fmods-lock.json/raw?ref=main"
    try {
        Write-Step "Kontroluji nejnovejsi seznam modu na GitLabu..."
        $tmpLock = Join-Path $env:TEMP "ja-to-vsechno-prcam-mods-lock.json"
        Invoke-WebRequest -Uri $rawLockUrl -Headers $headers -OutFile $tmpLock -UseBasicParsing -TimeoutSec 20
        # Overeni ze jde o validni JSON
        $null = Get-Content -Raw -Encoding UTF8 $tmpLock | ConvertFrom-Json
        Copy-Item -Force $tmpLock $lockPath
        Remove-Item -Force $tmpLock -ErrorAction SilentlyContinue
        Write-Ok "Seznam modu (mods-lock.json) je aktualni z GitLabu."
    } catch {
        Write-WarnMsg "Nepodarilo se stahnout aktualni mods-lock.json z GitLabu ($($_.Exception.Message)). Pouzivam lokalni kopii."
    }
}

if (-not (Test-Path $lockPath)) {
    throw "Chybi modpack\mods-lock.json!"
}

$lock = Get-Content -Raw -Encoding UTF8 $lockPath | ConvertFrom-Json
$modsDir = Join-Path $InstanceDir "mods"
New-Item -ItemType Directory -Force -Path $modsDir | Out-Null

# 2. Volitelny lokalni zdroj modu (pokud nekdo pridal slozku mods-bundle vedle baliku)
if ($LocalModsSource -eq "") {
    $candidate = Join-Path $RepoRoot "mods-bundle"
    if (Test-Path $candidate) {
        $LocalModsSource = $candidate
    }
}

# 3. Smazani starych/vyrazenych .jar souboru
$expectedFiles = @{}
foreach ($m in $lock.mods) {
    $expectedFiles[$m.file.ToLowerInvariant()] = $true
}

$removedCount = 0
Get-ChildItem -Path $modsDir -Filter "*.jar" -File -ErrorAction SilentlyContinue | ForEach-Object {
    if (-not $expectedFiles.ContainsKey($_.Name.ToLowerInvariant())) {
        Write-WarnMsg "Odstranuji vyrazeny mod: $($_.Name)"
        Remove-Item -Force $_.FullName
        $removedCount++
    }
}

# 4. Delta-synchronizace (kontrola SHA256, stazeni jen chybejicich nebo zmenenych)
$total = $lock.mods.Count
$downloaded = 0
$kept = 0
$idx = 0

foreach ($m in $lock.mods) {
    $idx++
    $targetPath = Join-Path $modsDir $m.file
    $needDownload = $true

    if (Test-Path $targetPath) {
        $currentHash = (Get-FileHash -Path $targetPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($currentHash -eq $m.sha256.ToLowerInvariant()) {
            $needDownload = $false
            $kept++
        }
    }

    if (-not $needDownload) {
        continue
    }

    # Zkusime lokalni zdroj pokud existuje
    if ($LocalModsSource -ne "" -and (Test-Path (Join-Path $LocalModsSource $m.file))) {
        $srcFile = Join-Path $LocalModsSource $m.file
        $srcHash = (Get-FileHash -Path $srcFile -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($srcHash -eq $m.sha256.ToLowerInvariant()) {
            Write-Step "[$idx/$total] Kopiruji lokalne: $($m.file)"
            Copy-Item -Force $srcFile $targetPath
            $downloaded++
            continue
        }
    }

    if (-not $hasGitlab) {
        throw "Chybi mod '$($m.file)' a v config.json neni nastaveny gitlab_project_id (ani lokalni slozka mods-bundle)."
    }

    $base = $cfg.gitlab_base_url.TrimEnd("/")
    $proj = $cfg.gitlab_project_id.ToString().Trim()
    $pkg = $cfg.gitlab_package_name
    $ver = $cfg.gitlab_package_version
    $pkgFile = if ($m.package_file) { $m.package_file } else { $m.file }
    $dlUrl = "$base/api/v4/projects/$proj/packages/generic/$pkg/$ver/$pkgFile"
    $tmpFile = "$targetPath.part"

    Write-Step "[$idx/$total] Stahuji z GitLabu: $($m.file)"
    try {
        Invoke-WebRequest -Uri $dlUrl -Headers $headers -OutFile $tmpFile -UseBasicParsing -TimeoutSec 120
    } catch {
        Remove-Item -Force $tmpFile -ErrorAction SilentlyContinue
        throw "Chyba pri stahovani '$($m.file)' z $dlUrl : $($_.Exception.Message)"
    }

    $dlHash = (Get-FileHash -Path $tmpFile -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($dlHash -ne $m.sha256.ToLowerInvariant()) {
        Remove-Item -Force $tmpFile -ErrorAction SilentlyContinue
        throw "SHA256 nesedi u '$($m.file)'! Ocekavano $($m.sha256), stazeno $dlHash."
    }

    Move-Item -Force $tmpFile $targetPath
    $downloaded++
}

Write-Ok "Mody hotove: $kept v poradku, $downloaded stazeno/aktualizovano, $removedCount smazano (celkem $total)."

# 5. Synchronizace overrides (config/, datapacks/, servers.dat)
$overridesDir = Join-Path $RepoRoot "modpack\overrides"
if (Test-Path $overridesDir) {
    Write-Step "Synchronizuji konfigurace (config/, datapacks/, servers.dat)..."
    foreach ($sub in @("config", "datapacks", "kubejs")) {
        $srcSub = Join-Path $overridesDir $sub
        if (Test-Path $srcSub) {
            $dstSub = Join-Path $InstanceDir $sub
            New-Item -ItemType Directory -Force -Path $dstSub | Out-Null
            Copy-Item -Path (Join-Path $srcSub "*") -Destination $dstSub -Recurse -Force
        }
    }
    $srcServers = Join-Path $overridesDir "servers.dat"
    $dstServers = Join-Path $InstanceDir "servers.dat"
    if ((Test-Path $srcServers) -and (-not (Test-Path $dstServers))) {
        Copy-Item -Force $srcServers $dstServers
        Write-Ok "Vytvoren vychozi servers.dat se serverem '$($cfg.server_name)'."
    }
}
