"""Trusted, Linux-only app-server launcher; never mount this module into a trial."""
import base64
from contextlib import nullcontext
import hashlib
import json
import os
from pathlib import Path
import queue
import shutil
import signal
import subprocess
import tempfile
import threading
import time

from build_cli_artifact import ORIGINAL_SHA256, fingerprint

CLI_VERSION = 'codex-cli 0.166.0'
MODEL = 'gpt-6.1-terra'
EFFORT = 'high'
CONFIG = '''model = "gpt-6.1-terra"
model_reasoning_effort = "high"
approval_policy = "never"
web_search = "disabled"
project_doc_max_bytes = 0
[features]
shell_tool = false
unified_exec = false
multi_agent = false
apps = false
plugins = false
view_image = false
image_generation = false
sleep_tool = false
goals = false
code_mode = false
code_mode_host = true
'''
SHELL = {'type': 'function', 'name': 'shell',
         'description': 'Run one shell command in the isolated task workspace. medaka is /toolchain/medaka. Every call consumes one operation.',
         'inputSchema': {'type': 'object', 'properties': {'command': {'type': 'string'}},
                         'required': ['command'], 'additionalProperties': False}}


class InfrastructureError(Exception):
    pass


def encoded(data):
    return base64.b64encode(data).decode('ascii')


class Journal:
    def __init__(self, path):
        self.stream = Path(path).open('x')
        self.lock = threading.Lock()

    def write(self, value):
        with self.lock:
            self.stream.write(json.dumps(value, sort_keys=True) + '\n')
            self.stream.flush()

    def close(self):
        self.stream.close()


class Budget:
    """Admission and closure share a lock; rejected calls have no effect."""
    def __init__(self, journal, seconds=600, limit=30, clock=time.monotonic):
        self.journal, self.clock = journal, clock
        self.started = clock()
        self.deadline = self.started + seconds
        self.limit = limit
        self.attempted = self.admitted = self.denied = 0
        self.closed = None
        self.lock = threading.Lock()

    def reserve(self, tool, request):
        with self.lock:
            self.attempted += 1
            if self.clock() >= self.deadline:
                self.closed = 'deadline'
            reason = self.closed or ('budget' if self.admitted >= self.limit else None)
            if reason:
                self.denied += 1
            else:
                self.admitted += 1
            record = {'event': 'admission', 'sequence': self.attempted, 'tool': tool,
                      'request_b64': encoded(request), 'admitted': reason is None,
                      'denial': reason, 'elapsed_seconds': self.clock() - self.started}
            self.journal.write(record)
            return record

    def close(self, reason):
        with self.lock:
            if self.closed is None:
                self.closed = reason


class Sandbox:
    def __init__(self, workspace, toolchain, budget):
        self.workspace, self.toolchain = Path(workspace), Path(toolchain)
        self.budget = budget
        self.active = set()
        self.lock = threading.Lock()

    def command(self, argv, toolchain=None):
        root = Path(toolchain or self.toolchain).resolve()
        args = ['bwrap', '--unshare-all', '--die-with-parent', '--new-session',
                '--cap-drop', 'ALL', '--clearenv', '--setenv', 'PATH', '/toolchain:/usr/bin:/bin',
                '--setenv', 'MEDAKA_STRICT', '1', '--setenv', 'MEDAKA_ROOT', '/toolchain',
                '--setenv', 'HOME', '/tmp', '--ro-bind', '/usr', '/usr',
                '--ro-bind', '/lib', '/lib', '--ro-bind', '/lib64', '/lib64',
                '--symlink', 'usr/bin', '/bin', '--proc', '/proc', '--dev', '/dev',
                '--tmpfs', '/tmp', '--bind', str(self.workspace), '/workspace',
                '--ro-bind', str(root), '/toolchain', '--chdir', '/workspace']
        return args + argv

    def spawn(self, argv, toolchain=None, sequence=None):
        with self.lock:
            if self.budget.closed or time.monotonic() >= self.budget.deadline:
                raise TimeoutError('trial closed')
            process = subprocess.Popen(self.command(argv, toolchain), stdin=subprocess.PIPE,
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                       start_new_session=True)
            self.active.add(process)
            if sequence is not None:
                self.budget.journal.write({'event': 'dispatch', 'sequence': sequence, 'tool': 'shell'})
            return process

    def forget(self, process):
        with self.lock:
            self.active.discard(process)

    def stop(self):
        with self.lock:
            for process in self.active:
                if process.poll() is None:
                    process.kill()
            for process in self.active:
                process.wait(timeout=10)
            self.active.clear()

    def run(self, argv, data=None, toolchain=None, sequence=None):
        process = self.spawn(argv, toolchain, sequence)
        try:
            out, err = process.communicate(data, timeout=max(.001, self.budget.deadline - time.monotonic()))
            return {'exit_code': process.returncode, 'stdout_b64': encoded(out), 'stderr_b64': encoded(err)}
        except subprocess.TimeoutExpired:
            self.budget.close('deadline')
            self.stop()
            process.communicate()
            raise TimeoutError('trial deadline')
        finally:
            self.forget(process)

    def verify(self):
        result = self.run(['/bin/true'])
        if result['exit_code'] != 0:
            raise InfrastructureError('network/PID/mount isolation unavailable: ' + base64.b64decode(result['stderr_b64']).decode(errors='replace'))


