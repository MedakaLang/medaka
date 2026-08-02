#!/bin/sh
# diff_compiler_origin_agreement.sh — the compiler's three elaboration drivers must
# not DISAGREE about which module declared a type-constructor head.
#
# ── what this gate is for ────────────────────────────────────────────────────
# `Ty.TyCon` carries a `TyConOrigin` (#1110 / epic #1122) stamped by resolve on both
# the check path and the emit path, and so do the four TYPE-DECLARATION nodes
# (`DData.dataOrigin` / `DNewtype.newtypeOrigin` / `DTypeAlias.tyAliasOrigin` /
# `DInterface.ifaceOrigin`). Nothing in the compiler reads any of them —
# deliberately,
# so the stamping PRs stayed byte-identical and mechanically verifiable. The cost of
# that is that every identity fact the compiler mints is UNOBSERVABLE, and two
# S0-class defects shipped through 12/12 green CI on exactly that:
#
#   F1  the flat driver stamped `mod:__user__` for a file's own declarations while
#       the emitter's graph path stamped the real loader id — inside ONE
#       `medaka build`. A check-vs-build divergence with no diagnostic.
#   F2  on prelude-flattened paths the PRELUDE's own types (Option/Result/Ordering)
#       were attributed to the USER's module.
#
# Both were found by hand-instrumenting a scratch build with `panic`. Nothing in the
# 84-gate suite could see either one. This gate is the answer to that.
#
# ⚠️ A PROBE THAT CALLED THE STAMPERS DIRECTLY WOULD NOT HAVE CAUGHT F2, AND THAT
# CONSTRAINT SHAPES THIS WHOLE GATE. `stampFlatTyOrigins` was *correct for its
# arguments*; the defect was a CALLER passing an empty prelude list. F1 likewise was
# a hardcoded literal at one of three call sites. A probe that hand-picks its
# arguments re-encodes the assumption it exists to test and reports green. So
# compiler/entries/origin_agreement_main.mdk drives the REAL entry points the way
# the real drivers drive them —
#
#   flat    checkProgramSchemesWithRuntime   (`check` on a no-import file, LSP, doc,
#                                             repl, playground)
#   single  elaborateModules … [("__user__", …)]   (`medaka test <file>`, snapshot)
#   graph   elaborateModules … <loader graph>      (`run` / `build` / `test <dir>`)
#
# — and reads back what THEY produced.
#
# ── what is asserted ────────────────────────────────────────────────────────
# The golden is the AGREEMENT TABLE, not the origins. That is the load-bearing
# choice: an agreement table detects a disagreement WITHOUT anyone having to know
# the right answer, which is the only property that survives an arc whose entire
# purpose is that the right answer is not settled yet. A golden of the origins
# themselves would also have MISSED F1 outright — each arm's claim was individually
# plausible; only their disagreement was wrong.
#
# Verdict vocabulary (per head, per arm pair), all defined in the probe:
#   AGREE        both arms claim, same module
#   CONFLICT     both arms claim, DIFFERENT modules      <- the defect class
#   L-ONLY/R-ONLY  one arm claims, the other is honestly SILENT
#   NEITHER      both saw the head, neither could attribute it
#   *-ABSENT     an arm never processed the head at all
#
# ⚠️ `L-ONLY`/`R-ONLY` IS NOT A FAILURE AND MUST NOT BE "FIXED". The flat path is
# deliberately silent (`OriginUnresolved`) wherever it has no loader-derived module
# id, rather than inventing one — that asymmetry IS F1's fix (see stampFlatTyOrigins'
# own comment in compiler/frontend/resolve.mdk). Under-supplying identity is
# correctable later; over-supplying a wrong one is made permanent by the immunity
# rule. So the gate distinguishes "silent" from "wrong", and only the second is a
# defect.
#
# ── the CONFLICT rows in the committed golden are a PINNED OPEN DEFECT (#1223) ─
# The `single` arm elaborates a file under the driver's own `"__user__"` label while
# the `graph` arm elaborates the same file under its loader id — which is precisely
# what `medaka test <dir>` does to one declaration in one process (#1223). Those rows
# are committed as CONFLICT on purpose, as test/must_fail_fixtures/ pins a live bug.
#
# ⚠️ BUT THEY DRAIN BY REVIEW, NOT MECHANICALLY, AND AN EARLIER DRAFT OF THIS HEADER
# CLAIMED OTHERWISE. The `single` arm spells `"__user__"` in the PROBE, not in
# compiler/tools/test_cmd.mdk where the real driver spells it — so unifying the
# drivers will NOT flip these rows: the probe will keep passing `"__user__"`, keep
# producing three CONFLICTs, and this gate will stay green against a stale golden.
# Whoever fixes #1223 must delete them here by hand; the golden's own header says so,
# and #1223 carries the caveat. Making it mechanical means exporting the id from
# test_cmd.mdk and importing it here — a change to a shipping driver, deliberately
# not bundled into a gate-only PR. This is the same hazard the probe argues against
# for the stampers ("a probe that hand-picks its arguments re-encodes the assumption
# it exists to test"), turned on one of its own arms; naming it is the minimum.
#
# ── TWO LAYERS: `<Name>` is an OCCURRENCE, `decl:<Name>` is a DECLARATION ─────
# The two are stamped by DIFFERENT functions on DIFFERENT paths — `stampTyOrigins`
# walks every `Ty` position, `stampDeclOrigins` fills the decl nodes' own carriers —
# so they are reported in separate namespaces (`:` cannot occur in a Medaka type
# name). Until this gate was widened, `noteHead` matched `TyCon` only, and since it
# is driven through `mapTyInDecl` — a `Ty`-POSITION rewrite — no callback it is
# handed could ever reach a decl-node field. The whole decl layer was therefore
# populated and graded by NOTHING, which is precisely the condition under which the
# two S0s above shipped green. An interface is the sharpest case: an interface name
# is never a `TyCon` (it is a constraint predicate, not a type constructor), so
# before this widening `interface Weighable` had no representation in this gate at
# all, and `#1047`'s interface-identity carrier was ungraded by construction.
#
# ⚠️ The flat arm is silent for the ENTIRE decl layer, by design, and that is not a
# defect to fix: `stampFlatTyOrigins` stamps occurrences only and never calls
# `stampDeclOrigins` (resolve.mdk — "FLAT (loader-less) DRIVERS GET NOTHING HERE").
#
# ── the RESIDUAL section — the runtime drain #1110 asked for ─────────────────
# Per arm, the `OriginUnresolved` heads that SURVIVED that driver's stamping pass.
# The producer ratchet in test/typecheck_compiler_source.sh pins who may MINT the
# sentinel — a fact about the SOURCE — and its own comment states the gap: it
# "cannot see whether a driver forgot to stamp, nor whether one stamped the WRONG
# id". CONFLICT rows answer the second. This section answers the first. It matters
# because `stampTyHead`'s immunity rule fills in only a still-unresolved head, so
# the FIRST stamp is the only one: a head that reaches a consumer unstamped stays
# unstamped.
#
# 🚨 THE RESIDUAL IS NOT ASSERTED EMPTY, AND A NONZERO COUNT IS NOT A BUG REPORT.
# `OriginUnresolved` means "no identity was available here", and both of resolve's
# routes to it are honest ABSENCE. What each arm means:
#   flat    EXPECTED, in bulk. `flatTyOriginScope` claims a strict SUBSET of what
#           the graph path claims — builtins plus the prelude's own types, and
#           nothing else. It has no loader id for the user's own declarations, it
#           never walks `usePathsOf prog` so it stamps nothing the buffer IMPORTS,
#           and it never runs the decl-layer stamper at all. Under-supplying
#           identity is correctable by a later graph pass; OVER-supplying a wrong
#           one is made PERMANENT by the immunity rule. That asymmetry is the
#           documented subset-and-agreement safety property, and these rows ARE it.
#           ⚠️ EXCEPT `flat core decl:*`: `checkProgramSeededSplit` already knows
#           `mod:core` for the prelude (it stamps prelude OCCURRENCES with it via
#           `stampFlatTyOrigins coreProg0 coreProg0`), so those rows are an
#           unwired decl-layer stamp on a known id, not "no id to invent" — #1227.
#   single  EXPECTED where the head comes from a module the 1-module graph does not
#           contain — `medaka test <file>` on a file whose imports are not loaded
#           has no source module to attribute them to.
#   graph   THE ONE TO READ. The graph path has a real module id for every module
#           and a scope of builtins + prelude + imports + own declarations, so a
#           head it left unstamped is either genuinely out of scope (already
#           reported as `UnknownType`; errors accumulate, so the tree still gets
#           here) or a DRIVER GAP. Not decidable from this output alone — which is
#           why the set is pinned for review rather than asserted empty.
#
# ⚠️ The `unresolved` fixture exists so the OCCURRENCE half of this section stays
# FALSIFIABLE. On the `graph` corpus the graph arm's occurrence residual is EMPTY —
# a good result that is also indistinguishable, from the golden alone, from a
# section structurally unable to emit a graph row. `unresolved` pins one (`graph
# main_unresolved Missing`, a bare occurrence — `Missing` is declared nowhere).
# Do not "fix" that row by deleting the undeclared type; doing so disarms the
# control and returns the occurrence half to unfalsifiable.
#
# This control says NOTHING about the `decl:` layer. `fillDeclOrigin` (resolve.mdk)
# stamps `OriginUnresolved -> OriginModule mid` unconditionally whenever `mid /= ""`,
# and the loader never mints `""`, so no source program can produce a
# `graph <slot> decl:X` residual row — that zero is structural, provable only by
# mutating the stamper, not earned by any fixture. Don't read "the residual section
# is falsifiable" as covering both layers.
#
# ⚠️ So: a diff here is never "just re-bless it". Read the moved rows. A row going
# AGREE -> CONFLICT is a NEW divergence. A row going AGREE -> NEITHER/*-ABSENT is
# identity being DESTROYED somewhere downstream of the stamp (the known hazards are
# `substMonoP` and `substTyVars`, which rebuild a `TCon`/`TyCon` from the name alone).
# A HEAD SPREAD line changing its ORIGIN (`Option 1 mod:core` -> `Option 1
# mod:__user__`) is a UNIFORM mis-attribution — every arm wrong the same way, so no
# verdict moves and that line is the only thing that can say it.
#
# ── the one EXPECTED-BENIGN shape, named so it is not mistaken for the above ──
# Adding a type to `stdlib/core.mdk` adds a `core <NewType> AGREE AGREE AGREE` row
# and a `<NewType> 1 mod:core` spread line, and moves `heads`/`claims`. That is the
# prelude growing, not a defect. It is also the ONLY innocent churn this golden has,
# and `stdlib/*` is already whole-suite blast radius in preflight — so anything else
# that moves here deserves the reading this header asks for.
#
# ── anti-vacuity ────────────────────────────────────────────────────────────
# Three counts are checked here, not just diffed, because a table that silently
# became empty would otherwise diff-match an empty golden and report green:
#   heads          > 0   the probe observed some type heads at all
#   flat-segments  > 0   resolve.mdk's agreement tap actually FIRED — if a future
#                        refactor stops routing the flat drivers through
#                        `checkProgramSeededSplit`, the `flat` column silently
#                        becomes all-ABSENT and every pair involving it stops
#                        asserting anything
#   decl-heads     > 0   the graph arm actually observed DECL-LAYER carriers. The
#                        exact peer of `flat-segments`, for the layer this gate was
#                        blind to for two PRs: if a refactor stops the `…Origin`
#                        fields reaching the trees `elaborateModules` returns (a
#                        decl rebuilt through `dDataUnresolved` instead of a record
#                        UPDATE would do it), every `decl:` row vanishes at once.
#                        Rows vanishing en masse is a shape a golden diff shows but
#                        does not INTERPRET, and the interpretation is the point.
#   fixtures       > 0   the corpus glob matched something
#
# ── OWED, not built here (#1222) ────────────────────────────────────────────
# A ratchet asserting that NOTHING IN THE COMPILER READS `setOriginTrace` — i.e.
# that the tap stays probe-only and no shipping path ever switches it on — belongs
# next to the #1110 producer ratchets in test/typecheck_compiler_source.sh. It is
# deliberately NOT added there yet: those ratchets scan with `git grep`, which sees
# only TRACKED files, so they report PASS on a working tree that fails the instant it
# is committed (filed as #1222). Building a new invariant on that foundation would
# inherit the hole. Owed once #1222 lands.
#
# Usage:  sh test/diff_compiler_origin_agreement.sh
#         CAPTURE=1 sh test/diff_compiler_origin_agreement.sh    # (re)bless goldens
# Exit:   0 all fixtures match; 1 a mismatch, an empty table, or a missing probe.
#         There is NO skip path: the probe needs no clang and no toolchain at gate
#         time, so "could not run" here is a real failure, never a skip.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SELF="$ROOT/test/bin/origin_agreement_main"
RT="$ROOT/stdlib/runtime.mdk"
CORE="$ROOT/stdlib/core.mdk"
FIXDIR="$ROOT/test/origin_fixtures"

