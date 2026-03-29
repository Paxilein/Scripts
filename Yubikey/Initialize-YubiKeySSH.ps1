<#
.SYNOPSIS
    Sets up a YubiKey-backed SSH key and wires it into your SSH config.

.DESCRIPTION
    Generates an ed25519-sk hardware-backed SSH key using your YubiKey, then
    updates ~/.ssh/config to add the IdentityFile to specified hosts (or all hosts).

    Requires:
    - OpenSSH 8.2+ (ships with Windows 10 1903+)
    - YubiKey plugged in when running

    The private key file (~/.ssh/id_ed25519_sk) is effectively a handle/credential ID.
    The actual private key never leaves the YubiKey hardware.

.PARAMETER KeyPath
    Path for the generated key. Defaults to ~/.ssh/id_ed25519_sk.

.PARAMETER KeyComment
    Comment embedded in the public key. Defaults to "$env:USERNAME@yubikey".

.PARAMETER Hosts
    One or more Host aliases from your SSH config to wire up the key to.
    If not specified, adds the IdentityFile to ALL hosts in your config.

.PARAMETER SSHConfigPath
    Path to your SSH config. Defaults to ~/.ssh/config.

.PARAMETER SkipConfigUpdate
    Generate the key but don't touch the SSH config.

.EXAMPLE
    # Full setup - generate key and wire up all hosts
    .\Initialize-YubiKeySSH.ps1

.EXAMPLE
    # Wire up specific hosts only
    .\Initialize-YubiKeySSH.ps1 -Hosts "web-server", "bastion"

.EXAMPLE
    # Just generate the key, update config manually later
    .\Initialize-YubiKeySSH.ps1 -SkipConfigUpdate

.EXAMPLE
    # Preview config changes without writing
    .\Initialize-YubiKeySSH.ps1 -WhatIf
#>

[CmdletBinding(SupportsShouldProcess)]
param(
  [Parameter(Mandatory = $false)]
  [string]$KeyPath = (Join-Path $env:USERPROFILE '.ssh\id_ed25519_sk'),

  [Parameter(Mandatory = $false)]
  [string]$KeyComment = "$env:USERNAME@yubikey",

  [Parameter(Mandatory = $false)]
  [string[]]$Hosts,

  [Parameter(Mandatory = $false)]
  [string]$SSHConfigPath = (Join-Path $env:USERPROFILE '.ssh\config'),

  [Parameter(Mandatory = $false)]
  [switch]$SkipConfigUpdate
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
    'Info' {
      'White' 
    }
    'Warning' {
      'Yellow' 
    }
    'Error' {
      'Red' 
    }
    'Success' {
      'Green' 
    }
  }

  Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}
#endregion

#region Prereq checks

function Test-OpenSSHVersion {
  [CmdletBinding()]
  param()

  $sshPath = Get-Command ssh -ErrorAction SilentlyContinue
  if (-not $sshPath) {
    Write-Log "ssh.exe not found. Install OpenSSH via: Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0" -Level Error
    return $false
  }

  # Parse version from "OpenSSH_for_Windows_9.x.x, ..."
  $versionOutput = & ssh -V 2>&1
  if ($versionOutput -match 'OpenSSH[_\w]*\s*(\d+)\.(\d+)') {
    $major = [int]$matches[1]
    $minor = [int]$matches[2]
    if ($major -gt 8 -or ($major -eq 8 -and $minor -ge 2)) {
      Write-Log "OpenSSH $major.$minor detected - FIDO2 supported" -Level Success
      return $true
    }
    else {
      Write-Log "OpenSSH $major.$minor is too old - FIDO2 requires 8.2+. Update via Windows Update or winget." -Level Error
      return $false
    }
  }

  # Can't parse version but ssh exists - warn and continue
  Write-Log "Could not parse OpenSSH version ('$versionOutput') - proceeding anyway" -Level Warning
  return $true
}

