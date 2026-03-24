<#
.SYNOPSIS
    SDA Web-Ready Core: ActiveDirectoryProfiler.ps1
.DESCRIPTION
    The core intelligence engine for the AD User Intelligence panel.
    Queries Active Directory for account details, parses AD groups,
    and cross-references the central UserHistory.json database.
.LINKS
    Website: www.servicedeskadvanced.com
    FAQ: SDA.WTF
#>

param(
    [Parameter(Mandatory=$false, Position=0)]
    [string]$TargetUser,

    [Parameter(Mandatory=$false)]
    [string]$SharedRoot,

    [Parameter(Mandatory=$false)]
    [switch]$AsJson,

    [Parameter(Mandatory=$false)]
    [switch]$GetTrainingData
)

$ErrorActionPreference = "Continue"

# --- Export Training Data ---
if ($GetTrainingData) {
    $data = @{
        StepName = "ACTIVE DIRECTORY PROFILER"
        Description = "While SDA uses the ActiveDirectory PowerShell module to parse and format data for the UI, a junior technician should know how to quickly look up a user's domain profile using classic command-line tools. The 'net user' command instantly returns the user's lockout status, exact password expiration date, and group memberships without needing to open the heavy ADUC graphical interface."
        Code = "net user `$TargetUser /domain"
        InPerson = "Opening Active Directory Users and Computers (ADUC), searching for the user, checking the 'Account' tab to see if the 'Unlock account' box is checked, checking the 'Member Of' tab, and manually calculating their password expiration date."
    }
    $data | ConvertTo-Json | Write-Output
    return
}

# --- Load Configuration ---
$ImportantGroups = @("VPN", "Admin", "M365", "License", "Remote")

if ([string]::IsNullOrWhiteSpace($SharedRoot)) {
    try {
        $ScriptDir = Split-Path -Path $MyInvocation.MyCommand.Path
        $RootFolder = Split-Path -Path $ScriptDir
        $ConfigFile = Join-Path -Path $RootFolder -ChildPath "Config\config.json"
        if (Test-Path $ConfigFile) {
            $Config = Get-Content $ConfigFile -Raw | ConvertFrom-Json
            $SharedRoot = $Config.SharedNetworkRoot
            if ($Config.ActiveDirectory.ImportantGroups) {
                $ImportantGroups = $Config.ActiveDirectory.ImportantGroups
            }
        } else { return }
    } catch { return }
} else {
    $ConfigFile = Join-Path -Path $SharedRoot -ChildPath "Config\config.json"
    if (Test-Path $ConfigFile) {
        $Config = Get-Content $ConfigFile -Raw | ConvertFrom-Json
        if ($Config.ActiveDirectory.ImportantGroups) {
            $ImportantGroups = $Config.ActiveDirectory.ImportantGroups
        }
    }
}

if ([string]::IsNullOrWhiteSpace($TargetUser)) { return }

# ============================================================================
# 1. Query Active Directory FIRST (Cascading Identity Resolution)
# ============================================================================
$adObj = $null
$multipleMatches = $null
$ADProps = @("Office", "Title", "Department", "EmailAddress", "PasswordLastSet", "LastLogonDate", "LockedOut", "Enabled", "MemberOf", "PasswordNeverExpires")

try {
    # Attempt 1: Strict Identity Match (SAMAccountName, GUID, SID)
    $adObj = Get-ADUser -Identity $TargetUser -Properties $ADProps -ErrorAction Stop
} catch {
    # Attempt 2: Ambiguous Name Resolution (ANR) Fallback
    try {
        $anrMatches = @(Get-ADUser -Filter "anr -eq '$TargetUser'" -Properties $ADProps -ErrorAction Stop)

        if ($anrMatches.Count -eq 1) {
            $adObj = $anrMatches[0]
        } elseif ($anrMatches.Count -gt 1) {
            # If multiple matches exist, prioritize exact DisplayName or Email match to minimize attack surface
            $exactMatch = $anrMatches | Where-Object { $_.DisplayName -eq $TargetUser -or $_.EmailAddress -eq $TargetUser }
            if ($exactMatch -and $exactMatch.Count -eq 1) {
                $adObj = $exactMatch[0]
            } else {
                # Pass the array back to the UI for selection
                $multipleMatches = $anrMatches
            }
        }
    } catch {
        # Fails gracefully to computer history check
    }
}

