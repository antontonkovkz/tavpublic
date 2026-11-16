"""Queued remote PowerShell execution. Python 3.10+, standard library only."""
import argparse
import concurrent.futures
import contextlib
import hmac
import json
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


class Queue:
    def __init__(self, path):
        self.path = path
        with self.connect() as db:
            db.execute('''CREATE TABLE IF NOT EXISTS jobs (
                id TEXT PRIMARY KEY, client TEXT NOT NULL, script TEXT NOT NULL,
                timeout INTEGER NOT NULL, state TEXT NOT NULL, created REAL NOT NULL,
                started REAL, finished REAL, result TEXT)''')

    @contextlib.contextmanager
    def connect(self):
        db = sqlite3.connect(self.path, timeout=30)
        db.row_factory = sqlite3.Row
        try:
            with db:
                yield db
        finally:
            db.close()

    def submit(self, client, script, timeout):
        job = uuid.uuid4().hex
        with self.connect() as db:
            db.execute('INSERT INTO jobs VALUES (?,?,?,?,?,?,NULL,NULL,NULL)',
                       (job, client, script, timeout, 'queued', time.time()))
        return job

    def claim(self, client):
        # A claimed job is never automatically retried: commands can have side effects.
        with self.connect() as db:
            db.execute('BEGIN IMMEDIATE')
            row = db.execute("SELECT * FROM jobs WHERE client=? AND state='queued' ORDER BY created LIMIT 1", (client,)).fetchone()
            if not row:
                return None
            db.execute("UPDATE jobs SET state='running', started=? WHERE id=?", (time.time(), row['id']))
            return dict(row)

    def get(self, job):
        with self.connect() as db:
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

    def finish(self, client, job, result):
        with self.connect() as db:
            row = db.execute('SELECT client,state FROM jobs WHERE id=?', (job,)).fetchone()
            if not row or row['client'] != client:
                return False
            if row['state'] == 'running':
                db.execute("UPDATE jobs SET state='done', finished=?, result=? WHERE id=?",
                           (time.time(), json.dumps(result), job))
            return row['state'] in ('running', 'done')


def make_server(address, queue, admin_token, clients):
    class Handler(BaseHTTPRequestHandler):
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
                admin = hmac.compare_digest(token, admin_token)
                client = next((name for name, secret in clients.items() if hmac.compare_digest(secret, token)), None)
                if not admin and not client:
                    return self.reply(401, {'error': 'unauthorized'})
                length = int(self.headers.get('Content-Length', '0'))
                if length < 0 or length > 2 * 1024 * 1024:
                    return self.reply(413, {'error': 'request too large'})
                data = json.loads(self.rfile.read(length))
                if self.path == '/submit' and admin:
                    name, script = data['client'], data['script']
                    timeout = int(data.get('timeout', 300))
                    if name not in clients or not isinstance(script, str) or not 1 <= len(script) <= 65536 or not 1 <= timeout <= 86400:
                        raise ValueError('invalid job')
                    return self.reply(200, {'id': queue.submit(name, script, timeout)})
                if self.path == '/status' and admin:
                    job = queue.get(data['id'])
                    return self.reply(200 if job else 404, job)
                if self.path == '/poll' and client:
                    return self.reply(200, {'job': queue.claim(client)})
                if self.path == '/result' and client:
                    result = data['result']
                    if not isinstance(result, dict) or len(json.dumps(result)) > 1600000:
                        raise ValueError('invalid result')
                    ok = queue.finish(client, data['id'], result)
                    return self.reply(200 if ok else 404, {'ok': ok})
                return self.reply(403, {'error': 'forbidden'})
            except (ValueError, KeyError, TypeError):
                self.reply(400, {'error': 'invalid request'})
            except Exception:
                self.reply(500, {'error': 'internal error'})

    server = ThreadingHTTPServer(address, Handler)
    server.daemon_threads = True
    return server


def api(url, token, path, data):
    if not url.startswith('https://') and not url.startswith(('http://127.0.0.1:', 'http://localhost:')):
        raise ValueError('HTTPS is required except on loopback')
    request = urllib.request.Request(url.rstrip('/') + path, json.dumps(data).encode(),
                                     {'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json'})
    # Do not forward bearer credentials through redirects.
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *args, **kwargs):
            return None
    with urllib.request.build_opener(NoRedirect).open(request, timeout=30) as response:
        return json.load(response)


