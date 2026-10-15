#!/usr/bin/env python3
# Read-only structural census of compiler/**/*.mdk. Usage: python3 -I census.py <repo-root> <section>
import os, re, sys, json, statistics, collections

ROOT = sys.argv[1]
SEC = sys.argv[2] if len(sys.argv) > 2 else "all"
COMP = os.path.join(ROOT, "compiler")

KEYWORDS = {"import", "data", "type", "interface", "impl", "export", "public", "test", "prop"}
IDENT = re.compile(r"^([a-z_][A-Za-z0-9_']*)")
OPDEF = re.compile(r"^\(([^)\s]+)\)")
IMPORT_RE = re.compile(r"^(?:export\s+)?import\s+([A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*)")
REF_RE = re.compile(r"^([a-z][A-Za-z0-9_']*)\s*=\s*(Ref|newRef)\b")
DATA_RE = re.compile(r"^(?:public\s+export\s+|export\s+)?data\s+([A-Z]\w*)")
TYPE_RE = re.compile(r"^(?:export\s+)?type\s+([A-Z]\w*)")


def modules(include_tests=False):
    out = []
    for d, _, fs in os.walk(COMP):
        for f in fs:
            if not f.endswith(".mdk"):
                continue
            if f.endswith("_test.mdk") and not include_tests:
                continue
            p = os.path.join(d, f)
            rel = os.path.relpath(p, COMP)
            out.append((rel[:-4].replace("/", "."), p))
    return sorted(out)


def read(p):
    with open(p, encoding="utf-8") as fh:
        return fh.read().split("\n")[:-1] if True else None


def analyze(path):
    L = read(path)
    info = {"lines": len(L)}
    info["comment"] = sum(1 for l in L if re.match(r"^\s*--", l))
    info["blank"] = sum(1 for l in L if l.strip() == "")
    info["code"] = info["lines"] - info["comment"] - info["blank"]
    names = []          # (lineno, name) column-0 definitional lines
    decl_lines = 0
    exports = []
    datas = []
    imports = []
    refs = []
    tests = 0
    pending_export = False
    for i, l in enumerate(L):
        if not l or l[0] in " \t" or l.startswith("--"):
            continue
        m = IMPORT_RE.match(l)
        if m:
            imports.append(m.group(1))
            if l.startswith("export"):
                exports.append(("import", m.group(1)))
            continue
        m = DATA_RE.match(l)
        if m:
            datas.append(m.group(1))
            if "export" in l.split("data")[0]:
                exports.append(("data", m.group(1)))
            continue
        m = TYPE_RE.match(l)
        if m:
            if l.startswith("export"):
                exports.append(("type", m.group(1)))
            continue
        if l.strip() == "export":
            pending_export = True
            continue
        w = l.split()[0]
        if w in ("else", "then", "in"):
            continue
        if w in ("test", "prop"):
            tests += 1
            continue
        if w in KEYWORDS:
            continue
        m = IDENT.match(l) or OPDEF.match(l)
        if m:
            nm = m.group(1)
            decl_lines += 1
            names.append((i + 1, nm))
            if pending_export:
                exports.append(("value", nm))
                pending_export = False
            mr = REF_RE.match(l)
            if mr:
                refs.append(mr.group(1))
    info["decl_lines"] = decl_lines
    info["names"] = sorted(set(n for _, n in names))
    info["name_lines"] = names
    info["exports"] = exports
    info["datas"] = datas
    info["imports"] = imports
    info["refs"] = refs
    info["tests"] = tests
    return info


def pct(xs, q):
    xs = sorted(xs)
    k = (len(xs) - 1) * q
    f = int(k)
    c = min(f + 1, len(xs) - 1)
    return xs[f] + (xs[c] - xs[f]) * (k - f)


MODS = modules()
INFO = {m: analyze(p) for m, p in MODS}
PATH = dict(MODS)