function Test-YubiKeyPresent {
  [CmdletBinding()]
  param()

  # Try ykman first (most reliable)
  $ykman = Get-Command ykman -ErrorAction SilentlyContinue
  if ($ykman) {
    $ykmanOutput = & ykman info 2>&1
    if ($LASTEXITCODE -eq 0) {
      $deviceLine = $ykmanOutput | Where-Object { $_ -match 'Device type|YubiKey' } | Select-Object -First 1
      Write-Log "YubiKey detected via ykman: $deviceLine" -Level Success
      return $true
    }
    else {
      Write-Log "ykman found but no YubiKey detected. Plug in your YubiKey and re-run." -Level Error
      return $false
    }
  }

  # Fallback: check USB HID devices for Yubico vendor ID (0x1050)
  $yubicoDevices = Get-PnpDevice -Class HIDClass -Status OK -ErrorAction SilentlyContinue |
  Where-Object { $_.HardwareID -like '*VID_1050*' }

  if ($yubicoDevices) {
    Write-Log "YubiKey detected via USB HID" -Level Success
    return $true
  }

  Write-Log "No YubiKey detected. Plug it in and re-run. (Install ykman for better detection: winget install Yubico.YubiKeyManager)" -Level Error
  return $false
}

#endregion

#region Key generation

function New-YubiKeySSHKey {
  [CmdletBinding(SupportsShouldProcess)]
  param(
    [string]$KeyPath,
    [string]$Comment
  )

  $publicKeyPath = "$KeyPath.pub"

  if (Test-Path $KeyPath) {
    Write-Log "Key already exists at: $KeyPath" -Level Warning
    $overwrite = Read-Host "Overwrite? (y/N)"
    if ($overwrite -ne 'y') {
      Write-Log "Skipping key generation - using existing key" -Level Info
      return $true
    }
  }

  Write-Log "Generating ed25519-sk key - touch your YubiKey when it flashes..." -Level Info
  Write-Host ""

  if ($PSCmdlet.ShouldProcess($KeyPath, "Generate YubiKey-backed ed25519-sk SSH key")) {
    & ssh-keygen -t ed25519-sk -C $Comment -f $KeyPath

    if ($LASTEXITCODE -ne 0) {
      Write-Log "ssh-keygen failed (exit code $LASTEXITCODE). Did you touch the key?" -Level Error
      return $false
    }

    Write-Host ""
    Write-Log "Key generated successfully" -Level Success
    Write-Log "Public key: $publicKeyPath" -Level Info
    Write-Host ""
    Write-Host "--- PUBLIC KEY (copy this to your servers' ~/.ssh/authorized_keys) ---" -ForegroundColor Cyan
    Get-Content $publicKeyPath | Write-Host -ForegroundColor Gray
    Write-Host "---" -ForegroundColor Cyan
    Write-Host ""
  }

  return $true
}

#endregion

#region SSH config update

