"""Independently grade the experimental lease observer's blocked receipt."""
import hashlib
import copy
import json
import os
from pathlib import Path
import subprocess
import sys


def require(ok, message):
    if not ok:
        raise RuntimeError(message)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def value(row, name):
    matches = [r['value'] for r in row['reports'] if r['name'] == name]
    require(len(matches) == 1, row['name'] + '/' + name)
    return matches[0]


def identities(actual, expected, message):
    require(len(actual) == len(set(actual)) and set(actual) == set(expected), message)


UNEXECUTED = ['endpoint directions/types/flags/shared identities/distinct stderr rejection matrix', 'pathname swaps, fd replacement/reuse, same-checked-fd use and open/stat failure controls', 'no destructive open before validation under injected failures', 'prior/in-flight buffered output and resolver admission/history synchronization', 'release/reacquisition and error-retained ownership', 'resolver/NSS pre-libc exclusion, HOSTALIASES error paths and disabling controls', 'legacy/raw/buffered/automatic/abort/stash/flush output including #4865 actual primitive', 'legacy launch interlocks and disabling controls', 'fresh-stdio child parent-fd reopen with identity/dumpability controls', 'compiled lease byte transport with acknowledged staggered producer/consumer overlap', 'scheduler-safe backpressure with status/control progress', 'Deadline/CancelToken termination and committed write prefixes without replay', 'directory-fsync compatibility policy (owner-only disposition remains rejection)', 'supervisor toolchain selection under a complete enforced lease']


def qualification(summary, observed):
    require(summary == observed, 'summary qualification mismatch')


