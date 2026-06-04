<#
.SYNOPSIS
    Reports GitHub Copilot token usage and estimated credit cost per VS Code workspace.

.DESCRIPTION
    Parses GitHub Copilot chat debug logs from all VS Code workspace storage folders
    and summarises token consumption and estimated credit cost per workspace.

    Credit rates are based on the GitHub Copilot premium model pricing (credits per 1M tokens)
    introduced on 1 June 2026.

    Requires GitHub Copilot debug logging to be enabled in VS Code settings:
        "github.copilot.advanced": { "debug.overrideCapabilities": ["debug"] }

    Only sessions logged after enabling debug mode will contain token data.

.PARAMETER SortBy
    Column to sort results by. Defaults to Credits (highest first).
    Valid values: Workspace, Requests, TotalInput, TotalOutput, TotalCached, Credits

.PARAMETER Since
    Only include requests from this date/time onwards. Defaults to all available data.

.PARAMETER ExportCsv
    Optional path to export results to a CSV file.

.PARAMETER Insiders
    Target VS Code Insiders instead of stable VS Code.

.EXAMPLE
    .\Get-CopilotTokenUsage.ps1

.EXAMPLE
    .\Get-CopilotTokenUsage.ps1 -Insiders

.EXAMPLE
    .\Get-CopilotTokenUsage.ps1 -Since (Get-Date).AddDays(-7)

.EXAMPLE
    .\Get-CopilotTokenUsage.ps1 -SortBy Requests -ExportCsv C:\Reports\copilot-usage.csv

.NOTES
    Author: Pax
    Date: 2026-06-04
    Requires: VS Code with GitHub Copilot extension, debug logging enabled
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory = $false)]
  [ValidateSet('Workspace', 'Requests', 'TotalInput', 'TotalOutput', 'TotalCached', 'Credits')]
  [string]$SortBy = 'Credits',

  [Parameter(Mandatory = $false)]
  [datetime]$Since,

  [Parameter(Mandatory = $false)]
  [string]$ExportCsv,

  [Parameter(Mandatory = $false)]
  [switch]$Insiders
)

#region Helper Functions

function Write-Log {
  param(
    [Parameter(Mandatory = $true)]
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
  $prefix = switch ($Level) {
    'Info' {
      'INF'
    }
    'Warning' {
      'WRN'
    }
    'Error' {
      'ERR'
    }
    'Success' {
      'OK '
    }
  }
  Write-Host "[$timestamp] [$prefix] $Message" -ForegroundColor $color
}

function Get-EstimatedCredits {
  param(
    [string]$Model,
    [long]$InputTokens,
    [long]$OutputTokens,
    [long]$CachedTokens
  )

  # Credits per 1M tokens — rates as of 1 June 2026
  $modelRates = @{
    'claude-haiku-4.5'  = @{ In = 100; Out = 500; Cache = 10 }
    'claude-opus-4.5'   = @{ In = 500; Out = 2500; Cache = 50 }
    'claude-opus-4.6'   = @{ In = 500; Out = 2500; Cache = 50 }
    'claude-opus-4.7'   = @{ In = 500; Out = 2500; Cache = 50 }
    'claude-sonnet-4.5' = @{ In = 300; Out = 1500; Cache = 30 }
    'claude-sonnet-4.6' = @{ In = 300; Out = 1500; Cache = 30 }
    'gemini-2.5-pro'    = @{ In = 125; Out = 1000; Cache = 12 }
    'gemini-3-flash'    = @{ In = 50; Out = 300; Cache = 5 }
    'gemini-3.1-pro'    = @{ In = 200; Out = 1200; Cache = 20 }
    'gemini-3.5-flash'  = @{ In = 150; Out = 900; Cache = 15 }
    'gpt-5-mini'        = @{ In = 25; Out = 200; Cache = 2 }
    'gpt-5.2'           = @{ In = 175; Out = 1400; Cache = 17 }
    'gpt-5.2-codex'     = @{ In = 175; Out = 1400; Cache = 17 }
    'gpt-5.3-codex'     = @{ In = 175; Out = 1400; Cache = 17 }
    'gpt-5.4'           = @{ In = 250; Out = 1500; Cache = 25 }
    'gpt-5.4-mini'      = @{ In = 75; Out = 450; Cache = 7 }
    'gpt-5.5'           = @{ In = 500; Out = 3000; Cache = 50 }
  }

  $rates = $modelRates[$Model.ToLower()]
  if (-not $rates) {
    return $null
  }

  $freshInputTokens = [math]::Max(0, $InputTokens - $CachedTokens)
  $credits = (($freshInputTokens * $rates.In) + ($CachedTokens * $rates.Cache) + ($OutputTokens * $rates.Out)) / 1e6
  return [math]::Round($credits, 4)
}

#endregion

#region Main

$storageRoot = if ($Insiders) {
  "$env:APPDATA\Code - Insiders\User\workspaceStorage"
}
else {
  "$env:APPDATA\Code\User\workspaceStorage"
}

Write-Log "Using storage root: $storageRoot"

if (-not (Test-Path $storageRoot)) {
  Write-Log "$(($Insiders) ? 'VS Code Insiders' : 'VS Code') workspace storage not found at: $storageRoot" -Level Error
  exit 1
}

# Build workspace hash -> friendly name lookup from workspace.json files
Write-Log "Building workspace name index..."
$workspaceNames = @{}
Get-ChildItem $storageRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
  $jsonPath = Join-Path $_.FullName "workspace.json"
  if (Test-Path $jsonPath) {
    try {
      $workspacePath = (Get-Content $jsonPath -Raw | ConvertFrom-Json).workspace
      $decoded = [System.Uri]::UnescapeDataString($workspacePath)
      $friendlyName = [System.IO.Path]::GetFileNameWithoutExtension($decoded.TrimEnd('/'))
      $workspaceNames[$_.Name] = $friendlyName
    }
    catch {
      # workspace.json exists but couldn't be parsed — skip silently
    }
  }
}
Write-Log "Found $($workspaceNames.Count) workspace mappings" -Level Success

