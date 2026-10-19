#!/usr/bin/env python3
"""Cheap style review of a live diff: the measured funnel of
docs/design/REVIEW-WORKFLOW-DESIGN.md applied to committed Medaka code.

A MEASUREMENT-GRADE TOOL, NOT A GATE. It calls external models, always exits 0
unless misused, and must never be enrolled in test/gates.toml.

Per unit (a top-level declaration the diff touches, with its leading comment
block, at the diff's head commit; see README.md "Reviewing a live diff"):
  1. evidence: the union of evidence.py's generators, capped as battery.py caps it;
  2. the battery prompt (battery.py), one Haiku call over the whole rubric;
  3. diff scope: a battery class goes on only if one of its findings quotes a
     line the diff added or changed (or quotes only evidence blocks); `--scope
     strict` asks for half the quoted lines (scope_strict);
  4. for each such class, the per-class confirm prompt (bench.claude_request,
     2 dev shots, that class's evidence); a finding survives only if both flag it;
  5. quote verification (bench.quote_verified), applied to both stages.
The prompts are built by the functions the benchmark measured, never copied
here, so the numbers in RESULTS-confirm-2026-10-18.md describe these prompts;
the scoping is code and changes no prompt.

Run from anywhere: python3 -I scripts/review_bench/review.py [--rev A..B] [--dry-run]
"""
from __future__ import annotations

import argparse
import contextlib
import json
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import battery as BT  # noqa: E402
import bench as B  # noqa: E402
import engines as E  # noqa: E402
import evidence as EV  # noqa: E402
import items as I  # noqa: E402
import rubric as R  # noqa: E402

ROOT = EV.ROOT
RESULTS_FILE = "scripts/review_bench/RESULTS-confirm-2026-10-18.md"
SHOTS = 2
BATTERY_KIND = "battery_pc"  # the measured arm is `battery-pc`: the battery with Claude Code's prompt cache
MAX_UNIT_LINES = 80
MERGE_LINES = 40  # a benchmark excerpt is at most 40 lines (fixtures/SCHEMA.md)
CONTEXT = 8  # lines kept on each side of a changed run when a long declaration is windowed
# Measured on the test split (RESULTS_FILE): battery then confirm, per hunk.
USD_PER_UNIT = 0.0052
CONFIRMS_PER_UNIT = 2.3


# ---------------------------------------------------------------------------
# The diff
# ---------------------------------------------------------------------------
def git(*args: str) -> str:
    r = subprocess.run(["git", "-C", str(ROOT), *args], capture_output=True, text=True, errors="replace")
    if r.returncode != 0:
        sys.exit(f"git {' '.join(args)}: {r.stderr.strip()}")
    return r.stdout


def resolve_rev(rev: str | None) -> tuple[str, str, str]:
    """(base sha, head sha, the range as given). A bare commit means that commit alone."""
    if rev is None:
        base = git("merge-base", "origin/main", "HEAD").strip()
        rev = f"{base[:12]}..HEAD"
    if "..." in rev:
        sys.exit("--rev takes A..B (a tree diff between two commits), not A...B")
    a, b = rev.split("..", 1) if ".." in rev else (rev + "^", rev)
    sa = git("rev-parse", "--verify", (a or "HEAD") + "^{commit}").strip()
    sb = git("rev-parse", "--verify", (b or "HEAD") + "^{commit}").strip()
    return sa, sb, rev


def skip_reason(path: str) -> str | None:
    if path.startswith("compiler/seed/"):
        return "bootstrap seed"
    if path.startswith("test/snapshots/"):
        return "snapshot"
    parts = path.split("/")
    if any("golden" in p for p in parts):
        return "golden"
    # A fixture deliberately exhibits a pattern (a lint rule's own fixture, a
    # must-fail pin, a program a gate's golden pins line by line); the rubric
    # exempts it (STYLE-RUBRIC.md, R27).
    if any("fixture" in p or "must_fail" in p for p in parts[:-1]):
        return "fixture"
    return None


