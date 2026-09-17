#!/usr/bin/env python3
"""Jev style census: judgment-class style findings over Medaka source.

Code enumerates candidates (comment blocks; declarations that thread Result or
Option by hand), TypeSafe's Jev model answers narrow typed questions about each
one, and this script ranks the answers into a roadmap an agent or a person can
act on. It sits between `medaka lint` (mechanical, exact, gated) and a full LLM
style pass (slow, expensive): a few hundred milliseconds and a few thousand
tokens per candidate, cents for the whole tree.

A CENSUS, NOT A GATE. It calls an external API and its answers are calibrated
probabilities, not verdicts. Always exits 0. Never enrol it in test/gates.toml.

The question set and its measured precision live in docs/design/JEV-DESIGN.md;
scripts/jev/jev_eval.py re-measures them against scripts/jev/eval_corpus.json
whenever a question changes. Change a question here, run the eval, then read
the numbers before trusting the new ranking.

Usage:
  python3 scripts/jev/jev_census.py                    # compiler/ + stdlib/
  python3 scripts/jev/jev_census.py compiler/tools     # one directory
  python3 scripts/jev/jev_census.py --changed origin/main   # diff-scoped
  python3 scripts/jev/jev_census.py --kind do --top 40
  python3 scripts/jev/jev_census.py --dry-run          # enumerate only, no API

Needs: `pip install typesafe-sdk` (or TYPESAFE_SDK_PATH pointing at a
--target install) and TYPESAFE_API_KEY in the environment or in
~/.config/typesafe/api_key. Answers are cached under .jev-cache/ by content
hash, so a rerun after an edit re-asks only what changed.
"""
from __future__ import annotations

import argparse
import asyncio
import hashlib
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CACHE = ROOT / ".jev-cache"
DEFAULT_MODEL = os.environ.get("TYPESAFE_DEFAULT_MODEL", "jev-latest")

# ---------------------------------------------------------------------------
# Questions. Plain dicts so they hash into the cache key; SDK objects are built
# at call time. Question ids are for code only and are not sent to the model.
# ---------------------------------------------------------------------------
COMMENT_POLICY = (
    "A source comment should state a constraint or fact that the code itself "
    "cannot show. History (what the code used to be, when or why it changed, "
    "which issue or pull request decided it), litigation of a decision, and "
    "prose addressed to a code reviewer belong on the issue tracker or in a "
    "design document, not in the source, because they stop being true or "
    "useful once the change lands."
)

COMMENT_QUESTIONS = {
    "history": {
        "type": "noul",
        "instructions": (
            "Does `comment` narrate history or provenance, such as what the code "
            "used to be, when or why it changed, or which issue or pull request "
            "decided it, rather than only stating a constraint or fact about the "
            "code as it is now? Judge only the comment's own sentences."
        ),
        "criteria": {
            "true": "A substantial part of the comment is about the past: a former "
                    "shape, a date, a sequence of changes, or who decided what.",
            "false": "The comment describes the present code, its invariants, its "
                     "contract, or why it must stay as it is, without recounting "
                     "history. A bare issue number as a pointer does not count.",
        },
    },
    "reviewer": {
        "type": "noul",
        "instructions": (
            "Is `comment` written for a code reviewer or narrating a change in "
            "progress, rather than written for a future maintainer reading the "
            "code? Signs: 'this PR', 'this slice', 'this unit', 'before this "
            "slice', 'earlier cut', 'earlier draft', 'this comment used to say', "
            "'measured on this diff' or 'on this branch', 'see the report's "
            "Notes', 'refuted', 'ratified', 'the reviewer asked', or a defense of "
            "a choice against an objection."
        ),
        "criteria": {
            "true": "The comment addresses a reviewer, refers to the change under "
                    "review or the sprint slice as a moving thing, narrates its own "
                    "drafts, or argues against an objection.",
            "false": "The comment is written to whoever reads the code later and "
                     "makes sense with no pull request, slice, or review in view.",
        },
    },
    "offsite": {
        "type": "noul",
        "instructions": (
            "Given `policy`, would the content of `comment` belong on an issue "
            "tracker or in a design document rather than in the source file, "
            "because it argues, litigates, or records a decision at length "
            "instead of stating the constraint the code must satisfy?"
        ),
        "criteria": {
            "true": "Most of the comment is argument, rationale history, or a "
                    "record of deliberation that a maintainer does not need in "
                    "order to edit the code safely.",
            "false": "The comment is the constraint itself, or a short pointer to "
                     "where the rationale lives.",
        },
    },
    "register": {
        "type": "score",
        "instructions": (
            "Given `policy`, rate how well `comment` fits the register of a "
            "source comment."
        ),
        "criteria": [
            "States a constraint or fact the code cannot show, concisely, with "
            "at most a pointer to where rationale lives",
            "Mostly constraint, with some history, narration, or argument mixed in",
            "Mostly history, provenance, or argument, with the actual constraint "
            "hard to find or stated only in passing",
            "Entirely history, litigation, or reviewer-addressed prose with no "
            "constraint a maintainer could act on",
        ],
    },
}

