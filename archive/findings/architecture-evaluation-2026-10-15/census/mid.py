import sys,subprocess
R=sys.argv[1]
def g(*a): return subprocess.run(["git","-C",R]+list(a),capture_output=True,text=True)
for d in ["2026-06-10","2026-06-20"]:
    s=g("rev-list","-1","--before="+d,"origin/main").stdout.strip()
    fs=[x for x in g("ls-tree","-r","--name-only",s,"selfhost/").stdout.split("\n") if x]
    tc=[x for x in fs if x.endswith(("typecheck.mdk","llvm_emit.mdk","wasm_emit.mdk","resolve.mdk","lint.mdk"))]
    print(d,s[:9],len([x for x in fs if x.endswith(".mdk")]),"selfhost .mdk files")
    for p in tc:
        print("  ",p,g("show",f"{s}:{p}").stdout.count("\n"))
