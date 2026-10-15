import sys,os,re,subprocess,collections
R=sys.argv[1]
ents=sorted(f[:-4] for f in os.listdir(R+"/compiler/entries") if f.endswith(".mdk") and not f.endswith("_test.mdk"))
entt=[f for f in os.listdir(R+"/compiler/entries") if f.endswith("_test.mdk")]
print("entries non-test:",len(ents),"entries _test:",len(entt))
g=open(R+"/test/gates.toml").read()
print("gates.toml [[gate]] rows:",len(re.findall(r"^\[\[gate\]\]",g,re.M)),"[[shard]]:",len(re.findall(r"^\[\[shard\]\]",g,re.M)))
mig=collections.Counter(re.findall(r'^migration\s*=\s*"([^"]+)"',g,re.M)); print("migration values:",dict(mig))
sh=[f for f in os.listdir(R+"/test") if f.endswith(".sh")]
print("test/*.sh (top level):",len(sh))
allsh=sum(1 for dp,_,fs in os.walk(R+"/test") for f in fs if f.endswith(".sh")); print("test/**/*.sh:",allsh)
tm=[os.path.join(dp,f) for dp,_,fs in os.walk(R+"/test") for f in fs if f.endswith("_test.mdk")]
print("test/**/*_test.mdk:",len(tm))
ctm=[os.path.join(dp,f) for dp,_,fs in os.walk(R+"/compiler") for f in fs if f.endswith("_test.mdk")]
print("compiler/**/*_test.mdk:",len(ctm))
# corpus
texts={}
for top in ["test","scripts",".github"]:
    for dp,_,fs in os.walk(os.path.join(R,top)):
        for f in fs:
            p=os.path.join(dp,f)
            try:
                if os.path.getsize(p)<3_000_000: texts[p]=open(p,errors="ignore").read()
            except: pass
for f in ["Makefile"]:
    texts[R+"/"+f]=open(R+"/"+f).read()
# also compiler/medaka.toml and compiler non-entries sources (e.g. build_oracles lists)
extra={}
for dp,_,fs in os.walk(R+"/compiler"):
    for f in fs:
        if f.endswith((".mdk",".toml")) and "entries" not in dp:
            extra[os.path.join(dp,f)]=open(os.path.join(dp,f),errors="ignore").read()
un=[]; unx=[]
for e in ents:
    pat=re.compile(r"\b"+re.escape(e)+r"\b")
    hit=[p for p,t in texts.items() if pat.search(t)]
    if not hit:
        un.append(e)
        hitx=[p for p,t in extra.items() if pat.search(t)]
        hite=[f for f in os.listdir(R+"/compiler/entries") if f!=e+".mdk" and pat.search(open(R+"/compiler/entries/"+f).read())]
        unx.append((e,[os.path.relpath(p,R) for p in hitx][:3],hite[:3]))
print("entries referenced by nothing in test/ scripts/ .github/ Makefile:",len(un))
for x in unx: print(" ",x)
