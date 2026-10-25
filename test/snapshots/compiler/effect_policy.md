# META
source_lines=256
stages=DESUGAR,MARK
# SOURCE
-- compiler/types/effect_policy.mdk — does an entry's invocation summary fit a
-- policy?  A policy is a list of (label, written parameter) entries, the shape
-- a target profile's rows carry.  The verdict (`policyRefusals`) is decided
-- from the atoms and the grants alone; the call-chain explanation
-- (`viaChain`) is a separate entry point, called only on a refusal.
import frontend.ast.{
  EffParamTy(..),
  TyConOrigin(..),
  Decl(..),
  ExternDecl(..),
  Expr(..),
  Arm(..),
  Guard(..),
  DoStmt(..),
  LetBind(..),
  FunClause(..),
  FieldAssign(..),
}
import types.effect_authority.{authVars, authvarDefaultName}
import types.effect_rows.{
  effLabelOrigin,
  atomLabelOf,
  atomLabel,
  atomAuth,
  atomsUnion,
  renderAtom,
  Atom(..),
  effrowLabels,
}
import types.repr.{Scheme(..), Mono(..), normalize}
import types.effect_domain.{Param}
import types.capability_manifest.{
  EntryKey(..), ManifestRequest(..), InvocationProtocol(..),
  CapabilityManifest(..)
}
import types.manifest_publish.{freezeAtoms}
import types.capability_policy.{manifestAllowed, permitFrozen}
export import types.capability_policy.{PolicyVerdict(..), Permit(..), allOk}
import support.util.{
  sortUniqS, joinWith, reverseL, filterList, contains, anyList
}
import support.ordmap.{
  OrdMap, omEmpty, omFromPairs, omFromNames, omLookup, omHasKey
}

-- The legacy atom API enters the same cell-free policy judgment.
export
policyRefusals : List (String, Param) ->
  List Atom ->
  List (String, EffParamTy) ->
  PolicyVerdict
policyRefusals domains atoms policy =
  manifestAllowed
    domains
    CapabilityManifest {
      request = ManifestRequest {
        entry = EntryKey { moduleId = "", binding = "legacy" },
        protocol = HostInvocation,
      },
      atoms = freezeAtoms domains atoms,
    }
    policy

export
permitOf : List (String, Param) -> Atom -> List (String, EffParamTy) -> Permit
permitOf domains atom policy = match freezeAtoms domains [atom]
  [frozen] => permitFrozen domains frozen policy
  _ => Forbidden

-- Why an atom's authority is unresolved: the variables it still names.
export
unresolvedWhy : Atom -> String
unresolvedWhy a =
  let names =
    map (v => "`" ++ authvarDefaultName v ++ "`") (authVars (atomAuth a))
  match names
    [one] => "authority variable \{one}"
    _ => "authority variables \{joinWith ", " names}"

-- `"mod.Name"` for a module-declared label, the bare name for a builtin.
export
qualifiedKey : Atom -> String
qualifiedKey a = match effLabelOrigin (atomLabelOf a)
  OriginModule m => "\"\{m}.\{atomLabel a}\""
  _ => atomLabel a

-- ── the call graph ──────────────────────────────────────────────────────────
-- name → callees restricted to top-level names.  Keyed; on a repeated name the
-- first binding wins, as a first-match scan would.
export type CallGraph = OrdMap (List String)

-- name → the atoms calling it performs, for every effectful fn.
export type EffectTable = OrdMap (List Atom)

-- collectEVars: every EVar name referenced in an expression (conservative —
-- includes non-call uses, safe for the chain heuristic).  The desugared tree
-- has no EGuards/ESection/EBlock surface sugar, so those arms are omitted
-- (already lowered).
collectEVars : Expr -> List String
collectEVars (EVar n) = [n]
collectEVars (ELoc _ e) = collectEVars e
collectEVars (EMethodRef n) = [n]
collectEVars (EDictApp n) = [n]
collectEVars (EApp f x) = collectEVars f ++ collectEVars x
collectEVars (ELam _ body) = collectEVars body
collectEVars (ELet _ _ _ v body) = collectEVars v ++ collectEVars body
collectEVars (ELetGroup binds body) =
  concatMapCP collectBind binds ++ collectEVars body
collectEVars (EMatch e arms) = collectEVars e ++ concatMapCP collectArm arms
collectEVars (EIf c t f) = collectEVars c ++ collectEVars t ++ collectEVars f
collectEVars (EBinOp _ a b _) = collectEVars a ++ collectEVars b
collectEVars (EUnOp _ e _) = collectEVars e
collectEVars (EInfix _ a b) = collectEVars a ++ collectEVars b
collectEVars (EAnnot e _) = collectEVars e
collectEVars (EHeadAnnot e _) = collectEVars e
collectEVars (EFieldAccess e _ _) = collectEVars e
collectEVars (ERecordCreate _ flds) = concatMapCP collectFieldAssign flds
collectEVars (ERecordUpdate e flds _) =
  collectEVars e ++ concatMapCP collectFieldAssign flds
collectEVars (EVariantUpdate _ e flds) =
  collectEVars e ++ concatMapCP collectFieldAssign flds
collectEVars (ETuple es) = concatMapCP collectEVars es
collectEVars (EListLit es) = concatMapCP collectEVars es
collectEVars (EArrayLit es) = concatMapCP collectEVars es
collectEVars (ERangeList a b _) = collectEVars a ++ collectEVars b
collectEVars (ERangeArray a b _) = collectEVars a ++ collectEVars b
collectEVars (ESlice a b c _) =
  collectEVars a ++ collectEVars b ++ collectEVars c
collectEVars (EIndex a b) = collectEVars a ++ collectEVars b
collectEVars (EBlock stmts) = concatMapCP collectStmt stmts
collectEVars (EDo _ stmts) = concatMapCP collectStmt stmts
collectEVars _ = []

collectBind : LetBind -> List String
collectBind (LetBind _ clauses _ _) = concatMapCP collectClause clauses

collectClause : FunClause -> List String
collectClause (FunClause _ body) = collectEVars body

collectArm : Arm -> List String
collectArm (Arm _ guards body) =
  concatMapCP collectGuard guards ++ collectEVars body

collectGuard : Guard -> List String
collectGuard (GBool e) = collectEVars e
collectGuard (GBind _ e) = collectEVars e

collectFieldAssign : FieldAssign -> List String
collectFieldAssign (FieldAssign _ e) = collectEVars e

collectStmt : DoStmt -> List String
collectStmt (DoExpr e) = collectEVars e
collectStmt (DoBind _ e) = collectEVars e
collectStmt (DoLet _ _ _ e _) = collectEVars e
collectStmt (DoAssign _ e) = collectEVars e
collectStmt (DoFieldAssign _ _ e) = collectEVars e

