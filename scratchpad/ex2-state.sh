#!/bin/sh
# EX-2: establish state
cd /root/medaka/.claude/worktrees/giggly-tinkering-rainbow || exit 1
BASE=$(git rev-parse 2b9dc798)
echo "BASE=$BASE"
echo "HEAD=$(git rev-parse HEAD)"
echo "--- files changed BASE..HEAD (numstat) ---"
git diff --numstat "$BASE"..HEAD
echo "--- any compiler/backend or seed touched? ---"
git diff --name-only "$BASE"..HEAD -- compiler/backend compiler/seed compiler/ir runtime stdlib
echo "(empty above = none)"
echo "--- seed identity ---"
ls -l compiler/seed/emitter.ll.gz
git log --oneline -1 -- compiler/seed/emitter.ll.gz
md5sum compiler/seed/emitter.ll.gz
gzip -dc compiler/seed/emitter.ll.gz | wc -c
gzip -dc compiler/seed/emitter.ll.gz | md5sum
echo "--- srcstamp ---"
cat .medaka_emitter.srcstamp
