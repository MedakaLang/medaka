#!/bin/sh
# test/manifest_emit.sh — `medaka manifest` capability manifest emission gate.
#
# WS-1c of docs/design/EFFECTS-CONFORMANCE-ROADMAP.md.  Verifies:
#   1. TOML golden output: correct key=value rendering (Prefix param → string,
#      ⊤ param → true).
#   2. Multi-label ordering: a two-capability row emits BOTH labels, sorted ascending.
#   3. Round-trip accept: manifest-derived --allow tokens → check-policy rc 0.
#   4. Tightened reject: narrowed param (non-matching prefix) → check-policy rc 1.
#
# Native-only gate (no OCaml oracle for `manifest` — it's a new native subcommand).
# Usage: sh test/manifest_emit.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NATIVE="$ROOT/medaka"
export MEDAKA_ROOT="$ROOT"

[ -x "$NATIVE" ] || { echo "SKIP: ./medaka not built — run: make medaka"; exit 2; }

pass=0; fail=0

ok_case() {
  printf 'ok   %s\n' "$1"
  pass=$((pass+1))
}

fail_case() {
  printf 'FAIL %s: %s\n' "$1" "$2"
  fail=$((fail+1))
}

# ── case 1: net_param_plugin.mdk — Prefix param renders as string ─────────────
# transform has inferred <Net "idp.example.com/api">
# Expected TOML:
#   [package.capabilities]
#   Net = "idp.example.com/api"
NET_FIX="$ROOT/test/check_policy_fixtures/net_param_plugin.mdk"
[ -f "$NET_FIX" ] || { fail_case "net-golden" "missing $NET_FIX"; }

if [ -f "$NET_FIX" ]; then
  got="$(perl -e 'alarm 90; exec @ARGV' "$NATIVE" manifest "$NET_FIX" --fn transform 2>&1)"
  expected='[package.capabilities]
FFI = true
Net = "idp.example.com/api"'
  if [ "$got" = "$expected" ]; then
    ok_case "net-golden (Prefix param renders as string)"
  else
    fail_case "net-golden" "expected $(printf '%s' "$expected" | head -2); got: $got"
  fi
fi

# ── case 2: manifest_mixed.mdk — multi-label row, both labels sorted ──────────
# entry has inferred <Clock, Stdout>; manifest must be:
#   [package.capabilities]
#   Clock = true
#   Stdout = true
# (both are ⊤-param host capabilities → true; labels sorted ascending)
MIXED_FIX="$ROOT/test/check_policy_fixtures/manifest_mixed.mdk"
[ -f "$MIXED_FIX" ] || { fail_case "mixed-golden" "missing $MIXED_FIX"; }

if [ -f "$MIXED_FIX" ]; then
  got="$(perl -e 'alarm 90; exec @ARGV' "$NATIVE" manifest "$MIXED_FIX" --fn entry 2>&1)"
  expected='[package.capabilities]
Clock = true
Stdout = true'
  if [ "$got" = "$expected" ]; then
    ok_case "mixed-golden (multi-label row, sorted ascending)"
  else
    fail_case "mixed-golden" "expected: $expected; got: $got"
  fi

  # Assert both labels appear
  if printf '%s' "$got" | grep -qF "Clock"; then
    ok_case "clock-present (Clock capability in manifest)"
  else
    fail_case "clock-present" "Clock missing from manifest: $got"
  fi

  if printf '%s' "$got" | grep -qF "Stdout"; then
    ok_case "stdout-present (Stdout capability in manifest)"
  else
    fail_case "stdout-present" "Stdout missing from manifest: $got"
  fi
fi

# ── case 3: round-trip accept ────────────────────────────────────────────────
# The manifest-derived --allow token for net_param_plugin is "Net=idp.example.com/api".
# check-policy with that exact allow must ACCEPT (rc 0).
# This proves the manifest is the exact verified authority (self ⊑ self).
if [ -f "$NET_FIX" ]; then
  rt_out="$(perl -e 'alarm 90; exec @ARGV' \
      "$NATIVE" check-policy "$NET_FIX" --allow "FFI,Net=idp.example.com/api" --fn transform 2>&1)"
  rt_rc=$?
  if [ "$rt_rc" = "0" ] && printf '%s' "$rt_out" | grep -qF "accepted"; then
    ok_case "round-trip-accept (manifest → check-policy rc=0)"
  else
    fail_case "round-trip-accept" "rc=$rt_rc output: $rt_out"
  fi
fi

