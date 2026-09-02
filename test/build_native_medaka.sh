#!/bin/sh
# BUILD THE NATIVE `medaka` CLI — OCaml-free.  Two modes, auto-selected:
#
#   WARM (./medaka_emitter present — the day-to-day loop): a 2-stage rebuild from
#   CURRENT source with NO seed, NO OCaml, NO C3a gate.
#     stage A: the existing emitter compiles compiler/entries/llvm_emit_modules_main.mdk
#              -> a FRESH ./medaka_emitter (re-emits its own graph; clang).
#     stage B: the fresh emitter compiles compiler/driver/medaka_cli.mdk -> ./medaka.
#   Always-2-stage is correct; the rebuilt emitter's self-consistency is guaranteed
#   separately by test/selfcompile_fixpoint.sh (not run here), so the warm loop is
#   sound.  A CONTENT-FINGERPRINT short-circuit skips stage A when compiler/**.mdk
#   AND runtime/*.c (the emitter links medaka_rt.c — e.g. floatToString feeds
#   float-literal codegen, see issue #182) hash to what ./medaka_emitter was built
#   from (can be disabled with FORCE_EMITTER_REBUILD=1).  See "Emitter provenance"
#   below for why this is a hash and NOT a timestamp.
#
#   COLD (no ./medaka_emitter — fresh clone): bootstrap emitter_v0 from the gzipped
#   committed seed (test/bootstrap_from_seed.sh, TOLERANT — a lagging seed only WARNS,
#   never aborts), then run the warm 2-stage rebuild from current source on top of it.
#
# Either way the result is a self-contained native `medaka` binary doing
# check/fmt/new/build/run/test/repl/lsp with no OCaml at runtime OR build time.
# (`medaka build` itself shells out to an emitter; set MEDAKA_EMITTER=./medaka_emitter
#  so user builds are also OCaml-free — see the printed hint at the end.)
#
# OPT-IN like the other LLVM scripts: skips cleanly (exit 2) when clang or libgc
# is absent.
#
# Usage:  sh test/build_native_medaka.sh [output-path]   (default ./medaka)
# Exit:   0 on success; 2 if clang/libgc absent (opt-in skip); 1 on any failure.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CC="${CC:-clang}"
STACK_SIZE="${STACK_SIZE:-0x20000000}"

# Boehm collects when allocation since the last GC reaches ~heap size; the emitter
# churns ~15 GB of transient garbage over a ~100 MB live set, so with the default
# initial heap it collects ~110 times (~4 s of a ~6 s self-compile emit). A large
# initial heap defers that to ~9 collections. These emitter runs are SERIAL (stage
# A then B), so the extra RSS (~1 GB) doesn't contend. Measured: make medaka 16s→11s.
# (Not applied to the parallel oracle build, where 10× the RSS causes memory
# pressure that erases the win — see test/build_oracles.sh.) User env value wins.
export GC_INITIAL_HEAP_SIZE="${GC_INITIAL_HEAP_SIZE:-1073741824}"
OUT="${1:-$ROOT/medaka}"
EMITTER="$ROOT/medaka_emitter"
RT="$ROOT/runtime/medaka_rt.c"
RUNTIME="$ROOT/stdlib/runtime.mdk"
CORE="$ROOT/stdlib/core.mdk"
DRIVER="$ROOT/compiler/entries/llvm_emit_modules_main.mdk"
CLI="$ROOT/compiler/driver/medaka_cli.mdk"
SELFHOST="$ROOT/compiler"
STDLIB="$ROOT/stdlib"
FORCE_EMITTER_REBUILD="${FORCE_EMITTER_REBUILD:-0}"
# OPT-IN, DEFAULT OFF (issue #1928 follow-up). When 1, stage B skips the clang link
# of ./medaka if a `.medaka.srcstamp` beside it says it was already built from
# exactly this compiler source. Unset/0 keeps the historical behaviour — stage B
# ALWAYS relinks — which is what the hot local dev loop and every other CI job get.
# Only CI's `inlang` job sets this: it downloads ./medaka from the `build` job and
# then runs `make test`, whose `.PHONY` `medaka` prerequisite would otherwise
# re-link (~55 s) over the binary it just downloaded. See stage B below.
SKIP_CLI_LINK_IF_FRESH="${SKIP_CLI_LINK_IF_FRESH:-0}"

command -v "$CC" >/dev/null 2>&1 || { echo "no C compiler ($CC) on PATH — skipping (opt-in)"; exit 2; }

