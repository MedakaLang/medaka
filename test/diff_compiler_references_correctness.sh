#!/bin/sh
# test/diff_compiler_references_correctness.sh — the CORRECTNESS gate for the
# cross-file reference index (compiler/tools/refindex.mdk, #254 Stage 0).
#
# WHAT IT PROVES (the "match binders, not strings" property, permanently)
# ----------------------------------------------------------------------
# Runs refindex_main --dump over the 4-module correctness project
# (test/references_fixtures/correctness/) and diffs the per-BinderKey dump
# against a captured golden. The fixture is built so ONE dump exercises every
# resolution hazard at once:
#
#   * shadowing              — a LOCAL `g` in main.topG gets a distinct `local`
#                              key; the imported top-level `g` keeps its own uses.
#   * member alias `helper as hh`, module alias `D.helper`, AND the re-export
#     chain `import reexport.{helper}` — all three spellings collapse to the ONE
#     origin key `defs<TAB>val<TAB>helper`.
#   * same name, two modules — `defs.shared` and `other.shared` are distinct keys.
#   * namespace clash        — `Color` (type) vs `Red` (ctor) are distinct keys.
#
# A regression that keyed by spelling (or lost import-origin threading) would
# merge or split these keys and MOVE this golden — that is the whole point.
#
# #254 Stage 2: each binding's USES now also include its TYPE SIGNATURE name
# (`foo :`) and every SELECTIVE / RE-EXPORT import CLAUSE name (`import m.{foo}`),
# recorded under the SAME key — so a signed, selectively-imported symbol's
# `references`/`rename` cover its signature and import clauses too. This grew the
# per-key USE lists in the golden; the binder-identity property above is unchanged.
#
# The dump prints absolute file uris, so paths are normalized to the fixture-
# relative basename before diffing, keeping the golden machine/worktree-stable.
#
# Usage: sh test/diff_compiler_references_correctness.sh
#   CAPTURE=1 sh test/diff_compiler_references_correctness.sh   — re-mint the golden
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SELF="$ROOT/test/bin/refindex_main"
RT="$ROOT/stdlib/runtime.mdk"
CORE="$ROOT/stdlib/core.mdk"
CAPTURE="${CAPTURE:-0}"

[ -x "$SELF" ] || {
  echo "build oracles first: FORCE=1 JOBS=1 sh test/build_oracles.sh --build-one refindex_main (missing $SELF)"
  exit 2
}

rc=0

# Dump one fixture project (rooted at <dir>/main.mdk) and diff against
# <dir>/expected.golden, with the fixture's absolute path prefix stripped so the
# golden is machine-independent (`#` delimiter — the path contains `/`, never `#`).
check_project() {
  fixdir="$1"; what="$2"
  gold="$fixdir/expected.golden"
  [ -d "$fixdir" ] || { echo "missing fixture dir $fixdir"; rc=2; return; }
  out="$("$SELF" --dump "$RT" "$CORE" "$fixdir/main.mdk" "$fixdir" 2>&1 | sed "s#$fixdir/##g")"

  if [ "$CAPTURE" = 1 ]; then
    printf '%s\n' "$out" > "$gold"
    echo "captured $gold ($(printf '%s\n' "$out" | grep -c '') lines)"
    return
  fi

  [ -f "$gold" ] || {
    echo "no golden at $gold — capture it: CAPTURE=1 sh test/diff_compiler_references_correctness.sh"
    rc=2; return
  }

  if printf '%s\n' "$out" | diff -u "$gold" - > /dev/null 2>&1; then
    echo "PASS: $what dump matches golden."
    return
  fi

  echo "FAIL: reference-index dump DIFFERS from $gold"
  echo "  ($what — a binder DEF/USE Loc or BinderKey moved.)"
  printf '%s\n' "$out" | diff -u "$gold" - | head -60
  rc=1
}

# The original 4-module corpus: shadowing / alias / re-export / same-name / namespace.
check_project "$ROOT/test/references_fixtures/correctness" \
  "reference-index correctness (shadowing / alias / re-export / same-name / namespace)"

# #913 Inc 2: every param/local binder records its DEF at its OWN name-token Loc,
# not the enclosing declaration's loc (fn param `p` ≠ `incByOne`'s loc; the
# `let tmp` local sits at the let token, not `shadowLet`'s loc).
check_project "$ROOT/test/references_fixtures/binder_loc" \
  "reference-index binder-Loc (#913 Inc 2: each binder at its own name token)"

# #964: a MULTI-CLAUSE top-level fn is N `DFunDef` decls sharing ONE BinderKey,
# so its key must carry N DEF sites (one per clause head), not just the last.
# A regression back to last-write-wins collapses those DEF columns to one entry
# and MOVES this golden.
check_project "$ROOT/test/references_fixtures/multiclause" \
  "reference-index multi-clause defs (#964: every clause head is a DEF site)"

# #964, the other half: the def list is a SET of sites, never a bag. A record field
# shared by K variants is recorded K times at ONE decl Loc under ONE field key, so an
# unguarded append repeats a byte-identical location — which a rename would turn into
# K edits over the same range (rejected, or double-applied, by LSP clients). No DEF
# column in this golden may repeat a site.
check_project "$ROOT/test/references_fixtures/dup_field_def" \
  "reference-index def dedup (#964: a shared record field is ONE DEF site, not K)"

# #1002: an `impl`'s method clause heads are DEF SITES, on the INTERFACE's key.
# They used to be recorded as neither def nor use (defsOfDecl returned [] for
# DImpl; walkImplMethods discarded the method name), so `references` on a method
# missed every impl and a rename would have orphaned them all. The fixture pins
# the keying from three directions: same module as the interface, a different
# module (resolved through the import, NOT the impl's own module id), and two
# impls of one interface for different types.
check_project "$ROOT/test/references_fixtures/impl_method" \
  "reference-index impl-method heads (#1002: every impl clause head is a DEF site)"

# #1002 F1: TWO interfaces declaring the same method name. Each impl's heads must
# land on ITS OWN interface's key. Keying by the bare method name through useEnv
# merged them (one slot per `method<TAB><name>`, no interface identity), which
# attributed one interface's impl to the other — a rename would then edit the
# wrong impl. A regression back to method-name keying collapses these two rows.
check_project "$ROOT/test/references_fixtures/iface_collide" \
  "reference-index method keying (#1002 F1: same method name, two interfaces stay distinct)"

# #1013: an interface METHOD's declaration def site is its OWN name token, not the
# interface's. It used to inherit the decl's loc, so `weigh` was recorded at
# `Weighed` — a rename driven off that set would have overwritten the interface
# TYPE NAME. Also pins the sig/default 1:1 zip (a defaulted method is two clause
# lines, so it carries two DISTINCT def spans, and no method may be dragged onto
# a neighbour's line).
check_project "$ROOT/test/references_fixtures/iface_method_loc" \
  "reference-index iface-method Loc (#1013: a method's decl def is at the METHOD token)"

# #1044: an imported TYPE sharing an interface's name must not steal the slot the
# impl-header lookup reads. Keying through `nsTy` (one slot per name, shared by
# data/newtype/alias/interface, last-write-wins) filed the head under a phantom
# `b|method|mfoo` and dropped it from `a|method|mfoo`. The import ORDER in that
# fixture's main.mdk is load-bearing — see its header.
check_project "$ROOT/test/references_fixtures/iface_ty_collide" \
  "reference-index iface keying (#1044: an imported TYPE cannot steal the interface slot)"

exit "$rc"
