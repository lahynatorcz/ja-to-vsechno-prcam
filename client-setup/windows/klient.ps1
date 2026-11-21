# Graficky WPF klient "Ja to vsechno prcam" pro Windows 10/11 (PowerShell 5.1+ bez zavislosti)
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

# Najdeme koren repa (podporuje spusteni z client-setup\windows\ i ze slozky zabaleneho ZIPu)
$scriptDir = $PSScriptRoot
$repoRoot = (Resolve-Path (Join-Path $scriptDir "..\..")).Path
$configPath = Join-Path $repoRoot "config.json"
if (-not (Test-Path $configPath)) {
    [System.Windows.MessageBox]::Show("Nenalezen soubor config.json ($configPath).", "Chyba konfigurace", "OK", "Error") | Out-Null
    exit 1
}

$cfg = Get-Content -Raw -Encoding UTF8 $configPath | ConvertFrom-Json
$appBase = Join-Path $env:LOCALAPPDATA "JaToVsechnoPrcam"
$instanceDir = Join-Path $appBase "instance"
$playerFile = Join-Path $appBase "player.json"
New-Item -ItemType Directory -Force -Path $appBase | Out-Null

# Automaticky vypocet doporucene RAM podle PC
$totalRamGb = 8
try {
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem
    $totalRamGb = [math]::Round($cs.TotalPhysicalMemory / 1GB)
} catch {}

$defaultRam = 4
if ($totalRamGb -ge 20) { $defaultRam = 8 }
elseif ($totalRamGb -ge 12) { $defaultRam = 6 }

# Nacteni ulozeneho profilu hrace
$savedNick = ""
$savedRam = $defaultRam
$savedMsAuth = $false
$savedAutoJoin = $false
if (Test-Path $playerFile) {
    try {
        $p = Get-Content -Raw -Encoding UTF8 $playerFile | ConvertFrom-Json
        if ($p.username) { $savedNick = $p.username }
        if ($p.ram_gb) { $savedRam = [int]$p.ram_gb }
        if ($null -ne $p.use_ms_auth) { $savedMsAuth = [bool]$p.use_ms_auth }
        if ($null -ne $p.auto_join) { $savedAutoJoin = [bool]$p.auto_join }
    } catch {}
}

function Find-TailscaleExe {
    $cmd = Get-Command tailscale.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $candidates = @(
        "C:\Program Files\Tailscale\tailscale.exe",
        "C:\Program Files (x86)\Tailscale\tailscale.exe"
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) { return $c }
    }
    return $null
}

