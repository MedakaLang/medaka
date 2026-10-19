#!/usr/bin/env python3
"""Diff-level benchmark: review.py's funnel over the commits that introduced the
labelled fixtures, plus clean commits, scored by line and declaration.

A MEASUREMENT, NOT A GATE. It calls external models, exits 0 unless misused,
and must never be enrolled in test/gates.toml.

Steps (README.md "Diff-level benchmark"):
  map     blame each positive, control and judgment fixture at its sha; the commit
          that introduced most of its lines is its introducing commit C, kept when
          C wrote at least half the excerpt; the range is mapped to C's line numbers
  plan    per split: each labelled commit's units (review.py's cutting), the units
          overlapping a kept item plus a fixed-seed sample of other units, and a
          fixed-seed sample of clean commits with a sample of their units
  run     review.py's funnel (review_units) over the plan, one arm at a time
  audit   Opus judges a fixed-seed sample of an arm's unlabelled findings
  report  recall, FPR, unlabelled findings per unit and per changed line, cost

Arms: `baseline` (review.py's default), `g2` (scope_strict), `g2-exempt`
(scope_strict_exempt), `g1` (evidence.py TWIN_NOTES), `fixed` (g1 and g2). The
scope arms ask nothing a `baseline` or `g1` run has not cached, since a
stricter scope only confirms fewer classes. `onedecl` (review.py --one-decl)
cuts each planned unit into its one-declaration pieces; a unit of one
declaration is its own piece and is served from the baseline's cache. Arms are
compared on parent units: the planned (merged) unit a piece belongs to.
Results: RESULTS-diffs-dev-2026-10-18.md, RESULTS-diffs-onedecl-dev-2026-10-18.md.

Run from anywhere: python3 -I scripts/review_bench/diffbench.py <step> --split dev
"""
from __future__ import annotations

import argparse
import contextlib
import hashlib
import json
import random
import re
import subprocess
import sys
from collections import Counter, defaultdict
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import battery as BT  # noqa: E402
import engines as E  # noqa: E402
import evidence as EV  # noqa: E402
import items as I  # noqa: E402
import review as RV  # noqa: E402

ROOT = EV.ROOT
DB = E.CACHE / "diffbench"
SEED = 20261018
MAIN = "261b94a2d9a2baa6a97464d0be85bf3ecc19269b"  # origin/main when the clean sample was drawn
EMPTY_TREE = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
MIN_SHARE = 0.5  # the introducing commit wrote at least this share of the excerpt's lines
SLACK = 2  # a finding's line may fall this far outside a mapped range
OTHER_UNITS = 3  # sampled per labelled commit, beyond the units holding a kept item
CLEAN_UNITS = 8  # sampled per clean commit
CLEAN_COMMITS = 30  # per split
# The commits whose live reviews exposed the two gaps the fixed arm addresses.
EXPOSED = ("3f3e63a12", "e5a3d0380")
# arm: (twin notes, scope, merge adjacent declarations)
ARMS = {"baseline": (False, "diff", True), "g2": (False, "strict", True),
        "g2-exempt": (False, "strict-exempt", True), "g1": (True, "diff", True), "fixed": (True, "strict", True),
        "onedecl": (False, "diff", False)}
# $6.00 for the first pass (g1, g2), $2.00 for the onedecl pass, then $7.00 for the
# one test-split pass (baseline and its audit) over the $7.8951 those two spent.
BUDGET_USD = 14.8951
# Measured on dev (RESULTS-diffs-dev-2026-10-18.md): a diff unit is larger than a
# fixture excerpt, so it costs more than review.USD_PER_UNIT.
USD_PER_UNIT = 0.0057  # baseline arm, battery then confirm
# A one-declaration piece of a merged unit, battery then confirm: the mean over the
# dev onedecl run's 430 such pieces (RESULTS-diffs-onedecl-dev-2026-10-18.md).
USD_PER_PIECE = 0.0039
AUDIT_USD = 0.045  # per Opus audit call
SCORED = ("positive", "control")


def git(*args: str) -> str | None:
    r = subprocess.run(["git", "-C", str(ROOT), *args], capture_output=True, text=True, errors="replace")
    return r.stdout if r.returncode == 0 else None


def _h(s: str) -> str:
    return hashlib.sha256(s.encode()).hexdigest()


def _range(s: str) -> tuple[int, int]:
    a, b = s.split("-")
    return int(a), int(b)


def _load(name: str, default):
    f = DB / name
    return json.loads(f.read_text()) if f.exists() else default


def _save(name: str, obj) -> None:
    E.ensure_cache(DB.name)
    tmp = DB / (name + ".tmp")
    tmp.write_text(json.dumps(obj, indent=1))
    tmp.replace(DB / name)


# ---------------------------------------------------------------------------
# 1. Introducing commits
# ---------------------------------------------------------------------------
HEADER = re.compile(r"^([0-9a-f]{40}) (\d+) (\d+)(?: \d+)?$")


def blame(sha: str, path: str, lo: int, hi: int) -> list[tuple[str, int, str]] | None:
    """(commit, line in that commit, path in that commit) per line lo..hi at sha."""
    out = git("blame", "--line-porcelain", "-w", "-L", f"{lo},{hi}", sha, "--", path)
    if out is None:
        return None
    rows, cur = [], None
    for ln in out.split("\n"):
        m = HEADER.match(ln)
        if m:
            cur = [m.group(1), int(m.group(2)), path]
        elif ln.startswith("filename ") and cur:
            cur[2] = ln[len("filename "):]
        elif ln.startswith("\t") and cur:
            rows.append(tuple(cur))
            cur = None
    return rows


def map_item(it: dict) -> dict:
    rec = {"id": it["_key"], "split": it["_split"], "class": it["class"], "polarity": it["polarity"],
           "file": it["file"], "sha": it["sha"], "lines": it["lines"], "anchor": it.get("anchor", ""),
           "evidence_scope": it.get("evidence_scope") or "?", "also_present": it.get("also_present") or [],
           "group": it["_group"], "kept": False}
    if not it["file"].endswith(".mdk"):
        return rec | {"why": "not .mdk: review.py reads Medaka only"}
    lo, hi = _range(it["lines"])
    rows = blame(it["sha"], it["file"], lo, hi)
    if not rows:
        return rec | {"why": "blame failed"}
    by = Counter(r[0] for r in rows)
    c, n = by.most_common(1)[0]
    mine = [r for r in rows if r[0] == c]
    cfile = Counter(r[2] for r in mine).most_common(1)[0][0]
    ls = [r[1] for r in mine if r[2] == cfile]
    rec |= {"commit": c, "commit_file": cfile, "lo": min(ls), "hi": max(ls), "share": round(n / len(rows), 3),
            "n_lines": len(rows)}
    if n / len(rows) < MIN_SHARE:
        return rec | {"why": "introducing commit wrote under half the excerpt"}
    why = RV.skip_reason(cfile)
    if why:
        return rec | {"why": f"file skipped by review.py at the introducing commit ({why})"}
    return rec | {"kept": True, "why": ""}