class Broker:
    """One serial real MCP protocol connection, reachable only by trusted callbacks."""
    def __init__(self, sandbox, original):
        self.sandbox = sandbox
        self.process = sandbox.spawn(['/toolchain/medaka', 'mcp'], original)
        self.incoming = queue.Queue()
        self.lock = threading.Lock()
        self.sequence = 0
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.reader.start()
        self.error_reader = threading.Thread(target=lambda: self.process.stderr.read(), daemon=True)
        self.error_reader.start()
        result = self.request('initialize', {'protocolVersion': '2024-11-05', 'capabilities': {},
                                           'clientInfo': {'name': 'medaka_trial_host', 'version': '1'}})
        self.protocol = result['protocolVersion']
        self._send({'jsonrpc': '2.0', 'method': 'notifications/initialized'})
        self.tools = self.request('tools/list', {})['tools']

    def _read(self):
        try:
            for line in self.process.stdout:
                self.incoming.put(json.loads(line))
        except (ValueError, OSError):
            pass
        finally:
            self.incoming.put(None)

    def close(self):
        self.reader.join(timeout=10)
        self.error_reader.join(timeout=10)
        for stream in (self.process.stdin, self.process.stdout, self.process.stderr):
            stream.close()

    def _send(self, value):
        self.process.stdin.write(json.dumps(value).encode() + b'\n')
        self.process.stdin.flush()

    def request(self, method, params, sequence=None):
        with self.lock:
            if self.sandbox.budget.closed or time.monotonic() >= self.sandbox.budget.deadline:
                raise TimeoutError('MCP trial closed')
            self.sequence += 1
            if sequence is not None:
                self.sandbox.budget.journal.write({'event': 'dispatch', 'sequence': sequence, 'tool': 'mcp'})
            self._send({'jsonrpc': '2.0', 'id': self.sequence, 'method': method, 'params': params})
            while True:
                remaining = self.sandbox.budget.deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError('MCP deadline')
                try:
                    result = self.incoming.get(timeout=remaining)
                except queue.Empty as error:
                    raise TimeoutError('MCP deadline') from error
                if result is None:
                    raise InfrastructureError('MCP connection closed')
                if result.get('id') == self.sequence:
                    if 'error' in result:
                        return {'isError': True, 'error': result['error']}
                    return result['result']


def verify_distribution(root, expected):
    root = Path(root).resolve()
    actual = fingerprint(root)
    if actual != expected:
        raise InfrastructureError('artifact fingerprint mismatch')
    required = {'medaka', 'medaka_emitter', 'runtime/medaka_rt.c', 'stdlib/core.mdk', 'stdlib/runtime.mdk'}
    if not required <= set(actual) or any(p.startswith('compiler/') for p in actual):
        raise InfrastructureError('invalid installed distribution')
    return root


def materialize(files, workspace):
    for name, value in files.items():
        path = Path(name)
        if path.is_absolute() or '..' in path.parts or not path.parts or path.parts[0] == '.codex':
            raise ValueError('unsafe workspace path')
        target = workspace / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(value)


