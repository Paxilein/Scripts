<#
.SYNOPSIS
    Registers chat session JSONL files that are missing from VS Code's chat history index
    so they appear in the chat panel.

.DESCRIPTION
    VS Code tracks chat sessions in a SQLite database (state.vscdb) via a JSON index
    stored under the key 'chat.ChatSessionStore.index'. When JSONL session files are
    placed in a workspace's chatSessions folder without VS Code creating them (e.g.
    after a manual copy, a workspace migration, or a conversion from the old .json
    format), they have no index entry and will not appear in the chat history panel.

    This script:
      1. Scans each workspace's chatSessions folder for .jsonl files
      2. Compares them against the current index entries
      3. Parses any missing files to extract title, timestamps, and metadata
      4. Inserts the missing entries into state.vscdb

    Run it with VS Code closed for a clean write, or open for a quick test (VS Code
    will overwrite the DB when it exits, so close and re-run for a permanent fix).

.REQUIREMENTS
    sqlite3.exe must be on your PATH.
    Install with: winget install SQLite.SQLite

.PARAMETER WorkspaceHash
    One or more 32-character workspace storage hashes to process.
    If omitted, all workspace folders that contain a chatSessions subfolder are processed.

.PARAMETER StoragePath
    Full path to VS Code's workspaceStorage folder.
    Defaults to: %APPDATA%\Code\User\workspaceStorage
    For VS Code Insiders, pass: "%APPDATA%\Code - Insiders\User\workspaceStorage"

.NOTES
    To find your workspace hash: in VS Code, open the Command Palette and run
    "Developer: Open Storage Folder" — the folder name in Explorer is the hash.

    This script is part of a toolkit for recovering and migrating VS Code Copilot
    chat sessions. https://github.com/Paxilein/Scripts
    Also see:
      Convert-CopilotChatSessions.ps1  — convert old .json sessions to .jsonl
      Cleanup-ChatSessionIndex.ps1     — remove ghost entries for deleted sessions

.EXAMPLE
    # Fix all workspaces automatically
    .\Add-MissingSessionsToIndex.ps1

    # Fix a specific workspace
    .\Add-MissingSessionsToIndex.ps1 -WorkspaceHash "6c3dc9e72d614dad23df7e35d1e7149c"

    # VS Code Insiders
    .\Add-MissingSessionsToIndex.ps1 -StoragePath "$env:APPDATA\Code - Insiders\User\workspaceStorage"
#>

param(
  [string[]]$WorkspaceHash,
  [string]$StoragePath = (Join-Path $env:APPDATA "Code\User\workspaceStorage")
)
if (-not (Get-Command sqlite3 -ErrorAction SilentlyContinue)) {
    Write-Error "sqlite3.exe not found. Install it with: winget install SQLite.SQLite`nThen restart your terminal and try again."
    exit 1
}
$storage = $StoragePath
$dbKey = "chat.ChatSessionStore.index"

