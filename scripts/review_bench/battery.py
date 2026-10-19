#!/usr/bin/env python3
"""Hunk-level review measurement: one Haiku call per excerpt over the whole rubric,
scored against the labelled fixtures.

A MEASUREMENT, NOT A GATE. It calls external models and exits 0 unless misused.
Never enrol it in test/gates.toml.

The unit is one distinct excerpt (fixture items grouped by sha, file and
lines). Its labelled classes are its items' classes (positive or control);
`also_present` and judgment classes are allowed and never scored. Every other
class is unlabelled: a flag on one is counted as volume and cost, and scored
only through the Opus audit.

Arms (subcommand that asks, then the name `report --arms` scores it by):
  A   `battery`     one Haiku call per excerpt, the whole rubric in the system
                    prompt; `battery` or `battery-pc` (with --prompt-cache)
  C   `perclass`    per-class Haiku on every class; `perclass`
  computed from the above without new calls:
  `verify:<battery>` (battery findings per-class Haiku confirms)

Every Haiku finding is verified as in bench.py: its quote must occur.

Subcommands (`python3 -I scripts/review_bench/battery.py <cmd> -h`):
  battery, perclass, audit, report
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import random
import re
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import bench as B  # noqa: E402
import engines as E  # noqa: E402
import items as I  # noqa: E402
import rubric as R  # noqa: E402

RESULTS = E.CACHE / "results"
SAMPLE_SEED = 20261017


# ---------------------------------------------------------------------------
# Units
# ---------------------------------------------------------------------------
def _h(s: str) -> str:
    return hashlib.sha256(s.encode()).hexdigest()


EVIDENCE = "curated"  # set from --evidence: curated | generated | none
# A whole-rubric prompt gets the union of every generator's refs for the excerpt,
# one generator's best ref first in turn, cut off at this many characters.
UNION_CAP_CHARS = 8000


def _generated_refs(sha, file, lines, excerpt) -> dict[str, list[dict]]:
    import evidence as EV
    out = {}
    for c in EV.GENERATED_CLASSES:
        refs = EV.generate({"class": c, "file": file, "sha": sha, "lines": lines, "excerpt": excerpt})
        out[c] = [{"file": r["file"], "anchor": r["anchor"], "excerpt": r["excerpt"],
                   "fact": r.get("fact", "")} for r in refs]
    return out


def _union_capped(by_class: dict[str, list[dict]], cap: int) -> list[dict]:
    queues = [list(v) for v in by_class.values()]
    out, seen, used = [], set(), 0
    while any(queues):
        for q in queues:
            if not q:
                continue
            r = q.pop(0)
            k = json.dumps(r, sort_keys=True)
            size = len(r["excerpt"]) + len(r["fact"])
            if k in seen or used + size > cap:
                continue
            seen.add(k)
            out.append(r)
            used += size
    return out


def units(fx: list[dict], split: str, known: set[str]) -> list[dict]:
    by: dict[tuple, list[dict]] = {}
    for it in fx:
        if split != "all" and it["_split"] != split:
            continue
        by.setdefault((it.get("sha"), it.get("file"), it.get("lines")), []).append(it)
    out = []
    for (sha, file, lines), its in by.items():
        refs, seen, by_class = [], set(), {}
        if EVIDENCE == "curated":
            for it in its:
                for r in I.evidence_refs(it):
                    k = json.dumps(r, sort_keys=True)
                    if k not in seen:
                        seen.add(k)
                        refs.append(r)
        elif EVIDENCE == "generated":
            by_class = _generated_refs(sha, file, lines, its[0]["excerpt"])
            refs = _union_capped(by_class, UNION_CAP_CHARS)
        labels, allowed = {}, set()
        for it in its:
            if it["class"] not in known:
                continue
            if it["polarity"] in ("positive", "control"):
                labels[it["class"]] = it["polarity"]
            else:
                allowed.add(it["class"])
            allowed |= set(it.get("also_present") or [])
        allowed -= set(labels)
        first = its[0]
        out.append({"_key": "U" + _h(f"{sha}|{file}|{lines}")[:12], "sha": sha, "file": file,
                    "lines": lines, "anchor": first.get("anchor", ""), "excerpt": first["excerpt"],
                    "_refs": refs, "_refs_by_class": by_class,
                    "evidence_chars": sum(len(r["excerpt"]) + len(r.get("fact", "")) for r in refs),
                    "_split": first["_split"], "_group": first["_group"],
                    "groups": sorted({it["_group"] for it in its}),
                    "item_keys": sorted(it["_key"] for it in its),
                    "evidence_scope": sorted({it.get("evidence_scope") or "?" for it in its}),
                    "labels": labels, "allowed": sorted(allowed)})
    return sorted(out, key=lambda u: u["_key"])


def sample(us: list[dict], n: int, seed: int = SAMPLE_SEED) -> list[dict]:
    """A fixed-seed draw that keeps the share of excerpts carrying a labelled positive."""
    rng = random.Random(seed)
    pos = [u for u in us if "positive" in u["labels"].values()]
    rest = [u for u in us if u not in pos]
    k = round(n * len(pos) / len(us))
    return sorted(rng.sample(pos, min(k, len(pos))) + rng.sample(rest, min(n - k, len(rest))),
                  key=lambda u: u["_key"])


def pseudo_item(u: dict, cls: str) -> dict:
    """One class asked of one excerpt. With generated evidence a per-class prompt gets
    that class's generator only, as bench.py gives it."""
    refs = u["_refs_by_class"].get(cls, []) if EVIDENCE == "generated" else u["_refs"]
    return {"_key": f"{u['_key']}#{cls}", "class": cls, "excerpt": u["excerpt"], "file": u["file"],
            "anchor": u["anchor"], "_refs": refs, "_group": u["_group"], "_split": u["_split"],
            "polarity": u["labels"].get(cls, "unlabelled")}