def grade(rows, pins, patches, out, root):
    cases = [r for r in rows if r.get('case') is True]
    operations = ('read', 'hash', 'read-bytes', 'write', 'append', 'telemetry', 'write-bytes', 'write-mode', 'fsync')
    expected = {'alias_%d_%d_%s' % (fd, alias, op) for fd in (0, 1) for alias in range(4) for op in operations}
    expected |= {prefix + op for prefix in ('caller_null_', 'pathname_control_') for op in operations}
    expected |= set('required_read_source required_read_config required_write required_append required_telemetry required_write-bytes required_write-mode required_scratch_create required_regular_fsync directory_fsync directory_control identity_write_control identity_read_control worker_piped worker_null owner_disabled_control owner_overlap ambient_control sticky_control setup_rollback rollback_disabled_control cleanup_control compiled_legacy_guard compiled_partial_read_control compiled_lossy_read_control'.split())
    names = [r['name'] for r in cases]
    require(len(names) == len(set(names)) and set(names) == expected, 'lease case matrix mismatch')
    require(all(r['rc'] == (77 if r['name'] in ('owner_disabled_control', 'setup_rollback', 'cleanup_control') else 0) and r['stderr_hex'] == '' and r['fixture_reaped'] and r['worker_pids_absent'] for r in cases), 'case execution or cleanup')
    by_name = {r['name']: r for r in rows}
    require(len(by_name) == len(rows), 'duplicate receipt row')
    require(by_name['source_pins']['sha256'] == pins, 'source pins')
    for item in by_name['experimental_transformation']['files']:
        name = item['transformed']
        require(name in patches and item['sha256'] == patches[name]['source'] and item['patch_sha256'] == patches[name]['patch'], 'transformation pins')
        require(digest(out / name) == patches[name]['source'] and digest(out / (name + '.patch')) == patches[name]['patch'], 'transformation bytes')
    require(len(by_name['experimental_transformation']['files']) == len(patches), 'transformation count')
    for r in cases:
        if r['name'].startswith(('alias_', 'caller_null_')):
            require(r['endpoint_hex'] == '' and r['remaining_hex'] == '00ff41c3285a', 'protected endpoint effect')
    require(by_name['identity_write_control']['endpoint_hex'] == '42595445530a', 'identity control effect')
    require(by_name['identity_read_control']['remaining_hex'] == '' and
            by_name['identity_read_control']['endpoint_hex'] == '', 'identity read effect')
    for name, path in (('source', 'stdlib/core.mdk'), ('config', 'compiler/medaka.toml')):
        row = by_name['required_read_' + name]
        expected_bytes = (root / path).read_bytes()
        receipt = row['read_receipt']
        require(receipt is not None and Path(receipt).is_file() and
                Path(receipt).read_bytes() == expected_bytes and
                value(row, 'read_length') == len(expected_bytes) and
                value(row, 'content_ok') == 1 and row['endpoint_hex'] == '' and
                row['remaining_hex'] == '00ff41c3285a', name + ' read effect')
    effects = {'write': b'BYTES\n', 'append': b'EVENT\nBYTES\n',
               'telemetry': b'EVENT\nBYTES\n', 'write-bytes': b'\xff\x00R',
               'write-mode': b'BYTES\n', 'scratch-create': b'BYTES\n',
               'regular-fsync': b'BYTES\n'}
    for name, expected_bytes in effects.items():
        row = by_name['required_' + name.replace('scratch-create', 'scratch_create').replace('regular-fsync', 'regular_fsync')]
        effect = out / ('effect-' + name)
        require(effect.is_file() and effect.read_bytes() == expected_bytes and
                (name != 'write-mode' or effect.stat().st_mode & 0o777 == 0o600) and
                value(row, 'content_ok') == 1 and row['endpoint_hex'] == '' and
                row['remaining_hex'] == '00ff41c3285a', name + ' file effect')
    for name in ('worker_null', 'worker_piped'):
        require((out / (name + '.marker')).read_bytes() == b'CHILD\n', 'worker marker')
    require(by_name['worker_piped']['worker_wire_hex'] == '5749524500ff0a', 'worker wire')
    def intact(row):
        return row['endpoint_hex'] == '' and row['remaining_hex'] == '00ff41c3285a'

    def denied(row, prefix):
        return all(value(row, prefix + '_' + op) == 0 for op in operations + ('null_open',))

    worker_names = ('worker_piped', 'worker_null', 'owner_disabled_control', 'owner_overlap',
                    'ambient_control', 'sticky_control', 'setup_rollback', 'rollback_disabled_control', 'cleanup_control')
    for name in worker_names:
        row = by_name[name]
        require(value(row, 'claim') == 0 and value(row, 'owner_thread_joined') == 1 and
                value(row, 'fds_after_worker') - value(row, 'fds_before_worker') == (1 if name == 'cleanup_control' else 0), name + ' cleanup')
    for name in ('worker_piped', 'worker_null', 'owner_overlap', 'ambient_control', 'sticky_control', 'rollback_disabled_control'):
        row = by_name[name]
        require((out / (name + '.marker')).read_bytes() == b'CHILD\n' and row['worker_pids'] and
                value(row, 'worker_exit') == 0 and value(row, 'worker_disposed') == 1 and
                value(row, 'owner_roots_after_dispose') == 0, name + ' launch')
    for name in ('owner_disabled_control', 'setup_rollback', 'cleanup_control'):
        require(not (out / (name + '.marker')).exists() and intact(by_name[name]) and
                value(by_name[name], 'owner_roots_after_failure') == 0, name + ' failure')
    overlap = by_name['owner_overlap']
    require(intact(overlap) and value(overlap, 'owner_held') == 1 and
            value(overlap, 'nested_endpoint_open') == 0 and value(overlap, 'nested_null_open') == 0 and
            denied(overlap, 'concurrent') and denied(overlap, 'after'), 'overlap authority')
    ambient = by_name['ambient_control']
    require(ambient['remaining_hex'] == '' and ambient['endpoint_hex'].startswith('4e45535445440a') and
            all(value(ambient, n) == 1 for n in ('nested_endpoint_open', 'nested_null_open', 'concurrent_null_open', 'concurrent_append')) and denied(ambient, 'after'), 'ambient authority')
    sticky = by_name['sticky_control']
    require(sticky['remaining_hex'] == '' and sticky['endpoint_hex'].startswith('4e45535445440a') and
            value(sticky, 'after_null_open') == 1 and value(sticky, 'after_append') == 1, 'sticky authority')
    for name in ('setup_rollback', 'cleanup_control'):
        row = by_name[name]
        require(value(row, 'injected_setup_failure') == 2 and
                any(r['name'] == 'launch_failed' and r['errno'] == 5 for r in row['reports']) and
                denied(row, 'concurrent') and denied(row, 'after'), name + ' rollback')
    require(value(by_name['cleanup_control'], 'mutation_leak_reclaimed') == 1, 'cleanup reclaim')
    rollback = by_name['rollback_disabled_control']
    require(intact(rollback) and denied(rollback, 'after') and
            not any(r['name'] == 'injected_setup_failure' for r in rollback['reports']), 'rollback disabling')
    directory = by_name['directory_fsync']
    require(intact(directory) and value(directory, 'content_ok') == 0 and
            any(r['name'] == 'type_denied' and r['value'] == 0o40000 for r in directory['reports']), 'directory refusal')
    require(intact(by_name['directory_control']) and value(by_name['directory_control'], 'content_ok') == 1, 'directory control')
    for name in ('compiled_legacy_reader_excluded', 'compiled_partial_loss_observed', 'compiled_utf8_loss_observed', 'nested_and_concurrent_denied', 'ambient_leak_detected', 'sticky_authority_detected', 'setup_failure_rolls_back', 'rollback_injection_control', 'rollback_cleanup_disabling_detected', 'directory_fsync_disposition', 'directory_mutation_observed', 'exact_case_matrix'):
        require(by_name[name]['status'] == 'PASS', name)
    guard = by_name['compiled_legacy_guard']
    for name in ('compiled_legacy_guard', 'compiled_partial_read_control', 'compiled_lossy_read_control'):
        row = by_name[name]
        raw = [json.loads(line) for line in Path(row['raw_receipt']).read_text().splitlines()]
        require(raw == row['reports'] and value(row, 'claim') == 0 and value(row, 'compiled_main_returned') == 0 and
                value(row, 'owner_thread_joined') == 1 and value(row, 'fds_before_compiled') == value(row, 'fds_after_compiled') and
                row['endpoint_hex'] == '', name + ' raw receipt/lifecycle')
    require(guard['first_remaining_hex'] == '80' and guard['second_remaining_hex'] == 'ff', 'guard bytes')
    partial = by_name['compiled_partial_read_control']
    require(partial['first_remaining_hex'] == '' and partial['second_remaining_hex'] == '' and [r['hex'] for r in partial['reports'] if r['name'] == 'read_result'] == ['', 'efbfbd'], 'partial loss')
    lossy = by_name['compiled_lossy_read_control']
    require([r['hex'] for r in lossy['reports'] if r['name'] == 'read_result'][0] == 'efbfbdefbfbd', 'UTF-8 replacement')
    q = by_name['qualification']
    require(q['status'] == 'BLOCKED' and q['qualified'] is False and q['exit_code'] == 77 and q['production_boundary_qualified'] is False and q['compiled_entry_qualified'] is False and 'private scratch' in q['next_action'], 'blocker semantics')
    identities(q['unexecuted_requirements'], UNEXECUTED, 'requirement identities')
    identities(by_name['unexecuted_requirements']['identities'], UNEXECUTED, 'observed requirement identities')
    return cases


