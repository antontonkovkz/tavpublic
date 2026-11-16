# Альтернативный вариант: SSH через Chisel

[English](CHISEL.en.md)

## Назначение

Эта инструкция относится только к альтернативному SSH-транспорту для Ubuntu и
Windows. Основной вариант удалённого управления описан в [README.md](README.md),
его установка — в [HTTPS_TRANSPORT.md](HTTPS_TRANSPORT.md). Для HTTPS Chisel не нужен.

Минимальная схема:

- AI-сервер поднимает `chisel server` на кастомном TCP-порту.
- Ubuntu-клиенты поднимают `chisel client` как systemd service.
- Каждый клиент пробрасывает свой локальный `sshd` назад на `127.0.0.1:<reverse-port>` на AI-сервере.
- AI работает с клиентами только через локальный helper `scripts/ai_client.sh`.

Пример удалённой команды:

```bash
scripts/ai_client.sh run client-1 -- sh -lc 'hostname && uname -a'
```

## Что устанавливается

На AI-сервере:

- `chisel` в `/usr/local/bin/chisel`
- конфиг в `/etc/chisel`
- systemd unit `chisel-server.service`
- SSH keypair для AI:
  - `/root/.ssh/ai_chisel_ed25519`
  - `/root/.ssh/ai_chisel_ed25519.pub`
- helper-скрипты:
  - `scripts/ai_client.sh`
  - `scripts/generate_client_install_command.sh`
  - `scripts/prepare_client_bootstrap.sh`
- инструкция для AI-агента:
  - `AGENT_INSTRUCTIONS.md`
- inventory:
  - `inventory/clients.tsv`
  - `inventory/known_hosts`

На Ubuntu-клиенте:

- `openssh-server`
- `chisel` в `/usr/local/bin/chisel`
- конфиг в `/etc/chisel/client.env`
- systemd unit `chisel-client.service`

## Основной сценарий

1. На AI-сервере запускаете установку:

```bash
sudo CHISEL_PORT=9312 bash scripts/install_ai_server.sh
```

Скрипт:

- скачивает и ставит `chisel`
- создаёт `/etc/chisel/server_key.pem`
- создаёт `/etc/chisel/users.json`
- поднимает `chisel-server.service`
- пытается открыть `CHISEL_PORT/tcp` в локальном `ufw` или `firewalld`, если правило ещё не существует
- генерирует SSH keypair для AI
- печатает:
  - `Auth: user:pass`
  - `Fingerprint: ...`
  - путь к SSH-ключам

Важно:

- локальный `ufw` или `firewalld` скрипт попробует настроить сам
- если у вас внешний cloud firewall / security group / provider firewall, входящий TCP-порт `CHISEL_PORT` всё равно нужно открыть отдельно
- сохраните `Auth` и `Fingerprint`, они нужны клиентам

2. На AI-сервере готовите bootstrap для нового клиента:

```bash
scripts/prepare_client_bootstrap.sh \
  --client-name client-1 \
  --ssh-user ubuntu \
  --server-host your-ai-server.example.com
```

Этот helper:

- пытается автоматически определить `server-port`, `auth` и `fingerprint` из локальной установки `chisel-server`
- выбирает свободный reverse port из диапазона `2200-2299`
- печатает:
  - команду добавления клиента в inventory
  - `Local command` для установки клиента
  - `Remote one-liner` для установки клиента через `curl | sudo bash`

3. Выполняете сгенерированную install-команду на Ubuntu-клиенте.

Установка клиента делает следующее:

- ставит `openssh-server`
- скачивает и ставит `chisel`
- добавляет public key AI-сервера в `authorized_keys` нужного пользователя
- создаёт `/etc/chisel/client.env`
- поднимает `chisel-client.service`

4. На AI-сервере добавляете клиента в inventory командой, которую напечатал `prepare_client_bootstrap.sh`.

Пример:

```bash
scripts/ai_client.sh add client-1 2201 ubuntu demo "Ubuntu test box"
```

