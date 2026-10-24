# META
source_lines=590
stages=DESUGAR,MARK
# SOURCE
import types.capability_manifest.{
  EntryKey(..),
  ManifestRequest(..),
  InvocationProtocol(..),
  CapabilityManifest(..),
  FrozenAtom(..),
  FrozenAuthority(..),
  FrozenVariable(..),
}
import types.effect_domain.{Param(..)}
import frontend.ast.{TyConOrigin(..)}
-- Structural S-expression dump of the Core IR (STAGE2-DESIGN §2.1).  Mirrors
-- sexp.mdk's style (AST dump) so the format is familiar; cprogramToSexp is the
-- canonical entry point and the frozen IR's serialization contract.
--
-- Losslessness: every field is serialized, including the lexical Addr on CVar
-- and the dispatch Routes on CMethod/CDict, so a parsed-back CProgram carries
-- the same structural information as the in-memory lowered program.
--
-- Sub-serializers are all exported so a future round-trip parser can import
-- them for cross-checking (parse-back → re-dump → assert identical output).

import ir.extern_types.{ExternDeclFact(..)}
import types.extern_source.{ExternBindingKind(..), ExternProvenance(..)}
import types.runtime_abi_types.{CallableShape(..)}
import support.ordmap.{omKeys, omLookup}
import frontend.ast.{Lit(..), Pat(..), Addr(..), Route(..)}
import ir.core_ir.{
  CExpr(..),
  MethodEvidence(..),
  CArm(..),
  CGuard(..),
  CStmt(..),
  CField(..),
  CBind(..),
  CClause(..),
  CImplEntry(..),
  CImplBody(..),
  ImplSym(..),
  CProgram(..),
  DeclFacts(..),
  EntryFact(..),
  MethodResultFact(..),
  CallMode(..),
  CallSite(..),
  CTree(..),
  CTBranch(..),
  CHead(..),
  programBinderIds,
}
import frontend.ast.{BinderId(..)}
import types.runtime_types.{BinderRow(..), binderOrdinal, runtimeTypeName}
import map as BM
import ir.sexp.{boolStr, node, slist, litSexp, patSexp}
import support.util.{escStr, joinNl, reverseL}

-- ── Addr and Route ─────────────────────────────────────────────────────────────

export
addrSexp : Addr -> String
addrSexp (ALocal frame slot) =
  node "ALocal" [intToString frame, intToString slot]
addrSexp AGlobal = "AGlobal"

