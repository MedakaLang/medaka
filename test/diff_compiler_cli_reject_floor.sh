#!/bin/sh
# diff_compiler_cli_reject_floor.sh — the ACCEPTANCE FLOOR for convention C2,
# unknown-flag rejection (#2354, S-unknown-flag-floor; umbrella #2301).
#
# ── WHY A SECOND CLI GATE ────────────────────────────────────────────────────
#
# test/diff_compiler_cli_help_conformance.sh (S-help-truthfulness) asserts that
# help prose and parse arms AGREE. Agreement is the right property for prose
# rot, and it is deliberately fail-open where a verb states nothing: its
# Property C reads each verb's own `(known: …)` roster, and a verb that prints
# no roster is reported `C UNCOVERED`, not FAIL. That is correct for C — a verb
# with custom parsing genuinely has nothing for C to compare — but it means the
# gate CANNOT pin C2:
#
#     delete a verb's `requireArgs` call and the verb stops rejecting
#     unknown flags entirely; its roster disappears with it; Property C moves
#     the verb from `covered` to `UNCOVERED` and the suite stays GREEN.
#
# The sprint's acceptance item E3 ("unknown-flag rejection is pinned by a
# fixture that fails on the pre-slice binary") therefore was NOT discharged by
# that gate. This one discharges it: it asserts the BEHAVIOUR C2 ratifies, and
# it goes RED — never `uncovered` — when the behaviour regresses.
#
# ── WHAT C2 SAYS (docs/ops/CLI-CONFORMANCE.md §2, the normative source) ───────
#
#   Every verb rejects an unrecognized `--`-shaped token appearing in a flag
#   position. The rejection goes to stderr, names the offending token AND the
#   verb's known flag set, and exits 1. No verb may treat an unrecognized `--`
#   token as a filename, and no verb may ignore one.
#
# ── THE THREE PROPERTIES ─────────────────────────────────────────────────────
#
#   R  REJECTION FLOOR. Every verb the binary's own usage block lists — minus a
#      declared, self-draining exemption set — must reject `--<bogus>` and exit
#      EXACTLY 1. Never accepted (rc 0), never swallowed as a positional.
#   K  ROSTER FLOOR. Every verb whose SOURCE hands its `ArgSpec` to
#      `requireArgs` must print a `(known: …)` roster in that rejection. This is
#      precisely the fact Property C treats as optional; here its absence is a
#      FAIL.
#   S  REACH. Every source-derived `requireArgs` verb must appear in the
#      usage block, so no covered verb can escape R by being invisible to the
#      derivation. Without S, deleting a verb's usage line would silently
#      narrow R — the same fail-open shape in a new place.
#
# R alone would still fail open if the verb list came from the thing being
# floored; S is what closes that. K alone would fail open if a call were
# deleted; R is what closes that. The three are load-bearing together.
#
# ── NOTHING IS ENCODED EXCEPT THE EXEMPTIONS, AND THOSE SELF-DRAIN ───────────
#
# No roster of verbs or flags appears in this file. Verbs come out of the binary
# (`cli_verbs`), the covered set out of the source (`requireArgs <verb>ArgSpec`
# resolved through that spec's own `spec "<verb>"` head — see the derivation),
# and the "is this a rejection" classifier is the ONE already-shared
# `cli_rejects_as_unknown` in test/cli_conformance_lib.sh — extended here by
# nobody, so the five accepted wordings cannot be half-updated in two consumers.
#
# The single exemption below is INVERTED, must-fail style: an exempt verb that
# STARTS conforming is a FAIL telling you to delete the exemption. An exemption
# list that only ever suppresses is how a floor rots into a ceiling.
#
# ── PROBE SHAPE, STATED RATHER THAN HIDDEN ───────────────────────────────────
#
# Two argv shapes are probed per verb — `medaka <verb> --bogus` and
# `medaka <verb> --bogus ok.mdk` — because verbs disagree about arity-checking
# order, and that disagreement is not a C2 violation: `medaka new` takes a
# project NAME, so the second shape is an arity error for it, correctly. The
# rule is therefore: at least one shape must REJECT with rc 1, and NO shape may
# exit 0. A non-rejecting shape must be some other loud error, and the gate
# prints which one it was.
#
# Usage:  sh test/diff_compiler_cli_reject_floor.sh
# Exit:   0 R/K/S all hold; 1 a floor breach; 2 no ./medaka built.

