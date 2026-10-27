# META
source_lines=1279
stages=DESUGAR,MARK
# SOURCE
-- tc_infer_records: the helpers the record arms call: field-owner resolution, field-shape
-- conflicts, record instantiation, the record error emitters and the field-name suggestion, and the
-- stamped record head (`stampedRecordHead`); the nine record arms themselves (`inferRecordCreate`,
-- `inferFieldAccess`, `inferValueField`, `inferRecordUpdate*`) and their field-assignment helpers
-- (`unifyFieldAssignIdx`, `unifyFieldAssignsIdx`) are members of the `tc_infer` recursion.
--
-- Spec: language-design Data Types, Sum Types (Variants with Named Fields), Product Types (record
-- construction, access, update).
--
-- Placement: declarations are placed by R1-R6 of the Phase 4 module table,
-- compiler/ARCHITECTURE-PLAYBOOK.md section 6.
-- Closure rule: this module may not import `types.typecheck`, nor any of `tc_infer`, `tc_elab`,
-- `tc_global`, `tc_module`.

import types.tc_types.{
  CtorFieldConflict(..),
  DynCtx,
  GraphCtx,
  ModuleCtx,
  RecordInfo,
  RecordSubst,
}
import types.tc_mono.{
  authCellsIn,
  authSame,
  headTyconMono,
  headTyconNameMono,
  monoSameGiven,
  recordAuthCells,
  recordOwnerModule,
  recordResultMono,
  rowSame,
  substMono,
  tyvarId,
}
import types.tc_diag_text.{
  abstractFieldMsg,
  ambiguousFieldDeclsMsg,
  ambiguousFieldMsg,
  fieldFixFrom,
  fieldNotInAllCtorsMsg,
  fieldPositionDiffersMsg,
  fieldTypeDiffersMsg,
  missingFieldMsg,
  partialExistentialUpdateMsg,
  unknownFieldMsg,
  unknownRecordMsg,
  updateMultiCtorMsg,
}
import types.tc_env.{lookupRecordByName, recordCandInfo}
import types.tc_diag.{pushTypeError, pushTypeErrorHelpFixAt}
import types.tc_unify.{
  freshInferenceAuthvar, freshSubst, freshVar, poisonMismatchVars, unifyIn
}
import types.effect_authority.{
  Authority(..), Authvar(..), authTop, authvarDomain, authvarId
}
import types.effect_rows.{EffRow(..), Effvar(..), effvarId}
import frontend.ast.{FieldAssign(..), Ident(..), TabKey(..)}
import types.registry.{
  HeadKey(..),
  headKeyTag,
  -- A-2.13 (#1319 unit 3): the IDENTITY inside a projected head, for the one
  -- record lookup that selects a row by the receiver rather than by a spelling.
  headKeyIdent,
  -- The DECLARATION half of a projected head, keeping `TkIdent` and `TkBare`
  -- apart — the mint an IDENTITY-keyed table's reader owes its writer.  Used by
  -- `ctorOracleKeyOf` below, which keys `matchOracle.typeCtors`; NOT
  -- `headTabOf`, whose `dispHeadTab` deliberately flattens every head to
  -- `TkBare` for the SPELLING-keyed dispatch buckets.
  headKeyDecl,
  spCandsOf,
  spRows,
}
import types.repr.{Mono(..), normalize}
import support.ordmap.{omHasKey, omLookup, omSize, OrdMap}
import types.effect_domain.{Param(..)}
import map.{Map(..)}
import support.util.{
  contains,
  dedupBy,
  editDistance,
  filterList,
  isEmptyL,
  isSome,
  listLen,
  orElseOpt,
  sortUniqS,
}
import list.{elemIndex, head}
import types.private_mangle.{isReservedCtor, mangledName}
import frontend.exhaust.{oGetCtors}
import map as IdMap

export
fieldAssignNamePair : FieldAssign -> (String, Unit)
fieldAssignNamePair (FieldAssign fn _) = (fn, ())

export
assignedFieldNames : List FieldAssign -> List String
assignedFieldNames fields = map (fa => fst (fieldAssignNamePair fa)) fields

-- TYPECHECK-AUDIT OBS4: every declared field must be supplied in a record
-- construction.  Walk `declaredFields`, check each name is present
-- among the supplied `FieldAssign` list; push MissingField for any absent one.
-- `supplied` is the SET of supplied field names (built once by the caller), so the
-- membership test is O(log N) instead of a per-declared-field O(N) list scan — a single
-- N-field construction was O(N x N) here (issue #980).  Declared order is still walked
-- in order, so the missing-field errors are pushed in exactly the old order.
export
checkMissingFields : ModuleCtx -> String -> List String -> OrdMap Unit -> Unit
checkMissingFields mctx _ [] _ = ()
checkMissingFields mctx rname (fname :: rest) supplied
  | omHasKey fname supplied = checkMissingFields mctx rname rest supplied
  | otherwise =
    pushTypeError mctx "T-MISSING-FIELD" (missingFieldMsg fname rname)
    checkMissingFields mctx rname rest supplied

-- ── #2839: the stamp names the record by IDENTITY, not by a spelling ─────────
-- The head this node carries downstream is the selected record's
-- OWNER-QUALIFIED name (`<owner module>__<record name>`), never the bare
-- registry key.
--
-- Both emitters pick a field's offset by `(record head, label)`, so two modules
-- declaring same-named records with their fields in opposite orders are
-- distinguishable at the emitter only if this stamp distinguishes them.  The
-- registry key alone does not: it is the record's DECL name, which is bare
-- unless `types/private_mangle.mdk` renamed it first.  Deriving the
-- qualification from the record's OWN declaring module makes the stamp's
-- cross-module identity a property of the declaration instead of a side effect
-- of the mangler having run before elaboration
-- (`compiler/TYPECHECK-TARGET-ARCHITECTURE.md` §1 L2).
--
-- The spelling is the MANGLER'S, and it reuses the mangler's own rename decision
-- rather than restating it, so the two cannot drift: a reserved fixed-tag
-- constructor is never renamed, every other one is qualified with its owner.
--
-- The qualification happens exactly once, and here is where.  This is the only
-- writer of the head a downstream reader sees: `types/private_mangle.mdk`'s
-- `renameScoped` deliberately passes the `EFieldAccess`/`ERecordUpdate` site ids
-- through (see its note there).  A second application would have to guess whether
-- the first had already run, and a prefix test is not that fact: a record whose
-- SOURCE name already carries its own module's prefix (`data Mm__Cfg` beside
-- `data Cfg` in module `Mm`) reads as "already qualified" and collides with its
-- sibling — measured, the built binary projected the sibling's slot at exit 0 on
-- a program the parent commit REFUSED.
--
-- The one pass that still renames a constructor BEFORE elaboration,
-- `mangleCtorCollisions`, cannot be observed through this cell: its drivers are
-- `eval`, `core_ir_eval` and `test`, and all three discard the record-name field
-- (`eval (EFieldAccess e field _)`, `ceval (CFieldAccess e field _)`).  The sole
-- reader is the emitter, reached only through drivers that elaborate unmangled.
export
stampedRecordHead : String -> RecordInfo -> String
stampedRecordHead rname ri = match recordOwnerModule ri
  None => rname
  Some mid => ownerQualifiedHead mid rname

-- The name the mangler gives a record head owned by `mid` — the same two-case
-- decision `buildUnitCtorRenameMap` makes, and nothing else.  NOT idempotent, and
-- deliberately so: idempotence would require a test for "has this already been
-- qualified?", the only available test is a prefix guess, and the guess is wrong
-- for a record the author named `<mid>__<something>`.  Applied once, from the
-- record's own declaring module, it needs no such test — see `stampedRecordHead`.
ownerQualifiedHead : String -> String -> String
ownerQualifiedHead mid name
  | isReservedCtor name = name
  | otherwise = mangledName mid name

-- the field's type from a resolved record `rname`, given the (already-inferred)
-- receiver type `te` to unify against the record's instantiated result type.  A
-- field absent from a KNOWN record names it (mirrors the oracle's `resolve_in`,
-- which raises UnknownField with the resolved record name).
export
inferFieldOfRecord : DynCtx -> Mono -> String -> RecordInfo -> String -> Mono
inferFieldOfRecord dyn te rname ri fname =
  let sr = instantiateRecordShared dyn.dcModule ri
  unifyIn dyn te (snd sr)
  match omLookup fname (recordFieldMap ri)
    Some fm => substRecordField dyn.dcModule.mcGraph (fst sr) fm
    None => unknownFieldFresh dyn.dcModule fname rname (recordFieldNames ri)

-- ── #1468: `.f` on a type whose constructors DISAGREE about `f` is rejected ──
--
-- The resolution ladder above answers "WHICH declaration does `.f` mean"; it never
-- asked whether the receiver's TYPE entitles anyone to ask.  For
-- `data T = | A { x : Int } | B { z : Int }`, `x` has exactly ONE owner, so
-- `resolveFieldByOwners`' singleton arm hands back `A` with full confidence and the
-- later unify is SATISFIED — the receiver really is a `T` — and `check` exits 0.
-- A `T` value carries no static constructor tag, so the emitted code reads slot 0
-- unconditionally: measured on this base, `getX (B { z = 99 })` printed `v=99`, and
-- with `B { z : String }` the same program printed a heap address as an `Int`.
-- `medaka run` already refuses (`E-PANIC unknown field: x`) because the interpreter
-- resolves fields BY NAME; this restores agreement by refusing EARLIER, at typecheck.
--
-- The guard answers three questions about `f` across the receiver type's
-- constructors (`ctorFieldConflict`): does some constructor withhold `f`, do
-- two constructors that declare it place it at different positions, and do two
-- declare it with different types?  Both emitters read `.f` at the selected
-- constructor's declaration-order index with no tag test, and the access is
-- typed by that constructor's declaration, so any disagreement reads the wrong
-- slot, or reads the right slot at the wrong type, for some value of the type
-- (#1468, #1465, #3726).  A field every constructor declares at ONE position
-- with ONE type has one slot and one type for every value, so the access stays
-- legal.
--
-- The head equality is a cascade guard, not a correctness one.  `te`'s head is
-- compared against the SELECTED record's own result head, so the guard speaks only
-- when the receiver genuinely IS a value of the declaring type.  A receiver of some
-- OTHER type reached this arm through the owner ladder's deliberate
-- "pick-one-so-unify-complains" fall-through and already has its mismatch; adding a
-- constructor-set error on top of it would be noise.  `headTyconMono`'s `None` (an
-- unstamped or non-`TCon` head) decides nothing, per the absence rule
-- `recordCandIsReceiverDecl` documents.
export
fieldSelectionWellTyped : ModuleCtx ->
  Mono ->
  String ->
  RecordInfo ->
  String ->
  Mono ->
  Mono
fieldSelectionWellTyped mctx te rname ri fname ft =
  match ctorFieldConflictHere mctx te rname ri fname
    None => ft
    Some conflict =>
      pushCtorFieldConflict
        mctx
        fname
        (optionOr rname (headTyconNameMono te))
        conflict
      -- Same poisoned placeholder `unknownFieldFresh` returns: the access is already
      -- explained, so don't let its result var pile a second cascade on top.
      let v = freshVar mctx ()
      poisonMismatchVars mctx v v
      v

-- The conflict, if any, among the constructors sharing the receiver's head.
-- `ctorSiblingWithholdingName` is the SAME withheld test
-- `narrowingBlockedByCtorSibling` asks in the multi-owner arm, so the two paths
-- cannot drift about what "a sibling withholds it" means.
ctorFieldConflictHere : ModuleCtx ->
  Mono ->
  String ->
  RecordInfo ->
  String ->
  Option CtorFieldConflict
ctorFieldConflictHere mctx te rname ri fname = match headTyconMono te
  None => None
  Some hk =>
    if Some hk == headTyconMono (recordResultMono ri) then
      ctorFieldConflict mctx hk fname rname
    else
      None

ctorFieldConflict : ModuleCtx ->
  HeadKey ->
  String ->
  String ->
  Option CtorFieldConflict
ctorFieldConflict mctx hk fname rname =
  match ctorSiblingWithholdingName mctx (Some hk) fname rname
    Some sib => Some (CtorWithholds sib)
    None => match ctorsOfHead mctx hk
      Some (ctors@(_ :: _ :: _)) =>
        let held = ctorFieldSlots mctx hk fname ctors
        orElseOpt
          (firstSlotDisagreement held)
          (firstTypeDisagreement mctx.mcGraph fname held)
      _ => None

ctorsOfHead : ModuleCtx -> HeadKey -> Option (List String)
ctorsOfHead mctx hk = match ctorOracleKeyOf (Some hk)
  None => None
  Some tk => oGetCtors mctx.mcCells.matchOracle.value tk

-- Each constructor that declares `fname`, with the field's index in that
-- constructor's declaration-order field list — the index both emitters read —
-- and the constructor's record.
ctorFieldSlots : ModuleCtx ->
  HeadKey ->
  String ->
  List String ->
  List (String, Int, RecordInfo)
ctorFieldSlots mctx hk fname ctors =
  filterMap (ctorFieldSlot mctx hk fname) ctors

ctorFieldSlot : ModuleCtx ->
  HeadKey ->
  String ->
  String ->
  Option (String, Int, RecordInfo)
ctorFieldSlot mctx hk fname k = match ctorRecordOfType mctx hk k
  None => None
  Some ri => map (i => (k, i, ri)) (elemIndex fname (recordFieldNames ri))

firstSlotDisagreement : List (String, Int, RecordInfo) ->
  Option CtorFieldConflict
firstSlotDisagreement [] = None
firstSlotDisagreement ((a, i, _) :: rest) =
  map ((b, j) => CtorSlotsDiffer a i b j) (slotOtherThan i rest)

slotOtherThan : Int -> List (String, Int, RecordInfo) -> Option (String, Int)
slotOtherThan _ [] = None
slotOtherThan i ((b, j, _) :: rest)
  | j /= i = Some (b, j)
  | otherwise = slotOtherThan i rest

-- The first constructor whose declared type for `fname` is not the first
-- constructor's.  Each constructor's record is registered over its OWN
-- parameter variables, so the other constructor's field type is restated over
-- the first's parameters before the two are compared; `data T a = A { x : a } |
-- B { x : a }` agrees.
firstTypeDisagreement : GraphCtx ->
  String ->
  List (String, Int, RecordInfo) ->
  Option CtorFieldConflict
firstTypeDisagreement gctx _ [] = None
firstTypeDisagreement gctx fname ((a, _, ra) :: rest) =
  match omLookup fname (recordFieldMap ra)
    None => None
    Some ta => typeOtherThan gctx fname a ra ta rest

typeOtherThan : GraphCtx ->
  String ->
  String ->
  RecordInfo ->
  Mono ->
  List (String, Int, RecordInfo) ->
  Option CtorFieldConflict
typeOtherThan gctx _ _ _ _ [] = None
typeOtherThan gctx fname a ra ta ((b, _, rb) :: rest) =
  match omLookup fname (recordFieldMap rb)
    Some tb =>
      let (tsub, esub, asub) =
        paramRenaming (recordResultMono rb) (recordResultMono ra) ([], [], [])
      let tbOverA = substMono gctx tsub esub asub tb
      if fieldTypeSame ta tbOverA then
        typeOtherThan gctx fname a ra ta rest
      else
        Some (CtorTypesDiffer a ta b tbOverA)
    None => typeOtherThan gctx fname a ra ta rest

-- Pairs each parameter of `from`'s head application with the argument at the
-- same position of `to`'s — a type, row or authority parameter, each into its
-- own substitution — so substituting restates a type written over `from`'s
-- parameters over `to`'s.
paramRenaming : Mono ->
  Mono ->
  (List (Int, Mono), List (Int, Ref Effvar), List (Int, Authority)) ->
  (List (Int, Mono), List (Int, Ref Effvar), List (Int, Authority))
paramRenaming from to acc = match normalize from
  TApp f1 a1 => match normalize to
    TApp f2 a2 => paramRenaming f1 f2 (renameParam (normalize a1) a2 acc)
    _ => acc
  _ => acc

renameParam : Mono ->
  Mono ->
  (List (Int, Mono), List (Int, Ref Effvar), List (Int, Authority)) ->
  (List (Int, Mono), List (Int, Ref Effvar), List (Int, Authority))
renameParam (TVar c) to (ts, es, qs) = ((tyvarId c, to) :: ts, es, qs)
renameParam (TEff (EffRow [] (Some e1))) (TEff (EffRow [] (Some e2))) (ts, es, qs) =
  (ts, (effvarId e1, e2) :: es, qs)
renameParam (TAuth (AVar q1)) (TAuth q2) (ts, es, qs) =
  (ts, es, (authvarId q1, q2) :: qs)
renameParam _ _ acc = acc

-- One declared type, read the way a field's value is used: the same shape,
-- the same declarations and variables (`monoSameGiven` at the leaves), and the
-- same effect rows and authorities, since a function field read at another
-- constructor's row performs effects its type does not show.  A qualifier on
-- one side only is peeled here rather than in `monoSameGiven`, which erases
-- rows and so is reached only once the left side is a leaf.
fieldTypeSame : Mono -> Mono -> Bool
fieldTypeSame x y = match (normalize x, normalize y)
  (TFun a1 r1 b1, TFun a2 r2 b2) =>
    fieldTypeSame a1 a2 && rowSame r1 r2 && fieldTypeSame b1 b2
  (TApp a1 b1, TApp a2 b2) => fieldTypeSame a1 a2 && fieldTypeSame b1 b2
  (TEff r1, TEff r2) => rowSame r1 r2
  (TQual t1 q1, TQual t2 q2) => fieldTypeSame t1 t2 && authSame q1 q2
  (TAuth q1, TAuth q2) => authSame q1 q2
  (TFun _ _ _, _) => False
  (TApp _ _, _) => False
  (TEff _, _) => False
  (TAuth _, _) => False
  (TQual t1 _, b) => fieldTypeSame t1 b
  (a, TQual t2 _) => fieldTypeSame a t2
  (a, b) => monoSameGiven a b

pushCtorFieldConflict : ModuleCtx ->
  String ->
  String ->
  CtorFieldConflict ->
  Unit
pushCtorFieldConflict mctx fname tname (CtorWithholds sib) =
  pushTypeError
    mctx
    "T-FIELD-NOT-IN-ALL-CTORS"
    (fieldNotInAllCtorsMsg fname tname sib)
pushCtorFieldConflict mctx fname tname (CtorSlotsDiffer a i b j) =
  pushTypeError
    mctx
    "T-FIELD-POSITION-DIFFERS"
    (fieldPositionDiffersMsg fname tname (a, i) (b, j))
pushCtorFieldConflict mctx fname tname (CtorTypesDiffer a ta b tb) =
  pushTypeError
    mctx
    "T-FIELD-TYPE-DIFFERS"
    (fieldTypeDiffersMsg fname tname a ta b tb)

-- ── #3727/#3726: `{ v | f = e }` on a type with more than one constructor ──
--
-- Both emitters rebuild an update as the constructor the typechecker selected,
-- copying the other fields by that constructor's layout; the receiver's own tag
-- is never read.  When the receiver's type has two or more constructors, a value
-- built by any other one comes back as the selected constructor, whatever the
-- field offsets.  `Con { v | f = e }` names the constructor and is not this path.
-- Same cascade guard as `fieldSelectionWellTyped`: only a receiver that really is
-- a value of the selected record's type is asked about.
export
recordUpdateWellTyped : ModuleCtx ->
  Mono ->
  String ->
  RecordInfo ->
  String ->
  Unit
recordUpdateWellTyped mctx bt rname ri fn = match headTyconMono bt
  None => ()
  Some hk =>
    if Some hk
      == headTyconMono (recordResultMono ri) then match ctorsOfHead mctx hk
      Some (ctors@(_ :: _ :: _)) =>
        pushTypeError
          mctx
          "T-UPDATE-MULTI-CTOR"
          (updateMultiCtorMsg
            fn
            (optionOr rname (headTyconNameMono bt))
            rname
            (filterList (/= fn) (recordFieldNames ri))
            ctors)
      _ => ()

-- field_owners: every registry KEY whose RecordInfo declares `fname`,
-- sorted + deduped.  For a plain record the key is its type name; for a
-- named-field variant it's the constructor name, whose
-- field_owners maps to the record's type name and the variant's con_name.
-- The field→owners multimap (fieldOwnersRef) already holds exactly this set of
-- keys, maintained at registration; `sortUniqS` canonicalizes it so the rendered
-- owner-list order (ambiguousFieldMsg / head) is byte-identical to the old walk.
--
-- #1597: the owner list is then REACHABILITY-FILTERED — see `fieldOwnerReachFilter`.
-- This is the one reader of the field→owners multimap that decides ACCEPTANCE, and it
-- is the only one this filter touches.
fieldOwnerNames : ModuleCtx -> String -> List String
fieldOwnerNames mctx fname =
  fieldOwnerReachFilter
    mctx
    (sortUniqS (optionOr [] (omLookup fname mctx.mcCells.fieldOwnersRef.value)))

-- #1597, and it fails open twice over — deliberately, because the owner half of
-- the seed is the LOUD one (zero owners ⇒ `pushUnknownField`, exit 1), so a filter
-- that could empty a non-empty owner set would convert a silent-wrongness family into
-- a false-reject one.
--   1. An owner key the index does not know is KEPT.  Locally minted keys (mangled
--      re-registrations, `where`-scoped records, the flat/single-file driver where
--      `buildDeclEnvs` never ran) have no `deOwnerModules` row and therefore no vote
--      to lose.
--   2. If the filter would remove EVERY owner, the UNFILTERED list is returned.
-- So this predicate can only ever collapse a spurious AMBIGUITY down towards the
-- reader's own candidates; no program that resolved before can stop resolving here.
fieldOwnerReachFilter : ModuleCtx -> List String -> List String
fieldOwnerReachFilter mctx owners =
  match filterList (fieldOwnerReachable mctx) owners
    [] => owners
    kept => kept

fieldOwnerReachable : ModuleCtx -> String -> Bool
fieldOwnerReachable mctx key =
  match omLookup key mctx.mcCells.fieldOwnerModulesRef.value
    None => True
    Some mids => fieldOwnerAnyReachable mctx mids

fieldOwnerAnyReachable : ModuleCtx -> List String -> Bool
fieldOwnerAnyReachable mctx [] = False
fieldOwnerAnyReachable mctx (m :: rest) =
  omHasKey m mctx.mcCells.fieldOwnerReachRef.value
    || fieldOwnerAnyReachable mctx rest

-- Resolve the record (name + info) that owns `fname` for a receiver of type `te`
-- (normalized).
-- (a) receiver head tycon is a known record → that record;
-- (b) receiver is an undetermined var → 0 owners = unknown field, 1 = that one,
--     >1 = ambiguous (push AmbiguousField, return None);
-- (c) receiver is a concrete non-record → first owner (so the later unify raises
--     the usual mismatch), or unknown field if none.
-- On error it pushes the matching type error and returns None.
--
-- Arm (a) does not ask a spelling question, and that is why it alone calls
-- `lookupRecordForReceiver` INSTEAD OF `lookupRecordByName` — see that function.
export
resolveFieldRecord : ModuleCtx -> Mono -> String -> Option (String, RecordInfo)
resolveFieldRecord mctx te fname = match headTyconNameMono te
  Some r => match lookupRecordForReceiver mctx te r
    Some ri => Some (r, ri)
    None =>
      if omHasKey
        (receiverTypeWord te r)
        mctx.mcGraph.abstractRecordTypesRef.value then
        pushTypeError mctx "T-ABSTRACT-FIELD" (abstractFieldMsg r fname)
        None
      else
        resolveFieldByOwners mctx te fname
  None => resolveFieldByOwners mctx te fname

-- ── #1111 Stage A-2 unit A-2.13 (#1319 unit 3): one entry, two questions ────
--
-- `recordByNameRef` is asked two questions that a single bare-`String` key
-- cannot answer separately, and #1376 / #1377 are the two halves of that:
--
--   (1) a SPELLING question — "which declaration does the `Cfg` written in THIS
--       module's source denote?"  Asked by `inferPatRec`, `inferRecordCreate`
--       and `inferVariantUpdate`, each of which starts from a name the module
--       wrote.  The bare key plus unit 2's per-module scope overlay
--       (`applyRecordScopeOverrides`) is the RIGHT instrument for it: the answer
--       is a property of what this module imported and declared.
--   (2) an IDENTITY question — "given a receiver whose type is already inferred
--       and already carries its origin, which `RecordInfo` describes it?"  Asked
--       by `resolveFieldRecord`'s arm (a) ONLY.  Nothing the module spelled is
--       an input: `mkZ.beta` is decided entirely by `mkZ`'s type.
--
-- Before this unit both questions read `lookupRecordByName`, so whatever decided
-- the single entry answered both the same way — and a module that NAMES one
-- declaration while HOLDING a value of the other cannot get both right.
--
-- The split is not mine — it is the spec's, and the implementation was not
-- following it.  `docs/spec/DICT-SEMANTICS.md` §8 I4 qualification 2 draws exactly
-- this line, in one sentence, and names both sides:
--
--     "It applies only to occurrences resolved BY NAME.  A record-field selection
--      `r.f` is resolved by the *type* of `r`, not by the spelling `f` … Record
--      *construction* and record *patterns* name the record, and are ambiguous
--      exactly when that name is."
--
-- So arm (a) is spec'd to resolve by the receiver's TYPE and was resolving by a
-- per-module decision over a bare spelling; the other three readers are spec'd to
-- resolve by name and do.  The diagnostic the collision produced was itself the
-- evidence the information was in hand at the point of failure — it could name
-- BOTH modules ("one comes from module 'zrmod', the other from 'armod'") while
-- selecting by neither.
--
-- THIS IS A SPLIT, NOT A GUARD AT A READ SITE, and the distinction is the one
-- `.claude/workstreams/TYPECHECK.md`'s standing gate asks about (its
-- "does the fix change the KEY, or add a guard at one read site?"
-- discriminator).  Question (2) now has its OWN key — the receiver's `Ident`,
-- selected out of the identity-keyed rows of `universeRecordPop` — and
-- question (1) keeps the spelling key it always had.  One read site moves
-- because exactly one read site asks question (2); a second site asking it would
-- call this same function.  What is NOT claimed: `recordByNameRef` is still
-- bare-keyed, and it is still the floor whenever the receiver carries no
-- identity.  This unit does not retire the overlay (that is #1319 unit 4) nor
-- the duplication (#1288 is the deleter, as for units 1 and 2).
--
-- The floor is reached by miss, never by fallback-on-ambiguity.  Three
-- honest-absence cases fall through to `lookupRecordByName`, all of them
-- "no identity was available", none of them "two candidates matched":
--   * the receiver head carries no identity (`headKeyIdent` = `None`) — the
--     flat/loader-less driver path, where NO declaration is stamped (#1115 /
--     E-1), and the `HkRigid` §8 I6.1 residual;
--   * the key has no companion row — the module's OWN records (the companion is
--     grown from `pubDecls` at the END of a module's arm, so a module never sees
--     itself in it) and every non-`ConNamed` declaration;
--   * no candidate's type identity equals the receiver's — e.g. a receiver whose
--     head is the TYPE of a named-field variant (`data T = | Cfg { … }`, key
--     `Cfg`, type `T`), which arm (a) misses today too and which the
--     field→owners path answers.
-- Two candidates can never BOTH match: a match requires equal
-- `(module, type name)`, and one module declaring two types of one name is a
-- duplicate-definition error.  So this cannot invent an ambiguity resolution.
lookupRecordForReceiver : ModuleCtx -> Mono -> String -> Option RecordInfo
lookupRecordForReceiver mctx te r =
  match recordForReceiverIdent mctx.mcGraph te r
    Some ri => Some ri
    None => match lookupRecordByName mctx r
      Some ri => if recordOfOtherType te ri then None else Some ri
      None => None

-- The floor answers by the record's NAME, and a program's own type may share a
-- prelude record's name (#3465: a program's `RField` beside the prelude's).  A
-- receiver whose type carries an identity is never given a record of a
-- different type; it falls to the field-owner path, which finds its own.  With
-- no identity on either side (the flat path) the floor stands.
recordOfOtherType : Mono -> RecordInfo -> Bool
recordOfOtherType te (RecordInfo _ _ res _ _) = match (
  receiverTypeIdent te,
  receiverTypeIdent res,
)
  (Some (Ident _ wo wn), Some (Ident _ ro rn)) => not (wn == rn && wo == ro)
  _ => False

-- The identity half.  `universeRecordPop`'s rows are indexed by the bare registry
-- key — an INDEX into a candidate list, not the selector; the selector is the
-- identity comparison below, which is why a collided key keeps both rows here
-- where `recordByNameRef` keeps one.
--
-- The cheap lookup runs first, deliberately.  This is on the path of EVERY
-- `.field` access whose receiver head is a known record — not only the colliding
-- ones — so the ordering is a cost decision, not a style one: `omLookup`
-- allocates nothing, while `receiverTypeIdent` mints a `HeadKey` (and, inside it,
-- an `Ident`).  A key with no companion row therefore pays one map lookup and
-- allocates nothing at all.  Do not "simplify" by projecting the head first.
recordForReceiverIdent : GraphCtx -> Mono -> String -> Option RecordInfo
recordForReceiverIdent gctx te r =
  match omLookup r (spRows gctx.crossRun.universeRecordPop.value)
    None => None
    Some cs => match receiverTypeIdent te
      None => None
      Some ident => recordCandForType ident cs

-- ROUTED THROUGH `headTyconMono`, NOT A FRESH `Mono.TCon` PATTERN.  Reading
-- the origin field directly here would add a second site to the `Mono.TCon`
-- origin-read ratchet in `test/typecheck_compiler_source.sh` and duplicate the
-- head-node classification `headTyconMono`/`headTyconNameMono` owe each other.
-- `headKeyIdent` (`types/registry.mdk`) is the accessor; its `None` collapses
-- "rigid" and "no module id yet" because at a ROW lookup both mean the same
-- thing — the derivation is written at that function.
-- The receiver's type word (`headKeyTag`), else its bare head name.
receiverTypeWord : Mono -> String -> String
receiverTypeWord te r = match headTyconMono te
  Some hk => headKeyTag hk
  None => r

receiverTypeIdent : Mono -> Option Ident
receiverTypeIdent te = match headTyconMono te
  Some hk => headKeyIdent hk
  None => None

recordCandForType : Ident ->
  List (Ident, String, RecordInfo) ->
  Option RecordInfo
recordCandForType _ [] = None
recordCandForType want ((ci, tyName, ri) :: rest)
  | recordCandIsType want ci tyName = Some ri
  | otherwise = recordCandForType want rest

-- Is candidate `ci` (stored under its CONSTRUCTOR identity, beside the name of
-- the TYPE it builds) the declaration the receiver identity `want` names?
--
-- A candidate carries `Ident NsCtor o cn` plus `tyName`, because that is what
-- `insertRecordRow` has in hand; the receiver's head names the TYPE, so the
-- comparison is `(owning type name, declaring module)`.  `o` is the same
-- `dataOrigin` `registerRecordInfoKeyed` put in the record's result type, which
-- is what `headTyconMono` projects back out of a value of that record — so this
-- compares the two ends of one declaration.
--
-- Retraction (#1381 round-2 review, finding 1).  The two conjuncts are not
-- separately measured, and the type-name one cannot be — by any fixture that
-- asserts a VALUE or an ACCEPTANCE.  An earlier version of this comment claimed
-- "each conjunct is measured, by a different fixture, and neither is measured by
-- the other's"; the counterfactual that would have shown it false is the one
-- that was never run.  What IS measured, by a separate cold rebuild each:
--   * drop `cio == wio` (type name only) → `record_receiver_ident_named_vs_held/`
--     goes RED; `…_value_only/` and `…_bystander/` stay GREEN.  So the
--     DECLARING-MODULE conjunct is load-bearing and is measured.
--   * drop BOTH (first candidate wins) → `…_bystander/` goes RED at `mkP.px`.
--   * drop `tyName == wname` (module only) → nothing in the tree goes red.  All
--     52 `diff_compiler_llvm_modules` cells pass, `make check-self` is clean, and
--     five purpose-built probes with ≥2 differently-ordered fields (so a wrong
--     pick is observable rather than index-0-invisible) print the hand-derived
--     value on the EXECUTED native binary.
--   * stub the whole selection to `None` → both drain fixtures RED, bystander
--     GREEN (which is what makes it a bystander and not a second drain).
--
-- Why no fixture can discriminate it — the derivation, so the next reader does
-- not re-run the rebuild.  The caller looks the candidate list up under
-- `r = headTyconNameMono te`, while `wname` comes from `headTyconMono te` →
-- `headKeyOfCon o n` → `Ident NsType o n`: the SAME `n`.  So `wname == r == the
-- outer key`, always, and `tyName == wname` reduces to "this candidate's owning
-- type name equals the registry key it is filed under" — i.e. "this candidate is
-- a plain record, not a named-field variant of a differently-named type".  When
-- the two conjuncts disagree the candidate is `(M, tyName = Y)` under key `r`
-- with `Y /= r` while the receiver's head is `(M, r)`; that candidate's result
-- head is `(M, Y)`, which can never unify with `(M, r)`.  And the floor
-- `lookupRecordByName r` can only return a record whose CONSTRUCTOR is `r`,
-- which is likewise never the receiver's own record.  Both arms reject.  So the
-- conjunct can change neither an accepted program's value nor accept vs reject.
--
-- It is observable in diagnostic text, in exactly one shape, and there it makes
-- the message worse.  Measured: `amod` declaring BOTH `data Tag = TA | TB` and
-- `data Box = | Tag { bx : Int }`, `zmod` declaring `data Tag = { tx : Int }`,
-- receiver `aTag : amod.Tag`, access `aTag.bx`.  Exit 1 either way.  With both
-- conjuncts: `Type mismatch: Tag vs Tag — … 'amod' … 'zmod'` plus a spurious
-- `Field 'bx' does not belong to record 'Tag'`.  With the module conjunct alone:
-- one `Type mismatch: Tag vs Box`, naming the record actually selected.  No
-- fixture pins this, deliberately — a golden here would enshrine the worse
-- message as the expected one.
--
-- So why keep it.  Deleting it moves the whole correctness of the selector onto
-- "a module contributes at most one candidate per registry key", which is true
-- only because two constructors of one name in one module is a `Duplicate
-- constructor` error — a property enforced by a DIFFERENT subsystem and asserted
-- nowhere near here.  Keeping the conjunct costs one monomorphic string compare
-- and keeps the comparison a direct expression of the question being asked.  It
-- is belt-and-braces, and this comment says so instead of claiming a measurement.
--
-- Name first, and monomorphic — the discipline `tabKeyEq` states at its own
-- definition and `compiler/AGENTS.md` states for hot helpers.  It also allocates
-- nothing, which is why the candidate identity is compared component-wise rather
-- than rebuilt as an `Ident NsType …` and `==`-ed: this runs per candidate, per
-- field access.
--
-- This is stricter than `unify`'s head test, and the direction is the point.
-- `sameTyConHead` (`frontend/ast.mdk`) lets an ABSENT origin match anything,
-- because it answers an ACCEPTANCE question where a false reject refuses a valid
-- program.  This answers a LOOKUP, where a false hit is silent wrongness — so
-- absence must never match, and it cannot: `headKeyIdent` yields no `Ident` for
-- an unstamped head, and this function is not reached.  That inversion is the
-- same one `ifaceIdMatches` and `sameTyConHead` document at each other.
recordCandIsType : Ident -> Ident -> String -> Bool
recordCandIsType (Ident _ wio wname) (Ident _ cio _) tyName =
  tyName == wname && cio == wio

-- Does this candidate's `RecordInfo` describe the declaration the RECEIVER's head
-- names?  `rk` is the receiver's key, projected once by the caller rather than per
-- candidate; `headTyconMono` produces both sides rather than a bespoke match, so
-- no new origin-binding `Mono.TCon` pattern enters the set
-- `test/typecheck_compiler_source.sh` pins.
--
-- The equality is `HeadKey`'s DERIVED one, and that is the fail-safe: `HeadKey`
-- embeds `TabKey`, whose `TkIdent`/`TkBare` split `types/registry.mdk` defines so a
-- key with identity can never equal one without.  So a receiver whose head was never
-- stamped matches ZERO candidates — not "the first one" — and the caller falls back
-- to today's ladder unchanged.  An absent identity therefore decides nothing, which
-- is the same absence-makes-no-claim rule `sameTyConHead` owns one layer down.
recordCandIsReceiverDecl : Option HeadKey -> (String, RecordInfo) -> Bool
recordCandIsReceiverDecl rk (_, ri) = rk == headTyconMono (recordResultMono ri)

resolveFieldByOwners : ModuleCtx ->
  Mono ->
  String ->
  Option (String, RecordInfo)
resolveFieldByOwners mctx te fname =
  let owners = fieldOwnerNames mctx fname
  match ownerDeclOfReceiver mctx te fname owners
    Some pair => Some pair
    None => match owners
      [] =>
        pushUnknownField mctx fname "<unknown>"
        None
      _ => match normalize te
        TVar _ => resolveFieldUnknownReceiver mctx fname owners
        _ => resolveFieldAmbiguous mctx te fname owners

-- An unannotated receiver says nothing about its type, so the candidates are the
-- record declarations visible here that declare `fname`.  An owner key names a
-- SPELLING, and `recordByNameRef` holds one declaration per spelling: the one this
-- module's own source means.  A value reaching `.fname` need not be of that
-- declaration (a named-field variant may share its constructor's spelling with
-- another module's record), so each key is expanded to every declaration filed
-- under it, and a declaration that does not declare `fname` is dropped.
--
-- The constructors of one type count once: the selection is a TYPE question, and
-- `fieldSelectionWellTyped` decides afterwards whether that type's constructors
-- agree about the field's slot.  Two types left is an ambiguity, reported at the
-- access.  No candidate at all keeps the owner-list answer.
resolveFieldUnknownReceiver : ModuleCtx ->
  String ->
  List String ->
  Option (String, RecordInfo)
resolveFieldUnknownReceiver mctx fname owners =
  match visibleFieldDecls mctx fname owners
    [pair] => Some pair
    [] => match owners
      [r] => pairRecordByName mctx r
      _ =>
        pushTypeError mctx "T-AMBIGUOUS-FIELD" (ambiguousFieldMsg fname owners)
        None
    cands =>
      pushTypeError
        mctx
        "T-AMBIGUOUS-FIELD"
        (ambiguousFieldDeclsMsg fname owners cands)
      None

-- The declarations under the owner keys that declare `fname`, reachable from this
-- module, one per type.  The floor row comes first under each key so that, when it
-- is one of the population's rows, the `RecordInfo` this module registered is the
-- one kept.
visibleFieldDecls : ModuleCtx ->
  String ->
  List String ->
  List (String, RecordInfo)
visibleFieldDecls mctx fname owners =
  dedupBy
    fieldDeclTypeKey
    (fieldDeclReachFilter mctx (flatMap (keyFieldDecls mctx fname) owners))

keyFieldDecls : ModuleCtx -> String -> String -> List (String, RecordInfo)
keyFieldDecls mctx fname k =
  let rows =
    map
      (c => (k, recordCandInfo c))
      (spCandsOf k mctx.mcGraph.crossRun.universeRecordPop.value)
  let floor = match pairRecordByName mctx k
    Some pair => [pair]
    None => []
  filterList (c => omHasKey fname (recordFieldMap (snd c))) (floor ++ rows)

-- Same fail-open shape as `fieldOwnerReachFilter`: a declaration whose module is
-- unknown is kept, and a filter that would remove every candidate removes none.
fieldDeclReachFilter : ModuleCtx ->
  List (String, RecordInfo) ->
  List (String, RecordInfo)
fieldDeclReachFilter mctx cands =
  match filterList (fieldDeclReachable mctx) cands
    [] => cands
    kept => kept

fieldDeclReachable : ModuleCtx -> (String, RecordInfo) -> Bool
fieldDeclReachable mctx (_, ri) = match recordOwnerModule ri
  None => True
  Some mid =>
    let reach = mctx.mcCells.fieldOwnerReachRef.value
    omSize reach == 0 || omHasKey mid reach

-- The declaring type's tag, so two named-field constructors of one type collapse.
fieldDeclTypeKey : (String, RecordInfo) -> String
fieldDeclTypeKey (k, ri) = match headTyconMono (recordResultMono ri)
  Some hk => headKeyTag hk
  None => k

-- #1383: a concrete receiver's field is answered by the receiver's own
-- declaration.  The floor `recordByNameRef` keeps one row per bare key, so when a
-- named-field variant (`data Holder = | Plain { hx }`) shares its key with
-- another module's record (`data Plain = { px }`), the floor can hold the other
-- declaration and the ladder below would pick it by registration order.  The
-- identity companion keeps every module's row under that key; the receiver's
-- `(declaring module, type name)` picks among them.
--
-- The answer is `(k, ri)` with `ri` read from the companion row filed under `k`,
-- so the stamp `stampedRecordHead k ri` names the selected declaration's own
-- module: the emitters apply that declaration's layout.
--
-- The matches are collapsed by declaring type (`fieldDeclTypeKey`): every match
-- is a constructor of the receiver's one type, so two owner keys naming two of its
-- constructors are one answer, and `fieldSelectionWellTyped` decides afterwards
-- whether they agree about the field's slot.
--
-- Declines (answers `None`, so the ladder runs unchanged) when the receiver
-- carries no identity, when no owner key holds the receiver's declaration, or when
-- a sibling constructor of the receiver's type withholds the field.  The sibling
-- case is the multi-`ConNamed`-variant shape `narrowedPick` refuses: the
-- receiver's type does not say which layout applies.
ownerDeclOfReceiver : ModuleCtx ->
  Mono ->
  String ->
  List String ->
  Option (String, RecordInfo)
ownerDeclOfReceiver mctx _ _ [] = None
ownerDeclOfReceiver mctx te fname owners = match receiverTypeIdent te
  None => None
  Some ident =>
    match dedupBy fieldDeclTypeKey (ownerDeclMatches mctx.mcGraph ident owners)
      [(k, ri)] =>
        if narrowingBlockedByCtorSibling mctx (headTyconMono te) fname k then
          None
        else
          Some (k, ri)
      _ => None

-- Every owner key whose companion rows hold the declaration `ident` names, with
-- that row's `RecordInfo`.
ownerDeclMatches : GraphCtx -> Ident -> List String -> List (String, RecordInfo)
ownerDeclMatches gctx _ [] = []
ownerDeclMatches gctx ident (k :: rest) =
  match omLookup k (spRows gctx.crossRun.universeRecordPop.value)
    None => ownerDeclMatches gctx ident rest
    Some cs => match recordCandForType ident cs
      None => ownerDeclMatches gctx ident rest
      Some ri => (k, ri) :: ownerDeclMatches gctx ident rest

-- A concrete receiver that is not itself a known record: one owner is that owner;
-- several are narrowed by the receiver's own declaration identity, and only if that
-- does not land on exactly one owner fall back to picking the first owner so the
-- later unify surfaces the type mismatch (mirrors the oracle's two `_` sub-branches).
resolveFieldAmbiguous : ModuleCtx ->
  Mono ->
  String ->
  List String ->
  Option (String, RecordInfo)
resolveFieldAmbiguous mctx _ _ [r] = pairRecordByName mctx r
resolveFieldAmbiguous mctx te fname owners =
  resolveFieldOwnersNarrowed mctx te fname owners

-- ── #1216 / #1382: the multi-owner arm stops answering by sort order ──────────
-- `sortUniqS` makes `head owners` a MODULE-NAME SORT, so before this the concrete
-- arm decided which record a `.field` access means by the alphabetical order of the
-- declaring modules — measured on the emit path as `CFieldAccess (CVar
-- "zwrap__mkZ") "a" "awrap__Cfg"`: zwrap's value, awrap's record, applied
-- faithfully by the backend.
--
-- The narrowing asks the one question the bare key cannot: which DECLARATION does
-- the receiver's own head name?  It ADOPTS `recordCandIsReceiverDecl` — the same
-- comparator the receiver-declaration lookups share — so both sides go
-- through `headTyconMono` and the comparison is on `HeadKey`, not on the string
-- every candidate here spells identically by construction.
--
-- What this has, and what it measurably does not — the second and third bullets
-- below replace three claims that shipped with the original narrowing and were
-- **measured false** by the adversarial review of `S-record-pairing-identity`.
-- Keep them stated as measurements; the false versions cost a reviewer a round and
-- were the stated reason the flat path carried no test cell.
--   * Absence decides nothing.  `HeadKey` embeds `TabKey`, whose `TkIdent`/`TkBare`
--     split means a key carrying identity can never equal one that does not.  A
--     receiver whose head was never stamped at all matches ZERO candidates and
--     falls through to exactly today's answer — never "the first one".
--   * It is live on the flat/single-file driver.  The retracted claim was that
--     the retired unstamped driver, where every decl was `TkBare`, matched zero candidates.
--     FALSE: `TkBare Ns String` CARRIES the type name, so two bare keys naming the
--     same type ARE equal, and the narrowing selects there.  Measured: `flat/p.mdk`
--     (two single-ctor records sharing field `tag`, concrete receiver) goes from a
--     base-arm `Type mismatch: Beta vs Alpha` to the hand-derived correct `42`.
--     That direction is CORRECT and is kept; `test/llvm_fixtures_modules/
--     record_owner_ctor_ambiguity/` carries the flat cell so it stays graded.
--   * It can widen an accept, which is why the sibling guard exists.  The
--     retracted claim was that "anything other than exactly one surviving candidate
--     returns today's answer, so it can never widen an accept" — the premise is
--     true and the conclusion does not follow: a singleton survivor is itself a new
--     accept where the old ladder's `head` pick reached a unify mismatch.  For
--     SINGLE-constructor records that widening is the fix (`flat`, `#1216`).  For a
--     MULTI-`ConNamed`-variant type it was unsound, exactly as the `#1319 UNIT 2`
--     note above predicted for a type-keyed record index: `recordCandIsReceiverDecl`
--     compares RESULT-TYPE heads while `registerRecordInfoKeyed` registers one
--     `RecordInfo` per named-field CONSTRUCTOR, so for
--     `data T = Zed { x } | Oth { y }` every candidate of type `T` compares equal to
--     an `Oth` receiver and the filter lands on `Zed` with full confidence.
--     Measured on `ada2bd57`: `(Oth …).x` went from a base-arm `exit 1` on
--     check/run/build to `check` exit 0 and a BUILT BINARY printing `99` — a
--     loud→silent transition.  `narrowingBlockedByCtorSibling` below is the repair.
--   * It cannot turn nothing into something.  Every candidate is built by a
--     SUCCESSFUL `lookupRecordByName`, and the fall-through is byte-for-byte the
--     old expression, so no program that resolved to `None` here can now resolve to
--     `Some`.
--
-- The survivors are collapsed by declaring type (`fieldDeclTypeKey`, as in the
-- unannotated-receiver path): the named-field constructors of the receiver's type
-- are one candidate, and `fieldSelectionWellTyped` decides afterwards whether they
-- agree about the field's slot and type.  Left uncollapsed, two constructors of
-- one type are two survivors, and the answer becomes the sorted `head owners`,
-- which depends on how an unrelated type's constructor is spelled.
--
-- One mint of the receiver's key for the whole filter, not one per candidate, for the
-- reason `types/registry.mdk` gives against re-minting a `TabKey` per lookup
-- (`tabKeyOf` → `mkIdent` → `identOriginOf` allocates on the way).
resolveFieldOwnersNarrowed : ModuleCtx ->
  Mono ->
  String ->
  List String ->
  Option (String, RecordInfo)
resolveFieldOwnersNarrowed mctx te fname owners =
  let rk = headTyconMono te
  narrowedPick
    mctx
    rk
    fname
    owners
    (dedupBy
      fieldDeclTypeKey
      (filterList (recordCandIsReceiverDecl rk) (ownerCandidates mctx owners)))

-- The singleton gate, plus the guard the comparator's granularity requires.  A
-- lone survivor is trusted ONLY when the receiver's type does not also have a
-- named-field constructor that withholds this field: a value of type `T` carries no
-- static constructor tag, so where two constructors of `T` disagree about `fname`
-- the receiver's TYPE cannot say which layout applies, and selecting is guessing.
-- Anything else — zero survivors, several survivors, or a blocked singleton —
-- returns the pre-narrowing answer byte-for-byte, the same `_ =>` fall-through the
-- original arm had.
narrowedPick : ModuleCtx ->
  Option HeadKey ->
  String ->
  List String ->
  List (String, RecordInfo) ->
  Option (String, RecordInfo)
narrowedPick mctx rk fname _ [(k, ri)]
  | not (narrowingBlockedByCtorSibling mctx rk fname k) = Some (k, ri)
narrowedPick mctx _ _ owners _ =
  pairRecordByName mctx (optionOr "" (head owners))

-- Is there ANOTHER registered named-field constructor sharing the survivor's
-- RESULT head that does NOT declare `fname`?  That is precisely the
-- multi-`ConNamed`-variant shape whose layout the receiver's type underdetermines.
-- A record re-registered under a second key is excluded by construction: it
-- declares `fname` too, so it fails the withholds test (and it would already be a
-- second survivor, since `fieldOwnersRef` is written in lockstep with
-- `recordByNameRef` by `registerRecordInfoKeyed`).
-- Cost: one pass over the record registry, taken ONLY when the filter produced a
-- singleton — i.e. in the give-up arm of a multi-owner field access, never on the
-- exact-hit path.
narrowingBlockedByCtorSibling : ModuleCtx ->
  Option HeadKey ->
  String ->
  String ->
  Bool
narrowingBlockedByCtorSibling mctx rk fname survivorKey =
  isSome (ctorSiblingWithholdingName mctx rk fname survivorKey)

-- The same walk, answering with the offending key rather than a bare `Bool` — #1468's
-- diagnostic has to NAME the constructor, and the Bool above is now `isSome` of this
-- so the two callers cannot drift about what "a sibling withholds it" means.
--
-- #1468: the candidate list is the FULL constructor list of the receiver's type, from
-- the compiler's own ctor oracle (`matchOracle`'s `typeCtors`, built from every
-- `Variant` of every `data` decl regardless of shape) via `oGetCtors`, keyed by
-- `TabKey` and reachable from `rk : Option HeadKey` through `ctorOracleKeyOf`.
-- `recordByNameRef` is no source: `registerRecordInfoKeyed` populates it only for
-- `ConNamed` variants, so a positional (`ConPos`) or nullary sibling of the same type
-- could never be found "withholding" the field.
ctorSiblingWithholdingName : ModuleCtx ->
  Option HeadKey ->
  String ->
  String ->
  Option String