def secA():
    sizes = [INFO[m]["lines"] for m, _ in MODS]
    print("### A1 size distribution (non-test compiler/**/*.mdk)\n")
    print("| files | total lines | median | p90 | max |")
    print("|---|---|---|---|---|")
    print(f"| {len(sizes)} | {sum(sizes)} | {statistics.median(sizes):.0f} | {pct(sizes,0.9):.0f} | {max(sizes)} |")
    print()
    for d in sorted(set(m.split(".")[0] for m, _ in MODS)):
        s = [INFO[m]["lines"] for m, _ in MODS if m.split(".")[0] == d]
        print(f"- {d}: {len(s)} files, {sum(s)} lines, median {statistics.median(s):.0f}, max {max(s)}")
    print("\n### A2 files over 2,000 lines\n")
    print("| module | lines | comment | code | blank | top-level names | col-0 decl lines | data | imports | exported | Ref cells |")
    print("|---|---|---|---|---|---|---|---|---|---|---|")
    big = sorted([m for m, _ in MODS if INFO[m]["lines"] > 2000], key=lambda m: -INFO[m]["lines"])
    for m in big:
        i = INFO[m]
        print(f"| {m} | {i['lines']} | {i['comment']} | {i['code']} | {i['blank']} | {len(i['names'])} | {i['decl_lines']} | {len(i['datas'])} | {len(i['imports'])} | {len(i['exports'])} | {len(i['refs'])} |")
    print(f"\n{len(big)} files over 2,000 lines hold {sum(INFO[m]['lines'] for m in big)} of {sum(sizes)} lines.")
    tot_c = sum(INFO[m]["comment"] for m, _ in MODS)
    print(f"Comment lines across all non-test modules: {tot_c} ({100*tot_c/sum(sizes):.1f}% of lines).")
    allrefs = [(m, r) for m, _ in MODS for r in INFO[m]["refs"]]
    print(f"\nModule-level Ref cells (col-0 `name = Ref ...`/`newRef`), all non-test modules: {len(allrefs)} in {len(set(m for m,_ in allrefs))} modules.")
    c = collections.Counter(m for m, _ in allrefs)
    print("Top: " + ", ".join(f"{m} {n}" for m, n in c.most_common(12)))


def extents(m):
    """Declaration extents: column-0 starts; merge consecutive same name; trim trailing blank/comment."""
    L = read(PATH[m])
    starts = []
    for i, l in enumerate(L):
        if not l or l[0] in " \t" or l.startswith("--"):
            continue
        if l.strip() in ("}", "]", ")") or l[0] in "}])|,":
            continue
        w = l.split()[0]
        if l.strip() == "export":
            continue
        mm = DATA_RE.match(l)
        if mm:
            starts.append((i, "data " + mm.group(1)))
            continue
        mm = TYPE_RE.match(l)
        if mm:
            starts.append((i, "type " + mm.group(1)))
            continue
        if IMPORT_RE.match(l):
            starts.append((i, "<import>"))
            continue
        if w in ("else", "then", "in"):
            continue
        if w in ("test", "prop"):
            starts.append((i, "<" + w + ">"))
            continue
        if w in KEYWORDS:
            starts.append((i, w + " " + (l.split()[1] if len(l.split()) > 1 else "")))
            continue
        mm = IDENT.match(l) or OPDEF.match(l)
        if mm:
            starts.append((i, mm.group(1)))
    merged = []
    for idx, (i, n) in enumerate(starts):
        if merged and merged[-1][1] == n and n not in ("<import>", "<test>", "<prop>"):
            continue
        merged.append([i, n])
    res = []
    for k, (i, n) in enumerate(merged):
        end = merged[k + 1][0] if k + 1 < len(merged) else len(L)
        j = end - 1
        while j > i and (L[j].strip() == "" or re.match(r"^\s*--", L[j])):
            j -= 1
        cm = sum(1 for x in L[i:j+1] if re.match(r"^\s*--", x))
        res.append((n, i + 1, j + 1, j - i + 1, cm))
    return res


