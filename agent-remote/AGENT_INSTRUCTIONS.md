# AI Agent Remote Host Instructions

## Windows через HTTPS, без Chisel

Для HTTPS-клиентов используйте `https_remote.py`, а не SSH helper ниже.
Установка: [HTTPS_TRANSPORT.md](HTTPS_TRANSPORT.md).
Отправка: `python3 https_remote.py submit --config /etc/agent-remote-https/operator.json windows-1 --script-file command.ps1 --timeout 300`.
Результат: `python3 https_remote.py status --config /etc/agent-remote-https/operator.json JOB_ID`.
Отправляйте PowerShell, несколько заданий можно отправить без ожидания.
Лимит задаёт workers клиента. Не повторяйте unknown без проверки состояния ПК.
Не выводите токены. Следующие инструкции относятся только к SSH/Chisel.

Этот проект использует reverse SSH поверх `chisel`.

AI-агент должен работать с удалёнными хостами только через локальный helper:

```bash
scripts/ai_client.sh
```

## Источник истины

- Inventory: `inventory/clients.tsv`
- Для каждого клиента в inventory хранятся:
  - `name`
  - `reverse-port`
  - `ssh_user`
  - `tags`
  - `description`

AI-агент не должен предполагать:

- одинаковые порты у всех клиентов
- одинакового SSH-пользователя у всех клиентов
- что клиент доступен, пока это не проверено явно

## Базовый порядок работы

1. Посмотреть inventory:

```bash
scripts/ai_client.sh list
```

2. Если нужен конкретный клиент, посмотреть его параметры:

```bash
scripts/ai_client.sh show client-1
```

3. Проверить доступность:

```bash
scripts/ai_client.sh check client-1
```

4. Выполнять команды только через:

```bash
scripts/ai_client.sh run client-1 -- sh -lc '...'
```

5. Интерактивную SSH-сессию использовать только если без неё нельзя:

```bash
scripts/ai_client.sh ssh client-1
```

## Предпочтительный стиль команд

Предпочитать:

```bash
scripts/ai_client.sh run client-1 -- sh -lc 'whoami && hostname && pwd'
```

Не предпочитать:

```bash
ssh -p 2201 ubuntu@127.0.0.1 ...
```

Причина:

- `ai_client.sh` использует inventory
- `ai_client.sh` использует private key AI: `/root/.ssh/ai_chisel_ed25519`
- меньше риска ошибиться портом или пользователем
- единый способ работы для всех клиентов

## Правила безопасности

- Перед изменениями сначала выполнять команды осмотра.
- По возможности делать команды идемпотентными.
- Перед потенциально опасными действиями сначала проверить:
  - текущего пользователя
  - hostname
  - текущую директорию
  - состояние сервиса, если работа идёт с сервисом
- Не удалять данные и не делать destructive actions без явной необходимости.
- Не предполагать, что хост одноразовый, даже если он тестовый.

## Рекомендуемая последовательность перед изменениями

```bash
scripts/ai_client.sh check client-1
scripts/ai_client.sh run client-1 -- sh -lc 'whoami && hostname && pwd'
scripts/ai_client.sh run client-1 -- sh -lc 'uname -a'
```

Если работа связана с systemd:

```bash
scripts/ai_client.sh run client-1 -- sh -lc 'systemctl is-system-running || true'
scripts/ai_client.sh run client-1 -- sh -lc 'systemctl status <service> --no-pager || true'
```

## Если клиент недоступен

На AI-сервере проверить:

```bash
systemctl status chisel-server --no-pager
scripts/ai_client.sh check client-1
```

Если есть доступ к самому клиенту через другой канал, проверить на клиенте:

```bash
systemctl status chisel-client --no-pager
systemctl status ssh --no-pager
cat /home/<user>/.ssh/authorized_keys
```

## Что не делать

- Не обходить `scripts/ai_client.sh`, если нет особой причины.
- Не использовать жёстко захардкоженные порты из памяти.
- Не изменять inventory вручную без необходимости, если можно использовать стандартный поток подготовки клиента.
- Не считать, что `root` доступен везде.

## Короткая памятка

Основной рабочий цикл:

```bash
scripts/ai_client.sh list
scripts/ai_client.sh check client-1
scripts/ai_client.sh run client-1 -- sh -lc '...'
```


## Windows clients

Prepare on the Linux AI server with `scripts/prepare_client_bootstrap.sh --os windows --client-name win-1 --ssh-user ATonkov --server-host ai.example.com`.
Run the generated installer command in elevated PowerShell from a Windows clone of this repository. It configures OpenSSH and a SYSTEM startup task named `AgentRemoteTunnel`, with automatic retries and no interactive console. No desktop/mouse automation is provided.

Inventory gains an optional sixth column `os` (`linux` or `windows`); old five-column records remain Linux. Add manually with `scripts/ai_client.sh add win-1 2201 ATonkov demo "Windows PC" windows`.

For Windows use `scripts/ai_client.sh ps win-1 'Get-Location; hostname; whoami'` and `scripts/ai_client.sh check win-1`. The `ps` command requires iconv and base64 on the server. PowerShell scripts use EncodedCommand; use explicit `exit` for native program failures. Never send `sh -lc`, `uname` or `systemctl` to Windows.

Files and credentials are under `C:\ProgramData\agent-remote` with access restricted to SYSTEM and Administrators. The installer uses an existing local account; sign in once before installing for a non-admin account. OpenSSH authorized_keys ACLs are configured for that account. SSH permissions follow the selected account. Existing SSH configuration is preserved; custom authentication rules may need manual adjustment. The installer requires administrator privileges and internet access. Windows SSH should be restricted to loopback/firewall policy when only tunnel access is needed.

Inspect `Get-ScheduledTaskInfo AgentRemoteTunnel`, `Get-Service sshd`, and `C:\ProgramData\agent-remote\tunnel.log` for diagnostics (the log is written when the tunnel process exits). Remove the tunnel with `Stop-ScheduledTask AgentRemoteTunnel; Unregister-ScheduledTask AgentRemoteTunnel -Confirm:$false`; this preserves SSH and its keys. Child processes launched by remote scripts must also use hidden execution when needed.
