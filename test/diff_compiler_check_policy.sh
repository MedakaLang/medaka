#!/bin/sh
# diff_compiler_check_policy.sh — `medaka check-policy` gate.
#
# WS-1a (bare-label policy compare): the native `medaka check-policy <file>
# [--allow …] [--fn …]` (compiler/tools/check_policy.mdk via medaka_cli.mdk) must
# be BYTE-IDENTICAL to a committed native golden
# (test/check_policy_fixtures/ws1a_<case>.golden + .rc) over the capability demo
# plugins (demo/plugin_good.mdk, demo/plugin_malicious.mdk), across a permissive
# policy (→ accept, exit 0) and a restrictive policy (→ reject + the call chain,
# exit 1).  This is WS-1a of docs/design/EFFECTS-CONFORMANCE-ROADMAP.md.
#
# OCaml-free (LIB-REMOVAL-DESIGN §6 Stage A): the goldens were captured from the
# canonical native ./medaka — no live OCaml oracle.
#
# Each case compares stdout/stderr AND the exit code (accept=0 / reject=1).
# Path-stable: the plugin path is the only absolute path that can appear; we strip
# it (sed) so goldens never bake /Users/.
#
# Usage:  sh test/diff_compiler_check_policy.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NATIVE="$ROOT/medaka"
GOLDIR="$ROOT/test/check_policy_fixtures"

[ -x "$NATIVE" ] || { echo "SKIP: ./medaka not built — run: make medaka"; exit 2; }
. "$ROOT/test/lib_stale_warning.sh"

export MEDAKA_ROOT="$ROOT"

pass=0; fail=0
mdk_require_marker || fail=$((fail+1))

# one_case <label> <file> <allow> <fn> <golden-stem>
one_case() {
  label="$1"; file="$2"; allow="$3"; fn="$4"; stem="$5"
  mdk="$ROOT/$file"
  golden="$GOLDIR/${stem}.golden"; rcfile="$GOLDIR/${stem}.rc"
  [ -f "$mdk" ]    || { fail=$((fail+1)); printf 'FAIL %s (missing %s)\n' "$label" "$file"; return; }
  [ -f "$golden" ] || { fail=$((fail+1)); printf 'FAIL %s (missing golden %s)\n' "$label" "$golden"; return; }
  [ -f "$rcfile" ] || { fail=$((fail+1)); printf 'FAIL %s (missing rc %s)\n' "$label" "$rcfile"; return; }

  # Capture stdout+stderr to a tmpfile so $? is the native exit code, not sed's.
  tmpout="$(mktemp)"
  perl -e 'alarm 90; exec @ARGV' \
      "$NATIVE" check-policy "$mdk" --allow "$allow" --fn "$fn" > "$tmpout" 2>&1
  native_rc=$?
  native_out="$(sed "s|$mdk|<plugin>|g" "$tmpout")"; rm -f "$tmpout"
  ref_out="$(cat "$golden")"; ref_rc="$(cat "$rcfile")"

  if [ "$native_out" = "$ref_out" ] && [ "$native_rc" = "$ref_rc" ]; then
    pass=$((pass+1)); printf 'ok   %s (rc=%s)\n' "$label" "$native_rc"
    return
  fi
  cls="$(mdk_classify_diff "$native_out" "$ref_out")"
  if [ "$cls" = "STALE_ONLY" ] && [ "$native_rc" = "$ref_rc" ]; then
    fail=$((fail+1)); mdk_stale_fail_line "$label"
  else
    fail=$((fail+1)); printf 'FAIL %s (native rc=%s, golden rc=%s)\n' "$label" "$native_rc" "$ref_rc"
    [ "$cls" = "STALE_ONLY" ] || [ "$cls" = "STALE_PLUS_DIFF" ] && mdk_stale_note
    printf '  --- native ---\n%s\n  --- golden ---\n%s\n' "$native_out" "$ref_out"
  fi
}