def shot_pool(u: dict, fx: list[dict]) -> list[dict]:
    """Few-shot pool for a unit: no item of the unit, of its groups, or with its excerpt."""
    keys, groups = set(u["item_keys"]), set(u["groups"])
    return [p for p in fx if p["_key"] not in keys and p["_group"] not in groups
            and p["excerpt"] != u["excerpt"]]


def label_of(u: dict, cls: str) -> str:
    if cls in u["labels"]:
        return u["labels"][cls]
    return "allowed" if cls in u["allowed"] else "unlabelled"


# ---------------------------------------------------------------------------
# Headless Claude returning raw text (the battery returns a list, not a verdict).
# ---------------------------------------------------------------------------
def _claude_raw_one(model: str, system: str, user: str, timeout: int, prompt_cache: bool) -> dict:
    E.ensure_cache(E.NEUTRAL_CWD.name)
    cmd = ["claude", "-p", "--model", model, "--output-format", "json", "--tools", "",
           "--strict-mcp-config", "--no-session-persistence", "--system-prompt", system]
    env = os.environ if prompt_cache else os.environ | {"DISABLE_PROMPT_CACHING": "1"}
    last = ""
    for _attempt in range(2):
        try:
            r = subprocess.run(cmd, cwd=E.NEUTRAL_CWD, input=user, capture_output=True, text=True,
                               timeout=timeout, env=env)
        except subprocess.TimeoutExpired:
            last = f"timeout after {timeout}s"
            continue
        try:
            j = json.loads(r.stdout)
        except json.JSONDecodeError:
            last = f"exit {r.returncode}: {(r.stderr or r.stdout)[-300:]}"
            continue
        if j.get("is_error"):
            last = f"claude error: {str(j.get('result'))[-300:]}"
            continue
        u = j.get("usage") or {}
        return {"raw": j.get("result") or "", "cost_usd": float(j.get("total_cost_usd") or 0.0),
                "usage": {"input": u.get("input_tokens") or 0,
                          "cache_write": u.get("cache_creation_input_tokens") or 0,
                          "cache_read": u.get("cache_read_input_tokens") or 0,
                          "output": u.get("output_tokens") or 0},
                "model": model, "duration_ms": j.get("duration_ms"), "prompt_cache": prompt_cache}
    return {"error": last}