def launch(spec, output, cli, cli_hashes, original, original_hashes, auth_file, seconds=600):
    """One fresh attempt. Caller owns serial scheduling and independent grading.

    seconds can only shorten the fixed corpus deadline, for synthetic controls.
    """
    if (spec['model'], spec['effort']) != (MODEL, EFFORT) or spec['arm'] not in ('shell-only', 'mcp'):
        raise ValueError('unsupported model/profile/arm')
    if spec['deadline_seconds'] != 600 or spec['tool_call_limit'] != 30 or not 0 < seconds <= 600:
        raise ValueError('invalid fixed trial budget')
    if subprocess.check_output(['codex', '--version'], text=True, stderr=subprocess.DEVNULL, timeout=30).strip() != CLI_VERSION:
        raise InfrastructureError('unverified Codex CLI version')
    cli = verify_distribution(cli, cli_hashes)
    if spec['arm'] == 'mcp' and (not isinstance(original_hashes, dict) or original_hashes.get('medaka') != ORIGINAL_SHA256):
        raise InfrastructureError('preserved baseline binary fingerprint mismatch')
    original = verify_distribution(original, original_hashes) if spec['arm'] == 'mcp' else None
    output = Path(output).resolve()
    output.mkdir(parents=True, exist_ok=False)
    subprocess.run(['codex', 'app-server', 'generate-json-schema', '--experimental', '--out', str(output / 'protocol')],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30)
    journal = Journal(output / 'host.jsonl')
    events = Journal(output / 'appserver.jsonl')
    budget = Budget(journal, seconds)
    summary = {'model': MODEL, 'effort': EFFORT, 'cli_version': CLI_VERSION,
               'outcome': 'infrastructure_error', 'answer': None, 'usage': None,
               'usage_complete': False, 'read_count': None, 'cpu_ns': None, 'peak_rss_bytes': None,
               'result_bytes': 0, 'shell_operations': 0, 'mcp_operations': 0,
               'spec_sha256': hashlib.sha256(json.dumps(spec, sort_keys=True).encode()).hexdigest(),
               'protocol_files': fingerprint(output / 'protocol'),
               'artifact_files': cli_hashes, 'mcp_artifact_files': original_hashes if original else None}
    incoming, write_lock, summary_lock = queue.Queue(), threading.Lock(), threading.Lock()
    process = sandbox = broker = workspace = None
    done = threading.Event()
    workers = []
    callback_error = []
    turn = thread_id = None
    exhausted = threading.Event()

    def send(value):
        with write_lock:
            if process.poll() is None:
                process.stdin.write(json.dumps(value) + '\n')
                process.stdin.flush()
                return True
            return False

    def read_events():
        try:
            for line in process.stdout:
                event = json.loads(line)
                if event.get('method', '').startswith('account/'):
                    event['params'] = {'redacted': 'account metadata'}
                events.write(event)
                if event.get('method') == 'item/tool/call':
                    admission = budget.reserve(event['params']['tool'], json.dumps(event['params']['arguments'], sort_keys=True).encode())
                    worker = threading.Thread(target=callback, args=(event, admission))
                    workers.append(worker)
                    worker.start()
                else:
                    incoming.put(event)
        except (ValueError, OSError):
            incoming.put({'host_error': 'malformed app-server stream'})
        finally:
            incoming.put({'host_error': 'app-server exited'})

    def wait_response(identifier):
        while True:
            remaining = budget.deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError('startup deadline')
            event = incoming.get(timeout=remaining)
            if 'host_error' in event or 'error' in event:
                raise InfrastructureError('app-server startup failed')
            if event.get('id') == identifier:
                return event['result']

    def callback(event, admission):
        params = event['params']
        tool = params['tool']
        result = {'denied': admission['denial']}
        success = False
        try:
            if admission['admitted']:
                arguments = params['arguments']
                if isinstance(arguments, str):
                    arguments = json.loads(arguments)
                if tool == 'shell' and set(arguments) == {'command'} and isinstance(arguments['command'], str):
                    result = sandbox.run(['/bin/sh', '-c', arguments['command']], sequence=admission['sequence'])
                    success = result['exit_code'] == 0
                elif broker is not None and tool in {t['name'] for t in broker.tools}:
                    result = broker.request('tools/call', {'name': tool, 'arguments': arguments}, sequence=admission['sequence'])
                    success = not result.get('isError', False)
                else:
                    result = {'error': 'unknown tool or invalid arguments'}
        except TimeoutError:
            budget.close('deadline')
            result = {'cancelled': budget.closed}
        except (OSError, ValueError, InfrastructureError) as error:
            callback_error.append(type(error).__name__)
            budget.close('infrastructure_error')
            result = {'error': type(error).__name__}
        finally:
            response = json.dumps(result, sort_keys=True).encode()
            delivered = False
            try:
                delivered = send({'id': event['id'], 'result': {'success': success,
                      'contentItems': [{'type': 'inputText', 'text': response.decode()}]}})
            except OSError:
                pass
            journal.write({'event': 'result', 'sequence': admission['sequence'], 'tool': tool,
                           'result_b64': encoded(response), 'result_bytes': len(response),
                           'delivered': delivered})
            with summary_lock:
                summary['result_bytes'] += len(response) if delivered else 0
            if budget.admitted >= budget.limit:
                exhausted.set()

    def watchdog():
        while not done.wait(.01):
            if time.monotonic() >= budget.deadline or exhausted.is_set() or callback_error:
                budget.close('deadline' if time.monotonic() >= budget.deadline else
                             'infrastructure_error' if callback_error else 'budget')
                if thread_id and turn:
                    try:
                        send({'id': 90, 'method': 'turn/interrupt', 'params': {'threadId': thread_id, 'turnId': turn}})
                    except OSError:
                        pass
                if sandbox:
                    sandbox.stop()
                if process and process.poll() is None:
                    os.killpg(process.pid, signal.SIGKILL)
                return

    monitor = threading.Thread(target=watchdog, daemon=True)
    monitor.start()
    private_temp = tempfile.TemporaryDirectory(prefix='medaka-trial-')
    try:
        with nullcontext(private_temp.name) as private:
            private = Path(private)
            workspace, home, cwd = private / 'workspace', private / 'host-home', private / 'host-cwd'
            for directory in (workspace, home, cwd):
                directory.mkdir(mode=0o700)
            materialize(spec['files'], workspace)
            sandbox = Sandbox(workspace, cli, budget)
            sandbox.verify()
            broker = Broker(sandbox, original) if original else None
            tools = [SHELL] + ([{'type': 'function', 'name': t['name'], 'description': t['description'],
                                'inputSchema': t['inputSchema']} for t in broker.tools] if broker else [])
            summary['tools'] = [t['name'] for t in tools]
            summary['mcp_protocol'] = broker.protocol if broker else None
            journal.write({'event': 'setup', 'mounts': ['/usr', '/lib', '/lib64', '/proc', '/dev',
                                                      '/tmp', '/workspace', '/toolchain'],
                           'tools': summary['tools'], 'workspace_fresh': not any(workspace.glob('*.jsonl'))})
            (home / 'config.toml').write_text(CONFIG)
            auth = home / 'auth.json'
            auth.symlink_to(Path(auth_file).resolve(strict=True))
            env = {'PATH': os.environ.get('PATH', '/usr/bin:/bin'), 'HOME': str(home), 'CODEX_HOME': str(home)}
            process = subprocess.Popen(['codex', 'app-server', '--listen', 'stdio://'],
                                       stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                       stderr=subprocess.DEVNULL, text=True, bufsize=1, env=env,
                                       cwd=cwd, start_new_session=True)
            reader = threading.Thread(target=read_events, daemon=True)
            reader.start()
            send({'id': 1, 'method': 'initialize', 'params': {'clientInfo': {'name': 'medaka_trial', 'version': '1'},
                                                           'capabilities': {'experimentalApi': True}}})
            summary['initialize'] = wait_response(1)
            send({'method': 'initialized', 'params': {}})
            send({'id': 2, 'method': 'thread/start', 'params': {'model': MODEL, 'ephemeral': True,
                  'environments': [], 'cwd': str(cwd), 'baseInstructions':
                  'Use the provided tools for the task. The task files are in /workspace. Tool paths use /workspace. '
                  'Shell output stdout_b64 and stderr_b64 are base64 encoded bytes. '
                  'You have at most 30 admitted primitive operations and a ten-minute deadline.', 'dynamicTools': tools}})
            thread_id = wait_response(2)['thread']['id']
            prompt = spec['prompt'] + '\n\n' + '\n'.join(c['id'] + ': ' + c['question'] for c in spec['controls'])
            send({'id': 3, 'method': 'turn/start', 'params': {'threadId': thread_id, 'effort': EFFORT,
                  'input': [{'type': 'text', 'text': prompt}]}})
            turn = wait_response(3)['turn']['id']
            while True:
                if budget.closed:
                    break
                try:
                    event = incoming.get(timeout=.1)
                except queue.Empty:
                    continue
                method = event.get('method')
                if 'host_error' in event:
                    raise InfrastructureError(event['host_error'])
                if method == 'thread/tokenUsage/updated':
                    summary['usage'] = event['params']['tokenUsage']
                elif method == 'item/completed':
                    item = event['params']['item']
                    if item.get('type') == 'agentMessage':
                        summary['answer'] = item.get('text')
                elif method == 'turn/completed':
                    status = event['params']['turn']['status']
                    summary['outcome'] = 'success' if status == 'completed' else 'tool_error'
                    summary['usage_complete'] = status == 'completed' and summary['usage'] is not None
                    break
                elif 'id' in event and method:
                    send({'id': event['id'], 'error': {'code': -32000, 'message': 'Capability disabled'}})
                    raise InfrastructureError('unexpected native capability request')
            # Persist result artifacts only after the isolated turn has stopped.
            budget.close(budget.closed or 'completed')
            sandbox.stop()
            for worker in workers:
                worker.join(timeout=10)
                if worker.is_alive():
                    raise InfrastructureError('callback did not terminate')
            auth.unlink()
    except (OSError, ValueError, InfrastructureError, queue.Empty) as error:
        summary['error'] = type(error).__name__ + ': ' + str(error)
        summary['outcome'] = 'infrastructure_error'
    except TimeoutError:
        budget.close('deadline')
    finally:
        done.set()
        monitor.join(timeout=10)
        budget.close('shutdown')
        if process:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=10)
            reader.join(timeout=10)
        if sandbox:
            sandbox.stop()
        for worker in workers:
            worker.join(timeout=10)
        if broker:
            broker.close()
        if process:
            process.stdin.close()
            process.stdout.close()
        result_root = output / 'workspace'
        result_root.mkdir()
        if workspace:
            for path in workspace.rglob('*'):
                if path.is_file() and not path.is_symlink():
                    target = result_root / path.relative_to(workspace)
                    target.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(path, target)
        summary['workspace_files'] = fingerprint(result_root)
        private_temp.cleanup()
        if budget.closed in ('deadline', 'budget', 'infrastructure_error'):
            summary['outcome'] = {'deadline': 'timeout', 'budget': 'cancelled',
                                  'infrastructure_error': 'infrastructure_error'}[budget.closed]
            summary['usage_complete'] = False
        summary.update(attempted=budget.attempted, admitted=budget.admitted, denied=budget.denied,
                       stop_reason=budget.closed, wall_ns=int((time.monotonic() - budget.started) * 1e9))
        journal.close()
        events.close()
        records = [json.loads(line) for line in (output / 'host.jsonl').read_text().splitlines()]
        summary['shell_operations'] = sum(r['event'] == 'dispatch' and r['tool'] == 'shell' for r in records)
        summary['mcp_operations'] = sum(r['event'] == 'dispatch' and r['tool'] == 'mcp' for r in records)
        summary['host_sha256'] = hashlib.sha256((output / 'host.jsonl').read_bytes()).hexdigest()
        summary['transcript_sha256'] = hashlib.sha256((output / 'appserver.jsonl').read_bytes()).hexdigest()
        (output / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    return summary


def run_with_retry(spec, output, runner):
    """Retain both attempts, and retry infrastructure failure once only."""
    root = Path(output)
    root.mkdir(parents=True, exist_ok=False)
    def attempt(number):
        path = root / f'attempt-{number}'
        try:
            result = runner(spec, path)
        except (InfrastructureError, OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
            result = {'outcome': 'infrastructure_error', 'error': type(error).__name__}
        path.mkdir(exist_ok=True)
        (path / 'attempt.json').write_text(json.dumps(result, indent=2) + '\n')
        return result

    attempts = [attempt(1)]
    if attempts[0]['outcome'] == 'infrastructure_error':
        attempts.append(attempt(2))
    (root / 'attempts.json').write_text(json.dumps(attempts, indent=2) + '\n')
    return attempts
