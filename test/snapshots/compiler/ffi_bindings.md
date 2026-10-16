# META
source_lines=341
stages=DESUGAR,MARK
# SOURCE
-- The declaration rules for a user `extern`'s host bindings and declared row,
-- and the messages of every `T-FFI-*` declaration rule.  Pure over the
-- declaration record and the atoms of its terminal result row, which the
-- typechecker reads with aliases expanded (`ffiDeclaredRow`) and passes in;
-- the rules return their diagnostics as data and the typechecker reports
-- them.  Ownership gating (`ffiStampMode`) and the catalog-name test stay with
-- the typechecker, which holds that state.
--
-- An `FFI` parameter in a declaration row is `HOST` or `HOST/LIBRARY`, HOST
-- being `c` or `js`.  The rule is about declaration rows only: a bound (a row
-- on any other signature, or a policy) compares parameters as text
-- (`types/effect_domain.mdk`), so `"c*"` admits both `"c"` and `"c/m"`, while
-- `"c"` does not admit `"c/m"` and `"c/*"` does not admit `"c"`.

import frontend.ast.{
  EffAtomTy(..),
  EffParamTy(..),
  ExternBind(..),
  ExternDecl(..),
  Loc,
  Ty,
  TyConOrigin(..),
  externBindings,
  firstTyLoc,
}
import types.repr.{ppTy}
import types.effect_domain.{Param(..), canonParam, isSubTop}
import types.effect_rows.{Atom, atomConst, atomLabel, atomsNorm, renderAtoms}
import support.util.{anyList, contains, filterList, joinWith, startsWith}
import support.char.{isAlnum, isApos, isDigit}
import string.{stripSuffix, toLower}

-- One declaration diagnostic: its code, where it is reported, its message.
public export data FfiDiag = FfiDiag String (Option Loc) String

-- The hosts a binding may name.
ffiHosts : List String
ffiHosts = ["c", "js"]

-- Every rule over one user extern.  `catalog` says the name is a
-- `stdlib/runtime.mdk` catalog name, which always runs the built-in: its
-- signature is held to the catalog's by the shadow and catalog-row rules
-- instead, so of these rules it meets only the one refusing a `bind` clause.
-- `row` is `None` when the signature has no arrow.
export
ffiDeclarationDiags : Bool ->
  ExternDecl ->
  Option (List EffAtomTy) ->
  List FfiDiag
ffiDeclarationDiags True d _ = match d.edBinds
  b :: _ =>
    [FfiDiag "T-FFI-BUILTIN-BIND" (Some b.ebLoc) (ffiBuiltinBindMsg d.edName)]
  [] => []
ffiDeclarationDiags False d row =
  let clauseDiags = ffiClauseDiags d.edName [] d.edBinds
  -- A malformed clause list already explains why a host looks unbound.
  let hostDiags = match clauseDiags
    [] => ffiRowHostDiags d row
    _ => filterList isNotUnbound (ffiRowHostDiags d row)
  ffiLabelDiags d row ++ hostDiags ++ ffiBindDiags d

isNotUnbound : FfiDiag -> Bool
isNotUnbound (FfiDiag code _ _) = code /= "T-FFI-UNBOUND-HOST"

