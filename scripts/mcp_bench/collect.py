"""Host-side process observation. Transcripts are never included in run records."""
import json
import os
import subprocess
import sys
import tempfile
import time

from pathlib import Path

from schema import validate_event, validate_run, validate_task


def _record(outcome, identity=None, wall_ns=0):
    identity = identity or {}
    return validate_run({
        'schema_version': 2, 'run_id': identity.get('run_id', 'run'),
        'task_id': identity.get('task_id', 'probe'), 'arm': identity.get('arm', 'instrumented'),
        'outcome': outcome, 'attempted': 1, 'completed': 1,
        'passed': int(outcome == 'success'), 'failed': int(outcome != 'success'), 'skipped': 0,
        'wall_ns': wall_ns, 'cpu_ns': None, 'peak_rss_bytes': None,
        'resource_scope': 'worker process tree',
        'resource_reason': {'cpu_ns': 'portable process-tree CPU measurement unavailable',
                            'peak_rss_bytes': 'portable process-tree peak RSS measurement unavailable'},
    })


def reconcile(events, exitStatus):
    """Reconcile server events with observed termination; return a validated Run."""
    pending, completed, outcomes = {}, set(), []
    try:
        for raw in events:
            event = validate_event(raw)
            key = (event['session_id'], event['request_id'])
            if event['event'] == 'cancel_requested' and pending:
                return _record('observer_failure')
            if event['event'] == 'start':
                if pending or key in completed:
                    return _record('observer_failure')
                pending[key] = (event['tool'], event['classification'])
            elif event['event'] == 'finish':
                if key not in pending:
                    return _record('observer_failure')
                if pending.pop(key) != (event['tool'], event['classification']):
                    return _record('observer_failure')
                completed.add(key)
                outcomes.append(event['outcome'])
    except (ValueError, KeyError, TypeError):
        return _record('observer_failure')
    if exitStatus in ('startup_failure', 'timeout', 'cancelled', 'observer_failure'):
        return _record(exitStatus)
    if exitStatus != 0:
        return _record('crash')
    if pending:
        return _record('observer_failure')
    for outcome in ('protocol_error', 'tool_error'):
        if outcome in outcomes:
            return _record(outcome)
    return _record('success')


def _responses(data, requests):
    if data and not data.endswith(b'\n'):
        raise ValueError('truncated output')
    responses = [json.loads(line) for line in data.splitlines()]
    expected = [r['id'] for r in requests if isinstance(r, dict) and 'id' in r]
    actual = []
    for response in responses:
        if (not isinstance(response, dict) or response.get('jsonrpc') != '2.0'
                or 'id' not in response or (('result' in response) == ('error' in response))):
            raise ValueError('invalid response')
        actual.append(response['id'])
    # JSON representation preserves the distinction between integer and string IDs.
    encode = lambda value: json.dumps(value, sort_keys=True, separators=(',', ':'))
    if sorted(map(encode, expected)) != sorted(map(encode, actual)):
        raise ValueError('missing or stray response')
    return responses


