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
from report import summarize

REQUEST = b'{"jsonrpc":"2.0","id":1,"method":"ping","secret":"private-source"}\n'
RESPONSE = '{"jsonrpc":"2.0","id":1,"result":{}}'


def event(kind, outcome=None):
    return dict(schema_version=1, session_id='s', request_id='1', tool='check', classification='probe',
                event=kind, outcome=outcome, duration_ns=1 if kind == 'finish' else None,
                response_bytes=1 if kind == 'finish' else None)


class CollectorTest(unittest.TestCase):
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
            child = 'import pathlib,time; time.sleep(.6); pathlib.Path(' + repr(marker) + ').touch()'
            code = 'import subprocess,sys,time; subprocess.Popen([sys.executable,"-c",' + repr(child) + ']); time.sleep(5)'
            try:
                self.assertEqual('timeout', self.worker(code, timeout=.2)['outcome'])
                self.assertIsNone(unrelated.poll())
                time.sleep(.8)
                self.assertFalse(Path(marker).exists())
            finally:
                unrelated.kill()
                unrelated.wait()

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

    def test_materialization_failure_returns_run(self):
        task = json.loads((Path(__file__).parent / 'tasks.json').read_text())[0]
        task['files'] = {'PROMPT.txt/child': 'x'}
        self.assertEqual('observer_failure', self.worker('pass', task=task)['outcome'])
        task['files'] = {'valid/file.mdk': 'x'}
        with patch.object(Path, 'write_text', side_effect=OSError('write failed')):
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
