#!/usr/bin/env python3
"""Rewrite each call to mdk_string_append / mdk_append / mdk_list_append in an
-O2 .ll into a counted wrapper carrying a site id; write the site table.
usage: appends.py in.ll out.ll sites.tsv"""
import re
import sys

src, out_ll, out_tsv = sys.argv[1:4]
CALL = re.compile(r'call i64 @(mdk_string_append|mdk_append|mdk_list_append)\(')
DEFINE = re.compile(r'^define [^@]*@("[^"]*"|[-\w.$]+)\(')
rows, sid, cur = [], 0, None
with open(src) as fh, open(out_ll, 'w') as out:
    for raw in fh:
        if raw.startswith('define '):
            cur = DEFINE.match(raw).group(1).strip('"')
        m = CALL.search(raw)
        if m and raw.startswith('  '):
            rows.append((sid, m.group(1), cur))
            raw = raw[:m.start()] + 'call i64 @cnt_%s(i64 %d, ' % (m.group(1), sid) + raw[m.end():]
            sid += 1
        out.write(raw)
    for f in ('mdk_string_append', 'mdk_append', 'mdk_list_append'):
        out.write('declare i64 @cnt_%s(i64, i64, i64)\n' % f)
with open(out_tsv, 'w') as t:
    for r in rows:
        t.write('%d\t%s\t%s\n' % r)
print('append sites', sid)
