"""Independent subprocess checks for the two installed supervisor experiments."""
import json
import ctypes
import errno
import platform
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

from external import digest
from package import assemble
from protocol import validate_sequence

transcript = []


def offline():
    """Deny socket and connect syscalls in this process and its descendants."""
    machine = platform.machine()
    numbers = {'x86_64': (41, 42), 'aarch64': (198, 203)}[machine]
    class Filter(ctypes.Structure):
        _fields_ = [('code', ctypes.c_ushort), ('jt', ctypes.c_ubyte),
                    ('jf', ctypes.c_ubyte), ('k', ctypes.c_uint)]
    class Program(ctypes.Structure):
        _fields_ = [('length', ctypes.c_ushort), ('filter', ctypes.POINTER(Filter))]
    code = (Filter * 6)(Filter(0x20, 0, 0, 0), Filter(0x15, 2, 0, numbers[0]),
                        Filter(0x15, 1, 0, numbers[1]), Filter(0x06, 0, 0, 0x7fff0000),
                        Filter(0x06, 0, 0, 0x00050000 | errno.EPERM),
                        Filter(0x06, 0, 0, 0x7fff0000))
    program = Program(len(code), code)
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(38, 1, 0, 0, 0) or libc.prctl(22, 2, ctypes.byref(program)):
        raise OSError(ctypes.get_errno(), 'seccomp setup failed')


def exchange(process, message):
    transcript.append(message)
    process.stdin.write(json.dumps(message) + '\n')
    process.stdin.flush()
    line = process.stdout.readline()
    if not line:
        raise AssertionError('supervisor closed stdout')
    reply = json.loads(line)
    transcript.append(reply)
    return reply


def context(workspace):
    return {key: {'value': workspace if key == 'workspace' else key, 'provenance': 'inferred'}
            for key in ('workspace', 'toolchain', 'snapshot', 'profile')}


def request(i, workspace, operation, arguments):
    return {'type': 'request', 'id': str(i), 'context': context(workspace),
            'operation': {'name': operation, 'arguments': arguments}}


def semantic(result, bad):
    text = json.dumps(result)
    if ('T-NO-IMPL' in text) != bad or 'result' not in result:
        raise AssertionError('semantic delegation control failed: ' + text)


