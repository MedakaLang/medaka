#!/bin/sh
# diff_compiler_core_ir_typed_modules.sh — the FOURTH engine arm (#1608).
#
# Grades `cevalModules` (compiler/ir/core_ir_eval.mdk) on the TYPED, multi-module
# path — marker + typecheck actually run, so routes are actually stamped — over a
# corpus whose shapes only a route can decide, in BOTH import orders, against a
# HAND-DERIVED expected value.
#
# ── WHY THIS GATE EXISTS ──────────────────────────────────────────────────────
#
# test/diff_compiler_core_ir_modules.sh already runs `cevalModules`, and it is
# STRUCTURALLY BLIND to dispatch: its driver (compiler/entries/core_ir_modules_main.mdk)
# is desugar + annotate only — no marker, no typecheck — so NO `Route` is ever
# stamped, and the driver falls back to untyped arg-tag "first impl wins" for every
# interface method. A gate over that path cannot distinguish a correct route word
# from no route word at all: its green proves nothing in either direction. That is
# #1608's own complaint, and it is why the driver this gate reads
# (compiler/entries/core_ir_typed_modules_main.mdk) had to be written.
#
# AGENTS.md records `evalModules` (eval.mdk) and `cevalModules` (core_ir_eval.mdk)
# as PARALLEL module drivers that must be fixed in LOCKSTEP, and that a fix once
# shipped patching only eval.mdk and left core_ir_eval.mdk broken for months. This
# gate is the instrument that can see that happen — see the LOCKSTEP tier below.
#
# ── WHAT IT GRADES: five arms x two permutations x N cases ────────────────────
#
#   TIER 1 — VALUE, on the TYPED/shipping arms. Each of
#       eval-typed   `medaka run <entry>`                      (the shipping interpreter)
#       native       `medaka build <entry>` + exec              (the shipping binary)
#       ceval-typed  test/bin/core_ir_typed_modules_main        (THE ARM THIS GATE ADDS)
#     must print the case's own expected.txt EXACTLY, at exit 0, in BOTH orderings.
#     ⚠️ NOT LEDGERABLE. A miss here is a red gate, full stop.
#
#   TIER 2 — LOCKSTEP, on the two UNTYPED module drivers. Each of
#       eval-untyped  test/bin/eval_modules_main
#       ceval-untyped test/bin/core_ir_modules_main
#     must produce the SAME bytes as the other, per entry. ⚠️ NOT LEDGERABLE
#     either: a divergence between them IS the AGENTS.md hazard, whichever of the
#     two is wrong, and absorbing it into a ledger row would be exactly the
#     rubber stamp the ledger exists to prevent.
#
#   TIER 3 — VALUE, on the untyped arms, in one of THREE dispositions:
#       (i)   output == expected.txt, no pin, no row -> ok, nothing owed.
#       (ii)  a PIN file `<entry>.untyped.txt` -> the output must equal it EXACTLY.
#             This says "this arm is arg-tag BY CONSTRUCTION and nobody is going to
#             fix it; here is what it prints." No issue is named, because there is
#             no defect to own. Any movement, in either direction, is RED.
#       (iii) no pin and output != expected.txt -> a row in
#             test/CORE-IR-TYPED-LEDGER.txt must name an OPEN issue and transcribe
#             the EXACT observed value. This says "live DEFECT, owned." Missing row
#             -> RED. Value moved -> RED. Case now correct -> RED, naming the issue
#             to close. That is the drain.
#     (ii) and (iii) are mutually exclusive per entry and the gate enforces it: a
#     pin says there is nothing to fix, a row says there is.
#
# ── WHY THE UNTYPED ARMS ARE PINNED AND NOT LEDGERED (#1608, CLOSED) ──────────
#
# This gate was built for #1608, which claimed `cevalModules` resolves a
# cross-module interface method by IMPORT ORDER rather than by the receiver's type.
# Measured arm for arm — first on a program of the described shape, then on the
# reporter's ORIGINAL program recovered verbatim from the sprint packet that
# produced the issue — that does not hold:
#
#   TYPED:   medaka run == medaka build == core_ir_typed_modules_main == CORRECT,
#            and order-invariant, on every case in this corpus.
#   UNTYPED: eval_modules_main == core_ir_modules_main, BYTE-IDENTICAL, and their
#            answer depends on import order rather than on the program.
#
# #1608's ✅/❌ table compared a TYPED `eval` reading (`medaka run`) against an
# UNTYPED `ceval` reading (core_ir_modules_main) — an ARM MISMATCH. Same-arm, the
# two parallel module drivers agree. #1608 was CLOSED 2026-08-15 as mis-scoped at
# filing.
#
# So the untyped arms' answer is wrong under the language semantics but is NOT an
# owned defect: those drivers are desugar + annotate only, no marker and no
# typecheck, so no `Route` is ever stamped and arg-tag "first impl wins" is all
# they have. That is their documented design (`cevalModules`' own header: "UNTYPED
# path, like cevalProgram / evalModules"), not a bug awaiting a fix — and a ledger
# row would be a signed statement that it IS one (see that file's WHAT A ROW MEANS).
# Hence the pin: the behaviour stays graded EXACTLY, which is the whole value of
# this gate, without asserting a defect nobody has argued for.
#
# ⚠️ The pinned value is NOT a blessing and NOT an oracle. expected.txt remains the
# statement of what is CORRECT, hand-derived, and tier 1 holds the shipping arms to
# it. The pin only records what a deliberately route-blind driver does. Note also
# that arg-tag's choice is independent of the program, so in any one ordering it is
# wrong for some programs and ACCIDENTALLY RIGHT for others — which is why several
# pins here equal expected.txt and that coincidence is called out rather than read
# as partial correctness.
#
# The must-fail suite cannot carry any of this: no verb in that harness drives
# `cevalModules` at all. Hence this gate.
#
# ── ORACLES ───────────────────────────────────────────────────────────────────
#
#   test/bin/core_ir_typed_modules_main   test/bin/core_ir_modules_main
#   test/bin/eval_modules_main
#   FORCE=1 JOBS=1 sh test/build_oracles.sh --build-one <name>
#
# Usage:  sh test/diff_compiler_core_ir_typed_modules.sh
# Exit:   0 all tiers satisfied; 1 a tier failed; 2 an oracle or the binary is missing.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="${MEDAKA:-$ROOT/medaka}"
RUNTIME="$ROOT/stdlib/runtime.mdk"
CORE="$ROOT/stdlib/core.mdk"
FIXDIR="$ROOT/test/core_ir_typed_modules_fixtures"
LEDGER="$ROOT/test/CORE-IR-TYPED-LEDGER.txt"