def changed_files(a: str, b: str) -> tuple[list[str], list[tuple[str, str]], int]:
    """(reviewed .mdk paths at b, [(path, why skipped)], count of non-.mdk files changed)."""
    reviewed, skipped, other = [], [], 0
    for ln in git("diff", "--name-status", "-M", "--no-color", a, b).splitlines():
        f = ln.split("\t")
        status, path = f[0], f[-1]
        if not path.endswith(".mdk"):
            other += 1
            continue
        if status.startswith("D"):
            skipped.append((path, "deleted"))
            continue
        why = skip_reason(path)
        if why:
            skipped.append((path, why))
        else:
            reviewed.append(path)
    return reviewed, skipped, other


HUNK_RE = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@")


def changed_lines(a: str, b: str, path: str) -> set[int]:
    """Line numbers at b that the diff adds or changes (pure deletions add none)."""
    out: set[int] = set()
    for ln in git("diff", "-U0", "-M", "--no-color", "--no-ext-diff", a, b, "--", path).splitlines():
        m = HUNK_RE.match(ln)
        if m:
            start, n = int(m.group(1)), int(m.group(2) if m.group(2) is not None else 1)
            out.update(range(start, start + n))
    return out


# ---------------------------------------------------------------------------
# Units
# ---------------------------------------------------------------------------
def windows(lo: int, hi: int, changed: list[int]) -> list[tuple[int, int]]:
    """A span of at most MAX_UNIT_LINES is one unit; a longer one becomes windows
    of changed runs with CONTEXT lines each side, clipped to the span."""
    if hi - lo + 1 <= MAX_UNIT_LINES:
        return [(lo, hi)]
    runs: list[list[int]] = []
    for n in changed:
        if runs and n - runs[-1][0] + 1 + 2 * CONTEXT <= MAX_UNIT_LINES:
            runs[-1][1] = n
        else:
            runs.append([n, n])
    out: list[tuple[int, int]] = []
    for first, last in runs:
        w = (max(lo, first - CONTEXT), min(hi, last + CONTEXT))
        if out and w[0] <= out[-1][1]:
            if w[1] - out[-1][0] + 1 <= MAX_UNIT_LINES:
                w = (out.pop()[0], w[1])
            else:
                w = (out[-1][1] + 1, w[1])
        out.append(w)
    return out


def make_unit(sha: str, path: str, lo: int, hi: int, anchor: str, excerpt: str) -> dict:
    """A unit in the shape battery.py's units() builds with generated evidence."""
    lines = f"{lo}-{hi}"
    by_class = BT._generated_refs(sha, path, lines, excerpt)
    refs = BT._union_capped(by_class, BT.UNION_CAP_CHARS)
    return {"_key": "L" + BT._h(f"{sha}|{path}|{lines}")[:12], "sha": sha, "file": path, "lines": lines,
            "anchor": anchor, "excerpt": excerpt, "_refs": refs, "_refs_by_class": by_class,
            "_split": "live", "_group": "live-diff", "groups": [], "item_keys": [], "labels": {},
            "allowed": [], "lo": lo, "hi": hi}


def decl_anchor(d) -> str:
    if d.kind == "import":
        return "imports"
    if d.kind in ("test", "prop"):
        m = re.search(r'"(?:\\.|[^"\\])*"', d.lines[d.head - 1])
        return f"{d.kind} {m.group(0) if m else d.name}"
    return d.name


def runs(ns: list[int]) -> list[tuple[int, int]]:
    out: list[list[int]] = []
    for n in ns:
        if out and n == out[-1][1] + 1:
            out[-1][1] = n
        else:
            out.append([n, n])
    return [(a, b) for a, b in out]


