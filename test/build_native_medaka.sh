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

# ---- PARALLEL CODEGEN: ThinLTO on BOTH links (issues #2681, #2725) --------------
# ON BY DEFAULT where the LLVM tools it needs are actually present, and used for
# BOTH links this script performs: stage A's emitter and stage B's ./medaka CLI.
#
# Handing clang one ~17 MB (emitter) or ~35 MB (CLI) IR module gets one
# single-threaded -O2 pipeline out of a 12-core box. When lld is discoverable,
# pcg_link instead cuts that module into ONE PARTITION PER SOURCE MODULE
# (pcg_partition, from the emitter's own `; mdk-module` markers), compiles each to
# ThinLTO bitcode CONCURRENTLY (`clang -x ir -O2 -flto=thin -c`, $MEDAKA_CODEGEN_JOBS
# at a time), and hands the results to a single ThinLTO link whose backend is itself
# parallel (`-flto=thin -fuse-ld=lld -Wl,--thinlto-jobs=N`). ThinLTO's per-module
# summaries carry inlining ACROSS partition boundaries, which is the thing a
# partition-local `opt`/`llc` scheme gives up. Set MEDAKA_PARALLEL_CODEGEN=0 to force
# the single `clang -O2` link on both stages; that is also what runs, silently but
# positively logged, wherever lld is absent (CI runner layouts vary — see
# pcg_discover, and MEDAKA_LLVM_BINDIR there for a toolchain it would not find).
#
# Partitioning by MODULE rather than by round-robin function (issue #2727) makes a
# partition's bytes depend only on the modules in it, so lld's --thinlto-cache-dir
# serves every partition an edit did not touch. Measured on the stage-B IR, one
# partition of 77 moved by each: a one-line edit to compiler/tools/lint.mdk, and a
# one-line edit to compiler/frontend/desugar.mdk. Round-robin gave every partition a
# share of every edit, and its module identifiers additionally carried the per-build
# `mktemp` path, which put a fresh key on every entry (issue #2752, fixed by the `cd`).
#
# Two things still cost more than one partition, both by construction rather than by
# accident. @mdk_program_main is the concatenation of every module's initializers and
# lives in the `program` partition, so adding or removing a TOP-LEVEL binding moves
# that partition as well as the module's own. And an edit inside the EMITTER's import
# closure rebuilds the emitter in stage A, after which a different emitter emits
# stage B — every module whose IR that changes is a real change, not a partitioning
# artifact. Measured, both stages, warm cache: a lint.mdk edit wrote 7 of 117 cache
# entries with stage A skipped; renaming a generated binder in desugar.mdk, which
# touches every desugared `do` block in the tree, wrote 18.
#
# 🚨 GRANULARITY IS THE WHOLE MECHANISM, not a tuning parameter. lld keys the cache
# on a module's import closure as well as on its own bytes, so a partition is
# skippable only if it does not import the one that changed. Coalescing the CLI's
# 411 scopes into 8 fat partitions makes every partition an importer of every other,
# and the cache then serves NOTHING after an edit. Measured on the real CLI IR with
# the partition objects held fixed and only the link timed:
#            cold   relink, same objects   relink after a 2-line lint.mdk edit
#   8 parts   24s   0s  (10/10 reused)     23s   (8 entries written, 1 reused)
#   73 parts  32s   1s  (74/74 reused)     6s    (5 entries written, 68 reused)
# The 5 written at module granularity are the edited partition plus its four real
# importers — the cost the mechanism is supposed to have. That is why the partition
# count is DERIVED from the module set and not set to a machine-sized number, and
# why $MEDAKA_CODEGEN_JOBS is a separate knob: the two used to be one variable, and
# tying the partition count to the core count is what made the cache useless.
#
# 🚨 NOTHING PER-BUILD MAY ENTER THE LTO UNIT, or the cache above is worthless.
# Every partition imports from runtime/medaka_rt.c, so anything that changes that
# file's summary hash changes every partition's cache key. The three build-provenance
# stamps are the standing instance: they change on every compiler edit, so they live
# in a generated three-line provenance.c compiled WITHOUT -flto (see stage B) and
# medaka_rt.c stays byte-identical across builds. Measured on identical partitions
# and one edit, varying only the fingerprint: unchanged — 4s, 5 entries written, 68
# reused; changed — 23s, 73 written, 0 reused. Moving medaka_rt.c itself out of the
# LTO unit fixes the cache the same way and costs ~7.7% of interpreter runtime over
# 3 interleaved reps — the trade the naive-split arm below already lost.
#
# ONE BUILD PER WORKTREE IS UN-PARTITIONED BY CONSTRUCTION, and that is not a bug to
# fix. Stage A always runs the PREVIOUS generation's emitter, so in a worktree whose
# ./medaka_emitter was built before the `; mdk-module` markers existed, stage A's IR
# has none. pcg_partition degrades that to a single ThinLTO module, labelled
# thinlto-nomark-1 in the log and in the build-cache key (it is a different binary
# from a partitioned one and must not be served as one). The emitter stage A builds
# from that IR does emit markers, so stage B and every build after it partition
# normally. A marker that is present but unreadable is still a hard failure.
#
# Measured on this box (Debian 13, 12-core/32GB) on 2026-09-08, on the real emitted
# CLI IR (34.6 MB):
#   * FULL-MISS BUILD is unmoved by granularity: stage-B link 43.5s at 8 partitions
#     vs 42.5s at 73, 2 reps each interleaved on a fresh $MEDAKA_SCRATCH.
#   * A warm stage-B link is mostly NOT the link: partitioning and the partition
#     compiles are redone every build and only the ThinLTO backend is cached, so
#     the floor for an unchanged rebuild is the partition + compile cost, not 0.
#   * INTERPRETER RUNTIME — what every `medaka check`/`test`/`run`, i.e. every gate
#     and oracle in the tree, pays on every invocation, far more often than the CLI
#     is relinked: `check compiler/backend/llvm_emit.mdk`, 3 reps interleaved —
#     plain 15.3s mean, ThinLTO 13.9s, naive split 16.3s. ThinLTO was not slower
#     than plain in any single rep. Granularity does not cost it either: 73
#     partitions measured 14.82s against 15.68s at 8, faster in all three reps,
#     because ThinLTO importing follows the combined summary index and not
#     partition membership.
# The CLI link previously stayed on the plain path because a naive-split CLI
# measured ~5.5% slower at interpreter runtime. That regression is a property of
# NAIVE SPLITTING, not of parallel codegen: it reproduces above as the 16.3s arm,
# and ThinLTO — which keeps cross-partition inlining — does not pay it. So both
# stages take this path now, and $PCG_MODE below describes both.
MEDAKA_PARALLEL_CODEGEN="${MEDAKA_PARALLEL_CODEGEN:-1}"
# HOW MANY partitions. Empty (the default) means DERIVED: one partition per module
# scope in the IR, with each `impl:` group folded onto the module scope before it
# and `program` alone at the end — 73 on the CLI IR, 42 on the emitter's. It is
# derived rather than fixed because the useful number is a property of the source,
# not of the box: what a partition is FOR is to be the unit the ThinLTO cache can
# skip, and a partition holding several modules is skippable only when none of them
# changed. Set it to an integer to coalesce to exactly that many instead, which is
# what the override is for and what a bisect wants.
#
# 🚨 A SMALL value is not a cheaper version of this — it is a different mechanism.
# Coalescing the CLI's 411 scopes into 8 partitions makes every partition an
# importer of every other, so a two-line edit to one module wrote 8 fresh ThinLTO
# cache entries and reused ONE, at 23s of link. The derived count reused 68 of 73,
# at 6s. Full-miss link time and interpreter runtime were both unmoved by the
# difference (measurements under "PARALLEL CODEGEN" above).
MEDAKA_CODEGEN_PARTS="${MEDAKA_CODEGEN_PARTS:-}"
# 0 is not a spelling of "auto": empty already means that, so a 0 is a typo or a
# shell variable that did not expand, and it used to reach awk as a partition count
# of zero and die there in awk's own words. Rejected here, before anything is built.
case "${MEDAKA_CODEGEN_PARTS:-auto}" in
  auto) ;;
  0|*[!0-9]*)
    echo "MEDAKA_CODEGEN_PARTS must be empty (one partition per module scope) or an integer >= 1; got '$MEDAKA_CODEGEN_PARTS'." >&2
    exit 1 ;;
