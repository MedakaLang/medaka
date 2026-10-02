#!/usr/bin/env python3
"""show_results.py — print what each battery program did on one arm.

Usage: python3 test/visitor_battery/tools/show_results.py <run|native|wasm> [RESULTS_DIR] [name,prefixes]
RESULTS_DIR defaults to test/visitor_battery/results (what run_battery.sh writes).
"""
import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent
arm = sys.argv[1] if len(sys.argv) > 1 else 'run'
R = pathlib.Path(sys.argv[2]) if len(sys.argv) > 2 else HERE.parent / 'results'
only = sys.argv[3].split(',') if len(sys.argv) > 3 else None

rows = {}
for line in (R / 'summary.tsv').read_text().splitlines():
    n, a, ec, t = line.split('\t')
    if a == arm:
        rows[n] = (ec, t)


def cat(p, lim=1200):
    if not p.exists():
        return '<missing>'
    s = p.read_text(errors='replace')
    return s if len(s) <= lim else s[:lim] + f'\n...[{len(s)} bytes total]'


for n in sorted(rows):
    if only and not any(n.startswith(o) for o in only):
        continue
    ec, t = rows[n]
    print(f'===== {n}  [{arm}] exit={ec} time={t}s')
    if arm == 'run':
        out, err = R / f'{n}.run.out', R / f'{n}.run.err'
    elif arm == 'native':
        out, err = R / f'{n}.native.out', R / f'{n}.native.err'
        if str(ec).startswith('B'):
            print('--- build stderr:'); print(cat(R / f'{n}.build.err'))
            continue
    else:
        out, err = R / f'{n}.wasm.out', R / f'{n}.wasm.err'
        if str(ec).startswith('C'):
            print('--- compile diagnostics:'); print(cat(R / f'{n}.wat'))
            continue
        if ec == 'P':
            print('--- wat parse error:'); print(cat(R / f'{n}.wasm.perr'))
            continue
    print('--- stdout:'); print(cat(out))
    e = cat(err)
    if e.strip():
        print('--- stderr:'); print(e)