function Test-ServerTcp([string]$ip, [int]$port, [int]$timeoutMs = 1200) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect($ip, $port, $null, $null)
        if ($iar.AsyncWaitHandle.WaitOne($timeoutMs, $false)) {
            $client.EndConnect($iar)
            return $true
        }
        return $false
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Já to všechno prcám — Klient"
        Height="560" Width="540"
        ResizeMode="CanMinimize"
        WindowStartupLocation="CenterScreen"
        Background="#0F172A" Foreground="#F8FAFC"
        FontFamily="Segoe UI">
    <Grid Margin="22">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <!-- Hlavicka -->
        <StackPanel Grid.Row="0" Margin="0,0,0,16">
            <TextBlock x:Name="TxtTitle" Text="Já to všechno prcám" FontSize="24" FontWeight="Bold" Foreground="#F8FAFC"/>
            <TextBlock x:Name="TxtSubtitle" Text="Minecraft 1.21.1 • NeoForge 21.1.228 • Confluence + Biomes O' Plenty" FontSize="12" Foreground="#94A3B8" Margin="0,4,0,0"/>
        </StackPanel>

        <!-- Karta stavu site a serveru -->
        <Border Grid.Row="1" Background="#1E293B" CornerRadius="10" Padding="14" Margin="0,0,0,14" BorderBrush="#334155" BorderThickness="1">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <StackPanel Grid.Column="0">
                    <TextBlock Text="STAV SÍTĚ (TAILSCALE) A SERVERU" FontSize="10" FontWeight="SemiBold" Foreground="#94A3B8"/>
                    <TextBlock x:Name="TxtTsStatus" Text="Kontroluji Tailscale..." FontSize="13" FontWeight="SemiBold" Foreground="#FBBF24" Margin="0,5,0,2"/>
                    <TextBlock x:Name="TxtSrvStatus" Text="Kontroluji server..." FontSize="12" Foreground="#CBD5E1"/>
                </StackPanel>
                <StackPanel Grid.Column="1" VerticalAlignment="Center">
                    <Button x:Name="BtnTailscale" Content="Nastavit Tailscale" Padding="12,7" Margin="0,0,0,6"
                            Background="#2563EB" Foreground="White" BorderThickness="0" FontWeight="SemiBold" Cursor="Hand"/>
                    <Button x:Name="BtnRefresh" Content="Obnovit stav" Padding="12,5"
                            Background="#334155" Foreground="#E2E8F0" BorderThickness="0" FontSize="11" Cursor="Hand"/>
                </StackPanel>
            </Grid>
        </Border>

        <!-- Nastaveni hrace -->
        <Border Grid.Row="2" Background="#1E293B" CornerRadius="10" Padding="14" Margin="0,0,0,14" BorderBrush="#334155" BorderThickness="1">
            <StackPanel>
                <TextBlock Text="NASTAVENÍ HRÁČE" FontSize="10" FontWeight="SemiBold" Foreground="#94A3B8" Margin="0,0,0,10"/>

                <Grid Margin="0,0,0,10">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="120"/>
                    </Grid.ColumnDefinitions>
                    <StackPanel Grid.Column="0" Margin="0,0,12,0">
                        <TextBlock Text="Tvoje přezdívka ve hře (3–16 znaků, bez mezer):" FontSize="12" Foreground="#CBD5E1" Margin="0,0,0,4"/>
                        <TextBox x:Name="InputNick" Height="32" Padding="8,5" FontSize="14"
                                 Background="#0F172A" Foreground="#F8FAFC" BorderBrush="#475569" CaretBrush="White"/>
                    </StackPanel>
                    <StackPanel Grid.Column="1">
                        <TextBlock x:Name="LblRam" Text="RAM pro hru:" FontSize="12" Foreground="#CBD5E1" Margin="0,0,0,4"/>
                        <ComboBox x:Name="ComboRam" Height="32" FontSize="13" VerticalContentAlignment="Center">
                            <ComboBoxItem Content="4 GB" Tag="4"/>
                            <ComboBoxItem Content="6 GB" Tag="6"/>
                            <ComboBoxItem Content="8 GB" Tag="8"/>
                            <ComboBoxItem Content="10 GB" Tag="10"/>
                        </ComboBox>
                    </StackPanel>
                </Grid>

                <CheckBox x:Name="ChkAutoJoin" Content="Připojit mě po startu hry rovnou na server" Foreground="#CBD5E1" Margin="0,2,0,6"/>
                <CheckBox x:Name="ChkMsAuth" Content="Mám koupený originální Minecraft (přihlásit přes Microsoft účet)" Foreground="#94A3B8"/>
            </StackPanel>
        </Border>

        <!-- Hlavni akcni tlacitko + poznamka -->
        <StackPanel Grid.Row="3" VerticalAlignment="Center">
            <Button x:Name="BtnPlay" Content="AKTUALIZOVAT MODY &amp; HRÁT" Height="52"
                    Background="#10B981" Foreground="#052E16" FontSize="16" FontWeight="Bold"
                    BorderThickness="0" Cursor="Hand"/>
            <TextBlock x:Name="TxtHint" Text="Při prvním spuštění se automaticky stáhne Java 21, Minecraft 1.21.1, NeoForge a všechny mody."
                       FontSize="11" Foreground="#94A3B8" TextWrapping="Wrap" TextAlignment="Center" Margin="0,10,0,0"/>
        </StackPanel>

        <!-- Spodni nastrojova lista -->
        <Grid Grid.Row="4" Margin="0,14,0,0">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>
            <Button x:Name="BtnShortcut" Grid.Column="0" Content="Vytvořit ikonu na Plochu" Margin="0,0,6,0" Padding="8,7"
                    Background="#334155" Foreground="#E2E8F0" BorderThickness="0" Cursor="Hand"/>
            <Button x:Name="BtnOpenDir" Grid.Column="1" Content="Otevřít složku hry" Margin="6,0,0,0" Padding="8,7"
                    Background="#334155" Foreground="#E2E8F0" BorderThickness="0" Cursor="Hand"/>
        </Grid>
    </Grid>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