def item_map(fx: list[dict]) -> dict[str, dict]:
    """Every positive, control and judgment fixture's mapping, cached by its pin."""
    cache = _load("map.json", {})
    out, todo = {}, []
    for it in fx:
        k = _h(json.dumps([it["_key"], it["sha"], it["file"], it["lines"], it["_split"], MIN_SHARE]))
        if k in cache:
            out[it["_key"]] = cache[k]
        else:
            todo.append((k, it))
    if todo:
        from concurrent.futures import ThreadPoolExecutor
        with ThreadPoolExecutor(max_workers=4) as pool:
            for (k, it), rec in zip(todo, pool.map(lambda t: map_item(t[1]), todo)):
                cache[k] = out[it["_key"]] = rec
        _save("map.json", cache)
    return out


def cmd_map(a) -> int:
    fx = I.load(None)
    m = item_map(fx)
    lines = ["| split | class | kept | dropped: under half | dropped: other |", "|---|---|---:|---:|---:|"]
    for split in ("dev", "test"):
        rows = [r for r in m.values() if r["split"] == split and r["polarity"] in SCORED]
        for cls in sorted({r["class"] for r in rows}):
            rs = [r for r in rows if r["class"] == cls]
            lines.append(f"| {split} | `{cls}` | {sum(r['kept'] for r in rs)} | "
                         f"{sum(r['why'].startswith('introducing') for r in rs)} | "
                         f"{sum(not r['kept'] and not r['why'].startswith('introducing') for r in rs)} |")
    print("\n".join(lines))
    for split in ("dev", "test"):
        rows = [r for r in m.values() if r["split"] == split and r["polarity"] in SCORED]
        kept = [r for r in rows if r["kept"]]
        print(f"\n{split}: {len(kept)} of {len(rows)} positive/control items kept "
              f"({sum(r['polarity'] == 'positive' for r in kept)} positives, "
              f"{sum(r['polarity'] == 'control' for r in kept)} controls) over "
              f"{len({r['commit'] for r in kept})} introducing commits; dropped: "
              + ", ".join(f"{w} {n}" for w, n in Counter(r["why"] for r in rows if not r["kept"]).most_common()))
    return 0


# ---------------------------------------------------------------------------
# 2-3. The plan: commits and units
# ---------------------------------------------------------------------------
def parent(c: str) -> str:
    p = git("rev-parse", "--verify", "-q", c + "^1")
    return p.strip() if p else EMPTY_TREE


def commit_specs(c: str) -> tuple[list[tuple], dict]:
    """review.py's units of commit c, before evidence, and the commit's totals."""
    p = parent(c)
    with contextlib.redirect_stdout(sys.stderr):
        files, skipped, other = RV.changed_files(p, c)
        specs, _notes = RV.unit_specs(p, c, files, True)
    return specs, {"parent": p, "units": len(specs), "changed": sum(len(s[5]) for s in specs),
                   "files": len(files), "skipped": len(skipped), "other_files": other}


def overlaps(spec: tuple, path: str, lo: int, hi: int) -> bool:
    return spec[0] == path and spec[1] <= hi and spec[2] >= lo


def split_of_sha(c: str) -> str:
    return "dev" if int(_h("clean|" + c)[:8], 16) % 2 == 0 else "test"


def clean_candidates(kept_commits: set[str]) -> list[str]:
    """Non-merge commits on MAIN touching .mdk files, dated within the labelled commits'
    span, minus the labelled commits, seed refreshes and the gap-exposing reviews."""
    dates = [int(git("show", "-s", "--format=%ct", c).strip()) for c in sorted(kept_commits)]
    lo, hi = min(dates), max(dates)
    out = []
    log = git("log", "--no-merges", f"--since={lo}", f"--until={hi}", "--format=%H\t%s", MAIN, "--", "*.mdk") or ""
    for ln in log.splitlines():
        c, _, subj = ln.partition("\t")
        if c in kept_commits or any(c.startswith(x) for x in EXPOSED):
            continue
        if re.search(r"\bseed\b", subj, re.I):
            continue
        out.append(c)
    return sorted(out)


def build_plan(fx: list[dict]) -> dict:
    """{commit: {kind, split(s), totals, units: [spec + role]}}; cached, deterministic."""
    plan = _load("plan.json", None)
    if plan is not None:
        return plan
    m = item_map(fx)
    by_commit: dict[str, list[dict]] = defaultdict(list)
    for r in m.values():
        if r.get("commit"):
            by_commit[r["commit"]].append(r)
    kept_commits = {r["commit"] for r in m.values() if r["kept"] and r["polarity"] in SCORED}
    plan = {"main": MAIN, "seed": SEED, "commits": {}}
    for c in sorted(kept_commits):
        specs, tot = commit_specs(c)
        recs = [r for r in by_commit[c] if r["kept"]]
        units, other = [], []
        for s in specs:
            hold = [r for r in recs if r["polarity"] in SCORED and overlaps(s, r["commit_file"], r["lo"], r["hi"])]
            near = [r for r in recs if overlaps(s, r["commit_file"], r["lo"], r["hi"])]
            if hold:
                units.append(list(s) + ["item", sorted({r["split"] for r in hold})])
            elif not near:
                other.append(list(s) + ["other", []])
        rng = random.Random(f"{SEED}:{c}")
        units += sorted(rng.sample(other, min(OTHER_UNITS, len(other))), key=lambda s: (s[0], s[1]))
        splits = Counter(r["split"] for r in recs if r["polarity"] in SCORED)
        plan["commits"][c] = {"kind": "labelled", "splits": dict(splits), "noise_split": splits.most_common(1)[0][0],
                              "items": sorted(r["id"] for r in by_commit[c]), "totals": tot, "units": units,
                              "other_pool": len(other)}
    cands = clean_candidates(kept_commits)
    random.Random(SEED).shuffle(cands)
    taken = Counter()
    for c in cands:
        sp = split_of_sha(c)
        if taken[sp] >= CLEAN_COMMITS:
            if all(taken[s] >= CLEAN_COMMITS for s in ("dev", "test")):
                break
            continue
        specs, tot = commit_specs(c)
        if not specs:
            continue
        rng = random.Random(f"{SEED}:{c}")
        units = sorted(rng.sample([list(s) + ["clean", []] for s in specs], min(CLEAN_UNITS, len(specs))),
                       key=lambda s: (s[0], s[1]))
        plan["commits"][c] = {"kind": "clean", "splits": {sp: 0}, "noise_split": sp, "items": [], "totals": tot,
                              "units": units}
        taken[sp] += 1
    plan["clean_candidates"] = len(cands)
    _save("plan.json", plan)
    return plan


