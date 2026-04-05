<#
.SYNOPSIS
    SDA Web-Ready Core: Helper_RemoveHistory.ps1
.DESCRIPTION
    Safely manages the central UserHistory.json database by 
    finding and deleting a specific User-to-PC mapping.
    Enforces strict schema validation to prevent PS 5.1 serialization bugs.
.LINKS
    Website: www.servicedeskadvanced.com
    FAQ: SDA.WTF
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$User,

    [Parameter(Mandatory=$false)]
    [string]$Computer,

    [Parameter(Mandatory=$false)]
    [string]$SharedRoot
)

# --- Load Configuration ---
if ([string]::IsNullOrWhiteSpace($SharedRoot)) {
    try {
        $ScriptDir = Split-Path -Path $MyInvocation.MyCommand.Path
        $RootFolder = Split-Path -Path $ScriptDir
        $ConfigFile = Join-Path -Path $RootFolder -ChildPath "config.json"

        if (Test-Path $ConfigFile) {
            $Config = Get-Content $ConfigFile -Raw | ConvertFrom-Json
            $SharedRoot = $Config.SharedNetworkRoot
        } else {
            Write-Output "[!] Error: SharedRoot path is missing and config.json not found."
            return
        }
    } catch {
        Write-Output "[!] Error: Failed to resolve SharedRoot."
        return
    }
}

$HistoryFile = Join-Path -Path $SharedRoot -ChildPath "Core\UserHistory.json"
$BackupFile  = Join-Path -Path $SharedRoot -ChildPath "Core\UserHistory.json.bak"
$TempFile    = Join-Path -Path $SharedRoot -ChildPath "Core\UserHistory.json.tmp"

# --- Read Database ---
$db = @{}
$initialCount = 0

if (Test-Path $HistoryFile) {
    # Backup if the file is healthy (>100 bytes).
    if ((Get-Item $HistoryFile).Length -gt 100) {
        Copy-Item -Path $HistoryFile -Destination $BackupFile -Force
    }

    try {
        $content = Get-Content $HistoryFile -Raw -ErrorAction Stop
        if (-not [string]::IsNullOrWhiteSpace($content)) {
            $raw = $content | ConvertFrom-Json
            if ($raw -isnot [System.Array]) { $raw = @($raw) }

            foreach ($entry in $raw) {
                if ($entry.User -and $entry.Computer) {
                    $key = "$($entry.User)-$($entry.Computer)"
                    $db[$key] = $entry
                }
            }
            $initialCount = $db.Count
        }
    } catch {
        Write-Output "`n[!] CRITICAL: JSON Parsing failed. Aborting to prevent data wipe."
        return
    }
}

# --- Remove Record ---
$scanKey = "$User-$Computer"

if ($db.ContainsKey($scanKey)) {
    $db.Remove($scanKey)
    $expectedCount = $initialCount - 1
    Write-Output " > Target record identified and removed from memory."
} else {
    Write-Output "[i] Record not found in database. Nothing removed."
    return
}

# --- Write to Disk (Strict Schema Enforcement) ---
if ($db.Count -eq $expectedCount -and $initialCount -gt 0) {
    try {
        # PS 5.1 Bug Fix: Force all objects to have the exact same properties before JSON conversion
        $finalList = @($db.Values | Sort-Object User | Select-Object User, Computer, LastSeen, Source, MACAddress)

        # Removed -Compress to restore pretty-printing
        $jsonOutput = ConvertTo-Json -InputObject $finalList -Depth 3 -ErrorAction Stop

        if ([string]::IsNullOrWhiteSpace($jsonOutput)) {
            throw "Generated JSON string was completely empty."
        }

        Set-Content -Path $TempFile -Value $jsonOutput -Force -ErrorAction Stop
        Move-Item -Path $TempFile -Destination $HistoryFile -Force -ErrorAction Stop

        Write-Output "[SDA SUCCESS] Database updated successfully."
    } catch {
        Write-Output "`n[!] ERROR SAVING: $($_.Exception.Message)"
        if (Test-Path $TempFile) { Remove-Item $TempFile -Force -ErrorAction SilentlyContinue }
    }
} else {
    Write-Output "`n[!] PROTECTION TRIGGERED: Record count mismatch. Aborting save to protect database."
}
