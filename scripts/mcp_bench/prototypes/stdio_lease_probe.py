#!/usr/bin/env python3
"""Observe fixed-site provenance and the compiled lease transport prerequisite."""

import argparse
import difflib
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import select
import shlex
import shutil
import subprocess
import sys
import time


OPERATIONS = ('read', 'hash', 'read-bytes', 'write', 'append', 'telemetry',
              'write-bytes', 'write-mode', 'fsync')
ALIASES = ('/proc/self/fd/{fd}', '/dev/fd/{fd}', '/dev/std{direction}', 'symlink')
SOURCE_HASHES = {
    'runtime/medaka_rt.c': '58f181d69091a7722bc845329035f9389cd02767c9db4aab3dc0402e7b4558bd',
    'runtime/medaka_process.c': '63f394aabd70597d8a343620b80da1731ad91d382061fec541f07647b1558242',
}
PREFIX = 'scripts/mcp_bench/prototypes/'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


COMPILED_CASES = {'compiled_legacy_guard', 'compiled_partial_read_control',
                  'compiled_lossy_read_control'}
UNEXECUTED = [
    'endpoint directions/types/flags/shared identities/distinct stderr rejection matrix',
    'pathname swaps, fd replacement/reuse, same-checked-fd use and open/stat failure controls',
    'no destructive open before validation under injected failures',
    'prior/in-flight buffered output and resolver admission/history synchronization',
    'release/reacquisition and error-retained ownership',
    'resolver/NSS pre-libc exclusion, HOSTALIASES error paths and disabling controls',
    'legacy/raw/buffered/automatic/abort/stash/flush output including #4865 actual primitive',
    'legacy launch interlocks and disabling controls',
    'fresh-stdio child parent-fd reopen with identity/dumpability controls',
    'compiled lease byte transport with acknowledged staggered producer/consumer overlap',
    'scheduler-safe backpressure with status/control progress',
    'Deadline/CancelToken termination and committed write prefixes without replay',
    'directory-fsync compatibility policy (owner-only disposition remains rejection)',
    'supervisor toolchain selection under a complete enforced lease',
]


