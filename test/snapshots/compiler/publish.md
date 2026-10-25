# META
source_lines=748
stages=DESUGAR,MARK
# SOURCE
-- The shapes the typechecker publishes, and the pure functions that freeze a
-- scheme into them: a leaf that imports representation modules only, so a
-- consumer can name a report without importing `types.typecheck`.
--
-- `zonk*` rebuild a value with every `Link`/`ELink`/`ALink` followed and write no
-- cell.  Each unbound cell reached is re-minted as a NEW cell holding the same id
-- and level, memoized by id (one map per variable kind): a scheme and its
-- context that name one variable share one frozen cell.  Effect rows are shared
-- DAGs, so a join is rebuilt once per id, never once per incoming link.
--
-- A link-bearing effect cell survives only as a join member that carries labels
-- (the shared labelled suffix `effect_rows` keeps on purpose); `liveCells`
-- accepts exactly that and nothing else.
import frontend.ast.{Loc, Decl, EvTable, EvId}
import types.repr.{
  Mono(..), Tyvar(..), Scheme(..), AuthResidual(..), VecObl(..), ppSchemeCon
}
import types.effect_rows.{EffRow(..), Effvar(..), Atom(..)}
import types.effect_authority.{Authority(..), Authvar(..)}
import types.disposition.{DispositionTable}
import types.runtime_types.{BinderTypeTable}
import types.evidence_coverage.{EvidenceFault, evidenceFaults}
import map as IdMap
import map.{Map(..)}
import list.{nub, reverse, mapAccumL, last}
import support.ordmap.{OrdMap, omLookup}
import types.capability_manifest.{
  EntryKey(..),
  ManifestRequest(..),
  ManifestSelector(..),
  InvocationProtocol(..),
  CapabilityManifest,
  ManifestDefect(..),
}
import types.effect_domain.{Param}
import types.effect_invocation.{InvocationOps}
import types.manifest_publish.{
  InvocationOwner(..), ManifestEntryInput(..), publishManifests
}

-- ── structured typecheck diagnostic (TcDiag) ───────────────────────────────
-- ONE structured record per accumulated diagnostic (errors AND match warnings):
-- code, severity, span, message and optional help/fix inline, so nothing
-- downstream zips parallel lists or looks help up by message text.
-- `driver/diagnostics.mdk` maps a TcDiag to its `Diag` and thence to the
-- `--json` shape (DIAGNOSTIC-CODES-DESIGN.md).  `severity` is an Int (1 = error,
-- 2 = warning, the codes `--json` emits) because the real `Severity` type lives in
-- `driver/diagnostics.mdk`, which imports the typechecker, so importing it here
-- would cycle.  `fix` is a plain (Loc span, replacement) pair, converted to a
-- real `Fix` on the diagnostics side.
public export data TcDiag =
  TcDiag String Int (Option Loc) String (Option String) (Option (Loc, String))

export
tcCode : TcDiag -> String
tcCode (TcDiag c _ _ _ _ _) = c

export
tcMsg : TcDiag -> String
tcMsg (TcDiag _ _ _ m _ _) = m

export
tcLoc : TcDiag -> Option Loc
tcLoc (TcDiag _ _ l _ _ _) = l

-- One module's row in a graph drive's per-module diagnostics: its own value
-- schemes, each with the context its module recorded for it, its isolated errors
-- and its isolated warnings, under its module id.  The context is taken when the
-- module closes, because the table it is read from is overwritten by the next
-- module's check.
-- The schemes half is what lets the ENTRY REPORT be a projection of the same list
-- rather than a second pass (`checkModulesEntryFromDiags`); `dropModSchemes` is the
-- narrower `(errs, warns)` view the bucketing fold consumes.
export type ModDiags = (String, (List (String, PubScheme), List TcDiag, List TcDiag))

-- ── published shapes ───────────────────────────────────────────────────────

-- A scheme with its own context, frozen: no Link, no cell shared with inference.
public export data PubScheme = PubScheme {
  psScheme : Scheme,
  psContext : List VecObl,
}

-- A scheme rendered with the context it was published with.
export
ppPubScheme : PubScheme -> String
ppPubScheme p = ppSchemeCon p.psContext p.psScheme

-- The schemes alone, for a reader that renders no context.
export
pubSchemes : List (String, PubScheme) -> List (String, Scheme)
pubSchemes = map (b => (fst b, (snd b).psScheme))

export
publishedEntrySchemes : List (String, List (String, a)) -> List (String, a)
publishedEntrySchemes modules = option [] snd (last modules)

export
publishCore : OrdMap (List VecObl) ->
  List (String, Scheme) ->
  List (String, PubScheme)
publishCore contexts =
  publishWithContexts (name => optionOr [] (omLookup name contexts))

export
publishWithContexts : (String -> List VecObl) ->
  List (String, Scheme) ->
  List (String, PubScheme)
publishWithContexts context = map (b => (
  fst b,
  PubScheme {
    psScheme = snd b,
    psContext = context (fst b),
  },
))

export
publishedCore : Option (List (String, PubScheme)) ->
  OrdMap (List VecObl) ->
  List (String, Scheme) ->
  List (String, PubScheme)
publishedCore (Some rows) _ _ = rows
publishedCore None contexts schemes = freezeRows (publishCore contexts schemes)

-- Resolve against checked source rows before erasure; wrappers always name their
-- owning module rather than the entry's same-spelled binding.
export
publishSelected : List (String, Param) ->
  (InvocationOwner -> Option InvocationOps) ->
  List ManifestSelector ->
  List ModDiags ->
  List (String, PubScheme) ->
  EntryOutcome ->
  Option EntryKey ->
  Bool ->
  (List ManifestRequest, List CapabilityManifest, List TcDiag)
publishSelected _ _ [] _ _ _ _ _ = ([], [], [])
publishSelected domains resolveOps selectors perMod core outcome executes valueMain =
  let entry = optionOr ("", ([], [], [])) (last perMod)
  let byModule =
    IdMap.fromList
      (map (m => (fst m, IdMap.fromList (reverse (modSchemes (snd m))))) perMod)
  let coreRows = IdMap.fromList (reverse core)
  let rows owner = match owner
    SourceModule mid => optionOr Tip (IdMap.get mid byModule)
    ShippedPrelude => coreRows
  let ownerOf key =
    if key.moduleId == "core"
      && not (IdMap.has key.binding (rows (SourceModule "core"))) then
      ShippedPrelude
    else
      SourceModule key.moduleId
  let own = rows (SourceModule (fst entry))
  let resolve selector = match selector
    ExactEntry key protocol =>
      (ManifestRequest { entry = key, protocol = protocol }, ownerOf key)
    EntryOverPrelude name protocol =>
      let isOwn = IdMap.has name own
      (
        ManifestRequest {
          entry = EntryKey {
            moduleId = if isOwn then fst entry else "core",
            binding = name,
          },
          protocol = protocol,
        },
        if isOwn then SourceModule (fst entry) else ShippedPrelude,
      )
  let resolved = map resolve selectors
  let selected = map fst resolved
  let wrapper owner name =
    map (p => (owner, p.psScheme)) (IdMap.get name (rows owner))
  let wrappers request = match request.protocol
    HostInvocation => []
    ExecutedMain =>
      if request.entry.moduleId /= fst entry
        || request.entry.binding /= "main"
        || not valueMain
        || outcome.eoMainIsUnit then
        []
      else if outcome.eoMainIsAsync then
        option
          []
          (key => option [] (w => [w]) (wrapper (ownerOf key) key.binding))
          executes
      else
        option [] (w => [w]) (wrapper ShippedPrelude "println")
  let inputs =
    flatMap
      ((request, owner) =>
        option
          []
          (p => [
            ManifestEntryInput {
              request = request,
              owner = owner,
              scheme = p.psScheme,
              wrappers = wrappers request,
            },
          ])
          (IdMap.get request.entry.binding (rows owner)))
      resolved
  let missingDrivers =
    flatMap
      (request => match request.protocol
        HostInvocation => []
        ExecutedMain =>
          if request.entry.moduleId == fst entry
            && request.entry.binding == "main"
            && valueMain
            && outcome.eoMainIsAsync
            && isEmpty (wrappers request) then
            [
              TcDiag
                "T-MANIFEST-WRAPPER"
                1
                None
                "no checked Async driver selected for executed main"
                None
                None,
            ]
          else
            [])
      selected
  let missing =
    missingDrivers
      ++ flatMap
        ((request, owner) =>
          if IdMap.has request.entry.binding (rows owner) then
            []
          else
            [
              TcDiag
                "T-MANIFEST-ENTRY"
                1
                None
                ("no '" ++ request.entry.binding ++ "' entry found")
                None
                None,
            ])
        resolved
  match publishManifests domains resolveOps inputs
    Ok manifests => (selected, manifests, missing)
    Err defects => (
      selected,
      [],
      missing
        ++ map
          ((ManifestDefect message) =>
            TcDiag "T-MANIFEST-INVALID" 1 None message None None)
          defects,
    )

-- The three variable kinds count ids separately.
public export data VarKind = TyVarK | EffVarK | AuthVarK deriving (Eq, Debug)

-- A cell the validator found in a frozen value.  `LinkCell` is a link left after
-- freezing (a bug); a type variable's `Link` carries no id, so its id is `None`.
-- `FreeMeta` is an unquantified cell found anywhere but at graph end (a bug
-- there).  `WeakVar` is the same cell at graph end, where nothing in the graph
-- fixed it (allowed, listed).  `OpenSummary` is an effect summary still unsolved
-- at graph end.
public export data LiveCell =
  | LinkCell String VarKind (Option Int)
  | FreeMeta String VarKind Int
  | WeakVar String VarKind Int
  | OpenSummary String Int
  deriving (Eq, Debug)

-- `paModule` is the module whose locals and seed the analysis holds: the last
-- module the drive checked, which is not the entry when resolve blocked it.  A
-- local's `Loc` is `None` where its binding site has none to give.
public export data PartialAnalysis = PartialAnalysis {
  paModule : String,
  paSchemes : List (String, List (String, PubScheme)),
  paCore : List (String, PubScheme),
  paLocals : List (String, PubScheme, Option Loc),
  paSeed : List (String, PubScheme),
}

-- The last-checked module's id, locals and import seed, each frozen with its own
-- context, taken while the typechecker's per-module tables are still that module's.
public export data EntryTables = EntryTables {
  etModule : String,
  etLocals : List (String, PubScheme, Option Loc),
  etSeed : List (String, PubScheme),
}

-- A drive that checked no module.
export
noEntryTables : EntryTables
noEntryTables = EntryTables { etModule = "", etLocals = [], etSeed = [] }

export
partialAnalysis : List (String, List (String, PubScheme)) ->
  List (String, PubScheme) ->
  EntryTables ->
  PartialAnalysis
partialAnalysis schemes core tables = PartialAnalysis {
  paModule = tables.etModule,
  paSchemes = schemes,
  paCore = core,
  paLocals = tables.etLocals,
  paSeed = tables.etSeed,
}

public export data CheckedProgram = CheckedProgram {
  cpSchemes : List (String, List (String, PubScheme)),
  cpCore : List (String, PubScheme),
  cpEvidence : EvTable,
  cpDispositions : DispositionTable,
  cpBinders : BinderTypeTable,
  cpEntryOutcome : EntryOutcome,
  cpTrees : Option (List Decl, List (String, List Decl)),
  cpWeak : List LiveCell,
  cpManifests : List CapabilityManifest,
}

public export data EntryOutcome = EntryOutcome {
  eoMainIsUnit : Bool,
  eoMainIsFloat : Bool,
  eoMainIsAsync : Bool,
  eoMainAsyncPayloadIsUnit : Bool,
  eoAutoPrint : Option EvId,
}

export
noEntryOutcome : EntryOutcome
noEntryOutcome = EntryOutcome {
  eoMainIsUnit = False,
  eoMainIsFloat = False,
  eoMainIsAsync = False,
  eoMainAsyncPayloadIsUnit = False,
  eoAutoPrint = None,
}

public export data TcReport = TcReport {
  trPartial : PartialAnalysis,
  trDiagnostics : List ModDiags,
  trResidual : List (String, TcDiag),
  trChecked : Option CheckedProgram,
  trEvidenceFaults : List EvidenceFault,
}

-- ── deep zonk, freeze by copy ──────────────────────────────────────────────

-- Per-kind memo of the frozen cell minted for each id, plus the frozen row of
-- each linked effect cell (so a shared labelled suffix is rebuilt once).
public export data ZState = ZState {
  zTys : Map Int (Ref Tyvar),
  zEffs : Map Int (Ref Effvar),
  zAuths : Map Int (Ref Authvar),
  zLinks : Map Int EffRow,
}

export
emptyZonk : ZState
emptyZonk = ZState { zTys = Tip, zEffs = Tip, zAuths = Tip, zLinks = Tip }

export
zonkMono : ZState -> Mono -> (ZState, Mono)
zonkMono z (TVar cell) = match !cell
  Link t => zonkMono z t
  Unbound id lvl => match IdMap.get id z.zTys
    Some c => (z, TVar c)
    None =>
      let c = Ref (Unbound id lvl)
      ({ z | zTys = IdMap.set id c z.zTys }, TVar c)
zonkMono z (TApp a b) =
  let (z1, a1) = zonkMono z a
  let (z2, b1) = zonkMono z1 b
  (z2, TApp a1 b1)
zonkMono z (TFun a row b) =
  let (z1, a1) = zonkMono z a
  let (z2, row1) = zonkRow z1 row
  let (z3, b1) = zonkMono z2 b
  (z3, TFun a1 row1 b1)
zonkMono z (TEff row) =
  let (z1, row1) = zonkRow z row
  (z1, TEff row1)
zonkMono z (TQual m auth) =
  let (z1, m1) = zonkMono z m
  let (z2, auth1) = zonkAuthority z1 auth
  (z2, TQual m1 auth1)
zonkMono z (TAuth auth) =
  let (z1, auth1) = zonkAuthority z auth
  (z1, TAuth auth1)
zonkMono z m = (z, m)

export
zonkAuthority : ZState -> Authority -> (ZState, Authority)
zonkAuthority z (AVar cell) = match !cell
  ALink _ _ target => zonkAuthority z target
  AUnbound id lvl top pat name => match IdMap.get id z.zAuths
    Some c => (z, AVar c)
    None =>
      let c = Ref (AUnbound id lvl top pat name)
      ({ z | zAuths = IdMap.set id c z.zAuths }, AVar c)
zonkAuthority z (AJoin ms) =
  let (z1, ms1) = mapAccumL zonkAuthority z ms
  (z1, AJoin ms1)
zonkAuthority z (AProduct axes) =
  let (z1, axes1) = mapAccumL zonkAxis z axes
  (z1, AProduct axes1)
zonkAuthority z a = (z, a)

zonkAxis : ZState -> (String, Authority) -> (ZState, (String, Authority))
zonkAxis z (name, a) =
  let (z1, a1) = zonkAuthority z a
  (z1, (name, a1))

zonkAtom : ZState -> Atom -> (ZState, Atom)
zonkAtom z (Atom lbl auth) =
  let (z1, auth1) = zonkAuthority z auth
  (z1, Atom lbl auth1)

-- A row's tail cell is followed through `ELink`; an `EJoin` is rebuilt with each
-- member re-minted.
export
zonkRow : ZState -> EffRow -> (ZState, EffRow)
zonkRow z (EffRow atoms tail) =
  let (z1, atoms1) = mapAccumL zonkAtom z atoms
  match tail
    None => (z1, EffRow atoms1 None)
    Some cell => match !cell
      ELink id row =>
        let (z2, EffRow more rest) = linkedRow z1 id row
        (z2, EffRow (atoms1 ++ more) rest)
      _ =>
        let (z2, c) = zonkEffCell z1 cell
        (z2, EffRow atoms1 (Some c))

linkedRow : ZState -> Int -> EffRow -> (ZState, EffRow)
linkedRow z id row = match IdMap.get id z.zLinks
  Some r => (z, r)
  None =>
    let (z1, r) = zonkRow z row
    ({ z1 | zLinks = IdMap.set id r z1.zLinks }, r)

-- A cell in member position (or a row tail that is not a link): the frozen cell
-- for this id.
zonkEffCell : ZState -> Ref Effvar -> (ZState, Ref Effvar)
zonkEffCell z cell = match !cell
  EUnbound id lvl => memoEff z id (EUnbound id lvl)
  ESummary id a b => memoEff z id (ESummary id a b)
  EJoin id lvl members => match IdMap.get id z.zEffs
    Some c => (z, c)
    None =>
      let (z1, ms) = mapAccumL zonkEffCell z members
      let c = Ref (EJoin id lvl ms)
      ({ z1 | zEffs = IdMap.set id c z1.zEffs }, c)
  ELink id row => match IdMap.get id z.zEffs
    Some c => (z, c)
    None =>
      let (z1, r) = linkedRow z id row
      match r
        EffRow [] (Some t) => ({ z1 | zEffs = IdMap.set id t z1.zEffs }, t)
        _ =>
          let c = Ref (ELink id r)
          ({ z1 | zEffs = IdMap.set id c z1.zEffs }, c)

memoEff : ZState -> Int -> Effvar -> (ZState, Ref Effvar)
memoEff z id v = match IdMap.get id z.zEffs
  Some c => (z, c)
  None =>
    let c = Ref v
    ({ z | zEffs = IdMap.set id c z.zEffs }, c)

export
zonkVecObl : ZState -> VecObl -> (ZState, VecObl)
zonkVecObl z (VecObl { voIface = iface, voIds = ids, voArgs = args }) =
  let (z1, args1) = mapAccumL zonkMono z args
  (z1, VecObl { voIface = iface, voIds = ids, voArgs = args1 })

zonkResidual : ZState -> AuthResidual -> (ZState, AuthResidual)
zonkResidual z (AuthResidual { arLower = lo, arUpper = hi, arExact = ex }) =
  let (z1, lo1) = zonkAuthority z lo
  let (z2, hi1) = zonkAuthority z1 hi
  (z2, AuthResidual { arLower = lo1, arUpper = hi1, arExact = ex })

export
zonkScheme : ZState -> Scheme -> (ZState, Scheme)
zonkScheme z (Forall ids effIds authIds residuals row t) =
  let (z1, residuals1) = mapAccumL zonkResidual z residuals
  let (z2, row1) = zonkRow z1 row
  let (z3, t1) = zonkMono z2 t
  (z3, Forall ids effIds authIds residuals1 row1 t1)

-- Freeze a scheme and its context together: one new cell per (kind, id), shared
-- between the two, so the context's ids still name the scheme's variables.
export
freezePub : Scheme -> List VecObl -> PubScheme
freezePub s ctx =
  let (z1, s1) = zonkScheme emptyZonk s
  let (_, ctx1) = mapAccumL zonkVecObl z1 ctx
  PubScheme { psScheme = s1, psContext = ctx1 }

