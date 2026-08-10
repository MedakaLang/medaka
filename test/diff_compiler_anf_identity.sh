#!/bin/sh
# X-A (#1400): StableNodeId is validated before its serializer can receive it.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SELF="$ROOT/test/bin/anf_identity_main"
GOLDEN="$ROOT/test/anf_identity.golden"

if [ ! -x "$SELF" ]; then
  echo "FAIL: missing probe $SELF"
  echo "      build it with: FORCE=1 JOBS=1 sh test/build_oracles.sh --build-one anf_identity_main"
  exit 1
fi

out="$("$SELF" 2>&1)"
rc=$?
if [ "$rc" -ne 0 ]; then
  echo "FAIL: canonical StableNodeId probe exited $rc"
  exit 1
fi

if [ "${CAPTURE:-0}" = "1" ]; then
  printf '%s\n' "$out" > "$GOLDEN"
  echo "blessed anf identity"
elif printf '%s\n' "$out" | diff -u "$GOLDEN" - > /dev/null 2>&1; then
  echo "ok   canonical stable node IDs"
else
  echo "FAIL: canonical StableNodeId serialization moved"
  printf '%s\n' "$out" | diff -u "$GOLDEN" -
  exit 1
fi

for case in absolute parent interior-parent alias span line-zero child empty-path; do
  expected=""
  case "$case" in
    absolute) expected="absolute-project-path" ;;
    parent) expected="parent-project-path" ;;
    interior-parent) expected="noncanonical-project-path" ;;
    alias) expected="noncanonical-project-path" ;;
    span) expected="invalid-source-span" ;;
    line-zero) expected="invalid-source-span" ;;
    child) expected="negative-structural-index" ;;
    empty-path) expected="empty-project-path" ;;
  esac
  bad="$(MEDAKA_ANF_IDENTITY_MUTATION="$case" "$SELF" 2>&1)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "FAIL: $case malformed-node control exited $rc"
    exit 1
  fi
  if ! printf '%s\n' "$bad" | grep -q "^[(]stable-node-id-error $expected[)]$"; then
    echo "FAIL: $case malformed-node control did not reject with $expected before serialization"
    exit 1
  fi
done

printf '\n1 ok, 0 failing (StableNodeId validation and serialization)\n'
