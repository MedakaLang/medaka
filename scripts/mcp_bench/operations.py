"""Run repeatable MCP operation observations without storing payloads in Runs."""
import json
from copy import deepcopy
from pathlib import Path

from collect import run_process


def measure_case(case, arm, repetitions):
    """Return run records, response-arrival offsets, and private responses in order."""
    if repetitions < 1:
        raise ValueError('repetitions must be positive')
    runs = []
    for index in range(repetitions):
        responses, timings = [], []
        limits = {'run_id': f"{case['id']}-{index}", 'task_id': case['id'],
                  'arm': arm['name'], 'trace': arm['trace'], 'task': case['task'],
                  'response_callback': responses.extend, 'timing_callback': timings.extend}
        transcript = b''.join((json.dumps(request) + '\n').encode() for request in case['requests'])
        record = run_process([arm['binary'], 'mcp'], arm.get('environment', {}), transcript, limits)
        runs.append({'record': record, 'arrival_ns': timings, 'responses': responses})
    return runs


def call(number, tool, arguments):
    return {'jsonrpc': '2.0', 'id': number, 'method': 'tools/call',
            'params': {'name': tool, 'arguments': arguments}}


def cases(tasks, root):
    init = {'jsonrpc': '2.0', 'id': 0, 'method': 'initialize',
            'params': {'protocolVersion': '2024-11-05', 'capabilities': {},
                       'clientInfo': {'name': 'baseline', 'version': '1'}}}
    task = {item['id']: item for item in tasks}
    def case(name, task_id, queries):
        return {'id': name, 'task': task[task_id], 'requests': [init] + queries}
    changed = deepcopy(task['repair-diagnostic'])
    changed['files']['main.mdk'] = 'main = 1 + 2\n'
    return [
        case('import-definition', 'import-definition', [
            call(1, 'medaka_definition', {'file': 'main.mdk', 'line': 2, 'col': 9}),
            call(2, 'medaka_definition', {'file': 'main.mdk', 'line': 2, 'col': 19})]),
        case('shadow-references', 'shadow-references', [
            call(1, 'medaka_references', {'file': 'main.mdk', 'line': 0, 'col': 0}),
            call(2, 'medaka_definition', {'file': 'main.mdk', 'line': 1, 'col': 6})]),
        case('stdlib-filter', 'stdlib-filter', [
            call(1, 'medaka_symbols', {'file': str(Path(root) / 'stdlib/core.mdk')}),
            call(2, 'medaka_symbols', {'file': str(Path(root) / 'stdlib/list.mdk')})]),
        case('repair-diagnostic', 'repair-diagnostic', [
            call(1, 'medaka_check', {'file': 'main.mdk'}),
            call(2, 'medaka_check', {'file': 'incomplete.mdk'}),
            call(3, 'medaka_check', {'source': 'main = 1 + 2'})]),
        {'id': 'changed-source', 'task': changed, 'requests': [init,
            call(1, 'medaka_check', {'file': 'main.mdk'})]},
        case('dispatch', 'dispatch', [
            call(1, 'medaka_type_at', {'file': 'main.mdk', 'line': 9, 'symbol': 'describe'}),
            call(2, 'medaka_check', {'file': 'main.mdk'})]),
        case('worktree-validation', 'worktree-validation', [
            call(1, 'medaka_check', {'source': 'main = 0'})]),
    ]


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument('--baseline-root', required=True)
    parser.add_argument('--instrumented-root', required=True)
    parser.add_argument('--output', required=True)
    options = parser.parse_args()
    tasks = json.loads(Path(__file__).with_name('tasks.json').read_text())
    output = {}
    for name, root, trace in [('baseline', options.baseline_root, False),
                              ('instrumented', options.instrumented_root, True)]:
        arm = {'name': name, 'binary': str(Path(root) / 'medaka'), 'trace': trace,
               'environment': {'MEDAKA_STRICT': '1'}}
        output[name] = {case['id']: measure_case(case, arm, 5) for case in cases(tasks, root)}
        missing = dict(arm, binary=str(Path(root) / 'missing-medaka'))
        output[name]['missing-binary'] = measure_case(cases(tasks, root)[-1], missing, 5)
    with open(options.output, 'x', encoding='utf-8') as stream:
        json.dump(output, stream, indent=2)
        stream.write('\n')
