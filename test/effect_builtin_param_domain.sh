#!/bin/sh
# test/effect_builtin_param_domain.sh
#
# WS-3b gate for DOMAIN-DIRECTED inferred-hole fill on the REAL stdlib
# builtins `getEnv` (Env, Set domain), `runCommand` (Exec, Prefix domain), and
# (filerw-hole-flip) `readFile`/`writeFile` (FileRead/FileWrite, Prefix domain).
# Unlike test/effect_param_domain.sh (which uses per-program LOCAL extern
# redeclarations + a per-program `effect Env Set`/`effect Exec Prefix` decl),
# these fixtures call the stdlib/runtime.mdk builtins DIRECTLY — no local
# extern, no effect decl — because:
#   - Env/Exec/FileRead/FileWrite are already pre-registered as Set/Prefix
#     domains in seedEffectDomains (compiler/types/typecheck.mdk)
#   - stdlib/runtime.mdk's `getEnv`/`runCommand`/`readFile`/`writeFile` (and
#     the other 7 file-IO externs) now carry the universal inferred-hole
#     marker `<Env _>`/`<Exec _>`/`<FileRead _>`/`<FileWrite _>`
# `args` is deliberately NOT flipped (its arg is Unit — no literal to refine).
#
# Prereq: `make medaka` (native CLI).  Usage: sh test/effect_builtin_param_domain.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
M="$ROOT/medaka"
FIX="$ROOT/test/effect_builtin_param_fixtures"
export MEDAKA_ROOT="$ROOT"
[ -x "$M" ] || { echo "build native first: make medaka (missing $M)"; exit 2; }

pass=0; fail=0
run() { perl -e 'alarm 60; exec @ARGV' -- "$M" check "$1" 2>&1; }

# expect ACCEPT: no "TYPE ERROR" / "parse error" line
expect_ok() {
  out="$(run "$1")"
  if echo "$out" | grep -qiE 'TYPE ERROR|parse error|^error:'; then
    echo "FAIL $2 (expected accept):"; echo "$out" | grep -iE 'error' | head -2; fail=$((fail+1))
  else echo "ok   $2"; pass=$((pass+1)); fi
}
# expect REJECT: output must contain the expected performs-row text
expect_reject() {
  out="$(run "$1")"
  if echo "$out" | grep -q "$3"; then
    echo "ok   $2"; pass=$((pass+1))
  else echo "FAIL $2 (expected reject matching '$3'):"; echo "$out" | grep -iE 'error' | head -2; fail=$((fail+1)); fi
}

# ENV (Set domain), REAL builtin getEnv: singleton hole-fill
expect_ok     "$FIX/env_hole_accept.mdk"  "ENV builtin  hole-fill accept ({HOME} ⊆ {HOME,PATH})"
expect_reject "$FIX/env_hole_reject.mdk"  "ENV builtin  hole-fill reject ({HOME} ⊄ {PATH})"   'performs <Env {"HOME"}>'

# EXEC (Prefix domain), REAL builtin runCommand: prefix hole-fill
expect_ok     "$FIX/exec_hole_accept.mdk" 'EXEC builtin hole-fill accept (/usr/bin/ls ⊑ /usr/bin/*)'
expect_reject "$FIX/exec_hole_reject.mdk" 'EXEC builtin hole-fill reject (/usr/bin/ls ⊄ /bin/*)' 'performs <Exec "/usr/bin/ls">'

# FILEREAD (Prefix domain), REAL builtin readFile: prefix hole-fill
expect_ok     "$FIX/fileread_hole_accept.mdk" 'FILEREAD builtin hole-fill accept (/etc/app/config.toml ⊑ /etc/app/*)'
expect_reject "$FIX/fileread_hole_reject.mdk" 'FILEREAD builtin hole-fill reject (/etc/app/config.toml ⊄ /etc/other/*)' 'performs <FileRead "/etc/app/config.toml">'

# FILEWRITE (Prefix domain), REAL builtin writeFile: prefix hole-fill
expect_ok     "$FIX/filewrite_hole_accept.mdk" 'FILEWRITE builtin hole-fill accept (/var/log/app.log ⊑ /var/log/*)'
expect_reject "$FIX/filewrite_hole_reject.mdk" 'FILEWRITE builtin hole-fill reject (/var/log/app.log ⊄ /tmp/*)' 'performs <FileWrite "/var/log/app.log">'

# ── top-level PSet (Env) manifest + check-policy round-trip ──────────────────
# Regression for the missing top-level `PSet (Some xs)` arms in
# check_policy.mdk's atomToToml/atomToAllowTok/parsePolicyTok (Env is a
# top-level Set-domain param, not nested in a PProduct axis).
manifest_out() { perl -e 'alarm 60; exec @ARGV' -- "$M" manifest "$@" 2>&1; }
policy_out()   { perl -e 'alarm 60; exec @ARGV' -- "$M" check-policy "$@" 2>&1; }

