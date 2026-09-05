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
#   sound.  A CONTENT-FINGERPRINT short-circuit skips stage A when everything that
#   can change the emitter binary — its own import closure, stdlib/**.mdk, and
#   runtime/*.c (it links medaka_rt.c; e.g. floatToString feeds float-literal
#   codegen, issue #182) — hashes to what ./medaka_emitter was built from (can be
#   disabled with FORCE_EMITTER_REBUILD=1).  See "Emitter provenance" below for
#   why this is a hash and NOT a timestamp, and FP_FULL there for the file set.
#
#   COLD (no ./medaka_emitter — fresh clone): bootstrap emitter_v0 from the gzipped
#   committed seed (test/bootstrap_from_seed.sh, TOLERANT — a lagging seed only WARNS,
#   never aborts), then run the warm 2-stage rebuild from current source on top of it.
#
#   Either mode can be short-circuited further by the BUILD CACHE (see that section):
#   a binary some other worktree already built from this exact source is copied into
#   place instead of being rebuilt. It is an accelerator only — any miss, absent cache
#   directory, or failed entry validation falls back to the build described above.
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
# churns ~15 GB of transient garbage over a ~100 MB live set, so a small initial
# heap forces far more collections during self-compile emit than a large one
# does. A large initial heap defers most of that GC work. These emitter runs are
# SERIAL (stage A then B), so the extra RSS (~1 GB) doesn't contend. Measured on
# this box (Debian 13, 12-core/32GB) on 2026-09-05, `make medaka` on a forced
# cache-miss full rebuild (FORCE_EMITTER_REBUILD=1, MEDAKA_BUILD_CACHE_DIR=):
# GC_INITIAL_HEAP_SIZE unset (Boehm default) 288.4s → 1 GiB (this default) 268.3s
# — about 7% faster, ~20s saved, at current codebase scale. The 1 GiB arm re-ran at
# 272.0s later the same day, so treat ~4s as this box's run-to-run noise floor and
# read the ~20s delta as signal only because it clears it. Re-derive with
# `time sh test/build_native_medaka.sh` under each setting rather than trusting
# this figure indefinitely.
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
# The same entry + search roots emit_graph hands the emitter for stage A, spelled
# repo-relative for test/emitter_source_set.awk (see FP_FULL below). The two must
# name the same graph: the fingerprint's whole claim is that it covers everything
# stage A actually compiles.
FP_ENTRY="compiler/entries/llvm_emit_modules_main.mdk"
FP_ROOTS="compiler:stdlib"
FORCE_EMITTER_REBUILD="${FORCE_EMITTER_REBUILD:-0}"
# OPT-IN, DEFAULT OFF (issue #1928 follow-up). When 1, stage B skips the clang link
# of ./medaka if a `.medaka.srcstamp` beside it says it was already built from
# exactly this compiler source. Unset/0 keeps the historical behaviour — stage B
# ALWAYS relinks — which is what the hot local dev loop and every other CI job get.
# Only CI's `inlang` job sets this: it downloads ./medaka from the `build` job and
# then runs `make test`, whose `.PHONY` `medaka` prerequisite would otherwise
# re-link (~55 s) over the binary it just downloaded. See stage B below.
SKIP_CLI_LINK_IF_FRESH="${SKIP_CLI_LINK_IF_FRESH:-0}"

# ---- PARALLEL CODEGEN (issue #2681) --------------------------------------------
# EMITTER-ONLY, ON BY DEFAULT where the LLVM tools it needs are actually present.
# Stage A's emitter link hands clang one ~17 MB IR module and gets one
# single-threaded -O2 pipeline out of a 12-core box. When `llvm-split`/`opt`/`llc`
# are discoverable, pcg_link splits that module into $MEDAKA_CODEGEN_PARTS
# partitions, runs `opt -O2` + `llc -O2` on each IN PARALLEL, and hands clang the
# resulting objects instead. Set MEDAKA_PARALLEL_CODEGEN=0 to force the single
# `clang -O2` invocation; that is also what runs, silently, wherever the tools are
# absent (CI runner layouts vary — see pcg_discover, and MEDAKA_LLVM_BINDIR there
# for pointing this at a toolchain it would not find).
#
# Stage B's ./medaka link does NOT take this path (S-codegen-cost-honest,
# 2026-09-05, this box): partitioning gives up cross-partition inlining, and for
# the emitter that costs only link time (its emitted IR is byte-identical either
# way — a parallel-linked emitter re-emits its own graph the same as a
# clang -O2-built one). For the CLI it also costs INTERPRETER RUNTIME, because
# medaka_cli.mdk's tree-walk interpreter is what every `medaka check`/`test`/`run`
# invocation executes — every gate and oracle in the tree pays this on every run,
# far more often than the CLI is relinked. Measured: `MEDAKA_STRICT=1 time
# ./medaka check compiler/driver/medaka_cli.mdk`, 3 reps each, same source, same
# day — plain -O2 CLI link avg 76.1s wall vs. parallel-codegen CLI link avg
# 80.3s wall, ~5.5% slower, consistently (every parallel rep slower than every
# plain rep). The CLI link therefore always takes the plain `clang -O2` path;
# $MEDAKA_PARALLEL_CODEGEN and $PCG_BIN below govern the emitter link only.
#
# `opt -O2` ahead of `llc -O2` (rather than `llc -O2` alone) is deliberate, not
# just architecturally reasoned: measured the same day on the CLI link, an
# `llc`-only parallel link (skips the IR-level optimization pass entirely) is
# ITSELF slower at runtime than the opt+llc parallel link — avg 87.3s wall vs.
# 80.3s (2 reps each) — and slower again than plain -O2's 76.1s. Skipping `opt`
# would not even trade correctness for speed; it loses on both.
MEDAKA_PARALLEL_CODEGEN="${MEDAKA_PARALLEL_CODEGEN:-1}"
# 8, on a 12-core box. The partitions run concurrently with nothing else in this
# script (both links are serial points), but each opt/llc holds its own partition in
# memory, and leaving ~4 cores idle keeps a concurrent build or the emitter's own GC
# threads from contending. Raising it past the core count buys nothing; lowering it
# to 1 is NOT the same as MEDAKA_PARALLEL_CODEGEN=0 (it still splits the module, so
# it still gives up cross-partition inlining, for no parallelism at all).
MEDAKA_CODEGEN_PARTS="${MEDAKA_CODEGEN_PARTS:-8}"

