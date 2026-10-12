#!/usr/bin/env python3
"""Append call counts by kind and by caller.
usage: append_report.py append_sites.tsv append.counts"""
import sys
from collections import defaultdict

sites = {int(l.split('\t')[0]): l.rstrip('\n').split('\t')[1:] for l in open(sys.argv[1])}
byfn, bykind = defaultdict(int), defaultdict(int)
for l in open(sys.argv[2]):
    i, c = map(int, l.split())
    k, f = sites[i]
    byfn[(k, f)] += c
    bykind[k] += c
print('== append calls by runtime entry point (from emitted code; runtime-internal calls not counted)')
for k in sorted(bykind, key=lambda k: -bykind[k]):
    print(f'  {bykind[k]/1e6:8.2f}M {k}')
print('\n== append calls by caller (top 25)')
for (k, f) in sorted(byfn, key=lambda x: -byfn[x])[:25]:
    print(f'  {byfn[(k, f)]/1e6:7.2f}M {k:18s} {f[:90]}')
