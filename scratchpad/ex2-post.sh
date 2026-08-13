#!/bin/sh
# EX-2 post-remint certification: strict byte-currency, then the fixpoint.
cd /root/medaka/.claude/worktrees/giggly-tinkering-rainbow || exit 1

echo "=== make bootstrap (STRICT byte-currency; OUT into scratchpad, tree emitter untouched) ==="
S=$(date +%s)
SEED_STRICT=1 sh test/bootstrap_from_seed.sh scratchpad/emitter_from_seed strict \
  > scratchpad/bootstrap-strict.log 2>&1
rc=$?
E=$(date +%s)
echo "bootstrap-strict exit=$rc wall_s=$((E-S))"
grep -E 'C3a|BOOTSTRAP-FROM-SEED' scratchpad/bootstrap-strict.log

echo "=== selfcompile_fixpoint (post-remint) ==="
S=$(date +%s)
sh test/selfcompile_fixpoint.sh > scratchpad/fixpoint-post.log 2>&1
rc2=$?
E=$(date +%s)
echo "fixpoint-post exit=$rc2 wall_s=$((E-S))"
cat scratchpad/fixpoint-post.log
