import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

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
        for events, status, outcome in [([start, finish], 0, 'success'), ([start], 0, 'crash'),
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

    def test_summary(self):
        run = self.worker('print(' + repr(RESPONSE) + ')')
        self.assertEqual({'success': 1}, summarize([run])['outcomes'])


if __name__ == '__main__':
    unittest.main()
