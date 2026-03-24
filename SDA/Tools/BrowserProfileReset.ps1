<#
.SYNOPSIS
    SDA Web-Ready Tool: BrowserProfileReset.ps1
.DESCRIPTION
    Completely resets Chrome and Edge browser profiles for a specific AD user on a remote machine.
    Strictly targets the \Default profile. Safely backs up bookmarks to a local temp directory, 
    kills browser processes, deletes corrupted AppData, and restores the bookmarks.
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
        StepName = "BROWSER PROFILE RESET"
        Description = "While SDA uses a complex PowerShell pipeline to safely backup and restore the user's bookmarks during a reset, a junior technician should know how to forcefully wipe a corrupted application profile manually. By utilizing Sysinternals PsExec, you can remotely execute a chained CMD command to forcefully kill the frozen browser process using 'taskkill', and then completely delete the corrupted AppData directory using 'rmdir'."
        Code = "psexec \\`$Target -s cmd.exe /c `"taskkill /F /IM chrome.exe & rmdir /S /Q `"C:\Users\`$TargetUser\AppData\Local\Google\Chrome\User Data`"`""
        InPerson = "Opening Task Manager to kill frozen browsers, navigating to %LocalAppData%, copying the Bookmarks file to the Desktop, deleting the 'User Data' folders manually, and pasting the Bookmarks file back into the new profile."
    }
    $data | ConvertTo-Json | Write-Output
    return
}

# --- Main Execution ---
Write-Output "========================================"
Write-Output "[SDA] BROWSER PROFILE RESET"
Write-Output "========================================"

if ([string]::IsNullOrWhiteSpace($Target) -or [string]::IsNullOrWhiteSpace($TargetUser)) { 
    Write-Output "[!] ERROR: Both Target PC and Target User are required for a Profile Reset."
    return 
}

if (-not (Test-Connection -ComputerName $Target -Count 1 -Quiet)) {
    Write-Output "[!] Offline. $Target is not responding to ping."
    return
}

$ActionLog = "Browser Profile Reset Executed ($TargetUser)"

# Sanitize TargetUser to prevent quote injection
$SafeUser = $TargetUser -replace "'", "''"

$PayloadString = @"
    `$ErrorActionPreference = 'SilentlyContinue'
    `$User = '$SafeUser'
    `$userDir = `"C:\Users\`$User`"

    # 1. Profile Validation
    if (!(Test-Path `$userDir)) {
        Write-Output `"---ERROR--- Local profile directory not found for AD User: `$User. Aborting.---ERROR---`"
        exit
    }

    `$cRoot = `"`$userDir\AppData\Local\Google\Chrome\User Data`"
    `$eRoot = `"`$userDir\AppData\Local\Microsoft\Edge\User Data`"
    `$backupDir = `"C:\Windows\Temp\SDA_BM_\`$User`"

    # 2. Secure Bookmarks (Strictly targeting 'Default' profile)
    if (!(Test-Path `$backupDir)) { New-Item -ItemType Directory -Path `$backupDir -Force | Out-Null }

    `$cBM = `"`$cRoot\Default\Bookmarks`"
    `$eBM = `"`$eRoot\Default\Bookmarks`"

    `$cBackedUp = `$false
    `$eBackedUp = `$false

    if (Test-Path `$cBM) { Copy-Item `$cBM `"`$backupDir\Chrome_BM`" -Force; `$cBackedUp = `$true }
    if (Test-Path `$eBM) { Copy-Item `$eBM `"`$backupDir\Edge_BM`" -Force; `$eBackedUp = `$true }

    # 3. Terminate Processes
    Stop-Process -Name `"chrome`", `"msedge`" -Force
    Start-Sleep -Seconds 2

    # 4. Purge Corrupted Profiles (Wipes the whole User Data to ensure a clean slate)
    if (Test-Path `$cRoot) { Remove-Item `$cRoot -Recurse -Force }
    if (Test-Path `$eRoot) { Remove-Item `$eRoot -Recurse -Force }

    # 5. Restore Bookmarks to the Default profile
    if (`$cBackedUp) {
        New-Item -ItemType Directory -Path `"`$cRoot\Default`" -Force | Out-Null
        Copy-Item `"`$backupDir\Chrome_BM`" `"`$cRoot\Default\Bookmarks`" -Force
    }
    if (`$eBackedUp) {
        New-Item -ItemType Directory -Path `"`$eRoot\Default`" -Force | Out-Null
        Copy-Item `"`$backupDir\Edge_BM`" `"`$eRoot\Default\Bookmarks`" -Force
    }

    # Cleanup
    Remove-Item `$backupDir -Recurse -Force
    Write-Output `"---SUCCESS---`"
"@

$PayloadBlock = [scriptblock]::Create($PayloadString)

try {
    Write-Output "[i] Attempting connection to $Target via WinRM..."
    Write-Output " > Validating AD User Profile..."
    Write-Output " > Securing 'Default' bookmarks for $TargetUser..."
    Write-Output " > Terminating browser processes..."
    Write-Output " > Purging AppData and restoring bookmarks..."

    $Output = Invoke-Command -ComputerName $Target -ErrorAction Stop -ScriptBlock $PayloadBlock | Out-String

    if ($Output -match "---ERROR---(.*?)---ERROR---") {
        Write-Output "`n[!] ERROR: $($matches[1])"
    } elseif ($Output -match "---SUCCESS---") {
        Write-Output "`n[SDA SUCCESS] Browser profiles reset successfully via WinRM!"
    } else {
        Write-Output "`n[!] ERROR: Unexpected output from target."
    }

} catch {
    Write-Output "[!] WinRM Failed or Blocked. Initiating PsExec Fallback..."

    $psExecPath = Join-Path -Path $SharedRoot -ChildPath "Core\psexec.exe"
    if (Test-Path $psExecPath) {
        try {
            $Bytes = [System.Text.Encoding]::Unicode.GetBytes($PayloadString)
            $EncodedCommand = [Convert]::ToBase64String($Bytes)

            $ArgsList = "-accepteula -nobanner -d \\$Target -s powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand $EncodedCommand"
            $Process = Start-Process -FilePath $psExecPath -ArgumentList $ArgsList -Wait -WindowStyle Hidden -PassThru

            if ($Process.ExitCode -eq 0) {
                Write-Output "`n[SDA SUCCESS] Browser profiles reset successfully via PsExec!"
                $ActionLog += " [PsExec Fallback]"
            } else {
                Write-Output "`n[!] ERROR: PsExec executed but returned exit code $($Process.ExitCode)."
            }
        } catch {
            Write-Output "`n[!] FATAL ERROR: Both WinRM and PsExec failed."
        }
    } else {
        Write-Output "`n[!] FATAL ERROR: WinRM failed and psexec.exe is missing from \Core."
    }
}

if (-not [string]::IsNullOrWhiteSpace($SharedRoot)) {
    $AuditHelper = Join-Path -Path $SharedRoot -ChildPath "Core\Helper_AuditLog.ps1"
    if (Test-Path $AuditHelper) {
        & $AuditHelper -Target $Target -Action $ActionLog -SharedRoot $SharedRoot
    }
}