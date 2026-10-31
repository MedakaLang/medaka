# META
source_lines=247
stages=DESUGAR,MARK
# SOURCE
-- tc_solve_test_support: the drive `typecheck_test` and `publish_test` share to observe the
-- solver through one whole check of a parsed source: its diagnostics and their codes, the
-- route words it stamps, the schemes it publishes, the evidence and disposition it keeps.
-- It imports `types.typecheck`, so the solver siblings (`tc_solve_givens_test`,
-- `tc_solve_entail_test`, `tc_solve_test`, `tc_solve_check_test`), which sit below it, do
-- not import it; they build their inputs from `tc_test_support`.  No production module
-- imports this file.

import support.diag_codes.{codeText}
import list.{sort, filter, sortOn, indexed}
import test.{Expectation, expectEqual}
import frontend.ast.{
  EvEntry(..), EvVal(..), Route(..), TyConOrigin(..), EvId(..), Loc(..)
}
import frontend.desugar.{desugar}
import frontend.parser.{parse, parseLocated}
import support.util.{joinNl, listLen}
import string.{join}
import types.tc_types.{
  DriveInputs(..), EvidenceObservationEntry(..), TraceSink,
  MethodReturnMemoView(..), DriveOutputs(..), InvocationView(..), TcConfig(..),
  ElabFacts(..)
}
import types.typecheck.{
  ModDiags, checkOneDiags, defaultDriveInputs, elaborateModules, tcCode, tcMsg,
  checkOneSchemeFullK
}
import types.repr.{Mono(..), Tyvar(..), Scheme(..), IfaceRef(..), VecObl(..)}
import types.effect_domain.{Param(..)}
import types.effect_rows.{EffRow(..), Effvar(..), Atom(..), EffLabel(..)}
import types.effect_authority.{Authority(..), Authvar(..)}
import types.publish.{
  PubScheme(..), VarKind(..), LiveCell(..), ppPubScheme, TcReport(..),
  CheckedProgram(..), EntryOutcome(..), PartialAnalysis(..), ModDiags,
  TcDiag(..)
}
import types.disposition.{
  MethodDisposition(..), dispositionRows, dispositionKey, dispositionInstance,
  dispositionMethod, dispositionIface
}
import types.evidence_coverage.{EvShape(..)}
import types.capability_manifest.{
  EntryKey(..), ManifestRequest(..), ManifestSelector(..),
  InvocationProtocol(..), ManifestLookup(..), FrozenAuthority(..)
}
import types.effect_invocation.{InvocationOps(..)}

-- The diagnostics of one check of [src] as the only module, with no stdlib and no profile.
export
checkDiags : String -> List (String, String)
checkDiags = checkDiagsOver ""

-- The diagnostics of one check of [src] over the core declarations [core] (a miniature
-- prelude; "" is none).
export
checkDiagsOver : String -> String -> List (String, String)
checkDiagsOver core src =
  let (errors, _) = checkOneDiags defaultDriveInputs [] (desugar (parse core)) (
    "probe",
    desugar (parseLocated src),
  )
  map (d => (codeText (tcCode d), tcMsg d)) errors

-- The codes of [checkDiags], in report order.
export
checkCodes : String -> List String
checkCodes src = map fst (checkDiags src)

-- [src] checks with no diagnostic.
export
expectChecks : String -> Expectation
expectChecks src = expectEqual [] (checkCodes src)

-- [src] is rejected with the codes [expected], in report order.
export
expectRejectedWith : List String -> String -> Expectation
expectRejectedWith expected src = expectEqual expected (checkCodes src)

-- The route words the solver stamped for [src] as the only module, sorted: every dictionary
-- key a site or an instance prerequisite resolved to, with the dictionary variables and
-- local abstractions it forwards.  A source that does not check has the words of whatever
-- the drive still stamped, so a test that reads them also asserts the check is clean.
export
routeWordsOf : String -> List String
routeWordsOf = routeWordsOver ""

-- [routeWordsOf] over the core declarations [core] (a miniature prelude).
export
routeWordsOver : String -> String -> List String
routeWordsOver core src =
  let elab = elaborateModules defaultDriveInputs [] (desugar (parse core)) [
    ("probe", desugar (parseLocated src)),
  ]
  sort (flatMap evidenceWords elab.erEvidence)

evidenceWords : EvEntry -> List String
evidenceWords (EvEntry _ val) = match val
  EvOne r => routeWords r
  EvMany rs => flatMap routeWords rs
  EvMethod _ _ r pre post => routeWords r ++ flatMap routeWords (pre ++ post)
  EvLit _ r => routeWords r
  EvHead _ => []

routeWords : Route -> List String
routeWords RNone = []
routeWords (RKey word a b) = word :: flatMap routeWords (a ++ b)
routeWords (RDict name) = ["dict:\{name}"]
routeWords (RDictFwd name) = ["dictfwd:\{name}"]
routeWords (RLocal name rs) = "local:\{name}" :: flatMap routeWords rs
routeWords (RScalar name) = ["scalar:\{name}"]
routeWords (RProj r _path) = routeWords r

-- The inputs of a drive a test observes through [sink]: nothing stdlib-owned, no
-- profile, the sink as the trace.
export
traced : TraceSink -> DriveInputs
traced sink = { defaultDriveInputs | diTrace = Some sink }

export
numericPreludeSource : String
numericPreludeSource = joinNl [
  "interface Num a where",
  "  fromInt : Int -> a",
  "impl Num Int where",
  "  fromInt n = n",
]