def cut_units(sha: str, path: str, changed: set[int], merge: bool = True) -> list[tuple[int, int, str]]:
    """[(lo, hi, anchor)] covering every changed line. Consecutive imports form one
    unit (an import block is read as one). With `merge`, touched declarations with
    no untouched one between them share a unit while it stays within MERGE_LINES,
    the size of a benchmark excerpt."""
    tree = EV.Tree(sha)
    spans: list[list] = []  # [lo, hi, anchor, kind]
    for d in tree.decls(path):
        if spans and d.kind == "import" and spans[-1][3] == "import":
            spans[-1][1] = d.end
        else:
            spans.append([d.start, d.end, decl_anchor(d), d.kind])
    groups: list[list] = []  # [lo, hi, [anchors]] of adjacent touched declarations
    prev_touched = False
    covered = set()
    for lo, hi, anchor, kind in spans:
        covered.update(range(lo, hi + 1))
        touched = any(lo <= n <= hi for n in changed)
        if touched:
            g = groups[-1] if groups else None
            if (merge and prev_touched and g and kind != "import" and g[3] != "import"
                    and hi - g[0] + 1 <= MERGE_LINES):
                g[1] = hi
                g[2].append(anchor)
            else:
                groups.append([lo, hi, [anchor], kind])
        prev_touched = touched
    out = []
    for lo, hi, anchors, _kind in groups:
        ch = sorted(n for n in changed if lo <= n <= hi)
        out += [(wlo, whi, " / ".join(anchors)) for wlo, whi in windows(lo, hi, ch)
                if any(wlo <= n <= whi for n in ch)]
    # Changed lines outside every declaration (a file with no top-level head).
    for rlo, rhi in runs(sorted(n for n in changed if n not in covered)):
        out += [(wlo, whi, "") for wlo, whi in windows(rlo, rhi, list(range(rlo, rhi + 1)))]
    return out


SIGILS = re.compile("[\U0001F6A8⚠\U0001F512️]")
VIS_PREFIX = re.compile(r"^(?:public\s+export|export|private)\s+", re.M)
COMMENT_MARK = re.compile(r"^\s*(?:--+|\{-|-\})\s?", re.M)
NEVER_MOVED = ("import",)


def normalize_decl(text: str) -> str:
    """A declaration's text with what a move may change removed: visibility prefix,
    comment sigils, comment markers (a re-wrapped comment), case and whitespace."""
    t = SIGILS.sub("", text)
    t = VIS_PREFIX.sub("", t)
    t = COMMENT_MARK.sub("", t)
    return " ".join(t.lower().split())


def base_index(a: str) -> dict[tuple[str, str], set[str]]:
    """(kind, name) -> normalized texts of every named declaration in the .mdk files at `a`."""
    tree = EV.Tree(a)
    idx: dict[tuple[str, str], set[str]] = {}
    for path in sorted(tree.files()):
        if not path.endswith(".mdk"):
            continue
        for d in tree.decls(path):
            if d.name and d.kind not in NEVER_MOVED:
                idx.setdefault((d.kind, d.name), set()).add(normalize_decl(d.text()))
    return idx


def moved_unchanged(b: str, path: str, ch: set[int], idx: dict) -> tuple[set[int], list[dict]]:
    """(changed lines left once unchanged-but-moved declarations are dropped, the
    dropped declarations). A touched declaration is dropped when a declaration of the
    same kind and name at the base, in this file or another, has the same normalized text."""
    left, dropped = set(ch), []
    for d in EV.Tree(b).decls(path):
        span = range(d.start, d.end + 1)
        if not d.name or d.kind in NEVER_MOVED or not any(n in ch for n in span):
            continue
        if normalize_decl(d.text()) in idx.get((d.kind, d.name), ()):
            left -= set(span)
            dropped.append({"name": d.name, "file": path, "reason": "moved-unchanged"})
    return left, dropped


def unit_specs(a: str, b: str, files: list[str], merge: bool, skip_moved: bool = False,
               dropped: list | None = None) -> tuple[list[tuple], list[str]]:
    """[(path, lo, hi, anchor, excerpt, changed lines)] in file order, before any
    evidence is generated, and notes on files with nothing to review. With `skip_moved`,
    declarations unchanged from `a` bar a move are left out and appended to `dropped`."""
    specs, notes = [], []
    idx = base_index(a) if skip_moved else {}
    for path in files:
        fl = EV.Tree(b).lines(path)
        # A changed blank line carries nothing to review.
        ch = {n for n in changed_lines(a, b, path) if n <= len(fl) and fl[n - 1].strip()}
        if ch and skip_moved:
            ch, gone = moved_unchanged(b, path, ch, idx)
            if dropped is not None:
                dropped += gone
        if not ch:
            notes.append(f"`{path}`: deletions, blank lines or moved-unchanged declarations only")
            continue
        for lo, hi, anchor in cut_units(b, path, ch, merge):
            specs.append((path, lo, hi, anchor, "\n".join(fl[lo - 1:hi]), sorted(n for n in ch if lo <= n <= hi)))
    return specs, notes


