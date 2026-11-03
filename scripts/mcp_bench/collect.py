"""Host-side process observation. Transcripts are never included in run records."""
import json
import os
import queue
import subprocess
import sys
import tempfile
import threading
import time

from pathlib import Path

from schema import validate_event, validate_run, validate_task
from supervisor import Boundary, Unavailable


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
    if exitStatus in ('startup_failure', 'timeout', 'cancelled', 'observer_failure', 'unsupported'):
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
    if any(type(identifier) not in (int, str) for identifier in expected):
        raise ValueError('unsupported request ID')
    actual = []
    for response in responses:
        if (not isinstance(response, dict) or response.get('jsonrpc') != '2.0'
                or type(response.get('id')) not in (int, str)
                or set(response) not in ({'jsonrpc', 'id', 'result'}, {'jsonrpc', 'id', 'error'})):
            raise ValueError('invalid response')
        if 'error' in response:
            error = response['error']
            if (not isinstance(error, dict) or not {'code', 'message'} <= set(error)
                    or set(error) - {'code', 'message', 'data'}
                    or type(error['code']) is not int or not isinstance(error['message'], str)):
                raise ValueError('invalid JSON-RPC error')
        actual.append(response['id'])
    # JSON representation preserves the distinction between integer and string IDs.
    encode = lambda value: json.dumps(value, sort_keys=True, separators=(',', ':'))
    if len(set(map(encode, expected))) != len(expected):
        raise ValueError('duplicate request ID')
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
    try:
        boundary = Boundary()
    except Unavailable as error:
        if limits.get('resource_callback') is not None:
            limits['resource_callback']({'unavailable': str(error)})
        return _record('unsupported', limits, time.monotonic_ns() - started)
    try:
        return _run_contained(command, environment, transcript, limits, requests, started, boundary)
    finally:
        boundary.close()


