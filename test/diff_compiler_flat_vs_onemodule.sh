#!/bin/sh
# diff_compiler_flat_vs_onemodule.sh — the FLAT arm's answers, pinned; the
# FLAT-vs-MODULE relation, characterized.
#
# ── WHAT THE TWO ARMS ARE ─────────────────────────────────────────────────────
#
# `CheckMode` (compiler/types/typecheck.mdk, grep 'data CheckMode') has exactly two
# constructors and exactly two constructing call sites:
#
#   checkProgramSeededSplit → checkBodyImpl seed (Flat coreProg) userProg      ⇒ FLAT
#   checkModuleFullImpl     → checkBodyImpl seedVars (Module mid …) prog       ⇒ MODULE
#
# FLAT is not a probe-only path. `medaka check <no-import file>` reaches it (via
# driver/diagnostics.mdk `analyzeLocatedG` → `analyzeFrom` → `checkProgramDiags`,
# which is the single-module arm of medaka_cli.mdk's `checkRoute`), and so do
# `medaka lsp`, `medaka repl`, `medaka doc`, `medaka lint`'s policy pass, `medaka
# snapshot`, and the `llvm_emit_typed_main` / `wasm_emit_typed_main` emit entries
# via `elaborateDict`. MODULE is reached by every import-bearing `check`, and by
# `run` / `build` / `test` — including on a ONE-module program, through the
# `elaborateOne` / `elaborateModules` 1-module wrapper.
#
# The FLAT arm builds its instance universe with `buildKeyTable fullUniverse` /
# `buildImplUniverse prog` — whole-program by construction, with no import graph to
# scope it. That is why FLAT is already graph-global, and already CORRECT, on the
# very shape ARCH B-2 exists to fix.
#
# ── WHY THIS GATE EXISTS (ARCH B-2.1-a; Stage B sprint, DECISIONS.md RUN-B-017) ─
#
# ARCH B-2.1 repoints the evidence reader (`concreteReqMatchByIface` ←
# `findMatchingImplReqsU`) off the cumulative `shadowKeyTableRef` onto the global
# instance environment `IE`. **`IE` is EMPTY on the FLAT path** (typecheck.mdk, grep
# 'declEnvsRef` is EMPTY on Flat'). So that repointing, done naively, is a
# CORRECT → BROKEN regression on the busiest verbs in the CLI — and it is invisible
# to every value golden, because the goldens for `check`/`lsp`/`repl` acceptance are
# not value goldens at all.
#
# This gate is the instrument for that risk, and it was built BEFORE the change so
# that it witnesses the CORRECT pre-state. A grader written afterwards can only
# confirm whatever the new code does.
#
# ── 🚨 THE ASSERT CHOICE, AND WHY IT IS NOT "THE TWO ARMS MUST AGREE" ──────────
#
# Today the two arms DISAGREE on case `cond_impl_third_module`: FLAT accepts, and
# the MODULE arm accepts or rejects depending on the order of two `import` lines in
# a third module. That disagreement is issue #1564, an OPEN defect this sprint
# intends to drain. Three candidate assertions were considered:
#
#   (a) "the two arms must AGREE on acceptance" — REJECTED, and not merely because
#       it would be red on arrival. It is red for the WRONG REASON and, worse, it
#       goes GREEN on the exact regression this gate exists to catch: if B-2.1
#       breaks FLAT down to the MODULE arm's rejection, the two arms AGREE and the
#       gate passes. An assertion that is satisfied by the failure it guards is not
#       an instrument.
#
#   (b) "the two arms must DISAGREE" — REJECTED. It enshrines #1564 as the expected
#       answer and goes red on the fix. That is the must-fail suite's idiom, not a
#       differential's, and #1564 ALREADY has that pin:
#       test/must_fail_fixtures/1564-import-order-decides-conditional-impl-candidacy/.
#       Pinning it twice means two gates to re-derive on one fix, and a second
#       chance to enshrine a wrong answer.
#
#   (c) CHOSEN. Pin the FLAT arm's own answer per case — exact exit code, exact
#       diagnostic `code`, exact value — because THAT is the property the B-2.1
#       bite must not change, and it is green today. Then grade the relation only
#       through a claim that is TRUE BOTH BEFORE AND AFTER the #1564 fix:
#
#         every arm that ACCEPTS a case must compute the SAME value.
#
#       That is DICT-SEMANTICS C4/I2's observable half — "consult the same instance
#       set AND produce the same evidence" — and it never enshrines anything: it is
#       silent about WHETHER an arm accepts and loud about an arm that accepts and
#       computes something else. It is also not hypothetical. #1564's own claim.txt
#       records that between ARCH A-3.6 and Door 4 this program was briefly ACCEPTED
#       and MISCOMPILED (`check` exit 0, built binary exit 139), which is precisely
#       the state this clause fails on and the acceptance-agreement clause (a) would
#       have called green.
#
# So each row is either PINned (its verdict is hand-derived from the spec and
# asserted) or CHARacterized (its verdict is a KNOWN defect: the row carries BOTH
# the correct answer and today's answer; observing today's answer passes with a
# note, observing the correct answer passes with a DRAIN NOTICE naming the issue,
# and observing a THIRD answer FAILS — so "something else broke" can never read as
# either "still broken" or "fixed").
#
# ── HOW THE EXPECTED VALUES WERE DERIVED (not captured) ───────────────────────
#
# Per this tree's standing rule that a captured golden records what the engine did,
# not what is correct, every expectation below is derived from the spec first and
# only then compared against the binary:
#
#   * cond_impl_third_module — ACCEPT, value `wrap(int)`. DICT-SEMANTICS §8 I5:
#     "instance candidacy is graph-global; import scoping filters NAMES, never
#     instances." The conditional `impl Tag (Wrap a) requires Tag a` is in the
#     program, so the goal `Tag (Wrap Int)` is dischargeable, and `Tag Int` is in
#     the program too. §3 independently forbids the observable: selection is never a
#     function of search order, declaration order, or resolution position. So ACCEPT
#     is correct on BOTH arms and under EVERY import order; the MODULE arm's
#     order-2 rejection is a FALSE REJECT and is the CHARacterized row.
#   * all_visible — ACCEPT, value `wrap(int)`. Same program with the conditional
#     impl's module imported by the module that needs it, so no candidacy question
#     arises on any arm. This is the ENVIRONMENT CONTROL: if it breaks, the prelude
#     or the harness broke, not the arms, and this gate says so rather than
#     reporting a finding.
#   * user_iface_dispatch / user_iface_undetermined — ARCH B-2.1-b2, and they exist
#     because the six rows above are all PRELUDE-interface or accept/reject shapes,
#     which is exactly why this gate was BLIND to the question `B-2.1-a4` had to
#     answer by hand (DECISIONS.md RUN-B-030). R1's finding F1: a USER-declared
#     interface is absent from `flatTyOriginScope`, so on FLAT its impls file under
#     the BARE `TabKey` only, while on MODULE they file under both the identity key
#     and the bare one — one ref (`bodyImplEnvRef`) carrying two keyings, selected by
#     driver arm. `a4` adjudicated it BENIGN (the goal side mints `oblIfaceKey`,
#     which IS the bare key for an identity-less goal, so write-side ⊇ read-side) —
#     but a benign verdict no gate defends is the shape that rots, and `B-2.1-b2` is
#     the bite that gives that substrate its first reader. These four rows are `a4`'s
#     own probes, re-derived here:
#       - p1 ACCEPT / value 7 — a user `Sizer` with one `impl Sizer Blob` and a
#         concrete call. The impl files bare-only on FLAT and the goal HITS. §8 I5.
#       - p3 REJECT `T-NO-IMPL` — same interface, called at a head with no impl.
#         This is p1's FAIL-CAPABILITY control: without it, "p1 accepts" is also what
#         an arm that accepts everything produces.
#       - p5 REJECT `T-AMBIGUOUS-INSTANCE` — 🚨 the SILENT sub-case, and the reason
#         these rows are worth their cost. `checkUndeterminedObligation`'s RULE 3 is
#         gated on `implCountForIfaceU >= 2`, so a MISSED universe lookup does not
#         mis-answer loudly: the count reads 0 and the diagnostic simply STOPS BEING
#         EMITTED — loud → silent, with no value and no golden moving. An absence
#         probe cannot see that; only a row asserting the diagnostic IS there can.
#       - p6 ACCEPT / value 3 — p5's control: the identical shape with ONE impl,
#         proving the guard is genuinely COUNT-driven and not shape-driven (if p6
#         also rejected, p5 would be evidence about the shape, not about the count).
#     Each FLAT row's `value` column runs `medaka run`, i.e. the MODULE arm's 1-module
#     wrapper, so every accepting row here is a two-arm observation on one file.
#   * no_impl_anywhere — REJECT (`T-NO-IMPL`) on both arms. There is genuinely no
#     `impl Tag (Wrap …)` in the program, so rejection is correct. This is the
#     NEGATIVE control: it is what stops an always-accept regression from making
#     the two ACCEPT cases vacuous. Without it, a compiler that accepted everything
#     would pass this gate's other six rows.
#
# ── ⚠️ WHAT THIS GATE CANNOT SEE, STATED SO NOBODY OVER-READS IT ──────────────
#
# The `value` column comes from `medaka run`, and `run` takes the MODULE arm even on
# a single no-import file (the `elaborateOne` 1-module wrapper). So a value here is
# never a FLAT-arm value observation: the FLAT arm is graded on ACCEPTANCE and
# DIAGNOSTICS only. A FLAT-arm value would need `llvm_emit_typed_main` /
# `wasm_emit_typed_main` (the `elaborateDict` entries), which are compiled probes
# under test/bin — deliberately out of scope so this gate reads no oracle. If a
# future bite needs the FLAT arm's emitted evidence, that is a different gate.
#
# ── FIXTURES ARE GENERATED, NOT COMMITTED, ON PURPOSE ─────────────────────────
#
# A fixture DIRECTORY is a shared corpus: adding one silently enrols it in every
# gate that globs test/*_fixtures (and in diff_compiler_fixture_corpus_coverage.sh),
# and the #1564 pin's own claim.txt warns that a committed directory of this shape
# is what an import-clause permutation differential would pick up and red on a
# pre-existing defect. Everything here is written into one `mktemp -d` per process
# instead — which also makes concurrent runs safe.
#
# Usage:  sh test/diff_compiler_flat_vs_onemodule.sh
#         MEDAKA=/other/tree/medaka sh test/diff_compiler_flat_vs_onemodule.sh
# Exit:   0 all rows as pinned/characterized; 1 a row moved; 2 no binary.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="${MEDAKA:-$ROOT/medaka}"
[ -x "$MEDAKA" ] || { echo "build native first: make medaka (missing $MEDAKA)"; exit 2; }

