import sys
sys.argv=[sys.argv[0], sys.argv[1], "none"]
exec(open(sys.argv[0].replace("appendix.py","census.py")).read().split("if SEC in")[0])
out, inn, std, unknown = graph()
print("| module | lines | out-deg | in-deg | top-level names (+data) | exported | exp. fraction | Ref cells |")
print("|---|---|---|---|---|---|---|---|")
for m in sorted(INFO):
    if m.startswith("entries."):
        continue
    i = INFO[m]
    n = len(i["names"]) + len(i["datas"])
    e = len([x for x in i["exports"] if x[0] != "import"])
    print(f"| {m} | {i['lines']} | {len(out[m])} | {len(inn[m])} | {n} | {e} | {e/max(n,1):.2f} | {len(i['refs'])} |")