def _run_contained(command, environment, transcript, limits, requests, started, boundary):
    events, malformed, observer_failure, status = [], False, False, 'startup_failure'
    with tempfile.TemporaryDirectory() as directory:
        os.chmod(directory, 0o711)
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
        for path in [workspace, *workspace.rglob('*')]:
            os.chown(path, boundary.uid, boundary.uid)
        Path(trace).touch(mode=0o600)
        os.chown(trace, boundary.uid, boundary.uid)
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
            output_read, output_write = os.pipe()
            try:
                supervisor = subprocess.Popen(
                    [sys.executable, str(Path(__file__).with_name('supervisor.py')), str(write_fd),
                     json.dumps([str(boundary.path), boundary.uid, command, env, limits.get('interactive', False)])],
                    stdin=subprocess.PIPE, stdout=output_write, stderr=subprocess.DEVNULL,
                    env={'PATH': os.defpath}, cwd=workspace, pass_fds=(write_fd,))
            except OSError:
                supervisor = None
            finally:
                os.close(write_fd)
                os.close(output_write)
            if supervisor is not None:
                arrivals, reader_errors = [], []
                lines = queue.Queue()
                exchanges, memberships = [], []
                observed_bytes = [0]
                def observe():
                    partial = b''
                    overflow_reported = False
                    try:
                        while True:
                            chunk = os.read(output_read, 4096)
                            if not chunk:
                                break
                            now = time.monotonic_ns()
                            remaining = limits.get("output_bytes", 1048576) + 1 - observed_bytes[0]
                            if remaining > 0:
                                bounded = chunk[:remaining]
                                arrivals.extend([now] * bounded.count(b"\n"))
                                stdout.write(bounded)
                                observed_bytes[0] += min(len(chunk), remaining)
                                if limits.get('interactive'):
                                    partial += bounded
                                    while b'\n' in partial:
                                        line, partial = partial.split(b'\n', 1)
                                        lines.put((now, line + b'\n'))
                            if observed_bytes[0] > limits.get('output_bytes', 1048576) and not overflow_reported:
                                lines.put((now, b'{}\n'))
                                overflow_reported = True
                    except OSError as error:
                        reader_errors.append(error)
                    finally:
                        lines.put(None)
                reader = threading.Thread(target=observe)
                reader.start()
                try:
                    if limits.get('interactive'):
                        expires = time.monotonic() + deadline
                        for index, request in enumerate(requests):
                            if limits.get('before_request') is not None:
                                limits['before_request'](index, workspace)
                            sent = time.monotonic_ns()
                            supervisor.stdin.write((json.dumps(request) + '\n').encode())
                            supervisor.stdin.flush()
                            if isinstance(request, dict) and 'id' in request:
                                try:
                                    item = lines.get(timeout=max(0, expires - time.monotonic()))
                                except queue.Empty:
                                    raise subprocess.TimeoutExpired(command, deadline)
                                if item is None:
                                    break
                                received, line = item
                                _responses(line, [request])
                                exchanges.append({'id': request['id'], 'sent_ns': sent - started,
                                                  'received_ns': received - started,
                                                  'round_trip_ns': received - sent})
                                memberships.append(len((boundary.path / 'cgroup.procs').read_text().splitlines()))
                        supervisor.stdin.close()
                        supervisor.stdin = None
                        supervisor.wait(timeout=max(0, expires - time.monotonic()))
                    else:
                        supervisor.communicate(transcript, timeout=deadline)
                except (ValueError, UnicodeError):
                    malformed = True
                    supervisor.kill()
                    supervisor.communicate()
                except BrokenPipeError:
                    try:
                        supervisor.stdin.close()
                    except OSError:
                        pass
                    supervisor.stdin = None
                    supervisor.wait(timeout=deadline)
                except subprocess.TimeoutExpired:
                    supervisor.kill()
                    supervisor.communicate()
                    status = 'cancelled' if cancel is not None and cancel <= timeout else 'timeout'
                except BaseException:
                    supervisor.kill()
                    supervisor.wait()
                    raise
                finally:
                    boundary.close()
                    reader.join()
                    os.close(output_read)
                if limits.get('resource_callback') is not None:
                    resources = dict(boundary.resources or {'unavailable': 'cgroup counters unavailable'})
                    resources['observed_member_counts'] = memberships
                    limits['resource_callback'](resources)
                try:
                    with os.fdopen(read_fd, 'rb') as status_stream:
                        observed_status = json.load(status_stream)
                        if status not in ('timeout', 'cancelled'):
                            status = observed_status
                except (ValueError, OSError):
                    if status not in ('timeout', 'cancelled'):
                        status = 'observer_failure'
                if supervisor.returncode != 0 and status not in ('timeout', 'cancelled'):
                    status = 'observer_failure'
                stdout.seek(0)
                output = stdout.read(limits.get('output_bytes', 1048576) + 1)
                if reader_errors or len(output) > limits.get('output_bytes', 1048576):
                    observer_failure = True
                else:
                    try:
                        responses = _responses(output, requests)
                    except (ValueError, UnicodeError):
                        malformed = True
                    else:
                        try:
                            if limits.get('timing_callback') is not None:
                                if len(arrivals) != len(responses):
                                    raise ValueError('response timing mismatch')
                                limits['timing_callback']([t - started for t in arrivals])
                            if limits.get('response_callback') is not None:
                                limits['response_callback'](responses)
                            if limits.get('exchange_callback') is not None:
                                limits['exchange_callback'](exchanges)
                        except Exception:
                            observer_failure = True
            else:
                os.close(read_fd)
                os.close(output_read)
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
    if outcome not in ('timeout', 'cancelled', 'startup_failure', 'crash', 'observer_failure', 'unsupported'):
        if observer_failure:
            outcome = 'observer_failure'
        elif malformed:
            outcome = 'protocol_error'
    return _record(outcome, limits, time.monotonic_ns() - started)
