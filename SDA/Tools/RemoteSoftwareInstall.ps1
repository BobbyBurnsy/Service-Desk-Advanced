<#
.SYNOPSIS
    SDA Web-Ready Tool: RemoteSoftwareInstall.ps1
.DESCRIPTION
    Acts as a backend controller for the Zero-Touch Deployment Library UI.
    Supports single and mass deployments via WinRM and PsExec.
    Includes Wake-on-LAN (WoL) functionality for offline targets.

    PAYLOAD MODEL (PDQ-style):
    Instead of running the installer directly from a UNC path (which fails due to
    the SYSTEM account double-hop auth problem), this script copies the installer
    to C:\Windows\Temp\SDA on the target machine first, then executes it locally.
    This mirrors how PDQ Deploy handles remote installs and is far more reliable.

    TWO-STEP PSEXEC FALLBACK:
    When WinRM is blocked, the script performs a two-step fallback instead of
    handing PsExec a UNC path (which SYSTEM cannot reach):
      Step 1 — The script itself (running as the technician) copies the installer
               directly to \\TARGET\C$\Windows\Temp\SDA\ via the admin share.
               No double-hop problem — you have the credentials, not SYSTEM.
      Step 2 — PsExec then runs as SYSTEM against the already-local file, so it
               never needs to touch the network at all.
    This makes the PsExec fallback just as reliable as the WinRM primary path.
.LINKS
    Website: www.servicedeskadvanced.com
    FAQ: SDA.WTF
#>

param(
    [Parameter(Mandatory=$false, Position=0)]
    [string]$Target,

    [Parameter(Mandatory=$false, Position=1)]
    [string]$TargetUser,

    [Parameter(Mandatory=$false)]
    [string]$SharedRoot,

    [Parameter(Mandatory=$false)]
    [string]$Action = "Install",

    [Parameter(Mandatory=$false)]
    [string]$AppName,

    [Parameter(Mandatory=$false)]
    [string]$AppPath,

    [Parameter(Mandatory=$false)]
    [string]$AppArgs,

    [Parameter(Mandatory=$false)]
    [string]$AppID,

    [Parameter(Mandatory=$false)]
    [switch]$GetTrainingData
)

$ErrorActionPreference = "Continue"

# --- Helper Functions ---
function Escape-Html([string]$s) {
    if ([string]::IsNullOrEmpty($s)) { return "" }
    return $s.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;').Replace("'", '&#39;')
}

if ([string]::IsNullOrWhiteSpace($SharedRoot)) {
    $ScriptDir = Split-Path -Path $MyInvocation.MyCommand.Path
    $SharedRoot = Split-Path -Path $ScriptDir
}

function Send-MagicPacket {
    param([string]$MacAddress)
    try {
        $cleanMac = $MacAddress -replace '[:-]',''
        $macByteArray = [byte[]]($cleanMac -split '(.{2})' -ne '' | ForEach-Object { [convert]::ToByte($_, 16) })
        $magicPacket = [byte[]](,0xFF * 6) + ($macByteArray * 16)

        $udpClient = New-Object System.Net.Sockets.UdpClient
        $udpClient.Connect([System.Net.IPAddress]::Broadcast, 9)
        $udpClient.Send($magicPacket, $magicPacket.Length) | Out-Null
        $udpClient.Close()
        return $true
    } catch { return $false }
}