esac

# HOW MANY concurrent jobs, which is a property of the box and NOT of the source:
# it bounds both the partition-compile fan-out and --thinlto-jobs, two concurrency
# levels that never overlap in time (the compiles finish before the link starts,
# and both links are serial points in this script). 8 on this 12-core box is the
# value the ThinLTO path was measured at; leaving ~4 cores idle keeps a concurrent
# build, or the emitter's own GC threads, from contending. It is NOT derived from
# nproc: that would silently re-tune every measurement in this file to whatever
# machine reran it. Setting it to 1 is not the same as MEDAKA_PARALLEL_CODEGEN=0 —
# the module is still partitioned and still linked through ThinLTO, just serially.
MEDAKA_CODEGEN_JOBS="${MEDAKA_CODEGEN_JOBS:-8}"

# lld is the ONLY external tool this path needs, and it is where the parallel
# ThinLTO backend and --thinlto-jobs come from, so every non-Darwin candidate
# directory must hold it. macOS is the exception: ld64.lld does not reliably link
# system frameworks, and Apple's own `ld` supports `-flto=thin` directly, so there
# the link goes through the system linker (see PCG_LTO_LDFLAGS) and NO tool
# directory is required at all. Untested on macOS — no Darwin box was available
# when this was written.
#
# The partitioning needs no tool at all: pcg_partition below cuts the module by its
# own `; mdk-module` markers, in awk.
PCG_NEED_LLD=1
[ "$(uname -s)" = "Darwin" ] && PCG_NEED_LLD=0

# Whether directory $1 supplies what the ThinLTO path needs there: ld.lld off
# Darwin, nothing but its own existence on it. The existence test is not
# ceremony — it is what keeps MEDAKA_LLVM_BINDIR pointed at a toolless directory
# a working way to exercise the plain-clang fallback on BOTH platforms.
pcg_has_tools() {
  [ -d "$1" ] || return 1
  [ "$PCG_NEED_LLD" = "0" ] && return 0
  [ -x "$1/ld.lld" ]
}