def units_from_specs(b: str, specs: list[tuple], jobs: int) -> list[dict]:
    """Units with evidence, generated `jobs` at a time (the generators are git-bound)."""
    from concurrent.futures import ThreadPoolExecutor
    # evidence.py reports a generator error on stdout, which carries the review.
    with contextlib.redirect_stdout(sys.stderr), ThreadPoolExecutor(max_workers=max(1, jobs)) as pool:
        return list(pool.map(lambda s: make_unit(b, *s[:5]) | {"changed": s[5]}, specs))


def build_units(a: str, b: str, files: list[str], jobs: int, merge: bool, skip_moved: bool = False,
                dropped: list | None = None) -> tuple[list[dict], list[str]]:
    """Units in file order, with evidence."""
    specs, notes = unit_specs(a, b, files, merge, skip_moved, dropped)
    return units_from_specs(b, specs, jobs), notes


# ---------------------------------------------------------------------------
# Diff scope
# ---------------------------------------------------------------------------
def quote_spans(excerpt: str, quote: str) -> list[tuple[int, int]]:
    """0-based (first, last) excerpt line spans the quote occupies, whitespace-normalized
    as bench.quote_verified compares it; minimal at both ends."""
    q = B._norm(quote)
    ls = excerpt.split("\n")
    out = []
    if not q:
        return out
    for i in range(len(ls)):
        for j in range(i, len(ls)):
            if q in B._norm("\n".join(ls[i:j + 1])):
                if j == i or q not in B._norm("\n".join(ls[i + 1:j + 1])):
                    out.append((i, j))
                break
    return out


def scope(u: dict, quotes: list[str]) -> tuple[str, int, str] | None:
    """('diff', line, quote) for the first quote overlapping a changed line;
    ('evidence', first changed line, quote) when no quote is in the excerpt at all
    (a finding argued from an evidence block about this unit); None when every
    quote in the excerpt sits on unchanged lines."""
    ch = set(u["changed"])
    in_excerpt = False
    for q in quotes:
        for i, j in quote_spans(u["excerpt"], q):
            in_excerpt = True
            hit = [u["lo"] + k for k in range(i, j + 1) if u["lo"] + k in ch]
            if hit:
                return "diff", hit[0], q
    if in_excerpt:
        return None
    q = next((q for q in quotes if q), "")
    return "evidence", u["changed"][0], q


# Classes whose rule is stated about the change itself: a repeat in new code
# (`dup.in-diff`), new behaviour with no test (`test.gap`), a concern a diff adds
# (`module.scattered-concern`). `scope_strict` holds them to the same half rule,
# since the instance their rule names is new code and either of a finding's two
# quotes may show it; `scope_strict_exempt` lets them keep `scope`'s rule, the
# variant measured beside it.
ABOUT_THE_CHANGE = ("dup.in-diff", "test.gap", "module.scattered-concern")


def comment_lines(excerpt: str) -> set[int]:
    """0-based excerpt lines that are comment lines (`--`, or inside `{- -}`)."""
    out, depth = set(), 0
    for k, ln in enumerate(excerpt.split("\n")):
        s = ln.strip()
        if depth or s.startswith(("--", "{-")):
            out.add(k)
        depth = max(0, depth + ln.count("{-") - ln.count("-}"))
    return out


