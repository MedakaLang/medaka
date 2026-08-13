#!/bin/sh
# EX-2: run the fixpoint, timed, exit code recorded. $1 = label
cd /root/medaka/.claude/worktrees/giggly-tinkering-rainbow || exit 1
LBL="${1:-pre}"
S=$(date +%s)
sh test/selfcompile_fixpoint.sh > "scratchpad/fixpoint-$LBL.log" 2>&1
rc=$?
E=$(date +%s)
echo "exit=$rc wall_s=$((E-S))" > "scratchpad/fixpoint-$LBL.rc"
echo "fixpoint-$LBL done: exit=$rc wall_s=$((E-S))"