# Where ld.lld lives. $MEDAKA_LLVM_BINDIR, if set, is searched INSTEAD of
# everything else — an operator knob for a toolchain in a nonstandard place, and
# the seam that lets the fallback path be exercised rather than asserted (point it
# at a directory without the tools). Otherwise: PATH first; then the versioned
# Debian/Ubuntu directories, which put ld.lld OFF PATH (on this box only
# /usr/bin/clang is on it); then the two Homebrew prefixes, for [B-DUAL-PLATFORM].
# Highest version wins among the /usr/lib/llvm-* candidates. Prints the directory
# to use, or returns nonzero when none supplies it — a runner without lld must
# degrade to the plain clang path, never fail, so no layout is hardcoded as the
# only place to look.
#
# The printed value is used as a directory PREFIX for `-fuse-ld`, so it must be the
# directory that actually holds ld.lld. Off Darwin there is no such directory to
# name: the value is a label for the log line, and PCG_LTO_LDFLAGS never reads it.
pcg_discover() {
  if [ -n "${MEDAKA_LLVM_BINDIR:-}" ]; then
    if pcg_has_tools "$MEDAKA_LLVM_BINDIR"; then
      printf '%s' "$MEDAKA_LLVM_BINDIR"
      return 0
    fi
    return 1
  fi
  if [ "$PCG_NEED_LLD" = "0" ]; then
    printf 'system-ld'
    return 0
  fi
  for _d in "" $(ls -d /usr/lib/llvm-*/bin 2>/dev/null | sort -r) \
            /opt/homebrew/opt/llvm/bin /usr/local/opt/llvm/bin; do
    if [ -z "$_d" ]; then
      if command -v ld.lld >/dev/null 2>&1; then
        _pd="$(dirname "$(command -v ld.lld)")"
        if pcg_has_tools "$_pd"; then
          printf '%s' "$_pd"
          return 0
        fi
      fi
    elif pcg_has_tools "$_d"; then
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
# The one value every later reader asks for: which codegen path this build's links
# take. Folded into BOTH build-cache keys below, because two binaries built from
# identical source down the two paths are NOT the same bytes — and a key that did
# not carry it would serve one path's binary under the other's name, making any
# later before/after measurement a comparison of one binary with itself.
#
# The `mod` names the PARTITIONING SCHEME, not just the tool. It is there because
# the round-robin scheme this replaced also spelled itself `thinlto-<N>`, so a
# binary one scheme cached would be served under the other's key and launder
# exactly the before/after measurement this field exists to protect. A future
# scheme gets its own word here, in the same commit that introduces it.
#
# The partition COUNT is derived per input, so it is not known here and the label
# says `auto` rather than a number; the per-stage log lines carry the real count.
# The job count is deliberately absent: it changes how long the link takes, never
# what it produces, so folding it in would split the cache for no gain.
PCG_PARTS_USED=""
PCG_MODE_USED=""
if [ -n "$PCG_BIN" ]; then
  PCG_MODE="thinlto-mod-${MEDAKA_CODEGEN_PARTS:-auto}"
else
  PCG_MODE="plain"
fi
# What the build ACTUALLY used. pcg_link overwrites it per input; on the plain path,
# and before any link has run, it is just $PCG_MODE.
PCG_MODE_USED="$PCG_MODE"

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
# records FP_COMPILER, not FP_FULL, because that is exactly what stage B stamps into
# the binary through its provenance object and what `liveSourceFingerprint` recomputes at
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
#   FP_COMPILER  = compiler/**.mdk + stdlib/**.mdk.  Stamped into ./medaka by the
#                  generated provenance object (stage B) and recomputed at runtime by
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
    _closure="$(awk -v entry="$FP_ENTRY" -v roots="$FP_ROOTS" -f test/emitter_source_set.awk /dev/null)" || _closure=""
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
#   * $PCG_MODE, on BOTH keys — the codegen PATH and its partition count (see
#     "PARALLEL CODEGEN" above). `plain` and `thinlto-8` are different codegen of
#     the same IR at the same -O level, so the two produce binaries that behave
#     identically but are not the same bytes. Without this component a box that
#     flipped MEDAKA_PARALLEL_CODEGEN, or one that simply has the LLVM tools where
#     another does not, would serve the other path's binary under this path's key —
#     and any later measurement of the two paths against each other would be
#     comparing one binary to itself. Both links take the path now, so both keys
#     carry it; the CLI key's former literal `plain` tag described a CLI link that
#     no longer exists.
#   * for the CLI only, $BUILD_COMMIT and $BUILD_DATE, which stage B stamps in
#     alongside the fingerprint. Two commits can share one
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
# Keyed on the codegen mode the build actually used, which is not always the one
# chosen up front: marker-less stage-A IR degrades to thinlto-nomark-1 and produces a
# different binary, so it must not be stored under the name of a partitioned one.
emitter_key_for() {
  printf 'emitter-%s-%s-%s' "$(cache_tag "$FP_FULL")" "$(cache_tag "${EMITTER_OPT:--O2}")" "$(cache_tag "$1")"
}
EMITTER_KEY="$(emitter_key_for "$PCG_MODE")"
cli_key_for() {
  printf 'medaka-%s-%s-%s-%s-%s-%s' "$(cache_tag "$FP_COMPILER")" "$(cache_tag "$FP_RUNTIME")" \
    "$(cache_tag "${CLI_OPT:--O2}")" "$(cache_tag "$1")" "$(cache_tag "$BUILD_COMMIT")" "$(cache_tag "$BUILD_DATE")"
}
CLI_KEY="$(cli_key_for "$PCG_MODE")"

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

# ---- ThinLTO link flags (see PARALLEL CODEGEN above) ---------------------------
# The ThinLTO backend writes one object per imported-summary group and can reuse
# them across links. Its keys are computed over each module's IDENTIFIER, which is
# the path clang was handed — so this cache only ever hits because pcg_link runs
# the partition compiles from inside the partition directory under RELATIVE names
# (issue #2752). What an EDIT then costs depends on how many partitions import the
# changed one — see the granularity paragraph under "PARALLEL CODEGEN".
# It lives under $MEDAKA_SCRATCH for the same reason the build cache does:
# /tmp on the dev box is a RAM-backed tmpfs, and a cache that evaporates under
# memory pressure is not a cache. `mkdir -p` failure is ignored — an unwritable
# cache directory makes the link cold, never broken.
#
# `-fuse-ld` is given lld's ABSOLUTE path: on this box ld.lld is not on PATH (only
# /usr/bin/clang is), and clang accepts an absolute path here where a bare `lld`
# would not resolve. macOS instead links through Apple's `ld`, which understands
# `-flto=thin` but has neither --thinlto-jobs nor --thinlto-cache-dir; its cache
# knob is -cache_path_lto and its backend parallelism is not ours to set. UNTESTED
# on macOS — no Darwin box was available; the flags are written from ld64's
# documented spelling, not from a measurement.
PCG_CACHE_DIR="$MEDAKA_SCRATCH/medaka-thinlto-cache"
PCG_LTO_LDFLAGS=""
if [ -n "$PCG_BIN" ]; then
  mkdir -p "$PCG_CACHE_DIR" 2>/dev/null || true
  case "$(uname -s)" in
    Darwin) PCG_LTO_LDFLAGS="-Wl,-cache_path_lto,$PCG_CACHE_DIR" ;;
    *) PCG_LTO_LDFLAGS="-fuse-ld=$PCG_BIN/ld.lld -Wl,--thinlto-jobs=$MEDAKA_CODEGEN_JOBS -Wl,--thinlto-cache-dir=$PCG_CACHE_DIR" ;;
  esac
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---- pcg_partition: cut the emitted IR by SOURCE MODULE ------------------------
#
#   pcg_partition <in.ll> <outdir> <n>     -> writes <outdir>/p0 .. p<k-1>,
#                                             prints "<k> mod" or "<k> nomark"
#
# <n> empty means DERIVE k: one partition per module scope, each `impl:` group
# folded onto the module scope that precedes it, `program` alone at the end. <n>
# nonzero coalesces to exactly n instead (see MEDAKA_CODEGEN_PARTS).
#
# IR WITH NO MARKERS AT ALL degrades to one partition holding the input verbatim,
# printing "1 nomark", because the caller cannot avoid meeting it: stage A always
# runs the PREVIOUS generation's emitter, and in every worktree whose
# ./medaka_emitter predates the markers that emitter is what produces stage A's IR.
# Failing there would make the first build after this landed a hard error for every
# developer and every warm CI cache, for one build — stage B, run by the emitter
# stage A just rebuilt, partitions normally, and so does every build after it.
#
# A marker that IS present but unusable stays a hard failure: it means the emitter
# is producing corrupt IR, and binning by a marker this file cannot read would put
# entities in the preamble and duplicate them into every partition.
#
# The emitter precedes every top-level entity with a `; mdk-module <scope>` comment,
# where <scope> is a module id (`frontend_lexer`), an impl-group key (`impl:List_eq`)
# or `program` (dispatchers, interface defaults, @mdk_program_main, the $memo
# forcers). Scopes are NOT contiguous in the text, so this bins by marker and never
# by position. Only a marker at TOP LEVEL moves the current scope, which is what the
# `define`/`}` state machine is for: a marker inside a function body would be a
# comment about an instruction, and acting on it would split a define from its own
# scope. The emitter currently emits none there, and this does not rely on that.
#
# A partition's bytes then depend only on the modules IN it, so editing one module
# leaves the other partitions byte-identical and the ThinLTO cache can serve them —
# but only if the changed partition is not an importer of most of the rest, which is
# why the default is one module per partition rather than a handful of big ones. It
# also isolates @mdk_program_main, which concatenates every module's initializers and
# therefore moves whenever any module gains or loses a top-level binding.
#
# Two things a text split has to do that llvm-split did in the IR:
#   * local-linkage globals (`private` string constants, `internal` closure records)
#     are referenced across partition boundaries, so their definitions are promoted
#     from private/internal to `hidden` — external linkage, still not exported from
#     the binary, and exactly what llvm-split emitted for the same globals. lld's
#     LTO re-internalizes what stays partition-local.
#   * a partition needs a declaration for every symbol it references but does not
#     define. They are derived from the definition text and appended (top-level IR
#     is order-insensitive), and ONLY for symbols the partition actually mentions —
#     declaring everything everywhere would put every module's string-constant types
#     in every partition and hand the cache a miss on every edit.
# The `; mdk-module` markers themselves are dropped: 3.7% of the IR text, and clang
# does not need them.
#
# Both halves of that promise depend on every entity carrying a marker: an entity
# that reached the preamble instead would be BROADCAST, i.e. defined n times over.
# That is why an unreadable marker is refused rather than skipped.
pcg_partition() {
  awk -v PARTS="$3" -v DIR="$2" '
  # The type of a global, as the balanced prefix of the text after `constant`/
  # `global`: `{ i64, i64, i64, [2 x i8] }` before its initializer, `[2 x i64]`
  # before its elements, or a bare `i64`.
  function typeprefix(s,   c, o, cl, d, i, ch, n) {
    c = substr(s, 1, 1)
    if (c == "{") { o = "{"; cl = "}" }
    else if (c == "[") { o = "["; cl = "]" }
    else { i = index(s, " "); return (i > 0 ? substr(s, 1, i - 1) : s) }
    d = 0; n = length(s)
    for (i = 1; i <= n; i++) {
      ch = substr(s, i, 1)
      if (ch == o) d++
      else if (ch == cl) { d--; if (d == 0) return substr(s, 1, i) }
    }
    return ""
  }
  function die(msg) { print "pcg: " msg > "/dev/stderr"; bad = 1; exit 1 }
  function note(s) { if (!(s in sz)) { sz[s] = 0; ord[++nord] = s } }
  function assign(   i, s, tot, mp, tgt, cum, p, cnt) {
    if (markers == 0) { DEG = 1; NPARTS = 1; part[""] = 0; OF[0] = DIR "/p0"; return }
    if (PARTS == "") {
      # Derived: a partition per module scope. An `impl:` group joins the module
      # before it — impl groups are numerous: 337 of the 414 scopes in the CLI IR,
      # and tiny, and the module they follow is the one whose edit moves them.
      p = -1
      for (i = 1; i <= nord; i++) {
        s = ord[i]
        if (s == "program" || s == "") continue
        if (substr(s, 1, 5) == "impl:") { if (p < 0) p = 0; part[s] = p; continue }
        part[s] = ++p
      }
      NPARTS = p + 2
      part["program"] = p + 1
    } else {
      tot = 0
      for (i = 1; i <= nord; i++) if (ord[i] != "program") tot += sz[ord[i]]
      mp = PARTS - 1; if (mp < 1) mp = 1
      tgt = tot / mp
      cum = 0; p = 0
      for (i = 1; i <= nord; i++) {
        s = ord[i]
        if (s == "program") { part[s] = PARTS - 1; continue }
        # Close a partition BEFORE the scope that would overshoot it, never after:
        # types_typecheck alone is a fifth of the module, and appending it to a
        # nearly-full partition is how one job ends up doing a third of the work.
        if (p < mp - 1 && cnt[p] > 0 && cum + sz[s] > tgt * (p + 1)) p++
        part[s] = p; cnt[p]++
        cum += sz[s]
      }
      NPARTS = PARTS
    }
    part[""] = 0
    for (i = 0; i < NPARTS; i++) OF[i] = DIR "/p" i
  }
  # ONE output file open at a time. A partition per module means ~77 of them, and
  # one-true-awk (the /usr/bin/awk of older macOS) caps simultaneous output
  # redirections near 17 — writing to the 18th is a runtime error, not a slow path.
  # Lines arrive in scope order, so switching costs one close per marker.
  function put(f, l) {
    if (f != curf) { if (curf != "") close(curf); curf = f }
    if (f in opened) print l >> f
    else { print l > f; opened[f] = 1 }
  }
  function emit(l,   s, sym) {
    # The preamble belongs to every partition. Buffered rather than broadcast, so
    # it costs one append per partition at END instead of NPARTS open files here.
    if (tp < 0) { pre[++npre] = l; return }
    put(OF[tp], l)
    if (index(l, "@")) {
      s = l
      while (match(s, /@[-a-zA-Z$._0-9]+/)) {
        sym = substr(s, RSTART, RLENGTH)
        # Remember the ORDER of first reference, not just the fact of it. The
        # declarations below are written in this order, so the partition bytes do not
        # depend on which awk ran: `for (k in ref)` is hash order, and gawk, mawk and
        # busybox awk each give a different one — which would give the same source
        # three different sets of ThinLTO cache keys.
        if (!((tp, sym) in ref)) { ref[tp, sym] = 1; rlist[tp, ++rn[tp]] = sym }
        s = substr(s, RSTART + RLENGTH)
      }
    }
  }
  BEGIN { ind = 0; cur = ""; tp = -1; markers = 0; bad = 0; note("") }

  # ---- pass 1: scope sizes, symbol owners, and each symbol s external declaration
  NR == FNR {
    if (ind) { sz[cur]++; if ($0 ~ /^\}/) ind = 0; next }
    if ($0 ~ /^; mdk-module($| )/) {
      cur = substr($0, 14)
      sub(/^[ \t]+/, "", cur); sub(/[ \t]+$/, "", cur)
      if (cur == "") die("`; mdk-module` marker with no scope name at line " FNR " — the emitted IR is corrupt")
      markers++; note(cur); next
    }
    sz[cur]++
    if ($0 ~ /^define /) {
      ind = 1
      nm = $3; sub(/\(.*/, "", nm)
      d = $0; sub(/^define /, "declare ", d); sub(/[ \t]*\{[ \t]*$/, "", d)
      owner[nm] = cur; decl[nm] = d
      next
    }
    if ($0 ~ /^@/) {
      nm = $1
      rest = $0; sub(/^[^ ]+ = /, "", rest)
      nt = split(rest, T, " ")
      kw = 0
      for (i = 1; i <= nt; i++) if (T[i] == "constant" || T[i] == "global") { kw = i; break }
      if (!kw) die("unrecognized global definition: " $0)
      vis = ""; st = 1
      if (T[1] == "private" || T[1] == "internal") { vis = "hidden "; st = 2 }
      head = ""
      for (i = st; i <= kw; i++) head = head (head == "" ? "" : " ") T[i]
      after = rest
      for (i = 1; i <= kw; i++) sub(/^[^ ]+ +/, "", after)
      ty = typeprefix(after)
      if (ty == "") die("cannot read the type of global " nm ": " $0)
      owner[nm] = cur; decl[nm] = nm " = external " vis head " " ty
      next
    }
    next
  }

  # ---- pass 2: write each line to its partition (preamble to all of them)
  {
    if (!assigned) { assign(); assigned = 1 }
    # Degraded: one partition, byte-identical to the input. No linkage promotion and
    # no synthesized declarations, because nothing crosses a partition boundary.
    if (DEG) { put(OF[0], $0); next }
    if (ind) { emit($0); if ($0 ~ /^\}/) ind = 0; next }
    if ($0 ~ /^; mdk-module($| )/) {
      cur = substr($0, 14)
      sub(/^[ \t]+/, "", cur); sub(/[ \t]+$/, "", cur)
      tp = part[cur]; next
    }
    l = $0
    if (l ~ /^define /) ind = 1
    else if (l ~ /^@/) { sub(/ = private /, " = hidden ", l); sub(/ = internal /, " = hidden ", l) }
    emit(l)
  }

  END {
    if (bad) exit 1
    if (curf != "") { close(curf); curf = "" }
    if (DEG) { print "1 nomark"; exit 0 }
    # One pass per partition, each opening its file once: the preamble it shares with
    # every other partition, then a declaration for each symbol it references but does
    # not define, in first-reference order.
    for (q = 0; q < NPARTS; q++) {
      if (!(OF[q] in opened)) { printf "" > OF[q]; opened[OF[q]] = 1 }
      for (i = 1; i <= npre; i++) print pre[i] >> OF[q]
      for (i = 1; i <= rn[q]; i++) {
        sym = rlist[q, i]
        if (!(sym in owner)) continue
        if (part[owner[sym]] == q) continue
        print decl[sym] >> OF[q]
      }
      close(OF[q])
    }
    print NPARTS " mod"
  }
  ' "$1" "$1"
}