def ask_raw(reqs: list[tuple[str, str, str]], model: str, kind: str, jobs: int, timeout: int,
            prompt_cache: bool) -> dict[str, dict]:
    """reqs: (key, system, user); the cache kind and key already include the prompt-cache mode."""
    out, todo = {}, []
    for key, system, user in reqs:
        hit = E._cache_get(kind, key)
        if hit is not None:
            out[key] = hit
        else:
            todo.append((key, system, user))
    print(f"{model} [{kind}]: {len(reqs)} requests, {len(out)} cached, {len(todo)} to ask", file=sys.stderr)
    t0 = time.perf_counter()

    def run(t):
        key, system, user = t
        res = _claude_raw_one(model, system, user, timeout, prompt_cache)
        if "error" not in res:
            E._cache_put(kind, key, res)
        return key, res

    with ThreadPoolExecutor(max_workers=jobs) as pool:
        for n, (key, res) in enumerate(pool.map(run, todo), 1):
            out[key] = res
            if n % 25 == 0:
                print(f"  {n}/{len(todo)} ({time.perf_counter() - t0:.0f}s)", file=sys.stderr)
    return out


# ---------------------------------------------------------------------------
# Arm A: the battery prompt.
# ---------------------------------------------------------------------------
BATTERY_CONTRACT = (
    "Reply with one JSON array and nothing else. Each element is one finding:\n"
    '{"class": "<class slug>", "evidence_quote": "<text>", "confidence": <0..1>, '
    '"reason": "<one or two sentences>"}\n'
    "- Report a finding only for a class listed above, and only when the code "
    "shows an instance of that class under its rule and its exceptions. One "
    "site may carry several classes; report each.\n"
    "- evidence_quote: copy verbatim a contiguous span (part of one line or "
    "several whole lines) from the excerpt or an evidence block that shows the "
    "instance. A quote that does not occur verbatim is discarded, and the "
    "finding with it.\n"
    "- confidence: how sure you are that this is a real finding of that class.\n"
    "- Reply `[]` when nothing applies."
)


def battery_system(rub: dict, classes: list[str]) -> str:
    note_keys = ["core"] + sorted({k for c in classes for k in R.SUBJECTS[c][1]})
    rules = []
    section = None
    for c in classes:
        r = rub[c]
        if r["section"] != section:
            section = r["section"]
            rules.append(f"### {section}")
        rules.append(f"`{c}`" + (f" ({r['ruling']})" if r["ruling"] else "") + "\n" + R.rule_text(r))
    return "\n\n".join([
        f"You review Medaka source code against a style rubric of {len(classes)} classes.",
        "## Medaka\n" + "\n\n".join(R.NOTES[k] for k in note_keys),
        "## The classes\n" + "\n\n".join(rules),
        "## Scope\nReview is diff-scoped: treat the excerpt as code a diff adds. "
        "Rules apply to test code exactly as to source, except a fixture that "
        "deliberately exhibits a pattern (a must-fail pin, a lint rule's own "
        "fixture). Evidence blocks are context from elsewhere in the repository. "
        "Do not report idiom density, or formatting `medaka fmt` owns.",
        "## Output\n" + BATTERY_CONTRACT,
    ])


def parse_findings(text: str) -> list[dict] | None:
    t = re.sub(r"^```(?:json)?\s*|\s*```$", "", text.strip())
    br = t[t.find("["): t.rfind("]") + 1] if "[" in t else ""
    lenient = re.sub(r'\\(?![\\"/bfnrtu])', r"\\\\", br)
    for cand in (t, br, lenient):
        try:
            v = json.loads(cand)
        except (json.JSONDecodeError, ValueError):
            continue
        if isinstance(v, list):
            return [{"class": str(f.get("class") or ""), "evidence_quote": str(f.get("evidence_quote") or ""),
                     "confidence": float(f.get("confidence") or 0.0), "reason": str(f.get("reason") or "")}
                    for f in v if isinstance(f, dict)]
    # One malformed element must not drop the rest: read objects one by one.
    found = []
    for m in re.finditer(r"\{[^{}]*\}", lenient or t):
        try:
            f = json.loads(m.group(0))
        except (json.JSONDecodeError, ValueError):
            continue
        if isinstance(f, dict) and "class" in f:
            found.append({"class": str(f.get("class") or ""), "evidence_quote": str(f.get("evidence_quote") or ""),
                          "confidence": float(f.get("confidence") or 0.0), "reason": str(f.get("reason") or "")})
    return found or None


