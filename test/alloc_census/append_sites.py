#!/usr/bin/env python3
"""usage: append_sites.py <in.ll> <out.ll> <appsites.tsv>

Helper of test/retain_census.sh.  Rewrites every `call i64 @mdk_list_append(a, b)`
and `call i64 @mdk_append(a, b)` in the IR, including those carrying a calling
convention or return attributes (`call noundef i64 @mdk_list_append(...)`, which
clang -O2 emits), into a site-numbered `@mdk_list_append_site(a, b, ID)` /
`@mdk_append_site(a, b, ID)`, keeping those tokens, so the cons
cells a `++` builds are attributed to the function that called it rather than to
the runtime.  Writes `id<TAB>function<TAB>callee` per site.  Arguments are matched
with balanced parentheses: a constant-expression operand carries its own commas.
"""
import re
import sys

DEFINE = re.compile(r'^define [^@]*@("[^"]*"|[-\w.$]+)\(')
# tokens between `call` and the return type: calling convention, return attributes
CALLEE = re.compile(r'(?<![%\w.$-])call((?: [^\s@(),]+)*?) i64 @(mdk_list_append|mdk_append)\(')


def rewrite(raw, func, rows):
    out, pos = [], 0
    while True:
        m = CALLEE.search(raw, pos)
        if not m:
            out.append(raw[pos:])
            return ''.join(out)
        i, depth = m.end(), 1
        while depth:
            if raw[i] == '(':
                depth += 1
            elif raw[i] == ')':
                depth -= 1
            i += 1
        sid = len(rows)
        rows.append((sid, func, m.group(2)))
        out.append(raw[pos:m.start()])
        out.append('call%s i64 @%s_site(%s, i64 %d)'
                   % (m.group(1), m.group(2), raw[m.end():i - 1], sid))
        pos = i


def main():
    src, dst, tsv = sys.argv[1:4]
    rows = []
    func = None
    with open(src) as f, open(dst, 'w') as o:
        for raw in f:
            m = DEFINE.match(raw)
            if m:
                func = m.group(1).strip('"')
            elif raw.startswith('}'):
                func = None
            if func is not None and 'append(' in raw:
                raw = rewrite(raw, func, rows)
            o.write(raw)
        o.write('\ndeclare i64 @mdk_list_append_site(i64, i64, i64)\n'
                'declare i64 @mdk_append_site(i64, i64, i64)\n')
    with open(tsv, 'w') as t:
        for r in rows:
            t.write('%d\t%s\t%s\n' % r)
    print('append sites:', len(rows), file=sys.stderr)


if __name__ == '__main__':
    main()