DO_LANGUAGE_NOTES = (
    "Medaka is a strict functional language with Haskell-like syntax. "
    "`Option a = Some a | None` and `Result e a = Ok a | Err e` are both "
    "monads: `andThen : m a -> (a -> m b) -> m b` and `pure`. `match e` "
    "followed by indented `Pattern => body` arms is pattern matching. "
    "`do` notation is sugar over `andThen`/`pure`: a line `x <- e` binds the "
    "success payload of `e` and short-circuits on `None`/`Err`; `let x = e` is a "
    "pure binding; the last line is the result. So a nested match that "
    "propagates every failure unchanged, like\n"
    "  match step1 x\n"
    "    Err e => Err e\n"
    "    Ok a => match step2 a\n"
    "      Err e => Err e\n"
    "      Ok b => step3 b\n"
    "is exactly\n"
    "  do\n"
    "    a <- step1 x\n"
    "    b <- step2 a\n"
    "    step3 b\n"
    "A `do` block replaces matches whose failure arm returns the failure "
    "unchanged (`Err e => Err e`, `None => None`). When every failure arm does "
    "the SAME thing but not a plain propagation (all `Err e => dieMsg e`, or "
    "all `None => False`), the chain still converts: the binds go in a `do` and "
    "the shared handler wraps it once, e.g. `withDefault False (do ...)` or "
    "`match (do ...)` with one `Err e => dieMsg e` arm; a per-step message is "
    "`x <- mapErr (e => \"context: \\{e}\") step`. A failure arm that differs "
    "from the others in what it does, or a chain mixing Option and Result, "
    "stays a match. Effectful steps like `readFile` are fine inside `do`; "
    "the compiler itself does this:\n"
    "  do\n"
    "    rsrc <- readPreludeFile rtPath\n"
    "    csrc <- readPreludeFile corePath\n"
    "    tsrc <- readFile input\n"
    "    match parseResult tsrc\n"
    "      Err e => Err (ppParseError tsrc input e)\n"
    "      Ok _ => ...\n"
    "where the last step stays an explicit match because its failure arm "
    "re-renders the error rather than propagating it."
)

DO_QUESTIONS = {
    "uniform_chain": {
        "type": "noul",
        "instructions": (
            "In `declaration`, are there two or more successive matches over "
            "the same monad (all Result or all Option) whose failure arms all "
            "do the same thing (the same expression modulo the error variable "
            "or message text, such as `Err e => dieMsg e` at every level, or "
            "`None => False` at every level) and whose success payload feeds "
            "the next step?"
        ),
        "criteria": {
            "true": "At least two successive levels share one failure handler "
                    "shape and thread the success value, so the levels could be "
                    "written as a do block with the handler applied once.",
            "false": "Fewer than two such levels, the failure arms differ in what "
                     "they do, the levels mix Option and Result, or the matches "
                     "are dispatch or fallback rather than a chain.",
        },
    },
    "readability_gain": {
        "type": "score",
        "instructions": (
            "How much would rewriting the failure-propagating matches in "
            "`declaration` as a `do` block improve its readability?"
        ),
        "criteria": [
            "No gain: the code is already flat, or a do block would not be "
            "shorter or clearer",
            "Small gain: one level of nesting would be removed",
            "Clear gain: two or more nesting levels would collapse into a linear "
            "sequence of binds",
            "Large gain: a deep pyramid would become a short linear do block",
        ],
    },
    "recommend": {
        "type": "choice",
        "instructions": (
            "What should a maintainer do with `declaration` regarding `do` "
            "notation?"
        ),
        "criteria": {
            "convert": "Rewrite the whole chain as a do block (with mapErr or a "
                       "single outer handler if the failure arms need one); it "
                       "is equivalent and clearly more readable",
            "partial": "Some levels form a chain worth putting in a do block, "
                       "but other matches in the declaration must stay explicit "
                       "because their failure arms do something different",
            "leave": "Leave it: the matches are dispatch or fallback rather "
                     "than a chain, only one or two shallow levels share a "
                     "handler, or a do block would not read better",
        },
    },
}


