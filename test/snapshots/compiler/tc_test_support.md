# META
source_lines=391
stages=DESUGAR,MARK
# SOURCE
-- tc_test_support: the fixtures the `tc_*_test` siblings of `compiler/types` share: a fresh
-- module record (`fresh`, and `scoped` inside a root scope), the codes and messages it has
-- been given, the signatures of a parsed source, the alias table and declared parameter kinds
-- a source's declarations register, the interface reference and the monos of the probe module
-- (`ifaceOf`, `intM`, `boolM`, `varM`), a hand-built pattern (`at`, `pvar`), the literal and
-- type name of a generated kind (`kindLit`, `kindName`, `genKinds`, `nthInt`), the triple
-- projections (`fst3`, `snd3`), the reader of a module that declares an interface with a live
-- impl (`readerOfLib`), the environment of an importer shadow over it (`shadowEnvOf`), a method occurrence of it (`methodOccurrence`), the
-- marked body of a source's `main` (`withMain`, `mainOf`) and the environment over the data
-- and record types a source declares (`scopedWith`, `envWithData`, `declareData`).  Test siblings import it
-- and no production module does.
-- `aliasTableOf` and `recordKindsOf` are the fixture-side twins of `tc_decls`'
-- `graphAliasRow` and `withDeclParamKinds`: a test of a module below `tc_decls` cannot
-- import those, and its fixtures need the same tables.  `recordKindsOf` reads `tc_decls`'
-- own `kindIsDeclared`, so the registration test it serves cannot disagree with it.

import list.{drop, reverse}
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
import support.ordmap.{omEmpty, omInsert, omLookup}
import types.publish.{tcCode, tcMsg}
import types.tc_decls.{kindIsDeclared, registerData}
import types.tc_scope.{insertRecordPop}
import types.tc_occurrence.{markGroupClauses}
import types.tc_effects.{clausesOf}
import types.tc_env.{
  buildImplEnvGo,
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
  freshModuleCtx,
  probeGraphCtx,
  wAll,
}
import types.evidence_complete.{innerNone}
import types.tc_types.{
  CheckRunSeed(..),
  EvCell(..),
  Kind(..),
  MarkCtx(..),
  ModuleCtx(..),
  ModuleMarking(..),
  StandaloneOrigin(..),
  TcEnv,
  ValueScheme(..),
}

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

-- The declarations of [ds] stamped as declared in the module [mid].
export
declaredIn : String -> List Decl -> List Decl
declaredIn mid ds = map (declaredAs mid) ds

declaredAs : String -> Decl -> Decl
declaredAs mid (d@(DInterface { ifaceOrigin = _ })) =
  DInterface { d | ifaceOrigin = OriginModule mid }
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

-- A marking that sends no name to a method, dictionary or shadow occurrence: the mark pass
-- over it only mints the evidence sites of the operators, literals and field accesses.
plainMarking : ModuleMarking
plainMarking = ModuleMarking {
  mmCtx = MarkCtx { mcRp = omEmpty, mcAn = omEmpty, mcSm = [] },
  mmTop = omEmpty,
  mmDictSet = Ref omEmpty,
  mmUserNames = omEmpty,
  mmExterns = omEmpty,
}

-- The right-hand side of `main = ...` in [src], parsed, desugared and run through the mark
-- pass in [m] so every site it names is minted, as the inference recursion reads it; `None`
-- when [src] defines no `main`.
export
mainOf : ModuleCtx -> String -> Option Expr
mainOf m src =
  let grouped =
    fold
      (acc (name, clause) =>
        omInsert name (clause :: optionOr [] (omLookup name acc)) acc)
      omEmpty
      (flatMap
        (d => match d
          DFunDef _ name pats body _ _ => [(name, (pats, body))]
          _ => [])
        (desugar (parse src)))
  let marked = markGroupClauses plainMarking (envFor m) ["main"] grouped
  match clausesOf "main" marked
    (_, body) :: _ => Some body
    [] => None