if [ ! -x "$SELF" ]; then
  echo "FAIL: missing probe $SELF"
  echo "      build it with:  FORCE=1 JOBS=1 sh test/build_oracles.sh --build-one origin_agreement_main"
  echo "      (this is a FAILURE, not a skip: the gate needs no clang at gate time,"
  echo "       so an absent probe means the gate asserted nothing.)"
  exit 1
fi

# A strictly-positive decimal count, and nothing else. See the guard below for why
# this is a `case` and not an arithmetic test.
is_count() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$1" -gt 0 ]
}

pass=0
fail=0
fixtures=0
conflicts_total=0

for dir in "$FIXDIR"/*/; do
  [ -d "$dir" ] || continue
  entry="$(ls "$dir"main_*.mdk 2>/dev/null | head -1)"
  if [ -z "$entry" ]; then
    echo "FAIL: $(basename "$dir") has no main_*.mdk entry"
    fail=$((fail + 1))
    continue
  fi
  fixtures=$((fixtures + 1))
  name="$(basename "$dir")"
  golden="${dir%/}/agreement.golden"

  out="$("$SELF" "$RT" "$CORE" "$entry" "${dir%/}" 2>&1)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "FAIL $name (probe exited $rc)"
    printf '%s\n' "$out" | sed 's/^/  /'
    fail=$((fail + 1))
    continue
  fi

  # ── anti-vacuity, BEFORE the diff ──────────────────────────────────────────
  # A table that became empty diff-matches an empty golden. These three read the
  # probe's own summary and fail on a zero, so "checked nothing" can never pass.
  # ⚠️ Read the SUMMARY section only. `awk '$1=="heads"'` over the whole output also
  # matches a `<slot> <head> …` table row, so a fixture directory literally named
  # `heads` / `flat-segments` / `conflicts` would feed this guard a verdict token.
  summary="$(printf '%s\n' "$out" | sed -n '/^=== SUMMARY ===$/,$p')"
  heads="$(printf '%s\n' "$summary" | awk '$1 == "heads" { print $2 }')"
  segs="$(printf '%s\n' "$summary" | awk '$1 == "flat-segments" { print $2 }')"
  declheads="$(printf '%s\n' "$summary" | awk '$1 == "decl-heads" { print $2 }')"
  nconf="$(printf '%s\n' "$summary" | awk '$1 == "conflicts" { print $2 }')"
  nresid="$(printf '%s\n' "$summary" | awk '$1 == "residual" { print $2 }')"

  # ⚠️ NOT `[ "$x" -le 0 ] 2>/dev/null`. On a NON-NUMERIC value that test exits 2
  # with the diagnostic suppressed, the `if` reads false, and the guard PASSES —
  # i.e. the one check standing between us and a silent no-op had a path where a
  # malformed summary read as healthy. Reject non-numeric explicitly instead.
  if ! is_count "$heads"; then
    echo "FAIL $name: probe reported heads='$heads' — not a positive count, so it"
    echo "     observed NO type heads (or the summary is malformed)."
    fail=$((fail + 1))
    continue
  fi
  if ! is_count "$segs"; then
    echo "FAIL $name: probe reported flat-segments='$segs' — resolve.mdk's agreement"
    echo "     tap never fired, so the 'flat' column asserted NOTHING. Check that"
    echo "     the flat drivers still route through checkProgramSeededSplit."
    fail=$((fail + 1))
    continue
  fi
  if ! is_count "$declheads"; then
    echo "FAIL $name: probe reported decl-heads='$declheads' — the graph arm saw NO"
    echo "     decl-layer origin carriers, so every 'decl:' row in the golden is"
    echo "     asserting nothing. Check that DData/DNewtype/DTypeAlias/DInterface"
    echo "     still carry their ...Origin fields through elaborateModules, and that"
    echo "     no decl is REBUILT via a d*Unresolved helper (which resets the field)"
    echo "     instead of a record update."
    fail=$((fail + 1))
    continue
  fi
  # ⚠️ `residual` is deliberately NOT guarded as > 0 or == 0. Its correct value is a
  # property of the CORPUS, not an invariant (see the residual notes in the header),
  # so the golden is the only assertion. It is read here purely to be reported.
  case "$nresid" in ''|*[!0-9]*) nresid='?' ;; esac
  case "$nconf" in ''|*[!0-9]*) nconf=0 ;; esac
  conflicts_total=$((conflicts_total + nconf))

  if [ "${CAPTURE:-0}" = "1" ]; then
    printf '%s' "$out" > "$golden"
    printf 'blessed %s (%s heads incl. %s decl-layer, %s conflicting, %s residual)\n' \
      "$name" "$heads" "$declheads" "${nconf:-?}" "$nresid"
    pass=$((pass + 1))
    continue
  fi

  if [ ! -f "$golden" ]; then
    echo "FAIL $name: no golden at $golden (CAPTURE=1 sh test/diff_compiler_origin_agreement.sh)"
    fail=$((fail + 1))
    continue
  fi

  if printf '%s' "$out" | diff -u "$golden" - > /dev/null 2>&1; then
    printf 'ok   %s (%s heads incl. %s decl-layer, %s conflicting, %s residual, tap fired %s times)\n' \
      "$name" "$heads" "$declheads" "${nconf:-?}" "$nresid" "$segs"
    pass=$((pass + 1))
  else
    printf 'FAIL %s — the agreement table MOVED:\n' "$name"
    printf '%s' "$out" | diff -u "$golden" - | sed 's/^/  /'
    echo "  Read the moved rows before re-blessing:"
    echo "    AGREE -> CONFLICT      a NEW driver disagreement (the #1110 defect class)"
    echo "    AGREE -> NEITHER       an acquired origin is being DESTROYED downstream"
    echo "    CONFLICT -> anything   a pinned defect was FIXED — re-bless and say which"
    echo "    + a 'graph ...' RESIDUAL row   a head the graph driver did NOT stamp."
    echo "                           Either the name is genuinely in no scope, or a"
    echo "                           driver forgot to stamp it. Decide which and say so."
    echo "    - a 'graph ...' RESIDUAL row   identity was ACQUIRED where it was not"
    echo "                           before. Good — but confirm it is the RIGHT module,"
    echo "                           because the immunity rule makes a first stamp final."
    echo "    every 'decl:' row gone  the decl-layer carriers stopped reaching the"
    echo "                           returned trees. See the decl-heads guard above."
    fail=$((fail + 1))
  fi
done

if [ "$fixtures" -eq 0 ]; then
  echo "FAIL: no fixtures under $FIXDIR — this gate checked NOTHING."
  exit 1
fi

printf '\n%d ok, %d failing (%d fixture(s), %d conflicting head(s) pinned)\n' \
  "$pass" "$fail" "$fixtures" "$conflicts_total"
[ "$fail" -eq 0 ]