concatMapCP : (a -> List b) -> List a -> List b
concatMapCP _ [] = []
concatMapCP f (x :: xs) = f x ++ concatMapCP f xs

-- A top-level name (DFunDef or DExtern), peeling DAttrib.
topName : Decl -> Option String
topName (DFunDef _ n _ _ _ _) = Some n
topName (DExtern (ExternDecl { edName = n, ... })) = Some n
topName (DAttrib _ d) = topName d
topName _ = None

-- (name, body-EVars) for each top-level DFunDef (externs have no body).
fnBody : Decl -> Option (String, List String)
fnBody (DFunDef _ n _ body _ _) = Some (n, collectEVars body)
fnBody (DAttrib _ d) = fnBody d
fnBody _ = None

export
buildCallGraph : List Decl -> CallGraph
buildCallGraph decls =
  let tops = omFromNames (collectOpts (map topName decls)) omEmpty
  let bodies = collectOpts (map fnBody decls)
  omFromPairs (reverseL (map (restrictBody tops) bodies)) omEmpty

restrictBody : OrdMap Unit -> (String, List String) -> (String, List String)
restrictBody tops (n, refs) = (n, filterList (r => omHasKey r tops) refs)

collectOpts : List (Option a) -> List a
collectOpts [] = []
collectOpts (None :: rest) = collectOpts rest
collectOpts ((Some x) :: rest) = x :: collectOpts rest

-- ── effectful callees ───────────────────────────────────────────────────────
-- (name, effect-atoms) for every fn whose CALL performs a non-empty effect set:
-- the chain below follows what calling a callee performs, not what a host
-- could reach through it.
export
fnEffectsTable : List (String, Scheme) -> EffectTable
fnEffectsTable schemes = omFromPairs (reverseL (effectfulPairs schemes)) omEmpty

effectfulPairs : List (String, Scheme) -> List (String, List Atom)
effectfulPairs [] = []
effectfulPairs ((name, sch) :: rest) = match callPerformed sch
  [] => effectfulPairs rest
  effs => (name, effs) :: effectfulPairs rest

-- What applying a binding performs: its forcing row and the rows along its
-- result spine, an effect index returned included.
callPerformed : Scheme -> List Atom
callPerformed (Forall _ _ _ _ force mono) =
  atomsUnion (effrowLabels force) (resultSpineRows mono)

resultSpineRows : Mono -> List Atom
resultSpineRows m = match normalize m
  TFun _ row res => atomsUnion (effrowLabels row) (resultSpineRows res)
  TEff row => effrowLabels row
  _ => []

-- Does fn `name` carry an atom whose LABEL is `label`?  (Chain reconstruction
-- stays label-keyed — the param does not participate in the call-graph trace.)
fnHasEffect : EffectTable -> String -> String -> Bool
fnHasEffect table name label = match omLookup name table
  None => False
  Some effs => anyList (a => atomLabel a == label) effs

-- ── the via-chain ───────────────────────────────────────────────────────────
-- From `start`, repeatedly hop to the lexicographically-smallest callee that
-- carries `forbiddenLabel`, stopping at a leaf or a revisit.  Called only to
-- explain a refusal.
export
viaChain : CallGraph -> EffectTable -> String -> String -> List String
viaChain callGraph effTable start forbiddenLabel =
  traceChain callGraph effTable forbiddenLabel start [start]

traceChain : CallGraph ->
  EffectTable ->
  String ->
  String ->
  List String ->
  List String
traceChain callGraph effTable forbiddenLabel fn visited =
  let callees = match omLookup fn callGraph
    None => []
    Some s => s
  match firstWithEffect effTable forbiddenLabel (sortUniqS callees)
    None => [fn]
    Some c =>
      if contains c visited then
        [fn, c]
      else
        fn :: traceChain callGraph effTable forbiddenLabel c (c :: visited)

