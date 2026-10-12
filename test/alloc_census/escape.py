#!/usr/bin/env python3
"""Escape census over -O2 LLVM IR emitted by medaka.

usage: escape.py <in.opt.ll> <out.instrumented.ll> <sites.tsv>

For every `call ptr @mdk_alloc[_atomic](i64 N)` in the optimized IR, follow the
returned pointer through derived values and classify where it goes.  Per-param
escape summaries for every defined function are solved to a fixpoint
(NOESC < RETURNED < ESC) so passing a cell to a callee that only reads it does not
count as an escape.  Each site is rewritten to `@mdk_alloc_site(i64 N, i64 ID)` so
a run can count it.

Limits. This is a LOWER BOUND on "does not escape"; every approximation errs
toward "escapes", never toward "free":
- A store into a cell that itself does not escape still counts as an escape.
- RET_LOCAL needs every direct caller to keep the result local, and the
  function's address never taken.
- Header-word decoding knows tuple, ref, closure, PAP and the reserved
  List/Option/Result tags only; user ADTs are just "adt/record".
- The census counts allocations in the -O2 IR of the non-LTO build, i.e. after
  LLVM's own deletions; it is not a count of what the source asks for.
"""
import re
import sys
from collections import defaultdict

VAL = re.compile(r'%(?:"[^"]*"|[-\w.$]+)')
DEFINE = re.compile(r'^define [^@]*@("[^"]*"|[-\w.$]+)\((.*)\)')
CALL = re.compile(r'\b(musttail |tail |notail )?call\b')
ALLOC = re.compile(r'call (?:[^@]*? )?ptr @(mdk_alloc|mdk_alloc_atomic)\(i64 ([^)]*)\)')

TUPLE_TAG = 6950939912435
REF_TAG = 6382862214
RESERVED = {(0, 0): 'Cons', (1, 0): 'Some', (2, 0): 'Ok', (2, 1): 'Err'}

FOLLOW_OPS = {'getelementptr', 'ptrtoint', 'inttoptr', 'bitcast', 'phi', 'select',
              'freeze', 'add', 'sub', 'or', 'xor', 'insertvalue', 'extractvalue'}
STOP_OPS = {'load', 'icmp', 'switch', 'br', 'trunc', 'lshr', 'ashr', 'shl', 'mul',
            'sdiv', 'srem', 'udiv', 'urem', 'sitofp', 'uitofp', 'fptosi', 'zext',
            'sext', 'fcmp', 'indirectbr', 'unreachable'}

NOESC, RETURNED, ESC = 0, 1, 2


def split_top(s):
    out, depth, cur = [], 0, []
    for ch in s:
        if ch in '([{<':
            depth += 1
        elif ch in ')]}>':
            depth -= 1
        if ch == ',' and depth == 0:
            out.append(''.join(cur))
            cur = []
        else:
            cur.append(ch)
    if cur:
        out.append(''.join(cur))
    return out


def call_parts(rhs):
    """(callee, [arg strings], musttail) for a call rhs, or None."""
    m = CALL.search(rhs)
    if not m:
        return None
    rest = rhs[m.end():]
    # callee is the first @name or %name immediately followed by '('
    cm = re.search(r'(@(?:"[^"]*"|[-\w.$]+)|%(?:"[^"]*"|[-\w.$]+))\(', rest)
    if not cm:
        return None
    callee = cm.group(1)
    i = cm.end()
    depth, j = 1, i
    while j < len(rest) and depth:
        if rest[j] == '(':
            depth += 1
        elif rest[j] == ')':
            depth -= 1
        j += 1
    args = split_top(rest[i:j - 1])
    return callee, args, (m.group(1) or '').strip() == 'musttail'


class Func:
    __slots__ = ('name', 'params', 'lines', 'users', 'defs')

    def __init__(self, name, params):
        self.name, self.params, self.lines = name, params, []
        self.users = None
        self.defs = None

    def index(self):
        if self.users is not None:
            return
        self.users = defaultdict(list)
        self.defs = {}
        for k, ln in enumerate(self.lines):
            d = None
            if ln.startswith('%'):
                eq = ln.find(' = ')
                if eq > 0:
                    d = ln[:eq]
                    self.defs[d] = k
                    rhs = ln[eq + 3:]
                else:
                    rhs = ln
            else:
                rhs = ln
            for v in set(VAL.findall(rhs)):
                self.users[v].append(k)


toplevel = []      # every line outside a function body (globals, declares, metadata)