-- ── SexpMode — which projection this serialization is (#686, #1954) ──────────
-- The choice is a value the caller passes, never a module-scope `Ref Bool` a
-- debug entry flips before calling `cprogramToSexp`, so the projection
-- a dump is in is visible at its call site and two dumps cannot fight over it.
-- Every serializer that can reach `routeSexp` takes one.
--
-- FAITHFUL-ROUTE mode (#686): `faithfulRoutes = True` makes `routeSexp` emit
-- `RKey`/`RLocal`'s nested `List Route` — the element/impl dicts — which the golden
-- projection deliberately drops.  Without it a null element route
-- (`RKey "List" [RNone]`) and a resolved one (`RKey "List" [RKey "Int" []]`)
-- serialize IDENTICALLY, so the typed-IR dump the docs bill as the highest-value
-- dict-route probe is blind to exactly the class of bug it is reached for (a null
-- element dict → build SIGSEGV, #410/#669).
export data SexpMode = SexpMode { faithfulRoutes : Bool }

-- The golden/round-trip projection — byte-identical to every committed
-- core_ir_sexp/snapshot golden, and what `cprogramToSexp` serializes in.
export
defaultSexpMode : SexpMode
defaultSexpMode = SexpMode { faithfulRoutes = False }

-- The faithful nested-route projection.  DEBUG-ONLY: never serialize a
-- golden-producing path (snapshot.mdk / round-trip) in this mode — it moves the
-- corpus.  Its one caller is core_ir_typed_modules_dump_main.mdk.
export
faithfulSexpMode : SexpMode
faithfulSexpMode = SexpMode { faithfulRoutes = True }

export
routeSexp : SexpMode -> Route -> String
routeSexp _ RNone = "RNone"
routeSexp m (RKey k ds sups) =
  if m.faithfulRoutes then
    node "RKey" [
      escStr k,
      slist (map (routeSexp m) ds),
      slist (map (routeSexp m) sups),
    ]
  else
    node "RKey" [escStr k]
routeSexp _ (RDict d) = node "RDict" [escStr d]
routeSexp _ (RDictFwd d) = node "RDictFwd" [escStr d]
-- S-1: the dict list is DROPPED in the DEFAULT projection, exactly as RKey's nested
-- requires-routes are — the S-expr form is a debug/golden projection, not a faithful
-- round-trip of the route.  Keeping it lossy holds every core_ir_sexp golden
-- byte-identical across the S-1 route widening.  The faithful arm (above/below) is
-- gated behind `SexpMode.faithfulRoutes` so ONLY the debug probe pays the widening.
routeSexp m (RLocal "" ds) =
  if m.faithfulRoutes then
    node "RLocal" [escStr "", slist (map (routeSexp m) ds)]
  else
    "RLocal"
routeSexp m (RLocal s ds) =
  if m.faithfulRoutes then
    node "RLocal" [escStr s, slist (map (routeSexp m) ds)]
  else
    node "RLocal" [escStr s]
routeSexp _ (RScalar s) = node "RScalar" [escStr s]
routeSexp m (RProj r path) =
  node "RProj" (routeSexp m r :: map intToString path)

-- ── CExpr ─────────────────────────────────────────────────────────────────────

export
callModeSexp : CallMode -> String
callModeSexp CallExact = "CallExact"
callModeSexp (CallPartial n) = node "CallPartial" [intToString n]
callModeSexp (CallOver n) = node "CallOver" [intToString n]
callModeSexp CallDynamic = "CallDynamic"

export
cexprSexp : SexpMode -> CExpr -> String
cexprSexp m (CLit l) = node "CLit" [litSexp l]
cexprSexp m (CVar x addr) = node "CVar" [escStr x, addrSexp addr]
cexprSexp m (CApp f args (CallSite mode tailPos)) = node "CApp" [
  cexprSexp m f,
  slist (map (cexprSexp m) args),
  callModeSexp mode,
  boolStr tailPos,
]
cexprSexp m (CLam pats body) =
  node "CLam" [slist (map patSexp pats), cexprSexp m body]
cexprSexp m (CLet isRec pat e1 e2) =
  node "CLet" [boolStr isRec, patSexp pat, cexprSexp m e1, cexprSexp m e2]
cexprSexp m (CLetGroup binds body) =
  node "CLetGroup" [slist (map (cbindSexp m) binds), cexprSexp m body]
cexprSexp m (CMatch scrut arms) =
  node "CMatch" (cexprSexp m scrut :: map (carmSexp m) arms)
cexprSexp m (CDecision scrut arms tree) = node "CDecision" [
  cexprSexp m scrut,
  slist (map (carmSexp m) arms),
  ctreeSexp tree,
]
cexprSexp m (CIf c t e) =
  node "CIf" [cexprSexp m c, cexprSexp m t, cexprSexp m e]
cexprSexp m (CBinPrim op l r tag _) =
  if tag == "" then
    node "CBinPrim" [escStr op, cexprSexp m l, cexprSexp m r]
  else
    node "CBinPrim" [escStr op, cexprSexp m l, cexprSexp m r, escStr tag]
cexprSexp m (CUnOp op e) = node "CUnOp" [escStr op, cexprSexp m e]
cexprSexp m (CTuple es) = node "CTuple" (map (cexprSexp m) es)
cexprSexp m (CList es) = node "CList" (map (cexprSexp m) es)
cexprSexp m (CRecord name fields) =
  node "CRecord" (escStr name :: map (cfieldSexp m) fields)
cexprSexp m (CFieldAccess e f n o) =
  node "CFieldAccess" [cexprSexp m e, escStr f, escStr n, intToString o]
cexprSexp m (CRecordUpdate name base fields) =
  node
    "CRecordUpdate"
    (escStr name :: cexprSexp m base :: map (cfieldSexp m) fields)
cexprSexp m (CVariantUpdate con base fields) =
  node
    "CVariantUpdate"
    (escStr con :: cexprSexp m base :: map (cfieldSexp m) fields)
cexprSexp m (CArray es) = node "CArray" (map (cexprSexp m) es)
cexprSexp m (CRangeList lo hi incl) =
  node "CRangeList" [cexprSexp m lo, cexprSexp m hi, boolStr incl]
cexprSexp m (CRangeArray lo hi incl) =
  node "CRangeArray" [cexprSexp m lo, cexprSexp m hi, boolStr incl]
cexprSexp m (CIndex a i) = node "CIndex" [cexprSexp m a, cexprSexp m i]
cexprSexp m (CSlice a lo hi incl) =
  node "CSlice" [cexprSexp m a, cexprSexp m lo, cexprSexp m hi, boolStr incl]
cexprSexp m (CStringIndex a i) =
  node "CStringIndex" [cexprSexp m a, cexprSexp m i]
cexprSexp m (CStringSlice a lo hi incl) = node "CStringSlice" [
  cexprSexp m a,
  cexprSexp m lo,
  cexprSexp m hi,
  boolStr incl,
]
cexprSexp m (CListIndex a i) = node "CListIndex" [cexprSexp m a, cexprSexp m i]
cexprSexp m (CListSlice a lo hi incl) = node "CListSlice" [
  cexprSexp m a,
  cexprSexp m lo,
  cexprSexp m hi,
  boolStr incl,
]
cexprSexp m (CBlock stmts) = node "CBlock" (map (cstmtSexp m) stmts)
cexprSexp m (CMethod name (MethodEvidence iface arity route implRoutes methRoutes)) = node
  "CMethod"
  [
    escStr name,
    escStr iface,
    intToString arity,
    routeSexp m route,
    slist (map (routeSexp m) implRoutes),
    slist (map (routeSexp m) methRoutes),
  ]
cexprSexp m (CDict name routes) =
  node "CDict" [escStr name, slist (map (routeSexp m) routes)]

-- ── CField ────────────────────────────────────────────────────────────────────

export
cfieldSexp : SexpMode -> CField -> String
cfieldSexp m (CField name o e) =
  node "cf" [escStr name, intToString o, cexprSexp m e]

-- ── CArm, CGuard ─────────────────────────────────────────────────────────────

export
carmSexp : SexpMode -> CArm -> String
carmSexp m (CArm pat guards body) =
  node "arm" [patSexp pat, slist (map (cguardSexp m) guards), cexprSexp m body]

export
cguardSexp : SexpMode -> CGuard -> String
cguardSexp m (CGBool e) = node "CGBool" [cexprSexp m e]
cguardSexp m (CGBind pat e) = node "CGBind" [patSexp pat, cexprSexp m e]

-- ── Decision tree ─────────────────────────────────────────────────────────────

export
ctreeSexp : CTree -> String
-- the miss site is not printed: the dump shows the tree's shape only
ctreeSexp (CTFail _) = "CTFail"
ctreeSexp (CTLeaf i) = node "CTLeaf" [intToString i]
ctreeSexp (CTGuard i fail) = node "CTGuard" [intToString i, ctreeSexp fail]
ctreeSexp (CTSwitch branches dflt) =
  node "CTSwitch" [slist (map ctbranchSexp branches), ctreeSexp dflt]
ctreeSexp (CTDrop tree) = node "CTDrop" [ctreeSexp tree]

export
ctbranchSexp : CTBranch -> String
ctbranchSexp (CTBranch head tree) =
  node "CTBranch" [cheadSexp head, ctreeSexp tree]

export
cheadSexp : CHead -> String
cheadSexp (HCon name arity) = node "HCon" [escStr name, intToString arity]
cheadSexp (HTuple arity) = node "HTuple" [intToString arity]
cheadSexp HCons = "HCons"
cheadSexp HNil = "HNil"
cheadSexp HUnit = "HUnit"
cheadSexp (HLit l) = node "HLit" [litSexp l]

-- ── CStmt ─────────────────────────────────────────────────────────────────────

export
cstmtSexp : SexpMode -> CStmt -> String
cstmtSexp m (CSExpr e) = node "CSExpr" [cexprSexp m e]
cstmtSexp m (CSLet isRec pat e) =
  node "CSLet" [boolStr isRec, patSexp pat, cexprSexp m e]
cstmtSexp m (CSAssign x e) = node "CSAssign" [escStr x, cexprSexp m e]

-- ── CBind, CClause ────────────────────────────────────────────────────────────

export
cbindSexp : SexpMode -> CBind -> String
cbindSexp m (CBind name clauses _ _) =
  node "CBind" (escStr name :: map (cclauseSexp m) clauses)

export
cclauseSexp : SexpMode -> CClause -> String
cclauseSexp m (CClause pats body) =
  node "CClause" [slist (map patSexp pats), cexprSexp m body]

-- ── CImplEntry, CImplBody ─────────────────────────────────────────────────────

implSymSexp : ImplSym -> String
implSymSexp (ImplSym tag ifaceTag keyTag) =
  slist [escStr tag, escStr ifaceTag, escStr keyTag]

export
cimplBodySexp : SexpMode -> CImplBody -> String
cimplBodySexp m (CImplTagged tag key iface sym positions pats body) = node
  "CImplTagged"
  [
    escStr tag,
    escStr key,
    escStr iface,
    implSymSexp sym,
    slist (map intToString positions),
    slist (map patSexp pats),
    cexprSexp m body,
  ]
cimplBodySexp m (CImplDefault ifaceId tag key sym positions pats body) = node
  "CImplDefault"
  [
    escStr ifaceId,
    escStr tag,
    escStr key,
    implSymSexp sym,
    slist (map intToString positions),
    slist (map patSexp pats),
    cexprSexp m body,
  ]

export
cimplEntrySexp : SexpMode -> CImplEntry -> String
cimplEntrySexp m (CImplEntry name score declared body) = node "CImplEntry" [
  escStr name,
  intToString score,
  intToString declared,
  cimplBodySexp m body,
]

-- ── CProgram ─────────────────────────────────────────────────────────────────

ctorArityPairSexp : (String, Int) -> String
ctorArityPairSexp (name, arity) = node "ca" [escStr name, intToString arity]

ctorTypePairSexp : (String, String) -> String
ctorTypePairSexp (ctor, ty) = node "ct" [escStr ctor, escStr ty]

-- One top-level CBind per line (not `slist`'s single-space join) — the whole
-- program is otherwise a single unbroken line (100+KB in real use), which
-- makes it unusable as a grep/less-navigable dict-routing probe (#1721). The
-- sexp tokenizer treats '\n' as ordinary whitespace (core_ir_sexp_parse.mdk),
-- so this is lossless for the roundtrip parser.
bindsSexp : SexpMode -> List CBind -> String
bindsSexp m binds = "(" ++ joinNl (map (cbindSexp m) binds) ++ ")"

-- The default (golden/round-trip) projection — the frozen serialization contract
-- and the shape every non-probe caller wants.  Unchanged signature: this is the
-- name snapshot.mdk, core_ir_dump_main and core_ir_roundtrip_main call.
export
cprogramToSexp : CProgram -> String
cprogramToSexp prog = cprogramToSexpWith defaultSexpMode prog

-- The mode-explicit seam.  `faithfulSexpMode` here is the debug projection that
-- would otherwise be reached by flipping an ambient flag first.
export
cprogramToSexpWith : SexpMode -> CProgram -> String
cprogramToSexpWith m (prog@(CProgram binds ctorArities ctorToType impls mctx facts)) =
  node
    "CProgram"
    ([
        bindsSexp m binds,
        slist (map ctorArityPairSexp ctorArities),
        slist (map ctorTypePairSexp ctorToType),
        slist (map (cimplEntrySexp m) impls),
      ]
      ++ tablesSexp mctx facts (binderTypesSexp prog))

-- The method-context table is written only when it has a row, so a program whose
-- interfaces declare no method context keeps the four-element form.  The
-- declaration facts are written only when they have a row, after the
-- method-context table, which is then written even when empty.  The binder-type
-- section follows both, which are then both written.
tablesSexp : List (String, Int) -> DeclFacts -> Option String -> List String
tablesSexp rows facts (Some binders) =
  [slist (map methodContextPairSexp rows), declFactsSexp facts, binders]
tablesSexp rows facts None = match (
  rows,
  facts.factRequires,
  facts.factSupers,
  facts.factMethodResults,
  facts.factEntryOutcome,
  omKeys facts.factExterns,
  facts.factManifests,
)
  ([], [], [], [], None, [], []) => []
  (_, [], [], [], None, [], []) => [slist (map methodContextPairSexp rows)]
  _ => [slist (map methodContextPairSexp rows), declFactsSexp facts]

declFactsSexp : DeclFacts -> String
declFactsSexp facts =
  if not (isEmpty (omKeys facts.factExterns))
    || not (isEmpty facts.factManifests) then
    node
      "facts"
      ([
          slist (map (factPairSexp "rq") facts.factRequires),
          slist (map (factPairSexp "sp") facts.factSupers),
          slist (map methodResultSexp facts.factMethodResults),
          optionOr "none" (map entryOutcomeSexp facts.factEntryOutcome),
          node
            "externs"
            (map
              (key => match omLookup key facts.factExterns
                Some fact => externSexp fact
                None => panic "extern inventory lost a row")
              (omKeys facts.factExterns)),
        ]
        ++ (if isEmpty facts.factManifests then
          []
        else
          [node "manifests" (map manifestSexp facts.factManifests)]))
  else
    node
      "facts"
      ([
          slist (map (factPairSexp "rq") facts.factRequires),
          slist (map (factPairSexp "sp") facts.factSupers),
        ]
        ++ (if isEmpty facts.factMethodResults
          && isNone facts.factEntryOutcome then
          []
        else
          [slist (map methodResultSexp facts.factMethodResults)])
        ++ (match facts.factEntryOutcome
          Some outcome => [entryOutcomeSexp outcome]
          None => []))

entryOutcomeSexp : EntryFact -> String
entryOutcomeSexp outcome = node "entry" [
  boolStr outcome.entryMainIsUnit,
  boolStr outcome.entryMainIsFloat,
]

methodResultSexp : MethodResultFact -> String
methodResultSexp row = node "mr" [
  escStr row.iface,
  escStr row.method,
  boolStr row.returnsHead,
  slist (map intToString row.callbackPositions),
  intToString row.valueArity,
]

factPairSexp : String -> (String, Int) -> String
factPairSexp tag (key, n) = node tag [escStr key, intToString n]

methodContextPairSexp : (String, Int) -> String
methodContextPairSexp (key, n) = node "mc" [escStr key, intToString n]

-- ── binder types ─────────────────────────────────────────────────────────────
-- `(binder-types [(ids n…)] (b i "module" "name" RT [RT])…)`.  A binder's ordinal
-- comes from a process-global counter, so it moves whenever any other program was
-- processed first; the dump renumbers the ids a program holds by first occurrence
-- in the binder walk (`core_ir.mapProgramBinders`), which is what makes it stable.
-- `ids` lists the renumbered id of each binder occurrence in walk order, and is
-- left out when that is 0, 1, 2…: every occurrence a distinct binder.  `-1` is a
-- binder with no id.  A row is `i`, the id's module, the binder's name, its type
-- and, for a function binder, the type its body returns; an id with no row has none.
-- The section is absent for a program with no binder.
binderTypesSexp : CProgram -> Option String
binderTypesSexp (prog@(CProgram _ _ _ _ _ facts)) =
  let ids = programBinderIds prog
  match ids
    [] => None
    _ =>
      let (occ, firsts) = denseIds ids BM.Tip 0 [] []
      let byOrd =
        BM.fromList (map (r => (binderOrdinal r.brId, r)) facts.factBinders)
      let rows = flatMap (binderRowSexp byOrd) (reverseL firsts)
      let idsPart =
        if isIdentity occ 0 then [] else [node "ids" (map intToString occ)]
      Some ("(" ++ joinNl ("binder-types" :: idsPart ++ rows) ++ ")")

-- Per-occurrence dense ids, and the distinct ids in order of first occurrence
-- paired with their dense id (both accumulated in reverse).
denseIds : List BinderId ->
  BM.Map Int Int ->
  Int ->
  List Int ->
  List (Int, BinderId) ->
  (List Int, List (Int, BinderId))
denseIds [] _ _ occ firsts = (reverseL occ, firsts)
denseIds ((bid@(BinderId _ n)) :: rest) seen next occ firsts
  | n < 0 = denseIds rest seen next (0 - 1 :: occ) firsts
  | otherwise = match BM.get n seen
    Some d => denseIds rest seen next (d :: occ) firsts
    None =>
      denseIds
        rest
        (BM.set n next seen)
        (next + 1)
        (next :: occ)
        ((next, bid) :: firsts)

isIdentity : List Int -> Int -> Bool
isIdentity [] _ = True
isIdentity (d :: rest) i = d == i && isIdentity rest (i + 1)

binderRowSexp : BM.Map Int BinderRow -> (Int, BinderId) -> List String
binderRowSexp byOrd (d, BinderId _ n) = match BM.get n byOrd
  None => []
  Some row => match row.brId
    BinderId m _ =>
      let ret = match row.brReturns
        None => []
        Some r => [runtimeTypeName r]
      -- a signed function's row ends in `signed`; every other row omits it
      let signed = if row.brSigned then ["signed"] else []
      [
        node
          "b"
          ([
              intToString d,
              escStr m,
              escStr row.brName,
              runtimeTypeName row.brType,
            ]
            ++ ret
            ++ signed),
      ]

externSexp : ExternDeclFact -> String
externSexp fact = node "extern" [
  escStr fact.symbol,
  escStr fact.originModule,
  escStr fact.declaredName,
  match fact.bindingKind
    ForeignBinding => "foreign"
    RuntimeBinding key => node "runtime" [escStr key],
  slist
    (map ((host, sym) => slist [escStr host, escStr sym]) fact.hostBindings),
  optionOr "missing-abi" (map shapeSexp fact.callableShape),
  match fact.provenance
    CheckedSource => "checked"
    RawSource => "raw"
    NoSourceSignature => "no-source-signature",
]

shapeSexp : CallableShape -> String
shapeSexp shape = node "abi" [
  intToString shape.writtenValueArity,
  intToString shape.loweredCoreArity,
  slist (map escStr shape.parameterHeads),
  escStr shape.resultHead,
  escStr shape.canonicalSignature,
]

manifestSexp : CapabilityManifest -> String
manifestSexp manifest = node "manifest" [
  escStr manifest.request.entry.moduleId,
  escStr manifest.request.entry.binding,
  match manifest.request.protocol
    HostInvocation => "host"
    ExecutedMain => "executed",
  slist (map frozenAtomSexp manifest.atoms),
]

frozenAtomSexp : FrozenAtom -> String
frozenAtomSexp atom = node "atom" [
  escStr atom.label,
  match atom.origin
    OriginBuiltin => "builtin"
    OriginUnresolved => "unresolved"
    OriginModule mid => node "module" [escStr mid],
  manifestParamSexp atom.domainTop,
  frozenAuthoritySexp atom.authority,
]

frozenAuthoritySexp : FrozenAuthority -> String
frozenAuthoritySexp (FrozenConst p) = node "const" [manifestParamSexp p]
frozenAuthoritySexp (FrozenVar v) = node "var" [
  intToString v.localId,
  manifestParamSexp v.domainTop,
  boolStr v.patternOnly,
  option "none" (name => node "some" [escStr name]) v.sourceName,
]
frozenAuthoritySexp (FrozenJoin members) =
  node "join" (map frozenAuthoritySexp members)
frozenAuthoritySexp (FrozenProduct axes) =
  node
    "product"
    (map
      ((name, authority) => slist [escStr name, frozenAuthoritySexp authority])
      axes)

manifestParamSexp : Param -> String
manifestParamSexp PUnit = "unit"
manifestParamSexp (PPrefix value) = node "prefix" [manifestStringSexp value]
manifestParamSexp (PPath value) = node "path" [manifestStringSexp value]
manifestParamSexp (PSet value) =
  node "set" [option "none" (members => node "some" (map escStr members)) value]
manifestParamSexp (PProduct axes) =
  node
    "axes"
    (map ((name, value) => slist [escStr name, manifestParamSexp value]) axes)

manifestStringSexp : Option String -> String
manifestStringSexp = option "none" (value => node "some" [escStr value])
# DESUGAR
(DUse false (UseGroup ("types" "capability_manifest") ((mem "EntryKey" true) (mem "ManifestRequest" true) (mem "InvocationProtocol" true) (mem "CapabilityManifest" true) (mem "FrozenAtom" true) (mem "FrozenAuthority" true) (mem "FrozenVariable" true))))
(DUse false (UseGroup ("types" "effect_domain") ((mem "Param" true))))
(DUse false (UseGroup ("frontend" "ast") ((mem "TyConOrigin" true))))
(DUse false (UseGroup ("ir" "extern_types") ((mem "ExternDeclFact" true))))
(DUse false (UseGroup ("types" "extern_source") ((mem "ExternBindingKind" true) (mem "ExternProvenance" true))))
(DUse false (UseGroup ("types" "runtime_abi_types") ((mem "CallableShape" true))))
(DUse false (UseGroup ("support" "ordmap") ((mem "omKeys" false) (mem "omLookup" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Lit" true) (mem "Pat" true) (mem "Addr" true) (mem "Route" true))))
(DUse false (UseGroup ("ir" "core_ir") ((mem "CExpr" true) (mem "MethodEvidence" true) (mem "CArm" true) (mem "CGuard" true) (mem "CStmt" true) (mem "CField" true) (mem "CBind" true) (mem "CClause" true) (mem "CImplEntry" true) (mem "CImplBody" true) (mem "ImplSym" true) (mem "CProgram" true) (mem "DeclFacts" true) (mem "EntryFact" true) (mem "MethodResultFact" true) (mem "CallMode" true) (mem "CallSite" true) (mem "CTree" true) (mem "CTBranch" true) (mem "CHead" true) (mem "programBinderIds" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "BinderId" true))))
(DUse false (UseGroup ("types" "runtime_types") ((mem "BinderRow" true) (mem "binderOrdinal" false) (mem "runtimeTypeName" false))))
(DUse false (UseAlias ("map") "BM"))
(DUse false (UseGroup ("ir" "sexp") ((mem "boolStr" false) (mem "node" false) (mem "slist" false) (mem "litSexp" false) (mem "patSexp" false))))
(DUse false (UseGroup ("support" "util") ((mem "escStr" false) (mem "joinNl" false) (mem "reverseL" false))))
(DTypeSig true "addrSexp" (TyFun (TyCon "Addr") (TyCon "String")))
(DFunDef false "addrSexp" ((PCon "ALocal" (PVar "frame") (PVar "slot"))) (EApp (EApp (EVar "node") (ELit (LString "ALocal"))) (EListLit (EApp (EVar "intToString") (EVar "frame")) (EApp (EVar "intToString") (EVar "slot")))))
(DFunDef false "addrSexp" ((PCon "AGlobal")) (ELit (LString "AGlobal")))
(DData Abstract "SexpMode" () ((variant "SexpMode" (ConNamed (field "faithfulRoutes" (TyCon "Bool"))))) ())
(DTypeSig true "defaultSexpMode" (TyCon "SexpMode"))
(DFunDef false "defaultSexpMode" () (ERecordCreate "SexpMode" ((fa "faithfulRoutes" (EVar "False")))))
(DTypeSig true "faithfulSexpMode" (TyCon "SexpMode"))
(DFunDef false "faithfulSexpMode" () (ERecordCreate "SexpMode" ((fa "faithfulRoutes" (EVar "True")))))
(DTypeSig true "routeSexp" (TyFun (TyCon "SexpMode") (TyFun (TyCon "Route") (TyCon "String"))))
(DFunDef false "routeSexp" (PWild (PCon "RNone")) (ELit (LString "RNone")))
(DFunDef false "routeSexp" ((PVar "m") (PCon "RKey" (PVar "k") (PVar "ds") (PVar "sups"))) (EIf (EFieldAccess (EVar "m") "faithfulRoutes") (EApp (EApp (EVar "node") (ELit (LString "RKey"))) (EListLit (EApp (EVar "escStr") (EVar "k")) (EApp (EVar "slist") (EApp (EApp (EVar "map") (EApp (EVar "routeSexp") (EVar "m"))) (EVar "ds"))) (EApp (EVar "slist") (EApp (EApp (EVar "map") (EApp (EVar "routeSexp") (EVar "m"))) (EVar "sups"))))) (EApp (EApp (EVar "node") (ELit (LString "RKey"))) (EListLit (EApp (EVar "escStr") (EVar "k"))))))
(DFunDef false "routeSexp" (PWild (PCon "RDict" (PVar "d"))) (EApp (EApp (EVar "node") (ELit (LString "RDict"))) (EListLit (EApp (EVar "escStr") (EVar "d")))))
(DFunDef false "routeSexp" (PWild (PCon "RDictFwd" (PVar "d"))) (EApp (EApp (EVar "node") (ELit (LString "RDictFwd"))) (EListLit (EApp (EVar "escStr") (EVar "d")))))
(DFunDef false "routeSexp" ((PVar "m") (PCon "RLocal" (PLit (LString "")) (PVar "ds"))) (EIf (EFieldAccess (EVar "m") "faithfulRoutes") (EApp (EApp (EVar "node") (ELit (LString "RLocal"))) (EListLit (EApp (EVar "escStr") (ELit (LString ""))) (EApp (EVar "slist") (EApp (EApp (EVar "map") (EApp (EVar "routeSexp") (EVar "m"))) (EVar "ds"))))) (ELit (LString "RLocal"))))
(DFunDef false "routeSexp" ((PVar "m") (PCon "RLocal" (PVar "s") (PVar "ds"))) (EIf (EFieldAccess (EVar "m") "faithfulRoutes") (EApp (EApp (EVar "node") (ELit (LString "RLocal"))) (EListLit (EApp (EVar "escStr") (EVar "s")) (EApp (EVar "slist") (EApp (EApp (EVar "map") (EApp (EVar "routeSexp") (EVar "m"))) (EVar "ds"))))) (EApp (EApp (EVar "node") (ELit (LString "RLocal"))) (EListLit (EApp (EVar "escStr") (EVar "s"))))))
(DFunDef false "routeSexp" (PWild (PCon "RScalar" (PVar "s"))) (EApp (EApp (EVar "node") (ELit (LString "RScalar"))) (EListLit (EApp (EVar "escStr") (EVar "s")))))
(DFunDef false "routeSexp" ((PVar "m") (PCon "RProj" (PVar "r") (PVar "path"))) (EApp (EApp (EVar "node") (ELit (LString "RProj"))) (EBinOp "::" (EApp (EApp (EVar "routeSexp") (EVar "m")) (EVar "r")) (EApp (EApp (EVar "map") (EVar "intToString")) (EVar "path")))))
(DTypeSig true "callModeSexp" (TyFun (TyCon "CallMode") (TyCon "String")))
(DFunDef false "callModeSexp" ((PCon "CallExact")) (ELit (LString "CallExact")))
(DFunDef false "callModeSexp" ((PCon "CallPartial" (PVar "n"))) (EApp (EApp (EVar "node") (ELit (LString "CallPartial"))) (EListLit (EApp (EVar "intToString") (EVar "n")))))
(DFunDef false "callModeSexp" ((PCon "CallOver" (PVar "n"))) (EApp (EApp (EVar "node") (ELit (LString "CallOver"))) (EListLit (EApp (EVar "intToString") (EVar "n")))))
(DFunDef false "callModeSexp" ((PCon "CallDynamic")) (ELit (LString "CallDynamic")))
(DTypeSig true "cexprSexp" (TyFun (TyCon "SexpMode") (TyFun (TyCon "CExpr") (TyCon "String"))))
(DFunDef false "cexprSexp" ((PVar "m") (PCon "CLit" (PVar "l"))) (EApp (EApp (EVar "node") (ELit (LString "CLit"))) (EListLit (EApp (EVar "litSexp") (EVar "l")))))
(DFunDef false "cexprSexp" ((PVar "m") (PCon "CVar" (PVar "x") (PVar "addr"))) (EApp (EApp (EVar "node") (ELit (LString "CVar"))) (EListLit (EApp (EVar "escStr") (EVar "x")) (EApp (EVar "addrSexp") (EVar "addr")))))
(DFunDef false "cexprSexp" ((PVar "m") (PCon "CApp" (PVar "f") (PVar "args") (PCon "CallSite" (PVar "mode") (PVar "tailPos")))) (EApp (EApp (EVar "node") (ELit (LString "CApp"))) (EListLit (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "f")) (EApp (EVar "slist") (EApp (EApp (EVar "map") (EApp (EVar "cexprSexp") (EVar "m"))) (EVar "args"))) (EApp (EVar "callModeSexp") (EVar "mode")) (EApp (EVar "boolStr") (EVar "tailPos")))))
(DFunDef false "cexprSexp" ((PVar "m") (PCon "CLam" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "node") (ELit (LString "CLam"))) (EListLit (EApp (EVar "slist") (EApp (EApp (EVar "map") (EVar "patSexp")) (EVar "pats"))) (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "body")))))
(DFunDef false "cexprSexp" ((PVar "m") (PCon "CLet" (PVar "isRec") (PVar "pat") (PVar "e1") (PVar "e2"))) (EApp (EApp (EVar "node") (ELit (LString "CLet"))) (EListLit (EApp (EVar "boolStr") (EVar "isRec")) (EApp (EVar "patSexp") (EVar "pat")) (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "e1")) (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "e2")))))
(DFunDef false "cexprSexp" ((PVar "m") (PCon "CLetGroup" (PVar "binds") (PVar "body"))) (EApp (EApp (EVar "node") (ELit (LString "CLetGroup"))) (EListLit (EApp (EVar "slist") (EApp (EApp (EVar "map") (EApp (EVar "cbindSexp") (EVar "m"))) (EVar "binds"))) (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "body")))))
(DFunDef false "cexprSexp" ((PVar "m") (PCon "CMatch" (PVar "scrut") (PVar "arms"))) (EApp (EApp (EVar "node") (ELit (LString "CMatch"))) (EBinOp "::" (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "scrut")) (EApp (EApp (EVar "map") (EApp (EVar "carmSexp") (EVar "m"))) (EVar "arms")))))
(DFunDef false "cexprSexp" ((PVar "m") (PCon "CDecision" (PVar "scrut") (PVar "arms") (PVar "tree"))) (EApp (EApp (EVar "node") (ELit (LString "CDecision"))) (EListLit (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "scrut")) (EApp (EVar "slist") (EApp (EApp (EVar "map") (EApp (EVar "carmSexp") (EVar "m"))) (EVar "arms"))) (EApp (EVar "ctreeSexp") (EVar "tree")))))
(DFunDef false "cexprSexp" ((PVar "m") (PCon "CIf" (PVar "c") (PVar "t") (PVar "e"))) (EApp (EApp (EVar "node") (ELit (LString "CIf"))) (EListLit (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "c")) (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "t")) (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "e")))))
(DFunDef false "cexprSexp" ((PVar "m") (PCon "CBinPrim" (PVar "op") (PVar "l") (PVar "r") (PVar "tag") PWild)) (EIf (EBinOp "==" (EVar "tag") (ELit (LString ""))) (EApp (EApp (EVar "node") (ELit (LString "CBinPrim"))) (EListLit (EApp (EVar "escStr") (EVar "op")) (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "l")) (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "r")))) (EApp (EApp (EVar "node") (ELit (LString "CBinPrim"))) (EListLit (EApp (EVar "escStr") (EVar "op")) (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "l")) (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "r")) (EApp (EVar "escStr") (EVar "tag"))))))
(DFunDef false "cexprSexp" ((PVar "m") (PCon "CUnOp" (PVar "op") (PVar "e"))) (EApp (EApp (EVar "node") (ELit (LString "CUnOp"))) (EListLit (EApp (EVar "escStr") (EVar "op")) (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "e")))))
(DFunDef false "cexprSexp" ((PVar "m") (PCon "CTuple" (PVar "es"))) (EApp (EApp (EVar "node") (ELit (LString "CTuple"))) (EApp (EApp (EVar "map") (EApp (EVar "cexprSexp") (EVar "m"))) (EVar "es"))))
(DFunDef false "cexprSexp" ((PVar "m") (PCon "CList" (PVar "es"))) (EApp (EApp (EVar "node") (ELit (LString "CList"))) (EApp (EApp (EVar "map") (EApp (EVar "cexprSexp") (EVar "m"))) (EVar "es"))))
(DFunDef false "cexprSexp" ((PVar "m") (PCon "CRecord" (PVar "name") (PVar "fields"))) (EApp (EApp (EVar "node") (ELit (LString "CRecord"))) (EBinOp "::" (EApp (EVar "escStr") (EVar "name")) (EApp (EApp (EVar "map") (EApp (EVar "cfieldSexp") (EVar "m"))) (EVar "fields")))))
(DFunDef false "cexprSexp" ((PVar "m") (PCon "CFieldAccess" (PVar "e") (PVar "f") (PVar "n") (PVar "o"))) (EApp (EApp (EVar "node") (ELit (LString "CFieldAccess"))) (EListLit (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "e")) (EApp (EVar "escStr") (EVar "f")) (EApp (EVar "escStr") (EVar "n")) (EApp (EVar "intToString") (EVar "o")))))
(DFunDef false "cexprSexp" ((PVar "m") (PCon "CRecordUpdate" (PVar "name") (PVar "base") (PVar "fields"))) (EApp (EApp (EVar "node") (ELit (LString "CRecordUpdate"))) (EBinOp "::" (EApp (EVar "escStr") (EVar "name")) (EBinOp "::" (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "base")) (EApp (EApp (EVar "map") (EApp (EVar "cfieldSexp") (EVar "m"))) (EVar "fields"))))))
(DFunDef false "cexprSexp" ((PVar "m") (PCon "CVariantUpdate" (PVar "con") (PVar "base") (PVar "fields"))) (EApp (EApp (EVar "node") (ELit (LString "CVariantUpdate"))) (EBinOp "::" (EApp (EVar "escStr") (EVar "con")) (EBinOp "::" (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "base")) (EApp (EApp (EVar "map") (EApp (EVar "cfieldSexp") (EVar "m"))) (EVar "fields"))))))
(DFunDef false "cexprSexp" ((PVar "m") (PCon "CArray" (PVar "es"))) (EApp (EApp (EVar "node") (ELit (LString "CArray"))) (EApp (EApp (EVar "map") (EApp (EVar "cexprSexp") (EVar "m"))) (EVar "es"))))
(DFunDef false "cexprSexp" ((PVar "m") (PCon "CRangeList" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EVar "node") (ELit (LString "CRangeList"))) (EListLit (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "lo")) (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "hi")) (EApp (EVar "boolStr") (EVar "incl")))))
(DFunDef false "cexprSexp" ((PVar "m") (PCon "CRangeArray" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EVar "node") (ELit (LString "CRangeArray"))) (EListLit (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "lo")) (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "hi")) (EApp (EVar "boolStr") (EVar "incl")))))
(DFunDef false "cexprSexp" ((PVar "m") (PCon "CIndex" (PVar "a") (PVar "i"))) (EApp (EApp (EVar "node") (ELit (LString "CIndex"))) (EListLit (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "a")) (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "i")))))
(DFunDef false "cexprSexp" ((PVar "m") (PCon "CSlice" (PVar "a") (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EVar "node") (ELit (LString "CSlice"))) (EListLit (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "a")) (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "lo")) (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "hi")) (EApp (EVar "boolStr") (EVar "incl")))))
(DFunDef false "cexprSexp" ((PVar "m") (PCon "CStringIndex" (PVar "a") (PVar "i"))) (EApp (EApp (EVar "node") (ELit (LString "CStringIndex"))) (EListLit (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "a")) (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "i")))))
(DFunDef false "cexprSexp" ((PVar "m") (PCon "CStringSlice" (PVar "a") (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EVar "node") (ELit (LString "CStringSlice"))) (EListLit (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "a")) (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "lo")) (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "hi")) (EApp (EVar "boolStr") (EVar "incl")))))
(DFunDef false "cexprSexp" ((PVar "m") (PCon "CListIndex" (PVar "a") (PVar "i"))) (EApp (EApp (EVar "node") (ELit (LString "CListIndex"))) (EListLit (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "a")) (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "i")))))
(DFunDef false "cexprSexp" ((PVar "m") (PCon "CListSlice" (PVar "a") (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EVar "node") (ELit (LString "CListSlice"))) (EListLit (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "a")) (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "lo")) (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "hi")) (EApp (EVar "boolStr") (EVar "incl")))))
(DFunDef false "cexprSexp" ((PVar "m") (PCon "CBlock" (PVar "stmts"))) (EApp (EApp (EVar "node") (ELit (LString "CBlock"))) (EApp (EApp (EVar "map") (EApp (EVar "cstmtSexp") (EVar "m"))) (EVar "stmts"))))
(DFunDef false "cexprSexp" ((PVar "m") (PCon "CMethod" (PVar "name") (PCon "MethodEvidence" (PVar "iface") (PVar "arity") (PVar "route") (PVar "implRoutes") (PVar "methRoutes")))) (EApp (EApp (EVar "node") (ELit (LString "CMethod"))) (EListLit (EApp (EVar "escStr") (EVar "name")) (EApp (EVar "escStr") (EVar "iface")) (EApp (EVar "intToString") (EVar "arity")) (EApp (EApp (EVar "routeSexp") (EVar "m")) (EVar "route")) (EApp (EVar "slist") (EApp (EApp (EVar "map") (EApp (EVar "routeSexp") (EVar "m"))) (EVar "implRoutes"))) (EApp (EVar "slist") (EApp (EApp (EVar "map") (EApp (EVar "routeSexp") (EVar "m"))) (EVar "methRoutes"))))))
(DFunDef false "cexprSexp" ((PVar "m") (PCon "CDict" (PVar "name") (PVar "routes"))) (EApp (EApp (EVar "node") (ELit (LString "CDict"))) (EListLit (EApp (EVar "escStr") (EVar "name")) (EApp (EVar "slist") (EApp (EApp (EVar "map") (EApp (EVar "routeSexp") (EVar "m"))) (EVar "routes"))))))
(DTypeSig true "cfieldSexp" (TyFun (TyCon "SexpMode") (TyFun (TyCon "CField") (TyCon "String"))))
(DFunDef false "cfieldSexp" ((PVar "m") (PCon "CField" (PVar "name") (PVar "o") (PVar "e"))) (EApp (EApp (EVar "node") (ELit (LString "cf"))) (EListLit (EApp (EVar "escStr") (EVar "name")) (EApp (EVar "intToString") (EVar "o")) (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "e")))))
(DTypeSig true "carmSexp" (TyFun (TyCon "SexpMode") (TyFun (TyCon "CArm") (TyCon "String"))))
(DFunDef false "carmSexp" ((PVar "m") (PCon "CArm" (PVar "pat") (PVar "guards") (PVar "body"))) (EApp (EApp (EVar "node") (ELit (LString "arm"))) (EListLit (EApp (EVar "patSexp") (EVar "pat")) (EApp (EVar "slist") (EApp (EApp (EVar "map") (EApp (EVar "cguardSexp") (EVar "m"))) (EVar "guards"))) (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "body")))))
(DTypeSig true "cguardSexp" (TyFun (TyCon "SexpMode") (TyFun (TyCon "CGuard") (TyCon "String"))))
(DFunDef false "cguardSexp" ((PVar "m") (PCon "CGBool" (PVar "e"))) (EApp (EApp (EVar "node") (ELit (LString "CGBool"))) (EListLit (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "e")))))
(DFunDef false "cguardSexp" ((PVar "m") (PCon "CGBind" (PVar "pat") (PVar "e"))) (EApp (EApp (EVar "node") (ELit (LString "CGBind"))) (EListLit (EApp (EVar "patSexp") (EVar "pat")) (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "e")))))
(DTypeSig true "ctreeSexp" (TyFun (TyCon "CTree") (TyCon "String")))
(DFunDef false "ctreeSexp" ((PCon "CTFail" PWild)) (ELit (LString "CTFail")))
(DFunDef false "ctreeSexp" ((PCon "CTLeaf" (PVar "i"))) (EApp (EApp (EVar "node") (ELit (LString "CTLeaf"))) (EListLit (EApp (EVar "intToString") (EVar "i")))))
(DFunDef false "ctreeSexp" ((PCon "CTGuard" (PVar "i") (PVar "fail"))) (EApp (EApp (EVar "node") (ELit (LString "CTGuard"))) (EListLit (EApp (EVar "intToString") (EVar "i")) (EApp (EVar "ctreeSexp") (EVar "fail")))))
(DFunDef false "ctreeSexp" ((PCon "CTSwitch" (PVar "branches") (PVar "dflt"))) (EApp (EApp (EVar "node") (ELit (LString "CTSwitch"))) (EListLit (EApp (EVar "slist") (EApp (EApp (EVar "map") (EVar "ctbranchSexp")) (EVar "branches"))) (EApp (EVar "ctreeSexp") (EVar "dflt")))))
(DFunDef false "ctreeSexp" ((PCon "CTDrop" (PVar "tree"))) (EApp (EApp (EVar "node") (ELit (LString "CTDrop"))) (EListLit (EApp (EVar "ctreeSexp") (EVar "tree")))))
(DTypeSig true "ctbranchSexp" (TyFun (TyCon "CTBranch") (TyCon "String")))
(DFunDef false "ctbranchSexp" ((PCon "CTBranch" (PVar "head") (PVar "tree"))) (EApp (EApp (EVar "node") (ELit (LString "CTBranch"))) (EListLit (EApp (EVar "cheadSexp") (EVar "head")) (EApp (EVar "ctreeSexp") (EVar "tree")))))
(DTypeSig true "cheadSexp" (TyFun (TyCon "CHead") (TyCon "String")))
(DFunDef false "cheadSexp" ((PCon "HCon" (PVar "name") (PVar "arity"))) (EApp (EApp (EVar "node") (ELit (LString "HCon"))) (EListLit (EApp (EVar "escStr") (EVar "name")) (EApp (EVar "intToString") (EVar "arity")))))
(DFunDef false "cheadSexp" ((PCon "HTuple" (PVar "arity"))) (EApp (EApp (EVar "node") (ELit (LString "HTuple"))) (EListLit (EApp (EVar "intToString") (EVar "arity")))))
(DFunDef false "cheadSexp" ((PCon "HCons")) (ELit (LString "HCons")))
(DFunDef false "cheadSexp" ((PCon "HNil")) (ELit (LString "HNil")))
(DFunDef false "cheadSexp" ((PCon "HUnit")) (ELit (LString "HUnit")))
(DFunDef false "cheadSexp" ((PCon "HLit" (PVar "l"))) (EApp (EApp (EVar "node") (ELit (LString "HLit"))) (EListLit (EApp (EVar "litSexp") (EVar "l")))))
(DTypeSig true "cstmtSexp" (TyFun (TyCon "SexpMode") (TyFun (TyCon "CStmt") (TyCon "String"))))
(DFunDef false "cstmtSexp" ((PVar "m") (PCon "CSExpr" (PVar "e"))) (EApp (EApp (EVar "node") (ELit (LString "CSExpr"))) (EListLit (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "e")))))
(DFunDef false "cstmtSexp" ((PVar "m") (PCon "CSLet" (PVar "isRec") (PVar "pat") (PVar "e"))) (EApp (EApp (EVar "node") (ELit (LString "CSLet"))) (EListLit (EApp (EVar "boolStr") (EVar "isRec")) (EApp (EVar "patSexp") (EVar "pat")) (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "e")))))
(DFunDef false "cstmtSexp" ((PVar "m") (PCon "CSAssign" (PVar "x") (PVar "e"))) (EApp (EApp (EVar "node") (ELit (LString "CSAssign"))) (EListLit (EApp (EVar "escStr") (EVar "x")) (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "e")))))
(DTypeSig true "cbindSexp" (TyFun (TyCon "SexpMode") (TyFun (TyCon "CBind") (TyCon "String"))))
(DFunDef false "cbindSexp" ((PVar "m") (PCon "CBind" (PVar "name") (PVar "clauses") PWild PWild)) (EApp (EApp (EVar "node") (ELit (LString "CBind"))) (EBinOp "::" (EApp (EVar "escStr") (EVar "name")) (EApp (EApp (EVar "map") (EApp (EVar "cclauseSexp") (EVar "m"))) (EVar "clauses")))))
(DTypeSig true "cclauseSexp" (TyFun (TyCon "SexpMode") (TyFun (TyCon "CClause") (TyCon "String"))))
(DFunDef false "cclauseSexp" ((PVar "m") (PCon "CClause" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "node") (ELit (LString "CClause"))) (EListLit (EApp (EVar "slist") (EApp (EApp (EVar "map") (EVar "patSexp")) (EVar "pats"))) (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "body")))))
(DTypeSig false "implSymSexp" (TyFun (TyCon "ImplSym") (TyCon "String")))
(DFunDef false "implSymSexp" ((PCon "ImplSym" (PVar "tag") (PVar "ifaceTag") (PVar "keyTag"))) (EApp (EVar "slist") (EListLit (EApp (EVar "escStr") (EVar "tag")) (EApp (EVar "escStr") (EVar "ifaceTag")) (EApp (EVar "escStr") (EVar "keyTag")))))
(DTypeSig true "cimplBodySexp" (TyFun (TyCon "SexpMode") (TyFun (TyCon "CImplBody") (TyCon "String"))))
(DFunDef false "cimplBodySexp" ((PVar "m") (PCon "CImplTagged" (PVar "tag") (PVar "key") (PVar "iface") (PVar "sym") (PVar "positions") (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "node") (ELit (LString "CImplTagged"))) (EListLit (EApp (EVar "escStr") (EVar "tag")) (EApp (EVar "escStr") (EVar "key")) (EApp (EVar "escStr") (EVar "iface")) (EApp (EVar "implSymSexp") (EVar "sym")) (EApp (EVar "slist") (EApp (EApp (EVar "map") (EVar "intToString")) (EVar "positions"))) (EApp (EVar "slist") (EApp (EApp (EVar "map") (EVar "patSexp")) (EVar "pats"))) (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "body")))))
(DFunDef false "cimplBodySexp" ((PVar "m") (PCon "CImplDefault" (PVar "ifaceId") (PVar "tag") (PVar "key") (PVar "sym") (PVar "positions") (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "node") (ELit (LString "CImplDefault"))) (EListLit (EApp (EVar "escStr") (EVar "ifaceId")) (EApp (EVar "escStr") (EVar "tag")) (EApp (EVar "escStr") (EVar "key")) (EApp (EVar "implSymSexp") (EVar "sym")) (EApp (EVar "slist") (EApp (EApp (EVar "map") (EVar "intToString")) (EVar "positions"))) (EApp (EVar "slist") (EApp (EApp (EVar "map") (EVar "patSexp")) (EVar "pats"))) (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "body")))))
(DTypeSig true "cimplEntrySexp" (TyFun (TyCon "SexpMode") (TyFun (TyCon "CImplEntry") (TyCon "String"))))
(DFunDef false "cimplEntrySexp" ((PVar "m") (PCon "CImplEntry" (PVar "name") (PVar "score") (PVar "declared") (PVar "body"))) (EApp (EApp (EVar "node") (ELit (LString "CImplEntry"))) (EListLit (EApp (EVar "escStr") (EVar "name")) (EApp (EVar "intToString") (EVar "score")) (EApp (EVar "intToString") (EVar "declared")) (EApp (EApp (EVar "cimplBodySexp") (EVar "m")) (EVar "body")))))
(DTypeSig false "ctorArityPairSexp" (TyFun (TyTuple (TyCon "String") (TyCon "Int")) (TyCon "String")))
(DFunDef false "ctorArityPairSexp" ((PTuple (PVar "name") (PVar "arity"))) (EApp (EApp (EVar "node") (ELit (LString "ca"))) (EListLit (EApp (EVar "escStr") (EVar "name")) (EApp (EVar "intToString") (EVar "arity")))))
(DTypeSig false "ctorTypePairSexp" (TyFun (TyTuple (TyCon "String") (TyCon "String")) (TyCon "String")))
(DFunDef false "ctorTypePairSexp" ((PTuple (PVar "ctor") (PVar "ty"))) (EApp (EApp (EVar "node") (ELit (LString "ct"))) (EListLit (EApp (EVar "escStr") (EVar "ctor")) (EApp (EVar "escStr") (EVar "ty")))))
(DTypeSig false "bindsSexp" (TyFun (TyCon "SexpMode") (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyCon "String"))))
(DFunDef false "bindsSexp" ((PVar "m") (PVar "binds")) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EVar "joinNl") (EApp (EApp (EVar "map") (EApp (EVar "cbindSexp") (EVar "m"))) (EVar "binds")))) (ELit (LString ")"))))
(DTypeSig true "cprogramToSexp" (TyFun (TyCon "CProgram") (TyCon "String")))
(DFunDef false "cprogramToSexp" ((PVar "prog")) (EApp (EApp (EVar "cprogramToSexpWith") (EVar "defaultSexpMode")) (EVar "prog")))
(DTypeSig true "cprogramToSexpWith" (TyFun (TyCon "SexpMode") (TyFun (TyCon "CProgram") (TyCon "String"))))
(DFunDef false "cprogramToSexpWith" ((PVar "m") (PAs "prog" (PCon "CProgram" (PVar "binds") (PVar "ctorArities") (PVar "ctorToType") (PVar "impls") (PVar "mctx") (PVar "facts")))) (EApp (EApp (EVar "node") (ELit (LString "CProgram"))) (EBinOp "++" (EListLit (EApp (EApp (EVar "bindsSexp") (EVar "m")) (EVar "binds")) (EApp (EVar "slist") (EApp (EApp (EVar "map") (EVar "ctorArityPairSexp")) (EVar "ctorArities"))) (EApp (EVar "slist") (EApp (EApp (EVar "map") (EVar "ctorTypePairSexp")) (EVar "ctorToType"))) (EApp (EVar "slist") (EApp (EApp (EVar "map") (EApp (EVar "cimplEntrySexp") (EVar "m"))) (EVar "impls")))) (EApp (EApp (EApp (EVar "tablesSexp") (EVar "mctx")) (EVar "facts")) (EApp (EVar "binderTypesSexp") (EVar "prog"))))))
(DTypeSig false "tablesSexp" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyCon "DeclFacts") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "tablesSexp" ((PVar "rows") (PVar "facts") (PCon "Some" (PVar "binders"))) (EListLit (EApp (EVar "slist") (EApp (EApp (EVar "map") (EVar "methodContextPairSexp")) (EVar "rows"))) (EApp (EVar "declFactsSexp") (EVar "facts")) (EVar "binders")))
(DFunDef false "tablesSexp" ((PVar "rows") (PVar "facts") (PCon "None")) (EMatch (ETuple (EVar "rows") (EFieldAccess (EVar "facts") "factRequires") (EFieldAccess (EVar "facts") "factSupers") (EFieldAccess (EVar "facts") "factMethodResults") (EFieldAccess (EVar "facts") "factEntryOutcome") (EApp (EVar "omKeys") (EFieldAccess (EVar "facts") "factExterns")) (EFieldAccess (EVar "facts") "factManifests")) (arm (PTuple (PList) (PList) (PList) (PList) (PCon "None") (PList) (PList)) () (EListLit)) (arm (PTuple PWild (PList) (PList) (PList) (PCon "None") (PList) (PList)) () (EListLit (EApp (EVar "slist") (EApp (EApp (EVar "map") (EVar "methodContextPairSexp")) (EVar "rows"))))) (arm PWild () (EListLit (EApp (EVar "slist") (EApp (EApp (EVar "map") (EVar "methodContextPairSexp")) (EVar "rows"))) (EApp (EVar "declFactsSexp") (EVar "facts"))))))
(DTypeSig false "declFactsSexp" (TyFun (TyCon "DeclFacts") (TyCon "String")))
(DFunDef false "declFactsSexp" ((PVar "facts")) (EIf (EBinOp "||" (EApp (EVar "not") (EApp (EVar "isEmpty") (EApp (EVar "omKeys") (EFieldAccess (EVar "facts") "factExterns")))) (EApp (EVar "not") (EApp (EVar "isEmpty") (EFieldAccess (EVar "facts") "factManifests")))) (EApp (EApp (EVar "node") (ELit (LString "facts"))) (EBinOp "++" (EListLit (EApp (EVar "slist") (EApp (EApp (EVar "map") (EApp (EVar "factPairSexp") (ELit (LString "rq")))) (EFieldAccess (EVar "facts") "factRequires"))) (EApp (EVar "slist") (EApp (EApp (EVar "map") (EApp (EVar "factPairSexp") (ELit (LString "sp")))) (EFieldAccess (EVar "facts") "factSupers"))) (EApp (EVar "slist") (EApp (EApp (EVar "map") (EVar "methodResultSexp")) (EFieldAccess (EVar "facts") "factMethodResults"))) (EApp (EApp (EVar "optionOr") (ELit (LString "none"))) (EApp (EApp (EVar "map") (EVar "entryOutcomeSexp")) (EFieldAccess (EVar "facts") "factEntryOutcome"))) (EApp (EApp (EVar "node") (ELit (LString "externs"))) (EApp (EApp (EVar "map") (ELam ((PVar "key")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "key")) (EFieldAccess (EVar "facts") "factExterns")) (arm (PCon "Some" (PVar "fact")) () (EApp (EVar "externSexp") (EVar "fact"))) (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "extern inventory lost a row"))))))) (EApp (EVar "omKeys") (EFieldAccess (EVar "facts") "factExterns"))))) (EIf (EApp (EVar "isEmpty") (EFieldAccess (EVar "facts") "factManifests")) (EListLit) (EListLit (EApp (EApp (EVar "node") (ELit (LString "manifests"))) (EApp (EApp (EVar "map") (EVar "manifestSexp")) (EFieldAccess (EVar "facts") "factManifests"))))))) (EApp (EApp (EVar "node") (ELit (LString "facts"))) (EBinOp "++" (EBinOp "++" (EListLit (EApp (EVar "slist") (EApp (EApp (EVar "map") (EApp (EVar "factPairSexp") (ELit (LString "rq")))) (EFieldAccess (EVar "facts") "factRequires"))) (EApp (EVar "slist") (EApp (EApp (EVar "map") (EApp (EVar "factPairSexp") (ELit (LString "sp")))) (EFieldAccess (EVar "facts") "factSupers")))) (EIf (EBinOp "&&" (EApp (EVar "isEmpty") (EFieldAccess (EVar "facts") "factMethodResults")) (EApp (EVar "isNone") (EFieldAccess (EVar "facts") "factEntryOutcome"))) (EListLit) (EListLit (EApp (EVar "slist") (EApp (EApp (EVar "map") (EVar "methodResultSexp")) (EFieldAccess (EVar "facts") "factMethodResults")))))) (EMatch (EFieldAccess (EVar "facts") "factEntryOutcome") (arm (PCon "Some" (PVar "outcome")) () (EListLit (EApp (EVar "entryOutcomeSexp") (EVar "outcome")))) (arm (PCon "None") () (EListLit)))))))
(DTypeSig false "entryOutcomeSexp" (TyFun (TyCon "EntryFact") (TyCon "String")))
(DFunDef false "entryOutcomeSexp" ((PVar "outcome")) (EApp (EApp (EVar "node") (ELit (LString "entry"))) (EListLit (EApp (EVar "boolStr") (EFieldAccess (EVar "outcome") "entryMainIsUnit")) (EApp (EVar "boolStr") (EFieldAccess (EVar "outcome") "entryMainIsFloat")))))
(DTypeSig false "methodResultSexp" (TyFun (TyCon "MethodResultFact") (TyCon "String")))
(DFunDef false "methodResultSexp" ((PVar "row")) (EApp (EApp (EVar "node") (ELit (LString "mr"))) (EListLit (EApp (EVar "escStr") (EFieldAccess (EVar "row") "iface")) (EApp (EVar "escStr") (EFieldAccess (EVar "row") "method")) (EApp (EVar "boolStr") (EFieldAccess (EVar "row") "returnsHead")) (EApp (EVar "slist") (EApp (EApp (EVar "map") (EVar "intToString")) (EFieldAccess (EVar "row") "callbackPositions"))) (EApp (EVar "intToString") (EFieldAccess (EVar "row") "valueArity")))))
(DTypeSig false "factPairSexp" (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "String") (TyCon "Int")) (TyCon "String"))))
(DFunDef false "factPairSexp" ((PVar "tag") (PTuple (PVar "key") (PVar "n"))) (EApp (EApp (EVar "node") (EVar "tag")) (EListLit (EApp (EVar "escStr") (EVar "key")) (EApp (EVar "intToString") (EVar "n")))))
(DTypeSig false "methodContextPairSexp" (TyFun (TyTuple (TyCon "String") (TyCon "Int")) (TyCon "String")))
(DFunDef false "methodContextPairSexp" ((PTuple (PVar "key") (PVar "n"))) (EApp (EApp (EVar "node") (ELit (LString "mc"))) (EListLit (EApp (EVar "escStr") (EVar "key")) (EApp (EVar "intToString") (EVar "n")))))
(DTypeSig false "binderTypesSexp" (TyFun (TyCon "CProgram") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "binderTypesSexp" ((PAs "prog" (PCon "CProgram" PWild PWild PWild PWild PWild (PVar "facts")))) (EBlock (DoLet false false (PVar "ids") (EApp (EVar "programBinderIds") (EVar "prog"))) (DoExpr (EMatch (EVar "ids") (arm (PList) () (EVar "None")) (arm PWild () (EBlock (DoLet false false (PTuple (PVar "occ") (PVar "firsts")) (EApp (EApp (EApp (EApp (EApp (EVar "denseIds") (EVar "ids")) (EVar "BM.Tip")) (ELit (LInt 0))) (EListLit)) (EListLit))) (DoLet false false (PVar "byOrd") (EApp (EVar "BM.fromList") (EApp (EApp (EVar "map") (ELam ((PVar "r")) (ETuple (EApp (EVar "binderOrdinal") (EFieldAccess (EVar "r") "brId")) (EVar "r")))) (EFieldAccess (EVar "facts") "factBinders")))) (DoLet false false (PVar "rows") (EApp (EApp (EVar "flatMap") (EApp (EVar "binderRowSexp") (EVar "byOrd"))) (EApp (EVar "reverseL") (EVar "firsts")))) (DoLet false false (PVar "idsPart") (EIf (EApp (EApp (EVar "isIdentity") (EVar "occ")) (ELit (LInt 0))) (EListLit) (EListLit (EApp (EApp (EVar "node") (ELit (LString "ids"))) (EApp (EApp (EVar "map") (EVar "intToString")) (EVar "occ")))))) (DoExpr (EApp (EVar "Some") (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EVar "joinNl") (EBinOp "::" (ELit (LString "binder-types")) (EBinOp "++" (EVar "idsPart") (EVar "rows"))))) (ELit (LString ")")))))))))))
(DTypeSig false "denseIds" (TyFun (TyApp (TyCon "List") (TyCon "BinderId")) (TyFun (TyApp (TyApp (TyCon "BM.Map") (TyCon "Int")) (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "BinderId"))) (TyTuple (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "BinderId"))))))))))
(DFunDef false "denseIds" ((PList) PWild PWild (PVar "occ") (PVar "firsts")) (ETuple (EApp (EVar "reverseL") (EVar "occ")) (EVar "firsts")))
(DFunDef false "denseIds" ((PCons (PAs "bid" (PCon "BinderId" PWild (PVar "n"))) (PVar "rest")) (PVar "seen") (PVar "next") (PVar "occ") (PVar "firsts")) (EIf (EBinOp "<" (EVar "n") (ELit (LInt 0))) (EApp (EApp (EApp (EApp (EApp (EVar "denseIds") (EVar "rest")) (EVar "seen")) (EVar "next")) (EBinOp "::" (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1))) (EVar "occ"))) (EVar "firsts")) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "BM.get") (EVar "n")) (EVar "seen")) (arm (PCon "Some" (PVar "d")) () (EApp (EApp (EApp (EApp (EApp (EVar "denseIds") (EVar "rest")) (EVar "seen")) (EVar "next")) (EBinOp "::" (EVar "d") (EVar "occ"))) (EVar "firsts"))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EVar "denseIds") (EVar "rest")) (EApp (EApp (EApp (EVar "BM.set") (EVar "n")) (EVar "next")) (EVar "seen"))) (EBinOp "+" (EVar "next") (ELit (LInt 1)))) (EBinOp "::" (EVar "next") (EVar "occ"))) (EBinOp "::" (ETuple (EVar "next") (EVar "bid")) (EVar "firsts"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "isIdentity" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "isIdentity" ((PList) PWild) (EVar "True"))
(DFunDef false "isIdentity" ((PCons (PVar "d") (PVar "rest")) (PVar "i")) (EBinOp "&&" (EBinOp "==" (EVar "d") (EVar "i")) (EApp (EApp (EVar "isIdentity") (EVar "rest")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))
(DTypeSig false "binderRowSexp" (TyFun (TyApp (TyApp (TyCon "BM.Map") (TyCon "Int")) (TyCon "BinderRow")) (TyFun (TyTuple (TyCon "Int") (TyCon "BinderId")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "binderRowSexp" ((PVar "byOrd") (PTuple (PVar "d") (PCon "BinderId" PWild (PVar "n")))) (EMatch (EApp (EApp (EVar "BM.get") (EVar "n")) (EVar "byOrd")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "row")) () (EMatch (EFieldAccess (EVar "row") "brId") (arm (PCon "BinderId" (PVar "m") PWild) () (EBlock (DoLet false false (PVar "ret") (EMatch (EFieldAccess (EVar "row") "brReturns") (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "r")) () (EListLit (EApp (EVar "runtimeTypeName") (EVar "r")))))) (DoLet false false (PVar "signed") (EIf (EFieldAccess (EVar "row") "brSigned") (EListLit (ELit (LString "signed"))) (EListLit))) (DoExpr (EListLit (EApp (EApp (EVar "node") (ELit (LString "b"))) (EBinOp "++" (EBinOp "++" (EListLit (EApp (EVar "intToString") (EVar "d")) (EApp (EVar "escStr") (EVar "m")) (EApp (EVar "escStr") (EFieldAccess (EVar "row") "brName")) (EApp (EVar "runtimeTypeName") (EFieldAccess (EVar "row") "brType"))) (EVar "ret")) (EVar "signed")))))))))))
(DTypeSig false "externSexp" (TyFun (TyCon "ExternDeclFact") (TyCon "String")))
(DFunDef false "externSexp" ((PVar "fact")) (EApp (EApp (EVar "node") (ELit (LString "extern"))) (EListLit (EApp (EVar "escStr") (EFieldAccess (EVar "fact") "symbol")) (EApp (EVar "escStr") (EFieldAccess (EVar "fact") "originModule")) (EApp (EVar "escStr") (EFieldAccess (EVar "fact") "declaredName")) (EMatch (EFieldAccess (EVar "fact") "bindingKind") (arm (PCon "ForeignBinding") () (ELit (LString "foreign"))) (arm (PCon "RuntimeBinding" (PVar "key")) () (EApp (EApp (EVar "node") (ELit (LString "runtime"))) (EListLit (EApp (EVar "escStr") (EVar "key")))))) (EApp (EVar "slist") (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "host") (PVar "sym"))) (EApp (EVar "slist") (EListLit (EApp (EVar "escStr") (EVar "host")) (EApp (EVar "escStr") (EVar "sym")))))) (EFieldAccess (EVar "fact") "hostBindings"))) (EApp (EApp (EVar "optionOr") (ELit (LString "missing-abi"))) (EApp (EApp (EVar "map") (EVar "shapeSexp")) (EFieldAccess (EVar "fact") "callableShape"))) (EMatch (EFieldAccess (EVar "fact") "provenance") (arm (PCon "CheckedSource") () (ELit (LString "checked"))) (arm (PCon "RawSource") () (ELit (LString "raw"))) (arm (PCon "NoSourceSignature") () (ELit (LString "no-source-signature")))))))
(DTypeSig false "shapeSexp" (TyFun (TyCon "CallableShape") (TyCon "String")))
(DFunDef false "shapeSexp" ((PVar "shape")) (EApp (EApp (EVar "node") (ELit (LString "abi"))) (EListLit (EApp (EVar "intToString") (EFieldAccess (EVar "shape") "writtenValueArity")) (EApp (EVar "intToString") (EFieldAccess (EVar "shape") "loweredCoreArity")) (EApp (EVar "slist") (EApp (EApp (EVar "map") (EVar "escStr")) (EFieldAccess (EVar "shape") "parameterHeads"))) (EApp (EVar "escStr") (EFieldAccess (EVar "shape") "resultHead")) (EApp (EVar "escStr") (EFieldAccess (EVar "shape") "canonicalSignature")))))
(DTypeSig false "manifestSexp" (TyFun (TyCon "CapabilityManifest") (TyCon "String")))
(DFunDef false "manifestSexp" ((PVar "manifest")) (EApp (EApp (EVar "node") (ELit (LString "manifest"))) (EListLit (EApp (EVar "escStr") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "manifest") "request") "entry") "moduleId")) (EApp (EVar "escStr") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "manifest") "request") "entry") "binding")) (EMatch (EFieldAccess (EFieldAccess (EVar "manifest") "request") "protocol") (arm (PCon "HostInvocation") () (ELit (LString "host"))) (arm (PCon "ExecutedMain") () (ELit (LString "executed")))) (EApp (EVar "slist") (EApp (EApp (EVar "map") (EVar "frozenAtomSexp")) (EFieldAccess (EVar "manifest") "atoms"))))))
(DTypeSig false "frozenAtomSexp" (TyFun (TyCon "FrozenAtom") (TyCon "String")))
(DFunDef false "frozenAtomSexp" ((PVar "atom")) (EApp (EApp (EVar "node") (ELit (LString "atom"))) (EListLit (EApp (EVar "escStr") (EFieldAccess (EVar "atom") "label")) (EMatch (EFieldAccess (EVar "atom") "origin") (arm (PCon "OriginBuiltin") () (ELit (LString "builtin"))) (arm (PCon "OriginUnresolved") () (ELit (LString "unresolved"))) (arm (PCon "OriginModule" (PVar "mid")) () (EApp (EApp (EVar "node") (ELit (LString "module"))) (EListLit (EApp (EVar "escStr") (EVar "mid")))))) (EApp (EVar "manifestParamSexp") (EFieldAccess (EVar "atom") "domainTop")) (EApp (EVar "frozenAuthoritySexp") (EFieldAccess (EVar "atom") "authority")))))
(DTypeSig false "frozenAuthoritySexp" (TyFun (TyCon "FrozenAuthority") (TyCon "String")))
(DFunDef false "frozenAuthoritySexp" ((PCon "FrozenConst" (PVar "p"))) (EApp (EApp (EVar "node") (ELit (LString "const"))) (EListLit (EApp (EVar "manifestParamSexp") (EVar "p")))))
(DFunDef false "frozenAuthoritySexp" ((PCon "FrozenVar" (PVar "v"))) (EApp (EApp (EVar "node") (ELit (LString "var"))) (EListLit (EApp (EVar "intToString") (EFieldAccess (EVar "v") "localId")) (EApp (EVar "manifestParamSexp") (EFieldAccess (EVar "v") "domainTop")) (EApp (EVar "boolStr") (EFieldAccess (EVar "v") "patternOnly")) (EApp (EApp (EApp (EVar "option") (ELit (LString "none"))) (ELam ((PVar "name")) (EApp (EApp (EVar "node") (ELit (LString "some"))) (EListLit (EApp (EVar "escStr") (EVar "name")))))) (EFieldAccess (EVar "v") "sourceName")))))
(DFunDef false "frozenAuthoritySexp" ((PCon "FrozenJoin" (PVar "members"))) (EApp (EApp (EVar "node") (ELit (LString "join"))) (EApp (EApp (EVar "map") (EVar "frozenAuthoritySexp")) (EVar "members"))))
(DFunDef false "frozenAuthoritySexp" ((PCon "FrozenProduct" (PVar "axes"))) (EApp (EApp (EVar "node") (ELit (LString "product"))) (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "name") (PVar "authority"))) (EApp (EVar "slist") (EListLit (EApp (EVar "escStr") (EVar "name")) (EApp (EVar "frozenAuthoritySexp") (EVar "authority")))))) (EVar "axes"))))
(DTypeSig false "manifestParamSexp" (TyFun (TyCon "Param") (TyCon "String")))
(DFunDef false "manifestParamSexp" ((PCon "PUnit")) (ELit (LString "unit")))
(DFunDef false "manifestParamSexp" ((PCon "PPrefix" (PVar "value"))) (EApp (EApp (EVar "node") (ELit (LString "prefix"))) (EListLit (EApp (EVar "manifestStringSexp") (EVar "value")))))
(DFunDef false "manifestParamSexp" ((PCon "PPath" (PVar "value"))) (EApp (EApp (EVar "node") (ELit (LString "path"))) (EListLit (EApp (EVar "manifestStringSexp") (EVar "value")))))
(DFunDef false "manifestParamSexp" ((PCon "PSet" (PVar "value"))) (EApp (EApp (EVar "node") (ELit (LString "set"))) (EListLit (EApp (EApp (EApp (EVar "option") (ELit (LString "none"))) (ELam ((PVar "members")) (EApp (EApp (EVar "node") (ELit (LString "some"))) (EApp (EApp (EVar "map") (EVar "escStr")) (EVar "members"))))) (EVar "value")))))
(DFunDef false "manifestParamSexp" ((PCon "PProduct" (PVar "axes"))) (EApp (EApp (EVar "node") (ELit (LString "axes"))) (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "name") (PVar "value"))) (EApp (EVar "slist") (EListLit (EApp (EVar "escStr") (EVar "name")) (EApp (EVar "manifestParamSexp") (EVar "value")))))) (EVar "axes"))))
(DTypeSig false "manifestStringSexp" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyCon "String")))
(DFunDef false "manifestStringSexp" () (EApp (EApp (EVar "option") (ELit (LString "none"))) (ELam ((PVar "value")) (EApp (EApp (EVar "node") (ELit (LString "some"))) (EListLit (EApp (EVar "escStr") (EVar "value")))))))
# MARK
(DUse false (UseGroup ("types" "capability_manifest") ((mem "EntryKey" true) (mem "ManifestRequest" true) (mem "InvocationProtocol" true) (mem "CapabilityManifest" true) (mem "FrozenAtom" true) (mem "FrozenAuthority" true) (mem "FrozenVariable" true))))
(DUse false (UseGroup ("types" "effect_domain") ((mem "Param" true))))
(DUse false (UseGroup ("frontend" "ast") ((mem "TyConOrigin" true))))
(DUse false (UseGroup ("ir" "extern_types") ((mem "ExternDeclFact" true))))
(DUse false (UseGroup ("types" "extern_source") ((mem "ExternBindingKind" true) (mem "ExternProvenance" true))))
(DUse false (UseGroup ("types" "runtime_abi_types") ((mem "CallableShape" true))))
(DUse false (UseGroup ("support" "ordmap") ((mem "omKeys" false) (mem "omLookup" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Lit" true) (mem "Pat" true) (mem "Addr" true) (mem "Route" true))))
(DUse false (UseGroup ("ir" "core_ir") ((mem "CExpr" true) (mem "MethodEvidence" true) (mem "CArm" true) (mem "CGuard" true) (mem "CStmt" true) (mem "CField" true) (mem "CBind" true) (mem "CClause" true) (mem "CImplEntry" true) (mem "CImplBody" true) (mem "ImplSym" true) (mem "CProgram" true) (mem "DeclFacts" true) (mem "EntryFact" true) (mem "MethodResultFact" true) (mem "CallMode" true) (mem "CallSite" true) (mem "CTree" true) (mem "CTBranch" true) (mem "CHead" true) (mem "programBinderIds" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "BinderId" true))))
(DUse false (UseGroup ("types" "runtime_types") ((mem "BinderRow" true) (mem "binderOrdinal" false) (mem "runtimeTypeName" false))))
(DUse false (UseAlias ("map") "BM"))
(DUse false (UseGroup ("ir" "sexp") ((mem "boolStr" false) (mem "node" false) (mem "slist" false) (mem "litSexp" false) (mem "patSexp" false))))
(DUse false (UseGroup ("support" "util") ((mem "escStr" false) (mem "joinNl" false) (mem "reverseL" false))))
(DTypeSig true "addrSexp" (TyFun (TyCon "Addr") (TyCon "String")))
(DFunDef false "addrSexp" ((PCon "ALocal" (PVar "frame") (PVar "slot"))) (EApp (EApp (EVar "node") (ELit (LString "ALocal"))) (EListLit (EApp (EVar "intToString") (EVar "frame")) (EApp (EVar "intToString") (EVar "slot")))))
(DFunDef false "addrSexp" ((PCon "AGlobal")) (ELit (LString "AGlobal")))
(DData Abstract "SexpMode" () ((variant "SexpMode" (ConNamed (field "faithfulRoutes" (TyCon "Bool"))))) ())
(DTypeSig true "defaultSexpMode" (TyCon "SexpMode"))
(DFunDef false "defaultSexpMode" () (ERecordCreate "SexpMode" ((fa "faithfulRoutes" (EVar "False")))))
(DTypeSig true "faithfulSexpMode" (TyCon "SexpMode"))
(DFunDef false "faithfulSexpMode" () (ERecordCreate "SexpMode" ((fa "faithfulRoutes" (EVar "True")))))
(DTypeSig true "routeSexp" (TyFun (TyCon "SexpMode") (TyFun (TyCon "Route") (TyCon "String"))))
(DFunDef false "routeSexp" (PWild (PCon "RNone")) (ELit (LString "RNone")))
(DFunDef false "routeSexp" ((PVar "m") (PCon "RKey" (PVar "k") (PVar "ds") (PVar "sups"))) (EIf (EFieldAccess (EVar "m") "faithfulRoutes") (EApp (EApp (EVar "node") (ELit (LString "RKey"))) (EListLit (EApp (EVar "escStr") (EVar "k")) (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EApp (EVar "routeSexp") (EVar "m"))) (EVar "ds"))) (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EApp (EVar "routeSexp") (EVar "m"))) (EVar "sups"))))) (EApp (EApp (EVar "node") (ELit (LString "RKey"))) (EListLit (EApp (EVar "escStr") (EVar "k"))))))
(DFunDef false "routeSexp" (PWild (PCon "RDict" (PVar "d"))) (EApp (EApp (EVar "node") (ELit (LString "RDict"))) (EListLit (EApp (EVar "escStr") (EVar "d")))))
(DFunDef false "routeSexp" (PWild (PCon "RDictFwd" (PVar "d"))) (EApp (EApp (EVar "node") (ELit (LString "RDictFwd"))) (EListLit (EApp (EVar "escStr") (EVar "d")))))
(DFunDef false "routeSexp" ((PVar "m") (PCon "RLocal" (PLit (LString "")) (PVar "ds"))) (EIf (EFieldAccess (EVar "m") "faithfulRoutes") (EApp (EApp (EVar "node") (ELit (LString "RLocal"))) (EListLit (EApp (EVar "escStr") (ELit (LString ""))) (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EApp (EVar "routeSexp") (EVar "m"))) (EVar "ds"))))) (ELit (LString "RLocal"))))
(DFunDef false "routeSexp" ((PVar "m") (PCon "RLocal" (PVar "s") (PVar "ds"))) (EIf (EFieldAccess (EVar "m") "faithfulRoutes") (EApp (EApp (EVar "node") (ELit (LString "RLocal"))) (EListLit (EApp (EVar "escStr") (EVar "s")) (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EApp (EVar "routeSexp") (EVar "m"))) (EVar "ds"))))) (EApp (EApp (EVar "node") (ELit (LString "RLocal"))) (EListLit (EApp (EVar "escStr") (EVar "s"))))))
(DFunDef false "routeSexp" (PWild (PCon "RScalar" (PVar "s"))) (EApp (EApp (EVar "node") (ELit (LString "RScalar"))) (EListLit (EApp (EVar "escStr") (EVar "s")))))
(DFunDef false "routeSexp" ((PVar "m") (PCon "RProj" (PVar "r") (PVar "path"))) (EApp (EApp (EVar "node") (ELit (LString "RProj"))) (EBinOp "::" (EApp (EApp (EVar "routeSexp") (EVar "m")) (EVar "r")) (EApp (EApp (EMethodRef "map") (EVar "intToString")) (EVar "path")))))
(DTypeSig true "callModeSexp" (TyFun (TyCon "CallMode") (TyCon "String")))
(DFunDef false "callModeSexp" ((PCon "CallExact")) (ELit (LString "CallExact")))
(DFunDef false "callModeSexp" ((PCon "CallPartial" (PVar "n"))) (EApp (EApp (EVar "node") (ELit (LString "CallPartial"))) (EListLit (EApp (EVar "intToString") (EVar "n")))))
(DFunDef false "callModeSexp" ((PCon "CallOver" (PVar "n"))) (EApp (EApp (EVar "node") (ELit (LString "CallOver"))) (EListLit (EApp (EVar "intToString") (EVar "n")))))
(DFunDef false "callModeSexp" ((PCon "CallDynamic")) (ELit (LString "CallDynamic")))
(DTypeSig true "cexprSexp" (TyFun (TyCon "SexpMode") (TyFun (TyCon "CExpr") (TyCon "String"))))
(DFunDef false "cexprSexp" ((PVar "m") (PCon "CLit" (PVar "l"))) (EApp (EApp (EVar "node") (ELit (LString "CLit"))) (EListLit (EApp (EVar "litSexp") (EVar "l")))))
(DFunDef false "cexprSexp" ((PVar "m") (PCon "CVar" (PVar "x") (PVar "addr"))) (EApp (EApp (EVar "node") (ELit (LString "CVar"))) (EListLit (EApp (EVar "escStr") (EVar "x")) (EApp (EVar "addrSexp") (EVar "addr")))))
(DFunDef false "cexprSexp" ((PVar "m") (PCon "CApp" (PVar "f") (PVar "args") (PCon "CallSite" (PVar "mode") (PVar "tailPos")))) (EApp (EApp (EVar "node") (ELit (LString "CApp"))) (EListLit (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "f")) (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EApp (EVar "cexprSexp") (EVar "m"))) (EVar "args"))) (EApp (EVar "callModeSexp") (EVar "mode")) (EApp (EVar "boolStr") (EVar "tailPos")))))
(DFunDef false "cexprSexp" ((PVar "m") (PCon "CLam" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "node") (ELit (LString "CLam"))) (EListLit (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EVar "patSexp")) (EVar "pats"))) (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "body")))))
(DFunDef false "cexprSexp" ((PVar "m") (PCon "CLet" (PVar "isRec") (PVar "pat") (PVar "e1") (PVar "e2"))) (EApp (EApp (EVar "node") (ELit (LString "CLet"))) (EListLit (EApp (EVar "boolStr") (EVar "isRec")) (EApp (EVar "patSexp") (EVar "pat")) (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "e1")) (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "e2")))))
(DFunDef false "cexprSexp" ((PVar "m") (PCon "CLetGroup" (PVar "binds") (PVar "body"))) (EApp (EApp (EVar "node") (ELit (LString "CLetGroup"))) (EListLit (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EApp (EVar "cbindSexp") (EVar "m"))) (EVar "binds"))) (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "body")))))
(DFunDef false "cexprSexp" ((PVar "m") (PCon "CMatch" (PVar "scrut") (PVar "arms"))) (EApp (EApp (EVar "node") (ELit (LString "CMatch"))) (EBinOp "::" (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "scrut")) (EApp (EApp (EMethodRef "map") (EApp (EVar "carmSexp") (EVar "m"))) (EVar "arms")))))
(DFunDef false "cexprSexp" ((PVar "m") (PCon "CDecision" (PVar "scrut") (PVar "arms") (PVar "tree"))) (EApp (EApp (EVar "node") (ELit (LString "CDecision"))) (EListLit (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "scrut")) (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EApp (EVar "carmSexp") (EVar "m"))) (EVar "arms"))) (EApp (EVar "ctreeSexp") (EVar "tree")))))
(DFunDef false "cexprSexp" ((PVar "m") (PCon "CIf" (PVar "c") (PVar "t") (PVar "e"))) (EApp (EApp (EVar "node") (ELit (LString "CIf"))) (EListLit (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "c")) (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "t")) (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "e")))))
(DFunDef false "cexprSexp" ((PVar "m") (PCon "CBinPrim" (PVar "op") (PVar "l") (PVar "r") (PVar "tag") PWild)) (EIf (EBinOp "==" (EVar "tag") (ELit (LString ""))) (EApp (EApp (EVar "node") (ELit (LString "CBinPrim"))) (EListLit (EApp (EVar "escStr") (EVar "op")) (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "l")) (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "r")))) (EApp (EApp (EVar "node") (ELit (LString "CBinPrim"))) (EListLit (EApp (EVar "escStr") (EVar "op")) (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "l")) (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "r")) (EApp (EVar "escStr") (EVar "tag"))))))
(DFunDef false "cexprSexp" ((PVar "m") (PCon "CUnOp" (PVar "op") (PVar "e"))) (EApp (EApp (EVar "node") (ELit (LString "CUnOp"))) (EListLit (EApp (EVar "escStr") (EVar "op")) (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "e")))))
(DFunDef false "cexprSexp" ((PVar "m") (PCon "CTuple" (PVar "es"))) (EApp (EApp (EVar "node") (ELit (LString "CTuple"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "cexprSexp") (EVar "m"))) (EVar "es"))))
(DFunDef false "cexprSexp" ((PVar "m") (PCon "CList" (PVar "es"))) (EApp (EApp (EVar "node") (ELit (LString "CList"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "cexprSexp") (EVar "m"))) (EVar "es"))))
(DFunDef false "cexprSexp" ((PVar "m") (PCon "CRecord" (PVar "name") (PVar "fields"))) (EApp (EApp (EVar "node") (ELit (LString "CRecord"))) (EBinOp "::" (EApp (EVar "escStr") (EVar "name")) (EApp (EApp (EMethodRef "map") (EApp (EVar "cfieldSexp") (EVar "m"))) (EVar "fields")))))
(DFunDef false "cexprSexp" ((PVar "m") (PCon "CFieldAccess" (PVar "e") (PVar "f") (PVar "n") (PVar "o"))) (EApp (EApp (EVar "node") (ELit (LString "CFieldAccess"))) (EListLit (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "e")) (EApp (EVar "escStr") (EVar "f")) (EApp (EVar "escStr") (EVar "n")) (EApp (EVar "intToString") (EVar "o")))))
(DFunDef false "cexprSexp" ((PVar "m") (PCon "CRecordUpdate" (PVar "name") (PVar "base") (PVar "fields"))) (EApp (EApp (EVar "node") (ELit (LString "CRecordUpdate"))) (EBinOp "::" (EApp (EVar "escStr") (EVar "name")) (EBinOp "::" (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "base")) (EApp (EApp (EMethodRef "map") (EApp (EVar "cfieldSexp") (EVar "m"))) (EVar "fields"))))))
(DFunDef false "cexprSexp" ((PVar "m") (PCon "CVariantUpdate" (PVar "con") (PVar "base") (PVar "fields"))) (EApp (EApp (EVar "node") (ELit (LString "CVariantUpdate"))) (EBinOp "::" (EApp (EVar "escStr") (EVar "con")) (EBinOp "::" (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "base")) (EApp (EApp (EMethodRef "map") (EApp (EVar "cfieldSexp") (EVar "m"))) (EVar "fields"))))))
(DFunDef false "cexprSexp" ((PVar "m") (PCon "CArray" (PVar "es"))) (EApp (EApp (EVar "node") (ELit (LString "CArray"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "cexprSexp") (EVar "m"))) (EVar "es"))))
(DFunDef false "cexprSexp" ((PVar "m") (PCon "CRangeList" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EVar "node") (ELit (LString "CRangeList"))) (EListLit (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "lo")) (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "hi")) (EApp (EVar "boolStr") (EVar "incl")))))
(DFunDef false "cexprSexp" ((PVar "m") (PCon "CRangeArray" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EVar "node") (ELit (LString "CRangeArray"))) (EListLit (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "lo")) (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "hi")) (EApp (EVar "boolStr") (EVar "incl")))))
(DFunDef false "cexprSexp" ((PVar "m") (PCon "CIndex" (PVar "a") (PVar "i"))) (EApp (EApp (EVar "node") (ELit (LString "CIndex"))) (EListLit (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "a")) (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "i")))))
(DFunDef false "cexprSexp" ((PVar "m") (PCon "CSlice" (PVar "a") (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EVar "node") (ELit (LString "CSlice"))) (EListLit (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "a")) (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "lo")) (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "hi")) (EApp (EVar "boolStr") (EVar "incl")))))
(DFunDef false "cexprSexp" ((PVar "m") (PCon "CStringIndex" (PVar "a") (PVar "i"))) (EApp (EApp (EVar "node") (ELit (LString "CStringIndex"))) (EListLit (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "a")) (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "i")))))
(DFunDef false "cexprSexp" ((PVar "m") (PCon "CStringSlice" (PVar "a") (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EVar "node") (ELit (LString "CStringSlice"))) (EListLit (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "a")) (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "lo")) (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "hi")) (EApp (EVar "boolStr") (EVar "incl")))))
(DFunDef false "cexprSexp" ((PVar "m") (PCon "CListIndex" (PVar "a") (PVar "i"))) (EApp (EApp (EVar "node") (ELit (LString "CListIndex"))) (EListLit (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "a")) (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "i")))))
(DFunDef false "cexprSexp" ((PVar "m") (PCon "CListSlice" (PVar "a") (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EVar "node") (ELit (LString "CListSlice"))) (EListLit (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "a")) (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "lo")) (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "hi")) (EApp (EVar "boolStr") (EVar "incl")))))
(DFunDef false "cexprSexp" ((PVar "m") (PCon "CBlock" (PVar "stmts"))) (EApp (EApp (EVar "node") (ELit (LString "CBlock"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "cstmtSexp") (EVar "m"))) (EVar "stmts"))))
(DFunDef false "cexprSexp" ((PVar "m") (PCon "CMethod" (PVar "name") (PCon "MethodEvidence" (PVar "iface") (PVar "arity") (PVar "route") (PVar "implRoutes") (PVar "methRoutes")))) (EApp (EApp (EVar "node") (ELit (LString "CMethod"))) (EListLit (EApp (EVar "escStr") (EVar "name")) (EApp (EVar "escStr") (EVar "iface")) (EApp (EVar "intToString") (EVar "arity")) (EApp (EApp (EVar "routeSexp") (EVar "m")) (EVar "route")) (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EApp (EVar "routeSexp") (EVar "m"))) (EVar "implRoutes"))) (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EApp (EVar "routeSexp") (EVar "m"))) (EVar "methRoutes"))))))
(DFunDef false "cexprSexp" ((PVar "m") (PCon "CDict" (PVar "name") (PVar "routes"))) (EApp (EApp (EVar "node") (ELit (LString "CDict"))) (EListLit (EApp (EVar "escStr") (EVar "name")) (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EApp (EVar "routeSexp") (EVar "m"))) (EVar "routes"))))))
(DTypeSig true "cfieldSexp" (TyFun (TyCon "SexpMode") (TyFun (TyCon "CField") (TyCon "String"))))
(DFunDef false "cfieldSexp" ((PVar "m") (PCon "CField" (PVar "name") (PVar "o") (PVar "e"))) (EApp (EApp (EVar "node") (ELit (LString "cf"))) (EListLit (EApp (EVar "escStr") (EVar "name")) (EApp (EVar "intToString") (EVar "o")) (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "e")))))
(DTypeSig true "carmSexp" (TyFun (TyCon "SexpMode") (TyFun (TyCon "CArm") (TyCon "String"))))
(DFunDef false "carmSexp" ((PVar "m") (PCon "CArm" (PVar "pat") (PVar "guards") (PVar "body"))) (EApp (EApp (EVar "node") (ELit (LString "arm"))) (EListLit (EApp (EVar "patSexp") (EVar "pat")) (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EApp (EVar "cguardSexp") (EVar "m"))) (EVar "guards"))) (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "body")))))
(DTypeSig true "cguardSexp" (TyFun (TyCon "SexpMode") (TyFun (TyCon "CGuard") (TyCon "String"))))
(DFunDef false "cguardSexp" ((PVar "m") (PCon "CGBool" (PVar "e"))) (EApp (EApp (EVar "node") (ELit (LString "CGBool"))) (EListLit (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "e")))))
(DFunDef false "cguardSexp" ((PVar "m") (PCon "CGBind" (PVar "pat") (PVar "e"))) (EApp (EApp (EVar "node") (ELit (LString "CGBind"))) (EListLit (EApp (EVar "patSexp") (EVar "pat")) (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "e")))))
(DTypeSig true "ctreeSexp" (TyFun (TyCon "CTree") (TyCon "String")))
(DFunDef false "ctreeSexp" ((PCon "CTFail" PWild)) (ELit (LString "CTFail")))
(DFunDef false "ctreeSexp" ((PCon "CTLeaf" (PVar "i"))) (EApp (EApp (EVar "node") (ELit (LString "CTLeaf"))) (EListLit (EApp (EVar "intToString") (EVar "i")))))
(DFunDef false "ctreeSexp" ((PCon "CTGuard" (PVar "i") (PVar "fail"))) (EApp (EApp (EVar "node") (ELit (LString "CTGuard"))) (EListLit (EApp (EVar "intToString") (EVar "i")) (EApp (EVar "ctreeSexp") (EVar "fail")))))
(DFunDef false "ctreeSexp" ((PCon "CTSwitch" (PVar "branches") (PVar "dflt"))) (EApp (EApp (EVar "node") (ELit (LString "CTSwitch"))) (EListLit (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EVar "ctbranchSexp")) (EVar "branches"))) (EApp (EVar "ctreeSexp") (EVar "dflt")))))
(DFunDef false "ctreeSexp" ((PCon "CTDrop" (PVar "tree"))) (EApp (EApp (EVar "node") (ELit (LString "CTDrop"))) (EListLit (EApp (EVar "ctreeSexp") (EVar "tree")))))
(DTypeSig true "ctbranchSexp" (TyFun (TyCon "CTBranch") (TyCon "String")))
(DFunDef false "ctbranchSexp" ((PCon "CTBranch" (PVar "head") (PVar "tree"))) (EApp (EApp (EVar "node") (ELit (LString "CTBranch"))) (EListLit (EApp (EVar "cheadSexp") (EVar "head")) (EApp (EVar "ctreeSexp") (EVar "tree")))))
(DTypeSig true "cheadSexp" (TyFun (TyCon "CHead") (TyCon "String")))
(DFunDef false "cheadSexp" ((PCon "HCon" (PVar "name") (PVar "arity"))) (EApp (EApp (EVar "node") (ELit (LString "HCon"))) (EListLit (EApp (EVar "escStr") (EVar "name")) (EApp (EVar "intToString") (EVar "arity")))))
(DFunDef false "cheadSexp" ((PCon "HTuple" (PVar "arity"))) (EApp (EApp (EVar "node") (ELit (LString "HTuple"))) (EListLit (EApp (EVar "intToString") (EVar "arity")))))
(DFunDef false "cheadSexp" ((PCon "HCons")) (ELit (LString "HCons")))
(DFunDef false "cheadSexp" ((PCon "HNil")) (ELit (LString "HNil")))
(DFunDef false "cheadSexp" ((PCon "HUnit")) (ELit (LString "HUnit")))
(DFunDef false "cheadSexp" ((PCon "HLit" (PVar "l"))) (EApp (EApp (EVar "node") (ELit (LString "HLit"))) (EListLit (EApp (EVar "litSexp") (EVar "l")))))
(DTypeSig true "cstmtSexp" (TyFun (TyCon "SexpMode") (TyFun (TyCon "CStmt") (TyCon "String"))))
(DFunDef false "cstmtSexp" ((PVar "m") (PCon "CSExpr" (PVar "e"))) (EApp (EApp (EVar "node") (ELit (LString "CSExpr"))) (EListLit (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "e")))))
(DFunDef false "cstmtSexp" ((PVar "m") (PCon "CSLet" (PVar "isRec") (PVar "pat") (PVar "e"))) (EApp (EApp (EVar "node") (ELit (LString "CSLet"))) (EListLit (EApp (EVar "boolStr") (EVar "isRec")) (EApp (EVar "patSexp") (EVar "pat")) (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "e")))))
(DFunDef false "cstmtSexp" ((PVar "m") (PCon "CSAssign" (PVar "x") (PVar "e"))) (EApp (EApp (EVar "node") (ELit (LString "CSAssign"))) (EListLit (EApp (EVar "escStr") (EVar "x")) (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "e")))))
(DTypeSig true "cbindSexp" (TyFun (TyCon "SexpMode") (TyFun (TyCon "CBind") (TyCon "String"))))
(DFunDef false "cbindSexp" ((PVar "m") (PCon "CBind" (PVar "name") (PVar "clauses") PWild PWild)) (EApp (EApp (EVar "node") (ELit (LString "CBind"))) (EBinOp "::" (EApp (EVar "escStr") (EVar "name")) (EApp (EApp (EMethodRef "map") (EApp (EVar "cclauseSexp") (EVar "m"))) (EVar "clauses")))))
(DTypeSig true "cclauseSexp" (TyFun (TyCon "SexpMode") (TyFun (TyCon "CClause") (TyCon "String"))))
(DFunDef false "cclauseSexp" ((PVar "m") (PCon "CClause" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "node") (ELit (LString "CClause"))) (EListLit (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EVar "patSexp")) (EVar "pats"))) (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "body")))))
(DTypeSig false "implSymSexp" (TyFun (TyCon "ImplSym") (TyCon "String")))
(DFunDef false "implSymSexp" ((PCon "ImplSym" (PVar "tag") (PVar "ifaceTag") (PVar "keyTag"))) (EApp (EVar "slist") (EListLit (EApp (EVar "escStr") (EVar "tag")) (EApp (EVar "escStr") (EVar "ifaceTag")) (EApp (EVar "escStr") (EVar "keyTag")))))
(DTypeSig true "cimplBodySexp" (TyFun (TyCon "SexpMode") (TyFun (TyCon "CImplBody") (TyCon "String"))))
(DFunDef false "cimplBodySexp" ((PVar "m") (PCon "CImplTagged" (PVar "tag") (PVar "key") (PVar "iface") (PVar "sym") (PVar "positions") (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "node") (ELit (LString "CImplTagged"))) (EListLit (EApp (EVar "escStr") (EVar "tag")) (EApp (EVar "escStr") (EVar "key")) (EApp (EVar "escStr") (EVar "iface")) (EApp (EVar "implSymSexp") (EVar "sym")) (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EVar "intToString")) (EVar "positions"))) (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EVar "patSexp")) (EVar "pats"))) (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "body")))))
(DFunDef false "cimplBodySexp" ((PVar "m") (PCon "CImplDefault" (PVar "ifaceId") (PVar "tag") (PVar "key") (PVar "sym") (PVar "positions") (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "node") (ELit (LString "CImplDefault"))) (EListLit (EApp (EVar "escStr") (EVar "ifaceId")) (EApp (EVar "escStr") (EVar "tag")) (EApp (EVar "escStr") (EVar "key")) (EApp (EVar "implSymSexp") (EVar "sym")) (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EVar "intToString")) (EVar "positions"))) (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EVar "patSexp")) (EVar "pats"))) (EApp (EApp (EVar "cexprSexp") (EVar "m")) (EVar "body")))))
(DTypeSig true "cimplEntrySexp" (TyFun (TyCon "SexpMode") (TyFun (TyCon "CImplEntry") (TyCon "String"))))
(DFunDef false "cimplEntrySexp" ((PVar "m") (PCon "CImplEntry" (PVar "name") (PVar "score") (PVar "declared") (PVar "body"))) (EApp (EApp (EVar "node") (ELit (LString "CImplEntry"))) (EListLit (EApp (EVar "escStr") (EVar "name")) (EApp (EVar "intToString") (EVar "score")) (EApp (EVar "intToString") (EVar "declared")) (EApp (EApp (EVar "cimplBodySexp") (EVar "m")) (EVar "body")))))
(DTypeSig false "ctorArityPairSexp" (TyFun (TyTuple (TyCon "String") (TyCon "Int")) (TyCon "String")))
(DFunDef false "ctorArityPairSexp" ((PTuple (PVar "name") (PVar "arity"))) (EApp (EApp (EVar "node") (ELit (LString "ca"))) (EListLit (EApp (EVar "escStr") (EVar "name")) (EApp (EVar "intToString") (EVar "arity")))))
(DTypeSig false "ctorTypePairSexp" (TyFun (TyTuple (TyCon "String") (TyCon "String")) (TyCon "String")))
(DFunDef false "ctorTypePairSexp" ((PTuple (PVar "ctor") (PVar "ty"))) (EApp (EApp (EVar "node") (ELit (LString "ct"))) (EListLit (EApp (EVar "escStr") (EVar "ctor")) (EApp (EVar "escStr") (EVar "ty")))))
(DTypeSig false "bindsSexp" (TyFun (TyCon "SexpMode") (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyCon "String"))))
(DFunDef false "bindsSexp" ((PVar "m") (PVar "binds")) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EVar "joinNl") (EApp (EApp (EMethodRef "map") (EApp (EVar "cbindSexp") (EVar "m"))) (EVar "binds")))) (ELit (LString ")"))))
(DTypeSig true "cprogramToSexp" (TyFun (TyCon "CProgram") (TyCon "String")))
(DFunDef false "cprogramToSexp" ((PVar "prog")) (EApp (EApp (EVar "cprogramToSexpWith") (EVar "defaultSexpMode")) (EVar "prog")))
(DTypeSig true "cprogramToSexpWith" (TyFun (TyCon "SexpMode") (TyFun (TyCon "CProgram") (TyCon "String"))))
(DFunDef false "cprogramToSexpWith" ((PVar "m") (PAs "prog" (PCon "CProgram" (PVar "binds") (PVar "ctorArities") (PVar "ctorToType") (PVar "impls") (PVar "mctx") (PVar "facts")))) (EApp (EApp (EVar "node") (ELit (LString "CProgram"))) (EBinOp "++" (EListLit (EApp (EApp (EVar "bindsSexp") (EVar "m")) (EVar "binds")) (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EVar "ctorArityPairSexp")) (EVar "ctorArities"))) (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EVar "ctorTypePairSexp")) (EVar "ctorToType"))) (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EApp (EVar "cimplEntrySexp") (EVar "m"))) (EVar "impls")))) (EApp (EApp (EApp (EVar "tablesSexp") (EVar "mctx")) (EVar "facts")) (EApp (EVar "binderTypesSexp") (EVar "prog"))))))
(DTypeSig false "tablesSexp" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyCon "DeclFacts") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "tablesSexp" ((PVar "rows") (PVar "facts") (PCon "Some" (PVar "binders"))) (EListLit (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EVar "methodContextPairSexp")) (EVar "rows"))) (EApp (EVar "declFactsSexp") (EVar "facts")) (EVar "binders")))
(DFunDef false "tablesSexp" ((PVar "rows") (PVar "facts") (PCon "None")) (EMatch (ETuple (EVar "rows") (EFieldAccess (EVar "facts") "factRequires") (EFieldAccess (EVar "facts") "factSupers") (EFieldAccess (EVar "facts") "factMethodResults") (EFieldAccess (EVar "facts") "factEntryOutcome") (EApp (EVar "omKeys") (EFieldAccess (EVar "facts") "factExterns")) (EFieldAccess (EVar "facts") "factManifests")) (arm (PTuple (PList) (PList) (PList) (PList) (PCon "None") (PList) (PList)) () (EListLit)) (arm (PTuple PWild (PList) (PList) (PList) (PCon "None") (PList) (PList)) () (EListLit (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EVar "methodContextPairSexp")) (EVar "rows"))))) (arm PWild () (EListLit (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EVar "methodContextPairSexp")) (EVar "rows"))) (EApp (EVar "declFactsSexp") (EVar "facts"))))))
(DTypeSig false "declFactsSexp" (TyFun (TyCon "DeclFacts") (TyCon "String")))
(DFunDef false "declFactsSexp" ((PVar "facts")) (EIf (EBinOp "||" (EApp (EVar "not") (EApp (EMethodRef "isEmpty") (EApp (EVar "omKeys") (EFieldAccess (EVar "facts") "factExterns")))) (EApp (EVar "not") (EApp (EMethodRef "isEmpty") (EFieldAccess (EVar "facts") "factManifests")))) (EApp (EApp (EVar "node") (ELit (LString "facts"))) (EBinOp "++" (EListLit (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EApp (EVar "factPairSexp") (ELit (LString "rq")))) (EFieldAccess (EVar "facts") "factRequires"))) (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EApp (EVar "factPairSexp") (ELit (LString "sp")))) (EFieldAccess (EVar "facts") "factSupers"))) (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EVar "methodResultSexp")) (EFieldAccess (EVar "facts") "factMethodResults"))) (EApp (EApp (EVar "optionOr") (ELit (LString "none"))) (EApp (EApp (EMethodRef "map") (EVar "entryOutcomeSexp")) (EFieldAccess (EVar "facts") "factEntryOutcome"))) (EApp (EApp (EVar "node") (ELit (LString "externs"))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "key")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "key")) (EFieldAccess (EVar "facts") "factExterns")) (arm (PCon "Some" (PVar "fact")) () (EApp (EVar "externSexp") (EVar "fact"))) (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "extern inventory lost a row"))))))) (EApp (EVar "omKeys") (EFieldAccess (EVar "facts") "factExterns"))))) (EIf (EApp (EMethodRef "isEmpty") (EFieldAccess (EVar "facts") "factManifests")) (EListLit) (EListLit (EApp (EApp (EVar "node") (ELit (LString "manifests"))) (EApp (EApp (EMethodRef "map") (EVar "manifestSexp")) (EFieldAccess (EVar "facts") "factManifests"))))))) (EApp (EApp (EVar "node") (ELit (LString "facts"))) (EBinOp "++" (EBinOp "++" (EListLit (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EApp (EVar "factPairSexp") (ELit (LString "rq")))) (EFieldAccess (EVar "facts") "factRequires"))) (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EApp (EVar "factPairSexp") (ELit (LString "sp")))) (EFieldAccess (EVar "facts") "factSupers")))) (EIf (EBinOp "&&" (EApp (EMethodRef "isEmpty") (EFieldAccess (EVar "facts") "factMethodResults")) (EApp (EVar "isNone") (EFieldAccess (EVar "facts") "factEntryOutcome"))) (EListLit) (EListLit (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EVar "methodResultSexp")) (EFieldAccess (EVar "facts") "factMethodResults")))))) (EMatch (EFieldAccess (EVar "facts") "factEntryOutcome") (arm (PCon "Some" (PVar "outcome")) () (EListLit (EApp (EVar "entryOutcomeSexp") (EVar "outcome")))) (arm (PCon "None") () (EListLit)))))))
(DTypeSig false "entryOutcomeSexp" (TyFun (TyCon "EntryFact") (TyCon "String")))
(DFunDef false "entryOutcomeSexp" ((PVar "outcome")) (EApp (EApp (EVar "node") (ELit (LString "entry"))) (EListLit (EApp (EVar "boolStr") (EFieldAccess (EVar "outcome") "entryMainIsUnit")) (EApp (EVar "boolStr") (EFieldAccess (EVar "outcome") "entryMainIsFloat")))))
(DTypeSig false "methodResultSexp" (TyFun (TyCon "MethodResultFact") (TyCon "String")))
(DFunDef false "methodResultSexp" ((PVar "row")) (EApp (EApp (EVar "node") (ELit (LString "mr"))) (EListLit (EApp (EVar "escStr") (EFieldAccess (EVar "row") "iface")) (EApp (EVar "escStr") (EFieldAccess (EVar "row") "method")) (EApp (EVar "boolStr") (EFieldAccess (EVar "row") "returnsHead")) (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EVar "intToString")) (EFieldAccess (EVar "row") "callbackPositions"))) (EApp (EVar "intToString") (EFieldAccess (EVar "row") "valueArity")))))
(DTypeSig false "factPairSexp" (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "String") (TyCon "Int")) (TyCon "String"))))
(DFunDef false "factPairSexp" ((PVar "tag") (PTuple (PVar "key") (PVar "n"))) (EApp (EApp (EVar "node") (EVar "tag")) (EListLit (EApp (EVar "escStr") (EVar "key")) (EApp (EVar "intToString") (EVar "n")))))
(DTypeSig false "methodContextPairSexp" (TyFun (TyTuple (TyCon "String") (TyCon "Int")) (TyCon "String")))
(DFunDef false "methodContextPairSexp" ((PTuple (PVar "key") (PVar "n"))) (EApp (EApp (EVar "node") (ELit (LString "mc"))) (EListLit (EApp (EVar "escStr") (EVar "key")) (EApp (EVar "intToString") (EVar "n")))))
(DTypeSig false "binderTypesSexp" (TyFun (TyCon "CProgram") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "binderTypesSexp" ((PAs "prog" (PCon "CProgram" PWild PWild PWild PWild PWild (PVar "facts")))) (EBlock (DoLet false false (PVar "ids") (EApp (EVar "programBinderIds") (EVar "prog"))) (DoExpr (EMatch (EVar "ids") (arm (PList) () (EVar "None")) (arm PWild () (EBlock (DoLet false false (PTuple (PVar "occ") (PVar "firsts")) (EApp (EApp (EApp (EApp (EApp (EVar "denseIds") (EVar "ids")) (EVar "BM.Tip")) (ELit (LInt 0))) (EListLit)) (EListLit))) (DoLet false false (PVar "byOrd") (EApp (EVar "BM.fromList") (EApp (EApp (EMethodRef "map") (ELam ((PVar "r")) (ETuple (EApp (EVar "binderOrdinal") (EFieldAccess (EVar "r") "brId")) (EVar "r")))) (EFieldAccess (EVar "facts") "factBinders")))) (DoLet false false (PVar "rows") (EApp (EApp (EDictApp "flatMap") (EApp (EVar "binderRowSexp") (EVar "byOrd"))) (EApp (EVar "reverseL") (EVar "firsts")))) (DoLet false false (PVar "idsPart") (EIf (EApp (EApp (EVar "isIdentity") (EVar "occ")) (ELit (LInt 0))) (EListLit) (EListLit (EApp (EApp (EVar "node") (ELit (LString "ids"))) (EApp (EApp (EMethodRef "map") (EVar "intToString")) (EVar "occ")))))) (DoExpr (EApp (EVar "Some") (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EVar "joinNl") (EBinOp "::" (ELit (LString "binder-types")) (EBinOp "++" (EVar "idsPart") (EVar "rows"))))) (ELit (LString ")")))))))))))
(DTypeSig false "denseIds" (TyFun (TyApp (TyCon "List") (TyCon "BinderId")) (TyFun (TyApp (TyApp (TyCon "BM.Map") (TyCon "Int")) (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "BinderId"))) (TyTuple (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "BinderId"))))))))))
(DFunDef false "denseIds" ((PList) PWild PWild (PVar "occ") (PVar "firsts")) (ETuple (EApp (EVar "reverseL") (EVar "occ")) (EVar "firsts")))
(DFunDef false "denseIds" ((PCons (PAs "bid" (PCon "BinderId" PWild (PVar "n"))) (PVar "rest")) (PVar "seen") (PVar "next") (PVar "occ") (PVar "firsts")) (EIf (EBinOp "<" (EVar "n") (ELit (LInt 0))) (EApp (EApp (EApp (EApp (EApp (EVar "denseIds") (EVar "rest")) (EVar "seen")) (EVar "next")) (EBinOp "::" (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1))) (EVar "occ"))) (EVar "firsts")) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "BM.get") (EVar "n")) (EVar "seen")) (arm (PCon "Some" (PVar "d")) () (EApp (EApp (EApp (EApp (EApp (EVar "denseIds") (EVar "rest")) (EVar "seen")) (EVar "next")) (EBinOp "::" (EVar "d") (EVar "occ"))) (EVar "firsts"))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EVar "denseIds") (EVar "rest")) (EApp (EApp (EApp (EVar "BM.set") (EVar "n")) (EVar "next")) (EVar "seen"))) (EBinOp "+" (EVar "next") (ELit (LInt 1)))) (EBinOp "::" (EVar "next") (EVar "occ"))) (EBinOp "::" (ETuple (EVar "next") (EVar "bid")) (EVar "firsts"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "isIdentity" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "isIdentity" ((PList) PWild) (EVar "True"))
(DFunDef false "isIdentity" ((PCons (PVar "d") (PVar "rest")) (PVar "i")) (EBinOp "&&" (EBinOp "==" (EVar "d") (EVar "i")) (EApp (EApp (EVar "isIdentity") (EVar "rest")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))
(DTypeSig false "binderRowSexp" (TyFun (TyApp (TyApp (TyCon "BM.Map") (TyCon "Int")) (TyCon "BinderRow")) (TyFun (TyTuple (TyCon "Int") (TyCon "BinderId")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "binderRowSexp" ((PVar "byOrd") (PTuple (PVar "d") (PCon "BinderId" PWild (PVar "n")))) (EMatch (EApp (EApp (EVar "BM.get") (EVar "n")) (EVar "byOrd")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "row")) () (EMatch (EFieldAccess (EVar "row") "brId") (arm (PCon "BinderId" (PVar "m") PWild) () (EBlock (DoLet false false (PVar "ret") (EMatch (EFieldAccess (EVar "row") "brReturns") (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "r")) () (EListLit (EApp (EVar "runtimeTypeName") (EVar "r")))))) (DoLet false false (PVar "signed") (EIf (EFieldAccess (EVar "row") "brSigned") (EListLit (ELit (LString "signed"))) (EListLit))) (DoExpr (EListLit (EApp (EApp (EVar "node") (ELit (LString "b"))) (EBinOp "++" (EBinOp "++" (EListLit (EApp (EVar "intToString") (EVar "d")) (EApp (EVar "escStr") (EVar "m")) (EApp (EVar "escStr") (EFieldAccess (EVar "row") "brName")) (EApp (EVar "runtimeTypeName") (EFieldAccess (EVar "row") "brType"))) (EVar "ret")) (EVar "signed")))))))))))
(DTypeSig false "externSexp" (TyFun (TyCon "ExternDeclFact") (TyCon "String")))
(DFunDef false "externSexp" ((PVar "fact")) (EApp (EApp (EVar "node") (ELit (LString "extern"))) (EListLit (EApp (EVar "escStr") (EFieldAccess (EVar "fact") "symbol")) (EApp (EVar "escStr") (EFieldAccess (EVar "fact") "originModule")) (EApp (EVar "escStr") (EFieldAccess (EVar "fact") "declaredName")) (EMatch (EFieldAccess (EVar "fact") "bindingKind") (arm (PCon "ForeignBinding") () (ELit (LString "foreign"))) (arm (PCon "RuntimeBinding" (PVar "key")) () (EApp (EApp (EVar "node") (ELit (LString "runtime"))) (EListLit (EApp (EVar "escStr") (EVar "key")))))) (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "host") (PVar "sym"))) (EApp (EVar "slist") (EListLit (EApp (EVar "escStr") (EVar "host")) (EApp (EVar "escStr") (EVar "sym")))))) (EFieldAccess (EVar "fact") "hostBindings"))) (EApp (EApp (EVar "optionOr") (ELit (LString "missing-abi"))) (EApp (EApp (EMethodRef "map") (EVar "shapeSexp")) (EFieldAccess (EVar "fact") "callableShape"))) (EMatch (EFieldAccess (EVar "fact") "provenance") (arm (PCon "CheckedSource") () (ELit (LString "checked"))) (arm (PCon "RawSource") () (ELit (LString "raw"))) (arm (PCon "NoSourceSignature") () (ELit (LString "no-source-signature")))))))
(DTypeSig false "shapeSexp" (TyFun (TyCon "CallableShape") (TyCon "String")))
(DFunDef false "shapeSexp" ((PVar "shape")) (EApp (EApp (EVar "node") (ELit (LString "abi"))) (EListLit (EApp (EVar "intToString") (EFieldAccess (EVar "shape") "writtenValueArity")) (EApp (EVar "intToString") (EFieldAccess (EVar "shape") "loweredCoreArity")) (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EVar "escStr")) (EFieldAccess (EVar "shape") "parameterHeads"))) (EApp (EVar "escStr") (EFieldAccess (EVar "shape") "resultHead")) (EApp (EVar "escStr") (EFieldAccess (EVar "shape") "canonicalSignature")))))
(DTypeSig false "manifestSexp" (TyFun (TyCon "CapabilityManifest") (TyCon "String")))
(DFunDef false "manifestSexp" ((PVar "manifest")) (EApp (EApp (EVar "node") (ELit (LString "manifest"))) (EListLit (EApp (EVar "escStr") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "manifest") "request") "entry") "moduleId")) (EApp (EVar "escStr") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "manifest") "request") "entry") "binding")) (EMatch (EFieldAccess (EFieldAccess (EVar "manifest") "request") "protocol") (arm (PCon "HostInvocation") () (ELit (LString "host"))) (arm (PCon "ExecutedMain") () (ELit (LString "executed")))) (EApp (EVar "slist") (EApp (EApp (EMethodRef "map") (EVar "frozenAtomSexp")) (EFieldAccess (EVar "manifest") "atoms"))))))
(DTypeSig false "frozenAtomSexp" (TyFun (TyCon "FrozenAtom") (TyCon "String")))
(DFunDef false "frozenAtomSexp" ((PVar "atom")) (EApp (EApp (EVar "node") (ELit (LString "atom"))) (EListLit (EApp (EVar "escStr") (EFieldAccess (EVar "atom") "label")) (EMatch (EFieldAccess (EVar "atom") "origin") (arm (PCon "OriginBuiltin") () (ELit (LString "builtin"))) (arm (PCon "OriginUnresolved") () (ELit (LString "unresolved"))) (arm (PCon "OriginModule" (PVar "mid")) () (EApp (EApp (EVar "node") (ELit (LString "module"))) (EListLit (EApp (EVar "escStr") (EVar "mid")))))) (EApp (EVar "manifestParamSexp") (EFieldAccess (EVar "atom") "domainTop")) (EApp (EVar "frozenAuthoritySexp") (EFieldAccess (EVar "atom") "authority")))))
(DTypeSig false "frozenAuthoritySexp" (TyFun (TyCon "FrozenAuthority") (TyCon "String")))
(DFunDef false "frozenAuthoritySexp" ((PCon "FrozenConst" (PVar "p"))) (EApp (EApp (EVar "node") (ELit (LString "const"))) (EListLit (EApp (EVar "manifestParamSexp") (EVar "p")))))
(DFunDef false "frozenAuthoritySexp" ((PCon "FrozenVar" (PVar "v"))) (EApp (EApp (EVar "node") (ELit (LString "var"))) (EListLit (EApp (EVar "intToString") (EFieldAccess (EVar "v") "localId")) (EApp (EVar "manifestParamSexp") (EFieldAccess (EVar "v") "domainTop")) (EApp (EVar "boolStr") (EFieldAccess (EVar "v") "patternOnly")) (EApp (EApp (EApp (EVar "option") (ELit (LString "none"))) (ELam ((PVar "name")) (EApp (EApp (EVar "node") (ELit (LString "some"))) (EListLit (EApp (EVar "escStr") (EVar "name")))))) (EFieldAccess (EVar "v") "sourceName")))))
(DFunDef false "frozenAuthoritySexp" ((PCon "FrozenJoin" (PVar "members"))) (EApp (EApp (EVar "node") (ELit (LString "join"))) (EApp (EApp (EMethodRef "map") (EVar "frozenAuthoritySexp")) (EVar "members"))))
(DFunDef false "frozenAuthoritySexp" ((PCon "FrozenProduct" (PVar "axes"))) (EApp (EApp (EVar "node") (ELit (LString "product"))) (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "name") (PVar "authority"))) (EApp (EVar "slist") (EListLit (EApp (EVar "escStr") (EVar "name")) (EApp (EVar "frozenAuthoritySexp") (EVar "authority")))))) (EVar "axes"))))
(DTypeSig false "manifestParamSexp" (TyFun (TyCon "Param") (TyCon "String")))
(DFunDef false "manifestParamSexp" ((PCon "PUnit")) (ELit (LString "unit")))
(DFunDef false "manifestParamSexp" ((PCon "PPrefix" (PVar "value"))) (EApp (EApp (EVar "node") (ELit (LString "prefix"))) (EListLit (EApp (EVar "manifestStringSexp") (EVar "value")))))
(DFunDef false "manifestParamSexp" ((PCon "PPath" (PVar "value"))) (EApp (EApp (EVar "node") (ELit (LString "path"))) (EListLit (EApp (EVar "manifestStringSexp") (EVar "value")))))
(DFunDef false "manifestParamSexp" ((PCon "PSet" (PVar "value"))) (EApp (EApp (EVar "node") (ELit (LString "set"))) (EListLit (EApp (EApp (EApp (EVar "option") (ELit (LString "none"))) (ELam ((PVar "members")) (EApp (EApp (EVar "node") (ELit (LString "some"))) (EApp (EApp (EMethodRef "map") (EVar "escStr")) (EVar "members"))))) (EVar "value")))))
(DFunDef false "manifestParamSexp" ((PCon "PProduct" (PVar "axes"))) (EApp (EApp (EVar "node") (ELit (LString "axes"))) (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "name") (PVar "value"))) (EApp (EVar "slist") (EListLit (EApp (EVar "escStr") (EVar "name")) (EApp (EVar "manifestParamSexp") (EVar "value")))))) (EVar "axes"))))
(DTypeSig false "manifestStringSexp" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyCon "String")))
(DFunDef false "manifestStringSexp" () (EApp (EApp (EVar "option") (ELit (LString "none"))) (ELam ((PVar "value")) (EApp (EApp (EVar "node") (ELit (LString "some"))) (EListLit (EApp (EVar "escStr") (EVar "value")))))))
