import concurrent.futures
import tempfile
import threading
import unittest
from pathlib import Path
import sys
import os
import json
import time
import http.client
import sqlite3
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from https_remote import Queue, api, make_server, execute, deliver_results, atomic_json, client_loop, instance_lock
from urllib.error import HTTPError


class TransportTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.queue = Queue(str(Path(self.directory.name) / 'jobs.db'))
        self.server = make_server(('127.0.0.1', 0), self.queue, 'a' * 40, {'pc': 'b' * 40, 'other': 'c' * 40}, 'r' * 40)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.url = 'http://127.0.0.1:' + str(self.server.server_port)

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.directory.cleanup()

    def test_parallel_claims_are_unique_and_results_are_isolated(self):
        ids = {api(self.url, 'a' * 40, '/submit', {'client': 'pc', 'script': 'hostname'})['id'] for _ in range(12)}
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            jobs = list(pool.map(lambda _: api(self.url, 'b' * 40, '/poll', {'protocol': 2})['job'], range(12)))
        self.assertEqual(ids, {job['id'] for job in jobs})
        self.assertIsNone(api(self.url, 'b' * 40, '/poll', {'protocol': 2})['job'])
        self.assertTrue(api(self.url, 'b' * 40, '/start', {'id': jobs[0]['id'], 'lease': jobs[0]['lease']})['ok'])
        result = {'exit_code': 0, 'stdout': 'test', 'stderr': ''}
        with self.assertRaises(HTTPError) as error:
            api(self.url, 'c' * 40, '/result', {'id': jobs[0]['id'], 'lease': jobs[0]['lease'], 'result': result})
        self.assertEqual(error.exception.code, 404)
        for _ in range(2):
            self.assertTrue(api(self.url, 'b' * 40, '/result', {'id': jobs[0]['id'], 'lease': jobs[0]['lease'], 'result': result})['ok'])
        status = api(self.url, 'a' * 40, '/status', {'id': jobs[0]['id']})
        self.assertEqual(status['result'], result)
        self.assertEqual(status['state'], 'done')

    def test_client_cannot_submit_and_jobs_survive_restart(self):
        with self.assertRaises(HTTPError) as error:
            api(self.url, 'b' * 40, '/submit', {'client': 'pc', 'script': 'hostname'})
        self.assertEqual(error.exception.code, 403)
        job = self.queue.submit('pc', 'hostname', 30)
        recovered = Queue(self.queue.path)
        self.assertEqual(recovered.claim('pc')['id'], job)
        self.assertIsNone(Queue(self.queue.path).claim('pc'))

    def test_lost_claim_expires_but_started_job_is_never_requeued(self):
        job = self.queue.submit('pc', 'hostname', 30)
        first = self.queue.claim('pc')
        with self.queue.connect() as db:
            db.execute('UPDATE jobs SET claimed=? WHERE id=?', (time.time()-61, job))
        second = self.queue.claim('pc')
        self.assertEqual(second['id'], job)
        self.assertNotEqual(second['lease'], first['lease'])
        self.assertFalse(self.queue.start('pc', job, first['lease']))
        self.assertTrue(self.queue.start('pc', job, second['lease']))
        self.assertFalse(self.queue.start('pc', job, second['lease']))
        with self.queue.connect() as db:
            db.execute('UPDATE jobs SET started=? WHERE id=?', (time.time()-500, job))
        self.assertIsNone(self.queue.claim('pc'))
        self.assertEqual(self.queue.get(job)['state'], 'unknown')

    def test_ttl_cancel_and_read_only_token(self):
        job = self.queue.submit('pc', 'hostname', 10, ttl=-1)
        self.assertIsNone(self.queue.claim('pc'))
        self.assertEqual(self.queue.get(job)['state'], 'expired')
        job = self.queue.submit('pc', 'hostname', 10)
        claim = self.queue.claim('pc')
        self.assertTrue(self.queue.cancel(job))
        self.assertFalse(self.queue.start('pc', job, claim['lease']))
        self.assertIn('clients', api(self.url, 'r'*40, '/list', {}))
        with self.assertRaises(HTTPError) as error:
            api(self.url, 'r'*40, '/submit', {'client':'pc','script':'hostname'})
        self.assertEqual(error.exception.code, 403)

    def test_legacy_client_cannot_receive_claim(self):
        self.queue.submit('pc', 'hostname', 10)
        with self.assertRaises(HTTPError) as error:
            api(self.url, 'b'*40, '/poll', {})
        self.assertEqual(error.exception.code, 409)
        self.assertEqual(self.queue.listing()['jobs'][0]['state'], 'queued')

    def test_bad_and_rejected_spool_do_not_block_good_result(self):
        spool = Path(self.directory.name)
        (spool/'1.json').write_text('')
        atomic_json(spool/'2.json', {'id':'gone','lease':'test','result':{}})
        atomic_json(spool/'3.json', {'id':'ok','lease':'test','result':{}})
        seen = []
        def send(path, payload):
            if payload['id']=='gone':
                raise HTTPError('http://localhost',404,'missing',None,None)
            seen.append(payload['id'])
            return {'ok': True}
        deliver_results(spool, send)
        self.assertEqual(seen, ['ok'])
        self.assertTrue((spool/'1.bad').exists())
        self.assertTrue((spool/'2.rejected').exists())
        self.assertFalse((spool/'3.json').exists())

    def test_network_error_does_not_prevent_polling(self):
        spool = Path(self.directory.name)/'spool'
        spool.mkdir()
        atomic_json(spool/'old.json', {'id':'old','lease':'test','result':{}})
        stop = threading.Event()
        polls = []
        def fake_api(url, token, path, data, proxy):
            if path == '/result':
                raise http.client.IncompleteRead(b'partial')
            polls.append(path)
            stop.set()
            return {'job':None}
        with patch('https_remote.api', fake_api):
            client_loop({'workers':1,'spool':str(spool),'url':self.url,'token':'test'},stop)
        self.assertEqual(polls, ['/poll'])
        self.assertTrue((spool/'old.json').exists())

    def test_malformed_poll_and_incomplete_read_are_retried(self):
        for failure in ({}, http.client.IncompleteRead(b'partial')):
            stop = threading.Event()
            calls = []
            def fake_api(*args):
                calls.append(args[2])
                if len(calls) == 1:
                    if isinstance(failure, Exception):
                        raise failure
                    return failure
                stop.set()
                return {'job':None}
            with patch('https_remote.api', fake_api), patch.object(stop, 'wait', return_value=False):
                client_loop({'workers':1,'spool':self.directory.name,'url':self.url,'token':'test'},stop)
            self.assertEqual(calls, ['/poll','/poll'])

    def test_instance_lock_rejects_second_client(self):
        with instance_lock(Path(self.directory.name)):
            with self.assertRaises(OSError):
                with instance_lock(Path(self.directory.name)):
                    pass

    def test_legacy_database_migration(self):
        path=Path(self.directory.name)/'legacy.db'
        with sqlite3.connect(path) as db:
            db.execute('CREATE TABLE jobs (id TEXT PRIMARY KEY, client TEXT, script TEXT, timeout INTEGER, state TEXT, created REAL, started REAL, finished REAL, result TEXT)')
            db.execute('INSERT INTO jobs VALUES (?,?,?,?,?,?,?,?,?)',('old','pc','hostname',10,'queued',time.time()-7200,None,None,None))
        db.close()
        migrated=Queue(str(path))
        self.assertEqual(migrated.get('old')['state'],'expired')
        with migrated.connect() as db:
            self.assertEqual(db.execute('PRAGMA journal_mode').fetchone()[0],'wal')

    def test_lost_start_response_never_executes(self):
        job=self.queue.submit('pc','hostname',10)
        stop=threading.Event()
        def send(url,token,path,data,proxy):
            if path=='/poll':
                return {'job':self.queue.claim('pc')}
            if path=='/start':
                self.assertTrue(self.queue.start('pc',data['id'],data['lease']))
                stop.set()
                raise http.client.IncompleteRead(b'partial')
            raise AssertionError(path)
        with patch('https_remote.api',send), patch('https_remote.execute') as executor:
            client_loop({'spool':self.directory.name,'url':self.url,'token':'test'},stop)
            executor.assert_not_called()
        self.assertEqual(self.queue.get(job)['state'],'running')

    def test_worker_spool_failure_is_observed_and_logged(self):
        job=self.queue.submit('pc','hostname',10)
        stop=threading.Event()
        messages=[]
        def log(message,*args):
            messages.append(message % args)
            stop.set()
        with patch('https_remote.execute',return_value={'stdout':'ok'}),patch('https_remote.atomic_json',side_effect=OSError('disk full')),patch('https_remote.LOG.error',log):
            client_loop({'spool':self.directory.name,'url':self.url,'token':'b'*40},stop)
        self.assertTrue(any('persist result' in m for m in messages))
        self.assertEqual(self.queue.get(job)['state'],'running')

    def test_end_to_end_client_ignores_bad_spool_and_executes_new_job(self):
        spool=Path(self.directory.name)/'spool'
        spool.mkdir()
        (spool/'bad.json').write_text('')
        atomic_json(spool/'gone.json',{'id':'gone','lease':'gone','result':{}})
        job=self.queue.submit('pc','hostname',10)
        stop=threading.Event()
        def send(url,token,path,data,proxy):
            value=api(url,token,path,data,proxy)
            if path=='/result' and data['id']==job:
                stop.set()
            return value
        with patch('https_remote.api',send),patch('https_remote.execute',return_value={'stdout':'executed','stderr':'','exit_code':0}):
            worker=threading.Thread(target=client_loop,args=({'spool':str(spool),'url':self.url,'token':'b'*40},stop))
            worker.start()
            worker.join(10)
            stop.set()
            worker.join(5)
        self.assertFalse(worker.is_alive())
        self.assertEqual(self.queue.get(job)['result']['stdout'],'executed')
        self.assertTrue((spool/'bad.bad').exists())
        self.assertTrue((spool/'gone.rejected').exists())

    @unittest.skipUnless(os.name == 'nt', 'Windows PowerShell required')
    def test_parallel_powershell_and_timeout(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(execute, [
                {'script': 'Start-Sleep -Milliseconds 300; Write-Output "one"', 'timeout': 10},
                {'script': 'Write-Output "two"', 'timeout': 10}]))
        self.assertEqual([r['stdout'].strip() for r in results], ['one', 'two'])
        self.assertTrue(all(r['exit_code'] == 0 for r in results))
        self.assertEqual(execute({'script': 'Start-Sleep -Seconds 15', 'timeout': 1})['reason'], 'timeout')

    @unittest.skipUnless(os.name == 'nt', 'Windows PowerShell required')
    def test_large_output_is_truncated_without_killing_command(self):
        result = execute({'script': "[Console]::Write('x' * 200000); [Console]::Write('TAIL'); exit 7", 'timeout':20})
        self.assertEqual(result['exit_code'], 7)
        self.assertIsNone(result['reason'])
        self.assertTrue(result['output_truncated'])
        self.assertTrue(result['stdout'].endswith('TAIL'))

    @unittest.skipUnless(os.name == 'nt', 'Windows Job Objects required')
    def test_parent_exit_also_kills_child(self):
        import ctypes
        from ctypes import wintypes
        result = execute({'script': "$p=Start-Process powershell.exe -ArgumentList '-NoProfile -NonInteractive -Command Start-Sleep -Seconds 60' -WindowStyle Hidden -PassThru; Write-Output $p.Id", 'timeout':20})
        self.assertEqual(result['exit_code'], 0)
        pid = int(result['stdout'].strip())
        kernel = ctypes.WinDLL('kernel32', use_last_error=True)
        kernel.OpenProcess.argtypes = [wintypes.DWORD,wintypes.BOOL,wintypes.DWORD]
        kernel.OpenProcess.restype = wintypes.HANDLE
        kernel.WaitForSingleObject.argtypes = [wintypes.HANDLE,wintypes.DWORD]
        kernel.CloseHandle.argtypes = [wintypes.HANDLE]
        handle = kernel.OpenProcess(0x100000,False,pid)
        if handle:
            try:
                self.assertEqual(kernel.WaitForSingleObject(handle,3000),0)
            finally:
                kernel.CloseHandle(handle)

    @unittest.skipUnless(os.name == 'nt', 'Windows Job Objects required')
    def test_client_crash_kills_job_process(self):
        import subprocess
        import ctypes
        from ctypes import wintypes
        root = str(Path(__file__).resolve().parents[1])
        pidfile = Path(self.directory.name)/'child.pid'
        code = ("import sys,time;sys.path.insert(0,"+repr(root)+");from windows_job import JobProcess;"
                "from pathlib import Path;out=open("+repr(str(Path(self.directory.name)/'child.log'))+",'wb');"
                "p=JobProcess(["+repr(os.path.join(os.environ['SystemRoot'],'System32','WindowsPowerShell','v1.0','powershell.exe'))+
                ",'-NoProfile','-NonInteractive','-Command','Start-Sleep -Seconds 60'],out,out);"
                "Path("+repr(str(pidfile))+").write_text(str(p.pid));time.sleep(60)")
        startup = subprocess.STARTUPINFO()
        startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
        startup.wShowWindow = subprocess.SW_HIDE
        parent = subprocess.Popen([sys.executable,'-c',code],shell=False,stdin=subprocess.DEVNULL,
                                  stdout=subprocess.PIPE,stderr=subprocess.PIPE,
                                  creationflags=subprocess.CREATE_NO_WINDOW,startupinfo=startup)
        try:
            deadline=time.monotonic()+10
            while not pidfile.exists() and time.monotonic()<deadline and parent.poll() is None:
                time.sleep(.05)
            self.assertTrue(pidfile.exists())
            kernel=ctypes.WinDLL('kernel32',use_last_error=True)
            kernel.OpenProcess.argtypes=[wintypes.DWORD,wintypes.BOOL,wintypes.DWORD]
            kernel.OpenProcess.restype=wintypes.HANDLE
            kernel.WaitForSingleObject.argtypes=[wintypes.HANDLE,wintypes.DWORD]
            kernel.CloseHandle.argtypes=[wintypes.HANDLE]
            handle=kernel.OpenProcess(0x100000,False,int(pidfile.read_text()))
            self.assertTrue(handle)
            try:
                parent.kill()
                parent.wait(timeout=5)
                self.assertEqual(kernel.WaitForSingleObject(handle,3000),0)
            finally:
                kernel.CloseHandle(handle)
        finally:
            if parent.poll() is None:
                parent.kill()
            parent.communicate(timeout=5)


if __name__ == '__main__':
    unittest.main()
