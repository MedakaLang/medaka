import json
import unittest
from unittest.mock import patch

import operations


class OperationTests(unittest.TestCase):
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
