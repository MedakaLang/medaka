# META
source_lines=313
stages=DESUGAR,MARK
# SOURCE
-- compiler/tools/codemod.mdk — the `medaka codemod` framework + registry.
--
-- A codemod is a NAMED, source-preserving AST transform: parse a `.mdk` file
-- (WITH positions + comments), rewrite its declarations, and re-render through
-- the comment-preserving formatter (`tools.fmt.formatProgram`).  The registry
-- mirrors `tools.lint`'s `Rule` pattern — adding a codemod is ONE constructor
-- function + ONE entry in `allCodemods`.  The CLI layer (medaka_cli.mdk) never
-- touches the record fields directly; it goes through the exported accessors
-- (`codemodName`/`codemodMk`/`codemodWarnDecls`/…) exactly as it does for lint.
--
-- ── Position/comment invariant (why re-render is safe) ──────────────────────
-- `codemodSource` threads the parser's position side-channels
-- (`positionsDecls`/`positionsVariantLines`/`positionsChainLines`/
-- `positionsLastContentLine`) BACK INTO `formatProgram` UNCHANGED.  That is only
-- sound because a codemod transform NEVER adds, removes, or reorders a decl, a
-- `data` variant, or a continuation-chain operand — it only rewrites TYPES in
-- place.  A transform that violates that (e.g. one that splices a new decl) would
-- desynchronise the side-channels and MUST NOT reuse this core.
--
-- ⚠️ VERBATIM SAFETY-NET CAVEAT.  `formatProgram`'s Option-C net (fmt.mdk:336-417)
-- re-emits a NON-data decl's ORIGINAL source lines verbatim whenever that decl
-- carries an INTERIOR single-line comment the chain/block paths can't anchor.
-- For such a decl the type rewrite is present in the AST but SILENTLY DISCARDED
-- from the rendered output (the original text wins).  Callers doing a bulk strip
-- MUST grep for residue afterwards (the PR-1 harness does exactly this).  Data
-- decls are exempt (their comments are placed per-variant, a reflow-safe path).
--
-- No stdlib imports (compiler isolation): generic helpers come from support.util.
--
-- ⚠️ The total Ty/Decl/Expr rewrite this framework runs on (`mapTyInDecl`) MOVED
-- to `frontend/ast.mdk` in #1110 — resolve's type-constructor origin stamper needs
-- the same walk and a frontend stage cannot import `tools/`.  It is still
-- hand-rolled rather than reusing desugar's `Expr -> Expr` engine, for the reason
-- that put it here originally: the CHANGED flag threads purely (an in-place
-- mutable-cell approach would leak a host capability into the transform's
-- otherwise-pure type).

import frontend.ast.{Ty(..), Loc, Decl(..), mapTyInDecl}
import frontend.parser.{
  parseResult,
  ParseError,
  parseWithPositions,
  positionsDecls,
  positionsVariantLines,
  trailingCommaLocs,
  unitStarts,
}
import frontend.lexer.{collectComments}
import tools.fmt.{formatProgram}
import support.util.{
  reverseL,
  listLen,
  lookupAssoc,
  splitOnChar,
  joinNl,
  anyList,
  dedupBy,
  lenKey,
}

-- ── public types ───────────────────────────────────────────────────────────