def score_findings(u: dict, findings: list[dict] | None, allowed_classes: set[str]) -> dict:
    flags: dict[str, dict] = {}
    dropped = unknown = 0
    for f in findings or []:
        if f["class"] not in allowed_classes:
            unknown += 1
            continue
        if not B.quote_verified(u, f["evidence_quote"]):
            dropped += 1
            continue
        if f["class"] not in flags or f["confidence"] > flags[f["class"]]["confidence"]:
            flags[f["class"]] = f
    return {"flags": flags, "dropped": dropped, "unknown_class": unknown,
            "parse_error": findings is None}


def battery_request(u: dict, rub: dict, classes: list[str], prompt_cache: bool) -> tuple[str, str, str]:
    """(cache key, system, user) of one battery call; review.py asks the cache with the key."""
    system, user = battery_system(rub, classes), I.render_user(u)
    key = E.chash({"model": E.CLAUDE_MODELS["haiku"], "system": system, "user": user,
                   "prompt_cache": prompt_cache})
    return key, system, user


def run_battery(us: list[dict], rub: dict, class_sets: dict[str, list[str]], kind: str, jobs: int,
                timeout: int, prompt_cache: bool) -> dict[str, dict]:
    model = E.CLAUDE_MODELS["haiku"]
    reqs, by = [], {}
    for u in us:
        cs = class_sets[u["_key"]]
        if not cs:
            continue
        key, system, user = battery_request(u, rub, cs, prompt_cache)
        reqs.append((key, system, user))
        by[u["_key"]] = key
    res = ask_raw(list({r[0]: r for r in reqs}.values()), model, kind, jobs, timeout, prompt_cache)
    out = {}
    for u in us:
        if u["_key"] not in by:
            out[u["_key"]] = {"flags": {}, "cost_usd": 0.0, "classes_asked": 0, "duration_ms": 0}
            continue
        r = res.get(by[u["_key"]], {"error": "missing"})
        if "error" in r:
            out[u["_key"]] = {"error": r["error"], "flags": {}, "cost_usd": 0.0,
                              "classes_asked": len(class_sets[u["_key"]])}
            continue
        sc = score_findings(u, parse_findings(r["raw"]), set(class_sets[u["_key"]]))
        out[u["_key"]] = sc | {"cost_usd": r["cost_usd"], "usage": r["usage"], "duration_ms": r["duration_ms"],
                               "classes_asked": len(class_sets[u["_key"]])}
    return out


def cmd_battery(a) -> int:
    rub, known, fx = _setup()
    us = _select_units(fx, a, known)
    classes = _rubric_order(rub, known)
    if a.dry_run:
        s = battery_system(rub, classes)
        print(f"battery system prompt: {len(s)} chars (~{len(s) / E.CHARS_PER_TOKEN:.0f} tokens); "
              f"{len(us)} excerpts", file=sys.stderr)
        if a.show:
            print(s + "\n--- user ---\n" + I.render_user(us[0]))
        return 0
    t0 = time.perf_counter()
    out = run_battery(us, rub, {u["_key"]: classes for u in us}, _kind("battery", a.prompt_cache), a.jobs,
                      a.timeout, a.prompt_cache)
    stage = "battery" + ("-pc" if a.prompt_cache else "")
    _save(stage, out)
    _log_run(stage, a.split, len(us), None, time.perf_counter() - t0, a.jobs)
    _summary(stage, out)
    return 0


# ---------------------------------------------------------------------------
# Arm C: per-class Haiku with the bench.py prompt.
# ---------------------------------------------------------------------------
def run_perclass(pairs: list[tuple[dict, str]], rub: dict, fx: list[dict], shots: int, jobs: int,
                 timeout: int) -> dict[str, dict]:
    model = E.CLAUDE_MODELS["haiku"]
    reqs = {}
    for u, c in pairs:
        it = pseudo_item(u, c)
        reqs[it["_key"]] = (it, B.claude_request(it, rub, model, shots, shot_pool(u, fx)))
    res = E.ask_claude(list({r[0]: r for _, r in reqs.values()}.values()), model, jobs, timeout)
    out = {}
    for k, (it, (key, _s, _u)) in reqs.items():
        a = res.get(key, {"error": "missing"})
        rec = {"class": it["class"]}
        if "error" in a:
            rec |= {"error": a["error"], "raw_flag": False, "flag": False, "cost_usd": 0.0}
        else:
            v = a["verdict"] or {"flag": False, "confidence": 0.0, "evidence_quote": "", "reason": ""}
            rec |= {"raw_flag": v["flag"], "confidence": v["confidence"], "evidence_quote": v["evidence_quote"],
                    "reason": v["reason"], "parse_error": a["parse_error"], "cost_usd": a["cost_usd"],
                    "duration_ms": a.get("duration_ms")}
        B.apply_verify(rec, it)
        out[k] = rec
    return out


