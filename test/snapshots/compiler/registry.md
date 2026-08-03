# META
source_lines=1249
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
--   | table                            | key                     | site          |
--   |----------------------------------|-------------------------|---------------|
--   | `universeIfaceParamKinds`        | Ident × Int             | typecheck.mdk |
--   | `obUnivConcreteRef`              | Ident × Ident           | typecheck.mdk |
--   | `checkCallObligationsU` dedup    | Ident × [Option Ident]  | typecheck.mdk |
--   | `methodReqCountRef`              | Ident × Ident           | eval.mdk      |
--   | `ifaceDispatchRef`               | Ident × Ident           | eval.mdk      |
--
-- Three of the five are pure identity tuples (`regKeyN`); one pairs an
-- identity with a parameter SLOT, which is an ordinal and not a declaration —
-- it has no namespace and no origin, so it is carried in `RegKey`'s second
-- component (`regKeyAt`) rather than faked as an `Ident`.
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
-- ⚠️ COUNTING THE BYTE-SHAPE ASSERTIONS: there are FIVE, in two groups with
-- two different jobs, and earlier cuts of this file variously called them
-- "three" and "the ONE doctest" (in one case immediately above three of
-- them). THREE `startsWith "1:…"` lines pin the ident-COUNT prefix, described
-- in this paragraph; TWO `identKey … == "…"` lines pin the origin TAG,
-- described at their own site further down. Both groups are the documented
-- exception to the opacity contract above. Do not re-encode the number here —
-- `grep -c '^-- > \(startsWith "1:\|identKey ident.* == "\)' ` this file.
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

-- A tuple of identities, rendered by plain concatenation. Injective on its
-- own: each element contributes exactly four netstrings, so a stream of `4n`
-- netstrings decodes to exactly one list, and two lists of different length
-- render to strings of different length.
export identKeys : List Ident -> String
identKeys idents = joinWith "" (map identKey idents)

ordKey : Int -> String
ordKey n = lenKey "\{n}"

-- ── RegKey: what a registry is keyed BY ───────────────────────────────────
-- Identity components first, then ORDINAL components (a parameter slot, an
-- arity index) — things that are genuinely not declarations and so have no
-- namespace and no origin. See "What the target tables need" above for the
-- five tables that need this and for why an ordinal is not smuggled into an
-- `Ident`'s name field.
public export data RegKey =
  | RegKey (List Ident) (List Int)
deriving (Eq, Ord, Debug)

-- The one-identity case — by far the most common, and the shape the
-- `Ident`-taking convenience wrappers below all go through.
export regKeyOf : Ident -> RegKey
regKeyOf ident = RegKey [ident] []

