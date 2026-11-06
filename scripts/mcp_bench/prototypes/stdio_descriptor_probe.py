#!/usr/bin/env python3
"""Observe the shared descriptor-hook experiment; 77 is a blocker, never PASS."""

import argparse
import difflib
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    root, out = args.root.resolve(), args.out.resolve()
    if not args.root.is_absolute() or not args.out.is_absolute() or out == root or root in out.parents or out.exists():
        parser.error('absolute checkout and new external output directory required')
    out.mkdir(parents=True)
    rows = []

    def save(name, status, **fields):
        row = dict(name=name, status=status, **fields)
        rows.append(row)
        (out / 'results.json').write_text(json.dumps(rows, indent=2) + '\n')
        print(json.dumps(row), flush=True)
        return row

    def require(name, condition, **fields):
        save(name, 'PASS' if condition else 'FAIL', **fields)
        if not condition:
            raise RuntimeError(name)

    def digest(path):
        return hashlib.sha256(path.read_bytes()).hexdigest()

    pins = ['runtime/medaka_rt.c', 'runtime/medaka_process.c',
            'scripts/mcp_bench/prototypes/stdio_descriptor_fixture.c',
            'scripts/mcp_bench/prototypes/stdio_descriptor_probe.py',
            'scripts/mcp_bench/prototypes/stdio_descriptor_census.py']
    save('source_pins', 'OBSERVED', sha256={p: digest(root / p) for p in pins},
         head=subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD'], text=True).strip())
    if sys.platform != 'linux':
        save('qualification', 'UNAVAILABLE', reason='Linux-only experiment; no matrix executed', exit_code=77)
        return 77
    save('identity', 'OBSERVED', uid=os.getuid(), euid=os.geteuid(),
         process_status=[line for line in Path('/proc/self/status').read_text().splitlines()
                 if line.startswith(('CapEff:', 'NoNewPrivs:', 'Uid:', 'Gid:'))],
         assumptions='No hostile external descriptor holder or privileged tracer excluded by this experiment; parent-fd protection unsupported.')

    def command(name, argv):
        result = subprocess.run(list(map(str, argv)), cwd=out, capture_output=True, timeout=120,
                                env=dict(os.environ, MEDAKA_STRICT='1'))
        save(name, 'PASS' if result.returncode == 0 else 'FAIL', argv=list(map(str, argv)),
             rc=result.returncode, stdout_hex=result.stdout.hex(), stderr_hex=result.stderr.hex())
        if result.returncode:
            raise RuntimeError(name)

    transformations = []
    for relative, name in [('runtime/medaka_rt.c', 'stdio_descriptor_runtime.c'),
                           ('runtime/medaka_process.c', 'stdio_descriptor_process.c')]:
        original = (root / relative).read_text()
        transformed, opens = re.subn(r'\bopen\(', 'descriptor_open(', original)
        transformed, fopens = re.subn(r'\bfopen\(', 'descriptor_fopen(', transformed)
        path = out / name
        path.write_text(transformed)
        patch = out / (name + '.patch')
        patch.write_text(''.join(difflib.unified_diff(original.splitlines(True), transformed.splitlines(True),
                                                   fromfile=relative, tofile=name)))
        transformations.append(dict(source=relative, transformed=name, open_replacements=opens,
                                    fopen_replacements=fopens, sha256=digest(path), patch_sha256=digest(patch)))
    save('experimental_transformation', 'OBSERVED', files=transformations,
         scope='All lexical open/fopen sites in scratch runtime and process owner, including comments; production files unchanged. Other routes are not interlocked.')
    exe = out / 'stdio-descriptor-fixture'
    command('build', shlex.split(os.environ.get('CC', 'clang')) + [
        '-O1', '-std=c11', '-DMDK_PROCESS_TESTING', '-ffunction-sections', '-fdata-sections',
        '-I' + str(out), '-I' + str(root / 'runtime'),
        str(root / pins[2]),
        '-Wl,--gc-sections', '-lgc', '-lm', '-pthread', '-o', str(exe)])
    seed = b'\x00\xffA\xc3\x28Z'
    counter = 0

    def case(name, op, path, mutation='none', mode='content'):
        nonlocal counter
        counter += 1
        inp, writer = os.pipe()
        reader, output = os.pipe()
        report = out / ('case-%03d.jsonl' % counter)
        receipt = out / ('case-%03d.read' % counter)
        process = None
        try:
            os.set_blocking(inp, False)
            os.set_blocking(output, False)
            for offset in range(0, len(seed), 2):
                os.write(writer, seed[offset:offset + 2])
            os.close(writer)
            writer = -1
            with report.open('wb') as log:
                argv = [str(exe), str(log.fileno()), mode, op, str(path), mutation]
                process = subprocess.Popen(argv, cwd=out, stdin=inp, stdout=output, stderr=subprocess.PIPE,
                                           pass_fds=(log.fileno(),),
                                           env=dict(os.environ, DESCRIPTOR_READ_RECEIPT=str(receipt)))
                os.close(output)
                output = -1
                try:
                    _, stderr = process.communicate(timeout=25)
                except subprocess.TimeoutExpired:
                    process.kill()
                    _, stderr = process.communicate()
                    save(name, 'FAIL', reason='timeout; fixture killed/reaped; worker/thread cleanup unproved',
                         fixture_pid=process.pid, stderr_hex=stderr.hex(), cleanup_incomplete=True)
                    raise RuntimeError(name)
            observed = os.read(reader, 65536)
            remaining = os.read(inp, 65536)
            details = [json.loads(line) for line in report.read_bytes().splitlines()]
            worker_pids = [r['value'] for r in details if r['name'] == 'worker_pid']
            return save(name, 'OBSERVED', argv=argv, mutation=mutation, rc=process.returncode,
                        input_hex=seed.hex(), endpoint_hex=observed.hex(), remaining_hex=remaining.hex(),
                        stderr_hex=stderr.hex(), reports=details, fixture_reaped=True,
                        worker_pids=worker_pids,
                        worker_pids_absent=all(not Path('/proc/%d' % pid).exists() for pid in worker_pids),
                        read_receipt=str(receipt) if receipt.exists() else None)
        finally:
            if process is not None and process.poll() is None:
                process.kill()
                process.wait()
            for fd in (inp, writer, reader, output):
                if fd >= 0:
                    os.close(fd)

    def value(row, name):
        return next(r['value'] for r in row['reports'] if r['name'] == name)

    def intact(row):
        return row['endpoint_hex'] == '' and row['remaining_hex'] == seed.hex()

    # Exact returned read bytes and external file effects are separate from Result reports.
    for relative in ('stdlib/core.mdk', 'compiler/medaka.toml'):
        row = case('required_read_' + relative.replace('/', '_'), 'read', root / relative)
        require('required_read_bytes', row['rc'] == 0 and value(row, 'content_ok') == 1 and intact(row)
                and Path(row['read_receipt']).read_bytes() == (root / relative).read_bytes())
    scratch = out / 'request'
    telemetry = out / 'telemetry'
    for op, path, initial, expected in [('write', scratch, b'OLD', b'BYTES\n'),
                                       ('append', telemetry, b'EVENT\n', b'EVENT\nBYTES\n'),
                                       ('telemetry', telemetry, b'EVENT\n', b'EVENT\nBYTES\n'),
                                       ('write-bytes', scratch, b'OLD', b'\xff\x00R'),
                                       ('write-mode', scratch, b'OLD', b'BYTES\n')]:
        path.write_bytes(initial)
        row = case('required_' + op, op, path)
        require('required_file_effect_' + op, row['rc'] == 0 and value(row, 'content_ok') == 1
                and intact(row) and path.read_bytes() == expected
                and (op != 'write-mode' or path.stat().st_mode & 0o777 == 0o600))
    scratch.unlink()
    row = case('required_scratch_create', 'write', scratch)
    require('required_scratch_created', row['rc'] == 0 and intact(row) and scratch.read_bytes() == b'BYTES\n')

    aliases = ['/proc/self/fd/{fd}', '/dev/fd/{fd}', '/dev/std{direction}', str(out / 'alias-{fd}')]
    operations = ['read', 'hash', 'read-bytes', 'write', 'append', 'telemetry', 'write-bytes', 'write-mode', 'fsync']
    for fd in (0, 1):
        for template in aliases:
            path = template.format(fd=fd, direction='in' if fd == 0 else 'out')
            if template.startswith(str(out)):
                Path(path).symlink_to('/proc/self/fd/%d' % fd)
            for op in operations:
                row = case('alias_%d_%s_%s' % (fd, aliases.index(template), op), op, path)
                require('alias_denied_before_effect', row['rc'] == 0 and intact(row)
                        and value(row, 'content_ok') == 0)
    row = case('identity_mutation_write', 'append', '/proc/self/fd/1', 'identity')
    require('identity_mutation_rejected_by_observer', row['rc'] == 0 and row['endpoint_hex'] == b'BYTES\n'.hex()
            and row['remaining_hex'] == seed.hex())
    row = case('identity_mutation_read', 'hash', '/proc/self/fd/0', 'identity')
    require('identity_read_mutation_rejected_by_observer', row['rc'] == 0 and row['remaining_hex'] == ''
            and row['endpoint_hex'] == '')

    marker = out / 'worker-marker'
    row = case('shared_policy_piped_worker', 'piped', marker, mode='worker')
    require('required_piped_worker', row['rc'] == 0 and intact(row) and marker.exists()
            and marker.read_bytes() == b'' and value(row, 'worker_disposed') == 1
            and value(row, 'worker_exit') == 0 and value(row, 'owner_roots_after_dispose') == 0
            and row['worker_pids'] and row['worker_pids_absent'])
    marker.unlink()
    row = case('shared_policy_null_worker', 'null', marker, mode='worker')
    require('shared_policy_worker_blocker', row['rc'] == 77 and intact(row) and not marker.exists()
            and any(r['name'] == 'type_denied' and r['value'] == 0o20000 for r in row['reports'])
            and any(r['name'] == 'launch_failed' and r['errno'] == 22 for r in row['reports'])
            and value(row, 'owner_roots_after_failure') == 0,
            reason='Real owner cannot open character-device /dev/null under the shared content type policy.')
    row = case('type_mutation_worker', 'null', marker, 'types', mode='worker')
    require('type_mutation_restores_required_worker', row['rc'] == 0 and intact(row) and marker.exists()
            and marker.read_bytes() == b'' and value(row, 'worker_disposed') == 1
            and value(row, 'worker_exit') == 0 and value(row, 'owner_roots_after_dispose') == 0
            and row['worker_pids'] and row['worker_pids_absent'])
    marker.unlink()

    supported = ['all nine runtime file families reject both endpoints via proc/dev/symlink aliases',
                 'fragmented/non-UTF-8 input remains exact', 'regular source/config exact reads',
                 'telemetry append and scratch create/write/mode exact effects',
                 'independent identity mutation produces bytes/consumes input',
                 'real piped owner submits/reaps/disposes marker worker; shared content type policy blocks Null mode and type-only mutation restores it']
    unsupported = ['pathname swap during open and fd replacement/reuse races',
                   'wrong endpoint types/flags, shared endpoints or stderr and injected open/stat/identity errors',
                   'directories for fsync and other special-file compatibility',
                   'acquisition/release/reacquisition, historical/in-flight use and synchronization',
                   'all four resolver/NSS routes, HOSTALIASES on Err and resolver acquisition races',
                   'legacy launch and buffered/raw/automatic/abort/stash/flush output interlocks',
                   'parent-fd reopen, dumpability enforcement and hostile external descriptor holders',
                   'bounded backpressure, no-progress/blocking, cancellation/deadline and prefix/no-replay',
                   'compiled Medaka entry enforcement and full census semantic classification',
                   'independent disabling mutations for acquisition/type-validation/order/lifetime; only identity and type policy controls executed']
    for number, reason in enumerate(unsupported, 1):
        save('unsupported_%02d' % number, 'UNSUPPORTED', reason=reason)
    scratch.unlink()
    telemetry.unlink()
    save('cleanup', 'OBSERVED', fixture_cases=counter, exact_fixtures_waited=True,
         worker='failed launch terminated before marker; type mutation reached worker_disposed; no child ownership timeout',
         scope='Observer fds closed; candidate pins closed; private content files removed; raw evidence and symlinks retained.')
    save('qualification', 'BLOCKED', exit_code=77, supported=supported, unsupported=unsupported,
         production_boundary_qualified=False, compiled_entry_qualified=False,
         blocker='A common descriptor content type policy reaches the real owner /dev/null opens and prevents Null-mode worker creation. Piped worker creation succeeds; this is a placement/type-policy compatibility blocker, not impossibility of the narrower design.',
         next_action='Recut an experimental boundary with explicit provenance for trusted owner /dev/null opens, without pathname exemptions for caller-controlled content, then implement and attack all unsupported rows.')
    return 77


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (RuntimeError, OSError, subprocess.SubprocessError) as error:
        print('descriptor observer failed: ' + str(error), file=sys.stderr)
        sys.exit(1)
