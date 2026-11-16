# Remote host instructions for AI agents

[Русский](AGENT_INSTRUCTIONS.md)

## Choose the transport

HTTPS clients use https_remote.py. SSH/Chisel clients use scripts/ai_client.sh.
Do not send Unix commands to Windows. See [README.en.md](README.en.md) and the
complete [HTTPS installation guide](HTTPS_TRANSPORT.en.md).

## HTTPS Windows clients

Submit a UTF-8 PowerShell script file and query its returned ID:

```bash
python3 https_remote.py submit --config /etc/agent-remote-https/operator.json windows-1 --script-file command.ps1 --timeout 300
python3 https_remote.py status --config /etc/agent-remote-https/operator.json JOB_ID
```

Submit multiple jobs without waiting for parallel execution. The client's workers
setting limits concurrency. done means a result arrived: inspect exit_code and
reason. Never retry unknown jobs without checking actual machine state. Never
print tokens. Use explicit PowerShell/native executable error handling.

## SSH/Chisel clients

inventory/clients.tsv is the source of truth for name, reverse port and SSH user.
The optional sixth field is OS (linux/windows); older records default to Linux.
Do not assume common users, ports, root access or availability across clients.
The helper defaults to private key /root/.ssh/ai_chisel_ed25519.

```bash
scripts/ai_client.sh list
scripts/ai_client.sh show client-1
scripts/ai_client.sh check client-1
scripts/ai_client.sh run client-1 -- sh -lc 'whoami && hostname && pwd'
```

Prefer the helper over direct ssh and avoid interactive sessions unless needed.
Use `scripts/ai_client.sh ssh client-1` when an interactive session is necessary.
For Windows use `scripts/ai_client.sh ps win-1 'whoami; hostname; Get-Location'`.
The ps command requires iconv/base64 on the server. Do not send sh, uname or
systemctl to Windows. See the README for Windows account/ACL setup.

## Inspect before changes

Verify the current user, hostname, directory and relevant service state. Prefer
idempotent commands. Do not delete data without a task-related need or assume a
host is disposable. Use the supported inventory helpers when available.

For Linux service tasks inspect:

```bash
scripts/ai_client.sh run client-1 -- sh -lc 'systemctl is-system-running || true'
scripts/ai_client.sh run client-1 -- sh -lc 'systemctl status SERVICE --no-pager || true'
```

If SSH is unreachable, inspect chisel-server on the server, then chisel-client
and ssh services on Ubuntu and authorized_keys ownership/permissions. On Windows
inspect AgentRemoteTunnel, sshd, and C:\ProgramData\agent-remote\tunnel.log.
That log is written after Chisel exits. Remote child processes must obey the
user's hidden execution requirements.
