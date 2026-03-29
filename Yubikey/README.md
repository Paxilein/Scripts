# YubiKey

> Part of [Paxilein/Scripts](https://github.com/Paxilein/Scripts)

PowerShell scripts for YubiKey setup and configuration.

---

## Scripts

### `Initialize-YubiKeySSH.ps1`

Generates a hardware-backed `ed25519-sk` SSH key using your YubiKey, then wires it into your `~/.ssh/config` by adding an `IdentityFile` line to the specified hosts (or all hosts).

The private key file on disk is effectively just a credential handle - the actual private key never leaves the YubiKey hardware. SSH connections require a physical touch on the key to authenticate.

**When to use:** You want touch-to-authenticate SSH logins backed by your YubiKey instead of a software key file.

**Requirements:**

- OpenSSH 8.2+ (ships with Windows 10 1903+, verify with `ssh -V`)
- YubiKey 5 series (FIDO2 support required)
- YubiKey Manager CLI (`ykman`) - optional but recommended for reliable key detection:
  ```powershell
  winget install Yubico.YubiKeyManager
  ```
- FIDO2 applet on the YubiKey must not be locked. If it is, reset it first:
  ```powershell
  ykman fido reset
  ```

```powershell
# Full setup - generate key and wire up ALL hosts in ~/.ssh/config
.\Initialize-YubiKeySSH.ps1

# Wire up specific hosts only
.\Initialize-YubiKeySSH.ps1 -Hosts "web-server", "bastion"

# Generate key only, update config manually later
.\Initialize-YubiKeySSH.ps1 -SkipConfigUpdate

# Preview config changes without writing anything
.\Initialize-YubiKeySSH.ps1 -WhatIf
```

**Parameters:**

| Parameter           | Default                 | Description                                           |
| ------------------- | ----------------------- | ----------------------------------------------------- |
| `-KeyPath`          | `~/.ssh/id_ed25519_sk`  | Path for the generated key pair                       |
| `-KeyComment`       | `$env:USERNAME@yubikey` | Comment embedded in the public key                    |
| `-Hosts`            | _(all hosts)_           | One or more SSH config Host aliases to add the key to |
| `-SSHConfigPath`    | `~/.ssh/config`         | Path to your SSH config file                          |
| `-SkipConfigUpdate` | `$false`                | Generate key only, skip config changes                |
| `-WhatIf`           | -                       | Preview all actions without writing any files         |

**After running:**

1. Copy the public key printed to the console into `~/.ssh/authorized_keys` on each server
2. Connect with `ssh <host-alias>` and touch the YubiKey when it flashes