# Accept: good plugin, permissive policy.
one_case "good-accept"        demo/plugin_good.mdk      "Cache,Log,FFI" transform ws1a_good_accept
# Reject: good plugin, restrictive policy (drops Log) → chain via logEvent.
one_case "good-reject"        demo/plugin_good.mdk      "Cache"     transform ws1a_good_reject
# Reject: malicious plugin, the demo policy → chain four helpers deep to fetch.
one_case "malicious-reject"   demo/plugin_malicious.mdk "Cache,Log" transform ws1a_malicious_reject
# Reject from a mid-graph entry: trace from tagVisit (chain to fetch).
one_case "midgraph-reject"    demo/plugin_malicious.mdk "Cache,Log" tagVisit  ws1a_midgraph_reject
# Accept: the plugin run reaches a user interface default and a prelude one.
one_case "defaults-accept"    test/check_policy_fixtures/defaults_plugin.mdk "Log,FFI" transform defaults_accept
# Accepted entries that are not `String -> String`: verdict, then a no-sample line.
one_case "int-entry-accept"   test/check_policy_fixtures/int_entry_plugin.mdk "Audit" transfer int_entry_accept
one_case "named-entry-sample" test/check_policy_fixtures/named_entry_plugin.mdk "FileRead" transform named_entry_accept
# An <IO> entry under a policy that names the eleven host labels.
one_case "io-join-accept"     test/check_policy_fixtures/io_join_plugin.mdk "Clock,Env,Exec,FileRead,FileWrite,Net,Rand,Signal,Stderr,Stdin,Stdout" transform io_join_accept
# The sample line follows `--fn`, not a fixed entry name.
one_case "renamed-entry-sample" test/check_policy_fixtures/renamed_entry_plugin.mdk "Audit" rewrite renamed_entry_accept
one_case "build-stamp-sample" test/check_policy_fixtures/build_stamp_plugin.mdk "Audit" stamp build_stamp_accept
one_case "thunk-entry-accept" test/check_policy_fixtures/thunk_entry_plugin.mdk "Audit" tick thunk_entry_accept
# Multi-file targets load through the module loader, as `manifest` does (#3331):
# the effect arrives from an imported sibling, the sample run evaluates the
# loaded program, and the chain is traced through the entry module's helpers.
one_case "xmod-accept"        test/check_policy_fixtures/policy_xmod_main.mdk "Stdout" transform xmod_accept
one_case "xmod-reject"        test/check_policy_fixtures/policy_xmod_main.mdk "Cache" transform xmod_reject
one_case "stdlib-import-accept" test/check_policy_fixtures/policy_stdlib_import.mdk "Stdout" shout stdlib_import_accept
#
# NOTE: an ACCEPT case that admits Fetch (e.g. malicious + --allow Cache,Log,Fetch)
# is deliberately NOT tested.  check-policy ACCEPT runs the plugin with stubs for
# only the three platform externs (cacheGet/cacheSet/logEvent); a plugin that
# actually reaches `fetch` then panics on the unstubbed extern in BOTH compilers,
# but the panic surfaces pre-existing native-vs-OCaml differences (stderr buffer
# ordering + panic-message format) that are unrelated to the policy logic.  The
# realistic accept path (good plugin, only stubbed externs) is covered by
# good-accept and is byte-identical.

echo ""
printf '%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1

# ── WS-1b: PARAMETER-LEVEL compare (NATIVE-ONLY — no oracle) ─────────────────
# The OCaml oracle does bare-label compare only; parameter-level compare
# (--allow 'Net=host/*' admitting an inferred <Net "host/api">) is a native-only
# enhancement, so these assert the native binary's accept/reject DIRECTLY (NOT
# vs the oracle).  The fixture's transform calls a <Net Prefix> extern with a
# STRING LITERAL, so the alpha known-prefix analysis infers
# <Net "idp.example.com/api">.  transform returns a closure so the accept-path
# run does not force the unstubbed netGet extern (clean rc 0 on accept).
ppass=0; pfail=0
PFIX="test/check_policy_fixtures/net_param_plugin.mdk"

# param_case LABEL ALLOW EXPECT_RC EXPECT_SUBSTR
param_case() {
  plabel="$1"; pallow="$2"; prc="$3"; psub="$4"
  pmdk="$ROOT/$PFIX"
  [ -f "$pmdk" ] || { pfail=$((pfail+1)); printf 'FAIL %s (missing %s)\n' "$plabel" "$PFIX"; return; }
  raw="$(perl -e 'alarm 90; exec @ARGV' \
      "$NATIVE" check-policy "$pmdk" --allow "$pallow" --fn transform 2>&1)"
  rc=$?
  out="$(printf '%s' "$raw" | sed "s|$pmdk|<plugin>|g")"
  if [ "$rc" = "$prc" ] && printf '%s' "$out" | grep -qF "$psub"; then
    ppass=$((ppass+1)); printf 'ok   %s (rc=%s)\n' "$plabel" "$rc"
  else
    pfail=$((pfail+1)); printf 'FAIL %s (rc=%s, want rc=%s + substr <%s>)\n' "$plabel" "$rc" "$prc" "$psub"
    printf '  --- native ---\n%s\n' "$out"
  fi
}

