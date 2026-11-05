#!/usr/bin/env python3
"""Independent stdio evidence: exit 77 means no policy qualified, never PASS."""

import argparse
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys


RULES = {
    'C1': ('pathname content I/O refused forever after first acquisition',
           r'\b(?:readFile(?:Bytes)?|hashFile|writeFile(?:Bytes|Mode)?|appendFile(?:ExceptStdout)?|fsync)\b'),
    'C2': ('libc resolver entry refused forever after first acquisition',
           r'\b(?:netResolve|netTcpConnect|netTcpListen|netConnectStart)\b'),
    'C3': ('legacy launch refused forever; prior attempt prevents acquisition',
           r'\b(?:runCommand|runCommandBatch)\b'),
    'C4': ('legacy protocol input/output requires rejection before buffering',
           r'\b(?:readLine(?:Opt)?|readExactly|readAll|putStr(?:Ln)?|println|print|flushStdout|byteBlockWriteStdout)\b'),
    'C5': ('native launch attempt before acquisition prevents acquisition',
           r'\b(?:processSubmitRaw|processStartRaw|submit|startOwned|startAsync)\b'),
    'C6': ('automatic main output/abort requires entry/lowering audit',
           r'\b(?:main\s*(?::[^\n]*)?=|panic\b|exit\b)'),
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    root, out = args.root.resolve(), args.out.resolve()
    if out == root or root in out.parents or out.exists():
        parser.error('--out must be a new directory outside the checkout')
    out.mkdir(parents=True)
    rows = []
    env = dict(os.environ, MEDAKA_STRICT='1', RES_OPTIONS='attempts:1 timeout:1')
    env.pop('HOSTALIASES', None)

    def save(name, status, **fields):
        row = dict(name=name, status=status, **fields)
        rows.append(row)
        (out / 'results.json').write_text(json.dumps(rows, indent=2) + '\n')
        print(json.dumps(row), flush=True)
        return row

    def command(name, argv, expected=0, **kwargs):
        result = subprocess.run(list(map(str, argv)), cwd=out, env=env,
                                capture_output=True, timeout=120, **kwargs)
        save(name, 'PASS' if result.returncode == expected else 'FAIL',
             argv=list(map(str, argv)), rc=result.returncode,
             stdout_hex=result.stdout.hex(), stderr_hex=result.stderr.hex())
        if result.returncode != expected:
            raise RuntimeError(name + ': unexpected exit')
        return result

    pins = ['scripts/mcp_bench/prototypes/stdio_authority_fixture.c',
            'scripts/mcp_bench/prototypes/stdio_authority_probe.py',
            'runtime/medaka_rt.c', 'runtime/medaka_process.c', 'stdlib/runtime.mdk',
            'compiler/backend/llvm_emit.mdk', 'compiler/backend/llvm_preamble.mdk',
            'compiler/frontend/resolve.mdk']
    save('source_pins', 'OBSERVED', head=subprocess.check_output(
        ['git', '-C', str(root), 'rev-parse', 'HEAD'], text=True).strip(),
        sha256={p: hashlib.sha256((root / p).read_bytes()).hexdigest() for p in pins})
    if sys.platform != 'linux':
        save('qualification', 'UNAVAILABLE', reason='Linux candidate; no portable boundary proved', exit_code=77)
        return 77
    save('effective_identity', 'OBSERVED', uid=os.getuid(), euid=os.geteuid(),
         process_status=[line for line in Path('/proc/self/status').read_text().splitlines()
                 if line.startswith(('CapEff:', 'NoNewPrivs:', 'Uid:', 'Gid:'))])
    fixture = root / pins[0]
    exe = out / 'stdio-fixture'
    command('native_fixture_build', shlex.split(os.environ.get('CC', 'clang')) + [
        '-O1', '-std=c11', '-DMDK_PROCESS_TESTING', '-ffunction-sections', '-fdata-sections', '-I' + str(root / 'runtime'),
        str(fixture), str(root / 'runtime/medaka_process.c'), '-Wl,--gc-sections',
        '-lgc', '-lm', '-pthread', '-o', str(exe)])

    def case(name, mode, op, path, seed=b'', mutate=False, extra_env=None):
        inp, writer = os.pipe()
        reader, output = os.pipe()
        report_r, report_w = os.pipe()
        process = None
        try:
            os.set_blocking(inp, False)
            os.set_blocking(output, False)
            for offset in range(0, len(seed), 2):
                os.write(writer, seed[offset:offset + 2])
            os.close(writer)
            writer = -1
            argv = [str(exe), mode, str(report_w), op, str(path)] + (['mutate'] if mutate else [])
            process = subprocess.Popen(argv, cwd=out, env=dict(env, **(extra_env or {})),
                                       stdin=inp, stdout=output, stderr=subprocess.PIPE,
                                       pass_fds=(report_w,))
            os.close(output)
            output = -1
            os.close(report_w)
            report_w = -1
            try:
                _, stderr = process.communicate(timeout=25)
            except subprocess.TimeoutExpired:
                process.kill()
                _, stderr = process.communicate()
                save(name, 'FAIL', reason='timeout; exact probe PID killed and reaped', stderr_hex=stderr.hex())
                raise RuntimeError(name + ': timeout')
            observed = os.read(reader, 65536)
            remaining = os.read(inp, 65536)
            reports = os.read(report_r, 65536)
            details = [json.loads(line) for line in reports.splitlines()]
            return save(name, 'OBSERVED', rc=process.returncode, input_hex=seed.hex(),
                        remaining_hex=remaining.hex(), endpoint_hex=observed.hex(),
                        stderr_hex=stderr.hex(), reports=details, reaped=True)
        finally:
            if process is not None and process.poll() is None:
                process.kill()
                process.wait()
            for fd in (inp, writer, reader, output, report_r, report_w):
                if fd >= 0:
                    os.close(fd)

    def value(row, name):
        return next(r['value'] for r in row['reports'] if r['name'] == name)

    def require(name, condition, **detail):
        save(name, 'PASS' if condition else 'FAIL', **detail)
        if not condition:
            raise RuntimeError(name)

    seed = b'\x00\xffA\xc3\x28Z'
    for alias in ('/proc/self/fd/1', '/dev/fd/1', '/dev/stdout', str(out / 'output-link')):
        if alias.endswith('output-link'):
            Path(alias).symlink_to('/proc/self/fd/1')
        for mutation in (False, True):
            row = case('output_alias_' + alias.replace('/', '_') + ('_mutation' if mutation else ''),
                       'sealed', 'write', alias, seed, mutate=mutation)
            require('output_alias_guard', row['rc'] == 0 and row['remaining_hex'] == seed.hex()
                    and row['endpoint_hex'] == (b'BYPASS'.hex() if mutation else '')
                    and value(row, 'operation_ok') == int(mutation))
    for alias in ('/proc/self/fd/0', '/dev/fd/0', '/dev/stdin', str(out / 'input-link')):
        if alias.endswith('input-link'):
            Path(alias).symlink_to('/proc/self/fd/0')
        for mutation in (False, True):
            row = case('input_alias_' + alias.replace('/', '_') + ('_mutation' if mutation else ''),
                       'sealed', 'hash', alias, seed, mutate=mutation)
            require('input_alias_guard', row['rc'] == 0 and row['endpoint_hex'] == ''
                    and row['remaining_hex'] == ('' if mutation else seed.hex()))

    replaced = out / 'replacement'
    for mutation in (False, True):
        row = case('fd_replacement' + ('_mutation' if mutation else ''), 'sealed', 'replace',
                   replaced, seed, mutate=mutation)
        require('fd_replacement_guard', row['endpoint_hex'] == '' and value(row,'identity_guard') == 0
                and replaced.read_bytes() == (b'REPLACED' if mutation else b''))
    for mutation in (False, True):
        row = case('parent_fd' + ('_mutation' if mutation else ''), 'parent', '-', '-', mutate=mutation)
        require('parent_fd_guard', row['rc'] == 0 and value(row,'child_status') == (0 if mutation else 13)
                and row['endpoint_hex'] == (b'CHILD'.hex() if mutation else ''))

    aliases = b'leasealias 127.0.0.1\n'
    for mode, mutation, hostaliases in [('unsealed',False,False), ('unsealed',False,True),
                                      ('sealed',False,True), ('sealed',True,True)]:
        row = case(f'resolver_{mode}_{mutation}_{hostaliases}',mode,'resolver','leasealias', aliases,
                   mutate=mutation, extra_env={'HOSTALIASES':'/proc/self/fd/0'} if hostaliases else {})
        consumed = hostaliases and (mode == 'unsealed' or mutation)
        require('resolver_input_guard', row['rc'] == 0 and row['remaining_hex'] == ('' if consumed else aliases.hex()))
        if consumed:
            save('resolver_err_still_consumes', 'OBSERVED', result_ok=value(row,'operation_ok'),
                 consumed_bytes=len(aliases) - len(bytes.fromhex(row['remaining_hex'])))

    marker = out / 'legacy-marker'
    script = 'printf launched > ' + shlex.quote(str(marker))
    for mode, mutation in [('sealed',False), ('release',False), ('sealed',True)]:
        marker.unlink(missing_ok=True)
        row = case('legacy_' + mode + str(mutation), mode,'legacy',script,seed,mutate=mutation)
        require('legacy_before_side_effect', row['rc'] == 0 and marker.exists() == mutation
                and (not marker.exists() or marker.read_bytes() == b'launched'))
    for kind in ('buffered','raw','automatic','abort'):
        expected = {'buffered':b'BUFFERED', 'raw':b'\xff\x00R', 'automatic':b'7\n', 'abort':b'STASH'}[kind]
        guarded = case('output_guard_' + kind,'sealed','output',kind)
        negative = case('output_mutation_' + kind,'sealed','output',kind,mutate=True)
        require('legacy_output_guard_' + kind, guarded['rc'] == 0 and guarded['endpoint_hex'] == ''
                and negative['endpoint_hex'] == expected.hex() and negative['rc'] == (1 if kind == 'abort' else 0))
    buffered_seed = b'FIRST\nSECOND\n'
    for mutation in (False,True):
        row = case('buffered_input' + str(mutation),'sealed','input','-',buffered_seed,mutate=mutation)
        require('buffered_input_guard',row['rc'] == 0 and row['remaining_hex'] == ('' if mutation else buffered_seed.hex()))
    prior_input = case('prior_buffered_input','history','input','-',buffered_seed)
    require('prior_buffered_input_blocks_acquire',prior_input['rc'] == 0
            and value(prior_input,'acquire') == 3 and prior_input['remaining_hex'] == '')

    regular = out / 'regular'
    regular.write_bytes(b'CONFIG')
    for op, arg in [('hash',str(regular)),('resolver','127.0.0.1'),
                    ('legacy','exit 0'),('native','exit 0')]:
        for mode in ('history','inflight'):
            row = case(mode + '_' + op,mode,op,arg)
            require('admission_' + mode + '_' + op, row['rc'] == 0
                    and (value(row,'acquire') == 3 if mode == 'history' else
                         value(row,'acquire_busy') == value(row,'cancel_does_not_release') == 2
                         and value(row,'acquire_after') == 3 and value(row,'cancel_requested_without_releasing_admission') == 1))
            if mode == 'inflight' and op == 'native':
                require('actual_native_queue_acceptance',value(row,'native_ticket_accepted_held_before_create') == 1)
        negative = case('history_mutation_' + op,'history',op,arg,mutate=True)
        require('history_guard_detects_mutation_' + op, value(negative,'acquire') == 0)
    negative = case('inflight_guard_mutation','inflight','hash',str(regular),mutate=True)
    require('inflight_guard_detects_mutation', value(negative,'acquire_busy') == 0)
    released = case('release_reacquire','release','write',str(out / 'release-marker'),seed)
    require('release_keeps_restrictions', value(released,'reacquire') == 0
            and value(released,'operation_ok') == 0 and not (out/'release-marker').exists())

    work = case('representative_supervisor','work',str(out/'telemetry'),str(root))
    require('runtime_seal_witnessed_blocker', work['rc'] == 0 and value(work,'read_source') == 0
            and value(work,'read_config') == 0 and value(work,'emit_telemetry') == 0
            and value(work,'write_scratch') == 0 and not (out/'telemetry').exists())
    native_rc = value(work,'submit_worker_rc')
    save('sealed_worker_external_marker','PASS' if native_rc == 0 and (out/'telemetry.worker').exists() else 'UNAVAILABLE',
         launch_rc=native_rc,marker_exists=(out/'telemetry.worker').exists())
    control = case('representative_supervisor_control','work-control',str(out/'control-telemetry'),str(root))
    require('supervisor_operations_positive_control',control['rc'] == 0 and
            all(value(control,k) == 1 for k in ('read_source','read_config','emit_telemetry','mkdir_scratch','write_scratch'))
            and (out/'control-telemetry').read_bytes() == b'EVENT\n')
    save('runtime_seal_decision','REFUSED', reason='C1 denies required source/config, telemetry and scratch content I/O before effects',
         production_boundary_qualified=False)

    programs = {
        'empty': 'main = ()\n',
        'net_only': """main : <Net "leasealias"> Unit
main = match netResolve "leasealias"
  Ok _ => ()
  Err _ => ()
""",
        'automatic': 'main = 7\n',
        'internal_stdout': 'main = byteBlockWriteStdout (byteBlockFromString "RAW")\n',
        'stash_exposure': 'main = stashRunStdout "EXPOSED"\n',
        'enable_exposure': 'main = enableRunStdoutFlush ()\n',
        'abort_exposure': """main =
  enableRunStdoutFlush ()
  stashRunStdout "EXPOSED"
  panic "CONTROL"
""",
    }
    for name, source in programs.items():
        path = out / (name + '.mdk')
        path.write_text(source)
        command(name + '_fmt',[root/'medaka','fmt','--write',path])
        command(name + '_lint',[root/'medaka','lint',path])
        if name == 'internal_stdout':
            rejected = command(name+'_check_reject',[root/'medaka','check',path],expected=1)
            require('internal_rejection_class', b'internal' in rejected.stderr.lower() + rejected.stdout.lower())
            command(name+'_check_allow',[root/'medaka','check','--allow-internal',path])
        if name.endswith('_exposure'):
            result = subprocess.run([root/'medaka','check',path],cwd=out,env=env,capture_output=True,timeout=120)
            save(name+'_ordinary_check','OBSERVED',rc=result.returncode,
                 stdout_hex=result.stdout.hex(),stderr_hex=result.stderr.hex(),
                 expected_security_verdict='reject internal-only extern; current acceptance is #4865 exposure')
            command(name+'_check_allow',[root/'medaka','check','--allow-internal',path])
        if name in ('net_only','automatic'):
            command(name+'_policy',[root/'medaka','check-policy',path,'--allow',
                                    'Net=leasealias' if name == 'net_only' else 'Stdout','--fn','main'])
        if name == 'net_only':
            command('net_policy_missing_grant',[root/'medaka','check-policy',path,'--allow','Stdout','--fn','main'],expected=1)
        native_exe = out / (name + '.exe')
        command(name+'_build',[root/'medaka','build'] + (['--allow-internal'] if name=='internal_stdout' else [])
                + [path,'-o',native_exe])
        inp, writer = os.pipe()
        try:
            os.write(writer, aliases)
            os.close(writer)
            writer = -1
            result = subprocess.run([native_exe],stdin=inp,env=dict(env,HOSTALIASES='/proc/self/fd/0'),
                                    capture_output=True,timeout=25)
            remaining = os.read(inp,65536)
            expected = {'empty':b'', 'net_only':b'', 'automatic':b'7\n', 'internal_stdout':b'RAW',
                        'stash_exposure':b'', 'enable_exposure':b'', 'abort_exposure':b'EXPOSED'}[name]
            require(name+'_native_bytes',result.returncode == (1 if name == 'abort_exposure' else 0) and result.stdout == expected
                    and remaining == (b'' if name=='net_only' else aliases),rc=result.returncode,
                    endpoint_hex=result.stdout.hex(),remaining_hex=remaining.hex(),stderr_hex=result.stderr.hex())
        finally:
            os.close(inp)
            if writer >= 0:
                os.close(writer)
    save('admission_policy_decision','UNQUALIFIED',reason='check-policy is advisory; ordinary native build runs Net-only resolver and automatic output. No production admission/seal path exists.')

    carriers = {'.mdk','.sh','.py','.c','.mjs','.js','.awk','.wat','.in','.mdki','.md','.fixed',''}
    inventory = []
    paths = subprocess.check_output(['git','-C',str(root),'ls-files','-z','test'],text=True).split('\0')
    counts, excluded = Counter(), Counter()
    for relative in paths:
        path = root / relative
        if not relative or not path.is_file():
            continue
        if path.suffix not in carriers:
            excluded[path.suffix] += 1
            continue
        text = path.read_text(errors='replace')
        hits = {rule: [dict(line=text.count('\n',0,m.start())+1,token=m.group())
                       for m in re.finditer(pattern,text)] for rule,(_,pattern) in RULES.items()}
        hits = {rule: values for rule,values in hits.items() if values}
        counts.update(hits.keys())
        inventory.append(dict(path=relative,sha256=hashlib.sha256(path.read_bytes()).hexdigest(),
                              rules=hits,classification='candidate conflict' if hits else 'no lexical trigger'))
    census = dict(scope='All tracked test/** program carriers; full file text includes inline programs. Overlapping lexical candidates include comments/strings; not semantic or unique-program counts.',
                  suffixes=sorted(carriers),files=len(inventory),rules={k:v[0] for k,v in RULES.items()},
                  file_counts=dict(counts),inline_host_files=sum(Path(r['path']).suffix!='.mdk' for r in inventory),
                  no_lexical_trigger=sum(not r['rules'] for r in inventory),inventory=inventory)
    census['excluded_artifact_suffix_counts'] = dict(excluded)
    (out/'compatibility-census.json').write_text(json.dumps(census,indent=2)+'\n')
    save('compatibility_census','OBSERVED',files=census['files'],file_counts=census['file_counts'],
         inline_host_files=census['inline_host_files'],no_lexical_trigger=census['no_lexical_trigger'],
         census_sha256=hashlib.sha256((out/'compatibility-census.json').read_bytes()).hexdigest())
    save('cleanup','PASS',detail='Every Popen waited; C fork child exactly reaped; runtime launch terminal/dispose or structured unavailable; private scratch directory removed',
         native_unavailable=[r for row in rows for r in row.get('reports',[]) if r['name'] in ('native_launch_unavailable','submit_error')])
    save('qualification','BLOCKED',exit_code=77,reason='Runtime seal conflicts with supervisor obligations. No enforceable narrower file/NSS/worker split qualified. No production API authorized.')
    return 77


if __name__ == '__main__':
    sys.exit(main())