# Where llvm-split/opt/llc live. $MEDAKA_LLVM_BINDIR, if set, is searched INSTEAD of
# everything else — an operator knob for a toolchain in a nonstandard place, and the
# seam that lets the fallback path be exercised rather than asserted (point it at a
# directory without the tools). Otherwise: PATH first; then the versioned
# Debian/Ubuntu directories, which put these tools OFF PATH (on this box only
# /usr/bin/clang is on it); then the two Homebrew prefixes, for [B-DUAL-PLATFORM].
# Highest version wins among the /usr/lib/llvm-* candidates. Prints the directory to
# use, or returns nonzero when no single directory holds all three — a runner without
# these tools must degrade to the plain clang path, never fail, so no layout is
# hardcoded as the only place to look.
pcg_discover() {
  if [ -n "${MEDAKA_LLVM_BINDIR:-}" ]; then
    if [ -x "$MEDAKA_LLVM_BINDIR/llvm-split" ] && [ -x "$MEDAKA_LLVM_BINDIR/opt" ] \
       && [ -x "$MEDAKA_LLVM_BINDIR/llc" ]; then
      printf '%s' "$MEDAKA_LLVM_BINDIR"
      return 0
    fi
    return 1
  fi
  for _d in "" $(ls -d /usr/lib/llvm-*/bin 2>/dev/null | sort -r) \
            /opt/homebrew/opt/llvm/bin /usr/local/opt/llvm/bin; do
    if [ -z "$_d" ]; then
      if command -v llvm-split >/dev/null 2>&1 && command -v opt >/dev/null 2>&1 \
         && command -v llc >/dev/null 2>&1; then
        dirname "$(command -v llvm-split)" | tr -d '\n'
        return 0
      fi
    elif [ -x "$_d/llvm-split" ] && [ -x "$_d/opt" ] && [ -x "$_d/llc" ]; then
      printf '%s' "$_d"
      return 0
    fi
  done
  return 1
}

PCG_BIN=""
if [ "$MEDAKA_PARALLEL_CODEGEN" = "1" ]; then
  PCG_BIN="$(pcg_discover || true)"
fi
# The one value every later reader asks for: which codegen path the EMITTER link
# (stage A) will take. Folded into the emitter's build-cache key below, because two
# emitter binaries built from identical source down the two paths are NOT the same
# bytes. The CLI link (stage B) always takes the plain path (see PARALLEL CODEGEN
# above) so its own key uses a fixed "plain" tag, never this variable.
if [ -n "$PCG_BIN" ]; then
  PCG_MODE="parallel-$MEDAKA_CODEGEN_PARTS"
else
  PCG_MODE="plain"
fi

command -v "$CC" >/dev/null 2>&1 || { echo "no C compiler ($CC) on PATH — skipping (opt-in)"; exit 2; }

