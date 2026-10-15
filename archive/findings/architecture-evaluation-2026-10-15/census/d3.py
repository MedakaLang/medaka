import sys,re,collections
sys.argv=[sys.argv[0], sys.argv[1], "none"]
exec(open(sys.argv[0].replace("d3.py","census.py")).read().split("if SEC in")[0])
owners=collections.defaultdict(set)
for m in INFO:
    if m.startswith("entries."): continue
    for n in INFO[m]["names"]: owners[n].add(m)
dup={n:ms for n,ms in owners.items() if len(ms)>=2}
two=sorted((n,ms) for n,ms in dup.items() if len(ms)==2)
print("2-module names:", "; ".join(f"`{n}` ({'/'.join(sorted(x.split('.')[1] for x in ms))})" for n,ms in two))
cross=sum(1 for n,ms in dup.items() if len(set(x.split('.')[0] for x in ms))>1)
print("dup names spanning 2+ directories:",cross)
pairs=collections.Counter()
for n,ms in dup.items():
    ms=sorted(ms)
    for i in range(len(ms)):
        for j in range(i+1,len(ms)): pairs[(ms[i],ms[j])]+=1
print("top module pairs sharing names:",pairs.most_common(12))
print("test/prop blocks inside non-test modules:",sum(INFO[m]["tests"] for m in INFO), {m:INFO[m]["tests"] for m in INFO if INFO[m]["tests"]})