# --- Handle Multiple Matches (Web UI) ---
if ($AsJson -and $multipleMatches) {
    $matchList = @()
    foreach ($m in $multipleMatches) {
        $matchList += @{
            Name = $m.Name
            SamAccountName = $m.SamAccountName
            Title = if ($m.Title) { $m.Title } else { "No Title" }
            Department = if ($m.Department) { $m.Department } else { "No Department" }
        }
    }
    @{ Status = "multiple"; Matches = $matchList } | ConvertTo-Json -Depth 3 -Compress | Write-Output
    return
}

# ============================================================================
# 2. Query Telemetry History (Using Resolved SAMAccountName)
# ============================================================================
$HistoryFile = Join-Path -Path $SharedRoot -ChildPath "Core\UserHistory.json"
$userHistory = @()
$computerHistory = @()

# Use the strict AD username if we found one, otherwise fall back to the raw search query (for PC searches)
$StrictSearchTerm = if ($adObj) { $adObj.SamAccountName } else { $TargetUser }

if (Test-Path $HistoryFile) {
    try {
        $raw = Get-Content $HistoryFile -Raw | ConvertFrom-Json
        if ($raw -isnot [System.Array]) { $raw = @($raw) }

        $seenPC = @{}
        $seenUser = @{}

        foreach ($entry in $raw) {
            if ("$($entry.User)".Trim() -eq "$StrictSearchTerm".Trim()) {
                $pc = "$($entry.Computer)".Trim()
                if (-not $seenPC.ContainsKey($pc)) {
                    $userHistory += $entry
                    $seenPC[$pc] = $true
                }
            }
            if ("$($entry.Computer)".Trim() -match "$StrictSearchTerm".Trim()) {
                $usr = "$($entry.User)".Trim()
                if (-not $seenUser.ContainsKey($usr)) {
                    $computerHistory += $entry
                    $seenUser[$usr] = $true
                }
            }
        }
    } catch { }
}

# ============================================================================
# 3. Process Data & Calculate Expiry
# ============================================================================
$expiryDate = "N/A"; $daysLeftStr = "N/A"
$matchedGroups = @()
$standardGroupCount = 0

if ($adObj) {
    if ($adObj.PasswordNeverExpires) {
        $expiryDate = "Never (Exempt)"; $daysLeftStr = "Infinite"
    } else {
        try {
            $policy = Get-ADDefaultDomainPasswordPolicy
            $maxAge = $policy.MaxPasswordAge.Days
            if ($adObj.PasswordLastSet) {
                $exp = $adObj.PasswordLastSet.AddDays($maxAge)
                $expiryDate = $exp.ToString("MM/dd/yyyy HH:mm")
                $span = New-TimeSpan -Start (Get-Date) -End $exp
                $daysLeft = $span.Days

                if ($daysLeft -lt 0) { $daysLeftStr = "!!! EXPIRED ($([math]::Abs($daysLeft)) days ago) !!!" } 
                elseif ($daysLeft -le 3) { $daysLeftStr = "!!! $daysLeft (EXPIRING SOON) !!!" } 
                else { $daysLeftStr = "$daysLeft" }
            }
        } catch { $expiryDate = "Unknown" }
    }

    if ($adObj.MemberOf) {
        foreach ($dn in $adObj.MemberOf) {
            $cn = if ($dn -match "^CN=([^,]+)") { $matches[1] } else { $dn }
            $isImportant = $false
            foreach ($keyword in $ImportantGroups) {
                if ($cn -match $keyword) {
                    $isImportant = $true
                    break
                }
            }
            if ($isImportant) { $matchedGroups += $cn } else { $standardGroupCount++ }
        }
    }
}

# ============================================================================
# 4. JSON Output (Web UI)
# ============================================================================
if ($AsJson) {
    $res = @{ Status = "error"; Message = "No matching user or computer found."; Type = "none" }

    if ($adObj) {
        $res.Status = "success"
        $res.Type = "user"
        $res.Name = $adObj.Name
        $res.SamAccountName = $adObj.SamAccountName
        $res.Title = $adObj.Title
        $res.Department = $adObj.Department
        $res.IsEnabled = [bool]$adObj.Enabled
        $res.IsLocked = [bool]$adObj.LockedOut
        $res.DaysUntilExpiry = $daysLeftStr
        $res.TargetPC = if ($userHistory.Count -gt 0) { $userHistory[0].Computer } else { "" }
        $res.KnownPCs = @($userHistory.Computer)
        $res.Email = $adObj.EmailAddress
        $res.ImportantGroups = $matchedGroups

    } elseif ($computerHistory.Count -gt 0) {
        $res.Status = "success"
        $res.Type = "computer"
        $res.TargetPC = $computerHistory[0].Computer
    }

    $res | ConvertTo-Json -Depth 3 -Compress | Write-Output
    return
}