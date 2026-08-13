#!/bin/sh
# EX-2: two-pass seed re-mint, with identity measured between passes.
cd /root/medaka/.claude/worktrees/giggly-tinkering-rainbow || exit 1
SEED=compiler/seed/emitter.ll.gz
cp "$SEED" scratchpad/seed-pre.ll.gz
echo "=== pre-remint seed ==="
ls -l "$SEED"; md5sum "$SEED"
gzip -dc "$SEED" > scratchpad/seed-pre.ll; wc -c < scratchpad/seed-pre.ll

for p in 1 2; do
  echo "=== refresh_seed pass $p ==="
  S=$(date +%s)
  sh test/refresh_seed.sh > "scratchpad/remint-$p.log" 2>&1
  rc=$?
  E=$(date +%s)
  echo "pass $p exit=$rc wall_s=$((E-S))"
  tail -2 "scratchpad/remint-$p.log"
  cp "$SEED" "scratchpad/seed-p$p.ll.gz"
  gzip -dc "$SEED" > "scratchpad/seed-p$p.ll"
  echo "gz bytes: $(wc -c < "$SEED")  raw bytes: $(wc -c < scratchpad/seed-p$p.ll)"
  md5sum "$SEED"
  md5sum "scratchpad/seed-p$p.ll"
  [ "$rc" = 0 ] || { echo "ABORT: pass $p failed"; exit 1; }
done

echo "=== pass1 vs pass2 RAW IR identity ==="
if cmp -s scratchpad/seed-p1.ll scratchpad/seed-p2.ll; then
  echo "IDENTICAL: second re-mint produced byte-identical raw IR (idempotent on this diff)"
else
  echo "DIFFERENT: second re-mint changed the raw IR (non-idempotence reproduced)"
  cmp scratchpad/seed-p1.ll scratchpad/seed-p2.ll | head -3
  diff scratchpad/seed-p1.ll scratchpad/seed-p2.ll | head -20 > scratchpad/seed-p1-p2.diff
  diff scratchpad/seed-p1.ll scratchpad/seed-p2.ll | wc -l
fi
echo "=== pre vs pass2 RAW IR ==="
cmp -s scratchpad/seed-pre.ll scratchpad/seed-p2.ll && echo "pre == p2 (no drift after all)" || echo "pre != p2 (seed WAS lagging; now current)"
echo "raw line counts: pre=$(wc -l < scratchpad/seed-pre.ll) p1=$(wc -l < scratchpad/seed-p1.ll) p2=$(wc -l < scratchpad/seed-p2.ll)"