# Best-effort sweep of orphaned per-PID staging files (issue #1141): each of
# $EMITTER/$OUT/$SRC_STAMP is built under a PID-suffixed name beside the final path
# and promoted with an atomic `mv`, so a build killed mid-compile (SIGTERM/SIGKILL —
# neither trappable the way EXIT is) can leave a `*.new.<pid>` behind. These never
# collide with a live build (the PID makes each name unique) and are NOT a lock —
# there is nothing here for a killed agent to get permanently stuck behind — so this
# is pure hygiene, not correctness; failures are silently ignored (`|| true`).
find "$ROOT" -maxdepth 1 \( -name 'medaka.new.*' -o -name 'medaka_emitter.new.*' -o -name '.medaka_emitter.srcstamp.new.*' -o -name '.medaka.srcstamp.new.*' \) -mtime +1 -delete 2>/dev/null || true

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
#   FP_FULL      = the emitter's OWN import closure + stdlib/**.mdk + runtime/*.c.
#                  Drives the stage-A rebuild-skip and the
#                  .medaka_emitter.srcstamp write, so its correct scope is
#                  "everything that can change the emitter binary" — no more and
#                  no less. The emitter links medaka_rt.c directly (see the clang
#                  invocation below), so a codegen-affecting runtime change — e.g.
#                  #57's floatToString formatting — must invalidate it (issue
#                  #182); stdlib/ is compiled INTO it (emit_graph passes
#                  $RUNTIME/$CORE and $STDLIB as a search root), so a
#                  stdlib/core.mdk edit must too (issue #2682 — it did not, and
#                  stage A reported "up-to-date" while the emitter kept the old
#                  prelude). Conversely compiler/tools/**, compiler/entries/**
#                  other than the emitter's own, and every other module OUTSIDE
#                  that closure cannot reach the emitter binary at all, and used
#                  to force a full ~4-minute rebuild for nothing (issue #2680).
#
#                  The closure itself comes from test/emitter_source_set.awk, a
#                  STATIC walker — this runs on the cold path with no ./medaka in
#                  existence, so it cannot ask the real loader. That makes it a
#                  reimplementation of driver.loader's resolution and therefore
#                  driftable: test/check_fingerprint_parity.sh diffs the walker's
#                  list against the loader's own graph
#                  (compiler/entries/module_closure_probe.mdk) on a built binary.
#                  And it FAILS CLOSED — any walker failure falls back to hashing
#                  the whole compiler tree, because an over-broad set costs one
#                  unnecessary rebuild while an under-broad one silently vouches
#                  for an emitter built from source that is no longer on disk.
#
#   FP_COMPILER  = compiler/**.mdk + stdlib/**.mdk.  Baked into ./medaka as
#                  -DMEDAKA_SRC_FP (below) and recomputed at runtime by
#                  `liveSourceFingerprint` in compiler/driver/medaka_cli.mdk,
#                  which is documented as a byte-for-byte mirror hashing the
#                  SAME find expression. The baked value MUST match that live
#                  computation, else every ./medaka invocation warns "stale"
#                  (and hard-fails under MEDAKA_STRICT=1). stdlib/ is compiled
#                  INTO the CLI binary exactly as it is into the emitter (a
#                  compiler/*.mdk module can import stdlib/*.mdk per
#                  [T-STDLIB-IMPORT], and those imports get linked into
#                  medaka_cli.ll at stage B) — issue #2682's other half: a
#                  stdlib-only edit changed CLI behavior with the same "stage
#                  reported up-to-date" silence FP_FULL already fixed for the
#                  emitter, and SKIP_CLI_LINK_IF_FRESH would call the resulting
#                  binary fresh forever. runtime/*.c stays OUT (it is not
#                  Medaka source `liveSourceFingerprint` can read); do NOT fold
#                  it in without also editing medaka_cli.mdk.
#
# Both fingerprints exclude `*_test.mdk`: a test sibling (compiler/types/registry_test.mdk
# and peers) is never linked into the emitter or the CLI, so hashing one would make
# editing a test rebuild the compiler and — because the baked FP_COMPILER is recomputed
# at runtime — make every ./medaka invocation warn stale. medaka_cli.mdk's
# `liveSourceFingerprint` carries the identical exclusion; the two must move together.
# FORCE_EMITTER_REBUILD=1 overrides the FP_FULL skip regardless.
src_fingerprint_compiler() {
  ( cd "$ROOT" && { find compiler -name '*.mdk' -not -name '*_test.mdk' -print
      find stdlib -name '*.mdk' -not -name '*_test.mdk' -print
    } | LC_ALL=C sort | while IFS= read -r f; do
      printf '%s\n' "$f"
      cat "$f"
    done ) | hash_stream | cut -d' ' -f1
}

# The FP_FULL file set, one repo-relative path per line, LC_ALL=C sorted.
# Run with $ROOT as cwd.
#
# The walker is skipped outright (not just on failure) when compiler/medaka.toml
# grows a `[dependencies]` section: it models `findInRoots` only, so a declared
# cross-project dep would resolve to a root it never searches and it would
# UNDER-report the closure — the one direction that is unsafe.
fp_full_file_list() {
  _closure=""
  if ! grep -q '^[[:space:]]*\[dependencies\]' compiler/medaka.toml 2>/dev/null; then
    _closure="$(awk -v entry="$FP_ENTRY" -v roots="$FP_ROOTS" -f test/emitter_source_set.awk)" || _closure=""
  fi
  if [ -z "$_closure" ]; then
    echo "note: emitter import-closure walk unavailable — hashing all of compiler/ for FP_FULL." >&2
    _closure="$(find compiler -name '*.mdk' -not -name '*_test.mdk' -print)"
  fi
  { printf '%s\n' "$_closure"
    find stdlib -name '*.mdk' -not -name '*_test.mdk' -print
    find runtime -name '*.c' -print
  } | LC_ALL=C sort -u
}

src_fingerprint_full() {
  ( cd "$ROOT" && fp_full_file_list | while IFS= read -r f; do
      printf '%s\n' "$f"
      cat "$f"
    done ) | hash_stream | cut -d' ' -f1
}