set -u

ROOT=${ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}
MEDAKA=${MEDAKA:-$ROOT/medaka}

# The token. Deliberately long and self-describing: it shows up verbatim in
# every failure message, and no verb can plausibly grow an arm for it.
BOGUS=--this-flag-does-not-exist-zz

# Verbs exempt from R, each with the reason it cannot hold. See the inverted
# staleness assertion (R') below: adding a name here does not merely silence it.
#
#   help — `medaka help` is the usage printer. It has no flag position at all:
#          every trailing token is ignored and it exits 0, which is the whole
#          point of the verb. Measured, not assumed: `medaka help --bogus`
#          prints the usage block, rc 0.
EXEMPT="help"

if [ ! -x "$MEDAKA" ]; then
  echo "diff_compiler_cli_reject_floor: no binary at $MEDAKA — run 'make medaka' first." >&2
  exit 2
fi

. "$ROOT/test/cli_conformance_lib.sh"
cli_lib_init || exit 2
trap 'cli_lib_cleanup' EXIT INT TERM

FAILS=$CLI_WORK/fails
: > "$FAILS"
fail() { echo "FAIL $*" | tee -a "$FAILS"; }

is_exempt() {
  for _e in $EXEMPT; do
    [ "$_e" = "$1" ] && return 0
  done
  return 1
}

# Classify one probe. Sets PR_VERDICT to REJECTS / ACCEPTED / OTHER-ERR, the rc
# to $PR_RC, the first line of the message to $PR_MSG, the whole of it to
# $PR_FULL.
#
# ⚠️ It ASSIGNS rather than echoing, and callers must invoke it plainly rather
# than as `v=$(probe_shape …)`: command substitution runs the function in a
# SUBSHELL, so every one of those four variables would be discarded and the
# caller would read a stale rc from the previous verb — a gate that reports the
# wrong verb's exit code is worse than one that reports nothing.
probe_shape() {
  _ps_verb=$1
  _ps_shape=$2
  if [ "$_ps_shape" = bare ]; then
    cli_probe "$_ps_verb" "$BOGUS"
  else
    cli_probe "$_ps_verb" "$BOGUS" ok.mdk
  fi
  PR_RC=$CLI_RC
  PR_FULL=$(cli_msg)
  PR_MSG=$(printf '%s' "$PR_FULL" | head -n 1 | cut -c1-90)
  if cli_rejects_as_unknown "$PR_FULL" "$BOGUS"; then
    PR_VERDICT=REJECTS
  elif [ "$PR_RC" -eq 0 ]; then
    PR_VERDICT=ACCEPTED
  else
    PR_VERDICT=OTHER-ERR
  fi
}

VERBS=$(cli_verbs)

# The covered set, from SOURCE, in TWO steps since S-cli-onto-args (#2355)
# migrated every covered verb onto stdlib/args.mdk: the old
# `assertCliFlags "<verb>" …` call carried the verb name as a literal at the
# call site, and `requireArgs <verb>ArgSpec argv` carries a SPEC NAME instead.
#
#   step 1  which `…ArgSpec` values are actually passed to `requireArgs`
#   step 2  each of those specs' own `spec "<verb>"` head — the single place
#           the verb name is written
#
# Two steps rather than one is what keeps this derived rather than encoded: the
# tree also carries specs that exist ONLY to render the rejection sentence, for
# verbs that share the wording but not the floor (they parse their argv their
# own way), and those must not be counted as covered. Step 1 is what excludes
# them — a spec is covered iff it is handed to `requireArgs`, which is the same
# thing as "this verb's whole argv goes through the shared parse". Note the
# spec's NAME need not contain the verb (`check-policy`'s is `policyArgSpec`);
# only step 2's `spec "<verb>"` head names verbs, which is the point.
# Swept over all of compiler/ rather than one file so a call that
# moves house is still found. The `ArgSpec` suffix is required by the pattern,
# so `requireArgs`'s own definition line (`requireArgs sp argv = …`) and its
# signature contribute nothing.
SRC_SPECS=$(grep -rh 'requireArgs ' "$ROOT/compiler" 2>/dev/null \
            | sed -n 's/.*requireArgs \([a-zA-Z][a-zA-Z0-9_]*ArgSpec\).*/\1/p' | sort -u)
