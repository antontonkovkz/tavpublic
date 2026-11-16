# Windows without Chisel: installation and operation

[Русский](HTTPS_TRANSPORT.md)

## Architecture

https_remote.py includes the SQLite queue server, Windows client and operator CLI.
Python 3.10+ is required. Windows polls HTTPS about once per second; no SSH,
Chisel or inbound PC ports are required. Each command runs in a separate hidden
PowerShell process. Screen and mouse control are not provided.

## Linux server installation

Run as root. The current deployment uses `/tavdata/agent-remote`.

```bash
cd /tavdata/agent-remote
git pull
python3 --version
install -d -m 700 /etc/agent-remote-https
install -d -m 755 /var/lib/agent-remote-https
python3 https_remote.py token
python3 https_remote.py token
```

Generate two different secrets for operator and client. Create
`/etc/agent-remote-https/server.json`:

```json
{
  "port": 9320,
  "database": "/var/lib/agent-remote-https/jobs.db",
  "admin_token": "REPLACE_WITH_ADMIN_TOKEN",
  "clients": {"windows-1": "REPLACE_WITH_CLIENT_TOKEN"}
}
```

Create `/etc/agent-remote-https/operator.json`:

```json
{"url":"http://127.0.0.1:9320", "token":"REPLACE_WITH_ADMIN_TOKEN"}
```

Use the same admin_token in operator.json. All tokens must be unique and at least
32 characters. Never give the operator token to clients. For another PC add its
name and separate token under clients, then restart the server. clients.tsv belongs
to the SSH transport.

```bash
chmod 600 /etc/agent-remote-https/*.json
```

Create `/etc/systemd/system/agent-remote-https.service`:

```ini
[Unit]
Description=Agent Remote HTTPS queue
After=network.target
[Service]
DynamicUser=yes
StateDirectory=agent-remote-https
LoadCredential=server.json:/etc/agent-remote-https/server.json
ExecStart=/usr/bin/python3 /tavdata/agent-remote/https_remote.py serve --config %d/server.json
Restart=on-failure
RestartSec=5
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
[Install]
WantedBy=multi-user.target
```

Requires systemd with LoadCredential support, available on the deployed Ubuntu.
The dynamic user must be able to read the code; StateDirectory provides database
write access. The API does not require root and binds only to loopback. Do not
expose port 9320 publicly.

```bash
systemctl daemon-reload
systemctl enable --now agent-remote-https
systemctl status agent-remote-https --no-pager
```

## HTTPS and Caddy

A DNS name and valid certificate are required. A dedicated site can use
`reverse_proxy 127.0.0.1:9320`. The current deployment adds the following inside
the edge.tavhome.online block, before its fallback handle:

```caddy
handle_path /agent-remote/* {
    reverse_proxy 127.0.0.1:9320
}
```

handle_path strips the prefix. Client URL: `https://edge.tavhome.online/agent-remote`.
Back up Caddyfile before editing, then run:

```bash
caddy validate --config /etc/caddy/Caddyfile
systemctl reload caddy
curl -i -X POST https://edge.tavhome.online/agent-remote/poll -d '{}'
```

Without a token, expect 401. A 502 means the backend is unavailable. Remote API
connections require HTTPS; HTTP is allowed only on loopback for the local operator.

## Windows preparation

Clone the project to `C:\my_data\remote\agent-remote`. Install Python 3.10+.
SYSTEM mode requires Python installed for all users. Current-user mode can use
Python installed in the user's profile.

```powershell
cd C:\my_data\remote\agent-remote
python --version
python -m pip install truststore
(Get-Command pythonw.exe).Source
```

truststore automatically uses the Windows certificate store while keeping TLS
verification enabled. Install it in the Python used by the task. pythonw hides
the client console; PowerShell and taskkill use CREATE_NO_WINDOW. Applications
launched by remote scripts must control their own windows. Endpoint protection
is not disabled and no exclusions are created.

Create private client.json, which is excluded from Git:

```json
{
  "url": "https://edge.tavhome.online/agent-remote",
  "token": "REPLACE_WITH_CLIENT_TOKEN",
  "workers": 4,
  "spool": "C:/Users/ATonkov/AppData/Local/agent-remote-https/results"
}
```

The token must match windows-1 in server.json. Adjust spool for another user;
write permission is required. The installer replaces spool with its own subdirectory.
**workers** sets the maximum concurrent commands: 1–32, default 4. Remaining jobs
wait on the server. Restart after changing it. Run one instance per PC and spool;
otherwise each instance has its own limit.

## Client installation: choose one mode

### Current user — the tested mode

```powershell
.\scripts\install_https_client.ps1 -CurrentUser -Pythonw (Get-Command pythonw.exe).Source -ConfigFile .\client.json
```

AgentRemoteHTTPSUser starts at user logon with ordinary user privileges. Files
are copied to `%LOCALAPPDATA%\agent-remote-https`. ACLs allow the user, SYSTEM
and Administrators. Elevation is not required, but organizational policy may
restrict task registration. Operation after logout is not guaranteed.

