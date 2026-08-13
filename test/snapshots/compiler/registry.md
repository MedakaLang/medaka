# META
source_lines=2024
stages=DESUGAR,MARK
# SOURCE
-- Identity + registry substrate — Stage A-2 unit A-2.0
-- (#1111 / TYPECHECK-TARGET-ARCHITECTURE.md §2 K, §6 A-2).
--
-- ⚠️ WHAT THIS UNIT DRAINS: NOTHING, YET. It is the substrate the LATER A-2
-- units re-key their tables onto; a defect is drained by the unit that
-- converts the table it lives in, never by this one. The eight tracked
-- defects Stage A-2 as a whole addresses, read off the tracker 2026-08-03:
-- S0 #1047, #1069, #1092, #1256; S1 #1257, #1258, #1259; S2 #1090.
-- ⚠️ #1047 is already CLOSED, and NOT by this substrate — PR #1264 (unit
-- A-2.9) closed it by giving the Core IR's untagged-default registry an
-- interface identity (`ifaceIdentity`/`ifaceIdMatches`, `frontend/ast.mdk`),
-- a backend-side fix that does not use this module at all. It is listed
-- because it is one of the eight collisions that motivated the arc, not
-- because anything here drains it.
-- 🚨 An earlier cut of this header said "drains #1070's five audit rows
-- across #1047/#1069/#1092/#1090" — FOUR issues, and phrased as if the
-- draining happened here. The severity self-correction updated
-- `frontend/ast.mdk` and left this header behind; both now name the same
-- tracker-derived set of eight.
--
-- 🚨 THIS UNIT CONVERTS NO TABLE AND HAS ZERO CALL SITES. It lands the
-- `Ident`/`Ns` identity carrier (in `frontend/ast.mdk`) and the
-- `Registry`/`MultiRegistry`/`SetRegistry` combinators (here) so each later
-- A-2 unit has something to re-key ONE table's writer + ALL its readers
-- onto, in a single PR. Nothing in `compiler/` imports this module yet —
-- that is a feature of the staging, not an oversight (see §6 A-2 in the
-- design doc: each conversion is its own reviewable, bisectable PR).
--
-- 🚨 BECAUSE THERE ARE NO CALL SITES, AN API DEFECT HERE HAS NOTHING TO
-- CATCH IT. The API is therefore sized against the ACTUAL target tables
-- (enumerated under "What the target tables need" below), not against what
-- a first conversion happens to reach for. Two API defects found by
-- adversarial review of this file's first cut were exactly that shape: no
-- composite-key form (five target tables have composite keys) and no
-- deletion/enumeration (two target conversions cannot be written without
-- them).
--
-- 🚨 "NO CALL SITES" ALSO MEANT "IN NO GATE", AND THAT IS NOW FIXED — the
-- paragraph above used to answer the hazard with doctests that NOTHING RAN.
-- A module outside every entry's import closure is invisible to `make
-- medaka`, to `make check-self`, and to `test/typecheck_compiler_source.sh`
-- (pass 1 walks `compiler/driver/medaka_cli.mdk`, pass 2 covers
-- `compiler/entries/*.mdk`; this file is in neither). MEASURED 2026-08-03:
-- with `regSize (Registry m) = "not an int"` injected here, `./medaka check
-- compiler/driver/medaka_cli.mdk` exited 0 and `make check-self` printed
-- PASS. So `Makefile`'s `test:` target now names this module explicitly.
-- `medaka test <file>` TYPECHECKS the file before running its doctests, so
-- that one line puts both halves — the types and the ~90 assertions below —
-- inside the required `inlang` check, which runs `make test`.
-- ⚠️ EVERY LATER A-2 UNIT INHERITS THIS. A unit that lands a
-- call-site-free module and forgets its `Makefile` line has shipped
-- unverified code with every gate green.
--
-- ── Why one `Ident` type generalizes a pattern already in the tree ─────────
-- `crossModuleFunConstraintsQualRef` (`types/typecheck.mdk`) is already keyed
-- by `(module, name)` because its bare-name twin
-- `crossModuleFunConstraintsRef` collides across modules that declare the
-- same function name. `Ident` generalizes that pair to
-- `(namespace, origin, name)` so the ~15 `universe*`/method/record/kind
-- tables named in #1070 can all re-key onto ONE identity type — one
-- comparator, one collision-free key renderer, one place a namespace can be
-- forgotten — instead of each growing its own ad hoc qualified-pair variant.
-- The namespace argument, its measured witness, and the citation correction
-- for `resolve.mdk`'s 2-namespace precedent all live on `Ns` in
-- `frontend/ast.mdk`; they are not repeated here.
--
-- ── Placement (measured 2026-08-03; re-derive, do not trust the numbers) ───
-- `Ns`/`IdentOrigin`/`Ident` are NOT here — they live in `frontend/ast.mdk`
-- beside the `TyConOrigin` they are derived from, because they are plain data
-- and the combinators below are not (they need `support/ordmap.mdk`). The
-- gate arithmetic behind keeping the combinators OUT of `compiler/support/`:
--   PREFLIGHT_DRY=1 PREFLIGHT_CHANGED_FILE=<file naming ONE path> sh test/preflight.sh
-- gives 103 gates for `compiler/support/util.mdk` (`test/preflight.sh`'s
-- `mark_full` blast-radius arm — the whole-suite run `AGENTS.md` forbids as
-- the everyday loop) versus 25 for `compiler/types/registry.mdk`, and that 25
-- is the BYTE-IDENTICAL set `compiler/types/typecheck.mdk` selects, so this
-- module costs a later A-2 unit nothing at all. For reference `ast.mdk`
-- selects 16 — NARROWER than this file, not wider.
-- 🚨 The first cut of this paragraph asserted the opposite ("`ast.mdk` … a
-- ~26-gate import surface (vs. `types/registry.mdk`'s narrower blast
-- radius)"). Both numbers were invented and the comparison was inverted.
-- The exact gate LISTS are in this PR's body, and the command above
-- regenerates them; the counts here are dated because counts rot.
--
-- ── Backing store ───────────────────────────────────────────────────────────
-- Wraps the EXISTING `OrdMap` (`support/ordmap.mdk`, itself a transparent
-- alias for stdlib `Map String a`) rather than reaching for stdlib `map`/
-- `hash_map` directly. `support/ordmap.mdk` is already imported by
-- `types/typecheck.mdk`, so this pays NOTHING extra: `Map`'s Eq/Ord/Debug/
-- Display/Mappable/Monoid instance surface is already forced into the
-- binary. Importing a stdlib module that defines a brand NEW type (e.g.
-- `map` cold, or `hash_map`) from a module that does not already transitively
-- pull it in is the anti-pattern `AGENTS.md` measures at +34 KB / +4.8%
-- self-compile (DCE keeps a `DImpl`/`DInterface` whole once it is
-- reachable at all) — this module avoids that by riding the SAME `OrdMap`
-- everything else already rides. `list.{sort}` and `map.{toList}` below are
-- likewise both already-forced surface (typecheck.mdk imports `list`
-- directly; `toList` operates on the already-forced `Map` type), so neither
-- adds new retained instance surface.
--
-- ── `identKey`: the ONE renderer, collision-free by construction ───────────
-- Every component (namespace tag, origin tag, origin module-or-empty, name)
-- is rendered through `lenKey` (`support/util.mdk`) — a length-prefixed
-- ("netstring") encoding: `lenKey s = "\{intToString (stringLength s)}:\{s}"`.
-- This is the SAME collision-free composite-key technique
-- `support/util.mdk`'s own callers already rely on (see its `lenKey`
-- doc-comment). Concatenating length-prefixed fields cannot let one field's
-- content bleed into the next boundary REGARDLESS of what characters the
-- fields contain — no separator character to reserve, so there is no
-- "adversarial name contains the separator" case to guard against (the
-- doctests below instead demonstrate the sharper adversarial case: two
-- DIFFERENT `(origin module, name)` pairs that share a character at their
-- boundary, e.g. `("ab", "c")` vs. `("a", "bc")`, which a naive `++`
-- concatenation WOULD collide on and `lenKey`-prefixing does not).
--
-- Each `identKey` is a group of EXACTLY FOUR netstrings, and a netstring
-- stream is uniquely decodable (the length prefix is all digits, so the
-- first `:` is always the delimiter). Both facts are load-bearing for the
-- composite keys below.
--
-- `identKey`'s output is OPAQUE TO CONSUMERS: no code outside this module may
-- parse it back, and this module's own non-test code does not either.
-- `regEntries` therefore does not reconstruct an `Ident` from the rendered
-- key — it keeps the original `RegKey` alongside its value in the backing map
-- instead, so recovering identities never depends on the key being decodable.
--
-- ⚠️ THE DOCTESTS IN THIS FILE ARE A STATED EXCEPTION, AND DELETING THEM
-- WOULD BE A REGRESSION, NOT A CLEANUP. Several assertions below read the
-- key's BYTES on purpose (`identKey identTypeFooM == "4:type6:module1:m3:Foo"`
-- and the three `startsWith "1:…"` count-prefix lines). They are not
-- consumers violating the contract; they are the only witnesses to two
-- invariants that no property-level test can see — that the origin TAG is
-- present, and that the ident-COUNT prefix is present. Both are documented
-- below as defense in depth precisely because the module still behaves
-- correctly without them TODAY, so a reviewer who reads only this paragraph,
-- concludes the byte-reading tests violate the contract, and deletes them
-- removes the one thing keeping injectivity independent of `nsTag`'s
-- alphabet. The contract is: opaque to CONSUMERS, transparent to the tests
-- that pin the encoding.
--
-- ── What the target tables need: COMPOSITE keys (`RegKey`) ─────────────────
-- An `Ident` names ONE declaration, and at least five tables A-2 must convert
-- are keyed by a TUPLE. Sizing the API to `Ident` alone would force each of
-- those conversions to re-invent a bare-string composite INSIDE the identity
-- (e.g. stuffing `"Foo@3"` into an `Ident`'s name field), which re-introduces
-- exactly the un-keyed string this arc exists to remove and forces a lie
-- about which `Ns` the thing is in. So `RegKey` is the key type and `Ident`
-- is its one-element case:
--
--   ⚠️ #1112 A-3.4 PR2 renamed one row's ANCHOR, not its key: the concrete
--   obligation bucket used to be cited as `obUnivConcreteRef`, a `CrossRun`
--   accumulator that unit DELETED. The key is unchanged; it is minted by
--   `insertUnivImplAt` into `ImplUniverse`, which the Module path now gets
--   from `ieUniverseAt` and the Flat path from `buildImplUniverse`.
--   | table                            | key                      | site          |
--   |----------------------------------|--------------------------|---------------|
--   | `universeIfaceParamKinds`        | TabKey × Int  ✅ A-2.4    | typecheck.mdk |
--   | `ImplUniverse` concrete bucket   | Ident × Ident            | typecheck.mdk |
--   | `checkCallObligationsU` dedup    | Ident × [Option Ident]   | typecheck.mdk |
--   | `methodReqCountRef`              | Ident × Ident            | eval.mdk      |
--   | `ifaceDispatchRef`               | Ident × Ident            | eval.mdk      |
--
-- Three of the five are pure identity tuples (`regKeyN`); one pairs an
-- identity with a parameter SLOT, which is an ordinal and not a declaration —
-- it has no namespace and no origin, so it is carried in `RegKey`'s second
-- component (`regKeyTabAt`) rather than faked as an `Ident`.
--
-- ⚠️ ROW 1 SAID `Ident × Int` UNTIL A-2.4 CONVERTED IT, AND THE CORRECTION IS
-- NOT COSMETIC. `Ident` has no identity-less inhabitant by design, and this
-- table is read on the FLAT driver path as well as the module path
-- (`checkGradedImplTys` ← `checkBodyImpl`, shared by both arms), where every
-- user declaration is `OriginUnresolved` until #1115. An `Ident`-only key
-- would have silently stopped registering and looking up anything there — see
-- `RegKey`'s own doc-comment for the full derivation. The remaining four rows
-- are stated as A-2.0 sized them; the unit that converts each owes the same
-- question ("is this table read on the flat path?") rather than inheriting
-- this row's answer.
--
-- 🚨 THE FIFTH ROW IS `[Option Ident]`, NOT `[Ident]`, AND THE DIFFERENCE
-- RE-OPENS #607. This row read `Ident × [Ident]` until round 2 of this PR's
-- review; that shape is not merely imprecise, it is a live conflation hazard,
-- so the derivation is spelled out here rather than left to the next unit.
-- The key today is (`types/typecheck.mdk:15171`):
--
--     let key = joinWith "," (iface :: map (o2 => fromOption "" (headTyconMono o2)) occs)
--
-- `headTyconMono : Mono -> Option String`, so a POSITION CAN BE ABSENT and
-- the `""` is a POSITIONAL PLACEHOLDER, not a name. Absent positions really
-- do reach this key on the dedup channel: `checkOneCallObligation` has an
-- explicit `else if not (allConcreteHeads args)` arm (`:15214-15215`) which
-- on the CALL channel (`dedup=True`) runs `checkUndeterminedObligations`, so
-- a non-ground obligation is checked AND its key is added to `seen`.
--
-- Concrete failure the `[Ident]` shape invites. Take `interface Ix a b` and
-- two CALL-channel obligations `Ix Int b0` (argument 1 undetermined) and
-- `Ix a0 Int` (argument 0 undetermined). Today the keys are `"Ix,Int,"` and
-- `"Ix,,Int"` — DISTINCT, so both get an ambiguity diagnostic. Convert to
-- `regKeyN (ifaceIdent :: presentHeads)` — which is what `Ident × [Ident]`
-- implies, since an `Ident` cannot be absent — and both become the SAME
-- `RegKey`; the `dedup && contains key seen` guard skips the second and ONE
-- DIAGNOSTIC IS SILENTLY LOST. That is exactly the conflation the
-- whole-vector key was introduced to prevent (`typecheck.mdk:15161-15163`,
-- #607), re-introduced by a key shape that cannot express absence.
--
-- ENCODING, so the next unit does not have to re-derive one. Absence is
-- positional, so carry the positions in the ordinal block, which is what it
-- is for:
--
--     regKeyNAt (ifaceIdent :: presentHeads) (arity :: presentIndices)
--
-- where `presentHeads` are the identities of the positions whose
-- `headTyconMono` was `Some`, in argument order, and `presentIndices` are
-- those positions' 0-based indices. Injective: `regKeyRender` already reads
-- the ident count, then exactly `4n` netstrings, then ordinals, so the two
-- blocks never interfere. On the example, `Ix Int b0` renders with ordinals
-- `[2, 0]` and `Ix a0 Int` with `[2, 1]` — different keys, both diagnostics
-- kept. The `arity` element is not decoration: WITHOUT it the encoding is
-- injective only if an interface's arity is fixed, which is true today but is
-- an unstated premise living in another file; with it, injectivity is a
-- property of the encoding alone.
--
-- ⚠️ A SECOND ABSENCE, in the same row, from a different cause. Turning a
-- `headTyconMono` name into an `Ident` needs that head's `TyConOrigin` —
-- `Mono`'s `TCon String TyConOrigin` carries one — and on the FLAT
-- single-file path it is `OriginUnresolved`, so `mkIdent` returns `None`
-- there for a position whose head IS concrete. So `Option` in this row covers
-- two distinct facts: "this argument has no head type constructor" and "this
-- head has no module identity yet". The conversion must not collapse them
-- into one placeholder: the first is a property of the obligation and must
-- key differently per position (above); the second is the Module-path-only
-- residual `Ns`' doc-comment in `frontend/ast.mdk` states, and on the flat
-- path this table simply keeps its string key until #1115 (E-1).
--
-- `regKeyRender`'s injectivity, in one line: the leading netstring is the
-- IDENT COUNT `n`, so a decoder reads `n`, then exactly `4n` netstrings (the
-- identity block), and everything after is ordinals. No reading depends on
-- what any tag or name happens to look like.
--
-- ⚠️ THE COUNT PREFIX IS DEFENSE IN DEPTH, AND IT HAS NO BEHAVIOURAL WITNESS
-- — verified by mutation, not asserted. Deleting it leaves the render
-- injective ANYWAY today, because the alternative reading (an ordinal
-- netstring mistaken for the start of an identity group) would need some
-- `nsTag` to be a decimal-digit string, and none is. MEASURED 2026-08-03:
-- deleting the prefix left every PROPERTY-level doctest in this file passing
-- (76/76 at the time), which is why the three `startsWith "1:…"` assertions
-- below were added — they are the only thing that reds it. RE-MEASURED on the
-- round-2 file (93 doctests): deleting the prefix gives 90/93, and the three
-- failures are exactly those three lines. So the
-- prefix buys exactly one thing: it makes injectivity independent of
-- `nsTag`'s alphabet, an invariant that otherwise lives silently in a
-- different function and that a seventh namespace could break without any
-- signal. It is kept for that reason, and those three doctests exist solely
-- because no property-level test can distinguish its presence.
--
-- ⚠️ COUNTING THE BYTE-SHAPE ASSERTIONS: they fall in two groups with two
-- different jobs, and earlier cuts of this file variously called them "three",
-- "the ONE doctest" (in one case immediately above three of them), and "FIVE"
-- — that last one written by this very paragraph, in the same breath as its
-- own instruction not to encode a count, and stale one unit later.
-- `startsWith "1:…"` lines pin the ident-COUNT prefix, described in this
-- paragraph; `identKey … == "…"` and `tabKeyRender (TkBare …)` lines pin the
-- origin/bare TAG, described at their own sites further down (A-2.4 added one
-- of each: a count-prefix line on a `TabKey`-built key, and `tabKeyRender
-- (TkBare NsType "Foo") == "4:type4:bare0:3:Foo"`). All are the documented
-- exception to the opacity contract above. DERIVE the count, never re-encode
-- it — and match `TkBare`, not the wider `Tk`, which also catches the
-- identity-arm PROPERTY line (`tabKeyRender (TkIdent …) == identKey …`) that
-- asserts no bytes at all:
-- `grep -c '^-- > \(startsWith "1:\|identKey ident.* == "\|tabKeyRender (TkBare\)' `
-- this file.
--
-- ── `regInsert` conflict handling (decided for THIS unit only) ─────────────
-- Per `docs/spec/DICT-SEMANTICS.md` §8 I4, declarations are never rejected —
-- only USE sites are — so once every table is keyed by `Ident`, two
-- genuinely distinct declarations get genuinely distinct identities and
-- coexist; a `regInsert` collision after re-keying means the REGISTRY'S OWN
-- KEYING is broken (a compiler bug), not a user error to diagnose at the
-- declaration. `regInsert` is therefore LAST-WRITE-WINS, matching every
-- existing `universe*` table's current behavior, and `regInsertChecked`
-- returns a `Bool` alongside the new registry saying whether an existing
-- entry under that exact key was overwritten — the signal a later unit
-- (A-2.8) can turn into a diagnostic once the diagnostic-code family
-- question (`T-INTERNAL-REGISTRY-CONFLICT` vs. a resolve-phase
-- `R-AMBIGUOUS-*` code) is settled. Deliberately NOT decided here.
-- ⚠️ So `Registry` is a LAST-WRITE-WINS map, and it must not be described as
-- a "write-once-or-diagnose" one. The first cut of this file used that
-- phrase as `Registry`'s own one-line header, thirty lines below the
-- paragraph saying the diagnostic is undecided: it is lifted from the design
-- doc's description of what A-2 will EVENTUALLY deliver, and a reader who
-- greps the header gets the opposite of the code.
--
-- ── What a conversion still has to review, table by table (NOT "pure") ─────
-- 🚨 A re-keying is NOT automatically behavior-preserving, and the first cut
-- of this file claimed it was ("a pure re-keying with no behavior change to
-- also review"). That is an unevidenced universal and it is FALSE for at
-- least one named target: `regEntries` enumerates in `regKeyRender` order (a
-- sorted `OrdMap`), while several targets are assoc `List`s enumerated in
-- DECLARATION order — `rejectCyclicAliases` (`types/typecheck.mdk`) walks
-- its alias table in that order and `emitCyclicAliasErrors` emits in the
-- order the DFS produced, so converting it moves DIAGNOSTIC ORDER and hence
-- goldens. Every conversion PR owes an explicit answer to "does any consumer
-- of this table depend on its enumeration order?", and where the answer is
-- yes it owes either an order-preserving side list or a reviewed golden
-- move. What IS preserved by construction is the last-write-wins RESOLUTION
-- of a duplicate key, not the ORDER a whole-table walk produces.

-- ⚠️ `IdentOrigin` is imported WITHOUT `(..)` — its constructors are private
-- to `frontend/ast.mdk` so that `IdentModule ""` is unrepresentable (see the
-- type's doc-comment there).  `identOriginFold` is the eliminator, and
-- `mkIdent`/`identOriginBuiltin` are the only mints.
import frontend.ast.{
  Ns(..),
  Ident(..),
  IdentOrigin,
  TyConOrigin(..),
  identOriginOf,
  identOriginFold,
  identOriginBuiltin,
  mkIdent,
}
import support.ordmap.{
  OrdMap,
  omEmpty,
  omInsert,
  omLookup,
  omHasKey,
  omDelete,
  omSize,
}
import support.util.{lenKey, listLen, joinWith, filterList, startsWith}
-- ⚠️ `sort` looks unused — it is reached ONLY from the `mregMerge`/`mregAdd`
-- doctests, which compare multi-registry buckets as multisets. MEASURED
-- 2026-08-03: deleting this line does NOT fail `medaka check`; it fails at
-- doctest RUN time with `runtime error [E-PANIC]: unbound constrained fn:
-- sort`. So the only thing standing between this import and a silent
-- "tidy-up" deletion is `make test` actually running this file's doctests —
-- which is exactly why `Makefile`'s `test:` target now names this module.
import list.{sort}
import map.{toList}

-- ── identKey ─────────────────────────────────────────────────────────────

nsTag : Ns -> String
nsTag NsType = "type"
nsTag NsIface = "iface"
nsTag NsMethod = "method"
nsTag NsCtor = "ctor"
nsTag NsField = "field"
nsTag NsValue = "value"

-- ⚠️ `IdentOrigin` has no "unresolved" inhabitant and no empty-module
-- inhabitant BY CONSTRUCTION (see its doc-comment in `frontend/ast.mdk`),
-- which is what stops this renderer from mapping a whole population onto one
-- constant key. Both arms below name a real origin, and `identOriginFold` is
-- total, so neither can be forgotten.
originTag : IdentOrigin -> String
originTag origin = identOriginFold "builtin" (_ => "module") origin

-- The `""` here is NOT the forbidden empty module id — it is the builtin
-- arm's contribution to a FIXED-WIDTH four-netstring group, and `lenKey ""` =
-- `"0:"` is a real netstring. No `IdentOrigin` can carry `""` as a module id,
-- so `originModuleOf` returning `""` identifies the builtin arm unambiguously.
originModuleOf : IdentOrigin -> String
originModuleOf origin = identOriginFold "" (m => m) origin

-- The one renderer — see the module doc-comment above for the collision
-- argument. Treat the result as OPAQUE. EXACTLY FOUR netstrings, always.
export identKey : Ident -> String
identKey (Ident ns origin name) = lenKey (nsTag ns)
  ++ lenKey (originTag origin)
  ++ lenKey (originModuleOf origin)
  ++ lenKey name

-- The `TabKey` renderer — `TkIdent` is `identKey` verbatim, so an
-- identity-bearing key renders exactly as it did before A-2.4 widened
-- `RegKey`'s identity block. The `TkBare` arm is the OTHER half of `tabKeyEq`'s
-- "never equate a
-- `TkIdent` with a `TkBare`" rule, expressed in the rendering rather than in a
-- comparator, because `Registry` compares RENDERED keys inside an `OrdMap`
-- and would otherwise have no way to tell the two halves apart.
--
-- ⚠️ ALSO EXACTLY FOUR NETSTRINGS, and the middle slot is `"bare"`, which
-- `originTag` can never produce (`identOriginFold "builtin" (_ => "module")`
-- is total and its two results are the only strings that arm can yield). So:
--   * `regKeyRender`'s injectivity argument survives verbatim — every element
--     is still a fixed group of four netstrings, so the leading key-COUNT
--     prefix still separates the identity block from the ordinal block with
--     no assumption about any tag or name spelling; and
--   * no `TkBare` render can EQUAL a `TkIdent` render, because they differ in
--     the second netstring for every possible `ns`/`name`. A bare-keyed row
--     and an identity-keyed row of the same spelling are therefore distinct
--     `OrdMap` entries — the structural exclusion A-2.3 wrote into `tabKeyEq`,
--     re-derived here for the rendered path.
-- The empty third netstring is the same fixed-width filler `identKey`'s
-- builtin arm uses (`lenKey "" = "0:"` is a real netstring); it is not a
-- module id, forbidden or otherwise.
export tabKeyRender : TabKey -> String
tabKeyRender (TkIdent ident) = identKey ident
tabKeyRender (TkBare ns name) = lenKey (nsTag ns)
  ++ lenKey "bare"
  ++ lenKey ""
  ++ lenKey name

-- A tuple of identities, rendered by plain concatenation. Injective on its
-- own: each element contributes exactly four netstrings, so a stream of `4n`
-- netstrings decodes to exactly one list, and two lists of different length
-- render to strings of different length.
export identKeys : List Ident -> String
identKeys idents = joinWith "" (map identKey idents)

-- The `TabKey` peer of `identKeys`, and the one `regKeyRender` actually calls.
-- Same argument: four netstrings per element, on BOTH `TabKey` arms.
export tabKeys : List TabKey -> String
tabKeys keys = joinWith "" (map tabKeyRender keys)

ordKey : Int -> String
ordKey n = lenKey "\{n}"

-- ── RegKey: what a registry is keyed BY ───────────────────────────────────
-- Identity components first, then ORDINAL components (a parameter slot, an
-- arity index) — things that are genuinely not declarations and so have no
-- namespace and no origin. See "What the target tables need" above for the
-- five tables that need this and for why an ordinal is not smuggled into an
-- `Ident`'s name field.
--
-- 🚨 A-2.4 WIDENED THE IDENTITY BLOCK FROM `List Ident` TO `List TabKey`, and
-- the reason is a composition gap between two earlier units rather than a
-- preference. A-2.0 sized this type against the five composite-key target
-- tables and used `Ident`, which has no identity-less inhabitant BY DESIGN
-- (`IdentOrigin`, `frontend/ast.mdk` — that is I6.3's "the absent case must be
-- unrepresentable"). A-2.3 then established, for the tables it converted, that
-- a real conversion ALSO needs the identity-LESS half — `TkBare` — because on
-- the flat/single-file driver path every USER declaration carries
-- `OriginUnresolved` until #1115 (E-1), and a table read on BOTH driver paths
-- must be able to key both populations. It landed that as `TabKey`, on the
-- assoc-list side only; `RegKey` never composed with it.
--
-- TWO UNITS NEEDED IT, AND BOTH MOTIVATING TABLES ARE NAMED ON PURPOSE — the
-- widening is not one table's special case:
--
--   * A-2.4's `universeIfaceParamKinds` is the first table that needs BOTH at
--     once: it is keyed by (interface × parameter slot) — so it needs the
--     ordinal block, which only `RegKey` has — and it is read by
--     `checkGradedImplTys`, reached from `checkBodyImpl`, which is shared by
--     the Flat and Module arms — so it needs the bare half. Keying it by
--     `Ident` alone would have SILENTLY DISABLED the graded instance-head kind
--     check on the flat path (every flat user interface would fail to mint a
--     key, so nothing would be registered and nothing looked up, and
--     `checkGradedImplTys` abstains on a miss). That is the `loud → silent`
--     regression `AGENTS.md` grades as a severity INCREASE, and it is invisible
--     to every golden, because a check that stops firing moves no output that
--     any fixture asserts.
--   * A-2.2b's is every dispatch key below — the `obUniv*` accumulators (whose
--     buckets are `ImplUniverse`'s; the refs themselves were retired by #1112
--     A-3.4 PR2), `KeyBuckets`, `checkCallObligationsU`'s dedup key — each of which projects a head
--     through `headTyconTy`/`headTyconMono`, and those projections answer
--     `TkBare` on the flat path for exactly the reason A-2.3 gives. Keying them
--     by `Ident` alone is not merely lossy, it is unconstructible.
--
-- ⚠️ THE TWO UNITS LANDED SEPARATELY AND THEIR MINTS ARE A UNION, NOT A CHOICE.
-- A-2.4 (#1270) contributed `regKeyTabAt`; A-2.2b (#1274) contributed
-- `regKeyNTab` and `regKeyNTabAt`; `git`'s conflict puts all three in ONE hunk,
-- so "take either side" would have deleted a mint that has live callers. All
-- three are below. Whoever holds the next conflict in this block owes the same
-- discipline — union the mints, reconcile the prose.
--
-- The widening is answer-preserving for identity-bearing keys: `regKeyOf`,
-- `regKeyN`, `regKeyAt` and `regKeyNAt` still take `Ident`s and wrap them in
-- `TkIdent`, whose render is `identKey` unchanged.
--
-- 🚨 WHAT THE IDENTITY BLOCK MAY NOT HOLD, and it is not a style rule.
-- `HeadKey`'s `HkRigid` arm (below) is NOT a `TabKey` and must never become
-- one: `docs/spec/DICT-SEMANTICS.md` §8 I6.1 says a rigid type variable is not
-- a declaration and must not be assigned an identity, and A-2.2's whole reason
-- for splitting `HkRigid` out of `TabKey` was that folding it in would destroy
-- A-1's greppability. A dispatch key whose positions can be rigid therefore
-- carries the rigid positions OUTSIDE this type — see `dispKeyRender` below.
public export data RegKey =
  | RegKey (List TabKey) (List Int)
deriving (Eq, Ord, Debug)

-- The one-identity case — by far the most common, and the shape the
-- `Ident`-taking convenience wrappers below all go through.
export regKeyOf : Ident -> RegKey
regKeyOf ident = RegKey [TkIdent ident] []

-- An identity TUPLE (`ImplUniverse`'s concrete bucket, `ifaceDispatchRef`,
-- `checkCallObligationsU`'s dedup key).
export regKeyN : List Ident -> RegKey
regKeyN idents = RegKey (map TkIdent idents) []

-- An identity plus an ordinal (`universeIfaceParamKinds`' `<iface>@<slot>`).
export regKeyAt : Ident -> Int -> RegKey
regKeyAt ident slot = RegKey [TkIdent ident] [slot]

-- Identity tuple PLUS ordinals — the shape `checkCallObligationsU`'s dedup key
-- needs, and the reason it exists: that key's argument vector has ABSENT
-- positions (`Ident × [Option Ident]`, see "What the target tables need"), and
-- the only way to keep two vectors that differ in WHICH position is absent on
-- different keys is to carry the present positions' indices alongside the
-- present identities. Neither `regKeyN` (no ordinals) nor `regKeyAt` (one
-- ident, one ordinal) can express that, so the conversion would otherwise
-- have had to spell `RegKey` by hand and re-derive the injectivity argument.
export regKeyNAt : List Ident -> List Int -> RegKey
regKeyNAt idents ords = RegKey (map TkIdent idents) ords

-- ── The `TabKey`-taking mints (A-2.4 + A-2.2b) ────────────────────────────
-- The four above are the `Ident`-only conveniences; these are what a
-- conversion whose site may or may not have identity calls, having minted its
-- key through `tabKeyOf` (the ONE total mint). A site that CAN prove it has
-- identity should still prefer the `Ident` forms — `regKeyOfTab (TkIdent i)`
-- and `regKeyOf i` are the same key, but the latter says so in the type.
export regKeyOfTab : TabKey -> RegKey
regKeyOfTab key = RegKey [key] []

-- `universeIfaceParamKinds`' (interface × slot) key, in the shape that keeps
-- the slot an ORDINAL rather than text spliced into a name. This is the direct
-- replacement for `ifaceSlotKey`'s `"\{iface}@\{i}"` (`types/typecheck.mdk`).
export regKeyTabAt : TabKey -> Int -> RegKey
regKeyTabAt key slot = RegKey [key] [slot]

-- The `TabKey` peer of `regKeyN` — an identity TUPLE whose members may or may
-- not carry identity. `ImplUniverse`'s concrete bucket `(interface, receiver head)`
-- pair is the first table that needs it: its interface half is bare by derivation
-- (`Predicate` carries no origin — see `builtinClassPresent` in
-- `types/typecheck.mdk`, and the `ifaceRegistered` TOMBSTONE beside it: #1539
-- retired that gate, so cite the live name) while its head half is whatever `headTyconTy`
-- projected, so ONE key genuinely mixes the two populations.
export regKeyNTab : List TabKey -> RegKey
regKeyNTab keys = RegKey keys []

-- The `TabKey` peer of `regKeyNAt` — an identity TUPLE plus ordinals, which is
-- what a key over a whole ARGUMENT VECTOR needs: the ordinal block carries the
-- vector's arity and the indices of the positions the identity block came
-- from, so two vectors differing only in WHICH position is absent stay apart
-- (#607). `checkCallObligationsU`'s dedup key is the first user.
export regKeyNTabAt : List TabKey -> List Int -> RegKey
regKeyNTabAt keys ords = RegKey keys ords

export regKeyTabs : RegKey -> List TabKey
regKeyTabs (RegKey keys _) = keys

export regKeyOrdinals : RegKey -> List Int
regKeyOrdinals (RegKey _ ords) = ords

-- OPAQUE, exactly as `identKey` is. The leading key-count netstring is what
-- makes the identity block and the ordinal block unambiguously separable
-- without assuming anything about tag or name spellings.
export regKeyRender : RegKey -> String
regKeyRender (RegKey keys ords) = lenKey "\{listLen keys}"
  ++ tabKeys keys
  ++ joinWith "" (map ordKey ords)

-- ── Registry: LAST-WRITE-WINS map from a RegKey to ONE value ──────────────
-- Stores the ORIGINAL `RegKey` alongside each value (not just its rendered
-- key) so `regEntries` can hand identities back out without ever parsing
-- `regKeyRender`'s opaque output.
public export data Registry v = Registry (OrdMap (RegKey, v))

export regEmpty : Registry v
regEmpty = Registry omEmpty

export regLookupK : RegKey -> Registry v -> Option v
regLookupK k (Registry m) = map ((_, v) => v) (omLookup (regKeyRender k) m)

export regLookup : Ident -> Registry v -> Option v
regLookup ident r = regLookupK (regKeyOf ident) r

-- ⚠️ `regKeyRender k` is bound ONCE. Medaka is strict, so the two-call form
-- evaluates the projection TWICE, and this projection BUILDS a string —
-- `support/util.mdk`'s `dedupBy` carries the same warning verbatim for the
-- same reason, and `check` is GC-bound. The first cut of this file called
-- `identKey ident` twice here.
export regInsertCheckedK : RegKey -> v -> Registry v -> (Registry v, Bool)
regInsertCheckedK k v (Registry m) =
  let s = regKeyRender k
  (Registry (omInsert s (k, v) m), omHasKey s m)

export regInsertChecked : Ident -> v -> Registry v -> (Registry v, Bool)
regInsertChecked ident v r = regInsertCheckedK (regKeyOf ident) v r

-- ⚠️ NOT `fst (regInsertCheckedK …)`: that form did the `omHasKey` tree walk
-- and threw the answer away. The overwrite signal costs a lookup, so the
-- caller who does not want it does not pay for it.
export regInsertK : RegKey -> v -> Registry v -> Registry v
regInsertK k v (Registry m) = Registry (omInsert (regKeyRender k) (k, v) m)

export regInsert : Ident -> v -> Registry v -> Registry v
regInsert ident v r = regInsertK (regKeyOf ident) v r

export regDeleteK : RegKey -> Registry v -> Registry v
regDeleteK k (Registry m) = Registry (omDelete (regKeyRender k) m)

export regDelete : Ident -> Registry v -> Registry v
regDelete ident r = regDeleteK (regKeyOf ident) r

-- Enumeration order is `regKeyRender` order (a sorted `OrdMap`), which is
-- NEITHER declaration order NOR alphabetical by name — see "What a conversion
-- still has to review" in the module doc-comment. It IS deterministic.
export regEntries : Registry v -> List (RegKey, v)
regEntries (Registry m) = map snd (toList m)

-- Symmetry with `mregKeys`/`sregKeys`. Derivable (`map fst (regEntries r)`),
-- added anyway because an API where two of three registry types can enumerate
-- their keys and the third cannot is a papercut every conversion pays, and
-- because a caller who wants only the keys should not have to know that the
-- values come along for free. Same order caveat as `regEntries`.
export regKeys : Registry v -> List RegKey
regKeys r = map fst (regEntries r)

export regSize : Registry v -> Int
regSize (Registry m) = omSize m

-- The bulk-delete `rejectCyclicAliases` (`types/typecheck.mdk`) needs: it
-- enumerates the alias table, computes a cyclic set, then rebuilds the table
-- without those entries. The predicate takes the whole `(key, value)` pair
-- so it drops straight into `filterList`'s shape, matching the existing site.
export regFilter : ((RegKey, v) -> Bool) -> Registry v -> Registry v
regFilter p r = regFromEntries (filterList p (regEntries r))

-- Last entry wins on a duplicate key, matching `regInsert`.
export regFromEntries : List (RegKey, v) -> Registry v
regFromEntries entries = regFromEntriesGo entries regEmpty

regFromEntriesGo : List (RegKey, v) -> Registry v -> Registry v
regFromEntriesGo [] acc = acc
regFromEntriesGo ((k, v)::rest) acc = regFromEntriesGo rest (regInsertK k v acc)

-- Whole-table copy, the `perRun` ↔ `crossRun` shape (`types/typecheck.mdk`
-- copies whole tables between the two in both directions). RIGHT-BIASED: an
-- entry in `newer` wins over the same key in `older`, which is what a
-- last-write-wins table's copy has always meant.
export regMerge : Registry v -> Registry v -> Registry v
regMerge older newer = regFromEntriesGo (regEntries newer) older

-- ── MultiRegistry: explicitly commutative — no entry can be lost to order ──
-- Unlike `Registry`, `mregAdd` never overwrites: every value ever added under
-- a key is kept, so which order two calls happen in cannot make one
-- registration disappear (the failure mode `Registry`'s last-write-wins
-- accepts on purpose). The internal LIST order under one key may still
-- differ by call order — the "order-free" guarantee is about completeness
-- (nothing is dropped), not about the enumeration order of `mregLookup`'s
-- result.
public export data MultiRegistry v = MultiRegistry (OrdMap (RegKey, List v))

export mregEmpty : MultiRegistry v
mregEmpty = MultiRegistry omEmpty

export mregAddK : RegKey -> v -> MultiRegistry v -> MultiRegistry v
mregAddK k v (MultiRegistry m) =
  let s = regKeyRender k
  match omLookup s m
    Some (_, vs) => MultiRegistry (omInsert s (k, v::vs) m)
    None => MultiRegistry (omInsert s (k, [v]) m)

export mregAdd : Ident -> v -> MultiRegistry v -> MultiRegistry v
mregAdd ident v mr = mregAddK (regKeyOf ident) v mr

-- ⚠️ APPEND, not `mregAddK`'s prepend, and the difference is load-bearing for
-- ONE of the two buckets that needs it. Attributing it to both overstates it, so
-- name which is which.
--
-- 🚨 ANCHOR: the two buckets are `ImplUniverse`'s, written by `insertUnivImplAt`
-- (`types/typecheck.mdk`). Until #1112 A-3.4 PR2 this paragraph named their
-- CARRIERS instead — the `obUnivConcreteRef`/`obUnivHeadlessRef` `CrossRun`
-- accumulators — and those three fields are now DELETED: the Module path's
-- universe is a projection of stage K's `IE` (`ieUniverseAt`, selecting from the
-- per-ordinal `ieUnivSnaps`), and the Flat path still calls `buildImplUniverse`.
-- The property below is unchanged and still live; only the names it can be
-- grepped by moved, from the retired refs to the value they held.
--
--   * the HEADLESS bucket (`univHeadless`) — THIS is the first-match reader.
--     `findMatchingImplReqsU` reaches it directly, on both its clauses, as
--     `firstReqMatch (univHeadless …)`, and its own doc-comment records that
--     the order is a deliberate soundness/conformance property and not an
--     order-immaterial coherence argument. A prepend here would silently
--     invert which impl's `requires` get discharged.
--   * the CONCRETE bucket (`univConcreteBucket`) — NOT read first-match, and not
--     read by `findMatchingImplReqsU` at all. That function's concrete arm goes
--     through `concreteReqMatchByIface` → `ieSelectRowByIface`, which reads
--     `bodyImplEnvRef` — a DIFFERENT table (and a DIFFERENT population: ARCH
--     B-2.1-b2 repointed this leg off the topological-prefix `shadowKeyTableRef`
--     onto the graph-global `IE`; the order argument here is unaffected, since
--     neither table is this bucket). The concrete bucket's own
--     readers are `univConcreteBucket`'s two, `implMatchesU` and
--     `implMatchesReceiverU`, and both are boolean EXISTENCE tests
--     (`bucketArgsMatch`/`bucketRecvMatch`, `||`-folded), for which bucket
--     order is immaterial.
--
-- ⚠️ A-3.4 PR2 ADDED A THIRD WRITER OF THE SAME ORDER PROPERTY, so it is now a
-- SET of three and not a pair: `ieBuildSnapsGo` folds `insertUnivImpl` over the
-- ordinal-ordered `ieRows` to build each prefix snapshot. It reaches this same
-- append through `insertUnivImplAt`, so the order is preserved by construction
-- rather than by a second spelling — but a future edit that gives `IE` its own
-- insert path owes this paragraph a re-read.
--
-- Both writers have always spelled `bucketOf k ++ [x]`; this is that spelling,
-- once, inside the abstraction, at the same O(bucket) cost per add. Keeping the
-- concrete side on it too is deliberate — the two accumulators are written by
-- one pass and reading them as a pair is easier than reasoning about why one
-- prepends — but it is a CONSISTENCY choice, not a correctness one.
--
-- `mregAddK` stays the default: a bucket whose order genuinely does not matter
-- should pay O(1), and a caller reaching for THIS one is asserting that its
-- bucket order is semantic. Say which in the call site's comment.
export mregAppendK : RegKey -> v -> MultiRegistry v -> MultiRegistry v
mregAppendK k v (MultiRegistry m) =
  let s = regKeyRender k
  match omLookup s m
    Some (_, vs) => MultiRegistry (omInsert s (k, vs ++ [v]) m)
    None => MultiRegistry (omInsert s (k, [v]) m)

export mregLookupK : RegKey -> MultiRegistry v -> List v
mregLookupK k (MultiRegistry m) = match omLookup (regKeyRender k) m
  Some (_, vs) => vs
  None => []

export mregLookup : Ident -> MultiRegistry v -> List v
mregLookup ident mr = mregLookupK (regKeyOf ident) mr

-- `MultiRegistry` had NO enumeration at all in this file's first cut, so a
-- conversion could write a table it could never walk. Same order caveat as
-- `regEntries`.
export mregEntries : MultiRegistry v -> List (RegKey, List v)
mregEntries (MultiRegistry m) = map snd (toList m)

export mregKeys : MultiRegistry v -> List RegKey
mregKeys mr = map fst (mregEntries mr)

-- Number of DISTINCT keys, not the total number of values added.
export mregSize : MultiRegistry v -> Int
mregSize (MultiRegistry m) = omSize m

-- Bucket-CONCATENATING union: no value from either side is dropped, which is
-- the invariant that makes this type worth having. `newer`'s values for a
-- shared key are prepended, matching `mregAdd`'s own prepend.
export mregMerge : MultiRegistry v -> MultiRegistry v -> MultiRegistry v
mregMerge older newer = mregMergeGo (mregEntries newer) older

mregMergeGo : List (RegKey, List v) -> MultiRegistry v -> MultiRegistry v
mregMergeGo [] acc = acc
mregMergeGo ((k, vs)::rest) acc = mregMergeGo rest (mregAddAll k vs acc)

mregAddAll : RegKey -> List v -> MultiRegistry v -> MultiRegistry v
mregAddAll _ [] acc = acc
mregAddAll k (v::vs) acc = mregAddAll k vs (mregAddK k v acc)

-- ── SetRegistry: membership only ──────────────────────────────────────────
-- Stores the `RegKey` as its value so the set can be ENUMERATED, which
-- `implCountForIfaceU`-shaped consumers (`omSize` today) and any "did you
-- mean" candidate list need.
public export data SetRegistry = SetRegistry (OrdMap RegKey)

export sregEmpty : SetRegistry
sregEmpty = SetRegistry omEmpty

export sregAddK : RegKey -> SetRegistry -> SetRegistry
sregAddK k (SetRegistry m) = SetRegistry (omInsert (regKeyRender k) k m)

export sregAdd : Ident -> SetRegistry -> SetRegistry
sregAdd ident s = sregAddK (regKeyOf ident) s

export sregMemberK : RegKey -> SetRegistry -> Bool
sregMemberK k (SetRegistry m) = omHasKey (regKeyRender k) m

export sregMember : Ident -> SetRegistry -> Bool
sregMember ident s = sregMemberK (regKeyOf ident) s

-- `implCountForIfaceU` (`types/typecheck.mdk`) is `omSize` over a per-iface
-- tag set; it could not be written against this type without this.
export sregSize : SetRegistry -> Int
sregSize (SetRegistry m) = omSize m

export sregKeys : SetRegistry -> List RegKey
sregKeys (SetRegistry m) = map snd (toList m)

export sregMerge : SetRegistry -> SetRegistry -> SetRegistry
sregMerge older newer = sregMergeGo (sregKeys newer) older

sregMergeGo : List RegKey -> SetRegistry -> SetRegistry
sregMergeGo [] acc = acc
sregMergeGo (k::rest) acc = sregMergeGo rest (sregAddK k acc)

-- ── TabKey: the key for a table that KEEPS its assoc-list representation ──
-- The three registries above replace a table's REPRESENTATION as well as its
-- key. `TabKey` is for the conversions that must keep the assoc list and
-- change ONLY the key, and A-2.3 (`universeAliasTable`,
-- `universeDataParamKinds`, `types/typecheck.mdk`) is the first of them.
-- Two independent reasons, both measured or cited rather than asserted:
--
-- ⚠️ "THE CONVERSIONS THAT KEEP THE ASSOC LIST" IS WHY THIS TYPE EXISTS, NOT
-- THE SET OF THINGS THAT USE IT — and that set grows. `HeadKey` below embeds a
-- `TabKey` as its declaration half and is not an assoc-list conversion at all.
-- Derive the users rather than reading them off this paragraph:
--
--   grep -nw TabKey compiler/types/*.mdk | grep -vE ':[[:space:]]*--'
--
--   * ALLOCATION. `Registry` keys on `regKeyRender`, so every LOOKUP would
--     build a fresh `String` (four netstrings, concatenated), UNCONDITIONALLY
--     and on every call — REJECTED for that reason. Those two tables are read
--     from `fromAstTypeApp`/`fromAstTypeE`/`headRemainingKinds` — once or more
--     per type-application node of every signature the elaborator meets —
--     inside `medaka check`, which `compiler/AGENTS.md` measures as GC-BOUND
--     (libgc 62% of a real `check`, no `mdk_` symbol above 0.8%). That file's
--     "the exception that IS one" section is this exact shape: migrating a
--     `List` scan whose KEY PROJECTION ALLOCATES measured 9.33×–14.96× MORE
--     allocation at every n tested, with no crossover, and BOTH perf CI arms
--     structurally blind to it.
--     ⚠️ **`TabKey` COMPARISON allocates nothing — true, and beside the
--     point: comparison was never where allocation moved, the MINT is.**
--     `tabKeyOf` → `mkIdent` → `identOriginOf` allocates on the way (an
--     `Option (IdentModule mid)`, the `map` closure over it, the `Ident`
--     record, the `Some`/`None`, then the `TkIdent`/`TkBare` wrapper) every
--     time a caller mints a key — and the two hottest readers
--     (`fromAstTypeApp`, `headRemainingKinds`, `types/typecheck.mdk`) each
--     minted it TWICE per node, once per table lookup, until hoisted to a
--     single shared binding (#1111 A-2.3 follow-up). The design chosen here
--     is cheaper than `Registry`'s render-per-LOOKUP cost (paid every call,
--     uncached), not free — price the alternative that was rejected AND the
--     one that was picked, not only the former.
--   * ENUMERATION ORDER. See the "NO ordered/insertion-order enumeration"
--     bullet below: `rejectCyclicAliases` + `emitCyclicAliasErrors`
--     (`types/typecheck.mdk`) depend on the alias table's enumeration order,
--     and that bullet names A-2.3's PR as the place to answer it. Keeping the
--     list answers it by construction — the order is the one that was there.
--
-- ⚠️ `TkBare` is NOT a fallback the identity path may reach. It is the key an
-- identity-LESS site mints, and `tabKeyEq` never equates it with a `TkIdent`,
-- so a module-path lookup can neither hit nor be hit by a bare-name row. That
-- separation is the whole point: a `TkIdent`-keyed lookup that misses MISSES,
-- exactly as a bare-name lookup misses today for a builtin.
--
-- `TkBare` carries its `Ns` for the same reason `Ident` does — so that a
-- future table holding more than one namespace cannot collide a bare type
-- name with a bare method name of the same spelling.
public export data TabKey =
  | TkIdent Ident
  | TkBare Ns String
deriving (Eq, Ord, Debug)

-- The ONE total mint. `mkIdent` answers "does this origin carry identity?";
-- `None` is honest absence (an `OriginUnresolved` head on the flat/
-- single-file driver path, or the `OriginModule ""` §8 I6.3 refuses), and it
-- lands in the `TkBare` half rather than being smuggled into a shared key.
export tabKeyOf : Ns -> TyConOrigin -> String -> TabKey
tabKeyOf ns origin name = match mkIdent ns origin name
  Some ident => TkIdent ident
  None => TkBare ns name

-- The BARE name inside a key, for the residual consumers that genuinely ask a
-- name question rather than an identity question (`noImplHint`'s
-- "is any user-declared type called this?", `rejectCyclicAliases`' name-keyed
-- dependency graph). Marked at each such call site; never used to build a
-- lookup key.
export tabKeyName : TabKey -> String
tabKeyName (TkIdent (Ident _ _ name)) = name
tabKeyName (TkBare _ name) = name

-- Monomorphic and short-circuiting on purpose (`compiler/AGENTS.md`): this
-- runs once per entry scanned, on every type-application node.
--
-- ⚠️ NAME FIRST, deliberately — the derived `Eq` would compare in FIELD order
-- (`Ns`, then `IdentOrigin`, then name), which is the least discriminating
-- order available here: within one of these tables every entry shares the
-- namespace and many share a module id, so a name-last comparison does the
-- two cheap-but-useless compares before the one that actually decides. The
-- derived instance is still kept for the doctests below.
tabKeyEq : TabKey -> TabKey -> Bool
tabKeyEq (TkIdent (Ident ns1 o1 n1)) (TkIdent (Ident ns2 o2 n2)) = n1 == n2
  && ns1 == ns2
  && o1 == o2
tabKeyEq (TkBare ns1 n1) (TkBare ns2 n2) = n1 == n2 && ns1 == ns2
tabKeyEq _ _ = False

-- `lookupAssoc`'s `TabKey`-keyed peer: FIRST match wins, so a prepend still
-- shadows (the ordering every reader of those two tables assumes — the
-- module's own decls are registered as a front overlay over the accumulated
-- universe).
export lookupTab : TabKey -> List (TabKey, v) -> Option v
lookupTab _ [] = None
lookupTab k ((k2, v)::rest) = if tabKeyEq k k2 then Some v else lookupTab k rest

-- 🚨 A BARE-NAME MEMBERSHIP TEST, AND IT IS NOT A LOOKUP. It answers "does
-- SOME entry carry this name, under any identity?" and returns no value, so
-- it cannot select the wrong module's row — there is no row to select. Its
-- one consumer is a diagnostic HINT (`noImplHint`, `types/typecheck.mdk`),
-- which asks whether a name is user-declared at all in order to decide
-- whether "add `deriving`" is applicable advice.
export tabHasName : String -> List (TabKey, v) -> Bool
tabHasName _ [] = False
tabHasName n ((k, _)::rest) = tabKeyName k == n || tabHasName n rest

-- ── The COMPOSITE assoc-list half (A-2.4) ─────────────────────────────────
-- `lookupTab`'s peer for a table whose key carries ORDINALS as well as
-- identity, and which keeps its assoc-list representation for the two reasons
-- `TabKey`'s doc-comment above gives (allocation: comparison here builds
-- nothing, while `Registry` renders a fresh `String` per lookup; and
-- enumeration order, which an assoc list preserves by construction).
-- `universeIfaceParamKinds` is the first such table.
--
-- ⚠️ ORDINALS FIRST, and it is the same "least discriminating first is wrong"
-- argument `tabKeyEq` makes for names. Every entry this scans shares the
-- interface's namespace, and within one interface's block every entry shares
-- the identity too — the SLOT is the component that actually decides, so
-- comparing it first short-circuits the common non-match before touching the
-- identity at all.
regKeyEq : RegKey -> RegKey -> Bool
regKeyEq (RegKey k1 o1) (RegKey k2 o2) = intsEq o1 o2 && tabKeysEq k1 k2

intsEq : List Int -> List Int -> Bool
intsEq [] [] = True
intsEq (a::as2) (b::bs) = a == b && intsEq as2 bs
intsEq _ _ = False

tabKeysEq : List TabKey -> List TabKey -> Bool
tabKeysEq [] [] = True
tabKeysEq (a::as2) (b::bs) = tabKeyEq a b && tabKeysEq as2 bs
tabKeysEq _ _ = False

-- FIRST match wins, exactly as `lookupTab` and the `lookupAssoc` it replaces —
-- so a prepend still shadows, which is the overlay ordering
-- `registerIfaceParamKinds` relies on (a module's own decls are registered as a
-- FRONT overlay over the accumulated universe).
export lookupReg : RegKey -> List (RegKey, v) -> Option v
lookupReg _ [] = None
lookupReg k ((k2, v)::rest) = if regKeyEq k k2 then Some v else lookupReg k rest
-- ── HeadKey: the result of projecting a type's HEAD TYPE CONSTRUCTOR ──────
-- Stage A-2 unit A-2.2 (#1111).  `types/typecheck.mdk`'s head projections —
-- `headTyconMono : Mono -> …` (the GOAL side of a dispatch key) and
-- `headTyconTy : Ty -> …` (the IMPL side) — both had `Option String` as their
-- result, so the identity `Mono.TCon`/`Ty.TyCon` already CARRY (Stage A-1) was
-- thrown away at the return type.  This is the type that lets it through.
--
-- 🚨 THE DECLARATION HALF IS `TabKey` ITSELF, NOT A COPY OF IT.  A-2.2 was
-- authored while A-2.3 (#1267) was still open, so its first draft minted its
-- own `HkIdent`/`HkBare` pair; that premise expired when A-2.3 landed, and two
-- near-identical ADTs — two mints, two name projections — in ONE file is a
-- seam every later unit that builds a dispatch key would have to relate at
-- every site.  So a head that IS a declaration is a `TabKey`, and `tabKeyOf`
-- above is the one place the "does this origin carry identity?" question is
-- answered.
--
-- ⚠️ THE ONE REAL DIVERGENCE, AND IT IS PAID ONCE HERE.  `TabKey` carries an
-- `Ns` (inside `TkIdent`'s `Ident`, and directly on `TkBare`) and a head
-- projection has no use for one: the head of a TYPE is always in the TYPE
-- namespace, so that field is redundant-but-always-`NsType` inside every
-- `HkDecl`.  It is fixed at the single mint below — `headKeyOfCon` supplies
-- `NsType` and nothing else may — which is why the unification was chosen over
-- a second ADT whose only difference from this one is an absent field: the
-- redundancy is one constant in one function, where a parallel key type would
-- have to be related to `TabKey` at every future dispatch-key seam.
--
-- 🚨 `None` STILL MEANS ONE THING, and it is not what `TkBare` means.  The
-- projections stay `Option HeadKey` because two absences are not the same
-- fact:
--
--   (1) "this type has no head type constructor at all" — a bare tyvar, a
--       function type, an effect row.  That is what `None` meant before this
--       unit and what it means after, unchanged at every call site.  It is a
--       property of the TYPE.
--   (2) "there is a head type constructor, but no identity for it" — `mkIdent`
--       answers `None` on the FLAT/single-file driver path, where a user
--       declaration still carries the pipeline-stage marker (`Ns`' doc-comment
--       in `frontend/ast.mdk`; A-2 is Module-path-only until #1115/E-1).  That
--       is a property of the PIPELINE, and it is `TkBare`, inside `HkDecl`.
--
-- Collapsing (1) into (2) — dropping the `Option` — is the conflation class
-- this whole stage exists to remove.
--
-- 🚨 AND THERE IS A THIRD FACT, which is why this is not simply
-- `Option TabKey`.  `headTyconMono` has an explicit `TRigid n => Some n` arm:
-- a head fabricated from a type-PARAMETER name.  `docs/spec/DICT-SEMANTICS.md`
-- §8 I6.1 says such a head denotes a rigid type variable, is not a
-- declaration, and MUST NOT be assigned an identity — and `Mono`'s own
-- doc-comment (`types/typecheck.mdk`) records that the arm is
-- ANSWER-PRESERVING, NOT CORRECT, kept deliberately, and that A-1's gain was
-- making the violation GREPPABLE rather than invisible inside `TCon`.
--
-- Routing a rigid head into `TkBare` would throw that gain away at exactly the
-- layer A-1 bought it for: `TkBare` means "a real declaration whose module id
-- has not been acquired yet", and two `TkBare`s of the same name ARE the same
-- declaration on the flat path.  A rigid `a` is not a declaration at ALL, so
-- it must not be able to sit in the same inhabitant as one.  `HkRigid` keeps
-- the I6.1 residual visible AND greppable at the key layer, which is what lets
-- the follow-on semantics unit delete it by deleting an arm.
--
-- ⚠️ THIS UNIT CHANGES NO ANSWER.  Every consumer projects straight back to
-- the bare name, so a rigid head is still handed out as a dispatch key exactly
-- as it was.  Whoever removes that must remove the ARM, not this inhabitant.
public export data HeadKey =
  -- a real head type constructor: `TkIdent` when its declaring module is known
  -- (§8 I4's `(originModule, name)`) or the LANGUAGE provides it
  -- (`IdentBuiltin`); `TkBare` when no identity has been acquired.  Always
  -- `NsType` — see the divergence note above.
  | HkDecl TabKey
  -- 🚨 NOT A DECLARATION: the parameter name of a rigid type variable, handed
  -- out as a dispatch key.  The §8 I6.1 residual, named rather than hidden.
  | HkRigid String
deriving (Eq, Ord, Debug)

-- The ONE mint for a head that IS a declaration, and the ONE place `NsType` is
-- supplied.  Argument order mirrors `tconFrom : TyConOrigin -> String -> Mono`
-- (`types/typecheck.mdk`), the mint that BUILT the head this projects, so a
-- swapped pair does not typecheck.
--
-- ⚠️ There is deliberately no `headKeyOfRigid`: `HkRigid` is applied at exactly
-- one site (`headTyconMono`'s `TRigid` arm) and a one-line helper would make
-- that site read like a routine mint rather than the flagged violation it is.
export headKeyOfCon : TyConOrigin -> String -> HeadKey
headKeyOfCon origin name = HkDecl (tabKeyOf NsType origin name)

-- The bare name inside a head key, whatever its inhabitant.  Allocation-free:
-- it returns a `String` that already exists.
--
-- 🚨 THIS IS THE STAGE A-2 LEDGER, AND IT IS A COMMAND RATHER THAN A NUMBER —
-- a count written here would carry no derivation and no expiry.  Every line
-- the recipe prints is a dispatch key STILL keyed by a bare name, and a later
-- unit's progress is a line LEAVING that set:
--
--   grep -nwE 'headKeyName|headKeyNameOr' compiler/types/typecheck.mdk \
--     | grep -vE '^[0-9]+:[[:space:]]*(--|import )' \
--     | grep -vE '^[0-9]+:headKeyNameOr'
--
-- ⚠️ Every filter is load-bearing, and a bare `grep -n headKeyName` answers a
-- DIFFERENT question: it also matches the substring inside `headKeyNameOr`,
-- the `import types.registry.{…}` line, and every comment that names either.
-- The last filter drops `headKeyNameOr`'s OWN signature and clauses
-- (`types/typecheck.mdk`, column 0) — that wrapper is the SPELLING of the
-- residual, not an instance of it.  Pipe to `wc -l` for the size; do not copy
-- the size back into this comment.
export headKeyName : HeadKey -> String
headKeyName (HkDecl k) = tabKeyName k
headKeyName (HkRigid name) = name

-- ── Keying a table BY a projected head — Stage A-2 unit A-2.2b (#1111) ────
-- A-2.2 widened the two head PROJECTIONS to carry identity and stopped there:
-- every consumer projected straight back to a bare name, so no table's key
-- moved. This is the layer that lets a table be keyed by the projection.
--
-- 🚨 A HEAD POSITION CARRIES ONE OF **THREE** FACTS, AND A KEY MUST KEEP ALL
-- THREE APART. `headKeyNameOr <dflt>` (`types/typecheck.mdk`) collapses them to
-- two — a name, or the placeholder — which is exactly what this replaces:
--
--   ABSENT      `None` — the type has NO head type constructor (a bare tyvar,
--               a function type, an effect row). A property of the TYPE.
--   DECLARATION `Some (HkDecl tk)` — a real head. Keyable, and the key is
--               `tk`, which already distinguishes the identity-bearing
--               (`TkIdent`) from the not-yet-identified (`TkBare`) case.
--   RIGID       `Some (HkRigid n)` — a type PARAMETER name handed out as a
--               dispatch key. §8 I6.1: NOT a declaration, and MUST NOT be
--               assigned an identity or become a table key.
--
-- The result type is `Option RegKey` and its `None` is the RIGID case — "this
-- position cannot be keyed at all", which is a different fact from the
-- ABSENT input and must not be confused with it. ABSENT is keyable, and its
-- key is `RegKey [] []`: an EMPTY identity block, which no declaration can
-- ever produce (every declaration key carries at least one `TabKey`), so the
-- headless bucket is structurally disjoint from every concrete one without a
-- reserved name like `noneHeadTag` having to be un-shadowable.
--
-- ⚠️ REFUSING TO KEY A RIGID IS ANSWER-PRESERVING HERE, not a narrowing, and
-- the derivation is about the WRITER, not about this function: the only
-- writer of a head-keyed dispatch bucket is `keyEntryOf` via `headTyconTy`,
-- whose arms are `TyCon`/`TyTuple` — it has no `TRigid` arm and structurally
-- CANNOT emit one. So a rigid GOAL head looked up a bucket that no writer
-- could have filled, and answering "no bucket" is the same empty list the
-- bare-name lookup returned. See `bucketOfHead` (`types/typecheck.mdk`).
-- The DECLARATION half of a projected head, or `None` when the projection is
-- the §8 I6.1 rigid residual. The peer of `headBucketKey` for a key that is a
-- TUPLE — `ImplUniverse`'s concrete-bucket `(interface, receiver head)` pair, and
-- `checkCallObligationsU`'s argument vector — where the head is one COMPONENT
-- of the key rather than the whole of it, so a `RegKey` is the wrong return
-- type.
export headKeyDecl : HeadKey -> Option TabKey
headKeyDecl (HkDecl key) = Some key
headKeyDecl (HkRigid _) = None

-- The IDENTITY inside a projected head, or `None` when the head has none —
-- the two-`None`-cases-collapsed peer of `headKeyDecl`, for a consumer that
-- needs the `Ident` itself rather than a `TabKey` it will only ever key with.
--
-- 🚨 THE TWO `None`s ARE DELIBERATELY COLLAPSED, AND THAT IS SAFE ONLY FOR A
-- LOOKUP.  `HkRigid` (§8 I6.1: not a declaration) and `HkDecl (TkBare …)` (a
-- declaration whose module id has not been acquired — the flat/loader-less
-- path, #1115 / E-1) are different facts, and `headKeyDecl`/`headBucketKey`
-- keep them apart because their consumers key a BUCKET, where the distinction
-- decides whether a row may be written.  This one answers "which row does this
-- head select?", where both facts have the same correct answer — *no identity,
-- therefore no row* — and merging them is exactly `tabKeyEq`'s rule that
-- absence never matches, not even itself.  A consumer that needs to tell the
-- two apart must call `headKeyDecl`; adding a `TkBare` fallback HERE would
-- resurrect the bare-name collision the identity layer exists to remove.
export headKeyIdent : HeadKey -> Option Ident
headKeyIdent (HkDecl (TkIdent ident)) = Some ident
headKeyIdent (HkDecl (TkBare _ _)) = None
headKeyIdent (HkRigid _) = None

export headBucketKey : Option HeadKey -> Option RegKey
headBucketKey None = Some (RegKey [] [])
headBucketKey (Some (HkDecl key)) = Some (regKeyOfTab key)
headBucketKey (Some (HkRigid _)) = None

-- ── A dispatch key over a whole ARGUMENT VECTOR ───────────────────────────
-- `checkCallObligationsU`'s dedup key (`types/typecheck.mdk`) is a vector, not
-- a single key: an interface plus one projected head PER argument, where a
-- position can be a declaration, absent, OR rigid. `RegKey` alone cannot
-- express it, and widening `RegKey` to admit a rigid is precisely what §8
-- I6.1 forbids (see `RegKey`'s own doc-comment). So the two halves are
-- rendered SEPARATELY and concatenated:
--
--   [base]   a `RegKey` whose identity block is the interface key followed by
--            the DECLARATION positions' keys, and whose ordinal block is the
--            vector's ARITY followed by those positions' indices. Every
--            position that is neither in the ordinal block nor in [rigids] is
--            absent, and the arity says how many positions there are, so the
--            classification of every position is recoverable ⇒ two vectors
--            differing only in WHICH position is absent get different keys.
--            That is #607's property, kept structurally rather than by a
--            positional `""` placeholder that a name could in principle equal.
--   [rigids] the §8 I6.1 RESIDUAL, as `(position, parameter name)` pairs in
--            ascending position order. It is a separate argument, and a
--            separate netstring group, for one reason: **deleting the residual
--            is deleting this argument**, and until then `grep -n
--            dispKeyRender` names every site that still keys on one.
--
-- ⚠️ INJECTIVITY ACROSS THE JOIN. `regKeyRender`'s output is wrapped in a
-- netstring of its own (`lenKey`) rather than concatenated raw, because the
-- ordinal block is NOT count-prefixed — an ordinal netstring and a rigid
-- position netstring are indistinguishable, so a raw join could read one as
-- the other. Wrapping fixes the boundary: `lenKey s ++ t` determines `s`
-- because a valid-UTF-8 byte-prefix of a valid-UTF-8 string is a codepoint
-- prefix, so equal codepoint counts force equal strings.
--
-- ⚠️ TWO RIGIDS OF THE SAME NAME AT THE SAME POSITION DO COMPARE EQUAL, and
-- that is deliberate: it is what the bare-name key did, and A-2.2b's bar is
-- answer-preservation. Making distinct occurrences of one rigid name
-- never-equal would need an occurrence identity that does not exist at the
-- call site, and inventing one is the I6.3 violation A-2.0's review already
-- rejected. What this rendering DOES guarantee is that a rigid never compares
-- equal to a DECLARATION of the same spelling, and never to a rigid at a
-- different position — the two conflations a bare-name vector admits.
export dispKeyRender : RegKey -> List (Int, String) -> String
dispKeyRender base rigids = lenKey (regKeyRender base)
  ++ lenKey "\{listLen rigids}"
  ++ joinWith "" (map ((i, name) => ordKey i ++ lenKey name) rigids)

-- ── Deliberately NOT added, with the table each omission affects ───────────
--   * NO `Display` for `Ident`/`RegKey` — see `Ident` in `frontend/ast.mdk`:
--     user-facing rendering is A-2.8's decision, and a derived instance would
--     silently become the answer at the first interpolation. Affects A-2.8's
--     ambiguity diagnostic, which must choose a rendering explicitly.
--   * NO `regAdjust`/`regAlter` (read-modify-write in one pass). Every target
--     table's writer is a plain overwrite or, for the multi-valued ones, an
--     `mregAdd`; `universeIfaceParamKinds` is the closest thing to a
--     read-modify-write and its writer (`insertIfaceParamKinds`) replaces the
--     whole slot list. Add it when a conversion actually needs it rather than
--     shipping an untested combinator.
--   * NO ordered/insertion-order enumeration. `rejectCyclicAliases` +
--     `emitCyclicAliasErrors` (`types/typecheck.mdk`) are the one known pair
--     that depends on enumeration order; the module doc-comment above makes
--     that a stated obligation of THAT unit's PR rather than a guarantee this
--     type silently fails to provide. A key-order side list is trivial to add
--     next to the registry in that one conversion; baking a second ordering
--     into every registry is not.
--     ✅ ANSWERED by A-2.3, and not with a side list: that conversion keeps
--     the assoc list and re-keys it (`TabKey` above), so the enumeration
--     order is unchanged by construction and `rejectCyclicAliases` needed no
--     ordering guarantee from this module at all. The bullet stands for the
--     NEXT conversion that does swap a representation.
--   * NO `mregDelete` — no target table removes a value from a multi-bucket
--     (`ImplUniverse`'s buckets, `ifaceDispatchRef` and `methodReqCountRef` are
--     grow-only within a run; the first is rebuilt per read/build rather than
--     reset, the other two cleared wholesale by `resetState`).

-- ── Doctest fixtures ───────────────────────────────────────────────────────
-- These `Ident`s exist only to give the doctests below short, readable
-- expressions. Each pair differs from its sibling along exactly ONE axis
-- (Ns, IdentOrigin, or name) so each doctest isolates one collision
-- dimension.
--
-- ⚠️ Every module-origin fixture is minted through `mkIdent`, because that is
-- now the ONLY way to obtain a module origin at all — `IdentModule` is
-- private to `frontend/ast.mdk`. `mkIdent` is partial, so the fixtures need a
-- total fallback; `identBuiltinFixture` is a WELL-FORMED identity with a name
-- no assertion below uses, so a fixture that silently fell back would show up
-- as the WRONG identity (every fixture would collapse onto one row and
-- `regSize regAllNs == 6`, the `regBoth*` lookups and the `regShift` pair
-- would all fail) rather than as a crash. That is checked, not assumed: see
-- the `mkIdent`-is-Some doctest in the F1 block below.
identBuiltinFixture : Ns -> String -> Ident
identBuiltinFixture ns name = Ident ns identOriginBuiltin name

identIn : Ns -> String -> String -> Ident
identIn ns mid name =
  fromOption
    (identBuiltinFixture ns "__fixture_fallback__")
    (mkIdent ns (OriginModule mid) name)

identTypeFooM : Ident
identTypeFooM = identIn NsType "m" "Foo"

identIfaceFooM : Ident
identIfaceFooM = identIn NsIface "m" "Foo"

identTypeFooN : Ident
identTypeFooN = identIn NsType "n" "Foo"

identTypeBarM : Ident
identTypeBarM = identIn NsType "m" "Bar"

identTypeFooBuiltin : Ident
identTypeFooBuiltin = identBuiltinFixture NsType "Foo"

-- ALL SIX namespaces at the SAME origin and the SAME name — the fixture the
-- namespace doctests below discriminate over. `size` is the exact spelling
-- `Ns`'s doc-comment (`frontend/ast.mdk`) uses for the field-vs-method case,
-- measured to check clean in one file.
identSizeIn : Ns -> Ident
identSizeIn ns = identIn ns "m" "size"

allNsIdents : List Ident
allNsIdents =
  map identSizeIn [NsType, NsIface, NsMethod, NsCtor, NsField, NsValue]

-- Adversarial: two DIFFERENT Idents whose (origin-module, name) pair shifts
-- a character across the module/name boundary — `"ab" ++ "c" == "a" ++
-- "bc"`. A naive un-prefixed concatenation of fields WOULD collide these;
-- `identKey`'s `lenKey`-prefixing does not.
identShiftA : Ident
identShiftA = identIn NsType "ab" "c"

identShiftB : Ident
identShiftB = identIn NsType "a" "bc"

regBothNs : Registry Int
regBothNs = regInsert identIfaceFooM 2 (regInsert identTypeFooM 1 regEmpty)

regBothOrigin : Registry Int
regBothOrigin = regInsert identTypeFooN 20 (regInsert identTypeFooM 10 regEmpty)

regOriginKinds : Registry Int
regOriginKinds =
  regInsert identTypeFooBuiltin 3 (regInsert identTypeFooM 1 regEmpty)

regBothNames : Registry Int
regBothNames =
  regInsert identTypeBarM 200 (regInsert identTypeFooM 100 regEmpty)

regShift : Registry Int
regShift = regInsert identShiftB 2 (regInsert identShiftA 1 regEmpty)

-- ── #607 conflation fixtures: WHICH position is absent must key differently ─
-- `interface Ix a b` with two CALL-channel obligations, each ground in ONE
-- argument and undetermined in the other. These are the two keys the
-- `Ident × [Option Ident]` row (module doc-comment) says must stay apart, in
-- the encoding it prescribes: identities = iface :: present heads, ordinals =
-- arity :: the present positions' 0-based indices.
identIfaceIxM : Ident
identIfaceIxM = identIn NsIface "m" "Ix"

identTypeIntM : Ident
identTypeIntM = identIn NsType "m" "Int"

-- `Ix Int b0` — argument 0 present (head `Int`), argument 1 undetermined.
keyIxIntUndet : RegKey
keyIxIntUndet = regKeyNAt [identIfaceIxM, identTypeIntM] [2, 0]

-- `Ix a0 Int` — argument 0 undetermined, argument 1 present (head `Int`).
keyIxUndetInt : RegKey
keyIxUndetInt = regKeyNAt [identIfaceIxM, identTypeIntM] [2, 1]

-- What the `[Ident]` shape would have produced for BOTH of the above: the
-- present heads only, with no record of which position they came from.
keyIxPresentOnly : RegKey
keyIxPresentOnly = regKeyN [identIfaceIxM, identTypeIntM]

regIxUndet : Registry Int
regIxUndet = regInsertK keyIxUndetInt 2 (regInsertK keyIxIntUndet 1 regEmpty)

-- ── A-2.2b: the RIGID position, beside the absent one ──────────────────────
-- `dispKeyRender`'s three-way discrimination, one fixture per fact at the
-- SAME position of the SAME 2-argument vector, so each doctest below isolates
-- one axis. `keyIxNoDecl` is the vector with NO declaration positions at all —
-- arity 2, nothing present — so a rigid can be placed at position 0 or 1
-- without colliding with a declaration slot.
keyIxNoDecl : RegKey
keyIxNoDecl = regKeyNAt [identIfaceIxM] [2]

-- A DECLARATION at position 0 whose name is `a` — the exact spelling a rigid
-- type parameter carries. `tabKeyOf`'s two arms are both exercised: `TkIdent`
-- here, `TkBare` in `keyIxBareAOnly` below, and NEITHER may equal the rigid.
identTypeLowerAM : Ident
identTypeLowerAM = identIn NsType "m" "a"

keyIxDeclAOnly : RegKey
keyIxDeclAOnly = regKeyNAt [identIfaceIxM, identTypeLowerAM] [2, 0]

-- The same declaration on the FLAT path — no identity acquired yet, so
-- `tabKeyOf` lands it in `TkBare`. Distinct from both the `TkIdent` row above
-- and the rigid.
keyIxBareAOnly : RegKey
keyIxBareAOnly = RegKey [TkIdent identIfaceIxM, TkBare NsType "a"] [2, 0]

-- Head-bucket fixtures: the three facts `headBucketKey` classifies.
headDeclFoo : Option HeadKey
headDeclFoo = Some (headKeyOfCon (OriginModule "m") "Foo")

-- ⚠️ Spelled with the CONSTRUCTOR, not `headKeyOfCon OriginUnresolved "Foo"`.
-- That mention would enrol this file in the #1110 `OriginUnresolved` PRODUCER
-- ratchet (`test/typecheck_compiler_source.sh`), which exists to keep
-- pre-resolve node construction inside `tyConUnresolved` — a doctest fixture is
-- not a producer, and widening that allowlist to admit one would be the masking
-- path the ratchet's own remedy forbids. `tabKeyOf`'s identity-less arm is
-- asserted directly elsewhere in this block, so nothing is lost.
headBareFoo : Option HeadKey
headBareFoo = Some (HkDecl (TkBare NsType "Foo"))

headRigidA : Option HeadKey
headRigidA = Some (HkRigid "a")

-- One entry per namespace, all under origin `m` and name `size`: any two
-- namespace tags collapsing into one makes this registry SMALLER than six.
regAllNs : Registry Int
regAllNs = regFromEntries (zipNsValues allNsIdents 1)

zipNsValues : List Ident -> Int -> List (RegKey, Int)
zipNsValues [] _ = []
zipNsValues (i::rest) n = (regKeyOf i, n) :: zipNsValues rest (n + 1)

-- Composite-key fixtures: the same identity at two different ordinal slots,
-- and two different identity TUPLES sharing a member.
regSlots : Registry Int
regSlots =
  regInsertK
    (regKeyAt identIfaceFooM 1)
    11
    (regInsertK (regKeyAt identIfaceFooM 0) 10 regEmpty)

regPairs : Registry Int
regPairs = regInsertK
  (regKeyN [identIfaceFooM, identTypeBarM])
  2
  (regInsertK (regKeyN [identIfaceFooM, identTypeFooM]) 1 regEmpty)

-- mregAdd, called in OPPOSITE orders under the SAME Ident with the SAME two
-- values — demonstrates no registration is lost to call order.
mregOrderA : MultiRegistry Int
mregOrderA = mregAdd identTypeFooM 2 (mregAdd identTypeFooM 1 mregEmpty)

mregOrderB : MultiRegistry Int
mregOrderB = mregAdd identTypeFooM 1 (mregAdd identTypeFooM 2 mregEmpty)

-- ── F1: neither non-identity can become an identity ────────────────────────
-- `identOriginOf` is total and REFUSES both non-identities, so no `Ident`
-- exists that would render to a shared constant key.
-- ⚠️ This replaces a doctest the first cut of this file shipped
-- (`regLookup identTypeFooUnresolved regAllOriginKinds == Some 2`) which
-- SPECIFIED the prohibited behaviour: it asserted that an `OriginUnresolved`
-- identity keys a registry row, i.e. exactly the collision
-- `resolve.mdk`'s consumer rule and `DICT-SEMANTICS.md` §8 I6.3 forbid.
--
-- ⚠️ These are now the LAST WORD on the empty-module case, not a backstop for
-- it: `IdentModule` is private to `frontend/ast.mdk`, so `IdentModule ""` is
-- not spellable anywhere and a doctest asserting how it keys could not be
-- written even if someone wanted to. Round 1's F1 residual is closed at the
-- type. What these pin is that the MINT still refuses the two non-identities
-- — the property the privacy of the constructor rests on.
-- > identOriginOf OriginUnresolved == None
-- True
-- > identOriginOf (OriginModule "") == None
-- True
-- > identOriginOf OriginBuiltin == Some identOriginBuiltin
-- True
-- > identOriginOf (OriginModule "m") == identOriginOf (OriginModule "m")
-- True
-- > identOriginOf (OriginModule "m") == identOriginOf (OriginModule "n")
-- False
-- > identOriginOf OriginBuiltin == identOriginOf (OriginModule "builtin")
-- False
-- > mkIdent NsType OriginUnresolved "Foo" == None
-- True
-- > mkIdent NsType (OriginModule "") "Foo" == None
-- True
-- > mkIdent NsType (OriginModule "m") "Foo" == Some identTypeFooM
-- True
-- > mkIdent NsType OriginBuiltin "Foo" == Some identTypeFooBuiltin
-- True

-- The fixture-fallback guard (see `identIn` above): every module-origin
-- fixture is a `Some`, so none of them silently became the builtin fallback.
-- > isSome (mkIdent NsType (OriginModule "m") "Foo")
-- True
-- > isSome (mkIdent NsType (OriginModule "ab") "c")
-- True

-- Round-trip: insert then lookup under the SAME Ident finds the value; a
-- DIFFERENT Ident (differing only in name) finds nothing.
-- > regLookup identTypeFooM (regInsert identTypeFooM 42 regEmpty)
-- Some 42
-- > regLookup identTypeBarM (regInsert identTypeFooM 42 regEmpty)
-- None

-- Two Idents differing ONLY in Ns (same origin, same name) do not collide:
-- both coexist and each lookup finds its own value.
-- > regLookup identTypeFooM regBothNs
-- Some 1
-- > regLookup identIfaceFooM regBothNs
-- Some 2

-- ── F2: ALL SIX namespaces discriminate ────────────────────────────────────
-- The size assertion is the one that cannot be passed by a broken `nsTag`:
-- ANY two tags rendering alike makes one entry overwrite the other and the
-- count drops. The six lookups then pin WHICH value each namespace holds.
--
-- The first cut of this file exercised only `NsType`/`NsIface`, and this is
-- MEASURED against it (`git show <that commit>:compiler/types/registry.mdk`,
-- run 2026-08-03), not relayed: `nsTag NsMethod = NsCtor = NsField = NsValue
-- = "type"` gave **23/23 passed, exit 0**, and so did `nsTag NsField =
-- "method"` — the exact field-vs-method collision `Ns`'s doc-comment gives as
-- the REASON six namespaces exist. Against the doctests below the same two
-- mutations give 73/80 and 76/80, both exit 1.
-- > regSize regAllNs
-- 6
-- > regLookup (identSizeIn NsType) regAllNs
-- Some 1
-- > regLookup (identSizeIn NsIface) regAllNs
-- Some 2
-- > regLookup (identSizeIn NsMethod) regAllNs
-- Some 3
-- > regLookup (identSizeIn NsCtor) regAllNs
-- Some 4
-- > regLookup (identSizeIn NsField) regAllNs
-- Some 5
-- > regLookup (identSizeIn NsValue) regAllNs
-- Some 6

-- The field-vs-method case `Ns`'s own doc-comment names, asserted directly on
-- the renderer rather than through a registry.
-- > identKey (identSizeIn NsField) == identKey (identSizeIn NsMethod)
-- False

-- Two Idents differing ONLY in IdentOrigin's module string do not collide.
-- > regLookup identTypeFooM regBothOrigin
-- Some 10
-- > regLookup identTypeFooN regBothOrigin
-- Some 20

-- Both IdentOrigin KINDS (module / builtin) coexist under the same Ns +
-- name — the origin TAG, not just the module string, is part of the key.
-- > regLookup identTypeFooM regOriginKinds
-- Some 1
-- > regLookup identTypeFooBuiltin regOriginKinds
-- Some 3

-- ⚠️ THE ORIGIN TAG IS NOW REDUNDANT BY CONSTRUCTION, AND THIS IS THE ONLY
-- THING THAT TESTS IT. Until `IdentOrigin`'s constructors went private, the
-- doctest here was `identKey identTypeFooBuiltin /= identKey (Ident NsType
-- (IdentModule "") "Foo")` — a hand-built ill-formed identity that had to be
-- kept off the builtin's row. That expression no longer COMPILES (the
-- constructor is private), which is the point of the change. But it took the
-- tag's only coverage with it: every module id is now non-empty, so
-- `originModuleOf` alone already separates builtin from every module, and
-- MEASURED 2026-08-03 the mutation `originTag = identOriginFold "module" (_
-- => "module")` gives 92/93 — every PROPERTY-level doctest in this file still
-- passes, and the single failure is the byte-shape line immediately below.
-- The tag is therefore defense in depth in exactly the sense the count prefix
-- is (see the module doc-comment): it keeps the builtin/module distinction
-- from resting on the emptiness of one field, so a future third `IdentOrigin`
-- inhabitant cannot quietly alias onto the builtin. Pinning it needs a
-- BYTE-SHAPE assertion, because no property-level one can see it.
-- `identKey` is four netstrings: ns, origin tag, origin module, name.
-- > identKey identTypeFooBuiltin == "4:type7:builtin0:3:Foo"
-- True
-- > identKey identTypeFooM == "4:type6:module1:m3:Foo"
-- True

-- The count prefix (see the module doc-comment): three more of the
-- byte-shape assertions, and the only thing that can distinguish the prefix
-- being there at all.
-- > startsWith "1:1" (regKeyRender (regKeyOf identTypeFooM))
-- True
-- > startsWith "1:2" (regKeyRender (regKeyN [identTypeFooM, identTypeBarM]))
-- True
-- > startsWith "1:0" (regKeyRender (regKeyN []))
-- True

-- Two Idents differing ONLY in name do not collide.
-- > regLookup identTypeFooM regBothNames
-- Some 100
-- > regLookup identTypeBarM regBothNames
-- Some 200

-- Adversarial boundary-shift case: identKey itself must differ (this is the
-- property that keeps regShift's two entries apart above).
-- > identKey identShiftA == identKey identShiftB
-- False
-- > regLookup identShiftA regShift
-- Some 1
-- > regLookup identShiftB regShift
-- Some 2

-- ── F3: #607 — two vectors differing only in WHICH position is absent ───────
-- THE assertion that would have caught the `Ident × [Ident]` row. Both keys
-- carry the SAME identities (`Ix`, `Int`) and differ only in which argument
-- position the present head came from, which under the wrong row would have
-- made them one key and silently dropped one ambiguity diagnostic. See
-- "What the target tables need" in the module doc-comment for the derivation.
-- > regKeyRender keyIxIntUndet == regKeyRender keyIxUndetInt
-- False
-- > regKeyTabs keyIxIntUndet == regKeyTabs keyIxUndetInt
-- True
-- > regSize regIxUndet
-- 2
-- > regLookupK keyIxIntUndet regIxUndet
-- Some 1
-- > regLookupK keyIxUndetInt regIxUndet
-- Some 2

-- ── F3b (A-2.2b): the same property THROUGH `dispKeyRender`'s join ─────────
-- The #607 assertion above is about `regKeyRender` alone. `dispKeyRender`
-- appends a second netstring group after it, and the whole reason
-- `regKeyRender`'s output is netstring-WRAPPED there is that the ordinal
-- block is not count-prefixed — so a raw join could read a rigid position as
-- an ordinal and re-conflate exactly what F3 keeps apart. These re-assert
-- #607 on the composed renderer, with an empty residual.
-- > dispKeyRender keyIxIntUndet [] == dispKeyRender keyIxUndetInt []
-- False
-- > dispKeyRender keyIxIntUndet [] == dispKeyRender keyIxIntUndet []
-- True

-- ── F3c (A-2.2b): a RIGID position is none of the other two facts ──────────
-- Same vector, same position, three different facts at it. The first two are
-- the conflations a bare-name key admits: `headKeyNameOr ""` renders a rigid
-- `a` as `"a"`, which is byte-identical to what it renders a type CONSTRUCTOR
-- named `a` as — and `""` is what it renders an absent position as, which any
-- head whose name were empty would equal.
--
-- ⚠️ The declaration arm is asserted on BOTH `TabKey` halves. `TkIdent` alone
-- would leave the flat path untested, and the flat path is where every user
-- declaration currently lands (A-2 is module-path-only until #1115/E-1) — so
-- it is the arm a rigid is most likely to be confused with in practice.
-- > dispKeyRender keyIxNoDecl [(0, "a")] == dispKeyRender keyIxNoDecl []
-- False
-- > dispKeyRender keyIxDeclAOnly [] == dispKeyRender keyIxNoDecl [(0, "a")]
-- False
-- > dispKeyRender keyIxBareAOnly [] == dispKeyRender keyIxNoDecl [(0, "a")]
-- False
-- > dispKeyRender keyIxDeclAOnly [] == dispKeyRender keyIxBareAOnly []
-- False

-- A rigid's POSITION and NAME both discriminate...
-- > dispKeyRender keyIxNoDecl [(0, "a")] == dispKeyRender keyIxNoDecl [(1, "a")]
-- False
-- > dispKeyRender keyIxNoDecl [(0, "a")] == dispKeyRender keyIxNoDecl [(0, "b")]
-- False
-- > dispKeyRender keyIxNoDecl [(0, "a"), (1, "b")] == dispKeyRender keyIxNoDecl [(0, "b"), (1, "a")]
-- False

-- ...and two occurrences of the SAME rigid name at the SAME position DO
-- compare equal. That is not an oversight: it is what the bare-name key did,
-- and A-2.2b is answer-preserving by construction. See `dispKeyRender`'s
-- doc-comment for why an occurrence identity is not available (and would be
-- the I6.3 violation A-2.0's review rejected).
-- > dispKeyRender keyIxNoDecl [(0, "a")] == dispKeyRender keyIxNoDecl [(0, "a")]
-- True

-- ── F3d (A-2.2b): `headBucketKey`'s three-way classification ───────────────
-- A rigid head yields NO key at all — the §8 I6.1 refusal. An ABSENT head
-- does yield one (the empty identity block), and it can never equal a
-- declaration's, because every declaration key carries at least one `TabKey`.
-- > isSome (headBucketKey headRigidA)
-- False
-- > isSome (headBucketKey None)
-- True
-- > map regKeyRender (headBucketKey None) == map regKeyRender (headBucketKey headDeclFoo)
-- False
-- > map regKeyRender (headBucketKey headDeclFoo) == map regKeyRender (headBucketKey headBareFoo)
-- False
-- > map regKeyRender (headBucketKey headDeclFoo) == map regKeyRender (headBucketKey headDeclFoo)
-- True

-- ...and the key the DISCARDED shape would have produced for both of them is
-- a THIRD key, distinct from either: dropping the positions does not merely
-- conflate the two, it also aliases nothing else, so no existing assertion
-- about `regKeyN` could have detected the loss.
-- > regLookupK keyIxPresentOnly regIxUndet
-- None
-- > regSize (regInsertK keyIxPresentOnly 3 regIxUndet)
-- 3

-- ── F3: composite keys ─────────────────────────────────────────────────────
-- Same identity, different ORDINAL slot: two rows, each found by its own key.
-- > regSize regSlots
-- 2
-- > regLookupK (regKeyAt identIfaceFooM 0) regSlots
-- Some 10
-- > regLookupK (regKeyAt identIfaceFooM 1) regSlots
-- Some 11

-- A one-ident key and the same ident at slot 0 are DIFFERENT keys — the
-- ordinal block is not silently equivalent to its absence.
-- > regKeyRender (regKeyOf identIfaceFooM) == regKeyRender (regKeyAt identIfaceFooM 0)
-- False

-- Identity TUPLES: two pairs sharing their first member stay apart, and a
-- one-element tuple is the same key as the plain identity form.
-- > regSize regPairs
-- 2
-- > regLookupK (regKeyN [identIfaceFooM, identTypeFooM]) regPairs
-- Some 1
-- > regLookupK (regKeyN [identIfaceFooM, identTypeBarM]) regPairs
-- Some 2
-- > regLookupK (regKeyN [identIfaceFooM]) (regInsert identIfaceFooM 7 regEmpty)
-- Some 7

-- The grouping is what keeps tuples apart, not a separator: `[A, B]` and
-- `[B, A]` are different keys, and no concatenation of two 1-tuples equals a
-- 2-tuple (the leading ident-count differs).
-- > regKeyRender (regKeyN [identTypeFooM, identTypeBarM]) == regKeyRender (regKeyN [identTypeBarM, identTypeFooM])
-- False
-- > identKeys [identTypeFooM, identTypeBarM] == identKey identTypeFooM ++ identKey identTypeBarM
-- True
-- > identKeys [identTypeFooM] == identKey identTypeFooM
-- True

-- regInsertChecked's overwrite signal fires both ways: True when an entry
-- under the exact same Ident already existed, False when the key was fresh.
-- > snd (regInsertChecked identTypeFooM 99 (regInsert identTypeFooM 1 regEmpty))
-- True
-- > snd (regInsertChecked identTypeFooM 99 regEmpty)
-- False

-- ── F4: regEntries hands back the ORIGINAL identities ──────────────────────
-- Asserted by comparing the returned `Ident`s themselves (derived `Eq`), not
-- merely by counting them: the first cut of this file claimed this property
-- while testing only `listLen (regEntries regBothNs) == 2`, which a
-- `regEntries` returning two FABRICATED identities would also pass.
-- Enumeration is in `regKeyRender` order, and `lenKey "type"` = `4:type`
-- sorts before `lenKey "iface"` = `5:iface`, so NsType comes first.
-- > map (e => regKeyTabs (fst e)) (regEntries regBothNs) == [[TkIdent identTypeFooM], [TkIdent identIfaceFooM]]
-- True
-- > map snd (regEntries regBothNs) == [1, 2]
-- True
-- > regKeys regBothNs == [regKeyOf identTypeFooM, regKeyOf identIfaceFooM]
-- True

-- ── F3: delete / filter / fromEntries / merge / size ────────────────────────
-- > regSize (regDelete identTypeFooM regBothNs)
-- 1
-- > regLookup identTypeFooM (regDelete identTypeFooM regBothNs)
-- None
-- > regLookup identIfaceFooM (regDelete identTypeFooM regBothNs)
-- Some 2
-- > regSize (regDelete identTypeFooN regBothNs)
-- 2
-- > regSize (regFilter (e => snd e > 1) regBothNs)
-- 1
-- > regLookup identIfaceFooM (regFilter (e => snd e > 1) regBothNs)
-- Some 2
-- > regSize (regFromEntries (regEntries regBothNs))
-- 2
-- > regLookup identTypeFooM (regFromEntries (regEntries regBothNs))
-- Some 1

-- regMerge is right-biased on a shared key and keeps both sides' unique keys.
-- > regSize (regMerge regBothNs regBothNames)
-- 3
-- > regLookup identTypeFooM (regMerge regBothNs regBothNames)
-- Some 100
-- > regLookup identIfaceFooM (regMerge regBothNs regBothNames)
-- Some 2
-- > regLookup identTypeBarM (regMerge regBothNs regBothNames)
-- Some 200

-- mregAdd never drops a registration to call order: both orders keep BOTH
-- values (as a multiset — sorted before comparing, since the internal list
-- order is not itself the guarantee).
-- > listLen (mregLookup identTypeFooM mregOrderA)
-- 2
-- > listLen (mregLookup identTypeFooM mregOrderB)
-- 2
-- > sort (mregLookup identTypeFooM mregOrderA) == sort (mregLookup identTypeFooM mregOrderB)
-- True
-- > mregLookup identTypeBarM mregOrderA
-- []

-- ── F3: MultiRegistry enumeration and union ────────────────────────────────
-- > mregSize (mregAdd identIfaceFooM 9 mregOrderA)
-- 2
-- > map (e => regKeyTabs (fst e)) (mregEntries mregOrderA) == [[TkIdent identTypeFooM]]
-- True
-- > mregKeys mregOrderA == [regKeyOf identTypeFooM]
-- True
-- > sort (mregLookup identTypeFooM (mregMerge mregOrderA mregOrderB)) == [1, 1, 2, 2]
-- True
-- > mregSize (mregMerge mregOrderA (mregAdd identTypeBarM 5 mregEmpty))
-- 2
-- > mregLookup identTypeBarM (mregMerge mregOrderA (mregAdd identTypeBarM 5 mregEmpty))
-- [5]
-- > mregLookupK (regKeyAt identIfaceFooM 0) (mregAddK (regKeyAt identIfaceFooM 0) 4 mregEmpty)
-- [4]

-- SetRegistry: membership, size, enumeration, union.
-- > sregMember identTypeFooM (sregAdd identTypeFooM sregEmpty)
-- True
-- > sregMember identTypeBarM (sregAdd identTypeFooM sregEmpty)
-- False
-- > sregSize (sregAdd identTypeFooM (sregAdd identTypeBarM sregEmpty))
-- 2
-- > sregSize (sregAdd identTypeFooM (sregAdd identTypeFooM sregEmpty))
-- 1
-- > sregSize (sregAdd (identSizeIn NsField) (sregAdd (identSizeIn NsMethod) sregEmpty))
-- 2
-- > sregKeys (sregAdd identTypeFooM sregEmpty) == [regKeyOf identTypeFooM]
-- True
-- > sregSize (sregMerge (sregAdd identTypeFooM sregEmpty) (sregAdd identTypeBarM sregEmpty))
-- 2
-- > sregMemberK (regKeyAt identIfaceFooM 3) (sregAddK (regKeyAt identIfaceFooM 3) sregEmpty)
-- True
-- > sregMemberK (regKeyAt identIfaceFooM 4) (sregAddK (regKeyAt identIfaceFooM 3) sregEmpty)
-- False

-- ── F4: TabKey — the assoc-list half (A-2.3's two tables) ──────────────────
-- Fixtures mirror the `Ident` ones above: `tabA`/`tabZ` are the SAME bare name
-- `Box` declared by two unrelated modules, which is the #1069/#1090/#1070
-- shape verbatim; `tabU` is what a flat/single-file driver mints for that same
-- name (no identity at all).
tabA : TabKey
tabA = tabKeyOf NsType (OriginModule "apub") "Box"

tabZ : TabKey
tabZ = tabKeyOf NsType (OriginModule "zopapub") "Box"

-- ⚠️ Spelled with the CONSTRUCTOR rather than as `tabKeyOf NsType
-- OriginUnresolved "Box"`, deliberately: `test/typecheck_compiler_source.sh`'s
-- #1110 ratchet pins the set of FILES carrying a non-comment `OriginUnresolved`
-- mention, and that ratchet is about `Ty`-layer node CONSTRUCTION — allow-listing
-- a whole file for one test fixture would excuse every future mention in it too.
-- Nothing is lost: the mint's own `OriginUnresolved` behaviour is asserted
-- directly in the F4 block below, and `TkBare NsType "Box"` is exactly what that
-- assertion says the mint returns.
tabU : TabKey
tabU = TkBare NsType "Box"

tabIfaceA : TabKey
tabIfaceA = tabKeyOf NsIface (OriginModule "apub") "Box"

-- `zopapub` registered LAST, so it is at the FRONT of the prepend — the exact
-- table state that makes the bare-name lookup answer with the wrong module's
-- row today.
tabTable : List (TabKey, Int)
tabTable = [(tabZ, 2), (tabA, 1)]

-- The mint is total, and each of the three origin cases lands where it must.
-- > tabKeyOf NsType (OriginModule "apub") "Box" == TkIdent (Ident NsType identOriginBuiltin "Box")
-- False
-- > tabKeyOf NsType OriginUnresolved "Box" == TkBare NsType "Box"
-- True
-- > tabKeyOf NsType (OriginModule "") "Box" == TkBare NsType "Box"
-- True
-- > tabKeyOf NsType OriginBuiltin "Box" == TkIdent (Ident NsType identOriginBuiltin "Box")
-- True

-- 🚨 THE DRAIN, in one assertion: the shadower is at the FRONT of the list and
-- the lookup still answers with the row whose module actually declared the
-- head being elaborated.
-- > lookupTab tabA tabTable
-- Some 1
-- > lookupTab tabZ tabTable
-- Some 2

-- An identity-bearing key NEVER matches a bare row, and a bare key never
-- matches an identity-bearing one — in BOTH directions, so neither half can
-- silently answer for the other.
-- > lookupTab tabU tabTable
-- None
-- > lookupTab tabA [(tabU, 7)]
-- None
-- > lookupTab tabU [(tabU, 7)]
-- Some 7

-- A miss is a MISS: nothing degrades to a name match.
-- > lookupTab (tabKeyOf NsType (OriginModule "other") "Box") tabTable
-- None
-- > lookupTab tabIfaceA tabTable
-- None
-- > lookupTab tabIfaceA [(tabIfaceA, 5)]
-- Some 5

-- Namespace discriminates on the BARE half too (`TkBare` carries its `Ns`).
-- > lookupTab (tabKeyOf NsIface OriginUnresolved "Box") [(tabU, 7)]
-- None

-- First match wins, so a prepend still shadows an earlier entry under the SAME
-- identity — the overlay ordering both converted tables rely on.
-- > lookupTab tabA ((tabA, 99) :: tabTable)
-- Some 99

-- `tabKeyName` reads the bare name out of either half.
-- > tabKeyName tabA
-- "Box"
-- > tabKeyName tabU
-- "Box"

-- `tabHasName` is the name-only membership predicate: it sees BOTH halves and
-- returns no value, so it can never select a row.
-- > tabHasName "Box" tabTable
-- True
-- > tabHasName "Box" [(tabU, 7)]
-- True
-- > tabHasName "Bx" tabTable
-- False
-- > tabHasName "Box" ([] : List (TabKey, Int))
-- False

-- ── F5: RegKey over TabKey — the COMPOSITE half of A-2.4 ──────────────────
-- `universeIfaceParamKinds`' real key shape: an INTERFACE identity plus a
-- parameter-SLOT ordinal. `slotGA`/`slotGB` are the same slot of two
-- same-named interfaces declared by two unrelated modules — the #1257 shape
-- verbatim; `slotUA` is what the flat/single-file driver mints for that same
-- interface (no identity at all).
ifaceG : TabKey
ifaceG = tabKeyOf NsIface (OriginModule "gmod") "Same"

ifaceP : TabKey
ifaceP = tabKeyOf NsIface (OriginModule "pmod") "Same"

-- Spelled with the CONSTRUCTOR, not `tabKeyOf NsIface OriginUnresolved "Same"`,
-- for the reason `tabU` above gives: `test/typecheck_compiler_source.sh`'s
-- #1110 ratchet pins the FILE SET carrying a non-comment `OriginUnresolved`
-- mention. Nothing is lost — the mint's `OriginUnresolved` behaviour is
-- asserted directly in F4 above, and `TkBare NsIface "Same"` is exactly what
-- that assertion says it returns.
ifaceU : TabKey
ifaceU = TkBare NsIface "Same"

slotGA : RegKey
slotGA = regKeyTabAt ifaceG 0

slotPA : RegKey
slotPA = regKeyTabAt ifaceP 0

slotUA : RegKey
slotUA = regKeyTabAt ifaceU 0

-- `gmod` registered LAST, so it is at the FRONT of the prepend — the table
-- state that makes the bare-name lookup answer with the wrong module's slot
-- kinds today (#1257).
slotTable : List (RegKey, Int)
slotTable = [(slotGA, 2), (slotPA, 1)]

-- 🚨 THE #1257 DRAIN, in one assertion: the shadower is at the FRONT and the
-- lookup still answers with the interface the impl actually names.
-- > lookupReg slotPA slotTable
-- Some 1
-- > lookupReg slotGA slotTable
-- Some 2

-- The ORDINAL discriminates: slot 1 of the same interface is a different key.
-- > lookupReg (regKeyTabAt ifaceP 1) slotTable
-- None
-- > lookupReg (regKeyTabAt ifaceP 1) ((regKeyTabAt ifaceP 1, 9) :: slotTable)
-- Some 9

-- First match wins, so a prepend still shadows under the SAME key — the
-- front-overlay ordering `registerIfaceParamKinds` relies on.
-- > lookupReg slotPA ((slotPA, 99) :: slotTable)
-- Some 99

-- An identity-bearing key NEVER matches a bare row and vice versa, in BOTH
-- directions — the same structural exclusion `tabKeyEq` gives the assoc-list
-- half, now through `RegKey`.
-- > lookupReg slotUA slotTable
-- None
-- > lookupReg slotPA [(slotUA, 7)]
-- None
-- > lookupReg slotUA [(slotUA, 7)]
-- Some 7

-- ...and the SAME exclusion holds through the RENDERED path, which is what an
-- `OrdMap`-backed `Registry`/`SetRegistry` actually compares. This is the
-- assertion that would catch a `tabKeyRender` whose bare arm collided with an
-- identity arm — `tabKeyEq` is not consulted at all down here.
-- > regKeyRender slotUA == regKeyRender slotPA
-- False
-- > regSize (regInsertK slotUA 7 (regInsertK slotPA 1 (regInsertK slotGA 2 regEmpty)))
-- 3
-- > regLookupK slotUA (regInsertK slotUA 7 (regInsertK slotPA 1 regEmpty))
-- Some 7
-- > regLookupK slotPA (regInsertK slotUA 7 (regInsertK slotPA 1 regEmpty))
-- Some 1

-- `regKeyOfTab` and `regKeyOf` agree on an identity-bearing key — the widening
-- is answer-preserving for every pre-A-2.4 caller.
-- > regKeyOfTab (TkIdent identIfaceFooM) == regKeyOf identIfaceFooM
-- True
-- > regKeyRender (regKeyOfTab (TkIdent identIfaceFooM)) == regKeyRender (regKeyOf identIfaceFooM)
-- True
-- > regKeyTabAt (TkIdent identIfaceFooM) 3 == regKeyAt identIfaceFooM 3
-- True

-- `tabKeyRender`'s identity arm IS `identKey`, unchanged, and its bare arm is
-- four netstrings with a `bare` tag that `originTag` cannot produce.
-- > tabKeyRender (TkIdent identTypeFooM) == identKey identTypeFooM
-- True
-- > tabKeyRender (TkBare NsType "Foo")
-- "4:type4:bare0:3:Foo"

-- Namespace still discriminates on the bare half, through the render too.
-- > regKeyRender (regKeyOfTab (TkBare NsType "Same")) == regKeyRender (regKeyOfTab (TkBare NsIface "Same"))
-- False

-- The ident-COUNT prefix is present on a `TabKey`-built key exactly as on an
-- `Ident`-built one (see the count-prefix paragraph in the module header).
--
-- 🚨 THE BLANK LINE BELOW IS PART OF THE ASSERTION, NOT SPACING. A doctest's
-- expected block runs to the next bare `--`, blank line, or `-- >` line
-- (`splitIntoBlocks`/`extractGo`, `compiler/tools/doctest.mdk`), so an
-- unseparated prose paragraph underneath is SWALLOWED INTO the expected text
-- and the example fails with `expected: True <six lines of prose>` /
-- `actual: True`. That is exactly how this line reddened `inlang` on PR #1270:
-- A-2.4 appended this example and #1268 prepended the F5 header below it, each
-- green alone, and git merged the two seams with no blank line between them —
-- a conflict-free merge that no gate on either branch could have seen. Derive
-- the whole file's exposure rather than eyeballing this one site: every
-- example's expected block, and any with more than one line, falls out of
-- replaying those two functions over the comment stream.
-- > startsWith "1:1" (regKeyRender slotPA)
-- True

-- ── F5: HeadKey — the head-tycon projection's key (A-2.2) ──────────────────
-- Fixtures mirror the `TabKey` ones above, because the declaration half of a
-- `HeadKey` IS a `TabKey`: `headA`/`headZ` are the SAME bare head name `Box`
-- declared by two unrelated modules — the #1069/#1090/#1070 collision shape
-- verbatim, and the reason the projection had to widen at all.
--
-- ⚠️ `headU` is spelled with the CONSTRUCTORS, not as `headKeyOfCon
-- OriginUnresolved "Box"`, for the reason `tabU` above gives: the #1110
-- ratchet in `test/typecheck_compiler_source.sh` pins the SET OF FILES
-- carrying a non-comment `OriginUnresolved` mention. Nothing is lost — the
-- mint's own answer for that origin is asserted below via `OriginModule ""`,
-- the other input `mkIdent` refuses, and both land in the same half.
headA : HeadKey
headA = headKeyOfCon (OriginModule "apub") "Box"

headZ : HeadKey
headZ = headKeyOfCon (OriginModule "zopapub") "Box"

headU : HeadKey
headU = HkDecl (TkBare NsType "Box")

-- The mint is total, it delegates the identity question to `tabKeyOf`, and it
-- is the one site that fixes the namespace to `NsType`.
-- > headKeyOfCon (OriginModule "apub") "Box" == HkDecl (TkIdent (Ident NsType identOriginBuiltin "Box"))
-- False
-- > headKeyOfCon OriginBuiltin "Box" == HkDecl (TkIdent (Ident NsType identOriginBuiltin "Box"))
-- True
-- > headKeyOfCon (OriginModule "") "Box" == HkDecl (TkBare NsType "Box")
-- True
-- > headKeyOfCon (OriginModule "apub") "Box" == HkDecl (tabKeyOf NsIface (OriginModule "apub") "Box")
-- False

-- 🚨 THE POINT OF THE WIDENING: two modules' same-named heads are now DISTINCT
-- keys, where the old `Option String` made them the same string.
-- > headA == headZ
-- False
-- > headA == headKeyOfCon (OriginModule "apub") "Box"
-- True

-- A declaration head and a rigid type variable never equate, in either
-- direction — §8 I6.1, which is why `HkRigid` is a separate inhabitant rather
-- than a `TkBare` with a parameter name in it.
-- > headA == HkRigid "Box"
-- False
-- > headU == HkRigid "Box"
-- False
-- > HkRigid "Box" == HkRigid "Box"
-- True

-- Inside the declaration half, `TabKey`'s own separation is inherited: an
-- identity-bearing head is not an identity-less one, and two identity-less
-- heads of the same name still match — which is what keeps the flat/
-- single-file path answering exactly as it does today.
-- > headA == headU
-- False
-- > headU == HkDecl (TkBare NsType "Box")
-- True

-- 🚨 ANSWER-PRESERVATION IS STRUCTURAL, AND THE DOCTESTS BELOW ONLY
-- ILLUSTRATE IT. The proof is that `headKeyName` inverts the mint on the name,
-- unconditionally and for every input either projection can see:
--
--   * `headKeyOfCon o n = HkDecl (tabKeyOf NsType o n)`, and `tabKeyOf` puts
--     `n` in whichever half it picks (`TkIdent (Ident _ _ n)` via `mkIdent`,
--     or `TkBare _ n`), so `tabKeyName` — and therefore `headKeyName` —
--     returns that same `n` whatever the origin was.  No origin can route `n`
--     anywhere `headKeyName` does not read it back out.
--   * `headKeyName (HkRigid n) = n` by its own clause.
--
-- Since those are the only two ways a `HeadKey` is built, `headKeyName` of the
-- new key is the `String` the old `Option String` projection returned, at
-- every call site, with no case analysis left over. The list below is one
-- witness per class the two projections actually produce — a module-declared
-- head, a second module's same-named head, an identity-less head, a rigid
-- variable, and a builtin tuple head — not the argument itself.
-- > map headKeyName [headA, headZ, headU, HkRigid "a", headKeyOfCon OriginBuiltin "__tuple2__"]
-- ["Box", "Box", "Box", "a", "__tuple2__"]

-- `headKeyIdent` (#1319 unit 3): the identity a head carries, for a consumer
-- selecting a ROW rather than keying a bucket.  Two modules' same-named heads
-- give DIFFERENT identities — that is the whole discrimination the record
-- lookup in `types/typecheck.mdk` buys from it — and BOTH identity-less
-- inhabitants answer `None`, which is `tabKeyEq`'s absence rule at the row
-- layer rather than a fallback.
-- > headKeyIdent headA == headKeyIdent headZ
-- False
-- > headKeyIdent headA == headKeyIdent (headKeyOfCon (OriginModule "apub") "Box")
-- True
-- > headKeyIdent (headKeyOfCon OriginBuiltin "Box") == Some (Ident NsType identOriginBuiltin "Box")
-- True
-- > headKeyIdent headU
-- None
-- > headKeyIdent (HkRigid "a")
-- None
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Ns" true) (mem "Ident" true) (mem "IdentOrigin" false) (mem "TyConOrigin" true) (mem "identOriginOf" false) (mem "identOriginFold" false) (mem "identOriginBuiltin" false) (mem "mkIdent" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omInsert" false) (mem "omLookup" false) (mem "omHasKey" false) (mem "omDelete" false) (mem "omSize" false))))
(DUse false (UseGroup ("support" "util") ((mem "lenKey" false) (mem "listLen" false) (mem "joinWith" false) (mem "filterList" false) (mem "startsWith" false))))
(DUse false (UseGroup ("list") ((mem "sort" false))))
(DUse false (UseGroup ("map") ((mem "toList" false))))
(DTypeSig false "nsTag" (TyFun (TyCon "Ns") (TyCon "String")))
(DFunDef false "nsTag" ((PCon "NsType")) (ELit (LString "type")))
(DFunDef false "nsTag" ((PCon "NsIface")) (ELit (LString "iface")))
(DFunDef false "nsTag" ((PCon "NsMethod")) (ELit (LString "method")))
(DFunDef false "nsTag" ((PCon "NsCtor")) (ELit (LString "ctor")))
(DFunDef false "nsTag" ((PCon "NsField")) (ELit (LString "field")))
(DFunDef false "nsTag" ((PCon "NsValue")) (ELit (LString "value")))
(DTypeSig false "originTag" (TyFun (TyCon "IdentOrigin") (TyCon "String")))
(DFunDef false "originTag" ((PVar "origin")) (EApp (EApp (EApp (EVar "identOriginFold") (ELit (LString "builtin"))) (ELam (PWild) (ELit (LString "module")))) (EVar "origin")))
(DTypeSig false "originModuleOf" (TyFun (TyCon "IdentOrigin") (TyCon "String")))
(DFunDef false "originModuleOf" ((PVar "origin")) (EApp (EApp (EApp (EVar "identOriginFold") (ELit (LString ""))) (ELam ((PVar "m")) (EVar "m"))) (EVar "origin")))
(DTypeSig true "identKey" (TyFun (TyCon "Ident") (TyCon "String")))
(DFunDef false "identKey" ((PCon "Ident" (PVar "ns") (PVar "origin") (PVar "name"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EApp (EVar "lenKey") (EApp (EVar "nsTag") (EVar "ns"))) (EApp (EVar "lenKey") (EApp (EVar "originTag") (EVar "origin")))) (EApp (EVar "lenKey") (EApp (EVar "originModuleOf") (EVar "origin")))) (EApp (EVar "lenKey") (EVar "name"))))
(DTypeSig true "tabKeyRender" (TyFun (TyCon "TabKey") (TyCon "String")))
(DFunDef false "tabKeyRender" ((PCon "TkIdent" (PVar "ident"))) (EApp (EVar "identKey") (EVar "ident")))
(DFunDef false "tabKeyRender" ((PCon "TkBare" (PVar "ns") (PVar "name"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EApp (EVar "lenKey") (EApp (EVar "nsTag") (EVar "ns"))) (EApp (EVar "lenKey") (ELit (LString "bare")))) (EApp (EVar "lenKey") (ELit (LString "")))) (EApp (EVar "lenKey") (EVar "name"))))
(DTypeSig true "identKeys" (TyFun (TyApp (TyCon "List") (TyCon "Ident")) (TyCon "String")))
(DFunDef false "identKeys" ((PVar "idents")) (EApp (EApp (EVar "joinWith") (ELit (LString ""))) (EApp (EApp (EVar "map") (EVar "identKey")) (EVar "idents"))))
(DTypeSig true "tabKeys" (TyFun (TyApp (TyCon "List") (TyCon "TabKey")) (TyCon "String")))
(DFunDef false "tabKeys" ((PVar "keys")) (EApp (EApp (EVar "joinWith") (ELit (LString ""))) (EApp (EApp (EVar "map") (EVar "tabKeyRender")) (EVar "keys"))))
(DTypeSig false "ordKey" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "ordKey" ((PVar "n")) (EApp (EVar "lenKey") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "n"))) (ELit (LString "")))))
(DData Public "RegKey" () ((variant "RegKey" (ConPos (TyApp (TyCon "List") (TyCon "TabKey")) (TyApp (TyCon "List") (TyCon "Int"))))) ())
(DImpl true "Eq" ((TyCon "RegKey")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "RegKey" (PVar "__a0") (PVar "__a1")) (PCon "RegKey" (PVar "__b0") (PVar "__b1"))) () (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "eq") (EVar "__a1")) (EVar "__b1"))))))))
(DImpl true "Ord" ((TyCon "RegKey")) () ((im "compare" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "RegKey" (PVar "__a0") (PVar "__a1")) (PCon "RegKey" (PVar "__b0") (PVar "__b1"))) () (EMatch (EApp (EApp (EVar "compare") (EVar "__a0")) (EVar "__b0")) (arm (PCon "Eq") () (EApp (EApp (EVar "compare") (EVar "__a1")) (EVar "__b1"))) (arm (PVar "__c") () (EVar "__c"))))))))
(DImpl true "Debug" ((TyCon "RegKey")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "RegKey" (PVar "__a0") (PVar "__a1")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "RegKey ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a1")))))))))
(DTypeSig true "regKeyOf" (TyFun (TyCon "Ident") (TyCon "RegKey")))
(DFunDef false "regKeyOf" ((PVar "ident")) (EApp (EApp (EVar "RegKey") (EListLit (EApp (EVar "TkIdent") (EVar "ident")))) (EListLit)))
(DTypeSig true "regKeyN" (TyFun (TyApp (TyCon "List") (TyCon "Ident")) (TyCon "RegKey")))
(DFunDef false "regKeyN" ((PVar "idents")) (EApp (EApp (EVar "RegKey") (EApp (EApp (EVar "map") (EVar "TkIdent")) (EVar "idents"))) (EListLit)))
(DTypeSig true "regKeyAt" (TyFun (TyCon "Ident") (TyFun (TyCon "Int") (TyCon "RegKey"))))
(DFunDef false "regKeyAt" ((PVar "ident") (PVar "slot")) (EApp (EApp (EVar "RegKey") (EListLit (EApp (EVar "TkIdent") (EVar "ident")))) (EListLit (EVar "slot"))))
(DTypeSig true "regKeyNAt" (TyFun (TyApp (TyCon "List") (TyCon "Ident")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "RegKey"))))
(DFunDef false "regKeyNAt" ((PVar "idents") (PVar "ords")) (EApp (EApp (EVar "RegKey") (EApp (EApp (EVar "map") (EVar "TkIdent")) (EVar "idents"))) (EVar "ords")))
(DTypeSig true "regKeyOfTab" (TyFun (TyCon "TabKey") (TyCon "RegKey")))
(DFunDef false "regKeyOfTab" ((PVar "key")) (EApp (EApp (EVar "RegKey") (EListLit (EVar "key"))) (EListLit)))
(DTypeSig true "regKeyTabAt" (TyFun (TyCon "TabKey") (TyFun (TyCon "Int") (TyCon "RegKey"))))
(DFunDef false "regKeyTabAt" ((PVar "key") (PVar "slot")) (EApp (EApp (EVar "RegKey") (EListLit (EVar "key"))) (EListLit (EVar "slot"))))
(DTypeSig true "regKeyNTab" (TyFun (TyApp (TyCon "List") (TyCon "TabKey")) (TyCon "RegKey")))
(DFunDef false "regKeyNTab" ((PVar "keys")) (EApp (EApp (EVar "RegKey") (EVar "keys")) (EListLit)))
(DTypeSig true "regKeyNTabAt" (TyFun (TyApp (TyCon "List") (TyCon "TabKey")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "RegKey"))))
(DFunDef false "regKeyNTabAt" ((PVar "keys") (PVar "ords")) (EApp (EApp (EVar "RegKey") (EVar "keys")) (EVar "ords")))
(DTypeSig true "regKeyTabs" (TyFun (TyCon "RegKey") (TyApp (TyCon "List") (TyCon "TabKey"))))
(DFunDef false "regKeyTabs" ((PCon "RegKey" (PVar "keys") PWild)) (EVar "keys"))
(DTypeSig true "regKeyOrdinals" (TyFun (TyCon "RegKey") (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "regKeyOrdinals" ((PCon "RegKey" PWild (PVar "ords"))) (EVar "ords"))
(DTypeSig true "regKeyRender" (TyFun (TyCon "RegKey") (TyCon "String")))
(DFunDef false "regKeyRender" ((PCon "RegKey" (PVar "keys") (PVar "ords"))) (EBinOp "++" (EBinOp "++" (EApp (EVar "lenKey") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "listLen") (EVar "keys")))) (ELit (LString "")))) (EApp (EVar "tabKeys") (EVar "keys"))) (EApp (EApp (EVar "joinWith") (ELit (LString ""))) (EApp (EApp (EVar "map") (EVar "ordKey")) (EVar "ords")))))
(DData Public "Registry" ("v") ((variant "Registry" (ConPos (TyApp (TyCon "OrdMap") (TyTuple (TyCon "RegKey") (TyVar "v")))))) ())
(DTypeSig true "regEmpty" (TyApp (TyCon "Registry") (TyVar "v")))
(DFunDef false "regEmpty" () (EApp (EVar "Registry") (EVar "omEmpty")))
(DTypeSig true "regLookupK" (TyFun (TyCon "RegKey") (TyFun (TyApp (TyCon "Registry") (TyVar "v")) (TyApp (TyCon "Option") (TyVar "v")))))
(DFunDef false "regLookupK" ((PVar "k") (PCon "Registry" (PVar "m"))) (EApp (EApp (EVar "map") (ELam ((PTuple PWild (PVar "v"))) (EVar "v"))) (EApp (EApp (EVar "omLookup") (EApp (EVar "regKeyRender") (EVar "k"))) (EVar "m"))))
(DTypeSig true "regLookup" (TyFun (TyCon "Ident") (TyFun (TyApp (TyCon "Registry") (TyVar "v")) (TyApp (TyCon "Option") (TyVar "v")))))
(DFunDef false "regLookup" ((PVar "ident") (PVar "r")) (EApp (EApp (EVar "regLookupK") (EApp (EVar "regKeyOf") (EVar "ident"))) (EVar "r")))
(DTypeSig true "regInsertCheckedK" (TyFun (TyCon "RegKey") (TyFun (TyVar "v") (TyFun (TyApp (TyCon "Registry") (TyVar "v")) (TyTuple (TyApp (TyCon "Registry") (TyVar "v")) (TyCon "Bool"))))))
(DFunDef false "regInsertCheckedK" ((PVar "k") (PVar "v") (PCon "Registry" (PVar "m"))) (EBlock (DoLet false false (PVar "s") (EApp (EVar "regKeyRender") (EVar "k"))) (DoExpr (ETuple (EApp (EVar "Registry") (EApp (EApp (EApp (EVar "omInsert") (EVar "s")) (ETuple (EVar "k") (EVar "v"))) (EVar "m"))) (EApp (EApp (EVar "omHasKey") (EVar "s")) (EVar "m"))))))
(DTypeSig true "regInsertChecked" (TyFun (TyCon "Ident") (TyFun (TyVar "v") (TyFun (TyApp (TyCon "Registry") (TyVar "v")) (TyTuple (TyApp (TyCon "Registry") (TyVar "v")) (TyCon "Bool"))))))
(DFunDef false "regInsertChecked" ((PVar "ident") (PVar "v") (PVar "r")) (EApp (EApp (EApp (EVar "regInsertCheckedK") (EApp (EVar "regKeyOf") (EVar "ident"))) (EVar "v")) (EVar "r")))
(DTypeSig true "regInsertK" (TyFun (TyCon "RegKey") (TyFun (TyVar "v") (TyFun (TyApp (TyCon "Registry") (TyVar "v")) (TyApp (TyCon "Registry") (TyVar "v"))))))
(DFunDef false "regInsertK" ((PVar "k") (PVar "v") (PCon "Registry" (PVar "m"))) (EApp (EVar "Registry") (EApp (EApp (EApp (EVar "omInsert") (EApp (EVar "regKeyRender") (EVar "k"))) (ETuple (EVar "k") (EVar "v"))) (EVar "m"))))
(DTypeSig true "regInsert" (TyFun (TyCon "Ident") (TyFun (TyVar "v") (TyFun (TyApp (TyCon "Registry") (TyVar "v")) (TyApp (TyCon "Registry") (TyVar "v"))))))
(DFunDef false "regInsert" ((PVar "ident") (PVar "v") (PVar "r")) (EApp (EApp (EApp (EVar "regInsertK") (EApp (EVar "regKeyOf") (EVar "ident"))) (EVar "v")) (EVar "r")))
(DTypeSig true "regDeleteK" (TyFun (TyCon "RegKey") (TyFun (TyApp (TyCon "Registry") (TyVar "v")) (TyApp (TyCon "Registry") (TyVar "v")))))
(DFunDef false "regDeleteK" ((PVar "k") (PCon "Registry" (PVar "m"))) (EApp (EVar "Registry") (EApp (EApp (EVar "omDelete") (EApp (EVar "regKeyRender") (EVar "k"))) (EVar "m"))))
(DTypeSig true "regDelete" (TyFun (TyCon "Ident") (TyFun (TyApp (TyCon "Registry") (TyVar "v")) (TyApp (TyCon "Registry") (TyVar "v")))))
(DFunDef false "regDelete" ((PVar "ident") (PVar "r")) (EApp (EApp (EVar "regDeleteK") (EApp (EVar "regKeyOf") (EVar "ident"))) (EVar "r")))
(DTypeSig true "regEntries" (TyFun (TyApp (TyCon "Registry") (TyVar "v")) (TyApp (TyCon "List") (TyTuple (TyCon "RegKey") (TyVar "v")))))
(DFunDef false "regEntries" ((PCon "Registry" (PVar "m"))) (EApp (EApp (EVar "map") (EVar "snd")) (EApp (EVar "toList") (EVar "m"))))
(DTypeSig true "regKeys" (TyFun (TyApp (TyCon "Registry") (TyVar "v")) (TyApp (TyCon "List") (TyCon "RegKey"))))
(DFunDef false "regKeys" ((PVar "r")) (EApp (EApp (EVar "map") (EVar "fst")) (EApp (EVar "regEntries") (EVar "r"))))
(DTypeSig true "regSize" (TyFun (TyApp (TyCon "Registry") (TyVar "v")) (TyCon "Int")))
(DFunDef false "regSize" ((PCon "Registry" (PVar "m"))) (EApp (EVar "omSize") (EVar "m")))
(DTypeSig true "regFilter" (TyFun (TyFun (TyTuple (TyCon "RegKey") (TyVar "v")) (TyCon "Bool")) (TyFun (TyApp (TyCon "Registry") (TyVar "v")) (TyApp (TyCon "Registry") (TyVar "v")))))
(DFunDef false "regFilter" ((PVar "p") (PVar "r")) (EApp (EVar "regFromEntries") (EApp (EApp (EVar "filterList") (EVar "p")) (EApp (EVar "regEntries") (EVar "r")))))
(DTypeSig true "regFromEntries" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "RegKey") (TyVar "v"))) (TyApp (TyCon "Registry") (TyVar "v"))))
(DFunDef false "regFromEntries" ((PVar "entries")) (EApp (EApp (EVar "regFromEntriesGo") (EVar "entries")) (EVar "regEmpty")))
(DTypeSig false "regFromEntriesGo" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "RegKey") (TyVar "v"))) (TyFun (TyApp (TyCon "Registry") (TyVar "v")) (TyApp (TyCon "Registry") (TyVar "v")))))
(DFunDef false "regFromEntriesGo" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "regFromEntriesGo" ((PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "regFromEntriesGo") (EVar "rest")) (EApp (EApp (EApp (EVar "regInsertK") (EVar "k")) (EVar "v")) (EVar "acc"))))
(DTypeSig true "regMerge" (TyFun (TyApp (TyCon "Registry") (TyVar "v")) (TyFun (TyApp (TyCon "Registry") (TyVar "v")) (TyApp (TyCon "Registry") (TyVar "v")))))
(DFunDef false "regMerge" ((PVar "older") (PVar "newer")) (EApp (EApp (EVar "regFromEntriesGo") (EApp (EVar "regEntries") (EVar "newer"))) (EVar "older")))
(DData Public "MultiRegistry" ("v") ((variant "MultiRegistry" (ConPos (TyApp (TyCon "OrdMap") (TyTuple (TyCon "RegKey") (TyApp (TyCon "List") (TyVar "v"))))))) ())
(DTypeSig true "mregEmpty" (TyApp (TyCon "MultiRegistry") (TyVar "v")))
(DFunDef false "mregEmpty" () (EApp (EVar "MultiRegistry") (EVar "omEmpty")))
(DTypeSig true "mregAddK" (TyFun (TyCon "RegKey") (TyFun (TyVar "v") (TyFun (TyApp (TyCon "MultiRegistry") (TyVar "v")) (TyApp (TyCon "MultiRegistry") (TyVar "v"))))))
(DFunDef false "mregAddK" ((PVar "k") (PVar "v") (PCon "MultiRegistry" (PVar "m"))) (EBlock (DoLet false false (PVar "s") (EApp (EVar "regKeyRender") (EVar "k"))) (DoExpr (EMatch (EApp (EApp (EVar "omLookup") (EVar "s")) (EVar "m")) (arm (PCon "Some" (PTuple PWild (PVar "vs"))) () (EApp (EVar "MultiRegistry") (EApp (EApp (EApp (EVar "omInsert") (EVar "s")) (ETuple (EVar "k") (EBinOp "::" (EVar "v") (EVar "vs")))) (EVar "m")))) (arm (PCon "None") () (EApp (EVar "MultiRegistry") (EApp (EApp (EApp (EVar "omInsert") (EVar "s")) (ETuple (EVar "k") (EListLit (EVar "v")))) (EVar "m"))))))))
(DTypeSig true "mregAdd" (TyFun (TyCon "Ident") (TyFun (TyVar "v") (TyFun (TyApp (TyCon "MultiRegistry") (TyVar "v")) (TyApp (TyCon "MultiRegistry") (TyVar "v"))))))
(DFunDef false "mregAdd" ((PVar "ident") (PVar "v") (PVar "mr")) (EApp (EApp (EApp (EVar "mregAddK") (EApp (EVar "regKeyOf") (EVar "ident"))) (EVar "v")) (EVar "mr")))
(DTypeSig true "mregAppendK" (TyFun (TyCon "RegKey") (TyFun (TyVar "v") (TyFun (TyApp (TyCon "MultiRegistry") (TyVar "v")) (TyApp (TyCon "MultiRegistry") (TyVar "v"))))))
(DFunDef false "mregAppendK" ((PVar "k") (PVar "v") (PCon "MultiRegistry" (PVar "m"))) (EBlock (DoLet false false (PVar "s") (EApp (EVar "regKeyRender") (EVar "k"))) (DoExpr (EMatch (EApp (EApp (EVar "omLookup") (EVar "s")) (EVar "m")) (arm (PCon "Some" (PTuple PWild (PVar "vs"))) () (EApp (EVar "MultiRegistry") (EApp (EApp (EApp (EVar "omInsert") (EVar "s")) (ETuple (EVar "k") (EBinOp "++" (EVar "vs") (EListLit (EVar "v"))))) (EVar "m")))) (arm (PCon "None") () (EApp (EVar "MultiRegistry") (EApp (EApp (EApp (EVar "omInsert") (EVar "s")) (ETuple (EVar "k") (EListLit (EVar "v")))) (EVar "m"))))))))
(DTypeSig true "mregLookupK" (TyFun (TyCon "RegKey") (TyFun (TyApp (TyCon "MultiRegistry") (TyVar "v")) (TyApp (TyCon "List") (TyVar "v")))))
(DFunDef false "mregLookupK" ((PVar "k") (PCon "MultiRegistry" (PVar "m"))) (EMatch (EApp (EApp (EVar "omLookup") (EApp (EVar "regKeyRender") (EVar "k"))) (EVar "m")) (arm (PCon "Some" (PTuple PWild (PVar "vs"))) () (EVar "vs")) (arm (PCon "None") () (EListLit))))
(DTypeSig true "mregLookup" (TyFun (TyCon "Ident") (TyFun (TyApp (TyCon "MultiRegistry") (TyVar "v")) (TyApp (TyCon "List") (TyVar "v")))))
(DFunDef false "mregLookup" ((PVar "ident") (PVar "mr")) (EApp (EApp (EVar "mregLookupK") (EApp (EVar "regKeyOf") (EVar "ident"))) (EVar "mr")))
(DTypeSig true "mregEntries" (TyFun (TyApp (TyCon "MultiRegistry") (TyVar "v")) (TyApp (TyCon "List") (TyTuple (TyCon "RegKey") (TyApp (TyCon "List") (TyVar "v"))))))
(DFunDef false "mregEntries" ((PCon "MultiRegistry" (PVar "m"))) (EApp (EApp (EVar "map") (EVar "snd")) (EApp (EVar "toList") (EVar "m"))))
(DTypeSig true "mregKeys" (TyFun (TyApp (TyCon "MultiRegistry") (TyVar "v")) (TyApp (TyCon "List") (TyCon "RegKey"))))
(DFunDef false "mregKeys" ((PVar "mr")) (EApp (EApp (EVar "map") (EVar "fst")) (EApp (EVar "mregEntries") (EVar "mr"))))
(DTypeSig true "mregSize" (TyFun (TyApp (TyCon "MultiRegistry") (TyVar "v")) (TyCon "Int")))
(DFunDef false "mregSize" ((PCon "MultiRegistry" (PVar "m"))) (EApp (EVar "omSize") (EVar "m")))
(DTypeSig true "mregMerge" (TyFun (TyApp (TyCon "MultiRegistry") (TyVar "v")) (TyFun (TyApp (TyCon "MultiRegistry") (TyVar "v")) (TyApp (TyCon "MultiRegistry") (TyVar "v")))))
(DFunDef false "mregMerge" ((PVar "older") (PVar "newer")) (EApp (EApp (EVar "mregMergeGo") (EApp (EVar "mregEntries") (EVar "newer"))) (EVar "older")))
(DTypeSig false "mregMergeGo" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "RegKey") (TyApp (TyCon "List") (TyVar "v")))) (TyFun (TyApp (TyCon "MultiRegistry") (TyVar "v")) (TyApp (TyCon "MultiRegistry") (TyVar "v")))))
(DFunDef false "mregMergeGo" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "mregMergeGo" ((PCons (PTuple (PVar "k") (PVar "vs")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "mregMergeGo") (EVar "rest")) (EApp (EApp (EApp (EVar "mregAddAll") (EVar "k")) (EVar "vs")) (EVar "acc"))))
(DTypeSig false "mregAddAll" (TyFun (TyCon "RegKey") (TyFun (TyApp (TyCon "List") (TyVar "v")) (TyFun (TyApp (TyCon "MultiRegistry") (TyVar "v")) (TyApp (TyCon "MultiRegistry") (TyVar "v"))))))
(DFunDef false "mregAddAll" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "mregAddAll" ((PVar "k") (PCons (PVar "v") (PVar "vs")) (PVar "acc")) (EApp (EApp (EApp (EVar "mregAddAll") (EVar "k")) (EVar "vs")) (EApp (EApp (EApp (EVar "mregAddK") (EVar "k")) (EVar "v")) (EVar "acc"))))
(DData Public "SetRegistry" () ((variant "SetRegistry" (ConPos (TyApp (TyCon "OrdMap") (TyCon "RegKey"))))) ())
(DTypeSig true "sregEmpty" (TyCon "SetRegistry"))
(DFunDef false "sregEmpty" () (EApp (EVar "SetRegistry") (EVar "omEmpty")))
(DTypeSig true "sregAddK" (TyFun (TyCon "RegKey") (TyFun (TyCon "SetRegistry") (TyCon "SetRegistry"))))
(DFunDef false "sregAddK" ((PVar "k") (PCon "SetRegistry" (PVar "m"))) (EApp (EVar "SetRegistry") (EApp (EApp (EApp (EVar "omInsert") (EApp (EVar "regKeyRender") (EVar "k"))) (EVar "k")) (EVar "m"))))
(DTypeSig true "sregAdd" (TyFun (TyCon "Ident") (TyFun (TyCon "SetRegistry") (TyCon "SetRegistry"))))
(DFunDef false "sregAdd" ((PVar "ident") (PVar "s")) (EApp (EApp (EVar "sregAddK") (EApp (EVar "regKeyOf") (EVar "ident"))) (EVar "s")))
(DTypeSig true "sregMemberK" (TyFun (TyCon "RegKey") (TyFun (TyCon "SetRegistry") (TyCon "Bool"))))
(DFunDef false "sregMemberK" ((PVar "k") (PCon "SetRegistry" (PVar "m"))) (EApp (EApp (EVar "omHasKey") (EApp (EVar "regKeyRender") (EVar "k"))) (EVar "m")))
(DTypeSig true "sregMember" (TyFun (TyCon "Ident") (TyFun (TyCon "SetRegistry") (TyCon "Bool"))))
(DFunDef false "sregMember" ((PVar "ident") (PVar "s")) (EApp (EApp (EVar "sregMemberK") (EApp (EVar "regKeyOf") (EVar "ident"))) (EVar "s")))
(DTypeSig true "sregSize" (TyFun (TyCon "SetRegistry") (TyCon "Int")))
(DFunDef false "sregSize" ((PCon "SetRegistry" (PVar "m"))) (EApp (EVar "omSize") (EVar "m")))
(DTypeSig true "sregKeys" (TyFun (TyCon "SetRegistry") (TyApp (TyCon "List") (TyCon "RegKey"))))
(DFunDef false "sregKeys" ((PCon "SetRegistry" (PVar "m"))) (EApp (EApp (EVar "map") (EVar "snd")) (EApp (EVar "toList") (EVar "m"))))
(DTypeSig true "sregMerge" (TyFun (TyCon "SetRegistry") (TyFun (TyCon "SetRegistry") (TyCon "SetRegistry"))))
(DFunDef false "sregMerge" ((PVar "older") (PVar "newer")) (EApp (EApp (EVar "sregMergeGo") (EApp (EVar "sregKeys") (EVar "newer"))) (EVar "older")))
(DTypeSig false "sregMergeGo" (TyFun (TyApp (TyCon "List") (TyCon "RegKey")) (TyFun (TyCon "SetRegistry") (TyCon "SetRegistry"))))
(DFunDef false "sregMergeGo" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "sregMergeGo" ((PCons (PVar "k") (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "sregMergeGo") (EVar "rest")) (EApp (EApp (EVar "sregAddK") (EVar "k")) (EVar "acc"))))
(DData Public "TabKey" () ((variant "TkIdent" (ConPos (TyCon "Ident"))) (variant "TkBare" (ConPos (TyCon "Ns") (TyCon "String")))) ())
(DImpl true "Eq" ((TyCon "TabKey")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "TkIdent" (PVar "__a0")) (PCon "TkIdent" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "TkBare" (PVar "__a0") (PVar "__a1")) (PCon "TkBare" (PVar "__b0") (PVar "__b1"))) () (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "eq") (EVar "__a1")) (EVar "__b1")))) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Ord" ((TyCon "TabKey")) () ((im "compare" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "TkIdent" (PVar "__a0")) (PCon "TkIdent" (PVar "__b0"))) () (EApp (EApp (EVar "compare") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "TkIdent" (PVar "__a0")) (PCon "TkBare" (PVar "__b0") (PVar "__b1"))) () (EVar "Lt")) (arm (PTuple (PCon "TkBare" (PVar "__a0") (PVar "__a1")) (PCon "TkIdent" (PVar "__b0"))) () (EVar "Gt")) (arm (PTuple (PCon "TkBare" (PVar "__a0") (PVar "__a1")) (PCon "TkBare" (PVar "__b0") (PVar "__b1"))) () (EMatch (EApp (EApp (EVar "compare") (EVar "__a0")) (EVar "__b0")) (arm (PCon "Eq") () (EApp (EApp (EVar "compare") (EVar "__a1")) (EVar "__b1"))) (arm (PVar "__c") () (EVar "__c"))))))))
(DImpl true "Debug" ((TyCon "TabKey")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "TkIdent" (PVar "__a0")) () (EBinOp "++" (ELit (LString "TkIdent ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0"))))) (arm (PCon "TkBare" (PVar "__a0") (PVar "__a1")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "TkBare ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a1")))))))))
(DTypeSig true "tabKeyOf" (TyFun (TyCon "Ns") (TyFun (TyCon "TyConOrigin") (TyFun (TyCon "String") (TyCon "TabKey")))))
(DFunDef false "tabKeyOf" ((PVar "ns") (PVar "origin") (PVar "name")) (EMatch (EApp (EApp (EApp (EVar "mkIdent") (EVar "ns")) (EVar "origin")) (EVar "name")) (arm (PCon "Some" (PVar "ident")) () (EApp (EVar "TkIdent") (EVar "ident"))) (arm (PCon "None") () (EApp (EApp (EVar "TkBare") (EVar "ns")) (EVar "name")))))
(DTypeSig true "tabKeyName" (TyFun (TyCon "TabKey") (TyCon "String")))
(DFunDef false "tabKeyName" ((PCon "TkIdent" (PCon "Ident" PWild PWild (PVar "name")))) (EVar "name"))
(DFunDef false "tabKeyName" ((PCon "TkBare" PWild (PVar "name"))) (EVar "name"))
(DTypeSig false "tabKeyEq" (TyFun (TyCon "TabKey") (TyFun (TyCon "TabKey") (TyCon "Bool"))))
(DFunDef false "tabKeyEq" ((PCon "TkIdent" (PCon "Ident" (PVar "ns1") (PVar "o1") (PVar "n1"))) (PCon "TkIdent" (PCon "Ident" (PVar "ns2") (PVar "o2") (PVar "n2")))) (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "n1") (EVar "n2")) (EBinOp "==" (EVar "ns1") (EVar "ns2"))) (EBinOp "==" (EVar "o1") (EVar "o2"))))
(DFunDef false "tabKeyEq" ((PCon "TkBare" (PVar "ns1") (PVar "n1")) (PCon "TkBare" (PVar "ns2") (PVar "n2"))) (EBinOp "&&" (EBinOp "==" (EVar "n1") (EVar "n2")) (EBinOp "==" (EVar "ns1") (EVar "ns2"))))
(DFunDef false "tabKeyEq" (PWild PWild) (EVar "False"))
(DTypeSig true "lookupTab" (TyFun (TyCon "TabKey") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyVar "v"))) (TyApp (TyCon "Option") (TyVar "v")))))
(DFunDef false "lookupTab" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupTab" ((PVar "k") (PCons (PTuple (PVar "k2") (PVar "v")) (PVar "rest"))) (EIf (EApp (EApp (EVar "tabKeyEq") (EVar "k")) (EVar "k2")) (EApp (EVar "Some") (EVar "v")) (EApp (EApp (EVar "lookupTab") (EVar "k")) (EVar "rest"))))
(DTypeSig true "tabHasName" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyVar "v"))) (TyCon "Bool"))))
(DFunDef false "tabHasName" (PWild (PList)) (EVar "False"))
(DFunDef false "tabHasName" ((PVar "n") (PCons (PTuple (PVar "k") PWild) (PVar "rest"))) (EBinOp "||" (EBinOp "==" (EApp (EVar "tabKeyName") (EVar "k")) (EVar "n")) (EApp (EApp (EVar "tabHasName") (EVar "n")) (EVar "rest"))))
(DTypeSig false "regKeyEq" (TyFun (TyCon "RegKey") (TyFun (TyCon "RegKey") (TyCon "Bool"))))
(DFunDef false "regKeyEq" ((PCon "RegKey" (PVar "k1") (PVar "o1")) (PCon "RegKey" (PVar "k2") (PVar "o2"))) (EBinOp "&&" (EApp (EApp (EVar "intsEq") (EVar "o1")) (EVar "o2")) (EApp (EApp (EVar "tabKeysEq") (EVar "k1")) (EVar "k2"))))
(DTypeSig false "intsEq" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Bool"))))
(DFunDef false "intsEq" ((PList) (PList)) (EVar "True"))
(DFunDef false "intsEq" ((PCons (PVar "a") (PVar "as2")) (PCons (PVar "b") (PVar "bs"))) (EBinOp "&&" (EBinOp "==" (EVar "a") (EVar "b")) (EApp (EApp (EVar "intsEq") (EVar "as2")) (EVar "bs"))))
(DFunDef false "intsEq" (PWild PWild) (EVar "False"))
(DTypeSig false "tabKeysEq" (TyFun (TyApp (TyCon "List") (TyCon "TabKey")) (TyFun (TyApp (TyCon "List") (TyCon "TabKey")) (TyCon "Bool"))))
(DFunDef false "tabKeysEq" ((PList) (PList)) (EVar "True"))
(DFunDef false "tabKeysEq" ((PCons (PVar "a") (PVar "as2")) (PCons (PVar "b") (PVar "bs"))) (EBinOp "&&" (EApp (EApp (EVar "tabKeyEq") (EVar "a")) (EVar "b")) (EApp (EApp (EVar "tabKeysEq") (EVar "as2")) (EVar "bs"))))
(DFunDef false "tabKeysEq" (PWild PWild) (EVar "False"))
(DTypeSig true "lookupReg" (TyFun (TyCon "RegKey") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "RegKey") (TyVar "v"))) (TyApp (TyCon "Option") (TyVar "v")))))
(DFunDef false "lookupReg" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupReg" ((PVar "k") (PCons (PTuple (PVar "k2") (PVar "v")) (PVar "rest"))) (EIf (EApp (EApp (EVar "regKeyEq") (EVar "k")) (EVar "k2")) (EApp (EVar "Some") (EVar "v")) (EApp (EApp (EVar "lookupReg") (EVar "k")) (EVar "rest"))))
(DData Public "HeadKey" () ((variant "HkDecl" (ConPos (TyCon "TabKey"))) (variant "HkRigid" (ConPos (TyCon "String")))) ())
(DImpl true "Eq" ((TyCon "HeadKey")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "HkDecl" (PVar "__a0")) (PCon "HkDecl" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "HkRigid" (PVar "__a0")) (PCon "HkRigid" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Ord" ((TyCon "HeadKey")) () ((im "compare" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "HkDecl" (PVar "__a0")) (PCon "HkDecl" (PVar "__b0"))) () (EApp (EApp (EVar "compare") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "HkDecl" (PVar "__a0")) (PCon "HkRigid" (PVar "__b0"))) () (EVar "Lt")) (arm (PTuple (PCon "HkRigid" (PVar "__a0")) (PCon "HkDecl" (PVar "__b0"))) () (EVar "Gt")) (arm (PTuple (PCon "HkRigid" (PVar "__a0")) (PCon "HkRigid" (PVar "__b0"))) () (EApp (EApp (EVar "compare") (EVar "__a0")) (EVar "__b0")))))))
(DImpl true "Debug" ((TyCon "HeadKey")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "HkDecl" (PVar "__a0")) () (EBinOp "++" (ELit (LString "HkDecl ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0"))))) (arm (PCon "HkRigid" (PVar "__a0")) () (EBinOp "++" (ELit (LString "HkRigid ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0")))))))))
(DTypeSig true "headKeyOfCon" (TyFun (TyCon "TyConOrigin") (TyFun (TyCon "String") (TyCon "HeadKey"))))
(DFunDef false "headKeyOfCon" ((PVar "origin") (PVar "name")) (EApp (EVar "HkDecl") (EApp (EApp (EApp (EVar "tabKeyOf") (EVar "NsType")) (EVar "origin")) (EVar "name"))))
(DTypeSig true "headKeyName" (TyFun (TyCon "HeadKey") (TyCon "String")))
(DFunDef false "headKeyName" ((PCon "HkDecl" (PVar "k"))) (EApp (EVar "tabKeyName") (EVar "k")))
(DFunDef false "headKeyName" ((PCon "HkRigid" (PVar "name"))) (EVar "name"))
(DTypeSig true "headKeyDecl" (TyFun (TyCon "HeadKey") (TyApp (TyCon "Option") (TyCon "TabKey"))))
(DFunDef false "headKeyDecl" ((PCon "HkDecl" (PVar "key"))) (EApp (EVar "Some") (EVar "key")))
(DFunDef false "headKeyDecl" ((PCon "HkRigid" PWild)) (EVar "None"))
(DTypeSig true "headKeyIdent" (TyFun (TyCon "HeadKey") (TyApp (TyCon "Option") (TyCon "Ident"))))
(DFunDef false "headKeyIdent" ((PCon "HkDecl" (PCon "TkIdent" (PVar "ident")))) (EApp (EVar "Some") (EVar "ident")))
(DFunDef false "headKeyIdent" ((PCon "HkDecl" (PCon "TkBare" PWild PWild))) (EVar "None"))
(DFunDef false "headKeyIdent" ((PCon "HkRigid" PWild)) (EVar "None"))
(DTypeSig true "headBucketKey" (TyFun (TyApp (TyCon "Option") (TyCon "HeadKey")) (TyApp (TyCon "Option") (TyCon "RegKey"))))
(DFunDef false "headBucketKey" ((PCon "None")) (EApp (EVar "Some") (EApp (EApp (EVar "RegKey") (EListLit)) (EListLit))))
(DFunDef false "headBucketKey" ((PCon "Some" (PCon "HkDecl" (PVar "key")))) (EApp (EVar "Some") (EApp (EVar "regKeyOfTab") (EVar "key"))))
(DFunDef false "headBucketKey" ((PCon "Some" (PCon "HkRigid" PWild))) (EVar "None"))
(DTypeSig true "dispKeyRender" (TyFun (TyCon "RegKey") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String"))) (TyCon "String"))))
(DFunDef false "dispKeyRender" ((PVar "base") (PVar "rigids")) (EBinOp "++" (EBinOp "++" (EApp (EVar "lenKey") (EApp (EVar "regKeyRender") (EVar "base"))) (EApp (EVar "lenKey") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "listLen") (EVar "rigids")))) (ELit (LString ""))))) (EApp (EApp (EVar "joinWith") (ELit (LString ""))) (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "i") (PVar "name"))) (EBinOp "++" (EApp (EVar "ordKey") (EVar "i")) (EApp (EVar "lenKey") (EVar "name"))))) (EVar "rigids")))))
(DTypeSig false "identBuiltinFixture" (TyFun (TyCon "Ns") (TyFun (TyCon "String") (TyCon "Ident"))))
(DFunDef false "identBuiltinFixture" ((PVar "ns") (PVar "name")) (EApp (EApp (EApp (EVar "Ident") (EVar "ns")) (EVar "identOriginBuiltin")) (EVar "name")))
(DTypeSig false "identIn" (TyFun (TyCon "Ns") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Ident")))))
(DFunDef false "identIn" ((PVar "ns") (PVar "mid") (PVar "name")) (EApp (EApp (EVar "fromOption") (EApp (EApp (EVar "identBuiltinFixture") (EVar "ns")) (ELit (LString "__fixture_fallback__")))) (EApp (EApp (EApp (EVar "mkIdent") (EVar "ns")) (EApp (EVar "OriginModule") (EVar "mid"))) (EVar "name"))))
(DTypeSig false "identTypeFooM" (TyCon "Ident"))
(DFunDef false "identTypeFooM" () (EApp (EApp (EApp (EVar "identIn") (EVar "NsType")) (ELit (LString "m"))) (ELit (LString "Foo"))))
(DTypeSig false "identIfaceFooM" (TyCon "Ident"))
(DFunDef false "identIfaceFooM" () (EApp (EApp (EApp (EVar "identIn") (EVar "NsIface")) (ELit (LString "m"))) (ELit (LString "Foo"))))
(DTypeSig false "identTypeFooN" (TyCon "Ident"))
(DFunDef false "identTypeFooN" () (EApp (EApp (EApp (EVar "identIn") (EVar "NsType")) (ELit (LString "n"))) (ELit (LString "Foo"))))
(DTypeSig false "identTypeBarM" (TyCon "Ident"))
(DFunDef false "identTypeBarM" () (EApp (EApp (EApp (EVar "identIn") (EVar "NsType")) (ELit (LString "m"))) (ELit (LString "Bar"))))
(DTypeSig false "identTypeFooBuiltin" (TyCon "Ident"))
(DFunDef false "identTypeFooBuiltin" () (EApp (EApp (EVar "identBuiltinFixture") (EVar "NsType")) (ELit (LString "Foo"))))
(DTypeSig false "identSizeIn" (TyFun (TyCon "Ns") (TyCon "Ident")))
(DFunDef false "identSizeIn" ((PVar "ns")) (EApp (EApp (EApp (EVar "identIn") (EVar "ns")) (ELit (LString "m"))) (ELit (LString "size"))))
(DTypeSig false "allNsIdents" (TyApp (TyCon "List") (TyCon "Ident")))
(DFunDef false "allNsIdents" () (EApp (EApp (EVar "map") (EVar "identSizeIn")) (EListLit (EVar "NsType") (EVar "NsIface") (EVar "NsMethod") (EVar "NsCtor") (EVar "NsField") (EVar "NsValue"))))
(DTypeSig false "identShiftA" (TyCon "Ident"))
(DFunDef false "identShiftA" () (EApp (EApp (EApp (EVar "identIn") (EVar "NsType")) (ELit (LString "ab"))) (ELit (LString "c"))))
(DTypeSig false "identShiftB" (TyCon "Ident"))
(DFunDef false "identShiftB" () (EApp (EApp (EApp (EVar "identIn") (EVar "NsType")) (ELit (LString "a"))) (ELit (LString "bc"))))
(DTypeSig false "regBothNs" (TyApp (TyCon "Registry") (TyCon "Int")))
(DFunDef false "regBothNs" () (EApp (EApp (EApp (EVar "regInsert") (EVar "identIfaceFooM")) (ELit (LInt 2))) (EApp (EApp (EApp (EVar "regInsert") (EVar "identTypeFooM")) (ELit (LInt 1))) (EVar "regEmpty"))))
(DTypeSig false "regBothOrigin" (TyApp (TyCon "Registry") (TyCon "Int")))
(DFunDef false "regBothOrigin" () (EApp (EApp (EApp (EVar "regInsert") (EVar "identTypeFooN")) (ELit (LInt 20))) (EApp (EApp (EApp (EVar "regInsert") (EVar "identTypeFooM")) (ELit (LInt 10))) (EVar "regEmpty"))))
(DTypeSig false "regOriginKinds" (TyApp (TyCon "Registry") (TyCon "Int")))
(DFunDef false "regOriginKinds" () (EApp (EApp (EApp (EVar "regInsert") (EVar "identTypeFooBuiltin")) (ELit (LInt 3))) (EApp (EApp (EApp (EVar "regInsert") (EVar "identTypeFooM")) (ELit (LInt 1))) (EVar "regEmpty"))))
(DTypeSig false "regBothNames" (TyApp (TyCon "Registry") (TyCon "Int")))
(DFunDef false "regBothNames" () (EApp (EApp (EApp (EVar "regInsert") (EVar "identTypeBarM")) (ELit (LInt 200))) (EApp (EApp (EApp (EVar "regInsert") (EVar "identTypeFooM")) (ELit (LInt 100))) (EVar "regEmpty"))))
(DTypeSig false "regShift" (TyApp (TyCon "Registry") (TyCon "Int")))
(DFunDef false "regShift" () (EApp (EApp (EApp (EVar "regInsert") (EVar "identShiftB")) (ELit (LInt 2))) (EApp (EApp (EApp (EVar "regInsert") (EVar "identShiftA")) (ELit (LInt 1))) (EVar "regEmpty"))))
(DTypeSig false "identIfaceIxM" (TyCon "Ident"))
(DFunDef false "identIfaceIxM" () (EApp (EApp (EApp (EVar "identIn") (EVar "NsIface")) (ELit (LString "m"))) (ELit (LString "Ix"))))
(DTypeSig false "identTypeIntM" (TyCon "Ident"))
(DFunDef false "identTypeIntM" () (EApp (EApp (EApp (EVar "identIn") (EVar "NsType")) (ELit (LString "m"))) (ELit (LString "Int"))))
(DTypeSig false "keyIxIntUndet" (TyCon "RegKey"))
(DFunDef false "keyIxIntUndet" () (EApp (EApp (EVar "regKeyNAt") (EListLit (EVar "identIfaceIxM") (EVar "identTypeIntM"))) (EListLit (ELit (LInt 2)) (ELit (LInt 0)))))
(DTypeSig false "keyIxUndetInt" (TyCon "RegKey"))
(DFunDef false "keyIxUndetInt" () (EApp (EApp (EVar "regKeyNAt") (EListLit (EVar "identIfaceIxM") (EVar "identTypeIntM"))) (EListLit (ELit (LInt 2)) (ELit (LInt 1)))))
(DTypeSig false "keyIxPresentOnly" (TyCon "RegKey"))
(DFunDef false "keyIxPresentOnly" () (EApp (EVar "regKeyN") (EListLit (EVar "identIfaceIxM") (EVar "identTypeIntM"))))
(DTypeSig false "regIxUndet" (TyApp (TyCon "Registry") (TyCon "Int")))
(DFunDef false "regIxUndet" () (EApp (EApp (EApp (EVar "regInsertK") (EVar "keyIxUndetInt")) (ELit (LInt 2))) (EApp (EApp (EApp (EVar "regInsertK") (EVar "keyIxIntUndet")) (ELit (LInt 1))) (EVar "regEmpty"))))
(DTypeSig false "keyIxNoDecl" (TyCon "RegKey"))
(DFunDef false "keyIxNoDecl" () (EApp (EApp (EVar "regKeyNAt") (EListLit (EVar "identIfaceIxM"))) (EListLit (ELit (LInt 2)))))
(DTypeSig false "identTypeLowerAM" (TyCon "Ident"))
(DFunDef false "identTypeLowerAM" () (EApp (EApp (EApp (EVar "identIn") (EVar "NsType")) (ELit (LString "m"))) (ELit (LString "a"))))
(DTypeSig false "keyIxDeclAOnly" (TyCon "RegKey"))
(DFunDef false "keyIxDeclAOnly" () (EApp (EApp (EVar "regKeyNAt") (EListLit (EVar "identIfaceIxM") (EVar "identTypeLowerAM"))) (EListLit (ELit (LInt 2)) (ELit (LInt 0)))))
(DTypeSig false "keyIxBareAOnly" (TyCon "RegKey"))
(DFunDef false "keyIxBareAOnly" () (EApp (EApp (EVar "RegKey") (EListLit (EApp (EVar "TkIdent") (EVar "identIfaceIxM")) (EApp (EApp (EVar "TkBare") (EVar "NsType")) (ELit (LString "a"))))) (EListLit (ELit (LInt 2)) (ELit (LInt 0)))))
(DTypeSig false "headDeclFoo" (TyApp (TyCon "Option") (TyCon "HeadKey")))
(DFunDef false "headDeclFoo" () (EApp (EVar "Some") (EApp (EApp (EVar "headKeyOfCon") (EApp (EVar "OriginModule") (ELit (LString "m")))) (ELit (LString "Foo")))))
(DTypeSig false "headBareFoo" (TyApp (TyCon "Option") (TyCon "HeadKey")))
(DFunDef false "headBareFoo" () (EApp (EVar "Some") (EApp (EVar "HkDecl") (EApp (EApp (EVar "TkBare") (EVar "NsType")) (ELit (LString "Foo"))))))
(DTypeSig false "headRigidA" (TyApp (TyCon "Option") (TyCon "HeadKey")))
(DFunDef false "headRigidA" () (EApp (EVar "Some") (EApp (EVar "HkRigid") (ELit (LString "a")))))
(DTypeSig false "regAllNs" (TyApp (TyCon "Registry") (TyCon "Int")))
(DFunDef false "regAllNs" () (EApp (EVar "regFromEntries") (EApp (EApp (EVar "zipNsValues") (EVar "allNsIdents")) (ELit (LInt 1)))))
(DTypeSig false "zipNsValues" (TyFun (TyApp (TyCon "List") (TyCon "Ident")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyTuple (TyCon "RegKey") (TyCon "Int"))))))
(DFunDef false "zipNsValues" ((PList) PWild) (EListLit))
(DFunDef false "zipNsValues" ((PCons (PVar "i") (PVar "rest")) (PVar "n")) (EBinOp "::" (ETuple (EApp (EVar "regKeyOf") (EVar "i")) (EVar "n")) (EApp (EApp (EVar "zipNsValues") (EVar "rest")) (EBinOp "+" (EVar "n") (ELit (LInt 1))))))
(DTypeSig false "regSlots" (TyApp (TyCon "Registry") (TyCon "Int")))
(DFunDef false "regSlots" () (EApp (EApp (EApp (EVar "regInsertK") (EApp (EApp (EVar "regKeyAt") (EVar "identIfaceFooM")) (ELit (LInt 1)))) (ELit (LInt 11))) (EApp (EApp (EApp (EVar "regInsertK") (EApp (EApp (EVar "regKeyAt") (EVar "identIfaceFooM")) (ELit (LInt 0)))) (ELit (LInt 10))) (EVar "regEmpty"))))
(DTypeSig false "regPairs" (TyApp (TyCon "Registry") (TyCon "Int")))
(DFunDef false "regPairs" () (EApp (EApp (EApp (EVar "regInsertK") (EApp (EVar "regKeyN") (EListLit (EVar "identIfaceFooM") (EVar "identTypeBarM")))) (ELit (LInt 2))) (EApp (EApp (EApp (EVar "regInsertK") (EApp (EVar "regKeyN") (EListLit (EVar "identIfaceFooM") (EVar "identTypeFooM")))) (ELit (LInt 1))) (EVar "regEmpty"))))
(DTypeSig false "mregOrderA" (TyApp (TyCon "MultiRegistry") (TyCon "Int")))
(DFunDef false "mregOrderA" () (EApp (EApp (EApp (EVar "mregAdd") (EVar "identTypeFooM")) (ELit (LInt 2))) (EApp (EApp (EApp (EVar "mregAdd") (EVar "identTypeFooM")) (ELit (LInt 1))) (EVar "mregEmpty"))))
(DTypeSig false "mregOrderB" (TyApp (TyCon "MultiRegistry") (TyCon "Int")))
(DFunDef false "mregOrderB" () (EApp (EApp (EApp (EVar "mregAdd") (EVar "identTypeFooM")) (ELit (LInt 1))) (EApp (EApp (EApp (EVar "mregAdd") (EVar "identTypeFooM")) (ELit (LInt 2))) (EVar "mregEmpty"))))
(DTypeSig false "tabA" (TyCon "TabKey"))
(DFunDef false "tabA" () (EApp (EApp (EApp (EVar "tabKeyOf") (EVar "NsType")) (EApp (EVar "OriginModule") (ELit (LString "apub")))) (ELit (LString "Box"))))
(DTypeSig false "tabZ" (TyCon "TabKey"))
(DFunDef false "tabZ" () (EApp (EApp (EApp (EVar "tabKeyOf") (EVar "NsType")) (EApp (EVar "OriginModule") (ELit (LString "zopapub")))) (ELit (LString "Box"))))
(DTypeSig false "tabU" (TyCon "TabKey"))
(DFunDef false "tabU" () (EApp (EApp (EVar "TkBare") (EVar "NsType")) (ELit (LString "Box"))))
(DTypeSig false "tabIfaceA" (TyCon "TabKey"))
(DFunDef false "tabIfaceA" () (EApp (EApp (EApp (EVar "tabKeyOf") (EVar "NsIface")) (EApp (EVar "OriginModule") (ELit (LString "apub")))) (ELit (LString "Box"))))
(DTypeSig false "tabTable" (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyCon "Int"))))
(DFunDef false "tabTable" () (EListLit (ETuple (EVar "tabZ") (ELit (LInt 2))) (ETuple (EVar "tabA") (ELit (LInt 1)))))
(DTypeSig false "ifaceG" (TyCon "TabKey"))
(DFunDef false "ifaceG" () (EApp (EApp (EApp (EVar "tabKeyOf") (EVar "NsIface")) (EApp (EVar "OriginModule") (ELit (LString "gmod")))) (ELit (LString "Same"))))
(DTypeSig false "ifaceP" (TyCon "TabKey"))
(DFunDef false "ifaceP" () (EApp (EApp (EApp (EVar "tabKeyOf") (EVar "NsIface")) (EApp (EVar "OriginModule") (ELit (LString "pmod")))) (ELit (LString "Same"))))
(DTypeSig false "ifaceU" (TyCon "TabKey"))
(DFunDef false "ifaceU" () (EApp (EApp (EVar "TkBare") (EVar "NsIface")) (ELit (LString "Same"))))
(DTypeSig false "slotGA" (TyCon "RegKey"))
(DFunDef false "slotGA" () (EApp (EApp (EVar "regKeyTabAt") (EVar "ifaceG")) (ELit (LInt 0))))
(DTypeSig false "slotPA" (TyCon "RegKey"))
(DFunDef false "slotPA" () (EApp (EApp (EVar "regKeyTabAt") (EVar "ifaceP")) (ELit (LInt 0))))
(DTypeSig false "slotUA" (TyCon "RegKey"))
(DFunDef false "slotUA" () (EApp (EApp (EVar "regKeyTabAt") (EVar "ifaceU")) (ELit (LInt 0))))
(DTypeSig false "slotTable" (TyApp (TyCon "List") (TyTuple (TyCon "RegKey") (TyCon "Int"))))
(DFunDef false "slotTable" () (EListLit (ETuple (EVar "slotGA") (ELit (LInt 2))) (ETuple (EVar "slotPA") (ELit (LInt 1)))))
(DTypeSig false "headA" (TyCon "HeadKey"))
(DFunDef false "headA" () (EApp (EApp (EVar "headKeyOfCon") (EApp (EVar "OriginModule") (ELit (LString "apub")))) (ELit (LString "Box"))))
(DTypeSig false "headZ" (TyCon "HeadKey"))
(DFunDef false "headZ" () (EApp (EApp (EVar "headKeyOfCon") (EApp (EVar "OriginModule") (ELit (LString "zopapub")))) (ELit (LString "Box"))))
(DTypeSig false "headU" (TyCon "HeadKey"))
(DFunDef false "headU" () (EApp (EVar "HkDecl") (EApp (EApp (EVar "TkBare") (EVar "NsType")) (ELit (LString "Box")))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Ns" true) (mem "Ident" true) (mem "IdentOrigin" false) (mem "TyConOrigin" true) (mem "identOriginOf" false) (mem "identOriginFold" false) (mem "identOriginBuiltin" false) (mem "mkIdent" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omInsert" false) (mem "omLookup" false) (mem "omHasKey" false) (mem "omDelete" false) (mem "omSize" false))))
(DUse false (UseGroup ("support" "util") ((mem "lenKey" false) (mem "listLen" false) (mem "joinWith" false) (mem "filterList" false) (mem "startsWith" false))))
(DUse false (UseGroup ("list") ((mem "sort" false))))
(DUse false (UseGroup ("map") ((mem "toList" false))))
(DTypeSig false "nsTag" (TyFun (TyCon "Ns") (TyCon "String")))
(DFunDef false "nsTag" ((PCon "NsType")) (ELit (LString "type")))
(DFunDef false "nsTag" ((PCon "NsIface")) (ELit (LString "iface")))
(DFunDef false "nsTag" ((PCon "NsMethod")) (ELit (LString "method")))
(DFunDef false "nsTag" ((PCon "NsCtor")) (ELit (LString "ctor")))
(DFunDef false "nsTag" ((PCon "NsField")) (ELit (LString "field")))
(DFunDef false "nsTag" ((PCon "NsValue")) (ELit (LString "value")))
(DTypeSig false "originTag" (TyFun (TyCon "IdentOrigin") (TyCon "String")))
(DFunDef false "originTag" ((PVar "origin")) (EApp (EApp (EApp (EVar "identOriginFold") (ELit (LString "builtin"))) (ELam (PWild) (ELit (LString "module")))) (EVar "origin")))
(DTypeSig false "originModuleOf" (TyFun (TyCon "IdentOrigin") (TyCon "String")))
(DFunDef false "originModuleOf" ((PVar "origin")) (EApp (EApp (EApp (EVar "identOriginFold") (ELit (LString ""))) (ELam ((PVar "m")) (EVar "m"))) (EVar "origin")))
(DTypeSig true "identKey" (TyFun (TyCon "Ident") (TyCon "String")))
(DFunDef false "identKey" ((PCon "Ident" (PVar "ns") (PVar "origin") (PVar "name"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EApp (EVar "lenKey") (EApp (EVar "nsTag") (EVar "ns"))) (EApp (EVar "lenKey") (EApp (EVar "originTag") (EVar "origin")))) (EApp (EVar "lenKey") (EApp (EVar "originModuleOf") (EVar "origin")))) (EApp (EVar "lenKey") (EVar "name"))))
(DTypeSig true "tabKeyRender" (TyFun (TyCon "TabKey") (TyCon "String")))
(DFunDef false "tabKeyRender" ((PCon "TkIdent" (PVar "ident"))) (EApp (EVar "identKey") (EVar "ident")))
(DFunDef false "tabKeyRender" ((PCon "TkBare" (PVar "ns") (PVar "name"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EApp (EVar "lenKey") (EApp (EVar "nsTag") (EVar "ns"))) (EApp (EVar "lenKey") (ELit (LString "bare")))) (EApp (EVar "lenKey") (ELit (LString "")))) (EApp (EVar "lenKey") (EVar "name"))))
(DTypeSig true "identKeys" (TyFun (TyApp (TyCon "List") (TyCon "Ident")) (TyCon "String")))
(DFunDef false "identKeys" ((PVar "idents")) (EApp (EApp (EVar "joinWith") (ELit (LString ""))) (EApp (EApp (EMethodRef "map") (EVar "identKey")) (EVar "idents"))))
(DTypeSig true "tabKeys" (TyFun (TyApp (TyCon "List") (TyCon "TabKey")) (TyCon "String")))
(DFunDef false "tabKeys" ((PVar "keys")) (EApp (EApp (EVar "joinWith") (ELit (LString ""))) (EApp (EApp (EMethodRef "map") (EVar "tabKeyRender")) (EVar "keys"))))
(DTypeSig false "ordKey" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "ordKey" ((PVar "n")) (EApp (EVar "lenKey") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "")))))
(DData Public "RegKey" () ((variant "RegKey" (ConPos (TyApp (TyCon "List") (TyCon "TabKey")) (TyApp (TyCon "List") (TyCon "Int"))))) ())
(DImpl true "Eq" ((TyCon "RegKey")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "RegKey" (PVar "__a0") (PVar "__a1")) (PCon "RegKey" (PVar "__b0") (PVar "__b1"))) () (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1"))))))))
(DImpl true "Ord" ((TyCon "RegKey")) () ((im "compare" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "RegKey" (PVar "__a0") (PVar "__a1")) (PCon "RegKey" (PVar "__b0") (PVar "__b1"))) () (EMatch (EApp (EApp (EMethodRef "compare") (EVar "__a0")) (EVar "__b0")) (arm (PCon "Eq") () (EApp (EApp (EMethodRef "compare") (EVar "__a1")) (EVar "__b1"))) (arm (PVar "__c") () (EVar "__c"))))))))
(DImpl true "Debug" ((TyCon "RegKey")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "RegKey" (PVar "__a0") (PVar "__a1")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "RegKey ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a1")))))))))
(DTypeSig true "regKeyOf" (TyFun (TyCon "Ident") (TyCon "RegKey")))
(DFunDef false "regKeyOf" ((PVar "ident")) (EApp (EApp (EVar "RegKey") (EListLit (EApp (EVar "TkIdent") (EVar "ident")))) (EListLit)))
(DTypeSig true "regKeyN" (TyFun (TyApp (TyCon "List") (TyCon "Ident")) (TyCon "RegKey")))
(DFunDef false "regKeyN" ((PVar "idents")) (EApp (EApp (EVar "RegKey") (EApp (EApp (EMethodRef "map") (EVar "TkIdent")) (EVar "idents"))) (EListLit)))
(DTypeSig true "regKeyAt" (TyFun (TyCon "Ident") (TyFun (TyCon "Int") (TyCon "RegKey"))))
(DFunDef false "regKeyAt" ((PVar "ident") (PVar "slot")) (EApp (EApp (EVar "RegKey") (EListLit (EApp (EVar "TkIdent") (EVar "ident")))) (EListLit (EVar "slot"))))
(DTypeSig true "regKeyNAt" (TyFun (TyApp (TyCon "List") (TyCon "Ident")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "RegKey"))))
(DFunDef false "regKeyNAt" ((PVar "idents") (PVar "ords")) (EApp (EApp (EVar "RegKey") (EApp (EApp (EMethodRef "map") (EVar "TkIdent")) (EVar "idents"))) (EVar "ords")))
(DTypeSig true "regKeyOfTab" (TyFun (TyCon "TabKey") (TyCon "RegKey")))
(DFunDef false "regKeyOfTab" ((PVar "key")) (EApp (EApp (EVar "RegKey") (EListLit (EVar "key"))) (EListLit)))
(DTypeSig true "regKeyTabAt" (TyFun (TyCon "TabKey") (TyFun (TyCon "Int") (TyCon "RegKey"))))
(DFunDef false "regKeyTabAt" ((PVar "key") (PVar "slot")) (EApp (EApp (EVar "RegKey") (EListLit (EVar "key"))) (EListLit (EVar "slot"))))
(DTypeSig true "regKeyNTab" (TyFun (TyApp (TyCon "List") (TyCon "TabKey")) (TyCon "RegKey")))
(DFunDef false "regKeyNTab" ((PVar "keys")) (EApp (EApp (EVar "RegKey") (EVar "keys")) (EListLit)))
(DTypeSig true "regKeyNTabAt" (TyFun (TyApp (TyCon "List") (TyCon "TabKey")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "RegKey"))))
(DFunDef false "regKeyNTabAt" ((PVar "keys") (PVar "ords")) (EApp (EApp (EVar "RegKey") (EVar "keys")) (EVar "ords")))
(DTypeSig true "regKeyTabs" (TyFun (TyCon "RegKey") (TyApp (TyCon "List") (TyCon "TabKey"))))
(DFunDef false "regKeyTabs" ((PCon "RegKey" (PVar "keys") PWild)) (EVar "keys"))
(DTypeSig true "regKeyOrdinals" (TyFun (TyCon "RegKey") (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "regKeyOrdinals" ((PCon "RegKey" PWild (PVar "ords"))) (EVar "ords"))
(DTypeSig true "regKeyRender" (TyFun (TyCon "RegKey") (TyCon "String")))
(DFunDef false "regKeyRender" ((PCon "RegKey" (PVar "keys") (PVar "ords"))) (EBinOp "++" (EBinOp "++" (EApp (EVar "lenKey") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "listLen") (EVar "keys")))) (ELit (LString "")))) (EApp (EVar "tabKeys") (EVar "keys"))) (EApp (EApp (EVar "joinWith") (ELit (LString ""))) (EApp (EApp (EMethodRef "map") (EVar "ordKey")) (EVar "ords")))))
(DData Public "Registry" ("v") ((variant "Registry" (ConPos (TyApp (TyCon "OrdMap") (TyTuple (TyCon "RegKey") (TyVar "v")))))) ())
(DTypeSig true "regEmpty" (TyApp (TyCon "Registry") (TyVar "v")))
(DFunDef false "regEmpty" () (EApp (EVar "Registry") (EVar "omEmpty")))
(DTypeSig true "regLookupK" (TyFun (TyCon "RegKey") (TyFun (TyApp (TyCon "Registry") (TyVar "v")) (TyApp (TyCon "Option") (TyVar "v")))))
(DFunDef false "regLookupK" ((PVar "k") (PCon "Registry" (PVar "m"))) (EApp (EApp (EMethodRef "map") (ELam ((PTuple PWild (PVar "v"))) (EVar "v"))) (EApp (EApp (EVar "omLookup") (EApp (EVar "regKeyRender") (EVar "k"))) (EVar "m"))))
(DTypeSig true "regLookup" (TyFun (TyCon "Ident") (TyFun (TyApp (TyCon "Registry") (TyVar "v")) (TyApp (TyCon "Option") (TyVar "v")))))
(DFunDef false "regLookup" ((PVar "ident") (PVar "r")) (EApp (EApp (EVar "regLookupK") (EApp (EVar "regKeyOf") (EVar "ident"))) (EVar "r")))
(DTypeSig true "regInsertCheckedK" (TyFun (TyCon "RegKey") (TyFun (TyVar "v") (TyFun (TyApp (TyCon "Registry") (TyVar "v")) (TyTuple (TyApp (TyCon "Registry") (TyVar "v")) (TyCon "Bool"))))))
(DFunDef false "regInsertCheckedK" ((PVar "k") (PVar "v") (PCon "Registry" (PVar "m"))) (EBlock (DoLet false false (PVar "s") (EApp (EVar "regKeyRender") (EVar "k"))) (DoExpr (ETuple (EApp (EVar "Registry") (EApp (EApp (EApp (EVar "omInsert") (EVar "s")) (ETuple (EVar "k") (EVar "v"))) (EVar "m"))) (EApp (EApp (EVar "omHasKey") (EVar "s")) (EVar "m"))))))
(DTypeSig true "regInsertChecked" (TyFun (TyCon "Ident") (TyFun (TyVar "v") (TyFun (TyApp (TyCon "Registry") (TyVar "v")) (TyTuple (TyApp (TyCon "Registry") (TyVar "v")) (TyCon "Bool"))))))
(DFunDef false "regInsertChecked" ((PVar "ident") (PVar "v") (PVar "r")) (EApp (EApp (EApp (EVar "regInsertCheckedK") (EApp (EVar "regKeyOf") (EVar "ident"))) (EVar "v")) (EVar "r")))
(DTypeSig true "regInsertK" (TyFun (TyCon "RegKey") (TyFun (TyVar "v") (TyFun (TyApp (TyCon "Registry") (TyVar "v")) (TyApp (TyCon "Registry") (TyVar "v"))))))
(DFunDef false "regInsertK" ((PVar "k") (PVar "v") (PCon "Registry" (PVar "m"))) (EApp (EVar "Registry") (EApp (EApp (EApp (EVar "omInsert") (EApp (EVar "regKeyRender") (EVar "k"))) (ETuple (EVar "k") (EVar "v"))) (EVar "m"))))
(DTypeSig true "regInsert" (TyFun (TyCon "Ident") (TyFun (TyVar "v") (TyFun (TyApp (TyCon "Registry") (TyVar "v")) (TyApp (TyCon "Registry") (TyVar "v"))))))
(DFunDef false "regInsert" ((PVar "ident") (PVar "v") (PVar "r")) (EApp (EApp (EApp (EVar "regInsertK") (EApp (EVar "regKeyOf") (EVar "ident"))) (EVar "v")) (EVar "r")))
(DTypeSig true "regDeleteK" (TyFun (TyCon "RegKey") (TyFun (TyApp (TyCon "Registry") (TyVar "v")) (TyApp (TyCon "Registry") (TyVar "v")))))
(DFunDef false "regDeleteK" ((PVar "k") (PCon "Registry" (PVar "m"))) (EApp (EVar "Registry") (EApp (EApp (EVar "omDelete") (EApp (EVar "regKeyRender") (EVar "k"))) (EVar "m"))))
(DTypeSig true "regDelete" (TyFun (TyCon "Ident") (TyFun (TyApp (TyCon "Registry") (TyVar "v")) (TyApp (TyCon "Registry") (TyVar "v")))))
(DFunDef false "regDelete" ((PVar "ident") (PVar "r")) (EApp (EApp (EVar "regDeleteK") (EApp (EVar "regKeyOf") (EVar "ident"))) (EVar "r")))
(DTypeSig true "regEntries" (TyFun (TyApp (TyCon "Registry") (TyVar "v")) (TyApp (TyCon "List") (TyTuple (TyCon "RegKey") (TyVar "v")))))
(DFunDef false "regEntries" ((PCon "Registry" (PVar "m"))) (EApp (EApp (EMethodRef "map") (EVar "snd")) (EApp (EMethodRef "toList") (EVar "m"))))
(DTypeSig true "regKeys" (TyFun (TyApp (TyCon "Registry") (TyVar "v")) (TyApp (TyCon "List") (TyCon "RegKey"))))
(DFunDef false "regKeys" ((PVar "r")) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EApp (EVar "regEntries") (EVar "r"))))
(DTypeSig true "regSize" (TyFun (TyApp (TyCon "Registry") (TyVar "v")) (TyCon "Int")))
(DFunDef false "regSize" ((PCon "Registry" (PVar "m"))) (EApp (EVar "omSize") (EVar "m")))
(DTypeSig true "regFilter" (TyFun (TyFun (TyTuple (TyCon "RegKey") (TyVar "v")) (TyCon "Bool")) (TyFun (TyApp (TyCon "Registry") (TyVar "v")) (TyApp (TyCon "Registry") (TyVar "v")))))
(DFunDef false "regFilter" ((PVar "p") (PVar "r")) (EApp (EVar "regFromEntries") (EApp (EApp (EVar "filterList") (EVar "p")) (EApp (EVar "regEntries") (EVar "r")))))
(DTypeSig true "regFromEntries" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "RegKey") (TyVar "v"))) (TyApp (TyCon "Registry") (TyVar "v"))))
(DFunDef false "regFromEntries" ((PVar "entries")) (EApp (EApp (EVar "regFromEntriesGo") (EVar "entries")) (EVar "regEmpty")))
(DTypeSig false "regFromEntriesGo" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "RegKey") (TyVar "v"))) (TyFun (TyApp (TyCon "Registry") (TyVar "v")) (TyApp (TyCon "Registry") (TyVar "v")))))
(DFunDef false "regFromEntriesGo" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "regFromEntriesGo" ((PCons (PTuple (PVar "k") (PVar "v")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "regFromEntriesGo") (EVar "rest")) (EApp (EApp (EApp (EVar "regInsertK") (EVar "k")) (EVar "v")) (EVar "acc"))))
(DTypeSig true "regMerge" (TyFun (TyApp (TyCon "Registry") (TyVar "v")) (TyFun (TyApp (TyCon "Registry") (TyVar "v")) (TyApp (TyCon "Registry") (TyVar "v")))))
(DFunDef false "regMerge" ((PVar "older") (PVar "newer")) (EApp (EApp (EVar "regFromEntriesGo") (EApp (EVar "regEntries") (EVar "newer"))) (EVar "older")))
(DData Public "MultiRegistry" ("v") ((variant "MultiRegistry" (ConPos (TyApp (TyCon "OrdMap") (TyTuple (TyCon "RegKey") (TyApp (TyCon "List") (TyVar "v"))))))) ())
(DTypeSig true "mregEmpty" (TyApp (TyCon "MultiRegistry") (TyVar "v")))
(DFunDef false "mregEmpty" () (EApp (EVar "MultiRegistry") (EVar "omEmpty")))
(DTypeSig true "mregAddK" (TyFun (TyCon "RegKey") (TyFun (TyVar "v") (TyFun (TyApp (TyCon "MultiRegistry") (TyVar "v")) (TyApp (TyCon "MultiRegistry") (TyVar "v"))))))
(DFunDef false "mregAddK" ((PVar "k") (PVar "v") (PCon "MultiRegistry" (PVar "m"))) (EBlock (DoLet false false (PVar "s") (EApp (EVar "regKeyRender") (EVar "k"))) (DoExpr (EMatch (EApp (EApp (EVar "omLookup") (EVar "s")) (EVar "m")) (arm (PCon "Some" (PTuple PWild (PVar "vs"))) () (EApp (EVar "MultiRegistry") (EApp (EApp (EApp (EVar "omInsert") (EVar "s")) (ETuple (EVar "k") (EBinOp "::" (EVar "v") (EVar "vs")))) (EVar "m")))) (arm (PCon "None") () (EApp (EVar "MultiRegistry") (EApp (EApp (EApp (EVar "omInsert") (EVar "s")) (ETuple (EVar "k") (EListLit (EVar "v")))) (EVar "m"))))))))
(DTypeSig true "mregAdd" (TyFun (TyCon "Ident") (TyFun (TyVar "v") (TyFun (TyApp (TyCon "MultiRegistry") (TyVar "v")) (TyApp (TyCon "MultiRegistry") (TyVar "v"))))))
(DFunDef false "mregAdd" ((PVar "ident") (PVar "v") (PVar "mr")) (EApp (EApp (EApp (EVar "mregAddK") (EApp (EVar "regKeyOf") (EVar "ident"))) (EVar "v")) (EVar "mr")))
(DTypeSig true "mregAppendK" (TyFun (TyCon "RegKey") (TyFun (TyVar "v") (TyFun (TyApp (TyCon "MultiRegistry") (TyVar "v")) (TyApp (TyCon "MultiRegistry") (TyVar "v"))))))
(DFunDef false "mregAppendK" ((PVar "k") (PVar "v") (PCon "MultiRegistry" (PVar "m"))) (EBlock (DoLet false false (PVar "s") (EApp (EVar "regKeyRender") (EVar "k"))) (DoExpr (EMatch (EApp (EApp (EVar "omLookup") (EVar "s")) (EVar "m")) (arm (PCon "Some" (PTuple PWild (PVar "vs"))) () (EApp (EVar "MultiRegistry") (EApp (EApp (EApp (EVar "omInsert") (EVar "s")) (ETuple (EVar "k") (EBinOp "++" (EVar "vs") (EListLit (EVar "v"))))) (EVar "m")))) (arm (PCon "None") () (EApp (EVar "MultiRegistry") (EApp (EApp (EApp (EVar "omInsert") (EVar "s")) (ETuple (EVar "k") (EListLit (EVar "v")))) (EVar "m"))))))))
(DTypeSig true "mregLookupK" (TyFun (TyCon "RegKey") (TyFun (TyApp (TyCon "MultiRegistry") (TyVar "v")) (TyApp (TyCon "List") (TyVar "v")))))
(DFunDef false "mregLookupK" ((PVar "k") (PCon "MultiRegistry" (PVar "m"))) (EMatch (EApp (EApp (EVar "omLookup") (EApp (EVar "regKeyRender") (EVar "k"))) (EVar "m")) (arm (PCon "Some" (PTuple PWild (PVar "vs"))) () (EVar "vs")) (arm (PCon "None") () (EListLit))))
(DTypeSig true "mregLookup" (TyFun (TyCon "Ident") (TyFun (TyApp (TyCon "MultiRegistry") (TyVar "v")) (TyApp (TyCon "List") (TyVar "v")))))
(DFunDef false "mregLookup" ((PVar "ident") (PVar "mr")) (EApp (EApp (EVar "mregLookupK") (EApp (EVar "regKeyOf") (EVar "ident"))) (EVar "mr")))
(DTypeSig true "mregEntries" (TyFun (TyApp (TyCon "MultiRegistry") (TyVar "v")) (TyApp (TyCon "List") (TyTuple (TyCon "RegKey") (TyApp (TyCon "List") (TyVar "v"))))))
(DFunDef false "mregEntries" ((PCon "MultiRegistry" (PVar "m"))) (EApp (EApp (EMethodRef "map") (EVar "snd")) (EApp (EMethodRef "toList") (EVar "m"))))
(DTypeSig true "mregKeys" (TyFun (TyApp (TyCon "MultiRegistry") (TyVar "v")) (TyApp (TyCon "List") (TyCon "RegKey"))))
(DFunDef false "mregKeys" ((PVar "mr")) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EApp (EVar "mregEntries") (EVar "mr"))))
(DTypeSig true "mregSize" (TyFun (TyApp (TyCon "MultiRegistry") (TyVar "v")) (TyCon "Int")))
(DFunDef false "mregSize" ((PCon "MultiRegistry" (PVar "m"))) (EApp (EVar "omSize") (EVar "m")))
(DTypeSig true "mregMerge" (TyFun (TyApp (TyCon "MultiRegistry") (TyVar "v")) (TyFun (TyApp (TyCon "MultiRegistry") (TyVar "v")) (TyApp (TyCon "MultiRegistry") (TyVar "v")))))
(DFunDef false "mregMerge" ((PVar "older") (PVar "newer")) (EApp (EApp (EVar "mregMergeGo") (EApp (EVar "mregEntries") (EVar "newer"))) (EVar "older")))
(DTypeSig false "mregMergeGo" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "RegKey") (TyApp (TyCon "List") (TyVar "v")))) (TyFun (TyApp (TyCon "MultiRegistry") (TyVar "v")) (TyApp (TyCon "MultiRegistry") (TyVar "v")))))
(DFunDef false "mregMergeGo" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "mregMergeGo" ((PCons (PTuple (PVar "k") (PVar "vs")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "mregMergeGo") (EVar "rest")) (EApp (EApp (EApp (EVar "mregAddAll") (EVar "k")) (EVar "vs")) (EVar "acc"))))
(DTypeSig false "mregAddAll" (TyFun (TyCon "RegKey") (TyFun (TyApp (TyCon "List") (TyVar "v")) (TyFun (TyApp (TyCon "MultiRegistry") (TyVar "v")) (TyApp (TyCon "MultiRegistry") (TyVar "v"))))))
(DFunDef false "mregAddAll" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "mregAddAll" ((PVar "k") (PCons (PVar "v") (PVar "vs")) (PVar "acc")) (EApp (EApp (EApp (EVar "mregAddAll") (EVar "k")) (EVar "vs")) (EApp (EApp (EApp (EVar "mregAddK") (EVar "k")) (EVar "v")) (EVar "acc"))))
(DData Public "SetRegistry" () ((variant "SetRegistry" (ConPos (TyApp (TyCon "OrdMap") (TyCon "RegKey"))))) ())
(DTypeSig true "sregEmpty" (TyCon "SetRegistry"))
(DFunDef false "sregEmpty" () (EApp (EVar "SetRegistry") (EVar "omEmpty")))
(DTypeSig true "sregAddK" (TyFun (TyCon "RegKey") (TyFun (TyCon "SetRegistry") (TyCon "SetRegistry"))))
(DFunDef false "sregAddK" ((PVar "k") (PCon "SetRegistry" (PVar "m"))) (EApp (EVar "SetRegistry") (EApp (EApp (EApp (EVar "omInsert") (EApp (EVar "regKeyRender") (EVar "k"))) (EVar "k")) (EVar "m"))))
(DTypeSig true "sregAdd" (TyFun (TyCon "Ident") (TyFun (TyCon "SetRegistry") (TyCon "SetRegistry"))))
(DFunDef false "sregAdd" ((PVar "ident") (PVar "s")) (EApp (EApp (EVar "sregAddK") (EApp (EVar "regKeyOf") (EVar "ident"))) (EVar "s")))
(DTypeSig true "sregMemberK" (TyFun (TyCon "RegKey") (TyFun (TyCon "SetRegistry") (TyCon "Bool"))))
(DFunDef false "sregMemberK" ((PVar "k") (PCon "SetRegistry" (PVar "m"))) (EApp (EApp (EVar "omHasKey") (EApp (EVar "regKeyRender") (EVar "k"))) (EVar "m")))
(DTypeSig true "sregMember" (TyFun (TyCon "Ident") (TyFun (TyCon "SetRegistry") (TyCon "Bool"))))
(DFunDef false "sregMember" ((PVar "ident") (PVar "s")) (EApp (EApp (EVar "sregMemberK") (EApp (EVar "regKeyOf") (EVar "ident"))) (EVar "s")))
(DTypeSig true "sregSize" (TyFun (TyCon "SetRegistry") (TyCon "Int")))
(DFunDef false "sregSize" ((PCon "SetRegistry" (PVar "m"))) (EApp (EVar "omSize") (EVar "m")))
(DTypeSig true "sregKeys" (TyFun (TyCon "SetRegistry") (TyApp (TyCon "List") (TyCon "RegKey"))))
(DFunDef false "sregKeys" ((PCon "SetRegistry" (PVar "m"))) (EApp (EApp (EMethodRef "map") (EVar "snd")) (EApp (EMethodRef "toList") (EVar "m"))))
(DTypeSig true "sregMerge" (TyFun (TyCon "SetRegistry") (TyFun (TyCon "SetRegistry") (TyCon "SetRegistry"))))
(DFunDef false "sregMerge" ((PVar "older") (PVar "newer")) (EApp (EApp (EVar "sregMergeGo") (EApp (EVar "sregKeys") (EVar "newer"))) (EVar "older")))
(DTypeSig false "sregMergeGo" (TyFun (TyApp (TyCon "List") (TyCon "RegKey")) (TyFun (TyCon "SetRegistry") (TyCon "SetRegistry"))))
(DFunDef false "sregMergeGo" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "sregMergeGo" ((PCons (PVar "k") (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "sregMergeGo") (EVar "rest")) (EApp (EApp (EVar "sregAddK") (EVar "k")) (EVar "acc"))))
(DData Public "TabKey" () ((variant "TkIdent" (ConPos (TyCon "Ident"))) (variant "TkBare" (ConPos (TyCon "Ns") (TyCon "String")))) ())
(DImpl true "Eq" ((TyCon "TabKey")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "TkIdent" (PVar "__a0")) (PCon "TkIdent" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "TkBare" (PVar "__a0") (PVar "__a1")) (PCon "TkBare" (PVar "__b0") (PVar "__b1"))) () (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1")))) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Ord" ((TyCon "TabKey")) () ((im "compare" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "TkIdent" (PVar "__a0")) (PCon "TkIdent" (PVar "__b0"))) () (EApp (EApp (EMethodRef "compare") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "TkIdent" (PVar "__a0")) (PCon "TkBare" (PVar "__b0") (PVar "__b1"))) () (EVar "Lt")) (arm (PTuple (PCon "TkBare" (PVar "__a0") (PVar "__a1")) (PCon "TkIdent" (PVar "__b0"))) () (EVar "Gt")) (arm (PTuple (PCon "TkBare" (PVar "__a0") (PVar "__a1")) (PCon "TkBare" (PVar "__b0") (PVar "__b1"))) () (EMatch (EApp (EApp (EMethodRef "compare") (EVar "__a0")) (EVar "__b0")) (arm (PCon "Eq") () (EApp (EApp (EMethodRef "compare") (EVar "__a1")) (EVar "__b1"))) (arm (PVar "__c") () (EVar "__c"))))))))
(DImpl true "Debug" ((TyCon "TabKey")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "TkIdent" (PVar "__a0")) () (EBinOp "++" (ELit (LString "TkIdent ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0"))))) (arm (PCon "TkBare" (PVar "__a0") (PVar "__a1")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "TkBare ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a1")))))))))
(DTypeSig true "tabKeyOf" (TyFun (TyCon "Ns") (TyFun (TyCon "TyConOrigin") (TyFun (TyCon "String") (TyCon "TabKey")))))
(DFunDef false "tabKeyOf" ((PVar "ns") (PVar "origin") (PVar "name")) (EMatch (EApp (EApp (EApp (EVar "mkIdent") (EVar "ns")) (EVar "origin")) (EVar "name")) (arm (PCon "Some" (PVar "ident")) () (EApp (EVar "TkIdent") (EVar "ident"))) (arm (PCon "None") () (EApp (EApp (EVar "TkBare") (EVar "ns")) (EVar "name")))))
(DTypeSig true "tabKeyName" (TyFun (TyCon "TabKey") (TyCon "String")))
(DFunDef false "tabKeyName" ((PCon "TkIdent" (PCon "Ident" PWild PWild (PVar "name")))) (EVar "name"))
(DFunDef false "tabKeyName" ((PCon "TkBare" PWild (PVar "name"))) (EVar "name"))
(DTypeSig false "tabKeyEq" (TyFun (TyCon "TabKey") (TyFun (TyCon "TabKey") (TyCon "Bool"))))
(DFunDef false "tabKeyEq" ((PCon "TkIdent" (PCon "Ident" (PVar "ns1") (PVar "o1") (PVar "n1"))) (PCon "TkIdent" (PCon "Ident" (PVar "ns2") (PVar "o2") (PVar "n2")))) (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "n1") (EVar "n2")) (EBinOp "==" (EVar "ns1") (EVar "ns2"))) (EBinOp "==" (EVar "o1") (EVar "o2"))))
(DFunDef false "tabKeyEq" ((PCon "TkBare" (PVar "ns1") (PVar "n1")) (PCon "TkBare" (PVar "ns2") (PVar "n2"))) (EBinOp "&&" (EBinOp "==" (EVar "n1") (EVar "n2")) (EBinOp "==" (EVar "ns1") (EVar "ns2"))))
(DFunDef false "tabKeyEq" (PWild PWild) (EVar "False"))
(DTypeSig true "lookupTab" (TyFun (TyCon "TabKey") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyVar "v"))) (TyApp (TyCon "Option") (TyVar "v")))))
(DFunDef false "lookupTab" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupTab" ((PVar "k") (PCons (PTuple (PVar "k2") (PVar "v")) (PVar "rest"))) (EIf (EApp (EApp (EVar "tabKeyEq") (EVar "k")) (EVar "k2")) (EApp (EVar "Some") (EVar "v")) (EApp (EApp (EVar "lookupTab") (EVar "k")) (EVar "rest"))))
(DTypeSig true "tabHasName" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyVar "v"))) (TyCon "Bool"))))
(DFunDef false "tabHasName" (PWild (PList)) (EVar "False"))
(DFunDef false "tabHasName" ((PVar "n") (PCons (PTuple (PVar "k") PWild) (PVar "rest"))) (EBinOp "||" (EBinOp "==" (EApp (EVar "tabKeyName") (EVar "k")) (EVar "n")) (EApp (EApp (EVar "tabHasName") (EVar "n")) (EVar "rest"))))
(DTypeSig false "regKeyEq" (TyFun (TyCon "RegKey") (TyFun (TyCon "RegKey") (TyCon "Bool"))))
(DFunDef false "regKeyEq" ((PCon "RegKey" (PVar "k1") (PVar "o1")) (PCon "RegKey" (PVar "k2") (PVar "o2"))) (EBinOp "&&" (EApp (EApp (EVar "intsEq") (EVar "o1")) (EVar "o2")) (EApp (EApp (EVar "tabKeysEq") (EVar "k1")) (EVar "k2"))))
(DTypeSig false "intsEq" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Bool"))))
(DFunDef false "intsEq" ((PList) (PList)) (EVar "True"))
(DFunDef false "intsEq" ((PCons (PVar "a") (PVar "as2")) (PCons (PVar "b") (PVar "bs"))) (EBinOp "&&" (EBinOp "==" (EVar "a") (EVar "b")) (EApp (EApp (EVar "intsEq") (EVar "as2")) (EVar "bs"))))
(DFunDef false "intsEq" (PWild PWild) (EVar "False"))
(DTypeSig false "tabKeysEq" (TyFun (TyApp (TyCon "List") (TyCon "TabKey")) (TyFun (TyApp (TyCon "List") (TyCon "TabKey")) (TyCon "Bool"))))
(DFunDef false "tabKeysEq" ((PList) (PList)) (EVar "True"))
(DFunDef false "tabKeysEq" ((PCons (PVar "a") (PVar "as2")) (PCons (PVar "b") (PVar "bs"))) (EBinOp "&&" (EApp (EApp (EVar "tabKeyEq") (EVar "a")) (EVar "b")) (EApp (EApp (EVar "tabKeysEq") (EVar "as2")) (EVar "bs"))))
(DFunDef false "tabKeysEq" (PWild PWild) (EVar "False"))
(DTypeSig true "lookupReg" (TyFun (TyCon "RegKey") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "RegKey") (TyVar "v"))) (TyApp (TyCon "Option") (TyVar "v")))))
(DFunDef false "lookupReg" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupReg" ((PVar "k") (PCons (PTuple (PVar "k2") (PVar "v")) (PVar "rest"))) (EIf (EApp (EApp (EVar "regKeyEq") (EVar "k")) (EVar "k2")) (EApp (EVar "Some") (EVar "v")) (EApp (EApp (EVar "lookupReg") (EVar "k")) (EVar "rest"))))
(DData Public "HeadKey" () ((variant "HkDecl" (ConPos (TyCon "TabKey"))) (variant "HkRigid" (ConPos (TyCon "String")))) ())
(DImpl true "Eq" ((TyCon "HeadKey")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "HkDecl" (PVar "__a0")) (PCon "HkDecl" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "HkRigid" (PVar "__a0")) (PCon "HkRigid" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Ord" ((TyCon "HeadKey")) () ((im "compare" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "HkDecl" (PVar "__a0")) (PCon "HkDecl" (PVar "__b0"))) () (EApp (EApp (EMethodRef "compare") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "HkDecl" (PVar "__a0")) (PCon "HkRigid" (PVar "__b0"))) () (EVar "Lt")) (arm (PTuple (PCon "HkRigid" (PVar "__a0")) (PCon "HkDecl" (PVar "__b0"))) () (EVar "Gt")) (arm (PTuple (PCon "HkRigid" (PVar "__a0")) (PCon "HkRigid" (PVar "__b0"))) () (EApp (EApp (EMethodRef "compare") (EVar "__a0")) (EVar "__b0")))))))
(DImpl true "Debug" ((TyCon "HeadKey")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "HkDecl" (PVar "__a0")) () (EBinOp "++" (ELit (LString "HkDecl ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0"))))) (arm (PCon "HkRigid" (PVar "__a0")) () (EBinOp "++" (ELit (LString "HkRigid ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0")))))))))
(DTypeSig true "headKeyOfCon" (TyFun (TyCon "TyConOrigin") (TyFun (TyCon "String") (TyCon "HeadKey"))))
(DFunDef false "headKeyOfCon" ((PVar "origin") (PVar "name")) (EApp (EVar "HkDecl") (EApp (EApp (EApp (EVar "tabKeyOf") (EVar "NsType")) (EVar "origin")) (EVar "name"))))
(DTypeSig true "headKeyName" (TyFun (TyCon "HeadKey") (TyCon "String")))
(DFunDef false "headKeyName" ((PCon "HkDecl" (PVar "k"))) (EApp (EVar "tabKeyName") (EVar "k")))
(DFunDef false "headKeyName" ((PCon "HkRigid" (PVar "name"))) (EVar "name"))
(DTypeSig true "headKeyDecl" (TyFun (TyCon "HeadKey") (TyApp (TyCon "Option") (TyCon "TabKey"))))
(DFunDef false "headKeyDecl" ((PCon "HkDecl" (PVar "key"))) (EApp (EVar "Some") (EVar "key")))
(DFunDef false "headKeyDecl" ((PCon "HkRigid" PWild)) (EVar "None"))
(DTypeSig true "headKeyIdent" (TyFun (TyCon "HeadKey") (TyApp (TyCon "Option") (TyCon "Ident"))))
(DFunDef false "headKeyIdent" ((PCon "HkDecl" (PCon "TkIdent" (PVar "ident")))) (EApp (EVar "Some") (EVar "ident")))
(DFunDef false "headKeyIdent" ((PCon "HkDecl" (PCon "TkBare" PWild PWild))) (EVar "None"))
(DFunDef false "headKeyIdent" ((PCon "HkRigid" PWild)) (EVar "None"))
(DTypeSig true "headBucketKey" (TyFun (TyApp (TyCon "Option") (TyCon "HeadKey")) (TyApp (TyCon "Option") (TyCon "RegKey"))))
(DFunDef false "headBucketKey" ((PCon "None")) (EApp (EVar "Some") (EApp (EApp (EVar "RegKey") (EListLit)) (EListLit))))
(DFunDef false "headBucketKey" ((PCon "Some" (PCon "HkDecl" (PVar "key")))) (EApp (EVar "Some") (EApp (EVar "regKeyOfTab") (EVar "key"))))
(DFunDef false "headBucketKey" ((PCon "Some" (PCon "HkRigid" PWild))) (EVar "None"))
(DTypeSig true "dispKeyRender" (TyFun (TyCon "RegKey") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String"))) (TyCon "String"))))
(DFunDef false "dispKeyRender" ((PVar "base") (PVar "rigids")) (EBinOp "++" (EBinOp "++" (EApp (EVar "lenKey") (EApp (EVar "regKeyRender") (EVar "base"))) (EApp (EVar "lenKey") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "listLen") (EVar "rigids")))) (ELit (LString ""))))) (EApp (EApp (EVar "joinWith") (ELit (LString ""))) (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "i") (PVar "name"))) (EBinOp "++" (EApp (EVar "ordKey") (EVar "i")) (EApp (EVar "lenKey") (EVar "name"))))) (EVar "rigids")))))
(DTypeSig false "identBuiltinFixture" (TyFun (TyCon "Ns") (TyFun (TyCon "String") (TyCon "Ident"))))
(DFunDef false "identBuiltinFixture" ((PVar "ns") (PVar "name")) (EApp (EApp (EApp (EVar "Ident") (EVar "ns")) (EVar "identOriginBuiltin")) (EVar "name")))
(DTypeSig false "identIn" (TyFun (TyCon "Ns") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Ident")))))
(DFunDef false "identIn" ((PVar "ns") (PVar "mid") (PVar "name")) (EApp (EApp (EVar "fromOption") (EApp (EApp (EVar "identBuiltinFixture") (EVar "ns")) (ELit (LString "__fixture_fallback__")))) (EApp (EApp (EApp (EVar "mkIdent") (EVar "ns")) (EApp (EVar "OriginModule") (EVar "mid"))) (EVar "name"))))
(DTypeSig false "identTypeFooM" (TyCon "Ident"))
(DFunDef false "identTypeFooM" () (EApp (EApp (EApp (EVar "identIn") (EVar "NsType")) (ELit (LString "m"))) (ELit (LString "Foo"))))
(DTypeSig false "identIfaceFooM" (TyCon "Ident"))
(DFunDef false "identIfaceFooM" () (EApp (EApp (EApp (EVar "identIn") (EVar "NsIface")) (ELit (LString "m"))) (ELit (LString "Foo"))))
(DTypeSig false "identTypeFooN" (TyCon "Ident"))
(DFunDef false "identTypeFooN" () (EApp (EApp (EApp (EVar "identIn") (EVar "NsType")) (ELit (LString "n"))) (ELit (LString "Foo"))))
(DTypeSig false "identTypeBarM" (TyCon "Ident"))
(DFunDef false "identTypeBarM" () (EApp (EApp (EApp (EVar "identIn") (EVar "NsType")) (ELit (LString "m"))) (ELit (LString "Bar"))))
(DTypeSig false "identTypeFooBuiltin" (TyCon "Ident"))
(DFunDef false "identTypeFooBuiltin" () (EApp (EApp (EVar "identBuiltinFixture") (EVar "NsType")) (ELit (LString "Foo"))))
(DTypeSig false "identSizeIn" (TyFun (TyCon "Ns") (TyCon "Ident")))
(DFunDef false "identSizeIn" ((PVar "ns")) (EApp (EApp (EApp (EVar "identIn") (EVar "ns")) (ELit (LString "m"))) (ELit (LString "size"))))
(DTypeSig false "allNsIdents" (TyApp (TyCon "List") (TyCon "Ident")))
(DFunDef false "allNsIdents" () (EApp (EApp (EMethodRef "map") (EVar "identSizeIn")) (EListLit (EVar "NsType") (EVar "NsIface") (EVar "NsMethod") (EVar "NsCtor") (EVar "NsField") (EVar "NsValue"))))
(DTypeSig false "identShiftA" (TyCon "Ident"))
(DFunDef false "identShiftA" () (EApp (EApp (EApp (EVar "identIn") (EVar "NsType")) (ELit (LString "ab"))) (ELit (LString "c"))))
(DTypeSig false "identShiftB" (TyCon "Ident"))
(DFunDef false "identShiftB" () (EApp (EApp (EApp (EVar "identIn") (EVar "NsType")) (ELit (LString "a"))) (ELit (LString "bc"))))
(DTypeSig false "regBothNs" (TyApp (TyCon "Registry") (TyCon "Int")))
(DFunDef false "regBothNs" () (EApp (EApp (EApp (EVar "regInsert") (EVar "identIfaceFooM")) (ELit (LInt 2))) (EApp (EApp (EApp (EVar "regInsert") (EVar "identTypeFooM")) (ELit (LInt 1))) (EVar "regEmpty"))))
(DTypeSig false "regBothOrigin" (TyApp (TyCon "Registry") (TyCon "Int")))
(DFunDef false "regBothOrigin" () (EApp (EApp (EApp (EVar "regInsert") (EVar "identTypeFooN")) (ELit (LInt 20))) (EApp (EApp (EApp (EVar "regInsert") (EVar "identTypeFooM")) (ELit (LInt 10))) (EVar "regEmpty"))))
(DTypeSig false "regOriginKinds" (TyApp (TyCon "Registry") (TyCon "Int")))
(DFunDef false "regOriginKinds" () (EApp (EApp (EApp (EVar "regInsert") (EVar "identTypeFooBuiltin")) (ELit (LInt 3))) (EApp (EApp (EApp (EVar "regInsert") (EVar "identTypeFooM")) (ELit (LInt 1))) (EVar "regEmpty"))))
(DTypeSig false "regBothNames" (TyApp (TyCon "Registry") (TyCon "Int")))
(DFunDef false "regBothNames" () (EApp (EApp (EApp (EVar "regInsert") (EVar "identTypeBarM")) (ELit (LInt 200))) (EApp (EApp (EApp (EVar "regInsert") (EVar "identTypeFooM")) (ELit (LInt 100))) (EVar "regEmpty"))))
(DTypeSig false "regShift" (TyApp (TyCon "Registry") (TyCon "Int")))
(DFunDef false "regShift" () (EApp (EApp (EApp (EVar "regInsert") (EVar "identShiftB")) (ELit (LInt 2))) (EApp (EApp (EApp (EVar "regInsert") (EVar "identShiftA")) (ELit (LInt 1))) (EVar "regEmpty"))))
(DTypeSig false "identIfaceIxM" (TyCon "Ident"))
(DFunDef false "identIfaceIxM" () (EApp (EApp (EApp (EVar "identIn") (EVar "NsIface")) (ELit (LString "m"))) (ELit (LString "Ix"))))
(DTypeSig false "identTypeIntM" (TyCon "Ident"))
(DFunDef false "identTypeIntM" () (EApp (EApp (EApp (EVar "identIn") (EVar "NsType")) (ELit (LString "m"))) (ELit (LString "Int"))))
(DTypeSig false "keyIxIntUndet" (TyCon "RegKey"))
(DFunDef false "keyIxIntUndet" () (EApp (EApp (EVar "regKeyNAt") (EListLit (EVar "identIfaceIxM") (EVar "identTypeIntM"))) (EListLit (ELit (LInt 2)) (ELit (LInt 0)))))
(DTypeSig false "keyIxUndetInt" (TyCon "RegKey"))
(DFunDef false "keyIxUndetInt" () (EApp (EApp (EVar "regKeyNAt") (EListLit (EVar "identIfaceIxM") (EVar "identTypeIntM"))) (EListLit (ELit (LInt 2)) (ELit (LInt 1)))))
(DTypeSig false "keyIxPresentOnly" (TyCon "RegKey"))
(DFunDef false "keyIxPresentOnly" () (EApp (EVar "regKeyN") (EListLit (EVar "identIfaceIxM") (EVar "identTypeIntM"))))
(DTypeSig false "regIxUndet" (TyApp (TyCon "Registry") (TyCon "Int")))
(DFunDef false "regIxUndet" () (EApp (EApp (EApp (EVar "regInsertK") (EVar "keyIxUndetInt")) (ELit (LInt 2))) (EApp (EApp (EApp (EVar "regInsertK") (EVar "keyIxIntUndet")) (ELit (LInt 1))) (EVar "regEmpty"))))
(DTypeSig false "keyIxNoDecl" (TyCon "RegKey"))
(DFunDef false "keyIxNoDecl" () (EApp (EApp (EVar "regKeyNAt") (EListLit (EVar "identIfaceIxM"))) (EListLit (ELit (LInt 2)))))
(DTypeSig false "identTypeLowerAM" (TyCon "Ident"))
(DFunDef false "identTypeLowerAM" () (EApp (EApp (EApp (EVar "identIn") (EVar "NsType")) (ELit (LString "m"))) (ELit (LString "a"))))
(DTypeSig false "keyIxDeclAOnly" (TyCon "RegKey"))
(DFunDef false "keyIxDeclAOnly" () (EApp (EApp (EVar "regKeyNAt") (EListLit (EVar "identIfaceIxM") (EVar "identTypeLowerAM"))) (EListLit (ELit (LInt 2)) (ELit (LInt 0)))))
(DTypeSig false "keyIxBareAOnly" (TyCon "RegKey"))
(DFunDef false "keyIxBareAOnly" () (EApp (EApp (EVar "RegKey") (EListLit (EApp (EVar "TkIdent") (EVar "identIfaceIxM")) (EApp (EApp (EVar "TkBare") (EVar "NsType")) (ELit (LString "a"))))) (EListLit (ELit (LInt 2)) (ELit (LInt 0)))))
(DTypeSig false "headDeclFoo" (TyApp (TyCon "Option") (TyCon "HeadKey")))
(DFunDef false "headDeclFoo" () (EApp (EVar "Some") (EApp (EApp (EVar "headKeyOfCon") (EApp (EVar "OriginModule") (ELit (LString "m")))) (ELit (LString "Foo")))))
(DTypeSig false "headBareFoo" (TyApp (TyCon "Option") (TyCon "HeadKey")))
(DFunDef false "headBareFoo" () (EApp (EVar "Some") (EApp (EVar "HkDecl") (EApp (EApp (EVar "TkBare") (EVar "NsType")) (ELit (LString "Foo"))))))
(DTypeSig false "headRigidA" (TyApp (TyCon "Option") (TyCon "HeadKey")))
(DFunDef false "headRigidA" () (EApp (EVar "Some") (EApp (EVar "HkRigid") (ELit (LString "a")))))
(DTypeSig false "regAllNs" (TyApp (TyCon "Registry") (TyCon "Int")))
(DFunDef false "regAllNs" () (EApp (EVar "regFromEntries") (EApp (EApp (EVar "zipNsValues") (EVar "allNsIdents")) (ELit (LInt 1)))))
(DTypeSig false "zipNsValues" (TyFun (TyApp (TyCon "List") (TyCon "Ident")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyTuple (TyCon "RegKey") (TyCon "Int"))))))
(DFunDef false "zipNsValues" ((PList) PWild) (EListLit))
(DFunDef false "zipNsValues" ((PCons (PVar "i") (PVar "rest")) (PVar "n")) (EBinOp "::" (ETuple (EApp (EVar "regKeyOf") (EVar "i")) (EVar "n")) (EApp (EApp (EVar "zipNsValues") (EVar "rest")) (EBinOp "+" (EVar "n") (ELit (LInt 1))))))
(DTypeSig false "regSlots" (TyApp (TyCon "Registry") (TyCon "Int")))
(DFunDef false "regSlots" () (EApp (EApp (EApp (EVar "regInsertK") (EApp (EApp (EVar "regKeyAt") (EVar "identIfaceFooM")) (ELit (LInt 1)))) (ELit (LInt 11))) (EApp (EApp (EApp (EVar "regInsertK") (EApp (EApp (EVar "regKeyAt") (EVar "identIfaceFooM")) (ELit (LInt 0)))) (ELit (LInt 10))) (EVar "regEmpty"))))
(DTypeSig false "regPairs" (TyApp (TyCon "Registry") (TyCon "Int")))
(DFunDef false "regPairs" () (EApp (EApp (EApp (EVar "regInsertK") (EApp (EVar "regKeyN") (EListLit (EVar "identIfaceFooM") (EVar "identTypeBarM")))) (ELit (LInt 2))) (EApp (EApp (EApp (EVar "regInsertK") (EApp (EVar "regKeyN") (EListLit (EVar "identIfaceFooM") (EVar "identTypeFooM")))) (ELit (LInt 1))) (EVar "regEmpty"))))
(DTypeSig false "mregOrderA" (TyApp (TyCon "MultiRegistry") (TyCon "Int")))
(DFunDef false "mregOrderA" () (EApp (EApp (EApp (EVar "mregAdd") (EVar "identTypeFooM")) (ELit (LInt 2))) (EApp (EApp (EApp (EVar "mregAdd") (EVar "identTypeFooM")) (ELit (LInt 1))) (EVar "mregEmpty"))))
(DTypeSig false "mregOrderB" (TyApp (TyCon "MultiRegistry") (TyCon "Int")))
(DFunDef false "mregOrderB" () (EApp (EApp (EApp (EVar "mregAdd") (EVar "identTypeFooM")) (ELit (LInt 1))) (EApp (EApp (EApp (EVar "mregAdd") (EVar "identTypeFooM")) (ELit (LInt 2))) (EVar "mregEmpty"))))
(DTypeSig false "tabA" (TyCon "TabKey"))
(DFunDef false "tabA" () (EApp (EApp (EApp (EVar "tabKeyOf") (EVar "NsType")) (EApp (EVar "OriginModule") (ELit (LString "apub")))) (ELit (LString "Box"))))
(DTypeSig false "tabZ" (TyCon "TabKey"))
(DFunDef false "tabZ" () (EApp (EApp (EApp (EVar "tabKeyOf") (EVar "NsType")) (EApp (EVar "OriginModule") (ELit (LString "zopapub")))) (ELit (LString "Box"))))
(DTypeSig false "tabU" (TyCon "TabKey"))
(DFunDef false "tabU" () (EApp (EApp (EVar "TkBare") (EVar "NsType")) (ELit (LString "Box"))))
(DTypeSig false "tabIfaceA" (TyCon "TabKey"))
(DFunDef false "tabIfaceA" () (EApp (EApp (EApp (EVar "tabKeyOf") (EVar "NsIface")) (EApp (EVar "OriginModule") (ELit (LString "apub")))) (ELit (LString "Box"))))
(DTypeSig false "tabTable" (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyCon "Int"))))
(DFunDef false "tabTable" () (EListLit (ETuple (EVar "tabZ") (ELit (LInt 2))) (ETuple (EVar "tabA") (ELit (LInt 1)))))
(DTypeSig false "ifaceG" (TyCon "TabKey"))
(DFunDef false "ifaceG" () (EApp (EApp (EApp (EVar "tabKeyOf") (EVar "NsIface")) (EApp (EVar "OriginModule") (ELit (LString "gmod")))) (ELit (LString "Same"))))
(DTypeSig false "ifaceP" (TyCon "TabKey"))
(DFunDef false "ifaceP" () (EApp (EApp (EApp (EVar "tabKeyOf") (EVar "NsIface")) (EApp (EVar "OriginModule") (ELit (LString "pmod")))) (ELit (LString "Same"))))
(DTypeSig false "ifaceU" (TyCon "TabKey"))
(DFunDef false "ifaceU" () (EApp (EApp (EVar "TkBare") (EVar "NsIface")) (ELit (LString "Same"))))
(DTypeSig false "slotGA" (TyCon "RegKey"))
(DFunDef false "slotGA" () (EApp (EApp (EVar "regKeyTabAt") (EVar "ifaceG")) (ELit (LInt 0))))
(DTypeSig false "slotPA" (TyCon "RegKey"))
(DFunDef false "slotPA" () (EApp (EApp (EVar "regKeyTabAt") (EVar "ifaceP")) (ELit (LInt 0))))
(DTypeSig false "slotUA" (TyCon "RegKey"))
(DFunDef false "slotUA" () (EApp (EApp (EVar "regKeyTabAt") (EVar "ifaceU")) (ELit (LInt 0))))
(DTypeSig false "slotTable" (TyApp (TyCon "List") (TyTuple (TyCon "RegKey") (TyCon "Int"))))
(DFunDef false "slotTable" () (EListLit (ETuple (EVar "slotGA") (ELit (LInt 2))) (ETuple (EVar "slotPA") (ELit (LInt 1)))))
(DTypeSig false "headA" (TyCon "HeadKey"))
(DFunDef false "headA" () (EApp (EApp (EVar "headKeyOfCon") (EApp (EVar "OriginModule") (ELit (LString "apub")))) (ELit (LString "Box"))))
(DTypeSig false "headZ" (TyCon "HeadKey"))
(DFunDef false "headZ" () (EApp (EApp (EVar "headKeyOfCon") (EApp (EVar "OriginModule") (ELit (LString "zopapub")))) (ELit (LString "Box"))))
(DTypeSig false "headU" (TyCon "HeadKey"))
(DFunDef false "headU" () (EApp (EVar "HkDecl") (EApp (EApp (EVar "TkBare") (EVar "NsType")) (ELit (LString "Box")))))