# ⚠️ Step 2 reads a WINDOW, not one line, because `medaka fmt` decides where a
# wide `<name> = spec "<verb>" [ … ]` body breaks: it leaves a short one whole
# (`docArgSpec = spec "doc" []`) and pushes a long one's argument to the next
# line (`checkArgSpec = spec` / `  "check" [`). A single-line pattern here
# resolved 2 of 9 specs and the gate still said PASS — a fail-open caught only
# because the covered COUNT was compared against the pre-migration one. The
# SPECS-vs-VERBS reconciliation below is what makes that comparison automatic.
SRC_VERBS=$(for _s in $SRC_SPECS; do
              grep -rhA3 "^$_s = spec" "$ROOT/compiler" 2>/dev/null \
                | sed -n 's/.*"\([a-z][a-z0-9-]*\)".*/\1/p' | head -n 1
            done | sort -u | tr '\n' ' ')

echo "== medaka CLI unknown-flag rejection floor (convention C2) =="
echo "   binary : $MEDAKA"
echo "   token  : $BOGUS"
echo "   verbs  : $VERBS"
echo "   covered: $SRC_VERBS  (verbs whose spec reaches \`requireArgs\`, from source)"
echo "   exempt : $EXEMPT"
echo

# ── D: the derivation resolved EVERY spec it found ──────────────────────────
#
# K and S iterate SRC_VERBS, so a step-2 pattern that quietly resolves only
# some of step 1's specs shrinks the covered set and both properties still
# report PASS over what is left — the same fail-open shape this whole gate
# exists to close, one level further in. Reconcile the two counts instead of
# trusting the pattern.
echo "-- D: every spec handed to \`requireArgs\` resolved to a verb --"
d_specs=$(printf '%s\n' $SRC_SPECS | grep -c . || true)
d_verbs=$(printf '%s\n' $SRC_VERBS | grep -c . || true)
if [ "$d_specs" -eq 0 ]; then
  fail "D no \`requireArgs <name>ArgSpec\` call found anywhere under compiler/ — the shared parse helper has been removed or renamed. Update this gate's step-1 pattern in the same commit if that was deliberate."
elif [ "$d_specs" -ne "$d_verbs" ]; then
  fail "D step 1 found $d_specs spec(s) [$SRC_SPECS] but step 2 resolved only $d_verbs verb name(s) [$SRC_VERBS] — the \`<name> = spec \"<verb>\"\` window pattern missed one, so K and S are silently narrowed. Fix the pattern, do not adjust the counts."
else
  echo "   D: $d_specs spec(s) -> $d_verbs verb name(s), one each."
fi
echo

# ── R: every non-exempt verb rejects, exit code exactly 1 ────────────────────
echo "-- R: unknown-flag rejection floor --"
r_ok=0
for v in $VERBS; do
  if is_exempt "$v"; then continue; fi
  v_rejects=0
  v_bad=0
  v_note=""
  for shape in bare withfile; do
    probe_shape "$v" "$shape"
    case "$PR_VERDICT" in
      REJECTS)
        if [ "$PR_RC" -ne 1 ]; then
          fail "R \`medaka $v $BOGUS\` ($shape) rejects but exits $PR_RC, not 1 (C2 fixes rc 1): $PR_MSG"
          v_bad=1
        else
          v_rejects=1
        fi
        ;;
      ACCEPTED)
        fail "R \`medaka $v $BOGUS\` ($shape) exits 0 — the unknown flag was SWALLOWED: ${PR_MSG:-<silent>}"
        v_bad=1
        ;;
      OTHER-ERR)
        v_note="$v_note $shape=other-err(rc$PR_RC)"
        ;;
    esac
  done
  if [ "$v_bad" -eq 1 ]; then
    :
  elif [ "$v_rejects" -eq 0 ]; then
    fail "R \`medaka $v $BOGUS\` never rejects the token as unknown, in either argv shape: $PR_MSG"
  else
    r_ok=$((r_ok + 1))
    echo "   $v: rejects as unknown, rc 1.${v_note:+ —}$v_note"
  fi
