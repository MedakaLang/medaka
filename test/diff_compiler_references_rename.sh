#!/bin/sh
# test/diff_compiler_references_rename.sh — golden JSON-RPC transcript gate for
# the `medaka_rename` MCP tool (#254 Stage 2: MCP tool + LSP
# `textDocument/rename`, both sharing `tools.lsp.renameResult`, which sits on
# the SAME Stage-0 `compiler/tools/refindex.mdk` index Stage 1's references use).
#
# Feeds a canned newline-delimited JSON-RPC request stream to `./medaka mcp` on
# stdin (same protocol/harness as test/diff_compiler_references_tool.sh — see
# that gate for the wire format), captures stdout, and diffs against a committed
# golden. Its OWN fixture corpus lives under test/references_fixtures/rename/
# (a NEW subdir — never touching test/references_fixtures/query/ or
# .../correctness/, whose goldens belong to other gates; see compiler/AGENTS.md's
# fixture-corpus trap).
#
# WHAT rename.jsonl PROVES (rename/{rdefs,rmain}.mdk)
# ---------------------------------------------------------------------------
# All three requests click inside rename/rmain.mdk. `foo` is a SIGNED top-level
# value in rdefs.mdk (`foo : Int` on one line, `foo = 10` on the next) that
# rmain.mdk imports SELECTIVELY (`import rdefs.{foo}`) — so a COMPLETE rename
# must rewrite the def, the `foo :` SIGNATURE, the `import …{foo}` CLAUSE, and
# every use. #254 Stage 2 extended refindex to index the signature-name and
# import-clause occurrences (previously un-indexed, which would have made a
# selective-import rename break the importing file); this fixture proves the
# emitted edit set now covers them.
#
# Rename TARGETS are PARAMETER-LESS top-level values (`foo`), per issue #913:
# clicking a function name that HAS parameters resolves to the WRONG binder (a
# param's local-binder def Loc collides with the function name's own Loc), so a
# rename target must be parameter-less.
#
#   Q1 (id 2): rename `foo` at rmain.mdk (0-based line 9, col 10 — the first
#     `foo` in `doubled = foo + foo`) to `bar`. Proves a correct, COMPLETE
#     CROSS-FILE `WorkspaceEdit`: 6 edits grouped by uri, sorted (path, then
#     line, then char), each `newText:"bar"`. Hand-verified ranges (0-based
#     line:char):
#       rdefs.mdk  8:7-10  — the `foo :` SIGNATURE name (`export foo : Int`).
#       rdefs.mdk  9:0-3   — the def site `foo = 10` (F6: def ALWAYS included).
#       rdefs.mdk 12:7-10  — `also = foo + 1`, `foo` at chars 7..10.
#       rmain.mdk  6:14-17 — the `import rdefs.{foo}` CLAUSE name.
#       rmain.mdk  9:10-13 — first `foo` in `doubled = foo + foo`.
#       rmain.mdk  9:16-19 — second `foo`.
#     Applying it yields rdefs `foo :`→`bar :`, `foo = 10`→`bar = 10`,
#     `also = bar + 1`, and rmain `import rdefs.{bar}` / `doubled = bar + bar` —
#     a program that STILL COMPILES (sig, import clause, def, and uses all moved
#     together). The Stage-1 references gate proves the same 6 occurrences.
#
#   Q2 (id 3): rename the prelude `not` at rmain.mdk (line 12, col 7 —
#     `flag = not True`) to `whatever`. Proves F3(a) OUT-OF-PROJECT REFUSE:
#     `not` is defined in the core prelude (outside the project root), so
#     `defsOf` finds no project def site → structured refusal
#     `{"refused":true,"reason":"cannot rename a symbol defined outside the
#     project"}`, NEVER a wrong/silent edit. `isError` is true.
#
#   Q3 (id 4): rename `foo` (same click as Q1) to `also` — a name that ALREADY
#     exists as a top-level value in rdefs.mdk. Proves F3(b) CAPTURE/COLLISION
#     REFUSE: the coarse `allDefKeys` scan finds a same-namespace binder named
#     `also` → refusal. Over-refusal is acceptable (F3 conservative spirit); a
#     silent capture is not.
#
# WHAT newname.jsonl PROVES (rename/nvdefs.mdk) — #966 newName VALIDATION
# ---------------------------------------------------------------------------
# `rename.jsonl` above vets the SYMBOL being renamed; these vet the NEW NAME,
# the arm #966 found unchecked. Both used to return a WorkspaceEdit whose
# APPLIED result was broken — the "never a wrong edit" contract's two open holes.
#
#   Q4 (id 2): rename `alpha` (nvdefs.mdk 20:10, the use in
#     `bothSum = alpha + target`) to `Color`. Proves F3(c) CASE/NAMESPACE REFUSE
#     (#966(a)): an uppercase-initial token IS a constructor/type in Medaka's
#     lexis, so applying the old edit produced `Color = 1` and the parse error
#     ``unexpected `Color` ``. Refusal names the namespace, not just "illegal".
#
#   Q5 (id 3): rename `target` (nvdefs.mdk 20:18) to `length`, a PRELUDE value.
#     Proves F3(b) extended to the PRELUDE (#966(b)): `renameCollides` scanned
#     `allDefKeys idx` = `hmKeys idx.defs`, and `refindex.mdk`'s `seedPrelude`
#     seeds prelude names as import ORIGINS with NO def entries — so no prelude
#     name was ever in that scan and the rename silently shadowed `length`.
#
#   Q6 (id 4): rename `alpha` to `renamedAlpha` — a lowercase, non-colliding,
#     non-prelude name. The POSITIVE CONTROL: it must still emit the complete
#     3-edit WorkspaceEdit (sig 13:7 + def 14:0 + the `bothSum` use 20:10),
#     so Q4/Q5 prove a DISCRIMINATING check rather than a check that refuses
#     everything. A gate whose new cases only ever assert refusals cannot tell
#     "validated" from "broken".
#
# WHAT ifacemethod.jsonl PROVES (rename/ifdefs.mdk) — INTERFACE-METHOD RENAME
# ---------------------------------------------------------------------------
# The other two transcripts vet the REQUEST (which symbol, which new name); this
# one vets the INDEX the edits are derived from. `refindex.mdk`'s `defsOfDecl`
# USED TO record an interface's METHOD DECLARATIONS at the enclosing decl's name
# `Loc` — the INTERFACE name — instead of each method's own name token, so a
# rename of an interface method emitted an edit over `interface Shp` and left the
# method declaration untouched: source that no longer parses. F3(d) span
# verification refused it. **#1013 fixed that Loc**, so the transcript now
# asserts the POSITIVE outcome; the corpus's F3(d) negative case moved to
# `pun.jsonl` Q12 (below), which is where span verification is still proven to
# discriminate.
#
#   Q7 (id 2): rename the interface method `zoneArea` at ifdefs.mdk 25:12 (the
#     first use in `zoneTotal = zoneArea (Sqr 3) + …`) to `zoneSize`. Must be the
#     COMPLETE 5-edit WorkspaceEdit — the interface's own method declaration
#     (12:2), BOTH impl clause heads (17:2, 22:2, #1002), and both call sites
#     (25:12, 25:31). Hand-verified: applying all five yields a module that still
#     checks clean.
#
#   Q8 (id 3): rename `zoneTotal` at 25:0 to `zoneSum` — a plain signed value in
#     the SAME file. The unrelated-symbol control: the 2-edit WorkspaceEdit
#     (sig 24:0 + def 25:0) must be untouched by anything Q7 does.
#
# WHAT pun.jsonl PROVES (rename/pdefs.mdk) — #963 RECORD-PUN EXPANSION
# ---------------------------------------------------------------------------
# A record PUN spells the FIELD name and the BINDER name with ONE token, so an
# edit that replaces that token outright renames the field too:
# `Circle { radius }` → `Circle { rad }` is a LOUD `Unknown field: rad` (#963).
# The span really does spell the old name, so F3(d) cannot see it — the span is
# right, the REPLACEMENT is wrong. `renameEmitVerified` now emits the expansion
# the sugar stands for, `girth = <newName>`, at a pun token only.
#
#   Q9 (id 2): rename the PATTERN pun binder `girth` at pdefs.mdk 21:9 (inside
#     `Blob { girth, mark = m } => girth * m`) to `girthA`. Two edits: the pun
#     token 21:9-14 becomes `girth = girthA` (NOT a bare `girthA`), the ordinary
#     use 21:30-35 becomes `girthA`. Applying both yields
#     `Blob { girth = girthA, mark = m } => girthA * m`.
#
#   Q10 (id 3): rename the PARAMETER `girth` at 27:7, whose only use is an
#     EXPRESSION pun (`mkBlob girth mark = Blob { girth, mark }`), to `girthB`.
#     The mirror of Q9: the binder 27:7-12 takes the bare name and the pun token
#     27:27-32 takes `girth = girthB`. Proves the expansion is keyed on the SITE,
#     not on which end of the rename the click was.
#
#   Q11 (id 4): rename `lo` at 32:9 — used inside a GENUINE `Set { lo, hi }`
#     literal — to `loZ`. The NEGATIVE CONTROL: both edits must be BARE. A brace
#     whose head is not a `ConNamed` ctor of this module is a container literal,
#     not a record, and expanding its elements would corrupt a working program.
#     Without this case a fix that expanded every bare brace element would pass.
#
#   Q12 (id 5): rename the parameter `girth` at 36:10, used in the RECORD-UPDATE
#     pun `{ b | girth }`, to `girthD`. Must be an F3(d) REFUSAL: the parser
#     builds a record-update pun's `EVar` UNLOCATED, so the index files the use
#     at the enclosing expression's span and span verification catches it. This
#     is the corpus's F3(d) negative case (it replaced Q7's, retired by #1013).
#
# All three edit sets above were applied by hand and the resulting module both
# checks and evaluates to the SAME value as before the rename (50).
#
# WHAT scopes.jsonl PROVES — F3(b) AFFECTED SCOPE + F3(f) KNOWN-INCOMPLETE SHAPE
# ---------------------------------------------------------------------------
# ⚠️ THIS TRANSCRIPT'S FIXTURES LIVE IN A SIBLING DIRECTORY,
# test/references_fixtures/rename_scopes/, NOT beside this file. That is
# deliberate and load-bearing: rename resolves its project root by walking up
# from the CLICKED file, so every `.mdk` next to a fixture is inside that
# fixture's project — dropping these modules into rename/ would have put their
# binders (and, for partial.jsonl below, files that do not parse) into the
# project index of every transcript above. A sibling directory keeps each
# corpus's index its own. The gate still loops over rename/*.jsonl; only the
# `.mdk` corpora are split.
#
# ⚠️ EVERY NEGATIVE CONTROL BELOW SITS IN THE CELL ITS ARM COULD GO BLIND IN —
# not beside it. That rule is written in blood: a previous version of the F3(f)
# arm keyed on "a second binder spells this name" and had to carve out
# `local`↔`local` to let ordinary shadowing through, and the fixture written to
# prove no-over-refusal was itself a `local`↔`local` pair. Test and bug occupied
# the same cell, so the corpus could not have caught the S0 that carve-out let
# past. Each control names its cell.
#
# Each request below emitted a WRONG EDIT before its arm landed — reproduced by
# driving `medaka mcp`, APPLYING the WorkspaceEdit, and re-running.
#
#   Q1/Q2 (id 2,3): rename `plainVal` (scopes.mdk 51:0) to `match`, then to `_`.
#     F3(c) RESERVED-WORD REFUSE. Every keyword in `frontend/lexer.mdk`'s
#     `keywordOrIdent` table is a lowercase identifier, so all 31 passed the
#     `isIdentStart`/`allIdentChars`/case checks #966(a) added: the applied edit
#     produced ``unexpected `match` ``. `newNameReserved` (lsp.mdk) asks the real
#     tokenizer instead of a copied list, so a keyword added to the lexer is
#     covered here the day it lands.
#
#   Q3 (id 4): rename the LOCAL `capLocal` (via its use, 32:2) to `capTop`, a
#     TOP-LEVEL value in the same file. F3(b) CROSS-NAMESPACE CAPTURE REFUSE.
#     `anyDefKeyMatches` compared namespace TAGS (`ns2 == ns`), so a `local` key
#     could never match a `val` key — the capture arm was blind in exactly the
#     direction capture happens. Applied, this module still `check`ed clean and
#     printed a DIFFERENT ANSWER (102 -> 4 on the review's reproducer).
#
#   Q4 (id 5): the INVERSE — rename the TOP-LEVEL `capTop` (via its use, 32:13)
#     to `capLocal`, a local in the same file. Must refuse too; a fix that only
#     looked one way would pass Q3 and fail here.
#
#   Q5 (id 6): rename `plainVal` to `sortBy`, a name the file IMPORTS
#     (`import list.{sortBy}`). F3(b) IMPORT-SCOPE REFUSE — the scan saw
#     `allDefKeys` plus the prelude and never the names an import binds, so this
#     was #966(b) unfixed one module over.
#
#   Q6 (id 7): rename the OUTER `shOuter` (40:2) of a shadowed pair to
#     `shTotal`. CELL: locals shadowing locals. Two edits, the inner `shOuter`
#     untouched.
#
#   Q7 (id 8): rename `plainVal` to `plainValZ`. CELL: nothing special — the
#     plain positive control that a legal name still emits the full edit set.
#
#   Q8 (id 9): rename the LOCAL `shdVal` (48:2), which SHADOWS a top-level of
#     the same name, to `shdCap`. CELL: `val`↔`local` namesake. Renaming ONTO
#     the other one is Q3/Q4's refusal; renaming EITHER OF THEM is ordinary code
#     and must succeed. A namesake-based F3(f) refused this.
#
#   Q9 (id 10): rename `plainVal` to `boxWidth` — a name that exists in this file
#     ONLY as a record FIELD. CELL: `field` vs value. A field label is reached
#     through the record's type, never the value scope, so it can neither capture
#     nor be captured; hand-applied, the module still checks. A namespace-blind
#     capture scan refused this.
#
#   Q10 (id 11): rename the SELF-RECURSIVE LOCAL `rgo` (recshapes.mdk 38:4, via
#     its use inside `rNest`) to `rgoZ`. F3(f) REFUSE, #1003. The recursive call
#     `rgo (k - 1)` is not filed under the local's key, so the rename left it
#     behind and it REBOUND to the enclosing `rgo`: `check` rc=0, output 10 ->
#     104. Silent. CELL: the namesake here is another `local`, not a top-level —
#     the exact variant the previous namesake-based arm carved out.
#
#   Q11 (id 12): rename the OUTER `rgo` (39:12), same file, same spelling, one
#     scope out, whose `let` does NOT mention itself. CELL: same name, same file,
#     not self-recursive — a detector matching the NAME rather than THIS def
#     site's own `Loc` would refuse it. Two edits; applied, the module checks.
#
#   Q12 (id 13): rename the top-level `let rec` binding `rcount` (47:21, via its
#     external call) to `rcountZ`. F3(f) REFUSE, #951 — `recshapes|local|rcount|N`
#     and `recshapes|val|rcount` hold a def at the SAME span and split the call
#     sites between them, so either click edits half. Applied: `Unbound variable`.
#
#   Q13 (id 14): rename `rplain` (47:32), an ordinary top-level function that IS
#     self-recursive. CELL: recursive but not a `DLetGroup` — a detector keyed on
#     "recursive" rather than on the top-level `let rec` FORM would refuse it.
#
#   Q14 (id 15): rename the interface method `shdwMine` (ifshadow.mdk 20:10) to
#     `shdwMineZ`. F3(f) REFUSE, #1056 — this module DECLARES `interface Shdw`
#     and also IMPORTS one, and refindex's `addOwnToEnv`-then-`processImports`
#     order lets the import win, so the impl clause head lands on a phantom key
#     and is dropped. Applied: `Method 'shdwMine' is not part of interface 'Shdw'`.
#
#   Q15 (id 16): rename `shdwOther` (ifshadow_ok.mdk 17:8). CELL: same imported
#     interface, same module, an impl clause head present — everything the #1056
#     case has EXCEPT a local re-declaration of `Shdw`. A first cut counted the
#     impl head as "declaring" the method name and refused this, i.e. refused
#     EVERY impl of an imported interface method. Applied, both files check.
#
#   Q16 (id 17): rename `aliasBar` (alias_lib.mdk 3:7) to `aliasZoo` while
#     `alias_main.mdk` calls it as `D.aliasBar` from a wrapper of the SAME name.
#     F3(f) REFUSE, #965(a) — the alias-qualified reference is filed at the
#     enclosing decl's `curLoc`, which here really does spell `aliasBar`, so
#     F3(d) span verification waves it through and the edit rewrote an UNRELATED
#     binder's definition head.
#
#   Q17 (id 18): rename `alias_other.mdk`'s OWN `aliasBar` (10:0) to
#     `aliasOtherZ`. CELL: a symbol spelled identically to Q16's, in a module
#     that `alias_main.mdk` ALSO alias-imports — but reached through that alias
#     only as `E.otherFn`, never `E.aliasBar`. A detector keyed on "some file
#     mentions `<alias>.aliasBar`", or on "this module is aliased somewhere",
#     would refuse it.
#
#   Q18 (id 19): rename `reexpVal` (reexp_main.mdk 15:0) to `sortBy`, which
#     reaches that module through `import reexp_mid.*` where `reexp_mid` holds
#     `export import list.{sortBy}`. F3(b) RE-EXPORT HOP. A re-exported name is a
#     `DUse`, not a declaration, so the module-source check could not see it —
#     and a DIRECT `import list.*` WAS already refused, which is what made the
#     gap invisible: the arm looked like it worked.
#
#   Q19 (id 20): rename `reexpVal` to `intercalate`. CELL: `list` declares it, so
#     the wildcard chain COULD reach it, but `reexp_mid` re-exports only
#     `sortBy` — a fix that pulled in everything downstream of the wildcard would
#     refuse it wrongly.
#
# ⚠️ Q10/Q12/Q14/Q16 are why the F3(f) arm is not the one-line gate proposed in
# review ("refuse whenever an edit span was recorded at the enclosing decl's
# `curLoc` rather than at a name token"): that is not observable from outside
# refindex (a caller sees a `Loc`, not its provenance, and the only observable
# proxy — "the span equals a decl's own name Loc" — is what every legitimate
# top-level def looks like), and dumping the index for all four showed only
# #965(a) has a misplaced span at all. Nor is it the namesake proxy that replaced
# it. See `renameIndexIncomplete` (lsp.mdk) for both post-mortems and for why the
# arm is four AST-decidable shapes instead.
#
# WHAT partial.jsonl PROVES (rename_partial/) — F2 PARTIAL GRAPH
# ---------------------------------------------------------------------------
#   Q20 (id 2): rename `gval` (goodmain.mdk 7:10) to `gvalZ` while the sibling
#     `brokensib.mdk` does not parse. Must REFUSE and NAME that file.
#     `refindex`'s `indexModule` no-ops an unparseable file, so its THREE `gval`
#     occurrences (the `import gooddefs.{gval}` clause and both uses) were absent
#     from the index and rename returned a clean `isError:false` success that
#     silently dropped them — `REFERENCES-RENAME-DESIGN.md:362-367` calls this
#     out by name. Refusal beats a `partial: true` marker because
#     `textDocument/rename` returns a `WorkspaceEdit` that editors apply
#     wholesale; the protocol has no slot a partial flag could occupy.
#
#   Q21 (id 3): rename `strval` (7:17) while `strsib.mdk` mentions it AFTER an
#     UNTERMINATED STRING LITERAL. CELL: a broken file whose LEXER view is broken
#     too — every character after the open quote is swallowed into the string, so
#     a token-based mention scan sees no `TIdent strval` and waves the file
#     through. `srcMentionsName` is a character scan for exactly this.
#
#   Q22 (id 4): rename `untouched` (7:26) to `untouchedZ`. CELL: the name appears
#     in a broken sibling's `--` COMMENT and nowhere else in it. A comment is not
#     an occurrence, so this must still emit the complete 4-edit set (sig + def +
#     import clause + use) — a character scan that did not skip comments failed
#     exactly here. Without this case, "refuse whenever any project file is
#     broken" would also pass, and one unparseable scratch file would block every
#     rename in the project.
#
#   Q23 (id 5): click INSIDE `brokensib.mdk` (10:14), the unparseable file
#     itself. The position is on an identifier but nothing in that file is
#     indexed, so `binderAt` misses — and the old wording, "no renameable symbol
#     at this position", sent the user hunting for a cursor bug in the commonest
#     real case (a mid-edit buffer). Must name the parse failure instead.
#
# All (line, col) pairs were hand-derived from the fixture source by counting
# characters (0-based, LSP-style) — re-derive the same way if the fixtures
# change. To regenerate the golden:
#   CAPTURE=1 sh test/diff_compiler_references_rename.sh
# (diff the result before committing, as with any CAPTURE=1 gate.)
#
# Usage: sh test/diff_compiler_references_rename.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDAKA="$ROOT/medaka"
FIXDIR="$ROOT/test/references_fixtures/rename"