CEVAL_TYPED="$ROOT/test/bin/core_ir_typed_modules_main"
CEVAL_UNTYPED="$ROOT/test/bin/core_ir_modules_main"
EVAL_UNTYPED="$ROOT/test/bin/eval_modules_main"

[ -x "$MEDAKA" ] || { echo "build the compiler first: make medaka (missing $MEDAKA)"; exit 2; }
for probe in "$CEVAL_TYPED" "$CEVAL_UNTYPED" "$EVAL_UNTYPED"; do
  [ -x "$probe" ] || {
    echo "build oracles first: FORCE=1 JOBS=1 sh test/build_oracles.sh --build-one $(basename "$probe") (missing $probe)"
    exit 2
  }
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT INT HUP TERM

# ── escaping ──────────────────────────────────────────────────────────────────
# A ledger row is one line and `|`-separated, so an observed value is escaped the
# same way its two sibling ledgers escape theirs: `\` -> `\\`, `|` -> `\p`,
# newline -> `\n`. The gate escapes what it OBSERVES and compares escaped strings,
# so a row you paste in is byte-for-byte what the gate prints on a failure.
esc() {
  sed -e 's/\\/\\\\/g' -e 's/|/\\p/g' | awk 'BEGIN{ORS=""} {print $0 "\\n"}'
}

# Native's runtime auto-prints a trailing `()` for a Unit-valued main; the probe
# drivers do not. Strip it on every arm so the arms are comparable.
strip_unit() { sed '${/^()$/d;}'; }

fail=0
checked=0

# ── ledger ────────────────────────────────────────────────────────────────────
# Row format (see test/CORE-IR-TYPED-LEDGER.txt for the full contract):
#   <case-dir>/<entry-basename> | #<issue> | <escaped observed untyped value>
# The gate enforces the SYNTAX offline (it must run on a box with no `gh` auth and
# in a required shard where an API blip must not block a merge). test/must_fail_census.sh
# HALF 4 is what reports a ledgered issue that has been CLOSED.
ledger_lookup() {  # $1 = "<case>/<entry>" -> prints "<issue>|<value>" or nothing
  [ -f "$LEDGER" ] || return 0
  awk -F'|' -v key="$1" '
    /^[ \t]*#/ { next }
    /^[ \t]*$/ { next }
    {
      k = $1; gsub(/^[ \t]+|[ \t]+$/, "", k)
      if (k != key) next
      iss = $2; gsub(/^[ \t]+|[ \t]+$/, "", iss)
      val = $3; gsub(/^[ \t]+|[ \t]+$/, "", val)
      print iss "|" val
    }
  ' "$LEDGER"
}

