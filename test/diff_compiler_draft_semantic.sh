#!/bin/sh
# X-0D (#1399): the additive DraftSemanticProgram must transport every current
# semantic emitter input without becoming a physical-backend input. The golden
# pins populations/provenance; the mutation arm proves a copied-field mismatch is
# observable rather than blessing a comparator that can only say MATCH.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SELF="$ROOT/test/bin/draft_semantic_main"
RT="$ROOT/stdlib/runtime.mdk"
CORE="$ROOT/stdlib/core.mdk"
FIXDIR="$ROOT/test/draft_semantic_fixtures"

if [ ! -x "$SELF" ]; then
  echo "FAIL: missing probe $SELF"
  echo "      build it with: FORCE=1 JOBS=1 sh test/build_oracles.sh --build-one draft_semantic_main"
  exit 1
fi

pass=0
fail=0
fixtures=0

for dir in "$FIXDIR"/*/; do
  [ -d "$dir" ] || continue
  entry=""
  entry_count=0
  for candidate in "$dir"main_*.mdk; do
    [ -f "$candidate" ] || continue
    entry="$candidate"
    entry_count=$((entry_count + 1))
  done
  if [ "$entry_count" -ne 1 ]; then
    echo "FAIL: $(basename "$dir") has $entry_count main_*.mdk entries; expected exactly one"
    fail=$((fail + 1))
    continue
  fi
  fixtures=$((fixtures + 1))
  name="$(basename "$dir")"
  golden="${dir%/}/draft.golden"
  out="$($SELF "$RT" "$CORE" "$entry" "${dir%/}" 2>&1)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "FAIL $name (probe exited $rc)"
    printf '%s\n' "$out" | sed 's/^/  /'
    fail=$((fail + 1))
    continue
  fi

  if ! printf '%s\n' "$out" | grep -q '(different 0)'; then
    echo "FAIL $name: baseline draft has a transport mismatch (or no summary)"
    printf '%s\n' "$out" | sed 's/^/  /'
    fail=$((fail + 1))
    continue
  fi

  mutation="${DRAFT_MUTATION:-method-iface}"
  bad="$(MEDAKA_DRAFT_MUTATION="$mutation" "$SELF" "$RT" "$CORE" "$entry" "${dir%/}" 2>&1)"
  bad_rc=$?
  if [ "$bad_rc" -ne 0 ]; then
    echo "FAIL $name: malformed-field control exited $bad_rc instead of producing a receipt"
    printf '%s\n' "$bad" | sed 's/^/  /'
    fail=$((fail + 1))
    continue
  fi
  if ! printf '%s\n' "$bad" | grep -q '(receipt method-iface methodIfaceTable elaborated-graph DIFFERENT)'; then
    echo "FAIL $name: malformed method-iface field was not detected"
    fail=$((fail + 1))
    continue
  fi
  if ! printf '%s\n' "$bad" | grep -q '(different 1)'; then
    echo "FAIL $name: malformed-field summary did not report exactly one mismatch"
    fail=$((fail + 1))
    continue
  fi

  bad_provenance="$(MEDAKA_DRAFT_MUTATION=method-iface-provenance "$SELF" "$RT" "$CORE" "$entry" "${dir%/}" 2>&1)"
  provenance_rc=$?
  if [ "$provenance_rc" -ne 0 ]; then
    echo "FAIL $name: provenance control exited $provenance_rc"
    fail=$((fail + 1))
    continue
  fi
  if ! printf '%s\n' "$bad_provenance" | grep -q '(receipt method-iface methodIfaceTable elaborated-graph DIFFERENT)'; then
    echo "FAIL $name: wrong method-iface provenance was not detected"
    fail=$((fail + 1))
    continue
  fi
  if ! printf '%s\n' "$bad_provenance" | grep -q '(different 1)'; then
    echo "FAIL $name: provenance control did not report exactly one mismatch"
    fail=$((fail + 1))
    continue
  fi

  control="$(MEDAKA_DRAFT_MUTATION=unrelated-control "$SELF" "$RT" "$CORE" "$entry" "${dir%/}" 2>&1)"
  control_rc=$?
  if [ "$control_rc" -ne 0 ]; then
    echo "FAIL $name: unrelated positive control exited $control_rc"
    fail=$((fail + 1))
    continue
  fi
  if ! printf '%s\n' "$control" | grep -q '(receipt module-emitter-projection elaborateModules elaborated-modules DIFFERENT)'; then
    echo "FAIL $name: P+U positive control did not change the module projection"
    fail=$((fail + 1))
    continue
  fi
  if printf '%s\n' "$control" | grep -q '(different 0)'; then
    echo "FAIL $name: P+U positive control could not observe its unrelated module"
    fail=$((fail + 1))
    continue
  fi

  isolated="$(MEDAKA_DRAFT_MUTATION=same-process "$SELF" "$RT" "$CORE" "$entry" "${dir%/}" 2>&1)"
  isolated_rc=$?
  if [ "$isolated_rc" -ne 0 ]; then
    echo "FAIL $name: P -> P+U -> P control exited $isolated_rc"
    fail=$((fail + 1))
    continue
  fi
  if [ "$isolated" != "$out" ]; then
    echo "FAIL $name: P changed after constructing unrelated P+U in the same process"
    fail=$((fail + 1))
    continue
  fi

  if [ "${CAPTURE:-0}" = "1" ]; then
    printf '%s\n' "$out" > "$golden"
    echo "blessed $name"
    pass=$((pass + 1))
  elif [ ! -f "$golden" ]; then
    echo "FAIL $name: no golden at $golden"
    fail=$((fail + 1))
  elif printf '%s\n' "$out" | diff -u "$golden" - > /dev/null 2>&1; then
    echo "ok   $name"
    pass=$((pass + 1))
  else
    echo "FAIL $name: draft schema/provenance/receipt output moved"
    printf '%s\n' "$out" | diff -u "$golden" - | sed 's/^/  /'
    fail=$((fail + 1))
  fi
done

if [ "$fixtures" -eq 0 ]; then
  echo "FAIL: no fixtures under $FIXDIR; this gate checked nothing"
  exit 1
fi

printf '\n%d ok, %d failing (%d fixture(s))\n' "$pass" "$fail" "$fixtures"
[ "$fail" -eq 0 ]