# manifest render: FileRead top-level Prefix param renders as a TOML string
# (renders the DECLARED bound, not the refined call-site value).
mff="$(manifest_out "$FIX/fileread_hole_accept.mdk" --fn readCfg)"
mff_expected='[package.capabilities]
FileRead = "/etc/app/*"'
if [ "$mff" = "$mff_expected" ]; then
  echo "ok   FILEREAD manifest render (top-level PPrefix -> TOML string)"; pass=$((pass+1))
else
  echo "FAIL FILEREAD manifest render: expected: $mff_expected; got: $mff"; fail=$((fail+1))
fi

# manifest render: top-level Env set must render as a TOML array, not `Env = true`.
mf="$(manifest_out "$FIX/env_hole_accept.mdk" --fn readHome)"
mf_expected='[package.capabilities]
Env = ["HOME", "PATH"]'
if [ "$mf" = "$mf_expected" ]; then
  echo "ok   ENV manifest render (top-level PSet -> TOML array)"; pass=$((pass+1))
else
  echo "FAIL ENV manifest render: expected: $mf_expected; got: $mf"; fail=$((fail+1))
fi

# round-trip accept: the manifest-derived --allow token (Env={HOME,PATH})
# fed back through check-policy must ACCEPT (self ⊑ self).
rt="$(policy_out "$FIX/env_hole_accept.mdk" --allow 'Env={HOME,PATH}' --fn readHome)"
if echo "$rt" | grep -q '^accepted'; then
  echo "ok   ENV round-trip accept (manifest --allow token accepted by check-policy)"; pass=$((pass+1))
else
  echo "FAIL ENV round-trip accept: $rt"; fail=$((fail+1))
fi

# tightened reject: narrowed Env set ({PATH}, missing HOME) must REJECT, proving
# the policy compare treats the rhs as a Set (subsetStr), not a wrongly-rejecting
# PPrefix (which would hit dsubN's domain-mismatch catch-all regardless of value).
tr="$(policy_out "$FIX/env_hole_accept.mdk" --allow 'Env={PATH}' --fn readHome)"
if echo "$tr" | grep -q '^rejected' && echo "$tr" | grep -q 'Env {"HOME", "PATH"}'; then
  echo "ok   ENV tightened reject (Env={PATH} rejects getEnv \"HOME\")"; pass=$((pass+1))
else
  echo "FAIL ENV tightened reject: $tr"; fail=$((fail+1))
fi

# FFI (Prefix domain, #2071/#2070): FFI is NOT in ioAliasLabels, so an <IO>
# bound must NOT subsume an <FFI>-performing body (control cell uses Exec,
# which IS in ioAliasLabels, to prove the rejection isn't a broken
# expandIoInBound).
expect_reject "$FIX/ffi_io_reject.mdk"  'FFI io-non-subsumption reject (<IO> does not subsume <FFI>)' 'performs <FFI "libcurl\*">'
expect_ok     "$FIX/exec_io_accept.mdk" 'EXEC io-subsumption accept control (<IO> subsumes <Exec>)'

# ── the DECLARED-ROW HONESTY rule + the caller shapes it composes with ──────
#
# F1 (epic #2070) replaced a silent rewrite with a check: a user extern's
# terminal row must ALREADY name `FFI`, whatever else it names, or the
# declaration is a located type error.
#
# 🚨 THE CELL THAT DISCRIMINATES THE RULE FROM ITS NARROW MISREADING is
# `ffi_stamp_missing_reject`, whose offending row is NOT empty.  The predecessor
# rewrote `<Net "…">` to `<FFI, Net "…">` exactly as it rewrote `<>` to `<FFI>`,
# so a bare-`<>` reject cell alone would show all-green against a fix that still
# silently widened every written row.  Read it together with
# `ffi_stamp_narrow_accept`: the two files differ only in the written `FFI`.
#
# The remaining two cells are about the CALLER, not the declaration: with `FFI`
# excluded from `ioAliasLabels` (R1), a caller bounded at bare `<>` does not
# subsume an `<FFI>`-performing body ⇒ REJECT, and naming `FFI` ⇒ ACCEPT.
expect_reject "$FIX/ffi_stamp_missing_reject.mdk" 'FFI declared-row honesty reject (non-empty row missing the FFI label)' \
  "Foreign declaration 'ffiFetch' does not name the 'FFI' effect in its result row"
expect_reject "$FIX/ffi_stamp_bare_reject.mdk"   'FFI caller reject (<> does not subsume the declared <FFI>)' 'performs <FFI>'
expect_ok     "$FIX/ffi_stamp_bare_accept.mdk"   'FFI caller accept (caller names FFI explicitly)'
expect_ok     "$FIX/ffi_stamp_narrow_accept.mdk" 'FFI narrow accept (FFI written alongside the Net param)'


