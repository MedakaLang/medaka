#!/usr/bin/env python3
"""Run the independent authority controls and verify their observed effects."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

root = Path(sys.argv[1]).resolve()
out = Path(sys.argv[2]).resolve()
prototype = root / 'scripts/mcp_bench/prototypes'
env = dict(os.environ, MEDAKA_STRICT='1')

def run(argv):
    return subprocess.run(list(map(str, argv)), cwd=root, env=env, capture_output=True, text=True, timeout=240)

def require(condition, message):
    if not condition:
        raise RuntimeError(message)

def ownership(test_root, dest):
    return run(['python3', test_root / 'scripts/mcp_bench/prototypes/ownership_probe.py',
                '--root', test_root, '--out', dest, '--refusal-only'])

normal = out / 'ownership'
result = ownership(root, normal)
require(result.returncode == 77, 'ownership must refuse unavailable deployment: ' + result.stderr)
receipt = json.loads((normal / 'ownership.json').read_text())
rows = {r['name']: r for r in receipt['rows']}
require(receipt['qualified'] is False and rows['qualification']['status'] == 'UNAVAILABLE', 'false qualification')
require(rows['external_nonexecution']['status'] == 'PASS' and not (normal / 'refused-target.marker').exists(), 'refusal effect')
require((normal / 'target-control.marker').read_bytes() == b'executed\n', 'marker control')
passed = [r for r in receipt['rows'] if r['status'] == 'PASS']
require(len(passed) >= 3, 'zero or incomplete executed controls')
if sys.platform == 'linux':
    require(rows['protocol_cleanup_retained']['status'] == 'PASS', 'ownership retention')
    require(rows['protocol_missing_authority']['status'] == 'PASS', 'admission')
    require((normal / 'token_replay.marker').read_bytes() == b'executed\n', 'replay effect')
    require(not (normal / 'missing_authority.marker').exists(), 'unadmitted effect')

    stdio = out / 'stdio'
    result = run(['python3', prototype / 'stdio_authority_probe.py', '--root', root, '--out', stdio])
    require(result.returncode == 77, 'stdio must remain blocked: ' + result.stdout[-8000:] + result.stderr)
    values = json.loads((stdio / 'results.json').read_text())
    by_name = {r['name']: r for r in values}
    require(by_name['qualification']['status'] == 'BLOCKED' and by_name['cleanup']['status'] == 'PASS', 'stdio qualification or cleanup')
    require(len([r for r in values if r['status'] == 'PASS']) >= 3, 'stdio matrix did not execute')
    require(by_name['output_alias__proc_self_fd_1']['endpoint_hex'] == '', 'guarded endpoint')
    require(by_name['output_alias__proc_self_fd_1_mutation']['endpoint_hex'] == b'BYPASS'.hex(), 'mutation endpoint')

def descriptor_matrix(rows):
    cases = [r for r in rows if r.get('name', '').startswith('alias_') and r.get('status') == 'OBSERVED']
    require(len(cases) == 72, 'descriptor matrix incomplete or zero executed: ' + str(len(cases)))
    require(all(r['endpoint_hex'] == '' and r['remaining_hex'] == '00ff41c3285a' for r in cases),
            'descriptor alias effect changed')

try:
    descriptor_matrix([])
    raise RuntimeError('zero-executed descriptor matrix escaped')
except RuntimeError as error:
    require('zero executed' in str(error), 'zero matrix failed for unrelated reason: ' + str(error))
print('zero-executed descriptor matrix rejected')

nonlinux = out / 'descriptor-nonlinux'
script = "import runpy,sys; sys.platform='darwin'; runpy.run_path(sys.argv.pop(1),run_name='__main__')"
result = run(['python3', '-c', script, prototype / 'stdio_descriptor_probe.py', '--root', root, '--out', nonlinux])
require(result.returncode == 77, 'non-Linux refusal failed: ' + result.stdout + result.stderr)
rows = json.loads((nonlinux / 'results.json').read_text())
require(rows[-1]['status'] == 'UNAVAILABLE' and 'no matrix executed' in rows[-1]['reason'], 'non-Linux diagnostic missing')
print('non-Linux descriptor refusal verified')

if sys.platform == 'linux':
    descriptor = out / 'descriptor'
    result = run(['python3', prototype / 'stdio_descriptor_probe.py', '--root', root, '--out', descriptor])
    require(result.returncode == 77, 'descriptor blocker changed: ' + result.stdout + result.stderr)
    rows = json.loads((descriptor / 'results.json').read_text())
    descriptor_matrix(rows)
    by_name = {r['name']: r for r in rows}
    for name in ('shared_policy_worker_blocker', 'required_piped_worker',
                 'identity_mutation_rejected_by_observer', 'identity_read_mutation_rejected_by_observer',
                 'type_mutation_restores_required_worker'):
        require(by_name[name]['status'] == 'PASS', name + ': ' + json.dumps(by_name[name]))
    require(by_name['qualification']['status'] == 'BLOCKED', 'descriptor falsely qualified')
    print('descriptor blocker and mutation controls verified')

source = (prototype / 'ownership_fixture.c').read_text()
mutations = {
    'nonexecution': ('return 77;\n  }\n#ifdef __linux__', 'return target(argv[2]);\n  }\n#ifdef __linux__'),
    'admission': ('else if (!authority) answer = UNAVAILABLE;', 'else if (!authority) answer = OK;'),
    'ownership': ('else if (request.operation == RELEASE && (state == HELD || state == RUNNING)) answer = RETAINED;',
                  'else if (request.operation == RELEASE && (state == HELD || state == RUNNING)) answer = OK;'),
}
with tempfile.TemporaryDirectory(prefix='.authority-mutation-', dir=root) as tmp:
    mutant_root = Path(tmp)
    mutant_dir = mutant_root / 'scripts/mcp_bench/prototypes'
    mutant_dir.mkdir(parents=True)
    shutil.copy(prototype / 'ownership_probe.py', mutant_dir)
    for name, (before, after) in mutations.items():
        if sys.platform != 'linux' and name != 'nonexecution':
            continue
        require(source.count(before) == 1, name + ' mutation site changed')
        (mutant_dir / 'ownership_fixture.c').write_text(source.replace(before, after))
        result = ownership(mutant_root, out / ('mutant-' + name))
        require(result.returncode == 1, name + ' mutation escaped observer: ' + result.stdout + result.stderr)
        mutated = json.loads((out / ('mutant-' + name) / 'ownership.json').read_text())
        failure = mutated['rows'][-1]
        expected = {'nonexecution': 'refusal executed target or wrong result', 'admission': 'local protocol failed: missing_authority:', 'ownership': 'local protocol failed: cleanup_retained:'}[name]
        require(failure['name'] == 'probe_failure' and expected in failure['reason'], name + ' failed for an unrelated reason: ' + failure['reason'])
        if name == 'nonexecution':
            require((out / 'mutant-nonexecution/refused-target.marker').read_bytes() == b'executed\n', 'nonexecution mutation had no effect')
        print(name + ' mutation rejected')
print('authority replay controls passed')