firstWithEffect : EffectTable -> String -> List String -> Option String
firstWithEffect _ _ [] = None
firstWithEffect effTable label (c :: rest) =
  if fnHasEffect effTable c label then
    Some c
  else
    firstWithEffect effTable label rest
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "EffParamTy" true) (mem "TyConOrigin" true) (mem "Decl" true) (mem "ExternDecl" true) (mem "Expr" true) (mem "Arm" true) (mem "Guard" true) (mem "DoStmt" true) (mem "LetBind" true) (mem "FunClause" true) (mem "FieldAssign" true))))
(DUse false (UseGroup ("types" "effect_authority") ((mem "authVars" false) (mem "authvarDefaultName" false))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "effLabelOrigin" false) (mem "atomLabelOf" false) (mem "atomLabel" false) (mem "atomAuth" false) (mem "atomsUnion" false) (mem "renderAtom" false) (mem "Atom" true) (mem "effrowLabels" false))))
(DUse false (UseGroup ("types" "repr") ((mem "Scheme" true) (mem "Mono" true) (mem "normalize" false))))
(DUse false (UseGroup ("types" "effect_domain") ((mem "Param" false))))
(DUse false (UseGroup ("types" "capability_manifest") ((mem "EntryKey" true) (mem "ManifestRequest" true) (mem "InvocationProtocol" true) (mem "CapabilityManifest" true))))
(DUse false (UseGroup ("types" "manifest_publish") ((mem "freezeAtoms" false))))
(DUse false (UseGroup ("types" "capability_policy") ((mem "manifestAllowed" false) (mem "permitFrozen" false))))
(DUse true (UseGroup ("types" "capability_policy") ((mem "PolicyVerdict" true) (mem "Permit" true) (mem "allOk" false))))
(DUse false (UseGroup ("support" "util") ((mem "sortUniqS" false) (mem "joinWith" false) (mem "reverseL" false) (mem "filterList" false) (mem "contains" false) (mem "anyList" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omFromPairs" false) (mem "omFromNames" false) (mem "omLookup" false) (mem "omHasKey" false))))
(DTypeSig true "policyRefusals" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffParamTy"))) (TyCon "PolicyVerdict")))))
(DFunDef false "policyRefusals" ((PVar "domains") (PVar "atoms") (PVar "policy")) (EApp (EApp (EApp (EVar "manifestAllowed") (EVar "domains")) (ERecordCreate "CapabilityManifest" ((fa "request" (ERecordCreate "ManifestRequest" ((fa "entry" (ERecordCreate "EntryKey" ((fa "moduleId" (ELit (LString ""))) (fa "binding" (ELit (LString "legacy")))))) (fa "protocol" (EVar "HostInvocation"))))) (fa "atoms" (EApp (EApp (EVar "freezeAtoms") (EVar "domains")) (EVar "atoms")))))) (EVar "policy")))
(DTypeSig true "permitOf" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyFun (TyCon "Atom") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffParamTy"))) (TyCon "Permit")))))
(DFunDef false "permitOf" ((PVar "domains") (PVar "atom") (PVar "policy")) (EMatch (EApp (EApp (EVar "freezeAtoms") (EVar "domains")) (EListLit (EVar "atom"))) (arm (PList (PVar "frozen")) () (EApp (EApp (EApp (EVar "permitFrozen") (EVar "domains")) (EVar "frozen")) (EVar "policy"))) (arm PWild () (EVar "Forbidden"))))
(DTypeSig true "unresolvedWhy" (TyFun (TyCon "Atom") (TyCon "String")))
(DFunDef false "unresolvedWhy" ((PVar "a")) (EBlock (DoLet false false (PVar "names") (EApp (EApp (EVar "map") (ELam ((PVar "v")) (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "authvarDefaultName") (EVar "v"))) (ELit (LString "`"))))) (EApp (EVar "authVars") (EApp (EVar "atomAuth") (EVar "a"))))) (DoExpr (EMatch (EVar "names") (arm (PList (PVar "one")) () (EBinOp "++" (EBinOp "++" (ELit (LString "authority variable ")) (EApp (EVar "display") (EVar "one"))) (ELit (LString "")))) (arm PWild () (EBinOp "++" (EBinOp "++" (ELit (LString "authority variables ")) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EVar "names")))) (ELit (LString ""))))))))
(DTypeSig true "qualifiedKey" (TyFun (TyCon "Atom") (TyCon "String")))
(DFunDef false "qualifiedKey" ((PVar "a")) (EMatch (EApp (EVar "effLabelOrigin") (EApp (EVar "atomLabelOf") (EVar "a"))) (arm (PCon "OriginModule" (PVar "m")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "\"")) (EApp (EVar "display") (EVar "m"))) (ELit (LString "."))) (EApp (EVar "display") (EApp (EVar "atomLabel") (EVar "a")))) (ELit (LString "\"")))) (arm PWild () (EApp (EVar "atomLabel") (EVar "a")))))
(DTypeAlias true "CallGraph" () (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))))
(DTypeAlias true "EffectTable" () (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "Atom"))))
(DTypeSig false "collectEVars" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "collectEVars" ((PCon "EVar" (PVar "n"))) (EListLit (EVar "n")))
(DFunDef false "collectEVars" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "collectEVars") (EVar "e")))
(DFunDef false "collectEVars" ((PCon "EMethodRef" (PVar "n"))) (EListLit (EVar "n")))
(DFunDef false "collectEVars" ((PCon "EDictApp" (PVar "n"))) (EListLit (EVar "n")))
(DFunDef false "collectEVars" ((PCon "EApp" (PVar "f") (PVar "x"))) (EBinOp "++" (EApp (EVar "collectEVars") (EVar "f")) (EApp (EVar "collectEVars") (EVar "x"))))
(DFunDef false "collectEVars" ((PCon "ELam" PWild (PVar "body"))) (EApp (EVar "collectEVars") (EVar "body")))
(DFunDef false "collectEVars" ((PCon "ELet" PWild PWild PWild (PVar "v") (PVar "body"))) (EBinOp "++" (EApp (EVar "collectEVars") (EVar "v")) (EApp (EVar "collectEVars") (EVar "body"))))
(DFunDef false "collectEVars" ((PCon "ELetGroup" (PVar "binds") (PVar "body"))) (EBinOp "++" (EApp (EApp (EVar "concatMapCP") (EVar "collectBind")) (EVar "binds")) (EApp (EVar "collectEVars") (EVar "body"))))
(DFunDef false "collectEVars" ((PCon "EMatch" (PVar "e") (PVar "arms"))) (EBinOp "++" (EApp (EVar "collectEVars") (EVar "e")) (EApp (EApp (EVar "concatMapCP") (EVar "collectArm")) (EVar "arms"))))
(DFunDef false "collectEVars" ((PCon "EIf" (PVar "c") (PVar "t") (PVar "f"))) (EBinOp "++" (EBinOp "++" (EApp (EVar "collectEVars") (EVar "c")) (EApp (EVar "collectEVars") (EVar "t"))) (EApp (EVar "collectEVars") (EVar "f"))))
(DFunDef false "collectEVars" ((PCon "EBinOp" PWild (PVar "a") (PVar "b") PWild)) (EBinOp "++" (EApp (EVar "collectEVars") (EVar "a")) (EApp (EVar "collectEVars") (EVar "b"))))
(DFunDef false "collectEVars" ((PCon "EUnOp" PWild (PVar "e") PWild)) (EApp (EVar "collectEVars") (EVar "e")))
(DFunDef false "collectEVars" ((PCon "EInfix" PWild (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EVar "collectEVars") (EVar "a")) (EApp (EVar "collectEVars") (EVar "b"))))
(DFunDef false "collectEVars" ((PCon "EAnnot" (PVar "e") PWild)) (EApp (EVar "collectEVars") (EVar "e")))
(DFunDef false "collectEVars" ((PCon "EHeadAnnot" (PVar "e") PWild)) (EApp (EVar "collectEVars") (EVar "e")))
(DFunDef false "collectEVars" ((PCon "EFieldAccess" (PVar "e") PWild PWild)) (EApp (EVar "collectEVars") (EVar "e")))
(DFunDef false "collectEVars" ((PCon "ERecordCreate" PWild (PVar "flds"))) (EApp (EApp (EVar "concatMapCP") (EVar "collectFieldAssign")) (EVar "flds")))
(DFunDef false "collectEVars" ((PCon "ERecordUpdate" (PVar "e") (PVar "flds") PWild)) (EBinOp "++" (EApp (EVar "collectEVars") (EVar "e")) (EApp (EApp (EVar "concatMapCP") (EVar "collectFieldAssign")) (EVar "flds"))))
(DFunDef false "collectEVars" ((PCon "EVariantUpdate" PWild (PVar "e") (PVar "flds"))) (EBinOp "++" (EApp (EVar "collectEVars") (EVar "e")) (EApp (EApp (EVar "concatMapCP") (EVar "collectFieldAssign")) (EVar "flds"))))
(DFunDef false "collectEVars" ((PCon "ETuple" (PVar "es"))) (EApp (EApp (EVar "concatMapCP") (EVar "collectEVars")) (EVar "es")))
(DFunDef false "collectEVars" ((PCon "EListLit" (PVar "es"))) (EApp (EApp (EVar "concatMapCP") (EVar "collectEVars")) (EVar "es")))
(DFunDef false "collectEVars" ((PCon "EArrayLit" (PVar "es"))) (EApp (EApp (EVar "concatMapCP") (EVar "collectEVars")) (EVar "es")))
(DFunDef false "collectEVars" ((PCon "ERangeList" (PVar "a") (PVar "b") PWild)) (EBinOp "++" (EApp (EVar "collectEVars") (EVar "a")) (EApp (EVar "collectEVars") (EVar "b"))))
(DFunDef false "collectEVars" ((PCon "ERangeArray" (PVar "a") (PVar "b") PWild)) (EBinOp "++" (EApp (EVar "collectEVars") (EVar "a")) (EApp (EVar "collectEVars") (EVar "b"))))
(DFunDef false "collectEVars" ((PCon "ESlice" (PVar "a") (PVar "b") (PVar "c") PWild)) (EBinOp "++" (EBinOp "++" (EApp (EVar "collectEVars") (EVar "a")) (EApp (EVar "collectEVars") (EVar "b"))) (EApp (EVar "collectEVars") (EVar "c"))))
(DFunDef false "collectEVars" ((PCon "EIndex" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EVar "collectEVars") (EVar "a")) (EApp (EVar "collectEVars") (EVar "b"))))
(DFunDef false "collectEVars" ((PCon "EBlock" (PVar "stmts"))) (EApp (EApp (EVar "concatMapCP") (EVar "collectStmt")) (EVar "stmts")))
(DFunDef false "collectEVars" ((PCon "EDo" PWild (PVar "stmts"))) (EApp (EApp (EVar "concatMapCP") (EVar "collectStmt")) (EVar "stmts")))
(DFunDef false "collectEVars" (PWild) (EListLit))
(DTypeSig false "collectBind" (TyFun (TyCon "LetBind") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "collectBind" ((PCon "LetBind" PWild (PVar "clauses") PWild PWild)) (EApp (EApp (EVar "concatMapCP") (EVar "collectClause")) (EVar "clauses")))
(DTypeSig false "collectClause" (TyFun (TyCon "FunClause") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "collectClause" ((PCon "FunClause" PWild (PVar "body"))) (EApp (EVar "collectEVars") (EVar "body")))
(DTypeSig false "collectArm" (TyFun (TyCon "Arm") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "collectArm" ((PCon "Arm" PWild (PVar "guards") (PVar "body"))) (EBinOp "++" (EApp (EApp (EVar "concatMapCP") (EVar "collectGuard")) (EVar "guards")) (EApp (EVar "collectEVars") (EVar "body"))))
(DTypeSig false "collectGuard" (TyFun (TyCon "Guard") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "collectGuard" ((PCon "GBool" (PVar "e"))) (EApp (EVar "collectEVars") (EVar "e")))
(DFunDef false "collectGuard" ((PCon "GBind" PWild (PVar "e"))) (EApp (EVar "collectEVars") (EVar "e")))
(DTypeSig false "collectFieldAssign" (TyFun (TyCon "FieldAssign") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "collectFieldAssign" ((PCon "FieldAssign" PWild (PVar "e"))) (EApp (EVar "collectEVars") (EVar "e")))
(DTypeSig false "collectStmt" (TyFun (TyCon "DoStmt") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "collectStmt" ((PCon "DoExpr" (PVar "e"))) (EApp (EVar "collectEVars") (EVar "e")))
(DFunDef false "collectStmt" ((PCon "DoBind" PWild (PVar "e"))) (EApp (EVar "collectEVars") (EVar "e")))
(DFunDef false "collectStmt" ((PCon "DoLet" PWild PWild PWild (PVar "e") PWild)) (EApp (EVar "collectEVars") (EVar "e")))
(DFunDef false "collectStmt" ((PCon "DoAssign" PWild (PVar "e"))) (EApp (EVar "collectEVars") (EVar "e")))
(DFunDef false "collectStmt" ((PCon "DoFieldAssign" PWild PWild (PVar "e"))) (EApp (EVar "collectEVars") (EVar "e")))
(DTypeSig false "concatMapCP" (TyFun (TyFun (TyVar "a") (TyApp (TyCon "List") (TyVar "b"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "b")))))
(DFunDef false "concatMapCP" (PWild (PList)) (EListLit))
(DFunDef false "concatMapCP" ((PVar "f") (PCons (PVar "x") (PVar "xs"))) (EBinOp "++" (EApp (EVar "f") (EVar "x")) (EApp (EApp (EVar "concatMapCP") (EVar "f")) (EVar "xs"))))
(DTypeSig false "topName" (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "topName" ((PCon "DFunDef" PWild (PVar "n") PWild PWild PWild PWild)) (EApp (EVar "Some") (EVar "n")))
(DFunDef false "topName" ((PCon "DExtern" (PRec "ExternDecl" ((rf "edName" (PVar "n"))) true))) (EApp (EVar "Some") (EVar "n")))
(DFunDef false "topName" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "topName") (EVar "d")))
(DFunDef false "topName" (PWild) (EVar "None"))
(DTypeSig false "fnBody" (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "fnBody" ((PCon "DFunDef" PWild (PVar "n") PWild (PVar "body") PWild PWild)) (EApp (EVar "Some") (ETuple (EVar "n") (EApp (EVar "collectEVars") (EVar "body")))))
(DFunDef false "fnBody" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "fnBody") (EVar "d")))
(DFunDef false "fnBody" (PWild) (EVar "None"))
(DTypeSig true "buildCallGraph" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "CallGraph")))
(DFunDef false "buildCallGraph" ((PVar "decls")) (EBlock (DoLet false false (PVar "tops") (EApp (EApp (EVar "omFromNames") (EApp (EVar "collectOpts") (EApp (EApp (EVar "map") (EVar "topName")) (EVar "decls")))) (EVar "omEmpty"))) (DoLet false false (PVar "bodies") (EApp (EVar "collectOpts") (EApp (EApp (EVar "map") (EVar "fnBody")) (EVar "decls")))) (DoExpr (EApp (EApp (EVar "omFromPairs") (EApp (EVar "reverseL") (EApp (EApp (EVar "map") (EApp (EVar "restrictBody") (EVar "tops"))) (EVar "bodies")))) (EVar "omEmpty")))))
(DTypeSig false "restrictBody" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "restrictBody" ((PVar "tops") (PTuple (PVar "n") (PVar "refs"))) (ETuple (EVar "n") (EApp (EApp (EVar "filterList") (ELam ((PVar "r")) (EApp (EApp (EVar "omHasKey") (EVar "r")) (EVar "tops")))) (EVar "refs"))))
(DTypeSig false "collectOpts" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyVar "a"))) (TyApp (TyCon "List") (TyVar "a"))))
(DFunDef false "collectOpts" ((PList)) (EListLit))
(DFunDef false "collectOpts" ((PCons (PCon "None") (PVar "rest"))) (EApp (EVar "collectOpts") (EVar "rest")))
(DFunDef false "collectOpts" ((PCons (PCon "Some" (PVar "x")) (PVar "rest"))) (EBinOp "::" (EVar "x") (EApp (EVar "collectOpts") (EVar "rest"))))
(DTypeSig true "fnEffectsTable" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyCon "EffectTable")))
(DFunDef false "fnEffectsTable" ((PVar "schemes")) (EApp (EApp (EVar "omFromPairs") (EApp (EVar "reverseL") (EApp (EVar "effectfulPairs") (EVar "schemes")))) (EVar "omEmpty")))
(DTypeSig false "effectfulPairs" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Atom"))))))
(DFunDef false "effectfulPairs" ((PList)) (EListLit))
(DFunDef false "effectfulPairs" ((PCons (PTuple (PVar "name") (PVar "sch")) (PVar "rest"))) (EMatch (EApp (EVar "callPerformed") (EVar "sch")) (arm (PList) () (EApp (EVar "effectfulPairs") (EVar "rest"))) (arm (PVar "effs") () (EBinOp "::" (ETuple (EVar "name") (EVar "effs")) (EApp (EVar "effectfulPairs") (EVar "rest"))))))
(DTypeSig false "callPerformed" (TyFun (TyCon "Scheme") (TyApp (TyCon "List") (TyCon "Atom"))))
(DFunDef false "callPerformed" ((PCon "Forall" PWild PWild PWild PWild (PVar "force") (PVar "mono"))) (EApp (EApp (EVar "atomsUnion") (EApp (EVar "effrowLabels") (EVar "force"))) (EApp (EVar "resultSpineRows") (EVar "mono"))))
(DTypeSig false "resultSpineRows" (TyFun (TyCon "Mono") (TyApp (TyCon "List") (TyCon "Atom"))))
(DFunDef false "resultSpineRows" ((PVar "m")) (EMatch (EApp (EVar "normalize") (EVar "m")) (arm (PCon "TFun" PWild (PVar "row") (PVar "res")) () (EApp (EApp (EVar "atomsUnion") (EApp (EVar "effrowLabels") (EVar "row"))) (EApp (EVar "resultSpineRows") (EVar "res")))) (arm (PCon "TEff" (PVar "row")) () (EApp (EVar "effrowLabels") (EVar "row"))) (arm PWild () (EListLit))))
(DTypeSig false "fnHasEffect" (TyFun (TyCon "EffectTable") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool")))))
(DFunDef false "fnHasEffect" ((PVar "table") (PVar "name") (PVar "label")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "name")) (EVar "table")) (arm (PCon "None") () (EVar "False")) (arm (PCon "Some" (PVar "effs")) () (EApp (EApp (EVar "anyList") (ELam ((PVar "a")) (EBinOp "==" (EApp (EVar "atomLabel") (EVar "a")) (EVar "label")))) (EVar "effs")))))
(DTypeSig true "viaChain" (TyFun (TyCon "CallGraph") (TyFun (TyCon "EffectTable") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "viaChain" ((PVar "callGraph") (PVar "effTable") (PVar "start") (PVar "forbiddenLabel")) (EApp (EApp (EApp (EApp (EApp (EVar "traceChain") (EVar "callGraph")) (EVar "effTable")) (EVar "forbiddenLabel")) (EVar "start")) (EListLit (EVar "start"))))
(DTypeSig false "traceChain" (TyFun (TyCon "CallGraph") (TyFun (TyCon "EffectTable") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "traceChain" ((PVar "callGraph") (PVar "effTable") (PVar "forbiddenLabel") (PVar "fn") (PVar "visited")) (EBlock (DoLet false false (PVar "callees") (EMatch (EApp (EApp (EVar "omLookup") (EVar "fn")) (EVar "callGraph")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "s")) () (EVar "s")))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "firstWithEffect") (EVar "effTable")) (EVar "forbiddenLabel")) (EApp (EVar "sortUniqS") (EVar "callees"))) (arm (PCon "None") () (EListLit (EVar "fn"))) (arm (PCon "Some" (PVar "c")) () (EIf (EApp (EApp (EVar "contains") (EVar "c")) (EVar "visited")) (EListLit (EVar "fn") (EVar "c")) (EBinOp "::" (EVar "fn") (EApp (EApp (EApp (EApp (EApp (EVar "traceChain") (EVar "callGraph")) (EVar "effTable")) (EVar "forbiddenLabel")) (EVar "c")) (EBinOp "::" (EVar "c") (EVar "visited"))))))))))
(DTypeSig false "firstWithEffect" (TyFun (TyCon "EffectTable") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "firstWithEffect" (PWild PWild (PList)) (EVar "None"))
(DFunDef false "firstWithEffect" ((PVar "effTable") (PVar "label") (PCons (PVar "c") (PVar "rest"))) (EIf (EApp (EApp (EApp (EVar "fnHasEffect") (EVar "effTable")) (EVar "c")) (EVar "label")) (EApp (EVar "Some") (EVar "c")) (EApp (EApp (EApp (EVar "firstWithEffect") (EVar "effTable")) (EVar "label")) (EVar "rest"))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "EffParamTy" true) (mem "TyConOrigin" true) (mem "Decl" true) (mem "ExternDecl" true) (mem "Expr" true) (mem "Arm" true) (mem "Guard" true) (mem "DoStmt" true) (mem "LetBind" true) (mem "FunClause" true) (mem "FieldAssign" true))))
(DUse false (UseGroup ("types" "effect_authority") ((mem "authVars" false) (mem "authvarDefaultName" false))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "effLabelOrigin" false) (mem "atomLabelOf" false) (mem "atomLabel" false) (mem "atomAuth" false) (mem "atomsUnion" false) (mem "renderAtom" false) (mem "Atom" true) (mem "effrowLabels" false))))
(DUse false (UseGroup ("types" "repr") ((mem "Scheme" true) (mem "Mono" true) (mem "normalize" false))))
(DUse false (UseGroup ("types" "effect_domain") ((mem "Param" false))))
(DUse false (UseGroup ("types" "capability_manifest") ((mem "EntryKey" true) (mem "ManifestRequest" true) (mem "InvocationProtocol" true) (mem "CapabilityManifest" true))))
(DUse false (UseGroup ("types" "manifest_publish") ((mem "freezeAtoms" false))))
(DUse false (UseGroup ("types" "capability_policy") ((mem "manifestAllowed" false) (mem "permitFrozen" false))))
(DUse true (UseGroup ("types" "capability_policy") ((mem "PolicyVerdict" true) (mem "Permit" true) (mem "allOk" false))))
(DUse false (UseGroup ("support" "util") ((mem "sortUniqS" false) (mem "joinWith" false) (mem "reverseL" false) (mem "filterList" false) (mem "contains" false) (mem "anyList" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omFromPairs" false) (mem "omFromNames" false) (mem "omLookup" false) (mem "omHasKey" false))))
(DTypeSig true "policyRefusals" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffParamTy"))) (TyCon "PolicyVerdict")))))
(DFunDef false "policyRefusals" ((PVar "domains") (PVar "atoms") (PVar "policy")) (EApp (EApp (EApp (EVar "manifestAllowed") (EVar "domains")) (ERecordCreate "CapabilityManifest" ((fa "request" (ERecordCreate "ManifestRequest" ((fa "entry" (ERecordCreate "EntryKey" ((fa "moduleId" (ELit (LString ""))) (fa "binding" (ELit (LString "legacy")))))) (fa "protocol" (EVar "HostInvocation"))))) (fa "atoms" (EApp (EApp (EVar "freezeAtoms") (EVar "domains")) (EVar "atoms")))))) (EVar "policy")))
(DTypeSig true "permitOf" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyFun (TyCon "Atom") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffParamTy"))) (TyCon "Permit")))))
(DFunDef false "permitOf" ((PVar "domains") (PVar "atom") (PVar "policy")) (EMatch (EApp (EApp (EVar "freezeAtoms") (EVar "domains")) (EListLit (EVar "atom"))) (arm (PList (PVar "frozen")) () (EApp (EApp (EApp (EVar "permitFrozen") (EVar "domains")) (EVar "frozen")) (EVar "policy"))) (arm PWild () (EVar "Forbidden"))))
(DTypeSig true "unresolvedWhy" (TyFun (TyCon "Atom") (TyCon "String")))
(DFunDef false "unresolvedWhy" ((PVar "a")) (EBlock (DoLet false false (PVar "names") (EApp (EApp (EMethodRef "map") (ELam ((PVar "v")) (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "authvarDefaultName") (EVar "v"))) (ELit (LString "`"))))) (EApp (EVar "authVars") (EApp (EVar "atomAuth") (EVar "a"))))) (DoExpr (EMatch (EVar "names") (arm (PList (PVar "one")) () (EBinOp "++" (EBinOp "++" (ELit (LString "authority variable ")) (EApp (EMethodRef "display") (EVar "one"))) (ELit (LString "")))) (arm PWild () (EBinOp "++" (EBinOp "++" (ELit (LString "authority variables ")) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EVar "names")))) (ELit (LString ""))))))))
(DTypeSig true "qualifiedKey" (TyFun (TyCon "Atom") (TyCon "String")))
(DFunDef false "qualifiedKey" ((PVar "a")) (EMatch (EApp (EVar "effLabelOrigin") (EApp (EVar "atomLabelOf") (EVar "a"))) (arm (PCon "OriginModule" (PVar "m")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "\"")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "."))) (EApp (EMethodRef "display") (EApp (EVar "atomLabel") (EVar "a")))) (ELit (LString "\"")))) (arm PWild () (EApp (EVar "atomLabel") (EVar "a")))))
(DTypeAlias true "CallGraph" () (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))))
(DTypeAlias true "EffectTable" () (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "Atom"))))
(DTypeSig false "collectEVars" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "collectEVars" ((PCon "EVar" (PVar "n"))) (EListLit (EVar "n")))
(DFunDef false "collectEVars" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "collectEVars") (EVar "e")))
(DFunDef false "collectEVars" ((PCon "EMethodRef" (PVar "n"))) (EListLit (EVar "n")))
(DFunDef false "collectEVars" ((PCon "EDictApp" (PVar "n"))) (EListLit (EVar "n")))
(DFunDef false "collectEVars" ((PCon "EApp" (PVar "f") (PVar "x"))) (EBinOp "++" (EApp (EVar "collectEVars") (EVar "f")) (EApp (EVar "collectEVars") (EVar "x"))))
(DFunDef false "collectEVars" ((PCon "ELam" PWild (PVar "body"))) (EApp (EVar "collectEVars") (EVar "body")))
(DFunDef false "collectEVars" ((PCon "ELet" PWild PWild PWild (PVar "v") (PVar "body"))) (EBinOp "++" (EApp (EVar "collectEVars") (EVar "v")) (EApp (EVar "collectEVars") (EVar "body"))))
(DFunDef false "collectEVars" ((PCon "ELetGroup" (PVar "binds") (PVar "body"))) (EBinOp "++" (EApp (EApp (EVar "concatMapCP") (EVar "collectBind")) (EVar "binds")) (EApp (EVar "collectEVars") (EVar "body"))))
(DFunDef false "collectEVars" ((PCon "EMatch" (PVar "e") (PVar "arms"))) (EBinOp "++" (EApp (EVar "collectEVars") (EVar "e")) (EApp (EApp (EVar "concatMapCP") (EVar "collectArm")) (EVar "arms"))))
(DFunDef false "collectEVars" ((PCon "EIf" (PVar "c") (PVar "t") (PVar "f"))) (EBinOp "++" (EBinOp "++" (EApp (EVar "collectEVars") (EVar "c")) (EApp (EVar "collectEVars") (EVar "t"))) (EApp (EVar "collectEVars") (EVar "f"))))
(DFunDef false "collectEVars" ((PCon "EBinOp" PWild (PVar "a") (PVar "b") PWild)) (EBinOp "++" (EApp (EVar "collectEVars") (EVar "a")) (EApp (EVar "collectEVars") (EVar "b"))))
(DFunDef false "collectEVars" ((PCon "EUnOp" PWild (PVar "e") PWild)) (EApp (EVar "collectEVars") (EVar "e")))
(DFunDef false "collectEVars" ((PCon "EInfix" PWild (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EVar "collectEVars") (EVar "a")) (EApp (EVar "collectEVars") (EVar "b"))))
(DFunDef false "collectEVars" ((PCon "EAnnot" (PVar "e") PWild)) (EApp (EVar "collectEVars") (EVar "e")))
(DFunDef false "collectEVars" ((PCon "EHeadAnnot" (PVar "e") PWild)) (EApp (EVar "collectEVars") (EVar "e")))
(DFunDef false "collectEVars" ((PCon "EFieldAccess" (PVar "e") PWild PWild)) (EApp (EVar "collectEVars") (EVar "e")))
(DFunDef false "collectEVars" ((PCon "ERecordCreate" PWild (PVar "flds"))) (EApp (EApp (EVar "concatMapCP") (EVar "collectFieldAssign")) (EVar "flds")))
(DFunDef false "collectEVars" ((PCon "ERecordUpdate" (PVar "e") (PVar "flds") PWild)) (EBinOp "++" (EApp (EVar "collectEVars") (EVar "e")) (EApp (EApp (EVar "concatMapCP") (EVar "collectFieldAssign")) (EVar "flds"))))
(DFunDef false "collectEVars" ((PCon "EVariantUpdate" PWild (PVar "e") (PVar "flds"))) (EBinOp "++" (EApp (EVar "collectEVars") (EVar "e")) (EApp (EApp (EVar "concatMapCP") (EVar "collectFieldAssign")) (EVar "flds"))))
(DFunDef false "collectEVars" ((PCon "ETuple" (PVar "es"))) (EApp (EApp (EVar "concatMapCP") (EVar "collectEVars")) (EVar "es")))
(DFunDef false "collectEVars" ((PCon "EListLit" (PVar "es"))) (EApp (EApp (EVar "concatMapCP") (EVar "collectEVars")) (EVar "es")))
(DFunDef false "collectEVars" ((PCon "EArrayLit" (PVar "es"))) (EApp (EApp (EVar "concatMapCP") (EVar "collectEVars")) (EVar "es")))
(DFunDef false "collectEVars" ((PCon "ERangeList" (PVar "a") (PVar "b") PWild)) (EBinOp "++" (EApp (EVar "collectEVars") (EVar "a")) (EApp (EVar "collectEVars") (EVar "b"))))
(DFunDef false "collectEVars" ((PCon "ERangeArray" (PVar "a") (PVar "b") PWild)) (EBinOp "++" (EApp (EVar "collectEVars") (EVar "a")) (EApp (EVar "collectEVars") (EVar "b"))))
(DFunDef false "collectEVars" ((PCon "ESlice" (PVar "a") (PVar "b") (PVar "c") PWild)) (EBinOp "++" (EBinOp "++" (EApp (EVar "collectEVars") (EVar "a")) (EApp (EVar "collectEVars") (EVar "b"))) (EApp (EVar "collectEVars") (EVar "c"))))
(DFunDef false "collectEVars" ((PCon "EIndex" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EVar "collectEVars") (EVar "a")) (EApp (EVar "collectEVars") (EVar "b"))))
(DFunDef false "collectEVars" ((PCon "EBlock" (PVar "stmts"))) (EApp (EApp (EVar "concatMapCP") (EVar "collectStmt")) (EVar "stmts")))
(DFunDef false "collectEVars" ((PCon "EDo" PWild (PVar "stmts"))) (EApp (EApp (EVar "concatMapCP") (EVar "collectStmt")) (EVar "stmts")))
(DFunDef false "collectEVars" (PWild) (EListLit))
(DTypeSig false "collectBind" (TyFun (TyCon "LetBind") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "collectBind" ((PCon "LetBind" PWild (PVar "clauses") PWild PWild)) (EApp (EApp (EVar "concatMapCP") (EVar "collectClause")) (EVar "clauses")))
(DTypeSig false "collectClause" (TyFun (TyCon "FunClause") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "collectClause" ((PCon "FunClause" PWild (PVar "body"))) (EApp (EVar "collectEVars") (EVar "body")))
(DTypeSig false "collectArm" (TyFun (TyCon "Arm") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "collectArm" ((PCon "Arm" PWild (PVar "guards") (PVar "body"))) (EBinOp "++" (EApp (EApp (EVar "concatMapCP") (EVar "collectGuard")) (EVar "guards")) (EApp (EVar "collectEVars") (EVar "body"))))
(DTypeSig false "collectGuard" (TyFun (TyCon "Guard") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "collectGuard" ((PCon "GBool" (PVar "e"))) (EApp (EVar "collectEVars") (EVar "e")))
(DFunDef false "collectGuard" ((PCon "GBind" PWild (PVar "e"))) (EApp (EVar "collectEVars") (EVar "e")))
(DTypeSig false "collectFieldAssign" (TyFun (TyCon "FieldAssign") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "collectFieldAssign" ((PCon "FieldAssign" PWild (PVar "e"))) (EApp (EVar "collectEVars") (EVar "e")))
(DTypeSig false "collectStmt" (TyFun (TyCon "DoStmt") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "collectStmt" ((PCon "DoExpr" (PVar "e"))) (EApp (EVar "collectEVars") (EVar "e")))
(DFunDef false "collectStmt" ((PCon "DoBind" PWild (PVar "e"))) (EApp (EVar "collectEVars") (EVar "e")))
(DFunDef false "collectStmt" ((PCon "DoLet" PWild PWild PWild (PVar "e") PWild)) (EApp (EVar "collectEVars") (EVar "e")))
(DFunDef false "collectStmt" ((PCon "DoAssign" PWild (PVar "e"))) (EApp (EVar "collectEVars") (EVar "e")))
(DFunDef false "collectStmt" ((PCon "DoFieldAssign" PWild PWild (PVar "e"))) (EApp (EVar "collectEVars") (EVar "e")))
(DTypeSig false "concatMapCP" (TyFun (TyFun (TyVar "a") (TyApp (TyCon "List") (TyVar "b"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "b")))))
(DFunDef false "concatMapCP" (PWild (PList)) (EListLit))
(DFunDef false "concatMapCP" ((PVar "f") (PCons (PVar "x") (PVar "xs"))) (EBinOp "++" (EApp (EVar "f") (EVar "x")) (EApp (EApp (EVar "concatMapCP") (EVar "f")) (EVar "xs"))))
(DTypeSig false "topName" (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "topName" ((PCon "DFunDef" PWild (PVar "n") PWild PWild PWild PWild)) (EApp (EVar "Some") (EVar "n")))
(DFunDef false "topName" ((PCon "DExtern" (PRec "ExternDecl" ((rf "edName" (PVar "n"))) true))) (EApp (EVar "Some") (EVar "n")))
(DFunDef false "topName" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "topName") (EVar "d")))
(DFunDef false "topName" (PWild) (EVar "None"))
(DTypeSig false "fnBody" (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "fnBody" ((PCon "DFunDef" PWild (PVar "n") PWild (PVar "body") PWild PWild)) (EApp (EVar "Some") (ETuple (EVar "n") (EApp (EVar "collectEVars") (EVar "body")))))
(DFunDef false "fnBody" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "fnBody") (EVar "d")))
(DFunDef false "fnBody" (PWild) (EVar "None"))
(DTypeSig true "buildCallGraph" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "CallGraph")))
(DFunDef false "buildCallGraph" ((PVar "decls")) (EBlock (DoLet false false (PVar "tops") (EApp (EApp (EVar "omFromNames") (EApp (EVar "collectOpts") (EApp (EApp (EMethodRef "map") (EVar "topName")) (EVar "decls")))) (EVar "omEmpty"))) (DoLet false false (PVar "bodies") (EApp (EVar "collectOpts") (EApp (EApp (EMethodRef "map") (EVar "fnBody")) (EVar "decls")))) (DoExpr (EApp (EApp (EVar "omFromPairs") (EApp (EVar "reverseL") (EApp (EApp (EMethodRef "map") (EApp (EVar "restrictBody") (EVar "tops"))) (EVar "bodies")))) (EVar "omEmpty")))))
(DTypeSig false "restrictBody" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "restrictBody" ((PVar "tops") (PTuple (PVar "n") (PVar "refs"))) (ETuple (EVar "n") (EApp (EApp (EVar "filterList") (ELam ((PVar "r")) (EApp (EApp (EVar "omHasKey") (EVar "r")) (EVar "tops")))) (EVar "refs"))))
(DTypeSig false "collectOpts" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyVar "a"))) (TyApp (TyCon "List") (TyVar "a"))))
(DFunDef false "collectOpts" ((PList)) (EListLit))
(DFunDef false "collectOpts" ((PCons (PCon "None") (PVar "rest"))) (EApp (EVar "collectOpts") (EVar "rest")))
(DFunDef false "collectOpts" ((PCons (PCon "Some" (PVar "x")) (PVar "rest"))) (EBinOp "::" (EVar "x") (EApp (EVar "collectOpts") (EVar "rest"))))
(DTypeSig true "fnEffectsTable" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyCon "EffectTable")))
(DFunDef false "fnEffectsTable" ((PVar "schemes")) (EApp (EApp (EVar "omFromPairs") (EApp (EVar "reverseL") (EApp (EVar "effectfulPairs") (EVar "schemes")))) (EVar "omEmpty")))
(DTypeSig false "effectfulPairs" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Atom"))))))
(DFunDef false "effectfulPairs" ((PList)) (EListLit))
(DFunDef false "effectfulPairs" ((PCons (PTuple (PVar "name") (PVar "sch")) (PVar "rest"))) (EMatch (EApp (EVar "callPerformed") (EVar "sch")) (arm (PList) () (EApp (EVar "effectfulPairs") (EVar "rest"))) (arm (PVar "effs") () (EBinOp "::" (ETuple (EVar "name") (EVar "effs")) (EApp (EVar "effectfulPairs") (EVar "rest"))))))
(DTypeSig false "callPerformed" (TyFun (TyCon "Scheme") (TyApp (TyCon "List") (TyCon "Atom"))))
(DFunDef false "callPerformed" ((PCon "Forall" PWild PWild PWild PWild (PVar "force") (PVar "mono"))) (EApp (EApp (EVar "atomsUnion") (EApp (EVar "effrowLabels") (EVar "force"))) (EApp (EVar "resultSpineRows") (EVar "mono"))))
(DTypeSig false "resultSpineRows" (TyFun (TyCon "Mono") (TyApp (TyCon "List") (TyCon "Atom"))))
(DFunDef false "resultSpineRows" ((PVar "m")) (EMatch (EApp (EVar "normalize") (EVar "m")) (arm (PCon "TFun" PWild (PVar "row") (PVar "res")) () (EApp (EApp (EVar "atomsUnion") (EApp (EVar "effrowLabels") (EVar "row"))) (EApp (EVar "resultSpineRows") (EVar "res")))) (arm (PCon "TEff" (PVar "row")) () (EApp (EVar "effrowLabels") (EVar "row"))) (arm PWild () (EListLit))))
(DTypeSig false "fnHasEffect" (TyFun (TyCon "EffectTable") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool")))))
(DFunDef false "fnHasEffect" ((PVar "table") (PVar "name") (PVar "label")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "name")) (EVar "table")) (arm (PCon "None") () (EVar "False")) (arm (PCon "Some" (PVar "effs")) () (EApp (EApp (EVar "anyList") (ELam ((PVar "a")) (EBinOp "==" (EApp (EVar "atomLabel") (EVar "a")) (EVar "label")))) (EVar "effs")))))
(DTypeSig true "viaChain" (TyFun (TyCon "CallGraph") (TyFun (TyCon "EffectTable") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "viaChain" ((PVar "callGraph") (PVar "effTable") (PVar "start") (PVar "forbiddenLabel")) (EApp (EApp (EApp (EApp (EApp (EVar "traceChain") (EVar "callGraph")) (EVar "effTable")) (EVar "forbiddenLabel")) (EVar "start")) (EListLit (EVar "start"))))
(DTypeSig false "traceChain" (TyFun (TyCon "CallGraph") (TyFun (TyCon "EffectTable") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "traceChain" ((PVar "callGraph") (PVar "effTable") (PVar "forbiddenLabel") (PVar "fn") (PVar "visited")) (EBlock (DoLet false false (PVar "callees") (EMatch (EApp (EApp (EVar "omLookup") (EVar "fn")) (EVar "callGraph")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "s")) () (EVar "s")))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "firstWithEffect") (EVar "effTable")) (EVar "forbiddenLabel")) (EApp (EVar "sortUniqS") (EVar "callees"))) (arm (PCon "None") () (EListLit (EVar "fn"))) (arm (PCon "Some" (PVar "c")) () (EIf (EApp (EApp (EVar "contains") (EVar "c")) (EVar "visited")) (EListLit (EVar "fn") (EVar "c")) (EBinOp "::" (EVar "fn") (EApp (EApp (EApp (EApp (EApp (EVar "traceChain") (EVar "callGraph")) (EVar "effTable")) (EVar "forbiddenLabel")) (EVar "c")) (EBinOp "::" (EVar "c") (EVar "visited"))))))))))
(DTypeSig false "firstWithEffect" (TyFun (TyCon "EffectTable") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "firstWithEffect" (PWild PWild (PList)) (EVar "None"))
(DFunDef false "firstWithEffect" ((PVar "effTable") (PVar "label") (PCons (PVar "c") (PVar "rest"))) (EIf (EApp (EApp (EApp (EVar "fnHasEffect") (EVar "effTable")) (EVar "c")) (EVar "label")) (EApp (EVar "Some") (EVar "c")) (EApp (EApp (EApp (EVar "firstWithEffect") (EVar "effTable")) (EVar "label")) (EVar "rest"))))
