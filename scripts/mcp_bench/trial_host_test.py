"""Deterministic controls; privileged boundary controls are explicitly opt-in."""
import base64
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

from build_cli_artifact import fingerprint
from trial_host import Budget, InfrastructureError, Journal, Sandbox, launch, materialize, run_with_retry, verify_distribution


class HostTests(unittest.TestCase):
    def test_missing_authority_returns_before_agent_or_auth_access(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            artifact = root / 'artifact'
            artifact.mkdir()
            for name in ('medaka', 'medaka_emitter', 'runtime/medaka_rt.c', 'stdlib/core.mdk', 'stdlib/runtime.mdk'):
                path = artifact / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('synthetic')
            spec = {'model': 'gpt-6.1-terra', 'effort': 'high', 'arm': 'shell-only',
                    'deadline_seconds': 600, 'tool_call_limit': 30, 'files': {}, 'prompt': 'synthetic', 'controls': []}
            with (patch('trial_host.subprocess.check_output', return_value='codex-cli 0.166.0'),
                  patch('trial_host.subprocess.run', side_effect=lambda command, **kw: Path(command[-1]).mkdir()),
                  patch('trial_host.Sandbox.verify', side_effect=InfrastructureError('missing namespace authority')),
                  patch('trial_host.subprocess.Popen') as popen):
                result = launch(spec, root / 'run', artifact, fingerprint(artifact), None, None,
                                root / 'nonexistent-auth')
            popen.assert_not_called()
            self.assertEqual('infrastructure_error', result['outcome'])
            self.assertEqual(0, result['attempted'])
            self.assertIsNone(result['usage'])
            self.assertIn('missing namespace authority', result['error'])

    def test_concurrent_attempts_all_recorded_before_effect(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'admissions.jsonl'
            journal = Journal(path)
            budget = Budget(journal)
            barrier = threading.Barrier(64)

            def attempt(index):
                barrier.wait()
                return budget.reserve('shell', str(index).encode())['admitted']

            with ThreadPoolExecutor(max_workers=64) as pool:
                effects = list(pool.map(attempt, range(64)))
            journal.close()
            records = [json.loads(line) for line in path.read_text().splitlines()]
            self.assertEqual((64, 30, 34), (budget.attempted, budget.admitted, budget.denied))
            self.assertEqual(30, sum(effects))
            self.assertEqual(list(range(1, 65)), [r['sequence'] for r in records])
            self.assertEqual(set(range(64)), {int(base64.b64decode(r['request_b64'])) for r in records})

    def test_deadline_and_closed_budget_deny_before_dispatch(self):
        with tempfile.TemporaryDirectory() as directory:
            journal = Journal(Path(directory) / 'log')
            now = [100.]
            budget = Budget(journal, seconds=2, clock=lambda: now[0])
            self.assertTrue(budget.reserve('shell', b'before')['admitted'])
            now[0] = 102.
            self.assertEqual('deadline', budget.reserve('shell', b'at')['denial'])
            now[0] = 101.
            self.assertFalse(budget.reserve('shell', b'after')['admitted'])
            self.assertEqual(1, budget.admitted)
            journal.close()

    def test_only_infrastructure_retries_once_and_retains_first(self):
        for outcome in ('success', 'incorrect', 'timeout', 'cancelled', 'tool_error', 'infrastructure_error'):
            with self.subTest(outcome=outcome), tempfile.TemporaryDirectory() as directory:
                seen = []

                def runner(spec, path):
                    path.mkdir()
                    self.assertFalse((path / 'marker').exists())
                    (path / 'marker').write_text(str(len(seen)))
                    seen.append(path)
                    return {'outcome': outcome, 'attempt': len(seen)}

                root = Path(directory) / 'run'
                attempts = run_with_retry({}, root, runner)
                self.assertEqual(2 if outcome == 'infrastructure_error' else 1, len(attempts))
                self.assertEqual('0', (seen[0] / 'marker').read_text())
                self.assertEqual(attempts, json.loads((root / 'attempts.json').read_text()))

    def test_prelaunch_infrastructure_failure_is_retained(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / 'run'

            def unavailable(spec, path):
                raise InfrastructureError('missing authority')

            attempts = run_with_retry({}, root, unavailable)
            self.assertEqual(2, len(attempts))
            self.assertEqual(attempts[0], json.loads((root / 'attempt-1/attempt.json').read_text()))
            self.assertEqual(attempts[1], json.loads((root / 'attempt-2/attempt.json').read_text()))

    def test_materialization_excludes_host_and_other_workspace(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            first, second = root / 'a', root / 'b'
            first.mkdir()
            second.mkdir()
            materialize({'src/main.mdk': 'main = 3\n'}, first)
            self.assertEqual(['src', 'src/main.mdk'], sorted(str(p.relative_to(first)) for p in first.rglob('*')))
            self.assertEqual([], list(second.iterdir()))
            for path in ('/etc/passwd', '../rubric', '.codex/config.toml'):
                with self.assertRaisesRegex(ValueError, 'unsafe'):
                    materialize({path: 'secret'}, second)

    def test_missing_or_changed_artifact_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'medaka').write_text('changed')
            with self.assertRaisesRegex(InfrastructureError, 'fingerprint'):
                verify_distribution(root, {'medaka': '0' * 64})
            (root / 'medaka').unlink()
            with self.assertRaisesRegex(InfrastructureError, 'distribution'):
                verify_distribution(root, {})


@unittest.skipUnless(os.environ.get('MEDAKA_TRIAL_REQUIRE_AUTHORITY') == '1',
                     'privileged namespace controls require MEDAKA_TRIAL_REQUIRE_AUTHORITY=1')
class NamespaceTests(unittest.TestCase):
    def test_launcher_watchdog_stops_synthetic_appserver_and_descendants(self):
        import subprocess
        import sys
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            artifact = root / 'artifact'
            artifact.mkdir()
            for name in ('medaka', 'medaka_emitter', 'runtime/medaka_rt.c', 'stdlib/core.mdk', 'stdlib/runtime.mdk'):
                path = artifact / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('synthetic artifact, not executed')
            fake = root / 'fake.py'
            fake.write_text('''import json,sys,time
for line in sys.stdin:
    event=json.loads(line)
    method=event.get('method')
    if method=='initialize': result={}
    elif method=='thread/start': result={'thread':{'id':'synthetic-thread'}}
    elif method=='turn/start': result={'turn':{'id':'synthetic-turn'}}
    else: continue
    print(json.dumps({'id':event['id'],'result':result}),flush=True)
    if method=='turn/start':
        command="python3 -c \\"import os,time; from pathlib import Path; p=os.fork(); (os.setsid(),time.sleep(2),Path('/workspace/escaped').write_text('late')) if p==0 else (Path('/workspace/started').write_text('yes'),time.sleep(30))\\""
        print(json.dumps({'id':100,'method':'item/tool/call','params':{'tool':'shell','arguments':{'command':command}}}),flush=True)
''')
            auth = root / 'fake-auth'
            auth.write_text('{}')
            spec = {'model': 'gpt-6.1-terra', 'effort': 'high', 'arm': 'shell-only',
                    'deadline_seconds': 600, 'tool_call_limit': 30, 'files': {}, 'prompt': 'synthetic', 'controls': []}
            popen = subprocess.Popen

            def intercept(command, *args, **kwargs):
                if command == ['codex', 'app-server', '--listen', 'stdio://']:
                    return popen([sys.executable, str(fake)], *args, **kwargs)
                return popen(command, *args, **kwargs)

            with patch('trial_host.subprocess.Popen', side_effect=intercept):
                result = launch(spec, root / 'run', artifact, fingerprint(artifact), None, None, auth, seconds=1)
            self.assertEqual('timeout', result['outcome'])
            self.assertEqual((1, 1, 0), (result['attempted'], result['admitted'], result['denied']))
            self.assertIn('started', result['workspace_files'])
            self.assertNotIn('escaped', result['workspace_files'])
            time.sleep(1.3)
            self.assertFalse((root / 'run/workspace/escaped').exists())
            self.assertIsNone(result['usage'])
            self.assertFalse(result['usage_complete'])

    def test_isolation_network_and_detached_descendant_cleanup(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            workspace, artifact = root / 'workspace', root / 'toolchain'
            workspace.mkdir()
            artifact.mkdir()
            canary = root / 'rubric-credential-other-arm'
            canary.write_text('synthetic private host canary')
            journal = Journal(root / 'log')
            budget = Budget(journal, seconds=10)
            sandbox = Sandbox(workspace, artifact, budget)
            try:
                sandbox.verify()
                code = ('import os,socket; from pathlib import Path; '
                        f'assert not Path({str(canary)!r}).exists(); '
                        'assert not any("KEY" in k or "TOKEN" in k for k in os.environ); '
                        's=socket.socket(); s.settimeout(.1); '
                        's.connect(("1.1.1.1",443))')
                result = sandbox.run(['python3', '-c', code])
                self.assertNotEqual(0, result['exit_code'])
                self.assertIn(b'Network is unreachable', base64.b64decode(result['stderr_b64']))
                code = ('import os,time; from pathlib import Path; p=os.fork(); '
                        '(os.setsid(),time.sleep(.4),Path("/workspace/late").write_text("escaped")) '
                        'if p==0 else time.sleep(10)')
                budget.deadline = time.monotonic() + .15
                with self.assertRaisesRegex(TimeoutError, 'deadline'):
                    sandbox.run(['python3', '-c', code])
                time.sleep(.5)
                self.assertFalse((workspace / 'late').exists())
                self.assertEqual(set(), sandbox.active)
                with self.assertRaisesRegex(TimeoutError, 'closed'):
                    sandbox.spawn(['/bin/true'])
            finally:
                sandbox.stop()
                journal.close()


if __name__ == '__main__':
    unittest.main()