-- An identity TUPLE (`obUnivConcreteRef`, `ifaceDispatchRef`,
-- `checkCallObligationsU`'s dedup key).
export regKeyN : List Ident -> RegKey
regKeyN idents = RegKey idents []

-- An identity plus an ordinal (`universeIfaceParamKinds`' `<iface>@<slot>`).
export regKeyAt : Ident -> Int -> RegKey
regKeyAt ident slot = RegKey [ident] [slot]

-- Identity tuple PLUS ordinals — the shape `checkCallObligationsU`'s dedup key
-- needs, and the reason it exists: that key's argument vector has ABSENT
-- positions (`Ident × [Option Ident]`, see "What the target tables need"), and
-- the only way to keep two vectors that differ in WHICH position is absent on
-- different keys is to carry the present positions' indices alongside the
-- present identities. Neither `regKeyN` (no ordinals) nor `regKeyAt` (one
-- ident, one ordinal) can express that, so the conversion would otherwise
-- have had to spell `RegKey` by hand and re-derive the injectivity argument.
export regKeyNAt : List Ident -> List Int -> RegKey
regKeyNAt idents ords = RegKey idents ords

export regKeyIdents : RegKey -> List Ident
regKeyIdents (RegKey idents _) = idents

export regKeyOrdinals : RegKey -> List Int
regKeyOrdinals (RegKey _ ords) = ords

-- OPAQUE, exactly as `identKey` is. The leading ident-count netstring is what
-- makes the identity block and the ordinal block unambiguously separable
-- without assuming anything about tag or name spellings.
export regKeyRender : RegKey -> String
regKeyRender (RegKey idents ords) = lenKey "\{listLen idents}"
  ++ identKeys idents
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
--     (`obUnivConcreteRef`, `ifaceDispatchRef` and `methodReqCountRef` are
--     grow-only within a run and cleared wholesale by `resetState`).

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
-- > regKeyIdents keyIxIntUndet == regKeyIdents keyIxUndetInt
-- True
-- > regSize regIxUndet
-- 2
-- > regLookupK keyIxIntUndet regIxUndet
-- Some 1
-- > regLookupK keyIxUndetInt regIxUndet
-- Some 2

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
-- > map (e => regKeyIdents (fst e)) (regEntries regBothNs) == [[identTypeFooM], [identIfaceFooM]]
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
-- > map (e => regKeyIdents (fst e)) (mregEntries mregOrderA) == [[identTypeFooM]]
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
(DTypeSig true "identKeys" (TyFun (TyApp (TyCon "List") (TyCon "Ident")) (TyCon "String")))
(DFunDef false "identKeys" ((PVar "idents")) (EApp (EApp (EVar "joinWith") (ELit (LString ""))) (EApp (EApp (EVar "map") (EVar "identKey")) (EVar "idents"))))
(DTypeSig false "ordKey" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "ordKey" ((PVar "n")) (EApp (EVar "lenKey") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "n"))) (ELit (LString "")))))
(DData Public "RegKey" () ((variant "RegKey" (ConPos (TyApp (TyCon "List") (TyCon "Ident")) (TyApp (TyCon "List") (TyCon "Int"))))) ())
(DImpl true "Eq" ((TyCon "RegKey")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "RegKey" (PVar "__a0") (PVar "__a1")) (PCon "RegKey" (PVar "__b0") (PVar "__b1"))) () (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "eq") (EVar "__a1")) (EVar "__b1"))))))))
(DImpl true "Ord" ((TyCon "RegKey")) () ((im "compare" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "RegKey" (PVar "__a0") (PVar "__a1")) (PCon "RegKey" (PVar "__b0") (PVar "__b1"))) () (EMatch (EApp (EApp (EVar "compare") (EVar "__a0")) (EVar "__b0")) (arm (PCon "Eq") () (EApp (EApp (EVar "compare") (EVar "__a1")) (EVar "__b1"))) (arm (PVar "__c") () (EVar "__c"))))))))
(DImpl true "Debug" ((TyCon "RegKey")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "RegKey" (PVar "__a0") (PVar "__a1")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "RegKey ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a1")))))))))
(DTypeSig true "regKeyOf" (TyFun (TyCon "Ident") (TyCon "RegKey")))
(DFunDef false "regKeyOf" ((PVar "ident")) (EApp (EApp (EVar "RegKey") (EListLit (EVar "ident"))) (EListLit)))
(DTypeSig true "regKeyN" (TyFun (TyApp (TyCon "List") (TyCon "Ident")) (TyCon "RegKey")))
(DFunDef false "regKeyN" ((PVar "idents")) (EApp (EApp (EVar "RegKey") (EVar "idents")) (EListLit)))
(DTypeSig true "regKeyAt" (TyFun (TyCon "Ident") (TyFun (TyCon "Int") (TyCon "RegKey"))))
(DFunDef false "regKeyAt" ((PVar "ident") (PVar "slot")) (EApp (EApp (EVar "RegKey") (EListLit (EVar "ident"))) (EListLit (EVar "slot"))))
(DTypeSig true "regKeyNAt" (TyFun (TyApp (TyCon "List") (TyCon "Ident")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "RegKey"))))
(DFunDef false "regKeyNAt" ((PVar "idents") (PVar "ords")) (EApp (EApp (EVar "RegKey") (EVar "idents")) (EVar "ords")))
(DTypeSig true "regKeyIdents" (TyFun (TyCon "RegKey") (TyApp (TyCon "List") (TyCon "Ident"))))
(DFunDef false "regKeyIdents" ((PCon "RegKey" (PVar "idents") PWild)) (EVar "idents"))
(DTypeSig true "regKeyOrdinals" (TyFun (TyCon "RegKey") (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "regKeyOrdinals" ((PCon "RegKey" PWild (PVar "ords"))) (EVar "ords"))
(DTypeSig true "regKeyRender" (TyFun (TyCon "RegKey") (TyCon "String")))
(DFunDef false "regKeyRender" ((PCon "RegKey" (PVar "idents") (PVar "ords"))) (EBinOp "++" (EBinOp "++" (EApp (EVar "lenKey") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "listLen") (EVar "idents")))) (ELit (LString "")))) (EApp (EVar "identKeys") (EVar "idents"))) (EApp (EApp (EVar "joinWith") (ELit (LString ""))) (EApp (EApp (EVar "map") (EVar "ordKey")) (EVar "ords")))))
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
(DTypeSig true "identKeys" (TyFun (TyApp (TyCon "List") (TyCon "Ident")) (TyCon "String")))
(DFunDef false "identKeys" ((PVar "idents")) (EApp (EApp (EVar "joinWith") (ELit (LString ""))) (EApp (EApp (EMethodRef "map") (EVar "identKey")) (EVar "idents"))))
(DTypeSig false "ordKey" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "ordKey" ((PVar "n")) (EApp (EVar "lenKey") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "")))))
(DData Public "RegKey" () ((variant "RegKey" (ConPos (TyApp (TyCon "List") (TyCon "Ident")) (TyApp (TyCon "List") (TyCon "Int"))))) ())
(DImpl true "Eq" ((TyCon "RegKey")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "RegKey" (PVar "__a0") (PVar "__a1")) (PCon "RegKey" (PVar "__b0") (PVar "__b1"))) () (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1"))))))))
(DImpl true "Ord" ((TyCon "RegKey")) () ((im "compare" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "RegKey" (PVar "__a0") (PVar "__a1")) (PCon "RegKey" (PVar "__b0") (PVar "__b1"))) () (EMatch (EApp (EApp (EMethodRef "compare") (EVar "__a0")) (EVar "__b0")) (arm (PCon "Eq") () (EApp (EApp (EMethodRef "compare") (EVar "__a1")) (EVar "__b1"))) (arm (PVar "__c") () (EVar "__c"))))))))
(DImpl true "Debug" ((TyCon "RegKey")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "RegKey" (PVar "__a0") (PVar "__a1")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "RegKey ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a1")))))))))
(DTypeSig true "regKeyOf" (TyFun (TyCon "Ident") (TyCon "RegKey")))
(DFunDef false "regKeyOf" ((PVar "ident")) (EApp (EApp (EVar "RegKey") (EListLit (EVar "ident"))) (EListLit)))
(DTypeSig true "regKeyN" (TyFun (TyApp (TyCon "List") (TyCon "Ident")) (TyCon "RegKey")))
(DFunDef false "regKeyN" ((PVar "idents")) (EApp (EApp (EVar "RegKey") (EVar "idents")) (EListLit)))
(DTypeSig true "regKeyAt" (TyFun (TyCon "Ident") (TyFun (TyCon "Int") (TyCon "RegKey"))))
(DFunDef false "regKeyAt" ((PVar "ident") (PVar "slot")) (EApp (EApp (EVar "RegKey") (EListLit (EVar "ident"))) (EListLit (EVar "slot"))))
(DTypeSig true "regKeyNAt" (TyFun (TyApp (TyCon "List") (TyCon "Ident")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "RegKey"))))
(DFunDef false "regKeyNAt" ((PVar "idents") (PVar "ords")) (EApp (EApp (EVar "RegKey") (EVar "idents")) (EVar "ords")))
(DTypeSig true "regKeyIdents" (TyFun (TyCon "RegKey") (TyApp (TyCon "List") (TyCon "Ident"))))
(DFunDef false "regKeyIdents" ((PCon "RegKey" (PVar "idents") PWild)) (EVar "idents"))
(DTypeSig true "regKeyOrdinals" (TyFun (TyCon "RegKey") (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "regKeyOrdinals" ((PCon "RegKey" PWild (PVar "ords"))) (EVar "ords"))
(DTypeSig true "regKeyRender" (TyFun (TyCon "RegKey") (TyCon "String")))
(DFunDef false "regKeyRender" ((PCon "RegKey" (PVar "idents") (PVar "ords"))) (EBinOp "++" (EBinOp "++" (EApp (EVar "lenKey") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "listLen") (EVar "idents")))) (ELit (LString "")))) (EApp (EVar "identKeys") (EVar "idents"))) (EApp (EApp (EVar "joinWith") (ELit (LString ""))) (EApp (EApp (EMethodRef "map") (EVar "ordKey")) (EVar "ords")))))
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
