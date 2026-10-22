#!/usr/bin/env python3
"""PreToolUse guard: waiting on a PR goes through scripts/pr.sh watch|land.

Hand-rolled PR polls each watch one signal and go silent on the others (a
failed check while a shard still runs, a conflict that appears mid-run, a
merge-queue bounce or lapse). The helper reads all of them in one query and
exits on the first. This denies a Bash or Monitor command that POLLS PR or CI
state; a one-shot read (`gh pr view N --json ...`) passes. Escape hatch for a
poll the helper cannot express: put PR_WAIT_OK=1 in the command.
"""
import json
import re
import sys

PR_READ = re.compile(
    r"gh\s+pr\s+(checks|view|status)\b|statusCheckRollup|isInMergeQueue|mergeQueue"
    r"|mergeStateStatus|check-runs|merge_group|gh\s+run\s+list\b"
)
POLL = re.compile(r"\b(while|until)\b|\bsleep\b|--watch\b|\bwatch\s+-n")

REASON = """Don't hand-roll a PR/CI poll; it misses whatever it isn't looking for.
Use the one waiter, as a single background Bash call (you are re-invoked when it exits):
  sh scripts/pr.sh watch --number N   # until required CI is green on the head
  sh scripts/pr.sh land  --number N   # arm auto-merge, until merged + on main
It exits on the FIRST of: RED(1) CONFLICT(2) QUEUE_FAILED(3) HEAD_MOVED(4) CLOSED(5)
STUCK(6) TIMEOUT(7) NOT_ON_MAIN(8) ERROR(9), or 0 = GREEN/MERGED, and prints a
`verdict:` line with `next:` steps. A subagent runs it in the foreground with
--timeout 540 and re-runs on 7. One-shot reads (no loop/sleep) are allowed. If
the helper truly cannot express this poll, add PR_WAIT_OK=1 to the command.
See docs/ops/PR-HELPER.md."""


def main():
    try:
        data = json.load(sys.stdin)
    except ValueError:
        return 0
    tool_input = data.get("tool_input") or {}
    cmd = tool_input.get("command") or ""
    if not isinstance(cmd, str) or not cmd:
        return 0
    if "pr.sh" in cmd or "PR_WAIT_OK=1" in cmd:
        return 0
    if not PR_READ.search(cmd):
        return 0
    if data.get("tool_name") != "Monitor" and not POLL.search(cmd):
        return 0
    json.dump(
        {
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": REASON,
            }
        },
        sys.stdout,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