def cmd_perclass(a) -> int:
    rub, known, fx = _setup()
    us = _select_units(fx, a, known)
    if a.which == "labelled":
        pairs = [(u, c) for u in us for c in sorted(u["labels"])]
    elif a.which == "flagged":
        bflags, _ = arm_flags(a.base, us)
        pairs = [(u, c) for u in us for c in sorted(bflags.get(u["_key"], ()))]
    else:
        pairs = [(u, c) for u in us for c in sorted(known)]
    print(f"perclass[{a.which}] {len(pairs)} (excerpt, class) pairs over {len(us)} excerpts", file=sys.stderr)
    if a.dry_run:
        return 0
    t0 = time.perf_counter()
    out = run_perclass(pairs, rub, fx, a.shots, a.jobs, a.timeout)
    _save("battery-perclass", out)
    _log_run(f"perclass-{a.which}", a.split, len(us), None, time.perf_counter() - t0, a.jobs)
    cost = sum(r["cost_usd"] for r in out.values())
    print(f"perclass: {len(out)} pairs, {sum(1 for r in out.values() if r.get('error'))} errors, "
          f"${cost:.4f}", file=sys.stderr)
    return 0


# ---------------------------------------------------------------------------
# Audit: Opus judges a fixed-seed sample of unlabelled flags.
# ---------------------------------------------------------------------------
AUDIT_CONTRACT = (
    "Reply with one JSON object and nothing else:\n"
    '{"verdict": "yes"|"no"|"unsure", "reason": "<one or two sentences>"}\n'
    "- yes: the quoted code really is an instance of this class under its rule "
    "and exceptions, one a reviewer of a diff adding this code should raise.\n"
    "- no: it is not (another class, an exception, a misreading, or not a defect).\n"
    "- unsure: the excerpt and evidence do not let you decide."
)


def audit_system(rub: dict, cls: str) -> str:
    r = rub[cls]
    return "\n\n".join([
        f"You audit one finding a cheap reviewer raised for the Medaka style class `{cls}`"
        + (f" (ruling {r['ruling']})" if r["ruling"] else "") + ".",
        "## Medaka\n" + R.notes_for(cls),
        "## The rule\n" + R.rule_text(r),
        "## Scope\nReview is diff-scoped: treat the excerpt as code a diff adds. Rules apply to test "
        "code exactly as to source, except a fixture that deliberately exhibits a pattern. Evidence "
        "blocks are context from elsewhere in the repository.",
        "## Output\n" + AUDIT_CONTRACT])


def parse_audit(text: str) -> str:
    m = re.search(r'"verdict"\s*:\s*"(yes|no|unsure)"', text)
    return m.group(1) if m else "unparsed"


def unlabelled_flags(us: list[dict], arm: dict[str, set[str]], details: dict) -> list[tuple]:
    out = []
    for u in us:
        for c in sorted(arm.get(u["_key"], set())):
            if label_of(u, c) == "unlabelled":
                out.append((u, c, details.get((u["_key"], c), {})))
    return out