def comment_state(item: dict) -> dict:
    return {"policy": COMMENT_POLICY, "file": item["file"],
            "comment": item["comment"], "code_after": item["code_after"]}


def do_state(item: dict, language_notes: bool = True) -> dict:
    s = {"file": item["file"], "declaration": item["source"]}
    if language_notes:
        s["language_notes"] = DO_LANGUAGE_NOTES
    return s


# ---------------------------------------------------------------------------
# Candidate enumeration. Loose on purpose: recall over precision, the judgment
# is the model's job. Same shapes the POC measured (docs/design/JEV-DESIGN.md).
# ---------------------------------------------------------------------------
COMMENT_RE = re.compile(r"^(\s*)--(.*)$")
DECL_SKIP_RE = re.compile(
    r"^(import|export data|data|export interface|interface|export impl|impl|type|export type)\b")
FAIL_ARM_RE = re.compile(r"^\s*(Err\s+\w+|Err\s+_|None)\s*=>", re.M)
OK_ARM_RE = re.compile(r"^\s*(Ok\s+|Some\s+)", re.M)
MAX_DECL_LINES = 120


def enumerate_file(rel: str, text: str) -> tuple[list[dict], list[dict], int]:
    lines = text.splitlines()
    n = len(lines)
    comments, decls, skipped = [], [], 0

    i = 0
    while i < n:
        m = COMMENT_RE.match(lines[i])
        if not m or lines[i].lstrip().startswith("-- lint-disable"):
            i += 1
            continue
        indent = m.group(1)
        start = i
        while i < n and (m2 := COMMENT_RE.match(lines[i])) and m2.group(1) == indent:
            i += 1
        block = lines[start:i]
        if len(block) < 2:
            continue  # one-liners are rarely a register problem; keeps cost down
        j, code = i, []
        while j < n and len(code) < 30:
            if lines[j].strip() == "" and code:
                break
            if COMMENT_RE.match(lines[j]) and code:
                break
            if lines[j].strip() != "":
                code.append(lines[j])
            j += 1
        comments.append({"kind": "comment", "id": f"{rel}:{start + 1}", "file": rel,
                         "line": start + 1, "lines": len(block),
                         "comment": "\n".join(block), "code_after": "\n".join(code)})

    starts = [k for k, l in enumerate(lines)
              if l and not l[0].isspace() and not l.startswith("--") and not l.startswith("{-")]
    for idx, s in enumerate(starts):
        e = starts[idx + 1] if idx + 1 < len(starts) else n
        body = lines[s:e]
        while body and (body[-1].strip() == "" or body[-1].lstrip().startswith("--")):
            body.pop()
        if not body or DECL_SKIP_RE.match(body[0]):
            continue
        src = "\n".join(body)
        if re.search(r"\bdo\s*$", src, re.M):
            continue
        nested = (len(re.findall(r"\bmatch\b", src)) >= 2
                  and len(FAIL_ARM_RE.findall(src)) >= 2 and len(OK_ARM_RE.findall(src)) >= 2)
        chain = len(re.findall(r"\bandThen\b", src)) >= 2
        if not (nested or chain):
            continue
        if len(body) > MAX_DECL_LINES:
            skipped += 1
            continue
        name = re.match(r"^([A-Za-z_][A-Za-z0-9_']*)", body[0])
        decls.append({"kind": "do", "id": f"{rel}:{s + 1}", "file": rel, "line": s + 1,
                      "name": name.group(1) if name else body[0][:30],
                      "lines": len(body), "source": src})
    return comments, decls, skipped


def target_files(paths: list[str], changed: str | None) -> list[str]:
    if changed:
        out = subprocess.run(["git", "-C", str(ROOT), "diff", "--name-only", changed, "--", "*.mdk"],
                             capture_output=True, text=True, check=True).stdout.split()
        return sorted(f for f in out if not f.endswith("_test.mdk") and (ROOT / f).exists())
    if not paths:
        paths = ["compiler", "stdlib"]
    files: list[str] = []
    for p in paths:
        pp = (ROOT / p) if not os.path.isabs(p) else Path(p)
        if pp.is_dir():
            out = subprocess.run(["git", "-C", str(ROOT), "ls-files", f"{pp.relative_to(ROOT)}/*.mdk"],
                                 capture_output=True, text=True, check=True).stdout.split()
            files.extend(out)
        elif pp.is_file():
            files.append(str(pp.relative_to(ROOT)) if pp.is_relative_to(ROOT) else str(pp))
    return sorted(set(f for f in files if not f.endswith("_test.mdk")))


