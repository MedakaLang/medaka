#!/usr/bin/env python3
"""Conservative, source-pinned inventory for the experimental stdio boundary."""
import argparse
import hashlib
import json
import re
import subprocess
from pathlib import Path

# Rules describe the proposed interlock, not observed semantic compatibility.
RULES = {
    'C1': ('regular content', 'permit regular files after descriptor identity validation', r'\b(?:readFile(?:Bytes)?|hashFile|writeFile(?:Bytes|Mode)?|appendFile(?:ExceptStdout)?|fsync)\b'),
    'C2': ('protocol aliases', 'deny either protected endpoint before content or destructive effects', r'/proc/(?:self|[0-9]+)/fd/[01]\b|/dev/(?:fd/[01]|stdin|stdout)\b'),
    'C3': ('resolver', 'deny resolver entry while protected; settle prior and in-flight history', r'\b(?:netResolve|netTcpConnect|netTcpListen|netConnectStart|getaddrinfo|HOSTALIASES)\b'),
    'C4': ('legacy input and output', 'interlock buffered and raw stdio including flush and stash', r'\b(?:readLine(?:Opt)?|readExactly|readAll|putStr(?:Ln)?|ePutStr(?:Ln)?|flushStdout|byteBlockWriteStdout|stashRunStdout|enableRunStdoutFlush|writeStdoutBytes)\b'),
    'C5': ('automatic and abort output', 'interlock implicit result printing, abort flush and diagnostics', r'\b(?:main|panic|exit|assert|print|println)\b'),
    'C6': ('legacy launch', 'deny legacy launch after acquisition', r'\b(?:runCommand(?:Batch)?|mdk_run_command(?:_batch)?|fork|execvp)\b'),
    'C7': ('native process submission', 'preserve owner submission and reap with fresh streams', r'\b(?:processSubmitRaw|processStartRaw|processRetryStartRaw|processCheckStartRaw|processAbortStartRaw|processPollExitRaw|processTryReadRaw|processTryWriteRaw|processStreamFdRaw|mdk_process_[a-z_]+)\b'),
}
ROUTES = {
    'C1': ['mdk_read_file', 'mdk_hash_file', 'mdk_read_file_bytes', 'mdk_write_impl (write/append)', 'mdk_append_file_except_stdout', 'mdk_write_file_bytes', 'mdk_write_file_mode', 'mdk_fsync'],
    'C2': ['all C1 path operands including symlink, proc and dev aliases; checked descriptor must be used'],
    'C3': ['mdk_net_resolve', 'mdk_net_tcp_connect', 'mdk_net_tcp_listen', 'mdk_net_connect_start'],
    'C4': ['mdk_read_line', 'mdk_read_line_opt', 'mdk_read_exactly', 'mdk_read_all', 'mdk_fwrite_str', 'mdk_byteblock_write_stdout', 'mdk_stash_run_stdout', 'mdk_enable_run_stdout_flush', 'flushStdout and stderr emitters'],
    'C5': ['native main result printers', 'mdk_flush_run_stdout_on_abort', 'mdk_abort_write', 'exit stdio flush', 'signal fault handlers and build stdout tracking'],
    'C6': ['mdk_run_command', 'mdk_run_command_batch', 'mdk_read_temp and child execvp'],
    'C7': ['mdk_process_submit and owner launch/reap', 'mdk_process_try_read', 'mdk_process_try_write', 'fresh-stdio child descriptor inheritance/reopen'],
}
# Each observation is a manually inspected carrier line, not a proof of the
# behavior of every program that imports it.
OBSERVATIONS = {
    ('test/native_fixtures/confinement/declared_bound_read.mdk', 32, 'C1', 'writeFileBytes'): 'byte write through a dynamic path; preserve only after endpoint identity check',
    ('test/native_fixtures/confinement/write_file_mode.mdk', 19, 'C1', 'writeFileMode'): 'mode-setting truncating write with dynamic name',
    ('stdlib/fs.mdk', 71, 'C1', 'readFileBytes'): 'stdlib copy reads file bytes',
    ('scripts/mcp_bench/prototypes/stdio_authority_probe.py', 134, 'C2', '/proc/self/fd/1'): 'explicit output endpoint alias in probe',
    ('scripts/mcp_bench/prototypes/stdio_authority_probe.py', 143, 'C2', '/proc/self/fd/0'): 'explicit input endpoint alias in probe',
    ('stdlib/net.mdk', 56, 'C3', 'netResolve'): 'public resolver wrapper calls resolver',
    ('scripts/mcp_bench/prototypes/stdio_authority_probe.py', 237, 'C4', 'byteBlockWriteStdout'): 'generated internal raw stdout probe',
    ('scripts/mcp_bench/prototypes/stdio_authority_probe.py', 238, 'C4', 'stashRunStdout'): 'generated stash exposure probe',
    ('scripts/mcp_bench/prototypes/stdio_authority_probe.py', 239, 'C4', 'enableRunStdoutFlush'): 'generated flush-enablement exposure probe',
    ('scripts/mcp_bench/prototypes/stdio_authority_probe.py', 236, 'C5', 'main'): 'generated native result printing probe',
    ('scripts/mcp_bench/prototypes/stdio_authority_probe.py', 243, 'C5', 'panic'): 'generated abort output probe',
    ('test/llvm_fixtures/s13_run_command.mdk', 1, 'C6', 'runCommand'): 'legacy process launch call',
    ('stdlib/process.mdk', 103, 'C7', 'processSubmitRaw'): 'public owner submission wrapper calls native submission',
}
RECEIPT_PATHS = {'docs/findings/mcp-runtime-stdio-descriptor/REPORT.md',
                 'docs/findings/mcp-runtime-stdio-descriptor/summary.json'}