5. Проверяете доступность клиента:

```bash
scripts/ai_client.sh check client-1
```

6. Выполняете команды через inventory:

```bash
scripts/ai_client.sh run client-1 -- sh -lc 'hostname && uname -a'
```

## Самый короткий поток

На AI-сервере:

```bash
sudo CHISEL_PORT=9312 bash scripts/install_ai_server.sh
scripts/prepare_client_bootstrap.sh --client-name client-1 --ssh-user ubuntu --server-host your-ai-server.example.com
```

После этого:

- копируете сгенерированную install-команду и выполняете её на клиенте
- копируете сгенерированную команду `scripts/ai_client.sh add ...` и выполняете её на AI-сервере
- проверяете:

```bash
scripts/ai_client.sh check client-1
scripts/ai_client.sh run client-1 -- sh -lc 'whoami && hostname'
```

## Команды оператора

Установка AI-сервера:

```bash
sudo CHISEL_PORT=9312 bash scripts/install_ai_server.sh
```

Подготовка bootstrap для клиента:

```bash
scripts/prepare_client_bootstrap.sh \
  --client-name client-1 \
  --ssh-user ubuntu \
  --server-host your-ai-server.example.com
```

Дополнительные параметры:

```bash
scripts/prepare_client_bootstrap.sh \
  --client-name client-2 \
  --ssh-user root \
  --server-host 203.0.113.10 \
  --port-start 2300 \
  --port-end 2399 \
  --tags demo \
  --description "Second test node"
```

Если нужен ручной режим без авто-подбора порта:

```bash
scripts/generate_client_install_command.sh \
  --server-host your-ai-server.example.com \
  --server-port 9312 \
  --auth 'ai:replace-with-strong-secret' \
  --fingerprint 'SERVER_FINGERPRINT' \
  --reverse-port 2201 \
  --ssh-user ubuntu
```

## Команды AI-агента

AI-агент должен работать только через `scripts/ai_client.sh`.

Полная инструкция для AI-агента:

```text
AGENT_INSTRUCTIONS.md
```

Список клиентов:

```bash
scripts/ai_client.sh list
```

Показать параметры клиента:

```bash
scripts/ai_client.sh show client-1
```

Проверить доступность:

```bash
scripts/ai_client.sh check
scripts/ai_client.sh check client-1
```

Выполнить команду:

```bash
scripts/ai_client.sh run client-1 -- sh -lc 'whoami && pwd && systemctl is-system-running'
```

Открыть интерактивную SSH-сессию:

```bash
scripts/ai_client.sh ssh client-1
```

## Правила для AI-агента

- Использовать `scripts/ai_client.sh` как единственную точку входа.
- Предпочитать `run <name> -- sh -lc '...'` вместо прямого `ssh`.
- Считать `inventory/clients.tsv` источником истины для имени клиента, пользователя и reverse-port.
- Учитывать, что `scripts/ai_client.sh` использует private key AI по умолчанию: `/root/.ssh/ai_chisel_ed25519`.
- Перед опасными действиями сначала выполнять inspect-команды.
- Не предполагать, что у всех клиентов одинаковый пользователь или порт.
- При недоступности клиента сначала проверить:

```bash
systemctl status chisel-server --no-pager
scripts/ai_client.sh check client-1
```

- По возможности делать команды идемпотентными.

## Формат inventory

Файл: `inventory/clients.tsv`

Формат строки:

```text
name<TAB>port<TAB>ssh_user<TAB>tags<TAB>description
```

Пример:

```text
client-1	2201	ubuntu	demo	Ubuntu test box
```

## Проверка и диагностика

На AI-сервере:

```bash
systemctl status chisel-server --no-pager
scripts/ai_client.sh list
scripts/ai_client.sh check
```

На клиенте:

```bash
systemctl status chisel-client --no-pager
systemctl status ssh --no-pager
```

Ручная проверка SSH с AI-сервера:

```bash
ssh -i /root/.ssh/ai_chisel_ed25519 -p 2201 ubuntu@127.0.0.1
```

Если `scripts/ai_client.sh check <name>` показывает `unreachable`, но туннель уже поднят, самые вероятные причины такие:

- пользователь из `--ssh-user` не существует на клиенте
- public key AI не попал в `~/.ssh/authorized_keys`
- неправильные права на `~/.ssh` или `authorized_keys`

Быстрая проверка на клиенте:

```bash
getent passwd <user>
sudo cat /home/<user>/.ssh/authorized_keys
sudo ls -ld /home/<user> /home/<user>/.ssh
sudo ls -l /home/<user>/.ssh/authorized_keys
systemctl status ssh --no-pager
```

## Замечания

- Reverse listener на AI-сервере ограничен `127.0.0.1`, поэтому SSH клиента не открыт наружу.
- Трафик `chisel` шифруется, потому что транспорт построен поверх SSH.
- Если позже понадобится лучшая маскировка под обычный web-трафик, можно поставить `chisel` за `nginx` или `caddy` и вынести наружу на `443/TCP`.
- Для варианта `Remote one-liner` нужно заранее опубликовать `scripts/install_ubuntu_client.sh` по доступному URL и при необходимости передать `CLIENT_SCRIPT_URL=...`.


## Windows-клиенты через Chisel и SSH

На Linux-сервере подготовьте подключение командой `scripts/prepare_client_bootstrap.sh --os windows --client-name win-1 --ssh-user operator --server-host ai.example.com`.
Выполните напечатанную команду установки в PowerShell от администратора из Windows-копии проекта. Она настраивает OpenSSH и задачу `AgentRemoteTunnel` от SYSTEM с запуском при загрузке, повторными попытками и без консольного окна. Управление мышью и экраном не предусмотрено.

В таблице клиентов есть необязательный шестой столбец `os` (`linux` или `windows`). Старые записи из пяти столбцов считаются Linux. Пример ручного добавления: `scripts/ai_client.sh add win-1 2201 operator demo "Windows PC" windows`.

Для Windows используйте `scripts/ai_client.sh ps win-1 'Get-Location; hostname; whoami'` и `scripts/ai_client.sh check win-1`. Команда `ps` требует iconv и base64 на сервере. Скрипты передаются через EncodedCommand; для ошибок внешних программ явно задавайте код через `exit`. Не отправляйте на Windows команды `sh -lc`, `uname` и `systemctl`.

Файлы и секреты находятся в `C:\ProgramData\agent-remote`, доступ ограничен SYSTEM и администраторами. Для обычной локальной учётной записи сначала войдите в Windows, чтобы создать профиль. Для доменной учётной записи запускайте установку с повышенными правами от неё же. Установщик настраивает права authorized_keys; права SSH соответствуют выбранному пользователю. Существующая конфигурация SSH сохраняется, нестандартные правила аутентификации могут потребовать ручной настройки. Нужны права администратора и Интернет. Если SSH нужен только через туннель, ограничьте прямой доступ к нему настройкой прослушивания или межсетевым экраном.

Диагностика: `Get-ScheduledTaskInfo AgentRemoteTunnel`, `Get-Service sshd` и `C:\ProgramData\agent-remote\tunnel.log` (журнал записывается после завершения процесса). Удаление задачи: `Stop-ScheduledTask AgentRemoteTunnel; Unregister-ScheduledTask AgentRemoteTunnel -Confirm:$false`. SSH и ключи сохраняются. Дочерние процессы удалённых скриптов тоже должны соблюдать скрытый запуск, когда он требуется.


## HTTPS-транспорт без Chisel

Выполнение PowerShell через очередь с настраиваемой параллельностью: [HTTPS_TRANSPORT.md](HTTPS_TRANSPORT.md). Параметр `workers` задаётся в конфигурации Windows-клиента: от 1 до 32, по умолчанию 4. После изменения перезапустите клиент.