def verify_lease(root, out):
    root, out = Path(root), Path(out)
    summary = json.loads((root / 'docs/findings/mcp-runtime-stdio-lease/summary.json').read_text())
    pins, patches = summary['source_pins'], summary['patches']
    inventory = summary['census']['inventory']
    encoded = json.dumps(inventory, sort_keys=True, separators=(',', ':')).encode()
    require(hashlib.sha256(encoded).hexdigest() == summary['census']['inventory_sha256'], 'census receipt pin')
    classifications = [(r['path'], r['line'], r['class'], r['token'], r['classification']) for r in inventory['supplemental_classifications']]
    path = 'scripts/mcp_bench/prototypes/stdio_lease_cases/legacy_read.mdk'
    identities(classifications, [(path, 1, 'C5', 'main', 'observed compiled Unit entry; no normal output in these cases'),
                                 (path, 2, 'C4', 'readExactly', 'observed compiled legacy-reader exclusion/control'),
                                 (path, 3, 'C4', 'readExactly', 'observed compiled legacy-reader exclusion/control')], 'census classifications')
    require(inventory['lexical_unknowns'] > 0, 'census unknowns')
    try:
        identities(classifications[:-1] + [(path, 4, 'C4', 'readExactly', 'substituted')], classifications, 'census classifications')
    except RuntimeError:
        print('lease classification substitution rejected')
    else:
        raise RuntimeError('classification substitution escaped')
    changed = dict(inventory, lexical_unknowns=-1)
    require(hashlib.sha256(json.dumps(changed, sort_keys=True, separators=(',', ':')).encode()).hexdigest() != summary['census']['inventory_sha256'], 'census mutation escaped')
    print('lease census receipt mutation rejected')
    require(all(digest(root / path) == value for path, value in pins.items()), 'checkout source pins')
    observer = root / 'scripts/mcp_bench/prototypes/stdio_lease_probe.py'
    env = dict(os.environ, MEDAKA_STRICT='1')
    script = "import runpy,sys; sys.platform='darwin'; runpy.run_path(sys.argv.pop(1),run_name='__main__')"
    nonlinux = out / 'lease-nonlinux'
    result = subprocess.run(['python3', '-c', script, str(observer), '--root', str(root), '--out', str(nonlinux)], cwd=root, env=env, capture_output=True, text=True, timeout=240)
    require(result.returncode == 77 and result.stderr == '', 'non-Linux observer exit/stderr')
    unavailable = json.loads((nonlinux / 'results.json').read_text())
    require(unavailable[-1]['status'] == 'UNAVAILABLE' and unavailable[-1]['qualified'] is False and 'no executable rows' in unavailable[-1]['reason'] and not any(r.get('case') for r in unavailable), 'non-Linux refusal')
    print('lease non-Linux refusal verified')
    if sys.platform != 'linux':
        return
    dest = out / 'lease'
    result = subprocess.run(['python3', str(observer), '--root', str(root), '--out', str(dest)], cwd=root, env=env, capture_output=True, text=True, timeout=240)
    require(result.returncode == 77 and result.stderr == '', 'lease observer exit/stderr: ' + result.stderr)
    rows = json.loads((dest / 'results.json').read_text())
    cases = grade(rows, pins, patches, dest, root)
    observed = next(r for r in rows if r['name'] == 'qualification')
    qualification(summary['qualification'], observed)
    forged = dict(summary['qualification'], status='QUALIFIED', qualified=True)
    try:
        qualification(forged, observed)
    except RuntimeError:
        print('lease summary qualification mutation rejected')
    else:
        raise RuntimeError('summary qualification mutation escaped')
    for name, replacement in [('zero', []), ('missing', cases[1:]), ('duplicate', cases + cases[:1]), ('substituted', cases[1:] + [dict(cases[0], name='substitute')])]:
        altered = [r for r in rows if not r.get('case')] + replacement
        try:
            grade(altered, pins, patches, dest, root)
        except RuntimeError as error:
            require(str(error) == 'lease case matrix mismatch', name + ' rejected for wrong reason')
        else:
            raise RuntimeError(name + ' matrix escaped')
        print('lease ' + name + ' matrix rejected')
    for name, changed in [('source', dict(pins, **{next(iter(pins)): '0' * 64})), ('patch', patches)]:
        altered = [dict(r) for r in rows]
        if name == 'patch':
            row = next(r for r in altered if r['name'] == 'experimental_transformation')
            row['files'] = [dict(f) for f in row['files']]
            row['files'][0]['patch_sha256'] = '0' * 64
        try:
            grade(altered, changed, patches, dest, root)
        except RuntimeError:
            print('lease ' + name + ' mutation rejected')
        else:
            raise RuntimeError(name + ' mutation escaped')
    altered = [dict(r, qualified=True) if r['name'] == 'qualification' else r for r in rows]
    try:
        grade(altered, pins, patches, dest, root)
    except RuntimeError as error:
        require(str(error) == 'blocker semantics', 'receipt mutation rejected for wrong reason')
    else:
        raise RuntimeError('receipt mutation escaped')
    mutations = [('source receipt', 'required_read_source', 'read_receipt', '/definitely/missing/forged'),
                 ('config receipt', 'required_read_config', 'read_receipt', '/definitely/missing/forged'),
                 ('source length', 'required_read_source', 'read_length', 0),
                 ('config length', 'required_read_config', 'read_length', 0),
                 ('identity read', 'identity_read_control', 'remaining_hex', '00ff41c3285a'),
                 ('overlap bytes', 'owner_overlap', 'remaining_hex', ''),
                 ('overlap report', 'owner_overlap', 'nested_endpoint_open', 1),
                 ('rollback', 'setup_rollback', 'owner_roots_after_failure', 1),
                 ('cleanup', 'cleanup_control', 'mutation_leak_reclaimed', 0),
                 ('directory', 'directory_fsync', 'content_ok', 1),
                 ('compiled raw report', 'compiled_legacy_guard', 'legacy_read_denied', 0)]
    altered = copy.deepcopy(rows)
    next(r for r in altered if r['name'] == 'qualification')['unexecuted_requirements'][0] = 'substituted requirement'
    try:
        grade(altered, pins, patches, dest, root)
    except RuntimeError:
        print('lease requirement substitution rejected')
    else:
        raise RuntimeError('requirement substitution escaped')
    for label, name, field, replacement in mutations:
        altered = copy.deepcopy(rows)
        row = next(r for r in altered if r['name'] == name)
        if field in row:
            row[field] = replacement
        else:
            next(r for r in row['reports'] if r['name'] == field)['value'] = replacement
        try:
            grade(altered, pins, patches, dest, root)
        except RuntimeError:
            print('lease ' + label + ' mutation rejected')
        else:
            raise RuntimeError(label + ' mutation escaped')
    for name in ('write', 'append', 'telemetry', 'write-bytes', 'write-mode', 'scratch-create', 'regular-fsync'):
        effect = dest / ('effect-' + name)
        original, mode = effect.read_bytes(), effect.stat().st_mode & 0o777
        try:
            effect.write_bytes(b'forged')
            try:
                grade(rows, pins, patches, dest, root)
            except RuntimeError:
                print('lease ' + name + ' effect mutation rejected')
            else:
                raise RuntimeError(name + ' effect mutation escaped')
        finally:
            effect.write_bytes(original)
            effect.chmod(mode)
    effect = dest / 'effect-write-mode'
    try:
        effect.chmod(0o644)
        try:
            grade(rows, pins, patches, dest, root)
        except RuntimeError:
            print('lease write-mode permissions mutation rejected')
        else:
            raise RuntimeError('write-mode permissions mutation escaped')
    finally:
        effect.chmod(0o600)
    for name in ('source', 'config'):
        receipt = Path(next(r for r in rows if r['name'] == 'required_read_' + name)['read_receipt'])
        original = receipt.read_bytes()
        try:
            receipt.write_bytes(b'forged')
            try:
                grade(rows, pins, patches, dest, root)
            except RuntimeError:
                print('lease ' + name + ' receipt bytes mutation rejected')
            else:
                raise RuntimeError(name + ' receipt bytes mutation escaped')
        finally:
            receipt.write_bytes(original)
    raw_path = Path(next(r for r in rows if r['name'] == 'compiled_legacy_guard')['raw_receipt'])
    raw = raw_path.read_bytes()
    try:
        raw_path.write_bytes(raw.replace(b'legacy_read_denied', b'legacy_read_forged', 1))
        try:
            grade(rows, pins, patches, dest, root)
        except RuntimeError:
            print('lease raw receipt bytes mutation rejected')
        else:
            raise RuntimeError('raw receipt bytes mutation escaped')
    finally:
        raw_path.write_bytes(raw)
    print('lease receipt mutation rejected; %d cases verified, qualified=false' % len(cases))