export
absentReturnSource : Bool -> Bool -> String
absentReturnSource reverseImpls ambient =
  let charImpl = joinNl [
    "impl Hidden Int Char where",
    "  hidden _ = 22",
  ]
  let boolImpl = joinNl [
    "impl Hidden Int Bool where",
    "  hidden _ = 12",
  ]
  let impls =
    if reverseImpls then [boolImpl, charImpl] else [charImpl, boolImpl]
  joinNl
    ([
        "interface Hidden a b where",
        "  hidden : Unit -> a",
      ]
      ++ impls
      ++ (if ambient then
        [
          "useHidden : Hidden a b => b -> a",
          "useHidden witness = hidden ()",
          "value : Int",
          "value = useHidden True : Int",
        ]
      else
        [
          "value : Int",
          "value = hidden ()",
        ]))

export
modErrorCount : List ModDiags -> Int
modErrorCount [] = 0
modErrorCount ((_, (_, errors, _)) :: rest) =
  listLen errors + modErrorCount rest

export
evidenceEntriesOfKind : String ->
  List EvidenceObservationEntry ->
  List EvidenceObservationEntry
evidenceEntriesOfKind kind = filter (e => e.eoeGoalKind == kind)

export
drive : String -> String -> List (String, PubScheme)
drive mid src =
  let (_, own) = checkOneSchemeFullK defaultDriveInputs None [] [] (
    mid,
    desugar (parseLocated src),
  )
  own

export
rendered : List (String, PubScheme) -> List String
rendered ss = map (e => "\{fst e} : \{ppPubScheme (snd e)}") ss

export
linkCount : Scheme -> Int
linkCount (Forall _ _ _ _ _ t) = monoLinks t

export
monoLinks : Mono -> Int
monoLinks (TVar cell) = match !cell
  Link t2 => 1 + monoLinks t2
  Unbound _ _ => 0
monoLinks (TApp a b) = monoLinks a + monoLinks b
monoLinks (TFun a _ b) = monoLinks a + monoLinks b
monoLinks (TQual a _) = monoLinks a
monoLinks _ = 0

-- The evidence in ordinal order, each id replaced by its rank, then the
-- disposition rows; `withheld` when there is no checked program.
export
accRenderChecked : Option CheckedProgram -> List String
accRenderChecked None = ["withheld"]
accRenderChecked (Some c) =
  let ordered =
    sortOn
      (e => match e
        EvEntry (EvId m i) _ => (m, i))
      c.cpEvidence
  "checked"
    :: map
        (ie => match ie
          (rank, EvEntry _ v) => "ev \{debug rank} \{valText v}")
        (indexed ordered)
      ++ map dispositionText (dispositionRows c.cpDispositions)

export
dispositionText : MethodDisposition -> String
dispositionText d =
  let kind = match d
    Supplied {  } => "supplied"
    InheritedDefault {  } => "inherited"
  let key = dispositionKey (dispositionInstance d) (dispositionMethod d)
  "disp \{kind} \{(dispositionIface d).irName} \{key}"

export
routeText : Route -> String
routeText RNone = "none"
routeText (RKey w ds sups) = "key(\{w};\{routesText ds};\{routesText sups})"
routeText (RDict d) = "dict(\{d})"
routeText (RDictFwd d) = "fwd(\{d})"
routeText (RLocal s ds) = "local(\{s};\{routesText ds})"
routeText (RScalar s) = "scalar(\{s})"
routeText (RProj r path) = "proj(\{routeText r};\{debug path})"

export
routesText : List Route -> String
routesText rs = join "," (map routeText rs)

export
valText : EvVal -> String
valText (EvOne r) = routeText r
valText (EvMany rs) = routesText rs
valText (EvMethod iface arity r impls meths) =
  "\{iface}/\{debug arity} \{routeText r} \{routesText impls} \{routesText meths}"
