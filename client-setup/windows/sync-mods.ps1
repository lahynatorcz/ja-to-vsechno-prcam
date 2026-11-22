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

function Invoke-GitHubAssetDownload {
    param(
        [Parameter(Mandatory = $true)][string]$AssetApiUrl,
        [Parameter(Mandatory = $true)][string]$OutFile,
        [string]$Token = ""
    )

    $req = [System.Net.HttpWebRequest]::Create($AssetApiUrl)
    $req.Method = "GET"
    $req.AllowAutoRedirect = $false
    $req.Accept = "application/octet-stream"
    $req.UserAgent = "ja-to-vsechno-prcam-client"
    $req.Timeout = 120000
    $req.ReadWriteTimeout = 120000
    $req.Headers.Add("X-GitHub-Api-Version", "2022-11-28")
    if ($Token -ne "") {
        $req.Headers.Add("Authorization", "Bearer $Token")
    }

    $resp = $null
    try {
        try {
            $resp = $req.GetResponse()
        } catch [System.Net.WebException] {
            if ($_.Exception.Response) {
                $resp = $_.Exception.Response
            } else {
                throw
            }
        }

        $code = [int]$resp.StatusCode
        if ($code -in @(301, 302, 303, 307, 308)) {
            $redirectUrl = $resp.Headers["Location"]
            $resp.Close()
            $resp = $null
            if (-not $redirectUrl) {
                throw "GitHub vratil presmerovani ($code) bez hlavicky Location."
            }
            # Podepsana URL (Azure/S3) nesmi dostat GitHub Authorization hlavicku!
            Invoke-WebRequest -Uri $redirectUrl -OutFile $OutFile -UseBasicParsing -TimeoutSec 180
        } elseif ($code -eq 200) {
            $inStream = $resp.GetResponseStream()
            $outStream = [System.IO.File]::Create($OutFile)
            try {
                $inStream.CopyTo($outStream)
            } finally {
                $outStream.Close()
                $inStream.Close()
            }
        } else {
            throw "GitHub vratil HTTP $code pri stahovani assetu."
        }
    } finally {
        if ($resp) { $resp.Close() }
    }
}

$configPath = Join-Path $RepoRoot "config.json"
if (-not (Test-Path $configPath)) {
    throw "Chybi soubor config.json na ceste: $configPath"
}
$cfg = Get-Content -Raw -Encoding UTF8 $configPath | ConvertFrom-Json

$lockPath = Join-Path $RepoRoot "modpack\mods-lock.json"
$ghRepo = if ($cfg.github_repo) { $cfg.github_repo.ToString().Trim() } else { "" }
$ghTag = if ($cfg.github_release_tag) { $cfg.github_release_tag.ToString().Trim() } else { "mods-1.0-bop" }
$ghToken = if ($cfg.github_read_token) { $cfg.github_read_token.ToString().Trim() } else { "" }
if ($ghToken -eq "" -and $env:GITHUB_READ_TOKEN) {
    $ghToken = $env:GITHUB_READ_TOKEN.Trim()
}

$apiHeaders = @{
    "User-Agent"           = "ja-to-vsechno-prcam-client"
    "X-GitHub-Api-Version" = "2022-11-28"
    "Accept"               = "application/vnd.github+json"
}
$rawHeaders = @{
    "User-Agent"           = "ja-to-vsechno-prcam-client"
    "X-GitHub-Api-Version" = "2022-11-28"
    "Accept"               = "application/vnd.github.raw+json"
}
if ($ghToken -ne "") {
    $apiHeaders["Authorization"] = "Bearer $ghToken"
    $rawHeaders["Authorization"] = "Bearer $ghToken"
}

# 1. Pokud je napojeny GitHub, stahneme nejnovejsi mods-lock.json (auto-update seznamu modu!)
$hasGithub = ($ghRepo -ne "")
if ($hasGithub) {
    $rawLockUrl = "https://api.github.com/repos/$ghRepo/contents/modpack/mods-lock.json?ref=main"
    try {
        Write-Step "Kontroluji nejnovejsi seznam modu na GitHubu..."
        $tmpLock = Join-Path $env:TEMP "ja-to-vsechno-prcam-mods-lock.json"
        Invoke-WebRequest -Uri $rawLockUrl -Headers $rawHeaders -OutFile $tmpLock -UseBasicParsing -TimeoutSec 20
        # Overeni ze jde o validni JSON
        $null = Get-Content -Raw -Encoding UTF8 $tmpLock | ConvertFrom-Json
        Copy-Item -Force $tmpLock $lockPath
        Remove-Item -Force $tmpLock -ErrorAction SilentlyContinue
        Write-Ok "Seznam modu (mods-lock.json) je aktualni z GitHubu."
    } catch {
        Write-WarnMsg "Nepodarilo se stahnout aktualni mods-lock.json z GitHubu ($($_.Exception.Message)). Pouzivam lokalni kopii."
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
$assetMap = $null

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

    if (-not $hasGithub) {
        throw "Chybi mod '$($m.file)' a v config.json neni nastaveny github_repo (ani lokalni slozka mods-bundle)."
    }

    # Lazy nacteni seznamu priloh GitHub Release (jen pokud je potreba neco stahovat)
    if ($null -eq $assetMap) {
        Write-Step "Nacitam seznam modu z GitHub Release ($ghRepo @ $ghTag)..."
        $relUrl = "https://api.github.com/repos/$ghRepo/releases/tags/$([System.Uri]::EscapeDataString($ghTag))"
        try {
            $release = Invoke-RestMethod -Uri $relUrl -Headers $apiHeaders -TimeoutSec 30
        } catch {
            throw "Nepodarilo se nacist GitHub Release '$ghTag' z '$ghRepo': $($_.Exception.Message)"
        }

        $assetMap = @{}
        $page = 1
        while ($true) {
            $assetsUrl = "https://api.github.com/repos/$ghRepo/releases/$($release.id)/assets?per_page=100&page=$page"
            $batch = Invoke-RestMethod -Uri $assetsUrl -Headers $apiHeaders -TimeoutSec 30
            if (-not $batch -or $batch.Count -eq 0) { break }
            foreach ($a in $batch) {
                $assetMap[$a.name] = $a.url
            }
            if ($batch.Count -lt 100) { break }
            $page++
        }
    }

    $pkgFile = if ($m.package_file) { $m.package_file } else { $m.file }
    $assetUrl = $assetMap[$pkgFile]
    if (-not $assetUrl) { $assetUrl = $assetMap[$m.file] }
    if (-not $assetUrl) {
        throw "Mod '$($m.file)' ($pkgFile) nebyl nalezen v GitHub Release '$ghTag'!"
    }

    $tmpFile = "$targetPath.part"
    Write-Step "[$idx/$total] Stahuji z GitHubu: $($m.file)"
    try {
        Invoke-GitHubAssetDownload -AssetApiUrl $assetUrl -OutFile $tmpFile -Token $ghToken
    } catch {
        Remove-Item -Force $tmpFile -ErrorAction SilentlyContinue
        throw "Chyba pri stahovani '$($m.file)' z GitHub Release: $($_.Exception.Message)"
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