def secB():
    for m in ["types.typecheck", "backend.llvm_emit", "backend.wasm_emit", "frontend.resolve", "eval.eval"]:
        ex = [e for e in extents(m) if not e[0].startswith("<")]
        spans = [e[3] for e in ex]
        print(f"\n#### {m}.mdk ({INFO[m]['lines']} lines, {len(ex)} merged declarations)\n")
        print(f"median {statistics.median(spans):.0f} lines, p90 {pct(spans,0.9):.0f}; >100: {sum(s>100 for s in spans)}; >200: {sum(s>200 for s in spans)}; >500: {sum(s>500 for s in spans)}; lines in decls >200: {sum(s for s in spans if s>200)}\n")
        print("| rank | declaration | start-end | lines | of which comment |")
        print("|---|---|---|---|---|")
        for r, e in enumerate(sorted(ex, key=lambda e: -e[3])[:15], 1):
            print(f"| {r} | `{e[0]}` | {e[1]}-{e[2]} | {e[3]} | {e[4]} |")


LAYER = {"support": 0, "frontend": 1, "types": 2, "ir": 3, "backend": 4}
TOP = {"driver", "tools", "entries"}


def stdlib_mods():
    s = set()
    for d, _, fs in os.walk(os.path.join(ROOT, "stdlib")):
        for f in fs:
            if f.endswith(".mdk") and not f.endswith("_test.mdk"):
                rel = os.path.relpath(os.path.join(d, f), os.path.join(ROOT, "stdlib"))
                s.add(rel[:-4].replace("/", "."))
    return s


def graph():
    mods = set(INFO)
    out = {m: set() for m in mods}
    inn = collections.defaultdict(set)
    std = collections.defaultdict(set)
    unknown = collections.defaultdict(set)
    SM = stdlib_mods()
    for m in mods:
        for imp in INFO[m]["imports"]:
            if imp in mods:
                out[m].add(imp)
                inn[imp].add(m)
            elif imp in SM:
                std[imp].add(m)
            else:
                # maybe a module whose test-sibling exists only, or partial path
                unknown[imp].add(m)
    return out, inn, std, unknown


def violation(src, dst):
    a, b = src.split(".")[0], dst.split(".")[0]
    if a in TOP:
        return None
    if b in TOP:
        return f"{a} -> {b} (non-top imports top)"
    if a == "eval":
        if b in ("ir", "backend"):
            return f"eval -> {b} (eval should depend on frontend/types only)"
        return None
    if b == "eval":
        return f"{a} -> eval (eval sits outside the support<frontend<types<ir<backend chain)"
    if a in LAYER and b in LAYER and LAYER[b] > LAYER[a]:
        return f"{a} -> {b} (upward)"
    return None