def plan_units(plan: dict, split: str) -> list[tuple[str, list]]:
    """(commit, spec) of every planned unit a split reviews: the units holding one of
    its items, and the other and clean units of the commits whose noise counts in it."""
    out = []
    for c, pc in sorted(plan["commits"].items()):
        for s in pc["units"]:
            if s[6] == "item" and split in s[7] or s[6] != "item" and pc["noise_split"] == split:
                out.append((c, s))
    return out


def cmd_plan(a) -> int:
    fx = I.load(None)
    plan = build_plan(fx)
    for split in ("dev", "test"):
        lab = [pc for pc in plan["commits"].values() if pc["kind"] == "labelled"
               and (split in pc["splits"] or pc["noise_split"] == split)]
        clean = [pc for pc in plan["commits"].values() if pc["kind"] == "clean" and pc["noise_split"] == split]
        mixed = sum(len(pc["splits"]) > 1 for pc in lab)
        roles = Counter(s[6] for _c, s in plan_units(plan, split))
        print(f"{split}: {len(lab)} labelled commits ({mixed} mixed-split), {len(clean)} clean commits; units "
              f"reviewed: {dict(roles)}; units in those commits: labelled "
              f"{sum(pc['totals']['units'] for pc in lab)}, clean {sum(pc['totals']['units'] for pc in clean)}")
    print(f"clean candidates in the window: {plan['clean_candidates']}")
    return 0


# ---------------------------------------------------------------------------
# Running an arm
# ---------------------------------------------------------------------------
def unit_key(c: str, path: str, lo: int, hi: int) -> str:
    """review.make_unit's key, known before evidence is generated."""
    return "L" + BT._h(f"{c}|{path}|{lo}-{hi}")[:12]


def piece_rows(plan: dict, split: str, parents: set[str] | None = None) -> list[tuple[str, list, str]]:
    """(commit, spec + role + splits, parent key) for the one-declaration pieces of a
    split's planned units, in plan order: review.cut_units(merge=False) over the same
    commit and file, each piece inside the planned unit it belongs to, which lends it
    its role. A planned unit of one declaration is its own piece."""
    by_c: dict[str, list] = defaultdict(list)
    for c, s in plan_units(plan, split):
        if parents is None or unit_key(c, *s[:3]) in parents:
            by_c[c].append(s)
    out = []
    for c, specs in sorted(by_c.items()):
        files = list(dict.fromkeys(s[0] for s in specs))
        with contextlib.redirect_stdout(sys.stderr):
            pieces, _notes = RV.unit_specs(plan["commits"][c]["totals"]["parent"], c, files, False)
        for s in specs:
            pk = unit_key(c, *s[:3])
            out += [(c, list(q) + s[6:8], pk) for q in pieces if q[0] == s[0] and s[1] <= q[1] and q[2] <= s[2]]
    return out


def make_units(plan: dict, split: str, fx: list[dict], twin_notes: bool, jobs: int, merge: bool = True,
               parents: set[str] | None = None) -> list[dict]:
    """The split's units with evidence: the planned units, or with `merge` off their
    one-declaration pieces (of `parents` only, when given). Each records its parent."""
    EV.TWIN_NOTES = twin_notes
    keyed = {it["_key"]: it for it in fx}
    out = []
    rows = [(c, s, None) for c, s in plan_units(plan, split)] if merge else piece_rows(plan, split, parents)
    by_c: dict[str, list] = defaultdict(list)
    for c, s, pk in rows:
        by_c[c].append((s, pk))
    for c, specs in sorted(by_c.items()):
        us = RV.units_from_specs(c, [tuple(s[:6]) for s, _pk in specs], jobs)
        items = [keyed[k] for k in plan["commits"][c]["items"] if k in keyed]
        for u, (s, pk) in zip(us, specs):
            # Few-shot examples never come from a fixture this commit introduced.
            u["item_keys"] = sorted(it["_key"] for it in items)
            u["groups"] = sorted({it["_group"] for it in items})
            u["commit"], u["role"], u["parent"] = c, s[6], pk or u["_key"]
            out.append(u)
    return out


def parent_of(u: dict) -> str:
    return u.get("parent", u["_key"])


def spent() -> float:
    return sum(x["new_usd"] for x in _load("ledger.json", []))


def log_spend(what: str, usd: float) -> None:
    led = _load("ledger.json", [])
    led.append({"what": what, "new_usd": round(usd, 6)})
    _save("ledger.json", led)


def unit_record(u: dict) -> dict:
    return {k: u[k] for k in ("_key", "commit", "role", "file", "lo", "hi", "anchor", "changed", "parent")}


def compared_parents(split: str, of: str) -> set[str]:
    """The units `of`'s run reviewed that every other arm's run kept as comparable:
    the evidence-nondeterministic units the merged arms leave out stay out."""
    run = _load(f"run-{split}-{of}.json", None)
    if run is None:
        sys.exit(f"no run for {split}/{of}")
    keep = {u["_key"] for u in run["units"]}
    for arm in ARMS:
        other = _load(f"run-{split}-{arm}.json", None)
        if other is not None and ARMS[arm][2] and other.get("comparable") is not None:
            keep &= set(other["comparable"])
    return keep


