<#
.SYNOPSIS
    Service Desk Advanced (SDA) - API Gateway
.DESCRIPTION
    Enterprise-grade, agentless orchestration gateway.
    Formerly Unified Help Desk Console (UHDC).
.LINKS
    Website: www.servicedeskadvanced.com
    FAQ: SDA.WTF
#>

# --- Enforce Elevated Execution Context ---
if (-Not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "[!] Elevation required. Resolving path and restarting as Administrator..." -ForegroundColor Yellow

    $LaunchPath = $PSCommandPath
    if ($LaunchPath -match '^[A-Za-z]:') {
        $drive = Get-PSDrive -Name $LaunchPath.Substring(0,1) -ErrorAction SilentlyContinue
        if ($drive -and $drive.DisplayRoot) {
            $LaunchPath = $LaunchPath -replace '^.:', $drive.DisplayRoot
        }
    }

    Start-Process PowerShell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$LaunchPath`"" -Verb RunAs
    Exit
}

$ErrorActionPreference = "Stop"
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition

Write-Host "========================================" -ForegroundColor Cyan
Write-Host " [SDA] SERVICE DESK ADVANCED INITIALIZING" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Docs: www.serveskadvanced.com" -ForegroundColor DarkGray
Write-Host " FAQs: SDA.WTF" -ForegroundColor DarkGray
Write-Host "========================================" -ForegroundColor Cyan

# --- Pre-Load Required Modules ---
Write-Host "[+] Loading Active Directory Module..." -ForegroundColor DarkGray
Import-Module ActiveDirectory -ErrorAction SilentlyContinue

# --- Ensure required directories exist ---
$RequiredFolders = @("Core", "Tools", "Logs", "Config", "TelemetryDrop")
foreach ($Folder in $RequiredFolders) {
    $FolderPath = Join-Path $ScriptRoot $Folder
    if (-not (Test-Path $FolderPath)) {
        Write-Host "[+] Creating missing directory: $Folder" -ForegroundColor DarkGray
        New-Item -ItemType Directory -Path $FolderPath -Force | Out-Null
    }
}

# --- Initialize default configuration ---
$ConfigPath = Join-Path $ScriptRoot "Config\config.json"
if (-not (Test-Path $ConfigPath)) {
    Write-Host "[!] First run detected. Generating default config.json..." -ForegroundColor Yellow

    $Template = [ordered]@{
        Organization = @{
            CompanyName  = "Acme Corp"
            TenantDomain = "acmecorp.com"
        }
        ActiveDirectory = @{
            ImportantGroups = @("VPN", "M365", "Admin", "License", "Finance")
        }
        AccessControl = @{
            MasterAdmins = @("Admin1", "Admin2")
            Trainees     = @("NewHire1")
        }
    }
    $Template | ConvertTo-Json -Depth 3 | Out-File $ConfigPath -Force

    Write-Host "`n[ACTION REQUIRED] A default config.json has been created in the \Config folder." -ForegroundColor Red
    Write-Host "Please open it, enter your Tenant Domain, and restart this script." -ForegroundColor Red
    Pause; exit
}

$Global:Config       = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$Global:TenantDomain = $Global:Config.Organization.TenantDomain
Write-Host "[OK] Configuration loaded for $($Global:Config.Organization.CompanyName)" -ForegroundColor Green

# --- Dot-source IdentityMenu.ps1 so Graph API helper functions are available ---
$IdentityMenuPath = Join-Path $ScriptRoot "Core\IdentityMenu.ps1"
if (Test-Path $IdentityMenuPath) {
    Write-Host "[+] Loading Identity Menu (Graph API)..." -ForegroundColor DarkGray
    try {
        . $IdentityMenuPath
        Write-Host "[OK] IdentityMenu loaded. GraphConnected: $Global:GraphConnected" -ForegroundColor Green
    } catch {
        Write-Host "[!] IdentityMenu load failed: $($_.Exception.Message)" -ForegroundColor Yellow
    }
} else {
    Write-Host "[!] IdentityMenu.ps1 not found in \Core. Cloud Identity features disabled." -ForegroundColor Yellow
}

