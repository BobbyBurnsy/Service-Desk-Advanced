<#
.SYNOPSIS
    SDA Web-Ready Tool: RemoteEventLogViewer.ps1
.DESCRIPTION
    Remotely queries the System and Application event logs.
    Uses Base64 transit encoding to prevent stream corruption from special characters.
    Exports to a local CSV and automatically opens the folder for the technician.
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
    [string]$Keyword,

    [Parameter(Mandatory=$false)]
    [switch]$GetTrainingData
)

$ErrorActionPreference = "Continue"

# --- Export Training Data ---
if ($GetTrainingData) {
    $data = @{
        StepName = "REMOTE EVENT LOG VIEWER"
        Description = "While SDA uses PowerShell to parse and format thousands of logs into a clean UI table, a junior technician should know how to pull event logs manually from the command line. By utilizing Sysinternals PsExec, you can remotely execute the native Windows Event Utility ('wevtutil') to instantly grab the latest system events in plain text without needing to open the slow Event Viewer GUI."
        Code = "psexec \\`$Target wevtutil qe System /c:10 /f:text /rd:true"
        InPerson = "Opening Event Viewer (eventvwr.msc), navigating to Windows Logs -> System, and filtering the log for Critical and Error events."
    }
    $data | ConvertTo-Json | Write-Output
    return
}

# --- Main Execution ---
Write-Output "========================================"
Write-Output "[SDA] REMOTE EVENT LOG VIEWER"
Write-Output "========================================"

if ([string]::IsNullOrWhiteSpace($Target)) { 
    Write-Output "[!] ERROR: Target PC is required."
    return 
}

if (-not (Test-Connection -ComputerName $Target -Count 1 -Quiet)) {
    Write-Output "[!] Offline. $Target is not responding to ping."
    return
}

$ActionLog = if ($Keyword) { "Remote Event Log Viewer Executed (Keyword: $Keyword)" } else { "Remote Event Log Viewer Executed (Critical/Error)" }

# Set up the local export directory on the Technician's PC
$LocalTemp = "C:\SDA\Exports"
if (-not (Test-Path $LocalTemp)) { New-Item -ItemType Directory -Path $LocalTemp -Force | Out-Null }
$Timestamp = (Get-Date).ToString("yyyyMMdd_HHmmss")
$ExportPath = "$LocalTemp\EventLogs_$Target_$Timestamp.csv"

$SafeKeyword = $Keyword -replace "'", "''"

# The Payload executed on the Target PC
$PayloadString = @"
    `$ErrorActionPreference = 'SilentlyContinue'
    `$Keyword = '$SafeKeyword'
    `$logs = `$null

    if ([string]::IsNullOrWhiteSpace(`$Keyword)) {
        `$logs = Get-WinEvent -FilterHashtable @{LogName=@('System','Application'); Level=@(1,2)} -MaxEvents 25
    } else {
        `$logs = Get-WinEvent -LogName 'System','Application' -MaxEvents 10000 | 
                Where-Object { `$_.Message -match `$Keyword -or `$_.ProviderName -match `$Keyword } | 
                Select-Object -First 50
    }

    `$results = @()
    if (`$logs) {
        foreach (`$log in `$logs) {
            # Strip newlines and tabs to ensure clean CSV/JSON formatting
            `$cleanMsg = `$log.Message -replace '[\r\n]+', ' ' -replace '\t', ' '

            `$results += [PSCustomObject]@{
                TimeCreated = `$log.TimeCreated.ToString('MM/dd HH:mm:ss')
                Level       = `$log.LevelDisplayName
                Provider    = `$log.ProviderName
                Message     = `$cleanMsg
            }
        }
    }

    `$json = @(`$results) | ConvertTo-Json -Compress

    # Base64 encode the JSON to guarantee safe transit over WinRM/PsExec streams
    `$b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes(`$json))
    Write-Output `"---B64_START---`$b64---B64_END---`"
"@

$PayloadBlock = [scriptblock]::Create($PayloadString)
$RawOutputString = $null
$MethodUsed = "WinRM"

try {
    Write-Output "[i] Attempting connection to $Target via WinRM... (This may take a moment)"
    $RawOutputString = Invoke-Command -ComputerName $Target -ErrorAction Stop -ScriptBlock $PayloadBlock | Out-String
} catch {
    Write-Output "[!] WinRM Failed or Blocked. Initiating PsExec Fallback..."
    $MethodUsed = "PsExec"

    $psExecPath = Join-Path -Path $SharedRoot -ChildPath "Core\psexec.exe"
    if (Test-Path $psExecPath) {
        try {
            $Bytes = [System.Text.Encoding]::Unicode.GetBytes($PayloadString)
            $EncodedCommand = [Convert]::ToBase64String($Bytes)

            $ArgsList = "/accepteula \\$Target -s powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand $EncodedCommand"
            $RawOutputString = & $psExecPath $ArgsList 2>&1 | Out-String
            $ActionLog += " [PsExec Fallback]"
        } catch {
            Write-Output "`n[!] FATAL ERROR: Both WinRM and PsExec failed."
            return
        }
    } else {
        Write-Output "`n[!] FATAL ERROR: WinRM failed and psexec.exe is missing from \Core."
        return
    }
}