### SYSTEM — full local privileges

Run elevated PowerShell using Python installed for all users:

```powershell
.\scripts\install_https_client.ps1 -Pythonw 'C:\Program Files\Python313\pythonw.exe' -ConfigFile .\client.json
```

AgentRemoteHTTPS starts at boot. Files reside in `C:\ProgramData\agent-remote-https`.
Commands have SYSTEM privileges with a different profile and network identity.
This is not the interactive user desktop.

Both modes use pythonw, restart on failure and unlimited task duration. Do not
run both simultaneously. If ps1 execution is restricted, use an approved signing
or execution method; the installer does not change ExecutionPolicy.

For a one-off trial instead of a task:

```powershell
python https_remote.py client --config .\client.json
```

Do not run a manual instance alongside the background client.

## Commands from the server

Create UTF-8 `/tmp/remote-command.ps1`:

```powershell
$ErrorActionPreference = 'Stop'
whoami
hostname
Get-Date -Format o
```

```bash
cd /tavdata/agent-remote
python3 https_remote.py submit --config /etc/agent-remote-https/operator.json windows-1 --script-file /tmp/remote-command.ps1 --timeout 300
python3 https_remote.py status --config /etc/agent-remote-https/operator.json JOB_ID
```

submit immediately returns an ID. Query status separately. Submit multiple jobs
without waiting to run concurrently. Responses include stdout, stderr, exit_code,
reason, timestamps and state: queued, running, done, unknown. done means a result
arrived, not necessarily success. Send PowerShell, not Bash. Use
`$ErrorActionPreference = 'Stop'` and, when needed, `exit $LASTEXITCODE` after exe calls.

## Stop, resume and configuration changes

```powershell
Stop-ScheduledTask AgentRemoteHTTPSUser
Disable-ScheduledTask AgentRemoteHTTPSUser
# Resume:
Enable-ScheduledTask AgentRemoteHTTPSUser
Start-ScheduledTask AgentRemoteHTTPSUser
```

For SYSTEM use AgentRemoteHTTPS and elevation. To change workers, stop the task,
edit the installed client.json and restart. Stop manual processes separately.
Remove a task with `Unregister-ScheduledTask AgentRemoteHTTPSUser -Confirm:$false`.
Files remain.

```bash
systemctl disable --now agent-remote-https
# Resume:
systemctl enable --now agent-remote-https
```

Stopping preserves data. Check queued jobs are still appropriate before resuming;
the client will continue picking them up. Delete files separately after verifying paths.

## Diagnostics and limitations

Server: `systemctl status agent-remote-https --no-pager`,
`journalctl -u agent-remote-https -n 50 --no-pager`, `ss -ltnp | grep 9320`.
Windows: `Get-ScheduledTask AgentRemoteHTTPSUser`,
`Get-ScheduledTaskInfo AgentRemoteHTTPSUser`. Code 267009/0x41301 means running.
For startup errors stop the task and run the client in foreground.
401 means wrong token; 403 means insufficient privileges; 502 means backend stopped.
For TLS errors check time, certificate and truststore in the task's Python.

Commands share files: coordinate concurrent changes. Timeouts range from 1 to
86400 seconds. taskkill terminates the process tree on timeout/output overflow.
Each output stream is capped at 128 KiB; periodic checking allows temporary files
to briefly exceed the threshold. Detached children are outside full termination
guarantees.

SQLite persists jobs. Claimed commands are never automatically replayed: they may
already have changed the PC. After timeout + 120 seconds without a response, status
shows unknown; inspect actual state before retrying. Completed results are spooled
and retried after connectivity returns. A crash before spooling can lose a result.
The database retains commands and output: restrict access and monitor size.
Cancellation, file transfer, history cleanup and desktop automation are not implemented.

## Current deployment and validation

As of 16 November 2026: server 89.46.237.38, code `/tavdata/agent-remote`, service
agent-remote-https, URL `https://edge.tavhome.online/agent-remote`, client windows-1,
PC DMW12105, account `detmir-group\atonkov`, workers=4.
The original AgentRemoteHTTPSUser task points directly to
`C:\my_data\remote\agent-remote\https_remote.py` and configuration
`C:\my_data\remote\agent-remote\.local\https-client.json`. Until reinstalled,
edit that file rather than the installer's LOCALAPPDATA location above.

Validated six end-to-end jobs: four concurrent, two waiting, stdout, hostname,
whoami, exit 7 and timeout. Local tests:

```bash
python -m unittest discover -s tests -v
```

These cover the queue, tokens, persistence, parallel PowerShell and timeout.
The PowerShell test runs only on Windows.
At the user's request the client and API are stopped and autostart is disabled.
Data is preserved. Caddy and other sites remain running; the API route returns 502
until the backend starts. The legacy Chisel transport is independent of HTTPS.
