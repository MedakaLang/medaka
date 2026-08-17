#!/bin/sh
# pds/test/vector_provenance.sh — G5 provenance ledger gate (S-vector-ledger, #1706).
#
# Enumerates every regular file under pds/test/ (excluding *.sh, *.mdk, and the
# ledger itself — see pds/test/VECTOR-PROVENANCE.txt's own header for the full
# rule), cross-checks it against a [vector] stanza in that ledger, and verifies
# the recorded local-sha256 against the file's CURRENT bytes.
#
# NO NETWORK. This gate never fetches source-url and never verifies
# source-sha256 — see the ledger's own DOES-NOT-PROVE block.
#
# This gate runs its own SELF-TEST first, on six synthetic fixtures built in a
# mktemp -d outside the tree, before it ever looks at the real tree: the real
# corpus is empty at the time this slice lands (no consumer slice has landed
# yet), so without the self-test every CI run of this gate would be vacuously
# green. If the self-test fails, the real check does not run — a broken
# checker's verdict on the real tree is worthless.
#
# The landed CI shard glob is 'pds/test/*' (S-pds-skeleton, #1705; confirmed at
# Step-0 of this slice) — no `_oracle` suffix on this filename; the naming
# uncertainty in earlier drafts of this slice's packet is resolved before this
# file was created, so no hedge is needed and this gate diffs against no
# external oracle (it has none to diff against).
set -u

ROOT="${MEDAKA_ROOT:?set MEDAKA_ROOT to the repo root}"

# ── sha256_of_file ────────────────────────────────────────────────────────────
sha256_of_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d ' ' -f 1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | cut -d ' ' -f 1
  else
    echo "vector_provenance: need sha256sum or shasum, neither found" >&2
    exit 2
  fi
}