def cmd_audit(a) -> int:
    rub, known, fx = _setup()
    us = _select_units(fx, a, known)
    arm, details = arm_flags(a.arm, us)
    flags = unlabelled_flags(us, arm, details)
    rng = random.Random(SAMPLE_SEED)
    picked = rng.sample(flags, min(a.n, len(flags)))
    print(f"audit {a.arm}: {len(flags)} unlabelled flags, auditing {len(picked)}", file=sys.stderr)
    if a.dry_run:
        return 0
    model = E.CLAUDE_MODELS["opus"]
    reqs, keys = [], []
    for u, c, d in picked:
        system = audit_system(rub, c)
        user = (I.render_user(u) + f"\n\nFinding: class `{c}`\nQuote:\n<<<\n{d.get('evidence_quote', '')}\n>>>\n"
                f"Reviewer's reason: {d.get('reason', '')}")
        key = E.chash({"model": model, "system": system, "user": user})
        reqs.append((key, system, user))
        keys.append((u["_key"], c, key))
    res = ask_raw(list({r[0]: r for r in reqs}.values()), model, "audit", a.jobs, a.timeout, False)
    out = {}
    for uk, c, key in keys:
        r = res.get(key, {"error": "missing"})
        out[f"{uk}#{c}"] = {"class": c, "verdict": "error" if "error" in r else parse_audit(r["raw"]),
                           "raw": r.get("raw", "")[:1000], "cost_usd": r.get("cost_usd", 0.0)}
    _save(f"audit-{_tag(a.arm)}-{a.split}", out)
    from collections import Counter
    print(Counter(v["verdict"] for v in out.values()), f"${sum(v['cost_usd'] for v in out.values()):.4f}",
          file=sys.stderr)
    return 0


# ---------------------------------------------------------------------------
# Scoring arms.
# ---------------------------------------------------------------------------
def arm_flags(arm: str, us: list[dict]) -> tuple[dict, dict]:
    """Returns ({unit key: flagged classes}, {(unit, class): finding}) and per-unit cost via ARM_COST.
    arm: `battery` | `battery-pc` | `perclass` | `verify:<battery>`."""
    ARM_COST.clear()
    flags, det = {}, {}
    if arm.startswith("verify:"):
        # Per-class Haiku after the battery: a battery finding survives only if the
        # per-class prompt for its class also flags it. Complete only where every
        # battery-flagged class has a per-class answer.
        base = arm.split(":", 1)[1]
        bflags, _ = arm_flags(base, us)
        bcost = dict(ARM_COST)
        pc = _load("battery-perclass")
        ARM_COST.clear()
        for u in us:
            if u["_key"] not in bflags:
                continue
            kept, cost, dur, complete = set(), bcost[u["_key"]][0], bcost[u["_key"]][1], True
            for c in bflags[u["_key"]]:
                r = pc.get(f"{u['_key']}#{c}")
                if r is None:
                    complete = False
                    continue
                cost += r["cost_usd"]
                dur += r.get("duration_ms") or 0
                if r.get("flag"):
                    kept.add(c)
                    det[(u["_key"], c)] = r
            flags[u["_key"]] = kept
            if complete:
                ARM_COST[u["_key"]] = (cost, dur, len(bflags[u["_key"]]))
        return flags, det
    if arm in ("battery", "battery-pc"):
        res = _load(arm)
        for u in us:
            r = res.get(u["_key"])
            if r is None:
                continue
            flags[u["_key"]] = set(r["flags"])
            for c, f in r["flags"].items():
                det[(u["_key"], c)] = f
            ARM_COST[u["_key"]] = (r["cost_usd"], r.get("duration_ms") or 0, r.get("classes_asked", 0))
        return flags, det
    if arm != "perclass":
        sys.exit(f"unknown arm `{arm}`: battery | battery-pc | perclass | verify:<battery>")
    pc = _load("battery-perclass")
    for u in us:
        cs, cost, dur, n, complete = set(), 0.0, 0, 0, True
        for c in sorted(R.SUBJECTS):
            n += 1
            r = pc.get(f"{u['_key']}#{c}")
            if r is None:
                complete = False
                continue
            cost += r["cost_usd"]
            dur += r.get("duration_ms") or 0
            if r.get("flag"):
                cs.add(c)
                det[(u["_key"], c)] = r
        flags[u["_key"]] = cs
        if complete:
            ARM_COST[u["_key"]] = (cost, dur, n)
    return flags, det


ARM_COST: dict[str, tuple] = {}