# Portable timeout: `timeout` is coreutils and does NOT exist on macOS, and every
# script in this tree must run on both. Same shim diff_compiler_engines.sh uses.
# ⚠️ NOT a drop-in for `timeout`: the child is killed by SIGALRM, so the shell
# reports 142 (128+14) where `timeout` reports 124. Real exit codes pass through.
run_t() { perl -e 'alarm shift; exec @ARGV' "$@"; }
LIMIT=180

WORK="$(mktemp -d)" || { echo "mktemp -d failed"; exit 2; }
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

# ── the shared declarations, one copy, so the arms cannot drift ───────────────
IFACE_DECLS='public export data Wrap a = Wrap a

export interface Tag t where
  tagOf : t -> String

export impl Tag Int where
  tagOf _ = "int"'
WRAP_IMPL='export impl Tag (Wrap a) requires Tag a where
  tagOf (Wrap x) = "wrap(\{tagOf x})"'
NEST_DECL='export nest x = tagOf (Wrap x)'
MAIN_DECL='main = println (nest 5)'
IMPORT_IFACE='import iface.{Tag, tagOf, Wrap}'

# ── case cond_impl_third_module ───────────────────────────────────────────────
# FLAT, both declaration orders (the FLAT arm must be order-free too).
mkdir -p "$WORK/c1fa" "$WORK/c1fb" "$WORK/c1m"
printf '%s\n\n%s\n\n%s\n\n%s\n' "$IFACE_DECLS" "$NEST_DECL" "$WRAP_IMPL" "$MAIN_DECL" > "$WORK/c1fa/flat.mdk"
printf '%s\n\n%s\n\n%s\n\n%s\n' "$IFACE_DECLS" "$WRAP_IMPL" "$NEST_DECL" "$MAIN_DECL" > "$WORK/c1fb/flat.mdk"
# MODULE: the same four declarations split across four modules. `nest.mdk` does NOT
# import `wrapimpl`, so the conditional impl is not NAMEABLE where `nest` is
# generalized — which per §8 I5 must not matter, and today does.
printf '%s\n' "$IFACE_DECLS" > "$WORK/c1m/iface.mdk"
printf '%s\n\n%s\n' "$IMPORT_IFACE" "$NEST_DECL" > "$WORK/c1m/nest.mdk"
printf '%s\n\n%s\n' "$IMPORT_IFACE" "$WRAP_IMPL" > "$WORK/c1m/wrapimpl.mdk"
# order 1: wrapimpl imported BEFORE nest.  order 2: AFTER.  Nothing else differs,
# which is what rules out "the fixture has a typo" as an explanation of order 2.
printf '%s\nimport wrapimpl\nimport nest.{nest}\n\n%s\n' "$IMPORT_IFACE" "$MAIN_DECL" > "$WORK/c1m/order1.mdk"
printf '%s\nimport nest.{nest}\nimport wrapimpl\n\n%s\n' "$IMPORT_IFACE" "$MAIN_DECL" > "$WORK/c1m/order2.mdk"

