<#
.SYNOPSIS
    SDA Web-Ready Core: NetworkAssetTracker.ps1 (Agentless Asset Tracker)
.DESCRIPTION
    A powerful, 100% Agentless background scanner that compiles a master map of
    User-to-Computer relationships. It scans Active Directory for all enabled
    Windows 10/11 workstations, pings them to check availability, queries
    the currently logged-on user, and extracts the MAC address for Wake-on-LAN.
.LINKS
    Website: www.servicedeskadvanced.com
    FAQ: SDA.WTF
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$SharedRoot,

    [Parameter(Mandatory=$false)]
    [switch]$IsVisible
)

# ==============================================================================
# 0. SELF-RESPAWN FOR VISIBILITY
# ==============================================================================
# If the API Gateway launched this hidden, respawn it in a visible, dedicated console.
if (-not $IsVisible) {
    $ArgsList = "-ExecutionPolicy Bypass -NoProfile -WindowStyle Normal -File `"$PSCommandPath`" -SharedRoot `"$SharedRoot`" -IsVisible"
    Start-Process "powershell.exe" -ArgumentList $ArgsList
    exit
}

$Host.UI.RawUI.WindowTitle = "SDA - Global Network Asset Tracker"
Clear-Host

# ==============================================================================
# 1. CONFIGURATION & PATH RESOLUTION
# ==============================================================================
if ([string]::IsNullOrWhiteSpace($SharedRoot)) {
    try {
        $ScriptDir = Split-Path -Path $MyInvocation.MyCommand.Path
        $RootFolder = Split-Path -Path $ScriptDir
        $ConfigFile = Join-Path -Path $RootFolder -ChildPath "Config\config.json"

        if (Test-Path $ConfigFile) {
            $Config = Get-Content $ConfigFile -Raw | ConvertFrom-Json
            $SharedRoot = $Config.SharedNetworkRoot
        } else {
            Write-Host " [!] FATAL: Could not locate config.json." -ForegroundColor Red
            Pause; exit
        }
    } catch { Pause; exit }
}

$HistoryFile = Join-Path -Path $SharedRoot -ChildPath "Core\UserHistory.json"
$BackupFile  = Join-Path -Path $SharedRoot -ChildPath "Core\UserHistory.json.bak"
$TempFile    = Join-Path -Path $SharedRoot -ChildPath "Core\UserHistory.json.tmp"

Write-Host "=======================================================" -ForegroundColor Cyan
Write-Host "       [SDA] GLOBAL NETWORK ASSET TRACKER              " -ForegroundColor Cyan
Write-Host "=======================================================" -ForegroundColor Cyan
Write-Host " [i] Architecture: 100% Agentless (Zero-Footprint)" -ForegroundColor DarkGray
Write-Host " [i] Scope: Active Windows 10/11 Workstations" -ForegroundColor DarkGray
Write-Host " [i] Mode: Additive (Preserves existing history)`n" -ForegroundColor DarkGray

# ==============================================================================
# 2. LOAD EXISTING DATABASE (With Composite Key Fix)
# ==============================================================================
$masterDB = @{}
$initialCount = 0

if (Test-Path $HistoryFile) {
    Write-Host " [1/4] Loading existing telemetry database..." -ForegroundColor White

    # Backup if the file is healthy (>100 bytes).
    if ((Get-Item $HistoryFile).Length -gt 100) {
        Copy-Item -Path $HistoryFile -Destination $BackupFile -Force
    }

    try {
        $raw = Get-Content $HistoryFile -Raw | ConvertFrom-Json -ErrorAction Stop
        if ($raw -isnot [System.Array]) { $raw = @($raw) }

        foreach ($entry in $raw) {
            # The Key is "User-Computer" to prevent overwriting PC1 with PC2
            if ($entry.User -and $entry.Computer) {
                $uniqueKey = "$($entry.User)-$($entry.Computer)"
                $masterDB[$uniqueKey] = $entry
            }
        }
        $initialCount = $masterDB.Count
        Write-Host "       [OK] Loaded $initialCount historical entries." -ForegroundColor Green
    } catch {
        Write-Host "       [FATAL] Could not read existing history. Aborting to protect data." -ForegroundColor Red
        Pause; exit
    }
} else {
    Write-Host " [1/4] No existing database found. Starting fresh." -ForegroundColor Yellow
}

# ==============================================================================
# 3. GET COMPUTERS (Universal Workstation Filter)
# ==============================================================================
Write-Host "`n [2/4] Fetching Computer List from Active Directory..." -ForegroundColor White

try {
    $filter = "Enabled -eq 'true' -and (OperatingSystem -like '*Windows 10*' -or OperatingSystem -like '*Windows 11*')"
    $computers = Get-ADComputer -Filter $filter -Properties OperatingSystem | Select-Object -ExpandProperty Name
} catch {
    Write-Host "       [ERROR] AD Query Failed. Ensure RSAT is installed." -ForegroundColor Red
    Pause; exit
}

$total = if ($computers) { $computers.Count } else { 0 }

if ($total -eq 0) {
    Write-Host "       [!] No computers found matching scope." -ForegroundColor Yellow
    Pause; exit
}
Write-Host "       [OK] Found $total target workstations." -ForegroundColor Green
Start-Sleep -Seconds 2

# ==============================================================================
# 4. SCAN LOOP (PS 5.1 .NET Ping & MAC Extraction)
# ==============================================================================
Write-Host "`n [3/4] Initiating WMI Telemetry Sweep..." -ForegroundColor White