def secC():
    out, inn, std, unknown = graph()
    mods = sorted(INFO)
    print("### C1 degree summary\n")
    outs = [len(out[m]) for m in mods]
    ins = [len(inn[m]) for m in mods]
    print(f"{len(mods)} modules, {sum(outs)} intra-compiler import edges (distinct module pairs). Out-degree median {statistics.median(outs):.0f}, max {max(outs)}; in-degree median {statistics.median(ins):.0f}, max {max(ins)}. Modules with in-degree 0: {sum(1 for x in ins if x==0)} (of which entries: {sum(1 for m in mods if not inn[m] and m.startswith('entries.'))}).\n")
    print("Hubs (top 20 by in-degree):\n")
    print("| module | in-degree | out-degree | lines |")
    print("|---|---|---|---|")
    for m in sorted(mods, key=lambda m: -len(inn[m]))[:20]:
        print(f"| {m} | {len(inn[m])} | {len(out[m])} | {INFO[m]['lines']} |")
    print("\nHighest out-degree (top 12):\n")
    print("| module | out-degree | in-degree |")
    print("|---|---|---|")
    for m in sorted(mods, key=lambda m: -len(out[m]))[:12]:
        print(f"| {m} | {len(out[m])} | {len(inn[m])} |")
    print("\n### C1b full per-module degree table (non-entries)\n")
    print("| module | out | in |")
    print("|---|---|---|")
    for m in mods:
        if m.startswith("entries."):
            continue
        print(f"| {m} | {len(out[m])} | {len(inn[m])} |")
    ent = [m for m in mods if m.startswith("entries.")]
    print(f"\nentries/* ({len(ent)} modules): out-degree total {sum(len(out[m]) for m in ent)}, in-degree total {sum(len(inn[m]) for m in ent)}.")
    print("\n### C2 directory-level edge matrix (row imports column; count of module edges)\n")
    dirs = ["support", "frontend", "types", "ir", "backend", "eval", "driver", "tools", "entries"]
    M = collections.Counter()
    for a in mods:
        for b in out[a]:
            M[(a.split(".")[0], b.split(".")[0])] += 1
    print("| from \\ to | " + " | ".join(dirs) + " |")
    print("|---" * (len(dirs) + 1) + "|")
    for a in dirs:
        print(f"| {a} | " + " | ".join(str(M[(a, b)] or ".") for b in dirs) + " |")
    print("\n### C3 layering violations (every edge)\n")
    viol = []
    for a in mods:
        for b in sorted(out[a]):
            v = violation(a, b)
            if v:
                viol.append((v.split(" (")[0], a, b, v))
    byk = collections.Counter(v[3] for v in viol)
    print(f"{len(viol)} violating edges.\n")
    for k, n in byk.most_common():
        print(f"- {k}: {n}")
    print("\n| from | to | kind |")
    print("|---|---|---|")
    for _, a, b, v in sorted(viol):
        print(f"| {a} | {b} | {v} |")
    print("\n### C4 stdlib modules imported by the compiler\n")
    print("| stdlib module | # compiler modules importing (non-test) |")
    print("|---|---|")
    for s, ms in sorted(std.items(), key=lambda kv: -len(kv[1])):
        print(f"| {s} | {len(ms)} |")
    if unknown:
        print("\nImports resolving to neither a compiler module nor a stdlib module:")
        for u, ms in sorted(unknown.items()):
            print(f"- `{u}` from {', '.join(sorted(ms))}")
    print("\n### C5 types/* vs typecheck\n")
    tc = "types.typecheck"
    tmods = [m for m in mods if m.startswith("types.") and m != tc]
    imp_by_tc = sorted(m for m in out[tc] if m.startswith("types."))
    imp_tc = sorted(m for m in inn[tc] if m.startswith("types."))
    print(f"typecheck.mdk imports {len(out[tc])} compiler modules ({len(imp_by_tc)} in types/), and is imported by {len(inn[tc])} modules ({len(imp_tc)} in types/).\n")
    print("| types/ module | lines | imported BY typecheck | IMPORTS typecheck | imports other types/* |")
    print("|---|---|---|---|---|")
    for m in tmods:
        oth = sorted(x.split(".")[1] for x in out[m] if x.startswith("types.") and x != tc)
        print(f"| {m.split('.')[1]} | {INFO[m]['lines']} | {'yes' if m in out[tc] else ''} | {'YES' if tc in out[m] else ''} | {', '.join(oth)} |")
    print("\nImporters of types.typecheck (all dirs): " + ", ".join(sorted(inn[tc])))
    # cycles: strongly connected components
    idx = {}
    low = {}
    st = []
    on = set()
    sccs = []
    c = [0]
    sys.setrecursionlimit(10000)

    def sc(v):
        idx[v] = low[v] = c[0]; c[0] += 1; st.append(v); on.add(v)
        for w in out[v]:
            if w not in idx:
                sc(w); low[v] = min(low[v], low[w])
            elif w in on:
                low[v] = min(low[v], idx[w])
        if low[v] == idx[v]:
            comp = []
            while True:
                w = st.pop(); on.discard(w); comp.append(w)
                if w == v:
                    break
            if len(comp) > 1:
                sccs.append(comp)
    for v in mods:
        if v not in idx:
            sc(v)
    print(f"\nImport cycles (SCCs of size >1): {len(sccs)}" + "".join(f"\n- {sorted(s)}" for s in sccs))
    # longest path depth
    memo = {}
    def depth(v):
        if v in memo:
            return memo[v]
        memo[v] = 0
        memo[v] = 1 + max([depth(w) for w in out[v]] or [0])
        return memo[v]
    d = max(mods, key=depth)
    print(f"\nLongest import chain length (modules): {depth(d)} (from {d}).")


