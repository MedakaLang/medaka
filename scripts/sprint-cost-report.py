#!/usr/bin/env python3
"""Aggregate Claude Code transcript token usage per model / agent-type / session.

Reads main-session .jsonl files and their subagents/ transcripts from
~/.claude/projects/*, dedupes per API request (message.id), and prints
markdown tables with token counts and estimated cost.

Usage: sprint_cost_report.py --since 2026-08-16T00:00:00 [--match SUBSTR]
"""
import argparse, glob, json, os, sys, datetime
from collections import defaultdict

# $/MTok list prices (verify against docs on reuse). (input, output)
PRICES = {
    "claude-fable-5": (10.0, 50.0),
    "claude-opus-5": (5.0, 25.0),
    "claude-opus-4-8": (5.0, 25.0),
    "claude-sonnet-5": (3.0, 15.0),   # intro $2/$10 through 2026-08-31
    "claude-sonnet-4-6": (3.0, 15.0),
    "claude-haiku-4-5-20251001": (1.0, 5.0),
    "claude-haiku-4-5": (1.0, 5.0),
}
CACHE_READ_MULT = 0.10
CACHE_W5M_MULT = 1.25
CACHE_W1H_MULT = 2.00


def price(model):
    for k, v in PRICES.items():
        if model.startswith(k):
            return v
    return (5.0, 25.0)  # unknown -> opus-tier guess, flagged in output


class Acc:
    __slots__ = ("inp", "out", "cr", "cw5", "cw1", "reqs", "cost", "models")

    def __init__(self):
        self.inp = self.out = self.cr = self.cw5 = self.cw1 = self.reqs = 0
        self.cost = 0.0
        self.models = set()

    def add(self, model, u):
        pi, po = price(model)
        inp = u.get("input_tokens", 0) or 0
        out = u.get("output_tokens", 0) or 0
        cr = u.get("cache_read_input_tokens", 0) or 0
        cc = u.get("cache_creation", {}) or {}
        cw5 = cc.get("ephemeral_5m_input_tokens")
        cw1 = cc.get("ephemeral_1h_input_tokens", 0) or 0
        if cw5 is None:
            cw5 = u.get("cache_creation_input_tokens", 0) or 0
            cw1 = 0
        self.inp += inp; self.out += out; self.cr += cr
        self.cw5 += cw5; self.cw1 += cw1; self.reqs += 1
        self.models.add(model)
        self.cost += (inp * pi + cr * CACHE_READ_MULT * pi
                      + cw5 * CACHE_W5M_MULT * pi + cw1 * CACHE_W1H_MULT * pi
                      + out * po) / 1e6


SEEN_GLOBAL = set()  # message.id dedupe across resumed/copied sessions