function Update-SSHConfig {
  [CmdletBinding(SupportsShouldProcess)]
  param(
    [string]$ConfigPath,
    [string]$KeyPath,
    [string[]]$TargetHosts
  )

  if (-not (Test-Path $ConfigPath)) {
    Write-Log "SSH config not found at $ConfigPath - skipping config update" -Level Warning
    return
  }

  $configContent = Get-Content $ConfigPath -Raw
  $lines = Get-Content $ConfigPath

  # Parse host blocks to find which ones to update
  $hostBlocks = [System.Collections.Generic.List[PSCustomObject]]::new()
  $currentHost = $null
  $currentStartLine = -1

  for ($i = 0; $i -lt $lines.Count; $i++) {
    $line = $lines[$i]
    if ($line -match '^\s*Host\s+(.+)$') {
      if ($currentHost) {
        $hostBlocks.Add([PSCustomObject]@{
            Alias     = $currentHost
            StartLine = $currentStartLine
            EndLine   = $i - 1
          })
      }
      $currentHost = $matches[1].Trim()
      $currentStartLine = $i
    }
  }
  if ($currentHost) {
    $hostBlocks.Add([PSCustomObject]@{
        Alias     = $currentHost
        StartLine = $currentStartLine
        EndLine   = $lines.Count - 1
      })
  }

  # Filter to target hosts if specified
  $blocksToUpdate = if ($TargetHosts) {
    $hostBlocks | Where-Object { $_.Alias -in $TargetHosts }
  }
  else {
    $hostBlocks
  }

  if ($blocksToUpdate.Count -eq 0) {
    Write-Log "No matching hosts found in SSH config to update" -Level Warning
    return
  }

  Write-Log "Updating IdentityFile for $($blocksToUpdate.Count) host(s): $($blocksToUpdate.Alias -join ', ')" -Level Info

  # Backup config
  $backupPath = "$ConfigPath.backup_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
  if ($PSCmdlet.ShouldProcess($ConfigPath, "Backup SSH config to $backupPath")) {
    Copy-Item $ConfigPath $backupPath
    Write-Log "Backed up config to: $backupPath" -Level Info
  }

  # Process each block - replace commented PPK lines or add IdentityFile
  $updatedLines = [System.Collections.Generic.List[string]]::new()
  $updatedLines.AddRange([string[]]$lines)
  $identityFileLine = "    IdentityFile $KeyPath"
  $offsetAdjustment = 0

  foreach ($block in ($blocksToUpdate | Sort-Object StartLine)) {
    $start = $block.StartLine + $offsetAdjustment
    $end = $block.EndLine + $offsetAdjustment

    $blockLines = $updatedLines[$start..$end]
    $ppkCommentIndex = -1
    $existingIdentityIndex = -1

    for ($i = 0; $i -lt $blockLines.Count; $i++) {
      if ($blockLines[$i] -match '^\s*#\s*IdentityFile.*PPK FORMAT') {
        $ppkCommentIndex = $i
      }
      elseif ($blockLines[$i] -match '^\s*IdentityFile\s+') {
        $existingIdentityIndex = $i
      }
    }

    if ($existingIdentityIndex -ge 0) {
      $absoluteIndex = $start + $existingIdentityIndex
      if ($PSCmdlet.ShouldProcess($block.Alias, "Replace existing IdentityFile line")) {
        $updatedLines[$absoluteIndex] = $identityFileLine
        Write-Log "[$($block.Alias)] Replaced existing IdentityFile" -Level Info
      }
    }
    elseif ($ppkCommentIndex -ge 0) {
      $absoluteIndex = $start + $ppkCommentIndex
      if ($PSCmdlet.ShouldProcess($block.Alias, "Replace PPK comment with IdentityFile")) {
        $updatedLines[$absoluteIndex] = $identityFileLine
        Write-Log "[$($block.Alias)] Replaced PPK comment with IdentityFile" -Level Info
      }
    }
    else {
      # No existing IdentityFile - insert after the Host line
      $insertAt = $start + 1
      if ($PSCmdlet.ShouldProcess($block.Alias, "Add IdentityFile line")) {
        $updatedLines.Insert($insertAt, $identityFileLine)
        $offsetAdjustment++
        Write-Log "[$($block.Alias)] Added IdentityFile line" -Level Info
      }
    }
  }

  if ($PSCmdlet.ShouldProcess($ConfigPath, "Write updated SSH config")) {
    $updatedLines | Set-Content $ConfigPath -Encoding UTF8
    Write-Log "SSH config updated" -Level Success
  }
}

#endregion

#region Main

Write-Log "YubiKey SSH setup starting" -Level Info
Write-Host ""

# Prereqs
if (-not (Test-OpenSSHVersion)) {
  exit 1 
}
if (-not (Test-YubiKeyPresent)) {
  exit 1 
}

# Generate key
$keyGenResult = New-YubiKeySSHKey -KeyPath $KeyPath -Comment $KeyComment
if (-not $keyGenResult) {
  exit 1 
}

# Update SSH config
if (-not $SkipConfigUpdate) {
  Update-SSHConfig -ConfigPath $SSHConfigPath -KeyPath $KeyPath -TargetHosts $Hosts
}

Write-Host ""
Write-Log "Done!" -Level Success
Write-Log "Next steps:" -Level Info
Write-Log "  1. Copy the public key above to ~/.ssh/authorized_keys on each server" -Level Info
Write-Log "  2. Test with: ssh <host-alias>" -Level Info
Write-Log "  3. Touch the YubiKey when it flashes during login" -Level Info

#endregion
