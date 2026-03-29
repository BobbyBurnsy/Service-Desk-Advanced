<#
.SYNOPSIS
    SDA Web-Ready Core: IntuneEntraManager.ps1
.DESCRIPTION
    A headless API router for Microsoft Intune and Entra ID management.
    Takes an Action parameter from the Web UI to retrieve devices, BitLocker keys,
    LAPS passwords, or manage MFA methods via the Microsoft Graph API.
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
    [string]$Action = "GetDevices",

    [Parameter(Mandatory=$false)]
    [string]$DeviceId,

    [Parameter(Mandatory=$false)]
    [string]$PhoneNumber,

    [Parameter(Mandatory=$false)]
    [bool]$NoPrompt = $false,

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
        StepName = "INTUNE & ENTRA MANAGER"
        Description = "Because this module interacts with Entra ID and Intune, there is no classic 'CMD' equivalent. The modern command-line for the Microsoft Cloud is the Graph API. While SDA automates the complex authentication and device correlation, a junior technician should know how to manually pull critical data, like a BitLocker recovery key, directly from a standard PowerShell terminal using the Microsoft.Graph module."
        Code = "Get-MgInformationProtectionBitlockerRecoveryKey -Filter `"deviceId eq '<AzureAD-Device-ID>'`""
        InPerson = "Logging into the Microsoft Endpoint Manager (Intune) web portal, searching for the user or device, navigating to the 'Recovery Keys' tab, and copying the 48-digit key."
    }
    $data | ConvertTo-Json | Write-Output
    return
}

$Context = Get-MgContext -ErrorAction SilentlyContinue
if (-not $Context) {
    if ($Action -eq "GetDevices") {
        Write-Output '{"error":"Graph API not connected. Please restart the SDA console to authenticate."}'
    } else {
        Write-Output "<div style='color:#e74c3c;'><i class='fa-solid fa-triangle-exclamation'></i> Graph API not connected. Please restart the SDA console to authenticate.</div>"
    }
    return
}

$TenantDomain = ""
if (-not [string]::IsNullOrWhiteSpace($SharedRoot)) {
    $ConfigFile = Join-Path -Path $SharedRoot -ChildPath "Config\config.json"
    if (Test-Path $ConfigFile) {
        try {
            $Config = Get-Content $ConfigFile -Raw | ConvertFrom-Json
            $TenantDomain = $Config.Organization.TenantDomain
        } catch {}
    }
}

$EmailToPass = $TargetUser
if ($EmailToPass -notmatch "@") {
    try {
        $adObj = Get-ADUser -Identity $TargetUser -Properties UserPrincipalName, EmailAddress -ErrorAction SilentlyContinue
        if ($adObj.UserPrincipalName) { 
            $EmailToPass = $adObj.UserPrincipalName 
        } elseif ($adObj.EmailAddress) { 
            $EmailToPass = $adObj.EmailAddress 
        } else {
            $EmailToPass = "$TargetUser@$TenantDomain"
        }
    } catch { 
        $EmailToPass = "$TargetUser@$TenantDomain"
    }
}

if (-not [string]::IsNullOrWhiteSpace($TenantDomain)) {
    $escapedDomain = [regex]::Escape($TenantDomain)
    if ($EmailToPass -notmatch "(?i)@$escapedDomain$") {
        if ($Action -eq "GetDevices") {
            Write-Output '{"error":"Cross-Agency Block: Target user does not belong to the authorized tenant domain."}'
        } else {
            Write-Output "<div style='color:#e74c3c;'><i class='fa-solid fa-shield-halved'></i> Cross-Agency Block: Target user does not belong to the authorized tenant domain.</div>"
        }
        return
    }
}

# --- Strict Input Validation ---
if (-not [string]::IsNullOrWhiteSpace($DeviceId) -and $DeviceId -notmatch '^[a-fA-F0-9\-]{36}$') {
    Write-Output "<div style='color:#e74c3c;'><i class='fa-solid fa-triangle-exclamation'></i> Invalid Device ID format. Must be a valid GUID.</div>"
    return
}

if ($Action -eq "AddSMS" -and $PhoneNumber -notmatch '^\+[1-9]\d{7,14}$') {
    Write-Output "<div style='color:#e74c3c;'><i class='fa-solid fa-triangle-exclamation'></i> Invalid phone number format. Must be E.164 format (e.g., +15550001111).</div>"
    return
}

# --- OData Injection Defense ---
$SafeTarget = if ($Target) { $Target.Replace("'", "''") } else { "" }
$SafeEmail  = if ($EmailToPass) { $EmailToPass.Replace("'", "''") } else { "" }

try {
    switch ($Action) {
        "GetDevices" {
            $RawDeviceList = @()
            $ResolvedUser = $null

            if (-not [string]::IsNullOrWhiteSpace($SafeTarget)) {
                $deviceMatch = Get-MgDeviceManagementManagedDevice -Filter "deviceName eq '$SafeTarget'" -ErrorAction SilentlyContinue
                if ($deviceMatch) { $RawDeviceList += $deviceMatch }
            }

            if (-not [string]::IsNullOrWhiteSpace($SafeEmail)) {
                $users = Get-MgUser -Filter "userPrincipalName eq '$SafeEmail' or mail eq '$SafeEmail'" -ErrorAction SilentlyContinue
                if ($users) {
                    $ResolvedUser = $users[0]
                    $userDevices = Get-MgDeviceManagementManagedDevice -Filter "userId eq '$($ResolvedUser.Id)'" -ErrorAction SilentlyContinue
                    if ($userDevices) { $RawDeviceList += $userDevices }
                }
            }

            if ($RawDeviceList.Count -gt 0) {
                $GlobalDevices = $RawDeviceList | Group-Object Id | ForEach-Object { $_.Group[0] } | Sort-Object deviceName

                $exportList = @()
                foreach ($dev in $GlobalDevices) {
                    $exportList += [PSCustomObject]@{
                        Id = $dev.Id
                        AzureAdDeviceId = $dev.AzureAdDeviceId
                        DeviceName = $dev.DeviceName
                        OS = $dev.OperatingSystem
                        Compliance = $dev.ComplianceState
                        Serial = $dev.SerialNumber
                    }
                }
                $exportList | ConvertTo-Json -Depth 3 | Write-Output
            } else {
                Write-Output "[]"
            }
        }

        "GetBitLocker" {
            $keys = Get-MgInformationProtectionBitlockerRecoveryKey -Filter "deviceId eq '$DeviceId'" -Property "key" -ErrorAction Stop
            if ($keys) { 
                $keyStr = $($keys[0].Key)
                $safeKey = Escape-Html $keyStr
                $html = "<div style='display: flex; justify-content: space-between; align-items: center; color:#2ecc71; font-weight:bold; font-size:1.1rem;'>"
                $html += "<span><i class='fa-solid fa-key'></i> RECOVERY KEY: $safeKey</span>"
                $html += "<button class='copy-secret-btn' data-value='$safeKey' style='background: transparent; border: 1px solid #2ecc71; color: #2ecc71; padding: 4px 8px; border-radius: 4px; cursor: pointer; font-size: 0.8rem;'><i class='fa-regular fa-copy'></i> Copy</button>"
                $html += "</div>"
                Write-Output $html
            }
            else { Write-Output "<div style='color:#e74c3c;'><i class='fa-solid fa-triangle-exclamation'></i> No BitLocker keys found for this device in Entra ID.</div>" }
        }

        "GetLAPS" {
            $uri = "https://graph.microsoft.com/beta/deviceLocalCredentials?`$filter=deviceId eq '$DeviceId'&`$select=credentials"
            $lapsData = Invoke-MgGraphRequest -Method GET -Uri $uri -ErrorAction Stop

            if ($lapsData.value -and $lapsData.value.Count -gt 0) { 
                $pwStr = $($lapsData.value[0].credentials.password)
                $safePw = Escape-Html $pwStr
                $html = "<div style='display: flex; justify-content: space-between; align-items: center; color:#f1c40f; font-weight:bold; font-size:1.1rem;'>"
                $html += "<span><i class='fa-solid fa-user-shield'></i> CLOUD LAPS: $safePw</span>"
                $html += "<button class='copy-secret-btn' data-value='$safePw' style='background: transparent; border: 1px solid #f1c40f; color: #f1c40f; padding: 4px 8px; border-radius: 4px; cursor: pointer; font-size: 0.8rem;'><i class='fa-regular fa-copy'></i> Copy</button>"
                $html += "</div>"
                Write-Output $html
            }
            else { Write-Output "<div style='color:#e74c3c;'><i class='fa-solid fa-triangle-exclamation'></i> No Cloud LAPS data available for this device.</div>" }
        }

        "Wipe" {
            Invoke-MgWipeDeviceManagementManagedDevice -ManagedDeviceId $DeviceId -ErrorAction Stop
            Write-Output "<div style='color:#3498db;'><i class='fa-solid fa-skull'></i> [SDA SUCCESS] Remote Wipe command dispatched to Intune.</div>"
        }

        "Sync" {
            Invoke-MgSyncDeviceManagementManagedDevice -ManagedDeviceId $DeviceId -ErrorAction Stop
            Write-Output "<div style='color:#3498db;'><i class='fa-solid fa-rotate'></i> [SDA SUCCESS] MDM Sync command dispatched to Intune.</div>"
        }

        "Reboot" {
            Invoke-MgRebootDeviceManagementManagedDevice -ManagedDeviceId $DeviceId -ErrorAction Stop
            Write-Output "<div style='color:#3498db;'><i class='fa-solid fa-power-off'></i> [SDA SUCCESS] Remote Reboot command dispatched to Intune.</div>"
        }

        "RemovePasscode" {
            Invoke-MgRemoveDeviceManagementManagedDevicePasscode -ManagedDeviceId $DeviceId -ErrorAction Stop
            Write-Output "<div style='color:#2ecc71;'><i class='fa-solid fa-unlock-keyhole'></i> [SDA SUCCESS] Remove Passcode command dispatched to device.</div>"
        }

        "GetMFA" {
            $user = Get-MgUser -UserId $EmailToPass -ErrorAction Stop
            $methods = Get-MgUserAuthenticationPhoneMethod -UserId $user.Id -ErrorAction SilentlyContinue
            if ($methods) {
                $html = "<strong><i class='fa-solid fa-mobile-screen'></i> Registered MFA Phones:</strong><br>"
                foreach ($m in $methods) { 
                    $safePhone = Escape-Html $m.PhoneNumber
                    $safeType  = Escape-Html $m.PhoneType
                    $html += "- $safeType: $safePhone<br>" 
                }
                Write-Output "<div style='color:#cbd5e1;'>$html</div>"
            } else { Write-Output "<div style='color:#e74c3c;'><i class='fa-solid fa-triangle-exclamation'></i> No MFA phone methods found for this user.</div>" }
        }

        "ClearMFA" {
            $user = Get-MgUser -UserId $EmailToPass -ErrorAction Stop
            $cleared = 0

            $phoneMethods = Get-MgUserAuthenticationPhoneMethod -UserId $user.Id -ErrorAction SilentlyContinue
            if ($phoneMethods) {
                foreach ($m in $phoneMethods) {
                    Remove-MgUserAuthenticationPhoneMethod -UserId $user.Id -PhoneAuthenticationMethodId $m.Id -ErrorAction Stop
                    $cleared++
                }
            }

            $authAppMethods = Get-MgUserAuthenticationMicrosoftAuthenticatorMethod -UserId $user.Id -ErrorAction SilentlyContinue
            if ($authAppMethods) {
                foreach ($m in $authAppMethods) {
                    Remove-MgUserAuthenticationMicrosoftAuthenticatorMethod -UserId $user.Id -MicrosoftAuthenticatorAuthenticationMethodId $m.Id -ErrorAction Stop
                    $cleared++
                }
            }

            Write-Output "<div style='color:#2ecc71;'><i class='fa-solid fa-check'></i> [SDA SUCCESS] Cleared $cleared MFA methods. User must re-register on next login.</div>"
        }

        "AddSMS" {
            $user = Get-MgUser -UserId $EmailToPass -ErrorAction Stop
            New-MgUserAuthenticationPhoneMethod -UserId $user.Id -PhoneType "mobile" -PhoneNumber $PhoneNumber -ErrorAction Stop

            $safePhone = Escape-Html $PhoneNumber
            Write-Output "<div style='color:#2ecc71;'><i class='fa-solid fa-check'></i> [SDA SUCCESS] $safePhone added as primary SMS MFA.</div>"
        }

        "RevokeSessions" {
            $user = Get-MgUser -UserId $EmailToPass -ErrorAction Stop
            Revoke-MgUserSignInSession -UserId $user.Id -ErrorAction Stop | Out-Null
            Write-Output "<div style='color:#2ecc71;'><i class='fa-solid fa-check'></i> [SDA SUCCESS] All active Entra ID sessions revoked.</div>"
        }

        default {
            Write-Output "<div style='color:#e74c3c;'><i class='fa-solid fa-triangle-exclamation'></i> Unknown or unsupported action: $(Escape-Html $Action)</div>"
        }
    }
} catch {
    Write-Output "<div style='color:#e74c3c;'><i class='fa-solid fa-circle-xmark'></i> [!] Graph API Error: $(Escape-Html $_.Exception.Message)</div>"
}
