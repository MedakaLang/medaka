import sys,subprocess
R=sys.argv[1]
def g(*a): return subprocess.run(["git","-C",R]+list(a),capture_output=True,text=True)
dates=["2026-06-01","2026-07-01","2026-08-01","2026-09-01","2026-10-01"]
paths=["compiler/types/typecheck.mdk","compiler/backend/llvm_emit.mdk","compiler/backend/wasm_emit.mdk","compiler/frontend/resolve.mdk","compiler/tools/lint.mdk"]
shas=[(d,g("rev-list","-1","--before="+d,"origin/main").stdout.strip()) for d in dates]
shas.append(("HEAD (origin/main)",g("rev-parse","origin/main").stdout.strip()))
shas.append(("worktree HEAD",g("rev-parse","HEAD").stdout.strip()))
print("| date | sha | "+" | ".join(p.split("/")[-1] for p in paths)+" | compiler/*.md docs | non-test compiler .mdk files | non-test compiler .mdk lines |")
print("|---"*(len(paths)+5)+"|")
for d,s in shas:
    row=[]
    for p in paths:
        r=g("show",f"{s}:{p}")
        row.append(str(r.stdout.count("\n")) if r.returncode==0 else "absent")
    top=g("ls-tree","--name-only",s,"compiler/").stdout.split("\n")
    nd=sum(1 for x in top if x.endswith(".md"))
    allf=[x for x in g("ls-tree","-r","--name-only",s,"compiler/").stdout.split("\n") if x.endswith(".mdk") and not x.endswith("_test.mdk")]
    # line count via cat-file batch
    inp="\n".join(f"{s}:{x}" for x in allf)+"\n"
    out=subprocess.run(["git","-C",R,"cat-file","--batch"],input=inp.encode(),capture_output=True).stdout
    # parse batch output
    tot=0;i=0
    while i<len(out):
        nl=out.index(b"\n",i); hdr=out[i:nl].split()
        if len(hdr)<3: i=nl+1; continue
        size=int(hdr[2]); body=out[nl+1:nl+1+size]; tot+=body.count(b"\n"); i=nl+1+size+1
    print(f"| {d} | {s[:9]} | "+" | ".join(row)+f" | {nd} | {len(allf)} | {tot} |")
