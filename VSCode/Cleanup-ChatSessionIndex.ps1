<#
.SYNOPSIS
    Removes ghost entries from the chat.ChatSessionStore.index in state.vscdb for
    any workspace where the referenced JSONL file no longer exists in chatSessions.

.DESCRIPTION
    VS Code keeps a JSON index of chat sessions in state.vscdb. When session JSONL
    files are moved out of a workspace's chatSessions folder, stale index entries
    remain and appear in the list as blank/empty sessions.

    This script reads each workspace's index, drops entries without a matching file,
    and writes the cleaned index back.

    IMPORTANT: Close VS Code before running, or changes will be overwritten.

.PARAMETER WorkspaceHash
    One or more workspace storage hashes to clean. If omitted, cleans all workspaces
    that have a chatSessions folder.

.PARAMETER StoragePath
    VS Code workspaceStorage path. Auto-detected from $env:APPDATA when omitted.

.EXAMPLE
    .\Cleanup-ChatSessionIndex.ps1
    .\Cleanup-ChatSessionIndex.ps1 -WorkspaceHash "abc123"
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

  # Get valid GUIDs from JSONL files on disk
  $validGuids = Get-ChildItem $sessionsPath -Filter "*.jsonl" -ErrorAction SilentlyContinue |
  Select-Object -ExpandProperty BaseName

  # Read the current index from the DB
  $rawJson = sqlite3 $dbPath "SELECT value FROM ItemTable WHERE key = '$dbKey';"
  if (-not $rawJson) {
    Write-Host "[$hash] No index found — skipping"
    continue
  }

  $index = $rawJson | ConvertFrom-Json
  $before = ($index.entries.PSObject.Properties | Measure-Object).Count

  # Build a new entries object with only entries that have a JSONL file
  $newEntries = [PSCustomObject]@{}
  foreach ($prop in $index.entries.PSObject.Properties) {
    if ($prop.Name -in $validGuids) {
      $newEntries | Add-Member -MemberType NoteProperty -Name $prop.Name -Value $prop.Value
    }
  }

  $after = ($newEntries.PSObject.Properties | Measure-Object).Count
  $removed = $before - $after

  if ($removed -eq 0) {
    Write-Host "[$hash] Nothing to remove ($before entries, all valid)"
    continue
  }

  # Write back
  $index.entries = $newEntries
  $newJson = $index | ConvertTo-Json -Depth 10 -Compress

  # Escape single quotes for SQLite
  $escaped = $newJson -replace "'", "''"
  sqlite3 $dbPath "UPDATE ItemTable SET value = '$escaped' WHERE key = '$dbKey';"

  Write-Host "[$hash] Removed $removed ghost entries ($before → $after)"
}

Write-Host "`nDone."
