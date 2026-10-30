#!/usr/bin/env python3
"""Controls for the actual census and retain-report routes."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
REPORT = ROOT / 'test/alloc_census/retain_report.py'


def user(module, name):
    logical = 'm' + module.encode().hex() + '__' + name
    return 'mdk.user.' + logical.encode().hex()


def generated(module):
    scope = 'module.' + module.encode().hex()
    return 'mdk.gen.lambda.' + scope.encode().hex() + '..3'


class Reports(unittest.TestCase):
    def test_retain_route_groups_only_valid_descriptors(self):
        module = 'front.λ_!'
        names = [user(module, 'probe'), generated(module), 'mdk_old__probe',
                 user('other', 'probe'), generated(module).replace('lambda', 'bogus'),
                 'mdk.user.6dzz', 'mdk.gen.lambda.00..3']
        with tempfile.TemporaryDirectory() as d:
            p = Path(d)
            (p / 'sites.tsv').write_text('id\tfn\tx\tkind\n' + ''.join(
                f'{i}\t{name}\t-\tCons\n' for i, name in enumerate(names, 1)))
            (p / 'appsites.tsv').write_text('')
            (p / 'retain.out').write_text('census\t1\t1\t1\n' + ''.join(
                f'site\t{i}\t1\t1000000\n' for i in range(1, len(names) + 1)))
            r = subprocess.run(['python3', '-I', str(REPORT), d], text=True, capture_output=True, check=True)
        groups = r.stdout.split('-- by module\n', 1)[1]
        self.assertIn('2.00 MB  28.6%  ' + module, groups)
        for name in ['old', 'other', *names[4:]]:
            self.assertIn('  ' + name + '\n', groups)
        self.assertIn(names[0] + ' Cons', r.stdout)
        self.assertIn(names[1] + ' Cons', r.stdout)

    def test_dispatch_census_and_classifier_controls(self):
        script = (ROOT / 'test/o2_survivor_census.sh').read_text()
        fixture = 'interface Metric a where\n  measure : a -> Int\n\ndata T0 = MkT0 Int\nimpl Metric T0 where\n  measure (MkT0 x) = x + 0\n\ndata T1 = MkT1 Int\nimpl Metric T1 where\n  measure (MkT1 x) = x + 1\n\ndata T2 = MkT2 Int\nimpl Metric T2 where\n  measure (MkT2 x) = x + 2\n\ndata T3 = MkT3 Int\nimpl Metric T3 where\n  measure (MkT3 x) = x + 3\n\nprobe : Metric a => a -> a -> Int\nprobe x y = measure x + measure y\nmain = println (probe (MkT0 10) (MkT0 20))\n'
        with tempfile.TemporaryDirectory() as d:
            p = Path(d)
            (p / 'dispatch_probe.mdk').write_text(fixture)
            script = script.replace('ROOT="$(cd "$(dirname "$0")/.." && pwd)"',
                                    'ROOT="' + str(ROOT) + '"')
            script = script.replace('CORPUS="$ROOT/test/o2_survivor_fixtures"',
                                    'CORPUS="' + d + '"')
            runner = p / 'census.sh'
            runner.write_text(script)
            result = subprocess.run(['sh', str(runner)], text=True, capture_output=True, check=True)
            def check_dispatch(output):
                section = output.split('OPAQUE_CALL survives:', 1)[1].split('ALLOCATION:', 1)[0]
                lines = [line for line in section.splitlines() if '@mdk.dispatch..6d656173757265.0.1.1(' in line]
                self.assertEqual(2, len(lines), output)
                self.assertIn('@mdk_int_overflow_at(', section)
            check_dispatch(result.stdout)
            self.assertIn('ALLOCATION: none', result.stdout)
            self.assertIn('LOAD: 0 total', result.stdout)
            self.assertIn('TAG_ARITH: 3 op(s)', result.stdout)
            self.assertIn('0 BUILD_FAILED, 0 ELIMINATED', result.stdout)
            with self.assertRaises(AssertionError):
                check_dispatch(result.stdout.replace('@mdk.dispatch.', '@hidden.dispatch.', 1))

        assignment = next(line for line in script.splitlines() if line.strip().startswith('opaque='))
        def classify(body):
            r = subprocess.run(['sh', '-c', assignment + '\nprintf "%s\\n" "$opaque"'],
                               env=dict(os.environ, body=body), text=True, capture_output=True, check=True)
            return r.stdout.strip()
        self.assertEqual('', classify('  call i64 @mdk.user.6162()'))
        self.assertEqual('', classify('  call ptr @GC_malloc(i64 8)\n  call ptr @mdk_alloc(i64 8)'))
        self.assertIn('@mdk_int_overflow_at(', classify('  call void @mdk_int_overflow_at()'))
        self.assertIn('@"mdk.dispatch..6d656173757265.0.1.1"(',
                      classify('  call i64 @"mdk.dispatch..6d656173757265.0.1.1"()'))

    def test_census_and_selector_mutation(self):
        cmd = ['sh', str(ROOT / 'test/o2_survivor_census.sh')]
        normal = subprocess.run(cmd, cwd=ROOT, text=True, capture_output=True, check=True)
        sections = {part.split(' (probe', 1)[0]: part for part in normal.stdout.split('== ')[1:]}
        for name in ('int_add', 'int_sub', 'int_eq', 'int_lt', 'string_eq', 'user_call'):
            self.assertIn('ALLOCATION: none\n  LOAD: 0 total\n', sections[name])
            self.assertIn('TAG_ARITH:', sections[name])
        self.assertIn('-- summary: 8 probe(s), 1 BUILD_FAILED, 1 ELIMINATED --', normal.stdout)
        for name in ('int_add', 'int_sub'):
            self.assertIn('@mdk_int_overflow_at(', sections[name])
            self.assertIn('TAG_ARITH: 3 op(s)', sections[name])
        self.assertIn('@mdk_string_eq(', sections['string_eq'])
        for name in ('int_eq', 'int_lt', 'user_call'):
            self.assertIn('OPAQUE_CALL: none', sections[name])
            self.assertIn('TAG_ARITH: 0 op(s)', sections[name])
        self.assertIn('ELIMINATED', sections['int_add_unreferenced'])
        self.assertIn('unbound variable', sections['build_fail_unbound'])
        env = dict(os.environ, O2_CENSUS_SELECTOR_OVERRIDE='mdk.user.00')
        bad = subprocess.run(cmd, cwd=ROOT, text=True, capture_output=True, check=True, env=env)
        self.assertIn('BUILD_FAILED — selector mismatch', bad.stdout)
        self.assertIn('selector mismatch:', bad.stderr)
        self.assertNotIn('ELIMINATED', bad.stdout.split('== int_add (', 1)[1].split('== ', 1)[0])


if __name__ == '__main__':
    unittest.main()