def scope_strict(u: dict, quotes: list[str], cls: str, exempt: tuple[str, ...] = ()) -> tuple[str, int, str] | None:
    """The rubric's diff scope ("a finding is about code the diff adds or changes"):
    a quote in the excerpt counts only when at least half of its non-blank lines are
    changed lines, or, for `comment.stale`, when a changed quoted line is a comment
    line (the diff edited the comment). Classes in `exempt` keep `scope`'s rule (any
    quoted line changed). A finding quoting only evidence blocks is placed as `scope`
    places it."""
    loose = scope(u, quotes)
    if loose is None or loose[0] == "evidence" or cls in exempt:
        return loose
    ch = set(u["changed"])
    ls = u["excerpt"].split("\n")
    comments = comment_lines(u["excerpt"]) if cls == "comment.stale" else set()
    for q in quotes:
        for i, j in quote_spans(u["excerpt"], q):
            body = [k for k in range(i, j + 1) if ls[k].strip()]
            hit = [k for k in body if u["lo"] + k in ch]
            if hit and (2 * len(hit) >= len(body) or any(k in comments for k in hit)):
                return "diff", u["lo"] + hit[0], q
    return None


def scope_strict_exempt(u: dict, quotes: list[str], cls: str) -> tuple[str, int, str] | None:
    return scope_strict(u, quotes, cls, ABOUT_THE_CHANGE)


SCOPES = {"diff": lambda u, quotes, _cls: scope(u, quotes), "strict": scope_strict,
          "strict-exempt": scope_strict_exempt}


# ---------------------------------------------------------------------------
# Asking
# ---------------------------------------------------------------------------
def setup():
    BT.EVIDENCE = "generated"
    rub = R.load_rubric()
    known = set(rub) & set(R.SUBJECTS)
    fx = I.load(None)
    return rub, known, fx, BT._rubric_order(rub, known)


class Shots:
    """Dev fixtures render as few-shot examples with generated evidence, as in the
    measured confirm arm; only the classes being confirmed are generated."""

    def __init__(self, fx: list[dict]):
        self.dev = [it for it in fx if it["_split"] == "dev"]
        self.done: set[str] = set()

    def need(self, classes: set[str]) -> None:
        new = classes - self.done
        if new:
            with contextlib.redirect_stdout(sys.stderr):
                I.set_evidence([it for it in self.dev if it["class"] in new], "generated")
            self.done |= new


def review(units: list[dict], rub: dict, fx: list[dict], classes: list[str], a) -> dict:
    return review_units(units, rub, fx, classes, jobs=a.jobs, timeout=a.timeout, max_usd=a.max_usd,
                        scope_fn=SCOPES[a.scope])