$txtTitle = $window.FindName("TxtTitle")
$txtSubtitle = $window.FindName("TxtSubtitle")
$txtTsStatus = $window.FindName("TxtTsStatus")
$txtSrvStatus = $window.FindName("TxtSrvStatus")
$btnTailscale = $window.FindName("BtnTailscale")
$btnRefresh = $window.FindName("BtnRefresh")
$inputNick = $window.FindName("InputNick")
$lblRam = $window.FindName("LblRam")
$comboRam = $window.FindName("ComboRam")
$chkAutoJoin = $window.FindName("ChkAutoJoin")
$chkMsAuth = $window.FindName("ChkMsAuth")
$btnPlay = $window.FindName("BtnPlay")
$btnShortcut = $window.FindName("BtnShortcut")
$btnOpenDir = $window.FindName("BtnOpenDir")

$txtTitle.Text = $cfg.server_name
$txtSubtitle.Text = "Minecraft $($cfg.mc_version) • NeoForge $($cfg.neoforge_version) • $($cfg.server_ip):$($cfg.server_port)"
$lblRam.Text = "RAM (PC má ${totalRamGb} GB):"
$inputNick.Text = $savedNick
$chkAutoJoin.IsChecked = $savedAutoJoin
$chkMsAuth.IsChecked = $savedMsAuth

foreach ($item in $comboRam.Items) {
    if ([int]$item.Tag -eq $savedRam) {
        $comboRam.SelectedItem = $item
        break
    }
}
if (-not $comboRam.SelectedItem) { $comboRam.SelectedIndex = 0 }

$refreshStatus = {
    $tsExe = Find-TailscaleExe
    if (-not $tsExe) {
        $txtTsStatus.Text = "Tailscale není nainstalovaný"
        $txtTsStatus.Foreground = "#F87171"
        $txtSrvStatus.Text = "Klikni vpravo na 'Nastavit Tailscale' (zabere 1 minutu)."
        $btnTailscale.Content = "Nainstalovat Tailscale"
        return
    }

    $btnTailscale.Content = "Připojit Tailscale"
    $tsIp = ""
    try {
        $tsIp = (& $tsExe ip -4 2>$null | Select-Object -First 1)
    } catch {}

    if ($tsIp -and $tsIp.Trim() -match '^100\.') {
        $txtTsStatus.Text = "Tailscale připojen ($($tsIp.Trim()))"
        $txtTsStatus.Foreground = "#34D399"
    } else {
        $txtTsStatus.Text = "Tailscale nainstalován, ale odpojen / nepřihlášen"
        $txtTsStatus.Foreground = "#FBBF24"
    }

    if (Test-ServerTcp -ip $cfg.server_ip -port ([int]$cfg.server_port)) {
        $txtSrvStatus.Text = "Server ONLINE ($($cfg.server_ip):$($cfg.server_port)) — připraveno ke hře!"
        $txtSrvStatus.Foreground = "#34D399"
    } else {
        $txtSrvStatus.Text = "Server teď neodpovídá na $($cfg.server_ip):$($cfg.server_port) (ověř pozvánku Tailscale / běh serveru)."
        $txtSrvStatus.Foreground = "#FBBF24"
    }
}

$btnRefresh.Add_Click({ & $refreshStatus })