# ── case all_visible (environment control) ────────────────────────────────────
mkdir -p "$WORK/c2f" "$WORK/c2m"
printf '%s\n\n%s\n\n%s\n\n%s\n' "$IFACE_DECLS" "$WRAP_IMPL" "$NEST_DECL" "$MAIN_DECL" > "$WORK/c2f/flat.mdk"
printf '%s\n' "$IFACE_DECLS" > "$WORK/c2m/iface.mdk"
printf '%s\n\n%s\n' "$IMPORT_IFACE" "$WRAP_IMPL" > "$WORK/c2m/wrapimpl.mdk"
printf '%s\nimport wrapimpl\n\n%s\n' "$IMPORT_IFACE" "$NEST_DECL" > "$WORK/c2m/nest.mdk"
printf '%s\nimport wrapimpl\nimport nest.{nest}\n\n%s\n' "$IMPORT_IFACE" "$MAIN_DECL" > "$WORK/c2m/order1.mdk"
printf '%s\nimport nest.{nest}\nimport wrapimpl\n\n%s\n' "$IMPORT_IFACE" "$MAIN_DECL" > "$WORK/c2m/order2.mdk"

# ── case no_impl_anywhere (negative control) ──────────────────────────────────
mkdir -p "$WORK/c3f" "$WORK/c3m"
printf '%s\n\n%s\n\n%s\n' "$IFACE_DECLS" "$NEST_DECL" "$MAIN_DECL" > "$WORK/c3f/flat.mdk"
printf '%s\n' "$IFACE_DECLS" > "$WORK/c3m/iface.mdk"
printf '%s\n\n%s\n' "$IMPORT_IFACE" "$NEST_DECL" > "$WORK/c3m/nest.mdk"
printf '%s\nimport nest.{nest}\n\n%s\n' "$IMPORT_IFACE" "$MAIN_DECL" > "$WORK/c3m/order1.mdk"

