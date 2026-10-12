#!/usr/bin/env python3
"""Run sequential Medaka check measurements; retain raw logs and provenance JSON."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import signal
import subprocess
import sys
import time


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def git(root: Path, *args: str) -> str:
    return subprocess.run(['git', '-C', str(root), *args], check=True,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout.decode().strip()


def gc_stats(log: str) -> dict:
    """Boehm 8.2 text counters exclude allocations after the last collection."""
    cycles = re.findall(r'Marking for collection #(\d+) after (\d+) allocated bytes', log)
    durations = re.findall(r'Complete collection took (\d+) ms (\d+) ns', log)
    heaps = re.findall(r'GC #\d+ freed (-?\d+) bytes, heap (\d+) KiB', log)
    return {
        'collections_logged': len(cycles),
        'collection_durations_logged': len(durations),
        'allocated_bytes_at_collection_boundaries': sum(int(size) for _, size in cycles),
        'reported_freed_bytes': sum(int(size) for size, _ in heaps),
        'max_logged_heap_bytes': max((int(size) * 1024 for _, size in heaps), default=0),
        'full_collection_wall_seconds': sum(int(ms) / 1000 + int(ns) / 1e9 for ms, ns in durations),
        'limitations': 'Not nursery survival or exact live bytes; omits final allocation tail and lazy sweep outside collection.',
    }


def wait_child(child, seconds):
    def expired(signum, frame):
        raise TimeoutError(f'workload exceeded {seconds} seconds')
    previous = signal.signal(signal.SIGALRM, expired)
    signal.setitimer(signal.ITIMER_REAL, seconds)
    try:
        return os.wait4(child.pid, 0)
    except BaseException:
        child.kill()
        child.wait()
        raise
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', required=True, type=Path, help='Medaka checkout root')
    parser.add_argument('--binary', required=True, type=Path, help='medaka executable')
    parser.add_argument('--workload', required=True, type=Path, help='check target, absolute or relative to root')
    parser.add_argument('--repeats', type=int, default=3, help='sequential timing runs (default: 3)')
    parser.add_argument('--output', required=True, type=Path, help='new/empty directory for raw logs and JSON')
    parser.add_argument('--mode', choices=('timing', 'gc-stats'), default='timing')
    parser.add_argument('--heap-size', default='2147483648')
    parser.add_argument('--free-space-divisor', default='1')
    parser.add_argument('--timeout', type=float, default=180, help='seconds per run')
    args = parser.parse_args()

    root = args.root.resolve(strict=True)
    binary = args.binary.resolve(strict=True)
    workload = args.workload if args.workload.is_absolute() else root / args.workload
    workload = workload.resolve(strict=True)
    if args.repeats < 1:
        parser.error('--repeats must be positive')
    if args.timeout <= 0:
        parser.error('--timeout must be positive')
    runs = 1 if args.mode == 'gc-stats' else args.repeats
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error(f'output directory is nonempty: {output}')
    output.mkdir(parents=True, exist_ok=True)

    inherited_gc = {key: value for key, value in os.environ.items() if key.startswith('GC_')}
    env = os.environ.copy()
    for key in inherited_gc:
        env.pop(key, None)
    env.update({
        'MEDAKA_ROOT': str(root),
        'MEDAKA_STRICT': '1',
        'GC_INITIAL_HEAP_SIZE': args.heap_size,
        'GC_FREE_SPACE_DIVISOR': args.free_space_divisor,
    })
    if args.mode == 'gc-stats':
        env['GC_PRINT_STATS'] = '1'
    command = [str(binary), 'check', str(workload)]
    git_head = git(root, 'rev-parse', 'HEAD')
    git_status = git(root, 'status', '--porcelain')
    diff_hash = sha256_bytes(subprocess.run(
        ['git', '-C', str(root), 'diff', '--binary', 'HEAD'], check=True,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    ).stdout)
    records = []
    for index in range(1, runs + 1):
        label = f'{workload.stem}_{args.mode}_{index}'
        prefix = output / label
        stdout_path = prefix.with_suffix('.stdout')
        stderr_path = prefix.with_suffix('.stderr')
        start = time.perf_counter()
        with stdout_path.open('wb') as stdout, stderr_path.open('wb') as stderr:
            child = subprocess.Popen(command, cwd=root, env=env, stdout=stdout, stderr=stderr)
            _, status, usage = wait_child(child, args.timeout)
        elapsed = time.perf_counter() - start
        if os.WIFEXITED(status):
            returncode = os.WEXITSTATUS(status)
        else:
            returncode = -os.WTERMSIG(status)
        child.returncode = returncode
        # wait4 ru_maxrss is KiB on Linux and bytes on macOS.
        peak_rss_bytes = int(usage.ru_maxrss * (1024 if sys.platform.startswith('linux') else 1))
        record = {
            'label': label,
            'mode': args.mode,
            'root': str(root),
            'git_head': git_head,
            'git_status': git_status,
            'git_diff_head_sha256': diff_hash,
            'platform': platform.platform(),
            'binary': str(binary),
            'binary_sha256': sha256_file(binary),
            'workload': str(workload),
            'workload_sha256': sha256_file(workload),
            'command': command,
            'environment': {key: value for key, value in env.items()
                            if key.startswith('GC_') or key in ('MEDAKA_ROOT', 'MEDAKA_STRICT')},
            'inherited_gc_environment_cleared': inherited_gc,
            'gc_print_stats': args.mode == 'gc-stats',
            'returncode': returncode,
            'elapsed_seconds': elapsed,
            'peak_rss_bytes': peak_rss_bytes,
            'stdout': {'path': str(stdout_path), 'bytes': stdout_path.stat().st_size,
                       'sha256': sha256_file(stdout_path)},
            'stderr': {'path': str(stderr_path), 'bytes': stderr_path.stat().st_size,
                       'sha256': sha256_file(stderr_path)},
        }
        if args.mode == 'gc-stats':
            record['gc_stats'] = gc_stats(stderr_path.read_text(errors='replace'))
            if not record['gc_stats']['collections_logged']:
                raise RuntimeError('no Boehm collection statistics found; this run cannot establish GC cost')
            if record['gc_stats']['collections_logged'] != record['gc_stats']['collection_durations_logged']:
                raise RuntimeError('incomplete Boehm collection durations; inspect the preserved raw log')
        (prefix.with_suffix('.json')).write_text(json.dumps(record, indent=2) + '\n')
        records.append(record)
        print(json.dumps({
            'label': label, 'returncode': returncode,
            'elapsed_seconds': elapsed, 'peak_rss_bytes': peak_rss_bytes,
            'stdout_sha256': record['stdout']['sha256'],
            'stderr_sha256': record['stderr']['sha256'],
        }))
    stdout_hashes = {record['stdout']['sha256'] for record in records}
    stderr_hashes = {record['stderr']['sha256'] for record in records}
    summary = {
        'mode': args.mode,
        'root': str(root),
        'git_head': git_head,
        'git_status': git_status,
        'git_diff_head_sha256': diff_hash,
        'platform': platform.platform(),
        'binary': str(binary),
        'binary_sha256': sha256_file(binary),
        'workload': str(workload),
        'workload_sha256': sha256_file(workload),
        'environment': {key: value for key, value in env.items()
                        if key.startswith('GC_') or key in ('MEDAKA_ROOT', 'MEDAKA_STRICT')},
        'inherited_gc_environment_cleared': inherited_gc,
        'runs': [record['label'] for record in records],
        'stdout_hashes_match': len(stdout_hashes) == 1,
        'stderr_hashes_match': len(stderr_hashes) == 1,
        'returncodes': [record['returncode'] for record in records],
    }
    (output / f'{workload.stem}_{args.mode}_summary.json').write_text(
        json.dumps(summary, indent=2) + '\n'
    )
    return 0 if (all(record['returncode'] == 0 for record in records)
                 and len(stdout_hashes) == len(stderr_hashes) == 1) else 1


if __name__ == '__main__':
    raise SystemExit(main())