# ── check_corpus <root> ───────────────────────────────────────────────────────
# The whole checker, parameterized on ONE argument (the repo root to check —
# either $ROOT for the real run, or a synthetic mktemp root in self_test — same
# code path both times, so the self-test proves something about the real run).
# Scans <root>/pds/test, reads <root>/pds/test/VECTOR-PROVENANCE.txt, resolves
# every file: value against <root>. Prints findings, returns 0/1.
check_corpus() {
  cr_root="$1"
  cr_testdir="$cr_root/pds/test"
  cr_ledger="$cr_testdir/VECTOR-PROVENANCE.txt"
  cr_scratch="$(mktemp -d "${TMPDIR:-/tmp}/pds-vp-check.XXXXXX")"

  if [ ! -d "$cr_testdir" ] || [ ! -f "$cr_ledger" ]; then
    echo "check_corpus: pds/test/ or its ledger missing under $cr_root"
    rm -rf "$cr_scratch"
    return 1
  fi

  find "$cr_testdir" -type f \
    ! -name '*.sh' \
    ! -name '*.mdk' \
    ! -path "$cr_ledger" \
    | LC_ALL=C sort > "$cr_scratch/files.lst"

  : > "$cr_scratch/hashes.lst"
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    rel="${f#"$cr_root"/}"
    h="$(sha256_of_file "$f")"
    printf '%s\t%s\n' "$rel" "$h" >> "$cr_scratch/hashes.lst"
  done < "$cr_scratch/files.lst"

  cr_out="$(awk -v ROOT="$cr_root" -v HASHES="$cr_scratch/hashes.lst" '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }

    BEGIN {
      fail = 0
      n_impl = 0
      n_vec = 0
      n_hashed = 0
      while ((getline hline < HASHES) > 0) {
        split(hline, hf, "\t")
        fhash[hf[1]] = hf[2]
        n_hashed++
      }
      close(HASHES)

      ledger = ARGV[1]
      cur_type = ""
      cur_idx = 0
      lineno = 0
      while ((getline raw < ledger) > 0) {
        lineno++
        line = raw
        t = trim(line)
        if (t == "" || substr(t, 1, 1) == "#") continue
        if (t ~ /^\[[A-Za-z]+\]$/) {
          htype = substr(t, 2, length(t) - 2)
          if (htype != "impl" && htype != "vector") {
            print "FAIL: line " lineno ": unknown stanza header [" htype "]"
            fail = 1
            cur_type = ""
            continue
          }
          cur_type = htype
          if (htype == "impl") {
            n_impl++
            cur_idx = n_impl
            impl_line[cur_idx] = lineno
          } else {
            n_vec++
            cur_idx = n_vec
            vec_line[cur_idx] = lineno
          }
          continue
        }
        if (cur_type == "") continue
        colon = index(line, ":")
        if (colon == 0) {
          print "FAIL: line " lineno ": malformed line (no key: value): " line
          fail = 1
          continue
        }
        key = trim(substr(line, 1, colon - 1))
        val = trim(substr(line, colon + 1))
        if (cur_type == "impl") {
          impl_val[cur_idx, key] = val
          impl_haskey[cur_idx, key] = 1
        } else {
          vec_val[cur_idx, key] = val
          vec_haskey[cur_idx, key] = 1
        }
      }
      close(ledger)

      impl_req_n = split("id repo version commit retrieved", impl_req, " ")
      impl_known_n = split("id repo version commit retrieved notes", impl_known, " ")
      for (i = 1; i <= n_impl; i++) {
        for (k = 1; k <= impl_req_n; k++) {
          rk = impl_req[k]
          if (!((i, rk) in impl_haskey) || impl_val[i, rk] == "") {
            print "FAIL: [impl] stanza at line " impl_line[i] ": missing required key \"" rk "\""
            fail = 1
          }
        }
        for (pair in impl_haskey) {
          split(pair, pk, SUBSEP)
          if (pk[1] != i) continue
          kk = pk[2]
          known = 0
          for (k = 1; k <= impl_known_n; k++) if (impl_known[k] == kk) known = 1
          if (!known) {
            print "FAIL: [impl] stanza at line " impl_line[i] ": unknown key \"" kk "\""
            fail = 1
          }
        }
        id = impl_val[i, "id"]
        if (id != "") {
          if (id in impl_id_first) {
            first = impl_id_first[id]
            if (impl_val[first, "commit"] != impl_val[i, "commit"]) {
              print "FAIL: CONFLICTING PIN: [impl] id \"" id "\" pinned to different commits at line " impl_line[first] " (" impl_val[first, "commit"] ") and line " impl_line[i] " (" impl_val[i, "commit"] ")"
              fail = 1
            }
          } else {
            impl_id_first[id] = i
          }
        }
        c = impl_val[i, "commit"]
        if (c != "" && c !~ /^[0-9a-f]{40}$/) {
          print "FAIL: [impl] stanza at line " impl_line[i] ": commit is not 40 lowercase hex: \"" c "\""
          fail = 1
        }
        r = impl_val[i, "retrieved"]
        if (r != "" && r !~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/) {
          print "FAIL: [impl] stanza at line " impl_line[i] ": retrieved is not YYYY-MM-DD: \"" r "\""
          fail = 1
        }
      }

      vec_common_n = split("file local-sha256 kind source-url extraction retrieved consumer", vec_common, " ")
      vec_known_n = split("file local-sha256 kind source-url extraction retrieved consumer source source-sha256 source-note impl notes", vec_known, " ")
      for (i = 1; i <= n_vec; i++) {
        for (k = 1; k <= vec_common_n; k++) {
          rk = vec_common[k]
          if (!((i, rk) in vec_haskey) || vec_val[i, rk] == "") {
            print "FAIL: [vector] stanza at line " vec_line[i] ": missing required key \"" rk "\""
            fail = 1
          }
        }
        for (pair in vec_haskey) {
          split(pair, pk, SUBSEP)
          if (pk[1] != i) continue
          kk = pk[2]
          known = 0
          for (k = 1; k <= vec_known_n; k++) if (vec_known[k] == kk) known = 1
          if (!known) {
            print "FAIL: [vector] stanza at line " vec_line[i] ": unknown key \"" kk "\""
            fail = 1
          }
        }

        kind = vec_val[i, "kind"]
        file = vec_val[i, "file"]
        if (kind != "published-artifact" && kind != "reference-impl") {
          print "FAIL: [vector] stanza at line " vec_line[i] ": unknown kind \"" kind "\" (must be published-artifact or reference-impl)"
          fail = 1
        }
        if (kind == "published-artifact") {
          if (!((i, "source") in vec_haskey) || vec_val[i, "source"] == "") {
            print "FAIL: [vector] stanza at line " vec_line[i] ": kind=published-artifact requires \"source\""
            fail = 1
          }
          if (!((i, "source-sha256") in vec_haskey) || vec_val[i, "source-sha256"] == "") {
            print "FAIL: [vector] stanza at line " vec_line[i] ": kind=published-artifact requires \"source-sha256\""
            fail = 1
          } else if (vec_val[i, "source-sha256"] == "UNAVAILABLE") {
            if (!((i, "source-note") in vec_haskey) || vec_val[i, "source-note"] == "") {
              print "FAIL: [vector] stanza at line " vec_line[i] ": source-sha256=UNAVAILABLE requires \"source-note\""
              fail = 1
            }
          } else if (vec_val[i, "source-sha256"] !~ /^[0-9a-f]{64}$/) {
            print "FAIL: [vector] stanza at line " vec_line[i] ": source-sha256 is not 64 lowercase hex and not UNAVAILABLE: \"" vec_val[i, "source-sha256"] "\""
            fail = 1
          }
        }
        if (kind == "reference-impl") {
          impl_id = vec_val[i, "impl"]
          if (!((i, "impl") in vec_haskey) || impl_id == "") {
            print "FAIL: [vector] stanza at line " vec_line[i] ": kind=reference-impl requires \"impl\""
            fail = 1
          } else if (!(impl_id in impl_id_first)) {
            print "FAIL: UNPINNED IMPL: [vector] stanza at line " vec_line[i] " names impl \"" impl_id "\" but no [impl] stanza defines it"
            fail = 1
          }
        }

        ls = vec_val[i, "local-sha256"]
        if (ls != "" && ls !~ /^[0-9a-f]{64}$/) {
          print "FAIL: [vector] stanza at line " vec_line[i] ": local-sha256 is not 64 lowercase hex: \"" ls "\""
          fail = 1
        }
        r = vec_val[i, "retrieved"]
        if (r != "" && r !~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/) {
          print "FAIL: [vector] stanza at line " vec_line[i] ": retrieved is not YYYY-MM-DD: \"" r "\""
          fail = 1
        }

        if (file != "") {
          if (file in vec_file_first) {
            print "FAIL: duplicate row: [vector] stanzas at line " vec_line[vec_file_first[file]] " and line " vec_line[i] " both name file \"" file "\""
            fail = 1
          } else {
            vec_file_first[file] = i
          }
          if (file in fhash) {
            actual = fhash[file]
            if (ls != "" && ls != actual) {
              print "FAIL: DIGEST MISMATCH: [vector] stanza at line " vec_line[i] " file \"" file "\": expected local-sha256=" ls " actual=" actual
              fail = 1
            }
          } else {
            print "FAIL: ORPHAN ROW: [vector] stanza at line " vec_line[i] " names file \"" file "\" which does not exist (or is excluded, e.g. .sh/.mdk)"
            fail = 1
          }
        }
      }

      for (rf in fhash) {
        if (!(rf in vec_file_first)) {
          print "FAIL: MISSING ROW: file \"" rf "\" has no [vector] stanza"
          fail = 1
        }
      }

      print "vectors: " n_hashed " files, " n_vec " rows"
      if (n_hashed == 0) {
        print "NOTE: the corpus is EMPTY - no vector file exists under pds/test/ yet. This run'"'"'s only fail-capable evidence is the self-test."
      }

      print "RESULT " (fail ? 1 : 0)
    }
  ' "$cr_ledger")"

  echo "$cr_out"
  rm -rf "$cr_scratch"

  case "$cr_out" in
    *"RESULT 0") return 0 ;;
    *) return 1 ;;
  esac
}