echo ""
echo "-- WS-1b parameter-level compare (native-only) --"
# inferred <Net "idp.example.com/api"> within policy wildcard idp.example.com/* => ACCEPT
param_case "param-prefix-accept"  "Net=idp.example.com/*,FFI"  0 "accepted"
# inferred <Net "idp.example.com/api"> NOT within other.com/* => REJECT, names Net
param_case "param-prefix-reject"  "Net=other.com/*"        1 "rejected"
# bare Net => policy param top => dsub _ top = True => ACCEPT (WS-1a invariant)
param_case "param-bare-accept"    "Net,FFI"                0 "accepted"

# ── WS-2: α SCOPE-SEEDING (E3 precision, NATIVE-ONLY) ────────────────────────
# Same fixture shape as WS-1b but the capability URL is bound by an OUTER-BODY
# `let dest = "<literal>"` then passed to the `<Net url>` extern.  Pre-WS-2 α ran
# with an empty `lets` at the fill site → `netGet dest` collapsed to ⊤ →
# OVER-REJECTED under a wildcard policy.  WS-2 seeds α with the enclosing body's
# let scope, so the inferred row carries the recovered literal prefix and the
# wildcard policy ADMITS it.  Soundness guards: a COMPUTED let RHS and a
# HELPER-LAUNDERED literal must STAY ⊤ (reject) — α recovers a prefix only when
# it can prove one, and is intraprocedural (spec §5 non-goal).
# param_case_f LABEL FIXTURE ALLOW EXPECT_RC EXPECT_SUBSTR
param_case_f() {
  flabel="$1"; ffix="$2"; fallow="$3"; frc="$4"; fsub="$5"
  fmdk="$ROOT/$ffix"
  [ -f "$fmdk" ] || { pfail=$((pfail+1)); printf 'FAIL %s (missing %s)\n' "$flabel" "$ffix"; return; }
  fraw="$(perl -e 'alarm 90; exec @ARGV' \
      "$NATIVE" check-policy "$fmdk" --allow "$fallow" --fn transform 2>&1)"
  frc_actual=$?
  fout="$(printf '%s' "$fraw" | sed "s|$fmdk|<plugin>|g")"
  if [ "$frc_actual" = "$frc" ] && printf '%s' "$fout" | grep -qF "$fsub"; then
    ppass=$((ppass+1)); printf 'ok   %s (rc=%s)\n' "$flabel" "$frc_actual"
  else
    pfail=$((pfail+1)); printf 'FAIL %s (rc=%s, want rc=%s + substr <%s>)\n' "$flabel" "$frc_actual" "$frc" "$fsub"
    printf '  --- native ---\n%s\n' "$fout"
  fi
}

echo ""
echo "-- WS-2 α scope-seeding (native-only) --"
OUTER="test/check_policy_fixtures/net_param_outer_let.mdk"
COMP="test/check_policy_fixtures/net_param_computed.mdk"
HELP="test/check_policy_fixtures/net_param_helper.mdk"
# A4/outer: outer-body let literal recovered ⇒ wildcard ADMITS ⇒ ACCEPT (was reject pre-WS-2)
param_case_f "ws2-outer-accept"   "$OUTER" "Net=idp.example.com/*,FFI" 0 "accepted"
# A4/outer under a non-matching wildcard ⇒ REJECT, names the recovered prefix
param_case_f "ws2-outer-reject"   "$OUTER" "Net=other.com/*"       1 "idp.example.com/api"
# A3/computed: let RHS is a parameter ⇒ α = ⊤ ⇒ STAY REJECTED (soundness)
param_case_f "ws2-computed-reject" "$COMP" "Net=idp.example.com/*" 1 "rejected"
# helper-laundered literal ⇒ intraprocedural boundary ⇒ α = ⊤ ⇒ STAY REJECTED
param_case_f "ws2-helper-reject"   "$HELP" "Net=idp.example.com/*" 1 "rejected"

echo ""
printf '%d param ok, %d param failing\n' "$ppass" "$pfail"
[ "$pfail" -eq 0 ] || exit 1

# ── Fail-closed analysis, entry, and evaluation routes (#2127/#2047) ───────
fpass=0; ffail=0

