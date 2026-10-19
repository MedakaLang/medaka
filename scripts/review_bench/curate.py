#!/usr/bin/env python3
"""Fixture curation for the review benchmark: validate, add, edit, count, and
list the items the judges contest. Deterministic and offline (git only, no
model calls). Not a gate: never enrol it in test/gates.toml.

Subcommands (`python3 -I scripts/review_bench/curate.py <cmd> -h`):
  check                 schema, rubric classes, ruling ids, byte-exact excerpts, split leakage
  add <new.jsonl>       allocate ids and splits for new records, check them, append
  edit <edits.json>     apply {id: {set, note, add_ref}} edits, check the edited items
  stats                 regenerate fixtures/STATS.md
  contested             items whose stored judge answers disagree with their label

Run from the repository root: excerpts are checked with `git show <sha>:<file>`.
"""
from __future__ import annotations

import argparse
import collections
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import rubric as R  # noqa: E402

FIXTURES = HERE / "fixtures" / "fixtures.jsonl"
STATS = HERE / "fixtures" / "STATS.md"
RULINGS_MD = R.ROOT / "docs" / "design" / "STYLE-RULINGS.md"

POLARITIES = ("positive", "control", "judgment")
CONTROL_KINDS = ("exception", "after-fix", "declined", "clean")
SEVERITIES = ("high", "medium", "low")
STRENGTHS = ("val", "fixed", "declined", "reviewed", "candidate")
SOURCE_KINDS = ("style-report", "file-mining", "val-ruling", "scan", "derived")
SCOPES = ("local", "file", "repo")
SPLITS = ("dev", "test")
FIELDS = ("id", "polarity", "class", "control_kind", "ruling", "severity", "summary", "file", "anchor",
          "sha", "lines", "excerpt", "evidence_scope", "evidence_refs", "label_strength", "source", "fix",
          "split", "also_present", "notes")
MAX_EXCERPT_LINES = 40
DEV_SHARE = 0.4

# Why a class is below the targets `stats` reports; one line each, kept current by hand.
BELOW_TARGET_WHY = {
    "data.clone-type": "the tree has few unsuppressed Option/Result clones; most two-case types are domain states (now controls).",
    "module.scattered-concern": "the class is about a diff adding a concern to the wrong file; existing disorganization is census, not review (R24), so item-level positives need diff fixtures.",
    "doc.register": "stdlib doc comments were cleaned up under the 2026-10-11 rule; the one positive is the R45 instance; the rest were judgment cases.",
    "comment.restates": "R47 made one-sentence summaries judgment; positives need blocks of two or more restating sentences.",
    "defensive.redundant": "no mined or scanned instance clear enough to label; one judgment item.",
    "test.gap": "needs the diff that added untested behaviour; no excerpt-level instance.",
    "test.repeated-columns": "only the two verdict tables R43 describes exist.",
    "data.string-key": "serialization-boundary keys with a matching parser are rare in the tree.",
}


# ---------------------------------------------------------------------------
def load(path: Path = FIXTURES) -> list[dict]:
    return [json.loads(l) for l in path.read_text().splitlines() if l.strip()]


def save(recs: list[dict], path: Path = FIXTURES) -> None:
    path.write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in recs))


_show: dict[tuple[str, str], list[str] | None] = {}


def lines_at(sha: str, path: str) -> list[str] | None:
    k = (sha, path)
    if k not in _show:
        p = subprocess.run(["git", "show", f"{sha}:{path}"], capture_output=True, text=True)
        _show[k] = p.stdout.splitlines() if p.returncode == 0 else None
    return _show[k]


def span(lines: str) -> tuple[int, int] | None:
    m = re.fullmatch(r"(\d+)-(\d+)", lines or "")
    return (int(m.group(1)), int(m.group(2))) if m and int(m.group(1)) <= int(m.group(2)) else None


def excerpt_error(sha: str, path: str, lines: str, text: str) -> str | None:
    rng = span(lines)
    if rng is None:
        return f"bad line range {lines!r}"
    src = lines_at(sha, path)
    if src is None:
        return f"{path} not at {sha[:10]}"
    return None if "\n".join(src[rng[0] - 1:rng[1]]) == text else f"excerpt differs from {path}:{lines} at {sha[:10]}"


def ruling_ids() -> set[str] | None:
    if not RULINGS_MD.exists():
        return None
    return set(re.findall(r"^### (R\d+)\b", RULINGS_MD.read_text(), re.M))


