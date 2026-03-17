<#
.SYNOPSIS
    Converts old GitHub Copilot chat session .json files to the current .jsonl event-log
    format so they appear in VS Code's chat history panel.

.DESCRIPTION
    At some point GitHub Copilot Chat changed its session storage format from a single
    flat .json file per session to an append-only .jsonl event log. Sessions saved in
    the old format are silently ignored by newer versions of VS Code and disappear from
    the chat history panel.

    This script converts each .json session file to the correct multi-line JSONL format:
      kind:0  — initial session shell (empty requests array)
      kind:1  — sets a scalar field (customTitle, lastMessageDate, ...)
      kind:2  — appends one request object to the requests array

    The converted .jsonl files are written to the destination folder (defaults to the
    same folder as the source files). The original .json files are left untouched.

.PARAMETER SourceFolder
    Folder containing the old .json session files.
    Usually: %APPDATA%\Code\User\workspaceStorage\<hash>\chatSessions

.PARAMETER DestinationFolder
    Folder to write the converted .jsonl files to.
    Defaults to SourceFolder (converts in-place alongside the originals).

.NOTES
    After converting, run Add-MissingSessionsToIndex.ps1 to register the new files
    in VS Code's state database so they appear in the chat panel.
    https://github.com/Paxilein/Scripts

.EXAMPLE
    # Convert sessions in the current workspace storage folder
    .\Convert-CopilotChatSessions.ps1 -SourceFolder "$env:APPDATA\Code\User\workspaceStorage\abc123def456\chatSessions"

    # Convert to a separate output folder
    .\Convert-CopilotChatSessions.ps1 -SourceFolder ".\old-sessions" -DestinationFolder ".\converted"
#>
param(
  [Parameter(Mandatory)]
  [string]$SourceFolder,

  [string]$DestinationFolder = $SourceFolder
)

$files = Get-ChildItem -Path $SourceFolder -Filter "*.json" -File
if (-not $files) {
  Write-Host "No .json files found in $SourceFolder"
  return
}

$converted = 0
$skipped = 0

foreach ($file in $files) {
  try {
    $old = Get-Content $file.FullName -Raw | ConvertFrom-Json

    $lines = [System.Collections.Generic.List[string]]::new()

    # Line 1 - kind:0: initial session shell with empty requests
    $init = [ordered]@{
      kind = 0
      v    = [ordered]@{
        version           = if ($old.version) {
          $old.version
        }
        else {
          3
        }
        creationDate      = $old.creationDate
        initialLocation   = if ($old.initialLocation) {
          $old.initialLocation
        }
        else {
          "panel"
        }
        responderUsername = if ($old.responderUsername) {
          $old.responderUsername
        }
        else {
          "GitHub Copilot"
        }
        sessionId         = $old.sessionId
        hasPendingEdits   = $false
        requests          = @()
        pendingRequests   = @()
        inputState        = [ordered]@{
          attachments = @()
          mode        = [ordered]@{ id = "agent"; kind = "agent" }
          inputText   = ""
          selections  = @()
          contrib     = [ordered]@{ chatDynamicVariableModel = @() }
        }
      }
    }
    $lines.Add(($init | ConvertTo-Json -Depth 50 -Compress))

    # kind:1 for customTitle if present
    if ($old.customTitle) {
      $lines.Add(([ordered]@{ kind = 1; k = @("customTitle"); v = $old.customTitle } | ConvertTo-Json -Depth 2 -Compress))
    }

    # kind:1 for lastMessageDate if present
    if ($old.lastMessageDate) {
      $lines.Add(([ordered]@{ kind = 1; k = @("lastMessageDate"); v = $old.lastMessageDate } | ConvertTo-Json -Depth 2 -Compress))
    }

    # kind:2 per request - append the full request object (already has response/result merged in old format)
    if ($old.requests) {
      foreach ($req in $old.requests) {
        $append = [ordered]@{ kind = 2; k = @("requests"); v = @($req) }
        $lines.Add(($append | ConvertTo-Json -Depth 50 -Compress))
      }
    }

    $outputPath = Join-Path $DestinationFolder "$($file.BaseName).jsonl"
    $lines | Set-Content $outputPath -Encoding UTF8NoBOM

    Write-Host "Converted: $($file.Name) -> $($file.BaseName).jsonl ($($lines.Count) lines, $($old.requests.Count) requests)"
    $converted++
  }
  catch {
    Write-Warning "Skipped $($file.Name): $_"
    $skipped++
  }
}

Write-Host "`nDone. Converted: $converted  Skipped: $skipped"
