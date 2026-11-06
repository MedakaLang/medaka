# META
source_lines=1299
stages=DESUGAR,MARK
# SOURCE
-- tc_init: the initialisation graph of one module's top-level values and the order it implies.
-- The nodes are the module's top-level bindings and one node per local `impl`; a node's
-- mentions are what its bodies may reach, each with the position the cycle rule reads.
--
-- Spec: language-design "Top-level initialisation (L1)", I1 (order), I3 (value cycles), I6
-- (constrained nullary bindings).  The position split is OCaml `Rec_check`'s
-- Dereference/Guard/Delay modes lifted to the module graph.
--
-- The walk over-approximates by construction: a missing mention becomes an uninitialised read
-- once initialisation is strict, so every `Expr` and `Pat` arm is handled explicitly and an
-- unknown name or interface widens to every local impl rather than to nothing.
--
-- Closure rule: this module may import `tc_types`, `tc_env` and the leaves below them; it may
-- not import `tc_module`, `tc_stamp`, `tc_global`, `typecheck`, or anything in `backend/`,
-- `ir/`, `eval/`, `driver/` or `tools/`.

import frontend.ast.{
  Arm(..),
  Constraint(..),
  Decl(..),
  DoStmt(..),
  Expr(..),
  FieldAssign(..),
  FunClause(..),
  Guard(..),
  GuardArm(..),
  IfaceMethod(..),
  ImplMethod(..),
  InterpPart(..),
  LetBind(..),
  Loc,
  MethodDefault(..),
  Pat(..),
  RecPatField(..),
  Require(..),
  Section(..),
  Super(..),
  Ty(..),
  TyConOrigin(..),
  ifaceIdentity,
}
import list.{last}
import map as M
import string.{nextChar, split, startCursor, stripPrefix}
import support.ordmap.{
  OrdMap, omEmpty, omFromPairs, omHasKey, omInsert, omLookup, omMapValues
}
import support.scc.{tarjanSCCs}
import support.util.{isEmptyL, isNonEmptyL, reverseL}
import types.effect_rows.{renderAtoms, rowFlat}
import types.repr.{IfaceRef(..), Scheme(..), VecObl(..)}
import types.tc_env.{
  ceRowIface, ceRowMethods, ceRowSupers, ieRowTriple, ieRowsVisibleAt,
  methodRowIface
}
import types.tc_types.{
  ClassEnv(..),
  DeclEnvs(..),
  MethodEnv(..),
  ModuleBindings(..),
  ModuleCtx(..),
  ModuleSeed(..),
}

-- What the graph is built from, projected from the module's check by `initInputsAt`.
-- Interface keys are `ifaceIdentity` strings; `""` is an unknown interface, which reaches
-- every local impl.  The dispatch tables are empty for a module that declares no impl,
-- since every dispatch edge ends at a local impl.
public export data InitInputs = InitInputs {
  iiModule : String,
  -- the marked, unstamped declarations
  iiDecls : List Decl,
  -- the module's own standalone schemes; their forcing rows are the purity rule's input
  iiSchemes : OrdMap Scheme,
  -- method spelling -> the interface keys that declare it, whole graph
  iiMethodIfaces : OrdMap (List String),
  -- interface key -> its reflexive-transitive dispatch closure: supers, the `requires` of
  -- every impl row of it, and the method-level constraints of its methods
  iiDispatchClosure : OrdMap (List String),
  -- constrained callee spelling -> its constraint interface keys (imported, then prelude)
  iiCalleeIfaces : OrdMap (List String),
  -- the method a binary or unary operator dispatches through
  iiBinopMethod : String -> Option String,
  iiUnopMethod : String -> Option String,
  -- every value name an import of the module binds; the prelude's names are not in it
  iiImportedValues : OrdMap Unit,
  -- nullary top-level bindings with a class constraint (I6)
  iiConstrained : OrdMap Unit,
  -- bindings that are never initialised (`main`, I4)
  iiExempt : OrdMap Unit,
}

-- How a later rule may use a mention.  `AtDeref` is evaluated when the node runs (an
-- application head or argument, a scrutinee, a `let` right-hand side, an operand);
-- `AtGuard` is only read (a constructor, tuple, list or record component, or anything inside
-- a lambda in such a position or as the whole right-hand side); `AtDelay` is inside a direct
-- lambda argument of a `Deferred*` call in guarded position, which the effect checker
-- proves the call does not run.
public export data InitPosition =
  | AtDeref
  | AtGuard
  | AtDelay
  deriving (Eq, Debug)

-- What makes the edge: a top-level name; a method occurrence or constrained call on the
-- target impl's own interface; an operator or literal on it; an imported value reaching a
-- local orphan impl; or an interface of the site's dispatch closure other than its own.
public export data InitEdgeKind =
  | ByName
  | ByDispatch
  | ByOperator
  | ByOrphan
  | ByClosure
  deriving (Eq, Debug)

public export data InitMention = InitMention {
  mentionTarget : String,
  mentionKind : InitEdgeKind,
  mentionPosition : InitPosition,
} deriving (Eq, Debug)

-- A function node's body runs when it is called and a constrained nullary binding is a
-- function of its dictionaries (I6), so only a `ValueNode` is initialised.
public export data InitNodeKind =
  | ValueNode
  | FunctionNode
  | ImplNode
  deriving (Eq, Debug)

-- [inodeOrder] is the node's source position among the module's nodes.
public export data InitNode = InitNode {
  inodeName : String,
  inodeKind : InitNodeKind,
  inodeOrder : Int,
  inodeLoc : Option Loc,
  inodeMentions : List InitMention,
}

-- [igraphNotInitialised] holds the value nodes I4 and I6 exempt from initialisation.
public export data InitGraph = InitGraph {
  igraphNodes : List InitNode,
  igraphNotInitialised : OrdMap Unit,
}

-- ── the rules ────────────────────────────────────────────────────────────────

-- A top-level value whose initialiser has a non-empty forcing row (I2): [ivRow] is the row
-- as the signature would write it.
public export data InitViolation = InitViolation {
  ivName : String,
  ivRow : String,
  ivLoc : Option Loc,
}

-- I2: every initialised value node (not a function, an impl, `main` or a constrained
-- nullary binding) must have an empty forcing row in its inferred scheme.  A row tail that
-- is unsolved counts as empty: only labels make a row non-empty.  The source annotation is
-- not read, so a row-less signature over an effectful body is rejected.
export
checkInitRules : InitInputs -> InitGraph -> List InitViolation
checkInitRules inputs g =
  flatMap
    (n =>
      if n.inodeKind == ValueNode
        && not (omHasKey n.inodeName g.igraphNotInitialised) then
        purityViolation inputs n
      else
        [])
    g.igraphNodes

purityViolation : InitInputs -> InitNode -> List InitViolation
purityViolation inputs n = match omLookup n.inodeName inputs.iiSchemes
  Some (Forall _ _ _ _ force _) => match fst (rowFlat force)
    [] => []
    labels => [
      InitViolation {
        ivName = n.inodeName,
        ivRow = "<\{renderAtoms labels}>",
        ivLoc = n.inodeLoc,
      },
    ]
  None => []

-- ── the input projection ─────────────────────────────────────────────────────

-- The inputs at the end of a module's check: [marked] is the tree `checkModuleFullDiags`
-- returns, [envs] the whole-graph declaration envelope and [ord] the module's ordinal.
export
initInputsAt : String ->
  ModuleSeed ->
  ModuleBindings ->
  List Decl ->
  ModuleCtx ->
  DeclEnvs ->
  Int ->
  (String -> Option String) ->
  (String -> Option String) ->
  InitInputs
initInputsAt mid seed bindings marked mctx envs ord binop unop =
  let dispatching = declaresImpl marked
  InitInputs {
    iiModule = mid,
    iiDecls = marked,
    iiSchemes = bindings.mbStandaloneSchemes,
    iiMethodIfaces =
      if dispatching then methodIfacesOf envs.deMethods else omEmpty,
    iiDispatchClosure =
      if dispatching then dispatchClosureOf envs ord else omEmpty,
    iiCalleeIfaces = if dispatching then calleeIfacesOf mctx else omEmpty,
    iiBinopMethod = binop,
    iiUnopMethod = unop,
    iiImportedValues = seed.msImportedNames,
    iiConstrained = constrainedOf mctx,
    iiExempt = omInsert "main" () omEmpty,
  }

declaresImpl : List Decl -> Bool
declaresImpl [] = False
declaresImpl ((DAttrib _ d) :: rest) = declaresImpl (d :: rest)
declaresImpl ((DImpl { implOrigin = _ }) :: _) = True
declaresImpl (_ :: rest) = declaresImpl rest

refKey : IfaceRef -> String
refKey r = ifaceIdentity r.irOrigin r.irName

methodIfacesOf : MethodEnv -> OrdMap (List String)
methodIfacesOf env =
  omMapValues (rows => map (r => refKey (methodRowIface r)) rows) env.meByName

calleeIfacesOf : ModuleCtx -> OrdMap (List String)
calleeIfacesOf mctx =
  let keysOf obls = map (o => refKey o.voIface) obls
  let core =
    omMapValues keysOf mctx.mcGraph.crossRun.coreSchemeObligationsRef.value
  M.foldlWithKey
    (acc n obls => omInsert n (keysOf obls) acc)
    core
    mctx.mcCells.importedSchemeOblsRef.value

-- The top-level names whose scheme carries a class obligation, read under the binding id
-- of the top-level binder so a local helper of the same spelling does not count.
constrainedOf : ModuleCtx -> OrdMap Unit
constrainedOf mctx =
  let ids = mctx.mcCells.schemeDefIdsRef.value
  fold
    (acc row => match row
      ((n, bid), obls) =>
        if isNonEmptyL obls && omLookup n ids == Some bid then
          omInsert n () acc
        else
          acc)
    omEmpty
    mctx.mcCells.schemeObligationsRef.value

-- One step of the dispatch closure from each interface key, then its reflexive-transitive
-- closure for every key that has a step.  The impl rows are the whole graph's (instance
-- candidacy is graph-global), and so are the interface rows: a `requires` may name an
-- interface declared after this module.
dispatchClosureOf : DeclEnvs -> Int -> OrdMap (List String)
dispatchClosureOf envs ord =
  let withSupers =
    fold
      (acc row =>
        addSteps
          (refKey (ceRowIface row))
          (map (s => ifaceIdentity s.superOrigin s.superHead) (ceRowSupers row)
            ++ flatMap
              (m => match m
                (_, ty, _) => tyConstraintKeys ty [])
              (ceRowMethods row))
          acc)
      omEmpty
      envs.deIfaces.ceRows
  let steps =
    fold
      (acc row => match ieRowTriple row
        (ir, _, reqs) =>
          addSteps
            (refKey ir)
            (map (q => ifaceIdentity q.requireOrigin q.requireHead) reqs)
            acc)
      withSupers
      (ieRowsVisibleAt ord envs.deImpls)
  M.foldlWithKey
    (acc k _ => omInsert k (closureFrom steps [k] omEmpty []) acc)
    omEmpty
    steps

addSteps : String -> List String -> OrdMap (List String) -> OrdMap (List String)
addSteps _ [] acc = acc
addSteps k ks acc = match omLookup k acc
  Some old => omInsert k (ks ++ old) acc
  None => omInsert k ks acc

closureFrom : OrdMap (List String) ->
  List String ->
  OrdMap Unit ->
  List String ->
  List String
closureFrom _ [] _ out = out
closureFrom steps (k :: rest) seen out
  | omHasKey k seen = closureFrom steps rest seen out
  | otherwise =
    let next = optionOr [] (omLookup k steps)
    closureFrom
      steps
      (fold (acc n => n :: acc) rest next)
      (omInsert k () seen)
      (k :: out)

-- The interface keys of every constraint written anywhere in [ty].
tyConstraintKeys : Ty -> List String -> List String
tyConstraintKeys (TyCon { tyConName = _ }) acc = acc
tyConstraintKeys (TyVar _) acc = acc
tyConstraintKeys (TyApp a b) acc = tyConstraintKeys a (tyConstraintKeys b acc)
tyConstraintKeys (TyFun a b) acc = tyConstraintKeys a (tyConstraintKeys b acc)
tyConstraintKeys (TyTuple ts) acc =
  fold (acc2 t => tyConstraintKeys t acc2) acc ts
tyConstraintKeys (TyEffect _ _ t) acc = tyConstraintKeys t acc
tyConstraintKeys (TyConstrained cs t) acc =
  tyConstraintKeys
    t
    (fold
      (acc2 c => ifaceIdentity c.constraintOrigin c.constraintHead :: acc2)
      acc
      cs)
tyConstraintKeys (TyNamed _ t _) acc = tyConstraintKeys t acc
tyConstraintKeys (TyQual t _ _) acc = tyConstraintKeys t acc
tyConstraintKeys (TyRow _ _ _) acc = acc
tyConstraintKeys (TyAuth _ _) acc = acc

-- ── nodes ────────────────────────────────────────────────────────────────────

-- One node before its walk: [rnodeArity] is the declared parameter count, [rnodeKey] an
-- impl's interface key and [rnodeOrphan] whether neither the impl's interface nor its head
-- type is declared here.
data RawNode = RawNode {
  rnodeName : String,
  rnodeKind : InitNodeKind,
  rnodeArity : Int,
  rnodeLoc : Option Loc,
  rnodeBodies : List (List Pat, Expr),
  rnodeKey : String,
  rnodeOrphan : Bool,
}

-- The walk's fixed context: the inputs, each local top-level binding's arity, the local
-- impl nodes (all, by interface key, and the orphans), and the prefix of a mangled seed
-- this module defines.
data InitWalk = InitWalk {
  iwInputs : InitInputs,
  iwTop : OrdMap Int,
  iwImpls : List String,
  iwImplsByKey : OrdMap (List String),
  iwOrphans : List String,
  iwSeedPrefix : String,
  iwLocalMethods : OrdMap Unit,
}

-- The source-ordered raw nodes of [decls], a multi-clause function's run of `DFunDef`s
-- folded into one node.
rawNodes : String -> List Decl -> List RawNode
rawNodes mid decls = reverseL (rawNodesGo mid 0 decls [])

rawNodesGo : String -> Int -> List Decl -> List RawNode -> List RawNode
rawNodesGo _ _ [] acc = acc
rawNodesGo mid k ((DAttrib _ d) :: rest) acc = rawNodesGo mid k (d :: rest) acc
rawNodesGo mid k ((DFunDef _ n ps body site _) :: rest) acc =
  rawNodesGo mid k rest (addClause n ps body site acc)
rawNodesGo mid k ((DLetGroup _ binds) :: rest) acc =
  rawNodesGo
    mid
    k
    rest
    (fold
      (acc2 b => match b
        LetBind n clauses site _ =>
          bindingNode
              n
              (map
                (c => match c
                  FunClause ps body => (ps, body))
                clauses)
              (Some site)
            :: acc2)
      acc
      binds)
rawNodesGo mid k ((DImpl { iface, tys, methods, implOrigin }) :: rest) acc =
  let node = RawNode {
    rnodeName = "impl#\{intToString k}:\{iface}",
    rnodeKind = ImplNode,
    rnodeArity = 0,
    rnodeLoc = None,
    rnodeBodies =
      map
        (m => match m
          ImplMethod _ ps body => (ps, body))
        methods,
    rnodeKey = ifaceIdentity implOrigin iface,
    rnodeOrphan =
      not (declaredIn mid implOrigin) && not (any (headDeclaredIn mid) tys),
  }
  rawNodesGo mid (k + 1) rest (node :: acc)
rawNodesGo mid k ((DTypeSig _ _ _ _) :: rest) acc = rawNodesGo mid k rest acc
rawNodesGo mid k ((DExtern _) :: rest) acc = rawNodesGo mid k rest acc
rawNodesGo mid k ((DData { dataName = _ }) :: rest) acc =
  rawNodesGo mid k rest acc
rawNodesGo mid k ((DUse _ _ _) :: rest) acc = rawNodesGo mid k rest acc
rawNodesGo mid k ((DEffect _ _ _ _ _ _) :: rest) acc = rawNodesGo mid k rest acc
rawNodesGo mid k ((DProp _ _ _ _) :: rest) acc = rawNodesGo mid k rest acc
rawNodesGo mid k ((DTest _ _ _) :: rest) acc = rawNodesGo mid k rest acc
rawNodesGo mid k ((DInterface { ifaceOrigin = _ }) :: rest) acc =
  rawNodesGo mid k rest acc
rawNodesGo mid k ((DTypeAlias { tyAliasName = _ }) :: rest) acc =
  rawNodesGo mid k rest acc
rawNodesGo mid k ((DNewtype { newtypeName = _ }) :: rest) acc =
  rawNodesGo mid k rest acc

-- A clause continuing the run of its function's clauses joins that node.
addClause : String -> List Pat -> Expr -> Loc -> List RawNode -> List RawNode
addClause n ps body _ (prev :: older)
  | prev.rnodeName == n && prev.rnodeKind /= ImplNode =
    -- Bound: one step per clause of one function.
    -- lint-disable-next-line rule-accumulator-append
    { prev | rnodeBodies = prev.rnodeBodies ++ [(ps, body)] } :: older
addClause n ps body site acc = bindingNode n [(ps, body)] (Some site) :: acc

bindingNode : String -> List (List Pat, Expr) -> Option Loc -> RawNode
bindingNode n bodies loc = RawNode {
  rnodeName = n,
  rnodeKind = FunctionNode,
  rnodeArity = match bodies
    (ps, _) :: _ => length ps
    [] => 0,
  rnodeLoc = loc,
  rnodeBodies = bodies,
  rnodeKey = "",
  rnodeOrphan = False,
}

declaredIn : String -> TyConOrigin -> Bool
declaredIn mid (OriginModule m) = m == mid
declaredIn _ _ = False

-- Whether the head type constructor of [ty] is declared in [mid]; an unresolved or
-- headless type is not, so an impl over it counts as an orphan.
headDeclaredIn : String -> Ty -> Bool
headDeclaredIn mid (TyCon { tyConOrigin }) = declaredIn mid tyConOrigin
headDeclaredIn mid (TyApp f _) = headDeclaredIn mid f
headDeclaredIn _ (TyVar _) = False
headDeclaredIn _ (TyFun _ _) = False
headDeclaredIn _ (TyTuple _) = False
headDeclaredIn mid (TyEffect _ _ t) = headDeclaredIn mid t
headDeclaredIn mid (TyConstrained _ t) = headDeclaredIn mid t
headDeclaredIn mid (TyNamed _ t _) = headDeclaredIn mid t
headDeclaredIn mid (TyQual t _ _) = headDeclaredIn mid t
headDeclaredIn _ (TyRow _ _ _) = False
headDeclaredIn _ (TyAuth _ _) = False

-- A local interface's default bodies, by interface key: they run as part of every local
-- impl of that interface.
localDefaults : List Decl ->
  OrdMap (List (List Pat, Expr)) ->
  OrdMap (List (List Pat, Expr))
localDefaults [] acc = acc
localDefaults ((DAttrib _ d) :: rest) acc = localDefaults (d :: rest) acc
localDefaults ((DInterface { name, methods, ifaceOrigin }) :: rest) acc =
  let bodies =
    flatMap
      (m => match m
        IfaceMethod _ _ (Some (MethodDefault ps body)) _ => [(ps, body)]
        IfaceMethod _ _ None _ => [])
      methods
  localDefaults rest (omInsert (ifaceIdentity ifaceOrigin name) bodies acc)
localDefaults (_ :: rest) acc = localDefaults rest acc

localMethodNames : List Decl -> OrdMap Unit -> OrdMap Unit
localMethodNames [] acc = acc
localMethodNames ((DAttrib _ d) :: rest) acc = localMethodNames (d :: rest) acc
localMethodNames ((DInterface { methods, ifaceOrigin = _ }) :: rest) acc =
  localMethodNames
    rest
    (fold
      (a m => match m
        IfaceMethod n _ _ _ => omInsert n () a)
      acc
      methods)
localMethodNames (_ :: rest) acc = localMethodNames rest acc

-- ── the graph ────────────────────────────────────────────────────────────────

export
initGraphOf : InitInputs -> InitGraph
initGraphOf inputs =
  let raw = map (classify inputs) (rawNodes inputs.iiModule inputs.iiDecls)
  let impls = filter (n => n.rnodeKind == ImplNode) raw
  let w = InitWalk {
    iwInputs = inputs,
    iwTop =
      fold
        (acc n =>
          if n.rnodeKind == ImplNode then
            acc
          else
            omInsert n.rnodeName n.rnodeArity acc)
        omEmpty
        raw,
    iwImpls = map (n => n.rnodeName) impls,
    iwImplsByKey =
      fold
        (acc n => addSteps n.rnodeKey [n.rnodeName] acc)
        omEmpty
        (reverseL impls),
    iwOrphans = map (n => n.rnodeName) (filter (n => n.rnodeOrphan) impls),
    iwSeedPrefix = "\{inputs.iiModule}__",
    iwLocalMethods = localMethodNames inputs.iiDecls omEmpty,
  }
  let defaults = localDefaults inputs.iiDecls omEmpty
  InitGraph {
    igraphNodes = walkNodes w defaults 0 raw [],
    igraphNotInitialised =
      fold
        (acc n =>
          if n.rnodeArity == 0
            && n.rnodeKind /= ImplNode
            && (omHasKey n.rnodeName inputs.iiExempt
              || omHasKey n.rnodeName inputs.iiConstrained) then
            omInsert n.rnodeName () acc
          else
            acc)
        omEmpty
        raw,
  }

-- A nullary binding is a value unless it carries a class constraint (I6).
classify : InitInputs -> RawNode -> RawNode
classify inputs n =
  if n.rnodeKind == FunctionNode
    && n.rnodeArity == 0
    && not (omHasKey n.rnodeName inputs.iiConstrained) then
    { n | rnodeKind = ValueNode }
  else
    n

walkNodes : InitWalk ->
  OrdMap (List (List Pat, Expr)) ->
  Int ->
  List RawNode ->
  List InitNode ->
  List InitNode
walkNodes _ _ _ [] acc = reverseL acc
walkNodes w defaults k (n :: rest) acc =
  let own = walkBodies w n.rnodeBodies []
  let mentions =
    if n.rnodeKind == ImplNode then
      walkBodies w (optionOr [] (omLookup n.rnodeKey defaults)) own
    else
      own
  walkNodes
    w
    defaults
    (k + 1)
    rest
    (InitNode {
        inodeName = n.rnodeName,
        inodeKind = n.rnodeKind,
        inodeOrder = k,
        inodeLoc = n.rnodeLoc,
        inodeMentions = reverseL mentions,
      }
      :: acc)

walkBodies : InitWalk ->
  List (List Pat, Expr) ->
  List InitMention ->
  List InitMention
walkBodies w bodies acc =
  fold
    (acc2 b => match b
      (ps, body) => walk w CtxReturn (bindPats ps omEmpty) body acc2)
    acc
    bodies

-- ── the walk ─────────────────────────────────────────────────────────────────

-- Where an expression sits: the whole right-hand side; a constructor component; anywhere
-- inside a guarded lambda; an evaluated position; a delayed lambda.  The last three absorb
-- everything below them.
data WalkCtx = CtxReturn | CtxGuard | CtxGuardBody | CtxDeref | CtxDelay

-- The position of a name read at [ctx].
namePos : WalkCtx -> InitPosition
namePos CtxReturn = AtDeref
namePos CtxGuard = AtGuard
namePos CtxGuardBody = AtGuard
namePos CtxDeref = AtDeref
namePos CtxDelay = AtDelay

-- The context of a subexpression that is evaluated when its parent is.
evalCtx : WalkCtx -> WalkCtx
evalCtx CtxReturn = CtxDeref
evalCtx CtxGuard = CtxDeref
evalCtx CtxGuardBody = CtxGuardBody
evalCtx CtxDeref = CtxDeref
evalCtx CtxDelay = CtxDelay

-- The context of a component its parent stores without inspecting.
componentCtx : WalkCtx -> WalkCtx
componentCtx CtxReturn = CtxGuard
componentCtx CtxGuard = CtxGuard
componentCtx CtxGuardBody = CtxGuardBody
componentCtx CtxDeref = CtxDeref
componentCtx CtxDelay = CtxDelay

-- The context of a lambda body: a guarded lambda is not called during initialisation; a
-- lambda in an evaluated position may be.
lambdaCtx : WalkCtx -> WalkCtx
lambdaCtx CtxReturn = CtxGuardBody
lambdaCtx CtxGuard = CtxGuardBody
lambdaCtx CtxGuardBody = CtxGuardBody
lambdaCtx CtxDeref = CtxDeref
lambdaCtx CtxDelay = CtxDelay

isGuarded : WalkCtx -> Bool
isGuarded CtxReturn = True
isGuarded CtxGuard = True
isGuarded CtxGuardBody = False
isGuarded CtxDeref = False
isGuarded CtxDelay = False

walk : InitWalk ->
  WalkCtx ->
  OrdMap Unit ->
  Expr ->
  List InitMention ->
  List InitMention
walk _ _ _ (ELit _) acc = acc
walk w ctx bound (EVar n) acc = nameRef w ctx bound n acc
walk w ctx bound (EApp f x) acc = walkApp w ctx bound (EApp f x) acc
walk w ctx bound (ELam ps body) acc =
  walk w (lambdaCtx ctx) (bindPats ps bound) body acc
walk w ctx bound (ELet _ r p e1 e2) acc =
  let after = bindPat p bound
  walk w ctx after e2 (walk w (evalCtx ctx) (if r then after else bound) e1 acc)
walk w ctx bound (EMatch e0 arms) acc =
  walkArms w ctx bound arms (walk w (evalCtx ctx) bound e0 acc)
walk w ctx bound (EIf c t e) acc =
  walk w ctx bound e (walk w ctx bound t (walk w (evalCtx ctx) bound c acc))
walk w ctx bound (EBinOp op l r _) acc =
  if op == "::" then
    walk w (componentCtx ctx) bound r (walk w (componentCtx ctx) bound l acc)
  else
    operatorRef
      w
      ctx
      (w.iwInputs.iiBinopMethod op)
      (walk w (evalCtx ctx) bound r (walk w (evalCtx ctx) bound l acc))
walk w ctx bound (EUnOp op x _) acc =
  operatorRef
    w
    ctx
    (w.iwInputs.iiUnopMethod op)
    (walk w (evalCtx ctx) bound x acc)
walk w ctx bound (EInfix op l r) acc =
  nameRef
    w
    (evalCtx ctx)
    bound
    op
    (walk w (evalCtx ctx) bound r (walk w (evalCtx ctx) bound l acc))
walk w ctx bound (EFieldAccess e0 _ _) acc = walk w (evalCtx ctx) bound e0 acc
walk w ctx bound (ETuple es) acc = walkAll w (componentCtx ctx) bound es acc
walk w ctx bound (EListLit es) acc = walkAll w (componentCtx ctx) bound es acc
walk w ctx bound (EArrayLit es) acc = walkAll w (componentCtx ctx) bound es acc
walk w ctx bound (ERangeList a b _) acc =
  walk w (evalCtx ctx) bound b (walk w (evalCtx ctx) bound a acc)
walk w ctx bound (ERangeArray a b _) acc =
  walk w (evalCtx ctx) bound b (walk w (evalCtx ctx) bound a acc)
walk w ctx bound (ESlice a lo hi _) acc =
  sugarMethodRef w ctx "slice" (walkAll w (evalCtx ctx) bound [a, lo, hi] acc)
walk w ctx bound (ELetGroup binds body) acc =
  let inner =
    fold
      (b2 lb => match lb
        LetBind n _ _ _ => omInsert n () b2)
      bound
      binds
  walk w ctx inner body (walkLetBinds w (evalCtx ctx) inner binds acc)
walk w ctx bound (ESection s) acc = walkSection w ctx bound s acc
walk w ctx bound (EIndex a i) acc =
  sugarMethodRef w ctx "index" (walkAll w (evalCtx ctx) bound [a, i] acc)
walk w ctx bound (EAnnot e0 _) acc = walk w ctx bound e0 acc
walk w ctx bound (EHeadAnnot e0 _) acc = walk w ctx bound e0 acc
walk w ctx bound (EBlock stmts) acc = walkStmts w ctx bound stmts acc
walk w ctx bound (EDo deferred stmts) acc =
  sugarMethodRef
    w
    ctx
    (if deferred then "deferThen" else "andThen")
    (walkStmts w (evalCtx ctx) bound stmts acc)
walk w ctx bound (EStringInterp parts) acc =
  sugarMethodRef
    w
    ctx
    "display"
    (fold
      (acc2 p => match p
        InterpStr _ => acc2
        InterpExpr e0 => walk w (evalCtx ctx) bound e0 acc2)
      acc
      parts)
walk w ctx bound (EGuards arms) acc =
  fold
    (acc2 a => match a
      GuardArm gs body => walkGuarded w ctx bound gs body acc2)
    acc
    arms
walk w ctx bound (ERecordCreate _ fs) acc =
  walkFields w (componentCtx ctx) bound fs acc
walk w ctx bound (ERecordUpdate e0 fs _) acc =
  walkFields w (componentCtx ctx) bound fs (walk w (evalCtx ctx) bound e0 acc)
walk w ctx bound (EVariantUpdate _ e0 fs) acc =
  walkFields w (componentCtx ctx) bound fs (walk w (evalCtx ctx) bound e0 acc)
walk w ctx bound (EMapLit _ kvs) acc =
  sugarMethodRef
    w
    ctx
    "fromEntries"
    (fold
      (acc2 kv =>
        walk
          w
          (evalCtx ctx)
          bound
          (snd kv)
          (walk w (evalCtx ctx) bound (fst kv) acc2))
      acc
      kvs)
walk w ctx bound (ESetLit _ es) acc =
  sugarMethodRef w ctx "fromEntries" (walkAll w (evalCtx ctx) bound es acc)
walk w ctx bound (EAsPat _ e0) acc = walk w (evalCtx ctx) bound e0 acc
walk w ctx bound (EOrPat es) acc = walkAll w (evalCtx ctx) bound es acc
walk w ctx bound (EMethodRef n) acc = methodRef w ctx bound n "" acc
walk w ctx bound (EDictApp n) acc = dictRef w ctx bound n acc
walk w ctx bound (EVarAt n _) acc = nameRef w ctx bound n acc
walk w ctx bound (EVarId n _) acc = nameRef w ctx bound n acc
walk w ctx bound (EMethodAt m seed _) acc = methodRef w ctx bound m seed acc
walk w ctx bound (EDictAt n _) acc = dictRef w ctx bound n acc
walk w ctx bound (ELoc _ e0) acc = walk w ctx bound e0 acc
walk w ctx bound (EDoOrigin _ e0) acc = walk w ctx bound e0 acc
walk w ctx _ (ENumLit _ _ _) acc = operatorRef w ctx (Some "fromInt") acc
walk w ctx _ (EWideLit _ _ _ _) acc = operatorRef w ctx (Some "fromInt") acc

walkAll : InitWalk ->
  WalkCtx ->
  OrdMap Unit ->
  List Expr ->
  List InitMention ->
  List InitMention
walkAll w ctx bound es acc = fold (acc2 e => walk w ctx bound e acc2) acc es

walkFields : InitWalk ->
  WalkCtx ->
  OrdMap Unit ->
  List FieldAssign ->
  List InitMention ->
  List InitMention
walkFields w ctx bound fs acc =
  fold
    (acc2 f => match f
      FieldAssign _ e => walk w ctx bound e acc2)
    acc
    fs

-- A local function's body is walked as called: a binding group in an evaluated
-- position can run it.
walkLetBinds : InitWalk ->
  WalkCtx ->
  OrdMap Unit ->
  List LetBind ->
  List InitMention ->
  List InitMention
walkLetBinds w ctx bound binds acc =
  fold
    (acc2 b => match b
      LetBind _ clauses _ _ =>
        fold
          (acc3 c => match c
            FunClause ps body => walk w ctx (bindPats ps bound) body acc3)
          acc2
          clauses)
    acc
    binds