def exercise(candidate, scenario):
    if candidate != 'paired':
        raise ValueError('expected paired experiment')
    transcript.clear()
    bundle, supervisor, checkout = scenario['bundle'], scenario['supervisor'], scenario['checkout']
    if sys.platform != 'linux':
        raise RuntimeError('offline control currently requires Linux seccomp')
    control = subprocess.run([sys.executable, '-c', 'import socket; socket.socket()'], preexec_fn=offline, capture_output=True, text=True)
    assert control.returncode != 0 and 'Operation not permitted' in control.stderr
    with tempfile.TemporaryDirectory(prefix='mcp-install-') as tmp:
        root = Path(tmp)
        a, b = root / 'checkout-a', root / 'checkout-b'
        a.mkdir(); b.mkdir()
        assert not (a / 'medaka').exists()
        manifest = assemble('python', {'bundle': bundle}, [], root / 'installed')
        assemble('medaka', {'bundle': bundle, 'supervisor': supervisor}, [], root / 'medaka-installed')
        failure = subprocess.check_output([str(root / 'medaka-installed' / 'supervisor')], cwd=a, text=True)
        assert 'unavailable' in failure
        worker = manifest['worker']
        def fake_worker(name, initialize, tool="{'result': {}}", child=False, exit_after=False):
            path = root / name
            path.write_text(f"""#!{sys.executable}
import json, subprocess, sys
from pathlib import Path
if {child!r}:
    child = subprocess.Popen(['sleep', '60'])
    Path({str(root / (name + '.pid'))!r}).write_text(str(child.pid))
for line in sys.stdin:
    message = json.loads(line)
    if message['method'] == 'initialize':
        response = {initialize}
    else:
        response = {tool}
    print(json.dumps(response), flush=True)
    if {exit_after!r}:
        break
""")
            path.chmod(0o755)
            return path

        valid = "{'jsonrpc': '2.0', 'id': message['id'], 'result': {'protocolVersion': '2024-11-05'}}"
        malformed = fake_worker('malformed', "{'result': {'protocolVersion': '2024-11-05'}}")
        wrong_rpc = fake_worker('wrong-rpc', "{'jsonrpc': '1.0', 'id': message['id'], 'result': {'protocolVersion': '2024-11-05'}}")
        wrong_id = fake_worker('wrong-id', "{'jsonrpc': '2.0', 'id': 99, 'result': {'protocolVersion': '2024-11-05'}}")
        wrong = fake_worker('wrong-version', "{'jsonrpc': '2.0', 'id': message['id'], 'result': {'protocolVersion': 'wrong'}}")
        error = fake_worker('worker-error', "{'jsonrpc': '2.0', 'id': message['id'], 'error': {'code': -1, 'message': 'no'}}")
        both = fake_worker('both', "{'jsonrpc': '2.0', 'id': message['id'], 'result': {}, 'error': {'code': -1, 'message': 'no'}}")
        fake = fake_worker('fake-worker', valid, "{'jsonrpc': '2.0', 'id': message['id'], 'result': {}}")
        dead = fake_worker('dead-worker', valid, child=True, exit_after=True)
        child_worker = fake_worker('child-worker', valid, child=True)
        artifact = {'id': worker, 'digest': manifest['sha256']}
        process = subprocess.Popen([sys.executable, str(root / 'installed' / 'external.py')], cwd=a,
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, preexec_fn=offline)
        pids = []
        (a / 'probe.mdk').write_text('main = 1 + 2\n')
        (b / 'probe.mdk').write_text('main = \"x\" + 1\n')
        try:
            init = exchange(process, {'type': 'initialize', 'versions': [1]})
            assert init['version'] == 1
            for i, (wid, path) in enumerate((('A', a), ('B', b)), 1):
                response = exchange(process, request(i, wid, 'openWorkspace', {'root': str(path), 'artifact': artifact}))
                status = response['result']
                pids.append(status['pid'])
                assert status['ready'] and status['toolchain']['provenance'] == 'inferred'
                assert status['attestation']['provenance'] == 'unavailable' and status['matching'] == 'unavailable'
            alias = root / 'alias-a'
            alias.symlink_to(a, target_is_directory=True)
            for name, path in (('same-root', a), ('alias-root', alias)):
                denied = exchange(process, request(name, name, 'openWorkspace', {'root': str(path), 'artifact': artifact}))
                assert denied['status'] == 'error' and 'duplicate canonical' in denied['error']
            snapshots = []
            for i, (wid, bad) in enumerate((('A', False), ('B', True), ('A', False)), 3):
                result = exchange(process, request(i, wid, 'check', {'file': 'probe.mdk'}))
                semantic(result, bad)
                snapshots.append(result['result']['snapshot'])
            assert snapshots[0] == snapshots[2] and snapshots[0] != snapshots[1]
            assert all(item['provenance'] == 'inferred' for item in snapshots)
            for candidate in (malformed, wrong_rpc, wrong_id, wrong, error, both):
                invalid_version = {'id': str(candidate), 'digest': digest(candidate)}
                denied = exchange(process, {'type': 'replace', 'id': candidate.name, 'workspace': 'A', 'artifact': invalid_version})
                assert denied['status'] == 'failed' and denied['worker'] == worker and denied['error']
                assert exchange(process, request('retained-' + candidate.name, 'A', 'status', {}))['result']['worker'] == worker
            fake_artifact = {'id': str(fake), 'digest': digest(fake)}
            assert exchange(process, {'type': 'replace', 'id': 'fake', 'workspace': 'B', 'artifact': fake_artifact})['status'] == 'switched'
            fake_result = exchange(process, request('fake-check', 'B', 'check', {'source': 'main = "x" + 1'}))
            assert fake_result['status'] == 'error' and 'invalid MCP tool result' in fake_result['error']
            assert exchange(process, {'type': 'replace', 'id': 'restore', 'workspace': 'B', 'artifact': artifact})['status'] == 'switched'
            invalid = dict(artifact, digest='0' * 64)
            failed = exchange(process, {'type': 'replace', 'id': '6', 'workspace': 'A', 'artifact': invalid})
            assert failed['status'] == 'failed' and failed['worker'] == worker
            replacement = root / 'installed' / 'toolchain' / 'medaka-rebuilt'
            env = dict(os.environ, MEDAKA_BUILD_CACHE_DIR='', SKIP_CLI_LINK_IF_FRESH='0')
            subprocess.run(['sh', str(Path(checkout) / 'test/build_native_medaka.sh')], cwd=checkout, env=env, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            shutil.copy2(Path(checkout) / 'medaka', replacement)
            new = {'id': str(replacement), 'digest': digest(replacement)}
            switched = exchange(process, {'type': 'replace', 'id': '7', 'workspace': 'A', 'artifact': new})
            assert switched['status'] == 'switched' and switched['workspace'] == 'A'
            pids.append(exchange(process, request('new-status', 'A', 'status', {}))['result']['pid'])
            assert exchange(process, request(8, 'B', 'status', {}))['result']['worker'] == worker
            semantic(exchange(process, request(9, 'A', 'check', {'source': 'main = "x" + 1'})), True)
            missing = {'id': str(root / 'missing'), 'digest': '0' * 64}
            assert exchange(process, {'type': 'replace', 'id': '10', 'workspace': 'A', 'artifact': missing})['status'] == 'failed'
            child_artifact = {'id': str(child_worker), 'digest': digest(child_worker)}
            assert exchange(process, {'type': 'replace', 'id': 'child', 'workspace': 'B', 'artifact': child_artifact})['status'] == 'switched'
            child_pid = int((root / 'child-worker.pid').read_text())
            dying = {'id': str(dead), 'digest': digest(dead)}
            assert exchange(process, {'type': 'replace', 'id': 'dead', 'workspace': 'B', 'artifact': dying})['status'] == 'switched'
            child_stat = Path(f'/proc/{child_pid}/stat')
            assert not child_stat.exists() or child_stat.read_text().split()[2] == 'Z'
            dead_child_pid = int((root / 'dead-worker.pid').read_text())
            pids.append(exchange(process, request('dead-status', 'B', 'status', {}))['result']['pid'])
            died = exchange(process, request('dead-check', 'B', 'check', {'source': 'main = 1'}))
            assert died['status'] == 'error' and died['result'] is None
            transcript.append({'type': 'shutdown'})
            process.stdin.write(json.dumps({'type': 'shutdown'}) + '\n'); process.stdin.flush()
            validate_sequence(transcript)
            assert process.wait(timeout=10) == 0
            assert process.stdout.read() == '' and process.stderr.read() == ''
            for pid in pids + [child_pid, dead_child_pid]:
                try:
                    os.kill(pid, 0)
                except ProcessLookupError:
                    continue
                stat = Path(f'/proc/{pid}/stat')
                if stat.exists() and stat.read_text().split()[2] == 'Z':
                    continue
                raise AssertionError(f'worker or child survived shutdown: {pid}')
        finally:
            if process.poll() is None:
                process.kill(); process.wait()
            process.stdin.close(); process.stdout.close(); process.stderr.close()
            for pid_file in root.glob('*.pid'):
                try:
                    os.kill(int(pid_file.read_text()), 9)
                except ProcessLookupError:
                    pass
        return {'python': 'offline seccomp control, A/B/A, replacement, hash/missing, stdout and semantic controls passed',
                'medaka': 'live lifecycle unavailable (candidate disqualified)'}


if __name__ == '__main__':
    result = exercise('paired', {'bundle': sys.argv[1], 'supervisor': sys.argv[2], 'checkout': sys.argv[3]})
    for candidate, observation in result.items():
        print(candidate + ': ' + observation)