# ── case 4: tightened reject ─────────────────────────────────────────────────
# Narrow the Net param to a NON-MATCHING prefix: other.com/api.
# The inferred <Net "idp.example.com/api"> is NOT ⊑ <Net "other.com/api">.
# check-policy must REJECT (rc 1).
if [ -f "$NET_FIX" ]; then
  tight_out="$(perl -e 'alarm 90; exec @ARGV' \
      "$NATIVE" check-policy "$NET_FIX" --allow "FFI,Net=other.com/api" --fn transform 2>&1)"
  tight_rc=$?
  if [ "$tight_rc" = "1" ] && printf '%s' "$tight_out" | grep -qF "rejected"; then
    ok_case "tightened-reject (narrowed param → check-policy rc=1)"
  else
    fail_case "tightened-reject" "rc=$tight_rc output: $tight_out"
  fi
fi

# ── case 5: `manifest` refuses what `check` refuses (S-2, #3321) ──────────────
# `medaka manifest` must now load/analyze the target exactly as `medaka check`
# does and refuse — diagnostics on stderr, nothing on stdout, exit 1 — for an
# ill-typed target, an unresolvable import, and a missing `--fn` binding; and
# it must resolve a target that imports a sibling module (previously never
# reached — the old implementation read exactly one file).

assert_refuse() {
  # $1 = case name, $2 = target, $3 = --fn value (may be empty for default)
  name="$1"; target="$2"; fnarg="$3"
  out="$(mktemp)"; err="$(mktemp)"
  if [ -n "$fnarg" ]; then
    "$NATIVE" manifest --fn "$fnarg" "$target" > "$out" 2> "$err"
  else
    "$NATIVE" manifest "$target" > "$out" 2> "$err"
  fi
  rc=$?
  if [ "$rc" = "1" ] && [ ! -s "$out" ] && [ -s "$err" ]; then
    ok_case "$name (exit 1, empty stdout, stderr diagnostics)"
  else
    fail_case "$name" "rc=$rc stdout=$(cat "$out") stderr=$(cat "$err")"
  fi
  rm -f "$out" "$err"
}

# case 1: ill-typed target
assert_refuse "manifest-illtyped" \
  "$ROOT/test/check_policy_fixtures/type_error_plugin.mdk" "transform"

# case 2: unresolvable target (bad import)
assert_refuse "manifest-unresolvable" \
  "$ROOT/test/check_policy_fixtures/manifest_unresolvable_plugin.mdk" ""

# case 3: --fn names no binding at all
assert_refuse "manifest-fn-nosuch" \
  "$ROOT/test/check_policy_fixtures/missing_entry_plugin.mdk" "nosuch"

# case 5: sibling-module import now resolves and the imported effect reaches
# the manifest.
XMOD_FIX="$ROOT/test/check_policy_fixtures/manifest_xmod_main.mdk"
[ -f "$XMOD_FIX" ] || { fail_case "xmod-golden" "missing $XMOD_FIX"; }
if [ -f "$XMOD_FIX" ]; then
  got="$(perl -e 'alarm 90; exec @ARGV' "$NATIVE" manifest "$XMOD_FIX" --fn entry 2>&1)"
  expected='[package.capabilities]
Clock = true'
  if [ "$got" = "$expected" ]; then
    ok_case "xmod-golden (sibling-import target resolves, imported effect reaches the manifest)"
  else
    fail_case "xmod-golden" "expected: $expected; got: $got"
  fi
fi

# ── case 6: surviving inferred-hole marker renders as ⊤ (#3322) ───────────────
# `entry`'s WRITTEN signature carries the inferred-hole marker `_` directly
# (`<Net "_">`), so the atom `atomToToml` sees is `PPrefix (Some "_")`
# unchanged — it must fold to the bare ⊤ grant `Net = true`, not print the
# literal hole string `Net = "_"`.
HOLE_FIX="$ROOT/test/check_policy_fixtures/manifest_hole_plugin.mdk"
[ -f "$HOLE_FIX" ] || { fail_case "hole-golden" "missing $HOLE_FIX"; }

if [ -f "$HOLE_FIX" ]; then
  got="$(perl -e 'alarm 90; exec @ARGV' "$NATIVE" manifest "$HOLE_FIX" --fn entry 2>&1)"
  expected='[package.capabilities]
FFI = true
Net = true'
  if [ "$got" = "$expected" ]; then
    ok_case "hole-golden (surviving inferred-hole atom renders as ⊤)"
  else
    fail_case "hole-golden" "expected: $expected; got: $got"
  fi
fi

echo ""
printf '%d ok, %d failing\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