def cmd_run(a) -> int:
    fx = I.load(None)
    plan = build_plan(fx)
    rub, _known, fx, classes = RV.setup()
    twin, scope_name, merge = ARMS[a.arm]
    if not merge:
        return run_pieces(a, plan, fx, rub, classes, scope_name)
    units = make_units(plan, a.split, fx, twin, a.jobs)
    if a.units_of:
        # Arms are compared on the same units: those another arm's run reviewed.
        prev = _load(f"run-{a.split}-{a.units_of}.json", None)
        if prev is None:
            sys.exit(f"no run for {a.split}/{a.units_of}")
        keep = {u["_key"] for u in prev["units"]}
        units = [u for u in units if u["_key"] in keep]
    # A unit is comparable with the baseline arm when its evidence without twin notes is
    # what the baseline asked with: some generators depend on the process's string-hash
    # order, and a cache entry written by another evidence.py version is not reused.
    # Every other arm runs on the comparable units only.
    comparable = None
    if a.arm != "baseline":
        plain = make_units(plan, a.split, fx, False, a.jobs) if twin else units
        keys = {u["_key"] for u in units}
        comparable = {u["_key"] for u in plain if u["_key"] in keys and E._cache_get(
            RV.BATTERY_KIND, BT.battery_request(u, rub, classes, True)[0]) is not None}
        if twin:
            units = make_units(plan, a.split, fx, True, a.jobs)
        units = [u for u in units if u["_key"] in comparable]
        print(f"{a.split}/{a.arm}: {len(keys) - len(comparable)} of {len(keys)} units left out: their "
              f"evidence without twin notes differs from the baseline run's", file=sys.stderr)
        comparable = sorted(comparable)
    if a.dry_run:
        fresh = sum(E._cache_get(RV.BATTERY_KIND, BT.battery_request(u, rub, classes, True)[0]) is None
                    for u in units)
        print(f"{a.split}/{a.arm}: {len(units)} units, {fresh} without a cached battery answer; "
              f"estimate ${fresh * USD_PER_UNIT:.2f} at ${USD_PER_UNIT}/unit "
              f"(a stricter scope confirms fewer classes, so `g2`/`fixed` cost at most this); "
              f"spent so far ${spent():.4f} of ${BUDGET_USD:.2f}")
        return 0
    left = min(a.max_usd, BUDGET_USD - spent())
    if left <= 0:
        sys.exit(f"diffbench: budget ${BUDGET_USD:.2f} spent")
    res = RV.review_units(units, rub, fx, classes, jobs=a.jobs, timeout=a.timeout, max_usd=left,
                          scope_fn=RV.SCOPES[scope_name])
    log_spend(f"run {a.split} {a.arm}", res["spend"])
    _save(f"run-{a.split}-{a.arm}.json", {
        "units": [unit_record(u) for u in res["reviewed"]], "unreviewed": len(res["unreviewed"]),
        "per_unit": res["per_unit"], "spend": res["spend"], "errors": res["errors"],
        "comparable": comparable})
    print(f"{a.split}/{a.arm}: {len(res['reviewed'])} units reviewed, {len(res['unreviewed'])} not (budget), "
          f"{len(res['findings'])} findings, new spend ${res['spend']:.4f}, {res['errors']} errors; "
          f"total spent ${spent():.4f}", file=sys.stderr)
    return 0


def run_pieces(a, plan: dict, fx: list[dict], rub: dict, classes: list[str], scope_name: str) -> int:
    """An arm without merging: the pieces of the units `--units-of` (default baseline)
    compared, so both arms cover the same commits, files and changed lines."""
    of = a.units_of or "baseline"
    parents = compared_parents(a.split, of)
    prev = {u["_key"]: u for u in _load(f"run-{a.split}-{of}.json", {"units": []})["units"]}
    if a.roles:
        parents = {k for k in parents if prev[k]["role"] in a.roles}
    units = make_units(plan, a.split, fx, False, a.jobs, merge=False, parents=parents)
    pieces = Counter(u["parent"] for u in units)
    # A unit of one declaration is its own piece: its prompt must be the one `of` asked.
    own = [u for u in units if u["_key"] == u["parent"]]
    fresh = {u["_key"] for u in units
             if E._cache_get(RV.BATTERY_KIND, BT.battery_request(u, rub, classes, True)[0]) is None}
    differ = {u["_key"] for u in own if u["_key"] in fresh}
    units = [u for u in units if u["parent"] not in differ]
    lost = {k for k in parents if k not in pieces}
    uncovered = sum(len(set(prev[k]["changed"]) - {n for u in units if u["parent"] == k for n in u["changed"]})
                    for k in parents - differ - lost)
    print(f"{a.split}/{a.arm}: {len(parents)} parent units ({sum(n > 1 for n in pieces.values())} cut into "
          f"pieces) -> {len(units)} pieces; {len(differ)} single-declaration parents left out (prompt differs "
          f"from `{of}`'s), {len(lost)} with no piece, {uncovered} parent changed lines in no piece",
          file=sys.stderr)
    fresh_new = sum(u["_key"] in fresh for u in units)
    if a.dry_run:
        print(f"{a.split}/{a.arm}: {len(units)} pieces, {fresh_new} without a cached battery answer; estimate "
              f"${fresh_new * USD_PER_PIECE:.2f} at ${USD_PER_PIECE}/piece; spent so far ${spent():.4f} of "
              f"${BUDGET_USD:.2f}")
        return 0
    left = min(a.max_usd, BUDGET_USD - spent())
    if left <= 0:
        sys.exit(f"diffbench: budget ${BUDGET_USD:.2f} spent")
    res = RV.review_units(units, rub, fx, classes, jobs=a.jobs, timeout=a.timeout, max_usd=left,
                          scope_fn=RV.SCOPES[scope_name])
    log_spend(f"run {a.split} {a.arm}", res["spend"])
    _save(f"run-{a.split}-{a.arm}.json", {
        "units": [unit_record(u) for u in res["reviewed"]], "unreviewed": len(res["unreviewed"]),
        "per_unit": res["per_unit"], "spend": res["spend"], "errors": res["errors"],
        "comparable": None, "units_of": of, "roles": a.roles or None,
        "pieces": {k: n for k, n in pieces.items() if k not in differ}})
    print(f"{a.split}/{a.arm}: {len(res['reviewed'])} pieces reviewed, {len(res['unreviewed'])} not (budget), "
          f"{len(res['findings'])} findings, new spend ${res['spend']:.4f}, {res['errors']} errors; "
          f"total spent ${spent():.4f}", file=sys.stderr)
    return 0


# ---------------------------------------------------------------------------
# 4. Scoring
# ---------------------------------------------------------------------------
def at_item(f: dict, u: dict, r: dict, anchor: bool = True) -> bool:
    """The finding sits on the item: same file at the introducing commit, its line
    within the mapped range (+-SLACK), or its unit's anchor naming the item's declaration."""
    if u["commit"] != r.get("commit") or f["file"] != r["commit_file"]:
        return False
    if r["lo"] - SLACK <= f["line"] <= r["hi"] + SLACK:
        return True
    return anchor and bool(r["anchor"]) and r["anchor"] in u["anchor"].split(" / ")