# ---- pcg_link: the ThinLTO half of PARALLEL CODEGEN (issues #2681, #2725, #2752) -
#
#   pcg_link <in.ll> <out-binary> <-O level> <errfile> [extra clang args ...]
#
# Partition the module by source module, compile each partition to ThinLTO bitcode
# concurrently, then let clang drive one ThinLTO link — which is also where
# runtime/medaka_rt.c is compiled, so the trailing args reach that compile exactly
# as they do on the plain path. Stage B passes its provenance object that way; with
# -flto=thin the C file becomes thin bitcode too, while that object stays a plain
# one, which is the point of it (see stage B).
#
# Returns nonzero on any failure with the reason appended to <errfile>; both call
# sites treat that exactly as they treat a clang failure, so a partition that
# cannot be split or compiled is a hard build failure, never a silent fallback to a
# binary built some other way.
#
# 🚨 THE PARTITION COMPILES AND THE LINK RUN WITH $_pdir AS THE WORKING DIRECTORY
# and name the partitions relatively. clang stamps the input path into the module
# identifier it writes into the bitcode, and lld keys the ThinLTO cache on that
# identifier — so an absolute name under a per-build `mktemp -d` gives every module
# a unique key and the cache the link is handed can never hit. Measured before this
# was fixed: two identical forced builds wrote 34 fresh entries and reused none.
# The caller's paths are absolutized here because that cd invalidates a relative one.
#
# 🚨 The partition files are EXTENSIONLESS, and `clang -c` on one fails instantly
# with "unknown file type" unless it is told `-x ir`. Inside the `&` fan-out below
# that failure would be silent and the whole "build" would finish in seconds with no
# objects at all — which is why every partition's status file is checked for `ok`
# AND its .o is checked for existence before the link.
#
# $GC_SECTION_CFLAGS is passed to the partition compiles as well as the link:
# without per-function/-data sections in the emitted objects, $GC_SECTION_LDFLAGS
# has nothing per-symbol to strip and the section-level DCE of issue #120 quietly
# stops working.
pcg_link() {
  _ll="$1"; _pout="$2"; _popt="$3"; _perr="$4"
  shift 4
  case "$_ll"   in /*) ;; *) _ll="$PWD/$_ll" ;; esac
  case "$_pout" in /*) ;; *) _pout="$PWD/$_pout" ;; esac
  case "$_perr" in /*) ;; *) _perr="$PWD/$_perr" ;; esac
  _pdir="$WORK/pcg.$$"
  rm -rf "$_pdir"
  mkdir -p "$_pdir" || { echo "pcg: cannot create $_pdir" >>"$_perr"; return 1; }

  # PCG_PARTS_USED and PCG_MODE_USED are what this input actually got: both are
  # per-input (the count under the derived default, the scheme when marker-less IR
  # degrades), so the caller's log line and its cache key read them from here rather
  # than from $MEDAKA_CODEGEN_PARTS and $PCG_MODE, which are decided before any IR
  # exists.
  _pinfo="$(pcg_partition "$_ll" "$_pdir" "$MEDAKA_CODEGEN_PARTS" 2>>"$_perr")"
  PCG_PARTS_USED="${_pinfo% *}"
  case "$PCG_PARTS_USED" in
    ''|*[!0-9]*) echo "pcg: module partitioning failed" >>"$_perr"; return 1 ;;
  esac
  if [ "${_pinfo#* }" = "nomark" ]; then
    PCG_MODE_USED="thinlto-nomark-1"
  else
    PCG_MODE_USED="$PCG_MODE"
  fi

  (
    cd "$_pdir" || exit 1

    # $MEDAKA_CODEGEN_JOBS workers, each taking every JOBSth partition. A worker
    # POOL and not one job per partition: there are as many partitions as modules
    # now, and 73 concurrent -O2 clangs on a 12-core box is not a build, it is a
    # thrash. Striding rather than waves of $JOBS means the one 200k-line partition
    # never barriers the rest behind it.
    # Each compile gets its OWN status and error file: POSIX `wait` reports only the
    # last job's exit status, so a mid-list failure is otherwise invisible, and
    # concurrent appends to one shared error file interleave. A missing status file
    # counts as a failure, not as success.
    _j=0
    while [ "$_j" -lt "$MEDAKA_CODEGEN_JOBS" ]; do
      (
        _k=$_j
        while [ "$_k" -lt "$PCG_PARTS_USED" ]; do
          if "$CC" -x ir "$_popt" -flto=thin -c $GC_SECTION_CFLAGS \
               "p$_k" -o "p$_k.o" 2>"p$_k.err"
          then printf 'ok' > "p$_k.status"
          else printf 'fail' > "p$_k.status"
          fi
          _k=$(( _k + MEDAKA_CODEGEN_JOBS ))
        done
      ) &
      _j=$(( _j + 1 ))
    done
    wait

    _objs=""
    _i=0
    while [ "$_i" -lt "$PCG_PARTS_USED" ]; do
      if [ "$(cat "p$_i.status" 2>/dev/null)" != "ok" ] || [ ! -s "p$_i.o" ]; then
        echo "pcg: partition $_i produced no ThinLTO object:" >>"$_perr"
        cat "p$_i.err" >>"$_perr" 2>/dev/null
        exit 1
      fi
      _objs="$_objs p$_i.o"
      _i=$(( _i + 1 ))
    done

    # $_objs, $PCG_LTO_LDFLAGS and the GC flag vars are deliberately unquoted word lists.
    "$CC" -pthread "$_popt" -flto=thin $PCG_LTO_LDFLAGS "$@" $GC_SECTION_CFLAGS $GC_CFLAGS \
          $_objs "$RT" $GC_LIBS "$GC_SECTION_LDFLAGS" -lm -o "$_pout" 2>>"$_perr"
  )
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
# It does NOT record the codegen path ($PCG_MODE), so flipping MEDAKA_PARALLEL_CODEGEN
# on an unchanged tree keeps the emitter the OTHER path built; use
# FORCE_EMITTER_REBUILD=1 when switching paths. (The stamp's content is asserted
# byte-for-byte against a bare fingerprint by .github/actions/setup-medaka/action.yml,
# so it cannot carry a second field without that assertion moving in lockstep.)
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
  STAGE_A_T0="$(date +%s)"
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
  #   linking THIS binary: -O0 22.5s → -O2 55.2s (the "+3s once" framing no
  #     longer holds at current codebase size — it's now a real ~33s cost, paid
  #     once per emitter rebuild). 55.2s supersedes a 74.3s reading taken earlier
  #     the same day: two later re-measurements of this same link, same box, same
  #     day, read 52s and 55.2s. Reproduce by timing the link this stage performs:
  #     `time FORCE_EMITTER_REBUILD=1 sh test/build_native_medaka.sh`, which is
  #     also sensitive to which codegen path stage A takes — see "PARALLEL
  #     CODEGEN" above.
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
  # Elapsed seconds are logged for the link on both paths (and for stage B's
  # below), so "which codegen path did this build take, and what did it cost"
  # is answerable from any build log without re-running anything.
  LINK_A_T0="$(date +%s)"
  if [ -n "$PCG_BIN" ]; then
    echo "stage A: $PCG_MODE codegen ($MEDAKA_CODEGEN_JOBS jobs, $PCG_BIN) -> $EMITTER ..."
    if ! pcg_link "$EMIT_LL" "$EMIT_NEW" "${EMITTER_OPT:--O2}" "$WORK/emitA-cc.err"; then
      rm -f "$EMIT_NEW"
      echo "FAIL ($PCG_MODE codegen, fresh emitter): $(cat "$WORK/emitA-cc.err")"; exit 1
    fi
  else
    # Say so POSITIVELY. Without this line a plain-path build is indistinguishable
    # in the log from a build of a script that has no parallel path at all, so
    # "which codegen path did this build take" is only answerable from a log when
    # the answer happens to be "thinlto".
    echo "stage A: plain clang ${EMITTER_OPT:--O2} link (parallel codegen disabled or its LLVM tools not found) -> $EMITTER ..."
    if ! "$CC" -pthread "${EMITTER_OPT:--O2}" $GC_SECTION_CFLAGS $GC_CFLAGS "$EMIT_LL" "$RT" $GC_LIBS "$GC_SECTION_LDFLAGS" -lm -o "$EMIT_NEW" 2>"$WORK/emitA-cc.err"; then
      rm -f "$EMIT_NEW"
      echo "FAIL (clang fresh emitter): $(cat "$WORK/emitA-cc.err")"; exit 1
    fi
  fi
  if [ "$PCG_MODE_USED" != "$PCG_MODE" ]; then
    echo "stage A: this emitter emits no \`; mdk-module\` markers (it predates them), so its IR"
    echo "         was NOT partitioned — one ThinLTO module and no partition parallelism, and this"
    echo "         binary is not cached. The emitter this stage just built does emit them, so"
    echo "         stage B and every later build partition normally."
    # NOT cached: the key is chosen before any IR exists, so no cache_get ever asks
    # for a nomark one. Storing it could only evict a servable entry from the eight.
    EMITTER_KEY=""
  fi
  echo "stage A: link done ($PCG_MODE_USED${PCG_PARTS_USED:+, $PCG_PARTS_USED partitions}, $(( $(date +%s) - LINK_A_T0 ))s)."
  mv "$EMIT_NEW" "$EMITTER"
  echo "stage A: rebuilt $EMITTER from current source ($PCG_MODE_USED, $(( $(date +%s) - STAGE_A_T0 ))s for emit + link)."
  [ -n "$EMITTER_KEY" ] && cache_put "$EMITTER_KEY" "$EMITTER"
fi

# ---- STAGE B (WARM): the (fresh) emitter emits the medaka_cli graph -> ./medaka --
# Unconditional BY DEFAULT (see SKIP_CLI_LINK_IF_FRESH at the top): the hot dev loop
# and every other caller keep relinking exactly as before. The opt-in skip below is
# symmetric with stage A's — same fingerprint helpers, same stamp file pattern, same
# "no stamp = unknown provenance = rebuild" fallback — but it compares FP_COMPILER,
# because that is what stage B actually stamps into the binary.
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
  STAGE_B_T0="$(date +%s)"
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
  # size. For build-heavy loops where the CLI's own extra link time dominates
  # instead, opt out with CLI_OPT=-O0. (The 94.6s figure is the PLAIN -O2 link;
  # the ThinLTO path this stage now takes by default cuts that to ~29s cold and
  # ~8s when the source has not changed since the last build. It does NOT cut the
  # link after a source edit — see "PARALLEL CODEGEN" above.)
  # (The EMITTER, by contrast, is always -O2 — it's the reused workhorse; see stage A.)
  CLI_OPT="${CLI_OPT:--O2}"
  # STALENESS STAMP (issue #89): stamp the COMPILER-source fingerprint into ./medaka
  # so the CLI can warn when it is run against a NEWER compiler/ than it was built
  # from.  It reaches the binary through the provenance object below — never the
  # emitter IR, which is produced before any clang runs — so it is fixpoint/seed-safe.
  # We stamp FP_COMPILER (compiler/**.mdk + stdlib/**.mdk), NOT FP_FULL: the driver's
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
  # PROVENANCE OBJECT: the three stamps live in their OWN translation unit, built
  # here and linked into ./medaka alone. runtime/medaka_rt.c declares them weak and
  # empty, so every other consumer of that file — stage A, bootstrap_from_seed.sh,
  # selfcompile_fixpoint.sh, build_cmd.mdk's rt.o for user builds — links no
  # provenance object and reads "", which is the contract those paths already had.
  #
  # It is compiled WITHOUT -flto for the reason the whole codegen path exists: these
  # three strings change on every compiler edit, and anything inside the LTO unit
  # that changes puts a fresh ThinLTO cache key on every partition importing it.
  # medaka_rt.c stays in the LTO unit (taking it out cost ~7.7% of interpreter
  # runtime); only this three-line file leaves. See "PARALLEL CODEGEN" above.
  PROV_C="$WORK/provenance.c"
  PROV_O="$WORK/provenance.o"
  printf 'const char mdk_build_fingerprint_str[] = "%s";\nconst char mdk_build_commit_str[] = "%s";\nconst char mdk_build_date_str[] = "%s";\n' \
    "$FP_COMPILER" "$BUILD_COMMIT" "$BUILD_DATE" > "$PROV_C"
  if ! "$CC" -c -O2 $GC_SECTION_CFLAGS "$PROV_C" -o "$PROV_O" 2>"$WORK/prov.err"; then
    rm -f "$OUT_NEW"
    echo "FAIL (clang provenance.c): $(cat "$WORK/prov.err")"; exit 1
  fi
  # $PROV_O is pcg_link's trailing arg, which it threads to the final clang, so it
  # reaches the link identically on both paths.
  LINK_B_T0="$(date +%s)"
  if [ -n "$PCG_BIN" ]; then
    echo "stage B: $PCG_MODE codegen ($MEDAKA_CODEGEN_JOBS jobs, $PCG_BIN) -> $OUT ..."
    if ! pcg_link "$CLI_LL" "$OUT_NEW" "$CLI_OPT" "$WORK/cc.err" "$PROV_O"; then
      rm -f "$OUT_NEW"
      echo "FAIL ($PCG_MODE codegen, medaka): $(cat "$WORK/cc.err")"; exit 1
    fi
  else
    echo "stage B: plain clang(medaka_cli.ll, $CLI_OPT) link (parallel codegen disabled or its LLVM tools not found) -> $OUT ..."
    if ! "$CC" -pthread "$CLI_OPT" "$PROV_O" $GC_SECTION_CFLAGS $GC_CFLAGS "$CLI_LL" "$RT" $GC_LIBS "$GC_SECTION_LDFLAGS" -lm -o "$OUT_NEW" 2>"$WORK/cc.err"; then
      rm -f "$OUT_NEW"
      echo "FAIL (clang medaka): $(cat "$WORK/cc.err")"; exit 1
    fi
  fi
  if [ "$PCG_MODE_USED" != "$PCG_MODE" ]; then
    echo "stage B: emitter IR carries no \`; mdk-module\` markers — un-partitioned, not cached."
    CLI_KEY=""
  fi
  echo "stage B: link done ($PCG_MODE_USED${PCG_PARTS_USED:+, $PCG_PARTS_USED partitions}, $(( $(date +%s) - LINK_B_T0 ))s)."
  mv "$OUT_NEW" "$OUT"
  echo "stage B: built $OUT ($PCG_MODE_USED, $(( $(date +%s) - STAGE_B_T0 ))s for emit + link)."
  [ -n "$CLI_KEY" ] && cache_put "$CLI_KEY" "$OUT"
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