ctorSiblingWithholdingName mctx None _ _ = None
ctorSiblingWithholdingName mctx (Some hk) fname survivorKey =
  match ctorsOfHead mctx hk
    None => None
    Some ctors => firstCtorSiblingWithholding mctx hk fname survivorKey ctors

-- The reader's key mint for `matchOracle`'s `typeCtors`, and it is **not**
-- `headTabOf`.  `typeCtors` is keyed by DECLARATION IDENTITY (`frontend/exhaust.mdk`,
-- oracle-identity leaf L1): its rows are minted `tabKeyOf NsType <that decl's own
-- dataOrigin> <tyname>`, so a module-stamped `data T` writes a `TkIdent` row.
-- `headTabOf` goes through `dispHeadTab hk = TkBare NsType (headKeyName hk)`, which
-- flattens EVERY head to `TkBare` because the dispatch head-buckets are SPELLING-keyed
-- (the #1317 T1 rule).  `tabKeyEq` never equates a `TkBare` lookup with a `TkIdent`
-- row, so keying this table through `headTabOf` would miss on every module-stamped
-- type, and both `None` arms of `ctorSiblingWithholdingName` fail OPEN (the narrowing is
-- trusted and the singleton survivor accepted).  A single-file program hides the miss:
-- unstamped decls mint `TkBare` too, so the wrong mint agrees by accident; the
-- pin is the cross-module fixture
-- `test/analyze_project_fixtures/record_ctor_sibling_blocks_narrowing/main_rejects.mdk`
-- (`T-TYPE-MISMATCH: Type mismatch: T vs U`).
--
-- The mint below is `matchCol0Type`'s, the other `oGetCtors` reader in this file, minus
-- the arms it needs only because it starts from a `Mono`: keep `HkDecl`'s own `TabKey`,
-- and refuse to key a rigid head at all.  §8 I6.1: a type PARAMETER is not a
-- declaration; `matchCol0Type`'s `TkBare NsType n` for that case is a key no writer can
-- have filled, so `None` here is the same miss without minting a forgery to reach it.
ctorOracleKeyOf : Option HeadKey -> Option TabKey
ctorOracleKeyOf None = None
ctorOracleKeyOf (Some hk) = headKeyDecl hk

firstCtorSiblingWithholding : ModuleCtx ->
  HeadKey ->
  String ->
  String ->
  List String ->
  Option String
firstCtorSiblingWithholding mctx _ _ _ [] = None
firstCtorSiblingWithholding mctx hk fname skey (k :: rest)
  | k == skey = firstCtorSiblingWithholding mctx hk fname skey rest
  | ctorSiblingWithholds mctx hk fname k = Some k
  | otherwise = firstCtorSiblingWithholding mctx hk fname skey rest

-- `oGetCtors` already scopes the candidate list to the receiver's own type
-- (via the `TabKey` lookup above), so this does not re-check the
-- head itself — only whether THIS constructor declares `fname`.  A name with
-- no `RecordInfo` of this type is a positional or nullary constructor: it
-- declares no named field, so it unconditionally withholds `fname`.
ctorSiblingWithholds : ModuleCtx -> HeadKey -> String -> String -> Bool
ctorSiblingWithholds mctx hk fname k = match ctorRecordOfType mctx hk k
  Some ri => isNone (omLookup fname (recordFieldMap ri))
  None => True

-- The `RecordInfo` constructor `k` of the type `hk` declares.  `k` is a
-- spelling, and the bare-keyed floor `recordByNameRef` keeps one row per
-- spelling, so a same-spelled constructor of another module's type can own it.
-- The identity companion is asked first (as `ownerDeclMatches` does), and a
-- floor row is accepted only when its result head IS `hk`.
ctorRecordOfType : ModuleCtx -> HeadKey -> String -> Option RecordInfo
ctorRecordOfType mctx hk k = match ctorRecordFromCompanion mctx.mcGraph hk k
  Some ri => Some ri
  None => match lookupRecordByName mctx k
    Some ri =>
      if recordCandIsReceiverDecl (Some hk) (k, ri) then Some ri else None
    None => None

ctorRecordFromCompanion : GraphCtx -> HeadKey -> String -> Option RecordInfo
ctorRecordFromCompanion gctx hk k = match headKeyIdent hk
  None => None
  Some ident => match omLookup k (spRows gctx.crossRun.universeRecordPop.value)
    None => None
    Some cs => recordCandForType ident cs

-- Each owner key paired with its `RecordInfo`; a key with no entry is dropped
-- rather than defaulted, so the filter above only ever sees real declarations.
ownerCandidates : ModuleCtx -> List String -> List (String, RecordInfo)
ownerCandidates mctx [] = []
ownerCandidates mctx (key :: rest) = match lookupRecordByName mctx key
  Some ri => (key, ri) :: ownerCandidates mctx rest
  None => ownerCandidates mctx rest

pairRecordByName : ModuleCtx -> String -> Option (String, RecordInfo)
pairRecordByName mctx r = map (ri => (r, ri)) (lookupRecordByName mctx r)

pushUnknownField : ModuleCtx -> String -> String -> Unit
pushUnknownField mctx fname rname =
  pushTypeError mctx "T-UNKNOWN-FIELD" (unknownFieldMsg fname rname)

-- `declared`: the record's own field names, so a genuine typo (`aeg` for
-- `age`) can be suggested (ERROR-QUALITY dim F).  When a close-enough
-- candidate exists the error gets a structured `help` + a machine `fix` that
-- replaces the bad field name's span with the suggestion; otherwise unchanged.
unknownFieldFresh : ModuleCtx -> String -> String -> List String -> Mono
unknownFieldFresh mctx fname rname declared =
  pushUnknownFieldMaybeSuggest mctx fname rname declared
  let v = freshVar mctx ()
  -- The field error already explained this access; poison its result
  -- var so a downstream `debug`/method use doesn't pile on a secondary
  -- `ambiguous instance` cascade (record_wrong_field).
  poisonMismatchVars mctx v v
  v