# ── #2074 the FFI-ABI.md section 1 CROSSABLE SET, at check time ──────────────
# A user-declared extern whose signature mentions a type outside section 1 is
# rejected with a located diagnostic naming the offending type.  One reject
# cell per non-crossable kind, one accept cell per crossable row.
#
# 🚨 The two cells that must be read TOGETHER are `ref_reject` and
# `builtin_name_accept`.  The guard EXEMPTS an extern whose name is a real
# `stdlib/runtime.mdk` catalog name, because `isAnyExtern`
# (compiler/backend/llvm_emit.mdk) dispatches emitted calls by NAME against the
# fixed `externCatalog` -- such a redeclaration is lowered as the builtin no
# matter what its local row says, so its signature is not a foreign-call
# contract.  `ref_reject` declares a NOVEL name (`ffiPeek`) carrying `Ref Int`
# and must still REJECT: without it, an exemption that had silently swallowed
# every declaration would still show all-green here.
expect_reject "$FIX/ffi_cross_tuple_reject.mdk" 'FFI crossable reject: Tuple result' \
  "Type '(Int, Int)' cannot cross the foreign-function boundary in extern 'ffiPair'"
expect_reject "$FIX/ffi_cross_list_reject.mdk" 'FFI crossable reject: List param' \
  "Type 'List Int' cannot cross the foreign-function boundary in extern 'ffiSum'"
expect_reject "$FIX/ffi_cross_array_elem_reject.mdk" 'FFI crossable reject: Array with non-Int element' \
  "Type 'Array String' cannot cross the foreign-function boundary in extern 'ffiWidths'"
expect_reject "$FIX/ffi_cross_adt_reject.mdk" 'FFI crossable reject: user ADT' \
  "Type 'Color' cannot cross the foreign-function boundary in extern 'ffiColorCode'"
expect_reject "$FIX/ffi_cross_ref_reject.mdk" 'FFI crossable reject: Ref under a NOVEL extern name (guard still fires)' \
  "Type 'Ref Int' cannot cross the foreign-function boundary in extern 'ffiPeek'"
expect_reject "$FIX/ffi_cross_fnparam_reject.mdk" 'FFI crossable reject: function-typed param (closure cell)' \
  "Type 'Int -> <> Int' cannot cross the foreign-function boundary in extern 'ffiApply'"
# Polymorphic extern: no crossable type is polymorphic.  ALSO the location cell
# -- a bare TyVar has no loc of its own, so this asserts the line, which is
# `:1:0` unless ffiCheckExternSig's whole-signature fallback is applied.
expect_reject "$FIX/ffi_cross_poly_reject.mdk" 'FFI crossable reject: polymorphic extern (located on its own line, not :1:0)' \
  "ffi_cross_poly_reject.mdk:11:.*Type 'a' cannot cross the foreign-function boundary in extern 'ffiWrapAll'"

expect_ok "$FIX/ffi_cross_int_accept.mdk"          'FFI crossable accept: Int'
expect_ok "$FIX/ffi_cross_float_accept.mdk"        'FFI crossable accept: Float'
expect_ok "$FIX/ffi_cross_bool_accept.mdk"         'FFI crossable accept: Bool'
expect_ok "$FIX/ffi_cross_char_accept.mdk"         'FFI crossable accept: Char'
expect_ok "$FIX/ffi_cross_string_accept.mdk"       'FFI crossable accept: String'
expect_ok "$FIX/ffi_cross_arrayint_accept.mdk"     'FFI crossable accept: Array Int'
expect_ok "$FIX/ffi_cross_unit_accept.mdk"         'FFI crossable accept: Unit return (C void)'
expect_ok "$FIX/ffi_cross_builtin_name_accept.mdk" 'FFI crossable accept: builtin-name exemption (getEnv redeclared)'

# ── #2103 the FFI library-name carve-out ────────────────────────────────────
# The Prefix delimiter guard (`prefixPatternOk`) is a HOST/PATH footgun guard;
# an FFI param names a LIBRARY, which has no delimiter structure.  Bare and
# wildcard spellings are both accepted AND denote the same set (prefixConcrete
# strips a trailing `*`), so the accept cells cross the two spellings.  The
# empty pattern is still rejected — the carve-out must not become "anything
# goes", because "" is a prefix of everything and would silently mean ⊤.
expect_ok     "$FIX/ffi_libname_bare_accept.mdk"     'FFI libname accept: bare "libcurl" (#2103)'
expect_ok     "$FIX/ffi_libname_wildcard_accept.mdk" 'FFI libname accept: "libcurl*" extern vs bare-bounded caller (same set)'
expect_reject "$FIX/ffi_libname_empty_reject.mdk"    'FFI libname reject: empty pattern still rejected' \
  'the library pattern is empty'

