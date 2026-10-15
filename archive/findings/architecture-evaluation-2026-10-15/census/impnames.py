import sys, re, collections
sys.argv=[sys.argv[0], sys.argv[1], "none"]
exec(open(sys.argv[0].replace("impnames.py","census.py")).read().split("if SEC in")[0])
# collect selective-import name lists per (importer, target)
uses = collections.defaultdict(lambda: collections.defaultdict(set))
for m, p in modules(include_tests=False):
    txt = open(p).read()
    for mm in re.finditer(r"^(?:export\s+)?import\s+([A-Za-z_][\w.]*?)\.\{([^}]*)\}", txt, re.M):
        tgt = mm.group(1)
        for nm in [x.strip().split()[0] for x in re.sub(r"--[^\n]*", "", mm.group(2)).split(",") if x.strip()]:
            nm = nm.replace("(..)", "").strip()
            if nm: uses[tgt][nm].add(m)
missing = collections.Counter(); tot = collections.Counter()
for tgt in uses:
    if tgt not in INFO: continue
    ex = set(e[1] for e in INFO[tgt]["exports"])
    for nm in uses[tgt]:
        tot[tgt]+=1
        if nm not in ex: missing[tgt]+=1
print("targets with imported-but-not-detected-exported names:", sum(missing.values()), "of", sum(tot.values()))
for t,n in missing.most_common(8): print(t, n, tot[t], [x for x in uses[t] if x not in set(e[1] for e in INFO[t]["exports"])][:6])
# most-imported individual names
fan = [(len(ms), t, nm) for t in uses if t in INFO for nm, ms in uses[t].items()]
print("top names by importer count:")
for n,t,nm in sorted(fan, reverse=True)[:15]: print(n, t, nm)
# import style counts
sty=collections.Counter()
for m,p in modules():
    for l in open(p):
        if re.match(r"^(export\s+)?import\s",l):
            if ".{" in l: sty["selective .{}"]+=1
            elif re.search(r"\.\*", l): sty["wildcard .*"]+=1
            elif " as " in l: sty["qualified as"]+=1
            else: sty["bare"]+=1
print(dict(sty))
# exports never imported (by non-test modules, and by any module incl. tests)
usesT = collections.defaultdict(set)
for m, p in modules(include_tests=True):
    txt = open(p).read()
    for mm in re.finditer(r"^(?:export\s+)?import\s+([A-Za-z_][\w.]*?)\.\{([^}]*)\}", txt, re.M):
        for nm in [x.strip().split()[0] for x in re.sub(r"--[^\n]*", "", mm.group(2)).split(",") if x.strip()]:
            usesT[mm.group(1)].add(nm.replace("(..)",""))
tot_ex=0; dead=0; deadT=0; rows=[]
for m in INFO:
    if m.startswith("entries."): continue
    ex = set(e[1] for e in INFO[m]["exports"] if e[0]!="import")
    d = [x for x in ex if x not in uses[m]]
    dT = [x for x in ex if x not in usesT[m]]
    tot_ex+=len(ex); dead+=len(d); deadT+=len(dT)
    rows.append((len(dT), len(d), len(ex), m))
print(f"non-entries exports {tot_ex}; not selectively imported by any non-test module: {dead}; by no module incl tests: {deadT}")
for r in sorted(rows, reverse=True)[:10]: print(r)
