# Windows без Chisel: установка и эксплуатация

[English](HTTPS_TRANSPORT.en.md)

## Архитектура

`https_remote.py` содержит сервер очереди SQLite, Windows-клиент и CLI оператора.
Требуется Python 3.10+. Windows сам опрашивает HTTPS примерно раз в секунду;
SSH, Chisel и входящие порты на ПК не нужны. Каждая команда выполняется отдельным
скрытым процессом PowerShell. Управления экраном и мышью нет.

## Установка Linux-сервера

Выполняйте от root. Репозиторий текущего развёртывания — `/tavdata/agent-remote`.

```bash
cd /tavdata/agent-remote
git pull
python3 --version
install -d -m 700 /etc/agent-remote-https
install -d -m 755 /var/lib/agent-remote-https
python3 https_remote.py token
python3 https_remote.py token
```

Получите два разных токена: оператора и клиента. Создайте
`/etc/agent-remote-https/server.json`:

```json
{
  "port": 9320,
  "database": "/var/lib/agent-remote-https/jobs.db",
  "admin_token": "REPLACE_WITH_ADMIN_TOKEN",
  "clients": {"windows-1": "REPLACE_WITH_CLIENT_TOKEN"}
}
```

Создайте `/etc/agent-remote-https/operator.json`:

```json
{"url":"http://127.0.0.1:9320", "token":"REPLACE_WITH_ADMIN_TOKEN"}
```

В operator.json используется тот же admin_token. Все токены уникальны и не короче
32 символов. Не выдавайте токен оператора клиенту. Для другого ПК добавьте имя и
отдельный токен в clients, затем перезапустите сервер. clients.tsv относится к SSH.

```bash
chmod 600 /etc/agent-remote-https/*.json
```

Создайте `/etc/systemd/system/agent-remote-https.service`:

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

Нужен systemd с поддержкой LoadCredential (в текущем Ubuntu есть). Код должен быть
доступен динамическому пользователю для чтения; StateDirectory обеспечивает запись
базы. API не требует root и слушает только loopback, порт 9320 наружу не открывайте.

```bash
systemctl daemon-reload
systemctl enable --now agent-remote-https
systemctl status agent-remote-https --no-pager
```

## HTTPS и Caddy

Нужны DNS-имя и действующий сертификат. Для отдельного сайта достаточно
`reverse_proxy 127.0.0.1:9320`. В текущем развёртывании в блоке edge.tavhome.online
перед общим обработчиком handle добавлено:

```caddy
handle_path /agent-remote/* {
    reverse_proxy 127.0.0.1:9320
}
```

handle_path удаляет префикс. URL клиента: `https://edge.tavhome.online/agent-remote`.
Сохраните копию Caddyfile перед редактированием, затем выполните:

```bash
caddy validate --config /etc/caddy/Caddyfile
systemctl reload caddy
curl -i -X POST https://edge.tavhome.online/agent-remote/poll -d '{}'
```

Без токена ожидается 401. 502 означает недоступность backend. Удалённый API требует
HTTPS; HTTP разрешён CLI только на loopback для локального оператора.

## Подготовка Windows

Клонируйте проект в `C:\my_data\remote\agent-remote`. Установите Python 3.10+.
Для SYSTEM нужна установка Python для всех пользователей. Пользовательский режим
допускает Python в профиле пользователя.

```powershell
cd C:\my_data\remote\agent-remote
python --version
python -m pip install truststore
(Get-Command pythonw.exe).Source
```

truststore подключает системное хранилище сертификатов Windows автоматически;
проверка TLS остаётся включённой. Установите пакет именно в Python задачи.
pythonw скрывает консоль клиента; PowerShell и taskkill запускаются с
CREATE_NO_WINDOW. Запускаемые удалённым скриптом приложения требуют собственного
управления окнами. Защита endpoint не отключается, исключения не добавляются.

Создайте приватный client.json (исключён из Git):

```json
{
  "url": "https://edge.tavhome.online/agent-remote",
  "token": "REPLACE_WITH_CLIENT_TOKEN",
  "workers": 4,
  "spool": "C:/Users/ATonkov/AppData/Local/agent-remote-https/results"
}
```

Токен совпадает с windows-1 в server.json. Измените spool для другого пользователя;
ему нужна запись. Установщик заменяет spool своим подкаталогом.
**workers** — максимум одновременных команд: 1–32, по умолчанию 4. Остальные ждут
на сервере. Настройка применяется после перезапуска. Запускайте один экземпляр
клиента для одного ПК и spool, иначе лимит будет действовать на каждый экземпляр.

## Установка клиента: выберите один режим

### Текущий пользователь — проверенный вариант

```powershell
.\scripts\install_https_client.ps1 -CurrentUser -Pythonw (Get-Command pythonw.exe).Source -ConfigFile .\client.json
```

Задача AgentRemoteHTTPSUser запускается при входе пользователя с его обычными
правами. Файлы копируются в `%LOCALAPPDATA%\agent-remote-https`. ACL разрешают
доступ пользователю, SYSTEM и администраторам. Повышение прав не требуется, но
корпоративная политика может запрещать регистрацию задач. Работа после выхода
пользователя не гарантируется.

