<#
.SYNOPSIS
    SDA Web-Ready Tool: RemoteSoftwareInstall.ps1
.DESCRIPTION
    Acts as a backend controller for the Zero-Touch Deployment Library UI.
    Supports single and mass deployments via WinRM and PsExec.
    Includes Wake-on-LAN (WoL) functionality for offline targets.
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
            # Process Stability Fix: Throw instead of exit to prevent killing the API Gateway
            throw "CRITICAL: SoftwareLibrary.json is corrupted. Aborting to prevent data loss."
        }
    } else { 
        $CoreDir = Join-Path -Path $SharedRoot -ChildPath "Core"
        if (-not (Test-Path $CoreDir)) { New-Item -ItemType Directory -Path $CoreDir -Force | Out-Null }

        $default = @(
            [PSCustomObject]@{ ID=1; Name="Google Chrome (Enterprise)"; Path="\\server\share\Software\GoogleChromeStandaloneEnterprise64.msi"; Args="/qn /norestart" }
        )
        ConvertTo-Json -InputObject $default -Depth 2 | Set-Content $LibraryFile -Force
        return $default
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

    $b64Path = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($safePath))
    $b64Args = if ($safeArgs) { [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($safeArgs)) } else { "" }

    $PayloadString = @"
        `$ErrorActionPreference = 'SilentlyContinue'
        `$decPath = [System.Text.Encoding]::Unicode.GetString([Convert]::FromBase64String('$b64Path'))
        `$decArgs = if ('$b64Args') { [System.Text.Encoding]::Unicode.GetString([Convert]::FromBase64String('$b64Args')) } else { '' }

        `$proc = Start-Process -FilePath `$decPath -ArgumentList `$decArgs -Wait -WindowStyle Hidden -PassThru
        if (`$proc) { Write-Output `"EXIT_CODE:`$(`$proc.ExitCode)`" }
"@

    $Bytes = [System.Text.Encoding]::Unicode.GetBytes($PayloadString)
    $EncodedCommand = [Convert]::ToBase64String($Bytes)
    $wmiPayload = "powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand $EncodedCommand"
    $psExecPath = Join-Path -Path $SharedRoot -ChildPath "Core\psexec.exe"

    if ($TargetArray.Count -eq 1) {
        $SingleTarget = $TargetArray[0]
        Write-Output "========================================"
        Write-Output "[SDA] ZERO-TOUCH DEPLOYMENT"
        Write-Output "========================================"
        Write-Output "[i] Deploying $SafeAppName to $SingleTarget..."

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

        try {
            Write-Output " > Initiating background installation via WinRM..."
            Invoke-Command -ComputerName $SingleTarget -ScriptBlock {
                param($cmd)
                Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $cmd } | Out-Null
            } -ArgumentList $wmiPayload -ErrorAction Stop
            Write-Output "`n[SDA SUCCESS] Deployment dispatched successfully via WinRM."
        } catch {
            Write-Output "[!] WinRM Failed. Initiating PsExec Fallback..."
            if (Test-Path $psExecPath) {
                try {
                    $ArgsList = "-accepteula -nobanner -d \\$SingleTarget -s powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand $EncodedCommand"

                    $Process = Start-Process -FilePath $psExecPath -ArgumentList $ArgsList -Wait -WindowStyle Hidden -PassThru
                    if ($Process.ExitCode -eq 0) { Write-Output "`n[SDA SUCCESS] Deployment dispatched successfully via PsExec." } 
                    else { Write-Output "`n[!] ERROR: PsExec returned exit code $($Process.ExitCode)." }
                } catch { Write-Output "`n[!] FATAL ERROR: Both WinRM and PsExec failed." }
            } else { Write-Output "`n[!] FATAL ERROR: psexec.exe is missing from \Core." }
        }

        if (-not [string]::IsNullOrWhiteSpace($SharedRoot)) {
            $AuditHelper = Join-Path -Path $SharedRoot -ChildPath "Core\Helper_AuditLog.ps1"
            if (Test-Path $AuditHelper) { & $AuditHelper -Target $SingleTarget -Action "Deployed Software: $AppName" -SharedRoot $SharedRoot }
        }
        return
    }

    Write-Output "========================================"
    Write-Output "[SDA] MASS ZERO-TOUCH DEPLOYMENT"
    Write-Output "========================================"
    Write-Output "[i] Application: $SafeAppName"
    Write-Output "[i] Total Targets: $($TargetArray.Count)"

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
                        $Woken += $offPC
                    } else {
                        $StillOffline += $offPC
                    }
                }
                $Offline = $StillOffline
                if ($Offline.Count -eq 0) { break }
            }
        }
    } else {
        Write-Output "`n[2/4] Skipping Wake-on-LAN (No offline targets or DB missing)."
    }

    if ($Online.Count -gt 0) {
        Write-Output "`n[3/4] Dispatching parallel WinRM commands..."

        $WinRMJob = Invoke-Command -ComputerName $Online -ScriptBlock {
            param($cmd)
            Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $cmd } | Out-Null
        } -ArgumentList $wmiPayload -ErrorVariable WinRMErrors -ErrorAction SilentlyContinue -AsJob

        Wait-Job $WinRMJob | Out-Null
        $JobResults = Receive-Job $WinRMJob
        Remove-Job $WinRMJob -Force

        # Logic Fix: Properly separate error lookup from fallback list
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
            Write-Output "`n[4/4] Initiating PsExec fallback for blocked targets..."
            if (Test-Path $psExecPath) {
                foreach ($t in $FailedWinRM) {
                    try {
                        $ArgsList = "-accepteula -nobanner -d \\$t -s powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand $EncodedCommand"
                        $Process = Start-Process -FilePath $psExecPath -ArgumentList $ArgsList -Wait -WindowStyle Hidden -PassThru
                        if ($Process.ExitCode -eq 0) { $SuccessPsExec += $t } else { $Failed += $t }
                    } catch { $Failed += $t }
                }
            } else {
                Write-Output " > [!] psexec.exe missing. Cannot process fallbacks."
                $Failed += $FailedWinRM
            }
        }
    }

    $TotalSuccess = $SuccessWinRM.Count + $SuccessPsExec.Count
    $html = "<div style='background: #1e293b; padding: 16px; border-radius: 8px; border-left: 4px solid #9b59b6; margin-top: 15px; margin-bottom: 10px; box-shadow: 0 4px 6px rgba(0,0,0,0.2); font-family: system-ui, sans-serif;'>"
    $html += "<div style='color: #f8fafc; font-weight: bold; font-size: 1.1rem; margin-bottom: 12px;'><i class='fa-solid fa-network-wired'></i> Mass Deployment Report</div>"

    $html += "<div style='display: grid; grid-template-columns: 1fr 1fr; gap: 10px; margin-bottom: 10px;'>"
    $html += "<div style='background: #0f172a; padding: 10px; border-radius: 6px; border: 1px solid #334155;'><span style='color: #94a3b8; font-size: 0.85rem;'>Total Targets</span><br><span style='color: #f8fafc; font-size: 1.2rem; font-weight: bold;'>$($TargetArray.Count)</span></div>"
    $html += "<div style='background: #0f172a; padding: 10px; border-radius: 6px; border: 1px solid #334155;'><span style='color: #94a3b8; font-size: 0.85rem;'>Successful Dispatches</span><br><span style='color: #2ecc71; font-size: 1.2rem; font-weight: bold;'>$TotalSuccess</span></div>"
    $html += "</div>"

    # Defense-in-Depth: Escape HTML for arrays rendered into the UI
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
