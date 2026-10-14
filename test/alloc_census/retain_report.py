#!/usr/bin/env python3
"""usage: retain_report.py <workdir> [--top N] [--census K ...]

Helper of test/retain_census.sh.  Reads <workdir>/{sites.tsv, appsites.tsv,
retain.out, medaka_retain} and prints the live series, then for each selected
census (default: the first, the middle and the last) live bytes by allocating
function and by module, then the referrer table when the run had targets.
Live bytes include the census's own 8-byte header per object.
"""
import os
import subprocess
import sys
from collections import defaultdict

args = sys.argv[1:]
work = args.pop(0)
top = 25
want = []
while args:
    a = args.pop(0)
    if a == '--top':
        top = int(args.pop(0))
    elif a == '--census':
        while args and not args[0].startswith('--'):
            want.append(int(args.pop(0)))

sites = {}
with open(os.path.join(work, 'sites.tsv')) as f:
    next(f)
    for ln in f:
        r = ln.rstrip('\n').split('\t')
        sites[int(r[0])] = (r[1], r[3])
app = {}
with open(os.path.join(work, 'appsites.tsv')) as f:
    for ln in f:
        r = ln.rstrip('\n').split('\t')
        app[int(r[0])] = r[1]

censuses = []
rt_pc = {}
with open(os.path.join(work, 'retain.out')) as f:
    for ln in f:
        r = ln.rstrip('\n').split('\t')
        if r[0] == 'census':
            cur = {'no': int(r[1]), 'alloc': int(r[2]), 'heap': int(r[3]),
                   'rows': defaultdict(lambda: [0, 0]), 'refs': {}}
            censuses.append(cur)
        elif r[0] == 'site':
            cur['rows'][('site', int(r[1]))] = [int(r[2]), int(r[3])]
        elif r[0] == 'rt':
            rt_pc[int(r[1])] = r[2]
            cur['rows'][('rt', int(r[1]))] = [int(r[3]), int(r[4])]
        elif r[0] == 'app':
            cur['rows'][('app', int(r[1]))] = [int(r[2]), int(r[3])]
        elif r[0] == 'untagged':
            cur['rows'][('untagged', 0)] = [int(r[1]), int(r[2])]
        elif r[0] == 'ref':
            cur['refs'][int(r[1])] = int(r[2])

# runtime callers by return address; needs the non-PIE link and addr2line
rt_name = {}
slots = sorted(rt_pc)
if slots:
    try:
        lines = subprocess.run(['addr2line', '-f', '-e', os.path.join(work, 'medaka_retain')]
                               + [rt_pc[s] for s in slots],
                               capture_output=True, text=True).stdout.split('\n')
        for i, s in enumerate(slots):
            rt_name[s] = lines[2 * i]
    except OSError:
        pass

APP_BASE = 0x400000


def name(kind, i):
    if kind == 'site':
        fn, k = sites.get(i, ('?', '?'))
        return fn, k
    if kind == 'app':
        return '++ in ' + app.get(i, '?'), 'Cons'
    if kind == 'rt':
        return 'rt:' + rt_name.get(i, rt_pc.get(i, '?')), ''
    return '<untagged>', ''


def key_name(key):
    cls, i = key >> 23, key & 0x7fffff
    if cls == 0:
        return '%s (%s)' % name('site', i)
    if i >= APP_BASE:
        return name('app', i - APP_BASE)[0]
    return name('rt', i)[0]


def module(fn):
    fn = fn.replace('++ in ', '').replace('rt:', '')
    # lifted lambdas, eta and pap wrappers name their module in a dotted suffix:
    # mdk_lam.frontend_parser.36, mdk_eta_<target>.frontend_parser.34
    parts = fn.split('.')
    if len(parts) >= 3 and parts[0].startswith(('mdk_lam', 'mdk_eta_', 'mdk_pap_')):
        return parts[-2]
    if fn.startswith('mdk_') and '__' in fn:
        return fn[4:].split('__')[0]
    return fn


print('census  alloc_GB  heap_MB  live_MB')
for c in censuses:
    live = sum(b for _, b in c['rows'].values())
    print(f"{c['no']:6d} {c['alloc']/1e9:9.1f} {c['heap']/1e6:8.0f} {live/1e6:8.1f}")
if not censuses:
    sys.exit(0)
if not want:
    want = sorted({censuses[0]['no'], censuses[len(censuses) // 2]['no'], censuses[-1]['no']})

for c in censuses:
    if c['no'] not in want:
        continue
    by_fn, by_mod = defaultdict(lambda: [0, 0]), defaultdict(int)
    for (kind, i), (n, b) in c['rows'].items():
        fn, k = name(kind, i)
        by_fn[(fn, k)][0] += n
        by_fn[(fn, k)][1] += b
        by_mod[module(fn)] += b
    tot = sum(b for _, b in by_fn.values())
    print(f"\n== census {c['no']}: {tot/1e6:.1f} MB live, by allocating function")
    for (fn, k), (n, b) in sorted(by_fn.items(), key=lambda kv: -kv[1][1])[:top]:
        print(f"{b/1e6:9.2f} MB {100*b/tot:5.1f}% {n/1e3:9.1f}k  {fn} {k}")
    print(f"-- by module")
    for m, b in sorted(by_mod.items(), key=lambda kv: -kv[1])[:12]:
        print(f"{b/1e6:9.2f} MB {100*b/tot:5.1f}%  {m}")
    if c['refs']:
        print(f"-- referrers into the target set (fields pointing in, by referrer)")
        for key, cnt in sorted(c['refs'].items(), key=lambda kv: -kv[1])[:top]:
            print(f"{cnt:9d}  {key_name(key)}")