def execute(job):
    flags = {}
    if os.name == 'nt':
        startup = subprocess.STARTUPINFO()
        startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
        startup.wShowWindow = subprocess.SW_HIDE
        flags = {'creationflags': subprocess.CREATE_NO_WINDOW, 'startupinfo': startup}
    with tempfile.TemporaryDirectory(prefix='agent-remote-') as directory:
        script = Path(directory) / 'command.ps1'
        script.write_text("[Console]::OutputEncoding = [Text.Encoding]::UTF8\n" + job['script'], encoding='utf-8-sig')
        with tempfile.TemporaryFile() as stdout, tempfile.TemporaryFile() as stderr:
            process = subprocess.Popen([
                os.path.join(os.environ.get('SystemRoot', r'C:\Windows'), 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe'),
                '-NoProfile', '-NonInteractive', '-File', str(script)],
                stdin=subprocess.DEVNULL, stdout=stdout, stderr=stderr, shell=False, **flags)
            deadline = time.monotonic() + job['timeout']
            reason = None
            while process.poll() is None:
                if time.monotonic() >= deadline:
                    reason = 'timeout'
                elif os.fstat(stdout.fileno()).st_size + os.fstat(stderr.fileno()).st_size > MAX_OUTPUT:
                    reason = 'output_limit'
                if reason:
                    subprocess.run(['taskkill.exe', '/PID', str(process.pid), '/T', '/F'],
                                   stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                   shell=False, **flags)
                    process.kill() if process.poll() is None else None
                    break
                time.sleep(0.1)
            process.wait()
            stdout.seek(0)
            stderr.seek(0)
            return {'exit_code': process.returncode, 'reason': reason,
                    'stdout': stdout.read(MAX_OUTPUT).decode('utf-8', errors='replace'),
                    'stderr': stderr.read(MAX_OUTPUT).decode('utf-8', errors='replace')}


def client_loop(config):
    workers = int(config.get('workers', 4))
    if not 1 <= workers <= 32:
        raise ValueError('workers must be between 1 and 32')
    spool = Path(config['spool'])
    spool.mkdir(parents=True, exist_ok=True)
    def run(job):
        try:
            result = execute(job)
        except Exception as exc:
            result = {'exit_code': None, 'reason': 'client_error', 'stderr': str(exc), 'stdout': ''}
        target = spool / (job['id'] + '.json')
        temporary = target.with_suffix('.tmp')
        temporary.write_text(json.dumps({'id': job['id'], 'result': result}), encoding='utf-8')
        temporary.replace(target)

    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
        active = set()
        while True:
            try:
                for pending in spool.glob('*.json'):
                    api(config['url'], config['token'], '/result', json.loads(pending.read_text(encoding='utf-8')))
                    pending.unlink()
                active = {future for future in active if not future.done()}
                if len(active) < workers:
                    job = api(config['url'], config['token'], '/poll', {})['job']
                    if job:
                        active.add(pool.submit(run, job))
                        continue
                time.sleep(1)
            except (OSError, ValueError, urllib.error.URLError):
                time.sleep(5)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    for name in ('serve', 'client', 'submit', 'status'):
        sub = commands.add_parser(name)
        sub.add_argument('--config', required=True)
        if name == 'submit':
            sub.add_argument('client')
            sub.add_argument('--script-file', required=True)
            sub.add_argument('--timeout', type=int, default=300)
        if name == 'status':
            sub.add_argument('id')
    commands.add_parser('token')
    args = parser.parse_args()
    if args.command == 'token':
        print(secrets.token_urlsafe(32))
        return
    config = json.loads(Path(args.config).read_text(encoding='utf-8-sig'))
    if args.command == 'serve':
        tokens = [config['admin_token'], *config['clients'].values()]
        if len(set(tokens)) != len(tokens) or any(len(t) < 32 for t in tokens):
            raise ValueError('Use unique tokens with at least 32 characters')
        make_server(('127.0.0.1', int(config.get('port', 9320))), Queue(config['database']),
                    config['admin_token'], config['clients']).serve_forever()
    elif args.command == 'client':
        if os.name != 'nt':
            raise ValueError('The execution client requires Windows')
        client_loop(config)
    elif args.command == 'submit':
        print(json.dumps(api(config['url'], config['token'], '/submit', {
            'client': args.client, 'script': Path(args.script_file).read_text(encoding='utf-8-sig'), 'timeout': args.timeout})))
    else:
        print(json.dumps(api(config['url'], config['token'], '/status', {'id': args.id}), ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