# Best-effort sweep of orphaned per-PID staging files (issue #1141): each of
# $EMITTER/$OUT/$SRC_STAMP is built under a PID-suffixed name beside the final path
# and promoted with an atomic `mv`, so a build killed mid-compile (SIGTERM/SIGKILL —
# neither trappable the way EXIT is) can leave a `*.new.<pid>` behind. These never
# collide with a live build (the PID makes each name unique) and are NOT a lock —
# there is nothing here for a killed agent to get permanently stuck behind — so this
# is pure hygiene, not correctness; failures are silently ignored (`|| true`).
find "$ROOT" -maxdepth 1 \( -name 'medaka.new.*' -o -name 'medaka_emitter.new.*' -o -name '.medaka_emitter.srcstamp.new.*' -o -name '.medaka.srcstamp.new.*' \) -mtime +1 -delete 2>/dev/null || true

# ---- COLD START: no native emitter yet -> bootstrap emitter_v0 from the seed ----
# Tolerant: a lagging committed seed must NOT abort the build (it builds a working
# emitter_v0 from the current-source re-emission, which then compiles current source).
if [ ! -x "$EMITTER" ]; then
  echo "cold start: no $EMITTER — bootstrapping emitter_v0 from the gzipped seed (tolerant) ..."
  SEED_TOLERANT=1 sh "$ROOT/test/bootstrap_from_seed.sh" "$EMITTER" tolerant
  rc=$?
  if [ "$rc" = 2 ]; then echo "skipping (clang/libgc absent)"; exit 2; fi
  if [ "$rc" != 0 ] || [ ! -x "$EMITTER" ]; then
    echo "FAIL: cold bootstrap did not produce $EMITTER"; exit 1
  fi
fi

# ---- Resolve GC flags (clang/libgc already proven present) ----------------------
if command -v pkg-config >/dev/null 2>&1 && pkg-config --exists bdw-gc 2>/dev/null; then
  GC_CFLAGS="$(pkg-config --cflags bdw-gc)"; GC_LIBS="$(pkg-config --libs bdw-gc)"
elif GC_PREFIX="$(brew --prefix bdw-gc 2>/dev/null)" && [ -n "$GC_PREFIX" ] && [ -f "$GC_PREFIX/include/gc.h" ]; then
  GC_CFLAGS="-I$GC_PREFIX/include"; GC_LIBS="-L$GC_PREFIX/lib -lgc"
elif printf '#include <gc.h>\nint main(void){return 0;}\n' | "$CC" -x c - -lgc -o /dev/null 2>/dev/null; then
  GC_CFLAGS=""; GC_LIBS="-lgc"
else
  echo "libgc (bdw-gc) not found — skipping (opt-in; install bdw-gc or set GC_PREFIX)"; exit 2
fi

# ---- Resolve section-level dead-code-elim flags (issue #120) --------------------
# -ffunction-sections/-fdata-sections put each fn/global in its own section so the
# LINKER's real relocation graph (not source-level analysis) decides what's
# reachable: source DCE (compiler/ir/dce.mdk) cannot prune an impl (dict-passing
# means pruning one could be a silent miscompile), but the linker sees the actual
# call/dict relocations and recovers exactly what source DCE is obliged to leave
# behind (measured 77% smaller binary on a sample fixture). The matching LINKER
# flag differs: GNU ld/gold/lld (Linux) take --gc-sections; macOS's ld64 has no
# such flag and uses -dead_strip instead — dual-platform per AGENTS.md.
GC_SECTION_CFLAGS="-ffunction-sections -fdata-sections"
case "$(uname -s)" in
  Darwin) GC_SECTION_LDFLAGS="-Wl,-dead_strip" ;;
  *) GC_SECTION_LDFLAGS="-Wl,--gc-sections" ;;
esac

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

trim_unit() {
  f="$1"
  if [ "$(tail -c 3 "$f" | od -An -tx1 | tr -d ' \n')" = "28290a" ]; then
    head -c $(( $(wc -c < "$f") - 3 )) "$f" > "$f.trim" && mv "$f.trim" "$f"
  fi
}

