# META
source_lines=446
stages=DESUGAR,MARK
# SOURCE
-- tc_test_support: the fixtures the `tc_*_test` siblings of `compiler/types` share: a fresh
-- module record (`fresh`, and `scoped` inside a root scope), the codes and messages it has
-- been given, the signatures of a parsed source, the alias table and declared parameter kinds
-- a source's declarations register, the interface reference and the monos of the probe module
-- (`ifaceOf`, `intM`, `boolM`, `varM`), a hand-built pattern (`at`, `pvar`), the literal and
-- type name of a generated kind (`kindLit`, `kindName`, `genKinds`, `nthInt`, `unitKind`), the
-- triple projections (`fst3`, `snd3`), the reader of a module that declares an interface with
-- a live impl (`readerOfLib`), the environment of an importer shadow over it (`shadowEnvOf`),
-- a method occurrence of it (`methodOccurrence`), and the environment over the data and
-- record types a source declares (`scopedWith`, `envWithData`, `declareData`,
-- `recordShapes`).  Test siblings import it and no production module does.
-- It imports no module above `tc_decls`, so a sibling of a lower module cannot reach a higher
-- one through it; the fixtures that run a source through the mark pass and `infer`
-- (`mainOf`, `withMain`) live in `tc_infer_test`.
-- `aliasTableOf` and `recordKindsOf` are the fixture-side twins of `tc_decls`'
-- `graphAliasRow` and `withDeclParamKinds`: a test of a module below `tc_decls` cannot
-- import those, and its fixtures need the same tables.  `recordKindsOf` reads `tc_decls`'
-- own `kindIsDeclared`, so the registration test it serves cannot disagree with it.

import list.{drop, range, reverse, zip}
import test.{Expectation, expectEqual}
import frontend.parser.{parse}
import frontend.desugar.{desugar}
import frontend.exhaust.{buildOracle}
import frontend.ast.{
  Decl(..),
  EvId(..),
  Expr(..),
  Loc(..),
  Pat(..),
  Route(..),
  TabKey,
  Ty(..),
  TyConOrigin(..),
  noBinderId,
}
import types.effect_rows.{pureRow}
import types.repr.{IfaceRef(..), Mono(..), Scheme(..), Tyvar(..)}
import types.tc_mono.{tconBuiltin}
import support.ordmap.{omEmpty, omInsert}
import types.publish.{tcCode, tcMsg}
import types.tc_decls.{kindIsDeclared, registerData}
import types.tc_scope.{insertRecordPop}
import types.tc_env.{
  buildClassEnvGo,
  buildImplEnvGo,
  classEnvFinish,
  declEnvModule,
  declParamKinds,
  emptyDeclEnvAcc,
  bindingWithStandalone,
  envFor,
  extendBindings,
  implAccFinish,
  methodEnvGo,
  ordinaryEnvBinding,
  tyTabKey,
}
import types.scopes.{ScopeOwner(..), freshScope, openScopeCursor}
import types.tc_state.{
  blankModuleCtx,
  currentScopeStore,
  emptyClassEnv,
  freshModuleCtx,
  probeGraphCtx,
  wAll,
}
import types.evidence.{ScopeId(..)}
import types.evidence_complete.{innerNone}
import types.tc_types.{
  CheckRunSeed(..),
  EvCell(..),
  Kind(..),
  MarkCtx(..),
  ModuleCtx(..),
  ClassEnv,
  ImplEnv,
  ModuleMarking(..),
  OblProjection(..),
  Predicate(..),
  Provenance(..),
  StandaloneOrigin(..),
  TcEnv,
  UObligation(..),
  ValueScheme(..),
}

-- The tag a route carries, as text: a route has no `Show`, and the tests compare these.
export
routeTag : Route -> String
routeTag (RScalar tag) = "scalar:\{tag}"
routeTag RNone = "none"
routeTag (RDict d) = "dict:\{d}"
routeTag (RKey word _ _) = "key:\{word}"
routeTag _ = "other"

-- A source position and a variable pattern at it, for tests that build syntax by hand.
export
at : Loc
at = Loc "t.mdk" 1 1 1 1

export
pvar : String -> Pat
pvar name = PVar name at noBinderId

-- A module record named "probe", minted in a fresh graph record.
export
fresh : Unit -> ModuleCtx
fresh _ = blankModuleCtx (probeGraphCtx ()) "probe"

-- A module record named "probe" whose inference sits in the root scope of its own module, as
-- the checks that record where a use stands expect.
export
scoped : Unit -> ModuleCtx
scoped _ = inRootScope (fresh ())

-- [m], its inference placed in the root scope of its own module.
export
inRootScope : ModuleCtx -> ModuleCtx
inRootScope m =
  let root =
    freshScope (currentScopeStore m.mcGraph ()) None 0 "probe" ModuleOwner
  m.mcCells.currentScope := openScopeCursor root
  m

-- The codes of the diagnostics pushed to [m] so far, oldest first.
export
codesOf : ModuleCtx -> List String
codesOf m = reverse (map tcCode (wAll m.mcCells.typeErrors))

-- The messages of the diagnostics pushed to [m] so far, oldest first.
export
messagesOf : ModuleCtx -> List String
messagesOf m = reverse (map tcMsg (wAll m.mcCells.typeErrors))

-- The type of every signature among [ds], in source order.
export
sigsOf : List Decl -> List Ty
sigsOf [] = []
sigsOf ((DTypeSig _ _ t _) :: rest) = t :: sigsOf rest
sigsOf (_ :: rest) = sigsOf rest

-- The type of the first signature of [src], or `None` when it declares none.
export
firstSig : String -> Option Ty
firstSig src = match sigsOf (parse src)
  t :: _ => Some t
  [] => None

-- [k] applied to the type of the first signature of [src]; a source with no signature
-- fails the test rather than reading as some placeholder type.
export
withFirstSig : String -> (Ty -> Expectation) -> Expectation
withFirstSig src k = match firstSig src
  Some t => k t
  None => expectEqual "a source with a signature" src

export
intTy : Ty
intTy =
  TyCon { tyConName = "Int", tyConLoc = None, tyConOrigin = OriginBuiltin }

-- An interface reference named [name], declared in the module "probe".
export
ifaceOf : String -> IfaceRef
ifaceOf name = IfaceRef { irName = name, irOrigin = OriginModule "probe" }

export
intM : Mono
intM = tconBuiltin "Int"

export
boolM : Mono
boolM = tconBuiltin "Bool"

-- The first and second components of a triple.
export
fst3 : (a, b, c) -> a
fst3 (a, _, _) = a

export
snd3 : (a, b, c) -> b
snd3 (_, b, _) = b

-- A free type variable with id [id] at level 0.
export
varM : Int -> Mono
varM id = TVar (Ref (Unbound id 0))

-- The alias table of [ds]: each alias keyed by its identity, with its parameters and
-- right-hand side.
export
aliasTableOf : List Decl -> List (TabKey, (List String, Ty))
aliasTableOf [] = []
aliasTableOf ((DTypeAlias { tyAliasName = n, tyAliasParams = ps, tyAliasRhs = rhs, tyAliasOrigin = o }) :: rest) =
  (tyTabKey o n, (ps, rhs)) :: aliasTableOf rest
aliasTableOf (_ :: rest) = aliasTableOf rest

-- Records in [m] the parameter kinds each data, newtype or alias head of [ds] declares.
-- A head whose parameters are all of kind `Type` has no entry, as it has none at a real
-- registration.
export
recordKindsOf : ModuleCtx -> List Decl -> Unit
recordKindsOf _ [] = ()
recordKindsOf m ((DData { dataName = n, dataParams = ps, dataParamKinds = anns, dataOrigin = o }) :: rest) =
  recordKinds m o n (declParamKinds m.mcGraph ps anns)
  recordKindsOf m rest
recordKindsOf m ((DNewtype { newtypeName = n, newtypeParams = ps, newtypeParamKinds = anns, newtypeOrigin = o }) :: rest) =
  recordKinds m o n (declParamKinds m.mcGraph ps anns)
  recordKindsOf m rest
recordKindsOf m ((DTypeAlias { tyAliasName = n, tyAliasParams = ps, tyAliasParamKinds = anns, tyAliasOrigin = o }) :: rest) =
  recordKinds m o n (declParamKinds m.mcGraph ps anns)
  recordKindsOf m rest
recordKindsOf m (_ :: rest) = recordKindsOf m rest

recordKinds : ModuleCtx -> TyConOrigin -> String -> List Kind -> Unit
recordKinds m o n kinds
  | any kindIsDeclared kinds =
    m.mcCells.dataParamKindsRef :=
      (tyTabKey o n, kinds) :: m.mcCells.dataParamKindsRef.value
    m.mcCells.dataParamNameIndexRef :=
      omInsert n () m.mcCells.dataParamNameIndexRef.value
  | otherwise = ()