def run_process(command, environment, transcript, limits):
    """Run JSON-lines bytes under a private supervisor; return only metadata.

    Optional response_callback receives parsed responses for an explicit comparison.
    `trace=False` selects the uninstrumented arm. `cancel_after` requests process
    termination after that many seconds; cancellation means that kill was observed.
    """
    started = time.monotonic_ns()
    if sys.platform != 'linux':
        return _record('unsupported', limits, time.monotonic_ns() - started)
    requests = [json.loads(line) for line in transcript.splitlines()]
    events, malformed, observer_failure, status = [], False, False, 'startup_failure'
    with tempfile.TemporaryDirectory() as directory:
        trace = os.path.join(directory, 'trace.jsonl')
        workspace = Path(directory) / 'workspace'
        workspace.mkdir()
        task = limits.get('task')
        if task is not None:
            try:
                task = validate_task(task)
                for name, source in task['files'].items():
                    path = workspace / name
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_text(source, encoding='utf-8')
                (workspace / 'PROMPT.txt').write_text(
                    task['prompt'] + '\n' + '\n'.join(c['question'] for c in task['controls']) + '\n', encoding='utf-8')
            except (OSError, ValueError, UnicodeError):
                return _record('observer_failure', limits, time.monotonic_ns() - started)
        env = {'PATH': os.defpath, 'HOME': str(workspace)}
        env.update(environment)
        env.pop('MEDAKA_MCP_LOG', None)
        env.pop('MEDAKA_MCP_TRACE', None)
        if limits.get('trace', True):
            env.update(MEDAKA_MCP_TRACE=trace, MEDAKA_MCP_TRACE_SESSION='collector', MEDAKA_MCP_TRACE_CLASS='probe')
        with tempfile.TemporaryFile() as stdout:
            timeout = limits.get('timeout', 30)
            cancel = limits.get('cancel_after')
            deadline = min(timeout, cancel) if cancel is not None else timeout
            read_fd, write_fd = os.pipe()
            try:
                supervisor = subprocess.Popen(
                    [sys.executable, str(Path(__file__).with_name('supervisor.py')), str(write_fd),
                     json.dumps([deadline, cancel is not None and cancel <= timeout, command])],
                    stdin=subprocess.PIPE, stdout=stdout, stderr=subprocess.DEVNULL,
                    env=env, cwd=workspace, pass_fds=(write_fd,))
            except OSError:
                supervisor = None
            finally:
                os.close(write_fd)
            if supervisor is not None:
                supervisor.communicate(transcript)
                try:
                    with os.fdopen(read_fd, 'rb') as status_stream:
                        status = json.load(status_stream)
                except (ValueError, OSError):
                    status = 'observer_failure'
                if supervisor.returncode != 0:
                    status = 'observer_failure'
                stdout.seek(0)
                output = stdout.read(limits.get('output_bytes', 1048576) + 1)
                if len(output) > limits.get('output_bytes', 1048576):
                    observer_failure = True
                else:
                    try:
                        responses = _responses(output, requests)
                    except (ValueError, UnicodeError):
                        malformed = True
                    else:
                        try:
                            if limits.get('response_callback') is not None:
                                limits['response_callback'](responses)
                        except Exception:
                            observer_failure = True
            else:
                os.close(read_fd)
        try:
            with open(trace, encoding='utf-8') as stream:
                events = [json.loads(line) for line in stream]
        except FileNotFoundError:
            if limits.get('trace', True) and any(r.get('method') == 'tools/call' for r in requests if isinstance(r, dict)) and status == 0:
                observer_failure = True
        except (OSError, ValueError, UnicodeError):
            observer_failure = True
    if limits.get('trace', True) and status == 0:
        known = {'medaka_check', 'medaka_type_at', 'medaka_symbols', 'medaka_definition',
                 'medaka_references', 'medaka_fmt', 'medaka_lint', 'medaka_test'}
        expected = []
        for index, request in enumerate(requests):
            if isinstance(request, list):
                expected.append(('start', str(index), 'protocol'))
            elif isinstance(request, dict) and request.get('method') == 'notifications/cancelled':
                expected.append(('cancel_requested', str(index), 'protocol'))
            elif isinstance(request, dict) and 'id' in request:
                method = request.get('method')
                if method == 'tools/call':
                    params = request.get('params')
                    name = params.get('name') if isinstance(params, dict) else None
                    expected.append(('start', str(index), name if isinstance(name, str) and name in known else 'unknown'))
                elif isinstance(method, str) and method not in ('initialize', 'ping', 'shutdown', 'tools/list', 'notifications/cancelled', 'notifications/initialized'):
                    expected.append(('start', str(index), 'protocol'))
        observed = [(e.get('event'), e.get('request_id'), e.get('tool')) for e in events
                    if isinstance(e, dict) and e.get('event') in ('start', 'cancel_requested')]
        if observed != expected or any(e.get('event') == 'protocol' or e.get('session_id') != 'collector' or e.get('classification') != 'probe'
                                     for e in events if isinstance(e, dict)):
            observer_failure = True
    outcome = reconcile(events, status)['outcome']
    if outcome not in ('timeout', 'cancelled', 'startup_failure', 'crash'):
        if observer_failure:
            outcome = 'observer_failure'
        elif malformed:
            outcome = 'protocol_error'
    return _record(outcome, limits, time.monotonic_ns() - started)