# ---------------------------------------------------------------------------
# Asking, with a content-hash cache and bounded concurrency.
# ---------------------------------------------------------------------------
def load_sdk():
    extra = os.environ.get("TYPESAFE_SDK_PATH")
    if extra:
        sys.path.insert(0, extra)
    try:
        import typesafe_sdk  # noqa: F401
    except ImportError:
        sys.exit("typesafe_sdk not importable: `pip install typesafe-sdk`, or set "
                 "TYPESAFE_SDK_PATH to a `pip install --target` directory")
    return sys.modules["typesafe_sdk"]


def api_key() -> str:
    key = os.environ.get("TYPESAFE_API_KEY")
    if not key:
        f = Path.home() / ".config" / "typesafe" / "api_key"
        if f.exists():
            key = f.read_text().strip()
    if not key:
        sys.exit("no TYPESAFE_API_KEY in the environment and no ~/.config/typesafe/api_key")
    return key


def build_questions(sdk, spec: dict) -> dict:
    out = {}
    for qid, q in spec.items():
        if q["type"] == "noul":
            crit = q.get("criteria")
            out[qid] = sdk.Noul(instructions=q["instructions"],
                                criteria=sdk.NoulCriteria(true=crit["true"], false=crit["false"]) if crit else None)
        elif q["type"] == "choice":
            out[qid] = sdk.Choice(instructions=q["instructions"], criteria=q["criteria"])
        else:
            out[qid] = sdk.Score(instructions=q["instructions"], criteria=q["criteria"])
    return out


def cache_key(model: str, state: dict, spec: dict) -> str:
    blob = json.dumps({"model": model, "state": state, "questions": spec}, sort_keys=True)
    return hashlib.sha256(blob.encode()).hexdigest()


def answer_to_json(a) -> dict:
    if hasattr(a, "noul"):
        return {"type": "noul", "noul": a.noul}
    if hasattr(a, "choice"):
        return {"type": "choice", "choice": a.choice, "confidence": a.confidence,
                "probabilities": dict(a.probabilities)}
    return {"type": "score", "score": a.score, "confidence": a.confidence,
            "probabilities": {str(k): v for k, v in a.probabilities.items()}}


async def ask_all(items: list[tuple[dict, dict]], model: str, jobs: int, quiet: bool) -> dict[str, dict]:
    """items: (state, question spec) pairs. Returns {cache_key: result}."""
    sdk = load_sdk()
    CACHE.mkdir(exist_ok=True)
    results: dict[str, dict] = {}
    todo = []
    for state, spec in items:
        k = cache_key(model, state, spec)
        f = CACHE / f"{k}.json"
        if f.exists():
            results[k] = json.loads(f.read_text())
        else:
            todo.append((k, state, spec))
    if not quiet:
        print(f"{len(items)} candidates, {len(results)} cached, {len(todo)} to ask", file=sys.stderr)
    if not todo:
        return results

    retry = sdk.RetryPolicy(max_retries=4, http_statuses={429, 500, 502, 503, 504})
    sem = asyncio.Semaphore(jobs)
    done = 0
    t0 = time.perf_counter()

    async with sdk.AsyncTypeSafeClient(api_key=api_key(), retry=retry, timeout=120.0) as client:
        async def one(k, state, spec):
            nonlocal done
            async with sem:
                resp = await client.system_one(state=state, questions=build_questions(sdk, spec), model=model)
            res = {"answers": {qid: answer_to_json(a) for qid, a in resp.answers.items()},
                   "model": resp.model,
                   "usage": {"input": resp.usage.input_tokens, "output": resp.usage.output_tokens}}
            (CACHE / f"{k}.json").write_text(json.dumps(res))
            results[k] = res
            done += 1
            if not quiet and done % 100 == 0:
                print(f"  {done}/{len(todo)} ({time.perf_counter() - t0:.0f}s)", file=sys.stderr)
        await asyncio.gather(*(one(*t) for t in todo))
    if not quiet:
        print(f"asked {len(todo)} in {time.perf_counter() - t0:.1f}s", file=sys.stderr)
    return results


# ---------------------------------------------------------------------------
# Report.
# ---------------------------------------------------------------------------
def rank_comments(rows: list[dict]) -> list[dict]:
    return sorted(rows, key=lambda r: (-r["register"], -r["offsite"], -r["history"]))


