<#
.SYNOPSIS
    Connect to an Azure VM via Bastion tunnel with YubiKey SSH authentication.

.DESCRIPTION
    Looks up the target alias in ~/.yubissh/*.json config files, establishes an
    Azure Bastion tunnel to the VM, then connects via SSH (using your YubiKey or
    any configured identity file).

    If no alias is specified, lists all known hosts across all config files.

    Config files live in ~/.yubissh/ - one JSON file per client.
    See the README for the config schema.

.PARAMETER Alias
    The host alias to connect to. Must match an alias defined in one of the
    config files in ~/.yubissh/.
    If omitted, lists all known hosts.

.PARAMETER SSHKey
    Override the SSH identity file. Defaults to the key in the host config,
    or ~/.ssh/id_ed25519_sk if not configured.

.PARAMETER User
    Override the SSH username. Defaults to the user in the host config.

.EXAMPLE
    # List all known hosts across all configs
    .\Connect-YubiSSH.ps1

.EXAMPLE
    # Connect to a host
    .\Connect-YubiSSH.ps1 ae-web-01

.EXAMPLE
    # Connect with a username override
    .\Connect-YubiSSH.ps1 ae-web-01 -User pax

.NOTES
    Requires:
    - Azure CLI (az) - https://aka.ms/installazurecliwindows
    - OpenSSH 8.2+
    - Azure Bastion Standard tier on the target bastion resource

    Host key checking is disabled for tunnel connections (localhost:randomport).
    Security is provided by Azure authentication + YubiKey SSH auth.
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory = $false, Position = 0)]
  [string]$Alias,

  [Parameter(Mandatory = $false)]
  [string]$SSHKey,

  [Parameter(Mandatory = $false)]
  [string]$User
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

#region Config

$ConfigDir = Join-Path $env:USERPROFILE '.yubissh'
$DefaultSSHKey = Join-Path $env:USERPROFILE '.ssh\id_ed25519_sk'

function Get-AllHostConfigs {
  [CmdletBinding()]
  param()

  if (-not (Test-Path $ConfigDir)) {
    return @()
  }

  $results = [System.Collections.Generic.List[PSCustomObject]]::new()

  foreach ($configFile in Get-ChildItem -Path $ConfigDir -Filter '*.json') {
    try {
      $config = Get-Content $configFile.FullName -Raw | ConvertFrom-Json
      foreach ($hostEntry in $config.hosts) {
        $results.Add([PSCustomObject]@{
            Client               = $config.client
            TenantId             = $config.tenant
            Alias                = $hostEntry.alias
            User                 = $hostEntry.user
            VMName               = $hostEntry.vmName
            VMResourceGroup      = $hostEntry.vmResourceGroup
            VMSubscription       = $hostEntry.vmSubscription
            BastionName          = $hostEntry.bastionName
            BastionResourceGroup = $hostEntry.bastionResourceGroup
            BastionSubscription  = $hostEntry.bastionSubscription
            SSHPort              = if ($hostEntry.sshPort) {
              $hostEntry.sshPort 
            }
            else {
              22 
            }
            SSHKey               = $hostEntry.sshKey
            ConfigFile           = $configFile.Name
          })
      }
    }
    catch {
      Write-Log "Failed to parse config file '$($configFile.Name)': $_" -Level Warning
    }
  }

  return $results
}

function Find-HostConfig {
  [CmdletBinding()]
  param([string]$TargetAlias)

  $allHosts = Get-AllHostConfigs
  $matches = $allHosts | Where-Object { $_.Alias -eq $TargetAlias }

  if ($matches.Count -eq 0) {
    return $null
  }

  if ($matches.Count -gt 1) {
    Write-Log "Alias '$TargetAlias' found in multiple config files: $($matches.ConfigFile -join ', ')" -Level Warning
    Write-Log "Using first match from '$($matches[0].ConfigFile)'" -Level Warning
  }

  return $matches[0]
}

#endregion

#region Networking

function Get-FreePort {
  [CmdletBinding()]
  param(
    [int]$StartPort = 2222
  )

  for ($port = $StartPort; $port -lt 65535; $port++) {
    try {
      $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $port)
      $listener.Start()
      $listener.Stop()
      return $port
    }
    catch {
      continue
    }
  }
  throw "Could not find a free local port starting from $StartPort"
}

function Wait-PortOpen {
  [CmdletBinding()]
  param(
    [int]$Port,
    [int]$TimeoutSeconds = 30
  )

  Write-Log "Waiting for tunnel on port $Port..." -Level Info
  $elapsed = 0

  while ($elapsed -lt $TimeoutSeconds) {
    try {
      $tcp = [System.Net.Sockets.TcpClient]::new('localhost', $Port)
      $tcp.Close()
      return $true
    }
    catch {
      Start-Sleep -Milliseconds 500
      $elapsed++
    }
  }

  return $false
}

#endregion

#region Azure

function Test-AzureCLI {
  [CmdletBinding()]
  param()

  if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Log "Azure CLI not found. Install from: https://aka.ms/installazurecliwindows" -Level Error
    return $false
  }
  return $true
}

function Set-AzureContext {
  [CmdletBinding()]
  param(
    [string]$TenantId,
    [string]$SubscriptionId
  )

  # Check current tenant
  $currentTenant = & az account show --query tenantId -o tsv 2>$null

  if ($LASTEXITCODE -ne 0 -or $currentTenant -ne $TenantId) {
    Write-Log "Logging in to tenant $TenantId..." -Level Info
    & az login --tenant $TenantId --only-show-errors

    if ($LASTEXITCODE -ne 0) {
      Write-Log "Azure login failed" -Level Error
      return $false
    }
  }

  Write-Log "Setting subscription: $SubscriptionId" -Level Info
  & az account set --subscription $SubscriptionId --only-show-errors

  if ($LASTEXITCODE -ne 0) {
    Write-Log "Failed to set subscription '$SubscriptionId'" -Level Error
    return $false
  }

  return $true
}

#endregion

#region Connection

function Connect-BastionSSH {
  [CmdletBinding()]
  param(
    [PSCustomObject]$HostConfig,
    [string]$SSHKeyOverride,
    [string]$UserOverride
  )

  $resolvedUser = if ($UserOverride) {
    $UserOverride 
  }
  else {
    $HostConfig.User 
  }
  $resolvedKey = if ($SSHKeyOverride) {
    $SSHKeyOverride 
  }
  elseif ($HostConfig.SSHKey) {
    $HostConfig.SSHKey 
  }
  else {
    $DefaultSSHKey 
  }

  if (-not (Test-Path $resolvedKey)) {
    Write-Log "SSH key not found: $resolvedKey" -Level Error
    return
  }

  # Azure context
  if (-not (Set-AzureContext -TenantId $HostConfig.TenantId -SubscriptionId $HostConfig.BastionSubscription)) {
    return
  }

  # VM resource ID (full ARM ID - can reference a different subscription)
  $vmResourceId = "/subscriptions/$($HostConfig.VMSubscription)/resourceGroups/$($HostConfig.VMResourceGroup)/providers/Microsoft.Compute/virtualMachines/$($HostConfig.VMName)"

  # Find a free local port
  $localPort = Get-FreePort
  Write-Log "Using local tunnel port: $localPort" -Level Info

  # Temp files for tunnel process output
  $tunnelStdout = Join-Path $env:TEMP "yubissh_$localPort.log"
  $tunnelStderr = Join-Path $env:TEMP "yubissh_$localPort.err"

  $tunnelProcess = $null

  try {
    # Start the Bastion tunnel as a background process
    Write-Log "Starting Bastion tunnel: $($HostConfig.BastionName) -> $($HostConfig.VMName)" -Level Info

    $azArgs = "network bastion tunnel --name $($HostConfig.BastionName) --resource-group $($HostConfig.BastionResourceGroup) --target-resource-id $vmResourceId --resource-port $($HostConfig.SSHPort) --port $localPort"

    $tunnelProcess = Start-Process `
      -FilePath 'az' `
      -ArgumentList $azArgs `
      -PassThru `
      -NoNewWindow `
      -RedirectStandardOutput $tunnelStdout `
      -RedirectStandardError $tunnelStderr

    # Wait for tunnel to be ready
    $tunnelReady = Wait-PortOpen -Port $localPort -TimeoutSeconds 30

    if (-not $tunnelReady) {
      Write-Log "Tunnel failed to open within 30 seconds" -Level Error
      if (Test-Path $tunnelStderr) {
        $errContent = Get-Content $tunnelStderr -Raw
        if ($errContent) {
          Write-Log "az error: $errContent" -Level Error 
        }
      }
      return
    }

    Write-Log "Tunnel ready - connecting to $resolvedUser@$($HostConfig.Alias)" -Level Success
    Write-Host ""

    # SSH - host key checking disabled since it's localhost:randomport
    & ssh `
      -p $localPort `
      -i $resolvedKey `
      -o 'StrictHostKeyChecking=no' `
      -o 'UserKnownHostsFile=NUL' `
      "$resolvedUser@localhost"
  }
  finally {
    # Always kill the tunnel when SSH exits
    if ($tunnelProcess -and -not $tunnelProcess.HasExited) {
      Write-Host ""
      Write-Log "Closing tunnel..." -Level Info
      Stop-Process -Id $tunnelProcess.Id -Force -ErrorAction SilentlyContinue
    }

    # Clean up temp files
    Remove-Item $tunnelStdout -Force -ErrorAction SilentlyContinue
    Remove-Item $tunnelStderr -Force -ErrorAction SilentlyContinue

    Write-Log "Disconnected from $($HostConfig.Alias)" -Level Info
  }
}

#endregion

#region Main

# Ensure config dir exists
if (-not (Test-Path $ConfigDir)) {
  New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null
  Write-Log "Created config directory: $ConfigDir" -Level Info
  Write-Log "Add client config files (*.json) to that directory. See README for schema." -Level Warning
  exit 0
}

# List mode
if (-not $Alias) {
  $allHosts = Get-AllHostConfigs

  if ($allHosts.Count -eq 0) {
    Write-Log "No hosts configured. Add *.json config files to $ConfigDir" -Level Warning
    exit 0
  }

  $allHosts | Select-Object Client, Alias, User, VMName, BastionName, ConfigFile | Format-Table -AutoSize
  exit 0
}

# Connect mode
if (-not (Test-AzureCLI)) {
  exit 1 
}

$hostConfig = Find-HostConfig -TargetAlias $Alias

if (-not $hostConfig) {
  Write-Log "No host found with alias '$Alias'. Run without arguments to list known hosts." -Level Error
  exit 1
}

Write-Log "Connecting to: $($hostConfig.Alias) [$($hostConfig.Client)]" -Level Info
Connect-BastionSSH -HostConfig $hostConfig -SSHKeyOverride $SSHKey -UserOverride $User

#endregion