-- Each row frozen on its own.  A weak cell two schemes share becomes one copy
-- per scheme: a frozen value is never unified again, and a scheme's variables are
-- named within that scheme, so the copies render as the shared cell did.
export
freezeRows : List (String, PubScheme) -> List (String, PubScheme)
freezeRows = map (b => (fst b, freezePub (snd b).psScheme (snd b).psContext))

export
freezeModDiags : ModDiags -> ModDiags
freezeModDiags (mid, (schemes, errs, warns)) =
  (mid, (freezeRows schemes, errs, warns))

-- The first [n] rows frozen and the rest kept: for a list whose tail an earlier
-- point already froze.
export
freezeNewest : Int -> List ModDiags -> List ModDiags
freezeNewest n rows
  | n <= 0 = rows
  | otherwise = match rows
    [] => []
    m :: rest => freezeModDiags m :: freezeNewest (n - 1) rest

-- ── the report of one graph drive ──────────────────────────────────────────

-- The report over a drive's frozen outputs.  `trChecked` is withheld on any
-- error the drive reports, any link left after freezing, any effect summary
-- still unsolved, and any evidence fault; the weak variables it allows are listed
-- in `cpWeak`.  The project typecheck pass (`typecheckPassReport` in
-- `driver/diagnostics.mdk`) also withholds it when resolve rejected any module of
-- the graph.  Every report `frontEnd` returns also withholds it on an error the
-- raw-tree passes add outside the drive (`R-CANNOT-DERIVE`); only a bare
-- `typecheckPassReport` does not.  The evidence table is built only for a drive
-- with no error, link or open summary: an ill-typed drive has no checked program
-- to carry it.  `trEvidenceFaults` is what the table failed against the trees,
-- empty when it was not built.
-- `tables` fill the partial analysis whether or not the program is checked.
export
graphReport : List ModDiags ->
  List (String, PubScheme) ->
  List (String, TcDiag) ->
  (Unit -> EvTable) ->
  DispositionTable ->
  BinderTypeTable ->
  Option (List Decl, List (String, List Decl)) ->
  EntryTables ->
  TcReport
graphReport perMod core residual evidence dispositions binders trees tables =
  graphReportWithOutcome
    noEntryOutcome
    []
    []
    perMod
    core
    residual
    evidence
    dispositions
    binders
    trees
    tables

export
graphReportWithOutcome : EntryOutcome ->
  List CapabilityManifest ->
  List TcDiag ->
  List ModDiags ->
  List (String, PubScheme) ->
  List (String, TcDiag) ->
  (Unit -> EvTable) ->
  DispositionTable ->
  BinderTypeTable ->
  Option (List Decl, List (String, List Decl)) ->
  EntryTables ->
  TcReport
graphReportWithOutcome outcome manifests manifestDiags perMod core residual evidence dispositions binders trees tables =
  let schemes = map (m => (fst m, modSchemes (snd m))) perMod
  let cells = graphCells (core :: map snd schemes)
  let judged =
    if isEmpty residual
      && isEmpty manifestDiags
      && noModErrors perMod
      && all isWeak cells then
      let table = evidence ()
      Some (table, evidenceFaults trees table)
    else
      None
  let checked = match judged
    Some (table, []) => Some CheckedProgram {
      cpSchemes = schemes,
      cpCore = core,
      cpEvidence = table,
      cpDispositions = dispositions,
      cpBinders = binders,
      cpEntryOutcome = outcome,
      cpTrees = trees,
      cpWeak = cells,
      cpManifests = manifests,
    }
    _ => None
  TcReport {
    trPartial = partialAnalysis schemes core tables,
    trDiagnostics = perMod,
    trResidual = residual ++ map (d => (tables.etModule, d)) manifestDiags,
    trChecked = checked,
    trEvidenceFaults = match judged
      Some (_, faults) => faults
      None => [],
  }

-- Every live cell of every row, read at graph end.
export
graphCells : List (List (String, PubScheme)) -> List LiveCell
graphCells [] = []
graphCells (rows :: rest) = rowCells rows (graphCells rest)

rowCells : List (String, PubScheme) -> List LiveCell -> List LiveCell
rowCells [] acc = acc
rowCells ((name, p) :: rest) acc =
  atGraphEnd (liveCells name p) ++ rowCells rest acc

modSchemes : (List (String, PubScheme), List TcDiag, List TcDiag) ->
  List (String, PubScheme)
modSchemes (s, _, _) = s

noModErrors : List ModDiags -> Bool
noModErrors [] = True
noModErrors ((_, (_, [], _)) :: rest) = noModErrors rest
noModErrors _ = False

isWeak : LiveCell -> Bool
isWeak (WeakVar _ _ _) = True
isWeak _ = False

-- ── live-cell validator ────────────────────────────────────────────────────

-- Seen effect ids (a shared row is walked once) and the cells found, newest first.
data Walk = Walk (Map Int Unit) (List LiveCell)

-- The cells in a frozen value that are not clean.  An unbound id outside the
-- quantifier lists is reported as `FreeMeta`; `atGraphEnd` renames those to the
-- allowed `WeakVar` for a value inspected at graph end.
export
liveCells : String -> PubScheme -> List LiveCell
liveCells name (PubScheme { psScheme = (Forall ids effIds authIds residuals row t), psContext = ctx }) =
  let w0 = Walk Tip []
  let w1 = walkResiduals name authIds residuals w0
  let w2 = walkRow name effIds authIds row w1
  let w3 = walkMono name ids effIds authIds t w2
  let w4 = foldWalk (walkObl name ids effIds authIds) ctx w3
  match w4
    Walk _ found => nub (reverse found)

-- At graph end nothing in the graph can fix an unquantified cell: it is a
-- weak variable.
export
atGraphEnd : List LiveCell -> List LiveCell
atGraphEnd = map toWeak

toWeak : LiveCell -> LiveCell
toWeak (FreeMeta n k i) = WeakVar n k i
toWeak c = c

foldWalk : (a -> Walk -> Walk) -> List a -> Walk -> Walk
foldWalk _ [] w = w
foldWalk f (x :: xs) w = foldWalk f xs (f x w)

push : LiveCell -> Walk -> Walk
push c (Walk seen found) = Walk seen (c :: found)

hasId : Int -> List Int -> Bool
hasId _ [] = False
hasId x (y :: ys) = x == y || hasId x ys

walkObl : String -> List Int -> List Int -> List Int -> VecObl -> Walk -> Walk
walkObl name ids effIds authIds (VecObl { voArgs = args }) w =
  foldWalk (walkMono name ids effIds authIds) args w

walkResiduals : String -> List Int -> List AuthResidual -> Walk -> Walk
walkResiduals name authIds rs w =
  foldWalk
    (r acc => match r
      AuthResidual { arLower = lo, arUpper = hi } =>
        walkAuth name authIds hi (walkAuth name authIds lo acc))
    rs
    w

walkMono : String -> List Int -> List Int -> List Int -> Mono -> Walk -> Walk
walkMono name ids effIds authIds (TVar cell) w = match !cell
  Link _ => push (LinkCell name TyVarK None) w
  Unbound id _ => if hasId id ids then w else push (FreeMeta name TyVarK id) w
walkMono name ids effIds authIds (TApp a b) w =
  walkMono name ids effIds authIds b (walkMono name ids effIds authIds a w)
walkMono name ids effIds authIds (TFun a row b) w =
  let w1 = walkMono name ids effIds authIds a w
  let w2 = walkRow name effIds authIds row w1
  walkMono name ids effIds authIds b w2
walkMono name _ effIds authIds (TEff row) w = walkRow name effIds authIds row w
walkMono name ids effIds authIds (TQual inner auth) w =
  walkAuth name authIds auth (walkMono name ids effIds authIds inner w)
walkMono name _ _ authIds (TAuth auth) w = walkAuth name authIds auth w
walkMono _ _ _ _ _ w = w

walkAuth : String -> List Int -> Authority -> Walk -> Walk
walkAuth name authIds (AVar cell) w = match !cell
  ALink id _ _ => push (LinkCell name AuthVarK (Some id)) w
  AUnbound id _ _ _ _ =>
    if hasId id authIds then w else push (FreeMeta name AuthVarK id) w
walkAuth name authIds (AJoin ms) w = foldWalk (walkAuth name authIds) ms w
walkAuth name authIds (AProduct axes) w =
  foldWalk (axis acc => walkAuth name authIds (snd axis) acc) axes w
walkAuth _ _ _ w = w

walkRow : String -> List Int -> List Int -> EffRow -> Walk -> Walk
walkRow name effIds authIds (EffRow atoms tail) w =
  let w1 =
    foldWalk
      (atom acc => match atom
        Atom _ auth => walkAuth name authIds auth acc)
      atoms
      w
  match tail
    None => w1
    Some cell => walkEffCell name effIds authIds False cell w1

-- `member` is True for a join member, where a labelled `ELink` is the accepted
-- shared-suffix form.
walkEffCell : String ->
  List Int ->
  List Int ->
  Bool ->
  Ref Effvar ->
  Walk ->
  Walk
