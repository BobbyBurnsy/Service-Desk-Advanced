<#
.SYNOPSIS
    SDA Web-Ready Tool: OutOfBandDataPreservation.ps1
.DESCRIPTION
    Securely extracts Google Chrome and Microsoft Edge bookmarks for a specified AD user.
    Strictly targets the \Default profile. Bypasses SMB/File Sharing firewalls by reading 
    the files locally on the target, encoding them to Base64, and transmitting them back 
    via standard output streams.
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
        StepName = "OUT-OF-BAND DATA PRESERVATION"
        Description = "While SDA uses a complex Base64 encoding pipeline to bypass strict SMB firewalls, a junior technician should know how to manually extract files over the network using classic administrative shares. By utilizing the built-in 'xcopy' command, you can reach directly into the target's hidden C`$ share and pull their Chrome bookmarks file straight to your local desktop."
        Code = "xcopy `"\\`$Target\C`$\Users\`$TargetUser\AppData\Local\Google\Chrome\User Data\Default\Bookmarks`" `"%USERPROFILE%\Desktop\`" /Y"
        InPerson = "Opening File Explorer, typing '%LocalAppData%\Google\Chrome\User Data\Default' into the address bar, copying the 'Bookmarks' file, and saving it to a flash drive."
    }
    $data | ConvertTo-Json | Write-Output
    return
}

# --- Main Execution ---
Write-Output "========================================"
Write-Output "[SDA] OUT-OF-BAND DATA PRESERVATION"
Write-Output "========================================"

if ([string]::IsNullOrWhiteSpace($Target) -or [string]::IsNullOrWhiteSpace($TargetUser)) { 
    Write-Output "[!] ERROR: Both Target PC and Target User are required."
    return 
}

if (-not (Test-Connection -ComputerName $Target -Count 1 -Quiet)) {
    Write-Output "[!] Offline. $Target is not responding to ping."
    return
}

$ActionLog = "Out-of-Band Data Preservation Executed ($TargetUser)"

# Sanitize TargetUser to prevent quote injection
$SafeUser = $TargetUser -replace "'", "''"

# Set up the local export directory on the Technician's PC
$timestamp = (Get-Date).ToString("yyyyMMdd_HHmmss")
$destFolder = "C:\SDA\Exports\Bookmarks_$Target_$SafeUser_$timestamp"
if (-not (Test-Path $destFolder)) { New-Item -ItemType Directory -Path $destFolder -Force | Out-Null }

$PayloadString = @"
    `$ErrorActionPreference = 'SilentlyContinue'
    `$User = '$SafeUser'
    `$userDir = `"C:\Users\`$User`"

    # 1. Profile Validation
    if (!(Test-Path `$userDir)) {
        Write-Output `"---ERROR--- Local profile directory not found for AD User: `$User. Aborting.---ERROR---`"
        exit
    }

    # 2. Strict Default Profile Targeting
    `$cPath = `"`$userDir\AppData\Local\Google\Chrome\User Data\Default\Bookmarks`"
    `$ePath = `"`$userDir\AppData\Local\Microsoft\Edge\User Data\Default\Bookmarks`"

    if (Test-Path `$cPath) {
        `$b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes(`$cPath))
        Write-Output `"---CHROME_START---`$b64---CHROME_END---`"
    }
    if (Test-Path `$ePath) {
        `$b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes(`$ePath))
        Write-Output `"---EDGE_START---`$b64---EDGE_END---`"
    }
"@

$PayloadBlock = [scriptblock]::Create($PayloadString)
$RawOutput = $null
$MethodUsed = "WinRM"

try {
    Write-Output "[i] Attempting connection to $Target via WinRM..."
    Write-Output " > Validating AD User Profile..."
    Write-Output " > Extracting and encoding 'Default' bookmarks..."

    $RawOutput = Invoke-Command -ComputerName $Target -ErrorAction Stop -ScriptBlock $PayloadBlock | Out-String
} catch {
    Write-Output "[!] WinRM Failed or Blocked. Initiating PsExec Fallback..."
    $MethodUsed = "PsExec"

    $psExecPath = Join-Path -Path $SharedRoot -ChildPath "Core\psexec.exe"
    if (Test-Path $psExecPath) {
        try {
            $Bytes = [System.Text.Encoding]::Unicode.GetBytes($PayloadString)
            $EncodedCommand = [Convert]::ToBase64String($Bytes)

            $ArgsList = "/accepteula \\$Target -s powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand $EncodedCommand"
            $RawOutput = & $psExecPath $ArgsList 2>&1 | Out-String
            $ActionLog += " [PsExec Fallback]"
        } catch {
            Write-Output "`n[!] FATAL ERROR: Both WinRM and PsExec failed."
            Remove-Item $destFolder -Force -ErrorAction SilentlyContinue
            return
        }
    } else {
        Write-Output "`n[!] FATAL ERROR: WinRM failed and psexec.exe is missing from \Core."
        Remove-Item $destFolder -Force -ErrorAction SilentlyContinue
        return
    }
}

# Check for Profile Validation Error
if ($RawOutput -match "---ERROR---(.*?)---ERROR---") {
    Write-Output "`n[!] ERROR: $($matches[1])"
    Remove-Item $destFolder -Force -ErrorAction SilentlyContinue
    return
}

Write-Output " > Decoding Base64 streams and reconstructing files..."

$FullOutputString = $RawOutput -join ""
$foundData = $false
$chromeStatus = "<span style='color: #7f8c8d;'>Not Found</span>"
$edgeStatus = "<span style='color: #7f8c8d;'>Not Found</span>"

if ($FullOutputString -match '---CHROME_START---(.*?)---CHROME_END---') {
    try {
        $bytes = [Convert]::FromBase64String($matches[1])
        [IO.File]::WriteAllBytes("$destFolder\Chrome_Bookmarks", $bytes)
        $chromeStatus = "<span style='color: #2ecc71; font-weight: bold;'>Secured</span>"
        $foundData = $true
    } catch { $chromeStatus = "<span style='color: #e74c3c;'>Decode Error</span>" }
}

if ($FullOutputString -match '---EDGE_START---(.*?)---EDGE_END---') {
    try {
        $bytes = [Convert]::FromBase64String($matches[1])
        [IO.File]::WriteAllBytes("$destFolder\Edge_Bookmarks", $bytes)
        $edgeStatus = "<span style='color: #2ecc71; font-weight: bold;'>Secured</span>"
        $foundData = $true
    } catch { $edgeStatus = "<span style='color: #e74c3c;'>Decode Error</span>" }
}

if ($foundData) {
    Write-Output "`n[SDA SUCCESS] Data Preservation complete via $MethodUsed!"

    # Build the HTML Success Card
    $html = "<div style='background: #1e293b; padding: 16px; border-radius: 8px; border-left: 4px solid #3498db; margin-top: 15px; margin-bottom: 10px; box-shadow: 0 4px 6px rgba(0,0,0,0.2); font-family: system-ui, sans-serif;'>"
    $html += "<div style='color: #f8fafc; font-weight: bold; font-size: 1.1rem; margin-bottom: 12px;'><i class='fa-solid fa-bookmark'></i> Bookmark Preservation Report</div>"

    $html += "<div style='display: grid; grid-template-columns: 120px 1fr; gap: 8px; font-size: 0.95rem; margin-bottom: 12px;'>"
    $html += "<span style='color: #94a3b8;'><i class='fa-brands fa-chrome'></i> Chrome:</span> $chromeStatus"
    $html += "<span style='color: #94a3b8;'><i class='fa-brands fa-edge'></i> Edge:</span> $edgeStatus"
    $html += "</div>"

    $html += "<div style='border-top: 1px solid #334155; padding-top: 10px; color: #94a3b8; font-size: 0.85rem;'>"
    $html += "<i class='fa-solid fa-folder-open' style='color: #3498db;'></i> Saved to: $destFolder"
    $html += "</div></div>"

    Write-Output $html

    # Automatically pop open the folder
    Start-Process explorer.exe -ArgumentList "`"$destFolder`""

    if (-not [string]::IsNullOrWhiteSpace($SharedRoot)) {
        $AuditHelper = Join-Path -Path $SharedRoot -ChildPath "Core\Helper_AuditLog.ps1"
        if (Test-Path $AuditHelper) {
            & $AuditHelper -Target $Target -Action $ActionLog -SharedRoot $SharedRoot
        }
    }
} else {
    Write-Output "`n[!] No 'Default' bookmarks found for user $TargetUser on $Target."
    Remove-Item $destFolder -Force -ErrorAction SilentlyContinue
}