walkArms : InitWalk ->
  WalkCtx ->
  OrdMap Unit ->
  List Arm ->
  List InitMention ->
  List InitMention
walkArms w ctx bound arms acc =
  fold
    (acc2 a => match a
      Arm p gs body => walkGuarded w ctx (bindPat p bound) gs body acc2)
    acc
    arms

walkGuarded : InitWalk ->
  WalkCtx ->
  OrdMap Unit ->
  List Guard ->
  Expr ->
  List InitMention ->
  List InitMention
walkGuarded w ctx bound [] body acc = walk w ctx bound body acc
walkGuarded w ctx bound ((GBool e) :: gs) body acc =
  walkGuarded w ctx bound gs body (walk w (evalCtx ctx) bound e acc)
walkGuarded w ctx bound ((GBind p e) :: gs) body acc =
  walkGuarded w ctx (bindPat p bound) gs body (walk w (evalCtx ctx) bound e acc)

-- A block's last statement is its result and keeps [ctx]; every earlier one is evaluated.
walkStmts : InitWalk ->
  WalkCtx ->
  OrdMap Unit ->
  List DoStmt ->
  List InitMention ->
  List InitMention
walkStmts _ _ _ [] acc = acc
walkStmts w ctx bound [DoExpr e] acc = walk w ctx bound e acc
walkStmts w ctx bound ((DoExpr e) :: rest) acc =
  walkStmts w ctx bound rest (walk w (evalCtx ctx) bound e acc)
walkStmts w ctx bound ((DoBind p e) :: rest) acc =
  walkStmts w ctx (bindPat p bound) rest (walk w (evalCtx ctx) bound e acc)
walkStmts w ctx bound ((DoLet _ r p e _) :: rest) acc =
  let after = bindPat p bound
  walkStmts
    w
    ctx
    after
    rest
    (walk w (evalCtx ctx) (if r then after else bound) e acc)
walkStmts w ctx bound ((DoAssign x e) :: rest) acc =
  walkStmts w ctx (omInsert x () bound) rest (walk w (evalCtx ctx) bound e acc)
walkStmts w ctx bound ((DoFieldAssign _ _ e) :: rest) acc =
  walkStmts w ctx bound rest (walk w (evalCtx ctx) bound e acc)

walkSection : InitWalk ->
  WalkCtx ->
  OrdMap Unit ->
  Section ->
  List InitMention ->
  List InitMention
walkSection w ctx bound (SecBare op) acc = sectionOp w ctx bound op acc
walkSection w ctx bound (SecRight op e) acc =
  sectionOp w ctx bound op (walk w (evalCtx ctx) bound e acc)
walkSection w ctx bound (SecLeft e op) acc =
  sectionOp w ctx bound op (walk w (evalCtx ctx) bound e acc)

-- A section's operator is a name or a builtin operator; it may dispatch either way.
sectionOp : InitWalk ->
  WalkCtx ->
  OrdMap Unit ->
  String ->
  List InitMention ->
  List InitMention
sectionOp w ctx bound op acc =
  nameRef
    w
    (evalCtx ctx)
    bound
    op
    (operatorRef
      w
      ctx
      (w.iwInputs.iiBinopMethod op)
      (operatorRef w ctx (w.iwInputs.iiUnopMethod op) acc))

-- ── applications ─────────────────────────────────────────────────────────────

-- How an application at a guarded position evaluates.  A constructor application stores
-- its arguments; an under-saturated call of a local function builds a closure; a
-- `Deferred*` call delays its direct lambda arguments; anything else is a call.
data AppShape = ShapeCtor | ShapePartial | ShapeDefer | ShapeCall

-- The application head and its arguments, through the transparent wrappers on the head.
spine : Expr -> List Expr -> (Expr, List Expr)
spine (EApp f x) args = spine f (x :: args)
spine (ELoc _ e) args = spine e args
spine (EDoOrigin _ e) args = spine e args
spine (EHeadAnnot e _) args = spine e args
spine (EAnnot e _) args = spine e args
spine e args = (e, args)

walkApp : InitWalk ->
  WalkCtx ->
  OrdMap Unit ->
  Expr ->
  List InitMention ->
  List InitMention
walkApp w ctx bound e acc =
  let (hd, args) = spine e []
  match appShape w ctx bound hd (length args)
    ShapeCtor => walkAll w (componentCtx ctx) bound args acc
    ShapePartial =>
      walkAll
        w
        (componentCtx ctx)
        bound
        args
        (walk w (componentCtx ctx) bound hd acc)
    ShapeDefer =>
      fold
        (acc2 a => walkDeferArg w bound a acc2)
        (walk w (evalCtx ctx) bound hd acc)
        args
    ShapeCall =>
      walkAll w (evalCtx ctx) bound args (walk w (evalCtx ctx) bound hd acc)

-- A direct lambda argument of a `Deferred*` call is delayed; any other argument, the
-- receiver included, is evaluated.
walkDeferArg : InitWalk ->
  OrdMap Unit ->
  Expr ->
  List InitMention ->
  List InitMention
walkDeferArg w bound a acc = match directLambda a
  Some (ps, body) => walk w CtxDelay (bindPats ps bound) body acc
  None => walk w CtxDeref bound a acc

directLambda : Expr -> Option (List Pat, Expr)
directLambda (ELam ps body) = Some (ps, body)
directLambda (ELoc _ e) = directLambda e
directLambda (EAnnot e _) = directLambda e
directLambda _ = None

appShape : InitWalk -> WalkCtx -> OrdMap Unit -> Expr -> Int -> AppShape
appShape w ctx bound (EVar n) nargs = nameShape w ctx bound n nargs
appShape w ctx bound (EVarId n _) nargs = nameShape w ctx bound n nargs
appShape w ctx bound (EVarAt n _) nargs = nameShape w ctx bound n nargs
appShape w ctx bound (EDictAt n _) nargs = nameShape w ctx bound n nargs
appShape w ctx bound (EMethodAt m "" _) _ =
  if isGuarded ctx && isPreludeDefer w bound m then ShapeDefer else ShapeCall
appShape _ _ _ _ _ = ShapeCall

nameShape : InitWalk -> WalkCtx -> OrdMap Unit -> String -> Int -> AppShape
nameShape w ctx bound n nargs
  | omHasKey n bound = ShapeCall
  | otherwise = match omLookup n w.iwTop
    Some arity =>
      if isGuarded ctx && nargs < arity then ShapePartial else ShapeCall
    None =>
      if isCtorName n then
        ShapeCtor
      else if isGuarded ctx && isPreludeDefer w bound n then
        ShapeDefer
      else
        ShapeCall

-- Whether [n] names the prelude's `Deferred*` method: the prelude spelling, and neither a
-- local binder, a local top-level binding, a local interface's method nor an import of the
-- module binds it.  This is the spelling plus a shadow check, not a resolved identity.
isPreludeDefer : InitWalk -> OrdMap Unit -> String -> Bool
isPreludeDefer w bound n =
  isDeferSpelling (bareSpelling n)
    && not (omHasKey n bound)
    && not (omHasKey n w.iwTop)
    && not (omHasKey n w.iwLocalMethods)
    && not (omHasKey n w.iwInputs.iiImportedValues)

isDeferSpelling : String -> Bool
isDeferSpelling "deferThen" = True
isDeferSpelling "deferMap" = True
isDeferSpelling "deferAp" = True
isDeferSpelling "deferFlatMap" = True
isDeferSpelling _ = False

-- A constructor spelling: its last dotted segment starts with an upper-case letter.
isCtorName : String -> Bool
isCtorName n = match nextChar (startCursor n)
  None => False
  Some (c, _) =>
    if not (charIsUpper c) then
      False
    else match stringIndexOf "." n
      None => True
      Some _ => match last (split "." n)
        Some seg => isCtorName seg
        None => False

bareSpelling : String -> String
bareSpelling n = optionOr n (stripPrefix "$core." n)

-- ── references ───────────────────────────────────────────────────────────────

mention : String -> InitEdgeKind -> InitPosition -> InitMention
mention t k p = InitMention {
  mentionTarget = t,
  mentionKind = k,
  mentionPosition = p,
}

-- A plain name: a local binder reaches nothing, a top-level binding is a node, and any
-- other value may be a method or reach a local orphan impl.
nameRef : InitWalk ->
  WalkCtx ->
  OrdMap Unit ->
  String ->
  List InitMention ->
  List InitMention
nameRef w ctx bound n acc
  | omHasKey n bound = acc
  | omHasKey n w.iwTop = mention n ByName (namePos ctx) :: acc
  | otherwise =
    let pos = namePos ctx
    let viaMethod = match methodKeys w n
      Some keys => dispatchTo w ByDispatch pos keys acc
      None => acc
    foreignRef w pos n viaMethod

-- A constrained call (`EDictAt`): a local callee is a node; another reaches the local
-- impls of its constraints' dispatch closures, every local impl when its constraints are
-- unknown, and the local orphans.
dictRef : InitWalk ->
  WalkCtx ->
  OrdMap Unit ->
  String ->
  List InitMention ->
  List InitMention
dictRef w ctx bound n acc
  | omHasKey n bound = acc
  | omHasKey n w.iwTop = mention n ByName (namePos ctx) :: acc
  | otherwise =
    let pos = namePos ctx
    let viaDict = match omLookup n w.iwInputs.iiCalleeIfaces
      Some keys => dispatchTo w ByDispatch pos keys acc
      None => toEvery w ByDispatch pos acc
    foreignRef w pos n viaDict

-- A method occurrence: its seed names a standalone shadow, and a top-level binding may
-- share the method's spelling; the method reaches every local impl when its spelling is
-- unknown.
methodRef : InitWalk ->
  WalkCtx ->
  OrdMap Unit ->
  String ->
  String ->
  List InitMention ->
  List InitMention
methodRef w ctx bound m seed acc =
  let pos = namePos ctx
  let asName =
    if omHasKey m w.iwTop && not (omHasKey m bound) then
      mention m ByName pos :: acc
    else
      acc
  let viaSeed =
    if seed == "" then
      asName
    else match stripPrefix w.iwSeedPrefix seed
      Some local if omHasKey local w.iwTop => mention local ByName pos :: asName
      _ => foreignRef w pos seed asName
  match methodKeys w m
    Some keys => dispatchTo w ByDispatch pos keys viaSeed
    None => toEvery w ByDispatch pos viaSeed

-- A method the desugarer introduced for sugar that survived to this tree.
sugarMethodRef : InitWalk ->
  WalkCtx ->
  String ->
  List InitMention ->
  List InitMention
sugarMethodRef w ctx m acc = match methodKeys w m
  Some keys => dispatchTo w ByDispatch (namePos (evalCtx ctx)) keys acc
  None => toEvery w ByDispatch (namePos (evalCtx ctx)) acc

-- An operator or literal runs its method where it is evaluated.  A method no interface
-- declares has no impl to reach.
operatorRef : InitWalk ->
  WalkCtx ->
  Option String ->
  List InitMention ->
  List InitMention
operatorRef _ _ None acc = acc
operatorRef w ctx (Some m) acc = match methodKeys w m
  Some keys => dispatchTo w ByOperator (namePos (evalCtx ctx)) keys acc
  None => acc

-- An imported or prelude value reaches the local orphan impls (constructors are not
-- values that run code).
foreignRef : InitWalk ->
  InitPosition ->
  String ->
  List InitMention ->
  List InitMention
foreignRef w pos n acc =
  if isEmptyL w.iwOrphans || isCtorName n then
    acc
  else
    fold (acc2 o => mention o ByOrphan pos :: acc2) acc w.iwOrphans

methodKeys : InitWalk -> String -> Option (List String)
methodKeys w n =
  let table = w.iwInputs.iiMethodIfaces
  let bare = bareSpelling n
  match omLookup bare table
    Some keys => Some keys
    None => match last (split "." bare)
      Some seg if seg /= bare => omLookup seg table
      _ => None

-- The local impls a site dispatching on [keys] reaches: for each key, the impls of every
-- interface of its dispatch closure, and the impls whose interface is unknown.
dispatchTo : InitWalk ->
  InitEdgeKind ->
  InitPosition ->
  List String ->
  List InitMention ->
  List InitMention
dispatchTo w kind pos keys acc =
  if isEmptyL w.iwImpls then
    acc
  else
    fold (acc2 key => dispatchKey w kind pos key acc2) acc keys

dispatchKey : InitWalk ->
  InitEdgeKind ->
  InitPosition ->
  String ->
  List InitMention ->
  List InitMention
dispatchKey w kind pos key acc
  | key == "" = toEvery w kind pos acc
  | otherwise =
    let closure = optionOr [key] (omLookup key w.iwInputs.iiDispatchClosure)
    fold
      (acc2 k =>
        if k == "" then
          toEvery w kind pos acc2
        else
          toImpls
            (if k == key then kind else ByClosure)
            pos
            (optionOr [] (omLookup k w.iwImplsByKey))
            acc2)
      (toImpls kind pos (optionOr [] (omLookup "" w.iwImplsByKey)) acc)
      closure

toEvery : InitWalk ->
  InitEdgeKind ->
  InitPosition ->
  List InitMention ->
  List InitMention
toEvery w kind pos acc = toImpls kind pos w.iwImpls acc

toImpls : InitEdgeKind ->
  InitPosition ->
  List String ->
  List InitMention ->
  List InitMention
toImpls kind pos impls acc =
  fold (acc2 i => mention i kind pos :: acc2) acc impls

-- ── binders ──────────────────────────────────────────────────────────────────

bindPats : List Pat -> OrdMap Unit -> OrdMap Unit
bindPats ps bound = fold (b p => bindPat p b) bound ps

bindPat : Pat -> OrdMap Unit -> OrdMap Unit
bindPat (PVar n _ _) bound = omInsert n () bound
bindPat PWild bound = bound
bindPat (PLit _) bound = bound
bindPat (PCon _ ps) bound = bindPats ps bound
bindPat (PCons h t) bound = bindPat t (bindPat h bound)
bindPat (PTuple ps) bound = bindPats ps bound
bindPat (PList ps) bound = bindPats ps bound
bindPat (PAs n _ _ p) bound = bindPat p (omInsert n () bound)
bindPat (POr ps) bound = bindPats ps bound
bindPat (PRng _ _ _) bound = bound
bindPat (PRec _ fields _) bound =
  fold
    (b f => match f
      RecPatField n _ _ None => omInsert n () b
      RecPatField _ _ _ (Some p) => bindPat p b)
    bound
    fields
bindPat (PAnn p _) bound = bindPat p bound

-- ── the order ────────────────────────────────────────────────────────────────

-- I1: the value nodes, dependency-first, ties by source position, over every mention.
-- A value's initialiser can call a function or a closure it reads, so what the initialiser
-- reaches is the whole may-reach relation, not its evaluated positions alone.  A
-- strongly connected component is emitted when every component it reaches has been, the
-- ready component with the earliest member first, and its members in source order.
export
initOrder : InitGraph -> List String
initOrder g =
  let nodes = g.igraphNodes
  let adj =
    omFromPairs
      (map
        (n => (n.inodeName, map (m => m.mentionTarget) n.inodeMentions))
        nodes)
      omEmpty
  let sccs = tarjanSCCs (map (n => n.inodeName) nodes) adj
  let compOf = componentIndex sccs 0 omEmpty
  let members = componentMembers compOf (reverseL nodes) empty
  let deps = componentDeps compOf nodes empty
  let indegree = M.mapWithKey (_ ds => M.size ds) deps
  let dependents =
    M.foldrWithKey
      (s ds acc =>
        M.foldrWithKey
          (d _ acc2 => M.set d (s :: optionOr [] (M.get d acc2)) acc2)
          acc
          ds)
      empty
      deps
  let ready =
    M.foldrWithKey
      (s ms acc =>
        if optionOr 0 (M.get s indegree) == 0 then
          M.set (firstOrder ms) s acc
        else
          acc)
      empty
      members
  reverseL (kahn g members dependents indegree ready [])

componentIndex : List (List String) -> Int -> OrdMap Int -> OrdMap Int
componentIndex [] _ acc = acc
componentIndex (c :: rest) i acc =
  componentIndex rest (i + 1) (fold (a n => omInsert n i a) acc c)

-- Each component's member nodes, in source order ([nodes] arrives reversed).
componentMembers : OrdMap Int ->
  List InitNode ->
  M.Map Int (List InitNode) ->
  M.Map Int (List InitNode)
componentMembers _ [] acc = acc
componentMembers compOf (n :: rest) acc =
  let c = optionOr 0 (omLookup n.inodeName compOf)
  componentMembers compOf rest (M.set c (n :: optionOr [] (M.get c acc)) acc)

-- Each component's set of other components it reaches.
componentDeps : OrdMap Int ->
  List InitNode ->
  M.Map Int (M.Map Int Unit) ->
  M.Map Int (M.Map Int Unit)
componentDeps _ [] acc = acc
componentDeps compOf (n :: rest) acc =
  let c = optionOr 0 (omLookup n.inodeName compOf)
  let mine =
    fold
      (s m => match omLookup m.mentionTarget compOf
        Some d => if d == c then s else M.set d () s
        None => s)
      (optionOr empty (M.get c acc))
      n.inodeMentions
  componentDeps compOf rest (M.set c mine acc)

firstOrder : List InitNode -> Int
firstOrder [] = 0
firstOrder (n :: _) = n.inodeOrder

kahn : InitGraph ->
  M.Map Int (List InitNode) ->
  M.Map Int (List Int) ->
  M.Map Int Int ->
  M.Map Int Int ->
  List String ->
  List String
