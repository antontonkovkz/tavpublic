"""Queued remote PowerShell execution. Python 3.10+, standard library only."""
import argparse
import concurrent.futures
import contextlib
import hmac
import json
import logging
from logging.handlers import RotatingFileHandler
import os
import secrets
import sqlite3
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.request
import uuid
from urllib.parse import urlsplit
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

# Use Windows certificate-chain validation (including managed enterprise roots).
if os.name == 'nt':
    try:
        import truststore
        truststore.inject_into_ssl()
    except ImportError:
        pass

MAX_OUTPUT = 128 * 1024
MAX_DISK_OUTPUT = 100 * 1024 * 1024
LOG = logging.getLogger('agent_remote')


def configure_logging(path=None):
    handler = RotatingFileHandler(path, maxBytes=2 * 1024 * 1024, backupCount=3, encoding='utf-8') if path else logging.StreamHandler()
    handler.setFormatter(logging.Formatter('%(asctime)s %(levelname)s %(message)s'))
    LOG.addHandler(handler)
    LOG.setLevel(logging.INFO)


def atomic_json(path, value):
    temporary = path.with_suffix('.tmp')
    with temporary.open('w', encoding='utf-8') as stream:
        json.dump(value, stream)
        stream.flush()
        os.fsync(stream.fileno())
    temporary.replace(path)


@contextlib.contextmanager
def instance_lock(spool):
    with (spool / 'client.lock').open('a+b') as stream:
        stream.seek(0)
        stream.write(b'0')
        stream.flush()
        stream.seek(0)
        if os.name == 'nt':
            import msvcrt
            msvcrt.locking(stream.fileno(), msvcrt.LK_NBLCK, 1)
        else:
            import fcntl
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        try:
            yield
        finally:
            if os.name == 'nt':
                stream.seek(0)
                msvcrt.locking(stream.fileno(), msvcrt.LK_UNLCK, 1)