-- A registered codemod.  `mk` parses the codemod-specific CLI arguments and
-- returns EITHER an error message OR the per-decl transform `Decl -> (Decl,
-- Bool)` (the Bool = "this decl changed").  `warn`, given the same args plus a
-- file's decls, returns advisory stderr lines the transform can't express (the
-- pure transform can't do IO) — e.g. "you asked to strip a label a `DEffect`
-- here declares".  Most codemods leave `warn` returning `[]`.
public export data Codemod = Codemod {
  name : String,
  descr : String,
  argHelp : String,
  mk : List String -> Result String (Decl -> (Decl, Bool)),
  warn : List String -> List Decl -> List String,
}

-- ── registry ────────────────────────────────────────────────────────────────
-- Adding a codemod = one `mkX`/`warnX` pair + one entry here.
export
allCodemods : List Codemod
allCodemods = [effectLabelsCodemod]

effectLabelsCodemod : Codemod
effectLabelsCodemod = Codemod {
  name = "effect-labels",
  descr = "strip and/or rename effect-row labels (e.g. <Rand>, <Net>, …)",
  argHelp = "--strip L1,L2   --rename Old=New   (repeatable)",
  mk = mkEffectLabels,
  warn = warnEffectLabels,
}

-- ── accessors (the CLI uses these; never the record fields) ──────────────────
export
codemodName : Codemod -> String
codemodName (Codemod { name, ... }) = name

export
codemodDescr : Codemod -> String
codemodDescr (Codemod { descr, ... }) = descr

export
codemodArgHelp : Codemod -> String
codemodArgHelp (Codemod { argHelp, ... }) = argHelp

export
codemodMk : Codemod -> List String -> Result String (Decl -> (Decl, Bool))
codemodMk (Codemod { mk, ... }) args = mk args

export
codemodWarnDecls : Codemod -> List String -> List Decl -> List String
codemodWarnDecls (Codemod { warn, ... }) args decls = warn args decls

export
findCodemod : String -> Option Codemod
findCodemod name = findCodemodGo name allCodemods

findCodemodGo : String -> List Codemod -> Option Codemod
findCodemodGo _ [] = None
findCodemodGo name (c :: rest) =
  if codemodName c == name then Some c else findCodemodGo name rest

-- Registry listing for the bare `medaka codemod` invocation.
export
codemodListing : String
codemodListing = joinNl (map codemodListingLine allCodemods)

codemodListingLine : Codemod -> String
codemodListingLine c =
  "  \{codemodName c} — \{codemodDescr c}\n    \{codemodArgHelp c}"

-- ── pure core ────────────────────────────────────────────────────────────────
-- Parse `src`, run the transform over every decl (OR-folding the change flags),
-- and — ONLY when something changed — re-render through the comment-preserving
-- formatter.  `None` = nothing changed (the caller MUST NOT write: this keeps a
-- codemod from doubling as `fmt` and keeps it off non-fmt-clean or #51 float
-- files that carry no target label).  Parse errors surface as `Err ParseError`
-- so the CLI reports them through the shared `ppParseError` path.
export
codemodSource : (Decl -> (Decl, Bool)) ->
  String ->
  Result ParseError (Option String)
codemodSource xf src = match parseResult src
  Err e => Err e
  Ok _ =>
    -- parseResult already proved the source parses, so parseWithPositions
    -- (which panics on failure) is safe here.
    let (decls, pos) = parseWithPositions src
    let (decls2, changed) = mapDeclsChanged xf decls
    if not changed then
      Ok None
    else
      let comments = collectComments src
      Ok
        (Some
          (formatProgram
            decls2
            (positionsDecls pos)
            (positionsVariantLines pos)
            (trailingCommaLocs ())
            (unitStarts ())
            comments
            src))

mapDeclsChanged : (Decl -> (Decl, Bool)) -> List Decl -> (List Decl, Bool)
mapDeclsChanged _ [] = ([], False)
mapDeclsChanged xf (d :: ds) =
  let (d2, c1) = xf d
  let (ds2, c2) = mapDeclsChanged xf ds
  (d2 :: ds2, c1 || c2)

-- ── the `effect-labels` transform ────────────────────────────────────────────
-- Per-label action, parsed from `--strip`/`--rename`.  Not an `Option String`
-- clone: the table is looked up with `lookupAssoc`, so `Option String` would make
-- `applyAtom` read `Option (Option String)`, where `Some None` (label present,
-- strip it) and `None` (label absent, leave it) are one typo apart.
-- lint-disable-next-line rule-clone-type
data EffAction = ADrop | ARename String

mkEffectLabels : List String -> Result String (Decl -> (Decl, Bool))
mkEffectLabels args = match parseEffectArgs args []
  Err msg => Err msg
  Ok [] => Err "need at least one --strip <labels> or --rename Old=New"
  Ok acts => Ok (mapTyInDecl (effTyNode acts))

-- Parse the codemod-specific args into a (label -> action) table.  `--strip`
-- and `--rename` each consume a following value (the CLI's generic flag/value
-- splitter has already paired them).
parseEffectArgs : List String ->
  List (String, EffAction) ->
  Result String (List (String, EffAction))
parseEffectArgs [] acc = Ok (reverseL acc)
parseEffectArgs ("--strip" :: v :: rest) acc =
  parseEffectArgs rest (prependDrops (splitOnChar ',' v) acc)
parseEffectArgs ("--rename" :: v :: rest) acc = match splitOnChar '=' v
  [old, nw] =>
    if old == "" || nw == "" then
      Err "--rename expects Old=New, got '\{v}'"
    else
      parseEffectArgs rest ((old, ARename nw) :: acc)
  _ => Err "--rename expects Old=New, got '\{v}'"
parseEffectArgs ["--strip"] _ =
  Err "--strip requires a value (e.g. --strip Rand,Net)"
parseEffectArgs ["--rename"] _ =
  Err "--rename requires a value (e.g. --rename Old=New)"
parseEffectArgs (x :: _) _ = Err "unknown argument '\{x}'"

prependDrops : List String ->
  List (String, EffAction) ->
  List (String, EffAction)
prependDrops [] acc = acc
prependDrops (n :: ns) acc =
  if n == "" then prependDrops ns acc else prependDrops ns ((n, ADrop) :: acc)

-- Apply the action table at one Ty node.  `TyEffect` and `TyRow` (#997, a
-- bare row atom) are affected; everything else passes through unchanged.
-- (The child type, if any, was already rewritten by mapTyFull's post-order
-- recursion.)
effTyNode : List (String, EffAction) -> Ty -> (Ty, Bool)
effTyNode acts (TyEffect es tail t) = rewriteRow acts es tail t
effTyNode acts (TyRow es tail l) = rewriteBareRow acts es tail l
effTyNode _ ty = (ty, False)

rewriteRow : List (String, EffAction) ->
  List (String, Option String) ->
  List String ->
  Ty ->
  (Ty, Bool)
rewriteRow acts es tail t =
  let (deduped, changed) = rewriteAtoms acts es
  match deduped
    [] => match tail
      -- fully-stripped, no tail → an unannotated (pure) arrow: drop the node.
      [] => if changed then (t, True) else (TyEffect [] [] t, False)
      -- an open row with no atoms still prints (`<v>`) and round-trips.
      _ => (TyEffect [] tail t, changed)
    _ => (TyEffect deduped tail t, changed)

-- Same action-table rewrite as `rewriteRow`, for a bare row atom (#997):
-- there is no wrapped type to fall back to when the row strips to empty, so
-- (unlike `rewriteRow`'s `None` case above) an empty closed bare row stays a
-- `TyRow [] []` rather than being dropped — there is no other Ty to become.
rewriteBareRow : List (String, EffAction) ->
  List (String, Option String) ->
  List String ->
  Option Loc ->
  (Ty, Bool)
rewriteBareRow acts es tail l =
  let (deduped, changed) = rewriteAtoms acts es
  (TyRow deduped tail l, changed)

rewriteAtoms : List (String, EffAction) ->
  List (String, Option String) ->
  (List (String, Option String), Bool)
rewriteAtoms acts es =
  let stepped = map (applyAtom acts) es
  let anyChanged = anyList sndB stepped
  let kept = collectKept stepped
  let deduped = dedupeAtoms kept
  let dedupChanged = listLen deduped /= listLen kept
  (deduped, anyChanged || dedupChanged)

applyAtom : List (String, EffAction) ->
  (String, Option String) ->
  (Option (String, Option String), Bool)
applyAtom acts (label, dom) = match lookupAssoc label acts
  None => (Some (label, dom), False)
  Some ADrop => (None, True)
  Some (ARename nw) => (Some (nw, dom), True)

sndB : (a, Bool) -> Bool
sndB (_, b) = b

collectKept : List (Option (String, Option String), Bool) ->
  List (String, Option String)
collectKept [] = []
collectKept ((None, _) :: rest) = collectKept rest
collectKept ((Some a, _) :: rest) = a :: collectKept rest

-- Order-preserving dedupe (keep first) — a rename can make two atoms identical.
-- #242: routed through the canonical O(n·log n) `support.util.dedupBy` (was a
-- private O(n²) `List`-as-a-set scan).  Both the label and the payload are
-- unconstrained Strings, so the label is length-prefixed and the `Option` is
-- tagged — the encoding is injective, matching the old `atomEq` exactly.
dedupeAtoms : List (String, Option String) -> List (String, Option String)
dedupeAtoms xs = dedupBy atomKey xs

atomKey : (String, Option String) -> String
atomKey (label, dom) = lenKey label ++ domKey dom

domKey : Option String -> String
domKey None = "N"
domKey (Some x) = "S\{x}"

-- Advisory warnings: a `DEffect` that DECLARES a targeted label is left
-- untouched (the codemod only rewrites row USES), so flag it for the operator.
warnEffectLabels : List String -> List Decl -> List String
warnEffectLabels args decls = match parseEffectArgs args []
  Err _ => []
  Ok acts => declEffectWarns acts decls

declEffectWarns : List (String, EffAction) -> List Decl -> List String
declEffectWarns _ [] = []
declEffectWarns acts (d :: ds) =
  declEffectWarn acts d ++ declEffectWarns acts ds

declEffectWarn : List (String, EffAction) -> Decl -> List String
declEffectWarn acts (DEffect _ name _) = match lookupAssoc name acts
  None => []
  Some _ => [
    "'effect \{name}' is declared here but effect-labels targets \{name}; the declaration is left untouched",
  ]
declEffectWarn acts (DAttrib _ d) = declEffectWarn acts d
declEffectWarn _ _ = []
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Ty" true) (mem "Loc" false) (mem "Decl" true) (mem "mapTyInDecl" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "parseResult" false) (mem "ParseError" false) (mem "parseWithPositions" false) (mem "positionsDecls" false) (mem "positionsVariantLines" false) (mem "trailingCommaLocs" false) (mem "unitStarts" false))))
(DUse false (UseGroup ("frontend" "lexer") ((mem "collectComments" false))))
(DUse false (UseGroup ("tools" "fmt") ((mem "formatProgram" false))))
(DUse false (UseGroup ("support" "util") ((mem "reverseL" false) (mem "listLen" false) (mem "lookupAssoc" false) (mem "splitOnChar" false) (mem "joinNl" false) (mem "anyList" false) (mem "dedupBy" false) (mem "lenKey" false))))
(DData Public "Codemod" () ((variant "Codemod" (ConNamed (field "name" (TyCon "String")) (field "descr" (TyCon "String")) (field "argHelp" (TyCon "String")) (field "mk" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyFun (TyCon "Decl") (TyTuple (TyCon "Decl") (TyCon "Bool")))))) (field "warn" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String")))))))) ())
(DTypeSig true "allCodemods" (TyApp (TyCon "List") (TyCon "Codemod")))
(DFunDef false "allCodemods" () (EListLit (EVar "effectLabelsCodemod")))
(DTypeSig false "effectLabelsCodemod" (TyCon "Codemod"))
(DFunDef false "effectLabelsCodemod" () (ERecordCreate "Codemod" ((fa "name" (ELit (LString "effect-labels"))) (fa "descr" (ELit (LString "strip and/or rename effect-row labels (e.g. <Rand>, <Net>, …)"))) (fa "argHelp" (ELit (LString "--strip L1,L2   --rename Old=New   (repeatable)"))) (fa "mk" (EVar "mkEffectLabels")) (fa "warn" (EVar "warnEffectLabels")))))
(DTypeSig true "codemodName" (TyFun (TyCon "Codemod") (TyCon "String")))
(DFunDef false "codemodName" ((PRec "Codemod" ((rf "name" None)) true)) (EVar "name"))
(DTypeSig true "codemodDescr" (TyFun (TyCon "Codemod") (TyCon "String")))
(DFunDef false "codemodDescr" ((PRec "Codemod" ((rf "descr" None)) true)) (EVar "descr"))
(DTypeSig true "codemodArgHelp" (TyFun (TyCon "Codemod") (TyCon "String")))
(DFunDef false "codemodArgHelp" ((PRec "Codemod" ((rf "argHelp" None)) true)) (EVar "argHelp"))
(DTypeSig true "codemodMk" (TyFun (TyCon "Codemod") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyFun (TyCon "Decl") (TyTuple (TyCon "Decl") (TyCon "Bool")))))))
(DFunDef false "codemodMk" ((PRec "Codemod" ((rf "mk" None)) true) (PVar "args")) (EApp (EVar "mk") (EVar "args")))
(DTypeSig true "codemodWarnDecls" (TyFun (TyCon "Codemod") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "codemodWarnDecls" ((PRec "Codemod" ((rf "warn" None)) true) (PVar "args") (PVar "decls")) (EApp (EApp (EVar "warn") (EVar "args")) (EVar "decls")))
(DTypeSig true "findCodemod" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Codemod"))))
(DFunDef false "findCodemod" ((PVar "name")) (EApp (EApp (EVar "findCodemodGo") (EVar "name")) (EVar "allCodemods")))
(DTypeSig false "findCodemodGo" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Codemod")) (TyApp (TyCon "Option") (TyCon "Codemod")))))
(DFunDef false "findCodemodGo" (PWild (PList)) (EVar "None"))
(DFunDef false "findCodemodGo" ((PVar "name") (PCons (PVar "c") (PVar "rest"))) (EIf (EBinOp "==" (EApp (EVar "codemodName") (EVar "c")) (EVar "name")) (EApp (EVar "Some") (EVar "c")) (EApp (EApp (EVar "findCodemodGo") (EVar "name")) (EVar "rest"))))
(DTypeSig true "codemodListing" (TyCon "String"))
(DFunDef false "codemodListing" () (EApp (EVar "joinNl") (EApp (EApp (EVar "map") (EVar "codemodListingLine")) (EVar "allCodemods"))))
(DTypeSig false "codemodListingLine" (TyFun (TyCon "Codemod") (TyCon "String")))
(DFunDef false "codemodListingLine" ((PVar "c")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  ")) (EApp (EVar "display") (EApp (EVar "codemodName") (EVar "c")))) (ELit (LString " — "))) (EApp (EVar "display") (EApp (EVar "codemodDescr") (EVar "c")))) (ELit (LString "\n    "))) (EApp (EVar "display") (EApp (EVar "codemodArgHelp") (EVar "c")))) (ELit (LString ""))))
(DTypeSig true "codemodSource" (TyFun (TyFun (TyCon "Decl") (TyTuple (TyCon "Decl") (TyCon "Bool"))) (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "ParseError")) (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "codemodSource" ((PVar "xf") (PVar "src")) (EMatch (EApp (EVar "parseResult") (EVar "src")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" PWild) () (EBlock (DoLet false false (PTuple (PVar "decls") (PVar "pos")) (EApp (EVar "parseWithPositions") (EVar "src"))) (DoLet false false (PTuple (PVar "decls2") (PVar "changed")) (EApp (EApp (EVar "mapDeclsChanged") (EVar "xf")) (EVar "decls"))) (DoExpr (EIf (EApp (EVar "not") (EVar "changed")) (EApp (EVar "Ok") (EVar "None")) (EBlock (DoLet false false (PVar "comments") (EApp (EVar "collectComments") (EVar "src"))) (DoExpr (EApp (EVar "Ok") (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "formatProgram") (EVar "decls2")) (EApp (EVar "positionsDecls") (EVar "pos"))) (EApp (EVar "positionsVariantLines") (EVar "pos"))) (EApp (EVar "trailingCommaLocs") (ELit LUnit))) (EApp (EVar "unitStarts") (ELit LUnit))) (EVar "comments")) (EVar "src"))))))))))))
(DTypeSig false "mapDeclsChanged" (TyFun (TyFun (TyCon "Decl") (TyTuple (TyCon "Decl") (TyCon "Bool"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool")))))
(DFunDef false "mapDeclsChanged" (PWild (PList)) (ETuple (EListLit) (EVar "False")))
(DFunDef false "mapDeclsChanged" ((PVar "xf") (PCons (PVar "d") (PVar "ds"))) (EBlock (DoLet false false (PTuple (PVar "d2") (PVar "c1")) (EApp (EVar "xf") (EVar "d"))) (DoLet false false (PTuple (PVar "ds2") (PVar "c2")) (EApp (EApp (EVar "mapDeclsChanged") (EVar "xf")) (EVar "ds"))) (DoExpr (ETuple (EBinOp "::" (EVar "d2") (EVar "ds2")) (EBinOp "||" (EVar "c1") (EVar "c2"))))))
(DData Private "EffAction" () ((variant "ADrop" (ConPos)) (variant "ARename" (ConPos (TyCon "String")))) ())
(DTypeSig false "mkEffectLabels" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyFun (TyCon "Decl") (TyTuple (TyCon "Decl") (TyCon "Bool"))))))
(DFunDef false "mkEffectLabels" ((PVar "args")) (EMatch (EApp (EApp (EVar "parseEffectArgs") (EVar "args")) (EListLit)) (arm (PCon "Err" (PVar "msg")) () (EApp (EVar "Err") (EVar "msg"))) (arm (PCon "Ok" (PList)) () (EApp (EVar "Err") (ELit (LString "need at least one --strip <labels> or --rename Old=New")))) (arm (PCon "Ok" (PVar "acts")) () (EApp (EVar "Ok") (EApp (EVar "mapTyInDecl") (EApp (EVar "effTyNode") (EVar "acts")))))))
(DTypeSig false "parseEffectArgs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffAction"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffAction")))))))
(DFunDef false "parseEffectArgs" ((PList) (PVar "acc")) (EApp (EVar "Ok") (EApp (EVar "reverseL") (EVar "acc"))))
(DFunDef false "parseEffectArgs" ((PCons (PLit (LString "--strip")) (PCons (PVar "v") (PVar "rest"))) (PVar "acc")) (EApp (EApp (EVar "parseEffectArgs") (EVar "rest")) (EApp (EApp (EVar "prependDrops") (EApp (EApp (EVar "splitOnChar") (ELit (LChar ","))) (EVar "v"))) (EVar "acc"))))
(DFunDef false "parseEffectArgs" ((PCons (PLit (LString "--rename")) (PCons (PVar "v") (PVar "rest"))) (PVar "acc")) (EMatch (EApp (EApp (EVar "splitOnChar") (ELit (LChar "="))) (EVar "v")) (arm (PList (PVar "old") (PVar "nw")) () (EIf (EBinOp "||" (EBinOp "==" (EVar "old") (ELit (LString ""))) (EBinOp "==" (EVar "nw") (ELit (LString "")))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "--rename expects Old=New, got '")) (EApp (EVar "display") (EVar "v"))) (ELit (LString "'")))) (EApp (EApp (EVar "parseEffectArgs") (EVar "rest")) (EBinOp "::" (ETuple (EVar "old") (EApp (EVar "ARename") (EVar "nw"))) (EVar "acc"))))) (arm PWild () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "--rename expects Old=New, got '")) (EApp (EVar "display") (EVar "v"))) (ELit (LString "'")))))))
(DFunDef false "parseEffectArgs" ((PList (PLit (LString "--strip"))) PWild) (EApp (EVar "Err") (ELit (LString "--strip requires a value (e.g. --strip Rand,Net)"))))
(DFunDef false "parseEffectArgs" ((PList (PLit (LString "--rename"))) PWild) (EApp (EVar "Err") (ELit (LString "--rename requires a value (e.g. --rename Old=New)"))))
(DFunDef false "parseEffectArgs" ((PCons (PVar "x") PWild) PWild) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "unknown argument '")) (EApp (EVar "display") (EVar "x"))) (ELit (LString "'")))))
(DTypeSig false "prependDrops" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffAction"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffAction"))))))
(DFunDef false "prependDrops" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "prependDrops" ((PCons (PVar "n") (PVar "ns")) (PVar "acc")) (EIf (EBinOp "==" (EVar "n") (ELit (LString ""))) (EApp (EApp (EVar "prependDrops") (EVar "ns")) (EVar "acc")) (EApp (EApp (EVar "prependDrops") (EVar "ns")) (EBinOp "::" (ETuple (EVar "n") (EVar "ADrop")) (EVar "acc")))))
(DTypeSig false "effTyNode" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffAction"))) (TyFun (TyCon "Ty") (TyTuple (TyCon "Ty") (TyCon "Bool")))))
(DFunDef false "effTyNode" ((PVar "acts") (PCon "TyEffect" (PVar "es") (PVar "tail") (PVar "t"))) (EApp (EApp (EApp (EApp (EVar "rewriteRow") (EVar "acts")) (EVar "es")) (EVar "tail")) (EVar "t")))
(DFunDef false "effTyNode" ((PVar "acts") (PCon "TyRow" (PVar "es") (PVar "tail") (PVar "l"))) (EApp (EApp (EApp (EApp (EVar "rewriteBareRow") (EVar "acts")) (EVar "es")) (EVar "tail")) (EVar "l")))
(DFunDef false "effTyNode" (PWild (PVar "ty")) (ETuple (EVar "ty") (EVar "False")))
(DTypeSig false "rewriteRow" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffAction"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Ty") (TyTuple (TyCon "Ty") (TyCon "Bool")))))))
(DFunDef false "rewriteRow" ((PVar "acts") (PVar "es") (PVar "tail") (PVar "t")) (EBlock (DoLet false false (PTuple (PVar "deduped") (PVar "changed")) (EApp (EApp (EVar "rewriteAtoms") (EVar "acts")) (EVar "es"))) (DoExpr (EMatch (EVar "deduped") (arm (PList) () (EMatch (EVar "tail") (arm (PList) () (EIf (EVar "changed") (ETuple (EVar "t") (EVar "True")) (ETuple (EApp (EApp (EApp (EVar "TyEffect") (EListLit)) (EListLit)) (EVar "t")) (EVar "False")))) (arm PWild () (ETuple (EApp (EApp (EApp (EVar "TyEffect") (EListLit)) (EVar "tail")) (EVar "t")) (EVar "changed"))))) (arm PWild () (ETuple (EApp (EApp (EApp (EVar "TyEffect") (EVar "deduped")) (EVar "tail")) (EVar "t")) (EVar "changed")))))))
(DTypeSig false "rewriteBareRow" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffAction"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyTuple (TyCon "Ty") (TyCon "Bool")))))))
(DFunDef false "rewriteBareRow" ((PVar "acts") (PVar "es") (PVar "tail") (PVar "l")) (EBlock (DoLet false false (PTuple (PVar "deduped") (PVar "changed")) (EApp (EApp (EVar "rewriteAtoms") (EVar "acts")) (EVar "es"))) (DoExpr (ETuple (EApp (EApp (EApp (EVar "TyRow") (EVar "deduped")) (EVar "tail")) (EVar "l")) (EVar "changed")))))
(DTypeSig false "rewriteAtoms" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffAction"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))) (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))) (TyCon "Bool")))))
(DFunDef false "rewriteAtoms" ((PVar "acts") (PVar "es")) (EBlock (DoLet false false (PVar "stepped") (EApp (EApp (EVar "map") (EApp (EVar "applyAtom") (EVar "acts"))) (EVar "es"))) (DoLet false false (PVar "anyChanged") (EApp (EApp (EVar "anyList") (EVar "sndB")) (EVar "stepped"))) (DoLet false false (PVar "kept") (EApp (EVar "collectKept") (EVar "stepped"))) (DoLet false false (PVar "deduped") (EApp (EVar "dedupeAtoms") (EVar "kept"))) (DoLet false false (PVar "dedupChanged") (EBinOp "/=" (EApp (EVar "listLen") (EVar "deduped")) (EApp (EVar "listLen") (EVar "kept")))) (DoExpr (ETuple (EVar "deduped") (EBinOp "||" (EVar "anyChanged") (EVar "dedupChanged"))))))
(DTypeSig false "applyAtom" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffAction"))) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyTuple (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))) (TyCon "Bool")))))
(DFunDef false "applyAtom" ((PVar "acts") (PTuple (PVar "label") (PVar "dom"))) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "label")) (EVar "acts")) (arm (PCon "None") () (ETuple (EApp (EVar "Some") (ETuple (EVar "label") (EVar "dom"))) (EVar "False"))) (arm (PCon "Some" (PCon "ADrop")) () (ETuple (EVar "None") (EVar "True"))) (arm (PCon "Some" (PCon "ARename" (PVar "nw"))) () (ETuple (EApp (EVar "Some") (ETuple (EVar "nw") (EVar "dom"))) (EVar "True")))))
(DTypeSig false "sndB" (TyFun (TyTuple (TyVar "a") (TyCon "Bool")) (TyCon "Bool")))
(DFunDef false "sndB" ((PTuple PWild (PVar "b"))) (EVar "b"))
(DTypeSig false "collectKept" (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))) (TyCon "Bool"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "collectKept" ((PList)) (EListLit))
(DFunDef false "collectKept" ((PCons (PTuple (PCon "None") PWild) (PVar "rest"))) (EApp (EVar "collectKept") (EVar "rest")))
(DFunDef false "collectKept" ((PCons (PTuple (PCon "Some" (PVar "a")) PWild) (PVar "rest"))) (EBinOp "::" (EVar "a") (EApp (EVar "collectKept") (EVar "rest"))))
(DTypeSig false "dedupeAtoms" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "dedupeAtoms" ((PVar "xs")) (EApp (EApp (EVar "dedupBy") (EVar "atomKey")) (EVar "xs")))
(DTypeSig false "atomKey" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyCon "String")))
(DFunDef false "atomKey" ((PTuple (PVar "label") (PVar "dom"))) (EBinOp "++" (EApp (EVar "lenKey") (EVar "label")) (EApp (EVar "domKey") (EVar "dom"))))
(DTypeSig false "domKey" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyCon "String")))
(DFunDef false "domKey" ((PCon "None")) (ELit (LString "N")))
(DFunDef false "domKey" ((PCon "Some" (PVar "x"))) (EBinOp "++" (EBinOp "++" (ELit (LString "S")) (EApp (EVar "display") (EVar "x"))) (ELit (LString ""))))
(DTypeSig false "warnEffectLabels" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "warnEffectLabels" ((PVar "args") (PVar "decls")) (EMatch (EApp (EApp (EVar "parseEffectArgs") (EVar "args")) (EListLit)) (arm (PCon "Err" PWild) () (EListLit)) (arm (PCon "Ok" (PVar "acts")) () (EApp (EApp (EVar "declEffectWarns") (EVar "acts")) (EVar "decls")))))
(DTypeSig false "declEffectWarns" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffAction"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "declEffectWarns" (PWild (PList)) (EListLit))
(DFunDef false "declEffectWarns" ((PVar "acts") (PCons (PVar "d") (PVar "ds"))) (EBinOp "++" (EApp (EApp (EVar "declEffectWarn") (EVar "acts")) (EVar "d")) (EApp (EApp (EVar "declEffectWarns") (EVar "acts")) (EVar "ds"))))
(DTypeSig false "declEffectWarn" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffAction"))) (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "declEffectWarn" ((PVar "acts") (PCon "DEffect" PWild (PVar "name") PWild)) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "name")) (EVar "acts")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" PWild) () (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "'effect ")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "' is declared here but effect-labels targets "))) (EApp (EVar "display") (EVar "name"))) (ELit (LString "; the declaration is left untouched")))))))
(DFunDef false "declEffectWarn" ((PVar "acts") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EVar "declEffectWarn") (EVar "acts")) (EVar "d")))
(DFunDef false "declEffectWarn" (PWild PWild) (EListLit))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Ty" true) (mem "Loc" false) (mem "Decl" true) (mem "mapTyInDecl" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "parseResult" false) (mem "ParseError" false) (mem "parseWithPositions" false) (mem "positionsDecls" false) (mem "positionsVariantLines" false) (mem "trailingCommaLocs" false) (mem "unitStarts" false))))
(DUse false (UseGroup ("frontend" "lexer") ((mem "collectComments" false))))
(DUse false (UseGroup ("tools" "fmt") ((mem "formatProgram" false))))
(DUse false (UseGroup ("support" "util") ((mem "reverseL" false) (mem "listLen" false) (mem "lookupAssoc" false) (mem "splitOnChar" false) (mem "joinNl" false) (mem "anyList" false) (mem "dedupBy" false) (mem "lenKey" false))))
(DData Public "Codemod" () ((variant "Codemod" (ConNamed (field "name" (TyCon "String")) (field "descr" (TyCon "String")) (field "argHelp" (TyCon "String")) (field "mk" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyFun (TyCon "Decl") (TyTuple (TyCon "Decl") (TyCon "Bool")))))) (field "warn" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String")))))))) ())
(DTypeSig true "allCodemods" (TyApp (TyCon "List") (TyCon "Codemod")))
(DFunDef false "allCodemods" () (EListLit (EVar "effectLabelsCodemod")))
(DTypeSig false "effectLabelsCodemod" (TyCon "Codemod"))
(DFunDef false "effectLabelsCodemod" () (ERecordCreate "Codemod" ((fa "name" (ELit (LString "effect-labels"))) (fa "descr" (ELit (LString "strip and/or rename effect-row labels (e.g. <Rand>, <Net>, …)"))) (fa "argHelp" (ELit (LString "--strip L1,L2   --rename Old=New   (repeatable)"))) (fa "mk" (EVar "mkEffectLabels")) (fa "warn" (EVar "warnEffectLabels")))))
(DTypeSig true "codemodName" (TyFun (TyCon "Codemod") (TyCon "String")))
(DFunDef false "codemodName" ((PRec "Codemod" ((rf "name" None)) true)) (EVar "name"))
(DTypeSig true "codemodDescr" (TyFun (TyCon "Codemod") (TyCon "String")))
(DFunDef false "codemodDescr" ((PRec "Codemod" ((rf "descr" None)) true)) (EVar "descr"))
(DTypeSig true "codemodArgHelp" (TyFun (TyCon "Codemod") (TyCon "String")))
(DFunDef false "codemodArgHelp" ((PRec "Codemod" ((rf "argHelp" None)) true)) (EVar "argHelp"))
(DTypeSig true "codemodMk" (TyFun (TyCon "Codemod") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyFun (TyCon "Decl") (TyTuple (TyCon "Decl") (TyCon "Bool")))))))
(DFunDef false "codemodMk" ((PRec "Codemod" ((rf "mk" None)) true) (PVar "args")) (EApp (EVar "mk") (EVar "args")))
(DTypeSig true "codemodWarnDecls" (TyFun (TyCon "Codemod") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "codemodWarnDecls" ((PRec "Codemod" ((rf "warn" None)) true) (PVar "args") (PVar "decls")) (EApp (EApp (EVar "warn") (EVar "args")) (EVar "decls")))
(DTypeSig true "findCodemod" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Codemod"))))
(DFunDef false "findCodemod" ((PVar "name")) (EApp (EApp (EVar "findCodemodGo") (EVar "name")) (EVar "allCodemods")))
(DTypeSig false "findCodemodGo" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Codemod")) (TyApp (TyCon "Option") (TyCon "Codemod")))))
(DFunDef false "findCodemodGo" (PWild (PList)) (EVar "None"))
(DFunDef false "findCodemodGo" ((PVar "name") (PCons (PVar "c") (PVar "rest"))) (EIf (EBinOp "==" (EApp (EVar "codemodName") (EVar "c")) (EVar "name")) (EApp (EVar "Some") (EVar "c")) (EApp (EApp (EVar "findCodemodGo") (EVar "name")) (EVar "rest"))))
(DTypeSig true "codemodListing" (TyCon "String"))
(DFunDef false "codemodListing" () (EApp (EVar "joinNl") (EApp (EApp (EMethodRef "map") (EVar "codemodListingLine")) (EVar "allCodemods"))))
(DTypeSig false "codemodListingLine" (TyFun (TyCon "Codemod") (TyCon "String")))
(DFunDef false "codemodListingLine" ((PVar "c")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  ")) (EApp (EMethodRef "display") (EApp (EVar "codemodName") (EVar "c")))) (ELit (LString " — "))) (EApp (EMethodRef "display") (EApp (EVar "codemodDescr") (EVar "c")))) (ELit (LString "\n    "))) (EApp (EMethodRef "display") (EApp (EVar "codemodArgHelp") (EVar "c")))) (ELit (LString ""))))
(DTypeSig true "codemodSource" (TyFun (TyFun (TyCon "Decl") (TyTuple (TyCon "Decl") (TyCon "Bool"))) (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "ParseError")) (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "codemodSource" ((PVar "xf") (PVar "src")) (EMatch (EApp (EVar "parseResult") (EVar "src")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" PWild) () (EBlock (DoLet false false (PTuple (PVar "decls") (PVar "pos")) (EApp (EVar "parseWithPositions") (EVar "src"))) (DoLet false false (PTuple (PVar "decls2") (PVar "changed")) (EApp (EApp (EVar "mapDeclsChanged") (EVar "xf")) (EVar "decls"))) (DoExpr (EIf (EApp (EVar "not") (EVar "changed")) (EApp (EVar "Ok") (EVar "None")) (EBlock (DoLet false false (PVar "comments") (EApp (EVar "collectComments") (EVar "src"))) (DoExpr (EApp (EVar "Ok") (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "formatProgram") (EVar "decls2")) (EApp (EVar "positionsDecls") (EVar "pos"))) (EApp (EVar "positionsVariantLines") (EVar "pos"))) (EApp (EVar "trailingCommaLocs") (ELit LUnit))) (EApp (EVar "unitStarts") (ELit LUnit))) (EVar "comments")) (EVar "src"))))))))))))
(DTypeSig false "mapDeclsChanged" (TyFun (TyFun (TyCon "Decl") (TyTuple (TyCon "Decl") (TyCon "Bool"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool")))))
(DFunDef false "mapDeclsChanged" (PWild (PList)) (ETuple (EListLit) (EVar "False")))
(DFunDef false "mapDeclsChanged" ((PVar "xf") (PCons (PVar "d") (PVar "ds"))) (EBlock (DoLet false false (PTuple (PVar "d2") (PVar "c1")) (EApp (EVar "xf") (EVar "d"))) (DoLet false false (PTuple (PVar "ds2") (PVar "c2")) (EApp (EApp (EVar "mapDeclsChanged") (EVar "xf")) (EVar "ds"))) (DoExpr (ETuple (EBinOp "::" (EVar "d2") (EVar "ds2")) (EBinOp "||" (EVar "c1") (EVar "c2"))))))
(DData Private "EffAction" () ((variant "ADrop" (ConPos)) (variant "ARename" (ConPos (TyCon "String")))) ())
(DTypeSig false "mkEffectLabels" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyFun (TyCon "Decl") (TyTuple (TyCon "Decl") (TyCon "Bool"))))))
(DFunDef false "mkEffectLabels" ((PVar "args")) (EMatch (EApp (EApp (EVar "parseEffectArgs") (EVar "args")) (EListLit)) (arm (PCon "Err" (PVar "msg")) () (EApp (EVar "Err") (EVar "msg"))) (arm (PCon "Ok" (PList)) () (EApp (EVar "Err") (ELit (LString "need at least one --strip <labels> or --rename Old=New")))) (arm (PCon "Ok" (PVar "acts")) () (EApp (EVar "Ok") (EApp (EVar "mapTyInDecl") (EApp (EVar "effTyNode") (EVar "acts")))))))
(DTypeSig false "parseEffectArgs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffAction"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffAction")))))))
(DFunDef false "parseEffectArgs" ((PList) (PVar "acc")) (EApp (EVar "Ok") (EApp (EVar "reverseL") (EVar "acc"))))
(DFunDef false "parseEffectArgs" ((PCons (PLit (LString "--strip")) (PCons (PVar "v") (PVar "rest"))) (PVar "acc")) (EApp (EApp (EVar "parseEffectArgs") (EVar "rest")) (EApp (EApp (EVar "prependDrops") (EApp (EApp (EVar "splitOnChar") (ELit (LChar ","))) (EVar "v"))) (EVar "acc"))))
(DFunDef false "parseEffectArgs" ((PCons (PLit (LString "--rename")) (PCons (PVar "v") (PVar "rest"))) (PVar "acc")) (EMatch (EApp (EApp (EVar "splitOnChar") (ELit (LChar "="))) (EVar "v")) (arm (PList (PVar "old") (PVar "nw")) () (EIf (EBinOp "||" (EBinOp "==" (EVar "old") (ELit (LString ""))) (EBinOp "==" (EVar "nw") (ELit (LString "")))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "--rename expects Old=New, got '")) (EApp (EMethodRef "display") (EVar "v"))) (ELit (LString "'")))) (EApp (EApp (EVar "parseEffectArgs") (EVar "rest")) (EBinOp "::" (ETuple (EVar "old") (EApp (EVar "ARename") (EVar "nw"))) (EVar "acc"))))) (arm PWild () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "--rename expects Old=New, got '")) (EApp (EMethodRef "display") (EVar "v"))) (ELit (LString "'")))))))
(DFunDef false "parseEffectArgs" ((PList (PLit (LString "--strip"))) PWild) (EApp (EVar "Err") (ELit (LString "--strip requires a value (e.g. --strip Rand,Net)"))))
(DFunDef false "parseEffectArgs" ((PList (PLit (LString "--rename"))) PWild) (EApp (EVar "Err") (ELit (LString "--rename requires a value (e.g. --rename Old=New)"))))
(DFunDef false "parseEffectArgs" ((PCons (PVar "x") PWild) PWild) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "unknown argument '")) (EApp (EMethodRef "display") (EVar "x"))) (ELit (LString "'")))))
(DTypeSig false "prependDrops" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffAction"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffAction"))))))
(DFunDef false "prependDrops" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "prependDrops" ((PCons (PVar "n") (PVar "ns")) (PVar "acc")) (EIf (EBinOp "==" (EVar "n") (ELit (LString ""))) (EApp (EApp (EVar "prependDrops") (EVar "ns")) (EVar "acc")) (EApp (EApp (EVar "prependDrops") (EVar "ns")) (EBinOp "::" (ETuple (EVar "n") (EVar "ADrop")) (EVar "acc")))))
(DTypeSig false "effTyNode" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffAction"))) (TyFun (TyCon "Ty") (TyTuple (TyCon "Ty") (TyCon "Bool")))))
(DFunDef false "effTyNode" ((PVar "acts") (PCon "TyEffect" (PVar "es") (PVar "tail") (PVar "t"))) (EApp (EApp (EApp (EApp (EVar "rewriteRow") (EVar "acts")) (EVar "es")) (EVar "tail")) (EVar "t")))
(DFunDef false "effTyNode" ((PVar "acts") (PCon "TyRow" (PVar "es") (PVar "tail") (PVar "l"))) (EApp (EApp (EApp (EApp (EVar "rewriteBareRow") (EVar "acts")) (EVar "es")) (EVar "tail")) (EVar "l")))
(DFunDef false "effTyNode" (PWild (PVar "ty")) (ETuple (EVar "ty") (EVar "False")))
(DTypeSig false "rewriteRow" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffAction"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Ty") (TyTuple (TyCon "Ty") (TyCon "Bool")))))))
(DFunDef false "rewriteRow" ((PVar "acts") (PVar "es") (PVar "tail") (PVar "t")) (EBlock (DoLet false false (PTuple (PVar "deduped") (PVar "changed")) (EApp (EApp (EVar "rewriteAtoms") (EVar "acts")) (EVar "es"))) (DoExpr (EMatch (EVar "deduped") (arm (PList) () (EMatch (EVar "tail") (arm (PList) () (EIf (EVar "changed") (ETuple (EVar "t") (EVar "True")) (ETuple (EApp (EApp (EApp (EVar "TyEffect") (EListLit)) (EListLit)) (EVar "t")) (EVar "False")))) (arm PWild () (ETuple (EApp (EApp (EApp (EVar "TyEffect") (EListLit)) (EVar "tail")) (EVar "t")) (EVar "changed"))))) (arm PWild () (ETuple (EApp (EApp (EApp (EVar "TyEffect") (EVar "deduped")) (EVar "tail")) (EVar "t")) (EVar "changed")))))))
(DTypeSig false "rewriteBareRow" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffAction"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyTuple (TyCon "Ty") (TyCon "Bool")))))))
(DFunDef false "rewriteBareRow" ((PVar "acts") (PVar "es") (PVar "tail") (PVar "l")) (EBlock (DoLet false false (PTuple (PVar "deduped") (PVar "changed")) (EApp (EApp (EVar "rewriteAtoms") (EVar "acts")) (EVar "es"))) (DoExpr (ETuple (EApp (EApp (EApp (EVar "TyRow") (EVar "deduped")) (EVar "tail")) (EVar "l")) (EVar "changed")))))
(DTypeSig false "rewriteAtoms" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffAction"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))) (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))) (TyCon "Bool")))))
(DFunDef false "rewriteAtoms" ((PVar "acts") (PVar "es")) (EBlock (DoLet false false (PVar "stepped") (EApp (EApp (EMethodRef "map") (EApp (EVar "applyAtom") (EVar "acts"))) (EVar "es"))) (DoLet false false (PVar "anyChanged") (EApp (EApp (EVar "anyList") (EVar "sndB")) (EVar "stepped"))) (DoLet false false (PVar "kept") (EApp (EVar "collectKept") (EVar "stepped"))) (DoLet false false (PVar "deduped") (EApp (EVar "dedupeAtoms") (EVar "kept"))) (DoLet false false (PVar "dedupChanged") (EBinOp "/=" (EApp (EVar "listLen") (EVar "deduped")) (EApp (EVar "listLen") (EVar "kept")))) (DoExpr (ETuple (EVar "deduped") (EBinOp "||" (EVar "anyChanged") (EVar "dedupChanged"))))))
(DTypeSig false "applyAtom" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffAction"))) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyTuple (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))) (TyCon "Bool")))))
(DFunDef false "applyAtom" ((PVar "acts") (PTuple (PVar "label") (PVar "dom"))) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "label")) (EVar "acts")) (arm (PCon "None") () (ETuple (EApp (EVar "Some") (ETuple (EVar "label") (EVar "dom"))) (EVar "False"))) (arm (PCon "Some" (PCon "ADrop")) () (ETuple (EVar "None") (EVar "True"))) (arm (PCon "Some" (PCon "ARename" (PVar "nw"))) () (ETuple (EApp (EVar "Some") (ETuple (EVar "nw") (EVar "dom"))) (EVar "True")))))
(DTypeSig false "sndB" (TyFun (TyTuple (TyVar "a") (TyCon "Bool")) (TyCon "Bool")))
(DFunDef false "sndB" ((PTuple PWild (PVar "b"))) (EVar "b"))
(DTypeSig false "collectKept" (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))) (TyCon "Bool"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "collectKept" ((PList)) (EListLit))
(DFunDef false "collectKept" ((PCons (PTuple (PCon "None") PWild) (PVar "rest"))) (EApp (EVar "collectKept") (EVar "rest")))
(DFunDef false "collectKept" ((PCons (PTuple (PCon "Some" (PVar "a")) PWild) (PVar "rest"))) (EBinOp "::" (EVar "a") (EApp (EVar "collectKept") (EVar "rest"))))
(DTypeSig false "dedupeAtoms" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "dedupeAtoms" ((PVar "xs")) (EApp (EApp (EVar "dedupBy") (EVar "atomKey")) (EVar "xs")))
(DTypeSig false "atomKey" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyCon "String")))
(DFunDef false "atomKey" ((PTuple (PVar "label") (PVar "dom"))) (EBinOp "++" (EApp (EVar "lenKey") (EVar "label")) (EApp (EVar "domKey") (EVar "dom"))))
(DTypeSig false "domKey" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyCon "String")))
(DFunDef false "domKey" ((PCon "None")) (ELit (LString "N")))
(DFunDef false "domKey" ((PCon "Some" (PVar "x"))) (EBinOp "++" (EBinOp "++" (ELit (LString "S")) (EApp (EMethodRef "display") (EVar "x"))) (ELit (LString ""))))
(DTypeSig false "warnEffectLabels" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "warnEffectLabels" ((PVar "args") (PVar "decls")) (EMatch (EApp (EApp (EVar "parseEffectArgs") (EVar "args")) (EListLit)) (arm (PCon "Err" PWild) () (EListLit)) (arm (PCon "Ok" (PVar "acts")) () (EApp (EApp (EVar "declEffectWarns") (EVar "acts")) (EVar "decls")))))
(DTypeSig false "declEffectWarns" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffAction"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "declEffectWarns" (PWild (PList)) (EListLit))
(DFunDef false "declEffectWarns" ((PVar "acts") (PCons (PVar "d") (PVar "ds"))) (EBinOp "++" (EApp (EApp (EVar "declEffectWarn") (EVar "acts")) (EVar "d")) (EApp (EApp (EVar "declEffectWarns") (EVar "acts")) (EVar "ds"))))
(DTypeSig false "declEffectWarn" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffAction"))) (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "declEffectWarn" ((PVar "acts") (PCon "DEffect" PWild (PVar "name") PWild)) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "name")) (EVar "acts")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" PWild) () (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "'effect ")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "' is declared here but effect-labels targets "))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "; the declaration is left untouched")))))))
(DFunDef false "declEffectWarn" ((PVar "acts") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EVar "declEffectWarn") (EVar "acts")) (EVar "d")))
(DFunDef false "declEffectWarn" (PWild PWild) (EListLit))