# ── self_test ─────────────────────────────────────────────────────────────────
self_test() {
  st_rc=0

  mk_vector() {
    # mk_vector <root> <relfile> <content>
    _r="$1"; _f="$2"; _c="$3"
    mkdir -p "$(dirname "$_r/$_f")"
    printf '%s' "$_c" > "$_r/$_f"
  }

  # T1 — one vector file, no stanza
  t1="$(mktemp -d "${TMPDIR:-/tmp}/pds-vp-t1.XXXXXX")"
  mkdir -p "$t1/pds/test"
  : > "$t1/pds/test/VECTOR-PROVENANCE.txt"
  mk_vector "$t1" "pds/test/lonely.txt" "hello t1"
  t1_out="$(check_corpus "$t1")"; t1_rc=$?
  rm -rf "$t1"
  if [ "$t1_rc" -eq 1 ] && printf '%s' "$t1_out" | grep -q "MISSING ROW.*pds/test/lonely.txt"; then
    echo "T1 missing row: PASS"
  else
    echo "T1 missing row: FAIL (rc=$t1_rc)"
    printf '%s\n' "$t1_out"
    st_rc=1
  fi

  # T2 — stanza present, file's bytes changed after the row was written
  t2="$(mktemp -d "${TMPDIR:-/tmp}/pds-vp-t2.XXXXXX")"
  mkdir -p "$t2/pds/test"
  mk_vector "$t2" "pds/test/drift.txt" "original bytes"
  orig_hash="$(sha256_of_file "$t2/pds/test/drift.txt")"
  cat > "$t2/pds/test/VECTOR-PROVENANCE.txt" << EOF
[vector]
file: pds/test/drift.txt
local-sha256: $orig_hash
kind: published-artifact
source: Test Fixture
source-url: https://example.invalid/t2
source-sha256: UNAVAILABLE
source-note: synthetic self-test fixture, no real artifact
extraction: hand-written for self-test T2
retrieved: 2026-08-17
consumer: self-test T2
EOF
  # now drift the file's bytes after the row was written
  mk_vector "$t2" "pds/test/drift.txt" "changed bytes after row written"
  actual_hash="$(sha256_of_file "$t2/pds/test/drift.txt")"
  t2_out="$(check_corpus "$t2")"; t2_rc=$?
  rm -rf "$t2"
  if [ "$t2_rc" -eq 1 ] && printf '%s' "$t2_out" | grep -q "DIGEST MISMATCH" \
     && printf '%s' "$t2_out" | grep -q "$orig_hash" \
     && printf '%s' "$t2_out" | grep -q "$actual_hash"; then
    echo "T2 digest mismatch: PASS"
  else
    echo "T2 digest mismatch: FAIL (rc=$t2_rc)"
    printf '%s\n' "$t2_out"
    st_rc=1
  fi

  # T3 — correct stanza (published-artifact), PLUS a reference-impl row whose
  # [impl] stanza IS present, in the SAME green fixture (both kinds exercised).
  t3="$(mktemp -d "${TMPDIR:-/tmp}/pds-vp-t3.XXXXXX")"
  mkdir -p "$t3/pds/test"
  mk_vector "$t3" "pds/test/good_pub.txt" "published artifact content t3"
  mk_vector "$t3" "pds/test/good_ref.txt" "reference impl content t3"
  pub_hash="$(sha256_of_file "$t3/pds/test/good_pub.txt")"
  ref_hash="$(sha256_of_file "$t3/pds/test/good_ref.txt")"
  cat > "$t3/pds/test/VECTOR-PROVENANCE.txt" << EOF
[impl]
id: fakeimpl
repo: https://example.invalid/fakeimpl
version: v9.9.9
commit: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
retrieved: 2026-08-17
notes: synthetic self-test impl

[vector]
file: pds/test/good_pub.txt
local-sha256: $pub_hash
kind: published-artifact
source: Test Fixture Pub
source-url: https://example.invalid/t3-pub
source-sha256: UNAVAILABLE
source-note: synthetic self-test fixture, no real artifact
extraction: hand-written for self-test T3
retrieved: 2026-08-17
consumer: self-test T3

[vector]
file: pds/test/good_ref.txt
local-sha256: $ref_hash
kind: reference-impl
impl: fakeimpl
source-url: https://example.invalid/t3-ref
extraction: hand-written for self-test T3
retrieved: 2026-08-17
consumer: self-test T3
EOF
  t3_out="$(check_corpus "$t3")"; t3_rc=$?
  rm -rf "$t3"
  if [ "$t3_rc" -eq 0 ] && printf '%s' "$t3_out" | grep -q "vectors: 2 files, 2 rows"; then
    echo "T3 correct (both kinds): PASS"
  else
    echo "T3 correct (both kinds): FAIL (rc=$t3_rc)"
    printf '%s\n' "$t3_out"
    st_rc=1
  fi

  # T4 — stanza whose file: does not exist
  t4="$(mktemp -d "${TMPDIR:-/tmp}/pds-vp-t4.XXXXXX")"
  mkdir -p "$t4/pds/test"
  cat > "$t4/pds/test/VECTOR-PROVENANCE.txt" << EOF
[vector]
file: pds/test/ghost.txt
local-sha256: 0000000000000000000000000000000000000000000000000000000000000000
kind: published-artifact
source: Test Fixture Ghost
source-url: https://example.invalid/t4
source-sha256: UNAVAILABLE
source-note: synthetic self-test fixture, no real artifact
extraction: hand-written for self-test T4
retrieved: 2026-08-17
consumer: self-test T4
EOF
  t4_out="$(check_corpus "$t4")"; t4_rc=$?
  rm -rf "$t4"
  if [ "$t4_rc" -eq 1 ] && printf '%s' "$t4_out" | grep -q "ORPHAN ROW.*pds/test/ghost.txt"; then
    echo "T4 orphan row: PASS"
  else
    echo "T4 orphan row: FAIL (rc=$t4_rc)"
    printf '%s\n' "$t4_out"
    st_rc=1
  fi

  # T5 — reference-impl row naming an impl: with no [impl] stanza
  t5="$(mktemp -d "${TMPDIR:-/tmp}/pds-vp-t5.XXXXXX")"
  mkdir -p "$t5/pds/test"
  mk_vector "$t5" "pds/test/unpinned.txt" "unpinned impl content t5"
  up_hash="$(sha256_of_file "$t5/pds/test/unpinned.txt")"
  cat > "$t5/pds/test/VECTOR-PROVENANCE.txt" << EOF
[vector]
file: pds/test/unpinned.txt
local-sha256: $up_hash
kind: reference-impl
impl: nosuchimpl
source-url: https://example.invalid/t5
extraction: hand-written for self-test T5
retrieved: 2026-08-17
consumer: self-test T5
EOF
  t5_out="$(check_corpus "$t5")"; t5_rc=$?
  rm -rf "$t5"
  if [ "$t5_rc" -eq 1 ] && printf '%s' "$t5_out" | grep -q "UNPINNED IMPL.*nosuchimpl"; then
    echo "T5 unpinned impl: PASS"
  else
    echo "T5 unpinned impl: FAIL (rc=$t5_rc)"
    printf '%s\n' "$t5_out"
    st_rc=1
  fi

  # T6 — two [impl] stanzas, same id, different commit
  t6="$(mktemp -d "${TMPDIR:-/tmp}/pds-vp-t6.XXXXXX")"
  mkdir -p "$t6/pds/test"
  cat > "$t6/pds/test/VECTOR-PROVENANCE.txt" << EOF
[impl]
id: dupimpl
repo: https://example.invalid/dupimpl
version: v1.0.0
commit: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
retrieved: 2026-08-17

[impl]
id: dupimpl
repo: https://example.invalid/dupimpl
version: v2.0.0
commit: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
retrieved: 2026-08-17
EOF
  t6_out="$(check_corpus "$t6")"; t6_rc=$?
  rm -rf "$t6"
  if [ "$t6_rc" -eq 1 ] && printf '%s' "$t6_out" | grep -q "CONFLICTING PIN.*dupimpl"; then
    echo "T6 conflicting pin: PASS"
  else
    echo "T6 conflicting pin: FAIL (rc=$t6_rc)"
    printf '%s\n' "$t6_out"
    st_rc=1
  fi

  return "$st_rc"
}

# ── main ──────────────────────────────────────────────────────────────────────
main() {
  echo "=== self-test ==="
  if ! self_test; then
    echo "SELF-TEST FAILED"
    exit 1
  fi
  echo "=== self-test: all six scenarios passed ==="
  echo "=== real tree: $ROOT ==="
  if ! check_corpus "$ROOT"; then
    echo "vector_provenance: REAL TREE CHECK FAILED"
    exit 1
  fi
  echo "vector_provenance: PASS"
  exit 0
}

main