-- A module declaring `Sizeable` with its method `size`, and `impl Sizeable Int`.
export
libSource : String
libSource =
  """
interface Sizeable a where
  size : a -> Int
impl Sizeable Int where
  size n = n
"""

-- The declarations of [ds] stamped as declared in the module [mid]: each interface, its supers
-- and each impl.
export
declaredIn : String -> List Decl -> List Decl
declaredIn mid ds = map (declaredAs mid) ds

declaredAs : String -> Decl -> Decl
declaredAs mid (d@(DInterface { supers = ss, ... })) = DInterface { d |
  ifaceOrigin = OriginModule mid,
  supers = map (sup => { sup | superOrigin = OriginModule mid }) ss,
}
declaredAs mid (d@(DImpl { implOrigin = _ })) =
  DImpl { d | implOrigin = OriginModule mid }
declaredAs _ d = d

-- The reader `user` (ordinal 2) of the module `lib` (ordinal 1), which declares `Sizeable`
-- and `impl Sizeable Int`.  The graph's method environment and the reader's impl
-- environment are built the way `checkBodyImpl` installs them, so `size` is the one
-- visible method and a live impl answers at `Int`.
export
readerOfLib : Unit -> ModuleCtx
readerOfLib _ =
  let g = probeGraphCtx ()
  let lib = declEnvModule g 1 "lib" (declaredIn "lib" (parse libSource))
  let user = declEnvModule g 2 "user" []
  let empty = g.declEnvsRef.value
  g.declEnvsRef := { empty |
    deMethods = methodEnvGo g [lib, user] empty.deMethods,
  }
  let m = blankModuleCtx g "user"
  m.mcCells.methodScopeCtxRef := Some ([], 2)
  m.mcCells.bodyImplEnvRef :=
    implAccFinish (buildImplEnvGo [lib, user] emptyDeclEnvAcc.daImpls)
  m

-- A module record named "probe" in a fresh graph, in its root scope, whose constructor oracle
-- knows the data [src] declares; `envWithData` registers the same source's types.
export
scopedWith : String -> ModuleCtx
scopedWith src =
  let seed = CheckRunSeed {
    crsOracle = buildOracle (map (declaredAsData "m") (parse src)),
    crsWarnings = [],
  }
  inRootScope (freshModuleCtx (probeGraphCtx ()) seed "probe")

-- An environment over [m] that knows the data and record types [src] declares, as the module
-- "m" declares them.
export
envWithData : ModuleCtx -> String -> TcEnv
envWithData m src = declareData "m" m (envFor m) src

-- [env] extended with the data and record types [src] declares as the module [mid] declares
-- them: the constructors and record rows, the field-owner table and the cross-module record
-- population.  The constructor oracle a match is checked against is minted with the module
-- record (`scopedWith`).
export
declareData : String -> ModuleCtx -> TcEnv -> String -> TcEnv
declareData mid m env src =
  let ds = map (declaredAsData mid) (parse src)
  let registered = fold registerData env ds
  m.mcGraph.crossRun.universeRecordPop :=
    insertRecordPop m ds m.mcGraph.crossRun.universeRecordPop.value
  registered

declaredAsData : String -> Decl -> Decl
declaredAsData mid (d@(DData { dataOrigin = _ })) =
  DData { d | dataOrigin = OriginModule mid }
declaredAsData _ d = d

-- The record declarations the record tests of `tc_infer_records` and `tc_infer` name.
export
recordShapes : String
recordShapes =
  """
data P = P { a : Int, b : Bool }
data Box t = Box { v : t }
data Pair x y = Pair { first : x, second : y }
data Cfg = Cfg { name : String, count : Int }
"""

-- The name of the type of a generated value of kind [k]: a Char, a Bool, a String or a Unit.
export
kindName : Int -> String
kindName 0 = "Char"
kindName 1 = "Bool"
kindName 2 = "String"
kindName _ = "Unit"

-- A literal of kind [k], as source.
export
kindLit : Int -> String
kindLit 0 = "'c'"
kindLit 1 = "True"
kindLit 2 = "\"s\""
kindLit _ = "()"

-- [n] generated kinds, each of the four.
export
genKinds : Int -> <Rand> List Int
genKinds n
  | n <= 0 = []
  | otherwise = randomInt 0 unitKind :: genKinds (n - 1)

-- The generated kind whose literal is `()` and whose type is Unit.
export
unitKind : Int
unitKind = 3

-- The element of [xs] at index [i]; the Unit kind beyond the end.
export
nthInt : Int -> List Int -> Int
nthInt i xs = match drop i xs
  x :: _ => x
  [] => unitKind

-- [m]'s environment with `size` bound as the interface method, of scheme [method], and also
-- as a standalone value of scheme [standalone] imported from another module, which is what
-- makes `size` an importer shadow in a reader of a module that declares a method of that name.
export
shadowEnvOf : Scheme -> Scheme -> ModuleCtx -> TcEnv
shadowEnvOf method standalone m =
  m.mcCells.standaloneValuesRef := omInsert "size" () omEmpty
  extendBindings (envFor m) [
    (
      "size",
      bindingWithStandalone (ordinaryEnvBinding method) (
        ImportedStandalone,
        ValueScheme { vsScheme = standalone, vsDeclared = None },
      ),
    ),
  ]

-- A method occurrence of `name` whose evidence cell the module [m] holds at ordinal 0.
export
methodOccurrence : ModuleCtx -> String -> Expr
methodOccurrence m name =
  let ev = EvId "probe" 0
  let cell = EvCell {
    ecId = ev,
    ecIface = Ref "",
    ecArity = Ref None,
    ecTag = Ref RNone,
    ecImpl = Ref [],
    ecMeth = Ref [],
    ecLoc = Ref None,
    ecName = Ref "",
    ecInner = Ref innerNone,
  }
  m.mcGraph.graphRun.evCells := arrayMake 1 (Some cell)
  EMethodAt name "" ev

-- The scheme of `size : a -> Int`, quantified over scheme id 1.
export
sizeScheme : Scheme
sizeScheme = Forall [1] [] [] [] pureRow (TFun (varM 1) pureRow intM)

-- The declarations of [src] as the module "m" declares them: desugared, as the checks over a
-- whole module read them, with each interface and impl stamped as declared in "m".
export
moduleDecls : String -> List Decl
moduleDecls src = declsOf "m" src

-- The declarations of [src], desugared, with each interface and impl stamped as declared in the
-- module [origin]: an impl of another module's interface carries that module's identity.
export
declsOf : String -> String -> List Decl
declsOf origin src = declaredIn origin (desugar (parse src))

-- The ordinal of the first user module in the tables `envsOf` builds.  Ordinal 0 is the
-- prelude's, which the coherence sweep never checks against itself.
export
moduleOrdinal : Int
moduleOrdinal = 1

-- The class table and the impl table of [ds], the declarations of the module "m" at ordinal
-- `moduleOrdinal`, built in the graph of [m].
export
envsOf : ModuleCtx -> List Decl -> (ClassEnv, ImplEnv)
envsOf m ds = envsOfModules m [("m", ds)]

-- The same over several modules, the first at ordinal `moduleOrdinal` and each next one after it.
export
envsOfModules : ModuleCtx -> List (String, List Decl) -> (ClassEnv, ImplEnv)
envsOfModules m modules =
  let dms =
    map
      (p =>
        declEnvModule
          m.mcGraph
          (moduleOrdinal + fst p)
          (fst (snd p))
          (snd (snd p)))
      (zip (range 0 (length modules)) modules)
  (
    classEnvFinish (buildClassEnvGo m.mcGraph dms emptyClassEnv),
    implAccFinish (buildImplEnvGo dms emptyDeclEnvAcc.daImpls),
  )