# --- Download & Verify PsExec if missing ---
$psExecPath = Join-Path $ScriptRoot "Core\psexec.exe"
if (-not (Test-Path $psExecPath)) {
    Write-Host "[i] PsExec.exe missing. Downloading from Sysinternals..." -ForegroundColor Cyan
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri "https://live.sysinternals.com/psexec.exe" -OutFile $psExecPath -UseBasicParsing -ErrorAction Stop
        Unblock-File $psExecPath -ErrorAction SilentlyContinue

        # Supply Chain Security: Authenticode Signature Validation
        Write-Host " > Verifying Microsoft Authenticode Signature..." -ForegroundColor DarkGray
        $sig = Get-AuthenticodeSignature $psExecPath
        if ($sig.Status -eq 'Valid' -and $sig.SignerCertificate.Subject -match 'Microsoft Corporation') {
            Write-Host "[OK] PsExec downloaded and cryptographically verified." -ForegroundColor Green
        } else {
            Remove-Item $psExecPath -Force -ErrorAction SilentlyContinue
            Write-Host "[!] CRITICAL: PsExec signature validation failed. File deleted to prevent supply chain attack." -ForegroundColor Red
        }
    } catch {
        Write-Host "[!] Failed to download PsExec. Please place it in \Core manually." -ForegroundColor Red
    }
}

# --- Initialize HTTP Listener ---
$Port = 5050
$Url  = "http://localhost:$Port/"
$HttpListener = New-Object System.Net.HttpListener
$HttpListener.Prefixes.Add($Url)

try {
    $HttpListener.Start()
} catch {
    Write-Host "[!] Port $Port is in use. Cleaning up orphaned processes..." -ForegroundColor Yellow
    $currentPID = $PID

    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.CommandLine -match "AppLogic.ps1" -and $_.ProcessId -ne $currentPID } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

    Start-Sleep -Seconds 2
    $HttpListener.Start()
}

Write-Host "[SDA] API Gateway Started on Port $Port" -ForegroundColor Cyan
Write-Host "[SDA] Rendering HTML Interface..." -ForegroundColor Cyan
Start-Process "msedge.exe" -ArgumentList "--app=$Url"

