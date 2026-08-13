#!/bin/sh
cd /root/medaka/.claude/worktrees/giggly-tinkering-rainbow || exit 1
before=$(wc -l < .claude/sprint-b/DEBT.md)
cat scratchpad/ex2-row.md >> .claude/sprint-b/DEBT.md
after=$(wc -l < .claude/sprint-b/DEBT.md)
echo "DEBT.md $before -> $after lines"
grep -n '^### `EX-2`' .claude/sprint-b/DEBT.md
git status --porcelain