def secD():
    ll = set(INFO["backend.llvm_emit"]["names"])
    ww = set(INFO["backend.wasm_emit"]["names"])
    both = sorted(ll & ww)
    wtwin = sorted(n for n in ll if (n + "W") in ww and n not in ww)
    print(f"### D1 llvm_emit vs wasm_emit\n\nllvm_emit top-level names: {len(ll)}; wasm_emit: {len(ww)}.\nSame name in both: {len(both)}. llvm name with a `W`-suffixed twin in wasm: {len(wtwin)}.\n")
    print("Same-name (first 40): " + ", ".join(f"`{n}`" for n in both[:40]))
    print("\nW-twins (first 40): " + ", ".join(f"`{n}`/`{n}W`" for n in wtwin[:40]))
    # also other backend modules that share names
    a = set(INFO["eval.eval"]["names"]); b = set(INFO["ir.core_ir_eval"]["names"]) if "ir.core_ir_eval" in INFO else set()
    sh = sorted(a & b)
    print(f"\n### D2 eval/eval.mdk vs ir/core_ir_eval.mdk\n\neval: {len(a)} names, core_ir_eval: {len(b)} names, shared: {len(sh)}.\n\n" + ", ".join(f"`{n}`" for n in sh))
    owners = collections.defaultdict(set)
    for m in INFO:
        if m.startswith("entries."):
            continue
        for n in INFO[m]["names"]:
            owners[n].add(m)
    dup = {n: ms for n, ms in owners.items() if len(ms) >= 2}
    print(f"\n### D3 same top-level name defined in 2+ modules (non-test, non-entries)\n\n{len(dup)} names are defined in 2 or more modules ({sum(len(v) for v in dup.values())} definitions). Distribution by module count: " +
          ", ".join(f"{k} modules: {v}" for k, v in sorted(collections.Counter(len(v) for v in dup.values()).items())))
    print("\n| name | # modules | modules |")
    print("|---|---|---|")
    for n, ms in sorted(dup.items(), key=lambda kv: (-len(kv[1]), kv[0])):
        print(f"| `{n}` | {len(ms)} | {', '.join(sorted(ms))} |")
    print("\n### D4 lookupAssoc call sites per module\n")
    defs = [m for m in INFO if "lookupAssoc" in INFO[m]["names"]]
    rows = []
    for m in INFO:
        L = read(PATH[m])
        n = 0
        for l in L:
            if re.match(r"^\s*--", l):
                continue
            if re.match(r"^lookupAssoc\b", l):
                continue
            n += len(re.findall(r"\blookupAssoc\b", l.split("--")[0]))
        if n:
            rows.append((n, m))
    print(f"Defined in: {', '.join(defs)}. Total call sites (non-comment, excluding definition lines): {sum(r[0] for r in rows)} in {len(rows)} modules.\n")
    print("| module | call sites |")
    print("|---|---|")
    for n, m in sorted(rows, reverse=True):
        print(f"| {m} | {n} |")


