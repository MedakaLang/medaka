"""Measure installed prototypes on Linux; write raw per-session observations."""
import json
import os
from pathlib import Path
import resource
import subprocess
import sys
import time

from exercise import exchange, offline, request, semantic
from external import digest
from package import assemble


def timed(fn):
    start = time.monotonic_ns()
    value = fn()
    return value, time.monotonic_ns() - start


def high_water(pid):
    for line in Path(f'/proc/{pid}/status').read_text().splitlines():
        if line.startswith('VmHWM:'):
            return int(line.split()[1]) * 1024
    return None


def measure(bundle, supervisor, destination):
    root = Path(destination)
    root.mkdir(parents=True, exist_ok=True)
    workspace = root / 'workspace'
    workspace.mkdir(exist_ok=True)
    (workspace / 'probe.mdk').write_text('main = "x" + 1\n')
    manifests = {}
    packaging = {}
    for candidate in ('python', 'medaka'):
        manifests[candidate], packaging[candidate] = timed(lambda: assemble(
            candidate, {'bundle': bundle, 'supervisor': supervisor}, [], root / candidate))
    rows = []
    for repetition in range(5):
        start = time.monotonic_ns()
        failure = subprocess.run([str(root / 'medaka' / 'supervisor')], cwd=workspace,
                                 capture_output=True, text=True, preexec_fn=offline)
        rows.append({'candidate': 'medaka', 'repetition': repetition,
                     'launch_to_exit_ns': time.monotonic_ns() - start,
                     'exit': failure.returncode, 'stdout': failure.stdout,
                     'semantic_query': 'unavailable'})
        assert 'unavailable' in failure.stdout
        before = resource.getrusage(resource.RUSAGE_CHILDREN)
        start = time.monotonic_ns()
        process = subprocess.Popen([sys.executable, str(root / 'python' / 'external.py')],
                                   cwd=workspace, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, text=True, preexec_fn=offline)
        try:
            init = exchange(process, {'type': 'initialize', 'versions': [1]})
            init_ns = time.monotonic_ns() - start
            assert init['version'] == 1
            worker = manifests['python']['worker']
            opened, open_ns = timed(lambda: exchange(process, request('open', 'A', 'openWorkspace',
                {'root': str(workspace), 'artifact': {'id': worker, 'digest': digest(worker)}})))
            pid = opened['result']['pid']
            timings = []
            for i in range(6):
                result, elapsed = timed(lambda: exchange(process, request(str(i), 'A', 'check', {'file': 'probe.mdk'})))
                semantic(result, True)
                timings.append(elapsed)
            memory = {'supervisor_vmhwm_bytes': high_water(process.pid), 'worker_vmhwm_bytes': high_water(pid)}
            process.stdin.write('{"type":"shutdown"}\n'); process.stdin.flush()
            assert process.wait(timeout=10) == 0
            stderr = process.stderr.read()
            assert not stderr
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                pass
            else:
                raise AssertionError('worker survived shutdown')
            after = resource.getrusage(resource.RUSAGE_CHILDREN)
            rows.append({'candidate': 'python', 'repetition': repetition,
                         'launch_to_initialize_ns': init_ns, 'open_worker_ns': open_ns,
                         'first_query_ns': timings[0], 'warm_query_ns': timings[1:],
                         'cpu_user_seconds': after.ru_utime - before.ru_utime,
                         'cpu_system_seconds': after.ru_stime - before.ru_stime,
                         **memory, 'worker_reaped': True})
        finally:
            if process.poll() is None:
                process.kill(); process.wait()
            process.stdin.close(); process.stdout.close(); process.stderr.close()
    return {'packaging_ns': packaging, 'manifests': manifests, 'sessions': rows}


if __name__ == '__main__':
    result = measure(*sys.argv[1:4])
    print(json.dumps(result, indent=2))