# Every row's key, so a row naming a case/entry that no longer exists can be
# reported as rot rather than silently ignored.
ledger_keys() {
  [ -f "$LEDGER" ] || return 0
  awk -F'|' '
    /^[ \t]*#/ { next }
    /^[ \t]*$/ { next }
    { k = $1; gsub(/^[ \t]+|[ \t]+$/, "", k); print k }
  ' "$LEDGER"
}

: > "$WORK/seen_keys"

for dir in "$FIXDIR"/*/; do
  [ -d "$dir" ] || continue
  case_name="$(basename "$dir")"
  expfile="${dir%/}/expected.txt"
  [ -f "$expfile" ] || { echo "FAIL $case_name — no expected.txt (it is HAND-DERIVED, never captured)"; fail=$((fail+1)); continue; }
  [ -f "${dir%/}/case.txt" ] || { echo "FAIL $case_name — no case.txt (a case must say how its expected value was established)"; fail=$((fail+1)); continue; }
  expected="$(strip_unit < "$expfile" | esc)"

  for entry in "${dir%/}"/main_*.mdk; do
    [ -f "$entry" ] || continue
    ename="$(basename "$entry" .mdk)"
    key="$case_name/$ename"
    checked=$((checked+1))
    echo "$key" >> "$WORK/seen_keys"

    # ── TIER 1: the typed / shipping arms must print the derived value ────────
    tier1_bad=0
    for arm in eval-typed native ceval-typed; do
      case "$arm" in
        eval-typed)
          out="$("$MEDAKA" run "$entry" 2>/dev/null)"; rc=$? ;;
        native)
          "$MEDAKA" build "$entry" -o "$WORK/bin" > "$WORK/build.log" 2>&1
          # NB: no pipe here on purpose — `medaka build`'s exit code does not
          # survive one (AGENTS.md), so it is redirected and read directly.
          if [ $? -ne 0 ]; then out=""; rc=1
          else out="$("$WORK/bin" 2>/dev/null)"; rc=$?; fi ;;
        ceval-typed)
          out="$("$CEVAL_TYPED" "$RUNTIME" "$CORE" "$entry" "${dir%/}" 2>/dev/null)"; rc=$? ;;
      esac
      got="$(printf '%s\n' "$out" | strip_unit | esc)"
      if [ "$rc" -ne 0 ] || [ "$got" != "$expected" ]; then
        tier1_bad=1; fail=$((fail+1))
        printf 'FAIL %s [%s] TIER 1 (value, typed arm — NOT LEDGERABLE)\n' "$key" "$arm"
        printf '  expected (hand-derived): %s\n' "$expected"
        printf '  observed (exit %s):      %s\n' "$rc" "$got"
      fi
    done
    [ "$tier1_bad" -eq 0 ] && printf 'ok   %s  tier1 typed arms == %s\n' "$key" "$expected"

    # ── TIER 2: the two UNTYPED module drivers must agree with EACH OTHER ─────
    eu="$("$EVAL_UNTYPED" "$CORE" "$entry" "${dir%/}" 2>/dev/null | strip_unit | esc)"
    cu="$("$CEVAL_UNTYPED" "$CORE" "$entry" "${dir%/}" 2>/dev/null | strip_unit | esc)"
    if [ "$eu" != "$cu" ]; then
      fail=$((fail+1))
      printf 'FAIL %s TIER 2 (LOCKSTEP — NOT LEDGERABLE)\n' "$key"
      printf '  evalModules  (eval.mdk):        %s\n' "$eu"
      printf '  cevalModules (core_ir_eval.mdk):%s\n' "$cu"
      printf '  ⚠️ AGENTS.md: these are PARALLEL module drivers and must be fixed in\n'
      printf '     LOCKSTEP. A divergence here is the documented hazard, whichever arm\n'
      printf '     is wrong. Do NOT ledger it — fix the driver that was left behind.\n'
      continue
    fi
    printf 'ok   %s  tier2 lockstep evalModules == cevalModules\n' "$key"

    # ── TIER 3: the untyped VALUE ─────────────────────────────────────────────
    # TWO MODES, and which one applies is decided by whether the entry has a PIN
    # file. They mean different things and must not be conflated:
    #
    #   PIN  (<entry>.untyped.txt present) — "this arm is arg-tag BY CONSTRUCTION,
    #        nobody is going to fix it, and here is exactly what it prints." No
    #        issue, because there is no defect to own. The value is still graded
    #        EXACTLY, so any movement in either direction is red.
    #   LEDGER (no pin, value != expected) — "this is a live DEFECT and here is the
    #        OPEN issue that owns it." Drains when the issue is fixed.
    #
    # An entry may not have both: a pin says there is nothing to fix, a row says
    # there is, and signing both is signing a contradiction.
    pinfile="${dir%/}/$ename.untyped.txt"
    row="$(ledger_lookup "$key")"

    if [ -f "$pinfile" ]; then
      if [ -n "$row" ]; then
        fail=$((fail+1))
        printf 'FAIL %s TIER 3 — BOTH a by-design pin AND a ledger row\n' "$key"
        printf '  %s says this arm is by-design and unowned; the %s row says it is a\n' "$(basename "$pinfile")" "${row%%|*}"
        printf '  live defect owned by an open issue. Exactly one of those is true. Decide\n'
        printf '  which, and delete the other.\n'
        continue
      fi
      pinned="$(strip_unit < "$pinfile" | esc)"
      if [ "$eu" != "$pinned" ]; then
        fail=$((fail+1))
        printf 'FAIL %s TIER 3 — THE BY-DESIGN PIN MOVED\n' "$key"
        printf '  pinned (%s): %s\n' "$(basename "$pinfile")" "$pinned"
        printf '  observed:    %s\n' "$eu"
        printf '  ⇒ the untyped arg-tag fallback shared by evalModules and cevalModules\n'
        printf '    changed behaviour. That may be a deliberate improvement or a regression,\n'
        printf '    but it is never a bump: re-derive, decide which it is, and say so in the\n'
        printf "    case's case.txt. If the arm became CORRECT, the pin should be deleted and\n"
        printf '    the entry graded against expected.txt on all five arms.\n'
        continue
      fi
      if [ "$eu" = "$expected" ]; then
        printf 'ok   %s  tier3 untyped pinned (== derived value; arg-tag agrees here by luck)\n' "$key"
      else
        printf 'ok   %s  tier3 untyped pinned by design (%s, derived is %s)\n' "$key" "$pinned" "$expected"
      fi
      continue
    fi

    if [ "$eu" = "$expected" ]; then
      if [ -n "$row" ]; then
        fail=$((fail+1))
        printf 'FAIL %s TIER 3 — LEDGER ROW DRAINED\n' "$key"
        printf '  the untyped arms now print the hand-derived value: %s\n' "$expected"
        printf '  ⇒ CLOSE %s, DELETE the row from test/CORE-IR-TYPED-LEDGER.txt, KEEP the\n' "${row%%|*}"
        printf '    fixture — without a row it is graded as correct, i.e. it becomes the\n'
        printf '    regression guard for the fix.\n'
      else
        printf 'ok   %s  tier3 untyped arms also correct (unledgered, as required)\n' "$key"
      fi
      continue
    fi
    if [ -z "$row" ]; then
      fail=$((fail+1))
      printf 'FAIL %s TIER 3 — UNLEDGERED WRONG VALUE on the untyped arms\n' "$key"
      printf '  expected (hand-derived): %s\n' "$expected"
      printf '  observed (both drivers): %s\n' "$eu"
      printf '  ⇒ either this is a real regression (fix it), or it is a known open defect,\n'
      printf '    in which case add a row to test/CORE-IR-TYPED-LEDGER.txt naming an OPEN\n'
      printf '    issue. Read that file first — a new row is deliberately expensive.\n'
      continue
    fi
    row_val="${row#*|}"
    if [ "$row_val" != "$eu" ]; then
      fail=$((fail+1))
      printf 'FAIL %s TIER 3 — THE DIVERGENCE MOVED\n' "$key"
      printf '  ledger row (%s) pins: %s\n' "${row%%|*}" "$row_val"
      printf '  observed:             %s\n' "$eu"
      printf '  ⇒ the row no longer describes what the binary does. Re-derive, do not bump.\n'
      continue
    fi
    printf 'ok   %s  tier3 untyped wrongness matches its ledger row (%s)\n' "$key" "${row%%|*}"
  done
done

# ── ledger rot: a row naming a case/entry that does not exist ─────────────────
if [ -f "$LEDGER" ]; then
  ledger_keys | while IFS= read -r k; do
    [ -n "$k" ] || continue
    grep -Fxq "$k" "$WORK/seen_keys" || echo "$k" >> "$WORK/rot"
  done
  if [ -f "$WORK/rot" ]; then
    while IFS= read -r k; do
      fail=$((fail+1))
      printf 'FAIL ledger rot — row names %s, which this corpus does not contain\n' "$k"
    done < "$WORK/rot"
  fi
fi

if [ "$checked" -eq 0 ]; then
  echo "NOTHING COMPARED — the corpus is empty. This is not a pass."
  exit 1
fi

printf '\n%d entries graded, %d failing\n' "$checked" "$fail"
[ "$fail" -eq 0 ]