def review_units(units: list[dict], rub: dict, fx: list[dict], classes: list[str], *, jobs: int, timeout: int,
                 max_usd: float, scope_fn=SCOPES["diff"]) -> dict:
    """The funnel over `units`. Besides the totals, `per_unit` records for each reviewed
    unit what its answers cost when first asked (cached or not), what that run asked
    anew, its findings, and what the scope filter dropped at each stage."""
    model = E.CLAUDE_MODELS["haiku"]
    shots = Shots(fx)
    spend = reused = 0.0
    asked = 0
    findings, out_of_scope, errors, done = [], 0, 0, 0
    per_unit: dict[str, dict] = {}
    chunk = max(1, jobs) * 2
    for n0 in range(0, len(units), chunk):
        if spend >= max_usd:
            break
        part = units[n0:n0 + chunk]
        fresh = {u["_key"]: E._cache_get(BATTERY_KIND, BT.battery_request(u, rub, classes, True)[0]) is None
                 for u in part}
        bat = BT.run_battery(part, rub, {u["_key"]: classes for u in part}, BATTERY_KIND, jobs, timeout, True)
        for u in part:
            r = bat[u["_key"]]
            errors += bool(r.get("error"))
            pu = per_unit[u["_key"]] = {"cost": r["cost_usd"], "new": 0.0, "error": bool(r.get("error")),
                                        "battery": sorted(r["flags"]), "findings": [], "confirm_no": [],
                                        "dropped_battery": [], "dropped_confirm": []}
            if fresh[u["_key"]]:
                spend += r["cost_usd"]
                pu["new"] += r["cost_usd"]
                asked += "error" not in r
            else:
                reused += r["cost_usd"]
        # Scope the battery before confirming: run_battery keeps one finding per class,
        # so every verified finding is read back from its cached answer, and a class
        # is confirmed only if one of them can survive the diff-scope filter.
        best: dict[tuple[str, str], dict] = {}
        for u in part:
            if not bat[u["_key"]]["flags"]:
                continue
            raw = E._cache_get(BATTERY_KIND, BT.battery_request(u, rub, classes, True)[0]) or {}
            for f in BT.parse_findings(raw.get("raw", "")) or []:
                k = (u["_key"], f["class"])
                if f["class"] not in bat[u["_key"]]["flags"] or not B.quote_verified(u, f["evidence_quote"]):
                    continue
                if (scope_fn(u, [f["evidence_quote"]], f["class"])
                        and f["confidence"] > best.get(k, {}).get("confidence", -1)):
                    best[k] = f
            for c, f in sorted(bat[u["_key"]]["flags"].items()):
                if (u["_key"], c) not in best:
                    out_of_scope += 1
                    per_unit[u["_key"]]["dropped_battery"].append(
                        {"class": c, "quote": f["evidence_quote"], "confidence": f["confidence"]})
        pairs = [(u, c) for u in part for c in sorted(bat[u["_key"]]["flags"]) if (u["_key"], c) in best]
        shots.need({c for _, c in pairs})
        pool = {u["_key"]: BT.shot_pool(u, fx) for u in part}
        pfresh = {}
        for u, c in pairs:
            key = B.claude_request(BT.pseudo_item(u, c), rub, model, SHOTS, pool[u["_key"]])[0]
            pfresh[f"{u['_key']}#{c}"] = E._cache_get("claude", key) is None
        pc = BT.run_perclass(pairs, rub, fx, SHOTS, jobs, timeout) if pairs else {}
        for k, rec in pc.items():
            errors += bool(rec.get("error"))
            if pfresh[k]:
                spend += rec["cost_usd"]
                asked += "error" not in rec
            else:
                reused += rec["cost_usd"]
        for u, c in pairs:
            rec, bf = pc[f"{u['_key']}#{c}"], best[(u["_key"], c)]
            pu = per_unit[u["_key"]]
            pu["cost"] += rec["cost_usd"]
            pu["new"] += rec["cost_usd"] if pfresh[f"{u['_key']}#{c}"] else 0.0
            pu["error"] = pu["error"] or bool(rec.get("error"))
            if not rec.get("flag"):
                pu["confirm_no"].append(c)
                continue
            where = scope_fn(u, [rec.get("evidence_quote", ""), bf["evidence_quote"]], c)
            if where is None:
                out_of_scope += 1
                pu["dropped_confirm"].append({"class": c, "quote": rec.get("evidence_quote", ""),
                                              "battery_quote": bf["evidence_quote"],
                                              "reason": rec.get("reason", "")})
                continue
            kind, line, quote = where
            f = {"file": u["file"], "line": line, "class": c, "quote": quote,
                 "reason": rec.get("reason", ""), "confidence_battery": bf["confidence"],
                 "confidence_confirm": rec.get("confidence", 0.0), "anchor": u["anchor"],
                 "quote_from": kind}
            findings.append(f)
            pu["findings"].append(f)
        done += len(part)
    findings.sort(key=lambda f: (-f["confidence_battery"] * f["confidence_confirm"], f["file"], f["line"]))
    return {"findings": findings, "reviewed": units[:done], "unreviewed": units[done:], "spend": spend,
            "reused": reused, "asked": asked, "out_of_scope": out_of_scope, "errors": errors,
            "per_unit": per_unit}


# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
def unit_line(u: dict) -> str:
    return f"- `{u['file']}:{u['lo']}-{u['hi']}`" + (f" `{u['anchor']}`" if u["anchor"] else "") \
        + f" ({len(u['changed'])} changed)"


def skipped_lines(skipped, other, notes) -> list[str]:
    out = [f"- `{p}`: {why}" for p, why in skipped] + [f"- {n}" for n in notes]
    if other:
        out.append(f"- {other} changed non-`.mdk` file(s): the reviewer reads Medaka only")
    return out or ["- none"]