pushUnknownFieldMaybeSuggest : ModuleCtx ->
  String ->
  String ->
  List String ->
  Unit
pushUnknownFieldMaybeSuggest mctx fname rname declared =
  match suggestField fname declared
    None => pushTypeError mctx "T-UNKNOWN-FIELD" (unknownFieldMsg fname rname)
    Some sug =>
      pushTypeErrorHelpFixAt
        mctx
        "T-UNKNOWN-FIELD"
        mctx.mcLoc
        (unknownFieldMsg fname rname ++ "; did you mean `\{sug}`?")
        "did you mean `\{sug}`?"
        (fieldFixFrom mctx.mcLoc fname sug)

-- "did you mean" for a record field: nearest declared field name by
-- Levenshtein distance, within a fixed distance of 2.  Skip names < 3 chars
-- (too noisy at that length, same floor as resolve.mdk's `suggestName`).
-- Unlike `suggestName` — which searches EVERY in-scope name and so scales its
-- threshold down with length to avoid noise in a large candidate pool — the
-- candidate pool here is one record's OWN declared fields (typically a
-- handful), so a flat distance-2 budget is safe: it's what's needed to catch
-- a two-letter transposition (`aeg` vs `age`, distance 2) without the
-- length-scaled cap resolve.mdk uses (which would reject that exact case:
-- min(2, max(1, 3/3)) = 1).  Ties favor the lexicographically-first candidate.
-- A small local copy rather than importing resolve.mdk's `suggestName`, which
-- would cycle (nothing here imports resolve.mdk today, and this file is a
-- dependency of the pipeline stage that runs after it).
suggestField : String -> List String -> Option String
suggestField fname declared
  | stringLength fname < 3 = None
  | otherwise = map fst (bestFieldCandidate fname 2 declared None)

bestFieldCandidate : String ->
  Int ->
  List String ->
  Option (String, Int) ->
  Option (String, Int)
bestFieldCandidate _ _ [] acc = acc
bestFieldCandidate fname lim (c :: cs) acc
  | c == fname = bestFieldCandidate fname lim cs acc
  | editDistance fname c > lim = bestFieldCandidate fname lim cs acc
  | otherwise =
    bestFieldCandidate
      fname
      lim
      cs
      (keepBetterField c (editDistance fname c) acc)

keepBetterField : String -> Int -> Option (String, Int) -> Option (String, Int)
keepBetterField c d None = Some (c, d)
keepBetterField c d (Some (bc, bd)) =
  if d < bd || d == bd && c < bc then Some (c, d) else Some (bc, bd)

-- push the message + return a fresh placeholder type so the continued path stays
-- in a valid state (the oracle accumulate-and-continue analog for these shapes).
export
unknownRecordFresh : ModuleCtx -> String -> Mono
unknownRecordFresh mctx name =
  pushTypeError mctx "T-UNKNOWN-RECORD" (unknownRecordMsg name)
  freshVar mctx ()

export
firstFieldName : List FieldAssign -> Option String
firstFieldName [] = None
firstFieldName ((FieldAssign fn _) :: _) = Some fn

-- Instantiate ONLY the result type, returning the shared param substitution so the
-- caller can instantiate individual fields on demand (via the field index).  The
-- fresh-var allocation is identical to `instantiateRecordOpening` (both call `freshSubst
-- paramIds`); only the per-field `substMono` trees for UNACCESSED fields are skipped,
-- and those allocate no fresh tyvars, so tyvar numbering is byte-identical.
export
instantiateRecordShared : ModuleCtx -> RecordInfo -> (RecordSubst, Mono)
instantiateRecordShared mctx (RecordInfo paramIds authIds result fields _) =
  let subst = freshSubst mctx paramIds
  let cells = recordAuthCells authIds result fields
  let asub =
    map (id => (id, sharedAuthority mctx id (IdMap.get id cells))) authIds
  (RecordSubst subst asub, substMono mctx.mcGraph subst [] asub result)

-- An update repacks a field under an existential binder only where it
-- replaces every field that mentions the binder: the value's index is then
-- the replacement's own.  Replacing some of them would leave one binder
-- naming two values at different authorities, so that is refused.  A binder
-- none of the assigned fields mentions is untouched and, as at a read,
-- recovers the top.
export
instantiateRecordUpdate : ModuleCtx ->
  String ->
  RecordInfo ->
  List String ->
  (RecordSubst, Mono)
instantiateRecordUpdate mctx rname (RecordInfo paramIds authIds result fields _) assigned =
  let subst = freshSubst mctx paramIds
  let cells = recordAuthCells authIds result fields
  let asub =
    map
      (id => (
        id,
        updateAuthority mctx rname fields assigned id (IdMap.get id cells),
      ))
      authIds
  (RecordSubst subst asub, substMono mctx.mcGraph subst [] asub result)

updateAuthority : ModuleCtx ->
  String ->
  List (String, Mono) ->
  List String ->
  Int ->
  Option (Ref Authvar) ->
  Authority
updateAuthority mctx rname fields assigned id source
  | IdMap.has id mctx.mcGraph.graphRun.ctorExistentialsRef.value =
    let mentioning =
      map fst (filterList (f => IdMap.has id (authCellsIn (snd f) Tip)) fields)
    let replaced = filterList (n => contains n assigned) mentioning
    if isEmptyL replaced then
      sharedAuthority mctx id source
    else if listLen replaced == listLen mentioning then
      AVar (freshInferenceAuthvar mctx id source)
    else
      pushTypeError
        mctx
        "T-AUTHORITY-EXISTENTIAL-SCOPE"
        (partialExistentialUpdateMsg rname mentioning)
      AVar (freshInferenceAuthvar mctx id source)
  | otherwise = AVar (freshInferenceAuthvar mctx id source)

-- A universal freshens flexible, as at any use.  An existential binder is
-- opened only by a pattern; a field read or update sees the value without
-- opening it, so what it recovers is the domain's top: the value proves
-- nothing about an authority the read cannot name.
sharedAuthority : ModuleCtx -> Int -> Option (Ref Authvar) -> Authority
sharedAuthority mctx id source
  | IdMap.has id mctx.mcGraph.graphRun.ctorExistentialsRef.value = match source
    Some cell => authTop (authvarDomain cell)
    None => authTop PUnit
  | otherwise = AVar (freshInferenceAuthvar mctx id source)

export
substRecordField : GraphCtx -> RecordSubst -> Mono -> Mono
substRecordField gctx (RecordSubst subst asub) fm =
  substMono gctx subst [] asub fm

export
recordFieldMap : RecordInfo -> OrdMap Mono
recordFieldMap (RecordInfo _ _ _ _ idx) = idx