def parse(path):
    funcs, order = {}, []
    cur = None
    with open(path) as fh:
        for raw in fh:
            if cur is None:
                if not raw.startswith('define '):
                    toplevel.append(raw)
                if raw.startswith('define '):
                    m = DEFINE.match(raw)
                    name = m.group(1).strip('"')
                    params = []
                    for p in split_top(m.group(2)):
                        vs = VAL.findall(p)
                        params.append(vs[-1] if vs else None)
                    cur = Func(name, params)
                    funcs[name] = cur
                    order.append(name)
                continue
            if raw.startswith('}'):
                cur = None
                continue
            s = raw.strip()
            if s and not s.endswith(':') and not s.startswith(';'):
                cur.lines.append(s)
    return funcs, order


summ = {}          # (func, param index) -> NOESC/RETURNED/ESC
dependents = defaultdict(set)   # callee -> set of (func, param idx) whose summary read it


def track(f, seed, key=None):
    """Follow `seed` in f. Returns (flags set, musttail bool, unknown callees set)."""
    f.index()
    flags, unknown = set(), set()
    mt = False
    seen, work = {seed}, [seed]
    while work:
        v = work.pop()
        for k in f.users.get(v, ()):
            ln = f.lines[k]
            d, rhs = None, ln
            if ln.startswith('%'):
                eq = ln.find(' = ')
                if eq > 0:
                    d, rhs = ln[:eq], ln[eq + 3:]
            op = rhs.split(None, 1)[0]
            if op in ('tail', 'musttail', 'notail', 'call', 'invoke'):
                cp = call_parts(rhs)
                if cp is None:
                    flags.add('other:call')
                    continue
                callee, args, must = cp
                if callee.startswith('%'):
                    if any(v in VAL.findall(a) for a in args):
                        flags.add('indirect')
                    continue
                cname = callee[1:].strip('"')
                if cname.startswith('llvm.'):
                    continue
                for j, a in enumerate(args):
                    if v not in VAL.findall(a):
                        continue
                    if must:
                        mt = True
                    g = funcs.get(cname)
                    if g is None or j >= len(g.params):
                        flags.add('extern')
                        unknown.add(cname)
                        continue
                    if key is not None:
                        dependents[cname].add(key)
                    s = summ.get((cname, j), NOESC)
                    if s == ESC:
                        flags.add('callesc')
                        unknown.add(cname)
                    elif s == RETURNED and d is not None and d not in seen:
                        seen.add(d)
                        work.append(d)
                continue
            if op == 'store':
                ops = split_top(rhs[len('store '):])
                if v in VAL.findall(ops[0]):
                    flags.add('store')
                continue
            if op == 'ret':
                flags.add('ret')
                continue
            if op in ('cmpxchg', 'atomicrmw'):
                flags.add('store')
                continue
            if op == 'and':
                last = rhs.rsplit(',', 1)[-1].strip()
                if re.fullmatch(r'-?\d+', last) and 0 <= int(last) < 256:
                    continue
                op = 'or'
            if op in FOLLOW_OPS:
                if op == 'phi':
                    flags.add('phi')
                if d is not None and d not in seen:
                    seen.add(d)
                    work.append(d)
                continue
            if op in STOP_OPS:
                continue
            flags.add('other:' + op)
    return flags, mt, unknown


def classify_param(flags):
    if flags & {'store', 'extern', 'indirect', 'callesc'} or any(x.startswith('other:') for x in flags):
        return ESC
    if 'ret' in flags:
        return RETURNED
    return NOESC


def solve():
    work = [(fn, i) for fn in order for i, p in enumerate(funcs[fn].params) if p]
    inq = set(work)
    rounds = 0
    while work:
        rounds += 1
        key = work.pop()
        inq.discard(key)
        fn, i = key
        f = funcs[fn]
        flags, _, _ = track(f, f.params[i], key)
        new = classify_param(flags)
        if new > summ.get(key, NOESC):
            summ[key] = new
            for dep in dependents[fn]:
                if dep not in inq:
                    inq.add(dep)
                    work.append(dep)
    return rounds


def header_kind(f, k, ptr):
    """Constructor kind from the constant stored at offset 0 near the alloc."""
    hdr, f1 = None, None
    gep8 = None
    for ln in f.lines[k + 1:k + 12]:
        m = re.match(r'store i64 (-?\d+), ptr ' + re.escape(ptr) + r',', ln)
        if m and hdr is None:
            hdr = int(m.group(1))
        m = re.match(r'(%[-\w.$]+) = getelementptr i8, ptr ' + re.escape(ptr) + r', i64 8$', ln)
        if m:
            gep8 = m.group(1)
        if gep8 and re.match(r'store i64 ptrtoint \(ptr @\S+ to i64\), ptr ' + re.escape(gep8), ln):
            f1 = 'fnptr'
    if hdr is None:
        return 'dynamic-hdr'
    if hdr == TUPLE_TAG:
        return 'tuple'
    if hdr == REF_TAG:
        return 'ref'
    if hdr == -1:
        return 'pap'
    hi, lo = hdr >> 32, hdr & 0xffffffff
    if hi >= 65536:
        return RESERVED.get((hi - 65536, lo), 'reserved?')
    if hi == 0 and f1 == 'fnptr':
        return 'closure'
    if hi == 0:
        return 'small-hdr'
    return 'adt/record'