valText (EvLit f r) = "\{debug f} \{routeText r}"
valText (EvHead h) = h
# DESUGAR
(DUse false (UseGroup ("support" "diag_codes") ((mem "codeText" false))))
(DUse false (UseGroup ("list") ((mem "sort" false) (mem "filter" false) (mem "sortOn" false) (mem "indexed" false))))
(DUse false (UseGroup ("test") ((mem "Expectation" false) (mem "expectEqual" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "EvEntry" true) (mem "EvVal" true) (mem "Route" true) (mem "TyConOrigin" true) (mem "EvId" true) (mem "Loc" true))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "desugar" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "parse" false) (mem "parseLocated" false))))
(DUse false (UseGroup ("support" "util") ((mem "joinNl" false) (mem "listLen" false))))
(DUse false (UseGroup ("string") ((mem "join" false))))
(DUse false (UseGroup ("types" "tc_types") ((mem "DriveInputs" true) (mem "EvidenceObservationEntry" true) (mem "TraceSink" false) (mem "MethodReturnMemoView" true) (mem "DriveOutputs" true) (mem "InvocationView" true) (mem "TcConfig" true) (mem "ElabFacts" true))))
(DUse false (UseGroup ("types" "typecheck") ((mem "ModDiags" false) (mem "checkOneDiags" false) (mem "defaultDriveInputs" false) (mem "elaborateModules" false) (mem "tcCode" false) (mem "tcMsg" false) (mem "checkOneSchemeFullK" false))))
(DUse false (UseGroup ("types" "repr") ((mem "Mono" true) (mem "Tyvar" true) (mem "Scheme" true) (mem "IfaceRef" true) (mem "VecObl" true))))
(DUse false (UseGroup ("types" "effect_domain") ((mem "Param" true))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "EffRow" true) (mem "Effvar" true) (mem "Atom" true) (mem "EffLabel" true))))
(DUse false (UseGroup ("types" "effect_authority") ((mem "Authority" true) (mem "Authvar" true))))
(DUse false (UseGroup ("types" "publish") ((mem "PubScheme" true) (mem "VarKind" true) (mem "LiveCell" true) (mem "ppPubScheme" false) (mem "TcReport" true) (mem "CheckedProgram" true) (mem "EntryOutcome" true) (mem "PartialAnalysis" true) (mem "ModDiags" false) (mem "TcDiag" true))))
(DUse false (UseGroup ("types" "disposition") ((mem "MethodDisposition" true) (mem "dispositionRows" false) (mem "dispositionKey" false) (mem "dispositionInstance" false) (mem "dispositionMethod" false) (mem "dispositionIface" false))))
(DUse false (UseGroup ("types" "evidence_coverage") ((mem "EvShape" true))))
(DUse false (UseGroup ("types" "capability_manifest") ((mem "EntryKey" true) (mem "ManifestRequest" true) (mem "ManifestSelector" true) (mem "InvocationProtocol" true) (mem "ManifestLookup" true) (mem "FrozenAuthority" true))))
(DUse false (UseGroup ("types" "effect_invocation") ((mem "InvocationOps" true))))
(DTypeSig true "checkDiags" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "checkDiags" () (EApp (EVar "checkDiagsOver") (ELit (LString ""))))
(DTypeSig true "checkDiagsOver" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "checkDiagsOver" ((PVar "core") (PVar "src")) (EBlock (DoLet false false (PTuple (PVar "errors") PWild) (EApp (EApp (EApp (EApp (EVar "checkOneDiags") (EVar "defaultDriveInputs")) (EListLit)) (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "core")))) (ETuple (ELit (LString "probe")) (EApp (EVar "desugar") (EApp (EVar "parseLocated") (EVar "src")))))) (DoExpr (EApp (EApp (EVar "map") (ELam ((PVar "d")) (ETuple (EApp (EVar "codeText") (EApp (EVar "tcCode") (EVar "d"))) (EApp (EVar "tcMsg") (EVar "d"))))) (EVar "errors")))))
(DTypeSig true "checkCodes" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "checkCodes" ((PVar "src")) (EApp (EApp (EVar "map") (EVar "fst")) (EApp (EVar "checkDiags") (EVar "src"))))
(DTypeSig true "expectChecks" (TyFun (TyCon "String") (TyCon "Expectation")))
(DFunDef false "expectChecks" ((PVar "src")) (EApp (EApp (EVar "expectEqual") (EListLit)) (EApp (EVar "checkCodes") (EVar "src"))))
(DTypeSig true "expectRejectedWith" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyCon "Expectation"))))
(DFunDef false "expectRejectedWith" ((PVar "expected") (PVar "src")) (EApp (EApp (EVar "expectEqual") (EVar "expected")) (EApp (EVar "checkCodes") (EVar "src"))))
(DTypeSig true "routeWordsOf" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "routeWordsOf" () (EApp (EVar "routeWordsOver") (ELit (LString ""))))
(DTypeSig true "routeWordsOver" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "routeWordsOver" ((PVar "core") (PVar "src")) (EBlock (DoLet false false (PVar "elab") (EApp (EApp (EApp (EApp (EVar "elaborateModules") (EVar "defaultDriveInputs")) (EListLit)) (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "core")))) (EListLit (ETuple (ELit (LString "probe")) (EApp (EVar "desugar") (EApp (EVar "parseLocated") (EVar "src"))))))) (DoExpr (EApp (EVar "sort") (EApp (EApp (EVar "flatMap") (EVar "evidenceWords")) (EFieldAccess (EVar "elab") "erEvidence"))))))
(DTypeSig false "evidenceWords" (TyFun (TyCon "EvEntry") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "evidenceWords" ((PCon "EvEntry" PWild (PVar "val"))) (EMatch (EVar "val") (arm (PCon "EvOne" (PVar "r")) () (EApp (EVar "routeWords") (EVar "r"))) (arm (PCon "EvMany" (PVar "rs")) () (EApp (EApp (EVar "flatMap") (EVar "routeWords")) (EVar "rs"))) (arm (PCon "EvMethod" PWild PWild (PVar "r") (PVar "pre") (PVar "post")) () (EBinOp "++" (EApp (EVar "routeWords") (EVar "r")) (EApp (EApp (EVar "flatMap") (EVar "routeWords")) (EBinOp "++" (EVar "pre") (EVar "post"))))) (arm (PCon "EvLit" PWild (PVar "r")) () (EApp (EVar "routeWords") (EVar "r"))) (arm (PCon "EvHead" PWild) () (EListLit))))
(DTypeSig false "routeWords" (TyFun (TyCon "Route") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "routeWords" ((PCon "RNone")) (EListLit))
(DFunDef false "routeWords" ((PCon "RKey" (PVar "word") (PVar "a") (PVar "b"))) (EBinOp "::" (EVar "word") (EApp (EApp (EVar "flatMap") (EVar "routeWords")) (EBinOp "++" (EVar "a") (EVar "b")))))
(DFunDef false "routeWords" ((PCon "RDict" (PVar "name"))) (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "dict:")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "")))))
(DFunDef false "routeWords" ((PCon "RDictFwd" (PVar "name"))) (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "dictfwd:")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "")))))
(DFunDef false "routeWords" ((PCon "RLocal" (PVar "name") (PVar "rs"))) (EBinOp "::" (EBinOp "++" (EBinOp "++" (ELit (LString "local:")) (EApp (EVar "display") (EVar "name"))) (ELit (LString ""))) (EApp (EApp (EVar "flatMap") (EVar "routeWords")) (EVar "rs"))))
(DFunDef false "routeWords" ((PCon "RScalar" (PVar "name"))) (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "scalar:")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "")))))
(DFunDef false "routeWords" ((PCon "RProj" (PVar "r") (PVar "_path"))) (EApp (EVar "routeWords") (EVar "r")))
(DTypeSig true "traced" (TyFun (TyCon "TraceSink") (TyCon "DriveInputs")))
(DFunDef false "traced" ((PVar "sink")) (ERecordUpdate (EVar "defaultDriveInputs") ((fa "diTrace" (EApp (EVar "Some") (EVar "sink"))))))
(DTypeSig true "numericPreludeSource" (TyCon "String"))
(DFunDef false "numericPreludeSource" () (EApp (EVar "joinNl") (EListLit (ELit (LString "interface Num a where")) (ELit (LString "  fromInt : Int -> a")) (ELit (LString "impl Num Int where")) (ELit (LString "  fromInt n = n")))))
(DTypeSig true "absentReturnSource" (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyCon "String"))))
(DFunDef false "absentReturnSource" ((PVar "reverseImpls") (PVar "ambient")) (EBlock (DoLet false false (PVar "charImpl") (EApp (EVar "joinNl") (EListLit (ELit (LString "impl Hidden Int Char where")) (ELit (LString "  hidden _ = 22"))))) (DoLet false false (PVar "boolImpl") (EApp (EVar "joinNl") (EListLit (ELit (LString "impl Hidden Int Bool where")) (ELit (LString "  hidden _ = 12"))))) (DoLet false false (PVar "impls") (EIf (EVar "reverseImpls") (EListLit (EVar "boolImpl") (EVar "charImpl")) (EListLit (EVar "charImpl") (EVar "boolImpl")))) (DoExpr (EApp (EVar "joinNl") (EBinOp "++" (EBinOp "++" (EListLit (ELit (LString "interface Hidden a b where")) (ELit (LString "  hidden : Unit -> a"))) (EVar "impls")) (EIf (EVar "ambient") (EListLit (ELit (LString "useHidden : Hidden a b => b -> a")) (ELit (LString "useHidden witness = hidden ()")) (ELit (LString "value : Int")) (ELit (LString "value = useHidden True : Int"))) (EListLit (ELit (LString "value : Int")) (ELit (LString "value = hidden ()")))))))))
(DTypeSig true "modErrorCount" (TyFun (TyApp (TyCon "List") (TyCon "ModDiags")) (TyCon "Int")))
(DFunDef false "modErrorCount" ((PList)) (ELit (LInt 0)))
(DFunDef false "modErrorCount" ((PCons (PTuple PWild (PTuple PWild (PVar "errors") PWild)) (PVar "rest"))) (EBinOp "+" (EApp (EVar "listLen") (EVar "errors")) (EApp (EVar "modErrorCount") (EVar "rest"))))
(DTypeSig true "evidenceEntriesOfKind" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "EvidenceObservationEntry")) (TyApp (TyCon "List") (TyCon "EvidenceObservationEntry")))))
(DFunDef false "evidenceEntriesOfKind" ((PVar "kind")) (EApp (EVar "filter") (ELam ((PVar "e")) (EBinOp "==" (EFieldAccess (EVar "e") "eoeGoalKind") (EVar "kind")))))
(DTypeSig true "drive" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))))))
(DFunDef false "drive" ((PVar "mid") (PVar "src")) (EBlock (DoLet false false (PTuple PWild (PVar "own")) (EApp (EApp (EApp (EApp (EApp (EVar "checkOneSchemeFullK") (EVar "defaultDriveInputs")) (EVar "None")) (EListLit)) (EListLit)) (ETuple (EVar "mid") (EApp (EVar "desugar") (EApp (EVar "parseLocated") (EVar "src")))))) (DoExpr (EVar "own"))))
(DTypeSig true "rendered" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "rendered" ((PVar "ss")) (EApp (EApp (EVar "map") (ELam ((PVar "e")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "fst") (EVar "e")))) (ELit (LString " : "))) (EApp (EVar "display") (EApp (EVar "ppPubScheme") (EApp (EVar "snd") (EVar "e"))))) (ELit (LString ""))))) (EVar "ss")))
(DTypeSig true "linkCount" (TyFun (TyCon "Scheme") (TyCon "Int")))
(DFunDef false "linkCount" ((PCon "Forall" PWild PWild PWild PWild PWild (PVar "t"))) (EApp (EVar "monoLinks") (EVar "t")))
(DTypeSig true "monoLinks" (TyFun (TyCon "Mono") (TyCon "Int")))
(DFunDef false "monoLinks" ((PCon "TVar" (PVar "cell"))) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "Link" (PVar "t2")) () (EBinOp "+" (ELit (LInt 1)) (EApp (EVar "monoLinks") (EVar "t2")))) (arm (PCon "Unbound" PWild PWild) () (ELit (LInt 0)))))
(DFunDef false "monoLinks" ((PCon "TApp" (PVar "a") (PVar "b"))) (EBinOp "+" (EApp (EVar "monoLinks") (EVar "a")) (EApp (EVar "monoLinks") (EVar "b"))))
(DFunDef false "monoLinks" ((PCon "TFun" (PVar "a") PWild (PVar "b"))) (EBinOp "+" (EApp (EVar "monoLinks") (EVar "a")) (EApp (EVar "monoLinks") (EVar "b"))))
(DFunDef false "monoLinks" ((PCon "TQual" (PVar "a") PWild)) (EApp (EVar "monoLinks") (EVar "a")))
(DFunDef false "monoLinks" (PWild) (ELit (LInt 0)))
(DTypeSig true "accRenderChecked" (TyFun (TyApp (TyCon "Option") (TyCon "CheckedProgram")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "accRenderChecked" ((PCon "None")) (EListLit (ELit (LString "withheld"))))
(DFunDef false "accRenderChecked" ((PCon "Some" (PVar "c"))) (EBlock (DoLet false false (PVar "ordered") (EApp (EApp (EVar "sortOn") (ELam ((PVar "e")) (EMatch (EVar "e") (arm (PCon "EvEntry" (PCon "EvId" (PVar "m") (PVar "i")) PWild) () (ETuple (EVar "m") (EVar "i")))))) (EFieldAccess (EVar "c") "cpEvidence"))) (DoExpr (EBinOp "::" (ELit (LString "checked")) (EBinOp "++" (EApp (EApp (EVar "map") (ELam ((PVar "ie")) (EMatch (EVar "ie") (arm (PTuple (PVar "rank") (PCon "EvEntry" PWild (PVar "v"))) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "ev ")) (EApp (EVar "display") (EApp (EVar "debug") (EVar "rank")))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EVar "valText") (EVar "v")))) (ELit (LString ""))))))) (EApp (EVar "indexed") (EVar "ordered"))) (EApp (EApp (EVar "map") (EVar "dispositionText")) (EApp (EVar "dispositionRows") (EFieldAccess (EVar "c") "cpDispositions"))))))))
(DTypeSig true "dispositionText" (TyFun (TyCon "MethodDisposition") (TyCon "String")))
(DFunDef false "dispositionText" ((PVar "d")) (EBlock (DoLet false false (PVar "kind") (EMatch (EVar "d") (arm (PRec "Supplied" () false) () (ELit (LString "supplied"))) (arm (PRec "InheritedDefault" () false) () (ELit (LString "inherited"))))) (DoLet false false (PVar "key") (EApp (EApp (EVar "dispositionKey") (EApp (EVar "dispositionInstance") (EVar "d"))) (EApp (EVar "dispositionMethod") (EVar "d")))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "disp ")) (EApp (EVar "display") (EVar "kind"))) (ELit (LString " "))) (EApp (EVar "display") (EFieldAccess (EApp (EVar "dispositionIface") (EVar "d")) "irName"))) (ELit (LString " "))) (EApp (EVar "display") (EVar "key"))) (ELit (LString ""))))))
(DTypeSig true "routeText" (TyFun (TyCon "Route") (TyCon "String")))
(DFunDef false "routeText" ((PCon "RNone")) (ELit (LString "none")))
(DFunDef false "routeText" ((PCon "RKey" (PVar "w") (PVar "ds") (PVar "sups"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "key(")) (EApp (EVar "display") (EVar "w"))) (ELit (LString ";"))) (EApp (EVar "display") (EApp (EVar "routesText") (EVar "ds")))) (ELit (LString ";"))) (EApp (EVar "display") (EApp (EVar "routesText") (EVar "sups")))) (ELit (LString ")"))))
(DFunDef false "routeText" ((PCon "RDict" (PVar "d"))) (EBinOp "++" (EBinOp "++" (ELit (LString "dict(")) (EApp (EVar "display") (EVar "d"))) (ELit (LString ")"))))
(DFunDef false "routeText" ((PCon "RDictFwd" (PVar "d"))) (EBinOp "++" (EBinOp "++" (ELit (LString "fwd(")) (EApp (EVar "display") (EVar "d"))) (ELit (LString ")"))))
(DFunDef false "routeText" ((PCon "RLocal" (PVar "s") (PVar "ds"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "local(")) (EApp (EVar "display") (EVar "s"))) (ELit (LString ";"))) (EApp (EVar "display") (EApp (EVar "routesText") (EVar "ds")))) (ELit (LString ")"))))
(DFunDef false "routeText" ((PCon "RScalar" (PVar "s"))) (EBinOp "++" (EBinOp "++" (ELit (LString "scalar(")) (EApp (EVar "display") (EVar "s"))) (ELit (LString ")"))))
(DFunDef false "routeText" ((PCon "RProj" (PVar "r") (PVar "path"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "proj(")) (EApp (EVar "display") (EApp (EVar "routeText") (EVar "r")))) (ELit (LString ";"))) (EApp (EVar "display") (EApp (EVar "debug") (EVar "path")))) (ELit (LString ")"))))
(DTypeSig true "routesText" (TyFun (TyApp (TyCon "List") (TyCon "Route")) (TyCon "String")))
(DFunDef false "routesText" ((PVar "rs")) (EApp (EApp (EVar "join") (ELit (LString ","))) (EApp (EApp (EVar "map") (EVar "routeText")) (EVar "rs"))))
(DTypeSig true "valText" (TyFun (TyCon "EvVal") (TyCon "String")))
(DFunDef false "valText" ((PCon "EvOne" (PVar "r"))) (EApp (EVar "routeText") (EVar "r")))
(DFunDef false "valText" ((PCon "EvMany" (PVar "rs"))) (EApp (EVar "routesText") (EVar "rs")))
(DFunDef false "valText" ((PCon "EvMethod" (PVar "iface") (PVar "arity") (PVar "r") (PVar "impls") (PVar "meths"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "iface"))) (ELit (LString "/"))) (EApp (EVar "display") (EApp (EVar "debug") (EVar "arity")))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EVar "routeText") (EVar "r")))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EVar "routesText") (EVar "impls")))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EVar "routesText") (EVar "meths")))) (ELit (LString ""))))
(DFunDef false "valText" ((PCon "EvLit" (PVar "f") (PVar "r"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "debug") (EVar "f")))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EVar "routeText") (EVar "r")))) (ELit (LString ""))))
(DFunDef false "valText" ((PCon "EvHead" (PVar "h"))) (EVar "h"))
# MARK
(DUse false (UseGroup ("support" "diag_codes") ((mem "codeText" false))))
(DUse false (UseGroup ("list") ((mem "sort" false) (mem "filter" false) (mem "sortOn" false) (mem "indexed" false))))
(DUse false (UseGroup ("test") ((mem "Expectation" false) (mem "expectEqual" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "EvEntry" true) (mem "EvVal" true) (mem "Route" true) (mem "TyConOrigin" true) (mem "EvId" true) (mem "Loc" true))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "desugar" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "parse" false) (mem "parseLocated" false))))
(DUse false (UseGroup ("support" "util") ((mem "joinNl" false) (mem "listLen" false))))
(DUse false (UseGroup ("string") ((mem "join" false))))
(DUse false (UseGroup ("types" "tc_types") ((mem "DriveInputs" true) (mem "EvidenceObservationEntry" true) (mem "TraceSink" false) (mem "MethodReturnMemoView" true) (mem "DriveOutputs" true) (mem "InvocationView" true) (mem "TcConfig" true) (mem "ElabFacts" true))))
(DUse false (UseGroup ("types" "typecheck") ((mem "ModDiags" false) (mem "checkOneDiags" false) (mem "defaultDriveInputs" false) (mem "elaborateModules" false) (mem "tcCode" false) (mem "tcMsg" false) (mem "checkOneSchemeFullK" false))))
(DUse false (UseGroup ("types" "repr") ((mem "Mono" true) (mem "Tyvar" true) (mem "Scheme" true) (mem "IfaceRef" true) (mem "VecObl" true))))
(DUse false (UseGroup ("types" "effect_domain") ((mem "Param" true))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "EffRow" true) (mem "Effvar" true) (mem "Atom" true) (mem "EffLabel" true))))
(DUse false (UseGroup ("types" "effect_authority") ((mem "Authority" true) (mem "Authvar" true))))
(DUse false (UseGroup ("types" "publish") ((mem "PubScheme" true) (mem "VarKind" true) (mem "LiveCell" true) (mem "ppPubScheme" false) (mem "TcReport" true) (mem "CheckedProgram" true) (mem "EntryOutcome" true) (mem "PartialAnalysis" true) (mem "ModDiags" false) (mem "TcDiag" true))))
(DUse false (UseGroup ("types" "disposition") ((mem "MethodDisposition" true) (mem "dispositionRows" false) (mem "dispositionKey" false) (mem "dispositionInstance" false) (mem "dispositionMethod" false) (mem "dispositionIface" false))))
(DUse false (UseGroup ("types" "evidence_coverage") ((mem "EvShape" true))))
(DUse false (UseGroup ("types" "capability_manifest") ((mem "EntryKey" true) (mem "ManifestRequest" true) (mem "ManifestSelector" true) (mem "InvocationProtocol" true) (mem "ManifestLookup" true) (mem "FrozenAuthority" true))))
(DUse false (UseGroup ("types" "effect_invocation") ((mem "InvocationOps" true))))
(DTypeSig true "checkDiags" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "checkDiags" () (EApp (EVar "checkDiagsOver") (ELit (LString ""))))
(DTypeSig true "checkDiagsOver" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "checkDiagsOver" ((PVar "core") (PVar "src")) (EBlock (DoLet false false (PTuple (PVar "errors") PWild) (EApp (EApp (EApp (EApp (EVar "checkOneDiags") (EVar "defaultDriveInputs")) (EListLit)) (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "core")))) (ETuple (ELit (LString "probe")) (EApp (EVar "desugar") (EApp (EVar "parseLocated") (EVar "src")))))) (DoExpr (EApp (EApp (EMethodRef "map") (ELam ((PVar "d")) (ETuple (EApp (EVar "codeText") (EApp (EVar "tcCode") (EVar "d"))) (EApp (EVar "tcMsg") (EVar "d"))))) (EVar "errors")))))
(DTypeSig true "checkCodes" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "checkCodes" ((PVar "src")) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EApp (EVar "checkDiags") (EVar "src"))))
(DTypeSig true "expectChecks" (TyFun (TyCon "String") (TyCon "Expectation")))
(DFunDef false "expectChecks" ((PVar "src")) (EApp (EApp (EVar "expectEqual") (EListLit)) (EApp (EVar "checkCodes") (EVar "src"))))
(DTypeSig true "expectRejectedWith" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyCon "Expectation"))))
(DFunDef false "expectRejectedWith" ((PVar "expected") (PVar "src")) (EApp (EApp (EVar "expectEqual") (EVar "expected")) (EApp (EVar "checkCodes") (EVar "src"))))
(DTypeSig true "routeWordsOf" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "routeWordsOf" () (EApp (EVar "routeWordsOver") (ELit (LString ""))))
(DTypeSig true "routeWordsOver" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "routeWordsOver" ((PVar "core") (PVar "src")) (EBlock (DoLet false false (PVar "elab") (EApp (EApp (EApp (EApp (EVar "elaborateModules") (EVar "defaultDriveInputs")) (EListLit)) (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "core")))) (EListLit (ETuple (ELit (LString "probe")) (EApp (EVar "desugar") (EApp (EVar "parseLocated") (EVar "src"))))))) (DoExpr (EApp (EVar "sort") (EApp (EApp (EDictApp "flatMap") (EVar "evidenceWords")) (EFieldAccess (EVar "elab") "erEvidence"))))))
(DTypeSig false "evidenceWords" (TyFun (TyCon "EvEntry") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "evidenceWords" ((PCon "EvEntry" PWild (PVar "val"))) (EMatch (EVar "val") (arm (PCon "EvOne" (PVar "r")) () (EApp (EVar "routeWords") (EVar "r"))) (arm (PCon "EvMany" (PVar "rs")) () (EApp (EApp (EDictApp "flatMap") (EVar "routeWords")) (EVar "rs"))) (arm (PCon "EvMethod" PWild PWild (PVar "r") (PVar "pre") (PVar "post")) () (EBinOp "++" (EApp (EVar "routeWords") (EVar "r")) (EApp (EApp (EDictApp "flatMap") (EVar "routeWords")) (EBinOp "++" (EVar "pre") (EVar "post"))))) (arm (PCon "EvLit" PWild (PVar "r")) () (EApp (EVar "routeWords") (EVar "r"))) (arm (PCon "EvHead" PWild) () (EListLit))))
(DTypeSig false "routeWords" (TyFun (TyCon "Route") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "routeWords" ((PCon "RNone")) (EListLit))
(DFunDef false "routeWords" ((PCon "RKey" (PVar "word") (PVar "a") (PVar "b"))) (EBinOp "::" (EVar "word") (EApp (EApp (EDictApp "flatMap") (EVar "routeWords")) (EBinOp "++" (EVar "a") (EVar "b")))))
(DFunDef false "routeWords" ((PCon "RDict" (PVar "name"))) (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "dict:")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "")))))
(DFunDef false "routeWords" ((PCon "RDictFwd" (PVar "name"))) (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "dictfwd:")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "")))))
(DFunDef false "routeWords" ((PCon "RLocal" (PVar "name") (PVar "rs"))) (EBinOp "::" (EBinOp "++" (EBinOp "++" (ELit (LString "local:")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString ""))) (EApp (EApp (EDictApp "flatMap") (EVar "routeWords")) (EVar "rs"))))
(DFunDef false "routeWords" ((PCon "RScalar" (PVar "name"))) (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "scalar:")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "")))))
(DFunDef false "routeWords" ((PCon "RProj" (PVar "r") (PVar "_path"))) (EApp (EVar "routeWords") (EVar "r")))
(DTypeSig true "traced" (TyFun (TyCon "TraceSink") (TyCon "DriveInputs")))
(DFunDef false "traced" ((PVar "sink")) (ERecordUpdate (EVar "defaultDriveInputs") ((fa "diTrace" (EApp (EVar "Some") (EVar "sink"))))))
(DTypeSig true "numericPreludeSource" (TyCon "String"))
(DFunDef false "numericPreludeSource" () (EApp (EVar "joinNl") (EListLit (ELit (LString "interface Num a where")) (ELit (LString "  fromInt : Int -> a")) (ELit (LString "impl Num Int where")) (ELit (LString "  fromInt n = n")))))
(DTypeSig true "absentReturnSource" (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyCon "String"))))
(DFunDef false "absentReturnSource" ((PVar "reverseImpls") (PVar "ambient")) (EBlock (DoLet false false (PVar "charImpl") (EApp (EVar "joinNl") (EListLit (ELit (LString "impl Hidden Int Char where")) (ELit (LString "  hidden _ = 22"))))) (DoLet false false (PVar "boolImpl") (EApp (EVar "joinNl") (EListLit (ELit (LString "impl Hidden Int Bool where")) (ELit (LString "  hidden _ = 12"))))) (DoLet false false (PVar "impls") (EIf (EVar "reverseImpls") (EListLit (EVar "boolImpl") (EVar "charImpl")) (EListLit (EVar "charImpl") (EVar "boolImpl")))) (DoExpr (EApp (EVar "joinNl") (EBinOp "++" (EBinOp "++" (EListLit (ELit (LString "interface Hidden a b where")) (ELit (LString "  hidden : Unit -> a"))) (EVar "impls")) (EIf (EVar "ambient") (EListLit (ELit (LString "useHidden : Hidden a b => b -> a")) (ELit (LString "useHidden witness = hidden ()")) (ELit (LString "value : Int")) (ELit (LString "value = useHidden True : Int"))) (EListLit (ELit (LString "value : Int")) (ELit (LString "value = hidden ()")))))))))
(DTypeSig true "modErrorCount" (TyFun (TyApp (TyCon "List") (TyCon "ModDiags")) (TyCon "Int")))
(DFunDef false "modErrorCount" ((PList)) (ELit (LInt 0)))
(DFunDef false "modErrorCount" ((PCons (PTuple PWild (PTuple PWild (PVar "errors") PWild)) (PVar "rest"))) (EBinOp "+" (EApp (EVar "listLen") (EVar "errors")) (EApp (EVar "modErrorCount") (EVar "rest"))))
(DTypeSig true "evidenceEntriesOfKind" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "EvidenceObservationEntry")) (TyApp (TyCon "List") (TyCon "EvidenceObservationEntry")))))
(DFunDef false "evidenceEntriesOfKind" ((PVar "kind")) (EApp (EMethodRef "filter") (ELam ((PVar "e")) (EBinOp "==" (EFieldAccess (EVar "e") "eoeGoalKind") (EVar "kind")))))
(DTypeSig true "drive" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))))))
(DFunDef false "drive" ((PVar "mid") (PVar "src")) (EBlock (DoLet false false (PTuple PWild (PVar "own")) (EApp (EApp (EApp (EApp (EApp (EVar "checkOneSchemeFullK") (EVar "defaultDriveInputs")) (EVar "None")) (EListLit)) (EListLit)) (ETuple (EVar "mid") (EApp (EVar "desugar") (EApp (EVar "parseLocated") (EVar "src")))))) (DoExpr (EVar "own"))))
(DTypeSig true "rendered" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "PubScheme"))) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "rendered" ((PVar "ss")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "e")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "fst") (EVar "e")))) (ELit (LString " : "))) (EApp (EMethodRef "display") (EApp (EVar "ppPubScheme") (EApp (EVar "snd") (EVar "e"))))) (ELit (LString ""))))) (EVar "ss")))
(DTypeSig true "linkCount" (TyFun (TyCon "Scheme") (TyCon "Int")))
(DFunDef false "linkCount" ((PCon "Forall" PWild PWild PWild PWild PWild (PVar "t"))) (EApp (EVar "monoLinks") (EVar "t")))
(DTypeSig true "monoLinks" (TyFun (TyCon "Mono") (TyCon "Int")))
(DFunDef false "monoLinks" ((PCon "TVar" (PVar "cell"))) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "Link" (PVar "t2")) () (EBinOp "+" (ELit (LInt 1)) (EApp (EVar "monoLinks") (EVar "t2")))) (arm (PCon "Unbound" PWild PWild) () (ELit (LInt 0)))))
(DFunDef false "monoLinks" ((PCon "TApp" (PVar "a") (PVar "b"))) (EBinOp "+" (EApp (EVar "monoLinks") (EVar "a")) (EApp (EVar "monoLinks") (EVar "b"))))
(DFunDef false "monoLinks" ((PCon "TFun" (PVar "a") PWild (PVar "b"))) (EBinOp "+" (EApp (EVar "monoLinks") (EVar "a")) (EApp (EVar "monoLinks") (EVar "b"))))
(DFunDef false "monoLinks" ((PCon "TQual" (PVar "a") PWild)) (EApp (EVar "monoLinks") (EVar "a")))
(DFunDef false "monoLinks" (PWild) (ELit (LInt 0)))
(DTypeSig true "accRenderChecked" (TyFun (TyApp (TyCon "Option") (TyCon "CheckedProgram")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "accRenderChecked" ((PCon "None")) (EListLit (ELit (LString "withheld"))))
(DFunDef false "accRenderChecked" ((PCon "Some" (PVar "c"))) (EBlock (DoLet false false (PVar "ordered") (EApp (EApp (EVar "sortOn") (ELam ((PVar "e")) (EMatch (EVar "e") (arm (PCon "EvEntry" (PCon "EvId" (PVar "m") (PVar "i")) PWild) () (ETuple (EVar "m") (EVar "i")))))) (EFieldAccess (EVar "c") "cpEvidence"))) (DoExpr (EBinOp "::" (ELit (LString "checked")) (EBinOp "++" (EApp (EApp (EMethodRef "map") (ELam ((PVar "ie")) (EMatch (EVar "ie") (arm (PTuple (PVar "rank") (PCon "EvEntry" PWild (PVar "v"))) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "ev ")) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EVar "rank")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EVar "valText") (EVar "v")))) (ELit (LString ""))))))) (EApp (EVar "indexed") (EVar "ordered"))) (EApp (EApp (EMethodRef "map") (EVar "dispositionText")) (EApp (EVar "dispositionRows") (EFieldAccess (EVar "c") "cpDispositions"))))))))
(DTypeSig true "dispositionText" (TyFun (TyCon "MethodDisposition") (TyCon "String")))
(DFunDef false "dispositionText" ((PVar "d")) (EBlock (DoLet false false (PVar "kind") (EMatch (EVar "d") (arm (PRec "Supplied" () false) () (ELit (LString "supplied"))) (arm (PRec "InheritedDefault" () false) () (ELit (LString "inherited"))))) (DoLet false false (PVar "key") (EApp (EApp (EVar "dispositionKey") (EApp (EVar "dispositionInstance") (EVar "d"))) (EApp (EVar "dispositionMethod") (EVar "d")))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "disp ")) (EApp (EMethodRef "display") (EVar "kind"))) (ELit (LString " "))) (EApp (EMethodRef "display") (EFieldAccess (EApp (EVar "dispositionIface") (EVar "d")) "irName"))) (ELit (LString " "))) (EApp (EMethodRef "display") (EVar "key"))) (ELit (LString ""))))))
(DTypeSig true "routeText" (TyFun (TyCon "Route") (TyCon "String")))
(DFunDef false "routeText" ((PCon "RNone")) (ELit (LString "none")))
(DFunDef false "routeText" ((PCon "RKey" (PVar "w") (PVar "ds") (PVar "sups"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "key(")) (EApp (EMethodRef "display") (EVar "w"))) (ELit (LString ";"))) (EApp (EMethodRef "display") (EApp (EVar "routesText") (EVar "ds")))) (ELit (LString ";"))) (EApp (EMethodRef "display") (EApp (EVar "routesText") (EVar "sups")))) (ELit (LString ")"))))
(DFunDef false "routeText" ((PCon "RDict" (PVar "d"))) (EBinOp "++" (EBinOp "++" (ELit (LString "dict(")) (EApp (EMethodRef "display") (EVar "d"))) (ELit (LString ")"))))
(DFunDef false "routeText" ((PCon "RDictFwd" (PVar "d"))) (EBinOp "++" (EBinOp "++" (ELit (LString "fwd(")) (EApp (EMethodRef "display") (EVar "d"))) (ELit (LString ")"))))
(DFunDef false "routeText" ((PCon "RLocal" (PVar "s") (PVar "ds"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "local(")) (EApp (EMethodRef "display") (EVar "s"))) (ELit (LString ";"))) (EApp (EMethodRef "display") (EApp (EVar "routesText") (EVar "ds")))) (ELit (LString ")"))))
(DFunDef false "routeText" ((PCon "RScalar" (PVar "s"))) (EBinOp "++" (EBinOp "++" (ELit (LString "scalar(")) (EApp (EMethodRef "display") (EVar "s"))) (ELit (LString ")"))))
(DFunDef false "routeText" ((PCon "RProj" (PVar "r") (PVar "path"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "proj(")) (EApp (EMethodRef "display") (EApp (EVar "routeText") (EVar "r")))) (ELit (LString ";"))) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EVar "path")))) (ELit (LString ")"))))
(DTypeSig true "routesText" (TyFun (TyApp (TyCon "List") (TyCon "Route")) (TyCon "String")))
(DFunDef false "routesText" ((PVar "rs")) (EApp (EApp (EVar "join") (ELit (LString ","))) (EApp (EApp (EMethodRef "map") (EVar "routeText")) (EVar "rs"))))
(DTypeSig true "valText" (TyFun (TyCon "EvVal") (TyCon "String")))
(DFunDef false "valText" ((PCon "EvOne" (PVar "r"))) (EApp (EVar "routeText") (EVar "r")))
(DFunDef false "valText" ((PCon "EvMany" (PVar "rs"))) (EApp (EVar "routesText") (EVar "rs")))
(DFunDef false "valText" ((PCon "EvMethod" (PVar "iface") (PVar "arity") (PVar "r") (PVar "impls") (PVar "meths"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "iface"))) (ELit (LString "/"))) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EVar "arity")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EVar "routeText") (EVar "r")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EVar "routesText") (EVar "impls")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EVar "routesText") (EVar "meths")))) (ELit (LString ""))))
(DFunDef false "valText" ((PCon "EvLit" (PVar "f") (PVar "r"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EVar "f")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EVar "routeText") (EVar "r")))) (ELit (LString ""))))
(DFunDef false "valText" ((PCon "EvHead" (PVar "h"))) (EVar "h"))
