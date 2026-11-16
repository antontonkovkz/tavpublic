# agent-remote

[English](AGENT_INSTRUCTIONS.en.md)

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


## Windows-клиенты через Chisel и SSH

На Linux-сервере подготовьте подключение командой `scripts/prepare_client_bootstrap.sh --os windows --client-name win-1 --ssh-user ATonkov --server-host ai.example.com`.
Выполните напечатанную команду установки в PowerShell от администратора из Windows-копии проекта. Она настраивает OpenSSH и задачу `AgentRemoteTunnel` от SYSTEM с запуском при загрузке, повторными попытками и без консольного окна. Управление мышью и экраном не предусмотрено.

В таблице клиентов есть необязательный шестой столбец `os` (`linux` или `windows`). Старые записи из пяти столбцов считаются Linux. Пример ручного добавления: `scripts/ai_client.sh add win-1 2201 ATonkov demo "Windows PC" windows`.

Для Windows используйте `scripts/ai_client.sh ps win-1 'Get-Location; hostname; whoami'` и `scripts/ai_client.sh check win-1`. Команда `ps` требует iconv и base64 на сервере. Скрипты передаются через EncodedCommand; для ошибок внешних программ явно задавайте код через `exit`. Не отправляйте на Windows команды `sh -lc`, `uname` и `systemctl`.

Файлы и секреты находятся в `C:\ProgramData\agent-remote`, доступ ограничен SYSTEM и администраторами. Для обычной локальной учётной записи сначала войдите в Windows, чтобы создать профиль. Для доменной учётной записи запускайте установку с повышенными правами от неё же. Установщик настраивает права authorized_keys; права SSH соответствуют выбранному пользователю. Существующая конфигурация SSH сохраняется, нестандартные правила аутентификации могут потребовать ручной настройки. Нужны права администратора и Интернет. Если SSH нужен только через туннель, ограничьте прямой доступ к нему настройкой прослушивания или межсетевым экраном.

Диагностика: `Get-ScheduledTaskInfo AgentRemoteTunnel`, `Get-Service sshd` и `C:\ProgramData\agent-remote\tunnel.log` (журнал записывается после завершения процесса). Удаление задачи: `Stop-ScheduledTask AgentRemoteTunnel; Unregister-ScheduledTask AgentRemoteTunnel -Confirm:$false`. SSH и ключи сохраняются. Дочерние процессы удалённых скриптов тоже должны соблюдать скрытый запуск, когда он требуется.


## HTTPS-транспорт без Chisel

Выполнение PowerShell через очередь с настраиваемой параллельностью: [HTTPS_TRANSPORT.md](HTTPS_TRANSPORT.md). Параметр `workers` задаётся в конфигурации Windows-клиента: от 1 до 32, по умолчанию 4. После изменения перезапустите клиент.
