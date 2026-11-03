import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

from collect import reconcile, run_process
from supervisor import Boundary, Unavailable
from report import summarize

REQUEST = b'{"jsonrpc":"2.0","id":1,"method":"ping","secret":"private-source"}\n'
RESPONSE = '{"jsonrpc":"2.0","id":1,"result":{}}'


def event(kind, outcome=None):
    return dict(schema_version=1, session_id='s', request_id='1', tool='check', classification='probe',
                event=kind, outcome=outcome, duration_ns=1 if kind == 'finish' else None,
                response_bytes=1 if kind == 'finish' else None)


class CollectorTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        try:
            boundary = Boundary()
        except Unavailable:
            cls.authority = False
        else:
            boundary.close()
            cls.authority = True

    def setUp(self):
        if not self.authority and self._testMethodName not in (
                'test_reconcile', 'test_unsupported_platform_never_launches_worker',
                'test_no_authority_never_launches_worker', 'test_namespace_failure_never_executes_worker'):
            self.skipTest('host cgroup/namespace authority unavailable; no worker launched')

    def test_no_authority_never_launches_worker(self):
        with patch('collect.Boundary', side_effect=Unavailable('no authority')), patch('collect.subprocess.Popen') as launch:
            self.assertEqual('unsupported', self.worker('pass')['outcome'])
            launch.assert_not_called()
        with patch('supervisor.os.geteuid', return_value=1000), patch('collect.subprocess.Popen') as launch:
            self.assertEqual('unsupported', self.worker('pass')['outcome'])
            launch.assert_not_called()

    def test_namespace_failure_never_executes_worker(self):
        from supervisor import namespace_init
        read_fd, write_fd = os.pipe()
        try:
            with patch('supervisor.syscall', side_effect=PermissionError('namespace denied')), \
                    patch('supervisor.subprocess.Popen') as launch, \
                    patch('supervisor.os._exit', side_effect=RuntimeError('exit intercepted')):
                with self.assertRaisesRegex(RuntimeError, 'exit intercepted'):
                    namespace_init(['worker-must-not-execute'], {}, 12345, b'', write_fd)
                launch.assert_not_called()
            os.close(write_fd)
            write_fd = None
            self.assertEqual(b'"unsupported"', os.read(read_fd, 100))
        finally:
            os.close(read_fd)
            if write_fd is not None:
                os.close(write_fd)

    def worker(self, code, **limits):
        return run_process([sys.executable, '-c', code], {}, REQUEST, limits)

    def test_success_invalid_truncated_stray_and_privacy(self):
        good = self.worker('print(' + repr(RESPONSE) + ')')
        self.assertEqual('success', good['outcome'])
        self.assertNotIn('private-source', json.dumps(good))
        self.assertIsNone(good['cpu_ns'])
        self.assertIsNone(good['peak_rss_bytes'])
        self.assertEqual('worker process tree', good['resource_scope'])
        self.assertTrue(good['resource_reason'])
        self.assertGreater(good['wall_ns'], 0)
        for code in ('print("stray")', 'print("{}")', 'print(' + repr(RESPONSE) + ', end="")',
                     'print(' + repr(RESPONSE) + '); print("stray")', 'pass'):
            with self.subTest(code=code):
                self.assertEqual('protocol_error', self.worker(code)['outcome'])
        self.assertEqual('observer_failure', self.worker('print(' + repr(RESPONSE) + ')', output_bytes=2)['outcome'])

    def test_startup_exit_timeout_cancel(self):
        self.assertEqual('startup_failure', run_process(['/nonexistent/collector-worker'], {}, REQUEST, {})['outcome'])
        self.assertEqual('crash', self.worker('raise SystemExit(4)')['outcome'])
        self.assertEqual('timeout', self.worker('import time; time.sleep(5)', timeout=.1)['outcome'])
        self.assertEqual('cancelled', self.worker('import time; time.sleep(5)', cancel_after=.1)['outcome'])

    def test_reconcile(self):
        start, finish = event('start'), event('finish', 'success')
        for events, status, outcome in [([start, finish], 0, 'success'), ([start], 0, 'observer_failure'),
                                        ([start, finish, finish], 0, 'observer_failure'),
                                        ([event('cancel_requested')], 0, 'success'),
                                        ([event('cancel_requested')], 'cancelled', 'cancelled'),
                                        ([start], 'timeout', 'timeout'),
                                        ([start, event('finish', 'tool_error')], 0, 'tool_error')]:
            with self.subTest(outcome=outcome):
                self.assertEqual(outcome, reconcile(events, status)['outcome'])

    def test_missing_and_invalid_trace_are_observer_failures(self):
        request = b'{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"medaka_fmt","arguments":{"source":"secret"}}}\n'
        response = 'print(' + repr(RESPONSE) + ')'
        for code in (response, 'import os; open(os.environ["MEDAKA_MCP_TRACE"], "w").write("bad\\n"); ' + response):
            run = run_process([sys.executable, '-c', code], {}, request, {})
            self.assertEqual('observer_failure', run['outcome'])
            self.assertNotIn('secret', json.dumps(run))

    def test_cleanup_does_not_kill_unrelated_process(self):
        unrelated = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(5)'])
        with tempfile.TemporaryDirectory() as directory:
            marker = str(Path(directory) / 'survived')
            Path(marker).touch(mode=0o666)
            os.chmod(marker, 0o666)
            os.chmod(directory, 0o755)
            child = 'import pathlib,time; time.sleep(.6); pathlib.Path(' + repr(marker) + ').write_text("escaped")'
            code = 'import subprocess,sys,time; subprocess.Popen([sys.executable,"-c",' + repr(child) + ']); time.sleep(5)'
            try:
                self.assertEqual('timeout', self.worker(code, timeout=.2)['outcome'])
                self.assertIsNone(unrelated.poll())
                time.sleep(.8)
                self.assertEqual('', Path(marker).read_text())
            finally:
                unrelated.kill()
                unrelated.wait()

    @unittest.skipUnless(sys.platform == 'linux', 'Linux subreaper regression')
    def test_detached_double_fork_cleanup_and_unrelated_reaping(self):
        unrelated = subprocess.Popen([sys.executable, '-c', 'import sys; sys.stdin.read(); raise SystemExit(37)'], stdin=subprocess.PIPE)
        try:
            for ending, limits, expected in (
                ('time.sleep(5)', {'timeout': .4}, 'timeout'),
                ('time.sleep(5)', {'cancel_after': .4}, 'cancelled'),
                ('print(' + repr(RESPONSE) + ')', {}, 'success'),
                ('raise SystemExit(4)', {}, 'crash'),
                ('print("invalid")', {}, 'protocol_error'),
                ('exec(' + repr('import os,signal\nfor sig in (signal.SIGKILL,signal.SIGSTOP):\n try: os.kill(os.getppid(),sig)\n except PermissionError: pass\nprint(' + repr(RESPONSE) + ')') + ')', {}, 'success'),
            ):
                with self.subTest(outcome=expected), tempfile.TemporaryDirectory() as directory:
                    marker = str(Path(directory) / 'escaped')
                    Path(marker).touch(mode=0o666)
                    os.chmod(marker, 0o666)
                    os.chmod(directory, 0o755)
                    child = ('import os,pathlib,time; os.setsid(); '
                             'pid=os.fork(); '
                             'os._exit(0) if pid else None; '
                             'time.sleep(1); pathlib.Path(' + repr(marker) + ').write_text("escaped")')
                    code = ('import subprocess,sys,time; '
                            'p=subprocess.Popen([sys.executable,"-c",' + repr(child) + ']); '
                            'p.wait(); ' + ending)
                    self.assertEqual(expected, self.worker(code, **limits)['outcome'])
                    self.assertIsNone(unrelated.poll())
                    time.sleep(1.2)
                    self.assertEqual('', Path(marker).read_text())
            unrelated.communicate(b'done', timeout=7)
            self.assertEqual(37, unrelated.returncode)
        finally:
            if unrelated.poll() is None:
                unrelated.kill()
                unrelated.wait()

    def test_unsupported_platform_never_launches_worker(self):
        with patch('collect.sys.platform', 'darwin'), patch('collect.subprocess.Popen') as launch:
            self.assertEqual('unsupported', self.worker('pass')['outcome'])
            launch.assert_not_called()

    def test_workspace_and_environment_are_isolated(self):
        task = json.loads((Path(__file__).parent / 'tasks.json').read_text())[0]
        responses = []
        code = """import os,json,pathlib
print(json.dumps({'jsonrpc':'2.0','id':1,'result':{'cwd':os.getcwd(), 'secret':os.getenv('COLLECTOR_SECRET'), 'files':sorted(str(p) for p in pathlib.Path('.').rglob('*') if p.is_file()), 'prompt':pathlib.Path('PROMPT.txt').read_text()}}))"""
        os.environ['COLLECTOR_SECRET'] = 'hidden'
        try:
            run = self.worker(code, task=task, response_callback=responses.extend)
        finally:
            del os.environ['COLLECTOR_SECRET']
        self.assertEqual('success', run['outcome'])
        result = responses[0]['result']
        self.assertNotEqual(os.getcwd(), result['cwd'])
        self.assertIsNone(result['secret'])
        self.assertEqual(set(task['files']) | {'PROMPT.txt'}, set(result['files']))
        self.assertNotIn(task['rubric'][0]['answer'], result['prompt'])

    def test_supervisor_death_with_missing_response_is_observer_failure(self):
        popen = subprocess.Popen
        def killed(*args, **kwargs):
            supervisor = popen(*args, **kwargs)
            supervisor.kill()
            return supervisor
        with patch('collect.subprocess.Popen', side_effect=killed):
            self.assertEqual('observer_failure', self.worker('pass')['outcome'])

    def test_signal_and_escape_attempts_have_no_authority(self):
        code = """import os,pathlib,signal,json
blocked=[]
for sig in (signal.SIGKILL, signal.SIGSTOP, signal.SIGTERM):
    try:
        os.kill(os.getppid(), sig)
    except PermissionError:
        blocked.append(int(sig))
try:
    pathlib.Path('/sys/fs/cgroup/cgroup.procs').write_text(str(os.getpid()))
except OSError:
    blocked.append('escape')
try:
    os.setuid(0)
except PermissionError:
    blocked.append('root')
caps=[line for line in pathlib.Path('/proc/self/status').read_text().splitlines() if line.startswith(('CapEff:', 'CapPrm:', 'CapAmb:'))]
print(json.dumps({'jsonrpc':'2.0','id':1,'result':{'blocked':blocked,'pid':os.getpid(),'parent':os.getppid(),'uid':os.getuid(),'caps':caps}}))
"""
        responses = []
        self.assertEqual('success', self.worker(code, response_callback=responses.extend)['outcome'])
        result = responses[0]['result']
        self.assertEqual([9, 19, 15, 'escape', 'root'], result['blocked'])
        self.assertEqual(1, result['parent'])
        self.assertNotEqual(0, result['uid'])
        self.assertTrue(all(int(line.split()[1], 16) == 0 for line in result['caps']))

    def test_stopped_and_killed_authority_deadline_cleanup(self):
        popen = subprocess.Popen
        for sig, expected in ((19, 'timeout'), (9, 'observer_failure')):
            with self.subTest(signal=sig), tempfile.TemporaryDirectory() as directory:
                marker = Path(directory) / 'survived'
                marker.touch(mode=0o666)
                os.chmod(directory, 0o755)
                os.chmod(marker, 0o666)
                child = 'import pathlib,time; time.sleep(.8); pathlib.Path(' + repr(str(marker)) + ').write_text("escaped")'
                worker = 'import subprocess,sys,time; subprocess.Popen([sys.executable,"-c",' + repr(child) + '],start_new_session=True); time.sleep(5)'
                launched, boundaries, members = [], [], []
                def track_boundary():
                    boundary = Boundary()
                    boundaries.append((boundary, boundary.path))
                    return boundary
                def sabotage(*args, **kwargs):
                    supervisor = popen(*args, **kwargs)
                    launched.append(supervisor)
                    return supervisor
                # Sabotage from the trusted observer after the worker has entered its namespace.
                import threading
                def stop():
                    while not launched:
                        time.sleep(.005)
                    time.sleep(.2)
                    members.extend(map(int, (boundaries[0][1] / 'cgroup.procs').read_text().split()))
                    os.kill(launched[0].pid, sig)
                thread = threading.Thread(target=stop)
                thread.start()
                with patch('collect.Boundary', side_effect=track_boundary), patch('collect.subprocess.Popen', side_effect=sabotage):
                    self.assertEqual(expected, self.worker(worker, timeout=.4)['outcome'])
                thread.join()
                self.assertIsNotNone(launched[0].poll())
                self.assertGreaterEqual(len(members), 4)
                self.assertFalse(boundaries[0][1].exists())
                self.assertEqual([], [pid for pid in members if Path(f'/proc/{pid}').exists()])
                time.sleep(1)
                self.assertEqual('', marker.read_text())

    def test_concurrent_runs_keep_separate_boundaries(self):
        from concurrent.futures import ThreadPoolExecutor
        with tempfile.TemporaryDirectory() as directory:
            os.chmod(directory, 0o755)
            markers = [Path(directory) / str(i) for i in range(6)]
            codes = []
            for marker in markers:
                marker.touch()
                os.chmod(marker, 0o666)
                child = 'import os,pathlib,time; os.setsid(); os.fork(); time.sleep(.6); pathlib.Path(' + repr(str(marker)) + ').write_text("escaped")'
                codes.append('import subprocess,sys,time; subprocess.Popen([sys.executable,"-c",' + repr(child) + ']); time.sleep(.1); print(' + repr(RESPONSE) + ')')
            with ThreadPoolExecutor(max_workers=3) as executor:
                runs = list(executor.map(self.worker, codes))
            self.assertEqual(['success'] * 6, [r['outcome'] for r in runs])
            time.sleep(.8)
            self.assertEqual([''] * 6, [p.read_text() for p in markers])

    def test_callback_failure_is_observer_failure(self):
        def fail(_):
            raise RuntimeError('grader failed')
        self.assertEqual('observer_failure', self.worker('print(' + repr(RESPONSE) + ')', response_callback=fail)['outcome'])

    def test_pairs_match_and_extra_calls_are_rejected(self):
        start, finish = event('start'), event('finish', 'success')
        for field in ('tool', 'classification'):
            bad = dict(finish, **{field: 'other' if field == 'tool' else 'organic'})
            self.assertEqual('observer_failure', reconcile([start, bad], 0)['outcome'])
        request = b'{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"medaka_fmt"}}\n'
        start = dict(start, session_id='collector', request_id='0', tool='medaka_fmt')
        finish = dict(finish, session_id='collector', request_id='0', tool='medaka_fmt')
        extra_start = dict(start, request_id='1', tool='forged-extra')
        extra_finish = dict(finish, request_id='1', tool='forged-extra')
        for events in ([start, finish, extra_start, extra_finish], [dict(start, tool='medaka_check'), dict(finish, tool='medaka_check')],
                       [start, finish, dict(start, event='cancel_requested')], [start]):
            code = 'import os,json; open(os.environ["MEDAKA_MCP_TRACE"],"w").write(' + repr(''.join(json.dumps(e) + '\n' for e in events)) + '); print(' + repr(RESPONSE) + ')'
            self.assertEqual('observer_failure', run_process([sys.executable, '-c', code], {}, request, {})['outcome'])

    def test_serial_lifecycle_full_process(self):
        requests = b''.join(json.dumps({'jsonrpc': '2.0', 'id': i, 'method': 'tools/call',
                                        'params': {'name': 'medaka_fmt'}}).encode() + b'\n' for i in (1, 2))
        starts = [dict(event('start'), session_id='collector', request_id=str(i), tool='medaka_fmt') for i in range(2)]
        finishes = [dict(event('finish', 'success'), session_id='collector', request_id=str(i), tool='medaka_fmt') for i in range(2)]
        responses = ''.join(json.dumps({'jsonrpc': '2.0', 'id': i, 'result': {}}) + '\n' for i in (1, 2))
        for events, expected in (([starts[0], starts[1], finishes[0], finishes[1]], 'observer_failure'),
                                 ([starts[0], finishes[0], starts[1], finishes[1]], 'success')):
            trace = ''.join(json.dumps(e) + '\n' for e in events)
            code = 'import os; open(os.environ["MEDAKA_MCP_TRACE"],"w").write(' + repr(trace) + '); print(' + repr(responses) + ', end="")'
            self.assertEqual(expected, run_process([sys.executable, '-c', code], {}, requests, {})['outcome'])

    def test_cancel_order_full_process(self):
        requests = (b'{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"medaka_fmt"}}\n'
                    b'{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1}}\n')
        start = dict(event('start'), session_id='collector', request_id='0', tool='medaka_fmt')
        finish = dict(event('finish', 'success'), session_id='collector', request_id='0', tool='medaka_fmt')
        cancel = dict(event('cancel_requested'), session_id='collector', request_id='1', tool='protocol')
        for events, expected in (([start, cancel, finish], 'observer_failure'),
                                 ([start, finish, cancel], 'success')):
            trace = ''.join(json.dumps(e) + '\n' for e in events)
            code = 'import os; open(os.environ["MEDAKA_MCP_TRACE"],"w").write(' + repr(trace) + '); print(' + repr(RESPONSE) + ')'
            self.assertEqual(expected, run_process([sys.executable, '-c', code], {}, requests, {})['outcome'])

    def test_cancel_order_across_idle_boundary(self):
        call = lambda i: {'jsonrpc': '2.0', 'id': i, 'method': 'tools/call', 'params': {'name': 'medaka_fmt'}}
        cancel_request = {'jsonrpc': '2.0', 'method': 'notifications/cancelled', 'params': {'requestId': 1}}
        start = lambda i: dict(event('start'), session_id='collector', request_id=str(i), tool='medaka_fmt')
        finish = lambda i: dict(event('finish', 'success'), session_id='collector', request_id=str(i), tool='medaka_fmt')
        cancel = lambda i: dict(event('cancel_requested'), session_id='collector', request_id=str(i), tool='protocol')
        cases = [
            ([call(1), call(2), cancel_request], [start(0), finish(0), cancel(2), start(1), finish(1)], 'observer_failure'),
            ([call(1), call(2), cancel_request], [start(0), finish(0), start(1), finish(1), cancel(2)], 'success'),
            ([cancel_request, call(1)], [start(1), finish(1), cancel(0)], 'observer_failure'),
            ([cancel_request, call(1)], [cancel(0), start(1), finish(1)], 'success'),
        ]
        for requests, events, expected in cases:
            transcript = ''.join(json.dumps(r) + '\n' for r in requests).encode()
            responses = ''.join(json.dumps({'jsonrpc': '2.0', 'id': r['id'], 'result': {}}) + '\n' for r in requests if 'id' in r)
            trace = ''.join(json.dumps(e) + '\n' for e in events)
            code = 'import os; open(os.environ["MEDAKA_MCP_TRACE"],"w").write(' + repr(trace) + '); print(' + repr(responses) + ', end="")'
            self.assertEqual(expected, run_process([sys.executable, '-c', code], {}, transcript, {})['outcome'])

    def test_materialization_failure_returns_run(self):
        task = json.loads((Path(__file__).parent / 'tasks.json').read_text())[0]
        task['files'] = {'PROMPT.txt/child': 'x'}
        self.assertEqual('observer_failure', self.worker('pass', task=task)['outcome'])
        task['files'] = {'valid/file.mdk': 'x'}
        write = Path.write_text
        def failed_materialization(path, *args, **kwargs):
            if path.name == 'file.mdk':
                raise OSError('write failed')
            return write(path, *args, **kwargs)
        with patch.object(Path, 'write_text', new=failed_materialization):
            self.assertEqual('observer_failure', self.worker('pass', task=task)['outcome'])

    def test_resource_report_values_and_unavailability(self):
        from schema import validate_run
        run = self.worker('print(' + repr(RESPONSE) + ')')
        measured = dict(run, cpu_ns=123, peak_rss_bytes=456, resource_scope='worker process',
                        resource_reason={'cpu_ns': None, 'peak_rss_bytes': None})
        validate_run(measured)
        metrics = summarize([run, measured])['metrics']
        self.assertEqual(run['wall_ns'], metrics['wall_ns'][0]['value'])
        self.assertEqual({'value': 123, 'scope': 'worker process', 'reason': None}, metrics['cpu_ns'][1])
        self.assertEqual(456, metrics['peak_rss_bytes'][1]['value'])
        self.assertIsNone(metrics['cpu_ns'][0]['value'])
        self.assertTrue(metrics['cpu_ns'][0]['reason'])
        self.assertTrue(metrics['peak_rss_bytes'][0]['reason'])
        with self.assertRaises(ValueError):
            validate_run(dict(measured, resource_reason={'cpu_ns': 'unavailable', 'peak_rss_bytes': None}))

    def test_summary(self):
        run = self.worker('print(' + repr(RESPONSE) + ')')
        self.assertEqual({'success': 1}, summarize([run])['outcomes'])


if __name__ == '__main__':
    unittest.main()