def rank_do(rows: list[dict]) -> list[dict]:
    return sorted(rows, key=lambda r: (-r["actionable"], -r["gain"]))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("paths", nargs="*", help="files or directories (default: compiler stdlib)")
    ap.add_argument("--changed", metavar="REF", help="only .mdk files changed since REF")
    ap.add_argument("--kind", choices=["comments", "do", "all"], default="all")
    ap.add_argument("--top", type=int, default=25, help="rows per ranked table")
    ap.add_argument("--json", metavar="OUT", help="write every candidate's answers to OUT")
    ap.add_argument("--jobs", type=int, default=8, help="concurrent requests")
    ap.add_argument("--model", default=DEFAULT_MODEL)
    ap.add_argument("--min-lines", type=int, default=2, help="skip comment blocks shorter than this")
    ap.add_argument("--dry-run", action="store_true", help="enumerate candidates, ask nothing")
    ap.add_argument("--quiet", action="store_true")
    a = ap.parse_args()

    files = target_files(a.paths, a.changed)
    comments, decls, skipped = [], [], 0
    for rel in files:
        c, d, s = enumerate_file(rel, (ROOT / rel).read_text())
        comments += [x for x in c if x["lines"] >= a.min_lines]
        decls += d
        skipped += s
    if a.kind == "comments":
        decls = []
    if a.kind == "do":
        comments = []
    print(f"jev census: {len(files)} files, {len(comments)} comment blocks, "
          f"{len(decls)} do-syntax candidates ({skipped} skipped over {MAX_DECL_LINES} lines)")
    if a.dry_run:
        return 0

    items = [(comment_state(c), COMMENT_QUESTIONS) for c in comments] + \
            [(do_state(d), DO_QUESTIONS) for d in decls]
    results = asyncio.run(ask_all(items, a.model, a.jobs, a.quiet))

    tok_in = sum(r["usage"]["input"] or 0 for r in results.values())
    tok_out = sum(r["usage"]["output"] or 0 for r in results.values())
    print(f"tokens: {tok_in} in, {tok_out} out (cached answers included)")

    crow, drow = [], []
    for c in comments:
        ans = results[cache_key(a.model, comment_state(c), COMMENT_QUESTIONS)]["answers"]
        crow.append({**c, "register": ans["register"]["score"], "history": ans["history"]["noul"],
                     "offsite": ans["offsite"]["noul"], "reviewer": ans["reviewer"]["noul"],
                     "register_confidence": ans["register"]["confidence"]})
    for d in decls:
        ans = results[cache_key(a.model, do_state(d), DO_QUESTIONS)]["answers"]
        p = ans["recommend"]["probabilities"]
        drow.append({**d, "actionable": p["convert"] + p["partial"], "recommend": ans["recommend"]["choice"],
                     "recommend_confidence": ans["recommend"]["confidence"],
                     "chain": ans["uniform_chain"]["noul"], "gain": ans["readability_gain"]["score"]})

    if crow:
        print(f"\n== comment register: top {a.top} of {len(crow)} by register score (0 constraint .. 3 pure history) ==")
        print(f"{'reg':>4} {'hist':>4} {'off':>4} {'rev':>4} {'ln':>3}  site")
        for r in rank_comments(crow)[:a.top]:
            print(f"{r['register']:4.1f} {r['history']:4.2f} {r['offsite']:4.2f} {r['reviewer']:4.2f} {r['lines']:3d}  {r['id']}")
        hi = sum(1 for r in crow if r["register"] >= 2.0)
        print(f"blocks at register >= 2.0: {hi} of {len(crow)}; "
              f"reviewer-addressed >= 0.5: {sum(1 for r in crow if r['reviewer'] >= 0.5)}")
    if drow:
        print(f"\n== do-syntax: top {a.top} of {len(drow)} by P(convert)+P(partial) ==")
        print(f"{'act':>4} {'chain':>5} {'gain':>4} {'rec':>7} {'ln':>3}  site")
        for r in rank_do(drow)[:a.top]:
            print(f"{r['actionable']:4.2f} {r['chain']:5.2f} {r['gain']:4.1f} {r['recommend']:>7} {r['lines']:3d}  {r['id']} {r['name']}")
        print(f"actionable >= 0.75: {sum(1 for r in drow if r['actionable'] >= 0.75)} of {len(drow)}")

    if a.json:
        strip = {"comment", "code_after", "source"}
        Path(a.json).write_text(json.dumps(
            {"model": a.model, "files": files,
             "comments": [{k: v for k, v in r.items() if k not in strip} for r in rank_comments(crow)],
             "do": [{k: v for k, v in r.items() if k not in strip} for r in rank_do(drow)]},
            indent=1) + "\n")
        print(f"wrote {a.json}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
