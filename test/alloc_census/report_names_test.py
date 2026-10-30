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
