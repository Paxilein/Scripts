<#
.SYNOPSIS
    Interactively create or update a ~/.yubissh client config file.

.DESCRIPTION
    Guides you through creating a JSON config file for use with Connect-YubiSSH.ps1.
    Uses Azure CLI to let you pick subscriptions, VMs, and Bastions from lists rather
    than typing resource IDs manually.

    Saves to ~/.yubissh/<ClientName>.json. If the file already exists, new hosts are
    appended to it.

.PARAMETER ClientName
    Name of the client to create or update a config for.
    If not specified, you will be prompted.

.EXAMPLE
    # Fully interactive
    .\New-YubiSSHConfig.ps1

.EXAMPLE
    # Pre-fill the client name
    .\New-YubiSSHConfig.ps1 -ClientName "Acme Corp"

.NOTES
    Requires Azure CLI (az): winget install Microsoft.AzureCLI
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory = $false)]
  [string]$ClientName
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

#region Helpers

function Read-NonEmptyString {
  param([string]$Prompt, [string]$Default)

  while ($true) {
    $displayPrompt = if ($Default) {
      "$Prompt [$Default]" 
    }
    else {
      $Prompt 
    }
    $value = Read-Host $displayPrompt
    if (-not $value -and $Default) {
      return $Default 
    }
    if ($value) {
      return $value 
    }
    Write-Host "  Value is required." -ForegroundColor Yellow
  }
}

function Select-FromList {
  param(
    [string]$Prompt,
    [object[]]$Items,
    [string]$DisplayProperty,
    [string]$SubDisplayProperty
  )

  if ($Items.Count -eq 0) {
    return $null
  }

  if ($Items.Count -eq 1) {
    $display = if ($SubDisplayProperty) {
      "$($Items[0].$DisplayProperty) ($($Items[0].$SubDisplayProperty))"
    }
    else {
      $Items[0].$DisplayProperty
    }
    Write-Host "  Auto-selected: $display" -ForegroundColor Gray
    return $Items[0]
  }

  Write-Host ""
  Write-Host "  $Prompt" -ForegroundColor Cyan
  for ($i = 0; $i -lt $Items.Count; $i++) {
    $display = if ($SubDisplayProperty) {
      "$($Items[$i].$DisplayProperty) ($($Items[$i].$SubDisplayProperty))"
    }
    else {
      $Items[$i].$DisplayProperty
    }
    Write-Host "  [$($i + 1)] $display"
  }
  Write-Host ""

  while ($true) {
    $input = Read-Host "  Enter number (1-$($Items.Count))"
    if ($input -match '^\d+$') {
      $index = [int]$input - 1
      if ($index -ge 0 -and $index -lt $Items.Count) {
        return $Items[$index]
      }
    }
    Write-Host "  Invalid selection." -ForegroundColor Yellow
  }
}

#endregion

#region Azure helpers

function Get-AzureSubscriptions {
  param([string]$TenantId)

  $json = & az account list --query "[?tenantId=='$TenantId']" -o json 2>$null
  if ($LASTEXITCODE -ne 0 -or -not $json) {
    return @() 
  }

  return ($json | ConvertFrom-Json) | ForEach-Object {
    [PSCustomObject]@{
      Name = $_.name
      Id   = $_.id
    }
  } | Sort-Object Name
}

function Find-AzureVMs {
  param(
    [string]$SubscriptionId,
    [string]$SearchTerm
  )

  Write-Log "Searching for VMs matching '$SearchTerm' in subscription..." -Level Info

  $json = & az vm list --subscription $SubscriptionId --query "[?contains(name, '$SearchTerm')]" -o json 2>$null
  if ($LASTEXITCODE -ne 0 -or -not $json) {
    return @() 
  }

  return ($json | ConvertFrom-Json) | ForEach-Object {
    # Extract RG from resourceGroup field (it comes back as the name, not full ID)
    [PSCustomObject]@{
      Name          = $_.name
      ResourceGroup = $_.resourceGroup
    }
  } | Sort-Object Name
}

function Get-AzureBastions {
  param([string]$SubscriptionId)

  Write-Log "Finding Bastion resources in subscription..." -Level Info

  $json = & az network bastion list --subscription $SubscriptionId -o json 2>$null
  if ($LASTEXITCODE -ne 0 -or -not $json) {
    return @() 
  }

  return ($json | ConvertFrom-Json) | ForEach-Object {
    # Extract resource group from id
    $idParts = $_.id -split '/'
    $rgIndex = ($idParts | Select-String -Pattern '^resourceGroups$' -SimpleMatch | Select-Object -First 1).LineNumber
    $resourceGroup = if ($rgIndex) {
      $idParts[$rgIndex] 
    }
    else {
      $_.resourceGroup 
    }

    [PSCustomObject]@{
      Name          = $_.name
      ResourceGroup = $resourceGroup
    }
  } | Sort-Object Name
}

#endregion

#region Main

$ConfigDir = Join-Path $env:USERPROFILE '.yubissh'
$DefaultSSHKey = Join-Path $env:USERPROFILE '.ssh\id_ed25519_sk'

# Check az CLI
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
  Write-Log "Azure CLI not found. Install from: winget install Microsoft.AzureCLI" -Level Error
  exit 1
}

# Ensure config dir exists
if (-not (Test-Path $ConfigDir)) {
  New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null
}

Write-Host ""
Write-Host "=== YubiSSH Config Generator ===" -ForegroundColor Cyan
Write-Host ""

# Client name
if (-not $ClientName) {
  $ClientName = Read-NonEmptyString -Prompt "Client name (used as config filename)"
}

$configFileName = "$ClientName.json" -replace '[\\/:*?"<>|]', '_'
$configPath = Join-Path $ConfigDir $configFileName

