import os,re,sys,subprocess,collections
R=sys.argv[1]
groups=["compiler","docs/design","docs/spec"]
TAGS=["SUPERSEDED","HISTORICAL","PROPOSAL","DRAFT","CURRENT","IMPLEMENTED","PARTIAL","LIVE"]
# all tracked files for reference search
files=subprocess.run(["git","-C",R,"ls-files"],capture_output=True,text=True).stdout.split("\n")
files=[f for f in files if f]
texts={}
for f in files:
    p=os.path.join(R,f)
    try:
        if os.path.getsize(p)>5_000_000: continue
        with open(p,encoding="utf-8",errors="ignore") as fh: texts[f]=fh.read()
    except Exception: pass
tagcount=collections.Counter(); tot={}
for g in groups:
    d=os.path.join(R,g)
    if not os.path.isdir(d): print("missing",g); continue
    mds=sorted(x for x in os.listdir(d) if x.endswith(".md"))
    print(f"\n#### {g}/*.md ({len(mds)} files)\n")
    print("| file | lines | status line (first 110 chars) | tags | refs (all) | refs excl. docs/README.md index | refs from non-.md files |")
    print("|---|---|---|---|---|---|---|")
    total=0; unref=0
    gt=collections.Counter(); low=[]
    for f in mds:
        p=os.path.join(d,f); L=open(p,encoding="utf-8").read().split("\n")
        n=len(L)-1 if L and L[-1]=="" else len(L); total+=n
        st=next((l for l in L if re.match(r"^\s*(\*\*Status:?\*\*|Status:|\*\*Status\*\*|>\s*\*\*Status)",l)),"")
        tags=[t for t in TAGS if re.search(r"\b"+t+r"\b",st,re.I)]
        for t in tags: gt[t]+=1
        rel=f"{g}/{f}"
        hit=[k for k,v in texts.items() if k!=rel and f in v]
        refs=len(hit)
        refs2=len([k for k in hit if k not in ("docs/README.md","docs/stdlib/index.md")])
        refs3=len([k for k in hit if not k.endswith(".md")])
        if refs2==0: unref+=1
        if refs2<=1: low.append(f)
        print(f"| {f} | {n} | {st.strip()[:110].replace('|','/')} | {','.join(tags)} | {refs} | {refs2} | {refs3} |")
    print(f"\n{g}: {len(mds)} docs, {total} lines; status line present in {sum(1 for f in mds if True)} checked; docs referenced by no file other than the generated index: {unref}; referenced by at most one such file: {len(low)} ({', '.join(low)}). Tag counts (status line only): {dict(gt)}")
    tot[g]=(len(mds),total,unref,dict(gt))
print(tot)
