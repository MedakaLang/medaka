#!/bin/sh
# Compile-time API boundary gate for #1723. `Fe` and `Sc` contain mutable
# arrays, so opacity is the invariant that prevents callers from corrupting
# shared sentinels or forging non-canonical values. This is intentionally a
# check gate, not a runtime test: the bad programs must be rejected before
# they can execute.
#
# Auto-enrolled in the `sqlite` CI shard by the `pds/test/*` glob.
set -u

ROOT="${MEDAKA_ROOT:?set MEDAKA_ROOT to the repo root}"
MEDAKA="${MEDAKA:-$ROOT/medaka}"
export MEDAKA_ROOT

[ -x "$MEDAKA" ] || { echo "build medaka first (missing $MEDAKA)"; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

# A name ending in `ForTest` is an explicit test-only export.  Derive the
# boundary from source on every run: production modules may not import one
# selectively, acquire one through a wildcard, or alias its exporting module,
# while test drivers must keep at least one explicit route so this policy
# cannot pass vacuously.
extract_test_exports() {
  export_file=$1
  export_module=$2
  awk -v module="$export_module" '
    function trim(s) {
      sub(/^[[:space:]]+/, "", s)
      sub(/[[:space:]]+$/, "", s)
      return s
    }
    function emit_decl(s, name) {
      s = trim(s)
      sub(/^data[[:space:]]+/, "", s)
      name = s
      sub(/[[:space:]:=(].*$/, "", name)
      if (name ~ /ForTest$/) print module "\t" name
    }
    {
      line = $0
      sub(/[[:space:]]*--.*/, "", line)
      line = trim(line)
      if (pending) {
        if (line == "") next
        emit_decl(line)
        pending = 0
        next
      }
      if (line == "export" || line == "public export") {
        pending = 1
        next
      }
      if (line ~ /^(public[[:space:]]+)?export[[:space:]]+/) {
        sub(/^(public[[:space:]]+)?export[[:space:]]+/, "", line)
        emit_decl(line)
      }
    }
  ' "$export_file"
}

parse_imports() {
  import_files=$1
  import_output=$2
  : > "$import_output"
  while IFS= read -r import_file; do
    import_rel=${import_file#"$scan_root"/}
    if ! awk -v consumer="$import_rel" '
      function trim(s) {
        sub(/^[[:space:]]+/, "", s)
        sub(/[[:space:]]+$/, "", s)
        return s
      }
      function brace_delta(s, copy, opens, closes) {
        copy = s
        opens = gsub(/{/, "", copy)
        copy = s
        closes = gsub(/}/, "", copy)
        return opens - closes
      }
      function emit_import(s, marker, module, body, count, i, names, name) {
        s = trim(s)
        sub(/^import[[:space:]]+/, "", s)
        marker = index(s, ".*")
        if (marker > 0) {
          module = trim(substr(s, 1, marker - 1))
          print consumer "\t" module "\t*"
          return
        }
        marker = index(s, ".{")
        if (marker > 0) {
          module = trim(substr(s, 1, marker - 1))
          body = substr(s, marker + 2)
          sub(/}.*/, "", body)
          gsub(/[[:space:]]/, "", body)
          count = split(body, names, ",")
          for (i = 1; i <= count; i++) {
            name = names[i]
            if (name != "") print consumer "\t" module "\t" name
          }
          return
        }
        if (s ~ /[[:space:]]+as[[:space:]]+/) {
          module = s
          sub(/[[:space:]]+as[[:space:]].*$/, "", module)
          print consumer "\t" trim(module) "\t@alias"
        }
      }
      {
        line = $0
        sub(/[[:space:]]*--.*/, "", line)
        if (!collecting) {
          if (line !~ /^[[:space:]]*import[[:space:]]+/) next
          clause = line
          depth = brace_delta(line)
          collecting = 1
        } else {
          clause = clause " " line
          depth += brace_delta(line)
        }
        if (depth <= 0) {
          emit_import(clause)
          clause = ""
          collecting = 0
        }
      }
      END {
        if (collecting) {
          print consumer ": unterminated import clause" > "/dev/stderr"
          exit 2
        }
      }
    ' "$import_file" >> "$import_output"; then
      return 1
    fi
  done < "$import_files"
}

deployment_boundary_ok() {
  scan_root=$1
  modules="$WORK/deployment-modules"
  hooks="$WORK/test-only-exports"
  hooks_sorted="$WORK/test-only-exports.sorted"
  production_imports="$WORK/production-imports"
  test_files="$WORK/test-modules"
  test_imports="$WORK/test-imports"

  find "$scan_root/pds/lib" -type f -name '*.mdk' -print | LC_ALL=C sort > "$modules"
  if [ ! -s "$modules" ]; then
    echo "FAIL: deployment boundary found zero production modules"
    return 1
  fi

  : > "$hooks"
  while IFS= read -r module_file; do
    module_rel=${module_file#"$scan_root"/pds/}
    module_name=${module_rel%.mdk}
    module_name=$(printf '%s' "$module_name" | tr '/' '.')
    extract_test_exports "$module_file" "$module_name" >> "$hooks"
  done < "$modules"
  LC_ALL=C sort -u "$hooks" > "$hooks_sorted"
  if [ ! -s "$hooks_sorted" ]; then
    echo "FAIL: deployment boundary found zero exported test-only APIs"
    return 1
  fi

  if ! parse_imports "$modules" "$production_imports"; then
    echo "FAIL: deployment boundary could not parse production imports"
    return 1
  fi
  if ! awk -F '\t' '
    NR == FNR {
      hook[$1 SUBSEP $2] = 1
      hook_module[$1] = 1
      next
    }
    $3 == "*" && ($2 in hook_module) {
      print $1 " imports test-only API wildcard from " $2
      exit 1
    }
    $3 == "@alias" && ($2 in hook_module) {
      print $1 " imports module with test-only APIs through alias from " $2
      exit 1
    }
    (($2 SUBSEP $3) in hook) {
      print $1 " imports test-only API " $3
      exit 1
    }
  ' "$hooks_sorted" "$production_imports"; then
    return 1
  fi

  find "$scan_root/pds/test" -type f -name '*.mdk' -print | LC_ALL=C sort > "$test_files"
  if ! parse_imports "$test_files" "$test_imports"; then
    echo "FAIL: deployment boundary could not parse test imports"
    return 1
  fi

  module_count=$(wc -l < "$modules" | tr -d '[:space:]')
  hook_count=$(wc -l < "$hooks_sorted" | tr -d '[:space:]')
  echo "PASS: deployment module census — $module_count production modules, $hook_count exported test-only APIs"
  if ! awk -F '\t' '
    NR == FNR {
      hook[$1 SUBSEP $2] = 1
      hook_module[$1] = 1
      next
    }
    $3 == "*" && ($2 in hook_module) {
      edge = $1 SUBSEP $2 SUBSEP "*"
      if (!(edge in seen)) {
        seen[edge] = 1
        count++
        print "PASS: observed allowed test wildcard consumer " $1 " -> " $2
      }
      next
    }
    $3 == "@alias" && ($2 in hook_module) {
      edge = $1 SUBSEP $2 SUBSEP "@alias"
      if (!(edge in seen)) {
        seen[edge] = 1
        count++
        print "PASS: observed allowed test module alias consumer " $1 " -> " $2
      }
      next
    }
    (($2 SUBSEP $3) in hook) {
      edge = $1 SUBSEP $2 SUBSEP $3
      if (!(edge in seen)) {
        seen[edge] = 1
        count++
        print "PASS: observed allowed test-only API consumer " $1 " -> " $2 "." $3
      }
    }
    END {
      if (count == 0) {
        print "FAIL: deployment boundary found zero test-only API consumers"
        exit 1
      }
      print "PASS: test-only API consumer census — " count " import edges"
    }
  ' "$hooks_sorted" "$test_imports"; then
    return 1
  fi
}

if ! deployment_boundary_ok "$ROOT"; then
  exit 1
fi

# The policy must accept aliases of modules without test-only exports and
# reject all three forbidden import forms directly, before compilation. Run
# the probes in a disposable project copy so an interruption cannot dirty the
# source checkout, then restore and compare the only mutated file byte-for-byte.
MUTATION_ROOT="$WORK/mutation-root"
mkdir -p "$MUTATION_ROOT/pds"
cp -R "$ROOT/pds/lib" "$MUTATION_ROOT/pds/lib"
cp -R "$ROOT/pds/test" "$MUTATION_ROOT/pds/test"
SIGN_MUTANT="$MUTATION_ROOT/pds/lib/sign.mdk"
SIGN_BASELINE="$WORK/sign.mdk.baseline"
cp "$SIGN_MUTANT" "$SIGN_BASELINE"

{
  printf '%s\n' 'import array as SafeArray'
  cat "$SIGN_BASELINE"
} > "$SIGN_MUTANT"
if ! deployment_boundary_ok "$MUTATION_ROOT" > "$WORK/safe-alias-control.out" 2>&1; then
  echo "FAIL: ordinary module alias control failed deployment policy"
  cat "$WORK/safe-alias-control.out"
  exit 1
fi
echo "PASS: ordinary module alias without test-only exports accepted"

cp "$SIGN_BASELINE" "$SIGN_MUTANT"
{
  printf '%s\n' 'import lib.secp256k1.{ecdsaSignDigestForTest}'
  cat "$SIGN_BASELINE"
} > "$SIGN_MUTANT"
if deployment_boundary_ok "$MUTATION_ROOT" > "$WORK/selective-mutation.out" 2>&1; then
  echo "FAIL: selective test-only import mutation passed deployment policy"
  cat "$WORK/selective-mutation.out"
  exit 1
fi
if ! grep -F -x -q 'pds/lib/sign.mdk imports test-only API ecdsaSignDigestForTest' "$WORK/selective-mutation.out"; then
  echo "FAIL: selective import mutation failed for an unexpected reason"
  cat "$WORK/selective-mutation.out"
  exit 1
fi
printf '%s' "PASS: selective test-only import mutation rejected directly — "
cat "$WORK/selective-mutation.out"

cp "$SIGN_BASELINE" "$SIGN_MUTANT"
{
  printf '%s\n' 'import lib.secp256k1.*'
  cat "$SIGN_BASELINE"
} > "$SIGN_MUTANT"
if deployment_boundary_ok "$MUTATION_ROOT" > "$WORK/wildcard-mutation.out" 2>&1; then
  echo "FAIL: wildcard test-only import mutation passed deployment policy"
  cat "$WORK/wildcard-mutation.out"
  exit 1
fi
if ! grep -F -x -q 'pds/lib/sign.mdk imports test-only API wildcard from lib.secp256k1' "$WORK/wildcard-mutation.out"; then
  echo "FAIL: wildcard import mutation failed for an unexpected reason"
  cat "$WORK/wildcard-mutation.out"
  exit 1
fi
printf '%s' "PASS: wildcard test-only import mutation rejected directly — "
cat "$WORK/wildcard-mutation.out"

cp "$SIGN_BASELINE" "$SIGN_MUTANT"
{
  printf '%s\n' 'import lib.secp256k1 as Internal'
  cat "$SIGN_BASELINE"
} > "$SIGN_MUTANT"
if deployment_boundary_ok "$MUTATION_ROOT" > "$WORK/alias-mutation.out" 2>&1; then
  echo "FAIL: aliased test-only module import mutation passed deployment policy"
  cat "$WORK/alias-mutation.out"
  exit 1
fi
if ! grep -F -x -q 'pds/lib/sign.mdk imports module with test-only APIs through alias from lib.secp256k1' "$WORK/alias-mutation.out"; then
  echo "FAIL: aliased module import mutation failed for an unexpected reason"
  cat "$WORK/alias-mutation.out"
  exit 1
fi
printf '%s' "PASS: aliased test-only module import mutation rejected directly — "
cat "$WORK/alias-mutation.out"

cp "$SIGN_BASELINE" "$SIGN_MUTANT"
if ! cmp -s "$SIGN_BASELINE" "$SIGN_MUTANT"; then
  echo "FAIL: disposable deployment mutation did not restore sign.mdk"
  exit 1
fi
echo "PASS: disposable deployment mutations restored sign.mdk byte-exactly; source tree untouched"

# These are distinct permanent attack cells: two exact `Array.set` sentinel
# mutations, two raw-array forgeries, and three constructor-import probes. Keep
# this floor in sync with the lists.
FAIL_FLOOR=7
PASS_FLOOR=2
TYPE_MISMATCH_CELLS="
pds/test/opaque_field_sentinel_attack.mdk
pds/test/opaque_scalar_sentinel_attack.mdk
pds/test/opaque_field_raw_forgery.mdk
pds/test/opaque_scalar_raw_forgery.mdk
"
ABSTRACT_EXPORT_CELLS="
pds/test/opaque_field_constructor_import.mdk
pds/test/opaque_scalar_constructor_import.mdk
pds/test/opaque_signature_constructor_import.mdk
"
PASS_CELLS="
pds/test/opaque_field_scalar_control.mdk
pds/test/opaque_signature_control.mdk
"

fail_ran=0
for rel in $TYPE_MISMATCH_CELLS; do
  path="$ROOT/$rel"
  out="$WORK/fail-$fail_ran.out"
  if [ ! -f "$path" ]; then
    echo "FAIL: missing required opacity attack cell $rel"
    exit 1
  fi
  if "$MEDAKA" check "$path" >"$out" 2>&1; then
    echo "FAIL: $rel checked successfully; the opaque API attack is reachable"
    cat "$out"
    exit 1
  fi
  if ! grep -q 'Type mismatch' "$out"; then
    echo "FAIL: $rel failed for an unexpected reason, not the opaque type boundary"
    cat "$out"
    exit 1
  fi
  fail_ran=$((fail_ran + 1))
  echo "PASS: rejected opacity attack $rel"
done

# These cells must fail at import resolution, rather than with the expression
# type mismatch above. They pin `export data`'s abstract constructor boundary:
# changing either declaration to `public export data` would make its cell
# resolve and then successfully unwrap/mutate or construct the representation.
for rel in $ABSTRACT_EXPORT_CELLS; do
  path="$ROOT/$rel"
  out="$WORK/abstract-$fail_ran.out"
  if [ ! -f "$path" ]; then
    echo "FAIL: missing required abstract-export attack cell $rel"
    exit 1
  fi
  if "$MEDAKA" check "$path" >"$out" 2>&1; then
    echo "FAIL: $rel checked successfully; private constructors are exported"
    cat "$out"
    exit 1
  fi
  if ! grep -q 'exports no constructors' "$out" || ! grep -q 'exported abstractly' "$out"; then
    echo "FAIL: $rel failed for an unexpected reason, not abstract constructor export"
    cat "$out"
    exit 1
  fi
  fail_ran=$((fail_ran + 1))
  echo "PASS: rejected abstract constructor import $rel"
done

pass_ran=0
for rel in $PASS_CELLS; do
  path="$ROOT/$rel"
  out="$WORK/pass-$pass_ran.out"
  if [ ! -f "$path" ]; then
    echo "FAIL: missing required opacity control $rel"
    exit 1
  fi
  if ! "$MEDAKA" check "$path" >"$out" 2>&1; then
    echo "FAIL: public opaque API control did not check: $rel"
    cat "$out"
    exit 1
  fi
  pass_ran=$((pass_ran + 1))
  echo "PASS: checked opacity control $rel"
done

if [ "$fail_ran" -lt "$FAIL_FLOOR" ]; then
  echo "FAIL: only $fail_ran opacity attack cells ran, expected >= $FAIL_FLOOR"
  exit 1
fi
if [ "$pass_ran" -lt "$PASS_FLOOR" ]; then
  echo "FAIL: only $pass_ran opacity control cells ran, expected >= $PASS_FLOOR"
  exit 1
fi

echo "PASS: field/scalar/signature opacity — $fail_ran rejected attack cells, $pass_ran public control cells"
