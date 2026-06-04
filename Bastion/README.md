# Bastion

> Part of [Paxilein/Scripts](https://github.com/Paxilein/Scripts)

Connect to Azure VMs via Bastion tunnel with YubiKey SSH authentication, using named host aliases - like PuTTY sessions but for Bastion.

---

## Scripts

### `New-YubiSSHConfig.ps1`

Interactively creates or updates a `~/.yubissh/<client>.json` config file. Uses Azure CLI to let you pick subscriptions, VMs, and Bastions from lists rather than typing resource IDs manually.

```powershell
# Fully interactive
.\New-YubiSSHConfig.ps1

# Pre-fill the client name
.\New-YubiSSHConfig.ps1 -ClientName "Acme Corp"
```

**Flow:**

1. Client name + Tenant ID
2. Log in to the tenant via `az login`
3. Pick the VM subscription from your subscription list
4. Search VMs by partial name → pick from matches
5. Pick the Bastion subscription (can differ - hub/spoke supported)
6. Auto-discover Bastions in that subscription → pick if multiple
7. SSH username + optional port/key overrides
8. Loop to add more hosts, then write the JSON

---

### `Connect-YubiSSH.ps1`

Looks up a host alias in `~/.yubissh/*.json`, establishes an Azure Bastion tunnel, and drops you into an SSH session. Cleans up the tunnel automatically when you exit.

**Requirements:**

- Azure CLI: `winget install Microsoft.AzureCLI`
- Azure Bastion **Standard tier** on the target bastion (native client/tunnel support)
- OpenSSH 8.2+
- A YubiKey-backed SSH key (see [../Yubikey/](../Yubikey/README.md)) or any standard SSH key

---

## Config Files

Create one JSON file per client in `~/.yubissh/`. The script scans all `*.json` files in that directory to resolve aliases.

```json
{
  "client": "Acme Corp",
  "tenant": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
  "hosts": [
    {
      "alias": "acme-web-01",
      "user": "adminuser",
      "vmName": "vm-web-01",
      "vmResourceGroup": "rg-prod-compute",
      "vmSubscription": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
      "bastionName": "bas-hub-prod",
      "bastionResourceGroup": "rg-hub-network",
      "bastionSubscription": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
    },
    {
      "alias": "acme-db-01",
      "user": "adminuser",
      "vmName": "vm-db-01",
      "vmResourceGroup": "rg-prod-data",
      "vmSubscription": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
      "bastionName": "bas-hub-prod",
      "bastionResourceGroup": "rg-hub-network",
      "bastionSubscription": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
      "sshPort": 22,
      "sshKey": "C:\\Users\\you\\.ssh\\id_ed25519_sk"
    }
  ]
}
```

**Fields:**

| Field                          | Required | Default                | Description                                                |
| ------------------------------ | -------- | ---------------------- | ---------------------------------------------------------- |
| `client`                       | Yes      | -                      | Display name for the client (shown in host list)           |
| `tenant`                       | Yes      | -                      | Azure tenant ID for this client                            |
| `hosts[].alias`                | Yes      | -                      | Short name used to connect (`Connect-YubiSSH.ps1 <alias>`) |
| `hosts[].user`                 | Yes      | -                      | SSH username on the VM                                     |
| `hosts[].vmName`               | Yes      | -                      | Azure VM name                                              |
| `hosts[].vmResourceGroup`      | Yes      | -                      | Resource group containing the VM                           |
| `hosts[].vmSubscription`       | Yes      | -                      | Subscription ID containing the VM                          |
| `hosts[].bastionName`          | Yes      | -                      | Azure Bastion resource name (in hub)                       |
| `hosts[].bastionResourceGroup` | Yes      | -                      | Resource group containing the Bastion                      |
| `hosts[].bastionSubscription`  | Yes      | -                      | Subscription ID containing the Bastion                     |
| `hosts[].sshPort`              | No       | `22`                   | SSH port on the VM                                         |
| `hosts[].sshKey`               | No       | `~/.ssh/id_ed25519_sk` | Path to SSH identity file                                  |

> The VM and Bastion can be in different subscriptions (hub/spoke topology is fully supported).

---

## Usage

```powershell
# List all known hosts across all config files
.\Connect-YubiSSH.ps1

# Connect to a host
.\Connect-YubiSSH.ps1 acme-web-01

# Connect with a username override
.\Connect-YubiSSH.ps1 acme-web-01 -User pax

# Connect with a specific key
.\Connect-YubiSSH.ps1 acme-web-01 -SSHKey ~/.ssh/id_rsa
```

**What happens when you connect:**

1. Scans `~/.yubissh/*.json` for the alias
2. Checks Azure CLI is logged into the right tenant (prompts if not)
3. Finds a free local port
4. Starts `az network bastion tunnel` in the background
5. Waits for the tunnel to be ready
6. SSHs to `localhost:<port>` - touch your YubiKey when it flashes
7. When you exit the SSH session, the tunnel is automatically killed

---

## Notes

- **Host key checking is disabled** for tunnel connections. Since the connection is always `localhost:<random-port>`, storing host keys is not useful. Security is provided by Azure authentication (to establish the tunnel) and your SSH key/YubiKey (to authenticate to the VM).
- If the alias exists in multiple config files, the first match is used with a warning.
- Tunnel logs are written to `%TEMP%\yubissh_<port>.log` during the session and cleaned up on exit.