class Queue:
    def __init__(self, path):
        self.path = path
        with self.connect() as db:
            db.execute('''CREATE TABLE IF NOT EXISTS jobs (
                id TEXT PRIMARY KEY, client TEXT NOT NULL, script TEXT NOT NULL,
                timeout INTEGER NOT NULL, state TEXT NOT NULL, created REAL NOT NULL,
                started REAL, finished REAL, result TEXT)''')
            columns = {r['name'] for r in db.execute('PRAGMA table_info(jobs)')}
            for name, kind in [('lease', 'TEXT'), ('claimed', 'REAL'), ('expires', 'REAL')]:
                if name not in columns:
                    db.execute('ALTER TABLE jobs ADD COLUMN ' + name + ' ' + kind)
            db.execute("UPDATE jobs SET expires=created+3600 WHERE expires IS NULL AND state='queued'")
            db.execute('CREATE INDEX IF NOT EXISTS jobs_claim ON jobs(client,state,created)')
            db.execute('CREATE INDEX IF NOT EXISTS jobs_lease_expiry ON jobs(state,claimed)')
            db.execute('CREATE INDEX IF NOT EXISTS jobs_ttl ON jobs(state,expires)')
            db.execute('CREATE INDEX IF NOT EXISTS jobs_retention ON jobs(state,finished)')
            db.execute('CREATE TABLE IF NOT EXISTS clients (name TEXT PRIMARY KEY, last_seen REAL)')
        with self.connect() as db:
            db.execute('PRAGMA journal_mode=WAL')

    @contextlib.contextmanager
    def connect(self):
        db = sqlite3.connect(self.path, timeout=30)
        db.row_factory = sqlite3.Row
        try:
            with db:
                yield db
        finally:
            db.close()

    def submit(self, client, script, timeout, ttl=3600):
        job = uuid.uuid4().hex
        with self.connect() as db:
            db.execute('INSERT INTO jobs (id,client,script,timeout,state,created,expires) VALUES (?,?,?,?,?,?,?)',
                       (job, client, script, timeout, 'queued', time.time(), time.time() + ttl))
        LOG.info('Submitted job=%s', job)
        return job

    def claim(self, client):
        with self.connect() as db:
            db.execute('BEGIN IMMEDIATE')
            self.maintain(db)
            db.execute('INSERT OR REPLACE INTO clients VALUES (?,?)', (client, time.time()))
            row = db.execute("SELECT * FROM jobs WHERE client=? AND state='queued' ORDER BY created LIMIT 1", (client,)).fetchone()
            if not row:
                return None
            lease = secrets.token_urlsafe(32)
            db.execute("UPDATE jobs SET state='claimed',claimed=?,lease=? WHERE id=?", (time.time(), lease, row['id']))
            return {**dict(row), 'lease': lease, 'state': 'claimed'}

    def maintain(self, db):
        now = time.time()
        db.execute("UPDATE jobs SET state='queued',lease=NULL,claimed=NULL WHERE state='claimed' AND claimed<?", (now - 60,))
        db.execute("UPDATE jobs SET state='expired',finished=? WHERE state IN ('queued','claimed') AND expires IS NOT NULL AND expires<=?", (now, now))

    def start(self, client, job, lease):
        # A start acknowledgement is issued once. Lost acknowledgements are not retried.
        with self.connect() as db:
            db.execute('BEGIN IMMEDIATE')
            self.maintain(db)
            return db.execute("UPDATE jobs SET state='running',started=? WHERE id=? AND client=? AND lease=? AND state='claimed'",
                              (time.time(), job, client, lease)).rowcount == 1

    def cancel(self, job):
        with self.connect() as db:
            return db.execute("UPDATE jobs SET state='cancelled',finished=? WHERE id=? AND state IN ('queued','claimed')",
                              (time.time(), job)).rowcount == 1

    def listing(self, client=None):
        with self.connect() as db:
            self.maintain(db)
            rows = db.execute('SELECT id,client,state,created,started,finished,expires,timeout FROM jobs WHERE (? IS NULL OR client=?) ORDER BY created DESC LIMIT 100', (client, client))
            jobs = [dict(r) for r in rows]
            for job in jobs:
                if job['state'] == 'running' and time.time() > job['started'] + job['timeout'] + 120:
                    job['state'] = 'unknown'
            return {'jobs': jobs, 'clients': [dict(r) for r in db.execute('SELECT * FROM clients')]}

    def purge(self, days):
        with self.connect() as db:
            return db.execute("DELETE FROM jobs WHERE state IN ('done','cancelled','expired') AND finished<?", (time.time() - days * 86400,)).rowcount

    def get(self, job):
        with self.connect() as db:
            self.maintain(db)
            row = db.execute('SELECT * FROM jobs WHERE id=?', (job,)).fetchone()
            if not row:
                return None
            result = dict(row)
            if result['result']:
                result['result'] = json.loads(result['result'])
            # A lost client leaves an uncertain outcome, never silently resubmit it.
            if result['state'] == 'running' and time.time() > result['started'] + result['timeout'] + 120:
                result['state'] = 'unknown'
            return result

    def finish(self, client, job, result, lease):
        with self.connect() as db:
            row = db.execute('SELECT client,state,lease FROM jobs WHERE id=?', (job,)).fetchone()
            if not row or row['client'] != client or row['lease'] != lease:
                return False
            if row['state'] == 'running':
                db.execute("UPDATE jobs SET state='done', finished=?, result=? WHERE id=? AND state='running'",
                           (time.time(), json.dumps(result), job))
            return row['state'] in ('running', 'done')