-- [k] applied to `mainOf m src`; a source with no `main` fails the test.
export
withMain : ModuleCtx -> String -> (Expr -> Expectation) -> Expectation
withMain m src k = match mainOf m src
  Some body => k body
  None => expectEqual "a source defining main" src

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
  | otherwise = randomInt 0 3 :: genKinds (n - 1)

-- The element of [xs] at index [i]; the Unit kind, 3, beyond the end.
export
nthInt : Int -> List Int -> Int
nthInt i xs = match drop i xs
  x :: _ => x
  [] => 3

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
# DESUGAR
(DUse false (UseGroup ("list") ((mem "drop" false) (mem "reverse" false))))
(DUse false (UseGroup ("test") ((mem "Expectation" false) (mem "expectEqual" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "parse" false))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "desugar" false))))
(DUse false (UseGroup ("frontend" "exhaust") ((mem "buildOracle" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "EvId" true) (mem "Expr" true) (mem "Loc" true) (mem "Pat" true) (mem "Route" true) (mem "TabKey" false) (mem "Ty" true) (mem "TyConOrigin" true) (mem "noBinderId" false))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "pureRow" false))))
(DUse false (UseGroup ("types" "repr") ((mem "IfaceRef" true) (mem "Mono" true) (mem "Scheme" true) (mem "Tyvar" true))))
(DUse false (UseGroup ("types" "tc_mono") ((mem "tconBuiltin" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "omEmpty" false) (mem "omInsert" false) (mem "omLookup" false))))
(DUse false (UseGroup ("types" "publish") ((mem "tcCode" false) (mem "tcMsg" false))))
(DUse false (UseGroup ("types" "tc_decls") ((mem "kindIsDeclared" false) (mem "registerData" false))))
(DUse false (UseGroup ("types" "tc_scope") ((mem "insertRecordPop" false))))
(DUse false (UseGroup ("types" "tc_occurrence") ((mem "markGroupClauses" false))))
(DUse false (UseGroup ("types" "tc_effects") ((mem "clausesOf" false))))
(DUse false (UseGroup ("types" "tc_env") ((mem "buildImplEnvGo" false) (mem "declEnvModule" false) (mem "declParamKinds" false) (mem "emptyDeclEnvAcc" false) (mem "bindingWithStandalone" false) (mem "envFor" false) (mem "extendBindings" false) (mem "implAccFinish" false) (mem "methodEnvGo" false) (mem "ordinaryEnvBinding" false) (mem "tyTabKey" false))))
(DUse false (UseGroup ("types" "scopes") ((mem "ScopeOwner" true) (mem "freshScope" false) (mem "openScopeCursor" false))))
(DUse false (UseGroup ("types" "tc_state") ((mem "blankModuleCtx" false) (mem "currentScopeStore" false) (mem "freshModuleCtx" false) (mem "probeGraphCtx" false) (mem "wAll" false))))
(DUse false (UseGroup ("types" "evidence_complete") ((mem "innerNone" false))))
(DUse false (UseGroup ("types" "tc_types") ((mem "CheckRunSeed" true) (mem "EvCell" true) (mem "Kind" true) (mem "MarkCtx" true) (mem "ModuleCtx" true) (mem "ModuleMarking" true) (mem "StandaloneOrigin" true) (mem "TcEnv" false) (mem "ValueScheme" true))))
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
(DFunDef false "declaredAs" ((PVar "mid") (PAs "d" (PRec "DInterface" ((rf "ifaceOrigin" PWild)) false))) (EVariantUpdate "DInterface" (EVar "d") ((fa "ifaceOrigin" (EApp (EVar "OriginModule") (EVar "mid"))))))
(DFunDef false "declaredAs" ((PVar "mid") (PAs "d" (PRec "DImpl" ((rf "implOrigin" PWild)) false))) (EVariantUpdate "DImpl" (EVar "d") ((fa "implOrigin" (EApp (EVar "OriginModule") (EVar "mid"))))))
(DFunDef false "declaredAs" (PWild (PVar "d")) (EVar "d"))
(DTypeSig true "readerOfLib" (TyFun (TyCon "Unit") (TyCon "ModuleCtx")))
(DFunDef false "readerOfLib" (PWild) (EBlock (DoLet false false (PVar "g") (EApp (EVar "probeGraphCtx") (ELit LUnit))) (DoLet false false (PVar "lib") (EApp (EApp (EApp (EApp (EVar "declEnvModule") (EVar "g")) (ELit (LInt 1))) (ELit (LString "lib"))) (EApp (EApp (EVar "declaredIn") (ELit (LString "lib"))) (EApp (EVar "parse") (EVar "libSource"))))) (DoLet false false (PVar "user") (EApp (EApp (EApp (EApp (EVar "declEnvModule") (EVar "g")) (ELit (LInt 2))) (ELit (LString "user"))) (EListLit))) (DoLet false false (PVar "empty") (EFieldAccess (EFieldAccess (EVar "g") "declEnvsRef") "value")) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "g") "declEnvsRef")) (ERecordUpdate (EVar "empty") ((fa "deMethods" (EApp (EApp (EApp (EVar "methodEnvGo") (EVar "g")) (EListLit (EVar "lib") (EVar "user"))) (EFieldAccess (EVar "empty") "deMethods"))))))) (DoLet false false (PVar "m") (EApp (EApp (EVar "blankModuleCtx") (EVar "g")) (ELit (LString "user")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "m") "mcCells") "methodScopeCtxRef")) (EApp (EVar "Some") (ETuple (EListLit) (ELit (LInt 2)))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "m") "mcCells") "bodyImplEnvRef")) (EApp (EVar "implAccFinish") (EApp (EApp (EVar "buildImplEnvGo") (EListLit (EVar "lib") (EVar "user"))) (EFieldAccess (EVar "emptyDeclEnvAcc") "daImpls"))))) (DoExpr (EVar "m"))))
(DTypeSig false "plainMarking" (TyCon "ModuleMarking"))
(DFunDef false "plainMarking" () (ERecordCreate "ModuleMarking" ((fa "mmCtx" (ERecordCreate "MarkCtx" ((fa "mcRp" (EVar "omEmpty")) (fa "mcAn" (EVar "omEmpty")) (fa "mcSm" (EListLit))))) (fa "mmTop" (EVar "omEmpty")) (fa "mmDictSet" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "mmUserNames" (EVar "omEmpty")) (fa "mmExterns" (EVar "omEmpty")))))
(DTypeSig true "mainOf" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Expr")))))
(DFunDef false "mainOf" ((PVar "m") (PVar "src")) (EBlock (DoLet false false (PVar "grouped") (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PTuple (PVar "name") (PVar "clause"))) (EApp (EApp (EApp (EVar "omInsert") (EVar "name")) (EBinOp "::" (EVar "clause") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "name")) (EVar "acc"))))) (EVar "acc")))) (EVar "omEmpty")) (EApp (EApp (EVar "flatMap") (ELam ((PVar "d")) (EMatch (EVar "d") (arm (PCon "DFunDef" PWild (PVar "name") (PVar "pats") (PVar "body") PWild PWild) () (EListLit (ETuple (EVar "name") (ETuple (EVar "pats") (EVar "body"))))) (arm PWild () (EListLit))))) (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "src")))))) (DoLet false false (PVar "marked") (EApp (EApp (EApp (EApp (EVar "markGroupClauses") (EVar "plainMarking")) (EApp (EVar "envFor") (EVar "m"))) (EListLit (ELit (LString "main")))) (EVar "grouped"))) (DoExpr (EMatch (EApp (EApp (EVar "clausesOf") (ELit (LString "main"))) (EVar "marked")) (arm (PCons (PTuple PWild (PVar "body")) PWild) () (EApp (EVar "Some") (EVar "body"))) (arm (PList) () (EVar "None"))))))
(DTypeSig true "withMain" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyFun (TyCon "Expr") (TyCon "Expectation")) (TyCon "Expectation")))))
(DFunDef false "withMain" ((PVar "m") (PVar "src") (PVar "k")) (EMatch (EApp (EApp (EVar "mainOf") (EVar "m")) (EVar "src")) (arm (PCon "Some" (PVar "body")) () (EApp (EVar "k") (EVar "body"))) (arm (PCon "None") () (EApp (EApp (EVar "expectEqual") (ELit (LString "a source defining main"))) (EVar "src")))))
(DTypeSig true "scopedWith" (TyFun (TyCon "String") (TyCon "ModuleCtx")))
(DFunDef false "scopedWith" ((PVar "src")) (EBlock (DoLet false false (PVar "seed") (ERecordCreate "CheckRunSeed" ((fa "crsOracle" (EApp (EVar "buildOracle") (EApp (EApp (EVar "map") (EApp (EVar "declaredAsData") (ELit (LString "m")))) (EApp (EVar "parse") (EVar "src"))))) (fa "crsWarnings" (EListLit))))) (DoExpr (EApp (EVar "inRootScope") (EApp (EApp (EApp (EVar "freshModuleCtx") (EApp (EVar "probeGraphCtx") (ELit LUnit))) (EVar "seed")) (ELit (LString "probe")))))))
(DTypeSig true "envWithData" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyCon "TcEnv"))))
(DFunDef false "envWithData" ((PVar "m") (PVar "src")) (EApp (EApp (EApp (EApp (EVar "declareData") (ELit (LString "m"))) (EVar "m")) (EApp (EVar "envFor") (EVar "m"))) (EVar "src")))
(DTypeSig true "declareData" (TyFun (TyCon "String") (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyCon "TcEnv"))))))
(DFunDef false "declareData" ((PVar "mid") (PVar "m") (PVar "env") (PVar "src")) (EBlock (DoLet false false (PVar "ds") (EApp (EApp (EVar "map") (EApp (EVar "declaredAsData") (EVar "mid"))) (EApp (EVar "parse") (EVar "src")))) (DoLet false false (PVar "registered") (EApp (EApp (EApp (EVar "fold") (EVar "registerData")) (EVar "env")) (EVar "ds"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "m") "mcGraph") "crossRun") "universeRecordPop")) (EApp (EApp (EApp (EVar "insertRecordPop") (EVar "m")) (EVar "ds")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "m") "mcGraph") "crossRun") "universeRecordPop") "value")))) (DoExpr (EVar "registered"))))
(DTypeSig false "declaredAsData" (TyFun (TyCon "String") (TyFun (TyCon "Decl") (TyCon "Decl"))))
(DFunDef false "declaredAsData" ((PVar "mid") (PAs "d" (PRec "DData" ((rf "dataOrigin" PWild)) false))) (EVariantUpdate "DData" (EVar "d") ((fa "dataOrigin" (EApp (EVar "OriginModule") (EVar "mid"))))))
(DFunDef false "declaredAsData" (PWild (PVar "d")) (EVar "d"))
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
(DFunDef false "genKinds" ((PVar "n")) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (EListLit) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EApp (EVar "randomInt") (ELit (LInt 0))) (ELit (LInt 3))) (EApp (EVar "genKinds") (EBinOp "-" (EVar "n") (ELit (LInt 1))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "nthInt" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Int"))))
(DFunDef false "nthInt" ((PVar "i") (PVar "xs")) (EMatch (EApp (EApp (EVar "drop") (EVar "i")) (EVar "xs")) (arm (PCons (PVar "x") PWild) () (EVar "x")) (arm (PList) () (ELit (LInt 3)))))
(DTypeSig true "shadowEnvOf" (TyFun (TyCon "Scheme") (TyFun (TyCon "Scheme") (TyFun (TyCon "ModuleCtx") (TyCon "TcEnv")))))
(DFunDef false "shadowEnvOf" ((PVar "method") (PVar "standalone") (PVar "m")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "m") "mcCells") "standaloneValuesRef")) (EApp (EApp (EApp (EVar "omInsert") (ELit (LString "size"))) (ELit LUnit)) (EVar "omEmpty")))) (DoExpr (EApp (EApp (EVar "extendBindings") (EApp (EVar "envFor") (EVar "m"))) (EListLit (ETuple (ELit (LString "size")) (EApp (EApp (EVar "bindingWithStandalone") (EApp (EVar "ordinaryEnvBinding") (EVar "method"))) (ETuple (EVar "ImportedStandalone") (ERecordCreate "ValueScheme" ((fa "vsScheme" (EVar "standalone")) (fa "vsDeclared" (EVar "None"))))))))))))
(DTypeSig true "methodOccurrence" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyCon "Expr"))))
(DFunDef false "methodOccurrence" ((PVar "m") (PVar "name")) (EBlock (DoLet false false (PVar "ev") (EApp (EApp (EVar "EvId") (ELit (LString "probe"))) (ELit (LInt 0)))) (DoLet false false (PVar "cell") (ERecordCreate "EvCell" ((fa "ecId" (EVar "ev")) (fa "ecIface" (EApp (EVar "Ref") (ELit (LString "")))) (fa "ecArity" (EApp (EVar "Ref") (EVar "None"))) (fa "ecTag" (EApp (EVar "Ref") (EVar "RNone"))) (fa "ecImpl" (EApp (EVar "Ref") (EListLit))) (fa "ecMeth" (EApp (EVar "Ref") (EListLit))) (fa "ecLoc" (EApp (EVar "Ref") (EVar "None"))) (fa "ecName" (EApp (EVar "Ref") (ELit (LString "")))) (fa "ecInner" (EApp (EVar "Ref") (EVar "innerNone")))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "m") "mcGraph") "graphRun") "evCells")) (EApp (EApp (EVar "arrayMake") (ELit (LInt 1))) (EApp (EVar "Some") (EVar "cell"))))) (DoExpr (EApp (EApp (EApp (EVar "EMethodAt") (EVar "name")) (ELit (LString ""))) (EVar "ev")))))
(DTypeSig true "sizeScheme" (TyCon "Scheme"))
(DFunDef false "sizeScheme" () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Forall") (EListLit (ELit (LInt 1)))) (EListLit)) (EListLit)) (EListLit)) (EVar "pureRow")) (EApp (EApp (EApp (EVar "TFun") (EApp (EVar "varM") (ELit (LInt 1)))) (EVar "pureRow")) (EVar "intM"))))
# MARK
(DUse false (UseGroup ("list") ((mem "drop" false) (mem "reverse" false))))
(DUse false (UseGroup ("test") ((mem "Expectation" false) (mem "expectEqual" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "parse" false))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "desugar" false))))
(DUse false (UseGroup ("frontend" "exhaust") ((mem "buildOracle" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "EvId" true) (mem "Expr" true) (mem "Loc" true) (mem "Pat" true) (mem "Route" true) (mem "TabKey" false) (mem "Ty" true) (mem "TyConOrigin" true) (mem "noBinderId" false))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "pureRow" false))))
(DUse false (UseGroup ("types" "repr") ((mem "IfaceRef" true) (mem "Mono" true) (mem "Scheme" true) (mem "Tyvar" true))))
(DUse false (UseGroup ("types" "tc_mono") ((mem "tconBuiltin" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "omEmpty" false) (mem "omInsert" false) (mem "omLookup" false))))
(DUse false (UseGroup ("types" "publish") ((mem "tcCode" false) (mem "tcMsg" false))))
(DUse false (UseGroup ("types" "tc_decls") ((mem "kindIsDeclared" false) (mem "registerData" false))))
(DUse false (UseGroup ("types" "tc_scope") ((mem "insertRecordPop" false))))
(DUse false (UseGroup ("types" "tc_occurrence") ((mem "markGroupClauses" false))))
(DUse false (UseGroup ("types" "tc_effects") ((mem "clausesOf" false))))
(DUse false (UseGroup ("types" "tc_env") ((mem "buildImplEnvGo" false) (mem "declEnvModule" false) (mem "declParamKinds" false) (mem "emptyDeclEnvAcc" false) (mem "bindingWithStandalone" false) (mem "envFor" false) (mem "extendBindings" false) (mem "implAccFinish" false) (mem "methodEnvGo" false) (mem "ordinaryEnvBinding" false) (mem "tyTabKey" false))))
(DUse false (UseGroup ("types" "scopes") ((mem "ScopeOwner" true) (mem "freshScope" false) (mem "openScopeCursor" false))))
(DUse false (UseGroup ("types" "tc_state") ((mem "blankModuleCtx" false) (mem "currentScopeStore" false) (mem "freshModuleCtx" false) (mem "probeGraphCtx" false) (mem "wAll" false))))
(DUse false (UseGroup ("types" "evidence_complete") ((mem "innerNone" false))))
(DUse false (UseGroup ("types" "tc_types") ((mem "CheckRunSeed" true) (mem "EvCell" true) (mem "Kind" true) (mem "MarkCtx" true) (mem "ModuleCtx" true) (mem "ModuleMarking" true) (mem "StandaloneOrigin" true) (mem "TcEnv" false) (mem "ValueScheme" true))))
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
(DFunDef false "declaredAs" ((PVar "mid") (PAs "d" (PRec "DInterface" ((rf "ifaceOrigin" PWild)) false))) (EVariantUpdate "DInterface" (EVar "d") ((fa "ifaceOrigin" (EApp (EVar "OriginModule") (EVar "mid"))))))
(DFunDef false "declaredAs" ((PVar "mid") (PAs "d" (PRec "DImpl" ((rf "implOrigin" PWild)) false))) (EVariantUpdate "DImpl" (EVar "d") ((fa "implOrigin" (EApp (EVar "OriginModule") (EVar "mid"))))))
(DFunDef false "declaredAs" (PWild (PVar "d")) (EVar "d"))
(DTypeSig true "readerOfLib" (TyFun (TyCon "Unit") (TyCon "ModuleCtx")))
(DFunDef false "readerOfLib" (PWild) (EBlock (DoLet false false (PVar "g") (EApp (EVar "probeGraphCtx") (ELit LUnit))) (DoLet false false (PVar "lib") (EApp (EApp (EApp (EApp (EVar "declEnvModule") (EVar "g")) (ELit (LInt 1))) (ELit (LString "lib"))) (EApp (EApp (EVar "declaredIn") (ELit (LString "lib"))) (EApp (EVar "parse") (EVar "libSource"))))) (DoLet false false (PVar "user") (EApp (EApp (EApp (EApp (EVar "declEnvModule") (EVar "g")) (ELit (LInt 2))) (ELit (LString "user"))) (EListLit))) (DoLet false false (PVar "empty") (EFieldAccess (EFieldAccess (EVar "g") "declEnvsRef") "value")) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "g") "declEnvsRef")) (ERecordUpdate (EMethodRef "empty") ((fa "deMethods" (EApp (EApp (EApp (EVar "methodEnvGo") (EVar "g")) (EListLit (EVar "lib") (EVar "user"))) (EFieldAccess (EMethodRef "empty") "deMethods"))))))) (DoLet false false (PVar "m") (EApp (EApp (EVar "blankModuleCtx") (EVar "g")) (ELit (LString "user")))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "m") "mcCells") "methodScopeCtxRef")) (EApp (EVar "Some") (ETuple (EListLit) (ELit (LInt 2)))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "m") "mcCells") "bodyImplEnvRef")) (EApp (EVar "implAccFinish") (EApp (EApp (EVar "buildImplEnvGo") (EListLit (EVar "lib") (EVar "user"))) (EFieldAccess (EVar "emptyDeclEnvAcc") "daImpls"))))) (DoExpr (EVar "m"))))
(DTypeSig false "plainMarking" (TyCon "ModuleMarking"))
(DFunDef false "plainMarking" () (ERecordCreate "ModuleMarking" ((fa "mmCtx" (ERecordCreate "MarkCtx" ((fa "mcRp" (EVar "omEmpty")) (fa "mcAn" (EVar "omEmpty")) (fa "mcSm" (EListLit))))) (fa "mmTop" (EVar "omEmpty")) (fa "mmDictSet" (EApp (EVar "Ref") (EVar "omEmpty"))) (fa "mmUserNames" (EVar "omEmpty")) (fa "mmExterns" (EVar "omEmpty")))))
(DTypeSig true "mainOf" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Expr")))))
(DFunDef false "mainOf" ((PVar "m") (PVar "src")) (EBlock (DoLet false false (PVar "grouped") (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PTuple (PVar "name") (PVar "clause"))) (EApp (EApp (EApp (EVar "omInsert") (EVar "name")) (EBinOp "::" (EVar "clause") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "name")) (EVar "acc"))))) (EVar "acc")))) (EVar "omEmpty")) (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "d")) (EMatch (EVar "d") (arm (PCon "DFunDef" PWild (PVar "name") (PVar "pats") (PVar "body") PWild PWild) () (EListLit (ETuple (EVar "name") (ETuple (EVar "pats") (EVar "body"))))) (arm PWild () (EListLit))))) (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "src")))))) (DoLet false false (PVar "marked") (EApp (EApp (EApp (EApp (EVar "markGroupClauses") (EVar "plainMarking")) (EApp (EVar "envFor") (EVar "m"))) (EListLit (ELit (LString "main")))) (EVar "grouped"))) (DoExpr (EMatch (EApp (EApp (EVar "clausesOf") (ELit (LString "main"))) (EVar "marked")) (arm (PCons (PTuple PWild (PVar "body")) PWild) () (EApp (EVar "Some") (EVar "body"))) (arm (PList) () (EVar "None"))))))
(DTypeSig true "withMain" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyFun (TyCon "Expr") (TyCon "Expectation")) (TyCon "Expectation")))))
(DFunDef false "withMain" ((PVar "m") (PVar "src") (PVar "k")) (EMatch (EApp (EApp (EVar "mainOf") (EVar "m")) (EVar "src")) (arm (PCon "Some" (PVar "body")) () (EApp (EVar "k") (EVar "body"))) (arm (PCon "None") () (EApp (EApp (EVar "expectEqual") (ELit (LString "a source defining main"))) (EVar "src")))))
(DTypeSig true "scopedWith" (TyFun (TyCon "String") (TyCon "ModuleCtx")))
(DFunDef false "scopedWith" ((PVar "src")) (EBlock (DoLet false false (PVar "seed") (ERecordCreate "CheckRunSeed" ((fa "crsOracle" (EApp (EVar "buildOracle") (EApp (EApp (EMethodRef "map") (EApp (EVar "declaredAsData") (ELit (LString "m")))) (EApp (EVar "parse") (EVar "src"))))) (fa "crsWarnings" (EListLit))))) (DoExpr (EApp (EVar "inRootScope") (EApp (EApp (EApp (EVar "freshModuleCtx") (EApp (EVar "probeGraphCtx") (ELit LUnit))) (EVar "seed")) (ELit (LString "probe")))))))
(DTypeSig true "envWithData" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyCon "TcEnv"))))
(DFunDef false "envWithData" ((PVar "m") (PVar "src")) (EApp (EApp (EApp (EApp (EVar "declareData") (ELit (LString "m"))) (EVar "m")) (EApp (EVar "envFor") (EVar "m"))) (EVar "src")))
(DTypeSig true "declareData" (TyFun (TyCon "String") (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyCon "TcEnv"))))))
(DFunDef false "declareData" ((PVar "mid") (PVar "m") (PVar "env") (PVar "src")) (EBlock (DoLet false false (PVar "ds") (EApp (EApp (EMethodRef "map") (EApp (EVar "declaredAsData") (EVar "mid"))) (EApp (EVar "parse") (EVar "src")))) (DoLet false false (PVar "registered") (EApp (EApp (EApp (EMethodRef "fold") (EVar "registerData")) (EVar "env")) (EVar "ds"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "m") "mcGraph") "crossRun") "universeRecordPop")) (EApp (EApp (EApp (EVar "insertRecordPop") (EVar "m")) (EVar "ds")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "m") "mcGraph") "crossRun") "universeRecordPop") "value")))) (DoExpr (EVar "registered"))))
(DTypeSig false "declaredAsData" (TyFun (TyCon "String") (TyFun (TyCon "Decl") (TyCon "Decl"))))
(DFunDef false "declaredAsData" ((PVar "mid") (PAs "d" (PRec "DData" ((rf "dataOrigin" PWild)) false))) (EVariantUpdate "DData" (EVar "d") ((fa "dataOrigin" (EApp (EVar "OriginModule") (EVar "mid"))))))
(DFunDef false "declaredAsData" (PWild (PVar "d")) (EVar "d"))
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
(DFunDef false "genKinds" ((PVar "n")) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (EListLit) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EApp (EVar "randomInt") (ELit (LInt 0))) (ELit (LInt 3))) (EApp (EVar "genKinds") (EBinOp "-" (EVar "n") (ELit (LInt 1))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "nthInt" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Int"))))
(DFunDef false "nthInt" ((PVar "i") (PVar "xs")) (EMatch (EApp (EApp (EVar "drop") (EVar "i")) (EVar "xs")) (arm (PCons (PVar "x") PWild) () (EVar "x")) (arm (PList) () (ELit (LInt 3)))))
(DTypeSig true "shadowEnvOf" (TyFun (TyCon "Scheme") (TyFun (TyCon "Scheme") (TyFun (TyCon "ModuleCtx") (TyCon "TcEnv")))))
(DFunDef false "shadowEnvOf" ((PVar "method") (PVar "standalone") (PVar "m")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "m") "mcCells") "standaloneValuesRef")) (EApp (EApp (EApp (EVar "omInsert") (ELit (LString "size"))) (ELit LUnit)) (EVar "omEmpty")))) (DoExpr (EApp (EApp (EVar "extendBindings") (EApp (EVar "envFor") (EVar "m"))) (EListLit (ETuple (ELit (LString "size")) (EApp (EApp (EVar "bindingWithStandalone") (EApp (EVar "ordinaryEnvBinding") (EVar "method"))) (ETuple (EVar "ImportedStandalone") (ERecordCreate "ValueScheme" ((fa "vsScheme" (EVar "standalone")) (fa "vsDeclared" (EVar "None"))))))))))))
(DTypeSig true "methodOccurrence" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyCon "Expr"))))
(DFunDef false "methodOccurrence" ((PVar "m") (PVar "name")) (EBlock (DoLet false false (PVar "ev") (EApp (EApp (EVar "EvId") (ELit (LString "probe"))) (ELit (LInt 0)))) (DoLet false false (PVar "cell") (ERecordCreate "EvCell" ((fa "ecId" (EVar "ev")) (fa "ecIface" (EApp (EVar "Ref") (ELit (LString "")))) (fa "ecArity" (EApp (EVar "Ref") (EVar "None"))) (fa "ecTag" (EApp (EVar "Ref") (EVar "RNone"))) (fa "ecImpl" (EApp (EVar "Ref") (EListLit))) (fa "ecMeth" (EApp (EVar "Ref") (EListLit))) (fa "ecLoc" (EApp (EVar "Ref") (EVar "None"))) (fa "ecName" (EApp (EVar "Ref") (ELit (LString "")))) (fa "ecInner" (EApp (EVar "Ref") (EVar "innerNone")))))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "m") "mcGraph") "graphRun") "evCells")) (EApp (EApp (EVar "arrayMake") (ELit (LInt 1))) (EApp (EVar "Some") (EVar "cell"))))) (DoExpr (EApp (EApp (EApp (EVar "EMethodAt") (EVar "name")) (ELit (LString ""))) (EVar "ev")))))
(DTypeSig true "sizeScheme" (TyCon "Scheme"))
(DFunDef false "sizeScheme" () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Forall") (EListLit (ELit (LInt 1)))) (EListLit)) (EListLit)) (EListLit)) (EVar "pureRow")) (EApp (EApp (EApp (EVar "TFun") (EApp (EVar "varM") (ELit (LInt 1)))) (EVar "pureRow")) (EVar "intM"))))
