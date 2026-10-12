#!/usr/bin/env python3
"""usage: report.py sites.tsv counts binary [nosym]
Pass `nosym` to skip runtime (C) caller symbolization (addr2line needs the
non-PIE Linux link)."""
import subprocess
import sys
from collections import defaultdict

sites_p, counts_p, binary = sys.argv[1:4]
sites = {}
with open(sites_p) as f:
    next(f)
    for ln in f:
        r = ln.rstrip('\n').split('\t')
        sites[int(r[0])] = r
total = 0
sn, sb = {}, {}
rt = []
with open(counts_p) as f:
    for ln in f:
        r = ln.split('\t')
        if r[0] == 'total_bytes':
            total = int(r[1])
        elif r[0] == 'site':
            sn[int(r[1])] = int(r[2]); sb[int(r[1])] = int(r[3])
        else:
            rt.append((r[1], int(r[2]), int(r[3])))

site_n, site_b = sum(sn.values()), sum(sb.values())
rt_n, rt_b = sum(x[1] for x in rt), sum(x[2] for x in rt)
print(f'TOTAL ALLOCATIONS {(site_n+rt_n)/1e6:.1f} M (emitted sites + runtime callers)')
print(f'GC total bytes {total/1e9:.2f} GB')
print(f'  emitted sites: {site_n/1e6:8.1f} M allocs {site_b/1e9:6.2f} GB  ({len(sn)} of {len(sites)} sites fired)')
print(f'  runtime (C)  : {rt_n/1e6:8.1f} M allocs {rt_b/1e9:6.2f} GB')
print(f'  other GC_malloc (direct in C): {(total-site_b-rt_b)/1e9:.2f} GB')
alln, allb = site_n + rt_n, site_b + rt_b


def table(keyf, title, top=None):
    n, b = defaultdict(int), defaultdict(int)
    for i, c in sn.items():
        k = keyf(sites[i]); n[k] += c; b[k] += sb[i]
    print(f'\n== {title}  (share of ALL allocations incl. runtime: count / bytes)')
    rows = sorted(n, key=lambda k: -n[k])
    for k in rows[:top]:
        print(f'  {str(k):42s} {n[k]/1e6:8.1f}M {100*n[k]/alln:5.1f}%  {b[k]/1e9:6.2f}GB {100*b[k]/allb:5.1f}%')


table(lambda r: r[4], 'by escape class')
table(lambda r: r[3], 'by kind')
table(lambda r: (r[4], r[3]), 'class x kind', 25)
table(lambda r: (r[4], 'phi' if r[5] else 'nophi'), 'class x loop-carried phi')

print('\n== top NOESC / RET_LOCAL sites')
cand = sorted((i for i in sn if sites[i][4] in ('NOESC', 'RET_LOCAL')), key=lambda i: -sn[i])
for i in cand[:15]:
    r = sites[i]
    print(f'  {sn[i]/1e6:7.2f}M {r[4]:9s} {r[3]:10s} size={r[2]:4s} {r[1][:70]}')

print('\n== top CALLEE_ESC / UNKNOWN_CALL escape targets (by allocs)')
t = defaultdict(int)
for i, c in sn.items():
    r = sites[i]
    if r[4] in ('CALLEE_ESC', 'UNKNOWN_CALL'):
        for g in (r[6].split(',') if r[6] else ['<indirect>']):
            t[g] += c
for g in sorted(t, key=lambda g: -t[g])[:15]:
    print(f'  {t[g]/1e6:7.2f}M  {g[:80]}')

print('\n== top emitted sites overall')
for i in sorted(sn, key=lambda i: -sn[i])[:15]:
    r = sites[i]
    print(f'  {sn[i]/1e6:7.2f}M {r[4]:12s} {r[3]:10s} size={r[2]:4s} {r[1][:64]}')

# runtime callers
if len(sys.argv) > 4 and sys.argv[4] == 'nosym':
    print('\n== runtime (C) allocators: caller symbolization skipped on this platform')
    sys.exit(0)
addrs = [x[0] for x in rt]
out = subprocess.run(['addr2line', '-f', '-e', binary] + addrs, capture_output=True, text=True).stdout.split('\n')
fn = defaultdict(lambda: [0, 0])
for k, x in enumerate(rt):
    name = out[2 * k] if 2 * k < len(out) else '?'
    fn[name][0] += x[1]; fn[name][1] += x[2]
print('\n== runtime (C) allocators')
for name in sorted(fn, key=lambda k: -fn[k][0])[:15]:
    print(f'  {fn[name][0]/1e6:7.2f}M {100*fn[name][0]/alln:5.1f}%  {fn[name][1]/1e9:6.2f}GB  {name}')
