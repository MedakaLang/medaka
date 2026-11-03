import json
import unittest
from unittest.mock import patch

import operations
from report import compact_measurements, measurement_summary


class OperationTests(unittest.TestCase):
    def test_compact_measurements_and_signed_matched_deltas(self):
        samples = []
        for arm, latency in [('trace-off', 20), ('trace-on', 10)]:
            samples.append({'record': {'run_id': 'fake-0', 'arm': arm, 'outcome': 'success'},
                            'exchanges': [{'id': 0, 'received_ns': 2}, {'id': 1, 'round_trip_ns': latency}],
                            'responses': [{'jsonrpc': '2.0', 'id': 1, 'result': {'private': '/secret/source'}}],
                            'resources': [{'cpu_ns': 3, 'peak_memory_charge_bytes': 4}]})
        document = compact_measurements({'samples': samples}, {'synthetic': True})
        self.assertNotIn('/secret/source', json.dumps(document))
        self.assertEqual({'samples': 1, 'min': -10, 'max': -10},
                         measurement_summary(document)['paired_trace_delta_ns'])
        self.assertEqual({'samples': 1, 'min': 10, 'max': 10},
                         measurement_summary(document)['paired_absolute_trace_delta_ns'])
        with self.assertRaisesRegex(ValueError, 'missing paired arm'):
            measurement_summary({'samples': samples[:1]})
        samples[0]['resources'][0]['peak_memory_charge_bytes'] = None
        with self.assertRaisesRegex(ValueError, 'missing measurement'):
            measurement_summary({'samples': samples})

    def test_matched_order_and_changed_source_requests(self):
        tasks = json.loads(operations.Path(operations.__file__).with_name('tasks.json').read_text())
        seen = []
        def fake(case, arm, index):
            seen.append((case['id'], arm['name'], index, arm['binary']))
            if case['id'] == 'changed-source':
                self.assertEqual(['initialize', 'tools/call', 'tools/call'],
                                 [request['method'] for request in case['requests']])
                self.assertEqual(case['requests'][1]['params'], case['requests'][2]['params'])
            return {'synthetic': True}
        with patch('operations.measure_interactive_case', fake):
            result = operations.measure_matched('/same-root', tasks, 5)
        self.assertEqual(80, len(result['samples']))
        self.assertEqual(['trace-off', 'trace-on', 'trace-on', 'trace-off', 'trace-off',
                          'trace-on', 'trace-on', 'trace-off', 'trace-off', 'trace-on'],
                         [row[1] for row in seen[:10]])
        self.assertEqual({'/same-root/medaka'}, {row[3] for row in seen if row[0] != 'missing-binary'})

    def test_repetitions_preserve_order_and_callbacks(self):
        seen = []
        def fake(command, environment, transcript, limits):
            seen.append((command, json.loads(transcript), limits['run_id']))
            limits['timing_callback']([12])
            limits['response_callback']([{'id': 1}])
            return {'outcome': 'success'}
        case = {'id': 'example', 'task': {}, 'requests': [{'id': 1}]}
        with patch('operations.run_process', fake):
            results = operations.measure_case(case, {'name': 'plain', 'binary': '/compiler', 'trace': False}, 5)
        self.assertEqual([item[2] for item in seen], [f'example-{i}' for i in range(5)])
        self.assertEqual([item['arrival_ns'] for item in results], [[12]] * 5)
        self.assertEqual([item['responses'] for item in results], [[{'id': 1}]] * 5)
        with self.assertRaises(ValueError):
            operations.measure_case(case, {'name': 'plain', 'binary': '/compiler', 'trace': False}, 0)


if __name__ == '__main__':
    unittest.main()