def secF():
    def counts(paths):
        c = collections.Counter(); issues = set()
        for p in paths:
            for l in read(p):
                com = re.match(r"^\s*--", l)
                if com and re.search(r"#[0-9]{2,5}\b", l):
                    c["issue_comment_lines"] += 1
                if com:
                    issues |= set(re.findall(r"#([0-9]{2,5})\b", l))
                if re.search(r"[─━═]{3,}", l):
                    c["banners"] += 1
                if com and re.search(r"20[0-9][0-9]-[0-9][0-9]", l):
                    c["dated"] += 1
                for w in ["legacy", "compat", "compatibility", "deprecated", "retired", "historical", "TODO", "FIXME", "HACK"]:
                    flags = 0 if w.isupper() else re.I
                    if re.search(r"\b" + w + (r"\b" if w != "compat" else r"(?!ib)"), l, flags):
                        c["w_" + w] += 1
                if re.search(r"\b(legacy|compat|compatibility|deprecated|retired|historical)\b|\bTODO\b|\bFIXME\b|\bHACK\b", l, re.I):
                    c["any_word"] += 1
                if com:
                    c["comment"] += 1
                c["lines"] += 1
        return c, issues
    tc, tci = counts([PATH["types.typecheck"]])
    ot, oti = counts([PATH[m] for m in INFO if m != "types.typecheck"])
    keys = ["lines", "comment", "issue_comment_lines", "banners", "dated", "any_word", "w_legacy", "w_compat", "w_compatibility", "w_deprecated", "w_retired", "w_historical", "w_TODO", "w_FIXME", "w_HACK"]
    print("| measure | typecheck.mdk | all other non-test modules |")
    print("|---|---|---|")
    for k in keys:
        print(f"| {k} | {tc[k]} | {ot[k]} |")
    print(f"| distinct issue numbers in comments | {len(tci)} | {len(oti)} |")
    print(f"| issue-ref comment lines per 1k lines | {1000*tc['issue_comment_lines']/tc['lines']:.1f} | {1000*ot['issue_comment_lines']/ot['lines']:.1f} |")


def secG():
    out, inn, std, unknown = graph()
    rows = []
    for m in INFO:
        i = INFO[m]
        nnames = len(i["names"]) + len(i["datas"])
        nexp = len([e for e in i["exports"] if e[0] != "import"])
        rows.append((m, nnames, nexp))
    tot = sum(r[2] for r in rows); totn = sum(r[1] for r in rows)
    print(f"Total exported names (values + types + data, non-test): {tot} of {totn} top-level names+data ({100*tot/totn:.1f}%).\n")
    nonent = [r for r in rows if not r[0].startswith("entries.")]
    print(f"Excluding entries/: {sum(r[2] for r in nonent)} exported of {sum(r[1] for r in nonent)}.\n")
    print("Top 10 by exported count:\n")
    print("| module | top-level names (+data) | exported | fraction | importers |")
    print("|---|---|---|---|---|")
    for m, n, e in sorted(rows, key=lambda r: -r[2])[:10]:
        print(f"| {m} | {n} | {e} | {e/max(n,1):.2f} | {len(inn[m])} |")
    fr = [e / n for m, n, e in rows if n >= 10]
    print(f"\nExported fraction over modules with >=10 names: median {statistics.median(fr):.2f}; modules with fraction >= 0.9: {sum(f>=0.9 for f in fr)} of {len(fr)}; with fraction <= 0.2: {sum(f<=0.2 for f in fr)}.")
    print("\nModules whose exports are imported by the most other modules (= in-degree):")
    for m in sorted(INFO, key=lambda m: -len(inn[m]))[:5]:
        print(f"- {m}: {len(inn[m])} importers, {len([e for e in INFO[m]['exports'] if e[0]!='import'])} exports")
    # per-name fan-in: count importers by selective import lists is complex; approximate by name mention in import lines
    print("\n#### per-module exported fraction (all non-entries modules)\n")
    print("| module | names(+data) | exported | fraction |")
    print("|---|---|---|---|")
    for m, n, e in sorted(nonent):
        print(f"| {m} | {n} | {e} | {e/max(n,1):.2f} |")


if SEC in ("A", "all"): secA()
if SEC in ("B", "all"): secB()
if SEC in ("C", "all"): secC()
if SEC in ("D", "all"): secD()
if SEC in ("F", "all"): secF()
if SEC in ("G", "all"): secG()
