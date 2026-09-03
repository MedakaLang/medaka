#!/usr/bin/env python3
"""Catch-all clause census over compiler/types/typecheck.mdk (#2551).

Enumerates every top-level multi-clause function whose clauses dispatch on an
`Expr` or `Decl` constructor at some parameter position while the FINAL clause
is a catch-all (`_` or a bare variable) at that position, and the constructors
named at that position do not cover the whole sum.  Such a clause silently
absorbs any constructor added to the sum later ([T-GLOBAL-TABLE]).

Not a lint rule: `medaka lint` has no type environment, so "the parameter is
`Expr`-typed" is not expressible there.  This script derives the constructor
sets from `compiler/frontend/ast.mdk` and the clause heads from the source
text; the gate around it (`test/diff_compiler_catch_all_census.sh`) compares
the site list against the committed ledger.

Output: one line per site, `<function>\t<sum>\t<named>/<total>`, sorted.  A
site that is exhaustive with a belt-and-braces `_` clause is not reported.
Exits 3 (MISSING) when it cannot find its subject — never reports an empty
list for a broken query.
"""
import re
import sys

ROOT = sys.argv[1] if len(sys.argv) > 1 else "."
AST = f"{ROOT}/compiler/frontend/ast.mdk"
SRC = f"{ROOT}/compiler/types/typecheck.mdk"
SUMS = ("Expr", "Decl")


def ctor_set(text, sum_name):
    m = re.search(r"^public export data %s =\n(.*?)(?=^\S)" % sum_name, text, re.S | re.M)
    if not m:
        return set()
    ctors = set()
    for line in m.group(1).split("\n"):
        mm = re.match(r"\s*\|\s*([A-Z][A-Za-z0-9_]*)", line)
        if mm:
            ctors.add(mm.group(1))
    return ctors


def split_top(s):
    """Split a clause's parameter text on top-level whitespace."""
    out, depth, cur = [], 0, ""
    for ch in s:
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        if ch.isspace() and depth == 0:
            if cur:
                out.append(cur)
            cur = ""
        else:
            cur += ch
    if cur:
        out.append(cur)
    return out


def split_tuple(s):
    """Top-level components of a parenthesized tuple pattern, or None."""
    if not (s.startswith("(") and s.endswith(")")):
        return None
    inner = s[1:-1]
    out, depth, cur = [], 0, ""
    for ch in inner:
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        if ch == "," and depth == 0:
            out.append(cur.strip())
            cur = ""
        else:
            cur += ch
    out.append(cur.strip())
    return out if len(out) > 1 else None


def head_of(pat):
    """The constructor head of a pattern (through `x@(...)` and parens), or
    "_" for a wildcard/variable, or None for anything else (literals, lists)."""
    p = pat.strip()
    if "@" in p and not p.startswith("("):
        p = p.split("@", 1)[1]
    while p.startswith("(") and p.endswith(")") and split_tuple(p) is None:
        p = p[1:-1].strip()
    if p == "_" or re.fullmatch(r"[a-z_][A-Za-z0-9_']*", p):
        return "_"
    m = re.match(r"([A-Z][A-Za-z0-9_]*)", p)
    return m.group(1) if m else None


def clause_positions(params):
    """Flatten parameters into positions: (index-path, head)."""
    positions = []
    for i, prm in enumerate(params):
        tup = split_tuple(prm)
        if tup:
            for j, comp in enumerate(tup):
                positions.append(((i, j), head_of(comp)))
        else:
            positions.append(((i,), head_of(prm)))
    return positions


def main():
    try:
        ast = open(AST).read()
        src = open(SRC).read()
    except OSError as e:
        print(f"MISSING: {e}", file=sys.stderr)
        return 3
    ctors = {s: ctor_set(ast, s) for s in SUMS}
    if any(len(c) < 2 for c in ctors.values()):
        print(f"MISSING: could not derive constructor sets from {AST}", file=sys.stderr)
        return 3
    ctor_owner = {}
    for s, cs in ctors.items():
        for c in cs:
            ctor_owner[c] = s

    # Top-level clause groups: consecutive lines `name <params> =` or `name <params>`
    # followed by guard lines, at column 0, same name.
    clause_re = re.compile(r"^([a-z_][A-Za-z0-9_']*)((?:\s+\S.*?)?)\s*(?:=(?!=)|$)")
    groups = {}
    order = []
    prev = None
    for line in src.split("\n"):
        if not line or line[0].isspace() or line.startswith("--"):
            continue
        m = clause_re.match(line)
        if not m or " : " in line.split("=")[0] and not m.group(2).strip().startswith("("):
            # a signature `name : T` — never a clause
            if re.match(r"^[a-z_][A-Za-z0-9_']*\s*:", line):
                prev = None
            continue
        if re.match(r"^[a-z_][A-Za-z0-9_']*\s*:", line):
            prev = None
            continue
        name = m.group(1)
        params = split_top(m.group(2).strip()) if m.group(2).strip() else []
        if name != prev:
            order.append((name, len(order)))
            groups.setdefault(name, []).append([])
        groups[name][-1].append(params)
        prev = name

    if not groups:
        print(f"MISSING: no clause groups found in {SRC}", file=sys.stderr)
        return 3

    sites = []
    for name, occurrences in groups.items():
        for clauses in occurrences:
            if len(clauses) < 2:
                continue
            per_pos = {}
            for ci, params in enumerate(clauses):
                for pos, head in clause_positions(params):
                    per_pos.setdefault(pos, []).append((ci, head))
            last = len(clauses) - 1
            for pos, heads in per_pos.items():
                named = {h for _, h in heads if h and h != "_"}
                owners = {ctor_owner[c] for c in named if c in ctor_owner}
                if len(owners) != 1:
                    continue
                (sum_name,) = owners
                total = ctors[sum_name]
                named_in = named & total
                if not named_in:
                    continue
                last_heads = [h for ci, h in heads if ci == last]
                if not last_heads or last_heads[-1] != "_":
                    continue
                if named_in == total:
                    continue  # exhaustive plus belt-and-braces
                sites.append((name, sum_name, len(named_in), len(total)))
                break  # one row per function

    if not sites:
        print("MISSING: query matched zero sites (expected dozens)", file=sys.stderr)
        return 3
    for name, sum_name, k, n in sorted(set(sites)):
        print(f"{name}\t{sum_name}\t{k}/{n}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