# ── cases user_iface_dispatch / user_iface_undetermined (ARCH B-2.1-b2) ───────
# A USER-DECLARED interface, not a prelude one — see the header. All four are FLAT
# (no import, so `check` takes checkProgramSeededSplit); each accepting row's value
# column additionally exercises the MODULE arm through `run`'s 1-module wrapper.
SIZER_IFACE='public export data Blob = Blob Int

export interface Sizer t where
  sizeOf : t -> Int

export impl Sizer Blob where
  sizeOf (Blob n) = n'
# The two-method form: `make` is RETURN-position, so `sizeOf (make 3)` leaves the
# interface param UNDETERMINED — which is what reaches RULE 3's impl-count guard.
SIZER_MK='public export data Blob = Blob Int

export interface Sizer t where
  make : Int -> t
  sizeOf : t -> Int

export impl Sizer Blob where
  make n = Blob n
  sizeOf (Blob n) = n'
SIZER_MK_OTHER='public export data Other = Other Int

export impl Sizer Other where
  make n = Other n
  sizeOf (Other n) = n'
mkdir -p "$WORK/c4" "$WORK/c5"
printf '%s\n\nmain = println (sizeOf (Blob 7))\n' "$SIZER_IFACE" > "$WORK/c4/p1.mdk"
printf '%s\n\npublic export data Other = Other Int\n\nmain = println (sizeOf (Other 7))\n' "$SIZER_IFACE" > "$WORK/c4/p3.mdk"
printf '%s\n\n%s\n\nmain = println (sizeOf (make 3))\n' "$SIZER_MK" "$SIZER_MK_OTHER" > "$WORK/c5/p5.mdk"
printf '%s\n\nmain = println (sizeOf (make 3))\n' "$SIZER_MK" > "$WORK/c5/p6.mdk"

