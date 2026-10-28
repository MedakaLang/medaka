# META
source_lines=271
stages=DESUGAR,MARK
# SOURCE
import json.{Json(..), jObject, jArray}
import frontend.ast.{
  Decl(..), ExternDecl(..), Loc(..), Variant(..), LetBind(..), ConPayload(..),
  fieldName, ifaceMethodName, implMethodName, letBindName
}
import frontend.parser.{
  DeclPos, positionsDecls, declPosLine, declPosEndLine, declPosNameLoc,
  declPosChildLocs, parseWithPositionsOpt
}
import frontend.recovery_result.{recoveredDecls, recoveredPositions}
import support.source_index.{
  SourceIndex, indexSource, sourcePositionToOffset, offsetToUtf16Position
}
import tools.lsp_positions.{locToLspRange}
import tools.source_snapshot.{
  SourceSnapshot(..), SnapshotMismatch(..), snapshotId, snapshotSyntaxId,
  snapshotSyntaxMatches, snapshotSyntaxResult, SnapshotSyntax
}

export
jPosition : Int -> Int -> Json
jPosition line ch = jObject [("line", JInt line), ("character", JInt ch)]
export
jRange : Int -> Int -> Int -> Int -> Json
jRange sl sc el ec =
  jObject [("start", jPosition sl sc), ("end", jPosition el ec)]
jRangeOfLoc : SourceIndex -> Loc -> Json
jRangeOfLoc index loc = optionOr JNull (locToLspRange index loc)
export
innerDecl : Decl -> Decl
innerDecl (DAttrib _ d) = innerDecl d
innerDecl d = d

-- `range` = the decl's whole line span; `selRange` = the LSP `selectionRange`
-- (#331: the decl's real NAME-token span when known, else the same as
-- `range` — see `renderSymbol`). Kept as separate params (rather than always
-- reusing `range`) so a real name span can differ from the enclosing range.
jSymbol : String -> Int -> Json -> Json -> List Json -> Json
jSymbol name kind range selRange children = jObject [
  ("name", JString name),
  ("kind", JInt kind),
  ("range", range),
  ("selectionRange", selRange),
  ("children", jArray children),
]

