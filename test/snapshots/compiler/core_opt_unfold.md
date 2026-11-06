# META
source_lines=253
stages=DESUGAR,MARK
# SOURCE
import frontend.ast.{Pat(..), Route(..)}
import support.ordmap.{
  OrdMap, omEmpty, omFromNames, omHasKey, omInsert, omKeys, omLookup
}
import support.util.{lenKey}
import ir.core_ir.{
  CBind(..),
  CClause(..),
  CExpr(..),
  CImplBody(..),
  CImplEntry(..),
  CProgram(..),
  CallSite,
  MethodEvidence(..),
  leadingDictParams,
}
import ir.core_walk.{rewriteProgramScoped}
-- Core IR unfolding of trivial definitions: a call of a definition whose body
-- cannot duplicate, drop or reorder work becomes that body, as GHC's simplifier
-- inlines a binding whose unfolding is trivial.
--
-- A definition is trivial when it has one clause and is
-- - a top-level value whose body is a literal, or
-- - a function or impl entry whose parameters are all variables, none a
--   dictionary, and whose body is its one parameter (`fromInt x = x`) or applies a
--   head to all its parameters in order (`fromInt x = intToFloat x`).  The head
--   must read no parameter and no given dictionary, so it means the same at every
--   call site that does not rebind its name.
--
-- A call site is a saturated application of a top-level name that no enclosing
-- binder rebinds, or of a method whose evidence selects one instance statically
-- and passes it no dictionaries.  It is skipped when a binder at the site rebinds
-- a name the head reads.

-- What a call of a trivial definition unfolds to.
data Unfolding =
  -- a literal value: zero parameters
  | Literal CExpr
  -- the one argument itself
  | Identity
  -- the head applied to the arguments, of which there are the arity
  | Forward Int CExpr

-- A definition the table can hold: a top-level binding by name, an impl entry by
-- method and the instance's route word.
data Target = TopLevel String | ImplEntry String String

-- The table key of a target; the two kinds never share a key.
targetKey : Target -> String
targetKey (TopLevel name) = "g\{name}"
targetKey (ImplEntry method word) = "e\{lenKey method}\{word}"

-- Replace every call of a trivial definition by its unfolding.  [noInline] names
-- the top-level functions a `@noinline` attribute marks; they keep their calls.
export
inlineTrivialCalls : List String -> CProgram -> CProgram
inlineTrivialCalls noInline prog =
  rewriteProgramScoped (unfoldSite (unfoldingTable noInline prog)) prog

unfoldSite : OrdMap Unfolding -> OrdMap Unit -> CExpr -> CExpr
unfoldSite table scope (e@(CApp head args site)) = match siteTarget scope head
  Some target => match omLookup (targetKey target) table
    Some u if not (captured scope u) => optionOr e (unfoldAt u args site)
    _ => e
  None => e
unfoldSite _ _ e = e

-- The definition a call head names, when a binder in [scope] does not rebind it.
siteTarget : OrdMap Unit -> CExpr -> Option Target
siteTarget scope (CVar name _) =
  if omHasKey name scope then None else Some (TopLevel name)
siteTarget _ (CMethod method (MethodEvidence _ _ (RKey word [] _) [] [])) =
  Some (ImplEntry method word)
siteTarget _ _ = None

-- [u] at a call with [args], when the call is saturated.
unfoldAt : Unfolding -> List CExpr -> CallSite -> Option CExpr
unfoldAt Identity [arg] _ = Some arg
unfoldAt (Forward n head) args site
  | n == length args = Some (CApp head args site)
unfoldAt _ _ _ = None

captured : OrdMap Unit -> Unfolding -> Bool
captured scope (Forward _ head) = any (n => omHasKey n scope) (headNames head)
captured _ _ = False

unfoldingArity : Unfolding -> Int
unfoldingArity (Literal _) = 0
unfoldingArity Identity = 1
unfoldingArity (Forward n _) = n

-- ── the table ──────────────────────────────────────────────────────────────

-- Every trivial definition of [prog] with its chain followed (`resolveKey`).
unfoldingTable : List String -> CProgram -> OrdMap Unfolding
unfoldingTable noInline (CProgram binds _ _ impls _ _) =
  let excluded = omFromNames noInline omEmpty
  let own = fold (acc b => bindRow excluded b acc) omEmpty binds
  let raw = entryRows impls own
  let resolved =
    fold
      (memo key => snd (resolveKey raw omEmpty key memo))
      omEmpty
      (omKeys raw)
  fold (acc key => keepResolved key resolved acc) omEmpty (omKeys resolved)

bindRow : OrdMap Unit -> CBind -> OrdMap Unfolding -> OrdMap Unfolding
bindRow excluded (CBind name [CClause pats body] _ _) acc
  | not (omHasKey name excluded) = match bindUnfolding pats body
    Some u => omInsert (targetKey (TopLevel name)) u acc
    None => acc
bindRow _ _ acc = acc

bindUnfolding : List Pat -> CExpr -> Option Unfolding
bindUnfolding [] (lit@(CLit _)) = Some (Literal lit)
bindUnfolding pats body = functionUnfolding pats body

-- An impl method of more than one clause has one entry per clause, so a key
-- seen twice is left out.
entryRows : List CImplEntry -> OrdMap Unfolding -> OrdMap Unfolding
entryRows impls acc =
  let counts = fold (m ent => countKey (entryKey ent) m) omEmpty impls
  fold (m ent => entryRow counts ent m) acc impls

entryRow : OrdMap Int -> CImplEntry -> OrdMap Unfolding -> OrdMap Unfolding
entryRow counts ent acc =
  let key = entryKey ent
  if omLookup key counts == Some 1 then match entryParts ent
    (pats, body) => match functionUnfolding pats body
      Some u => omInsert key u acc
      None => acc
  else
    acc

countKey : String -> OrdMap Int -> OrdMap Int
countKey key m = omInsert key (1 + optionOr 0 (omLookup key m)) m

entryKey : CImplEntry -> String
entryKey (CImplEntry m _ _ (CImplTagged _ word _ _ _ _ _)) =
  targetKey (ImplEntry m word)
entryKey (CImplEntry m _ _ (CImplDefault _ _ word _ _ _ _)) =
  targetKey (ImplEntry m word)

entryParts : CImplEntry -> (List Pat, CExpr)
entryParts (CImplEntry _ _ _ (CImplTagged _ _ _ _ _ pats body)) = (pats, body)
entryParts (CImplEntry _ _ _ (CImplDefault _ _ _ _ _ pats body)) = (pats, body)

