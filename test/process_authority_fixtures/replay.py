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
    require(result.returncode == 77, 'stdio must remain blocked: ' + result.stderr)
    values = json.loads((stdio / 'results.json').read_text())
    by_name = {r['name']: r for r in values}
    require(by_name['qualification']['status'] == 'BLOCKED' and by_name['cleanup']['status'] == 'PASS', 'stdio qualification or cleanup')
    require(len([r for r in values if r['status'] == 'PASS']) >= 3, 'stdio matrix did not execute')
    require(by_name['output_alias__proc_self_fd_1']['endpoint_hex'] == '', 'guarded endpoint')
    require(by_name['output_alias__proc_self_fd_1_mutation']['endpoint_hex'] == b'BYPASS'.hex(), 'mutation endpoint')

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