-- The row must name the foreign-call `FFI`, and the signature must have an
-- arrow to carry a row at all.  A nullary extern is refused, not passed: the
-- emitter lowers every user extern as a foreign call, so its name would
-- evaluate to an eta closure where a value is expected (#2106).
ffiLabelDiags : ExternDecl -> Option (List EffAtomTy) -> List FfiDiag
ffiLabelDiags d row =
  let fb = firstTyLoc d.edTy
  match row
    None => [FfiDiag "T-FFI-NULLARY" fb (ffiNullaryMsg d.edName)]
    Some atoms =>
      if anyList isForeignCallAtom atoms then
        []
      else if anyList (a => a.eatLabel == "FFI") atoms then
        [FfiDiag "T-FFI-UNLABELLED" fb (ffiDeclaredLabelMsg d.edName)]
      else
        [FfiDiag "T-FFI-UNLABELLED" fb (ffiUnlabelledMsg d.edName)]

-- The foreign-call effect itself.  A label a module declares with `effect FFI`
-- is spelled the same but is a user label, which the target check never gates,
-- so it cannot be what makes a declaration honest about calling foreign code.
isForeignCallAtom : EffAtomTy -> Bool
isForeignCallAtom a = match a.eatOrigin
  OriginModule _ => False
  _ => a.eatLabel == "FFI"

-- Each foreign-call atom names a host, and the declaration binds it.
ffiRowHostDiags : ExternDecl -> Option (List EffAtomTy) -> List FfiDiag
ffiRowHostDiags _ None = []
ffiRowHostDiags d (Some atoms) =
  flatMap (ffiAtomHostDiags d) (filterList isForeignCallAtom atoms)

ffiAtomHostDiags : ExternDecl -> EffAtomTy -> List FfiDiag
ffiAtomHostDiags d a = match a.eatParam
  -- the empty literal is refused by the parameter check already
  EPLit "" => []
  EPLit p => match ffiParamHost p ffiHosts
    Some h =>
      if anyList (b => b.ebHost == h) (externBindings d) then
        []
      else
        [
          FfiDiag
            "T-FFI-UNBOUND-HOST"
            (Some d.edLoc)
            (ffiUnboundHostMsg d.edName h),
        ]
    None =>
      [FfiDiag "T-FFI-NO-HOST" (Some d.edLoc) (ffiNoHostMsg d.edName (Some p))]
  _ => [FfiDiag "T-FFI-NO-HOST" (Some d.edLoc) (ffiNoHostMsg d.edName None)]

-- The host an `FFI` parameter names: a host alone, or a host, `/` and a
-- non-empty library.
ffiParamHost : String -> List String -> Option String
ffiParamHost _ [] = None
ffiParamHost p (h :: hs)
  | p == h = Some h
  | startsWith "\{h}/" p && stringLength p > stringLength h + 1 = Some h
  | otherwise = ffiParamHost p hs

-- The written clauses name known hosts, each once; every binding, written or
-- implied, names a symbol its host can call.
ffiBindDiags : ExternDecl -> List FfiDiag
ffiBindDiags d =
  ffiClauseDiags d.edName [] d.edBinds
    ++ flatMap (ffiSymbolDiags d) (externBindings d)

ffiClauseDiags : String -> List String -> List ExternBind -> List FfiDiag
ffiClauseDiags _ _ [] = []
ffiClauseDiags n seen (b :: rest)
  | not (contains b.ebHost ffiHosts) =
    FfiDiag "T-FFI-UNKNOWN-HOST" (Some b.ebLoc) (ffiUnknownHostMsg n b.ebHost)
      :: ffiClauseDiags n seen rest
  | contains b.ebHost seen =
    FfiDiag
        "T-FFI-DUPLICATE-HOST"
        (Some b.ebLoc)
        (ffiDuplicateHostMsg n b.ebHost)
      :: ffiClauseDiags n seen rest
  | otherwise = ffiClauseDiags n (b.ebHost :: seen) rest

ffiSymbolDiags : ExternDecl -> ExternBind -> List FfiDiag
ffiSymbolDiags d b = match b.ebHost
  "c" =>
    if not (isIdentWith isCIdentStart isCIdentChar b.ebSymbol) then
      [
        FfiDiag
          "T-FFI-C-SYMBOL"
          (Some b.ebLoc)
          (ffiCSymbolMsg d.edName b.ebSymbol (isEmptyBinds d)),
      ]
    else if startsWith "mdk_" b.ebSymbol then
      [
        FfiDiag
          "T-FFI-RESERVED-NAME"
          (Some b.ebLoc)
          (ffiReservedMsg d.edName b.ebSymbol (isEmptyBinds d)),
      ]
    else
      []
  "js" =>
    if isIdentWith isJsIdentStart isJsIdentChar b.ebSymbol then
      []
    else
      [
        FfiDiag
          "T-FFI-JS-NAME"
          (Some b.ebLoc)
          (ffiJsNameMsg d.edName b.ebSymbol),
      ]
  _ => []

isEmptyBinds : ExternDecl -> Bool
isEmptyBinds d = match d.edBinds
  [] => True
  _ => False

-- A non-empty string whose first character satisfies `start` and whose rest
-- satisfy `rest`.
isIdentWith : (Char -> Bool) -> (Char -> Bool) -> String -> Bool
isIdentWith start rest s =
  let cs = stringToChars s
  arrayLength cs > 0 && start (arrayGetUnsafe 0 cs) && identCharsFrom rest cs 1

identCharsFrom : (Char -> Bool) -> Array Char -> Int -> Bool
identCharsFrom p cs i =
  i >= arrayLength cs || p (arrayGetUnsafe i cs) && identCharsFrom p cs (i + 1)

-- A Medaka identifier character less the apostrophe.
isCIdentChar : Char -> Bool
isCIdentChar c = isAlnum c && not (isApos c)

isCIdentStart : Char -> Bool
isCIdentStart c = isCIdentChar c && not (isDigit c)

isJsIdentStart : Char -> Bool
isJsIdentStart c = isCIdentStart c || c == '$'

isJsIdentChar : Char -> Bool
isJsIdentChar c = isJsIdentStart c || isDigit c

-- ── messages ─────────────────────────────────────────────────────────────

ffiNullaryMsg : String -> String
ffiNullaryMsg n =
  "foreign declaration `\{n}` has no arrow in its signature, so it declares a foreign value rather than a foreign call; declare a call instead, `extern \{n} : Unit -> <FFI \"c\"> T`, invoked as `\{n} ()`"

ffiDeclaredLabelMsg : String -> String
ffiDeclaredLabelMsg n =
  "foreign declaration `\{n}` names `FFI` in its result row, but that `FFI` is a label declared with `effect FFI`, not the foreign-call effect; rename the declared label so `FFI` here means the foreign call"

ffiUnlabelledMsg : String -> String
ffiUnlabelledMsg n =
  "foreign declaration `\{n}` does not name the `FFI` effect in its result row; write `<FFI \"c\">` joined with whatever else the row names, such as `<FFI \"c\", Net \"a.com/*\">`"

ffiNoHostMsg : String -> Option String -> String
ffiNoHostMsg n written =
  let fix = match written
    Some p => ffiNoHostFix p
    None => "write `<FFI \"c\">` for a C function"
  let shown = match written
    Some lib => "`FFI \"\{lib}\"`"
    None => "`FFI`"
  "foreign declaration `\{n}` names \{shown} with no host in its result row; the parameter is a host, `c` or `js`, optionally followed by `/` and a library: \{fix}"

-- The repair for a written parameter that names no host.  A bound's spelling
-- (`"js*"`) or a dangling slash (`"c/"`) is a host written wrongly, and a host
-- in capitals is a case mistake; only a name that is no host reads as a C
-- library.
ffiNoHostFix : String -> String
ffiNoHostFix p =
  let base = dropTrailingSlash (dropTrailingStar p)
  if contains base ffiHosts then
    "write `<FFI \"\{base}\">` for the `\{base}` host"
  else if contains (toLower base) ffiHosts then
    "host names are lower-case: write `<FFI \"\{toLower base}\">`"
  else
    "write `<FFI \"c/\{p}\">` for a C library"

-- A bound's spelling of a whole host, `"c*"`, written in a declaration row.
dropTrailingStar : String -> String
dropTrailingStar s = match stripSuffix "*" s
  Some rest => rest
  None => s

dropTrailingSlash : String -> String
dropTrailingSlash s = match stripSuffix "/" s
  Some rest => rest
  None => s

ffiUnboundHostMsg : String -> String -> String
ffiUnboundHostMsg n h =
  "foreign declaration `\{n}` names the `\{h}` host in its result row but has no `\{h}` binding; add an indented `bind \{h} \"<name>\"` line under its signature"

ffiUnknownHostMsg : String -> String -> String
ffiUnknownHostMsg n h =
  "foreign declaration `\{n}` binds the unknown host `\{h}`; a binding names `c` or `js`"

ffiDuplicateHostMsg : String -> String -> String
ffiDuplicateHostMsg n h =
  "foreign declaration `\{n}` binds the `\{h}` host more than once; keep one `bind \{h}` line"

ffiCSymbolMsg : String -> String -> Bool -> String
ffiCSymbolMsg n sym implied =
  let what =
    if implied then
      "is bound to C under its own name, and `\{sym}`"
    else
      "binds the C symbol `\{sym}`, which"
  "foreign declaration `\{n}` \{what} is not a C identifier (a letter or `_`, then letters, digits and `_`); bind a C symbol with `bind c \"<symbol>\"`"

ffiJsNameMsg : String -> String -> String
ffiJsNameMsg n name =
  "foreign declaration `\{n}` binds the JavaScript name `\{name}`, which is not a JavaScript identifier (a letter, `_` or `$`, then letters, digits, `_` and `$`)"

ffiReservedMsg : String -> String -> Bool -> String
ffiReservedMsg n sym implied =
  let fix =
    if implied then
      "rename the extern, or bind another symbol with `bind c \"<symbol>\"`"
    else
      "bind another symbol"
  "foreign declaration `\{n}` claims a reserved name: its C symbol `\{sym}` is in the `mdk_` prefix, the runtime's own C symbol namespace; \{fix}"

ffiBuiltinBindMsg : String -> String
ffiBuiltinBindMsg n =
  "foreign declaration `\{n}` redeclares a built-in, which always runs the built-in's own implementation, so it takes no `bind` clause; drop the clause, or rename the extern"

export
ffiNonCrossableMsg : String -> Ty -> String
ffiNonCrossableMsg n t =
  "type `\{ppTy t}` cannot cross the foreign-function boundary in extern `\{n}`; marshal it into one of Int, Float, Bool, Char, String, Unit, U8, U16, U32, U64, I32, I64 or Array Int"

export
ffiShadowMsg : String -> String -> String -> String
ffiShadowMsg n want got =
  "foreign declaration `\{n}` redeclares a built-in at a type it does not have: the built-in is `\{want}`, this declaration claims `\{got}`; rename the extern, or declare it at the built-in's signature"

export
ffiCatalogTailMsg : String -> String -> List String -> String
ffiCatalogTailMsg n arrow missing =
  "foreign declaration `\{n}` redeclares a built-in with a narrower effect row\{arrow}: the built-in also performs the row variable \{joinWith ", " missing}; write that variable in the row, or rename the extern"

export
ffiCatalogNarrowMsg : String ->
  String ->
  List Atom ->
  List Atom ->
  List Atom ->
  String
ffiCatalogNarrowMsg n arrow cat decl missing =
  "foreign declaration `\{n}` redeclares a built-in with a narrower effect row\{arrow}: the built-in performs <\{renderAtoms cat}>, which this row does not cover at <\{renderAtoms missing}>\{ffiCatalogTopNote missing}; declare `<\{renderAtoms cat}>` or wider, or rename the extern"

-- A parameterised label whose parameter is the top renders as the bare label,
-- which against a declaration narrowing by a concrete parameter reads as "the
-- built-in touches nothing" rather than "the built-in may touch anything".  The
-- note is added here, in this one message: the shared renderers' top-renders-
-- empty is the intended surface elsewhere.  A domainless label has no
-- parameter that could be unconstrained, so it gets no note.
ffiCatalogTopNote : List Atom -> String
ffiCatalogTopNote missing =
  match map atomLabel (filterList atomParamIsTop (atomsNorm missing))
    [] => ""
    ls => " (\{joinWith "/" ls} there admits any value, not none)"

-- The top of a parameterised domain; `PUnit` is "no parameter", not "any
-- value".
atomParamIsTop : Atom -> Bool
atomParamIsTop a = match atomConst a
  Some p => paramIsTopDomain (canonParam p)
  None => False

paramIsTopDomain : Param -> Bool
paramIsTopDomain (PPrefix None) = True
paramIsTopDomain (PPath None) = True
paramIsTopDomain (PSet None) = True
paramIsTopDomain (p@(PProduct _)) = isSubTop p
paramIsTopDomain _ = False
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "EffAtomTy" true) (mem "EffParamTy" true) (mem "ExternBind" true) (mem "ExternDecl" true) (mem "Loc" false) (mem "Ty" false) (mem "TyConOrigin" true) (mem "externBindings" false) (mem "firstTyLoc" false))))
(DUse false (UseGroup ("types" "repr") ((mem "ppTy" false))))
(DUse false (UseGroup ("types" "effect_domain") ((mem "Param" true) (mem "canonParam" false) (mem "isSubTop" false))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "Atom" false) (mem "atomConst" false) (mem "atomLabel" false) (mem "atomsNorm" false) (mem "renderAtoms" false))))
(DUse false (UseGroup ("support" "util") ((mem "anyList" false) (mem "contains" false) (mem "filterList" false) (mem "joinWith" false) (mem "startsWith" false))))
(DUse false (UseGroup ("support" "char") ((mem "isAlnum" false) (mem "isApos" false) (mem "isDigit" false))))
(DUse false (UseGroup ("string") ((mem "stripSuffix" false) (mem "toLower" false))))
(DData Public "FfiDiag" () ((variant "FfiDiag" (ConPos (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "String")))) ())
(DTypeSig false "ffiHosts" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "ffiHosts" () (EListLit (ELit (LString "c")) (ELit (LString "js"))))
(DTypeSig true "ffiDeclarationDiags" (TyFun (TyCon "Bool") (TyFun (TyCon "ExternDecl") (TyFun (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "EffAtomTy"))) (TyApp (TyCon "List") (TyCon "FfiDiag"))))))
(DFunDef false "ffiDeclarationDiags" ((PCon "True") (PVar "d") PWild) (EMatch (EFieldAccess (EVar "d") "edBinds") (arm (PCons (PVar "b") PWild) () (EListLit (EApp (EApp (EApp (EVar "FfiDiag") (ELit (LString "T-FFI-BUILTIN-BIND"))) (EApp (EVar "Some") (EFieldAccess (EVar "b") "ebLoc"))) (EApp (EVar "ffiBuiltinBindMsg") (EFieldAccess (EVar "d") "edName"))))) (arm (PList) () (EListLit))))
(DFunDef false "ffiDeclarationDiags" ((PCon "False") (PVar "d") (PVar "row")) (EBlock (DoLet false false (PVar "clauseDiags") (EApp (EApp (EApp (EVar "ffiClauseDiags") (EFieldAccess (EVar "d") "edName")) (EListLit)) (EFieldAccess (EVar "d") "edBinds"))) (DoLet false false (PVar "hostDiags") (EMatch (EVar "clauseDiags") (arm (PList) () (EApp (EApp (EVar "ffiRowHostDiags") (EVar "d")) (EVar "row"))) (arm PWild () (EApp (EApp (EVar "filterList") (EVar "isNotUnbound")) (EApp (EApp (EVar "ffiRowHostDiags") (EVar "d")) (EVar "row")))))) (DoExpr (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "ffiLabelDiags") (EVar "d")) (EVar "row")) (EVar "hostDiags")) (EApp (EVar "ffiBindDiags") (EVar "d"))))))
(DTypeSig false "isNotUnbound" (TyFun (TyCon "FfiDiag") (TyCon "Bool")))
(DFunDef false "isNotUnbound" ((PCon "FfiDiag" (PVar "code") PWild PWild)) (EBinOp "/=" (EVar "code") (ELit (LString "T-FFI-UNBOUND-HOST"))))
(DTypeSig false "ffiLabelDiags" (TyFun (TyCon "ExternDecl") (TyFun (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "EffAtomTy"))) (TyApp (TyCon "List") (TyCon "FfiDiag")))))
(DFunDef false "ffiLabelDiags" ((PVar "d") (PVar "row")) (EBlock (DoLet false false (PVar "fb") (EApp (EVar "firstTyLoc") (EFieldAccess (EVar "d") "edTy"))) (DoExpr (EMatch (EVar "row") (arm (PCon "None") () (EListLit (EApp (EApp (EApp (EVar "FfiDiag") (ELit (LString "T-FFI-NULLARY"))) (EVar "fb")) (EApp (EVar "ffiNullaryMsg") (EFieldAccess (EVar "d") "edName"))))) (arm (PCon "Some" (PVar "atoms")) () (EIf (EApp (EApp (EVar "anyList") (EVar "isForeignCallAtom")) (EVar "atoms")) (EListLit) (EIf (EApp (EApp (EVar "anyList") (ELam ((PVar "a")) (EBinOp "==" (EFieldAccess (EVar "a") "eatLabel") (ELit (LString "FFI"))))) (EVar "atoms")) (EListLit (EApp (EApp (EApp (EVar "FfiDiag") (ELit (LString "T-FFI-UNLABELLED"))) (EVar "fb")) (EApp (EVar "ffiDeclaredLabelMsg") (EFieldAccess (EVar "d") "edName")))) (EListLit (EApp (EApp (EApp (EVar "FfiDiag") (ELit (LString "T-FFI-UNLABELLED"))) (EVar "fb")) (EApp (EVar "ffiUnlabelledMsg") (EFieldAccess (EVar "d") "edName")))))))))))
(DTypeSig false "isForeignCallAtom" (TyFun (TyCon "EffAtomTy") (TyCon "Bool")))
(DFunDef false "isForeignCallAtom" ((PVar "a")) (EMatch (EFieldAccess (EVar "a") "eatOrigin") (arm (PCon "OriginModule" PWild) () (EVar "False")) (arm PWild () (EBinOp "==" (EFieldAccess (EVar "a") "eatLabel") (ELit (LString "FFI"))))))
(DTypeSig false "ffiRowHostDiags" (TyFun (TyCon "ExternDecl") (TyFun (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "EffAtomTy"))) (TyApp (TyCon "List") (TyCon "FfiDiag")))))
(DFunDef false "ffiRowHostDiags" (PWild (PCon "None")) (EListLit))
(DFunDef false "ffiRowHostDiags" ((PVar "d") (PCon "Some" (PVar "atoms"))) (EApp (EApp (EVar "flatMap") (EApp (EVar "ffiAtomHostDiags") (EVar "d"))) (EApp (EApp (EVar "filterList") (EVar "isForeignCallAtom")) (EVar "atoms"))))
(DTypeSig false "ffiAtomHostDiags" (TyFun (TyCon "ExternDecl") (TyFun (TyCon "EffAtomTy") (TyApp (TyCon "List") (TyCon "FfiDiag")))))
(DFunDef false "ffiAtomHostDiags" ((PVar "d") (PVar "a")) (EMatch (EFieldAccess (EVar "a") "eatParam") (arm (PCon "EPLit" (PLit (LString ""))) () (EListLit)) (arm (PCon "EPLit" (PVar "p")) () (EMatch (EApp (EApp (EVar "ffiParamHost") (EVar "p")) (EVar "ffiHosts")) (arm (PCon "Some" (PVar "h")) () (EIf (EApp (EApp (EVar "anyList") (ELam ((PVar "b")) (EBinOp "==" (EFieldAccess (EVar "b") "ebHost") (EVar "h")))) (EApp (EVar "externBindings") (EVar "d"))) (EListLit) (EListLit (EApp (EApp (EApp (EVar "FfiDiag") (ELit (LString "T-FFI-UNBOUND-HOST"))) (EApp (EVar "Some") (EFieldAccess (EVar "d") "edLoc"))) (EApp (EApp (EVar "ffiUnboundHostMsg") (EFieldAccess (EVar "d") "edName")) (EVar "h")))))) (arm (PCon "None") () (EListLit (EApp (EApp (EApp (EVar "FfiDiag") (ELit (LString "T-FFI-NO-HOST"))) (EApp (EVar "Some") (EFieldAccess (EVar "d") "edLoc"))) (EApp (EApp (EVar "ffiNoHostMsg") (EFieldAccess (EVar "d") "edName")) (EApp (EVar "Some") (EVar "p")))))))) (arm PWild () (EListLit (EApp (EApp (EApp (EVar "FfiDiag") (ELit (LString "T-FFI-NO-HOST"))) (EApp (EVar "Some") (EFieldAccess (EVar "d") "edLoc"))) (EApp (EApp (EVar "ffiNoHostMsg") (EFieldAccess (EVar "d") "edName")) (EVar "None")))))))
(DTypeSig false "ffiParamHost" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "ffiParamHost" (PWild (PList)) (EVar "None"))
(DFunDef false "ffiParamHost" ((PVar "p") (PCons (PVar "h") (PVar "hs"))) (EIf (EBinOp "==" (EVar "p") (EVar "h")) (EApp (EVar "Some") (EVar "h")) (EIf (EBinOp "&&" (EApp (EApp (EVar "startsWith") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "h"))) (ELit (LString "/")))) (EVar "p")) (EBinOp ">" (EApp (EVar "stringLength") (EVar "p")) (EBinOp "+" (EApp (EVar "stringLength") (EVar "h")) (ELit (LInt 1))))) (EApp (EVar "Some") (EVar "h")) (EIf (EVar "otherwise") (EApp (EApp (EVar "ffiParamHost") (EVar "p")) (EVar "hs")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "ffiBindDiags" (TyFun (TyCon "ExternDecl") (TyApp (TyCon "List") (TyCon "FfiDiag"))))
(DFunDef false "ffiBindDiags" ((PVar "d")) (EBinOp "++" (EApp (EApp (EApp (EVar "ffiClauseDiags") (EFieldAccess (EVar "d") "edName")) (EListLit)) (EFieldAccess (EVar "d") "edBinds")) (EApp (EApp (EVar "flatMap") (EApp (EVar "ffiSymbolDiags") (EVar "d"))) (EApp (EVar "externBindings") (EVar "d")))))
(DTypeSig false "ffiClauseDiags" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "ExternBind")) (TyApp (TyCon "List") (TyCon "FfiDiag"))))))
(DFunDef false "ffiClauseDiags" (PWild PWild (PList)) (EListLit))
(DFunDef false "ffiClauseDiags" ((PVar "n") (PVar "seen") (PCons (PVar "b") (PVar "rest"))) (EIf (EApp (EVar "not") (EApp (EApp (EVar "contains") (EFieldAccess (EVar "b") "ebHost")) (EVar "ffiHosts"))) (EBinOp "::" (EApp (EApp (EApp (EVar "FfiDiag") (ELit (LString "T-FFI-UNKNOWN-HOST"))) (EApp (EVar "Some") (EFieldAccess (EVar "b") "ebLoc"))) (EApp (EApp (EVar "ffiUnknownHostMsg") (EVar "n")) (EFieldAccess (EVar "b") "ebHost"))) (EApp (EApp (EApp (EVar "ffiClauseDiags") (EVar "n")) (EVar "seen")) (EVar "rest"))) (EIf (EApp (EApp (EVar "contains") (EFieldAccess (EVar "b") "ebHost")) (EVar "seen")) (EBinOp "::" (EApp (EApp (EApp (EVar "FfiDiag") (ELit (LString "T-FFI-DUPLICATE-HOST"))) (EApp (EVar "Some") (EFieldAccess (EVar "b") "ebLoc"))) (EApp (EApp (EVar "ffiDuplicateHostMsg") (EVar "n")) (EFieldAccess (EVar "b") "ebHost"))) (EApp (EApp (EApp (EVar "ffiClauseDiags") (EVar "n")) (EVar "seen")) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "ffiClauseDiags") (EVar "n")) (EBinOp "::" (EFieldAccess (EVar "b") "ebHost") (EVar "seen"))) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "ffiSymbolDiags" (TyFun (TyCon "ExternDecl") (TyFun (TyCon "ExternBind") (TyApp (TyCon "List") (TyCon "FfiDiag")))))
(DFunDef false "ffiSymbolDiags" ((PVar "d") (PVar "b")) (EMatch (EFieldAccess (EVar "b") "ebHost") (arm (PLit (LString "c")) () (EIf (EApp (EVar "not") (EApp (EApp (EApp (EVar "isIdentWith") (EVar "isCIdentStart")) (EVar "isCIdentChar")) (EFieldAccess (EVar "b") "ebSymbol"))) (EListLit (EApp (EApp (EApp (EVar "FfiDiag") (ELit (LString "T-FFI-C-SYMBOL"))) (EApp (EVar "Some") (EFieldAccess (EVar "b") "ebLoc"))) (EApp (EApp (EApp (EVar "ffiCSymbolMsg") (EFieldAccess (EVar "d") "edName")) (EFieldAccess (EVar "b") "ebSymbol")) (EApp (EVar "isEmptyBinds") (EVar "d"))))) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "mdk_"))) (EFieldAccess (EVar "b") "ebSymbol")) (EListLit (EApp (EApp (EApp (EVar "FfiDiag") (ELit (LString "T-FFI-RESERVED-NAME"))) (EApp (EVar "Some") (EFieldAccess (EVar "b") "ebLoc"))) (EApp (EApp (EApp (EVar "ffiReservedMsg") (EFieldAccess (EVar "d") "edName")) (EFieldAccess (EVar "b") "ebSymbol")) (EApp (EVar "isEmptyBinds") (EVar "d"))))) (EListLit)))) (arm (PLit (LString "js")) () (EIf (EApp (EApp (EApp (EVar "isIdentWith") (EVar "isJsIdentStart")) (EVar "isJsIdentChar")) (EFieldAccess (EVar "b") "ebSymbol")) (EListLit) (EListLit (EApp (EApp (EApp (EVar "FfiDiag") (ELit (LString "T-FFI-JS-NAME"))) (EApp (EVar "Some") (EFieldAccess (EVar "b") "ebLoc"))) (EApp (EApp (EVar "ffiJsNameMsg") (EFieldAccess (EVar "d") "edName")) (EFieldAccess (EVar "b") "ebSymbol")))))) (arm PWild () (EListLit))))
(DTypeSig false "isEmptyBinds" (TyFun (TyCon "ExternDecl") (TyCon "Bool")))
(DFunDef false "isEmptyBinds" ((PVar "d")) (EMatch (EFieldAccess (EVar "d") "edBinds") (arm (PList) () (EVar "True")) (arm PWild () (EVar "False"))))
(DTypeSig false "isIdentWith" (TyFun (TyFun (TyCon "Char") (TyCon "Bool")) (TyFun (TyFun (TyCon "Char") (TyCon "Bool")) (TyFun (TyCon "String") (TyCon "Bool")))))
(DFunDef false "isIdentWith" ((PVar "start") (PVar "rest") (PVar "s")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "s"))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EBinOp ">" (EApp (EVar "arrayLength") (EVar "cs")) (ELit (LInt 0))) (EApp (EVar "start") (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 0))) (EVar "cs")))) (EApp (EApp (EApp (EVar "identCharsFrom") (EVar "rest")) (EVar "cs")) (ELit (LInt 1)))))))
(DTypeSig false "identCharsFrom" (TyFun (TyFun (TyCon "Char") (TyCon "Bool")) (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "identCharsFrom" ((PVar "p") (PVar "cs") (PVar "i")) (EBinOp "||" (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "cs"))) (EBinOp "&&" (EApp (EVar "p") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs"))) (EApp (EApp (EApp (EVar "identCharsFrom") (EVar "p")) (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))))))
(DTypeSig false "isCIdentChar" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isCIdentChar" ((PVar "c")) (EBinOp "&&" (EApp (EVar "isAlnum") (EVar "c")) (EApp (EVar "not") (EApp (EVar "isApos") (EVar "c")))))
(DTypeSig false "isCIdentStart" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isCIdentStart" ((PVar "c")) (EBinOp "&&" (EApp (EVar "isCIdentChar") (EVar "c")) (EApp (EVar "not") (EApp (EVar "isDigit") (EVar "c")))))
(DTypeSig false "isJsIdentStart" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isJsIdentStart" ((PVar "c")) (EBinOp "||" (EApp (EVar "isCIdentStart") (EVar "c")) (EBinOp "==" (EVar "c") (ELit (LChar "$")))))
(DTypeSig false "isJsIdentChar" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isJsIdentChar" ((PVar "c")) (EBinOp "||" (EApp (EVar "isJsIdentStart") (EVar "c")) (EApp (EVar "isDigit") (EVar "c"))))
(DTypeSig false "ffiNullaryMsg" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "ffiNullaryMsg" ((PVar "n")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "foreign declaration `")) (EApp (EVar "display") (EVar "n"))) (ELit (LString "` has no arrow in its signature, so it declares a foreign value rather than a foreign call; declare a call instead, `extern "))) (EApp (EVar "display") (EVar "n"))) (ELit (LString " : Unit -> <FFI \"c\"> T`, invoked as `"))) (EApp (EVar "display") (EVar "n"))) (ELit (LString " ()`"))))
(DTypeSig false "ffiDeclaredLabelMsg" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "ffiDeclaredLabelMsg" ((PVar "n")) (EBinOp "++" (EBinOp "++" (ELit (LString "foreign declaration `")) (EApp (EVar "display") (EVar "n"))) (ELit (LString "` names `FFI` in its result row, but that `FFI` is a label declared with `effect FFI`, not the foreign-call effect; rename the declared label so `FFI` here means the foreign call"))))
(DTypeSig false "ffiUnlabelledMsg" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "ffiUnlabelledMsg" ((PVar "n")) (EBinOp "++" (EBinOp "++" (ELit (LString "foreign declaration `")) (EApp (EVar "display") (EVar "n"))) (ELit (LString "` does not name the `FFI` effect in its result row; write `<FFI \"c\">` joined with whatever else the row names, such as `<FFI \"c\", Net \"a.com/*\">`"))))
(DTypeSig false "ffiNoHostMsg" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyCon "String"))))
(DFunDef false "ffiNoHostMsg" ((PVar "n") (PVar "written")) (EBlock (DoLet false false (PVar "fix") (EMatch (EVar "written") (arm (PCon "Some" (PVar "p")) () (EApp (EVar "ffiNoHostFix") (EVar "p"))) (arm (PCon "None") () (ELit (LString "write `<FFI \"c\">` for a C function"))))) (DoLet false false (PVar "shown") (EMatch (EVar "written") (arm (PCon "Some" (PVar "lib")) () (EBinOp "++" (EBinOp "++" (ELit (LString "`FFI \"")) (EApp (EVar "display") (EVar "lib"))) (ELit (LString "\"`")))) (arm (PCon "None") () (ELit (LString "`FFI`"))))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "foreign declaration `")) (EApp (EVar "display") (EVar "n"))) (ELit (LString "` names "))) (EApp (EVar "display") (EVar "shown"))) (ELit (LString " with no host in its result row; the parameter is a host, `c` or `js`, optionally followed by `/` and a library: "))) (EApp (EVar "display") (EVar "fix"))) (ELit (LString ""))))))
(DTypeSig false "ffiNoHostFix" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "ffiNoHostFix" ((PVar "p")) (EBlock (DoLet false false (PVar "base") (EApp (EVar "dropTrailingSlash") (EApp (EVar "dropTrailingStar") (EVar "p")))) (DoExpr (EIf (EApp (EApp (EVar "contains") (EVar "base")) (EVar "ffiHosts")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "write `<FFI \"")) (EApp (EVar "display") (EVar "base"))) (ELit (LString "\">` for the `"))) (EApp (EVar "display") (EVar "base"))) (ELit (LString "` host"))) (EIf (EApp (EApp (EVar "contains") (EApp (EVar "toLower") (EVar "base"))) (EVar "ffiHosts")) (EBinOp "++" (EBinOp "++" (ELit (LString "host names are lower-case: write `<FFI \"")) (EApp (EVar "display") (EApp (EVar "toLower") (EVar "base")))) (ELit (LString "\">`"))) (EBinOp "++" (EBinOp "++" (ELit (LString "write `<FFI \"c/")) (EApp (EVar "display") (EVar "p"))) (ELit (LString "\">` for a C library"))))))))
(DTypeSig false "dropTrailingStar" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "dropTrailingStar" ((PVar "s")) (EMatch (EApp (EApp (EVar "stripSuffix") (ELit (LString "*"))) (EVar "s")) (arm (PCon "Some" (PVar "rest")) () (EVar "rest")) (arm (PCon "None") () (EVar "s"))))
(DTypeSig false "dropTrailingSlash" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "dropTrailingSlash" ((PVar "s")) (EMatch (EApp (EApp (EVar "stripSuffix") (ELit (LString "/"))) (EVar "s")) (arm (PCon "Some" (PVar "rest")) () (EVar "rest")) (arm (PCon "None") () (EVar "s"))))
(DTypeSig false "ffiUnboundHostMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "ffiUnboundHostMsg" ((PVar "n") (PVar "h")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "foreign declaration `")) (EApp (EVar "display") (EVar "n"))) (ELit (LString "` names the `"))) (EApp (EVar "display") (EVar "h"))) (ELit (LString "` host in its result row but has no `"))) (EApp (EVar "display") (EVar "h"))) (ELit (LString "` binding; add an indented `bind "))) (EApp (EVar "display") (EVar "h"))) (ELit (LString " \"<name>\"` line under its signature"))))
(DTypeSig false "ffiUnknownHostMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "ffiUnknownHostMsg" ((PVar "n") (PVar "h")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "foreign declaration `")) (EApp (EVar "display") (EVar "n"))) (ELit (LString "` binds the unknown host `"))) (EApp (EVar "display") (EVar "h"))) (ELit (LString "`; a binding names `c` or `js`"))))
(DTypeSig false "ffiDuplicateHostMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "ffiDuplicateHostMsg" ((PVar "n") (PVar "h")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "foreign declaration `")) (EApp (EVar "display") (EVar "n"))) (ELit (LString "` binds the `"))) (EApp (EVar "display") (EVar "h"))) (ELit (LString "` host more than once; keep one `bind "))) (EApp (EVar "display") (EVar "h"))) (ELit (LString "` line"))))
(DTypeSig false "ffiCSymbolMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyCon "String")))))
(DFunDef false "ffiCSymbolMsg" ((PVar "n") (PVar "sym") (PVar "implied")) (EBlock (DoLet false false (PVar "what") (EIf (EVar "implied") (EBinOp "++" (EBinOp "++" (ELit (LString "is bound to C under its own name, and `")) (EApp (EVar "display") (EVar "sym"))) (ELit (LString "`"))) (EBinOp "++" (EBinOp "++" (ELit (LString "binds the C symbol `")) (EApp (EVar "display") (EVar "sym"))) (ELit (LString "`, which"))))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "foreign declaration `")) (EApp (EVar "display") (EVar "n"))) (ELit (LString "` "))) (EApp (EVar "display") (EVar "what"))) (ELit (LString " is not a C identifier (a letter or `_`, then letters, digits and `_`); bind a C symbol with `bind c \"<symbol>\"`"))))))
(DTypeSig false "ffiJsNameMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "ffiJsNameMsg" ((PVar "n") (PVar "name")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "foreign declaration `")) (EApp (EVar "display") (EVar "n"))) (ELit (LString "` binds the JavaScript name `"))) (EApp (EVar "display") (EVar "name"))) (ELit (LString "`, which is not a JavaScript identifier (a letter, `_` or `$`, then letters, digits, `_` and `$`)"))))
(DTypeSig false "ffiReservedMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyCon "String")))))
(DFunDef false "ffiReservedMsg" ((PVar "n") (PVar "sym") (PVar "implied")) (EBlock (DoLet false false (PVar "fix") (EIf (EVar "implied") (ELit (LString "rename the extern, or bind another symbol with `bind c \"<symbol>\"`")) (ELit (LString "bind another symbol")))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "foreign declaration `")) (EApp (EVar "display") (EVar "n"))) (ELit (LString "` claims a reserved name: its C symbol `"))) (EApp (EVar "display") (EVar "sym"))) (ELit (LString "` is in the `mdk_` prefix, the runtime's own C symbol namespace; "))) (EApp (EVar "display") (EVar "fix"))) (ELit (LString ""))))))
(DTypeSig false "ffiBuiltinBindMsg" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "ffiBuiltinBindMsg" ((PVar "n")) (EBinOp "++" (EBinOp "++" (ELit (LString "foreign declaration `")) (EApp (EVar "display") (EVar "n"))) (ELit (LString "` redeclares a built-in, which always runs the built-in's own implementation, so it takes no `bind` clause; drop the clause, or rename the extern"))))
(DTypeSig true "ffiNonCrossableMsg" (TyFun (TyCon "String") (TyFun (TyCon "Ty") (TyCon "String"))))
(DFunDef false "ffiNonCrossableMsg" ((PVar "n") (PVar "t")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "type `")) (EApp (EVar "display") (EApp (EVar "ppTy") (EVar "t")))) (ELit (LString "` cannot cross the foreign-function boundary in extern `"))) (EApp (EVar "display") (EVar "n"))) (ELit (LString "`; marshal it into one of Int, Float, Bool, Char, String, Unit, U8, U16, U32, U64, I32, I64 or Array Int"))))
(DTypeSig true "ffiShadowMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "ffiShadowMsg" ((PVar "n") (PVar "want") (PVar "got")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "foreign declaration `")) (EApp (EVar "display") (EVar "n"))) (ELit (LString "` redeclares a built-in at a type it does not have: the built-in is `"))) (EApp (EVar "display") (EVar "want"))) (ELit (LString "`, this declaration claims `"))) (EApp (EVar "display") (EVar "got"))) (ELit (LString "`; rename the extern, or declare it at the built-in's signature"))))
(DTypeSig true "ffiCatalogTailMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))))
(DFunDef false "ffiCatalogTailMsg" ((PVar "n") (PVar "arrow") (PVar "missing")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "foreign declaration `")) (EApp (EVar "display") (EVar "n"))) (ELit (LString "` redeclares a built-in with a narrower effect row"))) (EApp (EVar "display") (EVar "arrow"))) (ELit (LString ": the built-in also performs the row variable "))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EVar "missing")))) (ELit (LString "; write that variable in the row, or rename the extern"))))
(DTypeSig true "ffiCatalogNarrowMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "String")))))))
(DFunDef false "ffiCatalogNarrowMsg" ((PVar "n") (PVar "arrow") (PVar "cat") (PVar "decl") (PVar "missing")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "foreign declaration `")) (EApp (EVar "display") (EVar "n"))) (ELit (LString "` redeclares a built-in with a narrower effect row"))) (EApp (EVar "display") (EVar "arrow"))) (ELit (LString ": the built-in performs <"))) (EApp (EVar "display") (EApp (EVar "renderAtoms") (EVar "cat")))) (ELit (LString ">, which this row does not cover at <"))) (EApp (EVar "display") (EApp (EVar "renderAtoms") (EVar "missing")))) (ELit (LString ">"))) (EApp (EVar "display") (EApp (EVar "ffiCatalogTopNote") (EVar "missing")))) (ELit (LString "; declare `<"))) (EApp (EVar "display") (EApp (EVar "renderAtoms") (EVar "cat")))) (ELit (LString ">` or wider, or rename the extern"))))
(DTypeSig false "ffiCatalogTopNote" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "String")))
(DFunDef false "ffiCatalogTopNote" ((PVar "missing")) (EMatch (EApp (EApp (EVar "map") (EVar "atomLabel")) (EApp (EApp (EVar "filterList") (EVar "atomParamIsTop")) (EApp (EVar "atomsNorm") (EVar "missing")))) (arm (PList) () (ELit (LString ""))) (arm (PVar "ls") () (EBinOp "++" (EBinOp "++" (ELit (LString " (")) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString "/"))) (EVar "ls")))) (ELit (LString " there admits any value, not none)"))))))
(DTypeSig false "atomParamIsTop" (TyFun (TyCon "Atom") (TyCon "Bool")))
(DFunDef false "atomParamIsTop" ((PVar "a")) (EMatch (EApp (EVar "atomConst") (EVar "a")) (arm (PCon "Some" (PVar "p")) () (EApp (EVar "paramIsTopDomain") (EApp (EVar "canonParam") (EVar "p")))) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "paramIsTopDomain" (TyFun (TyCon "Param") (TyCon "Bool")))
(DFunDef false "paramIsTopDomain" ((PCon "PPrefix" (PCon "None"))) (EVar "True"))
(DFunDef false "paramIsTopDomain" ((PCon "PPath" (PCon "None"))) (EVar "True"))
(DFunDef false "paramIsTopDomain" ((PCon "PSet" (PCon "None"))) (EVar "True"))
(DFunDef false "paramIsTopDomain" ((PAs "p" (PCon "PProduct" PWild))) (EApp (EVar "isSubTop") (EVar "p")))
(DFunDef false "paramIsTopDomain" (PWild) (EVar "False"))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "EffAtomTy" true) (mem "EffParamTy" true) (mem "ExternBind" true) (mem "ExternDecl" true) (mem "Loc" false) (mem "Ty" false) (mem "TyConOrigin" true) (mem "externBindings" false) (mem "firstTyLoc" false))))
(DUse false (UseGroup ("types" "repr") ((mem "ppTy" false))))
(DUse false (UseGroup ("types" "effect_domain") ((mem "Param" true) (mem "canonParam" false) (mem "isSubTop" false))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "Atom" false) (mem "atomConst" false) (mem "atomLabel" false) (mem "atomsNorm" false) (mem "renderAtoms" false))))
(DUse false (UseGroup ("support" "util") ((mem "anyList" false) (mem "contains" false) (mem "filterList" false) (mem "joinWith" false) (mem "startsWith" false))))
(DUse false (UseGroup ("support" "char") ((mem "isAlnum" false) (mem "isApos" false) (mem "isDigit" false))))
(DUse false (UseGroup ("string") ((mem "stripSuffix" false) (mem "toLower" false))))
(DData Public "FfiDiag" () ((variant "FfiDiag" (ConPos (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "String")))) ())
(DTypeSig false "ffiHosts" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "ffiHosts" () (EListLit (ELit (LString "c")) (ELit (LString "js"))))
(DTypeSig true "ffiDeclarationDiags" (TyFun (TyCon "Bool") (TyFun (TyCon "ExternDecl") (TyFun (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "EffAtomTy"))) (TyApp (TyCon "List") (TyCon "FfiDiag"))))))
(DFunDef false "ffiDeclarationDiags" ((PCon "True") (PVar "d") PWild) (EMatch (EFieldAccess (EVar "d") "edBinds") (arm (PCons (PVar "b") PWild) () (EListLit (EApp (EApp (EApp (EVar "FfiDiag") (ELit (LString "T-FFI-BUILTIN-BIND"))) (EApp (EVar "Some") (EFieldAccess (EVar "b") "ebLoc"))) (EApp (EVar "ffiBuiltinBindMsg") (EFieldAccess (EVar "d") "edName"))))) (arm (PList) () (EListLit))))
(DFunDef false "ffiDeclarationDiags" ((PCon "False") (PVar "d") (PVar "row")) (EBlock (DoLet false false (PVar "clauseDiags") (EApp (EApp (EApp (EVar "ffiClauseDiags") (EFieldAccess (EVar "d") "edName")) (EListLit)) (EFieldAccess (EVar "d") "edBinds"))) (DoLet false false (PVar "hostDiags") (EMatch (EVar "clauseDiags") (arm (PList) () (EApp (EApp (EVar "ffiRowHostDiags") (EVar "d")) (EVar "row"))) (arm PWild () (EApp (EApp (EVar "filterList") (EVar "isNotUnbound")) (EApp (EApp (EVar "ffiRowHostDiags") (EVar "d")) (EVar "row")))))) (DoExpr (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "ffiLabelDiags") (EVar "d")) (EVar "row")) (EVar "hostDiags")) (EApp (EVar "ffiBindDiags") (EVar "d"))))))
(DTypeSig false "isNotUnbound" (TyFun (TyCon "FfiDiag") (TyCon "Bool")))
(DFunDef false "isNotUnbound" ((PCon "FfiDiag" (PVar "code") PWild PWild)) (EBinOp "/=" (EVar "code") (ELit (LString "T-FFI-UNBOUND-HOST"))))
(DTypeSig false "ffiLabelDiags" (TyFun (TyCon "ExternDecl") (TyFun (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "EffAtomTy"))) (TyApp (TyCon "List") (TyCon "FfiDiag")))))
(DFunDef false "ffiLabelDiags" ((PVar "d") (PVar "row")) (EBlock (DoLet false false (PVar "fb") (EApp (EVar "firstTyLoc") (EFieldAccess (EVar "d") "edTy"))) (DoExpr (EMatch (EVar "row") (arm (PCon "None") () (EListLit (EApp (EApp (EApp (EVar "FfiDiag") (ELit (LString "T-FFI-NULLARY"))) (EVar "fb")) (EApp (EVar "ffiNullaryMsg") (EFieldAccess (EVar "d") "edName"))))) (arm (PCon "Some" (PVar "atoms")) () (EIf (EApp (EApp (EVar "anyList") (EVar "isForeignCallAtom")) (EVar "atoms")) (EListLit) (EIf (EApp (EApp (EVar "anyList") (ELam ((PVar "a")) (EBinOp "==" (EFieldAccess (EVar "a") "eatLabel") (ELit (LString "FFI"))))) (EVar "atoms")) (EListLit (EApp (EApp (EApp (EVar "FfiDiag") (ELit (LString "T-FFI-UNLABELLED"))) (EVar "fb")) (EApp (EVar "ffiDeclaredLabelMsg") (EFieldAccess (EVar "d") "edName")))) (EListLit (EApp (EApp (EApp (EVar "FfiDiag") (ELit (LString "T-FFI-UNLABELLED"))) (EVar "fb")) (EApp (EVar "ffiUnlabelledMsg") (EFieldAccess (EVar "d") "edName")))))))))))
(DTypeSig false "isForeignCallAtom" (TyFun (TyCon "EffAtomTy") (TyCon "Bool")))
(DFunDef false "isForeignCallAtom" ((PVar "a")) (EMatch (EFieldAccess (EVar "a") "eatOrigin") (arm (PCon "OriginModule" PWild) () (EVar "False")) (arm PWild () (EBinOp "==" (EFieldAccess (EVar "a") "eatLabel") (ELit (LString "FFI"))))))
(DTypeSig false "ffiRowHostDiags" (TyFun (TyCon "ExternDecl") (TyFun (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "EffAtomTy"))) (TyApp (TyCon "List") (TyCon "FfiDiag")))))
(DFunDef false "ffiRowHostDiags" (PWild (PCon "None")) (EListLit))
(DFunDef false "ffiRowHostDiags" ((PVar "d") (PCon "Some" (PVar "atoms"))) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "ffiAtomHostDiags") (EVar "d"))) (EApp (EApp (EVar "filterList") (EVar "isForeignCallAtom")) (EVar "atoms"))))
(DTypeSig false "ffiAtomHostDiags" (TyFun (TyCon "ExternDecl") (TyFun (TyCon "EffAtomTy") (TyApp (TyCon "List") (TyCon "FfiDiag")))))
(DFunDef false "ffiAtomHostDiags" ((PVar "d") (PVar "a")) (EMatch (EFieldAccess (EVar "a") "eatParam") (arm (PCon "EPLit" (PLit (LString ""))) () (EListLit)) (arm (PCon "EPLit" (PVar "p")) () (EMatch (EApp (EApp (EVar "ffiParamHost") (EVar "p")) (EVar "ffiHosts")) (arm (PCon "Some" (PVar "h")) () (EIf (EApp (EApp (EVar "anyList") (ELam ((PVar "b")) (EBinOp "==" (EFieldAccess (EVar "b") "ebHost") (EVar "h")))) (EApp (EVar "externBindings") (EVar "d"))) (EListLit) (EListLit (EApp (EApp (EApp (EVar "FfiDiag") (ELit (LString "T-FFI-UNBOUND-HOST"))) (EApp (EVar "Some") (EFieldAccess (EVar "d") "edLoc"))) (EApp (EApp (EVar "ffiUnboundHostMsg") (EFieldAccess (EVar "d") "edName")) (EVar "h")))))) (arm (PCon "None") () (EListLit (EApp (EApp (EApp (EVar "FfiDiag") (ELit (LString "T-FFI-NO-HOST"))) (EApp (EVar "Some") (EFieldAccess (EVar "d") "edLoc"))) (EApp (EApp (EVar "ffiNoHostMsg") (EFieldAccess (EVar "d") "edName")) (EApp (EVar "Some") (EVar "p")))))))) (arm PWild () (EListLit (EApp (EApp (EApp (EVar "FfiDiag") (ELit (LString "T-FFI-NO-HOST"))) (EApp (EVar "Some") (EFieldAccess (EVar "d") "edLoc"))) (EApp (EApp (EVar "ffiNoHostMsg") (EFieldAccess (EVar "d") "edName")) (EVar "None")))))))
(DTypeSig false "ffiParamHost" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "ffiParamHost" (PWild (PList)) (EVar "None"))
(DFunDef false "ffiParamHost" ((PVar "p") (PCons (PVar "h") (PVar "hs"))) (EIf (EBinOp "==" (EVar "p") (EVar "h")) (EApp (EVar "Some") (EVar "h")) (EIf (EBinOp "&&" (EApp (EApp (EVar "startsWith") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "h"))) (ELit (LString "/")))) (EVar "p")) (EBinOp ">" (EApp (EVar "stringLength") (EVar "p")) (EBinOp "+" (EApp (EVar "stringLength") (EVar "h")) (ELit (LInt 1))))) (EApp (EVar "Some") (EVar "h")) (EIf (EVar "otherwise") (EApp (EApp (EVar "ffiParamHost") (EVar "p")) (EVar "hs")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "ffiBindDiags" (TyFun (TyCon "ExternDecl") (TyApp (TyCon "List") (TyCon "FfiDiag"))))
(DFunDef false "ffiBindDiags" ((PVar "d")) (EBinOp "++" (EApp (EApp (EApp (EVar "ffiClauseDiags") (EFieldAccess (EVar "d") "edName")) (EListLit)) (EFieldAccess (EVar "d") "edBinds")) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "ffiSymbolDiags") (EVar "d"))) (EApp (EVar "externBindings") (EVar "d")))))
(DTypeSig false "ffiClauseDiags" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "ExternBind")) (TyApp (TyCon "List") (TyCon "FfiDiag"))))))
(DFunDef false "ffiClauseDiags" (PWild PWild (PList)) (EListLit))
(DFunDef false "ffiClauseDiags" ((PVar "n") (PVar "seen") (PCons (PVar "b") (PVar "rest"))) (EIf (EApp (EVar "not") (EApp (EApp (EVar "contains") (EFieldAccess (EVar "b") "ebHost")) (EVar "ffiHosts"))) (EBinOp "::" (EApp (EApp (EApp (EVar "FfiDiag") (ELit (LString "T-FFI-UNKNOWN-HOST"))) (EApp (EVar "Some") (EFieldAccess (EVar "b") "ebLoc"))) (EApp (EApp (EVar "ffiUnknownHostMsg") (EVar "n")) (EFieldAccess (EVar "b") "ebHost"))) (EApp (EApp (EApp (EVar "ffiClauseDiags") (EVar "n")) (EVar "seen")) (EVar "rest"))) (EIf (EApp (EApp (EVar "contains") (EFieldAccess (EVar "b") "ebHost")) (EVar "seen")) (EBinOp "::" (EApp (EApp (EApp (EVar "FfiDiag") (ELit (LString "T-FFI-DUPLICATE-HOST"))) (EApp (EVar "Some") (EFieldAccess (EVar "b") "ebLoc"))) (EApp (EApp (EVar "ffiDuplicateHostMsg") (EVar "n")) (EFieldAccess (EVar "b") "ebHost"))) (EApp (EApp (EApp (EVar "ffiClauseDiags") (EVar "n")) (EVar "seen")) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "ffiClauseDiags") (EVar "n")) (EBinOp "::" (EFieldAccess (EVar "b") "ebHost") (EVar "seen"))) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "ffiSymbolDiags" (TyFun (TyCon "ExternDecl") (TyFun (TyCon "ExternBind") (TyApp (TyCon "List") (TyCon "FfiDiag")))))
(DFunDef false "ffiSymbolDiags" ((PVar "d") (PVar "b")) (EMatch (EFieldAccess (EVar "b") "ebHost") (arm (PLit (LString "c")) () (EIf (EApp (EVar "not") (EApp (EApp (EApp (EVar "isIdentWith") (EVar "isCIdentStart")) (EVar "isCIdentChar")) (EFieldAccess (EVar "b") "ebSymbol"))) (EListLit (EApp (EApp (EApp (EVar "FfiDiag") (ELit (LString "T-FFI-C-SYMBOL"))) (EApp (EVar "Some") (EFieldAccess (EVar "b") "ebLoc"))) (EApp (EApp (EApp (EVar "ffiCSymbolMsg") (EFieldAccess (EVar "d") "edName")) (EFieldAccess (EVar "b") "ebSymbol")) (EApp (EVar "isEmptyBinds") (EVar "d"))))) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "mdk_"))) (EFieldAccess (EVar "b") "ebSymbol")) (EListLit (EApp (EApp (EApp (EVar "FfiDiag") (ELit (LString "T-FFI-RESERVED-NAME"))) (EApp (EVar "Some") (EFieldAccess (EVar "b") "ebLoc"))) (EApp (EApp (EApp (EVar "ffiReservedMsg") (EFieldAccess (EVar "d") "edName")) (EFieldAccess (EVar "b") "ebSymbol")) (EApp (EVar "isEmptyBinds") (EVar "d"))))) (EListLit)))) (arm (PLit (LString "js")) () (EIf (EApp (EApp (EApp (EVar "isIdentWith") (EVar "isJsIdentStart")) (EVar "isJsIdentChar")) (EFieldAccess (EVar "b") "ebSymbol")) (EListLit) (EListLit (EApp (EApp (EApp (EVar "FfiDiag") (ELit (LString "T-FFI-JS-NAME"))) (EApp (EVar "Some") (EFieldAccess (EVar "b") "ebLoc"))) (EApp (EApp (EVar "ffiJsNameMsg") (EFieldAccess (EVar "d") "edName")) (EFieldAccess (EVar "b") "ebSymbol")))))) (arm PWild () (EListLit))))
(DTypeSig false "isEmptyBinds" (TyFun (TyCon "ExternDecl") (TyCon "Bool")))
(DFunDef false "isEmptyBinds" ((PVar "d")) (EMatch (EFieldAccess (EVar "d") "edBinds") (arm (PList) () (EVar "True")) (arm PWild () (EVar "False"))))
(DTypeSig false "isIdentWith" (TyFun (TyFun (TyCon "Char") (TyCon "Bool")) (TyFun (TyFun (TyCon "Char") (TyCon "Bool")) (TyFun (TyCon "String") (TyCon "Bool")))))
(DFunDef false "isIdentWith" ((PVar "start") (PVar "rest") (PVar "s")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "s"))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EBinOp ">" (EApp (EVar "arrayLength") (EVar "cs")) (ELit (LInt 0))) (EApp (EVar "start") (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 0))) (EVar "cs")))) (EApp (EApp (EApp (EVar "identCharsFrom") (EVar "rest")) (EVar "cs")) (ELit (LInt 1)))))))
(DTypeSig false "identCharsFrom" (TyFun (TyFun (TyCon "Char") (TyCon "Bool")) (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "identCharsFrom" ((PVar "p") (PVar "cs") (PVar "i")) (EBinOp "||" (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "cs"))) (EBinOp "&&" (EApp (EVar "p") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs"))) (EApp (EApp (EApp (EVar "identCharsFrom") (EVar "p")) (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))))))
(DTypeSig false "isCIdentChar" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isCIdentChar" ((PVar "c")) (EBinOp "&&" (EApp (EVar "isAlnum") (EVar "c")) (EApp (EVar "not") (EApp (EVar "isApos") (EVar "c")))))
(DTypeSig false "isCIdentStart" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isCIdentStart" ((PVar "c")) (EBinOp "&&" (EApp (EVar "isCIdentChar") (EVar "c")) (EApp (EVar "not") (EApp (EVar "isDigit") (EVar "c")))))
(DTypeSig false "isJsIdentStart" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isJsIdentStart" ((PVar "c")) (EBinOp "||" (EApp (EVar "isCIdentStart") (EVar "c")) (EBinOp "==" (EVar "c") (ELit (LChar "$")))))
(DTypeSig false "isJsIdentChar" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isJsIdentChar" ((PVar "c")) (EBinOp "||" (EApp (EVar "isJsIdentStart") (EVar "c")) (EApp (EVar "isDigit") (EVar "c"))))
(DTypeSig false "ffiNullaryMsg" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "ffiNullaryMsg" ((PVar "n")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "foreign declaration `")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "` has no arrow in its signature, so it declares a foreign value rather than a foreign call; declare a call instead, `extern "))) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString " : Unit -> <FFI \"c\"> T`, invoked as `"))) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString " ()`"))))
(DTypeSig false "ffiDeclaredLabelMsg" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "ffiDeclaredLabelMsg" ((PVar "n")) (EBinOp "++" (EBinOp "++" (ELit (LString "foreign declaration `")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "` names `FFI` in its result row, but that `FFI` is a label declared with `effect FFI`, not the foreign-call effect; rename the declared label so `FFI` here means the foreign call"))))
(DTypeSig false "ffiUnlabelledMsg" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "ffiUnlabelledMsg" ((PVar "n")) (EBinOp "++" (EBinOp "++" (ELit (LString "foreign declaration `")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "` does not name the `FFI` effect in its result row; write `<FFI \"c\">` joined with whatever else the row names, such as `<FFI \"c\", Net \"a.com/*\">`"))))
(DTypeSig false "ffiNoHostMsg" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyCon "String"))))
(DFunDef false "ffiNoHostMsg" ((PVar "n") (PVar "written")) (EBlock (DoLet false false (PVar "fix") (EMatch (EVar "written") (arm (PCon "Some" (PVar "p")) () (EApp (EVar "ffiNoHostFix") (EVar "p"))) (arm (PCon "None") () (ELit (LString "write `<FFI \"c\">` for a C function"))))) (DoLet false false (PVar "shown") (EMatch (EVar "written") (arm (PCon "Some" (PVar "lib")) () (EBinOp "++" (EBinOp "++" (ELit (LString "`FFI \"")) (EApp (EMethodRef "display") (EVar "lib"))) (ELit (LString "\"`")))) (arm (PCon "None") () (ELit (LString "`FFI`"))))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "foreign declaration `")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "` names "))) (EApp (EMethodRef "display") (EVar "shown"))) (ELit (LString " with no host in its result row; the parameter is a host, `c` or `js`, optionally followed by `/` and a library: "))) (EApp (EMethodRef "display") (EVar "fix"))) (ELit (LString ""))))))
(DTypeSig false "ffiNoHostFix" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "ffiNoHostFix" ((PVar "p")) (EBlock (DoLet false false (PVar "base") (EApp (EVar "dropTrailingSlash") (EApp (EVar "dropTrailingStar") (EVar "p")))) (DoExpr (EIf (EApp (EApp (EVar "contains") (EVar "base")) (EVar "ffiHosts")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "write `<FFI \"")) (EApp (EMethodRef "display") (EVar "base"))) (ELit (LString "\">` for the `"))) (EApp (EMethodRef "display") (EVar "base"))) (ELit (LString "` host"))) (EIf (EApp (EApp (EVar "contains") (EApp (EVar "toLower") (EVar "base"))) (EVar "ffiHosts")) (EBinOp "++" (EBinOp "++" (ELit (LString "host names are lower-case: write `<FFI \"")) (EApp (EMethodRef "display") (EApp (EVar "toLower") (EVar "base")))) (ELit (LString "\">`"))) (EBinOp "++" (EBinOp "++" (ELit (LString "write `<FFI \"c/")) (EApp (EMethodRef "display") (EVar "p"))) (ELit (LString "\">` for a C library"))))))))
(DTypeSig false "dropTrailingStar" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "dropTrailingStar" ((PVar "s")) (EMatch (EApp (EApp (EVar "stripSuffix") (ELit (LString "*"))) (EVar "s")) (arm (PCon "Some" (PVar "rest")) () (EVar "rest")) (arm (PCon "None") () (EVar "s"))))
(DTypeSig false "dropTrailingSlash" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "dropTrailingSlash" ((PVar "s")) (EMatch (EApp (EApp (EVar "stripSuffix") (ELit (LString "/"))) (EVar "s")) (arm (PCon "Some" (PVar "rest")) () (EVar "rest")) (arm (PCon "None") () (EVar "s"))))
(DTypeSig false "ffiUnboundHostMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "ffiUnboundHostMsg" ((PVar "n") (PVar "h")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "foreign declaration `")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "` names the `"))) (EApp (EMethodRef "display") (EVar "h"))) (ELit (LString "` host in its result row but has no `"))) (EApp (EMethodRef "display") (EVar "h"))) (ELit (LString "` binding; add an indented `bind "))) (EApp (EMethodRef "display") (EVar "h"))) (ELit (LString " \"<name>\"` line under its signature"))))
(DTypeSig false "ffiUnknownHostMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "ffiUnknownHostMsg" ((PVar "n") (PVar "h")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "foreign declaration `")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "` binds the unknown host `"))) (EApp (EMethodRef "display") (EVar "h"))) (ELit (LString "`; a binding names `c` or `js`"))))
(DTypeSig false "ffiDuplicateHostMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "ffiDuplicateHostMsg" ((PVar "n") (PVar "h")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "foreign declaration `")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "` binds the `"))) (EApp (EMethodRef "display") (EVar "h"))) (ELit (LString "` host more than once; keep one `bind "))) (EApp (EMethodRef "display") (EVar "h"))) (ELit (LString "` line"))))
(DTypeSig false "ffiCSymbolMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyCon "String")))))
(DFunDef false "ffiCSymbolMsg" ((PVar "n") (PVar "sym") (PVar "implied")) (EBlock (DoLet false false (PVar "what") (EIf (EVar "implied") (EBinOp "++" (EBinOp "++" (ELit (LString "is bound to C under its own name, and `")) (EApp (EMethodRef "display") (EVar "sym"))) (ELit (LString "`"))) (EBinOp "++" (EBinOp "++" (ELit (LString "binds the C symbol `")) (EApp (EMethodRef "display") (EVar "sym"))) (ELit (LString "`, which"))))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "foreign declaration `")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "` "))) (EApp (EMethodRef "display") (EVar "what"))) (ELit (LString " is not a C identifier (a letter or `_`, then letters, digits and `_`); bind a C symbol with `bind c \"<symbol>\"`"))))))
(DTypeSig false "ffiJsNameMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "ffiJsNameMsg" ((PVar "n") (PVar "name")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "foreign declaration `")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "` binds the JavaScript name `"))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "`, which is not a JavaScript identifier (a letter, `_` or `$`, then letters, digits, `_` and `$`)"))))
(DTypeSig false "ffiReservedMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyCon "String")))))
(DFunDef false "ffiReservedMsg" ((PVar "n") (PVar "sym") (PVar "implied")) (EBlock (DoLet false false (PVar "fix") (EIf (EVar "implied") (ELit (LString "rename the extern, or bind another symbol with `bind c \"<symbol>\"`")) (ELit (LString "bind another symbol")))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "foreign declaration `")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "` claims a reserved name: its C symbol `"))) (EApp (EMethodRef "display") (EVar "sym"))) (ELit (LString "` is in the `mdk_` prefix, the runtime's own C symbol namespace; "))) (EApp (EMethodRef "display") (EVar "fix"))) (ELit (LString ""))))))
(DTypeSig false "ffiBuiltinBindMsg" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "ffiBuiltinBindMsg" ((PVar "n")) (EBinOp "++" (EBinOp "++" (ELit (LString "foreign declaration `")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "` redeclares a built-in, which always runs the built-in's own implementation, so it takes no `bind` clause; drop the clause, or rename the extern"))))
(DTypeSig true "ffiNonCrossableMsg" (TyFun (TyCon "String") (TyFun (TyCon "Ty") (TyCon "String"))))
(DFunDef false "ffiNonCrossableMsg" ((PVar "n") (PVar "t")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "type `")) (EApp (EMethodRef "display") (EApp (EVar "ppTy") (EVar "t")))) (ELit (LString "` cannot cross the foreign-function boundary in extern `"))) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "`; marshal it into one of Int, Float, Bool, Char, String, Unit, U8, U16, U32, U64, I32, I64 or Array Int"))))
(DTypeSig true "ffiShadowMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "ffiShadowMsg" ((PVar "n") (PVar "want") (PVar "got")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "foreign declaration `")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "` redeclares a built-in at a type it does not have: the built-in is `"))) (EApp (EMethodRef "display") (EVar "want"))) (ELit (LString "`, this declaration claims `"))) (EApp (EMethodRef "display") (EVar "got"))) (ELit (LString "`; rename the extern, or declare it at the built-in's signature"))))
(DTypeSig true "ffiCatalogTailMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))))
(DFunDef false "ffiCatalogTailMsg" ((PVar "n") (PVar "arrow") (PVar "missing")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "foreign declaration `")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "` redeclares a built-in with a narrower effect row"))) (EApp (EMethodRef "display") (EVar "arrow"))) (ELit (LString ": the built-in also performs the row variable "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EVar "missing")))) (ELit (LString "; write that variable in the row, or rename the extern"))))
(DTypeSig true "ffiCatalogNarrowMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "String")))))))
(DFunDef false "ffiCatalogNarrowMsg" ((PVar "n") (PVar "arrow") (PVar "cat") (PVar "decl") (PVar "missing")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "foreign declaration `")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "` redeclares a built-in with a narrower effect row"))) (EApp (EMethodRef "display") (EVar "arrow"))) (ELit (LString ": the built-in performs <"))) (EApp (EMethodRef "display") (EApp (EVar "renderAtoms") (EVar "cat")))) (ELit (LString ">, which this row does not cover at <"))) (EApp (EMethodRef "display") (EApp (EVar "renderAtoms") (EVar "missing")))) (ELit (LString ">"))) (EApp (EMethodRef "display") (EApp (EVar "ffiCatalogTopNote") (EVar "missing")))) (ELit (LString "; declare `<"))) (EApp (EMethodRef "display") (EApp (EVar "renderAtoms") (EVar "cat")))) (ELit (LString ">` or wider, or rename the extern"))))
(DTypeSig false "ffiCatalogTopNote" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "String")))
(DFunDef false "ffiCatalogTopNote" ((PVar "missing")) (EMatch (EApp (EApp (EMethodRef "map") (EVar "atomLabel")) (EApp (EApp (EVar "filterList") (EVar "atomParamIsTop")) (EApp (EVar "atomsNorm") (EVar "missing")))) (arm (PList) () (ELit (LString ""))) (arm (PVar "ls") () (EBinOp "++" (EBinOp "++" (ELit (LString " (")) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString "/"))) (EVar "ls")))) (ELit (LString " there admits any value, not none)"))))))
(DTypeSig false "atomParamIsTop" (TyFun (TyCon "Atom") (TyCon "Bool")))
(DFunDef false "atomParamIsTop" ((PVar "a")) (EMatch (EApp (EVar "atomConst") (EVar "a")) (arm (PCon "Some" (PVar "p")) () (EApp (EVar "paramIsTopDomain") (EApp (EVar "canonParam") (EVar "p")))) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "paramIsTopDomain" (TyFun (TyCon "Param") (TyCon "Bool")))
(DFunDef false "paramIsTopDomain" ((PCon "PPrefix" (PCon "None"))) (EVar "True"))
(DFunDef false "paramIsTopDomain" ((PCon "PPath" (PCon "None"))) (EVar "True"))
(DFunDef false "paramIsTopDomain" ((PCon "PSet" (PCon "None"))) (EVar "True"))
(DFunDef false "paramIsTopDomain" ((PAs "p" (PCon "PProduct" PWild))) (EApp (EVar "isSubTop") (EVar "p")))
(DFunDef false "paramIsTopDomain" (PWild) (EVar "False"))
