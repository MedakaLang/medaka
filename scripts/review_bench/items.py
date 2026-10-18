"""Loading, selecting and rendering benchmark fixtures.

The schema is scripts/review_bench/fixtures/SCHEMA.md. Required here: polarity,
class, excerpt. Everything else is optional and read tolerantly: a missing id is
derived from the content, a missing split is reported as `none`, an evidence
ref given as a bare string becomes a ref with no excerpt.

Nothing a labeller wrote about the item (summary, notes, ruling, status,
label_strength) is ever rendered into a prompt; only the code is, plus a ref's
`fact`: a mechanically checkable statement about the tree ("no caller of `f`
outside this file at this commit"), the output a candidate generator would give.
"""
from __future__ import annotations

import fnmatch
import hashlib
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
DEFAULT_FIXTURES = HERE / "fixtures"
POLARITIES = ("positive", "control", "judgment")


def _h(s: str) -> str:
    return hashlib.sha256(s.encode()).hexdigest()


def item_key(it: dict) -> str:
    if it.get("id"):
        return str(it["id"])
    blob = json.dumps([it.get("file"), it.get("sha"), it.get("lines"), it.get("anchor"),
                       it.get("class"), it.get("polarity"), it.get("excerpt")])
    return "h" + _h(blob)[:12]


def source_group(it: dict) -> str:
    """What a split and a few-shot exclusion are keyed on: the sprint or mined file."""
    for k in ("source_group", "group"):
        if it.get(k):
            return str(it[k])
    src = it.get("source")
    if isinstance(src, dict) and src.get("ref"):
        return str(src["ref"]).split("#")[0]
    if isinstance(src, str) and src:
        return src.split("#")[0]
    return str(it.get("file") or "?")


def evidence_refs(it: dict) -> list[dict]:
    out = []
    for ref in it.get("evidence_refs") or []:
        if isinstance(ref, str):
            out.append({"file": ref, "anchor": "", "excerpt": ""})
        elif isinstance(ref, dict):
            out.append({"file": ref.get("file", ""), "anchor": ref.get("anchor", ""),
                        "excerpt": ref.get("excerpt", "") or "", "fact": ref.get("fact", "") or ""})
    return out


def load(paths: list[str] | None) -> list[dict]:
    files: list[Path] = []
    for p in (paths or [str(DEFAULT_FIXTURES)]):
        pp = Path(p)
        if pp.is_dir():
            files += sorted(pp.glob("*.jsonl"))
        elif pp.is_file():
            files.append(pp)
        else:
            sys.exit(f"no fixtures at {pp}")
    items, seen = [], set()
    for f in files:
        for n, line in enumerate(f.read_text().splitlines(), 1):
            if not line.strip():
                continue
            try:
                it = json.loads(line)
            except json.JSONDecodeError as e:
                sys.exit(f"{f}:{n}: bad JSON: {e}")
            if not it.get("excerpt") or it.get("polarity") not in POLARITIES or not it.get("class"):
                print(f"skip {f.name}:{n}: needs excerpt, class, polarity in {POLARITIES}", file=sys.stderr)
                continue
            it["_key"] = item_key(it)
            if it["_key"] in seen:
                print(f"skip {f.name}:{n}: duplicate id {it['_key']}", file=sys.stderr)
                continue
            seen.add(it["_key"])
            it["_split"] = it.get("split") or "none"
            it["_group"] = source_group(it)
            it["_refs"] = evidence_refs(it)
            items.append(it)
    return items


def select(items: list[dict], split: str, classes: list[str] | None, known: set[str],
           limit: int | None, include_judgment: bool = False) -> tuple[list[dict], dict]:
    """Filter, then (with a limit) draw round-robin over (class, polarity) strata,
    each stratum in a fixed hash order, so a small sample sees both polarities."""
    skipped = {"unknown_class": 0, "judgment": 0}
    out = []
    for it in items:
        if split != "all" and it["_split"] != split:
            continue
        if classes and not any(fnmatch.fnmatchcase(it["class"], c) for c in classes):
            continue
        if it["class"] not in known:
            skipped["unknown_class"] += 1
            continue
        if it["polarity"] == "judgment" and not include_judgment:
            skipped["judgment"] += 1
            continue
        out.append(it)
    if limit is None or limit >= len(out):
        return out, skipped
    strata: dict[tuple, list[dict]] = {}
    for it in sorted(out, key=lambda x: _h(x["_key"])):
        strata.setdefault((it["class"], it["polarity"]), []).append(it)
    # Classes in hash order (so a small sample is not all `comment.*`), each
    # class's positive stratum next to its control stratum.
    order = sorted(strata, key=lambda s: (_h(s[0]), s[1]))
    picked: list[dict] = []
    while len(picked) < limit:
        progressed = False
        for k in order:
            if strata[k] and len(picked) < limit:
                picked.append(strata[k].pop(0))
                progressed = True
        if not progressed:
            break
    return picked, skipped


def location(it: dict) -> str:
    loc = it.get("file") or "(unknown file)"
    if it.get("anchor"):
        loc += f", declaration `{it['anchor']}`"
    return loc


def render_user(it: dict) -> str:
    parts = [f"File: {location(it)}", "Excerpt:\n<<<\n" + it["excerpt"] + "\n>>>"]
    for i, ref in enumerate(it["_refs"], 1):
        head = f"Evidence {i}: {ref['file']}" + (f", `{ref['anchor']}`" if ref["anchor"] else "")
        body = "\n<<<\n" + ref["excerpt"] + "\n>>>" if ref["excerpt"] else " (location only)"
        parts.append(head + body + (f"\nFact: {ref['fact']}" if ref["fact"] else ""))
    return "\n\n".join(parts)


def jev_evidence(it: dict) -> list[dict]:
    return [{"file": r["file"], "anchor": r["anchor"], "excerpt": r["excerpt"]}
            | ({"fact": r["fact"]} if r["fact"] else {}) for r in it["_refs"]]


def few_shots(item: dict, pool: list[dict], k: int) -> list[tuple[str, bool, str]]:
    """k dev-split examples of the item's class, alternating polarity, never from
    the item's own source group, in a fixed hash order."""
    if k <= 0:
        return []
    cands = [p for p in pool if p["_split"] == "dev" and p["class"] == item["class"]
             and p["_group"] != item["_group"] and p["_key"] != item["_key"]
             and p["polarity"] in ("positive", "control")]
    pos = sorted((p for p in cands if p["polarity"] == "positive"), key=lambda x: _h(x["_key"]))
    neg = sorted((p for p in cands if p["polarity"] == "control"), key=lambda x: _h(x["_key"]))
    picked = []
    while len(picked) < k and (pos or neg):
        for lst in (pos, neg):
            if lst and len(picked) < k:
                picked.append(lst.pop(0))
    # An after-fix control's summary describes the defect it no longer has; as the
    # "why" under DO NOT FLAG it reads as permission for that defect.
    return [(render_user(p), p["polarity"] == "positive",
             "" if p.get("control_kind") == "after-fix" else p.get("summary", "")) for p in picked]