# Parse all Copilot chat debug logs
Write-Log "Scanning Copilot debug logs..."
$allRequests = [System.Collections.Generic.List[PSCustomObject]]::new()

$logFiles = Get-ChildItem $storageRoot -Recurse -Filter "main.jsonl" -ErrorAction SilentlyContinue |
Where-Object { $_.FullName -like "*GitHub.copilot-chat*" }

Write-Log "Found $($logFiles.Count) debug log file(s)"

foreach ($logFile in $logFiles) {
  $storageHash = ($logFile.FullName -replace [regex]::Escape("$storageRoot\"), '').Split('\')[0]
  $workspaceName = if ($workspaceNames[$storageHash]) {
    $workspaceNames[$storageHash]
  }
  else {
    $storageHash.Substring(0, 8)
  }

  # Build session title lookup: prefer VS Code's auto-generated title from state.vscdb,
  # fall back to first user message text if the DB isn't available or the session isn't listed.
  $sessionTitles = @{}

  $stateDb = Join-Path $storageRoot $storageHash 'state.vscdb'
  if ((Get-Command sqlite3 -ErrorAction SilentlyContinue) -and (Test-Path $stateDb)) {
    try {
      $indexJson = sqlite3 $stateDb "SELECT value FROM ItemTable WHERE key = 'chat.ChatSessionStore.index'" 2>$null
      if ($indexJson) {
        $indexData = $indexJson | ConvertFrom-Json
        foreach ($prop in $indexData.entries.PSObject.Properties) {
          $sessionTitles[$prop.Name] = $prop.Value.title
        }
      }
    }
    catch {
      Write-Log -Level Warning -Message "Could not read state.vscdb for hash $storageHash - falling back to first user message"
    }
  }

  # For any session not found in the DB, fall back to the first user message text
  Get-Content $logFile.FullName | Where-Object { $_ -match '"type":"user_message"' } | ForEach-Object {
    try {
      $msgEntry = $_ | ConvertFrom-Json
      $sid = $msgEntry.sid
      if (-not $sessionTitles.ContainsKey($sid)) {
        $content = $msgEntry.attrs.content -replace '[\r\n]+', ' '
        $sessionTitles[$sid] = if ($content.Length -gt 55) {
          $content.Substring(0, 52) + '...' 
        }
        else {
          $content 
        }
      }
    }
    catch {
    }
  }

  $llmLines = Get-Content $logFile.FullName | Where-Object { $_ -match '"type":"llm_request"' }

  foreach ($line in $llmLines) {
    try {
      $entry = $line | ConvertFrom-Json
      $timestamp = [DateTimeOffset]::FromUnixTimeMilliseconds($entry.ts).LocalDateTime

      if ($Since -and $timestamp -lt $Since) {
        continue
      }

      $credits = Get-EstimatedCredits `
        -Model         $entry.attrs.model `
        -InputTokens   $entry.attrs.inputTokens `
        -OutputTokens  $entry.attrs.outputTokens `
        -CachedTokens  $entry.attrs.cachedTokens

      $sessionTitle = if ($sessionTitles[$entry.sid]) {
        $sessionTitles[$entry.sid] 
      }
      else {
        $entry.sid.Substring(0, 8) 
      }

      $allRequests.Add([PSCustomObject]@{
          Workspace    = $workspaceName
          SessionId    = $entry.sid
          SessionTitle = $sessionTitle
          Model        = $entry.attrs.model
          InputTokens  = $entry.attrs.inputTokens
          OutputTokens = $entry.attrs.outputTokens
          CachedTokens = $entry.attrs.cachedTokens
          Credits      = $credits
          Timestamp    = $timestamp
        })
    }
    catch {
      # Malformed JSON line — skip
    }
  }
}

if ($allRequests.Count -eq 0) {
  Write-Log "No LLM requests found. Is debug logging enabled in VS Code?" -Level Warning
  Write-Log 'Add to VS Code settings.json: "github.copilot.advanced": { "debug.overrideCapabilities": ["debug"] }' -Level Warning
  exit 0
}

Write-Log "Parsed $($allRequests.Count) total LLM request(s)" -Level Success

# Summarise by workspace then session
$summary = $allRequests | Group-Object Workspace | Sort-Object {
  ($_.Group | Measure-Object Credits -Sum).Sum
} -Descending | ForEach-Object {
  $workspaceGroup = $_
  $workspaceTotalCredits = ($workspaceGroup.Group | Where-Object { $null -ne $_.Credits } | Measure-Object Credits -Sum).Sum

  # Workspace-level row
  [PSCustomObject]@{
    Workspace    = $workspaceGroup.Name
    Session      = '(all sessions)'
    Requests     = $workspaceGroup.Count
    TotalInput   = ($workspaceGroup.Group | Measure-Object InputTokens  -Sum).Sum
    TotalOutput  = ($workspaceGroup.Group | Measure-Object OutputTokens -Sum).Sum
    TotalCached  = ($workspaceGroup.Group | Measure-Object CachedTokens -Sum).Sum
    Credits      = [math]::Round($workspaceTotalCredits, 2)
    'Cost (USD)' = "`$$([math]::Round($workspaceTotalCredits * 0.01, 4))"
    FirstSeen    = ($workspaceGroup.Group | Measure-Object Timestamp -Minimum).Minimum.ToString('yyyy-MM-dd HH:mm')
    LastSeen     = ($workspaceGroup.Group | Measure-Object Timestamp -Maximum).Maximum.ToString('yyyy-MM-dd HH:mm')
  }

  # Per-session rows, indented with a prefix
  $workspaceGroup.Group | Group-Object SessionId | Sort-Object {
    ($_.Group | Measure-Object Credits -Sum).Sum
  } -Descending | ForEach-Object {
    $sessionCredits = ($_.Group | Where-Object { $null -ne $_.Credits } | Measure-Object Credits -Sum).Sum
    $sessionTitle = ($_.Group | Select-Object -First 1).SessionTitle
    [PSCustomObject]@{
      Workspace    = ''
      Session      = "  $sessionTitle"
      Requests     = $_.Count
      TotalInput   = ($_.Group | Measure-Object InputTokens  -Sum).Sum
      TotalOutput  = ($_.Group | Measure-Object OutputTokens -Sum).Sum
      TotalCached  = ($_.Group | Measure-Object CachedTokens -Sum).Sum
      Credits      = [math]::Round($sessionCredits, 2)
      'Cost (USD)' = "`$$([math]::Round($sessionCredits * 0.01, 4))"
      FirstSeen    = ($_.Group | Measure-Object Timestamp -Minimum).Minimum.ToString('yyyy-MM-dd HH:mm')
      LastSeen     = ($_.Group | Measure-Object Timestamp -Maximum).Maximum.ToString('yyyy-MM-dd HH:mm')
    }
  }
}

# Output
Write-Host ""
$summary | Format-Table -AutoSize

$grandTotalCredits = ($summary | Where-Object { $_.Session -eq '(all sessions)' } | Measure-Object Credits  -Sum).Sum
$grandTotalRequests = ($summary | Where-Object { $_.Session -eq '(all sessions)' } | Measure-Object Requests -Sum).Sum
Write-Host "Total: $grandTotalRequests requests | $([math]::Round($grandTotalCredits, 2)) credits | `$$([math]::Round($grandTotalCredits * 0.01, 4)) USD" -ForegroundColor Cyan

if ($ExportCsv) {
  $summary | Export-Csv -Path $ExportCsv -NoTypeInformation
  Write-Log "Exported to $ExportCsv" -Level Success
}

#endregion