def make_server(address, queue, admin_token, clients, read_token=None):
    class Handler(BaseHTTPRequestHandler):
        def setup(self):
            super().setup()
            self.connection.settimeout(35)

        def log_message(self, *args):
            pass  # Never log credentials or command bodies.

        def reply(self, status, value):
            body = json.dumps(value).encode()
            self.send_response(status)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_POST(self):
            try:
                token = self.headers.get('Authorization', '').removeprefix('Bearer ')
                token_bytes = token.encode('utf-8')
                admin = hmac.compare_digest(token_bytes, admin_token.encode())
                reader = admin or (read_token and hmac.compare_digest(token_bytes, read_token.encode()))
                client = next((name for name, secret in clients.items() if hmac.compare_digest(secret.encode(), token_bytes)), None)
                if not reader and not client:
                    # The API binds to loopback. Trust XFF only from the local reverse proxy.
                    peer = self.headers.get('X-Forwarded-For', self.client_address[0])[:200]
                    LOG.warning('Unauthorized request peer=%s', repr(peer))
                    return self.reply(401, {'error': 'unauthorized'})
                length = int(self.headers.get('Content-Length', '0'))
                if length < 0 or length > 2 * 1024 * 1024:
                    return self.reply(413, {'error': 'request too large'})
                data = json.loads(self.rfile.read(length))
                if not isinstance(data, dict):
                    raise ValueError('expected object')
                if self.path == '/submit' and admin:
                    name, script = data['client'], data['script']
                    timeout = int(data.get('timeout', 300))
                    if name not in clients or not isinstance(script, str) or not 1 <= len(script) <= 65536 or not 1 <= timeout <= 86400:
                        raise ValueError('invalid job')
                    ttl = int(data.get('ttl', 3600))
                    if not 1 <= ttl <= 604800:
                        raise ValueError('invalid ttl')
                    return self.reply(200, {'id': queue.submit(name, script, timeout, ttl)})
                if self.path == '/status' and reader:
                    job = queue.get(data['id'])
                    return self.reply(200 if job else 404, job)
                if self.path == '/poll' and client:
                    if data.get('protocol') != 2:
                        return self.reply(409, {'error': 'client upgrade required: protocol 2'})
                    return self.reply(200, {'job': queue.claim(client)})
                if self.path == '/start' and client:
                    ok = queue.start(client, data['id'], data['lease'])
                    return self.reply(200 if ok else 409, {'ok': ok})
                if self.path == '/cancel' and admin:
                    return self.reply(200, {'ok': queue.cancel(data['id'])})
                if self.path == '/list' and reader:
                    return self.reply(200, queue.listing(data.get('client')))
                if self.path == '/result' and client:
                    result = data['result']
                    if not isinstance(result, dict) or len(json.dumps(result)) > 1600000:
                        raise ValueError('invalid result')
                    ok = queue.finish(client, data['id'], result, data['lease'])
                    return self.reply(200 if ok else 404, {'ok': ok})
                return self.reply(403, {'error': 'forbidden'})
            except (ValueError, KeyError, TypeError):
                self.reply(400, {'error': 'invalid request'})
            except Exception:
                # Do not log exception messages, bodies, tokens, scripts, or outputs.
                import sys
                import traceback
                LOG.error('Request failure type=%s frames=%s', sys.exc_info()[0].__name__,
                          traceback.extract_tb(sys.exc_info()[2]).format())
                self.reply(500, {'error': 'internal error'})

    server = ThreadingHTTPServer(address, Handler)
    server.daemon_threads = True
    return server


def api(url, token, path, data, proxy=None):
    parsed = urlsplit(url)
    if parsed.username or parsed.password or parsed.query or parsed.fragment or not parsed.hostname:
        raise ValueError('Invalid API URL')
    if parsed.scheme != 'https' and not (parsed.scheme == 'http' and parsed.hostname in ('127.0.0.1', 'localhost', '::1')):
        raise ValueError('HTTPS is required except on loopback')
    request = urllib.request.Request(url.rstrip('/') + path, json.dumps(data).encode(),
                                     {'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json'})
    # Do not forward bearer credentials through redirects.
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *args, **kwargs):
            return None
    handlers = [NoRedirect]
    if proxy is not None:
        handlers.append(urllib.request.ProxyHandler({'http': proxy, 'https': proxy} if proxy else {}))
    with urllib.request.build_opener(*handlers).open(request, timeout=30) as response:
        return json.load(response)