# The existing $EMITTER can be too old to parse current source after a parser
# change (it crashes with "parse error" re-emitting the graph).  The gzipped seed
# carries the current parser, so re-bootstrap the emitter from it ONCE and retry.
# A genuine syntax error in source fails the retry too (the seed emitter can't
# parse it either), so this never masks a real parse error.
RESEEDED=0
reseed_emitter() {
  [ "$RESEEDED" = "1" ] && return 1
  RESEEDED=1
  echo "  existing emitter can't parse current source (likely a parser change) — re-bootstrapping the emitter from the gzipped seed ..."
  SEED_TOLERANT=1 sh "$ROOT/test/bootstrap_from_seed.sh" "$EMITTER" tolerant
  [ "$?" = 0 ] && [ -x "$EMITTER" ]
}

# emit_graph OUT_LL ERR_FILE TARGET_MDK — run the emitter over a graph; on
# failure, reseed once and retry. Returns the (final) emitter exit status.
emit_graph() {
  out_ll="$1"; err_file="$2"; target="$3"
  "$EMITTER" "$RUNTIME" "$CORE" "$target" "$SELFHOST" "$STDLIB" > "$out_ll" 2>"$err_file" && return 0
  reseed_emitter || return 1
  echo "  retrying emit with the seed-bootstrapped emitter ..."
  "$EMITTER" "$RUNTIME" "$CORE" "$target" "$SELFHOST" "$STDLIB" > "$out_ll" 2>"$err_file"
}


# ── Emitter provenance: hash the SOURCE, never trust the MTIME ────────────────
#
# An emitter binary's provenance — WHICH SOURCE was it built from — cannot be read
# off its mtime, and this bit every agent on every fresh worktree until 2026-07-13.
#
# The documented warm path is:  cp <other-tree>/medaka_emitter . && make medaka
# `cp` stamps the copy with the CURRENT time, which is NEWER than every file that
# `git worktree add` just checked out. So the old `find -newer "$EMITTER"` test found
# nothing newer and concluded "emitter up-to-date — skipping rebuild" about a binary
# that was, in SOURCE terms, arbitrarily old. It then handed that stale binary to
# stage B, where it died on syntax it predated ("parse error"), and the build fell
# back to a full COLD re-bootstrap from the seed — which additionally printed
#   "C3a WARN: committed seed differs ... (lagging seed)"
# an alarming, entirely unrelated message that sent agents hunting a seed bug that
# was not there. (Concretely: an emitter predating b2990236 cannot parse
# compiler/tools/snapshot.mdk, which now uses `import ... as ...`.)
#
# The mtime is not a weak signal here, it is an ACTIVELY INVERTED one: the staler the
# emitter's origin, the fresher its copy time. So fingerprint the source it was built
# from and keep that beside the binary. A copied-in emitter carries no stamp (the
# stamp is gitignored and never travels with a `cp`), so it is correctly treated as
# unknown-provenance and rebuilt — which is exactly the cheap stage-A emit that makes
# the warm path warm.
SRC_STAMP="$ROOT/.medaka_emitter.srcstamp"

# The same idea, one stage down: WHICH SOURCE was ./medaka (the CLI) linked from.
# Same reasoning as above — the mtime of a downloaded/copied-in ./medaka is an
# inverted signal — so keep the COMPILER-source fingerprint beside it. This stamp
# records FP_COMPILER, not FP_FULL, because that is exactly what stage B bakes into
# the binary as -DMEDAKA_SRC_FP and what `liveSourceFingerprint` recomputes at
# runtime ([B-STALENESS]); comparing anything else would compare the wrong thing.
#
# ⚠️ It describes the DEFAULT output path only. This script also gets called with an
# explicit output path (test/refresh_seed.sh links into a `mktemp` file), and a build
# that never wrote $ROOT/medaka must not leave a stamp vouching for it — that would be
# a stale-binary skip, precisely the silent wrongness the stamp exists to prevent. So
# both the read and the write below are gated on $OUT being the default path.
CLI_STAMP="$ROOT/.medaka.srcstamp"
CLI_STAMP_APPLIES=0
[ "$OUT" = "$ROOT/medaka" ] && CLI_STAMP_APPLIES=1

# sha256 where available (Linux coreutils / macOS `shasum`); `cksum` is the POSIX
# floor. This is a staleness check, not a signature — a weak hash only risks a
# missed rebuild, which FORCE_EMITTER_REBUILD=1 always overrides.
hash_stream() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256
  else cksum
  fi
}

