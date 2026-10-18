"""Asking the judges: Jev through typesafe_sdk, Haiku and Opus through headless
Claude Code. Every answer is cached by a hash of model + prompt + item content,
so a rerun costs nothing and an edit re-asks only what it changed.

Each cache entry records what obtaining it cost, so the report's cost figures
include answers served from the cache.
"""
from __future__ import annotations

import asyncio
import hashlib
import json
import os
import re
import site
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

HERE = Path(__file__).resolve().parent
CACHE = HERE / ".cache"
ROOT = HERE.parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "jev"))
import jev_census as jc  # noqa: E402

JEV_MODEL = jc.DEFAULT_MODEL
JEV_USD_PER_MTOK_IN = 0.042  # docs.typesafe.ai/models.md; output tokens are free
CLAUDE_MODELS = {"haiku": "claude-haiku-5-5", "opus": "claude-opus-5-5"}
CHARS_PER_TOKEN = 4.0  # only for an estimate when the API reports no token count


def chash(obj) -> str:
    return hashlib.sha256(json.dumps(obj, sort_keys=True).encode()).hexdigest()


def ensure_cache(sub: str = "") -> Path:
    """Create a cache subdirectory. The cache ignores itself (`*` in its own
    .gitignore), so answers derived from an external API are never tracked."""
    CACHE.mkdir(parents=True, exist_ok=True)
    ign = CACHE / ".gitignore"
    if not ign.exists():
        ign.write_text("# Regenerable model answers: never commit.\n*\n")
    d = CACHE / sub
    d.mkdir(parents=True, exist_ok=True)
    return d


def _cache_get(kind: str, key: str) -> dict | None:
    f = CACHE / kind / f"{key}.json"
    return json.loads(f.read_text()) if f.exists() else None


def _cache_put(kind: str, key: str, val: dict) -> None:
    d = ensure_cache(kind)
    tmp = d / f"{key}.tmp{os.getpid()}"
    tmp.write_text(json.dumps(val))
    tmp.replace(d / f"{key}.json")


# ---------------------------------------------------------------------------
# Jev
# ---------------------------------------------------------------------------
def _load_sdk():
    try:
        import typesafe_sdk  # noqa: F401
    except ImportError:
        # `python3 -I` drops the user site, where `pip install --user` puts the SDK.
        sys.path.append(site.getusersitepackages())
    return jc.load_sdk()


def jev_cost(usage: dict, state: dict, questions: dict) -> tuple[float, bool]:
    tin = usage.get("input")
    if tin is None:
        tin = len(json.dumps(state)) / CHARS_PER_TOKEN + len(json.dumps(questions)) / CHARS_PER_TOKEN
        return tin * JEV_USD_PER_MTOK_IN / 1e6, True
    return tin * JEV_USD_PER_MTOK_IN / 1e6, False


def jev_request_key(model: str, state: dict, questions: dict) -> str:
    # Both orders are in `questions`; sort_keys would merge them, so hash the order too.
    return chash({"model": model, "state": state,
                  "questions": {k: [q["instructions"], list(q["criteria"].items())]
                                for k, q in questions.items()}})


async def _jev_all(reqs: list[tuple[str, dict, dict]], model: str, jobs: int) -> dict[str, dict]:
    sdk = _load_sdk()
    out: dict[str, dict] = {}
    todo = []
    for key, state, qs in reqs:
        hit = _cache_get("jev", key)
        if hit is not None:
            out[key] = hit
        else:
            todo.append((key, state, qs))
    print(f"jev: {len(reqs)} requests, {len(out)} cached, {len(todo)} to ask", file=sys.stderr)
    if not todo:
        return out
    retry = sdk.RetryPolicy(max_retries=4, http_statuses={429, 500, 502, 503, 504})
    sem = asyncio.Semaphore(jobs)
    t0 = time.perf_counter()
    async with sdk.AsyncTypeSafeClient(api_key=jc.api_key(), retry=retry, timeout=120.0) as client:
        async def one(key, state, qs):
            built = {qid: sdk.Choice(instructions=q["instructions"], criteria=q["criteria"])
                     for qid, q in qs.items()}
            try:
                async with sem:
                    resp = await client.system_one(state=state, questions=built, model=model)
            except Exception as e:  # noqa: BLE001 -- one failed item must not sink the run
                out[key] = {"error": f"{type(e).__name__}: {e}"}
                return
            usage = {"input": resp.usage.input_tokens, "output": resp.usage.output_tokens}
            cost, est = jev_cost(usage, state, qs)
            res = {"answers": {qid: jc.answer_to_json(a) for qid, a in resp.answers.items()},
                   "model": resp.model, "usage": usage, "cost_usd": cost, "cost_estimated": est}
            _cache_put("jev", key, res)
            out[key] = res
        await asyncio.gather(*(one(*r) for r in todo))
    print(f"jev: asked {len(todo)} in {time.perf_counter() - t0:.1f}s", file=sys.stderr)
    return out


def ask_jev(reqs: list[tuple[str, dict, dict]], model: str = JEV_MODEL, jobs: int = 4) -> dict[str, dict]:
    """reqs: (cache key, state, questions). Returns {key: cached result or {'error'}}."""
    return asyncio.run(_jev_all(reqs, model, jobs))