function Read-SessionMetadata([string]$jsonlPath) {
  $meta = @{
    sessionId         = [System.IO.Path]::GetFileNameWithoutExtension($jsonlPath)
    title             = ""
    lastMessageDate   = 0
    creationDate      = 0
    initialLocation   = "panel"
    hasPendingEdits   = $false
    hasRequests       = $false
    lastResponseState = 1
    timingCreated     = 0
    timingLastStart   = 0
    timingLastEnd     = 0
  }

  try {
    foreach ($line in (Get-Content $jsonlPath)) {
      try {
        $obj = $line | ConvertFrom-Json -ErrorAction Stop

        # kind:0 — initial shell; grab creationDate, initialLocation, sessionId
        if ($obj.kind -eq 0 -and $obj.v) {
          if ($obj.v.creationDate) {
            $meta.creationDate = [long]$obj.v.creationDate 
          }
          if ($obj.v.initialLocation) {
            $meta.initialLocation = [string]$obj.v.initialLocation 
          }
          if ($obj.v.sessionId) {
            $meta.sessionId = [string]$obj.v.sessionId 
          }
        }

        # kind:1 — field set events
        if ($obj.kind -eq 1) {
          switch ($obj.k) {
            "customTitle" {
              if ($obj.v) {
                $meta.title = [string]$obj.v 
              } 
            }
            "lastMessageDate" {
              if ($obj.v) {
                $meta.lastMessageDate = [long]$obj.v 
              } 
            }
            "hasPendingEdits" {
              $meta.hasPendingEdits = [bool]$obj.v 
            }
            "initialLocation" {
              if ($obj.v) {
                $meta.initialLocation = [string]$obj.v 
              } 
            }
          }
        }

        # kind:2 — array append (requests)
        if ($obj.kind -eq 2 -and $obj.k -eq "requests" -and $obj.v) {
          $meta.hasRequests = $true
          $req = $obj.v
          # Grab timing if available
          if ($req.timestamp) {
            $meta.timingLastStart = [long]$req.timestamp 
          }
          if ($req.response -and $req.response.timings -and $req.response.timings.firstProgress) {
            $meta.timingLastEnd = [long]$req.response.timings.firstProgress
          }
          if ($meta.timingCreated -eq 0 -and $req.timestamp) {
            $meta.timingCreated = [long]$req.timestamp
          }
        }
      }
      catch {
      }
    }
  }
  catch {
  }

  # Fallbacks
  if ($meta.creationDate -eq 0) {
    $meta.creationDate = $meta.timingCreated 
  }
  if ($meta.timingCreated -eq 0) {
    $meta.timingCreated = $meta.creationDate 
  }
  if ($meta.lastMessageDate -eq 0 -and $meta.timingLastStart -gt 0) {
    $meta.lastMessageDate = $meta.timingLastStart
  }
  # Last resort: use file last-write time
  if ($meta.lastMessageDate -eq 0) {
    $meta.lastMessageDate = [long](([System.IO.File]::GetLastWriteTimeUtc($jsonlPath) `
          - [datetime]'1970-01-01').TotalMilliseconds)
  }
  if ($meta.timingCreated -eq 0) {
    $meta.timingCreated = $meta.lastMessageDate 
  }
  if ($meta.timingLastStart -eq 0) {
    $meta.timingLastStart = $meta.lastMessageDate 
  }
  if ($meta.timingLastEnd -eq 0) {
    $meta.timingLastEnd = $meta.lastMessageDate 
  }

  return $meta
}

if ($WorkspaceHash) {
  $hashes = $WorkspaceHash
}
else {
  $hashes = Get-ChildItem $storage -Directory | Where-Object {
    Test-Path (Join-Path $_.FullName "chatSessions")
  } | Select-Object -ExpandProperty Name
}

foreach ($hash in $hashes) {
  $wsPath = Join-Path $storage $hash
  $dbPath = Join-Path $wsPath "state.vscdb"
  $sessionsPath = Join-Path $wsPath "chatSessions"

  if (-not (Test-Path $dbPath)) {
    Write-Host "[$hash] No state.vscdb — skipping"
    continue
  }

  $jsonlFiles = Get-ChildItem $sessionsPath -Filter "*.jsonl" -ErrorAction SilentlyContinue
  if (-not $jsonlFiles) {
    Write-Host "[$hash] No JSONL files — skipping"
    continue
  }

  # Read or create the index
  $rawJson = sqlite3 $dbPath "SELECT value FROM ItemTable WHERE key = '$dbKey';"
  if ($rawJson) {
    $index = $rawJson | ConvertFrom-Json
    if (-not $index.entries) {
      $index | Add-Member -MemberType NoteProperty -Name "entries" -Value ([PSCustomObject]@{})
    }
  }
  else {
    $index = [PSCustomObject]@{
      version = 1
      entries = [PSCustomObject]@{}
    }
  }

  $existingGuids = $index.entries.PSObject.Properties.Name
  $missing = $jsonlFiles | Where-Object { $_.BaseName -notin $existingGuids }

  if (-not $missing) {
    Write-Host "[$hash] All $($jsonlFiles.Count) sessions already indexed"
    continue
  }

  $added = 0
  foreach ($file in $missing) {
    $m = Read-SessionMetadata $file.FullName

    $entry = [PSCustomObject]@{
      sessionId         = $m.sessionId
      title             = $m.title
      lastMessageDate   = $m.lastMessageDate
      timing            = [PSCustomObject]@{
        created            = $m.timingCreated
        lastRequestStarted = $m.timingLastStart
        lastRequestEnded   = $m.timingLastEnd
      }
      initialLocation   = $m.initialLocation
      hasPendingEdits   = $m.hasPendingEdits
      isEmpty           = (-not $m.hasRequests)
      isExternal        = $false
      lastResponseState = $m.lastResponseState
    }

    $index.entries | Add-Member -MemberType NoteProperty -Name $m.sessionId -Value $entry -Force
    $added++
  }

  # Write back
  $newJson = $index | ConvertTo-Json -Depth 10 -Compress
  $escaped = $newJson -replace "'", "''"

  $exists = sqlite3 $dbPath "SELECT COUNT(*) FROM ItemTable WHERE key = '$dbKey';"
  if ([int]$exists -gt 0) {
    sqlite3 $dbPath "UPDATE ItemTable SET value = '$escaped' WHERE key = '$dbKey';"
  }
  else {
    sqlite3 $dbPath "INSERT INTO ItemTable (key, value) VALUES ('$dbKey', '$escaped');"
  }

  Write-Host "[$hash] Added $added missing entries (total now: $(($index.entries.PSObject.Properties | Measure-Object).Count))"
}

Write-Host "`nDone."