# Names AND contents, REPO-RELATIVE, so an add/rename/delete registers as loudly as
# an edit and the stamp never bakes in an absolute worktree path.
#
# TWO fingerprints, because the value has two consumers with DIFFERENT scopes:
#
#   FP_FULL      = compiler/**.mdk + runtime/*.c.  Drives the stage-A rebuild-skip
#                  and the .medaka_emitter.srcstamp write.  The emitter links
#                  medaka_rt.c directly (see the clang invocation below), so a
#                  codegen-affecting runtime change — e.g. #57's floatToString
#                  formatting — must invalidate the emitter (issue #182). Before
#                  this, only compiler/**.mdk was hashed, so a medaka_rt.c-only
#                  change was invisible: stage A reported "up-to-date" and kept
#                  emitting with the OLD linked runtime — a native≠native(rebuilt)
#                  split that reads as a miscompile.
#
#   FP_COMPILER  = compiler/**.mdk ONLY.  Baked into ./medaka as -DMEDAKA_SRC_FP
#                  (below) and recomputed at runtime by `liveSourceFingerprint` in
#                  compiler/driver/medaka_cli.mdk, which is documented as a
#                  byte-for-byte mirror hashing `find compiler -name '*.mdk'`. The
#                  baked value MUST match that compiler-only computation, else every
#                  ./medaka invocation warns "stale" (and hard-fails under
#                  MEDAKA_STRICT=1). So the bake stays compiler-only; do NOT fold
#                  runtime/*.c into it without also editing medaka_cli.mdk.
#
# FORCE_EMITTER_REBUILD=1 overrides the FP_FULL skip regardless.
src_fingerprint_compiler() {
  ( cd "$ROOT" && find compiler -name '*.mdk' -print | LC_ALL=C sort | while IFS= read -r f; do
      printf '%s\n' "$f"
      cat "$f"
    done ) | hash_stream | cut -d' ' -f1
}
src_fingerprint_full() {
  ( cd "$ROOT" && { find compiler -name '*.mdk' -print; find runtime -name '*.c' -print; } | LC_ALL=C sort | while IFS= read -r f; do
      printf '%s\n' "$f"
      cat "$f"
    done ) | hash_stream | cut -d' ' -f1
}

# ---- STAGE A (WARM): existing emitter rebuilds itself from CURRENT source --------
# Skip ONLY when the emitter exists AND its stamp says it was built from exactly this
# compiler source AND runtime source (an up-to-date emitter re-emits byte-identically
# anyway; runtime/*.c is linked into the emitter binary, so it counts too — issue #182).
FP_FULL="$(src_fingerprint_full)"
FP_COMPILER="$(src_fingerprint_compiler)"

# VERSION PROVENANCE (issue #74 W8): commit + build date baked alongside
# FP_COMPILER below, at the SAME clang link, so `medaka --version` can report
# where a binary came from. Both degrade to empty on failure (a `.git`-less
# dist tarball, or no `git`/`date` in PATH) — never error the build. Portable
# across [B-DUAL-PLATFORM]: `git rev-parse --short` and `date -u +%Y-%m-%d`
# behave identically on GNU/Linux and BSD/macOS.
BUILD_COMMIT=""
if command -v git >/dev/null 2>&1 && [ -e "$ROOT/.git" ]; then
  BUILD_COMMIT="$(cd "$ROOT" && git rev-parse --short HEAD 2>/dev/null)"
fi
BUILD_DATE="$(date -u +%Y-%m-%d 2>/dev/null)"

STAMP_FP=""
[ -f "$SRC_STAMP" ] && STAMP_FP="$(cat "$SRC_STAMP" 2>/dev/null)"
if [ "$FORCE_EMITTER_REBUILD" != "1" ] && [ -x "$EMITTER" ] && [ -n "$STAMP_FP" ] && [ "$STAMP_FP" = "$FP_FULL" ]; then
  echo "stage A: emitter up-to-date (compiler + runtime source fingerprint unchanged) — skipping rebuild."