# runtime/*.c ALONE. Not a build input to any stage-skip decision — FP_FULL already
# covers runtime/*.c for the emitter, and FP_COMPILER deliberately excludes it because
# `liveSourceFingerprint` (a Medaka mirror) cannot read C. Its one consumer is $CLI_KEY
# below: stage B LINKS $RT into ./medaka, so two trees differing only in an uncommitted
# runtime/medaka_rt.c produce different binaries while sharing a FP_COMPILER, a
# -O level, and a $BUILD_COMMIT (every dirty state collapses to the same `<sha>-dirty`).
# Keying the CLI on $FP_FULL instead would be correct but over-broad: the CLI cache
# would then miss on every compiler edit outside the emitter's own closure.
src_fingerprint_runtime() {
  ( cd "$ROOT" && find runtime -name '*.c' -print | LC_ALL=C sort | while IFS= read -r f; do
      printf '%s\n' "$f"
      cat "$f"
    done ) | hash_stream | cut -d' ' -f1
}

# Both fingerprints are computed HERE — above the cold-start bootstrap — because the
# build cache below is keyed on them and must be able to answer "another tree already
# built this exact emitter" BEFORE the seed bootstrap runs, which is the single most
# expensive step on a fresh worktree. Neither computation needs a binary: they hash
# source files, and the FP_FULL closure walker is the static awk one for exactly this
# reason.
FP_FULL="$(src_fingerprint_full)"
FP_COMPILER="$(src_fingerprint_compiler)"
FP_RUNTIME="$(src_fingerprint_runtime)"

# VERSION PROVENANCE (issue #74 W8): commit + build date baked alongside
# FP_COMPILER below, at the SAME clang link, so `medaka --version` can report
# where a binary came from. Both degrade to empty on failure (a `.git`-less
# dist tarball, or no `git`/`date` in PATH) — never error the build. Portable
# across [B-DUAL-PLATFORM]: `git rev-parse --short` and `date -u +%Y-%m-%d`
# behave identically on GNU/Linux and BSD/macOS.
BUILD_COMMIT=""
if command -v git >/dev/null 2>&1 && [ -e "$ROOT/.git" ]; then
  BUILD_COMMIT="$(cd "$ROOT" && git rev-parse --short HEAD 2>/dev/null)"
  # #2514 review F-12: a modified tree otherwise reports a clean commit,
  # which is exactly backwards for a field whose only purpose is triaging bug
  # reports ("bug reports are useless without it", the S-3 mission this
  # provenance string exists for) — a `-dirty` suffix is the difference
  # between a usable and a misleading answer for every local/dev build.
  if [ -n "$BUILD_COMMIT" ] && [ -n "$(cd "$ROOT" && git status --porcelain 2>/dev/null)" ]; then
    BUILD_COMMIT="${BUILD_COMMIT}-dirty"
  fi
fi
BUILD_DATE="$(date -u +%Y-%m-%d 2>/dev/null)"

# ---- BUILD CACHE: a binary another tree already built, keyed on its provenance ---
# (issue #2683.) A fresh worktree at a commit some other tree has already built pays a
# file copy instead of the ~350 s cold bootstrap. The cache is a pure ACCELERATOR: on
# a miss, a missing/unwritable cache dir, or an entry that fails validation, the script
# takes exactly the path it took before this section existed.
#
# The key is the fingerprint that already decides what the binary IS — FP_FULL for the
# emitter, FP_COMPILER for the CLI — plus the build-variant inputs that are NOT source
# and therefore not in either fingerprint:
#   * the clang -O level, which is genuinely different codegen;
#   * $PCG_MODE, for the EMITTER key only — the codegen PATH and its partition count
#     (see "PARALLEL CODEGEN" above). `plain` and `parallel-8` are different codegen
#     of the same IR at the same -O level: the parallel path gives up cross-partition
#     inlining, so the two produce binaries that behave identically but are not the
#     same bytes. Without this component a box that flipped MEDAKA_PARALLEL_CODEGEN,
#     or one that simply has the LLVM tools where another does not, would serve the
#     other path's binary under this path's key — and any later measurement of the
#     two paths against each other would be comparing one binary to itself. The CLI
#     key uses a literal `plain` tag instead of $PCG_MODE: the CLI link never takes
#     the parallel path (S-codegen-cost-honest — the measured interpreter-runtime
#     cost of losing cross-partition inlining is not worth paying on the binary
#     every gate/oracle/`medaka check` runs), so its key does not vary with the knob.
#   * for the CLI only, $BUILD_COMMIT and $BUILD_DATE, which stage B bakes in as
#     -DMEDAKA_SRC_COMMIT/-DMEDAKA_SRC_BUILD_DATE. Two commits can share one
#     FP_COMPILER (a docs-only commit does), so keying on the fingerprint alone would
#     serve a binary whose `medaka --version` names a commit it was not built at —
#     the exact triage field #2514 F-12 added the `-dirty` suffix to keep honest.
#     The emitter bakes no such string, so its key stays purely source-derived and
#     hits across commits and days; it is also the expensive half.
#   * for the CLI only, $FP_RUNTIME — stage B links runtime/medaka_rt.c into ./medaka,
#     and FP_COMPILER does not cover it. $BUILD_COMMIT cannot stand in: it renders every
#     uncommitted tree state as one `<sha>-dirty` string, so without this component two
#     worktrees at the same commit with different uncommitted runtime edits share a key.
#     The emitter half needs no equivalent: $FP_FULL already folds runtime/*.c in.
#
# Storage lives under $MEDAKA_SCRATCH (the Makefile's own default, redeclared here
# because the Makefile exports only TMPDIR) and never under /tmp, which is a RAM-backed
# tmpfs on the dev box — a cache that evaporates under memory pressure is not a cache.
# Set MEDAKA_BUILD_CACHE_DIR= (empty) to disable reads and writes entirely.
MEDAKA_SCRATCH="${MEDAKA_SCRATCH:-/var/tmp/medaka-scratch}"
CACHE_DIR="${MEDAKA_BUILD_CACHE_DIR-$MEDAKA_SCRATCH/medaka-build-cache}"
# Entry count, not total bytes: every entry is one compiler binary of roughly the same
# size, so a count is a size proxy that needs no per-file `stat` (whose flags differ
# between Linux and macOS — [B-DUAL-PLATFORM]).
CACHE_MAX="${MEDAKA_BUILD_CACHE_MAX:-8}"