# Load existing config or start fresh
$config = if (Test-Path $configPath) {
  Write-Log "Existing config found at $configPath - appending hosts" -Level Info
  Get-Content $configPath -Raw | ConvertFrom-Json
}
else {
  [PSCustomObject]@{
    client = $ClientName
    tenant = ''
    hosts  = @()
  }
}

# Tenant ID
if (-not $config.tenant) {
  Write-Host ""
  $tenantId = Read-NonEmptyString -Prompt "Azure Tenant ID"
  $config.tenant = $tenantId
}
else {
  Write-Log "Using existing tenant: $($config.tenant)" -Level Info
}

# Login to tenant
Write-Log "Logging in to tenant $($config.tenant)..." -Level Info
& az login --tenant $config.tenant --only-show-errors

if ($LASTEXITCODE -ne 0) {
  Write-Log "Azure login failed" -Level Error
  exit 1
}

# Get subscriptions in this tenant
$subscriptions = Get-AzureSubscriptions -TenantId $config.tenant

if ($subscriptions.Count -eq 0) {
  Write-Log "No subscriptions found in tenant $($config.tenant)" -Level Error
  exit 1
}

# Loop to add hosts
$addAnother = $true

while ($addAnother) {
  Write-Host ""
  Write-Host "--- Add Host ---" -ForegroundColor Cyan

  # Host alias
  $hostAlias = Read-NonEmptyString -Prompt "Host alias (e.g. acme-web-01)"

  # Check for duplicate alias
  $existingAliases = $config.hosts | ForEach-Object { $_.alias }
  if ($existingAliases -contains $hostAlias) {
    Write-Log "Alias '$hostAlias' already exists in this config - skipping" -Level Warning
    continue
  }

  # VM subscription
  Write-Host ""
  $vmSubscription = Select-FromList -Prompt "Select VM subscription:" -Items $subscriptions -DisplayProperty Name -SubDisplayProperty Id

  # VM search
  Write-Host ""
  $vmSearchTerm = Read-NonEmptyString -Prompt "VM name (or partial name to search)"
  $matchingVMs = Find-AzureVMs -SubscriptionId $vmSubscription.Id -SearchTerm $vmSearchTerm

  if ($matchingVMs.Count -eq 0) {
    Write-Log "No VMs found matching '$vmSearchTerm' in $($vmSubscription.Name)" -Level Warning
    $vmName = Read-NonEmptyString -Prompt "Enter VM name manually"
    $vmResourceGroup = Read-NonEmptyString -Prompt "Enter VM resource group manually"
  }
  else {
    $selectedVM = Select-FromList -Prompt "Select VM:" -Items $matchingVMs -DisplayProperty Name -SubDisplayProperty ResourceGroup
    $vmName = $selectedVM.Name
    $vmResourceGroup = $selectedVM.ResourceGroup
  }

  # Bastion subscription (may differ from VM sub - hub/spoke)
  Write-Host ""
  Write-Host "  Bastion subscription (often different from VM - hub/spoke):" -ForegroundColor Cyan
  $bastionSubscription = Select-FromList -Prompt "Select Bastion subscription:" -Items $subscriptions -DisplayProperty Name -SubDisplayProperty Id

  # Find Bastions in that sub
  $bastions = Get-AzureBastions -SubscriptionId $bastionSubscription.Id

  if ($bastions.Count -eq 0) {
    Write-Log "No Bastion resources found in $($bastionSubscription.Name)" -Level Warning
    $bastionName = Read-NonEmptyString -Prompt "Enter Bastion name manually"
    $bastionResourceGroup = Read-NonEmptyString -Prompt "Enter Bastion resource group manually"
  }
  else {
    $selectedBastion = Select-FromList -Prompt "Select Bastion:" -Items $bastions -DisplayProperty Name -SubDisplayProperty ResourceGroup
    $bastionName = $selectedBastion.Name
    $bastionResourceGroup = $selectedBastion.ResourceGroup
  }

  # SSH details
  Write-Host ""
  $sshUser = Read-NonEmptyString -Prompt "SSH username"
  $sshPortInput = Read-Host "SSH port [22]"
  $sshPort = if ($sshPortInput -match '^\d+$') {
    [int]$sshPortInput 
  }
  else {
    22 
  }
  $sshKeyInput = Read-Host "SSH key path [$DefaultSSHKey]"
  $sshKey = if ($sshKeyInput) {
    $sshKeyInput 
  }
  else {
    $null 
  }

  # Build host entry
  $hostEntry = [ordered]@{
    alias                = $hostAlias
    user                 = $sshUser
    vmName               = $vmName
    vmResourceGroup      = $vmResourceGroup
    vmSubscription       = $vmSubscription.Id
    bastionName          = $bastionName
    bastionResourceGroup = $bastionResourceGroup
    bastionSubscription  = $bastionSubscription.Id
  }

  if ($sshPort -ne 22) {
    $hostEntry.sshPort = $sshPort 
  }
  if ($sshKey) {
    $hostEntry.sshKey = $sshKey 
  }

  # Append to config
  $config.hosts = @($config.hosts) + [PSCustomObject]$hostEntry

  Write-Log "Host '$hostAlias' added" -Level Success

  # Loop prompt
  Write-Host ""
  $moreInput = Read-Host "Add another host? (y/N)"
  $addAnother = $moreInput -eq 'y'
}

# Write config
$config | ConvertTo-Json -Depth 5 | Set-Content $configPath -Encoding UTF8
Write-Log "Config saved to: $configPath" -Level Success
Write-Host ""
Write-Log "Run 'Connect-YubiSSH.ps1' to list all configured hosts." -Level Info

#endregion