def check_record(r: dict, classes: set[str], rulings: set[str] | None, git: bool = True) -> list[str]:
    errs = []
    missing = [f for f in FIELDS if f not in r]
    if missing:
        return [f"missing fields {missing}"]
    if not re.fullmatch(r"RB-\d{4,}", r["id"] or ""):
        errs.append(f"bad id {r['id']!r}")
    if r["polarity"] not in POLARITIES:
        errs.append(f"polarity {r['polarity']!r}")
    if r["class"] not in classes:
        errs.append(f"class {r['class']!r} is not a rubric row")
    for c in r["also_present"]:
        if c not in classes:
            errs.append(f"also_present {c!r} is not a rubric row")
    if r["polarity"] == "control":
        if r["control_kind"] not in CONTROL_KINDS:
            errs.append(f"control_kind {r['control_kind']!r}")
    elif r["control_kind"] is not None:
        errs.append("control_kind set on a non-control")
    if r["polarity"] == "positive":
        if r["severity"] not in SEVERITIES:
            errs.append(f"severity {r['severity']!r}")
    elif r["severity"] is not None:
        errs.append("severity set on a non-positive")
    if r["ruling"] is not None:
        if not re.fullmatch(r"R\d+", r["ruling"]):
            errs.append(f"ruling {r['ruling']!r}")
        elif rulings is not None and r["ruling"] not in rulings:
            errs.append(f"ruling {r['ruling']} has no section in {RULINGS_MD.name}")
    if r["label_strength"] not in STRENGTHS:
        errs.append(f"label_strength {r['label_strength']!r}")
    if not isinstance(r["source"], dict) or r["source"].get("kind") not in SOURCE_KINDS:
        errs.append(f"source {r['source']!r}")
    if r["evidence_scope"] not in SCOPES:
        errs.append(f"evidence_scope {r['evidence_scope']!r}")
    if r["split"] not in SPLITS:
        errs.append(f"split {r['split']!r}")
    if not re.fullmatch(r"[0-9a-f]{40}", r["sha"] or ""):
        errs.append("sha must be a full 40-character SHA")
    if len(r["excerpt"].splitlines()) > MAX_EXCERPT_LINES:
        errs.append(f"excerpt over {MAX_EXCERPT_LINES} lines")
    if git:
        e = excerpt_error(r["sha"], r["file"], r["lines"], r["excerpt"])
        if e:
            errs.append(e)
        for i, ref in enumerate(r["evidence_refs"]):
            if ref.get("excerpt") and ref.get("lines"):
                e = excerpt_error(ref.get("sha") or r["sha"], ref["file"], ref["lines"], ref["excerpt"])
                if e:
                    errs.append(f"evidence_refs[{i}]: {e}")
        fx = r["fix"]
        if fx and fx.get("excerpt_after") and fx.get("lines"):
            e = excerpt_error(fx["sha"], fx["file"], fx["lines"], fx["excerpt_after"])
            if e:
                errs.append(f"fix: {e}")
    return errs


def same_code(a: dict, b: dict) -> bool:
    """The same code: one (file, anchor), or overlapping lines of one file at one SHA."""
    if a["file"] != b["file"]:
        return False
    if a["anchor"] and a["anchor"] == b["anchor"]:
        return True
    ra, rb = span(a["lines"]), span(b["lines"])
    return a["sha"] == b["sha"] and ra is not None and rb is not None and ra[0] <= rb[1] and rb[0] <= ra[1]


def leaks(recs: list[dict]) -> list[str]:
    """Pairs of items showing the same code in different splits."""
    by_file = collections.defaultdict(list)
    for r in recs:
        by_file[r["file"]].append(r)
    out = []
    for rs in by_file.values():
        for i, a in enumerate(rs):
            for b in rs[i + 1:]:
                if a["split"] != b["split"] and same_code(a, b):
                    out.append(f"{a['id']} ({a['split']}) and {b['id']} ({b['split']}) show the same code")
    return out


def group_key(r: dict) -> str:
    src = r.get("source") or {}
    return str(src.get("ref") or r["file"]).split("#")[0]


# ---------------------------------------------------------------------------
def cmd_check(a) -> int:
    recs = load(Path(a.fixtures))
    classes, rulings = set(R.load_rubric()), ruling_ids()
    bad = 0
    ids = collections.Counter(r.get("id") for r in recs)
    for i, n in ids.items():
        if n > 1:
            print(f"{i}: id used {n} times")
            bad += 1
    for r in recs:
        for e in check_record(r, classes, rulings, git=not a.no_git):
            print(f"{r.get('id')}: {e}")
            bad += 1
    for e in leaks(recs):
        print(e)
        bad += 1
    if rulings is None:
        print(f"note: {RULINGS_MD.name} not found; ruling ids checked for shape only", file=sys.stderr)
    print(f"{len(recs)} records, {bad} problems")
    return 1 if bad else 0