def run_units(split: str, arm: str) -> set[str] | None:
    """The parent units an arm's run reviewed whole (a piece-cut run may stop mid-parent)."""
    run = _load(f"run-{split}-{arm}.json", None)
    if run is None:
        return None
    if "pieces" not in run:
        return {u["_key"] for u in run["units"]}
    done = Counter(parent_of(u) for u in run["units"])
    return {k for k, n in run["pieces"].items() if done[k] == n}


def score(plan: dict, split: str, arm: str, m: dict[str, dict], only: set[str] | None = None,
          anchor: bool = True) -> dict:
    """`only` holds parent units; `anchor` off drops the anchor clause of at_item."""
    run = _load(f"run-{split}-{arm}.json", None)
    if run is None:
        return {}
    whole = run_units(split, arm)
    units = {u["_key"]: u for u in run["units"] if parent_of(u) in whole and (only is None or parent_of(u) in only)}
    per_unit = run["per_unit"]
    recs_by_c: dict[str, list[dict]] = defaultdict(list)
    for r in m.values():
        if r["kept"]:
            recs_by_c[r["commit"]].append(r)
    hit: dict[str, bool] = {}  # item id -> a finding of its class sits on it
    reviewed_items = set()
    labels: dict[tuple, str] = {}  # (unit key, finding index) -> positive|control|allowed|unlabelled
    for k, u in units.items():
        recs = recs_by_c.get(u["commit"], [])
        for r in recs:
            if r["polarity"] in SCORED and overlaps((u["file"], u["lo"], u["hi"]), r["commit_file"], r["lo"],
                                                     r["hi"]):
                reviewed_items.add(r["id"])
        for n, f in enumerate(per_unit.get(k, {}).get("findings", [])):
            lab = "unlabelled"
            for r in recs:
                if not at_item(f, u, r, anchor):
                    continue
                if r["polarity"] in SCORED and r["class"] == f["class"]:
                    hit[r["id"]] = True
                    lab = r["polarity"]
                elif lab == "unlabelled" and (f["class"] in r["also_present"]
                                              or (r["polarity"] == "judgment" and r["class"] == f["class"])):
                    lab = "allowed"
            labels[(k, n)] = lab
    items = [m[i] for i in reviewed_items if m[i]["split"] == split]
    return {"run": run, "units": units, "items": items, "hit": hit, "labels": labels}


def _f(x, fmt="{:.2f}") -> str:
    return "-" if x is None else fmt.format(x)


def _rate(n, d) -> str:
    return f"{_f(n / d if d else None)} ({n}/{d})"


def item_level(m: dict, ids: list[str]) -> dict[str, bool]:
    """The item-level verify:battery-pc verdict per item (battery.py's stored results)."""
    bat = json.loads((E.CACHE / "results" / "battery-pc@generated.json").read_text())
    pc = json.loads((E.CACHE / "results" / "battery-perclass@generated.json").read_text())
    out = {}
    for i in ids:
        r = m[i]
        uk = "U" + BT._h(f"{r['sha']}|{r['file']}|{r['lines']}")[:12]
        b = bat.get(uk)
        if b is None:
            continue
        p = pc.get(f"{uk}#{r['class']}")
        out[i] = r["class"] in b["flags"] and bool(p and p.get("flag"))
    return out


def family(cls: str) -> str:
    return cls.split(".")[0].split("-")[0]


MISS_CAUSES = ("battery did not flag the class in the unit", "battery flagged it, confirm said no",
               "flagged, but its quote was on unchanged lines (scope filter)",
               "a finding of the class in the unit, but outside the range and anchor")


def miss_causes(s: dict, pos: list[dict]) -> dict[str, str]:
    """Per missed positive, the furthest its class got in the units overlapping it."""
    by_c: dict[str, list[str]] = defaultdict(list)
    for k, u in s["units"].items():
        by_c[u["commit"]].append(k)
    out = {}
    for r in pos:
        if s["hit"].get(r["id"]):
            continue
        rank, c = 0, r["class"]
        for k in by_c.get(r.get("commit"), []):
            u = s["units"][k]
            if not overlaps((u["file"], u["lo"], u["hi"]), r["commit_file"], r["lo"], r["hi"]):
                continue
            p = s["run"]["per_unit"].get(k, {})
            if any(f["class"] == c for f in p.get("findings", [])):
                rank = max(rank, 3)
            elif any(d["class"] == c for d in p.get("dropped_battery", []) + p.get("dropped_confirm", [])):
                rank = max(rank, 2)
            elif c in p.get("confirm_no", []):
                rank = max(rank, 1)
        out[r["id"]] = MISS_CAUSES[rank]
    return out


