import sys,re
sys.argv=[sys.argv[0], sys.argv[1], "none"]
exec(open(sys.argv[0].replace("d2.py","census.py")).read().split("if SEC in")[0])
a=set(INFO["eval.eval"]["names"]); b=INFO["ir.core_ir_eval"]["names"]
print(INFO["ir.core_ir_eval"]["lines"], b)
norm=lambda n: re.sub(r"^(c|core|ceval)","",n).lower()
al={n.lower():n for n in a}
print("near matches (strip c/core prefix, case-insensitive):",[ (x,al[norm(x)]) for x in b if norm(x) in al])