# -------------------------------------------------------------------------
# HELPER: Two-step PsExec fallback
#
# Step 1: Copy the installer to the target via the C$ admin share.
#         This runs as the technician (you), so Kerberos auth works fine.
#         The destination mirrors the WinRM staging path so the payload
#         script is identical regardless of which path got it there.
# Step 2: PsExec launches the local-execute-only payload as SYSTEM.
#         By this point the installer is already on disk, so SYSTEM never
#         touches the network — no double-hop, no auth failure.
#
# Returns: $true on success, $false on any failure.
# -------------------------------------------------------------------------
function Invoke-PsExecFallback {
    param(
        [string]$TargetPC,
        [string]$SourcePath,
        [string]$FileName,
        [string]$PsExecPath,
        [string]$EncodedCommand
    )

    # Step 1: Pre-stage via admin share (runs as technician, not SYSTEM)
    $adminShareDest = "\\$TargetPC\C$\Windows\Temp\SDA"
    $adminShareFile = Join-Path $adminShareDest $FileName

    Write-Output " > [1/2] Pre-staging installer via admin share (\\$TargetPC\C$)..."
    try {
        if (-not (Test-Path $adminShareDest)) {
            New-Item -ItemType Directory -Path $adminShareDest -Force -ErrorAction Stop | Out-Null
        }
        Copy-Item -Path $SourcePath -Destination $adminShareFile -Force -ErrorAction Stop
        Write-Output " > [1/2] Installer copied successfully to $adminShareDest"
    } catch {
        Write-Output " > [!] Admin share copy failed for $TargetPC — $($_.Exception.Message)"
        return $false
    }

    # Step 2: PsExec runs the local-execute payload as SYSTEM.
    # The EncodedCommand payload will find the file already on disk at
    # C:\Windows\Temp\SDA\$FileName and skip straight to the install.
    Write-Output " > [2/2] Launching installer via PsExec (SYSTEM, local path)..."
    try {
        $ArgsList = "-accepteula -nobanner -d \\$TargetPC -s powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand $EncodedCommand"
        $Process = Start-Process -FilePath $PsExecPath -ArgumentList $ArgsList -Wait -WindowStyle Hidden -PassThru
        if ($Process.ExitCode -eq 0) {
            Write-Output " > [2/2] PsExec dispatched successfully."
            return $true
        } else {
            Write-Output " > [!] PsExec returned exit code $($Process.ExitCode) for $TargetPC."
            return $false
        }
    } catch {
        Write-Output " > [!] PsExec threw an exception for $TargetPC — $($_.Exception.Message)"
        return $false
    }
}

