# META
source_lines=188
stages=DESUGAR,MARK
# SOURCE
-- Scoped effect collection. A capture observes performed rows without solving
-- them; inference allowances and signature constraints belong to the checker.
import types.effect_rows.{EffRow(..), Effvar, collectRows}
import types.effect_domain.{Param(..), canonParam, productNorm, subTopOf}
import types.effect_authority.{Authority(..), authJoin, authTop}
import types.repr.{Mono(..), normalize}
import frontend.ast.{
  Expr(..), Lit(..), Pat(..), Arm(..), LetBind(..), FunClause(..), patBoundNames
}
import support.util.{reverseL, lookupAssoc}

export
recordEffect : Ref (List EffRow) -> EffRow -> Unit
recordEffect _ (EffRow [] None) = ()
recordEffect ambient row = ambient := row :: !ambient

export
captureEffects : Ref (List EffRow) ->
  (List (Ref Effvar) -> Ref Effvar) ->
  (Unit -> a) ->
  (a, EffRow)
captureEffects ambient makeJoin body =
  let saved = !ambient
  ambient := []
  let result = body ()
  let performed = collectRows makeJoin (reverseL !ambient)
  ambient := saved
  (result, performed)

-- ── the abstraction α ──────────────────────────────────────────────────────
-- The authority a string-producing expression may denote, in the domain of
-- the label it flows to: a literal is that literal; a prefix-domain
-- concatenation is bounded by its left operand; `if`/`match` join their
-- branches; a `let`-bound name reads its definition; a value whose checked
-- type is qualified reads the qualifier; anything else is the domain's top.
-- Over-approximation is the only sound direction, so an unknown shape is top.
export
alphaOf : Param ->
  (String -> Option Mono) ->
  List (String, AlphaBinder) ->
  Expr ->
  Mono ->
  Authority
alphaOf top varType lets e ty = match alphaSyntax top varType lets e
  Some q => q
  None => typeAuthority top ty

