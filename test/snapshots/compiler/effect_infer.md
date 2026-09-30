# META
source_lines=332
stages=DESUGAR,MARK
# SOURCE
-- Scoped effect collection. A capture observes performed rows without solving
-- them; inference allowances and signature constraints belong to the checker.
import types.effect_rows.{EffRow(..), Effvar, collectRows}
import types.effect_domain.{
  Param(..), canonParam, productNorm, subTopOf, productPrimaryLift, domainKey
}
import types.effect_authority.{
  Authority(..), authJoin, authTop, authExtend, authAppend, authWidenValue,
  authDomainTop, authRetag
}
import types.repr.{Mono(..), normalize}
import frontend.ast.{
  Expr(..), Lit(..), Pat(..), Arm(..), LetBind(..), FunClause(..), DoStmt(..),
  TyConOrigin(..), patBoundNames, sameTyConHead
}
import support.util.{reverseL, lookupAssoc, mapOption}

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
-- the label it flows to: a literal, or a concatenation of literals, is that
-- literal; any other prefix-domain concatenation is its left operand extended
-- by the suffix (`concatAuthority`); `if`/`match` join their
-- branches; a `let`-bound name reads its definition; a value whose checked
-- type is qualified reads the qualifier; an interpolated part reads as its
-- operand written directly (`displayHead`); anything else is the domain's top.
-- Over-approximation is the only sound direction, so an unknown shape is top.
-- [displayIsPrelude] says whether `display`, where no binder inside the
-- argument rebinds it, is the prelude `Display` method.
export
alphaOf : Param ->
  (String -> Option Mono) ->
  Bool ->
  List (String, AlphaBinder) ->
  Expr ->
  Mono ->
  Authority
alphaOf top varType displayIsPrelude lets e ty =
  let env =
    AlphaEnv { aeVarType = varType, aeDisplayIsPrelude = displayIsPrelude }
  match alphaSyntax top env lets e
    Some q => q
    None => typeAuthority top ty

-- What the abstraction knows about the names an argument mentions: each
-- name's checked type, and whether `display` is the prelude method.
data AlphaEnv = AlphaEnv {
  aeVarType : String -> Option Mono,
  aeDisplayIsPrelude : Bool,
}

