<#
.SYNOPSIS
    Patches the GitHub Copilot Chat extension to skip expired GitHub attachment URLs
    in conversation history, preventing "vision_attachment_not_accessible" /
    "attachment not found" 400 errors when resuming old sessions that had images.

.DESCRIPTION
    When a Copilot chat session contains images, VS Code stores the temporary GitHub
    attachment URL (https://github.com/github-copilot/chat/attachments/{uuid}) in the
    session JSONL. These URLs expire on GitHub's servers. When the session is resumed
    and a new message is sent, the extension includes the expired URL in the API
    request body. GitHub's backend returns HTTP 400 ("vision_attachment_not_accessible"
    or "attachment not found") which kills the entire request.

    This script patches the relevant extension.js to skip expired GitHub attachment
    URLs before they are included in the API request. The fix is equivalent to this
    TypeScript change in agentPrompt.tsx:

        } else if (part.type === Raw.ChatCompletionContentPartKind.Image) {
    +       if (part.imageUrl.url.startsWith('https://github.com/github-copilot/chat/attachments/')) {
    +           return undefined;
    +       }
            return <HistoricalImage src={part.imageUrl.url} ... />;

    The minified variable names in extension.js change with each VS Code update, so
    this script uses a regex to find the pattern regardless of variable names.

    Run this script after each VS Code update if the error reappears.

.PARAMETER ExtensionJsPath
    Optional. Full path to the extension.js to patch. If not specified, the script
    auto-detects the current VS Code installation.

.NOTES
    The patch is overwritten whenever the Copilot extension updates. Re-run the
    script after updates if the error returns.

    Source fix: c:\GIT\vscode\extensions\copilot\src\extension\prompts\node\agent\agentPrompt.tsx
    GitHub issue: https://github.com/microsoft/vscode/issues (pending)

.EXAMPLE
    .\Patch-CopilotExtension.ps1

.EXAMPLE
    .\Patch-CopilotExtension.ps1 -ExtensionJsPath "C:\Users\Me\.vscode\extensions\github.copilot-chat-0.50.0\dist\extension.js"
#>
param(
  [string]$ExtensionJsPath
)

#region --- Write-Log snippet ---
function Write-Log {
  param(
    [Parameter(Mandatory)][string]$Message,
    [ValidateSet('Info', 'Warning', 'Error', 'Success')][string]$Level = 'Info'
  )
  $colour = @{ Info = 'Cyan'; Warning = 'Yellow'; Error = 'Red'; Success = 'Green' }[$Level]
  $prefix = @{ Info = 'INFO'; Warning = 'WARN'; Error = 'ERRO'; Success = 'DONE' }[$Level]
  Write-Host "[$prefix] $Message" -ForegroundColor $colour
}
#endregion

# Regex that matches the vulnerable one-liner regardless of minified variable names.
# Captures the full statement so we can wrap it with the guard.
# Pattern: if(t.type==={ns}.Raw.ChatCompletionContentPartKind.Image)return vscpp({var},{src:t.imageUrl.url,...})
$vulnerablePattern = [regex]'(if\(t\.type===\w+\.Raw\.ChatCompletionContentPartKind\.Image\)return vscpp\(\w+,\{src:t\.imageUrl\.url,detail:t\.imageUrl\.detail,mimeType:t\.imageUrl\.mediaType\}\))'

$githubAttachmentPrefix = 'https://github.com/github-copilot/chat/attachments/'

function Find-ExtensionJs {
  Write-Log "Auto-detecting VS Code installation..."

  $candidates = @()

  # Built-in extension in VS Code install dir
  $vscodeBase = "C:\Users\$env:USERNAME\AppData\Local\Programs\Microsoft VS Code"
  if (Test-Path $vscodeBase) {
    Get-ChildItem $vscodeBase -Directory | Where-Object { $_.Name -ne 'bin' } | ForEach-Object {
      $path = Join-Path $_.FullName "resources\app\extensions\copilot\dist\extension.js"
      if (Test-Path $path) {
        $candidates += $path
      }
    }
  }

  # User-installed copilot-chat extension
  $userExtBase = "C:\Users\$env:USERNAME\.vscode\extensions"
  if (Test-Path $userExtBase) {
    Get-ChildItem $userExtBase -Directory | Where-Object { $_.Name -like "github.copilot-chat*" } | ForEach-Object {
      $path = Join-Path $_.FullName "dist\extension.js"
      if (Test-Path $path) {
        $candidates += $path
      }
    }
  }

  if ($candidates.Count -eq 0) {
    Write-Log "Could not find any extension.js. Use -ExtensionJsPath to specify the path." Error
    exit 1
  }

  # Return the newest one by last-write time
  return ($candidates | ForEach-Object { Get-Item $_ } | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
}

# --- Locate the target file ---
if (-not $ExtensionJsPath) {
  $ExtensionJsPath = Find-ExtensionJs
}

if (-not (Test-Path $ExtensionJsPath)) {
  Write-Log "File not found: $ExtensionJsPath" Error
  exit 1
}

Write-Log "Target: $ExtensionJsPath"
Write-Log "Reading file ($([Math]::Round((Get-Item $ExtensionJsPath).Length / 1MB, 1)) MB)..."
$content = [System.IO.File]::ReadAllText($ExtensionJsPath)

# --- Check if already patched ---
if ($content.Contains($githubAttachmentPrefix)) {
  Write-Log "File is already patched — '$githubAttachmentPrefix' guard is present." Success
  exit 0
}

# --- Find the vulnerable pattern ---
$match = $vulnerablePattern.Match($content)
if (-not $match.Success) {
  Write-Log "Vulnerable pattern not found in $ExtensionJsPath" Warning
  Write-Log "The extension may have been restructured. Manual inspection required." Warning
  exit 1
}

$matchCount = $vulnerablePattern.Matches($content).Count
if ($matchCount -ne 1) {
  Write-Log "Expected 1 match but found $matchCount — aborting to avoid unintended changes." Error
  exit 1
}

Write-Log "Found vulnerable pattern at index $($match.Index): $($match.Value.Substring(0, 80))..."

# --- Build the patched replacement ---
# Wrap the original one-liner with a guard that skips expired GitHub attachment URLs.
$originalStatement = $match.Value

# Reconstruct by wrapping the original one-liner:
# Original: if(t.type===X.Raw...Image)return vscpp(Y,{src:t.imageUrl.url,...})
# Patched:  if(t.type===X.Raw...Image){if(t.imageUrl.url.startsWith("..."))return;return vscpp(Y,{src:t.imageUrl.url,...})}
$patched = $originalStatement `
  -replace '^(if\(t\.type===\w+\.Raw\.ChatCompletionContentPartKind\.Image\))(return vscpp\(.+\))$', `
('$1{if(t.imageUrl.url.startsWith("' + $githubAttachmentPrefix + '"))return;$2}')

if ($patched -eq $originalStatement) {
  Write-Log "Replacement regex did not match — unexpected string format. Aborting." Error
  Write-Log "Original: $originalStatement" Error
  exit 1
}

# --- Back up and write ---
$backupPath = "$ExtensionJsPath.bak"
Write-Log "Creating backup: $backupPath"
Copy-Item $ExtensionJsPath $backupPath -Force

Write-Log "Applying patch..."
$newContent = $content.Replace($originalStatement, $patched)
[System.IO.File]::WriteAllText($ExtensionJsPath, $newContent, [System.Text.Encoding]::UTF8)

# --- Verify ---
$verify = [System.IO.File]::ReadAllText($ExtensionJsPath)
$oldRemaining = $vulnerablePattern.Matches($verify).Count
$newPresent = $verify.Contains($githubAttachmentPrefix)

if ($oldRemaining -eq 0 -and $newPresent) {
  Write-Log "Patch applied successfully. File size: $((Get-Item $ExtensionJsPath).Length) bytes" Success
  Write-Log "Reload VS Code window (Ctrl+Shift+P > Developer: Reload Window) to apply." Info
}
else {
  Write-Log "Verification failed (old remaining: $oldRemaining, new present: $newPresent) — restoring backup." Error
  Copy-Item $backupPath $ExtensionJsPath -Force
  exit 1
}
