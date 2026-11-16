import concurrent.futures
import tempfile
import threading
import unittest
from pathlib import Path
import sys
import os
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from https_remote import Queue, api, make_server, execute
from urllib.error import HTTPError


class TransportTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.queue = Queue(str(Path(self.directory.name) / 'jobs.db'))
        self.server = make_server(('127.0.0.1', 0), self.queue, 'a' * 40, {'pc': 'b' * 40, 'other': 'c' * 40})
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
            jobs = list(pool.map(lambda _: api(self.url, 'b' * 40, '/poll', {})['job'], range(12)))
        self.assertEqual(ids, {job['id'] for job in jobs})
        self.assertIsNone(api(self.url, 'b' * 40, '/poll', {})['job'])
        result = {'exit_code': 0, 'stdout': 'test', 'stderr': ''}
        with self.assertRaises(HTTPError) as error:
            api(self.url, 'c' * 40, '/result', {'id': jobs[0]['id'], 'result': result})
        self.assertEqual(error.exception.code, 404)
        for _ in range(2):
            self.assertTrue(api(self.url, 'b' * 40, '/result', {'id': jobs[0]['id'], 'result': result})['ok'])
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

    @unittest.skipUnless(os.name == 'nt', 'Windows PowerShell required')
    def test_parallel_powershell_and_timeout(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(execute, [
                {'script': 'Start-Sleep -Milliseconds 300; Write-Output "one"', 'timeout': 10},
                {'script': 'Write-Output "two"', 'timeout': 10}]))
        self.assertEqual([r['stdout'].strip() for r in results], ['one', 'two'])
        self.assertTrue(all(r['exit_code'] == 0 for r in results))
        self.assertEqual(execute({'script': 'Start-Sleep -Seconds 15', 'timeout': 1})['reason'], 'timeout')


if __name__ == '__main__':
    unittest.main()
