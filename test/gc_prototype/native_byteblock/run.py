#!/usr/bin/env python3
"""On-demand correctness of real ByteBlock helpers and checked typed kernels."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import shutil

ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=Path, default=Path('/tmp/medaka-byteblock-check'))
parser.add_argument('--emitter', type=Path, default=ROOT/'test/bin/llvm_emit_typed_main')
parser.add_argument('--build-manifest', type=Path, required=True)
parser.add_argument('--record-build', action='store_true', help='explicitly force-build the oracle and record its actual source/binary binding')
args = parser.parse_args()
if args.output.exists() and any(args.output.iterdir()):
    parser.error('output directory must be empty')
args.output.mkdir(parents=True, exist_ok=True)
records = []
env = {k:v for k,v in os.environ.items() if not k.startswith(('MEDAKA_', 'GC_', 'MDK_BYTEBLOCK_'))}
env.update(MEDAKA_STRICT='1', ASAN_OPTIONS='detect_leaks=0:abort_on_error=1:use_sigaltstack=0', UBSAN_OPTIONS='halt_on_error=1:print_stacktrace=1')

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def matrix_input_hashes(paths):
    return {str(p):digest(p) for p in paths}

def verify_matrix_inputs(paths, expected):
    if matrix_input_hashes(paths) != expected:
        raise RuntimeError('matrix collector/helper/fixture source drift')

def source_hashes():
    paths = [*ROOT.joinpath('compiler').rglob('*.mdk'),*ROOT.joinpath('stdlib').rglob('*.mdk'),
             *ROOT.joinpath('compiler').rglob('medaka.toml'),*ROOT.joinpath('stdlib').rglob('medaka.toml'),
             *ROOT.joinpath('runtime').rglob('*.c'),*ROOT.joinpath('runtime').rglob('*.h'),
             *ROOT.joinpath('test').glob('build*.sh'), ROOT/'test/lib_scratch.sh',
             ROOT/'test/emitter_source_set.awk',ROOT/'Makefile']
    return {str(p.relative_to(ROOT)):digest(p) for p in paths if p.is_file()}

build_command = ['sh','test/build_oracles.sh','--build-one','llvm_emit_typed_main']
if args.record_build:
    if args.build_manifest.exists(): parser.error('build manifest must not already exist')
    before = source_hashes()
    builders = {name:digest(ROOT/name) for name in ('medaka','medaka_emitter')}
    p = subprocess.run(build_command,cwd=ROOT,env={**env,'FORCE':'1','JOBS':'1'},capture_output=True,text=True,timeout=600)
    if p.returncode: raise RuntimeError(p.stderr)
    assert before == source_hashes() and builders == {name:digest(ROOT/name) for name in builders}
    args.build_manifest.write_text(json.dumps({'cwd':str(ROOT),'argv':build_command,'exit':p.returncode,
        'environment':{'FORCE':'1','JOBS':'1'},'stdout':p.stdout,'stderr':p.stderr,
        'sources':before,'builders':builders,'emitter_sha256':digest(args.emitter)},indent=2)+'\n')
    print(args.build_manifest)
    sys.exit(0)

build = json.loads(args.build_manifest.read_text())
def verify_build():
    assert build['sources'] == source_hashes() and build['emitter_sha256'] == digest(args.emitter)
    assert build['builders'] == {name:digest(ROOT/name) for name in ('medaka','medaka_emitter')}
    assert args.emitter.resolve() == (ROOT/'test/bin/llvm_emit_typed_main').resolve()
    assert build['cwd'] == str(ROOT) and build['exit'] == 0
    assert build['argv'] == build_command
    assert build['environment']['FORCE'] == '1' and build['environment']['JOBS'] == '1'
verify_build()

def run(argv, extra=None, success=True):
    current = {**env, **(extra or {})}
    try:
        p = subprocess.run([str(x) for x in argv], cwd=ROOT, env=current,
                           capture_output=True, text=True, timeout=600)
    except subprocess.TimeoutExpired as error:
        stdout = error.stdout or b''
        stderr = error.stderr or b''
        records.append({'argv':[str(x) for x in argv],'extra_environment':extra or {},'exit':None,'timeout_seconds':600,
                        'stdout_sha256':hashlib.sha256(stdout if isinstance(stdout,bytes) else stdout.encode()).hexdigest(),
                        'stderr':stderr.decode(errors='replace') if isinstance(stderr,bytes) else stderr})
        with (args.output/'attempts.jsonl').open('a') as journal:
            journal.write(json.dumps(records[-1])+'\n')
        raise
    records.append({'argv':[str(x) for x in argv], 'extra_environment':extra or {},
                    'exit':p.returncode, 'stdout_sha256':hashlib.sha256(p.stdout.encode()).hexdigest(),
                    'stderr':p.stderr})
    with (args.output/'attempts.jsonl').open('a') as journal:
        journal.write(json.dumps(records[-1])+'\n')
    if success and p.returncode:
        raise RuntimeError(records[-1])
    return p

def diagnostics(p):
    lines = [line.removeprefix('BYTEBLOCK_GC ') for line in p.stderr.splitlines()
             if line.startswith('BYTEBLOCK_GC ')]
    if len(lines) != 1 or len(p.stderr.splitlines()) != 1:
        raise RuntimeError(f'invalid diagnostics: {p.stderr}')
    return json.loads(lines[0])

run([ROOT/'medaka', 'check', ROOT/'compiler/backend/native_byteblock_kernel.mdk'])
try:
    gc_flags = shlex.split(subprocess.check_output(['pkg-config','--cflags','--libs','bdw-gc'],text=True))
except (OSError, subprocess.CalledProcessError):
    prefix = subprocess.check_output(['brew','--prefix','bdw-gc'],text=True).strip()
    gc_flags = [f'-I{prefix}/include',f'-L{prefix}/lib','-lgc']
cases = []
for n in (0,1,7,8,9,15,16,257):
    source = args.output/f'count-{n}.mdk'
    tail = (f'  byteBlockSetUnsafe {n-1} 77 source\n  byteBlockGetUnsafe {n-1} (byteBlockCopyUnsafe {n} source)'
            if n else '  byteBlockLength (byteBlockCopyUnsafe 0 source)')
    if n in (0,1):
        source = HERE/('empty_main.mdk' if n == 0 else 'copy_main.mdk')
    else:
        source.write_text(f'main : Int\nmain =\n  let source = byteBlockMake {n}\n{tail}\n')
    cases.append((f'count-{n}',source,77 if n else 0,n))
cases.append(('overlap', HERE/'blit_main.mdk',77,9))
matrix_paths = [ROOT/'test/gc_prototype/gc.c',ROOT/'test/gc_prototype/gc.h',
                HERE/'shim.c',HERE/'mdk_gc_byteblock_bridge.h',HERE/'run.py',
                *(source for _,source,_,_ in cases)]
matrix_before = matrix_input_hashes(matrix_paths)
(args.output/'matrix-inputs-before.json').write_text(json.dumps(matrix_before,indent=2)+'\n')
results = []
for name, source, answer, n in cases:
    ll = args.output/f'{name}.ll'
    proof, report = args.output/f'{name}.proof', args.output/f'{name}.sexpr'
    outputs = {'MEDAKA_BYTEBLOCK_KERNEL_PROOF':str(proof), 'MEDAKA_NATIVE_GC_CONTRACT':str(report)}
    emitted = run([args.emitter,'--byteblock-kernel',ROOT/'stdlib/runtime.mdk',source],outputs)
    raw = emitted.stdout.removesuffix('()\n')
    assert proof.read_text().startswith('(byteblock-kernel v1 ')
    assert 'moving-safe=false' in report.read_text()
    assert raw == run([args.emitter,ROOT/'stdlib/runtime.mdk',source]).stdout.removesuffix('()\n')
    ll.write_text(raw)
    for profile, flags in [('O0',['-O0']),('O2',['-O2','-fstrict-aliasing']),
                           ('san',['-O1','-fsanitize=address,undefined','-fno-omit-frame-pointer'])]:
        for mode in ('custom','boehm'):
            binary = args.output/f'{name}-{profile}-{mode}'
            command = ['clang',*flags,'-DMEDAKA_TEST_BYTEBLOCK_GC',f'-I{HERE}',str(ll),
                       str(ROOT/'runtime/medaka_rt.c'),str(ROOT/'test/gc_prototype/gc.c'),str(HERE/'shim.c'),
                       *(['-DUSE_BOEHM'] if mode == 'boehm' else []),*gc_flags,'-lm','-o',str(binary)]
            built = run(command,success=False)
            if built.returncode and profile == 'san' and sys.platform.startswith('linux') and 'libclang_rt' in built.stderr:
                command = command[:1]+['-fno-sanitize-link-runtime','-Wl,--no-as-needed','-lasan','-lubsan','-Wl,--as-needed']+command[1:]
                built = run(command,success=False)
            if built.returncode: raise RuntimeError(records[-1])
            p = run([binary],{'MDK_BYTEBLOCK_NURSERY':'32'})
            stat = diagnostics(p)
            assert p.stdout == f'{answer}\n' and stat['status'] == 'ok' and stat['joined'] == 1 and stat['root_bytes'] == 0
            if mode == 'custom' and n <= 8:
                assert stat['calls'] == 2 and stat['source_young'] == 1 and stat['source_moved'] == 1 and stat['promoted'] > 0 and stat['copied_payload'] > 0
            if mode == 'custom' and n >= 9:
                assert stat['source_young'] == 0 and stat['source_moved'] == 0 and stat['direct_old'] == 2
            results.append({'case':name,'profile':profile,'mode':mode,'stdout':p.stdout,'stats':stat})
            if mode == 'custom' and name == 'count-1':
                for mutation, status in [('ROOT','missing-helper-root'),('RELOAD','stale-source-word'),
                                         ('MASK','byteblock-atomic-mask'),('VERSION','byteblock-layout-version')]:
                    mutant = args.output/f'{name}-{profile}-{mutation}'
                    run(command[:-2]+[f'-DMDK_BB_MUTATE_{mutation}','-o',str(mutant)])
                    bad = run([mutant],success=False)
                    control = diagnostics(bad)
                    assert bad.returncode == 78 and not bad.stdout and control['status'] == status
                    if mutation == 'ROOT': assert control['calls'] == 2 and control['minor'] == 0 and control['root_bytes'] == 0 and control['copy_guard_reached'] == 1
                    if mutation == 'RELOAD': assert control['calls'] == 2 and control['source_young'] == 1 and control['source_moved'] == 1 and control['promoted'] > 0
                    if mutation in ('MASK','VERSION'): assert control['receipt_checked'] == 0
                    results.append({'mutation':mutation,'profile':profile,'stats':control,'exit':bad.returncode})
                for bound, status in [(0,'byteblock-signed-extent'),(1,'byteblock-signed-extent'),(2,'byteblock-object-extent')]:
                    mutant = args.output/f'{name}-{profile}-bound-{bound}'
                    run(command[:-2]+[f'-DMDK_BB_BOUND_CONTROL={bound}','-o',str(mutant)])
                    bad = run([mutant],success=False)
                    control = diagnostics(bad)
                    assert bad.returncode == 78 and not bad.stdout and control['status'] == status and control['calls'] == 0
                    results.append({'bound_control':bound,'profile':profile,'stats':control,'exit':bad.returncode})
            if mode == 'custom' and name == 'count-9':
                mutant = args.output/f'extent-{profile}'
                run(command[:-2]+['-DMDK_BB_MUTATE_EXTENT','-o',str(mutant)])
                bad = run([mutant],success=False)
                control = diagnostics(bad)
                assert bad.returncode == 78 and not bad.stdout and control['status'] == 'byteblock-extent-mismatch'
                assert control['requested_bytes'] == 32 and control['actual_bytes'] == 16 and control['receipt_checked'] == 0
                results.append({'mutation':'EXTENT','profile':profile,'stats':control,'exit':bad.returncode})
rejects = {
    'reuse':'main : Int\nmain =\n  let source = byteBlockMake 1\n  let copy = byteBlockCopyUnsafe 1 source\n  byteBlockGetUnsafe 0 source',
    'later-argument':'main : Int\nmain =\n  let source = byteBlockMake 1\n  byteBlockBlit source 0 (byteBlockMake 1) 0 1\n  byteBlockLength (byteBlockCopyUnsafe 1 source)',
    'extern':'extern custom : Int -> Int\nmain : Int\nmain = custom 1',
    'import':'import bytes as B\nmain : Int\nmain = 1',
    'extra-definition':'unused x = x\nmain : Int\nmain = 1',
    'closure':'main : Int\nmain =\n  let source = byteBlockMake 1\n  let f = x => byteBlockGetUnsafe 0 source\n  f 0',
}
for name, text in rejects.items():
    source = args.output/f'reject-{name}.mdk'
    source.write_text(text+'\n')
    p = run([args.emitter,'--byteblock-kernel',ROOT/'stdlib/runtime.mdk',source],success=False)
    assert p.returncode != 0 and 'byteblock kernel:' in p.stderr and not p.stdout
    results.append({'rejection':name,'exit':p.returncode,'stderr':p.stderr})
altered = args.output/'altered-runtime.mdk'
altered.write_text((ROOT/'stdlib/runtime.mdk').read_text()+'\n-- altered trusted catalog\n')
missing = args.output/'relocated/test/bin/llvm_emit_typed_main'
missing.parent.mkdir(parents=True)
shutil.copyfile(args.emitter,missing)
missing.chmod(0o755)
for name, emitter, catalog in [('altered-catalog',args.emitter,altered),('missing-canonical',missing,ROOT/'stdlib/runtime.mdk')]:
    p = run([emitter,'--byteblock-kernel',catalog,HERE/'copy_main.mdk'],success=False)
    assert p.returncode != 0 and 'trusted canonical runtime catalog missing or mismatched' in p.stderr and not p.stdout
    results.append({'rejection':name,'exit':p.returncode,'stderr':p.stderr})
verify_build()
verify_matrix_inputs(matrix_paths,matrix_before)
paths = [ROOT/'runtime/medaka_rt.c',ROOT/'test/gc_prototype/gc.c',ROOT/'test/gc_prototype/gc.h',
         ROOT/'compiler/backend/native_byteblock_kernel.mdk',ROOT/'compiler/entries/llvm_emit_typed_main.mdk',
         ROOT/'compiler/backend/native_gc_contract.mdk',ROOT/'stdlib/runtime.mdk',*HERE.glob('*')]
artifact = {'scope':'checked atomic ByteBlock kernel only; full varint custom execution unsupported',
            'base':subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),
            'sources':{str(p.relative_to(ROOT)):{'sha256':digest(p),'text':p.read_text()} for p in paths if p.is_file()},
            'emitter_sha256':digest(args.emitter),'medaka_sha256':digest(ROOT/'medaka'),
            'verified_build_manifest':build,'build_manifest_sha256':digest(args.build_manifest),
            'matrix_input_hashes_before_and_after':matrix_before,
            'commands':records,'results':results,'ASAN_OPTIONS':env['ASAN_OPTIONS'],'UBSAN_OPTIONS':env['UBSAN_OPTIONS'],
            'sanitizer_limits':'LeakSanitizer disabled for Boehm; ASan alternate-stack management disabled because real runtime installs a static worker signal stack. Memory instrumentation remains enabled.',
            'generated_artifacts':{p.name:digest(p) for p in args.output.iterdir() if p.suffix in ('.mdk','.ll','.proof','.sexpr')}}
(args.output/'result.json').write_text(json.dumps(artifact,indent=2)+'\n')
print(f'{len(results)} checked: {args.output / "result.json"}')
