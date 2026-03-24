<#
.SYNOPSIS
    SDA Web-Ready Tool: BitLockerStatusVerification.ps1
.DESCRIPTION
    Remotely queries the target computer to retrieve the BitLocker encryption 
    status for all connected volumes. Additionally queries Active Directory 
    for any backed-up recovery keys associated with the computer object.
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
        StepName = "BITLOCKER STATUS VERIFICATION & AD KEY RECOVERY"
        Description = "SDA automates two critical tasks: checking the live encryption status of the drive, and querying Active Directory for backed-up recovery keys. A junior technician should know how to do both manually. You can use 'manage-bde' via PsExec to check the live status, and the ActiveDirectory PowerShell module to extract the hidden 'msFVE-RecoveryInformation' object attached to the computer in AD."
        Code = "1. psexec \\`$Target -s manage-bde -status`n2. Get-ADObject -Filter `"objectClass -eq 'msFVE-RecoveryInformation'`" -SearchBase (Get-ADComputer `$Target).DistinguishedName -Properties 'msFVE-RecoveryPassword'"
        InPerson = "1. Navigating to 'Control Panel > System and Security > BitLocker Drive Encryption' on the target PC.`n2. Opening Active Directory Users and Computers (ADUC), finding the computer object, opening Properties, and viewing the 'BitLocker Recovery' tab."
    }
    $data | ConvertTo-Json | Write-Output
    return
}

# --- Main Execution ---
Write-Output "========================================"
Write-Output "[SDA] BITLOCKER STATUS VERIFICATION"
Write-Output "========================================"

if ([string]::IsNullOrWhiteSpace($Target)) { 
    Write-Output "[!] ERROR: Target PC is required."
    return 
}

if (-not (Test-Connection -ComputerName $Target -Count 1 -Quiet)) {
    Write-Output "[!] Offline. $Target is not responding to ping."
    return
}

$ActionLog = "BitLocker Status Verification Executed"