def cmd_add(a) -> int:
    recs = load(Path(a.fixtures))
    new = load(Path(a.new))
    classes, rulings = set(R.load_rubric()), ruling_ids()
    nxt = max(int(r["id"][3:]) for r in recs) + 1
    dev_pos = {r["class"] for r in recs if r["split"] == "dev" and r["polarity"] == "positive"}
    group_split: dict[str, str] = {}
    for r in new:
        r["id"] = f"RB-{nxt:04d}"
        nxt += 1
        g = group_key(r)
        if g in group_split:
            r["split"] = group_split[g]
            continue
        twin = next((o for o in recs if same_code(o, r)), None)
        if twin:
            r["split"], why = twin["split"], f"same code as {twin['id']}"
        elif r["polarity"] == "positive" and r["class"] not in dev_pos:
            r["split"], why = "dev", f"no dev positive for {r['class']} yet"
        else:
            h = int(hashlib.sha1(g.encode()).hexdigest()[:8], 16) / 0xFFFFFFFF
            r["split"], why = ("dev" if h < DEV_SHARE else "test"), "source-group hash"
        group_split[g] = r["split"]
        if r["split"] == "dev" and r["polarity"] == "positive":
            dev_pos.add(r["class"])
        print(f"{r['id']} {r['class']} {r['polarity']} -> {r['split']} ({why})")
    bad = 0
    for r in new:
        for e in check_record(r, classes, rulings):
            print(f"{r['id']}: {e}")
            bad += 1
    for e in leaks(recs + new):
        if any(r["id"] in e for r in new):
            print(e)
            bad += 1
    if bad:
        print(f"{bad} problems; nothing appended")
        return 1
    if a.dry_run:
        print(f"dry run: {len(new)} records would be appended")
        return 0
    save(recs + new, Path(a.fixtures))
    print(f"appended {len(new)} records; run `curate.py stats`")
    return 0


def cmd_edit(a) -> int:
    recs = load(Path(a.fixtures))
    edits = json.loads(Path(a.edits).read_text())
    classes, rulings = set(R.load_rubric()), ruling_ids()
    by_id = {r["id"]: r for r in recs}
    missing = sorted(set(edits) - set(by_id))
    if missing:
        print(f"ids not found: {missing}")
        return 1
    bad = 0
    for i, e in edits.items():
        r = by_id[i]
        for k, v in e.get("set", {}).items():
            if k not in FIELDS or k == "id":
                print(f"{i}: cannot set {k!r}")
                return 1
            r[k] = v
        if e.get("add_ref"):
            r["evidence_refs"].append(e["add_ref"])
        if e.get("note"):
            r["notes"] = (r["notes"] + " " if r["notes"] else "") + e["note"]
        if r["polarity"] != "control":
            r["control_kind"] = None
        if r["polarity"] != "positive":
            r["severity"] = None
        for err in check_record(r, classes, rulings):
            print(f"{i}: {err}")
            bad += 1
    if bad:
        print(f"{bad} problems; nothing written")
        return 1
    save(recs, Path(a.fixtures))
    print(f"applied {len(edits)} edits; run `curate.py stats`")
    return 0