# refuse_case LABEL FIXTURE ALLOW FN EXPECTED_SUBSTRING [SECOND_SUBSTRING]
refuse_case() {
  rlabel="$1"; rfix="$2"; rallow="$3"; rfn="$4"; rsub="$5"; rsub2="${6:-$5}"
  rmdk="$ROOT/$rfix"
  rtmp="$(mktemp)"
  perl -e 'alarm 90; exec @ARGV' \
      "$NATIVE" check-policy "$rmdk" --allow "$rallow" --fn "$rfn" > "$rtmp" 2>&1
  rrc=$?
  if [ "$rrc" -ne 0 ] && ! grep -qF "accepted." "$rtmp" && grep -qF "$rsub" "$rtmp" && grep -qF "$rsub2" "$rtmp"; then
    fpass=$((fpass+1)); printf 'ok   %s (rc=%s, no accepted verdict)\n' "$rlabel" "$rrc"
  else
    ffail=$((ffail+1)); printf 'FAIL %s (rc=%s, want nonzero + <%s> + <%s> + no accepted verdict)\n' "$rlabel" "$rrc" "$rsub" "$rsub2"
    sed 's/^/  /' "$rtmp"
  fi
  rm -f "$rtmp"
}

echo ""
echo "-- fail-closed analysis, entry, and evaluation --"
refuse_case "analysis-type-error" "test/check_policy_fixtures/type_error_plugin.mdk" "Panic" transform "rejected. compiler analysis failed" "type_error_plugin.mdk:5:14: No impl of Num for String"
refuse_case "analysis-unlabelled-ffi" "test/check_policy_fixtures/ffi_unlabelled_plugin.mdk" "FFI,Net" transform "rejected. compiler analysis failed"
# #3331: the refusal carries `check`'s diagnostics, located in the file that
# failed — here an imported sibling, and an unresolvable import.
refuse_case "analysis-import-type-error" "test/check_policy_fixtures/policy_xmod_bad_main.mdk" "Stdout" transform "rejected. compiler analysis failed" "policy_xmod_bad_helper.mdk:4:10: No impl of Num for String"
refuse_case "analysis-unresolvable" "test/check_policy_fixtures/manifest_unresolvable_plugin.mdk" "Stdout" transform "rejected. compiler analysis failed" "has no exported name 'noSuchExport'"
refuse_case "missing-entry-2047" "test/check_policy_fixtures/missing_entry_plugin.mdk" "Cache,Log" transform "rejected. no 'transform' entry found"
refuse_case "io-join-without-net" "test/check_policy_fixtures/io_join_plugin.mdk" "Clock,Env,Exec,FileRead,FileWrite,Rand,Signal,Stderr,Stdin,Stdout" transform "rejected. transform requires <IO>"
refuse_case "io-join-without-signal" "test/check_policy_fixtures/io_join_plugin.mdk" "Clock,Env,Exec,FileRead,FileWrite,Net,Rand,Stderr,Stdin,Stdout" transform "rejected. transform requires <IO>"

# Verdict first: the accepted verdict is printed before the sample run, so a
# panicking sample leaves `accepted.` on stdout, then panics, exit 1.
panic_tmp="$(mktemp)"
perl -e 'alarm 90; exec @ARGV' \
    "$NATIVE" check-policy "$ROOT/test/check_policy_fixtures/panic_plugin.mdk" \
    --allow "Panic" --fn transform > "$panic_tmp" 2> "$panic_tmp.err"
panic_rc=$?
if [ "$panic_rc" -eq 1 ] && [ "$(cat "$panic_tmp")" = "accepted. transform requires only pure" ] && grep -qF "policy evaluation boom" "$panic_tmp.err"; then
  fpass=$((fpass+1)); printf 'ok   evaluation-panic (verdict prints, then the sample panics, rc=1)\n'
else
  ffail=$((ffail+1)); printf 'FAIL evaluation-panic (rc=%s, want 1 + stdout exactly the accepted verdict + boom on stderr)\n' "$panic_rc"
  sed 's/^/  /' "$panic_tmp" "$panic_tmp.err"
fi
rm -f "$panic_tmp" "$panic_tmp.err"

# The #2047 control flips only entry presence in the same fixture and must still
# reach a genuine acceptance verdict at exit 0.
control_tmp="$(mktemp)"
perl -e 'alarm 90; exec @ARGV' \
    "$NATIVE" check-policy "$ROOT/test/check_policy_fixtures/missing_entry_plugin.mdk" \
    --allow "Cache,Log" --fn rewriteHeader > "$control_tmp" 2>&1
control_rc=$?
if [ "$control_rc" -eq 0 ] && grep -qF "accepted. rewriteHeader" "$control_tmp"; then
  fpass=$((fpass+1)); printf 'ok   missing-entry-2047-control (rc=0, accepted)\n'
else
  ffail=$((ffail+1)); printf 'FAIL missing-entry-2047-control (rc=%s, want rc=0 + accepted verdict)\n' "$control_rc"
  sed 's/^/  /' "$control_tmp"
fi
rm -f "$control_tmp"

echo ""
printf '%d fail-closed ok, %d fail-closed failing\n' "$fpass" "$ffail"
[ "$ffail" -eq 0 ] || exit 1
