<#
.SYNOPSIS
    Converts PuTTY saved sessions from the Windows registry to an OpenSSH config file.

.DESCRIPTION
    Reads all PuTTY sessions from HKCU:\Software\SimonTatham\PuTTY\Sessions and generates
    equivalent Host blocks for ~/.ssh/config (or a specified output path).

    Backs up any existing ssh config before writing.

    Notes:
    - PuTTY .ppk key files are NOT compatible with OpenSSH. If a session references a .ppk
      file, a warning is emitted and the IdentityFile line is commented out. Convert the key
      first with: ssh-keygen -p -N "" -m pem -f <key.ppk>  (or use puttygen).
    - Sessions named "Default Settings" are skipped.
    - Session names are URL-decoded (PuTTY stores spaces as %20 etc.)

.PARAMETER OutputPath
    Path to write the SSH config to. Defaults to ~/.ssh/config.

.PARAMETER Append
    When specified, appends to the existing config instead of replacing it.
    A backup is still created.

.EXAMPLE
    # Preview what would be generated without writing anything
    .\Convert-PuTTYSessionsToSSHConfig.ps1 -WhatIf

.EXAMPLE
    # Write to default ~/.ssh/config (backs up existing)
    .\Convert-PuTTYSessionsToSSHConfig.ps1

.EXAMPLE
    # Write to a custom path
    .\Convert-PuTTYSessionsToSSHConfig.ps1 -OutputPath C:\Temp\ssh_config_preview.txt

.EXAMPLE
    # Append to existing config
    .\Convert-PuTTYSessionsToSSHConfig.ps1 -Append
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $false)]
    [string]$OutputPath = (Join-Path $env:USERPROFILE '.ssh\config'),

    [Parameter(Mandatory = $false)]
    [switch]$Append
)

#region Write-Log
function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Message,

        [Parameter(Mandatory = $false)]
        [ValidateSet('Info', 'Warning', 'Error', 'Success')]
        [string]$Level = 'Info'
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $color = switch ($Level) {
        'Info'    { 'White' }
        'Warning' { 'Yellow' }
        'Error'   { 'Red' }
        'Success' { 'Green' }
    }

    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}
#endregion

#region Helpers

function ConvertFrom-PuTTYUrlEncoding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$EncodedString
    )

    # PuTTY URL-encodes session names (spaces = %20, etc.)
    return [System.Uri]::UnescapeDataString($EncodedString)
}

function Get-PuTTYSessions {
    [CmdletBinding()]
    param()

    $RegistryPath = 'HKCU:\Software\SimonTatham\PuTTY\Sessions'

    if (-not (Test-Path $RegistryPath)) {
        Write-Log "PuTTY sessions registry key not found at: $RegistryPath" -Level Warning
        return @()
    }

    $sessionKeys = Get-ChildItem -Path $RegistryPath
    Write-Log "Found $($sessionKeys.Count) PuTTY session(s) in registry" -Level Info

    $sessions = foreach ($sessionKey in $sessionKeys) {
        $sessionName = ConvertFrom-PuTTYUrlEncoding -EncodedString $sessionKey.PSChildName

        if ($sessionName -eq 'Default Settings') {
            Write-Log "Skipping 'Default Settings'" -Level Info
            continue
        }

        $properties = Get-ItemProperty -Path $sessionKey.PSPath
        $hostname = $properties.HostName
        $username = $properties.UserName
        $port = $properties.PortNumber
        $keyFile = $properties.PublicKeyFile

        # Skip sessions with no hostname (empty/template sessions)
        if ([string]::IsNullOrWhiteSpace($hostname)) {
            Write-Log "Skipping '$sessionName' - no HostName configured" -Level Warning
            continue
        }

        [PSCustomObject]@{
            SessionName = $sessionName
            HostName    = $hostname
            UserName    = $username
            Port        = if ($port -and $port -ne 22) { $port } else { $null }
            KeyFile     = $keyFile
        }
    }

    return $sessions
}