-- One outline child symbol carrying its OWN name-token range/selectionRange
-- (#331, increment 2): use the child's name `Loc` when the parser found one,
-- else fall back to the parent decl `range` (`fallback`).  Both `range` and
-- `selectionRange` are the name span (a leaf symbol has no distinct enclosing
-- range).
jChildLoc : SourceIndex -> String -> Int -> Json -> Option Loc -> Json
jChildLoc index name kind fallback loc =
  let r = match loc
    Some l => jRangeOfLoc index l
    None => fallback
  jSymbol name kind r r []

-- Outline children for the variant list of a data decl, consuming child-name
-- `Loc`s (#331, increment 2) from `locs` in outline order.  Mirrors the old
-- `flatMap variantSymChildren`: a nameOmitted record variant (`data X = { … }`)
-- exposes one Field symbol (kind 8) per field; any other variant shows its
-- single constructor name (kind 22).  The parser's `declChildSpansOf`
-- produces `locs` in exactly this order — keep the two in lockstep.
variantKids : SourceIndex ->
  Json ->
  List (Option Loc) ->
  List Variant ->
  List Json
variantKids index fb locs variants = go locs variants
  where
    go _ [] = []
    go spans ((Variant _ (ConNamed fs True)) :: vs) =
      let step = fieldKidsStep index fb spans (map fieldName fs)
      fst step ++ go (snd step) vs
    go [] ((Variant vn _) :: vs) = jChildLoc index vn 22 fb None :: go [] vs
    go (l :: ls) ((Variant vn _) :: vs) = jChildLoc index vn 22 fb l :: go ls vs

-- One Field child (kind 8) per field name, consuming a `Loc` each; returns the
-- kids plus the leftover `Loc`s for the next variant.
fieldKidsStep : SourceIndex ->
  Json ->
  List (Option Loc) ->
  List String ->
  (List Json, List (Option Loc))
fieldKidsStep index fb locs names = go locs names
  where
    go spans [] = ([], spans)
    go [] (fn :: fns) =
      let rest = go [] fns
      (jChildLoc index fn 8 fb None :: fst rest, snd rest)
    go (l :: ls) (fn :: fns) =
      let rest = go ls fns
      (jChildLoc index fn 8 fb l :: fst rest, snd rest)

-- 1:1 child symbols for a fixed-shape child list (methods, let-binds),
-- consuming a `Loc` each in order.
zipKids : SourceIndex ->
  Json ->
  Int ->
  List (Option Loc) ->
  List String ->
  List Json
zipKids _ _ _ _ [] = []
zipKids index fb kind [] (nm :: nms) =
  jChildLoc index nm kind fb None :: zipKids index fb kind [] nms
zipKids index fb kind (l :: ls) (nm :: nms) =
  jChildLoc index nm kind fb l :: zipKids index fb kind ls nms

-- The outline (name, kind, clauseLike, children) for a decl, given its
-- precomputed decl-level `range` (used for the child symbols' spans), or None for
-- decls that don't surface in the outline (DUse).  The decl's own range is
-- reattached by the caller (symbolParts), which also spans it across collapsed
-- clauses.  `clauseLike` is True ONLY for a signature or a value-binding clause
-- (DTypeSig/DFunDef/DLetGroup) — the decls that legitimately repeat under one name
-- (a sig + its clauses) and so may coalesce.  Everything else is False: crucially
-- DTest/DProp take a FREE string label (`test "double"`) that resolve.mdk
-- never enters into any namespace or duplicate check, so a test named after the
-- function it tests must NOT be swallowed into that function's outline entry.
-- `childLocs` (#331, increment 2) is the parser's ordered list of this decl's
-- child name-token `Loc`s (`declPosChildLocs`), consumed in the SAME order the
-- children are emitted below.  The order here IS the invariant the parser's
-- `declChildSpansOf` mirrors — change one, change both.
symbolPartsOfDecl : SourceIndex ->
  Decl ->
  Json ->
  List (Option Loc) ->
  Option (String, Int, Bool, List Json)
symbolPartsOfDecl index d range childLocs = match innerDecl d
  DTypeSig _ name _ _ => Some (name, 13, True, [])
  DExtern (ExternDecl { edName = name, ... }) => Some (name, 12, False, [])
  DFunDef _ name _ _ _ _ => Some (name, 12, True, [])
  DLetGroup _ binds => match binds
    [] => None
    (LetBind n0 _ _ _) :: _ =>
      let kids = zipKids index range 12 childLocs (map letBindName binds)
      Some (n0, 12, True, kids)
  DData { dataName = name, dataCtors = variants } =>
    -- records (the `data X = { … }` short form, nameOmitted) expose their
    -- fields as child symbols (kind 8); ordinary variants show their ctor name.
    let kids = variantKids index range childLocs variants
    Some (name, 10, False, kids)
  DInterface { name = n, methods = ms, ... } =>
    let kids = zipKids index range 6 childLocs (map ifaceMethodName ms)
    Some (n, 11, False, kids)
  DImpl { iface = ifc, methods = ms, ... } =>
    let label = implLabel ifc
    let kids = zipKids index range 6 childLocs (map implMethodName ms)
    Some (label, 5, False, kids)
  DTypeAlias { tyAliasName = name } => Some (name, 26, False, [])
  DNewtype { newtypeName = name } => Some (name, 23, False, [])
  DUse _ _ _ => None
  DProp _ name _ _ => Some (name, 12, False, [])
  DTest _ name _ => Some (name, 12, False, [])
  DEffect _ name _ _ _ _ => Some (name, 24, False, [])
  DAttrib _ _ => None  -- unreachable post innerDecl
-- Variable
-- Function
-- Function

-- EnumMember
-- Enum

-- Field
-- Struct

-- Interface

-- Class
-- TypeParameter
-- Struct

-- Event

-- "impl Iface" / "Name of impl Iface" label (mirror handle_document_symbol's).
implLabel : String -> String
implLabel iface = stringConcat ["impl ", iface]

export
wholeLineRange : SourceIndex -> Int -> Int -> Int -> Json
wholeLineRange index len sl el = match sourcePositionToOffset index (el + 1) 0
  Some _ => jRange sl 0 el 0
  None => match offsetToUtf16Position index len
    Some (line, col) => jRange sl 0 line col
    None => JNull

-- One outline row before collapse: name, LSP SymbolKind, 0-based start/end line,
-- whether it's a signature/clause row (only those coalesce — see
-- symbolPartsOfDecl), its child symbols, and its NAME-token `Loc` (#331,
-- `None` when the decl has no single name token or the finder missed — see
-- `declNameTokIdxAt`).  A dedicated type rather than a tuple because it
-- carries 7 fields (past the tuple ceiling) and reads better.
data SymRow = SymRow String Int Int Int Bool (List Json) (Option Loc)

-- Zip decls with positions (1:1; defensive truncation to the shorter list) into
-- SymRow rows, dropping non-outline decls.
symbolParts : SourceIndex -> Int -> List Decl -> List DeclPos -> List SymRow
symbolParts index len decls positions = go decls positions
  where
    go (d :: ds) (p :: ps) =
      let sl = declPosLine p - 1
      let el = declPosEndLine p
      match (symbolPartsOfDecl
        index
        d
        (wholeLineRange index len sl el)
        (declPosChildLocs p))
        None => go ds ps
        Some (name, kind, clauseLike, kids) =>
          SymRow name kind sl el clauseLike kids (declPosNameLoc p) :: go ds ps
    go _ _ = []

-- Collapse a signature+clauses run — consecutive rows that share the EXACT same
-- name AND are BOTH clause-like — into ONE outline symbol (#300 part 3): the
-- shared name, the LAST row's kind (so a `sig`(Variable)+`def`(Function) pair
-- reads as the Function, not the sig), the range spanning first-start..last-end,
-- and the concatenated children.  The clause-like gate is what stops a
-- `test "double"`/`prop` (free string label, never a duplicate) from being
-- fused into an adjacent same-named function; only sig/clause runs coalesce, and
-- only adjacent ones, so decls that merely share a prefix are never merged either.
-- The collapsed row keeps the FIRST clause's name `Loc` (`nl0`) — it pairs with
-- the kept start line `s0`, same as the OCaml/line-based fields already do.
collapseSymbols : List SymRow -> List SymRow
collapseSymbols [] = []
collapseSymbols (x :: xs) = collapseGo x xs

collapseGo : SymRow -> List SymRow -> List SymRow
collapseGo cur [] = [cur]
collapseGo (SymRow n0 k0 s0 e0 cl0 c0 nl0) ((SymRow n1 k1 s1 e1 cl1 c1 nl1) :: rest) =
  if n0 == n1 && cl0 && cl1 then
    collapseGo (SymRow n0 k1 s0 e1 True (c0 ++ c1) nl0) rest
  else
    SymRow n0 k0 s0 e0 cl0 c0 nl0
      :: collapseGo (SymRow n1 k1 s1 e1 cl1 c1 nl1) rest

renderSymbol : SourceIndex -> Int -> SymRow -> Json
renderSymbol index len (SymRow name kind sl el _ kids nameLoc) =
  let range = wholeLineRange index len sl el
  let selRange = match nameLoc
    Some l => jRangeOfLoc index l
    None => range
  jSymbol name kind range selRange kids

export
strictDocumentSymbols : String -> List Json
strictDocumentSymbols src = match parseWithPositionsOpt src
  None => []
  Some (decls, positions) =>
    let index = indexSource src
    let len = stringLength src
    positionsDecls positions
      |> symbolParts index len decls
      |> collapseSymbols
      |> map (renderSymbol index len)

export
symbolsFromRecovered : SourceSnapshot ->
  SnapshotSyntax ->
  Result SnapshotMismatch (List Json)
symbolsFromRecovered snapshot syntax =
  if not (snapshotSyntaxMatches snapshot syntax) then
    Err (SnapshotMismatch (snapshotSyntaxId syntax) (snapshotId snapshot))
  else match snapshot
    SourceSnapshot _ _ _ src index =>
      let result = snapshotSyntaxResult syntax
      let len = stringLength src
      Ok
        (positionsDecls (recoveredPositions result)
          |> symbolParts index len (recoveredDecls result)
          |> collapseSymbols
          |> map (renderSymbol index len))
# DESUGAR
(DUse false (UseGroup ("json") ((mem "Json" true) (mem "jObject" false) (mem "jArray" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "ExternDecl" true) (mem "Loc" true) (mem "Variant" true) (mem "LetBind" true) (mem "ConPayload" true) (mem "fieldName" false) (mem "ifaceMethodName" false) (mem "implMethodName" false) (mem "letBindName" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "DeclPos" false) (mem "positionsDecls" false) (mem "declPosLine" false) (mem "declPosEndLine" false) (mem "declPosNameLoc" false) (mem "declPosChildLocs" false) (mem "parseWithPositionsOpt" false))))
(DUse false (UseGroup ("frontend" "recovery_result") ((mem "recoveredDecls" false) (mem "recoveredPositions" false))))
(DUse false (UseGroup ("support" "source_index") ((mem "SourceIndex" false) (mem "indexSource" false) (mem "sourcePositionToOffset" false) (mem "offsetToUtf16Position" false))))
(DUse false (UseGroup ("tools" "lsp_positions") ((mem "locToLspRange" false))))
(DUse false (UseGroup ("tools" "source_snapshot") ((mem "SourceSnapshot" true) (mem "SnapshotMismatch" true) (mem "snapshotId" false) (mem "snapshotSyntaxId" false) (mem "snapshotSyntaxMatches" false) (mem "snapshotSyntaxResult" false) (mem "SnapshotSyntax" false))))
(DTypeSig true "jPosition" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Json"))))
(DFunDef false "jPosition" ((PVar "line") (PVar "ch")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "line")) (EApp (EVar "JInt") (EVar "line"))) (ETuple (ELit (LString "character")) (EApp (EVar "JInt") (EVar "ch"))))))
(DTypeSig true "jRange" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Json"))))))
(DFunDef false "jRange" ((PVar "sl") (PVar "sc") (PVar "el") (PVar "ec")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "start")) (EApp (EApp (EVar "jPosition") (EVar "sl")) (EVar "sc"))) (ETuple (ELit (LString "end")) (EApp (EApp (EVar "jPosition") (EVar "el")) (EVar "ec"))))))
(DTypeSig false "jRangeOfLoc" (TyFun (TyCon "SourceIndex") (TyFun (TyCon "Loc") (TyCon "Json"))))
(DFunDef false "jRangeOfLoc" ((PVar "index") (PVar "loc")) (EApp (EApp (EVar "optionOr") (EVar "JNull")) (EApp (EApp (EVar "locToLspRange") (EVar "index")) (EVar "loc"))))
(DTypeSig true "innerDecl" (TyFun (TyCon "Decl") (TyCon "Decl")))
(DFunDef false "innerDecl" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "innerDecl") (EVar "d")))
(DFunDef false "innerDecl" ((PVar "d")) (EVar "d"))
(DTypeSig false "jSymbol" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Json") (TyFun (TyCon "Json") (TyFun (TyApp (TyCon "List") (TyCon "Json")) (TyCon "Json")))))))
(DFunDef false "jSymbol" ((PVar "name") (PVar "kind") (PVar "range") (PVar "selRange") (PVar "children")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "name")) (EApp (EVar "JString") (EVar "name"))) (ETuple (ELit (LString "kind")) (EApp (EVar "JInt") (EVar "kind"))) (ETuple (ELit (LString "range")) (EVar "range")) (ETuple (ELit (LString "selectionRange")) (EVar "selRange")) (ETuple (ELit (LString "children")) (EApp (EVar "jArray") (EVar "children"))))))
(DTypeSig false "jChildLoc" (TyFun (TyCon "SourceIndex") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Json") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Json")))))))
(DFunDef false "jChildLoc" ((PVar "index") (PVar "name") (PVar "kind") (PVar "fallback") (PVar "loc")) (EBlock (DoLet false false (PVar "r") (EMatch (EVar "loc") (arm (PCon "Some" (PVar "l")) () (EApp (EApp (EVar "jRangeOfLoc") (EVar "index")) (EVar "l"))) (arm (PCon "None") () (EVar "fallback")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "jSymbol") (EVar "name")) (EVar "kind")) (EVar "r")) (EVar "r")) (EListLit)))))
(DTypeSig false "variantKids" (TyFun (TyCon "SourceIndex") (TyFun (TyCon "Json") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyApp (TyCon "List") (TyCon "Json")))))))
(DFunDef false "variantKids" ((PVar "index") (PVar "fb") (PVar "locs") (PVar "variants")) (ELetGroup ((lgb "go" (clause (PWild (PList)) (EListLit)) (clause ((PVar "spans") (PCons (PCon "Variant" PWild (PCon "ConNamed" (PVar "fs") (PCon "True"))) (PVar "vs"))) (EBlock (DoLet false false (PVar "step") (EApp (EApp (EApp (EApp (EVar "fieldKidsStep") (EVar "index")) (EVar "fb")) (EVar "spans")) (EApp (EApp (EVar "map") (EVar "fieldName")) (EVar "fs")))) (DoExpr (EBinOp "++" (EApp (EVar "fst") (EVar "step")) (EApp (EApp (EVar "go") (EApp (EVar "snd") (EVar "step"))) (EVar "vs")))))) (clause ((PList) (PCons (PCon "Variant" (PVar "vn") PWild) (PVar "vs"))) (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EVar "jChildLoc") (EVar "index")) (EVar "vn")) (ELit (LInt 22))) (EVar "fb")) (EVar "None")) (EApp (EApp (EVar "go") (EListLit)) (EVar "vs")))) (clause ((PCons (PVar "l") (PVar "ls")) (PCons (PCon "Variant" (PVar "vn") PWild) (PVar "vs"))) (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EVar "jChildLoc") (EVar "index")) (EVar "vn")) (ELit (LInt 22))) (EVar "fb")) (EVar "l")) (EApp (EApp (EVar "go") (EVar "ls")) (EVar "vs")))))) (EApp (EApp (EVar "go") (EVar "locs")) (EVar "variants"))))
(DTypeSig false "fieldKidsStep" (TyFun (TyCon "SourceIndex") (TyFun (TyCon "Json") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyTuple (TyApp (TyCon "List") (TyCon "Json")) (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Loc")))))))))
(DFunDef false "fieldKidsStep" ((PVar "index") (PVar "fb") (PVar "locs") (PVar "names")) (ELetGroup ((lgb "go" (clause ((PVar "spans") (PList)) (ETuple (EListLit) (EVar "spans"))) (clause ((PList) (PCons (PVar "fn") (PVar "fns"))) (EBlock (DoLet false false (PVar "rest") (EApp (EApp (EVar "go") (EListLit)) (EVar "fns"))) (DoExpr (ETuple (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EVar "jChildLoc") (EVar "index")) (EVar "fn")) (ELit (LInt 8))) (EVar "fb")) (EVar "None")) (EApp (EVar "fst") (EVar "rest"))) (EApp (EVar "snd") (EVar "rest")))))) (clause ((PCons (PVar "l") (PVar "ls")) (PCons (PVar "fn") (PVar "fns"))) (EBlock (DoLet false false (PVar "rest") (EApp (EApp (EVar "go") (EVar "ls")) (EVar "fns"))) (DoExpr (ETuple (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EVar "jChildLoc") (EVar "index")) (EVar "fn")) (ELit (LInt 8))) (EVar "fb")) (EVar "l")) (EApp (EVar "fst") (EVar "rest"))) (EApp (EVar "snd") (EVar "rest")))))))) (EApp (EApp (EVar "go") (EVar "locs")) (EVar "names"))))
(DTypeSig false "zipKids" (TyFun (TyCon "SourceIndex") (TyFun (TyCon "Json") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Json"))))))))
(DFunDef false "zipKids" (PWild PWild PWild PWild (PList)) (EListLit))
(DFunDef false "zipKids" ((PVar "index") (PVar "fb") (PVar "kind") (PList) (PCons (PVar "nm") (PVar "nms"))) (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EVar "jChildLoc") (EVar "index")) (EVar "nm")) (EVar "kind")) (EVar "fb")) (EVar "None")) (EApp (EApp (EApp (EApp (EApp (EVar "zipKids") (EVar "index")) (EVar "fb")) (EVar "kind")) (EListLit)) (EVar "nms"))))
(DFunDef false "zipKids" ((PVar "index") (PVar "fb") (PVar "kind") (PCons (PVar "l") (PVar "ls")) (PCons (PVar "nm") (PVar "nms"))) (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EVar "jChildLoc") (EVar "index")) (EVar "nm")) (EVar "kind")) (EVar "fb")) (EVar "l")) (EApp (EApp (EApp (EApp (EApp (EVar "zipKids") (EVar "index")) (EVar "fb")) (EVar "kind")) (EVar "ls")) (EVar "nms"))))
(DTypeSig false "symbolPartsOfDecl" (TyFun (TyCon "SourceIndex") (TyFun (TyCon "Decl") (TyFun (TyCon "Json") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Bool") (TyApp (TyCon "List") (TyCon "Json")))))))))
(DFunDef false "symbolPartsOfDecl" ((PVar "index") (PVar "d") (PVar "range") (PVar "childLocs")) (EMatch (EApp (EVar "innerDecl") (EVar "d")) (arm (PCon "DTypeSig" PWild (PVar "name") PWild PWild) () (EApp (EVar "Some") (ETuple (EVar "name") (ELit (LInt 13)) (EVar "True") (EListLit)))) (arm (PCon "DExtern" (PRec "ExternDecl" ((rf "edName" (PVar "name"))) true)) () (EApp (EVar "Some") (ETuple (EVar "name") (ELit (LInt 12)) (EVar "False") (EListLit)))) (arm (PCon "DFunDef" PWild (PVar "name") PWild PWild PWild PWild) () (EApp (EVar "Some") (ETuple (EVar "name") (ELit (LInt 12)) (EVar "True") (EListLit)))) (arm (PCon "DLetGroup" PWild (PVar "binds")) () (EMatch (EVar "binds") (arm (PList) () (EVar "None")) (arm (PCons (PCon "LetBind" (PVar "n0") PWild PWild PWild) PWild) () (EBlock (DoLet false false (PVar "kids") (EApp (EApp (EApp (EApp (EApp (EVar "zipKids") (EVar "index")) (EVar "range")) (ELit (LInt 12))) (EVar "childLocs")) (EApp (EApp (EVar "map") (EVar "letBindName")) (EVar "binds")))) (DoExpr (EApp (EVar "Some") (ETuple (EVar "n0") (ELit (LInt 12)) (EVar "True") (EVar "kids")))))))) (arm (PRec "DData" ((rf "dataName" (PVar "name")) (rf "dataCtors" (PVar "variants"))) false) () (EBlock (DoLet false false (PVar "kids") (EApp (EApp (EApp (EApp (EVar "variantKids") (EVar "index")) (EVar "range")) (EVar "childLocs")) (EVar "variants"))) (DoExpr (EApp (EVar "Some") (ETuple (EVar "name") (ELit (LInt 10)) (EVar "False") (EVar "kids")))))) (arm (PRec "DInterface" ((rf "name" (PVar "n")) (rf "methods" (PVar "ms"))) true) () (EBlock (DoLet false false (PVar "kids") (EApp (EApp (EApp (EApp (EApp (EVar "zipKids") (EVar "index")) (EVar "range")) (ELit (LInt 6))) (EVar "childLocs")) (EApp (EApp (EVar "map") (EVar "ifaceMethodName")) (EVar "ms")))) (DoExpr (EApp (EVar "Some") (ETuple (EVar "n") (ELit (LInt 11)) (EVar "False") (EVar "kids")))))) (arm (PRec "DImpl" ((rf "iface" (PVar "ifc")) (rf "methods" (PVar "ms"))) true) () (EBlock (DoLet false false (PVar "label") (EApp (EVar "implLabel") (EVar "ifc"))) (DoLet false false (PVar "kids") (EApp (EApp (EApp (EApp (EApp (EVar "zipKids") (EVar "index")) (EVar "range")) (ELit (LInt 6))) (EVar "childLocs")) (EApp (EApp (EVar "map") (EVar "implMethodName")) (EVar "ms")))) (DoExpr (EApp (EVar "Some") (ETuple (EVar "label") (ELit (LInt 5)) (EVar "False") (EVar "kids")))))) (arm (PRec "DTypeAlias" ((rf "tyAliasName" (PVar "name"))) false) () (EApp (EVar "Some") (ETuple (EVar "name") (ELit (LInt 26)) (EVar "False") (EListLit)))) (arm (PRec "DNewtype" ((rf "newtypeName" (PVar "name"))) false) () (EApp (EVar "Some") (ETuple (EVar "name") (ELit (LInt 23)) (EVar "False") (EListLit)))) (arm (PCon "DUse" PWild PWild PWild) () (EVar "None")) (arm (PCon "DProp" PWild (PVar "name") PWild PWild) () (EApp (EVar "Some") (ETuple (EVar "name") (ELit (LInt 12)) (EVar "False") (EListLit)))) (arm (PCon "DTest" PWild (PVar "name") PWild) () (EApp (EVar "Some") (ETuple (EVar "name") (ELit (LInt 12)) (EVar "False") (EListLit)))) (arm (PCon "DEffect" PWild (PVar "name") PWild PWild PWild PWild) () (EApp (EVar "Some") (ETuple (EVar "name") (ELit (LInt 24)) (EVar "False") (EListLit)))) (arm (PCon "DAttrib" PWild PWild) () (EVar "None"))))
(DTypeSig false "implLabel" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "implLabel" ((PVar "iface")) (EApp (EVar "stringConcat") (EListLit (ELit (LString "impl ")) (EVar "iface"))))
(DTypeSig true "wholeLineRange" (TyFun (TyCon "SourceIndex") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Json"))))))
(DFunDef false "wholeLineRange" ((PVar "index") (PVar "len") (PVar "sl") (PVar "el")) (EMatch (EApp (EApp (EApp (EVar "sourcePositionToOffset") (EVar "index")) (EBinOp "+" (EVar "el") (ELit (LInt 1)))) (ELit (LInt 0))) (arm (PCon "Some" PWild) () (EApp (EApp (EApp (EApp (EVar "jRange") (EVar "sl")) (ELit (LInt 0))) (EVar "el")) (ELit (LInt 0)))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "offsetToUtf16Position") (EVar "index")) (EVar "len")) (arm (PCon "Some" (PTuple (PVar "line") (PVar "col"))) () (EApp (EApp (EApp (EApp (EVar "jRange") (EVar "sl")) (ELit (LInt 0))) (EVar "line")) (EVar "col"))) (arm (PCon "None") () (EVar "JNull"))))))
(DData Private "SymRow" () ((variant "SymRow" (ConPos (TyCon "String") (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Bool") (TyApp (TyCon "List") (TyCon "Json")) (TyApp (TyCon "Option") (TyCon "Loc"))))) ())
(DTypeSig false "symbolParts" (TyFun (TyCon "SourceIndex") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "DeclPos")) (TyApp (TyCon "List") (TyCon "SymRow")))))))
(DFunDef false "symbolParts" ((PVar "index") (PVar "len") (PVar "decls") (PVar "positions")) (ELetGroup ((lgb "go" (clause ((PCons (PVar "d") (PVar "ds")) (PCons (PVar "p") (PVar "ps"))) (EBlock (DoLet false false (PVar "sl") (EBinOp "-" (EApp (EVar "declPosLine") (EVar "p")) (ELit (LInt 1)))) (DoLet false false (PVar "el") (EApp (EVar "declPosEndLine") (EVar "p"))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EVar "symbolPartsOfDecl") (EVar "index")) (EVar "d")) (EApp (EApp (EApp (EApp (EVar "wholeLineRange") (EVar "index")) (EVar "len")) (EVar "sl")) (EVar "el"))) (EApp (EVar "declPosChildLocs") (EVar "p"))) (arm (PCon "None") () (EApp (EApp (EVar "go") (EVar "ds")) (EVar "ps"))) (arm (PCon "Some" (PTuple (PVar "name") (PVar "kind") (PVar "clauseLike") (PVar "kids"))) () (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "SymRow") (EVar "name")) (EVar "kind")) (EVar "sl")) (EVar "el")) (EVar "clauseLike")) (EVar "kids")) (EApp (EVar "declPosNameLoc") (EVar "p"))) (EApp (EApp (EVar "go") (EVar "ds")) (EVar "ps")))))))) (clause (PWild PWild) (EListLit)))) (EApp (EApp (EVar "go") (EVar "decls")) (EVar "positions"))))
(DTypeSig false "collapseSymbols" (TyFun (TyApp (TyCon "List") (TyCon "SymRow")) (TyApp (TyCon "List") (TyCon "SymRow"))))
(DFunDef false "collapseSymbols" ((PList)) (EListLit))
(DFunDef false "collapseSymbols" ((PCons (PVar "x") (PVar "xs"))) (EApp (EApp (EVar "collapseGo") (EVar "x")) (EVar "xs")))
(DTypeSig false "collapseGo" (TyFun (TyCon "SymRow") (TyFun (TyApp (TyCon "List") (TyCon "SymRow")) (TyApp (TyCon "List") (TyCon "SymRow")))))
(DFunDef false "collapseGo" ((PVar "cur") (PList)) (EListLit (EVar "cur")))
(DFunDef false "collapseGo" ((PCon "SymRow" (PVar "n0") (PVar "k0") (PVar "s0") (PVar "e0") (PVar "cl0") (PVar "c0") (PVar "nl0")) (PCons (PCon "SymRow" (PVar "n1") (PVar "k1") (PVar "s1") (PVar "e1") (PVar "cl1") (PVar "c1") (PVar "nl1")) (PVar "rest"))) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "n0") (EVar "n1")) (EVar "cl0")) (EVar "cl1")) (EApp (EApp (EVar "collapseGo") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "SymRow") (EVar "n0")) (EVar "k1")) (EVar "s0")) (EVar "e1")) (EVar "True")) (EBinOp "++" (EVar "c0") (EVar "c1"))) (EVar "nl0"))) (EVar "rest")) (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "SymRow") (EVar "n0")) (EVar "k0")) (EVar "s0")) (EVar "e0")) (EVar "cl0")) (EVar "c0")) (EVar "nl0")) (EApp (EApp (EVar "collapseGo") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "SymRow") (EVar "n1")) (EVar "k1")) (EVar "s1")) (EVar "e1")) (EVar "cl1")) (EVar "c1")) (EVar "nl1"))) (EVar "rest")))))
(DTypeSig false "renderSymbol" (TyFun (TyCon "SourceIndex") (TyFun (TyCon "Int") (TyFun (TyCon "SymRow") (TyCon "Json")))))
(DFunDef false "renderSymbol" ((PVar "index") (PVar "len") (PCon "SymRow" (PVar "name") (PVar "kind") (PVar "sl") (PVar "el") PWild (PVar "kids") (PVar "nameLoc"))) (EBlock (DoLet false false (PVar "range") (EApp (EApp (EApp (EApp (EVar "wholeLineRange") (EVar "index")) (EVar "len")) (EVar "sl")) (EVar "el"))) (DoLet false false (PVar "selRange") (EMatch (EVar "nameLoc") (arm (PCon "Some" (PVar "l")) () (EApp (EApp (EVar "jRangeOfLoc") (EVar "index")) (EVar "l"))) (arm (PCon "None") () (EVar "range")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "jSymbol") (EVar "name")) (EVar "kind")) (EVar "range")) (EVar "selRange")) (EVar "kids")))))
(DTypeSig true "strictDocumentSymbols" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Json"))))
(DFunDef false "strictDocumentSymbols" ((PVar "src")) (EMatch (EApp (EVar "parseWithPositionsOpt") (EVar "src")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PTuple (PVar "decls") (PVar "positions"))) () (EBlock (DoLet false false (PVar "index") (EApp (EVar "indexSource") (EVar "src"))) (DoLet false false (PVar "len") (EApp (EVar "stringLength") (EVar "src"))) (DoExpr (EBinOp "|>" (EBinOp "|>" (EBinOp "|>" (EApp (EVar "positionsDecls") (EVar "positions")) (EApp (EApp (EApp (EVar "symbolParts") (EVar "index")) (EVar "len")) (EVar "decls"))) (EVar "collapseSymbols")) (EApp (EVar "map") (EApp (EApp (EVar "renderSymbol") (EVar "index")) (EVar "len")))))))))
(DTypeSig true "symbolsFromRecovered" (TyFun (TyCon "SourceSnapshot") (TyFun (TyCon "SnapshotSyntax") (TyApp (TyApp (TyCon "Result") (TyCon "SnapshotMismatch")) (TyApp (TyCon "List") (TyCon "Json"))))))
(DFunDef false "symbolsFromRecovered" ((PVar "snapshot") (PVar "syntax")) (EIf (EApp (EVar "not") (EApp (EApp (EVar "snapshotSyntaxMatches") (EVar "snapshot")) (EVar "syntax"))) (EApp (EVar "Err") (EApp (EApp (EVar "SnapshotMismatch") (EApp (EVar "snapshotSyntaxId") (EVar "syntax"))) (EApp (EVar "snapshotId") (EVar "snapshot")))) (EMatch (EVar "snapshot") (arm (PCon "SourceSnapshot" PWild PWild PWild (PVar "src") (PVar "index")) () (EBlock (DoLet false false (PVar "result") (EApp (EVar "snapshotSyntaxResult") (EVar "syntax"))) (DoLet false false (PVar "len") (EApp (EVar "stringLength") (EVar "src"))) (DoExpr (EApp (EVar "Ok") (EBinOp "|>" (EBinOp "|>" (EBinOp "|>" (EApp (EVar "positionsDecls") (EApp (EVar "recoveredPositions") (EVar "result"))) (EApp (EApp (EApp (EVar "symbolParts") (EVar "index")) (EVar "len")) (EApp (EVar "recoveredDecls") (EVar "result")))) (EVar "collapseSymbols")) (EApp (EVar "map") (EApp (EApp (EVar "renderSymbol") (EVar "index")) (EVar "len")))))))))))
# MARK
(DUse false (UseGroup ("json") ((mem "Json" true) (mem "jObject" false) (mem "jArray" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "ExternDecl" true) (mem "Loc" true) (mem "Variant" true) (mem "LetBind" true) (mem "ConPayload" true) (mem "fieldName" false) (mem "ifaceMethodName" false) (mem "implMethodName" false) (mem "letBindName" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "DeclPos" false) (mem "positionsDecls" false) (mem "declPosLine" false) (mem "declPosEndLine" false) (mem "declPosNameLoc" false) (mem "declPosChildLocs" false) (mem "parseWithPositionsOpt" false))))
(DUse false (UseGroup ("frontend" "recovery_result") ((mem "recoveredDecls" false) (mem "recoveredPositions" false))))
(DUse false (UseGroup ("support" "source_index") ((mem "SourceIndex" false) (mem "indexSource" false) (mem "sourcePositionToOffset" false) (mem "offsetToUtf16Position" false))))
(DUse false (UseGroup ("tools" "lsp_positions") ((mem "locToLspRange" false))))
(DUse false (UseGroup ("tools" "source_snapshot") ((mem "SourceSnapshot" true) (mem "SnapshotMismatch" true) (mem "snapshotId" false) (mem "snapshotSyntaxId" false) (mem "snapshotSyntaxMatches" false) (mem "snapshotSyntaxResult" false) (mem "SnapshotSyntax" false))))
(DTypeSig true "jPosition" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Json"))))
(DFunDef false "jPosition" ((PVar "line") (PVar "ch")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "line")) (EApp (EVar "JInt") (EVar "line"))) (ETuple (ELit (LString "character")) (EApp (EVar "JInt") (EVar "ch"))))))
(DTypeSig true "jRange" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Json"))))))
(DFunDef false "jRange" ((PVar "sl") (PVar "sc") (PVar "el") (PVar "ec")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "start")) (EApp (EApp (EVar "jPosition") (EVar "sl")) (EVar "sc"))) (ETuple (ELit (LString "end")) (EApp (EApp (EVar "jPosition") (EVar "el")) (EVar "ec"))))))
(DTypeSig false "jRangeOfLoc" (TyFun (TyCon "SourceIndex") (TyFun (TyCon "Loc") (TyCon "Json"))))
(DFunDef false "jRangeOfLoc" ((PVar "index") (PVar "loc")) (EApp (EApp (EVar "optionOr") (EVar "JNull")) (EApp (EApp (EVar "locToLspRange") (EMethodRef "index")) (EVar "loc"))))
(DTypeSig true "innerDecl" (TyFun (TyCon "Decl") (TyCon "Decl")))
(DFunDef false "innerDecl" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "innerDecl") (EVar "d")))
(DFunDef false "innerDecl" ((PVar "d")) (EVar "d"))
(DTypeSig false "jSymbol" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Json") (TyFun (TyCon "Json") (TyFun (TyApp (TyCon "List") (TyCon "Json")) (TyCon "Json")))))))
(DFunDef false "jSymbol" ((PVar "name") (PVar "kind") (PVar "range") (PVar "selRange") (PVar "children")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "name")) (EApp (EVar "JString") (EVar "name"))) (ETuple (ELit (LString "kind")) (EApp (EVar "JInt") (EVar "kind"))) (ETuple (ELit (LString "range")) (EVar "range")) (ETuple (ELit (LString "selectionRange")) (EVar "selRange")) (ETuple (ELit (LString "children")) (EApp (EVar "jArray") (EVar "children"))))))
(DTypeSig false "jChildLoc" (TyFun (TyCon "SourceIndex") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Json") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Json")))))))
(DFunDef false "jChildLoc" ((PVar "index") (PVar "name") (PVar "kind") (PVar "fallback") (PVar "loc")) (EBlock (DoLet false false (PVar "r") (EMatch (EVar "loc") (arm (PCon "Some" (PVar "l")) () (EApp (EApp (EVar "jRangeOfLoc") (EMethodRef "index")) (EVar "l"))) (arm (PCon "None") () (EVar "fallback")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "jSymbol") (EVar "name")) (EVar "kind")) (EVar "r")) (EVar "r")) (EListLit)))))
(DTypeSig false "variantKids" (TyFun (TyCon "SourceIndex") (TyFun (TyCon "Json") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyApp (TyCon "List") (TyCon "Json")))))))
(DFunDef false "variantKids" ((PVar "index") (PVar "fb") (PVar "locs") (PVar "variants")) (ELetGroup ((lgb "go" (clause (PWild (PList)) (EListLit)) (clause ((PVar "spans") (PCons (PCon "Variant" PWild (PCon "ConNamed" (PVar "fs") (PCon "True"))) (PVar "vs"))) (EBlock (DoLet false false (PVar "step") (EApp (EApp (EApp (EApp (EVar "fieldKidsStep") (EMethodRef "index")) (EVar "fb")) (EVar "spans")) (EApp (EApp (EMethodRef "map") (EVar "fieldName")) (EVar "fs")))) (DoExpr (EBinOp "++" (EApp (EVar "fst") (EVar "step")) (EApp (EApp (EVar "go") (EApp (EVar "snd") (EVar "step"))) (EVar "vs")))))) (clause ((PList) (PCons (PCon "Variant" (PVar "vn") PWild) (PVar "vs"))) (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EVar "jChildLoc") (EMethodRef "index")) (EVar "vn")) (ELit (LInt 22))) (EVar "fb")) (EVar "None")) (EApp (EApp (EVar "go") (EListLit)) (EVar "vs")))) (clause ((PCons (PVar "l") (PVar "ls")) (PCons (PCon "Variant" (PVar "vn") PWild) (PVar "vs"))) (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EVar "jChildLoc") (EMethodRef "index")) (EVar "vn")) (ELit (LInt 22))) (EVar "fb")) (EVar "l")) (EApp (EApp (EVar "go") (EVar "ls")) (EVar "vs")))))) (EApp (EApp (EVar "go") (EVar "locs")) (EVar "variants"))))
(DTypeSig false "fieldKidsStep" (TyFun (TyCon "SourceIndex") (TyFun (TyCon "Json") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyTuple (TyApp (TyCon "List") (TyCon "Json")) (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Loc")))))))))
(DFunDef false "fieldKidsStep" ((PVar "index") (PVar "fb") (PVar "locs") (PVar "names")) (ELetGroup ((lgb "go" (clause ((PVar "spans") (PList)) (ETuple (EListLit) (EVar "spans"))) (clause ((PList) (PCons (PVar "fn") (PVar "fns"))) (EBlock (DoLet false false (PVar "rest") (EApp (EApp (EVar "go") (EListLit)) (EVar "fns"))) (DoExpr (ETuple (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EVar "jChildLoc") (EMethodRef "index")) (EVar "fn")) (ELit (LInt 8))) (EVar "fb")) (EVar "None")) (EApp (EVar "fst") (EVar "rest"))) (EApp (EVar "snd") (EVar "rest")))))) (clause ((PCons (PVar "l") (PVar "ls")) (PCons (PVar "fn") (PVar "fns"))) (EBlock (DoLet false false (PVar "rest") (EApp (EApp (EVar "go") (EVar "ls")) (EVar "fns"))) (DoExpr (ETuple (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EVar "jChildLoc") (EMethodRef "index")) (EVar "fn")) (ELit (LInt 8))) (EVar "fb")) (EVar "l")) (EApp (EVar "fst") (EVar "rest"))) (EApp (EVar "snd") (EVar "rest")))))))) (EApp (EApp (EVar "go") (EVar "locs")) (EVar "names"))))
(DTypeSig false "zipKids" (TyFun (TyCon "SourceIndex") (TyFun (TyCon "Json") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Json"))))))))
(DFunDef false "zipKids" (PWild PWild PWild PWild (PList)) (EListLit))
(DFunDef false "zipKids" ((PVar "index") (PVar "fb") (PVar "kind") (PList) (PCons (PVar "nm") (PVar "nms"))) (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EVar "jChildLoc") (EMethodRef "index")) (EVar "nm")) (EVar "kind")) (EVar "fb")) (EVar "None")) (EApp (EApp (EApp (EApp (EApp (EVar "zipKids") (EMethodRef "index")) (EVar "fb")) (EVar "kind")) (EListLit)) (EVar "nms"))))
(DFunDef false "zipKids" ((PVar "index") (PVar "fb") (PVar "kind") (PCons (PVar "l") (PVar "ls")) (PCons (PVar "nm") (PVar "nms"))) (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EVar "jChildLoc") (EMethodRef "index")) (EVar "nm")) (EVar "kind")) (EVar "fb")) (EVar "l")) (EApp (EApp (EApp (EApp (EApp (EVar "zipKids") (EMethodRef "index")) (EVar "fb")) (EVar "kind")) (EVar "ls")) (EVar "nms"))))
(DTypeSig false "symbolPartsOfDecl" (TyFun (TyCon "SourceIndex") (TyFun (TyCon "Decl") (TyFun (TyCon "Json") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Bool") (TyApp (TyCon "List") (TyCon "Json")))))))))
(DFunDef false "symbolPartsOfDecl" ((PVar "index") (PVar "d") (PVar "range") (PVar "childLocs")) (EMatch (EApp (EVar "innerDecl") (EVar "d")) (arm (PCon "DTypeSig" PWild (PVar "name") PWild PWild) () (EApp (EVar "Some") (ETuple (EVar "name") (ELit (LInt 13)) (EVar "True") (EListLit)))) (arm (PCon "DExtern" (PRec "ExternDecl" ((rf "edName" (PVar "name"))) true)) () (EApp (EVar "Some") (ETuple (EVar "name") (ELit (LInt 12)) (EVar "False") (EListLit)))) (arm (PCon "DFunDef" PWild (PVar "name") PWild PWild PWild PWild) () (EApp (EVar "Some") (ETuple (EVar "name") (ELit (LInt 12)) (EVar "True") (EListLit)))) (arm (PCon "DLetGroup" PWild (PVar "binds")) () (EMatch (EVar "binds") (arm (PList) () (EVar "None")) (arm (PCons (PCon "LetBind" (PVar "n0") PWild PWild PWild) PWild) () (EBlock (DoLet false false (PVar "kids") (EApp (EApp (EApp (EApp (EApp (EVar "zipKids") (EMethodRef "index")) (EVar "range")) (ELit (LInt 12))) (EVar "childLocs")) (EApp (EApp (EMethodRef "map") (EVar "letBindName")) (EVar "binds")))) (DoExpr (EApp (EVar "Some") (ETuple (EVar "n0") (ELit (LInt 12)) (EVar "True") (EVar "kids")))))))) (arm (PRec "DData" ((rf "dataName" (PVar "name")) (rf "dataCtors" (PVar "variants"))) false) () (EBlock (DoLet false false (PVar "kids") (EApp (EApp (EApp (EApp (EVar "variantKids") (EMethodRef "index")) (EVar "range")) (EVar "childLocs")) (EVar "variants"))) (DoExpr (EApp (EVar "Some") (ETuple (EVar "name") (ELit (LInt 10)) (EVar "False") (EVar "kids")))))) (arm (PRec "DInterface" ((rf "name" (PVar "n")) (rf "methods" (PVar "ms"))) true) () (EBlock (DoLet false false (PVar "kids") (EApp (EApp (EApp (EApp (EApp (EVar "zipKids") (EMethodRef "index")) (EVar "range")) (ELit (LInt 6))) (EVar "childLocs")) (EApp (EApp (EMethodRef "map") (EVar "ifaceMethodName")) (EVar "ms")))) (DoExpr (EApp (EVar "Some") (ETuple (EVar "n") (ELit (LInt 11)) (EVar "False") (EVar "kids")))))) (arm (PRec "DImpl" ((rf "iface" (PVar "ifc")) (rf "methods" (PVar "ms"))) true) () (EBlock (DoLet false false (PVar "label") (EApp (EVar "implLabel") (EVar "ifc"))) (DoLet false false (PVar "kids") (EApp (EApp (EApp (EApp (EApp (EVar "zipKids") (EMethodRef "index")) (EVar "range")) (ELit (LInt 6))) (EVar "childLocs")) (EApp (EApp (EMethodRef "map") (EVar "implMethodName")) (EVar "ms")))) (DoExpr (EApp (EVar "Some") (ETuple (EVar "label") (ELit (LInt 5)) (EVar "False") (EVar "kids")))))) (arm (PRec "DTypeAlias" ((rf "tyAliasName" (PVar "name"))) false) () (EApp (EVar "Some") (ETuple (EVar "name") (ELit (LInt 26)) (EVar "False") (EListLit)))) (arm (PRec "DNewtype" ((rf "newtypeName" (PVar "name"))) false) () (EApp (EVar "Some") (ETuple (EVar "name") (ELit (LInt 23)) (EVar "False") (EListLit)))) (arm (PCon "DUse" PWild PWild PWild) () (EVar "None")) (arm (PCon "DProp" PWild (PVar "name") PWild PWild) () (EApp (EVar "Some") (ETuple (EVar "name") (ELit (LInt 12)) (EVar "False") (EListLit)))) (arm (PCon "DTest" PWild (PVar "name") PWild) () (EApp (EVar "Some") (ETuple (EVar "name") (ELit (LInt 12)) (EVar "False") (EListLit)))) (arm (PCon "DEffect" PWild (PVar "name") PWild PWild PWild PWild) () (EApp (EVar "Some") (ETuple (EVar "name") (ELit (LInt 24)) (EVar "False") (EListLit)))) (arm (PCon "DAttrib" PWild PWild) () (EVar "None"))))
(DTypeSig false "implLabel" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "implLabel" ((PVar "iface")) (EApp (EVar "stringConcat") (EListLit (ELit (LString "impl ")) (EVar "iface"))))
(DTypeSig true "wholeLineRange" (TyFun (TyCon "SourceIndex") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Json"))))))
(DFunDef false "wholeLineRange" ((PVar "index") (PVar "len") (PVar "sl") (PVar "el")) (EMatch (EApp (EApp (EApp (EVar "sourcePositionToOffset") (EMethodRef "index")) (EBinOp "+" (EVar "el") (ELit (LInt 1)))) (ELit (LInt 0))) (arm (PCon "Some" PWild) () (EApp (EApp (EApp (EApp (EVar "jRange") (EVar "sl")) (ELit (LInt 0))) (EVar "el")) (ELit (LInt 0)))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "offsetToUtf16Position") (EMethodRef "index")) (EVar "len")) (arm (PCon "Some" (PTuple (PVar "line") (PVar "col"))) () (EApp (EApp (EApp (EApp (EVar "jRange") (EVar "sl")) (ELit (LInt 0))) (EVar "line")) (EVar "col"))) (arm (PCon "None") () (EVar "JNull"))))))
(DData Private "SymRow" () ((variant "SymRow" (ConPos (TyCon "String") (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Bool") (TyApp (TyCon "List") (TyCon "Json")) (TyApp (TyCon "Option") (TyCon "Loc"))))) ())
(DTypeSig false "symbolParts" (TyFun (TyCon "SourceIndex") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "DeclPos")) (TyApp (TyCon "List") (TyCon "SymRow")))))))
(DFunDef false "symbolParts" ((PVar "index") (PVar "len") (PVar "decls") (PVar "positions")) (ELetGroup ((lgb "go" (clause ((PCons (PVar "d") (PVar "ds")) (PCons (PVar "p") (PVar "ps"))) (EBlock (DoLet false false (PVar "sl") (EBinOp "-" (EApp (EVar "declPosLine") (EVar "p")) (ELit (LInt 1)))) (DoLet false false (PVar "el") (EApp (EVar "declPosEndLine") (EVar "p"))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EVar "symbolPartsOfDecl") (EMethodRef "index")) (EVar "d")) (EApp (EApp (EApp (EApp (EVar "wholeLineRange") (EMethodRef "index")) (EVar "len")) (EVar "sl")) (EVar "el"))) (EApp (EVar "declPosChildLocs") (EVar "p"))) (arm (PCon "None") () (EApp (EApp (EVar "go") (EVar "ds")) (EVar "ps"))) (arm (PCon "Some" (PTuple (PVar "name") (PVar "kind") (PVar "clauseLike") (PVar "kids"))) () (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "SymRow") (EVar "name")) (EVar "kind")) (EVar "sl")) (EVar "el")) (EVar "clauseLike")) (EVar "kids")) (EApp (EVar "declPosNameLoc") (EVar "p"))) (EApp (EApp (EVar "go") (EVar "ds")) (EVar "ps")))))))) (clause (PWild PWild) (EListLit)))) (EApp (EApp (EVar "go") (EVar "decls")) (EVar "positions"))))
(DTypeSig false "collapseSymbols" (TyFun (TyApp (TyCon "List") (TyCon "SymRow")) (TyApp (TyCon "List") (TyCon "SymRow"))))
(DFunDef false "collapseSymbols" ((PList)) (EListLit))
(DFunDef false "collapseSymbols" ((PCons (PVar "x") (PVar "xs"))) (EApp (EApp (EVar "collapseGo") (EVar "x")) (EVar "xs")))
(DTypeSig false "collapseGo" (TyFun (TyCon "SymRow") (TyFun (TyApp (TyCon "List") (TyCon "SymRow")) (TyApp (TyCon "List") (TyCon "SymRow")))))
(DFunDef false "collapseGo" ((PVar "cur") (PList)) (EListLit (EVar "cur")))
(DFunDef false "collapseGo" ((PCon "SymRow" (PVar "n0") (PVar "k0") (PVar "s0") (PVar "e0") (PVar "cl0") (PVar "c0") (PVar "nl0")) (PCons (PCon "SymRow" (PVar "n1") (PVar "k1") (PVar "s1") (PVar "e1") (PVar "cl1") (PVar "c1") (PVar "nl1")) (PVar "rest"))) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "n0") (EVar "n1")) (EVar "cl0")) (EVar "cl1")) (EApp (EApp (EVar "collapseGo") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "SymRow") (EVar "n0")) (EVar "k1")) (EVar "s0")) (EVar "e1")) (EVar "True")) (EBinOp "++" (EVar "c0") (EVar "c1"))) (EVar "nl0"))) (EVar "rest")) (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "SymRow") (EVar "n0")) (EVar "k0")) (EVar "s0")) (EVar "e0")) (EVar "cl0")) (EVar "c0")) (EVar "nl0")) (EApp (EApp (EVar "collapseGo") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "SymRow") (EVar "n1")) (EVar "k1")) (EVar "s1")) (EVar "e1")) (EVar "cl1")) (EVar "c1")) (EVar "nl1"))) (EVar "rest")))))
(DTypeSig false "renderSymbol" (TyFun (TyCon "SourceIndex") (TyFun (TyCon "Int") (TyFun (TyCon "SymRow") (TyCon "Json")))))
(DFunDef false "renderSymbol" ((PVar "index") (PVar "len") (PCon "SymRow" (PVar "name") (PVar "kind") (PVar "sl") (PVar "el") PWild (PVar "kids") (PVar "nameLoc"))) (EBlock (DoLet false false (PVar "range") (EApp (EApp (EApp (EApp (EVar "wholeLineRange") (EMethodRef "index")) (EVar "len")) (EVar "sl")) (EVar "el"))) (DoLet false false (PVar "selRange") (EMatch (EVar "nameLoc") (arm (PCon "Some" (PVar "l")) () (EApp (EApp (EVar "jRangeOfLoc") (EMethodRef "index")) (EVar "l"))) (arm (PCon "None") () (EVar "range")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "jSymbol") (EVar "name")) (EVar "kind")) (EVar "range")) (EVar "selRange")) (EVar "kids")))))
(DTypeSig true "strictDocumentSymbols" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Json"))))
(DFunDef false "strictDocumentSymbols" ((PVar "src")) (EMatch (EApp (EVar "parseWithPositionsOpt") (EVar "src")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PTuple (PVar "decls") (PVar "positions"))) () (EBlock (DoLet false false (PVar "index") (EApp (EVar "indexSource") (EVar "src"))) (DoLet false false (PVar "len") (EApp (EVar "stringLength") (EVar "src"))) (DoExpr (EBinOp "|>" (EBinOp "|>" (EBinOp "|>" (EApp (EVar "positionsDecls") (EVar "positions")) (EApp (EApp (EApp (EVar "symbolParts") (EMethodRef "index")) (EVar "len")) (EVar "decls"))) (EVar "collapseSymbols")) (EApp (EMethodRef "map") (EApp (EApp (EVar "renderSymbol") (EMethodRef "index")) (EVar "len")))))))))
(DTypeSig true "symbolsFromRecovered" (TyFun (TyCon "SourceSnapshot") (TyFun (TyCon "SnapshotSyntax") (TyApp (TyApp (TyCon "Result") (TyCon "SnapshotMismatch")) (TyApp (TyCon "List") (TyCon "Json"))))))
(DFunDef false "symbolsFromRecovered" ((PVar "snapshot") (PVar "syntax")) (EIf (EApp (EVar "not") (EApp (EApp (EVar "snapshotSyntaxMatches") (EVar "snapshot")) (EVar "syntax"))) (EApp (EVar "Err") (EApp (EApp (EVar "SnapshotMismatch") (EApp (EVar "snapshotSyntaxId") (EVar "syntax"))) (EApp (EVar "snapshotId") (EVar "snapshot")))) (EMatch (EVar "snapshot") (arm (PCon "SourceSnapshot" PWild PWild PWild (PVar "src") (PVar "index")) () (EBlock (DoLet false false (PVar "result") (EApp (EVar "snapshotSyntaxResult") (EVar "syntax"))) (DoLet false false (PVar "len") (EApp (EVar "stringLength") (EVar "src"))) (DoExpr (EApp (EVar "Ok") (EBinOp "|>" (EBinOp "|>" (EBinOp "|>" (EApp (EVar "positionsDecls") (EApp (EVar "recoveredPositions") (EVar "result"))) (EApp (EApp (EApp (EVar "symbolParts") (EMethodRef "index")) (EVar "len")) (EApp (EVar "recoveredDecls") (EVar "result")))) (EVar "collapseSymbols")) (EApp (EMethodRef "map") (EApp (EApp (EVar "renderSymbol") (EMethodRef "index")) (EVar "len")))))))))))
