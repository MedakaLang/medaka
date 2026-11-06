#!/bin/sh
# emit_identity.sh: same-source emit differential between two compiler trees.
#
# Usage:
#   sh scripts/emit_identity.sh <base-tree> <head-tree> <out-dir> --llvm|--wat \
#      [--self] [--plant] [--half N] [corpus-dir ...]
#
# Each tree is an absolute path to a worktree with a built compiler: `medaka_emitter` at
# its root for --llvm (make -C <tree> medaka), test/bin/wasm_emit_modules_main for --wat
# (sh test/wasm/build_wasm_oracle.sh --modules-only). Every input file is taken from
# <head-tree>; each arm emits it with its OWN emitter, runtime.mdk, core.mdk, compiler/
# and stdlib/, so the arms differ only in the compiler that emits.
#
# Corpus dirs are relative to <head-tree> (an absolute one is used as is); default test/engine_fixtures test/dict_fixtures
# (test/wasm/fixtures_modules for --wat). Every *.mdk directly in a corpus dir is an entry;
# for a sub-directory, its main.mdk. --self adds compiler/driver/medaka_cli.mdk. Per entry
# the arms must agree on exit code, stdout and stderr; rejected entries compare stderr.
#
# Tree paths are normalised here (emit_identity_norm.py): the emitted text embeds each
# arm's tree root, which is not a compiler difference. No per-entry carve-out exists.
#
# --half N sets MEDAKA_EMIT_HALF=N on both arms (LLVM prelude-object halves; --llvm only).
# --plant appends one byte to the head arm's output for entry 1 (self-test hook: the run
# must then report DIFFER).
#
# Exit 0 identical, 1 differ (entries listed in <out-dir>/DIFFS, normalised forms in
# <out-dir>/{a,b}.<n>.norm, first differing lines in <out-dir>/<n>.diff), 2 usage.
# JOBS (default 4) bounds parallel emits; the box is shared.
set -u

usage() {
  printf '%s\n' "usage: sh emit_identity.sh <base-tree> <head-tree> <out-dir> --llvm|--wat [--self] [--plant] [--half N] [corpus-dir ...]" >&2
  exit 2
}

[ "$#" -ge 4 ] || usage
A="$1"; B="$2"; OUT="$3"; shift 3
MODE=""; SELF=0; PLANT=0; HALF=""; CORPORA=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --llvm) MODE=llvm ;;
    --wat) MODE=wat ;;
    --self) SELF=1 ;;
    --plant) PLANT=1 ;;
    --half)
      [ "$#" -ge 2 ] || usage
      HALF="$2"; shift ;;
    *) CORPORA="$CORPORA $1" ;;
  esac
  shift
done
[ -n "$MODE" ] || usage
if [ -n "$HALF" ]; then
  [ "$MODE" = llvm ] || usage
  case "$HALF" in 0|1|2) ;; *) usage ;; esac
fi

if [ "$MODE" = llvm ]; then
  EXT=ll
  BIN=medaka_emitter
  HINT="make -C <tree> medaka"
  [ -n "$CORPORA" ] || CORPORA="test/engine_fixtures test/dict_fixtures"
else
  EXT=wat
  BIN=test/bin/wasm_emit_modules_main
  HINT="sh test/wasm/build_wasm_oracle.sh --modules-only"
  [ -n "$CORPORA" ] || CORPORA="test/wasm/fixtures_modules"
fi
JOBS="${JOBS:-4}"

for t in "$A" "$B"; do
  case "$t" in /*) ;; *) printf '%s\n' "emit_identity: tree must be absolute: $t" >&2; exit 2 ;; esac
  if [ ! -x "$t/$BIN" ]; then
    printf '%s\n' "emit_identity: no built $BIN in $t ($HINT)" >&2
    exit 2
  fi
done
# Crossing variables would make both arms the same compiler.
unset MEDAKA_EMITTER MEDAKA_ROOT MEDAKA_STRICT MEDAKA_PRELUDE_OBJ MEDAKA_STAGE_COUNTS MEDAKA_EMIT_HALF 2>/dev/null || true
if [ -n "$HALF" ]; then
  MEDAKA_EMIT_HALF="$HALF"
  export MEDAKA_EMIT_HALF
fi

mkdir -p "$OUT" || exit 2
LIST="$OUT/entries"
: > "$LIST"
: > "$OUT/index"
for c in $CORPORA; do
  case "$c" in /*) d="$c" ;; *) d="$B/$c" ;; esac
  [ -d "$d" ] || { printf '%s\n' "emit_identity: no corpus dir $d" >&2; exit 2; }
  for f in "$d"/*.mdk; do
    [ -f "$f" ] && printf '%s\n' "$f" >> "$LIST"
  done
  for sub in "$d"/*/; do
    [ -f "${sub}main.mdk" ] && printf '%s\n' "${sub}main.mdk" >> "$LIST"
  done