# ── case iface_default_requires_closure (S-flat-reacher-census finding) ──────
# A superclass-default-method shape: `Fancy t requires Basic t` with a default
# body for `describe` that calls the superclass method `label`.  The default
# body's use of `label` is entailed by Fancy's OWN `requires Basic t` — no
# method-level `=>` needed.  Discovered live (no source stub) while auditing
# `groundUniverse`/class(1): on FLAT, the interface module's own decl universe
# IS the whole `prog`, so the requires-closure lookup sees both interfaces; on
# MODULE, a module declaring ONLY interfaces (no impl blocks) has
# `implDecls = []`, and if the requires-closure derivation for default-method
# rigidity is scoped to that empty universe, the closure comes back empty and
# the (correct, self-entailed) default body is rejected as under-constrained.
# Filed for triage by the orchestrator (no issue number yet — this census did
# not file it, per this slice's site list).
IFACE_DEFAULT_DECLS='public export data Box = Box Int

export interface Basic t where
  label : t -> String

export interface Fancy t requires Basic t where
  describe : t -> String
  describe x = "fancy:\{label x}"'
IFACE_DEFAULT_IMPL='export impl Basic Box where
  label (Box n) = "box\{n}"

export impl Fancy Box where'
IFACE_DEFAULT_MAIN='main = println (describe (Box 7))'
mkdir -p "$WORK/c6f" "$WORK/c6m"
printf '%s\n\n%s\n\n%s\n' "$IFACE_DEFAULT_DECLS" "$IFACE_DEFAULT_IMPL" "$IFACE_DEFAULT_MAIN" > "$WORK/c6f/flat.mdk"
printf '%s\n' "$IFACE_DEFAULT_DECLS" > "$WORK/c6m/iface.mdk"
printf 'import iface.{Box, Basic, Fancy, label, describe}\n\n%s\n\n%s\n' \
  "$IFACE_DEFAULT_IMPL" "$IFACE_DEFAULT_MAIN" > "$WORK/c6m/main.mdk"

