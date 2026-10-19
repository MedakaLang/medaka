#!/usr/bin/env python3
"""Review benchmark: measure a cheap style reviewer against labelled fixtures
(docs/design/REVIEW-WORKFLOW-DESIGN.md, rules in docs/design/STYLE-RUBRIC.md).

A MEASUREMENT, NOT A GATE. It calls external models and always exits 0 unless
it is misused. Never enrol it in test/gates.toml.

Subcommands:
  questions [--class C] [--check]      print each class's Haiku prompt
  run --stage haiku|opus               ask, cache, verify, and store results
  verify                               re-check every stored finding's evidence quote
  report [--split test] [--out F]      per class and stage: recall, FPR, cost
  evidence                             generated-evidence recall, no model

Run with `python3 -I scripts/review_bench/bench.py ...`; see README.md.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import engines as E  # noqa: E402
import items as I  # noqa: E402
import rubric as R  # noqa: E402

RESULTS = E.CACHE / "results"
STAGES = ("haiku", "opus")


# ---------------------------------------------------------------------------
# Request builders
# ---------------------------------------------------------------------------
def claude_request(it: dict, rub: dict, model: str, shots: int, pool: list[dict]) -> tuple[str, str, str]:
    system = R.generative_system(rub[it["class"]], I.few_shots(it, pool, shots))
    user = I.render_user(it)
    return E.claude_request_key(model, system, user), system, user


# ---------------------------------------------------------------------------
# Verification: a flagged finding survives only if its quote is really there.
# ---------------------------------------------------------------------------
def _norm(s: str) -> str:
    return " ".join(s.split())


def quote_verified(it: dict, quote: str) -> bool:
    q = _norm(quote)
    if not q:
        return False
    # A ref's `fact` is code-produced (a search result), so quoting it is as
    # grounded as quoting the code it was computed from.
    texts = [it["excerpt"]] + [r["excerpt"] for r in it["_refs"]] + [r.get("fact", "") for r in it["_refs"]]
    return any(q in _norm(t) for t in texts if t)


def apply_verify(rec: dict, it: dict) -> None:
    if rec.get("raw_flag"):
        rec["verified"] = quote_verified(it, rec.get("evidence_quote", ""))
        rec["flag"] = rec["verified"]
    elif "raw_flag" in rec:
        rec["verified"] = None
        rec["flag"] = False


# ---------------------------------------------------------------------------
# Stages
# ---------------------------------------------------------------------------
def base_record(it: dict) -> dict:
    return {"class": it["class"], "polarity": it["polarity"], "split": it["_split"], "group": it["_group"]}


def run_claude(sel: list[dict], rub: dict, stage: str, shots: int, pool: list[dict], jobs: int,
               timeout: int) -> dict[str, dict]:
    model = E.CLAUDE_MODELS[stage]
    reqs = {it["_key"]: claude_request(it, rub, model, shots, pool) for it in sel}
    res = E.ask_claude(list({r[0]: r for r in reqs.values()}.values()), model, jobs, timeout)
    out = {}
    for it in sel:
        a = res.get(reqs[it["_key"]][0], {"error": "missing"})
        rec = base_record(it) | {"stage": stage, "model": model, "shots": shots}
        if "error" in a:
            rec |= {"error": a["error"], "raw_flag": False, "flag": False, "cost_usd": 0.0}
        else:
            v = a["verdict"] or {"flag": False, "confidence": 0.0, "evidence_quote": "", "reason": ""}
            rec |= {"raw_flag": v["flag"], "confidence": v["confidence"],
                    "evidence_quote": v["evidence_quote"], "reason": v["reason"],
                    "parse_error": a["parse_error"], "cost_usd": a["cost_usd"],
                    "tokens_in": a["usage"]["input"], "tokens_out": a["usage"]["output"]}
        apply_verify(rec, it)
        out[it["_key"]] = rec
    return out


def results_name(stage: str, evidence: str = "curated") -> str:
    # curated keeps the bare name so results from before evidence modes still read.
    return f"{stage}.json" if evidence == "curated" else f"{stage}@{evidence}.json"


def save_results(stage: str, recs: dict[str, dict], evidence: str = "curated") -> Path:
    f = E.ensure_cache(RESULTS.name) / results_name(stage, evidence)
    cur = json.loads(f.read_text()) if f.exists() else {}
    cur.update(recs)
    f.write_text(json.dumps(cur, indent=1))
    return f


def load_results(stage: str, evidence: str = "curated") -> dict[str, dict]:
    f = RESULTS / results_name(stage, evidence)
    return json.loads(f.read_text()) if f.exists() else {}


# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------
def cmd_questions(a) -> int:
    rub = R.load_rubric()
    missing = sorted(set(rub) - set(R.SUBJECTS))
    extra = sorted(set(R.SUBJECTS) - set(rub))
    if a.check:
        fx = I.load(a.fixtures) if a.fixtures or I.DEFAULT_FIXTURES.exists() else []
        unknown = sorted({it["class"] for it in fx} - set(rub))
        print(f"rubric classes: {len(rub)}; with a question: {len(set(rub) & set(R.SUBJECTS))}")
        print(f"rubric classes with no question: {missing or 'none'}")
        print(f"questions for classes not in the rubric: {extra or 'none'}")
        print(f"fixture classes not in the rubric: {unknown or 'none'}")
        return 1 if missing or extra else 0
    for cls in sorted(rub):
        if a.cls and cls not in a.cls:
            continue
        r = rub[cls]
        print(f"## {cls}  ({r['ruling'] or 'established'}; {r['section']})")
        print("### Haiku system prompt")
        print(R.generative_system(r))
        print()
    return 0


def _est_tokens(texts) -> int:
    return int(sum(len(t) for t in texts) / E.CHARS_PER_TOKEN)


def cmd_run(a) -> int:
    rub = R.load_rubric()
    known = set(rub) & set(R.SUBJECTS)
    fx = I.load(a.fixtures)
    sel, skipped = I.select(fx, a.split, a.classes, known, a.limit)
    I.set_evidence(fx, a.evidence, {it["class"] for it in sel})
    if a.stage == "opus" and a.limit is None:
        sys.exit("--stage opus is the ceiling on a sample: pass --limit N")
    npos = sum(1 for it in sel if it["polarity"] == "positive")
    print(f"{a.stage} on split={a.split}, evidence={a.evidence}: {len(sel)} items "
          f"({npos} positive, {len(sel) - npos} control); "
          f"skipped {skipped['judgment']} judgment, {skipped['unknown_class']} with a class not in the rubric",
          file=sys.stderr)
    if not sel:
        return 0
    if a.dry_run:
        return dry_run(a, sel, fx, rub)
    E.PROMPT_CACHE = a.prompt_cache
    recs = run_claude(sel, rub, a.stage, a.shots, fx, a.jobs, a.timeout)
    for it in sel:
        recs[it["_key"]]["evidence"] = a.evidence
        recs[it["_key"]]["evidence_chars"] = sum(len(r["excerpt"]) + len(r.get("fact", ""))
                                                 for r in it["_refs"])
    f = save_results(a.stage, recs, a.evidence)
    errs = sum(1 for r in recs.values() if r.get("error"))
    cost = sum(r["cost_usd"] for r in recs.values())
    print(f"wrote {len(recs)} results to {f.relative_to(HERE)}; {errs} errors; "
          f"cost of these answers ${cost:.4f} (${cost / len(recs):.5f}/item, cached answers included)",
          file=sys.stderr)
    return 0


def dry_run(a, sel, fx, rub) -> int:
    from collections import Counter
    by = Counter((it["class"], it["polarity"]) for it in sel)
    for (cls, pol), n in sorted(by.items()):
        print(f"  {cls:30s} {pol:8s} {n}")
    if a.stage in ("haiku", "opus"):
        model = E.CLAUDE_MODELS[a.stage]
        reqs = [claude_request(it, rub, model, a.shots, fx) for it in sel]
        cached = sum(1 for k, _, _ in reqs if E._cache_get("claude", k) is not None)
        tok = _est_tokens(s + u for _, s, u in reqs)
        seen = [json.loads(p.read_text()) for p in (E.CACHE / "claude").glob("*.json")] \
            if (E.CACHE / "claude").exists() else []
        seen = [c for c in seen if c.get("model") == model]
        per = sum(c["cost_usd"] for c in seen) / len(seen) if seen else None
        note = f"; measured ${per:.5f}/call over {len(seen)} cached calls" if per else ""
        print(f"{model}: {len(reqs)} prompts, {cached} cached; ~{tok} input tokens est.{note}")
        for _, s, u in reqs[:a.show]:
            print(f"--- system ---\n{s}\n--- user ---\n{u}\n")
    return 0


def cmd_verify(a) -> int:
    allfx = I.load(a.fixtures)
    fx = {it["_key"]: it for it in allfx}
    for stage, mode in [(s, m) for m in I.EVIDENCE_MODES for s in ("haiku", "opus")]:
        recs = load_results(stage, mode)
        if not recs:
            continue
        I.set_evidence(allfx, mode, {r["class"] for r in recs.values()})
        flagged = dropped = missing = 0
        for k, rec in recs.items():
            if k not in fx:
                missing += 1
                continue
            apply_verify(rec, fx[k])
            flagged += bool(rec.get("raw_flag"))
            dropped += bool(rec.get("raw_flag")) and not rec.get("verified")
        save_results(stage, recs, mode)
        print(f"{stage} (evidence {mode}): {flagged} flagged, {dropped} dropped as unverifiable"
              + (f", {missing} results for items no longer in the fixtures" if missing else ""))
    return 0


def _metrics(recs: list[dict]) -> dict:
    pos = [r for r in recs if r["polarity"] == "positive"]
    ctl = [r for r in recs if r["polarity"] == "control"]
    tp = sum(1 for r in pos if r.get("flag"))
    fp = sum(1 for r in ctl if r.get("flag"))
    m = {"n_pos": len(pos), "n_ctl": len(ctl), "tp": tp, "fp": fp,
         "recall": tp / len(pos) if pos else None, "fpr": fp / len(ctl) if ctl else None,
         "precision": tp / (tp + fp) if tp + fp else None,
         "cost": sum(r.get("cost_usd") or 0.0 for r in recs),
         "errors": sum(1 for r in recs if r.get("error")),
         "dropped": sum(1 for r in recs if r.get("raw_flag") and not r.get("verified")),
         "est": any(r.get("cost_estimated") for r in recs)}
    return m


def _f(x, fmt="{:.2f}") -> str:
    return "-" if x is None else fmt.format(x)


def cmd_report(a) -> int:
    fx = I.load(a.fixtures)
    in_split = [it for it in fx if a.split == "all" or it["_split"] == a.split]
    # Polarity and class come from the fixtures as they are now: a stored result keeps
    # the label it was asked under, and an item relabelled since must score as relabelled.
    cur = {it["_key"]: it for it in in_split}
    keys = set(cur)
    judg: dict[str, int] = {}
    for it in in_split:
        if it["polarity"] == "judgment":
            judg[it["class"]] = judg.get(it["class"], 0) + 1
    lines = [f"# Review benchmark report: split `{a.split}`", "",
             f"{len(in_split)} fixtures in the split; {sum(judg.values())} judgment items excluded from "
             f"every score. Recall is over positives, FPR over controls, precision over both. "
             f"Haiku and Opus flags count only after evidence verification. "
             f"Cost includes answers served from the cache.", ""]
    for stage, mode in [(s, m) for s in STAGES for m in a.evidence]:
        recs = [r | {"polarity": cur[k]["polarity"], "class": cur[k]["class"]}
                for k, r in load_results(stage, mode).items()
                if k in keys and cur[k]["polarity"] != "judgment"]
        if not recs:
            continue
        classes = sorted({r["class"] for r in recs})
        if a.classes:
            import fnmatch
            classes = [c for c in classes if any(fnmatch.fnmatchcase(c, p) for p in a.classes)]
        rows = [(c, _metrics([r for r in recs if r["class"] == c])) for c in classes]
        allm = _metrics([r for r in recs if r["class"] in classes])
        lines += [f"## {stage}" + ("" if a.evidence == ["curated"] else f" (evidence: {mode})"), ""]
        head = "| class | pos | ctl | judg excl | recall | FPR | precision | dropped unverified | errors |"
        sep = "|---|---:|---:|---:|---:|---:|---:|---:|---:|"
        head += " cost/item | cost total |"
        sep += "---:|---:|"
        lines += [head, sep]
        for c, m in rows + [("**all**", allm)]:
            n = m["n_pos"] + m["n_ctl"]
            jx = sum(judg.values()) if c == "**all**" else judg.get(c, 0)
            row = (f"| {c} | {m['n_pos']} | {m['n_ctl']} | {jx} | {_f(m['recall'])} | {_f(m['fpr'])} | "
                   f"{_f(m['precision'])} |")
            row += f" {m['dropped']} | {m['errors']} |"
            row += f" ${m['cost'] / n if n else 0:.5f} | ${m['cost']:.4f} |"
            lines.append(row)
        lines.append("")
    text = "\n".join(lines)
    print(text)
    if a.out:
        Path(a.out).write_text(text + "\n")
        print(f"wrote {a.out}", file=sys.stderr)
    return 0


def cmd_evidence(a) -> int:
    """Generator recall with no model: on positives whose curated refs resolve,
    the share of curated refs a generated ref covers (same file and declaration
    or overlapping lines), and the share of items with at least one covered."""
    import fnmatch
    import evidence as EV
    fx = I.load(a.fixtures)
    if a.show:
        for it in fx:
            if it["_key"] in a.show:
                print(f"## {it['_key']} {it['class']} {it['file']} ({it['sha'][:9]} {it.get('lines')})")
                for r in EV.generate(it):
                    print(f"- {r['file']} `{r['anchor']}` {r['lines']}\n  fact: {r['fact']}")
                    if r["excerpt"]:
                        print("  " + r["excerpt"].replace("\n", "\n  "))
                print()
        return 0
    pats = a.classes or list(EV.GENERATED_CLASSES)
    sel = [it for it in fx if (a.split == "all" or it["_split"] == a.split)
           and any(fnmatch.fnmatchcase(it["class"], p) for p in pats) and it["polarity"] != "judgment"]
    rows = {}
    misses = []
    for it in sel:
        gen = EV.generate(it)
        row = rows.setdefault(it["class"], {"items": 0, "with_gen": 0, "chars": 0, "pos_cur": 0,
                                            "refs": 0, "covered": 0, "items_hit": 0})
        row["items"] += 1
        row["with_gen"] += bool(gen)
        row["chars"] += sum(len(r["excerpt"]) + len(r["fact"]) for r in gen)
        if it["polarity"] != "positive":
            continue
        cur = [r for r in it.get("evidence_refs") or [] if isinstance(r, dict) and EV.resolvable(r)]
        if not cur:
            continue
        row["pos_cur"] += 1
        hit = [EV.covers(gen, r) for r in cur]
        row["refs"] += len(cur)
        row["covered"] += sum(hit)
        row["items_hit"] += any(hit)
        misses += [(it["_key"], it["class"], r.get("file"), r.get("anchor")) for r, h in zip(cur, hit) if not h]
    print(f"Generator recall against curated refs, split `{a.split}` "
          f"(positives whose curated refs resolve; refs into docs or skills excluded).\n")
    print("| class | items | with generated refs | mean tokens | positives with curated refs "
          "| curated refs covered | items with >=1 covered |")
    print("|---|---:|---:|---:|---:|---:|---:|")
    tot = {k: 0 for k in ("items", "with_gen", "chars", "pos_cur", "refs", "covered", "items_hit")}
    for cls in sorted(rows):
        r = rows[cls]
        for k in tot:
            tot[k] += r[k]
        print(f"| {cls} | {r['items']} | {r['with_gen']} | {r['chars'] / max(1, r['items']) / E.CHARS_PER_TOKEN:.0f} "
              f"| {r['pos_cur']} | {r['covered']}/{r['refs']} | {r['items_hit']}/{r['pos_cur']} |")
    print(f"| **all** | {tot['items']} | {tot['with_gen']} | "
          f"{tot['chars'] / max(1, tot['items']) / E.CHARS_PER_TOKEN:.0f} | {tot['pos_cur']} | "
          f"{tot['covered']}/{tot['refs']} | {tot['items_hit']}/{tot['pos_cur']} |")
    if a.misses:
        print()
        for m in misses:
            print("miss", *m)
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    def common(p):
        p.add_argument("--fixtures", nargs="+", help=f"jsonl files or dirs (default {I.DEFAULT_FIXTURES})")
        p.add_argument("--classes", nargs="+", help="class names or globs (`comment.*`)")
        p.add_argument("--jobs", type=int, default=4, help="concurrent requests (the box is shared)")

    p = sub.add_parser("questions", help="print each class's Haiku prompt")
    p.add_argument("--class", dest="cls", nargs="+")
    p.add_argument("--check", action="store_true", help="every rubric class has a question; fixture classes known")
    p.add_argument("--fixtures", nargs="+")
    p.set_defaults(fn=cmd_questions)

    p = sub.add_parser("run", help="ask a stage over a split and store results")
    common(p)
    p.add_argument("--stage", choices=STAGES, required=True)
    p.add_argument("--split", default="dev", help="dev | test | all (or any split name in the fixtures)")
    p.add_argument("--limit", type=int, help="stratified sample of N items (required for opus)")
    p.add_argument("--shots", type=int, default=0, help="few-shot examples from the dev split, other sources only")
    p.add_argument("--timeout", type=int, default=300, help="seconds per Claude call")
    p.add_argument("--prompt-cache", action="store_true",
                   help="let Claude Code write its prompt cache (off by default: every prompt is unique)")
    p.add_argument("--evidence", choices=I.EVIDENCE_MODES, default="curated",
                   help="evidence blocks: the fixtures' hand-curated refs (default), refs found by "
                        "evidence.py, or none")
    p.add_argument("--dry-run", action="store_true", help="count and estimate; ask nothing")
    p.add_argument("--show", type=int, default=0, help="with --dry-run, print the first N prompts")
    p.set_defaults(fn=cmd_run)

    p = sub.add_parser("verify", help="re-check stored findings' evidence quotes against the fixtures")
    p.add_argument("--fixtures", nargs="+")
    p.set_defaults(fn=cmd_verify)

    p = sub.add_parser("report", help="markdown report per class and stage")
    p.add_argument("--fixtures", nargs="+")
    p.add_argument("--classes", nargs="+")
    p.add_argument("--split", default="test")
    p.add_argument("--evidence", nargs="+", choices=I.EVIDENCE_MODES, default=["curated"],
                   help="which runs to report, by evidence mode")
    p.add_argument("--out", help="also write the markdown here")
    p.set_defaults(fn=cmd_report)

    p = sub.add_parser("evidence", help="show generated evidence, or measure its recall against curated refs")
    p.add_argument("--fixtures", nargs="+")
    p.add_argument("--classes", nargs="+")
    p.add_argument("--split", default="dev")
    p.add_argument("--show", nargs="+", metavar="ID", help="print the generated refs of these items")
    p.add_argument("--misses", action="store_true", help="with the recall table, list uncovered curated refs")
    p.set_defaults(fn=cmd_evidence)

    a = ap.parse_args()
    return a.fn(a)


if __name__ == "__main__":
    sys.exit(main())
