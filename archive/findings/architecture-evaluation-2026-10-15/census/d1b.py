import sys,re
sys.argv=[sys.argv[0], sys.argv[1], "none"]
exec(open(sys.argv[0].replace("d1b.py","census.py")).read().split("if SEC in")[0])
ll=set(INFO["backend.llvm_emit"]["names"]); ww=set(INFO["backend.wasm_emit"]["names"])
for suf in ["Ref","Wasm","W"]:
    t=sorted(n for n in ll if n+suf in ww)
    print(suf, len(t), t[:40])
t=sorted(n for n in ll if "wasm"+n[0].upper()+n[1:] in ww); print("wasm-prefix",len(t),t)
# other backend modules sharing names with either
for m in INFO:
    if m.startswith("backend.") and m not in ("backend.llvm_emit","backend.wasm_emit"):
        s=set(INFO[m]["names"]); x=sorted(s&(ll|ww))
        if x: print(m, len(x), x[:10])
