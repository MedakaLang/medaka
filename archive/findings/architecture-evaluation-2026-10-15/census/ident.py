import sys,re,collections
sys.argv=[sys.argv[0], sys.argv[1], "none"]
exec(open(sys.argv[0].replace("ident.py","census.py")).read().split("if SEC in")[0])
def bodies(m):
    L=read(PATH[m]); out=collections.defaultdict(list)
    for n,s,e,_,_ in extents(m):
        txt="\n".join(l for l in L[s-1:e] if not re.match(r"^\s*--",l))
        out[n].append(re.sub(r"\s+"," ",txt).strip())
    return {n:"\n".join(v) for n,v in out.items()}
B={m:bodies(m) for m in INFO if not m.startswith("entries.")}
owners=collections.defaultdict(set)
for m in B:
    for n in B[m]:
        if not n.startswith(("<","data ","type ")): owners[n].add(m)
dup={n:ms for n,ms in owners.items() if len(ms)>=2}
ident=[];
for n,ms in dup.items():
    vals=collections.Counter(B[m][n] for m in ms)
    if vals.most_common(1)[0][1]>=2:
        ident.append((n,sorted(m for m in ms if B[m][n]==vals.most_common(1)[0][0])))
print("dup names:",len(dup),"with >=2 textually identical definitions (whitespace/comment-normalized):",len(ident))
print("; ".join(f"`{n}` ({'/'.join(x.split('.')[1] for x in ms)})" for n,ms in sorted(ident)))
lw=[n for n in dup if {"backend.llvm_emit","backend.wasm_emit"}<=dup[n]]
print("llvm/wasm same-name identical:",sum(1 for n in lw if B["backend.llvm_emit"][n]==B["backend.wasm_emit"][n]),"of",len(lw))
