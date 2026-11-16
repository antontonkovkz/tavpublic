# agent-remote: remote command execution

[Русский](README.md)

Two independent transports are available:

- **Windows without Chisel:** HTTPS polling, a persistent job queue, separate
  PowerShell processes, configurable concurrency. See the complete
  [Windows HTTPS installation guide](HTTPS_TRANSPORT.en.md).
- **SSH through Chisel:** a reverse tunnel from Ubuntu or Windows to a Linux AI
  server. This page describes that transport. Use `scripts/ai_client.sh` for SSH
  clients; HTTPS clients use `https_remote.py` instead.

## SSH architecture and installed components

The Linux server runs Chisel on a custom TCP port. Clients connect outbound and
forward their local sshd to `127.0.0.1:<reverse-port>` on the server. The reverse
listener is not publicly exposed. Chisel encrypts transport traffic using SSH.

The server installer creates `/usr/local/bin/chisel`, `/etc/chisel/server_key.pem`,
`/etc/chisel/users.json`, `chisel-server.service`, and the AI SSH key pair
`/root/.ssh/ai_chisel_ed25519` / `.pub`. Project helpers manage installation,
inventory (`inventory/clients.tsv`) and host keys (`inventory/known_hosts`).

Ubuntu clients get openssh-server, `/usr/local/bin/chisel`,
`/etc/chisel/client.env`, and `chisel-client.service`.

## Install the Linux AI server

```bash
sudo CHISEL_PORT=9312 bash scripts/install_ai_server.sh
```

The installer downloads Chisel, generates its server key and the AI SSH key pair,
starts the service, and attempts to open CHISEL_PORT/tcp in ufw or firewalld.
Provider/cloud firewall rules must be configured separately. Save the printed
Auth and Fingerprint values: clients need them. Do not publish credentials.

## Prepare and install an Ubuntu client

On the server:

```bash
scripts/prepare_client_bootstrap.sh \
  --client-name client-1 \
  --ssh-user ubuntu \
  --server-host your-ai-server.example.com
```

This infers the server port, authentication and fingerprint from the local server
installation, chooses an unused reverse port in 2200–2299, and prints installation
and inventory commands. Run the installation command on the client, then run the
printed `ai_client.sh add` command on the server.

The client installer adds the AI public key to the selected user's authorized_keys,
configures the tunnel, and enables its service. The user must already exist.

```bash
scripts/ai_client.sh add client-1 2201 ubuntu demo "Ubuntu test box"
scripts/ai_client.sh check client-1
scripts/ai_client.sh run client-1 -- sh -lc 'whoami && hostname'
```

Optional preparation parameters:

```bash
scripts/prepare_client_bootstrap.sh \
  --client-name client-2 --ssh-user root \
  --server-host 203.0.113.10 \
  --port-start 2300 --port-end 2399 \
  --tags demo --description "Second test node"
```

To specify all connection details manually:

```bash
scripts/generate_client_install_command.sh \
  --server-host your-ai-server.example.com --server-port 9312 \
  --auth 'ai:replace-with-strong-secret' --fingerprint 'SERVER_FINGERPRINT' \
  --reverse-port 2201 --ssh-user ubuntu
```

The generated curl-based Ubuntu installation command requires hosting
install_ubuntu_client.sh at an accessible URL. Set `--client-script-url` or
CLIENT_SCRIPT_URL accordingly. Chisel can also sit behind nginx/Caddy on 443/TCP.

## SSH helper commands

```bash
scripts/ai_client.sh list
scripts/ai_client.sh show client-1
scripts/ai_client.sh check
scripts/ai_client.sh check client-1
scripts/ai_client.sh run client-1 -- sh -lc 'whoami && pwd'
scripts/ai_client.sh ssh client-1
```

Use interactive SSH only when needed. The helper reads inventory and uses the AI
private key by default. Never assume all clients have the same user or port.
Inspect identity, hostname, working directory and service state before changing
systems; prefer idempotent operations. See AGENT_INSTRUCTIONS.md for agent rules.

Inventory uses tab-separated fields:

```text
name<TAB>port<TAB>ssh_user<TAB>tags<TAB>description[<TAB>os]
```

The optional OS is linux or windows. Five-column records default to Linux.

## Windows through SSH/Chisel

Prepare on the Linux server:

```bash
scripts/prepare_client_bootstrap.sh --os windows --client-name win-1 \
  --ssh-user ATonkov --server-host ai.example.com
```

Run the generated installer command in elevated PowerShell from a Windows copy
of the project. It configures OpenSSH and the SYSTEM startup task AgentRemoteTunnel
with retries and no console. Files and credentials are under
`C:\ProgramData\agent-remote`, restricted to SYSTEM and Administrators.

For a non-admin local account, sign in once to create its profile. For a domain
account, run elevated as that same account. SSH privileges follow the selected
account. Existing sshd configuration is preserved; custom authentication rules may
need adjustment. Installation requires administrator rights and Internet access.
Restrict direct SSH access through listener/firewall rules if only the tunnel is needed.

```bash
scripts/ai_client.sh add win-1 2201 ATonkov demo "Windows PC" windows
scripts/ai_client.sh check win-1
scripts/ai_client.sh ps win-1 'Get-Location; hostname; whoami'
```

The ps command requires iconv and base64 on the server and uses EncodedCommand.
Use explicit exit codes for native executable failures. Do not send sh, uname,
or systemctl commands to Windows. Desktop automation is not included; further
child applications must also obey hidden execution requirements.

## SSH diagnostics

Server:

```bash
systemctl status chisel-server --no-pager
scripts/ai_client.sh check client-1
ssh -i /root/.ssh/ai_chisel_ed25519 -p 2201 ubuntu@127.0.0.1
```

Ubuntu client:

```bash
systemctl status chisel-client --no-pager
systemctl status ssh --no-pager
getent passwd ubuntu
sudo ls -ld /home/ubuntu /home/ubuntu/.ssh
sudo ls -l /home/ubuntu/.ssh/authorized_keys
```

If the tunnel is up but SSH fails, verify the user exists, the AI public key is
installed, and authorized_keys ownership/permissions are correct.

Windows: inspect `Get-ScheduledTaskInfo AgentRemoteTunnel`, `Get-Service sshd`,
and `C:\ProgramData\agent-remote\tunnel.log`. The log is written when Chisel exits.
The elevated `scripts/diagnose_windows_client.ps1` produces a diagnostic report.
To remove the tunnel task while preserving SSH and keys:

```powershell
Stop-ScheduledTask AgentRemoteTunnel
Unregister-ScheduledTask AgentRemoteTunnel -Confirm:$false
```
