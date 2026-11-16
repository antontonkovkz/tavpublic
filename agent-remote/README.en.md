# agent-remote — remote PC management from a server

[Русский](README.md)

agent-remote lets an operator or AI agent on a server execute commands on a remote
Windows PC and retrieve results. The background client connects outbound over
HTTPS. The primary setup requires no Chisel or SSH on either side and no inbound
ports on the PC.

## How it works

1. An operator on the Linux server submits a PowerShell script to the queue.
2. The Windows client receives the job through an outbound HTTPS connection.
3. Each command runs in its own PowerShell process without a console window.
4. The client returns stdout, stderr and exit code; the server stores the result.

Use it for files, Git, builds, processes and services within the client's account
permissions. Mouse, screen and application-window control are not implemented.
File transfer and cancellation of running commands are not implemented either.

## Features

- Concurrent commands: configurable `workers` from 1 to 32, default 4. Remaining
  jobs wait in the queue. Restart the client after changing the setting.
- Persistent jobs and results in SQLite on the server.
- Execution timeouts, bounded output and separate results for each job.
- Waiting TTL, cancellation before execution, and job/client listings.
- Local result spooling and retry after connectivity returns.
- Separate tokens for each PC and the operator.
- Client startup at user logon or Windows boot as SYSTEM.

Unacknowledged claims return to the queue after 60 seconds. A separate start
acknowledgement is required; started commands are never automatically replayed: they may already have changed
the PC. Inspect actual machine state before retrying a job with an unknown outcome.

## Installation and configuration

**[Complete installation guide](HTTPS_TRANSPORT.en.md)**: Linux API and systemd
service, HTTPS through Caddy, Windows client installation, concurrency, stopping,
resuming and troubleshooting.

The server needs Python 3.10+ and an HTTPS proxy with a valid certificate. Windows
needs Python 3.10+; truststore is recommended for Windows certificate validation.
SYSTEM is not required for ordinary management; choose privileges for your tasks.

| File | Purpose |
| --- | --- |
| `https_remote.py` | Queue server, Windows client and operator CLI |
| `scripts/install_https_client.ps1` | Windows background client installer |
| `windows_job.py` | Windows Job Object execution and child-process cleanup |
| [HTTPS_TRANSPORT.en.md](HTTPS_TRANSPORT.en.md) | Full installation and operation guide |
| [AGENT_INSTRUCTIONS.en.md](AGENT_INSTRUCTIONS.en.md) | AI agent operating rules |
| [REVIEW.en.md](REVIEW.en.md) | Review findings, fixes and remaining limitations |

## Command example

Create UTF-8 command.ps1:

```powershell
$ErrorActionPreference = 'Stop'
whoami
hostname
Get-Date -Format o
```

On the configured server:

```bash
python3 https_remote.py submit --config /etc/agent-remote-https/operator.json windows-1 --script-file command.ps1 --timeout 300
python3 https_remote.py status --config /etc/agent-remote-https/operator.json JOB_ID
```

The first command returns a job ID; replace JOB_ID with it in the second command.
Submit multiple jobs without waiting to execute concurrently.

## Validation

```bash
python -m unittest discover -s tests -v
```

Tests cover the queue, token isolation, persistence, parallel PowerShell and
timeout. The PowerShell test runs only on Windows.

## Alternative: SSH through Chisel

An independent reverse SSH tunnel option is retained for Ubuntu clients or
existing SSH infrastructure. It requires Chisel on both sides and uses
scripts/ai_client.sh for command execution.

**[Alternative SSH/Chisel installation guide](CHISEL.en.md)**.