def report(split: str, arms: list[str]) -> str:
    fx = I.load(None)
    m = item_map(fx)
    plan = build_plan(fx)
    out = [f"## Split `{split}`", ""]
    have = {arm: run_units(split, arm) for arm in arms}
    have = {k: v for k, v in have.items() if v is not None}
    common = set.intersection(*have.values()) if have else set()
    sc = {arm: score(plan, split, arm, m, common) for arm in have}
    out += [f"Arms compared on the {len(common)} (parent) units every listed run reviewed whole "
            + ", ".join(f"(`{k}` {len(v)})" for k, v in have.items()) + "; units scored per arm: "
            + ", ".join(f"`{k}` {len(s['units'])}" for k, s in sc.items()) + ".", ""]
    if not sc:
        return "\n".join(out + ["no runs"])
    any_sc = next(iter(sc.values()))
    items = any_sc["items"]
    pos = [r for r in items if r["polarity"] == "positive"]
    ctl = [r for r in items if r["polarity"] == "control"]
    il = item_level(m, [r["id"] for r in items])
    noanchor = {arm: score(plan, split, arm, m, common, anchor=False) for arm in have}
    out += ["### Labelled items", "",
            "| arm | recall | FPR | recall, no anchor clause | FPR, no anchor clause | item-level recall, same items "
            "| item-level FPR, same items |",
            "|---|---:|---:|---:|---:|---:|---:|"]
    for arm, s in sc.items():
        tp = sum(s["hit"].get(r["id"], False) for r in pos)
        fp = sum(s["hit"].get(r["id"], False) for r in ctl)
        na = noanchor[arm]
        ip = [r for r in pos if r["id"] in il]
        ic = [r for r in ctl if r["id"] in il]
        out.append(f"| {arm} | {_rate(tp, len(pos))} | {_rate(fp, len(ctl))} | "
                   f"{_rate(sum(na['hit'].get(r['id'], False) for r in pos), len(pos))} | "
                   f"{_rate(sum(na['hit'].get(r['id'], False) for r in ctl), len(ctl))} | "
                   f"{_rate(sum(il[r['id']] for r in ip), len(ip))} | {_rate(sum(il[r['id']] for r in ic), len(ic))} |")
    out += ["", "### Why positives are missed", "",
            "| arm | cause of the miss | item level found it | item level missed it |", "|---|---|---:|---:|"]
    for arm, s in sc.items():
        causes = miss_causes(s, pos)
        for cause in MISS_CAUSES:
            ids = [i for i, c in causes.items() if c == cause]
            out.append(f"| {arm} | {cause} | {sum(il.get(i) is True for i in ids)} | "
                       f"{sum(il.get(i) is False for i in ids)} |")
    out += ["", "### Unlabelled findings", "",
            "| arm | unit kind | units | changed lines | unlabelled | per unit | per 100 changed lines | "
            "allowed | $ / unit | $ / 100 changed lines |", "|---|---|---:|---:|---:|---:|---:|---:|---:|---:|"]
    for arm, s in sc.items():
        for role in ("item", "other", "clean"):
            ks = {k for k, u in s["units"].items() if u["role"] == role
                  and (role == "item" or plan["commits"][u["commit"]]["noise_split"] == split)}
            if not ks:
                continue
            ch = sum(len(s["units"][k]["changed"]) for k in ks)
            un = sum(1 for (k, _n), lab in s["labels"].items() if k in ks and lab == "unlabelled")
            al = sum(1 for (k, _n), lab in s["labels"].items() if k in ks and lab == "allowed")
            cost = sum(s["run"]["per_unit"][k]["cost"] for k in ks if k in s["run"]["per_unit"])
            out.append(f"| {arm} | {role} | {len(ks)} | {ch} | {un} | {_f(un / len(ks))} | "
                       f"{_f(100 * un / ch if ch else None)} | {al} | {_f(cost / len(ks), '${:.4f}')} | "
                       f"{_f(100 * cost / ch if ch else None, '${:.3f}')} |")
    clean = [pc for pc in plan["commits"].values() if pc["kind"] == "clean" and pc["noise_split"] == split]
    lab = [pc for pc in plan["commits"].values() if pc["kind"] == "labelled" and pc["noise_split"] == split]
    if clean:
        out += ["", f"Whole-commit scale: a clean commit here has {_f(sum(pc['totals']['units'] for pc in clean) / len(clean), '{:.1f}')} "
                    f"units and {_f(sum(pc['totals']['changed'] for pc in clean) / len(clean), '{:.0f}')} changed lines on "
                    f"average (median {sorted(pc['totals']['units'] for pc in clean)[len(clean) // 2]} units); a labelled "
                    f"commit {_f(sum(pc['totals']['units'] for pc in lab) / max(1, len(lab)), '{:.1f}')} units."]
    # Recall by family and evidence scope.
    for key, name in ((lambda r: family(r["class"]), "class family"), (lambda r: r["evidence_scope"], "evidence scope")):
        groups = sorted({key(r) for r in pos})
        out += ["", f"### Recall by {name}", "", "| " + name + " | " + " | ".join(sc) + " | item-level |",
                "|---|" + "---:|" * (len(sc) + 1)]
        for g in groups:
            ps = [r for r in pos if key(r) == g]
            ip = [r for r in ps if r["id"] in il]
            out.append(f"| {g} | " + " | ".join(_rate(sum(s["hit"].get(r["id"], False) for r in ps), len(ps))
                                                for s in sc.values())
                       + f" | {_rate(sum(il[r['id']] for r in ip), len(ip))} |")
    # What the scope filter dropped.
    out += ["", "### What the scope filter dropped", "",
            "| arm | battery flags not confirmed (out of scope) | confirmed findings dropped | top classes |",
            "|---|---:|---:|---|"]
    for arm, s in sc.items():
        pu = s["run"]["per_unit"].values()
        db = [d for p in pu for d in p["dropped_battery"]]
        dc = [d for p in pu for d in p["dropped_confirm"]]
        top = Counter(d["class"] for d in db + dc).most_common(5)
        out.append(f"| {arm} | {len(db)} | {len(dc)} | " + ", ".join(f"`{c}` {n}" for c, n in top) + " |")
    for strict, loose in (("g2", "baseline"), ("fixed", "g1"), ("onedecl", "baseline")):
        if strict in sc and loose in sc:
            out += ["", f"`{strict}` against `{loose}`: " + scope_diff(sc[loose], sc[strict])]
    out += ["", "### Spend", ""]
    for arm, s in sc.items():
        out.append(f"- `{arm}`: {len(s['units'])} units, new spend ${s['run']['spend']:.4f}, "
                   f"{s['run']['errors']} errors, {s['run']['unreviewed']} units not reviewed")
    return "\n".join(out)


def finding_keys(s: dict) -> dict[tuple, str]:
    """(parent unit, class, line) of each finding: the same finding under either cutting."""
    out = {}
    for (k, n), lab in s["labels"].items():
        f = s["run"]["per_unit"][k]["findings"][n]
        out[(parent_of(s["units"][k]), f["class"], f["line"])] = lab
    return out


def scope_diff(loose: dict, strict: dict) -> str:
    a, b = finding_keys(loose), finding_keys(strict)
    gone = Counter(lab for k, lab in a.items() if k not in b)
    new = Counter(lab for k, lab in b.items() if k not in a)
    return (f"{sum(gone.values())} findings dropped ({', '.join(f'{l} {n}' for l, n in gone.most_common()) or 'none'}), "
            f"{sum(new.values())} new ({', '.join(f'{l} {n}' for l, n in new.most_common()) or 'none'}).")


def cmd_report(a) -> int:
    text = report(a.split, a.arms) + "\n\n" + audit_report(a.split)
    print(text)
    if a.out:
        Path(a.out).write_text(text + "\n")
    return 0


# ---------------------------------------------------------------------------
# 5. Audit
# ---------------------------------------------------------------------------
DIFF_SCOPE = ("## Scope\nReview is diff-scoped: a finding is about code the diff adds or changes. The "
              "excerpt is the declaration after the diff; the lines the diff added or changed are listed "
              "after it, and the rest is unchanged context. Rules apply to test code exactly as to source, "
              "except a fixture that deliberately exhibits a pattern. Evidence blocks are context from "
              "elsewhere in the repository.")
CAUSES = ("unchanged", "deliberate", "rule", "needs-evidence", "misread", "other")
CAUSE_CONTRACT = (
    'For "no", add "cause", the main reason, one of: "unchanged" (the finding is about code the diff did '
    'not add or change), "deliberate" (a suppression or comment in the excerpt or evidence says the '
    'duplication or independence is deliberate), "rule" (the code is not an instance of the class under '
    'its rule or an exception covers it), "needs-evidence" (deciding it needs code the reviewer was not '
    'shown), "misread" (the reviewer misread the code or the evidence), "other".')