# Decode the Base64 payload back into JSON on the Technician's PC
if ($RawOutputString -match '---B64_START---(.*?)---B64_END---') {
    try {
        $b64Data = $matches[1]
        $jsonString = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64Data))

        $logData = $jsonString | ConvertFrom-Json
        if ($logData -isnot [System.Array]) { $logData = @($logData) }

        if ($logData.Count -gt 0) {
            Write-Output "`n[SDA SUCCESS] Found $($logData.Count) matching logs via $MethodUsed."

            # Export to CSV
            $logData | Export-Csv -Path $ExportPath -NoTypeInformation -Force

            # Build the HTML Table for the UI
            $html = "<div style='margin-top: 15px; margin-bottom: 15px; max-height: 400px; overflow-y: auto; border: 1px solid #334155; border-radius: 8px; background: #0f172a; box-shadow: 0 4px 6px rgba(0,0,0,0.2);'>"
            $html += "<table style='width: 100%; border-collapse: collapse; font-family: system-ui, sans-serif; font-size: 0.85rem; text-align: left;'>"
            $html += "<thead style='position: sticky; top: 0; background: #1e293b; color: #38bdf8; box-shadow: 0 2px 4px rgba(0,0,0,0.5);'>"
            $html += "<tr><th style='padding: 10px; border-bottom: 2px solid #334155; width: 15%;'>Time</th><th style='padding: 10px; border-bottom: 2px solid #334155; width: 10%;'>Level</th><th style='padding: 10px; border-bottom: 2px solid #334155; width: 20%;'>Provider</th><th style='padding: 10px; border-bottom: 2px solid #334155; width: 55%;'>Message</th></tr></thead><tbody>"

            foreach ($log in $logData) {
                $levelColor = "#f8fafc"
                if ($log.Level -match "Error|Critical") { $levelColor = "#e74c3c" }
                elseif ($log.Level -match "Warning") { $levelColor = "#f1c40f" }

                $msg = $log.Message -replace '<', '&lt;' -replace '>', '&gt;'
                if ($msg.Length -gt 250) { $msg = $msg.Substring(0, 247) + "..." }

                $html += "<tr style='border-bottom: 1px solid #1e293b;'>"
                $html += "<td style='padding: 8px; color: #94a3b8; white-space: nowrap;'>$($log.TimeCreated)</td>"
                $html += "<td style='padding: 8px; color: $levelColor; font-weight: bold;'>$($log.Level)</td>"
                $html += "<td style='padding: 8px; color: #cbd5e1;'>$($log.Provider)</td>"
                $html += "<td style='padding: 8px; color: #f8fafc; word-wrap: break-word; max-width: 300px;'>$msg</td>"
                $html += "</tr>"
            }

            $html += "</tbody></table></div>"
            $html += "<div style='color: #94a3b8; font-size: 0.85rem; margin-bottom: 10px;'><i class='fa-solid fa-file-csv'></i> Dataset saved to: $ExportPath</div>"

            Write-Output $html

            # Automatically pop open the folder and highlight the CSV file
            Start-Process explorer.exe -ArgumentList "/select,`"$ExportPath`""

            if (-not [string]::IsNullOrWhiteSpace($SharedRoot)) {
                $AuditHelper = Join-Path -Path $SharedRoot -ChildPath "Core\Helper_AuditLog.ps1"
                if (Test-Path $AuditHelper) {
                    & $AuditHelper -Target $Target -Action $ActionLog -SharedRoot $SharedRoot
                }
            }
        } else {
            Write-Output "`n[i] No matching event logs found."
        }
    } catch {
        Write-Output "`n[!] ERROR: Failed to decode Base64 event log data."
    }
} else {
    Write-Output "`n[!] ERROR: No valid event log data returned from target."
}