def expected_cases(scope='lease'):
    names = {'required_read_source', 'required_read_config', 'required_write',
             'required_append', 'required_telemetry', 'required_write-bytes',
             'required_write-mode', 'required_scratch_create',
             'required_regular_fsync', 'directory_fsync', 'directory_control',
             'identity_write_control', 'identity_read_control',
             'worker_piped', 'worker_null', 'owner_disabled_control',
             'owner_overlap', 'ambient_control', 'sticky_control',
             'setup_rollback', 'rollback_disabled_control', 'cleanup_control'}
    names.update('alias_%d_%d_%s' % (fd, alias, op)
                 for fd in (0, 1) for alias in range(len(ALIASES)) for op in OPERATIONS)
    names.update('caller_null_' + op for op in OPERATIONS)
    names.update('pathname_control_' + op for op in OPERATIONS)
    if scope == 'lease':
        names.update(COMPILED_CASES)
    return names


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--scope', choices=('owner', 'lease'), default='lease')
    args = parser.parse_args()
    root, out = args.root.resolve(), args.out.resolve()
    if not args.root.is_absolute() or not args.out.is_absolute() or out == root or root in out.parents or out.exists():
        parser.error('absolute checkout and new external output directory required')
    out.mkdir(parents=True)
    rows, cases = [], []

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

    pins = list(SOURCE_HASHES) + ['runtime/medaka_runtime.h', 'runtime/medaka_process.h', 'runtime/medaka_abi.h'] + [PREFIX + name for name in (
        'stdio_lease_fixture.c', 'stdio_lease_probe.py', 'stdio_descriptor_census.py',
        'stdio_lease_cases/legacy_read.mdk')]
    save('source_pins', 'OBSERVED', sha256={p: digest(root / p) for p in pins},
         head=subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD'], text=True).strip())
    save('expected_cases', 'OBSERVED', identities=sorted(expected_cases(args.scope)), scope=args.scope)
    if sys.platform != 'linux':
        save('qualification', 'UNAVAILABLE', exit_code=77, qualified=False,
             unmet_prerequisites=['Linux anonymous nonblocking pipes and native owner facilities'],
             reason='Non-Linux experiment unavailable; no executable rows ran.')
        return 77
    save('environment', 'OBSERVED', uid=os.getuid(), euid=os.geteuid(),
         platform=platform.platform(), python=sys.version,
         process_status=[line for line in Path('/proc/self/status').read_text().splitlines()
                         if line.startswith(('CapEff:', 'NoNewPrivs:', 'Uid:', 'Gid:'))],
         assumptions=['No claim against hostile native code calling private C functions.',
                      'No parent-fd, dumpability, privileged tracer or external descriptor-holder protection.',
                      'Only startup descriptor claim and one legacy-reader guard are exercised on the compiled entry; no complete lease admission or transport.'])
    require('transform_source_pins', all(digest(root / p) == expected for p, expected in SOURCE_HASHES.items()))

    def replace_once(source, old, new):
        if source.count(old) != 1:
            raise RuntimeError('unmapped source drift: ' + old)
        return source.replace(old, new)

    transformations = []
    for relative, name in [('runtime/medaka_rt.c', 'stdio_lease_runtime.c'),
                           ('runtime/medaka_process.c', 'stdio_lease_process.c')]:
        original = (root / relative).read_text()
        if relative.endswith('medaka_rt.c'):
            transformed, opens = re.subn(r'\bopen\(', 'content_open(', original)
            transformed, fopens = re.subn(r'\bfopen\(', 'content_fopen(', transformed)
            if (opens, fopens) != (5, 7):
                raise RuntimeError('unmapped content-open sites')
            transformed = replace_once(transformed,
                'long long mdk_read_exactly(long long n_tagged) {',
                'static long long original_read_exactly(long long n_tagged) {')
            details = dict(open_replacements=opens, fopen_replacements=fopens,
                           legacy_reader_definition_replacements=1)
        else:
            transformed = replace_once(original,
                'open("/dev/null", (i ? O_WRONLY : O_RDONLY) | O_CLOEXEC)', 'owner_null(i)')
            transformed = replace_once(transformed, 'GC_do_blocking(wait_submission, NULL);',
                'GC_do_blocking(wait_submission, NULL);\n    if (atomic_load(&shutdown_owner)) break;')
            transformed = replace_once(transformed, 'PTHREAD_CREATE_DETACHED', 'PTHREAD_CREATE_JOINABLE')
            transformed = replace_once(transformed,
                'GC_pthread_create(&worker, &attr, submission_worker, NULL)',
                'GC_pthread_create(&owner_thread, &attr, submission_worker, NULL)')
            transformed = replace_once(transformed,
                'if (child[i] >= 0) close(child[i]);',
                'if (child[i] >= 0 && !disabled("cleanup")) close(child[i]);')
            details = dict(owner_literal_replacements=1, joinable_observer_lifecycle=True)
        path = out / name
        path.write_text(transformed)
        patch = out / (name + '.patch')
        patch.write_text(''.join(difflib.unified_diff(original.splitlines(True), transformed.splitlines(True),
                                                   fromfile=relative, tofile=name)))
        transformations.append(dict(source=relative, transformed=name, **details,
                                    sha256=digest(path), patch_sha256=digest(patch)))
    save('experimental_transformation', 'OBSERVED', files=transformations,
         scope='External scratch only. One fixed owner operand site; caller hooks have no owner authority. readExactly definition is renamed for one compiled legacy-reader guard/control. Shutdown/join instrumentation only after empty owner roots and submission slots.')

    argv = shlex.split(os.environ.get('CC', 'clang')) + [
        '-O1', '-std=c11', '-DMDK_PROCESS_TESTING', '-ffunction-sections', '-fdata-sections',
        '-I' + str(out), '-I' + str(root / 'runtime'), str(root / (PREFIX + 'stdio_lease_fixture.c')),
        '-Wl,--gc-sections', '-lgc', '-lm', '-pthread', '-o', str(out / 'stdio-lease-fixture')]
    compiler_path = Path(shutil.which(argv[0]) or argv[0]).resolve()
    compiler = subprocess.run([argv[0], '--version'], capture_output=True, timeout=10)
    require('compiler_environment', compiler.returncode == 0, path=str(compiler_path),
            sha256=digest(compiler_path), version=compiler.stdout.decode(), stderr_hex=compiler.stderr.hex())
    built = subprocess.run(argv, cwd=out, capture_output=True, timeout=120,
                           env=dict(os.environ, MEDAKA_STRICT='1'))
    require('build', built.returncode == 0, argv=argv, rc=built.returncode,
            stdout_hex=built.stdout.hex(), stderr_hex=built.stderr.hex())
    save('binary_pin', 'OBSERVED', path=str(out / 'stdio-lease-fixture'), sha256=digest(out / 'stdio-lease-fixture'))
    seed = b'\x00\xffA\xc3\x28Z'

    def case(name, op, path, mutation='none', mode='content'):
        if name in cases:
            raise RuntimeError('duplicate case: ' + name)
        cases.append(name)
        inp, writer = os.pipe()
        reader, output = os.pipe()
        report = out / ('case-%03d.jsonl' % len(cases))
        receipt = out / ('case-%03d.read' % len(cases))
        wire = out / ('case-%03d.wire' % len(cases))
        process = None
        try:
            os.set_blocking(inp, False)
            os.set_blocking(output, False)
            os.write(writer, seed)
            os.close(writer)
            writer = -1
            with report.open('wb') as log:
                argv = [str(out / 'stdio-lease-fixture'), str(log.fileno()), mode, op, str(path), mutation]
                process = subprocess.Popen(argv, cwd=out, stdin=inp, stdout=output, stderr=subprocess.PIPE,
                    pass_fds=(log.fileno(),), env=dict(os.environ, LEASE_READ_RECEIPT=str(receipt),
                                                                    LEASE_WORKER_RECEIPT=str(wire)))
                os.close(output)
                output = -1
                try:
                    _, stderr = process.communicate(timeout=25)
                except subprocess.TimeoutExpired:
                    process.kill()
                    _, stderr = process.communicate()
                    save(name, 'FAIL', reason='timeout; fixture killed and reaped; owner cleanup unproved',
                         fixture_pid=process.pid, stderr_hex=stderr.hex(), cleanup_incomplete=True)
                    raise RuntimeError(name)
            observed = os.read(reader, 65536)
            remaining = os.read(inp, 65536)
            details = [json.loads(line) for line in report.read_bytes().splitlines()]
            worker_pids = [r['value'] for r in details if r['name'] == 'worker_pid']
            row = save(name, 'OBSERVED', case=True, argv=argv, mutation=mutation, rc=process.returncode,
                input_hex=seed.hex(), endpoint_hex=observed.hex(), remaining_hex=remaining.hex(),
                stderr_hex=stderr.hex(), reports=details, fixture_reaped=True,
                worker_pids=worker_pids, worker_pids_absent=all(not Path('/proc/%d' % pid).exists() for pid in worker_pids),
                worker_wire_hex=wire.read_bytes().hex() if wire.exists() else None,
                read_receipt=str(receipt) if receipt.exists() else None)
            require(name + '_fixture', process.returncode in (0, 77) and stderr == b''
                    and value(row, 'claim') == 0)
            return row
        finally:
            if process is not None and process.poll() is None:
                process.kill()
                process.wait()
            for fd in (inp, writer, reader, output):
                if fd >= 0:
                    os.close(fd)

    def value(row, name):
        matches = [r['value'] for r in row['reports'] if r['name'] == name]
        if len(matches) != 1:
            raise RuntimeError('missing/duplicate report: ' + row['name'] + '/' + name)
        return matches[0]

    def intact(row):
        return row['endpoint_hex'] == '' and row['remaining_hex'] == seed.hex()

    for name, relative in [('source', 'stdlib/core.mdk'), ('config', 'compiler/medaka.toml')]:
        row = case('required_read_' + name, 'read', root / relative)
        require(name + '_exact_bytes', row['rc'] == 0 and value(row, 'content_ok') == 1 and intact(row)
                and Path(row['read_receipt']).read_bytes() == (root / relative).read_bytes())

    scratch, telemetry = out / 'request', out / 'telemetry'
    for op, path, initial, expected in [
        ('write', scratch, b'OLD', b'BYTES\n'),
        ('append', telemetry, b'EVENT\n', b'EVENT\nBYTES\n'),
        ('telemetry', telemetry, b'EVENT\n', b'EVENT\nBYTES\n'),
        ('write-bytes', scratch, b'OLD', b'\xff\x00R'),
        ('write-mode', scratch, b'OLD', b'BYTES\n')]:
        path.write_bytes(initial)
        row = case('required_' + op, op, path)
        require('exact_file_' + op, row['rc'] == 0 and value(row, 'content_ok') == 1 and intact(row)
                and path.read_bytes() == expected and (op != 'write-mode' or path.stat().st_mode & 0o777 == 0o600))
    scratch.unlink()
    row = case('required_scratch_create', 'write', scratch)
    require('scratch_created', row['rc'] == 0 and value(row, 'content_ok') == 1
            and intact(row) and scratch.read_bytes() == b'BYTES\n')
    row = case('required_regular_fsync', 'fsync', scratch)
    require('regular_fsync_succeeds', row['rc'] == 0 and value(row, 'content_ok') == 1
            and intact(row) and scratch.read_bytes() == b'BYTES\n')

    row = case('directory_fsync', 'fsync', out, mode='directory')
    require('directory_fsync_disposition', row['rc'] == 0 and value(row, 'content_ok') == 0 and intact(row)
            and any(r['name'] == 'type_denied' and r['value'] == 0o40000 for r in row['reports']),
            disposition='Directory fsync remains rejected by caller type policy; broader supervisor compatibility unqualified.')
    row = case('directory_control', 'fsync', out, 'directory', 'directory')
    require('directory_mutation_observed', row['rc'] == 0 and value(row, 'content_ok') == 1 and intact(row))

    for fd in (0, 1):
        for index, template in enumerate(ALIASES):
            path = template.format(fd=fd, direction='in' if fd == 0 else 'out')
            if template == 'symlink':
                path = out / ('alias-%d' % fd)
                path.symlink_to('/proc/self/fd/%d' % fd)
            for op in OPERATIONS:
                row = case('alias_%d_%d_%s' % (fd, index, op), op, path)
                require(row['name'] + '_denied', row['rc'] == 0 and intact(row) and value(row, 'content_ok') == 0)
    for op in OPERATIONS:
        row = case('caller_null_' + op, op, '/dev/null')
        require(row['name'] + '_denied', row['rc'] == 0 and intact(row) and value(row, 'content_ok') == 0
                and any(r['name'] == 'type_denied' for r in row['reports']))
        row = case('pathname_control_' + op, op, '/dev/null', 'pathname')
        # A raw device open is independent of operations whose own syscall rejects /dev/null.
        require(row['name'] + '_type_guard_disabled', row['rc'] == 0 and intact(row)
                and not any(r['name'] == 'type_denied' for r in row['reports'])
                and (op not in ('read', 'hash', 'read-bytes', 'append') or value(row, 'content_ok') == 1)
                and (op != 'read' or Path(row['read_receipt']).read_bytes() == b''))
    row = case('identity_write_control', 'append', '/proc/self/fd/1', 'identity')
    require('identity_write_detected', row['rc'] == 0 and value(row, 'content_ok') == 1
            and row['endpoint_hex'] == b'BYTES\n'.hex() and row['remaining_hex'] == seed.hex())
    row = case('identity_read_control', 'hash', '/proc/self/fd/0', 'identity')
    require('identity_read_detected', row['rc'] == 0 and value(row, 'content_ok') == 1
            and row['remaining_hex'] == '' and row['endpoint_hex'] == '')

    def worker_case(name, mode='worker', streams='null', mutation='none', leaked_fds=0):
        marker = out / (name + '.marker')
        row = case(name, streams, marker, mutation, mode)
        exists = marker.exists()
        require(name + '_cleanup', value(row, 'owner_thread_joined') == 1 and row['worker_pids_absent']
                and value(row, 'fds_after_worker') - value(row, 'fds_before_worker') == leaked_fds,
                external_marker=str(marker), marker_exists=exists,
                marker_hex=marker.read_bytes().hex() if exists else None)
        return row, marker

    def launched(row, marker):
        require(row['name'] + '_launched', row['rc'] == 0 and marker.exists() and marker.read_bytes() == b'CHILD\n'
                and value(row, 'worker_exit') == 0 and value(row, 'worker_disposed') == 1
                and value(row, 'owner_roots_after_dispose') == 0 and row['worker_pids']
                and next(r['errno'] for r in row['reports'] if r['name'] == 'worker_exit') == 0)

    def denied_attacks(row, prefix):
        return all(value(row, prefix + '_' + op) == 0 for op in OPERATIONS) and value(row, prefix + '_null_open') == 0

    row, marker = worker_case('worker_piped', streams='piped')
    launched(row, marker)
    require('piped_unchanged', intact(row) and value(row, 'owner_calls') == 0 and denied_attacks(row, 'after')
            and row['worker_wire_hex'] == b'WIRE\x00\xff\n'.hex() and value(row, 'worker_stream_eof') == 1)
    row, marker = worker_case('worker_null')
    launched(row, marker)
    require('null_owner_separated', intact(row) and value(row, 'owner_calls') == 3 and denied_attacks(row, 'after')
            and row['worker_wire_hex'] is None and value(row, 'worker_stream_closed') == 1
            and sum(r['name'] == 'owner_null_open' and r['errno'] == 1 for r in row['reports']) == 3)
    row, marker = worker_case('owner_disabled_control', mutation='owner')
    require('owner_control_recreates_null_blocker', row['rc'] == 77 and not marker.exists() and intact(row)
            and value(row, 'owner_roots_after_failure') == 0
            and any(r['name'] == 'launch_failed' and r['errno'] == 22 for r in row['reports']))

    row, marker = worker_case('owner_overlap', mode='overlap')
    launched(row, marker)
    require('nested_and_concurrent_denied', intact(row) and value(row, 'owner_held') == 1
            and value(row, 'nested_endpoint_open') == 0 and value(row, 'nested_null_open') == 0
            and denied_attacks(row, 'concurrent') and denied_attacks(row, 'after'))
    row, marker = worker_case('ambient_control', mode='overlap', mutation='ambient')
    launched(row, marker)
    require('ambient_leak_detected', row['remaining_hex'] == '' and row['endpoint_hex'].startswith(b'NESTED\n'.hex())
            and value(row, 'nested_endpoint_open') == 1 and value(row, 'nested_null_open') == 1
            and value(row, 'concurrent_null_open') == 1 and value(row, 'concurrent_append') == 1
            and denied_attacks(row, 'after'))
    row, marker = worker_case('sticky_control', mode='overlap', mutation='sticky')
    launched(row, marker)
    require('sticky_authority_detected', row['remaining_hex'] == '' and value(row, 'after_null_open') == 1
            and value(row, 'after_append') == 1 and row['endpoint_hex'].startswith(b'NESTED\n'.hex()))

    row, marker = worker_case('setup_rollback', mode='rollback')
    require('setup_failure_rolls_back', row['rc'] == 77 and not marker.exists() and intact(row)
            and value(row, 'injected_setup_failure') == 2 and value(row, 'owner_roots_after_failure') == 0
            and any(r['name'] == 'launch_failed' and r['errno'] == 5 for r in row['reports'])
            and denied_attacks(row, 'concurrent') and denied_attacks(row, 'after'))
    row, marker = worker_case('rollback_disabled_control', mode='rollback', mutation='rollback')
    launched(row, marker)
    require('rollback_injection_control', intact(row) and denied_attacks(row, 'after')
            and not any(r['name'] == 'injected_setup_failure' for r in row['reports']))
    row, marker = worker_case('cleanup_control', mode='rollback', mutation='cleanup', leaked_fds=1)
    require('rollback_cleanup_disabling_detected', row['rc'] == 77 and not marker.exists() and intact(row)
            and value(row, 'owner_roots_after_failure') == 0 and value(row, 'mutation_leak_reclaimed') == 1)

    require('exact_owner_case_matrix', len(cases) == len(expected_cases('owner'))
            and set(cases) == expected_cases('owner'),
            actual=sorted(cases), expected=sorted(expected_cases('owner')))

    if args.scope == 'lease':
        target = root / (PREFIX + 'stdio_lease_cases/legacy_read.mdk')
        reference = out / 'legacy-read-reference'
        command = [str(root / 'medaka'), 'build', '--keep-ir', str(target), '-o', str(reference)]
        built = subprocess.run(command, cwd=root, capture_output=True, timeout=120,
                               env=dict(os.environ, MEDAKA_STRICT='1'))
        require('compiled_target_build', built.returncode == 0, argv=command, rc=built.returncode,
                stdout_hex=built.stdout.hex(), stderr_hex=built.stderr.hex())
        ir = Path(str(reference) + '.ll')
        save('compiled_target_pins', 'OBSERVED', source_sha256=digest(target),
             compiler_sha256=digest(root / 'medaka'), reference_sha256=digest(reference), ir_sha256=digest(ir),
             scope='Unmodified generated IR linked to scratch runtime; target exposes only main and public readExactly.')
        compiled = out / 'compiled-lease-entry'
        command = argv[:-2] + ['-DLEASE_COMPILED', str(ir), '-o', str(compiled)]
        built = subprocess.run(command, cwd=out, capture_output=True, timeout=120)
        require('compiled_instrumented_link', built.returncode == 0, argv=command, rc=built.returncode,
                stdout_hex=built.stdout.hex(), stderr_hex=built.stderr.hex())
        save('compiled_binary_pin', 'OBSERVED', path=str(compiled), sha256=digest(compiled))

        def compiled_case(name, mutation, first):
            if name in cases:
                raise RuntimeError('duplicate case: ' + name)
            cases.append(name)
            inp, writer = os.pipe()
            reader, output = os.pipe()
            reports, report_write = os.pipe()
            control, control_write = os.pipe()
            fds = [inp, writer, reader, output, reports, report_write, control, control_write]
            process, events, pending = None, [], b''
            phases = []
            path = out / (name + '.jsonl')
            started = time.monotonic_ns()
            try:
                os.set_blocking(inp, False)
                os.set_blocking(output, False)
                process = subprocess.Popen([str(compiled), str(report_write), 'compiled', 'unused', 'unused', mutation],
                    cwd=out, stdin=inp, stdout=output, stderr=subprocess.PIPE,
                    pass_fds=(report_write, control),
                    env=dict(os.environ, LEASE_CONTROL_FD=str(control)))
                for fd in (output, report_write, control):
                    os.close(fd)
                    fds.remove(fd)

                def await_event(kind, call):
                    nonlocal pending
                    deadline = time.monotonic() + 15
                    while True:
                        while b'\n' in pending:
                            line, pending = pending.split(b'\n', 1)
                            event = json.loads(line)
                            events.append(event)
                            with path.open('ab') as log:
                                log.write(line + b'\n')
                            if event['name'] == kind and event.get('value') == call:
                                phases.append(dict(event=kind, call=call, elapsed_ns=time.monotonic_ns() - started))
                                return
                        left = deadline - time.monotonic()
                        if left <= 0 or not select.select([reports], [], [], left)[0]:
                            raise RuntimeError(name + ': barrier timeout')
                        data = os.read(reports, 65536)
                        if not data:
                            raise RuntimeError(name + ': report EOF before ' + kind)
                        pending += data

                def remaining():
                    try:
                        return os.read(inp, 65536)
                    except BlockingIOError:
                        return b''

                await_event('read_ready', 1)
                require(name + '_starts_empty', remaining() == b'')
                os.write(writer, first)
                phases.append(dict(event='producer_first', hex=first.hex(), elapsed_ns=time.monotonic_ns() - started))
                os.write(control_write, b'R')
                await_event('read_returned', 1)
                first_remaining = remaining()
                await_event('read_ready', 2)
                os.write(writer, b'\xff')
                phases.append(dict(event='producer_second', hex='ff', elapsed_ns=time.monotonic_ns() - started))
                os.write(control_write, b'R')
                await_event('read_returned', 2)
                second_remaining = remaining()
                os.close(writer)
                fds.remove(writer)
                _, stderr = process.communicate(timeout=15)
                tail = pending
                while True:
                    data = os.read(reports, 65536)
                    if not data:
                        break
                    tail += data
                if tail:
                    with path.open('ab') as log:
                        log.write(tail)
                    events.extend(json.loads(line) for line in tail.splitlines())
                endpoint = os.read(reader, 65536)
                row = save(name, 'OBSERVED', case=True, mutation=mutation, rc=process.returncode,
                    reports=events, stderr_hex=stderr.hex(), endpoint_hex=endpoint.hex(),
                    first_sent_hex=first.hex(), first_remaining_hex=first_remaining.hex(),
                    second_sent_hex='ff', second_remaining_hex=second_remaining.hex(),
                    phases=phases, fixture_reaped=True, worker_pids=[], worker_pids_absent=True,
                    raw_receipt=str(path))
                require(name + '_lifecycle', process.returncode == 0 and stderr == b'' and endpoint == b''
                        and value(row, 'claim') == 0 and value(row, 'compiled_main_returned') == 0
                        and value(row, 'owner_thread_joined') == 1
                        and value(row, 'fds_before_compiled') == value(row, 'fds_after_compiled')
                        and [r['call'] for r in events if r['name'] == 'read_result'] == [1, 2])
                return row
            finally:
                if process is not None and process.poll() is None:
                    process.kill()
                    process.wait()
                    save(name + '_cleanup', 'FAIL', cleanup_incomplete=True,
                         reason='Fixture killed and reaped; internal owner-thread cleanup unproved.')
                if process is not None and process.stderr is not None:
                    process.stderr.close()
                for fd in fds:
                    os.close(fd)

        row = compiled_case('compiled_legacy_guard', 'none', b'\x80')
        require('compiled_legacy_reader_excluded', row['first_remaining_hex'] == '80'
                and row['second_remaining_hex'] == 'ff'
                and [r['value'] for r in row['reports'] if r['name'] == 'legacy_read_denied'] == [1, 2]
                and all(not r['some'] and r['hex'] == '' for r in row['reports'] if r['name'] == 'read_result'))
        row = compiled_case('compiled_partial_read_control', 'legacy-read', b'\x80')
        results = [r for r in row['reports'] if r['name'] == 'read_result']
        require('compiled_partial_loss_observed', row['first_remaining_hex'] == ''
                and row['second_remaining_hex'] == ''
                and results == [dict(name='read_result', call=1, some=0, hex=''),
                                dict(name='read_result', call=2, some=1, hex='efbfbd')])
        row = compiled_case('compiled_lossy_read_control', 'legacy-read', b'\x80\xff')
        results = [r for r in row['reports'] if r['name'] == 'read_result']
        require('compiled_utf8_loss_observed', row['first_remaining_hex'] == ''
                and row['second_remaining_hex'] == ''
                and results == [dict(name='read_result', call=1, some=1, hex='efbfbdefbfbd'),
                                dict(name='read_result', call=2, some=1, hex='efbfbd')])
        save('transport_prerequisite', 'BLOCKED',
             reason='Excluding legacy stdin leaves this public-only compiled target without a lease byte-read door. Disabling that exclusion consumes a short nonblocking prefix then returns None; complete non-UTF-8 input is replaced, not preserved.',
             next_action='Recut with an explicitly authorized private scratch lease-transport ABI and a compiled target allowed to invoke it; retain legacy readExactly exclusion. No public API or production implementation is proposed.',
             limitation='A witnessed incompatibility of this public legacy reader, not an impossibility claim about a private experimental transport or Medaka.')
        save('unexecuted_requirements', 'UNQUALIFIED', identities=UNEXECUTED,
             reason='Stop at the compiled-entry transport prerequisite; these rows were not implemented or executed and none is qualified.')

    require('exact_case_matrix', len(cases) == len(expected_cases(args.scope))
            and set(cases) == expected_cases(args.scope),
            actual=sorted(cases), expected=sorted(expected_cases(args.scope)))
    scratch.unlink()
    telemetry.unlink()
    joined = sum(event['name'] == 'owner_thread_joined' and event['value'] == 1
                 for row in rows if row.get('case') for event in row['reports'])
    save('cleanup', 'OBSERVED', fixtures_waited=len(cases), owner_threads_joined=joined,
         scope='All fixture processes waited; initialized owner threads joined after roots/slots empty. Child PIDs independently absent, fds conserved except cleanup mutation whose one leaked fd is observed and explicitly reclaimed. Raw external artifacts retained.')
    if args.scope == 'lease':
        save('qualification', 'BLOCKED', exit_code=77, qualified=False,
             production_boundary_qualified=False, compiled_entry_qualified=False,
             scope='Owner-provenance regression plus compiled public legacy-reader exclusion and disabling controls only.',
             blocker='No authorized byte-preserving lease transport door for the public-only compiled target; readExactly loses partial and non-UTF-8 input.',
             next_action='Explicitly authorize a private scratch lease-transport ABI and its compiled target invocation before resuming the remaining coupled proof.',
             unexecuted_requirements=UNEXECUTED)
        return 77
    save('qualification', 'QUALIFIED_OWNER_PROVENANCE_ONLY', exit_code=0, qualified=True,
         production_boundary_qualified=False, compiled_entry_qualified=False,
         scope='Fixed literal owner Null setup is separated from content hooks, including measured nested/overlapping content and rollback. Linux anonymous nonblocking pipe endpoints only.',
         remaining=['Directory fsync rejected; requires a separate measured caller type-policy decision.',
                    'No lease admission/history, resolver/NSS, legacy/automatic output, compiled Medaka entry, byte transport, cancellation or parent-fd protection qualification.',
                    'Whole-tree lexical census does not prove semantic compatibility.'])
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (RuntimeError, OSError, ValueError, subprocess.SubprocessError) as error:
        print('lease observer failed: ' + str(error), file=sys.stderr)
        sys.exit(1)
