# META
source_lines=788
stages=DESUGAR,MARK
# SOURCE
-- The SHARED ROUTE-WORD MINT (ARCH B-2, #1113) — the only mint of an impl route
-- word in the tree, imported by `types/typecheck.mdk`, `eval/eval.mdk` and
-- `ir/core_ir_lower.mdk`; the two mirrors it replaced (`eval.implKeyOf`'s private
-- `ppTyK` printer family, `typecheck.implKeyTc`'s hand-spelled body) are deleted.
--
-- The design doc's two-component `RKey` carrier (identity + word) was refused:
-- `Route` crosses into `ir/`, `backend/` and `eval/`, where the only namespaces
-- are `String` symbol names and `hashName`'d i64 dict words, so no reading site
-- can consume a separate identity component. The identity lives INSIDE the word
-- instead (content-derived, see `ifaceWordOf`), and `data Route`
-- (`frontend/ast.mdk`) is unchanged.
--
-- See compiler/TYPECHECK-TARGET-ARCHITECTURE.md § "9.6 The subsumption
-- enumeration — derived by SHAPE, not by prefix" for why this mint lives in its
-- own module rather than an existing one.
--
-- `Makefile`'s `test:` target names this module explicitly (as it names
-- `registry.mdk`), so `medaka test <file>` typechecks it and runs its doctests
-- (the compatibility pins: byte-identity with the pre-fold word on the
-- absent-origin arm) -- a module outside every entry's import closure is
-- otherwise invisible to `make medaka`, `make check-self` and
-- `test/typecheck_compiler_source.sh`.
--
-- ── What the exports are ──────────────────────────────────────────────────
-- `implRouteKeyWord` builds the route word for an impl: `<iface word>|<type args,
-- space-joined>|<method name or empty>`. The interface word is qualified when
-- origin is known (e.g., "b::Speak"), or the bare name when origin is absent.
--
-- A dictionary word is always the selected instance's `implRouteKeyWord` (no
-- method): one word per instance, the same in every module.
--
-- `rkTy`/`rkTyFunArg`/`rkTyAtom` are one prec-2 `Ty` printer. It matches
-- `types/typecheck.mdk`'s version, not `eval/eval.mdk`'s, because the latter is
-- incomplete on effect rows and constraints. This widens eval's words for
-- programs differing only on effect row or constraint, which is safe: no
-- accepted program has two impls that differ only on those axes.