if ($GetTrainingData) {
    $data = @{
        StepName = "ZERO-TOUCH SOFTWARE DEPLOYMENT"
        Description = "While SDA uses WMI and PowerShell runspaces to deploy software asynchronously, a junior technician should know how to push an installer manually. By utilizing Sysinternals PsExec, you can remotely execute an installer as the SYSTEM account. This bypasses the 'Double-Hop' authentication issue, allowing the target machine's computer account to pull the installer directly from a network share and install it silently in the background."
        Code = "psexec \\`$Target -s msiexec.exe /i `"\\server\share\installer.msi`" /qn /norestart"
        InPerson = "Walking desk to desk with a flash drive, copying the installer to the desktop, and clicking through the installation wizard. Alternatively, opening an elevated command prompt and typing the silent install command."
    }
    $data | ConvertTo-Json | Write-Output
    return
}

$LibraryFile = Join-Path -Path $SharedRoot -ChildPath "Core\SoftwareLibrary.json"
$HistoryFile = Join-Path -Path $SharedRoot -ChildPath "Core\UserHistory.json"

function Load-Lib {
    if (Test-Path $LibraryFile) {
        try {
            $raw = Get-Content $LibraryFile -Raw -ErrorAction Stop | ConvertFrom-Json
            if ($null -eq $raw) { return @() }
            if ($raw -is [System.Array]) { return $raw } else { return @($raw) }
        } catch {
            # JSON is malformed — rename the broken file for recovery and start fresh
            # rather than throwing, which would kill the API gateway response entirely.
            $backupPath = "$LibraryFile.corrupted_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
            Rename-Item -Path $LibraryFile -NewName $backupPath -Force -ErrorAction SilentlyContinue
            Write-Output "[!] SoftwareLibrary.json was corrupted and has been backed up to: $backupPath"
            Write-Output "[i] A fresh default library will be created now."
            # Fall through to the creation block below
        }
    }

    # File doesn't exist, or was just renamed away above — create a fresh default.
    try {
        $CoreDir = Join-Path -Path $SharedRoot -ChildPath "Core"
        if (-not (Test-Path $CoreDir)) { New-Item -ItemType Directory -Path $CoreDir -Force -ErrorAction Stop | Out-Null }

        $default = @(
            [PSCustomObject]@{ ID=1; Name="Google Chrome (Enterprise)"; Path="\\server\share\Software\GoogleChromeStandaloneEnterprise64.msi"; Args="/qn /norestart" }
        )
        ConvertTo-Json -InputObject $default -Depth 2 | Set-Content $LibraryFile -Force -ErrorAction Stop
        return $default
    } catch {
        # Can't write to disk at all — return an empty array so GetLibrary still
        # returns valid JSON and the UI renders instead of spinning forever.
        Write-Output "[!] Could not create SoftwareLibrary.json: $($_.Exception.Message)"
        return @()
    }
}

function Save-Lib {
    param($d)
    ConvertTo-Json -InputObject @($d) -Depth 2 | Set-Content $LibraryFile -Force
}

if ($Action -eq "GetLibrary") {
    $lib = @(Load-Lib)
    $json = ConvertTo-Json -InputObject $lib -Depth 2 -Compress

    if ($lib.Count -eq 1 -and $json -notmatch "^\[") {
        $json = "[$json]"
    }

    Write-Output $json
    return
}

if ($Action -eq "AddApp") {
    $lib = @(Load-Lib)
    $newID = if ($lib.Count -gt 0) { ([int]($lib | Select-Object -ExpandProperty ID | Measure-Object -Maximum).Maximum) + 1 } else { 1 }

    $cleanName = $AppName.Trim() -replace '[\x00-\x1F]', ''
    $cleanPath = $AppPath.Trim() -replace '[\x00-\x1F]', ''
    $cleanArgs = if ($AppArgs) { $AppArgs.Trim() -replace '[\x00-\x1F]', '' } else { "" }

    $lib += [PSCustomObject]@{ ID=$newID; Name=$cleanName; Path=$cleanPath; Args=$cleanArgs }
    Save-Lib $lib
    Write-Output "[SDA] [+] Added '$cleanName' to the central Software Library."
    return
}

if ($Action -eq "DeleteApp") {
    $lib = @(Load-Lib)
    $lib = $lib | Where-Object { $_.ID -ne [int]$AppID }
    Save-Lib $lib
    Write-Output "[SDA] [-] Application removed from the central Software Library."
    return
}

if ($Action -eq "Install") {

    if ([string]::IsNullOrWhiteSpace($Target)) {
        Write-Output "[!] ERROR: Target PC(s) required."
        return
    }

    $SafeAppName = Escape-Html $AppName
    $TargetArray = @($Target -split ',' | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    # Defense-in-Depth: Explicitly strip interpolation characters ($, ", ', and backticks)
    $SanitizeRegex = "[`\$`"'``]"
    $safePath = $AppPath -replace $SanitizeRegex, ''
    $safeArgs = if ($AppArgs) { $AppArgs -replace $SanitizeRegex, '' } else { "" }

    # Derive the installer filename from the source path so we can reconstruct
    # the local staging path on the target without hardcoding anything.
    $installerFileName = [System.IO.Path]::GetFileName($safePath)

    # Encode the source UNC path, filename, and install args so they survive
    # being passed through WinRM/PsExec without any quoting or escaping issues.
    $b64SourcePath  = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($safePath))
    $b64FileName    = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($installerFileName))
    $b64Args        = if ($safeArgs) { [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($safeArgs)) } else { "" }

    # -------------------------------------------------------------------------
    # PDQ-STYLE PAYLOAD: Copy installer locally, then execute from local path.
    #
    # WHY THIS WORKS:
    #   The Copy-Item runs inside the Invoke-Command session, which carries the
    #   technician's Kerberos credentials — so it CAN reach the UNC share.
    #   The subsequent Start-Process runs as SYSTEM (via WMI/PsExec) against a
    #   local path, so there is no double-hop or auth issue during the install.
    #   This is exactly how PDQ Deploy stages and runs packages.
    #
    # FLOW:
    #   1. Decode the source UNC path and filename on the remote machine.
    #   2. Ensure C:\Windows\Temp\SDA exists as a staging folder.
    #   3. Copy the installer from the share to the local staging folder.
    #      (This step uses WinRM credentials — no double-hop problem.)
    #   4. Build the install command using the fully local path.
    #   5. Execute via WMI Win32_Process as SYSTEM from a local path.
    #   6. Clean up the staged installer after the process launches.
    # -------------------------------------------------------------------------
    $PayloadString = @"
        `$ErrorActionPreference = 'SilentlyContinue'

        # Step 1: Decode inputs
        `$sourcePath    = [System.Text.Encoding]::Unicode.GetString([Convert]::FromBase64String('$b64SourcePath'))
        `$fileName      = [System.Text.Encoding]::Unicode.GetString([Convert]::FromBase64String('$b64FileName'))
        `$installArgs   = if ('$b64Args') { [System.Text.Encoding]::Unicode.GetString([Convert]::FromBase64String('$b64Args')) } else { '' }

        # Step 2: Prepare local staging folder
        `$stagingDir  = 'C:\Windows\Temp\SDA'
        `$localPath   = Join-Path `$stagingDir `$fileName
        if (-not (Test-Path `$stagingDir)) { New-Item -ItemType Directory -Path `$stagingDir -Force | Out-Null }

        # Step 3: Copy installer from UNC share to local staging path
        Copy-Item -Path `$sourcePath -Destination `$localPath -Force -ErrorAction Stop

        # Step 4 & 5: Determine installer type and build the correct launch command.
        # MSI files must be driven through msiexec.exe — you cannot Start-Process an
        # .msi directly as SYSTEM without it. EXE installers run directly.
        `$extension = [System.IO.Path]::GetExtension(`$localPath).ToLower()
        if (`$extension -eq '.msi') {
            `$execPath = 'msiexec.exe'
            `$execArgs = "/i `"`$localPath`" `$installArgs"
        } else {
            `$execPath = `$localPath
            `$execArgs = `$installArgs
        }

        # Step 6: Launch via WMI as SYSTEM from the fully local path
        `$wmiCmd = "`$execPath `$execArgs"
        Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = `$wmiCmd } | Out-Null

        # Step 7: Clean up staged installer after a short delay to let the
        # installer process detach. The install itself continues in the background.
        Start-Sleep -Seconds 5
        Remove-Item -Path `$localPath -Force -ErrorAction SilentlyContinue
"@

    # Encode the entire payload as Base64 so it passes cleanly through
    # WinRM argument boundaries and PsExec without any escaping issues.
    $Bytes = [System.Text.Encoding]::Unicode.GetBytes($PayloadString)
    $EncodedCommand = [Convert]::ToBase64String($Bytes)

    # This is the WMI command that PsExec will run as SYSTEM on the remote box.
    # It simply launches PowerShell with our encoded payload.
    $psExecPath = Join-Path -Path $SharedRoot -ChildPath "Core\psexec.exe"

    # =========================================================================
    # SINGLE TARGET DEPLOYMENT
    # =========================================================================
    if ($TargetArray.Count -eq 1) {
        $SingleTarget = $TargetArray[0]
        Write-Output "========================================"
        Write-Output "[SDA] ZERO-TOUCH DEPLOYMENT"
        Write-Output "========================================"
        Write-Output "[i] Deploying $SafeAppName to $SingleTarget..."
        Write-Output "[i] Staging installer to C:\Windows\Temp\SDA on target..."

        if (-not (Test-Connection -ComputerName $SingleTarget -Count 1 -Quiet)) {
            Write-Output "[!] $SingleTarget is offline. Attempting Wake-on-LAN..."
            $Woken = $false
            if (Test-Path $HistoryFile) {
                try {
                    $dbRaw = Get-Content $HistoryFile -Raw -ErrorAction Stop | ConvertFrom-Json
                    if ($dbRaw -isnot [System.Array]) { $dbRaw = @($dbRaw) }
                } catch {
                    $dbRaw = @()
                    Write-Output " > [!] Telemetry DB locked or unavailable. Skipping WoL."
                }

                $dbEntry = $dbRaw | Where-Object { $_.Computer -eq $SingleTarget -and $_.MACAddress -ne $null } | Select-Object -First 1
                if ($dbEntry) {
                    Write-Output " > Sending Magic Packet to $($dbEntry.MACAddress)..."
                    Send-MagicPacket -MacAddress $dbEntry.MACAddress | Out-Null
                    Write-Output " > Waiting for boot (up to 90 seconds)..."

                    for ($i = 0; $i -lt 18; $i++) {
                        Start-Sleep -Seconds 5
                        if (Test-Connection -ComputerName $SingleTarget -Count 1 -Quiet) {
                            Write-Output " > [SUCCESS] Target is now awake!"
                            $Woken = $true
                            break
                        }
                    }
                } else { Write-Output " > [i] No MAC address found in telemetry. Cannot wake." }
            }

            if (-not $Woken) {
                Write-Output "[!] Target remains offline. Aborting deployment."
                return
            }
        }

        # --- Primary path: WinRM ---
        # Invoke-Command runs under the technician's credentials (Kerberos), so
        # Copy-Item inside the payload CAN reach the UNC share. The subsequent
        # WMI launch runs locally on the target, so no double-hop occurs.
        try {
            Write-Output " > Copying installer to target staging folder via WinRM..."
            Invoke-Command -ComputerName $SingleTarget -ScriptBlock {
                param($encodedCmd)
                powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand $encodedCmd
            } -ArgumentList $EncodedCommand -ErrorAction Stop
            Write-Output "`n[SDA SUCCESS] Installer staged and launched successfully via WinRM."
            Write-Output "[i] Installation is running silently in the background on $SingleTarget."
        } catch {
            # --- Fallback path: Two-step admin share pre-stage + PsExec ---
            # The script (running as you) copies the installer to \\TARGET\C$\...,
            # then PsExec runs the payload as SYSTEM against the already-local file.
            Write-Output "[!] WinRM failed. Initiating two-step PsExec fallback..."
            if (Test-Path $psExecPath) {
                $fallbackOK = Invoke-PsExecFallback `
                    -TargetPC      $SingleTarget `
                    -SourcePath    $safePath `
                    -FileName      $installerFileName `
                    -PsExecPath    $psExecPath `
                    -EncodedCommand $EncodedCommand

                if ($fallbackOK) {
                    Write-Output "`n[SDA SUCCESS] Deployment dispatched via PsExec fallback."
                    Write-Output "[i] Installation is running silently in the background on $SingleTarget."
                } else {
                    Write-Output "`n[!] FATAL ERROR: Both WinRM and PsExec fallback failed for $SingleTarget."
                }
            } else { Write-Output "`n[!] FATAL ERROR: psexec.exe is missing from \Core." }
        }

        if (-not [string]::IsNullOrWhiteSpace($SharedRoot)) {
            $AuditHelper = Join-Path -Path $SharedRoot -ChildPath "Core\Helper_AuditLog.ps1"
            if (Test-Path $AuditHelper) { & $AuditHelper -Target $SingleTarget -Action "Deployed Software: $AppName" -SharedRoot $SharedRoot }
        }
        return
    }

    # =========================================================================
    # MASS DEPLOYMENT
    # =========================================================================
    Write-Output "========================================"
    Write-Output "[SDA] MASS ZERO-TOUCH DEPLOYMENT"
    Write-Output "========================================"
    Write-Output "[i] Application : $SafeAppName"
    Write-Output "[i] Total Targets: $($TargetArray.Count)"
    Write-Output "[i] Payload model: Copy-to-C:\Windows\Temp\SDA, then install locally"

    $Online = @(); $Offline = @(); $Woken = @(); $SuccessWinRM = @(); $SuccessPsExec = @(); $Failed = @()

    Write-Output "`n[1/4] Performing rapid ping sweep..."
    foreach ($t in $TargetArray) {
        if (Test-Connection -ComputerName $t -Count 1 -Quiet) { $Online += $t } else { $Offline += $t }
    }
    Write-Output " > Online: $($Online.Count) | Offline: $($Offline.Count)"

    if ($Offline.Count -gt 0 -and (Test-Path $HistoryFile)) {
        Write-Output "`n[2/4] Attempting Wake-on-LAN for offline targets..."
        try {
            $dbRaw = Get-Content $HistoryFile -Raw -ErrorAction Stop | ConvertFrom-Json
            if ($dbRaw -isnot [System.Array]) { $dbRaw = @($dbRaw) }
        } catch {
            $dbRaw = @()
            Write-Output " > [!] Telemetry DB locked or unavailable. Skipping WoL."
        }

        $WokeSomeone = $false
        foreach ($offPC in $Offline) {
            $dbEntry = $dbRaw | Where-Object { $_.Computer -eq $offPC -and $_.MACAddress -ne $null } | Select-Object -First 1
            if ($dbEntry) {
                Write-Output " > Sending Magic Packet to $offPC ($($dbEntry.MACAddress))..."
                Send-MagicPacket -MacAddress $dbEntry.MACAddress | Out-Null
                $WokeSomeone = $true
            } else {
                Write-Output " > [i] No MAC address found in telemetry for $offPC."
            }
        }

        if ($WokeSomeone) {
            Write-Output " > Waiting for machines to boot (up to 90 seconds)..."
            for ($i = 0; $i -lt 18; $i++) {
                Start-Sleep -Seconds 5
                $StillOffline = @()
                foreach ($offPC in $Offline) {
                    if (Test-Connection -ComputerName $offPC -Count 1 -Quiet) {
                        Write-Output " > [SUCCESS] $offPC is now awake!"
                        $Online += $offPC
                        $Woken  += $offPC
                    } else {
                        $StillOffline += $offPC
                    }
                }
                $Offline = $StillOffline
                if ($Offline.Count -eq 0) { break }
            }
        }
    } else {
        Write-Output "`n[2/4] Skipping Wake-on-LAN (No offline targets or telemetry DB missing)."
    }

    if ($Online.Count -gt 0) {
        Write-Output "`n[3/4] Dispatching parallel WinRM staging + install jobs..."
        Write-Output " > Each target will copy the installer locally before executing."

        # Invoke-Command -AsJob fires all targets in parallel. Each remote session
        # runs our full payload: copy from UNC (using WinRM/Kerberos creds) then
        # launch the installer via WMI from the local staging path.
        $WinRMJob = Invoke-Command -ComputerName $Online -ScriptBlock {
            param($encodedCmd)
            powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand $encodedCmd
        } -ArgumentList $EncodedCommand -ErrorVariable WinRMErrors -ErrorAction SilentlyContinue -AsJob

        Wait-Job $WinRMJob | Out-Null
        Receive-Job $WinRMJob | Out-Null
        Remove-Job $WinRMJob -Force

        $WinRMErrorsList = @()
        foreach ($err in $WinRMErrors) {
            if ($err.TargetObject) { $WinRMErrorsList += $err.TargetObject.ToString().ToUpper() }
        }

        $FailedWinRM = @()
        foreach ($t in $Online) {
            if ($WinRMErrorsList -contains $t.ToUpper()) { $FailedWinRM += $t }
            else { $SuccessWinRM += $t }
        }

        Write-Output " > WinRM Success: $($SuccessWinRM.Count) | WinRM Blocked: $($FailedWinRM.Count)"

        if ($FailedWinRM.Count -gt 0) {
            Write-Output "`n[4/4] Initiating two-step PsExec fallback for WinRM-blocked targets..."
            Write-Output " > Script will pre-stage via C$ admin share, then PsExec executes locally."
            if (Test-Path $psExecPath) {
                foreach ($t in $FailedWinRM) {
                    Write-Output " > Processing $t..."
                    $fallbackOK = Invoke-PsExecFallback `
                        -TargetPC       $t `
                        -SourcePath     $safePath `
                        -FileName       $installerFileName `
                        -PsExecPath     $psExecPath `
                        -EncodedCommand $EncodedCommand

                    if ($fallbackOK) { $SuccessPsExec += $t } else { $Failed += $t }
                }
            } else {
                Write-Output " > [!] psexec.exe missing. Cannot process fallbacks."
                $Failed += $FailedWinRM
            }
        } else {
            Write-Output "`n[4/4] No PsExec fallback needed. All targets handled via WinRM."
        }
    }

    $TotalSuccess = $SuccessWinRM.Count + $SuccessPsExec.Count
    $html = "<div style='background: #1e293b; padding: 16px; border-radius: 8px; border-left: 4px solid #9b59b6; margin-top: 15px; margin-bottom: 10px; box-shadow: 0 4px 6px rgba(0,0,0,0.2); font-family: system-ui, sans-serif;'>"
    $html += "<div style='color: #f8fafc; font-weight: bold; font-size: 1.1rem; margin-bottom: 12px;'><i class='fa-solid fa-network-wired'></i> Mass Deployment Report</div>"

    $html += "<div style='display: grid; grid-template-columns: 1fr 1fr; gap: 10px; margin-bottom: 10px;'>"
    $html += "<div style='background: #0f172a; padding: 10px; border-radius: 6px; border: 1px solid #334155;'><span style='color: #94a3b8; font-size: 0.85rem;'>Total Targets</span><br><span style='color: #f8fafc; font-size: 1.2rem; font-weight: bold;'>$($TargetArray.Count)</span></div>"
    $html += "<div style='background: #0f172a; padding: 10px; border-radius: 6px; border: 1px solid #334155;'><span style='color: #94a3b8; font-size: 0.85rem;'>Successful Dispatches</span><br><span style='color: #2ecc71; font-size: 1.2rem; font-weight: bold;'>$TotalSuccess</span></div>"
    $html += "</div>"

    if ($Woken.Count -gt 0) {
        $safeWoken = ($Woken | ForEach-Object { Escape-Html $_ }) -join ', '
        $html += "<div style='color: #3498db; font-size: 0.85rem; margin-top: 8px;'><i class='fa-solid fa-power-off'></i> <strong>$($Woken.Count) Woken via WoL:</strong> $safeWoken</div>"
    }
    if ($Offline.Count -gt 0) {
        $safeOffline = ($Offline | ForEach-Object { Escape-Html $_ }) -join ', '
        $html += "<div style='color: #e74c3c; font-size: 0.85rem; margin-top: 8px;'><i class='fa-solid fa-triangle-exclamation'></i> <strong>$($Offline.Count) Offline:</strong> $safeOffline</div>"
    }
    if ($Failed.Count -gt 0) {
        $safeFailed = ($Failed | ForEach-Object { Escape-Html $_ }) -join ', '
        $html += "<div style='color: #f1c40f; font-size: 0.85rem; margin-top: 8px;'><i class='fa-solid fa-circle-xmark'></i> <strong>$($Failed.Count) Failed:</strong> $safeFailed</div>"
    }

    $html += "</div>"
    Write-Output $html

    if (-not [string]::IsNullOrWhiteSpace($SharedRoot)) {
        $AuditHelper = Join-Path -Path $SharedRoot -ChildPath "Core\Helper_AuditLog.ps1"
        if (Test-Path $AuditHelper) {
            & $AuditHelper -Target "MASS DEPLOY ($TotalSuccess PCs)" -Action "Deployed Software: $AppName" -SharedRoot $SharedRoot
        }
    }
}