### SYSTEM — полные локальные права

В PowerShell от администратора, с Python для всех пользователей:

```powershell
.\scripts\install_https_client.ps1 -Pythonw 'C:\Program Files\Python313\pythonw.exe' -ConfigFile .\client.json
```

Задача AgentRemoteHTTPS запускается при загрузке. Файлы находятся в
`C:\ProgramData\agent-remote-https`. Команды имеют права SYSTEM, другой профиль и
сетевую идентичность. Это не интерактивный пользовательский рабочий стол.

Оба режима используют pythonw, повторный запуск при сбое и неограниченную
длительность задачи. Не запускайте оба режима одновременно. При запрете ps1
используйте разрешённый способ подписи/запуска; установщик не меняет ExecutionPolicy.

Для разового испытания вместо задачи:

```powershell
python https_remote.py client --config .\client.json
```

Не запускайте ручной экземпляр вместе с фоновым.

## Команды с сервера

Создайте UTF-8 файл `/tmp/remote-command.ps1`:

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

submit сразу возвращает ID. status запрашивается отдельно. Для параллельной работы
отправляйте несколько заданий без ожидания. Ответ содержит stdout, stderr, exit_code,
reason, время и state: queued, running, done, unknown. done означает получение
ответа, а не обязательно успех. Отправляйте PowerShell, не Bash. Используйте
`$ErrorActionPreference = 'Stop'` и при необходимости `exit $LASTEXITCODE` после exe.

## Остановка, возобновление и настройки

```powershell
Stop-ScheduledTask AgentRemoteHTTPSUser
Disable-ScheduledTask AgentRemoteHTTPSUser
# Возобновить:
Enable-ScheduledTask AgentRemoteHTTPSUser
Start-ScheduledTask AgentRemoteHTTPSUser
```

Для SYSTEM замените имя на AgentRemoteHTTPS и используйте администратора. Чтобы
изменить workers, остановите задачу, исправьте установленный client.json и запустите
снова. Ручной процесс останавливается отдельно. Удаление задачи:
`Unregister-ScheduledTask AgentRemoteHTTPSUser -Confirm:$false`. Файлы остаются.

```bash
systemctl disable --now agent-remote-https
# Возобновить:
systemctl enable --now agent-remote-https
```

Остановка сохраняет данные. Перед возобновлением оцените актуальность queued-заданий:
клиент продолжит их получать. Удаление файлов выполняется отдельно после проверки путей.

## Диагностика и ограничения

Сервер: `systemctl status agent-remote-https --no-pager`,
`journalctl -u agent-remote-https -n 50 --no-pager`, `ss -ltnp | grep 9320`.
Windows: `Get-ScheduledTask AgentRemoteHTTPSUser`,
`Get-ScheduledTaskInfo AgentRemoteHTTPSUser`. Код 267009/0x41301 означает работу.
Для ошибок запуска остановите задачу и запустите клиент вручную.
401 — неверный токен; 403 — недостаточные права; 502 — backend выключен.
При TLS-ошибке проверьте время, сертификат и truststore в используемом Python.

Команды используют общие файлы: согласовывайте параллельные изменения. Таймаут
1–86400 секунд. При таймауте/переполнении вывода taskkill завершает дерево процессов.
Каждый поток результата ограничен 128 КиБ; периодическая проверка допускает
кратковременное превышение размера временных файлов. Отсоединённые дети не покрыты
полной гарантией завершения.

SQLite сохраняет задания. Выданные команды автоматически не повторяются: они могли
уже изменить ПК. После timeout + 120 секунд без ответа статус отображается unknown;
перед повтором проверьте фактическое состояние. Готовые ответы сохраняются в spool
и повторно отправляются после восстановления сети. Сбой до записи spool может
потерять ответ. В базе остаются команды и вывод: ограничивайте доступ и следите
за размером. Нет отмены, передачи файлов, очистки истории и desktop automation.

## Текущее развёртывание и проверка

На 16 ноября 2026: сервер 89.46.237.38, код `/tavdata/agent-remote`, служба
agent-remote-https, URL `https://edge.tavhome.online/agent-remote`, клиент windows-1,
ПК DMW12105, пользователь `detmir-group\atonkov`, workers=4.
Первоначальная задача AgentRemoteHTTPSUser ссылается прямо на
`C:\my_data\remote\agent-remote\https_remote.py` и конфигурацию
`C:\my_data\remote\agent-remote\.local\https-client.json`. До переустановки
меняйте этот файл, а не LOCALAPPDATA из установщика выше.

Проверены шесть сквозных заданий (четыре одновременно, два в ожидании), stdout,
hostname, whoami, exit 7 и таймаут. Локальные тесты:

```bash
python -m unittest discover -s tests -v
```

Проверяют очередь, токены, сохранение заданий, параллельный PowerShell и таймаут.
PowerShell-тест выполняется только на Windows.
По просьбе пользователя клиент и API остановлены, автозапуск отключён. Данные
сохранены. Caddy и другие сайты работают; маршрут API даёт 502 до запуска backend.
Старый Chisel-транспорт независим от HTTPS.