-- An obligation of the interface [iface] over the argument monos [args], carried as the
-- arguments it was built over.
export
oblOver : IfaceRef -> List Mono -> UObligation
oblOver iface args = UObligation {
  pred = Predicate { iface = iface, args = args },
  originId = 0,
  prov = PNumLit,
  loc = None,
  uoScope = ScopeId 0,
  oblProj = OpProjected,
}
# DESUGAR
(DUse false (UseGroup ("list") ((mem "drop" false) (mem "range" false) (mem "reverse" false) (mem "zip" false))))
(DUse false (UseGroup ("test") ((mem "Expectation" false) (mem "expectEqual" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "parse" false))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "desugar" false))))
(DUse false (UseGroup ("frontend" "exhaust") ((mem "buildOracle" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "EvId" true) (mem "Expr" true) (mem "Loc" true) (mem "Pat" true) (mem "Route" true) (mem "TabKey" false) (mem "Ty" true) (mem "TyConOrigin" true) (mem "noBinderId" false))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "pureRow" false))))
(DUse false (UseGroup ("types" "repr") ((mem "IfaceRef" true) (mem "Mono" true) (mem "Scheme" true) (mem "Tyvar" true))))
(DUse false (UseGroup ("types" "tc_mono") ((mem "tconBuiltin" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "omEmpty" false) (mem "omInsert" false))))
(DUse false (UseGroup ("types" "publish") ((mem "tcCode" false) (mem "tcMsg" false))))
(DUse false (UseGroup ("types" "tc_decls") ((mem "kindIsDeclared" false) (mem "registerData" false))))
(DUse false (UseGroup ("types" "tc_scope") ((mem "insertRecordPop" false))))
(DUse false (UseGroup ("types" "tc_env") ((mem "buildClassEnvGo" false) (mem "buildImplEnvGo" false) (mem "classEnvFinish" false) (mem "declEnvModule" false) (mem "declParamKinds" false) (mem "emptyDeclEnvAcc" false) (mem "bindingWithStandalone" false) (mem "envFor" false) (mem "extendBindings" false) (mem "implAccFinish" false) (mem "methodEnvGo" false) (mem "ordinaryEnvBinding" false) (mem "tyTabKey" false))))
(DUse false (UseGroup ("types" "scopes") ((mem "ScopeOwner" true) (mem "freshScope" false) (mem "openScopeCursor" false))))
(DUse false (UseGroup ("types" "tc_state") ((mem "blankModuleCtx" false) (mem "currentScopeStore" false) (mem "emptyClassEnv" false) (mem "freshModuleCtx" false) (mem "probeGraphCtx" false) (mem "wAll" false))))
(DUse false (UseGroup ("types" "evidence") ((mem "ScopeId" true))))
(DUse false (UseGroup ("types" "evidence_complete") ((mem "innerNone" false))))
(DUse false (UseGroup ("types" "tc_types") ((mem "CheckRunSeed" true) (mem "EvCell" true) (mem "Kind" true) (mem "MarkCtx" true) (mem "ModuleCtx" true) (mem "ClassEnv" false) (mem "ImplEnv" false) (mem "ModuleMarking" true) (mem "OblProjection" true) (mem "Predicate" true) (mem "Provenance" true) (mem "StandaloneOrigin" true) (mem "TcEnv" false) (mem "UObligation" true) (mem "ValueScheme" true))))
(DTypeSig true "routeTag" (TyFun (TyCon "Route") (TyCon "String")))
(DFunDef false "routeTag" ((PCon "RScalar" (PVar "tag"))) (EBinOp "++" (EBinOp "++" (ELit (LString "scalar:")) (EApp (EVar "display") (EVar "tag"))) (ELit (LString ""))))
(DFunDef false "routeTag" ((PCon "RNone")) (ELit (LString "none")))
(DFunDef false "routeTag" ((PCon "RDict" (PVar "d"))) (EBinOp "++" (EBinOp "++" (ELit (LString "dict:")) (EApp (EVar "display") (EVar "d"))) (ELit (LString ""))))
(DFunDef false "routeTag" ((PCon "RKey" (PVar "word") PWild PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "key:")) (EApp (EVar "display") (EVar "word"))) (ELit (LString ""))))
(DFunDef false "routeTag" (PWild) (ELit (LString "other")))
(DTypeSig true "at" (TyCon "Loc"))
(DFunDef false "at" () (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString "t.mdk"))) (ELit (LInt 1))) (ELit (LInt 1))) (ELit (LInt 1))) (ELit (LInt 1))))
(DTypeSig true "pvar" (TyFun (TyCon "String") (TyCon "Pat")))
(DFunDef false "pvar" ((PVar "name")) (EApp (EApp (EApp (EVar "PVar") (EVar "name")) (EVar "at")) (EVar "noBinderId")))
(DTypeSig true "fresh" (TyFun (TyCon "Unit") (TyCon "ModuleCtx")))
(DFunDef false "fresh" (PWild) (EApp (EApp (EVar "blankModuleCtx") (EApp (EVar "probeGraphCtx") (ELit LUnit))) (ELit (LString "probe"))))
(DTypeSig true "scoped" (TyFun (TyCon "Unit") (TyCon "ModuleCtx")))
(DFunDef false "scoped" (PWild) (EApp (EVar "inRootScope") (EApp (EVar "fresh") (ELit LUnit))))
(DTypeSig true "inRootScope" (TyFun (TyCon "ModuleCtx") (TyCon "ModuleCtx")))
(DFunDef false "inRootScope" ((PVar "m")) (EBlock (DoLet false false (PVar "root") (EApp (EApp (EApp (EApp (EApp (EVar "freshScope") (EApp (EApp (EVar "currentScopeStore") (EFieldAccess (EVar "m") "mcGraph")) (ELit LUnit))) (EVar "None")) (ELit (LInt 0))) (ELit (LString "probe"))) (EVar "ModuleOwner"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "m") "mcCells") "currentScope")) (EApp (EVar "openScopeCursor") (EVar "root")))) (DoExpr (EVar "m"))))
(DTypeSig true "codesOf" (TyFun (TyCon "ModuleCtx") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "codesOf" ((PVar "m")) (EApp (EVar "reverse") (EApp (EApp (EVar "map") (EVar "tcCode")) (EApp (EVar "wAll") (EFieldAccess (EFieldAccess (EVar "m") "mcCells") "typeErrors")))))
(DTypeSig true "messagesOf" (TyFun (TyCon "ModuleCtx") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "messagesOf" ((PVar "m")) (EApp (EVar "reverse") (EApp (EApp (EVar "map") (EVar "tcMsg")) (EApp (EVar "wAll") (EFieldAccess (EFieldAccess (EVar "m") "mcCells") "typeErrors")))))
(DTypeSig true "sigsOf" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Ty"))))
(DFunDef false "sigsOf" ((PList)) (EListLit))
(DFunDef false "sigsOf" ((PCons (PCon "DTypeSig" PWild PWild (PVar "t") PWild) (PVar "rest"))) (EBinOp "::" (EVar "t") (EApp (EVar "sigsOf") (EVar "rest"))))
(DFunDef false "sigsOf" ((PCons PWild (PVar "rest"))) (EApp (EVar "sigsOf") (EVar "rest")))
(DTypeSig true "firstSig" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Ty"))))
(DFunDef false "firstSig" ((PVar "src")) (EMatch (EApp (EVar "sigsOf") (EApp (EVar "parse") (EVar "src"))) (arm (PCons (PVar "t") PWild) () (EApp (EVar "Some") (EVar "t"))) (arm (PList) () (EVar "None"))))
(DTypeSig true "withFirstSig" (TyFun (TyCon "String") (TyFun (TyFun (TyCon "Ty") (TyCon "Expectation")) (TyCon "Expectation"))))
(DFunDef false "withFirstSig" ((PVar "src") (PVar "k")) (EMatch (EApp (EVar "firstSig") (EVar "src")) (arm (PCon "Some" (PVar "t")) () (EApp (EVar "k") (EVar "t"))) (arm (PCon "None") () (EApp (EApp (EVar "expectEqual") (ELit (LString "a source with a signature"))) (EVar "src")))))
(DTypeSig true "intTy" (TyCon "Ty"))
(DFunDef false "intTy" () (ERecordCreate "TyCon" ((fa "tyConName" (ELit (LString "Int"))) (fa "tyConLoc" (EVar "None")) (fa "tyConOrigin" (EVar "OriginBuiltin")))))
(DTypeSig true "ifaceOf" (TyFun (TyCon "String") (TyCon "IfaceRef")))
(DFunDef false "ifaceOf" ((PVar "name")) (ERecordCreate "IfaceRef" ((fa "irName" (EVar "name")) (fa "irOrigin" (EApp (EVar "OriginModule") (ELit (LString "probe")))))))
(DTypeSig true "intM" (TyCon "Mono"))
(DFunDef false "intM" () (EApp (EVar "tconBuiltin") (ELit (LString "Int"))))
(DTypeSig true "boolM" (TyCon "Mono"))
(DFunDef false "boolM" () (EApp (EVar "tconBuiltin") (ELit (LString "Bool"))))
(DTypeSig true "fst3" (TyFun (TyTuple (TyVar "a") (TyVar "b") (TyVar "c")) (TyVar "a")))
(DFunDef false "fst3" ((PTuple (PVar "a") PWild PWild)) (EVar "a"))
(DTypeSig true "snd3" (TyFun (TyTuple (TyVar "a") (TyVar "b") (TyVar "c")) (TyVar "b")))
(DFunDef false "snd3" ((PTuple PWild (PVar "b") PWild)) (EVar "b"))
(DTypeSig true "varM" (TyFun (TyCon "Int") (TyCon "Mono")))
(DFunDef false "varM" ((PVar "id")) (EApp (EVar "TVar") (EApp (EVar "Ref") (EApp (EApp (EVar "Unbound") (EVar "id")) (ELit (LInt 0))))))
(DTypeSig true "aliasTableOf" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Ty"))))))
(DFunDef false "aliasTableOf" ((PList)) (EListLit))
(DFunDef false "aliasTableOf" ((PCons (PRec "DTypeAlias" ((rf "tyAliasName" (PVar "n")) (rf "tyAliasParams" (PVar "ps")) (rf "tyAliasRhs" (PVar "rhs")) (rf "tyAliasOrigin" (PVar "o"))) false) (PVar "rest"))) (EBinOp "::" (ETuple (EApp (EApp (EVar "tyTabKey") (EVar "o")) (EVar "n")) (ETuple (EVar "ps") (EVar "rhs"))) (EApp (EVar "aliasTableOf") (EVar "rest"))))
(DFunDef false "aliasTableOf" ((PCons PWild (PVar "rest"))) (EApp (EVar "aliasTableOf") (EVar "rest")))
(DTypeSig true "recordKindsOf" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Unit"))))
(DFunDef false "recordKindsOf" (PWild (PList)) (ELit LUnit))
(DFunDef false "recordKindsOf" ((PVar "m") (PCons (PRec "DData" ((rf "dataName" (PVar "n")) (rf "dataParams" (PVar "ps")) (rf "dataParamKinds" (PVar "anns")) (rf "dataOrigin" (PVar "o"))) false) (PVar "rest"))) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EVar "recordKinds") (EVar "m")) (EVar "o")) (EVar "n")) (EApp (EApp (EApp (EVar "declParamKinds") (EFieldAccess (EVar "m") "mcGraph")) (EVar "ps")) (EVar "anns")))) (DoExpr (EApp (EApp (EVar "recordKindsOf") (EVar "m")) (EVar "rest")))))
(DFunDef false "recordKindsOf" ((PVar "m") (PCons (PRec "DNewtype" ((rf "newtypeName" (PVar "n")) (rf "newtypeParams" (PVar "ps")) (rf "newtypeParamKinds" (PVar "anns")) (rf "newtypeOrigin" (PVar "o"))) false) (PVar "rest"))) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EVar "recordKinds") (EVar "m")) (EVar "o")) (EVar "n")) (EApp (EApp (EApp (EVar "declParamKinds") (EFieldAccess (EVar "m") "mcGraph")) (EVar "ps")) (EVar "anns")))) (DoExpr (EApp (EApp (EVar "recordKindsOf") (EVar "m")) (EVar "rest")))))
(DFunDef false "recordKindsOf" ((PVar "m") (PCons (PRec "DTypeAlias" ((rf "tyAliasName" (PVar "n")) (rf "tyAliasParams" (PVar "ps")) (rf "tyAliasParamKinds" (PVar "anns")) (rf "tyAliasOrigin" (PVar "o"))) false) (PVar "rest"))) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EVar "recordKinds") (EVar "m")) (EVar "o")) (EVar "n")) (EApp (EApp (EApp (EVar "declParamKinds") (EFieldAccess (EVar "m") "mcGraph")) (EVar "ps")) (EVar "anns")))) (DoExpr (EApp (EApp (EVar "recordKindsOf") (EVar "m")) (EVar "rest")))))
(DFunDef false "recordKindsOf" ((PVar "m") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "recordKindsOf") (EVar "m")) (EVar "rest")))
(DTypeSig false "recordKinds" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "TyConOrigin") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Kind")) (TyCon "Unit"))))))
(DFunDef false "recordKinds" ((PVar "m") (PVar "o") (PVar "n") (PVar "kinds")) (EIf (EApp (EApp (EVar "any") (EVar "kindIsDeclared")) (EVar "kinds")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "m") "mcCells") "dataParamKindsRef")) (EBinOp "::" (ETuple (EApp (EApp (EVar "tyTabKey") (EVar "o")) (EVar "n")) (EVar "kinds")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "m") "mcCells") "dataParamKindsRef") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "m") "mcCells") "dataParamNameIndexRef")) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (ELit LUnit)) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "m") "mcCells") "dataParamNameIndexRef") "value"))))) (EIf (EVar "otherwise") (ELit LUnit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "libSource" (TyCon "String"))
(DFunDef false "libSource" () (ELit (LString "interface Sizeable a where\n  size : a -> Int\nimpl Sizeable Int where\n  size n = n\n")))
(DTypeSig true "declaredIn" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "declaredIn" ((PVar "mid") (PVar "ds")) (EApp (EApp (EVar "map") (EApp (EVar "declaredAs") (EVar "mid"))) (EVar "ds")))
(DTypeSig false "declaredAs" (TyFun (TyCon "String") (TyFun (TyCon "Decl") (TyCon "Decl"))))
(DFunDef false "declaredAs" ((PVar "mid") (PAs "d" (PRec "DInterface" ((rf "supers" (PVar "ss"))) true))) (EVariantUpdate "DInterface" (EVar "d") ((fa "ifaceOrigin" (EApp (EVar "OriginModule") (EVar "mid"))) (fa "supers" (EApp (EApp (EVar "map") (ELam ((PVar "sup")) (ERecordUpdate (EVar "sup") ((fa "superOrigin" (EApp (EVar "OriginModule") (EVar "mid"))))))) (EVar "ss"))))))
(DFunDef false "declaredAs" ((PVar "mid") (PAs "d" (PRec "DImpl" ((rf "implOrigin" PWild)) false))) (EVariantUpdate "DImpl" (EVar "d") ((fa "implOrigin" (EApp (EVar "OriginModule") (EVar "mid"))))))
(DFunDef false "declaredAs" (PWild (PVar "d")) (EVar "d"))
(DTypeSig true "readerOfLib" (TyFun (TyCon "Unit") (TyCon "ModuleCtx")))
(DFunDef false "readerOfLib" (PWild) (EBlock (DoLet false false (PVar "g") (EApp (EVar "probeGraphCtx") (ELit LUnit))) (DoLet false false (PVar "lib") (EApp (EApp (EApp (EApp (EVar "declEnvModule") (EVar "g")) (ELit (LInt 1))) (ELit (LString "lib"))) (EApp (EApp (EVar "declaredIn") (ELit (LString "lib"))) (EApp (EVar "parse") (EVar "libSource"))))) (DoLet false false (PVar "user") (EApp (EApp (EApp (EApp (EVar "declEnvModule") (EVar "g")) (ELit (LInt 2))) (ELit (LString "user"))) (EListLit))) (DoLet false false (PVar "empty") (EFieldAccess (EFieldAccess (EVar "g") "declEnvsRef") "value")) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "g") "declEnvsRef")) (ERecordUpdate (EVar "empty") ((fa "deMethods" (EApp (EApp (EApp (EVar "methodEnvGo") (EVar "g")) (EListLit (EVar "lib") (EVar "user"))) (EFieldAccess (EVar "empty") "deMethods"))))))) (DoLet false false (PVar "m") (EApp (EApp (EVar "blankModuleCtx") (EVar "g")) (ELit (LString "user")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "m") "mcCells") "methodScopeCtxRef")) (EApp (EVar "Some") (ETuple (EListLit) (ELit (LInt 2)))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "m") "mcCells") "bodyImplEnvRef")) (EApp (EVar "implAccFinish") (EApp (EApp (EVar "buildImplEnvGo") (EListLit (EVar "lib") (EVar "user"))) (EFieldAccess (EVar "emptyDeclEnvAcc") "daImpls"))))) (DoExpr (EVar "m"))))
(DTypeSig true "scopedWith" (TyFun (TyCon "String") (TyCon "ModuleCtx")))
(DFunDef false "scopedWith" ((PVar "src")) (EBlock (DoLet false false (PVar "seed") (ERecordCreate "CheckRunSeed" ((fa "crsOracle" (EApp (EVar "buildOracle") (EApp (EApp (EVar "map") (EApp (EVar "declaredAsData") (ELit (LString "m")))) (EApp (EVar "parse") (EVar "src"))))) (fa "crsWarnings" (EListLit))))) (DoExpr (EApp (EVar "inRootScope") (EApp (EApp (EApp (EVar "freshModuleCtx") (EApp (EVar "probeGraphCtx") (ELit LUnit))) (EVar "seed")) (ELit (LString "probe")))))))
(DTypeSig true "envWithData" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyCon "TcEnv"))))
(DFunDef false "envWithData" ((PVar "m") (PVar "src")) (EApp (EApp (EApp (EApp (EVar "declareData") (ELit (LString "m"))) (EVar "m")) (EApp (EVar "envFor") (EVar "m"))) (EVar "src")))
(DTypeSig true "declareData" (TyFun (TyCon "String") (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyCon "TcEnv"))))))
(DFunDef false "declareData" ((PVar "mid") (PVar "m") (PVar "env") (PVar "src")) (EBlock (DoLet false false (PVar "ds") (EApp (EApp (EVar "map") (EApp (EVar "declaredAsData") (EVar "mid"))) (EApp (EVar "parse") (EVar "src")))) (DoLet false false (PVar "registered") (EApp (EApp (EApp (EVar "fold") (EVar "registerData")) (EVar "env")) (EVar "ds"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "m") "mcGraph") "crossRun") "universeRecordPop")) (EApp (EApp (EApp (EVar "insertRecordPop") (EVar "m")) (EVar "ds")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "m") "mcGraph") "crossRun") "universeRecordPop") "value")))) (DoExpr (EVar "registered"))))
(DTypeSig false "declaredAsData" (TyFun (TyCon "String") (TyFun (TyCon "Decl") (TyCon "Decl"))))
(DFunDef false "declaredAsData" ((PVar "mid") (PAs "d" (PRec "DData" ((rf "dataOrigin" PWild)) false))) (EVariantUpdate "DData" (EVar "d") ((fa "dataOrigin" (EApp (EVar "OriginModule") (EVar "mid"))))))
(DFunDef false "declaredAsData" (PWild (PVar "d")) (EVar "d"))
(DTypeSig true "recordShapes" (TyCon "String"))
(DFunDef false "recordShapes" () (ELit (LString "data P = P { a : Int, b : Bool }\ndata Box t = Box { v : t }\ndata Pair x y = Pair { first : x, second : y }\ndata Cfg = Cfg { name : String, count : Int }\n")))
(DTypeSig true "kindName" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "kindName" ((PLit (LInt 0))) (ELit (LString "Char")))
(DFunDef false "kindName" ((PLit (LInt 1))) (ELit (LString "Bool")))
(DFunDef false "kindName" ((PLit (LInt 2))) (ELit (LString "String")))
(DFunDef false "kindName" (PWild) (ELit (LString "Unit")))
(DTypeSig true "kindLit" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "kindLit" ((PLit (LInt 0))) (ELit (LString "'c'")))
(DFunDef false "kindLit" ((PLit (LInt 1))) (ELit (LString "True")))
(DFunDef false "kindLit" ((PLit (LInt 2))) (ELit (LString "\"s\"")))
(DFunDef false "kindLit" (PWild) (ELit (LString "()")))
(DTypeSig true "genKinds" (TyFun (TyCon "Int") (TyEffect ("Rand") None (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "genKinds" ((PVar "n")) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (EListLit) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EApp (EVar "randomInt") (ELit (LInt 0))) (EVar "unitKind")) (EApp (EVar "genKinds") (EBinOp "-" (EVar "n") (ELit (LInt 1))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "unitKind" (TyCon "Int"))
(DFunDef false "unitKind" () (ELit (LInt 3)))
(DTypeSig true "nthInt" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Int"))))
(DFunDef false "nthInt" ((PVar "i") (PVar "xs")) (EMatch (EApp (EApp (EVar "drop") (EVar "i")) (EVar "xs")) (arm (PCons (PVar "x") PWild) () (EVar "x")) (arm (PList) () (EVar "unitKind"))))
(DTypeSig true "shadowEnvOf" (TyFun (TyCon "Scheme") (TyFun (TyCon "Scheme") (TyFun (TyCon "ModuleCtx") (TyCon "TcEnv")))))
(DFunDef false "shadowEnvOf" ((PVar "method") (PVar "standalone") (PVar "m")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "m") "mcCells") "standaloneValuesRef")) (EApp (EApp (EApp (EVar "omInsert") (ELit (LString "size"))) (ELit LUnit)) (EVar "omEmpty")))) (DoExpr (EApp (EApp (EVar "extendBindings") (EApp (EVar "envFor") (EVar "m"))) (EListLit (ETuple (ELit (LString "size")) (EApp (EApp (EVar "bindingWithStandalone") (EApp (EVar "ordinaryEnvBinding") (EVar "method"))) (ETuple (EVar "ImportedStandalone") (ERecordCreate "ValueScheme" ((fa "vsScheme" (EVar "standalone")) (fa "vsDeclared" (EVar "None"))))))))))))
(DTypeSig true "methodOccurrence" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyCon "Expr"))))
(DFunDef false "methodOccurrence" ((PVar "m") (PVar "name")) (EBlock (DoLet false false (PVar "ev") (EApp (EApp (EVar "EvId") (ELit (LString "probe"))) (ELit (LInt 0)))) (DoLet false false (PVar "cell") (ERecordCreate "EvCell" ((fa "ecId" (EVar "ev")) (fa "ecIface" (EApp (EVar "Ref") (ELit (LString "")))) (fa "ecArity" (EApp (EVar "Ref") (EVar "None"))) (fa "ecTag" (EApp (EVar "Ref") (EVar "RNone"))) (fa "ecImpl" (EApp (EVar "Ref") (EListLit))) (fa "ecMeth" (EApp (EVar "Ref") (EListLit))) (fa "ecLoc" (EApp (EVar "Ref") (EVar "None"))) (fa "ecName" (EApp (EVar "Ref") (ELit (LString "")))) (fa "ecInner" (EApp (EVar "Ref") (EVar "innerNone")))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "m") "mcGraph") "graphRun") "evCells")) (EApp (EApp (EVar "arrayMake") (ELit (LInt 1))) (EApp (EVar "Some") (EVar "cell"))))) (DoExpr (EApp (EApp (EApp (EVar "EMethodAt") (EVar "name")) (ELit (LString ""))) (EVar "ev")))))
(DTypeSig true "sizeScheme" (TyCon "Scheme"))
(DFunDef false "sizeScheme" () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Forall") (EListLit (ELit (LInt 1)))) (EListLit)) (EListLit)) (EListLit)) (EVar "pureRow")) (EApp (EApp (EApp (EVar "TFun") (EApp (EVar "varM") (ELit (LInt 1)))) (EVar "pureRow")) (EVar "intM"))))
(DTypeSig true "moduleDecls" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "moduleDecls" ((PVar "src")) (EApp (EApp (EVar "declsOf") (ELit (LString "m"))) (EVar "src")))
(DTypeSig true "declsOf" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "declsOf" ((PVar "origin") (PVar "src")) (EApp (EApp (EVar "declaredIn") (EVar "origin")) (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "src")))))
(DTypeSig true "moduleOrdinal" (TyCon "Int"))
(DFunDef false "moduleOrdinal" () (ELit (LInt 1)))
(DTypeSig true "envsOf" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyTuple (TyCon "ClassEnv") (TyCon "ImplEnv")))))
(DFunDef false "envsOf" ((PVar "m") (PVar "ds")) (EApp (EApp (EVar "envsOfModules") (EVar "m")) (EListLit (ETuple (ELit (LString "m")) (EVar "ds")))))
(DTypeSig true "envsOfModules" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyTuple (TyCon "ClassEnv") (TyCon "ImplEnv")))))
(DFunDef false "envsOfModules" ((PVar "m") (PVar "modules")) (EBlock (DoLet false false (PVar "dms") (EApp (EApp (EVar "map") (ELam ((PVar "p")) (EApp (EApp (EApp (EApp (EVar "declEnvModule") (EFieldAccess (EVar "m") "mcGraph")) (EBinOp "+" (EVar "moduleOrdinal") (EApp (EVar "fst") (EVar "p")))) (EApp (EVar "fst") (EApp (EVar "snd") (EVar "p")))) (EApp (EVar "snd") (EApp (EVar "snd") (EVar "p")))))) (EApp (EApp (EVar "zip") (EApp (EApp (EVar "range") (ELit (LInt 0))) (EApp (EVar "length") (EVar "modules")))) (EVar "modules")))) (DoExpr (ETuple (EApp (EVar "classEnvFinish") (EApp (EApp (EApp (EVar "buildClassEnvGo") (EFieldAccess (EVar "m") "mcGraph")) (EVar "dms")) (EVar "emptyClassEnv"))) (EApp (EVar "implAccFinish") (EApp (EApp (EVar "buildImplEnvGo") (EVar "dms")) (EFieldAccess (EVar "emptyDeclEnvAcc") "daImpls")))))))
(DTypeSig true "oblOver" (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "UObligation"))))
(DFunDef false "oblOver" ((PVar "iface") (PVar "args")) (ERecordCreate "UObligation" ((fa "pred" (ERecordCreate "Predicate" ((fa "iface" (EVar "iface")) (fa "args" (EVar "args"))))) (fa "originId" (ELit (LInt 0))) (fa "prov" (EVar "PNumLit")) (fa "loc" (EVar "None")) (fa "uoScope" (EApp (EVar "ScopeId") (ELit (LInt 0)))) (fa "oblProj" (EVar "OpProjected")))))
# MARK
(DUse false (UseGroup ("list") ((mem "drop" false) (mem "range" false) (mem "reverse" false) (mem "zip" false))))
(DUse false (UseGroup ("test") ((mem "Expectation" false) (mem "expectEqual" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "parse" false))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "desugar" false))))
(DUse false (UseGroup ("frontend" "exhaust") ((mem "buildOracle" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "EvId" true) (mem "Expr" true) (mem "Loc" true) (mem "Pat" true) (mem "Route" true) (mem "TabKey" false) (mem "Ty" true) (mem "TyConOrigin" true) (mem "noBinderId" false))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "pureRow" false))))
(DUse false (UseGroup ("types" "repr") ((mem "IfaceRef" true) (mem "Mono" true) (mem "Scheme" true) (mem "Tyvar" true))))
(DUse false (UseGroup ("types" "tc_mono") ((mem "tconBuiltin" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "omEmpty" false) (mem "omInsert" false))))
(DUse false (UseGroup ("types" "publish") ((mem "tcCode" false) (mem "tcMsg" false))))
(DUse false (UseGroup ("types" "tc_decls") ((mem "kindIsDeclared" false) (mem "registerData" false))))
(DUse false (UseGroup ("types" "tc_scope") ((mem "insertRecordPop" false))))
(DUse false (UseGroup ("types" "tc_env") ((mem "buildClassEnvGo" false) (mem "buildImplEnvGo" false) (mem "classEnvFinish" false) (mem "declEnvModule" false) (mem "declParamKinds" false) (mem "emptyDeclEnvAcc" false) (mem "bindingWithStandalone" false) (mem "envFor" false) (mem "extendBindings" false) (mem "implAccFinish" false) (mem "methodEnvGo" false) (mem "ordinaryEnvBinding" false) (mem "tyTabKey" false))))
(DUse false (UseGroup ("types" "scopes") ((mem "ScopeOwner" true) (mem "freshScope" false) (mem "openScopeCursor" false))))
(DUse false (UseGroup ("types" "tc_state") ((mem "blankModuleCtx" false) (mem "currentScopeStore" false) (mem "emptyClassEnv" false) (mem "freshModuleCtx" false) (mem "probeGraphCtx" false) (mem "wAll" false))))
(DUse false (UseGroup ("types" "evidence") ((mem "ScopeId" true))))
(DUse false (UseGroup ("types" "evidence_complete") ((mem "innerNone" false))))
(DUse false (UseGroup ("types" "tc_types") ((mem "CheckRunSeed" true) (mem "EvCell" true) (mem "Kind" true) (mem "MarkCtx" true) (mem "ModuleCtx" true) (mem "ClassEnv" false) (mem "ImplEnv" false) (mem "ModuleMarking" true) (mem "OblProjection" true) (mem "Predicate" true) (mem "Provenance" true) (mem "StandaloneOrigin" true) (mem "TcEnv" false) (mem "UObligation" true) (mem "ValueScheme" true))))
(DTypeSig true "routeTag" (TyFun (TyCon "Route") (TyCon "String")))
(DFunDef false "routeTag" ((PCon "RScalar" (PVar "tag"))) (EBinOp "++" (EBinOp "++" (ELit (LString "scalar:")) (EApp (EMethodRef "display") (EVar "tag"))) (ELit (LString ""))))
(DFunDef false "routeTag" ((PCon "RNone")) (ELit (LString "none")))
(DFunDef false "routeTag" ((PCon "RDict" (PVar "d"))) (EBinOp "++" (EBinOp "++" (ELit (LString "dict:")) (EApp (EMethodRef "display") (EVar "d"))) (ELit (LString ""))))
(DFunDef false "routeTag" ((PCon "RKey" (PVar "word") PWild PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "key:")) (EApp (EMethodRef "display") (EVar "word"))) (ELit (LString ""))))
(DFunDef false "routeTag" (PWild) (ELit (LString "other")))
(DTypeSig true "at" (TyCon "Loc"))
(DFunDef false "at" () (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString "t.mdk"))) (ELit (LInt 1))) (ELit (LInt 1))) (ELit (LInt 1))) (ELit (LInt 1))))
(DTypeSig true "pvar" (TyFun (TyCon "String") (TyCon "Pat")))
(DFunDef false "pvar" ((PVar "name")) (EApp (EApp (EApp (EVar "PVar") (EVar "name")) (EVar "at")) (EVar "noBinderId")))
(DTypeSig true "fresh" (TyFun (TyCon "Unit") (TyCon "ModuleCtx")))
(DFunDef false "fresh" (PWild) (EApp (EApp (EVar "blankModuleCtx") (EApp (EVar "probeGraphCtx") (ELit LUnit))) (ELit (LString "probe"))))
(DTypeSig true "scoped" (TyFun (TyCon "Unit") (TyCon "ModuleCtx")))
(DFunDef false "scoped" (PWild) (EApp (EVar "inRootScope") (EApp (EVar "fresh") (ELit LUnit))))
(DTypeSig true "inRootScope" (TyFun (TyCon "ModuleCtx") (TyCon "ModuleCtx")))
(DFunDef false "inRootScope" ((PVar "m")) (EBlock (DoLet false false (PVar "root") (EApp (EApp (EApp (EApp (EApp (EVar "freshScope") (EApp (EApp (EVar "currentScopeStore") (EFieldAccess (EVar "m") "mcGraph")) (ELit LUnit))) (EVar "None")) (ELit (LInt 0))) (ELit (LString "probe"))) (EVar "ModuleOwner"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "m") "mcCells") "currentScope")) (EApp (EVar "openScopeCursor") (EVar "root")))) (DoExpr (EVar "m"))))
(DTypeSig true "codesOf" (TyFun (TyCon "ModuleCtx") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "codesOf" ((PVar "m")) (EApp (EVar "reverse") (EApp (EApp (EMethodRef "map") (EVar "tcCode")) (EApp (EVar "wAll") (EFieldAccess (EFieldAccess (EVar "m") "mcCells") "typeErrors")))))
(DTypeSig true "messagesOf" (TyFun (TyCon "ModuleCtx") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "messagesOf" ((PVar "m")) (EApp (EVar "reverse") (EApp (EApp (EMethodRef "map") (EVar "tcMsg")) (EApp (EVar "wAll") (EFieldAccess (EFieldAccess (EVar "m") "mcCells") "typeErrors")))))
(DTypeSig true "sigsOf" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Ty"))))
(DFunDef false "sigsOf" ((PList)) (EListLit))
(DFunDef false "sigsOf" ((PCons (PCon "DTypeSig" PWild PWild (PVar "t") PWild) (PVar "rest"))) (EBinOp "::" (EVar "t") (EApp (EVar "sigsOf") (EVar "rest"))))
(DFunDef false "sigsOf" ((PCons PWild (PVar "rest"))) (EApp (EVar "sigsOf") (EVar "rest")))
(DTypeSig true "firstSig" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Ty"))))
(DFunDef false "firstSig" ((PVar "src")) (EMatch (EApp (EVar "sigsOf") (EApp (EVar "parse") (EVar "src"))) (arm (PCons (PVar "t") PWild) () (EApp (EVar "Some") (EVar "t"))) (arm (PList) () (EVar "None"))))
(DTypeSig true "withFirstSig" (TyFun (TyCon "String") (TyFun (TyFun (TyCon "Ty") (TyCon "Expectation")) (TyCon "Expectation"))))
(DFunDef false "withFirstSig" ((PVar "src") (PVar "k")) (EMatch (EApp (EVar "firstSig") (EVar "src")) (arm (PCon "Some" (PVar "t")) () (EApp (EVar "k") (EVar "t"))) (arm (PCon "None") () (EApp (EApp (EVar "expectEqual") (ELit (LString "a source with a signature"))) (EVar "src")))))
(DTypeSig true "intTy" (TyCon "Ty"))
(DFunDef false "intTy" () (ERecordCreate "TyCon" ((fa "tyConName" (ELit (LString "Int"))) (fa "tyConLoc" (EVar "None")) (fa "tyConOrigin" (EVar "OriginBuiltin")))))
(DTypeSig true "ifaceOf" (TyFun (TyCon "String") (TyCon "IfaceRef")))
(DFunDef false "ifaceOf" ((PVar "name")) (ERecordCreate "IfaceRef" ((fa "irName" (EVar "name")) (fa "irOrigin" (EApp (EVar "OriginModule") (ELit (LString "probe")))))))
(DTypeSig true "intM" (TyCon "Mono"))
(DFunDef false "intM" () (EApp (EVar "tconBuiltin") (ELit (LString "Int"))))
(DTypeSig true "boolM" (TyCon "Mono"))
(DFunDef false "boolM" () (EApp (EVar "tconBuiltin") (ELit (LString "Bool"))))
(DTypeSig true "fst3" (TyFun (TyTuple (TyVar "a") (TyVar "b") (TyVar "c")) (TyVar "a")))
(DFunDef false "fst3" ((PTuple (PVar "a") PWild PWild)) (EVar "a"))
(DTypeSig true "snd3" (TyFun (TyTuple (TyVar "a") (TyVar "b") (TyVar "c")) (TyVar "b")))
(DFunDef false "snd3" ((PTuple PWild (PVar "b") PWild)) (EVar "b"))
(DTypeSig true "varM" (TyFun (TyCon "Int") (TyCon "Mono")))
(DFunDef false "varM" ((PVar "id")) (EApp (EVar "TVar") (EApp (EVar "Ref") (EApp (EApp (EVar "Unbound") (EVar "id")) (ELit (LInt 0))))))
(DTypeSig true "aliasTableOf" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Ty"))))))
(DFunDef false "aliasTableOf" ((PList)) (EListLit))
(DFunDef false "aliasTableOf" ((PCons (PRec "DTypeAlias" ((rf "tyAliasName" (PVar "n")) (rf "tyAliasParams" (PVar "ps")) (rf "tyAliasRhs" (PVar "rhs")) (rf "tyAliasOrigin" (PVar "o"))) false) (PVar "rest"))) (EBinOp "::" (ETuple (EApp (EApp (EVar "tyTabKey") (EVar "o")) (EVar "n")) (ETuple (EVar "ps") (EVar "rhs"))) (EApp (EVar "aliasTableOf") (EVar "rest"))))
(DFunDef false "aliasTableOf" ((PCons PWild (PVar "rest"))) (EApp (EVar "aliasTableOf") (EVar "rest")))
(DTypeSig true "recordKindsOf" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Unit"))))
(DFunDef false "recordKindsOf" (PWild (PList)) (ELit LUnit))
(DFunDef false "recordKindsOf" ((PVar "m") (PCons (PRec "DData" ((rf "dataName" (PVar "n")) (rf "dataParams" (PVar "ps")) (rf "dataParamKinds" (PVar "anns")) (rf "dataOrigin" (PVar "o"))) false) (PVar "rest"))) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EVar "recordKinds") (EVar "m")) (EVar "o")) (EVar "n")) (EApp (EApp (EApp (EVar "declParamKinds") (EFieldAccess (EVar "m") "mcGraph")) (EVar "ps")) (EVar "anns")))) (DoExpr (EApp (EApp (EVar "recordKindsOf") (EVar "m")) (EVar "rest")))))
(DFunDef false "recordKindsOf" ((PVar "m") (PCons (PRec "DNewtype" ((rf "newtypeName" (PVar "n")) (rf "newtypeParams" (PVar "ps")) (rf "newtypeParamKinds" (PVar "anns")) (rf "newtypeOrigin" (PVar "o"))) false) (PVar "rest"))) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EVar "recordKinds") (EVar "m")) (EVar "o")) (EVar "n")) (EApp (EApp (EApp (EVar "declParamKinds") (EFieldAccess (EVar "m") "mcGraph")) (EVar "ps")) (EVar "anns")))) (DoExpr (EApp (EApp (EVar "recordKindsOf") (EVar "m")) (EVar "rest")))))
(DFunDef false "recordKindsOf" ((PVar "m") (PCons (PRec "DTypeAlias" ((rf "tyAliasName" (PVar "n")) (rf "tyAliasParams" (PVar "ps")) (rf "tyAliasParamKinds" (PVar "anns")) (rf "tyAliasOrigin" (PVar "o"))) false) (PVar "rest"))) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EVar "recordKinds") (EVar "m")) (EVar "o")) (EVar "n")) (EApp (EApp (EApp (EVar "declParamKinds") (EFieldAccess (EVar "m") "mcGraph")) (EVar "ps")) (EVar "anns")))) (DoExpr (EApp (EApp (EVar "recordKindsOf") (EVar "m")) (EVar "rest")))))
(DFunDef false "recordKindsOf" ((PVar "m") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "recordKindsOf") (EVar "m")) (EVar "rest")))
(DTypeSig false "recordKinds" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "TyConOrigin") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Kind")) (TyCon "Unit"))))))
(DFunDef false "recordKinds" ((PVar "m") (PVar "o") (PVar "n") (PVar "kinds")) (EIf (EApp (EApp (EDictApp "any") (EVar "kindIsDeclared")) (EVar "kinds")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "m") "mcCells") "dataParamKindsRef")) (EBinOp "::" (ETuple (EApp (EApp (EVar "tyTabKey") (EVar "o")) (EVar "n")) (EVar "kinds")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "m") "mcCells") "dataParamKindsRef") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "m") "mcCells") "dataParamNameIndexRef")) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (ELit LUnit)) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "m") "mcCells") "dataParamNameIndexRef") "value"))))) (EIf (EVar "otherwise") (ELit LUnit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "libSource" (TyCon "String"))
(DFunDef false "libSource" () (ELit (LString "interface Sizeable a where\n  size : a -> Int\nimpl Sizeable Int where\n  size n = n\n")))
(DTypeSig true "declaredIn" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "declaredIn" ((PVar "mid") (PVar "ds")) (EApp (EApp (EMethodRef "map") (EApp (EVar "declaredAs") (EVar "mid"))) (EVar "ds")))
(DTypeSig false "declaredAs" (TyFun (TyCon "String") (TyFun (TyCon "Decl") (TyCon "Decl"))))
(DFunDef false "declaredAs" ((PVar "mid") (PAs "d" (PRec "DInterface" ((rf "supers" (PVar "ss"))) true))) (EVariantUpdate "DInterface" (EVar "d") ((fa "ifaceOrigin" (EApp (EVar "OriginModule") (EVar "mid"))) (fa "supers" (EApp (EApp (EMethodRef "map") (ELam ((PVar "sup")) (ERecordUpdate (EVar "sup") ((fa "superOrigin" (EApp (EVar "OriginModule") (EVar "mid"))))))) (EVar "ss"))))))
(DFunDef false "declaredAs" ((PVar "mid") (PAs "d" (PRec "DImpl" ((rf "implOrigin" PWild)) false))) (EVariantUpdate "DImpl" (EVar "d") ((fa "implOrigin" (EApp (EVar "OriginModule") (EVar "mid"))))))
(DFunDef false "declaredAs" (PWild (PVar "d")) (EVar "d"))
(DTypeSig true "readerOfLib" (TyFun (TyCon "Unit") (TyCon "ModuleCtx")))
(DFunDef false "readerOfLib" (PWild) (EBlock (DoLet false false (PVar "g") (EApp (EVar "probeGraphCtx") (ELit LUnit))) (DoLet false false (PVar "lib") (EApp (EApp (EApp (EApp (EVar "declEnvModule") (EVar "g")) (ELit (LInt 1))) (ELit (LString "lib"))) (EApp (EApp (EVar "declaredIn") (ELit (LString "lib"))) (EApp (EVar "parse") (EVar "libSource"))))) (DoLet false false (PVar "user") (EApp (EApp (EApp (EApp (EVar "declEnvModule") (EVar "g")) (ELit (LInt 2))) (ELit (LString "user"))) (EListLit))) (DoLet false false (PVar "empty") (EFieldAccess (EFieldAccess (EVar "g") "declEnvsRef") "value")) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "g") "declEnvsRef")) (ERecordUpdate (EMethodRef "empty") ((fa "deMethods" (EApp (EApp (EApp (EVar "methodEnvGo") (EVar "g")) (EListLit (EVar "lib") (EVar "user"))) (EFieldAccess (EMethodRef "empty") "deMethods"))))))) (DoLet false false (PVar "m") (EApp (EApp (EVar "blankModuleCtx") (EVar "g")) (ELit (LString "user")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "m") "mcCells") "methodScopeCtxRef")) (EApp (EVar "Some") (ETuple (EListLit) (ELit (LInt 2)))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "m") "mcCells") "bodyImplEnvRef")) (EApp (EVar "implAccFinish") (EApp (EApp (EVar "buildImplEnvGo") (EListLit (EVar "lib") (EVar "user"))) (EFieldAccess (EVar "emptyDeclEnvAcc") "daImpls"))))) (DoExpr (EVar "m"))))
(DTypeSig true "scopedWith" (TyFun (TyCon "String") (TyCon "ModuleCtx")))
(DFunDef false "scopedWith" ((PVar "src")) (EBlock (DoLet false false (PVar "seed") (ERecordCreate "CheckRunSeed" ((fa "crsOracle" (EApp (EVar "buildOracle") (EApp (EApp (EMethodRef "map") (EApp (EVar "declaredAsData") (ELit (LString "m")))) (EApp (EVar "parse") (EVar "src"))))) (fa "crsWarnings" (EListLit))))) (DoExpr (EApp (EVar "inRootScope") (EApp (EApp (EApp (EVar "freshModuleCtx") (EApp (EVar "probeGraphCtx") (ELit LUnit))) (EVar "seed")) (ELit (LString "probe")))))))
(DTypeSig true "envWithData" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyCon "TcEnv"))))
(DFunDef false "envWithData" ((PVar "m") (PVar "src")) (EApp (EApp (EApp (EApp (EVar "declareData") (ELit (LString "m"))) (EVar "m")) (EApp (EVar "envFor") (EVar "m"))) (EVar "src")))
(DTypeSig true "declareData" (TyFun (TyCon "String") (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyCon "TcEnv"))))))
(DFunDef false "declareData" ((PVar "mid") (PVar "m") (PVar "env") (PVar "src")) (EBlock (DoLet false false (PVar "ds") (EApp (EApp (EMethodRef "map") (EApp (EVar "declaredAsData") (EVar "mid"))) (EApp (EVar "parse") (EVar "src")))) (DoLet false false (PVar "registered") (EApp (EApp (EApp (EMethodRef "fold") (EVar "registerData")) (EVar "env")) (EVar "ds"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "m") "mcGraph") "crossRun") "universeRecordPop")) (EApp (EApp (EApp (EVar "insertRecordPop") (EVar "m")) (EVar "ds")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "m") "mcGraph") "crossRun") "universeRecordPop") "value")))) (DoExpr (EVar "registered"))))
(DTypeSig false "declaredAsData" (TyFun (TyCon "String") (TyFun (TyCon "Decl") (TyCon "Decl"))))
(DFunDef false "declaredAsData" ((PVar "mid") (PAs "d" (PRec "DData" ((rf "dataOrigin" PWild)) false))) (EVariantUpdate "DData" (EVar "d") ((fa "dataOrigin" (EApp (EVar "OriginModule") (EVar "mid"))))))
(DFunDef false "declaredAsData" (PWild (PVar "d")) (EVar "d"))
(DTypeSig true "recordShapes" (TyCon "String"))
(DFunDef false "recordShapes" () (ELit (LString "data P = P { a : Int, b : Bool }\ndata Box t = Box { v : t }\ndata Pair x y = Pair { first : x, second : y }\ndata Cfg = Cfg { name : String, count : Int }\n")))
(DTypeSig true "kindName" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "kindName" ((PLit (LInt 0))) (ELit (LString "Char")))
(DFunDef false "kindName" ((PLit (LInt 1))) (ELit (LString "Bool")))
(DFunDef false "kindName" ((PLit (LInt 2))) (ELit (LString "String")))
(DFunDef false "kindName" (PWild) (ELit (LString "Unit")))
(DTypeSig true "kindLit" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "kindLit" ((PLit (LInt 0))) (ELit (LString "'c'")))
(DFunDef false "kindLit" ((PLit (LInt 1))) (ELit (LString "True")))
(DFunDef false "kindLit" ((PLit (LInt 2))) (ELit (LString "\"s\"")))
(DFunDef false "kindLit" (PWild) (ELit (LString "()")))
(DTypeSig true "genKinds" (TyFun (TyCon "Int") (TyEffect ("Rand") None (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "genKinds" ((PVar "n")) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (EListLit) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EApp (EVar "randomInt") (ELit (LInt 0))) (EVar "unitKind")) (EApp (EVar "genKinds") (EBinOp "-" (EVar "n") (ELit (LInt 1))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "unitKind" (TyCon "Int"))
(DFunDef false "unitKind" () (ELit (LInt 3)))
(DTypeSig true "nthInt" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Int"))))
(DFunDef false "nthInt" ((PVar "i") (PVar "xs")) (EMatch (EApp (EApp (EVar "drop") (EVar "i")) (EVar "xs")) (arm (PCons (PVar "x") PWild) () (EVar "x")) (arm (PList) () (EVar "unitKind"))))
(DTypeSig true "shadowEnvOf" (TyFun (TyCon "Scheme") (TyFun (TyCon "Scheme") (TyFun (TyCon "ModuleCtx") (TyCon "TcEnv")))))
(DFunDef false "shadowEnvOf" ((PVar "method") (PVar "standalone") (PVar "m")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "m") "mcCells") "standaloneValuesRef")) (EApp (EApp (EApp (EVar "omInsert") (ELit (LString "size"))) (ELit LUnit)) (EVar "omEmpty")))) (DoExpr (EApp (EApp (EVar "extendBindings") (EApp (EVar "envFor") (EVar "m"))) (EListLit (ETuple (ELit (LString "size")) (EApp (EApp (EVar "bindingWithStandalone") (EApp (EVar "ordinaryEnvBinding") (EVar "method"))) (ETuple (EVar "ImportedStandalone") (ERecordCreate "ValueScheme" ((fa "vsScheme" (EVar "standalone")) (fa "vsDeclared" (EVar "None"))))))))))))
(DTypeSig true "methodOccurrence" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyCon "Expr"))))
(DFunDef false "methodOccurrence" ((PVar "m") (PVar "name")) (EBlock (DoLet false false (PVar "ev") (EApp (EApp (EVar "EvId") (ELit (LString "probe"))) (ELit (LInt 0)))) (DoLet false false (PVar "cell") (ERecordCreate "EvCell" ((fa "ecId" (EVar "ev")) (fa "ecIface" (EApp (EVar "Ref") (ELit (LString "")))) (fa "ecArity" (EApp (EVar "Ref") (EVar "None"))) (fa "ecTag" (EApp (EVar "Ref") (EVar "RNone"))) (fa "ecImpl" (EApp (EVar "Ref") (EListLit))) (fa "ecMeth" (EApp (EVar "Ref") (EListLit))) (fa "ecLoc" (EApp (EVar "Ref") (EVar "None"))) (fa "ecName" (EApp (EVar "Ref") (ELit (LString "")))) (fa "ecInner" (EApp (EVar "Ref") (EVar "innerNone")))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "m") "mcGraph") "graphRun") "evCells")) (EApp (EApp (EVar "arrayMake") (ELit (LInt 1))) (EApp (EVar "Some") (EVar "cell"))))) (DoExpr (EApp (EApp (EApp (EVar "EMethodAt") (EVar "name")) (ELit (LString ""))) (EVar "ev")))))
(DTypeSig true "sizeScheme" (TyCon "Scheme"))
(DFunDef false "sizeScheme" () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Forall") (EListLit (ELit (LInt 1)))) (EListLit)) (EListLit)) (EListLit)) (EVar "pureRow")) (EApp (EApp (EApp (EVar "TFun") (EApp (EVar "varM") (ELit (LInt 1)))) (EVar "pureRow")) (EVar "intM"))))
(DTypeSig true "moduleDecls" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "moduleDecls" ((PVar "src")) (EApp (EApp (EVar "declsOf") (ELit (LString "m"))) (EVar "src")))
(DTypeSig true "declsOf" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "declsOf" ((PVar "origin") (PVar "src")) (EApp (EApp (EVar "declaredIn") (EVar "origin")) (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "src")))))
(DTypeSig true "moduleOrdinal" (TyCon "Int"))
(DFunDef false "moduleOrdinal" () (ELit (LInt 1)))
(DTypeSig true "envsOf" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyTuple (TyCon "ClassEnv") (TyCon "ImplEnv")))))
(DFunDef false "envsOf" ((PVar "m") (PVar "ds")) (EApp (EApp (EVar "envsOfModules") (EVar "m")) (EListLit (ETuple (ELit (LString "m")) (EVar "ds")))))
(DTypeSig true "envsOfModules" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyTuple (TyCon "ClassEnv") (TyCon "ImplEnv")))))
(DFunDef false "envsOfModules" ((PVar "m") (PVar "modules")) (EBlock (DoLet false false (PVar "dms") (EApp (EApp (EMethodRef "map") (ELam ((PVar "p")) (EApp (EApp (EApp (EApp (EVar "declEnvModule") (EFieldAccess (EVar "m") "mcGraph")) (EBinOp "+" (EVar "moduleOrdinal") (EApp (EVar "fst") (EVar "p")))) (EApp (EVar "fst") (EApp (EVar "snd") (EVar "p")))) (EApp (EVar "snd") (EApp (EVar "snd") (EVar "p")))))) (EApp (EApp (EVar "zip") (EApp (EApp (EVar "range") (ELit (LInt 0))) (EApp (EMethodRef "length") (EVar "modules")))) (EVar "modules")))) (DoExpr (ETuple (EApp (EVar "classEnvFinish") (EApp (EApp (EApp (EVar "buildClassEnvGo") (EFieldAccess (EVar "m") "mcGraph")) (EVar "dms")) (EVar "emptyClassEnv"))) (EApp (EVar "implAccFinish") (EApp (EApp (EVar "buildImplEnvGo") (EVar "dms")) (EFieldAccess (EVar "emptyDeclEnvAcc") "daImpls")))))))
(DTypeSig true "oblOver" (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "UObligation"))))
(DFunDef false "oblOver" ((PVar "iface") (PVar "args")) (ERecordCreate "UObligation" ((fa "pred" (ERecordCreate "Predicate" ((fa "iface" (EVar "iface")) (fa "args" (EVar "args"))))) (fa "originId" (ELit (LInt 0))) (fa "prov" (EVar "PNumLit")) (fa "loc" (EVar "None")) (fa "uoScope" (EApp (EVar "ScopeId") (ELit (LInt 0)))) (fa "oblProj" (EVar "OpProjected")))))
