# META
source_lines=825
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
import support.util.{joinWith, escStr, reverseL}
import array.{sort}

-- ── the evidence table (#2549 M2) ─────────────────────────────────────────
-- `EDictAt` carries an `EvId`, not a route cell, so a reader answers "what did
-- the solver decide here" by looking the id up in the elaboration's `EvIndex`
-- rather than by dereferencing a pointer the typechecker handed it.  The lookup
-- lives HERE because this module is the one below all three readers of a solved
-- route -- `types/typecheck.mdk` (dict passing), `eval/eval.mdk` and
-- `ir/core_ir_lower.mdk` -- and `frontend/ast.mdk` (the only lower module)
-- imports nothing and holds no state.  No cell holds a drive's index: each reader
-- is handed the one its own elaboration built.  The one cell here holds the
-- prelude's segment, which is the same for every drive of a process.
--
-- A lookup that cannot be answered is an `Err` here, and a panic in the readers:
--
--   no index                 -> Err.  The caller holds `None`: no elaboration ran.
--   ordinal below every run  -> Err: the id is from an earlier graph.
--   ordinal past its run     -> Err.
--   in-run `None`            -> Err.
--
-- This holds because the typechecker publishes an entry for EVERY `EDictAt` it mints,
-- including an application of zero dictionaries (`EvMany []`, the #739 arm of
-- `inferDictAtFound`), so "no entry" can only mean a missing or stale index.
--
-- What the lookup does NOT catch: an id from another elaboration that lands on an
-- ordinal inside this index's span.  A memo hit rewinds the counter, so two
-- elaborations can publish overlapping spans, and such a read answers with
-- ANOTHER GOAL'S ROUTES -- silently wrong, at exit 0.  The module half of the id,
-- compared on every hit, is the only tripwire for that, and it cannot fire for
-- today's consumer.  Handing each reader its own elaboration's index is the
-- protection.
--
-- The index is an ARRAY over the id's ordinal, not a scan of the spine: the table
-- has one entry per solver goal (838 on a four-file fixture), so a per-site linear
-- scan would be the List-as-a-map quadratic `compiler/AGENTS.md` records thirteen
-- instances of.  Ordinals are graph-global (see `freshEvId`), so an ordinal less the
-- first ordinal of the run holding it IS the slot and carries uniqueness by itself.
-- The id's MODULE half is compared on every hit as a tripwire, not as part of the
-- key -- see `EvId` in `frontend/ast.mdk` for why it cannot fire for today's
-- consumer and must be kept anyway.
--
-- A table's ordinals need not be one run.  A drive that serves a module keeps that
-- module's ordinals as recorded, perhaps many drives ago, and mints its own at or
-- past the lineage's counter, so one array from the smallest to the largest would
-- span every ordinal minted in between.  A table whose span is at most twice its
-- entries is one run; any other is cut wherever two of its ordinals lie more than
-- `runGap` apart, so its slots grow with its entries, not with its span.

-- The table as runs of slots, each the ordinal of its first slot and the slots
-- from it, in ascending order and disjoint.  There is always at least one run.
export data EvIndex = EvIndex (Array EvRun)

data EvRun = EvRun Int (Array (Option EvEntry))

-- The widest gap between two ordinals of one run of a split table.
runGap : Int
runGap = 64

-- The prelude's own segment, once a process holds the prelude's elaborated trees
-- (`types/prelude_elab.mdk`): their rows indexed from ordinal 0 to the prelude's
-- counter, built once.  Every drive of such a process mints its ids at or past
-- that counter, so a table holding the prelude's rows beside a drive's is indexed
-- as the segment plus the drive's own runs.  A run over both would span every
-- ordinal the process has minted, which grows with each drive of a long-lived
-- process.
preludeEvidenceRef : Ref (Option (Array (Option EvEntry)))
preludeEvidenceRef = Ref None

-- Index [rows] as the prelude's segment, below [counter].
export
setPreludeEvidence : Int -> EvTable -> Unit
setPreludeEvidence counter rows =
  let arr = arrayMake counter None
  fillEvidence (EvIndex (arrayFromList [EvRun 0 arr])) rows
  preludeEvidenceRef := Some arr

-- The index of [entries]; two entries under one ordinal panic (`fillEvidence`).
-- An entry below the prelude's counter is the segment's, and panics unless the
-- segment holds it under the same module.
export
evIndexOf : EvTable -> EvIndex
evIndexOf entries = match !preludeEvidenceRef
  None => filledIndexOf entries
  Some seg => filledIndexOf (filter (aboveSegment seg) entries)

-- [entries] less those the prelude's segment answers; all of them with no segment.
-- A reader that judges the table rather than trusting it (`evidenceFaults`) indexes
-- this and lets `evidenceLookup` answer the segment's range.
export
entriesAboveSegment : EvTable -> EvTable
entriesAboveSegment entries = match !preludeEvidenceRef
  None => entries
  Some seg =>
    filter
      (e => match e
        EvEntry (EvId _ i) _ => i >= arrayLength seg)
      entries

filledIndexOf : EvTable -> EvIndex
filledIndexOf entries =
  let index = emptyIndexFor entries
  fillEvidence index entries
  index

-- An index with a slot for every ordinal of [entries]' runs and nothing filled;
-- the caller fills it (`claimSlot`) and decides what a repeated ordinal means.
export
emptyIndexFor : EvTable -> EvIndex
emptyIndexFor entries =
  let lo = evMinOrdinal entries
  let hi = evSlotCount entries lo
  if hi - lo <= 2 * length entries then
    EvIndex (arrayFromList [emptyRun lo hi])
  else
    let ordinals = sort (arrayFromList (map entryOrdinal entries))
    let first = arrayGetUnsafe 0 ordinals
    EvIndex (arrayFromList (runsFrom ordinals 1 first first []))

-- The runs of sorted [ordinals] from position [k] on: the open run from [lo] to
-- [last], after the closed runs [acc], newest first.
runsFrom : Array Int -> Int -> Int -> Int -> List EvRun -> List EvRun
runsFrom ordinals k lo last acc =
  if k >= arrayLength ordinals then
    reverseL (emptyRun lo (last + 1) :: acc)
  else
    let i = arrayGetUnsafe k ordinals
    if i - last > runGap then
      runsFrom ordinals (k + 1) i i (emptyRun lo (last + 1) :: acc)
    else
      runsFrom ordinals (k + 1) lo i acc

-- A run of empty slots for the ordinals from [lo] up to, not including, [hi].
emptyRun : Int -> Int -> EvRun
emptyRun lo hi = EvRun lo (arrayMake (hi - lo) None)

entryOrdinal : EvEntry -> Int
entryOrdinal (EvEntry (EvId _ i) _) = i

-- The position of the last of [runs] starting at or below ordinal [i], searched
-- in positions [a] up to [b]; one less than [a] when none there does.
runAt : Array EvRun -> Int -> Int -> Int -> Int
runAt runs i a b =
  if a >= b then
    a - 1
  else
    let mid = (a + b) / 2
    match arrayGetUnsafe mid runs
      EvRun lo _ =>
        if lo <= i then runAt runs i (mid + 1) b else runAt runs i a mid

-- The run of [idx] holding ordinal [i]'s slot; panics when none does.
runFor : EvIndex -> String -> Int -> EvRun
runFor (EvIndex runs) m i =
  let k = runAt runs i 0 (arrayLength runs)
  if k < 0 then
    noSlot m i
  else match arrayGetUnsafe k runs
    run@(EvRun lo arr) => if i - lo < arrayLength arr then run else noSlot m i

noSlot : String -> Int -> a
noSlot m i =
  panic "evidence table: \{m}#\{intToString i} has no slot in the index"

-- Put [e] in its slot of [idx] when the slot is empty; False when another entry
-- holds it.
export
claimSlot : EvIndex -> EvEntry -> Bool
claimSlot idx (e@(EvEntry (EvId m i) _)) = match runFor idx m i
  EvRun lo arr => match arrayGetUnsafe (i - lo) arr
    None =>
      arraySetUnsafe (i - lo) (Some e) arr
      True
    Some _ => False

-- Put [e] in its slot of [idx], over whatever entry holds it.
export
replaceEntryIn : EvIndex -> EvEntry -> Unit
replaceEntryIn idx (e@(EvEntry (EvId m i) _)) = match runFor idx m i
  EvRun lo arr => arraySetUnsafe (i - lo) (Some e) arr

-- The number of slots [idx] holds, filled or not.
export
evIndexSlotCount : EvIndex -> Int
evIndexSlotCount (EvIndex runs) = slotsFrom runs 0 0

slotsFrom : Array EvRun -> Int -> Int -> Int
slotsFrom runs k acc =
  if k >= arrayLength runs then
    acc
  else match arrayGetUnsafe k runs
    EvRun _ arr => slotsFrom runs (k + 1) (acc + arrayLength arr)

-- The entries [idx] holds, in ordinal order.
export
evIndexEntries : EvIndex -> List EvEntry
evIndexEntries (EvIndex runs) = runEntries runs (arrayLength runs - 1) []

-- The entries of [runs] up to position [k], before [acc].
runEntries : Array EvRun -> Int -> List EvEntry -> List EvEntry
runEntries runs k acc =
  if k < 0 then
    acc
  else match arrayGetUnsafe k runs
    EvRun _ arr =>
      runEntries runs (k - 1) (slotEntries arr (arrayLength arr - 1) acc)

-- The entries of [slots] up to position [k], before [acc].
slotEntries : Array (Option EvEntry) -> Int -> List EvEntry -> List EvEntry
slotEntries slots k acc =
  if k < 0 then
    acc
  else match arrayGetUnsafe k slots
    Some e => slotEntries slots (k - 1) (e :: acc)
    None => slotEntries slots (k - 1) acc

aboveSegment : Array (Option EvEntry) -> EvEntry -> Bool
aboveSegment seg (EvEntry (EvId m i) _)
  | i >= arrayLength seg = True
  | otherwise = match arrayGetUnsafe i seg
    Some (EvEntry (EvId m2 _) _) if m2 == m => False
    _ =>
      panic
        "evidence table: \{m}#\{intToString i} is below the prelude's counter but not the prelude's"

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
fillEvidence : EvIndex -> EvTable -> Unit
fillEvidence _ [] = ()
fillEvidence idx ((e@(EvEntry (EvId m i) _)) :: rest) =
  if claimSlot idx e then
    fillEvidence idx rest
  else
    panic "evidence table: two goals published under \{m}#\{intToString i}"

neverPublished : String -> String -> Int -> Result String a
neverPublished what m i =
  Err "evidence table: \{what} \{m}#\{intToString i} was never published"

answerIn : EvIndex -> String -> EvId -> EvVal
answerIn idx what ev = match evidenceLookup (Some idx) what ev
  Ok v => v
  Err message => panic message

-- The lookup over [table], the shape a reader holds: `None` when no
-- elaboration has published one, else the index's runs.  An ordinal in a gap
-- between two runs is past the earlier run's slots.
export
evidenceLookup : Option EvIndex -> String -> EvId -> Result String EvVal
evidenceLookup None what (EvId m i) =
  Err
    "evidence table: no elaboration has published one (looking up \{what} \{m}#\{intToString i})"
evidenceLookup (Some (EvIndex runs)) what (EvId m i) = match !preludeEvidenceRef
  Some seg if i >= 0 && i < arrayLength seg => slotAnswer seg what m i i
  _ =>
    let k = runAt runs i 0 (arrayLength runs)
    if k < 0 then
      Err
        "evidence table: \{what} \{m}#\{intToString i} is from an earlier graph"
    else match arrayGetUnsafe k runs
      EvRun lo arr => slotAnswer arr what m i (i - lo)

slotAnswer : Array (Option EvEntry) ->
  String ->
  String ->
  Int ->
  Int ->
  Result String EvVal
slotAnswer arr what m i slot =
  if slot >= arrayLength arr then
    neverPublished what m i
  else match arrayGetUnsafe slot arr
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
-- with no entry therefore means the index is not the one this node's
-- elaboration published, and it panics, as `evMethodRoutesIn` does.
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
-- builtin operator.  Every other miss panics, as `evDictRoutesIn` does.
export
evSiteRouteIn : EvIndex -> EvId -> Route
evSiteRouteIn idx ev = match siteRouteResultIn idx ev
  Ok r => r
  Err message => panic message

siteRouteResultIn : EvIndex -> EvId -> Result String Route
siteRouteResultIn idx ev
  | isUnminted ev = Ok RNone
  | otherwise = match evidenceLookup (Some idx) "operator site" ev
    Ok (EvOne r) => Ok r
    Ok _ =>
      Err "evidence table: an operator site answered by another kind of entry"
    Err message => Err message

-- The defaulted float and `fromInt` route solved for numeric literal site [ev].
-- A literal built after inference carries `unminted` and answers `(None, RNone)`,
-- a plain `Int`.  Every other miss panics.
export
evSiteLitIn : EvIndex -> EvId -> (Option Float, Route)
evSiteLitIn idx ev = match siteLitResultIn idx ev
  Ok answer => answer
  Err message => panic message

siteLitResultIn : EvIndex -> EvId -> Result String (Option Float, Route)
siteLitResultIn idx ev
  | isUnminted ev = Ok (None, RNone)
  | otherwise = match evidenceLookup (Some idx) "literal site" ev
    Ok (EvLit f r) => Ok (f, r)
    Ok _ =>
      Err "evidence table: a literal site answered by another kind of entry"
    Err message => Err message

-- The resolved record head published for field access or record update site [ev],
-- "" when inference never resolved one.  A site built after inference carries
-- `unminted` and answers "".  Every other miss panics.
export
evSiteHeadIn : EvIndex -> EvId -> String
evSiteHeadIn idx ev = match siteHeadResultIn idx ev
  Ok head => head
  Err message => panic message

siteHeadResultIn : EvIndex -> EvId -> Result String String
siteHeadResultIn idx ev
  | isUnminted ev = Ok ""
  | otherwise = match evidenceLookup (Some idx) "record-head site" ev
    Ok (EvHead h) => Ok h
    Ok _ =>
      Err "evidence table: a record-head site answered by another kind of entry"
    Err message => Err message

-- The answer published for a method occurrence: the interface identity it resolved
-- to, its selected denotation's pre-use arrow arity, dispatch route, selected impl's
-- `requires` dicts and the method's own `=>` dicts.  The arity is fixed from the selected scheme before application can
-- specialize its result.
--
-- As with `evDictRoutesIn`, a miss here is LOUD on every arm.  The typechecker mints
-- one entry per `EMethodAt` node at the moment it constructs the node and
-- publishes every one of them, so an id with no entry can only mean the index
-- held is not the one this node's elaboration published, surfaced instead of
-- answered with an unrouted dispatch.
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
-- (`tc_mono.headTyconTy`/`headTyconMono`, `dispatch_keys.headTycon`, and through the
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
(DUse false (UseGroup ("frontend" "ast") ((mem "Ty" true) (mem "Constraint" true) (mem "TyConOrigin" true) (mem "EffAtomTy" true) (mem "qualifierSource" false) (mem "EffParamTy" true) (mem "effAtomSurface" false) (mem "effAtomBare" false) (mem "effAtomWith" false) (mem "Route" true) (mem "EvId" true) (mem "isUnminted" false) (mem "EvVal" true) (mem "EvEntry" true) (mem "EvTable" false) (mem "constraintUnresolved" false) (mem "tyConBuiltin" false) (mem "ifaceIdentity" false) (mem "authTermsSurface" false))))
(DUse false (UseGroup ("support" "util") ((mem "joinWith" false) (mem "escStr" false) (mem "reverseL" false))))
(DUse false (UseGroup ("array") ((mem "sort" false))))
(DData Abstract "EvIndex" () ((variant "EvIndex" (ConPos (TyApp (TyCon "Array") (TyCon "EvRun"))))) ())
(DData Private "EvRun" () ((variant "EvRun" (ConPos (TyCon "Int") (TyApp (TyCon "Array") (TyApp (TyCon "Option") (TyCon "EvEntry")))))) ())
(DTypeSig false "runGap" (TyCon "Int"))
(DFunDef false "runGap" () (ELit (LInt 64)))
(DTypeSig false "preludeEvidenceRef" (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyApp (TyCon "Array") (TyApp (TyCon "Option") (TyCon "EvEntry"))))))
(DFunDef false "preludeEvidenceRef" () (EApp (EVar "Ref") (EVar "None")))
(DTypeSig true "setPreludeEvidence" (TyFun (TyCon "Int") (TyFun (TyCon "EvTable") (TyCon "Unit"))))
(DFunDef false "setPreludeEvidence" ((PVar "counter") (PVar "rows")) (EBlock (DoLet false false (PVar "arr") (EApp (EApp (EVar "arrayMake") (EVar "counter")) (EVar "None"))) (DoExpr (EApp (EApp (EVar "fillEvidence") (EApp (EVar "EvIndex") (EApp (EVar "arrayFromList") (EListLit (EApp (EApp (EVar "EvRun") (ELit (LInt 0))) (EVar "arr")))))) (EVar "rows"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "preludeEvidenceRef")) (EApp (EVar "Some") (EVar "arr"))))))
(DTypeSig true "evIndexOf" (TyFun (TyCon "EvTable") (TyCon "EvIndex")))
(DFunDef false "evIndexOf" ((PVar "entries")) (EMatch (EUnOp "!" (EVar "preludeEvidenceRef")) (arm (PCon "None") () (EApp (EVar "filledIndexOf") (EVar "entries"))) (arm (PCon "Some" (PVar "seg")) () (EApp (EVar "filledIndexOf") (EApp (EApp (EVar "filter") (EApp (EVar "aboveSegment") (EVar "seg"))) (EVar "entries"))))))
(DTypeSig true "entriesAboveSegment" (TyFun (TyCon "EvTable") (TyCon "EvTable")))
(DFunDef false "entriesAboveSegment" ((PVar "entries")) (EMatch (EUnOp "!" (EVar "preludeEvidenceRef")) (arm (PCon "None") () (EVar "entries")) (arm (PCon "Some" (PVar "seg")) () (EApp (EApp (EVar "filter") (ELam ((PVar "e")) (EMatch (EVar "e") (arm (PCon "EvEntry" (PCon "EvId" PWild (PVar "i")) PWild) () (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "seg"))))))) (EVar "entries")))))
(DTypeSig false "filledIndexOf" (TyFun (TyCon "EvTable") (TyCon "EvIndex")))
(DFunDef false "filledIndexOf" ((PVar "entries")) (EBlock (DoLet false false (PVar "index") (EApp (EVar "emptyIndexFor") (EVar "entries"))) (DoExpr (EApp (EApp (EVar "fillEvidence") (EVar "index")) (EVar "entries"))) (DoExpr (EVar "index"))))
(DTypeSig true "emptyIndexFor" (TyFun (TyCon "EvTable") (TyCon "EvIndex")))
(DFunDef false "emptyIndexFor" ((PVar "entries")) (EBlock (DoLet false false (PVar "lo") (EApp (EVar "evMinOrdinal") (EVar "entries"))) (DoLet false false (PVar "hi") (EApp (EApp (EVar "evSlotCount") (EVar "entries")) (EVar "lo"))) (DoExpr (EIf (EBinOp "<=" (EBinOp "-" (EVar "hi") (EVar "lo")) (EBinOp "*" (ELit (LInt 2)) (EApp (EVar "length") (EVar "entries")))) (EApp (EVar "EvIndex") (EApp (EVar "arrayFromList") (EListLit (EApp (EApp (EVar "emptyRun") (EVar "lo")) (EVar "hi"))))) (EBlock (DoLet false false (PVar "ordinals") (EApp (EVar "sort") (EApp (EVar "arrayFromList") (EApp (EApp (EVar "map") (EVar "entryOrdinal")) (EVar "entries"))))) (DoLet false false (PVar "first") (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 0))) (EVar "ordinals"))) (DoExpr (EApp (EVar "EvIndex") (EApp (EVar "arrayFromList") (EApp (EApp (EApp (EApp (EApp (EVar "runsFrom") (EVar "ordinals")) (ELit (LInt 1))) (EVar "first")) (EVar "first")) (EListLit))))))))))
(DTypeSig false "runsFrom" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "EvRun")) (TyApp (TyCon "List") (TyCon "EvRun"))))))))
(DFunDef false "runsFrom" ((PVar "ordinals") (PVar "k") (PVar "lo") (PVar "last") (PVar "acc")) (EIf (EBinOp ">=" (EVar "k") (EApp (EVar "arrayLength") (EVar "ordinals"))) (EApp (EVar "reverseL") (EBinOp "::" (EApp (EApp (EVar "emptyRun") (EVar "lo")) (EBinOp "+" (EVar "last") (ELit (LInt 1)))) (EVar "acc"))) (EBlock (DoLet false false (PVar "i") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "k")) (EVar "ordinals"))) (DoExpr (EIf (EBinOp ">" (EBinOp "-" (EVar "i") (EVar "last")) (EVar "runGap")) (EApp (EApp (EApp (EApp (EApp (EVar "runsFrom") (EVar "ordinals")) (EBinOp "+" (EVar "k") (ELit (LInt 1)))) (EVar "i")) (EVar "i")) (EBinOp "::" (EApp (EApp (EVar "emptyRun") (EVar "lo")) (EBinOp "+" (EVar "last") (ELit (LInt 1)))) (EVar "acc"))) (EApp (EApp (EApp (EApp (EApp (EVar "runsFrom") (EVar "ordinals")) (EBinOp "+" (EVar "k") (ELit (LInt 1)))) (EVar "lo")) (EVar "i")) (EVar "acc")))))))
(DTypeSig false "emptyRun" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "EvRun"))))
(DFunDef false "emptyRun" ((PVar "lo") (PVar "hi")) (EApp (EApp (EVar "EvRun") (EVar "lo")) (EApp (EApp (EVar "arrayMake") (EBinOp "-" (EVar "hi") (EVar "lo"))) (EVar "None"))))
(DTypeSig false "entryOrdinal" (TyFun (TyCon "EvEntry") (TyCon "Int")))
(DFunDef false "entryOrdinal" ((PCon "EvEntry" (PCon "EvId" PWild (PVar "i")) PWild)) (EVar "i"))
(DTypeSig false "runAt" (TyFun (TyApp (TyCon "Array") (TyCon "EvRun")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "runAt" ((PVar "runs") (PVar "i") (PVar "a") (PVar "b")) (EIf (EBinOp ">=" (EVar "a") (EVar "b")) (EBinOp "-" (EVar "a") (ELit (LInt 1))) (EBlock (DoLet false false (PVar "mid") (EBinOp "/" (EBinOp "+" (EVar "a") (EVar "b")) (ELit (LInt 2)))) (DoExpr (EMatch (EApp (EApp (EVar "arrayGetUnsafe") (EVar "mid")) (EVar "runs")) (arm (PCon "EvRun" (PVar "lo") PWild) () (EIf (EBinOp "<=" (EVar "lo") (EVar "i")) (EApp (EApp (EApp (EApp (EVar "runAt") (EVar "runs")) (EVar "i")) (EBinOp "+" (EVar "mid") (ELit (LInt 1)))) (EVar "b")) (EApp (EApp (EApp (EApp (EVar "runAt") (EVar "runs")) (EVar "i")) (EVar "a")) (EVar "mid")))))))))
(DTypeSig false "runFor" (TyFun (TyCon "EvIndex") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "EvRun")))))
(DFunDef false "runFor" ((PCon "EvIndex" (PVar "runs")) (PVar "m") (PVar "i")) (EBlock (DoLet false false (PVar "k") (EApp (EApp (EApp (EApp (EVar "runAt") (EVar "runs")) (EVar "i")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "runs")))) (DoExpr (EIf (EBinOp "<" (EVar "k") (ELit (LInt 0))) (EApp (EApp (EVar "noSlot") (EVar "m")) (EVar "i")) (EMatch (EApp (EApp (EVar "arrayGetUnsafe") (EVar "k")) (EVar "runs")) (arm (PAs "run" (PCon "EvRun" (PVar "lo") (PVar "arr"))) () (EIf (EBinOp "<" (EBinOp "-" (EVar "i") (EVar "lo")) (EApp (EVar "arrayLength") (EVar "arr"))) (EVar "run") (EApp (EApp (EVar "noSlot") (EVar "m")) (EVar "i")))))))))
(DTypeSig false "noSlot" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyVar "a"))))
(DFunDef false "noSlot" ((PVar "m") (PVar "i")) (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "evidence table: ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString "#"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString " has no slot in the index")))))
(DTypeSig true "claimSlot" (TyFun (TyCon "EvIndex") (TyFun (TyCon "EvEntry") (TyCon "Bool"))))
(DFunDef false "claimSlot" ((PVar "idx") (PAs "e" (PCon "EvEntry" (PCon "EvId" (PVar "m") (PVar "i")) PWild))) (EMatch (EApp (EApp (EApp (EVar "runFor") (EVar "idx")) (EVar "m")) (EVar "i")) (arm (PCon "EvRun" (PVar "lo") (PVar "arr")) () (EMatch (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EVar "i") (EVar "lo"))) (EVar "arr")) (arm (PCon "None") () (EBlock (DoExpr (EApp (EApp (EApp (EVar "arraySetUnsafe") (EBinOp "-" (EVar "i") (EVar "lo"))) (EApp (EVar "Some") (EVar "e"))) (EVar "arr"))) (DoExpr (EVar "True")))) (arm (PCon "Some" PWild) () (EVar "False"))))))
(DTypeSig true "replaceEntryIn" (TyFun (TyCon "EvIndex") (TyFun (TyCon "EvEntry") (TyCon "Unit"))))
(DFunDef false "replaceEntryIn" ((PVar "idx") (PAs "e" (PCon "EvEntry" (PCon "EvId" (PVar "m") (PVar "i")) PWild))) (EMatch (EApp (EApp (EApp (EVar "runFor") (EVar "idx")) (EVar "m")) (EVar "i")) (arm (PCon "EvRun" (PVar "lo") (PVar "arr")) () (EApp (EApp (EApp (EVar "arraySetUnsafe") (EBinOp "-" (EVar "i") (EVar "lo"))) (EApp (EVar "Some") (EVar "e"))) (EVar "arr")))))
(DTypeSig true "evIndexSlotCount" (TyFun (TyCon "EvIndex") (TyCon "Int")))
(DFunDef false "evIndexSlotCount" ((PCon "EvIndex" (PVar "runs"))) (EApp (EApp (EApp (EVar "slotsFrom") (EVar "runs")) (ELit (LInt 0))) (ELit (LInt 0))))
(DTypeSig false "slotsFrom" (TyFun (TyApp (TyCon "Array") (TyCon "EvRun")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "slotsFrom" ((PVar "runs") (PVar "k") (PVar "acc")) (EIf (EBinOp ">=" (EVar "k") (EApp (EVar "arrayLength") (EVar "runs"))) (EVar "acc") (EMatch (EApp (EApp (EVar "arrayGetUnsafe") (EVar "k")) (EVar "runs")) (arm (PCon "EvRun" PWild (PVar "arr")) () (EApp (EApp (EApp (EVar "slotsFrom") (EVar "runs")) (EBinOp "+" (EVar "k") (ELit (LInt 1)))) (EBinOp "+" (EVar "acc") (EApp (EVar "arrayLength") (EVar "arr"))))))))
(DTypeSig true "evIndexEntries" (TyFun (TyCon "EvIndex") (TyApp (TyCon "List") (TyCon "EvEntry"))))
(DFunDef false "evIndexEntries" ((PCon "EvIndex" (PVar "runs"))) (EApp (EApp (EApp (EVar "runEntries") (EVar "runs")) (EBinOp "-" (EApp (EVar "arrayLength") (EVar "runs")) (ELit (LInt 1)))) (EListLit)))
(DTypeSig false "runEntries" (TyFun (TyApp (TyCon "Array") (TyCon "EvRun")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "EvEntry")) (TyApp (TyCon "List") (TyCon "EvEntry"))))))
(DFunDef false "runEntries" ((PVar "runs") (PVar "k") (PVar "acc")) (EIf (EBinOp "<" (EVar "k") (ELit (LInt 0))) (EVar "acc") (EMatch (EApp (EApp (EVar "arrayGetUnsafe") (EVar "k")) (EVar "runs")) (arm (PCon "EvRun" PWild (PVar "arr")) () (EApp (EApp (EApp (EVar "runEntries") (EVar "runs")) (EBinOp "-" (EVar "k") (ELit (LInt 1)))) (EApp (EApp (EApp (EVar "slotEntries") (EVar "arr")) (EBinOp "-" (EApp (EVar "arrayLength") (EVar "arr")) (ELit (LInt 1)))) (EVar "acc")))))))
(DTypeSig false "slotEntries" (TyFun (TyApp (TyCon "Array") (TyApp (TyCon "Option") (TyCon "EvEntry"))) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "EvEntry")) (TyApp (TyCon "List") (TyCon "EvEntry"))))))
(DFunDef false "slotEntries" ((PVar "slots") (PVar "k") (PVar "acc")) (EIf (EBinOp "<" (EVar "k") (ELit (LInt 0))) (EVar "acc") (EMatch (EApp (EApp (EVar "arrayGetUnsafe") (EVar "k")) (EVar "slots")) (arm (PCon "Some" (PVar "e")) () (EApp (EApp (EApp (EVar "slotEntries") (EVar "slots")) (EBinOp "-" (EVar "k") (ELit (LInt 1)))) (EBinOp "::" (EVar "e") (EVar "acc")))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "slotEntries") (EVar "slots")) (EBinOp "-" (EVar "k") (ELit (LInt 1)))) (EVar "acc"))))))
(DTypeSig false "aboveSegment" (TyFun (TyApp (TyCon "Array") (TyApp (TyCon "Option") (TyCon "EvEntry"))) (TyFun (TyCon "EvEntry") (TyCon "Bool"))))
(DFunDef false "aboveSegment" ((PVar "seg") (PCon "EvEntry" (PCon "EvId" (PVar "m") (PVar "i")) PWild)) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "seg"))) (EVar "True") (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "seg")) (arm (PCon "Some" (PCon "EvEntry" (PCon "EvId" (PVar "m2") PWild) PWild)) ((GBool (EBinOp "==" (EVar "m2") (EVar "m")))) (EVar "False")) (arm PWild () (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "evidence table: ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString "#"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString " is below the prelude's counter but not the prelude's")))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "evSlotCount" (TyFun (TyCon "EvTable") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "evSlotCount" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "evSlotCount" ((PCons (PCon "EvEntry" (PCon "EvId" PWild (PVar "i")) PWild) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "evSlotCount") (EVar "rest")) (EApp (EApp (EVar "max") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "acc"))))
(DTypeSig false "evMinOrdinal" (TyFun (TyCon "EvTable") (TyCon "Int")))
(DFunDef false "evMinOrdinal" ((PList)) (ELit (LInt 0)))
(DFunDef false "evMinOrdinal" ((PCons (PCon "EvEntry" (PCon "EvId" PWild (PVar "i")) PWild) (PVar "rest"))) (EApp (EApp (EVar "evMinFrom") (EVar "rest")) (EVar "i")))
(DTypeSig false "evMinFrom" (TyFun (TyCon "EvTable") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "evMinFrom" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "evMinFrom" ((PCons (PCon "EvEntry" (PCon "EvId" PWild (PVar "i")) PWild) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "evMinFrom") (EVar "rest")) (EApp (EApp (EVar "min") (EVar "i")) (EVar "acc"))))
(DTypeSig false "fillEvidence" (TyFun (TyCon "EvIndex") (TyFun (TyCon "EvTable") (TyCon "Unit"))))
(DFunDef false "fillEvidence" (PWild (PList)) (ELit LUnit))
(DFunDef false "fillEvidence" ((PVar "idx") (PCons (PAs "e" (PCon "EvEntry" (PCon "EvId" (PVar "m") (PVar "i")) PWild)) (PVar "rest"))) (EIf (EApp (EApp (EVar "claimSlot") (EVar "idx")) (EVar "e")) (EApp (EApp (EVar "fillEvidence") (EVar "idx")) (EVar "rest")) (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "evidence table: two goals published under ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString "#"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ""))))))
(DTypeSig false "neverPublished" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyVar "a"))))))
(DFunDef false "neverPublished" ((PVar "what") (PVar "m") (PVar "i")) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "evidence table: ")) (EApp (EVar "display") (EVar "what"))) (ELit (LString " "))) (EApp (EVar "display") (EVar "m"))) (ELit (LString "#"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString " was never published")))))
(DTypeSig false "answerIn" (TyFun (TyCon "EvIndex") (TyFun (TyCon "String") (TyFun (TyCon "EvId") (TyCon "EvVal")))))
(DFunDef false "answerIn" ((PVar "idx") (PVar "what") (PVar "ev")) (EMatch (EApp (EApp (EApp (EVar "evidenceLookup") (EApp (EVar "Some") (EVar "idx"))) (EVar "what")) (EVar "ev")) (arm (PCon "Ok" (PVar "v")) () (EVar "v")) (arm (PCon "Err" (PVar "message")) () (EApp (EVar "panic") (EVar "message")))))
(DTypeSig true "evidenceLookup" (TyFun (TyApp (TyCon "Option") (TyCon "EvIndex")) (TyFun (TyCon "String") (TyFun (TyCon "EvId") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "EvVal"))))))
(DFunDef false "evidenceLookup" ((PCon "None") (PVar "what") (PCon "EvId" (PVar "m") (PVar "i"))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "evidence table: no elaboration has published one (looking up ")) (EApp (EVar "display") (EVar "what"))) (ELit (LString " "))) (EApp (EVar "display") (EVar "m"))) (ELit (LString "#"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ")")))))
(DFunDef false "evidenceLookup" ((PCon "Some" (PCon "EvIndex" (PVar "runs"))) (PVar "what") (PCon "EvId" (PVar "m") (PVar "i"))) (EMatch (EUnOp "!" (EVar "preludeEvidenceRef")) (arm (PCon "Some" (PVar "seg")) ((GBool (EBinOp "&&" (EBinOp ">=" (EVar "i") (ELit (LInt 0))) (EBinOp "<" (EVar "i") (EApp (EVar "arrayLength") (EVar "seg")))))) (EApp (EApp (EApp (EApp (EApp (EVar "slotAnswer") (EVar "seg")) (EVar "what")) (EVar "m")) (EVar "i")) (EVar "i"))) (arm PWild () (EBlock (DoLet false false (PVar "k") (EApp (EApp (EApp (EApp (EVar "runAt") (EVar "runs")) (EVar "i")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "runs")))) (DoExpr (EIf (EBinOp "<" (EVar "k") (ELit (LInt 0))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "evidence table: ")) (EApp (EVar "display") (EVar "what"))) (ELit (LString " "))) (EApp (EVar "display") (EVar "m"))) (ELit (LString "#"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString " is from an earlier graph")))) (EMatch (EApp (EApp (EVar "arrayGetUnsafe") (EVar "k")) (EVar "runs")) (arm (PCon "EvRun" (PVar "lo") (PVar "arr")) () (EApp (EApp (EApp (EApp (EApp (EVar "slotAnswer") (EVar "arr")) (EVar "what")) (EVar "m")) (EVar "i")) (EBinOp "-" (EVar "i") (EVar "lo")))))))))))
(DTypeSig false "slotAnswer" (TyFun (TyApp (TyCon "Array") (TyApp (TyCon "Option") (TyCon "EvEntry"))) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "EvVal"))))))))
(DFunDef false "slotAnswer" ((PVar "arr") (PVar "what") (PVar "m") (PVar "i") (PVar "slot")) (EIf (EBinOp ">=" (EVar "slot") (EApp (EVar "arrayLength") (EVar "arr"))) (EApp (EApp (EApp (EVar "neverPublished") (EVar "what")) (EVar "m")) (EVar "i")) (EMatch (EApp (EApp (EVar "arrayGetUnsafe") (EVar "slot")) (EVar "arr")) (arm (PCon "None") () (EApp (EApp (EApp (EVar "neverPublished") (EVar "what")) (EVar "m")) (EVar "i"))) (arm (PCon "Some" (PCon "EvEntry" (PCon "EvId" (PVar "m2") PWild) (PVar "v"))) () (EIf (EBinOp "==" (EVar "m2") (EVar "m")) (EApp (EVar "Ok") (EVar "v")) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "evidence table: ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString "#"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString " answered by module "))) (EApp (EVar "display") (EVar "m2"))) (ELit (LString "")))))))))
(DTypeSig true "evDictRoutesIn" (TyFun (TyCon "EvIndex") (TyFun (TyCon "EvId") (TyApp (TyCon "List") (TyCon "Route")))))
(DFunDef false "evDictRoutesIn" ((PVar "idx") (PVar "ev")) (EApp (EVar "evRoutesOf") (EApp (EApp (EApp (EVar "answerIn") (EVar "idx")) (ELit (LString "dictionary application"))) (EVar "ev"))))
(DTypeSig false "evRoutesOf" (TyFun (TyCon "EvVal") (TyApp (TyCon "List") (TyCon "Route"))))
(DFunDef false "evRoutesOf" ((PCon "EvMany" (PVar "rs"))) (EVar "rs"))
(DFunDef false "evRoutesOf" ((PCon "EvOne" PWild)) (EApp (EVar "panic") (ELit (LString "evidence table: a dictionary application solved to a single route"))))
(DFunDef false "evRoutesOf" ((PCon "EvMethod" PWild PWild PWild PWild PWild)) (EApp (EVar "panic") (ELit (LString "evidence table: a dictionary application answered by a method occurrence"))))
(DFunDef false "evRoutesOf" ((PCon "EvLit" PWild PWild)) (EApp (EVar "panic") (ELit (LString "evidence table: a dictionary application answered by a literal site"))))
(DFunDef false "evRoutesOf" ((PCon "EvHead" PWild)) (EApp (EVar "panic") (ELit (LString "evidence table: a dictionary application answered by a record-head site"))))
(DTypeSig true "evSiteRouteIn" (TyFun (TyCon "EvIndex") (TyFun (TyCon "EvId") (TyCon "Route"))))
(DFunDef false "evSiteRouteIn" ((PVar "idx") (PVar "ev")) (EMatch (EApp (EApp (EVar "siteRouteResultIn") (EVar "idx")) (EVar "ev")) (arm (PCon "Ok" (PVar "r")) () (EVar "r")) (arm (PCon "Err" (PVar "message")) () (EApp (EVar "panic") (EVar "message")))))
(DTypeSig false "siteRouteResultIn" (TyFun (TyCon "EvIndex") (TyFun (TyCon "EvId") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Route")))))
(DFunDef false "siteRouteResultIn" ((PVar "idx") (PVar "ev")) (EIf (EApp (EVar "isUnminted") (EVar "ev")) (EApp (EVar "Ok") (EVar "RNone")) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EApp (EVar "evidenceLookup") (EApp (EVar "Some") (EVar "idx"))) (ELit (LString "operator site"))) (EVar "ev")) (arm (PCon "Ok" (PCon "EvOne" (PVar "r"))) () (EApp (EVar "Ok") (EVar "r"))) (arm (PCon "Ok" PWild) () (EApp (EVar "Err") (ELit (LString "evidence table: an operator site answered by another kind of entry")))) (arm (PCon "Err" (PVar "message")) () (EApp (EVar "Err") (EVar "message")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "evSiteLitIn" (TyFun (TyCon "EvIndex") (TyFun (TyCon "EvId") (TyTuple (TyApp (TyCon "Option") (TyCon "Float")) (TyCon "Route")))))
(DFunDef false "evSiteLitIn" ((PVar "idx") (PVar "ev")) (EMatch (EApp (EApp (EVar "siteLitResultIn") (EVar "idx")) (EVar "ev")) (arm (PCon "Ok" (PVar "answer")) () (EVar "answer")) (arm (PCon "Err" (PVar "message")) () (EApp (EVar "panic") (EVar "message")))))
(DTypeSig false "siteLitResultIn" (TyFun (TyCon "EvIndex") (TyFun (TyCon "EvId") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyApp (TyCon "Option") (TyCon "Float")) (TyCon "Route"))))))
(DFunDef false "siteLitResultIn" ((PVar "idx") (PVar "ev")) (EIf (EApp (EVar "isUnminted") (EVar "ev")) (EApp (EVar "Ok") (ETuple (EVar "None") (EVar "RNone"))) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EApp (EVar "evidenceLookup") (EApp (EVar "Some") (EVar "idx"))) (ELit (LString "literal site"))) (EVar "ev")) (arm (PCon "Ok" (PCon "EvLit" (PVar "f") (PVar "r"))) () (EApp (EVar "Ok") (ETuple (EVar "f") (EVar "r")))) (arm (PCon "Ok" PWild) () (EApp (EVar "Err") (ELit (LString "evidence table: a literal site answered by another kind of entry")))) (arm (PCon "Err" (PVar "message")) () (EApp (EVar "Err") (EVar "message")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "evSiteHeadIn" (TyFun (TyCon "EvIndex") (TyFun (TyCon "EvId") (TyCon "String"))))
(DFunDef false "evSiteHeadIn" ((PVar "idx") (PVar "ev")) (EMatch (EApp (EApp (EVar "siteHeadResultIn") (EVar "idx")) (EVar "ev")) (arm (PCon "Ok" (PVar "head")) () (EVar "head")) (arm (PCon "Err" (PVar "message")) () (EApp (EVar "panic") (EVar "message")))))
(DTypeSig false "siteHeadResultIn" (TyFun (TyCon "EvIndex") (TyFun (TyCon "EvId") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String")))))
(DFunDef false "siteHeadResultIn" ((PVar "idx") (PVar "ev")) (EIf (EApp (EVar "isUnminted") (EVar "ev")) (EApp (EVar "Ok") (ELit (LString ""))) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EApp (EVar "evidenceLookup") (EApp (EVar "Some") (EVar "idx"))) (ELit (LString "record-head site"))) (EVar "ev")) (arm (PCon "Ok" (PCon "EvHead" (PVar "h"))) () (EApp (EVar "Ok") (EVar "h"))) (arm (PCon "Ok" PWild) () (EApp (EVar "Err") (ELit (LString "evidence table: a record-head site answered by another kind of entry")))) (arm (PCon "Err" (PVar "message")) () (EApp (EVar "Err") (EVar "message")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
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
(DUse false (UseGroup ("frontend" "ast") ((mem "Ty" true) (mem "Constraint" true) (mem "TyConOrigin" true) (mem "EffAtomTy" true) (mem "qualifierSource" false) (mem "EffParamTy" true) (mem "effAtomSurface" false) (mem "effAtomBare" false) (mem "effAtomWith" false) (mem "Route" true) (mem "EvId" true) (mem "isUnminted" false) (mem "EvVal" true) (mem "EvEntry" true) (mem "EvTable" false) (mem "constraintUnresolved" false) (mem "tyConBuiltin" false) (mem "ifaceIdentity" false) (mem "authTermsSurface" false))))
(DUse false (UseGroup ("support" "util") ((mem "joinWith" false) (mem "escStr" false) (mem "reverseL" false))))
(DUse false (UseGroup ("array") ((mem "sort" false))))
(DData Abstract "EvIndex" () ((variant "EvIndex" (ConPos (TyApp (TyCon "Array") (TyCon "EvRun"))))) ())
(DData Private "EvRun" () ((variant "EvRun" (ConPos (TyCon "Int") (TyApp (TyCon "Array") (TyApp (TyCon "Option") (TyCon "EvEntry")))))) ())
(DTypeSig false "runGap" (TyCon "Int"))
(DFunDef false "runGap" () (ELit (LInt 64)))
(DTypeSig false "preludeEvidenceRef" (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyApp (TyCon "Array") (TyApp (TyCon "Option") (TyCon "EvEntry"))))))
(DFunDef false "preludeEvidenceRef" () (EApp (EVar "Ref") (EVar "None")))
(DTypeSig true "setPreludeEvidence" (TyFun (TyCon "Int") (TyFun (TyCon "EvTable") (TyCon "Unit"))))
(DFunDef false "setPreludeEvidence" ((PVar "counter") (PVar "rows")) (EBlock (DoLet false false (PVar "arr") (EApp (EApp (EVar "arrayMake") (EVar "counter")) (EVar "None"))) (DoExpr (EApp (EApp (EVar "fillEvidence") (EApp (EVar "EvIndex") (EApp (EVar "arrayFromList") (EListLit (EApp (EApp (EVar "EvRun") (ELit (LInt 0))) (EVar "arr")))))) (EVar "rows"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "preludeEvidenceRef")) (EApp (EVar "Some") (EVar "arr"))))))
(DTypeSig true "evIndexOf" (TyFun (TyCon "EvTable") (TyCon "EvIndex")))
(DFunDef false "evIndexOf" ((PVar "entries")) (EMatch (EUnOp "!" (EVar "preludeEvidenceRef")) (arm (PCon "None") () (EApp (EVar "filledIndexOf") (EVar "entries"))) (arm (PCon "Some" (PVar "seg")) () (EApp (EVar "filledIndexOf") (EApp (EApp (EMethodRef "filter") (EApp (EVar "aboveSegment") (EVar "seg"))) (EVar "entries"))))))
(DTypeSig true "entriesAboveSegment" (TyFun (TyCon "EvTable") (TyCon "EvTable")))
(DFunDef false "entriesAboveSegment" ((PVar "entries")) (EMatch (EUnOp "!" (EVar "preludeEvidenceRef")) (arm (PCon "None") () (EVar "entries")) (arm (PCon "Some" (PVar "seg")) () (EApp (EApp (EMethodRef "filter") (ELam ((PVar "e")) (EMatch (EVar "e") (arm (PCon "EvEntry" (PCon "EvId" PWild (PVar "i")) PWild) () (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "seg"))))))) (EVar "entries")))))
(DTypeSig false "filledIndexOf" (TyFun (TyCon "EvTable") (TyCon "EvIndex")))
(DFunDef false "filledIndexOf" ((PVar "entries")) (EBlock (DoLet false false (PVar "index") (EApp (EVar "emptyIndexFor") (EVar "entries"))) (DoExpr (EApp (EApp (EVar "fillEvidence") (EMethodRef "index")) (EVar "entries"))) (DoExpr (EMethodRef "index"))))
(DTypeSig true "emptyIndexFor" (TyFun (TyCon "EvTable") (TyCon "EvIndex")))
(DFunDef false "emptyIndexFor" ((PVar "entries")) (EBlock (DoLet false false (PVar "lo") (EApp (EVar "evMinOrdinal") (EVar "entries"))) (DoLet false false (PVar "hi") (EApp (EApp (EVar "evSlotCount") (EVar "entries")) (EVar "lo"))) (DoExpr (EIf (EBinOp "<=" (EBinOp "-" (EVar "hi") (EVar "lo")) (EBinOp "*" (ELit (LInt 2)) (EApp (EMethodRef "length") (EVar "entries")))) (EApp (EVar "EvIndex") (EApp (EVar "arrayFromList") (EListLit (EApp (EApp (EVar "emptyRun") (EVar "lo")) (EVar "hi"))))) (EBlock (DoLet false false (PVar "ordinals") (EApp (EVar "sort") (EApp (EVar "arrayFromList") (EApp (EApp (EMethodRef "map") (EVar "entryOrdinal")) (EVar "entries"))))) (DoLet false false (PVar "first") (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 0))) (EVar "ordinals"))) (DoExpr (EApp (EVar "EvIndex") (EApp (EVar "arrayFromList") (EApp (EApp (EApp (EApp (EApp (EVar "runsFrom") (EVar "ordinals")) (ELit (LInt 1))) (EVar "first")) (EVar "first")) (EListLit))))))))))
(DTypeSig false "runsFrom" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "EvRun")) (TyApp (TyCon "List") (TyCon "EvRun"))))))))
(DFunDef false "runsFrom" ((PVar "ordinals") (PVar "k") (PVar "lo") (PVar "last") (PVar "acc")) (EIf (EBinOp ">=" (EVar "k") (EApp (EVar "arrayLength") (EVar "ordinals"))) (EApp (EVar "reverseL") (EBinOp "::" (EApp (EApp (EVar "emptyRun") (EVar "lo")) (EBinOp "+" (EVar "last") (ELit (LInt 1)))) (EVar "acc"))) (EBlock (DoLet false false (PVar "i") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "k")) (EVar "ordinals"))) (DoExpr (EIf (EBinOp ">" (EBinOp "-" (EVar "i") (EVar "last")) (EVar "runGap")) (EApp (EApp (EApp (EApp (EApp (EVar "runsFrom") (EVar "ordinals")) (EBinOp "+" (EVar "k") (ELit (LInt 1)))) (EVar "i")) (EVar "i")) (EBinOp "::" (EApp (EApp (EVar "emptyRun") (EVar "lo")) (EBinOp "+" (EVar "last") (ELit (LInt 1)))) (EVar "acc"))) (EApp (EApp (EApp (EApp (EApp (EVar "runsFrom") (EVar "ordinals")) (EBinOp "+" (EVar "k") (ELit (LInt 1)))) (EVar "lo")) (EVar "i")) (EVar "acc")))))))
(DTypeSig false "emptyRun" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "EvRun"))))
(DFunDef false "emptyRun" ((PVar "lo") (PVar "hi")) (EApp (EApp (EVar "EvRun") (EVar "lo")) (EApp (EApp (EVar "arrayMake") (EBinOp "-" (EVar "hi") (EVar "lo"))) (EVar "None"))))
(DTypeSig false "entryOrdinal" (TyFun (TyCon "EvEntry") (TyCon "Int")))
(DFunDef false "entryOrdinal" ((PCon "EvEntry" (PCon "EvId" PWild (PVar "i")) PWild)) (EVar "i"))
(DTypeSig false "runAt" (TyFun (TyApp (TyCon "Array") (TyCon "EvRun")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "runAt" ((PVar "runs") (PVar "i") (PVar "a") (PVar "b")) (EIf (EBinOp ">=" (EVar "a") (EVar "b")) (EBinOp "-" (EVar "a") (ELit (LInt 1))) (EBlock (DoLet false false (PVar "mid") (EBinOp "/" (EBinOp "+" (EVar "a") (EVar "b")) (ELit (LInt 2)))) (DoExpr (EMatch (EApp (EApp (EVar "arrayGetUnsafe") (EVar "mid")) (EVar "runs")) (arm (PCon "EvRun" (PVar "lo") PWild) () (EIf (EBinOp "<=" (EVar "lo") (EVar "i")) (EApp (EApp (EApp (EApp (EVar "runAt") (EVar "runs")) (EVar "i")) (EBinOp "+" (EVar "mid") (ELit (LInt 1)))) (EVar "b")) (EApp (EApp (EApp (EApp (EVar "runAt") (EVar "runs")) (EVar "i")) (EVar "a")) (EVar "mid")))))))))
(DTypeSig false "runFor" (TyFun (TyCon "EvIndex") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "EvRun")))))
(DFunDef false "runFor" ((PCon "EvIndex" (PVar "runs")) (PVar "m") (PVar "i")) (EBlock (DoLet false false (PVar "k") (EApp (EApp (EApp (EApp (EVar "runAt") (EVar "runs")) (EVar "i")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "runs")))) (DoExpr (EIf (EBinOp "<" (EVar "k") (ELit (LInt 0))) (EApp (EApp (EVar "noSlot") (EVar "m")) (EVar "i")) (EMatch (EApp (EApp (EVar "arrayGetUnsafe") (EVar "k")) (EVar "runs")) (arm (PAs "run" (PCon "EvRun" (PVar "lo") (PVar "arr"))) () (EIf (EBinOp "<" (EBinOp "-" (EVar "i") (EVar "lo")) (EApp (EVar "arrayLength") (EVar "arr"))) (EVar "run") (EApp (EApp (EVar "noSlot") (EVar "m")) (EVar "i")))))))))
(DTypeSig false "noSlot" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyVar "a"))))
(DFunDef false "noSlot" ((PVar "m") (PVar "i")) (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "evidence table: ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "#"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString " has no slot in the index")))))
(DTypeSig true "claimSlot" (TyFun (TyCon "EvIndex") (TyFun (TyCon "EvEntry") (TyCon "Bool"))))
(DFunDef false "claimSlot" ((PVar "idx") (PAs "e" (PCon "EvEntry" (PCon "EvId" (PVar "m") (PVar "i")) PWild))) (EMatch (EApp (EApp (EApp (EVar "runFor") (EVar "idx")) (EVar "m")) (EVar "i")) (arm (PCon "EvRun" (PVar "lo") (PVar "arr")) () (EMatch (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EVar "i") (EVar "lo"))) (EVar "arr")) (arm (PCon "None") () (EBlock (DoExpr (EApp (EApp (EApp (EVar "arraySetUnsafe") (EBinOp "-" (EVar "i") (EVar "lo"))) (EApp (EVar "Some") (EVar "e"))) (EVar "arr"))) (DoExpr (EVar "True")))) (arm (PCon "Some" PWild) () (EVar "False"))))))
(DTypeSig true "replaceEntryIn" (TyFun (TyCon "EvIndex") (TyFun (TyCon "EvEntry") (TyCon "Unit"))))
(DFunDef false "replaceEntryIn" ((PVar "idx") (PAs "e" (PCon "EvEntry" (PCon "EvId" (PVar "m") (PVar "i")) PWild))) (EMatch (EApp (EApp (EApp (EVar "runFor") (EVar "idx")) (EVar "m")) (EVar "i")) (arm (PCon "EvRun" (PVar "lo") (PVar "arr")) () (EApp (EApp (EApp (EVar "arraySetUnsafe") (EBinOp "-" (EVar "i") (EVar "lo"))) (EApp (EVar "Some") (EVar "e"))) (EVar "arr")))))
(DTypeSig true "evIndexSlotCount" (TyFun (TyCon "EvIndex") (TyCon "Int")))
(DFunDef false "evIndexSlotCount" ((PCon "EvIndex" (PVar "runs"))) (EApp (EApp (EApp (EVar "slotsFrom") (EVar "runs")) (ELit (LInt 0))) (ELit (LInt 0))))
(DTypeSig false "slotsFrom" (TyFun (TyApp (TyCon "Array") (TyCon "EvRun")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "slotsFrom" ((PVar "runs") (PVar "k") (PVar "acc")) (EIf (EBinOp ">=" (EVar "k") (EApp (EVar "arrayLength") (EVar "runs"))) (EVar "acc") (EMatch (EApp (EApp (EVar "arrayGetUnsafe") (EVar "k")) (EVar "runs")) (arm (PCon "EvRun" PWild (PVar "arr")) () (EApp (EApp (EApp (EVar "slotsFrom") (EVar "runs")) (EBinOp "+" (EVar "k") (ELit (LInt 1)))) (EBinOp "+" (EVar "acc") (EApp (EVar "arrayLength") (EVar "arr"))))))))
(DTypeSig true "evIndexEntries" (TyFun (TyCon "EvIndex") (TyApp (TyCon "List") (TyCon "EvEntry"))))
(DFunDef false "evIndexEntries" ((PCon "EvIndex" (PVar "runs"))) (EApp (EApp (EApp (EVar "runEntries") (EVar "runs")) (EBinOp "-" (EApp (EVar "arrayLength") (EVar "runs")) (ELit (LInt 1)))) (EListLit)))
(DTypeSig false "runEntries" (TyFun (TyApp (TyCon "Array") (TyCon "EvRun")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "EvEntry")) (TyApp (TyCon "List") (TyCon "EvEntry"))))))
(DFunDef false "runEntries" ((PVar "runs") (PVar "k") (PVar "acc")) (EIf (EBinOp "<" (EVar "k") (ELit (LInt 0))) (EVar "acc") (EMatch (EApp (EApp (EVar "arrayGetUnsafe") (EVar "k")) (EVar "runs")) (arm (PCon "EvRun" PWild (PVar "arr")) () (EApp (EApp (EApp (EVar "runEntries") (EVar "runs")) (EBinOp "-" (EVar "k") (ELit (LInt 1)))) (EApp (EApp (EApp (EVar "slotEntries") (EVar "arr")) (EBinOp "-" (EApp (EVar "arrayLength") (EVar "arr")) (ELit (LInt 1)))) (EVar "acc")))))))
(DTypeSig false "slotEntries" (TyFun (TyApp (TyCon "Array") (TyApp (TyCon "Option") (TyCon "EvEntry"))) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "EvEntry")) (TyApp (TyCon "List") (TyCon "EvEntry"))))))
(DFunDef false "slotEntries" ((PVar "slots") (PVar "k") (PVar "acc")) (EIf (EBinOp "<" (EVar "k") (ELit (LInt 0))) (EVar "acc") (EMatch (EApp (EApp (EVar "arrayGetUnsafe") (EVar "k")) (EVar "slots")) (arm (PCon "Some" (PVar "e")) () (EApp (EApp (EApp (EVar "slotEntries") (EVar "slots")) (EBinOp "-" (EVar "k") (ELit (LInt 1)))) (EBinOp "::" (EVar "e") (EVar "acc")))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "slotEntries") (EVar "slots")) (EBinOp "-" (EVar "k") (ELit (LInt 1)))) (EVar "acc"))))))
(DTypeSig false "aboveSegment" (TyFun (TyApp (TyCon "Array") (TyApp (TyCon "Option") (TyCon "EvEntry"))) (TyFun (TyCon "EvEntry") (TyCon "Bool"))))
(DFunDef false "aboveSegment" ((PVar "seg") (PCon "EvEntry" (PCon "EvId" (PVar "m") (PVar "i")) PWild)) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "seg"))) (EVar "True") (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "seg")) (arm (PCon "Some" (PCon "EvEntry" (PCon "EvId" (PVar "m2") PWild) PWild)) ((GBool (EBinOp "==" (EVar "m2") (EVar "m")))) (EVar "False")) (arm PWild () (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "evidence table: ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "#"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString " is below the prelude's counter but not the prelude's")))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "evSlotCount" (TyFun (TyCon "EvTable") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "evSlotCount" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "evSlotCount" ((PCons (PCon "EvEntry" (PCon "EvId" PWild (PVar "i")) PWild) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "evSlotCount") (EVar "rest")) (EApp (EApp (EMethodRef "max") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "acc"))))
(DTypeSig false "evMinOrdinal" (TyFun (TyCon "EvTable") (TyCon "Int")))
(DFunDef false "evMinOrdinal" ((PList)) (ELit (LInt 0)))
(DFunDef false "evMinOrdinal" ((PCons (PCon "EvEntry" (PCon "EvId" PWild (PVar "i")) PWild) (PVar "rest"))) (EApp (EApp (EVar "evMinFrom") (EVar "rest")) (EVar "i")))
(DTypeSig false "evMinFrom" (TyFun (TyCon "EvTable") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "evMinFrom" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "evMinFrom" ((PCons (PCon "EvEntry" (PCon "EvId" PWild (PVar "i")) PWild) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "evMinFrom") (EVar "rest")) (EApp (EApp (EMethodRef "min") (EVar "i")) (EVar "acc"))))
(DTypeSig false "fillEvidence" (TyFun (TyCon "EvIndex") (TyFun (TyCon "EvTable") (TyCon "Unit"))))
(DFunDef false "fillEvidence" (PWild (PList)) (ELit LUnit))
(DFunDef false "fillEvidence" ((PVar "idx") (PCons (PAs "e" (PCon "EvEntry" (PCon "EvId" (PVar "m") (PVar "i")) PWild)) (PVar "rest"))) (EIf (EApp (EApp (EVar "claimSlot") (EVar "idx")) (EVar "e")) (EApp (EApp (EVar "fillEvidence") (EVar "idx")) (EVar "rest")) (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "evidence table: two goals published under ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "#"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ""))))))
(DTypeSig false "neverPublished" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyVar "a"))))))
(DFunDef false "neverPublished" ((PVar "what") (PVar "m") (PVar "i")) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "evidence table: ")) (EApp (EMethodRef "display") (EVar "what"))) (ELit (LString " "))) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "#"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString " was never published")))))
(DTypeSig false "answerIn" (TyFun (TyCon "EvIndex") (TyFun (TyCon "String") (TyFun (TyCon "EvId") (TyCon "EvVal")))))
(DFunDef false "answerIn" ((PVar "idx") (PVar "what") (PVar "ev")) (EMatch (EApp (EApp (EApp (EVar "evidenceLookup") (EApp (EVar "Some") (EVar "idx"))) (EVar "what")) (EVar "ev")) (arm (PCon "Ok" (PVar "v")) () (EVar "v")) (arm (PCon "Err" (PVar "message")) () (EApp (EVar "panic") (EVar "message")))))
(DTypeSig true "evidenceLookup" (TyFun (TyApp (TyCon "Option") (TyCon "EvIndex")) (TyFun (TyCon "String") (TyFun (TyCon "EvId") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "EvVal"))))))
(DFunDef false "evidenceLookup" ((PCon "None") (PVar "what") (PCon "EvId" (PVar "m") (PVar "i"))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "evidence table: no elaboration has published one (looking up ")) (EApp (EMethodRef "display") (EVar "what"))) (ELit (LString " "))) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "#"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ")")))))
(DFunDef false "evidenceLookup" ((PCon "Some" (PCon "EvIndex" (PVar "runs"))) (PVar "what") (PCon "EvId" (PVar "m") (PVar "i"))) (EMatch (EUnOp "!" (EVar "preludeEvidenceRef")) (arm (PCon "Some" (PVar "seg")) ((GBool (EBinOp "&&" (EBinOp ">=" (EVar "i") (ELit (LInt 0))) (EBinOp "<" (EVar "i") (EApp (EVar "arrayLength") (EVar "seg")))))) (EApp (EApp (EApp (EApp (EApp (EVar "slotAnswer") (EVar "seg")) (EVar "what")) (EVar "m")) (EVar "i")) (EVar "i"))) (arm PWild () (EBlock (DoLet false false (PVar "k") (EApp (EApp (EApp (EApp (EVar "runAt") (EVar "runs")) (EVar "i")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "runs")))) (DoExpr (EIf (EBinOp "<" (EVar "k") (ELit (LInt 0))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "evidence table: ")) (EApp (EMethodRef "display") (EVar "what"))) (ELit (LString " "))) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "#"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString " is from an earlier graph")))) (EMatch (EApp (EApp (EVar "arrayGetUnsafe") (EVar "k")) (EVar "runs")) (arm (PCon "EvRun" (PVar "lo") (PVar "arr")) () (EApp (EApp (EApp (EApp (EApp (EVar "slotAnswer") (EVar "arr")) (EVar "what")) (EVar "m")) (EVar "i")) (EBinOp "-" (EVar "i") (EVar "lo")))))))))))
(DTypeSig false "slotAnswer" (TyFun (TyApp (TyCon "Array") (TyApp (TyCon "Option") (TyCon "EvEntry"))) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "EvVal"))))))))
(DFunDef false "slotAnswer" ((PVar "arr") (PVar "what") (PVar "m") (PVar "i") (PVar "slot")) (EIf (EBinOp ">=" (EVar "slot") (EApp (EVar "arrayLength") (EVar "arr"))) (EApp (EApp (EApp (EVar "neverPublished") (EVar "what")) (EVar "m")) (EVar "i")) (EMatch (EApp (EApp (EVar "arrayGetUnsafe") (EVar "slot")) (EVar "arr")) (arm (PCon "None") () (EApp (EApp (EApp (EVar "neverPublished") (EVar "what")) (EVar "m")) (EVar "i"))) (arm (PCon "Some" (PCon "EvEntry" (PCon "EvId" (PVar "m2") PWild) (PVar "v"))) () (EIf (EBinOp "==" (EVar "m2") (EVar "m")) (EApp (EVar "Ok") (EVar "v")) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "evidence table: ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "#"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString " answered by module "))) (EApp (EMethodRef "display") (EVar "m2"))) (ELit (LString "")))))))))
(DTypeSig true "evDictRoutesIn" (TyFun (TyCon "EvIndex") (TyFun (TyCon "EvId") (TyApp (TyCon "List") (TyCon "Route")))))
(DFunDef false "evDictRoutesIn" ((PVar "idx") (PVar "ev")) (EApp (EVar "evRoutesOf") (EApp (EApp (EApp (EVar "answerIn") (EVar "idx")) (ELit (LString "dictionary application"))) (EVar "ev"))))
(DTypeSig false "evRoutesOf" (TyFun (TyCon "EvVal") (TyApp (TyCon "List") (TyCon "Route"))))
(DFunDef false "evRoutesOf" ((PCon "EvMany" (PVar "rs"))) (EVar "rs"))
(DFunDef false "evRoutesOf" ((PCon "EvOne" PWild)) (EApp (EVar "panic") (ELit (LString "evidence table: a dictionary application solved to a single route"))))
(DFunDef false "evRoutesOf" ((PCon "EvMethod" PWild PWild PWild PWild PWild)) (EApp (EVar "panic") (ELit (LString "evidence table: a dictionary application answered by a method occurrence"))))
(DFunDef false "evRoutesOf" ((PCon "EvLit" PWild PWild)) (EApp (EVar "panic") (ELit (LString "evidence table: a dictionary application answered by a literal site"))))
(DFunDef false "evRoutesOf" ((PCon "EvHead" PWild)) (EApp (EVar "panic") (ELit (LString "evidence table: a dictionary application answered by a record-head site"))))
(DTypeSig true "evSiteRouteIn" (TyFun (TyCon "EvIndex") (TyFun (TyCon "EvId") (TyCon "Route"))))
(DFunDef false "evSiteRouteIn" ((PVar "idx") (PVar "ev")) (EMatch (EApp (EApp (EVar "siteRouteResultIn") (EVar "idx")) (EVar "ev")) (arm (PCon "Ok" (PVar "r")) () (EVar "r")) (arm (PCon "Err" (PVar "message")) () (EApp (EVar "panic") (EVar "message")))))
(DTypeSig false "siteRouteResultIn" (TyFun (TyCon "EvIndex") (TyFun (TyCon "EvId") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Route")))))
(DFunDef false "siteRouteResultIn" ((PVar "idx") (PVar "ev")) (EIf (EApp (EVar "isUnminted") (EVar "ev")) (EApp (EVar "Ok") (EVar "RNone")) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EApp (EVar "evidenceLookup") (EApp (EVar "Some") (EVar "idx"))) (ELit (LString "operator site"))) (EVar "ev")) (arm (PCon "Ok" (PCon "EvOne" (PVar "r"))) () (EApp (EVar "Ok") (EVar "r"))) (arm (PCon "Ok" PWild) () (EApp (EVar "Err") (ELit (LString "evidence table: an operator site answered by another kind of entry")))) (arm (PCon "Err" (PVar "message")) () (EApp (EVar "Err") (EVar "message")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "evSiteLitIn" (TyFun (TyCon "EvIndex") (TyFun (TyCon "EvId") (TyTuple (TyApp (TyCon "Option") (TyCon "Float")) (TyCon "Route")))))
(DFunDef false "evSiteLitIn" ((PVar "idx") (PVar "ev")) (EMatch (EApp (EApp (EVar "siteLitResultIn") (EVar "idx")) (EVar "ev")) (arm (PCon "Ok" (PVar "answer")) () (EVar "answer")) (arm (PCon "Err" (PVar "message")) () (EApp (EVar "panic") (EVar "message")))))
(DTypeSig false "siteLitResultIn" (TyFun (TyCon "EvIndex") (TyFun (TyCon "EvId") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyApp (TyCon "Option") (TyCon "Float")) (TyCon "Route"))))))
(DFunDef false "siteLitResultIn" ((PVar "idx") (PVar "ev")) (EIf (EApp (EVar "isUnminted") (EVar "ev")) (EApp (EVar "Ok") (ETuple (EVar "None") (EVar "RNone"))) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EApp (EVar "evidenceLookup") (EApp (EVar "Some") (EVar "idx"))) (ELit (LString "literal site"))) (EVar "ev")) (arm (PCon "Ok" (PCon "EvLit" (PVar "f") (PVar "r"))) () (EApp (EVar "Ok") (ETuple (EVar "f") (EVar "r")))) (arm (PCon "Ok" PWild) () (EApp (EVar "Err") (ELit (LString "evidence table: a literal site answered by another kind of entry")))) (arm (PCon "Err" (PVar "message")) () (EApp (EVar "Err") (EVar "message")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "evSiteHeadIn" (TyFun (TyCon "EvIndex") (TyFun (TyCon "EvId") (TyCon "String"))))
(DFunDef false "evSiteHeadIn" ((PVar "idx") (PVar "ev")) (EMatch (EApp (EApp (EVar "siteHeadResultIn") (EVar "idx")) (EVar "ev")) (arm (PCon "Ok" (PVar "head")) () (EVar "head")) (arm (PCon "Err" (PVar "message")) () (EApp (EVar "panic") (EVar "message")))))
(DTypeSig false "siteHeadResultIn" (TyFun (TyCon "EvIndex") (TyFun (TyCon "EvId") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String")))))
(DFunDef false "siteHeadResultIn" ((PVar "idx") (PVar "ev")) (EIf (EApp (EVar "isUnminted") (EVar "ev")) (EApp (EVar "Ok") (ELit (LString ""))) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EApp (EVar "evidenceLookup") (EApp (EVar "Some") (EVar "idx"))) (ELit (LString "record-head site"))) (EVar "ev")) (arm (PCon "Ok" (PCon "EvHead" (PVar "h"))) () (EApp (EVar "Ok") (EVar "h"))) (arm (PCon "Ok" PWild) () (EApp (EVar "Err") (ELit (LString "evidence table: a record-head site answered by another kind of entry")))) (arm (PCon "Err" (PVar "message")) () (EApp (EVar "Err") (EVar "message")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
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