-- `constraintUnresolved` is reached ONLY from the `TyConstrained` doctests
-- below (it is `Constraint`'s one legal mint for an unstamped occurrence).
-- Deleting it as unused fails at doctest RUN time, not at `check`.
import frontend.ast.{
  Ty(..),
  Constraint(..),
  TyConOrigin(..),
  EffAtomTy(..),
  qualifierSource,
  EffParamTy(..),
  effAtomSurface,
  authTermSurface,
  effAtomBare,
  effAtomWith,
  Route(..),
  EvId(..),
  isUnminted,
  EvVal(..),
  EvEntry(..),
  EvTable,
  constraintUnresolved,
  tyConBuiltin,
  ifaceIdentity,
  authTermsSurface,
}
import support.util.{joinWith, escStr}
import types.runtime_types.{installedBinderTable, restoreBinderTable}

-- ── the published evidence table (#2549 M2) ───────────────────────────────
-- `EDictAt` carries an `EvId`, not a route cell, so a reader answers "what did
-- the solver decide here" by looking the id up rather than by dereferencing a
-- pointer the typechecker handed it.  The lookup lives HERE because this module
-- is the one below all three readers of a solved route — `types/typecheck.mdk`
-- (dict passing), `eval/eval.mdk` and `ir/core_ir_lower.mdk` — exactly the three
-- the header above names as this seam's consumers.  A cell inside any one of
-- them would be unreachable from the other two, and `frontend/ast.mdk` (the only
-- lower module) imports nothing and holds no state.
--
-- Exactly one table is installed per elaboration, and every read of it completes
-- before the next elaboration installs: `test_cmd`'s `prepareMulti` / `prepareSingle` /
-- `runChosen` phases, `elaborateRun`, `runEmitWith`, `eval_autoprint_main.runElab`
-- and `playground_main.finishClean` each
-- elaborate, install, and finish reading before the next elaboration begins; a
-- diagnostics-only elaboration that runs between them (`test_cmd`'s helper validation)
-- runs inside `withEvidencePreserved`, which reinstalls the table it found.  A lookup
-- that cannot be answered is a panic on every arm:
--
--   no table installed  -> panic.  `evidenceRef` holding `None` means no elaboration
--                          has run.
--   ordinal below span  -> panic: the id is from an earlier graph.
--   ordinal above span  -> panic.
--   in-span `None`      -> panic.
--
-- This holds because the typechecker publishes an entry for EVERY `EDictAt` it mints,
-- including an application of zero dictionaries (`EvMany []`, the #739 arm of
-- `inferDictAtFound`), so "no entry" can only mean a missing or stale table.
--
-- What the panic does NOT catch: a read that escaped the install ordering and landed
-- on an ordinal inside the installed span.  A memo hit rewinds the counter, so two
-- elaborations can publish overlapping spans, and such a read can land on ANOTHER
-- GOAL'S ROUTES — silently wrong, at exit 0.  The module half of the id, compared on
-- every hit, is the only tripwire for that, and it cannot fire for today's consumer.
-- The install ordering above is the protection.
--
-- The index is an ARRAY over the id's ordinal, not a scan of the spine: the table
-- has one entry per solver goal (838 on a four-file fixture), so a per-site linear
-- scan would be the List-as-a-map quadratic `compiler/AGENTS.md` records thirteen
-- instances of.  Ordinals are graph-global (see `freshEvId`), so the ordinal less the
-- table's smallest one IS the index and carries uniqueness by itself; the array spans
-- the installed entries' ordinals, not every ordinal the process has minted.  The
-- id's MODULE half is compared on every hit as a tripwire, not as part of the key —
-- see `EvId` in `frontend/ast.mdk` for why it cannot fire for today's consumer and
-- must be kept anyway.
evidenceRef : Ref (Option EvIndex)
evidenceRef = Ref None

-- The table indexed by ordinal less its smallest one: the lowest ordinal and the
-- slots from it.
public export data EvIndex = EvIndex Int (Array (Option EvEntry))

-- The index of [entries]; two entries under one ordinal panic (`fillEvidence`).
export
evIndexOf : EvTable -> EvIndex
evIndexOf entries =
  let lo = evMinOrdinal entries
  let arr = arrayMake (evSlotCount entries lo - lo) None
  let _ = fillEvidence lo arr entries
  EvIndex lo arr

-- Replace the installed evidence with this elaboration's.  Called once per
-- elaboration, so the table never outlives the program it describes.
export
installEvidence : EvTable -> Unit
installEvidence entries = evidenceRef := Some (evIndexOf entries)

-- The installed index, or the empty one when no elaboration has published one, so
-- a reader holding it answers as an untyped lowering does: no entry for any id.
export
installedEvidenceIndex : Unit -> EvIndex
installedEvidenceIndex _ = match !evidenceRef
  Some idx => idx
  None => evIndexOf []

-- Test visibility (`typecheck_test.mdk`): the installed table's slot count, 0 when
-- none is installed.
export
installedEvidenceSlots : Unit -> Int
installedEvidenceSlots _ = match !evidenceRef
  None => 0
  Some (EvIndex _ arr) => arrayLength arr

-- Rewrite every installed entry in place (#2809).  The emit path renames its top-level
-- symbols AFTER elaboration, and an `RLocal` route carries one.  `mangleUnitsEv`
-- returns the renamed table by value as well; this keeps the installed copy equal to
-- it for the readers that still read the installed table.
export
remapEvidence : (EvEntry -> EvEntry) -> Unit
remapEvidence f = match !evidenceRef
  None => ()
  Some (EvIndex _ arr) => remapEvidenceGo f arr 0 (arrayLength arr)

remapEvidenceGo : (EvEntry -> EvEntry) ->
  Array (Option EvEntry) ->
  Int ->
  Int ->
  Unit
remapEvidenceGo f arr i n
  | i >= n = ()
  | otherwise =
    let _ = match arrayGetUnsafe i arr
      None => ()
      Some e => arraySetUnsafe i (Some (f e)) arr
    remapEvidenceGo f arr (i + 1) n

-- Every installed entry, in ordinal order: the table of installed entries.
-- Empty when no elaboration has published one.
export
installedEvidenceEntries : Unit -> List EvEntry
installedEvidenceEntries _ = match !evidenceRef
  None => []
  Some (EvIndex _ arr) => evidenceEntriesFrom arr (arrayLength arr - 1) []

-- Helper elaboration temporarily replaces the process-global evidence table.
-- Restore the complete installed table afterward, including method-occurrence
-- entries that an elaborateModules return value does not carry.  The binder-type
-- table is replaced by the same elaborations and is put back with it.
export
withEvidencePreserved : (Unit -> <e> a) -> <e> a
withEvidencePreserved action =
  let before = installedEvidenceEntries ()
  let binders = installedBinderTable ()
  let result = action ()
  let _ = installEvidence before
  let _ = restoreBinderTable binders
  result

evidenceEntriesFrom : Array (Option EvEntry) ->
  Int ->
  List EvEntry ->
  List EvEntry
evidenceEntriesFrom arr i acc =
  if i < 0 then
    acc
  else match arrayGetUnsafe i arr
    None => evidenceEntriesFrom arr (i - 1) acc
    Some e => evidenceEntriesFrom arr (i - 1) (e :: acc)

-- one past the largest ordinal in [entries], at least [acc]
evSlotCount : EvTable -> Int -> Int
evSlotCount [] acc = acc
evSlotCount ((EvEntry (EvId _ i) _) :: rest) acc =
  evSlotCount rest (max (i + 1) acc)

-- the smallest ordinal in [entries], 0 when there are none
evMinOrdinal : EvTable -> Int
evMinOrdinal [] = 0
evMinOrdinal ((EvEntry (EvId _ i) _) :: rest) = evMinFrom rest i

evMinFrom : EvTable -> Int -> Int
evMinFrom [] acc = acc
evMinFrom ((EvEntry (EvId _ i) _) :: rest) acc = evMinFrom rest (min i acc)

-- Two entries under one ordinal would mean two goals published under one name,
-- and the reader below could then answer with either.  The cell scheme this
-- replaces could not express that (one node, one cell), so it is a tripwire
-- rather than a case with a policy: no program in the gate corpus, the 59-fixture
-- module arm, or the compiler's own self-compile reaches it.
fillEvidence : Int -> Array (Option EvEntry) -> EvTable -> Unit
fillEvidence _ _ [] = ()
fillEvidence lo arr ((e@(EvEntry (EvId m i) _)) :: rest) =
  let _ = match arrayGetUnsafe (i - lo) arr
    None => arraySetUnsafe (i - lo) (Some e) arr
    Some _ =>
      panic "evidence table: two goals published under \{m}#\{intToString i}"
  fillEvidence lo arr rest

neverPublished : String -> String -> Int -> Result String a
neverPublished what m i =
  Err "evidence table: \{what} \{m}#\{intToString i} was never published"

-- The installed entry's answer for [ev], looked up as [what]; every miss panics.
installedAnswer : String -> EvId -> EvVal
installedAnswer what ev = match installedLookup what ev
  Ok v => v
  Err message => panic message

-- `installedAnswer` over an explicit index.
answerIn : EvIndex -> String -> EvId -> EvVal
answerIn idx what ev = match evidenceLookup (Some idx) what ev
  Ok v => v
  Err message => panic message

-- `installedAnswer`'s answer, or the reason the installed table has none.
export
installedLookup : String -> EvId -> Result String EvVal
installedLookup what ev = evidenceLookup !evidenceRef what ev

-- The lookup over [table], the shape `evidenceRef` holds: `None` when no
-- elaboration has published one, else the lowest ordinal and the slots from it.
export
evidenceLookup : Option EvIndex -> String -> EvId -> Result String EvVal
evidenceLookup None what (EvId m i) =
  Err
    "evidence table: no elaboration has published one (looking up \{what} \{m}#\{intToString i})"
evidenceLookup (Some (EvIndex lo arr)) what (EvId m i) =
  if i < lo then
    Err "evidence table: \{what} \{m}#\{intToString i} is from an earlier graph"
  else if i - lo >= arrayLength arr then
    neverPublished what m i
  else match arrayGetUnsafe (i - lo) arr
    None => neverPublished what m i
    Some (EvEntry (EvId m2 _) v) =>
      if m2 == m then
        Ok v
      else
        Err "evidence table: \{m}#\{intToString i} answered by module \{m2}"

-- The dictionary routes solved for [ev], slot-ordered.
--
-- Every `EDictAt` has an entry; an application that needs no routing (the #739
-- bare-name-collision arm of `inferDictAtFound`) is published as `EvMany []`.  An id
-- with no entry therefore means the installed table is not the one this node's
-- elaboration published, and it panics, as `evMethodRoutes` does.
export
evDictRoutes : EvId -> List Route
evDictRoutes ev = evRoutesOf (installedAnswer "dictionary application" ev)

-- `evDictRoutes` over an explicit index.
export
evDictRoutesIn : EvIndex -> EvId -> List Route
evDictRoutesIn idx ev = evRoutesOf (answerIn idx "dictionary application" ev)

evRoutesOf : EvVal -> List Route
evRoutesOf (EvMany rs) = rs
evRoutesOf (EvOne _) =
  panic "evidence table: a dictionary application solved to a single route"
evRoutesOf (EvMethod _ _ _ _ _) =
  panic
    "evidence table: a dictionary application answered by a method occurrence"
evRoutesOf (EvLit _ _) =
  panic "evidence table: a dictionary application answered by a literal site"
evRoutesOf (EvHead _) =
  panic
    "evidence table: a dictionary application answered by a record-head site"

-- The route solved for operator site [ev].  A site built after inference carries
-- `unminted`: no route was ever decided for it, and it answers `RNone`, the
-- builtin operator.  Every other miss panics, as `evDictRoutes` does.
export
evSiteRoute : EvId -> Route
evSiteRoute ev = match evSiteRouteResult ev
  Ok r => r
  Err message => panic message

-- `evSiteRoute` over an explicit index.
export
evSiteRouteIn : EvIndex -> EvId -> Route
evSiteRouteIn idx ev = match siteRouteResultIn (Some idx) ev
  Ok r => r
  Err message => panic message

-- `evSiteRoute`'s answer, or the reason the installed table has none.
export
evSiteRouteResult : EvId -> Result String Route
evSiteRouteResult ev = siteRouteResultIn !evidenceRef ev

siteRouteResultIn : Option EvIndex -> EvId -> Result String Route
siteRouteResultIn table ev
  | isUnminted ev = Ok RNone
  | otherwise = match evidenceLookup table "operator site" ev
    Ok (EvOne r) => Ok r
    Ok _ =>
      Err "evidence table: an operator site answered by another kind of entry"
    Err message => Err message

-- The defaulted float and `fromInt` route solved for numeric literal site [ev].
-- A literal built after inference carries `unminted` and answers `(None, RNone)`,
-- a plain `Int`.  Every other miss panics.
export
evSiteLit : EvId -> (Option Float, Route)
evSiteLit ev = match evSiteLitResult ev
  Ok answer => answer
  Err message => panic message

-- `evSiteLit` over an explicit index.
export
evSiteLitIn : EvIndex -> EvId -> (Option Float, Route)
evSiteLitIn idx ev = match siteLitResultIn (Some idx) ev
  Ok answer => answer
  Err message => panic message

-- `evSiteLit`'s answer, or the reason the installed table has none.
export
evSiteLitResult : EvId -> Result String (Option Float, Route)
evSiteLitResult ev = siteLitResultIn !evidenceRef ev

siteLitResultIn : Option EvIndex -> EvId -> Result String (Option Float, Route)
siteLitResultIn table ev
  | isUnminted ev = Ok (None, RNone)
  | otherwise = match evidenceLookup table "literal site" ev
    Ok (EvLit f r) => Ok (f, r)
    Ok _ =>
      Err "evidence table: a literal site answered by another kind of entry"
    Err message => Err message

-- The resolved record head published for field access or record update site [ev],
-- "" when inference never resolved one.  A site built after inference carries
-- `unminted` and answers "".  Every other miss panics.
export
evSiteHead : EvId -> String
evSiteHead ev = match evSiteHeadResult ev
  Ok head => head
  Err message => panic message

-- `evSiteHead` over an explicit index.
export
evSiteHeadIn : EvIndex -> EvId -> String
evSiteHeadIn idx ev = match siteHeadResultIn (Some idx) ev
  Ok head => head
  Err message => panic message

-- `evSiteHead`'s answer, or the reason the installed table has none.
export
evSiteHeadResult : EvId -> Result String String
evSiteHeadResult ev = siteHeadResultIn !evidenceRef ev

siteHeadResultIn : Option EvIndex -> EvId -> Result String String
siteHeadResultIn table ev
  | isUnminted ev = Ok ""
  | otherwise = match evidenceLookup table "record-head site" ev
    Ok (EvHead h) => Ok h
    Ok _ =>
      Err "evidence table: a record-head site answered by another kind of entry"
    Err message => Err message

-- The answer published for a method occurrence: the interface identity it resolved
-- to, its selected denotation's pre-use arrow arity, dispatch route, selected impl's
-- `requires` dicts and the method's own `=>` dicts.  The arity is fixed from the selected scheme before application can
-- specialize its result.
--
-- As with `evDictRoutes`, a miss here is LOUD on every arm.  The typechecker mints
-- one entry per `EMethodAt` node at the moment it constructs the node and
-- publishes every one of them, so an id with no entry can only mean the table
-- installed is not the one this node's elaboration published — the install-
-- ordering hazard the header above describes, surfaced instead of answered with
-- an unrouted dispatch.
export
evMethodRoutes : EvId -> (String, Int, Route, List Route, List Route)
evMethodRoutes ev = evMethodOf (installedAnswer "method occurrence" ev)

-- `evMethodRoutes` over an explicit index.
export
evMethodRoutesIn : EvIndex ->
  EvId ->
  (String, Int, Route, List Route, List Route)
evMethodRoutesIn idx ev = evMethodOf (answerIn idx "method occurrence" ev)

evMethodOf : EvVal -> (String, Int, Route, List Route, List Route)
evMethodOf (EvMethod iface arity r impls meths) =
  (iface, arity, r, impls, meths)
evMethodOf _ =
  panic
    "evidence table: a method occurrence answered by a dictionary application"

-- ── the interface half of the word ────────────────────────────────────────
-- `module::Iface` when the interface's origin is known, and the BARE name when
-- it is not.
--
-- 🚨 THE FALLBACK IS THE WHOLE POINT OF THIS FUNCTION — DO NOT DELETE IT AS
-- REDUNDANT. `ifaceIdentity` answers `""` on both loader-less arms
-- (`OriginUnresolved`, `OriginBuiltin`) and the tree states that `""` IS
-- ABSENCE, NOT AN IDENTITY (`frontend/ast.mdk`, `ifaceIdentity`'s own
-- doc-comment; `ifaceIdMatches` is the ONLY legal comparison on two of these
-- strings and absence never matches even itself). The flat drivers
-- deliberately stamp no origin, so a word built from a RAW `ifaceIdentity`
-- would spell `"|T|"` for EVERY interface under `medaka check <single file>`,
-- lsp, repl, doc, lint and snapshot — collapsing onto one word the instances
-- that the present bare-name word keeps apart. That is a silent-wrongness
-- regression, and it would be invisible to any golden that only exercises the
-- module path.
--
-- ⚠️ THE PROPERTY THE FALLBACK RESTS ON, stated because this is precisely
-- where a silent collapse would live: the bare-name arm is safe only because
-- two same-spelled interfaces cannot both have absent origins AND be in scope
-- together — the flat path is ONE module and therefore one namespace, and
-- cross-module the origins are stamped. A future change that lets a
-- loader-less driver see two modules at once breaks that premise, and this is
-- the line it breaks.
export
ifaceWordOf : TyConOrigin -> String -> String
ifaceWordOf o name = match ifaceIdentity o name
  "" => name
  ident => ident

-- ── the FUNCTION head tag ─────────────────────────────────────────────────
-- The dispatch/impl-tag of an ARROW-headed impl (`impl Sz (Int -> Int)`) —
-- #1617.  Sited HERE, beside the route word, for the reason this module exists
-- at all: the tag is derived independently on three sides of the seam
-- (`typecheck.headTyconTy`/`headTyconMono`, `eval.headTycon`, and through the
-- latter `core_ir_lower.headTyconHead`), and a mirrored constant is exactly the
-- drift `tupleHeadTag`/`tupleHeadTagTc` still carries.  One mint, three readers.
--
-- 🚨 IT IS DELIBERATELY ARITY-FREE, and that is the opposite of the nearest
-- precedent (`tupleHeadTag n = "__tuple<n>__"`), so the divergence is derived
-- rather than assumed.  A tuple's arity is the ONLY thing that separates
-- `(Int, Int)` from `(Int, Int, Int)` at the head, and the runtime cell carries
-- it (`HTuple`), so an arity-erased tuple tag coalesced impls that a value could
-- still be told apart by.  An arrow has NO runtime tag at all (a closure carries
-- no cell tag — that is the very E-PANIC #1617 reports on `build`), and its arity
-- does not separate the pair the bug is about: `Int -> Int` and `Bool -> Bool`
-- are both arity-1.  So NO tag drawn from an arrow's shape can discriminate two
-- arrow-headed impls, and the discrimination has to come — and already does come
-- — from `implRouteKeyWord` above, which prints the FULL type args.  The single
-- tag's job is only to make the two impls share a head, the case a symbol tag
-- spells with the canonical key.  This is the same mechanism `Pair Int Bool` vs
-- `Pair Bool Int` already rides, not a new one.
export
funHeadTag : String
funHeadTag = "__fun__"

-- ── the impl route word ───────────────────────────────────────────────────
-- `<iface word>|<type args, prec-2, space-joined>|<method name or empty>`.
--
-- Built from the same source (an impl's AST type args) on BOTH sides of the
-- seam — the definition side at install time and the caller side at each
-- ground `RKey` route site — so the two strings agree BY CONSTRUCTION rather
-- than by two mirrored implementations happening to stay in lockstep. Two
-- impls sharing a head tycon but differing in type args (`Pair Int Bool` vs
-- `Pair Bool Int`) get DISTINCT words, which is what lets narrowing pick the
-- impl the typechecker chose instead of falling back to first-impl-wins.
--
-- ⚠️ The `|` separators are NOT collision-free the way `support/util.mdk`'s
-- `lenKey` netstrings are; this is the EXISTING wire format, reproduced
-- verbatim, because its consumers in `ir/`, `backend/` and `eval/` are plain
-- `String` namespaces that already carry it. Changing the format is a
-- different bite with a different blast radius.
export
implRouteKeyWord : TyConOrigin -> String -> List Ty -> Option String -> String
implRouteKeyWord o iface tys nm =
  "\{ifaceWordOf o iface}|\{joinWith " " (map rkTyAtom tys)}|\{optionOr "" nm}"

-- The dictionary word of the prelude's `Num Int` instance, whose `fromInt` is the
-- identity: the native emitter recognises a literal routed to it.
export
numIntWord : String
numIntWord = "core::Num|Int|"

-- The dictionary word of the prelude's `Num Float` instance, whose `fromInt`
-- cannot fail.
export
numFloatWord : String
numFloatWord = "core::Num|Float|"

-- ── the type-head word (#1397) ───────────────────────────────────────────
-- The word a type head contributes to every impl tag, route word, dictionary
-- word and runtime type tag: the prelude's and the language's types by their
-- name, every other type by its declaring module's id, a dot, and its name.
-- Impl dispatch keys a type by this word in every engine, so two modules'
-- same-spelled types never share an impl, and a program's own type spelled
-- like a prelude type (`Result`) is not the prelude's.
--
-- The word must be INJECTIVE over type identities: a type name has no dot, so
-- the last dot separates the module id from the name, and a word with no dot
-- is a prelude or builtin type.  It is not an identifier; a backend spells it
-- into a symbol through `private_mangle.injectiveIdent`, never `sanitizeId`,
-- whose many-to-one mapping would merge `a.b.T` with `a_b.T` (#1950's lesson).
--
-- >>> typeTagOf (OriginModule "core") "Result"
-- "Result"
-- >>> typeTagOf OriginBuiltin "Int"
-- "Int"
-- >>> typeTagOf (OriginModule "app.dirs") "T"
-- "app.dirs.T"
export
typeTagOf : TyConOrigin -> String -> String
typeTagOf (OriginModule "core") name = name
typeTagOf (OriginModule m) name = "\{m}.\{name}"
typeTagOf _ name = name

-- The name a type word shows a reader: the part after its last dot.  A
-- dispatch word is internal; a message names the type as it is written.
--
-- >>> typeTagName "app.dirs.T"
-- "T"
-- >>> typeTagName "Int"
-- "Int"
export
typeTagName : String -> String
typeTagName tag = afterLastDot tag (stringLength tag - 1)

afterLastDot : String -> Int -> String
afterLastDot tag i
  | i < 0 = tag
  | stringSlice i (i + 1) tag == "." =
    stringSlice (i + 1) (stringLength tag) tag
  | otherwise = afterLastDot tag (i - 1)

-- ── the ONE prec-2 `Ty` printer ──────────────────────────────────────────
-- Mirrors `types/typecheck.mdk`'s `ppTy` family byte-for-byte (which in turn
-- mirrors the retired OCaml `pp_ty_prec`): `rkTy` is prec 0, `rkTyFunArg`
-- prec 1 (wraps arrows), `rkTyAtom` prec 2 (wraps arrows AND applications).
--
-- A type constructor renders through `typeTagOf`, so two modules' same-spelled
-- types are two words (#1397).
rkTy : Ty -> String
rkTy (TyCon { tyConName = n, tyConOrigin = o }) = typeTagOf o n
rkTy (TyVar n) = n
rkTy (TyApp a b) = "\{rkTy a} \{rkTyAtom b}"
rkTy (TyFun a b) = "\{rkTyFunArg a} -> \{rkTy b}"
rkTy (TyTuple ts) = "(" ++ joinWith ", " (map rkTy ts) ++ ")"
rkTy (TyEffect effs tail t) = "<\{rkRowBody effs tail}> \{rkTy t}"
-- A bare row atom (#997) wraps no type, so there is nothing to fall back to.
rkTy (TyRow effs tail _) = "<\{rkRowBody effs tail}>"
rkTy (TyAuth ps _) = authTermsSurface escStr ps
rkTy (TyConstrained cs t) = "\{rkConstraints cs} => \{rkTy t}"
-- A binder's name is lexical to its signature and is not part of the word;
-- the qualifier IS (it changes what the argument means), so it is kept.
rkTy (TyNamed _ t _) = rkTy t
rkTy (TyQual t ns _) = "\{rkTyAtom t} \{qualifierSource escStr ns}"

-- argument of `->`: wrap `TyFun` (prec ≥ 1) but not `TyApp` (prec < 2).
rkTyFunArg : Ty -> String
rkTyFunArg (TyFun a b) = "(" ++ rkTy (TyFun a b) ++ ")"
rkTyFunArg t = rkTy t

-- argument of an application: wrap `TyFun` and `TyApp` (both prec ≥ 2).
rkTyAtom : Ty -> String
rkTyAtom (TyFun a b) = "(" ++ rkTy (TyFun a b) ++ ")"
rkTyAtom (TyApp a b) = "(" ++ rkTy (TyApp a b) ++ ")"
rkTyAtom t = rkTy t

-- shared `<…>` row-body renderer for the `TyEffect`/`TyRow` arms above.
rkRowBody : List EffAtomTy -> List String -> String
rkRowBody effs [] = joinWith ", " (map rkEffAtom effs)
rkRowBody [] tails = joinWith " | " tails
rkRowBody effs tails =
  "\{joinWith ", " (map rkEffAtom effs)} | \{joinWith " | " tails}"

-- One effect atom, with its optional domain parameter. The domain IS part of
-- what a written row means, so it is kept: dropping it would collide
-- `Net "a/*"` and `Net "b/*"` onto one word.
--
-- 🚨 `a` LEFT THIS DIRECTIVE MARKED "TRANSITIONAL, `B-2.2-e` OWNS DELETING IT".
-- `e` LANDED AND REFUSED TO DELETE IT, because the premise was wrong: `e` deletes
-- `eval.mdk`'s copy (`ppEffAtomK`, which only `implKeyOf` reached), but
-- `types/typecheck.mdk`'s `ppEffAtomTy` and `tools/doc.mdk`'s `ppEffAtomDoc` are
-- reached by the DIAGNOSTIC printers, which `e` does not touch — so this copy
-- does NOT become the only one; it becomes one of THREE.  MEASURED, not reasoned:
-- with the directive removed,
--   medaka lint --only=rule-duplicate-body --deny=rule-duplicate-body \
--     compiler stdlib sqlite
-- exits 1 with *"'rkEffAtom' has a body structurally identical to a definition in
-- compiler/tools/doc.mdk, compiler/types/typecheck.mdk"*.  The directive stays
-- until someone folds the DIAGNOSTIC printers too, which is a different bite with
-- a different blast radius (every error message that renders a type).
--
-- 🚨 PLACEMENT IS LOAD-BEARING, and the diagnostic's own line number misleads.
-- `-- lint-disable-next-line rule-duplicate-body` must sit immediately above
-- THE SPECIFIC DUPLICATED EQUATION (here the `Some s` arm, exactly as
-- `eval.mdk` places its copy).  Above the signature, or above the first
-- equation, it does NOT suppress — measured, three placements, same command:
--   medaka lint --only=rule-duplicate-body --deny=rule-duplicate-body \
--     compiler stdlib sqlite
-- The finding is REPORTED at the declaration's first line, which is a
-- decl-level anchor and NOT the line the directive is matched against; putting
-- the directive where the diagnostic points is the natural move and it fails.
rkEffAtom : EffAtomTy -> String
rkEffAtom a = effAtomSurface escStr a

-- single constraint: no outer parens; multiple: parenthesised.
rkConstraints : List Constraint -> String
rkConstraints [c] = rkConstraint c
rkConstraints cs = "(" ++ joinWith ", " (map rkConstraint cs) ++ ")"

rkConstraint : Constraint -> String
rkConstraint (Constraint { constraintHead = iface, constraintArgs = [] }) =
  iface
rkConstraint (Constraint { constraintHead = iface, constraintArgs = tys }) =
  "\{iface} \{joinWith " " (map rkTyAtom tys)}"

-- ── doctests ─────────────────────────────────────────────────────────────
-- 🚨 THESE ARE THE ONLY THING THAT RUNS THIS MODULE (see the header): with no
-- call sites, `make medaka`, `make check-self` and
-- `test/typecheck_compiler_source.sh` are all blind to it. Deleting the
-- `Makefile` `test:` line that names this file would silently un-run every
-- assertion below.

-- Fixtures. `rkTyInt`/`rkTyBool` are the unresolved-origin `TyCon`s a flat
-- driver builds; `rkTyIntM` is the same head with a module origin stamped, and
-- it renders IDENTICALLY — pinning that a type argument's origin is not in the
-- word (see `rkTy`'s doc-comment).
rkTyInt : Ty
rkTyInt =
  TyCon { tyConName = "Int", tyConLoc = None, tyConOrigin = OriginUnresolved }

rkTyBool : Ty
rkTyBool =
  TyCon { tyConName = "Bool", tyConLoc = None, tyConOrigin = OriginUnresolved }

rkTyFloat : Ty
rkTyFloat = tyConBuiltin "Float" None

rkTyIntM : Ty
rkTyIntM =
  TyCon { tyConName = "Int", tyConLoc = None, tyConOrigin = OriginModule "m" }

rkTyList : Ty
rkTyList =
  TyCon { tyConName = "List", tyConLoc = None, tyConOrigin = OriginUnresolved }

-- `ifaceWordOf`: the module arm qualifies, and BOTH absent arms fall back to
-- the bare name rather than to `""`. The last two lines are the ones that red
-- if the fallback is deleted — without it they would both read `""`, i.e. the
-- every-interface-collapses-to-one-word regression the doc-comment describes.
-- > ifaceWordOf (OriginModule "b") "Speak"
-- "b::Speak"
-- > ifaceWordOf OriginUnresolved "Speak"
-- "Speak"
-- > ifaceWordOf OriginBuiltin "Speak"
-- "Speak"

-- Two DIFFERENT modules declaring the same interface name stay apart…
-- > ifaceWordOf (OriginModule "a") "Speak" == ifaceWordOf (OriginModule "b") "Speak"
-- False

-- …and the bare arm is NOT equal to any qualified one, so a stamped and an
-- unstamped occurrence never silently share a word.
-- > ifaceWordOf OriginUnresolved "Speak" == ifaceWordOf (OriginModule "a") "Speak"
-- False

-- `implRouteKeyWord`, origin ABSENT: byte-identical to what `implKeyTc` and
-- `implKeyOf` produce today. These are the compatibility pins — if one of them
-- moves, the mint is no longer a drop-in for the two originals.
-- > implRouteKeyWord OriginUnresolved "Show" [rkTyInt] None
-- "Show|Int|"
-- > implRouteKeyWord OriginUnresolved "Show" [] None
-- "Show||"
-- > implRouteKeyWord OriginUnresolved "Show" [rkTyInt] (Some "show")
-- "Show|Int|show"
-- > implRouteKeyWord OriginUnresolved "Pair" [rkTyInt, rkTyBool] None
-- "Pair|Int Bool|"

-- Argument ORDER is preserved, which is what keeps `Pair Int Bool` and
-- `Pair Bool Int` on distinct words.
-- > implRouteKeyWord OriginUnresolved "P" [rkTyInt, rkTyBool] None == implRouteKeyWord OriginUnresolved "P" [rkTyBool, rkTyInt] None
-- False

-- An APPLIED argument is parenthesised (prec 2), so `Show (List Int)` cannot
-- be confused with a two-argument impl.
-- > implRouteKeyWord OriginUnresolved "Show" [TyApp rkTyList rkTyInt] None
-- "Show|(List Int)|"
-- > implRouteKeyWord OriginUnresolved "Show" [TyApp rkTyList rkTyInt] None == implRouteKeyWord OriginUnresolved "Show" [rkTyList, rkTyInt] None
-- False

-- A type argument's declaring module IS in the word (#1397): module `m`'s own
-- `Int` is not the builtin one.
-- > implRouteKeyWord OriginUnresolved "Show" [rkTyIntM] None
-- "Show|m.Int|"
-- > implRouteKeyWord OriginUnresolved "Show" [rkTyIntM] None == implRouteKeyWord OriginUnresolved "Show" [rkTyInt] None
-- False

-- `numIntWord` is `implRouteKeyWord`'s word for the prelude's `Num Int`.
-- > numIntWord == implRouteKeyWord (OriginModule "core") "Num" [rkTyInt] None
-- True
-- > numFloatWord == implRouteKeyWord (OriginModule "core") "Num" [rkTyFloat] None
-- True

-- `implRouteKeyWord`, origin PRESENT: the #1047/#1265 route-word substitution
-- (NOT #1182 — see the header). Applied by `B-2.2-b1` at `keyForSite`.
-- > implRouteKeyWord (OriginModule "b") "Speak" [rkTyInt] None
-- "b::Speak|Int|"
-- > implRouteKeyWord (OriginModule "a") "Speak" [rkTyInt] None == implRouteKeyWord (OriginModule "b") "Speak" [rkTyInt] None
-- False

-- The `Ty` printer, at the three precedences. `rkTyAtom` wraps an application
-- and an arrow; `rkTy` wraps neither.
-- > rkTy (TyApp rkTyList rkTyInt)
-- "List Int"
-- > rkTyAtom (TyApp rkTyList rkTyInt)
-- "(List Int)"
-- > rkTy (TyFun rkTyInt rkTyBool)
-- "Int -> Bool"
-- > rkTyAtom (TyFun rkTyInt rkTyBool)
-- "(Int -> Bool)"

-- Right-associativity of `->` is visible: the LEFT argument of an arrow is
-- parenthesised, the right is not.
-- > rkTy (TyFun (TyFun rkTyInt rkTyBool) rkTyInt)
-- "(Int -> Bool) -> Int"
-- > rkTy (TyFun rkTyInt (TyFun rkTyBool rkTyInt))
-- "Int -> Bool -> Int"

-- An application is NOT parenthesised in an arrow argument (prec 1 < 2).
-- > rkTy (TyFun (TyApp rkTyList rkTyInt) rkTyBool)
-- "List Int -> Bool"
-- > rkTy (TyVar "a")
-- "a"
-- > rkTy (TyTuple [rkTyInt, rkTyBool])
-- "(Int, Bool)"

-- The three arms where this printer is the COMPLETE one and `eval`'s
-- `ppTyAtomK` is not (see the header). These assertions are the record of what
-- a later bite's caller collapse would change on the eval side.
-- > rkTy (TyEffect [effAtomBare "Stdout"] [] rkTyInt)
-- "<Stdout> Int"
-- > rkTy (TyRow [effAtomBare "Stdout"] [] None)
-- "<Stdout>"
-- > rkTy (TyRow [effAtomBare "Stdout", effAtomBare "Rand"] [] None)
-- "<Stdout, Rand>"
-- > rkTy (TyRow [] ["e"] None)
-- "<e>"
-- > rkTy (TyRow [effAtomBare "Stdout"] ["e"] None)
-- "<Stdout | e>"

-- A domain parameter is kept, so two rows differing only by domain do not
-- collide onto one word.
-- > rkTy (TyRow [effAtomWith "Net" (EPLit "a/*")] [] None) == rkTy (TyRow [effAtomWith "Net" (EPLit "b/*")] [] None)
-- False
-- > rkTy (TyRow [effAtomWith "Net" (EPName "host")] [] None)
-- "<Net host>"

-- A constraint prefix: bare for one, parenthesised for two.
-- > rkTy (TyConstrained [constraintUnresolved "Eq" [TyVar "a"]] (TyVar "a"))
-- "Eq a => a"
-- > rkTy (TyConstrained [constraintUnresolved "Eq" [], constraintUnresolved "Ord" [TyVar "a"]] (TyVar "a"))
-- "(Eq, Ord a) => a"

-- Two impls differing ONLY in an effect row get distinct words here — the
-- property eval's printer does not have today.
-- > implRouteKeyWord OriginUnresolved "A" [TyEffect [effAtomBare "Stdout"] [] rkTyInt] None == implRouteKeyWord OriginUnresolved "A" [TyEffect [effAtomBare "Rand"] [] rkTyInt] None
-- False
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Ty" true) (mem "Constraint" true) (mem "TyConOrigin" true) (mem "EffAtomTy" true) (mem "qualifierSource" false) (mem "EffParamTy" true) (mem "effAtomSurface" false) (mem "authTermSurface" false) (mem "effAtomBare" false) (mem "effAtomWith" false) (mem "Route" true) (mem "EvId" true) (mem "isUnminted" false) (mem "EvVal" true) (mem "EvEntry" true) (mem "EvTable" false) (mem "constraintUnresolved" false) (mem "tyConBuiltin" false) (mem "ifaceIdentity" false) (mem "authTermsSurface" false))))
(DUse false (UseGroup ("support" "util") ((mem "joinWith" false) (mem "escStr" false))))
(DUse false (UseGroup ("types" "runtime_types") ((mem "installedBinderTable" false) (mem "restoreBinderTable" false))))
(DTypeSig false "evidenceRef" (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "EvIndex"))))
(DFunDef false "evidenceRef" () (EApp (EVar "Ref") (EVar "None")))
(DData Public "EvIndex" () ((variant "EvIndex" (ConPos (TyCon "Int") (TyApp (TyCon "Array") (TyApp (TyCon "Option") (TyCon "EvEntry")))))) ())
(DTypeSig true "evIndexOf" (TyFun (TyCon "EvTable") (TyCon "EvIndex")))
(DFunDef false "evIndexOf" ((PVar "entries")) (EBlock (DoLet false false (PVar "lo") (EApp (EVar "evMinOrdinal") (EVar "entries"))) (DoLet false false (PVar "arr") (EApp (EApp (EVar "arrayMake") (EBinOp "-" (EApp (EApp (EVar "evSlotCount") (EVar "entries")) (EVar "lo")) (EVar "lo"))) (EVar "None"))) (DoLet false false PWild (EApp (EApp (EApp (EVar "fillEvidence") (EVar "lo")) (EVar "arr")) (EVar "entries"))) (DoExpr (EApp (EApp (EVar "EvIndex") (EVar "lo")) (EVar "arr")))))
(DTypeSig true "installEvidence" (TyFun (TyCon "EvTable") (TyCon "Unit")))
(DFunDef false "installEvidence" ((PVar "entries")) (EApp (EApp (EVar "setRef") (EVar "evidenceRef")) (EApp (EVar "Some") (EApp (EVar "evIndexOf") (EVar "entries")))))
(DTypeSig true "installedEvidenceIndex" (TyFun (TyCon "Unit") (TyCon "EvIndex")))
(DFunDef false "installedEvidenceIndex" (PWild) (EMatch (EUnOp "!" (EVar "evidenceRef")) (arm (PCon "Some" (PVar "idx")) () (EVar "idx")) (arm (PCon "None") () (EApp (EVar "evIndexOf") (EListLit)))))
(DTypeSig true "installedEvidenceSlots" (TyFun (TyCon "Unit") (TyCon "Int")))
(DFunDef false "installedEvidenceSlots" (PWild) (EMatch (EUnOp "!" (EVar "evidenceRef")) (arm (PCon "None") () (ELit (LInt 0))) (arm (PCon "Some" (PCon "EvIndex" PWild (PVar "arr"))) () (EApp (EVar "arrayLength") (EVar "arr")))))
(DTypeSig true "remapEvidence" (TyFun (TyFun (TyCon "EvEntry") (TyCon "EvEntry")) (TyCon "Unit")))
(DFunDef false "remapEvidence" ((PVar "f")) (EMatch (EUnOp "!" (EVar "evidenceRef")) (arm (PCon "None") () (ELit LUnit)) (arm (PCon "Some" (PCon "EvIndex" PWild (PVar "arr"))) () (EApp (EApp (EApp (EApp (EVar "remapEvidenceGo") (EVar "f")) (EVar "arr")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "arr"))))))
(DTypeSig false "remapEvidenceGo" (TyFun (TyFun (TyCon "EvEntry") (TyCon "EvEntry")) (TyFun (TyApp (TyCon "Array") (TyApp (TyCon "Option") (TyCon "EvEntry"))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Unit"))))))
(DFunDef false "remapEvidenceGo" ((PVar "f") (PVar "arr") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (ELit LUnit) (EIf (EVar "otherwise") (EBlock (DoLet false false PWild (EMatch (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (arm (PCon "None") () (ELit LUnit)) (arm (PCon "Some" (PVar "e")) () (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "i")) (EApp (EVar "Some") (EApp (EVar "f") (EVar "e")))) (EVar "arr"))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "remapEvidenceGo") (EVar "f")) (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "installedEvidenceEntries" (TyFun (TyCon "Unit") (TyApp (TyCon "List") (TyCon "EvEntry"))))
(DFunDef false "installedEvidenceEntries" (PWild) (EMatch (EUnOp "!" (EVar "evidenceRef")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PCon "EvIndex" PWild (PVar "arr"))) () (EApp (EApp (EApp (EVar "evidenceEntriesFrom") (EVar "arr")) (EBinOp "-" (EApp (EVar "arrayLength") (EVar "arr")) (ELit (LInt 1)))) (EListLit)))))
(DTypeSig true "withEvidencePreserved" (TyFun (TyFun (TyCon "Unit") (TyEffect () (Some "e") (TyVar "a"))) (TyEffect () (Some "e") (TyVar "a"))))
(DFunDef false "withEvidencePreserved" ((PVar "action")) (EBlock (DoLet false false (PVar "before") (EApp (EVar "installedEvidenceEntries") (ELit LUnit))) (DoLet false false (PVar "binders") (EApp (EVar "installedBinderTable") (ELit LUnit))) (DoLet false false (PVar "result") (EApp (EVar "action") (ELit LUnit))) (DoLet false false PWild (EApp (EVar "installEvidence") (EVar "before"))) (DoLet false false PWild (EApp (EVar "restoreBinderTable") (EVar "binders"))) (DoExpr (EVar "result"))))
(DTypeSig false "evidenceEntriesFrom" (TyFun (TyApp (TyCon "Array") (TyApp (TyCon "Option") (TyCon "EvEntry"))) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "EvEntry")) (TyApp (TyCon "List") (TyCon "EvEntry"))))))
(DFunDef false "evidenceEntriesFrom" ((PVar "arr") (PVar "i") (PVar "acc")) (EIf (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EVar "acc") (EMatch (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (arm (PCon "None") () (EApp (EApp (EApp (EVar "evidenceEntriesFrom") (EVar "arr")) (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "acc"))) (arm (PCon "Some" (PVar "e")) () (EApp (EApp (EApp (EVar "evidenceEntriesFrom") (EVar "arr")) (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EBinOp "::" (EVar "e") (EVar "acc")))))))
(DTypeSig false "evSlotCount" (TyFun (TyCon "EvTable") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "evSlotCount" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "evSlotCount" ((PCons (PCon "EvEntry" (PCon "EvId" PWild (PVar "i")) PWild) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "evSlotCount") (EVar "rest")) (EApp (EApp (EVar "max") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "acc"))))
(DTypeSig false "evMinOrdinal" (TyFun (TyCon "EvTable") (TyCon "Int")))
(DFunDef false "evMinOrdinal" ((PList)) (ELit (LInt 0)))
(DFunDef false "evMinOrdinal" ((PCons (PCon "EvEntry" (PCon "EvId" PWild (PVar "i")) PWild) (PVar "rest"))) (EApp (EApp (EVar "evMinFrom") (EVar "rest")) (EVar "i")))
(DTypeSig false "evMinFrom" (TyFun (TyCon "EvTable") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "evMinFrom" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "evMinFrom" ((PCons (PCon "EvEntry" (PCon "EvId" PWild (PVar "i")) PWild) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "evMinFrom") (EVar "rest")) (EApp (EApp (EVar "min") (EVar "i")) (EVar "acc"))))
(DTypeSig false "fillEvidence" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyApp (TyCon "Option") (TyCon "EvEntry"))) (TyFun (TyCon "EvTable") (TyCon "Unit")))))
(DFunDef false "fillEvidence" (PWild PWild (PList)) (ELit LUnit))
(DFunDef false "fillEvidence" ((PVar "lo") (PVar "arr") (PCons (PAs "e" (PCon "EvEntry" (PCon "EvId" (PVar "m") (PVar "i")) PWild)) (PVar "rest"))) (EBlock (DoLet false false PWild (EMatch (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EVar "i") (EVar "lo"))) (EVar "arr")) (arm (PCon "None") () (EApp (EApp (EApp (EVar "arraySetUnsafe") (EBinOp "-" (EVar "i") (EVar "lo"))) (EApp (EVar "Some") (EVar "e"))) (EVar "arr"))) (arm (PCon "Some" PWild) () (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "evidence table: two goals published under ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString "#"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ""))))))) (DoExpr (EApp (EApp (EApp (EVar "fillEvidence") (EVar "lo")) (EVar "arr")) (EVar "rest")))))
(DTypeSig false "neverPublished" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyVar "a"))))))
(DFunDef false "neverPublished" ((PVar "what") (PVar "m") (PVar "i")) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "evidence table: ")) (EApp (EVar "display") (EVar "what"))) (ELit (LString " "))) (EApp (EVar "display") (EVar "m"))) (ELit (LString "#"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString " was never published")))))
(DTypeSig false "installedAnswer" (TyFun (TyCon "String") (TyFun (TyCon "EvId") (TyCon "EvVal"))))
(DFunDef false "installedAnswer" ((PVar "what") (PVar "ev")) (EMatch (EApp (EApp (EVar "installedLookup") (EVar "what")) (EVar "ev")) (arm (PCon "Ok" (PVar "v")) () (EVar "v")) (arm (PCon "Err" (PVar "message")) () (EApp (EVar "panic") (EVar "message")))))
(DTypeSig false "answerIn" (TyFun (TyCon "EvIndex") (TyFun (TyCon "String") (TyFun (TyCon "EvId") (TyCon "EvVal")))))
(DFunDef false "answerIn" ((PVar "idx") (PVar "what") (PVar "ev")) (EMatch (EApp (EApp (EApp (EVar "evidenceLookup") (EApp (EVar "Some") (EVar "idx"))) (EVar "what")) (EVar "ev")) (arm (PCon "Ok" (PVar "v")) () (EVar "v")) (arm (PCon "Err" (PVar "message")) () (EApp (EVar "panic") (EVar "message")))))
(DTypeSig true "installedLookup" (TyFun (TyCon "String") (TyFun (TyCon "EvId") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "EvVal")))))
(DFunDef false "installedLookup" ((PVar "what") (PVar "ev")) (EApp (EApp (EApp (EVar "evidenceLookup") (EUnOp "!" (EVar "evidenceRef"))) (EVar "what")) (EVar "ev")))
(DTypeSig true "evidenceLookup" (TyFun (TyApp (TyCon "Option") (TyCon "EvIndex")) (TyFun (TyCon "String") (TyFun (TyCon "EvId") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "EvVal"))))))
(DFunDef false "evidenceLookup" ((PCon "None") (PVar "what") (PCon "EvId" (PVar "m") (PVar "i"))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "evidence table: no elaboration has published one (looking up ")) (EApp (EVar "display") (EVar "what"))) (ELit (LString " "))) (EApp (EVar "display") (EVar "m"))) (ELit (LString "#"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ")")))))
(DFunDef false "evidenceLookup" ((PCon "Some" (PCon "EvIndex" (PVar "lo") (PVar "arr"))) (PVar "what") (PCon "EvId" (PVar "m") (PVar "i"))) (EIf (EBinOp "<" (EVar "i") (EVar "lo")) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "evidence table: ")) (EApp (EVar "display") (EVar "what"))) (ELit (LString " "))) (EApp (EVar "display") (EVar "m"))) (ELit (LString "#"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString " is from an earlier graph")))) (EIf (EBinOp ">=" (EBinOp "-" (EVar "i") (EVar "lo")) (EApp (EVar "arrayLength") (EVar "arr"))) (EApp (EApp (EApp (EVar "neverPublished") (EVar "what")) (EVar "m")) (EVar "i")) (EMatch (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EVar "i") (EVar "lo"))) (EVar "arr")) (arm (PCon "None") () (EApp (EApp (EApp (EVar "neverPublished") (EVar "what")) (EVar "m")) (EVar "i"))) (arm (PCon "Some" (PCon "EvEntry" (PCon "EvId" (PVar "m2") PWild) (PVar "v"))) () (EIf (EBinOp "==" (EVar "m2") (EVar "m")) (EApp (EVar "Ok") (EVar "v")) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "evidence table: ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString "#"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString " answered by module "))) (EApp (EVar "display") (EVar "m2"))) (ELit (LString ""))))))))))
(DTypeSig true "evDictRoutes" (TyFun (TyCon "EvId") (TyApp (TyCon "List") (TyCon "Route"))))
(DFunDef false "evDictRoutes" ((PVar "ev")) (EApp (EVar "evRoutesOf") (EApp (EApp (EVar "installedAnswer") (ELit (LString "dictionary application"))) (EVar "ev"))))
(DTypeSig true "evDictRoutesIn" (TyFun (TyCon "EvIndex") (TyFun (TyCon "EvId") (TyApp (TyCon "List") (TyCon "Route")))))
(DFunDef false "evDictRoutesIn" ((PVar "idx") (PVar "ev")) (EApp (EVar "evRoutesOf") (EApp (EApp (EApp (EVar "answerIn") (EVar "idx")) (ELit (LString "dictionary application"))) (EVar "ev"))))
(DTypeSig false "evRoutesOf" (TyFun (TyCon "EvVal") (TyApp (TyCon "List") (TyCon "Route"))))
(DFunDef false "evRoutesOf" ((PCon "EvMany" (PVar "rs"))) (EVar "rs"))
(DFunDef false "evRoutesOf" ((PCon "EvOne" PWild)) (EApp (EVar "panic") (ELit (LString "evidence table: a dictionary application solved to a single route"))))
(DFunDef false "evRoutesOf" ((PCon "EvMethod" PWild PWild PWild PWild PWild)) (EApp (EVar "panic") (ELit (LString "evidence table: a dictionary application answered by a method occurrence"))))
(DFunDef false "evRoutesOf" ((PCon "EvLit" PWild PWild)) (EApp (EVar "panic") (ELit (LString "evidence table: a dictionary application answered by a literal site"))))
(DFunDef false "evRoutesOf" ((PCon "EvHead" PWild)) (EApp (EVar "panic") (ELit (LString "evidence table: a dictionary application answered by a record-head site"))))
(DTypeSig true "evSiteRoute" (TyFun (TyCon "EvId") (TyCon "Route")))
(DFunDef false "evSiteRoute" ((PVar "ev")) (EMatch (EApp (EVar "evSiteRouteResult") (EVar "ev")) (arm (PCon "Ok" (PVar "r")) () (EVar "r")) (arm (PCon "Err" (PVar "message")) () (EApp (EVar "panic") (EVar "message")))))
(DTypeSig true "evSiteRouteIn" (TyFun (TyCon "EvIndex") (TyFun (TyCon "EvId") (TyCon "Route"))))
(DFunDef false "evSiteRouteIn" ((PVar "idx") (PVar "ev")) (EMatch (EApp (EApp (EVar "siteRouteResultIn") (EApp (EVar "Some") (EVar "idx"))) (EVar "ev")) (arm (PCon "Ok" (PVar "r")) () (EVar "r")) (arm (PCon "Err" (PVar "message")) () (EApp (EVar "panic") (EVar "message")))))
(DTypeSig true "evSiteRouteResult" (TyFun (TyCon "EvId") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Route"))))
(DFunDef false "evSiteRouteResult" ((PVar "ev")) (EApp (EApp (EVar "siteRouteResultIn") (EUnOp "!" (EVar "evidenceRef"))) (EVar "ev")))
(DTypeSig false "siteRouteResultIn" (TyFun (TyApp (TyCon "Option") (TyCon "EvIndex")) (TyFun (TyCon "EvId") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Route")))))
(DFunDef false "siteRouteResultIn" ((PVar "table") (PVar "ev")) (EIf (EApp (EVar "isUnminted") (EVar "ev")) (EApp (EVar "Ok") (EVar "RNone")) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EApp (EVar "evidenceLookup") (EVar "table")) (ELit (LString "operator site"))) (EVar "ev")) (arm (PCon "Ok" (PCon "EvOne" (PVar "r"))) () (EApp (EVar "Ok") (EVar "r"))) (arm (PCon "Ok" PWild) () (EApp (EVar "Err") (ELit (LString "evidence table: an operator site answered by another kind of entry")))) (arm (PCon "Err" (PVar "message")) () (EApp (EVar "Err") (EVar "message")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "evSiteLit" (TyFun (TyCon "EvId") (TyTuple (TyApp (TyCon "Option") (TyCon "Float")) (TyCon "Route"))))
(DFunDef false "evSiteLit" ((PVar "ev")) (EMatch (EApp (EVar "evSiteLitResult") (EVar "ev")) (arm (PCon "Ok" (PVar "answer")) () (EVar "answer")) (arm (PCon "Err" (PVar "message")) () (EApp (EVar "panic") (EVar "message")))))
(DTypeSig true "evSiteLitIn" (TyFun (TyCon "EvIndex") (TyFun (TyCon "EvId") (TyTuple (TyApp (TyCon "Option") (TyCon "Float")) (TyCon "Route")))))
(DFunDef false "evSiteLitIn" ((PVar "idx") (PVar "ev")) (EMatch (EApp (EApp (EVar "siteLitResultIn") (EApp (EVar "Some") (EVar "idx"))) (EVar "ev")) (arm (PCon "Ok" (PVar "answer")) () (EVar "answer")) (arm (PCon "Err" (PVar "message")) () (EApp (EVar "panic") (EVar "message")))))
(DTypeSig true "evSiteLitResult" (TyFun (TyCon "EvId") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyApp (TyCon "Option") (TyCon "Float")) (TyCon "Route")))))
(DFunDef false "evSiteLitResult" ((PVar "ev")) (EApp (EApp (EVar "siteLitResultIn") (EUnOp "!" (EVar "evidenceRef"))) (EVar "ev")))
(DTypeSig false "siteLitResultIn" (TyFun (TyApp (TyCon "Option") (TyCon "EvIndex")) (TyFun (TyCon "EvId") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyApp (TyCon "Option") (TyCon "Float")) (TyCon "Route"))))))
(DFunDef false "siteLitResultIn" ((PVar "table") (PVar "ev")) (EIf (EApp (EVar "isUnminted") (EVar "ev")) (EApp (EVar "Ok") (ETuple (EVar "None") (EVar "RNone"))) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EApp (EVar "evidenceLookup") (EVar "table")) (ELit (LString "literal site"))) (EVar "ev")) (arm (PCon "Ok" (PCon "EvLit" (PVar "f") (PVar "r"))) () (EApp (EVar "Ok") (ETuple (EVar "f") (EVar "r")))) (arm (PCon "Ok" PWild) () (EApp (EVar "Err") (ELit (LString "evidence table: a literal site answered by another kind of entry")))) (arm (PCon "Err" (PVar "message")) () (EApp (EVar "Err") (EVar "message")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "evSiteHead" (TyFun (TyCon "EvId") (TyCon "String")))
(DFunDef false "evSiteHead" ((PVar "ev")) (EMatch (EApp (EVar "evSiteHeadResult") (EVar "ev")) (arm (PCon "Ok" (PVar "head")) () (EVar "head")) (arm (PCon "Err" (PVar "message")) () (EApp (EVar "panic") (EVar "message")))))
(DTypeSig true "evSiteHeadIn" (TyFun (TyCon "EvIndex") (TyFun (TyCon "EvId") (TyCon "String"))))
(DFunDef false "evSiteHeadIn" ((PVar "idx") (PVar "ev")) (EMatch (EApp (EApp (EVar "siteHeadResultIn") (EApp (EVar "Some") (EVar "idx"))) (EVar "ev")) (arm (PCon "Ok" (PVar "head")) () (EVar "head")) (arm (PCon "Err" (PVar "message")) () (EApp (EVar "panic") (EVar "message")))))
(DTypeSig true "evSiteHeadResult" (TyFun (TyCon "EvId") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String"))))
(DFunDef false "evSiteHeadResult" ((PVar "ev")) (EApp (EApp (EVar "siteHeadResultIn") (EUnOp "!" (EVar "evidenceRef"))) (EVar "ev")))
(DTypeSig false "siteHeadResultIn" (TyFun (TyApp (TyCon "Option") (TyCon "EvIndex")) (TyFun (TyCon "EvId") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String")))))
(DFunDef false "siteHeadResultIn" ((PVar "table") (PVar "ev")) (EIf (EApp (EVar "isUnminted") (EVar "ev")) (EApp (EVar "Ok") (ELit (LString ""))) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EApp (EVar "evidenceLookup") (EVar "table")) (ELit (LString "record-head site"))) (EVar "ev")) (arm (PCon "Ok" (PCon "EvHead" (PVar "h"))) () (EApp (EVar "Ok") (EVar "h"))) (arm (PCon "Ok" PWild) () (EApp (EVar "Err") (ELit (LString "evidence table: a record-head site answered by another kind of entry")))) (arm (PCon "Err" (PVar "message")) () (EApp (EVar "Err") (EVar "message")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "evMethodRoutes" (TyFun (TyCon "EvId") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Route") (TyApp (TyCon "List") (TyCon "Route")) (TyApp (TyCon "List") (TyCon "Route")))))
(DFunDef false "evMethodRoutes" ((PVar "ev")) (EApp (EVar "evMethodOf") (EApp (EApp (EVar "installedAnswer") (ELit (LString "method occurrence"))) (EVar "ev"))))
(DTypeSig true "evMethodRoutesIn" (TyFun (TyCon "EvIndex") (TyFun (TyCon "EvId") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Route") (TyApp (TyCon "List") (TyCon "Route")) (TyApp (TyCon "List") (TyCon "Route"))))))
(DFunDef false "evMethodRoutesIn" ((PVar "idx") (PVar "ev")) (EApp (EVar "evMethodOf") (EApp (EApp (EApp (EVar "answerIn") (EVar "idx")) (ELit (LString "method occurrence"))) (EVar "ev"))))
(DTypeSig false "evMethodOf" (TyFun (TyCon "EvVal") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Route") (TyApp (TyCon "List") (TyCon "Route")) (TyApp (TyCon "List") (TyCon "Route")))))
(DFunDef false "evMethodOf" ((PCon "EvMethod" (PVar "iface") (PVar "arity") (PVar "r") (PVar "impls") (PVar "meths"))) (ETuple (EVar "iface") (EVar "arity") (EVar "r") (EVar "impls") (EVar "meths")))
(DFunDef false "evMethodOf" (PWild) (EApp (EVar "panic") (ELit (LString "evidence table: a method occurrence answered by a dictionary application"))))
(DTypeSig true "ifaceWordOf" (TyFun (TyCon "TyConOrigin") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "ifaceWordOf" ((PVar "o") (PVar "name")) (EMatch (EApp (EApp (EVar "ifaceIdentity") (EVar "o")) (EVar "name")) (arm (PLit (LString "")) () (EVar "name")) (arm (PVar "ident") () (EVar "ident"))))
(DTypeSig true "funHeadTag" (TyCon "String"))
(DFunDef false "funHeadTag" () (ELit (LString "__fun__")))
(DTypeSig true "implRouteKeyWord" (TyFun (TyCon "TyConOrigin") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyCon "String"))))))
(DFunDef false "implRouteKeyWord" ((PVar "o") (PVar "iface") (PVar "tys") (PVar "nm")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EApp (EVar "ifaceWordOf") (EVar "o")) (EVar "iface")))) (ELit (LString "|"))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EVar "map") (EVar "rkTyAtom")) (EVar "tys"))))) (ELit (LString "|"))) (EApp (EVar "display") (EApp (EApp (EVar "optionOr") (ELit (LString ""))) (EVar "nm")))) (ELit (LString ""))))
(DTypeSig true "numIntWord" (TyCon "String"))
(DFunDef false "numIntWord" () (ELit (LString "core::Num|Int|")))
(DTypeSig true "numFloatWord" (TyCon "String"))
(DFunDef false "numFloatWord" () (ELit (LString "core::Num|Float|")))
(DTypeSig true "typeTagOf" (TyFun (TyCon "TyConOrigin") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "typeTagOf" ((PCon "OriginModule" (PLit (LString "core"))) (PVar "name")) (EVar "name"))
(DFunDef false "typeTagOf" ((PCon "OriginModule" (PVar "m")) (PVar "name")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "m"))) (ELit (LString "."))) (EApp (EVar "display") (EVar "name"))) (ELit (LString ""))))
(DFunDef false "typeTagOf" (PWild (PVar "name")) (EVar "name"))
(DTypeSig true "typeTagName" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "typeTagName" ((PVar "tag")) (EApp (EApp (EVar "afterLastDot") (EVar "tag")) (EBinOp "-" (EApp (EVar "stringLength") (EVar "tag")) (ELit (LInt 1)))))
(DTypeSig false "afterLastDot" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "afterLastDot" ((PVar "tag") (PVar "i")) (EIf (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EVar "tag") (EIf (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EVar "i")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "tag")) (ELit (LString "."))) (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "stringLength") (EVar "tag"))) (EVar "tag")) (EIf (EVar "otherwise") (EApp (EApp (EVar "afterLastDot") (EVar "tag")) (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "rkTy" (TyFun (TyCon "Ty") (TyCon "String")))
(DFunDef false "rkTy" ((PRec "TyCon" ((rf "tyConName" (PVar "n")) (rf "tyConOrigin" (PVar "o"))) false)) (EApp (EApp (EVar "typeTagOf") (EVar "o")) (EVar "n")))
(DFunDef false "rkTy" ((PCon "TyVar" (PVar "n"))) (EVar "n"))
(DFunDef false "rkTy" ((PCon "TyApp" (PVar "a") (PVar "b"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "rkTy") (EVar "a")))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EVar "rkTyAtom") (EVar "b")))) (ELit (LString ""))))
(DFunDef false "rkTy" ((PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "rkTyFunArg") (EVar "a")))) (ELit (LString " -> "))) (EApp (EVar "display") (EApp (EVar "rkTy") (EVar "b")))) (ELit (LString ""))))
(DFunDef false "rkTy" ((PCon "TyTuple" (PVar "ts"))) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "map") (EVar "rkTy")) (EVar "ts")))) (ELit (LString ")"))))
(DFunDef false "rkTy" ((PCon "TyEffect" (PVar "effs") (PVar "tail") (PVar "t"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "<")) (EApp (EVar "display") (EApp (EApp (EVar "rkRowBody") (EVar "effs")) (EVar "tail")))) (ELit (LString "> "))) (EApp (EVar "display") (EApp (EVar "rkTy") (EVar "t")))) (ELit (LString ""))))
(DFunDef false "rkTy" ((PCon "TyRow" (PVar "effs") (PVar "tail") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "<")) (EApp (EVar "display") (EApp (EApp (EVar "rkRowBody") (EVar "effs")) (EVar "tail")))) (ELit (LString ">"))))
(DFunDef false "rkTy" ((PCon "TyAuth" (PVar "ps") PWild)) (EApp (EApp (EVar "authTermsSurface") (EVar "escStr")) (EVar "ps")))
(DFunDef false "rkTy" ((PCon "TyConstrained" (PVar "cs") (PVar "t"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "rkConstraints") (EVar "cs")))) (ELit (LString " => "))) (EApp (EVar "display") (EApp (EVar "rkTy") (EVar "t")))) (ELit (LString ""))))
(DFunDef false "rkTy" ((PCon "TyNamed" PWild (PVar "t") PWild)) (EApp (EVar "rkTy") (EVar "t")))
(DFunDef false "rkTy" ((PCon "TyQual" (PVar "t") (PVar "ns") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "rkTyAtom") (EVar "t")))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EApp (EVar "qualifierSource") (EVar "escStr")) (EVar "ns")))) (ELit (LString ""))))
(DTypeSig false "rkTyFunArg" (TyFun (TyCon "Ty") (TyCon "String")))
(DFunDef false "rkTyFunArg" ((PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EVar "rkTy") (EApp (EApp (EVar "TyFun") (EVar "a")) (EVar "b")))) (ELit (LString ")"))))
(DFunDef false "rkTyFunArg" ((PVar "t")) (EApp (EVar "rkTy") (EVar "t")))
(DTypeSig false "rkTyAtom" (TyFun (TyCon "Ty") (TyCon "String")))
(DFunDef false "rkTyAtom" ((PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EVar "rkTy") (EApp (EApp (EVar "TyFun") (EVar "a")) (EVar "b")))) (ELit (LString ")"))))
(DFunDef false "rkTyAtom" ((PCon "TyApp" (PVar "a") (PVar "b"))) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EVar "rkTy") (EApp (EApp (EVar "TyApp") (EVar "a")) (EVar "b")))) (ELit (LString ")"))))
(DFunDef false "rkTyAtom" ((PVar "t")) (EApp (EVar "rkTy") (EVar "t")))
(DTypeSig false "rkRowBody" (TyFun (TyApp (TyCon "List") (TyCon "EffAtomTy")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))
(DFunDef false "rkRowBody" ((PVar "effs") (PList)) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "map") (EVar "rkEffAtom")) (EVar "effs"))))
(DFunDef false "rkRowBody" ((PList) (PVar "tails")) (EApp (EApp (EVar "joinWith") (ELit (LString " | "))) (EVar "tails")))
(DFunDef false "rkRowBody" ((PVar "effs") (PVar "tails")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "map") (EVar "rkEffAtom")) (EVar "effs"))))) (ELit (LString " | "))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString " | "))) (EVar "tails")))) (ELit (LString ""))))
(DTypeSig false "rkEffAtom" (TyFun (TyCon "EffAtomTy") (TyCon "String")))
(DFunDef false "rkEffAtom" ((PVar "a")) (EApp (EApp (EVar "effAtomSurface") (EVar "escStr")) (EVar "a")))
(DTypeSig false "rkConstraints" (TyFun (TyApp (TyCon "List") (TyCon "Constraint")) (TyCon "String")))
(DFunDef false "rkConstraints" ((PList (PVar "c"))) (EApp (EVar "rkConstraint") (EVar "c")))
(DFunDef false "rkConstraints" ((PVar "cs")) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "map") (EVar "rkConstraint")) (EVar "cs")))) (ELit (LString ")"))))
(DTypeSig false "rkConstraint" (TyFun (TyCon "Constraint") (TyCon "String")))
(DFunDef false "rkConstraint" ((PRec "Constraint" ((rf "constraintHead" (PVar "iface")) (rf "constraintArgs" (PList))) false)) (EVar "iface"))
(DFunDef false "rkConstraint" ((PRec "Constraint" ((rf "constraintHead" (PVar "iface")) (rf "constraintArgs" (PVar "tys"))) false)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "iface"))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EVar "map") (EVar "rkTyAtom")) (EVar "tys"))))) (ELit (LString ""))))
(DTypeSig false "rkTyInt" (TyCon "Ty"))
(DFunDef false "rkTyInt" () (ERecordCreate "TyCon" ((fa "tyConName" (ELit (LString "Int"))) (fa "tyConLoc" (EVar "None")) (fa "tyConOrigin" (EVar "OriginUnresolved")))))
(DTypeSig false "rkTyBool" (TyCon "Ty"))
(DFunDef false "rkTyBool" () (ERecordCreate "TyCon" ((fa "tyConName" (ELit (LString "Bool"))) (fa "tyConLoc" (EVar "None")) (fa "tyConOrigin" (EVar "OriginUnresolved")))))
(DTypeSig false "rkTyFloat" (TyCon "Ty"))
(DFunDef false "rkTyFloat" () (EApp (EApp (EVar "tyConBuiltin") (ELit (LString "Float"))) (EVar "None")))
(DTypeSig false "rkTyIntM" (TyCon "Ty"))
(DFunDef false "rkTyIntM" () (ERecordCreate "TyCon" ((fa "tyConName" (ELit (LString "Int"))) (fa "tyConLoc" (EVar "None")) (fa "tyConOrigin" (EApp (EVar "OriginModule") (ELit (LString "m")))))))
(DTypeSig false "rkTyList" (TyCon "Ty"))
(DFunDef false "rkTyList" () (ERecordCreate "TyCon" ((fa "tyConName" (ELit (LString "List"))) (fa "tyConLoc" (EVar "None")) (fa "tyConOrigin" (EVar "OriginUnresolved")))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Ty" true) (mem "Constraint" true) (mem "TyConOrigin" true) (mem "EffAtomTy" true) (mem "qualifierSource" false) (mem "EffParamTy" true) (mem "effAtomSurface" false) (mem "authTermSurface" false) (mem "effAtomBare" false) (mem "effAtomWith" false) (mem "Route" true) (mem "EvId" true) (mem "isUnminted" false) (mem "EvVal" true) (mem "EvEntry" true) (mem "EvTable" false) (mem "constraintUnresolved" false) (mem "tyConBuiltin" false) (mem "ifaceIdentity" false) (mem "authTermsSurface" false))))
(DUse false (UseGroup ("support" "util") ((mem "joinWith" false) (mem "escStr" false))))
(DUse false (UseGroup ("types" "runtime_types") ((mem "installedBinderTable" false) (mem "restoreBinderTable" false))))
(DTypeSig false "evidenceRef" (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "EvIndex"))))
(DFunDef false "evidenceRef" () (EApp (EVar "Ref") (EVar "None")))
(DData Public "EvIndex" () ((variant "EvIndex" (ConPos (TyCon "Int") (TyApp (TyCon "Array") (TyApp (TyCon "Option") (TyCon "EvEntry")))))) ())
(DTypeSig true "evIndexOf" (TyFun (TyCon "EvTable") (TyCon "EvIndex")))
(DFunDef false "evIndexOf" ((PVar "entries")) (EBlock (DoLet false false (PVar "lo") (EApp (EVar "evMinOrdinal") (EVar "entries"))) (DoLet false false (PVar "arr") (EApp (EApp (EVar "arrayMake") (EBinOp "-" (EApp (EApp (EVar "evSlotCount") (EVar "entries")) (EVar "lo")) (EVar "lo"))) (EVar "None"))) (DoLet false false PWild (EApp (EApp (EApp (EVar "fillEvidence") (EVar "lo")) (EVar "arr")) (EVar "entries"))) (DoExpr (EApp (EApp (EVar "EvIndex") (EVar "lo")) (EVar "arr")))))
(DTypeSig true "installEvidence" (TyFun (TyCon "EvTable") (TyCon "Unit")))
(DFunDef false "installEvidence" ((PVar "entries")) (EApp (EApp (EVar "setRef") (EVar "evidenceRef")) (EApp (EVar "Some") (EApp (EVar "evIndexOf") (EVar "entries")))))
(DTypeSig true "installedEvidenceIndex" (TyFun (TyCon "Unit") (TyCon "EvIndex")))
(DFunDef false "installedEvidenceIndex" (PWild) (EMatch (EUnOp "!" (EVar "evidenceRef")) (arm (PCon "Some" (PVar "idx")) () (EVar "idx")) (arm (PCon "None") () (EApp (EVar "evIndexOf") (EListLit)))))
(DTypeSig true "installedEvidenceSlots" (TyFun (TyCon "Unit") (TyCon "Int")))
(DFunDef false "installedEvidenceSlots" (PWild) (EMatch (EUnOp "!" (EVar "evidenceRef")) (arm (PCon "None") () (ELit (LInt 0))) (arm (PCon "Some" (PCon "EvIndex" PWild (PVar "arr"))) () (EApp (EVar "arrayLength") (EVar "arr")))))
(DTypeSig true "remapEvidence" (TyFun (TyFun (TyCon "EvEntry") (TyCon "EvEntry")) (TyCon "Unit")))
(DFunDef false "remapEvidence" ((PVar "f")) (EMatch (EUnOp "!" (EVar "evidenceRef")) (arm (PCon "None") () (ELit LUnit)) (arm (PCon "Some" (PCon "EvIndex" PWild (PVar "arr"))) () (EApp (EApp (EApp (EApp (EVar "remapEvidenceGo") (EVar "f")) (EVar "arr")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "arr"))))))
(DTypeSig false "remapEvidenceGo" (TyFun (TyFun (TyCon "EvEntry") (TyCon "EvEntry")) (TyFun (TyApp (TyCon "Array") (TyApp (TyCon "Option") (TyCon "EvEntry"))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Unit"))))))
(DFunDef false "remapEvidenceGo" ((PVar "f") (PVar "arr") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (ELit LUnit) (EIf (EVar "otherwise") (EBlock (DoLet false false PWild (EMatch (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (arm (PCon "None") () (ELit LUnit)) (arm (PCon "Some" (PVar "e")) () (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "i")) (EApp (EVar "Some") (EApp (EVar "f") (EVar "e")))) (EVar "arr"))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "remapEvidenceGo") (EVar "f")) (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "installedEvidenceEntries" (TyFun (TyCon "Unit") (TyApp (TyCon "List") (TyCon "EvEntry"))))
(DFunDef false "installedEvidenceEntries" (PWild) (EMatch (EUnOp "!" (EVar "evidenceRef")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PCon "EvIndex" PWild (PVar "arr"))) () (EApp (EApp (EApp (EVar "evidenceEntriesFrom") (EVar "arr")) (EBinOp "-" (EApp (EVar "arrayLength") (EVar "arr")) (ELit (LInt 1)))) (EListLit)))))
(DTypeSig true "withEvidencePreserved" (TyFun (TyFun (TyCon "Unit") (TyEffect () (Some "e") (TyVar "a"))) (TyEffect () (Some "e") (TyVar "a"))))
(DFunDef false "withEvidencePreserved" ((PVar "action")) (EBlock (DoLet false false (PVar "before") (EApp (EVar "installedEvidenceEntries") (ELit LUnit))) (DoLet false false (PVar "binders") (EApp (EVar "installedBinderTable") (ELit LUnit))) (DoLet false false (PVar "result") (EApp (EVar "action") (ELit LUnit))) (DoLet false false PWild (EApp (EVar "installEvidence") (EVar "before"))) (DoLet false false PWild (EApp (EVar "restoreBinderTable") (EVar "binders"))) (DoExpr (EVar "result"))))
(DTypeSig false "evidenceEntriesFrom" (TyFun (TyApp (TyCon "Array") (TyApp (TyCon "Option") (TyCon "EvEntry"))) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "EvEntry")) (TyApp (TyCon "List") (TyCon "EvEntry"))))))
(DFunDef false "evidenceEntriesFrom" ((PVar "arr") (PVar "i") (PVar "acc")) (EIf (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EVar "acc") (EMatch (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (arm (PCon "None") () (EApp (EApp (EApp (EVar "evidenceEntriesFrom") (EVar "arr")) (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "acc"))) (arm (PCon "Some" (PVar "e")) () (EApp (EApp (EApp (EVar "evidenceEntriesFrom") (EVar "arr")) (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EBinOp "::" (EVar "e") (EVar "acc")))))))
(DTypeSig false "evSlotCount" (TyFun (TyCon "EvTable") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "evSlotCount" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "evSlotCount" ((PCons (PCon "EvEntry" (PCon "EvId" PWild (PVar "i")) PWild) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "evSlotCount") (EVar "rest")) (EApp (EApp (EMethodRef "max") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "acc"))))
(DTypeSig false "evMinOrdinal" (TyFun (TyCon "EvTable") (TyCon "Int")))
(DFunDef false "evMinOrdinal" ((PList)) (ELit (LInt 0)))
(DFunDef false "evMinOrdinal" ((PCons (PCon "EvEntry" (PCon "EvId" PWild (PVar "i")) PWild) (PVar "rest"))) (EApp (EApp (EVar "evMinFrom") (EVar "rest")) (EVar "i")))
(DTypeSig false "evMinFrom" (TyFun (TyCon "EvTable") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "evMinFrom" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "evMinFrom" ((PCons (PCon "EvEntry" (PCon "EvId" PWild (PVar "i")) PWild) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "evMinFrom") (EVar "rest")) (EApp (EApp (EMethodRef "min") (EVar "i")) (EVar "acc"))))
(DTypeSig false "fillEvidence" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyApp (TyCon "Option") (TyCon "EvEntry"))) (TyFun (TyCon "EvTable") (TyCon "Unit")))))
(DFunDef false "fillEvidence" (PWild PWild (PList)) (ELit LUnit))
(DFunDef false "fillEvidence" ((PVar "lo") (PVar "arr") (PCons (PAs "e" (PCon "EvEntry" (PCon "EvId" (PVar "m") (PVar "i")) PWild)) (PVar "rest"))) (EBlock (DoLet false false PWild (EMatch (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EVar "i") (EVar "lo"))) (EVar "arr")) (arm (PCon "None") () (EApp (EApp (EApp (EVar "arraySetUnsafe") (EBinOp "-" (EVar "i") (EVar "lo"))) (EApp (EVar "Some") (EVar "e"))) (EVar "arr"))) (arm (PCon "Some" PWild) () (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "evidence table: two goals published under ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "#"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ""))))))) (DoExpr (EApp (EApp (EApp (EVar "fillEvidence") (EVar "lo")) (EVar "arr")) (EVar "rest")))))
(DTypeSig false "neverPublished" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyVar "a"))))))
(DFunDef false "neverPublished" ((PVar "what") (PVar "m") (PVar "i")) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "evidence table: ")) (EApp (EMethodRef "display") (EVar "what"))) (ELit (LString " "))) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "#"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString " was never published")))))
(DTypeSig false "installedAnswer" (TyFun (TyCon "String") (TyFun (TyCon "EvId") (TyCon "EvVal"))))
(DFunDef false "installedAnswer" ((PVar "what") (PVar "ev")) (EMatch (EApp (EApp (EVar "installedLookup") (EVar "what")) (EVar "ev")) (arm (PCon "Ok" (PVar "v")) () (EVar "v")) (arm (PCon "Err" (PVar "message")) () (EApp (EVar "panic") (EVar "message")))))
(DTypeSig false "answerIn" (TyFun (TyCon "EvIndex") (TyFun (TyCon "String") (TyFun (TyCon "EvId") (TyCon "EvVal")))))
(DFunDef false "answerIn" ((PVar "idx") (PVar "what") (PVar "ev")) (EMatch (EApp (EApp (EApp (EVar "evidenceLookup") (EApp (EVar "Some") (EVar "idx"))) (EVar "what")) (EVar "ev")) (arm (PCon "Ok" (PVar "v")) () (EVar "v")) (arm (PCon "Err" (PVar "message")) () (EApp (EVar "panic") (EVar "message")))))
(DTypeSig true "installedLookup" (TyFun (TyCon "String") (TyFun (TyCon "EvId") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "EvVal")))))
(DFunDef false "installedLookup" ((PVar "what") (PVar "ev")) (EApp (EApp (EApp (EVar "evidenceLookup") (EUnOp "!" (EVar "evidenceRef"))) (EVar "what")) (EVar "ev")))
(DTypeSig true "evidenceLookup" (TyFun (TyApp (TyCon "Option") (TyCon "EvIndex")) (TyFun (TyCon "String") (TyFun (TyCon "EvId") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "EvVal"))))))
(DFunDef false "evidenceLookup" ((PCon "None") (PVar "what") (PCon "EvId" (PVar "m") (PVar "i"))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "evidence table: no elaboration has published one (looking up ")) (EApp (EMethodRef "display") (EVar "what"))) (ELit (LString " "))) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "#"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ")")))))
(DFunDef false "evidenceLookup" ((PCon "Some" (PCon "EvIndex" (PVar "lo") (PVar "arr"))) (PVar "what") (PCon "EvId" (PVar "m") (PVar "i"))) (EIf (EBinOp "<" (EVar "i") (EVar "lo")) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "evidence table: ")) (EApp (EMethodRef "display") (EVar "what"))) (ELit (LString " "))) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "#"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString " is from an earlier graph")))) (EIf (EBinOp ">=" (EBinOp "-" (EVar "i") (EVar "lo")) (EApp (EVar "arrayLength") (EVar "arr"))) (EApp (EApp (EApp (EVar "neverPublished") (EVar "what")) (EVar "m")) (EVar "i")) (EMatch (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EVar "i") (EVar "lo"))) (EVar "arr")) (arm (PCon "None") () (EApp (EApp (EApp (EVar "neverPublished") (EVar "what")) (EVar "m")) (EVar "i"))) (arm (PCon "Some" (PCon "EvEntry" (PCon "EvId" (PVar "m2") PWild) (PVar "v"))) () (EIf (EBinOp "==" (EVar "m2") (EVar "m")) (EApp (EVar "Ok") (EVar "v")) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "evidence table: ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "#"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString " answered by module "))) (EApp (EMethodRef "display") (EVar "m2"))) (ELit (LString ""))))))))))
(DTypeSig true "evDictRoutes" (TyFun (TyCon "EvId") (TyApp (TyCon "List") (TyCon "Route"))))
(DFunDef false "evDictRoutes" ((PVar "ev")) (EApp (EVar "evRoutesOf") (EApp (EApp (EVar "installedAnswer") (ELit (LString "dictionary application"))) (EVar "ev"))))
(DTypeSig true "evDictRoutesIn" (TyFun (TyCon "EvIndex") (TyFun (TyCon "EvId") (TyApp (TyCon "List") (TyCon "Route")))))
(DFunDef false "evDictRoutesIn" ((PVar "idx") (PVar "ev")) (EApp (EVar "evRoutesOf") (EApp (EApp (EApp (EVar "answerIn") (EVar "idx")) (ELit (LString "dictionary application"))) (EVar "ev"))))
(DTypeSig false "evRoutesOf" (TyFun (TyCon "EvVal") (TyApp (TyCon "List") (TyCon "Route"))))
(DFunDef false "evRoutesOf" ((PCon "EvMany" (PVar "rs"))) (EVar "rs"))
(DFunDef false "evRoutesOf" ((PCon "EvOne" PWild)) (EApp (EVar "panic") (ELit (LString "evidence table: a dictionary application solved to a single route"))))
(DFunDef false "evRoutesOf" ((PCon "EvMethod" PWild PWild PWild PWild PWild)) (EApp (EVar "panic") (ELit (LString "evidence table: a dictionary application answered by a method occurrence"))))
(DFunDef false "evRoutesOf" ((PCon "EvLit" PWild PWild)) (EApp (EVar "panic") (ELit (LString "evidence table: a dictionary application answered by a literal site"))))
(DFunDef false "evRoutesOf" ((PCon "EvHead" PWild)) (EApp (EVar "panic") (ELit (LString "evidence table: a dictionary application answered by a record-head site"))))
(DTypeSig true "evSiteRoute" (TyFun (TyCon "EvId") (TyCon "Route")))
(DFunDef false "evSiteRoute" ((PVar "ev")) (EMatch (EApp (EVar "evSiteRouteResult") (EVar "ev")) (arm (PCon "Ok" (PVar "r")) () (EVar "r")) (arm (PCon "Err" (PVar "message")) () (EApp (EVar "panic") (EVar "message")))))
(DTypeSig true "evSiteRouteIn" (TyFun (TyCon "EvIndex") (TyFun (TyCon "EvId") (TyCon "Route"))))
(DFunDef false "evSiteRouteIn" ((PVar "idx") (PVar "ev")) (EMatch (EApp (EApp (EVar "siteRouteResultIn") (EApp (EVar "Some") (EVar "idx"))) (EVar "ev")) (arm (PCon "Ok" (PVar "r")) () (EVar "r")) (arm (PCon "Err" (PVar "message")) () (EApp (EVar "panic") (EVar "message")))))
(DTypeSig true "evSiteRouteResult" (TyFun (TyCon "EvId") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Route"))))
(DFunDef false "evSiteRouteResult" ((PVar "ev")) (EApp (EApp (EVar "siteRouteResultIn") (EUnOp "!" (EVar "evidenceRef"))) (EVar "ev")))
(DTypeSig false "siteRouteResultIn" (TyFun (TyApp (TyCon "Option") (TyCon "EvIndex")) (TyFun (TyCon "EvId") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Route")))))
(DFunDef false "siteRouteResultIn" ((PVar "table") (PVar "ev")) (EIf (EApp (EVar "isUnminted") (EVar "ev")) (EApp (EVar "Ok") (EVar "RNone")) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EApp (EVar "evidenceLookup") (EVar "table")) (ELit (LString "operator site"))) (EVar "ev")) (arm (PCon "Ok" (PCon "EvOne" (PVar "r"))) () (EApp (EVar "Ok") (EVar "r"))) (arm (PCon "Ok" PWild) () (EApp (EVar "Err") (ELit (LString "evidence table: an operator site answered by another kind of entry")))) (arm (PCon "Err" (PVar "message")) () (EApp (EVar "Err") (EVar "message")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "evSiteLit" (TyFun (TyCon "EvId") (TyTuple (TyApp (TyCon "Option") (TyCon "Float")) (TyCon "Route"))))
(DFunDef false "evSiteLit" ((PVar "ev")) (EMatch (EApp (EVar "evSiteLitResult") (EVar "ev")) (arm (PCon "Ok" (PVar "answer")) () (EVar "answer")) (arm (PCon "Err" (PVar "message")) () (EApp (EVar "panic") (EVar "message")))))
(DTypeSig true "evSiteLitIn" (TyFun (TyCon "EvIndex") (TyFun (TyCon "EvId") (TyTuple (TyApp (TyCon "Option") (TyCon "Float")) (TyCon "Route")))))
(DFunDef false "evSiteLitIn" ((PVar "idx") (PVar "ev")) (EMatch (EApp (EApp (EVar "siteLitResultIn") (EApp (EVar "Some") (EVar "idx"))) (EVar "ev")) (arm (PCon "Ok" (PVar "answer")) () (EVar "answer")) (arm (PCon "Err" (PVar "message")) () (EApp (EVar "panic") (EVar "message")))))
(DTypeSig true "evSiteLitResult" (TyFun (TyCon "EvId") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyApp (TyCon "Option") (TyCon "Float")) (TyCon "Route")))))
(DFunDef false "evSiteLitResult" ((PVar "ev")) (EApp (EApp (EVar "siteLitResultIn") (EUnOp "!" (EVar "evidenceRef"))) (EVar "ev")))
(DTypeSig false "siteLitResultIn" (TyFun (TyApp (TyCon "Option") (TyCon "EvIndex")) (TyFun (TyCon "EvId") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyApp (TyCon "Option") (TyCon "Float")) (TyCon "Route"))))))
(DFunDef false "siteLitResultIn" ((PVar "table") (PVar "ev")) (EIf (EApp (EVar "isUnminted") (EVar "ev")) (EApp (EVar "Ok") (ETuple (EVar "None") (EVar "RNone"))) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EApp (EVar "evidenceLookup") (EVar "table")) (ELit (LString "literal site"))) (EVar "ev")) (arm (PCon "Ok" (PCon "EvLit" (PVar "f") (PVar "r"))) () (EApp (EVar "Ok") (ETuple (EVar "f") (EVar "r")))) (arm (PCon "Ok" PWild) () (EApp (EVar "Err") (ELit (LString "evidence table: a literal site answered by another kind of entry")))) (arm (PCon "Err" (PVar "message")) () (EApp (EVar "Err") (EVar "message")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "evSiteHead" (TyFun (TyCon "EvId") (TyCon "String")))
(DFunDef false "evSiteHead" ((PVar "ev")) (EMatch (EApp (EVar "evSiteHeadResult") (EVar "ev")) (arm (PCon "Ok" (PVar "head")) () (EVar "head")) (arm (PCon "Err" (PVar "message")) () (EApp (EVar "panic") (EVar "message")))))
(DTypeSig true "evSiteHeadIn" (TyFun (TyCon "EvIndex") (TyFun (TyCon "EvId") (TyCon "String"))))
(DFunDef false "evSiteHeadIn" ((PVar "idx") (PVar "ev")) (EMatch (EApp (EApp (EVar "siteHeadResultIn") (EApp (EVar "Some") (EVar "idx"))) (EVar "ev")) (arm (PCon "Ok" (PVar "head")) () (EVar "head")) (arm (PCon "Err" (PVar "message")) () (EApp (EVar "panic") (EVar "message")))))
(DTypeSig true "evSiteHeadResult" (TyFun (TyCon "EvId") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String"))))
(DFunDef false "evSiteHeadResult" ((PVar "ev")) (EApp (EApp (EVar "siteHeadResultIn") (EUnOp "!" (EVar "evidenceRef"))) (EVar "ev")))
(DTypeSig false "siteHeadResultIn" (TyFun (TyApp (TyCon "Option") (TyCon "EvIndex")) (TyFun (TyCon "EvId") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String")))))
(DFunDef false "siteHeadResultIn" ((PVar "table") (PVar "ev")) (EIf (EApp (EVar "isUnminted") (EVar "ev")) (EApp (EVar "Ok") (ELit (LString ""))) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EApp (EVar "evidenceLookup") (EVar "table")) (ELit (LString "record-head site"))) (EVar "ev")) (arm (PCon "Ok" (PCon "EvHead" (PVar "h"))) () (EApp (EVar "Ok") (EVar "h"))) (arm (PCon "Ok" PWild) () (EApp (EVar "Err") (ELit (LString "evidence table: a record-head site answered by another kind of entry")))) (arm (PCon "Err" (PVar "message")) () (EApp (EVar "Err") (EVar "message")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "evMethodRoutes" (TyFun (TyCon "EvId") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Route") (TyApp (TyCon "List") (TyCon "Route")) (TyApp (TyCon "List") (TyCon "Route")))))
(DFunDef false "evMethodRoutes" ((PVar "ev")) (EApp (EVar "evMethodOf") (EApp (EApp (EVar "installedAnswer") (ELit (LString "method occurrence"))) (EVar "ev"))))
(DTypeSig true "evMethodRoutesIn" (TyFun (TyCon "EvIndex") (TyFun (TyCon "EvId") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Route") (TyApp (TyCon "List") (TyCon "Route")) (TyApp (TyCon "List") (TyCon "Route"))))))
(DFunDef false "evMethodRoutesIn" ((PVar "idx") (PVar "ev")) (EApp (EVar "evMethodOf") (EApp (EApp (EApp (EVar "answerIn") (EVar "idx")) (ELit (LString "method occurrence"))) (EVar "ev"))))
(DTypeSig false "evMethodOf" (TyFun (TyCon "EvVal") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Route") (TyApp (TyCon "List") (TyCon "Route")) (TyApp (TyCon "List") (TyCon "Route")))))
(DFunDef false "evMethodOf" ((PCon "EvMethod" (PVar "iface") (PVar "arity") (PVar "r") (PVar "impls") (PVar "meths"))) (ETuple (EVar "iface") (EVar "arity") (EVar "r") (EVar "impls") (EVar "meths")))
(DFunDef false "evMethodOf" (PWild) (EApp (EVar "panic") (ELit (LString "evidence table: a method occurrence answered by a dictionary application"))))
(DTypeSig true "ifaceWordOf" (TyFun (TyCon "TyConOrigin") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "ifaceWordOf" ((PVar "o") (PVar "name")) (EMatch (EApp (EApp (EVar "ifaceIdentity") (EVar "o")) (EVar "name")) (arm (PLit (LString "")) () (EVar "name")) (arm (PVar "ident") () (EVar "ident"))))
(DTypeSig true "funHeadTag" (TyCon "String"))
(DFunDef false "funHeadTag" () (ELit (LString "__fun__")))
(DTypeSig true "implRouteKeyWord" (TyFun (TyCon "TyConOrigin") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyCon "String"))))))
(DFunDef false "implRouteKeyWord" ((PVar "o") (PVar "iface") (PVar "tys") (PVar "nm")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EApp (EVar "ifaceWordOf") (EVar "o")) (EVar "iface")))) (ELit (LString "|"))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EMethodRef "map") (EVar "rkTyAtom")) (EVar "tys"))))) (ELit (LString "|"))) (EApp (EMethodRef "display") (EApp (EApp (EVar "optionOr") (ELit (LString ""))) (EVar "nm")))) (ELit (LString ""))))
(DTypeSig true "numIntWord" (TyCon "String"))
(DFunDef false "numIntWord" () (ELit (LString "core::Num|Int|")))
(DTypeSig true "numFloatWord" (TyCon "String"))
(DFunDef false "numFloatWord" () (ELit (LString "core::Num|Float|")))
(DTypeSig true "typeTagOf" (TyFun (TyCon "TyConOrigin") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "typeTagOf" ((PCon "OriginModule" (PLit (LString "core"))) (PVar "name")) (EVar "name"))
(DFunDef false "typeTagOf" ((PCon "OriginModule" (PVar "m")) (PVar "name")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "."))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString ""))))
(DFunDef false "typeTagOf" (PWild (PVar "name")) (EVar "name"))
(DTypeSig true "typeTagName" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "typeTagName" ((PVar "tag")) (EApp (EApp (EVar "afterLastDot") (EVar "tag")) (EBinOp "-" (EApp (EVar "stringLength") (EVar "tag")) (ELit (LInt 1)))))
(DTypeSig false "afterLastDot" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "afterLastDot" ((PVar "tag") (PVar "i")) (EIf (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EVar "tag") (EIf (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EVar "i")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "tag")) (ELit (LString "."))) (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "stringLength") (EVar "tag"))) (EVar "tag")) (EIf (EVar "otherwise") (EApp (EApp (EVar "afterLastDot") (EVar "tag")) (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "rkTy" (TyFun (TyCon "Ty") (TyCon "String")))
(DFunDef false "rkTy" ((PRec "TyCon" ((rf "tyConName" (PVar "n")) (rf "tyConOrigin" (PVar "o"))) false)) (EApp (EApp (EVar "typeTagOf") (EVar "o")) (EVar "n")))
(DFunDef false "rkTy" ((PCon "TyVar" (PVar "n"))) (EVar "n"))
(DFunDef false "rkTy" ((PCon "TyApp" (PVar "a") (PVar "b"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "rkTy") (EVar "a")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EVar "rkTyAtom") (EVar "b")))) (ELit (LString ""))))
(DFunDef false "rkTy" ((PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "rkTyFunArg") (EVar "a")))) (ELit (LString " -> "))) (EApp (EMethodRef "display") (EApp (EVar "rkTy") (EVar "b")))) (ELit (LString ""))))
(DFunDef false "rkTy" ((PCon "TyTuple" (PVar "ts"))) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EMethodRef "map") (EVar "rkTy")) (EVar "ts")))) (ELit (LString ")"))))
(DFunDef false "rkTy" ((PCon "TyEffect" (PVar "effs") (PVar "tail") (PVar "t"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "<")) (EApp (EMethodRef "display") (EApp (EApp (EVar "rkRowBody") (EVar "effs")) (EVar "tail")))) (ELit (LString "> "))) (EApp (EMethodRef "display") (EApp (EVar "rkTy") (EVar "t")))) (ELit (LString ""))))
(DFunDef false "rkTy" ((PCon "TyRow" (PVar "effs") (PVar "tail") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "<")) (EApp (EMethodRef "display") (EApp (EApp (EVar "rkRowBody") (EVar "effs")) (EVar "tail")))) (ELit (LString ">"))))
(DFunDef false "rkTy" ((PCon "TyAuth" (PVar "ps") PWild)) (EApp (EApp (EVar "authTermsSurface") (EVar "escStr")) (EVar "ps")))
(DFunDef false "rkTy" ((PCon "TyConstrained" (PVar "cs") (PVar "t"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "rkConstraints") (EVar "cs")))) (ELit (LString " => "))) (EApp (EMethodRef "display") (EApp (EVar "rkTy") (EVar "t")))) (ELit (LString ""))))
(DFunDef false "rkTy" ((PCon "TyNamed" PWild (PVar "t") PWild)) (EApp (EVar "rkTy") (EVar "t")))
(DFunDef false "rkTy" ((PCon "TyQual" (PVar "t") (PVar "ns") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "rkTyAtom") (EVar "t")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "qualifierSource") (EVar "escStr")) (EVar "ns")))) (ELit (LString ""))))
(DTypeSig false "rkTyFunArg" (TyFun (TyCon "Ty") (TyCon "String")))
(DFunDef false "rkTyFunArg" ((PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EVar "rkTy") (EApp (EApp (EVar "TyFun") (EVar "a")) (EVar "b")))) (ELit (LString ")"))))
(DFunDef false "rkTyFunArg" ((PVar "t")) (EApp (EVar "rkTy") (EVar "t")))
(DTypeSig false "rkTyAtom" (TyFun (TyCon "Ty") (TyCon "String")))
(DFunDef false "rkTyAtom" ((PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EVar "rkTy") (EApp (EApp (EVar "TyFun") (EVar "a")) (EVar "b")))) (ELit (LString ")"))))
(DFunDef false "rkTyAtom" ((PCon "TyApp" (PVar "a") (PVar "b"))) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EVar "rkTy") (EApp (EApp (EVar "TyApp") (EVar "a")) (EVar "b")))) (ELit (LString ")"))))
(DFunDef false "rkTyAtom" ((PVar "t")) (EApp (EVar "rkTy") (EVar "t")))
(DTypeSig false "rkRowBody" (TyFun (TyApp (TyCon "List") (TyCon "EffAtomTy")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))
(DFunDef false "rkRowBody" ((PVar "effs") (PList)) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EMethodRef "map") (EVar "rkEffAtom")) (EVar "effs"))))
(DFunDef false "rkRowBody" ((PList) (PVar "tails")) (EApp (EApp (EVar "joinWith") (ELit (LString " | "))) (EVar "tails")))
(DFunDef false "rkRowBody" ((PVar "effs") (PVar "tails")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EMethodRef "map") (EVar "rkEffAtom")) (EVar "effs"))))) (ELit (LString " | "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString " | "))) (EVar "tails")))) (ELit (LString ""))))
(DTypeSig false "rkEffAtom" (TyFun (TyCon "EffAtomTy") (TyCon "String")))
(DFunDef false "rkEffAtom" ((PVar "a")) (EApp (EApp (EVar "effAtomSurface") (EVar "escStr")) (EVar "a")))
(DTypeSig false "rkConstraints" (TyFun (TyApp (TyCon "List") (TyCon "Constraint")) (TyCon "String")))
(DFunDef false "rkConstraints" ((PList (PVar "c"))) (EApp (EVar "rkConstraint") (EVar "c")))
(DFunDef false "rkConstraints" ((PVar "cs")) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EMethodRef "map") (EVar "rkConstraint")) (EVar "cs")))) (ELit (LString ")"))))
(DTypeSig false "rkConstraint" (TyFun (TyCon "Constraint") (TyCon "String")))
(DFunDef false "rkConstraint" ((PRec "Constraint" ((rf "constraintHead" (PVar "iface")) (rf "constraintArgs" (PList))) false)) (EVar "iface"))
(DFunDef false "rkConstraint" ((PRec "Constraint" ((rf "constraintHead" (PVar "iface")) (rf "constraintArgs" (PVar "tys"))) false)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "iface"))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EMethodRef "map") (EVar "rkTyAtom")) (EVar "tys"))))) (ELit (LString ""))))
(DTypeSig false "rkTyInt" (TyCon "Ty"))
(DFunDef false "rkTyInt" () (ERecordCreate "TyCon" ((fa "tyConName" (ELit (LString "Int"))) (fa "tyConLoc" (EVar "None")) (fa "tyConOrigin" (EVar "OriginUnresolved")))))
(DTypeSig false "rkTyBool" (TyCon "Ty"))
(DFunDef false "rkTyBool" () (ERecordCreate "TyCon" ((fa "tyConName" (ELit (LString "Bool"))) (fa "tyConLoc" (EVar "None")) (fa "tyConOrigin" (EVar "OriginUnresolved")))))
(DTypeSig false "rkTyFloat" (TyCon "Ty"))
(DFunDef false "rkTyFloat" () (EApp (EApp (EVar "tyConBuiltin") (ELit (LString "Float"))) (EVar "None")))
(DTypeSig false "rkTyIntM" (TyCon "Ty"))
(DFunDef false "rkTyIntM" () (ERecordCreate "TyCon" ((fa "tyConName" (ELit (LString "Int"))) (fa "tyConLoc" (EVar "None")) (fa "tyConOrigin" (EApp (EVar "OriginModule") (ELit (LString "m")))))))
(DTypeSig false "rkTyList" (TyCon "Ty"))
(DFunDef false "rkTyList" () (ERecordCreate "TyCon" ((fa "tyConName" (ELit (LString "List"))) (fa "tyConLoc" (EVar "None")) (fa "tyConOrigin" (EVar "OriginUnresolved")))))
