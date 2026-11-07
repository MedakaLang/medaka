"""Independently grade the experimental lease observer's blocked receipt."""
import hashlib
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


def grade(rows, pins, patches, out):
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
    for name in ('worker_null', 'worker_piped'):
        require((out / (name + '.marker')).read_bytes() == b'CHILD\n', 'worker marker')
    require(by_name['worker_piped']['worker_wire_hex'] == '5749524500ff0a', 'worker wire')
    for name in ('compiled_legacy_reader_excluded', 'compiled_partial_loss_observed', 'compiled_utf8_loss_observed', 'nested_and_concurrent_denied', 'ambient_leak_detected', 'sticky_authority_detected', 'setup_failure_rolls_back', 'rollback_injection_control', 'rollback_cleanup_disabling_detected', 'directory_fsync_disposition', 'directory_mutation_observed', 'exact_case_matrix'):
        require(by_name[name]['status'] == 'PASS', name)
    guard = by_name['compiled_legacy_guard']
    require(guard['first_remaining_hex'] == '80' and guard['second_remaining_hex'] == 'ff', 'guard bytes')
    partial = by_name['compiled_partial_read_control']
    require(partial['first_remaining_hex'] == '' and partial['second_remaining_hex'] == '' and [r['hex'] for r in partial['reports'] if r['name'] == 'read_result'] == ['', 'efbfbd'], 'partial loss')
    lossy = by_name['compiled_lossy_read_control']
    require([r['hex'] for r in lossy['reports'] if r['name'] == 'read_result'][0] == 'efbfbdefbfbd', 'UTF-8 replacement')
    q = by_name['qualification']
    require(q['status'] == 'BLOCKED' and q['qualified'] is False and q['exit_code'] == 77 and q['production_boundary_qualified'] is False and q['compiled_entry_qualified'] is False and len(q['unexecuted_requirements']) == 14 and 'private scratch' in q['next_action'], 'blocker semantics')
    return cases


def verify_lease(root, out):
    root, out = Path(root), Path(out)
    summary = json.loads((root / 'docs/findings/mcp-runtime-stdio-lease/summary.json').read_text())
    pins, patches = summary['source_pins'], summary['patches']
    inventory = summary['census']['inventory']
    encoded = json.dumps(inventory, sort_keys=True, separators=(',', ':')).encode()
    require(hashlib.sha256(encoded).hexdigest() == summary['census']['inventory_sha256'], 'census receipt pin')
    require(inventory['lexical_unknowns'] > 0 and len(inventory['supplemental_classifications']) == 3, 'census classifications')
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
    cases = grade(rows, pins, patches, dest)
    for name, replacement in [('zero', []), ('missing', cases[1:]), ('duplicate', cases + cases[:1]), ('substituted', cases[1:] + [dict(cases[0], name='substitute')])]:
        altered = [r for r in rows if not r.get('case')] + replacement
        try:
            grade(altered, pins, patches, dest)
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
            grade(altered, changed, patches, dest)
        except RuntimeError:
            print('lease ' + name + ' mutation rejected')
        else:
            raise RuntimeError(name + ' mutation escaped')
    altered = [dict(r, qualified=True) if r['name'] == 'qualification' else r for r in rows]
    try:
        grade(altered, pins, patches, dest)
    except RuntimeError as error:
        require(str(error) == 'blocker semantics', 'receipt mutation rejected for wrong reason')
    else:
        raise RuntimeError('receipt mutation escaped')
    print('lease receipt mutation rejected; 115 cases verified, qualified=false')