-- The unfolding of a function whose clause is [pats] and [body], when it is
-- trivial.  A leading dictionary parameter (an instance's `requires`, a method's
-- own context, an inherited default's receiver) is not an argument at a call
-- site, so a definition taking one is not.
functionUnfolding : List Pat -> CExpr -> Option Unfolding
functionUnfolding pats body =
  if leadingDictParams pats > 0 then
    None
  else match varNames pats
    Some [p] if isVarNamed p body => Some Identity
    Some (params@(_ :: _)) => forwarding params body
    _ => None

forwarding : List String -> CExpr -> Option Unfolding
forwarding params (CApp head args _) =
  if isPlainHead head
    && all (n => not (elem n params)) (headNames head)
    && sameVars params args then
    Some (Forward (length params) head)
  else
    None
forwarding _ _ = None

varNames : List Pat -> Option (List String)
varNames [] = Some []
varNames ((PVar x _ _) :: rest) = map (x :: _) (varNames rest)
varNames _ = None

isVarNamed : String -> CExpr -> Bool
isVarNamed x (CVar y _) = x == y
isVarNamed _ _ = False

-- [args] are exactly the variables [params], in order.
sameVars : List String -> List CExpr -> Bool
sameVars [] [] = True
sameVars (p :: ps) (a :: rest) = isVarNamed p a && sameVars ps rest
sameVars _ _ = False

-- A head an unfolding may carry: a name, or a method or constrained-function
-- occurrence whose routes read no given dictionary and name no local standalone.
isPlainHead : CExpr -> Bool
isPlainHead (CVar _ _) = True
isPlainHead (CMethod _ ev) =
  all staticRoute (ev.meDispatch :: ev.mePrereqs ++ ev.meContext)
isPlainHead (CDict _ routes) = all staticRoute routes
isPlainHead _ = False

staticRoute : Route -> Bool
staticRoute (RKey _ reqs sups) = all staticRoute (reqs ++ sups)
staticRoute (RScalar _) = True
staticRoute RNone = True
staticRoute _ = False

-- The name a plain head reads from its scope.
headNames : CExpr -> List String
headNames (CVar name _) = [name]
headNames (CMethod name _) = [name]
headNames (CDict name _) = [name]
headNames _ = []

-- The head of a forwarding unfolding as a call target of its own: the next link
-- of a chain.
headTarget : CExpr -> Option Target
headTarget head = siteTarget omEmpty head

-- The final unfolding of [key], following each forwarding head into the table
-- while the arity agrees.  [path] holds the keys this chain has passed; the link
-- that would return to one of them is not followed, so a cycle is cut there.
-- [memo] answers each key once.
resolveKey : OrdMap Unfolding ->
  OrdMap Unit ->
  String ->
  OrdMap Unfolding ->
  (Option Unfolding, OrdMap Unfolding)
resolveKey raw path key memo = match omLookup key memo
  Some done => (Some done, memo)
  None => match omLookup key raw
    Some u if not (omHasKey key path) =>
      let (result, memo2) = followLink raw (omInsert key () path) u memo
      (Some result, omInsert key result memo2)
    _ => (None, memo)

followLink : OrdMap Unfolding ->
  OrdMap Unit ->
  Unfolding ->
  OrdMap Unfolding ->
  (Unfolding, OrdMap Unfolding)
followLink raw path (u@(Forward n head)) memo = match headTarget head
  Some next =>
    let (found, memo2) = resolveKey raw path (targetKey next) memo
    match found
      Some v if unfoldingArity v == n => (v, memo2)
      _ => (u, memo2)
  None => (u, memo)
followLink _ _ u memo = (u, memo)

-- A resolved unfolding whose head names its own definition is a call of
-- itself, so it is dropped.
keepResolved : String ->
  OrdMap Unfolding ->
  OrdMap Unfolding ->
  OrdMap Unfolding
keepResolved key resolved acc = match omLookup key resolved
  Some (Forward _ head) if map targetKey (headTarget head) == Some key => acc
  Some u => omInsert key u acc
  None => acc
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Pat" true) (mem "Route" true))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omFromNames" false) (mem "omHasKey" false) (mem "omInsert" false) (mem "omKeys" false) (mem "omLookup" false))))
(DUse false (UseGroup ("support" "util") ((mem "lenKey" false))))
(DUse false (UseGroup ("ir" "core_ir") ((mem "CBind" true) (mem "CClause" true) (mem "CExpr" true) (mem "CImplBody" true) (mem "CImplEntry" true) (mem "CProgram" true) (mem "CallSite" false) (mem "MethodEvidence" true) (mem "leadingDictParams" false))))
(DUse false (UseGroup ("ir" "core_walk") ((mem "rewriteProgramScoped" false))))
(DData Private "Unfolding" () ((variant "Literal" (ConPos (TyCon "CExpr"))) (variant "Identity" (ConPos)) (variant "Forward" (ConPos (TyCon "Int") (TyCon "CExpr")))) ())
(DData Private "Target" () ((variant "TopLevel" (ConPos (TyCon "String"))) (variant "ImplEntry" (ConPos (TyCon "String") (TyCon "String")))) ())
(DTypeSig false "targetKey" (TyFun (TyCon "Target") (TyCon "String")))
(DFunDef false "targetKey" ((PCon "TopLevel" (PVar "name"))) (EBinOp "++" (EBinOp "++" (ELit (LString "g")) (EApp (EVar "display") (EVar "name"))) (ELit (LString ""))))
(DFunDef false "targetKey" ((PCon "ImplEntry" (PVar "method") (PVar "word"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "e")) (EApp (EVar "display") (EApp (EVar "lenKey") (EVar "method")))) (ELit (LString ""))) (EApp (EVar "display") (EVar "word"))) (ELit (LString ""))))
(DTypeSig true "inlineTrivialCalls" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "CProgram") (TyCon "CProgram"))))
(DFunDef false "inlineTrivialCalls" ((PVar "noInline") (PVar "prog")) (EApp (EApp (EVar "rewriteProgramScoped") (EApp (EVar "unfoldSite") (EApp (EApp (EVar "unfoldingTable") (EVar "noInline")) (EVar "prog")))) (EVar "prog")))
(DTypeSig false "unfoldSite" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unfolding")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "CExpr") (TyCon "CExpr")))))
(DFunDef false "unfoldSite" ((PVar "table") (PVar "scope") (PAs "e" (PCon "CApp" (PVar "head") (PVar "args") (PVar "site")))) (EMatch (EApp (EApp (EVar "siteTarget") (EVar "scope")) (EVar "head")) (arm (PCon "Some" (PVar "target")) () (EMatch (EApp (EApp (EVar "omLookup") (EApp (EVar "targetKey") (EVar "target"))) (EVar "table")) (arm (PCon "Some" (PVar "u")) ((GBool (EApp (EVar "not") (EApp (EApp (EVar "captured") (EVar "scope")) (EVar "u"))))) (EApp (EApp (EVar "optionOr") (EVar "e")) (EApp (EApp (EApp (EVar "unfoldAt") (EVar "u")) (EVar "args")) (EVar "site")))) (arm PWild () (EVar "e")))) (arm (PCon "None") () (EVar "e"))))
(DFunDef false "unfoldSite" (PWild PWild (PVar "e")) (EVar "e"))
(DTypeSig false "siteTarget" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "CExpr") (TyApp (TyCon "Option") (TyCon "Target")))))
(DFunDef false "siteTarget" ((PVar "scope") (PCon "CVar" (PVar "name") PWild)) (EIf (EApp (EApp (EVar "omHasKey") (EVar "name")) (EVar "scope")) (EVar "None") (EApp (EVar "Some") (EApp (EVar "TopLevel") (EVar "name")))))
(DFunDef false "siteTarget" (PWild (PCon "CMethod" (PVar "method") (PCon "MethodEvidence" PWild PWild (PCon "RKey" (PVar "word") (PList) PWild) (PList) (PList)))) (EApp (EVar "Some") (EApp (EApp (EVar "ImplEntry") (EVar "method")) (EVar "word"))))
(DFunDef false "siteTarget" (PWild PWild) (EVar "None"))
(DTypeSig false "unfoldAt" (TyFun (TyCon "Unfolding") (TyFun (TyApp (TyCon "List") (TyCon "CExpr")) (TyFun (TyCon "CallSite") (TyApp (TyCon "Option") (TyCon "CExpr"))))))
(DFunDef false "unfoldAt" ((PCon "Identity") (PList (PVar "arg")) PWild) (EApp (EVar "Some") (EVar "arg")))
(DFunDef false "unfoldAt" ((PCon "Forward" (PVar "n") (PVar "head")) (PVar "args") (PVar "site")) (EIf (EBinOp "==" (EVar "n") (EApp (EVar "length") (EVar "args"))) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "CApp") (EVar "head")) (EVar "args")) (EVar "site"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "unfoldAt" (PWild PWild PWild) (EVar "None"))
(DTypeSig false "captured" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "Unfolding") (TyCon "Bool"))))
(DFunDef false "captured" ((PVar "scope") (PCon "Forward" PWild (PVar "head"))) (EApp (EApp (EVar "any") (ELam ((PVar "n")) (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "scope")))) (EApp (EVar "headNames") (EVar "head"))))
(DFunDef false "captured" (PWild PWild) (EVar "False"))
(DTypeSig false "unfoldingArity" (TyFun (TyCon "Unfolding") (TyCon "Int")))
(DFunDef false "unfoldingArity" ((PCon "Literal" PWild)) (ELit (LInt 0)))
(DFunDef false "unfoldingArity" ((PCon "Identity")) (ELit (LInt 1)))
(DFunDef false "unfoldingArity" ((PCon "Forward" (PVar "n") PWild)) (EVar "n"))
(DTypeSig false "unfoldingTable" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "CProgram") (TyApp (TyCon "OrdMap") (TyCon "Unfolding")))))
(DFunDef false "unfoldingTable" ((PVar "noInline") (PCon "CProgram" (PVar "binds") PWild PWild (PVar "impls") PWild PWild)) (EBlock (DoLet false false (PVar "excluded") (EApp (EApp (EVar "omFromNames") (EVar "noInline")) (EVar "omEmpty"))) (DoLet false false (PVar "own") (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "b")) (EApp (EApp (EApp (EVar "bindRow") (EVar "excluded")) (EVar "b")) (EVar "acc")))) (EVar "omEmpty")) (EVar "binds"))) (DoLet false false (PVar "raw") (EApp (EApp (EVar "entryRows") (EVar "impls")) (EVar "own"))) (DoLet false false (PVar "resolved") (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "memo") (PVar "key")) (EApp (EVar "snd") (EApp (EApp (EApp (EApp (EVar "resolveKey") (EVar "raw")) (EVar "omEmpty")) (EVar "key")) (EVar "memo"))))) (EVar "omEmpty")) (EApp (EVar "omKeys") (EVar "raw")))) (DoExpr (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "key")) (EApp (EApp (EApp (EVar "keepResolved") (EVar "key")) (EVar "resolved")) (EVar "acc")))) (EVar "omEmpty")) (EApp (EVar "omKeys") (EVar "resolved"))))))
(DTypeSig false "bindRow" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "CBind") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unfolding")) (TyApp (TyCon "OrdMap") (TyCon "Unfolding"))))))
(DFunDef false "bindRow" ((PVar "excluded") (PCon "CBind" (PVar "name") (PList (PCon "CClause" (PVar "pats") (PVar "body"))) PWild PWild) (PVar "acc")) (EIf (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EVar "name")) (EVar "excluded"))) (EMatch (EApp (EApp (EVar "bindUnfolding") (EVar "pats")) (EVar "body")) (arm (PCon "Some" (PVar "u")) () (EApp (EApp (EApp (EVar "omInsert") (EApp (EVar "targetKey") (EApp (EVar "TopLevel") (EVar "name")))) (EVar "u")) (EVar "acc"))) (arm (PCon "None") () (EVar "acc"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "bindRow" (PWild PWild (PVar "acc")) (EVar "acc"))
(DTypeSig false "bindUnfolding" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "CExpr") (TyApp (TyCon "Option") (TyCon "Unfolding")))))
(DFunDef false "bindUnfolding" ((PList) (PAs "lit" (PCon "CLit" PWild))) (EApp (EVar "Some") (EApp (EVar "Literal") (EVar "lit"))))
(DFunDef false "bindUnfolding" ((PVar "pats") (PVar "body")) (EApp (EApp (EVar "functionUnfolding") (EVar "pats")) (EVar "body")))
(DTypeSig false "entryRows" (TyFun (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unfolding")) (TyApp (TyCon "OrdMap") (TyCon "Unfolding")))))
(DFunDef false "entryRows" ((PVar "impls") (PVar "acc")) (EBlock (DoLet false false (PVar "counts") (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "m") (PVar "ent")) (EApp (EApp (EVar "countKey") (EApp (EVar "entryKey") (EVar "ent"))) (EVar "m")))) (EVar "omEmpty")) (EVar "impls"))) (DoExpr (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "m") (PVar "ent")) (EApp (EApp (EApp (EVar "entryRow") (EVar "counts")) (EVar "ent")) (EVar "m")))) (EVar "acc")) (EVar "impls")))))
(DTypeSig false "entryRow" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "CImplEntry") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unfolding")) (TyApp (TyCon "OrdMap") (TyCon "Unfolding"))))))
(DFunDef false "entryRow" ((PVar "counts") (PVar "ent") (PVar "acc")) (EBlock (DoLet false false (PVar "key") (EApp (EVar "entryKey") (EVar "ent"))) (DoExpr (EIf (EBinOp "==" (EApp (EApp (EVar "omLookup") (EVar "key")) (EVar "counts")) (EApp (EVar "Some") (ELit (LInt 1)))) (EMatch (EApp (EVar "entryParts") (EVar "ent")) (arm (PTuple (PVar "pats") (PVar "body")) () (EMatch (EApp (EApp (EVar "functionUnfolding") (EVar "pats")) (EVar "body")) (arm (PCon "Some" (PVar "u")) () (EApp (EApp (EApp (EVar "omInsert") (EVar "key")) (EVar "u")) (EVar "acc"))) (arm (PCon "None") () (EVar "acc"))))) (EVar "acc")))))
(DTypeSig false "countKey" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyApp (TyCon "OrdMap") (TyCon "Int")))))
(DFunDef false "countKey" ((PVar "key") (PVar "m")) (EApp (EApp (EApp (EVar "omInsert") (EVar "key")) (EBinOp "+" (ELit (LInt 1)) (EApp (EApp (EVar "optionOr") (ELit (LInt 0))) (EApp (EApp (EVar "omLookup") (EVar "key")) (EVar "m"))))) (EVar "m")))
(DTypeSig false "entryKey" (TyFun (TyCon "CImplEntry") (TyCon "String")))
(DFunDef false "entryKey" ((PCon "CImplEntry" (PVar "m") PWild PWild (PCon "CImplTagged" PWild (PVar "word") PWild PWild PWild PWild PWild))) (EApp (EVar "targetKey") (EApp (EApp (EVar "ImplEntry") (EVar "m")) (EVar "word"))))
(DFunDef false "entryKey" ((PCon "CImplEntry" (PVar "m") PWild PWild (PCon "CImplDefault" PWild PWild (PVar "word") PWild PWild PWild PWild))) (EApp (EVar "targetKey") (EApp (EApp (EVar "ImplEntry") (EVar "m")) (EVar "word"))))
(DTypeSig false "entryParts" (TyFun (TyCon "CImplEntry") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "CExpr"))))
(DFunDef false "entryParts" ((PCon "CImplEntry" PWild PWild PWild (PCon "CImplTagged" PWild PWild PWild PWild PWild (PVar "pats") (PVar "body")))) (ETuple (EVar "pats") (EVar "body")))
(DFunDef false "entryParts" ((PCon "CImplEntry" PWild PWild PWild (PCon "CImplDefault" PWild PWild PWild PWild PWild (PVar "pats") (PVar "body")))) (ETuple (EVar "pats") (EVar "body")))
(DTypeSig false "functionUnfolding" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "CExpr") (TyApp (TyCon "Option") (TyCon "Unfolding")))))
(DFunDef false "functionUnfolding" ((PVar "pats") (PVar "body")) (EIf (EBinOp ">" (EApp (EVar "leadingDictParams") (EVar "pats")) (ELit (LInt 0))) (EVar "None") (EMatch (EApp (EVar "varNames") (EVar "pats")) (arm (PCon "Some" (PList (PVar "p"))) ((GBool (EApp (EApp (EVar "isVarNamed") (EVar "p")) (EVar "body")))) (EApp (EVar "Some") (EVar "Identity"))) (arm (PCon "Some" (PAs "params" (PCons PWild PWild))) () (EApp (EApp (EVar "forwarding") (EVar "params")) (EVar "body"))) (arm PWild () (EVar "None")))))
(DTypeSig false "forwarding" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "CExpr") (TyApp (TyCon "Option") (TyCon "Unfolding")))))
(DFunDef false "forwarding" ((PVar "params") (PCon "CApp" (PVar "head") (PVar "args") PWild)) (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EVar "isPlainHead") (EVar "head")) (EApp (EApp (EVar "all") (ELam ((PVar "n")) (EApp (EVar "not") (EApp (EApp (EVar "elem") (EVar "n")) (EVar "params"))))) (EApp (EVar "headNames") (EVar "head")))) (EApp (EApp (EVar "sameVars") (EVar "params")) (EVar "args"))) (EApp (EVar "Some") (EApp (EApp (EVar "Forward") (EApp (EVar "length") (EVar "params"))) (EVar "head"))) (EVar "None")))
(DFunDef false "forwarding" (PWild PWild) (EVar "None"))
(DTypeSig false "varNames" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "varNames" ((PList)) (EApp (EVar "Some") (EListLit)))
(DFunDef false "varNames" ((PCons (PCon "PVar" (PVar "x") PWild PWild) (PVar "rest"))) (EApp (EApp (EVar "map") (ELam ((PVar "_s")) (EBinOp "::" (EVar "x") (EVar "_s")))) (EApp (EVar "varNames") (EVar "rest"))))
(DFunDef false "varNames" (PWild) (EVar "None"))
(DTypeSig false "isVarNamed" (TyFun (TyCon "String") (TyFun (TyCon "CExpr") (TyCon "Bool"))))
(DFunDef false "isVarNamed" ((PVar "x") (PCon "CVar" (PVar "y") PWild)) (EBinOp "==" (EVar "x") (EVar "y")))
(DFunDef false "isVarNamed" (PWild PWild) (EVar "False"))
(DTypeSig false "sameVars" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "CExpr")) (TyCon "Bool"))))
(DFunDef false "sameVars" ((PList) (PList)) (EVar "True"))
(DFunDef false "sameVars" ((PCons (PVar "p") (PVar "ps")) (PCons (PVar "a") (PVar "rest"))) (EBinOp "&&" (EApp (EApp (EVar "isVarNamed") (EVar "p")) (EVar "a")) (EApp (EApp (EVar "sameVars") (EVar "ps")) (EVar "rest"))))
(DFunDef false "sameVars" (PWild PWild) (EVar "False"))
(DTypeSig false "isPlainHead" (TyFun (TyCon "CExpr") (TyCon "Bool")))
(DFunDef false "isPlainHead" ((PCon "CVar" PWild PWild)) (EVar "True"))
(DFunDef false "isPlainHead" ((PCon "CMethod" PWild (PVar "ev"))) (EApp (EApp (EVar "all") (EVar "staticRoute")) (EBinOp "::" (EFieldAccess (EVar "ev") "meDispatch") (EBinOp "++" (EFieldAccess (EVar "ev") "mePrereqs") (EFieldAccess (EVar "ev") "meContext")))))
(DFunDef false "isPlainHead" ((PCon "CDict" PWild (PVar "routes"))) (EApp (EApp (EVar "all") (EVar "staticRoute")) (EVar "routes")))
(DFunDef false "isPlainHead" (PWild) (EVar "False"))
(DTypeSig false "staticRoute" (TyFun (TyCon "Route") (TyCon "Bool")))
(DFunDef false "staticRoute" ((PCon "RKey" PWild (PVar "reqs") (PVar "sups"))) (EApp (EApp (EVar "all") (EVar "staticRoute")) (EBinOp "++" (EVar "reqs") (EVar "sups"))))
(DFunDef false "staticRoute" ((PCon "RScalar" PWild)) (EVar "True"))
(DFunDef false "staticRoute" ((PCon "RNone")) (EVar "True"))
(DFunDef false "staticRoute" (PWild) (EVar "False"))
(DTypeSig false "headNames" (TyFun (TyCon "CExpr") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "headNames" ((PCon "CVar" (PVar "name") PWild)) (EListLit (EVar "name")))
(DFunDef false "headNames" ((PCon "CMethod" (PVar "name") PWild)) (EListLit (EVar "name")))
(DFunDef false "headNames" ((PCon "CDict" (PVar "name") PWild)) (EListLit (EVar "name")))
(DFunDef false "headNames" (PWild) (EListLit))
(DTypeSig false "headTarget" (TyFun (TyCon "CExpr") (TyApp (TyCon "Option") (TyCon "Target"))))
(DFunDef false "headTarget" ((PVar "head")) (EApp (EApp (EVar "siteTarget") (EVar "omEmpty")) (EVar "head")))
(DTypeSig false "resolveKey" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unfolding")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unfolding")) (TyTuple (TyApp (TyCon "Option") (TyCon "Unfolding")) (TyApp (TyCon "OrdMap") (TyCon "Unfolding"))))))))
(DFunDef false "resolveKey" ((PVar "raw") (PVar "path") (PVar "key") (PVar "memo")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "key")) (EVar "memo")) (arm (PCon "Some" (PVar "done")) () (ETuple (EApp (EVar "Some") (EVar "done")) (EVar "memo"))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "omLookup") (EVar "key")) (EVar "raw")) (arm (PCon "Some" (PVar "u")) ((GBool (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EVar "key")) (EVar "path"))))) (EBlock (DoLet false false (PTuple (PVar "result") (PVar "memo2")) (EApp (EApp (EApp (EApp (EVar "followLink") (EVar "raw")) (EApp (EApp (EApp (EVar "omInsert") (EVar "key")) (ELit LUnit)) (EVar "path"))) (EVar "u")) (EVar "memo"))) (DoExpr (ETuple (EApp (EVar "Some") (EVar "result")) (EApp (EApp (EApp (EVar "omInsert") (EVar "key")) (EVar "result")) (EVar "memo2")))))) (arm PWild () (ETuple (EVar "None") (EVar "memo")))))))
(DTypeSig false "followLink" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unfolding")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "Unfolding") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unfolding")) (TyTuple (TyCon "Unfolding") (TyApp (TyCon "OrdMap") (TyCon "Unfolding"))))))))
(DFunDef false "followLink" ((PVar "raw") (PVar "path") (PAs "u" (PCon "Forward" (PVar "n") (PVar "head"))) (PVar "memo")) (EMatch (EApp (EVar "headTarget") (EVar "head")) (arm (PCon "Some" (PVar "next")) () (EBlock (DoLet false false (PTuple (PVar "found") (PVar "memo2")) (EApp (EApp (EApp (EApp (EVar "resolveKey") (EVar "raw")) (EVar "path")) (EApp (EVar "targetKey") (EVar "next"))) (EVar "memo"))) (DoExpr (EMatch (EVar "found") (arm (PCon "Some" (PVar "v")) ((GBool (EBinOp "==" (EApp (EVar "unfoldingArity") (EVar "v")) (EVar "n")))) (ETuple (EVar "v") (EVar "memo2"))) (arm PWild () (ETuple (EVar "u") (EVar "memo2"))))))) (arm (PCon "None") () (ETuple (EVar "u") (EVar "memo")))))
(DFunDef false "followLink" (PWild PWild (PVar "u") (PVar "memo")) (ETuple (EVar "u") (EVar "memo")))
(DTypeSig false "keepResolved" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unfolding")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unfolding")) (TyApp (TyCon "OrdMap") (TyCon "Unfolding"))))))
(DFunDef false "keepResolved" ((PVar "key") (PVar "resolved") (PVar "acc")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "key")) (EVar "resolved")) (arm (PCon "Some" (PCon "Forward" PWild (PVar "head"))) ((GBool (EBinOp "==" (EApp (EApp (EVar "map") (EVar "targetKey")) (EApp (EVar "headTarget") (EVar "head"))) (EApp (EVar "Some") (EVar "key"))))) (EVar "acc")) (arm (PCon "Some" (PVar "u")) () (EApp (EApp (EApp (EVar "omInsert") (EVar "key")) (EVar "u")) (EVar "acc"))) (arm (PCon "None") () (EVar "acc"))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Pat" true) (mem "Route" true))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omFromNames" false) (mem "omHasKey" false) (mem "omInsert" false) (mem "omKeys" false) (mem "omLookup" false))))
(DUse false (UseGroup ("support" "util") ((mem "lenKey" false))))
(DUse false (UseGroup ("ir" "core_ir") ((mem "CBind" true) (mem "CClause" true) (mem "CExpr" true) (mem "CImplBody" true) (mem "CImplEntry" true) (mem "CProgram" true) (mem "CallSite" false) (mem "MethodEvidence" true) (mem "leadingDictParams" false))))
(DUse false (UseGroup ("ir" "core_walk") ((mem "rewriteProgramScoped" false))))
(DData Private "Unfolding" () ((variant "Literal" (ConPos (TyCon "CExpr"))) (variant "Identity" (ConPos)) (variant "Forward" (ConPos (TyCon "Int") (TyCon "CExpr")))) ())
(DData Private "Target" () ((variant "TopLevel" (ConPos (TyCon "String"))) (variant "ImplEntry" (ConPos (TyCon "String") (TyCon "String")))) ())
(DTypeSig false "targetKey" (TyFun (TyCon "Target") (TyCon "String")))
(DFunDef false "targetKey" ((PCon "TopLevel" (PVar "name"))) (EBinOp "++" (EBinOp "++" (ELit (LString "g")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString ""))))
(DFunDef false "targetKey" ((PCon "ImplEntry" (PVar "method") (PVar "word"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "e")) (EApp (EMethodRef "display") (EApp (EVar "lenKey") (EVar "method")))) (ELit (LString ""))) (EApp (EMethodRef "display") (EVar "word"))) (ELit (LString ""))))
(DTypeSig true "inlineTrivialCalls" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "CProgram") (TyCon "CProgram"))))
(DFunDef false "inlineTrivialCalls" ((PVar "noInline") (PVar "prog")) (EApp (EApp (EVar "rewriteProgramScoped") (EApp (EVar "unfoldSite") (EApp (EApp (EVar "unfoldingTable") (EVar "noInline")) (EVar "prog")))) (EVar "prog")))
(DTypeSig false "unfoldSite" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unfolding")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "CExpr") (TyCon "CExpr")))))
(DFunDef false "unfoldSite" ((PVar "table") (PVar "scope") (PAs "e" (PCon "CApp" (PVar "head") (PVar "args") (PVar "site")))) (EMatch (EApp (EApp (EVar "siteTarget") (EVar "scope")) (EVar "head")) (arm (PCon "Some" (PVar "target")) () (EMatch (EApp (EApp (EVar "omLookup") (EApp (EVar "targetKey") (EVar "target"))) (EVar "table")) (arm (PCon "Some" (PVar "u")) ((GBool (EApp (EVar "not") (EApp (EApp (EVar "captured") (EVar "scope")) (EVar "u"))))) (EApp (EApp (EVar "optionOr") (EVar "e")) (EApp (EApp (EApp (EVar "unfoldAt") (EVar "u")) (EVar "args")) (EVar "site")))) (arm PWild () (EVar "e")))) (arm (PCon "None") () (EVar "e"))))
(DFunDef false "unfoldSite" (PWild PWild (PVar "e")) (EVar "e"))
(DTypeSig false "siteTarget" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "CExpr") (TyApp (TyCon "Option") (TyCon "Target")))))
(DFunDef false "siteTarget" ((PVar "scope") (PCon "CVar" (PVar "name") PWild)) (EIf (EApp (EApp (EVar "omHasKey") (EVar "name")) (EVar "scope")) (EVar "None") (EApp (EVar "Some") (EApp (EVar "TopLevel") (EVar "name")))))
(DFunDef false "siteTarget" (PWild (PCon "CMethod" (PVar "method") (PCon "MethodEvidence" PWild PWild (PCon "RKey" (PVar "word") (PList) PWild) (PList) (PList)))) (EApp (EVar "Some") (EApp (EApp (EVar "ImplEntry") (EVar "method")) (EVar "word"))))
(DFunDef false "siteTarget" (PWild PWild) (EVar "None"))
(DTypeSig false "unfoldAt" (TyFun (TyCon "Unfolding") (TyFun (TyApp (TyCon "List") (TyCon "CExpr")) (TyFun (TyCon "CallSite") (TyApp (TyCon "Option") (TyCon "CExpr"))))))
(DFunDef false "unfoldAt" ((PCon "Identity") (PList (PVar "arg")) PWild) (EApp (EVar "Some") (EVar "arg")))
(DFunDef false "unfoldAt" ((PCon "Forward" (PVar "n") (PVar "head")) (PVar "args") (PVar "site")) (EIf (EBinOp "==" (EVar "n") (EApp (EMethodRef "length") (EVar "args"))) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "CApp") (EVar "head")) (EVar "args")) (EVar "site"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "unfoldAt" (PWild PWild PWild) (EVar "None"))
(DTypeSig false "captured" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "Unfolding") (TyCon "Bool"))))
(DFunDef false "captured" ((PVar "scope") (PCon "Forward" PWild (PVar "head"))) (EApp (EApp (EDictApp "any") (ELam ((PVar "n")) (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "scope")))) (EApp (EVar "headNames") (EVar "head"))))
(DFunDef false "captured" (PWild PWild) (EVar "False"))
(DTypeSig false "unfoldingArity" (TyFun (TyCon "Unfolding") (TyCon "Int")))
(DFunDef false "unfoldingArity" ((PCon "Literal" PWild)) (ELit (LInt 0)))
(DFunDef false "unfoldingArity" ((PCon "Identity")) (ELit (LInt 1)))
(DFunDef false "unfoldingArity" ((PCon "Forward" (PVar "n") PWild)) (EVar "n"))
(DTypeSig false "unfoldingTable" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "CProgram") (TyApp (TyCon "OrdMap") (TyCon "Unfolding")))))
(DFunDef false "unfoldingTable" ((PVar "noInline") (PCon "CProgram" (PVar "binds") PWild PWild (PVar "impls") PWild PWild)) (EBlock (DoLet false false (PVar "excluded") (EApp (EApp (EVar "omFromNames") (EVar "noInline")) (EVar "omEmpty"))) (DoLet false false (PVar "own") (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "b")) (EApp (EApp (EApp (EVar "bindRow") (EVar "excluded")) (EVar "b")) (EVar "acc")))) (EVar "omEmpty")) (EVar "binds"))) (DoLet false false (PVar "raw") (EApp (EApp (EVar "entryRows") (EVar "impls")) (EVar "own"))) (DoLet false false (PVar "resolved") (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "memo") (PVar "key")) (EApp (EVar "snd") (EApp (EApp (EApp (EApp (EVar "resolveKey") (EVar "raw")) (EVar "omEmpty")) (EVar "key")) (EVar "memo"))))) (EVar "omEmpty")) (EApp (EVar "omKeys") (EVar "raw")))) (DoExpr (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "key")) (EApp (EApp (EApp (EVar "keepResolved") (EVar "key")) (EVar "resolved")) (EVar "acc")))) (EVar "omEmpty")) (EApp (EVar "omKeys") (EVar "resolved"))))))
(DTypeSig false "bindRow" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "CBind") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unfolding")) (TyApp (TyCon "OrdMap") (TyCon "Unfolding"))))))
(DFunDef false "bindRow" ((PVar "excluded") (PCon "CBind" (PVar "name") (PList (PCon "CClause" (PVar "pats") (PVar "body"))) PWild PWild) (PVar "acc")) (EIf (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EVar "name")) (EVar "excluded"))) (EMatch (EApp (EApp (EVar "bindUnfolding") (EVar "pats")) (EVar "body")) (arm (PCon "Some" (PVar "u")) () (EApp (EApp (EApp (EVar "omInsert") (EApp (EVar "targetKey") (EApp (EVar "TopLevel") (EVar "name")))) (EVar "u")) (EVar "acc"))) (arm (PCon "None") () (EVar "acc"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "bindRow" (PWild PWild (PVar "acc")) (EVar "acc"))
(DTypeSig false "bindUnfolding" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "CExpr") (TyApp (TyCon "Option") (TyCon "Unfolding")))))
(DFunDef false "bindUnfolding" ((PList) (PAs "lit" (PCon "CLit" PWild))) (EApp (EVar "Some") (EApp (EVar "Literal") (EVar "lit"))))
(DFunDef false "bindUnfolding" ((PVar "pats") (PVar "body")) (EApp (EApp (EVar "functionUnfolding") (EVar "pats")) (EVar "body")))
(DTypeSig false "entryRows" (TyFun (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unfolding")) (TyApp (TyCon "OrdMap") (TyCon "Unfolding")))))
(DFunDef false "entryRows" ((PVar "impls") (PVar "acc")) (EBlock (DoLet false false (PVar "counts") (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "m") (PVar "ent")) (EApp (EApp (EVar "countKey") (EApp (EVar "entryKey") (EVar "ent"))) (EVar "m")))) (EVar "omEmpty")) (EVar "impls"))) (DoExpr (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "m") (PVar "ent")) (EApp (EApp (EApp (EVar "entryRow") (EVar "counts")) (EVar "ent")) (EVar "m")))) (EVar "acc")) (EVar "impls")))))
(DTypeSig false "entryRow" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "CImplEntry") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unfolding")) (TyApp (TyCon "OrdMap") (TyCon "Unfolding"))))))
(DFunDef false "entryRow" ((PVar "counts") (PVar "ent") (PVar "acc")) (EBlock (DoLet false false (PVar "key") (EApp (EVar "entryKey") (EVar "ent"))) (DoExpr (EIf (EBinOp "==" (EApp (EApp (EVar "omLookup") (EVar "key")) (EVar "counts")) (EApp (EVar "Some") (ELit (LInt 1)))) (EMatch (EApp (EVar "entryParts") (EVar "ent")) (arm (PTuple (PVar "pats") (PVar "body")) () (EMatch (EApp (EApp (EVar "functionUnfolding") (EVar "pats")) (EVar "body")) (arm (PCon "Some" (PVar "u")) () (EApp (EApp (EApp (EVar "omInsert") (EVar "key")) (EVar "u")) (EVar "acc"))) (arm (PCon "None") () (EVar "acc"))))) (EVar "acc")))))
(DTypeSig false "countKey" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyApp (TyCon "OrdMap") (TyCon "Int")))))
(DFunDef false "countKey" ((PVar "key") (PVar "m")) (EApp (EApp (EApp (EVar "omInsert") (EVar "key")) (EBinOp "+" (ELit (LInt 1)) (EApp (EApp (EVar "optionOr") (ELit (LInt 0))) (EApp (EApp (EVar "omLookup") (EVar "key")) (EVar "m"))))) (EVar "m")))
(DTypeSig false "entryKey" (TyFun (TyCon "CImplEntry") (TyCon "String")))
(DFunDef false "entryKey" ((PCon "CImplEntry" (PVar "m") PWild PWild (PCon "CImplTagged" PWild (PVar "word") PWild PWild PWild PWild PWild))) (EApp (EVar "targetKey") (EApp (EApp (EVar "ImplEntry") (EVar "m")) (EVar "word"))))
(DFunDef false "entryKey" ((PCon "CImplEntry" (PVar "m") PWild PWild (PCon "CImplDefault" PWild PWild (PVar "word") PWild PWild PWild PWild))) (EApp (EVar "targetKey") (EApp (EApp (EVar "ImplEntry") (EVar "m")) (EVar "word"))))
(DTypeSig false "entryParts" (TyFun (TyCon "CImplEntry") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "CExpr"))))
(DFunDef false "entryParts" ((PCon "CImplEntry" PWild PWild PWild (PCon "CImplTagged" PWild PWild PWild PWild PWild (PVar "pats") (PVar "body")))) (ETuple (EVar "pats") (EVar "body")))
(DFunDef false "entryParts" ((PCon "CImplEntry" PWild PWild PWild (PCon "CImplDefault" PWild PWild PWild PWild PWild (PVar "pats") (PVar "body")))) (ETuple (EVar "pats") (EVar "body")))
(DTypeSig false "functionUnfolding" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "CExpr") (TyApp (TyCon "Option") (TyCon "Unfolding")))))
(DFunDef false "functionUnfolding" ((PVar "pats") (PVar "body")) (EIf (EBinOp ">" (EApp (EVar "leadingDictParams") (EVar "pats")) (ELit (LInt 0))) (EVar "None") (EMatch (EApp (EVar "varNames") (EVar "pats")) (arm (PCon "Some" (PList (PVar "p"))) ((GBool (EApp (EApp (EVar "isVarNamed") (EVar "p")) (EVar "body")))) (EApp (EVar "Some") (EVar "Identity"))) (arm (PCon "Some" (PAs "params" (PCons PWild PWild))) () (EApp (EApp (EVar "forwarding") (EVar "params")) (EVar "body"))) (arm PWild () (EVar "None")))))
(DTypeSig false "forwarding" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "CExpr") (TyApp (TyCon "Option") (TyCon "Unfolding")))))
(DFunDef false "forwarding" ((PVar "params") (PCon "CApp" (PVar "head") (PVar "args") PWild)) (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EVar "isPlainHead") (EVar "head")) (EApp (EApp (EDictApp "all") (ELam ((PVar "n")) (EApp (EVar "not") (EApp (EApp (EDictApp "elem") (EVar "n")) (EVar "params"))))) (EApp (EVar "headNames") (EVar "head")))) (EApp (EApp (EVar "sameVars") (EVar "params")) (EVar "args"))) (EApp (EVar "Some") (EApp (EApp (EVar "Forward") (EApp (EMethodRef "length") (EVar "params"))) (EVar "head"))) (EVar "None")))
(DFunDef false "forwarding" (PWild PWild) (EVar "None"))
(DTypeSig false "varNames" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "varNames" ((PList)) (EApp (EVar "Some") (EListLit)))
(DFunDef false "varNames" ((PCons (PCon "PVar" (PVar "x") PWild PWild) (PVar "rest"))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "_s")) (EBinOp "::" (EVar "x") (EVar "_s")))) (EApp (EVar "varNames") (EVar "rest"))))
(DFunDef false "varNames" (PWild) (EVar "None"))
(DTypeSig false "isVarNamed" (TyFun (TyCon "String") (TyFun (TyCon "CExpr") (TyCon "Bool"))))
(DFunDef false "isVarNamed" ((PVar "x") (PCon "CVar" (PVar "y") PWild)) (EBinOp "==" (EVar "x") (EVar "y")))
(DFunDef false "isVarNamed" (PWild PWild) (EVar "False"))
(DTypeSig false "sameVars" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "CExpr")) (TyCon "Bool"))))
(DFunDef false "sameVars" ((PList) (PList)) (EVar "True"))
(DFunDef false "sameVars" ((PCons (PVar "p") (PVar "ps")) (PCons (PVar "a") (PVar "rest"))) (EBinOp "&&" (EApp (EApp (EVar "isVarNamed") (EVar "p")) (EVar "a")) (EApp (EApp (EVar "sameVars") (EVar "ps")) (EVar "rest"))))
(DFunDef false "sameVars" (PWild PWild) (EVar "False"))
(DTypeSig false "isPlainHead" (TyFun (TyCon "CExpr") (TyCon "Bool")))
(DFunDef false "isPlainHead" ((PCon "CVar" PWild PWild)) (EVar "True"))
(DFunDef false "isPlainHead" ((PCon "CMethod" PWild (PVar "ev"))) (EApp (EApp (EDictApp "all") (EVar "staticRoute")) (EBinOp "::" (EFieldAccess (EVar "ev") "meDispatch") (EBinOp "++" (EFieldAccess (EVar "ev") "mePrereqs") (EFieldAccess (EVar "ev") "meContext")))))
(DFunDef false "isPlainHead" ((PCon "CDict" PWild (PVar "routes"))) (EApp (EApp (EDictApp "all") (EVar "staticRoute")) (EVar "routes")))
(DFunDef false "isPlainHead" (PWild) (EVar "False"))
(DTypeSig false "staticRoute" (TyFun (TyCon "Route") (TyCon "Bool")))
(DFunDef false "staticRoute" ((PCon "RKey" PWild (PVar "reqs") (PVar "sups"))) (EApp (EApp (EDictApp "all") (EVar "staticRoute")) (EBinOp "++" (EVar "reqs") (EVar "sups"))))
(DFunDef false "staticRoute" ((PCon "RScalar" PWild)) (EVar "True"))
(DFunDef false "staticRoute" ((PCon "RNone")) (EVar "True"))
(DFunDef false "staticRoute" (PWild) (EVar "False"))
(DTypeSig false "headNames" (TyFun (TyCon "CExpr") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "headNames" ((PCon "CVar" (PVar "name") PWild)) (EListLit (EVar "name")))
(DFunDef false "headNames" ((PCon "CMethod" (PVar "name") PWild)) (EListLit (EVar "name")))
(DFunDef false "headNames" ((PCon "CDict" (PVar "name") PWild)) (EListLit (EVar "name")))
(DFunDef false "headNames" (PWild) (EListLit))
(DTypeSig false "headTarget" (TyFun (TyCon "CExpr") (TyApp (TyCon "Option") (TyCon "Target"))))
(DFunDef false "headTarget" ((PVar "head")) (EApp (EApp (EVar "siteTarget") (EVar "omEmpty")) (EVar "head")))
(DTypeSig false "resolveKey" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unfolding")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unfolding")) (TyTuple (TyApp (TyCon "Option") (TyCon "Unfolding")) (TyApp (TyCon "OrdMap") (TyCon "Unfolding"))))))))
(DFunDef false "resolveKey" ((PVar "raw") (PVar "path") (PVar "key") (PVar "memo")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "key")) (EVar "memo")) (arm (PCon "Some" (PVar "done")) () (ETuple (EApp (EVar "Some") (EVar "done")) (EVar "memo"))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "omLookup") (EVar "key")) (EVar "raw")) (arm (PCon "Some" (PVar "u")) ((GBool (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EVar "key")) (EVar "path"))))) (EBlock (DoLet false false (PTuple (PVar "result") (PVar "memo2")) (EApp (EApp (EApp (EApp (EVar "followLink") (EVar "raw")) (EApp (EApp (EApp (EVar "omInsert") (EVar "key")) (ELit LUnit)) (EVar "path"))) (EVar "u")) (EVar "memo"))) (DoExpr (ETuple (EApp (EVar "Some") (EVar "result")) (EApp (EApp (EApp (EVar "omInsert") (EVar "key")) (EVar "result")) (EVar "memo2")))))) (arm PWild () (ETuple (EVar "None") (EVar "memo")))))))
(DTypeSig false "followLink" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unfolding")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "Unfolding") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unfolding")) (TyTuple (TyCon "Unfolding") (TyApp (TyCon "OrdMap") (TyCon "Unfolding"))))))))
(DFunDef false "followLink" ((PVar "raw") (PVar "path") (PAs "u" (PCon "Forward" (PVar "n") (PVar "head"))) (PVar "memo")) (EMatch (EApp (EVar "headTarget") (EVar "head")) (arm (PCon "Some" (PVar "next")) () (EBlock (DoLet false false (PTuple (PVar "found") (PVar "memo2")) (EApp (EApp (EApp (EApp (EVar "resolveKey") (EVar "raw")) (EVar "path")) (EApp (EVar "targetKey") (EVar "next"))) (EVar "memo"))) (DoExpr (EMatch (EVar "found") (arm (PCon "Some" (PVar "v")) ((GBool (EBinOp "==" (EApp (EVar "unfoldingArity") (EVar "v")) (EVar "n")))) (ETuple (EVar "v") (EVar "memo2"))) (arm PWild () (ETuple (EVar "u") (EVar "memo2"))))))) (arm (PCon "None") () (ETuple (EVar "u") (EVar "memo")))))
(DFunDef false "followLink" (PWild PWild (PVar "u") (PVar "memo")) (ETuple (EVar "u") (EVar "memo")))
(DTypeSig false "keepResolved" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unfolding")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unfolding")) (TyApp (TyCon "OrdMap") (TyCon "Unfolding"))))))
(DFunDef false "keepResolved" ((PVar "key") (PVar "resolved") (PVar "acc")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "key")) (EVar "resolved")) (arm (PCon "Some" (PCon "Forward" PWild (PVar "head"))) ((GBool (EBinOp "==" (EApp (EApp (EMethodRef "map") (EVar "targetKey")) (EApp (EVar "headTarget") (EVar "head"))) (EApp (EVar "Some") (EVar "key"))))) (EVar "acc")) (arm (PCon "Some" (PVar "u")) () (EApp (EApp (EApp (EVar "omInsert") (EVar "key")) (EVar "u")) (EVar "acc"))) (arm (PCon "None") () (EVar "acc"))))