$btnTailscale.Add_Click({
    $tsExe = Find-TailscaleExe
    if (-not $tsExe) {
        $ans = [System.Windows.MessageBox]::Show(
            "Nainstaluji oficiální Tailscale pro Windows (vyžádá si potvrzení správce UAC). Pokračovat?",
            "Instalace Tailscale", "YesNo", "Question"
        )
        if ($ans -ne "Yes") { return }

        $installCmd = @'
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Write-Host "=== Instalace Tailscale ===" -ForegroundColor Cyan
$winget = Get-Command winget -ErrorAction SilentlyContinue
$installed = $false
if ($winget) {
    Write-Host "Zkousim instalaci pres winget..." -ForegroundColor Cyan
    winget install -e --id Tailscale.Tailscale --accept-source-agreements --accept-package-agreements
    if ($LASTEXITCODE -eq 0) { $installed = $true }
}
if (-not $installed) {
    Write-Host "Stahuji oficialni MSI z pkgs.tailscale.com/stable/..." -ForegroundColor Yellow
    $html = (Invoke-WebRequest -Uri "https://pkgs.tailscale.com/stable/" -UseBasicParsing).Content
    $m = [regex]::Match($html, 'tailscale-setup-[0-9\.]+-amd64\.msi')
    if (-not $m.Success) { throw "Nepodarilo se najit MSI odkaz na pkgs.tailscale.com/stable/" }
    $msiUrl = "https://pkgs.tailscale.com/stable/$($m.Value)"
    $msiPath = Join-Path $env:TEMP $m.Value
    Invoke-WebRequest -Uri $msiUrl -OutFile $msiPath -UseBasicParsing
    Write-Host "Spoustim MSI instalator ($($m.Value))..." -ForegroundColor Cyan
    Start-Process msiexec.exe -ArgumentList "/i `"$msiPath`" /passive" -Wait
}
Write-Host "Tailscale nainstalovan! Ted se prosim prihlas v prohlizeci." -ForegroundColor Green
Start-Sleep -Seconds 2
'@
        $tmpScript = Join-Path $env:TEMP "install-tailscale-mc.ps1"
        Set-Content -Path $tmpScript -Value $installCmd -Encoding UTF8
        Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$tmpScript`"" -Wait
        Remove-Item -Force $tmpScript -ErrorAction SilentlyContinue
        $tsExe = Find-TailscaleExe
    }

    if ($tsExe) {
        # Spustime Tailscale GUI a prihlaseni
        $tsGui = "C:\Program Files\Tailscale\tailscale-ipn.exe"
        if (Test-Path $tsGui) {
            Start-Process $tsGui -ErrorAction SilentlyContinue
        }
        Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Command `"& '$tsExe' up`"" -Wait

        if ($cfg.tailscale_share_url -and $cfg.tailscale_share_url.Trim() -ne "") {
            $openShare = [System.Windows.MessageBox]::Show(
                "Pokud jsi jeste neprijal pozvanku na server dell5290, otevru ted zvací odkaz v prohlizeci (staci kliknout na 'Accept invite'). Otevrit?",
                "Pozvanka na server", "YesNo", "Information"
            )
            if ($openShare -eq "Yes") {
                Start-Process $cfg.tailscale_share_url.Trim()
            }
        }
    }
    & $refreshStatus
})

$btnPlay.Add_Click({
    $nick = $inputNick.Text.Trim()
    if ($nick -notmatch '^[A-Za-z0-9_]{3,16}$') {
        [System.Windows.MessageBox]::Show(
            "Zadej platnou přezdívku (3 až 16 znaků, jen písmena bez diakritiky, čísla a podtržítko _).",
            "Neplatná přezdívka", "OK", "Warning"
        ) | Out-Null
        return
    }

    $ramVal = [int]$comboRam.SelectedItem.Tag
    $useMs = [bool]$chkMsAuth.IsChecked
    $autoJoin = [bool]$chkAutoJoin.IsChecked

    $profileObj = [ordered]@{
        username = $nick
        ram_gb = $ramVal
        use_ms_auth = $useMs
        auto_join = $autoJoin
    }
    $profileObj | ConvertTo-Json | Set-Content -Path $playerFile -Encoding UTF8

    $launchScript = Join-Path $scriptDir "launch.ps1"
    $argList = @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-NoExit",
        "-File", "`"$launchScript`"",
        "-RepoRoot", "`"$repoRoot`"",
        "-Username", "`"$nick`"",
        "-RamGb", $ramVal
    )
    if ($useMs) { $argList += "-UseMicrosoftAuth" }
    if ($autoJoin) { $argList += "-AutoJoinServer" }

    Start-Process powershell.exe -ArgumentList ($argList -join " ")
})

$btnShortcut.Add_Click({
    try {
        $desktop = [Environment]::GetFolderPath("Desktop")
        $lnkPath = Join-Path $desktop "Ja to vsechno prcam.lnk"
        $batPath = Join-Path $scriptDir "HRAT.bat"
        $shell = New-Object -ComObject WScript.Shell
        $sc = $shell.CreateShortcut($lnkPath)
        $sc.TargetPath = $batPath
        $sc.WorkingDirectory = $scriptDir
        $sc.Description = "Spustit Minecraft server $($cfg.server_name)"
        $sc.Save()
        [System.Windows.MessageBox]::Show("Zástupce vytvořen na Plochu: $lnkPath", "Hotovo", "OK", "Information") | Out-Null
    } catch {
        [System.Windows.MessageBox]::Show("Nepodařilo se vytvořit zástupce: $($_.Exception.Message)", "Chyba", "OK", "Error") | Out-Null
    }
})

$btnOpenDir.Add_Click({
    New-Item -ItemType Directory -Force -Path $instanceDir | Out-Null
    Start-Process explorer.exe -ArgumentList "`"$instanceDir`""
})

$window.Add_Loaded({ & $refreshStatus })
$null = $window.ShowDialog()