else
  if [ "$FORCE_EMITTER_REBUILD" = "1" ]; then
    echo "stage A: FORCE_EMITTER_REBUILD=1 — rebuilding emitter from current source ..."
  elif [ -z "$STAMP_FP" ]; then
    # Either the cold branch above just minted it from the seed, or it was copied in
    # from another tree. Both are "provenance unknown" — rebuild rather than guess.
    echo "stage A: emitter provenance unknown (fresh bootstrap, or copied in from another tree) — rebuilding from current source ..."
  else
    echo "stage A: compiler or runtime source changed since this emitter was built — rebuilding emitter from current source ..."
  fi
  EMIT_LL="$WORK/emitter.ll"
  if ! emit_graph "$EMIT_LL" "$WORK/emitA.err" "$DRIVER"; then
    echo "FAIL (emitter crashed re-emitting its own graph):"; cat "$WORK/emitA.err"; exit 1
  fi
  trim_unit "$EMIT_LL"
  [ -s "$EMIT_LL" ] || { echo "FAIL: empty IR for the emitter graph"; cat "$WORK/emitA.err"; exit 1; }
  # Staged NEXT TO the final target ($EMITTER's own directory), not under $WORK:
  # $WORK comes from mktemp -d, which (absent a same-filesystem TMPDIR) can land on
  # a different device than $ROOT (e.g. tmpfs /tmp vs the repo's real filesystem) —
  # a cross-device `mv` is NOT atomic (rename(2) EXDEV forces a copy). Staging
  # beside $EMITTER guarantees the final `mv` is a same-filesystem rename, so a
  # concurrent `make medaka` in this worktree (issue #1141) can race for LAST
  # WRITE but never observes a partially-written binary at the final path.
  EMIT_NEW="$EMITTER.new.$$"
  rm -f "$EMIT_NEW"
  # Build the emitter — the compiler's WORKHORSE binary — at -O2. It is reused for
  # every emit downstream (oracle build's 53 entries, every `medaka build`, make
  # medaka's own stage B), so clang -O2 (~+3s once vs -O0) buys ~30% faster emit
  # each time (self-compile 5.4s→3.7s; oracle build 55s→48s). EMITTER_OPT overrides.
  if ! "$CC" -pthread "${EMITTER_OPT:--O2}" $GC_SECTION_CFLAGS $GC_CFLAGS "$EMIT_LL" "$RT" $GC_LIBS "$GC_SECTION_LDFLAGS" -lm -o "$EMIT_NEW" 2>"$WORK/emitA-cc.err"; then
    rm -f "$EMIT_NEW"
    echo "FAIL (clang fresh emitter): $(cat "$WORK/emitA-cc.err")"; exit 1
  fi
  mv "$EMIT_NEW" "$EMITTER"
  echo "stage A: rebuilt $EMITTER from current source."
fi

# ---- STAGE B (WARM): the (fresh) emitter emits the medaka_cli graph -> ./medaka --
# Unconditional BY DEFAULT (see SKIP_CLI_LINK_IF_FRESH at the top): the hot dev loop
# and every other caller keep relinking exactly as before. The opt-in skip below is
# symmetric with stage A's — same fingerprint helpers, same stamp file pattern, same
# "no stamp = unknown provenance = rebuild" fallback — but it compares FP_COMPILER,
# because that is what stage B actually bakes into the binary (-DMEDAKA_SRC_FP).
CLI_STAMP_FP=""
if [ "$CLI_STAMP_APPLIES" = "1" ] && [ -f "$CLI_STAMP" ]; then
  CLI_STAMP_FP="$(cat "$CLI_STAMP" 2>/dev/null)"
fi
if [ "$SKIP_CLI_LINK_IF_FRESH" = "1" ] && [ "$CLI_STAMP_APPLIES" = "1" ] \
   && [ -x "$OUT" ] && [ -n "$CLI_STAMP_FP" ] && [ "$CLI_STAMP_FP" = "$FP_COMPILER" ]; then
  echo "stage B: medaka up-to-date (compiler source fingerprint unchanged) — skipping rebuild."