def metrics(us: list[dict], flags: dict[str, set[str]], complete: set[str]) -> dict:
    """Unlabelled flags are counted only over excerpts every forwarded class was asked of."""
    tp = npos = fp = nctl = unl = n = nc = 0
    for u in us:
        if u["_key"] not in flags:
            continue
        n += 1
        f = flags[u["_key"]]
        for c, pol in u["labels"].items():
            if pol == "positive":
                npos += 1
                tp += c in f
            else:
                nctl += 1
                fp += c in f
        if u["_key"] in complete:
            nc += 1
            unl += sum(1 for c in f if label_of(u, c) == "unlabelled")
    return {"n": n, "npos": npos, "tp": tp, "recall": tp / npos if npos else None, "nctl": nctl, "fp": fp,
            "fpr": fp / nctl if nctl else None, "unl_per": unl / nc if nc else None, "unl": unl, "nc": nc}


def cmd_report(a) -> int:
    rub, known, fx = _setup()
    us = _select_units(fx, a, known)
    ev = sum(u["evidence_chars"] for u in us) / max(1, len(us))
    lines = [f"## Split `{a.split}`, evidence `{EVIDENCE}`: {len(us)} excerpts, "
             f"evidence {ev / E.CHARS_PER_TOKEN:.0f} tokens per excerpt (characters / 4)", ""]
    lines += ["### Arms", "",
              "| arm | excerpts | recall | FPR | unlabelled flags / excerpt (excerpts) | classes asked / excerpt | "
              "$/excerpt | Claude s / excerpt |",
              "|---|---:|---:|---:|---:|---:|---:|---:|"]
    for arm in a.arms:
        sub = us
        if a.sample_for and any(arm.startswith(p) for p in a.sample_for):
            sub = sample(us, a.sample)
        try:
            flags, _ = arm_flags(arm, sub)
        except (FileNotFoundError, KeyError) as e:
            lines.append(f"| {arm} | missing: {e} |")
            continue
        m = metrics(sub, flags, set(ARM_COST))
        costed = [ARM_COST[k] for k in flags if k in ARM_COST]
        cost = sum(c for c, _, _ in costed) / len(costed) if costed else None
        dur = sum(d for _, d, _ in costed) / len(costed) / 1000 if costed else None
        asked = sum(n for _, _, n in costed) / len(costed) if costed else None
        lines.append(f"| {arm} | {m['n']} | {_f(m['recall'])} ({m['tp']}/{m['npos']}) | {_f(m['fpr'])} "
                     f"({m['fp']}/{m['nctl']}) | {_f(m['unl_per'])} ({m['nc']}) | {_f(asked, '{:.1f}')} | "
                     f"{_f(cost, '${:.5f}')} ({len(costed)}) | {_f(dur, '{:.1f}')} |")
    for f in sorted(RESULTS.glob(f"audit-*-{a.split}{_suffix()}.json")) if RESULTS.exists() else []:
        from collections import Counter
        v = json.loads(f.read_text())
        c = Counter(x["verdict"] for x in v.values())
        n = sum(c.values())
        lines += ["", f"Audit `{f.stem}`: {n} unlabelled flags, yes {c['yes']}, no {c['no']}, "
                      f"unsure {c['unsure']}, other {n - c['yes'] - c['no'] - c['unsure']}; precision "
                      f"(yes / yes+no) {_f(c['yes'] / (c['yes'] + c['no']) if c['yes'] + c['no'] else None)}; "
                      f"${sum(x['cost_usd'] for x in v.values()):.4f}"]
    text = "\n".join(lines)
    print(text)
    if a.out:
        Path(a.out).write_text(text + "\n")
    return 0


# ---------------------------------------------------------------------------
# Plumbing
# ---------------------------------------------------------------------------
def _setup():
    rub = R.load_rubric()
    known = set(rub) & set(R.SUBJECTS)
    fx = I.load(None)
    # Few-shot examples render with the same kind of evidence as the scored prompt;
    # they come from dev only, so only dev items need generating.
    I.set_evidence([it for it in fx if it["_split"] == "dev"], EVIDENCE)
    return rub, known, fx


def _suffix() -> str:
    return "" if EVIDENCE == "curated" else f"@{EVIDENCE}"


def _rubric_order(rub: dict, known: set[str]) -> list[str]:
    return [c for c in rub if c in known]


def _select_units(fx, a, known):
    us = units(fx, a.split, known)
    if getattr(a, "sample", None) and getattr(a, "sample_for", None) is None:
        us = sample(us, a.sample)
    if getattr(a, "limit", None):
        us = us[:a.limit]
    return us