def cmd_stats(a) -> int:
    recs = load(Path(a.fixtures))
    rub = R.load_rubric()
    with_exc = {c for c, r in rub.items() if r["exceptions"] and r["exceptions"].lower() != "none"}
    C = collections.Counter
    L = ["# Fixture statistics", "",
         "Generated by `python3 -I scripts/review_bench/curate.py stats` from `fixtures.jsonl`; do not edit "
         "by hand. Counts are items; one excerpt can carry items of several classes.", ""]
    sp = C(r["split"] for r in recs)
    L += [f"Total {len(recs)} items: {sp['dev']} dev ({100 * sp['dev'] // len(recs)}%), {sp['test']} test.", "",
          "| | positive | control | judgment | total |", "|---|---|---|---|---|"]
    for ls in STRENGTHS:
        row = C(r["polarity"] for r in recs if r["label_strength"] == ls)
        L.append(f"| {ls} | {row['positive']} | {row['control']} | {row['judgment']} | {sum(row.values())} |")
    row = C(r["polarity"] for r in recs)
    L += [f"| **all** | {row['positive']} | {row['control']} | {row['judgment']} | {len(recs)} |", ""]
    sk = C(r["source"]["kind"] for r in recs)
    L += ["Source kinds: " + ", ".join(f"`{k}` {v}" for k, v in sorted(sk.items())) + ".", "",
          "## By class", "",
          "Positives, controls and judgments as dev/test; `val`, `fixed`, `rev`, `cand` count positives by "
          "label strength (`cand` includes `declined`).", "",
          "| class | pos dev/test | val | fixed | rev | cand | ctrl dev/test | judg |",
          "|---|---|---|---|---|---|---|---|"]
    by = collections.defaultdict(list)
    for r in recs:
        by[r["class"]].append(r)
    short = []
    for cls in rub:
        rs = by.get(cls, [])
        p = [r for r in rs if r["polarity"] == "positive"]
        ct = [r for r in rs if r["polarity"] == "control"]
        j = [r for r in rs if r["polarity"] == "judgment"]
        pd = sum(r["split"] == "dev" for r in p)
        cd = sum(r["split"] == "dev" for r in ct)
        ls = C(r["label_strength"] for r in p)
        L.append(f"| `{cls}` | {pd}/{len(p) - pd} | {ls['val']} | {ls['fixed']} | {ls['reviewed']} | "
                 f"{ls['candidate'] + ls['declined']} | {cd}/{len(ct) - cd} | {len(j)} |")
        why = []
        if len(p) < 4:
            why.append(f"{len(p)} positive" + ("" if len(p) == 1 else "s"))
        if cls in with_exc and len(ct) < 3:
            why.append(f"{len(ct)} control" + ("" if len(ct) == 1 else "s") + " for a named exception")
        if p and pd == 0:
            why.append("no positive in dev")
        if why:
            short.append((cls, why))
    L += ["", "## Below target", "",
          "Targets: four or more positives per class; three or more controls where the rubric names an "
          "exception; one dev positive per class.", ""]
    for cls, why in short:
        extra = BELOW_TARGET_WHY.get(cls, "")
        L.append(f"- `{cls}`: {', '.join(why)}." + (f" Why: {extra}" if extra else ""))
    STATS.write_text("\n".join(L) + "\n")
    print(f"wrote {STATS.relative_to(R.ROOT)}: {len(short)} classes below target")
    return 0


def cmd_contested(a) -> int:
    import bench as B
    recs = {r["id"]: r for r in load(Path(a.fixtures))}
    res = {s: B.load_results(s, a.evidence) for s in a.stages}
    rows = []
    for i, r in recs.items():
        if r["polarity"] == "judgment" or (a.split != "all" and r["split"] != a.split):
            continue
        want = r["polarity"] == "positive"
        votes, said = 0, []
        for s in a.stages:
            h = res[s].get(i)
            if h and h.get("flag") is not None and h["flag"] != want:
                votes += 2 if s == "opus" else 1
                said.append(f"{s}: {h.get('reason', '')[:300]}")
        if votes:
            rows.append((votes, r["label_strength"] != "candidate", i, r, said))
    rows.sort(key=lambda x: (-x[0], x[1], x[2]))
    for votes, _, i, r, said in rows:
        print(f"{i} {r['class']} {r['polarity']} {r['label_strength']} {r['split']} votes={votes}")
        for s in said:
            print(f"    {s}")
    print(f"{len(rows)} contested", file=sys.stderr)
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    def common(p):
        p.add_argument("--fixtures", default=str(FIXTURES))

    p = sub.add_parser("check", help="validate every record")
    common(p)
    p.add_argument("--no-git", action="store_true", help="skip the byte-exact excerpt checks")
    p.set_defaults(fn=cmd_check)

    p = sub.add_parser("add", help="append new records (no id, no split) after checking them")
    common(p)
    p.add_argument("new", help="JSONL of new records; `id` and `split` are assigned")
    p.add_argument("--dry-run", action="store_true")
    p.set_defaults(fn=cmd_add)

    p = sub.add_parser("edit", help="apply {id: {set, note, add_ref}} edits")
    common(p)
    p.add_argument("edits")
    p.set_defaults(fn=cmd_edit)

    p = sub.add_parser("stats", help="regenerate fixtures/STATS.md")
    common(p)
    p.set_defaults(fn=cmd_stats)

    p = sub.add_parser("contested", help="items whose stored judge answers disagree with the label")
    common(p)
    p.add_argument("--stages", nargs="+", default=["haiku", "opus"])
    p.add_argument("--evidence", default="curated")
    p.add_argument("--split", default="dev", help="dev | test | all; adjudicate dev, look at test once")
    p.set_defaults(fn=cmd_contested)

    a = ap.parse_args()
    return a.fn(a)


if __name__ == "__main__":
    sys.exit(main())
