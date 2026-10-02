import pathlib, sys
R = pathlib.Path('/var/tmp/medaka-scratch/claude-0/-root-medaka/42371736-88ae-460b-b194-a26e487bb4d9/scratchpad/results')
arm = sys.argv[1]
only = sys.argv[2].split(",") if len(sys.argv) > 2 else None
rows = {}
for line in (R / 'summary.tsv').read_text().splitlines():
    n, a, ec, t = line.split('\t')
    if a == arm: rows[n] = (ec, t)
def cat(p, lim=1200):
    if not p.exists(): return '<missing>'
    s = p.read_text(errors='replace')
    return s if len(s) <= lim else s[:lim] + f'\n...[{len(s)} bytes total]'
for n in sorted(rows):
    if only and not any(n.startswith(o) for o in only): continue
    ec, t = rows[n]
    print(f'===== {n}  [{arm}] exit={ec} time={t}s')
    if arm == 'run':
        out, err = R / f'{n}.run.out', R / f'{n}.run.err'
    elif arm == 'native':
        out, err = R / f'{n}.native.out', R / f'{n}.native.err'
        berr = R / f'{n}.build.err'
        if str(ec).startswith('B'):
            print('--- build stderr:'); print(cat(berr)); print('--- build stdout:'); print(cat(R / f'{n}.build.out'))
            continue
    else:
        out, err = R / f'{n}.wasm.out', R / f'{n}.wasm.err'
        if str(ec).startswith('C'):
            print('--- compile diagnostics:'); print(cat(R / f'{n}.wat')); print('--- compile stderr:'); print(cat(R / f'{n}.wasm.cerr'))
            continue
        if ec == 'P':
            print('--- wat parse error:'); print(cat(R / f'{n}.wasm.perr')); continue
    print('--- stdout:'); print(cat(out))
    e = cat(err)
    if e.strip(): print('--- stderr:'); print(e)