$count = 0
$newFinds = 0
$updatedFinds = 0
$pingSender = New-Object System.Net.NetworkInformation.Ping

foreach ($pc in $computers) {
    $count++
    $percent = "{0:N0}" -f (($count / $total) * 100)

    # Fast Ping Test (.NET class prevents PS 5.1 WMI terminating errors)
    $isOnline = $false
    try {
        if ($pingSender.Send($pc, 500).Status -eq "Success") { $isOnline = $true }
    } catch {}

    if ($isOnline) {
        try {
            # Quick WMI Query for Logged-in User
            $compInfo = Get-CimInstance -ClassName Win32_ComputerSystem -ComputerName $pc -ErrorAction Stop
            $rawUser = $compInfo.UserName

            if ($rawUser) {
                $cleanUser = ($rawUser -split "\\")[-1].Trim()
                $timeStamp = (Get-Date).ToString("yyyy-MM-dd HH:mm")

                # Extract MAC Address for Wake-on-LAN (Agentless)
                $macAddress = $null
                try {
                    $netAdapter = Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -ComputerName $pc -Filter "IPEnabled = 'True'" -ErrorAction SilentlyContinue | Select-Object -First 1
                    if ($netAdapter) { $macAddress = $netAdapter.MACAddress }
                } catch {}

                # Create the Unique Key
                $scanKey = "$cleanUser-$pc"

                if ($masterDB.ContainsKey($scanKey)) {
                    # --- UPDATE EXISTING ENTRY ---
                    $masterDB[$scanKey].LastSeen = $timeStamp
                    if ($macAddress) { $masterDB[$scanKey].MACAddress = $macAddress }
                    $updatedFinds++
                    Write-Host "       [$percent%] REFRESH: $cleanUser on $pc" -ForegroundColor DarkGray
                }
                else {
                    # --- ADD NEW ENTRY ---
                    $masterDB[$scanKey] = [PSCustomObject]@{
                        User       = $cleanUser
                        Computer   = $pc
                        LastSeen   = $timeStamp
                        Source     = "Agentless-Map"
                        MACAddress = $macAddress
                    }
                    $newFinds++
                    Write-Host "       [$percent%] NEW: $cleanUser found on $pc" -ForegroundColor Cyan
                }
            }
        } catch {}
    }

    # --- ATOMIC AUTO-SAVE (Every 50 items) ---
    if ($count % 50 -eq 0) {
        if ($masterDB.Count -ge $initialCount -and $masterDB.Count -gt 0) {
            try {
                $finalList = @($masterDB.Values | Sort-Object User)
                $jsonOutput = ConvertTo-Json -InputObject $finalList -Depth 3 -Compress -ErrorAction Stop

                # PS 5.1 Single-Item Array Protection
                if ($finalList.Count -eq 1 -and $jsonOutput -notmatch "^\s*\[") {
                    $jsonOutput = "[$jsonOutput]"
                }

                if (-not [string]::IsNullOrWhiteSpace($jsonOutput)) {
                    Set-Content -Path $TempFile -Value $jsonOutput -Force -ErrorAction Stop
                    Move-Item -Path $TempFile -Destination $HistoryFile -Force -ErrorAction Stop
                }
            } catch {}
        }
    }
}

# ==============================================================================
# 5. FINAL ATOMIC SAVE
# ==============================================================================
Write-Host "`n [4/4] Finalizing Database..." -ForegroundColor White

# Final Safety Check: Database should create NEW records, never shrink.
if ($masterDB.Count -ge $initialCount -and $masterDB.Count -gt 0) {
    try {
        $finalList = @($masterDB.Values | Sort-Object User)

        $jsonOutput = ConvertTo-Json -InputObject $finalList -Depth 3 -Compress -ErrorAction Stop

        if ($finalList.Count -eq 1 -and $jsonOutput -notmatch "^\s*\[") {
            $jsonOutput = "[$jsonOutput]"
        }

        if ([string]::IsNullOrWhiteSpace($jsonOutput)) { throw "Generated JSON string was completely empty." }

        Set-Content -Path $TempFile -Value $jsonOutput -Force -ErrorAction Stop
        Move-Item -Path $TempFile -Destination $HistoryFile -Force -ErrorAction Stop

        Write-Host "`n=======================================================" -ForegroundColor Cyan
        Write-Host " [SDA SUCCESS] Network Map Complete!" -ForegroundColor Green
        Write-Host "=======================================================" -ForegroundColor Cyan
        Write-Host "   Total DB Entries: $($masterDB.Count)" -ForegroundColor White
        Write-Host "   New Connections:  $newFinds" -ForegroundColor Cyan
        Write-Host "   Refreshed:        $updatedFinds" -ForegroundColor DarkGray
        Write-Host "`n You may now close this window and return to the console." -ForegroundColor Yellow
    } catch {
        Write-Host "       [ERROR] Could not save file: $($_.Exception.Message)" -ForegroundColor Red
        if (Test-Path $TempFile) { Remove-Item $TempFile -Force -ErrorAction SilentlyContinue }
    }
} else {
    Write-Host "       [PROTECTION] Scan resulted in data loss ($($masterDB.Count) vs $initialCount)." -ForegroundColor Yellow
    Write-Host "       Save aborted. Restoring backup..." -ForegroundColor Yellow
    Copy-Item $BackupFile $HistoryFile -Force
}

Write-Host ""
Pause