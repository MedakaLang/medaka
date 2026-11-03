"""Host-side process observation. Transcripts are never included in run records."""
import json
import os
import signal
import subprocess
import tempfile
import time

from schema import validate_event, validate_run


def _record(outcome, identity=None, wall_ns=0):
    identity = identity or {}
    return validate_run({
        'schema_version': 2, 'run_id': identity.get('run_id', 'run'),
        'task_id': identity.get('task_id', 'probe'), 'arm': identity.get('arm', 'instrumented'),
        'outcome': outcome, 'attempted': 1, 'completed': 1,
        'passed': int(outcome == 'success'), 'failed': int(outcome != 'success'), 'skipped': 0,
        'wall_ns': wall_ns, 'cpu_ns': None, 'peak_rss_bytes': None,
        'resource_scope': 'worker process tree',
        'resource_reason': 'per-process-tree CPU and peak RSS are unavailable via the portable adapter',
    })


def reconcile(events, exitStatus):
    """Reconcile server events with observed termination; return a validated Run."""
    pending, completed, outcomes = set(), set(), []
    try:
        for raw in events:
            event = validate_event(raw)
            key = (event['session_id'], event['request_id'])
            if event['event'] == 'start':
                if key in pending or key in completed:
                    return _record('observer_failure')
                pending.add(key)
            elif event['event'] == 'finish':
                if key not in pending:
                    return _record('observer_failure')
                pending.remove(key)
                completed.add(key)
                outcomes.append(event['outcome'])
    except (ValueError, KeyError, TypeError):
        return _record('observer_failure')
    if exitStatus in ('startup_failure', 'timeout', 'cancelled'):
        return _record(exitStatus)
    if exitStatus != 0 or pending:
        return _record('crash')
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
    """Run JSON-lines bytes in a private process group; return only metadata.

    Optional response_callback receives parsed responses for an explicit comparison.
    `trace=False` selects the uninstrumented arm. `cancel_after` requests process
    termination after that many seconds; cancellation means that kill was observed.
    """
    started = time.monotonic_ns()
    requests = [json.loads(line) for line in transcript.splitlines()]
    events, malformed, observer_failure, status = [], False, False, 'startup_failure'
    with tempfile.TemporaryDirectory() as directory:
        trace = os.path.join(directory, 'trace.jsonl')
        env = os.environ.copy()
        env.update(environment)
        env.pop('MEDAKA_MCP_LOG', None)
        env.pop('MEDAKA_MCP_TRACE', None)
        if limits.get('trace', True):
            env.update(MEDAKA_MCP_TRACE=trace, MEDAKA_MCP_TRACE_SESSION='collector', MEDAKA_MCP_TRACE_CLASS='probe')
        with tempfile.TemporaryFile() as stdout:
            try:
                process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=stdout,
                                           stderr=subprocess.DEVNULL, env=env, start_new_session=True)
            except OSError:
                process = None
            if process is not None:
                timeout = limits.get('timeout', 30)
                cancel = limits.get('cancel_after')
                deadline = min(timeout, cancel) if cancel is not None else timeout
                try:
                    process.communicate(transcript, timeout=deadline)
                    status = process.returncode
                except subprocess.TimeoutExpired:
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    process.communicate()
                    status = 'cancelled' if cancel is not None and cancel <= timeout else 'timeout'
                finally:
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                stdout.seek(0)
                output = stdout.read(limits.get('output_bytes', 1048576) + 1)
                if len(output) > limits.get('output_bytes', 1048576):
                    observer_failure = True
                else:
                    try:
                        responses = _responses(output, requests)
                        if limits.get('response_callback') is not None:
                            limits['response_callback'](responses)
                    except (ValueError, UnicodeError):
                        malformed = True
        try:
            with open(trace, encoding='utf-8') as stream:
                events = [json.loads(line) for line in stream]
        except FileNotFoundError:
            if limits.get('trace', True) and any(r.get('method') == 'tools/call' for r in requests if isinstance(r, dict)) and status == 0:
                observer_failure = True
        except (OSError, ValueError, UnicodeError):
            observer_failure = True
    if limits.get('trace', True) and status == 0:
        calls = sum(1 for r in requests if isinstance(r, dict) and r.get('method') == 'tools/call')
        if sum(1 for e in events if isinstance(e, dict) and e.get('event') == 'start') < calls:
            observer_failure = True
    outcome = reconcile(events, status)['outcome']
    if outcome not in ('timeout', 'cancelled', 'startup_failure', 'crash'):
        if observer_failure:
            outcome = 'observer_failure'
        elif malformed:
            outcome = 'protocol_error'
    return _record(outcome, limits, time.monotonic_ns() - started)