CLOSING = (f"These are a cheap reviewer's findings at the measured operating point (Haiku battery, then "
           f"per-class confirm: recall 0.76, false-positive rate 0.08 on the benchmark's test split, "
           f"`{RESULTS_FILE}`). About one in three findings on classes outside the benchmark labels is "
           f"wrong (audited precision 0.65). Check each against its rubric row in "
           f"`docs/design/STYLE-RUBRIC.md` and the DECLINED register of `.claude/skills/style-review/SKILL.md`; "
           f"the reader decides.")


def moved_lines(moved: list[dict]) -> list[str]:
    if not moved:
        return []
    return [f"## Skipped declarations: unchanged from the base, moved ({len(moved)})"] \
        + [f"- `{m['name']}` in `{m['file']}`: {m['reason']}" for m in moved] + [""]


def markdown(rev: str, a: str, b: str, res: dict, skipped, other, notes, moved=()) -> str:
    fs = res["findings"]
    out = [f"# Cheap style review: `{rev}` ({a[:9]}..{b[:9]})", ""]
    out.append(f"{len(fs)} finding(s), ranked by battery confidence times confirm confidence "
               f"(the rubric carries no per-class severity).")
    out.append("")
    shown = fs[:40]
    for n, f in enumerate(shown, 1):
        out.append(f"{n}. [{f['class']}] {f['file']}:{f['line']}"
                   + (f" `{f['anchor']}`" if f["anchor"] else "")
                   + f" (battery {f['confidence_battery']:.2f}, confirm {f['confidence_confirm']:.2f})")
        q = f["quote"].strip("\n")
        if f["quote_from"] == "evidence":
            out.append("   QUOTE (from an evidence block, not the diff):")
        else:
            out.append("   QUOTE:")
        out += ["   > " + ln for ln in q.split("\n")[:6]]
        out.append(f"   WHY: {f['reason']}")
        out.append("")
    if len(fs) > len(shown):
        rest: dict[str, int] = {}
        for f in fs[len(shown):]:
            rest[f["class"]] = rest.get(f["class"], 0) + 1
        out.append(f"{len(fs) - len(shown)} more (`--json` lists them): "
                   + ", ".join(f"{c} {n}" for c, n in sorted(rest.items(), key=lambda x: -x[1])))
        out.append("")
    out.append(f"## Units reviewed ({len(res['reviewed'])})")
    out += [unit_line(u) for u in res["reviewed"]] or ["- none"]
    out.append("")
    if res["unreviewed"]:
        out.append(f"## Units not reviewed: budget reached ({len(res['unreviewed'])})")
        out += [unit_line(u) for u in res["unreviewed"]]
        out.append("")
    out += moved_lines(list(moved))
    out.append("## Skipped")
    out += skipped_lines(skipped, other, notes)
    out.append("")
    out.append("## Spend")
    out.append(f"${res['spend']:.4f} for {res['asked']} new Haiku call(s); cached answers reused "
               f"(${res['reused']:.4f} when first asked). {res['out_of_scope']} finding(s) dropped as "
               f"outside the diff's changed lines (battery flags not sent to confirm, and confirmed "
               f"findings); {res['errors']} call error(s).")
    out.append("")
    out.append(CLOSING)
    return "\n".join(out)