done
echo "   R: $r_ok verbs reject an unknown flag with rc 1."
echo

# ── R': the declared exemptions are still needed (inverted, must-fail style) ─
echo "-- R': declared exemptions still necessary --"
for v in $EXEMPT; do
  case " $VERBS " in
    *" $v "*) ;;
    *)
      fail "R' \`$v\` is exempt from R but is not a verb the binary lists — delete the stale exemption."
      continue
      ;;
  esac
  ex_rejects=0
  for shape in bare withfile; do
    probe_shape "$v" "$shape"
    [ "$PR_VERDICT" = REJECTS ] && ex_rejects=1
  done
  if [ "$ex_rejects" -eq 1 ]; then
    fail "R' \`medaka $v\` now REJECTS unknown flags — good news, and this gate's exemption is stale. Remove \`$v\` from EXEMPT so R floors it."
  else
    echo "   $v: still non-rejecting by design — exemption live."
  fi
done
echo

# ── K: every source-covered verb names its known set ─────────────────────────
#
# This is the exact fact Property C of diff_compiler_cli_help_conformance.sh
# reports as `UNCOVERED` when it is missing. Here its absence is a FAIL, which
# is the whole reason this gate exists.
echo "-- K: every \`requireArgs\` verb prints a \`(known: …)\` roster --"
k_ok=0
k_n=0
if [ -z "$SRC_VERBS" ]; then
  fail "K no \`requireArgs <verb>ArgSpec\` call resolving to a \`spec \"<verb>\"\` head found anywhere under compiler/ — the shared rejection helper has been removed or renamed. That is the regression this gate exists to catch, not a derivation bug: if the helper was deliberately renamed, update this gate's two-step pattern in the same commit."
fi
for v in $SRC_VERBS; do
  k_n=$((k_n + 1))
  probe_shape "$v" bare
  case "$PR_FULL" in
    *"(known: "*)
      k_ok=$((k_ok + 1))
      echo "   $v: $PR_MSG"
      ;;
    *)
      fail "K source hands \`$v\`'s spec to \`requireArgs\`, but \`medaka $v $BOGUS\` prints no \`(known: …)\` roster [$PR_VERDICT rc$PR_RC]: ${PR_MSG:-<silent>}"
      ;;
  esac
done
echo "   K: $k_ok of $k_n covered verbs name their known set."
echo

# ── S: every source-covered verb is reachable by R ───────────────────────────
echo "-- S: every covered verb appears in the usage block (so R sees it) --"
s_ok=0
for v in $SRC_VERBS; do
  case " $VERBS " in
    *" $v "*) s_ok=$((s_ok + 1)) ;;
    *) fail "S source hands \`$v\`'s spec to \`requireArgs\`, but \`medaka help\` never lists \`$v\` — R cannot see it, so its rejection is unfloored." ;;
  esac
  if is_exempt "$v"; then
    fail "S \`$v\` has a \`requireArgs\` call AND sits in this gate's EXEMPT list — a covered verb must never be exempt."
  fi
done
echo "   S: $s_ok of $k_n covered verbs are visible to R."
echo

# `wc -l`, not `grep -c`: grep EXITS 1 on an empty file, so a `|| echo 0`
# fallback appends a SECOND zero and every later numeric test dies on
# "Illegal number: 0\n0" — a counting bug that reports FAIL on a clean run.
n=$(wc -l < "$FAILS" | tr -d ' ')
if [ "$n" -eq 0 ]; then
  echo "PASS diff_compiler_cli_reject_floor: R/K/S all hold."
  exit 0
fi
echo "FAIL diff_compiler_cli_reject_floor: $n floor breach(es) above."
exit 1
