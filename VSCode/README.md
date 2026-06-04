# VS Code Copilot Chat Session Tools

> Part of [Paxilein/Scripts](https://github.com/Paxilein/Scripts)

PowerShell scripts for recovering and managing GitHub Copilot Chat history in VS Code.

## The Problem

GitHub Copilot Chat changed its session storage format at some point — from a single flat `.json` file per session to an append-only `.jsonl` event log. Sessions saved in the old format are silently ignored by newer VS Code versions and **disappear from the chat history panel**.

Additionally, if you manually copy session files between workspaces (e.g. to organise them per-project), VS Code won't know about them and they won't show up either — because the session list is driven by an index in a SQLite database, not by the files directly.

These scripts fix both problems.

---

## Scripts

### `Get-CopilotTokenUsage.ps1`

Scans all VS Code workspace debug logs and reports GitHub Copilot token consumption and estimated credit costs, broken down by workspace and chat session.

**When to use:** You want visibility into how many Copilot credits you're burning, which workspaces are the most expensive, and which sessions are driving the cost.

**Requirements:**
- Debug logging must be enabled in VS Code settings:
  ```json
  "github.copilot.advanced": { "debug.overrideCapabilities": ["debug"] }
  ```
- `sqlite3.exe` on your PATH for session title resolution (optional but recommended):
  ```powershell
  winget install SQLite.SQLite
  ```

```powershell
# Show all usage, sorted by credits (default)
.\Get-CopilotTokenUsage.ps1

# Sort by workspace name
.\Get-CopilotTokenUsage.ps1 -SortBy Workspace

# Only show usage since a specific date
.\Get-CopilotTokenUsage.ps1 -Since (Get-Date).AddDays(-7)

# Export to CSV
.\Get-CopilotTokenUsage.ps1 -ExportCsv .\copilot-usage.csv

# VS Code Insiders
.\Get-CopilotTokenUsage.ps1 -Insiders
```

**Output columns:** Workspace, Session, Requests, TotalInput, TotalOutput, TotalCached, Credits, Cost (USD), FirstSeen, LastSeen.

**Notes:**
- Credits are calculated per request using the model's specific rate, then aggregated — so mixed-model sessions are costed correctly.
- Session titles are resolved from VS Code's `state.vscdb` (the display name shown in the chat panel). Falls back to the first user message text if the session has been deleted or `sqlite3` is unavailable.
- Only logs captured after enabling debug mode are included. Historical usage before that point is not available.
- Credit rates are based on the GitHub Copilot pricing model as of June 2026.

---

### `Convert-CopilotChatSessions.ps1`

Converts old `.json` session files to the current `.jsonl` event-log format.

**When to use:** Your chat history disappeared after a VS Code update and you have old `.json` files in your `chatSessions` folder.

**Requirements:** None (pure PowerShell).

```powershell
# Convert all sessions in a workspace storage folder
.\Convert-CopilotChatSessions.ps1 `
    -SourceFolder "$env:APPDATA\Code\User\workspaceStorage\<hash>\chatSessions"

# Convert to a separate output folder
.\Convert-CopilotChatSessions.ps1 `
    -SourceFolder ".\old-sessions" `
    -DestinationFolder ".\converted"
```

After converting, run `Add-MissingSessionsToIndex.ps1` to register the new files.

---

### `Add-MissingSessionsToIndex.ps1`

Registers `.jsonl` session files that exist on disk but are missing from VS Code's chat history index, so they appear in the chat panel.

**When to use:**

- After running `Convert-CopilotChatSessions.ps1`
- After manually copying session files into a workspace's `chatSessions` folder
- Sessions are on disk but don't show in VS Code's chat history

**Requirements:** `sqlite3.exe` on your PATH.

```powershell
winget install SQLite.SQLite
# Restart your terminal after installing
```

```powershell
# Fix all workspaces automatically (recommended)
.\Add-MissingSessionsToIndex.ps1

# Fix a specific workspace
.\Add-MissingSessionsToIndex.ps1 -WorkspaceHash "6c3dc9e72d614dad23df7e35d1e7149c"

# VS Code Insiders
.\Add-MissingSessionsToIndex.ps1 `
    -StoragePath "$env:APPDATA\Code - Insiders\User\workspaceStorage"
```

> **Tip:** To find your workspace hash, run **Developer: Open Storage Folder** from VS Code's Command Palette — the folder name is the hash.

---

### `Cleanup-ChatSessionIndex.ps1`

Removes ghost index entries that point to session files which no longer exist, so blank/empty entries stop appearing in the chat history list.

**When to use:** The chat history panel shows sessions that open blank or show no content.

**Requirements:** `sqlite3.exe` on your PATH (see above).

```powershell
# Clean all workspaces
.\Cleanup-ChatSessionIndex.ps1

# Clean a specific workspace
.\Cleanup-ChatSessionIndex.ps1 -WorkspaceHash "6c3dc9e72d614dad23df7e35d1e7149c"
```

---

## Typical Recovery Workflow

```
1. Find your chatSessions folder:
   %APPDATA%\Code\User\workspaceStorage\<hash>\chatSessions

2. If you have old .json files:
   .\Convert-CopilotChatSessions.ps1 -SourceFolder "<path>\chatSessions"

3. Register all sessions with VS Code (close VS Code first for a clean write):
   .\Add-MissingSessionsToIndex.ps1

4. If you still see blank ghost entries in the list:
   .\Cleanup-ChatSessionIndex.ps1

5. Restart VS Code — your sessions should appear.
```

---

## Notes

- All scripts default to `%APPDATA%\Code\User\workspaceStorage`. Use `-StoragePath` for VS Code Insiders or a non-standard install location.
- Scripts are safe to re-run — they skip entries that already exist.
- Original `.json` files are never modified or deleted by the conversion script.

## License

MIT — see [LICENSE](LICENSE).
