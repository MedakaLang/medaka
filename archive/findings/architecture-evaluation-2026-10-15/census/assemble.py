import re, os
S = os.path.dirname(os.path.abspath(__file__))
rd = lambda f: open(os.path.join(S, f), encoding="utf-8").read().rstrip("\n")
C = rd("C.out")
c1b_start = C.index("### C1b")
c2_start = C.index("### C2")
cmain = C[:c1b_start] + C[c2_start:]
cmain = cmain.replace("### C2", "### C2").replace("### C1 ", "### C1 ")
D = rd("D.out")
d1 = D[D.index("### D1"):D.index("### D2")].replace("### D1 llvm_emit vs wasm_emit\n\n", "")
d4 = D[D.index("### D4"):].split("\n", 2)[2]
ident = rd("ident.out").split("\n")[1]
two = rd("d3.out").split("\n")[0].replace("2-module names: ", "")
G = rd("G.out")
gtop = G[:G.index("#### per-module")].rstrip()
vals = {
    "A.out": rd("A.out"), "arch.out": rd("arch.out"), "B.out": rd("B.out"), "C.main": cmain,
    "D1.out": d1.strip(), "ident.out": ident, "D3big.out": rd("D3big.out"), "D3two.out": two,
    "D4.out": d4.strip(), "E.out": rd("E.out").rsplit("\n", 1)[0], "F.out": rd("F.out"),
    "G.top": gtop, "I.out": rd("I.out"), "appendix.out": rd("appendix.out"),
}
t = rd("template.md")
for k, v in vals.items():
    t = t.replace("@@" + k + "@@", v)
assert "@@" not in t, re.findall(r"@@[^@]+@@", t)
t = t.replace("—", "-").replace("–", "-")
open(os.path.join(S, "census-medaka.md"), "w", encoding="utf-8").write(t + "\n")
print(len(t.split("\n")), "lines")