done
[ "$SELF" = 1 ] && printf '%s\n' "$B/compiler/driver/medaka_cli.mdk" >> "$LIST"

# One emit: <bin> <arm-tree> <entry> <out-prefix> <head-tree> <ext>. Roots mirror
# build_cmd.mdk's emitArgsBase: the entry's own dir, the head tree's compiler/ (for
# --self), then compiler/ and stdlib/ of the emitting arm.
cat > "$OUT/emit_one.sh" <<'EOS'
#!/bin/sh
bin="$1"; tree="$2"; entry="$3"; pre="$4"; head="$5"; ext="$6"
dir=$(dirname "$entry")
"$tree/$bin" "$tree/stdlib/runtime.mdk" "$tree/stdlib/core.mdk" "$entry" \
  "$dir" "$head/compiler" "$tree/compiler" "$tree/stdlib" > "$pre.$ext" 2> "$pre.err"
echo $? > "$pre.code"
EOS

n=0
: > "$OUT/jobs"
while IFS= read -r e; do
  n=$((n + 1))
  printf '%s\n' "$BIN $A $e $OUT/a.$n $B $EXT" >> "$OUT/jobs"
  printf '%s\n' "$BIN $B $e $OUT/b.$n $B $EXT" >> "$OUT/jobs"
  printf '%s\n' "$n $e" >> "$OUT/index"
done < "$LIST"
xargs -P "$JOBS" -L 1 sh "$OUT/emit_one.sh" < "$OUT/jobs"

if [ "$PLANT" = 1 ] && [ "$n" -ge 1 ]; then
  printf 'x' >> "$OUT/b.1.$EXT"
fi

: > "$OUT/DIFFS"
bad=0
i=0
while [ "$i" -lt "$n" ]; do
  i=$((i + 1))
  same=1
  cmp -s "$OUT/a.$i.code" "$OUT/b.$i.code" || same=0
  cmp -s "$OUT/a.$i.$EXT" "$OUT/b.$i.$EXT" || same=0
  cmp -s "$OUT/a.$i.err" "$OUT/b.$i.err" || same=0
  [ "$same" = 0 ] && bad=$((bad + 1))
done

if [ "$bad" != 0 ]; then
  TOOLDIR=$(dirname "$0")
  python3 -I "$TOOLDIR/emit_identity_norm.py" "$OUT" "$A" "$B" "$EXT" > "$OUT/norm.out" 2>&1
  nrc=$?
  # The normaliser exits 0 (nothing differs after path normalisation) or 1 (something
  # does) and prints its summary line either way. Anything else means it could not run,
  # which is not evidence of identity, so the raw verdict stands.
  if [ "$nrc" = 0 ] && grep -q '^norm: ' "$OUT/norm.out"; then
    printf '%s\n' "emit_identity: $bad entries differed only in the emitting tree's path (normalised, see $OUT/norm.out)"
    bad=0
  elif [ "$nrc" = 1 ] && grep -q '^norm: ' "$OUT/norm.out"; then
    bad=0
    for k in $(grep '^NORMALISED DIFFER' "$OUT/norm.out" | sed 's/^NORMALISED DIFFER //'); do
      bad=$((bad + 1))
      printf '%s\n' "$k $(sed -n "${k}p" "$LIST")" >> "$OUT/DIFFS"
      diff "$OUT/a.$k.norm" "$OUT/b.$k.norm" | head -20 > "$OUT/$k.diff"
    done
  else
    printf '%s\n' "emit_identity: normaliser could not run (rc=$nrc, see $OUT/norm.out); raw verdict stands" >&2
    i=0
    while [ "$i" -lt "$n" ]; do
      i=$((i + 1))
      if ! cmp -s "$OUT/a.$i.$EXT" "$OUT/b.$i.$EXT"; then
        printf '%s\n' "$i $(sed -n "${i}p" "$LIST")" >> "$OUT/DIFFS"
      fi
    done
  fi
fi
if [ "$bad" = 0 ]; then
  SELFNOTE=""
  [ "$SELF" = 1 ] && SELFNOTE=" + self"
  printf '%s\n' "emit_identity: IDENTICAL on $n entries ($MODE:$CORPORA$SELFNOTE)"
  exit 0
fi
printf '%s\n' "emit_identity: DIFFER on $bad of $n entries; see $OUT/DIFFS"
cat "$OUT/DIFFS"
exit 1