# ── the rows ──────────────────────────────────────────────────────────────────
# case | label | path | arm | mode | correct | today | code | value
#   mode PIN  : `correct` is asserted; `today` is ignored (written as the same).
#   mode CHAR : `correct` is the spec's answer, `today` the known-defect answer;
#               `code` is the diagnostic expected in the `today` state; `issue`
#               is named in the DRAIN NOTICE.
#   value     : expected stdout of `medaka run` when the verdict is ACCEPT ('-'
#               when the program is expected to be rejected).
#   issue     : (10th column, optional) per-row issue handle for the DRAIN
#               NOTICE / "still live" text — defaults to $CHAR_ISSUE when a row
#               omits it (every pre-existing row cites #1564; a row added later
#               for a DIFFERENT known defect names its own handle instead of
#               overloading #1564's).
ROWS="
cond_impl_third_module|flat_nest_first|c1fa/flat.mdk|FLAT|PIN|ACCEPT|ACCEPT|-|wrap(int)
cond_impl_third_module|flat_impl_first|c1fb/flat.mdk|FLAT|PIN|ACCEPT|ACCEPT|-|wrap(int)
cond_impl_third_module|module_order1|c1m/order1.mdk|MODULE|PIN|ACCEPT|ACCEPT|-|wrap(int)
cond_impl_third_module|module_order2|c1m/order2.mdk|MODULE|CHAR|ACCEPT|REJECT|T-REQUIRES-UNROUTED|wrap(int)
all_visible|flat|c2f/flat.mdk|FLAT|PIN|ACCEPT|ACCEPT|-|wrap(int)
all_visible|module_order1|c2m/order1.mdk|MODULE|PIN|ACCEPT|ACCEPT|-|wrap(int)
all_visible|module_order2|c2m/order2.mdk|MODULE|PIN|ACCEPT|ACCEPT|-|wrap(int)
no_impl_anywhere|flat|c3f/flat.mdk|FLAT|PIN|REJECT|REJECT|T-NO-IMPL|-
no_impl_anywhere|module_order1|c3m/order1.mdk|MODULE|PIN|REJECT|REJECT|T-NO-IMPL|-
user_iface_dispatch|p1_concrete_hit|c4/p1.mdk|FLAT|PIN|ACCEPT|ACCEPT|-|7
user_iface_dispatch|p3_no_impl|c4/p3.mdk|FLAT|PIN|REJECT|REJECT|T-NO-IMPL|-
user_iface_undetermined|p5_two_impls|c5/p5.mdk|FLAT|PIN|REJECT|REJECT|T-AMBIGUOUS-INSTANCE|-
user_iface_undetermined|p6_one_impl|c5/p6.mdk|FLAT|PIN|ACCEPT|ACCEPT|-|3
iface_default_requires_closure|flat|c6f/flat.mdk|FLAT|PIN|ACCEPT|ACCEPT|-|fancy:box7
iface_default_requires_closure|module|c6m/main.mdk|MODULE|CHAR|ACCEPT|REJECT|T-IMPL-TOO-SPECIFIC|fancy:box7|S-flat-reacher-census-finding-1(needs-issue)
"
CHAR_ISSUE=1564

fails=0
checked=0
drained=0
printf '%-24s %-16s %-7s %-5s %-8s %-22s %s\n' CASE ROW ARM MODE VERDICT CODE VALUE
printf -- '---------------------------------------------------------------------------------------------------\n'

# per-case value agreement (the C4/I2 observable clause), accumulated as
# "<case>=<value>" lines and compared at the end.
VALFILE="$WORK/.values"
: > "$VALFILE"