[ -x "$MEDAKA" ] || { echo "SKIP: ./medaka not built — run: make medaka"; exit 2; }
[ -d "$FIXDIR" ] || { echo "FAIL: missing $FIXDIR"; exit 1; }

export MEDAKA_ROOT="$ROOT"

# Fixed cwd = repo root, exactly like diff_compiler_references_tool.sh, so a
# fixture's repo-relative `file` argument resolves the same regardless of where
# this gate was invoked from, and no `medaka.toml` sits above the fixture dir,
# so `findProjectRoot` falls back to the fixture dir itself as the project root.
cd "$ROOT" || { echo "FAIL: cannot cd to $ROOT"; exit 1; }

pass=0; fail=0

for req in "$FIXDIR"/*.jsonl; do
  [ -f "$req" ] || continue
  name="$(basename "$req" .jsonl)"
  golden="$FIXDIR/$name.golden"

  tmpout="$(mktemp)"
  perl -e 'alarm 30; exec @ARGV' "$MEDAKA" mcp < "$req" > "$tmpout" 2>/dev/null
  rc=$?
  self_out="$(cat "$tmpout")"
  rm -f "$tmpout"

  if [ "${CAPTURE:-0}" = "1" ]; then
    printf '%s\n' "$self_out" > "$golden"
    printf 'CAPTURE %s\n' "$golden"
    continue
  fi

  if [ ! -f "$golden" ]; then
    fail=$((fail+1)); printf 'FAIL %s (missing golden %s)\n' "$name" "$golden"; continue
  fi
  want_out="$(cat "$golden")"

  # Exit code checked too — a tool that emits correct response lines and THEN
  # crashes before EOF must not read as a pass (same as the references gate).
  if [ "$rc" -ne 0 ]; then
    fail=$((fail+1)); printf 'FAIL %s: medaka mcp exited %d\n' "$name" "$rc"
    printf '  self:   %s\n' "$self_out"
  elif [ "$self_out" = "$want_out" ]; then
    pass=$((pass+1)); printf 'ok   %s\n' "$name"
  else
    fail=$((fail+1)); printf 'FAIL %s\n' "$name"
    printf '  self:   %s\n' "$self_out"
    printf '  golden: %s\n' "$want_out"
  fi
done

if [ "${CAPTURE:-0}" = "1" ]; then
  exit 0
fi

echo ""
total=$((pass+fail))
printf 'checked %d fixture(s): %d ok, %d failing\n' "$total" "$pass" "$fail"

# A gate that silently compares zero fixtures must FAIL, not report green.
if [ "$total" -eq 0 ]; then
  echo "FAIL: no fixtures found under $FIXDIR (checked 0 — treating as failure)"
  exit 1
fi

[ "$fail" -eq 0 ]
