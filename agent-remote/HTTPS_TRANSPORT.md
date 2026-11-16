# Windows без Chisel: установка и эксплуатация

[English](HTTPS_TRANSPORT.en.md)

## Архитектура

`https_remote.py` содержит сервер очереди SQLite, Windows-клиент и CLI оператора.
Требуется Python 3.10+. Windows сам опрашивает HTTPS примерно раз в секунду;
SSH, Chisel и входящие порты на ПК не нужны. Каждая команда выполняется отдельным
скрытым процессом PowerShell. Управления экраном и мышью нет.

## Установка Linux-сервера

Выполняйте от root. В примере репозиторий GitHub находится в `/opt/tavpublic`,
а код проекта — в его подкаталоге agent-remote. Для новой установки:

```bash
git clone https://github.com/antontonkovkz/tavpublic.git /opt/tavpublic
cd /opt/tavpublic/agent-remote
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
ExecStart=/usr/bin/python3 /opt/tavpublic/agent-remote/https_remote.py serve --config %d/server.json
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
`reverse_proxy 127.0.0.1:9320`. В текущем развёртывании в блоке remote.example.com
перед общим обработчиком handle добавлено:

```caddy
handle_path /agent-remote/* {
    reverse_proxy 127.0.0.1:9320
}
```

handle_path удаляет префикс. URL клиента: `https://remote.example.com/agent-remote`.
Сохраните копию Caddyfile перед редактированием, затем выполните:

```bash
caddy validate --config /etc/caddy/Caddyfile
systemctl reload caddy
curl -i -X POST https://remote.example.com/agent-remote/poll -d '{}'
```

Без токена ожидается 401. 502 означает недоступность backend. Удалённый API требует
HTTPS; HTTP разрешён CLI только на loopback для локального оператора.

## Подготовка Windows

Клонируйте репозиторий в `C:\work\tavpublic`. Код проекта находится в agent-remote.
Установите Python 3.10+.
Для SYSTEM нужна установка Python для всех пользователей. Пользовательский режим
допускает Python в профиле пользователя.

```powershell
git clone https://github.com/antontonkovkz/tavpublic.git C:\work\tavpublic
cd C:\work\tavpublic\agent-remote
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
  "url": "https://remote.example.com/agent-remote",
  "token": "REPLACE_WITH_CLIENT_TOKEN",
  "workers": 4,
  "spool": "C:/Users/operator/AppData/Local/agent-remote-https/results"
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
cd /opt/tavpublic/agent-remote
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
1–86400 секунд. Процесс создаётся приостановленным, помещается в Windows Job Object
с KILL_ON_JOB_CLOSE и только затем запускается. Закрытие клиента или таймаут завершает
его процессы и потомков, включая запущенные через Start-Process. Процессы, созданные
внешней службой вне Job Object, этим механизмом не контролируются.
Ответ сохраняет начало и конец каждого потока в пределах примерно 128 КиБ.
Усечение ответа не прерывает сборку. Отдельный аварийный порог временного вывода —
100 МиБ суммарно; проверка периодическая и допускает кратковременное превышение.

SQLite сохраняет задания. Подтверждённые команды автоматически не повторяются: они могли
уже изменить ПК. После timeout + 120 секунд без ответа статус отображается unknown;
перед повтором проверьте фактическое состояние. Готовые ответы сохраняются в spool
и повторно отправляются после восстановления сети. Сбой до записи spool может
потерять ответ. В базе остаются команды и вывод: ограничивайте доступ и следите
за размером. Передача файлов и управление экраном не реализованы; отмена доступна
только до начала исполнения. Остановка работающей команды вручную через API пока не реализована.

## Обновление протокола и новые настройки

Новый клиент и сервер используют протокол 2: queued → claimed → running → done.
Клиент обязан получить успешный `/start` перед выполнением. Если ответ `/poll`
потерян, claimed возвращается в queued через 60 секунд с новым случайным ключом
выдачи. Старый ключ уже не позволяет начать работу. После успешного `/start`
задание никогда автоматически не возвращается в очередь, даже если подтверждение
не дошло до клиента: такой исход позже станет unknown.

Обновляйте сервер и все клиенты при остановленных процессах. Скопируйте рядом с
https_remote.py также windows_job.py, затем переустановите задачу. Сделайте резервную
копию SQLite с корректным учётом WAL (остановите сервер и скопируйте базу и файлы
`-wal`/`-shm`, если они есть). Миграция схемы автоматическая. Старые queued получают
TTL от времени создания, старые running не переисполняются. Старый клиент получает
409 до выдачи задания. Старые ответы без ключа выдачи останутся в карантине для
ручного разбора; не удаляйте их до проверки состояния ПК.

Повреждённые spool/*.json переименовываются в .bad; окончательно отвергнутые сервером
— в .rejected. Они не блокируют другие ответы и получение заданий. Запись результата
использует flush/fsync перед атомарной заменой. Ошибки фоновых работников пишутся в
`client.log` рядом с client.json; ротация — 2 МиБ и три резервных файла.
На сервере ошибки и неудачные авторизации видны в journalctl. Тексты команд, ответы
и секреты в эти журналы не пишутся.

SYSTEM-установка допускает Python только внутри Program Files и проверяет владельцев,
права записи и отсутствие точек перенаправления в дереве Python и родительских
каталогах до Program Files. Не используйте пользовательские библиотеки/интерпретатор.
Установщик запрещает Restricted/AllSigned и ограниченный языковой режим; клиент
также проверяет политику в своей учётной записи перед заданием. Политики не меняются,
Bypass не включается. Проверка: `Get-ExecutionPolicy -List`. AppLocker/WDAC и правила
организации могут требовать дополнительного разрешения. Планировщик теперь разрешает
работу от батареи. Один spool защищён межпроцессной блокировкой.

В конфигурации клиента можно явно задать `"proxy": "http://proxy.example.com:8080"`.
Пустая строка отключает прокси, отсутствие поля сохраняет стандартные настройки urllib.
PAC и NTLM/Kerberos не реализованы. SYSTEM не наследует пользовательскую прокси-сессию.
TLS проверяется системным хранилищем, но не закрепляется отдельным отпечатком: доверенная
TLS-инспекция видит содержимое. Опрос пока остаётся коротким, без long polling.

```bash
python3 https_remote.py submit --config /etc/agent-remote-https/operator.json windows-1 --script-file command.ps1 --timeout 300 --ttl 3600 --wait
python3 https_remote.py list --config /etc/agent-remote-https/operator.json --client windows-1
python3 https_remote.py cancel --config /etc/agent-remote-https/operator.json JOB_ID
python3 https_remote.py purge --config /etc/agent-remote-https/server.json --days 30
```

TTL ограничивает ожидание начала задания (1–604800 секунд, по умолчанию час).
cancel отменяет queued/claimed, но не running. list возвращает до 100 последних
заданий и время последнего опроса клиентов. purge выполняется локально с доступом
к базе и удаляет только завершённые/отменённые/просроченные записи. Делайте это при
остановленном сервере с правами владельца базы. SQLite использует WAL и индекс очереди.
В server.json можно добавить уникальный read_token; отдельная конфигурация оператора
с этим токеном разрешает только status/list. Для ротации замените токен на обеих
сторонах при остановленном клиенте и перезапустите сервер.

## Границы доверия

Сервер и токен оператора дают возможность выполнять код на клиентах с их правами.
Подписей скриптов и автоматического определения опасных команд нет. Для разрушительных
операций агент должен запрашивать подтверждение оператора. Вывод ПК считайте недоверенными
данными, а не инструкциями агенту. Системный режим на рабочем ПК и постоянное соединение
с сервером должны соответствовать разрешённой в организации схеме удалённого управления.