function ConvertTo-SSHConfigBlock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Session
    )

    # Sanitise the session name for use as SSH Host alias (no spaces in Host alias is safest)
    $hostAlias = $Session.SessionName -replace '\s+', '-'

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("Host $hostAlias")
    $lines.Add("    HostName $($Session.HostName)")

    if (-not [string]::IsNullOrWhiteSpace($Session.UserName)) {
        $lines.Add("    User $($Session.UserName)")
    }

    if ($Session.Port) {
        $lines.Add("    Port $($Session.Port)")
    }

    if (-not [string]::IsNullOrWhiteSpace($Session.KeyFile)) {
        if ($Session.KeyFile -like '*.ppk') {
            Write-Log "Session '$($Session.SessionName)': key file '$($Session.KeyFile)' is a PuTTY .ppk format - NOT compatible with OpenSSH. Convert it first, then update the IdentityFile line." -Level Warning
            $lines.Add("    # IdentityFile $($Session.KeyFile)  <-- PPK FORMAT: convert to OpenSSH format first")
        }
        else {
            $lines.Add("    IdentityFile $($Session.KeyFile)")
        }
    }

    return $lines -join "`n"
}

#endregion

#region Main

Write-Log "PuTTY to SSH config converter starting" -Level Info
Write-Log "Output path: $OutputPath" -Level Info

$PuTTYSessions = Get-PuTTYSessions

if ($PuTTYSessions.Count -eq 0) {
    Write-Log "No sessions to convert. Exiting." -Level Warning
    exit 0
}

# Build config content
$ConfigHeader = @"
# Generated by Convert-PuTTYSessionsToSSHConfig.ps1
# Date: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
# Source: HKCU:\Software\SimonTatham\PuTTY\Sessions
# $($PuTTYSessions.Count) session(s) converted
"@

$ConfigBlocks = foreach ($Session in $PuTTYSessions) {
    Write-Log "Converting session: '$($Session.SessionName)' -> $($Session.HostName)" -Level Info
    ConvertTo-SSHConfigBlock -Session $Session
}

$ConfigContent = $ConfigHeader + "`n`n" + ($ConfigBlocks -join "`n`n") + "`n"

# Preview in WhatIf mode
if ($WhatIfPreference) {
    Write-Log "WhatIf: Would write the following to $OutputPath" -Level Info
    Write-Host "`n--- SSH CONFIG PREVIEW ---" -ForegroundColor Cyan
    Write-Host $ConfigContent -ForegroundColor Gray
    Write-Host "--- END PREVIEW ---`n" -ForegroundColor Cyan
    exit 0
}

# Ensure ~/.ssh directory exists
$SshDirectory = Split-Path -Parent $OutputPath
if (-not (Test-Path $SshDirectory)) {
    Write-Log "Creating SSH directory: $SshDirectory" -Level Info
    New-Item -ItemType Directory -Path $SshDirectory -Force | Out-Null
}

# Backup existing config
if (Test-Path $OutputPath) {
    $BackupPath = "$OutputPath.backup_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    if ($PSCmdlet.ShouldProcess($OutputPath, "Backup existing SSH config to $BackupPath")) {
        Copy-Item -Path $OutputPath -Destination $BackupPath
        Write-Log "Backed up existing config to: $BackupPath" -Level Info
    }
}

# Write config
if ($Append) {
    if ($PSCmdlet.ShouldProcess($OutputPath, "Append $($PuTTYSessions.Count) session(s) to SSH config")) {
        Add-Content -Path $OutputPath -Value "`n$ConfigContent" -Encoding UTF8
        Write-Log "Appended $($PuTTYSessions.Count) session(s) to: $OutputPath" -Level Success
    }
}
else {
    if ($PSCmdlet.ShouldProcess($OutputPath, "Write $($PuTTYSessions.Count) session(s) to SSH config")) {
        Set-Content -Path $OutputPath -Value $ConfigContent -Encoding UTF8
        Write-Log "Written $($PuTTYSessions.Count) session(s) to: $OutputPath" -Level Success
    }
}

Write-Log "Done. Review $OutputPath before using - especially any commented-out PPK key paths." -Level Success

#endregion
