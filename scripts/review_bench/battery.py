#!/usr/bin/env python3
"""Whole-rubric review per excerpt: does a Jev router pay when every class is
asked of every hunk?

A MEASUREMENT, NOT A GATE. It calls external models and exits 0 unless misused.
Never enrol it in test/gates.toml.

The unit is one distinct excerpt (fixture items grouped by sha, file and
lines). Its labelled classes are its items' classes (positive or control);
`also_present` and judgment classes are allowed and never scored. Every other
class is unlabelled: a flag on one is counted as volume and cost, and scored
only through the Opus audit.

Arms:
  A   `battery`   one Haiku call per excerpt, the whole rubric in the system prompt
  B   `jev`       one Jev router pass per excerpt (state layout: shared, family,
                  perclass), then Haiku per class on the classes it forwards
  B'  `restricted` one Haiku battery call per excerpt over the forwarded classes only
  C   `perclass`  Haiku per class on every class, on a fixed-seed sample

Every Haiku finding is verified as in bench.py: its quote must occur.

Subcommands (`python3 -I scripts/review_bench/battery.py <cmd> -h`):
  jev, battery, perclass, restricted, audit, report
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

sys.path.insert(0, str(HERE.parents[1] / "scripts" / "jev"))
from jev_eval import auc  # noqa: E402

RESULTS = E.CACHE / "results"
STATES = ("shared", "shared1", "family", "perclass")
SAMPLE_SEED = 20261017


# ---------------------------------------------------------------------------
# Units
# ---------------------------------------------------------------------------
def _h(s: str) -> str:
    return hashlib.sha256(s.encode()).hexdigest()


def units(fx: list[dict], split: str, known: set[str]) -> list[dict]:
    by: dict[tuple, list[dict]] = {}
    for it in fx:
        if split != "all" and it["_split"] != split:
            continue
        by.setdefault((it.get("sha"), it.get("file"), it.get("lines")), []).append(it)
    out = []
    for (sha, file, lines), its in by.items():
        refs, seen = [], set()
        for it in its:
            for r in it["_refs"]:
                k = json.dumps(r, sort_keys=True)
                if k not in seen:
                    seen.add(k)
                    refs.append(r)
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
                    "_refs": refs, "_split": first["_split"], "_group": first["_group"],
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
    return {"_key": f"{u['_key']}#{cls}", "class": cls, "excerpt": u["excerpt"], "file": u["file"],
            "anchor": u["anchor"], "_refs": u["_refs"], "_group": u["_group"], "_split": u["_split"],
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
# Jev router: three state layouts, the per-class question text unchanged.
# ---------------------------------------------------------------------------
def slug_key(cls: str) -> str:
    return re.sub(r"[^a-z0-9]", "_", cls)


def _multi_rule_question(r: dict) -> dict:
    q = R.jev_question(r)
    q = dict(q)
    q["instructions"] = q["instructions"].replace("`rule`", f"`rules.{slug_key(r['class'])}`")
    return q


def jev_requests(u: dict, rub: dict, classes: list[str], layout: str, model: str) -> list[tuple]:
    """[(cache key, state, questions, [classes answered])]. Question ids are `<class>|fwd|rev`."""
    evidence = I.jev_evidence(u)
    base = {"file": I.location(u), "excerpt": u["excerpt"], "evidence": evidence}
    if layout == "perclass":
        out = []
        for c in classes:
            it = pseudo_item(u, c)
            key, state, qs = B.jev_request(it, rub, model)
            out.append((key, state, {f"{c}|{k}": v for k, v in qs.items()}, [c]))
        return out
    if layout in ("shared", "shared1"):
        groups = {"all": classes}
    else:
        groups = {}
        for c in classes:
            groups.setdefault("+".join(R.SUBJECTS[c][1]) or "plain", []).append(c)
    # `shared1` asks the flag-first order only: half the question tokens, no position-bias average.
    orders = ("fwd",) if layout == "shared1" else ("fwd", "rev")
    out = []
    for _g, cs in groups.items():
        note_keys = ["core"] + sorted({k for c in cs for k in R.SUBJECTS[c][1]})
        state = {"language_notes": {k: R.NOTES[k] for k in note_keys},
                 "rules": {slug_key(c): R.rule_text(rub[c]) for c in cs}} | base
        qs = {}
        for c in cs:
            for k, v in R.jev_both_orders(_multi_rule_question(rub[c])).items():
                if k in orders:
                    qs[f"{c}|{k}"] = v
        out.append((E.jev_request_key(model, state, qs), state, qs, cs))
    return out


def jev_class_p(res: dict, cls: str) -> float | None:
    ps = [a["probabilities"]["flag"] for qid, a in res.get("answers", {}).items()
          if qid.split("|")[0] == cls and a.get("type") == "choice" and "flag" in a.get("probabilities", {})]
    return sum(ps) / len(ps) if ps else None


def cmd_jev(a) -> int:
    rub, known, fx = _setup()
    us = _select_units(fx, a, known)
    classes = sorted(known)
    reqs = {u["_key"]: jev_requests(u, rub, classes, a.layout, a.jev_model) for u in us}
    flat = list({r[0]: r[:3] for rs in reqs.values() for r in rs}.values())
    toks = sum(len(json.dumps(s)) + len(json.dumps(q)) for _, s, q in flat) / E.CHARS_PER_TOKEN
    print(f"jev[{a.layout}] over {len(us)} excerpts: {len(flat)} requests, ~{toks:.0f} input tokens est., "
          f"~${toks * E.JEV_USD_PER_MTOK_IN / 1e6:.3f}", file=sys.stderr)
    if a.dry_run:
        if a.show:
            k, s, q = flat[0]
            print(json.dumps({"state": s, "questions": dict(list(q.items())[:4])}, indent=1))
        return 0
    todo = sum(1 for k, _, _ in flat if E._cache_get("jev", k) is None)
    t0 = time.perf_counter()
    res = E.ask_jev(flat, a.jev_model, a.jobs)
    wall = time.perf_counter() - t0
    out = {}
    for u in us:
        ps, cost, errs = {}, 0.0, 0
        for key, _s, _q, cs in reqs[u["_key"]]:
            r = res.get(key, {"error": "missing"})
            if "error" in r:
                errs += 1
                continue
            cost += r["cost_usd"]
            for c in cs:
                ps[c] = jev_class_p(r, c)
        out[u["_key"]] = {"p": ps, "cost_usd": cost, "errors": errs, "requests": len(reqs[u["_key"]])}
    _save(f"battery-jev-{a.layout}", out)
    _log_run(f"jev-{a.layout}", a.split, len(us), todo, wall, a.jobs)
    tot = sum(r["cost_usd"] for r in out.values())
    print(f"jev[{a.layout}]: {len(out)} excerpts, {sum(r['errors'] for r in out.values())} failed requests, "
          f"${tot:.4f} (${tot / max(len(out), 1):.5f}/excerpt), {wall:.0f}s for {todo} asked", file=sys.stderr)
    return 0


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
# Arm A / B': the battery prompt.
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


def run_battery(us: list[dict], rub: dict, class_sets: dict[str, list[str]], kind: str, jobs: int,
                timeout: int, prompt_cache: bool) -> dict[str, dict]:
    model = E.CLAUDE_MODELS["haiku"]
    reqs, by = [], {}
    for u in us:
        cs = class_sets[u["_key"]]
        if not cs:
            continue
        system, user = battery_system(rub, cs), I.render_user(u)
        key = E.chash({"model": model, "system": system, "user": user, "prompt_cache": prompt_cache})
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
# Arm C (and B's Haiku stage): per-class Haiku with the bench.py prompt.
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
# Router decisions, shared by B, B' and the report.
# ---------------------------------------------------------------------------
def load_router(layout: str) -> dict[str, dict]:
    return _load(f"battery-jev-{layout}")


def fit_global(us: list[dict], jev: dict, target: float) -> float:
    ps = sorted(jev[u["_key"]]["p"].get(c) or 0.0 for u in us if u["_key"] in jev
                for c, pol in u["labels"].items() if pol == "positive")
    if not ps:
        return 0.0
    grid = [i / 200 for i in range(0, 201)]
    return max(t for t in grid if sum(1 for p in ps if p >= t) >= target * len(ps))


def router_rule(spec: str, us_dev: list[dict]) -> tuple[str, callable]:
    """spec `<layout>:<threshold>|fit95[:cross]`. `cross` always forwards the cross-snippet classes."""
    parts = spec.split(":")
    layout, thr = parts[0], parts[1] if len(parts) > 1 else "fit95"
    cross = "cross" in parts[2:]
    jev = load_router(layout)
    if thr.startswith("fit"):
        t = fit_global(us_dev, jev, int(thr[3:]) / 100)
    else:
        t = float(thr)

    def fwd(u: dict, c: str) -> bool:
        if cross and R.cross_snippet(c):
            return True
        p = jev.get(u["_key"], {}).get("p", {}).get(c)
        return p is None or p >= t
    return f"{layout} t={t:.3f}{' +cross' if cross else ''}", fwd


def cmd_restricted(a) -> int:
    rub, known, fx = _setup()
    us = _select_units(fx, a, known)
    dev = units(fx, "dev", known)
    name, fwd = router_rule(a.router, dev)
    order = _rubric_order(rub, known)
    sets = {u["_key"]: [c for c in order if fwd(u, c)] for u in us}
    n = sum(len(v) for v in sets.values())
    print(f"restricted battery, router {name}: {n / max(len(us), 1):.1f} classes per excerpt", file=sys.stderr)
    if a.dry_run:
        return 0
    t0 = time.perf_counter()
    out = run_battery(us, rub, sets, "battery_r", a.jobs, a.timeout, False)
    for k in out:
        out[k]["router"] = name
    stage = f"battery-restricted-{_tag(a.router)}"
    _save(stage, out)
    _log_run(stage, a.split, len(us), None, time.perf_counter() - t0, a.jobs)
    _summary(stage, out)
    return 0


def cmd_route(a) -> int:
    """Ask per-class Haiku on the pairs a router forwards (B's Haiku stage)."""
    rub, known, fx = _setup()
    us = _select_units(fx, a, known)
    dev = units(fx, "dev", known)
    name, fwd = router_rule(a.router, dev)
    pairs = [(u, c) for u in us for c in sorted(known) if fwd(u, c)]
    print(f"route {name}: {len(pairs)} pairs ({len(pairs) / max(len(us), 1):.1f}/excerpt)", file=sys.stderr)
    if a.dry_run:
        return 0
    t0 = time.perf_counter()
    out = run_perclass(pairs, rub, fx, a.shots, a.jobs, a.timeout)
    _save("battery-perclass", out)
    _log_run(f"route-{_tag(a.router)}", a.split, len(us), None, time.perf_counter() - t0, a.jobs)
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
    dev = units(fx, "dev", known)
    arm, details = arm_flags(a.arm, us, dev)
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
def arm_flags(arm: str, us: list[dict], dev: list[dict]) -> tuple[dict, dict]:
    """Returns ({unit key: flagged classes}, {(unit, class): finding}) and per-unit cost via ARM_COST.
    arm: `battery` | `battery-pc` | `perclass` | `route:<router>` | `restricted:<router>` | `jev:<router>`."""
    ARM_COST.clear()
    flags, det = {}, {}
    if arm.startswith("filter:"):
        # Jev after the battery: a battery finding survives only if the router would forward its class.
        _, base, spec = arm.split(":", 2)
        bflags, bdet = arm_flags(base, us, dev)
        bcost = dict(ARM_COST)
        _name, fwd = router_rule(spec, dev)
        jcost = {k: v["cost_usd"] for k, v in load_router(spec.split(":")[0]).items()}
        ARM_COST.clear()
        for u in us:
            if u["_key"] not in bflags:
                continue
            flags[u["_key"]] = {c for c in bflags[u["_key"]] if fwd(u, c)}
            c0, d0, n0 = bcost[u["_key"]]
            ARM_COST[u["_key"]] = (c0 + jcost.get(u["_key"], 0.0), d0, n0)
        return flags, {k: v for k, v in bdet.items() if k[1] in flags.get(k[0], ())}
    if arm in ("battery", "battery-pc") or arm.startswith("restricted:"):
        stage = arm if not arm.startswith("restricted:") else f"battery-restricted-{_tag(arm.split(':', 1)[1])}"
        res = _load(stage)
        jcost = {}
        if arm.startswith("restricted:"):
            layout = arm.split(":", 1)[1].split(":")[0]
            jcost = {k: v["cost_usd"] for k, v in load_router(layout).items()}
        for u in us:
            r = res.get(u["_key"])
            if r is None:
                continue
            flags[u["_key"]] = set(r["flags"])
            for c, f in r["flags"].items():
                det[(u["_key"], c)] = f
            ARM_COST[u["_key"]] = (r["cost_usd"] + jcost.get(u["_key"], 0.0), r.get("duration_ms") or 0,
                                   r.get("classes_asked", 0))
        return flags, det
    pc = _load("battery-perclass")
    if arm == "perclass":
        fwd, jcost = (lambda u, c: True), {}
    else:
        kind, spec = arm.split(":", 1)
        _name, fwd = router_rule(spec, dev)
        jcost = {k: v["cost_usd"] for k, v in load_router(spec.split(":")[0]).items()}
    jev_only = arm.startswith("jev:")
    for u in us:
        cs, cost, dur, n, complete = set(), jcost.get(u["_key"], 0.0), 0, 0, True
        for c in sorted(R.SUBJECTS):
            if not fwd(u, c):
                continue
            n += 1
            if jev_only:
                cs.add(c)
                continue
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


def router_stats(us: list[dict], layout: str, dev: list[dict]) -> dict:
    jev = load_router(layout)
    pos, ctl, unl = [], [], []
    for u in us:
        if u["_key"] not in jev:
            continue
        for c, p in jev[u["_key"]]["p"].items():
            if p is None:
                continue
            lab = label_of(u, c)
            (pos if lab == "positive" else ctl if lab == "control" else unl if lab == "unlabelled" else []).append(p)
    pairs = [(p, True) for p in pos] + [(p, False) for p in ctl]
    pairs_u = [(p, True) for p in pos] + [(p, False) for p in unl]
    t = fit_global(dev, jev, 0.95)
    return {"auc_pc": auc(pairs) if pairs else None, "auc_pu": auc(pairs_u) if pairs_u else None,
            "t95": t, "n": len([u for u in us if u["_key"] in jev]),
            "cost": sum(jev[u["_key"]]["cost_usd"] for u in us if u["_key"] in jev),
            "fwd_per": (sum(1 for p in pos + ctl + unl if p >= t)
                        + sum(1 for u in us if u["_key"] in jev for c, p in jev[u["_key"]]["p"].items()
                              if p is not None and label_of(u, c) == "allowed" and p >= t))
            / max(1, len([u for u in us if u["_key"] in jev])),
            "pos_recall": sum(1 for p in pos if p >= t) / len(pos) if pos else None,
            "ctl_fwd": sum(1 for p in ctl if p >= t) / len(ctl) if ctl else None}


def cmd_report(a) -> int:
    rub, known, fx = _setup()
    us = _select_units(fx, a, known)
    dev = units(fx, "dev", known)
    lines = [f"## Split `{a.split}`: {len(us)} excerpts", ""]
    lines += ["### Jev router alone (P(flag) over every class of every excerpt)", "",
              "| state | excerpts | AUC pos vs ctl | AUC pos vs unlabelled | t (95% dev recall) | "
              "recall at t | controls forwarded | classes forwarded / excerpt | $/excerpt |",
              "|---|---:|---:|---:|---:|---:|---:|---:|---:|"]
    for layout in STATES:
        if not load_router(layout):
            continue
        s = router_stats(us, layout, dev)
        if not s["n"]:
            continue
        lines.append(f"| {layout} | {s['n']} | {_f(s['auc_pc'])} | {_f(s['auc_pu'])} | {s['t95']:.3f} | "
                     f"{_f(s['pos_recall'])} | {_f(s['ctl_fwd'])} | {s['fwd_per']:.1f} | "
                     f"${s['cost'] / s['n']:.5f} |")
    lines += ["", "### Arms", "",
              "| arm | excerpts | recall | FPR | unlabelled flags / excerpt (excerpts) | classes asked / excerpt | "
              "$/excerpt | Claude s / excerpt |",
              "|---|---:|---:|---:|---:|---:|---:|---:|"]
    for arm in a.arms:
        sub = us
        if a.sample_for and any(arm.startswith(p) for p in a.sample_for):
            sub = sample(us, a.sample)
        try:
            flags, _ = arm_flags(arm, sub, dev)
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
    for f in sorted(RESULTS.glob(f"audit-*-{a.split}.json")) if RESULTS.exists() else []:
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
    return rub, known, I.load(None)


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
    f = E.ensure_cache(RESULTS.name) / f"{stage}.json"
    cur = json.loads(f.read_text()) if f.exists() else {}
    cur.update(recs)
    f.write_text(json.dumps(cur, indent=1))


def _load(stage: str) -> dict:
    f = RESULTS / f"{stage}.json"
    return json.loads(f.read_text()) if f.exists() else {}


def _log_run(stage, split, n, asked, wall, jobs) -> None:
    f = E.ensure_cache(RESULTS.name) / "battery-runs.jsonl"
    with f.open("a") as fh:
        fh.write(json.dumps({"stage": stage, "split": split, "excerpts": n, "asked": asked,
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

    p = sub.add_parser("jev", help="Jev router over every class of every excerpt")
    common(p, claude=False)
    p.add_argument("--layout", choices=STATES, default="shared")
    p.add_argument("--jev-model", default=E.JEV_MODEL)
    p.add_argument("--show", action="store_true")
    p.set_defaults(fn=cmd_jev)

    p = sub.add_parser("battery", help="arm A: one Haiku call per excerpt over the whole rubric")
    common(p)
    p.add_argument("--prompt-cache", action="store_true")
    p.add_argument("--show", action="store_true")
    p.set_defaults(fn=cmd_battery)

    p = sub.add_parser("perclass", help="arm C: per-class Haiku (bench.py prompt) on every or labelled class")
    common(p)
    p.add_argument("--which", choices=("all", "labelled"), default="all")
    p.add_argument("--shots", type=int, default=2)
    p.set_defaults(fn=cmd_perclass)

    p = sub.add_parser("route", help="arm B: per-class Haiku on the classes a router forwards")
    common(p)
    p.add_argument("--router", required=True, help="<layout>:<t>|fit95[:cross]")
    p.add_argument("--shots", type=int, default=2)
    p.set_defaults(fn=cmd_route)

    p = sub.add_parser("restricted", help="arm B': Haiku battery over the forwarded classes only")
    common(p)
    p.add_argument("--router", required=True)
    p.set_defaults(fn=cmd_restricted)

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

    a = ap.parse_args()
    return a.fn(a)


if __name__ == "__main__":
    sys.exit(main())