# Filename-safe rendering of a key component (hex digests and -O flags already are;
# $BUILD_COMMIT/$BUILD_DATE come from git/date and could in principle not be).
cache_tag() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }

# The -O defaults are spelled the same way the two clang invocations spell them, so a
# key can never claim an optimization level the link did not use.
EMITTER_KEY="emitter-$(cache_tag "$FP_FULL")-$(cache_tag "${EMITTER_OPT:--O2}")-$(cache_tag "$PCG_MODE")"
CLI_KEY="medaka-$(cache_tag "$FP_COMPILER")-$(cache_tag "$FP_RUNTIME")-$(cache_tag "${CLI_OPT:--O2}")-plain-$(cache_tag "$BUILD_COMMIT")-$(cache_tag "$BUILD_DATE")"

# Each entry is two files: <key>.bin (the binary) and <key>.sha (the digest of exactly
# those stored bytes). Validation recomputes the digest BEFORE the entry is copied
# anywhere, so a truncated or half-written entry is detected and discarded rather than
# installed as $EMITTER/$OUT — issue #2233's regression was precisely "a truncated
# entry bricks the next build", and the fallback below must therefore be a real build
# in the SAME invocation, not a warning and an exit.
cache_get() {
  _k="$1"; _dest="$2"
  [ -n "$CACHE_DIR" ] || return 1
  _ent="$CACHE_DIR/$_k.bin"; _sha="$CACHE_DIR/$_k.sha"
  [ -f "$_ent" ] && [ -f "$_sha" ] || return 1
  _want="$(cat "$_sha" 2>/dev/null)"
  [ -n "$_want" ] || return 1
  _got="$(hash_stream < "$_ent" 2>/dev/null | cut -d' ' -f1)"
  if [ -z "$_got" ] || [ "$_got" != "$_want" ]; then
    echo "  build cache: entry $_k is corrupt or truncated (digest mismatch) — discarding it and building for real."
    rm -f "$_ent" "$_sha"
    return 1
  fi
  # Same stage-beside-then-atomic-mv discipline as $EMITTER/$OUT (issue #1141): a
  # concurrent build in this worktree must never observe a partially-copied binary at
  # the final path.
  _new="$_dest.new.$$"
  rm -f "$_new"
  cp "$_ent" "$_new" 2>/dev/null || { rm -f "$_new"; return 1; }
  chmod +x "$_new" 2>/dev/null || true
  mv "$_new" "$_dest" 2>/dev/null || { rm -f "$_new"; return 1; }
  touch "$_ent" "$_sha" 2>/dev/null || true   # recency, for the eviction order below
  return 0
}

# Populate. Called ONLY after a stage genuinely built a fresh binary — a cache hit
# re-writes nothing. Failures here are silent and non-fatal: a cache that cannot be
# written must not fail a build that has already succeeded.
cache_put() {
  _k="$1"; _src="$2"
  [ -n "$CACHE_DIR" ] || return 0
  mkdir -p "$CACHE_DIR" 2>/dev/null || return 0
  _ent="$CACHE_DIR/$_k.bin"; _sha="$CACHE_DIR/$_k.sha"
  # Already stored and intact: leave it alone rather than churning a file other builds
  # may be reading.
  if [ -f "$_ent" ] && [ -f "$_sha" ] \
     && [ "$(hash_stream < "$_ent" 2>/dev/null | cut -d' ' -f1)" = "$(cat "$_sha" 2>/dev/null)" ]; then
    return 0
  fi
  _entn="$_ent.new.$$"; _shan="$_sha.new.$$"
  rm -f "$_entn" "$_shan"
  cp "$_src" "$_entn" 2>/dev/null || { rm -f "$_entn"; return 0; }
  # Digest the STORED copy, not the source: the digest must certify the bytes a future
  # reader will actually read.
  _h="$(hash_stream < "$_entn" 2>/dev/null | cut -d' ' -f1)"
  [ -n "$_h" ] || { rm -f "$_entn"; return 0; }
  printf '%s\n' "$_h" > "$_shan" 2>/dev/null || { rm -f "$_entn" "$_shan"; return 0; }
  # Retire any stale digest first, then publish binary then digest: every intermediate
  # state a concurrent reader can observe is either "no digest" or "digest matches the
  # binary beside it", i.e. a clean miss or a valid hit, never a mismatched pair.
  rm -f "$_sha"
  mv "$_entn" "$_ent" 2>/dev/null && mv "$_shan" "$_sha" 2>/dev/null || { rm -f "$_entn" "$_shan"; return 0; }
  echo "  build cache: stored $_k."
  cache_evict
}