# --- Main Request Loop (Resilient) ---
try {
    while ($HttpListener.IsListening) {
        try {
            $Context  = $HttpListener.GetContext()
            $Request  = $Context.Request
            $Response = $Context.Response

            # ----------------------------------------------------------------
            # Serve Main UI
            # ----------------------------------------------------------------
            if ($Request.Url.AbsolutePath -eq "/") {
                $HtmlPath    = Join-Path $ScriptRoot "MainUI.html"
                $HtmlContent = Get-Content $HtmlPath -Raw
                $Buffer      = [System.Text.Encoding]::UTF8.GetBytes($HtmlContent)
                $Response.ContentType      = "text/html"
                $Response.ContentLength64  = $Buffer.Length
                $Response.OutputStream.Write($Buffer, 0, $Buffer.Length)
            }

            # ----------------------------------------------------------------
            # Telemetry Feed
            # ----------------------------------------------------------------
            elseif ($Request.Url.AbsolutePath -eq "/api/telemetry" -and $Request.HttpMethod -eq "GET") {
                $MasterDB    = Join-Path $ScriptRoot "Core\UserHistory.json"
                $JsonResponse = if (Test-Path $MasterDB) { Get-Content $MasterDB -Raw } else { '[]' }
                $Buffer = [System.Text.Encoding]::UTF8.GetBytes($JsonResponse)
                $Response.ContentType     = "application/json"
                $Response.ContentLength64 = $Buffer.Length
                $Response.OutputStream.Write($Buffer, 0, $Buffer.Length)
            }

            # ----------------------------------------------------------------
            # Remote Access Launcher
            # ----------------------------------------------------------------
            elseif ($Request.Url.AbsolutePath -eq "/api/remote/connect" -and $Request.HttpMethod -eq "POST") {
                $StreamReader = New-Object System.IO.StreamReader($Request.InputStream, [System.Text.Encoding]::UTF8)
                $RequestBody  = $StreamReader.ReadToEnd() | ConvertFrom-Json
                $Method       = $RequestBody.Method
                $TargetPC     = $RequestBody.TargetPC

                Write-Host ">>> Launching $Method against $TargetPC..." -ForegroundColor Yellow
                $ResponseObj = @{ status = "success"; message = "" }

                try {
                    # Strict validation on TargetPC
                    if ([string]::IsNullOrWhiteSpace($TargetPC) -or $TargetPC -notmatch "^[a-zA-Z0-9_.,-]+$") {
                        throw "Invalid Target PC format."
                    }

                    switch ($Method) {
                        "SCCM" {
                            $sccmPath = "C:\Program Files (x86)\Microsoft Endpoint Manager\AdminConsole\bin\i386\CmRcViewer.exe"
                            if (Test-Path $sccmPath) {
                                Start-Process $sccmPath -ArgumentList $TargetPC
                                $ResponseObj.message = "SCCM CmRcViewer launched for $TargetPC."
                            } else {
                                $ResponseObj.status  = "error"
                                $ResponseObj.message = "CmRcViewer.exe not found."
                            }
                        }
                        "MSRA" {
                            Start-Process "msra.exe" -ArgumentList "/offerRA $TargetPC"
                            $ResponseObj.message = "MSRA Invitation sent to $TargetPC."
                        }
                        "TeamViewer" {
                            $tvPath = "C:\Program Files\TeamViewer\TeamViewer.exe"
                            if (Test-Path $tvPath) {
                                Start-Process $tvPath -ArgumentList "-i $TargetPC"
                                $ResponseObj.message = "TeamViewer launched targeting $TargetPC."
                            } else {
                                $ResponseObj.status  = "error"
                                $ResponseObj.message = "TeamViewer.exe not found."
                            }
                        }
                        "CShare" {
                            Start-Process "explorer.exe" -ArgumentList "\\$TargetPC\c$"
                            $ResponseObj.message = "Opened C$ share for $TargetPC."
                        }
                        default {
                            throw "Unknown remote access method."
                        }
                    }
                } catch {
                    $ResponseObj.status  = "error"
                    $ResponseObj.message = "Failed to launch remote tool: $($_.Exception.Message)"
                }

                $JsonResponse = $ResponseObj | ConvertTo-Json -Depth 3 -Compress
                $Buffer = [System.Text.Encoding]::UTF8.GetBytes($JsonResponse)
                $Response.ContentType     = "application/json"
                $Response.ContentLength64 = $Buffer.Length
                $Response.OutputStream.Write($Buffer, 0, $Buffer.Length)
            }

            # ----------------------------------------------------------------
            # Fetch Training Data
            # ----------------------------------------------------------------
            elseif ($Request.Url.AbsolutePath -eq "/api/tools/training" -and $Request.HttpMethod -eq "POST") {
                $StreamReader = New-Object System.IO.StreamReader($Request.InputStream, [System.Text.Encoding]::UTF8)
                $RequestBody  = $StreamReader.ReadToEnd() | ConvertFrom-Json
                $ScriptName   = $RequestBody.Script
                $ExtraArgs    = $RequestBody.ExtraArgs

                # Strict Input Validation (Path Traversal Prevention)
                if ($ScriptName -notmatch "^[a-zA-Z0-9_-]+\.ps1$") {
                    Write-Host "[!] Path Traversal Attempt Blocked in Training Endpoint: $ScriptName" -ForegroundColor Red
                    $JsonResponse = (@{ error = "Invalid script name format." } | ConvertTo-Json -Compress)
                } else {
                    $ScriptPath = Join-Path $ScriptRoot "Tools\$ScriptName"
                    if (-not (Test-Path $ScriptPath)) { $ScriptPath = Join-Path $ScriptRoot "Core\$ScriptName" }

                    if (Test-Path $ScriptPath) {
                        try {
                            $Params = @{ GetTrainingData = $true }
                            if ($null -ne $ExtraArgs) {
                                foreach ($prop in $ExtraArgs.psobject.properties) {
                                    $Params[$prop.Name] = $prop.Value
                                }
                            }
                            $RawOutput    = & $ScriptPath @Params | Out-String
                            $JsonResponse = $RawOutput.Trim()
                        } catch {
                            $JsonResponse = (@{ error = "Failed to load training data." } | ConvertTo-Json -Compress)
                        }
                    } else {
                        $JsonResponse = (@{ error = "Script not found." } | ConvertTo-Json -Compress)
                    }
                }

                $Buffer = [System.Text.Encoding]::UTF8.GetBytes($JsonResponse)
                $Response.ContentType     = "application/json"
                $Response.ContentLength64 = $Buffer.Length
                $Response.OutputStream.Write($Buffer, 0, $Buffer.Length)
            }

            # ----------------------------------------------------------------
            # Execute Tool
            # ----------------------------------------------------------------
            elseif ($Request.Url.AbsolutePath -eq "/api/tools/execute" -and $Request.HttpMethod -eq "POST") {
                $StreamReader = New-Object System.IO.StreamReader($Request.InputStream, [System.Text.Encoding]::UTF8)
                $RequestBody  = $StreamReader.ReadToEnd() | ConvertFrom-Json

                $ScriptName  = $RequestBody.Script
                $TargetPC    = $RequestBody.Target
                $TargetUser  = $RequestBody.TargetUser
                $ExtraArgs   = $RequestBody.ExtraArgs

                $ResponseObj = @{ status = "error"; message = ""; output = "" }
                $InputValid  = $true

                # --- Strict Input Validation ---
                if ($ScriptName -notmatch "^[a-zA-Z0-9_-]+\.ps1$") {
                    $ResponseObj.message = "Invalid script name format."
                    Write-Host "[!] Path Traversal Attempt Blocked: $ScriptName" -ForegroundColor Red
                    $InputValid = $false
                }
                elseif (-not [string]::IsNullOrWhiteSpace($TargetPC) -and $TargetPC -notmatch "^[a-zA-Z0-9_.,-]+$") {
                    $ResponseObj.message = "Invalid characters in Target PC name."
                    Write-Host "[!] Command Injection Attempt Blocked: $TargetPC" -ForegroundColor Red
                    $InputValid = $false
                }

                if ($InputValid -and $null -ne $ExtraArgs) {
                    foreach ($prop in $ExtraArgs.psobject.properties) {
                        if ($prop.Name -notmatch "^[a-zA-Z0-9_]+$") {
                            $ResponseObj.message = "Invalid parameter name format."
                            Write-Host "[!] Parameter Name Injection Blocked: $($prop.Name)" -ForegroundColor Red
                            $InputValid = $false
                            break
                        }
                        # Expanded Blocklist for Defense-in-Depth
                        if ($prop.Value -is [string] -and $prop.Value -match '(\$\(|`|;|\||&&|>|%|--)') {
                            $ResponseObj.message = "Illegal characters detected in parameter payload."
                            Write-Host "[!] Parameter Value Injection Blocked: $($prop.Name)" -ForegroundColor Red
                            $InputValid = $false
                            break
                        }
                    }
                }

                if ($InputValid) {
                    $ScriptPath = Join-Path $ScriptRoot "Tools\$ScriptName"
                    if (-not (Test-Path $ScriptPath)) { $ScriptPath = Join-Path $ScriptRoot "Core\$ScriptName" }

                    Write-Host ">>> Executing $ScriptName against $TargetPC..." -ForegroundColor Yellow

                    if (Test-Path $ScriptPath) {
                        try {
                            $Params = @{
                                Target      = $TargetPC
                                TargetUser  = $TargetUser
                                SharedRoot  = $ScriptRoot
                            }

                            if ($null -ne $ExtraArgs) {
                                foreach ($prop in $ExtraArgs.psobject.properties) {
                                    if ($prop.Value -is [bool]) {
                                        if ($prop.Value -eq $true) {
                                            $Params[$prop.Name] = $true
                                        }
                                    } else {
                                        $Params[$prop.Name] = $prop.Value
                                    }
                                }
                            }

                            $RawOutput = & $ScriptPath @Params *>&1 | Out-String

                            $ResponseObj.status  = "success"
                            $ResponseObj.message = "Executed"
                            $ResponseObj.output  = $RawOutput.Trim()
                        } catch {
                            $ResponseObj.message = "Script execution failed: $($_.Exception.Message)"
                        }
                    } else {
                        $ResponseObj.message = "Script not found: $ScriptName"
                    }
                }

                $JsonResponse = $ResponseObj | ConvertTo-Json -Depth 3 -Compress
                $Buffer = [System.Text.Encoding]::UTF8.GetBytes($JsonResponse)
                $Response.ContentType     = "application/json"
                $Response.ContentLength64 = $Buffer.Length
                $Response.OutputStream.Write($Buffer, 0, $Buffer.Length)
            }

            # ----------------------------------------------------------------
            # AD Intelligence Search
            # ----------------------------------------------------------------
            elseif ($Request.Url.AbsolutePath -eq "/api/identity/search" -and $Request.HttpMethod -eq "POST") {
                $StreamReader = New-Object System.IO.StreamReader($Request.InputStream, [System.Text.Encoding]::UTF8)
                $RequestBody  = $StreamReader.ReadToEnd() | ConvertFrom-Json
                $Query        = $RequestBody.Query

                Write-Host ">>> Executing Identity Correlation for $Query..." -ForegroundColor Yellow

                $ScriptPath = Join-Path $ScriptRoot "Core\ActiveDirectoryProfiler.ps1"

                if (Test-Path $ScriptPath) {
                    try {
                        $RawOutput    = & $ScriptPath -TargetUser $Query -SharedRoot $ScriptRoot -AsJson 6>$null | Out-String
                        $JsonResponse = $RawOutput.Trim()
                        if ([string]::IsNullOrWhiteSpace($JsonResponse)) {
                            $JsonResponse = (@{ Status = "error"; Message = "No data returned." } | ConvertTo-Json -Compress)
                        }
                    } catch {
                        $JsonResponse = (@{ Status = "error"; Message = "AD Query failed: $($_.Exception.Message)" } | ConvertTo-Json -Compress)
                    }
                } else {
                    $JsonResponse = (@{ Status = "error"; Message = "ActiveDirectoryProfiler.ps1 not found." } | ConvertTo-Json -Compress)
                }

                $Buffer = [System.Text.Encoding]::UTF8.GetBytes($JsonResponse)
                $Response.ContentType     = "application/json"
                $Response.ContentLength64 = $Buffer.Length
                $Response.OutputStream.Write($Buffer, 0, $Buffer.Length)
            }

            # ----------------------------------------------------------------
            # AD & Cloud Identity Actions
            # ----------------------------------------------------------------
            elseif ($Request.Url.AbsolutePath -eq "/api/identity/action" -and $Request.HttpMethod -eq "POST") {
                $StreamReader = New-Object System.IO.StreamReader($Request.InputStream, [System.Text.Encoding]::UTF8)
                $RequestBody  = $StreamReader.ReadToEnd() | ConvertFrom-Json
                $Action       = $RequestBody.Action
                $TargetUser   = $RequestBody.TargetUser
                $ForceChange  = $RequestBody.ForceChange

                $NewPassword = $RequestBody.NewPassword
                if ($null -ne $NewPassword) { $NewPassword = $NewPassword.Trim() }

                # Default to secure behavior if parameter is missing
                if ($null -eq $ForceChange) { $ForceChange = $true }

                Write-Host ">>> Executing $Action on $TargetUser..." -ForegroundColor Yellow
                $ResponseObj = @{ status = "success"; message = "" }

                try {
                    # Strict Input Validation for AD Cmdlets
                    if ([string]::IsNullOrWhiteSpace($TargetUser) -or $TargetUser -notmatch '^[a-zA-Z0-9._@-]+$') {
                        throw "Invalid TargetUser format. Potential injection blocked."
                    }

                    # Explicit Allowlist for Actions
                    $AllowedActions = @('UnlockAccount', 'ResetPassword', 'RevokeSessions', 'ClearMFA')
                    if ($Action -notin $AllowedActions) {
                        throw "Unknown or disallowed action: $Action"
                    }

                    switch ($Action) {

                        # ---- Pure Active Directory Actions ----
                        "UnlockAccount" {
                            Unlock-ADAccount -Identity $TargetUser -ErrorAction Stop
                            $ResponseObj.message = "AD Account unlocked successfully."
                        }

                        "ResetPassword" {
                            if ([string]::IsNullOrWhiteSpace($NewPassword)) {
                                throw "No password was provided by the UI."
                            }
                            $securePwd = ConvertTo-SecureString $NewPassword -AsPlainText -Force
                            Set-ADAccountPassword -Identity $TargetUser -NewPassword $securePwd -Reset -ErrorAction Stop
                            Set-ADUser -Identity $TargetUser -ChangePasswordAtLogon $ForceChange -ErrorAction Stop

                            # Information Disclosure Fix: Do not echo the plaintext password back to the UI telemetry
                            if ($ForceChange) {
                                $ResponseObj.message = "Password reset successfully. User must change at next logon."
                            } else {
                                $ResponseObj.message = "Password reset successfully. Persistent password set."
                            }
                        }

                        # ---- Cloud / Graph API Actions ----
                        "RevokeSessions" {
                            if (-not $Global:GraphConnected) {
                                throw "Graph API is not connected. Cannot revoke cloud sessions."
                            }
                            $upn = $TargetUser
                            if ($upn -notmatch "@") {
                                $adObj = Get-ADUser -Identity $TargetUser -Properties UserPrincipalName -ErrorAction SilentlyContinue
                                if ($adObj) { $upn = $adObj.UserPrincipalName }
                            }
                            $result = Revoke-SDASessions -TargetUPN $upn
                            $ResponseObj.message = $result
                        }

                        "ClearMFA" {
                            if (-not $Global:GraphConnected) {
                                throw "Graph API is not connected. Cannot clear MFA methods."
                            }
                            $upn = $TargetUser
                            if ($upn -notmatch "@") {
                                $adObj = Get-ADUser -Identity $TargetUser -Properties UserPrincipalName -ErrorAction SilentlyContinue
                                if ($adObj) { $upn = $adObj.UserPrincipalName }
                            }
                            $result = Clear-SDAUserMFA -TargetUPN $upn
                            $ResponseObj.message = $result
                        }
                    }
                } catch {
                    $errMsg = $_.Exception.Message
                    Write-Host "  > [!] Identity Action Failed: $errMsg" -ForegroundColor Red
                    $ResponseObj.status  = "error"
                    $ResponseObj.message = "Error: $errMsg"
                }

                $JsonResponse = $ResponseObj | ConvertTo-Json -Depth 3 -Compress
                $Buffer = [System.Text.Encoding]::UTF8.GetBytes($JsonResponse)
                $Response.ContentType     = "application/json"
                $Response.ContentLength64 = $Buffer.Length
                $Response.OutputStream.Write($Buffer, 0, $Buffer.Length)
            }

            # ----------------------------------------------------------------
            # Background Task Dispatcher
            # ----------------------------------------------------------------
            elseif ($Request.Url.AbsolutePath -eq "/api/tools/background" -and $Request.HttpMethod -eq "POST") {
                $StreamReader = New-Object System.IO.StreamReader($Request.InputStream, [System.Text.Encoding]::UTF8)
                $RequestBody  = $StreamReader.ReadToEnd() | ConvertFrom-Json
                $ScriptName   = $RequestBody.Script

                $ResponseObj = @{ status = "error"; message = "" }

                # Strict Input Validation (Path Traversal Prevention)
                if ($ScriptName -notmatch "^[a-zA-Z0-9_-]+\.ps1$") {
                    Write-Host "[!] Path Traversal Attempt Blocked in Background Dispatcher: $ScriptName" -ForegroundColor Red
                    $ResponseObj.message = "Invalid script name format."
                } else {
                    $ScriptPath  = Join-Path $ScriptRoot "Core\$ScriptName"
                    Write-Host ">>> Spawning background process: $ScriptName..." -ForegroundColor Magenta

                    if (Test-Path $ScriptPath) {
                        try {
                            $existingProcess = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match [regex]::Escape($ScriptName) }

                            if ($existingProcess) {
                                Write-Host "  > [!] Blocked: $ScriptName is already running." -ForegroundColor Yellow
                                $ResponseObj.status  = "warn"
                                $ResponseObj.message = "$ScriptName is already running. Please wait for it to complete."
                            } else {
                                $ArgsList = "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptPath`" -SharedRoot `"$ScriptRoot`""
                                Start-Process "powershell.exe" -ArgumentList $ArgsList

                                $ResponseObj.status  = "success"
                                $ResponseObj.message = "$ScriptName launched in the background."
                            }
                        } catch {
                            $ResponseObj.message = "Failed to launch background process."
                        }
                    } else {
                        $ResponseObj.message = "Script not found: $ScriptName"
                    }
                }

                $JsonResponse = $ResponseObj | ConvertTo-Json -Depth 3 -Compress
                $Buffer = [System.Text.Encoding]::UTF8.GetBytes($JsonResponse)
                $Response.ContentType     = "application/json"
                $Response.ContentLength64 = $Buffer.Length
                $Response.OutputStream.Write($Buffer, 0, $Buffer.Length)
            }

            # ----------------------------------------------------------------
            # System Status & RBAC Check
            # ----------------------------------------------------------------
            elseif ($Request.Url.AbsolutePath -eq "/api/system/status" -and $Request.HttpMethod -eq "GET") {
                $isTrainee = $false
                if ($Global:Config.AccessControl.Trainees -contains $env:USERNAME) {
                    $isTrainee = $true
                }

                $statusObj = @{
                    GraphConnected = $Global:GraphConnected
                    IsTrainee      = $isTrainee
                    Username       = $env:USERNAME
                }

                $JsonResponse = $statusObj | ConvertTo-Json -Compress
                $Buffer = [System.Text.Encoding]::UTF8.GetBytes($JsonResponse)
                $Response.ContentType     = "application/json"
                $Response.ContentLength64 = $Buffer.Length
                $Response.OutputStream.Write($Buffer, 0, $Buffer.Length)
            }

            # ----------------------------------------------------------------
            # Graceful Shutdown
            # ----------------------------------------------------------------
            elseif ($Request.Url.AbsolutePath -eq "/api/system/shutdown" -and $Request.HttpMethod -eq "POST") {
                Write-Host ">>> Shutdown signal received. Terminating engine..." -ForegroundColor Yellow
                $Response.StatusCode = 200
                $Response.Close()
                $HttpListener.Stop()
                break
            }

            else { $Response.StatusCode = 404 }

            $Response.Close()

        } catch {
            Write-Host "[!] API Gateway Error: $($_.Exception.Message)" -ForegroundColor Red
            try {
                if ($null -ne $Response) {
                    $Response.StatusCode = 500
                    $Response.Close()
                }
            } catch {}
        }
    }
}
finally {
    $HttpListener.Stop()
    $HttpListener.Close()
}