def _kind(base: str, pc: bool) -> str:
    return base + ("_pc" if pc else "")


def _tag(s: str) -> str:
    return re.sub(r"[^A-Za-z0-9.]+", "_", s)


def _save(stage: str, recs: dict) -> None:
    f = E.ensure_cache(RESULTS.name) / f"{stage}{_suffix()}.json"
    cur = json.loads(f.read_text()) if f.exists() else {}
    cur.update(recs)
    f.write_text(json.dumps(cur, indent=1))


def _load(stage: str) -> dict:
    f = RESULTS / f"{stage}{_suffix()}.json"
    return json.loads(f.read_text()) if f.exists() else {}


def _log_run(stage, split, n, asked, wall, jobs) -> None:
    f = E.ensure_cache(RESULTS.name) / "battery-runs.jsonl"
    with f.open("a") as fh:
        fh.write(json.dumps({"stage": stage + _suffix(), "split": split, "excerpts": n, "asked": asked,
                             "wall_s": round(wall, 1), "jobs": jobs, "at": time.time()}) + "\n")


def _summary(stage: str, out: dict) -> None:
    cost = sum(r["cost_usd"] for r in out.values())
    errs = sum(1 for r in out.values() if r.get("error"))
    pe = sum(1 for r in out.values() if r.get("parse_error"))
    dr = sum(r.get("dropped", 0) for r in out.values())
    print(f"{stage}: {len(out)} excerpts, {errs} errors, {pe} parse errors, {dr} unverified findings dropped, "
          f"${cost:.4f} (${cost / max(len(out), 1):.5f}/excerpt)", file=sys.stderr)


def _f(x, fmt="{:.2f}") -> str:
    return "-" if x is None else fmt.format(x)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    def common(p, claude=True):
        p.add_argument("--split", default="dev")
        p.add_argument("--sample", type=int, help=f"fixed-seed sample of N excerpts (seed {SAMPLE_SEED})")
        p.add_argument("--limit", type=int, help="first N excerpts in key order (smoke runs)")
        p.add_argument("--jobs", type=int, default=4, help="concurrent requests (the box is shared)")
        p.add_argument("--dry-run", action="store_true")
        if claude:
            p.add_argument("--timeout", type=int, default=300)

    p = sub.add_parser("battery", help="arm A: one Haiku call per excerpt over the whole rubric")
    common(p)
    p.add_argument("--prompt-cache", action="store_true")
    p.add_argument("--show", action="store_true")
    p.set_defaults(fn=cmd_battery)

    p = sub.add_parser("perclass", help="arm C: per-class Haiku (bench.py prompt) on every or labelled class")
    common(p)
    p.add_argument("--which", choices=("all", "labelled", "flagged"), default="all",
                   help="`flagged`: the classes the --base battery flagged, for `verify:<base>`")
    p.add_argument("--base", default="battery-pc", help="the battery arm `--which flagged` confirms")
    p.add_argument("--shots", type=int, default=2)
    p.set_defaults(fn=cmd_perclass)

    p = sub.add_parser("audit", help="Opus judges a fixed-seed sample of an arm's unlabelled flags")
    common(p)
    p.add_argument("--arm", required=True)
    p.add_argument("--n", type=int, default=30)
    p.set_defaults(fn=cmd_audit)

    p = sub.add_parser("report", help="markdown table of every arm on a split")
    p.add_argument("--split", default="dev")
    p.add_argument("--arms", nargs="+", default=["battery"])
    p.add_argument("--sample", type=int, default=40)
    p.add_argument("--sample-for", nargs="*", default=[], help="arm prefixes scored on the fixed-seed sample only")
    p.add_argument("--limit", type=int)
    p.add_argument("--out")
    p.set_defaults(fn=cmd_report)

    for p in sub.choices.values():
        p.add_argument("--evidence", choices=I.EVIDENCE_MODES, default="curated",
                       help="evidence blocks: fixture-curated refs, evidence.py output (unioned and capped "
                            f"at {UNION_CAP_CHARS} characters for a whole-rubric prompt), or none")
    a = ap.parse_args()
    global EVIDENCE
    EVIDENCE = a.evidence
    return a.fn(a)


if __name__ == "__main__":
    sys.exit(main())
