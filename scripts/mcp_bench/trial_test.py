import json
from pathlib import Path
import unittest

import trials


REF = 'sha256:' + 'a' * 64
CONFIG = {'run_id': 'synthetic', 'model': 'model', 'effort': 'high', 'harness_version': 'test'}
TASKS = json.loads((Path(__file__).parent / 'tasks.json').read_text())


def attempt(outcome='unknown'):
    return {'outcome': outcome, 'answer': None, 'events': [{'tool': 'shell', 'request': b'\x00\xff',
            'result': b'\xff\n'}], 'usage': {'input_tokens': 12, 'output_tokens': None,
            'read_count': None, 'complete': False}, 'evidence_ref': REF}


def evidence(task):
    return {group: {item['id']: {'passed': True, 'basis': item['basis'], 'evidence_ref': REF}
                    for item in task[source]}
            for group, source in (('criteria', 'rubric'), ('controls', 'controls'))}


class TrialTests(unittest.TestCase):
    def test_identities_and_export_boundary(self):
        identities = set()
        for task in TASKS:
            for arm in trials.ARMS:
                spec = trials.trial_manifest(task, arm, CONFIG)
                identities.add((spec['task_id'], spec['arm']))
                self.assertEqual((spec['deadline_seconds'], spec['tool_call_limit']), (600, 30))
                self.assertEqual(spec['prompt'], task['prompt'])
                self.assertEqual(spec['controls'], [{'id': c['id'], 'question': c['question']} for c in task['controls']])
                self.assertNotIn('rubric', spec)
                self.assertTrue(all(set(c) == {'id', 'question'} for c in spec['controls']))
                spec['files'].clear()
                self.assertTrue(trials.trial_manifest(task, arm, CONFIG)['files'])
        self.assertEqual(len(identities), 12)
        with self.assertRaises(ValueError):
            trials.trial_manifest(TASKS[0], 'MCP', CONFIG)

    def test_import_preserves_observations_and_retries(self):
        spec = trials.trial_manifest(TASKS[0], 'mcp', CONFIG)
        first = attempt('infrastructure_error')
        second = attempt('timeout')
        run = trials.import_transcript(spec, {'attempts': [first, second]})
        first['events'][0]['result'] = b'changed'
        self.assertEqual(run['attempts'][0]['events'][0]['result'], b'\xff\n')
        self.assertEqual(run['attempts'][0]['events'][0]['request'], b'\x00\xff')
        self.assertEqual(run['attempts'][0]['usage'], {'input_tokens': 12, 'output_tokens': None,
                                                        'read_count': None, 'complete': False})
        self.assertEqual(run['attempts'][1]['outcome'], 'timeout')
        self.assertEqual(run['attempts'][0]['evidence_ref'], REF)
        for outcome in ('unsupported', 'tool_error', 'protocol_error', 'unknown', 'timeout'):
            self.assertEqual(trials.import_transcript(spec, {'attempts': [attempt(outcome)]})['attempts'][0]['outcome'], outcome)
            with self.assertRaises(ValueError):
                trials.import_transcript(spec, {'attempts': [attempt(outcome), attempt()]})
        with self.assertRaises(ValueError):
            trials.import_transcript(spec, {'attempts': [attempt('infrastructure_error')] * 3})
        bad = attempt(); bad['evidence_ref'] = 'mutable/path'
        with self.assertRaises(ValueError):
            trials.import_transcript(spec, {'attempts': [bad]})

    def test_independent_grading_and_denominators(self):
        task = TASKS[0]
        judgments = evidence(task)
        good = trials.grade(task, 'paraphrased answer', judgments)
        self.assertEqual((good['outcome'], good['attempted'], good['completed'], good['passed']), ('success', 2, 2, 2))
        judgments['controls'][task['controls'][0]['id']]['passed'] = False
        self.assertEqual(trials.grade(task, 'answer', judgments)['outcome'], 'incorrect')
        judgments['controls'].clear()
        missing = trials.grade(task, 'answer', judgments)
        self.assertEqual((missing['outcome'], missing['completed'], missing['skipped']), ('unknown', 1, 1))
        self.assertEqual(trials.grade(task, None, evidence(task))['outcome'], 'unknown')
        judgments = evidence(task)
        judgments['criteria'][task['rubric'][0]['id']]['basis'] = 'MCP response'
        with self.assertRaises(ValueError):
            trials.grade(task, 'answer', judgments)
        judgments = evidence(task)
        judgments['controls']['extra'] = judgments['controls'][task['controls'][0]['id']]
        with self.assertRaises(ValueError):
            trials.grade(task, 'answer', judgments)


if __name__ == '__main__':
    unittest.main()