PINS = ['runtime/medaka_rt.c', 'runtime/medaka_process.c', 'stdlib/runtime.mdk', 'compiler/backend/extern_catalog.mdk', 'compiler/backend/llvm_emit.mdk', 'compiler/backend/llvm_preamble.mdk', 'compiler/frontend/resolve.mdk', 'scripts/mcp_bench/prototypes/stdio_authority_probe.py', 'scripts/mcp_bench/prototypes/stdio_authority_fixture.c', 'docs/findings/mcp-runtime-authority/STDIO.md']

def digest(data):
    return hashlib.sha256(data).hexdigest()

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', required=True, type=Path)
    parser.add_argument('--out', required=True, type=Path)
    args = parser.parse_args()
    root, out = args.root.resolve(), args.out.resolve()
    if not args.root.is_absolute() or not args.out.is_absolute() or out == root or root in out.parents:
        parser.error('absolute root and external output file required')
    compiled = {k: re.compile(v[2]) for k, v in RULES.items()}
    pins = {p: digest((root / p).read_bytes()) for p in PINS}
    carriers, matches, excluded = {}, [], []
    tracked = subprocess.check_output(['git', '-C', str(root), 'ls-files', '-z', '--cached', '--others', '--exclude-standard'])
    for rel in sorted(set(tracked.decode('utf-8').split('\0')) - {''}):
        if rel in RECEIPT_PATHS:
            continue
        path = root / rel
        if path.is_symlink() or not path.is_file():
            excluded.append({'path': rel, 'reason': 'symlink or missing file; target not scanned through this path'})
            continue
        data = path.read_bytes()
        carriers[rel] = digest(data)
        try:
            source = data.decode('utf-8')
        except UnicodeDecodeError:
            excluded.append({'path': rel, 'reason': 'non-UTF-8; cannot classify dynamic or embedded code'})
            continue
        if '\0' in source:
            excluded.append({'path': rel, 'reason': 'NUL-containing carrier; cannot classify embedded code'})
            continue
        found = False
        for number, line in enumerate(source.splitlines(), 1):
            for key, pattern in compiled.items():
                for hit in pattern.finditer(line):
                    found = True
                    observation = OBSERVATIONS.get((rel, number, key, hit.group()))
                    matches.append({'path': rel, 'line': number, 'class': key, 'token': hit.group(), 'classification': 'inspected route example' if observation else 'unknown lexical candidate', 'reason': observation or 'uninspected token; could be a call, declaration, comment, string, or unrelated identifier'})
        if not found:
            excluded.append({'path': rel, 'reason': 'no listed lexical token; indirect, generated and dynamic uses remain unknown'})
    counts = {key: sum(m['class'] == key for m in matches) for key in RULES}
    observed = {key: sum(m['class'] == key and m['classification'] == 'inspected route example' for m in matches) for key in RULES}
    if sum(observed.values()) != len(OBSERVATIONS):
        raise ValueError('an inspected source observation moved or no longer matches')
    result = {'schema': 1, 'receipt_exclusions': sorted(RECEIPT_PATHS), 'source_pins': pins, 'carrier_pins': carriers,
              'numbered_classes': {k: {'description': v[0], 'enforcement': v[1], 'candidate_count': counts[k], 'inspected_example_count': observed[k], 'unknown_candidate_count': counts[k] - observed[k], 'routes': ROUTES[k]} for k, v in RULES.items()},
              'candidates': matches, 'excluded': excluded,
              'unknowns': ['Uninspected lexical hits, including comments and strings, require semantic inspection; unknown dynamic uses have no defensible count.', 'Indirect calls, imported aliases, generated programs, dynamic paths and external native code are not resolved by lexical scanning.', 'Every native main may print automatically or flush on abort, including programs without a matching token.', 'No count proves compatibility or route enforcement; resolver/NSS and descriptor history require executable controls.'],
              'historical_broad_seal': 'Rejected: docs/findings/mcp-runtime-authority/STDIO.md; denies required file work.'}
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(result, indent=2, sort_keys=True) + '\n', encoding='utf-8')
    print('carriers:', len(carriers), 'candidates:', len(matches), 'excluded:', len(excluded))
    print('candidate counts:', json.dumps(counts, sort_keys=True))

if __name__ == '__main__':
    main()
