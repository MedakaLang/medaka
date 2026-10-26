# META
source_lines=559
stages=DESUGAR,MARK
# SOURCE
-- tc_diag: the emission API over `TcDiag` (`recordTypeError`, the `pushTypeError*` family, dedup
-- keys, ambiguity replacement), the detection counter, `writtenDiag`, the context-free renderers
-- (`backticked`, `quotedNames`); a message builder that needs solver or inference context lives
-- beside its emission site (D3).
--
-- Spec: ERROR-QUALITY.md; DIAGNOSTIC-CODES-DESIGN.md; A5.
--
-- Placement: declarations are placed by R1-R6 of the Phase 4 module table,
-- compiler/ARCHITECTURE-PLAYBOOK.md section 6.
-- Closure rule: this module may not import `types.typecheck`, nor any of `tc_scope`, `tc_unify`,
-- `tc_decls_variance`, `tc_decls_types`, `tc_decls`, `tc_foreign`, `tc_solve_givens`,
-- `tc_solve_entail`, `tc_solve`, `tc_solve_check`, `tc_shadow`, `tc_effects`, `tc_occurrence`,
-- `tc_groups`, `tc_pat`, `tc_infer_records`, `tc_infer`, `tc_elab`, `tc_global`, `tc_module`.

import types.tc_mono.{headTyconMono, headTyconNameMono, monoUnboundIds}
import types.tc_state.{wPush}
import frontend.ast.{
  Decl(..), Expr(..), Ident(..), Loc(..), TabKey(..), identOriginFold, orElseLoc
}
import types.repr.{Mono(..), normalize, ppMono, ppMonosShared, ppPredArgsShared}
import types.tc_types.{
  AbsorptionEvent(..),
  GraphCtx(..),
  ModuleCtx(..),
  Predicate(..),
  UObligation(..),
  Windowed(..),
}
import map as IdMap
export import types.publish.{TcDiag(..), tcCode, tcLoc, tcMsg}
import support.ordmap.{omHasKey, omInsert, omLookup, OrdMap}
import support.util.{
  anyList, contains, filterList, isSome, joinWith, splitOnChar, startsWith
}
import types.registry.{HeadKey(..)}
import types.disposition.{MethodDisposition(..)}

export
locGoalKey : Option Loc -> String
locGoalKey None = ""
locGoalKey (Some (Loc file sl sc el ec)) =
  "\{file}:\{intToString sl}:\{intToString sc}:\{intToString el}:\{intToString ec}"

-- The same question asked during a drive, of the live sticky flag.
export
typeErrorsArmed : GraphCtx -> Unit -> Bool
typeErrorsArmed gctx _ = gctx.typeErrorsSticky.value

-- issue 1146 — the sole writer of the `typeErrors` channel.  Every push, deduped
-- or not, helper-mediated or not, funnels through here, so the three facts one push
-- establishes cannot drift apart at one site and not another: the diagnostic is
-- STORED, the build/run sticky gate is ARMED, and an error OCCURRED.
--
-- It is NOT the sole writer of `ModuleCells.mcCells.errorsDetected` — that would put the
-- counter back in step with the list, which is exactly what PR2 removed.  The counter
-- is bumped by `noteTypeErrorDetected` below, from here AND from each dedup
-- short-circuit, so it counts errors DETECTED rather than errors STORED.  Do not
-- "restore" the equality: a region containing only a deduped push must still answer
-- `erredDuring` True, or a diagnostics decision reaches a control decision again.
--
-- ONE standing obligation, and it is not discharged here: anywhere the channel is
-- ROLLED BACK, this counter must be rolled back WITH it, or a region straddling the
-- rollback would see a detection that no longer has a diagnostic behind it.  No site
-- rolls the channel back within one module record's lifetime today: `checkGraphFinish`
-- rolls back only the two cells that OUTLIVE a module (`typeErrorsSticky` and its
-- message list), around a memo path's drain.  Any future rollback of `typeErrors`
-- owes the same pairing.
--
-- The funnel is not cosmetic.  Before it there were SIX push sites, not the five
-- named helpers: `recordDoMonadError` open-codes its own cons + sticky set.  A
-- hand-placed bump at "the five helpers" would have left that one silent, and the
-- counter would then have UNDER-counted exactly on the `do`-requires-a-monad path.
-- #2068: it is also the sole writer of `typeErrorMsgSetRef`, the membership
-- INDEX the `pushTypeErrorOnce*` helpers and `alreadyReportedAt` test instead of
-- re-scanning the channel (it holds the rendered message and a message-at-site
-- key).  Keeping the insert HERE — inside the one funnel — is what makes the
-- index unable to disagree with the channel: there is no second push site to
-- forget.  A rollback of the channel owes the index the same pairing the counter
-- states above; today there is none within a module record's lifetime (see there).
export
recordTypeError : ModuleCtx -> TcDiag -> Unit
recordTypeError mctx raw =
  let d = writtenDiag raw
  mctx.mcGraph.typeErrorsSticky := True
  mctx.mcGraph.typeErrorsStickyDiags :=
    (mctx.mcCells.currentModuleRef.value, d)
      :: mctx.mcGraph.typeErrorsStickyDiags.value
  let _ = noteTypeErrorDetected mctx ()
  mctx.mcCells.typeErrorMsgSetRef :=
    omInsert
      (msgAtKey (tcMsg d) (tcLoc d))
      ()
      (omInsert (tcMsg d) () mctx.mcCells.typeErrorMsgSetRef.value)
  wPush mctx.mcCells.typeErrors d

-- issue 1146 PR2 — the counter's ONLY incrementing statement, so "an error was
-- detected" is written in one place whether or not the diagnostic is stored.
-- Called from `recordTypeError` (stored) and from all three dedup short-circuits
-- (detected, suppressed as a duplicate).  It deliberately does NOT arm
-- `typeErrorsSticky`: a short-circuit means an identical message is already in the
-- channel, which armed it at its own push, and nothing clears it within the drive.
noteTypeErrorDetected : ModuleCtx -> Unit -> Unit
noteTypeErrorDetected mctx _ =
  mctx.mcCells.errorsDetected := mctx.mcCells.errorsDetected.value + 1

-- issue 1146 — THE polling convention for "did region [act] DETECT an error".
--
-- Three inference sites used to answer that by measuring `listLen typeErrors` before
-- and after the region.  That made the diagnostic accumulator load-bearing CONTROL
-- FLOW rather than a report: any change to how many entries land in it — a dedup-key
-- change, a rendering change, a loc-selection change — could silently flip an
-- inference branch, and a gated `unify` that does not run is a type error that is not
-- caught.  They now read the occurrence COUNTER, through this ONE combinator, so the
-- judgment is implemented once and no diagnostics decision reaches a control decision:
-- the counter records DETECTIONS, and no dedup, rendering, ordering, loc-selection or
-- code-selection choice changes whether an error was detected.
--
-- Read the answer as "an error was detected in [act]", NOT as "[act] added a
-- diagnostic" — since PR2 those differ, and the difference is the point.  Do not
-- re-derive it from `typeErrors`; that reintroduces the coupling this removes.
--
-- Medaka is STRICT, so [act] must be a thunk: `erredDuring (_ => work)`.  Passing
-- the region's VALUE would evaluate it before the first read and always answer False.
export
erredDuring : ModuleCtx -> (Unit -> a) -> (Bool, a)
erredDuring mctx act =
  let before = mctx.mcCells.errorsDetected.value
  let result = act ()
  (mctx.mcCells.errorsDetected.value /= before, result)

-- Push one type-error message at the span of the construct around it.
export
pushTypeError : ModuleCtx -> String -> String -> Unit
pushTypeError mctx code msg =
  recordTypeError mctx (TcDiag code 1 mctx.mcLoc msg None None)