# ── the three DECLARATION-NAME rules (review round of `ffi-lower-and-link`) ──
#
# Each one turned a SILENT WRONG VALUE at exit 0 into a located refusal, and each
# has an accept cell above that a blunter fix would break -- read them in pairs:
#
#   ffi_nullary_reject          <-> ffi_stamp_narrow_accept
#       differ only in whether an ARROW exists.  While the label rule's `None`
#       arm passed, the emitter lowered a nullary extern as an eta CLOSURE
#       POINTER where the declared value was expected.  #2106 (how a nullary
#       extern WOULD spell a label) stays open; this pins only the refusal.
#
#   ffi_builtin_shadow_reject   <-> ffi_cross_builtin_name_accept
#       differ only in whether the local type-head shape AGREES with the catalog
#       row's.  The builtin-name exemption was keyed on the bare name, and its
#       justification was measured only on COMPATIBLE redeclarations; an
#       incompatible one got the same free pass and reached the real builtin with
#       reinterpreted argument bits.  Deleting the exemption instead of gating it
#       would show green here and red there.
#
#   ffi_reserved_prefix_reject  -- no pair; the ban is unconditional.
#       Its signature MATCHES the runtime internal deliberately: a mismatched one
#       was already loud (clang rejects the conflicting `declare`), so only the
#       matching case discriminates.
#
# -- the FIFTH rule: the CATALOG ROW (#2163, epic #2070 R2) -------------------
#
#   ffi_catalog_narrow_reject   <-> ffi_cross_builtin_name_accept
#       differ only in whether the redeclared row still COVERS the catalog's own
#       row.  Both redeclare `getEnv`; the accept cell writes the catalog's own
#       `<Env "_">`, this one writes `<>`.  The shape rule above cannot see the
#       difference -- it walks THROUGH effect rows by design -- so `<>` typechecked
#       a caller as pure while the emitter lowered the call to the real builtin.
#       Subsumption, not equality: a WIDER row (e.g. `<IO>`) still accepts, which
#       is what keeps `docs/spec/SYNTAX.md`'s `extern putStrLn : String -> <IO>
#       Unit` spelling legal against the catalog's narrower `<Stdout>`.
expect_reject "$FIX/ffi_nullary_reject.mdk" 'FFI nullary reject (no arrow: nowhere to write the FFI label, and the emitter lowered it anyway)' \
  "Foreign declaration 'gNullary' has no arrow in its signature"
expect_reject "$FIX/ffi_builtin_shadow_reject.mdk" 'FFI builtin-shadow reject (catalog name redeclared with an INCOMPATIBLE signature)' \
  "Foreign declaration 'log' redeclares a built-in runtime name with an incompatible signature"
expect_reject "$FIX/ffi_reserved_prefix_reject.mdk" 'FFI reserved-prefix reject (mdk_ is the runtime C symbol namespace)' \
  "Foreign declaration 'mdk_nil' claims a reserved name"
expect_reject "$FIX/ffi_catalog_narrow_reject.mdk" 'FFI catalog-row reject (catalog name redeclared with a NARROWER effect row -- #2163)' \
  "Foreign declaration 'getEnv' redeclares a built-in runtime name with a NARROWER effect row"
expect_reject "$FIX/ffi_catalog_writefile_narrow_reject.mdk" "FFI catalog-row reject: #2163's own program (writeFile redeclared <>)" \
  "Foreign declaration 'writeFile' redeclares a built-in runtime name with a NARROWER effect row"
expect_ok "$FIX/ffi_catalog_honest_accept.mdk" 'FFI catalog-row accept: the honest row, no redeclaration (#2163 CONTROL)'

# #2106: does the alias-wrapped nullary spelling get the SAME T-FFI-NULLARY
# rejection as the plain form (ffi_nullary_reject.mdk above)?  Measured, not
# assumed: `expandAliasHeadTy` unwraps both a direct zero-param alias and a
# constrained alias applied at its own head before `ffiRowHasFFITy` ever sees
# them, so both land on the identical bare-TyCon `None` case and the identical
# message naming the extern 'k'.  #2106 CLOSES on this measurement.
expect_reject "$FIX/ffi_nullary_alias_direct_reject.mdk" 'FFI nullary reject: DIRECT alias (#2106, type A = Int; extern k : A)' \
  "Foreign declaration 'k' has no arrow in its signature"
expect_reject "$FIX/ffi_nullary_alias_constrained_reject.mdk" 'FFI nullary reject: CONSTRAINED alias (#2106, type A a = Sh a => Int; extern k : A Int)' \
  "Foreign declaration 'k' has no arrow in its signature"
echo "effect_builtin_param_domain: $pass/$fail"
[ "$fail" -eq 0 ]
