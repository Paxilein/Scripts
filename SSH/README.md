# SSH

> Part of [Paxilein/Scripts](https://github.com/Paxilein/Scripts)

PowerShell scripts for SSH configuration and key management.

---

## Scripts

### `Convert-PuTTYSessionsToSSHConfig.ps1`

Reads all PuTTY saved sessions from the Windows registry and generates equivalent `Host` blocks for `~/.ssh/config`.

**When to use:** You have PuTTY sessions you want to migrate to OpenSSH so you can use `ssh <alias>` from PowerShell, Windows Terminal, or VS Code Remote SSH.

**Requirements:** None (pure PowerShell).

**Notes:**

- Sessions named `Default Settings` are skipped
- Sessions with no `HostName` configured are skipped
- PuTTY `.ppk` key files are **not compatible with OpenSSH** - if a session references one, the `IdentityFile` line is commented out with a warning. Convert the key first:
  ```powershell
  ssh-keygen -p -N "" -m pem -f <key.ppk>
  ```
  Or use `puttygen` to export as OpenSSH format.

```powershell
# Preview what would be generated without writing anything
.\Convert-PuTTYSessionsToSSHConfig.ps1 -WhatIf

# Write to ~/.ssh/config (backs up any existing config first)
.\Convert-PuTTYSessionsToSSHConfig.ps1

# Write to a custom path
.\Convert-PuTTYSessionsToSSHConfig.ps1 -OutputPath C:\Temp\ssh_config_preview.txt

# Append to existing config instead of replacing it
.\Convert-PuTTYSessionsToSSHConfig.ps1 -Append
```

**Parameters:**

| Parameter     | Default         | Description                                    |
| ------------- | --------------- | ---------------------------------------------- |
| `-OutputPath` | `~/.ssh/config` | Path to write the SSH config to                |
| `-Append`     | `$false`        | Append to existing config instead of replacing |
| `-WhatIf`     | -               | Preview output without writing any files       |