-- A binder in the abstraction's scope, innermost first: a let with its
-- right-hand side, a parameter or pattern the environment types (read
-- through the checked type), or a binder inside the argument itself, whose
-- value nothing can see (the domain's top).
public export data AlphaBinder = ALet Expr | AParam | AOpaque

-- The qualifier a checked type carries, else the domain's top. A qualifier
-- of another domain (a Product of another schema, a Prefix read at a Set) is
-- no element of this one, so it too is the top. The empty authority has no
-- domain and is an element of every one.
export
typeAuthority : Param -> Mono -> Authority
typeAuthority top ty = match normalize ty
  TQual _ q => qualifierIn top q
  _ => authTop top

qualifierIn : Param -> Authority -> Authority
qualifierIn top q = if inDomain top q then authRetag top q else authTop top

inDomain : Param -> Authority -> Bool
inDomain PUnit _ = True
inDomain top q = match authDomainTop q
  PUnit => True
  d => domainKey d == domainKey top

alphaSyntax : Param ->
  AlphaEnv ->
  List (String, AlphaBinder) ->
  Expr ->
  Option Authority
alphaSyntax top env lets (ELoc _ e) = alphaSyntax top env lets e
alphaSyntax top env lets (EDoOrigin _ e) = alphaSyntax top env lets e
alphaSyntax top env lets (EAnnot e _) = alphaSyntax top env lets e
alphaSyntax top env lets (EHeadAnnot e _) = alphaSyntax top env lets e
alphaSyntax top _ _ (ELit (LString s)) = Some (literalAuthority top s)
alphaSyntax top env lets (e@(EBinOp op a b _))
  | op == "++" = match exactString env lets e
    Some s => Some (literalAuthority top s)
    None =>
      if emptyString env lets a then
        alphaSyntax top env lets b
      else if emptyString env lets b then
        alphaSyntax top env lets a
      else
        concatAuthority top env lets a b
alphaSyntax _ _ _ (EBinOp _ _ _ _) = None
alphaSyntax top env lets (EVar x) = varAuthority top env lets x
alphaSyntax top env lets (EVarId x _) = varAuthority top env lets x
alphaSyntax top env lets (EVarAt x _) = varAuthority top env lets x
alphaSyntax top env lets (EDictAt x _) = varAuthority top env lets x
alphaSyntax top env lets (ELet _ _ (PVar x _) e1 e2) =
  alphaSyntax top env ((x, ALet e1) :: lets) e2
alphaSyntax top env lets (ELet _ _ pat _ e2) =
  alphaUnder top env lets (patBoundNames pat) e2
alphaSyntax top env lets (ELetGroup binds body) =
  alphaSyntax
    top
    env
    (collectBinds binds (shadowed (flatMap letBindName binds) lets))
    body
alphaSyntax top env lets (EBlock stmts) = blockAuthority top env lets stmts
alphaSyntax top env lets (EIf _ t f) =
  joinBranches [alphaSyntax top env lets t, alphaSyntax top env lets f]
alphaSyntax top env lets (EMatch scrut arms) =
  joinBranches (map (armAuthority top env lets scrut) arms)
alphaSyntax top env lets (EApp f x)
  | displayHead env lets f = alphaSyntax top (stringNames env) lets x
alphaSyntax _ _ _ _ = None

-- `display e`, which string interpolation lowers each part to, is `e` itself
-- when `display` is the prelude method and `e` is a `String`: the prelude's
-- `Display String` is the identity. A local, top-level or imported definition
-- of `display` denotes some other function, so under one the part is top.
displayHead : AlphaEnv -> List (String, AlphaBinder) -> Expr -> Bool
displayHead env lets (ELoc _ f) = displayHead env lets f
displayHead env lets (EVar x) = preludeDisplay env lets x
displayHead env lets (EVarId x _) = preludeDisplay env lets x
displayHead env lets (EMethodAt x seed _) =
  seed == "" && preludeDisplay env lets x
displayHead _ _ _ = False

preludeDisplay : AlphaEnv -> List (String, AlphaBinder) -> String -> Bool
preludeDisplay env lets x =
  x == "display" && env.aeDisplayIsPrelude && isNone (letInScope x lets)

-- The names a `display` operand is read through: only a qualified `String`
-- keeps its qualifier, since a qualified value of another type displays as a
-- different string. Every form the abstraction knows is then a `String`.
stringNames : AlphaEnv -> AlphaEnv
stringNames env = { env |
  aeVarType =
    x => match env.aeVarType x
      Some ty => if qualifiedString ty then Some ty else None
      None => None,
}

qualifiedString : Mono -> Bool
qualifiedString ty = match normalize ty
  TQual inner _ => match normalize inner
    TCon n o => sameTyConHead n o "String" OriginBuiltin
    _ => False
  _ => False

-- A block is its last statement, read in the scope its statements build: a
-- `let` of a name reads its definition, as the `let` expression does; a
-- patterned let, a bind or an assignment introduces names whose values the
-- abstraction cannot see. A block ending in a statement that is not an
-- expression has no string value to abstract.
blockAuthority : Param ->
  AlphaEnv ->
  List (String, AlphaBinder) ->
  List DoStmt ->
  Option Authority
blockAuthority top env lets [DoExpr e] = alphaSyntax top env lets e
blockAuthority top env lets (s :: rest@(_ :: _)) =
  blockAuthority top env (stmtScope s lets) rest
blockAuthority _ _ _ _ = None

stmtScope : DoStmt -> List (String, AlphaBinder) -> List (String, AlphaBinder)
stmtScope (DoLet _ _ (PVar x _) e) lets = (x, ALet e) :: lets
stmtScope (DoLet _ _ pat _) lets = shadowed (patBoundNames pat) lets
stmtScope (DoBind pat _) lets = shadowed (patBoundNames pat) lets
stmtScope (DoAssign x _) lets = shadowed [x] lets
stmtScope (DoExpr _) lets = lets
stmtScope (DoFieldAssign _ _ _) lets = lets

-- An arm that merely renames the scrutinee reads it; any other pattern binds
-- names whose values the abstraction cannot see, so they shadow to the top.
armAuthority : Param ->
  AlphaEnv ->
  List (String, AlphaBinder) ->
  Expr ->
  Arm ->
  Option Authority
armAuthority top env lets scrut (Arm (PVar x _) _ rhs) =
  alphaSyntax top env ((x, ALet scrut) :: lets) rhs
armAuthority top env lets _ (Arm pat _ rhs) =
  alphaUnder top env lets (patBoundNames pat) rhs

-- The body of a binder whose names the abstraction cannot resolve: each name
-- enters the scope with no value, so it shadows every outer let and every
-- outer checked type of that name.
alphaUnder : Param ->
  AlphaEnv ->
  List (String, AlphaBinder) ->
  List String ->
  Expr ->
  Option Authority
alphaUnder top env lets names body =
  alphaSyntax top env (shadowed names lets) body

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
literalAuthority (PPath _) s = AConst (canonParam (PPath (Some s)))
literalAuthority (PSet _) s = AConst (PSet (Some [s]))
literalAuthority (PProduct schema) s = AConst (productPrimaryLift schema s)
literalAuthority top _ = authTop top

-- In a prefix-shaped domain a justified constant left prefix bounds the
-- whole: a suffix the abstraction knows exactly is appended (`authAppend`),
-- any other extends the left operand to the pattern it begins (`authExtend`).
-- A left operand that is an authority variable extends to its domain's top.
-- In the Set domain appending changes the member, so the result is top.
concatAuthority : Param ->
  AlphaEnv ->
  List (String, AlphaBinder) ->
  Expr ->
  Expr ->
  Option Authority
concatAuthority (top@(PPrefix _)) env lets a b =
  mapOption (suffixed env lets b) (alphaSyntax top env lets a)
concatAuthority (top@(PPath _)) env lets a b =
  mapOption (suffixed env lets b) (alphaSyntax top env lets a)
concatAuthority (top@(PProduct _)) env lets a b =
  mapOption (suffixed env lets b) (alphaSyntax top env lets a)
concatAuthority _ _ _ _ _ = None

suffixed : AlphaEnv ->
  List (String, AlphaBinder) ->
  Expr ->
  Authority ->
  Authority
suffixed env lets b left = match exactString env lets b
  Some s => authAppend s left
  None => authExtend left

-- The string an expression denotes exactly: a literal, a concatenation of
-- two such, or an interpolated part whose operand is one.
exactString : AlphaEnv -> List (String, AlphaBinder) -> Expr -> Option String
exactString env lets (ELoc _ e) = exactString env lets e
exactString env lets (EDoOrigin _ e) = exactString env lets e
exactString env lets (EAnnot e _) = exactString env lets e
exactString env lets (EHeadAnnot e _) = exactString env lets e
exactString _ _ (ELit (LString s)) = Some s
exactString env lets (EBinOp op a b _)
  | op == "++" = match (exactString env lets a, exactString env lets b)
    (Some x, Some y) => Some (x ++ y)
    _ => None
exactString env lets (EApp f x)
  | displayHead env lets f = exactString env lets x
exactString _ _ _ = None

-- An operand that is exactly the empty string: appending it on either side
-- leaves the other operand's value, and so its authority, unchanged. String
-- interpolation lowers `"\{e}"` to `"" ++ display e ++ ""`.
emptyString : AlphaEnv -> List (String, AlphaBinder) -> Expr -> Bool
emptyString env lets e = match exactString env lets e
  Some s => s == ""
  None => False

-- A name reads its same-body `let` definition first, then its checked type.
varAuthority : Param ->
  AlphaEnv ->
  List (String, AlphaBinder) ->
  String ->
  Option Authority
varAuthority top env lets x = match letInScope x lets
  Some (ALet rhs, older) => alphaSyntax top env older rhs
  Some (AOpaque, _) => None
  Some (AParam, _) => typedAuthority top env x
  None => typedAuthority top env x

typedAuthority : Param -> AlphaEnv -> String -> Option Authority
typedAuthority top env x = match env.aeVarType x
  Some ty => match normalize ty
    TQual _ q => Some (qualifierIn top q)
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

-- Every branch must be known for the join to say more than the top. The
-- join is a value's, so past the cap it is widened (`authWidenValue`).
joinBranches : List (Option Authority) -> Option Authority
joinBranches [] = None
joinBranches [q] = q
joinBranches (q :: rest) = match (q, joinBranches rest)
  (Some a, Some b) => Some (authWidenValue (authJoin a b))
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
(DUse false (UseGroup ("types" "effect_domain") ((mem "Param" true) (mem "canonParam" false) (mem "productNorm" false) (mem "subTopOf" false) (mem "productPrimaryLift" false) (mem "domainKey" false))))
(DUse false (UseGroup ("types" "effect_authority") ((mem "Authority" true) (mem "authJoin" false) (mem "authTop" false) (mem "authExtend" false) (mem "authAppend" false) (mem "authWidenValue" false) (mem "authDomainTop" false) (mem "authRetag" false))))
(DUse false (UseGroup ("types" "repr") ((mem "Mono" true) (mem "normalize" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Expr" true) (mem "Lit" true) (mem "Pat" true) (mem "Arm" true) (mem "LetBind" true) (mem "FunClause" true) (mem "DoStmt" true) (mem "TyConOrigin" true) (mem "patBoundNames" false) (mem "sameTyConHead" false))))
(DUse false (UseGroup ("support" "util") ((mem "reverseL" false) (mem "lookupAssoc" false) (mem "mapOption" false))))
(DTypeSig true "recordEffect" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "EffRow"))) (TyFun (TyCon "EffRow") (TyCon "Unit"))))
(DFunDef false "recordEffect" (PWild (PCon "EffRow" (PList) (PCon "None"))) (ELit LUnit))
(DFunDef false "recordEffect" ((PVar "ambient") (PVar "row")) (EApp (EApp (EVar "setRef") (EVar "ambient")) (EBinOp "::" (EVar "row") (EUnOp "!" (EVar "ambient")))))
(DTypeSig true "captureEffects" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "EffRow"))) (TyFun (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyFun (TyFun (TyCon "Unit") (TyVar "a")) (TyTuple (TyVar "a") (TyCon "EffRow"))))))
(DFunDef false "captureEffects" ((PVar "ambient") (PVar "makeJoin") (PVar "body")) (EBlock (DoLet false false (PVar "saved") (EUnOp "!" (EVar "ambient"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "ambient")) (EListLit))) (DoLet false false (PVar "result") (EApp (EVar "body") (ELit LUnit))) (DoLet false false (PVar "performed") (EApp (EApp (EVar "collectRows") (EVar "makeJoin")) (EApp (EVar "reverseL") (EUnOp "!" (EVar "ambient"))))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "ambient")) (EVar "saved"))) (DoExpr (ETuple (EVar "result") (EVar "performed")))))
(DTypeSig true "alphaOf" (TyFun (TyCon "Param") (TyFun (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Mono"))) (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "AlphaBinder"))) (TyFun (TyCon "Expr") (TyFun (TyCon "Mono") (TyCon "Authority"))))))))
(DFunDef false "alphaOf" ((PVar "top") (PVar "varType") (PVar "displayIsPrelude") (PVar "lets") (PVar "e") (PVar "ty")) (EBlock (DoLet false false (PVar "env") (ERecordCreate "AlphaEnv" ((fa "aeVarType" (EVar "varType")) (fa "aeDisplayIsPrelude" (EVar "displayIsPrelude"))))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EVar "alphaSyntax") (EVar "top")) (EVar "env")) (EVar "lets")) (EVar "e")) (arm (PCon "Some" (PVar "q")) () (EVar "q")) (arm (PCon "None") () (EApp (EApp (EVar "typeAuthority") (EVar "top")) (EVar "ty")))))))
(DData Private "AlphaEnv" () ((variant "AlphaEnv" (ConNamed (field "aeVarType" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Mono")))) (field "aeDisplayIsPrelude" (TyCon "Bool"))))) ())
(DData Public "AlphaBinder" () ((variant "ALet" (ConPos (TyCon "Expr"))) (variant "AParam" (ConPos)) (variant "AOpaque" (ConPos))) ())
(DTypeSig true "typeAuthority" (TyFun (TyCon "Param") (TyFun (TyCon "Mono") (TyCon "Authority"))))
(DFunDef false "typeAuthority" ((PVar "top") (PVar "ty")) (EMatch (EApp (EVar "normalize") (EVar "ty")) (arm (PCon "TQual" PWild (PVar "q")) () (EApp (EApp (EVar "qualifierIn") (EVar "top")) (EVar "q"))) (arm PWild () (EApp (EVar "authTop") (EVar "top")))))
(DTypeSig false "qualifierIn" (TyFun (TyCon "Param") (TyFun (TyCon "Authority") (TyCon "Authority"))))
(DFunDef false "qualifierIn" ((PVar "top") (PVar "q")) (EIf (EApp (EApp (EVar "inDomain") (EVar "top")) (EVar "q")) (EApp (EApp (EVar "authRetag") (EVar "top")) (EVar "q")) (EApp (EVar "authTop") (EVar "top"))))
(DTypeSig false "inDomain" (TyFun (TyCon "Param") (TyFun (TyCon "Authority") (TyCon "Bool"))))
(DFunDef false "inDomain" ((PCon "PUnit") PWild) (EVar "True"))
(DFunDef false "inDomain" ((PVar "top") (PVar "q")) (EMatch (EApp (EVar "authDomainTop") (EVar "q")) (arm (PCon "PUnit") () (EVar "True")) (arm (PVar "d") () (EBinOp "==" (EApp (EVar "domainKey") (EVar "d")) (EApp (EVar "domainKey") (EVar "top"))))))
(DTypeSig false "alphaSyntax" (TyFun (TyCon "Param") (TyFun (TyCon "AlphaEnv") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "AlphaBinder"))) (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Authority")))))))
(DFunDef false "alphaSyntax" ((PVar "top") (PVar "env") (PVar "lets") (PCon "ELoc" PWild (PVar "e"))) (EApp (EApp (EApp (EApp (EVar "alphaSyntax") (EVar "top")) (EVar "env")) (EVar "lets")) (EVar "e")))
(DFunDef false "alphaSyntax" ((PVar "top") (PVar "env") (PVar "lets") (PCon "EDoOrigin" PWild (PVar "e"))) (EApp (EApp (EApp (EApp (EVar "alphaSyntax") (EVar "top")) (EVar "env")) (EVar "lets")) (EVar "e")))
(DFunDef false "alphaSyntax" ((PVar "top") (PVar "env") (PVar "lets") (PCon "EAnnot" (PVar "e") PWild)) (EApp (EApp (EApp (EApp (EVar "alphaSyntax") (EVar "top")) (EVar "env")) (EVar "lets")) (EVar "e")))
(DFunDef false "alphaSyntax" ((PVar "top") (PVar "env") (PVar "lets") (PCon "EHeadAnnot" (PVar "e") PWild)) (EApp (EApp (EApp (EApp (EVar "alphaSyntax") (EVar "top")) (EVar "env")) (EVar "lets")) (EVar "e")))
(DFunDef false "alphaSyntax" ((PVar "top") PWild PWild (PCon "ELit" (PCon "LString" (PVar "s")))) (EApp (EVar "Some") (EApp (EApp (EVar "literalAuthority") (EVar "top")) (EVar "s"))))
(DFunDef false "alphaSyntax" ((PVar "top") (PVar "env") (PVar "lets") (PAs "e" (PCon "EBinOp" (PVar "op") (PVar "a") (PVar "b") PWild))) (EIf (EBinOp "==" (EVar "op") (ELit (LString "++"))) (EMatch (EApp (EApp (EApp (EVar "exactString") (EVar "env")) (EVar "lets")) (EVar "e")) (arm (PCon "Some" (PVar "s")) () (EApp (EVar "Some") (EApp (EApp (EVar "literalAuthority") (EVar "top")) (EVar "s")))) (arm (PCon "None") () (EIf (EApp (EApp (EApp (EVar "emptyString") (EVar "env")) (EVar "lets")) (EVar "a")) (EApp (EApp (EApp (EApp (EVar "alphaSyntax") (EVar "top")) (EVar "env")) (EVar "lets")) (EVar "b")) (EIf (EApp (EApp (EApp (EVar "emptyString") (EVar "env")) (EVar "lets")) (EVar "b")) (EApp (EApp (EApp (EApp (EVar "alphaSyntax") (EVar "top")) (EVar "env")) (EVar "lets")) (EVar "a")) (EApp (EApp (EApp (EApp (EApp (EVar "concatAuthority") (EVar "top")) (EVar "env")) (EVar "lets")) (EVar "a")) (EVar "b")))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "alphaSyntax" (PWild PWild PWild (PCon "EBinOp" PWild PWild PWild PWild)) (EVar "None"))
(DFunDef false "alphaSyntax" ((PVar "top") (PVar "env") (PVar "lets") (PCon "EVar" (PVar "x"))) (EApp (EApp (EApp (EApp (EVar "varAuthority") (EVar "top")) (EVar "env")) (EVar "lets")) (EVar "x")))
(DFunDef false "alphaSyntax" ((PVar "top") (PVar "env") (PVar "lets") (PCon "EVarId" (PVar "x") PWild)) (EApp (EApp (EApp (EApp (EVar "varAuthority") (EVar "top")) (EVar "env")) (EVar "lets")) (EVar "x")))
(DFunDef false "alphaSyntax" ((PVar "top") (PVar "env") (PVar "lets") (PCon "EVarAt" (PVar "x") PWild)) (EApp (EApp (EApp (EApp (EVar "varAuthority") (EVar "top")) (EVar "env")) (EVar "lets")) (EVar "x")))
(DFunDef false "alphaSyntax" ((PVar "top") (PVar "env") (PVar "lets") (PCon "EDictAt" (PVar "x") PWild)) (EApp (EApp (EApp (EApp (EVar "varAuthority") (EVar "top")) (EVar "env")) (EVar "lets")) (EVar "x")))
(DFunDef false "alphaSyntax" ((PVar "top") (PVar "env") (PVar "lets") (PCon "ELet" PWild PWild (PCon "PVar" (PVar "x") PWild) (PVar "e1") (PVar "e2"))) (EApp (EApp (EApp (EApp (EVar "alphaSyntax") (EVar "top")) (EVar "env")) (EBinOp "::" (ETuple (EVar "x") (EApp (EVar "ALet") (EVar "e1"))) (EVar "lets"))) (EVar "e2")))
(DFunDef false "alphaSyntax" ((PVar "top") (PVar "env") (PVar "lets") (PCon "ELet" PWild PWild (PVar "pat") PWild (PVar "e2"))) (EApp (EApp (EApp (EApp (EApp (EVar "alphaUnder") (EVar "top")) (EVar "env")) (EVar "lets")) (EApp (EVar "patBoundNames") (EVar "pat"))) (EVar "e2")))
(DFunDef false "alphaSyntax" ((PVar "top") (PVar "env") (PVar "lets") (PCon "ELetGroup" (PVar "binds") (PVar "body"))) (EApp (EApp (EApp (EApp (EVar "alphaSyntax") (EVar "top")) (EVar "env")) (EApp (EApp (EVar "collectBinds") (EVar "binds")) (EApp (EApp (EVar "shadowed") (EApp (EApp (EVar "flatMap") (EVar "letBindName")) (EVar "binds"))) (EVar "lets")))) (EVar "body")))
(DFunDef false "alphaSyntax" ((PVar "top") (PVar "env") (PVar "lets") (PCon "EBlock" (PVar "stmts"))) (EApp (EApp (EApp (EApp (EVar "blockAuthority") (EVar "top")) (EVar "env")) (EVar "lets")) (EVar "stmts")))
(DFunDef false "alphaSyntax" ((PVar "top") (PVar "env") (PVar "lets") (PCon "EIf" PWild (PVar "t") (PVar "f"))) (EApp (EVar "joinBranches") (EListLit (EApp (EApp (EApp (EApp (EVar "alphaSyntax") (EVar "top")) (EVar "env")) (EVar "lets")) (EVar "t")) (EApp (EApp (EApp (EApp (EVar "alphaSyntax") (EVar "top")) (EVar "env")) (EVar "lets")) (EVar "f")))))
(DFunDef false "alphaSyntax" ((PVar "top") (PVar "env") (PVar "lets") (PCon "EMatch" (PVar "scrut") (PVar "arms"))) (EApp (EVar "joinBranches") (EApp (EApp (EVar "map") (EApp (EApp (EApp (EApp (EVar "armAuthority") (EVar "top")) (EVar "env")) (EVar "lets")) (EVar "scrut"))) (EVar "arms"))))
(DFunDef false "alphaSyntax" ((PVar "top") (PVar "env") (PVar "lets") (PCon "EApp" (PVar "f") (PVar "x"))) (EIf (EApp (EApp (EApp (EVar "displayHead") (EVar "env")) (EVar "lets")) (EVar "f")) (EApp (EApp (EApp (EApp (EVar "alphaSyntax") (EVar "top")) (EApp (EVar "stringNames") (EVar "env"))) (EVar "lets")) (EVar "x")) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "alphaSyntax" (PWild PWild PWild PWild) (EVar "None"))
(DTypeSig false "displayHead" (TyFun (TyCon "AlphaEnv") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "AlphaBinder"))) (TyFun (TyCon "Expr") (TyCon "Bool")))))
(DFunDef false "displayHead" ((PVar "env") (PVar "lets") (PCon "ELoc" PWild (PVar "f"))) (EApp (EApp (EApp (EVar "displayHead") (EVar "env")) (EVar "lets")) (EVar "f")))
(DFunDef false "displayHead" ((PVar "env") (PVar "lets") (PCon "EVar" (PVar "x"))) (EApp (EApp (EApp (EVar "preludeDisplay") (EVar "env")) (EVar "lets")) (EVar "x")))
(DFunDef false "displayHead" ((PVar "env") (PVar "lets") (PCon "EVarId" (PVar "x") PWild)) (EApp (EApp (EApp (EVar "preludeDisplay") (EVar "env")) (EVar "lets")) (EVar "x")))
(DFunDef false "displayHead" ((PVar "env") (PVar "lets") (PCon "EMethodAt" (PVar "x") (PVar "seed") PWild)) (EBinOp "&&" (EBinOp "==" (EVar "seed") (ELit (LString ""))) (EApp (EApp (EApp (EVar "preludeDisplay") (EVar "env")) (EVar "lets")) (EVar "x"))))
(DFunDef false "displayHead" (PWild PWild PWild) (EVar "False"))
(DTypeSig false "preludeDisplay" (TyFun (TyCon "AlphaEnv") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "AlphaBinder"))) (TyFun (TyCon "String") (TyCon "Bool")))))
(DFunDef false "preludeDisplay" ((PVar "env") (PVar "lets") (PVar "x")) (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "x") (ELit (LString "display"))) (EFieldAccess (EVar "env") "aeDisplayIsPrelude")) (EApp (EVar "isNone") (EApp (EApp (EVar "letInScope") (EVar "x")) (EVar "lets")))))
(DTypeSig false "stringNames" (TyFun (TyCon "AlphaEnv") (TyCon "AlphaEnv")))
(DFunDef false "stringNames" ((PVar "env")) (ERecordUpdate (EVar "env") ((fa "aeVarType" (ELam ((PVar "x")) (EMatch (EApp (EFieldAccess (EVar "env") "aeVarType") (EVar "x")) (arm (PCon "Some" (PVar "ty")) () (EIf (EApp (EVar "qualifiedString") (EVar "ty")) (EApp (EVar "Some") (EVar "ty")) (EVar "None"))) (arm (PCon "None") () (EVar "None"))))))))
(DTypeSig false "qualifiedString" (TyFun (TyCon "Mono") (TyCon "Bool")))
(DFunDef false "qualifiedString" ((PVar "ty")) (EMatch (EApp (EVar "normalize") (EVar "ty")) (arm (PCon "TQual" (PVar "inner") PWild) () (EMatch (EApp (EVar "normalize") (EVar "inner")) (arm (PCon "TCon" (PVar "n") (PVar "o")) () (EApp (EApp (EApp (EApp (EVar "sameTyConHead") (EVar "n")) (EVar "o")) (ELit (LString "String"))) (EVar "OriginBuiltin"))) (arm PWild () (EVar "False")))) (arm PWild () (EVar "False"))))
(DTypeSig false "blockAuthority" (TyFun (TyCon "Param") (TyFun (TyCon "AlphaEnv") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "AlphaBinder"))) (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyApp (TyCon "Option") (TyCon "Authority")))))))
(DFunDef false "blockAuthority" ((PVar "top") (PVar "env") (PVar "lets") (PList (PCon "DoExpr" (PVar "e")))) (EApp (EApp (EApp (EApp (EVar "alphaSyntax") (EVar "top")) (EVar "env")) (EVar "lets")) (EVar "e")))
(DFunDef false "blockAuthority" ((PVar "top") (PVar "env") (PVar "lets") (PCons (PVar "s") (PAs "rest" (PCons PWild PWild)))) (EApp (EApp (EApp (EApp (EVar "blockAuthority") (EVar "top")) (EVar "env")) (EApp (EApp (EVar "stmtScope") (EVar "s")) (EVar "lets"))) (EVar "rest")))
(DFunDef false "blockAuthority" (PWild PWild PWild PWild) (EVar "None"))
(DTypeSig false "stmtScope" (TyFun (TyCon "DoStmt") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "AlphaBinder"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "AlphaBinder"))))))
(DFunDef false "stmtScope" ((PCon "DoLet" PWild PWild (PCon "PVar" (PVar "x") PWild) (PVar "e")) (PVar "lets")) (EBinOp "::" (ETuple (EVar "x") (EApp (EVar "ALet") (EVar "e"))) (EVar "lets")))
(DFunDef false "stmtScope" ((PCon "DoLet" PWild PWild (PVar "pat") PWild) (PVar "lets")) (EApp (EApp (EVar "shadowed") (EApp (EVar "patBoundNames") (EVar "pat"))) (EVar "lets")))
(DFunDef false "stmtScope" ((PCon "DoBind" (PVar "pat") PWild) (PVar "lets")) (EApp (EApp (EVar "shadowed") (EApp (EVar "patBoundNames") (EVar "pat"))) (EVar "lets")))
(DFunDef false "stmtScope" ((PCon "DoAssign" (PVar "x") PWild) (PVar "lets")) (EApp (EApp (EVar "shadowed") (EListLit (EVar "x"))) (EVar "lets")))
(DFunDef false "stmtScope" ((PCon "DoExpr" PWild) (PVar "lets")) (EVar "lets"))
(DFunDef false "stmtScope" ((PCon "DoFieldAssign" PWild PWild PWild) (PVar "lets")) (EVar "lets"))
(DTypeSig false "armAuthority" (TyFun (TyCon "Param") (TyFun (TyCon "AlphaEnv") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "AlphaBinder"))) (TyFun (TyCon "Expr") (TyFun (TyCon "Arm") (TyApp (TyCon "Option") (TyCon "Authority"))))))))
(DFunDef false "armAuthority" ((PVar "top") (PVar "env") (PVar "lets") (PVar "scrut") (PCon "Arm" (PCon "PVar" (PVar "x") PWild) PWild (PVar "rhs"))) (EApp (EApp (EApp (EApp (EVar "alphaSyntax") (EVar "top")) (EVar "env")) (EBinOp "::" (ETuple (EVar "x") (EApp (EVar "ALet") (EVar "scrut"))) (EVar "lets"))) (EVar "rhs")))
(DFunDef false "armAuthority" ((PVar "top") (PVar "env") (PVar "lets") PWild (PCon "Arm" (PVar "pat") PWild (PVar "rhs"))) (EApp (EApp (EApp (EApp (EApp (EVar "alphaUnder") (EVar "top")) (EVar "env")) (EVar "lets")) (EApp (EVar "patBoundNames") (EVar "pat"))) (EVar "rhs")))
(DTypeSig false "alphaUnder" (TyFun (TyCon "Param") (TyFun (TyCon "AlphaEnv") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "AlphaBinder"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Authority"))))))))
(DFunDef false "alphaUnder" ((PVar "top") (PVar "env") (PVar "lets") (PVar "names") (PVar "body")) (EApp (EApp (EApp (EApp (EVar "alphaSyntax") (EVar "top")) (EVar "env")) (EApp (EApp (EVar "shadowed") (EVar "names")) (EVar "lets"))) (EVar "body")))
(DTypeSig false "shadowed" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "AlphaBinder"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "AlphaBinder"))))))
(DFunDef false "shadowed" ((PVar "names") (PVar "lets")) (EBinOp "++" (EApp (EApp (EVar "map") (ELam ((PVar "n")) (ETuple (EVar "n") (EVar "AOpaque")))) (EVar "names")) (EVar "lets")))
(DTypeSig false "letBindName" (TyFun (TyCon "LetBind") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "letBindName" ((PCon "LetBind" (PVar "n") PWild)) (EListLit (EVar "n")))
(DTypeSig false "literalAuthority" (TyFun (TyCon "Param") (TyFun (TyCon "String") (TyCon "Authority"))))
(DFunDef false "literalAuthority" ((PCon "PPrefix" PWild) (PVar "s")) (EApp (EVar "AConst") (EApp (EVar "canonParam") (EApp (EVar "PPrefix") (EApp (EVar "Some") (EVar "s"))))))
(DFunDef false "literalAuthority" ((PCon "PPath" PWild) (PVar "s")) (EApp (EVar "AConst") (EApp (EVar "canonParam") (EApp (EVar "PPath") (EApp (EVar "Some") (EVar "s"))))))
(DFunDef false "literalAuthority" ((PCon "PSet" PWild) (PVar "s")) (EApp (EVar "AConst") (EApp (EVar "PSet") (EApp (EVar "Some") (EListLit (EVar "s"))))))
(DFunDef false "literalAuthority" ((PCon "PProduct" (PVar "schema")) (PVar "s")) (EApp (EVar "AConst") (EApp (EApp (EVar "productPrimaryLift") (EVar "schema")) (EVar "s"))))
(DFunDef false "literalAuthority" ((PVar "top") PWild) (EApp (EVar "authTop") (EVar "top")))
(DTypeSig false "concatAuthority" (TyFun (TyCon "Param") (TyFun (TyCon "AlphaEnv") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "AlphaBinder"))) (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Authority"))))))))
(DFunDef false "concatAuthority" ((PAs "top" (PCon "PPrefix" PWild)) (PVar "env") (PVar "lets") (PVar "a") (PVar "b")) (EApp (EApp (EVar "mapOption") (EApp (EApp (EApp (EVar "suffixed") (EVar "env")) (EVar "lets")) (EVar "b"))) (EApp (EApp (EApp (EApp (EVar "alphaSyntax") (EVar "top")) (EVar "env")) (EVar "lets")) (EVar "a"))))
(DFunDef false "concatAuthority" ((PAs "top" (PCon "PPath" PWild)) (PVar "env") (PVar "lets") (PVar "a") (PVar "b")) (EApp (EApp (EVar "mapOption") (EApp (EApp (EApp (EVar "suffixed") (EVar "env")) (EVar "lets")) (EVar "b"))) (EApp (EApp (EApp (EApp (EVar "alphaSyntax") (EVar "top")) (EVar "env")) (EVar "lets")) (EVar "a"))))
(DFunDef false "concatAuthority" ((PAs "top" (PCon "PProduct" PWild)) (PVar "env") (PVar "lets") (PVar "a") (PVar "b")) (EApp (EApp (EVar "mapOption") (EApp (EApp (EApp (EVar "suffixed") (EVar "env")) (EVar "lets")) (EVar "b"))) (EApp (EApp (EApp (EApp (EVar "alphaSyntax") (EVar "top")) (EVar "env")) (EVar "lets")) (EVar "a"))))
(DFunDef false "concatAuthority" (PWild PWild PWild PWild PWild) (EVar "None"))
(DTypeSig false "suffixed" (TyFun (TyCon "AlphaEnv") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "AlphaBinder"))) (TyFun (TyCon "Expr") (TyFun (TyCon "Authority") (TyCon "Authority"))))))
(DFunDef false "suffixed" ((PVar "env") (PVar "lets") (PVar "b") (PVar "left")) (EMatch (EApp (EApp (EApp (EVar "exactString") (EVar "env")) (EVar "lets")) (EVar "b")) (arm (PCon "Some" (PVar "s")) () (EApp (EApp (EVar "authAppend") (EVar "s")) (EVar "left"))) (arm (PCon "None") () (EApp (EVar "authExtend") (EVar "left")))))
(DTypeSig false "exactString" (TyFun (TyCon "AlphaEnv") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "AlphaBinder"))) (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "exactString" ((PVar "env") (PVar "lets") (PCon "ELoc" PWild (PVar "e"))) (EApp (EApp (EApp (EVar "exactString") (EVar "env")) (EVar "lets")) (EVar "e")))
(DFunDef false "exactString" ((PVar "env") (PVar "lets") (PCon "EDoOrigin" PWild (PVar "e"))) (EApp (EApp (EApp (EVar "exactString") (EVar "env")) (EVar "lets")) (EVar "e")))
(DFunDef false "exactString" ((PVar "env") (PVar "lets") (PCon "EAnnot" (PVar "e") PWild)) (EApp (EApp (EApp (EVar "exactString") (EVar "env")) (EVar "lets")) (EVar "e")))
(DFunDef false "exactString" ((PVar "env") (PVar "lets") (PCon "EHeadAnnot" (PVar "e") PWild)) (EApp (EApp (EApp (EVar "exactString") (EVar "env")) (EVar "lets")) (EVar "e")))
(DFunDef false "exactString" (PWild PWild (PCon "ELit" (PCon "LString" (PVar "s")))) (EApp (EVar "Some") (EVar "s")))
(DFunDef false "exactString" ((PVar "env") (PVar "lets") (PCon "EBinOp" (PVar "op") (PVar "a") (PVar "b") PWild)) (EIf (EBinOp "==" (EVar "op") (ELit (LString "++"))) (EMatch (ETuple (EApp (EApp (EApp (EVar "exactString") (EVar "env")) (EVar "lets")) (EVar "a")) (EApp (EApp (EApp (EVar "exactString") (EVar "env")) (EVar "lets")) (EVar "b"))) (arm (PTuple (PCon "Some" (PVar "x")) (PCon "Some" (PVar "y"))) () (EApp (EVar "Some") (EBinOp "++" (EVar "x") (EVar "y")))) (arm PWild () (EVar "None"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "exactString" ((PVar "env") (PVar "lets") (PCon "EApp" (PVar "f") (PVar "x"))) (EIf (EApp (EApp (EApp (EVar "displayHead") (EVar "env")) (EVar "lets")) (EVar "f")) (EApp (EApp (EApp (EVar "exactString") (EVar "env")) (EVar "lets")) (EVar "x")) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "exactString" (PWild PWild PWild) (EVar "None"))
(DTypeSig false "emptyString" (TyFun (TyCon "AlphaEnv") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "AlphaBinder"))) (TyFun (TyCon "Expr") (TyCon "Bool")))))
(DFunDef false "emptyString" ((PVar "env") (PVar "lets") (PVar "e")) (EMatch (EApp (EApp (EApp (EVar "exactString") (EVar "env")) (EVar "lets")) (EVar "e")) (arm (PCon "Some" (PVar "s")) () (EBinOp "==" (EVar "s") (ELit (LString "")))) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "varAuthority" (TyFun (TyCon "Param") (TyFun (TyCon "AlphaEnv") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "AlphaBinder"))) (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Authority")))))))
(DFunDef false "varAuthority" ((PVar "top") (PVar "env") (PVar "lets") (PVar "x")) (EMatch (EApp (EApp (EVar "letInScope") (EVar "x")) (EVar "lets")) (arm (PCon "Some" (PTuple (PCon "ALet" (PVar "rhs")) (PVar "older"))) () (EApp (EApp (EApp (EApp (EVar "alphaSyntax") (EVar "top")) (EVar "env")) (EVar "older")) (EVar "rhs"))) (arm (PCon "Some" (PTuple (PCon "AOpaque") PWild)) () (EVar "None")) (arm (PCon "Some" (PTuple (PCon "AParam") PWild)) () (EApp (EApp (EApp (EVar "typedAuthority") (EVar "top")) (EVar "env")) (EVar "x"))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "typedAuthority") (EVar "top")) (EVar "env")) (EVar "x")))))
(DTypeSig false "typedAuthority" (TyFun (TyCon "Param") (TyFun (TyCon "AlphaEnv") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Authority"))))))
(DFunDef false "typedAuthority" ((PVar "top") (PVar "env") (PVar "x")) (EMatch (EApp (EFieldAccess (EVar "env") "aeVarType") (EVar "x")) (arm (PCon "Some" (PVar "ty")) () (EMatch (EApp (EVar "normalize") (EVar "ty")) (arm (PCon "TQual" PWild (PVar "q")) () (EApp (EVar "Some") (EApp (EApp (EVar "qualifierIn") (EVar "top")) (EVar "q")))) (arm PWild () (EVar "None")))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "letInScope" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "AlphaBinder"))) (TyApp (TyCon "Option") (TyTuple (TyCon "AlphaBinder") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "AlphaBinder"))))))))
(DFunDef false "letInScope" (PWild (PList)) (EVar "None"))
(DFunDef false "letInScope" ((PVar "x") (PCons (PTuple (PVar "n") (PVar "e")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "n") (EVar "x")) (EApp (EVar "Some") (ETuple (EVar "e") (EVar "rest"))) (EApp (EApp (EVar "letInScope") (EVar "x")) (EVar "rest"))))
(DTypeSig false "joinBranches" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Authority"))) (TyApp (TyCon "Option") (TyCon "Authority"))))
(DFunDef false "joinBranches" ((PList)) (EVar "None"))
(DFunDef false "joinBranches" ((PList (PVar "q"))) (EVar "q"))
(DFunDef false "joinBranches" ((PCons (PVar "q") (PVar "rest"))) (EMatch (ETuple (EVar "q") (EApp (EVar "joinBranches") (EVar "rest"))) (arm (PTuple (PCon "Some" (PVar "a")) (PCon "Some" (PVar "b"))) () (EApp (EVar "Some") (EApp (EVar "authWidenValue") (EApp (EApp (EVar "authJoin") (EVar "a")) (EVar "b"))))) (arm PWild () (EVar "None"))))
(DTypeSig false "collectBinds" (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "AlphaBinder"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "AlphaBinder"))))))
(DFunDef false "collectBinds" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "collectBinds" ((PCons (PCon "LetBind" (PVar "n") (PVar "clauses")) (PVar "rest")) (PVar "acc")) (EMatch (EVar "clauses") (arm (PList (PCon "FunClause" (PList) (PVar "rhs"))) () (EApp (EApp (EVar "collectBinds") (EVar "rest")) (EBinOp "::" (ETuple (EVar "n") (EApp (EVar "ALet") (EVar "rhs"))) (EVar "acc")))) (arm PWild () (EApp (EApp (EVar "collectBinds") (EVar "rest")) (EVar "acc")))))
# MARK
(DUse false (UseGroup ("types" "effect_rows") ((mem "EffRow" true) (mem "Effvar" false) (mem "collectRows" false))))
(DUse false (UseGroup ("types" "effect_domain") ((mem "Param" true) (mem "canonParam" false) (mem "productNorm" false) (mem "subTopOf" false) (mem "productPrimaryLift" false) (mem "domainKey" false))))
(DUse false (UseGroup ("types" "effect_authority") ((mem "Authority" true) (mem "authJoin" false) (mem "authTop" false) (mem "authExtend" false) (mem "authAppend" false) (mem "authWidenValue" false) (mem "authDomainTop" false) (mem "authRetag" false))))
(DUse false (UseGroup ("types" "repr") ((mem "Mono" true) (mem "normalize" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Expr" true) (mem "Lit" true) (mem "Pat" true) (mem "Arm" true) (mem "LetBind" true) (mem "FunClause" true) (mem "DoStmt" true) (mem "TyConOrigin" true) (mem "patBoundNames" false) (mem "sameTyConHead" false))))
(DUse false (UseGroup ("support" "util") ((mem "reverseL" false) (mem "lookupAssoc" false) (mem "mapOption" false))))
(DTypeSig true "recordEffect" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "EffRow"))) (TyFun (TyCon "EffRow") (TyCon "Unit"))))
(DFunDef false "recordEffect" (PWild (PCon "EffRow" (PList) (PCon "None"))) (ELit LUnit))
(DFunDef false "recordEffect" ((PVar "ambient") (PVar "row")) (EApp (EApp (EVar "setRef") (EVar "ambient")) (EBinOp "::" (EVar "row") (EUnOp "!" (EVar "ambient")))))
(DTypeSig true "captureEffects" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "EffRow"))) (TyFun (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyFun (TyFun (TyCon "Unit") (TyVar "a")) (TyTuple (TyVar "a") (TyCon "EffRow"))))))
(DFunDef false "captureEffects" ((PVar "ambient") (PVar "makeJoin") (PVar "body")) (EBlock (DoLet false false (PVar "saved") (EUnOp "!" (EVar "ambient"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "ambient")) (EListLit))) (DoLet false false (PVar "result") (EApp (EVar "body") (ELit LUnit))) (DoLet false false (PVar "performed") (EApp (EApp (EVar "collectRows") (EVar "makeJoin")) (EApp (EVar "reverseL") (EUnOp "!" (EVar "ambient"))))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "ambient")) (EVar "saved"))) (DoExpr (ETuple (EVar "result") (EVar "performed")))))
(DTypeSig true "alphaOf" (TyFun (TyCon "Param") (TyFun (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Mono"))) (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "AlphaBinder"))) (TyFun (TyCon "Expr") (TyFun (TyCon "Mono") (TyCon "Authority"))))))))
(DFunDef false "alphaOf" ((PVar "top") (PVar "varType") (PVar "displayIsPrelude") (PVar "lets") (PVar "e") (PVar "ty")) (EBlock (DoLet false false (PVar "env") (ERecordCreate "AlphaEnv" ((fa "aeVarType" (EVar "varType")) (fa "aeDisplayIsPrelude" (EVar "displayIsPrelude"))))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EVar "alphaSyntax") (EVar "top")) (EVar "env")) (EVar "lets")) (EVar "e")) (arm (PCon "Some" (PVar "q")) () (EVar "q")) (arm (PCon "None") () (EApp (EApp (EVar "typeAuthority") (EVar "top")) (EVar "ty")))))))
(DData Private "AlphaEnv" () ((variant "AlphaEnv" (ConNamed (field "aeVarType" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Mono")))) (field "aeDisplayIsPrelude" (TyCon "Bool"))))) ())
(DData Public "AlphaBinder" () ((variant "ALet" (ConPos (TyCon "Expr"))) (variant "AParam" (ConPos)) (variant "AOpaque" (ConPos))) ())
(DTypeSig true "typeAuthority" (TyFun (TyCon "Param") (TyFun (TyCon "Mono") (TyCon "Authority"))))
(DFunDef false "typeAuthority" ((PVar "top") (PVar "ty")) (EMatch (EApp (EVar "normalize") (EVar "ty")) (arm (PCon "TQual" PWild (PVar "q")) () (EApp (EApp (EVar "qualifierIn") (EVar "top")) (EVar "q"))) (arm PWild () (EApp (EVar "authTop") (EVar "top")))))
(DTypeSig false "qualifierIn" (TyFun (TyCon "Param") (TyFun (TyCon "Authority") (TyCon "Authority"))))
(DFunDef false "qualifierIn" ((PVar "top") (PVar "q")) (EIf (EApp (EApp (EVar "inDomain") (EVar "top")) (EVar "q")) (EApp (EApp (EVar "authRetag") (EVar "top")) (EVar "q")) (EApp (EVar "authTop") (EVar "top"))))
(DTypeSig false "inDomain" (TyFun (TyCon "Param") (TyFun (TyCon "Authority") (TyCon "Bool"))))
(DFunDef false "inDomain" ((PCon "PUnit") PWild) (EVar "True"))
(DFunDef false "inDomain" ((PVar "top") (PVar "q")) (EMatch (EApp (EVar "authDomainTop") (EVar "q")) (arm (PCon "PUnit") () (EVar "True")) (arm (PVar "d") () (EBinOp "==" (EApp (EVar "domainKey") (EVar "d")) (EApp (EVar "domainKey") (EVar "top"))))))
(DTypeSig false "alphaSyntax" (TyFun (TyCon "Param") (TyFun (TyCon "AlphaEnv") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "AlphaBinder"))) (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Authority")))))))
(DFunDef false "alphaSyntax" ((PVar "top") (PVar "env") (PVar "lets") (PCon "ELoc" PWild (PVar "e"))) (EApp (EApp (EApp (EApp (EVar "alphaSyntax") (EVar "top")) (EVar "env")) (EVar "lets")) (EVar "e")))
(DFunDef false "alphaSyntax" ((PVar "top") (PVar "env") (PVar "lets") (PCon "EDoOrigin" PWild (PVar "e"))) (EApp (EApp (EApp (EApp (EVar "alphaSyntax") (EVar "top")) (EVar "env")) (EVar "lets")) (EVar "e")))
(DFunDef false "alphaSyntax" ((PVar "top") (PVar "env") (PVar "lets") (PCon "EAnnot" (PVar "e") PWild)) (EApp (EApp (EApp (EApp (EVar "alphaSyntax") (EVar "top")) (EVar "env")) (EVar "lets")) (EVar "e")))
(DFunDef false "alphaSyntax" ((PVar "top") (PVar "env") (PVar "lets") (PCon "EHeadAnnot" (PVar "e") PWild)) (EApp (EApp (EApp (EApp (EVar "alphaSyntax") (EVar "top")) (EVar "env")) (EVar "lets")) (EVar "e")))
(DFunDef false "alphaSyntax" ((PVar "top") PWild PWild (PCon "ELit" (PCon "LString" (PVar "s")))) (EApp (EVar "Some") (EApp (EApp (EVar "literalAuthority") (EVar "top")) (EVar "s"))))
(DFunDef false "alphaSyntax" ((PVar "top") (PVar "env") (PVar "lets") (PAs "e" (PCon "EBinOp" (PVar "op") (PVar "a") (PVar "b") PWild))) (EIf (EBinOp "==" (EVar "op") (ELit (LString "++"))) (EMatch (EApp (EApp (EApp (EVar "exactString") (EVar "env")) (EVar "lets")) (EVar "e")) (arm (PCon "Some" (PVar "s")) () (EApp (EVar "Some") (EApp (EApp (EVar "literalAuthority") (EVar "top")) (EVar "s")))) (arm (PCon "None") () (EIf (EApp (EApp (EApp (EVar "emptyString") (EVar "env")) (EVar "lets")) (EVar "a")) (EApp (EApp (EApp (EApp (EVar "alphaSyntax") (EVar "top")) (EVar "env")) (EVar "lets")) (EVar "b")) (EIf (EApp (EApp (EApp (EVar "emptyString") (EVar "env")) (EVar "lets")) (EVar "b")) (EApp (EApp (EApp (EApp (EVar "alphaSyntax") (EVar "top")) (EVar "env")) (EVar "lets")) (EVar "a")) (EApp (EApp (EApp (EApp (EApp (EVar "concatAuthority") (EVar "top")) (EVar "env")) (EVar "lets")) (EVar "a")) (EVar "b")))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "alphaSyntax" (PWild PWild PWild (PCon "EBinOp" PWild PWild PWild PWild)) (EVar "None"))
(DFunDef false "alphaSyntax" ((PVar "top") (PVar "env") (PVar "lets") (PCon "EVar" (PVar "x"))) (EApp (EApp (EApp (EApp (EVar "varAuthority") (EVar "top")) (EVar "env")) (EVar "lets")) (EVar "x")))
(DFunDef false "alphaSyntax" ((PVar "top") (PVar "env") (PVar "lets") (PCon "EVarId" (PVar "x") PWild)) (EApp (EApp (EApp (EApp (EVar "varAuthority") (EVar "top")) (EVar "env")) (EVar "lets")) (EVar "x")))
(DFunDef false "alphaSyntax" ((PVar "top") (PVar "env") (PVar "lets") (PCon "EVarAt" (PVar "x") PWild)) (EApp (EApp (EApp (EApp (EVar "varAuthority") (EVar "top")) (EVar "env")) (EVar "lets")) (EVar "x")))
(DFunDef false "alphaSyntax" ((PVar "top") (PVar "env") (PVar "lets") (PCon "EDictAt" (PVar "x") PWild)) (EApp (EApp (EApp (EApp (EVar "varAuthority") (EVar "top")) (EVar "env")) (EVar "lets")) (EVar "x")))
(DFunDef false "alphaSyntax" ((PVar "top") (PVar "env") (PVar "lets") (PCon "ELet" PWild PWild (PCon "PVar" (PVar "x") PWild) (PVar "e1") (PVar "e2"))) (EApp (EApp (EApp (EApp (EVar "alphaSyntax") (EVar "top")) (EVar "env")) (EBinOp "::" (ETuple (EVar "x") (EApp (EVar "ALet") (EVar "e1"))) (EVar "lets"))) (EVar "e2")))
(DFunDef false "alphaSyntax" ((PVar "top") (PVar "env") (PVar "lets") (PCon "ELet" PWild PWild (PVar "pat") PWild (PVar "e2"))) (EApp (EApp (EApp (EApp (EApp (EVar "alphaUnder") (EVar "top")) (EVar "env")) (EVar "lets")) (EApp (EVar "patBoundNames") (EVar "pat"))) (EVar "e2")))
(DFunDef false "alphaSyntax" ((PVar "top") (PVar "env") (PVar "lets") (PCon "ELetGroup" (PVar "binds") (PVar "body"))) (EApp (EApp (EApp (EApp (EVar "alphaSyntax") (EVar "top")) (EVar "env")) (EApp (EApp (EVar "collectBinds") (EVar "binds")) (EApp (EApp (EVar "shadowed") (EApp (EApp (EDictApp "flatMap") (EVar "letBindName")) (EVar "binds"))) (EVar "lets")))) (EVar "body")))
(DFunDef false "alphaSyntax" ((PVar "top") (PVar "env") (PVar "lets") (PCon "EBlock" (PVar "stmts"))) (EApp (EApp (EApp (EApp (EVar "blockAuthority") (EVar "top")) (EVar "env")) (EVar "lets")) (EVar "stmts")))
(DFunDef false "alphaSyntax" ((PVar "top") (PVar "env") (PVar "lets") (PCon "EIf" PWild (PVar "t") (PVar "f"))) (EApp (EVar "joinBranches") (EListLit (EApp (EApp (EApp (EApp (EVar "alphaSyntax") (EVar "top")) (EVar "env")) (EVar "lets")) (EVar "t")) (EApp (EApp (EApp (EApp (EVar "alphaSyntax") (EVar "top")) (EVar "env")) (EVar "lets")) (EVar "f")))))
(DFunDef false "alphaSyntax" ((PVar "top") (PVar "env") (PVar "lets") (PCon "EMatch" (PVar "scrut") (PVar "arms"))) (EApp (EVar "joinBranches") (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EApp (EVar "armAuthority") (EVar "top")) (EVar "env")) (EVar "lets")) (EVar "scrut"))) (EVar "arms"))))
(DFunDef false "alphaSyntax" ((PVar "top") (PVar "env") (PVar "lets") (PCon "EApp" (PVar "f") (PVar "x"))) (EIf (EApp (EApp (EApp (EVar "displayHead") (EVar "env")) (EVar "lets")) (EVar "f")) (EApp (EApp (EApp (EApp (EVar "alphaSyntax") (EVar "top")) (EApp (EVar "stringNames") (EVar "env"))) (EVar "lets")) (EVar "x")) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "alphaSyntax" (PWild PWild PWild PWild) (EVar "None"))
(DTypeSig false "displayHead" (TyFun (TyCon "AlphaEnv") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "AlphaBinder"))) (TyFun (TyCon "Expr") (TyCon "Bool")))))
(DFunDef false "displayHead" ((PVar "env") (PVar "lets") (PCon "ELoc" PWild (PVar "f"))) (EApp (EApp (EApp (EVar "displayHead") (EVar "env")) (EVar "lets")) (EVar "f")))
(DFunDef false "displayHead" ((PVar "env") (PVar "lets") (PCon "EVar" (PVar "x"))) (EApp (EApp (EApp (EVar "preludeDisplay") (EVar "env")) (EVar "lets")) (EVar "x")))
(DFunDef false "displayHead" ((PVar "env") (PVar "lets") (PCon "EVarId" (PVar "x") PWild)) (EApp (EApp (EApp (EVar "preludeDisplay") (EVar "env")) (EVar "lets")) (EVar "x")))
(DFunDef false "displayHead" ((PVar "env") (PVar "lets") (PCon "EMethodAt" (PVar "x") (PVar "seed") PWild)) (EBinOp "&&" (EBinOp "==" (EVar "seed") (ELit (LString ""))) (EApp (EApp (EApp (EVar "preludeDisplay") (EVar "env")) (EVar "lets")) (EVar "x"))))
(DFunDef false "displayHead" (PWild PWild PWild) (EVar "False"))
(DTypeSig false "preludeDisplay" (TyFun (TyCon "AlphaEnv") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "AlphaBinder"))) (TyFun (TyCon "String") (TyCon "Bool")))))
(DFunDef false "preludeDisplay" ((PVar "env") (PVar "lets") (PVar "x")) (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "x") (ELit (LString "display"))) (EFieldAccess (EVar "env") "aeDisplayIsPrelude")) (EApp (EVar "isNone") (EApp (EApp (EVar "letInScope") (EVar "x")) (EVar "lets")))))
(DTypeSig false "stringNames" (TyFun (TyCon "AlphaEnv") (TyCon "AlphaEnv")))
(DFunDef false "stringNames" ((PVar "env")) (ERecordUpdate (EVar "env") ((fa "aeVarType" (ELam ((PVar "x")) (EMatch (EApp (EFieldAccess (EVar "env") "aeVarType") (EVar "x")) (arm (PCon "Some" (PVar "ty")) () (EIf (EApp (EVar "qualifiedString") (EVar "ty")) (EApp (EVar "Some") (EVar "ty")) (EVar "None"))) (arm (PCon "None") () (EVar "None"))))))))
(DTypeSig false "qualifiedString" (TyFun (TyCon "Mono") (TyCon "Bool")))
(DFunDef false "qualifiedString" ((PVar "ty")) (EMatch (EApp (EVar "normalize") (EVar "ty")) (arm (PCon "TQual" (PVar "inner") PWild) () (EMatch (EApp (EVar "normalize") (EVar "inner")) (arm (PCon "TCon" (PVar "n") (PVar "o")) () (EApp (EApp (EApp (EApp (EVar "sameTyConHead") (EVar "n")) (EVar "o")) (ELit (LString "String"))) (EVar "OriginBuiltin"))) (arm PWild () (EVar "False")))) (arm PWild () (EVar "False"))))
(DTypeSig false "blockAuthority" (TyFun (TyCon "Param") (TyFun (TyCon "AlphaEnv") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "AlphaBinder"))) (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyApp (TyCon "Option") (TyCon "Authority")))))))
(DFunDef false "blockAuthority" ((PVar "top") (PVar "env") (PVar "lets") (PList (PCon "DoExpr" (PVar "e")))) (EApp (EApp (EApp (EApp (EVar "alphaSyntax") (EVar "top")) (EVar "env")) (EVar "lets")) (EVar "e")))
(DFunDef false "blockAuthority" ((PVar "top") (PVar "env") (PVar "lets") (PCons (PVar "s") (PAs "rest" (PCons PWild PWild)))) (EApp (EApp (EApp (EApp (EVar "blockAuthority") (EVar "top")) (EVar "env")) (EApp (EApp (EVar "stmtScope") (EVar "s")) (EVar "lets"))) (EVar "rest")))
(DFunDef false "blockAuthority" (PWild PWild PWild PWild) (EVar "None"))
(DTypeSig false "stmtScope" (TyFun (TyCon "DoStmt") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "AlphaBinder"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "AlphaBinder"))))))
(DFunDef false "stmtScope" ((PCon "DoLet" PWild PWild (PCon "PVar" (PVar "x") PWild) (PVar "e")) (PVar "lets")) (EBinOp "::" (ETuple (EVar "x") (EApp (EVar "ALet") (EVar "e"))) (EVar "lets")))
(DFunDef false "stmtScope" ((PCon "DoLet" PWild PWild (PVar "pat") PWild) (PVar "lets")) (EApp (EApp (EVar "shadowed") (EApp (EVar "patBoundNames") (EVar "pat"))) (EVar "lets")))
(DFunDef false "stmtScope" ((PCon "DoBind" (PVar "pat") PWild) (PVar "lets")) (EApp (EApp (EVar "shadowed") (EApp (EVar "patBoundNames") (EVar "pat"))) (EVar "lets")))
(DFunDef false "stmtScope" ((PCon "DoAssign" (PVar "x") PWild) (PVar "lets")) (EApp (EApp (EVar "shadowed") (EListLit (EVar "x"))) (EVar "lets")))
(DFunDef false "stmtScope" ((PCon "DoExpr" PWild) (PVar "lets")) (EVar "lets"))
(DFunDef false "stmtScope" ((PCon "DoFieldAssign" PWild PWild PWild) (PVar "lets")) (EVar "lets"))
(DTypeSig false "armAuthority" (TyFun (TyCon "Param") (TyFun (TyCon "AlphaEnv") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "AlphaBinder"))) (TyFun (TyCon "Expr") (TyFun (TyCon "Arm") (TyApp (TyCon "Option") (TyCon "Authority"))))))))
(DFunDef false "armAuthority" ((PVar "top") (PVar "env") (PVar "lets") (PVar "scrut") (PCon "Arm" (PCon "PVar" (PVar "x") PWild) PWild (PVar "rhs"))) (EApp (EApp (EApp (EApp (EVar "alphaSyntax") (EVar "top")) (EVar "env")) (EBinOp "::" (ETuple (EVar "x") (EApp (EVar "ALet") (EVar "scrut"))) (EVar "lets"))) (EVar "rhs")))
(DFunDef false "armAuthority" ((PVar "top") (PVar "env") (PVar "lets") PWild (PCon "Arm" (PVar "pat") PWild (PVar "rhs"))) (EApp (EApp (EApp (EApp (EApp (EVar "alphaUnder") (EVar "top")) (EVar "env")) (EVar "lets")) (EApp (EVar "patBoundNames") (EVar "pat"))) (EVar "rhs")))
(DTypeSig false "alphaUnder" (TyFun (TyCon "Param") (TyFun (TyCon "AlphaEnv") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "AlphaBinder"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Authority"))))))))
(DFunDef false "alphaUnder" ((PVar "top") (PVar "env") (PVar "lets") (PVar "names") (PVar "body")) (EApp (EApp (EApp (EApp (EVar "alphaSyntax") (EVar "top")) (EVar "env")) (EApp (EApp (EVar "shadowed") (EVar "names")) (EVar "lets"))) (EVar "body")))
(DTypeSig false "shadowed" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "AlphaBinder"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "AlphaBinder"))))))
(DFunDef false "shadowed" ((PVar "names") (PVar "lets")) (EBinOp "++" (EApp (EApp (EMethodRef "map") (ELam ((PVar "n")) (ETuple (EVar "n") (EVar "AOpaque")))) (EVar "names")) (EVar "lets")))
(DTypeSig false "letBindName" (TyFun (TyCon "LetBind") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "letBindName" ((PCon "LetBind" (PVar "n") PWild)) (EListLit (EVar "n")))
(DTypeSig false "literalAuthority" (TyFun (TyCon "Param") (TyFun (TyCon "String") (TyCon "Authority"))))
(DFunDef false "literalAuthority" ((PCon "PPrefix" PWild) (PVar "s")) (EApp (EVar "AConst") (EApp (EVar "canonParam") (EApp (EVar "PPrefix") (EApp (EVar "Some") (EVar "s"))))))
(DFunDef false "literalAuthority" ((PCon "PPath" PWild) (PVar "s")) (EApp (EVar "AConst") (EApp (EVar "canonParam") (EApp (EVar "PPath") (EApp (EVar "Some") (EVar "s"))))))
(DFunDef false "literalAuthority" ((PCon "PSet" PWild) (PVar "s")) (EApp (EVar "AConst") (EApp (EVar "PSet") (EApp (EVar "Some") (EListLit (EVar "s"))))))
(DFunDef false "literalAuthority" ((PCon "PProduct" (PVar "schema")) (PVar "s")) (EApp (EVar "AConst") (EApp (EApp (EVar "productPrimaryLift") (EVar "schema")) (EVar "s"))))
(DFunDef false "literalAuthority" ((PVar "top") PWild) (EApp (EVar "authTop") (EVar "top")))
(DTypeSig false "concatAuthority" (TyFun (TyCon "Param") (TyFun (TyCon "AlphaEnv") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "AlphaBinder"))) (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Authority"))))))))
(DFunDef false "concatAuthority" ((PAs "top" (PCon "PPrefix" PWild)) (PVar "env") (PVar "lets") (PVar "a") (PVar "b")) (EApp (EApp (EVar "mapOption") (EApp (EApp (EApp (EVar "suffixed") (EVar "env")) (EVar "lets")) (EVar "b"))) (EApp (EApp (EApp (EApp (EVar "alphaSyntax") (EVar "top")) (EVar "env")) (EVar "lets")) (EVar "a"))))
(DFunDef false "concatAuthority" ((PAs "top" (PCon "PPath" PWild)) (PVar "env") (PVar "lets") (PVar "a") (PVar "b")) (EApp (EApp (EVar "mapOption") (EApp (EApp (EApp (EVar "suffixed") (EVar "env")) (EVar "lets")) (EVar "b"))) (EApp (EApp (EApp (EApp (EVar "alphaSyntax") (EVar "top")) (EVar "env")) (EVar "lets")) (EVar "a"))))
(DFunDef false "concatAuthority" ((PAs "top" (PCon "PProduct" PWild)) (PVar "env") (PVar "lets") (PVar "a") (PVar "b")) (EApp (EApp (EVar "mapOption") (EApp (EApp (EApp (EVar "suffixed") (EVar "env")) (EVar "lets")) (EVar "b"))) (EApp (EApp (EApp (EApp (EVar "alphaSyntax") (EVar "top")) (EVar "env")) (EVar "lets")) (EVar "a"))))
(DFunDef false "concatAuthority" (PWild PWild PWild PWild PWild) (EVar "None"))
(DTypeSig false "suffixed" (TyFun (TyCon "AlphaEnv") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "AlphaBinder"))) (TyFun (TyCon "Expr") (TyFun (TyCon "Authority") (TyCon "Authority"))))))
(DFunDef false "suffixed" ((PVar "env") (PVar "lets") (PVar "b") (PVar "left")) (EMatch (EApp (EApp (EApp (EVar "exactString") (EVar "env")) (EVar "lets")) (EVar "b")) (arm (PCon "Some" (PVar "s")) () (EApp (EApp (EVar "authAppend") (EVar "s")) (EVar "left"))) (arm (PCon "None") () (EApp (EVar "authExtend") (EVar "left")))))
(DTypeSig false "exactString" (TyFun (TyCon "AlphaEnv") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "AlphaBinder"))) (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "exactString" ((PVar "env") (PVar "lets") (PCon "ELoc" PWild (PVar "e"))) (EApp (EApp (EApp (EVar "exactString") (EVar "env")) (EVar "lets")) (EVar "e")))
(DFunDef false "exactString" ((PVar "env") (PVar "lets") (PCon "EDoOrigin" PWild (PVar "e"))) (EApp (EApp (EApp (EVar "exactString") (EVar "env")) (EVar "lets")) (EVar "e")))
(DFunDef false "exactString" ((PVar "env") (PVar "lets") (PCon "EAnnot" (PVar "e") PWild)) (EApp (EApp (EApp (EVar "exactString") (EVar "env")) (EVar "lets")) (EVar "e")))
(DFunDef false "exactString" ((PVar "env") (PVar "lets") (PCon "EHeadAnnot" (PVar "e") PWild)) (EApp (EApp (EApp (EVar "exactString") (EVar "env")) (EVar "lets")) (EVar "e")))
(DFunDef false "exactString" (PWild PWild (PCon "ELit" (PCon "LString" (PVar "s")))) (EApp (EVar "Some") (EVar "s")))
(DFunDef false "exactString" ((PVar "env") (PVar "lets") (PCon "EBinOp" (PVar "op") (PVar "a") (PVar "b") PWild)) (EIf (EBinOp "==" (EVar "op") (ELit (LString "++"))) (EMatch (ETuple (EApp (EApp (EApp (EVar "exactString") (EVar "env")) (EVar "lets")) (EVar "a")) (EApp (EApp (EApp (EVar "exactString") (EVar "env")) (EVar "lets")) (EVar "b"))) (arm (PTuple (PCon "Some" (PVar "x")) (PCon "Some" (PVar "y"))) () (EApp (EVar "Some") (EBinOp "++" (EVar "x") (EVar "y")))) (arm PWild () (EVar "None"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "exactString" ((PVar "env") (PVar "lets") (PCon "EApp" (PVar "f") (PVar "x"))) (EIf (EApp (EApp (EApp (EVar "displayHead") (EVar "env")) (EVar "lets")) (EVar "f")) (EApp (EApp (EApp (EVar "exactString") (EVar "env")) (EVar "lets")) (EVar "x")) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "exactString" (PWild PWild PWild) (EVar "None"))
(DTypeSig false "emptyString" (TyFun (TyCon "AlphaEnv") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "AlphaBinder"))) (TyFun (TyCon "Expr") (TyCon "Bool")))))
(DFunDef false "emptyString" ((PVar "env") (PVar "lets") (PVar "e")) (EMatch (EApp (EApp (EApp (EVar "exactString") (EVar "env")) (EVar "lets")) (EVar "e")) (arm (PCon "Some" (PVar "s")) () (EBinOp "==" (EVar "s") (ELit (LString "")))) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "varAuthority" (TyFun (TyCon "Param") (TyFun (TyCon "AlphaEnv") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "AlphaBinder"))) (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Authority")))))))
(DFunDef false "varAuthority" ((PVar "top") (PVar "env") (PVar "lets") (PVar "x")) (EMatch (EApp (EApp (EVar "letInScope") (EVar "x")) (EVar "lets")) (arm (PCon "Some" (PTuple (PCon "ALet" (PVar "rhs")) (PVar "older"))) () (EApp (EApp (EApp (EApp (EVar "alphaSyntax") (EVar "top")) (EVar "env")) (EVar "older")) (EVar "rhs"))) (arm (PCon "Some" (PTuple (PCon "AOpaque") PWild)) () (EVar "None")) (arm (PCon "Some" (PTuple (PCon "AParam") PWild)) () (EApp (EApp (EApp (EVar "typedAuthority") (EVar "top")) (EVar "env")) (EVar "x"))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "typedAuthority") (EVar "top")) (EVar "env")) (EVar "x")))))
(DTypeSig false "typedAuthority" (TyFun (TyCon "Param") (TyFun (TyCon "AlphaEnv") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Authority"))))))
(DFunDef false "typedAuthority" ((PVar "top") (PVar "env") (PVar "x")) (EMatch (EApp (EFieldAccess (EVar "env") "aeVarType") (EVar "x")) (arm (PCon "Some" (PVar "ty")) () (EMatch (EApp (EVar "normalize") (EVar "ty")) (arm (PCon "TQual" PWild (PVar "q")) () (EApp (EVar "Some") (EApp (EApp (EVar "qualifierIn") (EVar "top")) (EVar "q")))) (arm PWild () (EVar "None")))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "letInScope" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "AlphaBinder"))) (TyApp (TyCon "Option") (TyTuple (TyCon "AlphaBinder") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "AlphaBinder"))))))))
(DFunDef false "letInScope" (PWild (PList)) (EVar "None"))
(DFunDef false "letInScope" ((PVar "x") (PCons (PTuple (PVar "n") (PVar "e")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "n") (EVar "x")) (EApp (EVar "Some") (ETuple (EVar "e") (EVar "rest"))) (EApp (EApp (EVar "letInScope") (EVar "x")) (EVar "rest"))))
(DTypeSig false "joinBranches" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Authority"))) (TyApp (TyCon "Option") (TyCon "Authority"))))
(DFunDef false "joinBranches" ((PList)) (EVar "None"))
(DFunDef false "joinBranches" ((PList (PVar "q"))) (EVar "q"))
(DFunDef false "joinBranches" ((PCons (PVar "q") (PVar "rest"))) (EMatch (ETuple (EVar "q") (EApp (EVar "joinBranches") (EVar "rest"))) (arm (PTuple (PCon "Some" (PVar "a")) (PCon "Some" (PVar "b"))) () (EApp (EVar "Some") (EApp (EVar "authWidenValue") (EApp (EApp (EVar "authJoin") (EVar "a")) (EVar "b"))))) (arm PWild () (EVar "None"))))
(DTypeSig false "collectBinds" (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "AlphaBinder"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "AlphaBinder"))))))
(DFunDef false "collectBinds" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "collectBinds" ((PCons (PCon "LetBind" (PVar "n") (PVar "clauses")) (PVar "rest")) (PVar "acc")) (EMatch (EVar "clauses") (arm (PList (PCon "FunClause" (PList) (PVar "rhs"))) () (EApp (EApp (EVar "collectBinds") (EVar "rest")) (EBinOp "::" (ETuple (EVar "n") (EApp (EVar "ALet") (EVar "rhs"))) (EVar "acc")))) (arm PWild () (EApp (EApp (EVar "collectBinds") (EVar "rest")) (EVar "acc")))))
