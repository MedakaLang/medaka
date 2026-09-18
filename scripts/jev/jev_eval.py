#!/usr/bin/env python3
"""Re-measure jev_census.py's questions against the hand-labeled corpus.

Run this after changing any question in jev_census.py. It asks the model the
current questions over scripts/jev/eval_corpus.json (every item carries its
own text, so the tree can drift underneath) and prints precision,
recall, AUC, calibration by probability bucket, Score rank correlation, and
Choice accuracy at confidence tiers, next to the regex census's own numbers
on the same sample. Numbers are agreement with one labeler's judgment, not
truth; the corpus header says so.

Usage:
  python3 scripts/jev/jev_eval.py               # both halves
  python3 scripts/jev/jev_eval.py --kind do
  python3 scripts/jev/jev_eval.py --no-language-notes   # the novel-language control

Answers go through the same .jev-cache/ as the census, so an unchanged
question costs nothing to re-evaluate.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import jev_census as jc  # noqa: E402

CORPUS = Path(__file__).resolve().parent / "eval_corpus.json"


def prf(pairs, thr):
    tp = sum(1 for p, y in pairs if p >= thr and y)
    fp = sum(1 for p, y in pairs if p >= thr and not y)
    fn = sum(1 for p, y in pairs if p < thr and y)
    prec = tp / (tp + fp) if tp + fp else 0.0
    rec = tp / (tp + fn) if tp + fn else 0.0
    f1 = 2 * prec * rec / (prec + rec) if prec + rec else 0.0
    return prec, rec, f1, tp, fp, fn


def auc(pairs):
    pos = [p for p, y in pairs if y]
    neg = [p for p, y in pairs if not y]
    if not pos or not neg:
        return float("nan")
    return sum(1.0 if p > n else 0.5 if p == n else 0.0 for p in pos for n in neg) / (len(pos) * len(neg))


def noul_report(name, pairs):
    print(f"\n[{name}] n={len(pairs)} positives={sum(1 for _, y in pairs if y)} AUC={auc(pairs):.3f}")
    p, r, f, tp, fp, fn = prf(pairs, 0.5)
    print(f"  @0.5  precision {p:.2f} recall {r:.2f} F1 {f:.2f}  (tp {tp} fp {fp} fn {fn})")
    best = max(((prf(pairs, t / 20)[2], t / 20) for t in range(1, 20)), key=lambda x: x[0])
    p, r, f, *_ = prf(pairs, best[1])
    print(f"  best  thr {best[1]:.2f}: precision {p:.2f} recall {r:.2f} F1 {f:.2f}")
    print("  calibration: bucket, n, mean predicted, observed positive rate")
    for lo in (0.0, 0.2, 0.4, 0.6, 0.8):
        hi = lo + 0.2
        b = [(p_, y) for p_, y in pairs if lo <= p_ < hi or (hi == 1.0 and p_ == 1.0)]
        if b:
            print(f"    [{lo:.1f},{hi:.1f}) n={len(b):3d} pred {sum(p_ for p_, _ in b) / len(b):.2f} "
                  f"obs {sum(1 for _, y in b if y) / len(b):.2f}")


def spearman(xs, ys):
    def ranks(v):
        order = sorted(range(len(v)), key=lambda i: v[i])
        r = [0.0] * len(v)
        i = 0
        while i < len(order):
            j = i
            while j + 1 < len(order) and v[order[j + 1]] == v[order[i]]:
                j += 1
            for k in range(i, j + 1):
                r[order[k]] = (i + j) / 2 + 1
            i = j + 1
        return r
    rx, ry = ranks(xs), ranks(ys)
    n = len(xs)
    mx, my = sum(rx) / n, sum(ry) / n
    num = sum((a - mx) * (b - my) for a, b in zip(rx, ry))
    den = (sum((a - mx) ** 2 for a in rx) * sum((b - my) ** 2 for b in ry)) ** 0.5
    return num / den if den else float("nan")


def score_report(name, pairs):
    mae = sum(abs(s - y) for s, y in pairs) / len(pairs)
    print(f"\n[{name}] n={len(pairs)} MAE {mae:.2f} levels, Spearman {spearman([s for s, _ in pairs], [y for _, y in pairs]):.3f}")
    for lvl in sorted(set(y for _, y in pairs)):
        b = [s for s, y in pairs if y == lvl]
        print(f"    label {lvl}: mean predicted {sum(b) / len(b):.2f}  (n={len(b)})")


def choice_report(name, rows, options):
    print(f"\n[{name}] n={len(rows)} accuracy {sum(1 for c, y, _ in rows if c == y) / len(rows):.2f}")
    for thr in (0.5, 0.7, 0.9):
        sub = [(c, y) for c, y, conf in rows if conf >= thr]
        if sub:
            print(f"  confidence >= {thr:.1f}: coverage {len(sub) / len(rows):.2f} "
                  f"accuracy {sum(1 for c, y in sub if c == y) / len(sub):.2f}")
    print("  confusion (rows = label, cols = predicted): " + " ".join(f"{o:>8}" for o in options))
    for y in options:
        print(f"    {y:>8} " + " ".join(f"{sum(1 for c, yy, _ in rows if yy == y and c == o):8d}" for o in options))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--kind", choices=["comments", "do", "all"], default="all")
    ap.add_argument("--no-language-notes", action="store_true")
    ap.add_argument("--jobs", type=int, default=8)
    ap.add_argument("--model", default=jc.DEFAULT_MODEL)
    a = ap.parse_args()
    corpus = json.loads(CORPUS.read_text())

    if a.kind in ("comments", "all"):
        items = corpus["comments"]
        states = [jc.comment_state({"file": it["origin"].split(":")[0], **it}) for it in items]
        res = asyncio.run(jc.ask_all([(s, jc.COMMENT_QUESTIONS) for s in states], a.model, a.jobs, True))
        ans = [res[jc.cache_key(a.model, s, jc.COMMENT_QUESTIONS)]["answers"] for s in states]
        print(f"== comments: {len(items)} items ==")
        # Rows carry different label sets: the fresh stratified draw is labeled
        # for `ephemeral` only. Each report runs over the rows that carry what it
        # needs, so an unlabeled row is absent rather than counted as a negative.
        def labeled(q):
            return [(x, it) for x, it in zip(ans, items) if q in it["labels"]]
        for q in ("history", "ephemeral", "offsite"):
            noul_report(q, [(x[q]["noul"], it["labels"][q] == "y") for x, it in labeled(q)])
        score_report("register", [(x["register"]["score"], it["labels"]["register"]) for x, it in labeled("register")])
        # The regex baselines can only be computed where the census classes were
        # recorded; `regex_census: null` means "not computed", not "no hits".
        rx = [it for it in items if it.get("regex_census") is not None]
        p, r, f, tp, fp, fn = prf([(1.0 if "history" in it["regex_census"] else 0.0,
                                    it["labels"]["history"] == "y") for it in rx if "history" in it["labels"]], 0.5)
        print(f"\n[regex census 'history' class, {len(rx)} rows with a census] precision {p:.2f} recall {r:.2f} F1 {f:.2f}")
        p, r, f, *_ = prf([(1.0 if any(c in it["regex_census"] for c in ("draft", "deictic", "ruling")) else 0.0,
                            it["labels"]["ephemeral"] == "y") for it in rx if "ephemeral" in it["labels"]], 0.5)
        print(f"[regex census draft+deictic+ruling vs 'ephemeral' label] precision {p:.2f} recall {r:.2f} F1 {f:.2f}")
        print("\nlargest disagreements:")
        for q in ("history", "ephemeral", "offsite"):
            bad = sorted(((abs(x[q]["noul"] - (1.0 if it["labels"][q] == "y" else 0.0)), it["id"], x[q]["noul"], it["labels"][q])
                          for x, it in labeled(q)), reverse=True)[:4]
            print(f"  {q}: " + ", ".join(f"{i} jev={p_:.2f} label={y}" for _, i, p_, y in bad))

    if a.kind in ("do", "all"):
        items = corpus["do"]
        states = [jc.do_state({"file": it["origin"].split(":")[0], **it}, not a.no_language_notes) for it in items]
        res = asyncio.run(jc.ask_all([(s, jc.DO_QUESTIONS) for s in states], a.model, a.jobs, True))
        ans = [res[jc.cache_key(a.model, s, jc.DO_QUESTIONS)]["answers"] for s in states]
        print(f"\n== do-syntax: {len(items)} items{' (no language notes)' if a.no_language_notes else ''} ==")
        noul_report("uniform_chain", [(x["uniform_chain"]["noul"], it["labels"]["uniform_chain"] == "y") for x, it in zip(ans, items)])
        score_report("readability_gain", [(x["readability_gain"]["score"], it["labels"]["gain"]) for x, it in zip(ans, items)])
        choice_report("recommend", [(x["recommend"]["choice"], it["labels"]["recommend"], x["recommend"]["confidence"]) for x, it in zip(ans, items)],
                      ["convert", "partial", "leave"])
        noul_report("P(convert)+P(partial) vs label != leave",
                    [(x["recommend"]["probabilities"]["convert"] + x["recommend"]["probabilities"]["partial"],
                      it["labels"]["recommend"] != "leave") for x, it in zip(ans, items)])
        print("\ndisagreements on recommend:")
        for x, it in zip(ans, items):
            if x["recommend"]["choice"] != it["labels"]["recommend"]:
                print(f"  {it['id']} {it['origin']}: jev={x['recommend']['choice']} ({x['recommend']['confidence']:.2f}) "
                      f"label={it['labels']['recommend']} chain={x['uniform_chain']['noul']:.2f} gain={x['readability_gain']['score']:.1f}/{it['labels']['gain']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