def dry_run(rev, a, b, units, rub, classes, skipped, other, notes, moved=()) -> str:
    out = [f"# Dry run: `{rev}` ({a[:9]}..{b[:9]})", "", f"## Units ({len(units)})"]
    tok = cached = 0
    for u in units:
        key, system, user = BT.battery_request(u, rub, classes, True)
        hit = E._cache_get(BATTERY_KIND, key) is not None
        cached += hit
        tok += (len(system) + len(user)) / E.CHARS_PER_TOKEN
        out.append(unit_line(u) + (" (cached)" if hit else ""))
    fresh = len(units) - cached
    out += [""] + moved_lines(list(moved))
    out += ["## Skipped"] + skipped_lines(skipped, other, notes) + ["", "## Estimate"]
    out.append(f"Battery input about {tok:,.0f} tokens over {len(units)} call(s) (characters / 4; the "
               f"rubric prefix is the same in every call). Confirm adds about {CONFIRMS_PER_UNIT} per-class "
               f"calls per unit. {cached} unit(s) have a cached battery answer.")
    out.append(f"Estimated cost: ${fresh * USD_PER_UNIT:.2f} for {fresh} uncached unit(s) at the measured "
               f"${USD_PER_UNIT} per hunk (`{RESULTS_FILE}`).")
    return "\n".join(out)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--rev", help="A..B, or one commit for that commit alone "
                                  "(default: $(git merge-base origin/main HEAD)..HEAD)")
    ap.add_argument("--dry-run", action="store_true", help="list units, estimate tokens and cost; ask nothing")
    ap.add_argument("--max-usd", type=float, default=1.00,
                    help="stop asking once new spend reaches this (checked per batch of 2 x --jobs units)")
    ap.add_argument("--jobs", type=int, default=4, help="concurrent requests (the box is shared)")
    ap.add_argument("--timeout", type=int, default=300, help="seconds per Claude call")
    ap.add_argument("--json", action="store_true", help="emit findings as JSON records")
    ap.add_argument("--one-decl", action="store_true",
                    help=f"one declaration per unit; by default adjacent touched declarations share a unit "
                         f"up to {MERGE_LINES} lines")
    ap.add_argument("--scope", choices=sorted(SCOPES), default="diff",
                    help="diff: a quote touching a changed line survives (the measured default); strict: at "
                         "least half of the quote's lines must be changed (scope_strict); strict-exempt: the "
                         "same, but dup.in-diff, test.gap and module.scattered-concern keep the default "
                         "(dev-measured only, RESULTS-diffs-dev-2026-10-18.md)")
    ap.add_argument("--keep-moved", action="store_true",
                    help="review declarations whose text is unchanged from the base bar a visibility prefix, "
                         "whitespace, comment sigils or case, even when moved; by default they are skipped "
                         "and listed")
    ap.add_argument("--twin-notes", action="store_true",
                    help="dup.* evidence also states suppressions and deliberate-copy comments on the excerpt's "
                         "file and its candidate twins (evidence.TWIN_NOTES; dev-measured only)")
    a = ap.parse_args()
    EV.TWIN_NOTES = a.twin_notes
    if a.scope != "diff" or a.twin_notes:
        print("review: --scope strict / --twin-notes are measured on the dev split only; the closing "
              "figures describe the default", file=sys.stderr)

    base, head, rev = resolve_rev(a.rev)
    files, skipped, other = changed_files(base, head)
    if files:
        dirty = git("status", "--porcelain", "--", *files).splitlines()
        if dirty:
            print(f"review: {len(dirty)} reviewed file(s) have uncommitted changes; only committed code "
                  f"at {head[:9]} is reviewed: " + ", ".join(d[3:] for d in dirty[:8]), file=sys.stderr)
    rub, _known, fx, classes = setup()
    moved: list[dict] = []
    units, notes = build_units(base, head, files, a.jobs, not a.one_decl, not a.keep_moved, moved)
    if a.dry_run:
        print(dry_run(rev, base, head, units, rub, classes, skipped, other, notes, moved))
        return 0
    res = review(units, rub, fx, classes, a)
    if res["unreviewed"]:
        print(f"review: budget ${a.max_usd:.2f} reached; {len(res['unreviewed'])} unit(s) not reviewed",
              file=sys.stderr)
    if a.json:
        print(json.dumps({"rev": rev, "base": base, "head": head, "findings": res["findings"],
                          "units_reviewed": len(res["reviewed"]), "units_unreviewed": len(res["unreviewed"]),
                          "skipped": [{"file": p, "reason": w} for p, w in skipped],
                          "skipped_units": moved,
                          "spend_usd": round(res["spend"], 6), "out_of_scope_dropped": res["out_of_scope"],
                          "results": RESULTS_FILE}, indent=1))
    else:
        print(markdown(rev, base, head, res, skipped, other, notes, moved))
    return 0


if __name__ == "__main__":
    sys.exit(main())