export
recordFieldNames : RecordInfo -> List String
recordFieldNames (RecordInfo _ _ _ fields _) = map fst fields
# DESUGAR
(DUse false (UseGroup ("types" "tc_types") ((mem "CtorFieldConflict" true) (mem "DynCtx" false) (mem "GraphCtx" false) (mem "ModuleCtx" false) (mem "RecordInfo" false) (mem "RecordSubst" false))))
(DUse false (UseGroup ("types" "tc_mono") ((mem "authCellsIn" false) (mem "authSame" false) (mem "headTyconMono" false) (mem "headTyconNameMono" false) (mem "monoSameGiven" false) (mem "recordAuthCells" false) (mem "recordOwnerModule" false) (mem "recordResultMono" false) (mem "rowSame" false) (mem "substMono" false) (mem "tyvarId" false))))
(DUse false (UseGroup ("types" "tc_diag_text") ((mem "abstractFieldMsg" false) (mem "ambiguousFieldDeclsMsg" false) (mem "ambiguousFieldMsg" false) (mem "fieldFixFrom" false) (mem "fieldNotInAllCtorsMsg" false) (mem "fieldPositionDiffersMsg" false) (mem "fieldTypeDiffersMsg" false) (mem "missingFieldMsg" false) (mem "partialExistentialUpdateMsg" false) (mem "unknownFieldMsg" false) (mem "unknownRecordMsg" false) (mem "updateMultiCtorMsg" false))))
(DUse false (UseGroup ("types" "tc_env") ((mem "lookupRecordByName" false) (mem "recordCandInfo" false))))
(DUse false (UseGroup ("types" "tc_diag") ((mem "pushTypeError" false) (mem "pushTypeErrorHelpFixAt" false))))
(DUse false (UseGroup ("types" "tc_unify") ((mem "freshInferenceAuthvar" false) (mem "freshSubst" false) (mem "freshVar" false) (mem "poisonMismatchVars" false) (mem "unifyIn" false))))
(DUse false (UseGroup ("types" "effect_authority") ((mem "Authority" true) (mem "Authvar" true) (mem "authTop" false) (mem "authvarDomain" false) (mem "authvarId" false))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "EffRow" true) (mem "Effvar" true) (mem "effvarId" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "FieldAssign" true) (mem "Ident" true) (mem "TabKey" true))))
(DUse false (UseGroup ("types" "registry") ((mem "HeadKey" true) (mem "headKeyTag" false) (mem "headKeyIdent" false) (mem "headKeyDecl" false) (mem "spCandsOf" false) (mem "spRows" false))))
(DUse false (UseGroup ("types" "repr") ((mem "Mono" true) (mem "normalize" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "omHasKey" false) (mem "omLookup" false) (mem "omSize" false) (mem "OrdMap" false))))
(DUse false (UseGroup ("types" "effect_domain") ((mem "Param" true))))
(DUse false (UseGroup ("map") ((mem "Map" true))))
(DUse false (UseGroup ("support" "util") ((mem "contains" false) (mem "dedupBy" false) (mem "editDistance" false) (mem "filterList" false) (mem "isEmptyL" false) (mem "isSome" false) (mem "listLen" false) (mem "orElseOpt" false) (mem "sortUniqS" false))))
(DUse false (UseGroup ("list") ((mem "elemIndex" false) (mem "head" false))))
(DUse false (UseGroup ("types" "private_mangle") ((mem "isReservedCtor" false) (mem "mangledName" false))))
(DUse false (UseGroup ("frontend" "exhaust") ((mem "oGetCtors" false))))
(DUse false (UseAlias ("map") "IdMap"))
(DTypeSig true "fieldAssignNamePair" (TyFun (TyCon "FieldAssign") (TyTuple (TyCon "String") (TyCon "Unit"))))
(DFunDef false "fieldAssignNamePair" ((PCon "FieldAssign" (PVar "fn") PWild)) (ETuple (EVar "fn") (ELit LUnit)))
(DTypeSig true "assignedFieldNames" (TyFun (TyApp (TyCon "List") (TyCon "FieldAssign")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "assignedFieldNames" ((PVar "fields")) (EApp (EApp (EVar "map") (ELam ((PVar "fa")) (EApp (EVar "fst") (EApp (EVar "fieldAssignNamePair") (EVar "fa"))))) (EVar "fields")))
(DTypeSig true "checkMissingFields" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyCon "Unit"))))))
(DFunDef false "checkMissingFields" ((PVar "mctx") PWild (PList) PWild) (ELit LUnit))
(DFunDef false "checkMissingFields" ((PVar "mctx") (PVar "rname") (PCons (PVar "fname") (PVar "rest")) (PVar "supplied")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "fname")) (EVar "supplied")) (EApp (EApp (EApp (EApp (EVar "checkMissingFields") (EVar "mctx")) (EVar "rname")) (EVar "rest")) (EVar "supplied")) (EIf (EVar "otherwise") (EBlock (DoExpr (EApp (EApp (EApp (EVar "pushTypeError") (EVar "mctx")) (ELit (LString "T-MISSING-FIELD"))) (EApp (EApp (EVar "missingFieldMsg") (EVar "fname")) (EVar "rname")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "checkMissingFields") (EVar "mctx")) (EVar "rname")) (EVar "rest")) (EVar "supplied")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "stampedRecordHead" (TyFun (TyCon "String") (TyFun (TyCon "RecordInfo") (TyCon "String"))))
(DFunDef false "stampedRecordHead" ((PVar "rname") (PVar "ri")) (EMatch (EApp (EVar "recordOwnerModule") (EVar "ri")) (arm (PCon "None") () (EVar "rname")) (arm (PCon "Some" (PVar "mid")) () (EApp (EApp (EVar "ownerQualifiedHead") (EVar "mid")) (EVar "rname")))))
(DTypeSig false "ownerQualifiedHead" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "ownerQualifiedHead" ((PVar "mid") (PVar "name")) (EIf (EApp (EVar "isReservedCtor") (EVar "name")) (EVar "name") (EIf (EVar "otherwise") (EApp (EApp (EVar "mangledName") (EVar "mid")) (EVar "name")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "inferFieldOfRecord" (TyFun (TyCon "DynCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "String") (TyFun (TyCon "RecordInfo") (TyFun (TyCon "String") (TyCon "Mono")))))))
(DFunDef false "inferFieldOfRecord" ((PVar "dyn") (PVar "te") (PVar "rname") (PVar "ri") (PVar "fname")) (EBlock (DoLet false false (PVar "sr") (EApp (EApp (EVar "instantiateRecordShared") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "ri"))) (DoExpr (EApp (EApp (EApp (EVar "unifyIn") (EVar "dyn")) (EVar "te")) (EApp (EVar "snd") (EVar "sr")))) (DoExpr (EMatch (EApp (EApp (EVar "omLookup") (EVar "fname")) (EApp (EVar "recordFieldMap") (EVar "ri"))) (arm (PCon "Some" (PVar "fm")) () (EApp (EApp (EApp (EVar "substRecordField") (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcGraph")) (EApp (EVar "fst") (EVar "sr"))) (EVar "fm"))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "unknownFieldFresh") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "fname")) (EVar "rname")) (EApp (EVar "recordFieldNames") (EVar "ri"))))))))
(DTypeSig true "fieldSelectionWellTyped" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "String") (TyFun (TyCon "RecordInfo") (TyFun (TyCon "String") (TyFun (TyCon "Mono") (TyCon "Mono"))))))))
(DFunDef false "fieldSelectionWellTyped" ((PVar "mctx") (PVar "te") (PVar "rname") (PVar "ri") (PVar "fname") (PVar "ft")) (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "ctorFieldConflictHere") (EVar "mctx")) (EVar "te")) (EVar "rname")) (EVar "ri")) (EVar "fname")) (arm (PCon "None") () (EVar "ft")) (arm (PCon "Some" (PVar "conflict")) () (EBlock (DoExpr (EApp (EApp (EApp (EApp (EVar "pushCtorFieldConflict") (EVar "mctx")) (EVar "fname")) (EApp (EApp (EVar "optionOr") (EVar "rname")) (EApp (EVar "headTyconNameMono") (EVar "te")))) (EVar "conflict"))) (DoLet false false (PVar "v") (EApp (EApp (EVar "freshVar") (EVar "mctx")) (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EVar "poisonMismatchVars") (EVar "mctx")) (EVar "v")) (EVar "v"))) (DoExpr (EVar "v"))))))
(DTypeSig false "ctorFieldConflictHere" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "String") (TyFun (TyCon "RecordInfo") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "CtorFieldConflict"))))))))
(DFunDef false "ctorFieldConflictHere" ((PVar "mctx") (PVar "te") (PVar "rname") (PVar "ri") (PVar "fname")) (EMatch (EApp (EVar "headTyconMono") (EVar "te")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "hk")) () (EIf (EBinOp "==" (EApp (EVar "Some") (EVar "hk")) (EApp (EVar "headTyconMono") (EApp (EVar "recordResultMono") (EVar "ri")))) (EApp (EApp (EApp (EApp (EVar "ctorFieldConflict") (EVar "mctx")) (EVar "hk")) (EVar "fname")) (EVar "rname")) (EVar "None")))))
(DTypeSig false "ctorFieldConflict" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "HeadKey") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "CtorFieldConflict")))))))
(DFunDef false "ctorFieldConflict" ((PVar "mctx") (PVar "hk") (PVar "fname") (PVar "rname")) (EMatch (EApp (EApp (EApp (EApp (EVar "ctorSiblingWithholdingName") (EVar "mctx")) (EApp (EVar "Some") (EVar "hk"))) (EVar "fname")) (EVar "rname")) (arm (PCon "Some" (PVar "sib")) () (EApp (EVar "Some") (EApp (EVar "CtorWithholds") (EVar "sib")))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "ctorsOfHead") (EVar "mctx")) (EVar "hk")) (arm (PCon "Some" (PAs "ctors" (PCons PWild (PCons PWild PWild)))) () (EBlock (DoLet false false (PVar "held") (EApp (EApp (EApp (EApp (EVar "ctorFieldSlots") (EVar "mctx")) (EVar "hk")) (EVar "fname")) (EVar "ctors"))) (DoExpr (EApp (EApp (EVar "orElseOpt") (EApp (EVar "firstSlotDisagreement") (EVar "held"))) (EApp (EApp (EApp (EVar "firstTypeDisagreement") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "fname")) (EVar "held")))))) (arm PWild () (EVar "None"))))))
(DTypeSig false "ctorsOfHead" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "HeadKey") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "ctorsOfHead" ((PVar "mctx") (PVar "hk")) (EMatch (EApp (EVar "ctorOracleKeyOf") (EApp (EVar "Some") (EVar "hk"))) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "tk")) () (EApp (EApp (EVar "oGetCtors") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "matchOracle") "value")) (EVar "tk")))))
(DTypeSig false "ctorFieldSlots" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "HeadKey") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "RecordInfo"))))))))
(DFunDef false "ctorFieldSlots" ((PVar "mctx") (PVar "hk") (PVar "fname") (PVar "ctors")) (EApp (EApp (EVar "filterMap") (EApp (EApp (EApp (EVar "ctorFieldSlot") (EVar "mctx")) (EVar "hk")) (EVar "fname"))) (EVar "ctors")))
(DTypeSig false "ctorFieldSlot" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "HeadKey") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "RecordInfo"))))))))
(DFunDef false "ctorFieldSlot" ((PVar "mctx") (PVar "hk") (PVar "fname") (PVar "k")) (EMatch (EApp (EApp (EApp (EVar "ctorRecordOfType") (EVar "mctx")) (EVar "hk")) (EVar "k")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "ri")) () (EApp (EApp (EVar "map") (ELam ((PVar "i")) (ETuple (EVar "k") (EVar "i") (EVar "ri")))) (EApp (EApp (EVar "elemIndex") (EVar "fname")) (EApp (EVar "recordFieldNames") (EVar "ri")))))))
(DTypeSig false "firstSlotDisagreement" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "RecordInfo"))) (TyApp (TyCon "Option") (TyCon "CtorFieldConflict"))))
(DFunDef false "firstSlotDisagreement" ((PList)) (EVar "None"))
(DFunDef false "firstSlotDisagreement" ((PCons (PTuple (PVar "a") (PVar "i") PWild) (PVar "rest"))) (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "b") (PVar "j"))) (EApp (EApp (EApp (EApp (EVar "CtorSlotsDiffer") (EVar "a")) (EVar "i")) (EVar "b")) (EVar "j")))) (EApp (EApp (EVar "slotOtherThan") (EVar "i")) (EVar "rest"))))
(DTypeSig false "slotOtherThan" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "RecordInfo"))) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Int"))))))
(DFunDef false "slotOtherThan" (PWild (PList)) (EVar "None"))
(DFunDef false "slotOtherThan" ((PVar "i") (PCons (PTuple (PVar "b") (PVar "j") PWild) (PVar "rest"))) (EIf (EBinOp "/=" (EVar "j") (EVar "i")) (EApp (EVar "Some") (ETuple (EVar "b") (EVar "j"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "slotOtherThan") (EVar "i")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "firstTypeDisagreement" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "RecordInfo"))) (TyApp (TyCon "Option") (TyCon "CtorFieldConflict"))))))
(DFunDef false "firstTypeDisagreement" ((PVar "gctx") PWild (PList)) (EVar "None"))
(DFunDef false "firstTypeDisagreement" ((PVar "gctx") (PVar "fname") (PCons (PTuple (PVar "a") PWild (PVar "ra")) (PVar "rest"))) (EMatch (EApp (EApp (EVar "omLookup") (EVar "fname")) (EApp (EVar "recordFieldMap") (EVar "ra"))) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "ta")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "typeOtherThan") (EVar "gctx")) (EVar "fname")) (EVar "a")) (EVar "ra")) (EVar "ta")) (EVar "rest")))))
(DTypeSig false "typeOtherThan" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "RecordInfo") (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "RecordInfo"))) (TyApp (TyCon "Option") (TyCon "CtorFieldConflict")))))))))
(DFunDef false "typeOtherThan" ((PVar "gctx") PWild PWild PWild PWild (PList)) (EVar "None"))
(DFunDef false "typeOtherThan" ((PVar "gctx") (PVar "fname") (PVar "a") (PVar "ra") (PVar "ta") (PCons (PTuple (PVar "b") PWild (PVar "rb")) (PVar "rest"))) (EMatch (EApp (EApp (EVar "omLookup") (EVar "fname")) (EApp (EVar "recordFieldMap") (EVar "rb"))) (arm (PCon "Some" (PVar "tb")) () (EBlock (DoLet false false (PTuple (PVar "tsub") (PVar "esub") (PVar "asub")) (EApp (EApp (EApp (EVar "paramRenaming") (EApp (EVar "recordResultMono") (EVar "rb"))) (EApp (EVar "recordResultMono") (EVar "ra"))) (ETuple (EListLit) (EListLit) (EListLit)))) (DoLet false false (PVar "tbOverA") (EApp (EApp (EApp (EApp (EApp (EVar "substMono") (EVar "gctx")) (EVar "tsub")) (EVar "esub")) (EVar "asub")) (EVar "tb"))) (DoExpr (EIf (EApp (EApp (EVar "fieldTypeSame") (EVar "ta")) (EVar "tbOverA")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "typeOtherThan") (EVar "gctx")) (EVar "fname")) (EVar "a")) (EVar "ra")) (EVar "ta")) (EVar "rest")) (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EVar "CtorTypesDiffer") (EVar "a")) (EVar "ta")) (EVar "b")) (EVar "tbOverA"))))))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "typeOtherThan") (EVar "gctx")) (EVar "fname")) (EVar "a")) (EVar "ra")) (EVar "ta")) (EVar "rest")))))
(DTypeSig false "paramRenaming" (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyFun (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyApp (TyCon "Ref") (TyCon "Effvar")))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Authority")))) (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyApp (TyCon "Ref") (TyCon "Effvar")))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Authority"))))))))
(DFunDef false "paramRenaming" ((PVar "from") (PVar "to") (PVar "acc")) (EMatch (EApp (EVar "normalize") (EVar "from")) (arm (PCon "TApp" (PVar "f1") (PVar "a1")) () (EMatch (EApp (EVar "normalize") (EVar "to")) (arm (PCon "TApp" (PVar "f2") (PVar "a2")) () (EApp (EApp (EApp (EVar "paramRenaming") (EVar "f1")) (EVar "f2")) (EApp (EApp (EApp (EVar "renameParam") (EApp (EVar "normalize") (EVar "a1"))) (EVar "a2")) (EVar "acc")))) (arm PWild () (EVar "acc")))) (arm PWild () (EVar "acc"))))
(DTypeSig false "renameParam" (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyFun (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyApp (TyCon "Ref") (TyCon "Effvar")))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Authority")))) (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyApp (TyCon "Ref") (TyCon "Effvar")))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Authority"))))))))
(DFunDef false "renameParam" ((PCon "TVar" (PVar "c")) (PVar "to") (PTuple (PVar "ts") (PVar "es") (PVar "qs"))) (ETuple (EBinOp "::" (ETuple (EApp (EVar "tyvarId") (EVar "c")) (EVar "to")) (EVar "ts")) (EVar "es") (EVar "qs")))
(DFunDef false "renameParam" ((PCon "TEff" (PCon "EffRow" (PList) (PCon "Some" (PVar "e1")))) (PCon "TEff" (PCon "EffRow" (PList) (PCon "Some" (PVar "e2")))) (PTuple (PVar "ts") (PVar "es") (PVar "qs"))) (ETuple (EVar "ts") (EBinOp "::" (ETuple (EApp (EVar "effvarId") (EVar "e1")) (EVar "e2")) (EVar "es")) (EVar "qs")))
(DFunDef false "renameParam" ((PCon "TAuth" (PCon "AVar" (PVar "q1"))) (PCon "TAuth" (PVar "q2")) (PTuple (PVar "ts") (PVar "es") (PVar "qs"))) (ETuple (EVar "ts") (EVar "es") (EBinOp "::" (ETuple (EApp (EVar "authvarId") (EVar "q1")) (EVar "q2")) (EVar "qs"))))
(DFunDef false "renameParam" (PWild PWild (PVar "acc")) (EVar "acc"))
(DTypeSig false "fieldTypeSame" (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Bool"))))
(DFunDef false "fieldTypeSame" ((PVar "x") (PVar "y")) (EMatch (ETuple (EApp (EVar "normalize") (EVar "x")) (EApp (EVar "normalize") (EVar "y"))) (arm (PTuple (PCon "TFun" (PVar "a1") (PVar "r1") (PVar "b1")) (PCon "TFun" (PVar "a2") (PVar "r2") (PVar "b2"))) () (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "fieldTypeSame") (EVar "a1")) (EVar "a2")) (EApp (EApp (EVar "rowSame") (EVar "r1")) (EVar "r2"))) (EApp (EApp (EVar "fieldTypeSame") (EVar "b1")) (EVar "b2")))) (arm (PTuple (PCon "TApp" (PVar "a1") (PVar "b1")) (PCon "TApp" (PVar "a2") (PVar "b2"))) () (EBinOp "&&" (EApp (EApp (EVar "fieldTypeSame") (EVar "a1")) (EVar "a2")) (EApp (EApp (EVar "fieldTypeSame") (EVar "b1")) (EVar "b2")))) (arm (PTuple (PCon "TEff" (PVar "r1")) (PCon "TEff" (PVar "r2"))) () (EApp (EApp (EVar "rowSame") (EVar "r1")) (EVar "r2"))) (arm (PTuple (PCon "TQual" (PVar "t1") (PVar "q1")) (PCon "TQual" (PVar "t2") (PVar "q2"))) () (EBinOp "&&" (EApp (EApp (EVar "fieldTypeSame") (EVar "t1")) (EVar "t2")) (EApp (EApp (EVar "authSame") (EVar "q1")) (EVar "q2")))) (arm (PTuple (PCon "TAuth" (PVar "q1")) (PCon "TAuth" (PVar "q2"))) () (EApp (EApp (EVar "authSame") (EVar "q1")) (EVar "q2"))) (arm (PTuple (PCon "TFun" PWild PWild PWild) PWild) () (EVar "False")) (arm (PTuple (PCon "TApp" PWild PWild) PWild) () (EVar "False")) (arm (PTuple (PCon "TEff" PWild) PWild) () (EVar "False")) (arm (PTuple (PCon "TAuth" PWild) PWild) () (EVar "False")) (arm (PTuple (PCon "TQual" (PVar "t1") PWild) (PVar "b")) () (EApp (EApp (EVar "fieldTypeSame") (EVar "t1")) (EVar "b"))) (arm (PTuple (PVar "a") (PCon "TQual" (PVar "t2") PWild)) () (EApp (EApp (EVar "fieldTypeSame") (EVar "a")) (EVar "t2"))) (arm (PTuple (PVar "a") (PVar "b")) () (EApp (EApp (EVar "monoSameGiven") (EVar "a")) (EVar "b")))))
(DTypeSig false "pushCtorFieldConflict" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "CtorFieldConflict") (TyCon "Unit"))))))
(DFunDef false "pushCtorFieldConflict" ((PVar "mctx") (PVar "fname") (PVar "tname") (PCon "CtorWithholds" (PVar "sib"))) (EApp (EApp (EApp (EVar "pushTypeError") (EVar "mctx")) (ELit (LString "T-FIELD-NOT-IN-ALL-CTORS"))) (EApp (EApp (EApp (EVar "fieldNotInAllCtorsMsg") (EVar "fname")) (EVar "tname")) (EVar "sib"))))
(DFunDef false "pushCtorFieldConflict" ((PVar "mctx") (PVar "fname") (PVar "tname") (PCon "CtorSlotsDiffer" (PVar "a") (PVar "i") (PVar "b") (PVar "j"))) (EApp (EApp (EApp (EVar "pushTypeError") (EVar "mctx")) (ELit (LString "T-FIELD-POSITION-DIFFERS"))) (EApp (EApp (EApp (EApp (EVar "fieldPositionDiffersMsg") (EVar "fname")) (EVar "tname")) (ETuple (EVar "a") (EVar "i"))) (ETuple (EVar "b") (EVar "j")))))
(DFunDef false "pushCtorFieldConflict" ((PVar "mctx") (PVar "fname") (PVar "tname") (PCon "CtorTypesDiffer" (PVar "a") (PVar "ta") (PVar "b") (PVar "tb"))) (EApp (EApp (EApp (EVar "pushTypeError") (EVar "mctx")) (ELit (LString "T-FIELD-TYPE-DIFFERS"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "fieldTypeDiffersMsg") (EVar "fname")) (EVar "tname")) (EVar "a")) (EVar "ta")) (EVar "b")) (EVar "tb"))))
(DTypeSig true "recordUpdateWellTyped" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "String") (TyFun (TyCon "RecordInfo") (TyFun (TyCon "String") (TyCon "Unit")))))))
(DFunDef false "recordUpdateWellTyped" ((PVar "mctx") (PVar "bt") (PVar "rname") (PVar "ri") (PVar "fn")) (EMatch (EApp (EVar "headTyconMono") (EVar "bt")) (arm (PCon "None") () (ELit LUnit)) (arm (PCon "Some" (PVar "hk")) () (EIf (EBinOp "==" (EApp (EVar "Some") (EVar "hk")) (EApp (EVar "headTyconMono") (EApp (EVar "recordResultMono") (EVar "ri")))) (EMatch (EApp (EApp (EVar "ctorsOfHead") (EVar "mctx")) (EVar "hk")) (arm (PCon "Some" (PAs "ctors" (PCons PWild (PCons PWild PWild)))) () (EApp (EApp (EApp (EVar "pushTypeError") (EVar "mctx")) (ELit (LString "T-UPDATE-MULTI-CTOR"))) (EApp (EApp (EApp (EApp (EApp (EVar "updateMultiCtorMsg") (EVar "fn")) (EApp (EApp (EVar "optionOr") (EVar "rname")) (EApp (EVar "headTyconNameMono") (EVar "bt")))) (EVar "rname")) (EApp (EApp (EVar "filterList") (ELam ((PVar "_s")) (EBinOp "/=" (EVar "_s") (EVar "fn")))) (EApp (EVar "recordFieldNames") (EVar "ri")))) (EVar "ctors")))) (arm PWild () (ELit LUnit))) (ELit LUnit)))))
(DTypeSig false "fieldOwnerNames" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "fieldOwnerNames" ((PVar "mctx") (PVar "fname")) (EApp (EApp (EVar "fieldOwnerReachFilter") (EVar "mctx")) (EApp (EVar "sortUniqS") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "fname")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "fieldOwnersRef") "value"))))))
(DTypeSig false "fieldOwnerReachFilter" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "fieldOwnerReachFilter" ((PVar "mctx") (PVar "owners")) (EMatch (EApp (EApp (EVar "filterList") (EApp (EVar "fieldOwnerReachable") (EVar "mctx"))) (EVar "owners")) (arm (PList) () (EVar "owners")) (arm (PVar "kept") () (EVar "kept"))))
(DTypeSig false "fieldOwnerReachable" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "fieldOwnerReachable" ((PVar "mctx") (PVar "key")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "key")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "fieldOwnerModulesRef") "value")) (arm (PCon "None") () (EVar "True")) (arm (PCon "Some" (PVar "mids")) () (EApp (EApp (EVar "fieldOwnerAnyReachable") (EVar "mctx")) (EVar "mids")))))
(DTypeSig false "fieldOwnerAnyReachable" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "fieldOwnerAnyReachable" ((PVar "mctx") (PList)) (EVar "False"))
(DFunDef false "fieldOwnerAnyReachable" ((PVar "mctx") (PCons (PVar "m") (PVar "rest"))) (EBinOp "||" (EApp (EApp (EVar "omHasKey") (EVar "m")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "fieldOwnerReachRef") "value")) (EApp (EApp (EVar "fieldOwnerAnyReachable") (EVar "mctx")) (EVar "rest"))))
(DTypeSig true "resolveFieldRecord" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "RecordInfo")))))))
(DFunDef false "resolveFieldRecord" ((PVar "mctx") (PVar "te") (PVar "fname")) (EMatch (EApp (EVar "headTyconNameMono") (EVar "te")) (arm (PCon "Some" (PVar "r")) () (EMatch (EApp (EApp (EApp (EVar "lookupRecordForReceiver") (EVar "mctx")) (EVar "te")) (EVar "r")) (arm (PCon "Some" (PVar "ri")) () (EApp (EVar "Some") (ETuple (EVar "r") (EVar "ri")))) (arm (PCon "None") () (EIf (EApp (EApp (EVar "omHasKey") (EApp (EApp (EVar "receiverTypeWord") (EVar "te")) (EVar "r"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "abstractRecordTypesRef") "value")) (EBlock (DoExpr (EApp (EApp (EApp (EVar "pushTypeError") (EVar "mctx")) (ELit (LString "T-ABSTRACT-FIELD"))) (EApp (EApp (EVar "abstractFieldMsg") (EVar "r")) (EVar "fname")))) (DoExpr (EVar "None"))) (EApp (EApp (EApp (EVar "resolveFieldByOwners") (EVar "mctx")) (EVar "te")) (EVar "fname")))))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "resolveFieldByOwners") (EVar "mctx")) (EVar "te")) (EVar "fname")))))
(DTypeSig false "lookupRecordForReceiver" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "RecordInfo"))))))
(DFunDef false "lookupRecordForReceiver" ((PVar "mctx") (PVar "te") (PVar "r")) (EMatch (EApp (EApp (EApp (EVar "recordForReceiverIdent") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "te")) (EVar "r")) (arm (PCon "Some" (PVar "ri")) () (EApp (EVar "Some") (EVar "ri"))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "lookupRecordByName") (EVar "mctx")) (EVar "r")) (arm (PCon "Some" (PVar "ri")) () (EIf (EApp (EApp (EVar "recordOfOtherType") (EVar "te")) (EVar "ri")) (EVar "None") (EApp (EVar "Some") (EVar "ri")))) (arm (PCon "None") () (EVar "None"))))))
(DTypeSig false "recordOfOtherType" (TyFun (TyCon "Mono") (TyFun (TyCon "RecordInfo") (TyCon "Bool"))))
(DFunDef false "recordOfOtherType" ((PVar "te") (PCon "RecordInfo" PWild PWild (PVar "res") PWild PWild)) (EMatch (ETuple (EApp (EVar "receiverTypeIdent") (EVar "te")) (EApp (EVar "receiverTypeIdent") (EVar "res"))) (arm (PTuple (PCon "Some" (PCon "Ident" PWild (PVar "wo") (PVar "wn"))) (PCon "Some" (PCon "Ident" PWild (PVar "ro") (PVar "rn")))) () (EApp (EVar "not") (EBinOp "&&" (EBinOp "==" (EVar "wn") (EVar "rn")) (EBinOp "==" (EVar "wo") (EVar "ro"))))) (arm PWild () (EVar "False"))))
(DTypeSig false "recordForReceiverIdent" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "RecordInfo"))))))
(DFunDef false "recordForReceiverIdent" ((PVar "gctx") (PVar "te") (PVar "r")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "r")) (EApp (EVar "spRows") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "universeRecordPop") "value"))) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "cs")) () (EMatch (EApp (EVar "receiverTypeIdent") (EVar "te")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "ident")) () (EApp (EApp (EVar "recordCandForType") (EVar "ident")) (EVar "cs")))))))
(DTypeSig false "receiverTypeWord" (TyFun (TyCon "Mono") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "receiverTypeWord" ((PVar "te") (PVar "r")) (EMatch (EApp (EVar "headTyconMono") (EVar "te")) (arm (PCon "Some" (PVar "hk")) () (EApp (EVar "headKeyTag") (EVar "hk"))) (arm (PCon "None") () (EVar "r"))))
(DTypeSig false "receiverTypeIdent" (TyFun (TyCon "Mono") (TyApp (TyCon "Option") (TyCon "Ident"))))
(DFunDef false "receiverTypeIdent" ((PVar "te")) (EMatch (EApp (EVar "headTyconMono") (EVar "te")) (arm (PCon "Some" (PVar "hk")) () (EApp (EVar "headKeyIdent") (EVar "hk"))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "recordCandForType" (TyFun (TyCon "Ident") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Ident") (TyCon "String") (TyCon "RecordInfo"))) (TyApp (TyCon "Option") (TyCon "RecordInfo")))))
(DFunDef false "recordCandForType" (PWild (PList)) (EVar "None"))
(DFunDef false "recordCandForType" ((PVar "want") (PCons (PTuple (PVar "ci") (PVar "tyName") (PVar "ri")) (PVar "rest"))) (EIf (EApp (EApp (EApp (EVar "recordCandIsType") (EVar "want")) (EVar "ci")) (EVar "tyName")) (EApp (EVar "Some") (EVar "ri")) (EIf (EVar "otherwise") (EApp (EApp (EVar "recordCandForType") (EVar "want")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "recordCandIsType" (TyFun (TyCon "Ident") (TyFun (TyCon "Ident") (TyFun (TyCon "String") (TyCon "Bool")))))
(DFunDef false "recordCandIsType" ((PCon "Ident" PWild (PVar "wio") (PVar "wname")) (PCon "Ident" PWild (PVar "cio") PWild) (PVar "tyName")) (EBinOp "&&" (EBinOp "==" (EVar "tyName") (EVar "wname")) (EBinOp "==" (EVar "cio") (EVar "wio"))))
(DTypeSig false "recordCandIsReceiverDecl" (TyFun (TyApp (TyCon "Option") (TyCon "HeadKey")) (TyFun (TyTuple (TyCon "String") (TyCon "RecordInfo")) (TyCon "Bool"))))
(DFunDef false "recordCandIsReceiverDecl" ((PVar "rk") (PTuple PWild (PVar "ri"))) (EBinOp "==" (EVar "rk") (EApp (EVar "headTyconMono") (EApp (EVar "recordResultMono") (EVar "ri")))))
(DTypeSig false "resolveFieldByOwners" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "RecordInfo")))))))
(DFunDef false "resolveFieldByOwners" ((PVar "mctx") (PVar "te") (PVar "fname")) (EBlock (DoLet false false (PVar "owners") (EApp (EApp (EVar "fieldOwnerNames") (EVar "mctx")) (EVar "fname"))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EVar "ownerDeclOfReceiver") (EVar "mctx")) (EVar "te")) (EVar "fname")) (EVar "owners")) (arm (PCon "Some" (PVar "pair")) () (EApp (EVar "Some") (EVar "pair"))) (arm (PCon "None") () (EMatch (EVar "owners") (arm (PList) () (EBlock (DoExpr (EApp (EApp (EApp (EVar "pushUnknownField") (EVar "mctx")) (EVar "fname")) (ELit (LString "<unknown>")))) (DoExpr (EVar "None")))) (arm PWild () (EMatch (EApp (EVar "normalize") (EVar "te")) (arm (PCon "TVar" PWild) () (EApp (EApp (EApp (EVar "resolveFieldUnknownReceiver") (EVar "mctx")) (EVar "fname")) (EVar "owners"))) (arm PWild () (EApp (EApp (EApp (EApp (EVar "resolveFieldAmbiguous") (EVar "mctx")) (EVar "te")) (EVar "fname")) (EVar "owners")))))))))))
(DTypeSig false "resolveFieldUnknownReceiver" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "RecordInfo")))))))
(DFunDef false "resolveFieldUnknownReceiver" ((PVar "mctx") (PVar "fname") (PVar "owners")) (EMatch (EApp (EApp (EApp (EVar "visibleFieldDecls") (EVar "mctx")) (EVar "fname")) (EVar "owners")) (arm (PList (PVar "pair")) () (EApp (EVar "Some") (EVar "pair"))) (arm (PList) () (EMatch (EVar "owners") (arm (PList (PVar "r")) () (EApp (EApp (EVar "pairRecordByName") (EVar "mctx")) (EVar "r"))) (arm PWild () (EBlock (DoExpr (EApp (EApp (EApp (EVar "pushTypeError") (EVar "mctx")) (ELit (LString "T-AMBIGUOUS-FIELD"))) (EApp (EApp (EVar "ambiguousFieldMsg") (EVar "fname")) (EVar "owners")))) (DoExpr (EVar "None")))))) (arm (PVar "cands") () (EBlock (DoExpr (EApp (EApp (EApp (EVar "pushTypeError") (EVar "mctx")) (ELit (LString "T-AMBIGUOUS-FIELD"))) (EApp (EApp (EApp (EVar "ambiguousFieldDeclsMsg") (EVar "fname")) (EVar "owners")) (EVar "cands")))) (DoExpr (EVar "None"))))))
(DTypeSig false "visibleFieldDecls" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "RecordInfo")))))))
(DFunDef false "visibleFieldDecls" ((PVar "mctx") (PVar "fname") (PVar "owners")) (EApp (EApp (EVar "dedupBy") (EVar "fieldDeclTypeKey")) (EApp (EApp (EVar "fieldDeclReachFilter") (EVar "mctx")) (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "keyFieldDecls") (EVar "mctx")) (EVar "fname"))) (EVar "owners")))))
(DTypeSig false "keyFieldDecls" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "RecordInfo")))))))
(DFunDef false "keyFieldDecls" ((PVar "mctx") (PVar "fname") (PVar "k")) (EBlock (DoLet false false (PVar "rows") (EApp (EApp (EVar "map") (ELam ((PVar "c")) (ETuple (EVar "k") (EApp (EVar "recordCandInfo") (EVar "c"))))) (EApp (EApp (EVar "spCandsOf") (EVar "k")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "crossRun") "universeRecordPop") "value")))) (DoLet false false (PVar "floor") (EMatch (EApp (EApp (EVar "pairRecordByName") (EVar "mctx")) (EVar "k")) (arm (PCon "Some" (PVar "pair")) () (EListLit (EVar "pair"))) (arm (PCon "None") () (EListLit)))) (DoExpr (EApp (EApp (EVar "filterList") (ELam ((PVar "c")) (EApp (EApp (EVar "omHasKey") (EVar "fname")) (EApp (EVar "recordFieldMap") (EApp (EVar "snd") (EVar "c")))))) (EBinOp "++" (EVar "floor") (EVar "rows"))))))
(DTypeSig false "fieldDeclReachFilter" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "RecordInfo"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "RecordInfo"))))))
(DFunDef false "fieldDeclReachFilter" ((PVar "mctx") (PVar "cands")) (EMatch (EApp (EApp (EVar "filterList") (EApp (EVar "fieldDeclReachable") (EVar "mctx"))) (EVar "cands")) (arm (PList) () (EVar "cands")) (arm (PVar "kept") () (EVar "kept"))))
(DTypeSig false "fieldDeclReachable" (TyFun (TyCon "ModuleCtx") (TyFun (TyTuple (TyCon "String") (TyCon "RecordInfo")) (TyCon "Bool"))))
(DFunDef false "fieldDeclReachable" ((PVar "mctx") (PTuple PWild (PVar "ri"))) (EMatch (EApp (EVar "recordOwnerModule") (EVar "ri")) (arm (PCon "None") () (EVar "True")) (arm (PCon "Some" (PVar "mid")) () (EBlock (DoLet false false (PVar "reach") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "fieldOwnerReachRef") "value")) (DoExpr (EBinOp "||" (EBinOp "==" (EApp (EVar "omSize") (EVar "reach")) (ELit (LInt 0))) (EApp (EApp (EVar "omHasKey") (EVar "mid")) (EVar "reach"))))))))
(DTypeSig false "fieldDeclTypeKey" (TyFun (TyTuple (TyCon "String") (TyCon "RecordInfo")) (TyCon "String")))
(DFunDef false "fieldDeclTypeKey" ((PTuple (PVar "k") (PVar "ri"))) (EMatch (EApp (EVar "headTyconMono") (EApp (EVar "recordResultMono") (EVar "ri"))) (arm (PCon "Some" (PVar "hk")) () (EApp (EVar "headKeyTag") (EVar "hk"))) (arm (PCon "None") () (EVar "k"))))
(DTypeSig false "ownerDeclOfReceiver" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "RecordInfo"))))))))
(DFunDef false "ownerDeclOfReceiver" ((PVar "mctx") PWild PWild (PList)) (EVar "None"))
(DFunDef false "ownerDeclOfReceiver" ((PVar "mctx") (PVar "te") (PVar "fname") (PVar "owners")) (EMatch (EApp (EVar "receiverTypeIdent") (EVar "te")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "ident")) () (EMatch (EApp (EApp (EVar "dedupBy") (EVar "fieldDeclTypeKey")) (EApp (EApp (EApp (EVar "ownerDeclMatches") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "ident")) (EVar "owners"))) (arm (PList (PTuple (PVar "k") (PVar "ri"))) () (EIf (EApp (EApp (EApp (EApp (EVar "narrowingBlockedByCtorSibling") (EVar "mctx")) (EApp (EVar "headTyconMono") (EVar "te"))) (EVar "fname")) (EVar "k")) (EVar "None") (EApp (EVar "Some") (ETuple (EVar "k") (EVar "ri"))))) (arm PWild () (EVar "None"))))))
(DTypeSig false "ownerDeclMatches" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Ident") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "RecordInfo")))))))
(DFunDef false "ownerDeclMatches" ((PVar "gctx") PWild (PList)) (EListLit))
(DFunDef false "ownerDeclMatches" ((PVar "gctx") (PVar "ident") (PCons (PVar "k") (PVar "rest"))) (EMatch (EApp (EApp (EVar "omLookup") (EVar "k")) (EApp (EVar "spRows") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "universeRecordPop") "value"))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "ownerDeclMatches") (EVar "gctx")) (EVar "ident")) (EVar "rest"))) (arm (PCon "Some" (PVar "cs")) () (EMatch (EApp (EApp (EVar "recordCandForType") (EVar "ident")) (EVar "cs")) (arm (PCon "None") () (EApp (EApp (EApp (EVar "ownerDeclMatches") (EVar "gctx")) (EVar "ident")) (EVar "rest"))) (arm (PCon "Some" (PVar "ri")) () (EBinOp "::" (ETuple (EVar "k") (EVar "ri")) (EApp (EApp (EApp (EVar "ownerDeclMatches") (EVar "gctx")) (EVar "ident")) (EVar "rest"))))))))
(DTypeSig false "resolveFieldAmbiguous" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "RecordInfo"))))))))
(DFunDef false "resolveFieldAmbiguous" ((PVar "mctx") PWild PWild (PList (PVar "r"))) (EApp (EApp (EVar "pairRecordByName") (EVar "mctx")) (EVar "r")))
(DFunDef false "resolveFieldAmbiguous" ((PVar "mctx") (PVar "te") (PVar "fname") (PVar "owners")) (EApp (EApp (EApp (EApp (EVar "resolveFieldOwnersNarrowed") (EVar "mctx")) (EVar "te")) (EVar "fname")) (EVar "owners")))
(DTypeSig false "resolveFieldOwnersNarrowed" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "RecordInfo"))))))))
(DFunDef false "resolveFieldOwnersNarrowed" ((PVar "mctx") (PVar "te") (PVar "fname") (PVar "owners")) (EBlock (DoLet false false (PVar "rk") (EApp (EVar "headTyconMono") (EVar "te"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "narrowedPick") (EVar "mctx")) (EVar "rk")) (EVar "fname")) (EVar "owners")) (EApp (EApp (EVar "dedupBy") (EVar "fieldDeclTypeKey")) (EApp (EApp (EVar "filterList") (EApp (EVar "recordCandIsReceiverDecl") (EVar "rk"))) (EApp (EApp (EVar "ownerCandidates") (EVar "mctx")) (EVar "owners"))))))))
(DTypeSig false "narrowedPick" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "Option") (TyCon "HeadKey")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "RecordInfo"))) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "RecordInfo")))))))))
(DFunDef false "narrowedPick" ((PVar "mctx") (PVar "rk") (PVar "fname") PWild (PList (PTuple (PVar "k") (PVar "ri")))) (EIf (EApp (EVar "not") (EApp (EApp (EApp (EApp (EVar "narrowingBlockedByCtorSibling") (EVar "mctx")) (EVar "rk")) (EVar "fname")) (EVar "k"))) (EApp (EVar "Some") (ETuple (EVar "k") (EVar "ri"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "narrowedPick" ((PVar "mctx") PWild PWild (PVar "owners") PWild) (EApp (EApp (EVar "pairRecordByName") (EVar "mctx")) (EApp (EApp (EVar "optionOr") (ELit (LString ""))) (EApp (EVar "head") (EVar "owners")))))
(DTypeSig false "narrowingBlockedByCtorSibling" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "Option") (TyCon "HeadKey")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))))
(DFunDef false "narrowingBlockedByCtorSibling" ((PVar "mctx") (PVar "rk") (PVar "fname") (PVar "survivorKey")) (EApp (EVar "isSome") (EApp (EApp (EApp (EApp (EVar "ctorSiblingWithholdingName") (EVar "mctx")) (EVar "rk")) (EVar "fname")) (EVar "survivorKey"))))
(DTypeSig false "ctorSiblingWithholdingName" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "Option") (TyCon "HeadKey")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))))))
(DFunDef false "ctorSiblingWithholdingName" ((PVar "mctx") (PCon "None") PWild PWild) (EVar "None"))
(DFunDef false "ctorSiblingWithholdingName" ((PVar "mctx") (PCon "Some" (PVar "hk")) (PVar "fname") (PVar "survivorKey")) (EMatch (EApp (EApp (EVar "ctorsOfHead") (EVar "mctx")) (EVar "hk")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "ctors")) () (EApp (EApp (EApp (EApp (EApp (EVar "firstCtorSiblingWithholding") (EVar "mctx")) (EVar "hk")) (EVar "fname")) (EVar "survivorKey")) (EVar "ctors")))))
(DTypeSig false "ctorOracleKeyOf" (TyFun (TyApp (TyCon "Option") (TyCon "HeadKey")) (TyApp (TyCon "Option") (TyCon "TabKey"))))
(DFunDef false "ctorOracleKeyOf" ((PCon "None")) (EVar "None"))
(DFunDef false "ctorOracleKeyOf" ((PCon "Some" (PVar "hk"))) (EApp (EVar "headKeyDecl") (EVar "hk")))
(DTypeSig false "firstCtorSiblingWithholding" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "HeadKey") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "String"))))))))
(DFunDef false "firstCtorSiblingWithholding" ((PVar "mctx") PWild PWild PWild (PList)) (EVar "None"))
(DFunDef false "firstCtorSiblingWithholding" ((PVar "mctx") (PVar "hk") (PVar "fname") (PVar "skey") (PCons (PVar "k") (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "skey")) (EApp (EApp (EApp (EApp (EApp (EVar "firstCtorSiblingWithholding") (EVar "mctx")) (EVar "hk")) (EVar "fname")) (EVar "skey")) (EVar "rest")) (EIf (EApp (EApp (EApp (EApp (EVar "ctorSiblingWithholds") (EVar "mctx")) (EVar "hk")) (EVar "fname")) (EVar "k")) (EApp (EVar "Some") (EVar "k")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "firstCtorSiblingWithholding") (EVar "mctx")) (EVar "hk")) (EVar "fname")) (EVar "skey")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "ctorSiblingWithholds" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "HeadKey") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))))
(DFunDef false "ctorSiblingWithholds" ((PVar "mctx") (PVar "hk") (PVar "fname") (PVar "k")) (EMatch (EApp (EApp (EApp (EVar "ctorRecordOfType") (EVar "mctx")) (EVar "hk")) (EVar "k")) (arm (PCon "Some" (PVar "ri")) () (EApp (EVar "isNone") (EApp (EApp (EVar "omLookup") (EVar "fname")) (EApp (EVar "recordFieldMap") (EVar "ri"))))) (arm (PCon "None") () (EVar "True"))))
(DTypeSig false "ctorRecordOfType" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "HeadKey") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "RecordInfo"))))))
(DFunDef false "ctorRecordOfType" ((PVar "mctx") (PVar "hk") (PVar "k")) (EMatch (EApp (EApp (EApp (EVar "ctorRecordFromCompanion") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "hk")) (EVar "k")) (arm (PCon "Some" (PVar "ri")) () (EApp (EVar "Some") (EVar "ri"))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "lookupRecordByName") (EVar "mctx")) (EVar "k")) (arm (PCon "Some" (PVar "ri")) () (EIf (EApp (EApp (EVar "recordCandIsReceiverDecl") (EApp (EVar "Some") (EVar "hk"))) (ETuple (EVar "k") (EVar "ri"))) (EApp (EVar "Some") (EVar "ri")) (EVar "None"))) (arm (PCon "None") () (EVar "None"))))))
(DTypeSig false "ctorRecordFromCompanion" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "HeadKey") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "RecordInfo"))))))
(DFunDef false "ctorRecordFromCompanion" ((PVar "gctx") (PVar "hk") (PVar "k")) (EMatch (EApp (EVar "headKeyIdent") (EVar "hk")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "ident")) () (EMatch (EApp (EApp (EVar "omLookup") (EVar "k")) (EApp (EVar "spRows") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "universeRecordPop") "value"))) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "cs")) () (EApp (EApp (EVar "recordCandForType") (EVar "ident")) (EVar "cs")))))))
(DTypeSig false "ownerCandidates" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "RecordInfo"))))))
(DFunDef false "ownerCandidates" ((PVar "mctx") (PList)) (EListLit))
(DFunDef false "ownerCandidates" ((PVar "mctx") (PCons (PVar "key") (PVar "rest"))) (EMatch (EApp (EApp (EVar "lookupRecordByName") (EVar "mctx")) (EVar "key")) (arm (PCon "Some" (PVar "ri")) () (EBinOp "::" (ETuple (EVar "key") (EVar "ri")) (EApp (EApp (EVar "ownerCandidates") (EVar "mctx")) (EVar "rest")))) (arm (PCon "None") () (EApp (EApp (EVar "ownerCandidates") (EVar "mctx")) (EVar "rest")))))
(DTypeSig false "pairRecordByName" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "RecordInfo"))))))
(DFunDef false "pairRecordByName" ((PVar "mctx") (PVar "r")) (EApp (EApp (EVar "map") (ELam ((PVar "ri")) (ETuple (EVar "r") (EVar "ri")))) (EApp (EApp (EVar "lookupRecordByName") (EVar "mctx")) (EVar "r"))))
(DTypeSig false "pushUnknownField" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Unit")))))
(DFunDef false "pushUnknownField" ((PVar "mctx") (PVar "fname") (PVar "rname")) (EApp (EApp (EApp (EVar "pushTypeError") (EVar "mctx")) (ELit (LString "T-UNKNOWN-FIELD"))) (EApp (EApp (EVar "unknownFieldMsg") (EVar "fname")) (EVar "rname"))))
(DTypeSig false "unknownFieldFresh" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Mono"))))))
(DFunDef false "unknownFieldFresh" ((PVar "mctx") (PVar "fname") (PVar "rname") (PVar "declared")) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EVar "pushUnknownFieldMaybeSuggest") (EVar "mctx")) (EVar "fname")) (EVar "rname")) (EVar "declared"))) (DoLet false false (PVar "v") (EApp (EApp (EVar "freshVar") (EVar "mctx")) (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EVar "poisonMismatchVars") (EVar "mctx")) (EVar "v")) (EVar "v"))) (DoExpr (EVar "v"))))
(DTypeSig false "pushUnknownFieldMaybeSuggest" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Unit"))))))
(DFunDef false "pushUnknownFieldMaybeSuggest" ((PVar "mctx") (PVar "fname") (PVar "rname") (PVar "declared")) (EMatch (EApp (EApp (EVar "suggestField") (EVar "fname")) (EVar "declared")) (arm (PCon "None") () (EApp (EApp (EApp (EVar "pushTypeError") (EVar "mctx")) (ELit (LString "T-UNKNOWN-FIELD"))) (EApp (EApp (EVar "unknownFieldMsg") (EVar "fname")) (EVar "rname")))) (arm (PCon "Some" (PVar "sug")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "pushTypeErrorHelpFixAt") (EVar "mctx")) (ELit (LString "T-UNKNOWN-FIELD"))) (EFieldAccess (EVar "mctx") "mcLoc")) (EBinOp "++" (EApp (EApp (EVar "unknownFieldMsg") (EVar "fname")) (EVar "rname")) (EBinOp "++" (EBinOp "++" (ELit (LString "; did you mean `")) (EApp (EVar "display") (EVar "sug"))) (ELit (LString "`?"))))) (EBinOp "++" (EBinOp "++" (ELit (LString "did you mean `")) (EApp (EVar "display") (EVar "sug"))) (ELit (LString "`?")))) (EApp (EApp (EApp (EVar "fieldFixFrom") (EFieldAccess (EVar "mctx") "mcLoc")) (EVar "fname")) (EVar "sug"))))))
(DTypeSig false "suggestField" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "suggestField" ((PVar "fname") (PVar "declared")) (EIf (EBinOp "<" (EApp (EVar "stringLength") (EVar "fname")) (ELit (LInt 3))) (EVar "None") (EIf (EVar "otherwise") (EApp (EApp (EVar "map") (EVar "fst")) (EApp (EApp (EApp (EApp (EVar "bestFieldCandidate") (EVar "fname")) (ELit (LInt 2))) (EVar "declared")) (EVar "None"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "bestFieldCandidate" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Int"))) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Int"))))))))
(DFunDef false "bestFieldCandidate" (PWild PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "bestFieldCandidate" ((PVar "fname") (PVar "lim") (PCons (PVar "c") (PVar "cs")) (PVar "acc")) (EIf (EBinOp "==" (EVar "c") (EVar "fname")) (EApp (EApp (EApp (EApp (EVar "bestFieldCandidate") (EVar "fname")) (EVar "lim")) (EVar "cs")) (EVar "acc")) (EIf (EBinOp ">" (EApp (EApp (EVar "editDistance") (EVar "fname")) (EVar "c")) (EVar "lim")) (EApp (EApp (EApp (EApp (EVar "bestFieldCandidate") (EVar "fname")) (EVar "lim")) (EVar "cs")) (EVar "acc")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "bestFieldCandidate") (EVar "fname")) (EVar "lim")) (EVar "cs")) (EApp (EApp (EApp (EVar "keepBetterField") (EVar "c")) (EApp (EApp (EVar "editDistance") (EVar "fname")) (EVar "c"))) (EVar "acc"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "keepBetterField" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Int"))) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Int")))))))
(DFunDef false "keepBetterField" ((PVar "c") (PVar "d") (PCon "None")) (EApp (EVar "Some") (ETuple (EVar "c") (EVar "d"))))
(DFunDef false "keepBetterField" ((PVar "c") (PVar "d") (PCon "Some" (PTuple (PVar "bc") (PVar "bd")))) (EIf (EBinOp "||" (EBinOp "<" (EVar "d") (EVar "bd")) (EBinOp "&&" (EBinOp "==" (EVar "d") (EVar "bd")) (EBinOp "<" (EVar "c") (EVar "bc")))) (EApp (EVar "Some") (ETuple (EVar "c") (EVar "d"))) (EApp (EVar "Some") (ETuple (EVar "bc") (EVar "bd")))))
(DTypeSig true "unknownRecordFresh" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyCon "Mono"))))
(DFunDef false "unknownRecordFresh" ((PVar "mctx") (PVar "name")) (EBlock (DoExpr (EApp (EApp (EApp (EVar "pushTypeError") (EVar "mctx")) (ELit (LString "T-UNKNOWN-RECORD"))) (EApp (EVar "unknownRecordMsg") (EVar "name")))) (DoExpr (EApp (EApp (EVar "freshVar") (EVar "mctx")) (ELit LUnit)))))
(DTypeSig true "firstFieldName" (TyFun (TyApp (TyCon "List") (TyCon "FieldAssign")) (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "firstFieldName" ((PList)) (EVar "None"))
(DFunDef false "firstFieldName" ((PCons (PCon "FieldAssign" (PVar "fn") PWild) PWild)) (EApp (EVar "Some") (EVar "fn")))
(DTypeSig true "instantiateRecordShared" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "RecordInfo") (TyTuple (TyCon "RecordSubst") (TyCon "Mono")))))
(DFunDef false "instantiateRecordShared" ((PVar "mctx") (PCon "RecordInfo" (PVar "paramIds") (PVar "authIds") (PVar "result") (PVar "fields") PWild)) (EBlock (DoLet false false (PVar "subst") (EApp (EApp (EVar "freshSubst") (EVar "mctx")) (EVar "paramIds"))) (DoLet false false (PVar "cells") (EApp (EApp (EApp (EVar "recordAuthCells") (EVar "authIds")) (EVar "result")) (EVar "fields"))) (DoLet false false (PVar "asub") (EApp (EApp (EVar "map") (ELam ((PVar "id")) (ETuple (EVar "id") (EApp (EApp (EApp (EVar "sharedAuthority") (EVar "mctx")) (EVar "id")) (EApp (EApp (EVar "IdMap.get") (EVar "id")) (EVar "cells")))))) (EVar "authIds"))) (DoExpr (ETuple (EApp (EApp (EVar "RecordSubst") (EVar "subst")) (EVar "asub")) (EApp (EApp (EApp (EApp (EApp (EVar "substMono") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "subst")) (EListLit)) (EVar "asub")) (EVar "result"))))))
(DTypeSig true "instantiateRecordUpdate" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "RecordInfo") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyTuple (TyCon "RecordSubst") (TyCon "Mono")))))))
(DFunDef false "instantiateRecordUpdate" ((PVar "mctx") (PVar "rname") (PCon "RecordInfo" (PVar "paramIds") (PVar "authIds") (PVar "result") (PVar "fields") PWild) (PVar "assigned")) (EBlock (DoLet false false (PVar "subst") (EApp (EApp (EVar "freshSubst") (EVar "mctx")) (EVar "paramIds"))) (DoLet false false (PVar "cells") (EApp (EApp (EApp (EVar "recordAuthCells") (EVar "authIds")) (EVar "result")) (EVar "fields"))) (DoLet false false (PVar "asub") (EApp (EApp (EVar "map") (ELam ((PVar "id")) (ETuple (EVar "id") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "updateAuthority") (EVar "mctx")) (EVar "rname")) (EVar "fields")) (EVar "assigned")) (EVar "id")) (EApp (EApp (EVar "IdMap.get") (EVar "id")) (EVar "cells")))))) (EVar "authIds"))) (DoExpr (ETuple (EApp (EApp (EVar "RecordSubst") (EVar "subst")) (EVar "asub")) (EApp (EApp (EApp (EApp (EApp (EVar "substMono") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "subst")) (EListLit)) (EVar "asub")) (EVar "result"))))))
(DTypeSig false "updateAuthority" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyApp (TyCon "Ref") (TyCon "Authvar"))) (TyCon "Authority"))))))))
(DFunDef false "updateAuthority" ((PVar "mctx") (PVar "rname") (PVar "fields") (PVar "assigned") (PVar "id") (PVar "source")) (EIf (EApp (EApp (EVar "IdMap.has") (EVar "id")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "graphRun") "ctorExistentialsRef") "value")) (EBlock (DoLet false false (PVar "mentioning") (EApp (EApp (EVar "map") (EVar "fst")) (EApp (EApp (EVar "filterList") (ELam ((PVar "f")) (EApp (EApp (EVar "IdMap.has") (EVar "id")) (EApp (EApp (EVar "authCellsIn") (EApp (EVar "snd") (EVar "f"))) (EVar "Tip"))))) (EVar "fields")))) (DoLet false false (PVar "replaced") (EApp (EApp (EVar "filterList") (ELam ((PVar "n")) (EApp (EApp (EVar "contains") (EVar "n")) (EVar "assigned")))) (EVar "mentioning"))) (DoExpr (EIf (EApp (EVar "isEmptyL") (EVar "replaced")) (EApp (EApp (EApp (EVar "sharedAuthority") (EVar "mctx")) (EVar "id")) (EVar "source")) (EIf (EBinOp "==" (EApp (EVar "listLen") (EVar "replaced")) (EApp (EVar "listLen") (EVar "mentioning"))) (EApp (EVar "AVar") (EApp (EApp (EApp (EVar "freshInferenceAuthvar") (EVar "mctx")) (EVar "id")) (EVar "source"))) (EBlock (DoExpr (EApp (EApp (EApp (EVar "pushTypeError") (EVar "mctx")) (ELit (LString "T-AUTHORITY-EXISTENTIAL-SCOPE"))) (EApp (EApp (EVar "partialExistentialUpdateMsg") (EVar "rname")) (EVar "mentioning")))) (DoExpr (EApp (EVar "AVar") (EApp (EApp (EApp (EVar "freshInferenceAuthvar") (EVar "mctx")) (EVar "id")) (EVar "source"))))))))) (EIf (EVar "otherwise") (EApp (EVar "AVar") (EApp (EApp (EApp (EVar "freshInferenceAuthvar") (EVar "mctx")) (EVar "id")) (EVar "source"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "sharedAuthority" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyApp (TyCon "Ref") (TyCon "Authvar"))) (TyCon "Authority")))))
(DFunDef false "sharedAuthority" ((PVar "mctx") (PVar "id") (PVar "source")) (EIf (EApp (EApp (EVar "IdMap.has") (EVar "id")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "graphRun") "ctorExistentialsRef") "value")) (EMatch (EVar "source") (arm (PCon "Some" (PVar "cell")) () (EApp (EVar "authTop") (EApp (EVar "authvarDomain") (EVar "cell")))) (arm (PCon "None") () (EApp (EVar "authTop") (EVar "PUnit")))) (EIf (EVar "otherwise") (EApp (EVar "AVar") (EApp (EApp (EApp (EVar "freshInferenceAuthvar") (EVar "mctx")) (EVar "id")) (EVar "source"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "substRecordField" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "RecordSubst") (TyFun (TyCon "Mono") (TyCon "Mono")))))
(DFunDef false "substRecordField" ((PVar "gctx") (PCon "RecordSubst" (PVar "subst") (PVar "asub")) (PVar "fm")) (EApp (EApp (EApp (EApp (EApp (EVar "substMono") (EVar "gctx")) (EVar "subst")) (EListLit)) (EVar "asub")) (EVar "fm")))
(DTypeSig true "recordFieldMap" (TyFun (TyCon "RecordInfo") (TyApp (TyCon "OrdMap") (TyCon "Mono"))))
(DFunDef false "recordFieldMap" ((PCon "RecordInfo" PWild PWild PWild PWild (PVar "idx"))) (EVar "idx"))
(DTypeSig true "recordFieldNames" (TyFun (TyCon "RecordInfo") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "recordFieldNames" ((PCon "RecordInfo" PWild PWild PWild (PVar "fields") PWild)) (EApp (EApp (EVar "map") (EVar "fst")) (EVar "fields")))
# MARK
(DUse false (UseGroup ("types" "tc_types") ((mem "CtorFieldConflict" true) (mem "DynCtx" false) (mem "GraphCtx" false) (mem "ModuleCtx" false) (mem "RecordInfo" false) (mem "RecordSubst" false))))
(DUse false (UseGroup ("types" "tc_mono") ((mem "authCellsIn" false) (mem "authSame" false) (mem "headTyconMono" false) (mem "headTyconNameMono" false) (mem "monoSameGiven" false) (mem "recordAuthCells" false) (mem "recordOwnerModule" false) (mem "recordResultMono" false) (mem "rowSame" false) (mem "substMono" false) (mem "tyvarId" false))))
(DUse false (UseGroup ("types" "tc_diag_text") ((mem "abstractFieldMsg" false) (mem "ambiguousFieldDeclsMsg" false) (mem "ambiguousFieldMsg" false) (mem "fieldFixFrom" false) (mem "fieldNotInAllCtorsMsg" false) (mem "fieldPositionDiffersMsg" false) (mem "fieldTypeDiffersMsg" false) (mem "missingFieldMsg" false) (mem "partialExistentialUpdateMsg" false) (mem "unknownFieldMsg" false) (mem "unknownRecordMsg" false) (mem "updateMultiCtorMsg" false))))
(DUse false (UseGroup ("types" "tc_env") ((mem "lookupRecordByName" false) (mem "recordCandInfo" false))))
(DUse false (UseGroup ("types" "tc_diag") ((mem "pushTypeError" false) (mem "pushTypeErrorHelpFixAt" false))))
(DUse false (UseGroup ("types" "tc_unify") ((mem "freshInferenceAuthvar" false) (mem "freshSubst" false) (mem "freshVar" false) (mem "poisonMismatchVars" false) (mem "unifyIn" false))))
(DUse false (UseGroup ("types" "effect_authority") ((mem "Authority" true) (mem "Authvar" true) (mem "authTop" false) (mem "authvarDomain" false) (mem "authvarId" false))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "EffRow" true) (mem "Effvar" true) (mem "effvarId" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "FieldAssign" true) (mem "Ident" true) (mem "TabKey" true))))
(DUse false (UseGroup ("types" "registry") ((mem "HeadKey" true) (mem "headKeyTag" false) (mem "headKeyIdent" false) (mem "headKeyDecl" false) (mem "spCandsOf" false) (mem "spRows" false))))
(DUse false (UseGroup ("types" "repr") ((mem "Mono" true) (mem "normalize" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "omHasKey" false) (mem "omLookup" false) (mem "omSize" false) (mem "OrdMap" false))))
(DUse false (UseGroup ("types" "effect_domain") ((mem "Param" true))))
(DUse false (UseGroup ("map") ((mem "Map" true))))
(DUse false (UseGroup ("support" "util") ((mem "contains" false) (mem "dedupBy" false) (mem "editDistance" false) (mem "filterList" false) (mem "isEmptyL" false) (mem "isSome" false) (mem "listLen" false) (mem "orElseOpt" false) (mem "sortUniqS" false))))
(DUse false (UseGroup ("list") ((mem "elemIndex" false) (mem "head" false))))
(DUse false (UseGroup ("types" "private_mangle") ((mem "isReservedCtor" false) (mem "mangledName" false))))
(DUse false (UseGroup ("frontend" "exhaust") ((mem "oGetCtors" false))))
(DUse false (UseAlias ("map") "IdMap"))
(DTypeSig true "fieldAssignNamePair" (TyFun (TyCon "FieldAssign") (TyTuple (TyCon "String") (TyCon "Unit"))))
(DFunDef false "fieldAssignNamePair" ((PCon "FieldAssign" (PVar "fn") PWild)) (ETuple (EVar "fn") (ELit LUnit)))
(DTypeSig true "assignedFieldNames" (TyFun (TyApp (TyCon "List") (TyCon "FieldAssign")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "assignedFieldNames" ((PVar "fields")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "fa")) (EApp (EVar "fst") (EApp (EVar "fieldAssignNamePair") (EVar "fa"))))) (EVar "fields")))
(DTypeSig true "checkMissingFields" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyCon "Unit"))))))
(DFunDef false "checkMissingFields" ((PVar "mctx") PWild (PList) PWild) (ELit LUnit))
(DFunDef false "checkMissingFields" ((PVar "mctx") (PVar "rname") (PCons (PVar "fname") (PVar "rest")) (PVar "supplied")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "fname")) (EVar "supplied")) (EApp (EApp (EApp (EApp (EVar "checkMissingFields") (EVar "mctx")) (EVar "rname")) (EVar "rest")) (EVar "supplied")) (EIf (EVar "otherwise") (EBlock (DoExpr (EApp (EApp (EApp (EVar "pushTypeError") (EVar "mctx")) (ELit (LString "T-MISSING-FIELD"))) (EApp (EApp (EVar "missingFieldMsg") (EVar "fname")) (EVar "rname")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "checkMissingFields") (EVar "mctx")) (EVar "rname")) (EVar "rest")) (EVar "supplied")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "stampedRecordHead" (TyFun (TyCon "String") (TyFun (TyCon "RecordInfo") (TyCon "String"))))
(DFunDef false "stampedRecordHead" ((PVar "rname") (PVar "ri")) (EMatch (EApp (EVar "recordOwnerModule") (EVar "ri")) (arm (PCon "None") () (EVar "rname")) (arm (PCon "Some" (PVar "mid")) () (EApp (EApp (EVar "ownerQualifiedHead") (EVar "mid")) (EVar "rname")))))
(DTypeSig false "ownerQualifiedHead" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "ownerQualifiedHead" ((PVar "mid") (PVar "name")) (EIf (EApp (EVar "isReservedCtor") (EVar "name")) (EVar "name") (EIf (EVar "otherwise") (EApp (EApp (EVar "mangledName") (EVar "mid")) (EVar "name")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "inferFieldOfRecord" (TyFun (TyCon "DynCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "String") (TyFun (TyCon "RecordInfo") (TyFun (TyCon "String") (TyCon "Mono")))))))
(DFunDef false "inferFieldOfRecord" ((PVar "dyn") (PVar "te") (PVar "rname") (PVar "ri") (PVar "fname")) (EBlock (DoLet false false (PVar "sr") (EApp (EApp (EVar "instantiateRecordShared") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "ri"))) (DoExpr (EApp (EApp (EApp (EVar "unifyIn") (EVar "dyn")) (EVar "te")) (EApp (EVar "snd") (EVar "sr")))) (DoExpr (EMatch (EApp (EApp (EVar "omLookup") (EVar "fname")) (EApp (EVar "recordFieldMap") (EVar "ri"))) (arm (PCon "Some" (PVar "fm")) () (EApp (EApp (EApp (EVar "substRecordField") (EFieldAccess (EFieldAccess (EVar "dyn") "dcModule") "mcGraph")) (EApp (EVar "fst") (EVar "sr"))) (EVar "fm"))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "unknownFieldFresh") (EFieldAccess (EVar "dyn") "dcModule")) (EVar "fname")) (EVar "rname")) (EApp (EVar "recordFieldNames") (EVar "ri"))))))))
(DTypeSig true "fieldSelectionWellTyped" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "String") (TyFun (TyCon "RecordInfo") (TyFun (TyCon "String") (TyFun (TyCon "Mono") (TyCon "Mono"))))))))
(DFunDef false "fieldSelectionWellTyped" ((PVar "mctx") (PVar "te") (PVar "rname") (PVar "ri") (PVar "fname") (PVar "ft")) (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "ctorFieldConflictHere") (EVar "mctx")) (EVar "te")) (EVar "rname")) (EVar "ri")) (EVar "fname")) (arm (PCon "None") () (EVar "ft")) (arm (PCon "Some" (PVar "conflict")) () (EBlock (DoExpr (EApp (EApp (EApp (EApp (EVar "pushCtorFieldConflict") (EVar "mctx")) (EVar "fname")) (EApp (EApp (EVar "optionOr") (EVar "rname")) (EApp (EVar "headTyconNameMono") (EVar "te")))) (EVar "conflict"))) (DoLet false false (PVar "v") (EApp (EApp (EVar "freshVar") (EVar "mctx")) (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EVar "poisonMismatchVars") (EVar "mctx")) (EVar "v")) (EVar "v"))) (DoExpr (EVar "v"))))))
(DTypeSig false "ctorFieldConflictHere" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "String") (TyFun (TyCon "RecordInfo") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "CtorFieldConflict"))))))))
(DFunDef false "ctorFieldConflictHere" ((PVar "mctx") (PVar "te") (PVar "rname") (PVar "ri") (PVar "fname")) (EMatch (EApp (EVar "headTyconMono") (EVar "te")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "hk")) () (EIf (EBinOp "==" (EApp (EVar "Some") (EVar "hk")) (EApp (EVar "headTyconMono") (EApp (EVar "recordResultMono") (EVar "ri")))) (EApp (EApp (EApp (EApp (EVar "ctorFieldConflict") (EVar "mctx")) (EVar "hk")) (EVar "fname")) (EVar "rname")) (EVar "None")))))
(DTypeSig false "ctorFieldConflict" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "HeadKey") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "CtorFieldConflict")))))))
(DFunDef false "ctorFieldConflict" ((PVar "mctx") (PVar "hk") (PVar "fname") (PVar "rname")) (EMatch (EApp (EApp (EApp (EApp (EVar "ctorSiblingWithholdingName") (EVar "mctx")) (EApp (EVar "Some") (EVar "hk"))) (EVar "fname")) (EVar "rname")) (arm (PCon "Some" (PVar "sib")) () (EApp (EVar "Some") (EApp (EVar "CtorWithholds") (EVar "sib")))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "ctorsOfHead") (EVar "mctx")) (EVar "hk")) (arm (PCon "Some" (PAs "ctors" (PCons PWild (PCons PWild PWild)))) () (EBlock (DoLet false false (PVar "held") (EApp (EApp (EApp (EApp (EVar "ctorFieldSlots") (EVar "mctx")) (EVar "hk")) (EVar "fname")) (EVar "ctors"))) (DoExpr (EApp (EApp (EVar "orElseOpt") (EApp (EVar "firstSlotDisagreement") (EVar "held"))) (EApp (EApp (EApp (EVar "firstTypeDisagreement") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "fname")) (EVar "held")))))) (arm PWild () (EVar "None"))))))
(DTypeSig false "ctorsOfHead" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "HeadKey") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "ctorsOfHead" ((PVar "mctx") (PVar "hk")) (EMatch (EApp (EVar "ctorOracleKeyOf") (EApp (EVar "Some") (EVar "hk"))) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "tk")) () (EApp (EApp (EVar "oGetCtors") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "matchOracle") "value")) (EVar "tk")))))
(DTypeSig false "ctorFieldSlots" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "HeadKey") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "RecordInfo"))))))))
(DFunDef false "ctorFieldSlots" ((PVar "mctx") (PVar "hk") (PVar "fname") (PVar "ctors")) (EApp (EApp (EMethodRef "filterMap") (EApp (EApp (EApp (EVar "ctorFieldSlot") (EVar "mctx")) (EVar "hk")) (EVar "fname"))) (EVar "ctors")))
(DTypeSig false "ctorFieldSlot" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "HeadKey") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "RecordInfo"))))))))
(DFunDef false "ctorFieldSlot" ((PVar "mctx") (PVar "hk") (PVar "fname") (PVar "k")) (EMatch (EApp (EApp (EApp (EVar "ctorRecordOfType") (EVar "mctx")) (EVar "hk")) (EVar "k")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "ri")) () (EApp (EApp (EMethodRef "map") (ELam ((PVar "i")) (ETuple (EVar "k") (EVar "i") (EVar "ri")))) (EApp (EApp (EVar "elemIndex") (EVar "fname")) (EApp (EVar "recordFieldNames") (EVar "ri")))))))
(DTypeSig false "firstSlotDisagreement" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "RecordInfo"))) (TyApp (TyCon "Option") (TyCon "CtorFieldConflict"))))
(DFunDef false "firstSlotDisagreement" ((PList)) (EVar "None"))
(DFunDef false "firstSlotDisagreement" ((PCons (PTuple (PVar "a") (PVar "i") PWild) (PVar "rest"))) (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "b") (PVar "j"))) (EApp (EApp (EApp (EApp (EVar "CtorSlotsDiffer") (EVar "a")) (EVar "i")) (EVar "b")) (EVar "j")))) (EApp (EApp (EVar "slotOtherThan") (EVar "i")) (EVar "rest"))))
(DTypeSig false "slotOtherThan" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "RecordInfo"))) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Int"))))))
(DFunDef false "slotOtherThan" (PWild (PList)) (EVar "None"))
(DFunDef false "slotOtherThan" ((PVar "i") (PCons (PTuple (PVar "b") (PVar "j") PWild) (PVar "rest"))) (EIf (EBinOp "/=" (EVar "j") (EVar "i")) (EApp (EVar "Some") (ETuple (EVar "b") (EVar "j"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "slotOtherThan") (EVar "i")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "firstTypeDisagreement" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "RecordInfo"))) (TyApp (TyCon "Option") (TyCon "CtorFieldConflict"))))))
(DFunDef false "firstTypeDisagreement" ((PVar "gctx") PWild (PList)) (EVar "None"))
(DFunDef false "firstTypeDisagreement" ((PVar "gctx") (PVar "fname") (PCons (PTuple (PVar "a") PWild (PVar "ra")) (PVar "rest"))) (EMatch (EApp (EApp (EVar "omLookup") (EVar "fname")) (EApp (EVar "recordFieldMap") (EVar "ra"))) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "ta")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "typeOtherThan") (EVar "gctx")) (EVar "fname")) (EVar "a")) (EVar "ra")) (EVar "ta")) (EVar "rest")))))
(DTypeSig false "typeOtherThan" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "RecordInfo") (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "RecordInfo"))) (TyApp (TyCon "Option") (TyCon "CtorFieldConflict")))))))))
(DFunDef false "typeOtherThan" ((PVar "gctx") PWild PWild PWild PWild (PList)) (EVar "None"))
(DFunDef false "typeOtherThan" ((PVar "gctx") (PVar "fname") (PVar "a") (PVar "ra") (PVar "ta") (PCons (PTuple (PVar "b") PWild (PVar "rb")) (PVar "rest"))) (EMatch (EApp (EApp (EVar "omLookup") (EVar "fname")) (EApp (EVar "recordFieldMap") (EVar "rb"))) (arm (PCon "Some" (PVar "tb")) () (EBlock (DoLet false false (PTuple (PVar "tsub") (PVar "esub") (PVar "asub")) (EApp (EApp (EApp (EVar "paramRenaming") (EApp (EVar "recordResultMono") (EVar "rb"))) (EApp (EVar "recordResultMono") (EVar "ra"))) (ETuple (EListLit) (EListLit) (EListLit)))) (DoLet false false (PVar "tbOverA") (EApp (EApp (EApp (EApp (EApp (EVar "substMono") (EVar "gctx")) (EVar "tsub")) (EVar "esub")) (EVar "asub")) (EVar "tb"))) (DoExpr (EIf (EApp (EApp (EVar "fieldTypeSame") (EVar "ta")) (EVar "tbOverA")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "typeOtherThan") (EVar "gctx")) (EVar "fname")) (EVar "a")) (EVar "ra")) (EVar "ta")) (EVar "rest")) (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EVar "CtorTypesDiffer") (EVar "a")) (EVar "ta")) (EVar "b")) (EVar "tbOverA"))))))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "typeOtherThan") (EVar "gctx")) (EVar "fname")) (EVar "a")) (EVar "ra")) (EVar "ta")) (EVar "rest")))))
(DTypeSig false "paramRenaming" (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyFun (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyApp (TyCon "Ref") (TyCon "Effvar")))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Authority")))) (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyApp (TyCon "Ref") (TyCon "Effvar")))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Authority"))))))))
(DFunDef false "paramRenaming" ((PVar "from") (PVar "to") (PVar "acc")) (EMatch (EApp (EVar "normalize") (EVar "from")) (arm (PCon "TApp" (PVar "f1") (PVar "a1")) () (EMatch (EApp (EVar "normalize") (EVar "to")) (arm (PCon "TApp" (PVar "f2") (PVar "a2")) () (EApp (EApp (EApp (EVar "paramRenaming") (EVar "f1")) (EVar "f2")) (EApp (EApp (EApp (EVar "renameParam") (EApp (EVar "normalize") (EVar "a1"))) (EVar "a2")) (EVar "acc")))) (arm PWild () (EVar "acc")))) (arm PWild () (EVar "acc"))))
(DTypeSig false "renameParam" (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyFun (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyApp (TyCon "Ref") (TyCon "Effvar")))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Authority")))) (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Mono"))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyApp (TyCon "Ref") (TyCon "Effvar")))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Authority"))))))))
(DFunDef false "renameParam" ((PCon "TVar" (PVar "c")) (PVar "to") (PTuple (PVar "ts") (PVar "es") (PVar "qs"))) (ETuple (EBinOp "::" (ETuple (EApp (EVar "tyvarId") (EVar "c")) (EVar "to")) (EVar "ts")) (EVar "es") (EVar "qs")))
(DFunDef false "renameParam" ((PCon "TEff" (PCon "EffRow" (PList) (PCon "Some" (PVar "e1")))) (PCon "TEff" (PCon "EffRow" (PList) (PCon "Some" (PVar "e2")))) (PTuple (PVar "ts") (PVar "es") (PVar "qs"))) (ETuple (EVar "ts") (EBinOp "::" (ETuple (EApp (EVar "effvarId") (EVar "e1")) (EVar "e2")) (EVar "es")) (EVar "qs")))
(DFunDef false "renameParam" ((PCon "TAuth" (PCon "AVar" (PVar "q1"))) (PCon "TAuth" (PVar "q2")) (PTuple (PVar "ts") (PVar "es") (PVar "qs"))) (ETuple (EVar "ts") (EVar "es") (EBinOp "::" (ETuple (EApp (EVar "authvarId") (EVar "q1")) (EVar "q2")) (EVar "qs"))))
(DFunDef false "renameParam" (PWild PWild (PVar "acc")) (EVar "acc"))
(DTypeSig false "fieldTypeSame" (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "Bool"))))
(DFunDef false "fieldTypeSame" ((PVar "x") (PVar "y")) (EMatch (ETuple (EApp (EVar "normalize") (EVar "x")) (EApp (EVar "normalize") (EVar "y"))) (arm (PTuple (PCon "TFun" (PVar "a1") (PVar "r1") (PVar "b1")) (PCon "TFun" (PVar "a2") (PVar "r2") (PVar "b2"))) () (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "fieldTypeSame") (EVar "a1")) (EVar "a2")) (EApp (EApp (EVar "rowSame") (EVar "r1")) (EVar "r2"))) (EApp (EApp (EVar "fieldTypeSame") (EVar "b1")) (EVar "b2")))) (arm (PTuple (PCon "TApp" (PVar "a1") (PVar "b1")) (PCon "TApp" (PVar "a2") (PVar "b2"))) () (EBinOp "&&" (EApp (EApp (EVar "fieldTypeSame") (EVar "a1")) (EVar "a2")) (EApp (EApp (EVar "fieldTypeSame") (EVar "b1")) (EVar "b2")))) (arm (PTuple (PCon "TEff" (PVar "r1")) (PCon "TEff" (PVar "r2"))) () (EApp (EApp (EVar "rowSame") (EVar "r1")) (EVar "r2"))) (arm (PTuple (PCon "TQual" (PVar "t1") (PVar "q1")) (PCon "TQual" (PVar "t2") (PVar "q2"))) () (EBinOp "&&" (EApp (EApp (EVar "fieldTypeSame") (EVar "t1")) (EVar "t2")) (EApp (EApp (EVar "authSame") (EVar "q1")) (EVar "q2")))) (arm (PTuple (PCon "TAuth" (PVar "q1")) (PCon "TAuth" (PVar "q2"))) () (EApp (EApp (EVar "authSame") (EVar "q1")) (EVar "q2"))) (arm (PTuple (PCon "TFun" PWild PWild PWild) PWild) () (EVar "False")) (arm (PTuple (PCon "TApp" PWild PWild) PWild) () (EVar "False")) (arm (PTuple (PCon "TEff" PWild) PWild) () (EVar "False")) (arm (PTuple (PCon "TAuth" PWild) PWild) () (EVar "False")) (arm (PTuple (PCon "TQual" (PVar "t1") PWild) (PVar "b")) () (EApp (EApp (EVar "fieldTypeSame") (EVar "t1")) (EVar "b"))) (arm (PTuple (PVar "a") (PCon "TQual" (PVar "t2") PWild)) () (EApp (EApp (EVar "fieldTypeSame") (EVar "a")) (EVar "t2"))) (arm (PTuple (PVar "a") (PVar "b")) () (EApp (EApp (EVar "monoSameGiven") (EVar "a")) (EVar "b")))))
(DTypeSig false "pushCtorFieldConflict" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "CtorFieldConflict") (TyCon "Unit"))))))
(DFunDef false "pushCtorFieldConflict" ((PVar "mctx") (PVar "fname") (PVar "tname") (PCon "CtorWithholds" (PVar "sib"))) (EApp (EApp (EApp (EVar "pushTypeError") (EVar "mctx")) (ELit (LString "T-FIELD-NOT-IN-ALL-CTORS"))) (EApp (EApp (EApp (EVar "fieldNotInAllCtorsMsg") (EVar "fname")) (EVar "tname")) (EVar "sib"))))
(DFunDef false "pushCtorFieldConflict" ((PVar "mctx") (PVar "fname") (PVar "tname") (PCon "CtorSlotsDiffer" (PVar "a") (PVar "i") (PVar "b") (PVar "j"))) (EApp (EApp (EApp (EVar "pushTypeError") (EVar "mctx")) (ELit (LString "T-FIELD-POSITION-DIFFERS"))) (EApp (EApp (EApp (EApp (EVar "fieldPositionDiffersMsg") (EVar "fname")) (EVar "tname")) (ETuple (EVar "a") (EVar "i"))) (ETuple (EVar "b") (EVar "j")))))
(DFunDef false "pushCtorFieldConflict" ((PVar "mctx") (PVar "fname") (PVar "tname") (PCon "CtorTypesDiffer" (PVar "a") (PVar "ta") (PVar "b") (PVar "tb"))) (EApp (EApp (EApp (EVar "pushTypeError") (EVar "mctx")) (ELit (LString "T-FIELD-TYPE-DIFFERS"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "fieldTypeDiffersMsg") (EVar "fname")) (EVar "tname")) (EVar "a")) (EVar "ta")) (EVar "b")) (EVar "tb"))))
(DTypeSig true "recordUpdateWellTyped" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "String") (TyFun (TyCon "RecordInfo") (TyFun (TyCon "String") (TyCon "Unit")))))))
(DFunDef false "recordUpdateWellTyped" ((PVar "mctx") (PVar "bt") (PVar "rname") (PVar "ri") (PVar "fn")) (EMatch (EApp (EVar "headTyconMono") (EVar "bt")) (arm (PCon "None") () (ELit LUnit)) (arm (PCon "Some" (PVar "hk")) () (EIf (EBinOp "==" (EApp (EVar "Some") (EVar "hk")) (EApp (EVar "headTyconMono") (EApp (EVar "recordResultMono") (EVar "ri")))) (EMatch (EApp (EApp (EVar "ctorsOfHead") (EVar "mctx")) (EVar "hk")) (arm (PCon "Some" (PAs "ctors" (PCons PWild (PCons PWild PWild)))) () (EApp (EApp (EApp (EVar "pushTypeError") (EVar "mctx")) (ELit (LString "T-UPDATE-MULTI-CTOR"))) (EApp (EApp (EApp (EApp (EApp (EVar "updateMultiCtorMsg") (EVar "fn")) (EApp (EApp (EVar "optionOr") (EVar "rname")) (EApp (EVar "headTyconNameMono") (EVar "bt")))) (EVar "rname")) (EApp (EApp (EVar "filterList") (ELam ((PVar "_s")) (EBinOp "/=" (EVar "_s") (EVar "fn")))) (EApp (EVar "recordFieldNames") (EVar "ri")))) (EVar "ctors")))) (arm PWild () (ELit LUnit))) (ELit LUnit)))))
(DTypeSig false "fieldOwnerNames" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "fieldOwnerNames" ((PVar "mctx") (PVar "fname")) (EApp (EApp (EVar "fieldOwnerReachFilter") (EVar "mctx")) (EApp (EVar "sortUniqS") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "fname")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "fieldOwnersRef") "value"))))))
(DTypeSig false "fieldOwnerReachFilter" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "fieldOwnerReachFilter" ((PVar "mctx") (PVar "owners")) (EMatch (EApp (EApp (EVar "filterList") (EApp (EVar "fieldOwnerReachable") (EVar "mctx"))) (EVar "owners")) (arm (PList) () (EVar "owners")) (arm (PVar "kept") () (EVar "kept"))))
(DTypeSig false "fieldOwnerReachable" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "fieldOwnerReachable" ((PVar "mctx") (PVar "key")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "key")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "fieldOwnerModulesRef") "value")) (arm (PCon "None") () (EVar "True")) (arm (PCon "Some" (PVar "mids")) () (EApp (EApp (EVar "fieldOwnerAnyReachable") (EVar "mctx")) (EVar "mids")))))
(DTypeSig false "fieldOwnerAnyReachable" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "fieldOwnerAnyReachable" ((PVar "mctx") (PList)) (EVar "False"))
(DFunDef false "fieldOwnerAnyReachable" ((PVar "mctx") (PCons (PVar "m") (PVar "rest"))) (EBinOp "||" (EApp (EApp (EVar "omHasKey") (EVar "m")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "fieldOwnerReachRef") "value")) (EApp (EApp (EVar "fieldOwnerAnyReachable") (EVar "mctx")) (EVar "rest"))))
(DTypeSig true "resolveFieldRecord" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "RecordInfo")))))))
(DFunDef false "resolveFieldRecord" ((PVar "mctx") (PVar "te") (PVar "fname")) (EMatch (EApp (EVar "headTyconNameMono") (EVar "te")) (arm (PCon "Some" (PVar "r")) () (EMatch (EApp (EApp (EApp (EVar "lookupRecordForReceiver") (EVar "mctx")) (EVar "te")) (EVar "r")) (arm (PCon "Some" (PVar "ri")) () (EApp (EVar "Some") (ETuple (EVar "r") (EVar "ri")))) (arm (PCon "None") () (EIf (EApp (EApp (EVar "omHasKey") (EApp (EApp (EVar "receiverTypeWord") (EVar "te")) (EVar "r"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "abstractRecordTypesRef") "value")) (EBlock (DoExpr (EApp (EApp (EApp (EVar "pushTypeError") (EVar "mctx")) (ELit (LString "T-ABSTRACT-FIELD"))) (EApp (EApp (EVar "abstractFieldMsg") (EVar "r")) (EVar "fname")))) (DoExpr (EVar "None"))) (EApp (EApp (EApp (EVar "resolveFieldByOwners") (EVar "mctx")) (EVar "te")) (EVar "fname")))))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "resolveFieldByOwners") (EVar "mctx")) (EVar "te")) (EVar "fname")))))
(DTypeSig false "lookupRecordForReceiver" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "RecordInfo"))))))
(DFunDef false "lookupRecordForReceiver" ((PVar "mctx") (PVar "te") (PVar "r")) (EMatch (EApp (EApp (EApp (EVar "recordForReceiverIdent") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "te")) (EVar "r")) (arm (PCon "Some" (PVar "ri")) () (EApp (EVar "Some") (EVar "ri"))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "lookupRecordByName") (EVar "mctx")) (EVar "r")) (arm (PCon "Some" (PVar "ri")) () (EIf (EApp (EApp (EVar "recordOfOtherType") (EVar "te")) (EVar "ri")) (EVar "None") (EApp (EVar "Some") (EVar "ri")))) (arm (PCon "None") () (EVar "None"))))))
(DTypeSig false "recordOfOtherType" (TyFun (TyCon "Mono") (TyFun (TyCon "RecordInfo") (TyCon "Bool"))))
(DFunDef false "recordOfOtherType" ((PVar "te") (PCon "RecordInfo" PWild PWild (PVar "res") PWild PWild)) (EMatch (ETuple (EApp (EVar "receiverTypeIdent") (EVar "te")) (EApp (EVar "receiverTypeIdent") (EVar "res"))) (arm (PTuple (PCon "Some" (PCon "Ident" PWild (PVar "wo") (PVar "wn"))) (PCon "Some" (PCon "Ident" PWild (PVar "ro") (PVar "rn")))) () (EApp (EVar "not") (EBinOp "&&" (EBinOp "==" (EVar "wn") (EVar "rn")) (EBinOp "==" (EVar "wo") (EVar "ro"))))) (arm PWild () (EVar "False"))))
(DTypeSig false "recordForReceiverIdent" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "RecordInfo"))))))
(DFunDef false "recordForReceiverIdent" ((PVar "gctx") (PVar "te") (PVar "r")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "r")) (EApp (EVar "spRows") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "universeRecordPop") "value"))) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "cs")) () (EMatch (EApp (EVar "receiverTypeIdent") (EVar "te")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "ident")) () (EApp (EApp (EVar "recordCandForType") (EVar "ident")) (EVar "cs")))))))
(DTypeSig false "receiverTypeWord" (TyFun (TyCon "Mono") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "receiverTypeWord" ((PVar "te") (PVar "r")) (EMatch (EApp (EVar "headTyconMono") (EVar "te")) (arm (PCon "Some" (PVar "hk")) () (EApp (EVar "headKeyTag") (EVar "hk"))) (arm (PCon "None") () (EVar "r"))))
(DTypeSig false "receiverTypeIdent" (TyFun (TyCon "Mono") (TyApp (TyCon "Option") (TyCon "Ident"))))
(DFunDef false "receiverTypeIdent" ((PVar "te")) (EMatch (EApp (EVar "headTyconMono") (EVar "te")) (arm (PCon "Some" (PVar "hk")) () (EApp (EVar "headKeyIdent") (EVar "hk"))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "recordCandForType" (TyFun (TyCon "Ident") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Ident") (TyCon "String") (TyCon "RecordInfo"))) (TyApp (TyCon "Option") (TyCon "RecordInfo")))))
(DFunDef false "recordCandForType" (PWild (PList)) (EVar "None"))
(DFunDef false "recordCandForType" ((PVar "want") (PCons (PTuple (PVar "ci") (PVar "tyName") (PVar "ri")) (PVar "rest"))) (EIf (EApp (EApp (EApp (EVar "recordCandIsType") (EVar "want")) (EVar "ci")) (EVar "tyName")) (EApp (EVar "Some") (EVar "ri")) (EIf (EVar "otherwise") (EApp (EApp (EVar "recordCandForType") (EVar "want")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "recordCandIsType" (TyFun (TyCon "Ident") (TyFun (TyCon "Ident") (TyFun (TyCon "String") (TyCon "Bool")))))
(DFunDef false "recordCandIsType" ((PCon "Ident" PWild (PVar "wio") (PVar "wname")) (PCon "Ident" PWild (PVar "cio") PWild) (PVar "tyName")) (EBinOp "&&" (EBinOp "==" (EVar "tyName") (EVar "wname")) (EBinOp "==" (EVar "cio") (EVar "wio"))))
(DTypeSig false "recordCandIsReceiverDecl" (TyFun (TyApp (TyCon "Option") (TyCon "HeadKey")) (TyFun (TyTuple (TyCon "String") (TyCon "RecordInfo")) (TyCon "Bool"))))
(DFunDef false "recordCandIsReceiverDecl" ((PVar "rk") (PTuple PWild (PVar "ri"))) (EBinOp "==" (EVar "rk") (EApp (EVar "headTyconMono") (EApp (EVar "recordResultMono") (EVar "ri")))))
(DTypeSig false "resolveFieldByOwners" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "RecordInfo")))))))
(DFunDef false "resolveFieldByOwners" ((PVar "mctx") (PVar "te") (PVar "fname")) (EBlock (DoLet false false (PVar "owners") (EApp (EApp (EVar "fieldOwnerNames") (EVar "mctx")) (EVar "fname"))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EVar "ownerDeclOfReceiver") (EVar "mctx")) (EVar "te")) (EVar "fname")) (EVar "owners")) (arm (PCon "Some" (PVar "pair")) () (EApp (EVar "Some") (EVar "pair"))) (arm (PCon "None") () (EMatch (EVar "owners") (arm (PList) () (EBlock (DoExpr (EApp (EApp (EApp (EVar "pushUnknownField") (EVar "mctx")) (EVar "fname")) (ELit (LString "<unknown>")))) (DoExpr (EVar "None")))) (arm PWild () (EMatch (EApp (EVar "normalize") (EVar "te")) (arm (PCon "TVar" PWild) () (EApp (EApp (EApp (EVar "resolveFieldUnknownReceiver") (EVar "mctx")) (EVar "fname")) (EVar "owners"))) (arm PWild () (EApp (EApp (EApp (EApp (EVar "resolveFieldAmbiguous") (EVar "mctx")) (EVar "te")) (EVar "fname")) (EVar "owners")))))))))))
(DTypeSig false "resolveFieldUnknownReceiver" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "RecordInfo")))))))
(DFunDef false "resolveFieldUnknownReceiver" ((PVar "mctx") (PVar "fname") (PVar "owners")) (EMatch (EApp (EApp (EApp (EVar "visibleFieldDecls") (EVar "mctx")) (EVar "fname")) (EVar "owners")) (arm (PList (PVar "pair")) () (EApp (EVar "Some") (EVar "pair"))) (arm (PList) () (EMatch (EVar "owners") (arm (PList (PVar "r")) () (EApp (EApp (EVar "pairRecordByName") (EVar "mctx")) (EVar "r"))) (arm PWild () (EBlock (DoExpr (EApp (EApp (EApp (EVar "pushTypeError") (EVar "mctx")) (ELit (LString "T-AMBIGUOUS-FIELD"))) (EApp (EApp (EVar "ambiguousFieldMsg") (EVar "fname")) (EVar "owners")))) (DoExpr (EVar "None")))))) (arm (PVar "cands") () (EBlock (DoExpr (EApp (EApp (EApp (EVar "pushTypeError") (EVar "mctx")) (ELit (LString "T-AMBIGUOUS-FIELD"))) (EApp (EApp (EApp (EVar "ambiguousFieldDeclsMsg") (EVar "fname")) (EVar "owners")) (EVar "cands")))) (DoExpr (EVar "None"))))))
(DTypeSig false "visibleFieldDecls" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "RecordInfo")))))))
(DFunDef false "visibleFieldDecls" ((PVar "mctx") (PVar "fname") (PVar "owners")) (EApp (EApp (EVar "dedupBy") (EVar "fieldDeclTypeKey")) (EApp (EApp (EVar "fieldDeclReachFilter") (EVar "mctx")) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "keyFieldDecls") (EVar "mctx")) (EVar "fname"))) (EVar "owners")))))
(DTypeSig false "keyFieldDecls" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "RecordInfo")))))))
(DFunDef false "keyFieldDecls" ((PVar "mctx") (PVar "fname") (PVar "k")) (EBlock (DoLet false false (PVar "rows") (EApp (EApp (EMethodRef "map") (ELam ((PVar "c")) (ETuple (EVar "k") (EApp (EVar "recordCandInfo") (EVar "c"))))) (EApp (EApp (EVar "spCandsOf") (EVar "k")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "crossRun") "universeRecordPop") "value")))) (DoLet false false (PVar "floor") (EMatch (EApp (EApp (EVar "pairRecordByName") (EVar "mctx")) (EVar "k")) (arm (PCon "Some" (PVar "pair")) () (EListLit (EVar "pair"))) (arm (PCon "None") () (EListLit)))) (DoExpr (EApp (EApp (EVar "filterList") (ELam ((PVar "c")) (EApp (EApp (EVar "omHasKey") (EVar "fname")) (EApp (EVar "recordFieldMap") (EApp (EVar "snd") (EVar "c")))))) (EBinOp "++" (EVar "floor") (EVar "rows"))))))
(DTypeSig false "fieldDeclReachFilter" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "RecordInfo"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "RecordInfo"))))))
(DFunDef false "fieldDeclReachFilter" ((PVar "mctx") (PVar "cands")) (EMatch (EApp (EApp (EVar "filterList") (EApp (EVar "fieldDeclReachable") (EVar "mctx"))) (EVar "cands")) (arm (PList) () (EVar "cands")) (arm (PVar "kept") () (EVar "kept"))))
(DTypeSig false "fieldDeclReachable" (TyFun (TyCon "ModuleCtx") (TyFun (TyTuple (TyCon "String") (TyCon "RecordInfo")) (TyCon "Bool"))))
(DFunDef false "fieldDeclReachable" ((PVar "mctx") (PTuple PWild (PVar "ri"))) (EMatch (EApp (EVar "recordOwnerModule") (EVar "ri")) (arm (PCon "None") () (EVar "True")) (arm (PCon "Some" (PVar "mid")) () (EBlock (DoLet false false (PVar "reach") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "fieldOwnerReachRef") "value")) (DoExpr (EBinOp "||" (EBinOp "==" (EApp (EVar "omSize") (EVar "reach")) (ELit (LInt 0))) (EApp (EApp (EVar "omHasKey") (EVar "mid")) (EVar "reach"))))))))
(DTypeSig false "fieldDeclTypeKey" (TyFun (TyTuple (TyCon "String") (TyCon "RecordInfo")) (TyCon "String")))
(DFunDef false "fieldDeclTypeKey" ((PTuple (PVar "k") (PVar "ri"))) (EMatch (EApp (EVar "headTyconMono") (EApp (EVar "recordResultMono") (EVar "ri"))) (arm (PCon "Some" (PVar "hk")) () (EApp (EVar "headKeyTag") (EVar "hk"))) (arm (PCon "None") () (EVar "k"))))
(DTypeSig false "ownerDeclOfReceiver" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "RecordInfo"))))))))
(DFunDef false "ownerDeclOfReceiver" ((PVar "mctx") PWild PWild (PList)) (EVar "None"))
(DFunDef false "ownerDeclOfReceiver" ((PVar "mctx") (PVar "te") (PVar "fname") (PVar "owners")) (EMatch (EApp (EVar "receiverTypeIdent") (EVar "te")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "ident")) () (EMatch (EApp (EApp (EVar "dedupBy") (EVar "fieldDeclTypeKey")) (EApp (EApp (EApp (EVar "ownerDeclMatches") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "ident")) (EVar "owners"))) (arm (PList (PTuple (PVar "k") (PVar "ri"))) () (EIf (EApp (EApp (EApp (EApp (EVar "narrowingBlockedByCtorSibling") (EVar "mctx")) (EApp (EVar "headTyconMono") (EVar "te"))) (EVar "fname")) (EVar "k")) (EVar "None") (EApp (EVar "Some") (ETuple (EVar "k") (EVar "ri"))))) (arm PWild () (EVar "None"))))))
(DTypeSig false "ownerDeclMatches" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Ident") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "RecordInfo")))))))
(DFunDef false "ownerDeclMatches" ((PVar "gctx") PWild (PList)) (EListLit))
(DFunDef false "ownerDeclMatches" ((PVar "gctx") (PVar "ident") (PCons (PVar "k") (PVar "rest"))) (EMatch (EApp (EApp (EVar "omLookup") (EVar "k")) (EApp (EVar "spRows") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "universeRecordPop") "value"))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "ownerDeclMatches") (EVar "gctx")) (EVar "ident")) (EVar "rest"))) (arm (PCon "Some" (PVar "cs")) () (EMatch (EApp (EApp (EVar "recordCandForType") (EVar "ident")) (EVar "cs")) (arm (PCon "None") () (EApp (EApp (EApp (EVar "ownerDeclMatches") (EVar "gctx")) (EVar "ident")) (EVar "rest"))) (arm (PCon "Some" (PVar "ri")) () (EBinOp "::" (ETuple (EVar "k") (EVar "ri")) (EApp (EApp (EApp (EVar "ownerDeclMatches") (EVar "gctx")) (EVar "ident")) (EVar "rest"))))))))
(DTypeSig false "resolveFieldAmbiguous" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "RecordInfo"))))))))
(DFunDef false "resolveFieldAmbiguous" ((PVar "mctx") PWild PWild (PList (PVar "r"))) (EApp (EApp (EVar "pairRecordByName") (EVar "mctx")) (EVar "r")))
(DFunDef false "resolveFieldAmbiguous" ((PVar "mctx") (PVar "te") (PVar "fname") (PVar "owners")) (EApp (EApp (EApp (EApp (EVar "resolveFieldOwnersNarrowed") (EVar "mctx")) (EVar "te")) (EVar "fname")) (EVar "owners")))
(DTypeSig false "resolveFieldOwnersNarrowed" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Mono") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "RecordInfo"))))))))
(DFunDef false "resolveFieldOwnersNarrowed" ((PVar "mctx") (PVar "te") (PVar "fname") (PVar "owners")) (EBlock (DoLet false false (PVar "rk") (EApp (EVar "headTyconMono") (EVar "te"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "narrowedPick") (EVar "mctx")) (EVar "rk")) (EVar "fname")) (EVar "owners")) (EApp (EApp (EVar "dedupBy") (EVar "fieldDeclTypeKey")) (EApp (EApp (EVar "filterList") (EApp (EVar "recordCandIsReceiverDecl") (EVar "rk"))) (EApp (EApp (EVar "ownerCandidates") (EVar "mctx")) (EVar "owners"))))))))
(DTypeSig false "narrowedPick" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "Option") (TyCon "HeadKey")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "RecordInfo"))) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "RecordInfo")))))))))
(DFunDef false "narrowedPick" ((PVar "mctx") (PVar "rk") (PVar "fname") PWild (PList (PTuple (PVar "k") (PVar "ri")))) (EIf (EApp (EVar "not") (EApp (EApp (EApp (EApp (EVar "narrowingBlockedByCtorSibling") (EVar "mctx")) (EVar "rk")) (EVar "fname")) (EVar "k"))) (EApp (EVar "Some") (ETuple (EVar "k") (EVar "ri"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "narrowedPick" ((PVar "mctx") PWild PWild (PVar "owners") PWild) (EApp (EApp (EVar "pairRecordByName") (EVar "mctx")) (EApp (EApp (EVar "optionOr") (ELit (LString ""))) (EApp (EVar "head") (EVar "owners")))))
(DTypeSig false "narrowingBlockedByCtorSibling" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "Option") (TyCon "HeadKey")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))))
(DFunDef false "narrowingBlockedByCtorSibling" ((PVar "mctx") (PVar "rk") (PVar "fname") (PVar "survivorKey")) (EApp (EVar "isSome") (EApp (EApp (EApp (EApp (EVar "ctorSiblingWithholdingName") (EVar "mctx")) (EVar "rk")) (EVar "fname")) (EVar "survivorKey"))))
(DTypeSig false "ctorSiblingWithholdingName" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "Option") (TyCon "HeadKey")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))))))
(DFunDef false "ctorSiblingWithholdingName" ((PVar "mctx") (PCon "None") PWild PWild) (EVar "None"))
(DFunDef false "ctorSiblingWithholdingName" ((PVar "mctx") (PCon "Some" (PVar "hk")) (PVar "fname") (PVar "survivorKey")) (EMatch (EApp (EApp (EVar "ctorsOfHead") (EVar "mctx")) (EVar "hk")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "ctors")) () (EApp (EApp (EApp (EApp (EApp (EVar "firstCtorSiblingWithholding") (EVar "mctx")) (EVar "hk")) (EVar "fname")) (EVar "survivorKey")) (EVar "ctors")))))
(DTypeSig false "ctorOracleKeyOf" (TyFun (TyApp (TyCon "Option") (TyCon "HeadKey")) (TyApp (TyCon "Option") (TyCon "TabKey"))))
(DFunDef false "ctorOracleKeyOf" ((PCon "None")) (EVar "None"))
(DFunDef false "ctorOracleKeyOf" ((PCon "Some" (PVar "hk"))) (EApp (EVar "headKeyDecl") (EVar "hk")))
(DTypeSig false "firstCtorSiblingWithholding" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "HeadKey") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "String"))))))))
(DFunDef false "firstCtorSiblingWithholding" ((PVar "mctx") PWild PWild PWild (PList)) (EVar "None"))
(DFunDef false "firstCtorSiblingWithholding" ((PVar "mctx") (PVar "hk") (PVar "fname") (PVar "skey") (PCons (PVar "k") (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "skey")) (EApp (EApp (EApp (EApp (EApp (EVar "firstCtorSiblingWithholding") (EVar "mctx")) (EVar "hk")) (EVar "fname")) (EVar "skey")) (EVar "rest")) (EIf (EApp (EApp (EApp (EApp (EVar "ctorSiblingWithholds") (EVar "mctx")) (EVar "hk")) (EVar "fname")) (EVar "k")) (EApp (EVar "Some") (EVar "k")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "firstCtorSiblingWithholding") (EVar "mctx")) (EVar "hk")) (EVar "fname")) (EVar "skey")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "ctorSiblingWithholds" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "HeadKey") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))))
(DFunDef false "ctorSiblingWithholds" ((PVar "mctx") (PVar "hk") (PVar "fname") (PVar "k")) (EMatch (EApp (EApp (EApp (EVar "ctorRecordOfType") (EVar "mctx")) (EVar "hk")) (EVar "k")) (arm (PCon "Some" (PVar "ri")) () (EApp (EVar "isNone") (EApp (EApp (EVar "omLookup") (EVar "fname")) (EApp (EVar "recordFieldMap") (EVar "ri"))))) (arm (PCon "None") () (EVar "True"))))
(DTypeSig false "ctorRecordOfType" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "HeadKey") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "RecordInfo"))))))
(DFunDef false "ctorRecordOfType" ((PVar "mctx") (PVar "hk") (PVar "k")) (EMatch (EApp (EApp (EApp (EVar "ctorRecordFromCompanion") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "hk")) (EVar "k")) (arm (PCon "Some" (PVar "ri")) () (EApp (EVar "Some") (EVar "ri"))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "lookupRecordByName") (EVar "mctx")) (EVar "k")) (arm (PCon "Some" (PVar "ri")) () (EIf (EApp (EApp (EVar "recordCandIsReceiverDecl") (EApp (EVar "Some") (EVar "hk"))) (ETuple (EVar "k") (EVar "ri"))) (EApp (EVar "Some") (EVar "ri")) (EVar "None"))) (arm (PCon "None") () (EVar "None"))))))
(DTypeSig false "ctorRecordFromCompanion" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "HeadKey") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "RecordInfo"))))))
(DFunDef false "ctorRecordFromCompanion" ((PVar "gctx") (PVar "hk") (PVar "k")) (EMatch (EApp (EVar "headKeyIdent") (EVar "hk")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "ident")) () (EMatch (EApp (EApp (EVar "omLookup") (EVar "k")) (EApp (EVar "spRows") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "crossRun") "universeRecordPop") "value"))) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "cs")) () (EApp (EApp (EVar "recordCandForType") (EVar "ident")) (EVar "cs")))))))
(DTypeSig false "ownerCandidates" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "RecordInfo"))))))
(DFunDef false "ownerCandidates" ((PVar "mctx") (PList)) (EListLit))
(DFunDef false "ownerCandidates" ((PVar "mctx") (PCons (PVar "key") (PVar "rest"))) (EMatch (EApp (EApp (EVar "lookupRecordByName") (EVar "mctx")) (EVar "key")) (arm (PCon "Some" (PVar "ri")) () (EBinOp "::" (ETuple (EVar "key") (EVar "ri")) (EApp (EApp (EVar "ownerCandidates") (EVar "mctx")) (EVar "rest")))) (arm (PCon "None") () (EApp (EApp (EVar "ownerCandidates") (EVar "mctx")) (EVar "rest")))))
(DTypeSig false "pairRecordByName" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "RecordInfo"))))))
(DFunDef false "pairRecordByName" ((PVar "mctx") (PVar "r")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "ri")) (ETuple (EVar "r") (EVar "ri")))) (EApp (EApp (EVar "lookupRecordByName") (EVar "mctx")) (EVar "r"))))
(DTypeSig false "pushUnknownField" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Unit")))))
(DFunDef false "pushUnknownField" ((PVar "mctx") (PVar "fname") (PVar "rname")) (EApp (EApp (EApp (EVar "pushTypeError") (EVar "mctx")) (ELit (LString "T-UNKNOWN-FIELD"))) (EApp (EApp (EVar "unknownFieldMsg") (EVar "fname")) (EVar "rname"))))
(DTypeSig false "unknownFieldFresh" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Mono"))))))
(DFunDef false "unknownFieldFresh" ((PVar "mctx") (PVar "fname") (PVar "rname") (PVar "declared")) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EVar "pushUnknownFieldMaybeSuggest") (EVar "mctx")) (EVar "fname")) (EVar "rname")) (EVar "declared"))) (DoLet false false (PVar "v") (EApp (EApp (EVar "freshVar") (EVar "mctx")) (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EVar "poisonMismatchVars") (EVar "mctx")) (EVar "v")) (EVar "v"))) (DoExpr (EVar "v"))))
(DTypeSig false "pushUnknownFieldMaybeSuggest" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Unit"))))))
(DFunDef false "pushUnknownFieldMaybeSuggest" ((PVar "mctx") (PVar "fname") (PVar "rname") (PVar "declared")) (EMatch (EApp (EApp (EVar "suggestField") (EVar "fname")) (EVar "declared")) (arm (PCon "None") () (EApp (EApp (EApp (EVar "pushTypeError") (EVar "mctx")) (ELit (LString "T-UNKNOWN-FIELD"))) (EApp (EApp (EVar "unknownFieldMsg") (EVar "fname")) (EVar "rname")))) (arm (PCon "Some" (PVar "sug")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "pushTypeErrorHelpFixAt") (EVar "mctx")) (ELit (LString "T-UNKNOWN-FIELD"))) (EFieldAccess (EVar "mctx") "mcLoc")) (EBinOp "++" (EApp (EApp (EVar "unknownFieldMsg") (EVar "fname")) (EVar "rname")) (EBinOp "++" (EBinOp "++" (ELit (LString "; did you mean `")) (EApp (EMethodRef "display") (EVar "sug"))) (ELit (LString "`?"))))) (EBinOp "++" (EBinOp "++" (ELit (LString "did you mean `")) (EApp (EMethodRef "display") (EVar "sug"))) (ELit (LString "`?")))) (EApp (EApp (EApp (EVar "fieldFixFrom") (EFieldAccess (EVar "mctx") "mcLoc")) (EVar "fname")) (EVar "sug"))))))
(DTypeSig false "suggestField" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "suggestField" ((PVar "fname") (PVar "declared")) (EIf (EBinOp "<" (EApp (EVar "stringLength") (EVar "fname")) (ELit (LInt 3))) (EVar "None") (EIf (EVar "otherwise") (EApp (EApp (EMethodRef "map") (EVar "fst")) (EApp (EApp (EApp (EApp (EVar "bestFieldCandidate") (EVar "fname")) (ELit (LInt 2))) (EVar "declared")) (EVar "None"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "bestFieldCandidate" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Int"))) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Int"))))))))
(DFunDef false "bestFieldCandidate" (PWild PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "bestFieldCandidate" ((PVar "fname") (PVar "lim") (PCons (PVar "c") (PVar "cs")) (PVar "acc")) (EIf (EBinOp "==" (EVar "c") (EVar "fname")) (EApp (EApp (EApp (EApp (EVar "bestFieldCandidate") (EVar "fname")) (EVar "lim")) (EVar "cs")) (EVar "acc")) (EIf (EBinOp ">" (EApp (EApp (EVar "editDistance") (EVar "fname")) (EVar "c")) (EVar "lim")) (EApp (EApp (EApp (EApp (EVar "bestFieldCandidate") (EVar "fname")) (EVar "lim")) (EVar "cs")) (EVar "acc")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "bestFieldCandidate") (EVar "fname")) (EVar "lim")) (EVar "cs")) (EApp (EApp (EApp (EVar "keepBetterField") (EVar "c")) (EApp (EApp (EVar "editDistance") (EVar "fname")) (EVar "c"))) (EVar "acc"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "keepBetterField" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Int"))) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Int")))))))
(DFunDef false "keepBetterField" ((PVar "c") (PVar "d") (PCon "None")) (EApp (EVar "Some") (ETuple (EVar "c") (EVar "d"))))
(DFunDef false "keepBetterField" ((PVar "c") (PVar "d") (PCon "Some" (PTuple (PVar "bc") (PVar "bd")))) (EIf (EBinOp "||" (EBinOp "<" (EVar "d") (EVar "bd")) (EBinOp "&&" (EBinOp "==" (EVar "d") (EVar "bd")) (EBinOp "<" (EVar "c") (EVar "bc")))) (EApp (EVar "Some") (ETuple (EVar "c") (EVar "d"))) (EApp (EVar "Some") (ETuple (EVar "bc") (EVar "bd")))))
(DTypeSig true "unknownRecordFresh" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyCon "Mono"))))
(DFunDef false "unknownRecordFresh" ((PVar "mctx") (PVar "name")) (EBlock (DoExpr (EApp (EApp (EApp (EVar "pushTypeError") (EVar "mctx")) (ELit (LString "T-UNKNOWN-RECORD"))) (EApp (EVar "unknownRecordMsg") (EVar "name")))) (DoExpr (EApp (EApp (EVar "freshVar") (EVar "mctx")) (ELit LUnit)))))
(DTypeSig true "firstFieldName" (TyFun (TyApp (TyCon "List") (TyCon "FieldAssign")) (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "firstFieldName" ((PList)) (EVar "None"))
(DFunDef false "firstFieldName" ((PCons (PCon "FieldAssign" (PVar "fn") PWild) PWild)) (EApp (EVar "Some") (EVar "fn")))
(DTypeSig true "instantiateRecordShared" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "RecordInfo") (TyTuple (TyCon "RecordSubst") (TyCon "Mono")))))
(DFunDef false "instantiateRecordShared" ((PVar "mctx") (PCon "RecordInfo" (PVar "paramIds") (PVar "authIds") (PVar "result") (PVar "fields") PWild)) (EBlock (DoLet false false (PVar "subst") (EApp (EApp (EVar "freshSubst") (EVar "mctx")) (EVar "paramIds"))) (DoLet false false (PVar "cells") (EApp (EApp (EApp (EVar "recordAuthCells") (EVar "authIds")) (EVar "result")) (EVar "fields"))) (DoLet false false (PVar "asub") (EApp (EApp (EMethodRef "map") (ELam ((PVar "id")) (ETuple (EVar "id") (EApp (EApp (EApp (EVar "sharedAuthority") (EVar "mctx")) (EVar "id")) (EApp (EApp (EVar "IdMap.get") (EVar "id")) (EVar "cells")))))) (EVar "authIds"))) (DoExpr (ETuple (EApp (EApp (EVar "RecordSubst") (EVar "subst")) (EVar "asub")) (EApp (EApp (EApp (EApp (EApp (EVar "substMono") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "subst")) (EListLit)) (EVar "asub")) (EVar "result"))))))
(DTypeSig true "instantiateRecordUpdate" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "RecordInfo") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyTuple (TyCon "RecordSubst") (TyCon "Mono")))))))
(DFunDef false "instantiateRecordUpdate" ((PVar "mctx") (PVar "rname") (PCon "RecordInfo" (PVar "paramIds") (PVar "authIds") (PVar "result") (PVar "fields") PWild) (PVar "assigned")) (EBlock (DoLet false false (PVar "subst") (EApp (EApp (EVar "freshSubst") (EVar "mctx")) (EVar "paramIds"))) (DoLet false false (PVar "cells") (EApp (EApp (EApp (EVar "recordAuthCells") (EVar "authIds")) (EVar "result")) (EVar "fields"))) (DoLet false false (PVar "asub") (EApp (EApp (EMethodRef "map") (ELam ((PVar "id")) (ETuple (EVar "id") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "updateAuthority") (EVar "mctx")) (EVar "rname")) (EVar "fields")) (EVar "assigned")) (EVar "id")) (EApp (EApp (EVar "IdMap.get") (EVar "id")) (EVar "cells")))))) (EVar "authIds"))) (DoExpr (ETuple (EApp (EApp (EVar "RecordSubst") (EVar "subst")) (EVar "asub")) (EApp (EApp (EApp (EApp (EApp (EVar "substMono") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "subst")) (EListLit)) (EVar "asub")) (EVar "result"))))))
(DTypeSig false "updateAuthority" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyApp (TyCon "Ref") (TyCon "Authvar"))) (TyCon "Authority"))))))))
(DFunDef false "updateAuthority" ((PVar "mctx") (PVar "rname") (PVar "fields") (PVar "assigned") (PVar "id") (PVar "source")) (EIf (EApp (EApp (EVar "IdMap.has") (EVar "id")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "graphRun") "ctorExistentialsRef") "value")) (EBlock (DoLet false false (PVar "mentioning") (EApp (EApp (EMethodRef "map") (EVar "fst")) (EApp (EApp (EVar "filterList") (ELam ((PVar "f")) (EApp (EApp (EVar "IdMap.has") (EVar "id")) (EApp (EApp (EVar "authCellsIn") (EApp (EVar "snd") (EVar "f"))) (EVar "Tip"))))) (EVar "fields")))) (DoLet false false (PVar "replaced") (EApp (EApp (EVar "filterList") (ELam ((PVar "n")) (EApp (EApp (EVar "contains") (EVar "n")) (EVar "assigned")))) (EVar "mentioning"))) (DoExpr (EIf (EApp (EVar "isEmptyL") (EVar "replaced")) (EApp (EApp (EApp (EVar "sharedAuthority") (EVar "mctx")) (EVar "id")) (EVar "source")) (EIf (EBinOp "==" (EApp (EVar "listLen") (EVar "replaced")) (EApp (EVar "listLen") (EVar "mentioning"))) (EApp (EVar "AVar") (EApp (EApp (EApp (EVar "freshInferenceAuthvar") (EVar "mctx")) (EVar "id")) (EVar "source"))) (EBlock (DoExpr (EApp (EApp (EApp (EVar "pushTypeError") (EVar "mctx")) (ELit (LString "T-AUTHORITY-EXISTENTIAL-SCOPE"))) (EApp (EApp (EVar "partialExistentialUpdateMsg") (EVar "rname")) (EVar "mentioning")))) (DoExpr (EApp (EVar "AVar") (EApp (EApp (EApp (EVar "freshInferenceAuthvar") (EVar "mctx")) (EVar "id")) (EVar "source"))))))))) (EIf (EVar "otherwise") (EApp (EVar "AVar") (EApp (EApp (EApp (EVar "freshInferenceAuthvar") (EVar "mctx")) (EVar "id")) (EVar "source"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "sharedAuthority" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyApp (TyCon "Ref") (TyCon "Authvar"))) (TyCon "Authority")))))
(DFunDef false "sharedAuthority" ((PVar "mctx") (PVar "id") (PVar "source")) (EIf (EApp (EApp (EVar "IdMap.has") (EVar "id")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "graphRun") "ctorExistentialsRef") "value")) (EMatch (EVar "source") (arm (PCon "Some" (PVar "cell")) () (EApp (EVar "authTop") (EApp (EVar "authvarDomain") (EVar "cell")))) (arm (PCon "None") () (EApp (EVar "authTop") (EVar "PUnit")))) (EIf (EVar "otherwise") (EApp (EVar "AVar") (EApp (EApp (EApp (EVar "freshInferenceAuthvar") (EVar "mctx")) (EVar "id")) (EVar "source"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "substRecordField" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "RecordSubst") (TyFun (TyCon "Mono") (TyCon "Mono")))))
(DFunDef false "substRecordField" ((PVar "gctx") (PCon "RecordSubst" (PVar "subst") (PVar "asub")) (PVar "fm")) (EApp (EApp (EApp (EApp (EApp (EVar "substMono") (EVar "gctx")) (EVar "subst")) (EListLit)) (EVar "asub")) (EVar "fm")))
(DTypeSig true "recordFieldMap" (TyFun (TyCon "RecordInfo") (TyApp (TyCon "OrdMap") (TyCon "Mono"))))
(DFunDef false "recordFieldMap" ((PCon "RecordInfo" PWild PWild PWild PWild (PVar "idx"))) (EVar "idx"))
(DTypeSig true "recordFieldNames" (TyFun (TyCon "RecordInfo") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "recordFieldNames" ((PCon "RecordInfo" PWild PWild PWild (PVar "fields") PWild)) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "fields")))