def main():
    global funcs, order
    src, out_ll, out_tsv = sys.argv[1:4]
    funcs, order = parse(src)
    print('functions:', len(order), file=sys.stderr)
    rounds = solve()
    nesc = sum(1 for v in summ.values() if v == ESC)
    print('summary rounds:', rounds, 'escaping params:', nesc, 'of',
          sum(1 for fn in order for p in funcs[fn].params if p), file=sys.stderr)

    # call sites of every defined function, and address-taken set
    callsites = defaultdict(list)
    addr_taken = set()
    for fn in order:
        f = funcs[fn]
        for k, ln in enumerate(f.lines):
            calls_here = set()
            cp = call_parts(ln) if 'call ' in ln else None
            if cp and cp[0].startswith('@'):
                cn = cp[0][1:].strip('"')
                calls_here.add(cn)
                if ln.startswith('%'):
                    callsites[cn].append((fn, ln[:ln.find(' = ')], cp[2]))
                else:
                    callsites[cn].append((fn, None, cp[2]))
            for g in re.findall(r'@("[^"]*"|[-\w.$]+)', ln):
                g = g.strip('"')
                if g in funcs and g not in calls_here:
                    addr_taken.add(g)
            # a function passed as an argument also counts
            if cp:
                for a in cp[1]:
                    for g in re.findall(r'@("[^"]*"|[-\w.$]+)', a):
                        if g.strip('"') in funcs:
                            addr_taken.add(g.strip('"'))

    # a function named anywhere outside a function body (a static closure
    # constant, a vtable) can be called indirectly
    for ln in toplevel:
        if ln.startswith('declare '):
            continue
        for g in re.findall(r'@("[^"]*"|[-\w.$]+)', ln):
            if g.strip('"') in funcs:
                addr_taken.add(g.strip('"'))

    ret_local_cache = {}

    def ret_local(fn):
        if fn in ret_local_cache:
            return ret_local_cache[fn]
        ok = fn not in addr_taken and bool(callsites[fn])
        if ok:
            for caller, res, must in callsites[fn]:
                if res is None or must:
                    ok = False
                    break
                fl, mt, _ = track(funcs[caller], res)
                if classify_param(fl) != NOESC or mt:
                    ok = False
                    break
        ret_local_cache[fn] = ok
        return ok

    sid = 0
    rows = []
    with open(src) as fh, open(out_ll, 'w') as out:
        cur = None
        k = -1
        for raw in fh:
            if raw.startswith('define '):
                cur = funcs[DEFINE.match(raw).group(1).strip('"')]
                k = -1
            elif raw.startswith('}'):
                cur = None
            elif cur is not None:
                s = raw.strip()
                if s and not s.endswith(':') and not s.startswith(';'):
                    k += 1
            m = ALLOC.search(raw) if cur is not None else None
            if m:
                ptr = raw.strip().split(' = ')[0]
                fl, mt, unk = track(cur, ptr)
                atomic = m.group(1) == 'mdk_alloc_atomic'
                size = m.group(2)
                if fl & {'store', 'extern', 'indirect', 'callesc'} or any(x.startswith('other:') for x in fl):
                    if 'store' in fl:
                        cls = 'STORE'
                    elif fl & {'extern', 'indirect'}:
                        cls = 'UNKNOWN_CALL'
                    elif 'callesc' in fl:
                        cls = 'CALLEE_ESC'
                    else:
                        cls = 'OTHER'
                elif 'ret' in fl:
                    cls = 'RET_LOCAL' if ret_local(cur.name) else 'RET'
                elif mt:
                    cls = 'MUSTTAIL'
                else:
                    cls = 'NOESC'
                kind = 'atomic' if atomic else header_kind(cur, k, ptr)
                rows.append((sid, cur.name, size, kind, cls, 'phi' if 'phi' in fl else '',
                             ','.join(sorted(unk))[:120]))
                fn_new = 'mdk_alloc_atomic_site' if atomic else 'mdk_alloc_site'
                raw = raw[:m.start()] + 'call ptr @%s(i64 %s, i64 %d)' % (fn_new, size, sid) + raw[m.end():]
                sid += 1
            out.write(raw)
        out.write('\ndeclare ptr @mdk_alloc_site(i64, i64)\ndeclare ptr @mdk_alloc_atomic_site(i64, i64)\n')
    with open(out_tsv, 'w') as t:
        t.write('id\tfunc\tsize\tkind\tclass\tphi\tescapes_to\n')
        for r in rows:
            t.write('\t'.join(str(x) for x in r) + '\n')
    print('sites:', sid, file=sys.stderr)


if __name__ == '__main__':
    main()
