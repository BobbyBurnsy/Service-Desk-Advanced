<#
.SYNOPSIS
    SDA Web-Ready Tool: RemoteScriptExecutor.ps1
.DESCRIPTION
    Acts as a backend controller for the Custom Script Library UI.
    Reads custom .ps1 scripts from a network share and executes them remotely
    in memory, capturing the output. Supports single and mass deployments.
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
    [string]$Action = "Execute",

    [Parameter(Mandatory=$false)]
    [string]$ScriptName,

    [Parameter(Mandatory=$false)]
    [string]$ScriptPath,

    [Parameter(Mandatory=$false)]
    [string]$ScriptID,

    [Parameter(Mandatory=$false)]
    [switch]$GetTrainingData
)

$ErrorActionPreference = "Continue"

# --- Helper Functions ---
function Escape-Html([string]$s) {
    if ([string]::IsNullOrEmpty($s)) { return "" }
    return $s.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;').Replace("'", '&#39;')
}

if ($GetTrainingData) {
    $data = @{
        StepName = "CUSTOM SCRIPT ORCHESTRATOR"
        Description = "While SDA uses in-memory ScriptBlocks and WinRM for mass concurrency, a junior technician should know how to manually deploy a PowerShell script to a remote machine. By utilizing Sysinternals PsExec, you can remotely invoke the PowerShell executable, bypass the local execution policy, and run a script directly from a network share as the SYSTEM account."
        Code = "psexec \\`$Target -s powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File `"\\server\share\scripts\YourScript.ps1`""
        InPerson = "Copying a .ps1 file to a flash drive, walking to the user's desk, opening PowerShell as Administrator, and running the script manually."
    }
    $data | ConvertTo-Json | Write-Output
    return
}

# --- Path Resolution Fallback ---
if ([string]::IsNullOrWhiteSpace($SharedRoot)) {
    $ScriptDir = Split-Path -Path $MyInvocation.MyCommand.Path
    $SharedRoot = Split-Path -Path $ScriptDir
}

# --- Library Management ---
$LibraryFile = Join-Path -Path $SharedRoot -ChildPath "Core\ScriptLibrary.json"

function Load-Lib {
    if (Test-Path $LibraryFile) {
        try {
            $raw = Get-Content $LibraryFile -Raw -ErrorAction Stop | ConvertFrom-Json
            if ($null -eq $raw) { return @() }
            if ($raw -is [System.Array]) { return $raw } else { return @($raw) }
        } catch { 
            # Process Stability Fix: Throw instead of exit to prevent killing the API Gateway
            throw "CRITICAL: ScriptLibrary.json is corrupted. Aborting to prevent data loss."
        }
    } else { 
        $CoreDir = Join-Path -Path $SharedRoot -ChildPath "Core"
        if (-not (Test-Path $CoreDir)) { New-Item -ItemType Directory -Path $CoreDir -Force | Out-Null }

        $default = @(
            [PSCustomObject]@{ ID=1; Name="Clear DNS Cache (Example)"; Path="\\server\share\Scripts\ClearDNS.ps1" }
        )
        ConvertTo-Json -InputObject $default -Depth 2 | Set-Content $LibraryFile -Force
        return $default
    }
}

function Save-Lib {
    param($d)
    ConvertTo-Json -InputObject @($d) -Depth 2 | Set-Content $LibraryFile -Force
}

# --- UI Library Management ---
if ($Action -eq "GetLibrary") {
    $lib = @(Load-Lib)
    $json = ConvertTo-Json -InputObject $lib -Depth 2 -Compress

    if ($lib.Count -eq 1 -and $json -notmatch "^\[") {
        $json = "[$json]"
    }

    Write-Output $json
    return
}

if ($Action -eq "AddScript") {
    $lib = @(Load-Lib)
    $newID = if ($lib.Count -gt 0) { ([int]($lib | Select-Object -ExpandProperty ID | Measure-Object -Maximum).Maximum) + 1 } else { 1 }

    $cleanName = $ScriptName.Trim() -replace '[\x00-\x1F]', ''
    $cleanPath = $ScriptPath.Trim() -replace '[\x00-\x1F]', ''

    $lib += [PSCustomObject]@{ ID=$newID; Name=$cleanName; Path=$cleanPath }
    Save-Lib $lib

    $SafeScriptName = Escape-Html $cleanName
    Write-Output "[SDA] [+] Added '$SafeScriptName' to the Custom Script Library."
    return
}

if ($Action -eq "DeleteScript") {
    $lib = @(Load-Lib)
    $lib = $lib | Where-Object { $_.ID -ne [int]$ScriptID }
    Save-Lib $lib
    Write-Output "[SDA] [-] Script removed from the Custom Script Library."
    return
}

# --- Main Execution ---
if ($Action -eq "Execute") {

    if ([string]::IsNullOrWhiteSpace($Target)) { Write-Output "[!] ERROR: Target PC(s) required."; return }
    if (-not (Test-Path $ScriptPath)) { Write-Output "[!] ERROR: Cannot read script at $ScriptPath. Verify path and permissions."; return }

    # --- Security Boundary: Trusted Path Validation ---
    $resolvedPath = [System.IO.Path]::GetFullPath($ScriptPath)

    # Defense-in-Depth: Prevent UNC path traversal bypasses on older .NET versions
    if ($resolvedPath -match '\.\.') {
        Write-Output "<div style='color: var(--accent-danger); font-weight: bold;'><i class='fa-solid fa-shield-halved'></i> SECURITY BLOCK: Execution Aborted</div>"
        Write-Output "<div style='color: var(--text-secondary); margin-top: 4px;'>Path traversal sequences (..) are not permitted in script paths.</div>"
        return
    }

    $isTrusted = $false
    $trustedRoots = @([System.IO.Path]::GetFullPath($SharedRoot))

    $ConfigFile = Join-Path -Path $SharedRoot -ChildPath "Config\config.json"
    if (Test-Path $ConfigFile) {
        try {
            $Config = Get-Content $ConfigFile -Raw | ConvertFrom-Json
            if ($Config.AccessControl.TrustedScriptRoots) {
                foreach ($tr in $Config.AccessControl.TrustedScriptRoots) {
                    $trustedRoots += [System.IO.Path]::GetFullPath($tr)
                }
            }
        } catch {}
    }

    foreach ($root in $trustedRoots) {
        if ($resolvedPath.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
            $isTrusted = $true
            break
        }
    }

    if (-not $isTrusted) {
        Write-Output "<div style='color: var(--accent-danger); font-weight: bold;'><i class='fa-solid fa-shield-halved'></i> SECURITY BLOCK: Execution Aborted</div>"
        Write-Output "<div style='color: var(--text-secondary); margin-top: 4px;'>The path <strong>$ScriptPath</strong> is outside the trusted execution boundaries.</div>"
        Write-Output "<div style='color: var(--text-secondary); margin-top: 4px;'>To allow this, an administrator must add the directory to <strong>TrustedScriptRoots</strong> in <em>\\Config\\config.json</em>.</div>"
        return
    }

    # Defense-in-Depth: Explicitly validate file extension to prevent arbitrary binary execution
    if ([System.IO.Path]::GetExtension($resolvedPath) -ne '.ps1') {
        Write-Output "<div style='color: var(--accent-danger); font-weight: bold;'><i class='fa-solid fa-shield-halved'></i> SECURITY BLOCK: Execution Aborted</div>"
        Write-Output "<div style='color: var(--text-secondary); margin-top: 4px;'>Only <strong>.ps1</strong> files are permitted for remote execution.</div>"
        return
    }
    # --- End Security Boundary ---

    $SafeScriptName = Escape-Html $ScriptName
    $PayloadString = Get-Content $ScriptPath -Raw
    $PayloadBlock = [scriptblock]::Create($PayloadString)

    $TargetArray = @($Target -split ',' | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $psExecPath = Join-Path -Path $SharedRoot -ChildPath "Core\psexec.exe"

    # --- Single Target Execution ---
    if ($TargetArray.Count -eq 1) {
        $SingleTarget = $TargetArray[0]
        Write-Output "========================================"
        Write-Output "[SDA] CUSTOM SCRIPT EXECUTION"
        Write-Output "========================================"
        Write-Output "[i] Executing '$SafeScriptName' on $SingleTarget..."

        if (-not (Test-Connection -ComputerName $SingleTarget -Count 1 -Quiet)) { Write-Output "[!] Offline."; return }

        try {
            Write-Output " > Executing via WinRM..."
            $Output = Invoke-Command -ComputerName $SingleTarget -ScriptBlock $PayloadBlock -ErrorAction Stop | Out-String
            Write-Output "`n[SDA SUCCESS] Script Output:`n$Output"
        } catch {
            Write-Output "[!] WinRM Failed. Initiating PsExec Fallback..."
            if (Test-Path $psExecPath) {
                try {
                    $Bytes = [System.Text.Encoding]::Unicode.GetBytes($PayloadString)
                    $EncodedCommand = [Convert]::ToBase64String($Bytes)

                    # Note: Single-target PsExec is intentionally synchronous to capture output for troubleshooting
                    $Output = & $psExecPath -accepteula -nobanner \\$SingleTarget -s powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand $EncodedCommand 2>&1 | Out-String
                    Write-Output "`n[SDA SUCCESS] Script Output (via PsExec):`n$Output"
                } catch { Write-Output "`n[!] FATAL ERROR: Both WinRM and PsExec failed." }
            } else { Write-Output "`n[!] FATAL ERROR: psexec.exe is missing." }
        }

        if (-not [string]::IsNullOrWhiteSpace($SharedRoot)) {
            $AuditHelper = Join-Path -Path $SharedRoot -ChildPath "Core\Helper_AuditLog.ps1"
            if (Test-Path $AuditHelper) { & $AuditHelper -Target $SingleTarget -Action "Executed Custom Script: $ScriptName" -SharedRoot $SharedRoot }
        }
        return
    }

    # --- Mass Execution ---
    Write-Output "========================================"
    Write-Output "[SDA] MASS SCRIPT EXECUTION"
    Write-Output "========================================"
    Write-Output "[i] Script: $SafeScriptName"
    Write-Output "[i] Total Targets: $($TargetArray.Count)"

    $Online = @(); $Offline = @(); $SuccessWinRM = @(); $SuccessPsExec = @(); $Failed = @()

    Write-Output "`n[1/3] Performing rapid ping sweep..."
    foreach ($t in $TargetArray) { if (Test-Connection -ComputerName $t -Count 1 -Quiet) { $Online += $t } else { $Offline += $t } }

    if ($Online.Count -gt 0) {
        Write-Output "`n[2/3] Dispatching parallel WinRM commands..."

        $WinRMJob = Invoke-Command -ComputerName $Online -ScriptBlock $PayloadBlock -ErrorVariable WinRMErrors -ErrorAction SilentlyContinue -AsJob
        Wait-Job $WinRMJob | Out-Null
        $JobResults = Receive-Job $WinRMJob
		Remove-Job $WinRMJob -Force

        # Logic Fix: Properly separate error lookup from fallback list
        $WinRMErrorsList = @()
        foreach ($err in $WinRMErrors) { if ($err.TargetObject) { $WinRMErrorsList += $err.TargetObject.ToString().ToUpper() } }

        $FailedWinRM = @()
        foreach ($t in $Online) { 
            if ($WinRMErrorsList -contains $t.ToUpper()) { $FailedWinRM += $t } 
            else { $SuccessWinRM += $t } 
        }

        if ($FailedWinRM.Count -gt 0) {
            Write-Output "`n[3/3] Initiating PsExec fallback for blocked targets..."
            if (Test-Path $psExecPath) {
                $Bytes = [System.Text.Encoding]::Unicode.GetBytes($PayloadString)
                $EncodedCommand = [Convert]::ToBase64String($Bytes)

                foreach ($t in $FailedWinRM) {
                    try {
                        # Note: Mass-target PsExec uses -d (detached) to prevent hanging the API Gateway
                        $ArgsList = "-accepteula -nobanner -d \\$t -s powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand $EncodedCommand"
                        $Process = Start-Process -FilePath $psExecPath -ArgumentList $ArgsList -Wait -WindowStyle Hidden -PassThru
                        if ($Process.ExitCode -eq 0) { $SuccessPsExec += $t } else { $Failed += $t }
                    } catch { $Failed += $t }
                }
            } else { $Failed += $FailedWinRM }
        }
    }

    $TotalSuccess = $SuccessWinRM.Count + $SuccessPsExec.Count
    $html = "<div style='background: #1e293b; padding: 16px; border-radius: 8px; border-left: 4px solid #9b59b6; margin-top: 15px; margin-bottom: 10px; box-shadow: 0 4px 6px rgba(0,0,0,0.2); font-family: system-ui, sans-serif;'>"
    $html += "<div style='color: #f8fafc; font-weight: bold; font-size: 1.1rem; margin-bottom: 12px;'><i class='fa-solid fa-scroll'></i> Mass Script Execution Report</div>"
    $html += "<div style='display: grid; grid-template-columns: 1fr 1fr; gap: 10px; margin-bottom: 10px;'>"
    $html += "<div style='background: #0f172a; padding: 10px; border-radius: 6px; border: 1px solid #334155;'><span style='color: #94a3b8; font-size: 0.85rem;'>Total Targets</span><br><span style='color: #f8fafc; font-size: 1.2rem; font-weight: bold;'>$($TargetArray.Count)</span></div>"
    $html += "<div style='background: #0f172a; padding: 10px; border-radius: 6px; border: 1px solid #334155;'><span style='color: #94a3b8; font-size: 0.85rem;'>Successful Executions</span><br><span style='color: #2ecc71; font-size: 1.2rem; font-weight: bold;'>$TotalSuccess</span></div>"
    $html += "</div>"

    # Defense-in-Depth: Escape HTML for arrays rendered into the UI
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
        if (Test-Path $AuditHelper) { & $AuditHelper -Target "MASS SCRIPT ($TotalSuccess PCs)" -Action "Executed Script: $ScriptName" -SharedRoot $SharedRoot }
    }
}