-- A binder in the abstraction's scope, innermost first: a let with its
-- right-hand side, a parameter or pattern the environment types (read
-- through the checked type), or a binder inside the argument itself, whose
-- value nothing can see (the domain's top).
public export data AlphaBinder = ALet Expr | AParam | AOpaque

-- The qualifier a checked type carries, else the domain's top.
export
typeAuthority : Param -> Mono -> Authority
typeAuthority top ty = match normalize ty
  TQual _ q => q
  _ => authTop top

alphaSyntax : Param ->
  (String -> Option Mono) ->
  List (String, AlphaBinder) ->
  Expr ->
  Option Authority
alphaSyntax top vt lets (ELoc _ e) = alphaSyntax top vt lets e
alphaSyntax top vt lets (EDoOrigin _ e) = alphaSyntax top vt lets e
alphaSyntax top vt lets (EAnnot e _) = alphaSyntax top vt lets e
alphaSyntax top vt lets (EHeadAnnot e _) = alphaSyntax top vt lets e
alphaSyntax top _ _ (ELit (LString s)) = Some (literalAuthority top s)
alphaSyntax top vt lets (EBinOp op a _ _)
  | op == "++" = concatAuthority top vt lets a
alphaSyntax _ _ _ (EBinOp _ _ _ _) = None
alphaSyntax top vt lets (EVar x) = varAuthority top vt lets x
alphaSyntax top vt lets (EVarId x _) = varAuthority top vt lets x
alphaSyntax top vt lets (EVarAt x _) = varAuthority top vt lets x
alphaSyntax top vt lets (ELet _ _ (PVar x _) e1 e2) =
  alphaSyntax top vt ((x, ALet e1) :: lets) e2
alphaSyntax top vt lets (ELet _ _ pat _ e2) =
  alphaUnder top vt lets (patBoundNames pat) e2
alphaSyntax top vt lets (ELetGroup binds body) =
  alphaSyntax
    top
    vt
    (collectBinds binds (shadowed (flatMap letBindName binds) lets))
    body
alphaSyntax top vt lets (EIf _ t f) =
  joinBranches [alphaSyntax top vt lets t, alphaSyntax top vt lets f]
alphaSyntax top vt lets (EMatch scrut arms) =
  joinBranches (map (armAuthority top vt lets scrut) arms)
alphaSyntax _ _ _ _ = None

-- An arm that merely renames the scrutinee reads it; any other pattern binds
-- names whose values the abstraction cannot see, so they shadow to the top.
armAuthority : Param ->
  (String -> Option Mono) ->
  List (String, AlphaBinder) ->
  Expr ->
  Arm ->
  Option Authority
armAuthority top vt lets scrut (Arm (PVar x _) _ rhs) =
  alphaSyntax top vt ((x, ALet scrut) :: lets) rhs
armAuthority top vt lets _ (Arm pat _ rhs) =
  alphaUnder top vt lets (patBoundNames pat) rhs

-- The body of a binder whose names the abstraction cannot resolve: each name
-- enters the scope with no value, so it shadows every outer let and every
-- outer checked type of that name.
alphaUnder : Param ->
  (String -> Option Mono) ->
  List (String, AlphaBinder) ->
  List String ->
  Expr ->
  Option Authority
alphaUnder top vt lets names body =
  alphaSyntax top vt (shadowed names lets) body

shadowed : List String ->
  List (String, AlphaBinder) ->
  List (String, AlphaBinder)
shadowed names lets = map (n => (n, AOpaque)) names ++ lets

letBindName : LetBind -> List String
letBindName (LetBind n _) = [n]

-- A domain element from a literal: a Prefix pattern, a singleton Set, or a
-- product's primary axis; an atomic label abstracts every value to its top.
literalAuthority : Param -> String -> Authority
literalAuthority (PPrefix _) s = AConst (canonParam (PPrefix (Some s)))
literalAuthority (PSet _) s = AConst (PSet (Some [s]))
literalAuthority (PProduct _) s =
  AConst (productNorm [("Host", canonParam (PPrefix (Some s)))])
literalAuthority top _ = authTop top

-- In a prefix-shaped domain a justified left prefix bounds the whole; in the
-- Set domain appending changes the member, so the result is top.
concatAuthority : Param ->
  (String -> Option Mono) ->
  List (String, AlphaBinder) ->
  Expr ->
  Option Authority
concatAuthority (top@(PPrefix _)) vt lets a = alphaSyntax top vt lets a
concatAuthority (top@(PProduct _)) vt lets a = alphaSyntax top vt lets a
concatAuthority _ _ _ _ = None

-- A name reads its same-body `let` definition first, then its checked type.
varAuthority : Param ->
  (String -> Option Mono) ->
  List (String, AlphaBinder) ->
  String ->
  Option Authority
varAuthority top vt lets x = match letInScope x lets
  Some (ALet rhs, older) => alphaSyntax top vt older rhs
  Some (AOpaque, _) => None
  Some (AParam, _) => typedAuthority vt x
  None => typedAuthority vt x

typedAuthority : (String -> Option Mono) -> String -> Option Authority
typedAuthority vt x = match vt x
  Some ty => match normalize ty
    TQual _ q => Some q
    _ => None
  None => None

-- A let's right-hand side is read in the scope it was bound in: the entries
-- older than it, never a later rebinding of a name it mentions.
letInScope : String ->
  List (String, AlphaBinder) ->
  Option (AlphaBinder, List (String, AlphaBinder))
letInScope _ [] = None
letInScope x ((n, e) :: rest) =
  if n == x then Some (e, rest) else letInScope x rest

-- Every branch must be known for the join to say more than the top.
joinBranches : List (Option Authority) -> Option Authority
joinBranches [] = None
joinBranches [q] = q
joinBranches (q :: rest) = match (q, joinBranches rest)
  (Some a, Some b) => Some (authJoin a b)
  _ => None

collectBinds : List LetBind ->
  List (String, AlphaBinder) ->
  List (String, AlphaBinder)
collectBinds [] acc = acc
collectBinds ((LetBind n clauses) :: rest) acc = match clauses
  [FunClause [] rhs] => collectBinds rest ((n, ALet rhs) :: acc)
  _ => collectBinds rest acc
# DESUGAR
(DUse false (UseGroup ("types" "effect_rows") ((mem "EffRow" true) (mem "Effvar" false) (mem "collectRows" false))))
(DUse false (UseGroup ("types" "effect_domain") ((mem "Param" true) (mem "canonParam" false) (mem "productNorm" false) (mem "subTopOf" false))))
(DUse false (UseGroup ("types" "effect_authority") ((mem "Authority" true) (mem "authJoin" false) (mem "authTop" false))))
(DUse false (UseGroup ("types" "repr") ((mem "Mono" true) (mem "normalize" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Expr" true) (mem "Lit" true) (mem "Pat" true) (mem "Arm" true) (mem "LetBind" true) (mem "FunClause" true) (mem "patBoundNames" false))))
(DUse false (UseGroup ("support" "util") ((mem "reverseL" false) (mem "lookupAssoc" false))))
(DTypeSig true "recordEffect" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "EffRow"))) (TyFun (TyCon "EffRow") (TyCon "Unit"))))
(DFunDef false "recordEffect" (PWild (PCon "EffRow" (PList) (PCon "None"))) (ELit LUnit))
(DFunDef false "recordEffect" ((PVar "ambient") (PVar "row")) (EApp (EApp (EVar "setRef") (EVar "ambient")) (EBinOp "::" (EVar "row") (EUnOp "!" (EVar "ambient")))))
(DTypeSig true "captureEffects" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "EffRow"))) (TyFun (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyFun (TyFun (TyCon "Unit") (TyVar "a")) (TyTuple (TyVar "a") (TyCon "EffRow"))))))
(DFunDef false "captureEffects" ((PVar "ambient") (PVar "makeJoin") (PVar "body")) (EBlock (DoLet false false (PVar "saved") (EUnOp "!" (EVar "ambient"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "ambient")) (EListLit))) (DoLet false false (PVar "result") (EApp (EVar "body") (ELit LUnit))) (DoLet false false (PVar "performed") (EApp (EApp (EVar "collectRows") (EVar "makeJoin")) (EApp (EVar "reverseL") (EUnOp "!" (EVar "ambient"))))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "ambient")) (EVar "saved"))) (DoExpr (ETuple (EVar "result") (EVar "performed")))))
(DTypeSig true "alphaOf" (TyFun (TyCon "Param") (TyFun (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Mono"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "AlphaBinder"))) (TyFun (TyCon "Expr") (TyFun (TyCon "Mono") (TyCon "Authority")))))))
(DFunDef false "alphaOf" ((PVar "top") (PVar "varType") (PVar "lets") (PVar "e") (PVar "ty")) (EMatch (EApp (EApp (EApp (EApp (EVar "alphaSyntax") (EVar "top")) (EVar "varType")) (EVar "lets")) (EVar "e")) (arm (PCon "Some" (PVar "q")) () (EVar "q")) (arm (PCon "None") () (EApp (EApp (EVar "typeAuthority") (EVar "top")) (EVar "ty")))))
(DData Public "AlphaBinder" () ((variant "ALet" (ConPos (TyCon "Expr"))) (variant "AParam" (ConPos)) (variant "AOpaque" (ConPos))) ())
(DTypeSig true "typeAuthority" (TyFun (TyCon "Param") (TyFun (TyCon "Mono") (TyCon "Authority"))))
(DFunDef false "typeAuthority" ((PVar "top") (PVar "ty")) (EMatch (EApp (EVar "normalize") (EVar "ty")) (arm (PCon "TQual" PWild (PVar "q")) () (EVar "q")) (arm PWild () (EApp (EVar "authTop") (EVar "top")))))
(DTypeSig false "alphaSyntax" (TyFun (TyCon "Param") (TyFun (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Mono"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "AlphaBinder"))) (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Authority")))))))
(DFunDef false "alphaSyntax" ((PVar "top") (PVar "vt") (PVar "lets") (PCon "ELoc" PWild (PVar "e"))) (EApp (EApp (EApp (EApp (EVar "alphaSyntax") (EVar "top")) (EVar "vt")) (EVar "lets")) (EVar "e")))
(DFunDef false "alphaSyntax" ((PVar "top") (PVar "vt") (PVar "lets") (PCon "EDoOrigin" PWild (PVar "e"))) (EApp (EApp (EApp (EApp (EVar "alphaSyntax") (EVar "top")) (EVar "vt")) (EVar "lets")) (EVar "e")))
(DFunDef false "alphaSyntax" ((PVar "top") (PVar "vt") (PVar "lets") (PCon "EAnnot" (PVar "e") PWild)) (EApp (EApp (EApp (EApp (EVar "alphaSyntax") (EVar "top")) (EVar "vt")) (EVar "lets")) (EVar "e")))
(DFunDef false "alphaSyntax" ((PVar "top") (PVar "vt") (PVar "lets") (PCon "EHeadAnnot" (PVar "e") PWild)) (EApp (EApp (EApp (EApp (EVar "alphaSyntax") (EVar "top")) (EVar "vt")) (EVar "lets")) (EVar "e")))
(DFunDef false "alphaSyntax" ((PVar "top") PWild PWild (PCon "ELit" (PCon "LString" (PVar "s")))) (EApp (EVar "Some") (EApp (EApp (EVar "literalAuthority") (EVar "top")) (EVar "s"))))
(DFunDef false "alphaSyntax" ((PVar "top") (PVar "vt") (PVar "lets") (PCon "EBinOp" (PVar "op") (PVar "a") PWild PWild)) (EIf (EBinOp "==" (EVar "op") (ELit (LString "++"))) (EApp (EApp (EApp (EApp (EVar "concatAuthority") (EVar "top")) (EVar "vt")) (EVar "lets")) (EVar "a")) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "alphaSyntax" (PWild PWild PWild (PCon "EBinOp" PWild PWild PWild PWild)) (EVar "None"))
(DFunDef false "alphaSyntax" ((PVar "top") (PVar "vt") (PVar "lets") (PCon "EVar" (PVar "x"))) (EApp (EApp (EApp (EApp (EVar "varAuthority") (EVar "top")) (EVar "vt")) (EVar "lets")) (EVar "x")))
(DFunDef false "alphaSyntax" ((PVar "top") (PVar "vt") (PVar "lets") (PCon "EVarId" (PVar "x") PWild)) (EApp (EApp (EApp (EApp (EVar "varAuthority") (EVar "top")) (EVar "vt")) (EVar "lets")) (EVar "x")))
(DFunDef false "alphaSyntax" ((PVar "top") (PVar "vt") (PVar "lets") (PCon "EVarAt" (PVar "x") PWild)) (EApp (EApp (EApp (EApp (EVar "varAuthority") (EVar "top")) (EVar "vt")) (EVar "lets")) (EVar "x")))
(DFunDef false "alphaSyntax" ((PVar "top") (PVar "vt") (PVar "lets") (PCon "ELet" PWild PWild (PCon "PVar" (PVar "x") PWild) (PVar "e1") (PVar "e2"))) (EApp (EApp (EApp (EApp (EVar "alphaSyntax") (EVar "top")) (EVar "vt")) (EBinOp "::" (ETuple (EVar "x") (EApp (EVar "ALet") (EVar "e1"))) (EVar "lets"))) (EVar "e2")))
(DFunDef false "alphaSyntax" ((PVar "top") (PVar "vt") (PVar "lets") (PCon "ELet" PWild PWild (PVar "pat") PWild (PVar "e2"))) (EApp (EApp (EApp (EApp (EApp (EVar "alphaUnder") (EVar "top")) (EVar "vt")) (EVar "lets")) (EApp (EVar "patBoundNames") (EVar "pat"))) (EVar "e2")))
(DFunDef false "alphaSyntax" ((PVar "top") (PVar "vt") (PVar "lets") (PCon "ELetGroup" (PVar "binds") (PVar "body"))) (EApp (EApp (EApp (EApp (EVar "alphaSyntax") (EVar "top")) (EVar "vt")) (EApp (EApp (EVar "collectBinds") (EVar "binds")) (EApp (EApp (EVar "shadowed") (EApp (EApp (EVar "flatMap") (EVar "letBindName")) (EVar "binds"))) (EVar "lets")))) (EVar "body")))
(DFunDef false "alphaSyntax" ((PVar "top") (PVar "vt") (PVar "lets") (PCon "EIf" PWild (PVar "t") (PVar "f"))) (EApp (EVar "joinBranches") (EListLit (EApp (EApp (EApp (EApp (EVar "alphaSyntax") (EVar "top")) (EVar "vt")) (EVar "lets")) (EVar "t")) (EApp (EApp (EApp (EApp (EVar "alphaSyntax") (EVar "top")) (EVar "vt")) (EVar "lets")) (EVar "f")))))
(DFunDef false "alphaSyntax" ((PVar "top") (PVar "vt") (PVar "lets") (PCon "EMatch" (PVar "scrut") (PVar "arms"))) (EApp (EVar "joinBranches") (EApp (EApp (EVar "map") (EApp (EApp (EApp (EApp (EVar "armAuthority") (EVar "top")) (EVar "vt")) (EVar "lets")) (EVar "scrut"))) (EVar "arms"))))
(DFunDef false "alphaSyntax" (PWild PWild PWild PWild) (EVar "None"))
(DTypeSig false "armAuthority" (TyFun (TyCon "Param") (TyFun (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Mono"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "AlphaBinder"))) (TyFun (TyCon "Expr") (TyFun (TyCon "Arm") (TyApp (TyCon "Option") (TyCon "Authority"))))))))
(DFunDef false "armAuthority" ((PVar "top") (PVar "vt") (PVar "lets") (PVar "scrut") (PCon "Arm" (PCon "PVar" (PVar "x") PWild) PWild (PVar "rhs"))) (EApp (EApp (EApp (EApp (EVar "alphaSyntax") (EVar "top")) (EVar "vt")) (EBinOp "::" (ETuple (EVar "x") (EApp (EVar "ALet") (EVar "scrut"))) (EVar "lets"))) (EVar "rhs")))
(DFunDef false "armAuthority" ((PVar "top") (PVar "vt") (PVar "lets") PWild (PCon "Arm" (PVar "pat") PWild (PVar "rhs"))) (EApp (EApp (EApp (EApp (EApp (EVar "alphaUnder") (EVar "top")) (EVar "vt")) (EVar "lets")) (EApp (EVar "patBoundNames") (EVar "pat"))) (EVar "rhs")))
(DTypeSig false "alphaUnder" (TyFun (TyCon "Param") (TyFun (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Mono"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "AlphaBinder"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Authority"))))))))
(DFunDef false "alphaUnder" ((PVar "top") (PVar "vt") (PVar "lets") (PVar "names") (PVar "body")) (EApp (EApp (EApp (EApp (EVar "alphaSyntax") (EVar "top")) (EVar "vt")) (EApp (EApp (EVar "shadowed") (EVar "names")) (EVar "lets"))) (EVar "body")))
(DTypeSig false "shadowed" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "AlphaBinder"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "AlphaBinder"))))))
(DFunDef false "shadowed" ((PVar "names") (PVar "lets")) (EBinOp "++" (EApp (EApp (EVar "map") (ELam ((PVar "n")) (ETuple (EVar "n") (EVar "AOpaque")))) (EVar "names")) (EVar "lets")))
(DTypeSig false "letBindName" (TyFun (TyCon "LetBind") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "letBindName" ((PCon "LetBind" (PVar "n") PWild)) (EListLit (EVar "n")))
(DTypeSig false "literalAuthority" (TyFun (TyCon "Param") (TyFun (TyCon "String") (TyCon "Authority"))))
(DFunDef false "literalAuthority" ((PCon "PPrefix" PWild) (PVar "s")) (EApp (EVar "AConst") (EApp (EVar "canonParam") (EApp (EVar "PPrefix") (EApp (EVar "Some") (EVar "s"))))))
(DFunDef false "literalAuthority" ((PCon "PSet" PWild) (PVar "s")) (EApp (EVar "AConst") (EApp (EVar "PSet") (EApp (EVar "Some") (EListLit (EVar "s"))))))
(DFunDef false "literalAuthority" ((PCon "PProduct" PWild) (PVar "s")) (EApp (EVar "AConst") (EApp (EVar "productNorm") (EListLit (ETuple (ELit (LString "Host")) (EApp (EVar "canonParam") (EApp (EVar "PPrefix") (EApp (EVar "Some") (EVar "s")))))))))
(DFunDef false "literalAuthority" ((PVar "top") PWild) (EApp (EVar "authTop") (EVar "top")))
(DTypeSig false "concatAuthority" (TyFun (TyCon "Param") (TyFun (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Mono"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "AlphaBinder"))) (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Authority")))))))
(DFunDef false "concatAuthority" ((PAs "top" (PCon "PPrefix" PWild)) (PVar "vt") (PVar "lets") (PVar "a")) (EApp (EApp (EApp (EApp (EVar "alphaSyntax") (EVar "top")) (EVar "vt")) (EVar "lets")) (EVar "a")))
(DFunDef false "concatAuthority" ((PAs "top" (PCon "PProduct" PWild)) (PVar "vt") (PVar "lets") (PVar "a")) (EApp (EApp (EApp (EApp (EVar "alphaSyntax") (EVar "top")) (EVar "vt")) (EVar "lets")) (EVar "a")))
(DFunDef false "concatAuthority" (PWild PWild PWild PWild) (EVar "None"))
(DTypeSig false "varAuthority" (TyFun (TyCon "Param") (TyFun (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Mono"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "AlphaBinder"))) (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Authority")))))))
(DFunDef false "varAuthority" ((PVar "top") (PVar "vt") (PVar "lets") (PVar "x")) (EMatch (EApp (EApp (EVar "letInScope") (EVar "x")) (EVar "lets")) (arm (PCon "Some" (PTuple (PCon "ALet" (PVar "rhs")) (PVar "older"))) () (EApp (EApp (EApp (EApp (EVar "alphaSyntax") (EVar "top")) (EVar "vt")) (EVar "older")) (EVar "rhs"))) (arm (PCon "Some" (PTuple (PCon "AOpaque") PWild)) () (EVar "None")) (arm (PCon "Some" (PTuple (PCon "AParam") PWild)) () (EApp (EApp (EVar "typedAuthority") (EVar "vt")) (EVar "x"))) (arm (PCon "None") () (EApp (EApp (EVar "typedAuthority") (EVar "vt")) (EVar "x")))))
(DTypeSig false "typedAuthority" (TyFun (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Mono"))) (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Authority")))))
(DFunDef false "typedAuthority" ((PVar "vt") (PVar "x")) (EMatch (EApp (EVar "vt") (EVar "x")) (arm (PCon "Some" (PVar "ty")) () (EMatch (EApp (EVar "normalize") (EVar "ty")) (arm (PCon "TQual" PWild (PVar "q")) () (EApp (EVar "Some") (EVar "q"))) (arm PWild () (EVar "None")))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "letInScope" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "AlphaBinder"))) (TyApp (TyCon "Option") (TyTuple (TyCon "AlphaBinder") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "AlphaBinder"))))))))
(DFunDef false "letInScope" (PWild (PList)) (EVar "None"))
(DFunDef false "letInScope" ((PVar "x") (PCons (PTuple (PVar "n") (PVar "e")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "n") (EVar "x")) (EApp (EVar "Some") (ETuple (EVar "e") (EVar "rest"))) (EApp (EApp (EVar "letInScope") (EVar "x")) (EVar "rest"))))
(DTypeSig false "joinBranches" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Authority"))) (TyApp (TyCon "Option") (TyCon "Authority"))))
(DFunDef false "joinBranches" ((PList)) (EVar "None"))
(DFunDef false "joinBranches" ((PList (PVar "q"))) (EVar "q"))
(DFunDef false "joinBranches" ((PCons (PVar "q") (PVar "rest"))) (EMatch (ETuple (EVar "q") (EApp (EVar "joinBranches") (EVar "rest"))) (arm (PTuple (PCon "Some" (PVar "a")) (PCon "Some" (PVar "b"))) () (EApp (EVar "Some") (EApp (EApp (EVar "authJoin") (EVar "a")) (EVar "b")))) (arm PWild () (EVar "None"))))
(DTypeSig false "collectBinds" (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "AlphaBinder"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "AlphaBinder"))))))
(DFunDef false "collectBinds" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "collectBinds" ((PCons (PCon "LetBind" (PVar "n") (PVar "clauses")) (PVar "rest")) (PVar "acc")) (EMatch (EVar "clauses") (arm (PList (PCon "FunClause" (PList) (PVar "rhs"))) () (EApp (EApp (EVar "collectBinds") (EVar "rest")) (EBinOp "::" (ETuple (EVar "n") (EApp (EVar "ALet") (EVar "rhs"))) (EVar "acc")))) (arm PWild () (EApp (EApp (EVar "collectBinds") (EVar "rest")) (EVar "acc")))))
# MARK
(DUse false (UseGroup ("types" "effect_rows") ((mem "EffRow" true) (mem "Effvar" false) (mem "collectRows" false))))
(DUse false (UseGroup ("types" "effect_domain") ((mem "Param" true) (mem "canonParam" false) (mem "productNorm" false) (mem "subTopOf" false))))
(DUse false (UseGroup ("types" "effect_authority") ((mem "Authority" true) (mem "authJoin" false) (mem "authTop" false))))
(DUse false (UseGroup ("types" "repr") ((mem "Mono" true) (mem "normalize" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Expr" true) (mem "Lit" true) (mem "Pat" true) (mem "Arm" true) (mem "LetBind" true) (mem "FunClause" true) (mem "patBoundNames" false))))
(DUse false (UseGroup ("support" "util") ((mem "reverseL" false) (mem "lookupAssoc" false))))
(DTypeSig true "recordEffect" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "EffRow"))) (TyFun (TyCon "EffRow") (TyCon "Unit"))))
(DFunDef false "recordEffect" (PWild (PCon "EffRow" (PList) (PCon "None"))) (ELit LUnit))
(DFunDef false "recordEffect" ((PVar "ambient") (PVar "row")) (EApp (EApp (EVar "setRef") (EVar "ambient")) (EBinOp "::" (EVar "row") (EUnOp "!" (EVar "ambient")))))
(DTypeSig true "captureEffects" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "EffRow"))) (TyFun (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyFun (TyFun (TyCon "Unit") (TyVar "a")) (TyTuple (TyVar "a") (TyCon "EffRow"))))))
(DFunDef false "captureEffects" ((PVar "ambient") (PVar "makeJoin") (PVar "body")) (EBlock (DoLet false false (PVar "saved") (EUnOp "!" (EVar "ambient"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "ambient")) (EListLit))) (DoLet false false (PVar "result") (EApp (EVar "body") (ELit LUnit))) (DoLet false false (PVar "performed") (EApp (EApp (EVar "collectRows") (EVar "makeJoin")) (EApp (EVar "reverseL") (EUnOp "!" (EVar "ambient"))))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "ambient")) (EVar "saved"))) (DoExpr (ETuple (EVar "result") (EVar "performed")))))
(DTypeSig true "alphaOf" (TyFun (TyCon "Param") (TyFun (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Mono"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "AlphaBinder"))) (TyFun (TyCon "Expr") (TyFun (TyCon "Mono") (TyCon "Authority")))))))
(DFunDef false "alphaOf" ((PVar "top") (PVar "varType") (PVar "lets") (PVar "e") (PVar "ty")) (EMatch (EApp (EApp (EApp (EApp (EVar "alphaSyntax") (EVar "top")) (EVar "varType")) (EVar "lets")) (EVar "e")) (arm (PCon "Some" (PVar "q")) () (EVar "q")) (arm (PCon "None") () (EApp (EApp (EVar "typeAuthority") (EVar "top")) (EVar "ty")))))
(DData Public "AlphaBinder" () ((variant "ALet" (ConPos (TyCon "Expr"))) (variant "AParam" (ConPos)) (variant "AOpaque" (ConPos))) ())
(DTypeSig true "typeAuthority" (TyFun (TyCon "Param") (TyFun (TyCon "Mono") (TyCon "Authority"))))
(DFunDef false "typeAuthority" ((PVar "top") (PVar "ty")) (EMatch (EApp (EVar "normalize") (EVar "ty")) (arm (PCon "TQual" PWild (PVar "q")) () (EVar "q")) (arm PWild () (EApp (EVar "authTop") (EVar "top")))))
(DTypeSig false "alphaSyntax" (TyFun (TyCon "Param") (TyFun (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Mono"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "AlphaBinder"))) (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Authority")))))))
(DFunDef false "alphaSyntax" ((PVar "top") (PVar "vt") (PVar "lets") (PCon "ELoc" PWild (PVar "e"))) (EApp (EApp (EApp (EApp (EVar "alphaSyntax") (EVar "top")) (EVar "vt")) (EVar "lets")) (EVar "e")))
(DFunDef false "alphaSyntax" ((PVar "top") (PVar "vt") (PVar "lets") (PCon "EDoOrigin" PWild (PVar "e"))) (EApp (EApp (EApp (EApp (EVar "alphaSyntax") (EVar "top")) (EVar "vt")) (EVar "lets")) (EVar "e")))
(DFunDef false "alphaSyntax" ((PVar "top") (PVar "vt") (PVar "lets") (PCon "EAnnot" (PVar "e") PWild)) (EApp (EApp (EApp (EApp (EVar "alphaSyntax") (EVar "top")) (EVar "vt")) (EVar "lets")) (EVar "e")))
(DFunDef false "alphaSyntax" ((PVar "top") (PVar "vt") (PVar "lets") (PCon "EHeadAnnot" (PVar "e") PWild)) (EApp (EApp (EApp (EApp (EVar "alphaSyntax") (EVar "top")) (EVar "vt")) (EVar "lets")) (EVar "e")))
(DFunDef false "alphaSyntax" ((PVar "top") PWild PWild (PCon "ELit" (PCon "LString" (PVar "s")))) (EApp (EVar "Some") (EApp (EApp (EVar "literalAuthority") (EVar "top")) (EVar "s"))))
(DFunDef false "alphaSyntax" ((PVar "top") (PVar "vt") (PVar "lets") (PCon "EBinOp" (PVar "op") (PVar "a") PWild PWild)) (EIf (EBinOp "==" (EVar "op") (ELit (LString "++"))) (EApp (EApp (EApp (EApp (EVar "concatAuthority") (EVar "top")) (EVar "vt")) (EVar "lets")) (EVar "a")) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "alphaSyntax" (PWild PWild PWild (PCon "EBinOp" PWild PWild PWild PWild)) (EVar "None"))
(DFunDef false "alphaSyntax" ((PVar "top") (PVar "vt") (PVar "lets") (PCon "EVar" (PVar "x"))) (EApp (EApp (EApp (EApp (EVar "varAuthority") (EVar "top")) (EVar "vt")) (EVar "lets")) (EVar "x")))
(DFunDef false "alphaSyntax" ((PVar "top") (PVar "vt") (PVar "lets") (PCon "EVarId" (PVar "x") PWild)) (EApp (EApp (EApp (EApp (EVar "varAuthority") (EVar "top")) (EVar "vt")) (EVar "lets")) (EVar "x")))
(DFunDef false "alphaSyntax" ((PVar "top") (PVar "vt") (PVar "lets") (PCon "EVarAt" (PVar "x") PWild)) (EApp (EApp (EApp (EApp (EVar "varAuthority") (EVar "top")) (EVar "vt")) (EVar "lets")) (EVar "x")))
(DFunDef false "alphaSyntax" ((PVar "top") (PVar "vt") (PVar "lets") (PCon "ELet" PWild PWild (PCon "PVar" (PVar "x") PWild) (PVar "e1") (PVar "e2"))) (EApp (EApp (EApp (EApp (EVar "alphaSyntax") (EVar "top")) (EVar "vt")) (EBinOp "::" (ETuple (EVar "x") (EApp (EVar "ALet") (EVar "e1"))) (EVar "lets"))) (EVar "e2")))
(DFunDef false "alphaSyntax" ((PVar "top") (PVar "vt") (PVar "lets") (PCon "ELet" PWild PWild (PVar "pat") PWild (PVar "e2"))) (EApp (EApp (EApp (EApp (EApp (EVar "alphaUnder") (EVar "top")) (EVar "vt")) (EVar "lets")) (EApp (EVar "patBoundNames") (EVar "pat"))) (EVar "e2")))
(DFunDef false "alphaSyntax" ((PVar "top") (PVar "vt") (PVar "lets") (PCon "ELetGroup" (PVar "binds") (PVar "body"))) (EApp (EApp (EApp (EApp (EVar "alphaSyntax") (EVar "top")) (EVar "vt")) (EApp (EApp (EVar "collectBinds") (EVar "binds")) (EApp (EApp (EVar "shadowed") (EApp (EApp (EDictApp "flatMap") (EVar "letBindName")) (EVar "binds"))) (EVar "lets")))) (EVar "body")))
(DFunDef false "alphaSyntax" ((PVar "top") (PVar "vt") (PVar "lets") (PCon "EIf" PWild (PVar "t") (PVar "f"))) (EApp (EVar "joinBranches") (EListLit (EApp (EApp (EApp (EApp (EVar "alphaSyntax") (EVar "top")) (EVar "vt")) (EVar "lets")) (EVar "t")) (EApp (EApp (EApp (EApp (EVar "alphaSyntax") (EVar "top")) (EVar "vt")) (EVar "lets")) (EVar "f")))))
(DFunDef false "alphaSyntax" ((PVar "top") (PVar "vt") (PVar "lets") (PCon "EMatch" (PVar "scrut") (PVar "arms"))) (EApp (EVar "joinBranches") (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EApp (EVar "armAuthority") (EVar "top")) (EVar "vt")) (EVar "lets")) (EVar "scrut"))) (EVar "arms"))))
(DFunDef false "alphaSyntax" (PWild PWild PWild PWild) (EVar "None"))
(DTypeSig false "armAuthority" (TyFun (TyCon "Param") (TyFun (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Mono"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "AlphaBinder"))) (TyFun (TyCon "Expr") (TyFun (TyCon "Arm") (TyApp (TyCon "Option") (TyCon "Authority"))))))))
(DFunDef false "armAuthority" ((PVar "top") (PVar "vt") (PVar "lets") (PVar "scrut") (PCon "Arm" (PCon "PVar" (PVar "x") PWild) PWild (PVar "rhs"))) (EApp (EApp (EApp (EApp (EVar "alphaSyntax") (EVar "top")) (EVar "vt")) (EBinOp "::" (ETuple (EVar "x") (EApp (EVar "ALet") (EVar "scrut"))) (EVar "lets"))) (EVar "rhs")))
(DFunDef false "armAuthority" ((PVar "top") (PVar "vt") (PVar "lets") PWild (PCon "Arm" (PVar "pat") PWild (PVar "rhs"))) (EApp (EApp (EApp (EApp (EApp (EVar "alphaUnder") (EVar "top")) (EVar "vt")) (EVar "lets")) (EApp (EVar "patBoundNames") (EVar "pat"))) (EVar "rhs")))
(DTypeSig false "alphaUnder" (TyFun (TyCon "Param") (TyFun (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Mono"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "AlphaBinder"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Authority"))))))))
(DFunDef false "alphaUnder" ((PVar "top") (PVar "vt") (PVar "lets") (PVar "names") (PVar "body")) (EApp (EApp (EApp (EApp (EVar "alphaSyntax") (EVar "top")) (EVar "vt")) (EApp (EApp (EVar "shadowed") (EVar "names")) (EVar "lets"))) (EVar "body")))
(DTypeSig false "shadowed" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "AlphaBinder"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "AlphaBinder"))))))
(DFunDef false "shadowed" ((PVar "names") (PVar "lets")) (EBinOp "++" (EApp (EApp (EMethodRef "map") (ELam ((PVar "n")) (ETuple (EVar "n") (EVar "AOpaque")))) (EVar "names")) (EVar "lets")))
(DTypeSig false "letBindName" (TyFun (TyCon "LetBind") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "letBindName" ((PCon "LetBind" (PVar "n") PWild)) (EListLit (EVar "n")))
(DTypeSig false "literalAuthority" (TyFun (TyCon "Param") (TyFun (TyCon "String") (TyCon "Authority"))))
(DFunDef false "literalAuthority" ((PCon "PPrefix" PWild) (PVar "s")) (EApp (EVar "AConst") (EApp (EVar "canonParam") (EApp (EVar "PPrefix") (EApp (EVar "Some") (EVar "s"))))))
(DFunDef false "literalAuthority" ((PCon "PSet" PWild) (PVar "s")) (EApp (EVar "AConst") (EApp (EVar "PSet") (EApp (EVar "Some") (EListLit (EVar "s"))))))
(DFunDef false "literalAuthority" ((PCon "PProduct" PWild) (PVar "s")) (EApp (EVar "AConst") (EApp (EVar "productNorm") (EListLit (ETuple (ELit (LString "Host")) (EApp (EVar "canonParam") (EApp (EVar "PPrefix") (EApp (EVar "Some") (EVar "s")))))))))
(DFunDef false "literalAuthority" ((PVar "top") PWild) (EApp (EVar "authTop") (EVar "top")))
(DTypeSig false "concatAuthority" (TyFun (TyCon "Param") (TyFun (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Mono"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "AlphaBinder"))) (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Authority")))))))
(DFunDef false "concatAuthority" ((PAs "top" (PCon "PPrefix" PWild)) (PVar "vt") (PVar "lets") (PVar "a")) (EApp (EApp (EApp (EApp (EVar "alphaSyntax") (EVar "top")) (EVar "vt")) (EVar "lets")) (EVar "a")))
(DFunDef false "concatAuthority" ((PAs "top" (PCon "PProduct" PWild)) (PVar "vt") (PVar "lets") (PVar "a")) (EApp (EApp (EApp (EApp (EVar "alphaSyntax") (EVar "top")) (EVar "vt")) (EVar "lets")) (EVar "a")))
(DFunDef false "concatAuthority" (PWild PWild PWild PWild) (EVar "None"))
(DTypeSig false "varAuthority" (TyFun (TyCon "Param") (TyFun (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Mono"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "AlphaBinder"))) (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Authority")))))))
(DFunDef false "varAuthority" ((PVar "top") (PVar "vt") (PVar "lets") (PVar "x")) (EMatch (EApp (EApp (EVar "letInScope") (EVar "x")) (EVar "lets")) (arm (PCon "Some" (PTuple (PCon "ALet" (PVar "rhs")) (PVar "older"))) () (EApp (EApp (EApp (EApp (EVar "alphaSyntax") (EVar "top")) (EVar "vt")) (EVar "older")) (EVar "rhs"))) (arm (PCon "Some" (PTuple (PCon "AOpaque") PWild)) () (EVar "None")) (arm (PCon "Some" (PTuple (PCon "AParam") PWild)) () (EApp (EApp (EVar "typedAuthority") (EVar "vt")) (EVar "x"))) (arm (PCon "None") () (EApp (EApp (EVar "typedAuthority") (EVar "vt")) (EVar "x")))))
(DTypeSig false "typedAuthority" (TyFun (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Mono"))) (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Authority")))))
(DFunDef false "typedAuthority" ((PVar "vt") (PVar "x")) (EMatch (EApp (EVar "vt") (EVar "x")) (arm (PCon "Some" (PVar "ty")) () (EMatch (EApp (EVar "normalize") (EVar "ty")) (arm (PCon "TQual" PWild (PVar "q")) () (EApp (EVar "Some") (EVar "q"))) (arm PWild () (EVar "None")))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "letInScope" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "AlphaBinder"))) (TyApp (TyCon "Option") (TyTuple (TyCon "AlphaBinder") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "AlphaBinder"))))))))
(DFunDef false "letInScope" (PWild (PList)) (EVar "None"))
(DFunDef false "letInScope" ((PVar "x") (PCons (PTuple (PVar "n") (PVar "e")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "n") (EVar "x")) (EApp (EVar "Some") (ETuple (EVar "e") (EVar "rest"))) (EApp (EApp (EVar "letInScope") (EVar "x")) (EVar "rest"))))
(DTypeSig false "joinBranches" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Authority"))) (TyApp (TyCon "Option") (TyCon "Authority"))))
(DFunDef false "joinBranches" ((PList)) (EVar "None"))
(DFunDef false "joinBranches" ((PList (PVar "q"))) (EVar "q"))
(DFunDef false "joinBranches" ((PCons (PVar "q") (PVar "rest"))) (EMatch (ETuple (EVar "q") (EApp (EVar "joinBranches") (EVar "rest"))) (arm (PTuple (PCon "Some" (PVar "a")) (PCon "Some" (PVar "b"))) () (EApp (EVar "Some") (EApp (EApp (EVar "authJoin") (EVar "a")) (EVar "b")))) (arm PWild () (EVar "None"))))
(DTypeSig false "collectBinds" (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "AlphaBinder"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "AlphaBinder"))))))
(DFunDef false "collectBinds" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "collectBinds" ((PCons (PCon "LetBind" (PVar "n") (PVar "clauses")) (PVar "rest")) (PVar "acc")) (EMatch (EVar "clauses") (arm (PList (PCon "FunClause" (PList) (PVar "rhs"))) () (EApp (EApp (EVar "collectBinds") (EVar "rest")) (EBinOp "::" (ETuple (EVar "n") (EApp (EVar "ALet") (EVar "rhs"))) (EVar "acc")))) (arm PWild () (EApp (EApp (EVar "collectBinds") (EVar "rest")) (EVar "acc")))))