def requests_of(jsonl_path):
    """Yield (model, usage, ts) one per API request (dedup by message.id)."""
    best = {}
    order = []
    try:
        with open(jsonl_path) as f:
            for line in f:
                try:
                    d = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if d.get("type") != "assistant":
                    continue
                m = d.get("message") or {}
                u = m.get("usage")
                if not u:
                    continue
                mid = m.get("id") or d.get("requestId") or d.get("uuid")
                if mid not in best:
                    order.append(mid)
                cur = best.get(mid)
                if cur is None or (u.get("output_tokens", 0) or 0) >= (cur[1].get("output_tokens", 0) or 0):
                    best[mid] = (m.get("model", "?"), u, d.get("timestamp"))
    except OSError:
        return
    for mid in order:
        if mid in SEEN_GLOBAL:
            continue
        SEEN_GLOBAL.add(mid)
        yield best[mid]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--since", required=True)
    ap.add_argument("--until", default=None)
    ap.add_argument("--projects-root", default=os.path.expanduser("~/.claude/projects"))
    ap.add_argument("--match", default="", help="substring filter on project dir name")
    ap.add_argument("--session", action="append", default=[],
                    help="only sessions whose label or id contains this (repeatable). "
                         "A sprint report MUST be scoped this way: the unfiltered "
                         "report pools unrelated sessions into main-session/"
                         "general-purpose, the rows the cost hypotheses are graded on")
    ap.add_argument("--exclude-session", action="append", default=[],
                    help="drop sessions whose label or id contains this (repeatable)")
    args = ap.parse_args()
    since = datetime.datetime.fromisoformat(args.since).timestamp()
    until = datetime.datetime.fromisoformat(args.until).timestamp() if args.until else float("inf")

    by_type = defaultdict(Acc)          # agent type (or 'main-session')
    by_model = defaultdict(Acc)
    by_session = defaultdict(Acc)       # (proj, session-label)
    agents = []                         # (cost, label, acc) individual subagents

    for proj in sorted(glob.glob(os.path.join(args.projects_root, "*"))):
        if args.match and args.match not in os.path.basename(proj):
            continue
        for sj in glob.glob(os.path.join(proj, "*.jsonl")):
            mt = os.path.getmtime(sj)
            if not (since <= mt <= until):
                continue
            sid = os.path.basename(sj)[:-6]
            slug = None
            try:
                with open(sj) as f:
                    for line in f:
                        if '"slug"' in line:
                            try:
                                slug = json.loads(line).get("slug")
                            except json.JSONDecodeError:
                                pass
                            if slug:
                                break
            except OSError:
                pass
            label = f"{os.path.basename(proj).replace('-root-medaka--claude-worktrees-', 'wt:').replace('-root-medaka', 'medaka')}/{slug or sid[:8]}"
            hay = f"{label} {sid}"
            if args.session and not any(s in hay for s in args.session):
                continue
            if any(s in hay for s in args.exclude_session):
                continue
            for model, u, ts in requests_of(sj):
                by_type["main-session"].add(model, u)
                by_model[model].add(model, u)
                by_session[label].add(model, u)
            subdir = os.path.join(proj, sid, "subagents")
            for aj in glob.glob(os.path.join(subdir, "agent-*.jsonl")):
                meta = {}
                mp = aj[:-6] + ".meta.json"
                if os.path.exists(mp):
                    try:
                        meta = json.load(open(mp))
                    except (OSError, json.JSONDecodeError):
                        pass
                at = meta.get("agentType", "unknown-agent")
                acc = Acc()
                for model, u, ts in requests_of(aj):
                    acc.add(model, u)
                    by_type[at].add(model, u)
                    by_model[model].add(model, u)
                    by_session[label].add(model, u)
                if acc.reqs:
                    desc = (meta.get("description") or "")[:48]
                    agents.append((acc.cost, f"{at}: {desc} [{label}]", acc))

    def row(name, a):
        mm = ",".join(sorted(m.split("-2")[0] if m[0].isdigit() else m for m in a.models))
        tot_in = a.inp + a.cr + a.cw5 + a.cw1
        hit = a.cr / tot_in * 100 if tot_in else 0
        return (f"| {name} | {a.reqs} | {a.inp/1e3:.0f}k | {a.cw5/1e6:.2f}M | {a.cw1/1e6:.2f}M "
                f"| {a.cr/1e6:.1f}M | {hit:.0f}% | {a.out/1e3:.0f}k | ${a.cost:.2f} |")

    hdr = ("| | reqs | input | cache-w 5m | cache-w 1h | cache-read | hit% | output | est cost |\n"
           "|---|---|---|---|---|---|---|---|---|")
    scope = ""
    if args.session:
        scope += f", sessions matching {args.session}"
    if args.exclude_session:
        scope += f", excluding {args.exclude_session}"
    print(f"# Token cost report — sessions modified {args.since} .. "
          f"{args.until or 'now'}{scope or ' (UNFILTERED — not sprint-scoped)'}\n")
    print("## By model\n" + hdr)
    for k in sorted(by_model, key=lambda k: -by_model[k].cost):
        print(row(k, by_model[k]))
    print("\n## By agent type (subagents; 'main-session' = all top-level sessions)\n" + hdr)
    for k in sorted(by_type, key=lambda k: -by_type[k].cost):
        print(row(f"{k} ({','.join(sorted(by_type[k].models))})", by_type[k]))
    print("\n## By session\n" + hdr)
    for k in sorted(by_session, key=lambda k: -by_session[k].cost):
        if by_session[k].cost >= 0.5:
            print(row(k, by_session[k]))
    print("\n## Top 20 individual subagents by est cost\n" + hdr)
    for cost, label, acc in sorted(agents, key=lambda t: -t[0])[:20]:
        print(row(label, acc))
    total = Acc()
    for a in by_model.values():
        total.inp += a.inp; total.out += a.out; total.cr += a.cr
        total.cw5 += a.cw5; total.cw1 += a.cw1; total.reqs += a.reqs; total.cost += a.cost
    print(f"\n**TOTAL: {total.reqs} requests, est ${total.cost:.2f}** "
          f"(input {total.inp/1e6:.1f}M, cache-w {total.cw5/1e6:.1f}M@5m + {total.cw1/1e6:.1f}M@1h, "
          f"cache-r {total.cr/1e6:.0f}M, output {total.out/1e6:.1f}M)")


if __name__ == "__main__":
    main()