IFS='
'
for row in $ROWS; do
  [ -n "$row" ] || continue
  case="$(printf '%s' "$row" | cut -d'|' -f1)"
  label="$(printf '%s' "$row" | cut -d'|' -f2)"
  rel="$(printf '%s' "$row" | cut -d'|' -f3)"
  arm="$(printf '%s' "$row" | cut -d'|' -f4)"
  mode="$(printf '%s' "$row" | cut -d'|' -f5)"
  correct="$(printf '%s' "$row" | cut -d'|' -f6)"
  today="$(printf '%s' "$row" | cut -d'|' -f7)"
  wantcode="$(printf '%s' "$row" | cut -d'|' -f8)"
  wantval="$(printf '%s' "$row" | cut -d'|' -f9)"
  rowissue="$(printf '%s' "$row" | cut -d'|' -f10)"
  [ -n "$rowissue" ] || rowissue="$CHAR_ISSUE"
  f="$WORK/$rel"
  checked=$((checked + 1))

  # ⚠️ TWO redirect rules, both learned the hard way, both load-bearing here:
  #
  #  1. Exit codes are read from a FILE REDIRECT, never a pipeline: `medaka check x
  #     | grep` reports grep's status, so a rejection would read as exit 0.
  #  2. STDERR IS KEPT SEPARATE FROM STDOUT — never `2>&1` on a run whose STDOUT is
  #     an assertion. Every `./medaka` invocation writes the source-staleness warning
  #     ("built from compiler source that differs …") to STDERR, so a `2>&1` here puts
  #     that warning on line 1 and `head -1` reads it AS THE PROGRAM'S VALUE. The
  #     first draft of this gate did exactly that and went red on all six accepting
  #     rows the moment the binary lagged the tree by one comment edit — a build
  #     freshness artefact masquerading as a semantic finding (cf. #1421).
  run_t "$LIMIT" "$MEDAKA" check "$f" > "$WORK/.chk" 2> "$WORK/.chkerr"; cec=$?
  case "$cec" in
    0) verdict=ACCEPT ;;
    1) verdict=REJECT ;;
    *) verdict="EXIT$cec" ;;
  esac

  gotcode='-'
  if [ "$verdict" = REJECT ]; then
    # The stable handle is the JSON `code`, not the message prose (which embeds a
    # rendered type and a remedy sentence that may legitimately be reworded).
    run_t "$LIMIT" "$MEDAKA" check --json "$f" > "$WORK/.json" 2> "$WORK/.jsonerr"
    gotcode="$(tr ',' '\n' < "$WORK/.json" | grep '"code"' | head -1 | sed 's/.*"code":"//; s/".*//')"
    [ -n "$gotcode" ] || gotcode='!!NO-CODE'
  fi

  gotval='-'
  if [ "$verdict" = ACCEPT ] && [ "$wantval" != '-' ]; then
    run_t "$LIMIT" "$MEDAKA" run "$f" > "$WORK/.run" 2> "$WORK/.runerr"; rec=$?
    if [ "$rec" -ne 0 ]; then
      gotval="!!RUN-EXIT$rec"
    else
      gotval="$(head -1 "$WORK/.run")"
    fi
    printf '%s=%s\n' "$case" "$gotval" >> "$VALFILE"
  fi

  printf '%-24s %-16s %-7s %-5s %-8s %-22s %s\n' \
    "$case" "$label" "$arm" "$mode" "$verdict" "$gotcode" "$gotval"

  note=''
  if [ "$mode" = PIN ]; then
    if [ "$verdict" != "$correct" ]; then
      note="FAIL: pinned $correct, got $verdict"
      fails=$((fails + 1))
    elif [ "$verdict" = REJECT ] && [ "$gotcode" != "$wantcode" ]; then
      note="FAIL: pinned diagnostic $wantcode, got $gotcode"
      fails=$((fails + 1))
    fi
  else
    if [ "$verdict" = "$today" ]; then
      if [ "$verdict" = REJECT ] && [ "$gotcode" != "$wantcode" ]; then
        note="FAIL: characterized as $today/$wantcode, got $today/$gotcode — a DIFFERENT defect, not the pinned one"
        fails=$((fails + 1))
      else
        note="as characterized — issue #$rowissue still live on this row"
      fi
    elif [ "$verdict" = "$correct" ]; then
      # ⚠️ This message deliberately does NOT spell out the must-fail fixture's
      # directory path. test/preflight.sh's fixture-dir → consumer derivation
      # strips full-line comments but NOT strings, so a path literal in a message
      # here makes this gate look like a CONSUMER of that corpus — the same
      # hint-string false positive preflight's own `_invokes` was hardened
      # against, one axis over. diff_compiler_fixture_corpus_coverage.sh shares
      # the rule, so the edge would also let this gate wrongly certify that
      # corpus as covered. The header names the fixture; grep the issue number.
      note="DRAIN NOTICE: this row now gives the CORRECT answer ($correct). Issue #$rowissue may be drained — re-derive it, and expect that issue's own must-fail pin (grep $rowissue under the must-fail fixture corpus) to go red: that suite owns the drain, this gate only reports it."
      drained=$((drained + 1))
    else
      note="FAIL: neither the correct answer ($correct) nor the characterized one ($today) — got $verdict"
      fails=$((fails + 1))
    fi
  fi

  if [ "$verdict" = ACCEPT ] && [ "$wantval" != '-' ] && [ "$gotval" != "$wantval" ]; then
    note="$note
    FAIL: accepted, but the value is [$gotval], not the derived [$wantval]"
    fails=$((fails + 1))
  fi
  [ -z "$note" ] || printf '    %s\n' "$note"
