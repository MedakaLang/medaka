"""Per-subagent context usage, for keeping Haiku workers under the 100k tier.

Usage:
    python3 <repo>/.claude/skills/test-conversion-orchestrator/agent_usage.py AGENT_ID [AGENT_ID...]
    python3 <repo>/.claude/skills/test-conversion-orchestrator/agent_usage.py --detail AGENT_ID

AGENT_ID is the `agentId` the Agent tool returned (a unique prefix is enough).
For each agent it prints:
- first: the context on its first call (the fixed startup cost)
- peak: the largest single request, which is the number the pricing tier is about
- out: output tokens
- calls: tool calls
`--detail` adds the size of every tool result in order, which shows what to
cut from the packet or the skill.
"""
import glob
import json
import os
import sys

base = os.environ.get("CLAUDE_CONFIG_DIR", os.path.expanduser("~/.claude"))
args = sys.argv[1:]
detail = "--detail" in args
ids = [a for a in args if a != "--detail"]
if not ids:
    print(__doc__)
    sys.exit(2)

for aid in ids:
    aid = aid.removeprefix("agent-")
    paths = glob.glob(os.path.join(base, "projects", "*", "*", "subagents", f"agent-{aid}*.jsonl"))
    if len(paths) != 1:
        print(f"{aid}: {len(paths)} transcripts match")
        continue
    first = None
    peak = out = calls = 0
    model = "?"
    names = {}
    results = []
    for line in open(paths[0]):
        e = json.loads(line)
        m = e.get("message", {})
        if e.get("type") == "assistant":
            u = m.get("usage", {})
            model = m.get("model", model)
            ctx = u.get("input_tokens", 0) + u.get("cache_read_input_tokens", 0) + u.get("cache_creation_input_tokens", 0)
            first = ctx if first is None else first
            peak = max(peak, ctx)
            out += u.get("output_tokens", 0)
            for c in m.get("content", []):
                if c.get("type") == "tool_use":
                    calls += 1
                    i = c["input"]
                    names[c["id"]] = c["name"] + ": " + str(i.get("command") or i.get("file_path") or "")[:90]
        elif e.get("type") == "user" and isinstance(m.get("content"), list):
            for c in m["content"]:
                if c.get("type") == "tool_result":
                    body = c.get("content")
                    text = body if isinstance(body, str) else "".join(x.get("text", "") for x in body if isinstance(x, dict))
                    results.append((len(text) // 4, names.get(c["tool_use_id"], "?")))
    flag = "  OVER 100k" if peak > 100_000 else ""
    print(f"{aid[:17]} {model} first={first} peak={peak} out={out} calls={calls}{flag}")
    if detail:
        for toks, name in results:
            print(f"  {toks:6d} tok  {name}")