walkEffCell name effIds authIds member cell (w@(Walk seen found)) = match !cell
  EUnbound id _ =>
    if hasId id effIds then w else push (FreeMeta name EffVarK id) w
  ESummary id _ _ => push (OpenSummary name id) w
  ELink id row =>
    if IdMap.has id seen then
      w
    else
      let w1 = Walk (IdMap.set id () seen) found
      let w2 = if member then w1 else push (LinkCell name EffVarK (Some id)) w1
      walkRow name effIds authIds row w2
  EJoin id _ members =>
    if IdMap.has id seen then
      w
    else
      foldWalk
        (walkEffCell name effIds authIds True)
        members
        (Walk (IdMap.set id () seen) found)
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" false) (mem "Decl" false) (mem "EvTable" false) (mem "EvId" false))))
(DUse false (UseGroup ("types" "repr") ((mem "Mono" true) (mem "Tyvar" true) (mem "Scheme" true) (mem "AuthResidual" true) (mem "VecObl" true) (mem "ppSchemeCon" false))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "EffRow" true) (mem "Effvar" true) (mem "Atom" true))))
(DUse false (UseGroup ("types" "effect_authority") ((mem "Authority" true) (mem "Authvar" true))))
(DUse false (UseGroup ("types" "disposition") ((mem "DispositionTable" false))))
(DUse false (UseGroup ("types" "runtime_types") ((mem "BinderTypeTable" false))))
(DUse false (UseGroup ("types" "evidence_coverage") ((mem "EvidenceFault" false) (mem "evidenceFaults" false))))
(DUse false (UseAlias ("map") "IdMap"))
(DUse false (UseGroup ("map") ((mem "Map" true))))
(DUse false (UseGroup ("list") ((mem "nub" false) (mem "reverse" false) (mem "mapAccumL" false) (mem "last" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omLookup" false))))
(DUse false (UseGroup ("types" "capability_manifest") ((mem "EntryKey" true) (mem "ManifestRequest" true) (mem "ManifestSelector" true) (mem "InvocationProtocol" true) (mem "CapabilityManifest" false) (mem "ManifestDefect" true))))
(DUse false (UseGroup ("types" "effect_domain") ((mem "Param" false))))
(DUse false (UseGroup ("types" "effect_invocation") ((mem "InvocationOps" false))))
(DUse false (UseGroup ("types" "manifest_publish") ((mem "InvocationOwner" true) (mem "ManifestEntryInput" true) (mem "publishManifests" false))))
(DData Public "TcDiag" () ((variant "TcDiag" (ConPos (TyCon "String") (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "Option") (TyTuple (TyCon "Loc") (TyCon "String")))))) ())
(DTypeSig true "tcCode" (TyFun (TyCon "TcDiag") (TyCon "String")))
(DFunDef false "tcCode" ((PCon "TcDiag" (PVar "c") PWild PWild PWild PWild PWild)) (EVar "c"))
(DTypeSig true "tcMsg" (TyFun (TyCon "TcDiag") (TyCon "String")))
(DFunDef false "tcMsg" ((PCon "TcDiag" PWild PWild PWild (PVar "m") PWild PWild)) (EVar "m"))
(DTypeSig true "tcLoc" (TyFun (TyCon "TcDiag") (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "tcLoc" ((PCon "TcDiag" PWild PWild (PVar "l") PWild PWild PWild)) (EVar "l"))
(DTypeAlias true "ModDiags" () (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))) (TyApp (TyCon "List") (TyCon "TcDiag")) (TyApp (TyCon "List") (TyCon "TcDiag")))))
(DData Public "PubScheme" () ((variant "PubScheme" (ConNamed (field "psScheme" (TyCon "Scheme")) (field "psContext" (TyApp (TyCon "List") (TyCon "VecObl")))))) ())
(DTypeSig true "ppPubScheme" (TyFun (TyCon "PubScheme") (TyCon "String")))
(DFunDef false "ppPubScheme" ((PVar "p")) (EApp (EApp (EVar "ppSchemeCon") (EFieldAccess (EVar "p") "psContext")) (EFieldAccess (EVar "p") "psScheme")))
(DTypeSig true "pubSchemes" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme")))))
(DFunDef false "pubSchemes" () (EApp (EVar "map") (ELam ((PVar "b")) (ETuple (EApp (EVar "fst") (EVar "b")) (EFieldAccess (EApp (EVar "snd") (EVar "b")) "psScheme")))))
(DTypeSig true "publishedEntrySchemes" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a"))))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a")))))
(DFunDef false "publishedEntrySchemes" ((PVar "modules")) (EApp (EApp (EApp (EVar "option") (EListLit)) (EVar "snd")) (EApp (EVar "last") (EVar "modules"))))
(DTypeSig true "publishCore" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "VecObl"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))))))
(DFunDef false "publishCore" ((PVar "contexts")) (EApp (EVar "publishWithContexts") (ELam ((PVar "name")) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "name")) (EVar "contexts"))))))
(DTypeSig true "publishWithContexts" (TyFun (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "VecObl"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))))))
(DFunDef false "publishWithContexts" ((PVar "context")) (EApp (EVar "map") (ELam ((PVar "b")) (ETuple (EApp (EVar "fst") (EVar "b")) (ERecordCreate "PubScheme" ((fa "psScheme" (EApp (EVar "snd") (EVar "b"))) (fa "psContext" (EApp (EVar "context") (EApp (EVar "fst") (EVar "b"))))))))))
(DTypeSig true "publishedCore" (TyFun (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme")))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "VecObl"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme")))))))
(DFunDef false "publishedCore" ((PCon "Some" (PVar "rows")) PWild PWild) (EVar "rows"))
(DFunDef false "publishedCore" ((PCon "None") (PVar "contexts") (PVar "schemes")) (EApp (EVar "freezeRows") (EApp (EApp (EVar "publishCore") (EVar "contexts")) (EVar "schemes"))))
(DTypeSig true "publishSelected" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyFun (TyFun (TyCon "InvocationOwner") (TyApp (TyCon "Option") (TyCon "InvocationOps"))) (TyFun (TyApp (TyCon "List") (TyCon "ManifestSelector")) (TyFun (TyApp (TyCon "List") (TyCon "ModDiags")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))) (TyFun (TyCon "EntryOutcome") (TyFun (TyApp (TyCon "Option") (TyCon "EntryKey")) (TyFun (TyCon "Bool") (TyTuple (TyApp (TyCon "List") (TyCon "ManifestRequest")) (TyApp (TyCon "List") (TyCon "CapabilityManifest")) (TyApp (TyCon "List") (TyCon "TcDiag"))))))))))))
(DFunDef false "publishSelected" (PWild PWild (PList) PWild PWild PWild PWild PWild) (ETuple (EListLit) (EListLit) (EListLit)))
(DFunDef false "publishSelected" ((PVar "domains") (PVar "resolveOps") (PVar "selectors") (PVar "perMod") (PVar "core") (PVar "outcome") (PVar "executes") (PVar "valueMain")) (EBlock (DoLet false false (PVar "entry") (EApp (EApp (EVar "optionOr") (ETuple (ELit (LString "")) (ETuple (EListLit) (EListLit) (EListLit)))) (EApp (EVar "last") (EVar "perMod")))) (DoLet false false (PVar "byModule") (EApp (EVar "IdMap.fromList") (EApp (EApp (EVar "map") (ELam ((PVar "m")) (ETuple (EApp (EVar "fst") (EVar "m")) (EApp (EVar "IdMap.fromList") (EApp (EVar "reverse") (EApp (EVar "modSchemes") (EApp (EVar "snd") (EVar "m")))))))) (EVar "perMod")))) (DoLet false false (PVar "coreRows") (EApp (EVar "IdMap.fromList") (EApp (EVar "reverse") (EVar "core")))) (DoLet false true (PVar "rows") (ELam ((PVar "owner")) (EMatch (EVar "owner") (arm (PCon "SourceModule" (PVar "mid")) () (EApp (EApp (EVar "optionOr") (EVar "Tip")) (EApp (EApp (EVar "IdMap.get") (EVar "mid")) (EVar "byModule")))) (arm (PCon "ShippedPrelude") () (EVar "coreRows"))))) (DoLet false true (PVar "ownerOf") (ELam ((PVar "key")) (EIf (EBinOp "&&" (EBinOp "==" (EFieldAccess (EVar "key") "moduleId") (ELit (LString "core"))) (EApp (EVar "not") (EApp (EApp (EVar "IdMap.has") (EFieldAccess (EVar "key") "binding")) (EApp (EVar "rows") (EApp (EVar "SourceModule") (ELit (LString "core"))))))) (EVar "ShippedPrelude") (EApp (EVar "SourceModule") (EFieldAccess (EVar "key") "moduleId"))))) (DoLet false false (PVar "own") (EApp (EVar "rows") (EApp (EVar "SourceModule") (EApp (EVar "fst") (EVar "entry"))))) (DoLet false true (PVar "resolve") (ELam ((PVar "selector")) (EMatch (EVar "selector") (arm (PCon "ExactEntry" (PVar "key") (PVar "protocol")) () (ETuple (ERecordCreate "ManifestRequest" ((fa "entry" (EVar "key")) (fa "protocol" (EVar "protocol")))) (EApp (EVar "ownerOf") (EVar "key")))) (arm (PCon "EntryOverPrelude" (PVar "name") (PVar "protocol")) () (EBlock (DoLet false false (PVar "isOwn") (EApp (EApp (EVar "IdMap.has") (EVar "name")) (EVar "own"))) (DoExpr (ETuple (ERecordCreate "ManifestRequest" ((fa "entry" (ERecordCreate "EntryKey" ((fa "moduleId" (EIf (EVar "isOwn") (EApp (EVar "fst") (EVar "entry")) (ELit (LString "core")))) (fa "binding" (EVar "name"))))) (fa "protocol" (EVar "protocol")))) (EIf (EVar "isOwn") (EApp (EVar "SourceModule") (EApp (EVar "fst") (EVar "entry"))) (EVar "ShippedPrelude"))))))))) (DoLet false false (PVar "resolved") (EApp (EApp (EVar "map") (EVar "resolve")) (EVar "selectors"))) (DoLet false false (PVar "selected") (EApp (EApp (EVar "map") (EVar "fst")) (EVar "resolved"))) (DoLet false true (PVar "wrapper") (ELam ((PVar "owner")) (ELam ((PVar "name")) (EApp (EApp (EVar "map") (ELam ((PVar "p")) (ETuple (EVar "owner") (EFieldAccess (EVar "p") "psScheme")))) (EApp (EApp (EVar "IdMap.get") (EVar "name")) (EApp (EVar "rows") (EVar "owner"))))))) (DoLet false true (PVar "wrappers") (ELam ((PVar "request")) (EMatch (EFieldAccess (EVar "request") "protocol") (arm (PCon "HostInvocation") () (EListLit)) (arm (PCon "ExecutedMain") () (EIf (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "/=" (EFieldAccess (EFieldAccess (EVar "request") "entry") "moduleId") (EApp (EVar "fst") (EVar "entry"))) (EBinOp "/=" (EFieldAccess (EFieldAccess (EVar "request") "entry") "binding") (ELit (LString "main")))) (EApp (EVar "not") (EVar "valueMain"))) (EFieldAccess (EVar "outcome") "eoMainIsUnit")) (EListLit) (EIf (EFieldAccess (EVar "outcome") "eoMainIsAsync") (EApp (EApp (EApp (EVar "option") (EListLit)) (ELam ((PVar "key")) (EApp (EApp (EApp (EVar "option") (EListLit)) (ELam ((PVar "w")) (EListLit (EVar "w")))) (EApp (EApp (EVar "wrapper") (EApp (EVar "ownerOf") (EVar "key"))) (EFieldAccess (EVar "key") "binding"))))) (EVar "executes")) (EApp (EApp (EApp (EVar "option") (EListLit)) (ELam ((PVar "w")) (EListLit (EVar "w")))) (EApp (EApp (EVar "wrapper") (EVar "ShippedPrelude")) (ELit (LString "println")))))))))) (DoLet false false (PVar "inputs") (EApp (EApp (EVar "flatMap") (ELam ((PTuple (PVar "request") (PVar "owner"))) (EApp (EApp (EApp (EVar "option") (EListLit)) (ELam ((PVar "p")) (EListLit (ERecordCreate "ManifestEntryInput" ((fa "request" (EVar "request")) (fa "owner" (EVar "owner")) (fa "scheme" (EFieldAccess (EVar "p") "psScheme")) (fa "wrappers" (EApp (EVar "wrappers") (EVar "request")))))))) (EApp (EApp (EVar "IdMap.get") (EFieldAccess (EFieldAccess (EVar "request") "entry") "binding")) (EApp (EVar "rows") (EVar "owner")))))) (EVar "resolved"))) (DoLet false false (PVar "missingDrivers") (EApp (EApp (EVar "flatMap") (ELam ((PVar "request")) (EMatch (EFieldAccess (EVar "request") "protocol") (arm (PCon "HostInvocation") () (EListLit)) (arm (PCon "ExecutedMain") () (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EFieldAccess (EFieldAccess (EVar "request") "entry") "moduleId") (EApp (EVar "fst") (EVar "entry"))) (EBinOp "==" (EFieldAccess (EFieldAccess (EVar "request") "entry") "binding") (ELit (LString "main")))) (EVar "valueMain")) (EFieldAccess (EVar "outcome") "eoMainIsAsync")) (EApp (EVar "isEmpty") (EApp (EVar "wrappers") (EVar "request")))) (EListLit (EApp (EApp (EApp (EApp (EApp (EApp (EVar "TcDiag") (ELit (LString "T-MANIFEST-WRAPPER"))) (ELit (LInt 1))) (EVar "None")) (ELit (LString "no checked Async driver selected for executed main"))) (EVar "None")) (EVar "None"))) (EListLit)))))) (EVar "selected"))) (DoLet false false (PVar "missing") (EBinOp "++" (EVar "missingDrivers") (EApp (EApp (EVar "flatMap") (ELam ((PTuple (PVar "request") (PVar "owner"))) (EIf (EApp (EApp (EVar "IdMap.has") (EFieldAccess (EFieldAccess (EVar "request") "entry") "binding")) (EApp (EVar "rows") (EVar "owner"))) (EListLit) (EListLit (EApp (EApp (EApp (EApp (EApp (EApp (EVar "TcDiag") (ELit (LString "T-MANIFEST-ENTRY"))) (ELit (LInt 1))) (EVar "None")) (EBinOp "++" (EBinOp "++" (ELit (LString "no '")) (EFieldAccess (EFieldAccess (EVar "request") "entry") "binding")) (ELit (LString "' entry found")))) (EVar "None")) (EVar "None")))))) (EVar "resolved")))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "publishManifests") (EVar "domains")) (EVar "resolveOps")) (EVar "inputs")) (arm (PCon "Ok" (PVar "manifests")) () (ETuple (EVar "selected") (EVar "manifests") (EVar "missing"))) (arm (PCon "Err" (PVar "defects")) () (ETuple (EVar "selected") (EListLit) (EBinOp "++" (EVar "missing") (EApp (EApp (EVar "map") (ELam ((PCon "ManifestDefect" (PVar "message"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "TcDiag") (ELit (LString "T-MANIFEST-INVALID"))) (ELit (LInt 1))) (EVar "None")) (EVar "message")) (EVar "None")) (EVar "None")))) (EVar "defects")))))))))
(DData Public "VarKind" () ((variant "TyVarK" (ConPos)) (variant "EffVarK" (ConPos)) (variant "AuthVarK" (ConPos))) ())
(DImpl true "Eq" ((TyCon "VarKind")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "TyVarK") (PCon "TyVarK")) () (EVar "True")) (arm (PTuple (PCon "EffVarK") (PCon "EffVarK")) () (EVar "True")) (arm (PTuple (PCon "AuthVarK") (PCon "AuthVarK")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "VarKind")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "TyVarK") () (ELit (LString "TyVarK"))) (arm (PCon "EffVarK") () (ELit (LString "EffVarK"))) (arm (PCon "AuthVarK") () (ELit (LString "AuthVarK")))))))
(DData Public "LiveCell" () ((variant "LinkCell" (ConPos (TyCon "String") (TyCon "VarKind") (TyApp (TyCon "Option") (TyCon "Int")))) (variant "FreeMeta" (ConPos (TyCon "String") (TyCon "VarKind") (TyCon "Int"))) (variant "WeakVar" (ConPos (TyCon "String") (TyCon "VarKind") (TyCon "Int"))) (variant "OpenSummary" (ConPos (TyCon "String") (TyCon "Int")))) ())
(DImpl true "Eq" ((TyCon "LiveCell")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "LinkCell" (PVar "__a0") (PVar "__a1") (PVar "__a2")) (PCon "LinkCell" (PVar "__b0") (PVar "__b1") (PVar "__b2"))) () (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EVar "eq") (EVar "__a2")) (EVar "__b2")))) (arm (PTuple (PCon "FreeMeta" (PVar "__a0") (PVar "__a1") (PVar "__a2")) (PCon "FreeMeta" (PVar "__b0") (PVar "__b1") (PVar "__b2"))) () (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EVar "eq") (EVar "__a2")) (EVar "__b2")))) (arm (PTuple (PCon "WeakVar" (PVar "__a0") (PVar "__a1") (PVar "__a2")) (PCon "WeakVar" (PVar "__b0") (PVar "__b1") (PVar "__b2"))) () (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EVar "eq") (EVar "__a2")) (EVar "__b2")))) (arm (PTuple (PCon "OpenSummary" (PVar "__a0") (PVar "__a1")) (PCon "OpenSummary" (PVar "__b0") (PVar "__b1"))) () (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "eq") (EVar "__a1")) (EVar "__b1")))) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "LiveCell")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "LinkCell" (PVar "__a0") (PVar "__a1") (PVar "__a2")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "LinkCell ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a1")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a2"))))) (arm (PCon "FreeMeta" (PVar "__a0") (PVar "__a1") (PVar "__a2")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "FreeMeta ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a1")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a2"))))) (arm (PCon "WeakVar" (PVar "__a0") (PVar "__a1") (PVar "__a2")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "WeakVar ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a1")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a2"))))) (arm (PCon "OpenSummary" (PVar "__a0") (PVar "__a1")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "OpenSummary ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a1")))))))))
(DData Public "PartialAnalysis" () ((variant "PartialAnalysis" (ConNamed (field "paModule" (TyCon "String")) (field "paSchemes" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme")))))) (field "paCore" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme")))) (field "paLocals" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme") (TyApp (TyCon "Option") (TyCon "Loc"))))) (field "paSeed" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))))))) ())
(DData Public "EntryTables" () ((variant "EntryTables" (ConNamed (field "etModule" (TyCon "String")) (field "etLocals" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme") (TyApp (TyCon "Option") (TyCon "Loc"))))) (field "etSeed" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))))))) ())
(DTypeSig true "noEntryTables" (TyCon "EntryTables"))
(DFunDef false "noEntryTables" () (ERecordCreate "EntryTables" ((fa "etModule" (ELit (LString ""))) (fa "etLocals" (EListLit)) (fa "etSeed" (EListLit)))))
(DTypeSig true "partialAnalysis" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))) (TyFun (TyCon "EntryTables") (TyCon "PartialAnalysis")))))
(DFunDef false "partialAnalysis" ((PVar "schemes") (PVar "core") (PVar "tables")) (ERecordCreate "PartialAnalysis" ((fa "paModule" (EFieldAccess (EVar "tables") "etModule")) (fa "paSchemes" (EVar "schemes")) (fa "paCore" (EVar "core")) (fa "paLocals" (EFieldAccess (EVar "tables") "etLocals")) (fa "paSeed" (EFieldAccess (EVar "tables") "etSeed")))))
(DData Public "CheckedProgram" () ((variant "CheckedProgram" (ConNamed (field "cpSchemes" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme")))))) (field "cpCore" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme")))) (field "cpEvidence" (TyCon "EvTable")) (field "cpDispositions" (TyCon "DispositionTable")) (field "cpBinders" (TyCon "BinderTypeTable")) (field "cpEntryOutcome" (TyCon "EntryOutcome")) (field "cpTrees" (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))))) (field "cpWeak" (TyApp (TyCon "List") (TyCon "LiveCell"))) (field "cpManifests" (TyApp (TyCon "List") (TyCon "CapabilityManifest")))))) ())
(DData Public "EntryOutcome" () ((variant "EntryOutcome" (ConNamed (field "eoMainIsUnit" (TyCon "Bool")) (field "eoMainIsFloat" (TyCon "Bool")) (field "eoMainIsAsync" (TyCon "Bool")) (field "eoMainAsyncPayloadIsUnit" (TyCon "Bool")) (field "eoAutoPrint" (TyApp (TyCon "Option") (TyCon "EvId")))))) ())
(DTypeSig true "noEntryOutcome" (TyCon "EntryOutcome"))
(DFunDef false "noEntryOutcome" () (ERecordCreate "EntryOutcome" ((fa "eoMainIsUnit" (EVar "False")) (fa "eoMainIsFloat" (EVar "False")) (fa "eoMainIsAsync" (EVar "False")) (fa "eoMainAsyncPayloadIsUnit" (EVar "False")) (fa "eoAutoPrint" (EVar "None")))))
(DData Public "TcReport" () ((variant "TcReport" (ConNamed (field "trPartial" (TyCon "PartialAnalysis")) (field "trDiagnostics" (TyApp (TyCon "List") (TyCon "ModDiags"))) (field "trResidual" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TcDiag")))) (field "trChecked" (TyApp (TyCon "Option") (TyCon "CheckedProgram"))) (field "trEvidenceFaults" (TyApp (TyCon "List") (TyCon "EvidenceFault")))))) ())
(DData Public "ZState" () ((variant "ZState" (ConNamed (field "zTys" (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyCon "Ref") (TyCon "Tyvar")))) (field "zEffs" (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyCon "Ref") (TyCon "Effvar")))) (field "zAuths" (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyCon "Ref") (TyCon "Authvar")))) (field "zLinks" (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "EffRow")))))) ())
(DTypeSig true "emptyZonk" (TyCon "ZState"))
(DFunDef false "emptyZonk" () (ERecordCreate "ZState" ((fa "zTys" (EVar "Tip")) (fa "zEffs" (EVar "Tip")) (fa "zAuths" (EVar "Tip")) (fa "zLinks" (EVar "Tip")))))
(DTypeSig true "zonkMono" (TyFun (TyCon "ZState") (TyFun (TyCon "Mono") (TyTuple (TyCon "ZState") (TyCon "Mono")))))
(DFunDef false "zonkMono" ((PVar "z") (PCon "TVar" (PVar "cell"))) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "Link" (PVar "t")) () (EApp (EApp (EVar "zonkMono") (EVar "z")) (EVar "t"))) (arm (PCon "Unbound" (PVar "id") (PVar "lvl")) () (EMatch (EApp (EApp (EVar "IdMap.get") (EVar "id")) (EFieldAccess (EVar "z") "zTys")) (arm (PCon "Some" (PVar "c")) () (ETuple (EVar "z") (EApp (EVar "TVar") (EVar "c")))) (arm (PCon "None") () (EBlock (DoLet false false (PVar "c") (EApp (EVar "Ref") (EApp (EApp (EVar "Unbound") (EVar "id")) (EVar "lvl")))) (DoExpr (ETuple (ERecordUpdate (EVar "z") ((fa "zTys" (EApp (EApp (EApp (EVar "IdMap.set") (EVar "id")) (EVar "c")) (EFieldAccess (EVar "z") "zTys"))))) (EApp (EVar "TVar") (EVar "c"))))))))))
(DFunDef false "zonkMono" ((PVar "z") (PCon "TApp" (PVar "a") (PVar "b"))) (EBlock (DoLet false false (PTuple (PVar "z1") (PVar "a1")) (EApp (EApp (EVar "zonkMono") (EVar "z")) (EVar "a"))) (DoLet false false (PTuple (PVar "z2") (PVar "b1")) (EApp (EApp (EVar "zonkMono") (EVar "z1")) (EVar "b"))) (DoExpr (ETuple (EVar "z2") (EApp (EApp (EVar "TApp") (EVar "a1")) (EVar "b1"))))))
(DFunDef false "zonkMono" ((PVar "z") (PCon "TFun" (PVar "a") (PVar "row") (PVar "b"))) (EBlock (DoLet false false (PTuple (PVar "z1") (PVar "a1")) (EApp (EApp (EVar "zonkMono") (EVar "z")) (EVar "a"))) (DoLet false false (PTuple (PVar "z2") (PVar "row1")) (EApp (EApp (EVar "zonkRow") (EVar "z1")) (EVar "row"))) (DoLet false false (PTuple (PVar "z3") (PVar "b1")) (EApp (EApp (EVar "zonkMono") (EVar "z2")) (EVar "b"))) (DoExpr (ETuple (EVar "z3") (EApp (EApp (EApp (EVar "TFun") (EVar "a1")) (EVar "row1")) (EVar "b1"))))))
(DFunDef false "zonkMono" ((PVar "z") (PCon "TEff" (PVar "row"))) (EBlock (DoLet false false (PTuple (PVar "z1") (PVar "row1")) (EApp (EApp (EVar "zonkRow") (EVar "z")) (EVar "row"))) (DoExpr (ETuple (EVar "z1") (EApp (EVar "TEff") (EVar "row1"))))))
(DFunDef false "zonkMono" ((PVar "z") (PCon "TQual" (PVar "m") (PVar "auth"))) (EBlock (DoLet false false (PTuple (PVar "z1") (PVar "m1")) (EApp (EApp (EVar "zonkMono") (EVar "z")) (EVar "m"))) (DoLet false false (PTuple (PVar "z2") (PVar "auth1")) (EApp (EApp (EVar "zonkAuthority") (EVar "z1")) (EVar "auth"))) (DoExpr (ETuple (EVar "z2") (EApp (EApp (EVar "TQual") (EVar "m1")) (EVar "auth1"))))))
(DFunDef false "zonkMono" ((PVar "z") (PCon "TAuth" (PVar "auth"))) (EBlock (DoLet false false (PTuple (PVar "z1") (PVar "auth1")) (EApp (EApp (EVar "zonkAuthority") (EVar "z")) (EVar "auth"))) (DoExpr (ETuple (EVar "z1") (EApp (EVar "TAuth") (EVar "auth1"))))))
(DFunDef false "zonkMono" ((PVar "z") (PVar "m")) (ETuple (EVar "z") (EVar "m")))
(DTypeSig true "zonkAuthority" (TyFun (TyCon "ZState") (TyFun (TyCon "Authority") (TyTuple (TyCon "ZState") (TyCon "Authority")))))
(DFunDef false "zonkAuthority" ((PVar "z") (PCon "AVar" (PVar "cell"))) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "ALink" PWild PWild (PVar "target")) () (EApp (EApp (EVar "zonkAuthority") (EVar "z")) (EVar "target"))) (arm (PCon "AUnbound" (PVar "id") (PVar "lvl") (PVar "top") (PVar "pat") (PVar "name")) () (EMatch (EApp (EApp (EVar "IdMap.get") (EVar "id")) (EFieldAccess (EVar "z") "zAuths")) (arm (PCon "Some" (PVar "c")) () (ETuple (EVar "z") (EApp (EVar "AVar") (EVar "c")))) (arm (PCon "None") () (EBlock (DoLet false false (PVar "c") (EApp (EVar "Ref") (EApp (EApp (EApp (EApp (EApp (EVar "AUnbound") (EVar "id")) (EVar "lvl")) (EVar "top")) (EVar "pat")) (EVar "name")))) (DoExpr (ETuple (ERecordUpdate (EVar "z") ((fa "zAuths" (EApp (EApp (EApp (EVar "IdMap.set") (EVar "id")) (EVar "c")) (EFieldAccess (EVar "z") "zAuths"))))) (EApp (EVar "AVar") (EVar "c"))))))))))
(DFunDef false "zonkAuthority" ((PVar "z") (PCon "AJoin" (PVar "ms"))) (EBlock (DoLet false false (PTuple (PVar "z1") (PVar "ms1")) (EApp (EApp (EApp (EVar "mapAccumL") (EVar "zonkAuthority")) (EVar "z")) (EVar "ms"))) (DoExpr (ETuple (EVar "z1") (EApp (EVar "AJoin") (EVar "ms1"))))))
(DFunDef false "zonkAuthority" ((PVar "z") (PCon "AProduct" (PVar "axes"))) (EBlock (DoLet false false (PTuple (PVar "z1") (PVar "axes1")) (EApp (EApp (EApp (EVar "mapAccumL") (EVar "zonkAxis")) (EVar "z")) (EVar "axes"))) (DoExpr (ETuple (EVar "z1") (EApp (EVar "AProduct") (EVar "axes1"))))))
(DFunDef false "zonkAuthority" ((PVar "z") (PVar "a")) (ETuple (EVar "z") (EVar "a")))
(DTypeSig false "zonkAxis" (TyFun (TyCon "ZState") (TyFun (TyTuple (TyCon "String") (TyCon "Authority")) (TyTuple (TyCon "ZState") (TyTuple (TyCon "String") (TyCon "Authority"))))))
(DFunDef false "zonkAxis" ((PVar "z") (PTuple (PVar "name") (PVar "a"))) (EBlock (DoLet false false (PTuple (PVar "z1") (PVar "a1")) (EApp (EApp (EVar "zonkAuthority") (EVar "z")) (EVar "a"))) (DoExpr (ETuple (EVar "z1") (ETuple (EVar "name") (EVar "a1"))))))
(DTypeSig false "zonkAtom" (TyFun (TyCon "ZState") (TyFun (TyCon "Atom") (TyTuple (TyCon "ZState") (TyCon "Atom")))))
(DFunDef false "zonkAtom" ((PVar "z") (PCon "Atom" (PVar "lbl") (PVar "auth"))) (EBlock (DoLet false false (PTuple (PVar "z1") (PVar "auth1")) (EApp (EApp (EVar "zonkAuthority") (EVar "z")) (EVar "auth"))) (DoExpr (ETuple (EVar "z1") (EApp (EApp (EVar "Atom") (EVar "lbl")) (EVar "auth1"))))))
(DTypeSig true "zonkRow" (TyFun (TyCon "ZState") (TyFun (TyCon "EffRow") (TyTuple (TyCon "ZState") (TyCon "EffRow")))))
(DFunDef false "zonkRow" ((PVar "z") (PCon "EffRow" (PVar "atoms") (PVar "tail"))) (EBlock (DoLet false false (PTuple (PVar "z1") (PVar "atoms1")) (EApp (EApp (EApp (EVar "mapAccumL") (EVar "zonkAtom")) (EVar "z")) (EVar "atoms"))) (DoExpr (EMatch (EVar "tail") (arm (PCon "None") () (ETuple (EVar "z1") (EApp (EApp (EVar "EffRow") (EVar "atoms1")) (EVar "None")))) (arm (PCon "Some" (PVar "cell")) () (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "ELink" (PVar "id") (PVar "row")) () (EBlock (DoLet false false (PTuple (PVar "z2") (PCon "EffRow" (PVar "more") (PVar "rest"))) (EApp (EApp (EApp (EVar "linkedRow") (EVar "z1")) (EVar "id")) (EVar "row"))) (DoExpr (ETuple (EVar "z2") (EApp (EApp (EVar "EffRow") (EBinOp "++" (EVar "atoms1") (EVar "more"))) (EVar "rest")))))) (arm PWild () (EBlock (DoLet false false (PTuple (PVar "z2") (PVar "c")) (EApp (EApp (EVar "zonkEffCell") (EVar "z1")) (EVar "cell"))) (DoExpr (ETuple (EVar "z2") (EApp (EApp (EVar "EffRow") (EVar "atoms1")) (EApp (EVar "Some") (EVar "c")))))))))))))
(DTypeSig false "linkedRow" (TyFun (TyCon "ZState") (TyFun (TyCon "Int") (TyFun (TyCon "EffRow") (TyTuple (TyCon "ZState") (TyCon "EffRow"))))))
(DFunDef false "linkedRow" ((PVar "z") (PVar "id") (PVar "row")) (EMatch (EApp (EApp (EVar "IdMap.get") (EVar "id")) (EFieldAccess (EVar "z") "zLinks")) (arm (PCon "Some" (PVar "r")) () (ETuple (EVar "z") (EVar "r"))) (arm (PCon "None") () (EBlock (DoLet false false (PTuple (PVar "z1") (PVar "r")) (EApp (EApp (EVar "zonkRow") (EVar "z")) (EVar "row"))) (DoExpr (ETuple (ERecordUpdate (EVar "z1") ((fa "zLinks" (EApp (EApp (EApp (EVar "IdMap.set") (EVar "id")) (EVar "r")) (EFieldAccess (EVar "z1") "zLinks"))))) (EVar "r")))))))
(DTypeSig false "zonkEffCell" (TyFun (TyCon "ZState") (TyFun (TyApp (TyCon "Ref") (TyCon "Effvar")) (TyTuple (TyCon "ZState") (TyApp (TyCon "Ref") (TyCon "Effvar"))))))
(DFunDef false "zonkEffCell" ((PVar "z") (PVar "cell")) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "EUnbound" (PVar "id") (PVar "lvl")) () (EApp (EApp (EApp (EVar "memoEff") (EVar "z")) (EVar "id")) (EApp (EApp (EVar "EUnbound") (EVar "id")) (EVar "lvl")))) (arm (PCon "ESummary" (PVar "id") (PVar "a") (PVar "b")) () (EApp (EApp (EApp (EVar "memoEff") (EVar "z")) (EVar "id")) (EApp (EApp (EApp (EVar "ESummary") (EVar "id")) (EVar "a")) (EVar "b")))) (arm (PCon "EJoin" (PVar "id") (PVar "lvl") (PVar "members")) () (EMatch (EApp (EApp (EVar "IdMap.get") (EVar "id")) (EFieldAccess (EVar "z") "zEffs")) (arm (PCon "Some" (PVar "c")) () (ETuple (EVar "z") (EVar "c"))) (arm (PCon "None") () (EBlock (DoLet false false (PTuple (PVar "z1") (PVar "ms")) (EApp (EApp (EApp (EVar "mapAccumL") (EVar "zonkEffCell")) (EVar "z")) (EVar "members"))) (DoLet false false (PVar "c") (EApp (EVar "Ref") (EApp (EApp (EApp (EVar "EJoin") (EVar "id")) (EVar "lvl")) (EVar "ms")))) (DoExpr (ETuple (ERecordUpdate (EVar "z1") ((fa "zEffs" (EApp (EApp (EApp (EVar "IdMap.set") (EVar "id")) (EVar "c")) (EFieldAccess (EVar "z1") "zEffs"))))) (EVar "c"))))))) (arm (PCon "ELink" (PVar "id") (PVar "row")) () (EMatch (EApp (EApp (EVar "IdMap.get") (EVar "id")) (EFieldAccess (EVar "z") "zEffs")) (arm (PCon "Some" (PVar "c")) () (ETuple (EVar "z") (EVar "c"))) (arm (PCon "None") () (EBlock (DoLet false false (PTuple (PVar "z1") (PVar "r")) (EApp (EApp (EApp (EVar "linkedRow") (EVar "z")) (EVar "id")) (EVar "row"))) (DoExpr (EMatch (EVar "r") (arm (PCon "EffRow" (PList) (PCon "Some" (PVar "t"))) () (ETuple (ERecordUpdate (EVar "z1") ((fa "zEffs" (EApp (EApp (EApp (EVar "IdMap.set") (EVar "id")) (EVar "t")) (EFieldAccess (EVar "z1") "zEffs"))))) (EVar "t"))) (arm PWild () (EBlock (DoLet false false (PVar "c") (EApp (EVar "Ref") (EApp (EApp (EVar "ELink") (EVar "id")) (EVar "r")))) (DoExpr (ETuple (ERecordUpdate (EVar "z1") ((fa "zEffs" (EApp (EApp (EApp (EVar "IdMap.set") (EVar "id")) (EVar "c")) (EFieldAccess (EVar "z1") "zEffs"))))) (EVar "c")))))))))))))
(DTypeSig false "memoEff" (TyFun (TyCon "ZState") (TyFun (TyCon "Int") (TyFun (TyCon "Effvar") (TyTuple (TyCon "ZState") (TyApp (TyCon "Ref") (TyCon "Effvar")))))))
(DFunDef false "memoEff" ((PVar "z") (PVar "id") (PVar "v")) (EMatch (EApp (EApp (EVar "IdMap.get") (EVar "id")) (EFieldAccess (EVar "z") "zEffs")) (arm (PCon "Some" (PVar "c")) () (ETuple (EVar "z") (EVar "c"))) (arm (PCon "None") () (EBlock (DoLet false false (PVar "c") (EApp (EVar "Ref") (EVar "v"))) (DoExpr (ETuple (ERecordUpdate (EVar "z") ((fa "zEffs" (EApp (EApp (EApp (EVar "IdMap.set") (EVar "id")) (EVar "c")) (EFieldAccess (EVar "z") "zEffs"))))) (EVar "c")))))))
(DTypeSig true "zonkVecObl" (TyFun (TyCon "ZState") (TyFun (TyCon "VecObl") (TyTuple (TyCon "ZState") (TyCon "VecObl")))))
(DFunDef false "zonkVecObl" ((PVar "z") (PRec "VecObl" ((rf "voIface" (PVar "iface")) (rf "voIds" (PVar "ids")) (rf "voArgs" (PVar "args"))) false)) (EBlock (DoLet false false (PTuple (PVar "z1") (PVar "args1")) (EApp (EApp (EApp (EVar "mapAccumL") (EVar "zonkMono")) (EVar "z")) (EVar "args"))) (DoExpr (ETuple (EVar "z1") (ERecordCreate "VecObl" ((fa "voIface" (EVar "iface")) (fa "voIds" (EVar "ids")) (fa "voArgs" (EVar "args1"))))))))
(DTypeSig false "zonkResidual" (TyFun (TyCon "ZState") (TyFun (TyCon "AuthResidual") (TyTuple (TyCon "ZState") (TyCon "AuthResidual")))))
(DFunDef false "zonkResidual" ((PVar "z") (PRec "AuthResidual" ((rf "arLower" (PVar "lo")) (rf "arUpper" (PVar "hi")) (rf "arExact" (PVar "ex"))) false)) (EBlock (DoLet false false (PTuple (PVar "z1") (PVar "lo1")) (EApp (EApp (EVar "zonkAuthority") (EVar "z")) (EVar "lo"))) (DoLet false false (PTuple (PVar "z2") (PVar "hi1")) (EApp (EApp (EVar "zonkAuthority") (EVar "z1")) (EVar "hi"))) (DoExpr (ETuple (EVar "z2") (ERecordCreate "AuthResidual" ((fa "arLower" (EVar "lo1")) (fa "arUpper" (EVar "hi1")) (fa "arExact" (EVar "ex"))))))))
(DTypeSig true "zonkScheme" (TyFun (TyCon "ZState") (TyFun (TyCon "Scheme") (TyTuple (TyCon "ZState") (TyCon "Scheme")))))
(DFunDef false "zonkScheme" ((PVar "z") (PCon "Forall" (PVar "ids") (PVar "effIds") (PVar "authIds") (PVar "residuals") (PVar "row") (PVar "t"))) (EBlock (DoLet false false (PTuple (PVar "z1") (PVar "residuals1")) (EApp (EApp (EApp (EVar "mapAccumL") (EVar "zonkResidual")) (EVar "z")) (EVar "residuals"))) (DoLet false false (PTuple (PVar "z2") (PVar "row1")) (EApp (EApp (EVar "zonkRow") (EVar "z1")) (EVar "row"))) (DoLet false false (PTuple (PVar "z3") (PVar "t1")) (EApp (EApp (EVar "zonkMono") (EVar "z2")) (EVar "t"))) (DoExpr (ETuple (EVar "z3") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Forall") (EVar "ids")) (EVar "effIds")) (EVar "authIds")) (EVar "residuals1")) (EVar "row1")) (EVar "t1"))))))
(DTypeSig true "freezePub" (TyFun (TyCon "Scheme") (TyFun (TyApp (TyCon "List") (TyCon "VecObl")) (TyCon "PubScheme"))))
(DFunDef false "freezePub" ((PVar "s") (PVar "ctx")) (EBlock (DoLet false false (PTuple (PVar "z1") (PVar "s1")) (EApp (EApp (EVar "zonkScheme") (EVar "emptyZonk")) (EVar "s"))) (DoLet false false (PTuple PWild (PVar "ctx1")) (EApp (EApp (EApp (EVar "mapAccumL") (EVar "zonkVecObl")) (EVar "z1")) (EVar "ctx"))) (DoExpr (ERecordCreate "PubScheme" ((fa "psScheme" (EVar "s1")) (fa "psContext" (EVar "ctx1")))))))
(DTypeSig true "freezeRows" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme")))))
(DFunDef false "freezeRows" () (EApp (EVar "map") (ELam ((PVar "b")) (ETuple (EApp (EVar "fst") (EVar "b")) (EApp (EApp (EVar "freezePub") (EFieldAccess (EApp (EVar "snd") (EVar "b")) "psScheme")) (EFieldAccess (EApp (EVar "snd") (EVar "b")) "psContext"))))))
(DTypeSig true "freezeModDiags" (TyFun (TyCon "ModDiags") (TyCon "ModDiags")))
(DFunDef false "freezeModDiags" ((PTuple (PVar "mid") (PTuple (PVar "schemes") (PVar "errs") (PVar "warns")))) (ETuple (EVar "mid") (ETuple (EApp (EVar "freezeRows") (EVar "schemes")) (EVar "errs") (EVar "warns"))))
(DTypeSig true "freezeNewest" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "ModDiags")) (TyApp (TyCon "List") (TyCon "ModDiags")))))
(DFunDef false "freezeNewest" ((PVar "n") (PVar "rows")) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (EVar "rows") (EIf (EVar "otherwise") (EMatch (EVar "rows") (arm (PList) () (EListLit)) (arm (PCons (PVar "m") (PVar "rest")) () (EBinOp "::" (EApp (EVar "freezeModDiags") (EVar "m")) (EApp (EApp (EVar "freezeNewest") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "rest"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "graphReport" (TyFun (TyApp (TyCon "List") (TyCon "ModDiags")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TcDiag"))) (TyFun (TyFun (TyCon "Unit") (TyCon "EvTable")) (TyFun (TyCon "DispositionTable") (TyFun (TyCon "BinderTypeTable") (TyFun (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))) (TyFun (TyCon "EntryTables") (TyCon "TcReport"))))))))))
(DFunDef false "graphReport" ((PVar "perMod") (PVar "core") (PVar "residual") (PVar "evidence") (PVar "dispositions") (PVar "binders") (PVar "trees") (PVar "tables")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphReportWithOutcome") (EVar "noEntryOutcome")) (EListLit)) (EListLit)) (EVar "perMod")) (EVar "core")) (EVar "residual")) (EVar "evidence")) (EVar "dispositions")) (EVar "binders")) (EVar "trees")) (EVar "tables")))
(DTypeSig true "graphReportWithOutcome" (TyFun (TyCon "EntryOutcome") (TyFun (TyApp (TyCon "List") (TyCon "CapabilityManifest")) (TyFun (TyApp (TyCon "List") (TyCon "TcDiag")) (TyFun (TyApp (TyCon "List") (TyCon "ModDiags")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TcDiag"))) (TyFun (TyFun (TyCon "Unit") (TyCon "EvTable")) (TyFun (TyCon "DispositionTable") (TyFun (TyCon "BinderTypeTable") (TyFun (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))) (TyFun (TyCon "EntryTables") (TyCon "TcReport")))))))))))))
(DFunDef false "graphReportWithOutcome" ((PVar "outcome") (PVar "manifests") (PVar "manifestDiags") (PVar "perMod") (PVar "core") (PVar "residual") (PVar "evidence") (PVar "dispositions") (PVar "binders") (PVar "trees") (PVar "tables")) (EBlock (DoLet false false (PVar "schemes") (EApp (EApp (EVar "map") (ELam ((PVar "m")) (ETuple (EApp (EVar "fst") (EVar "m")) (EApp (EVar "modSchemes") (EApp (EVar "snd") (EVar "m")))))) (EVar "perMod"))) (DoLet false false (PVar "cells") (EApp (EVar "graphCells") (EBinOp "::" (EVar "core") (EApp (EApp (EVar "map") (EVar "snd")) (EVar "schemes"))))) (DoLet false false (PVar "judged") (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EVar "isEmpty") (EVar "residual")) (EApp (EVar "isEmpty") (EVar "manifestDiags"))) (EApp (EVar "noModErrors") (EVar "perMod"))) (EApp (EApp (EVar "all") (EVar "isWeak")) (EVar "cells"))) (EBlock (DoLet false false (PVar "table") (EApp (EVar "evidence") (ELit LUnit))) (DoExpr (EApp (EVar "Some") (ETuple (EVar "table") (EApp (EApp (EVar "evidenceFaults") (EVar "trees")) (EVar "table")))))) (EVar "None"))) (DoLet false false (PVar "checked") (EMatch (EVar "judged") (arm (PCon "Some" (PTuple (PVar "table") (PList))) () (EApp (EVar "Some") (ERecordCreate "CheckedProgram" ((fa "cpSchemes" (EVar "schemes")) (fa "cpCore" (EVar "core")) (fa "cpEvidence" (EVar "table")) (fa "cpDispositions" (EVar "dispositions")) (fa "cpBinders" (EVar "binders")) (fa "cpEntryOutcome" (EVar "outcome")) (fa "cpTrees" (EVar "trees")) (fa "cpWeak" (EVar "cells")) (fa "cpManifests" (EVar "manifests")))))) (arm PWild () (EVar "None")))) (DoExpr (ERecordCreate "TcReport" ((fa "trPartial" (EApp (EApp (EApp (EVar "partialAnalysis") (EVar "schemes")) (EVar "core")) (EVar "tables"))) (fa "trDiagnostics" (EVar "perMod")) (fa "trResidual" (EBinOp "++" (EVar "residual") (EApp (EApp (EVar "map") (ELam ((PVar "d")) (ETuple (EFieldAccess (EVar "tables") "etModule") (EVar "d")))) (EVar "manifestDiags")))) (fa "trChecked" (EVar "checked")) (fa "trEvidenceFaults" (EMatch (EVar "judged") (arm (PCon "Some" (PTuple PWild (PVar "faults"))) () (EVar "faults")) (arm (PCon "None") () (EListLit)))))))))
(DTypeSig true "graphCells" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme")))) (TyApp (TyCon "List") (TyCon "LiveCell"))))
(DFunDef false "graphCells" ((PList)) (EListLit))
(DFunDef false "graphCells" ((PCons (PVar "rows") (PVar "rest"))) (EApp (EApp (EVar "rowCells") (EVar "rows")) (EApp (EVar "graphCells") (EVar "rest"))))
(DTypeSig false "rowCells" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))) (TyFun (TyApp (TyCon "List") (TyCon "LiveCell")) (TyApp (TyCon "List") (TyCon "LiveCell")))))
(DFunDef false "rowCells" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "rowCells" ((PCons (PTuple (PVar "name") (PVar "p")) (PVar "rest")) (PVar "acc")) (EBinOp "++" (EApp (EVar "atGraphEnd") (EApp (EApp (EVar "liveCells") (EVar "name")) (EVar "p"))) (EApp (EApp (EVar "rowCells") (EVar "rest")) (EVar "acc"))))
(DTypeSig false "modSchemes" (TyFun (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))) (TyApp (TyCon "List") (TyCon "TcDiag")) (TyApp (TyCon "List") (TyCon "TcDiag"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme")))))
(DFunDef false "modSchemes" ((PTuple (PVar "s") PWild PWild)) (EVar "s"))
(DTypeSig false "noModErrors" (TyFun (TyApp (TyCon "List") (TyCon "ModDiags")) (TyCon "Bool")))
(DFunDef false "noModErrors" ((PList)) (EVar "True"))
(DFunDef false "noModErrors" ((PCons (PTuple PWild (PTuple PWild (PList) PWild)) (PVar "rest"))) (EApp (EVar "noModErrors") (EVar "rest")))
(DFunDef false "noModErrors" (PWild) (EVar "False"))
(DTypeSig false "isWeak" (TyFun (TyCon "LiveCell") (TyCon "Bool")))
(DFunDef false "isWeak" ((PCon "WeakVar" PWild PWild PWild)) (EVar "True"))
(DFunDef false "isWeak" (PWild) (EVar "False"))
(DData Private "Walk" () ((variant "Walk" (ConPos (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyApp (TyCon "List") (TyCon "LiveCell"))))) ())
(DTypeSig true "liveCells" (TyFun (TyCon "String") (TyFun (TyCon "PubScheme") (TyApp (TyCon "List") (TyCon "LiveCell")))))
(DFunDef false "liveCells" ((PVar "name") (PRec "PubScheme" ((rf "psScheme" (PCon "Forall" (PVar "ids") (PVar "effIds") (PVar "authIds") (PVar "residuals") (PVar "row") (PVar "t"))) (rf "psContext" (PVar "ctx"))) false)) (EBlock (DoLet false false (PVar "w0") (EApp (EApp (EVar "Walk") (EVar "Tip")) (EListLit))) (DoLet false false (PVar "w1") (EApp (EApp (EApp (EApp (EVar "walkResiduals") (EVar "name")) (EVar "authIds")) (EVar "residuals")) (EVar "w0"))) (DoLet false false (PVar "w2") (EApp (EApp (EApp (EApp (EApp (EVar "walkRow") (EVar "name")) (EVar "effIds")) (EVar "authIds")) (EVar "row")) (EVar "w1"))) (DoLet false false (PVar "w3") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "walkMono") (EVar "name")) (EVar "ids")) (EVar "effIds")) (EVar "authIds")) (EVar "t")) (EVar "w2"))) (DoLet false false (PVar "w4") (EApp (EApp (EApp (EVar "foldWalk") (EApp (EApp (EApp (EApp (EVar "walkObl") (EVar "name")) (EVar "ids")) (EVar "effIds")) (EVar "authIds"))) (EVar "ctx")) (EVar "w3"))) (DoExpr (EMatch (EVar "w4") (arm (PCon "Walk" PWild (PVar "found")) () (EApp (EVar "nub") (EApp (EVar "reverse") (EVar "found"))))))))
(DTypeSig true "atGraphEnd" (TyFun (TyApp (TyCon "List") (TyCon "LiveCell")) (TyApp (TyCon "List") (TyCon "LiveCell"))))
(DFunDef false "atGraphEnd" () (EApp (EVar "map") (EVar "toWeak")))
(DTypeSig false "toWeak" (TyFun (TyCon "LiveCell") (TyCon "LiveCell")))
(DFunDef false "toWeak" ((PCon "FreeMeta" (PVar "n") (PVar "k") (PVar "i"))) (EApp (EApp (EApp (EVar "WeakVar") (EVar "n")) (EVar "k")) (EVar "i")))
(DFunDef false "toWeak" ((PVar "c")) (EVar "c"))
(DTypeSig false "foldWalk" (TyFun (TyFun (TyVar "a") (TyFun (TyCon "Walk") (TyCon "Walk"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyFun (TyCon "Walk") (TyCon "Walk")))))
(DFunDef false "foldWalk" (PWild (PList) (PVar "w")) (EVar "w"))
(DFunDef false "foldWalk" ((PVar "f") (PCons (PVar "x") (PVar "xs")) (PVar "w")) (EApp (EApp (EApp (EVar "foldWalk") (EVar "f")) (EVar "xs")) (EApp (EApp (EVar "f") (EVar "x")) (EVar "w"))))
(DTypeSig false "push" (TyFun (TyCon "LiveCell") (TyFun (TyCon "Walk") (TyCon "Walk"))))
(DFunDef false "push" ((PVar "c") (PCon "Walk" (PVar "seen") (PVar "found"))) (EApp (EApp (EVar "Walk") (EVar "seen")) (EBinOp "::" (EVar "c") (EVar "found"))))
(DTypeSig false "hasId" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Bool"))))
(DFunDef false "hasId" (PWild (PList)) (EVar "False"))
(DFunDef false "hasId" ((PVar "x") (PCons (PVar "y") (PVar "ys"))) (EBinOp "||" (EBinOp "==" (EVar "x") (EVar "y")) (EApp (EApp (EVar "hasId") (EVar "x")) (EVar "ys"))))
(DTypeSig false "walkObl" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "VecObl") (TyFun (TyCon "Walk") (TyCon "Walk"))))))))
(DFunDef false "walkObl" ((PVar "name") (PVar "ids") (PVar "effIds") (PVar "authIds") (PRec "VecObl" ((rf "voArgs" (PVar "args"))) false) (PVar "w")) (EApp (EApp (EApp (EVar "foldWalk") (EApp (EApp (EApp (EApp (EVar "walkMono") (EVar "name")) (EVar "ids")) (EVar "effIds")) (EVar "authIds"))) (EVar "args")) (EVar "w")))
(DTypeSig false "walkResiduals" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "AuthResidual")) (TyFun (TyCon "Walk") (TyCon "Walk"))))))
(DFunDef false "walkResiduals" ((PVar "name") (PVar "authIds") (PVar "rs") (PVar "w")) (EApp (EApp (EApp (EVar "foldWalk") (ELam ((PVar "r") (PVar "acc")) (EMatch (EVar "r") (arm (PRec "AuthResidual" ((rf "arLower" (PVar "lo")) (rf "arUpper" (PVar "hi"))) false) () (EApp (EApp (EApp (EApp (EVar "walkAuth") (EVar "name")) (EVar "authIds")) (EVar "hi")) (EApp (EApp (EApp (EApp (EVar "walkAuth") (EVar "name")) (EVar "authIds")) (EVar "lo")) (EVar "acc"))))))) (EVar "rs")) (EVar "w")))
(DTypeSig false "walkMono" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Mono") (TyFun (TyCon "Walk") (TyCon "Walk"))))))))
(DFunDef false "walkMono" ((PVar "name") (PVar "ids") (PVar "effIds") (PVar "authIds") (PCon "TVar" (PVar "cell")) (PVar "w")) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "Link" PWild) () (EApp (EApp (EVar "push") (EApp (EApp (EApp (EVar "LinkCell") (EVar "name")) (EVar "TyVarK")) (EVar "None"))) (EVar "w"))) (arm (PCon "Unbound" (PVar "id") PWild) () (EIf (EApp (EApp (EVar "hasId") (EVar "id")) (EVar "ids")) (EVar "w") (EApp (EApp (EVar "push") (EApp (EApp (EApp (EVar "FreeMeta") (EVar "name")) (EVar "TyVarK")) (EVar "id"))) (EVar "w"))))))
(DFunDef false "walkMono" ((PVar "name") (PVar "ids") (PVar "effIds") (PVar "authIds") (PCon "TApp" (PVar "a") (PVar "b")) (PVar "w")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "walkMono") (EVar "name")) (EVar "ids")) (EVar "effIds")) (EVar "authIds")) (EVar "b")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "walkMono") (EVar "name")) (EVar "ids")) (EVar "effIds")) (EVar "authIds")) (EVar "a")) (EVar "w"))))
(DFunDef false "walkMono" ((PVar "name") (PVar "ids") (PVar "effIds") (PVar "authIds") (PCon "TFun" (PVar "a") (PVar "row") (PVar "b")) (PVar "w")) (EBlock (DoLet false false (PVar "w1") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "walkMono") (EVar "name")) (EVar "ids")) (EVar "effIds")) (EVar "authIds")) (EVar "a")) (EVar "w"))) (DoLet false false (PVar "w2") (EApp (EApp (EApp (EApp (EApp (EVar "walkRow") (EVar "name")) (EVar "effIds")) (EVar "authIds")) (EVar "row")) (EVar "w1"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "walkMono") (EVar "name")) (EVar "ids")) (EVar "effIds")) (EVar "authIds")) (EVar "b")) (EVar "w2")))))
(DFunDef false "walkMono" ((PVar "name") PWild (PVar "effIds") (PVar "authIds") (PCon "TEff" (PVar "row")) (PVar "w")) (EApp (EApp (EApp (EApp (EApp (EVar "walkRow") (EVar "name")) (EVar "effIds")) (EVar "authIds")) (EVar "row")) (EVar "w")))
(DFunDef false "walkMono" ((PVar "name") (PVar "ids") (PVar "effIds") (PVar "authIds") (PCon "TQual" (PVar "inner") (PVar "auth")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkAuth") (EVar "name")) (EVar "authIds")) (EVar "auth")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "walkMono") (EVar "name")) (EVar "ids")) (EVar "effIds")) (EVar "authIds")) (EVar "inner")) (EVar "w"))))
(DFunDef false "walkMono" ((PVar "name") PWild PWild (PVar "authIds") (PCon "TAuth" (PVar "auth")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkAuth") (EVar "name")) (EVar "authIds")) (EVar "auth")) (EVar "w")))
(DFunDef false "walkMono" (PWild PWild PWild PWild PWild (PVar "w")) (EVar "w"))
(DTypeSig false "walkAuth" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Authority") (TyFun (TyCon "Walk") (TyCon "Walk"))))))
(DFunDef false "walkAuth" ((PVar "name") (PVar "authIds") (PCon "AVar" (PVar "cell")) (PVar "w")) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "ALink" (PVar "id") PWild PWild) () (EApp (EApp (EVar "push") (EApp (EApp (EApp (EVar "LinkCell") (EVar "name")) (EVar "AuthVarK")) (EApp (EVar "Some") (EVar "id")))) (EVar "w"))) (arm (PCon "AUnbound" (PVar "id") PWild PWild PWild PWild) () (EIf (EApp (EApp (EVar "hasId") (EVar "id")) (EVar "authIds")) (EVar "w") (EApp (EApp (EVar "push") (EApp (EApp (EApp (EVar "FreeMeta") (EVar "name")) (EVar "AuthVarK")) (EVar "id"))) (EVar "w"))))))
(DFunDef false "walkAuth" ((PVar "name") (PVar "authIds") (PCon "AJoin" (PVar "ms")) (PVar "w")) (EApp (EApp (EApp (EVar "foldWalk") (EApp (EApp (EVar "walkAuth") (EVar "name")) (EVar "authIds"))) (EVar "ms")) (EVar "w")))
(DFunDef false "walkAuth" ((PVar "name") (PVar "authIds") (PCon "AProduct" (PVar "axes")) (PVar "w")) (EApp (EApp (EApp (EVar "foldWalk") (ELam ((PVar "axis") (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "walkAuth") (EVar "name")) (EVar "authIds")) (EApp (EVar "snd") (EVar "axis"))) (EVar "acc")))) (EVar "axes")) (EVar "w")))
(DFunDef false "walkAuth" (PWild PWild PWild (PVar "w")) (EVar "w"))
(DTypeSig false "walkRow" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "EffRow") (TyFun (TyCon "Walk") (TyCon "Walk")))))))
(DFunDef false "walkRow" ((PVar "name") (PVar "effIds") (PVar "authIds") (PCon "EffRow" (PVar "atoms") (PVar "tail")) (PVar "w")) (EBlock (DoLet false false (PVar "w1") (EApp (EApp (EApp (EVar "foldWalk") (ELam ((PVar "atom") (PVar "acc")) (EMatch (EVar "atom") (arm (PCon "Atom" PWild (PVar "auth")) () (EApp (EApp (EApp (EApp (EVar "walkAuth") (EVar "name")) (EVar "authIds")) (EVar "auth")) (EVar "acc")))))) (EVar "atoms")) (EVar "w"))) (DoExpr (EMatch (EVar "tail") (arm (PCon "None") () (EVar "w1")) (arm (PCon "Some" (PVar "cell")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "walkEffCell") (EVar "name")) (EVar "effIds")) (EVar "authIds")) (EVar "False")) (EVar "cell")) (EVar "w1")))))))
(DTypeSig false "walkEffCell" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "Ref") (TyCon "Effvar")) (TyFun (TyCon "Walk") (TyCon "Walk"))))))))
(DFunDef false "walkEffCell" ((PVar "name") (PVar "effIds") (PVar "authIds") (PVar "member") (PVar "cell") (PAs "w" (PCon "Walk" (PVar "seen") (PVar "found")))) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "EUnbound" (PVar "id") PWild) () (EIf (EApp (EApp (EVar "hasId") (EVar "id")) (EVar "effIds")) (EVar "w") (EApp (EApp (EVar "push") (EApp (EApp (EApp (EVar "FreeMeta") (EVar "name")) (EVar "EffVarK")) (EVar "id"))) (EVar "w")))) (arm (PCon "ESummary" (PVar "id") PWild PWild) () (EApp (EApp (EVar "push") (EApp (EApp (EVar "OpenSummary") (EVar "name")) (EVar "id"))) (EVar "w"))) (arm (PCon "ELink" (PVar "id") (PVar "row")) () (EIf (EApp (EApp (EVar "IdMap.has") (EVar "id")) (EVar "seen")) (EVar "w") (EBlock (DoLet false false (PVar "w1") (EApp (EApp (EVar "Walk") (EApp (EApp (EApp (EVar "IdMap.set") (EVar "id")) (ELit LUnit)) (EVar "seen"))) (EVar "found"))) (DoLet false false (PVar "w2") (EIf (EVar "member") (EVar "w1") (EApp (EApp (EVar "push") (EApp (EApp (EApp (EVar "LinkCell") (EVar "name")) (EVar "EffVarK")) (EApp (EVar "Some") (EVar "id")))) (EVar "w1")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "walkRow") (EVar "name")) (EVar "effIds")) (EVar "authIds")) (EVar "row")) (EVar "w2")))))) (arm (PCon "EJoin" (PVar "id") PWild (PVar "members")) () (EIf (EApp (EApp (EVar "IdMap.has") (EVar "id")) (EVar "seen")) (EVar "w") (EApp (EApp (EApp (EVar "foldWalk") (EApp (EApp (EApp (EApp (EVar "walkEffCell") (EVar "name")) (EVar "effIds")) (EVar "authIds")) (EVar "True"))) (EVar "members")) (EApp (EApp (EVar "Walk") (EApp (EApp (EApp (EVar "IdMap.set") (EVar "id")) (ELit LUnit)) (EVar "seen"))) (EVar "found")))))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" false) (mem "Decl" false) (mem "EvTable" false) (mem "EvId" false))))
(DUse false (UseGroup ("types" "repr") ((mem "Mono" true) (mem "Tyvar" true) (mem "Scheme" true) (mem "AuthResidual" true) (mem "VecObl" true) (mem "ppSchemeCon" false))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "EffRow" true) (mem "Effvar" true) (mem "Atom" true))))
(DUse false (UseGroup ("types" "effect_authority") ((mem "Authority" true) (mem "Authvar" true))))
(DUse false (UseGroup ("types" "disposition") ((mem "DispositionTable" false))))
(DUse false (UseGroup ("types" "runtime_types") ((mem "BinderTypeTable" false))))
(DUse false (UseGroup ("types" "evidence_coverage") ((mem "EvidenceFault" false) (mem "evidenceFaults" false))))
(DUse false (UseAlias ("map") "IdMap"))
(DUse false (UseGroup ("map") ((mem "Map" true))))
(DUse false (UseGroup ("list") ((mem "nub" false) (mem "reverse" false) (mem "mapAccumL" false) (mem "last" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omLookup" false))))
(DUse false (UseGroup ("types" "capability_manifest") ((mem "EntryKey" true) (mem "ManifestRequest" true) (mem "ManifestSelector" true) (mem "InvocationProtocol" true) (mem "CapabilityManifest" false) (mem "ManifestDefect" true))))
(DUse false (UseGroup ("types" "effect_domain") ((mem "Param" false))))
(DUse false (UseGroup ("types" "effect_invocation") ((mem "InvocationOps" false))))
(DUse false (UseGroup ("types" "manifest_publish") ((mem "InvocationOwner" true) (mem "ManifestEntryInput" true) (mem "publishManifests" false))))
(DData Public "TcDiag" () ((variant "TcDiag" (ConPos (TyCon "String") (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "Option") (TyTuple (TyCon "Loc") (TyCon "String")))))) ())
(DTypeSig true "tcCode" (TyFun (TyCon "TcDiag") (TyCon "String")))
(DFunDef false "tcCode" ((PCon "TcDiag" (PVar "c") PWild PWild PWild PWild PWild)) (EVar "c"))
(DTypeSig true "tcMsg" (TyFun (TyCon "TcDiag") (TyCon "String")))
(DFunDef false "tcMsg" ((PCon "TcDiag" PWild PWild PWild (PVar "m") PWild PWild)) (EVar "m"))
(DTypeSig true "tcLoc" (TyFun (TyCon "TcDiag") (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "tcLoc" ((PCon "TcDiag" PWild PWild (PVar "l") PWild PWild PWild)) (EVar "l"))
(DTypeAlias true "ModDiags" () (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))) (TyApp (TyCon "List") (TyCon "TcDiag")) (TyApp (TyCon "List") (TyCon "TcDiag")))))
(DData Public "PubScheme" () ((variant "PubScheme" (ConNamed (field "psScheme" (TyCon "Scheme")) (field "psContext" (TyApp (TyCon "List") (TyCon "VecObl")))))) ())
(DTypeSig true "ppPubScheme" (TyFun (TyCon "PubScheme") (TyCon "String")))
(DFunDef false "ppPubScheme" ((PVar "p")) (EApp (EApp (EVar "ppSchemeCon") (EFieldAccess (EVar "p") "psContext")) (EFieldAccess (EVar "p") "psScheme")))
(DTypeSig true "pubSchemes" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme")))))
(DFunDef false "pubSchemes" () (EApp (EMethodRef "map") (ELam ((PVar "b")) (ETuple (EApp (EVar "fst") (EVar "b")) (EFieldAccess (EApp (EVar "snd") (EVar "b")) "psScheme")))))
(DTypeSig true "publishedEntrySchemes" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a"))))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a")))))
(DFunDef false "publishedEntrySchemes" ((PVar "modules")) (EApp (EApp (EApp (EVar "option") (EListLit)) (EVar "snd")) (EApp (EVar "last") (EVar "modules"))))
(DTypeSig true "publishCore" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "VecObl"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))))))
(DFunDef false "publishCore" ((PVar "contexts")) (EApp (EVar "publishWithContexts") (ELam ((PVar "name")) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "name")) (EVar "contexts"))))))
(DTypeSig true "publishWithContexts" (TyFun (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "VecObl"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))))))
(DFunDef false "publishWithContexts" ((PVar "context")) (EApp (EMethodRef "map") (ELam ((PVar "b")) (ETuple (EApp (EVar "fst") (EVar "b")) (ERecordCreate "PubScheme" ((fa "psScheme" (EApp (EVar "snd") (EVar "b"))) (fa "psContext" (EApp (EVar "context") (EApp (EVar "fst") (EVar "b"))))))))))
(DTypeSig true "publishedCore" (TyFun (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme")))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "VecObl"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme")))))))
(DFunDef false "publishedCore" ((PCon "Some" (PVar "rows")) PWild PWild) (EVar "rows"))
(DFunDef false "publishedCore" ((PCon "None") (PVar "contexts") (PVar "schemes")) (EApp (EVar "freezeRows") (EApp (EApp (EVar "publishCore") (EVar "contexts")) (EVar "schemes"))))
(DTypeSig true "publishSelected" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyFun (TyFun (TyCon "InvocationOwner") (TyApp (TyCon "Option") (TyCon "InvocationOps"))) (TyFun (TyApp (TyCon "List") (TyCon "ManifestSelector")) (TyFun (TyApp (TyCon "List") (TyCon "ModDiags")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))) (TyFun (TyCon "EntryOutcome") (TyFun (TyApp (TyCon "Option") (TyCon "EntryKey")) (TyFun (TyCon "Bool") (TyTuple (TyApp (TyCon "List") (TyCon "ManifestRequest")) (TyApp (TyCon "List") (TyCon "CapabilityManifest")) (TyApp (TyCon "List") (TyCon "TcDiag"))))))))))))
(DFunDef false "publishSelected" (PWild PWild (PList) PWild PWild PWild PWild PWild) (ETuple (EListLit) (EListLit) (EListLit)))
(DFunDef false "publishSelected" ((PVar "domains") (PVar "resolveOps") (PVar "selectors") (PVar "perMod") (PVar "core") (PVar "outcome") (PVar "executes") (PVar "valueMain")) (EBlock (DoLet false false (PVar "entry") (EApp (EApp (EVar "optionOr") (ETuple (ELit (LString "")) (ETuple (EListLit) (EListLit) (EListLit)))) (EApp (EVar "last") (EVar "perMod")))) (DoLet false false (PVar "byModule") (EApp (EVar "IdMap.fromList") (EApp (EApp (EMethodRef "map") (ELam ((PVar "m")) (ETuple (EApp (EVar "fst") (EVar "m")) (EApp (EVar "IdMap.fromList") (EApp (EVar "reverse") (EApp (EVar "modSchemes") (EApp (EVar "snd") (EVar "m")))))))) (EVar "perMod")))) (DoLet false false (PVar "coreRows") (EApp (EVar "IdMap.fromList") (EApp (EVar "reverse") (EVar "core")))) (DoLet false true (PVar "rows") (ELam ((PVar "owner")) (EMatch (EVar "owner") (arm (PCon "SourceModule" (PVar "mid")) () (EApp (EApp (EVar "optionOr") (EVar "Tip")) (EApp (EApp (EVar "IdMap.get") (EVar "mid")) (EVar "byModule")))) (arm (PCon "ShippedPrelude") () (EVar "coreRows"))))) (DoLet false true (PVar "ownerOf") (ELam ((PVar "key")) (EIf (EBinOp "&&" (EBinOp "==" (EFieldAccess (EVar "key") "moduleId") (ELit (LString "core"))) (EApp (EVar "not") (EApp (EApp (EVar "IdMap.has") (EFieldAccess (EVar "key") "binding")) (EApp (EVar "rows") (EApp (EVar "SourceModule") (ELit (LString "core"))))))) (EVar "ShippedPrelude") (EApp (EVar "SourceModule") (EFieldAccess (EVar "key") "moduleId"))))) (DoLet false false (PVar "own") (EApp (EVar "rows") (EApp (EVar "SourceModule") (EApp (EVar "fst") (EVar "entry"))))) (DoLet false true (PVar "resolve") (ELam ((PVar "selector")) (EMatch (EVar "selector") (arm (PCon "ExactEntry" (PVar "key") (PVar "protocol")) () (ETuple (ERecordCreate "ManifestRequest" ((fa "entry" (EVar "key")) (fa "protocol" (EVar "protocol")))) (EApp (EVar "ownerOf") (EVar "key")))) (arm (PCon "EntryOverPrelude" (PVar "name") (PVar "protocol")) () (EBlock (DoLet false false (PVar "isOwn") (EApp (EApp (EVar "IdMap.has") (EVar "name")) (EVar "own"))) (DoExpr (ETuple (ERecordCreate "ManifestRequest" ((fa "entry" (ERecordCreate "EntryKey" ((fa "moduleId" (EIf (EVar "isOwn") (EApp (EVar "fst") (EVar "entry")) (ELit (LString "core")))) (fa "binding" (EVar "name"))))) (fa "protocol" (EVar "protocol")))) (EIf (EVar "isOwn") (EApp (EVar "SourceModule") (EApp (EVar "fst") (EVar "entry"))) (EVar "ShippedPrelude"))))))))) (DoLet false false (PVar "resolved") (EApp (EApp (EMethodRef "map") (EVar "resolve")) (EVar "selectors"))) (DoLet false false (PVar "selected") (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "resolved"))) (DoLet false true (PVar "wrapper") (ELam ((PVar "owner")) (ELam ((PVar "name")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "p")) (ETuple (EVar "owner") (EFieldAccess (EVar "p") "psScheme")))) (EApp (EApp (EVar "IdMap.get") (EVar "name")) (EApp (EVar "rows") (EVar "owner"))))))) (DoLet false true (PVar "wrappers") (ELam ((PVar "request")) (EMatch (EFieldAccess (EVar "request") "protocol") (arm (PCon "HostInvocation") () (EListLit)) (arm (PCon "ExecutedMain") () (EIf (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "/=" (EFieldAccess (EFieldAccess (EVar "request") "entry") "moduleId") (EApp (EVar "fst") (EVar "entry"))) (EBinOp "/=" (EFieldAccess (EFieldAccess (EVar "request") "entry") "binding") (ELit (LString "main")))) (EApp (EVar "not") (EVar "valueMain"))) (EFieldAccess (EVar "outcome") "eoMainIsUnit")) (EListLit) (EIf (EFieldAccess (EVar "outcome") "eoMainIsAsync") (EApp (EApp (EApp (EVar "option") (EListLit)) (ELam ((PVar "key")) (EApp (EApp (EApp (EVar "option") (EListLit)) (ELam ((PVar "w")) (EListLit (EVar "w")))) (EApp (EApp (EVar "wrapper") (EApp (EVar "ownerOf") (EVar "key"))) (EFieldAccess (EVar "key") "binding"))))) (EVar "executes")) (EApp (EApp (EApp (EVar "option") (EListLit)) (ELam ((PVar "w")) (EListLit (EVar "w")))) (EApp (EApp (EVar "wrapper") (EVar "ShippedPrelude")) (ELit (LString "println")))))))))) (DoLet false false (PVar "inputs") (EApp (EApp (EDictApp "flatMap") (ELam ((PTuple (PVar "request") (PVar "owner"))) (EApp (EApp (EApp (EVar "option") (EListLit)) (ELam ((PVar "p")) (EListLit (ERecordCreate "ManifestEntryInput" ((fa "request" (EVar "request")) (fa "owner" (EVar "owner")) (fa "scheme" (EFieldAccess (EVar "p") "psScheme")) (fa "wrappers" (EApp (EVar "wrappers") (EVar "request")))))))) (EApp (EApp (EVar "IdMap.get") (EFieldAccess (EFieldAccess (EVar "request") "entry") "binding")) (EApp (EVar "rows") (EVar "owner")))))) (EVar "resolved"))) (DoLet false false (PVar "missingDrivers") (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "request")) (EMatch (EFieldAccess (EVar "request") "protocol") (arm (PCon "HostInvocation") () (EListLit)) (arm (PCon "ExecutedMain") () (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EFieldAccess (EFieldAccess (EVar "request") "entry") "moduleId") (EApp (EVar "fst") (EVar "entry"))) (EBinOp "==" (EFieldAccess (EFieldAccess (EVar "request") "entry") "binding") (ELit (LString "main")))) (EVar "valueMain")) (EFieldAccess (EVar "outcome") "eoMainIsAsync")) (EApp (EMethodRef "isEmpty") (EApp (EVar "wrappers") (EVar "request")))) (EListLit (EApp (EApp (EApp (EApp (EApp (EApp (EVar "TcDiag") (ELit (LString "T-MANIFEST-WRAPPER"))) (ELit (LInt 1))) (EVar "None")) (ELit (LString "no checked Async driver selected for executed main"))) (EVar "None")) (EVar "None"))) (EListLit)))))) (EVar "selected"))) (DoLet false false (PVar "missing") (EBinOp "++" (EVar "missingDrivers") (EApp (EApp (EDictApp "flatMap") (ELam ((PTuple (PVar "request") (PVar "owner"))) (EIf (EApp (EApp (EVar "IdMap.has") (EFieldAccess (EFieldAccess (EVar "request") "entry") "binding")) (EApp (EVar "rows") (EVar "owner"))) (EListLit) (EListLit (EApp (EApp (EApp (EApp (EApp (EApp (EVar "TcDiag") (ELit (LString "T-MANIFEST-ENTRY"))) (ELit (LInt 1))) (EVar "None")) (EBinOp "++" (EBinOp "++" (ELit (LString "no '")) (EFieldAccess (EFieldAccess (EVar "request") "entry") "binding")) (ELit (LString "' entry found")))) (EVar "None")) (EVar "None")))))) (EVar "resolved")))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "publishManifests") (EVar "domains")) (EVar "resolveOps")) (EVar "inputs")) (arm (PCon "Ok" (PVar "manifests")) () (ETuple (EVar "selected") (EVar "manifests") (EVar "missing"))) (arm (PCon "Err" (PVar "defects")) () (ETuple (EVar "selected") (EListLit) (EBinOp "++" (EVar "missing") (EApp (EApp (EMethodRef "map") (ELam ((PCon "ManifestDefect" (PVar "message"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "TcDiag") (ELit (LString "T-MANIFEST-INVALID"))) (ELit (LInt 1))) (EVar "None")) (EVar "message")) (EVar "None")) (EVar "None")))) (EVar "defects")))))))))
(DData Public "VarKind" () ((variant "TyVarK" (ConPos)) (variant "EffVarK" (ConPos)) (variant "AuthVarK" (ConPos))) ())
(DImpl true "Eq" ((TyCon "VarKind")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "TyVarK") (PCon "TyVarK")) () (EVar "True")) (arm (PTuple (PCon "EffVarK") (PCon "EffVarK")) () (EVar "True")) (arm (PTuple (PCon "AuthVarK") (PCon "AuthVarK")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "VarKind")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "TyVarK") () (ELit (LString "TyVarK"))) (arm (PCon "EffVarK") () (ELit (LString "EffVarK"))) (arm (PCon "AuthVarK") () (ELit (LString "AuthVarK")))))))
(DData Public "LiveCell" () ((variant "LinkCell" (ConPos (TyCon "String") (TyCon "VarKind") (TyApp (TyCon "Option") (TyCon "Int")))) (variant "FreeMeta" (ConPos (TyCon "String") (TyCon "VarKind") (TyCon "Int"))) (variant "WeakVar" (ConPos (TyCon "String") (TyCon "VarKind") (TyCon "Int"))) (variant "OpenSummary" (ConPos (TyCon "String") (TyCon "Int")))) ())
(DImpl true "Eq" ((TyCon "LiveCell")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "LinkCell" (PVar "__a0") (PVar "__a1") (PVar "__a2")) (PCon "LinkCell" (PVar "__b0") (PVar "__b1") (PVar "__b2"))) () (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EMethodRef "eq") (EVar "__a2")) (EVar "__b2")))) (arm (PTuple (PCon "FreeMeta" (PVar "__a0") (PVar "__a1") (PVar "__a2")) (PCon "FreeMeta" (PVar "__b0") (PVar "__b1") (PVar "__b2"))) () (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EMethodRef "eq") (EVar "__a2")) (EVar "__b2")))) (arm (PTuple (PCon "WeakVar" (PVar "__a0") (PVar "__a1") (PVar "__a2")) (PCon "WeakVar" (PVar "__b0") (PVar "__b1") (PVar "__b2"))) () (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EMethodRef "eq") (EVar "__a2")) (EVar "__b2")))) (arm (PTuple (PCon "OpenSummary" (PVar "__a0") (PVar "__a1")) (PCon "OpenSummary" (PVar "__b0") (PVar "__b1"))) () (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1")))) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "LiveCell")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "LinkCell" (PVar "__a0") (PVar "__a1") (PVar "__a2")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "LinkCell ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a1")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a2"))))) (arm (PCon "FreeMeta" (PVar "__a0") (PVar "__a1") (PVar "__a2")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "FreeMeta ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a1")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a2"))))) (arm (PCon "WeakVar" (PVar "__a0") (PVar "__a1") (PVar "__a2")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "WeakVar ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a1")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a2"))))) (arm (PCon "OpenSummary" (PVar "__a0") (PVar "__a1")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "OpenSummary ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a1")))))))))
(DData Public "PartialAnalysis" () ((variant "PartialAnalysis" (ConNamed (field "paModule" (TyCon "String")) (field "paSchemes" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme")))))) (field "paCore" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme")))) (field "paLocals" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme") (TyApp (TyCon "Option") (TyCon "Loc"))))) (field "paSeed" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))))))) ())
(DData Public "EntryTables" () ((variant "EntryTables" (ConNamed (field "etModule" (TyCon "String")) (field "etLocals" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme") (TyApp (TyCon "Option") (TyCon "Loc"))))) (field "etSeed" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))))))) ())
(DTypeSig true "noEntryTables" (TyCon "EntryTables"))
(DFunDef false "noEntryTables" () (ERecordCreate "EntryTables" ((fa "etModule" (ELit (LString ""))) (fa "etLocals" (EListLit)) (fa "etSeed" (EListLit)))))
(DTypeSig true "partialAnalysis" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))) (TyFun (TyCon "EntryTables") (TyCon "PartialAnalysis")))))
(DFunDef false "partialAnalysis" ((PVar "schemes") (PVar "core") (PVar "tables")) (ERecordCreate "PartialAnalysis" ((fa "paModule" (EFieldAccess (EVar "tables") "etModule")) (fa "paSchemes" (EVar "schemes")) (fa "paCore" (EVar "core")) (fa "paLocals" (EFieldAccess (EVar "tables") "etLocals")) (fa "paSeed" (EFieldAccess (EVar "tables") "etSeed")))))
(DData Public "CheckedProgram" () ((variant "CheckedProgram" (ConNamed (field "cpSchemes" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme")))))) (field "cpCore" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme")))) (field "cpEvidence" (TyCon "EvTable")) (field "cpDispositions" (TyCon "DispositionTable")) (field "cpBinders" (TyCon "BinderTypeTable")) (field "cpEntryOutcome" (TyCon "EntryOutcome")) (field "cpTrees" (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))))) (field "cpWeak" (TyApp (TyCon "List") (TyCon "LiveCell"))) (field "cpManifests" (TyApp (TyCon "List") (TyCon "CapabilityManifest")))))) ())
(DData Public "EntryOutcome" () ((variant "EntryOutcome" (ConNamed (field "eoMainIsUnit" (TyCon "Bool")) (field "eoMainIsFloat" (TyCon "Bool")) (field "eoMainIsAsync" (TyCon "Bool")) (field "eoMainAsyncPayloadIsUnit" (TyCon "Bool")) (field "eoAutoPrint" (TyApp (TyCon "Option") (TyCon "EvId")))))) ())
(DTypeSig true "noEntryOutcome" (TyCon "EntryOutcome"))
(DFunDef false "noEntryOutcome" () (ERecordCreate "EntryOutcome" ((fa "eoMainIsUnit" (EVar "False")) (fa "eoMainIsFloat" (EVar "False")) (fa "eoMainIsAsync" (EVar "False")) (fa "eoMainAsyncPayloadIsUnit" (EVar "False")) (fa "eoAutoPrint" (EVar "None")))))
(DData Public "TcReport" () ((variant "TcReport" (ConNamed (field "trPartial" (TyCon "PartialAnalysis")) (field "trDiagnostics" (TyApp (TyCon "List") (TyCon "ModDiags"))) (field "trResidual" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TcDiag")))) (field "trChecked" (TyApp (TyCon "Option") (TyCon "CheckedProgram"))) (field "trEvidenceFaults" (TyApp (TyCon "List") (TyCon "EvidenceFault")))))) ())
(DData Public "ZState" () ((variant "ZState" (ConNamed (field "zTys" (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyCon "Ref") (TyCon "Tyvar")))) (field "zEffs" (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyCon "Ref") (TyCon "Effvar")))) (field "zAuths" (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyApp (TyCon "Ref") (TyCon "Authvar")))) (field "zLinks" (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "EffRow")))))) ())
(DTypeSig true "emptyZonk" (TyCon "ZState"))
(DFunDef false "emptyZonk" () (ERecordCreate "ZState" ((fa "zTys" (EVar "Tip")) (fa "zEffs" (EVar "Tip")) (fa "zAuths" (EVar "Tip")) (fa "zLinks" (EVar "Tip")))))
(DTypeSig true "zonkMono" (TyFun (TyCon "ZState") (TyFun (TyCon "Mono") (TyTuple (TyCon "ZState") (TyCon "Mono")))))
(DFunDef false "zonkMono" ((PVar "z") (PCon "TVar" (PVar "cell"))) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "Link" (PVar "t")) () (EApp (EApp (EVar "zonkMono") (EVar "z")) (EVar "t"))) (arm (PCon "Unbound" (PVar "id") (PVar "lvl")) () (EMatch (EApp (EApp (EVar "IdMap.get") (EVar "id")) (EFieldAccess (EVar "z") "zTys")) (arm (PCon "Some" (PVar "c")) () (ETuple (EVar "z") (EApp (EVar "TVar") (EVar "c")))) (arm (PCon "None") () (EBlock (DoLet false false (PVar "c") (EApp (EVar "Ref") (EApp (EApp (EVar "Unbound") (EVar "id")) (EVar "lvl")))) (DoExpr (ETuple (ERecordUpdate (EVar "z") ((fa "zTys" (EApp (EApp (EApp (EVar "IdMap.set") (EVar "id")) (EVar "c")) (EFieldAccess (EVar "z") "zTys"))))) (EApp (EVar "TVar") (EVar "c"))))))))))
(DFunDef false "zonkMono" ((PVar "z") (PCon "TApp" (PVar "a") (PVar "b"))) (EBlock (DoLet false false (PTuple (PVar "z1") (PVar "a1")) (EApp (EApp (EVar "zonkMono") (EVar "z")) (EVar "a"))) (DoLet false false (PTuple (PVar "z2") (PVar "b1")) (EApp (EApp (EVar "zonkMono") (EVar "z1")) (EVar "b"))) (DoExpr (ETuple (EVar "z2") (EApp (EApp (EVar "TApp") (EVar "a1")) (EVar "b1"))))))
(DFunDef false "zonkMono" ((PVar "z") (PCon "TFun" (PVar "a") (PVar "row") (PVar "b"))) (EBlock (DoLet false false (PTuple (PVar "z1") (PVar "a1")) (EApp (EApp (EVar "zonkMono") (EVar "z")) (EVar "a"))) (DoLet false false (PTuple (PVar "z2") (PVar "row1")) (EApp (EApp (EVar "zonkRow") (EVar "z1")) (EVar "row"))) (DoLet false false (PTuple (PVar "z3") (PVar "b1")) (EApp (EApp (EVar "zonkMono") (EVar "z2")) (EVar "b"))) (DoExpr (ETuple (EVar "z3") (EApp (EApp (EApp (EVar "TFun") (EVar "a1")) (EVar "row1")) (EVar "b1"))))))
(DFunDef false "zonkMono" ((PVar "z") (PCon "TEff" (PVar "row"))) (EBlock (DoLet false false (PTuple (PVar "z1") (PVar "row1")) (EApp (EApp (EVar "zonkRow") (EVar "z")) (EVar "row"))) (DoExpr (ETuple (EVar "z1") (EApp (EVar "TEff") (EVar "row1"))))))
(DFunDef false "zonkMono" ((PVar "z") (PCon "TQual" (PVar "m") (PVar "auth"))) (EBlock (DoLet false false (PTuple (PVar "z1") (PVar "m1")) (EApp (EApp (EVar "zonkMono") (EVar "z")) (EVar "m"))) (DoLet false false (PTuple (PVar "z2") (PVar "auth1")) (EApp (EApp (EVar "zonkAuthority") (EVar "z1")) (EVar "auth"))) (DoExpr (ETuple (EVar "z2") (EApp (EApp (EVar "TQual") (EVar "m1")) (EVar "auth1"))))))
(DFunDef false "zonkMono" ((PVar "z") (PCon "TAuth" (PVar "auth"))) (EBlock (DoLet false false (PTuple (PVar "z1") (PVar "auth1")) (EApp (EApp (EVar "zonkAuthority") (EVar "z")) (EVar "auth"))) (DoExpr (ETuple (EVar "z1") (EApp (EVar "TAuth") (EVar "auth1"))))))
(DFunDef false "zonkMono" ((PVar "z") (PVar "m")) (ETuple (EVar "z") (EVar "m")))
(DTypeSig true "zonkAuthority" (TyFun (TyCon "ZState") (TyFun (TyCon "Authority") (TyTuple (TyCon "ZState") (TyCon "Authority")))))
(DFunDef false "zonkAuthority" ((PVar "z") (PCon "AVar" (PVar "cell"))) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "ALink" PWild PWild (PVar "target")) () (EApp (EApp (EVar "zonkAuthority") (EVar "z")) (EVar "target"))) (arm (PCon "AUnbound" (PVar "id") (PVar "lvl") (PVar "top") (PVar "pat") (PVar "name")) () (EMatch (EApp (EApp (EVar "IdMap.get") (EVar "id")) (EFieldAccess (EVar "z") "zAuths")) (arm (PCon "Some" (PVar "c")) () (ETuple (EVar "z") (EApp (EVar "AVar") (EVar "c")))) (arm (PCon "None") () (EBlock (DoLet false false (PVar "c") (EApp (EVar "Ref") (EApp (EApp (EApp (EApp (EApp (EVar "AUnbound") (EVar "id")) (EVar "lvl")) (EVar "top")) (EVar "pat")) (EVar "name")))) (DoExpr (ETuple (ERecordUpdate (EVar "z") ((fa "zAuths" (EApp (EApp (EApp (EVar "IdMap.set") (EVar "id")) (EVar "c")) (EFieldAccess (EVar "z") "zAuths"))))) (EApp (EVar "AVar") (EVar "c"))))))))))
(DFunDef false "zonkAuthority" ((PVar "z") (PCon "AJoin" (PVar "ms"))) (EBlock (DoLet false false (PTuple (PVar "z1") (PVar "ms1")) (EApp (EApp (EApp (EVar "mapAccumL") (EVar "zonkAuthority")) (EVar "z")) (EVar "ms"))) (DoExpr (ETuple (EVar "z1") (EApp (EVar "AJoin") (EVar "ms1"))))))
(DFunDef false "zonkAuthority" ((PVar "z") (PCon "AProduct" (PVar "axes"))) (EBlock (DoLet false false (PTuple (PVar "z1") (PVar "axes1")) (EApp (EApp (EApp (EVar "mapAccumL") (EVar "zonkAxis")) (EVar "z")) (EVar "axes"))) (DoExpr (ETuple (EVar "z1") (EApp (EVar "AProduct") (EVar "axes1"))))))
(DFunDef false "zonkAuthority" ((PVar "z") (PVar "a")) (ETuple (EVar "z") (EVar "a")))
(DTypeSig false "zonkAxis" (TyFun (TyCon "ZState") (TyFun (TyTuple (TyCon "String") (TyCon "Authority")) (TyTuple (TyCon "ZState") (TyTuple (TyCon "String") (TyCon "Authority"))))))
(DFunDef false "zonkAxis" ((PVar "z") (PTuple (PVar "name") (PVar "a"))) (EBlock (DoLet false false (PTuple (PVar "z1") (PVar "a1")) (EApp (EApp (EVar "zonkAuthority") (EVar "z")) (EVar "a"))) (DoExpr (ETuple (EVar "z1") (ETuple (EVar "name") (EVar "a1"))))))
(DTypeSig false "zonkAtom" (TyFun (TyCon "ZState") (TyFun (TyCon "Atom") (TyTuple (TyCon "ZState") (TyCon "Atom")))))
(DFunDef false "zonkAtom" ((PVar "z") (PCon "Atom" (PVar "lbl") (PVar "auth"))) (EBlock (DoLet false false (PTuple (PVar "z1") (PVar "auth1")) (EApp (EApp (EVar "zonkAuthority") (EVar "z")) (EVar "auth"))) (DoExpr (ETuple (EVar "z1") (EApp (EApp (EVar "Atom") (EVar "lbl")) (EVar "auth1"))))))
(DTypeSig true "zonkRow" (TyFun (TyCon "ZState") (TyFun (TyCon "EffRow") (TyTuple (TyCon "ZState") (TyCon "EffRow")))))
(DFunDef false "zonkRow" ((PVar "z") (PCon "EffRow" (PVar "atoms") (PVar "tail"))) (EBlock (DoLet false false (PTuple (PVar "z1") (PVar "atoms1")) (EApp (EApp (EApp (EVar "mapAccumL") (EVar "zonkAtom")) (EVar "z")) (EVar "atoms"))) (DoExpr (EMatch (EVar "tail") (arm (PCon "None") () (ETuple (EVar "z1") (EApp (EApp (EVar "EffRow") (EVar "atoms1")) (EVar "None")))) (arm (PCon "Some" (PVar "cell")) () (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "ELink" (PVar "id") (PVar "row")) () (EBlock (DoLet false false (PTuple (PVar "z2") (PCon "EffRow" (PVar "more") (PVar "rest"))) (EApp (EApp (EApp (EVar "linkedRow") (EVar "z1")) (EVar "id")) (EVar "row"))) (DoExpr (ETuple (EVar "z2") (EApp (EApp (EVar "EffRow") (EBinOp "++" (EVar "atoms1") (EVar "more"))) (EVar "rest")))))) (arm PWild () (EBlock (DoLet false false (PTuple (PVar "z2") (PVar "c")) (EApp (EApp (EVar "zonkEffCell") (EVar "z1")) (EVar "cell"))) (DoExpr (ETuple (EVar "z2") (EApp (EApp (EVar "EffRow") (EVar "atoms1")) (EApp (EVar "Some") (EVar "c")))))))))))))
(DTypeSig false "linkedRow" (TyFun (TyCon "ZState") (TyFun (TyCon "Int") (TyFun (TyCon "EffRow") (TyTuple (TyCon "ZState") (TyCon "EffRow"))))))
(DFunDef false "linkedRow" ((PVar "z") (PVar "id") (PVar "row")) (EMatch (EApp (EApp (EVar "IdMap.get") (EVar "id")) (EFieldAccess (EVar "z") "zLinks")) (arm (PCon "Some" (PVar "r")) () (ETuple (EVar "z") (EVar "r"))) (arm (PCon "None") () (EBlock (DoLet false false (PTuple (PVar "z1") (PVar "r")) (EApp (EApp (EVar "zonkRow") (EVar "z")) (EVar "row"))) (DoExpr (ETuple (ERecordUpdate (EVar "z1") ((fa "zLinks" (EApp (EApp (EApp (EVar "IdMap.set") (EVar "id")) (EVar "r")) (EFieldAccess (EVar "z1") "zLinks"))))) (EVar "r")))))))
(DTypeSig false "zonkEffCell" (TyFun (TyCon "ZState") (TyFun (TyApp (TyCon "Ref") (TyCon "Effvar")) (TyTuple (TyCon "ZState") (TyApp (TyCon "Ref") (TyCon "Effvar"))))))
(DFunDef false "zonkEffCell" ((PVar "z") (PVar "cell")) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "EUnbound" (PVar "id") (PVar "lvl")) () (EApp (EApp (EApp (EVar "memoEff") (EVar "z")) (EVar "id")) (EApp (EApp (EVar "EUnbound") (EVar "id")) (EVar "lvl")))) (arm (PCon "ESummary" (PVar "id") (PVar "a") (PVar "b")) () (EApp (EApp (EApp (EVar "memoEff") (EVar "z")) (EVar "id")) (EApp (EApp (EApp (EVar "ESummary") (EVar "id")) (EVar "a")) (EVar "b")))) (arm (PCon "EJoin" (PVar "id") (PVar "lvl") (PVar "members")) () (EMatch (EApp (EApp (EVar "IdMap.get") (EVar "id")) (EFieldAccess (EVar "z") "zEffs")) (arm (PCon "Some" (PVar "c")) () (ETuple (EVar "z") (EVar "c"))) (arm (PCon "None") () (EBlock (DoLet false false (PTuple (PVar "z1") (PVar "ms")) (EApp (EApp (EApp (EVar "mapAccumL") (EVar "zonkEffCell")) (EVar "z")) (EVar "members"))) (DoLet false false (PVar "c") (EApp (EVar "Ref") (EApp (EApp (EApp (EVar "EJoin") (EVar "id")) (EVar "lvl")) (EVar "ms")))) (DoExpr (ETuple (ERecordUpdate (EVar "z1") ((fa "zEffs" (EApp (EApp (EApp (EVar "IdMap.set") (EVar "id")) (EVar "c")) (EFieldAccess (EVar "z1") "zEffs"))))) (EVar "c"))))))) (arm (PCon "ELink" (PVar "id") (PVar "row")) () (EMatch (EApp (EApp (EVar "IdMap.get") (EVar "id")) (EFieldAccess (EVar "z") "zEffs")) (arm (PCon "Some" (PVar "c")) () (ETuple (EVar "z") (EVar "c"))) (arm (PCon "None") () (EBlock (DoLet false false (PTuple (PVar "z1") (PVar "r")) (EApp (EApp (EApp (EVar "linkedRow") (EVar "z")) (EVar "id")) (EVar "row"))) (DoExpr (EMatch (EVar "r") (arm (PCon "EffRow" (PList) (PCon "Some" (PVar "t"))) () (ETuple (ERecordUpdate (EVar "z1") ((fa "zEffs" (EApp (EApp (EApp (EVar "IdMap.set") (EVar "id")) (EVar "t")) (EFieldAccess (EVar "z1") "zEffs"))))) (EVar "t"))) (arm PWild () (EBlock (DoLet false false (PVar "c") (EApp (EVar "Ref") (EApp (EApp (EVar "ELink") (EVar "id")) (EVar "r")))) (DoExpr (ETuple (ERecordUpdate (EVar "z1") ((fa "zEffs" (EApp (EApp (EApp (EVar "IdMap.set") (EVar "id")) (EVar "c")) (EFieldAccess (EVar "z1") "zEffs"))))) (EVar "c")))))))))))))
(DTypeSig false "memoEff" (TyFun (TyCon "ZState") (TyFun (TyCon "Int") (TyFun (TyCon "Effvar") (TyTuple (TyCon "ZState") (TyApp (TyCon "Ref") (TyCon "Effvar")))))))
(DFunDef false "memoEff" ((PVar "z") (PVar "id") (PVar "v")) (EMatch (EApp (EApp (EVar "IdMap.get") (EVar "id")) (EFieldAccess (EVar "z") "zEffs")) (arm (PCon "Some" (PVar "c")) () (ETuple (EVar "z") (EVar "c"))) (arm (PCon "None") () (EBlock (DoLet false false (PVar "c") (EApp (EVar "Ref") (EVar "v"))) (DoExpr (ETuple (ERecordUpdate (EVar "z") ((fa "zEffs" (EApp (EApp (EApp (EVar "IdMap.set") (EVar "id")) (EVar "c")) (EFieldAccess (EVar "z") "zEffs"))))) (EVar "c")))))))
(DTypeSig true "zonkVecObl" (TyFun (TyCon "ZState") (TyFun (TyCon "VecObl") (TyTuple (TyCon "ZState") (TyCon "VecObl")))))
(DFunDef false "zonkVecObl" ((PVar "z") (PRec "VecObl" ((rf "voIface" (PVar "iface")) (rf "voIds" (PVar "ids")) (rf "voArgs" (PVar "args"))) false)) (EBlock (DoLet false false (PTuple (PVar "z1") (PVar "args1")) (EApp (EApp (EApp (EVar "mapAccumL") (EVar "zonkMono")) (EVar "z")) (EVar "args"))) (DoExpr (ETuple (EVar "z1") (ERecordCreate "VecObl" ((fa "voIface" (EVar "iface")) (fa "voIds" (EVar "ids")) (fa "voArgs" (EVar "args1"))))))))
(DTypeSig false "zonkResidual" (TyFun (TyCon "ZState") (TyFun (TyCon "AuthResidual") (TyTuple (TyCon "ZState") (TyCon "AuthResidual")))))
(DFunDef false "zonkResidual" ((PVar "z") (PRec "AuthResidual" ((rf "arLower" (PVar "lo")) (rf "arUpper" (PVar "hi")) (rf "arExact" (PVar "ex"))) false)) (EBlock (DoLet false false (PTuple (PVar "z1") (PVar "lo1")) (EApp (EApp (EVar "zonkAuthority") (EVar "z")) (EVar "lo"))) (DoLet false false (PTuple (PVar "z2") (PVar "hi1")) (EApp (EApp (EVar "zonkAuthority") (EVar "z1")) (EVar "hi"))) (DoExpr (ETuple (EVar "z2") (ERecordCreate "AuthResidual" ((fa "arLower" (EVar "lo1")) (fa "arUpper" (EVar "hi1")) (fa "arExact" (EVar "ex"))))))))
(DTypeSig true "zonkScheme" (TyFun (TyCon "ZState") (TyFun (TyCon "Scheme") (TyTuple (TyCon "ZState") (TyCon "Scheme")))))
(DFunDef false "zonkScheme" ((PVar "z") (PCon "Forall" (PVar "ids") (PVar "effIds") (PVar "authIds") (PVar "residuals") (PVar "row") (PVar "t"))) (EBlock (DoLet false false (PTuple (PVar "z1") (PVar "residuals1")) (EApp (EApp (EApp (EVar "mapAccumL") (EVar "zonkResidual")) (EVar "z")) (EVar "residuals"))) (DoLet false false (PTuple (PVar "z2") (PVar "row1")) (EApp (EApp (EVar "zonkRow") (EVar "z1")) (EVar "row"))) (DoLet false false (PTuple (PVar "z3") (PVar "t1")) (EApp (EApp (EVar "zonkMono") (EVar "z2")) (EVar "t"))) (DoExpr (ETuple (EVar "z3") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Forall") (EVar "ids")) (EVar "effIds")) (EVar "authIds")) (EVar "residuals1")) (EVar "row1")) (EVar "t1"))))))
(DTypeSig true "freezePub" (TyFun (TyCon "Scheme") (TyFun (TyApp (TyCon "List") (TyCon "VecObl")) (TyCon "PubScheme"))))
(DFunDef false "freezePub" ((PVar "s") (PVar "ctx")) (EBlock (DoLet false false (PTuple (PVar "z1") (PVar "s1")) (EApp (EApp (EVar "zonkScheme") (EVar "emptyZonk")) (EVar "s"))) (DoLet false false (PTuple PWild (PVar "ctx1")) (EApp (EApp (EApp (EVar "mapAccumL") (EVar "zonkVecObl")) (EVar "z1")) (EVar "ctx"))) (DoExpr (ERecordCreate "PubScheme" ((fa "psScheme" (EVar "s1")) (fa "psContext" (EVar "ctx1")))))))
(DTypeSig true "freezeRows" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme")))))
(DFunDef false "freezeRows" () (EApp (EMethodRef "map") (ELam ((PVar "b")) (ETuple (EApp (EVar "fst") (EVar "b")) (EApp (EApp (EVar "freezePub") (EFieldAccess (EApp (EVar "snd") (EVar "b")) "psScheme")) (EFieldAccess (EApp (EVar "snd") (EVar "b")) "psContext"))))))
(DTypeSig true "freezeModDiags" (TyFun (TyCon "ModDiags") (TyCon "ModDiags")))
(DFunDef false "freezeModDiags" ((PTuple (PVar "mid") (PTuple (PVar "schemes") (PVar "errs") (PVar "warns")))) (ETuple (EVar "mid") (ETuple (EApp (EVar "freezeRows") (EVar "schemes")) (EVar "errs") (EVar "warns"))))
(DTypeSig true "freezeNewest" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "ModDiags")) (TyApp (TyCon "List") (TyCon "ModDiags")))))
(DFunDef false "freezeNewest" ((PVar "n") (PVar "rows")) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (EVar "rows") (EIf (EVar "otherwise") (EMatch (EVar "rows") (arm (PList) () (EListLit)) (arm (PCons (PVar "m") (PVar "rest")) () (EBinOp "::" (EApp (EVar "freezeModDiags") (EVar "m")) (EApp (EApp (EVar "freezeNewest") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "rest"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "graphReport" (TyFun (TyApp (TyCon "List") (TyCon "ModDiags")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TcDiag"))) (TyFun (TyFun (TyCon "Unit") (TyCon "EvTable")) (TyFun (TyCon "DispositionTable") (TyFun (TyCon "BinderTypeTable") (TyFun (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))) (TyFun (TyCon "EntryTables") (TyCon "TcReport"))))))))))
(DFunDef false "graphReport" ((PVar "perMod") (PVar "core") (PVar "residual") (PVar "evidence") (PVar "dispositions") (PVar "binders") (PVar "trees") (PVar "tables")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "graphReportWithOutcome") (EVar "noEntryOutcome")) (EListLit)) (EListLit)) (EVar "perMod")) (EVar "core")) (EVar "residual")) (EVar "evidence")) (EVar "dispositions")) (EVar "binders")) (EVar "trees")) (EVar "tables")))
(DTypeSig true "graphReportWithOutcome" (TyFun (TyCon "EntryOutcome") (TyFun (TyApp (TyCon "List") (TyCon "CapabilityManifest")) (TyFun (TyApp (TyCon "List") (TyCon "TcDiag")) (TyFun (TyApp (TyCon "List") (TyCon "ModDiags")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TcDiag"))) (TyFun (TyFun (TyCon "Unit") (TyCon "EvTable")) (TyFun (TyCon "DispositionTable") (TyFun (TyCon "BinderTypeTable") (TyFun (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))) (TyFun (TyCon "EntryTables") (TyCon "TcReport")))))))))))))
(DFunDef false "graphReportWithOutcome" ((PVar "outcome") (PVar "manifests") (PVar "manifestDiags") (PVar "perMod") (PVar "core") (PVar "residual") (PVar "evidence") (PVar "dispositions") (PVar "binders") (PVar "trees") (PVar "tables")) (EBlock (DoLet false false (PVar "schemes") (EApp (EApp (EMethodRef "map") (ELam ((PVar "m")) (ETuple (EApp (EVar "fst") (EVar "m")) (EApp (EVar "modSchemes") (EApp (EVar "snd") (EVar "m")))))) (EVar "perMod"))) (DoLet false false (PVar "cells") (EApp (EVar "graphCells") (EBinOp "::" (EVar "core") (EApp (EApp (EMethodRef "map") (EVar "snd")) (EVar "schemes"))))) (DoLet false false (PVar "judged") (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EMethodRef "isEmpty") (EVar "residual")) (EApp (EMethodRef "isEmpty") (EVar "manifestDiags"))) (EApp (EVar "noModErrors") (EVar "perMod"))) (EApp (EApp (EDictApp "all") (EVar "isWeak")) (EVar "cells"))) (EBlock (DoLet false false (PVar "table") (EApp (EVar "evidence") (ELit LUnit))) (DoExpr (EApp (EVar "Some") (ETuple (EVar "table") (EApp (EApp (EVar "evidenceFaults") (EVar "trees")) (EVar "table")))))) (EVar "None"))) (DoLet false false (PVar "checked") (EMatch (EVar "judged") (arm (PCon "Some" (PTuple (PVar "table") (PList))) () (EApp (EVar "Some") (ERecordCreate "CheckedProgram" ((fa "cpSchemes" (EVar "schemes")) (fa "cpCore" (EVar "core")) (fa "cpEvidence" (EVar "table")) (fa "cpDispositions" (EVar "dispositions")) (fa "cpBinders" (EVar "binders")) (fa "cpEntryOutcome" (EVar "outcome")) (fa "cpTrees" (EVar "trees")) (fa "cpWeak" (EVar "cells")) (fa "cpManifests" (EVar "manifests")))))) (arm PWild () (EVar "None")))) (DoExpr (ERecordCreate "TcReport" ((fa "trPartial" (EApp (EApp (EApp (EVar "partialAnalysis") (EVar "schemes")) (EVar "core")) (EVar "tables"))) (fa "trDiagnostics" (EVar "perMod")) (fa "trResidual" (EBinOp "++" (EVar "residual") (EApp (EApp (EMethodRef "map") (ELam ((PVar "d")) (ETuple (EFieldAccess (EVar "tables") "etModule") (EVar "d")))) (EVar "manifestDiags")))) (fa "trChecked" (EVar "checked")) (fa "trEvidenceFaults" (EMatch (EVar "judged") (arm (PCon "Some" (PTuple PWild (PVar "faults"))) () (EVar "faults")) (arm (PCon "None") () (EListLit)))))))))
(DTypeSig true "graphCells" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme")))) (TyApp (TyCon "List") (TyCon "LiveCell"))))
(DFunDef false "graphCells" ((PList)) (EListLit))
(DFunDef false "graphCells" ((PCons (PVar "rows") (PVar "rest"))) (EApp (EApp (EVar "rowCells") (EVar "rows")) (EApp (EVar "graphCells") (EVar "rest"))))
(DTypeSig false "rowCells" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))) (TyFun (TyApp (TyCon "List") (TyCon "LiveCell")) (TyApp (TyCon "List") (TyCon "LiveCell")))))
(DFunDef false "rowCells" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "rowCells" ((PCons (PTuple (PVar "name") (PVar "p")) (PVar "rest")) (PVar "acc")) (EBinOp "++" (EApp (EVar "atGraphEnd") (EApp (EApp (EVar "liveCells") (EVar "name")) (EVar "p"))) (EApp (EApp (EVar "rowCells") (EVar "rest")) (EVar "acc"))))
(DTypeSig false "modSchemes" (TyFun (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))) (TyApp (TyCon "List") (TyCon "TcDiag")) (TyApp (TyCon "List") (TyCon "TcDiag"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme")))))
(DFunDef false "modSchemes" ((PTuple (PVar "s") PWild PWild)) (EVar "s"))
(DTypeSig false "noModErrors" (TyFun (TyApp (TyCon "List") (TyCon "ModDiags")) (TyCon "Bool")))
(DFunDef false "noModErrors" ((PList)) (EVar "True"))
(DFunDef false "noModErrors" ((PCons (PTuple PWild (PTuple PWild (PList) PWild)) (PVar "rest"))) (EApp (EVar "noModErrors") (EVar "rest")))
(DFunDef false "noModErrors" (PWild) (EVar "False"))
(DTypeSig false "isWeak" (TyFun (TyCon "LiveCell") (TyCon "Bool")))
(DFunDef false "isWeak" ((PCon "WeakVar" PWild PWild PWild)) (EVar "True"))
(DFunDef false "isWeak" (PWild) (EVar "False"))
(DData Private "Walk" () ((variant "Walk" (ConPos (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyCon "Unit")) (TyApp (TyCon "List") (TyCon "LiveCell"))))) ())
(DTypeSig true "liveCells" (TyFun (TyCon "String") (TyFun (TyCon "PubScheme") (TyApp (TyCon "List") (TyCon "LiveCell")))))
(DFunDef false "liveCells" ((PVar "name") (PRec "PubScheme" ((rf "psScheme" (PCon "Forall" (PVar "ids") (PVar "effIds") (PVar "authIds") (PVar "residuals") (PVar "row") (PVar "t"))) (rf "psContext" (PVar "ctx"))) false)) (EBlock (DoLet false false (PVar "w0") (EApp (EApp (EVar "Walk") (EVar "Tip")) (EListLit))) (DoLet false false (PVar "w1") (EApp (EApp (EApp (EApp (EVar "walkResiduals") (EVar "name")) (EVar "authIds")) (EVar "residuals")) (EVar "w0"))) (DoLet false false (PVar "w2") (EApp (EApp (EApp (EApp (EApp (EVar "walkRow") (EVar "name")) (EVar "effIds")) (EVar "authIds")) (EVar "row")) (EVar "w1"))) (DoLet false false (PVar "w3") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "walkMono") (EVar "name")) (EVar "ids")) (EVar "effIds")) (EVar "authIds")) (EVar "t")) (EVar "w2"))) (DoLet false false (PVar "w4") (EApp (EApp (EApp (EVar "foldWalk") (EApp (EApp (EApp (EApp (EVar "walkObl") (EVar "name")) (EVar "ids")) (EVar "effIds")) (EVar "authIds"))) (EVar "ctx")) (EVar "w3"))) (DoExpr (EMatch (EVar "w4") (arm (PCon "Walk" PWild (PVar "found")) () (EApp (EVar "nub") (EApp (EVar "reverse") (EVar "found"))))))))
(DTypeSig true "atGraphEnd" (TyFun (TyApp (TyCon "List") (TyCon "LiveCell")) (TyApp (TyCon "List") (TyCon "LiveCell"))))
(DFunDef false "atGraphEnd" () (EApp (EMethodRef "map") (EVar "toWeak")))
(DTypeSig false "toWeak" (TyFun (TyCon "LiveCell") (TyCon "LiveCell")))
(DFunDef false "toWeak" ((PCon "FreeMeta" (PVar "n") (PVar "k") (PVar "i"))) (EApp (EApp (EApp (EVar "WeakVar") (EVar "n")) (EVar "k")) (EVar "i")))
(DFunDef false "toWeak" ((PVar "c")) (EVar "c"))
(DTypeSig false "foldWalk" (TyFun (TyFun (TyVar "a") (TyFun (TyCon "Walk") (TyCon "Walk"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyFun (TyCon "Walk") (TyCon "Walk")))))
(DFunDef false "foldWalk" (PWild (PList) (PVar "w")) (EVar "w"))
(DFunDef false "foldWalk" ((PVar "f") (PCons (PVar "x") (PVar "xs")) (PVar "w")) (EApp (EApp (EApp (EVar "foldWalk") (EVar "f")) (EVar "xs")) (EApp (EApp (EVar "f") (EVar "x")) (EVar "w"))))
(DTypeSig false "push" (TyFun (TyCon "LiveCell") (TyFun (TyCon "Walk") (TyCon "Walk"))))
(DFunDef false "push" ((PVar "c") (PCon "Walk" (PVar "seen") (PVar "found"))) (EApp (EApp (EVar "Walk") (EVar "seen")) (EBinOp "::" (EVar "c") (EVar "found"))))
(DTypeSig false "hasId" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Bool"))))
(DFunDef false "hasId" (PWild (PList)) (EVar "False"))
(DFunDef false "hasId" ((PVar "x") (PCons (PVar "y") (PVar "ys"))) (EBinOp "||" (EBinOp "==" (EVar "x") (EVar "y")) (EApp (EApp (EVar "hasId") (EVar "x")) (EVar "ys"))))
(DTypeSig false "walkObl" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "VecObl") (TyFun (TyCon "Walk") (TyCon "Walk"))))))))
(DFunDef false "walkObl" ((PVar "name") (PVar "ids") (PVar "effIds") (PVar "authIds") (PRec "VecObl" ((rf "voArgs" (PVar "args"))) false) (PVar "w")) (EApp (EApp (EApp (EVar "foldWalk") (EApp (EApp (EApp (EApp (EVar "walkMono") (EVar "name")) (EVar "ids")) (EVar "effIds")) (EVar "authIds"))) (EVar "args")) (EVar "w")))
(DTypeSig false "walkResiduals" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "AuthResidual")) (TyFun (TyCon "Walk") (TyCon "Walk"))))))
(DFunDef false "walkResiduals" ((PVar "name") (PVar "authIds") (PVar "rs") (PVar "w")) (EApp (EApp (EApp (EVar "foldWalk") (ELam ((PVar "r") (PVar "acc")) (EMatch (EVar "r") (arm (PRec "AuthResidual" ((rf "arLower" (PVar "lo")) (rf "arUpper" (PVar "hi"))) false) () (EApp (EApp (EApp (EApp (EVar "walkAuth") (EVar "name")) (EVar "authIds")) (EVar "hi")) (EApp (EApp (EApp (EApp (EVar "walkAuth") (EVar "name")) (EVar "authIds")) (EVar "lo")) (EVar "acc"))))))) (EVar "rs")) (EVar "w")))
(DTypeSig false "walkMono" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Mono") (TyFun (TyCon "Walk") (TyCon "Walk"))))))))
(DFunDef false "walkMono" ((PVar "name") (PVar "ids") (PVar "effIds") (PVar "authIds") (PCon "TVar" (PVar "cell")) (PVar "w")) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "Link" PWild) () (EApp (EApp (EVar "push") (EApp (EApp (EApp (EVar "LinkCell") (EVar "name")) (EVar "TyVarK")) (EVar "None"))) (EVar "w"))) (arm (PCon "Unbound" (PVar "id") PWild) () (EIf (EApp (EApp (EVar "hasId") (EVar "id")) (EVar "ids")) (EVar "w") (EApp (EApp (EVar "push") (EApp (EApp (EApp (EVar "FreeMeta") (EVar "name")) (EVar "TyVarK")) (EVar "id"))) (EVar "w"))))))
(DFunDef false "walkMono" ((PVar "name") (PVar "ids") (PVar "effIds") (PVar "authIds") (PCon "TApp" (PVar "a") (PVar "b")) (PVar "w")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "walkMono") (EVar "name")) (EVar "ids")) (EVar "effIds")) (EVar "authIds")) (EVar "b")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "walkMono") (EVar "name")) (EVar "ids")) (EVar "effIds")) (EVar "authIds")) (EVar "a")) (EVar "w"))))
(DFunDef false "walkMono" ((PVar "name") (PVar "ids") (PVar "effIds") (PVar "authIds") (PCon "TFun" (PVar "a") (PVar "row") (PVar "b")) (PVar "w")) (EBlock (DoLet false false (PVar "w1") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "walkMono") (EVar "name")) (EVar "ids")) (EVar "effIds")) (EVar "authIds")) (EVar "a")) (EVar "w"))) (DoLet false false (PVar "w2") (EApp (EApp (EApp (EApp (EApp (EVar "walkRow") (EVar "name")) (EVar "effIds")) (EVar "authIds")) (EVar "row")) (EVar "w1"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "walkMono") (EVar "name")) (EVar "ids")) (EVar "effIds")) (EVar "authIds")) (EVar "b")) (EVar "w2")))))
(DFunDef false "walkMono" ((PVar "name") PWild (PVar "effIds") (PVar "authIds") (PCon "TEff" (PVar "row")) (PVar "w")) (EApp (EApp (EApp (EApp (EApp (EVar "walkRow") (EVar "name")) (EVar "effIds")) (EVar "authIds")) (EVar "row")) (EVar "w")))
(DFunDef false "walkMono" ((PVar "name") (PVar "ids") (PVar "effIds") (PVar "authIds") (PCon "TQual" (PVar "inner") (PVar "auth")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkAuth") (EVar "name")) (EVar "authIds")) (EVar "auth")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "walkMono") (EVar "name")) (EVar "ids")) (EVar "effIds")) (EVar "authIds")) (EVar "inner")) (EVar "w"))))
(DFunDef false "walkMono" ((PVar "name") PWild PWild (PVar "authIds") (PCon "TAuth" (PVar "auth")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkAuth") (EVar "name")) (EVar "authIds")) (EVar "auth")) (EVar "w")))
(DFunDef false "walkMono" (PWild PWild PWild PWild PWild (PVar "w")) (EVar "w"))
(DTypeSig false "walkAuth" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Authority") (TyFun (TyCon "Walk") (TyCon "Walk"))))))
(DFunDef false "walkAuth" ((PVar "name") (PVar "authIds") (PCon "AVar" (PVar "cell")) (PVar "w")) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "ALink" (PVar "id") PWild PWild) () (EApp (EApp (EVar "push") (EApp (EApp (EApp (EVar "LinkCell") (EVar "name")) (EVar "AuthVarK")) (EApp (EVar "Some") (EVar "id")))) (EVar "w"))) (arm (PCon "AUnbound" (PVar "id") PWild PWild PWild PWild) () (EIf (EApp (EApp (EVar "hasId") (EVar "id")) (EVar "authIds")) (EVar "w") (EApp (EApp (EVar "push") (EApp (EApp (EApp (EVar "FreeMeta") (EVar "name")) (EVar "AuthVarK")) (EVar "id"))) (EVar "w"))))))
(DFunDef false "walkAuth" ((PVar "name") (PVar "authIds") (PCon "AJoin" (PVar "ms")) (PVar "w")) (EApp (EApp (EApp (EVar "foldWalk") (EApp (EApp (EVar "walkAuth") (EVar "name")) (EVar "authIds"))) (EVar "ms")) (EVar "w")))
(DFunDef false "walkAuth" ((PVar "name") (PVar "authIds") (PCon "AProduct" (PVar "axes")) (PVar "w")) (EApp (EApp (EApp (EVar "foldWalk") (ELam ((PVar "axis") (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "walkAuth") (EVar "name")) (EVar "authIds")) (EApp (EVar "snd") (EVar "axis"))) (EVar "acc")))) (EVar "axes")) (EVar "w")))
(DFunDef false "walkAuth" (PWild PWild PWild (PVar "w")) (EVar "w"))
(DTypeSig false "walkRow" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "EffRow") (TyFun (TyCon "Walk") (TyCon "Walk")))))))
(DFunDef false "walkRow" ((PVar "name") (PVar "effIds") (PVar "authIds") (PCon "EffRow" (PVar "atoms") (PVar "tail")) (PVar "w")) (EBlock (DoLet false false (PVar "w1") (EApp (EApp (EApp (EVar "foldWalk") (ELam ((PVar "atom") (PVar "acc")) (EMatch (EVar "atom") (arm (PCon "Atom" PWild (PVar "auth")) () (EApp (EApp (EApp (EApp (EVar "walkAuth") (EVar "name")) (EVar "authIds")) (EVar "auth")) (EVar "acc")))))) (EVar "atoms")) (EVar "w"))) (DoExpr (EMatch (EVar "tail") (arm (PCon "None") () (EVar "w1")) (arm (PCon "Some" (PVar "cell")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "walkEffCell") (EVar "name")) (EVar "effIds")) (EVar "authIds")) (EVar "False")) (EVar "cell")) (EVar "w1")))))))
(DTypeSig false "walkEffCell" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "Ref") (TyCon "Effvar")) (TyFun (TyCon "Walk") (TyCon "Walk"))))))))
(DFunDef false "walkEffCell" ((PVar "name") (PVar "effIds") (PVar "authIds") (PVar "member") (PVar "cell") (PAs "w" (PCon "Walk" (PVar "seen") (PVar "found")))) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "EUnbound" (PVar "id") PWild) () (EIf (EApp (EApp (EVar "hasId") (EVar "id")) (EVar "effIds")) (EVar "w") (EApp (EApp (EVar "push") (EApp (EApp (EApp (EVar "FreeMeta") (EVar "name")) (EVar "EffVarK")) (EVar "id"))) (EVar "w")))) (arm (PCon "ESummary" (PVar "id") PWild PWild) () (EApp (EApp (EVar "push") (EApp (EApp (EVar "OpenSummary") (EVar "name")) (EVar "id"))) (EVar "w"))) (arm (PCon "ELink" (PVar "id") (PVar "row")) () (EIf (EApp (EApp (EVar "IdMap.has") (EVar "id")) (EVar "seen")) (EVar "w") (EBlock (DoLet false false (PVar "w1") (EApp (EApp (EVar "Walk") (EApp (EApp (EApp (EVar "IdMap.set") (EVar "id")) (ELit LUnit)) (EVar "seen"))) (EVar "found"))) (DoLet false false (PVar "w2") (EIf (EVar "member") (EVar "w1") (EApp (EApp (EVar "push") (EApp (EApp (EApp (EVar "LinkCell") (EVar "name")) (EVar "EffVarK")) (EApp (EVar "Some") (EVar "id")))) (EVar "w1")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "walkRow") (EVar "name")) (EVar "effIds")) (EVar "authIds")) (EVar "row")) (EVar "w2")))))) (arm (PCon "EJoin" (PVar "id") PWild (PVar "members")) () (EIf (EApp (EApp (EVar "IdMap.has") (EVar "id")) (EVar "seen")) (EVar "w") (EApp (EApp (EApp (EVar "foldWalk") (EApp (EApp (EApp (EApp (EVar "walkEffCell") (EVar "name")) (EVar "effIds")) (EVar "authIds")) (EVar "True"))) (EVar "members")) (EApp (EApp (EVar "Walk") (EApp (EApp (EApp (EVar "IdMap.set") (EVar "id")) (ELit LUnit)) (EVar "seen"))) (EVar "found")))))))