done
unset IFS

# ── the relation clause: every ACCEPTING arm of a case computes the SAME value ──
# True before AND after the #1564 fix; silent about WHETHER an arm accepts. This is
# what catches an arm that accepts and miscompiles, which acceptance-agreement
# would have graded green.
for case in cond_impl_third_module all_visible no_impl_anywhere user_iface_dispatch user_iface_undetermined iface_default_requires_closure; do
  # `grep -c` exits 1 on no match, so count through `wc -l` instead — a `|| echo 0`
  # fallback appends a SECOND line and the arithmetic below then reads "0\n0".
  n="$(grep "^$case=" "$VALFILE" | wc -l | tr -d ' ')"
  [ "$n" -gt 0 ] || continue
  distinct="$(grep "^$case=" "$VALFILE" | sed "s/^$case=//" | sort -u | wc -l | tr -d ' ')"
  if [ "$distinct" -gt 1 ]; then
    echo "FAIL [$case]: accepting arms disagree on the VALUE ($distinct distinct):"
    grep "^$case=" "$VALFILE" | sed 's/^/      /'
    fails=$((fails + 1))
  else
    printf 'ok   [%s]: %s accepting arm(s), one value\n' "$case" "$n"
  fi
done

# "this didn't run" must never look like "this passed".
if [ "$checked" -eq 0 ]; then
  echo "FAIL: checked 0 rows"
  exit 1
fi
printf 'checked %s rows (%s drain notice(s))\n' "$checked" "$drained"

if [ "$fails" -ne 0 ]; then
  printf '%s row(s) moved — see above.\n' "$fails"
  echo 'If a FLAT row moved, the evidence reader lost an answer the FLAT path gets'
  echo 'right today: that is ARCH B-2.1-a regressing check/lsp/repl, not a stale'
  echo 'expectation. Do not relax a row to match the binary — see the assert-choice'
  echo 'section in this file header.'
  exit 1
fi
echo 'PASS: the FLAT arm holds its pinned answers; accepting arms agree on values.'
exit 0