$PayloadString = @"
    `$ErrorActionPreference = 'SilentlyContinue'
    `$volumes = Get-BitLockerVolume

    `$results = @()
    if (`$volumes) {
        foreach (`$vol in `$volumes) {
            `$protectors = (`$vol.KeyProtector | Select-Object -ExpandProperty KeyProtectorType) -join ', '
            `$results += [PSCustomObject]@{
                MountPoint = `$vol.MountPoint
                Status     = `$vol.VolumeStatus.ToString()
                Protection = `$vol.ProtectionStatus.ToString()
                Method     = `$vol.EncryptionMethod.ToString()
                Protectors = if (`$protectors) { `$protectors } else { 'None' }
            }
        }
    }

    `$json = @(`$results) | ConvertTo-Json -Compress
    Write-Output `"---JSON_START---`$json---JSON_END---`"
"@

$PayloadBlock = [scriptblock]::Create($PayloadString)
$RawOutputString = $null
$MethodUsed = "WinRM"

try {
    Write-Output "[i] Attempting connection to $Target via WinRM..."
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

if ($RawOutputString -match '---JSON_START---(.*?)---JSON_END---') {
    try {
        $bdeData = $matches[1] | ConvertFrom-Json
        if ($bdeData -isnot [System.Array]) { $bdeData = @($bdeData) }

        if ($bdeData.Count -gt 0) {
            Write-Output "`n[SDA SUCCESS] BitLocker telemetry retrieved via $MethodUsed!`n"

            # --- Query Active Directory for Recovery Keys ---
            $adKeysHtml = ""
            try {
                Write-Output " > Querying Active Directory for backed-up recovery keys..."
                $adComp = Get-ADComputer -Identity $Target -ErrorAction SilentlyContinue
                if ($adComp) {
                    $adKeys = Get-ADObject -Filter "objectClass -eq 'msFVE-RecoveryInformation'" -SearchBase $adComp.DistinguishedName -Properties 'msFVE-RecoveryPassword', 'whenCreated' -ErrorAction SilentlyContinue | Sort-Object whenCreated -Descending

                    if ($adKeys) {
                        $adKeysHtml += "<div style='margin-top: 16px; padding-top: 12px; border-top: 1px solid #334155;'>"
                        $adKeysHtml += "<div style='color: #3498db; font-weight: bold; margin-bottom: 8px; font-size: 0.95rem;'><i class='fa-brands fa-windows'></i> Active Directory Recovery Keys</div>"
                        foreach ($k in $adKeys) {
                            $pw = $k.'msFVE-RecoveryPassword'
                            $date = if ($k.whenCreated) { $k.whenCreated.ToString("MM/dd/yyyy") } else { "Unknown Date" }
                            $adKeysHtml += "<div style='display: flex; justify-content: space-between; align-items: center; background: #0f172a; padding: 10px; border-radius: 6px; margin-bottom: 6px; border: 1px solid #334155;'>"
                            $adKeysHtml += "<span style='color: #2ecc71; font-family: Consolas, monospace; font-size: 0.95rem; font-weight: bold;'>$pw</span>"
                            $adKeysHtml += "<span style='color: #94a3b8; font-size: 0.8rem;'>$date</span>"
                            $adKeysHtml += "</div>"
                        }
                        $adKeysHtml += "</div>"
                    } else {
                        $adKeysHtml += "<div style='margin-top: 12px; padding-top: 12px; border-top: 1px solid #334155; color: #94a3b8; font-size: 0.85rem;'><i class='fa-solid fa-circle-info'></i> No recovery keys found in Active Directory for this device.</div>"
                    }
                }
            } catch {
                $adKeysHtml += "<div style='margin-top: 12px; padding-top: 12px; border-top: 1px solid #334155; color: #e74c3c; font-size: 0.85rem;'><i class='fa-solid fa-triangle-exclamation'></i> Failed to query Active Directory for recovery keys.</div>"
            }

            # --- Build UI Graphic ---
            $html = "<div style='display: flex; flex-direction: column; gap: 12px; margin-top: 10px; margin-bottom: 10px;'>"

            foreach ($vol in $bdeData) {
                $icon = "fa-lock-open"
                $statusColor = "#e74c3c"

                if ($vol.Protection -eq "On") { 
                    $icon = "fa-lock"
                    $statusColor = "#2ecc71"
                } elseif ($vol.Status -match "Progress") {
                    $icon = "fa-spinner fa-spin"
                    $statusColor = "#f1c40f"
                }

                $html += "<div style='background: #1e293b; padding: 16px; border-radius: 8px; border-left: 4px solid $statusColor; box-shadow: 0 4px 6px rgba(0,0,0,0.2); font-family: system-ui, sans-serif;'>"
                $html += "<div style='display: flex; justify-content: space-between; align-items: center; margin-bottom: 12px;'>"
                $html += "<div style='color: #f8fafc; font-weight: bold; font-size: 1.1rem;'><i class='fa-solid fa-hard-drive'></i> Drive $($vol.MountPoint)</div>"
                $html += "<div style='color: $statusColor; font-weight: bold; font-size: 0.95rem; text-transform: uppercase;'><i class='fa-solid $icon'></i> $($vol.Protection)</div>"
                $html += "</div>"
                $html += "<div style='display: grid; grid-template-columns: 120px 1fr; gap: 8px; font-size: 0.9rem;'>"
                $html += "<span style='color: #94a3b8;'>Volume Status:</span><span style='color: #cbd5e1;'>$($vol.Status)</span>"
                $html += "<span style='color: #94a3b8;'>Encryption:</span><span style='color: #cbd5e1;'>$($vol.Method)</span>"
                $html += "<span style='color: #94a3b8;'>Key Protectors:</span><span style='color: #cbd5e1;'>$($vol.Protectors)</span>"
                $html += "</div>"

                # Append AD Keys if this is the OS drive (usually C:)
                if ($vol.MountPoint -match "C:") {
                    $html += $adKeysHtml
                }

                $html += "</div>"
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
            Write-Output "`n[i] No BitLocker volumes found or feature is not installed."
        }
    } catch {
        Write-Output "`n[!] ERROR: Failed to parse BitLocker data JSON."
    }
} else {
    Write-Output "`n[!] ERROR: No valid BitLocker data returned from target."
}