def jev_p_flag(res: dict) -> float | None:
    """Mean P(flag) over the two option orders."""
    ps = [a["probabilities"]["flag"] for a in res.get("answers", {}).values()
          if a.get("type") == "choice" and "flag" in a.get("probabilities", {})]
    return sum(ps) / len(ps) if ps else None


# ---------------------------------------------------------------------------
# Headless Claude Code (Haiku, Opus)
# ---------------------------------------------------------------------------
NEUTRAL_CWD = CACHE / "cwd"  # empty dir: no CLAUDE.md, memory or MCP config is loaded
# Every benchmark prompt is unique, so Claude Code's one-hour cache write is a
# surcharge with no later read; with it off a fixture-sized Haiku call cost
# about 0.57x as much.
PROMPT_CACHE = False


def claude_request_key(model: str, system: str, user: str) -> str:
    return chash({"model": model, "system": system, "user": user})


def parse_verdict(text: str) -> dict | None:
    t = text.strip()
    t = re.sub(r"^```(?:json)?\s*|\s*```$", "", t)
    braced = t[t.find("{"): t.rfind("}") + 1] if "{" in t else ""
    # A quoted Medaka interpolation (`\{e}`) is not a JSON escape; double its backslash.
    lenient = re.sub(r'\\(?![\\"/bfnrtu])', r"\\\\", braced)
    for cand in (t, braced, lenient):
        try:
            v = json.loads(cand)
        except (json.JSONDecodeError, ValueError):
            continue
        if isinstance(v, dict) and "flag" in v:
            return {"flag": bool(v.get("flag")), "confidence": float(v.get("confidence") or 0.0),
                    "evidence_quote": str(v.get("evidence_quote") or ""),
                    "reason": str(v.get("reason") or "")}
    # Unescaped quotes inside a string field: the flag and confidence still read cleanly.
    flag = re.search(r'"flag"\s*:\s*(true|false)', t)
    if flag:
        conf = re.search(r'"confidence"\s*:\s*([0-9.]+)', t)
        quote = re.search(r'"evidence_quote"\s*:\s*"((?:[^"\\]|\\.)*)"', t)
        reason = re.search(r'"reason"\s*:\s*"(.*)"\s*}\s*$', t, re.S)
        return {"flag": flag.group(1) == "true", "confidence": float(conf.group(1)) if conf else 0.0,
                "evidence_quote": quote.group(1) if quote else "",
                "reason": reason.group(1) if reason else ""}
    return None


def _claude_one(model: str, system: str, user: str, timeout: int) -> dict:
    ensure_cache(NEUTRAL_CWD.name)
    cmd =["claude", "-p", "--model", model, "--output-format", "json", "--tools", "",
           "--strict-mcp-config", "--no-session-persistence", "--system-prompt", system]
    last = ""
    for _attempt in range(2):
        try:
            # The user turn goes on stdin: an argv string is capped at 128 KiB.
            env = os.environ if PROMPT_CACHE else os.environ | {"DISABLE_PROMPT_CACHING": "1"}
            r = subprocess.run(cmd, cwd=NEUTRAL_CWD, input=user, capture_output=True, text=True,
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
        verdict = parse_verdict(j.get("result") or "")
        return {"verdict": verdict, "raw": (j.get("result") or "")[:4000],
                "parse_error": verdict is None,
                "cost_usd": float(j.get("total_cost_usd") or 0.0),
                "usage": {"input": (u.get("input_tokens") or 0) + (u.get("cache_creation_input_tokens") or 0)
                          + (u.get("cache_read_input_tokens") or 0),
                          "output": u.get("output_tokens") or 0},
                "model": model, "duration_ms": j.get("duration_ms")}
    return {"error": last}


def ask_claude(reqs: list[tuple[str, str, str]], model: str, jobs: int = 4,
               timeout: int = 300) -> dict[str, dict]:
    """reqs: (cache key, system, user). Errors are returned, never cached."""
    out: dict[str, dict] = {}
    todo = []
    for key, system, user in reqs:
        hit = _cache_get("claude", key)
        if hit is not None and hit.get("parse_error"):
            hit["verdict"] = parse_verdict(hit.get("raw") or "")
            hit["parse_error"] = hit["verdict"] is None
        if hit is not None:
            out[key] = hit
        else:
            todo.append((key, system, user))
    print(f"{model}: {len(reqs)} requests, {len(out)} cached, {len(todo)} to ask", file=sys.stderr)
    if not todo:
        return out
    t0 = time.perf_counter()

    def run(t):
        key, system, user = t
        res = _claude_one(model, system, user, timeout)
        if "error" not in res:
            _cache_put("claude", key, res)
        return key, res

    with ThreadPoolExecutor(max_workers=jobs) as pool:
        for n, (key, res) in enumerate(pool.map(run, todo), 1):
            out[key] = res
            if n % 25 == 0:
                print(f"  {n}/{len(todo)} ({time.perf_counter() - t0:.0f}s)", file=sys.stderr)
    print(f"{model}: asked {len(todo)} in {time.perf_counter() - t0:.1f}s", file=sys.stderr)
    return out