kahn g members dependents indegree ready out = match M.minView ready
  None => out
  Some (_, s, rest) =>
    let ms = optionOr [] (M.get s members)
    let out2 =
      fold
        (acc n =>
          if n.inodeKind == ValueNode
            && not (omHasKey n.inodeName g.igraphNotInitialised) then
            n.inodeName :: acc
          else
            acc)
        out
        ms
    let (indegree2, ready2) =
      fold
        (st d => match st
          (deg, rdy) =>
            let left = optionOr 0 (M.get d deg) - 1
            let deg2 = M.set d left deg
            if left == 0 then
              (deg2, M.set (firstOrder (optionOr [] (M.get d members))) d rdy)
            else
              (deg2, rdy))
        (indegree, rest)
        (optionOr [] (M.get s dependents))
    kahn g members dependents indegree2 ready2 out2
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Arm" true) (mem "Constraint" true) (mem "Decl" true) (mem "DoStmt" true) (mem "Expr" true) (mem "FieldAssign" true) (mem "FunClause" true) (mem "Guard" true) (mem "GuardArm" true) (mem "IfaceMethod" true) (mem "ImplMethod" true) (mem "InterpPart" true) (mem "LetBind" true) (mem "Loc" false) (mem "MethodDefault" true) (mem "Pat" true) (mem "RecPatField" true) (mem "Require" true) (mem "Section" true) (mem "Super" true) (mem "Ty" true) (mem "TyConOrigin" true) (mem "ifaceIdentity" false))))
(DUse false (UseGroup ("list") ((mem "last" false))))
(DUse false (UseAlias ("map") "M"))
(DUse false (UseGroup ("string") ((mem "nextChar" false) (mem "split" false) (mem "startCursor" false) (mem "stripPrefix" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omFromPairs" false) (mem "omHasKey" false) (mem "omInsert" false) (mem "omLookup" false) (mem "omMapValues" false))))
(DUse false (UseGroup ("support" "scc") ((mem "tarjanSCCs" false))))
(DUse false (UseGroup ("support" "util") ((mem "isEmptyL" false) (mem "isNonEmptyL" false) (mem "reverseL" false))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "renderAtoms" false) (mem "rowFlat" false))))
(DUse false (UseGroup ("types" "repr") ((mem "IfaceRef" true) (mem "Scheme" true) (mem "VecObl" true))))
(DUse false (UseGroup ("types" "tc_env") ((mem "ceRowIface" false) (mem "ceRowMethods" false) (mem "ceRowSupers" false) (mem "ieRowTriple" false) (mem "ieRowsVisibleAt" false) (mem "methodRowIface" false))))
(DUse false (UseGroup ("types" "tc_types") ((mem "ClassEnv" true) (mem "DeclEnvs" true) (mem "MethodEnv" true) (mem "ModuleBindings" true) (mem "ModuleCtx" true) (mem "ModuleSeed" true))))
(DData Public "InitInputs" () ((variant "InitInputs" (ConNamed (field "iiModule" (TyCon "String")) (field "iiDecls" (TyApp (TyCon "List") (TyCon "Decl"))) (field "iiSchemes" (TyApp (TyCon "OrdMap") (TyCon "Scheme"))) (field "iiMethodIfaces" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String")))) (field "iiDispatchClosure" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String")))) (field "iiCalleeIfaces" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String")))) (field "iiBinopMethod" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))) (field "iiUnopMethod" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))) (field "iiImportedValues" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "iiConstrained" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "iiExempt" (TyApp (TyCon "OrdMap") (TyCon "Unit")))))) ())
(DData Public "InitPosition" () ((variant "AtDeref" (ConPos)) (variant "AtGuard" (ConPos)) (variant "AtDelay" (ConPos))) ())
(DImpl true "Eq" ((TyCon "InitPosition")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "AtDeref") (PCon "AtDeref")) () (EVar "True")) (arm (PTuple (PCon "AtGuard") (PCon "AtGuard")) () (EVar "True")) (arm (PTuple (PCon "AtDelay") (PCon "AtDelay")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "InitPosition")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "AtDeref") () (ELit (LString "AtDeref"))) (arm (PCon "AtGuard") () (ELit (LString "AtGuard"))) (arm (PCon "AtDelay") () (ELit (LString "AtDelay")))))))
(DData Public "InitEdgeKind" () ((variant "ByName" (ConPos)) (variant "ByDispatch" (ConPos)) (variant "ByOperator" (ConPos)) (variant "ByOrphan" (ConPos)) (variant "ByClosure" (ConPos))) ())
(DImpl true "Eq" ((TyCon "InitEdgeKind")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "ByName") (PCon "ByName")) () (EVar "True")) (arm (PTuple (PCon "ByDispatch") (PCon "ByDispatch")) () (EVar "True")) (arm (PTuple (PCon "ByOperator") (PCon "ByOperator")) () (EVar "True")) (arm (PTuple (PCon "ByOrphan") (PCon "ByOrphan")) () (EVar "True")) (arm (PTuple (PCon "ByClosure") (PCon "ByClosure")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "InitEdgeKind")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "ByName") () (ELit (LString "ByName"))) (arm (PCon "ByDispatch") () (ELit (LString "ByDispatch"))) (arm (PCon "ByOperator") () (ELit (LString "ByOperator"))) (arm (PCon "ByOrphan") () (ELit (LString "ByOrphan"))) (arm (PCon "ByClosure") () (ELit (LString "ByClosure")))))))
(DData Public "InitMention" () ((variant "InitMention" (ConNamed (field "mentionTarget" (TyCon "String")) (field "mentionKind" (TyCon "InitEdgeKind")) (field "mentionPosition" (TyCon "InitPosition"))))) ())
(DImpl true "Eq" ((TyCon "InitMention")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PRec "InitMention" ((rf "mentionTarget" (PVar "__a0")) (rf "mentionKind" (PVar "__a1")) (rf "mentionPosition" (PVar "__a2"))) false) (PRec "InitMention" ((rf "mentionTarget" (PVar "__b0")) (rf "mentionKind" (PVar "__b1")) (rf "mentionPosition" (PVar "__b2"))) false)) () (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EVar "eq") (EVar "__a2")) (EVar "__b2"))))))))
(DImpl true "Debug" ((TyCon "InitMention")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PRec "InitMention" ((rf "mentionTarget" (PVar "__a0")) (rf "mentionKind" (PVar "__a1")) (rf "mentionPosition" (PVar "__a2"))) false) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "InitMention {")) (ELit (LString " mentionTarget = "))) (EApp (EVar "debug") (EVar "__a0"))) (ELit (LString ", mentionKind = "))) (EApp (EVar "debug") (EVar "__a1"))) (ELit (LString ", mentionPosition = "))) (EApp (EVar "debug") (EVar "__a2"))) (ELit (LString " }"))))))))
(DData Public "InitNodeKind" () ((variant "ValueNode" (ConPos)) (variant "FunctionNode" (ConPos)) (variant "ImplNode" (ConPos))) ())
(DImpl true "Eq" ((TyCon "InitNodeKind")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "ValueNode") (PCon "ValueNode")) () (EVar "True")) (arm (PTuple (PCon "FunctionNode") (PCon "FunctionNode")) () (EVar "True")) (arm (PTuple (PCon "ImplNode") (PCon "ImplNode")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "InitNodeKind")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "ValueNode") () (ELit (LString "ValueNode"))) (arm (PCon "FunctionNode") () (ELit (LString "FunctionNode"))) (arm (PCon "ImplNode") () (ELit (LString "ImplNode")))))))
(DData Public "InitNode" () ((variant "InitNode" (ConNamed (field "inodeName" (TyCon "String")) (field "inodeKind" (TyCon "InitNodeKind")) (field "inodeOrder" (TyCon "Int")) (field "inodeLoc" (TyApp (TyCon "Option") (TyCon "Loc"))) (field "inodeMentions" (TyApp (TyCon "List") (TyCon "InitMention")))))) ())
(DData Public "InitGraph" () ((variant "InitGraph" (ConNamed (field "igraphNodes" (TyApp (TyCon "List") (TyCon "InitNode"))) (field "igraphNotInitialised" (TyApp (TyCon "OrdMap") (TyCon "Unit")))))) ())
(DData Public "InitViolation" () ((variant "InitViolation" (ConNamed (field "ivName" (TyCon "String")) (field "ivRow" (TyCon "String")) (field "ivLoc" (TyApp (TyCon "Option") (TyCon "Loc")))))) ())
(DTypeSig true "checkInitRules" (TyFun (TyCon "InitInputs") (TyFun (TyCon "InitGraph") (TyApp (TyCon "List") (TyCon "InitViolation")))))
(DFunDef false "checkInitRules" ((PVar "inputs") (PVar "g")) (EApp (EApp (EVar "flatMap") (ELam ((PVar "n")) (EIf (EBinOp "&&" (EBinOp "==" (EFieldAccess (EVar "n") "inodeKind") (EVar "ValueNode")) (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EFieldAccess (EVar "n") "inodeName")) (EFieldAccess (EVar "g") "igraphNotInitialised")))) (EApp (EApp (EVar "purityViolation") (EVar "inputs")) (EVar "n")) (EListLit)))) (EFieldAccess (EVar "g") "igraphNodes")))
(DTypeSig false "purityViolation" (TyFun (TyCon "InitInputs") (TyFun (TyCon "InitNode") (TyApp (TyCon "List") (TyCon "InitViolation")))))
(DFunDef false "purityViolation" ((PVar "inputs") (PVar "n")) (EMatch (EApp (EApp (EVar "omLookup") (EFieldAccess (EVar "n") "inodeName")) (EFieldAccess (EVar "inputs") "iiSchemes")) (arm (PCon "Some" (PCon "Forall" PWild PWild PWild PWild (PVar "force") PWild)) () (EMatch (EApp (EVar "fst") (EApp (EVar "rowFlat") (EVar "force"))) (arm (PList) () (EListLit)) (arm (PVar "labels") () (EListLit (ERecordCreate "InitViolation" ((fa "ivName" (EFieldAccess (EVar "n") "inodeName")) (fa "ivRow" (EBinOp "++" (EBinOp "++" (ELit (LString "<")) (EApp (EVar "display") (EApp (EVar "renderAtoms") (EVar "labels")))) (ELit (LString ">")))) (fa "ivLoc" (EFieldAccess (EVar "n") "inodeLoc")))))))) (arm (PCon "None") () (EListLit))))
(DTypeSig true "initInputsAt" (TyFun (TyCon "String") (TyFun (TyCon "ModuleSeed") (TyFun (TyCon "ModuleBindings") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "DeclEnvs") (TyFun (TyCon "Int") (TyFun (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyFun (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyCon "InitInputs")))))))))))
(DFunDef false "initInputsAt" ((PVar "mid") (PVar "seed") (PVar "bindings") (PVar "marked") (PVar "mctx") (PVar "envs") (PVar "ord") (PVar "binop") (PVar "unop")) (EBlock (DoLet false false (PVar "dispatching") (EApp (EVar "declaresImpl") (EVar "marked"))) (DoExpr (ERecordCreate "InitInputs" ((fa "iiModule" (EVar "mid")) (fa "iiDecls" (EVar "marked")) (fa "iiSchemes" (EFieldAccess (EVar "bindings") "mbStandaloneSchemes")) (fa "iiMethodIfaces" (EIf (EVar "dispatching") (EApp (EVar "methodIfacesOf") (EFieldAccess (EVar "envs") "deMethods")) (EVar "omEmpty"))) (fa "iiDispatchClosure" (EIf (EVar "dispatching") (EApp (EApp (EVar "dispatchClosureOf") (EVar "envs")) (EVar "ord")) (EVar "omEmpty"))) (fa "iiCalleeIfaces" (EIf (EVar "dispatching") (EApp (EVar "calleeIfacesOf") (EVar "mctx")) (EVar "omEmpty"))) (fa "iiBinopMethod" (EVar "binop")) (fa "iiUnopMethod" (EVar "unop")) (fa "iiImportedValues" (EFieldAccess (EVar "seed") "msImportedNames")) (fa "iiConstrained" (EApp (EVar "constrainedOf") (EVar "mctx"))) (fa "iiExempt" (EApp (EApp (EApp (EVar "omInsert") (ELit (LString "main"))) (ELit LUnit)) (EVar "omEmpty"))))))))
(DTypeSig false "declaresImpl" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool")))
(DFunDef false "declaresImpl" ((PList)) (EVar "False"))
(DFunDef false "declaresImpl" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "declaresImpl") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "declaresImpl" ((PCons (PRec "DImpl" ((rf "implOrigin" PWild)) false) PWild)) (EVar "True"))
(DFunDef false "declaresImpl" ((PCons PWild (PVar "rest"))) (EApp (EVar "declaresImpl") (EVar "rest")))
(DTypeSig false "refKey" (TyFun (TyCon "IfaceRef") (TyCon "String")))
(DFunDef false "refKey" ((PVar "r")) (EApp (EApp (EVar "ifaceIdentity") (EFieldAccess (EVar "r") "irOrigin")) (EFieldAccess (EVar "r") "irName")))
(DTypeSig false "methodIfacesOf" (TyFun (TyCon "MethodEnv") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "methodIfacesOf" ((PVar "env")) (EApp (EApp (EVar "omMapValues") (ELam ((PVar "rows")) (EApp (EApp (EVar "map") (ELam ((PVar "r")) (EApp (EVar "refKey") (EApp (EVar "methodRowIface") (EVar "r"))))) (EVar "rows")))) (EFieldAccess (EVar "env") "meByName")))
(DTypeSig false "calleeIfacesOf" (TyFun (TyCon "ModuleCtx") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "calleeIfacesOf" ((PVar "mctx")) (EBlock (DoLet false true (PVar "keysOf") (ELam ((PVar "obls")) (EApp (EApp (EVar "map") (ELam ((PVar "o")) (EApp (EVar "refKey") (EFieldAccess (EVar "o") "voIface")))) (EVar "obls")))) (DoLet false false (PVar "core") (EApp (EApp (EVar "omMapValues") (EVar "keysOf")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "crossRun") "coreSchemeObligationsRef") "value"))) (DoExpr (EApp (EApp (EApp (EVar "M.foldlWithKey") (ELam ((PVar "acc") (PVar "n") (PVar "obls")) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (EApp (EVar "keysOf") (EVar "obls"))) (EVar "acc")))) (EVar "core")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "importedSchemeOblsRef") "value")))))
(DTypeSig false "constrainedOf" (TyFun (TyCon "ModuleCtx") (TyApp (TyCon "OrdMap") (TyCon "Unit"))))
(DFunDef false "constrainedOf" ((PVar "mctx")) (EBlock (DoLet false false (PVar "ids") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "schemeDefIdsRef") "value")) (DoExpr (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "row")) (EMatch (EVar "row") (arm (PTuple (PTuple (PVar "n") (PVar "bid")) (PVar "obls")) () (EIf (EBinOp "&&" (EApp (EVar "isNonEmptyL") (EVar "obls")) (EBinOp "==" (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "ids")) (EApp (EVar "Some") (EVar "bid")))) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (ELit LUnit)) (EVar "acc")) (EVar "acc")))))) (EVar "omEmpty")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "schemeObligationsRef") "value")))))
(DTypeSig false "dispatchClosureOf" (TyFun (TyCon "DeclEnvs") (TyFun (TyCon "Int") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "dispatchClosureOf" ((PVar "envs") (PVar "ord")) (EBlock (DoLet false false (PVar "withSupers") (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "row")) (EApp (EApp (EApp (EVar "addSteps") (EApp (EVar "refKey") (EApp (EVar "ceRowIface") (EVar "row")))) (EBinOp "++" (EApp (EApp (EVar "map") (ELam ((PVar "s")) (EApp (EApp (EVar "ifaceIdentity") (EFieldAccess (EVar "s") "superOrigin")) (EFieldAccess (EVar "s") "superHead")))) (EApp (EVar "ceRowSupers") (EVar "row"))) (EApp (EApp (EVar "flatMap") (ELam ((PVar "m")) (EMatch (EVar "m") (arm (PTuple PWild (PVar "ty") PWild) () (EApp (EApp (EVar "tyConstraintKeys") (EVar "ty")) (EListLit)))))) (EApp (EVar "ceRowMethods") (EVar "row"))))) (EVar "acc")))) (EVar "omEmpty")) (EFieldAccess (EFieldAccess (EVar "envs") "deIfaces") "ceRows"))) (DoLet false false (PVar "steps") (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "row")) (EMatch (EApp (EVar "ieRowTriple") (EVar "row")) (arm (PTuple (PVar "ir") PWild (PVar "reqs")) () (EApp (EApp (EApp (EVar "addSteps") (EApp (EVar "refKey") (EVar "ir"))) (EApp (EApp (EVar "map") (ELam ((PVar "q")) (EApp (EApp (EVar "ifaceIdentity") (EFieldAccess (EVar "q") "requireOrigin")) (EFieldAccess (EVar "q") "requireHead")))) (EVar "reqs"))) (EVar "acc")))))) (EVar "withSupers")) (EApp (EApp (EVar "ieRowsVisibleAt") (EVar "ord")) (EFieldAccess (EVar "envs") "deImpls")))) (DoExpr (EApp (EApp (EApp (EVar "M.foldlWithKey") (ELam ((PVar "acc") (PVar "k") PWild) (EApp (EApp (EApp (EVar "omInsert") (EVar "k")) (EApp (EApp (EApp (EApp (EVar "closureFrom") (EVar "steps")) (EListLit (EVar "k"))) (EVar "omEmpty")) (EListLit))) (EVar "acc")))) (EVar "omEmpty")) (EVar "steps")))))
(DTypeSig false "addSteps" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "addSteps" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "addSteps" ((PVar "k") (PVar "ks") (PVar "acc")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "k")) (EVar "acc")) (arm (PCon "Some" (PVar "old")) () (EApp (EApp (EApp (EVar "omInsert") (EVar "k")) (EBinOp "++" (EVar "ks") (EVar "old"))) (EVar "acc"))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "omInsert") (EVar "k")) (EVar "ks")) (EVar "acc")))))
(DTypeSig false "closureFrom" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "closureFrom" (PWild (PList) PWild (PVar "out")) (EVar "out"))
(DFunDef false "closureFrom" ((PVar "steps") (PCons (PVar "k") (PVar "rest")) (PVar "seen") (PVar "out")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "k")) (EVar "seen")) (EApp (EApp (EApp (EApp (EVar "closureFrom") (EVar "steps")) (EVar "rest")) (EVar "seen")) (EVar "out")) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "next") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "k")) (EVar "steps")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "closureFrom") (EVar "steps")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "n")) (EBinOp "::" (EVar "n") (EVar "acc")))) (EVar "rest")) (EVar "next"))) (EApp (EApp (EApp (EVar "omInsert") (EVar "k")) (ELit LUnit)) (EVar "seen"))) (EBinOp "::" (EVar "k") (EVar "out"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "tyConstraintKeys" (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "tyConstraintKeys" ((PRec "TyCon" ((rf "tyConName" PWild)) false) (PVar "acc")) (EVar "acc"))
(DFunDef false "tyConstraintKeys" ((PCon "TyVar" PWild) (PVar "acc")) (EVar "acc"))
(DFunDef false "tyConstraintKeys" ((PCon "TyApp" (PVar "a") (PVar "b")) (PVar "acc")) (EApp (EApp (EVar "tyConstraintKeys") (EVar "a")) (EApp (EApp (EVar "tyConstraintKeys") (EVar "b")) (EVar "acc"))))
(DFunDef false "tyConstraintKeys" ((PCon "TyFun" (PVar "a") (PVar "b")) (PVar "acc")) (EApp (EApp (EVar "tyConstraintKeys") (EVar "a")) (EApp (EApp (EVar "tyConstraintKeys") (EVar "b")) (EVar "acc"))))
(DFunDef false "tyConstraintKeys" ((PCon "TyTuple" (PVar "ts")) (PVar "acc")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc2") (PVar "t")) (EApp (EApp (EVar "tyConstraintKeys") (EVar "t")) (EVar "acc2")))) (EVar "acc")) (EVar "ts")))
(DFunDef false "tyConstraintKeys" ((PCon "TyEffect" PWild PWild (PVar "t")) (PVar "acc")) (EApp (EApp (EVar "tyConstraintKeys") (EVar "t")) (EVar "acc")))
(DFunDef false "tyConstraintKeys" ((PCon "TyConstrained" (PVar "cs") (PVar "t")) (PVar "acc")) (EApp (EApp (EVar "tyConstraintKeys") (EVar "t")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc2") (PVar "c")) (EBinOp "::" (EApp (EApp (EVar "ifaceIdentity") (EFieldAccess (EVar "c") "constraintOrigin")) (EFieldAccess (EVar "c") "constraintHead")) (EVar "acc2")))) (EVar "acc")) (EVar "cs"))))
(DFunDef false "tyConstraintKeys" ((PCon "TyNamed" PWild (PVar "t") PWild) (PVar "acc")) (EApp (EApp (EVar "tyConstraintKeys") (EVar "t")) (EVar "acc")))
(DFunDef false "tyConstraintKeys" ((PCon "TyQual" (PVar "t") PWild PWild) (PVar "acc")) (EApp (EApp (EVar "tyConstraintKeys") (EVar "t")) (EVar "acc")))
(DFunDef false "tyConstraintKeys" ((PCon "TyRow" PWild PWild PWild) (PVar "acc")) (EVar "acc"))
(DFunDef false "tyConstraintKeys" ((PCon "TyAuth" PWild PWild) (PVar "acc")) (EVar "acc"))
(DData Private "RawNode" () ((variant "RawNode" (ConNamed (field "rnodeName" (TyCon "String")) (field "rnodeKind" (TyCon "InitNodeKind")) (field "rnodeArity" (TyCon "Int")) (field "rnodeLoc" (TyApp (TyCon "Option") (TyCon "Loc"))) (field "rnodeBodies" (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (field "rnodeKey" (TyCon "String")) (field "rnodeOrphan" (TyCon "Bool"))))) ())
(DData Private "InitWalk" () ((variant "InitWalk" (ConNamed (field "iwInputs" (TyCon "InitInputs")) (field "iwTop" (TyApp (TyCon "OrdMap") (TyCon "Int"))) (field "iwImpls" (TyApp (TyCon "List") (TyCon "String"))) (field "iwImplsByKey" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String")))) (field "iwOrphans" (TyApp (TyCon "List") (TyCon "String"))) (field "iwSeedPrefix" (TyCon "String")) (field "iwLocalMethods" (TyApp (TyCon "OrdMap") (TyCon "Unit")))))) ())
(DTypeSig false "rawNodes" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "RawNode")))))
(DFunDef false "rawNodes" ((PVar "mid") (PVar "decls")) (EApp (EVar "reverseL") (EApp (EApp (EApp (EApp (EVar "rawNodesGo") (EVar "mid")) (ELit (LInt 0))) (EVar "decls")) (EListLit))))
(DTypeSig false "rawNodesGo" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "RawNode")) (TyApp (TyCon "List") (TyCon "RawNode")))))))
(DFunDef false "rawNodesGo" (PWild PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "rawNodesGo" ((PVar "mid") (PVar "k") (PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "rawNodesGo") (EVar "mid")) (EVar "k")) (EBinOp "::" (EVar "d") (EVar "rest"))) (EVar "acc")))
(DFunDef false "rawNodesGo" ((PVar "mid") (PVar "k") (PCons (PCon "DFunDef" PWild (PVar "n") (PVar "ps") (PVar "body") (PVar "site") PWild) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "rawNodesGo") (EVar "mid")) (EVar "k")) (EVar "rest")) (EApp (EApp (EApp (EApp (EApp (EVar "addClause") (EVar "n")) (EVar "ps")) (EVar "body")) (EVar "site")) (EVar "acc"))))
(DFunDef false "rawNodesGo" ((PVar "mid") (PVar "k") (PCons (PCon "DLetGroup" PWild (PVar "binds")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "rawNodesGo") (EVar "mid")) (EVar "k")) (EVar "rest")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc2") (PVar "b")) (EMatch (EVar "b") (arm (PCon "LetBind" (PVar "n") (PVar "clauses") (PVar "site") PWild) () (EBinOp "::" (EApp (EApp (EApp (EVar "bindingNode") (EVar "n")) (EApp (EApp (EVar "map") (ELam ((PVar "c")) (EMatch (EVar "c") (arm (PCon "FunClause" (PVar "ps") (PVar "body")) () (ETuple (EVar "ps") (EVar "body")))))) (EVar "clauses"))) (EApp (EVar "Some") (EVar "site"))) (EVar "acc2")))))) (EVar "acc")) (EVar "binds"))))
(DFunDef false "rawNodesGo" ((PVar "mid") (PVar "k") (PCons (PRec "DImpl" ((rf "iface" None) (rf "tys" None) (rf "methods" None) (rf "implOrigin" None)) false) (PVar "rest")) (PVar "acc")) (EBlock (DoLet false false (PVar "node") (ERecordCreate "RawNode" ((fa "rnodeName" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "impl#")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "k")))) (ELit (LString ":"))) (EApp (EVar "display") (EVar "iface"))) (ELit (LString "")))) (fa "rnodeKind" (EVar "ImplNode")) (fa "rnodeArity" (ELit (LInt 0))) (fa "rnodeLoc" (EVar "None")) (fa "rnodeBodies" (EApp (EApp (EVar "map") (ELam ((PVar "m")) (EMatch (EVar "m") (arm (PCon "ImplMethod" PWild (PVar "ps") (PVar "body")) () (ETuple (EVar "ps") (EVar "body")))))) (EVar "methods"))) (fa "rnodeKey" (EApp (EApp (EVar "ifaceIdentity") (EVar "implOrigin")) (EVar "iface"))) (fa "rnodeOrphan" (EBinOp "&&" (EApp (EVar "not") (EApp (EApp (EVar "declaredIn") (EVar "mid")) (EVar "implOrigin"))) (EApp (EVar "not") (EApp (EApp (EVar "any") (EApp (EVar "headDeclaredIn") (EVar "mid"))) (EVar "tys")))))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "rawNodesGo") (EVar "mid")) (EBinOp "+" (EVar "k") (ELit (LInt 1)))) (EVar "rest")) (EBinOp "::" (EVar "node") (EVar "acc"))))))
(DFunDef false "rawNodesGo" ((PVar "mid") (PVar "k") (PCons (PCon "DTypeSig" PWild PWild PWild PWild) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "rawNodesGo") (EVar "mid")) (EVar "k")) (EVar "rest")) (EVar "acc")))
(DFunDef false "rawNodesGo" ((PVar "mid") (PVar "k") (PCons (PCon "DExtern" PWild) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "rawNodesGo") (EVar "mid")) (EVar "k")) (EVar "rest")) (EVar "acc")))
(DFunDef false "rawNodesGo" ((PVar "mid") (PVar "k") (PCons (PRec "DData" ((rf "dataName" PWild)) false) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "rawNodesGo") (EVar "mid")) (EVar "k")) (EVar "rest")) (EVar "acc")))
(DFunDef false "rawNodesGo" ((PVar "mid") (PVar "k") (PCons (PCon "DUse" PWild PWild PWild) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "rawNodesGo") (EVar "mid")) (EVar "k")) (EVar "rest")) (EVar "acc")))
(DFunDef false "rawNodesGo" ((PVar "mid") (PVar "k") (PCons (PCon "DEffect" PWild PWild PWild PWild PWild PWild) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "rawNodesGo") (EVar "mid")) (EVar "k")) (EVar "rest")) (EVar "acc")))
(DFunDef false "rawNodesGo" ((PVar "mid") (PVar "k") (PCons (PCon "DProp" PWild PWild PWild PWild) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "rawNodesGo") (EVar "mid")) (EVar "k")) (EVar "rest")) (EVar "acc")))
(DFunDef false "rawNodesGo" ((PVar "mid") (PVar "k") (PCons (PCon "DTest" PWild PWild PWild) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "rawNodesGo") (EVar "mid")) (EVar "k")) (EVar "rest")) (EVar "acc")))
(DFunDef false "rawNodesGo" ((PVar "mid") (PVar "k") (PCons (PRec "DInterface" ((rf "ifaceOrigin" PWild)) false) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "rawNodesGo") (EVar "mid")) (EVar "k")) (EVar "rest")) (EVar "acc")))
(DFunDef false "rawNodesGo" ((PVar "mid") (PVar "k") (PCons (PRec "DTypeAlias" ((rf "tyAliasName" PWild)) false) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "rawNodesGo") (EVar "mid")) (EVar "k")) (EVar "rest")) (EVar "acc")))
(DFunDef false "rawNodesGo" ((PVar "mid") (PVar "k") (PCons (PRec "DNewtype" ((rf "newtypeName" PWild)) false) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "rawNodesGo") (EVar "mid")) (EVar "k")) (EVar "rest")) (EVar "acc")))
(DTypeSig false "addClause" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Expr") (TyFun (TyCon "Loc") (TyFun (TyApp (TyCon "List") (TyCon "RawNode")) (TyApp (TyCon "List") (TyCon "RawNode"))))))))
(DFunDef false "addClause" ((PVar "n") (PVar "ps") (PVar "body") PWild (PCons (PVar "prev") (PVar "older"))) (EIf (EBinOp "&&" (EBinOp "==" (EFieldAccess (EVar "prev") "rnodeName") (EVar "n")) (EBinOp "/=" (EFieldAccess (EVar "prev") "rnodeKind") (EVar "ImplNode"))) (EBinOp "::" (ERecordUpdate (EVar "prev") ((fa "rnodeBodies" (EBinOp "++" (EFieldAccess (EVar "prev") "rnodeBodies") (EListLit (ETuple (EVar "ps") (EVar "body"))))))) (EVar "older")) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "addClause" ((PVar "n") (PVar "ps") (PVar "body") (PVar "site") (PVar "acc")) (EBinOp "::" (EApp (EApp (EApp (EVar "bindingNode") (EVar "n")) (EListLit (ETuple (EVar "ps") (EVar "body")))) (EApp (EVar "Some") (EVar "site"))) (EVar "acc")))
(DTypeSig false "bindingNode" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "RawNode")))))
(DFunDef false "bindingNode" ((PVar "n") (PVar "bodies") (PVar "loc")) (ERecordCreate "RawNode" ((fa "rnodeName" (EVar "n")) (fa "rnodeKind" (EVar "FunctionNode")) (fa "rnodeArity" (EMatch (EVar "bodies") (arm (PCons (PTuple (PVar "ps") PWild) PWild) () (EApp (EVar "length") (EVar "ps"))) (arm (PList) () (ELit (LInt 0))))) (fa "rnodeLoc" (EVar "loc")) (fa "rnodeBodies" (EVar "bodies")) (fa "rnodeKey" (ELit (LString ""))) (fa "rnodeOrphan" (EVar "False")))))
(DTypeSig false "declaredIn" (TyFun (TyCon "String") (TyFun (TyCon "TyConOrigin") (TyCon "Bool"))))
(DFunDef false "declaredIn" ((PVar "mid") (PCon "OriginModule" (PVar "m"))) (EBinOp "==" (EVar "m") (EVar "mid")))
(DFunDef false "declaredIn" (PWild PWild) (EVar "False"))
(DTypeSig false "headDeclaredIn" (TyFun (TyCon "String") (TyFun (TyCon "Ty") (TyCon "Bool"))))
(DFunDef false "headDeclaredIn" ((PVar "mid") (PRec "TyCon" ((rf "tyConOrigin" None)) false)) (EApp (EApp (EVar "declaredIn") (EVar "mid")) (EVar "tyConOrigin")))
(DFunDef false "headDeclaredIn" ((PVar "mid") (PCon "TyApp" (PVar "f") PWild)) (EApp (EApp (EVar "headDeclaredIn") (EVar "mid")) (EVar "f")))
(DFunDef false "headDeclaredIn" (PWild (PCon "TyVar" PWild)) (EVar "False"))
(DFunDef false "headDeclaredIn" (PWild (PCon "TyFun" PWild PWild)) (EVar "False"))
(DFunDef false "headDeclaredIn" (PWild (PCon "TyTuple" PWild)) (EVar "False"))
(DFunDef false "headDeclaredIn" ((PVar "mid") (PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EApp (EVar "headDeclaredIn") (EVar "mid")) (EVar "t")))
(DFunDef false "headDeclaredIn" ((PVar "mid") (PCon "TyConstrained" PWild (PVar "t"))) (EApp (EApp (EVar "headDeclaredIn") (EVar "mid")) (EVar "t")))
(DFunDef false "headDeclaredIn" ((PVar "mid") (PCon "TyNamed" PWild (PVar "t") PWild)) (EApp (EApp (EVar "headDeclaredIn") (EVar "mid")) (EVar "t")))
(DFunDef false "headDeclaredIn" ((PVar "mid") (PCon "TyQual" (PVar "t") PWild PWild)) (EApp (EApp (EVar "headDeclaredIn") (EVar "mid")) (EVar "t")))
(DFunDef false "headDeclaredIn" (PWild (PCon "TyRow" PWild PWild PWild)) (EVar "False"))
(DFunDef false "headDeclaredIn" (PWild (PCon "TyAuth" PWild PWild)) (EVar "False"))
(DTypeSig false "localDefaults" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))))))
(DFunDef false "localDefaults" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "localDefaults" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "localDefaults") (EBinOp "::" (EVar "d") (EVar "rest"))) (EVar "acc")))
(DFunDef false "localDefaults" ((PCons (PRec "DInterface" ((rf "name" None) (rf "methods" None) (rf "ifaceOrigin" None)) false) (PVar "rest")) (PVar "acc")) (EBlock (DoLet false false (PVar "bodies") (EApp (EApp (EVar "flatMap") (ELam ((PVar "m")) (EMatch (EVar "m") (arm (PCon "IfaceMethod" PWild PWild (PCon "Some" (PCon "MethodDefault" (PVar "ps") (PVar "body"))) PWild) () (EListLit (ETuple (EVar "ps") (EVar "body")))) (arm (PCon "IfaceMethod" PWild PWild (PCon "None") PWild) () (EListLit))))) (EVar "methods"))) (DoExpr (EApp (EApp (EVar "localDefaults") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EApp (EApp (EVar "ifaceIdentity") (EVar "ifaceOrigin")) (EVar "name"))) (EVar "bodies")) (EVar "acc"))))))
(DFunDef false "localDefaults" ((PCons PWild (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "localDefaults") (EVar "rest")) (EVar "acc")))
(DTypeSig false "localMethodNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit")))))
(DFunDef false "localMethodNames" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "localMethodNames" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "localMethodNames") (EBinOp "::" (EVar "d") (EVar "rest"))) (EVar "acc")))
(DFunDef false "localMethodNames" ((PCons (PRec "DInterface" ((rf "methods" None) (rf "ifaceOrigin" PWild)) false) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "localMethodNames") (EVar "rest")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "a") (PVar "m")) (EMatch (EVar "m") (arm (PCon "IfaceMethod" (PVar "n") PWild PWild PWild) () (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (ELit LUnit)) (EVar "a")))))) (EVar "acc")) (EVar "methods"))))
(DFunDef false "localMethodNames" ((PCons PWild (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "localMethodNames") (EVar "rest")) (EVar "acc")))
(DTypeSig true "initGraphOf" (TyFun (TyCon "InitInputs") (TyCon "InitGraph")))
(DFunDef false "initGraphOf" ((PVar "inputs")) (EBlock (DoLet false false (PVar "raw") (EApp (EApp (EVar "map") (EApp (EVar "classify") (EVar "inputs"))) (EApp (EApp (EVar "rawNodes") (EFieldAccess (EVar "inputs") "iiModule")) (EFieldAccess (EVar "inputs") "iiDecls")))) (DoLet false false (PVar "impls") (EApp (EApp (EVar "filter") (ELam ((PVar "n")) (EBinOp "==" (EFieldAccess (EVar "n") "rnodeKind") (EVar "ImplNode")))) (EVar "raw"))) (DoLet false false (PVar "w") (ERecordCreate "InitWalk" ((fa "iwInputs" (EVar "inputs")) (fa "iwTop" (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "n")) (EIf (EBinOp "==" (EFieldAccess (EVar "n") "rnodeKind") (EVar "ImplNode")) (EVar "acc") (EApp (EApp (EApp (EVar "omInsert") (EFieldAccess (EVar "n") "rnodeName")) (EFieldAccess (EVar "n") "rnodeArity")) (EVar "acc"))))) (EVar "omEmpty")) (EVar "raw"))) (fa "iwImpls" (EApp (EApp (EVar "map") (ELam ((PVar "n")) (EFieldAccess (EVar "n") "rnodeName"))) (EVar "impls"))) (fa "iwImplsByKey" (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "n")) (EApp (EApp (EApp (EVar "addSteps") (EFieldAccess (EVar "n") "rnodeKey")) (EListLit (EFieldAccess (EVar "n") "rnodeName"))) (EVar "acc")))) (EVar "omEmpty")) (EApp (EVar "reverseL") (EVar "impls")))) (fa "iwOrphans" (EApp (EApp (EVar "map") (ELam ((PVar "n")) (EFieldAccess (EVar "n") "rnodeName"))) (EApp (EApp (EVar "filter") (ELam ((PVar "n")) (EFieldAccess (EVar "n") "rnodeOrphan"))) (EVar "impls")))) (fa "iwSeedPrefix" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EFieldAccess (EVar "inputs") "iiModule"))) (ELit (LString "__")))) (fa "iwLocalMethods" (EApp (EApp (EVar "localMethodNames") (EFieldAccess (EVar "inputs") "iiDecls")) (EVar "omEmpty")))))) (DoLet false false (PVar "defaults") (EApp (EApp (EVar "localDefaults") (EFieldAccess (EVar "inputs") "iiDecls")) (EVar "omEmpty"))) (DoExpr (ERecordCreate "InitGraph" ((fa "igraphNodes" (EApp (EApp (EApp (EApp (EApp (EVar "walkNodes") (EVar "w")) (EVar "defaults")) (ELit (LInt 0))) (EVar "raw")) (EListLit))) (fa "igraphNotInitialised" (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "n")) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EFieldAccess (EVar "n") "rnodeArity") (ELit (LInt 0))) (EBinOp "/=" (EFieldAccess (EVar "n") "rnodeKind") (EVar "ImplNode"))) (EBinOp "||" (EApp (EApp (EVar "omHasKey") (EFieldAccess (EVar "n") "rnodeName")) (EFieldAccess (EVar "inputs") "iiExempt")) (EApp (EApp (EVar "omHasKey") (EFieldAccess (EVar "n") "rnodeName")) (EFieldAccess (EVar "inputs") "iiConstrained")))) (EApp (EApp (EApp (EVar "omInsert") (EFieldAccess (EVar "n") "rnodeName")) (ELit LUnit)) (EVar "acc")) (EVar "acc")))) (EVar "omEmpty")) (EVar "raw"))))))))
(DTypeSig false "classify" (TyFun (TyCon "InitInputs") (TyFun (TyCon "RawNode") (TyCon "RawNode"))))
(DFunDef false "classify" ((PVar "inputs") (PVar "n")) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EFieldAccess (EVar "n") "rnodeKind") (EVar "FunctionNode")) (EBinOp "==" (EFieldAccess (EVar "n") "rnodeArity") (ELit (LInt 0)))) (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EFieldAccess (EVar "n") "rnodeName")) (EFieldAccess (EVar "inputs") "iiConstrained")))) (ERecordUpdate (EVar "n") ((fa "rnodeKind" (EVar "ValueNode")))) (EVar "n")))
(DTypeSig false "walkNodes" (TyFun (TyCon "InitWalk") (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "RawNode")) (TyFun (TyApp (TyCon "List") (TyCon "InitNode")) (TyApp (TyCon "List") (TyCon "InitNode"))))))))
(DFunDef false "walkNodes" (PWild PWild PWild (PList) (PVar "acc")) (EApp (EVar "reverseL") (EVar "acc")))
(DFunDef false "walkNodes" ((PVar "w") (PVar "defaults") (PVar "k") (PCons (PVar "n") (PVar "rest")) (PVar "acc")) (EBlock (DoLet false false (PVar "own") (EApp (EApp (EApp (EVar "walkBodies") (EVar "w")) (EFieldAccess (EVar "n") "rnodeBodies")) (EListLit))) (DoLet false false (PVar "mentions") (EIf (EBinOp "==" (EFieldAccess (EVar "n") "rnodeKind") (EVar "ImplNode")) (EApp (EApp (EApp (EVar "walkBodies") (EVar "w")) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EFieldAccess (EVar "n") "rnodeKey")) (EVar "defaults")))) (EVar "own")) (EVar "own"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "walkNodes") (EVar "w")) (EVar "defaults")) (EBinOp "+" (EVar "k") (ELit (LInt 1)))) (EVar "rest")) (EBinOp "::" (ERecordCreate "InitNode" ((fa "inodeName" (EFieldAccess (EVar "n") "rnodeName")) (fa "inodeKind" (EFieldAccess (EVar "n") "rnodeKind")) (fa "inodeOrder" (EVar "k")) (fa "inodeLoc" (EFieldAccess (EVar "n") "rnodeLoc")) (fa "inodeMentions" (EApp (EVar "reverseL") (EVar "mentions"))))) (EVar "acc"))))))
(DTypeSig false "walkBodies" (TyFun (TyCon "InitWalk") (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))) (TyFun (TyApp (TyCon "List") (TyCon "InitMention")) (TyApp (TyCon "List") (TyCon "InitMention"))))))
(DFunDef false "walkBodies" ((PVar "w") (PVar "bodies") (PVar "acc")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc2") (PVar "b")) (EMatch (EVar "b") (arm (PTuple (PVar "ps") (PVar "body")) () (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EVar "CtxReturn")) (EApp (EApp (EVar "bindPats") (EVar "ps")) (EVar "omEmpty"))) (EVar "body")) (EVar "acc2")))))) (EVar "acc")) (EVar "bodies")))
(DData Private "WalkCtx" () ((variant "CtxReturn" (ConPos)) (variant "CtxGuard" (ConPos)) (variant "CtxGuardBody" (ConPos)) (variant "CtxDeref" (ConPos)) (variant "CtxDelay" (ConPos))) ())
(DTypeSig false "namePos" (TyFun (TyCon "WalkCtx") (TyCon "InitPosition")))
(DFunDef false "namePos" ((PCon "CtxReturn")) (EVar "AtDeref"))
(DFunDef false "namePos" ((PCon "CtxGuard")) (EVar "AtGuard"))
(DFunDef false "namePos" ((PCon "CtxGuardBody")) (EVar "AtGuard"))
(DFunDef false "namePos" ((PCon "CtxDeref")) (EVar "AtDeref"))
(DFunDef false "namePos" ((PCon "CtxDelay")) (EVar "AtDelay"))
(DTypeSig false "evalCtx" (TyFun (TyCon "WalkCtx") (TyCon "WalkCtx")))
(DFunDef false "evalCtx" ((PCon "CtxReturn")) (EVar "CtxDeref"))
(DFunDef false "evalCtx" ((PCon "CtxGuard")) (EVar "CtxDeref"))
(DFunDef false "evalCtx" ((PCon "CtxGuardBody")) (EVar "CtxGuardBody"))
(DFunDef false "evalCtx" ((PCon "CtxDeref")) (EVar "CtxDeref"))
(DFunDef false "evalCtx" ((PCon "CtxDelay")) (EVar "CtxDelay"))
(DTypeSig false "componentCtx" (TyFun (TyCon "WalkCtx") (TyCon "WalkCtx")))
(DFunDef false "componentCtx" ((PCon "CtxReturn")) (EVar "CtxGuard"))
(DFunDef false "componentCtx" ((PCon "CtxGuard")) (EVar "CtxGuard"))
(DFunDef false "componentCtx" ((PCon "CtxGuardBody")) (EVar "CtxGuardBody"))
(DFunDef false "componentCtx" ((PCon "CtxDeref")) (EVar "CtxDeref"))
(DFunDef false "componentCtx" ((PCon "CtxDelay")) (EVar "CtxDelay"))
(DTypeSig false "lambdaCtx" (TyFun (TyCon "WalkCtx") (TyCon "WalkCtx")))
(DFunDef false "lambdaCtx" ((PCon "CtxReturn")) (EVar "CtxGuardBody"))
(DFunDef false "lambdaCtx" ((PCon "CtxGuard")) (EVar "CtxGuardBody"))
(DFunDef false "lambdaCtx" ((PCon "CtxGuardBody")) (EVar "CtxGuardBody"))
(DFunDef false "lambdaCtx" ((PCon "CtxDeref")) (EVar "CtxDeref"))
(DFunDef false "lambdaCtx" ((PCon "CtxDelay")) (EVar "CtxDelay"))
(DTypeSig false "isGuarded" (TyFun (TyCon "WalkCtx") (TyCon "Bool")))
(DFunDef false "isGuarded" ((PCon "CtxReturn")) (EVar "True"))
(DFunDef false "isGuarded" ((PCon "CtxGuard")) (EVar "True"))
(DFunDef false "isGuarded" ((PCon "CtxGuardBody")) (EVar "False"))
(DFunDef false "isGuarded" ((PCon "CtxDeref")) (EVar "False"))
(DFunDef false "isGuarded" ((PCon "CtxDelay")) (EVar "False"))
(DTypeSig false "walk" (TyFun (TyCon "InitWalk") (TyFun (TyCon "WalkCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "InitMention")) (TyApp (TyCon "List") (TyCon "InitMention"))))))))
(DFunDef false "walk" (PWild PWild PWild (PCon "ELit" PWild) (PVar "acc")) (EVar "acc"))
(DFunDef false "walk" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "EVar" (PVar "n")) (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EVar "nameRef") (EVar "w")) (EVar "ctx")) (EVar "bound")) (EVar "n")) (EVar "acc")))
(DFunDef false "walk" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "EApp" (PVar "f") (PVar "x")) (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EVar "walkApp") (EVar "w")) (EVar "ctx")) (EVar "bound")) (EApp (EApp (EVar "EApp") (EVar "f")) (EVar "x"))) (EVar "acc")))
(DFunDef false "walk" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "ELam" (PVar "ps") (PVar "body")) (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EApp (EVar "lambdaCtx") (EVar "ctx"))) (EApp (EApp (EVar "bindPats") (EVar "ps")) (EVar "bound"))) (EVar "body")) (EVar "acc")))
(DFunDef false "walk" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "ELet" PWild (PVar "r") (PVar "p") (PVar "e1") (PVar "e2")) (PVar "acc")) (EBlock (DoLet false false (PVar "after") (EApp (EApp (EVar "bindPat") (EVar "p")) (EVar "bound"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EVar "ctx")) (EVar "after")) (EVar "e2")) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EApp (EVar "evalCtx") (EVar "ctx"))) (EIf (EVar "r") (EVar "after") (EVar "bound"))) (EVar "e1")) (EVar "acc"))))))
(DFunDef false "walk" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "EMatch" (PVar "e0") (PVar "arms")) (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EVar "walkArms") (EVar "w")) (EVar "ctx")) (EVar "bound")) (EVar "arms")) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EApp (EVar "evalCtx") (EVar "ctx"))) (EVar "bound")) (EVar "e0")) (EVar "acc"))))
(DFunDef false "walk" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "EIf" (PVar "c") (PVar "t") (PVar "e")) (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EVar "ctx")) (EVar "bound")) (EVar "e")) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EVar "ctx")) (EVar "bound")) (EVar "t")) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EApp (EVar "evalCtx") (EVar "ctx"))) (EVar "bound")) (EVar "c")) (EVar "acc")))))
(DFunDef false "walk" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "EBinOp" (PVar "op") (PVar "l") (PVar "r") PWild) (PVar "acc")) (EIf (EBinOp "==" (EVar "op") (ELit (LString "::"))) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EApp (EVar "componentCtx") (EVar "ctx"))) (EVar "bound")) (EVar "r")) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EApp (EVar "componentCtx") (EVar "ctx"))) (EVar "bound")) (EVar "l")) (EVar "acc"))) (EApp (EApp (EApp (EApp (EVar "operatorRef") (EVar "w")) (EVar "ctx")) (EApp (EFieldAccess (EFieldAccess (EVar "w") "iwInputs") "iiBinopMethod") (EVar "op"))) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EApp (EVar "evalCtx") (EVar "ctx"))) (EVar "bound")) (EVar "r")) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EApp (EVar "evalCtx") (EVar "ctx"))) (EVar "bound")) (EVar "l")) (EVar "acc"))))))
(DFunDef false "walk" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "EUnOp" (PVar "op") (PVar "x") PWild) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "operatorRef") (EVar "w")) (EVar "ctx")) (EApp (EFieldAccess (EFieldAccess (EVar "w") "iwInputs") "iiUnopMethod") (EVar "op"))) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EApp (EVar "evalCtx") (EVar "ctx"))) (EVar "bound")) (EVar "x")) (EVar "acc"))))
(DFunDef false "walk" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "EInfix" (PVar "op") (PVar "l") (PVar "r")) (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EVar "nameRef") (EVar "w")) (EApp (EVar "evalCtx") (EVar "ctx"))) (EVar "bound")) (EVar "op")) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EApp (EVar "evalCtx") (EVar "ctx"))) (EVar "bound")) (EVar "r")) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EApp (EVar "evalCtx") (EVar "ctx"))) (EVar "bound")) (EVar "l")) (EVar "acc")))))
(DFunDef false "walk" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "EFieldAccess" (PVar "e0") PWild PWild) (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EApp (EVar "evalCtx") (EVar "ctx"))) (EVar "bound")) (EVar "e0")) (EVar "acc")))
(DFunDef false "walk" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "ETuple" (PVar "es")) (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EVar "walkAll") (EVar "w")) (EApp (EVar "componentCtx") (EVar "ctx"))) (EVar "bound")) (EVar "es")) (EVar "acc")))
(DFunDef false "walk" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "EListLit" (PVar "es")) (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EVar "walkAll") (EVar "w")) (EApp (EVar "componentCtx") (EVar "ctx"))) (EVar "bound")) (EVar "es")) (EVar "acc")))
(DFunDef false "walk" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "EArrayLit" (PVar "es")) (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EVar "walkAll") (EVar "w")) (EApp (EVar "componentCtx") (EVar "ctx"))) (EVar "bound")) (EVar "es")) (EVar "acc")))
(DFunDef false "walk" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "ERangeList" (PVar "a") (PVar "b") PWild) (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EApp (EVar "evalCtx") (EVar "ctx"))) (EVar "bound")) (EVar "b")) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EApp (EVar "evalCtx") (EVar "ctx"))) (EVar "bound")) (EVar "a")) (EVar "acc"))))
(DFunDef false "walk" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "ERangeArray" (PVar "a") (PVar "b") PWild) (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EApp (EVar "evalCtx") (EVar "ctx"))) (EVar "bound")) (EVar "b")) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EApp (EVar "evalCtx") (EVar "ctx"))) (EVar "bound")) (EVar "a")) (EVar "acc"))))
(DFunDef false "walk" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "ESlice" (PVar "a") (PVar "lo") (PVar "hi") PWild) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "sugarMethodRef") (EVar "w")) (EVar "ctx")) (ELit (LString "slice"))) (EApp (EApp (EApp (EApp (EApp (EVar "walkAll") (EVar "w")) (EApp (EVar "evalCtx") (EVar "ctx"))) (EVar "bound")) (EListLit (EVar "a") (EVar "lo") (EVar "hi"))) (EVar "acc"))))
(DFunDef false "walk" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "ELetGroup" (PVar "binds") (PVar "body")) (PVar "acc")) (EBlock (DoLet false false (PVar "inner") (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "b2") (PVar "lb")) (EMatch (EVar "lb") (arm (PCon "LetBind" (PVar "n") PWild PWild PWild) () (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (ELit LUnit)) (EVar "b2")))))) (EVar "bound")) (EVar "binds"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EVar "ctx")) (EVar "inner")) (EVar "body")) (EApp (EApp (EApp (EApp (EApp (EVar "walkLetBinds") (EVar "w")) (EApp (EVar "evalCtx") (EVar "ctx"))) (EVar "inner")) (EVar "binds")) (EVar "acc"))))))
(DFunDef false "walk" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "ESection" (PVar "s")) (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EVar "walkSection") (EVar "w")) (EVar "ctx")) (EVar "bound")) (EVar "s")) (EVar "acc")))
(DFunDef false "walk" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "EIndex" (PVar "a") (PVar "i")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "sugarMethodRef") (EVar "w")) (EVar "ctx")) (ELit (LString "index"))) (EApp (EApp (EApp (EApp (EApp (EVar "walkAll") (EVar "w")) (EApp (EVar "evalCtx") (EVar "ctx"))) (EVar "bound")) (EListLit (EVar "a") (EVar "i"))) (EVar "acc"))))
(DFunDef false "walk" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "EAnnot" (PVar "e0") PWild) (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EVar "ctx")) (EVar "bound")) (EVar "e0")) (EVar "acc")))
(DFunDef false "walk" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "EHeadAnnot" (PVar "e0") PWild) (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EVar "ctx")) (EVar "bound")) (EVar "e0")) (EVar "acc")))
(DFunDef false "walk" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "EBlock" (PVar "stmts")) (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EVar "walkStmts") (EVar "w")) (EVar "ctx")) (EVar "bound")) (EVar "stmts")) (EVar "acc")))
(DFunDef false "walk" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "EDo" (PVar "deferred") (PVar "stmts")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "sugarMethodRef") (EVar "w")) (EVar "ctx")) (EIf (EVar "deferred") (ELit (LString "deferThen")) (ELit (LString "andThen")))) (EApp (EApp (EApp (EApp (EApp (EVar "walkStmts") (EVar "w")) (EApp (EVar "evalCtx") (EVar "ctx"))) (EVar "bound")) (EVar "stmts")) (EVar "acc"))))
(DFunDef false "walk" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "EStringInterp" (PVar "parts")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "sugarMethodRef") (EVar "w")) (EVar "ctx")) (ELit (LString "display"))) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc2") (PVar "p")) (EMatch (EVar "p") (arm (PCon "InterpStr" PWild) () (EVar "acc2")) (arm (PCon "InterpExpr" (PVar "e0")) () (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EApp (EVar "evalCtx") (EVar "ctx"))) (EVar "bound")) (EVar "e0")) (EVar "acc2")))))) (EVar "acc")) (EVar "parts"))))
(DFunDef false "walk" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "EGuards" (PVar "arms")) (PVar "acc")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc2") (PVar "a")) (EMatch (EVar "a") (arm (PCon "GuardArm" (PVar "gs") (PVar "body")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "walkGuarded") (EVar "w")) (EVar "ctx")) (EVar "bound")) (EVar "gs")) (EVar "body")) (EVar "acc2")))))) (EVar "acc")) (EVar "arms")))
(DFunDef false "walk" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "ERecordCreate" PWild (PVar "fs")) (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EVar "walkFields") (EVar "w")) (EApp (EVar "componentCtx") (EVar "ctx"))) (EVar "bound")) (EVar "fs")) (EVar "acc")))
(DFunDef false "walk" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "ERecordUpdate" (PVar "e0") (PVar "fs") PWild) (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EVar "walkFields") (EVar "w")) (EApp (EVar "componentCtx") (EVar "ctx"))) (EVar "bound")) (EVar "fs")) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EApp (EVar "evalCtx") (EVar "ctx"))) (EVar "bound")) (EVar "e0")) (EVar "acc"))))
(DFunDef false "walk" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "EVariantUpdate" PWild (PVar "e0") (PVar "fs")) (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EVar "walkFields") (EVar "w")) (EApp (EVar "componentCtx") (EVar "ctx"))) (EVar "bound")) (EVar "fs")) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EApp (EVar "evalCtx") (EVar "ctx"))) (EVar "bound")) (EVar "e0")) (EVar "acc"))))
(DFunDef false "walk" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "EMapLit" PWild (PVar "kvs")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "sugarMethodRef") (EVar "w")) (EVar "ctx")) (ELit (LString "fromEntries"))) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc2") (PVar "kv")) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EApp (EVar "evalCtx") (EVar "ctx"))) (EVar "bound")) (EApp (EVar "snd") (EVar "kv"))) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EApp (EVar "evalCtx") (EVar "ctx"))) (EVar "bound")) (EApp (EVar "fst") (EVar "kv"))) (EVar "acc2"))))) (EVar "acc")) (EVar "kvs"))))
(DFunDef false "walk" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "ESetLit" PWild (PVar "es")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "sugarMethodRef") (EVar "w")) (EVar "ctx")) (ELit (LString "fromEntries"))) (EApp (EApp (EApp (EApp (EApp (EVar "walkAll") (EVar "w")) (EApp (EVar "evalCtx") (EVar "ctx"))) (EVar "bound")) (EVar "es")) (EVar "acc"))))
(DFunDef false "walk" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "EAsPat" PWild (PVar "e0")) (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EApp (EVar "evalCtx") (EVar "ctx"))) (EVar "bound")) (EVar "e0")) (EVar "acc")))
(DFunDef false "walk" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "EOrPat" (PVar "es")) (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EVar "walkAll") (EVar "w")) (EApp (EVar "evalCtx") (EVar "ctx"))) (EVar "bound")) (EVar "es")) (EVar "acc")))
(DFunDef false "walk" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "EMethodRef" (PVar "n")) (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "methodRef") (EVar "w")) (EVar "ctx")) (EVar "bound")) (EVar "n")) (ELit (LString ""))) (EVar "acc")))
(DFunDef false "walk" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "EDictApp" (PVar "n")) (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EVar "dictRef") (EVar "w")) (EVar "ctx")) (EVar "bound")) (EVar "n")) (EVar "acc")))
(DFunDef false "walk" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "EVarAt" (PVar "n") PWild) (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EVar "nameRef") (EVar "w")) (EVar "ctx")) (EVar "bound")) (EVar "n")) (EVar "acc")))
(DFunDef false "walk" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "EVarId" (PVar "n") PWild) (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EVar "nameRef") (EVar "w")) (EVar "ctx")) (EVar "bound")) (EVar "n")) (EVar "acc")))
(DFunDef false "walk" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "EMethodAt" (PVar "m") (PVar "seed") PWild) (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "methodRef") (EVar "w")) (EVar "ctx")) (EVar "bound")) (EVar "m")) (EVar "seed")) (EVar "acc")))
(DFunDef false "walk" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "EDictAt" (PVar "n") PWild) (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EVar "dictRef") (EVar "w")) (EVar "ctx")) (EVar "bound")) (EVar "n")) (EVar "acc")))
(DFunDef false "walk" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "ELoc" PWild (PVar "e0")) (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EVar "ctx")) (EVar "bound")) (EVar "e0")) (EVar "acc")))
(DFunDef false "walk" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "EDoOrigin" PWild (PVar "e0")) (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EVar "ctx")) (EVar "bound")) (EVar "e0")) (EVar "acc")))
(DFunDef false "walk" ((PVar "w") (PVar "ctx") PWild (PCon "ENumLit" PWild PWild PWild) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "operatorRef") (EVar "w")) (EVar "ctx")) (EApp (EVar "Some") (ELit (LString "fromInt")))) (EVar "acc")))
(DFunDef false "walk" ((PVar "w") (PVar "ctx") PWild (PCon "EWideLit" PWild PWild PWild PWild) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "operatorRef") (EVar "w")) (EVar "ctx")) (EApp (EVar "Some") (ELit (LString "fromInt")))) (EVar "acc")))
(DTypeSig false "walkAll" (TyFun (TyCon "InitWalk") (TyFun (TyCon "WalkCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyFun (TyApp (TyCon "List") (TyCon "InitMention")) (TyApp (TyCon "List") (TyCon "InitMention"))))))))
(DFunDef false "walkAll" ((PVar "w") (PVar "ctx") (PVar "bound") (PVar "es") (PVar "acc")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc2") (PVar "e")) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EVar "ctx")) (EVar "bound")) (EVar "e")) (EVar "acc2")))) (EVar "acc")) (EVar "es")))
(DTypeSig false "walkFields" (TyFun (TyCon "InitWalk") (TyFun (TyCon "WalkCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "FieldAssign")) (TyFun (TyApp (TyCon "List") (TyCon "InitMention")) (TyApp (TyCon "List") (TyCon "InitMention"))))))))
(DFunDef false "walkFields" ((PVar "w") (PVar "ctx") (PVar "bound") (PVar "fs") (PVar "acc")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc2") (PVar "f")) (EMatch (EVar "f") (arm (PCon "FieldAssign" PWild (PVar "e")) () (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EVar "ctx")) (EVar "bound")) (EVar "e")) (EVar "acc2")))))) (EVar "acc")) (EVar "fs")))
(DTypeSig false "walkLetBinds" (TyFun (TyCon "InitWalk") (TyFun (TyCon "WalkCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyFun (TyApp (TyCon "List") (TyCon "InitMention")) (TyApp (TyCon "List") (TyCon "InitMention"))))))))
(DFunDef false "walkLetBinds" ((PVar "w") (PVar "ctx") (PVar "bound") (PVar "binds") (PVar "acc")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc2") (PVar "b")) (EMatch (EVar "b") (arm (PCon "LetBind" PWild (PVar "clauses") PWild PWild) () (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc3") (PVar "c")) (EMatch (EVar "c") (arm (PCon "FunClause" (PVar "ps") (PVar "body")) () (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EVar "ctx")) (EApp (EApp (EVar "bindPats") (EVar "ps")) (EVar "bound"))) (EVar "body")) (EVar "acc3")))))) (EVar "acc2")) (EVar "clauses")))))) (EVar "acc")) (EVar "binds")))
(DTypeSig false "walkArms" (TyFun (TyCon "InitWalk") (TyFun (TyCon "WalkCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "Arm")) (TyFun (TyApp (TyCon "List") (TyCon "InitMention")) (TyApp (TyCon "List") (TyCon "InitMention"))))))))
(DFunDef false "walkArms" ((PVar "w") (PVar "ctx") (PVar "bound") (PVar "arms") (PVar "acc")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc2") (PVar "a")) (EMatch (EVar "a") (arm (PCon "Arm" (PVar "p") (PVar "gs") (PVar "body")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "walkGuarded") (EVar "w")) (EVar "ctx")) (EApp (EApp (EVar "bindPat") (EVar "p")) (EVar "bound"))) (EVar "gs")) (EVar "body")) (EVar "acc2")))))) (EVar "acc")) (EVar "arms")))
(DTypeSig false "walkGuarded" (TyFun (TyCon "InitWalk") (TyFun (TyCon "WalkCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "Guard")) (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "InitMention")) (TyApp (TyCon "List") (TyCon "InitMention")))))))))
(DFunDef false "walkGuarded" ((PVar "w") (PVar "ctx") (PVar "bound") (PList) (PVar "body") (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EVar "ctx")) (EVar "bound")) (EVar "body")) (EVar "acc")))
(DFunDef false "walkGuarded" ((PVar "w") (PVar "ctx") (PVar "bound") (PCons (PCon "GBool" (PVar "e")) (PVar "gs")) (PVar "body") (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "walkGuarded") (EVar "w")) (EVar "ctx")) (EVar "bound")) (EVar "gs")) (EVar "body")) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EApp (EVar "evalCtx") (EVar "ctx"))) (EVar "bound")) (EVar "e")) (EVar "acc"))))
(DFunDef false "walkGuarded" ((PVar "w") (PVar "ctx") (PVar "bound") (PCons (PCon "GBind" (PVar "p") (PVar "e")) (PVar "gs")) (PVar "body") (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "walkGuarded") (EVar "w")) (EVar "ctx")) (EApp (EApp (EVar "bindPat") (EVar "p")) (EVar "bound"))) (EVar "gs")) (EVar "body")) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EApp (EVar "evalCtx") (EVar "ctx"))) (EVar "bound")) (EVar "e")) (EVar "acc"))))
(DTypeSig false "walkStmts" (TyFun (TyCon "InitWalk") (TyFun (TyCon "WalkCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyFun (TyApp (TyCon "List") (TyCon "InitMention")) (TyApp (TyCon "List") (TyCon "InitMention"))))))))
(DFunDef false "walkStmts" (PWild PWild PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "walkStmts" ((PVar "w") (PVar "ctx") (PVar "bound") (PList (PCon "DoExpr" (PVar "e"))) (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EVar "ctx")) (EVar "bound")) (EVar "e")) (EVar "acc")))
(DFunDef false "walkStmts" ((PVar "w") (PVar "ctx") (PVar "bound") (PCons (PCon "DoExpr" (PVar "e")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EVar "walkStmts") (EVar "w")) (EVar "ctx")) (EVar "bound")) (EVar "rest")) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EApp (EVar "evalCtx") (EVar "ctx"))) (EVar "bound")) (EVar "e")) (EVar "acc"))))
(DFunDef false "walkStmts" ((PVar "w") (PVar "ctx") (PVar "bound") (PCons (PCon "DoBind" (PVar "p") (PVar "e")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EVar "walkStmts") (EVar "w")) (EVar "ctx")) (EApp (EApp (EVar "bindPat") (EVar "p")) (EVar "bound"))) (EVar "rest")) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EApp (EVar "evalCtx") (EVar "ctx"))) (EVar "bound")) (EVar "e")) (EVar "acc"))))
(DFunDef false "walkStmts" ((PVar "w") (PVar "ctx") (PVar "bound") (PCons (PCon "DoLet" PWild (PVar "r") (PVar "p") (PVar "e") PWild) (PVar "rest")) (PVar "acc")) (EBlock (DoLet false false (PVar "after") (EApp (EApp (EVar "bindPat") (EVar "p")) (EVar "bound"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "walkStmts") (EVar "w")) (EVar "ctx")) (EVar "after")) (EVar "rest")) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EApp (EVar "evalCtx") (EVar "ctx"))) (EIf (EVar "r") (EVar "after") (EVar "bound"))) (EVar "e")) (EVar "acc"))))))
(DFunDef false "walkStmts" ((PVar "w") (PVar "ctx") (PVar "bound") (PCons (PCon "DoAssign" (PVar "x") (PVar "e")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EVar "walkStmts") (EVar "w")) (EVar "ctx")) (EApp (EApp (EApp (EVar "omInsert") (EVar "x")) (ELit LUnit)) (EVar "bound"))) (EVar "rest")) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EApp (EVar "evalCtx") (EVar "ctx"))) (EVar "bound")) (EVar "e")) (EVar "acc"))))
(DFunDef false "walkStmts" ((PVar "w") (PVar "ctx") (PVar "bound") (PCons (PCon "DoFieldAssign" PWild PWild (PVar "e")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EVar "walkStmts") (EVar "w")) (EVar "ctx")) (EVar "bound")) (EVar "rest")) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EApp (EVar "evalCtx") (EVar "ctx"))) (EVar "bound")) (EVar "e")) (EVar "acc"))))
(DTypeSig false "walkSection" (TyFun (TyCon "InitWalk") (TyFun (TyCon "WalkCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "Section") (TyFun (TyApp (TyCon "List") (TyCon "InitMention")) (TyApp (TyCon "List") (TyCon "InitMention"))))))))
(DFunDef false "walkSection" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "SecBare" (PVar "op")) (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EVar "sectionOp") (EVar "w")) (EVar "ctx")) (EVar "bound")) (EVar "op")) (EVar "acc")))
(DFunDef false "walkSection" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "SecRight" (PVar "op") (PVar "e")) (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EVar "sectionOp") (EVar "w")) (EVar "ctx")) (EVar "bound")) (EVar "op")) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EApp (EVar "evalCtx") (EVar "ctx"))) (EVar "bound")) (EVar "e")) (EVar "acc"))))
(DFunDef false "walkSection" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "SecLeft" (PVar "e") (PVar "op")) (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EVar "sectionOp") (EVar "w")) (EVar "ctx")) (EVar "bound")) (EVar "op")) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EApp (EVar "evalCtx") (EVar "ctx"))) (EVar "bound")) (EVar "e")) (EVar "acc"))))
(DTypeSig false "sectionOp" (TyFun (TyCon "InitWalk") (TyFun (TyCon "WalkCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "InitMention")) (TyApp (TyCon "List") (TyCon "InitMention"))))))))
(DFunDef false "sectionOp" ((PVar "w") (PVar "ctx") (PVar "bound") (PVar "op") (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EVar "nameRef") (EVar "w")) (EApp (EVar "evalCtx") (EVar "ctx"))) (EVar "bound")) (EVar "op")) (EApp (EApp (EApp (EApp (EVar "operatorRef") (EVar "w")) (EVar "ctx")) (EApp (EFieldAccess (EFieldAccess (EVar "w") "iwInputs") "iiBinopMethod") (EVar "op"))) (EApp (EApp (EApp (EApp (EVar "operatorRef") (EVar "w")) (EVar "ctx")) (EApp (EFieldAccess (EFieldAccess (EVar "w") "iwInputs") "iiUnopMethod") (EVar "op"))) (EVar "acc")))))
(DData Private "AppShape" () ((variant "ShapeCtor" (ConPos)) (variant "ShapePartial" (ConPos)) (variant "ShapeDefer" (ConPos)) (variant "ShapeCall" (ConPos))) ())
(DTypeSig false "spine" (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyTuple (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Expr"))))))
(DFunDef false "spine" ((PCon "EApp" (PVar "f") (PVar "x")) (PVar "args")) (EApp (EApp (EVar "spine") (EVar "f")) (EBinOp "::" (EVar "x") (EVar "args"))))
(DFunDef false "spine" ((PCon "ELoc" PWild (PVar "e")) (PVar "args")) (EApp (EApp (EVar "spine") (EVar "e")) (EVar "args")))
(DFunDef false "spine" ((PCon "EDoOrigin" PWild (PVar "e")) (PVar "args")) (EApp (EApp (EVar "spine") (EVar "e")) (EVar "args")))
(DFunDef false "spine" ((PCon "EHeadAnnot" (PVar "e") PWild) (PVar "args")) (EApp (EApp (EVar "spine") (EVar "e")) (EVar "args")))
(DFunDef false "spine" ((PCon "EAnnot" (PVar "e") PWild) (PVar "args")) (EApp (EApp (EVar "spine") (EVar "e")) (EVar "args")))
(DFunDef false "spine" ((PVar "e") (PVar "args")) (ETuple (EVar "e") (EVar "args")))
(DTypeSig false "walkApp" (TyFun (TyCon "InitWalk") (TyFun (TyCon "WalkCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "InitMention")) (TyApp (TyCon "List") (TyCon "InitMention"))))))))
(DFunDef false "walkApp" ((PVar "w") (PVar "ctx") (PVar "bound") (PVar "e") (PVar "acc")) (EBlock (DoLet false false (PTuple (PVar "hd") (PVar "args")) (EApp (EApp (EVar "spine") (EVar "e")) (EListLit))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "appShape") (EVar "w")) (EVar "ctx")) (EVar "bound")) (EVar "hd")) (EApp (EVar "length") (EVar "args"))) (arm (PCon "ShapeCtor") () (EApp (EApp (EApp (EApp (EApp (EVar "walkAll") (EVar "w")) (EApp (EVar "componentCtx") (EVar "ctx"))) (EVar "bound")) (EVar "args")) (EVar "acc"))) (arm (PCon "ShapePartial") () (EApp (EApp (EApp (EApp (EApp (EVar "walkAll") (EVar "w")) (EApp (EVar "componentCtx") (EVar "ctx"))) (EVar "bound")) (EVar "args")) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EApp (EVar "componentCtx") (EVar "ctx"))) (EVar "bound")) (EVar "hd")) (EVar "acc")))) (arm (PCon "ShapeDefer") () (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc2") (PVar "a")) (EApp (EApp (EApp (EApp (EVar "walkDeferArg") (EVar "w")) (EVar "bound")) (EVar "a")) (EVar "acc2")))) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EApp (EVar "evalCtx") (EVar "ctx"))) (EVar "bound")) (EVar "hd")) (EVar "acc"))) (EVar "args"))) (arm (PCon "ShapeCall") () (EApp (EApp (EApp (EApp (EApp (EVar "walkAll") (EVar "w")) (EApp (EVar "evalCtx") (EVar "ctx"))) (EVar "bound")) (EVar "args")) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EApp (EVar "evalCtx") (EVar "ctx"))) (EVar "bound")) (EVar "hd")) (EVar "acc"))))))))
(DTypeSig false "walkDeferArg" (TyFun (TyCon "InitWalk") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "InitMention")) (TyApp (TyCon "List") (TyCon "InitMention")))))))
(DFunDef false "walkDeferArg" ((PVar "w") (PVar "bound") (PVar "a") (PVar "acc")) (EMatch (EApp (EVar "directLambda") (EVar "a")) (arm (PCon "Some" (PTuple (PVar "ps") (PVar "body"))) () (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EVar "CtxDelay")) (EApp (EApp (EVar "bindPats") (EVar "ps")) (EVar "bound"))) (EVar "body")) (EVar "acc"))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EVar "CtxDeref")) (EVar "bound")) (EVar "a")) (EVar "acc")))))
(DTypeSig false "directLambda" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))))
(DFunDef false "directLambda" ((PCon "ELam" (PVar "ps") (PVar "body"))) (EApp (EVar "Some") (ETuple (EVar "ps") (EVar "body"))))
(DFunDef false "directLambda" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "directLambda") (EVar "e")))
(DFunDef false "directLambda" ((PCon "EAnnot" (PVar "e") PWild)) (EApp (EVar "directLambda") (EVar "e")))
(DFunDef false "directLambda" (PWild) (EVar "None"))
(DTypeSig false "appShape" (TyFun (TyCon "InitWalk") (TyFun (TyCon "WalkCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "Expr") (TyFun (TyCon "Int") (TyCon "AppShape")))))))
(DFunDef false "appShape" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "EVar" (PVar "n")) (PVar "nargs")) (EApp (EApp (EApp (EApp (EApp (EVar "nameShape") (EVar "w")) (EVar "ctx")) (EVar "bound")) (EVar "n")) (EVar "nargs")))
(DFunDef false "appShape" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "EVarId" (PVar "n") PWild) (PVar "nargs")) (EApp (EApp (EApp (EApp (EApp (EVar "nameShape") (EVar "w")) (EVar "ctx")) (EVar "bound")) (EVar "n")) (EVar "nargs")))
(DFunDef false "appShape" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "EVarAt" (PVar "n") PWild) (PVar "nargs")) (EApp (EApp (EApp (EApp (EApp (EVar "nameShape") (EVar "w")) (EVar "ctx")) (EVar "bound")) (EVar "n")) (EVar "nargs")))
(DFunDef false "appShape" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "EDictAt" (PVar "n") PWild) (PVar "nargs")) (EApp (EApp (EApp (EApp (EApp (EVar "nameShape") (EVar "w")) (EVar "ctx")) (EVar "bound")) (EVar "n")) (EVar "nargs")))
(DFunDef false "appShape" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "EMethodAt" (PVar "m") (PLit (LString "")) PWild) PWild) (EIf (EBinOp "&&" (EApp (EVar "isGuarded") (EVar "ctx")) (EApp (EApp (EApp (EVar "isPreludeDefer") (EVar "w")) (EVar "bound")) (EVar "m"))) (EVar "ShapeDefer") (EVar "ShapeCall")))
(DFunDef false "appShape" (PWild PWild PWild PWild PWild) (EVar "ShapeCall"))
(DTypeSig false "nameShape" (TyFun (TyCon "InitWalk") (TyFun (TyCon "WalkCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "AppShape")))))))
(DFunDef false "nameShape" ((PVar "w") (PVar "ctx") (PVar "bound") (PVar "n") (PVar "nargs")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "bound")) (EVar "ShapeCall") (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EFieldAccess (EVar "w") "iwTop")) (arm (PCon "Some" (PVar "arity")) () (EIf (EBinOp "&&" (EApp (EVar "isGuarded") (EVar "ctx")) (EBinOp "<" (EVar "nargs") (EVar "arity"))) (EVar "ShapePartial") (EVar "ShapeCall"))) (arm (PCon "None") () (EIf (EApp (EVar "isCtorName") (EVar "n")) (EVar "ShapeCtor") (EIf (EBinOp "&&" (EApp (EVar "isGuarded") (EVar "ctx")) (EApp (EApp (EApp (EVar "isPreludeDefer") (EVar "w")) (EVar "bound")) (EVar "n"))) (EVar "ShapeDefer") (EVar "ShapeCall"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "isPreludeDefer" (TyFun (TyCon "InitWalk") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "String") (TyCon "Bool")))))
(DFunDef false "isPreludeDefer" ((PVar "w") (PVar "bound") (PVar "n")) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EVar "isDeferSpelling") (EApp (EVar "bareSpelling") (EVar "n"))) (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "bound")))) (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EVar "n")) (EFieldAccess (EVar "w") "iwTop")))) (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EVar "n")) (EFieldAccess (EVar "w") "iwLocalMethods")))) (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EVar "n")) (EFieldAccess (EFieldAccess (EVar "w") "iwInputs") "iiImportedValues")))))
(DTypeSig false "isDeferSpelling" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isDeferSpelling" ((PLit (LString "deferThen"))) (EVar "True"))
(DFunDef false "isDeferSpelling" ((PLit (LString "deferMap"))) (EVar "True"))
(DFunDef false "isDeferSpelling" ((PLit (LString "deferAp"))) (EVar "True"))
(DFunDef false "isDeferSpelling" ((PLit (LString "deferFlatMap"))) (EVar "True"))
(DFunDef false "isDeferSpelling" (PWild) (EVar "False"))
(DTypeSig false "isCtorName" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isCtorName" ((PVar "n")) (EMatch (EApp (EVar "nextChar") (EApp (EVar "startCursor") (EVar "n"))) (arm (PCon "None") () (EVar "False")) (arm (PCon "Some" (PTuple (PVar "c") PWild)) () (EIf (EApp (EVar "not") (EApp (EVar "charIsUpper") (EVar "c"))) (EVar "False") (EMatch (EApp (EApp (EVar "stringIndexOf") (ELit (LString "."))) (EVar "n")) (arm (PCon "None") () (EVar "True")) (arm (PCon "Some" PWild) () (EMatch (EApp (EVar "last") (EApp (EApp (EVar "split") (ELit (LString "."))) (EVar "n"))) (arm (PCon "Some" (PVar "seg")) () (EApp (EVar "isCtorName") (EVar "seg"))) (arm (PCon "None") () (EVar "False")))))))))
(DTypeSig false "bareSpelling" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "bareSpelling" ((PVar "n")) (EApp (EApp (EVar "optionOr") (EVar "n")) (EApp (EApp (EVar "stripPrefix") (ELit (LString "$core."))) (EVar "n"))))
(DTypeSig false "mention" (TyFun (TyCon "String") (TyFun (TyCon "InitEdgeKind") (TyFun (TyCon "InitPosition") (TyCon "InitMention")))))
(DFunDef false "mention" ((PVar "t") (PVar "k") (PVar "p")) (ERecordCreate "InitMention" ((fa "mentionTarget" (EVar "t")) (fa "mentionKind" (EVar "k")) (fa "mentionPosition" (EVar "p")))))
(DTypeSig false "nameRef" (TyFun (TyCon "InitWalk") (TyFun (TyCon "WalkCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "InitMention")) (TyApp (TyCon "List") (TyCon "InitMention"))))))))
(DFunDef false "nameRef" ((PVar "w") (PVar "ctx") (PVar "bound") (PVar "n") (PVar "acc")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "bound")) (EVar "acc") (EIf (EApp (EApp (EVar "omHasKey") (EVar "n")) (EFieldAccess (EVar "w") "iwTop")) (EBinOp "::" (EApp (EApp (EApp (EVar "mention") (EVar "n")) (EVar "ByName")) (EApp (EVar "namePos") (EVar "ctx"))) (EVar "acc")) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "pos") (EApp (EVar "namePos") (EVar "ctx"))) (DoLet false false (PVar "viaMethod") (EMatch (EApp (EApp (EVar "methodKeys") (EVar "w")) (EVar "n")) (arm (PCon "Some" (PVar "keys")) () (EApp (EApp (EApp (EApp (EApp (EVar "dispatchTo") (EVar "w")) (EVar "ByDispatch")) (EVar "pos")) (EVar "keys")) (EVar "acc"))) (arm (PCon "None") () (EVar "acc")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "foreignRef") (EVar "w")) (EVar "pos")) (EVar "n")) (EVar "viaMethod")))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "dictRef" (TyFun (TyCon "InitWalk") (TyFun (TyCon "WalkCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "InitMention")) (TyApp (TyCon "List") (TyCon "InitMention"))))))))
(DFunDef false "dictRef" ((PVar "w") (PVar "ctx") (PVar "bound") (PVar "n") (PVar "acc")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "bound")) (EVar "acc") (EIf (EApp (EApp (EVar "omHasKey") (EVar "n")) (EFieldAccess (EVar "w") "iwTop")) (EBinOp "::" (EApp (EApp (EApp (EVar "mention") (EVar "n")) (EVar "ByName")) (EApp (EVar "namePos") (EVar "ctx"))) (EVar "acc")) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "pos") (EApp (EVar "namePos") (EVar "ctx"))) (DoLet false false (PVar "viaDict") (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EFieldAccess (EFieldAccess (EVar "w") "iwInputs") "iiCalleeIfaces")) (arm (PCon "Some" (PVar "keys")) () (EApp (EApp (EApp (EApp (EApp (EVar "dispatchTo") (EVar "w")) (EVar "ByDispatch")) (EVar "pos")) (EVar "keys")) (EVar "acc"))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "toEvery") (EVar "w")) (EVar "ByDispatch")) (EVar "pos")) (EVar "acc"))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "foreignRef") (EVar "w")) (EVar "pos")) (EVar "n")) (EVar "viaDict")))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "methodRef" (TyFun (TyCon "InitWalk") (TyFun (TyCon "WalkCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "InitMention")) (TyApp (TyCon "List") (TyCon "InitMention")))))))))
(DFunDef false "methodRef" ((PVar "w") (PVar "ctx") (PVar "bound") (PVar "m") (PVar "seed") (PVar "acc")) (EBlock (DoLet false false (PVar "pos") (EApp (EVar "namePos") (EVar "ctx"))) (DoLet false false (PVar "asName") (EIf (EBinOp "&&" (EApp (EApp (EVar "omHasKey") (EVar "m")) (EFieldAccess (EVar "w") "iwTop")) (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EVar "m")) (EVar "bound")))) (EBinOp "::" (EApp (EApp (EApp (EVar "mention") (EVar "m")) (EVar "ByName")) (EVar "pos")) (EVar "acc")) (EVar "acc"))) (DoLet false false (PVar "viaSeed") (EIf (EBinOp "==" (EVar "seed") (ELit (LString ""))) (EVar "asName") (EMatch (EApp (EApp (EVar "stripPrefix") (EFieldAccess (EVar "w") "iwSeedPrefix")) (EVar "seed")) (arm (PCon "Some" (PVar "local")) ((GBool (EApp (EApp (EVar "omHasKey") (EVar "local")) (EFieldAccess (EVar "w") "iwTop")))) (EBinOp "::" (EApp (EApp (EApp (EVar "mention") (EVar "local")) (EVar "ByName")) (EVar "pos")) (EVar "asName"))) (arm PWild () (EApp (EApp (EApp (EApp (EVar "foreignRef") (EVar "w")) (EVar "pos")) (EVar "seed")) (EVar "asName")))))) (DoExpr (EMatch (EApp (EApp (EVar "methodKeys") (EVar "w")) (EVar "m")) (arm (PCon "Some" (PVar "keys")) () (EApp (EApp (EApp (EApp (EApp (EVar "dispatchTo") (EVar "w")) (EVar "ByDispatch")) (EVar "pos")) (EVar "keys")) (EVar "viaSeed"))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "toEvery") (EVar "w")) (EVar "ByDispatch")) (EVar "pos")) (EVar "viaSeed")))))))
(DTypeSig false "sugarMethodRef" (TyFun (TyCon "InitWalk") (TyFun (TyCon "WalkCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "InitMention")) (TyApp (TyCon "List") (TyCon "InitMention")))))))
(DFunDef false "sugarMethodRef" ((PVar "w") (PVar "ctx") (PVar "m") (PVar "acc")) (EMatch (EApp (EApp (EVar "methodKeys") (EVar "w")) (EVar "m")) (arm (PCon "Some" (PVar "keys")) () (EApp (EApp (EApp (EApp (EApp (EVar "dispatchTo") (EVar "w")) (EVar "ByDispatch")) (EApp (EVar "namePos") (EApp (EVar "evalCtx") (EVar "ctx")))) (EVar "keys")) (EVar "acc"))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "toEvery") (EVar "w")) (EVar "ByDispatch")) (EApp (EVar "namePos") (EApp (EVar "evalCtx") (EVar "ctx")))) (EVar "acc")))))
(DTypeSig false "operatorRef" (TyFun (TyCon "InitWalk") (TyFun (TyCon "WalkCtx") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "InitMention")) (TyApp (TyCon "List") (TyCon "InitMention")))))))
(DFunDef false "operatorRef" (PWild PWild (PCon "None") (PVar "acc")) (EVar "acc"))
(DFunDef false "operatorRef" ((PVar "w") (PVar "ctx") (PCon "Some" (PVar "m")) (PVar "acc")) (EMatch (EApp (EApp (EVar "methodKeys") (EVar "w")) (EVar "m")) (arm (PCon "Some" (PVar "keys")) () (EApp (EApp (EApp (EApp (EApp (EVar "dispatchTo") (EVar "w")) (EVar "ByOperator")) (EApp (EVar "namePos") (EApp (EVar "evalCtx") (EVar "ctx")))) (EVar "keys")) (EVar "acc"))) (arm (PCon "None") () (EVar "acc"))))
(DTypeSig false "foreignRef" (TyFun (TyCon "InitWalk") (TyFun (TyCon "InitPosition") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "InitMention")) (TyApp (TyCon "List") (TyCon "InitMention")))))))
(DFunDef false "foreignRef" ((PVar "w") (PVar "pos") (PVar "n") (PVar "acc")) (EIf (EBinOp "||" (EApp (EVar "isEmptyL") (EFieldAccess (EVar "w") "iwOrphans")) (EApp (EVar "isCtorName") (EVar "n"))) (EVar "acc") (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc2") (PVar "o")) (EBinOp "::" (EApp (EApp (EApp (EVar "mention") (EVar "o")) (EVar "ByOrphan")) (EVar "pos")) (EVar "acc2")))) (EVar "acc")) (EFieldAccess (EVar "w") "iwOrphans"))))
(DTypeSig false "methodKeys" (TyFun (TyCon "InitWalk") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "methodKeys" ((PVar "w") (PVar "n")) (EBlock (DoLet false false (PVar "table") (EFieldAccess (EFieldAccess (EVar "w") "iwInputs") "iiMethodIfaces")) (DoLet false false (PVar "bare") (EApp (EVar "bareSpelling") (EVar "n"))) (DoExpr (EMatch (EApp (EApp (EVar "omLookup") (EVar "bare")) (EVar "table")) (arm (PCon "Some" (PVar "keys")) () (EApp (EVar "Some") (EVar "keys"))) (arm (PCon "None") () (EMatch (EApp (EVar "last") (EApp (EApp (EVar "split") (ELit (LString "."))) (EVar "bare"))) (arm (PCon "Some" (PVar "seg")) ((GBool (EBinOp "/=" (EVar "seg") (EVar "bare")))) (EApp (EApp (EVar "omLookup") (EVar "seg")) (EVar "table"))) (arm PWild () (EVar "None"))))))))
(DTypeSig false "dispatchTo" (TyFun (TyCon "InitWalk") (TyFun (TyCon "InitEdgeKind") (TyFun (TyCon "InitPosition") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "InitMention")) (TyApp (TyCon "List") (TyCon "InitMention"))))))))
(DFunDef false "dispatchTo" ((PVar "w") (PVar "kind") (PVar "pos") (PVar "keys") (PVar "acc")) (EIf (EApp (EVar "isEmptyL") (EFieldAccess (EVar "w") "iwImpls")) (EVar "acc") (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc2") (PVar "key")) (EApp (EApp (EApp (EApp (EApp (EVar "dispatchKey") (EVar "w")) (EVar "kind")) (EVar "pos")) (EVar "key")) (EVar "acc2")))) (EVar "acc")) (EVar "keys"))))
(DTypeSig false "dispatchKey" (TyFun (TyCon "InitWalk") (TyFun (TyCon "InitEdgeKind") (TyFun (TyCon "InitPosition") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "InitMention")) (TyApp (TyCon "List") (TyCon "InitMention"))))))))
(DFunDef false "dispatchKey" ((PVar "w") (PVar "kind") (PVar "pos") (PVar "key") (PVar "acc")) (EIf (EBinOp "==" (EVar "key") (ELit (LString ""))) (EApp (EApp (EApp (EApp (EVar "toEvery") (EVar "w")) (EVar "kind")) (EVar "pos")) (EVar "acc")) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "closure") (EApp (EApp (EVar "optionOr") (EListLit (EVar "key"))) (EApp (EApp (EVar "omLookup") (EVar "key")) (EFieldAccess (EFieldAccess (EVar "w") "iwInputs") "iiDispatchClosure")))) (DoExpr (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc2") (PVar "k")) (EIf (EBinOp "==" (EVar "k") (ELit (LString ""))) (EApp (EApp (EApp (EApp (EVar "toEvery") (EVar "w")) (EVar "kind")) (EVar "pos")) (EVar "acc2")) (EApp (EApp (EApp (EApp (EVar "toImpls") (EIf (EBinOp "==" (EVar "k") (EVar "key")) (EVar "kind") (EVar "ByClosure"))) (EVar "pos")) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "k")) (EFieldAccess (EVar "w") "iwImplsByKey")))) (EVar "acc2"))))) (EApp (EApp (EApp (EApp (EVar "toImpls") (EVar "kind")) (EVar "pos")) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (ELit (LString ""))) (EFieldAccess (EVar "w") "iwImplsByKey")))) (EVar "acc"))) (EVar "closure")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "toEvery" (TyFun (TyCon "InitWalk") (TyFun (TyCon "InitEdgeKind") (TyFun (TyCon "InitPosition") (TyFun (TyApp (TyCon "List") (TyCon "InitMention")) (TyApp (TyCon "List") (TyCon "InitMention")))))))
(DFunDef false "toEvery" ((PVar "w") (PVar "kind") (PVar "pos") (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "toImpls") (EVar "kind")) (EVar "pos")) (EFieldAccess (EVar "w") "iwImpls")) (EVar "acc")))
(DTypeSig false "toImpls" (TyFun (TyCon "InitEdgeKind") (TyFun (TyCon "InitPosition") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "InitMention")) (TyApp (TyCon "List") (TyCon "InitMention")))))))
(DFunDef false "toImpls" ((PVar "kind") (PVar "pos") (PVar "impls") (PVar "acc")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc2") (PVar "i")) (EBinOp "::" (EApp (EApp (EApp (EVar "mention") (EVar "i")) (EVar "kind")) (EVar "pos")) (EVar "acc2")))) (EVar "acc")) (EVar "impls")))
(DTypeSig false "bindPats" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit")))))
(DFunDef false "bindPats" ((PVar "ps") (PVar "bound")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "b") (PVar "p")) (EApp (EApp (EVar "bindPat") (EVar "p")) (EVar "b")))) (EVar "bound")) (EVar "ps")))
(DTypeSig false "bindPat" (TyFun (TyCon "Pat") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit")))))
(DFunDef false "bindPat" ((PCon "PVar" (PVar "n") PWild PWild) (PVar "bound")) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (ELit LUnit)) (EVar "bound")))
(DFunDef false "bindPat" ((PCon "PWild") (PVar "bound")) (EVar "bound"))
(DFunDef false "bindPat" ((PCon "PLit" PWild) (PVar "bound")) (EVar "bound"))
(DFunDef false "bindPat" ((PCon "PCon" PWild (PVar "ps")) (PVar "bound")) (EApp (EApp (EVar "bindPats") (EVar "ps")) (EVar "bound")))
(DFunDef false "bindPat" ((PCon "PCons" (PVar "h") (PVar "t")) (PVar "bound")) (EApp (EApp (EVar "bindPat") (EVar "t")) (EApp (EApp (EVar "bindPat") (EVar "h")) (EVar "bound"))))
(DFunDef false "bindPat" ((PCon "PTuple" (PVar "ps")) (PVar "bound")) (EApp (EApp (EVar "bindPats") (EVar "ps")) (EVar "bound")))
(DFunDef false "bindPat" ((PCon "PList" (PVar "ps")) (PVar "bound")) (EApp (EApp (EVar "bindPats") (EVar "ps")) (EVar "bound")))
(DFunDef false "bindPat" ((PCon "PAs" (PVar "n") PWild PWild (PVar "p")) (PVar "bound")) (EApp (EApp (EVar "bindPat") (EVar "p")) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (ELit LUnit)) (EVar "bound"))))
(DFunDef false "bindPat" ((PCon "POr" (PVar "ps")) (PVar "bound")) (EApp (EApp (EVar "bindPats") (EVar "ps")) (EVar "bound")))
(DFunDef false "bindPat" ((PCon "PRng" PWild PWild PWild) (PVar "bound")) (EVar "bound"))
(DFunDef false "bindPat" ((PCon "PRec" PWild (PVar "fields") PWild) (PVar "bound")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "b") (PVar "f")) (EMatch (EVar "f") (arm (PCon "RecPatField" (PVar "n") PWild PWild (PCon "None")) () (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (ELit LUnit)) (EVar "b"))) (arm (PCon "RecPatField" PWild PWild PWild (PCon "Some" (PVar "p"))) () (EApp (EApp (EVar "bindPat") (EVar "p")) (EVar "b")))))) (EVar "bound")) (EVar "fields")))
(DFunDef false "bindPat" ((PCon "PAnn" (PVar "p") PWild) (PVar "bound")) (EApp (EApp (EVar "bindPat") (EVar "p")) (EVar "bound")))
(DTypeSig true "initOrder" (TyFun (TyCon "InitGraph") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "initOrder" ((PVar "g")) (EBlock (DoLet false false (PVar "nodes") (EFieldAccess (EVar "g") "igraphNodes")) (DoLet false false (PVar "adj") (EApp (EApp (EVar "omFromPairs") (EApp (EApp (EVar "map") (ELam ((PVar "n")) (ETuple (EFieldAccess (EVar "n") "inodeName") (EApp (EApp (EVar "map") (ELam ((PVar "m")) (EFieldAccess (EVar "m") "mentionTarget"))) (EFieldAccess (EVar "n") "inodeMentions"))))) (EVar "nodes"))) (EVar "omEmpty"))) (DoLet false false (PVar "sccs") (EApp (EApp (EVar "tarjanSCCs") (EApp (EApp (EVar "map") (ELam ((PVar "n")) (EFieldAccess (EVar "n") "inodeName"))) (EVar "nodes"))) (EVar "adj"))) (DoLet false false (PVar "compOf") (EApp (EApp (EApp (EVar "componentIndex") (EVar "sccs")) (ELit (LInt 0))) (EVar "omEmpty"))) (DoLet false false (PVar "members") (EApp (EApp (EApp (EVar "componentMembers") (EVar "compOf")) (EApp (EVar "reverseL") (EVar "nodes"))) (EVar "empty"))) (DoLet false false (PVar "deps") (EApp (EApp (EApp (EVar "componentDeps") (EVar "compOf")) (EVar "nodes")) (EVar "empty"))) (DoLet false false (PVar "indegree") (EApp (EApp (EVar "M.mapWithKey") (ELam (PWild (PVar "ds")) (EApp (EVar "M.size") (EVar "ds")))) (EVar "deps"))) (DoLet false false (PVar "dependents") (EApp (EApp (EApp (EVar "M.foldrWithKey") (ELam ((PVar "s") (PVar "ds") (PVar "acc")) (EApp (EApp (EApp (EVar "M.foldrWithKey") (ELam ((PVar "d") PWild (PVar "acc2")) (EApp (EApp (EApp (EVar "M.set") (EVar "d")) (EBinOp "::" (EVar "s") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "M.get") (EVar "d")) (EVar "acc2"))))) (EVar "acc2")))) (EVar "acc")) (EVar "ds")))) (EVar "empty")) (EVar "deps"))) (DoLet false false (PVar "ready") (EApp (EApp (EApp (EVar "M.foldrWithKey") (ELam ((PVar "s") (PVar "ms") (PVar "acc")) (EIf (EBinOp "==" (EApp (EApp (EVar "optionOr") (ELit (LInt 0))) (EApp (EApp (EVar "M.get") (EVar "s")) (EVar "indegree"))) (ELit (LInt 0))) (EApp (EApp (EApp (EVar "M.set") (EApp (EVar "firstOrder") (EVar "ms"))) (EVar "s")) (EVar "acc")) (EVar "acc")))) (EVar "empty")) (EVar "members"))) (DoExpr (EApp (EVar "reverseL") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "kahn") (EVar "g")) (EVar "members")) (EVar "dependents")) (EVar "indegree")) (EVar "ready")) (EListLit))))))
(DTypeSig false "componentIndex" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyApp (TyCon "OrdMap") (TyCon "Int"))))))
(DFunDef false "componentIndex" ((PList) PWild (PVar "acc")) (EVar "acc"))
(DFunDef false "componentIndex" ((PCons (PVar "c") (PVar "rest")) (PVar "i") (PVar "acc")) (EApp (EApp (EApp (EVar "componentIndex") (EVar "rest")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "a") (PVar "n")) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (EVar "i")) (EVar "a")))) (EVar "acc")) (EVar "c"))))
(DTypeSig false "componentMembers" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "InitNode")) (TyFun (TyApp (TyApp (TyCon "M.Map") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "InitNode"))) (TyApp (TyApp (TyCon "M.Map") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "InitNode")))))))
(DFunDef false "componentMembers" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "componentMembers" ((PVar "compOf") (PCons (PVar "n") (PVar "rest")) (PVar "acc")) (EBlock (DoLet false false (PVar "c") (EApp (EApp (EVar "optionOr") (ELit (LInt 0))) (EApp (EApp (EVar "omLookup") (EFieldAccess (EVar "n") "inodeName")) (EVar "compOf")))) (DoExpr (EApp (EApp (EApp (EVar "componentMembers") (EVar "compOf")) (EVar "rest")) (EApp (EApp (EApp (EVar "M.set") (EVar "c")) (EBinOp "::" (EVar "n") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "M.get") (EVar "c")) (EVar "acc"))))) (EVar "acc"))))))
(DTypeSig false "componentDeps" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "InitNode")) (TyFun (TyApp (TyApp (TyCon "M.Map") (TyCon "Int")) (TyApp (TyApp (TyCon "M.Map") (TyCon "Int")) (TyCon "Unit"))) (TyApp (TyApp (TyCon "M.Map") (TyCon "Int")) (TyApp (TyApp (TyCon "M.Map") (TyCon "Int")) (TyCon "Unit")))))))
(DFunDef false "componentDeps" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "componentDeps" ((PVar "compOf") (PCons (PVar "n") (PVar "rest")) (PVar "acc")) (EBlock (DoLet false false (PVar "c") (EApp (EApp (EVar "optionOr") (ELit (LInt 0))) (EApp (EApp (EVar "omLookup") (EFieldAccess (EVar "n") "inodeName")) (EVar "compOf")))) (DoLet false false (PVar "mine") (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "s") (PVar "m")) (EMatch (EApp (EApp (EVar "omLookup") (EFieldAccess (EVar "m") "mentionTarget")) (EVar "compOf")) (arm (PCon "Some" (PVar "d")) () (EIf (EBinOp "==" (EVar "d") (EVar "c")) (EVar "s") (EApp (EApp (EApp (EVar "M.set") (EVar "d")) (ELit LUnit)) (EVar "s")))) (arm (PCon "None") () (EVar "s"))))) (EApp (EApp (EVar "optionOr") (EVar "empty")) (EApp (EApp (EVar "M.get") (EVar "c")) (EVar "acc")))) (EFieldAccess (EVar "n") "inodeMentions"))) (DoExpr (EApp (EApp (EApp (EVar "componentDeps") (EVar "compOf")) (EVar "rest")) (EApp (EApp (EApp (EVar "M.set") (EVar "c")) (EVar "mine")) (EVar "acc"))))))
(DTypeSig false "firstOrder" (TyFun (TyApp (TyCon "List") (TyCon "InitNode")) (TyCon "Int")))
(DFunDef false "firstOrder" ((PList)) (ELit (LInt 0)))
(DFunDef false "firstOrder" ((PCons (PVar "n") PWild)) (EFieldAccess (EVar "n") "inodeOrder"))
(DTypeSig false "kahn" (TyFun (TyCon "InitGraph") (TyFun (TyApp (TyApp (TyCon "M.Map") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "InitNode"))) (TyFun (TyApp (TyApp (TyCon "M.Map") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int"))) (TyFun (TyApp (TyApp (TyCon "M.Map") (TyCon "Int")) (TyCon "Int")) (TyFun (TyApp (TyApp (TyCon "M.Map") (TyCon "Int")) (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))))
(DFunDef false "kahn" ((PVar "g") (PVar "members") (PVar "dependents") (PVar "indegree") (PVar "ready") (PVar "out")) (EMatch (EApp (EVar "M.minView") (EVar "ready")) (arm (PCon "None") () (EVar "out")) (arm (PCon "Some" (PTuple PWild (PVar "s") (PVar "rest"))) () (EBlock (DoLet false false (PVar "ms") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "M.get") (EVar "s")) (EVar "members")))) (DoLet false false (PVar "out2") (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "n")) (EIf (EBinOp "&&" (EBinOp "==" (EFieldAccess (EVar "n") "inodeKind") (EVar "ValueNode")) (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EFieldAccess (EVar "n") "inodeName")) (EFieldAccess (EVar "g") "igraphNotInitialised")))) (EBinOp "::" (EFieldAccess (EVar "n") "inodeName") (EVar "acc")) (EVar "acc")))) (EVar "out")) (EVar "ms"))) (DoLet false false (PTuple (PVar "indegree2") (PVar "ready2")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "st") (PVar "d")) (EMatch (EVar "st") (arm (PTuple (PVar "deg") (PVar "rdy")) () (EBlock (DoLet false false (PVar "left") (EBinOp "-" (EApp (EApp (EVar "optionOr") (ELit (LInt 0))) (EApp (EApp (EVar "M.get") (EVar "d")) (EVar "deg"))) (ELit (LInt 1)))) (DoLet false false (PVar "deg2") (EApp (EApp (EApp (EVar "M.set") (EVar "d")) (EVar "left")) (EVar "deg"))) (DoExpr (EIf (EBinOp "==" (EVar "left") (ELit (LInt 0))) (ETuple (EVar "deg2") (EApp (EApp (EApp (EVar "M.set") (EApp (EVar "firstOrder") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "M.get") (EVar "d")) (EVar "members"))))) (EVar "d")) (EVar "rdy"))) (ETuple (EVar "deg2") (EVar "rdy"))))))))) (ETuple (EVar "indegree") (EVar "rest"))) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "M.get") (EVar "s")) (EVar "dependents"))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "kahn") (EVar "g")) (EVar "members")) (EVar "dependents")) (EVar "indegree2")) (EVar "ready2")) (EVar "out2")))))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Arm" true) (mem "Constraint" true) (mem "Decl" true) (mem "DoStmt" true) (mem "Expr" true) (mem "FieldAssign" true) (mem "FunClause" true) (mem "Guard" true) (mem "GuardArm" true) (mem "IfaceMethod" true) (mem "ImplMethod" true) (mem "InterpPart" true) (mem "LetBind" true) (mem "Loc" false) (mem "MethodDefault" true) (mem "Pat" true) (mem "RecPatField" true) (mem "Require" true) (mem "Section" true) (mem "Super" true) (mem "Ty" true) (mem "TyConOrigin" true) (mem "ifaceIdentity" false))))
(DUse false (UseGroup ("list") ((mem "last" false))))
(DUse false (UseAlias ("map") "M"))
(DUse false (UseGroup ("string") ((mem "nextChar" false) (mem "split" false) (mem "startCursor" false) (mem "stripPrefix" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omFromPairs" false) (mem "omHasKey" false) (mem "omInsert" false) (mem "omLookup" false) (mem "omMapValues" false))))
(DUse false (UseGroup ("support" "scc") ((mem "tarjanSCCs" false))))
(DUse false (UseGroup ("support" "util") ((mem "isEmptyL" false) (mem "isNonEmptyL" false) (mem "reverseL" false))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "renderAtoms" false) (mem "rowFlat" false))))
(DUse false (UseGroup ("types" "repr") ((mem "IfaceRef" true) (mem "Scheme" true) (mem "VecObl" true))))
(DUse false (UseGroup ("types" "tc_env") ((mem "ceRowIface" false) (mem "ceRowMethods" false) (mem "ceRowSupers" false) (mem "ieRowTriple" false) (mem "ieRowsVisibleAt" false) (mem "methodRowIface" false))))
(DUse false (UseGroup ("types" "tc_types") ((mem "ClassEnv" true) (mem "DeclEnvs" true) (mem "MethodEnv" true) (mem "ModuleBindings" true) (mem "ModuleCtx" true) (mem "ModuleSeed" true))))
(DData Public "InitInputs" () ((variant "InitInputs" (ConNamed (field "iiModule" (TyCon "String")) (field "iiDecls" (TyApp (TyCon "List") (TyCon "Decl"))) (field "iiSchemes" (TyApp (TyCon "OrdMap") (TyCon "Scheme"))) (field "iiMethodIfaces" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String")))) (field "iiDispatchClosure" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String")))) (field "iiCalleeIfaces" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String")))) (field "iiBinopMethod" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))) (field "iiUnopMethod" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))) (field "iiImportedValues" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "iiConstrained" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "iiExempt" (TyApp (TyCon "OrdMap") (TyCon "Unit")))))) ())
(DData Public "InitPosition" () ((variant "AtDeref" (ConPos)) (variant "AtGuard" (ConPos)) (variant "AtDelay" (ConPos))) ())
(DImpl true "Eq" ((TyCon "InitPosition")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "AtDeref") (PCon "AtDeref")) () (EVar "True")) (arm (PTuple (PCon "AtGuard") (PCon "AtGuard")) () (EVar "True")) (arm (PTuple (PCon "AtDelay") (PCon "AtDelay")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "InitPosition")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "AtDeref") () (ELit (LString "AtDeref"))) (arm (PCon "AtGuard") () (ELit (LString "AtGuard"))) (arm (PCon "AtDelay") () (ELit (LString "AtDelay")))))))
(DData Public "InitEdgeKind" () ((variant "ByName" (ConPos)) (variant "ByDispatch" (ConPos)) (variant "ByOperator" (ConPos)) (variant "ByOrphan" (ConPos)) (variant "ByClosure" (ConPos))) ())
(DImpl true "Eq" ((TyCon "InitEdgeKind")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "ByName") (PCon "ByName")) () (EVar "True")) (arm (PTuple (PCon "ByDispatch") (PCon "ByDispatch")) () (EVar "True")) (arm (PTuple (PCon "ByOperator") (PCon "ByOperator")) () (EVar "True")) (arm (PTuple (PCon "ByOrphan") (PCon "ByOrphan")) () (EVar "True")) (arm (PTuple (PCon "ByClosure") (PCon "ByClosure")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "InitEdgeKind")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "ByName") () (ELit (LString "ByName"))) (arm (PCon "ByDispatch") () (ELit (LString "ByDispatch"))) (arm (PCon "ByOperator") () (ELit (LString "ByOperator"))) (arm (PCon "ByOrphan") () (ELit (LString "ByOrphan"))) (arm (PCon "ByClosure") () (ELit (LString "ByClosure")))))))
(DData Public "InitMention" () ((variant "InitMention" (ConNamed (field "mentionTarget" (TyCon "String")) (field "mentionKind" (TyCon "InitEdgeKind")) (field "mentionPosition" (TyCon "InitPosition"))))) ())
(DImpl true "Eq" ((TyCon "InitMention")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PRec "InitMention" ((rf "mentionTarget" (PVar "__a0")) (rf "mentionKind" (PVar "__a1")) (rf "mentionPosition" (PVar "__a2"))) false) (PRec "InitMention" ((rf "mentionTarget" (PVar "__b0")) (rf "mentionKind" (PVar "__b1")) (rf "mentionPosition" (PVar "__b2"))) false)) () (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EMethodRef "eq") (EVar "__a2")) (EVar "__b2"))))))))
(DImpl true "Debug" ((TyCon "InitMention")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PRec "InitMention" ((rf "mentionTarget" (PVar "__a0")) (rf "mentionKind" (PVar "__a1")) (rf "mentionPosition" (PVar "__a2"))) false) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "InitMention {")) (ELit (LString " mentionTarget = "))) (EApp (EMethodRef "debug") (EVar "__a0"))) (ELit (LString ", mentionKind = "))) (EApp (EMethodRef "debug") (EVar "__a1"))) (ELit (LString ", mentionPosition = "))) (EApp (EMethodRef "debug") (EVar "__a2"))) (ELit (LString " }"))))))))
(DData Public "InitNodeKind" () ((variant "ValueNode" (ConPos)) (variant "FunctionNode" (ConPos)) (variant "ImplNode" (ConPos))) ())
(DImpl true "Eq" ((TyCon "InitNodeKind")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "ValueNode") (PCon "ValueNode")) () (EVar "True")) (arm (PTuple (PCon "FunctionNode") (PCon "FunctionNode")) () (EVar "True")) (arm (PTuple (PCon "ImplNode") (PCon "ImplNode")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "InitNodeKind")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "ValueNode") () (ELit (LString "ValueNode"))) (arm (PCon "FunctionNode") () (ELit (LString "FunctionNode"))) (arm (PCon "ImplNode") () (ELit (LString "ImplNode")))))))
(DData Public "InitNode" () ((variant "InitNode" (ConNamed (field "inodeName" (TyCon "String")) (field "inodeKind" (TyCon "InitNodeKind")) (field "inodeOrder" (TyCon "Int")) (field "inodeLoc" (TyApp (TyCon "Option") (TyCon "Loc"))) (field "inodeMentions" (TyApp (TyCon "List") (TyCon "InitMention")))))) ())
(DData Public "InitGraph" () ((variant "InitGraph" (ConNamed (field "igraphNodes" (TyApp (TyCon "List") (TyCon "InitNode"))) (field "igraphNotInitialised" (TyApp (TyCon "OrdMap") (TyCon "Unit")))))) ())
(DData Public "InitViolation" () ((variant "InitViolation" (ConNamed (field "ivName" (TyCon "String")) (field "ivRow" (TyCon "String")) (field "ivLoc" (TyApp (TyCon "Option") (TyCon "Loc")))))) ())
(DTypeSig true "checkInitRules" (TyFun (TyCon "InitInputs") (TyFun (TyCon "InitGraph") (TyApp (TyCon "List") (TyCon "InitViolation")))))
(DFunDef false "checkInitRules" ((PVar "inputs") (PVar "g")) (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "n")) (EIf (EBinOp "&&" (EBinOp "==" (EFieldAccess (EVar "n") "inodeKind") (EVar "ValueNode")) (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EFieldAccess (EVar "n") "inodeName")) (EFieldAccess (EVar "g") "igraphNotInitialised")))) (EApp (EApp (EVar "purityViolation") (EVar "inputs")) (EVar "n")) (EListLit)))) (EFieldAccess (EVar "g") "igraphNodes")))
(DTypeSig false "purityViolation" (TyFun (TyCon "InitInputs") (TyFun (TyCon "InitNode") (TyApp (TyCon "List") (TyCon "InitViolation")))))
(DFunDef false "purityViolation" ((PVar "inputs") (PVar "n")) (EMatch (EApp (EApp (EVar "omLookup") (EFieldAccess (EVar "n") "inodeName")) (EFieldAccess (EVar "inputs") "iiSchemes")) (arm (PCon "Some" (PCon "Forall" PWild PWild PWild PWild (PVar "force") PWild)) () (EMatch (EApp (EVar "fst") (EApp (EVar "rowFlat") (EVar "force"))) (arm (PList) () (EListLit)) (arm (PVar "labels") () (EListLit (ERecordCreate "InitViolation" ((fa "ivName" (EFieldAccess (EVar "n") "inodeName")) (fa "ivRow" (EBinOp "++" (EBinOp "++" (ELit (LString "<")) (EApp (EMethodRef "display") (EApp (EVar "renderAtoms") (EVar "labels")))) (ELit (LString ">")))) (fa "ivLoc" (EFieldAccess (EVar "n") "inodeLoc")))))))) (arm (PCon "None") () (EListLit))))
(DTypeSig true "initInputsAt" (TyFun (TyCon "String") (TyFun (TyCon "ModuleSeed") (TyFun (TyCon "ModuleBindings") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "DeclEnvs") (TyFun (TyCon "Int") (TyFun (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyFun (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyCon "InitInputs")))))))))))
(DFunDef false "initInputsAt" ((PVar "mid") (PVar "seed") (PVar "bindings") (PVar "marked") (PVar "mctx") (PVar "envs") (PVar "ord") (PVar "binop") (PVar "unop")) (EBlock (DoLet false false (PVar "dispatching") (EApp (EVar "declaresImpl") (EVar "marked"))) (DoExpr (ERecordCreate "InitInputs" ((fa "iiModule" (EVar "mid")) (fa "iiDecls" (EVar "marked")) (fa "iiSchemes" (EFieldAccess (EVar "bindings") "mbStandaloneSchemes")) (fa "iiMethodIfaces" (EIf (EVar "dispatching") (EApp (EVar "methodIfacesOf") (EFieldAccess (EVar "envs") "deMethods")) (EVar "omEmpty"))) (fa "iiDispatchClosure" (EIf (EVar "dispatching") (EApp (EApp (EVar "dispatchClosureOf") (EVar "envs")) (EVar "ord")) (EVar "omEmpty"))) (fa "iiCalleeIfaces" (EIf (EVar "dispatching") (EApp (EVar "calleeIfacesOf") (EVar "mctx")) (EVar "omEmpty"))) (fa "iiBinopMethod" (EVar "binop")) (fa "iiUnopMethod" (EVar "unop")) (fa "iiImportedValues" (EFieldAccess (EVar "seed") "msImportedNames")) (fa "iiConstrained" (EApp (EVar "constrainedOf") (EVar "mctx"))) (fa "iiExempt" (EApp (EApp (EApp (EVar "omInsert") (ELit (LString "main"))) (ELit LUnit)) (EVar "omEmpty"))))))))
(DTypeSig false "declaresImpl" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool")))
(DFunDef false "declaresImpl" ((PList)) (EVar "False"))
(DFunDef false "declaresImpl" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "declaresImpl") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "declaresImpl" ((PCons (PRec "DImpl" ((rf "implOrigin" PWild)) false) PWild)) (EVar "True"))
(DFunDef false "declaresImpl" ((PCons PWild (PVar "rest"))) (EApp (EVar "declaresImpl") (EVar "rest")))
(DTypeSig false "refKey" (TyFun (TyCon "IfaceRef") (TyCon "String")))
(DFunDef false "refKey" ((PVar "r")) (EApp (EApp (EVar "ifaceIdentity") (EFieldAccess (EVar "r") "irOrigin")) (EFieldAccess (EVar "r") "irName")))
(DTypeSig false "methodIfacesOf" (TyFun (TyCon "MethodEnv") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "methodIfacesOf" ((PVar "env")) (EApp (EApp (EVar "omMapValues") (ELam ((PVar "rows")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "r")) (EApp (EVar "refKey") (EApp (EVar "methodRowIface") (EVar "r"))))) (EVar "rows")))) (EFieldAccess (EVar "env") "meByName")))
(DTypeSig false "calleeIfacesOf" (TyFun (TyCon "ModuleCtx") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "calleeIfacesOf" ((PVar "mctx")) (EBlock (DoLet false true (PVar "keysOf") (ELam ((PVar "obls")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "o")) (EApp (EVar "refKey") (EFieldAccess (EVar "o") "voIface")))) (EVar "obls")))) (DoLet false false (PVar "core") (EApp (EApp (EVar "omMapValues") (EVar "keysOf")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "crossRun") "coreSchemeObligationsRef") "value"))) (DoExpr (EApp (EApp (EApp (EVar "M.foldlWithKey") (ELam ((PVar "acc") (PVar "n") (PVar "obls")) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (EApp (EVar "keysOf") (EVar "obls"))) (EVar "acc")))) (EVar "core")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "importedSchemeOblsRef") "value")))))
(DTypeSig false "constrainedOf" (TyFun (TyCon "ModuleCtx") (TyApp (TyCon "OrdMap") (TyCon "Unit"))))
(DFunDef false "constrainedOf" ((PVar "mctx")) (EBlock (DoLet false false (PVar "ids") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "schemeDefIdsRef") "value")) (DoExpr (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "row")) (EMatch (EVar "row") (arm (PTuple (PTuple (PVar "n") (PVar "bid")) (PVar "obls")) () (EIf (EBinOp "&&" (EApp (EVar "isNonEmptyL") (EVar "obls")) (EBinOp "==" (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "ids")) (EApp (EVar "Some") (EVar "bid")))) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (ELit LUnit)) (EVar "acc")) (EVar "acc")))))) (EVar "omEmpty")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "schemeObligationsRef") "value")))))
(DTypeSig false "dispatchClosureOf" (TyFun (TyCon "DeclEnvs") (TyFun (TyCon "Int") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "dispatchClosureOf" ((PVar "envs") (PVar "ord")) (EBlock (DoLet false false (PVar "withSupers") (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "row")) (EApp (EApp (EApp (EVar "addSteps") (EApp (EVar "refKey") (EApp (EVar "ceRowIface") (EVar "row")))) (EBinOp "++" (EApp (EApp (EMethodRef "map") (ELam ((PVar "s")) (EApp (EApp (EVar "ifaceIdentity") (EFieldAccess (EVar "s") "superOrigin")) (EFieldAccess (EVar "s") "superHead")))) (EApp (EVar "ceRowSupers") (EVar "row"))) (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "m")) (EMatch (EVar "m") (arm (PTuple PWild (PVar "ty") PWild) () (EApp (EApp (EVar "tyConstraintKeys") (EVar "ty")) (EListLit)))))) (EApp (EVar "ceRowMethods") (EVar "row"))))) (EVar "acc")))) (EVar "omEmpty")) (EFieldAccess (EFieldAccess (EVar "envs") "deIfaces") "ceRows"))) (DoLet false false (PVar "steps") (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "row")) (EMatch (EApp (EVar "ieRowTriple") (EVar "row")) (arm (PTuple (PVar "ir") PWild (PVar "reqs")) () (EApp (EApp (EApp (EVar "addSteps") (EApp (EVar "refKey") (EVar "ir"))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "q")) (EApp (EApp (EVar "ifaceIdentity") (EFieldAccess (EVar "q") "requireOrigin")) (EFieldAccess (EVar "q") "requireHead")))) (EVar "reqs"))) (EVar "acc")))))) (EVar "withSupers")) (EApp (EApp (EVar "ieRowsVisibleAt") (EVar "ord")) (EFieldAccess (EVar "envs") "deImpls")))) (DoExpr (EApp (EApp (EApp (EVar "M.foldlWithKey") (ELam ((PVar "acc") (PVar "k") PWild) (EApp (EApp (EApp (EVar "omInsert") (EVar "k")) (EApp (EApp (EApp (EApp (EVar "closureFrom") (EVar "steps")) (EListLit (EVar "k"))) (EVar "omEmpty")) (EListLit))) (EVar "acc")))) (EVar "omEmpty")) (EVar "steps")))))
(DTypeSig false "addSteps" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "addSteps" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "addSteps" ((PVar "k") (PVar "ks") (PVar "acc")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "k")) (EVar "acc")) (arm (PCon "Some" (PVar "old")) () (EApp (EApp (EApp (EVar "omInsert") (EVar "k")) (EBinOp "++" (EVar "ks") (EVar "old"))) (EVar "acc"))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "omInsert") (EVar "k")) (EVar "ks")) (EVar "acc")))))
(DTypeSig false "closureFrom" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "closureFrom" (PWild (PList) PWild (PVar "out")) (EVar "out"))
(DFunDef false "closureFrom" ((PVar "steps") (PCons (PVar "k") (PVar "rest")) (PVar "seen") (PVar "out")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "k")) (EVar "seen")) (EApp (EApp (EApp (EApp (EVar "closureFrom") (EVar "steps")) (EVar "rest")) (EVar "seen")) (EVar "out")) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "next") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "k")) (EVar "steps")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "closureFrom") (EVar "steps")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "n")) (EBinOp "::" (EVar "n") (EVar "acc")))) (EVar "rest")) (EVar "next"))) (EApp (EApp (EApp (EVar "omInsert") (EVar "k")) (ELit LUnit)) (EVar "seen"))) (EBinOp "::" (EVar "k") (EVar "out"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "tyConstraintKeys" (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "tyConstraintKeys" ((PRec "TyCon" ((rf "tyConName" PWild)) false) (PVar "acc")) (EVar "acc"))
(DFunDef false "tyConstraintKeys" ((PCon "TyVar" PWild) (PVar "acc")) (EVar "acc"))
(DFunDef false "tyConstraintKeys" ((PCon "TyApp" (PVar "a") (PVar "b")) (PVar "acc")) (EApp (EApp (EVar "tyConstraintKeys") (EVar "a")) (EApp (EApp (EVar "tyConstraintKeys") (EVar "b")) (EVar "acc"))))
(DFunDef false "tyConstraintKeys" ((PCon "TyFun" (PVar "a") (PVar "b")) (PVar "acc")) (EApp (EApp (EVar "tyConstraintKeys") (EVar "a")) (EApp (EApp (EVar "tyConstraintKeys") (EVar "b")) (EVar "acc"))))
(DFunDef false "tyConstraintKeys" ((PCon "TyTuple" (PVar "ts")) (PVar "acc")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc2") (PVar "t")) (EApp (EApp (EVar "tyConstraintKeys") (EVar "t")) (EVar "acc2")))) (EVar "acc")) (EVar "ts")))
(DFunDef false "tyConstraintKeys" ((PCon "TyEffect" PWild PWild (PVar "t")) (PVar "acc")) (EApp (EApp (EVar "tyConstraintKeys") (EVar "t")) (EVar "acc")))
(DFunDef false "tyConstraintKeys" ((PCon "TyConstrained" (PVar "cs") (PVar "t")) (PVar "acc")) (EApp (EApp (EVar "tyConstraintKeys") (EVar "t")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc2") (PVar "c")) (EBinOp "::" (EApp (EApp (EVar "ifaceIdentity") (EFieldAccess (EVar "c") "constraintOrigin")) (EFieldAccess (EVar "c") "constraintHead")) (EVar "acc2")))) (EVar "acc")) (EVar "cs"))))
(DFunDef false "tyConstraintKeys" ((PCon "TyNamed" PWild (PVar "t") PWild) (PVar "acc")) (EApp (EApp (EVar "tyConstraintKeys") (EVar "t")) (EVar "acc")))
(DFunDef false "tyConstraintKeys" ((PCon "TyQual" (PVar "t") PWild PWild) (PVar "acc")) (EApp (EApp (EVar "tyConstraintKeys") (EVar "t")) (EVar "acc")))
(DFunDef false "tyConstraintKeys" ((PCon "TyRow" PWild PWild PWild) (PVar "acc")) (EVar "acc"))
(DFunDef false "tyConstraintKeys" ((PCon "TyAuth" PWild PWild) (PVar "acc")) (EVar "acc"))
(DData Private "RawNode" () ((variant "RawNode" (ConNamed (field "rnodeName" (TyCon "String")) (field "rnodeKind" (TyCon "InitNodeKind")) (field "rnodeArity" (TyCon "Int")) (field "rnodeLoc" (TyApp (TyCon "Option") (TyCon "Loc"))) (field "rnodeBodies" (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (field "rnodeKey" (TyCon "String")) (field "rnodeOrphan" (TyCon "Bool"))))) ())
(DData Private "InitWalk" () ((variant "InitWalk" (ConNamed (field "iwInputs" (TyCon "InitInputs")) (field "iwTop" (TyApp (TyCon "OrdMap") (TyCon "Int"))) (field "iwImpls" (TyApp (TyCon "List") (TyCon "String"))) (field "iwImplsByKey" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String")))) (field "iwOrphans" (TyApp (TyCon "List") (TyCon "String"))) (field "iwSeedPrefix" (TyCon "String")) (field "iwLocalMethods" (TyApp (TyCon "OrdMap") (TyCon "Unit")))))) ())
(DTypeSig false "rawNodes" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "RawNode")))))
(DFunDef false "rawNodes" ((PVar "mid") (PVar "decls")) (EApp (EVar "reverseL") (EApp (EApp (EApp (EApp (EVar "rawNodesGo") (EVar "mid")) (ELit (LInt 0))) (EVar "decls")) (EListLit))))
(DTypeSig false "rawNodesGo" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "RawNode")) (TyApp (TyCon "List") (TyCon "RawNode")))))))
(DFunDef false "rawNodesGo" (PWild PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "rawNodesGo" ((PVar "mid") (PVar "k") (PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "rawNodesGo") (EVar "mid")) (EVar "k")) (EBinOp "::" (EVar "d") (EVar "rest"))) (EVar "acc")))
(DFunDef false "rawNodesGo" ((PVar "mid") (PVar "k") (PCons (PCon "DFunDef" PWild (PVar "n") (PVar "ps") (PVar "body") (PVar "site") PWild) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "rawNodesGo") (EVar "mid")) (EVar "k")) (EVar "rest")) (EApp (EApp (EApp (EApp (EApp (EVar "addClause") (EVar "n")) (EVar "ps")) (EVar "body")) (EVar "site")) (EVar "acc"))))
(DFunDef false "rawNodesGo" ((PVar "mid") (PVar "k") (PCons (PCon "DLetGroup" PWild (PVar "binds")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "rawNodesGo") (EVar "mid")) (EVar "k")) (EVar "rest")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc2") (PVar "b")) (EMatch (EVar "b") (arm (PCon "LetBind" (PVar "n") (PVar "clauses") (PVar "site") PWild) () (EBinOp "::" (EApp (EApp (EApp (EVar "bindingNode") (EVar "n")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "c")) (EMatch (EVar "c") (arm (PCon "FunClause" (PVar "ps") (PVar "body")) () (ETuple (EVar "ps") (EVar "body")))))) (EVar "clauses"))) (EApp (EVar "Some") (EVar "site"))) (EVar "acc2")))))) (EVar "acc")) (EVar "binds"))))
(DFunDef false "rawNodesGo" ((PVar "mid") (PVar "k") (PCons (PRec "DImpl" ((rf "iface" None) (rf "tys" None) (rf "methods" None) (rf "implOrigin" None)) false) (PVar "rest")) (PVar "acc")) (EBlock (DoLet false false (PVar "node") (ERecordCreate "RawNode" ((fa "rnodeName" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "impl#")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "k")))) (ELit (LString ":"))) (EApp (EMethodRef "display") (EVar "iface"))) (ELit (LString "")))) (fa "rnodeKind" (EVar "ImplNode")) (fa "rnodeArity" (ELit (LInt 0))) (fa "rnodeLoc" (EVar "None")) (fa "rnodeBodies" (EApp (EApp (EMethodRef "map") (ELam ((PVar "m")) (EMatch (EVar "m") (arm (PCon "ImplMethod" PWild (PVar "ps") (PVar "body")) () (ETuple (EVar "ps") (EVar "body")))))) (EVar "methods"))) (fa "rnodeKey" (EApp (EApp (EVar "ifaceIdentity") (EVar "implOrigin")) (EVar "iface"))) (fa "rnodeOrphan" (EBinOp "&&" (EApp (EVar "not") (EApp (EApp (EVar "declaredIn") (EVar "mid")) (EVar "implOrigin"))) (EApp (EVar "not") (EApp (EApp (EDictApp "any") (EApp (EVar "headDeclaredIn") (EVar "mid"))) (EVar "tys")))))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "rawNodesGo") (EVar "mid")) (EBinOp "+" (EVar "k") (ELit (LInt 1)))) (EVar "rest")) (EBinOp "::" (EVar "node") (EVar "acc"))))))
(DFunDef false "rawNodesGo" ((PVar "mid") (PVar "k") (PCons (PCon "DTypeSig" PWild PWild PWild PWild) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "rawNodesGo") (EVar "mid")) (EVar "k")) (EVar "rest")) (EVar "acc")))
(DFunDef false "rawNodesGo" ((PVar "mid") (PVar "k") (PCons (PCon "DExtern" PWild) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "rawNodesGo") (EVar "mid")) (EVar "k")) (EVar "rest")) (EVar "acc")))
(DFunDef false "rawNodesGo" ((PVar "mid") (PVar "k") (PCons (PRec "DData" ((rf "dataName" PWild)) false) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "rawNodesGo") (EVar "mid")) (EVar "k")) (EVar "rest")) (EVar "acc")))
(DFunDef false "rawNodesGo" ((PVar "mid") (PVar "k") (PCons (PCon "DUse" PWild PWild PWild) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "rawNodesGo") (EVar "mid")) (EVar "k")) (EVar "rest")) (EVar "acc")))
(DFunDef false "rawNodesGo" ((PVar "mid") (PVar "k") (PCons (PCon "DEffect" PWild PWild PWild PWild PWild PWild) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "rawNodesGo") (EVar "mid")) (EVar "k")) (EVar "rest")) (EVar "acc")))
(DFunDef false "rawNodesGo" ((PVar "mid") (PVar "k") (PCons (PCon "DProp" PWild PWild PWild PWild) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "rawNodesGo") (EVar "mid")) (EVar "k")) (EVar "rest")) (EVar "acc")))
(DFunDef false "rawNodesGo" ((PVar "mid") (PVar "k") (PCons (PCon "DTest" PWild PWild PWild) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "rawNodesGo") (EVar "mid")) (EVar "k")) (EVar "rest")) (EVar "acc")))
(DFunDef false "rawNodesGo" ((PVar "mid") (PVar "k") (PCons (PRec "DInterface" ((rf "ifaceOrigin" PWild)) false) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "rawNodesGo") (EVar "mid")) (EVar "k")) (EVar "rest")) (EVar "acc")))
(DFunDef false "rawNodesGo" ((PVar "mid") (PVar "k") (PCons (PRec "DTypeAlias" ((rf "tyAliasName" PWild)) false) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "rawNodesGo") (EVar "mid")) (EVar "k")) (EVar "rest")) (EVar "acc")))
(DFunDef false "rawNodesGo" ((PVar "mid") (PVar "k") (PCons (PRec "DNewtype" ((rf "newtypeName" PWild)) false) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "rawNodesGo") (EVar "mid")) (EVar "k")) (EVar "rest")) (EVar "acc")))
(DTypeSig false "addClause" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Expr") (TyFun (TyCon "Loc") (TyFun (TyApp (TyCon "List") (TyCon "RawNode")) (TyApp (TyCon "List") (TyCon "RawNode"))))))))
(DFunDef false "addClause" ((PVar "n") (PVar "ps") (PVar "body") PWild (PCons (PVar "prev") (PVar "older"))) (EIf (EBinOp "&&" (EBinOp "==" (EFieldAccess (EVar "prev") "rnodeName") (EVar "n")) (EBinOp "/=" (EFieldAccess (EVar "prev") "rnodeKind") (EVar "ImplNode"))) (EBinOp "::" (ERecordUpdate (EVar "prev") ((fa "rnodeBodies" (EBinOp "++" (EFieldAccess (EVar "prev") "rnodeBodies") (EListLit (ETuple (EVar "ps") (EVar "body"))))))) (EVar "older")) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "addClause" ((PVar "n") (PVar "ps") (PVar "body") (PVar "site") (PVar "acc")) (EBinOp "::" (EApp (EApp (EApp (EVar "bindingNode") (EVar "n")) (EListLit (ETuple (EVar "ps") (EVar "body")))) (EApp (EVar "Some") (EVar "site"))) (EVar "acc")))
(DTypeSig false "bindingNode" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "RawNode")))))
(DFunDef false "bindingNode" ((PVar "n") (PVar "bodies") (PVar "loc")) (ERecordCreate "RawNode" ((fa "rnodeName" (EVar "n")) (fa "rnodeKind" (EVar "FunctionNode")) (fa "rnodeArity" (EMatch (EVar "bodies") (arm (PCons (PTuple (PVar "ps") PWild) PWild) () (EApp (EMethodRef "length") (EVar "ps"))) (arm (PList) () (ELit (LInt 0))))) (fa "rnodeLoc" (EVar "loc")) (fa "rnodeBodies" (EVar "bodies")) (fa "rnodeKey" (ELit (LString ""))) (fa "rnodeOrphan" (EVar "False")))))
(DTypeSig false "declaredIn" (TyFun (TyCon "String") (TyFun (TyCon "TyConOrigin") (TyCon "Bool"))))
(DFunDef false "declaredIn" ((PVar "mid") (PCon "OriginModule" (PVar "m"))) (EBinOp "==" (EVar "m") (EVar "mid")))
(DFunDef false "declaredIn" (PWild PWild) (EVar "False"))
(DTypeSig false "headDeclaredIn" (TyFun (TyCon "String") (TyFun (TyCon "Ty") (TyCon "Bool"))))
(DFunDef false "headDeclaredIn" ((PVar "mid") (PRec "TyCon" ((rf "tyConOrigin" None)) false)) (EApp (EApp (EVar "declaredIn") (EVar "mid")) (EVar "tyConOrigin")))
(DFunDef false "headDeclaredIn" ((PVar "mid") (PCon "TyApp" (PVar "f") PWild)) (EApp (EApp (EVar "headDeclaredIn") (EVar "mid")) (EVar "f")))
(DFunDef false "headDeclaredIn" (PWild (PCon "TyVar" PWild)) (EVar "False"))
(DFunDef false "headDeclaredIn" (PWild (PCon "TyFun" PWild PWild)) (EVar "False"))
(DFunDef false "headDeclaredIn" (PWild (PCon "TyTuple" PWild)) (EVar "False"))
(DFunDef false "headDeclaredIn" ((PVar "mid") (PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EApp (EVar "headDeclaredIn") (EVar "mid")) (EVar "t")))
(DFunDef false "headDeclaredIn" ((PVar "mid") (PCon "TyConstrained" PWild (PVar "t"))) (EApp (EApp (EVar "headDeclaredIn") (EVar "mid")) (EVar "t")))
(DFunDef false "headDeclaredIn" ((PVar "mid") (PCon "TyNamed" PWild (PVar "t") PWild)) (EApp (EApp (EVar "headDeclaredIn") (EVar "mid")) (EVar "t")))
(DFunDef false "headDeclaredIn" ((PVar "mid") (PCon "TyQual" (PVar "t") PWild PWild)) (EApp (EApp (EVar "headDeclaredIn") (EVar "mid")) (EVar "t")))
(DFunDef false "headDeclaredIn" (PWild (PCon "TyRow" PWild PWild PWild)) (EVar "False"))
(DFunDef false "headDeclaredIn" (PWild (PCon "TyAuth" PWild PWild)) (EVar "False"))
(DTypeSig false "localDefaults" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))))))
(DFunDef false "localDefaults" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "localDefaults" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "localDefaults") (EBinOp "::" (EVar "d") (EVar "rest"))) (EVar "acc")))
(DFunDef false "localDefaults" ((PCons (PRec "DInterface" ((rf "name" None) (rf "methods" None) (rf "ifaceOrigin" None)) false) (PVar "rest")) (PVar "acc")) (EBlock (DoLet false false (PVar "bodies") (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "m")) (EMatch (EVar "m") (arm (PCon "IfaceMethod" PWild PWild (PCon "Some" (PCon "MethodDefault" (PVar "ps") (PVar "body"))) PWild) () (EListLit (ETuple (EVar "ps") (EVar "body")))) (arm (PCon "IfaceMethod" PWild PWild (PCon "None") PWild) () (EListLit))))) (EVar "methods"))) (DoExpr (EApp (EApp (EVar "localDefaults") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EApp (EApp (EVar "ifaceIdentity") (EVar "ifaceOrigin")) (EVar "name"))) (EVar "bodies")) (EVar "acc"))))))
(DFunDef false "localDefaults" ((PCons PWild (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "localDefaults") (EVar "rest")) (EVar "acc")))
(DTypeSig false "localMethodNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit")))))
(DFunDef false "localMethodNames" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "localMethodNames" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "localMethodNames") (EBinOp "::" (EVar "d") (EVar "rest"))) (EVar "acc")))
(DFunDef false "localMethodNames" ((PCons (PRec "DInterface" ((rf "methods" None) (rf "ifaceOrigin" PWild)) false) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "localMethodNames") (EVar "rest")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "a") (PVar "m")) (EMatch (EVar "m") (arm (PCon "IfaceMethod" (PVar "n") PWild PWild PWild) () (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (ELit LUnit)) (EVar "a")))))) (EVar "acc")) (EVar "methods"))))
(DFunDef false "localMethodNames" ((PCons PWild (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "localMethodNames") (EVar "rest")) (EVar "acc")))
(DTypeSig true "initGraphOf" (TyFun (TyCon "InitInputs") (TyCon "InitGraph")))
(DFunDef false "initGraphOf" ((PVar "inputs")) (EBlock (DoLet false false (PVar "raw") (EApp (EApp (EMethodRef "map") (EApp (EVar "classify") (EVar "inputs"))) (EApp (EApp (EVar "rawNodes") (EFieldAccess (EVar "inputs") "iiModule")) (EFieldAccess (EVar "inputs") "iiDecls")))) (DoLet false false (PVar "impls") (EApp (EApp (EMethodRef "filter") (ELam ((PVar "n")) (EBinOp "==" (EFieldAccess (EVar "n") "rnodeKind") (EVar "ImplNode")))) (EVar "raw"))) (DoLet false false (PVar "w") (ERecordCreate "InitWalk" ((fa "iwInputs" (EVar "inputs")) (fa "iwTop" (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "n")) (EIf (EBinOp "==" (EFieldAccess (EVar "n") "rnodeKind") (EVar "ImplNode")) (EVar "acc") (EApp (EApp (EApp (EVar "omInsert") (EFieldAccess (EVar "n") "rnodeName")) (EFieldAccess (EVar "n") "rnodeArity")) (EVar "acc"))))) (EVar "omEmpty")) (EVar "raw"))) (fa "iwImpls" (EApp (EApp (EMethodRef "map") (ELam ((PVar "n")) (EFieldAccess (EVar "n") "rnodeName"))) (EVar "impls"))) (fa "iwImplsByKey" (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "n")) (EApp (EApp (EApp (EVar "addSteps") (EFieldAccess (EVar "n") "rnodeKey")) (EListLit (EFieldAccess (EVar "n") "rnodeName"))) (EVar "acc")))) (EVar "omEmpty")) (EApp (EVar "reverseL") (EVar "impls")))) (fa "iwOrphans" (EApp (EApp (EMethodRef "map") (ELam ((PVar "n")) (EFieldAccess (EVar "n") "rnodeName"))) (EApp (EApp (EMethodRef "filter") (ELam ((PVar "n")) (EFieldAccess (EVar "n") "rnodeOrphan"))) (EVar "impls")))) (fa "iwSeedPrefix" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EFieldAccess (EVar "inputs") "iiModule"))) (ELit (LString "__")))) (fa "iwLocalMethods" (EApp (EApp (EVar "localMethodNames") (EFieldAccess (EVar "inputs") "iiDecls")) (EVar "omEmpty")))))) (DoLet false false (PVar "defaults") (EApp (EApp (EVar "localDefaults") (EFieldAccess (EVar "inputs") "iiDecls")) (EVar "omEmpty"))) (DoExpr (ERecordCreate "InitGraph" ((fa "igraphNodes" (EApp (EApp (EApp (EApp (EApp (EVar "walkNodes") (EVar "w")) (EVar "defaults")) (ELit (LInt 0))) (EVar "raw")) (EListLit))) (fa "igraphNotInitialised" (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "n")) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EFieldAccess (EVar "n") "rnodeArity") (ELit (LInt 0))) (EBinOp "/=" (EFieldAccess (EVar "n") "rnodeKind") (EVar "ImplNode"))) (EBinOp "||" (EApp (EApp (EVar "omHasKey") (EFieldAccess (EVar "n") "rnodeName")) (EFieldAccess (EVar "inputs") "iiExempt")) (EApp (EApp (EVar "omHasKey") (EFieldAccess (EVar "n") "rnodeName")) (EFieldAccess (EVar "inputs") "iiConstrained")))) (EApp (EApp (EApp (EVar "omInsert") (EFieldAccess (EVar "n") "rnodeName")) (ELit LUnit)) (EVar "acc")) (EVar "acc")))) (EVar "omEmpty")) (EVar "raw"))))))))
(DTypeSig false "classify" (TyFun (TyCon "InitInputs") (TyFun (TyCon "RawNode") (TyCon "RawNode"))))
(DFunDef false "classify" ((PVar "inputs") (PVar "n")) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EFieldAccess (EVar "n") "rnodeKind") (EVar "FunctionNode")) (EBinOp "==" (EFieldAccess (EVar "n") "rnodeArity") (ELit (LInt 0)))) (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EFieldAccess (EVar "n") "rnodeName")) (EFieldAccess (EVar "inputs") "iiConstrained")))) (ERecordUpdate (EVar "n") ((fa "rnodeKind" (EVar "ValueNode")))) (EVar "n")))
(DTypeSig false "walkNodes" (TyFun (TyCon "InitWalk") (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "RawNode")) (TyFun (TyApp (TyCon "List") (TyCon "InitNode")) (TyApp (TyCon "List") (TyCon "InitNode"))))))))
(DFunDef false "walkNodes" (PWild PWild PWild (PList) (PVar "acc")) (EApp (EVar "reverseL") (EVar "acc")))
(DFunDef false "walkNodes" ((PVar "w") (PVar "defaults") (PVar "k") (PCons (PVar "n") (PVar "rest")) (PVar "acc")) (EBlock (DoLet false false (PVar "own") (EApp (EApp (EApp (EVar "walkBodies") (EVar "w")) (EFieldAccess (EVar "n") "rnodeBodies")) (EListLit))) (DoLet false false (PVar "mentions") (EIf (EBinOp "==" (EFieldAccess (EVar "n") "rnodeKind") (EVar "ImplNode")) (EApp (EApp (EApp (EVar "walkBodies") (EVar "w")) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EFieldAccess (EVar "n") "rnodeKey")) (EVar "defaults")))) (EVar "own")) (EVar "own"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "walkNodes") (EVar "w")) (EVar "defaults")) (EBinOp "+" (EVar "k") (ELit (LInt 1)))) (EVar "rest")) (EBinOp "::" (ERecordCreate "InitNode" ((fa "inodeName" (EFieldAccess (EVar "n") "rnodeName")) (fa "inodeKind" (EFieldAccess (EVar "n") "rnodeKind")) (fa "inodeOrder" (EVar "k")) (fa "inodeLoc" (EFieldAccess (EVar "n") "rnodeLoc")) (fa "inodeMentions" (EApp (EVar "reverseL") (EVar "mentions"))))) (EVar "acc"))))))
(DTypeSig false "walkBodies" (TyFun (TyCon "InitWalk") (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))) (TyFun (TyApp (TyCon "List") (TyCon "InitMention")) (TyApp (TyCon "List") (TyCon "InitMention"))))))
(DFunDef false "walkBodies" ((PVar "w") (PVar "bodies") (PVar "acc")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc2") (PVar "b")) (EMatch (EVar "b") (arm (PTuple (PVar "ps") (PVar "body")) () (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EVar "CtxReturn")) (EApp (EApp (EVar "bindPats") (EVar "ps")) (EVar "omEmpty"))) (EVar "body")) (EVar "acc2")))))) (EVar "acc")) (EVar "bodies")))
(DData Private "WalkCtx" () ((variant "CtxReturn" (ConPos)) (variant "CtxGuard" (ConPos)) (variant "CtxGuardBody" (ConPos)) (variant "CtxDeref" (ConPos)) (variant "CtxDelay" (ConPos))) ())
(DTypeSig false "namePos" (TyFun (TyCon "WalkCtx") (TyCon "InitPosition")))
(DFunDef false "namePos" ((PCon "CtxReturn")) (EVar "AtDeref"))
(DFunDef false "namePos" ((PCon "CtxGuard")) (EVar "AtGuard"))
(DFunDef false "namePos" ((PCon "CtxGuardBody")) (EVar "AtGuard"))
(DFunDef false "namePos" ((PCon "CtxDeref")) (EVar "AtDeref"))
(DFunDef false "namePos" ((PCon "CtxDelay")) (EVar "AtDelay"))
(DTypeSig false "evalCtx" (TyFun (TyCon "WalkCtx") (TyCon "WalkCtx")))
(DFunDef false "evalCtx" ((PCon "CtxReturn")) (EVar "CtxDeref"))
(DFunDef false "evalCtx" ((PCon "CtxGuard")) (EVar "CtxDeref"))
(DFunDef false "evalCtx" ((PCon "CtxGuardBody")) (EVar "CtxGuardBody"))
(DFunDef false "evalCtx" ((PCon "CtxDeref")) (EVar "CtxDeref"))
(DFunDef false "evalCtx" ((PCon "CtxDelay")) (EVar "CtxDelay"))
(DTypeSig false "componentCtx" (TyFun (TyCon "WalkCtx") (TyCon "WalkCtx")))
(DFunDef false "componentCtx" ((PCon "CtxReturn")) (EVar "CtxGuard"))
(DFunDef false "componentCtx" ((PCon "CtxGuard")) (EVar "CtxGuard"))
(DFunDef false "componentCtx" ((PCon "CtxGuardBody")) (EVar "CtxGuardBody"))
(DFunDef false "componentCtx" ((PCon "CtxDeref")) (EVar "CtxDeref"))
(DFunDef false "componentCtx" ((PCon "CtxDelay")) (EVar "CtxDelay"))
(DTypeSig false "lambdaCtx" (TyFun (TyCon "WalkCtx") (TyCon "WalkCtx")))
(DFunDef false "lambdaCtx" ((PCon "CtxReturn")) (EVar "CtxGuardBody"))
(DFunDef false "lambdaCtx" ((PCon "CtxGuard")) (EVar "CtxGuardBody"))
(DFunDef false "lambdaCtx" ((PCon "CtxGuardBody")) (EVar "CtxGuardBody"))
(DFunDef false "lambdaCtx" ((PCon "CtxDeref")) (EVar "CtxDeref"))
(DFunDef false "lambdaCtx" ((PCon "CtxDelay")) (EVar "CtxDelay"))
(DTypeSig false "isGuarded" (TyFun (TyCon "WalkCtx") (TyCon "Bool")))
(DFunDef false "isGuarded" ((PCon "CtxReturn")) (EVar "True"))
(DFunDef false "isGuarded" ((PCon "CtxGuard")) (EVar "True"))
(DFunDef false "isGuarded" ((PCon "CtxGuardBody")) (EVar "False"))
(DFunDef false "isGuarded" ((PCon "CtxDeref")) (EVar "False"))
(DFunDef false "isGuarded" ((PCon "CtxDelay")) (EVar "False"))
(DTypeSig false "walk" (TyFun (TyCon "InitWalk") (TyFun (TyCon "WalkCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "InitMention")) (TyApp (TyCon "List") (TyCon "InitMention"))))))))
(DFunDef false "walk" (PWild PWild PWild (PCon "ELit" PWild) (PVar "acc")) (EVar "acc"))
(DFunDef false "walk" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "EVar" (PVar "n")) (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EVar "nameRef") (EVar "w")) (EVar "ctx")) (EVar "bound")) (EVar "n")) (EVar "acc")))
(DFunDef false "walk" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "EApp" (PVar "f") (PVar "x")) (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EVar "walkApp") (EVar "w")) (EVar "ctx")) (EVar "bound")) (EApp (EApp (EVar "EApp") (EVar "f")) (EVar "x"))) (EVar "acc")))
(DFunDef false "walk" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "ELam" (PVar "ps") (PVar "body")) (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EApp (EVar "lambdaCtx") (EVar "ctx"))) (EApp (EApp (EVar "bindPats") (EVar "ps")) (EVar "bound"))) (EVar "body")) (EVar "acc")))
(DFunDef false "walk" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "ELet" PWild (PVar "r") (PVar "p") (PVar "e1") (PVar "e2")) (PVar "acc")) (EBlock (DoLet false false (PVar "after") (EApp (EApp (EVar "bindPat") (EVar "p")) (EVar "bound"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EVar "ctx")) (EVar "after")) (EVar "e2")) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EApp (EVar "evalCtx") (EVar "ctx"))) (EIf (EVar "r") (EVar "after") (EVar "bound"))) (EVar "e1")) (EVar "acc"))))))
(DFunDef false "walk" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "EMatch" (PVar "e0") (PVar "arms")) (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EVar "walkArms") (EVar "w")) (EVar "ctx")) (EVar "bound")) (EVar "arms")) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EApp (EVar "evalCtx") (EVar "ctx"))) (EVar "bound")) (EVar "e0")) (EVar "acc"))))
(DFunDef false "walk" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "EIf" (PVar "c") (PVar "t") (PVar "e")) (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EVar "ctx")) (EVar "bound")) (EVar "e")) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EVar "ctx")) (EVar "bound")) (EVar "t")) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EApp (EVar "evalCtx") (EVar "ctx"))) (EVar "bound")) (EVar "c")) (EVar "acc")))))
(DFunDef false "walk" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "EBinOp" (PVar "op") (PVar "l") (PVar "r") PWild) (PVar "acc")) (EIf (EBinOp "==" (EVar "op") (ELit (LString "::"))) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EApp (EVar "componentCtx") (EVar "ctx"))) (EVar "bound")) (EVar "r")) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EApp (EVar "componentCtx") (EVar "ctx"))) (EVar "bound")) (EVar "l")) (EVar "acc"))) (EApp (EApp (EApp (EApp (EVar "operatorRef") (EVar "w")) (EVar "ctx")) (EApp (EFieldAccess (EFieldAccess (EVar "w") "iwInputs") "iiBinopMethod") (EVar "op"))) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EApp (EVar "evalCtx") (EVar "ctx"))) (EVar "bound")) (EVar "r")) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EApp (EVar "evalCtx") (EVar "ctx"))) (EVar "bound")) (EVar "l")) (EVar "acc"))))))
(DFunDef false "walk" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "EUnOp" (PVar "op") (PVar "x") PWild) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "operatorRef") (EVar "w")) (EVar "ctx")) (EApp (EFieldAccess (EFieldAccess (EVar "w") "iwInputs") "iiUnopMethod") (EVar "op"))) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EApp (EVar "evalCtx") (EVar "ctx"))) (EVar "bound")) (EVar "x")) (EVar "acc"))))
(DFunDef false "walk" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "EInfix" (PVar "op") (PVar "l") (PVar "r")) (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EVar "nameRef") (EVar "w")) (EApp (EVar "evalCtx") (EVar "ctx"))) (EVar "bound")) (EVar "op")) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EApp (EVar "evalCtx") (EVar "ctx"))) (EVar "bound")) (EVar "r")) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EApp (EVar "evalCtx") (EVar "ctx"))) (EVar "bound")) (EVar "l")) (EVar "acc")))))
(DFunDef false "walk" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "EFieldAccess" (PVar "e0") PWild PWild) (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EApp (EVar "evalCtx") (EVar "ctx"))) (EVar "bound")) (EVar "e0")) (EVar "acc")))
(DFunDef false "walk" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "ETuple" (PVar "es")) (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EVar "walkAll") (EVar "w")) (EApp (EVar "componentCtx") (EVar "ctx"))) (EVar "bound")) (EVar "es")) (EVar "acc")))
(DFunDef false "walk" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "EListLit" (PVar "es")) (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EVar "walkAll") (EVar "w")) (EApp (EVar "componentCtx") (EVar "ctx"))) (EVar "bound")) (EVar "es")) (EVar "acc")))
(DFunDef false "walk" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "EArrayLit" (PVar "es")) (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EVar "walkAll") (EVar "w")) (EApp (EVar "componentCtx") (EVar "ctx"))) (EVar "bound")) (EVar "es")) (EVar "acc")))
(DFunDef false "walk" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "ERangeList" (PVar "a") (PVar "b") PWild) (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EApp (EVar "evalCtx") (EVar "ctx"))) (EVar "bound")) (EVar "b")) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EApp (EVar "evalCtx") (EVar "ctx"))) (EVar "bound")) (EVar "a")) (EVar "acc"))))
(DFunDef false "walk" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "ERangeArray" (PVar "a") (PVar "b") PWild) (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EApp (EVar "evalCtx") (EVar "ctx"))) (EVar "bound")) (EVar "b")) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EApp (EVar "evalCtx") (EVar "ctx"))) (EVar "bound")) (EVar "a")) (EVar "acc"))))
(DFunDef false "walk" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "ESlice" (PVar "a") (PVar "lo") (PVar "hi") PWild) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "sugarMethodRef") (EVar "w")) (EVar "ctx")) (ELit (LString "slice"))) (EApp (EApp (EApp (EApp (EApp (EVar "walkAll") (EVar "w")) (EApp (EVar "evalCtx") (EVar "ctx"))) (EVar "bound")) (EListLit (EVar "a") (EVar "lo") (EVar "hi"))) (EVar "acc"))))
(DFunDef false "walk" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "ELetGroup" (PVar "binds") (PVar "body")) (PVar "acc")) (EBlock (DoLet false false (PVar "inner") (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "b2") (PVar "lb")) (EMatch (EVar "lb") (arm (PCon "LetBind" (PVar "n") PWild PWild PWild) () (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (ELit LUnit)) (EVar "b2")))))) (EVar "bound")) (EVar "binds"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EVar "ctx")) (EVar "inner")) (EVar "body")) (EApp (EApp (EApp (EApp (EApp (EVar "walkLetBinds") (EVar "w")) (EApp (EVar "evalCtx") (EVar "ctx"))) (EVar "inner")) (EVar "binds")) (EVar "acc"))))))
(DFunDef false "walk" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "ESection" (PVar "s")) (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EVar "walkSection") (EVar "w")) (EVar "ctx")) (EVar "bound")) (EVar "s")) (EVar "acc")))
(DFunDef false "walk" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "EIndex" (PVar "a") (PVar "i")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "sugarMethodRef") (EVar "w")) (EVar "ctx")) (ELit (LString "index"))) (EApp (EApp (EApp (EApp (EApp (EVar "walkAll") (EVar "w")) (EApp (EVar "evalCtx") (EVar "ctx"))) (EVar "bound")) (EListLit (EVar "a") (EVar "i"))) (EVar "acc"))))
(DFunDef false "walk" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "EAnnot" (PVar "e0") PWild) (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EVar "ctx")) (EVar "bound")) (EVar "e0")) (EVar "acc")))
(DFunDef false "walk" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "EHeadAnnot" (PVar "e0") PWild) (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EVar "ctx")) (EVar "bound")) (EVar "e0")) (EVar "acc")))
(DFunDef false "walk" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "EBlock" (PVar "stmts")) (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EVar "walkStmts") (EVar "w")) (EVar "ctx")) (EVar "bound")) (EVar "stmts")) (EVar "acc")))
(DFunDef false "walk" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "EDo" (PVar "deferred") (PVar "stmts")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "sugarMethodRef") (EVar "w")) (EVar "ctx")) (EIf (EVar "deferred") (ELit (LString "deferThen")) (ELit (LString "andThen")))) (EApp (EApp (EApp (EApp (EApp (EVar "walkStmts") (EVar "w")) (EApp (EVar "evalCtx") (EVar "ctx"))) (EVar "bound")) (EVar "stmts")) (EVar "acc"))))
(DFunDef false "walk" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "EStringInterp" (PVar "parts")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "sugarMethodRef") (EVar "w")) (EVar "ctx")) (ELit (LString "display"))) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc2") (PVar "p")) (EMatch (EVar "p") (arm (PCon "InterpStr" PWild) () (EVar "acc2")) (arm (PCon "InterpExpr" (PVar "e0")) () (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EApp (EVar "evalCtx") (EVar "ctx"))) (EVar "bound")) (EVar "e0")) (EVar "acc2")))))) (EVar "acc")) (EVar "parts"))))
(DFunDef false "walk" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "EGuards" (PVar "arms")) (PVar "acc")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc2") (PVar "a")) (EMatch (EVar "a") (arm (PCon "GuardArm" (PVar "gs") (PVar "body")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "walkGuarded") (EVar "w")) (EVar "ctx")) (EVar "bound")) (EVar "gs")) (EVar "body")) (EVar "acc2")))))) (EVar "acc")) (EVar "arms")))
(DFunDef false "walk" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "ERecordCreate" PWild (PVar "fs")) (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EVar "walkFields") (EVar "w")) (EApp (EVar "componentCtx") (EVar "ctx"))) (EVar "bound")) (EVar "fs")) (EVar "acc")))
(DFunDef false "walk" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "ERecordUpdate" (PVar "e0") (PVar "fs") PWild) (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EVar "walkFields") (EVar "w")) (EApp (EVar "componentCtx") (EVar "ctx"))) (EVar "bound")) (EVar "fs")) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EApp (EVar "evalCtx") (EVar "ctx"))) (EVar "bound")) (EVar "e0")) (EVar "acc"))))
(DFunDef false "walk" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "EVariantUpdate" PWild (PVar "e0") (PVar "fs")) (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EVar "walkFields") (EVar "w")) (EApp (EVar "componentCtx") (EVar "ctx"))) (EVar "bound")) (EVar "fs")) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EApp (EVar "evalCtx") (EVar "ctx"))) (EVar "bound")) (EVar "e0")) (EVar "acc"))))
(DFunDef false "walk" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "EMapLit" PWild (PVar "kvs")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "sugarMethodRef") (EVar "w")) (EVar "ctx")) (ELit (LString "fromEntries"))) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc2") (PVar "kv")) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EApp (EVar "evalCtx") (EVar "ctx"))) (EVar "bound")) (EApp (EVar "snd") (EVar "kv"))) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EApp (EVar "evalCtx") (EVar "ctx"))) (EVar "bound")) (EApp (EVar "fst") (EVar "kv"))) (EVar "acc2"))))) (EVar "acc")) (EVar "kvs"))))
(DFunDef false "walk" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "ESetLit" PWild (PVar "es")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "sugarMethodRef") (EVar "w")) (EVar "ctx")) (ELit (LString "fromEntries"))) (EApp (EApp (EApp (EApp (EApp (EVar "walkAll") (EVar "w")) (EApp (EVar "evalCtx") (EVar "ctx"))) (EVar "bound")) (EVar "es")) (EVar "acc"))))
(DFunDef false "walk" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "EAsPat" PWild (PVar "e0")) (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EApp (EVar "evalCtx") (EVar "ctx"))) (EVar "bound")) (EVar "e0")) (EVar "acc")))
(DFunDef false "walk" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "EOrPat" (PVar "es")) (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EVar "walkAll") (EVar "w")) (EApp (EVar "evalCtx") (EVar "ctx"))) (EVar "bound")) (EVar "es")) (EVar "acc")))
(DFunDef false "walk" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "EMethodRef" (PVar "n")) (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "methodRef") (EVar "w")) (EVar "ctx")) (EVar "bound")) (EVar "n")) (ELit (LString ""))) (EVar "acc")))
(DFunDef false "walk" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "EDictApp" (PVar "n")) (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EVar "dictRef") (EVar "w")) (EVar "ctx")) (EVar "bound")) (EVar "n")) (EVar "acc")))
(DFunDef false "walk" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "EVarAt" (PVar "n") PWild) (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EVar "nameRef") (EVar "w")) (EVar "ctx")) (EVar "bound")) (EVar "n")) (EVar "acc")))
(DFunDef false "walk" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "EVarId" (PVar "n") PWild) (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EVar "nameRef") (EVar "w")) (EVar "ctx")) (EVar "bound")) (EVar "n")) (EVar "acc")))
(DFunDef false "walk" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "EMethodAt" (PVar "m") (PVar "seed") PWild) (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "methodRef") (EVar "w")) (EVar "ctx")) (EVar "bound")) (EVar "m")) (EVar "seed")) (EVar "acc")))
(DFunDef false "walk" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "EDictAt" (PVar "n") PWild) (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EVar "dictRef") (EVar "w")) (EVar "ctx")) (EVar "bound")) (EVar "n")) (EVar "acc")))
(DFunDef false "walk" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "ELoc" PWild (PVar "e0")) (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EVar "ctx")) (EVar "bound")) (EVar "e0")) (EVar "acc")))
(DFunDef false "walk" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "EDoOrigin" PWild (PVar "e0")) (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EVar "ctx")) (EVar "bound")) (EVar "e0")) (EVar "acc")))
(DFunDef false "walk" ((PVar "w") (PVar "ctx") PWild (PCon "ENumLit" PWild PWild PWild) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "operatorRef") (EVar "w")) (EVar "ctx")) (EApp (EVar "Some") (ELit (LString "fromInt")))) (EVar "acc")))
(DFunDef false "walk" ((PVar "w") (PVar "ctx") PWild (PCon "EWideLit" PWild PWild PWild PWild) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "operatorRef") (EVar "w")) (EVar "ctx")) (EApp (EVar "Some") (ELit (LString "fromInt")))) (EVar "acc")))
(DTypeSig false "walkAll" (TyFun (TyCon "InitWalk") (TyFun (TyCon "WalkCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyFun (TyApp (TyCon "List") (TyCon "InitMention")) (TyApp (TyCon "List") (TyCon "InitMention"))))))))
(DFunDef false "walkAll" ((PVar "w") (PVar "ctx") (PVar "bound") (PVar "es") (PVar "acc")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc2") (PVar "e")) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EVar "ctx")) (EVar "bound")) (EVar "e")) (EVar "acc2")))) (EVar "acc")) (EVar "es")))
(DTypeSig false "walkFields" (TyFun (TyCon "InitWalk") (TyFun (TyCon "WalkCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "FieldAssign")) (TyFun (TyApp (TyCon "List") (TyCon "InitMention")) (TyApp (TyCon "List") (TyCon "InitMention"))))))))
(DFunDef false "walkFields" ((PVar "w") (PVar "ctx") (PVar "bound") (PVar "fs") (PVar "acc")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc2") (PVar "f")) (EMatch (EVar "f") (arm (PCon "FieldAssign" PWild (PVar "e")) () (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EVar "ctx")) (EVar "bound")) (EVar "e")) (EVar "acc2")))))) (EVar "acc")) (EVar "fs")))
(DTypeSig false "walkLetBinds" (TyFun (TyCon "InitWalk") (TyFun (TyCon "WalkCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyFun (TyApp (TyCon "List") (TyCon "InitMention")) (TyApp (TyCon "List") (TyCon "InitMention"))))))))
(DFunDef false "walkLetBinds" ((PVar "w") (PVar "ctx") (PVar "bound") (PVar "binds") (PVar "acc")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc2") (PVar "b")) (EMatch (EVar "b") (arm (PCon "LetBind" PWild (PVar "clauses") PWild PWild) () (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc3") (PVar "c")) (EMatch (EVar "c") (arm (PCon "FunClause" (PVar "ps") (PVar "body")) () (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EVar "ctx")) (EApp (EApp (EVar "bindPats") (EVar "ps")) (EVar "bound"))) (EVar "body")) (EVar "acc3")))))) (EVar "acc2")) (EVar "clauses")))))) (EVar "acc")) (EVar "binds")))
(DTypeSig false "walkArms" (TyFun (TyCon "InitWalk") (TyFun (TyCon "WalkCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "Arm")) (TyFun (TyApp (TyCon "List") (TyCon "InitMention")) (TyApp (TyCon "List") (TyCon "InitMention"))))))))
(DFunDef false "walkArms" ((PVar "w") (PVar "ctx") (PVar "bound") (PVar "arms") (PVar "acc")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc2") (PVar "a")) (EMatch (EVar "a") (arm (PCon "Arm" (PVar "p") (PVar "gs") (PVar "body")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "walkGuarded") (EVar "w")) (EVar "ctx")) (EApp (EApp (EVar "bindPat") (EVar "p")) (EVar "bound"))) (EVar "gs")) (EVar "body")) (EVar "acc2")))))) (EVar "acc")) (EVar "arms")))
(DTypeSig false "walkGuarded" (TyFun (TyCon "InitWalk") (TyFun (TyCon "WalkCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "Guard")) (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "InitMention")) (TyApp (TyCon "List") (TyCon "InitMention")))))))))
(DFunDef false "walkGuarded" ((PVar "w") (PVar "ctx") (PVar "bound") (PList) (PVar "body") (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EVar "ctx")) (EVar "bound")) (EVar "body")) (EVar "acc")))
(DFunDef false "walkGuarded" ((PVar "w") (PVar "ctx") (PVar "bound") (PCons (PCon "GBool" (PVar "e")) (PVar "gs")) (PVar "body") (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "walkGuarded") (EVar "w")) (EVar "ctx")) (EVar "bound")) (EVar "gs")) (EVar "body")) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EApp (EVar "evalCtx") (EVar "ctx"))) (EVar "bound")) (EVar "e")) (EVar "acc"))))
(DFunDef false "walkGuarded" ((PVar "w") (PVar "ctx") (PVar "bound") (PCons (PCon "GBind" (PVar "p") (PVar "e")) (PVar "gs")) (PVar "body") (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "walkGuarded") (EVar "w")) (EVar "ctx")) (EApp (EApp (EVar "bindPat") (EVar "p")) (EVar "bound"))) (EVar "gs")) (EVar "body")) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EApp (EVar "evalCtx") (EVar "ctx"))) (EVar "bound")) (EVar "e")) (EVar "acc"))))
(DTypeSig false "walkStmts" (TyFun (TyCon "InitWalk") (TyFun (TyCon "WalkCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyFun (TyApp (TyCon "List") (TyCon "InitMention")) (TyApp (TyCon "List") (TyCon "InitMention"))))))))
(DFunDef false "walkStmts" (PWild PWild PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "walkStmts" ((PVar "w") (PVar "ctx") (PVar "bound") (PList (PCon "DoExpr" (PVar "e"))) (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EVar "ctx")) (EVar "bound")) (EVar "e")) (EVar "acc")))
(DFunDef false "walkStmts" ((PVar "w") (PVar "ctx") (PVar "bound") (PCons (PCon "DoExpr" (PVar "e")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EVar "walkStmts") (EVar "w")) (EVar "ctx")) (EVar "bound")) (EVar "rest")) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EApp (EVar "evalCtx") (EVar "ctx"))) (EVar "bound")) (EVar "e")) (EVar "acc"))))
(DFunDef false "walkStmts" ((PVar "w") (PVar "ctx") (PVar "bound") (PCons (PCon "DoBind" (PVar "p") (PVar "e")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EVar "walkStmts") (EVar "w")) (EVar "ctx")) (EApp (EApp (EVar "bindPat") (EVar "p")) (EVar "bound"))) (EVar "rest")) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EApp (EVar "evalCtx") (EVar "ctx"))) (EVar "bound")) (EVar "e")) (EVar "acc"))))
(DFunDef false "walkStmts" ((PVar "w") (PVar "ctx") (PVar "bound") (PCons (PCon "DoLet" PWild (PVar "r") (PVar "p") (PVar "e") PWild) (PVar "rest")) (PVar "acc")) (EBlock (DoLet false false (PVar "after") (EApp (EApp (EVar "bindPat") (EVar "p")) (EVar "bound"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "walkStmts") (EVar "w")) (EVar "ctx")) (EVar "after")) (EVar "rest")) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EApp (EVar "evalCtx") (EVar "ctx"))) (EIf (EVar "r") (EVar "after") (EVar "bound"))) (EVar "e")) (EVar "acc"))))))
(DFunDef false "walkStmts" ((PVar "w") (PVar "ctx") (PVar "bound") (PCons (PCon "DoAssign" (PVar "x") (PVar "e")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EVar "walkStmts") (EVar "w")) (EVar "ctx")) (EApp (EApp (EApp (EVar "omInsert") (EVar "x")) (ELit LUnit)) (EVar "bound"))) (EVar "rest")) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EApp (EVar "evalCtx") (EVar "ctx"))) (EVar "bound")) (EVar "e")) (EVar "acc"))))
(DFunDef false "walkStmts" ((PVar "w") (PVar "ctx") (PVar "bound") (PCons (PCon "DoFieldAssign" PWild PWild (PVar "e")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EVar "walkStmts") (EVar "w")) (EVar "ctx")) (EVar "bound")) (EVar "rest")) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EApp (EVar "evalCtx") (EVar "ctx"))) (EVar "bound")) (EVar "e")) (EVar "acc"))))
(DTypeSig false "walkSection" (TyFun (TyCon "InitWalk") (TyFun (TyCon "WalkCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "Section") (TyFun (TyApp (TyCon "List") (TyCon "InitMention")) (TyApp (TyCon "List") (TyCon "InitMention"))))))))
(DFunDef false "walkSection" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "SecBare" (PVar "op")) (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EVar "sectionOp") (EVar "w")) (EVar "ctx")) (EVar "bound")) (EVar "op")) (EVar "acc")))
(DFunDef false "walkSection" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "SecRight" (PVar "op") (PVar "e")) (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EVar "sectionOp") (EVar "w")) (EVar "ctx")) (EVar "bound")) (EVar "op")) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EApp (EVar "evalCtx") (EVar "ctx"))) (EVar "bound")) (EVar "e")) (EVar "acc"))))
(DFunDef false "walkSection" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "SecLeft" (PVar "e") (PVar "op")) (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EVar "sectionOp") (EVar "w")) (EVar "ctx")) (EVar "bound")) (EVar "op")) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EApp (EVar "evalCtx") (EVar "ctx"))) (EVar "bound")) (EVar "e")) (EVar "acc"))))
(DTypeSig false "sectionOp" (TyFun (TyCon "InitWalk") (TyFun (TyCon "WalkCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "InitMention")) (TyApp (TyCon "List") (TyCon "InitMention"))))))))
(DFunDef false "sectionOp" ((PVar "w") (PVar "ctx") (PVar "bound") (PVar "op") (PVar "acc")) (EApp (EApp (EApp (EApp (EApp (EVar "nameRef") (EVar "w")) (EApp (EVar "evalCtx") (EVar "ctx"))) (EVar "bound")) (EVar "op")) (EApp (EApp (EApp (EApp (EVar "operatorRef") (EVar "w")) (EVar "ctx")) (EApp (EFieldAccess (EFieldAccess (EVar "w") "iwInputs") "iiBinopMethod") (EVar "op"))) (EApp (EApp (EApp (EApp (EVar "operatorRef") (EVar "w")) (EVar "ctx")) (EApp (EFieldAccess (EFieldAccess (EVar "w") "iwInputs") "iiUnopMethod") (EVar "op"))) (EVar "acc")))))
(DData Private "AppShape" () ((variant "ShapeCtor" (ConPos)) (variant "ShapePartial" (ConPos)) (variant "ShapeDefer" (ConPos)) (variant "ShapeCall" (ConPos))) ())
(DTypeSig false "spine" (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyTuple (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Expr"))))))
(DFunDef false "spine" ((PCon "EApp" (PVar "f") (PVar "x")) (PVar "args")) (EApp (EApp (EVar "spine") (EVar "f")) (EBinOp "::" (EVar "x") (EVar "args"))))
(DFunDef false "spine" ((PCon "ELoc" PWild (PVar "e")) (PVar "args")) (EApp (EApp (EVar "spine") (EVar "e")) (EVar "args")))
(DFunDef false "spine" ((PCon "EDoOrigin" PWild (PVar "e")) (PVar "args")) (EApp (EApp (EVar "spine") (EVar "e")) (EVar "args")))
(DFunDef false "spine" ((PCon "EHeadAnnot" (PVar "e") PWild) (PVar "args")) (EApp (EApp (EVar "spine") (EVar "e")) (EVar "args")))
(DFunDef false "spine" ((PCon "EAnnot" (PVar "e") PWild) (PVar "args")) (EApp (EApp (EVar "spine") (EVar "e")) (EVar "args")))
(DFunDef false "spine" ((PVar "e") (PVar "args")) (ETuple (EVar "e") (EVar "args")))
(DTypeSig false "walkApp" (TyFun (TyCon "InitWalk") (TyFun (TyCon "WalkCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "InitMention")) (TyApp (TyCon "List") (TyCon "InitMention"))))))))
(DFunDef false "walkApp" ((PVar "w") (PVar "ctx") (PVar "bound") (PVar "e") (PVar "acc")) (EBlock (DoLet false false (PTuple (PVar "hd") (PVar "args")) (EApp (EApp (EVar "spine") (EVar "e")) (EListLit))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "appShape") (EVar "w")) (EVar "ctx")) (EVar "bound")) (EVar "hd")) (EApp (EMethodRef "length") (EVar "args"))) (arm (PCon "ShapeCtor") () (EApp (EApp (EApp (EApp (EApp (EVar "walkAll") (EVar "w")) (EApp (EVar "componentCtx") (EVar "ctx"))) (EVar "bound")) (EVar "args")) (EVar "acc"))) (arm (PCon "ShapePartial") () (EApp (EApp (EApp (EApp (EApp (EVar "walkAll") (EVar "w")) (EApp (EVar "componentCtx") (EVar "ctx"))) (EVar "bound")) (EVar "args")) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EApp (EVar "componentCtx") (EVar "ctx"))) (EVar "bound")) (EVar "hd")) (EVar "acc")))) (arm (PCon "ShapeDefer") () (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc2") (PVar "a")) (EApp (EApp (EApp (EApp (EVar "walkDeferArg") (EVar "w")) (EVar "bound")) (EVar "a")) (EVar "acc2")))) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EApp (EVar "evalCtx") (EVar "ctx"))) (EVar "bound")) (EVar "hd")) (EVar "acc"))) (EVar "args"))) (arm (PCon "ShapeCall") () (EApp (EApp (EApp (EApp (EApp (EVar "walkAll") (EVar "w")) (EApp (EVar "evalCtx") (EVar "ctx"))) (EVar "bound")) (EVar "args")) (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EApp (EVar "evalCtx") (EVar "ctx"))) (EVar "bound")) (EVar "hd")) (EVar "acc"))))))))
(DTypeSig false "walkDeferArg" (TyFun (TyCon "InitWalk") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "InitMention")) (TyApp (TyCon "List") (TyCon "InitMention")))))))
(DFunDef false "walkDeferArg" ((PVar "w") (PVar "bound") (PVar "a") (PVar "acc")) (EMatch (EApp (EVar "directLambda") (EVar "a")) (arm (PCon "Some" (PTuple (PVar "ps") (PVar "body"))) () (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EVar "CtxDelay")) (EApp (EApp (EVar "bindPats") (EVar "ps")) (EVar "bound"))) (EVar "body")) (EVar "acc"))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EVar "walk") (EVar "w")) (EVar "CtxDeref")) (EVar "bound")) (EVar "a")) (EVar "acc")))))
(DTypeSig false "directLambda" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))))
(DFunDef false "directLambda" ((PCon "ELam" (PVar "ps") (PVar "body"))) (EApp (EVar "Some") (ETuple (EVar "ps") (EVar "body"))))
(DFunDef false "directLambda" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "directLambda") (EVar "e")))
(DFunDef false "directLambda" ((PCon "EAnnot" (PVar "e") PWild)) (EApp (EVar "directLambda") (EVar "e")))
(DFunDef false "directLambda" (PWild) (EVar "None"))
(DTypeSig false "appShape" (TyFun (TyCon "InitWalk") (TyFun (TyCon "WalkCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "Expr") (TyFun (TyCon "Int") (TyCon "AppShape")))))))
(DFunDef false "appShape" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "EVar" (PVar "n")) (PVar "nargs")) (EApp (EApp (EApp (EApp (EApp (EVar "nameShape") (EVar "w")) (EVar "ctx")) (EVar "bound")) (EVar "n")) (EVar "nargs")))
(DFunDef false "appShape" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "EVarId" (PVar "n") PWild) (PVar "nargs")) (EApp (EApp (EApp (EApp (EApp (EVar "nameShape") (EVar "w")) (EVar "ctx")) (EVar "bound")) (EVar "n")) (EVar "nargs")))
(DFunDef false "appShape" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "EVarAt" (PVar "n") PWild) (PVar "nargs")) (EApp (EApp (EApp (EApp (EApp (EVar "nameShape") (EVar "w")) (EVar "ctx")) (EVar "bound")) (EVar "n")) (EVar "nargs")))
(DFunDef false "appShape" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "EDictAt" (PVar "n") PWild) (PVar "nargs")) (EApp (EApp (EApp (EApp (EApp (EVar "nameShape") (EVar "w")) (EVar "ctx")) (EVar "bound")) (EVar "n")) (EVar "nargs")))
(DFunDef false "appShape" ((PVar "w") (PVar "ctx") (PVar "bound") (PCon "EMethodAt" (PVar "m") (PLit (LString "")) PWild) PWild) (EIf (EBinOp "&&" (EApp (EVar "isGuarded") (EVar "ctx")) (EApp (EApp (EApp (EVar "isPreludeDefer") (EVar "w")) (EVar "bound")) (EVar "m"))) (EVar "ShapeDefer") (EVar "ShapeCall")))
(DFunDef false "appShape" (PWild PWild PWild PWild PWild) (EVar "ShapeCall"))
(DTypeSig false "nameShape" (TyFun (TyCon "InitWalk") (TyFun (TyCon "WalkCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "AppShape")))))))
(DFunDef false "nameShape" ((PVar "w") (PVar "ctx") (PVar "bound") (PVar "n") (PVar "nargs")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "bound")) (EVar "ShapeCall") (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EFieldAccess (EVar "w") "iwTop")) (arm (PCon "Some" (PVar "arity")) () (EIf (EBinOp "&&" (EApp (EVar "isGuarded") (EVar "ctx")) (EBinOp "<" (EVar "nargs") (EVar "arity"))) (EVar "ShapePartial") (EVar "ShapeCall"))) (arm (PCon "None") () (EIf (EApp (EVar "isCtorName") (EVar "n")) (EVar "ShapeCtor") (EIf (EBinOp "&&" (EApp (EVar "isGuarded") (EVar "ctx")) (EApp (EApp (EApp (EVar "isPreludeDefer") (EVar "w")) (EVar "bound")) (EVar "n"))) (EVar "ShapeDefer") (EVar "ShapeCall"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "isPreludeDefer" (TyFun (TyCon "InitWalk") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "String") (TyCon "Bool")))))
(DFunDef false "isPreludeDefer" ((PVar "w") (PVar "bound") (PVar "n")) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EVar "isDeferSpelling") (EApp (EVar "bareSpelling") (EVar "n"))) (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "bound")))) (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EVar "n")) (EFieldAccess (EVar "w") "iwTop")))) (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EVar "n")) (EFieldAccess (EVar "w") "iwLocalMethods")))) (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EVar "n")) (EFieldAccess (EFieldAccess (EVar "w") "iwInputs") "iiImportedValues")))))
(DTypeSig false "isDeferSpelling" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isDeferSpelling" ((PLit (LString "deferThen"))) (EVar "True"))
(DFunDef false "isDeferSpelling" ((PLit (LString "deferMap"))) (EVar "True"))
(DFunDef false "isDeferSpelling" ((PLit (LString "deferAp"))) (EVar "True"))
(DFunDef false "isDeferSpelling" ((PLit (LString "deferFlatMap"))) (EVar "True"))
(DFunDef false "isDeferSpelling" (PWild) (EVar "False"))
(DTypeSig false "isCtorName" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isCtorName" ((PVar "n")) (EMatch (EApp (EVar "nextChar") (EApp (EVar "startCursor") (EVar "n"))) (arm (PCon "None") () (EVar "False")) (arm (PCon "Some" (PTuple (PVar "c") PWild)) () (EIf (EApp (EVar "not") (EApp (EVar "charIsUpper") (EVar "c"))) (EVar "False") (EMatch (EApp (EApp (EVar "stringIndexOf") (ELit (LString "."))) (EVar "n")) (arm (PCon "None") () (EVar "True")) (arm (PCon "Some" PWild) () (EMatch (EApp (EVar "last") (EApp (EApp (EVar "split") (ELit (LString "."))) (EVar "n"))) (arm (PCon "Some" (PVar "seg")) () (EApp (EVar "isCtorName") (EVar "seg"))) (arm (PCon "None") () (EVar "False")))))))))
(DTypeSig false "bareSpelling" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "bareSpelling" ((PVar "n")) (EApp (EApp (EVar "optionOr") (EVar "n")) (EApp (EApp (EVar "stripPrefix") (ELit (LString "$core."))) (EVar "n"))))
(DTypeSig false "mention" (TyFun (TyCon "String") (TyFun (TyCon "InitEdgeKind") (TyFun (TyCon "InitPosition") (TyCon "InitMention")))))
(DFunDef false "mention" ((PVar "t") (PVar "k") (PVar "p")) (ERecordCreate "InitMention" ((fa "mentionTarget" (EVar "t")) (fa "mentionKind" (EVar "k")) (fa "mentionPosition" (EVar "p")))))
(DTypeSig false "nameRef" (TyFun (TyCon "InitWalk") (TyFun (TyCon "WalkCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "InitMention")) (TyApp (TyCon "List") (TyCon "InitMention"))))))))
(DFunDef false "nameRef" ((PVar "w") (PVar "ctx") (PVar "bound") (PVar "n") (PVar "acc")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "bound")) (EVar "acc") (EIf (EApp (EApp (EVar "omHasKey") (EVar "n")) (EFieldAccess (EVar "w") "iwTop")) (EBinOp "::" (EApp (EApp (EApp (EVar "mention") (EVar "n")) (EVar "ByName")) (EApp (EVar "namePos") (EVar "ctx"))) (EVar "acc")) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "pos") (EApp (EVar "namePos") (EVar "ctx"))) (DoLet false false (PVar "viaMethod") (EMatch (EApp (EApp (EVar "methodKeys") (EVar "w")) (EVar "n")) (arm (PCon "Some" (PVar "keys")) () (EApp (EApp (EApp (EApp (EApp (EVar "dispatchTo") (EVar "w")) (EVar "ByDispatch")) (EVar "pos")) (EVar "keys")) (EVar "acc"))) (arm (PCon "None") () (EVar "acc")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "foreignRef") (EVar "w")) (EVar "pos")) (EVar "n")) (EVar "viaMethod")))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "dictRef" (TyFun (TyCon "InitWalk") (TyFun (TyCon "WalkCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "InitMention")) (TyApp (TyCon "List") (TyCon "InitMention"))))))))
(DFunDef false "dictRef" ((PVar "w") (PVar "ctx") (PVar "bound") (PVar "n") (PVar "acc")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "bound")) (EVar "acc") (EIf (EApp (EApp (EVar "omHasKey") (EVar "n")) (EFieldAccess (EVar "w") "iwTop")) (EBinOp "::" (EApp (EApp (EApp (EVar "mention") (EVar "n")) (EVar "ByName")) (EApp (EVar "namePos") (EVar "ctx"))) (EVar "acc")) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "pos") (EApp (EVar "namePos") (EVar "ctx"))) (DoLet false false (PVar "viaDict") (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EFieldAccess (EFieldAccess (EVar "w") "iwInputs") "iiCalleeIfaces")) (arm (PCon "Some" (PVar "keys")) () (EApp (EApp (EApp (EApp (EApp (EVar "dispatchTo") (EVar "w")) (EVar "ByDispatch")) (EVar "pos")) (EVar "keys")) (EVar "acc"))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "toEvery") (EVar "w")) (EVar "ByDispatch")) (EVar "pos")) (EVar "acc"))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "foreignRef") (EVar "w")) (EVar "pos")) (EVar "n")) (EVar "viaDict")))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "methodRef" (TyFun (TyCon "InitWalk") (TyFun (TyCon "WalkCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "InitMention")) (TyApp (TyCon "List") (TyCon "InitMention")))))))))
(DFunDef false "methodRef" ((PVar "w") (PVar "ctx") (PVar "bound") (PVar "m") (PVar "seed") (PVar "acc")) (EBlock (DoLet false false (PVar "pos") (EApp (EVar "namePos") (EVar "ctx"))) (DoLet false false (PVar "asName") (EIf (EBinOp "&&" (EApp (EApp (EVar "omHasKey") (EVar "m")) (EFieldAccess (EVar "w") "iwTop")) (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EVar "m")) (EVar "bound")))) (EBinOp "::" (EApp (EApp (EApp (EVar "mention") (EVar "m")) (EVar "ByName")) (EVar "pos")) (EVar "acc")) (EVar "acc"))) (DoLet false false (PVar "viaSeed") (EIf (EBinOp "==" (EVar "seed") (ELit (LString ""))) (EVar "asName") (EMatch (EApp (EApp (EVar "stripPrefix") (EFieldAccess (EVar "w") "iwSeedPrefix")) (EVar "seed")) (arm (PCon "Some" (PVar "local")) ((GBool (EApp (EApp (EVar "omHasKey") (EVar "local")) (EFieldAccess (EVar "w") "iwTop")))) (EBinOp "::" (EApp (EApp (EApp (EVar "mention") (EVar "local")) (EVar "ByName")) (EVar "pos")) (EVar "asName"))) (arm PWild () (EApp (EApp (EApp (EApp (EVar "foreignRef") (EVar "w")) (EVar "pos")) (EVar "seed")) (EVar "asName")))))) (DoExpr (EMatch (EApp (EApp (EVar "methodKeys") (EVar "w")) (EVar "m")) (arm (PCon "Some" (PVar "keys")) () (EApp (EApp (EApp (EApp (EApp (EVar "dispatchTo") (EVar "w")) (EVar "ByDispatch")) (EVar "pos")) (EVar "keys")) (EVar "viaSeed"))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "toEvery") (EVar "w")) (EVar "ByDispatch")) (EVar "pos")) (EVar "viaSeed")))))))
(DTypeSig false "sugarMethodRef" (TyFun (TyCon "InitWalk") (TyFun (TyCon "WalkCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "InitMention")) (TyApp (TyCon "List") (TyCon "InitMention")))))))
(DFunDef false "sugarMethodRef" ((PVar "w") (PVar "ctx") (PVar "m") (PVar "acc")) (EMatch (EApp (EApp (EVar "methodKeys") (EVar "w")) (EVar "m")) (arm (PCon "Some" (PVar "keys")) () (EApp (EApp (EApp (EApp (EApp (EVar "dispatchTo") (EVar "w")) (EVar "ByDispatch")) (EApp (EVar "namePos") (EApp (EVar "evalCtx") (EVar "ctx")))) (EVar "keys")) (EVar "acc"))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "toEvery") (EVar "w")) (EVar "ByDispatch")) (EApp (EVar "namePos") (EApp (EVar "evalCtx") (EVar "ctx")))) (EVar "acc")))))
(DTypeSig false "operatorRef" (TyFun (TyCon "InitWalk") (TyFun (TyCon "WalkCtx") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "InitMention")) (TyApp (TyCon "List") (TyCon "InitMention")))))))
(DFunDef false "operatorRef" (PWild PWild (PCon "None") (PVar "acc")) (EVar "acc"))
(DFunDef false "operatorRef" ((PVar "w") (PVar "ctx") (PCon "Some" (PVar "m")) (PVar "acc")) (EMatch (EApp (EApp (EVar "methodKeys") (EVar "w")) (EVar "m")) (arm (PCon "Some" (PVar "keys")) () (EApp (EApp (EApp (EApp (EApp (EVar "dispatchTo") (EVar "w")) (EVar "ByOperator")) (EApp (EVar "namePos") (EApp (EVar "evalCtx") (EVar "ctx")))) (EVar "keys")) (EVar "acc"))) (arm (PCon "None") () (EVar "acc"))))
(DTypeSig false "foreignRef" (TyFun (TyCon "InitWalk") (TyFun (TyCon "InitPosition") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "InitMention")) (TyApp (TyCon "List") (TyCon "InitMention")))))))
(DFunDef false "foreignRef" ((PVar "w") (PVar "pos") (PVar "n") (PVar "acc")) (EIf (EBinOp "||" (EApp (EVar "isEmptyL") (EFieldAccess (EVar "w") "iwOrphans")) (EApp (EVar "isCtorName") (EVar "n"))) (EVar "acc") (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc2") (PVar "o")) (EBinOp "::" (EApp (EApp (EApp (EVar "mention") (EVar "o")) (EVar "ByOrphan")) (EVar "pos")) (EVar "acc2")))) (EVar "acc")) (EFieldAccess (EVar "w") "iwOrphans"))))
(DTypeSig false "methodKeys" (TyFun (TyCon "InitWalk") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "methodKeys" ((PVar "w") (PVar "n")) (EBlock (DoLet false false (PVar "table") (EFieldAccess (EFieldAccess (EVar "w") "iwInputs") "iiMethodIfaces")) (DoLet false false (PVar "bare") (EApp (EVar "bareSpelling") (EVar "n"))) (DoExpr (EMatch (EApp (EApp (EVar "omLookup") (EVar "bare")) (EVar "table")) (arm (PCon "Some" (PVar "keys")) () (EApp (EVar "Some") (EVar "keys"))) (arm (PCon "None") () (EMatch (EApp (EVar "last") (EApp (EApp (EVar "split") (ELit (LString "."))) (EVar "bare"))) (arm (PCon "Some" (PVar "seg")) ((GBool (EBinOp "/=" (EVar "seg") (EVar "bare")))) (EApp (EApp (EVar "omLookup") (EVar "seg")) (EVar "table"))) (arm PWild () (EVar "None"))))))))
(DTypeSig false "dispatchTo" (TyFun (TyCon "InitWalk") (TyFun (TyCon "InitEdgeKind") (TyFun (TyCon "InitPosition") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "InitMention")) (TyApp (TyCon "List") (TyCon "InitMention"))))))))
(DFunDef false "dispatchTo" ((PVar "w") (PVar "kind") (PVar "pos") (PVar "keys") (PVar "acc")) (EIf (EApp (EVar "isEmptyL") (EFieldAccess (EVar "w") "iwImpls")) (EVar "acc") (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc2") (PVar "key")) (EApp (EApp (EApp (EApp (EApp (EVar "dispatchKey") (EVar "w")) (EVar "kind")) (EVar "pos")) (EVar "key")) (EVar "acc2")))) (EVar "acc")) (EVar "keys"))))
(DTypeSig false "dispatchKey" (TyFun (TyCon "InitWalk") (TyFun (TyCon "InitEdgeKind") (TyFun (TyCon "InitPosition") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "InitMention")) (TyApp (TyCon "List") (TyCon "InitMention"))))))))
(DFunDef false "dispatchKey" ((PVar "w") (PVar "kind") (PVar "pos") (PVar "key") (PVar "acc")) (EIf (EBinOp "==" (EVar "key") (ELit (LString ""))) (EApp (EApp (EApp (EApp (EVar "toEvery") (EVar "w")) (EVar "kind")) (EVar "pos")) (EVar "acc")) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "closure") (EApp (EApp (EVar "optionOr") (EListLit (EVar "key"))) (EApp (EApp (EVar "omLookup") (EVar "key")) (EFieldAccess (EFieldAccess (EVar "w") "iwInputs") "iiDispatchClosure")))) (DoExpr (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc2") (PVar "k")) (EIf (EBinOp "==" (EVar "k") (ELit (LString ""))) (EApp (EApp (EApp (EApp (EVar "toEvery") (EVar "w")) (EVar "kind")) (EVar "pos")) (EVar "acc2")) (EApp (EApp (EApp (EApp (EVar "toImpls") (EIf (EBinOp "==" (EVar "k") (EVar "key")) (EVar "kind") (EVar "ByClosure"))) (EVar "pos")) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "k")) (EFieldAccess (EVar "w") "iwImplsByKey")))) (EVar "acc2"))))) (EApp (EApp (EApp (EApp (EVar "toImpls") (EVar "kind")) (EVar "pos")) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (ELit (LString ""))) (EFieldAccess (EVar "w") "iwImplsByKey")))) (EVar "acc"))) (EVar "closure")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "toEvery" (TyFun (TyCon "InitWalk") (TyFun (TyCon "InitEdgeKind") (TyFun (TyCon "InitPosition") (TyFun (TyApp (TyCon "List") (TyCon "InitMention")) (TyApp (TyCon "List") (TyCon "InitMention")))))))
(DFunDef false "toEvery" ((PVar "w") (PVar "kind") (PVar "pos") (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "toImpls") (EVar "kind")) (EVar "pos")) (EFieldAccess (EVar "w") "iwImpls")) (EVar "acc")))
(DTypeSig false "toImpls" (TyFun (TyCon "InitEdgeKind") (TyFun (TyCon "InitPosition") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "InitMention")) (TyApp (TyCon "List") (TyCon "InitMention")))))))
(DFunDef false "toImpls" ((PVar "kind") (PVar "pos") (PVar "impls") (PVar "acc")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc2") (PVar "i")) (EBinOp "::" (EApp (EApp (EApp (EVar "mention") (EVar "i")) (EVar "kind")) (EVar "pos")) (EVar "acc2")))) (EVar "acc")) (EVar "impls")))
(DTypeSig false "bindPats" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit")))))
(DFunDef false "bindPats" ((PVar "ps") (PVar "bound")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "b") (PVar "p")) (EApp (EApp (EVar "bindPat") (EVar "p")) (EVar "b")))) (EVar "bound")) (EVar "ps")))
(DTypeSig false "bindPat" (TyFun (TyCon "Pat") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit")))))
(DFunDef false "bindPat" ((PCon "PVar" (PVar "n") PWild PWild) (PVar "bound")) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (ELit LUnit)) (EVar "bound")))
(DFunDef false "bindPat" ((PCon "PWild") (PVar "bound")) (EVar "bound"))
(DFunDef false "bindPat" ((PCon "PLit" PWild) (PVar "bound")) (EVar "bound"))
(DFunDef false "bindPat" ((PCon "PCon" PWild (PVar "ps")) (PVar "bound")) (EApp (EApp (EVar "bindPats") (EVar "ps")) (EVar "bound")))
(DFunDef false "bindPat" ((PCon "PCons" (PVar "h") (PVar "t")) (PVar "bound")) (EApp (EApp (EVar "bindPat") (EVar "t")) (EApp (EApp (EVar "bindPat") (EVar "h")) (EVar "bound"))))
(DFunDef false "bindPat" ((PCon "PTuple" (PVar "ps")) (PVar "bound")) (EApp (EApp (EVar "bindPats") (EVar "ps")) (EVar "bound")))
(DFunDef false "bindPat" ((PCon "PList" (PVar "ps")) (PVar "bound")) (EApp (EApp (EVar "bindPats") (EVar "ps")) (EVar "bound")))
(DFunDef false "bindPat" ((PCon "PAs" (PVar "n") PWild PWild (PVar "p")) (PVar "bound")) (EApp (EApp (EVar "bindPat") (EVar "p")) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (ELit LUnit)) (EVar "bound"))))
(DFunDef false "bindPat" ((PCon "POr" (PVar "ps")) (PVar "bound")) (EApp (EApp (EVar "bindPats") (EVar "ps")) (EVar "bound")))
(DFunDef false "bindPat" ((PCon "PRng" PWild PWild PWild) (PVar "bound")) (EVar "bound"))
(DFunDef false "bindPat" ((PCon "PRec" PWild (PVar "fields") PWild) (PVar "bound")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "b") (PVar "f")) (EMatch (EVar "f") (arm (PCon "RecPatField" (PVar "n") PWild PWild (PCon "None")) () (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (ELit LUnit)) (EVar "b"))) (arm (PCon "RecPatField" PWild PWild PWild (PCon "Some" (PVar "p"))) () (EApp (EApp (EVar "bindPat") (EVar "p")) (EVar "b")))))) (EVar "bound")) (EVar "fields")))
(DFunDef false "bindPat" ((PCon "PAnn" (PVar "p") PWild) (PVar "bound")) (EApp (EApp (EVar "bindPat") (EVar "p")) (EVar "bound")))
(DTypeSig true "initOrder" (TyFun (TyCon "InitGraph") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "initOrder" ((PVar "g")) (EBlock (DoLet false false (PVar "nodes") (EFieldAccess (EVar "g") "igraphNodes")) (DoLet false false (PVar "adj") (EApp (EApp (EVar "omFromPairs") (EApp (EApp (EMethodRef "map") (ELam ((PVar "n")) (ETuple (EFieldAccess (EVar "n") "inodeName") (EApp (EApp (EMethodRef "map") (ELam ((PVar "m")) (EFieldAccess (EVar "m") "mentionTarget"))) (EFieldAccess (EVar "n") "inodeMentions"))))) (EVar "nodes"))) (EVar "omEmpty"))) (DoLet false false (PVar "sccs") (EApp (EApp (EVar "tarjanSCCs") (EApp (EApp (EMethodRef "map") (ELam ((PVar "n")) (EFieldAccess (EVar "n") "inodeName"))) (EVar "nodes"))) (EVar "adj"))) (DoLet false false (PVar "compOf") (EApp (EApp (EApp (EVar "componentIndex") (EVar "sccs")) (ELit (LInt 0))) (EVar "omEmpty"))) (DoLet false false (PVar "members") (EApp (EApp (EApp (EVar "componentMembers") (EVar "compOf")) (EApp (EVar "reverseL") (EVar "nodes"))) (EMethodRef "empty"))) (DoLet false false (PVar "deps") (EApp (EApp (EApp (EVar "componentDeps") (EVar "compOf")) (EVar "nodes")) (EMethodRef "empty"))) (DoLet false false (PVar "indegree") (EApp (EApp (EVar "M.mapWithKey") (ELam (PWild (PVar "ds")) (EApp (EVar "M.size") (EVar "ds")))) (EVar "deps"))) (DoLet false false (PVar "dependents") (EApp (EApp (EApp (EVar "M.foldrWithKey") (ELam ((PVar "s") (PVar "ds") (PVar "acc")) (EApp (EApp (EApp (EVar "M.foldrWithKey") (ELam ((PVar "d") PWild (PVar "acc2")) (EApp (EApp (EApp (EVar "M.set") (EVar "d")) (EBinOp "::" (EVar "s") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "M.get") (EVar "d")) (EVar "acc2"))))) (EVar "acc2")))) (EVar "acc")) (EVar "ds")))) (EMethodRef "empty")) (EVar "deps"))) (DoLet false false (PVar "ready") (EApp (EApp (EApp (EVar "M.foldrWithKey") (ELam ((PVar "s") (PVar "ms") (PVar "acc")) (EIf (EBinOp "==" (EApp (EApp (EVar "optionOr") (ELit (LInt 0))) (EApp (EApp (EVar "M.get") (EVar "s")) (EVar "indegree"))) (ELit (LInt 0))) (EApp (EApp (EApp (EVar "M.set") (EApp (EVar "firstOrder") (EVar "ms"))) (EVar "s")) (EVar "acc")) (EVar "acc")))) (EMethodRef "empty")) (EVar "members"))) (DoExpr (EApp (EVar "reverseL") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "kahn") (EVar "g")) (EVar "members")) (EVar "dependents")) (EVar "indegree")) (EVar "ready")) (EListLit))))))
(DTypeSig false "componentIndex" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyApp (TyCon "OrdMap") (TyCon "Int"))))))
(DFunDef false "componentIndex" ((PList) PWild (PVar "acc")) (EVar "acc"))
(DFunDef false "componentIndex" ((PCons (PVar "c") (PVar "rest")) (PVar "i") (PVar "acc")) (EApp (EApp (EApp (EVar "componentIndex") (EVar "rest")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "a") (PVar "n")) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (EVar "i")) (EVar "a")))) (EVar "acc")) (EVar "c"))))
(DTypeSig false "componentMembers" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "InitNode")) (TyFun (TyApp (TyApp (TyCon "M.Map") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "InitNode"))) (TyApp (TyApp (TyCon "M.Map") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "InitNode")))))))
(DFunDef false "componentMembers" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "componentMembers" ((PVar "compOf") (PCons (PVar "n") (PVar "rest")) (PVar "acc")) (EBlock (DoLet false false (PVar "c") (EApp (EApp (EVar "optionOr") (ELit (LInt 0))) (EApp (EApp (EVar "omLookup") (EFieldAccess (EVar "n") "inodeName")) (EVar "compOf")))) (DoExpr (EApp (EApp (EApp (EVar "componentMembers") (EVar "compOf")) (EVar "rest")) (EApp (EApp (EApp (EVar "M.set") (EVar "c")) (EBinOp "::" (EVar "n") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "M.get") (EVar "c")) (EVar "acc"))))) (EVar "acc"))))))
(DTypeSig false "componentDeps" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "InitNode")) (TyFun (TyApp (TyApp (TyCon "M.Map") (TyCon "Int")) (TyApp (TyApp (TyCon "M.Map") (TyCon "Int")) (TyCon "Unit"))) (TyApp (TyApp (TyCon "M.Map") (TyCon "Int")) (TyApp (TyApp (TyCon "M.Map") (TyCon "Int")) (TyCon "Unit")))))))
(DFunDef false "componentDeps" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "componentDeps" ((PVar "compOf") (PCons (PVar "n") (PVar "rest")) (PVar "acc")) (EBlock (DoLet false false (PVar "c") (EApp (EApp (EVar "optionOr") (ELit (LInt 0))) (EApp (EApp (EVar "omLookup") (EFieldAccess (EVar "n") "inodeName")) (EVar "compOf")))) (DoLet false false (PVar "mine") (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "s") (PVar "m")) (EMatch (EApp (EApp (EVar "omLookup") (EFieldAccess (EVar "m") "mentionTarget")) (EVar "compOf")) (arm (PCon "Some" (PVar "d")) () (EIf (EBinOp "==" (EVar "d") (EVar "c")) (EVar "s") (EApp (EApp (EApp (EVar "M.set") (EVar "d")) (ELit LUnit)) (EVar "s")))) (arm (PCon "None") () (EVar "s"))))) (EApp (EApp (EVar "optionOr") (EMethodRef "empty")) (EApp (EApp (EVar "M.get") (EVar "c")) (EVar "acc")))) (EFieldAccess (EVar "n") "inodeMentions"))) (DoExpr (EApp (EApp (EApp (EVar "componentDeps") (EVar "compOf")) (EVar "rest")) (EApp (EApp (EApp (EVar "M.set") (EVar "c")) (EVar "mine")) (EVar "acc"))))))
(DTypeSig false "firstOrder" (TyFun (TyApp (TyCon "List") (TyCon "InitNode")) (TyCon "Int")))
(DFunDef false "firstOrder" ((PList)) (ELit (LInt 0)))
(DFunDef false "firstOrder" ((PCons (PVar "n") PWild)) (EFieldAccess (EVar "n") "inodeOrder"))
(DTypeSig false "kahn" (TyFun (TyCon "InitGraph") (TyFun (TyApp (TyApp (TyCon "M.Map") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "InitNode"))) (TyFun (TyApp (TyApp (TyCon "M.Map") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int"))) (TyFun (TyApp (TyApp (TyCon "M.Map") (TyCon "Int")) (TyCon "Int")) (TyFun (TyApp (TyApp (TyCon "M.Map") (TyCon "Int")) (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))))
(DFunDef false "kahn" ((PVar "g") (PVar "members") (PVar "dependents") (PVar "indegree") (PVar "ready") (PVar "out")) (EMatch (EApp (EVar "M.minView") (EVar "ready")) (arm (PCon "None") () (EVar "out")) (arm (PCon "Some" (PTuple PWild (PVar "s") (PVar "rest"))) () (EBlock (DoLet false false (PVar "ms") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "M.get") (EVar "s")) (EVar "members")))) (DoLet false false (PVar "out2") (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "n")) (EIf (EBinOp "&&" (EBinOp "==" (EFieldAccess (EVar "n") "inodeKind") (EVar "ValueNode")) (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EFieldAccess (EVar "n") "inodeName")) (EFieldAccess (EVar "g") "igraphNotInitialised")))) (EBinOp "::" (EFieldAccess (EVar "n") "inodeName") (EVar "acc")) (EVar "acc")))) (EVar "out")) (EVar "ms"))) (DoLet false false (PTuple (PVar "indegree2") (PVar "ready2")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "st") (PVar "d")) (EMatch (EVar "st") (arm (PTuple (PVar "deg") (PVar "rdy")) () (EBlock (DoLet false false (PVar "left") (EBinOp "-" (EApp (EApp (EVar "optionOr") (ELit (LInt 0))) (EApp (EApp (EVar "M.get") (EVar "d")) (EVar "deg"))) (ELit (LInt 1)))) (DoLet false false (PVar "deg2") (EApp (EApp (EApp (EVar "M.set") (EVar "d")) (EVar "left")) (EVar "deg"))) (DoExpr (EIf (EBinOp "==" (EVar "left") (ELit (LInt 0))) (ETuple (EVar "deg2") (EApp (EApp (EApp (EVar "M.set") (EApp (EVar "firstOrder") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "M.get") (EVar "d")) (EVar "members"))))) (EVar "d")) (EVar "rdy"))) (ETuple (EVar "deg2") (EVar "rdy"))))))))) (ETuple (EVar "indegree") (EVar "rest"))) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "M.get") (EVar "s")) (EVar "dependents"))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "kahn") (EVar "g")) (EVar "members")) (EVar "dependents")) (EVar "indegree2")) (EVar "ready2")) (EVar "out2")))))))