else
  CLI_LL="$WORK/medaka_cli.ll"
  echo "stage B: medaka_emitter -> medaka_cli.ll ..."
  if ! emit_graph "$CLI_LL" "$WORK/emit.err" "$CLI"; then
    echo "FAIL (emitter crashed compiling medaka_cli.mdk):"; cat "$WORK/emit.err"; exit 1
  fi
  trim_unit "$CLI_LL"
  [ -s "$CLI_LL" ] || { echo "FAIL: empty IR for medaka_cli.mdk"; cat "$WORK/emit.err"; exit 1; }

  # The medaka CLI is built at -O0 by DEFAULT: make medaka is the hot compiler-dev
  # loop and does NOT reuse the CLI (the diff gates run compiled test/bin oracles,
  # not the CLI interpreter), so -O2 here would be a straight +~4s clang cost on the
  # most frequent command. But `medaka run`/`test`/`check` DO run the CLI's tree-walk
  # interpreter, which is ~2× faster at -O2 (medaka test 1.3s→0.65s). So for
  # interpreter/doctest-heavy workflows, -O2 is the default (medaka test 1.3s→0.65s);
  # for build-heavy loops where the +~4s clang cost dominates, opt out with CLI_OPT=-O0.
  # (The EMITTER, by contrast, is always -O2 — it's the reused workhorse; see stage A.)
  CLI_OPT="${CLI_OPT:--O2}"
  echo "stage B: clang(medaka_cli.ll, $CLI_OPT) -> $OUT ..."
  # STALENESS STAMP (issue #89): bake the COMPILER-source fingerprint into ./medaka
  # so the CLI can warn when it is run against a NEWER compiler/ than it was built
  # from.  The -D hits ONLY this C compile of medaka_rt.c — never the emitter IR —
  # so it is fixpoint/seed-safe (the text IR is produced before clang runs).  We bake
  # FP_COMPILER (compiler/**.mdk only), NOT FP_FULL: the driver's `liveSourceFingerprint`
  # (compiler/driver/medaka_cli.mdk) recomputes a compiler-only hash at runtime and
  # hard-fails a mismatch under MEDAKA_STRICT, so the baked value must stay byte-for-byte
  # compiler-only.  FP_FULL (which folds in runtime/*.c for the emitter-rebuild trigger,
  # issue #182) is written to .medaka_emitter.srcstamp below, a DIFFERENT consumer.
  # Empty on paths that never set it (returns "" → the check silently skips).
  # $OUT.new.$$ is staged NEXT TO $OUT (never under $WORK — see the stage-A EMIT_NEW
  # comment above for why: cross-device mv is not atomic) so two concurrent `make
  # medaka` invocations in this worktree (issue #1141) each build a private, complete
  # binary and only the final `mv` (a same-filesystem rename, atomic) touches the
  # shared path — neither process can ever observe (or leave behind) a
  # partially-written $OUT, only last-writer-wins on which COMPLETE build stuck.
  OUT_NEW="$OUT.new.$$"
  rm -f "$OUT_NEW"
  if ! "$CC" -pthread "$CLI_OPT" "-DMEDAKA_SRC_FP=$FP_COMPILER" "-DMEDAKA_SRC_COMMIT=\"$BUILD_COMMIT\"" "-DMEDAKA_SRC_BUILD_DATE=\"$BUILD_DATE\"" $GC_SECTION_CFLAGS $GC_CFLAGS "$CLI_LL" "$RT" $GC_LIBS "$GC_SECTION_LDFLAGS" -lm -o "$OUT_NEW" 2>"$WORK/cc.err"; then
    rm -f "$OUT_NEW"
    echo "FAIL (clang medaka): $(cat "$WORK/cc.err")"; exit 1
  fi
  mv "$OUT_NEW" "$OUT"
fi

# Record WHICH SOURCE this emitter was built from — FP_FULL (compiler + runtime), so
# a later medaka_rt.c change re-triggers stage A (issue #182). Correct on every path
# that got here: stage A rebuilt it, or its stamp already matched, or emit_graph's
# reseed rebuilt it from the current-source re-emission. Written last, so a failed
# build never leaves a stamp claiming a provenance the binary does not have.
# Staged + renamed the same way as $EMITTER/$OUT above: two concurrent builds must
# not be able to interleave partial writes into $SRC_STAMP either.
STAMP_NEW="$SRC_STAMP.new.$$"
printf '%s\n' "$FP_FULL" > "$STAMP_NEW"
mv "$STAMP_NEW" "$SRC_STAMP"

# ...and the same for the CLI, recording FP_COMPILER — the value stage B bakes in.
# Written on both stage-B paths: after a real link it records the fresh provenance,
# and after a skip it re-writes the value the skip already proved equal, so the two
# paths converge on the same file content. Gated on the default output path (see
# CLI_STAMP above): a build that linked somewhere else must not vouch for $ROOT/medaka.
if [ "$CLI_STAMP_APPLIES" = "1" ]; then
  CLI_STAMP_NEW="$CLI_STAMP.new.$$"
  printf '%s\n' "$FP_COMPILER" > "$CLI_STAMP_NEW"
  mv "$CLI_STAMP_NEW" "$CLI_STAMP"
fi

echo
echo "BUILT $OUT — native, OCaml-free."
echo "For OCaml-free user builds too, export MEDAKA_EMITTER=$EMITTER (so 'medaka build' uses the native emitter)."