def audit_system(rub: dict, cls: str) -> str:
    """battery.py's audit prompt with the diff's scope stated and a cause for "no"."""
    s = BT.audit_system(rub, cls)
    head, _, rest = s.partition("## Scope\n")
    _old_scope, _, out = rest.partition("\n\n## Output\n")
    return head + DIFF_SCOPE + "\n\n## Output\n" + out + "\n" + CAUSE_CONTRACT


def audit_user(u: dict, f: dict) -> str:
    ls = u["excerpt"].split("\n")
    changed = "\n".join(ls[n - u["lo"]] for n in u["changed"])
    return (I.render_user(u) + f"\n\nLines the diff added or changed:\n<<<\n{changed}\n>>>"
            + f"\n\nFinding: class `{f['class']}`\nQuote:\n<<<\n{f['quote']}\n>>>\nReviewer's reason: {f['reason']}")


def parse_cause(text: str) -> str:
    mm = re.search(r'"cause"\s*:\s*"([a-z-]+)"', text)
    return mm.group(1) if mm and mm.group(1) in CAUSES else ""


def cmd_audit(a) -> int:
    fx = I.load(None)
    m = item_map(fx)
    plan = build_plan(fx)
    rub, _known, fx, classes = RV.setup()
    # Sample from the units every arm's run reviewed, so the audit scores each arm. A
    # piece-cut arm narrows the pool only for its own audit, so earlier samples stand.
    have = [v for v in (run_units(a.split, arm) for arm in ARMS if ARMS[arm][2] or arm == a.arm) if v is not None]
    s = score(plan, a.split, a.arm, m, set.intersection(*have) if have else None)
    if not s:
        sys.exit(f"no run for {a.split}/{a.arm}")
    pool = []
    for (k, n), lab in sorted(s["labels"].items()):
        u = s["units"][k]
        if lab == "unlabelled" and plan["commits"][u["commit"]]["noise_split"] == a.split:
            pool.append((k, n))
    if a.new_against:
        base = score(plan, a.split, a.new_against, m)
        seen = {(parent_of(base["units"][k]), f["class"], f["line"], f["quote"])
                for k, p in base["run"]["per_unit"].items() if k in base["units"] for f in p["findings"]}
        pool = [(k, n) for k, n in pool if (parent_of(s["units"][k]), *[s["run"]["per_unit"][k]["findings"][n][x]
                                                                     for x in ("class", "line", "quote")]) not in seen]
    picked = sorted(random.Random(SEED).sample(pool, min(a.n, len(pool))))
    est = len(picked) * AUDIT_USD
    print(f"audit {a.split}/{a.arm}: {len(pool)} unlabelled findings, auditing {len(picked)}, "
          f"at most ${est:.2f}; spent so far ${spent():.4f}", file=sys.stderr)
    if a.dry_run:
        return 0
    if spent() + est > BUDGET_USD:
        sys.exit(f"diffbench: an audit of {len(picked)} would pass the ${BUDGET_USD:.2f} budget")
    # The judge sees the twin notes whatever the arm: it rules on the code, not on the reviewer's view.
    need = defaultdict(list)
    for k, _n in picked:
        need[s["units"][k]["commit"]].append(k)
    EV.TWIN_NOTES = True
    full = {}
    if not ARMS[a.arm][2]:
        rows = piece_rows(plan, a.split, {parent_of(s["units"][k]) for k, _n in picked})
    for c, ks in need.items():
        cand = plan["commits"][c]["units"] if ARMS[a.arm][2] else [x for c2, x, _pk in rows if c2 == c]
        specs = [next(x for x in cand if x[0] == s["units"][k]["file"]
                      and x[1] == s["units"][k]["lo"] and x[2] == s["units"][k]["hi"]) for k in ks]
        for k, u in zip(ks, RV.units_from_specs(c, [tuple(x[:6]) for x in specs], a.jobs)):
            full[k] = u
    model = E.CLAUDE_MODELS["opus"]
    reqs, keys = [], []
    for k, n in picked:
        f = s["run"]["per_unit"][k]["findings"][n]
        system, user = audit_system(rub, f["class"]), audit_user(full[k], f)
        key = E.chash({"model": model, "system": system, "user": user})
        reqs.append((key, system, user))
        keys.append((k, n, key))
    fresh = sum(E._cache_get("audit", r[0]) is None for r in reqs)
    res = BT.ask_raw(list({r[0]: r for r in reqs}.values()), model, "audit", a.jobs, a.timeout, False)
    new = 0.0
    out = _load(f"audit-{a.split}-{a.arm}.json", {})
    for k, n, key in keys:
        r = res.get(key, {"error": "missing"})
        f = s["run"]["per_unit"][k]["findings"][n]
        out[f"{k}#{n}"] = {"class": f["class"], "file": f["file"], "line": f["line"], "quote": f["quote"],
                           "reason": f["reason"], "role": s["units"][k]["role"], "parent": parent_of(s["units"][k]),
                           "verdict": "error" if "error" in r else BT.parse_audit(r["raw"]),
                           "cause": parse_cause(r.get("raw", "")), "raw": r.get("raw", "")[:1200],
                           "cost_usd": r.get("cost_usd", 0.0)}
    new = sum(r.get("cost_usd", 0.0) for r in res.values()) if fresh else 0.0
    log_spend(f"audit {a.split} {a.arm}", new)
    _save(f"audit-{a.split}-{a.arm}.json", out)
    print(Counter(v["verdict"] for v in out.values()), Counter(v["cause"] for v in out.values() if v["verdict"] == "no"),
          f"new ${new:.4f}, total spent ${spent():.4f}", file=sys.stderr)
    return 0


CAUSE_TAG = {"unchanged": "G2 (pre-existing code)", "deliberate": "G1 (deliberate twin or suppression)",
             "rule": "the class's rule", "needs-evidence": "missing evidence", "misread": "other (misread)",
             "other": "other", "": "other (no cause given)"}


def _kept_by(split: str, arm: str) -> set[tuple] | None:
    """(parent unit, class) of each finding an arm's run kept."""
    run = _load(f"run-{split}-{arm}.json", None)
    if run is None:
        return None
    parent = {u["_key"]: parent_of(u) for u in run["units"]}
    return {(parent.get(k, k), f["class"]) for k, p in run["per_unit"].items() for f in p["findings"]}


