import sys,re,os
R=sys.argv[1]; C=R+"/compiler"
L=open(C+"/types/typecheck.mdk").read().split("\n")
for d in ["PerRun","CrossRun","GraphRun","DriverState"]:
    s=next(i for i,l in enumerate(L) if re.match(r"^(public export |export )?data "+d+r"\b",l))
    e=next(i for i in range(s+1,len(L)) if L[i] and L[i][0] not in " \t-}")
    body=[l for l in L[s:e] if not re.match(r"^\s*--",l)]
    f=[l for l in body if re.match(r"^\s+,?\s*[a-zA-Z0-9_]+\s*:",l)]
    r=[l for l in f if re.search(r":\s*Ref\b",l)]
    print(d, f"lines {s+1}-{e}", "fields",len(f),"Ref fields",len(r))
ft={}
for dp,_,fs in os.walk(C):
    for fn in fs:
        if fn.endswith(".mdk") and not fn.endswith("_test.mdk"):
            names=set(re.findall(r"^([a-z][A-Za-z0-9_]*ForTest)\b",open(os.path.join(dp,fn)).read(),re.M))
            if names: ft[os.path.relpath(os.path.join(dp,fn),C)]=len(names)
print("ForTest-suffixed top-level names in non-test modules:",sum(ft.values()),ft)
