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


def measure_interactive_case(case, arm, index=0):
    """One serial session; raw payloads remain private until explicitly compacted."""
    responses, exchanges, resources = [], [], []
    def before_request(number, workspace):
        if case['id'] == 'changed-source' and number == 2:
            (workspace / 'main.mdk').write_text('main = 1 + 2\n')
    limits = {'run_id': f"{case['id']}-{index}", 'task_id': case['id'],
              'arm': arm['name'], 'trace': arm['trace'], 'task': case['task'],
              'interactive': True, 'before_request': before_request,
              'response_callback': responses.extend, 'exchange_callback': exchanges.extend,
              'resource_callback': resources.append}
    transcript = b''.join((json.dumps(request) + '\n').encode() for request in case['requests'])
    record = run_process([arm['binary'], 'mcp'], arm.get('environment', {}), transcript, limits)
    return {'record': record, 'exchanges': exchanges, 'responses': responses, 'resources': resources}


def measure_matched(root, tasks, repetitions=5):
    """Alternate trace order within each case using the identical executable/tree."""
    if repetitions < 1:
        raise ValueError('repetitions must be positive')
    queries = cases(tasks, root)
    changed = next(case for case in queries if case['id'] == 'changed-source')
    changed['task'] = deepcopy(next(task for task in tasks if task['id'] == 'repair-diagnostic'))
    changed['requests'].append(call(2, 'medaka_check', {'file': 'main.mdk'}))
    missing = deepcopy(queries[-1])
    missing['id'] = 'missing-binary'
    queries.append(missing)
    samples = []
    for case in queries:
        for index in range(repetitions):
            for trace in ((False, True) if index % 2 == 0 else (True, False)):
                arm = {'name': 'trace-on' if trace else 'trace-off', 'trace': trace,
                       'binary': str(Path(root) / ('missing-medaka' if case['id'] == 'missing-binary' else 'medaka')),
                       'environment': {'MEDAKA_STRICT': '1'}}
                samples.append(measure_interactive_case(case, arm, index))
    return {'schema_version': 1, 'samples': samples}


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
    parser.add_argument('--baseline-root')
    parser.add_argument('--instrumented-root')
    parser.add_argument('--interactive-root')
    parser.add_argument('--output', required=True)
    options = parser.parse_args()
    tasks = json.loads(Path(__file__).with_name('tasks.json').read_text())
    if options.interactive_root:
        output = measure_matched(options.interactive_root, tasks)
        with open(options.output, 'x', encoding='utf-8') as stream:
            json.dump(output, stream, indent=2)
            stream.write('\n')
        raise SystemExit(0)
    if not options.baseline_root or not options.instrumented_root:
        parser.error('supply --interactive-root or both legacy roots')
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