def read_output(stream):
    size = os.fstat(stream.fileno()).st_size
    stream.seek(0)
    if size <= MAX_OUTPUT:
        data = stream.read(MAX_OUTPUT)
    else:
        head = stream.read(MAX_OUTPUT // 2)
        stream.seek(-MAX_OUTPUT // 2, os.SEEK_END)
        data = head + b'\n... [output truncated: head and tail] ...\n' + stream.read(MAX_OUTPUT // 2)
    return data.decode('utf-8', errors='replace'), size > MAX_OUTPUT


def execute(job):
    flags = {}
    if os.name == 'nt':
        startup = subprocess.STARTUPINFO()
        startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
        startup.wShowWindow = subprocess.SW_HIDE
        flags = {'creationflags': subprocess.CREATE_NO_WINDOW, 'startupinfo': startup}
    powershell = os.path.join(os.environ.get('SystemRoot', r'C:\Windows'), 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe')
    probe = subprocess.run([powershell, '-NoProfile', '-NonInteractive', '-Command',
                            "@{policy=[string](Get-ExecutionPolicy);language=[string]$ExecutionContext.SessionState.LanguageMode}|ConvertTo-Json -Compress"],
                           stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, shell=False, timeout=30, **flags)
    try:
        settings = json.loads(probe.stdout.decode('utf-8-sig'))
        if probe.returncode or not isinstance(settings, dict) or not all(k in settings for k in ('policy', 'language')):
            raise ValueError('invalid probe')
    except ValueError:
        return {'exit_code': probe.returncode, 'reason': 'policy_probe_failed', 'stdout': '',
                'stderr': 'PowerShell preflight failed. Inspect ExecutionPolicy, AppLocker and WDAC under the client account.'}
    if settings['policy'] in ('Restricted', 'AllSigned') or settings['language'] != 'FullLanguage':
        return {'exit_code': None, 'reason': 'policy_blocked', 'stdout': '',
                'stderr': 'Unsigned PowerShell jobs require an approved execution policy and FullLanguage mode; no policy was changed.'}
    with tempfile.TemporaryDirectory(prefix='agent-remote-') as directory:
        script = Path(directory) / 'command.ps1'
        script.write_text("[Console]::OutputEncoding = [Text.Encoding]::UTF8\n" + job['script'], encoding='utf-8-sig')
        with tempfile.TemporaryFile() as stdout, tempfile.TemporaryFile() as stderr:
            command = [
                powershell,
                '-NoProfile', '-NonInteractive', '-File', str(script)]
            from windows_job import JobProcess
            with contextlib.closing(JobProcess(command, stdout, stderr)) as process:
                deadline = time.monotonic() + job['timeout']
                reason = None
                while process.poll() is None:
                    if time.monotonic() >= deadline:
                        reason = 'timeout'
                    elif os.fstat(stdout.fileno()).st_size + os.fstat(stderr.fileno()).st_size > MAX_DISK_OUTPUT:
                        reason = 'disk_output_limit'
                    if reason:
                        process.kill()
                        break
                    time.sleep(0.1)
                process.wait()
                process.close()  # Close job even on normal parent exit: no orphan children.
                out, out_cut = read_output(stdout)
                err, err_cut = read_output(stderr)
                return {'exit_code': process.returncode, 'reason': reason,
                        'stdout': out, 'stderr': err, 'output_truncated': out_cut or err_cut}


def deliver_results(spool, send):
    def quarantine(path, suffix):
        try:
            path.replace(path.with_suffix(suffix))
        except OSError as exc:
            LOG.warning('Cannot quarantine result type=%s', type(exc).__name__)
    for pending in sorted(spool.glob('*.json')):
        try:
            payload = json.loads(pending.read_text(encoding='utf-8'))
            if not isinstance(payload, dict) or not all(k in payload for k in ('id', 'lease', 'result')):
                raise ValueError('invalid spool payload')
        except (ValueError, UnicodeError):
            quarantine(pending, '.bad')
            LOG.warning('Quarantined invalid result file')
            continue
        except OSError as exc:
            LOG.warning('Cannot read result type=%s', type(exc).__name__)
            continue
        try:
            acknowledgement = send('/result', payload)
            if not isinstance(acknowledgement, dict) or acknowledgement.get('ok') is not True:
                raise ValueError('invalid result acknowledgement')
            pending.unlink()
        except urllib.error.HTTPError as exc:
            if exc.code in (400, 404, 409, 410, 413):
                quarantine(pending, '.rejected')
                LOG.warning('Result rejected status=%d', exc.code)
            else:
                LOG.warning('Result delivery deferred status=%d', exc.code)
        except Exception as exc:
            LOG.warning('Result delivery deferred type=%s', type(exc).__name__)


def valid_job(job):
    return (isinstance(job, dict) and isinstance(job.get('id'), str)
            and len(job['id']) == 32 and all(c in '0123456789abcdef' for c in job['id'])
            and isinstance(job.get('lease'), str) and isinstance(job.get('script'), str)
            and isinstance(job.get('timeout'), int) and 1 <= job['timeout'] <= 86400)


def client_loop(config, stop=None):
    workers = int(config.get('workers', 4))
    if not 1 <= workers <= 32:
        raise ValueError('workers must be between 1 and 32')
    spool = Path(config['spool'])
    spool.mkdir(parents=True, exist_ok=True)
    stop = stop or threading.Event()
    def send(path, payload):
        return api(config['url'], config['token'], path, payload, config.get('proxy'))
    def run(job):
        try:
            result = execute(job)
        except Exception as exc:
            LOG.error('Execution failed type=%s job=%s', type(exc).__name__, job['id'])
            result = {'exit_code': None, 'reason': 'client_error', 'stderr': type(exc).__name__, 'stdout': ''}
        target = spool / (job['id'] + '.json')
        atomic_json(target, {'id': job['id'], 'lease': job['lease'], 'result': result})

    with instance_lock(spool), concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
        active = set()
        while not stop.is_set():
            try:
                for future in list(active):
                    if future.done():
                        active.remove(future)
                        try:
                            future.result()
                        except Exception as exc:
                            LOG.error('Worker failed to persist result type=%s', type(exc).__name__)
                deliver_results(spool, send)
                if len(active) < workers:
                    response = send('/poll', {'protocol': 2})
                    if not isinstance(response, dict) or 'job' not in response:
                        raise ValueError('invalid poll response')
                    job = response['job']
                    if job:
                        if not valid_job(job):
                            raise ValueError('invalid job')
                        acknowledgement = send('/start', {'id': job['id'], 'lease': job['lease']})
                        if not isinstance(acknowledgement, dict) or acknowledgement.get('ok') is not True:
                            raise ValueError('invalid start acknowledgement')
                        active.add(pool.submit(run, job))
                        continue
                stop.wait(1)
            except Exception as exc:
                LOG.warning('Client iteration failed type=%s', type(exc).__name__)
                stop.wait(5)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    for name in ('serve', 'client', 'submit', 'status', 'cancel', 'list', 'purge'):
        sub = commands.add_parser(name)
        sub.add_argument('--config', required=True)
        if name == 'submit':
            sub.add_argument('client')
            sub.add_argument('--script-file', required=True)
            sub.add_argument('--timeout', type=int, default=300)
            sub.add_argument('--ttl', type=int, default=3600)
            sub.add_argument('--wait', action='store_true')
        if name in ('status', 'cancel'):
            sub.add_argument('id')
        if name == 'list':
            sub.add_argument('--client')
        if name == 'purge':
            sub.add_argument('--days', type=int, default=30)
    commands.add_parser('token')
    args = parser.parse_args()
    if args.command == 'token':
        print(secrets.token_urlsafe(32))
        return
    if args.command == 'client':
        configure_logging(Path(args.config).resolve().parent / 'client.log')
    elif args.command == 'serve':
        configure_logging()
    config = json.loads(Path(args.config).read_text(encoding='utf-8-sig'))
    if args.command == 'serve':
        tokens = [config['admin_token'], *config['clients'].values()]
        if config.get('read_token'):
            tokens.append(config['read_token'])
        if len(set(tokens)) != len(tokens) or any(len(t) < 32 for t in tokens):
            raise ValueError('Use unique tokens with at least 32 characters')
        make_server(('127.0.0.1', int(config.get('port', 9320))), Queue(config['database']),
                    config['admin_token'], config['clients'], config.get('read_token')).serve_forever()
    elif args.command == 'client':
        if os.name != 'nt':
            raise ValueError('The execution client requires Windows')
        client_loop(config)
    elif args.command == 'submit':
        response = api(config['url'], config['token'], '/submit', {
            'client': args.client, 'script': Path(args.script_file).read_text(encoding='utf-8-sig'), 'timeout': args.timeout, 'ttl': args.ttl}, config.get('proxy'))
        print(json.dumps(response), flush=True)
        if args.wait:
            while True:
                result = api(config['url'], config['token'], '/status', response, config.get('proxy'))
                if result['state'] in ('done', 'unknown', 'expired', 'cancelled'):
                    print(json.dumps(result, ensure_ascii=False, indent=2))
                    break
                time.sleep(1)
    elif args.command == 'list':
        print(json.dumps(api(config['url'], config['token'], '/list', {'client': args.client}, config.get('proxy')), indent=2))
    elif args.command == 'purge':
        if args.days < 1:
            raise ValueError('days must be positive')
        print(json.dumps({'deleted': Queue(config['database']).purge(args.days)}))
    else:
        print(json.dumps(api(config['url'], config['token'], '/' + args.command, {'id': args.id}, config.get('proxy')), ensure_ascii=False, indent=2))


if __name__ == '__main__':
    try:
        main()
    except Exception as exc:
        LOG.error('Startup/command failed type=%s', type(exc).__name__)
        raise SystemExit(1)
