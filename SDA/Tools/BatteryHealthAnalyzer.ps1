<#
.SYNOPSIS
    SDA Web-Ready Tool: BatteryHealthAnalyzer.ps1
.DESCRIPTION
    Queries the Windows Kernel Power Manager via powercfg to extract exact 
    milliwatt-hour (mWh) metrics. Bypasses legacy WMI classes for compatibility 
    with Modern Standby laptops. Calculates degradation, outputs a styled HTML payload,
    and securely extracts the full in-depth HTML battery report for the technician.
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
    [switch]$GetTrainingData
)

$ErrorActionPreference = "Continue"

# --- Export Training Data ---
if ($GetTrainingData) {
    $data = @{
        StepName = "BATTERY HEALTH ANALYZER"
        Description = "While SDA uses PowerShell to silently generate and parse an XML battery report to render a graphical health bar, a junior technician should know how to generate a battery report manually. By utilizing Sysinternals PsExec, you can remotely execute the native 'powercfg' utility to generate a comprehensive HTML battery report directly on the target's C: drive."
        Code = "psexec \\`$Target powercfg /batteryreport /output `"C:\battery_report.html`""
        InPerson = "Opening an elevated Command Prompt, typing 'powercfg /batteryreport', opening the generated HTML file in a browser, and manually doing the math between Design Capacity and Full Charge Capacity."
    }
    $data | ConvertTo-Json | Write-Output
    return
}

# --- Main Execution ---
Write-Output "========================================"
Write-Output "[SDA] BATTERY HEALTH ANALYZER"
Write-Output "========================================"

if ([string]::IsNullOrWhiteSpace($Target)) { 
    Write-Output "[!] ERROR: Target PC is required."
    return 
}

if (-not (Test-Connection -ComputerName $Target -Count 1 -Quiet)) {
    Write-Output "[!] Offline. $Target is not responding to ping."
    return
}

$ActionLog = "Battery Health Analyzer Executed (Kernel Power Query & HTML Export)"

# The Payload uses powercfg to generate both XML (for UI) and HTML (for deep dive)
$PayloadString = @"
    `$ErrorActionPreference = 'SilentlyContinue'
    `$tempXml = `"`$env:TEMP\sda_batt_`$([Guid]::NewGuid().ToString().Substring(0,8)).xml`"
    `$tempHtml = `"`$env:TEMP\sda_batt_`$([Guid]::NewGuid().ToString().Substring(0,8)).html`"

    # Generate reports via Kernel Power Manager
    cmd.exe /c `"powercfg /batteryreport /xml /output `"`$tempXml`"`" | Out-Null
    cmd.exe /c `"powercfg /batteryreport /html /output `"`$tempHtml`"`" | Out-Null

    `$batList = @()
    if (Test-Path `$tempXml) {
        [xml]`$battXml = Get-Content `$tempXml

        # Handle multiple batteries if present
        `$batteries = `$battXml.BatteryReport.Batteries.Battery
        if (`$batteries -isnot [System.Array]) { `$batteries = @(`$batteries) }

        foreach (`$bat in `$batteries) {
            if (`$bat.DesignCapacity -and `$bat.FullChargeCapacity) {
                `$batList += [PSCustomObject]@{ 
                    Design = [int]`$bat.DesignCapacity
                    Full   = [int]`$bat.FullChargeCapacity 
                }
            }
        }
        Remove-Item `$tempXml -Force
    }

    `$htmlB64 = ''
    if (Test-Path `$tempHtml) {
        `$htmlB64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes(`$tempHtml))
        Remove-Item `$tempHtml -Force
    }

    `$results = @{
        Batteries = `$batList
        HtmlReport = `$htmlB64
    }

    `$json = `$results | ConvertTo-Json -Depth 3 -Compress
    Write-Output `"---JSON_START---`$json---JSON_END---`"
"@

$PayloadBlock = [scriptblock]::Create($PayloadString)
$RawOutputString = $null
$MethodUsed = "WinRM"

try {
    Write-Output "[i] Attempting connection to $Target via WinRM..."
    Write-Output " > Generating and extracting powercfg reports..."
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

if ($RawOutputString -match '(?s)---JSON_START---(.*?)---JSON_END---') {
    try {
        $jsonPayload = $matches[1].Trim()
        $parsedData = $jsonPayload | ConvertFrom-Json

        $batteryData = $parsedData.Batteries
        if ($batteryData -isnot [System.Array]) { $batteryData = @($batteryData) }

        if ($batteryData.Count -gt 0) {
            Write-Output "`n[SDA SUCCESS] Battery telemetry retrieved via $MethodUsed!`n"

            # --- Handle HTML Report Export ---
            $LocalTemp = "C:\SDA\Exports"
            if (-not (Test-Path $LocalTemp)) { New-Item -ItemType Directory -Path $LocalTemp -Force | Out-Null }
            $Timestamp = (Get-Date).ToString("yyyyMMdd_HHmmss")
            $ExportPath = "$LocalTemp\BatteryReport_$Target_$Timestamp.html"

            if (-not [string]::IsNullOrWhiteSpace($parsedData.HtmlReport)) {
                $bytes = [Convert]::FromBase64String($parsedData.HtmlReport)
                [IO.File]::WriteAllBytes($ExportPath, $bytes)
            }

            # --- Build UI Graphic ---
            $html = "<div style='display: flex; flex-direction: column; gap: 12px; margin-top: 10px; margin-bottom: 10px;'>"

            foreach ($bat in $batteryData) {
                $design = $bat.Design
                $full = $bat.Full

                if ($design -eq 0) { $design = 1 }

                $healthPct = [math]::Round(($full / $design) * 100, 1)
                if ($healthPct -gt 100) { $healthPct = 100 }

                $barColor = "#2ecc71"
                if ($healthPct -lt 75) { $barColor = "#f1c40f" }
                if ($healthPct -lt 50) { $barColor = "#e74c3c" }

                $html += "<div style='background: #1e293b; padding: 16px; border-radius: 8px; border-left: 4px solid $barColor; box-shadow: 0 4px 6px rgba(0,0,0,0.2); font-family: system-ui, sans-serif;'>"
                $html += "<div style='color: #f8fafc; font-weight: bold; margin-bottom: 12px; font-size: 1.1rem;'><i class='fa-solid fa-battery-half'></i> Hardware Battery Health</div>"
                $html += "<div style='display: flex; justify-content: space-between; margin-bottom: 6px; font-size: 0.9rem;'>"
                $html += "<span style='color: #94a3b8;'>Design Capacity:</span><span style='color: #f8fafc;'>$($design.ToString('N0')) mWh</span></div>"
                $html += "<div style='display: flex; justify-content: space-between; margin-bottom: 12px; font-size: 0.9rem;'>"
                $html += "<span style='color: #94a3b8;'>Full Charge Capacity:</span><span style='color: #f8fafc;'>$($full.ToString('N0')) mWh</span></div>"
                $html += "<div style='width: 100%; background: #0f172a; border-radius: 6px; height: 10px; overflow: hidden; margin-bottom: 8px;'>"
                $html += "<div style='width: $($healthPct)%; background: $barColor; height: 100%; border-radius: 6px;'></div></div>"
                $html += "<div style='text-align: right; color: $barColor; font-weight: bold; font-size: 0.95rem;'>$healthPct% Health</div></div>"
            }

            if (Test-Path $ExportPath) {
                $html += "<div style='color: #94a3b8; font-size: 0.85rem; margin-top: 4px;'><i class='fa-solid fa-file-code'></i> Full in-depth report saved to: $ExportPath</div>"
                # Automatically open the HTML report in the technician's default browser
                Start-Process $ExportPath
            }

            $html += "</div>"
            Write-Output $html

            if (-not [string]::IsNullOrWhiteSpace($SharedRoot)) {
                $AuditHelper = Join-Path -Path $SharedRoot -ChildPath "Core\Helper_AuditLog.ps1"
                if (Test-Path $AuditHelper) {
                    & $AuditHelper -Target $Target -Action $ActionLog -SharedRoot $SharedRoot
                }
            }
        } else {
            Write-Output "`n[i] No battery data found. (Target is likely a Desktop PC or Virtual Machine)."
        }
    } catch {
        Write-Output "`n[!] ERROR: Failed to parse battery data JSON. Payload received: $($matches[1])"
    }
} else {
    Write-Output "`n[!] ERROR: No valid battery data returned from target. Stream may be corrupted."
}