def audit_report(split: str) -> str:
    out = []
    kept = {arm: _kept_by(split, arm) for arm in ARMS}
    covered = {arm: run_units(split, arm) for arm in ARMS}
    for f in sorted(DB.glob(f"audit-{split}-*.json")) if DB.exists() else []:
        v = json.loads(f.read_text())
        c = Counter(x["verdict"] for x in v.values())
        causes = Counter(CAUSE_TAG.get(x["cause"], x["cause"]) for x in v.values() if x["verdict"] == "no")
        yn = c["yes"] + c["no"]
        out.append(f"Audit `{f.stem}`: {len(v)} unlabelled findings: yes {c['yes']}, no {c['no']}, unsure "
                   f"{c['unsure']}, other {len(v) - c['yes'] - c['no'] - c['unsure']}; precision (yes / yes+no) "
                   f"{_f(c['yes'] / yn if yn else None)}; causes of no: "
                   + (", ".join(f"{k} {n}" for k, n in causes.most_common()) or "none")
                   + f"; ${sum(x['cost_usd'] for x in v.values()):.4f}")
        rows = ["", "| verdict | audited | " + " | ".join(f"kept by `{a}`" for a in ARMS if kept[a] is not None)
                + " |", "|---|---:|" + "---:|" * sum(kept[a] is not None for a in ARMS)]
        for verdict in ("yes", "no", "unsure"):
            xs = [(x.get("parent", k.split("#")[0]), x) for k, x in v.items() if x["verdict"] == verdict]
            rows.append(f"| {verdict} | {len(xs)} | " + " | ".join(
                kept_cell(xs, kept[a], covered[a]) for a in ARMS if kept[a] is not None) + " |")
        out.append("\n".join(rows) + "\n\nA cell \"k of n\" counts only the n audited findings whose unit that "
                   "arm's run reviewed.")
    return "\n\n".join(out)


def kept_cell(xs: list[tuple], kept: set[tuple], covered: set[str]) -> str:
    """How many audited findings an arm keeps, among those in units it reviewed."""
    mine = [(uk, x) for uk, x in xs if uk in covered]
    n = sum((uk, x["class"]) in kept for uk, x in mine)
    return str(n) if len(mine) == len(xs) else f"{n} of {len(mine)}"


def cmd_estimate(a) -> int:
    """What a split's runs would cost, without asking."""
    fx = I.load(None)
    plan = build_plan(fx)
    rub, _known, fx, classes = RV.setup()
    for split in a.splits:
        for arm in ("baseline", "g1"):
            units = make_units(plan, split, fx, ARMS[arm][0], a.jobs)
            fresh = sum(E._cache_get(RV.BATTERY_KIND, BT.battery_request(u, rub, classes, True)[0]) is None
                        for u in units)
            print(f"{split}/{arm}: {len(units)} units, {fresh} uncached battery calls, about "
                  f"${fresh * USD_PER_UNIT:.2f} with confirm")
        # Pieces are counted from the cutting alone: a piece equal to its planned unit is
        # the baseline's unit; the others are new unless an onedecl run asked them.
        rows = piece_rows(plan, split)
        asked = {u["_key"] for u in _load(f"run-{split}-onedecl.json", {"units": []})["units"]}
        new = [(c, q) for c, q, pk in rows if unit_key(c, *q[:3]) != pk]
        fresh = sum(unit_key(c, *q[:3]) not in asked for c, q in new)
        roles = Counter(q[6] for _c, q in new)
        print(f"{split}/onedecl: {len(rows)} pieces of {len({pk for *_x, pk in rows})} planned units; "
              f"{len(rows) - len(new)} are a planned unit (the baseline's, cached once it runs), {len(new)} new "
              f"({', '.join(f'{r} {n}' for r, n in sorted(roles.items()))}), {fresh} of them unasked: about "
              f"${fresh * USD_PER_PIECE:.2f} after the baseline at ${USD_PER_PIECE}/piece")
    print(f"audit: about ${AUDIT_USD:.3f} per Opus call")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("map", help="introducing commits and kept/dropped counts (no model)")
    p.set_defaults(fn=cmd_map)
    p = sub.add_parser("plan", help="commits and units per split (no model)")
    p.set_defaults(fn=cmd_plan)
    p = sub.add_parser("run", help="review.py's funnel over a split's planned units, one arm")
    p.add_argument("--split", required=True, choices=("dev", "test"))
    p.add_argument("--arm", required=True, choices=sorted(ARMS))
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--max-usd", type=float, default=BUDGET_USD)
    p.add_argument("--units-of", choices=sorted(ARMS), help="only the units this arm's run reviewed")
    p.add_argument("--roles", nargs="+", choices=("item", "other", "clean"),
                   help="onedecl: only the pieces of parent units of these kinds")
    p.add_argument("--jobs", type=int, default=4)
    p.add_argument("--timeout", type=int, default=300)
    p.set_defaults(fn=cmd_run)
    p = sub.add_parser("audit", help="Opus judges a sample of an arm's unlabelled findings")
    p.add_argument("--split", required=True, choices=("dev", "test"))
    p.add_argument("--arm", required=True, choices=sorted(ARMS))
    p.add_argument("--n", type=int, default=40)
    p.add_argument("--new-against", choices=sorted(ARMS),
                   help="audit only findings this arm has and the given arm lacks")
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--jobs", type=int, default=4)
    p.add_argument("--timeout", type=int, default=300)
    p.set_defaults(fn=cmd_audit)
    p = sub.add_parser("report", help="markdown tables for a split")
    p.add_argument("--split", required=True, choices=("dev", "test"))
    p.add_argument("--arms", nargs="+", default=list(ARMS))
    p.add_argument("--out")
    p.set_defaults(fn=cmd_report)
    p = sub.add_parser("estimate", help="unit counts and cost of a split's runs, asking nothing")
    p.add_argument("--splits", nargs="+", default=["dev", "test"])
    p.add_argument("--jobs", type=int, default=4)
    p.set_defaults(fn=cmd_estimate)
    for p in (sub.choices["run"], sub.choices["audit"]):
        p.add_argument("--approved", action="store_true",
                       help="the project owner approved asking on the test split (it is looked at once)")
    a = ap.parse_args()
    if (getattr(a, "split", None) == "test" and a.cmd in ("run", "audit") and not a.dry_run
            and not a.approved):
        sys.exit("diffbench: the test split runs once, with the owner's approval (--approved); "
                 "`estimate` or --dry-run counts it")
    return a.fn(a)


if __name__ == "__main__":
    sys.exit(main())