# Opportunistic eviction on write (no cron, no separate script — every stray .sh in the
# tree is a `make preflight` gate candidate, [WEB-SH-IS-A-GATE]). Newest-first listing,
# drop everything past $CACHE_MAX; cache_get touches an entry it serves, so the order is
# least-recently-USED, not merely oldest-written.
cache_evict() {
  [ -n "$CACHE_DIR" ] || return 0
  # Same hygiene as the $ROOT sweep near the top: a build killed between staging an
  # entry and promoting it leaves a per-PID orphan that nothing else will ever claim.
  find "$CACHE_DIR" -maxdepth 1 -name '*.new.*' -mtime +1 -delete 2>/dev/null || true
  ls -t "$CACHE_DIR"/*.bin 2>/dev/null | {
    _n=0
    while IFS= read -r _e; do
      _n=$((_n + 1))
      [ "$_n" -le "$CACHE_MAX" ] && continue
      rm -f "$_e" "${_e%.bin}.sha"
      echo "  build cache: evicted $(basename "${_e%.bin}") (cache is capped at $CACHE_MAX entries)."
    done
  }
  return 0
}

# The emitter read, deliberately AHEAD of the cold-start bootstrap: on a fresh worktree
# a hit skips both the seed bootstrap and the stage-A rebuild. Not consulted when
# FORCE_EMITTER_REBUILD=1 (that flag exists to force a real rebuild) nor when the local
# emitter is already provably current (nothing to gain). On a hit we write $SRC_STAMP
# immediately so the emitter carries the same provenance a real stage A would have left
# it, and stage A's existing skip arm then fires on it.
EMITTER_STAMP_FP=""
[ -f "$SRC_STAMP" ] && EMITTER_STAMP_FP="$(cat "$SRC_STAMP" 2>/dev/null)"
if [ "$FORCE_EMITTER_REBUILD" != "1" ] \
   && ! { [ -x "$EMITTER" ] && [ "$EMITTER_STAMP_FP" = "$FP_FULL" ]; } \
   && cache_get "$EMITTER_KEY" "$EMITTER"; then
  echo "stage A: emitter restored from build cache ($EMITTER_KEY) — no seed bootstrap, no rebuild."
  STAMP_NEW="$SRC_STAMP.new.$$"
  printf '%s\n' "$FP_FULL" > "$STAMP_NEW"
  mv "$STAMP_NEW" "$SRC_STAMP"
fi

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

# ---- pcg_link: the parallel half of PARALLEL CODEGEN (issue #2681) --------------
#
#   pcg_link <in.ll> <out-binary> <-O level> <errfile> [extra clang args ...]
#
# Split the module, `opt` + `llc` each partition concurrently, then let clang do the
# final link — which is also where runtime/medaka_rt.c is compiled, so any extra
# args (e.g. provenance -DMEDAKA_SRC_* defines) reach the same compile they would on
# the plain path. Returns nonzero on any failure with the reason appended to
# <errfile>; the one call site (stage A's emitter link) treats that exactly as it
# treats a clang failure, so a partition that cannot be split or codegen'd is a hard
# build failure, never a silent fallback to a binary built some other way. Stage B's
# CLI link never calls this — see "PARALLEL CODEGEN" above.
#
# `-relocation-model=pic` is not optional: llc defaults to the static model, and the
# resulting objects fail the PIE link with "relocation R_X86_64_32S ... can not be
# used when making a PIE object". `-function-sections`/`-data-sections` are llc's
# spelling of $GC_SECTION_CFLAGS, without which $GC_SECTION_LDFLAGS has nothing
# per-symbol to strip and the section-level DCE of issue #120 quietly stops working.
pcg_link() {
  _ll="$1"; _pout="$2"; _popt="$3"; _perr="$4"
  shift 4
  _pdir="$WORK/pcg.$$"
  rm -rf "$_pdir"
  mkdir -p "$_pdir" || { echo "pcg: cannot create $_pdir" >>"$_perr"; return 1; }

  if ! "$PCG_BIN/llvm-split" -j "$MEDAKA_CODEGEN_PARTS" -o "$_pdir/p" "$_ll" 2>>"$_perr"; then
    echo "pcg: llvm-split failed" >>"$_perr"; return 1
  fi

  # One background job per partition. Each gets its OWN status and error file:
  # POSIX `wait` reports only the last job's exit status, so a mid-list failure is
  # otherwise invisible, and concurrent appends to one shared error file interleave.
  # A missing status file counts as a failure, not as success.
  _i=0
  while [ "$_i" -lt "$MEDAKA_CODEGEN_PARTS" ]; do
    (
      if "$PCG_BIN/opt" "$_popt" "$_pdir/p$_i" -o "$_pdir/p$_i.opt.bc" 2>"$_pdir/p$_i.err" \
         && "$PCG_BIN/llc" "$_popt" -filetype=obj -relocation-model=pic \
              -function-sections -data-sections \
              "$_pdir/p$_i.opt.bc" -o "$_pdir/p$_i.o" 2>>"$_pdir/p$_i.err"
      then printf 'ok' > "$_pdir/p$_i.status"
      else printf 'fail' > "$_pdir/p$_i.status"
      fi
    ) &
    _i=$(( _i + 1 ))
  done
  wait

  _objs=""
  _i=0
  while [ "$_i" -lt "$MEDAKA_CODEGEN_PARTS" ]; do
    if [ "$(cat "$_pdir/p$_i.status" 2>/dev/null)" != "ok" ]; then
      echo "pcg: partition $_i failed opt/llc:" >>"$_perr"
      cat "$_pdir/p$_i.err" >>"$_perr" 2>/dev/null
      return 1
    fi
    _objs="$_objs $_pdir/p$_i.o"
    _i=$(( _i + 1 ))
  done

  # $_objs and the GC flag vars are deliberately unquoted word lists.
  "$CC" -pthread "$_popt" "$@" $GC_SECTION_CFLAGS $GC_CFLAGS $_objs "$RT" $GC_LIBS \
        "$GC_SECTION_LDFLAGS" -lm -o "$_pout" 2>>"$_perr"
}

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


# ---- STAGE A (WARM): existing emitter rebuilds itself from CURRENT source --------
# Skip ONLY when the emitter exists AND its stamp says it was built from exactly this
# compiler source AND runtime source (an up-to-date emitter re-emits byte-identically
# anyway; runtime/*.c is linked into the emitter binary, so it counts too — issue #182).
# A build-cache hit above already wrote $SRC_STAMP, so it lands in this same skip arm.
STAMP_FP=""
[ -f "$SRC_STAMP" ] && STAMP_FP="$(cat "$SRC_STAMP" 2>/dev/null)"
if [ "$FORCE_EMITTER_REBUILD" != "1" ] && [ -x "$EMITTER" ] && [ -n "$STAMP_FP" ] && [ "$STAMP_FP" = "$FP_FULL" ]; then
  echo "stage A: emitter up-to-date (emitter-closure + stdlib + runtime source fingerprint unchanged) — skipping rebuild."
else
  if [ "$FORCE_EMITTER_REBUILD" = "1" ]; then
    echo "stage A: FORCE_EMITTER_REBUILD=1 — rebuilding emitter from current source ..."
  elif [ -z "$STAMP_FP" ]; then
    # Either the cold branch above just minted it from the seed, or it was copied in
    # from another tree. Both are "provenance unknown" — rebuild rather than guess.
    echo "stage A: emitter provenance unknown (fresh bootstrap, or copied in from another tree) — rebuilding from current source ..."
  else
    echo "stage A: emitter source (its import closure, stdlib, or runtime) changed since this emitter was built — rebuilding emitter from current source ..."
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
  # medaka's own stage B), so an -O2 emitter emits noticeably faster than an -O0
  # one, at the one-time cost of a slower link here. Measured on this box (Debian
  # 13, 12-core/32GB) on 2026-09-05, with the two emitter binaries built from
  # identical source and run directly (`time ./medaka_emitter <runtime> <core>
  # <target> <compiler> <stdlib> > out.ll`):
  #   linking THIS binary: -O0 22.5s → -O2 74.3s (the "+3s once" framing no
  #     longer holds at current codebase size — it's now a real ~52s cost, paid
  #     once per emitter rebuild).
  #   emitter re-emitting its OWN driver graph: -O0 23.1s → -O2 15.6s (~32%
  #     faster).
  #   emitting compiler/driver/medaka_cli.mdk: -O0 117.0s → -O2 85.9s (~27%
  #     faster).
  #   oracle build (2-entry subset, `diff_compiler_parse*`, FORCE=1 JOBS=1 sh
  #     test/build_oracles.sh --for 'diff_compiler_parse*'): -O0 17.3s → -O2
  #     16.5s (~5% faster — the per-entry clang/link overhead of two small
  #     oracles dilutes the emitter's own emit-speed win; not re-measured
  #     against the full 53-entry set, which is too slow to run locally per
  #     [L-SHARED-BOX]). EMITTER_OPT overrides.
  if [ -n "$PCG_BIN" ]; then
    echo "stage A: parallel codegen ($MEDAKA_CODEGEN_PARTS partitions, $PCG_BIN) -> $EMITTER ..."
    if ! pcg_link "$EMIT_LL" "$EMIT_NEW" "${EMITTER_OPT:--O2}" "$WORK/emitA-cc.err"; then
      rm -f "$EMIT_NEW"
      echo "FAIL (parallel codegen, fresh emitter): $(cat "$WORK/emitA-cc.err")"; exit 1
    fi
  elif ! "$CC" -pthread "${EMITTER_OPT:--O2}" $GC_SECTION_CFLAGS $GC_CFLAGS "$EMIT_LL" "$RT" $GC_LIBS "$GC_SECTION_LDFLAGS" -lm -o "$EMIT_NEW" 2>"$WORK/emitA-cc.err"; then
    rm -f "$EMIT_NEW"
    echo "FAIL (clang fresh emitter): $(cat "$WORK/emitA-cc.err")"; exit 1
  fi
  mv "$EMIT_NEW" "$EMITTER"
  echo "stage A: rebuilt $EMITTER from current source."
  cache_put "$EMITTER_KEY" "$EMITTER"
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
if [ "$FORCE_EMITTER_REBUILD" != "1" ] && [ "$SKIP_CLI_LINK_IF_FRESH" = "1" ] \
   && [ "$CLI_STAMP_APPLIES" = "1" ] \
   && [ -x "$OUT" ] && [ -n "$CLI_STAMP_FP" ] && [ "$CLI_STAMP_FP" = "$FP_COMPILER" ]; then
  echo "stage B: medaka up-to-date (compiler source fingerprint unchanged) — skipping rebuild."
elif [ "$FORCE_EMITTER_REBUILD" != "1" ] && cache_get "$CLI_KEY" "$OUT"; then
  # Reached even with SKIP_CLI_LINK_IF_FRESH unset: a cache hit costs a file copy, so
  # there is nothing for the default "always relink" policy to buy here. The key pins
  # the compiler source, the runtime source, the -O level and the two provenance strings
  # stage B bakes in, so the served binary is the one this link would have produced.
  #
  # FORCE_EMITTER_REBUILD suppresses the hit even so, matching stage A's own guard: a
  # cached ./medaka was emitted by whichever emitter held that key's source, so serving
  # it here would pair a freshly rebuilt emitter with a CLI the OLD one produced —
  # exactly the crossed-arm result [T-EMITTER-BENCH]'s two-rebuild protocol exists to
  # rule out, and the flag's only purpose is to make both stages real.
  echo "stage B: medaka restored from build cache ($CLI_KEY) — skipping the emit and the link."
else
  CLI_LL="$WORK/medaka_cli.ll"
  echo "stage B: medaka_emitter -> medaka_cli.ll ..."
  if ! emit_graph "$CLI_LL" "$WORK/emit.err" "$CLI"; then
    echo "FAIL (emitter crashed compiling medaka_cli.mdk):"; cat "$WORK/emit.err"; exit 1
  fi
  trim_unit "$CLI_LL"
  [ -s "$CLI_LL" ] || { echo "FAIL: empty IR for medaka_cli.mdk"; cat "$WORK/emit.err"; exit 1; }

  # `medaka run`/`test`/`check` run the CLI's tree-walk interpreter, which is
  # noticeably faster at -O2, so -O2 is the default here (matching the emitter),
  # even though clang linking the CLI itself at -O2 is a real one-time cost, not
  # the old "+~4s" estimate: measured on this box (Debian 13, 12-core/32GB) on
  # 2026-09-05, `clang` linking the SAME emitted medaka_cli IR: CLI_OPT=-O0
  # 6.8s → CLI_OPT=-O2 94.6s. Interpreter speed itself, measured the same day
  # with `MEDAKA_STRICT=1 time ./medaka test stdlib/list.mdk`: CLI_OPT=-O0
  # 4.78s → CLI_OPT=-O2 2.44s — about 2x faster, at current stdlib/interpreter
  # size. For build-heavy loops where the CLI's own ~88s extra link time
  # dominates instead, opt out with CLI_OPT=-O0.
  # (The EMITTER, by contrast, is always -O2 — it's the reused workhorse; see stage A.)
  CLI_OPT="${CLI_OPT:--O2}"
  # Always the plain single clang link — never pcg_link, even when $PCG_BIN is set
  # for stage A. See the CLI runtime-regression measurement in "PARALLEL CODEGEN"
  # above (S-codegen-cost-honest, 2026-09-05): partitioning the CLI's own IR costs
  # ~5.5% on every `medaka check`/`test`/`run` afterward, which is paid far more
  # often than this link.
  echo "stage B: clang(medaka_cli.ll, $CLI_OPT) -> $OUT ..."
  # STALENESS STAMP (issue #89): bake the COMPILER-source fingerprint into ./medaka
  # so the CLI can warn when it is run against a NEWER compiler/ than it was built
  # from.  The -D hits ONLY this C compile of medaka_rt.c — never the emitter IR —
  # so it is fixpoint/seed-safe (the text IR is produced before clang runs).  We bake
  # FP_COMPILER (compiler/**.mdk + stdlib/**.mdk), NOT FP_FULL: the driver's
  # `liveSourceFingerprint` (compiler/driver/medaka_cli.mdk) recomputes the SAME
  # file set as a hash at runtime and hard-fails a mismatch under MEDAKA_STRICT,
  # so the baked value must stay byte-for-byte identical to that live computation.
  # FP_FULL (which additionally folds in runtime/*.c for the emitter-rebuild
  # trigger, issue #182) is written to .medaka_emitter.srcstamp below, a
  # DIFFERENT consumer.
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
  cache_put "$CLI_KEY" "$OUT"
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