-- Push one type-error message attributed to [loc] rather than the enclosing
-- construct (#414).  Same non-deduping semantics as `pushTypeError` — the
-- deduping `pushTypeErrorOnceAt` is for obligation errors, which two checkers can
-- each detect; a coherence conflict is pushed exactly once per run.  `None` falls
-- back to the enclosing construct's span.
-- The same diagnostic at the same span is one diagnostic: a default body
-- checked generically and again as each instance's copy, or two checks
-- deriving one obligation, report it once.  The identity is the binding, the
-- span and the text: an unlocated diagnostic is never folded, and a probe
-- that parses without location state (every span degenerate and equal)
-- still keeps one report per binding.
export
pushTypeErrorAt : ModuleCtx -> String -> Option Loc -> String -> Unit
pushTypeErrorAt mctx code loc msg =
  let at = orElseLoc loc mctx.mcLoc
  let key = "\{code}\t\{mctx.mcCells.currentFn.value}\t\{locKey at}\t\{msg}"
  if isSome at && omHasKey key mctx.mcCells.typeErrorKeySetRef.value then
    noteTypeErrorDetected mctx ()
  else
    mctx.mcCells.typeErrorKeySetRef :=
      omInsert key () mctx.mcCells.typeErrorKeySetRef.value
    recordTypeError mctx (TcDiag code 1 at msg None None)

export
locKey : Option Loc -> String
locKey None = ""
locKey (Some (Loc file line col _ _)) =
  "\{file}:\{intToString line}:\{intToString col}"

-- #11 soundness: REPORT an obligation error only if the SAME message isn't already
-- accumulated.  A single missing impl can be detected by both checkImplObligations
-- (the original deferred obligation, once it grounds) and checkCallObligations (the
-- call-site instantiation); ERROR-QUALITY dim R/X want one diagnostic per root cause,
-- so the second detection is suppressed from the REPORT.
--
-- issue 1146 PR2: suppressed from the report, NOT from the record of what happened —
-- the short-circuit still calls `noteTypeErrorDetected`.  Dedup is a presentation
-- judgment keyed on rendered text; letting it also decide "did an error occur here"
-- is what made a message-rendering change able to flip an inference branch.
--
-- #2068: the membership test is an OrdMap lookup on `typeErrorMsgSetRef`, not the
-- `anyList (e => tcMsg e == msg) mctx.mcCells.typeErrors.items.value` scan it used
-- to be.  The scan was O(accumulated) per push, hence O(N^2) over a program whose
-- N diagnostics are pairwise DISTINCT — which is the common case for this family
-- (`pushNoImplError` renders the interface AND the type into every message).  It
-- read linear only on a corpus of REPEATED messages, where the first comparison
-- always matched and the list never grew.  The index answers the identical
-- question: `recordTypeError` is the sole writer of both, so a key is present iff
-- a diagnostic with that rendered message is in the channel.
export
pushTypeErrorOnce : ModuleCtx -> String -> String -> Unit
pushTypeErrorOnce mctx code msg =
  if omHasKey msg mctx.mcCells.typeErrorMsgSetRef.value then
    noteTypeErrorDetected mctx ()
  else
    pushTypeError mctx code msg

-- Membership key for "this message at this span".  A located diagnostic is a
-- duplicate only of the same text at the same span, so two sites with identical
-- text each report; an unlocated one folds on text alone.
msgAtKey : String -> Option Loc -> String
msgAtKey msg at = "\{msg}\t@@\t\{locKey at}"

alreadyReportedAt : ModuleCtx -> String -> Option Loc -> Bool
alreadyReportedAt mctx msg None =
  omHasKey msg mctx.mcCells.typeErrorMsgSetRef.value
alreadyReportedAt mctx msg at =
  omHasKey (msgAtKey msg at) mctx.mcCells.typeErrorMsgSetRef.value

-- B.10.2c: push a deduped type error attributing it to the supplied loc: the
-- post-HM obligation check runs outside every construct, so the loc was
-- snapshotted into the obligation tuple at the record site.  `None` falls back
-- to the record's `mcLoc`, the enclosing construct's span (none after
-- inference).  issue 1146 PR2: the short-circuit bumps the occurrence counter (see `pushTypeErrorOnce`) — dedup suppresses the REPORT only.
export
pushTypeErrorOnceAt : ModuleCtx -> String -> Option Loc -> String -> Unit
pushTypeErrorOnceAt mctx code loc msg =
  if omHasKey msg mctx.mcCells.typeErrorMsgSetRef.value then
    noteTypeErrorDetected mctx ()
  else
    recordTypeError
      mctx
      (TcDiag code 1 (orElseLoc loc mctx.mcLoc) msg None None)

-- Like `pushTypeErrorOnceAt`, but the duplicate test is per SITE: the same text at
-- another span is a second diagnostic, the same text at the same span (a signature
-- elaborated twice) still folds.  For messages that describe one site's own fault,
-- where two sites with identical text must each be reported.  An ambiguous goal
-- folds on its span instead (`pushAmbiguityAt`).
export
pushTypeErrorOncePerSite : ModuleCtx -> String -> Option Loc -> String -> Unit
pushTypeErrorOncePerSite mctx code loc msg =
  let at = orElseLoc loc mctx.mcLoc
  if alreadyReportedAt mctx msg at then
    noteTypeErrorDetected mctx ()
  else
    recordTypeError mctx (TcDiag code 1 at msg None None)

-- A `T-AMBIGUOUS-INSTANCE` is one diagnostic per span, however many checks judge
-- the goal there: the boundary, the module's obligation check and the selector each
-- reach the same verdict on it.  Its text does not identify it, since the short
-- message names only the interface, so two goals at two spans are two diagnostics.
-- Of two messages at one span the one that names the goal and its candidates
-- ([namesGoal]) is kept.  An unlocated one folds on its text.
export
pushAmbiguityAt : ModuleCtx -> Bool -> Option Loc -> String -> Unit
pushAmbiguityAt mctx namesGoal loc msg =
  let at = orElseLoc loc mctx.mcLoc
  let code = "T-AMBIGUOUS-INSTANCE"
  if isNone at then
    pushTypeErrorOnceAt mctx code at msg
  else
    let site = locKey at
    match omLookup site mctx.mcCells.ambiguitySitesRef.value
      None =>
        mctx.mcCells.ambiguitySitesRef :=
          omInsert site namesGoal mctx.mcCells.ambiguitySitesRef.value
        recordTypeError mctx (TcDiag code 1 at msg None None)
      Some named =>
        if namesGoal && not named then
          mctx.mcCells.ambiguitySitesRef :=
            omInsert site True mctx.mcCells.ambiguitySitesRef.value
          replaceAmbiguityAt
            mctx
            site
            (writtenDiag (TcDiag code 1 at msg None None))
        else
          noteTypeErrorDetected mctx ()

-- Puts [d] in place of the `T-AMBIGUOUS-INSTANCE` recorded at [site], in the
-- module's channel and the sticky one.
replaceAmbiguityAt : ModuleCtx -> String -> TcDiag -> Unit
replaceAmbiguityAt mctx site d =
  let same e = tcCode e == tcCode d && locKey (tcLoc e) == site
  let swap e = if same e then d else e
  let _ = noteTypeErrorDetected mctx ()
  mctx.mcCells.typeErrorMsgSetRef :=
    omInsert
      (msgAtKey (tcMsg d) (tcLoc d))
      ()
      (omInsert (tcMsg d) () mctx.mcCells.typeErrorMsgSetRef.value)
  mctx.mcCells.typeErrors.items := map swap !mctx.mcCells.typeErrors.items
  mctx.mcGraph.typeErrorsStickyDiags :=
    map ((m, e) => (m, swap e)) mctx.mcGraph.typeErrorsStickyDiags.value

-- A boundary's `T-AMBIGUOUS-INSTANCE` on the goal [args]: one undetermined
-- variable is one diagnostic, however many goals at however many spans pose it, so
-- a goal sharing a boundary-owned variable with one already reported folds into
-- it.  Only the variables the boundary owns ([rigidIds] and scheme-quantified ones
-- excluded) identify the cause: two goals that share only a rigid variable are two
-- defects.  The selector and the obligation check cannot tell a rigid variable
-- from an open one, so they fold on the span alone (`pushAmbiguityAt`).
export
pushBoundaryAmbiguity : ModuleCtx ->
  OrdMap Unit ->
  List Mono ->
  Option Loc ->
  String ->
  Unit
pushBoundaryAmbiguity mctx rigidIds args loc msg =
  let reported = mctx.mcCells.ambiguityVarsRef
  let ids =
    filterList (boundaryOwnsOpen mctx rigidIds) (flatMap monoUnboundIds args)
  if anyList (i => IdMap.has i reported.value) ids then
    noteTypeErrorDetected mctx ()
  else
    reported := fold (m i => IdMap.set i () m) reported.value ids
    pushAmbiguityAt mctx False loc msg

-- Push a deduped type error (same dedup rule as pushTypeErrorOnceAt) that also
-- carries a human `help` string and an optional machine-applicable `fix`
-- (ERROR-QUALITY dim F).  #159: help/fix now ride INSIDE the TcDiag — no
-- message-keyed side channel.  `Fix`/`Diag` live in driver/diagnostics.mdk (which
-- imports this module), so the fix is carried as a plain (Loc, String)
-- span+replacement pair, converted to a real `Fix` on the diagnostics.mdk side.
-- issue 1146 PR2: the short-circuit bumps the occurrence counter (see
-- `pushTypeErrorOnce`) — dedup suppresses the REPORT only.
export
pushTypeErrorHelpFixAt : ModuleCtx ->
  String ->
  Option Loc ->
  String ->
  String ->
  Option (Loc, String) ->
  Unit
pushTypeErrorHelpFixAt mctx code loc msg help fix =
  if omHasKey msg mctx.mcCells.typeErrorMsgSetRef.value then
    noteTypeErrorDetected mctx ()
  else
    recordTypeError
      mctx
      (TcDiag code 1 (orElseLoc loc mctx.mcLoc) msg (Some help) fix)

-- Diagnostic text with every renamed local binder (`f$m$3$lb`) shown as written.
writtenNames : String -> String
writtenNames text = match splitOnChar '$' text
  [only] => only
  parts => dropRenameSuffixes parts

dropRenameSuffixes : List String -> String
dropRenameSuffixes [] = ""
dropRenameSuffixes [a] = a
dropRenameSuffixes (a :: _ :: n :: lb :: more)
  | allDigits n && startsWith "lb" lb =
    a ++ dropRenameSuffixes (stringSlice 2 (stringLength lb) lb :: more)
dropRenameSuffixes (a :: rest) = "\{a}$\{dropRenameSuffixes rest}"

allDigits : String -> Bool
allDigits n = stringLength n > 0 && allDigitsFrom n 0

allDigitsFrom : String -> Int -> Bool
allDigitsFrom n i
  | i >= stringLength n = True
  | otherwise =
    let c = stringSlice i (i + 1) n
    c >= "0" && c <= "9" && allDigitsFrom n (i + 1)

-- A diagnostic as the user reads it: binder names as written.
export
writtenDiag : TcDiag -> TcDiag
writtenDiag (TcDiag code sev loc msg help fix) =
  TcDiag code sev loc (writtenNames msg) (map writtenNames help) fix

export
backticked : String -> String
backticked s = "`\{s}`"

-- Chunk C: recover the ultimate callee name of an application spine (the
-- leftmost head), stripping transparent wrappers.  `None` when the head is not
-- a plain variable (so no name to blame in an over-application message).
export
appSpineName : Expr -> Option String
appSpineName (ELoc _ e) = appSpineName e
appSpineName (EDoOrigin _ e) = appSpineName e
appSpineName (EAnnot e _) = appSpineName e
appSpineName (EApp f _) = appSpineName f
appSpineName (EVar n) = Some n
appSpineName (EVarId n _) = Some n
appSpineName (EVarAt n _) = Some n
-- #2705: every driver marks now, so a callee can arrive as the marked occurrence
-- shape; it still has the name a message wants.
appSpineName (EMethodAt n _ _) = Some n
appSpineName (EDictAt n _) = Some n
appSpineName _ = None

-- surface-site lookup: does [m] (a type appearing in a no-impl / mismatch error)
-- equal a recorded tuple-call residual?  Compared by normalized rendering — the
-- residual IS the very type that flows into the error, so they render identically.
tupleCallHintFor : ModuleCtx -> Mono -> Option (String, Option (Loc, String))
tupleCallHintFor mctx m =
  findTupleCand (ppMono (normalize m)) mctx.mcCells.tupleCallCandidates.value

findTupleCand : String ->
  List (Mono, String, Option (Loc, String)) ->
  Option (String, Option (Loc, String))
findTupleCand _ [] = None
findTupleCand key ((res, help, fix) :: rest)
  | ppMono (normalize res) == key = Some (help, fix)
  | otherwise = findTupleCand key rest

-- first tuple-call hint matching any of the offending types in an error.
export
firstTupleCallHint : ModuleCtx ->
  List Mono ->
  Option (String, Option (Loc, String))
firstTupleCallHint mctx [] = None
firstTupleCallHint mctx (m :: rest) = match tupleCallHintFor mctx m
  Some hf => Some hf
  None => firstTupleCallHint mctx rest

-- [i] is neither held rigid nor quantified by a registered scheme.
export
boundaryOwnsOpen : ModuleCtx -> OrdMap Unit -> Int -> Bool
boundaryOwnsOpen mctx rigidIds i =
  not (omHasKey (intToString i) rigidIds)
    && not (IdMap.has i mctx.mcCells.deferrableVarIds.value)

-- The ordinal of the zero-based position [i].
export
ordinalWord : Int -> String
ordinalWord 0 = "first"
ordinalWord 1 = "second"
ordinalWord 2 = "third"
ordinalWord 3 = "fourth"
ordinalWord 4 = "fifth"
ordinalWord i = "\{intToString (i + 1)}th"

-- #1952: a MULTI-ARGUMENT goal names its arguments at ARGUMENT precedence, so
-- `Conv (Wrap a) Int` no longer prints as `Conv for Wrap a Int` — which reads as a
-- three-argument predicate and cannot be matched against the impl heads printed beside
-- it.  The length gate is the whole disambiguation and is not a hedge: with exactly
-- ONE argument the entire remainder of the message IS that argument, so there is nothing
-- to mis-group, and `ppMonosShared` is kept there so every existing single-argument
-- reject (`No impl of Eq for List Int`) renders byte-identically.  This message is prose,
-- not source — `renderConstraintCtx` is the surface that owes parens unconditionally.
noImplFoundMsg : String -> List Mono -> String
noImplFoundMsg iface [arg] = "no impl of \{iface} for \{ppMonosShared [arg]}"
noImplFoundMsg iface args = "no impl of \{iface} for \{ppPredArgsShared args}"

-- Actionable-fix hint (F dimension) for a `No impl of <iface> for <ty>` reject:
-- only when [args] is a single user-declared data type (a `dataParamKindsRef`
-- hit) does "add deriving" / "write an impl" read as concrete, applicable
-- advice — a builtin (String/Int/Bool/…) can't take `deriving`, and a function
-- type is structurally un-implementable, so both stay hint-free (unchanged
-- message) rather than print misleading advice.  A stdlib-owned type is
-- hint-free too for the derivable interfaces (`headIsStdlibOwned`).
-- #1111 A-2.3: the ONE `dataParamKindsRef` consumer that stays a BARE-NAME
-- question, and it is a membership test rather than a lookup.  A-2.2 has since
-- landed, so the identity IS reachable here (`headTyconMono` now answers a
-- `HeadKey`); this site deliberately calls the bare-name residual
-- `headTyconNameMono` instead, and is therefore one of the residual rows the
-- Stage A-2 ledger counts.
-- That costs nothing real: the question this asks is "is a type by this name
-- user-declared anywhere?", used ONLY to decide whether `add 'deriving X'` is
-- applicable advice rather than a dead end for a builtin.  `omHasKey` (over
-- `dataParamNameIndexRef`, which #2158 put in front of the old `tabHasName`
-- scan — same bare-name question, same answer) returns no value, so it cannot
-- select the wrong module's row; the worst a collision can do is offer
-- applicable advice for the right reason under the wrong module's declaration.
noImplHint : ModuleCtx -> String -> List Mono -> Option String
noImplHint mctx iface [arg] = match headTyconNameMono arg
  Some n =>
    if derivableIface iface && headIsStdlibOwned mctx.mcGraph arg then
      None
    else
      noImplHintFor mctx iface n
  None => None
noImplHint mctx _ _ = None

-- A type declared in a stdlib-owned module cannot take `deriving`, and an
-- `impl` of a core interface for it would be an orphan (docs/spec/language-design.md
-- "No Orphan Instances"), so neither remedy of `noImplAdvice` is available to the
-- caller.  A type with no module identity (builtin, unresolved) is not stdlib-owned.
headIsStdlibOwned : GraphCtx -> Mono -> Bool
headIsStdlibOwned gctx arg = match headTyconMono arg
  Some (HkDecl (TkIdent (Ident _ io _))) =>
    identOriginFold
      False
      (mid => omHasKey mid gctx.config.value.tcStdlibOwned)
      io
  _ => False

noImplHintFor : ModuleCtx -> String -> String -> Option String
noImplHintFor mctx iface n
  -- #2158: was `tabHasName n mctx.mcCells.dataParamKindsRef.value`, an O(n)
  -- linear scan re-run per no-impl diagnostic. `dataParamNameIndexRef` is the
  -- same bare-name membership question (built from `tabKeyName` over exactly
  -- the same keys, kept in lockstep at every dataParamKindsRef write site —
  -- see the field's comment on `ModuleCtx`), answered via `omHasKey` instead.
  | omHasKey n mctx.mcCells.dataParamNameIndexRef.value =
    Some (noImplAdvice iface n)
  | otherwise = None

-- Roadmap #18a: only a DERIVABLE interface may be suggested via `deriving`.  A
-- `deriving <iface>` for anything outside that set is silently DROPPED by desugar's
-- `deriveImpls` (its `deriveForData`/`deriveForNewtype` return None), so the old
-- unconditional "add 'deriving X'" sent the user down a dead end for every other
-- interface — including the `Semigroup` reject `a ++ b` now raises, and the
-- pre-existing user-interface case (`No impl of Printable for Foo`).  For those the
-- only real fix is to write the impl, so that is all we advise.
noImplAdvice : String -> String -> String
noImplAdvice iface n
  | derivableIface iface =
    "add `deriving \{iface}` to `\{n}` or write `impl \{iface} \{n}`"
  | otherwise = "write `impl \{iface} \{n}`"

-- The interfaces desugar.mdk can actually synthesize an impl for (deriveForData /
-- deriveForNewtype).  `Generic` is data-only; the other four cover both.
export
derivableIface : String -> Bool
derivableIface iface =
  contains iface ["Eq", "Ord", "Debug", "Display", "Generic"]

-- Append the hint (when applicable) to the plain `noImplFoundMsg`, mirroring
-- the did-you-mean append convention (base message ++ "; " ++ hint).
noImplFoundMsgHinted : ModuleCtx ->
  String ->
  List Mono ->
  (String, Option String)
noImplFoundMsgHinted mctx iface args =
  let base = noImplFoundMsg iface args
  match noImplHint mctx iface args
    Some hint => ("\{base}; \{hint}", Some hint)
    None => (base, None)

-- Push a `No impl of …` type error, appending + recording the actionable-fix
-- hint (via `pushTypeErrorHelpFixAt`) when one applies; otherwise behaves
-- exactly like the previous plain `pushTypeErrorOnceAt "T-NO-IMPL" …` call.
export
pushNoImplError : ModuleCtx -> String -> Option Loc -> List Mono -> Unit
pushNoImplError mctx iface loc args = match firstTupleCallHint mctx args
  -- P0-16: the un-implementable type IS a tuple-call residual (e.g. `println
  -- (add(1, 2))` → `No impl of Display for ((Int, Int) -> (Int, Int))`) — append
  -- the "call with spaces, not parentheses" hint + machine fix.
  Some (help, fix) =>
    pushTypeErrorHelpFixAt
      mctx
      "T-NO-IMPL"
      loc
      "\{noImplFoundMsg iface args}; \{help}"
      help
      fix
  None =>
    let (msg, mhint) = noImplFoundMsgHinted mctx iface args
    match mhint
      Some hint => pushTypeErrorHelpFixAt mctx "T-NO-IMPL" loc msg hint None
      None => pushTypeErrorOnceAt mctx "T-NO-IMPL" loc msg

export
quotedNames : List String -> String
quotedNames names = joinWith ", " (map (n => "`" ++ n ++ "`") names)

-- prepend an optional bare-message diagnostic (code, severity, help) to a TcDiag list.
export
prependDiagOpt : String ->
  Int ->
  Option String ->
  Option String ->
  List TcDiag ->
  List TcDiag
prependDiagOpt _ _ _ None ds = ds
prependDiagOpt code sev help (Some msg) ds =
  writtenDiag (TcDiag code sev None msg help None) :: ds
# DESUGAR
(DUse false (UseGroup ("types" "tc_mono") ((mem "headTyconMono" false) (mem "headTyconNameMono" false) (mem "monoUnboundIds" false))))
(DUse false (UseGroup ("types" "tc_state") ((mem "wPush" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "Expr" true) (mem "Ident" true) (mem "Loc" true) (mem "TabKey" true) (mem "identOriginFold" false) (mem "orElseLoc" false))))
(DUse false (UseGroup ("types" "repr") ((mem "Mono" true) (mem "normalize" false) (mem "ppMono" false) (mem "ppMonosShared" false) (mem "ppPredArgsShared" false))))
(DUse false (UseGroup ("types" "tc_types") ((mem "AbsorptionEvent" true) (mem "GraphCtx" true) (mem "ModuleCtx" true) (mem "Predicate" true) (mem "UObligation" true) (mem "Windowed" true))))
(DUse false (UseAlias ("map") "IdMap"))
(DUse true (UseGroup ("types" "publish") ((mem "TcDiag" true) (mem "tcCode" false) (mem "tcLoc" false) (mem "tcMsg" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "omHasKey" false) (mem "omInsert" false) (mem "omLookup" false) (mem "OrdMap" false))))
(DUse false (UseGroup ("support" "util") ((mem "anyList" false) (mem "contains" false) (mem "filterList" false) (mem "isSome" false) (mem "joinWith" false) (mem "splitOnChar" false) (mem "startsWith" false))))
(DUse false (UseGroup ("types" "registry") ((mem "HeadKey" true))))
(DUse false (UseGroup ("types" "disposition") ((mem "MethodDisposition" true))))
(DTypeSig true "locGoalKey" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "String")))
(DFunDef false "locGoalKey" ((PCon "None")) (ELit (LString "")))
(DFunDef false "locGoalKey" ((PCon "Some" (PCon "Loc" (PVar "file") (PVar "sl") (PVar "sc") (PVar "el") (PVar "ec")))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "file"))) (ELit (LString ":"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "sl")))) (ELit (LString ":"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "sc")))) (ELit (LString ":"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "el")))) (ELit (LString ":"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "ec")))) (ELit (LString ""))))
(DTypeSig true "typeErrorsArmed" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Unit") (TyCon "Bool"))))
(DFunDef false "typeErrorsArmed" ((PVar "gctx") PWild) (EFieldAccess (EFieldAccess (EVar "gctx") "typeErrorsSticky") "value"))
(DTypeSig true "recordTypeError" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "TcDiag") (TyCon "Unit"))))
(DFunDef false "recordTypeError" ((PVar "mctx") (PVar "raw")) (EBlock (DoLet false false (PVar "d") (EApp (EVar "writtenDiag") (EVar "raw"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "typeErrorsSticky")) (EVar "True"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "typeErrorsStickyDiags")) (EBinOp "::" (ETuple (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentModuleRef") "value") (EVar "d")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "typeErrorsStickyDiags") "value")))) (DoLet false false PWild (EApp (EApp (EVar "noteTypeErrorDetected") (EVar "mctx")) (ELit LUnit))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "typeErrorMsgSetRef")) (EApp (EApp (EApp (EVar "omInsert") (EApp (EApp (EVar "msgAtKey") (EApp (EVar "tcMsg") (EVar "d"))) (EApp (EVar "tcLoc") (EVar "d")))) (ELit LUnit)) (EApp (EApp (EApp (EVar "omInsert") (EApp (EVar "tcMsg") (EVar "d"))) (ELit LUnit)) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "typeErrorMsgSetRef") "value"))))) (DoExpr (EApp (EApp (EVar "wPush") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "typeErrors")) (EVar "d")))))
(DTypeSig false "noteTypeErrorDetected" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Unit") (TyCon "Unit"))))
(DFunDef false "noteTypeErrorDetected" ((PVar "mctx") PWild) (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "errorsDetected")) (EBinOp "+" (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "errorsDetected") "value") (ELit (LInt 1)))))
(DTypeSig true "erredDuring" (TyFun (TyCon "ModuleCtx") (TyFun (TyFun (TyCon "Unit") (TyVar "a")) (TyTuple (TyCon "Bool") (TyVar "a")))))
(DFunDef false "erredDuring" ((PVar "mctx") (PVar "act")) (EBlock (DoLet false false (PVar "before") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "errorsDetected") "value")) (DoLet false false (PVar "result") (EApp (EVar "act") (ELit LUnit))) (DoExpr (ETuple (EBinOp "/=" (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "errorsDetected") "value") (EVar "before")) (EVar "result")))))
(DTypeSig true "pushTypeError" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Unit")))))
(DFunDef false "pushTypeError" ((PVar "mctx") (PVar "code") (PVar "msg")) (EApp (EApp (EVar "recordTypeError") (EVar "mctx")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "TcDiag") (EVar "code")) (ELit (LInt 1))) (EFieldAccess (EVar "mctx") "mcLoc")) (EVar "msg")) (EVar "None")) (EVar "None"))))
(DTypeSig true "pushTypeErrorAt" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "String") (TyCon "Unit"))))))
(DFunDef false "pushTypeErrorAt" ((PVar "mctx") (PVar "code") (PVar "loc") (PVar "msg")) (EBlock (DoLet false false (PVar "at") (EApp (EApp (EVar "orElseLoc") (EVar "loc")) (EFieldAccess (EVar "mctx") "mcLoc"))) (DoLet false false (PVar "key") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "code"))) (ELit (LString "\t"))) (EApp (EVar "display") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentFn") "value"))) (ELit (LString "\t"))) (EApp (EVar "display") (EApp (EVar "locKey") (EVar "at")))) (ELit (LString "\t"))) (EApp (EVar "display") (EVar "msg"))) (ELit (LString "")))) (DoExpr (EIf (EBinOp "&&" (EApp (EVar "isSome") (EVar "at")) (EApp (EApp (EVar "omHasKey") (EVar "key")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "typeErrorKeySetRef") "value"))) (EApp (EApp (EVar "noteTypeErrorDetected") (EVar "mctx")) (ELit LUnit)) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "typeErrorKeySetRef")) (EApp (EApp (EApp (EVar "omInsert") (EVar "key")) (ELit LUnit)) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "typeErrorKeySetRef") "value")))) (DoExpr (EApp (EApp (EVar "recordTypeError") (EVar "mctx")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "TcDiag") (EVar "code")) (ELit (LInt 1))) (EVar "at")) (EVar "msg")) (EVar "None")) (EVar "None")))))))))
(DTypeSig true "locKey" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "String")))
(DFunDef false "locKey" ((PCon "None")) (ELit (LString "")))
(DFunDef false "locKey" ((PCon "Some" (PCon "Loc" (PVar "file") (PVar "line") (PVar "col") PWild PWild))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "file"))) (ELit (LString ":"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "line")))) (ELit (LString ":"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "col")))) (ELit (LString ""))))
(DTypeSig true "pushTypeErrorOnce" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Unit")))))
(DFunDef false "pushTypeErrorOnce" ((PVar "mctx") (PVar "code") (PVar "msg")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "msg")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "typeErrorMsgSetRef") "value")) (EApp (EApp (EVar "noteTypeErrorDetected") (EVar "mctx")) (ELit LUnit)) (EApp (EApp (EApp (EVar "pushTypeError") (EVar "mctx")) (EVar "code")) (EVar "msg"))))
(DTypeSig false "msgAtKey" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "String"))))
(DFunDef false "msgAtKey" ((PVar "msg") (PVar "at")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "msg"))) (ELit (LString "\t@@\t"))) (EApp (EVar "display") (EApp (EVar "locKey") (EVar "at")))) (ELit (LString ""))))
(DTypeSig false "alreadyReportedAt" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Bool")))))
(DFunDef false "alreadyReportedAt" ((PVar "mctx") (PVar "msg") (PCon "None")) (EApp (EApp (EVar "omHasKey") (EVar "msg")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "typeErrorMsgSetRef") "value")))
(DFunDef false "alreadyReportedAt" ((PVar "mctx") (PVar "msg") (PVar "at")) (EApp (EApp (EVar "omHasKey") (EApp (EApp (EVar "msgAtKey") (EVar "msg")) (EVar "at"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "typeErrorMsgSetRef") "value")))
(DTypeSig true "pushTypeErrorOnceAt" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "String") (TyCon "Unit"))))))
(DFunDef false "pushTypeErrorOnceAt" ((PVar "mctx") (PVar "code") (PVar "loc") (PVar "msg")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "msg")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "typeErrorMsgSetRef") "value")) (EApp (EApp (EVar "noteTypeErrorDetected") (EVar "mctx")) (ELit LUnit)) (EApp (EApp (EVar "recordTypeError") (EVar "mctx")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "TcDiag") (EVar "code")) (ELit (LInt 1))) (EApp (EApp (EVar "orElseLoc") (EVar "loc")) (EFieldAccess (EVar "mctx") "mcLoc"))) (EVar "msg")) (EVar "None")) (EVar "None")))))
(DTypeSig true "pushTypeErrorOncePerSite" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "String") (TyCon "Unit"))))))
(DFunDef false "pushTypeErrorOncePerSite" ((PVar "mctx") (PVar "code") (PVar "loc") (PVar "msg")) (EBlock (DoLet false false (PVar "at") (EApp (EApp (EVar "orElseLoc") (EVar "loc")) (EFieldAccess (EVar "mctx") "mcLoc"))) (DoExpr (EIf (EApp (EApp (EApp (EVar "alreadyReportedAt") (EVar "mctx")) (EVar "msg")) (EVar "at")) (EApp (EApp (EVar "noteTypeErrorDetected") (EVar "mctx")) (ELit LUnit)) (EApp (EApp (EVar "recordTypeError") (EVar "mctx")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "TcDiag") (EVar "code")) (ELit (LInt 1))) (EVar "at")) (EVar "msg")) (EVar "None")) (EVar "None")))))))
(DTypeSig true "pushAmbiguityAt" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "String") (TyCon "Unit"))))))
(DFunDef false "pushAmbiguityAt" ((PVar "mctx") (PVar "namesGoal") (PVar "loc") (PVar "msg")) (EBlock (DoLet false false (PVar "at") (EApp (EApp (EVar "orElseLoc") (EVar "loc")) (EFieldAccess (EVar "mctx") "mcLoc"))) (DoLet false false (PVar "code") (ELit (LString "T-AMBIGUOUS-INSTANCE"))) (DoExpr (EIf (EApp (EVar "isNone") (EVar "at")) (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOnceAt") (EVar "mctx")) (EVar "code")) (EVar "at")) (EVar "msg")) (EBlock (DoLet false false (PVar "site") (EApp (EVar "locKey") (EVar "at"))) (DoExpr (EMatch (EApp (EApp (EVar "omLookup") (EVar "site")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "ambiguitySitesRef") "value")) (arm (PCon "None") () (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "ambiguitySitesRef")) (EApp (EApp (EApp (EVar "omInsert") (EVar "site")) (EVar "namesGoal")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "ambiguitySitesRef") "value")))) (DoExpr (EApp (EApp (EVar "recordTypeError") (EVar "mctx")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "TcDiag") (EVar "code")) (ELit (LInt 1))) (EVar "at")) (EVar "msg")) (EVar "None")) (EVar "None")))))) (arm (PCon "Some" (PVar "named")) () (EIf (EBinOp "&&" (EVar "namesGoal") (EApp (EVar "not") (EVar "named"))) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "ambiguitySitesRef")) (EApp (EApp (EApp (EVar "omInsert") (EVar "site")) (EVar "True")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "ambiguitySitesRef") "value")))) (DoExpr (EApp (EApp (EApp (EVar "replaceAmbiguityAt") (EVar "mctx")) (EVar "site")) (EApp (EVar "writtenDiag") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "TcDiag") (EVar "code")) (ELit (LInt 1))) (EVar "at")) (EVar "msg")) (EVar "None")) (EVar "None")))))) (EApp (EApp (EVar "noteTypeErrorDetected") (EVar "mctx")) (ELit LUnit)))))))))))
(DTypeSig false "replaceAmbiguityAt" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "TcDiag") (TyCon "Unit")))))
(DFunDef false "replaceAmbiguityAt" ((PVar "mctx") (PVar "site") (PVar "d")) (EBlock (DoLet false true (PVar "same") (ELam ((PVar "e")) (EBinOp "&&" (EBinOp "==" (EApp (EVar "tcCode") (EVar "e")) (EApp (EVar "tcCode") (EVar "d"))) (EBinOp "==" (EApp (EVar "locKey") (EApp (EVar "tcLoc") (EVar "e"))) (EVar "site"))))) (DoLet false true (PVar "swap") (ELam ((PVar "e")) (EIf (EApp (EVar "same") (EVar "e")) (EVar "d") (EVar "e")))) (DoLet false false PWild (EApp (EApp (EVar "noteTypeErrorDetected") (EVar "mctx")) (ELit LUnit))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "typeErrorMsgSetRef")) (EApp (EApp (EApp (EVar "omInsert") (EApp (EApp (EVar "msgAtKey") (EApp (EVar "tcMsg") (EVar "d"))) (EApp (EVar "tcLoc") (EVar "d")))) (ELit LUnit)) (EApp (EApp (EApp (EVar "omInsert") (EApp (EVar "tcMsg") (EVar "d"))) (ELit LUnit)) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "typeErrorMsgSetRef") "value"))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "typeErrors") "items")) (EApp (EApp (EVar "map") (EVar "swap")) (EUnOp "!" (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "typeErrors") "items"))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "typeErrorsStickyDiags")) (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "m") (PVar "e"))) (ETuple (EVar "m") (EApp (EVar "swap") (EVar "e"))))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "typeErrorsStickyDiags") "value"))))))
(DTypeSig true "pushBoundaryAmbiguity" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "String") (TyCon "Unit")))))))
(DFunDef false "pushBoundaryAmbiguity" ((PVar "mctx") (PVar "rigidIds") (PVar "args") (PVar "loc") (PVar "msg")) (EBlock (DoLet false false (PVar "reported") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "ambiguityVarsRef")) (DoLet false false (PVar "ids") (EApp (EApp (EVar "filterList") (EApp (EApp (EVar "boundaryOwnsOpen") (EVar "mctx")) (EVar "rigidIds"))) (EApp (EApp (EVar "flatMap") (EVar "monoUnboundIds")) (EVar "args")))) (DoExpr (EIf (EApp (EApp (EVar "anyList") (ELam ((PVar "i")) (EApp (EApp (EVar "IdMap.has") (EVar "i")) (EFieldAccess (EVar "reported") "value")))) (EVar "ids")) (EApp (EApp (EVar "noteTypeErrorDetected") (EVar "mctx")) (ELit LUnit)) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EVar "reported")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "m") (PVar "i")) (EApp (EApp (EApp (EVar "IdMap.set") (EVar "i")) (ELit LUnit)) (EVar "m")))) (EFieldAccess (EVar "reported") "value")) (EVar "ids")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "pushAmbiguityAt") (EVar "mctx")) (EVar "False")) (EVar "loc")) (EVar "msg"))))))))
(DTypeSig true "pushTypeErrorHelpFixAt" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "Loc") (TyCon "String"))) (TyCon "Unit"))))))))
(DFunDef false "pushTypeErrorHelpFixAt" ((PVar "mctx") (PVar "code") (PVar "loc") (PVar "msg") (PVar "help") (PVar "fix")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "msg")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "typeErrorMsgSetRef") "value")) (EApp (EApp (EVar "noteTypeErrorDetected") (EVar "mctx")) (ELit LUnit)) (EApp (EApp (EVar "recordTypeError") (EVar "mctx")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "TcDiag") (EVar "code")) (ELit (LInt 1))) (EApp (EApp (EVar "orElseLoc") (EVar "loc")) (EFieldAccess (EVar "mctx") "mcLoc"))) (EVar "msg")) (EApp (EVar "Some") (EVar "help"))) (EVar "fix")))))
(DTypeSig false "writtenNames" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "writtenNames" ((PVar "text")) (EMatch (EApp (EApp (EVar "splitOnChar") (ELit (LChar "$"))) (EVar "text")) (arm (PList (PVar "only")) () (EVar "only")) (arm (PVar "parts") () (EApp (EVar "dropRenameSuffixes") (EVar "parts")))))
(DTypeSig false "dropRenameSuffixes" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "dropRenameSuffixes" ((PList)) (ELit (LString "")))
(DFunDef false "dropRenameSuffixes" ((PList (PVar "a"))) (EVar "a"))
(DFunDef false "dropRenameSuffixes" ((PCons (PVar "a") (PCons PWild (PCons (PVar "n") (PCons (PVar "lb") (PVar "more")))))) (EIf (EBinOp "&&" (EApp (EVar "allDigits") (EVar "n")) (EApp (EApp (EVar "startsWith") (ELit (LString "lb"))) (EVar "lb"))) (EBinOp "++" (EVar "a") (EApp (EVar "dropRenameSuffixes") (EBinOp "::" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 2))) (EApp (EVar "stringLength") (EVar "lb"))) (EVar "lb")) (EVar "more")))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "dropRenameSuffixes" ((PCons (PVar "a") (PVar "rest"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "a"))) (ELit (LString "$"))) (EApp (EVar "display") (EApp (EVar "dropRenameSuffixes") (EVar "rest")))) (ELit (LString ""))))
(DTypeSig false "allDigits" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "allDigits" ((PVar "n")) (EBinOp "&&" (EBinOp ">" (EApp (EVar "stringLength") (EVar "n")) (ELit (LInt 0))) (EApp (EApp (EVar "allDigitsFrom") (EVar "n")) (ELit (LInt 0)))))
(DTypeSig false "allDigitsFrom" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "allDigitsFrom" ((PVar "n") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "stringLength") (EVar "n"))) (EVar "True") (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "c") (EApp (EApp (EApp (EVar "stringSlice") (EVar "i")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n"))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LString "0"))) (EBinOp "<=" (EVar "c") (ELit (LString "9")))) (EApp (EApp (EVar "allDigitsFrom") (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "writtenDiag" (TyFun (TyCon "TcDiag") (TyCon "TcDiag")))
(DFunDef false "writtenDiag" ((PCon "TcDiag" (PVar "code") (PVar "sev") (PVar "loc") (PVar "msg") (PVar "help") (PVar "fix"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "TcDiag") (EVar "code")) (EVar "sev")) (EVar "loc")) (EApp (EVar "writtenNames") (EVar "msg"))) (EApp (EApp (EVar "map") (EVar "writtenNames")) (EVar "help"))) (EVar "fix")))
(DTypeSig true "backticked" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "backticked" ((PVar "s")) (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "display") (EVar "s"))) (ELit (LString "`"))))
(DTypeSig true "appSpineName" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "appSpineName" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "appSpineName") (EVar "e")))
(DFunDef false "appSpineName" ((PCon "EDoOrigin" PWild (PVar "e"))) (EApp (EVar "appSpineName") (EVar "e")))
(DFunDef false "appSpineName" ((PCon "EAnnot" (PVar "e") PWild)) (EApp (EVar "appSpineName") (EVar "e")))
(DFunDef false "appSpineName" ((PCon "EApp" (PVar "f") PWild)) (EApp (EVar "appSpineName") (EVar "f")))
(DFunDef false "appSpineName" ((PCon "EVar" (PVar "n"))) (EApp (EVar "Some") (EVar "n")))
(DFunDef false "appSpineName" ((PCon "EVarId" (PVar "n") PWild)) (EApp (EVar "Some") (EVar "n")))
(DFunDef false "appSpineName" ((PCon "EVarAt" (PVar "n") PWild)) (EApp (EVar "Some") (EVar "n")))
(DFunDef false "appSpineName" ((PCon "EMethodAt" (PVar "n") PWild PWild)) (EApp (EVar "Some") (EVar "n")))
(DFunDef false "appSpineName" ((PCon "EDictAt" (PVar "n") PWild)) (EApp (EVar "Some") (EVar "n")))
(DFunDef false "appSpineName" (PWild) (EVar "None"))
(DTypeSig false "tupleCallHintFor" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Mono") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyTuple (TyCon "Loc") (TyCon "String"))))))))
(DFunDef false "tupleCallHintFor" ((PVar "mctx") (PVar "m")) (EApp (EApp (EVar "findTupleCand") (EApp (EVar "ppMono") (EApp (EVar "normalize") (EVar "m")))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "tupleCallCandidates") "value")))
(DTypeSig false "findTupleCand" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Mono") (TyCon "String") (TyApp (TyCon "Option") (TyTuple (TyCon "Loc") (TyCon "String"))))) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyTuple (TyCon "Loc") (TyCon "String"))))))))
(DFunDef false "findTupleCand" (PWild (PList)) (EVar "None"))
(DFunDef false "findTupleCand" ((PVar "key") (PCons (PTuple (PVar "res") (PVar "help") (PVar "fix")) (PVar "rest"))) (EIf (EBinOp "==" (EApp (EVar "ppMono") (EApp (EVar "normalize") (EVar "res"))) (EVar "key")) (EApp (EVar "Some") (ETuple (EVar "help") (EVar "fix"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "findTupleCand") (EVar "key")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "firstTupleCallHint" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyTuple (TyCon "Loc") (TyCon "String"))))))))
(DFunDef false "firstTupleCallHint" ((PVar "mctx") (PList)) (EVar "None"))
(DFunDef false "firstTupleCallHint" ((PVar "mctx") (PCons (PVar "m") (PVar "rest"))) (EMatch (EApp (EApp (EVar "tupleCallHintFor") (EVar "mctx")) (EVar "m")) (arm (PCon "Some" (PVar "hf")) () (EApp (EVar "Some") (EVar "hf"))) (arm (PCon "None") () (EApp (EApp (EVar "firstTupleCallHint") (EVar "mctx")) (EVar "rest")))))
(DTypeSig true "boundaryOwnsOpen" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "boundaryOwnsOpen" ((PVar "mctx") (PVar "rigidIds") (PVar "i")) (EBinOp "&&" (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EApp (EVar "intToString") (EVar "i"))) (EVar "rigidIds"))) (EApp (EVar "not") (EApp (EApp (EVar "IdMap.has") (EVar "i")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "deferrableVarIds") "value")))))
(DTypeSig true "ordinalWord" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "ordinalWord" ((PLit (LInt 0))) (ELit (LString "first")))
(DFunDef false "ordinalWord" ((PLit (LInt 1))) (ELit (LString "second")))
(DFunDef false "ordinalWord" ((PLit (LInt 2))) (ELit (LString "third")))
(DFunDef false "ordinalWord" ((PLit (LInt 3))) (ELit (LString "fourth")))
(DFunDef false "ordinalWord" ((PLit (LInt 4))) (ELit (LString "fifth")))
(DFunDef false "ordinalWord" ((PVar "i")) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "intToString") (EBinOp "+" (EVar "i") (ELit (LInt 1)))))) (ELit (LString "th"))))
(DTypeSig false "noImplFoundMsg" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "String"))))
(DFunDef false "noImplFoundMsg" ((PVar "iface") (PList (PVar "arg"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "no impl of ")) (EApp (EVar "display") (EVar "iface"))) (ELit (LString " for "))) (EApp (EVar "display") (EApp (EVar "ppMonosShared") (EListLit (EVar "arg"))))) (ELit (LString ""))))
(DFunDef false "noImplFoundMsg" ((PVar "iface") (PVar "args")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "no impl of ")) (EApp (EVar "display") (EVar "iface"))) (ELit (LString " for "))) (EApp (EVar "display") (EApp (EVar "ppPredArgsShared") (EVar "args")))) (ELit (LString ""))))
(DTypeSig false "noImplHint" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "noImplHint" ((PVar "mctx") (PVar "iface") (PList (PVar "arg"))) (EMatch (EApp (EVar "headTyconNameMono") (EVar "arg")) (arm (PCon "Some" (PVar "n")) () (EIf (EBinOp "&&" (EApp (EVar "derivableIface") (EVar "iface")) (EApp (EApp (EVar "headIsStdlibOwned") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "arg"))) (EVar "None") (EApp (EApp (EApp (EVar "noImplHintFor") (EVar "mctx")) (EVar "iface")) (EVar "n")))) (arm (PCon "None") () (EVar "None"))))
(DFunDef false "noImplHint" ((PVar "mctx") PWild PWild) (EVar "None"))
(DTypeSig false "headIsStdlibOwned" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Mono") (TyCon "Bool"))))
(DFunDef false "headIsStdlibOwned" ((PVar "gctx") (PVar "arg")) (EMatch (EApp (EVar "headTyconMono") (EVar "arg")) (arm (PCon "Some" (PCon "HkDecl" (PCon "TkIdent" (PCon "Ident" PWild (PVar "io") PWild)))) () (EApp (EApp (EApp (EVar "identOriginFold") (EVar "False")) (ELam ((PVar "mid")) (EApp (EApp (EVar "omHasKey") (EVar "mid")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "config") "value") "tcStdlibOwned")))) (EVar "io"))) (arm PWild () (EVar "False"))))
(DTypeSig false "noImplHintFor" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "noImplHintFor" ((PVar "mctx") (PVar "iface") (PVar "n")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "n")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "dataParamNameIndexRef") "value")) (EApp (EVar "Some") (EApp (EApp (EVar "noImplAdvice") (EVar "iface")) (EVar "n"))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "noImplAdvice" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "noImplAdvice" ((PVar "iface") (PVar "n")) (EIf (EApp (EVar "derivableIface") (EVar "iface")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "add `deriving ")) (EApp (EVar "display") (EVar "iface"))) (ELit (LString "` to `"))) (EApp (EVar "display") (EVar "n"))) (ELit (LString "` or write `impl "))) (EApp (EVar "display") (EVar "iface"))) (ELit (LString " "))) (EApp (EVar "display") (EVar "n"))) (ELit (LString "`"))) (EIf (EVar "otherwise") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "write `impl ")) (EApp (EVar "display") (EVar "iface"))) (ELit (LString " "))) (EApp (EVar "display") (EVar "n"))) (ELit (LString "`"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "derivableIface" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "derivableIface" ((PVar "iface")) (EApp (EApp (EVar "contains") (EVar "iface")) (EListLit (ELit (LString "Eq")) (ELit (LString "Ord")) (ELit (LString "Debug")) (ELit (LString "Display")) (ELit (LString "Generic")))))
(DTypeSig false "noImplFoundMsgHinted" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))))))
(DFunDef false "noImplFoundMsgHinted" ((PVar "mctx") (PVar "iface") (PVar "args")) (EBlock (DoLet false false (PVar "base") (EApp (EApp (EVar "noImplFoundMsg") (EVar "iface")) (EVar "args"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "noImplHint") (EVar "mctx")) (EVar "iface")) (EVar "args")) (arm (PCon "Some" (PVar "hint")) () (ETuple (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "base"))) (ELit (LString "; "))) (EApp (EVar "display") (EVar "hint"))) (ELit (LString ""))) (EApp (EVar "Some") (EVar "hint")))) (arm (PCon "None") () (ETuple (EVar "base") (EVar "None")))))))
(DTypeSig true "pushNoImplError" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Unit"))))))
(DFunDef false "pushNoImplError" ((PVar "mctx") (PVar "iface") (PVar "loc") (PVar "args")) (EMatch (EApp (EApp (EVar "firstTupleCallHint") (EVar "mctx")) (EVar "args")) (arm (PCon "Some" (PTuple (PVar "help") (PVar "fix"))) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "pushTypeErrorHelpFixAt") (EVar "mctx")) (ELit (LString "T-NO-IMPL"))) (EVar "loc")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EApp (EVar "noImplFoundMsg") (EVar "iface")) (EVar "args")))) (ELit (LString "; "))) (EApp (EVar "display") (EVar "help"))) (ELit (LString "")))) (EVar "help")) (EVar "fix"))) (arm (PCon "None") () (EBlock (DoLet false false (PTuple (PVar "msg") (PVar "mhint")) (EApp (EApp (EApp (EVar "noImplFoundMsgHinted") (EVar "mctx")) (EVar "iface")) (EVar "args"))) (DoExpr (EMatch (EVar "mhint") (arm (PCon "Some" (PVar "hint")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "pushTypeErrorHelpFixAt") (EVar "mctx")) (ELit (LString "T-NO-IMPL"))) (EVar "loc")) (EVar "msg")) (EVar "hint")) (EVar "None"))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOnceAt") (EVar "mctx")) (ELit (LString "T-NO-IMPL"))) (EVar "loc")) (EVar "msg")))))))))
(DTypeSig true "quotedNames" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "quotedNames" ((PVar "names")) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "map") (ELam ((PVar "n")) (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EVar "n")) (ELit (LString "`"))))) (EVar "names"))))
(DTypeSig true "prependDiagOpt" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "TcDiag")) (TyApp (TyCon "List") (TyCon "TcDiag"))))))))
(DFunDef false "prependDiagOpt" (PWild PWild PWild (PCon "None") (PVar "ds")) (EVar "ds"))
(DFunDef false "prependDiagOpt" ((PVar "code") (PVar "sev") (PVar "help") (PCon "Some" (PVar "msg")) (PVar "ds")) (EBinOp "::" (EApp (EVar "writtenDiag") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "TcDiag") (EVar "code")) (EVar "sev")) (EVar "None")) (EVar "msg")) (EVar "help")) (EVar "None"))) (EVar "ds")))
# MARK
(DUse false (UseGroup ("types" "tc_mono") ((mem "headTyconMono" false) (mem "headTyconNameMono" false) (mem "monoUnboundIds" false))))
(DUse false (UseGroup ("types" "tc_state") ((mem "wPush" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "Expr" true) (mem "Ident" true) (mem "Loc" true) (mem "TabKey" true) (mem "identOriginFold" false) (mem "orElseLoc" false))))
(DUse false (UseGroup ("types" "repr") ((mem "Mono" true) (mem "normalize" false) (mem "ppMono" false) (mem "ppMonosShared" false) (mem "ppPredArgsShared" false))))
(DUse false (UseGroup ("types" "tc_types") ((mem "AbsorptionEvent" true) (mem "GraphCtx" true) (mem "ModuleCtx" true) (mem "Predicate" true) (mem "UObligation" true) (mem "Windowed" true))))
(DUse false (UseAlias ("map") "IdMap"))
(DUse true (UseGroup ("types" "publish") ((mem "TcDiag" true) (mem "tcCode" false) (mem "tcLoc" false) (mem "tcMsg" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "omHasKey" false) (mem "omInsert" false) (mem "omLookup" false) (mem "OrdMap" false))))
(DUse false (UseGroup ("support" "util") ((mem "anyList" false) (mem "contains" false) (mem "filterList" false) (mem "isSome" false) (mem "joinWith" false) (mem "splitOnChar" false) (mem "startsWith" false))))
(DUse false (UseGroup ("types" "registry") ((mem "HeadKey" true))))
(DUse false (UseGroup ("types" "disposition") ((mem "MethodDisposition" true))))
(DTypeSig true "locGoalKey" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "String")))
(DFunDef false "locGoalKey" ((PCon "None")) (ELit (LString "")))
(DFunDef false "locGoalKey" ((PCon "Some" (PCon "Loc" (PVar "file") (PVar "sl") (PVar "sc") (PVar "el") (PVar "ec")))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "file"))) (ELit (LString ":"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "sl")))) (ELit (LString ":"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "sc")))) (ELit (LString ":"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "el")))) (ELit (LString ":"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "ec")))) (ELit (LString ""))))
(DTypeSig true "typeErrorsArmed" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Unit") (TyCon "Bool"))))
(DFunDef false "typeErrorsArmed" ((PVar "gctx") PWild) (EFieldAccess (EFieldAccess (EVar "gctx") "typeErrorsSticky") "value"))
(DTypeSig true "recordTypeError" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "TcDiag") (TyCon "Unit"))))
(DFunDef false "recordTypeError" ((PVar "mctx") (PVar "raw")) (EBlock (DoLet false false (PVar "d") (EApp (EVar "writtenDiag") (EVar "raw"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "typeErrorsSticky")) (EVar "True"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "typeErrorsStickyDiags")) (EBinOp "::" (ETuple (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentModuleRef") "value") (EVar "d")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "typeErrorsStickyDiags") "value")))) (DoLet false false PWild (EApp (EApp (EVar "noteTypeErrorDetected") (EVar "mctx")) (ELit LUnit))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "typeErrorMsgSetRef")) (EApp (EApp (EApp (EVar "omInsert") (EApp (EApp (EVar "msgAtKey") (EApp (EVar "tcMsg") (EVar "d"))) (EApp (EVar "tcLoc") (EVar "d")))) (ELit LUnit)) (EApp (EApp (EApp (EVar "omInsert") (EApp (EVar "tcMsg") (EVar "d"))) (ELit LUnit)) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "typeErrorMsgSetRef") "value"))))) (DoExpr (EApp (EApp (EVar "wPush") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "typeErrors")) (EVar "d")))))
(DTypeSig false "noteTypeErrorDetected" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Unit") (TyCon "Unit"))))
(DFunDef false "noteTypeErrorDetected" ((PVar "mctx") PWild) (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "errorsDetected")) (EBinOp "+" (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "errorsDetected") "value") (ELit (LInt 1)))))
(DTypeSig true "erredDuring" (TyFun (TyCon "ModuleCtx") (TyFun (TyFun (TyCon "Unit") (TyVar "a")) (TyTuple (TyCon "Bool") (TyVar "a")))))
(DFunDef false "erredDuring" ((PVar "mctx") (PVar "act")) (EBlock (DoLet false false (PVar "before") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "errorsDetected") "value")) (DoLet false false (PVar "result") (EApp (EVar "act") (ELit LUnit))) (DoExpr (ETuple (EBinOp "/=" (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "errorsDetected") "value") (EVar "before")) (EVar "result")))))
(DTypeSig true "pushTypeError" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Unit")))))
(DFunDef false "pushTypeError" ((PVar "mctx") (PVar "code") (PVar "msg")) (EApp (EApp (EVar "recordTypeError") (EVar "mctx")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "TcDiag") (EVar "code")) (ELit (LInt 1))) (EFieldAccess (EVar "mctx") "mcLoc")) (EVar "msg")) (EVar "None")) (EVar "None"))))
(DTypeSig true "pushTypeErrorAt" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "String") (TyCon "Unit"))))))
(DFunDef false "pushTypeErrorAt" ((PVar "mctx") (PVar "code") (PVar "loc") (PVar "msg")) (EBlock (DoLet false false (PVar "at") (EApp (EApp (EVar "orElseLoc") (EVar "loc")) (EFieldAccess (EVar "mctx") "mcLoc"))) (DoLet false false (PVar "key") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "code"))) (ELit (LString "\t"))) (EApp (EMethodRef "display") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "currentFn") "value"))) (ELit (LString "\t"))) (EApp (EMethodRef "display") (EApp (EVar "locKey") (EVar "at")))) (ELit (LString "\t"))) (EApp (EMethodRef "display") (EVar "msg"))) (ELit (LString "")))) (DoExpr (EIf (EBinOp "&&" (EApp (EVar "isSome") (EVar "at")) (EApp (EApp (EVar "omHasKey") (EVar "key")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "typeErrorKeySetRef") "value"))) (EApp (EApp (EVar "noteTypeErrorDetected") (EVar "mctx")) (ELit LUnit)) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "typeErrorKeySetRef")) (EApp (EApp (EApp (EVar "omInsert") (EVar "key")) (ELit LUnit)) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "typeErrorKeySetRef") "value")))) (DoExpr (EApp (EApp (EVar "recordTypeError") (EVar "mctx")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "TcDiag") (EVar "code")) (ELit (LInt 1))) (EVar "at")) (EVar "msg")) (EVar "None")) (EVar "None")))))))))
(DTypeSig true "locKey" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "String")))
(DFunDef false "locKey" ((PCon "None")) (ELit (LString "")))
(DFunDef false "locKey" ((PCon "Some" (PCon "Loc" (PVar "file") (PVar "line") (PVar "col") PWild PWild))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "file"))) (ELit (LString ":"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "line")))) (ELit (LString ":"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "col")))) (ELit (LString ""))))
(DTypeSig true "pushTypeErrorOnce" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Unit")))))
(DFunDef false "pushTypeErrorOnce" ((PVar "mctx") (PVar "code") (PVar "msg")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "msg")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "typeErrorMsgSetRef") "value")) (EApp (EApp (EVar "noteTypeErrorDetected") (EVar "mctx")) (ELit LUnit)) (EApp (EApp (EApp (EVar "pushTypeError") (EVar "mctx")) (EVar "code")) (EVar "msg"))))
(DTypeSig false "msgAtKey" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "String"))))
(DFunDef false "msgAtKey" ((PVar "msg") (PVar "at")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "msg"))) (ELit (LString "\t@@\t"))) (EApp (EMethodRef "display") (EApp (EVar "locKey") (EVar "at")))) (ELit (LString ""))))
(DTypeSig false "alreadyReportedAt" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Bool")))))
(DFunDef false "alreadyReportedAt" ((PVar "mctx") (PVar "msg") (PCon "None")) (EApp (EApp (EVar "omHasKey") (EVar "msg")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "typeErrorMsgSetRef") "value")))
(DFunDef false "alreadyReportedAt" ((PVar "mctx") (PVar "msg") (PVar "at")) (EApp (EApp (EVar "omHasKey") (EApp (EApp (EVar "msgAtKey") (EVar "msg")) (EVar "at"))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "typeErrorMsgSetRef") "value")))
(DTypeSig true "pushTypeErrorOnceAt" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "String") (TyCon "Unit"))))))
(DFunDef false "pushTypeErrorOnceAt" ((PVar "mctx") (PVar "code") (PVar "loc") (PVar "msg")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "msg")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "typeErrorMsgSetRef") "value")) (EApp (EApp (EVar "noteTypeErrorDetected") (EVar "mctx")) (ELit LUnit)) (EApp (EApp (EVar "recordTypeError") (EVar "mctx")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "TcDiag") (EVar "code")) (ELit (LInt 1))) (EApp (EApp (EVar "orElseLoc") (EVar "loc")) (EFieldAccess (EVar "mctx") "mcLoc"))) (EVar "msg")) (EVar "None")) (EVar "None")))))
(DTypeSig true "pushTypeErrorOncePerSite" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "String") (TyCon "Unit"))))))
(DFunDef false "pushTypeErrorOncePerSite" ((PVar "mctx") (PVar "code") (PVar "loc") (PVar "msg")) (EBlock (DoLet false false (PVar "at") (EApp (EApp (EVar "orElseLoc") (EVar "loc")) (EFieldAccess (EVar "mctx") "mcLoc"))) (DoExpr (EIf (EApp (EApp (EApp (EVar "alreadyReportedAt") (EVar "mctx")) (EVar "msg")) (EVar "at")) (EApp (EApp (EVar "noteTypeErrorDetected") (EVar "mctx")) (ELit LUnit)) (EApp (EApp (EVar "recordTypeError") (EVar "mctx")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "TcDiag") (EVar "code")) (ELit (LInt 1))) (EVar "at")) (EVar "msg")) (EVar "None")) (EVar "None")))))))
(DTypeSig true "pushAmbiguityAt" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "String") (TyCon "Unit"))))))
(DFunDef false "pushAmbiguityAt" ((PVar "mctx") (PVar "namesGoal") (PVar "loc") (PVar "msg")) (EBlock (DoLet false false (PVar "at") (EApp (EApp (EVar "orElseLoc") (EVar "loc")) (EFieldAccess (EVar "mctx") "mcLoc"))) (DoLet false false (PVar "code") (ELit (LString "T-AMBIGUOUS-INSTANCE"))) (DoExpr (EIf (EApp (EVar "isNone") (EVar "at")) (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOnceAt") (EVar "mctx")) (EVar "code")) (EVar "at")) (EVar "msg")) (EBlock (DoLet false false (PVar "site") (EApp (EVar "locKey") (EVar "at"))) (DoExpr (EMatch (EApp (EApp (EVar "omLookup") (EVar "site")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "ambiguitySitesRef") "value")) (arm (PCon "None") () (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "ambiguitySitesRef")) (EApp (EApp (EApp (EVar "omInsert") (EVar "site")) (EVar "namesGoal")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "ambiguitySitesRef") "value")))) (DoExpr (EApp (EApp (EVar "recordTypeError") (EVar "mctx")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "TcDiag") (EVar "code")) (ELit (LInt 1))) (EVar "at")) (EVar "msg")) (EVar "None")) (EVar "None")))))) (arm (PCon "Some" (PVar "named")) () (EIf (EBinOp "&&" (EVar "namesGoal") (EApp (EVar "not") (EVar "named"))) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "ambiguitySitesRef")) (EApp (EApp (EApp (EVar "omInsert") (EVar "site")) (EVar "True")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "ambiguitySitesRef") "value")))) (DoExpr (EApp (EApp (EApp (EVar "replaceAmbiguityAt") (EVar "mctx")) (EVar "site")) (EApp (EVar "writtenDiag") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "TcDiag") (EVar "code")) (ELit (LInt 1))) (EVar "at")) (EVar "msg")) (EVar "None")) (EVar "None")))))) (EApp (EApp (EVar "noteTypeErrorDetected") (EVar "mctx")) (ELit LUnit)))))))))))
(DTypeSig false "replaceAmbiguityAt" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "TcDiag") (TyCon "Unit")))))
(DFunDef false "replaceAmbiguityAt" ((PVar "mctx") (PVar "site") (PVar "d")) (EBlock (DoLet false true (PVar "same") (ELam ((PVar "e")) (EBinOp "&&" (EBinOp "==" (EApp (EVar "tcCode") (EVar "e")) (EApp (EVar "tcCode") (EVar "d"))) (EBinOp "==" (EApp (EVar "locKey") (EApp (EVar "tcLoc") (EVar "e"))) (EVar "site"))))) (DoLet false true (PVar "swap") (ELam ((PVar "e")) (EIf (EApp (EVar "same") (EVar "e")) (EVar "d") (EVar "e")))) (DoLet false false PWild (EApp (EApp (EVar "noteTypeErrorDetected") (EVar "mctx")) (ELit LUnit))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "typeErrorMsgSetRef")) (EApp (EApp (EApp (EVar "omInsert") (EApp (EApp (EVar "msgAtKey") (EApp (EVar "tcMsg") (EVar "d"))) (EApp (EVar "tcLoc") (EVar "d")))) (ELit LUnit)) (EApp (EApp (EApp (EVar "omInsert") (EApp (EVar "tcMsg") (EVar "d"))) (ELit LUnit)) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "typeErrorMsgSetRef") "value"))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "typeErrors") "items")) (EApp (EApp (EMethodRef "map") (EVar "swap")) (EUnOp "!" (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "typeErrors") "items"))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "typeErrorsStickyDiags")) (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "m") (PVar "e"))) (ETuple (EVar "m") (EApp (EVar "swap") (EVar "e"))))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "typeErrorsStickyDiags") "value"))))))
(DTypeSig true "pushBoundaryAmbiguity" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "String") (TyCon "Unit")))))))
(DFunDef false "pushBoundaryAmbiguity" ((PVar "mctx") (PVar "rigidIds") (PVar "args") (PVar "loc") (PVar "msg")) (EBlock (DoLet false false (PVar "reported") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "ambiguityVarsRef")) (DoLet false false (PVar "ids") (EApp (EApp (EVar "filterList") (EApp (EApp (EVar "boundaryOwnsOpen") (EVar "mctx")) (EVar "rigidIds"))) (EApp (EApp (EDictApp "flatMap") (EVar "monoUnboundIds")) (EVar "args")))) (DoExpr (EIf (EApp (EApp (EVar "anyList") (ELam ((PVar "i")) (EApp (EApp (EVar "IdMap.has") (EVar "i")) (EFieldAccess (EVar "reported") "value")))) (EVar "ids")) (EApp (EApp (EVar "noteTypeErrorDetected") (EVar "mctx")) (ELit LUnit)) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EVar "reported")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "m") (PVar "i")) (EApp (EApp (EApp (EVar "IdMap.set") (EVar "i")) (ELit LUnit)) (EVar "m")))) (EFieldAccess (EVar "reported") "value")) (EVar "ids")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "pushAmbiguityAt") (EVar "mctx")) (EVar "False")) (EVar "loc")) (EVar "msg"))))))))
(DTypeSig true "pushTypeErrorHelpFixAt" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "Loc") (TyCon "String"))) (TyCon "Unit"))))))))
(DFunDef false "pushTypeErrorHelpFixAt" ((PVar "mctx") (PVar "code") (PVar "loc") (PVar "msg") (PVar "help") (PVar "fix")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "msg")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "typeErrorMsgSetRef") "value")) (EApp (EApp (EVar "noteTypeErrorDetected") (EVar "mctx")) (ELit LUnit)) (EApp (EApp (EVar "recordTypeError") (EVar "mctx")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "TcDiag") (EVar "code")) (ELit (LInt 1))) (EApp (EApp (EVar "orElseLoc") (EVar "loc")) (EFieldAccess (EVar "mctx") "mcLoc"))) (EVar "msg")) (EApp (EVar "Some") (EVar "help"))) (EVar "fix")))))
(DTypeSig false "writtenNames" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "writtenNames" ((PVar "text")) (EMatch (EApp (EApp (EVar "splitOnChar") (ELit (LChar "$"))) (EVar "text")) (arm (PList (PVar "only")) () (EVar "only")) (arm (PVar "parts") () (EApp (EVar "dropRenameSuffixes") (EVar "parts")))))
(DTypeSig false "dropRenameSuffixes" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "dropRenameSuffixes" ((PList)) (ELit (LString "")))
(DFunDef false "dropRenameSuffixes" ((PList (PVar "a"))) (EVar "a"))
(DFunDef false "dropRenameSuffixes" ((PCons (PVar "a") (PCons PWild (PCons (PVar "n") (PCons (PVar "lb") (PVar "more")))))) (EIf (EBinOp "&&" (EApp (EVar "allDigits") (EVar "n")) (EApp (EApp (EVar "startsWith") (ELit (LString "lb"))) (EVar "lb"))) (EBinOp "++" (EVar "a") (EApp (EVar "dropRenameSuffixes") (EBinOp "::" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 2))) (EApp (EVar "stringLength") (EVar "lb"))) (EVar "lb")) (EVar "more")))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "dropRenameSuffixes" ((PCons (PVar "a") (PVar "rest"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "a"))) (ELit (LString "$"))) (EApp (EMethodRef "display") (EApp (EVar "dropRenameSuffixes") (EVar "rest")))) (ELit (LString ""))))
(DTypeSig false "allDigits" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "allDigits" ((PVar "n")) (EBinOp "&&" (EBinOp ">" (EApp (EVar "stringLength") (EVar "n")) (ELit (LInt 0))) (EApp (EApp (EVar "allDigitsFrom") (EVar "n")) (ELit (LInt 0)))))
(DTypeSig false "allDigitsFrom" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "allDigitsFrom" ((PVar "n") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "stringLength") (EVar "n"))) (EVar "True") (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "c") (EApp (EApp (EApp (EVar "stringSlice") (EVar "i")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n"))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LString "0"))) (EBinOp "<=" (EVar "c") (ELit (LString "9")))) (EApp (EApp (EVar "allDigitsFrom") (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "writtenDiag" (TyFun (TyCon "TcDiag") (TyCon "TcDiag")))
(DFunDef false "writtenDiag" ((PCon "TcDiag" (PVar "code") (PVar "sev") (PVar "loc") (PVar "msg") (PVar "help") (PVar "fix"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "TcDiag") (EVar "code")) (EVar "sev")) (EVar "loc")) (EApp (EVar "writtenNames") (EVar "msg"))) (EApp (EApp (EMethodRef "map") (EVar "writtenNames")) (EVar "help"))) (EVar "fix")))
(DTypeSig true "backticked" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "backticked" ((PVar "s")) (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EMethodRef "display") (EVar "s"))) (ELit (LString "`"))))
(DTypeSig true "appSpineName" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "appSpineName" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "appSpineName") (EVar "e")))
(DFunDef false "appSpineName" ((PCon "EDoOrigin" PWild (PVar "e"))) (EApp (EVar "appSpineName") (EVar "e")))
(DFunDef false "appSpineName" ((PCon "EAnnot" (PVar "e") PWild)) (EApp (EVar "appSpineName") (EVar "e")))
(DFunDef false "appSpineName" ((PCon "EApp" (PVar "f") PWild)) (EApp (EVar "appSpineName") (EVar "f")))
(DFunDef false "appSpineName" ((PCon "EVar" (PVar "n"))) (EApp (EVar "Some") (EVar "n")))
(DFunDef false "appSpineName" ((PCon "EVarId" (PVar "n") PWild)) (EApp (EVar "Some") (EVar "n")))
(DFunDef false "appSpineName" ((PCon "EVarAt" (PVar "n") PWild)) (EApp (EVar "Some") (EVar "n")))
(DFunDef false "appSpineName" ((PCon "EMethodAt" (PVar "n") PWild PWild)) (EApp (EVar "Some") (EVar "n")))
(DFunDef false "appSpineName" ((PCon "EDictAt" (PVar "n") PWild)) (EApp (EVar "Some") (EVar "n")))
(DFunDef false "appSpineName" (PWild) (EVar "None"))
(DTypeSig false "tupleCallHintFor" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Mono") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyTuple (TyCon "Loc") (TyCon "String"))))))))
(DFunDef false "tupleCallHintFor" ((PVar "mctx") (PVar "m")) (EApp (EApp (EVar "findTupleCand") (EApp (EVar "ppMono") (EApp (EVar "normalize") (EVar "m")))) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "tupleCallCandidates") "value")))
(DTypeSig false "findTupleCand" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Mono") (TyCon "String") (TyApp (TyCon "Option") (TyTuple (TyCon "Loc") (TyCon "String"))))) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyTuple (TyCon "Loc") (TyCon "String"))))))))
(DFunDef false "findTupleCand" (PWild (PList)) (EVar "None"))
(DFunDef false "findTupleCand" ((PVar "key") (PCons (PTuple (PVar "res") (PVar "help") (PVar "fix")) (PVar "rest"))) (EIf (EBinOp "==" (EApp (EVar "ppMono") (EApp (EVar "normalize") (EVar "res"))) (EVar "key")) (EApp (EVar "Some") (ETuple (EVar "help") (EVar "fix"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "findTupleCand") (EVar "key")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "firstTupleCallHint" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyTuple (TyCon "Loc") (TyCon "String"))))))))
(DFunDef false "firstTupleCallHint" ((PVar "mctx") (PList)) (EVar "None"))
(DFunDef false "firstTupleCallHint" ((PVar "mctx") (PCons (PVar "m") (PVar "rest"))) (EMatch (EApp (EApp (EVar "tupleCallHintFor") (EVar "mctx")) (EVar "m")) (arm (PCon "Some" (PVar "hf")) () (EApp (EVar "Some") (EVar "hf"))) (arm (PCon "None") () (EApp (EApp (EVar "firstTupleCallHint") (EVar "mctx")) (EVar "rest")))))
(DTypeSig true "boundaryOwnsOpen" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "boundaryOwnsOpen" ((PVar "mctx") (PVar "rigidIds") (PVar "i")) (EBinOp "&&" (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EApp (EVar "intToString") (EVar "i"))) (EVar "rigidIds"))) (EApp (EVar "not") (EApp (EApp (EVar "IdMap.has") (EVar "i")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "deferrableVarIds") "value")))))
(DTypeSig true "ordinalWord" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "ordinalWord" ((PLit (LInt 0))) (ELit (LString "first")))
(DFunDef false "ordinalWord" ((PLit (LInt 1))) (ELit (LString "second")))
(DFunDef false "ordinalWord" ((PLit (LInt 2))) (ELit (LString "third")))
(DFunDef false "ordinalWord" ((PLit (LInt 3))) (ELit (LString "fourth")))
(DFunDef false "ordinalWord" ((PLit (LInt 4))) (ELit (LString "fifth")))
(DFunDef false "ordinalWord" ((PVar "i")) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EBinOp "+" (EVar "i") (ELit (LInt 1)))))) (ELit (LString "th"))))
(DTypeSig false "noImplFoundMsg" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "String"))))
(DFunDef false "noImplFoundMsg" ((PVar "iface") (PList (PVar "arg"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "no impl of ")) (EApp (EMethodRef "display") (EVar "iface"))) (ELit (LString " for "))) (EApp (EMethodRef "display") (EApp (EVar "ppMonosShared") (EListLit (EVar "arg"))))) (ELit (LString ""))))
(DFunDef false "noImplFoundMsg" ((PVar "iface") (PVar "args")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "no impl of ")) (EApp (EMethodRef "display") (EVar "iface"))) (ELit (LString " for "))) (EApp (EMethodRef "display") (EApp (EVar "ppPredArgsShared") (EVar "args")))) (ELit (LString ""))))
(DTypeSig false "noImplHint" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "noImplHint" ((PVar "mctx") (PVar "iface") (PList (PVar "arg"))) (EMatch (EApp (EVar "headTyconNameMono") (EVar "arg")) (arm (PCon "Some" (PVar "n")) () (EIf (EBinOp "&&" (EApp (EVar "derivableIface") (EVar "iface")) (EApp (EApp (EVar "headIsStdlibOwned") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "arg"))) (EVar "None") (EApp (EApp (EApp (EVar "noImplHintFor") (EVar "mctx")) (EVar "iface")) (EVar "n")))) (arm (PCon "None") () (EVar "None"))))
(DFunDef false "noImplHint" ((PVar "mctx") PWild PWild) (EVar "None"))
(DTypeSig false "headIsStdlibOwned" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Mono") (TyCon "Bool"))))
(DFunDef false "headIsStdlibOwned" ((PVar "gctx") (PVar "arg")) (EMatch (EApp (EVar "headTyconMono") (EVar "arg")) (arm (PCon "Some" (PCon "HkDecl" (PCon "TkIdent" (PCon "Ident" PWild (PVar "io") PWild)))) () (EApp (EApp (EApp (EVar "identOriginFold") (EVar "False")) (ELam ((PVar "mid")) (EApp (EApp (EVar "omHasKey") (EVar "mid")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "config") "value") "tcStdlibOwned")))) (EVar "io"))) (arm PWild () (EVar "False"))))
(DTypeSig false "noImplHintFor" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "noImplHintFor" ((PVar "mctx") (PVar "iface") (PVar "n")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "n")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "dataParamNameIndexRef") "value")) (EApp (EVar "Some") (EApp (EApp (EVar "noImplAdvice") (EVar "iface")) (EVar "n"))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "noImplAdvice" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "noImplAdvice" ((PVar "iface") (PVar "n")) (EIf (EApp (EVar "derivableIface") (EVar "iface")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "add `deriving ")) (EApp (EMethodRef "display") (EVar "iface"))) (ELit (LString "` to `"))) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "` or write `impl "))) (EApp (EMethodRef "display") (EVar "iface"))) (ELit (LString " "))) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "`"))) (EIf (EVar "otherwise") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "write `impl ")) (EApp (EMethodRef "display") (EVar "iface"))) (ELit (LString " "))) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "`"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "derivableIface" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "derivableIface" ((PVar "iface")) (EApp (EApp (EVar "contains") (EVar "iface")) (EListLit (ELit (LString "Eq")) (ELit (LString "Ord")) (ELit (LString "Debug")) (ELit (LString "Display")) (ELit (LString "Generic")))))
(DTypeSig false "noImplFoundMsgHinted" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))))))
(DFunDef false "noImplFoundMsgHinted" ((PVar "mctx") (PVar "iface") (PVar "args")) (EBlock (DoLet false false (PVar "base") (EApp (EApp (EVar "noImplFoundMsg") (EVar "iface")) (EVar "args"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "noImplHint") (EVar "mctx")) (EVar "iface")) (EVar "args")) (arm (PCon "Some" (PVar "hint")) () (ETuple (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "base"))) (ELit (LString "; "))) (EApp (EMethodRef "display") (EVar "hint"))) (ELit (LString ""))) (EApp (EVar "Some") (EVar "hint")))) (arm (PCon "None") () (ETuple (EVar "base") (EVar "None")))))))
(DTypeSig true "pushNoImplError" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "Unit"))))))
(DFunDef false "pushNoImplError" ((PVar "mctx") (PVar "iface") (PVar "loc") (PVar "args")) (EMatch (EApp (EApp (EVar "firstTupleCallHint") (EVar "mctx")) (EVar "args")) (arm (PCon "Some" (PTuple (PVar "help") (PVar "fix"))) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "pushTypeErrorHelpFixAt") (EVar "mctx")) (ELit (LString "T-NO-IMPL"))) (EVar "loc")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EApp (EVar "noImplFoundMsg") (EVar "iface")) (EVar "args")))) (ELit (LString "; "))) (EApp (EMethodRef "display") (EVar "help"))) (ELit (LString "")))) (EVar "help")) (EVar "fix"))) (arm (PCon "None") () (EBlock (DoLet false false (PTuple (PVar "msg") (PVar "mhint")) (EApp (EApp (EApp (EVar "noImplFoundMsgHinted") (EVar "mctx")) (EVar "iface")) (EVar "args"))) (DoExpr (EMatch (EVar "mhint") (arm (PCon "Some" (PVar "hint")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "pushTypeErrorHelpFixAt") (EVar "mctx")) (ELit (LString "T-NO-IMPL"))) (EVar "loc")) (EVar "msg")) (EVar "hint")) (EVar "None"))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOnceAt") (EVar "mctx")) (ELit (LString "T-NO-IMPL"))) (EVar "loc")) (EVar "msg")))))))))
(DTypeSig true "quotedNames" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "quotedNames" ((PVar "names")) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "n")) (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EVar "n")) (ELit (LString "`"))))) (EVar "names"))))
(DTypeSig true "prependDiagOpt" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "TcDiag")) (TyApp (TyCon "List") (TyCon "TcDiag"))))))))
(DFunDef false "prependDiagOpt" (PWild PWild PWild (PCon "None") (PVar "ds")) (EVar "ds"))
(DFunDef false "prependDiagOpt" ((PVar "code") (PVar "sev") (PVar "help") (PCon "Some" (PVar "msg")) (PVar "ds")) (EBinOp "::" (EApp (EVar "writtenDiag") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "TcDiag") (EVar "code")) (EVar "sev")) (EVar "None")) (EVar "msg")) (EVar "help")) (EVar "None"))) (EVar "ds")))
