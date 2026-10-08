# META
source_lines=3125
stages=DESUGAR,MARK
# SOURCE
-- elaborated-AST → Core IR lowering (STAGE2-DESIGN §2.1).  Consumes the SAME
-- desugared (and, on the typed path, marked + route-stamped) AST the tree-walker
-- consumes, and produces `core_ir.mdk`'s backend-neutral IR.
--
-- The lowering is where the surface→primitive collapse happens (see core_ir.mdk
-- header): `&&`/`||` become short-circuiting `CIf`, `|>` becomes `CApp`, the
-- composition operators become explicit `CLam`s, type annotations are erased,
-- and the typechecker's mutable dispatch `Ref Route` cells are *read out* into
-- immutable `CMethod`/`CDict` nodes.  Everything else is a structural one-to-one
-- map (the IR deliberately stays close to the core AST so the equivalence gate
-- is a clean diff, not a rewrite).

import frontend.ast.{
  Lit(..),
  Loc(..),
  noDeclLoc,
  Pat(..),
  RecPatField(..),
  Expr(..),
  Arm(..),
  Guard(..),
  DoStmt(..),
  FieldAssign(..),
  LetBind(..),
  FunClause(..),
  Addr(..),
  Decl(..),
  Variant(..),
  ConPayload(..),
  Field(..),
  Ty(..),
  Constraint(..),
  IfaceMethod(..),
  MethodDefault(..),
  ImplMethod(..),
  Route(..),
  TyConOrigin,
  ifaceIdentity,
  defaultReceiverDict,
}
-- B-2.2-e: the ONE route-word mint.  There is no `eval.eval.implKeyOf` mirror:
-- both sides of the dict-word seam call `route_key.implRouteKeyWord` with the
-- impl's own `implOrigin`.
import types.route_key.{
  implRouteKeyWord, ifaceWordOf, evDictRoutes, evMethodRoutes
}
import ir.core_ir.{
  CExpr(..),
  CArm(..),
  CGuard(..),
  CStmt(..),
  CField(..),
  CBind(..),
  CClause(..),
  CImplEntry(..),
  CImplBody(..),
  CProgram(..),
  CTree(..),
  CTBranch(..),
  CHead(..),
  FailSite(..),
  siteSentinelName,
}
import frontend.desugar.{mapProg}
import frontend.marker.{localBoundNames}
import types.disposition.{
  DispositionTable,
  InstanceShape(..),
  ifaceSuperCount,
  inheritorsOf,
  installedDispositions,
  installedDispositionsOpt,
}
import eval.eval.{
  buildCtorToType,
  installDispatchTables,
  lookupPositions,
  tyvarsInArgs,
  headTyconHead,
  exprStartLoc,
}
import list.{replicate, take, drop, range}
import support.ordmap.{OrdMap, omEmpty, omInsert, omHasKey, omLookup}
-- `hashName`/`dictTag` are the two dict-witness tag mints, imported (not copied)
-- so `dictWitnessTagGuard` checks the tag space the backends actually emit.
import backend.private_mangle.{dictTag, hashName, injectiveIdent}
import support.util.{
  contains,
  listLen,
  allList,
  anyList,
  lookupAssoc,
  noneHeadTag,
  isEmptyL,
  isNonEmptyL,
  joinWith,
  reverseL,
  startsWith,
  dedupBy,
  lenKey,
  splitOnChar,
}

-- a synthetic binder for the lowered composition operators; constructed
-- directly (never parsed) so the unusual name is harmless.
composeVar : String
composeVar = "$cf"

-- ── expressions ────────────────────────────────────────────────────────────
-- The published answer for a method occurrence, as the IR node carries it.
cmethodOf : String -> (String, Int, Route, List Route, List Route) -> CExpr
cmethodOf name (iface, arity, route, implRoutes, methodRoutes) =
  CMethod name iface arity route implRoutes methodRoutes

lower : Expr -> CExpr
lower (ELit l) = CLit l
-- PLAN.md #11: dictPass rewrites every ENumLit to ELit before lowering; this
-- arm is defensive (a non-rewritten path) — a Float-stamped ref lowers to a
-- float constant, else an int.
lower (ENumLit n r _ _) = match !r
  Some f => CLit (LFloat f)
  None => CLit (LInt n)
-- defensive like the `ENumLit` arm: dictPass rewrites a wide literal to `LU64`.
lower (EWideLit hi lo _ _) = CLit (LU64 hi lo)
lower (EVar x) = CVar x AGlobal
-- #837: strip the resolve-only binding-id tag; lower exactly as bare EVar.
lower (EVarId x _) = CVar x AGlobal
lower (EVarAt x addr) = CVar x addr
lower (EApp f x) = CApp (lower f) (lower x)
lower (ELam pats body) = CLam pats (lower body)
lower (ELet site False pat e1 e2)
  | patMayFail pat = letDecision site pat (lower e1) (lower e2)
lower (ELet _ recFlag pat e1 e2) = CLet recFlag pat (lower e1) (lower e2)
lower (ELetGroup binds body) = CLetGroup (map lowerBind binds) (lower body)
lower (EMatch scrut arms) = lowerMatch noDeclLoc (lower scrut) arms
lower (EIf c t e) = CIf (lower c) (lower t) (lower e)
lower (EBinOp op l r route) = lowerBinop op l r (scalarTagOfRoute !route)
lower (EInfix op l r) = CApp (CApp (CVar op AGlobal) (lower l)) (lower r)
-- #1739 half A: `!x` lowers to the SAME Core IR node `x.value` does, rather than a
-- `CUnOp "!"` both backends would then need a new arm for.  `CFieldAccess _ "value"`
-- already carries Ref-read end-to-end (core_ir_eval, llvm_emit, wasm_emit), so the
-- repurpose costs zero emitter work — and cannot make the two spellings diverge.
-- The empty record-name stamp matches what `EFieldAccess e "value"` lowers with:
-- `inferValueField` never stamps the ref, because a Ref is not a record.
lower (EUnOp "!" e _) = CFieldAccess (lower e) "value" ""
lower (EUnOp op e _) = CUnOp op (lower e)
lower (ETuple es) = CTuple (map lower es)
lower (EListLit es) = CList (map lower es)
lower (EArrayLit es) = CArray (map lower es)
lower (ERangeList lo hi incl) = CRangeList (lower lo) (lower hi) incl
lower (ERangeArray lo hi incl) = CRangeArray (lower lo) (lower hi) incl
lower (EIndex a i r) =
  if !r == "String" then
    CStringIndex (lower a) (lower i)
  else if !r == "List" then
    CListIndex (lower a) (lower i)
  else
    CIndex (lower a) (lower i)
lower (ESlice a lo hi incl r) =
  if !r == "String" then
    CStringSlice (lower a) (lower lo) (lower hi) incl
  else if !r == "List" then
    CListSlice (lower a) (lower lo) (lower hi) incl
  else
    CSlice (lower a) (lower lo) (lower hi) incl
lower (EFieldAccess e f r) = CFieldAccess (lower e) f !r
lower (ERecordCreate name fields) = CRecord name (map lowerField fields)
lower (ERecordUpdate base fields r) =
  CRecordUpdate !r (lower base) (map lowerField fields)
lower (EVariantUpdate con base fields) =
  CVariantUpdate con (lower base) (map lowerField fields)
lower (EBlock stmts) = CBlock (lowerStmts stmts)
-- SHARED-FLOAT-RESIDUAL §3(C): dictPass wraps a scalar-tagged binop (arithmetic
-- "Float" or comparison "Int") in `EAnnot (EBinOp …) (TyCon tag)` (the ref-cell
-- route does not survive to here, a node does).  Read the tag into CBinPrim's
-- scalar field so the emitter picks that type's primitive.  Must precede the
-- transparent `EAnnot e _` strip below.
lower (EAnnot (EBinOp op l r _) (TyCon { tyConName = tag })) =
  lowerBinop op l r tag
lower (EAnnot e _) = lower e
lower (EHeadAnnot e _) = lower e
-- dispatch: read the typechecker-filled route — `EMethodAt` still out of its
-- mutable cell, `EDictAt` out of the published evidence table — making it
-- structural + immutable in the IR (slice 5; present so the lowering is total).
-- (instance-`requires` impl dicts — the second ref — are unsupported in the Core
-- IR experiment; drop them, the core_ir fixtures carry no requires-impls)
-- #2705: the occurrence's answer is read from the published evidence table, the
-- same seam `EDictAt` crosses on the next line.
lower (EMethodAt name _ ev) = cmethodOf name (evMethodRoutes ev)
lower (EDictAt name ev) = CDict name (evDictRoutes ev)
-- A located `match` keeps its keyword's span as the trap site of the decision
-- it lowers to, the span the interpreter reports (`eval`'s `ELoc l (EMatch …)`
-- arm); a refutable `let` takes its own site field (the `ELet` arm above).
-- Every other ELoc is stripped: no location wrapper reaches the Core IR, and
-- only the trap fields carry one.
lower (ELoc l (EMatch scrut arms)) = lowerMatch l (lower scrut) arms
lower (ELoc _ e) = lower e
lower (EDoOrigin _ e) = lower e
lower other = panic ("core_ir lower: unsupported node " ++ nodeTag other)

-- surface binops that are really sugar are lowered to primitive control flow /
-- application here; only the genuinely-primitive ops survive as CBinPrim.
-- the scalar-type tag carried on an EBinOp's route: "Float" for a stamped
-- monomorphic arithmetic operand, "Int" for a stamped monomorphic comparison
-- operand, "" otherwise.  Only RScalar carries it; every dispatch route
-- (RKey/RDict/…) means "unstamped".
scalarTagOfRoute : Route -> String
scalarTagOfRoute (RScalar s) = s
scalarTagOfRoute _ = ""

lowerBinop : String -> Expr -> Expr -> String -> CExpr
lowerBinop "&&" l r _ = CIf (lower l) (lower r) (CLit (LBool False))
lowerBinop "||" l r _ = CIf (lower l) (CLit (LBool True)) (lower r)
lowerBinop "|>" l r _ = CApp (lower r) (lower l)
lowerBinop ">>" l r _ = composeLam (lower l) (lower r)
lowerBinop "<<" l r _ = composeLam (lower r) (lower l)
lowerBinop op l r tag = CBinPrim op (lower l) (lower r) tag (exprStartLoc l)

-- (f >> g) ≡ \x -> g (f x).  composeLam first second ≡ \x -> second (first x).
composeLam : CExpr -> CExpr -> CExpr
composeLam first second =
  CLam
    [PVar composeVar (Loc "" 0 0 0 0)]
    (CApp second (CApp first (CVar composeVar AGlobal)))

lowerArm : Arm -> CArm
lowerArm (Arm pat guards body) = CArm pat (map lowerGuard guards) (lower body)

lowerGuard : Guard -> CGuard
lowerGuard (GBool e) = CGBool (lower e)
lowerGuard (GBind p e) = CGBind p (lower e)

-- ── decision-tree match compilation (§2.1) ─────────────────────────────────
-- Compile a `match`'s ordered arms into a CDecision (decision tree) when every
-- arm pattern is tree-able; otherwise emit the ordered-arm CMatch unchanged.
-- The fall-back keeps the proven ordered path for record/range patterns the
-- tree compiler doesn't model — correctness first, the tree captures the win on
-- the constructor/list/tuple/literal matches that dominate the lexer + parser.
-- [site] is the `match` keyword's span, which a miss reports.
lowerMatch : Loc -> CExpr -> List Arm -> CExpr
lowerMatch site cscrut arms
  | allList armTreeable arms =
    CDecision cscrut (map lowerArm arms) (compileArms (NoArm site) arms)
  | otherwise = CMatch cscrut (map lowerArm arms)

-- A non-recursive `let` whose pattern can miss lowers to a one-arm decision whose
-- miss is E-LET-REFUTE at [site], so a backend tests the whole pattern, nested
-- fields included, through the match machinery.  `refoldLets` turns it back into
-- the plain `CLet` for every lowering that does not use that check.
letDecision : Loc -> Pat -> CExpr -> CExpr -> CExpr
letDecision site pat scrut body =
  let arms = [CArm pat [] body]
  CDecision scrut arms (compileArmsC (LetRefuted site) arms)

-- Whether a `let` pattern can fail to match, judged by its shape alone: any
-- constructor, list or literal (other than `()`) in it.  A tuple of variables
-- cannot, and keeps the plain `CLet`.
patMayFail : Pat -> Bool
patMayFail PWild = False
patMayFail (PVar _ _) = False
patMayFail (PLit LUnit) = False
patMayFail (PAs _ _ p) = patMayFail p
patMayFail (PTuple ps) = anyList patMayFail ps
patMayFail _ = True

-- A block's statements.  A refutable `let` takes the rest of the block as its
-- decision's body, so the block ends with that decision; a refutable `let` that
-- ends the block gets the empty block as its body, the Unit a last `let` yields
-- (`refoldLets` reads both back).
lowerStmts : List DoStmt -> List CStmt
lowerStmts [] = []
lowerStmts ((DoLet _ False pat e site) :: rest)
  | patMayFail pat =
    [CSExpr (letDecision site pat (lower e) (CBlock (lowerStmts rest)))]
lowerStmts (s :: rest) = lowerStmt s :: lowerStmts rest

armTreeable : Arm -> Bool
armTreeable (Arm pat _ _) = treeablePat pat

-- a pattern is tree-able if it is built only from constructors / lists / tuples
-- / literals / vars / wildcards / as-patterns / record / range patterns.
-- PRng and PRec canonicalize to PWild in the matrix (see canonPat); arms
-- containing them are marked as "needs guard" (patNeedsGuard) so the tree
-- emits CTGuard leaves that fall through on matchPat failure, preserving the
-- ordered semantics exactly.
treeablePat : Pat -> Bool
treeablePat PWild = True
treeablePat (PVar _ _) = True
treeablePat (PLit _) = True
treeablePat (PCon _ args) = allList treeablePat args
treeablePat (PCons h t) = treeablePat h && treeablePat t
treeablePat (PList ps) = allList treeablePat ps
treeablePat (PTuple ps) = allList treeablePat ps
treeablePat (PAs _ _ p) = treeablePat p
treeablePat (PRng _ _ _) = True
treeablePat (PRec _ _ _) = True

compileArms : FailSite -> List Arm -> CTree
compileArms site arms =
  compileTree site (map armHasGuard arms) (initialRows arms 0)

-- an arm whose pattern (recursively) contains PRng or PRec may not match the
-- scrutinee at the leaf even though the matrix treated it as a wildcard — the
-- tree leaf must therefore be a CTGuard (fall-through on matchPat failure) rather
-- than a CTLeaf (which assumes the pattern is guaranteed to match the scrutinee).
armHasGuard : Arm -> Bool
armHasGuard (Arm pat gs _) = isNonEmptyL gs || patNeedsGuard pat

patNeedsGuard : Pat -> Bool
patNeedsGuard (PRng _ _ _) = True
patNeedsGuard (PRec _ _ _) = True
patNeedsGuard (PCon _ args) = anyList patNeedsGuard args
patNeedsGuard (PCons h t) = patNeedsGuard h || patNeedsGuard t
patNeedsGuard (PList ps) = anyList patNeedsGuard ps
patNeedsGuard (PTuple ps) = anyList patNeedsGuard ps
patNeedsGuard (PAs _ _ p) = patNeedsGuard p
patNeedsGuard _ = False

-- one matrix row per arm: its (canonicalised) pattern as a single column, paired
-- with the arm's index (the leaves carry it back to the original CArm).
initialRows : List Arm -> Int -> List (List Pat, Int)
initialRows [] _ = []
initialRows ((Arm pat _ _) :: rest) i =
  ([canonPat pat], i) :: initialRows rest (i + 1)

-- ── the Maranget recursion, emitting a tree (mirrors exhaust.mdk's matrix ops,
-- re-implemented here over index-carrying rows since exhaust's are stage-local).
-- Always discriminates the leftmost column; a row's index rides along through
-- specialization so the leaf knows which arm it selected.
-- exported for the LLVM backend (slice 7): arg-position dispatch coalesces an
-- impl method's clauses into a decision tree via this same Maranget compiler —
-- the backend-neutral transform Axis-1 designates as shared by both backends
-- (only leaf emission differs: bytecode SWITCH vs LLVM switch/br).
-- The `List Bool` is indexed BY ARM INDEX, and the recursion looks a leaf's arm
-- up in it — which, as a list, cost O(i) per leaf and O(N²) over an N-arm match
-- (`nthBool`; the second half of #408, see `guardSet`).  The exported entry
-- keeps the caller-facing `List Bool` and converts it ONCE, at the top, into the
-- membership set the recursion actually threads.
-- [site] is what every miss leaf of the tree raises.
export
compileTree : FailSite -> List Bool -> List (List Pat, Int) -> CTree
compileTree site guards rows =
  withFailSite site (compileTreeG (guardSet 0 guards omEmpty) rows)

-- [t] with every miss leaf raising [site].
withFailSite : FailSite -> CTree -> CTree
withFailSite site (CTFail _) = CTFail site
withFailSite _ (CTLeaf i) = CTLeaf i
withFailSite site (CTGuard i t) = CTGuard i (withFailSite site t)
withFailSite site (CTSwitch bs d) =
  CTSwitch (map (failSiteBranch site) bs) (withFailSite site d)
withFailSite site (CTDrop t) = CTDrop (withFailSite site t)

failSiteBranch : FailSite -> CTBranch -> CTBranch
failSiteBranch site (CTBranch h t) = CTBranch h (withFailSite site t)

-- The site [t]'s misses raise (every miss leaf of one tree carries the same one);
-- an unlocated `NoArm` when it has none.
treeFailSite : CTree -> FailSite
treeFailSite t = match treeFailSiteOpt t
  Some s => s
  None => NoArm noDeclLoc

treeFailSiteOpt : CTree -> Option FailSite
treeFailSiteOpt (CTFail s) = Some s
treeFailSiteOpt (CTLeaf _) = None
treeFailSiteOpt (CTGuard _ t) = treeFailSiteOpt t
treeFailSiteOpt (CTSwitch bs d) = match firstBranchFailSite bs
  Some s => Some s
  None => treeFailSiteOpt d
treeFailSiteOpt (CTDrop t) = treeFailSiteOpt t

firstBranchFailSite : List CTBranch -> Option FailSite
firstBranchFailSite [] = None
firstBranchFailSite ((CTBranch _ t) :: rest) = match treeFailSiteOpt t
  Some s => Some s
  None => firstBranchFailSite rest

-- Guarded ARM INDICES as an `OrdMap Unit` membership set: O(log N) per leaf
-- lookup where the `List Bool` walk was O(arm index).  Built once per
-- `compileTree` entry (twice per match at most — see `compileArms`), never
-- inside the recursion.  `nthBool guards i` was `False` for any `i` past the
-- list's end, so an index absent from the set reads exactly as it did.
guardSet : Int -> List Bool -> OrdMap Unit -> OrdMap Unit
guardSet _ [] acc = acc
guardSet i (True :: rest) acc =
  guardSet (i + 1) rest (omInsert (intToString i) () acc)
guardSet i (False :: rest) acc = guardSet (i + 1) rest acc

compileTreeG : OrdMap Unit -> List (List Pat, Int) -> CTree
compileTreeG _ [] = CTFail (NoArm noDeclLoc)
compileTreeG guards (row :: rest) = compileRows guards row rest (row :: rest)

compileRows : OrdMap Unit ->
  (List Pat, Int) ->
  List (List Pat, Int) ->
  List (List Pat, Int) ->
  CTree
compileRows guards (pats, i) rest rows
  | allWild pats = leafOrGuard guards i rest
  | anyList rowHasCon rows = buildConSwitch guards rows
  | anyList rowHasLit rows = buildLitSwitch guards rows
  | otherwise = CTDrop (compileTreeG guards (map dropHead rows))

-- the first (highest-priority still-viable) row matches everything reaching
-- here: a guarded clause becomes a CTGuard whose failure resumes at `rest`; an
-- unguarded one terminates (later rows are unreachable, exactly as ordered).
leafOrGuard : OrdMap Unit -> Int -> List (List Pat, Int) -> CTree
leafOrGuard guards i rest
  | omHasKey (intToString i) guards = CTGuard i (compileTreeG guards rest)
  | otherwise = CTLeaf i

-- #408: the switch's rows are bucketed by head in ONE pass and each branch is
-- handed its OWN rows, rather than every branch re-filtering the whole matrix.
-- Calling `specializeCon c a rows` once per distinct head instead has each
-- of those calls scan all N rows — O(N²) for an N-arm match over an N-ctor
-- type.  That cost is pure instruction count (each miss is an alloc-free
-- `c2 == c`), so it is invisible to both the op arm and the alloc arm of
-- perf_scaling and only surfaced once diff_compiler_stage_ir_scaling.sh graded
-- per-stage Callgrind Ir.  See `conBuckets` for the wildcard/ordering argument.
buildConSwitch : OrdMap Unit -> List (List Pat, Int) -> CTree
buildConSwitch guards rows =
  let buckets = conBuckets 0 rows omEmpty
  let wilds = wildTailRows 0 rows
  CTSwitch
    (map (conBranch guards buckets wilds) (distinctConHeads rows))
    (compileTreeG guards (defaultMatrix rows))

conBranch : OrdMap Unit ->
  OrdMap (List (Int, (List Pat, Int))) ->
  List (Int, (List Pat, Int)) ->
  (String, Int) ->
  CTBranch
conBranch guards buckets wilds (c, a) =
  CTBranch
    (decodeHead c a)
    (compileTreeG
      guards
      (mergeByOrd (reverseL (bucketRows c buckets)) (map (padWildRow a) wilds)))

buildLitSwitch : OrdMap Unit -> List (List Pat, Int) -> CTree
buildLitSwitch guards rows =
  let buckets = litBuckets 0 rows omEmpty
  let wilds = wildTailRows 0 rows
  CTSwitch
    (map (litBranch guards buckets wilds) (distinctLits rows))
    (compileTreeG guards (defaultMatrix rows))

-- Literal heads have arity 0, so a wildcard row contributes its tail unpadded —
-- exactly what the old `specLitRow _ (PWild::rest, i) = Some (rest, i)` did.
litBranch : OrdMap Unit ->
  OrdMap (List (Int, (List Pat, Int))) ->
  List (Int, (List Pat, Int)) ->
  Lit ->
  CTBranch
litBranch guards buckets wilds l =
  CTBranch
    (HLit l)
    (compileTreeG
      guards
      (mergeByOrd (reverseL (bucketRows (litKey l) buckets)) wilds))

-- map a canonical constructor name + arity to the runtime head the evaluator
-- tests with (the synthetic list/tuple/unit names canonPat introduced map back
-- to their real Value shapes; everything else is a plain named constructor).
-- The built-in forms key off RESERVED synthetic names (`__cons__`/`__nil__`/
-- `__unit__`/`__tuple__`, all un-writable as user ctors) — NOT the user-facing
-- `Cons`/`Nil`/`Unit`. A user `data T = Cons … | Nil` therefore lowers its
-- ctors to `HCon "Cons"`/`HCon "Nil"` (→ VCon shapes), not the built-in list
-- heads; aliasing the two was a silent ceval miscompile (decodeHead bug).
decodeHead : String -> Int -> CHead
decodeHead "__cons__" _ = HCons
decodeHead "__nil__" _ = HNil
decodeHead "__unit__" _ = HUnit
decodeHead "__tuple__" a = HTuple a
decodeHead c a = HCon c a

-- ── canonical patterns for the matrix (mirror exhaust.mdk's desugarPat) ─────
-- Var → wildcard; lists → reserved __cons__/__nil__ chains; tuples → __tuple__;
-- Unit literal → reserved __unit__; Bool literals → True/False nullary ctors —
-- so specialization is uniform. The list/unit forms use RESERVED synthetic names
-- (not the user-facing `Cons`/`Nil`/`Unit`) so a user ctor of the same name can't
-- alias the built-in head. Only tree-able patterns reach here (PRng/PRec gated).
tupleName : String
tupleName = "__tuple__"

-- reserved synthetic head names for the built-in list/unit forms. Like
-- `tupleName`, these are un-writable as user constructors (lower-case + leading
-- `__`), so a user ctor literally named `Cons`/`Nil`/`Unit` keeps its own name
-- through the matrix and lowers to `HCon`, never the built-in list/unit heads.
consName : String
consName = "__cons__"

nilName : String
nilName = "__nil__"

unitName : String
unitName = "__unit__"

-- exported for the LLVM backend (slice 7): impl-method clauses are canonicalised
-- into the matrix form before `compileTree` (same as `initialRows` does for match
-- arms) — part of the shared backend-neutral decision-tree pass (Axis-1).
export
canonPat : Pat -> Pat
canonPat (PVar _ _) = PWild
canonPat PWild = PWild
canonPat (PLit (LBool True)) = PCon "True" []
canonPat (PLit (LBool False)) = PCon "False" []
canonPat (PLit LUnit) = PCon unitName []
canonPat (PLit l) = PLit l
canonPat (PTuple ps) = PCon tupleName (map canonPat ps)
canonPat (PCon c args) = PCon c (map canonPat args)
canonPat (PCons h t) = PCon consName [canonPat h, canonPat t]
canonPat (PList []) = PCon nilName []
canonPat (PList (h :: r)) = PCon consName [canonPat h, canonPat (PList r)]
canonPat (PAs _ _ p) = canonPat p
canonPat (PRng _ _ _) = PWild
canonPat (PRec _ _ _) = PWild

-- ── matrix predicates / column analysis ────────────────────────────────────
allWild : List Pat -> Bool
allWild ps = allList isWildPat ps

isWildPat : Pat -> Bool
isWildPat PWild = True
isWildPat _ = False

rowHasCon : (List Pat, Int) -> Bool
rowHasCon ((PCon _ _) :: _, _) = True
rowHasCon _ = False

rowHasLit : (List Pat, Int) -> Bool
rowHasLit ((PLit _) :: _, _) = True
rowHasLit _ = False

dropHead : (List Pat, Int) -> (List Pat, Int)
dropHead (_ :: ps, i) = (ps, i)
dropHead ([], i) = ([], i)

-- distinct head constructors present in column 0, first-seen order, each with
-- its arity (uniform per name in a well-typed column).
distinctConHeads : List (List Pat, Int) -> List (String, Int)
distinctConHeads rows = dedupHeads (colHeads rows) omEmpty

colHeads : List (List Pat, Int) -> List (String, Int)
colHeads [] = []
colHeads (((PCon c args) :: _, _) :: rest) = (c, listLen args) :: colHeads rest
colHeads (_ :: rest) = colHeads rest

-- First-seen dedup by constructor name.  `seen` is an `OrdMap`-backed membership
-- set (O(log n) test/insert) rather than a growing `List` scanned with `contains`
-- per head — that scan was O(arms^2) on an N-arm match over an N-ctor type (#960).
-- The output is still built at each head's FIRST occurrence, recursing on `rest`
-- unchanged, so first-occurrence ordering is byte-identical to the old list form.
dedupHeads : List (String, Int) -> OrdMap Unit -> List (String, Int)
dedupHeads [] _ = []
dedupHeads ((c, a) :: rest) seen
  | omHasKey c seen = dedupHeads rest seen
  | otherwise = (c, a) :: dedupHeads rest (omInsert c () seen)

distinctLits : List (List Pat, Int) -> List Lit
distinctLits rows = dedupLits (colLits rows) omEmpty

colLits : List (List Pat, Int) -> List Lit
colLits [] = []
colLits (((PLit l) :: _, _) :: rest) = l :: colLits rest
colLits (_ :: rest) = colLits rest

-- First-seen dedup of the column's literal heads.  Mirrors #960's `dedupHeads`
-- fix: the old `seen` List scanned with `anyList (l == _)` per literal was
-- O(arms^2) on an N-arm literal match (a lexer/opcode/state-machine dispatch),
-- and — unlike `dedupHeads`' `contains` — the scan used the UNcounted `anyList`
-- AND each `Eq Lit` compare allocated, so the quadratic was invisible to the op
-- arm yet superlinear in allocation (#970).  `seen` is now an `OrdMap Unit`
-- membership set keyed by `litKey` (an injective, Eq-exact string render of the
-- literal): O(log n) test/insert.  The output is still built at each literal's
-- FIRST occurrence, recursing on `rest` unchanged, so first-occurrence order —
-- and therefore the emitted literal-switch — is byte-identical to the old form.
dedupLits : List Lit -> OrdMap Unit -> List Lit
dedupLits [] _ = []
dedupLits (l :: rest) seen =
  let k = litKey l
  match omHasKey k seen
    True => dedupLits rest seen
    False => l :: dedupLits rest (omInsert k () seen)

-- A total, injective, Eq-exact string key for a match-column literal.  Each
-- constructor gets a distinct one-char tag, so keys can never collide ACROSS
-- constructors (the tag partitions the space); WITHIN a constructor the render
-- is injective, so `litKey a == litKey b`  iff  `a == b` (derived `Eq Lit`) —
-- exactly the membership test the old `anyList (l == _)` performed, preserving
-- dedup semantics.  Float note: -0.0 is normalised to +0.0 (they are `Eq`-equal
-- and the old `==` deduped them); NaN cannot be written as a pattern literal so
-- its `NaN /= NaN` edge is unreachable here.  LBool/LUnit are canonicalised to
-- constructors before lowering (see `canonPat`), so those arms never reach this
-- function but are kept total.
litKey : Lit -> String
litKey (LInt n) = "i" ++ intToString n
litKey (LChar c) = "c" ++ c
litKey (LString s) = "s" ++ s
litKey (LFloat f) = "f" ++ floatToString (normLitZero f)
litKey (LBool True) = "bT"
litKey (LBool False) = "bF"
litKey LUnit = "u"
litKey (LU64 hi lo) = "w\{intToString hi}.\{intToString lo}"
litKey (LI64 hi lo) = "i\{intToString hi}.\{intToString lo}"

-- collapse -0.0 to +0.0 so the float key matches `Eq Lit` (which treats them
-- equal); a no-op for every other value.
normLitZero : Float -> Float
normLitZero f = if f == 0.0 then 0.0 else f

-- ── matrix specialization / default (over index-carrying rows) ─────────────
filterMapRows : ((List Pat, Int) -> Option (List Pat, Int)) ->
  List (List Pat, Int) ->
  List (List Pat, Int)
filterMapRows _ [] = []
filterMapRows f (r :: rest) = match f r
  Some r2 => r2 :: filterMapRows f rest
  None => filterMapRows f rest

-- ── one-pass matrix bucketing, replacing the per-branch rescan (#408) ───────
--
-- A `specializeCon c a rows` that `filterMapRows` over the WHOLE matrix,
-- called once per distinct head by `buildConSwitch` — with `specializeLit` mirroring it
-- for literal switches — is replaced by a single bucketing pass whose
-- result is read once per branch, so lowering an N-arm switch is O(N log N)
-- instead of O(N²).
--
-- THE ORDERING/WILDCARD ARGUMENT.  `specializeCon c a` kept, IN MATRIX ROW
-- ORDER: (1) each `PCon c` row, head replaced by its fields; (2) each `PWild`
-- row, head replaced by `a` wildcards.  Pattern priority is positional, so that
-- relative order is observable — it decides which arm a value selects, and the
-- emitted `CTSwitch` is graded byte-identical.  A wildcard row belongs to EVERY
-- branch, so buckets alone cannot reproduce it (this is the same subtlety
-- `exhaust.mdk`'s `usefulCovered` documents, where it is handled by falling back
-- to the rescan).  Here it is handled instead, because a trailing `_ =>` arm on
-- a wide match is common enough that a fallback would leave the quadratic in
-- place for it: every row is tagged with its ORDINAL in the matrix on the way
-- into its bucket, wildcard tails are collected once in the same numbering, and
-- a branch re-interleaves its bucket with the (padded) wildcard rows by ordinal.
-- The merge therefore reproduces the filter's order exactly, by construction,
-- and costs O(bucket + wildcards) per branch — proportional to the rows that
-- branch actually receives.
--
-- Branch ORDER is untouched: `distinctConHeads`/`distinctLits` still mint it,
-- unchanged, in first-seen row order.

-- A bucket's rows, or none.  Buckets are built by prepending, so a bucket reads
-- back in reverse row order and is `reverseL`'d at the branch (as in
-- `exhaust.mdk`'s `headBuckets`).
bucketRows : String ->
  OrdMap (List (Int, (List Pat, Int))) ->
  List (Int, (List Pat, Int))
bucketRows k m = optionOr [] (omLookup k m)

pushBucket : String ->
  (Int, (List Pat, Int)) ->
  OrdMap (List (Int, (List Pat, Int))) ->
  OrdMap (List (Int, (List Pat, Int)))
pushBucket k r m = omInsert k (r :: bucketRows k m) m

-- Rows grouped by column-0 constructor, head stripped to `args ++ rest` — i.e.
-- exactly the rows `specializeCon c` kept, for every `c` at once.  Non-`PCon`
-- rows (wildcards, literals, empty) still consume an ordinal so the numbering
-- stays aligned with `wildTailRows`.
conBuckets : Int ->
  List (List Pat, Int) ->
  OrdMap (List (Int, (List Pat, Int))) ->
  OrdMap (List (Int, (List Pat, Int)))
conBuckets _ [] acc = acc
conBuckets k (((PCon c args) :: rest, i) :: more) acc =
  conBuckets (k + 1) more (pushBucket c (k, (args ++ rest, i)) acc)
conBuckets k (_ :: more) acc = conBuckets (k + 1) more acc

-- The literal mirror.  Keyed by `litKey`, which is injective and `Eq`-exact, so
-- two literals share a bucket exactly when the old `litEq` compare accepted them
-- (`distinctLits` already deduped its heads by the same key).  That also retires
-- `litEq`: #970's O(arms²) allocating compares are gone with the rescan itself,
-- since a row is now keyed ONCE rather than compared once per distinct literal.
litBuckets : Int ->
  List (List Pat, Int) ->
  OrdMap (List (Int, (List Pat, Int))) ->
  OrdMap (List (Int, (List Pat, Int)))
litBuckets _ [] acc = acc
litBuckets k (((PLit l) :: rest, i) :: more) acc =
  litBuckets (k + 1) more (pushBucket (litKey l) (k, (rest, i)) acc)
litBuckets k (_ :: more) acc = litBuckets (k + 1) more acc

-- Column-0 wildcard rows, head stripped, tagged with the same ordinals
-- `conBuckets`/`litBuckets` assign.  The head's replacement wildcards are added
-- per branch by `padWildRow`, since the count is the branch's own arity.
wildTailRows : Int -> List (List Pat, Int) -> List (Int, (List Pat, Int))
wildTailRows _ [] = []
wildTailRows k ((PWild :: rest, i) :: more) =
  (k, (rest, i)) :: wildTailRows (k + 1) more
wildTailRows k (_ :: more) = wildTailRows (k + 1) more

padWildRow : Int -> (Int, (List Pat, Int)) -> (Int, (List Pat, Int))
padWildRow arity (k, (ps, i)) = (k, (replicate arity PWild ++ ps, i))

-- Interleave a branch's own rows with the wildcard rows by ordinal, restoring
-- matrix row order and dropping the tags.  Ordinals are unique (one per matrix
-- row) and both inputs are ascending, so this is a total, order-exact merge.
mergeByOrd : List (Int, (List Pat, Int)) ->
  List (Int, (List Pat, Int)) ->
  List (List Pat, Int)
mergeByOrd [] ys = map untagRow ys
mergeByOrd xs [] = map untagRow xs
mergeByOrd ((ka, ra) :: xs) ((kb, rb) :: ys) =
  if ka < kb then
    ra :: mergeByOrd xs ((kb, rb) :: ys)
  else
    rb :: mergeByOrd ((ka, ra) :: xs) ys

untagRow : (Int, (List Pat, Int)) -> (List Pat, Int)
untagRow (_, r) = r

-- the default matrix: rows whose head is a wildcard (head dropped); used for the
-- switch's default branch and (when column 0 is all wildcards) CTDrop.
defaultMatrix : List (List Pat, Int) -> List (List Pat, Int)
defaultMatrix rows = filterMapRows defRow rows

defRow : (List Pat, Int) -> Option (List Pat, Int)
defRow (PWild :: rest, i) = Some (rest, i)
defRow _ = None

-- ── small local helpers ────────────────────────────────────────────────────

lowerField : FieldAssign -> CField
lowerField (FieldAssign k e) = CField k (lower e)

lowerBind : LetBind -> CBind
lowerBind (LetBind name clauses site) =
  CBind name (map lowerClause clauses) site

lowerClause : FunClause -> CClause
lowerClause (FunClause pats body) = CClause pats (lower body)

lowerStmt : DoStmt -> CStmt
lowerStmt (DoExpr e) = CSExpr (lower e)
lowerStmt (DoLet _ recFlag pat e _) = CSLet recFlag pat (lower e)
lowerStmt (DoAssign x e) = CSAssign x (lower e)
lowerStmt _ = panic "core_ir lower: unsupported block statement"

-- ── programs ───────────────────────────────────────────────────────────────
-- Coalesce top-level multi-clause `DFunDef`s into one CBind per name (preserving
-- first-appearance order, exactly as eval.mdk's funGroupNames), gather the ctor
-- arity + ctor→type tables.
--
-- This form lowers WITHOUT the typechecker's disposition table, for the untyped
-- probes (`core_ir_main`, `core_ir_prelude_main`, `core_ir_run_main`,
-- `core_ir_roundtrip_main`, `core_ir_dump_main`, the snapshot tool's CORE_IR
-- section).  It cannot see an inherited default: which instance inherits which
-- default is instance identity, and only elaboration establishes that.  An impl that
-- leaves a method to its interface's default therefore gets no body for it here.  A
-- driver that typechecks lowers through `lowerTypedProgram`.
export
lowerProgram : List Decl -> CProgram
lowerProgram prog = refoldProgram noLetCheck (lowerProgramWith None prog)

-- Lowering after an elaboration, against the table it published.  Refuses (panics)
-- when none was published instead of silently lowering every inherited default away.
export
lowerTypedProgram : List Decl -> CProgram
lowerTypedProgram prog =
  refoldProgram
    noLetCheck
    (lowerProgramWith (Some (installedDispositions ())) prog)

-- [dispositions] is the typechecker's table for [prog] (`None` for an untyped
-- probe; see `lowerProgram`).  Refutable lets are still one-arm decisions here
-- (`letDecision`); each public lowering decides which of them to keep.
lowerProgramWith : Option DispositionTable -> List Decl -> CProgram
lowerProgramWith dispositions prog =
  CProgram
    (lowerGroupsRaw prog)
    (ctorArities prog)
    (buildCtorToType prog)
    (lowerImplsRaw
      (installDispatchTables prog)
      (instanceReqCounts prog)
      dispositions
      prog)

-- ── which refutable lets keep their decision (see `letDecision`) ─────────────
-- Only the native backend tests a refutable `let` through its decision; every
-- other consumer gets the plain `CLet`/`CSLet` back, unchanged.  Native keeps the
-- decision only where the pattern can really miss, by the program's constructor
-- table, so a `let` on a single-constructor type keeps its unchecked destructure.

-- A `let` pattern the decision is kept for; `noLetCheck` keeps none.
noLetCheck : Pat -> Bool
noLetCheck _ = False

-- [p] can miss a value of its type: a constructor with a sibling (or one the table
-- does not know), a list, or a literal other than `()`, anywhere in it.  A record
-- pattern still unresolved after `rewriteProgramRecPats` keeps the plain `let`.
patCanMiss : OrdMap Bool -> Pat -> Bool
patCanMiss _ PWild = False
patCanMiss _ (PVar _ _) = False
patCanMiss _ (PLit LUnit) = False
patCanMiss _ (PLit _) = True
patCanMiss sib (PAs _ _ p) = patCanMiss sib p
patCanMiss sib (PTuple ps) = anyList (patCanMiss sib) ps
patCanMiss sib (PCon c ps) = ctorHasSibling sib c || anyList (patCanMiss sib) ps
patCanMiss _ (PRec _ _ _) = False
patCanMiss _ _ = True

ctorHasSibling : OrdMap Bool -> String -> Bool
ctorHasSibling sib c = match omLookup c sib
  Some b => b
  None => True

-- constructor → whether its type declares another constructor, from a CProgram's
-- (ctor, type) table; the first row for a constructor name wins, as the emitter's
-- `ctorTypeOf` reads it.
siblingTable : List (String, String) -> OrdMap Bool
siblingTable t =
  let counts = typeCtorCounts t omEmpty
  siblingRows counts t omEmpty

typeCtorCounts : List (String, String) -> OrdMap Int -> OrdMap Int
typeCtorCounts [] acc = acc
typeCtorCounts ((_, ty) :: rest) acc =
  let n = match omLookup ty acc
    Some k => k + 1
    None => 1
  typeCtorCounts rest (omInsert ty n acc)

siblingRows : OrdMap Int -> List (String, String) -> OrdMap Bool -> OrdMap Bool
siblingRows _ [] acc = acc
siblingRows counts ((c, ty) :: rest) acc
  | omHasKey c acc = siblingRows counts rest acc
  | otherwise =
    let many = match omLookup ty counts
      Some k => k > 1
      None => True
    siblingRows counts rest (omInsert c many acc)

-- the let-refute site of a one-arm decision `letDecision` built, else None.
letDecisionSite : CTree -> Option Loc
letDecisionSite t = match treeFailSiteOpt t
  Some (LetRefuted l) => Some l
  _ => None

refoldProgram : (Pat -> Bool) -> CProgram -> CProgram
refoldProgram keep (CProgram groups ctorArs ctorTypes implEntries) =
  CProgram
    (map (refoldBind keep) groups)
    ctorArs
    ctorTypes
    (map (refoldImpl keep) implEntries)

refoldBind : (Pat -> Bool) -> CBind -> CBind
refoldBind keep (CBind n clauses site) =
  CBind n (map (refoldClause keep) clauses) site

refoldClause : (Pat -> Bool) -> CClause -> CClause
refoldClause keep (CClause pats body) = CClause pats (refoldExpr keep body)

refoldImpl : (Pat -> Bool) -> CImplEntry -> CImplEntry
refoldImpl keep (CImplEntry n s (CImplTagged tag key iface ps pats body)) =
  CImplEntry n s (CImplTagged tag key iface ps pats (refoldExpr keep body))
refoldImpl keep (CImplEntry n s (CImplDefault ifaceId tag key ps pats body)) =
  CImplEntry n s (CImplDefault ifaceId tag key ps pats (refoldExpr keep body))

refoldExpr : (Pat -> Bool) -> CExpr -> CExpr
refoldExpr keep (CDecision scrut [CArm pat [] body] tree)
  | isSomeLoc (letDecisionSite tree) && not (keep pat) =
    CLet False pat (refoldExpr keep scrut) (refoldExpr keep body)
refoldExpr keep (CDecision scrut arms tree) =
  CDecision (refoldExpr keep scrut) (map (refoldArm keep) arms) tree
refoldExpr _ (CLit l) = CLit l
refoldExpr _ (CVar x addr) = CVar x addr
refoldExpr keep (CApp f x) = CApp (refoldExpr keep f) (refoldExpr keep x)
refoldExpr keep (CLam pats body) = CLam pats (refoldExpr keep body)
refoldExpr keep (CLet r pat e1 e2) =
  CLet r pat (refoldExpr keep e1) (refoldExpr keep e2)
refoldExpr keep (CLetGroup binds body) =
  CLetGroup (map (refoldBind keep) binds) (refoldExpr keep body)
refoldExpr keep (CMatch scrut arms) =
  CMatch (refoldExpr keep scrut) (map (refoldArm keep) arms)
refoldExpr keep (CIf c t e) =
  CIf (refoldExpr keep c) (refoldExpr keep t) (refoldExpr keep e)
refoldExpr keep (CBinPrim op l r tag site) =
  CBinPrim op (refoldExpr keep l) (refoldExpr keep r) tag site
refoldExpr keep (CUnOp op x) = CUnOp op (refoldExpr keep x)
refoldExpr keep (CTuple es) = CTuple (map (refoldExpr keep) es)
refoldExpr keep (CList es) = CList (map (refoldExpr keep) es)
refoldExpr keep (CRecord name fields) =
  CRecord name (map (refoldField keep) fields)
refoldExpr keep (CFieldAccess ex f n) = CFieldAccess (refoldExpr keep ex) f n
refoldExpr keep (CRecordUpdate name base fields) =
  CRecordUpdate name (refoldExpr keep base) (map (refoldField keep) fields)
refoldExpr keep (CVariantUpdate con base fields) =
  CVariantUpdate con (refoldExpr keep base) (map (refoldField keep) fields)
refoldExpr keep (CArray es) = CArray (map (refoldExpr keep) es)
refoldExpr keep (CRangeList lo hi incl) =
  CRangeList (refoldExpr keep lo) (refoldExpr keep hi) incl
refoldExpr keep (CRangeArray lo hi incl) =
  CRangeArray (refoldExpr keep lo) (refoldExpr keep hi) incl
refoldExpr keep (CIndex a i) = CIndex (refoldExpr keep a) (refoldExpr keep i)
refoldExpr keep (CSlice a lo hi incl) =
  CSlice (refoldExpr keep a) (refoldExpr keep lo) (refoldExpr keep hi) incl
refoldExpr keep (CStringIndex a i) =
  CStringIndex (refoldExpr keep a) (refoldExpr keep i)
refoldExpr keep (CStringSlice a lo hi incl) =
  CStringSlice
    (refoldExpr keep a)
    (refoldExpr keep lo)
    (refoldExpr keep hi)
    incl
refoldExpr keep (CListIndex a i) =
  CListIndex (refoldExpr keep a) (refoldExpr keep i)
refoldExpr keep (CListSlice a lo hi incl) =
  CListSlice (refoldExpr keep a) (refoldExpr keep lo) (refoldExpr keep hi) incl
refoldExpr keep (CBlock stmts) = CBlock (refoldStmts keep stmts)
refoldExpr _ (CMethod name iface arity r ir mr) =
  CMethod name iface arity r ir mr
refoldExpr _ (CDict name rs) = CDict name rs

-- A block that ends with a `lowerStmts` let decision gets its `let` statement
-- back, followed by the statements the decision took as its body.  A kept decision
-- that ended the block takes Unit as its body in place of the empty block.
refoldStmts : (Pat -> Bool) -> List CStmt -> List CStmt
refoldStmts _ [] = []
refoldStmts keep [CSExpr (CDecision scrut [CArm pat [] (CBlock rest)] tree)]
  | isSomeLoc (letDecisionSite tree) =
    let scrut2 = refoldExpr keep scrut
    if keep pat then
      let body =
        if isEmptyL rest then CLit LUnit else CBlock (refoldStmts keep rest)
      [CSExpr (CDecision scrut2 [CArm pat [] body] tree)]
    else
      CSLet False pat scrut2 :: refoldStmts keep rest
refoldStmts keep (s :: rest) = refoldStmt keep s :: refoldStmts keep rest

refoldStmt : (Pat -> Bool) -> CStmt -> CStmt
refoldStmt keep (CSExpr e) = CSExpr (refoldExpr keep e)
refoldStmt keep (CSLet r pat e) = CSLet r pat (refoldExpr keep e)
refoldStmt keep (CSAssign x e) = CSAssign x (refoldExpr keep e)

refoldArm : (Pat -> Bool) -> CArm -> CArm
refoldArm keep (CArm pat guards body) =
  CArm pat (map (refoldGuard keep) guards) (refoldExpr keep body)

refoldGuard : (Pat -> Bool) -> CGuard -> CGuard
refoldGuard keep (CGBool e) = CGBool (refoldExpr keep e)
refoldGuard keep (CGBind p e) = CGBind p (refoldExpr keep e)

refoldField : (Pat -> Bool) -> CField -> CField
refoldField keep (CField k e) = CField k (refoldExpr keep e)

isSomeLoc : Option Loc -> Bool
isSomeLoc (Some _) = True
isSomeLoc None = False

-- #1970: which backend(s) a `lowerProgramEmit` caller is about to feed the result
-- to — the discriminator `dictWitnessTagGuard` needs to narrow its wasm 30-bit
-- `dictTag` check (#377) to callers that provably never emit wasm from this
-- CProgram.  `TargetBothUnknown` is NOT a "don't know yet, ask later" filler value
-- — it is the correct, and unchanged, answer for a caller that positively serves
-- (or cannot rule out serving) BOTH backends from the one lowered program: a
-- shared debug/structural probe (`snapshot.mdk`'s `emitBoth`, `profile_main.mdk`'s
-- reused `cprog`, `core_ir_typed_modules_dump_main.mdk`, `draft_semantic_program.mdk`)
-- must get the SAME full-width check a genuinely target-unaware caller would, or a
-- collision that is real under `--target wasm` goes unreported because SOME other
-- caller in the same binary happened to know `native`.  Only `TargetNative` narrows.
public export data EmitTarget = TargetNative | TargetWasm | TargetBothUnknown

-- ── record-pattern → positional-constructor-pattern rewrite (native backend) ──
-- The LLVM emitter has no record-pattern path: records / named-field variants are
-- heap CELLS `[tag | field0 | field1 | …]` exactly like positional constructors,
-- so a `match` on one is destructured by the SAME cellTag-test + positional
-- field-extraction machinery `PCon` already drives (emitDecision / bindPattern).
-- A `PRec "T" recFields open` is therefore lowered to `PCon "T" [sub-pattern per
-- field IN DECLARED ORDER]`: each declared field of `T` contributes (a) the
-- matching `RecPatField`'s sub-pattern, (b) `PVar label` if it is a pun (`None`),
-- or (c) `PWild` if the field is unnamed in the pattern (covers both the open
-- `..` form and a fully-specified record naming a subset).  After the rewrite no
-- PRec reaches canonPat / bindPattern, so the emitter needs no record-specific code.
--
-- This is an EMIT-ONLY transform: the tree-walking core_ir_eval evaluates a record
-- to a by-name `VRecord` and matches `PRec` by label, so it must NOT see the
-- positional `PCon` rewrite (a `PCon` would not match a `VRecord`).  Hence it lives
-- in `lowerProgramEmit` — which the LLVM emit drivers call — NOT in the shared
-- `lowerProgram` that core_ir_main / core_ir_eval use.  The field-order map is
-- DECLARED order (DData named-field variants), the same order
-- the emitter's record cell layout / recFieldTable use, so the positional indices
-- line up with the cell's stored field offsets (verified by the fixture byte-diff).
export
lowerProgramEmit : EmitTarget -> List Decl -> CProgram
lowerProgramEmit target prog =
  -- #1950: refuse a program whose impls collide on ONE emitted symbol, here rather
  -- than letting clang report it unlocated.  Both backends reach this seam.
  let _ = implSymbolCollisionGuard prog
  -- #348/#377: refuse a program whose dict-witness TAGS collide under djb2, in
  -- either backend's tag width the caller's `target` cannot rule out.  Same seam,
  -- same reason.
  let _ = dictWitnessTagGuard target prog
  let sited = match target
    TargetBothUnknown => prog
    _ => siteTrapCalls prog
  let raw = lowerProgramWith (installedDispositionsOpt ()) sited
  let fo = declaredRecordFieldOrders prog
  hoistNullaryMemo
    (match target
      -- the let decisions are refolded after the record-pattern rewrite, which
      -- resolves the record patterns `patCanMiss` reads
      TargetBothUnknown =>
        rewriteProgramRecPats fo (refoldProgram noLetCheck raw)
      _ =>
        let rewritten = rewriteProgramRecPats fo raw
        refoldProgram
          (patCanMiss (siblingTable (cprogramCtorTypes raw)))
          rewritten)

cprogramCtorTypes : CProgram -> List (String, String)
cprogramCtorTypes (CProgram _ _ ctorTypes _) = ctorTypes

-- ── located `panic` and `xs[i]` (native and wasm backends) ─────────────────────────────
-- A saturated `panic m` and an `xs[i]` that reads one of the prelude's own
-- `Index` impls trap inside a body that knows nothing of the caller, so the
-- caller's site travels in as an argument: `panic m` becomes `panicAt <site> m`
-- and `xs[i]` the impl's site-carrying twin, `arrayIndexAt <site> xs i`.  The
-- site is the start of the application, where `medaka run` reports it, as a
-- `siteSentinelName` literal the emitter packs.  Only a site with a file is
-- rewritten, so a build whose driver stamps no files lowers as before.
siteTrapCalls : List Decl -> List Decl
siteTrapCalls prog =
  let twins = indexTwins (topFunNames prog omEmpty)
  map (siteTrapDecl twins) prog

-- The Core IR cannot tell the `panic` extern from a local of the same name, so
-- a declaration that binds `panic` anywhere keeps every `panic` call as it was.
siteTrapDecl : OrdMap String -> Decl -> Decl
siteTrapDecl twins d =
  let panicFree = not (contains "panic" (declBinders d))
  match mapProg (siteTrapExpr panicFree twins) [d]
    [d2] => d2
    _ => d

siteTrapExpr : Bool -> OrdMap String -> Expr -> Expr
siteTrapExpr panicFree twins (e@(EApp h m))
  | panicFree && isPanicHead h =
    sitedCall (exprStartLoc e) (EVar "panicAt") [m] e
siteTrapExpr _ twins (e@(EApp (EApp h a) i)) = match indexTwinOf twins h
  Some twin => sitedCall (exprStartLoc e) (EVar twin) [a, i] e
  None => e
siteTrapExpr _ _ e = e

-- `f <site> args…`, or [orig] when [site] names no file. The second clause is
-- `noDeclLoc`'s span after the driver stamped a file onto it: still no site.
sitedCall : Loc -> Expr -> List Expr -> Expr -> Expr
sitedCall (Loc "" _ _ _ _) _ _ orig = orig
sitedCall (Loc _ 1 0 1 0) _ _ orig = orig
sitedCall (Loc f sl sc _ _) fn args _ =
  applyAll (EApp fn (siteLiteral f sl sc)) args

applyAll : Expr -> List Expr -> Expr
applyAll f [] = f
applyAll f (x :: rest) = applyAll (EApp f x) rest

siteLiteral : String -> Int -> Int -> Expr
siteLiteral f line col =
  EApp
    (EApp (EApp (EVar siteSentinelName) (ELit (LString f))) (ELit (LInt line)))
    (ELit (LInt col))

isPanicHead : Expr -> Bool
isPanicHead (ELoc _ e) = isPanicHead e
isPanicHead (EVar "panic") = True
isPanicHead (EVarId "panic" _) = True
isPanicHead (EVarAt "panic" AGlobal) = True
isPanicHead _ = False

-- The prelude's `Index` impls, by route key, and the twin each one's body is.
-- A twin the program does not define (a driver that lowers no prelude) is left
-- out, so its `xs[i]` keeps the plain method call.
indexTwins : OrdMap Unit -> OrdMap String
indexTwins names =
  indexTwinsGo
    names
    [
      ("core::Index|(Array a) Int a|", "arrayIndexAt"),
      ("core::Index|(List a) Int a|", "listIndexAt"),
      ("core::Index|String Int Char|", "stringIndexAt"),
    ]
    omEmpty

indexTwinsGo : OrdMap Unit ->
  List (String, String) ->
  OrdMap String ->
  OrdMap String
indexTwinsGo _ [] acc = acc
indexTwinsGo names ((key, twin) :: rest) acc = match preludeFunName names twin
  Some n => indexTwinsGo names rest (omInsert key n acc)
  None => indexTwinsGo names rest acc

-- [n]'s emitted name: mangled as a prelude function, or bare when unmangled.
preludeFunName : OrdMap Unit -> String -> Option String
preludeFunName names n
  | omHasKey ("core__" ++ n) names = Some ("core__" ++ n)
  | omHasKey n names = Some n
  | otherwise = None

topFunNames : List Decl -> OrdMap Unit -> OrdMap Unit
topFunNames [] acc = acc
topFunNames ((DFunDef _ n _ _ _) :: rest) acc =
  topFunNames rest (omInsert n () acc)
topFunNames ((DAttrib _ d) :: rest) acc = topFunNames (d :: rest) acc
topFunNames (_ :: rest) acc = topFunNames rest acc

indexTwinOf : OrdMap String -> Expr -> Option String
indexTwinOf twins (ELoc _ h) = indexTwinOf twins h
indexTwinOf twins (EMethodAt "index" _ ev) = match evMethodRoutes ev
  (_, _, RKey key _ _, _, _) => omLookup key twins
  _ => None
indexTwinOf _ _ = None

-- Every name a pattern or a local function binds in [d], its own parameters
-- and its methods' included.
declBinders : Decl -> List String
declBinders (DImpl { methods, ... }) = flatMap implMethodBinders methods
declBinders (DInterface { methods, ... }) = flatMap ifaceMethodBinders methods
declBinders (DAttrib _ d) = declBinders d
declBinders d = localBoundNames [d] ++ localFunNames d

implMethodBinders : ImplMethod -> List String
implMethodBinders (ImplMethod n ps body) =
  declBinders (DFunDef False n ps body noDeclLoc)

ifaceMethodBinders : IfaceMethod -> List String
ifaceMethodBinders (IfaceMethod n _ (Some (MethodDefault ps body)) _) =
  declBinders (DFunDef False n ps body noDeclLoc)
ifaceMethodBinders _ = []

-- the names of the `let`/`where` functions [d] defines (`localBoundNames`
-- counts their parameters but not the names themselves).
localFunNames : Decl -> List String
localFunNames d =
  let acc = Ref []
  let _ = mapProg (noteLocalFuns acc) [d]
  !acc

noteLocalFuns : Ref (List String) -> Expr -> Expr
noteLocalFuns acc (e@(ELetGroup binds _)) =
  acc := map letBindName binds ++ !acc
  e
noteLocalFuns _ e = e

letBindName : LetBind -> String
letBindName (LetBind n _ _) = n

-- ── the ONE authority on a record's field order (#1513) ──────────────────────
-- ctor name → [field label in declared order], from every DData named-field
-- (`ConNamed`) variant — records are the `data X = { … }` short form, whose
-- synthesized ctor is a ConNamed variant.  (`DInterface`/`DImpl` are themselves
-- named-field variants of the AST's `Decl` type — declared in ast.mdk via `data
-- Decl = … | DInterface { … }` — so a self-hosted compiler that destructures them
-- gets their orders through the `DData ConNamed` branch when ast.mdk is in `prog`.)
--
-- EXPORTED because both backends seed their field-order tables from it (#1513).
-- Before that they built those tables by SCANNING the lowered program for `CRecord`
-- construction sites, which is wrong in two independent directions and was silently
-- wrong in both:
--   * a record with no construction site the scan happens to walk is ABSENT, and the
--     label-only fallback then answers with a DIFFERENT record that owns the label —
--     a wrong `getelementptr` offset at exit 0, or a segfault when the colliding
--     fields are differently typed;
--   * the entry a scan does produce carries the FIRST CONSTRUCTION SITE's written
--     label order, so `R { g = …, f = … }` installed `[g, f]` as the layout of `R`
--     and every differently-ordered literal of `R` in the same program was laid out
--     inconsistently with it.
-- The declaration answers both: it is always present, it is independent of DCE and
-- of which expression positions any scan walks, and it is the only thing all four
-- record operations (create / access / update / pattern) can agree on.
export
declaredRecordFieldOrders : List Decl -> List (String, List String)
declaredRecordFieldOrders prog = flatMap recPatFieldOrderEntries prog

recPatFieldOrderEntries : Decl -> List (String, List String)
recPatFieldOrderEntries (DData { dataCtors = variants }) =
  flatMap variantNamedOrder variants
recPatFieldOrderEntries (DAttrib _ inner) = recPatFieldOrderEntries inner
recPatFieldOrderEntries _ = []

variantNamedOrder : Variant -> List (String, List String)
variantNamedOrder (Variant n (ConNamed fs _)) = [(n, map fieldLabel fs)]
variantNamedOrder _ = []

fieldLabel : Field -> String
fieldLabel (Field n _) = n

-- the single pattern rewrite: a record pattern becomes a positional constructor
-- pattern over the type's declared field order; recurse into EVERY nested form.
rewritePat : List (String, List String) -> Pat -> Pat
rewritePat fo (PRec name recFields _) = match lookupAssoc name fo
  Some labels => PCon name (map (recPatForLabel fo recFields) labels)
  None => PRec name (map (rewriteRecPatField fo) recFields) False
-- no declared order found (e.g. an anonymous record with no `data`): leave the
-- PRec untouched — the emitter's existing gap-path reports it, no silent miscompile.

rewritePat fo (PCon c args) = PCon c (map (rewritePat fo) args)
rewritePat fo (PCons h t) = PCons (rewritePat fo h) (rewritePat fo t)
rewritePat fo (PTuple ps) = PTuple (map (rewritePat fo) ps)
rewritePat fo (PList ps) = PList (map (rewritePat fo) ps)
rewritePat fo (PAs x l p) = PAs x l (rewritePat fo p)
rewritePat _ p = p

-- the sub-pattern bound to declared field `label`: the named field's sub-pattern
-- (recursively rewritten), `PVar label` for a pun, or `PWild` when the field is
-- not named in the pattern (open `..` / subset).
recPatForLabel : List (String, List String) -> List RecPatField -> String -> Pat
recPatForLabel fo recFields label = match findRecField label recFields
  Some (RecPatField _ fl (Some sub)) => rewritePat fo sub
  Some (RecPatField _ fl None) => PVar label fl
  None => PWild

findRecField : String -> List RecPatField -> Option RecPatField
findRecField _ [] = None
findRecField label ((RecPatField l fl sub) :: rest)
  | l == label = Some (RecPatField l fl sub)
  | otherwise = findRecField label rest

rewriteRecPatField : List (String, List String) -> RecPatField -> RecPatField
rewriteRecPatField fo (RecPatField l fl (Some sub)) =
  RecPatField l fl (Some (rewritePat fo sub))
rewriteRecPatField _ (RecPatField l fl None) = RecPatField l fl None

-- ── apply the rewrite to every pattern position the lowered Core IR carries ───
-- Walks the whole program (groups + impls), rewriting every pattern and — for a
-- CDecision — RECOMPILING its decision tree from the rewritten arms (the tree was
-- built from the original PRec arms, which canonPat wildcarded; the rewritten PCon
-- arms compile to a proper constructor switch with no needs-guard fall-through).
rewriteProgramRecPats : List (String, List String) -> CProgram -> CProgram
rewriteProgramRecPats fo (CProgram groups ctorArs ctorTypes implEntries) =
  CProgram
    (map (rewriteBindRP fo) groups)
    ctorArs
    ctorTypes
    (map (rewriteImplRP fo) implEntries)

rewriteBindRP : List (String, List String) -> CBind -> CBind
rewriteBindRP fo (CBind n clauses site) =
  CBind n (map (rewriteClauseRP fo) clauses) site

rewriteClauseRP : List (String, List String) -> CClause -> CClause
rewriteClauseRP fo (CClause pats body) =
  CClause (map (rewritePat fo) pats) (rewriteExprRP fo body)

rewriteImplRP : List (String, List String) -> CImplEntry -> CImplEntry
rewriteImplRP fo (CImplEntry n s (CImplTagged tag key iface ps pats body)) =
  CImplEntry
    n
    s
    (CImplTagged
      tag
      key
      iface
      ps
      (map (rewritePat fo) pats)
      (rewriteExprRP fo body))
rewriteImplRP fo (CImplEntry n s (CImplDefault ifaceId tag key ps pats body)) =
  CImplEntry
    n
    s
    (CImplDefault
      ifaceId
      tag
      key
      ps
      (map (rewritePat fo) pats)
      (rewriteExprRP fo body))

rewriteExprRP : List (String, List String) -> CExpr -> CExpr
rewriteExprRP _ (CLit l) = CLit l
rewriteExprRP _ (CVar x addr) = CVar x addr
rewriteExprRP fo (CApp f x) = CApp (rewriteExprRP fo f) (rewriteExprRP fo x)
rewriteExprRP fo (CLam pats body) =
  CLam (map (rewritePat fo) pats) (rewriteExprRP fo body)
rewriteExprRP fo (CLet r pat e1 e2) =
  CLet r (rewritePat fo pat) (rewriteExprRP fo e1) (rewriteExprRP fo e2)
rewriteExprRP fo (CLetGroup binds body) =
  CLetGroup (map (rewriteBindRP fo) binds) (rewriteExprRP fo body)
rewriteExprRP fo (CMatch scrut arms) =
  CMatch (rewriteExprRP fo scrut) (map (rewriteArmRP fo) arms)
rewriteExprRP fo (CDecision scrut arms tree) =
  let arms2 = map (rewriteArmRP fo) arms
  CDecision
    (rewriteExprRP fo scrut)
    arms2
    (compileArmsC (treeFailSite tree) arms2)
rewriteExprRP fo (CIf c t e) =
  CIf (rewriteExprRP fo c) (rewriteExprRP fo t) (rewriteExprRP fo e)
rewriteExprRP fo (CBinPrim op l r tag site) =
  CBinPrim op (rewriteExprRP fo l) (rewriteExprRP fo r) tag site
rewriteExprRP fo (CUnOp op x) = CUnOp op (rewriteExprRP fo x)
rewriteExprRP fo (CTuple es) = CTuple (map (rewriteExprRP fo) es)
rewriteExprRP fo (CList es) = CList (map (rewriteExprRP fo) es)
rewriteExprRP fo (CRecord name fields) =
  normalizeRecordOrder fo name (map (rewriteFieldRP fo) fields)
rewriteExprRP fo (CFieldAccess ex f n) = CFieldAccess (rewriteExprRP fo ex) f n
rewriteExprRP fo (CRecordUpdate name base fields) =
  CRecordUpdate name (rewriteExprRP fo base) (map (rewriteFieldRP fo) fields)
rewriteExprRP fo (CVariantUpdate con base fields) =
  CVariantUpdate con (rewriteExprRP fo base) (map (rewriteFieldRP fo) fields)
rewriteExprRP fo (CArray es) = CArray (map (rewriteExprRP fo) es)
rewriteExprRP fo (CRangeList lo hi incl) =
  CRangeList (rewriteExprRP fo lo) (rewriteExprRP fo hi) incl
rewriteExprRP fo (CRangeArray lo hi incl) =
  CRangeArray (rewriteExprRP fo lo) (rewriteExprRP fo hi) incl
rewriteExprRP fo (CIndex a i) = CIndex (rewriteExprRP fo a) (rewriteExprRP fo i)
rewriteExprRP fo (CSlice a lo hi incl) =
  CSlice (rewriteExprRP fo a) (rewriteExprRP fo lo) (rewriteExprRP fo hi) incl
rewriteExprRP fo (CStringIndex a i) =
  CStringIndex (rewriteExprRP fo a) (rewriteExprRP fo i)
rewriteExprRP fo (CStringSlice a lo hi incl) =
  CStringSlice
    (rewriteExprRP fo a)
    (rewriteExprRP fo lo)
    (rewriteExprRP fo hi)
    incl
rewriteExprRP fo (CListIndex a i) =
  CListIndex (rewriteExprRP fo a) (rewriteExprRP fo i)
rewriteExprRP fo (CListSlice a lo hi incl) =
  CListSlice
    (rewriteExprRP fo a)
    (rewriteExprRP fo lo)
    (rewriteExprRP fo hi)
    incl
rewriteExprRP fo (CBlock stmts) = CBlock (map (rewriteStmtRP fo) stmts)
rewriteExprRP _ (CMethod name iface arity r ir mr) =
  CMethod name iface arity r ir mr
rewriteExprRP _ (CDict name rs) = CDict name rs

rewriteArmRP : List (String, List String) -> CArm -> CArm
rewriteArmRP fo (CArm pat guards body) =
  CArm
    (rewritePat fo pat)
    (map (rewriteGuardRP fo) guards)
    (rewriteExprRP fo body)

rewriteGuardRP : List (String, List String) -> CGuard -> CGuard
rewriteGuardRP fo (CGBool e) = CGBool (rewriteExprRP fo e)
rewriteGuardRP fo (CGBind p e) = CGBind (rewritePat fo p) (rewriteExprRP fo e)

rewriteStmtRP : List (String, List String) -> CStmt -> CStmt
rewriteStmtRP fo (CSExpr e) = CSExpr (rewriteExprRP fo e)
rewriteStmtRP fo (CSLet r pat e) =
  CSLet r (rewritePat fo pat) (rewriteExprRP fo e)
rewriteStmtRP fo (CSAssign x e) = CSAssign x (rewriteExprRP fo e)

rewriteFieldRP : List (String, List String) -> CField -> CField
rewriteFieldRP fo (CField k e) = CField k (rewriteExprRP fo e)

-- ── #1513: a record literal is laid out in DECLARED order, not written order ──
-- Both emit backends store a record cell POSITIONALLY, in the order the `CRecord`
-- node lists its fields, while every READER (`CFieldAccess`, `CRecordUpdate`, the
-- `PRec`→`PCon` rewrite above) indexes by the DECLARED order.  Their in-source
-- comments already assert the two coincide — "CRecord carries fields in DECLARED
-- order (lowering preserves it)", wasm_emit `emitRecordRef` — but nothing
-- established it: no pass reordered a literal, so `R { g = …, f = … }` built the
-- cell `[g, f]` and `r.f` read slot 1.  MEASURED on `main` before this change: a
-- program with `R { g = 20, f = 10 }` and `R { f = 30, g = 40 }` printed the
-- correct `10 30` under `medaka run` and a silent `10 40` from the built binary.
--
-- The rewrite makes the asserted invariant TRUE at the one point every emit driver
-- funnels through, so BOTH backends inherit it.  Field expressions are bound to
-- temporaries IN WRITTEN ORDER first and the `CRecord` then refers to those
-- temporaries, so an effectful field expression still runs when the source says it
-- does — reordering the *nodes* would have made `run` and `build` disagree about
-- evaluation order, trading one silent divergence for another.
--
-- Untouched, and byte-identical IR, when the literal is already in declared order
-- (the overwhelmingly common case) or when the labels cannot be matched up against
-- the declaration exactly once each — an anonymous record with no `data`, or a
-- malformed literal that a diagnostic elsewhere owns.  It is not this pass's job to
-- start dropping or duplicating fields on a shape it does not recognise.
normalizeRecordOrder : List (String, List String) ->
  String ->
  List CField ->
  CExpr
normalizeRecordOrder fo name fields = match lookupAssoc name fo
  None => CRecord name fields
  Some labels =>
    let written = map cFieldLabel fields
    if written == labels || not (isPermutationOf written labels) then
      CRecord name fields
    else
      bindFieldTemps fields (CRecord name (map recTempField labels))

-- every declared label appears exactly once among the written ones, and vice versa.
-- Lengths equal + every declared label written ⇒ a permutation, because the
-- typechecker already rejects a literal that names the same field twice
-- (T-DUPLICATE-FIELD) or one the record does not declare (T-UNKNOWN-FIELD).
isPermutationOf : List String -> List String -> Bool
isPermutationOf written labels =
  listLen written == listLen labels && allList (l => contains l written) labels

cFieldLabel : CField -> String
cFieldLabel (CField k _) = k

-- `$rf$<label>` cannot collide with a user binder (`$` is not an identifier
-- character) and is unique within one literal because its labels are.  A nested
-- literal's temporaries shadow only inside the field expression that contains it,
-- which is closed before the outer `CRecord` reads its own temporaries back.
recTempName : String -> String
recTempName label = "$rf$" ++ label

recTempField : String -> CField
recTempField label = CField label (CVar (recTempName label) AGlobal)

bindFieldTemps : List CField -> CExpr -> CExpr
bindFieldTemps [] body = body
bindFieldTemps ((CField k ex) :: rest) body =
  CLet
    False
    (PVar (recTempName k) (Loc "" 0 0 0 0))
    ex
    (bindFieldTemps rest body)

-- ── #719: nullary return-position impl-method CAF memoisation (emit backends) ──
-- A point-free (nullary) RETURN-POSITION impl method at a fixed concrete type
-- (`theUnit : a`; RKey-dispatched, no discriminating argument) is a per-instance
-- CAF: eval evaluates its body ONCE and shares the value at every occurrence at
-- that type (eval.mdk implMethodValue/memoThunk, TYPECHECK-AUDIT C6).  Both emit
-- backends, however, lowered each occurrence to a fresh `call
-- @mdk_impl_<tag>_<method>()`, re-running the body — duplicating any side effect
-- (issue #719, silent run /= build on the LLVM and WasmGC backends).
--
-- Fix (emit-only, so BOTH backends inherit it via lowerProgramEmit — the eval arm
-- already memoises): HOIST each such occurrence to a synthesized top-level value
-- binding `$memo_<tag>_<method> = <the nullary CMethod>` and replace the occurrence
-- with a reference to it.  The existing top-level value-global CAF machinery (#561
-- lazy globals) then computes the body once, memoises it, and black-holes a cyclic
-- self-force into E-CYCLIC-VALUE — the SAME machinery that already makes a top-level
-- `x = theUnit : Box` correct on both backends.  No new memo infrastructure.
--
-- Gated to EXACTLY eval's memoThunk case: an RKey route with NO nested (parametric-
-- impl) dicts and NO impl/method dict routes (`CMethod _ 0 (RKey tag []) [] []`), whose
-- resolved impl is RETURN-position (`positions == []`) AND point-free (`pats == []`).
-- A method WITH arguments (non-empty pats), a discriminating-arg method (non-empty
-- positions), a runtime-dict route (RDict/RDictFwd), or a dict-parametric impl
-- (non-empty routes) is NOT hoisted — it keeps its per-call semantics.
--
-- Only occurrences that ACTUALLY appear are hoisted: the walk records each rewritten
-- (tag, method) into `LowerState.memoRefs` (declared below).  That collector is a Ref
-- so the structural walk stays one pass without tupling an accumulator through every
-- CExpr case — but it is a field of the per-emission carrier, not a module-scope Ref
-- reset by convention on entry (#1954).

-- the (method, key, SELECTOR) instances that are per-instance CAFs — see the gate
-- above.  An RKey occurrence carries the instance's canonical `key`, which is what
-- the walk matches.  The selector only NAMES the CAF: the bare head when this is the
-- SOLE impl at (method, head), else the key (TYPECHECK-AUDIT C7) — the emitters'
-- `implFnSymTag` choice, so a dispatcher arm finds the CAF under its symbol tag.
memoKeys : List CImplEntry -> List (String, String, String)
memoKeys entries = memoKeysGo entries entries

memoKeysGo : List CImplEntry -> List CImplEntry -> List (String, String, String)
memoKeysGo _ [] = []
memoKeysGo all ((CImplEntry m _ (CImplTagged tag key _ positions pats _)) :: rest)
  | isEmptyL positions && isEmptyL pats =
    (m, key, memoSelector all m tag key) :: memoKeysGo all rest
memoKeysGo all ((CImplEntry m _ (CImplDefault _ tag key positions pats _)) :: rest)
  | isEmptyL positions && isEmptyL pats =
    (m, key, memoSelector all m tag key) :: memoKeysGo all rest
memoKeysGo all (_ :: rest) = memoKeysGo all rest

-- the symbol tag of (method, head-tag): the bare head when the head is the sole impl
-- of (method, head), else the canonical C7 key.
memoSelector : List CImplEntry -> String -> String -> String -> String
memoSelector all method tag key =
  if headTagUniqueL all method tag then tag else key

-- does the head tycon [tag] of [method] have a single impl, or several distinct C7
-- keys (a same-head collision)?  Counts DISTINCT keys, not raw entries (the joint
-- prelude+module list duplicates each prelude impl, and a multi-clause impl
-- contributes several entries sharing one key).  Mirror of llvm_emit.headTagUnique.
headTagUniqueL : List CImplEntry -> String -> String -> Bool
headTagUniqueL entries method tag =
  listLen (distinctKeysAtHeadL entries method tag []) <= 1

distinctKeysAtHeadL : List CImplEntry ->
  String ->
  String ->
  List String ->
  List String
distinctKeysAtHeadL [] _ _ acc = acc
distinctKeysAtHeadL ((CImplEntry n _ (CImplTagged t k _ _ _ _)) :: rest) method tag acc
  | n == method && t == tag && not (contains k acc) =
    distinctKeysAtHeadL rest method tag (k :: acc)
  | otherwise = distinctKeysAtHeadL rest method tag acc
distinctKeysAtHeadL ((CImplEntry n _ (CImplDefault _ t k _ _ _)) :: rest) method tag acc
  | n == method && t == tag && not (contains k acc) =
    distinctKeysAtHeadL rest method tag (k :: acc)
  | otherwise = distinctKeysAtHeadL rest method tag acc
distinctKeysAtHeadL (_ :: rest) method tag acc =
  distinctKeysAtHeadL rest method tag acc

-- the CAF selector of the memoisable instance of [m] whose canonical key is [key]
memoSelectorOf : List (String, String, String) ->
  String ->
  String ->
  Option String
memoSelectorOf [] _ _ = None
memoSelectorOf ((m2, k2, sel) :: rest) m key =
  if m == m2 && key == k2 then Some sel else memoSelectorOf rest m key

-- #731 item 1: the (method, selector) instances whose dispatch is UNAMBIGUOUS by
-- STATIC KNOWLEDGE regardless of route — exactly one tagged impl and no interface
-- default.  Such a nullary method reached through a runtime-dict route (RDict/
-- RDictFwd — a polymorphic caller forwarding a concrete dict) can only ever resolve
-- to that ONE impl, so its per-instance CAF is statically the same one an RKey
-- occurrence would name and is hoistable identically.  A method with ≥2 impls needs
-- the RUNTIME-resolved tag (not statically hoistable) and is left per-call — the
-- residual multi-impl RDict case tracked separately.  Subset of `keys` (already
-- nullary/return-position/no-requires), so it never over-memoises past eval.
soleMemoKeys : List CImplEntry ->
  List (String, String, String) ->
  List (String, (String, String))
soleMemoKeys _ [] = []
soleMemoKeys entries ((m, key, sel) :: rest)
  | taggedImplCount entries m 1 == 1 =
    (m, (key, sel)) :: soleMemoKeys entries rest
  | otherwise = soleMemoKeys entries rest

-- distinct C7 keys of [method]'s tagged impls (short-circuits at [cap]: this only
-- ever asks "is it exactly 1?", so counting past 2 is wasted work on a big table).
taggedImplCount : List CImplEntry -> String -> Int -> Int
taggedImplCount entries method cap =
  listLen (distinctImplKeysL entries method cap [])

distinctImplKeysL : List CImplEntry ->
  String ->
  Int ->
  List String ->
  List String
distinctImplKeysL [] _ _ acc = acc
distinctImplKeysL _ _ cap acc
  | listLen acc > cap = acc
distinctImplKeysL ((CImplEntry n _ (CImplTagged _ k _ _ _ _)) :: rest) method cap acc
  | n == method && not (contains k acc) =
    distinctImplKeysL rest method cap (k :: acc)
  | otherwise = distinctImplKeysL rest method cap acc
distinctImplKeysL ((CImplEntry n _ (CImplDefault _ _ k _ _ _)) :: rest) method cap acc
  | n == method && not (contains k acc) =
    distinctImplKeysL rest method cap (k :: acc)
  | otherwise = distinctImplKeysL rest method cap acc
distinctImplKeysL (_ :: rest) method cap acc =
  distinctImplKeysL rest method cap acc

-- ── LowerState — the per-emission hoist carrier (#1954) ──────────────────────
-- Constructed once per `hoistNullaryMemo` call and threaded explicitly through the
-- whole hoist walk, in place of three module-scope `Ref`s that were reset-on-entry
-- by convention.  It REPLACES the walk's existing `keys` parameter rather than
-- riding alongside it, so no walk function gained an argument.
--
--   • `memoKeysAll` — #747: ALL (method, key, selector) memo rows of the program
--     (nullary/return-position/no-requires impls), computed once in
--     `hoistNullaryMemo`.  This is one value serving what would otherwise be two: the
--     `keys` parameter the walk threaded (read by `hoistExpr`'s `memoSelectorOf` gate)
--     and `allMemoKeysRef`, which `hoistNullaryMemo` always assigned that same
--     `keys`.  Read by the RDict/RDictFwd MULTI-impl arm of `hoistDictNullary` to
--     enumerate every impl tag of the method so a `$memo_<selector>_<method>` CAF
--     is synthesized for each.  The occurrence stays a runtime dispatch; the emit
--     backends' dispatch chain forces the matching per-tag CAF (per-runtime-tag
--     memoisation), so each resolved tag's side effect fires once — the same
--     sharing eval's per-VTypedImpl memoThunk gives regardless of route.
--   • `soleKeys` — the (method, (key, selector)) instances hoistable through a runtime-dict
--     route (#731 item 1).  Read only by the RDict/RDictFwd `hoistExpr` arm.
--   • `memoRefs` — the walk's collector of rewritten (selector, key, method) rows.  The one
--     mutable field, and the only reason the carrier holds a `Ref` at all.
--
-- Adding a field is one line here plus the one construction site in
-- `hoistNullaryMemo`: every walk function already takes the whole record.
data LowerState = LowerState {
  memoKeysAll : List (String, String, String),
  soleKeys : List (String, (String, String)),
  memoRefs : Ref (List (String, String, String)),
}

-- the synthesized CAF binding name for a memoised (selector, method) instance.  The
-- `$` prefix is the internal-binder convention (cf. composeVar `$cf`), so it cannot
-- collide with a user/prelude binding; it flows verbatim into `@mdk_g_<name>`.  The
-- selector is encoded with `private_mangle.injectiveIdent`, the shared emitted-
-- identifier encoding: a C7 key carries `|`/`(`/`)`/spaces, none legal in that
-- global symbol, and a module-qualified head tag (`app.T`) carries a dot.  A
-- prelude or builtin head tag is alphanumeric, and `injectiveIdent` is the
-- identity on such strings.
--
-- ⚠️ It was `sanitizeId` until #1950, and that is a SECOND, independent instance of
-- that bug, one symbol family over: `sanitizeId` is MANY-TO-ONE, so two impls whose
-- C7 keys differ only in `[^A-Za-z0-9_]` positions were given ONE `$memo_` CAF —
-- surfacing as a raw `invalid redefinition of function 'mdk_force_$memo_…'` from
-- clang.  `implSymbolCollisionGuard` below never covered this family (its SCOPE is
-- `mdk_impl_*`), so the encoder is the only thing keeping these names apart.
memoBindName : String -> String -> String
memoBindName selector method = "$memo_\{injectiveIdent selector}_\{method}"

recordMemoRef : LowerState -> String -> String -> String -> Unit
recordMemoRef st sel key method =
  let refs = st.memoRefs in refs := (sel, key, method) :: !refs

-- #731 item 1 / #747: rewrite a runtime-dict-routed nullary occurrence.
--   • single-impl (`st.soleKeys`): the runtime dict can only ever resolve to the
--     ONE impl, so hoist the occurrence itself to that shared CAF (statically the
--     same one an RKey occurrence names) — #731 item 1, unchanged.
--   • multi-impl (#747): the resolved tag is only known at runtime, so the occurrence
--     STAYS a dispatch — but synthesize a `$memo_<selector>_<method>` CAF for EVERY
--     impl tag of the method (recordMultiImplMemo).  The emit backends' dispatch chain
--     forces the matching per-tag CAF instead of re-calling the impl fn, so each
--     resolved tag's side effect fires once, shared across routes (matching eval's
--     per-VTypedImpl memoThunk).  Distinct tags carry distinct CAFs → memoise
--     independently.  A method with no nullary/return-position impl records nothing.
hoistDictNullary : LowerState -> String -> String -> Route -> CExpr
hoistDictNullary st name iface route = match lookupAssoc name st.soleKeys
  Some (key, sel) =>
    let _ = recordMemoRef st sel key name
    CVar (memoBindName sel name) AGlobal
  None =>
    let _ = recordMultiImplMemo st name
    CMethod name iface 0 route [] []

-- #747: synthesize one per-tag CAF for every nullary/return-position impl of a
-- multi-impl method reached via a runtime-dict route.  Records each (selector, method)
-- into `st.memoRefs` so hoistNullaryMemo prepends a `$memo_<selector>_<method>` value
-- bind (dedupPairs collapses repeats).  Only fires for methods that appear in the
-- program's memo keys — a nullary occurrence of a NON-memoisable method records
-- nothing, leaving its per-call dispatch untouched.
recordMultiImplMemo : LowerState -> String -> Unit
recordMultiImplMemo st name = recordMultiImplMemoGo st name st.memoKeysAll

recordMultiImplMemoGo : LowerState ->
  String ->
  List (String, String, String) ->
  Unit
recordMultiImplMemoGo _ _ [] = ()
recordMultiImplMemoGo st name ((m, key, sel) :: rest)
  | m == name =
    let _ = recordMemoRef st sel key name
    recordMultiImplMemoGo st name rest
  | otherwise = recordMultiImplMemoGo st name rest

-- the whole-program hoist: rewrite every memoisable occurrence to a CAF reference,
-- then prepend one synthesized CAF value-bind per referenced instance.  A no-op (the
-- byte-identical old program) when the program defines no memoisable nullary method.
hoistNullaryMemo : CProgram -> CProgram
hoistNullaryMemo (CProgram groups ctorArs ctorTypes implEntries) =
  let keys = memoKeys implEntries
  if isEmptyL keys then
    CProgram groups ctorArs ctorTypes implEntries
  else
    let st = LowerState {
      memoKeysAll = keys,
      soleKeys = soleMemoKeys implEntries keys,
      memoRefs = Ref [],
    }
    let groups2 = map (hoistBind st) groups
    let impls2 = map (hoistImpl st) implEntries
    let refs = dedupPairs (reverseL !st.memoRefs)
    CProgram (map memoCafBind refs ++ groups2) ctorArs ctorTypes impls2

memoCafBind : (String, String, String) -> CBind
memoCafBind (sel, key, method) =
  CBind
    (memoBindName sel method)
    [CClause [] (CMethod method "" 0 (RKey key [] []) [] [])]
    noDeclLoc

-- #242: routed through the canonical O(n·log n) `support.util.dedupBy` (was a
-- private O(n²) `List`-as-a-set scan).  Both components are unconstrained
-- Strings, so the key length-prefixes the first — a bare separator would not be
-- injective.  Same first-occurrence order, so the memo-CAF binds are unchanged.
dedupPairs : List (String, String, String) -> List (String, String, String)
dedupPairs ps = dedupBy memoRefKey ps

memoRefKey : (String, String, String) -> String
memoRefKey (sel, _, method) = lenKey sel ++ method

hoistBind : LowerState -> CBind -> CBind
hoistBind st (CBind n clauses site) =
  CBind n (map (hoistClause st) clauses) site

hoistClause : LowerState -> CClause -> CClause
hoistClause st (CClause pats body) = CClause pats (hoistExpr st body)

hoistImpl : LowerState -> CImplEntry -> CImplEntry
hoistImpl st (CImplEntry n s (CImplTagged tag key iface pos pats body)) =
  CImplEntry n s (CImplTagged tag key iface pos pats (hoistExpr st body))
hoistImpl st (CImplEntry n s (CImplDefault ifaceId tag key pos pats body)) =
  CImplEntry n s (CImplDefault ifaceId tag key pos pats (hoistExpr st body))

-- the structural walk (mirrors rewriteExprRP), rewriting ONLY the gated CMethod
-- occurrence; everything else recurses unchanged.
hoistExpr : LowerState -> CExpr -> CExpr
hoistExpr st (CMethod name iface 0 (RKey key [] sups) [] []) =
  match memoSelectorOf st.memoKeysAll name key
    Some sel =>
      let _ = recordMemoRef st sel key name
      CVar (memoBindName sel name) AGlobal
    None => CMethod name iface 0 (RKey key [] sups) [] []
-- #731 item 1: a nullary return-position method reached via a runtime-dict route
-- (RDictFwd from a polymorphic caller forwarding a concrete dict, or a plain RDict)
-- resolves — when the method has exactly one impl and no default — statically to
-- that one impl.  eval memoises it globally per resolved tag (the SAME memoThunk a
-- direct RKey occurrence hits); hoist it to the SAME CAF the RKey path uses so the
-- side effect fires once on build too, shared across routes.  A multi-impl method's
-- tag is only known at runtime, so it stays a per-call dispatch (unchanged).
hoistExpr st (CMethod name iface 0 (RDict d) [] []) =
  hoistDictNullary st name iface (RDict d)
hoistExpr st (CMethod name iface 0 (RDictFwd d) [] []) =
  hoistDictNullary st name iface (RDictFwd d)
hoistExpr st (CMethod name iface 0 (RProj r path) [] []) =
  hoistDictNullary st name iface (RProj r path)
hoistExpr _ (CMethod name iface arity r ir mr) =
  CMethod name iface arity r ir mr
hoistExpr _ (CLit l) = CLit l
hoistExpr _ (CVar x addr) = CVar x addr
hoistExpr st (CApp f x) = CApp (hoistExpr st f) (hoistExpr st x)
hoistExpr st (CLam pats body) = CLam pats (hoistExpr st body)
hoistExpr st (CLet r pat e1 e2) = CLet r pat (hoistExpr st e1) (hoistExpr st e2)
hoistExpr st (CLetGroup binds body) =
  CLetGroup (map (hoistBind st) binds) (hoistExpr st body)
hoistExpr st (CMatch scrut arms) =
  CMatch (hoistExpr st scrut) (map (hoistArm st) arms)
hoistExpr st (CDecision scrut arms tree) =
  CDecision (hoistExpr st scrut) (map (hoistArm st) arms) tree
hoistExpr st (CIf c t e) =
  CIf (hoistExpr st c) (hoistExpr st t) (hoistExpr st e)
hoistExpr st (CBinPrim op l r tag site) =
  CBinPrim op (hoistExpr st l) (hoistExpr st r) tag site
hoistExpr st (CUnOp op x) = CUnOp op (hoistExpr st x)
hoistExpr st (CTuple es) = CTuple (map (hoistExpr st) es)
hoistExpr st (CList es) = CList (map (hoistExpr st) es)
hoistExpr st (CRecord name fields) = CRecord name (map (hoistField st) fields)
hoistExpr st (CFieldAccess ex f n) = CFieldAccess (hoistExpr st ex) f n
hoistExpr st (CRecordUpdate name base fields) =
  CRecordUpdate name (hoistExpr st base) (map (hoistField st) fields)
hoistExpr st (CVariantUpdate con base fields) =
  CVariantUpdate con (hoistExpr st base) (map (hoistField st) fields)
hoistExpr st (CArray es) = CArray (map (hoistExpr st) es)
hoistExpr st (CRangeList lo hi incl) =
  CRangeList (hoistExpr st lo) (hoistExpr st hi) incl
hoistExpr st (CRangeArray lo hi incl) =
  CRangeArray (hoistExpr st lo) (hoistExpr st hi) incl
hoistExpr st (CIndex a i) = CIndex (hoistExpr st a) (hoistExpr st i)
hoistExpr st (CSlice a lo hi incl) =
  CSlice (hoistExpr st a) (hoistExpr st lo) (hoistExpr st hi) incl
hoistExpr st (CStringIndex a i) = CStringIndex (hoistExpr st a) (hoistExpr st i)
hoistExpr st (CStringSlice a lo hi incl) =
  CStringSlice (hoistExpr st a) (hoistExpr st lo) (hoistExpr st hi) incl
hoistExpr st (CListIndex a i) = CListIndex (hoistExpr st a) (hoistExpr st i)
hoistExpr st (CListSlice a lo hi incl) =
  CListSlice (hoistExpr st a) (hoistExpr st lo) (hoistExpr st hi) incl
hoistExpr st (CBlock stmts) = CBlock (map (hoistStmt st) stmts)
hoistExpr _ (CDict name rs) = CDict name rs

hoistArm : LowerState -> CArm -> CArm
hoistArm st (CArm pat guards body) =
  CArm pat (map (hoistGuard st) guards) (hoistExpr st body)

hoistGuard : LowerState -> CGuard -> CGuard
hoistGuard st (CGBool e) = CGBool (hoistExpr st e)
hoistGuard st (CGBind p e) = CGBind p (hoistExpr st e)

hoistStmt : LowerState -> CStmt -> CStmt
hoistStmt st (CSExpr e) = CSExpr (hoistExpr st e)
hoistStmt st (CSLet r pat e) = CSLet r pat (hoistExpr st e)
hoistStmt st (CSAssign x e) = CSAssign x (hoistExpr st e)

hoistField : LowerState -> CField -> CField
hoistField st (CField k e) = CField k (hoistExpr st e)

-- recompile a CDecision's tree from rewritten arms (same call lowerMatch makes).
compileArmsC : FailSite -> List CArm -> CTree
compileArmsC site arms =
  compileTree site (map carmHasGuard arms) (cInitialRows arms 0)

carmHasGuard : CArm -> Bool
carmHasGuard (CArm pat gs _) = isNonEmptyL gs || patNeedsGuard pat

cInitialRows : List CArm -> Int -> List (List Pat, Int)
cInitialRows [] _ = []
cInitialRows ((CArm pat _ _) :: rest) i =
  ([canonPat pat], i) :: cInitialRows rest (i + 1)

-- the top-level function-group half of lowerProgram, exposed for the multi-module
-- driver (core_ir_eval.cevalModules), which lowers each module's groups separately
-- (per-module local frames) rather than as one flat program.
export
lowerGroups : List Decl -> List CBind
lowerGroups prog = map (refoldBind noLetCheck) (lowerGroupsRaw prog)

lowerGroupsRaw : List Decl -> List CBind
lowerGroupsRaw prog = lgGroup (bindSites prog omEmpty) (funClausesOf prog)

-- O(n log n) group-by-name, IDENTICAL output to
-- `map (n => CBind n (clausesFor n clauses)) (groupNames clauses [])`: preserves
-- clause order within a name AND first-occurrence order of names, via an
-- index-carrying merge sort (no map, no typeclass dispatch). Replaces the old
-- O(names·clauses) groupNames+clausesFor rescan. Elements are ((name, idx), clause).
lgGroup : OrdMap Loc -> List (String, CClause) -> List CBind
lgGroup sites clauses =
  let groups = lgRuns (lgSortName (lgTag clauses 0))
  map (lgToBind sites) (lgSortIdx groups)

lgTag : List (String, CClause) -> Int -> List ((String, Int), CClause)
lgTag [] _ = []
lgTag ((n, c) :: rest) i = ((n, i), c) :: lgTag rest (i + 1)

lgSplit : List a -> (List a, List a)
lgSplit [] = ([], [])
lgSplit [x] = ([x], [])
lgSplit (x :: y :: rest) =
  let (a, b) = lgSplit rest
  (x :: a, y :: b)

-- merge sort by name, ascending-index tiebreak (stable ⇒ clause order preserved).
lgSortName : List ((String, Int), CClause) -> List ((String, Int), CClause)
lgSortName [] = []
lgSortName [x] = [x]
lgSortName xs =
  let (a, b) = lgSplit xs
  lgMergeName (lgSortName a) (lgSortName b)

lgMergeName : List ((String, Int), CClause) ->
  List ((String, Int), CClause) ->
  List ((String, Int), CClause)
lgMergeName [] ys = ys
lgMergeName xs [] = xs
lgMergeName (((n1, i1), c1) :: xs) (((n2, i2), c2) :: ys) =
  match stringCompare n1 n2
    Lt => ((n1, i1), c1) :: lgMergeName xs (((n2, i2), c2) :: ys)
    Gt => ((n2, i2), c2) :: lgMergeName (((n1, i1), c1) :: xs) ys
    Eq =>
      if i1 <= i2 then
        ((n1, i1), c1) :: lgMergeName xs (((n2, i2), c2) :: ys)
      else
        ((n2, i2), c2) :: lgMergeName (((n1, i1), c1) :: xs) ys

-- collapse runs of equal name (now contiguous, index-ascending) into
-- ((name, firstIdx), clausesInOrder).
lgRuns : List ((String, Int), CClause) -> List ((String, Int), List CClause)
lgRuns [] = []
lgRuns (((n, i), c) :: rest) =
  let (cs, others) = lgSpan n rest
  ((n, i), c :: cs) :: lgRuns others

lgSpan : String ->
  List ((String, Int), CClause) ->
  (List CClause, List ((String, Int), CClause))
lgSpan _ [] = ([], [])
lgSpan n (((m, j), c) :: rest) =
  if m == n then
    let (cs, o) = lgSpan n rest
    (c :: cs, o)
  else
    ([], ((m, j), c) :: rest)

-- order groups by first-occurrence index (== groupNames order).
lgSortIdx : List ((String, Int), List CClause) ->
  List ((String, Int), List CClause)
lgSortIdx [] = []
lgSortIdx [x] = [x]
lgSortIdx xs =
  let (a, b) = lgSplit xs
  lgMergeIdx (lgSortIdx a) (lgSortIdx b)

lgMergeIdx : List ((String, Int), List CClause) ->
  List ((String, Int), List CClause) ->
  List ((String, Int), List CClause)
lgMergeIdx [] ys = ys
lgMergeIdx xs [] = xs
lgMergeIdx (((n1, i1), cs1) :: xs) (((n2, i2), cs2) :: ys) =
  if i1 <= i2 then
    ((n1, i1), cs1) :: lgMergeIdx xs (((n2, i2), cs2) :: ys)
  else
    ((n2, i2), cs2) :: lgMergeIdx (((n1, i1), cs1) :: xs) ys

lgToBind : OrdMap Loc -> ((String, Int), List CClause) -> CBind
lgToBind sites ((n, _), cs) = match omLookup n sites
  Some site => CBind n cs site
  None => CBind n cs noDeclLoc

-- name -> the site of its first clause, over the decls `funClausesOf` reads.
bindSites : List Decl -> OrdMap Loc -> OrdMap Loc
bindSites [] acc = acc
bindSites ((DFunDef _ n _ _ site) :: rest) acc =
  bindSites rest (firstSite n site acc)
bindSites ((DLetGroup _ binds) :: rest) acc =
  bindSites rest (letBindSites binds acc)
bindSites ((DAttrib _ d) :: rest) acc = bindSites (d :: rest) acc
bindSites (_ :: rest) acc = bindSites rest acc

letBindSites : List LetBind -> OrdMap Loc -> OrdMap Loc
letBindSites [] acc = acc
letBindSites ((LetBind n _ site) :: rest) acc =
  letBindSites rest (firstSite n site acc)

firstSite : String -> Loc -> OrdMap Loc -> OrdMap Loc
firstSite n site acc = if omHasKey n acc then acc else omInsert n site acc

-- ── typeclass impls / interface defaults (slice 5) ─────────────────────────
-- Mirror eval.mdk's `declImplEntries` exactly: build the iface dispatch-position
-- table once, then emit one CImplEntry per impl-method clause (tagged by the
-- impl's concrete type head) and per interface default (untagged fallback).  The
-- method BODY is lowered to CExpr; the tag / positions / score are pure AST
-- computations reused from eval.mdk so the Core IR stays Ty-free.
-- #315/#413: installDispatchTables both BUILDS the dispatch table (as
-- buildIfaceDispatch did) and installs it alongside the method reqCount table that
-- applyMethodDicts consults.  cevalProgram is handed a CProgram and so has no decls
-- of its own to derive them from; lowering is the last point that still does.
-- Without this the Core-IR interpreter's reqCount lookups all returned None and
-- #413's fix was inert there (proven: `impl S (List a) requires S a where s _ = 2`
-- ran correctly under `medaka run` but panicked "applied non-function: 2" under
-- core_ir_typed_main).  The emit path lowers through here too and never reads the
-- tables, so installing is a no-op for it.

-- ── the declared impls, read off the impl DECLS ────────────────────────────────
-- One row per DECLARED impl: (iface identity, iface, head tag, canonical impl key).
-- `lowerDeclImpl` projects a `DImpl` to one `CImplEntry` per method it defines, so an
-- impl that inherits every method has no entry of its own; this table still lists it.
-- The head tag and key are computed exactly as `lowerImplMethod` computes an entry's
-- (`optionOr noneHeadTag (headTyconHead tys)`, `implRouteKeyWord implOrigin iface tys
-- None`), matched arm-for-arm with `lowerDeclImpl`, `DAttrib` unwrapping included
-- (#1037).  Its reader is `llvm_emit.preludeImplSymbols`, which needs the prelude's
-- own instances by key.
export
ifaceImplHeadTable : List Decl -> List (String, String, String, String)
ifaceImplHeadTable prog = flatMap ifaceImplHeadEntries prog

ifaceImplHeadEntries : Decl -> List (String, String, String, String)
-- #1037: matched arm-for-arm with `lowerDeclImpl`, which now unwraps `DAttrib` too.
ifaceImplHeadEntries (DAttrib _ d) = ifaceImplHeadEntries d
ifaceImplHeadEntries (DImpl { iface = ifaceName, implOrigin = o, tys = typeArgs, ... }) = [
  (
    ifaceIdentity o ifaceName,
    ifaceName,
    optionOr noneHeadTag (headTyconHead typeArgs),
    implRouteKeyWord o ifaceName typeArgs None,
  ),
]
ifaceImplHeadEntries _ = []

-- ── emitted impl-symbol collision guard (#1950) ───────────────────────────────
-- An impl method is emitted as `mdk_impl_<symTag>_<method>`, where `symTag` is the
-- bare head tag when that head is the SOLE impl of (method, head), and otherwise
-- (TYPECHECK-AUDIT C7) the canonical dispatch key run through
-- `private_mangle.injectiveIdent` — the SAME encoding both backends use
-- (`llvm_emit.implFnSymTag`, `wasm_emit.implFnSymTagW`) and the one called here.
--
-- ⚠️ THIS GUARD IS NO LONGER FIREABLE FOR THE #1950 CLASS, BY CONSTRUCTION — AND IS
-- KEPT ANYWAY.  It catches a real collision class: spelling the C7 key
-- with the MANY-TO-ONE `sanitizeId` (everything outside [A-Za-z0-9_] → `_`) makes two
-- impls whose keys differ ONLY in those characters (`Sz|(Q A_B C)|` vs
-- `Sz|(Q A B_C)|`) land on ONE emitted symbol and reach the user as a RAW,
-- UNLOCATED clang `invalid redefinition of function` (#1950).  `injectiveIdent`
-- removed the collapse at its source, so no two distinct keys can reach one symbol
-- through this arm any more.  What survives here is the ASSERTION — (method, tag,
-- key) → symbol is injective — a real invariant of the emitted-symbol scheme that a
-- future change to either backend's tag rule could otherwise break silently.  Its
-- live surface is narrower than that invariant: see SCOPE below, in particular that
-- it never covered #1397's identical-pre-image shape.  Anything it does print now
-- describes a defect in the SCHEME, not a user naming mistake.
--
-- ⚠️ NOT BY SOURCE LINE, and that is a property of the pipeline, not of this site.
-- MEASURED: every emit driver parses through `parser.parse` (`entry_support`'s
-- `readAllDecls`/`driveModulesGo`) or `loader.loadProgram`, both of which use the
-- PLACEHOLDER-LOC parser — only `parseLocated`/`parseLocatedResult` (the `check`
-- and LSP paths) populate spans, and even those leave `Loc`'s `file` field "" for
-- the caller to fill.  Printing
-- `firstTyLocList`'s answer here gives `:1:0` for BOTH impls of the repro — a wrong
-- location is worse than none, so the canonical dispatch key (which is
-- `<module>::<Iface>|<type args>|`, i.e. exactly the impl's declared identity) is
-- what the message names instead.  Giving the emit path real spans is a
-- pipeline-wide change and is deliberately not attempted here.
--
-- Sited HERE, not in either backend, for the reason `private_mangle`'s own guard
-- states for itself: `lowerProgramEmit` is the ONE seam every emit driver of BOTH
-- backends funnels through (`llvm_emit_*_main`, `wasm_emit_*_main`, the playground,
-- `tools/snapshot.mdk`, the dump probes), so one check serves all of them instead of
-- a fifth and sixth per-backend copy of the collision predicate desyncing.  The rows
-- are read off the DECLARATIONS — matched arm-for-arm with `lowerDeclImpl`, DAttrib
-- unwrapping included (#1037) — because `CImplEntry` carries no source location and
-- an unlocated refusal would only trade one unlocated message for another.
-- Enumerating `methods` gives exactly the (method, tag, key) triples
-- `lowerImplMethod` mints for the same `prog`, so the domain is the entry set, not
-- an approximation of it.
--
-- SCOPE — stated out loud, because a partial check cited as a total one is how this
-- bug class survives:
--   * covers TAGGED IMPL METHOD symbols only.  Interface DEFAULTS
--     (`mdk_default_<method>_<injectiveIdent tag>`), the per-instance `$memo_` CAFs
--     (`memoBindName`) and emitter-gensym'd lambdas/etas are minted elsewhere and
--     are NOT checked here.
--   * it is a check on DISTINCT PRE-IMAGES.  Rows are deduplicated by
--     (method, head tag, canonical key) FIRST, so two impls that are already
--     IDENTICAL in that triple pass through here.  Two modules' same-spelled
--     types never are (#1397): a head tag and a route word carry the type's
--     module (`route_key.typeTagOf`, injective by construction), and the symbol
--     spells that tag through `injectiveIdent`.
--   * it is likewise NOT a duplicate-clause check: a legitimate multi-clause impl
--     contributes several rows sharing ONE key, and the joint prelude+module decl
--     list duplicates each prelude impl.  Both collapse in the dedup and can never
--     fire this.
--   * it observes the symbol the backends are about to mint; it does not change the
--     mangling scheme.  Every collision-free program emits byte-identical IR.
implSymbolCollisionGuard : List Decl -> Unit
implSymbolCollisionGuard prog =
  let rows = dedupImplSymRows (flatMap implSymRowsOf prog) omEmpty
  checkImplSymbolsInjective (collidingHeads rows omEmpty omEmpty) rows omEmpty

-- one row per lowered impl-method clause: (method, head tag, canonical key).
-- Matched arm-for-arm with `lowerDeclImpl` — same DAttrib unwrap, same `methods`
-- traversal, and the tag/key computed by the SAME two expressions `lowerImplMethod`
-- uses, so the two cannot drift apart on a program.
implSymRowsOf : Decl -> List (String, String, String)
implSymRowsOf (DAttrib _ d) = implSymRowsOf d
implSymRowsOf (DImpl { iface = ifaceName, implOrigin = o, tys = typeArgs, methods, ... }) =
  map
    (implSymRow
      (optionOr noneHeadTag (headTyconHead typeArgs))
      (implRouteKeyWord o ifaceName typeArgs None))
    methods
implSymRowsOf _ = []

implSymRow : String -> String -> ImplMethod -> (String, String, String)
implSymRow tag key (ImplMethod mname _ _) = (mname, tag, key)

-- distinct pre-images, first arrival wins.  This is what keeps #1397's shape and
-- every multi-clause impl out of the check — see the SCOPE paragraph above.
dedupImplSymRows : List (String, String, String) ->
  OrdMap Unit ->
  List (String, String, String)
dedupImplSymRows [] _ = []
dedupImplSymRows ((m, tag, key) :: rest) seen
  | omHasKey (implPreImageKey m tag key) seen = dedupImplSymRows rest seen
  | otherwise =
    (m, tag, key)
      :: dedupImplSymRows rest (omInsert (implPreImageKey m tag key) () seen)

-- `\n` cannot occur in a method name, a head tag or a route word, so this is an
-- injective rendering of the triple and safe as a set key.
implPreImageKey : String -> String -> String -> String
implPreImageKey m tag key = "\{m}\n\{tag}\n\{key}"

-- the (method, head tag) pairs carrying ≥2 DISTINCT canonical keys — i.e. exactly
-- the pairs `headTagUnique`/`headTagUniqueW` answer False for, so exactly the ones
-- whose symbols take the sanitized-key arm.  Computed ONCE, in O(n log n) through the
-- weight-balanced tree, rather than re-scanned per row: the emitters can afford the
-- linear `distinctKeysAtHead` count because they call it per METHOD BUCKET (#990),
-- and this guard sees the whole program at once.
collidingHeads : List (String, String, String) ->
  OrdMap String ->
  OrdMap Unit ->
  OrdMap Unit
collidingHeads [] _ acc = acc
collidingHeads ((m, tag, key) :: rest) firstKey acc =
  match omLookup (implHeadKey m tag) firstKey
    None => collidingHeads rest (omInsert (implHeadKey m tag) key firstKey) acc
    Some k0 =>
      if k0 == key then
        collidingHeads rest firstKey acc
      else
        collidingHeads rest firstKey (omInsert (implHeadKey m tag) () acc)

implHeadKey : String -> String -> String
implHeadKey m tag = "\{m}\n\{tag}"

-- injectivity of (method, tag, key) -> emitted symbol, one pass, O(n log n) through
-- the same weight-balanced tree `private_mangle`'s guard uses.  Rows are already
-- distinct pre-images, so ANY second arrival at one symbol is a genuine collision.
--
-- ⚠️ The three data lines are UNINDENTED on purpose: they are CONTENT-derived (the
-- symbol and the two dispatch keys), so a `stdout-line` pin can match them with
-- `grep -qxF` against a whitespace-stripped claim value without false-draining on a
-- rewording of the prose around them.  Keep them flush-left if this message is ever
-- pinned again.
checkImplSymbolsInjective : OrdMap Unit ->
  List (String, String, String) ->
  OrdMap String ->
  Unit
checkImplSymbolsInjective _ [] _ = ()
checkImplSymbolsInjective collide ((m, tag, key) :: rest) seen =
  let sym = "mdk_impl_\{implSymTagOf collide m tag key}_\{m}"
  match omLookup sym seen
    None => checkImplSymbolsInjective collide rest (omInsert sym key seen)
    Some prev =>
      panic
        "emitted impl-symbol collision: two DISTINCT impls of method `\{m}` are emitted under one symbol.\ncollided symbol: \{sym}\nimpl 1 key: \{prev}\nimpl 2 key: \{key}\nTwo distinct impls cannot share one emitted symbol: the backend would define one body twice (the native link fails) or keep one and silently drop the other. The two keys above are the impls' canonical dispatch keys, spelled `<module>::<Interface>|<type arguments>|`. Since #1950 those keys are spelled into the symbol by `private_mangle.injectiveIdent`, which is INJECTIVE, so this is NOT a naming mistake you can rename your way out of -- it means the emitted-symbol scheme itself lost injectivity. Please report this message, with both keys above."

-- the SYMBOL tag this row is emitted under — the injectively encoded head tag when
-- it is the sole impl of (method, head), else the injectively encoded canonical key.  Mirror of
-- `llvm_emit.implFnSymTag` / `wasm_emit.implFnSymTagW`, over declaration rows: it
-- MUST call the same `injectiveIdent` they do, or the guard and the backends
-- disagree about what symbol was actually emitted.
implSymTagOf : OrdMap Unit -> String -> String -> String -> String
implSymTagOf collide method tag key =
  if omHasKey (implHeadKey method tag) collide then
    injectiveIdent key
  else
    injectiveIdent tag

-- ── dict-witness TAG injectivity — #348 (native i64), #377 (wasm 30-bit) ──────
--
-- A DIFFERENT failure mode from `implSymbolCollisionGuard` above, in a different
-- space, and no encoding choice can prevent it.  That guard covers the SYMBOL
-- space, where the collapse was `sanitizeId` being many-to-one and the fix was to
-- spell the key injectively (#1950).  This one covers the DICT-WITNESS TAG space,
-- where the map is `hashName` — a HASH.  A hash is a lossy map from an unbounded
-- domain to a fixed width by construction, so there is no injective spelling to
-- switch to: the only available discharge is to CHECK, at emit time, that the
-- program's own pre-images do not happen to collide, and refuse if they do.
--
-- 🚨 This is not a theoretical shape, and the estimate it replaces was wrong in
-- both directions.  `wasm_emit.dictTag`'s own comment called a collision
-- "astronomically unlikely for the small impl-tag alphabet" and the native 64-bit
-- scheme's the "same THEORETICAL collision shape".  Colliding pre-images are
-- CONSTRUCTIBLE, in the FULL i64, with no masking and no search: djb2 is the
-- radix-33 polynomial `5381*33^n + Σ c_i*33^i`, and the identifier alphabet spans
-- 74 code points (`0` = 48 … `z` = 122) — WIDER than the radix — so
-- `Δ_{i+1} = +1, Δ_i = −33` at two ADJACENT positions is an exact zero.  Every
-- `(X, c)` / `(X+1, chr(ord c − 33))` adjacent pair collides: `Az`/`BY`,
-- `Azure`/`BYure`, `Mzone`/`NYone`.  MEASURED on the pre-guard binary, two impls of
-- one interface at head tycons `Mzone` and `NYone`, dispatched through a dict
-- parameter: `medaka build` answered `mzone|mzone` at exit 0 with no diagnostic,
-- where `medaka run` (the interpreter oracle) answered `mzone|nyone`.  Both head
-- tags hashed to 210683374574, so the shared dispatcher emitted the SAME
-- `icmp eq i64 %headTag, 210683374574` for both arms and the first arm won every
-- call.  The collision has nothing to do with how many tags a program has, and
-- nothing to do with the mask width — widening the tag would not remove it.
--
-- Sited HERE for the same reason `implSymbolCollisionGuard` is: `lowerProgramEmit`
-- is the ONE seam every emit driver of BOTH backends funnels through, so one check
-- serves LLVM and WasmGC instead of two per-backend copies of the predicate
-- desyncing.  Both hashes are imported from `backend.private_mangle` — the SAME
-- `hashName` the LLVM emitter stamps into `emitDictCell`/`emitDispatchArm` and
-- the SAME `dictTag` the wasm emitter stamps into `routeWitness`/
-- `emitDispatchChain` — because a guard with its own copy of the hash certifies a
-- property of the copy, not of what shipped.
--
-- The pre-image population IS enumerable at this seam.  A dict witness is
-- `hashName key` / `dictTag key` where `key` is the canonical key of the instance
-- the typechecker selected (`route_key.implRouteKeyWord`), the one word a
-- dispatcher arm compares.  So the space is exactly the declared impls' canonical
-- keys, which this reads off `DImpl` with the same expression `ifaceImplHeadEntries`
-- and `implSymRowsOf` use (DAttrib unwrap included).  That is the entry set, not an
-- approximation of it.
--
-- SCOPE — stated out loud, because a partial check cited as a total one is how this
-- bug class survives:
--   * partitioned by METHOD NAME.  The emitted dispatcher only ever compares route
--     words WITHIN one method name's dispatch chain (`llvm_emit.emitDispatchBody`'s
--     candidate set is `implsOf e name`, a method-name lookup), so two impls of
--     UNRELATED methods whose route words happen to hash alike are never actually
--     compared at runtime — refusing them would be a false positive.  The OLD code
--     here pooled every impl's route words PROGRAM-WIDE, prelude and stdlib
--     included, into one injectivity check spanning every method name at once; that
--     is what let an unrelated prelude impl's route word (e.g. `Int`'s, for a
--     completely different method) reject an otherwise-correct single-type,
--     single-interface program.  Do not reintroduce program-wide pooling here.
--   * covers the DICT-WITNESS TAG space of both backends, and nothing else.  The
--     native CONSTRUCTOR/record cell headers are NOT in it and are not made safe
--     here: since the ordinal rep was ratified they are `llvm_emit.cellTag`'s
--     composite `(typeId, ordinal)`, not a hash, and only the three fixed sentinels
--     `$tuple`/`$ref`/`$closure` still carry `hashName` — a fixed three-element,
--     program-independent set.  `llvm_emit`'s own comment marks that boundary
--     ("Same shape, different NAMESPACES — merging them would silently cross
--     dict-word and ctor-tag hashing"), and it is why widening this guard to cell
--     headers would be checking a union that is never compared as one.
--   * covers the WASM SYMBOL namespaces (`gname`) NOT AT ALL — see #378.  Those
--     names are not observable here: the wasm local/global identifier sets are
--     MINTED during wasm-specific lowering (`synthParams`' `$__wparg<n>`,
--     `scratchLocals`' `$__rf<d>`, lifted-lambda and wrapper params), not carried by
--     the declaration list this seam sees, so there is no enumerable population to
--     check at this site.  Deliberately not forced into a shared site that does not
--     fit; measurement and the site it WOULD need are in the slice report.
--   * it is a check on DISTINCT PRE-IMAGES that belong to DIFFERENT impls; the
--     multi-clause and joint prelude+module duplicates of one impl share its key.
--   * it observes the tag the backends are about to mint; it does not change the
--     tag scheme.  Every collision-free program emits byte-identical IR and WAT.
--   * ⚠️ the WASM pass OVER-APPROXIMATES for a caller that cannot positively rule
--     out wasm.  #1970 threads an `EmitTarget` discriminator through
--     `lowerProgramEmit` and its callers: a caller passing `TargetNative` (an
--     LLVM-only emit driver) skips this 30-bit pass entirely, so a pair that
--     collides ONLY in the masked width — full i64 hashes distinct — now builds
--     under `--target native`, where native codegen for it is correct.
--     `TargetWasm` and `TargetBothUnknown` both still run this pass, unchanged: a
--     target-agnostic caller (a shared debug probe, or a driver feeding one
--     lowered `CProgram` to both backends) gets the SAME full-width check as
--     before, because it cannot rule out wasm either.
dictWitnessTagGuard : EmitTarget -> List Decl -> Unit
dictWitnessTagGuard target prog =
  let rows = dedupRouteWords (flatMap dictRouteWordsOf prog) omEmpty
  -- native FIRST, and ALWAYS: a full-width `hashName` collision is also a
  -- `dictTag` collision (masking cannot separate equal values), so reporting it
  -- in the i64 space names the wider defect regardless of target — this pass is
  -- not the over-approximation and is never narrowed.
  let _ = checkDictTagsInjective nativeDictTagSpace hashName rows omEmpty
  match target
    TargetNative => ()
    _ => checkDictTagsInjective wasmDictTagSpace dictTag rows omEmpty

nativeDictTagSpace : String
nativeDictTagSpace =
  "native (LLVM) i64 dict-witness word `hashName` -- BOTH backends, since the wasm tag is this hash masked"

-- ⚠️ Names the OVER-APPROXIMATION out loud.  This seam has no backend
-- discriminator (see the SCOPE note on `dictWitnessTagGuard`), so a collision that
-- exists only in the 30-bit width refuses the NATIVE build too, even though the
-- native i64 tags are distinct and native codegen would have been correct.  That is
-- the deliberate direction: a loud refusal on a rare program beats a silent wrong
-- dispatch under `--target wasm`, and the fix (rename one type) clears both.
wasmDictTagSpace : String
wasmDictTagSpace =
  "wasm (WasmGC) 30-bit i31 dict tag `dictTag` (`hashName` masked to the low 30 bits) -- the full i64 tags are DISTINCT, so native codegen would be correct here; refused anyway because a wasm-target build cannot rule out this narrower width"

-- the word a dict witness for this impl carries (its canonical key), paired with the
-- impl's identity (that same key) and the METHOD NAME that word's dispatch chain is
-- keyed by — the same grouping key `llvm_emit.implsOf`/`dispFnName` use to decide
-- what a real dispatch chain compares.  Mirrors `implSymRowsOf`'s per-`ImplMethod`
-- walk: one row per method clause, not one row per `DImpl`.
dictRouteWordsOf : Decl -> List (String, String, String)
dictRouteWordsOf (DAttrib _ d) = dictRouteWordsOf d
dictRouteWordsOf (DImpl { iface = ifaceName, implOrigin = o, tys = typeArgs, methods, ... }) =
  let key = implRouteKeyWord o ifaceName typeArgs None
  map (dictRouteWordRowFor key) methods
dictRouteWordsOf _ = []

dictRouteWordRowFor : String -> ImplMethod -> (String, String, String)
dictRouteWordRowFor key (ImplMethod mname _ _) = (mname, key, key)

-- distinct pre-images, first arrival wins, keyed by (method, word) so two DIFFERENT
-- methods' identical word never spuriously dedup against each other (mirrors
-- `implPreImageKey`'s `"\{a}\n\{b}"` compound-key shape).  The joint
-- prelude+module decl list duplicates each prelude impl and a multi-clause impl
-- contributes one row per clause; both still collapse here and can never fire the
-- check.
dedupRouteWords : List (String, String, String) ->
  OrdMap Unit ->
  List (String, String, String)
dedupRouteWords [] _ = []
dedupRouteWords ((m, w, owner) :: rest) seen
  | omHasKey (dictRouteWordKey m w) seen = dedupRouteWords rest seen
  | otherwise =
    (m, w, owner)
      :: dedupRouteWords rest (omInsert (dictRouteWordKey m w) () seen)

dictRouteWordKey : String -> String -> String
dictRouteWordKey m w = "\{m}\n\{w}"

-- injectivity of route word -> emitted tag, one pass per space, O(n log n) through
-- the same weight-balanced tree the two guards above use.  `hash` is passed in so
-- the native and wasm passes are ONE predicate over two widths rather than two
-- copies that can disagree about what a collision is.  The map key is
-- METHOD-NAME-SCOPED (`"\{mname}\n\{intToString (hash w)}"`) so injectivity is
-- checked WITHIN one method name's population only — the same partition
-- `dictRouteWordsOf`/`dedupRouteWords` build, and the same grouping key
-- `implsOf`/`dispFnName` use to decide what a real dispatch chain compares.
--
-- ⚠️ The four data lines are UNINDENTED on purpose, for the same reason
-- `checkImplSymbolsInjective`'s three are: they are CONTENT-derived, so a
-- `stdout-line` pin can match them with `grep -qxF` without false-draining on a
-- rewording of the prose around them.
checkDictTagsInjective : String ->
  (String -> Int) ->
  List (String, String, String) ->
  OrdMap (String, String) ->
  Unit
checkDictTagsInjective _ _ [] _ = ()
checkDictTagsInjective space hash ((m, w, owner) :: rest) seen =
  let t = intToString (hash w)
  let k = "\{m}\n\{t}"
  match omLookup k seen
    None => checkDictTagsInjective space hash rest (omInsert k (w, owner) seen)
    Some (w0, owner0) =>
      if owner0 == owner then
        checkDictTagsInjective space hash rest seen
      else
        panic
          "emitted dict-witness tag collision: two DISTINCT impls of method `\{m}` hash to one dispatch tag.\ntag space: \{space}\ncollided tag: \{t}\nroute word 1: \{w0}\nroute word 2: \{w}\nA dict witness carries this tag, and method `\{m}`'s shared dispatcher selects an impl by comparing it against every OTHER impl of that SAME method name -- these two words ARE compared against each other at that dispatcher, so this collision is live: whichever arm the emitter happened to emit FIRST wins every call through a dictionary, silently, at exit 0. The two words above are the impls' route words: either a bare head tycon or a canonical dispatch key spelled `<module>::<Interface>|<type arguments>|`. This is NOT a naming collision you can rename your way out of by making the names more different -- `hashName` is djb2, a radix-33 polynomial over a 74-code-point alphabet, so it is genuinely non-injective (`hashName \"Az\" == hashName \"BY\"`). One of the two words above may name a type or interface from the prelude or stdlib that you do not own -- rename the OTHER one, one of your own types or interfaces involved in this collision. Please also report this message, with both words above."

-- lowerImpls against a PRE-BUILT dispatch table — the multi-module driver builds
-- one `disp` from all modules' decls jointly (an impl in module B for an interface
-- in the prelude needs the prelude's dispatch positions), then lowers each
-- module's impls against it.
export
lowerImplsWith : List ((String, String, String), List Int) ->
  OrdMap Int ->
  Option DispositionTable ->
  List Decl ->
  List CImplEntry
lowerImplsWith disp reqCounts dispositions prog =
  map (refoldImpl noLetCheck) (lowerImplsRaw disp reqCounts dispositions prog)

lowerImplsRaw : List ((String, String, String), List Int) ->
  OrdMap Int ->
  Option DispositionTable ->
  List Decl ->
  List CImplEntry
lowerImplsRaw disp reqCounts dispositions prog =
  flatMap (lowerDeclImpl disp reqCounts dispositions) prog

lowerDeclImpl : List ((String, String, String), List Int) ->
  OrdMap Int ->
  Option DispositionTable ->
  Decl ->
  List CImplEntry
-- #1037: an ATTRIBUTE IS METADATA — it must never change which impls exist.  A
-- decl attribute parses to `DAttrib attrs <decl>` (parser.parseAttrib wraps ANY
-- decl), so `@deprecated "…" impl Speak Cat where …` reaches here as a DAttrib and
-- fell through to `_ => []`: the impl contributed ZERO entries and simply VANISHED
-- from the program's impl set.  Native then had an impl-less interface-with-default
-- and SIGSEGV'd through #948's arm-less dispatcher; eval's `declImplEntries` has the
-- same shape and silently answered from the interface default instead.
lowerDeclImpl disp reqCounts dt (DAttrib _ d) =
  lowerDeclImpl disp reqCounts dt d
-- B-2.2-e: `implOrigin` is bound here purely to reach `lowerImplMethod`'s route
-- word (the definition side of the identity-bearing key `keyForSite` stamps at the
-- call site).  Matched arm-for-arm by `eval.declImplEntries`, which threads the
-- same field for the same reason.
lowerDeclImpl disp _ _ (DImpl { iface = ifaceName, implOrigin = o, tys = typeArgs, methods, ... }) =
  map (lowerImplMethod disp o ifaceName typeArgs) methods
-- An interface lowers one entry for each default per instance the table says
-- inherits it — lowered HERE, beside the interface's other code, because the body
-- is the interface module's (its names resolve there).  Every inherited slot
-- therefore has its own entry, and no engine is left to choose a default.  The interface word is read straight off `DInterface.ifaceOrigin`
-- (resolve stamps it in `elaborateModules`' preamble — `stampGraphTyOrigins`), the
-- same spelling the table's producer keys the slot by.
lowerDeclImpl disp reqCounts (Some dt) (DInterface { name = ifaceName, ifaceOrigin = o, methods, ... }) =
  flatMap (lowerInheritedDefault disp reqCounts dt o ifaceName) methods
lowerDeclImpl _ _ _ _ = []

lowerImplMethod : List ((String, String, String), List Int) ->
  TyConOrigin ->
  String ->
  List Ty ->
  ImplMethod ->
  CImplEntry
lowerImplMethod disp o ifaceName typeArgs (ImplMethod mname pats body) =
  let tag = optionOr noneHeadTag (headTyconHead typeArgs)
  let key = implRouteKeyWord o ifaceName typeArgs None
  -- #1113 Phase 4: identity-keyed admissibility lookup — the LOCKSTEP peer of
  -- `eval.implMethodEntry`'s identical line.  `o` is already bound for `key`, so
  -- both consumers pay nothing.  These are the ONLY two `lookupPositions` call
  -- sites, and `CImplTagged`'s `positions` is where the answer is FROZEN.
  let positions =
    lookupPositions (ifaceIdentity o ifaceName) ifaceName mname disp
  CImplEntry
    mname
    (tyvarsInArgs typeArgs)
    (CImplTagged tag key ifaceName positions pats (lower body))

lowerInheritedDefault : List ((String, String, String), List Int) ->
  OrdMap Int ->
  DispositionTable ->
  TyConOrigin ->
  String ->
  IfaceMethod ->
  List CImplEntry
lowerInheritedDefault _ _ _ _ _ (IfaceMethod _ _ None _) = []
lowerInheritedDefault disp reqCounts dt o ifaceName (IfaceMethod mname _ (Some (MethodDefault pats body)) _) =
  let ifaceWord = ifaceWordOf o ifaceName
  let positions =
    lookupPositions (ifaceIdentity o ifaceName) ifaceName mname disp
  let nMethodDicts = leadingDictParams pats
  let receiver = "$dict_\{mname}_\{intToString nMethodDicts}"
  let params =
    take nMethodDicts pats
      ++ [PVar receiver (Loc "" 0 0 0 0)]
      ++ drop nMethodDicts pats
      ++ lamParams body
  let lowered = lower (underLam body)
  let spec =
    shape => DefaultRow {
      drSelf = defaultReceiverDict mname,
      drReceiver = receiver,
      drIface = ifaceWord,
      drWord = shape.isWord,
      drSupers = receiverFields receiver 0 (ifaceSuperCount ifaceWord dt),
      drReqs =
        receiverFields
          receiver
          (ifaceSuperCount ifaceWord dt)
          (optionOr 0 (omLookup shape.isWord reqCounts)),
    }
  map
    (shape =>
      CImplEntry
        mname
        (tyvarsInArgs shape.isTys)
        (CImplDefault
          ifaceWord
          (optionOr noneHeadTag (headTyconHead shape.isTys))
          shape.isWord
          positions
          params
          (specializeRow (spec shape) lowered)))
    (inheritorsOf ifaceWord mname dt)

-- One inheriting instance's entry for a default is the default's body lowered once
-- and specialized to that instance.  The entry takes the default's method-level
-- dictionaries, then its RECEIVER -- the dictionary of the instance whose slot it
-- fills, handed over by whichever call selected this entry -- then the default's
-- value patterns (and, for a point-free default, its lambda's).  The receiver sits
-- where a supplied method's first `requires` dictionary sits and is named like one,
-- so every engine's count of an entry's leading dictionaries covers it; an engine
-- differs only in passing the selecting dictionary itself there rather than the
-- dictionary's `requires`.
--
-- The entry is reached only through its instance's word, so the receiver IS that
-- instance's dictionary: a call in the body to a method of the same interface on the
-- receiver goes straight to the instance's own entry for it (supplied or inherited),
-- its `requires` read out of the receiver.  Everything else, a superclass call in
-- particular, still reads the receiver, so it answers with the dictionary the caller
-- built.
data DefaultRow = DefaultRow {
  -- the receiver name the body's evidence was rendered to (`defaultReceiverDict`)
  drSelf : String,
  -- the entry's receiver parameter
  drReceiver : String,
  -- the interface's word, which a sibling call carries
  drIface : String,
  -- the inheriting instance's word
  drWord : String,
  -- the receiver's super dictionaries, then its `requires`, as projections of it
  drSupers : List Route,
  drReqs : List Route,
}

-- projections [from, from + n) of the dictionary named [recv]: a dictionary stores
-- its supers, then its `requires`
receiverFields : String -> Int -> Int -> List Route
receiverFields recv from n =
  map (i => RProj (RDict recv) [i]) (range from (from + n))

specializeRow : DefaultRow -> CExpr -> CExpr
specializeRow row (CMethod name iface arity route implRoutes methRoutes) =
  if iface == row.drIface && isReceiverRoute row route then
    CMethod
      name
      iface
      arity
      (RKey row.drWord [] row.drSupers)
      row.drReqs
      (map (renameReceiver row) methRoutes)
  else
    CMethod
      name
      iface
      arity
      (renameReceiver row route)
      (map (renameReceiver row) implRoutes)
      (map (renameReceiver row) methRoutes)
specializeRow row (CDict name routes) =
  CDict name (map (renameReceiver row) routes)
specializeRow row (CVar x addr) =
  if x == row.drSelf then CVar row.drReceiver addr else CVar x addr
specializeRow _ (CLit l) = CLit l
specializeRow row (CApp f x) = CApp (specializeRow row f) (specializeRow row x)
specializeRow row (CLam pats body) = CLam pats (specializeRow row body)
specializeRow row (CLet r pat e1 e2) =
  CLet r pat (specializeRow row e1) (specializeRow row e2)
specializeRow row (CLetGroup binds body) =
  CLetGroup (map (specializeBind row) binds) (specializeRow row body)
specializeRow row (CMatch scrut arms) =
  CMatch (specializeRow row scrut) (map (specializeArm row) arms)
specializeRow row (CDecision scrut arms tree) =
  CDecision (specializeRow row scrut) (map (specializeArm row) arms) tree
specializeRow row (CIf c t e) =
  CIf (specializeRow row c) (specializeRow row t) (specializeRow row e)
specializeRow row (CBinPrim op l r tag site) =
  CBinPrim op (specializeRow row l) (specializeRow row r) tag site
specializeRow row (CUnOp op x) = CUnOp op (specializeRow row x)
specializeRow row (CTuple es) = CTuple (map (specializeRow row) es)
specializeRow row (CList es) = CList (map (specializeRow row) es)
specializeRow row (CRecord name fields) =
  CRecord name (map (specializeField row) fields)
specializeRow row (CFieldAccess ex f n) =
  CFieldAccess (specializeRow row ex) f n
specializeRow row (CRecordUpdate name base fields) =
  CRecordUpdate name (specializeRow row base) (map (specializeField row) fields)
specializeRow row (CVariantUpdate con base fields) =
  CVariantUpdate con (specializeRow row base) (map (specializeField row) fields)
specializeRow row (CArray es) = CArray (map (specializeRow row) es)
specializeRow row (CRangeList lo hi incl) =
  CRangeList (specializeRow row lo) (specializeRow row hi) incl
specializeRow row (CRangeArray lo hi incl) =
  CRangeArray (specializeRow row lo) (specializeRow row hi) incl
specializeRow row (CIndex a i) =
  CIndex (specializeRow row a) (specializeRow row i)
specializeRow row (CSlice a lo hi incl) =
  CSlice
    (specializeRow row a)
    (specializeRow row lo)
    (specializeRow row hi)
    incl
specializeRow row (CStringIndex a i) =
  CStringIndex (specializeRow row a) (specializeRow row i)
specializeRow row (CStringSlice a lo hi incl) =
  CStringSlice
    (specializeRow row a)
    (specializeRow row lo)
    (specializeRow row hi)
    incl
specializeRow row (CListIndex a i) =
  CListIndex (specializeRow row a) (specializeRow row i)
specializeRow row (CListSlice a lo hi incl) =
  CListSlice
    (specializeRow row a)
    (specializeRow row lo)
    (specializeRow row hi)
    incl
specializeRow row (CBlock stmts) = CBlock (map (specializeStmt row) stmts)

specializeBind : DefaultRow -> CBind -> CBind
specializeBind row (CBind n clauses site) =
  CBind n (map (specializeClause row) clauses) site

specializeClause : DefaultRow -> CClause -> CClause
specializeClause row (CClause pats body) = CClause pats (specializeRow row body)

specializeArm : DefaultRow -> CArm -> CArm
specializeArm row (CArm pat guards body) =
  CArm pat (map (specializeGuard row) guards) (specializeRow row body)

specializeGuard : DefaultRow -> CGuard -> CGuard
specializeGuard row (CGBool e) = CGBool (specializeRow row e)
specializeGuard row (CGBind p e) = CGBind p (specializeRow row e)

specializeStmt : DefaultRow -> CStmt -> CStmt
specializeStmt row (CSExpr e) = CSExpr (specializeRow row e)
specializeStmt row (CSLet r pat e) = CSLet r pat (specializeRow row e)
specializeStmt row (CSAssign x e) = CSAssign x (specializeRow row e)

specializeField : DefaultRow -> CField -> CField
specializeField row (CField k e) = CField k (specializeRow row e)

-- the receiver itself, not a projection of it
isReceiverRoute : DefaultRow -> Route -> Bool
isReceiverRoute row (RDict d) = d == row.drSelf
isReceiverRoute row (RDictFwd d) = d == row.drSelf
isReceiverRoute _ _ = False

renameReceiver : DefaultRow -> Route -> Route
renameReceiver row (RDict d) =
  RDict (if d == row.drSelf then row.drReceiver else d)
renameReceiver row (RDictFwd d) =
  RDictFwd (if d == row.drSelf then row.drReceiver else d)
renameReceiver row (RKey k reqs sups) =
  RKey k (map (renameReceiver row) reqs) (map (renameReceiver row) sups)
renameReceiver row (RProj r path) = RProj (renameReceiver row r) path
renameReceiver row (RLocal sym dicts) =
  RLocal sym (map (renameReceiver row) dicts)
renameReceiver _ RNone = RNone
renameReceiver _ (RScalar t) = RScalar t

-- Each instance's `requires` count, keyed by its word: the length of the segment its
-- dictionary stores after its supers.  Built from every module's impls, because an
-- instance can inherit a default declared in another module.
export
instanceReqCounts : List Decl -> OrdMap Int
instanceReqCounts decls = instanceReqCountsGo decls omEmpty

instanceReqCountsGo : List Decl -> OrdMap Int -> OrdMap Int
instanceReqCountsGo [] acc = acc
instanceReqCountsGo ((DAttrib _ d) :: rest) acc =
  instanceReqCountsGo (d :: rest) acc
instanceReqCountsGo ((DImpl { iface, tys, reqs, implOrigin, ... }) :: rest) acc =
  instanceReqCountsGo
    rest
    (omInsert (implRouteKeyWord implOrigin iface tys None) (listLen reqs) acc)
instanceReqCountsGo (_ :: rest) acc = instanceReqCountsGo rest acc

-- a default body's leading lambda parameters, and the body under them
lamParams : Expr -> List Pat
lamParams (ELoc _ e) = lamParams e
lamParams (ELam ps _) = ps
lamParams _ = []

underLam : Expr -> Expr
underLam (ELoc _ e) = underLam e
underLam (ELam _ b) = b
underLam e = e

-- the leading `$dict_*` parameters dict-passing prepended to a default's clause
leadingDictParams : List Pat -> Int
leadingDictParams ((PVar x _) :: rest) =
  if startsWith "$dict" x then 1 + leadingDictParams rest else 0
leadingDictParams _ = 0

-- ── returns-self table (native backend: method-call RESULT-type inference) ───
-- Per (interface, method): does the method's RESULT type mention an interface
-- type parameter?  This is the result-side analogue of `dispatchPositionsOf`'s
-- per-arg `tyMentions` (eval.mdk) — True for a container method whose result is
-- the self/container type (`map`/`ap`/`andThen` at a container impl all return
-- the container), False for a method returning a scalar/element/concrete type
-- (`compare : a -> a -> Ordering`).  The LLVM emitter reads it to statically type
-- a method-call result: a `returnsSelf` method dispatched (RKey) at type `T`
-- yields `tagToLTy T`, so a downstream `++`/`::` on that result picks the right
-- list/string instruction instead of falling to the `LTInt` default (the last
-- EMITTER-GAPS.md #3 residual: `ap@List` / `andThen@List`, whose `++` operand is
-- a CALL result like `map f xs` / `f x`, not a param).
export
returnsSelfTable : List Decl -> List ((String, String), Bool)
returnsSelfTable prog = flatMap ifaceReturnsSelfEntries prog

ifaceReturnsSelfEntries : Decl -> List ((String, String), Bool)
-- #1037: an attribute on an `interface` must not delete it from this table either.
ifaceReturnsSelfEntries (DAttrib _ d) = ifaceReturnsSelfEntries d
ifaceReturnsSelfEntries (DInterface { name = ifaceName, typarams = typeParams, methods, ... }) =
  map (m => ifaceReturnsSelfEntry ifaceName typeParams m) methods
ifaceReturnsSelfEntries _ = []

ifaceReturnsSelfEntry : String ->
  List String ->
  IfaceMethod ->
  ((String, String), Bool)
ifaceReturnsSelfEntry ifaceName typeParams (IfaceMethod mname mty _ _) = (
  (ifaceName, mname),
  tyMentionsParams (methodResultTy mty) (headParamOnly typeParams),
)

-- Only the HEAD (first) interface type parameter — the one whose concrete
-- instantiation names the impl's dispatch/head tag (`headTyconHead typeArgs`
-- takes typeArgs[0]).  A method's result is the self/container type ONLY when it
-- mentions THIS param; the emitter then types the RKey result as `tagToLTy
-- headTag`.  A multi-param interface (`Ix c v`) whose result mentions a NON-head
-- param (`v`, the element) is NOT self-returning: typing its Char/element result
-- as `tagToLTy headTag` (e.g. LTStr for `impl Ix String Char`) would route a
-- downstream `==` through @mdk_string_eq, dereferencing a Char immediate as a
-- String pointer → SIGSEGV.  (Previously ALL typeParams were checked, mis-marking
-- `ix` self-returning and mis-typing its array-slot Char result.)
headParamOnly : List String -> List String
headParamOnly [] = []
headParamOnly (p :: _) = [p]

-- the RESULT type of a method type: the final tail after stripping the TyFun
-- argument chain (and any leading constraint/effect wrappers).
methodResultTy : Ty -> Ty
methodResultTy (TyConstrained _ t) = methodResultTy t
methodResultTy (TyEffect _ _ t) = methodResultTy t
methodResultTy (TyFun _ b) = methodResultTy b
methodResultTy (TyQual t _ _) = methodResultTy t
methodResultTy t = t

-- does a type mention one of the given interface type-parameter names? (the
-- result-side twin of eval.mdk's non-exported `tyMentions`).
tyMentionsParams : Ty -> List String -> Bool
tyMentionsParams (TyVar n) params = contains n params
tyMentionsParams (TyCon { tyConName = _ }) _ = False
tyMentionsParams (TyApp a b) params =
  tyMentionsParams a params || tyMentionsParams b params
tyMentionsParams (TyFun a b) params =
  tyMentionsParams a params || tyMentionsParams b params
tyMentionsParams (TyTuple ts) params =
  anyList (t => tyMentionsParams t params) ts
tyMentionsParams (TyEffect _ _ t) params = tyMentionsParams t params
-- A bare row atom (#997) has no wrapped type, but a bare tail var (`<e>`,
-- no labels) IS a mention of that name, same as a bare `TyVar` above.
-- Intentional cross-file duplicate of eval.mdk's tyMentions TyRow clause;
-- not consolidating (tiny helper / divergent-by-design untyped-eval vs
-- typed-core-IR pair — same precedent as typecheck.mdk's and doc.mdk's
-- ppEffAtomTy).
-- lint-disable-next-line rule-duplicate-body
tyMentionsParams (TyRow _ tail _) params = anyList (v => contains v params) tail
tyMentionsParams (TyAuth _ _) _ = False
tyMentionsParams (TyConstrained _ t) params = tyMentionsParams t params
tyMentionsParams (TyNamed _ t _) params = tyMentionsParams t params
tyMentionsParams (TyQual t _ _) params = tyMentionsParams t params

-- ── self-returning function-PARAM table (native backend) ────────────────────
-- Per (interface, method): the ARGUMENT positions whose type is a FUNCTION whose
-- RESULT mentions the interface/self type variable — i.e. a callback that yields
-- the container.  e.g. `andThen : m a -> (a -> m b) -> m b` has param 1 of type
-- `a -> m b`, a function returning self.  The emitter types the APPLICATION of
-- such a param (`f x`) as the container (`tagToLTy tag`), closing `andThen@List`
-- where the `++` LEFT operand `f x` is an indirect call the method-call
-- inference (returnsSelfTable) cannot reach.  Result-side analogue scoped to
-- function-typed params, not the whole-method result.
export
selfFnParamTable : List Decl -> List ((String, String), List Int)
selfFnParamTable prog = flatMap ifaceSelfFnParamEntries prog

ifaceSelfFnParamEntries : Decl -> List ((String, String), List Int)
-- #1037
ifaceSelfFnParamEntries (DAttrib _ d) = ifaceSelfFnParamEntries d
ifaceSelfFnParamEntries (DInterface { name = ifaceName, typarams = typeParams, methods, ... }) =
  map (m => ifaceSelfFnParamEntry ifaceName typeParams m) methods
ifaceSelfFnParamEntries _ = []

ifaceSelfFnParamEntry : String ->
  List String ->
  IfaceMethod ->
  ((String, String), List Int)
ifaceSelfFnParamEntry ifaceName typeParams (IfaceMethod mname mty _ _) =
  ((ifaceName, mname), selfFnPositions 0 (methodArgTys mty) typeParams)

-- the argument types of a method type (the a's of `a -> a -> … -> r`).
methodArgTys : Ty -> List Ty
methodArgTys (TyConstrained _ t) = methodArgTys t
methodArgTys (TyEffect _ _ t) = methodArgTys t
methodArgTys (TyFun (TyNamed _ a _) b) = a :: methodArgTys b
methodArgTys (TyFun a b) = a :: methodArgTys b
methodArgTys _ = []

-- ── method → (interface, full-arity) table (native backend: default methods) ─
-- Per interface method name: the interface it belongs to and its full argument
-- arity (from the declared signature `a -> b -> … -> r`).  The LLVM emitter reads
-- it to emit an interface DEFAULT method (a `CImplDefault` body the type's `impl`
-- did not override): the arity drives eta-expansion of a point-free default
-- (`filter p = filterMap …` is arity-1 point-free but the method is arity-2), and
-- the interface name lets the emitter recognise inner SAME-interface method calls
-- in the default body and re-stamp them to the concrete dispatch tag (so the
-- partially-applied inner `filterMap` lowers to a direct `@mdk_impl_<tag>_filterMap`
-- call instead of an un-dispatchable arg-tag fallback).  Keyed by BARE method name
-- ROW SHAPE, #1450/#1668: each row is `(method, (ifaceName, ifaceWord, arity))`.
-- The row COUNT and the `(ifaceName, arity)` pair are UNCHANGED -- `makeEmitInput`
-- projects the pair straight back out for the existing bare-name index, so the
-- INTERFACE leg above keeps its current bare spelling and its current answers.
-- The third component is ADDITIVE: `ifaceWordOf implOrigin ifaceName`, the
-- DECLARATION identity of the interface (`"zmod::IZ"`; the bare name when no origin
-- is stamped, i.e. single-file, where a cross-module collision cannot exist).  It
-- lets the emitter index the ARITY leg by interface DECLARATION instead of by bare
-- method name -- which is the whole of #1450 / #1668: two modules declaring
-- same-spelled methods on unrelated interfaces collapse to ONE bare-name row, and
-- whichever declaration lands last silently supplies BOTH impls' emitted arity.
export
methodIfaceTable : List Decl -> List (String, (String, String, Int))
methodIfaceTable prog = flatMap ifaceMethodArityEntries prog

ifaceMethodArityEntries : Decl -> List (String, (String, String, Int))
-- #1037
ifaceMethodArityEntries (DAttrib _ d) = ifaceMethodArityEntries d
ifaceMethodArityEntries (DInterface { name = ifaceName, ifaceOrigin = o, methods, ... }) =
  map (m => ifaceMethodArityEntry (ifaceWordOf o ifaceName) ifaceName m) methods
ifaceMethodArityEntries _ = []

ifaceMethodArityEntry : String ->
  String ->
  IfaceMethod ->
  (String, (String, String, Int))
ifaceMethodArityEntry ifaceWord ifaceName (IfaceMethod mname mty _ _) =
  (mname, (ifaceName, ifaceWord, listLen (methodArgTys mty)))

-- The identity-keyed lookup word for the ARITY leg (#1450, #1668): the interface's
-- DECLARATION word and the method name, spliced.  Minted here, beside the table it
-- keys, and read by both backends -- `ifaceWordOf` never answers `""` (it falls back
-- to the bare interface name), so this word is never the absence-matches-absence
-- hazard `ifaceIdentity` carries.  `#` cannot occur in either half.
export
ifaceMethodArityKey : String -> String -> String
ifaceMethodArityKey ifaceWord mname = "\{ifaceWord}#\{mname}"

-- The interface DECLARATION word an impl route key carries in its first field
-- (`route_key.implRouteKeyWord` = `<iface word>|<type args>|<method>`).  This is a
-- READ of the key's existing, already-identity-bearing content -- NOT a re-keying
-- of it, and not a read of `CImplTagged`'s bare `iface` field, which keeps its
-- current spelling and its current route-word readers (#1277 / PR #1346 E4).
export
ifaceWordOfKey : String -> String
ifaceWordOfKey key = match splitOnChar '|' key
  w :: _ => w
  [] => key

-- The interface SPELLING an `ifaceWordOf` word names: the part after
-- `<module>::`, or the whole word when no origin was stamped (a module id never
-- contains `:`).
--
-- > ifaceNameOfWord "core::Show"
-- "Show"
-- > ifaceNameOfWord "Show"
-- "Show"
export
ifaceNameOfWord : String -> String
ifaceNameOfWord word = match reverseL (splitOnChar ':' word)
  name :: _ => name
  [] => word

-- ── method → method-level constraint INTERFACE names (native backend, G7) ────
-- Per interface method that carries a method-level `=>` constraint (foldMap's
-- `Monoid m =>`): the interface name of each such constraint, IN SLOT ORDER —
-- the SAME order typecheck's `methodConstraintSlotIds`/`resolveMethodDicts` fill
-- the method occurrence's `methRoutes` list.  This lets the default-body emitter
-- map a cross-interface method (e.g. the `empty` in foldMap's default, a Monoid
-- method whose dict is threaded per-call by the RESULT type, not the container)
-- to the threaded method-dict PARAM and dispatch it at run time — so one shared
-- `@mdk_default_foldMap_List` serves both a List-monoid and a String-monoid fold.
-- A constraint over ONLY interface params contributes no slot (it dispatches via
-- the impl, not a per-call dict); mirrors typecheck's `constraintIsMethodLevel`.
-- Qualified rows include an explicit [] so a selected unconstrained method cannot
-- fall through to a same-spelled interface method's legacy bare row.
export
methodConstraintIfaces : List Decl -> List (String, List String)
methodConstraintIfaces prog = flatMap methodConstraintIfaceEntries prog

methodConstraintIfaceEntries : Decl -> List (String, List String)
-- #1037
methodConstraintIfaceEntries (DAttrib _ d) = methodConstraintIfaceEntries d
methodConstraintIfaceEntries (DInterface { name = ifaceName, ifaceOrigin = o, typarams, methods, ... }) =
  flatMap
    (m => methodConstraintIfaceEntry (ifaceWordOf o ifaceName) typarams m)
    methods
methodConstraintIfaceEntries _ = []

methodConstraintIfaceEntry : String ->
  List String ->
  IfaceMethod ->
  List (String, List String)
methodConstraintIfaceEntry ifaceWord typarams (IfaceMethod mname mty _ _) =
  let ifaces = methodLevelConstraintIfaces typarams mty
  let qualified = (ifaceMethodArityKey ifaceWord mname, ifaces)
  if isEmptyL ifaces then
    [qualified]
  else
    [
      (mname, ifaces),
      qualified,
    ]

-- the interface name of each method-level constraint in [ty], in declaration
-- order (peels TyConstrained/TyEffect like methodConstraintSlotIds).
methodLevelConstraintIfaces : List String -> Ty -> List String
methodLevelConstraintIfaces typarams (TyConstrained cs t) =
  flatMap (c => constraintIfaceIfMethodLevel typarams c) cs
    ++ methodLevelConstraintIfaces typarams t
methodLevelConstraintIfaces typarams (TyEffect _ _ t) =
  methodLevelConstraintIfaces typarams t
methodLevelConstraintIfaces _ _ = []

constraintIfaceIfMethodLevel : List String -> Constraint -> List String
constraintIfaceIfMethodLevel typarams (Constraint { constraintHead = ifaceName, constraintArgs = args })
  | constraintArgsMentionNonParam typarams args = [ifaceName]
  | otherwise = []

-- a constraint is method-level iff one of its argument types mentions a tyvar
-- that is NOT an interface param (so the dict is supplied per-call).
constraintArgsMentionNonParam : List String -> List Ty -> Bool
constraintArgsMentionNonParam typarams args =
  anyList (t => tyMentionsNonParam t typarams) args

tyMentionsNonParam : Ty -> List String -> Bool
tyMentionsNonParam (TyVar n) params = not (contains n params)
tyMentionsNonParam (TyCon { tyConName = _ }) _ = False
tyMentionsNonParam (TyApp a b) params =
  tyMentionsNonParam a params || tyMentionsNonParam b params
tyMentionsNonParam (TyFun a b) params =
  tyMentionsNonParam a params || tyMentionsNonParam b params
tyMentionsNonParam (TyTuple ts) params =
  anyList (t => tyMentionsNonParam t params) ts
tyMentionsNonParam (TyEffect _ _ t) params = tyMentionsNonParam t params
-- Mirror of the `tyMentionsParams` arm above.
tyMentionsNonParam (TyRow _ tail _) params =
  anyList (v => not (contains v params)) tail
tyMentionsNonParam (TyAuth _ _) _ = False
tyMentionsNonParam (TyConstrained _ t) params = tyMentionsNonParam t params
tyMentionsNonParam (TyNamed _ t _) params = tyMentionsNonParam t params
tyMentionsNonParam (TyQual t _ _) params = tyMentionsNonParam t params

-- ── constructor → DECLARED field type-head names (native backend, Gap E2) ────
-- Per data-constructor name: the head type-name of each declared field, IN
-- DECLARED ORDER (e.g. `Rect Float Float` → ("Rect", ["Float","Float"])).  The
-- LLVM emitter (`bindFields`) reads it to type a match-bound field VARIABLE from
-- the ctor's declared field type rather than guessing from body-use (`paramUseTy`,
-- which defaults Float fields to LTInt → integer arith on a boxed-Float word →
-- SIGSEGV; Gap E2).  A field whose type is not a simple type-constructor head
-- (polymorphic `TyVar`, applied/function/tuple types) maps to "" — the emitter
-- treats "" / unknown-scalar names as "fall back to paramUseTy/LTInt", so the
-- change is ADDITIVE: only fields with a known scalar head (Float/Bool/Int/…)
-- change typing.  Both positional (`ConPos`) and named-field (`ConNamed`)
-- payloads are covered, in the same DECLARED order the cell layout stores.
export
ctorFieldTypeNames : List Decl -> List (String, List String)
ctorFieldTypeNames prog = flatMap ctorFieldTypeEntries prog

ctorFieldTypeEntries : Decl -> List (String, List String)
ctorFieldTypeEntries (DData { dataCtors = variants }) =
  map variantFieldTypeEntry variants
ctorFieldTypeEntries (DNewtype { newtypeCtor = con, newtypeFieldTy = fieldTy }) =
  [(con, [tyHeadName fieldTy])]
ctorFieldTypeEntries (DAttrib _ d) = ctorFieldTypeEntries d
ctorFieldTypeEntries _ = []

variantFieldTypeEntry : Variant -> (String, List String)
variantFieldTypeEntry (Variant name (ConPos tys)) = (name, map tyHeadName tys)
variantFieldTypeEntry (Variant name (ConNamed fields _)) =
  (name, map fieldTyHeadName fields)

fieldTyHeadName : Field -> String
fieldTyHeadName (Field _ ty) = tyHeadName ty

-- the head type-CONSTRUCTOR name of a field type, or "" if it has no simple head
-- (TyVar / TyFun / TyTuple / applied types) — the emitter treats "" as "unknown".
tyHeadName : Ty -> String
tyHeadName (TyCon { tyConName = n }) = n
-- G3: a type VARIABLE head (`a` in `Num a => a -> a`) yields its var name, so the
-- emitter's declSig table can recognise a polymorphic Num param (isTypeVarName) and
-- route its arithmetic through the runtime tag-dispatched @mdk_num_* helpers.
-- ADDITIVE for every other consumer: a var name (lowercase) is not a known scalar,
-- so `fieldNameToLTy` maps it to None exactly as the old "" did (ctor-field /
-- record-field LTy seeding is unchanged); only the new G3 check reads the name.
tyHeadName (TyVar n) = n
tyHeadName (TyApp a _) = tyHeadName a
tyHeadName (TyConstrained _ t) = tyHeadName t
tyHeadName (TyEffect _ _ t) = tyHeadName t
tyHeadName (TyNamed _ t _) = tyHeadName t
tyHeadName (TyQual t _ _) = tyHeadName t
tyHeadName _ = ""

-- ── function → DECLARED param/return type-head names (native backend, Gap E1) ─
-- Per top-level function name (from its `DTypeSig` annotation): the head
-- type-name of each declared PARAMETER (in order) plus the declared RETURN type
-- head, e.g. `double : Float -> Float` → ("double", (["Float"], "Float")).  The
-- LLVM emitter's signature inference (`inferSigs`/`inferParamTys`/`paramUseTy`)
-- otherwise recovers param/return LTys purely from BODY USE; a literal-free
-- annotated body like `double x = x + x` has no Float anchor → param defaults
-- LTInt → integer arith on a boxed-Float word → garbage (Gap E1).  Seeding the
-- DECLARED scalar type wins over the body-use guess.  A non-scalar head (TyVar /
-- applied / function / tuple) maps to "" and the emitter falls back to the
-- existing guess, so the seed is ADDITIVE: only known-scalar declared params/
-- returns change typing (and `Int`-annotated fns seed LTInt = current default).
export
declSigTypeNames : List Decl -> List (String, (List String, String))
declSigTypeNames prog = flatMap declSigTypeEntries prog

declSigTypeEntries : Decl -> List (String, (List String, String))
declSigTypeEntries (DTypeSig _ name ty _) =
  [(name, (map tyHeadName (methodArgTys ty), tyHeadName (methodRetTy ty)))]
declSigTypeEntries (DExtern _ name ty) =
  [(name, (map tyHeadName (methodArgTys ty), tyHeadName (methodRetTy ty)))]
declSigTypeEntries (DAttrib _ inner) = declSigTypeEntries inner
declSigTypeEntries _ = []

-- ── user-declared FFI externs → the lowering's own table (#2074) ─────────────
-- The emitter's `declSigIndex` (above) cannot answer "is this name a USER
-- extern?": it is built from `runtimeDecls ++ allDecls` and holds ordinary
-- annotated functions and the `stdlib/runtime.mdk` builtins in the same
-- flat keyspace.  So the FFI lowering gets its OWN index, minted here from the
-- same two decl lists the emit drivers already hold, and carried to the emitter
-- as `EmitInput.ffiExternIndex`.
--
-- #2174/#2135: this raw-AST producer now remains only for the snapshot tool's
-- intentionally untyped emitter stage.  Every typed LLVM/Wasm driver obtains its
-- rows from `types.typecheck.checkedFfiExternTypeNames{,Modules}`, which expands
-- through the typechecker's canonical alias carrier and subtracts builtins through
-- the catalog map seeded by `noteBuiltinExternNames`.  It then calls
-- `validateFfiExternTypeNames` below for this table's whole-program injectivity
-- guard.  Do not route a typed emitter back through this syntactic head walk.
--
-- 🚨 THE BUILTIN-NAME EXEMPTION, emitter side.  A local `extern` whose name is a
-- `stdlib/runtime.mdk` catalog name is emitted through the BUILTIN's codegen
-- (`isAnyExtern` in `emitApp`'s ladder dispatches by exact NAME), regardless of
-- what the local row claims — that is the same fact `ffiIsBuiltinExternName`
-- (`compiler/types/typecheck.mdk`) exempts from the crossable-set guard.  Here it
-- is honoured by SUBTRACTING the runtime catalog's own extern names, so such a
-- name never enters the FFI index at all and no foreign call can be minted for
-- it.  (`emitApp` checks `isAnyExtern` BEFORE the FFI arm as well, so the
-- exemption holds on both sides of the seam; this filter is what keeps it true
-- for a runtime extern name whose catalog row gives llvm no family.)
export
ffiExternTypeNames : List Decl ->
  List Decl ->
  List (String, (List String, String))
ffiExternTypeNames runtimeDecls userDecls =
  validateFfiExternTypeNames
    (ffiExternRows (externDeclNamesOf runtimeDecls) userDecls)

-- The canonical typed producer lives in `types.typecheck`, but this guard is a
-- property of the FINISHED bare-name-keyed emitter table rather than of one
-- module's typecheck.  Keeping the validator here lets both the typed carrier and
-- the untyped snapshot fallback share the existing one-symbol/one-signature
-- refusal without asking typecheck to import lowering (which would be a cycle).
export
validateFfiExternTypeNames : List (String, (List String, String)) ->
  List (String, (List String, String))
validateFfiExternTypeNames rows =
  -- 🚨 THE INDEX IS BARE-NAME KEYED ACROSS THE WHOLE PROGRAM, so a name declared
  -- twice with two different signatures is a contradiction the index cannot hold
  -- ([T-GLOBAL-TABLE]).  Guard it HERE, in the wrapper, and not inside
  -- `ffiExternRows`: the property is about the FINISHED list, and `ffiExternRows`
  -- is a self-recursive walk that would have to re-scan its own tail at every step
  -- to ask it — the exact list-as-a-set shape `compiler/AGENTS.md` opens with.
  let _ = ffiCheckExternRowsDistinct omEmpty rows
  rows

-- Two modules may each declare `extern cDouble`, and the declared name IS the C
-- symbol (`compiler/FFI-ABI.md`), so both calls link to ONE C function.  If the two
-- declarations agree, that is legitimate sharing and this walk is silent.  If they
-- DISAGREE, `omFromPairs (reverseL …)` in `EmitInputData` keeps the first row and
-- marshals the other module's calls through it: `useY 4.0` against an
-- `Int -> Int` row printed 139888567046080 at exit 0, and the `Float -> Float`
-- variant of the same collision segfaulted.  Neither has any channel to reach the
-- author, so the contradiction is refused here rather than emitted.
--
-- A PANIC, not a located diagnostic, and that is the stage's own limit rather than
-- a choice: Core IR lowering runs post-typecheck, where [T-ERRORS-ACCUM]'s
-- accumulating pipeline is no longer available, and this is the same shape the two
-- existing whole-program injectivity guards in this file use
-- (`checkImplSymbolsInjective`, `dictWitnessTagGuard`) for the same reason.
--
-- ⚠️ The three data lines are UNINDENTED on purpose, matching
-- `checkImplSymbolsInjective`: they are CONTENT-derived, so a `stdout-line` pin can
-- match them with `grep -qxF` without false-draining on a rewording of the prose.
ffiCheckExternRowsDistinct : OrdMap String ->
  List (String, (List String, String)) ->
  Unit
ffiCheckExternRowsDistinct _ [] = ()
ffiCheckExternRowsDistinct seen ((n, sh) :: rest) =
  let k = ffiRowShapeKey sh
  match omLookup n seen
    None => ffiCheckExternRowsDistinct (omInsert n k seen) rest
    Some prev if prev == k => ffiCheckExternRowsDistinct seen rest
    Some prev =>
      panic
        "foreign declaration collision: the C symbol `\{n}` is declared twice with different signatures.\ncolliding symbol: \{n}\ndeclaration 1: \{prev}\ndeclaration 2: \{k}\nA foreign declaration's name IS the C symbol it links to, so both declarations name ONE C function and only one of these two signatures can describe it. The other module's calls would be marshalled through the wrong signature -- a wrong value at exit 0, or a memory fault. Give the two declarations the same signature, or declare the differing one against a differently-named C symbol."

-- The rendered `(argument heads, return head)` row, for the collision message and
-- the comparison behind it.  Same projection the index itself stores, so the guard
-- cannot be stricter or looser than the table it is protecting.
ffiRowShapeKey : (List String, String) -> String
ffiRowShapeKey (args, ret) = "\{joinWith "," args} -> \{ret}"

-- the `DExtern` names of a decl list, in order.
export
externDeclNamesOf : List Decl -> List String
externDeclNamesOf [] = []
externDeclNamesOf ((DExtern _ n _) :: rest) = n :: externDeclNamesOf rest
externDeclNamesOf ((DAttrib _ inner) :: rest) =
  externDeclNamesOf [inner] ++ externDeclNamesOf rest
externDeclNamesOf (_ :: rest) = externDeclNamesOf rest

-- Same (param-head-names, return-head-name) shape as `declSigTypeEntries`, so
-- the emitter reads one row type for both tables.  `tyHeadName` collapses
-- `Array Int` to `Array`, which is unambiguous HERE and only here: slice 1's
-- `ffiCrossableTy` guard rejects every non-crossable type — `Array` of anything
-- but `Int` included — before a user extern's signature can reach the emitter,
-- so `Array` in this table always means `Array Int`.
ffiExternRows : List String -> List Decl -> List (String, (List String, String))
ffiExternRows _ [] = []
ffiExternRows builtins ((DExtern _ n ty) :: rest)
  | contains n builtins = ffiExternRows builtins rest
  | otherwise =
    (n, (map tyHeadName (methodArgTys ty), tyHeadName (methodRetTy ty)))
      :: ffiExternRows builtins rest
ffiExternRows builtins ((DAttrib _ inner) :: rest) =
  ffiExternRows builtins (inner :: rest)
ffiExternRows builtins (_ :: rest) = ffiExternRows builtins rest

-- the RESULT type of a (possibly-constrained, possibly-effectful) function type
-- (the `r` of `a -> b -> … -> r`); a non-function type is its own result.
methodRetTy : Ty -> Ty
methodRetTy (TyConstrained _ t) = methodRetTy t
methodRetTy (TyEffect _ _ t) = methodRetTy t
methodRetTy (TyFun _ b) = methodRetTy b
methodRetTy (TyQual t _ _) = methodRetTy t
methodRetTy t = t

-- positions (0-based) whose type is a TyFun whose result mentions a param.
selfFnPositions : Int -> List Ty -> List String -> List Int
selfFnPositions _ [] _ = []
selfFnPositions i (t :: ts) params
  | tyIsFunReturningSelf t params = i :: selfFnPositions (i + 1) ts params
  | otherwise = selfFnPositions (i + 1) ts params

tyIsFunReturningSelf : Ty -> List String -> Bool
tyIsFunReturningSelf (TyFun _ b) params =
  tyMentionsParams (methodResultTy b) params
tyIsFunReturningSelf (TyConstrained _ t) params = tyIsFunReturningSelf t params
tyIsFunReturningSelf (TyEffect _ _ t) params = tyIsFunReturningSelf t params
tyIsFunReturningSelf _ _ = False

funClausesOf : List Decl -> List (String, CClause)
funClausesOf [] = []
funClausesOf ((DFunDef _ n pats body _) :: rest) =
  (n, CClause pats (lower body)) :: funClausesOf rest
-- Top-level `let rec … with …` (DLetGroup): flatten each binding's clauses
-- into (name, CClause) entries, mirroring eval.mdk's funDefs/letGroupDefs.
funClausesOf ((DLetGroup _ binds) :: rest) =
  letGroupClausesOf binds ++ funClausesOf rest
funClausesOf ((DAttrib _ d) :: rest) = funClausesOf (d :: rest)
funClausesOf (_ :: rest) = funClausesOf rest

letGroupClausesOf : List LetBind -> List (String, CClause)
letGroupClausesOf [] = []
letGroupClausesOf ((LetBind n clauses _) :: rest) =
  map (lowerLetBind n) clauses ++ letGroupClausesOf rest

lowerLetBind : String -> FunClause -> (String, CClause)
lowerLetBind n (FunClause pats body) = (n, CClause pats (lower body))

ctorArities : List Decl -> List (String, Int)
ctorArities [] = []
ctorArities ((DData { dataCtors = variants }) :: rest) =
  map variantArity variants ++ ctorArities rest
-- A newtype is structurally a single-constructor, single-field data type, so its
-- constructor is a callable arity-1 ctor (matches the oracle's `make_ctor con 1`).
-- Without this the emitter sees `UserId 42` as an unbound variable.
ctorArities ((DNewtype { newtypeCtor = con }) :: rest) =
  (con, 1) :: ctorArities rest
ctorArities ((DAttrib _ d) :: rest) = ctorArities (d :: rest)
ctorArities (_ :: rest) = ctorArities rest

variantArity : Variant -> (String, Int)
variantArity (Variant n payload) = (n, payloadArityL payload)

payloadArityL : ConPayload -> Int
payloadArityL (ConPos tys) = listLen tys
payloadArityL (ConNamed fs _) = listLen fs

-- a readable tag for the unsupported-node panic
nodeTag : Expr -> String
nodeTag (ESection _) = "ESection"
nodeTag (EGuards _) = "EGuards"
nodeTag (EDo _ _) = "EDo"
nodeTag (EStringInterp _) = "EStringInterp"
nodeTag (EVariantUpdate _ _ _) = "EVariantUpdate"
nodeTag (EMapLit _ _) = "EMapLit"
nodeTag (ESetLit _ _) = "ESetLit"
nodeTag (EAsPat _ _) = "EAsPat"
nodeTag (EMethodRef _) = "EMethodRef"
nodeTag (EDictApp _) = "EDictApp"
nodeTag _ = "?"
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Lit" true) (mem "Loc" true) (mem "noDeclLoc" false) (mem "Pat" true) (mem "RecPatField" true) (mem "Expr" true) (mem "Arm" true) (mem "Guard" true) (mem "DoStmt" true) (mem "FieldAssign" true) (mem "LetBind" true) (mem "FunClause" true) (mem "Addr" true) (mem "Decl" true) (mem "Variant" true) (mem "ConPayload" true) (mem "Field" true) (mem "Ty" true) (mem "Constraint" true) (mem "IfaceMethod" true) (mem "MethodDefault" true) (mem "ImplMethod" true) (mem "Route" true) (mem "TyConOrigin" false) (mem "ifaceIdentity" false) (mem "defaultReceiverDict" false))))
(DUse false (UseGroup ("types" "route_key") ((mem "implRouteKeyWord" false) (mem "ifaceWordOf" false) (mem "evDictRoutes" false) (mem "evMethodRoutes" false))))
(DUse false (UseGroup ("ir" "core_ir") ((mem "CExpr" true) (mem "CArm" true) (mem "CGuard" true) (mem "CStmt" true) (mem "CField" true) (mem "CBind" true) (mem "CClause" true) (mem "CImplEntry" true) (mem "CImplBody" true) (mem "CProgram" true) (mem "CTree" true) (mem "CTBranch" true) (mem "CHead" true) (mem "FailSite" true) (mem "siteSentinelName" false))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "mapProg" false))))
(DUse false (UseGroup ("frontend" "marker") ((mem "localBoundNames" false))))
(DUse false (UseGroup ("types" "disposition") ((mem "DispositionTable" false) (mem "InstanceShape" true) (mem "ifaceSuperCount" false) (mem "inheritorsOf" false) (mem "installedDispositions" false) (mem "installedDispositionsOpt" false))))
(DUse false (UseGroup ("eval" "eval") ((mem "buildCtorToType" false) (mem "installDispatchTables" false) (mem "lookupPositions" false) (mem "tyvarsInArgs" false) (mem "headTyconHead" false) (mem "exprStartLoc" false))))
(DUse false (UseGroup ("list") ((mem "replicate" false) (mem "take" false) (mem "drop" false) (mem "range" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omInsert" false) (mem "omHasKey" false) (mem "omLookup" false))))
(DUse false (UseGroup ("backend" "private_mangle") ((mem "dictTag" false) (mem "hashName" false) (mem "injectiveIdent" false))))
(DUse false (UseGroup ("support" "util") ((mem "contains" false) (mem "listLen" false) (mem "allList" false) (mem "anyList" false) (mem "lookupAssoc" false) (mem "noneHeadTag" false) (mem "isEmptyL" false) (mem "isNonEmptyL" false) (mem "joinWith" false) (mem "reverseL" false) (mem "startsWith" false) (mem "dedupBy" false) (mem "lenKey" false) (mem "splitOnChar" false))))
(DTypeSig false "composeVar" (TyCon "String"))
(DFunDef false "composeVar" () (ELit (LString "$cf")))
(DTypeSig false "cmethodOf" (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Route") (TyApp (TyCon "List") (TyCon "Route")) (TyApp (TyCon "List") (TyCon "Route"))) (TyCon "CExpr"))))
(DFunDef false "cmethodOf" ((PVar "name") (PTuple (PVar "iface") (PVar "arity") (PVar "route") (PVar "implRoutes") (PVar "methodRoutes"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "CMethod") (EVar "name")) (EVar "iface")) (EVar "arity")) (EVar "route")) (EVar "implRoutes")) (EVar "methodRoutes")))
(DTypeSig false "lower" (TyFun (TyCon "Expr") (TyCon "CExpr")))
(DFunDef false "lower" ((PCon "ELit" (PVar "l"))) (EApp (EVar "CLit") (EVar "l")))
(DFunDef false "lower" ((PCon "ENumLit" (PVar "n") (PVar "r") PWild PWild)) (EMatch (EUnOp "!" (EVar "r")) (arm (PCon "Some" (PVar "f")) () (EApp (EVar "CLit") (EApp (EVar "LFloat") (EVar "f")))) (arm (PCon "None") () (EApp (EVar "CLit") (EApp (EVar "LInt") (EVar "n"))))))
(DFunDef false "lower" ((PCon "EWideLit" (PVar "hi") (PVar "lo") PWild PWild)) (EApp (EVar "CLit") (EApp (EApp (EVar "LU64") (EVar "hi")) (EVar "lo"))))
(DFunDef false "lower" ((PCon "EVar" (PVar "x"))) (EApp (EApp (EVar "CVar") (EVar "x")) (EVar "AGlobal")))
(DFunDef false "lower" ((PCon "EVarId" (PVar "x") PWild)) (EApp (EApp (EVar "CVar") (EVar "x")) (EVar "AGlobal")))
(DFunDef false "lower" ((PCon "EVarAt" (PVar "x") (PVar "addr"))) (EApp (EApp (EVar "CVar") (EVar "x")) (EVar "addr")))
(DFunDef false "lower" ((PCon "EApp" (PVar "f") (PVar "x"))) (EApp (EApp (EVar "CApp") (EApp (EVar "lower") (EVar "f"))) (EApp (EVar "lower") (EVar "x"))))
(DFunDef false "lower" ((PCon "ELam" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "CLam") (EVar "pats")) (EApp (EVar "lower") (EVar "body"))))
(DFunDef false "lower" ((PCon "ELet" (PVar "site") (PCon "False") (PVar "pat") (PVar "e1") (PVar "e2"))) (EIf (EApp (EVar "patMayFail") (EVar "pat")) (EApp (EApp (EApp (EApp (EVar "letDecision") (EVar "site")) (EVar "pat")) (EApp (EVar "lower") (EVar "e1"))) (EApp (EVar "lower") (EVar "e2"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "lower" ((PCon "ELet" PWild (PVar "recFlag") (PVar "pat") (PVar "e1") (PVar "e2"))) (EApp (EApp (EApp (EApp (EVar "CLet") (EVar "recFlag")) (EVar "pat")) (EApp (EVar "lower") (EVar "e1"))) (EApp (EVar "lower") (EVar "e2"))))
(DFunDef false "lower" ((PCon "ELetGroup" (PVar "binds") (PVar "body"))) (EApp (EApp (EVar "CLetGroup") (EApp (EApp (EVar "map") (EVar "lowerBind")) (EVar "binds"))) (EApp (EVar "lower") (EVar "body"))))
(DFunDef false "lower" ((PCon "EMatch" (PVar "scrut") (PVar "arms"))) (EApp (EApp (EApp (EVar "lowerMatch") (EVar "noDeclLoc")) (EApp (EVar "lower") (EVar "scrut"))) (EVar "arms")))
(DFunDef false "lower" ((PCon "EIf" (PVar "c") (PVar "t") (PVar "e"))) (EApp (EApp (EApp (EVar "CIf") (EApp (EVar "lower") (EVar "c"))) (EApp (EVar "lower") (EVar "t"))) (EApp (EVar "lower") (EVar "e"))))
(DFunDef false "lower" ((PCon "EBinOp" (PVar "op") (PVar "l") (PVar "r") (PVar "route"))) (EApp (EApp (EApp (EApp (EVar "lowerBinop") (EVar "op")) (EVar "l")) (EVar "r")) (EApp (EVar "scalarTagOfRoute") (EUnOp "!" (EVar "route")))))
(DFunDef false "lower" ((PCon "EInfix" (PVar "op") (PVar "l") (PVar "r"))) (EApp (EApp (EVar "CApp") (EApp (EApp (EVar "CApp") (EApp (EApp (EVar "CVar") (EVar "op")) (EVar "AGlobal"))) (EApp (EVar "lower") (EVar "l")))) (EApp (EVar "lower") (EVar "r"))))
(DFunDef false "lower" ((PCon "EUnOp" (PLit (LString "!")) (PVar "e") PWild)) (EApp (EApp (EApp (EVar "CFieldAccess") (EApp (EVar "lower") (EVar "e"))) (ELit (LString "value"))) (ELit (LString ""))))
(DFunDef false "lower" ((PCon "EUnOp" (PVar "op") (PVar "e") PWild)) (EApp (EApp (EVar "CUnOp") (EVar "op")) (EApp (EVar "lower") (EVar "e"))))
(DFunDef false "lower" ((PCon "ETuple" (PVar "es"))) (EApp (EVar "CTuple") (EApp (EApp (EVar "map") (EVar "lower")) (EVar "es"))))
(DFunDef false "lower" ((PCon "EListLit" (PVar "es"))) (EApp (EVar "CList") (EApp (EApp (EVar "map") (EVar "lower")) (EVar "es"))))
(DFunDef false "lower" ((PCon "EArrayLit" (PVar "es"))) (EApp (EVar "CArray") (EApp (EApp (EVar "map") (EVar "lower")) (EVar "es"))))
(DFunDef false "lower" ((PCon "ERangeList" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EVar "CRangeList") (EApp (EVar "lower") (EVar "lo"))) (EApp (EVar "lower") (EVar "hi"))) (EVar "incl")))
(DFunDef false "lower" ((PCon "ERangeArray" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EVar "CRangeArray") (EApp (EVar "lower") (EVar "lo"))) (EApp (EVar "lower") (EVar "hi"))) (EVar "incl")))
(DFunDef false "lower" ((PCon "EIndex" (PVar "a") (PVar "i") (PVar "r"))) (EIf (EBinOp "==" (EUnOp "!" (EVar "r")) (ELit (LString "String"))) (EApp (EApp (EVar "CStringIndex") (EApp (EVar "lower") (EVar "a"))) (EApp (EVar "lower") (EVar "i"))) (EIf (EBinOp "==" (EUnOp "!" (EVar "r")) (ELit (LString "List"))) (EApp (EApp (EVar "CListIndex") (EApp (EVar "lower") (EVar "a"))) (EApp (EVar "lower") (EVar "i"))) (EApp (EApp (EVar "CIndex") (EApp (EVar "lower") (EVar "a"))) (EApp (EVar "lower") (EVar "i"))))))
(DFunDef false "lower" ((PCon "ESlice" (PVar "a") (PVar "lo") (PVar "hi") (PVar "incl") (PVar "r"))) (EIf (EBinOp "==" (EUnOp "!" (EVar "r")) (ELit (LString "String"))) (EApp (EApp (EApp (EApp (EVar "CStringSlice") (EApp (EVar "lower") (EVar "a"))) (EApp (EVar "lower") (EVar "lo"))) (EApp (EVar "lower") (EVar "hi"))) (EVar "incl")) (EIf (EBinOp "==" (EUnOp "!" (EVar "r")) (ELit (LString "List"))) (EApp (EApp (EApp (EApp (EVar "CListSlice") (EApp (EVar "lower") (EVar "a"))) (EApp (EVar "lower") (EVar "lo"))) (EApp (EVar "lower") (EVar "hi"))) (EVar "incl")) (EApp (EApp (EApp (EApp (EVar "CSlice") (EApp (EVar "lower") (EVar "a"))) (EApp (EVar "lower") (EVar "lo"))) (EApp (EVar "lower") (EVar "hi"))) (EVar "incl")))))
(DFunDef false "lower" ((PCon "EFieldAccess" (PVar "e") (PVar "f") (PVar "r"))) (EApp (EApp (EApp (EVar "CFieldAccess") (EApp (EVar "lower") (EVar "e"))) (EVar "f")) (EUnOp "!" (EVar "r"))))
(DFunDef false "lower" ((PCon "ERecordCreate" (PVar "name") (PVar "fields"))) (EApp (EApp (EVar "CRecord") (EVar "name")) (EApp (EApp (EVar "map") (EVar "lowerField")) (EVar "fields"))))
(DFunDef false "lower" ((PCon "ERecordUpdate" (PVar "base") (PVar "fields") (PVar "r"))) (EApp (EApp (EApp (EVar "CRecordUpdate") (EUnOp "!" (EVar "r"))) (EApp (EVar "lower") (EVar "base"))) (EApp (EApp (EVar "map") (EVar "lowerField")) (EVar "fields"))))
(DFunDef false "lower" ((PCon "EVariantUpdate" (PVar "con") (PVar "base") (PVar "fields"))) (EApp (EApp (EApp (EVar "CVariantUpdate") (EVar "con")) (EApp (EVar "lower") (EVar "base"))) (EApp (EApp (EVar "map") (EVar "lowerField")) (EVar "fields"))))
(DFunDef false "lower" ((PCon "EBlock" (PVar "stmts"))) (EApp (EVar "CBlock") (EApp (EVar "lowerStmts") (EVar "stmts"))))
(DFunDef false "lower" ((PCon "EAnnot" (PCon "EBinOp" (PVar "op") (PVar "l") (PVar "r") PWild) (PRec "TyCon" ((rf "tyConName" (PVar "tag"))) false))) (EApp (EApp (EApp (EApp (EVar "lowerBinop") (EVar "op")) (EVar "l")) (EVar "r")) (EVar "tag")))
(DFunDef false "lower" ((PCon "EAnnot" (PVar "e") PWild)) (EApp (EVar "lower") (EVar "e")))
(DFunDef false "lower" ((PCon "EHeadAnnot" (PVar "e") PWild)) (EApp (EVar "lower") (EVar "e")))
(DFunDef false "lower" ((PCon "EMethodAt" (PVar "name") PWild (PVar "ev"))) (EApp (EApp (EVar "cmethodOf") (EVar "name")) (EApp (EVar "evMethodRoutes") (EVar "ev"))))
(DFunDef false "lower" ((PCon "EDictAt" (PVar "name") (PVar "ev"))) (EApp (EApp (EVar "CDict") (EVar "name")) (EApp (EVar "evDictRoutes") (EVar "ev"))))
(DFunDef false "lower" ((PCon "ELoc" (PVar "l") (PCon "EMatch" (PVar "scrut") (PVar "arms")))) (EApp (EApp (EApp (EVar "lowerMatch") (EVar "l")) (EApp (EVar "lower") (EVar "scrut"))) (EVar "arms")))
(DFunDef false "lower" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "lower") (EVar "e")))
(DFunDef false "lower" ((PCon "EDoOrigin" PWild (PVar "e"))) (EApp (EVar "lower") (EVar "e")))
(DFunDef false "lower" ((PVar "other")) (EApp (EVar "panic") (EBinOp "++" (ELit (LString "core_ir lower: unsupported node ")) (EApp (EVar "nodeTag") (EVar "other")))))
(DTypeSig false "scalarTagOfRoute" (TyFun (TyCon "Route") (TyCon "String")))
(DFunDef false "scalarTagOfRoute" ((PCon "RScalar" (PVar "s"))) (EVar "s"))
(DFunDef false "scalarTagOfRoute" (PWild) (ELit (LString "")))
(DTypeSig false "lowerBinop" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyFun (TyCon "String") (TyCon "CExpr"))))))
(DFunDef false "lowerBinop" ((PLit (LString "&&")) (PVar "l") (PVar "r") PWild) (EApp (EApp (EApp (EVar "CIf") (EApp (EVar "lower") (EVar "l"))) (EApp (EVar "lower") (EVar "r"))) (EApp (EVar "CLit") (EApp (EVar "LBool") (EVar "False")))))
(DFunDef false "lowerBinop" ((PLit (LString "||")) (PVar "l") (PVar "r") PWild) (EApp (EApp (EApp (EVar "CIf") (EApp (EVar "lower") (EVar "l"))) (EApp (EVar "CLit") (EApp (EVar "LBool") (EVar "True")))) (EApp (EVar "lower") (EVar "r"))))
(DFunDef false "lowerBinop" ((PLit (LString "|>")) (PVar "l") (PVar "r") PWild) (EApp (EApp (EVar "CApp") (EApp (EVar "lower") (EVar "r"))) (EApp (EVar "lower") (EVar "l"))))
(DFunDef false "lowerBinop" ((PLit (LString ">>")) (PVar "l") (PVar "r") PWild) (EApp (EApp (EVar "composeLam") (EApp (EVar "lower") (EVar "l"))) (EApp (EVar "lower") (EVar "r"))))
(DFunDef false "lowerBinop" ((PLit (LString "<<")) (PVar "l") (PVar "r") PWild) (EApp (EApp (EVar "composeLam") (EApp (EVar "lower") (EVar "r"))) (EApp (EVar "lower") (EVar "l"))))
(DFunDef false "lowerBinop" ((PVar "op") (PVar "l") (PVar "r") (PVar "tag")) (EApp (EApp (EApp (EApp (EApp (EVar "CBinPrim") (EVar "op")) (EApp (EVar "lower") (EVar "l"))) (EApp (EVar "lower") (EVar "r"))) (EVar "tag")) (EApp (EVar "exprStartLoc") (EVar "l"))))
(DTypeSig false "composeLam" (TyFun (TyCon "CExpr") (TyFun (TyCon "CExpr") (TyCon "CExpr"))))
(DFunDef false "composeLam" ((PVar "first") (PVar "second")) (EApp (EApp (EVar "CLam") (EListLit (EApp (EApp (EVar "PVar") (EVar "composeVar")) (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString ""))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0)))))) (EApp (EApp (EVar "CApp") (EVar "second")) (EApp (EApp (EVar "CApp") (EVar "first")) (EApp (EApp (EVar "CVar") (EVar "composeVar")) (EVar "AGlobal"))))))
(DTypeSig false "lowerArm" (TyFun (TyCon "Arm") (TyCon "CArm")))
(DFunDef false "lowerArm" ((PCon "Arm" (PVar "pat") (PVar "guards") (PVar "body"))) (EApp (EApp (EApp (EVar "CArm") (EVar "pat")) (EApp (EApp (EVar "map") (EVar "lowerGuard")) (EVar "guards"))) (EApp (EVar "lower") (EVar "body"))))
(DTypeSig false "lowerGuard" (TyFun (TyCon "Guard") (TyCon "CGuard")))
(DFunDef false "lowerGuard" ((PCon "GBool" (PVar "e"))) (EApp (EVar "CGBool") (EApp (EVar "lower") (EVar "e"))))
(DFunDef false "lowerGuard" ((PCon "GBind" (PVar "p") (PVar "e"))) (EApp (EApp (EVar "CGBind") (EVar "p")) (EApp (EVar "lower") (EVar "e"))))
(DTypeSig false "lowerMatch" (TyFun (TyCon "Loc") (TyFun (TyCon "CExpr") (TyFun (TyApp (TyCon "List") (TyCon "Arm")) (TyCon "CExpr")))))
(DFunDef false "lowerMatch" ((PVar "site") (PVar "cscrut") (PVar "arms")) (EIf (EApp (EApp (EVar "allList") (EVar "armTreeable")) (EVar "arms")) (EApp (EApp (EApp (EVar "CDecision") (EVar "cscrut")) (EApp (EApp (EVar "map") (EVar "lowerArm")) (EVar "arms"))) (EApp (EApp (EVar "compileArms") (EApp (EVar "NoArm") (EVar "site"))) (EVar "arms"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "CMatch") (EVar "cscrut")) (EApp (EApp (EVar "map") (EVar "lowerArm")) (EVar "arms"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "letDecision" (TyFun (TyCon "Loc") (TyFun (TyCon "Pat") (TyFun (TyCon "CExpr") (TyFun (TyCon "CExpr") (TyCon "CExpr"))))))
(DFunDef false "letDecision" ((PVar "site") (PVar "pat") (PVar "scrut") (PVar "body")) (EBlock (DoLet false false (PVar "arms") (EListLit (EApp (EApp (EApp (EVar "CArm") (EVar "pat")) (EListLit)) (EVar "body")))) (DoExpr (EApp (EApp (EApp (EVar "CDecision") (EVar "scrut")) (EVar "arms")) (EApp (EApp (EVar "compileArmsC") (EApp (EVar "LetRefuted") (EVar "site"))) (EVar "arms"))))))
(DTypeSig false "patMayFail" (TyFun (TyCon "Pat") (TyCon "Bool")))
(DFunDef false "patMayFail" ((PCon "PWild")) (EVar "False"))
(DFunDef false "patMayFail" ((PCon "PVar" PWild PWild)) (EVar "False"))
(DFunDef false "patMayFail" ((PCon "PLit" (PCon "LUnit"))) (EVar "False"))
(DFunDef false "patMayFail" ((PCon "PAs" PWild PWild (PVar "p"))) (EApp (EVar "patMayFail") (EVar "p")))
(DFunDef false "patMayFail" ((PCon "PTuple" (PVar "ps"))) (EApp (EApp (EVar "anyList") (EVar "patMayFail")) (EVar "ps")))
(DFunDef false "patMayFail" (PWild) (EVar "True"))
(DTypeSig false "lowerStmts" (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyApp (TyCon "List") (TyCon "CStmt"))))
(DFunDef false "lowerStmts" ((PList)) (EListLit))
(DFunDef false "lowerStmts" ((PCons (PCon "DoLet" PWild (PCon "False") (PVar "pat") (PVar "e") (PVar "site")) (PVar "rest"))) (EIf (EApp (EVar "patMayFail") (EVar "pat")) (EListLit (EApp (EVar "CSExpr") (EApp (EApp (EApp (EApp (EVar "letDecision") (EVar "site")) (EVar "pat")) (EApp (EVar "lower") (EVar "e"))) (EApp (EVar "CBlock") (EApp (EVar "lowerStmts") (EVar "rest")))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "lowerStmts" ((PCons (PVar "s") (PVar "rest"))) (EBinOp "::" (EApp (EVar "lowerStmt") (EVar "s")) (EApp (EVar "lowerStmts") (EVar "rest"))))
(DTypeSig false "armTreeable" (TyFun (TyCon "Arm") (TyCon "Bool")))
(DFunDef false "armTreeable" ((PCon "Arm" (PVar "pat") PWild PWild)) (EApp (EVar "treeablePat") (EVar "pat")))
(DTypeSig false "treeablePat" (TyFun (TyCon "Pat") (TyCon "Bool")))
(DFunDef false "treeablePat" ((PCon "PWild")) (EVar "True"))
(DFunDef false "treeablePat" ((PCon "PVar" PWild PWild)) (EVar "True"))
(DFunDef false "treeablePat" ((PCon "PLit" PWild)) (EVar "True"))
(DFunDef false "treeablePat" ((PCon "PCon" PWild (PVar "args"))) (EApp (EApp (EVar "allList") (EVar "treeablePat")) (EVar "args")))
(DFunDef false "treeablePat" ((PCon "PCons" (PVar "h") (PVar "t"))) (EBinOp "&&" (EApp (EVar "treeablePat") (EVar "h")) (EApp (EVar "treeablePat") (EVar "t"))))
(DFunDef false "treeablePat" ((PCon "PList" (PVar "ps"))) (EApp (EApp (EVar "allList") (EVar "treeablePat")) (EVar "ps")))
(DFunDef false "treeablePat" ((PCon "PTuple" (PVar "ps"))) (EApp (EApp (EVar "allList") (EVar "treeablePat")) (EVar "ps")))
(DFunDef false "treeablePat" ((PCon "PAs" PWild PWild (PVar "p"))) (EApp (EVar "treeablePat") (EVar "p")))
(DFunDef false "treeablePat" ((PCon "PRng" PWild PWild PWild)) (EVar "True"))
(DFunDef false "treeablePat" ((PCon "PRec" PWild PWild PWild)) (EVar "True"))
(DTypeSig false "compileArms" (TyFun (TyCon "FailSite") (TyFun (TyApp (TyCon "List") (TyCon "Arm")) (TyCon "CTree"))))
(DFunDef false "compileArms" ((PVar "site") (PVar "arms")) (EApp (EApp (EApp (EVar "compileTree") (EVar "site")) (EApp (EApp (EVar "map") (EVar "armHasGuard")) (EVar "arms"))) (EApp (EApp (EVar "initialRows") (EVar "arms")) (ELit (LInt 0)))))
(DTypeSig false "armHasGuard" (TyFun (TyCon "Arm") (TyCon "Bool")))
(DFunDef false "armHasGuard" ((PCon "Arm" (PVar "pat") (PVar "gs") PWild)) (EBinOp "||" (EApp (EVar "isNonEmptyL") (EVar "gs")) (EApp (EVar "patNeedsGuard") (EVar "pat"))))
(DTypeSig false "patNeedsGuard" (TyFun (TyCon "Pat") (TyCon "Bool")))
(DFunDef false "patNeedsGuard" ((PCon "PRng" PWild PWild PWild)) (EVar "True"))
(DFunDef false "patNeedsGuard" ((PCon "PRec" PWild PWild PWild)) (EVar "True"))
(DFunDef false "patNeedsGuard" ((PCon "PCon" PWild (PVar "args"))) (EApp (EApp (EVar "anyList") (EVar "patNeedsGuard")) (EVar "args")))
(DFunDef false "patNeedsGuard" ((PCon "PCons" (PVar "h") (PVar "t"))) (EBinOp "||" (EApp (EVar "patNeedsGuard") (EVar "h")) (EApp (EVar "patNeedsGuard") (EVar "t"))))
(DFunDef false "patNeedsGuard" ((PCon "PList" (PVar "ps"))) (EApp (EApp (EVar "anyList") (EVar "patNeedsGuard")) (EVar "ps")))
(DFunDef false "patNeedsGuard" ((PCon "PTuple" (PVar "ps"))) (EApp (EApp (EVar "anyList") (EVar "patNeedsGuard")) (EVar "ps")))
(DFunDef false "patNeedsGuard" ((PCon "PAs" PWild PWild (PVar "p"))) (EApp (EVar "patNeedsGuard") (EVar "p")))
(DFunDef false "patNeedsGuard" (PWild) (EVar "False"))
(DTypeSig false "initialRows" (TyFun (TyApp (TyCon "List") (TyCon "Arm")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))))))
(DFunDef false "initialRows" ((PList) PWild) (EListLit))
(DFunDef false "initialRows" ((PCons (PCon "Arm" (PVar "pat") PWild PWild) (PVar "rest")) (PVar "i")) (EBinOp "::" (ETuple (EListLit (EApp (EVar "canonPat") (EVar "pat"))) (EVar "i")) (EApp (EApp (EVar "initialRows") (EVar "rest")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))
(DTypeSig true "compileTree" (TyFun (TyCon "FailSite") (TyFun (TyApp (TyCon "List") (TyCon "Bool")) (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))) (TyCon "CTree")))))
(DFunDef false "compileTree" ((PVar "site") (PVar "guards") (PVar "rows")) (EApp (EApp (EVar "withFailSite") (EVar "site")) (EApp (EApp (EVar "compileTreeG") (EApp (EApp (EApp (EVar "guardSet") (ELit (LInt 0))) (EVar "guards")) (EVar "omEmpty"))) (EVar "rows"))))
(DTypeSig false "withFailSite" (TyFun (TyCon "FailSite") (TyFun (TyCon "CTree") (TyCon "CTree"))))
(DFunDef false "withFailSite" ((PVar "site") (PCon "CTFail" PWild)) (EApp (EVar "CTFail") (EVar "site")))
(DFunDef false "withFailSite" (PWild (PCon "CTLeaf" (PVar "i"))) (EApp (EVar "CTLeaf") (EVar "i")))
(DFunDef false "withFailSite" ((PVar "site") (PCon "CTGuard" (PVar "i") (PVar "t"))) (EApp (EApp (EVar "CTGuard") (EVar "i")) (EApp (EApp (EVar "withFailSite") (EVar "site")) (EVar "t"))))
(DFunDef false "withFailSite" ((PVar "site") (PCon "CTSwitch" (PVar "bs") (PVar "d"))) (EApp (EApp (EVar "CTSwitch") (EApp (EApp (EVar "map") (EApp (EVar "failSiteBranch") (EVar "site"))) (EVar "bs"))) (EApp (EApp (EVar "withFailSite") (EVar "site")) (EVar "d"))))
(DFunDef false "withFailSite" ((PVar "site") (PCon "CTDrop" (PVar "t"))) (EApp (EVar "CTDrop") (EApp (EApp (EVar "withFailSite") (EVar "site")) (EVar "t"))))
(DTypeSig false "failSiteBranch" (TyFun (TyCon "FailSite") (TyFun (TyCon "CTBranch") (TyCon "CTBranch"))))
(DFunDef false "failSiteBranch" ((PVar "site") (PCon "CTBranch" (PVar "h") (PVar "t"))) (EApp (EApp (EVar "CTBranch") (EVar "h")) (EApp (EApp (EVar "withFailSite") (EVar "site")) (EVar "t"))))
(DTypeSig false "treeFailSite" (TyFun (TyCon "CTree") (TyCon "FailSite")))
(DFunDef false "treeFailSite" ((PVar "t")) (EMatch (EApp (EVar "treeFailSiteOpt") (EVar "t")) (arm (PCon "Some" (PVar "s")) () (EVar "s")) (arm (PCon "None") () (EApp (EVar "NoArm") (EVar "noDeclLoc")))))
(DTypeSig false "treeFailSiteOpt" (TyFun (TyCon "CTree") (TyApp (TyCon "Option") (TyCon "FailSite"))))
(DFunDef false "treeFailSiteOpt" ((PCon "CTFail" (PVar "s"))) (EApp (EVar "Some") (EVar "s")))
(DFunDef false "treeFailSiteOpt" ((PCon "CTLeaf" PWild)) (EVar "None"))
(DFunDef false "treeFailSiteOpt" ((PCon "CTGuard" PWild (PVar "t"))) (EApp (EVar "treeFailSiteOpt") (EVar "t")))
(DFunDef false "treeFailSiteOpt" ((PCon "CTSwitch" (PVar "bs") (PVar "d"))) (EMatch (EApp (EVar "firstBranchFailSite") (EVar "bs")) (arm (PCon "Some" (PVar "s")) () (EApp (EVar "Some") (EVar "s"))) (arm (PCon "None") () (EApp (EVar "treeFailSiteOpt") (EVar "d")))))
(DFunDef false "treeFailSiteOpt" ((PCon "CTDrop" (PVar "t"))) (EApp (EVar "treeFailSiteOpt") (EVar "t")))
(DTypeSig false "firstBranchFailSite" (TyFun (TyApp (TyCon "List") (TyCon "CTBranch")) (TyApp (TyCon "Option") (TyCon "FailSite"))))
(DFunDef false "firstBranchFailSite" ((PList)) (EVar "None"))
(DFunDef false "firstBranchFailSite" ((PCons (PCon "CTBranch" PWild (PVar "t")) (PVar "rest"))) (EMatch (EApp (EVar "treeFailSiteOpt") (EVar "t")) (arm (PCon "Some" (PVar "s")) () (EApp (EVar "Some") (EVar "s"))) (arm (PCon "None") () (EApp (EVar "firstBranchFailSite") (EVar "rest")))))
(DTypeSig false "guardSet" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Bool")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit"))))))
(DFunDef false "guardSet" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "guardSet" ((PVar "i") (PCons (PCon "True") (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "guardSet") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EApp (EVar "intToString") (EVar "i"))) (ELit LUnit)) (EVar "acc"))))
(DFunDef false "guardSet" ((PVar "i") (PCons (PCon "False") (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "guardSet") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest")) (EVar "acc")))
(DTypeSig false "compileTreeG" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))) (TyCon "CTree"))))
(DFunDef false "compileTreeG" (PWild (PList)) (EApp (EVar "CTFail") (EApp (EVar "NoArm") (EVar "noDeclLoc"))))
(DFunDef false "compileTreeG" ((PVar "guards") (PCons (PVar "row") (PVar "rest"))) (EApp (EApp (EApp (EApp (EVar "compileRows") (EVar "guards")) (EVar "row")) (EVar "rest")) (EBinOp "::" (EVar "row") (EVar "rest"))))
(DTypeSig false "compileRows" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))) (TyCon "CTree"))))))
(DFunDef false "compileRows" ((PVar "guards") (PTuple (PVar "pats") (PVar "i")) (PVar "rest") (PVar "rows")) (EIf (EApp (EVar "allWild") (EVar "pats")) (EApp (EApp (EApp (EVar "leafOrGuard") (EVar "guards")) (EVar "i")) (EVar "rest")) (EIf (EApp (EApp (EVar "anyList") (EVar "rowHasCon")) (EVar "rows")) (EApp (EApp (EVar "buildConSwitch") (EVar "guards")) (EVar "rows")) (EIf (EApp (EApp (EVar "anyList") (EVar "rowHasLit")) (EVar "rows")) (EApp (EApp (EVar "buildLitSwitch") (EVar "guards")) (EVar "rows")) (EIf (EVar "otherwise") (EApp (EVar "CTDrop") (EApp (EApp (EVar "compileTreeG") (EVar "guards")) (EApp (EApp (EVar "map") (EVar "dropHead")) (EVar "rows")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "leafOrGuard" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))) (TyCon "CTree")))))
(DFunDef false "leafOrGuard" ((PVar "guards") (PVar "i") (PVar "rest")) (EIf (EApp (EApp (EVar "omHasKey") (EApp (EVar "intToString") (EVar "i"))) (EVar "guards")) (EApp (EApp (EVar "CTGuard") (EVar "i")) (EApp (EApp (EVar "compileTreeG") (EVar "guards")) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EVar "CTLeaf") (EVar "i")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "buildConSwitch" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))) (TyCon "CTree"))))
(DFunDef false "buildConSwitch" ((PVar "guards") (PVar "rows")) (EBlock (DoLet false false (PVar "buckets") (EApp (EApp (EApp (EVar "conBuckets") (ELit (LInt 0))) (EVar "rows")) (EVar "omEmpty"))) (DoLet false false (PVar "wilds") (EApp (EApp (EVar "wildTailRows") (ELit (LInt 0))) (EVar "rows"))) (DoExpr (EApp (EApp (EVar "CTSwitch") (EApp (EApp (EVar "map") (EApp (EApp (EApp (EVar "conBranch") (EVar "guards")) (EVar "buckets")) (EVar "wilds"))) (EApp (EVar "distinctConHeads") (EVar "rows")))) (EApp (EApp (EVar "compileTreeG") (EVar "guards")) (EApp (EVar "defaultMatrix") (EVar "rows")))))))
(DTypeSig false "conBranch" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int")))) (TyFun (TyTuple (TyCon "String") (TyCon "Int")) (TyCon "CTBranch"))))))
(DFunDef false "conBranch" ((PVar "guards") (PVar "buckets") (PVar "wilds") (PTuple (PVar "c") (PVar "a"))) (EApp (EApp (EVar "CTBranch") (EApp (EApp (EVar "decodeHead") (EVar "c")) (EVar "a"))) (EApp (EApp (EVar "compileTreeG") (EVar "guards")) (EApp (EApp (EVar "mergeByOrd") (EApp (EVar "reverseL") (EApp (EApp (EVar "bucketRows") (EVar "c")) (EVar "buckets")))) (EApp (EApp (EVar "map") (EApp (EVar "padWildRow") (EVar "a"))) (EVar "wilds"))))))
(DTypeSig false "buildLitSwitch" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))) (TyCon "CTree"))))
(DFunDef false "buildLitSwitch" ((PVar "guards") (PVar "rows")) (EBlock (DoLet false false (PVar "buckets") (EApp (EApp (EApp (EVar "litBuckets") (ELit (LInt 0))) (EVar "rows")) (EVar "omEmpty"))) (DoLet false false (PVar "wilds") (EApp (EApp (EVar "wildTailRows") (ELit (LInt 0))) (EVar "rows"))) (DoExpr (EApp (EApp (EVar "CTSwitch") (EApp (EApp (EVar "map") (EApp (EApp (EApp (EVar "litBranch") (EVar "guards")) (EVar "buckets")) (EVar "wilds"))) (EApp (EVar "distinctLits") (EVar "rows")))) (EApp (EApp (EVar "compileTreeG") (EVar "guards")) (EApp (EVar "defaultMatrix") (EVar "rows")))))))
(DTypeSig false "litBranch" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int")))) (TyFun (TyCon "Lit") (TyCon "CTBranch"))))))
(DFunDef false "litBranch" ((PVar "guards") (PVar "buckets") (PVar "wilds") (PVar "l")) (EApp (EApp (EVar "CTBranch") (EApp (EVar "HLit") (EVar "l"))) (EApp (EApp (EVar "compileTreeG") (EVar "guards")) (EApp (EApp (EVar "mergeByOrd") (EApp (EVar "reverseL") (EApp (EApp (EVar "bucketRows") (EApp (EVar "litKey") (EVar "l"))) (EVar "buckets")))) (EVar "wilds")))))
(DTypeSig false "decodeHead" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "CHead"))))
(DFunDef false "decodeHead" ((PLit (LString "__cons__")) PWild) (EVar "HCons"))
(DFunDef false "decodeHead" ((PLit (LString "__nil__")) PWild) (EVar "HNil"))
(DFunDef false "decodeHead" ((PLit (LString "__unit__")) PWild) (EVar "HUnit"))
(DFunDef false "decodeHead" ((PLit (LString "__tuple__")) (PVar "a")) (EApp (EVar "HTuple") (EVar "a")))
(DFunDef false "decodeHead" ((PVar "c") (PVar "a")) (EApp (EApp (EVar "HCon") (EVar "c")) (EVar "a")))
(DTypeSig false "tupleName" (TyCon "String"))
(DFunDef false "tupleName" () (ELit (LString "__tuple__")))
(DTypeSig false "consName" (TyCon "String"))
(DFunDef false "consName" () (ELit (LString "__cons__")))
(DTypeSig false "nilName" (TyCon "String"))
(DFunDef false "nilName" () (ELit (LString "__nil__")))
(DTypeSig false "unitName" (TyCon "String"))
(DFunDef false "unitName" () (ELit (LString "__unit__")))
(DTypeSig true "canonPat" (TyFun (TyCon "Pat") (TyCon "Pat")))
(DFunDef false "canonPat" ((PCon "PVar" PWild PWild)) (EVar "PWild"))
(DFunDef false "canonPat" ((PCon "PWild")) (EVar "PWild"))
(DFunDef false "canonPat" ((PCon "PLit" (PCon "LBool" (PCon "True")))) (EApp (EApp (EVar "PCon") (ELit (LString "True"))) (EListLit)))
(DFunDef false "canonPat" ((PCon "PLit" (PCon "LBool" (PCon "False")))) (EApp (EApp (EVar "PCon") (ELit (LString "False"))) (EListLit)))
(DFunDef false "canonPat" ((PCon "PLit" (PCon "LUnit"))) (EApp (EApp (EVar "PCon") (EVar "unitName")) (EListLit)))
(DFunDef false "canonPat" ((PCon "PLit" (PVar "l"))) (EApp (EVar "PLit") (EVar "l")))
(DFunDef false "canonPat" ((PCon "PTuple" (PVar "ps"))) (EApp (EApp (EVar "PCon") (EVar "tupleName")) (EApp (EApp (EVar "map") (EVar "canonPat")) (EVar "ps"))))
(DFunDef false "canonPat" ((PCon "PCon" (PVar "c") (PVar "args"))) (EApp (EApp (EVar "PCon") (EVar "c")) (EApp (EApp (EVar "map") (EVar "canonPat")) (EVar "args"))))
(DFunDef false "canonPat" ((PCon "PCons" (PVar "h") (PVar "t"))) (EApp (EApp (EVar "PCon") (EVar "consName")) (EListLit (EApp (EVar "canonPat") (EVar "h")) (EApp (EVar "canonPat") (EVar "t")))))
(DFunDef false "canonPat" ((PCon "PList" (PList))) (EApp (EApp (EVar "PCon") (EVar "nilName")) (EListLit)))
(DFunDef false "canonPat" ((PCon "PList" (PCons (PVar "h") (PVar "r")))) (EApp (EApp (EVar "PCon") (EVar "consName")) (EListLit (EApp (EVar "canonPat") (EVar "h")) (EApp (EVar "canonPat") (EApp (EVar "PList") (EVar "r"))))))
(DFunDef false "canonPat" ((PCon "PAs" PWild PWild (PVar "p"))) (EApp (EVar "canonPat") (EVar "p")))
(DFunDef false "canonPat" ((PCon "PRng" PWild PWild PWild)) (EVar "PWild"))
(DFunDef false "canonPat" ((PCon "PRec" PWild PWild PWild)) (EVar "PWild"))
(DTypeSig false "allWild" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Bool")))
(DFunDef false "allWild" ((PVar "ps")) (EApp (EApp (EVar "allList") (EVar "isWildPat")) (EVar "ps")))
(DTypeSig false "isWildPat" (TyFun (TyCon "Pat") (TyCon "Bool")))
(DFunDef false "isWildPat" ((PCon "PWild")) (EVar "True"))
(DFunDef false "isWildPat" (PWild) (EVar "False"))
(DTypeSig false "rowHasCon" (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int")) (TyCon "Bool")))
(DFunDef false "rowHasCon" ((PTuple (PCons (PCon "PCon" PWild PWild) PWild) PWild)) (EVar "True"))
(DFunDef false "rowHasCon" (PWild) (EVar "False"))
(DTypeSig false "rowHasLit" (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int")) (TyCon "Bool")))
(DFunDef false "rowHasLit" ((PTuple (PCons (PCon "PLit" PWild) PWild) PWild)) (EVar "True"))
(DFunDef false "rowHasLit" (PWild) (EVar "False"))
(DTypeSig false "dropHead" (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int")) (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))))
(DFunDef false "dropHead" ((PTuple (PCons PWild (PVar "ps")) (PVar "i"))) (ETuple (EVar "ps") (EVar "i")))
(DFunDef false "dropHead" ((PTuple (PList) (PVar "i"))) (ETuple (EListLit) (EVar "i")))
(DTypeSig false "distinctConHeads" (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int")))))
(DFunDef false "distinctConHeads" ((PVar "rows")) (EApp (EApp (EVar "dedupHeads") (EApp (EVar "colHeads") (EVar "rows"))) (EVar "omEmpty")))
(DTypeSig false "colHeads" (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int")))))
(DFunDef false "colHeads" ((PList)) (EListLit))
(DFunDef false "colHeads" ((PCons (PTuple (PCons (PCon "PCon" (PVar "c") (PVar "args")) PWild) PWild) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "c") (EApp (EVar "listLen") (EVar "args"))) (EApp (EVar "colHeads") (EVar "rest"))))
(DFunDef false "colHeads" ((PCons PWild (PVar "rest"))) (EApp (EVar "colHeads") (EVar "rest")))
(DTypeSig false "dedupHeads" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))))))
(DFunDef false "dedupHeads" ((PList) PWild) (EListLit))
(DFunDef false "dedupHeads" ((PCons (PTuple (PVar "c") (PVar "a")) (PVar "rest")) (PVar "seen")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "c")) (EVar "seen")) (EApp (EApp (EVar "dedupHeads") (EVar "rest")) (EVar "seen")) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "c") (EVar "a")) (EApp (EApp (EVar "dedupHeads") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "c")) (ELit LUnit)) (EVar "seen")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "distinctLits" (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))) (TyApp (TyCon "List") (TyCon "Lit"))))
(DFunDef false "distinctLits" ((PVar "rows")) (EApp (EApp (EVar "dedupLits") (EApp (EVar "colLits") (EVar "rows"))) (EVar "omEmpty")))
(DTypeSig false "colLits" (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))) (TyApp (TyCon "List") (TyCon "Lit"))))
(DFunDef false "colLits" ((PList)) (EListLit))
(DFunDef false "colLits" ((PCons (PTuple (PCons (PCon "PLit" (PVar "l")) PWild) PWild) (PVar "rest"))) (EBinOp "::" (EVar "l") (EApp (EVar "colLits") (EVar "rest"))))
(DFunDef false "colLits" ((PCons PWild (PVar "rest"))) (EApp (EVar "colLits") (EVar "rest")))
(DTypeSig false "dedupLits" (TyFun (TyApp (TyCon "List") (TyCon "Lit")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "List") (TyCon "Lit")))))
(DFunDef false "dedupLits" ((PList) PWild) (EListLit))
(DFunDef false "dedupLits" ((PCons (PVar "l") (PVar "rest")) (PVar "seen")) (EBlock (DoLet false false (PVar "k") (EApp (EVar "litKey") (EVar "l"))) (DoExpr (EMatch (EApp (EApp (EVar "omHasKey") (EVar "k")) (EVar "seen")) (arm (PCon "True") () (EApp (EApp (EVar "dedupLits") (EVar "rest")) (EVar "seen"))) (arm (PCon "False") () (EBinOp "::" (EVar "l") (EApp (EApp (EVar "dedupLits") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "k")) (ELit LUnit)) (EVar "seen")))))))))
(DTypeSig false "litKey" (TyFun (TyCon "Lit") (TyCon "String")))
(DFunDef false "litKey" ((PCon "LInt" (PVar "n"))) (EBinOp "++" (ELit (LString "i")) (EApp (EVar "intToString") (EVar "n"))))
(DFunDef false "litKey" ((PCon "LChar" (PVar "c"))) (EBinOp "++" (ELit (LString "c")) (EVar "c")))
(DFunDef false "litKey" ((PCon "LString" (PVar "s"))) (EBinOp "++" (ELit (LString "s")) (EVar "s")))
(DFunDef false "litKey" ((PCon "LFloat" (PVar "f"))) (EBinOp "++" (ELit (LString "f")) (EApp (EVar "floatToString") (EApp (EVar "normLitZero") (EVar "f")))))
(DFunDef false "litKey" ((PCon "LBool" (PCon "True"))) (ELit (LString "bT")))
(DFunDef false "litKey" ((PCon "LBool" (PCon "False"))) (ELit (LString "bF")))
(DFunDef false "litKey" ((PCon "LUnit")) (ELit (LString "u")))
(DFunDef false "litKey" ((PCon "LU64" (PVar "hi") (PVar "lo"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "w")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "hi")))) (ELit (LString "."))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "lo")))) (ELit (LString ""))))
(DFunDef false "litKey" ((PCon "LI64" (PVar "hi") (PVar "lo"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "i")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "hi")))) (ELit (LString "."))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "lo")))) (ELit (LString ""))))
(DTypeSig false "normLitZero" (TyFun (TyCon "Float") (TyCon "Float")))
(DFunDef false "normLitZero" ((PVar "f")) (EIf (EBinOp "==" (EVar "f") (ELit (LFloat 0.0))) (ELit (LFloat 0.0)) (EVar "f")))
(DTypeSig false "filterMapRows" (TyFun (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int")) (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))) (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))))))
(DFunDef false "filterMapRows" (PWild (PList)) (EListLit))
(DFunDef false "filterMapRows" ((PVar "f") (PCons (PVar "r") (PVar "rest"))) (EMatch (EApp (EVar "f") (EVar "r")) (arm (PCon "Some" (PVar "r2")) () (EBinOp "::" (EVar "r2") (EApp (EApp (EVar "filterMapRows") (EVar "f")) (EVar "rest")))) (arm (PCon "None") () (EApp (EApp (EVar "filterMapRows") (EVar "f")) (EVar "rest")))))
(DTypeSig false "bucketRows" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int")))))))
(DFunDef false "bucketRows" ((PVar "k") (PVar "m")) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "k")) (EVar "m"))))
(DTypeSig false "pushBucket" (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "Int") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int")))))))))
(DFunDef false "pushBucket" ((PVar "k") (PVar "r") (PVar "m")) (EApp (EApp (EApp (EVar "omInsert") (EVar "k")) (EBinOp "::" (EVar "r") (EApp (EApp (EVar "bucketRows") (EVar "k")) (EVar "m")))) (EVar "m")))
(DTypeSig false "conBuckets" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int")))))))))
(DFunDef false "conBuckets" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "conBuckets" ((PVar "k") (PCons (PTuple (PCons (PCon "PCon" (PVar "c") (PVar "args")) (PVar "rest")) (PVar "i")) (PVar "more")) (PVar "acc")) (EApp (EApp (EApp (EVar "conBuckets") (EBinOp "+" (EVar "k") (ELit (LInt 1)))) (EVar "more")) (EApp (EApp (EApp (EVar "pushBucket") (EVar "c")) (ETuple (EVar "k") (ETuple (EBinOp "++" (EVar "args") (EVar "rest")) (EVar "i")))) (EVar "acc"))))
(DFunDef false "conBuckets" ((PVar "k") (PCons PWild (PVar "more")) (PVar "acc")) (EApp (EApp (EApp (EVar "conBuckets") (EBinOp "+" (EVar "k") (ELit (LInt 1)))) (EVar "more")) (EVar "acc")))
(DTypeSig false "litBuckets" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int")))))))))
(DFunDef false "litBuckets" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "litBuckets" ((PVar "k") (PCons (PTuple (PCons (PCon "PLit" (PVar "l")) (PVar "rest")) (PVar "i")) (PVar "more")) (PVar "acc")) (EApp (EApp (EApp (EVar "litBuckets") (EBinOp "+" (EVar "k") (ELit (LInt 1)))) (EVar "more")) (EApp (EApp (EApp (EVar "pushBucket") (EApp (EVar "litKey") (EVar "l"))) (ETuple (EVar "k") (ETuple (EVar "rest") (EVar "i")))) (EVar "acc"))))
(DFunDef false "litBuckets" ((PVar "k") (PCons PWild (PVar "more")) (PVar "acc")) (EApp (EApp (EApp (EVar "litBuckets") (EBinOp "+" (EVar "k") (ELit (LInt 1)))) (EVar "more")) (EVar "acc")))
(DTypeSig false "wildTailRows" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int")))))))
(DFunDef false "wildTailRows" (PWild (PList)) (EListLit))
(DFunDef false "wildTailRows" ((PVar "k") (PCons (PTuple (PCons (PCon "PWild") (PVar "rest")) (PVar "i")) (PVar "more"))) (EBinOp "::" (ETuple (EVar "k") (ETuple (EVar "rest") (EVar "i"))) (EApp (EApp (EVar "wildTailRows") (EBinOp "+" (EVar "k") (ELit (LInt 1)))) (EVar "more"))))
(DFunDef false "wildTailRows" ((PVar "k") (PCons PWild (PVar "more"))) (EApp (EApp (EVar "wildTailRows") (EBinOp "+" (EVar "k") (ELit (LInt 1)))) (EVar "more")))
(DTypeSig false "padWildRow" (TyFun (TyCon "Int") (TyFun (TyTuple (TyCon "Int") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))) (TyTuple (TyCon "Int") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))))))
(DFunDef false "padWildRow" ((PVar "arity") (PTuple (PVar "k") (PTuple (PVar "ps") (PVar "i")))) (ETuple (EVar "k") (ETuple (EBinOp "++" (EApp (EApp (EVar "replicate") (EVar "arity")) (EVar "PWild")) (EVar "ps")) (EVar "i"))))
(DTypeSig false "mergeByOrd" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int")))) (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))))))
(DFunDef false "mergeByOrd" ((PList) (PVar "ys")) (EApp (EApp (EVar "map") (EVar "untagRow")) (EVar "ys")))
(DFunDef false "mergeByOrd" ((PVar "xs") (PList)) (EApp (EApp (EVar "map") (EVar "untagRow")) (EVar "xs")))
(DFunDef false "mergeByOrd" ((PCons (PTuple (PVar "ka") (PVar "ra")) (PVar "xs")) (PCons (PTuple (PVar "kb") (PVar "rb")) (PVar "ys"))) (EIf (EBinOp "<" (EVar "ka") (EVar "kb")) (EBinOp "::" (EVar "ra") (EApp (EApp (EVar "mergeByOrd") (EVar "xs")) (EBinOp "::" (ETuple (EVar "kb") (EVar "rb")) (EVar "ys")))) (EBinOp "::" (EVar "rb") (EApp (EApp (EVar "mergeByOrd") (EBinOp "::" (ETuple (EVar "ka") (EVar "ra")) (EVar "xs"))) (EVar "ys")))))
(DTypeSig false "untagRow" (TyFun (TyTuple (TyCon "Int") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))) (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))))
(DFunDef false "untagRow" ((PTuple PWild (PVar "r"))) (EVar "r"))
(DTypeSig false "defaultMatrix" (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))) (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int")))))
(DFunDef false "defaultMatrix" ((PVar "rows")) (EApp (EApp (EVar "filterMapRows") (EVar "defRow")) (EVar "rows")))
(DTypeSig false "defRow" (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int")) (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int")))))
(DFunDef false "defRow" ((PTuple (PCons (PCon "PWild") (PVar "rest")) (PVar "i"))) (EApp (EVar "Some") (ETuple (EVar "rest") (EVar "i"))))
(DFunDef false "defRow" (PWild) (EVar "None"))
(DTypeSig false "lowerField" (TyFun (TyCon "FieldAssign") (TyCon "CField")))
(DFunDef false "lowerField" ((PCon "FieldAssign" (PVar "k") (PVar "e"))) (EApp (EApp (EVar "CField") (EVar "k")) (EApp (EVar "lower") (EVar "e"))))
(DTypeSig false "lowerBind" (TyFun (TyCon "LetBind") (TyCon "CBind")))
(DFunDef false "lowerBind" ((PCon "LetBind" (PVar "name") (PVar "clauses") (PVar "site"))) (EApp (EApp (EApp (EVar "CBind") (EVar "name")) (EApp (EApp (EVar "map") (EVar "lowerClause")) (EVar "clauses"))) (EVar "site")))
(DTypeSig false "lowerClause" (TyFun (TyCon "FunClause") (TyCon "CClause")))
(DFunDef false "lowerClause" ((PCon "FunClause" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "CClause") (EVar "pats")) (EApp (EVar "lower") (EVar "body"))))
(DTypeSig false "lowerStmt" (TyFun (TyCon "DoStmt") (TyCon "CStmt")))
(DFunDef false "lowerStmt" ((PCon "DoExpr" (PVar "e"))) (EApp (EVar "CSExpr") (EApp (EVar "lower") (EVar "e"))))
(DFunDef false "lowerStmt" ((PCon "DoLet" PWild (PVar "recFlag") (PVar "pat") (PVar "e") PWild)) (EApp (EApp (EApp (EVar "CSLet") (EVar "recFlag")) (EVar "pat")) (EApp (EVar "lower") (EVar "e"))))
(DFunDef false "lowerStmt" ((PCon "DoAssign" (PVar "x") (PVar "e"))) (EApp (EApp (EVar "CSAssign") (EVar "x")) (EApp (EVar "lower") (EVar "e"))))
(DFunDef false "lowerStmt" (PWild) (EApp (EVar "panic") (ELit (LString "core_ir lower: unsupported block statement"))))
(DTypeSig true "lowerProgram" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "CProgram")))
(DFunDef false "lowerProgram" ((PVar "prog")) (EApp (EApp (EVar "refoldProgram") (EVar "noLetCheck")) (EApp (EApp (EVar "lowerProgramWith") (EVar "None")) (EVar "prog"))))
(DTypeSig true "lowerTypedProgram" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "CProgram")))
(DFunDef false "lowerTypedProgram" ((PVar "prog")) (EApp (EApp (EVar "refoldProgram") (EVar "noLetCheck")) (EApp (EApp (EVar "lowerProgramWith") (EApp (EVar "Some") (EApp (EVar "installedDispositions") (ELit LUnit)))) (EVar "prog"))))
(DTypeSig false "lowerProgramWith" (TyFun (TyApp (TyCon "Option") (TyCon "DispositionTable")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "CProgram"))))
(DFunDef false "lowerProgramWith" ((PVar "dispositions") (PVar "prog")) (EApp (EApp (EApp (EApp (EVar "CProgram") (EApp (EVar "lowerGroupsRaw") (EVar "prog"))) (EApp (EVar "ctorArities") (EVar "prog"))) (EApp (EVar "buildCtorToType") (EVar "prog"))) (EApp (EApp (EApp (EApp (EVar "lowerImplsRaw") (EApp (EVar "installDispatchTables") (EVar "prog"))) (EApp (EVar "instanceReqCounts") (EVar "prog"))) (EVar "dispositions")) (EVar "prog"))))
(DTypeSig false "noLetCheck" (TyFun (TyCon "Pat") (TyCon "Bool")))
(DFunDef false "noLetCheck" (PWild) (EVar "False"))
(DTypeSig false "patCanMiss" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Bool")) (TyFun (TyCon "Pat") (TyCon "Bool"))))
(DFunDef false "patCanMiss" (PWild (PCon "PWild")) (EVar "False"))
(DFunDef false "patCanMiss" (PWild (PCon "PVar" PWild PWild)) (EVar "False"))
(DFunDef false "patCanMiss" (PWild (PCon "PLit" (PCon "LUnit"))) (EVar "False"))
(DFunDef false "patCanMiss" (PWild (PCon "PLit" PWild)) (EVar "True"))
(DFunDef false "patCanMiss" ((PVar "sib") (PCon "PAs" PWild PWild (PVar "p"))) (EApp (EApp (EVar "patCanMiss") (EVar "sib")) (EVar "p")))
(DFunDef false "patCanMiss" ((PVar "sib") (PCon "PTuple" (PVar "ps"))) (EApp (EApp (EVar "anyList") (EApp (EVar "patCanMiss") (EVar "sib"))) (EVar "ps")))
(DFunDef false "patCanMiss" ((PVar "sib") (PCon "PCon" (PVar "c") (PVar "ps"))) (EBinOp "||" (EApp (EApp (EVar "ctorHasSibling") (EVar "sib")) (EVar "c")) (EApp (EApp (EVar "anyList") (EApp (EVar "patCanMiss") (EVar "sib"))) (EVar "ps"))))
(DFunDef false "patCanMiss" (PWild (PCon "PRec" PWild PWild PWild)) (EVar "False"))
(DFunDef false "patCanMiss" (PWild PWild) (EVar "True"))
(DTypeSig false "ctorHasSibling" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Bool")) (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "ctorHasSibling" ((PVar "sib") (PVar "c")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "c")) (EVar "sib")) (arm (PCon "Some" (PVar "b")) () (EVar "b")) (arm (PCon "None") () (EVar "True"))))
(DTypeSig false "siblingTable" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "OrdMap") (TyCon "Bool"))))
(DFunDef false "siblingTable" ((PVar "t")) (EBlock (DoLet false false (PVar "counts") (EApp (EApp (EVar "typeCtorCounts") (EVar "t")) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EApp (EVar "siblingRows") (EVar "counts")) (EVar "t")) (EVar "omEmpty")))))
(DTypeSig false "typeCtorCounts" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyApp (TyCon "OrdMap") (TyCon "Int")))))
(DFunDef false "typeCtorCounts" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "typeCtorCounts" ((PCons (PTuple PWild (PVar "ty")) (PVar "rest")) (PVar "acc")) (EBlock (DoLet false false (PVar "n") (EMatch (EApp (EApp (EVar "omLookup") (EVar "ty")) (EVar "acc")) (arm (PCon "Some" (PVar "k")) () (EBinOp "+" (EVar "k") (ELit (LInt 1)))) (arm (PCon "None") () (ELit (LInt 1))))) (DoExpr (EApp (EApp (EVar "typeCtorCounts") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "ty")) (EVar "n")) (EVar "acc"))))))
(DTypeSig false "siblingRows" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Bool")) (TyApp (TyCon "OrdMap") (TyCon "Bool"))))))
(DFunDef false "siblingRows" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "siblingRows" ((PVar "counts") (PCons (PTuple (PVar "c") (PVar "ty")) (PVar "rest")) (PVar "acc")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "c")) (EVar "acc")) (EApp (EApp (EApp (EVar "siblingRows") (EVar "counts")) (EVar "rest")) (EVar "acc")) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "many") (EMatch (EApp (EApp (EVar "omLookup") (EVar "ty")) (EVar "counts")) (arm (PCon "Some" (PVar "k")) () (EBinOp ">" (EVar "k") (ELit (LInt 1)))) (arm (PCon "None") () (EVar "True")))) (DoExpr (EApp (EApp (EApp (EVar "siblingRows") (EVar "counts")) (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "c")) (EVar "many")) (EVar "acc"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "letDecisionSite" (TyFun (TyCon "CTree") (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "letDecisionSite" ((PVar "t")) (EMatch (EApp (EVar "treeFailSiteOpt") (EVar "t")) (arm (PCon "Some" (PCon "LetRefuted" (PVar "l"))) () (EApp (EVar "Some") (EVar "l"))) (arm PWild () (EVar "None"))))
(DTypeSig false "refoldProgram" (TyFun (TyFun (TyCon "Pat") (TyCon "Bool")) (TyFun (TyCon "CProgram") (TyCon "CProgram"))))
(DFunDef false "refoldProgram" ((PVar "keep") (PCon "CProgram" (PVar "groups") (PVar "ctorArs") (PVar "ctorTypes") (PVar "implEntries"))) (EApp (EApp (EApp (EApp (EVar "CProgram") (EApp (EApp (EVar "map") (EApp (EVar "refoldBind") (EVar "keep"))) (EVar "groups"))) (EVar "ctorArs")) (EVar "ctorTypes")) (EApp (EApp (EVar "map") (EApp (EVar "refoldImpl") (EVar "keep"))) (EVar "implEntries"))))
(DTypeSig false "refoldBind" (TyFun (TyFun (TyCon "Pat") (TyCon "Bool")) (TyFun (TyCon "CBind") (TyCon "CBind"))))
(DFunDef false "refoldBind" ((PVar "keep") (PCon "CBind" (PVar "n") (PVar "clauses") (PVar "site"))) (EApp (EApp (EApp (EVar "CBind") (EVar "n")) (EApp (EApp (EVar "map") (EApp (EVar "refoldClause") (EVar "keep"))) (EVar "clauses"))) (EVar "site")))
(DTypeSig false "refoldClause" (TyFun (TyFun (TyCon "Pat") (TyCon "Bool")) (TyFun (TyCon "CClause") (TyCon "CClause"))))
(DFunDef false "refoldClause" ((PVar "keep") (PCon "CClause" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "CClause") (EVar "pats")) (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "body"))))
(DTypeSig false "refoldImpl" (TyFun (TyFun (TyCon "Pat") (TyCon "Bool")) (TyFun (TyCon "CImplEntry") (TyCon "CImplEntry"))))
(DFunDef false "refoldImpl" ((PVar "keep") (PCon "CImplEntry" (PVar "n") (PVar "s") (PCon "CImplTagged" (PVar "tag") (PVar "key") (PVar "iface") (PVar "ps") (PVar "pats") (PVar "body")))) (EApp (EApp (EApp (EVar "CImplEntry") (EVar "n")) (EVar "s")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "CImplTagged") (EVar "tag")) (EVar "key")) (EVar "iface")) (EVar "ps")) (EVar "pats")) (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "body")))))
(DFunDef false "refoldImpl" ((PVar "keep") (PCon "CImplEntry" (PVar "n") (PVar "s") (PCon "CImplDefault" (PVar "ifaceId") (PVar "tag") (PVar "key") (PVar "ps") (PVar "pats") (PVar "body")))) (EApp (EApp (EApp (EVar "CImplEntry") (EVar "n")) (EVar "s")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "CImplDefault") (EVar "ifaceId")) (EVar "tag")) (EVar "key")) (EVar "ps")) (EVar "pats")) (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "body")))))
(DTypeSig false "refoldExpr" (TyFun (TyFun (TyCon "Pat") (TyCon "Bool")) (TyFun (TyCon "CExpr") (TyCon "CExpr"))))
(DFunDef false "refoldExpr" ((PVar "keep") (PCon "CDecision" (PVar "scrut") (PList (PCon "CArm" (PVar "pat") (PList) (PVar "body"))) (PVar "tree"))) (EIf (EBinOp "&&" (EApp (EVar "isSomeLoc") (EApp (EVar "letDecisionSite") (EVar "tree"))) (EApp (EVar "not") (EApp (EVar "keep") (EVar "pat")))) (EApp (EApp (EApp (EApp (EVar "CLet") (EVar "False")) (EVar "pat")) (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "scrut"))) (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "body"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "refoldExpr" ((PVar "keep") (PCon "CDecision" (PVar "scrut") (PVar "arms") (PVar "tree"))) (EApp (EApp (EApp (EVar "CDecision") (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "scrut"))) (EApp (EApp (EVar "map") (EApp (EVar "refoldArm") (EVar "keep"))) (EVar "arms"))) (EVar "tree")))
(DFunDef false "refoldExpr" (PWild (PCon "CLit" (PVar "l"))) (EApp (EVar "CLit") (EVar "l")))
(DFunDef false "refoldExpr" (PWild (PCon "CVar" (PVar "x") (PVar "addr"))) (EApp (EApp (EVar "CVar") (EVar "x")) (EVar "addr")))
(DFunDef false "refoldExpr" ((PVar "keep") (PCon "CApp" (PVar "f") (PVar "x"))) (EApp (EApp (EVar "CApp") (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "f"))) (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "x"))))
(DFunDef false "refoldExpr" ((PVar "keep") (PCon "CLam" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "CLam") (EVar "pats")) (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "body"))))
(DFunDef false "refoldExpr" ((PVar "keep") (PCon "CLet" (PVar "r") (PVar "pat") (PVar "e1") (PVar "e2"))) (EApp (EApp (EApp (EApp (EVar "CLet") (EVar "r")) (EVar "pat")) (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "e1"))) (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "e2"))))
(DFunDef false "refoldExpr" ((PVar "keep") (PCon "CLetGroup" (PVar "binds") (PVar "body"))) (EApp (EApp (EVar "CLetGroup") (EApp (EApp (EVar "map") (EApp (EVar "refoldBind") (EVar "keep"))) (EVar "binds"))) (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "body"))))
(DFunDef false "refoldExpr" ((PVar "keep") (PCon "CMatch" (PVar "scrut") (PVar "arms"))) (EApp (EApp (EVar "CMatch") (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "scrut"))) (EApp (EApp (EVar "map") (EApp (EVar "refoldArm") (EVar "keep"))) (EVar "arms"))))
(DFunDef false "refoldExpr" ((PVar "keep") (PCon "CIf" (PVar "c") (PVar "t") (PVar "e"))) (EApp (EApp (EApp (EVar "CIf") (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "c"))) (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "t"))) (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "e"))))
(DFunDef false "refoldExpr" ((PVar "keep") (PCon "CBinPrim" (PVar "op") (PVar "l") (PVar "r") (PVar "tag") (PVar "site"))) (EApp (EApp (EApp (EApp (EApp (EVar "CBinPrim") (EVar "op")) (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "l"))) (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "r"))) (EVar "tag")) (EVar "site")))
(DFunDef false "refoldExpr" ((PVar "keep") (PCon "CUnOp" (PVar "op") (PVar "x"))) (EApp (EApp (EVar "CUnOp") (EVar "op")) (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "x"))))
(DFunDef false "refoldExpr" ((PVar "keep") (PCon "CTuple" (PVar "es"))) (EApp (EVar "CTuple") (EApp (EApp (EVar "map") (EApp (EVar "refoldExpr") (EVar "keep"))) (EVar "es"))))
(DFunDef false "refoldExpr" ((PVar "keep") (PCon "CList" (PVar "es"))) (EApp (EVar "CList") (EApp (EApp (EVar "map") (EApp (EVar "refoldExpr") (EVar "keep"))) (EVar "es"))))
(DFunDef false "refoldExpr" ((PVar "keep") (PCon "CRecord" (PVar "name") (PVar "fields"))) (EApp (EApp (EVar "CRecord") (EVar "name")) (EApp (EApp (EVar "map") (EApp (EVar "refoldField") (EVar "keep"))) (EVar "fields"))))
(DFunDef false "refoldExpr" ((PVar "keep") (PCon "CFieldAccess" (PVar "ex") (PVar "f") (PVar "n"))) (EApp (EApp (EApp (EVar "CFieldAccess") (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "ex"))) (EVar "f")) (EVar "n")))
(DFunDef false "refoldExpr" ((PVar "keep") (PCon "CRecordUpdate" (PVar "name") (PVar "base") (PVar "fields"))) (EApp (EApp (EApp (EVar "CRecordUpdate") (EVar "name")) (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "base"))) (EApp (EApp (EVar "map") (EApp (EVar "refoldField") (EVar "keep"))) (EVar "fields"))))
(DFunDef false "refoldExpr" ((PVar "keep") (PCon "CVariantUpdate" (PVar "con") (PVar "base") (PVar "fields"))) (EApp (EApp (EApp (EVar "CVariantUpdate") (EVar "con")) (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "base"))) (EApp (EApp (EVar "map") (EApp (EVar "refoldField") (EVar "keep"))) (EVar "fields"))))
(DFunDef false "refoldExpr" ((PVar "keep") (PCon "CArray" (PVar "es"))) (EApp (EVar "CArray") (EApp (EApp (EVar "map") (EApp (EVar "refoldExpr") (EVar "keep"))) (EVar "es"))))
(DFunDef false "refoldExpr" ((PVar "keep") (PCon "CRangeList" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EVar "CRangeList") (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "lo"))) (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "refoldExpr" ((PVar "keep") (PCon "CRangeArray" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EVar "CRangeArray") (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "lo"))) (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "refoldExpr" ((PVar "keep") (PCon "CIndex" (PVar "a") (PVar "i"))) (EApp (EApp (EVar "CIndex") (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "a"))) (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "i"))))
(DFunDef false "refoldExpr" ((PVar "keep") (PCon "CSlice" (PVar "a") (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EApp (EVar "CSlice") (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "a"))) (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "lo"))) (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "refoldExpr" ((PVar "keep") (PCon "CStringIndex" (PVar "a") (PVar "i"))) (EApp (EApp (EVar "CStringIndex") (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "a"))) (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "i"))))
(DFunDef false "refoldExpr" ((PVar "keep") (PCon "CStringSlice" (PVar "a") (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EApp (EVar "CStringSlice") (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "a"))) (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "lo"))) (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "refoldExpr" ((PVar "keep") (PCon "CListIndex" (PVar "a") (PVar "i"))) (EApp (EApp (EVar "CListIndex") (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "a"))) (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "i"))))
(DFunDef false "refoldExpr" ((PVar "keep") (PCon "CListSlice" (PVar "a") (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EApp (EVar "CListSlice") (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "a"))) (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "lo"))) (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "refoldExpr" ((PVar "keep") (PCon "CBlock" (PVar "stmts"))) (EApp (EVar "CBlock") (EApp (EApp (EVar "refoldStmts") (EVar "keep")) (EVar "stmts"))))
(DFunDef false "refoldExpr" (PWild (PCon "CMethod" (PVar "name") (PVar "iface") (PVar "arity") (PVar "r") (PVar "ir") (PVar "mr"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "CMethod") (EVar "name")) (EVar "iface")) (EVar "arity")) (EVar "r")) (EVar "ir")) (EVar "mr")))
(DFunDef false "refoldExpr" (PWild (PCon "CDict" (PVar "name") (PVar "rs"))) (EApp (EApp (EVar "CDict") (EVar "name")) (EVar "rs")))
(DTypeSig false "refoldStmts" (TyFun (TyFun (TyCon "Pat") (TyCon "Bool")) (TyFun (TyApp (TyCon "List") (TyCon "CStmt")) (TyApp (TyCon "List") (TyCon "CStmt")))))
(DFunDef false "refoldStmts" (PWild (PList)) (EListLit))
(DFunDef false "refoldStmts" ((PVar "keep") (PList (PCon "CSExpr" (PCon "CDecision" (PVar "scrut") (PList (PCon "CArm" (PVar "pat") (PList) (PCon "CBlock" (PVar "rest")))) (PVar "tree"))))) (EIf (EApp (EVar "isSomeLoc") (EApp (EVar "letDecisionSite") (EVar "tree"))) (EBlock (DoLet false false (PVar "scrut2") (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "scrut"))) (DoExpr (EIf (EApp (EVar "keep") (EVar "pat")) (EBlock (DoLet false false (PVar "body") (EIf (EApp (EVar "isEmptyL") (EVar "rest")) (EApp (EVar "CLit") (EVar "LUnit")) (EApp (EVar "CBlock") (EApp (EApp (EVar "refoldStmts") (EVar "keep")) (EVar "rest"))))) (DoExpr (EListLit (EApp (EVar "CSExpr") (EApp (EApp (EApp (EVar "CDecision") (EVar "scrut2")) (EListLit (EApp (EApp (EApp (EVar "CArm") (EVar "pat")) (EListLit)) (EVar "body")))) (EVar "tree")))))) (EBinOp "::" (EApp (EApp (EApp (EVar "CSLet") (EVar "False")) (EVar "pat")) (EVar "scrut2")) (EApp (EApp (EVar "refoldStmts") (EVar "keep")) (EVar "rest")))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "refoldStmts" ((PVar "keep") (PCons (PVar "s") (PVar "rest"))) (EBinOp "::" (EApp (EApp (EVar "refoldStmt") (EVar "keep")) (EVar "s")) (EApp (EApp (EVar "refoldStmts") (EVar "keep")) (EVar "rest"))))
(DTypeSig false "refoldStmt" (TyFun (TyFun (TyCon "Pat") (TyCon "Bool")) (TyFun (TyCon "CStmt") (TyCon "CStmt"))))
(DFunDef false "refoldStmt" ((PVar "keep") (PCon "CSExpr" (PVar "e"))) (EApp (EVar "CSExpr") (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "e"))))
(DFunDef false "refoldStmt" ((PVar "keep") (PCon "CSLet" (PVar "r") (PVar "pat") (PVar "e"))) (EApp (EApp (EApp (EVar "CSLet") (EVar "r")) (EVar "pat")) (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "e"))))
(DFunDef false "refoldStmt" ((PVar "keep") (PCon "CSAssign" (PVar "x") (PVar "e"))) (EApp (EApp (EVar "CSAssign") (EVar "x")) (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "e"))))
(DTypeSig false "refoldArm" (TyFun (TyFun (TyCon "Pat") (TyCon "Bool")) (TyFun (TyCon "CArm") (TyCon "CArm"))))
(DFunDef false "refoldArm" ((PVar "keep") (PCon "CArm" (PVar "pat") (PVar "guards") (PVar "body"))) (EApp (EApp (EApp (EVar "CArm") (EVar "pat")) (EApp (EApp (EVar "map") (EApp (EVar "refoldGuard") (EVar "keep"))) (EVar "guards"))) (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "body"))))
(DTypeSig false "refoldGuard" (TyFun (TyFun (TyCon "Pat") (TyCon "Bool")) (TyFun (TyCon "CGuard") (TyCon "CGuard"))))
(DFunDef false "refoldGuard" ((PVar "keep") (PCon "CGBool" (PVar "e"))) (EApp (EVar "CGBool") (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "e"))))
(DFunDef false "refoldGuard" ((PVar "keep") (PCon "CGBind" (PVar "p") (PVar "e"))) (EApp (EApp (EVar "CGBind") (EVar "p")) (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "e"))))
(DTypeSig false "refoldField" (TyFun (TyFun (TyCon "Pat") (TyCon "Bool")) (TyFun (TyCon "CField") (TyCon "CField"))))
(DFunDef false "refoldField" ((PVar "keep") (PCon "CField" (PVar "k") (PVar "e"))) (EApp (EApp (EVar "CField") (EVar "k")) (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "e"))))
(DTypeSig false "isSomeLoc" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Bool")))
(DFunDef false "isSomeLoc" ((PCon "Some" PWild)) (EVar "True"))
(DFunDef false "isSomeLoc" ((PCon "None")) (EVar "False"))
(DData Public "EmitTarget" () ((variant "TargetNative" (ConPos)) (variant "TargetWasm" (ConPos)) (variant "TargetBothUnknown" (ConPos))) ())
(DTypeSig true "lowerProgramEmit" (TyFun (TyCon "EmitTarget") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "CProgram"))))
(DFunDef false "lowerProgramEmit" ((PVar "target") (PVar "prog")) (EBlock (DoLet false false PWild (EApp (EVar "implSymbolCollisionGuard") (EVar "prog"))) (DoLet false false PWild (EApp (EApp (EVar "dictWitnessTagGuard") (EVar "target")) (EVar "prog"))) (DoLet false false (PVar "sited") (EMatch (EVar "target") (arm (PCon "TargetBothUnknown") () (EVar "prog")) (arm PWild () (EApp (EVar "siteTrapCalls") (EVar "prog"))))) (DoLet false false (PVar "raw") (EApp (EApp (EVar "lowerProgramWith") (EApp (EVar "installedDispositionsOpt") (ELit LUnit))) (EVar "sited"))) (DoLet false false (PVar "fo") (EApp (EVar "declaredRecordFieldOrders") (EVar "prog"))) (DoExpr (EApp (EVar "hoistNullaryMemo") (EMatch (EVar "target") (arm (PCon "TargetBothUnknown") () (EApp (EApp (EVar "rewriteProgramRecPats") (EVar "fo")) (EApp (EApp (EVar "refoldProgram") (EVar "noLetCheck")) (EVar "raw")))) (arm PWild () (EBlock (DoLet false false (PVar "rewritten") (EApp (EApp (EVar "rewriteProgramRecPats") (EVar "fo")) (EVar "raw"))) (DoExpr (EApp (EApp (EVar "refoldProgram") (EApp (EVar "patCanMiss") (EApp (EVar "siblingTable") (EApp (EVar "cprogramCtorTypes") (EVar "raw"))))) (EVar "rewritten"))))))))))
(DTypeSig false "cprogramCtorTypes" (TyFun (TyCon "CProgram") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "cprogramCtorTypes" ((PCon "CProgram" PWild PWild (PVar "ctorTypes") PWild)) (EVar "ctorTypes"))
(DTypeSig false "siteTrapCalls" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "siteTrapCalls" ((PVar "prog")) (EBlock (DoLet false false (PVar "twins") (EApp (EVar "indexTwins") (EApp (EApp (EVar "topFunNames") (EVar "prog")) (EVar "omEmpty")))) (DoExpr (EApp (EApp (EVar "map") (EApp (EVar "siteTrapDecl") (EVar "twins"))) (EVar "prog")))))
(DTypeSig false "siteTrapDecl" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "Decl") (TyCon "Decl"))))
(DFunDef false "siteTrapDecl" ((PVar "twins") (PVar "d")) (EBlock (DoLet false false (PVar "panicFree") (EApp (EVar "not") (EApp (EApp (EVar "contains") (ELit (LString "panic"))) (EApp (EVar "declBinders") (EVar "d"))))) (DoExpr (EMatch (EApp (EApp (EVar "mapProg") (EApp (EApp (EVar "siteTrapExpr") (EVar "panicFree")) (EVar "twins"))) (EListLit (EVar "d"))) (arm (PList (PVar "d2")) () (EVar "d2")) (arm PWild () (EVar "d"))))))
(DTypeSig false "siteTrapExpr" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "siteTrapExpr" ((PVar "panicFree") (PVar "twins") (PAs "e" (PCon "EApp" (PVar "h") (PVar "m")))) (EIf (EBinOp "&&" (EVar "panicFree") (EApp (EVar "isPanicHead") (EVar "h"))) (EApp (EApp (EApp (EApp (EVar "sitedCall") (EApp (EVar "exprStartLoc") (EVar "e"))) (EApp (EVar "EVar") (ELit (LString "panicAt")))) (EListLit (EVar "m"))) (EVar "e")) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "siteTrapExpr" (PWild (PVar "twins") (PAs "e" (PCon "EApp" (PCon "EApp" (PVar "h") (PVar "a")) (PVar "i")))) (EMatch (EApp (EApp (EVar "indexTwinOf") (EVar "twins")) (EVar "h")) (arm (PCon "Some" (PVar "twin")) () (EApp (EApp (EApp (EApp (EVar "sitedCall") (EApp (EVar "exprStartLoc") (EVar "e"))) (EApp (EVar "EVar") (EVar "twin"))) (EListLit (EVar "a") (EVar "i"))) (EVar "e"))) (arm (PCon "None") () (EVar "e"))))
(DFunDef false "siteTrapExpr" (PWild PWild (PVar "e")) (EVar "e"))
(DTypeSig false "sitedCall" (TyFun (TyCon "Loc") (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyFun (TyCon "Expr") (TyCon "Expr"))))))
(DFunDef false "sitedCall" ((PCon "Loc" (PLit (LString "")) PWild PWild PWild PWild) PWild PWild (PVar "orig")) (EVar "orig"))
(DFunDef false "sitedCall" ((PCon "Loc" PWild (PLit (LInt 1)) (PLit (LInt 0)) (PLit (LInt 1)) (PLit (LInt 0))) PWild PWild (PVar "orig")) (EVar "orig"))
(DFunDef false "sitedCall" ((PCon "Loc" (PVar "f") (PVar "sl") (PVar "sc") PWild PWild) (PVar "fn") (PVar "args") PWild) (EApp (EApp (EVar "applyAll") (EApp (EApp (EVar "EApp") (EVar "fn")) (EApp (EApp (EApp (EVar "siteLiteral") (EVar "f")) (EVar "sl")) (EVar "sc")))) (EVar "args")))
(DTypeSig false "applyAll" (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyCon "Expr"))))
(DFunDef false "applyAll" ((PVar "f") (PList)) (EVar "f"))
(DFunDef false "applyAll" ((PVar "f") (PCons (PVar "x") (PVar "rest"))) (EApp (EApp (EVar "applyAll") (EApp (EApp (EVar "EApp") (EVar "f")) (EVar "x"))) (EVar "rest")))
(DTypeSig false "siteLiteral" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Expr")))))
(DFunDef false "siteLiteral" ((PVar "f") (PVar "line") (PVar "col")) (EApp (EApp (EVar "EApp") (EApp (EApp (EVar "EApp") (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (EVar "siteSentinelName"))) (EApp (EVar "ELit") (EApp (EVar "LString") (EVar "f"))))) (EApp (EVar "ELit") (EApp (EVar "LInt") (EVar "line"))))) (EApp (EVar "ELit") (EApp (EVar "LInt") (EVar "col")))))
(DTypeSig false "isPanicHead" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isPanicHead" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "isPanicHead") (EVar "e")))
(DFunDef false "isPanicHead" ((PCon "EVar" (PLit (LString "panic")))) (EVar "True"))
(DFunDef false "isPanicHead" ((PCon "EVarId" (PLit (LString "panic")) PWild)) (EVar "True"))
(DFunDef false "isPanicHead" ((PCon "EVarAt" (PLit (LString "panic")) (PCon "AGlobal"))) (EVar "True"))
(DFunDef false "isPanicHead" (PWild) (EVar "False"))
(DTypeSig false "indexTwins" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "String"))))
(DFunDef false "indexTwins" ((PVar "names")) (EApp (EApp (EApp (EVar "indexTwinsGo") (EVar "names")) (EListLit (ETuple (ELit (LString "core::Index|(Array a) Int a|")) (ELit (LString "arrayIndexAt"))) (ETuple (ELit (LString "core::Index|(List a) Int a|")) (ELit (LString "listIndexAt"))) (ETuple (ELit (LString "core::Index|String Int Char|")) (ELit (LString "stringIndexAt"))))) (EVar "omEmpty")))
(DTypeSig false "indexTwinsGo" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyApp (TyCon "OrdMap") (TyCon "String"))))))
(DFunDef false "indexTwinsGo" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "indexTwinsGo" ((PVar "names") (PCons (PTuple (PVar "key") (PVar "twin")) (PVar "rest")) (PVar "acc")) (EMatch (EApp (EApp (EVar "preludeFunName") (EVar "names")) (EVar "twin")) (arm (PCon "Some" (PVar "n")) () (EApp (EApp (EApp (EVar "indexTwinsGo") (EVar "names")) (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "key")) (EVar "n")) (EVar "acc")))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "indexTwinsGo") (EVar "names")) (EVar "rest")) (EVar "acc")))))
(DTypeSig false "preludeFunName" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "preludeFunName" ((PVar "names") (PVar "n")) (EIf (EApp (EApp (EVar "omHasKey") (EBinOp "++" (ELit (LString "core__")) (EVar "n"))) (EVar "names")) (EApp (EVar "Some") (EBinOp "++" (ELit (LString "core__")) (EVar "n"))) (EIf (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "names")) (EApp (EVar "Some") (EVar "n")) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "topFunNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit")))))
(DFunDef false "topFunNames" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "topFunNames" ((PCons (PCon "DFunDef" PWild (PVar "n") PWild PWild PWild) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "topFunNames") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (ELit LUnit)) (EVar "acc"))))
(DFunDef false "topFunNames" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "topFunNames") (EBinOp "::" (EVar "d") (EVar "rest"))) (EVar "acc")))
(DFunDef false "topFunNames" ((PCons PWild (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "topFunNames") (EVar "rest")) (EVar "acc")))
(DTypeSig false "indexTwinOf" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "indexTwinOf" ((PVar "twins") (PCon "ELoc" PWild (PVar "h"))) (EApp (EApp (EVar "indexTwinOf") (EVar "twins")) (EVar "h")))
(DFunDef false "indexTwinOf" ((PVar "twins") (PCon "EMethodAt" (PLit (LString "index")) PWild (PVar "ev"))) (EMatch (EApp (EVar "evMethodRoutes") (EVar "ev")) (arm (PTuple PWild PWild (PCon "RKey" (PVar "key") PWild PWild) PWild PWild) () (EApp (EApp (EVar "omLookup") (EVar "key")) (EVar "twins"))) (arm PWild () (EVar "None"))))
(DFunDef false "indexTwinOf" (PWild PWild) (EVar "None"))
(DTypeSig false "declBinders" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "declBinders" ((PRec "DImpl" ((rf "methods" None)) true)) (EApp (EApp (EVar "flatMap") (EVar "implMethodBinders")) (EVar "methods")))
(DFunDef false "declBinders" ((PRec "DInterface" ((rf "methods" None)) true)) (EApp (EApp (EVar "flatMap") (EVar "ifaceMethodBinders")) (EVar "methods")))
(DFunDef false "declBinders" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "declBinders") (EVar "d")))
(DFunDef false "declBinders" ((PVar "d")) (EBinOp "++" (EApp (EVar "localBoundNames") (EListLit (EVar "d"))) (EApp (EVar "localFunNames") (EVar "d"))))
(DTypeSig false "implMethodBinders" (TyFun (TyCon "ImplMethod") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "implMethodBinders" ((PCon "ImplMethod" (PVar "n") (PVar "ps") (PVar "body"))) (EApp (EVar "declBinders") (EApp (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "False")) (EVar "n")) (EVar "ps")) (EVar "body")) (EVar "noDeclLoc"))))
(DTypeSig false "ifaceMethodBinders" (TyFun (TyCon "IfaceMethod") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "ifaceMethodBinders" ((PCon "IfaceMethod" (PVar "n") PWild (PCon "Some" (PCon "MethodDefault" (PVar "ps") (PVar "body"))) PWild)) (EApp (EVar "declBinders") (EApp (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "False")) (EVar "n")) (EVar "ps")) (EVar "body")) (EVar "noDeclLoc"))))
(DFunDef false "ifaceMethodBinders" (PWild) (EListLit))
(DTypeSig false "localFunNames" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "localFunNames" ((PVar "d")) (EBlock (DoLet false false (PVar "acc") (EApp (EVar "Ref") (EListLit))) (DoLet false false PWild (EApp (EApp (EVar "mapProg") (EApp (EVar "noteLocalFuns") (EVar "acc"))) (EListLit (EVar "d")))) (DoExpr (EUnOp "!" (EVar "acc")))))
(DTypeSig false "noteLocalFuns" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "Expr") (TyCon "Expr"))))
(DFunDef false "noteLocalFuns" ((PVar "acc") (PAs "e" (PCon "ELetGroup" (PVar "binds") PWild))) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EVar "acc")) (EBinOp "++" (EApp (EApp (EVar "map") (EVar "letBindName")) (EVar "binds")) (EUnOp "!" (EVar "acc"))))) (DoExpr (EVar "e"))))
(DFunDef false "noteLocalFuns" (PWild (PVar "e")) (EVar "e"))
(DTypeSig false "letBindName" (TyFun (TyCon "LetBind") (TyCon "String")))
(DFunDef false "letBindName" ((PCon "LetBind" (PVar "n") PWild PWild)) (EVar "n"))
(DTypeSig true "declaredRecordFieldOrders" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "declaredRecordFieldOrders" ((PVar "prog")) (EApp (EApp (EVar "flatMap") (EVar "recPatFieldOrderEntries")) (EVar "prog")))
(DTypeSig false "recPatFieldOrderEntries" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "recPatFieldOrderEntries" ((PRec "DData" ((rf "dataCtors" (PVar "variants"))) false)) (EApp (EApp (EVar "flatMap") (EVar "variantNamedOrder")) (EVar "variants")))
(DFunDef false "recPatFieldOrderEntries" ((PCon "DAttrib" PWild (PVar "inner"))) (EApp (EVar "recPatFieldOrderEntries") (EVar "inner")))
(DFunDef false "recPatFieldOrderEntries" (PWild) (EListLit))
(DTypeSig false "variantNamedOrder" (TyFun (TyCon "Variant") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "variantNamedOrder" ((PCon "Variant" (PVar "n") (PCon "ConNamed" (PVar "fs") PWild))) (EListLit (ETuple (EVar "n") (EApp (EApp (EVar "map") (EVar "fieldLabel")) (EVar "fs")))))
(DFunDef false "variantNamedOrder" (PWild) (EListLit))
(DTypeSig false "fieldLabel" (TyFun (TyCon "Field") (TyCon "String")))
(DFunDef false "fieldLabel" ((PCon "Field" (PVar "n") PWild)) (EVar "n"))
(DTypeSig false "rewritePat" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyCon "Pat") (TyCon "Pat"))))
(DFunDef false "rewritePat" ((PVar "fo") (PCon "PRec" (PVar "name") (PVar "recFields") PWild)) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "name")) (EVar "fo")) (arm (PCon "Some" (PVar "labels")) () (EApp (EApp (EVar "PCon") (EVar "name")) (EApp (EApp (EVar "map") (EApp (EApp (EVar "recPatForLabel") (EVar "fo")) (EVar "recFields"))) (EVar "labels")))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "PRec") (EVar "name")) (EApp (EApp (EVar "map") (EApp (EVar "rewriteRecPatField") (EVar "fo"))) (EVar "recFields"))) (EVar "False")))))
(DFunDef false "rewritePat" ((PVar "fo") (PCon "PCon" (PVar "c") (PVar "args"))) (EApp (EApp (EVar "PCon") (EVar "c")) (EApp (EApp (EVar "map") (EApp (EVar "rewritePat") (EVar "fo"))) (EVar "args"))))
(DFunDef false "rewritePat" ((PVar "fo") (PCon "PCons" (PVar "h") (PVar "t"))) (EApp (EApp (EVar "PCons") (EApp (EApp (EVar "rewritePat") (EVar "fo")) (EVar "h"))) (EApp (EApp (EVar "rewritePat") (EVar "fo")) (EVar "t"))))
(DFunDef false "rewritePat" ((PVar "fo") (PCon "PTuple" (PVar "ps"))) (EApp (EVar "PTuple") (EApp (EApp (EVar "map") (EApp (EVar "rewritePat") (EVar "fo"))) (EVar "ps"))))
(DFunDef false "rewritePat" ((PVar "fo") (PCon "PList" (PVar "ps"))) (EApp (EVar "PList") (EApp (EApp (EVar "map") (EApp (EVar "rewritePat") (EVar "fo"))) (EVar "ps"))))
(DFunDef false "rewritePat" ((PVar "fo") (PCon "PAs" (PVar "x") (PVar "l") (PVar "p"))) (EApp (EApp (EApp (EVar "PAs") (EVar "x")) (EVar "l")) (EApp (EApp (EVar "rewritePat") (EVar "fo")) (EVar "p"))))
(DFunDef false "rewritePat" (PWild (PVar "p")) (EVar "p"))
(DTypeSig false "recPatForLabel" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyApp (TyCon "List") (TyCon "RecPatField")) (TyFun (TyCon "String") (TyCon "Pat")))))
(DFunDef false "recPatForLabel" ((PVar "fo") (PVar "recFields") (PVar "label")) (EMatch (EApp (EApp (EVar "findRecField") (EVar "label")) (EVar "recFields")) (arm (PCon "Some" (PCon "RecPatField" PWild (PVar "fl") (PCon "Some" (PVar "sub")))) () (EApp (EApp (EVar "rewritePat") (EVar "fo")) (EVar "sub"))) (arm (PCon "Some" (PCon "RecPatField" PWild (PVar "fl") (PCon "None"))) () (EApp (EApp (EVar "PVar") (EVar "label")) (EVar "fl"))) (arm (PCon "None") () (EVar "PWild"))))
(DTypeSig false "findRecField" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "RecPatField")) (TyApp (TyCon "Option") (TyCon "RecPatField")))))
(DFunDef false "findRecField" (PWild (PList)) (EVar "None"))
(DFunDef false "findRecField" ((PVar "label") (PCons (PCon "RecPatField" (PVar "l") (PVar "fl") (PVar "sub")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "l") (EVar "label")) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "RecPatField") (EVar "l")) (EVar "fl")) (EVar "sub"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "findRecField") (EVar "label")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "rewriteRecPatField" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyCon "RecPatField") (TyCon "RecPatField"))))
(DFunDef false "rewriteRecPatField" ((PVar "fo") (PCon "RecPatField" (PVar "l") (PVar "fl") (PCon "Some" (PVar "sub")))) (EApp (EApp (EApp (EVar "RecPatField") (EVar "l")) (EVar "fl")) (EApp (EVar "Some") (EApp (EApp (EVar "rewritePat") (EVar "fo")) (EVar "sub")))))
(DFunDef false "rewriteRecPatField" (PWild (PCon "RecPatField" (PVar "l") (PVar "fl") (PCon "None"))) (EApp (EApp (EApp (EVar "RecPatField") (EVar "l")) (EVar "fl")) (EVar "None")))
(DTypeSig false "rewriteProgramRecPats" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyCon "CProgram") (TyCon "CProgram"))))
(DFunDef false "rewriteProgramRecPats" ((PVar "fo") (PCon "CProgram" (PVar "groups") (PVar "ctorArs") (PVar "ctorTypes") (PVar "implEntries"))) (EApp (EApp (EApp (EApp (EVar "CProgram") (EApp (EApp (EVar "map") (EApp (EVar "rewriteBindRP") (EVar "fo"))) (EVar "groups"))) (EVar "ctorArs")) (EVar "ctorTypes")) (EApp (EApp (EVar "map") (EApp (EVar "rewriteImplRP") (EVar "fo"))) (EVar "implEntries"))))
(DTypeSig false "rewriteBindRP" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyCon "CBind") (TyCon "CBind"))))
(DFunDef false "rewriteBindRP" ((PVar "fo") (PCon "CBind" (PVar "n") (PVar "clauses") (PVar "site"))) (EApp (EApp (EApp (EVar "CBind") (EVar "n")) (EApp (EApp (EVar "map") (EApp (EVar "rewriteClauseRP") (EVar "fo"))) (EVar "clauses"))) (EVar "site")))
(DTypeSig false "rewriteClauseRP" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyCon "CClause") (TyCon "CClause"))))
(DFunDef false "rewriteClauseRP" ((PVar "fo") (PCon "CClause" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "CClause") (EApp (EApp (EVar "map") (EApp (EVar "rewritePat") (EVar "fo"))) (EVar "pats"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "body"))))
(DTypeSig false "rewriteImplRP" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyCon "CImplEntry") (TyCon "CImplEntry"))))
(DFunDef false "rewriteImplRP" ((PVar "fo") (PCon "CImplEntry" (PVar "n") (PVar "s") (PCon "CImplTagged" (PVar "tag") (PVar "key") (PVar "iface") (PVar "ps") (PVar "pats") (PVar "body")))) (EApp (EApp (EApp (EVar "CImplEntry") (EVar "n")) (EVar "s")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "CImplTagged") (EVar "tag")) (EVar "key")) (EVar "iface")) (EVar "ps")) (EApp (EApp (EVar "map") (EApp (EVar "rewritePat") (EVar "fo"))) (EVar "pats"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "body")))))
(DFunDef false "rewriteImplRP" ((PVar "fo") (PCon "CImplEntry" (PVar "n") (PVar "s") (PCon "CImplDefault" (PVar "ifaceId") (PVar "tag") (PVar "key") (PVar "ps") (PVar "pats") (PVar "body")))) (EApp (EApp (EApp (EVar "CImplEntry") (EVar "n")) (EVar "s")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "CImplDefault") (EVar "ifaceId")) (EVar "tag")) (EVar "key")) (EVar "ps")) (EApp (EApp (EVar "map") (EApp (EVar "rewritePat") (EVar "fo"))) (EVar "pats"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "body")))))
(DTypeSig false "rewriteExprRP" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyCon "CExpr") (TyCon "CExpr"))))
(DFunDef false "rewriteExprRP" (PWild (PCon "CLit" (PVar "l"))) (EApp (EVar "CLit") (EVar "l")))
(DFunDef false "rewriteExprRP" (PWild (PCon "CVar" (PVar "x") (PVar "addr"))) (EApp (EApp (EVar "CVar") (EVar "x")) (EVar "addr")))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CApp" (PVar "f") (PVar "x"))) (EApp (EApp (EVar "CApp") (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "f"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "x"))))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CLam" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "CLam") (EApp (EApp (EVar "map") (EApp (EVar "rewritePat") (EVar "fo"))) (EVar "pats"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "body"))))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CLet" (PVar "r") (PVar "pat") (PVar "e1") (PVar "e2"))) (EApp (EApp (EApp (EApp (EVar "CLet") (EVar "r")) (EApp (EApp (EVar "rewritePat") (EVar "fo")) (EVar "pat"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "e1"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "e2"))))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CLetGroup" (PVar "binds") (PVar "body"))) (EApp (EApp (EVar "CLetGroup") (EApp (EApp (EVar "map") (EApp (EVar "rewriteBindRP") (EVar "fo"))) (EVar "binds"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "body"))))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CMatch" (PVar "scrut") (PVar "arms"))) (EApp (EApp (EVar "CMatch") (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "scrut"))) (EApp (EApp (EVar "map") (EApp (EVar "rewriteArmRP") (EVar "fo"))) (EVar "arms"))))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CDecision" (PVar "scrut") (PVar "arms") (PVar "tree"))) (EBlock (DoLet false false (PVar "arms2") (EApp (EApp (EVar "map") (EApp (EVar "rewriteArmRP") (EVar "fo"))) (EVar "arms"))) (DoExpr (EApp (EApp (EApp (EVar "CDecision") (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "scrut"))) (EVar "arms2")) (EApp (EApp (EVar "compileArmsC") (EApp (EVar "treeFailSite") (EVar "tree"))) (EVar "arms2"))))))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CIf" (PVar "c") (PVar "t") (PVar "e"))) (EApp (EApp (EApp (EVar "CIf") (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "c"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "t"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "e"))))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CBinPrim" (PVar "op") (PVar "l") (PVar "r") (PVar "tag") (PVar "site"))) (EApp (EApp (EApp (EApp (EApp (EVar "CBinPrim") (EVar "op")) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "l"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "r"))) (EVar "tag")) (EVar "site")))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CUnOp" (PVar "op") (PVar "x"))) (EApp (EApp (EVar "CUnOp") (EVar "op")) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "x"))))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CTuple" (PVar "es"))) (EApp (EVar "CTuple") (EApp (EApp (EVar "map") (EApp (EVar "rewriteExprRP") (EVar "fo"))) (EVar "es"))))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CList" (PVar "es"))) (EApp (EVar "CList") (EApp (EApp (EVar "map") (EApp (EVar "rewriteExprRP") (EVar "fo"))) (EVar "es"))))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CRecord" (PVar "name") (PVar "fields"))) (EApp (EApp (EApp (EVar "normalizeRecordOrder") (EVar "fo")) (EVar "name")) (EApp (EApp (EVar "map") (EApp (EVar "rewriteFieldRP") (EVar "fo"))) (EVar "fields"))))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CFieldAccess" (PVar "ex") (PVar "f") (PVar "n"))) (EApp (EApp (EApp (EVar "CFieldAccess") (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "ex"))) (EVar "f")) (EVar "n")))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CRecordUpdate" (PVar "name") (PVar "base") (PVar "fields"))) (EApp (EApp (EApp (EVar "CRecordUpdate") (EVar "name")) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "base"))) (EApp (EApp (EVar "map") (EApp (EVar "rewriteFieldRP") (EVar "fo"))) (EVar "fields"))))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CVariantUpdate" (PVar "con") (PVar "base") (PVar "fields"))) (EApp (EApp (EApp (EVar "CVariantUpdate") (EVar "con")) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "base"))) (EApp (EApp (EVar "map") (EApp (EVar "rewriteFieldRP") (EVar "fo"))) (EVar "fields"))))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CArray" (PVar "es"))) (EApp (EVar "CArray") (EApp (EApp (EVar "map") (EApp (EVar "rewriteExprRP") (EVar "fo"))) (EVar "es"))))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CRangeList" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EVar "CRangeList") (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "lo"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CRangeArray" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EVar "CRangeArray") (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "lo"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CIndex" (PVar "a") (PVar "i"))) (EApp (EApp (EVar "CIndex") (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "a"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "i"))))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CSlice" (PVar "a") (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EApp (EVar "CSlice") (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "a"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "lo"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CStringIndex" (PVar "a") (PVar "i"))) (EApp (EApp (EVar "CStringIndex") (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "a"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "i"))))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CStringSlice" (PVar "a") (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EApp (EVar "CStringSlice") (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "a"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "lo"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CListIndex" (PVar "a") (PVar "i"))) (EApp (EApp (EVar "CListIndex") (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "a"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "i"))))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CListSlice" (PVar "a") (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EApp (EVar "CListSlice") (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "a"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "lo"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CBlock" (PVar "stmts"))) (EApp (EVar "CBlock") (EApp (EApp (EVar "map") (EApp (EVar "rewriteStmtRP") (EVar "fo"))) (EVar "stmts"))))
(DFunDef false "rewriteExprRP" (PWild (PCon "CMethod" (PVar "name") (PVar "iface") (PVar "arity") (PVar "r") (PVar "ir") (PVar "mr"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "CMethod") (EVar "name")) (EVar "iface")) (EVar "arity")) (EVar "r")) (EVar "ir")) (EVar "mr")))
(DFunDef false "rewriteExprRP" (PWild (PCon "CDict" (PVar "name") (PVar "rs"))) (EApp (EApp (EVar "CDict") (EVar "name")) (EVar "rs")))
(DTypeSig false "rewriteArmRP" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyCon "CArm") (TyCon "CArm"))))
(DFunDef false "rewriteArmRP" ((PVar "fo") (PCon "CArm" (PVar "pat") (PVar "guards") (PVar "body"))) (EApp (EApp (EApp (EVar "CArm") (EApp (EApp (EVar "rewritePat") (EVar "fo")) (EVar "pat"))) (EApp (EApp (EVar "map") (EApp (EVar "rewriteGuardRP") (EVar "fo"))) (EVar "guards"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "body"))))
(DTypeSig false "rewriteGuardRP" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyCon "CGuard") (TyCon "CGuard"))))
(DFunDef false "rewriteGuardRP" ((PVar "fo") (PCon "CGBool" (PVar "e"))) (EApp (EVar "CGBool") (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "e"))))
(DFunDef false "rewriteGuardRP" ((PVar "fo") (PCon "CGBind" (PVar "p") (PVar "e"))) (EApp (EApp (EVar "CGBind") (EApp (EApp (EVar "rewritePat") (EVar "fo")) (EVar "p"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "e"))))
(DTypeSig false "rewriteStmtRP" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyCon "CStmt") (TyCon "CStmt"))))
(DFunDef false "rewriteStmtRP" ((PVar "fo") (PCon "CSExpr" (PVar "e"))) (EApp (EVar "CSExpr") (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "e"))))
(DFunDef false "rewriteStmtRP" ((PVar "fo") (PCon "CSLet" (PVar "r") (PVar "pat") (PVar "e"))) (EApp (EApp (EApp (EVar "CSLet") (EVar "r")) (EApp (EApp (EVar "rewritePat") (EVar "fo")) (EVar "pat"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "e"))))
(DFunDef false "rewriteStmtRP" ((PVar "fo") (PCon "CSAssign" (PVar "x") (PVar "e"))) (EApp (EApp (EVar "CSAssign") (EVar "x")) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "e"))))
(DTypeSig false "rewriteFieldRP" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyCon "CField") (TyCon "CField"))))
(DFunDef false "rewriteFieldRP" ((PVar "fo") (PCon "CField" (PVar "k") (PVar "e"))) (EApp (EApp (EVar "CField") (EVar "k")) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "e"))))
(DTypeSig false "normalizeRecordOrder" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "CField")) (TyCon "CExpr")))))
(DFunDef false "normalizeRecordOrder" ((PVar "fo") (PVar "name") (PVar "fields")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "name")) (EVar "fo")) (arm (PCon "None") () (EApp (EApp (EVar "CRecord") (EVar "name")) (EVar "fields"))) (arm (PCon "Some" (PVar "labels")) () (EBlock (DoLet false false (PVar "written") (EApp (EApp (EVar "map") (EVar "cFieldLabel")) (EVar "fields"))) (DoExpr (EIf (EBinOp "||" (EBinOp "==" (EVar "written") (EVar "labels")) (EApp (EVar "not") (EApp (EApp (EVar "isPermutationOf") (EVar "written")) (EVar "labels")))) (EApp (EApp (EVar "CRecord") (EVar "name")) (EVar "fields")) (EApp (EApp (EVar "bindFieldTemps") (EVar "fields")) (EApp (EApp (EVar "CRecord") (EVar "name")) (EApp (EApp (EVar "map") (EVar "recTempField")) (EVar "labels"))))))))))
(DTypeSig false "isPermutationOf" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "isPermutationOf" ((PVar "written") (PVar "labels")) (EBinOp "&&" (EBinOp "==" (EApp (EVar "listLen") (EVar "written")) (EApp (EVar "listLen") (EVar "labels"))) (EApp (EApp (EVar "allList") (ELam ((PVar "l")) (EApp (EApp (EVar "contains") (EVar "l")) (EVar "written")))) (EVar "labels"))))
(DTypeSig false "cFieldLabel" (TyFun (TyCon "CField") (TyCon "String")))
(DFunDef false "cFieldLabel" ((PCon "CField" (PVar "k") PWild)) (EVar "k"))
(DTypeSig false "recTempName" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "recTempName" ((PVar "label")) (EBinOp "++" (ELit (LString "$rf$")) (EVar "label")))
(DTypeSig false "recTempField" (TyFun (TyCon "String") (TyCon "CField")))
(DFunDef false "recTempField" ((PVar "label")) (EApp (EApp (EVar "CField") (EVar "label")) (EApp (EApp (EVar "CVar") (EApp (EVar "recTempName") (EVar "label"))) (EVar "AGlobal"))))
(DTypeSig false "bindFieldTemps" (TyFun (TyApp (TyCon "List") (TyCon "CField")) (TyFun (TyCon "CExpr") (TyCon "CExpr"))))
(DFunDef false "bindFieldTemps" ((PList) (PVar "body")) (EVar "body"))
(DFunDef false "bindFieldTemps" ((PCons (PCon "CField" (PVar "k") (PVar "ex")) (PVar "rest")) (PVar "body")) (EApp (EApp (EApp (EApp (EVar "CLet") (EVar "False")) (EApp (EApp (EVar "PVar") (EApp (EVar "recTempName") (EVar "k"))) (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString ""))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))))) (EVar "ex")) (EApp (EApp (EVar "bindFieldTemps") (EVar "rest")) (EVar "body"))))
(DTypeSig false "memoKeys" (TyFun (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String")))))
(DFunDef false "memoKeys" ((PVar "entries")) (EApp (EApp (EVar "memoKeysGo") (EVar "entries")) (EVar "entries")))
(DTypeSig false "memoKeysGo" (TyFun (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyFun (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String"))))))
(DFunDef false "memoKeysGo" (PWild (PList)) (EListLit))
(DFunDef false "memoKeysGo" ((PVar "all") (PCons (PCon "CImplEntry" (PVar "m") PWild (PCon "CImplTagged" (PVar "tag") (PVar "key") PWild (PVar "positions") (PVar "pats") PWild)) (PVar "rest"))) (EIf (EBinOp "&&" (EApp (EVar "isEmptyL") (EVar "positions")) (EApp (EVar "isEmptyL") (EVar "pats"))) (EBinOp "::" (ETuple (EVar "m") (EVar "key") (EApp (EApp (EApp (EApp (EVar "memoSelector") (EVar "all")) (EVar "m")) (EVar "tag")) (EVar "key"))) (EApp (EApp (EVar "memoKeysGo") (EVar "all")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "memoKeysGo" ((PVar "all") (PCons (PCon "CImplEntry" (PVar "m") PWild (PCon "CImplDefault" PWild (PVar "tag") (PVar "key") (PVar "positions") (PVar "pats") PWild)) (PVar "rest"))) (EIf (EBinOp "&&" (EApp (EVar "isEmptyL") (EVar "positions")) (EApp (EVar "isEmptyL") (EVar "pats"))) (EBinOp "::" (ETuple (EVar "m") (EVar "key") (EApp (EApp (EApp (EApp (EVar "memoSelector") (EVar "all")) (EVar "m")) (EVar "tag")) (EVar "key"))) (EApp (EApp (EVar "memoKeysGo") (EVar "all")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "memoKeysGo" ((PVar "all") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "memoKeysGo") (EVar "all")) (EVar "rest")))
(DTypeSig false "memoSelector" (TyFun (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))))
(DFunDef false "memoSelector" ((PVar "all") (PVar "method") (PVar "tag") (PVar "key")) (EIf (EApp (EApp (EApp (EVar "headTagUniqueL") (EVar "all")) (EVar "method")) (EVar "tag")) (EVar "tag") (EVar "key")))
(DTypeSig false "headTagUniqueL" (TyFun (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool")))))
(DFunDef false "headTagUniqueL" ((PVar "entries") (PVar "method") (PVar "tag")) (EBinOp "<=" (EApp (EVar "listLen") (EApp (EApp (EApp (EApp (EVar "distinctKeysAtHeadL") (EVar "entries")) (EVar "method")) (EVar "tag")) (EListLit))) (ELit (LInt 1))))
(DTypeSig false "distinctKeysAtHeadL" (TyFun (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "distinctKeysAtHeadL" ((PList) PWild PWild (PVar "acc")) (EVar "acc"))
(DFunDef false "distinctKeysAtHeadL" ((PCons (PCon "CImplEntry" (PVar "n") PWild (PCon "CImplTagged" (PVar "t") (PVar "k") PWild PWild PWild PWild)) (PVar "rest")) (PVar "method") (PVar "tag") (PVar "acc")) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "n") (EVar "method")) (EBinOp "==" (EVar "t") (EVar "tag"))) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EVar "k")) (EVar "acc")))) (EApp (EApp (EApp (EApp (EVar "distinctKeysAtHeadL") (EVar "rest")) (EVar "method")) (EVar "tag")) (EBinOp "::" (EVar "k") (EVar "acc"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "distinctKeysAtHeadL") (EVar "rest")) (EVar "method")) (EVar "tag")) (EVar "acc")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "distinctKeysAtHeadL" ((PCons (PCon "CImplEntry" (PVar "n") PWild (PCon "CImplDefault" PWild (PVar "t") (PVar "k") PWild PWild PWild)) (PVar "rest")) (PVar "method") (PVar "tag") (PVar "acc")) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "n") (EVar "method")) (EBinOp "==" (EVar "t") (EVar "tag"))) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EVar "k")) (EVar "acc")))) (EApp (EApp (EApp (EApp (EVar "distinctKeysAtHeadL") (EVar "rest")) (EVar "method")) (EVar "tag")) (EBinOp "::" (EVar "k") (EVar "acc"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "distinctKeysAtHeadL") (EVar "rest")) (EVar "method")) (EVar "tag")) (EVar "acc")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "distinctKeysAtHeadL" ((PCons PWild (PVar "rest")) (PVar "method") (PVar "tag") (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "distinctKeysAtHeadL") (EVar "rest")) (EVar "method")) (EVar "tag")) (EVar "acc")))
(DTypeSig false "memoSelectorOf" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "memoSelectorOf" ((PList) PWild PWild) (EVar "None"))
(DFunDef false "memoSelectorOf" ((PCons (PTuple (PVar "m2") (PVar "k2") (PVar "sel")) (PVar "rest")) (PVar "m") (PVar "key")) (EIf (EBinOp "&&" (EBinOp "==" (EVar "m") (EVar "m2")) (EBinOp "==" (EVar "key") (EVar "k2"))) (EApp (EVar "Some") (EVar "sel")) (EApp (EApp (EApp (EVar "memoSelectorOf") (EVar "rest")) (EVar "m")) (EVar "key"))))
(DTypeSig false "soleMemoKeys" (TyFun (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "soleMemoKeys" (PWild (PList)) (EListLit))
(DFunDef false "soleMemoKeys" ((PVar "entries") (PCons (PTuple (PVar "m") (PVar "key") (PVar "sel")) (PVar "rest"))) (EIf (EBinOp "==" (EApp (EApp (EApp (EVar "taggedImplCount") (EVar "entries")) (EVar "m")) (ELit (LInt 1))) (ELit (LInt 1))) (EBinOp "::" (ETuple (EVar "m") (ETuple (EVar "key") (EVar "sel"))) (EApp (EApp (EVar "soleMemoKeys") (EVar "entries")) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "soleMemoKeys") (EVar "entries")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "taggedImplCount" (TyFun (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "taggedImplCount" ((PVar "entries") (PVar "method") (PVar "cap")) (EApp (EVar "listLen") (EApp (EApp (EApp (EApp (EVar "distinctImplKeysL") (EVar "entries")) (EVar "method")) (EVar "cap")) (EListLit))))
(DTypeSig false "distinctImplKeysL" (TyFun (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "distinctImplKeysL" ((PList) PWild PWild (PVar "acc")) (EVar "acc"))
(DFunDef false "distinctImplKeysL" (PWild PWild (PVar "cap") (PVar "acc")) (EIf (EBinOp ">" (EApp (EVar "listLen") (EVar "acc")) (EVar "cap")) (EVar "acc") (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "distinctImplKeysL" ((PCons (PCon "CImplEntry" (PVar "n") PWild (PCon "CImplTagged" PWild (PVar "k") PWild PWild PWild PWild)) (PVar "rest")) (PVar "method") (PVar "cap") (PVar "acc")) (EIf (EBinOp "&&" (EBinOp "==" (EVar "n") (EVar "method")) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EVar "k")) (EVar "acc")))) (EApp (EApp (EApp (EApp (EVar "distinctImplKeysL") (EVar "rest")) (EVar "method")) (EVar "cap")) (EBinOp "::" (EVar "k") (EVar "acc"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "distinctImplKeysL") (EVar "rest")) (EVar "method")) (EVar "cap")) (EVar "acc")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "distinctImplKeysL" ((PCons (PCon "CImplEntry" (PVar "n") PWild (PCon "CImplDefault" PWild PWild (PVar "k") PWild PWild PWild)) (PVar "rest")) (PVar "method") (PVar "cap") (PVar "acc")) (EIf (EBinOp "&&" (EBinOp "==" (EVar "n") (EVar "method")) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EVar "k")) (EVar "acc")))) (EApp (EApp (EApp (EApp (EVar "distinctImplKeysL") (EVar "rest")) (EVar "method")) (EVar "cap")) (EBinOp "::" (EVar "k") (EVar "acc"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "distinctImplKeysL") (EVar "rest")) (EVar "method")) (EVar "cap")) (EVar "acc")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "distinctImplKeysL" ((PCons PWild (PVar "rest")) (PVar "method") (PVar "cap") (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "distinctImplKeysL") (EVar "rest")) (EVar "method")) (EVar "cap")) (EVar "acc")))
(DData Private "LowerState" () ((variant "LowerState" (ConNamed (field "memoKeysAll" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String")))) (field "soleKeys" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyCon "String") (TyCon "String"))))) (field "memoRefs" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String")))))))) ())
(DTypeSig false "memoBindName" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "memoBindName" ((PVar "selector") (PVar "method")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "$memo_")) (EApp (EVar "display") (EApp (EVar "injectiveIdent") (EVar "selector")))) (ELit (LString "_"))) (EApp (EVar "display") (EVar "method"))) (ELit (LString ""))))
(DTypeSig false "recordMemoRef" (TyFun (TyCon "LowerState") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Unit"))))))
(DFunDef false "recordMemoRef" ((PVar "st") (PVar "sel") (PVar "key") (PVar "method")) (ELet false (PVar "refs") (EFieldAccess (EVar "st") "memoRefs") (EApp (EApp (EVar "setRef") (EVar "refs")) (EBinOp "::" (ETuple (EVar "sel") (EVar "key") (EVar "method")) (EUnOp "!" (EVar "refs"))))))
(DTypeSig false "hoistDictNullary" (TyFun (TyCon "LowerState") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Route") (TyCon "CExpr"))))))
(DFunDef false "hoistDictNullary" ((PVar "st") (PVar "name") (PVar "iface") (PVar "route")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "name")) (EFieldAccess (EVar "st") "soleKeys")) (arm (PCon "Some" (PTuple (PVar "key") (PVar "sel"))) () (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "recordMemoRef") (EVar "st")) (EVar "sel")) (EVar "key")) (EVar "name"))) (DoExpr (EApp (EApp (EVar "CVar") (EApp (EApp (EVar "memoBindName") (EVar "sel")) (EVar "name"))) (EVar "AGlobal"))))) (arm (PCon "None") () (EBlock (DoLet false false PWild (EApp (EApp (EVar "recordMultiImplMemo") (EVar "st")) (EVar "name"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "CMethod") (EVar "name")) (EVar "iface")) (ELit (LInt 0))) (EVar "route")) (EListLit)) (EListLit)))))))
(DTypeSig false "recordMultiImplMemo" (TyFun (TyCon "LowerState") (TyFun (TyCon "String") (TyCon "Unit"))))
(DFunDef false "recordMultiImplMemo" ((PVar "st") (PVar "name")) (EApp (EApp (EApp (EVar "recordMultiImplMemoGo") (EVar "st")) (EVar "name")) (EFieldAccess (EVar "st") "memoKeysAll")))
(DTypeSig false "recordMultiImplMemoGo" (TyFun (TyCon "LowerState") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String"))) (TyCon "Unit")))))
(DFunDef false "recordMultiImplMemoGo" (PWild PWild (PList)) (ELit LUnit))
(DFunDef false "recordMultiImplMemoGo" ((PVar "st") (PVar "name") (PCons (PTuple (PVar "m") (PVar "key") (PVar "sel")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "m") (EVar "name")) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "recordMemoRef") (EVar "st")) (EVar "sel")) (EVar "key")) (EVar "name"))) (DoExpr (EApp (EApp (EApp (EVar "recordMultiImplMemoGo") (EVar "st")) (EVar "name")) (EVar "rest")))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "recordMultiImplMemoGo") (EVar "st")) (EVar "name")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "hoistNullaryMemo" (TyFun (TyCon "CProgram") (TyCon "CProgram")))
(DFunDef false "hoistNullaryMemo" ((PCon "CProgram" (PVar "groups") (PVar "ctorArs") (PVar "ctorTypes") (PVar "implEntries"))) (EBlock (DoLet false false (PVar "keys") (EApp (EVar "memoKeys") (EVar "implEntries"))) (DoExpr (EIf (EApp (EVar "isEmptyL") (EVar "keys")) (EApp (EApp (EApp (EApp (EVar "CProgram") (EVar "groups")) (EVar "ctorArs")) (EVar "ctorTypes")) (EVar "implEntries")) (EBlock (DoLet false false (PVar "st") (ERecordCreate "LowerState" ((fa "memoKeysAll" (EVar "keys")) (fa "soleKeys" (EApp (EApp (EVar "soleMemoKeys") (EVar "implEntries")) (EVar "keys"))) (fa "memoRefs" (EApp (EVar "Ref") (EListLit)))))) (DoLet false false (PVar "groups2") (EApp (EApp (EVar "map") (EApp (EVar "hoistBind") (EVar "st"))) (EVar "groups"))) (DoLet false false (PVar "impls2") (EApp (EApp (EVar "map") (EApp (EVar "hoistImpl") (EVar "st"))) (EVar "implEntries"))) (DoLet false false (PVar "refs") (EApp (EVar "dedupPairs") (EApp (EVar "reverseL") (EUnOp "!" (EFieldAccess (EVar "st") "memoRefs"))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "CProgram") (EBinOp "++" (EApp (EApp (EVar "map") (EVar "memoCafBind")) (EVar "refs")) (EVar "groups2"))) (EVar "ctorArs")) (EVar "ctorTypes")) (EVar "impls2"))))))))
(DTypeSig false "memoCafBind" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyCon "String")) (TyCon "CBind")))
(DFunDef false "memoCafBind" ((PTuple (PVar "sel") (PVar "key") (PVar "method"))) (EApp (EApp (EApp (EVar "CBind") (EApp (EApp (EVar "memoBindName") (EVar "sel")) (EVar "method"))) (EListLit (EApp (EApp (EVar "CClause") (EListLit)) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "CMethod") (EVar "method")) (ELit (LString ""))) (ELit (LInt 0))) (EApp (EApp (EApp (EVar "RKey") (EVar "key")) (EListLit)) (EListLit))) (EListLit)) (EListLit))))) (EVar "noDeclLoc")))
(DTypeSig false "dedupPairs" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String")))))
(DFunDef false "dedupPairs" ((PVar "ps")) (EApp (EApp (EVar "dedupBy") (EVar "memoRefKey")) (EVar "ps")))
(DTypeSig false "memoRefKey" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyCon "String")) (TyCon "String")))
(DFunDef false "memoRefKey" ((PTuple (PVar "sel") PWild (PVar "method"))) (EBinOp "++" (EApp (EVar "lenKey") (EVar "sel")) (EVar "method")))
(DTypeSig false "hoistBind" (TyFun (TyCon "LowerState") (TyFun (TyCon "CBind") (TyCon "CBind"))))
(DFunDef false "hoistBind" ((PVar "st") (PCon "CBind" (PVar "n") (PVar "clauses") (PVar "site"))) (EApp (EApp (EApp (EVar "CBind") (EVar "n")) (EApp (EApp (EVar "map") (EApp (EVar "hoistClause") (EVar "st"))) (EVar "clauses"))) (EVar "site")))
(DTypeSig false "hoistClause" (TyFun (TyCon "LowerState") (TyFun (TyCon "CClause") (TyCon "CClause"))))
(DFunDef false "hoistClause" ((PVar "st") (PCon "CClause" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "CClause") (EVar "pats")) (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "body"))))
(DTypeSig false "hoistImpl" (TyFun (TyCon "LowerState") (TyFun (TyCon "CImplEntry") (TyCon "CImplEntry"))))
(DFunDef false "hoistImpl" ((PVar "st") (PCon "CImplEntry" (PVar "n") (PVar "s") (PCon "CImplTagged" (PVar "tag") (PVar "key") (PVar "iface") (PVar "pos") (PVar "pats") (PVar "body")))) (EApp (EApp (EApp (EVar "CImplEntry") (EVar "n")) (EVar "s")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "CImplTagged") (EVar "tag")) (EVar "key")) (EVar "iface")) (EVar "pos")) (EVar "pats")) (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "body")))))
(DFunDef false "hoistImpl" ((PVar "st") (PCon "CImplEntry" (PVar "n") (PVar "s") (PCon "CImplDefault" (PVar "ifaceId") (PVar "tag") (PVar "key") (PVar "pos") (PVar "pats") (PVar "body")))) (EApp (EApp (EApp (EVar "CImplEntry") (EVar "n")) (EVar "s")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "CImplDefault") (EVar "ifaceId")) (EVar "tag")) (EVar "key")) (EVar "pos")) (EVar "pats")) (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "body")))))
(DTypeSig false "hoistExpr" (TyFun (TyCon "LowerState") (TyFun (TyCon "CExpr") (TyCon "CExpr"))))
(DFunDef false "hoistExpr" ((PVar "st") (PCon "CMethod" (PVar "name") (PVar "iface") (PLit (LInt 0)) (PCon "RKey" (PVar "key") (PList) (PVar "sups")) (PList) (PList))) (EMatch (EApp (EApp (EApp (EVar "memoSelectorOf") (EFieldAccess (EVar "st") "memoKeysAll")) (EVar "name")) (EVar "key")) (arm (PCon "Some" (PVar "sel")) () (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "recordMemoRef") (EVar "st")) (EVar "sel")) (EVar "key")) (EVar "name"))) (DoExpr (EApp (EApp (EVar "CVar") (EApp (EApp (EVar "memoBindName") (EVar "sel")) (EVar "name"))) (EVar "AGlobal"))))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "CMethod") (EVar "name")) (EVar "iface")) (ELit (LInt 0))) (EApp (EApp (EApp (EVar "RKey") (EVar "key")) (EListLit)) (EVar "sups"))) (EListLit)) (EListLit)))))
(DFunDef false "hoistExpr" ((PVar "st") (PCon "CMethod" (PVar "name") (PVar "iface") (PLit (LInt 0)) (PCon "RDict" (PVar "d")) (PList) (PList))) (EApp (EApp (EApp (EApp (EVar "hoistDictNullary") (EVar "st")) (EVar "name")) (EVar "iface")) (EApp (EVar "RDict") (EVar "d"))))
(DFunDef false "hoistExpr" ((PVar "st") (PCon "CMethod" (PVar "name") (PVar "iface") (PLit (LInt 0)) (PCon "RDictFwd" (PVar "d")) (PList) (PList))) (EApp (EApp (EApp (EApp (EVar "hoistDictNullary") (EVar "st")) (EVar "name")) (EVar "iface")) (EApp (EVar "RDictFwd") (EVar "d"))))
(DFunDef false "hoistExpr" ((PVar "st") (PCon "CMethod" (PVar "name") (PVar "iface") (PLit (LInt 0)) (PCon "RProj" (PVar "r") (PVar "path")) (PList) (PList))) (EApp (EApp (EApp (EApp (EVar "hoistDictNullary") (EVar "st")) (EVar "name")) (EVar "iface")) (EApp (EApp (EVar "RProj") (EVar "r")) (EVar "path"))))
(DFunDef false "hoistExpr" (PWild (PCon "CMethod" (PVar "name") (PVar "iface") (PVar "arity") (PVar "r") (PVar "ir") (PVar "mr"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "CMethod") (EVar "name")) (EVar "iface")) (EVar "arity")) (EVar "r")) (EVar "ir")) (EVar "mr")))
(DFunDef false "hoistExpr" (PWild (PCon "CLit" (PVar "l"))) (EApp (EVar "CLit") (EVar "l")))
(DFunDef false "hoistExpr" (PWild (PCon "CVar" (PVar "x") (PVar "addr"))) (EApp (EApp (EVar "CVar") (EVar "x")) (EVar "addr")))
(DFunDef false "hoistExpr" ((PVar "st") (PCon "CApp" (PVar "f") (PVar "x"))) (EApp (EApp (EVar "CApp") (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "f"))) (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "x"))))
(DFunDef false "hoistExpr" ((PVar "st") (PCon "CLam" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "CLam") (EVar "pats")) (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "body"))))
(DFunDef false "hoistExpr" ((PVar "st") (PCon "CLet" (PVar "r") (PVar "pat") (PVar "e1") (PVar "e2"))) (EApp (EApp (EApp (EApp (EVar "CLet") (EVar "r")) (EVar "pat")) (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "e1"))) (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "e2"))))
(DFunDef false "hoistExpr" ((PVar "st") (PCon "CLetGroup" (PVar "binds") (PVar "body"))) (EApp (EApp (EVar "CLetGroup") (EApp (EApp (EVar "map") (EApp (EVar "hoistBind") (EVar "st"))) (EVar "binds"))) (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "body"))))
(DFunDef false "hoistExpr" ((PVar "st") (PCon "CMatch" (PVar "scrut") (PVar "arms"))) (EApp (EApp (EVar "CMatch") (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "scrut"))) (EApp (EApp (EVar "map") (EApp (EVar "hoistArm") (EVar "st"))) (EVar "arms"))))
(DFunDef false "hoistExpr" ((PVar "st") (PCon "CDecision" (PVar "scrut") (PVar "arms") (PVar "tree"))) (EApp (EApp (EApp (EVar "CDecision") (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "scrut"))) (EApp (EApp (EVar "map") (EApp (EVar "hoistArm") (EVar "st"))) (EVar "arms"))) (EVar "tree")))
(DFunDef false "hoistExpr" ((PVar "st") (PCon "CIf" (PVar "c") (PVar "t") (PVar "e"))) (EApp (EApp (EApp (EVar "CIf") (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "c"))) (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "t"))) (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "e"))))
(DFunDef false "hoistExpr" ((PVar "st") (PCon "CBinPrim" (PVar "op") (PVar "l") (PVar "r") (PVar "tag") (PVar "site"))) (EApp (EApp (EApp (EApp (EApp (EVar "CBinPrim") (EVar "op")) (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "l"))) (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "r"))) (EVar "tag")) (EVar "site")))
(DFunDef false "hoistExpr" ((PVar "st") (PCon "CUnOp" (PVar "op") (PVar "x"))) (EApp (EApp (EVar "CUnOp") (EVar "op")) (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "x"))))
(DFunDef false "hoistExpr" ((PVar "st") (PCon "CTuple" (PVar "es"))) (EApp (EVar "CTuple") (EApp (EApp (EVar "map") (EApp (EVar "hoistExpr") (EVar "st"))) (EVar "es"))))
(DFunDef false "hoistExpr" ((PVar "st") (PCon "CList" (PVar "es"))) (EApp (EVar "CList") (EApp (EApp (EVar "map") (EApp (EVar "hoistExpr") (EVar "st"))) (EVar "es"))))
(DFunDef false "hoistExpr" ((PVar "st") (PCon "CRecord" (PVar "name") (PVar "fields"))) (EApp (EApp (EVar "CRecord") (EVar "name")) (EApp (EApp (EVar "map") (EApp (EVar "hoistField") (EVar "st"))) (EVar "fields"))))
(DFunDef false "hoistExpr" ((PVar "st") (PCon "CFieldAccess" (PVar "ex") (PVar "f") (PVar "n"))) (EApp (EApp (EApp (EVar "CFieldAccess") (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "ex"))) (EVar "f")) (EVar "n")))
(DFunDef false "hoistExpr" ((PVar "st") (PCon "CRecordUpdate" (PVar "name") (PVar "base") (PVar "fields"))) (EApp (EApp (EApp (EVar "CRecordUpdate") (EVar "name")) (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "base"))) (EApp (EApp (EVar "map") (EApp (EVar "hoistField") (EVar "st"))) (EVar "fields"))))
(DFunDef false "hoistExpr" ((PVar "st") (PCon "CVariantUpdate" (PVar "con") (PVar "base") (PVar "fields"))) (EApp (EApp (EApp (EVar "CVariantUpdate") (EVar "con")) (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "base"))) (EApp (EApp (EVar "map") (EApp (EVar "hoistField") (EVar "st"))) (EVar "fields"))))
(DFunDef false "hoistExpr" ((PVar "st") (PCon "CArray" (PVar "es"))) (EApp (EVar "CArray") (EApp (EApp (EVar "map") (EApp (EVar "hoistExpr") (EVar "st"))) (EVar "es"))))
(DFunDef false "hoistExpr" ((PVar "st") (PCon "CRangeList" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EVar "CRangeList") (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "lo"))) (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "hoistExpr" ((PVar "st") (PCon "CRangeArray" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EVar "CRangeArray") (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "lo"))) (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "hoistExpr" ((PVar "st") (PCon "CIndex" (PVar "a") (PVar "i"))) (EApp (EApp (EVar "CIndex") (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "a"))) (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "i"))))
(DFunDef false "hoistExpr" ((PVar "st") (PCon "CSlice" (PVar "a") (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EApp (EVar "CSlice") (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "a"))) (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "lo"))) (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "hoistExpr" ((PVar "st") (PCon "CStringIndex" (PVar "a") (PVar "i"))) (EApp (EApp (EVar "CStringIndex") (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "a"))) (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "i"))))
(DFunDef false "hoistExpr" ((PVar "st") (PCon "CStringSlice" (PVar "a") (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EApp (EVar "CStringSlice") (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "a"))) (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "lo"))) (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "hoistExpr" ((PVar "st") (PCon "CListIndex" (PVar "a") (PVar "i"))) (EApp (EApp (EVar "CListIndex") (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "a"))) (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "i"))))
(DFunDef false "hoistExpr" ((PVar "st") (PCon "CListSlice" (PVar "a") (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EApp (EVar "CListSlice") (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "a"))) (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "lo"))) (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "hoistExpr" ((PVar "st") (PCon "CBlock" (PVar "stmts"))) (EApp (EVar "CBlock") (EApp (EApp (EVar "map") (EApp (EVar "hoistStmt") (EVar "st"))) (EVar "stmts"))))
(DFunDef false "hoistExpr" (PWild (PCon "CDict" (PVar "name") (PVar "rs"))) (EApp (EApp (EVar "CDict") (EVar "name")) (EVar "rs")))
(DTypeSig false "hoistArm" (TyFun (TyCon "LowerState") (TyFun (TyCon "CArm") (TyCon "CArm"))))
(DFunDef false "hoistArm" ((PVar "st") (PCon "CArm" (PVar "pat") (PVar "guards") (PVar "body"))) (EApp (EApp (EApp (EVar "CArm") (EVar "pat")) (EApp (EApp (EVar "map") (EApp (EVar "hoistGuard") (EVar "st"))) (EVar "guards"))) (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "body"))))
(DTypeSig false "hoistGuard" (TyFun (TyCon "LowerState") (TyFun (TyCon "CGuard") (TyCon "CGuard"))))
(DFunDef false "hoistGuard" ((PVar "st") (PCon "CGBool" (PVar "e"))) (EApp (EVar "CGBool") (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "e"))))
(DFunDef false "hoistGuard" ((PVar "st") (PCon "CGBind" (PVar "p") (PVar "e"))) (EApp (EApp (EVar "CGBind") (EVar "p")) (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "e"))))
(DTypeSig false "hoistStmt" (TyFun (TyCon "LowerState") (TyFun (TyCon "CStmt") (TyCon "CStmt"))))
(DFunDef false "hoistStmt" ((PVar "st") (PCon "CSExpr" (PVar "e"))) (EApp (EVar "CSExpr") (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "e"))))
(DFunDef false "hoistStmt" ((PVar "st") (PCon "CSLet" (PVar "r") (PVar "pat") (PVar "e"))) (EApp (EApp (EApp (EVar "CSLet") (EVar "r")) (EVar "pat")) (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "e"))))
(DFunDef false "hoistStmt" ((PVar "st") (PCon "CSAssign" (PVar "x") (PVar "e"))) (EApp (EApp (EVar "CSAssign") (EVar "x")) (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "e"))))
(DTypeSig false "hoistField" (TyFun (TyCon "LowerState") (TyFun (TyCon "CField") (TyCon "CField"))))
(DFunDef false "hoistField" ((PVar "st") (PCon "CField" (PVar "k") (PVar "e"))) (EApp (EApp (EVar "CField") (EVar "k")) (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "e"))))
(DTypeSig false "compileArmsC" (TyFun (TyCon "FailSite") (TyFun (TyApp (TyCon "List") (TyCon "CArm")) (TyCon "CTree"))))
(DFunDef false "compileArmsC" ((PVar "site") (PVar "arms")) (EApp (EApp (EApp (EVar "compileTree") (EVar "site")) (EApp (EApp (EVar "map") (EVar "carmHasGuard")) (EVar "arms"))) (EApp (EApp (EVar "cInitialRows") (EVar "arms")) (ELit (LInt 0)))))
(DTypeSig false "carmHasGuard" (TyFun (TyCon "CArm") (TyCon "Bool")))
(DFunDef false "carmHasGuard" ((PCon "CArm" (PVar "pat") (PVar "gs") PWild)) (EBinOp "||" (EApp (EVar "isNonEmptyL") (EVar "gs")) (EApp (EVar "patNeedsGuard") (EVar "pat"))))
(DTypeSig false "cInitialRows" (TyFun (TyApp (TyCon "List") (TyCon "CArm")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))))))
(DFunDef false "cInitialRows" ((PList) PWild) (EListLit))
(DFunDef false "cInitialRows" ((PCons (PCon "CArm" (PVar "pat") PWild PWild) (PVar "rest")) (PVar "i")) (EBinOp "::" (ETuple (EListLit (EApp (EVar "canonPat") (EVar "pat"))) (EVar "i")) (EApp (EApp (EVar "cInitialRows") (EVar "rest")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))
(DTypeSig true "lowerGroups" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "CBind"))))
(DFunDef false "lowerGroups" ((PVar "prog")) (EApp (EApp (EVar "map") (EApp (EVar "refoldBind") (EVar "noLetCheck"))) (EApp (EVar "lowerGroupsRaw") (EVar "prog"))))
(DTypeSig false "lowerGroupsRaw" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "CBind"))))
(DFunDef false "lowerGroupsRaw" ((PVar "prog")) (EApp (EApp (EVar "lgGroup") (EApp (EApp (EVar "bindSites") (EVar "prog")) (EVar "omEmpty"))) (EApp (EVar "funClausesOf") (EVar "prog"))))
(DTypeSig false "lgGroup" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Loc")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "CClause"))) (TyApp (TyCon "List") (TyCon "CBind")))))
(DFunDef false "lgGroup" ((PVar "sites") (PVar "clauses")) (EBlock (DoLet false false (PVar "groups") (EApp (EVar "lgRuns") (EApp (EVar "lgSortName") (EApp (EApp (EVar "lgTag") (EVar "clauses")) (ELit (LInt 0)))))) (DoExpr (EApp (EApp (EVar "map") (EApp (EVar "lgToBind") (EVar "sites"))) (EApp (EVar "lgSortIdx") (EVar "groups"))))))
(DTypeSig false "lgTag" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "CClause"))) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "Int")) (TyCon "CClause"))))))
(DFunDef false "lgTag" ((PList) PWild) (EListLit))
(DFunDef false "lgTag" ((PCons (PTuple (PVar "n") (PVar "c")) (PVar "rest")) (PVar "i")) (EBinOp "::" (ETuple (ETuple (EVar "n") (EVar "i")) (EVar "c")) (EApp (EApp (EVar "lgTag") (EVar "rest")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))
(DTypeSig false "lgSplit" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyTuple (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "lgSplit" ((PList)) (ETuple (EListLit) (EListLit)))
(DFunDef false "lgSplit" ((PList (PVar "x"))) (ETuple (EListLit (EVar "x")) (EListLit)))
(DFunDef false "lgSplit" ((PCons (PVar "x") (PCons (PVar "y") (PVar "rest")))) (EBlock (DoLet false false (PTuple (PVar "a") (PVar "b")) (EApp (EVar "lgSplit") (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EVar "x") (EVar "a")) (EBinOp "::" (EVar "y") (EVar "b"))))))
(DTypeSig false "lgSortName" (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "Int")) (TyCon "CClause"))) (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "Int")) (TyCon "CClause")))))
(DFunDef false "lgSortName" ((PList)) (EListLit))
(DFunDef false "lgSortName" ((PList (PVar "x"))) (EListLit (EVar "x")))
(DFunDef false "lgSortName" ((PVar "xs")) (EBlock (DoLet false false (PTuple (PVar "a") (PVar "b")) (EApp (EVar "lgSplit") (EVar "xs"))) (DoExpr (EApp (EApp (EVar "lgMergeName") (EApp (EVar "lgSortName") (EVar "a"))) (EApp (EVar "lgSortName") (EVar "b"))))))
(DTypeSig false "lgMergeName" (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "Int")) (TyCon "CClause"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "Int")) (TyCon "CClause"))) (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "Int")) (TyCon "CClause"))))))
(DFunDef false "lgMergeName" ((PList) (PVar "ys")) (EVar "ys"))
(DFunDef false "lgMergeName" ((PVar "xs") (PList)) (EVar "xs"))
(DFunDef false "lgMergeName" ((PCons (PTuple (PTuple (PVar "n1") (PVar "i1")) (PVar "c1")) (PVar "xs")) (PCons (PTuple (PTuple (PVar "n2") (PVar "i2")) (PVar "c2")) (PVar "ys"))) (EMatch (EApp (EApp (EVar "stringCompare") (EVar "n1")) (EVar "n2")) (arm (PCon "Lt") () (EBinOp "::" (ETuple (ETuple (EVar "n1") (EVar "i1")) (EVar "c1")) (EApp (EApp (EVar "lgMergeName") (EVar "xs")) (EBinOp "::" (ETuple (ETuple (EVar "n2") (EVar "i2")) (EVar "c2")) (EVar "ys"))))) (arm (PCon "Gt") () (EBinOp "::" (ETuple (ETuple (EVar "n2") (EVar "i2")) (EVar "c2")) (EApp (EApp (EVar "lgMergeName") (EBinOp "::" (ETuple (ETuple (EVar "n1") (EVar "i1")) (EVar "c1")) (EVar "xs"))) (EVar "ys")))) (arm (PCon "Eq") () (EIf (EBinOp "<=" (EVar "i1") (EVar "i2")) (EBinOp "::" (ETuple (ETuple (EVar "n1") (EVar "i1")) (EVar "c1")) (EApp (EApp (EVar "lgMergeName") (EVar "xs")) (EBinOp "::" (ETuple (ETuple (EVar "n2") (EVar "i2")) (EVar "c2")) (EVar "ys")))) (EBinOp "::" (ETuple (ETuple (EVar "n2") (EVar "i2")) (EVar "c2")) (EApp (EApp (EVar "lgMergeName") (EBinOp "::" (ETuple (ETuple (EVar "n1") (EVar "i1")) (EVar "c1")) (EVar "xs"))) (EVar "ys")))))))
(DTypeSig false "lgRuns" (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "Int")) (TyCon "CClause"))) (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "CClause"))))))
(DFunDef false "lgRuns" ((PList)) (EListLit))
(DFunDef false "lgRuns" ((PCons (PTuple (PTuple (PVar "n") (PVar "i")) (PVar "c")) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "cs") (PVar "others")) (EApp (EApp (EVar "lgSpan") (EVar "n")) (EVar "rest"))) (DoExpr (EBinOp "::" (ETuple (ETuple (EVar "n") (EVar "i")) (EBinOp "::" (EVar "c") (EVar "cs"))) (EApp (EVar "lgRuns") (EVar "others"))))))
(DTypeSig false "lgSpan" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "Int")) (TyCon "CClause"))) (TyTuple (TyApp (TyCon "List") (TyCon "CClause")) (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "Int")) (TyCon "CClause")))))))
(DFunDef false "lgSpan" (PWild (PList)) (ETuple (EListLit) (EListLit)))
(DFunDef false "lgSpan" ((PVar "n") (PCons (PTuple (PTuple (PVar "m") (PVar "j")) (PVar "c")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "m") (EVar "n")) (EBlock (DoLet false false (PTuple (PVar "cs") (PVar "o")) (EApp (EApp (EVar "lgSpan") (EVar "n")) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EVar "c") (EVar "cs")) (EVar "o")))) (ETuple (EListLit) (EBinOp "::" (ETuple (ETuple (EVar "m") (EVar "j")) (EVar "c")) (EVar "rest")))))
(DTypeSig false "lgSortIdx" (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "CClause")))) (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "CClause"))))))
(DFunDef false "lgSortIdx" ((PList)) (EListLit))
(DFunDef false "lgSortIdx" ((PList (PVar "x"))) (EListLit (EVar "x")))
(DFunDef false "lgSortIdx" ((PVar "xs")) (EBlock (DoLet false false (PTuple (PVar "a") (PVar "b")) (EApp (EVar "lgSplit") (EVar "xs"))) (DoExpr (EApp (EApp (EVar "lgMergeIdx") (EApp (EVar "lgSortIdx") (EVar "a"))) (EApp (EVar "lgSortIdx") (EVar "b"))))))
(DTypeSig false "lgMergeIdx" (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "CClause")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "CClause")))) (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "CClause")))))))
(DFunDef false "lgMergeIdx" ((PList) (PVar "ys")) (EVar "ys"))
(DFunDef false "lgMergeIdx" ((PVar "xs") (PList)) (EVar "xs"))
(DFunDef false "lgMergeIdx" ((PCons (PTuple (PTuple (PVar "n1") (PVar "i1")) (PVar "cs1")) (PVar "xs")) (PCons (PTuple (PTuple (PVar "n2") (PVar "i2")) (PVar "cs2")) (PVar "ys"))) (EIf (EBinOp "<=" (EVar "i1") (EVar "i2")) (EBinOp "::" (ETuple (ETuple (EVar "n1") (EVar "i1")) (EVar "cs1")) (EApp (EApp (EVar "lgMergeIdx") (EVar "xs")) (EBinOp "::" (ETuple (ETuple (EVar "n2") (EVar "i2")) (EVar "cs2")) (EVar "ys")))) (EBinOp "::" (ETuple (ETuple (EVar "n2") (EVar "i2")) (EVar "cs2")) (EApp (EApp (EVar "lgMergeIdx") (EBinOp "::" (ETuple (ETuple (EVar "n1") (EVar "i1")) (EVar "cs1")) (EVar "xs"))) (EVar "ys")))))
(DTypeSig false "lgToBind" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Loc")) (TyFun (TyTuple (TyTuple (TyCon "String") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "CClause"))) (TyCon "CBind"))))
(DFunDef false "lgToBind" ((PVar "sites") (PTuple (PTuple (PVar "n") PWild) (PVar "cs"))) (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "sites")) (arm (PCon "Some" (PVar "site")) () (EApp (EApp (EApp (EVar "CBind") (EVar "n")) (EVar "cs")) (EVar "site"))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "CBind") (EVar "n")) (EVar "cs")) (EVar "noDeclLoc")))))
(DTypeSig false "bindSites" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Loc")) (TyApp (TyCon "OrdMap") (TyCon "Loc")))))
(DFunDef false "bindSites" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "bindSites" ((PCons (PCon "DFunDef" PWild (PVar "n") PWild PWild (PVar "site")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "bindSites") (EVar "rest")) (EApp (EApp (EApp (EVar "firstSite") (EVar "n")) (EVar "site")) (EVar "acc"))))
(DFunDef false "bindSites" ((PCons (PCon "DLetGroup" PWild (PVar "binds")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "bindSites") (EVar "rest")) (EApp (EApp (EVar "letBindSites") (EVar "binds")) (EVar "acc"))))
(DFunDef false "bindSites" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "bindSites") (EBinOp "::" (EVar "d") (EVar "rest"))) (EVar "acc")))
(DFunDef false "bindSites" ((PCons PWild (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "bindSites") (EVar "rest")) (EVar "acc")))
(DTypeSig false "letBindSites" (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Loc")) (TyApp (TyCon "OrdMap") (TyCon "Loc")))))
(DFunDef false "letBindSites" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "letBindSites" ((PCons (PCon "LetBind" (PVar "n") PWild (PVar "site")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "letBindSites") (EVar "rest")) (EApp (EApp (EApp (EVar "firstSite") (EVar "n")) (EVar "site")) (EVar "acc"))))
(DTypeSig false "firstSite" (TyFun (TyCon "String") (TyFun (TyCon "Loc") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Loc")) (TyApp (TyCon "OrdMap") (TyCon "Loc"))))))
(DFunDef false "firstSite" ((PVar "n") (PVar "site") (PVar "acc")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "acc")) (EVar "acc") (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (EVar "site")) (EVar "acc"))))
(DTypeSig true "ifaceImplHeadTable" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String") (TyCon "String")))))
(DFunDef false "ifaceImplHeadTable" ((PVar "prog")) (EApp (EApp (EVar "flatMap") (EVar "ifaceImplHeadEntries")) (EVar "prog")))
(DTypeSig false "ifaceImplHeadEntries" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String") (TyCon "String")))))
(DFunDef false "ifaceImplHeadEntries" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "ifaceImplHeadEntries") (EVar "d")))
(DFunDef false "ifaceImplHeadEntries" ((PRec "DImpl" ((rf "iface" (PVar "ifaceName")) (rf "implOrigin" (PVar "o")) (rf "tys" (PVar "typeArgs"))) true)) (EListLit (ETuple (EApp (EApp (EVar "ifaceIdentity") (EVar "o")) (EVar "ifaceName")) (EVar "ifaceName") (EApp (EApp (EVar "optionOr") (EVar "noneHeadTag")) (EApp (EVar "headTyconHead") (EVar "typeArgs"))) (EApp (EApp (EApp (EApp (EVar "implRouteKeyWord") (EVar "o")) (EVar "ifaceName")) (EVar "typeArgs")) (EVar "None")))))
(DFunDef false "ifaceImplHeadEntries" (PWild) (EListLit))
(DTypeSig false "implSymbolCollisionGuard" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Unit")))
(DFunDef false "implSymbolCollisionGuard" ((PVar "prog")) (EBlock (DoLet false false (PVar "rows") (EApp (EApp (EVar "dedupImplSymRows") (EApp (EApp (EVar "flatMap") (EVar "implSymRowsOf")) (EVar "prog"))) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EApp (EVar "checkImplSymbolsInjective") (EApp (EApp (EApp (EVar "collidingHeads") (EVar "rows")) (EVar "omEmpty")) (EVar "omEmpty"))) (EVar "rows")) (EVar "omEmpty")))))
(DTypeSig false "implSymRowsOf" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String")))))
(DFunDef false "implSymRowsOf" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "implSymRowsOf") (EVar "d")))
(DFunDef false "implSymRowsOf" ((PRec "DImpl" ((rf "iface" (PVar "ifaceName")) (rf "implOrigin" (PVar "o")) (rf "tys" (PVar "typeArgs")) (rf "methods" None)) true)) (EApp (EApp (EVar "map") (EApp (EApp (EVar "implSymRow") (EApp (EApp (EVar "optionOr") (EVar "noneHeadTag")) (EApp (EVar "headTyconHead") (EVar "typeArgs")))) (EApp (EApp (EApp (EApp (EVar "implRouteKeyWord") (EVar "o")) (EVar "ifaceName")) (EVar "typeArgs")) (EVar "None")))) (EVar "methods")))
(DFunDef false "implSymRowsOf" (PWild) (EListLit))
(DTypeSig false "implSymRow" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "ImplMethod") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String"))))))
(DFunDef false "implSymRow" ((PVar "tag") (PVar "key") (PCon "ImplMethod" (PVar "mname") PWild PWild)) (ETuple (EVar "mname") (EVar "tag") (EVar "key")))
(DTypeSig false "dedupImplSymRows" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String"))))))
(DFunDef false "dedupImplSymRows" ((PList) PWild) (EListLit))
(DFunDef false "dedupImplSymRows" ((PCons (PTuple (PVar "m") (PVar "tag") (PVar "key")) (PVar "rest")) (PVar "seen")) (EIf (EApp (EApp (EVar "omHasKey") (EApp (EApp (EApp (EVar "implPreImageKey") (EVar "m")) (EVar "tag")) (EVar "key"))) (EVar "seen")) (EApp (EApp (EVar "dedupImplSymRows") (EVar "rest")) (EVar "seen")) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "m") (EVar "tag") (EVar "key")) (EApp (EApp (EVar "dedupImplSymRows") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EApp (EApp (EApp (EVar "implPreImageKey") (EVar "m")) (EVar "tag")) (EVar "key"))) (ELit LUnit)) (EVar "seen")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "implPreImageKey" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "implPreImageKey" ((PVar "m") (PVar "tag") (PVar "key")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "m"))) (ELit (LString "\n"))) (EApp (EVar "display") (EVar "tag"))) (ELit (LString "\n"))) (EApp (EVar "display") (EVar "key"))) (ELit (LString ""))))
(DTypeSig false "collidingHeads" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit"))))))
(DFunDef false "collidingHeads" ((PList) PWild (PVar "acc")) (EVar "acc"))
(DFunDef false "collidingHeads" ((PCons (PTuple (PVar "m") (PVar "tag") (PVar "key")) (PVar "rest")) (PVar "firstKey") (PVar "acc")) (EMatch (EApp (EApp (EVar "omLookup") (EApp (EApp (EVar "implHeadKey") (EVar "m")) (EVar "tag"))) (EVar "firstKey")) (arm (PCon "None") () (EApp (EApp (EApp (EVar "collidingHeads") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EApp (EApp (EVar "implHeadKey") (EVar "m")) (EVar "tag"))) (EVar "key")) (EVar "firstKey"))) (EVar "acc"))) (arm (PCon "Some" (PVar "k0")) () (EIf (EBinOp "==" (EVar "k0") (EVar "key")) (EApp (EApp (EApp (EVar "collidingHeads") (EVar "rest")) (EVar "firstKey")) (EVar "acc")) (EApp (EApp (EApp (EVar "collidingHeads") (EVar "rest")) (EVar "firstKey")) (EApp (EApp (EApp (EVar "omInsert") (EApp (EApp (EVar "implHeadKey") (EVar "m")) (EVar "tag"))) (ELit LUnit)) (EVar "acc")))))))
(DTypeSig false "implHeadKey" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "implHeadKey" ((PVar "m") (PVar "tag")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "m"))) (ELit (LString "\n"))) (EApp (EVar "display") (EVar "tag"))) (ELit (LString ""))))
(DTypeSig false "checkImplSymbolsInjective" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyCon "Unit")))))
(DFunDef false "checkImplSymbolsInjective" (PWild (PList) PWild) (ELit LUnit))
(DFunDef false "checkImplSymbolsInjective" ((PVar "collide") (PCons (PTuple (PVar "m") (PVar "tag") (PVar "key")) (PVar "rest")) (PVar "seen")) (EBlock (DoLet false false (PVar "sym") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "mdk_impl_")) (EApp (EVar "display") (EApp (EApp (EApp (EApp (EVar "implSymTagOf") (EVar "collide")) (EVar "m")) (EVar "tag")) (EVar "key")))) (ELit (LString "_"))) (EApp (EVar "display") (EVar "m"))) (ELit (LString "")))) (DoExpr (EMatch (EApp (EApp (EVar "omLookup") (EVar "sym")) (EVar "seen")) (arm (PCon "None") () (EApp (EApp (EApp (EVar "checkImplSymbolsInjective") (EVar "collide")) (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "sym")) (EVar "key")) (EVar "seen")))) (arm (PCon "Some" (PVar "prev")) () (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "emitted impl-symbol collision: two DISTINCT impls of method `")) (EApp (EVar "display") (EVar "m"))) (ELit (LString "` are emitted under one symbol.\ncollided symbol: "))) (EApp (EVar "display") (EVar "sym"))) (ELit (LString "\nimpl 1 key: "))) (EApp (EVar "display") (EVar "prev"))) (ELit (LString "\nimpl 2 key: "))) (EApp (EVar "display") (EVar "key"))) (ELit (LString "\nTwo distinct impls cannot share one emitted symbol: the backend would define one body twice (the native link fails) or keep one and silently drop the other. The two keys above are the impls' canonical dispatch keys, spelled `<module>::<Interface>|<type arguments>|`. Since #1950 those keys are spelled into the symbol by `private_mangle.injectiveIdent`, which is INJECTIVE, so this is NOT a naming mistake you can rename your way out of -- it means the emitted-symbol scheme itself lost injectivity. Please report this message, with both keys above.")))))))))
(DTypeSig false "implSymTagOf" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))))
(DFunDef false "implSymTagOf" ((PVar "collide") (PVar "method") (PVar "tag") (PVar "key")) (EIf (EApp (EApp (EVar "omHasKey") (EApp (EApp (EVar "implHeadKey") (EVar "method")) (EVar "tag"))) (EVar "collide")) (EApp (EVar "injectiveIdent") (EVar "key")) (EApp (EVar "injectiveIdent") (EVar "tag"))))
(DTypeSig false "dictWitnessTagGuard" (TyFun (TyCon "EmitTarget") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Unit"))))
(DFunDef false "dictWitnessTagGuard" ((PVar "target") (PVar "prog")) (EBlock (DoLet false false (PVar "rows") (EApp (EApp (EVar "dedupRouteWords") (EApp (EApp (EVar "flatMap") (EVar "dictRouteWordsOf")) (EVar "prog"))) (EVar "omEmpty"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "checkDictTagsInjective") (EVar "nativeDictTagSpace")) (EVar "hashName")) (EVar "rows")) (EVar "omEmpty"))) (DoExpr (EMatch (EVar "target") (arm (PCon "TargetNative") () (ELit LUnit)) (arm PWild () (EApp (EApp (EApp (EApp (EVar "checkDictTagsInjective") (EVar "wasmDictTagSpace")) (EVar "dictTag")) (EVar "rows")) (EVar "omEmpty")))))))
(DTypeSig false "nativeDictTagSpace" (TyCon "String"))
(DFunDef false "nativeDictTagSpace" () (ELit (LString "native (LLVM) i64 dict-witness word `hashName` -- BOTH backends, since the wasm tag is this hash masked")))
(DTypeSig false "wasmDictTagSpace" (TyCon "String"))
(DFunDef false "wasmDictTagSpace" () (ELit (LString "wasm (WasmGC) 30-bit i31 dict tag `dictTag` (`hashName` masked to the low 30 bits) -- the full i64 tags are DISTINCT, so native codegen would be correct here; refused anyway because a wasm-target build cannot rule out this narrower width")))
(DTypeSig false "dictRouteWordsOf" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String")))))
(DFunDef false "dictRouteWordsOf" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "dictRouteWordsOf") (EVar "d")))
(DFunDef false "dictRouteWordsOf" ((PRec "DImpl" ((rf "iface" (PVar "ifaceName")) (rf "implOrigin" (PVar "o")) (rf "tys" (PVar "typeArgs")) (rf "methods" None)) true)) (EBlock (DoLet false false (PVar "key") (EApp (EApp (EApp (EApp (EVar "implRouteKeyWord") (EVar "o")) (EVar "ifaceName")) (EVar "typeArgs")) (EVar "None"))) (DoExpr (EApp (EApp (EVar "map") (EApp (EVar "dictRouteWordRowFor") (EVar "key"))) (EVar "methods")))))
(DFunDef false "dictRouteWordsOf" (PWild) (EListLit))
(DTypeSig false "dictRouteWordRowFor" (TyFun (TyCon "String") (TyFun (TyCon "ImplMethod") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String")))))
(DFunDef false "dictRouteWordRowFor" ((PVar "key") (PCon "ImplMethod" (PVar "mname") PWild PWild)) (ETuple (EVar "mname") (EVar "key") (EVar "key")))
(DTypeSig false "dedupRouteWords" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String"))))))
(DFunDef false "dedupRouteWords" ((PList) PWild) (EListLit))
(DFunDef false "dedupRouteWords" ((PCons (PTuple (PVar "m") (PVar "w") (PVar "owner")) (PVar "rest")) (PVar "seen")) (EIf (EApp (EApp (EVar "omHasKey") (EApp (EApp (EVar "dictRouteWordKey") (EVar "m")) (EVar "w"))) (EVar "seen")) (EApp (EApp (EVar "dedupRouteWords") (EVar "rest")) (EVar "seen")) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "m") (EVar "w") (EVar "owner")) (EApp (EApp (EVar "dedupRouteWords") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EApp (EApp (EVar "dictRouteWordKey") (EVar "m")) (EVar "w"))) (ELit LUnit)) (EVar "seen")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "dictRouteWordKey" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "dictRouteWordKey" ((PVar "m") (PVar "w")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "m"))) (ELit (LString "\n"))) (EApp (EVar "display") (EVar "w"))) (ELit (LString ""))))
(DTypeSig false "checkDictTagsInjective" (TyFun (TyCon "String") (TyFun (TyFun (TyCon "String") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "OrdMap") (TyTuple (TyCon "String") (TyCon "String"))) (TyCon "Unit"))))))
(DFunDef false "checkDictTagsInjective" (PWild PWild (PList) PWild) (ELit LUnit))
(DFunDef false "checkDictTagsInjective" ((PVar "space") (PVar "hash") (PCons (PTuple (PVar "m") (PVar "w") (PVar "owner")) (PVar "rest")) (PVar "seen")) (EBlock (DoLet false false (PVar "t") (EApp (EVar "intToString") (EApp (EVar "hash") (EVar "w")))) (DoLet false false (PVar "k") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "m"))) (ELit (LString "\n"))) (EApp (EVar "display") (EVar "t"))) (ELit (LString "")))) (DoExpr (EMatch (EApp (EApp (EVar "omLookup") (EVar "k")) (EVar "seen")) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "checkDictTagsInjective") (EVar "space")) (EVar "hash")) (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "k")) (ETuple (EVar "w") (EVar "owner"))) (EVar "seen")))) (arm (PCon "Some" (PTuple (PVar "w0") (PVar "owner0"))) () (EIf (EBinOp "==" (EVar "owner0") (EVar "owner")) (EApp (EApp (EApp (EApp (EVar "checkDictTagsInjective") (EVar "space")) (EVar "hash")) (EVar "rest")) (EVar "seen")) (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "emitted dict-witness tag collision: two DISTINCT impls of method `")) (EApp (EVar "display") (EVar "m"))) (ELit (LString "` hash to one dispatch tag.\ntag space: "))) (EApp (EVar "display") (EVar "space"))) (ELit (LString "\ncollided tag: "))) (EApp (EVar "display") (EVar "t"))) (ELit (LString "\nroute word 1: "))) (EApp (EVar "display") (EVar "w0"))) (ELit (LString "\nroute word 2: "))) (EApp (EVar "display") (EVar "w"))) (ELit (LString "\nA dict witness carries this tag, and method `"))) (EApp (EVar "display") (EVar "m"))) (ELit (LString "`'s shared dispatcher selects an impl by comparing it against every OTHER impl of that SAME method name -- these two words ARE compared against each other at that dispatcher, so this collision is live: whichever arm the emitter happened to emit FIRST wins every call through a dictionary, silently, at exit 0. The two words above are the impls' route words: either a bare head tycon or a canonical dispatch key spelled `<module>::<Interface>|<type arguments>|`. This is NOT a naming collision you can rename your way out of by making the names more different -- `hashName` is djb2, a radix-33 polynomial over a 74-code-point alphabet, so it is genuinely non-injective (`hashName \"Az\" == hashName \"BY\"`). One of the two words above may name a type or interface from the prelude or stdlib that you do not own -- rename the OTHER one, one of your own types or interfaces involved in this collision. Please also report this message, with both words above."))))))))))
(DTypeSig true "lowerImplsWith" (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Int")))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyApp (TyCon "Option") (TyCon "DispositionTable")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "CImplEntry")))))))
(DFunDef false "lowerImplsWith" ((PVar "disp") (PVar "reqCounts") (PVar "dispositions") (PVar "prog")) (EApp (EApp (EVar "map") (EApp (EVar "refoldImpl") (EVar "noLetCheck"))) (EApp (EApp (EApp (EApp (EVar "lowerImplsRaw") (EVar "disp")) (EVar "reqCounts")) (EVar "dispositions")) (EVar "prog"))))
(DTypeSig false "lowerImplsRaw" (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Int")))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyApp (TyCon "Option") (TyCon "DispositionTable")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "CImplEntry")))))))
(DFunDef false "lowerImplsRaw" ((PVar "disp") (PVar "reqCounts") (PVar "dispositions") (PVar "prog")) (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EVar "lowerDeclImpl") (EVar "disp")) (EVar "reqCounts")) (EVar "dispositions"))) (EVar "prog")))
(DTypeSig false "lowerDeclImpl" (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Int")))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyApp (TyCon "Option") (TyCon "DispositionTable")) (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "CImplEntry")))))))
(DFunDef false "lowerDeclImpl" ((PVar "disp") (PVar "reqCounts") (PVar "dt") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EApp (EApp (EVar "lowerDeclImpl") (EVar "disp")) (EVar "reqCounts")) (EVar "dt")) (EVar "d")))
(DFunDef false "lowerDeclImpl" ((PVar "disp") PWild PWild (PRec "DImpl" ((rf "iface" (PVar "ifaceName")) (rf "implOrigin" (PVar "o")) (rf "tys" (PVar "typeArgs")) (rf "methods" None)) true)) (EApp (EApp (EVar "map") (EApp (EApp (EApp (EApp (EVar "lowerImplMethod") (EVar "disp")) (EVar "o")) (EVar "ifaceName")) (EVar "typeArgs"))) (EVar "methods")))
(DFunDef false "lowerDeclImpl" ((PVar "disp") (PVar "reqCounts") (PCon "Some" (PVar "dt")) (PRec "DInterface" ((rf "name" (PVar "ifaceName")) (rf "ifaceOrigin" (PVar "o")) (rf "methods" None)) true)) (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EApp (EApp (EVar "lowerInheritedDefault") (EVar "disp")) (EVar "reqCounts")) (EVar "dt")) (EVar "o")) (EVar "ifaceName"))) (EVar "methods")))
(DFunDef false "lowerDeclImpl" (PWild PWild PWild PWild) (EListLit))
(DTypeSig false "lowerImplMethod" (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Int")))) (TyFun (TyCon "TyConOrigin") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyCon "ImplMethod") (TyCon "CImplEntry")))))))
(DFunDef false "lowerImplMethod" ((PVar "disp") (PVar "o") (PVar "ifaceName") (PVar "typeArgs") (PCon "ImplMethod" (PVar "mname") (PVar "pats") (PVar "body"))) (EBlock (DoLet false false (PVar "tag") (EApp (EApp (EVar "optionOr") (EVar "noneHeadTag")) (EApp (EVar "headTyconHead") (EVar "typeArgs")))) (DoLet false false (PVar "key") (EApp (EApp (EApp (EApp (EVar "implRouteKeyWord") (EVar "o")) (EVar "ifaceName")) (EVar "typeArgs")) (EVar "None"))) (DoLet false false (PVar "positions") (EApp (EApp (EApp (EApp (EVar "lookupPositions") (EApp (EApp (EVar "ifaceIdentity") (EVar "o")) (EVar "ifaceName"))) (EVar "ifaceName")) (EVar "mname")) (EVar "disp"))) (DoExpr (EApp (EApp (EApp (EVar "CImplEntry") (EVar "mname")) (EApp (EVar "tyvarsInArgs") (EVar "typeArgs"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "CImplTagged") (EVar "tag")) (EVar "key")) (EVar "ifaceName")) (EVar "positions")) (EVar "pats")) (EApp (EVar "lower") (EVar "body")))))))
(DTypeSig false "lowerInheritedDefault" (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Int")))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "DispositionTable") (TyFun (TyCon "TyConOrigin") (TyFun (TyCon "String") (TyFun (TyCon "IfaceMethod") (TyApp (TyCon "List") (TyCon "CImplEntry")))))))))
(DFunDef false "lowerInheritedDefault" (PWild PWild PWild PWild PWild (PCon "IfaceMethod" PWild PWild (PCon "None") PWild)) (EListLit))
(DFunDef false "lowerInheritedDefault" ((PVar "disp") (PVar "reqCounts") (PVar "dt") (PVar "o") (PVar "ifaceName") (PCon "IfaceMethod" (PVar "mname") PWild (PCon "Some" (PCon "MethodDefault" (PVar "pats") (PVar "body"))) PWild)) (EBlock (DoLet false false (PVar "ifaceWord") (EApp (EApp (EVar "ifaceWordOf") (EVar "o")) (EVar "ifaceName"))) (DoLet false false (PVar "positions") (EApp (EApp (EApp (EApp (EVar "lookupPositions") (EApp (EApp (EVar "ifaceIdentity") (EVar "o")) (EVar "ifaceName"))) (EVar "ifaceName")) (EVar "mname")) (EVar "disp"))) (DoLet false false (PVar "nMethodDicts") (EApp (EVar "leadingDictParams") (EVar "pats"))) (DoLet false false (PVar "receiver") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "$dict_")) (EApp (EVar "display") (EVar "mname"))) (ELit (LString "_"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "nMethodDicts")))) (ELit (LString "")))) (DoLet false false (PVar "params") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "take") (EVar "nMethodDicts")) (EVar "pats")) (EListLit (EApp (EApp (EVar "PVar") (EVar "receiver")) (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString ""))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0)))))) (EApp (EApp (EVar "drop") (EVar "nMethodDicts")) (EVar "pats"))) (EApp (EVar "lamParams") (EVar "body")))) (DoLet false false (PVar "lowered") (EApp (EVar "lower") (EApp (EVar "underLam") (EVar "body")))) (DoLet false false (PVar "spec") (ELam ((PVar "shape")) (ERecordCreate "DefaultRow" ((fa "drSelf" (EApp (EVar "defaultReceiverDict") (EVar "mname"))) (fa "drReceiver" (EVar "receiver")) (fa "drIface" (EVar "ifaceWord")) (fa "drWord" (EFieldAccess (EVar "shape") "isWord")) (fa "drSupers" (EApp (EApp (EApp (EVar "receiverFields") (EVar "receiver")) (ELit (LInt 0))) (EApp (EApp (EVar "ifaceSuperCount") (EVar "ifaceWord")) (EVar "dt")))) (fa "drReqs" (EApp (EApp (EApp (EVar "receiverFields") (EVar "receiver")) (EApp (EApp (EVar "ifaceSuperCount") (EVar "ifaceWord")) (EVar "dt"))) (EApp (EApp (EVar "optionOr") (ELit (LInt 0))) (EApp (EApp (EVar "omLookup") (EFieldAccess (EVar "shape") "isWord")) (EVar "reqCounts"))))))))) (DoExpr (EApp (EApp (EVar "map") (ELam ((PVar "shape")) (EApp (EApp (EApp (EVar "CImplEntry") (EVar "mname")) (EApp (EVar "tyvarsInArgs") (EFieldAccess (EVar "shape") "isTys"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "CImplDefault") (EVar "ifaceWord")) (EApp (EApp (EVar "optionOr") (EVar "noneHeadTag")) (EApp (EVar "headTyconHead") (EFieldAccess (EVar "shape") "isTys")))) (EFieldAccess (EVar "shape") "isWord")) (EVar "positions")) (EVar "params")) (EApp (EApp (EVar "specializeRow") (EApp (EVar "spec") (EVar "shape"))) (EVar "lowered")))))) (EApp (EApp (EApp (EVar "inheritorsOf") (EVar "ifaceWord")) (EVar "mname")) (EVar "dt"))))))
(DData Private "DefaultRow" () ((variant "DefaultRow" (ConNamed (field "drSelf" (TyCon "String")) (field "drReceiver" (TyCon "String")) (field "drIface" (TyCon "String")) (field "drWord" (TyCon "String")) (field "drSupers" (TyApp (TyCon "List") (TyCon "Route"))) (field "drReqs" (TyApp (TyCon "List") (TyCon "Route")))))) ())
(DTypeSig false "receiverFields" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Route"))))))
(DFunDef false "receiverFields" ((PVar "recv") (PVar "from") (PVar "n")) (EApp (EApp (EVar "map") (ELam ((PVar "i")) (EApp (EApp (EVar "RProj") (EApp (EVar "RDict") (EVar "recv"))) (EListLit (EVar "i"))))) (EApp (EApp (EVar "range") (EVar "from")) (EBinOp "+" (EVar "from") (EVar "n")))))
(DTypeSig false "specializeRow" (TyFun (TyCon "DefaultRow") (TyFun (TyCon "CExpr") (TyCon "CExpr"))))
(DFunDef false "specializeRow" ((PVar "row") (PCon "CMethod" (PVar "name") (PVar "iface") (PVar "arity") (PVar "route") (PVar "implRoutes") (PVar "methRoutes"))) (EIf (EBinOp "&&" (EBinOp "==" (EVar "iface") (EFieldAccess (EVar "row") "drIface")) (EApp (EApp (EVar "isReceiverRoute") (EVar "row")) (EVar "route"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "CMethod") (EVar "name")) (EVar "iface")) (EVar "arity")) (EApp (EApp (EApp (EVar "RKey") (EFieldAccess (EVar "row") "drWord")) (EListLit)) (EFieldAccess (EVar "row") "drSupers"))) (EFieldAccess (EVar "row") "drReqs")) (EApp (EApp (EVar "map") (EApp (EVar "renameReceiver") (EVar "row"))) (EVar "methRoutes"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "CMethod") (EVar "name")) (EVar "iface")) (EVar "arity")) (EApp (EApp (EVar "renameReceiver") (EVar "row")) (EVar "route"))) (EApp (EApp (EVar "map") (EApp (EVar "renameReceiver") (EVar "row"))) (EVar "implRoutes"))) (EApp (EApp (EVar "map") (EApp (EVar "renameReceiver") (EVar "row"))) (EVar "methRoutes")))))
(DFunDef false "specializeRow" ((PVar "row") (PCon "CDict" (PVar "name") (PVar "routes"))) (EApp (EApp (EVar "CDict") (EVar "name")) (EApp (EApp (EVar "map") (EApp (EVar "renameReceiver") (EVar "row"))) (EVar "routes"))))
(DFunDef false "specializeRow" ((PVar "row") (PCon "CVar" (PVar "x") (PVar "addr"))) (EIf (EBinOp "==" (EVar "x") (EFieldAccess (EVar "row") "drSelf")) (EApp (EApp (EVar "CVar") (EFieldAccess (EVar "row") "drReceiver")) (EVar "addr")) (EApp (EApp (EVar "CVar") (EVar "x")) (EVar "addr"))))
(DFunDef false "specializeRow" (PWild (PCon "CLit" (PVar "l"))) (EApp (EVar "CLit") (EVar "l")))
(DFunDef false "specializeRow" ((PVar "row") (PCon "CApp" (PVar "f") (PVar "x"))) (EApp (EApp (EVar "CApp") (EApp (EApp (EVar "specializeRow") (EVar "row")) (EVar "f"))) (EApp (EApp (EVar "specializeRow") (EVar "row")) (EVar "x"))))
(DFunDef false "specializeRow" ((PVar "row") (PCon "CLam" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "CLam") (EVar "pats")) (EApp (EApp (EVar "specializeRow") (EVar "row")) (EVar "body"))))
(DFunDef false "specializeRow" ((PVar "row") (PCon "CLet" (PVar "r") (PVar "pat") (PVar "e1") (PVar "e2"))) (EApp (EApp (EApp (EApp (EVar "CLet") (EVar "r")) (EVar "pat")) (EApp (EApp (EVar "specializeRow") (EVar "row")) (EVar "e1"))) (EApp (EApp (EVar "specializeRow") (EVar "row")) (EVar "e2"))))
(DFunDef false "specializeRow" ((PVar "row") (PCon "CLetGroup" (PVar "binds") (PVar "body"))) (EApp (EApp (EVar "CLetGroup") (EApp (EApp (EVar "map") (EApp (EVar "specializeBind") (EVar "row"))) (EVar "binds"))) (EApp (EApp (EVar "specializeRow") (EVar "row")) (EVar "body"))))
(DFunDef false "specializeRow" ((PVar "row") (PCon "CMatch" (PVar "scrut") (PVar "arms"))) (EApp (EApp (EVar "CMatch") (EApp (EApp (EVar "specializeRow") (EVar "row")) (EVar "scrut"))) (EApp (EApp (EVar "map") (EApp (EVar "specializeArm") (EVar "row"))) (EVar "arms"))))
(DFunDef false "specializeRow" ((PVar "row") (PCon "CDecision" (PVar "scrut") (PVar "arms") (PVar "tree"))) (EApp (EApp (EApp (EVar "CDecision") (EApp (EApp (EVar "specializeRow") (EVar "row")) (EVar "scrut"))) (EApp (EApp (EVar "map") (EApp (EVar "specializeArm") (EVar "row"))) (EVar "arms"))) (EVar "tree")))
(DFunDef false "specializeRow" ((PVar "row") (PCon "CIf" (PVar "c") (PVar "t") (PVar "e"))) (EApp (EApp (EApp (EVar "CIf") (EApp (EApp (EVar "specializeRow") (EVar "row")) (EVar "c"))) (EApp (EApp (EVar "specializeRow") (EVar "row")) (EVar "t"))) (EApp (EApp (EVar "specializeRow") (EVar "row")) (EVar "e"))))
(DFunDef false "specializeRow" ((PVar "row") (PCon "CBinPrim" (PVar "op") (PVar "l") (PVar "r") (PVar "tag") (PVar "site"))) (EApp (EApp (EApp (EApp (EApp (EVar "CBinPrim") (EVar "op")) (EApp (EApp (EVar "specializeRow") (EVar "row")) (EVar "l"))) (EApp (EApp (EVar "specializeRow") (EVar "row")) (EVar "r"))) (EVar "tag")) (EVar "site")))
(DFunDef false "specializeRow" ((PVar "row") (PCon "CUnOp" (PVar "op") (PVar "x"))) (EApp (EApp (EVar "CUnOp") (EVar "op")) (EApp (EApp (EVar "specializeRow") (EVar "row")) (EVar "x"))))
(DFunDef false "specializeRow" ((PVar "row") (PCon "CTuple" (PVar "es"))) (EApp (EVar "CTuple") (EApp (EApp (EVar "map") (EApp (EVar "specializeRow") (EVar "row"))) (EVar "es"))))
(DFunDef false "specializeRow" ((PVar "row") (PCon "CList" (PVar "es"))) (EApp (EVar "CList") (EApp (EApp (EVar "map") (EApp (EVar "specializeRow") (EVar "row"))) (EVar "es"))))
(DFunDef false "specializeRow" ((PVar "row") (PCon "CRecord" (PVar "name") (PVar "fields"))) (EApp (EApp (EVar "CRecord") (EVar "name")) (EApp (EApp (EVar "map") (EApp (EVar "specializeField") (EVar "row"))) (EVar "fields"))))
(DFunDef false "specializeRow" ((PVar "row") (PCon "CFieldAccess" (PVar "ex") (PVar "f") (PVar "n"))) (EApp (EApp (EApp (EVar "CFieldAccess") (EApp (EApp (EVar "specializeRow") (EVar "row")) (EVar "ex"))) (EVar "f")) (EVar "n")))
(DFunDef false "specializeRow" ((PVar "row") (PCon "CRecordUpdate" (PVar "name") (PVar "base") (PVar "fields"))) (EApp (EApp (EApp (EVar "CRecordUpdate") (EVar "name")) (EApp (EApp (EVar "specializeRow") (EVar "row")) (EVar "base"))) (EApp (EApp (EVar "map") (EApp (EVar "specializeField") (EVar "row"))) (EVar "fields"))))
(DFunDef false "specializeRow" ((PVar "row") (PCon "CVariantUpdate" (PVar "con") (PVar "base") (PVar "fields"))) (EApp (EApp (EApp (EVar "CVariantUpdate") (EVar "con")) (EApp (EApp (EVar "specializeRow") (EVar "row")) (EVar "base"))) (EApp (EApp (EVar "map") (EApp (EVar "specializeField") (EVar "row"))) (EVar "fields"))))
(DFunDef false "specializeRow" ((PVar "row") (PCon "CArray" (PVar "es"))) (EApp (EVar "CArray") (EApp (EApp (EVar "map") (EApp (EVar "specializeRow") (EVar "row"))) (EVar "es"))))
(DFunDef false "specializeRow" ((PVar "row") (PCon "CRangeList" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EVar "CRangeList") (EApp (EApp (EVar "specializeRow") (EVar "row")) (EVar "lo"))) (EApp (EApp (EVar "specializeRow") (EVar "row")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "specializeRow" ((PVar "row") (PCon "CRangeArray" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EVar "CRangeArray") (EApp (EApp (EVar "specializeRow") (EVar "row")) (EVar "lo"))) (EApp (EApp (EVar "specializeRow") (EVar "row")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "specializeRow" ((PVar "row") (PCon "CIndex" (PVar "a") (PVar "i"))) (EApp (EApp (EVar "CIndex") (EApp (EApp (EVar "specializeRow") (EVar "row")) (EVar "a"))) (EApp (EApp (EVar "specializeRow") (EVar "row")) (EVar "i"))))
(DFunDef false "specializeRow" ((PVar "row") (PCon "CSlice" (PVar "a") (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EApp (EVar "CSlice") (EApp (EApp (EVar "specializeRow") (EVar "row")) (EVar "a"))) (EApp (EApp (EVar "specializeRow") (EVar "row")) (EVar "lo"))) (EApp (EApp (EVar "specializeRow") (EVar "row")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "specializeRow" ((PVar "row") (PCon "CStringIndex" (PVar "a") (PVar "i"))) (EApp (EApp (EVar "CStringIndex") (EApp (EApp (EVar "specializeRow") (EVar "row")) (EVar "a"))) (EApp (EApp (EVar "specializeRow") (EVar "row")) (EVar "i"))))
(DFunDef false "specializeRow" ((PVar "row") (PCon "CStringSlice" (PVar "a") (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EApp (EVar "CStringSlice") (EApp (EApp (EVar "specializeRow") (EVar "row")) (EVar "a"))) (EApp (EApp (EVar "specializeRow") (EVar "row")) (EVar "lo"))) (EApp (EApp (EVar "specializeRow") (EVar "row")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "specializeRow" ((PVar "row") (PCon "CListIndex" (PVar "a") (PVar "i"))) (EApp (EApp (EVar "CListIndex") (EApp (EApp (EVar "specializeRow") (EVar "row")) (EVar "a"))) (EApp (EApp (EVar "specializeRow") (EVar "row")) (EVar "i"))))
(DFunDef false "specializeRow" ((PVar "row") (PCon "CListSlice" (PVar "a") (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EApp (EVar "CListSlice") (EApp (EApp (EVar "specializeRow") (EVar "row")) (EVar "a"))) (EApp (EApp (EVar "specializeRow") (EVar "row")) (EVar "lo"))) (EApp (EApp (EVar "specializeRow") (EVar "row")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "specializeRow" ((PVar "row") (PCon "CBlock" (PVar "stmts"))) (EApp (EVar "CBlock") (EApp (EApp (EVar "map") (EApp (EVar "specializeStmt") (EVar "row"))) (EVar "stmts"))))
(DTypeSig false "specializeBind" (TyFun (TyCon "DefaultRow") (TyFun (TyCon "CBind") (TyCon "CBind"))))
(DFunDef false "specializeBind" ((PVar "row") (PCon "CBind" (PVar "n") (PVar "clauses") (PVar "site"))) (EApp (EApp (EApp (EVar "CBind") (EVar "n")) (EApp (EApp (EVar "map") (EApp (EVar "specializeClause") (EVar "row"))) (EVar "clauses"))) (EVar "site")))
(DTypeSig false "specializeClause" (TyFun (TyCon "DefaultRow") (TyFun (TyCon "CClause") (TyCon "CClause"))))
(DFunDef false "specializeClause" ((PVar "row") (PCon "CClause" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "CClause") (EVar "pats")) (EApp (EApp (EVar "specializeRow") (EVar "row")) (EVar "body"))))
(DTypeSig false "specializeArm" (TyFun (TyCon "DefaultRow") (TyFun (TyCon "CArm") (TyCon "CArm"))))
(DFunDef false "specializeArm" ((PVar "row") (PCon "CArm" (PVar "pat") (PVar "guards") (PVar "body"))) (EApp (EApp (EApp (EVar "CArm") (EVar "pat")) (EApp (EApp (EVar "map") (EApp (EVar "specializeGuard") (EVar "row"))) (EVar "guards"))) (EApp (EApp (EVar "specializeRow") (EVar "row")) (EVar "body"))))
(DTypeSig false "specializeGuard" (TyFun (TyCon "DefaultRow") (TyFun (TyCon "CGuard") (TyCon "CGuard"))))
(DFunDef false "specializeGuard" ((PVar "row") (PCon "CGBool" (PVar "e"))) (EApp (EVar "CGBool") (EApp (EApp (EVar "specializeRow") (EVar "row")) (EVar "e"))))
(DFunDef false "specializeGuard" ((PVar "row") (PCon "CGBind" (PVar "p") (PVar "e"))) (EApp (EApp (EVar "CGBind") (EVar "p")) (EApp (EApp (EVar "specializeRow") (EVar "row")) (EVar "e"))))
(DTypeSig false "specializeStmt" (TyFun (TyCon "DefaultRow") (TyFun (TyCon "CStmt") (TyCon "CStmt"))))
(DFunDef false "specializeStmt" ((PVar "row") (PCon "CSExpr" (PVar "e"))) (EApp (EVar "CSExpr") (EApp (EApp (EVar "specializeRow") (EVar "row")) (EVar "e"))))
(DFunDef false "specializeStmt" ((PVar "row") (PCon "CSLet" (PVar "r") (PVar "pat") (PVar "e"))) (EApp (EApp (EApp (EVar "CSLet") (EVar "r")) (EVar "pat")) (EApp (EApp (EVar "specializeRow") (EVar "row")) (EVar "e"))))
(DFunDef false "specializeStmt" ((PVar "row") (PCon "CSAssign" (PVar "x") (PVar "e"))) (EApp (EApp (EVar "CSAssign") (EVar "x")) (EApp (EApp (EVar "specializeRow") (EVar "row")) (EVar "e"))))
(DTypeSig false "specializeField" (TyFun (TyCon "DefaultRow") (TyFun (TyCon "CField") (TyCon "CField"))))
(DFunDef false "specializeField" ((PVar "row") (PCon "CField" (PVar "k") (PVar "e"))) (EApp (EApp (EVar "CField") (EVar "k")) (EApp (EApp (EVar "specializeRow") (EVar "row")) (EVar "e"))))
(DTypeSig false "isReceiverRoute" (TyFun (TyCon "DefaultRow") (TyFun (TyCon "Route") (TyCon "Bool"))))
(DFunDef false "isReceiverRoute" ((PVar "row") (PCon "RDict" (PVar "d"))) (EBinOp "==" (EVar "d") (EFieldAccess (EVar "row") "drSelf")))
(DFunDef false "isReceiverRoute" ((PVar "row") (PCon "RDictFwd" (PVar "d"))) (EBinOp "==" (EVar "d") (EFieldAccess (EVar "row") "drSelf")))
(DFunDef false "isReceiverRoute" (PWild PWild) (EVar "False"))
(DTypeSig false "renameReceiver" (TyFun (TyCon "DefaultRow") (TyFun (TyCon "Route") (TyCon "Route"))))
(DFunDef false "renameReceiver" ((PVar "row") (PCon "RDict" (PVar "d"))) (EApp (EVar "RDict") (EIf (EBinOp "==" (EVar "d") (EFieldAccess (EVar "row") "drSelf")) (EFieldAccess (EVar "row") "drReceiver") (EVar "d"))))
(DFunDef false "renameReceiver" ((PVar "row") (PCon "RDictFwd" (PVar "d"))) (EApp (EVar "RDictFwd") (EIf (EBinOp "==" (EVar "d") (EFieldAccess (EVar "row") "drSelf")) (EFieldAccess (EVar "row") "drReceiver") (EVar "d"))))
(DFunDef false "renameReceiver" ((PVar "row") (PCon "RKey" (PVar "k") (PVar "reqs") (PVar "sups"))) (EApp (EApp (EApp (EVar "RKey") (EVar "k")) (EApp (EApp (EVar "map") (EApp (EVar "renameReceiver") (EVar "row"))) (EVar "reqs"))) (EApp (EApp (EVar "map") (EApp (EVar "renameReceiver") (EVar "row"))) (EVar "sups"))))
(DFunDef false "renameReceiver" ((PVar "row") (PCon "RProj" (PVar "r") (PVar "path"))) (EApp (EApp (EVar "RProj") (EApp (EApp (EVar "renameReceiver") (EVar "row")) (EVar "r"))) (EVar "path")))
(DFunDef false "renameReceiver" ((PVar "row") (PCon "RLocal" (PVar "sym") (PVar "dicts"))) (EApp (EApp (EVar "RLocal") (EVar "sym")) (EApp (EApp (EVar "map") (EApp (EVar "renameReceiver") (EVar "row"))) (EVar "dicts"))))
(DFunDef false "renameReceiver" (PWild (PCon "RNone")) (EVar "RNone"))
(DFunDef false "renameReceiver" (PWild (PCon "RScalar" (PVar "t"))) (EApp (EVar "RScalar") (EVar "t")))
(DTypeSig true "instanceReqCounts" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "OrdMap") (TyCon "Int"))))
(DFunDef false "instanceReqCounts" ((PVar "decls")) (EApp (EApp (EVar "instanceReqCountsGo") (EVar "decls")) (EVar "omEmpty")))
(DTypeSig false "instanceReqCountsGo" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyApp (TyCon "OrdMap") (TyCon "Int")))))
(DFunDef false "instanceReqCountsGo" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "instanceReqCountsGo" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "instanceReqCountsGo") (EBinOp "::" (EVar "d") (EVar "rest"))) (EVar "acc")))
(DFunDef false "instanceReqCountsGo" ((PCons (PRec "DImpl" ((rf "iface" None) (rf "tys" None) (rf "reqs" None) (rf "implOrigin" None)) true) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "instanceReqCountsGo") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EApp (EApp (EApp (EApp (EVar "implRouteKeyWord") (EVar "implOrigin")) (EVar "iface")) (EVar "tys")) (EVar "None"))) (EApp (EVar "listLen") (EVar "reqs"))) (EVar "acc"))))
(DFunDef false "instanceReqCountsGo" ((PCons PWild (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "instanceReqCountsGo") (EVar "rest")) (EVar "acc")))
(DTypeSig false "lamParams" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Pat"))))
(DFunDef false "lamParams" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "lamParams") (EVar "e")))
(DFunDef false "lamParams" ((PCon "ELam" (PVar "ps") PWild)) (EVar "ps"))
(DFunDef false "lamParams" (PWild) (EListLit))
(DTypeSig false "underLam" (TyFun (TyCon "Expr") (TyCon "Expr")))
(DFunDef false "underLam" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "underLam") (EVar "e")))
(DFunDef false "underLam" ((PCon "ELam" PWild (PVar "b"))) (EVar "b"))
(DFunDef false "underLam" ((PVar "e")) (EVar "e"))
(DTypeSig false "leadingDictParams" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int")))
(DFunDef false "leadingDictParams" ((PCons (PCon "PVar" (PVar "x") PWild) (PVar "rest"))) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "$dict"))) (EVar "x")) (EBinOp "+" (ELit (LInt 1)) (EApp (EVar "leadingDictParams") (EVar "rest"))) (ELit (LInt 0))))
(DFunDef false "leadingDictParams" (PWild) (ELit (LInt 0)))
(DTypeSig true "returnsSelfTable" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyCon "Bool")))))
(DFunDef false "returnsSelfTable" ((PVar "prog")) (EApp (EApp (EVar "flatMap") (EVar "ifaceReturnsSelfEntries")) (EVar "prog")))
(DTypeSig false "ifaceReturnsSelfEntries" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyCon "Bool")))))
(DFunDef false "ifaceReturnsSelfEntries" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "ifaceReturnsSelfEntries") (EVar "d")))
(DFunDef false "ifaceReturnsSelfEntries" ((PRec "DInterface" ((rf "name" (PVar "ifaceName")) (rf "typarams" (PVar "typeParams")) (rf "methods" None)) true)) (EApp (EApp (EVar "map") (ELam ((PVar "m")) (EApp (EApp (EApp (EVar "ifaceReturnsSelfEntry") (EVar "ifaceName")) (EVar "typeParams")) (EVar "m")))) (EVar "methods")))
(DFunDef false "ifaceReturnsSelfEntries" (PWild) (EListLit))
(DTypeSig false "ifaceReturnsSelfEntry" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "IfaceMethod") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyCon "Bool"))))))
(DFunDef false "ifaceReturnsSelfEntry" ((PVar "ifaceName") (PVar "typeParams") (PCon "IfaceMethod" (PVar "mname") (PVar "mty") PWild PWild)) (ETuple (ETuple (EVar "ifaceName") (EVar "mname")) (EApp (EApp (EVar "tyMentionsParams") (EApp (EVar "methodResultTy") (EVar "mty"))) (EApp (EVar "headParamOnly") (EVar "typeParams")))))
(DTypeSig false "headParamOnly" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "headParamOnly" ((PList)) (EListLit))
(DFunDef false "headParamOnly" ((PCons (PVar "p") PWild)) (EListLit (EVar "p")))
(DTypeSig false "methodResultTy" (TyFun (TyCon "Ty") (TyCon "Ty")))
(DFunDef false "methodResultTy" ((PCon "TyConstrained" PWild (PVar "t"))) (EApp (EVar "methodResultTy") (EVar "t")))
(DFunDef false "methodResultTy" ((PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EVar "methodResultTy") (EVar "t")))
(DFunDef false "methodResultTy" ((PCon "TyFun" PWild (PVar "b"))) (EApp (EVar "methodResultTy") (EVar "b")))
(DFunDef false "methodResultTy" ((PCon "TyQual" (PVar "t") PWild PWild)) (EApp (EVar "methodResultTy") (EVar "t")))
(DFunDef false "methodResultTy" ((PVar "t")) (EVar "t"))
(DTypeSig false "tyMentionsParams" (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "tyMentionsParams" ((PCon "TyVar" (PVar "n")) (PVar "params")) (EApp (EApp (EVar "contains") (EVar "n")) (EVar "params")))
(DFunDef false "tyMentionsParams" ((PRec "TyCon" ((rf "tyConName" PWild)) false) PWild) (EVar "False"))
(DFunDef false "tyMentionsParams" ((PCon "TyApp" (PVar "a") (PVar "b")) (PVar "params")) (EBinOp "||" (EApp (EApp (EVar "tyMentionsParams") (EVar "a")) (EVar "params")) (EApp (EApp (EVar "tyMentionsParams") (EVar "b")) (EVar "params"))))
(DFunDef false "tyMentionsParams" ((PCon "TyFun" (PVar "a") (PVar "b")) (PVar "params")) (EBinOp "||" (EApp (EApp (EVar "tyMentionsParams") (EVar "a")) (EVar "params")) (EApp (EApp (EVar "tyMentionsParams") (EVar "b")) (EVar "params"))))
(DFunDef false "tyMentionsParams" ((PCon "TyTuple" (PVar "ts")) (PVar "params")) (EApp (EApp (EVar "anyList") (ELam ((PVar "t")) (EApp (EApp (EVar "tyMentionsParams") (EVar "t")) (EVar "params")))) (EVar "ts")))
(DFunDef false "tyMentionsParams" ((PCon "TyEffect" PWild PWild (PVar "t")) (PVar "params")) (EApp (EApp (EVar "tyMentionsParams") (EVar "t")) (EVar "params")))
(DFunDef false "tyMentionsParams" ((PCon "TyRow" PWild (PVar "tail") PWild) (PVar "params")) (EApp (EApp (EVar "anyList") (ELam ((PVar "v")) (EApp (EApp (EVar "contains") (EVar "v")) (EVar "params")))) (EVar "tail")))
(DFunDef false "tyMentionsParams" ((PCon "TyAuth" PWild PWild) PWild) (EVar "False"))
(DFunDef false "tyMentionsParams" ((PCon "TyConstrained" PWild (PVar "t")) (PVar "params")) (EApp (EApp (EVar "tyMentionsParams") (EVar "t")) (EVar "params")))
(DFunDef false "tyMentionsParams" ((PCon "TyNamed" PWild (PVar "t") PWild) (PVar "params")) (EApp (EApp (EVar "tyMentionsParams") (EVar "t")) (EVar "params")))
(DFunDef false "tyMentionsParams" ((PCon "TyQual" (PVar "t") PWild PWild) (PVar "params")) (EApp (EApp (EVar "tyMentionsParams") (EVar "t")) (EVar "params")))
(DTypeSig true "selfFnParamTable" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "selfFnParamTable" ((PVar "prog")) (EApp (EApp (EVar "flatMap") (EVar "ifaceSelfFnParamEntries")) (EVar "prog")))
(DTypeSig false "ifaceSelfFnParamEntries" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "ifaceSelfFnParamEntries" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "ifaceSelfFnParamEntries") (EVar "d")))
(DFunDef false "ifaceSelfFnParamEntries" ((PRec "DInterface" ((rf "name" (PVar "ifaceName")) (rf "typarams" (PVar "typeParams")) (rf "methods" None)) true)) (EApp (EApp (EVar "map") (ELam ((PVar "m")) (EApp (EApp (EApp (EVar "ifaceSelfFnParamEntry") (EVar "ifaceName")) (EVar "typeParams")) (EVar "m")))) (EVar "methods")))
(DFunDef false "ifaceSelfFnParamEntries" (PWild) (EListLit))
(DTypeSig false "ifaceSelfFnParamEntry" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "IfaceMethod") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Int")))))))
(DFunDef false "ifaceSelfFnParamEntry" ((PVar "ifaceName") (PVar "typeParams") (PCon "IfaceMethod" (PVar "mname") (PVar "mty") PWild PWild)) (ETuple (ETuple (EVar "ifaceName") (EVar "mname")) (EApp (EApp (EApp (EVar "selfFnPositions") (ELit (LInt 0))) (EApp (EVar "methodArgTys") (EVar "mty"))) (EVar "typeParams"))))
(DTypeSig false "methodArgTys" (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyCon "Ty"))))
(DFunDef false "methodArgTys" ((PCon "TyConstrained" PWild (PVar "t"))) (EApp (EVar "methodArgTys") (EVar "t")))
(DFunDef false "methodArgTys" ((PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EVar "methodArgTys") (EVar "t")))
(DFunDef false "methodArgTys" ((PCon "TyFun" (PCon "TyNamed" PWild (PVar "a") PWild) (PVar "b"))) (EBinOp "::" (EVar "a") (EApp (EVar "methodArgTys") (EVar "b"))))
(DFunDef false "methodArgTys" ((PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "::" (EVar "a") (EApp (EVar "methodArgTys") (EVar "b"))))
(DFunDef false "methodArgTys" (PWild) (EListLit))
(DTypeSig true "methodIfaceTable" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Int"))))))
(DFunDef false "methodIfaceTable" ((PVar "prog")) (EApp (EApp (EVar "flatMap") (EVar "ifaceMethodArityEntries")) (EVar "prog")))
(DTypeSig false "ifaceMethodArityEntries" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Int"))))))
(DFunDef false "ifaceMethodArityEntries" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "ifaceMethodArityEntries") (EVar "d")))
(DFunDef false "ifaceMethodArityEntries" ((PRec "DInterface" ((rf "name" (PVar "ifaceName")) (rf "ifaceOrigin" (PVar "o")) (rf "methods" None)) true)) (EApp (EApp (EVar "map") (ELam ((PVar "m")) (EApp (EApp (EApp (EVar "ifaceMethodArityEntry") (EApp (EApp (EVar "ifaceWordOf") (EVar "o")) (EVar "ifaceName"))) (EVar "ifaceName")) (EVar "m")))) (EVar "methods")))
(DFunDef false "ifaceMethodArityEntries" (PWild) (EListLit))
(DTypeSig false "ifaceMethodArityEntry" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "IfaceMethod") (TyTuple (TyCon "String") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Int")))))))
(DFunDef false "ifaceMethodArityEntry" ((PVar "ifaceWord") (PVar "ifaceName") (PCon "IfaceMethod" (PVar "mname") (PVar "mty") PWild PWild)) (ETuple (EVar "mname") (ETuple (EVar "ifaceName") (EVar "ifaceWord") (EApp (EVar "listLen") (EApp (EVar "methodArgTys") (EVar "mty"))))))
(DTypeSig true "ifaceMethodArityKey" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "ifaceMethodArityKey" ((PVar "ifaceWord") (PVar "mname")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "ifaceWord"))) (ELit (LString "#"))) (EApp (EVar "display") (EVar "mname"))) (ELit (LString ""))))
(DTypeSig true "ifaceWordOfKey" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "ifaceWordOfKey" ((PVar "key")) (EMatch (EApp (EApp (EVar "splitOnChar") (ELit (LChar "|"))) (EVar "key")) (arm (PCons (PVar "w") PWild) () (EVar "w")) (arm (PList) () (EVar "key"))))
(DTypeSig true "ifaceNameOfWord" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "ifaceNameOfWord" ((PVar "word")) (EMatch (EApp (EVar "reverseL") (EApp (EApp (EVar "splitOnChar") (ELit (LChar ":"))) (EVar "word"))) (arm (PCons (PVar "name") PWild) () (EVar "name")) (arm (PList) () (EVar "word"))))
(DTypeSig true "methodConstraintIfaces" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "methodConstraintIfaces" ((PVar "prog")) (EApp (EApp (EVar "flatMap") (EVar "methodConstraintIfaceEntries")) (EVar "prog")))
(DTypeSig false "methodConstraintIfaceEntries" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "methodConstraintIfaceEntries" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "methodConstraintIfaceEntries") (EVar "d")))
(DFunDef false "methodConstraintIfaceEntries" ((PRec "DInterface" ((rf "name" (PVar "ifaceName")) (rf "ifaceOrigin" (PVar "o")) (rf "typarams" None) (rf "methods" None)) true)) (EApp (EApp (EVar "flatMap") (ELam ((PVar "m")) (EApp (EApp (EApp (EVar "methodConstraintIfaceEntry") (EApp (EApp (EVar "ifaceWordOf") (EVar "o")) (EVar "ifaceName"))) (EVar "typarams")) (EVar "m")))) (EVar "methods")))
(DFunDef false "methodConstraintIfaceEntries" (PWild) (EListLit))
(DTypeSig false "methodConstraintIfaceEntry" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "IfaceMethod") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "methodConstraintIfaceEntry" ((PVar "ifaceWord") (PVar "typarams") (PCon "IfaceMethod" (PVar "mname") (PVar "mty") PWild PWild)) (EBlock (DoLet false false (PVar "ifaces") (EApp (EApp (EVar "methodLevelConstraintIfaces") (EVar "typarams")) (EVar "mty"))) (DoLet false false (PVar "qualified") (ETuple (EApp (EApp (EVar "ifaceMethodArityKey") (EVar "ifaceWord")) (EVar "mname")) (EVar "ifaces"))) (DoExpr (EIf (EApp (EVar "isEmptyL") (EVar "ifaces")) (EListLit (EVar "qualified")) (EListLit (ETuple (EVar "mname") (EVar "ifaces")) (EVar "qualified"))))))
(DTypeSig false "methodLevelConstraintIfaces" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "methodLevelConstraintIfaces" ((PVar "typarams") (PCon "TyConstrained" (PVar "cs") (PVar "t"))) (EBinOp "++" (EApp (EApp (EVar "flatMap") (ELam ((PVar "c")) (EApp (EApp (EVar "constraintIfaceIfMethodLevel") (EVar "typarams")) (EVar "c")))) (EVar "cs")) (EApp (EApp (EVar "methodLevelConstraintIfaces") (EVar "typarams")) (EVar "t"))))
(DFunDef false "methodLevelConstraintIfaces" ((PVar "typarams") (PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EApp (EVar "methodLevelConstraintIfaces") (EVar "typarams")) (EVar "t")))
(DFunDef false "methodLevelConstraintIfaces" (PWild PWild) (EListLit))
(DTypeSig false "constraintIfaceIfMethodLevel" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Constraint") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "constraintIfaceIfMethodLevel" ((PVar "typarams") (PRec "Constraint" ((rf "constraintHead" (PVar "ifaceName")) (rf "constraintArgs" (PVar "args"))) false)) (EIf (EApp (EApp (EVar "constraintArgsMentionNonParam") (EVar "typarams")) (EVar "args")) (EListLit (EVar "ifaceName")) (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "constraintArgsMentionNonParam" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyCon "Bool"))))
(DFunDef false "constraintArgsMentionNonParam" ((PVar "typarams") (PVar "args")) (EApp (EApp (EVar "anyList") (ELam ((PVar "t")) (EApp (EApp (EVar "tyMentionsNonParam") (EVar "t")) (EVar "typarams")))) (EVar "args")))
(DTypeSig false "tyMentionsNonParam" (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "tyMentionsNonParam" ((PCon "TyVar" (PVar "n")) (PVar "params")) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EVar "n")) (EVar "params"))))
(DFunDef false "tyMentionsNonParam" ((PRec "TyCon" ((rf "tyConName" PWild)) false) PWild) (EVar "False"))
(DFunDef false "tyMentionsNonParam" ((PCon "TyApp" (PVar "a") (PVar "b")) (PVar "params")) (EBinOp "||" (EApp (EApp (EVar "tyMentionsNonParam") (EVar "a")) (EVar "params")) (EApp (EApp (EVar "tyMentionsNonParam") (EVar "b")) (EVar "params"))))
(DFunDef false "tyMentionsNonParam" ((PCon "TyFun" (PVar "a") (PVar "b")) (PVar "params")) (EBinOp "||" (EApp (EApp (EVar "tyMentionsNonParam") (EVar "a")) (EVar "params")) (EApp (EApp (EVar "tyMentionsNonParam") (EVar "b")) (EVar "params"))))
(DFunDef false "tyMentionsNonParam" ((PCon "TyTuple" (PVar "ts")) (PVar "params")) (EApp (EApp (EVar "anyList") (ELam ((PVar "t")) (EApp (EApp (EVar "tyMentionsNonParam") (EVar "t")) (EVar "params")))) (EVar "ts")))
(DFunDef false "tyMentionsNonParam" ((PCon "TyEffect" PWild PWild (PVar "t")) (PVar "params")) (EApp (EApp (EVar "tyMentionsNonParam") (EVar "t")) (EVar "params")))
(DFunDef false "tyMentionsNonParam" ((PCon "TyRow" PWild (PVar "tail") PWild) (PVar "params")) (EApp (EApp (EVar "anyList") (ELam ((PVar "v")) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EVar "v")) (EVar "params"))))) (EVar "tail")))
(DFunDef false "tyMentionsNonParam" ((PCon "TyAuth" PWild PWild) PWild) (EVar "False"))
(DFunDef false "tyMentionsNonParam" ((PCon "TyConstrained" PWild (PVar "t")) (PVar "params")) (EApp (EApp (EVar "tyMentionsNonParam") (EVar "t")) (EVar "params")))
(DFunDef false "tyMentionsNonParam" ((PCon "TyNamed" PWild (PVar "t") PWild) (PVar "params")) (EApp (EApp (EVar "tyMentionsNonParam") (EVar "t")) (EVar "params")))
(DFunDef false "tyMentionsNonParam" ((PCon "TyQual" (PVar "t") PWild PWild) (PVar "params")) (EApp (EApp (EVar "tyMentionsNonParam") (EVar "t")) (EVar "params")))
(DTypeSig true "ctorFieldTypeNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "ctorFieldTypeNames" ((PVar "prog")) (EApp (EApp (EVar "flatMap") (EVar "ctorFieldTypeEntries")) (EVar "prog")))
(DTypeSig false "ctorFieldTypeEntries" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "ctorFieldTypeEntries" ((PRec "DData" ((rf "dataCtors" (PVar "variants"))) false)) (EApp (EApp (EVar "map") (EVar "variantFieldTypeEntry")) (EVar "variants")))
(DFunDef false "ctorFieldTypeEntries" ((PRec "DNewtype" ((rf "newtypeCtor" (PVar "con")) (rf "newtypeFieldTy" (PVar "fieldTy"))) false)) (EListLit (ETuple (EVar "con") (EListLit (EApp (EVar "tyHeadName") (EVar "fieldTy"))))))
(DFunDef false "ctorFieldTypeEntries" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "ctorFieldTypeEntries") (EVar "d")))
(DFunDef false "ctorFieldTypeEntries" (PWild) (EListLit))
(DTypeSig false "variantFieldTypeEntry" (TyFun (TyCon "Variant") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "variantFieldTypeEntry" ((PCon "Variant" (PVar "name") (PCon "ConPos" (PVar "tys")))) (ETuple (EVar "name") (EApp (EApp (EVar "map") (EVar "tyHeadName")) (EVar "tys"))))
(DFunDef false "variantFieldTypeEntry" ((PCon "Variant" (PVar "name") (PCon "ConNamed" (PVar "fields") PWild))) (ETuple (EVar "name") (EApp (EApp (EVar "map") (EVar "fieldTyHeadName")) (EVar "fields"))))
(DTypeSig false "fieldTyHeadName" (TyFun (TyCon "Field") (TyCon "String")))
(DFunDef false "fieldTyHeadName" ((PCon "Field" PWild (PVar "ty"))) (EApp (EVar "tyHeadName") (EVar "ty")))
(DTypeSig false "tyHeadName" (TyFun (TyCon "Ty") (TyCon "String")))
(DFunDef false "tyHeadName" ((PRec "TyCon" ((rf "tyConName" (PVar "n"))) false)) (EVar "n"))
(DFunDef false "tyHeadName" ((PCon "TyVar" (PVar "n"))) (EVar "n"))
(DFunDef false "tyHeadName" ((PCon "TyApp" (PVar "a") PWild)) (EApp (EVar "tyHeadName") (EVar "a")))
(DFunDef false "tyHeadName" ((PCon "TyConstrained" PWild (PVar "t"))) (EApp (EVar "tyHeadName") (EVar "t")))
(DFunDef false "tyHeadName" ((PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EVar "tyHeadName") (EVar "t")))
(DFunDef false "tyHeadName" ((PCon "TyNamed" PWild (PVar "t") PWild)) (EApp (EVar "tyHeadName") (EVar "t")))
(DFunDef false "tyHeadName" ((PCon "TyQual" (PVar "t") PWild PWild)) (EApp (EVar "tyHeadName") (EVar "t")))
(DFunDef false "tyHeadName" (PWild) (ELit (LString "")))
(DTypeSig true "declSigTypeNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))))
(DFunDef false "declSigTypeNames" ((PVar "prog")) (EApp (EApp (EVar "flatMap") (EVar "declSigTypeEntries")) (EVar "prog")))
(DTypeSig false "declSigTypeEntries" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))))
(DFunDef false "declSigTypeEntries" ((PCon "DTypeSig" PWild (PVar "name") (PVar "ty") PWild)) (EListLit (ETuple (EVar "name") (ETuple (EApp (EApp (EVar "map") (EVar "tyHeadName")) (EApp (EVar "methodArgTys") (EVar "ty"))) (EApp (EVar "tyHeadName") (EApp (EVar "methodRetTy") (EVar "ty")))))))
(DFunDef false "declSigTypeEntries" ((PCon "DExtern" PWild (PVar "name") (PVar "ty"))) (EListLit (ETuple (EVar "name") (ETuple (EApp (EApp (EVar "map") (EVar "tyHeadName")) (EApp (EVar "methodArgTys") (EVar "ty"))) (EApp (EVar "tyHeadName") (EApp (EVar "methodRetTy") (EVar "ty")))))))
(DFunDef false "declSigTypeEntries" ((PCon "DAttrib" PWild (PVar "inner"))) (EApp (EVar "declSigTypeEntries") (EVar "inner")))
(DFunDef false "declSigTypeEntries" (PWild) (EListLit))
(DTypeSig true "ffiExternTypeNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))))))
(DFunDef false "ffiExternTypeNames" ((PVar "runtimeDecls") (PVar "userDecls")) (EApp (EVar "validateFfiExternTypeNames") (EApp (EApp (EVar "ffiExternRows") (EApp (EVar "externDeclNamesOf") (EVar "runtimeDecls"))) (EVar "userDecls"))))
(DTypeSig true "validateFfiExternTypeNames" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))))
(DFunDef false "validateFfiExternTypeNames" ((PVar "rows")) (EBlock (DoLet false false PWild (EApp (EApp (EVar "ffiCheckExternRowsDistinct") (EVar "omEmpty")) (EVar "rows"))) (DoExpr (EVar "rows"))))
(DTypeSig false "ffiCheckExternRowsDistinct" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))) (TyCon "Unit"))))
(DFunDef false "ffiCheckExternRowsDistinct" (PWild (PList)) (ELit LUnit))
(DFunDef false "ffiCheckExternRowsDistinct" ((PVar "seen") (PCons (PTuple (PVar "n") (PVar "sh")) (PVar "rest"))) (EBlock (DoLet false false (PVar "k") (EApp (EVar "ffiRowShapeKey") (EVar "sh"))) (DoExpr (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "seen")) (arm (PCon "None") () (EApp (EApp (EVar "ffiCheckExternRowsDistinct") (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (EVar "k")) (EVar "seen"))) (EVar "rest"))) (arm (PCon "Some" (PVar "prev")) ((GBool (EBinOp "==" (EVar "prev") (EVar "k")))) (EApp (EApp (EVar "ffiCheckExternRowsDistinct") (EVar "seen")) (EVar "rest"))) (arm (PCon "Some" (PVar "prev")) () (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "foreign declaration collision: the C symbol `")) (EApp (EVar "display") (EVar "n"))) (ELit (LString "` is declared twice with different signatures.\ncolliding symbol: "))) (EApp (EVar "display") (EVar "n"))) (ELit (LString "\ndeclaration 1: "))) (EApp (EVar "display") (EVar "prev"))) (ELit (LString "\ndeclaration 2: "))) (EApp (EVar "display") (EVar "k"))) (ELit (LString "\nA foreign declaration's name IS the C symbol it links to, so both declarations name ONE C function and only one of these two signatures can describe it. The other module's calls would be marshalled through the wrong signature -- a wrong value at exit 0, or a memory fault. Give the two declarations the same signature, or declare the differing one against a differently-named C symbol.")))))))))
(DTypeSig false "ffiRowShapeKey" (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")) (TyCon "String")))
(DFunDef false "ffiRowShapeKey" ((PTuple (PVar "args") (PVar "ret"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ","))) (EVar "args")))) (ELit (LString " -> "))) (EApp (EVar "display") (EVar "ret"))) (ELit (LString ""))))
(DTypeSig true "externDeclNamesOf" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "externDeclNamesOf" ((PList)) (EListLit))
(DFunDef false "externDeclNamesOf" ((PCons (PCon "DExtern" PWild (PVar "n") PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "externDeclNamesOf") (EVar "rest"))))
(DFunDef false "externDeclNamesOf" ((PCons (PCon "DAttrib" PWild (PVar "inner")) (PVar "rest"))) (EBinOp "++" (EApp (EVar "externDeclNamesOf") (EListLit (EVar "inner"))) (EApp (EVar "externDeclNamesOf") (EVar "rest"))))
(DFunDef false "externDeclNamesOf" ((PCons PWild (PVar "rest"))) (EApp (EVar "externDeclNamesOf") (EVar "rest")))
(DTypeSig false "ffiExternRows" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))))))
(DFunDef false "ffiExternRows" (PWild (PList)) (EListLit))
(DFunDef false "ffiExternRows" ((PVar "builtins") (PCons (PCon "DExtern" PWild (PVar "n") (PVar "ty")) (PVar "rest"))) (EIf (EApp (EApp (EVar "contains") (EVar "n")) (EVar "builtins")) (EApp (EApp (EVar "ffiExternRows") (EVar "builtins")) (EVar "rest")) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "n") (ETuple (EApp (EApp (EVar "map") (EVar "tyHeadName")) (EApp (EVar "methodArgTys") (EVar "ty"))) (EApp (EVar "tyHeadName") (EApp (EVar "methodRetTy") (EVar "ty"))))) (EApp (EApp (EVar "ffiExternRows") (EVar "builtins")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "ffiExternRows" ((PVar "builtins") (PCons (PCon "DAttrib" PWild (PVar "inner")) (PVar "rest"))) (EApp (EApp (EVar "ffiExternRows") (EVar "builtins")) (EBinOp "::" (EVar "inner") (EVar "rest"))))
(DFunDef false "ffiExternRows" ((PVar "builtins") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "ffiExternRows") (EVar "builtins")) (EVar "rest")))
(DTypeSig false "methodRetTy" (TyFun (TyCon "Ty") (TyCon "Ty")))
(DFunDef false "methodRetTy" ((PCon "TyConstrained" PWild (PVar "t"))) (EApp (EVar "methodRetTy") (EVar "t")))
(DFunDef false "methodRetTy" ((PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EVar "methodRetTy") (EVar "t")))
(DFunDef false "methodRetTy" ((PCon "TyFun" PWild (PVar "b"))) (EApp (EVar "methodRetTy") (EVar "b")))
(DFunDef false "methodRetTy" ((PCon "TyQual" (PVar "t") PWild PWild)) (EApp (EVar "methodRetTy") (EVar "t")))
(DFunDef false "methodRetTy" ((PVar "t")) (EVar "t"))
(DTypeSig false "selfFnPositions" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "selfFnPositions" (PWild (PList) PWild) (EListLit))
(DFunDef false "selfFnPositions" ((PVar "i") (PCons (PVar "t") (PVar "ts")) (PVar "params")) (EIf (EApp (EApp (EVar "tyIsFunReturningSelf") (EVar "t")) (EVar "params")) (EBinOp "::" (EVar "i") (EApp (EApp (EApp (EVar "selfFnPositions") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "ts")) (EVar "params"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "selfFnPositions") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "ts")) (EVar "params")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "tyIsFunReturningSelf" (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "tyIsFunReturningSelf" ((PCon "TyFun" PWild (PVar "b")) (PVar "params")) (EApp (EApp (EVar "tyMentionsParams") (EApp (EVar "methodResultTy") (EVar "b"))) (EVar "params")))
(DFunDef false "tyIsFunReturningSelf" ((PCon "TyConstrained" PWild (PVar "t")) (PVar "params")) (EApp (EApp (EVar "tyIsFunReturningSelf") (EVar "t")) (EVar "params")))
(DFunDef false "tyIsFunReturningSelf" ((PCon "TyEffect" PWild PWild (PVar "t")) (PVar "params")) (EApp (EApp (EVar "tyIsFunReturningSelf") (EVar "t")) (EVar "params")))
(DFunDef false "tyIsFunReturningSelf" (PWild PWild) (EVar "False"))
(DTypeSig false "funClausesOf" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "CClause")))))
(DFunDef false "funClausesOf" ((PList)) (EListLit))
(DFunDef false "funClausesOf" ((PCons (PCon "DFunDef" PWild (PVar "n") (PVar "pats") (PVar "body") PWild) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "n") (EApp (EApp (EVar "CClause") (EVar "pats")) (EApp (EVar "lower") (EVar "body")))) (EApp (EVar "funClausesOf") (EVar "rest"))))
(DFunDef false "funClausesOf" ((PCons (PCon "DLetGroup" PWild (PVar "binds")) (PVar "rest"))) (EBinOp "++" (EApp (EVar "letGroupClausesOf") (EVar "binds")) (EApp (EVar "funClausesOf") (EVar "rest"))))
(DFunDef false "funClausesOf" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "funClausesOf") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "funClausesOf" ((PCons PWild (PVar "rest"))) (EApp (EVar "funClausesOf") (EVar "rest")))
(DTypeSig false "letGroupClausesOf" (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "CClause")))))
(DFunDef false "letGroupClausesOf" ((PList)) (EListLit))
(DFunDef false "letGroupClausesOf" ((PCons (PCon "LetBind" (PVar "n") (PVar "clauses") PWild) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "map") (EApp (EVar "lowerLetBind") (EVar "n"))) (EVar "clauses")) (EApp (EVar "letGroupClausesOf") (EVar "rest"))))
(DTypeSig false "lowerLetBind" (TyFun (TyCon "String") (TyFun (TyCon "FunClause") (TyTuple (TyCon "String") (TyCon "CClause")))))
(DFunDef false "lowerLetBind" ((PVar "n") (PCon "FunClause" (PVar "pats") (PVar "body"))) (ETuple (EVar "n") (EApp (EApp (EVar "CClause") (EVar "pats")) (EApp (EVar "lower") (EVar "body")))))
(DTypeSig false "ctorArities" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int")))))
(DFunDef false "ctorArities" ((PList)) (EListLit))
(DFunDef false "ctorArities" ((PCons (PRec "DData" ((rf "dataCtors" (PVar "variants"))) false) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "map") (EVar "variantArity")) (EVar "variants")) (EApp (EVar "ctorArities") (EVar "rest"))))
(DFunDef false "ctorArities" ((PCons (PRec "DNewtype" ((rf "newtypeCtor" (PVar "con"))) false) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "con") (ELit (LInt 1))) (EApp (EVar "ctorArities") (EVar "rest"))))
(DFunDef false "ctorArities" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "ctorArities") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "ctorArities" ((PCons PWild (PVar "rest"))) (EApp (EVar "ctorArities") (EVar "rest")))
(DTypeSig false "variantArity" (TyFun (TyCon "Variant") (TyTuple (TyCon "String") (TyCon "Int"))))
(DFunDef false "variantArity" ((PCon "Variant" (PVar "n") (PVar "payload"))) (ETuple (EVar "n") (EApp (EVar "payloadArityL") (EVar "payload"))))
(DTypeSig false "payloadArityL" (TyFun (TyCon "ConPayload") (TyCon "Int")))
(DFunDef false "payloadArityL" ((PCon "ConPos" (PVar "tys"))) (EApp (EVar "listLen") (EVar "tys")))
(DFunDef false "payloadArityL" ((PCon "ConNamed" (PVar "fs") PWild)) (EApp (EVar "listLen") (EVar "fs")))
(DTypeSig false "nodeTag" (TyFun (TyCon "Expr") (TyCon "String")))
(DFunDef false "nodeTag" ((PCon "ESection" PWild)) (ELit (LString "ESection")))
(DFunDef false "nodeTag" ((PCon "EGuards" PWild)) (ELit (LString "EGuards")))
(DFunDef false "nodeTag" ((PCon "EDo" PWild PWild)) (ELit (LString "EDo")))
(DFunDef false "nodeTag" ((PCon "EStringInterp" PWild)) (ELit (LString "EStringInterp")))
(DFunDef false "nodeTag" ((PCon "EVariantUpdate" PWild PWild PWild)) (ELit (LString "EVariantUpdate")))
(DFunDef false "nodeTag" ((PCon "EMapLit" PWild PWild)) (ELit (LString "EMapLit")))
(DFunDef false "nodeTag" ((PCon "ESetLit" PWild PWild)) (ELit (LString "ESetLit")))
(DFunDef false "nodeTag" ((PCon "EAsPat" PWild PWild)) (ELit (LString "EAsPat")))
(DFunDef false "nodeTag" ((PCon "EMethodRef" PWild)) (ELit (LString "EMethodRef")))
(DFunDef false "nodeTag" ((PCon "EDictApp" PWild)) (ELit (LString "EDictApp")))
(DFunDef false "nodeTag" (PWild) (ELit (LString "?")))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Lit" true) (mem "Loc" true) (mem "noDeclLoc" false) (mem "Pat" true) (mem "RecPatField" true) (mem "Expr" true) (mem "Arm" true) (mem "Guard" true) (mem "DoStmt" true) (mem "FieldAssign" true) (mem "LetBind" true) (mem "FunClause" true) (mem "Addr" true) (mem "Decl" true) (mem "Variant" true) (mem "ConPayload" true) (mem "Field" true) (mem "Ty" true) (mem "Constraint" true) (mem "IfaceMethod" true) (mem "MethodDefault" true) (mem "ImplMethod" true) (mem "Route" true) (mem "TyConOrigin" false) (mem "ifaceIdentity" false) (mem "defaultReceiverDict" false))))
(DUse false (UseGroup ("types" "route_key") ((mem "implRouteKeyWord" false) (mem "ifaceWordOf" false) (mem "evDictRoutes" false) (mem "evMethodRoutes" false))))
(DUse false (UseGroup ("ir" "core_ir") ((mem "CExpr" true) (mem "CArm" true) (mem "CGuard" true) (mem "CStmt" true) (mem "CField" true) (mem "CBind" true) (mem "CClause" true) (mem "CImplEntry" true) (mem "CImplBody" true) (mem "CProgram" true) (mem "CTree" true) (mem "CTBranch" true) (mem "CHead" true) (mem "FailSite" true) (mem "siteSentinelName" false))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "mapProg" false))))
(DUse false (UseGroup ("frontend" "marker") ((mem "localBoundNames" false))))
(DUse false (UseGroup ("types" "disposition") ((mem "DispositionTable" false) (mem "InstanceShape" true) (mem "ifaceSuperCount" false) (mem "inheritorsOf" false) (mem "installedDispositions" false) (mem "installedDispositionsOpt" false))))
(DUse false (UseGroup ("eval" "eval") ((mem "buildCtorToType" false) (mem "installDispatchTables" false) (mem "lookupPositions" false) (mem "tyvarsInArgs" false) (mem "headTyconHead" false) (mem "exprStartLoc" false))))
(DUse false (UseGroup ("list") ((mem "replicate" false) (mem "take" false) (mem "drop" false) (mem "range" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omInsert" false) (mem "omHasKey" false) (mem "omLookup" false))))
(DUse false (UseGroup ("backend" "private_mangle") ((mem "dictTag" false) (mem "hashName" false) (mem "injectiveIdent" false))))
(DUse false (UseGroup ("support" "util") ((mem "contains" false) (mem "listLen" false) (mem "allList" false) (mem "anyList" false) (mem "lookupAssoc" false) (mem "noneHeadTag" false) (mem "isEmptyL" false) (mem "isNonEmptyL" false) (mem "joinWith" false) (mem "reverseL" false) (mem "startsWith" false) (mem "dedupBy" false) (mem "lenKey" false) (mem "splitOnChar" false))))
(DTypeSig false "composeVar" (TyCon "String"))
(DFunDef false "composeVar" () (ELit (LString "$cf")))
(DTypeSig false "cmethodOf" (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Route") (TyApp (TyCon "List") (TyCon "Route")) (TyApp (TyCon "List") (TyCon "Route"))) (TyCon "CExpr"))))
(DFunDef false "cmethodOf" ((PVar "name") (PTuple (PVar "iface") (PVar "arity") (PVar "route") (PVar "implRoutes") (PVar "methodRoutes"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "CMethod") (EVar "name")) (EVar "iface")) (EVar "arity")) (EVar "route")) (EVar "implRoutes")) (EVar "methodRoutes")))
(DTypeSig false "lower" (TyFun (TyCon "Expr") (TyCon "CExpr")))
(DFunDef false "lower" ((PCon "ELit" (PVar "l"))) (EApp (EVar "CLit") (EVar "l")))
(DFunDef false "lower" ((PCon "ENumLit" (PVar "n") (PVar "r") PWild PWild)) (EMatch (EUnOp "!" (EVar "r")) (arm (PCon "Some" (PVar "f")) () (EApp (EVar "CLit") (EApp (EVar "LFloat") (EVar "f")))) (arm (PCon "None") () (EApp (EVar "CLit") (EApp (EVar "LInt") (EVar "n"))))))
(DFunDef false "lower" ((PCon "EWideLit" (PVar "hi") (PVar "lo") PWild PWild)) (EApp (EVar "CLit") (EApp (EApp (EVar "LU64") (EVar "hi")) (EVar "lo"))))
(DFunDef false "lower" ((PCon "EVar" (PVar "x"))) (EApp (EApp (EVar "CVar") (EVar "x")) (EVar "AGlobal")))
(DFunDef false "lower" ((PCon "EVarId" (PVar "x") PWild)) (EApp (EApp (EVar "CVar") (EVar "x")) (EVar "AGlobal")))
(DFunDef false "lower" ((PCon "EVarAt" (PVar "x") (PVar "addr"))) (EApp (EApp (EVar "CVar") (EVar "x")) (EVar "addr")))
(DFunDef false "lower" ((PCon "EApp" (PVar "f") (PVar "x"))) (EApp (EApp (EVar "CApp") (EApp (EVar "lower") (EVar "f"))) (EApp (EVar "lower") (EVar "x"))))
(DFunDef false "lower" ((PCon "ELam" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "CLam") (EVar "pats")) (EApp (EVar "lower") (EVar "body"))))
(DFunDef false "lower" ((PCon "ELet" (PVar "site") (PCon "False") (PVar "pat") (PVar "e1") (PVar "e2"))) (EIf (EApp (EVar "patMayFail") (EVar "pat")) (EApp (EApp (EApp (EApp (EVar "letDecision") (EVar "site")) (EVar "pat")) (EApp (EVar "lower") (EVar "e1"))) (EApp (EVar "lower") (EVar "e2"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "lower" ((PCon "ELet" PWild (PVar "recFlag") (PVar "pat") (PVar "e1") (PVar "e2"))) (EApp (EApp (EApp (EApp (EVar "CLet") (EVar "recFlag")) (EVar "pat")) (EApp (EVar "lower") (EVar "e1"))) (EApp (EVar "lower") (EVar "e2"))))
(DFunDef false "lower" ((PCon "ELetGroup" (PVar "binds") (PVar "body"))) (EApp (EApp (EVar "CLetGroup") (EApp (EApp (EMethodRef "map") (EVar "lowerBind")) (EVar "binds"))) (EApp (EVar "lower") (EVar "body"))))
(DFunDef false "lower" ((PCon "EMatch" (PVar "scrut") (PVar "arms"))) (EApp (EApp (EApp (EVar "lowerMatch") (EVar "noDeclLoc")) (EApp (EVar "lower") (EVar "scrut"))) (EVar "arms")))
(DFunDef false "lower" ((PCon "EIf" (PVar "c") (PVar "t") (PVar "e"))) (EApp (EApp (EApp (EVar "CIf") (EApp (EVar "lower") (EVar "c"))) (EApp (EVar "lower") (EVar "t"))) (EApp (EVar "lower") (EVar "e"))))
(DFunDef false "lower" ((PCon "EBinOp" (PVar "op") (PVar "l") (PVar "r") (PVar "route"))) (EApp (EApp (EApp (EApp (EVar "lowerBinop") (EVar "op")) (EVar "l")) (EVar "r")) (EApp (EVar "scalarTagOfRoute") (EUnOp "!" (EVar "route")))))
(DFunDef false "lower" ((PCon "EInfix" (PVar "op") (PVar "l") (PVar "r"))) (EApp (EApp (EVar "CApp") (EApp (EApp (EVar "CApp") (EApp (EApp (EVar "CVar") (EVar "op")) (EVar "AGlobal"))) (EApp (EVar "lower") (EVar "l")))) (EApp (EVar "lower") (EVar "r"))))
(DFunDef false "lower" ((PCon "EUnOp" (PLit (LString "!")) (PVar "e") PWild)) (EApp (EApp (EApp (EVar "CFieldAccess") (EApp (EVar "lower") (EVar "e"))) (ELit (LString "value"))) (ELit (LString ""))))
(DFunDef false "lower" ((PCon "EUnOp" (PVar "op") (PVar "e") PWild)) (EApp (EApp (EVar "CUnOp") (EVar "op")) (EApp (EVar "lower") (EVar "e"))))
(DFunDef false "lower" ((PCon "ETuple" (PVar "es"))) (EApp (EVar "CTuple") (EApp (EApp (EMethodRef "map") (EVar "lower")) (EVar "es"))))
(DFunDef false "lower" ((PCon "EListLit" (PVar "es"))) (EApp (EVar "CList") (EApp (EApp (EMethodRef "map") (EVar "lower")) (EVar "es"))))
(DFunDef false "lower" ((PCon "EArrayLit" (PVar "es"))) (EApp (EVar "CArray") (EApp (EApp (EMethodRef "map") (EVar "lower")) (EVar "es"))))
(DFunDef false "lower" ((PCon "ERangeList" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EVar "CRangeList") (EApp (EVar "lower") (EVar "lo"))) (EApp (EVar "lower") (EVar "hi"))) (EVar "incl")))
(DFunDef false "lower" ((PCon "ERangeArray" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EVar "CRangeArray") (EApp (EVar "lower") (EVar "lo"))) (EApp (EVar "lower") (EVar "hi"))) (EVar "incl")))
(DFunDef false "lower" ((PCon "EIndex" (PVar "a") (PVar "i") (PVar "r"))) (EIf (EBinOp "==" (EUnOp "!" (EVar "r")) (ELit (LString "String"))) (EApp (EApp (EVar "CStringIndex") (EApp (EVar "lower") (EVar "a"))) (EApp (EVar "lower") (EVar "i"))) (EIf (EBinOp "==" (EUnOp "!" (EVar "r")) (ELit (LString "List"))) (EApp (EApp (EVar "CListIndex") (EApp (EVar "lower") (EVar "a"))) (EApp (EVar "lower") (EVar "i"))) (EApp (EApp (EVar "CIndex") (EApp (EVar "lower") (EVar "a"))) (EApp (EVar "lower") (EVar "i"))))))
(DFunDef false "lower" ((PCon "ESlice" (PVar "a") (PVar "lo") (PVar "hi") (PVar "incl") (PVar "r"))) (EIf (EBinOp "==" (EUnOp "!" (EVar "r")) (ELit (LString "String"))) (EApp (EApp (EApp (EApp (EVar "CStringSlice") (EApp (EVar "lower") (EVar "a"))) (EApp (EVar "lower") (EVar "lo"))) (EApp (EVar "lower") (EVar "hi"))) (EVar "incl")) (EIf (EBinOp "==" (EUnOp "!" (EVar "r")) (ELit (LString "List"))) (EApp (EApp (EApp (EApp (EVar "CListSlice") (EApp (EVar "lower") (EVar "a"))) (EApp (EVar "lower") (EVar "lo"))) (EApp (EVar "lower") (EVar "hi"))) (EVar "incl")) (EApp (EApp (EApp (EApp (EVar "CSlice") (EApp (EVar "lower") (EVar "a"))) (EApp (EVar "lower") (EVar "lo"))) (EApp (EVar "lower") (EVar "hi"))) (EVar "incl")))))
(DFunDef false "lower" ((PCon "EFieldAccess" (PVar "e") (PVar "f") (PVar "r"))) (EApp (EApp (EApp (EVar "CFieldAccess") (EApp (EVar "lower") (EVar "e"))) (EVar "f")) (EUnOp "!" (EVar "r"))))
(DFunDef false "lower" ((PCon "ERecordCreate" (PVar "name") (PVar "fields"))) (EApp (EApp (EVar "CRecord") (EVar "name")) (EApp (EApp (EMethodRef "map") (EVar "lowerField")) (EVar "fields"))))
(DFunDef false "lower" ((PCon "ERecordUpdate" (PVar "base") (PVar "fields") (PVar "r"))) (EApp (EApp (EApp (EVar "CRecordUpdate") (EUnOp "!" (EVar "r"))) (EApp (EVar "lower") (EVar "base"))) (EApp (EApp (EMethodRef "map") (EVar "lowerField")) (EVar "fields"))))
(DFunDef false "lower" ((PCon "EVariantUpdate" (PVar "con") (PVar "base") (PVar "fields"))) (EApp (EApp (EApp (EVar "CVariantUpdate") (EVar "con")) (EApp (EVar "lower") (EVar "base"))) (EApp (EApp (EMethodRef "map") (EVar "lowerField")) (EVar "fields"))))
(DFunDef false "lower" ((PCon "EBlock" (PVar "stmts"))) (EApp (EVar "CBlock") (EApp (EVar "lowerStmts") (EVar "stmts"))))
(DFunDef false "lower" ((PCon "EAnnot" (PCon "EBinOp" (PVar "op") (PVar "l") (PVar "r") PWild) (PRec "TyCon" ((rf "tyConName" (PVar "tag"))) false))) (EApp (EApp (EApp (EApp (EVar "lowerBinop") (EVar "op")) (EVar "l")) (EVar "r")) (EVar "tag")))
(DFunDef false "lower" ((PCon "EAnnot" (PVar "e") PWild)) (EApp (EVar "lower") (EVar "e")))
(DFunDef false "lower" ((PCon "EHeadAnnot" (PVar "e") PWild)) (EApp (EVar "lower") (EVar "e")))
(DFunDef false "lower" ((PCon "EMethodAt" (PVar "name") PWild (PVar "ev"))) (EApp (EApp (EVar "cmethodOf") (EVar "name")) (EApp (EVar "evMethodRoutes") (EVar "ev"))))
(DFunDef false "lower" ((PCon "EDictAt" (PVar "name") (PVar "ev"))) (EApp (EApp (EVar "CDict") (EVar "name")) (EApp (EVar "evDictRoutes") (EVar "ev"))))
(DFunDef false "lower" ((PCon "ELoc" (PVar "l") (PCon "EMatch" (PVar "scrut") (PVar "arms")))) (EApp (EApp (EApp (EVar "lowerMatch") (EVar "l")) (EApp (EVar "lower") (EVar "scrut"))) (EVar "arms")))
(DFunDef false "lower" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "lower") (EVar "e")))
(DFunDef false "lower" ((PCon "EDoOrigin" PWild (PVar "e"))) (EApp (EVar "lower") (EVar "e")))
(DFunDef false "lower" ((PVar "other")) (EApp (EVar "panic") (EBinOp "++" (ELit (LString "core_ir lower: unsupported node ")) (EApp (EVar "nodeTag") (EVar "other")))))
(DTypeSig false "scalarTagOfRoute" (TyFun (TyCon "Route") (TyCon "String")))
(DFunDef false "scalarTagOfRoute" ((PCon "RScalar" (PVar "s"))) (EVar "s"))
(DFunDef false "scalarTagOfRoute" (PWild) (ELit (LString "")))
(DTypeSig false "lowerBinop" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyFun (TyCon "String") (TyCon "CExpr"))))))
(DFunDef false "lowerBinop" ((PLit (LString "&&")) (PVar "l") (PVar "r") PWild) (EApp (EApp (EApp (EVar "CIf") (EApp (EVar "lower") (EVar "l"))) (EApp (EVar "lower") (EVar "r"))) (EApp (EVar "CLit") (EApp (EVar "LBool") (EVar "False")))))
(DFunDef false "lowerBinop" ((PLit (LString "||")) (PVar "l") (PVar "r") PWild) (EApp (EApp (EApp (EVar "CIf") (EApp (EVar "lower") (EVar "l"))) (EApp (EVar "CLit") (EApp (EVar "LBool") (EVar "True")))) (EApp (EVar "lower") (EVar "r"))))
(DFunDef false "lowerBinop" ((PLit (LString "|>")) (PVar "l") (PVar "r") PWild) (EApp (EApp (EVar "CApp") (EApp (EVar "lower") (EVar "r"))) (EApp (EVar "lower") (EVar "l"))))
(DFunDef false "lowerBinop" ((PLit (LString ">>")) (PVar "l") (PVar "r") PWild) (EApp (EApp (EVar "composeLam") (EApp (EVar "lower") (EVar "l"))) (EApp (EVar "lower") (EVar "r"))))
(DFunDef false "lowerBinop" ((PLit (LString "<<")) (PVar "l") (PVar "r") PWild) (EApp (EApp (EVar "composeLam") (EApp (EVar "lower") (EVar "r"))) (EApp (EVar "lower") (EVar "l"))))
(DFunDef false "lowerBinop" ((PVar "op") (PVar "l") (PVar "r") (PVar "tag")) (EApp (EApp (EApp (EApp (EApp (EVar "CBinPrim") (EVar "op")) (EApp (EVar "lower") (EVar "l"))) (EApp (EVar "lower") (EVar "r"))) (EVar "tag")) (EApp (EVar "exprStartLoc") (EVar "l"))))
(DTypeSig false "composeLam" (TyFun (TyCon "CExpr") (TyFun (TyCon "CExpr") (TyCon "CExpr"))))
(DFunDef false "composeLam" ((PVar "first") (PVar "second")) (EApp (EApp (EVar "CLam") (EListLit (EApp (EApp (EVar "PVar") (EVar "composeVar")) (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString ""))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0)))))) (EApp (EApp (EVar "CApp") (EVar "second")) (EApp (EApp (EVar "CApp") (EVar "first")) (EApp (EApp (EVar "CVar") (EVar "composeVar")) (EVar "AGlobal"))))))
(DTypeSig false "lowerArm" (TyFun (TyCon "Arm") (TyCon "CArm")))
(DFunDef false "lowerArm" ((PCon "Arm" (PVar "pat") (PVar "guards") (PVar "body"))) (EApp (EApp (EApp (EVar "CArm") (EVar "pat")) (EApp (EApp (EMethodRef "map") (EVar "lowerGuard")) (EVar "guards"))) (EApp (EVar "lower") (EVar "body"))))
(DTypeSig false "lowerGuard" (TyFun (TyCon "Guard") (TyCon "CGuard")))
(DFunDef false "lowerGuard" ((PCon "GBool" (PVar "e"))) (EApp (EVar "CGBool") (EApp (EVar "lower") (EVar "e"))))
(DFunDef false "lowerGuard" ((PCon "GBind" (PVar "p") (PVar "e"))) (EApp (EApp (EVar "CGBind") (EVar "p")) (EApp (EVar "lower") (EVar "e"))))
(DTypeSig false "lowerMatch" (TyFun (TyCon "Loc") (TyFun (TyCon "CExpr") (TyFun (TyApp (TyCon "List") (TyCon "Arm")) (TyCon "CExpr")))))
(DFunDef false "lowerMatch" ((PVar "site") (PVar "cscrut") (PVar "arms")) (EIf (EApp (EApp (EVar "allList") (EVar "armTreeable")) (EVar "arms")) (EApp (EApp (EApp (EVar "CDecision") (EVar "cscrut")) (EApp (EApp (EMethodRef "map") (EVar "lowerArm")) (EVar "arms"))) (EApp (EApp (EVar "compileArms") (EApp (EVar "NoArm") (EVar "site"))) (EVar "arms"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "CMatch") (EVar "cscrut")) (EApp (EApp (EMethodRef "map") (EVar "lowerArm")) (EVar "arms"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "letDecision" (TyFun (TyCon "Loc") (TyFun (TyCon "Pat") (TyFun (TyCon "CExpr") (TyFun (TyCon "CExpr") (TyCon "CExpr"))))))
(DFunDef false "letDecision" ((PVar "site") (PVar "pat") (PVar "scrut") (PVar "body")) (EBlock (DoLet false false (PVar "arms") (EListLit (EApp (EApp (EApp (EVar "CArm") (EVar "pat")) (EListLit)) (EVar "body")))) (DoExpr (EApp (EApp (EApp (EVar "CDecision") (EVar "scrut")) (EVar "arms")) (EApp (EApp (EVar "compileArmsC") (EApp (EVar "LetRefuted") (EVar "site"))) (EVar "arms"))))))
(DTypeSig false "patMayFail" (TyFun (TyCon "Pat") (TyCon "Bool")))
(DFunDef false "patMayFail" ((PCon "PWild")) (EVar "False"))
(DFunDef false "patMayFail" ((PCon "PVar" PWild PWild)) (EVar "False"))
(DFunDef false "patMayFail" ((PCon "PLit" (PCon "LUnit"))) (EVar "False"))
(DFunDef false "patMayFail" ((PCon "PAs" PWild PWild (PVar "p"))) (EApp (EVar "patMayFail") (EVar "p")))
(DFunDef false "patMayFail" ((PCon "PTuple" (PVar "ps"))) (EApp (EApp (EVar "anyList") (EVar "patMayFail")) (EVar "ps")))
(DFunDef false "patMayFail" (PWild) (EVar "True"))
(DTypeSig false "lowerStmts" (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyApp (TyCon "List") (TyCon "CStmt"))))
(DFunDef false "lowerStmts" ((PList)) (EListLit))
(DFunDef false "lowerStmts" ((PCons (PCon "DoLet" PWild (PCon "False") (PVar "pat") (PVar "e") (PVar "site")) (PVar "rest"))) (EIf (EApp (EVar "patMayFail") (EVar "pat")) (EListLit (EApp (EVar "CSExpr") (EApp (EApp (EApp (EApp (EVar "letDecision") (EVar "site")) (EVar "pat")) (EApp (EVar "lower") (EVar "e"))) (EApp (EVar "CBlock") (EApp (EVar "lowerStmts") (EVar "rest")))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "lowerStmts" ((PCons (PVar "s") (PVar "rest"))) (EBinOp "::" (EApp (EVar "lowerStmt") (EVar "s")) (EApp (EVar "lowerStmts") (EVar "rest"))))
(DTypeSig false "armTreeable" (TyFun (TyCon "Arm") (TyCon "Bool")))
(DFunDef false "armTreeable" ((PCon "Arm" (PVar "pat") PWild PWild)) (EApp (EVar "treeablePat") (EVar "pat")))
(DTypeSig false "treeablePat" (TyFun (TyCon "Pat") (TyCon "Bool")))
(DFunDef false "treeablePat" ((PCon "PWild")) (EVar "True"))
(DFunDef false "treeablePat" ((PCon "PVar" PWild PWild)) (EVar "True"))
(DFunDef false "treeablePat" ((PCon "PLit" PWild)) (EVar "True"))
(DFunDef false "treeablePat" ((PCon "PCon" PWild (PVar "args"))) (EApp (EApp (EVar "allList") (EVar "treeablePat")) (EVar "args")))
(DFunDef false "treeablePat" ((PCon "PCons" (PVar "h") (PVar "t"))) (EBinOp "&&" (EApp (EVar "treeablePat") (EVar "h")) (EApp (EVar "treeablePat") (EVar "t"))))
(DFunDef false "treeablePat" ((PCon "PList" (PVar "ps"))) (EApp (EApp (EVar "allList") (EVar "treeablePat")) (EVar "ps")))
(DFunDef false "treeablePat" ((PCon "PTuple" (PVar "ps"))) (EApp (EApp (EVar "allList") (EVar "treeablePat")) (EVar "ps")))
(DFunDef false "treeablePat" ((PCon "PAs" PWild PWild (PVar "p"))) (EApp (EVar "treeablePat") (EVar "p")))
(DFunDef false "treeablePat" ((PCon "PRng" PWild PWild PWild)) (EVar "True"))
(DFunDef false "treeablePat" ((PCon "PRec" PWild PWild PWild)) (EVar "True"))
(DTypeSig false "compileArms" (TyFun (TyCon "FailSite") (TyFun (TyApp (TyCon "List") (TyCon "Arm")) (TyCon "CTree"))))
(DFunDef false "compileArms" ((PVar "site") (PVar "arms")) (EApp (EApp (EApp (EVar "compileTree") (EVar "site")) (EApp (EApp (EMethodRef "map") (EVar "armHasGuard")) (EVar "arms"))) (EApp (EApp (EVar "initialRows") (EVar "arms")) (ELit (LInt 0)))))
(DTypeSig false "armHasGuard" (TyFun (TyCon "Arm") (TyCon "Bool")))
(DFunDef false "armHasGuard" ((PCon "Arm" (PVar "pat") (PVar "gs") PWild)) (EBinOp "||" (EApp (EVar "isNonEmptyL") (EVar "gs")) (EApp (EVar "patNeedsGuard") (EVar "pat"))))
(DTypeSig false "patNeedsGuard" (TyFun (TyCon "Pat") (TyCon "Bool")))
(DFunDef false "patNeedsGuard" ((PCon "PRng" PWild PWild PWild)) (EVar "True"))
(DFunDef false "patNeedsGuard" ((PCon "PRec" PWild PWild PWild)) (EVar "True"))
(DFunDef false "patNeedsGuard" ((PCon "PCon" PWild (PVar "args"))) (EApp (EApp (EVar "anyList") (EVar "patNeedsGuard")) (EVar "args")))
(DFunDef false "patNeedsGuard" ((PCon "PCons" (PVar "h") (PVar "t"))) (EBinOp "||" (EApp (EVar "patNeedsGuard") (EVar "h")) (EApp (EVar "patNeedsGuard") (EVar "t"))))
(DFunDef false "patNeedsGuard" ((PCon "PList" (PVar "ps"))) (EApp (EApp (EVar "anyList") (EVar "patNeedsGuard")) (EVar "ps")))
(DFunDef false "patNeedsGuard" ((PCon "PTuple" (PVar "ps"))) (EApp (EApp (EVar "anyList") (EVar "patNeedsGuard")) (EVar "ps")))
(DFunDef false "patNeedsGuard" ((PCon "PAs" PWild PWild (PVar "p"))) (EApp (EVar "patNeedsGuard") (EVar "p")))
(DFunDef false "patNeedsGuard" (PWild) (EVar "False"))
(DTypeSig false "initialRows" (TyFun (TyApp (TyCon "List") (TyCon "Arm")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))))))
(DFunDef false "initialRows" ((PList) PWild) (EListLit))
(DFunDef false "initialRows" ((PCons (PCon "Arm" (PVar "pat") PWild PWild) (PVar "rest")) (PVar "i")) (EBinOp "::" (ETuple (EListLit (EApp (EVar "canonPat") (EVar "pat"))) (EVar "i")) (EApp (EApp (EVar "initialRows") (EVar "rest")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))
(DTypeSig true "compileTree" (TyFun (TyCon "FailSite") (TyFun (TyApp (TyCon "List") (TyCon "Bool")) (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))) (TyCon "CTree")))))
(DFunDef false "compileTree" ((PVar "site") (PVar "guards") (PVar "rows")) (EApp (EApp (EVar "withFailSite") (EVar "site")) (EApp (EApp (EVar "compileTreeG") (EApp (EApp (EApp (EVar "guardSet") (ELit (LInt 0))) (EVar "guards")) (EVar "omEmpty"))) (EVar "rows"))))
(DTypeSig false "withFailSite" (TyFun (TyCon "FailSite") (TyFun (TyCon "CTree") (TyCon "CTree"))))
(DFunDef false "withFailSite" ((PVar "site") (PCon "CTFail" PWild)) (EApp (EVar "CTFail") (EVar "site")))
(DFunDef false "withFailSite" (PWild (PCon "CTLeaf" (PVar "i"))) (EApp (EVar "CTLeaf") (EVar "i")))
(DFunDef false "withFailSite" ((PVar "site") (PCon "CTGuard" (PVar "i") (PVar "t"))) (EApp (EApp (EVar "CTGuard") (EVar "i")) (EApp (EApp (EVar "withFailSite") (EVar "site")) (EVar "t"))))
(DFunDef false "withFailSite" ((PVar "site") (PCon "CTSwitch" (PVar "bs") (PVar "d"))) (EApp (EApp (EVar "CTSwitch") (EApp (EApp (EMethodRef "map") (EApp (EVar "failSiteBranch") (EVar "site"))) (EVar "bs"))) (EApp (EApp (EVar "withFailSite") (EVar "site")) (EVar "d"))))
(DFunDef false "withFailSite" ((PVar "site") (PCon "CTDrop" (PVar "t"))) (EApp (EVar "CTDrop") (EApp (EApp (EVar "withFailSite") (EVar "site")) (EVar "t"))))
(DTypeSig false "failSiteBranch" (TyFun (TyCon "FailSite") (TyFun (TyCon "CTBranch") (TyCon "CTBranch"))))
(DFunDef false "failSiteBranch" ((PVar "site") (PCon "CTBranch" (PVar "h") (PVar "t"))) (EApp (EApp (EVar "CTBranch") (EVar "h")) (EApp (EApp (EVar "withFailSite") (EVar "site")) (EVar "t"))))
(DTypeSig false "treeFailSite" (TyFun (TyCon "CTree") (TyCon "FailSite")))
(DFunDef false "treeFailSite" ((PVar "t")) (EMatch (EApp (EVar "treeFailSiteOpt") (EVar "t")) (arm (PCon "Some" (PVar "s")) () (EVar "s")) (arm (PCon "None") () (EApp (EVar "NoArm") (EVar "noDeclLoc")))))
(DTypeSig false "treeFailSiteOpt" (TyFun (TyCon "CTree") (TyApp (TyCon "Option") (TyCon "FailSite"))))
(DFunDef false "treeFailSiteOpt" ((PCon "CTFail" (PVar "s"))) (EApp (EVar "Some") (EVar "s")))
(DFunDef false "treeFailSiteOpt" ((PCon "CTLeaf" PWild)) (EVar "None"))
(DFunDef false "treeFailSiteOpt" ((PCon "CTGuard" PWild (PVar "t"))) (EApp (EVar "treeFailSiteOpt") (EVar "t")))
(DFunDef false "treeFailSiteOpt" ((PCon "CTSwitch" (PVar "bs") (PVar "d"))) (EMatch (EApp (EVar "firstBranchFailSite") (EVar "bs")) (arm (PCon "Some" (PVar "s")) () (EApp (EVar "Some") (EVar "s"))) (arm (PCon "None") () (EApp (EVar "treeFailSiteOpt") (EVar "d")))))
(DFunDef false "treeFailSiteOpt" ((PCon "CTDrop" (PVar "t"))) (EApp (EVar "treeFailSiteOpt") (EVar "t")))
(DTypeSig false "firstBranchFailSite" (TyFun (TyApp (TyCon "List") (TyCon "CTBranch")) (TyApp (TyCon "Option") (TyCon "FailSite"))))
(DFunDef false "firstBranchFailSite" ((PList)) (EVar "None"))
(DFunDef false "firstBranchFailSite" ((PCons (PCon "CTBranch" PWild (PVar "t")) (PVar "rest"))) (EMatch (EApp (EVar "treeFailSiteOpt") (EVar "t")) (arm (PCon "Some" (PVar "s")) () (EApp (EVar "Some") (EVar "s"))) (arm (PCon "None") () (EApp (EVar "firstBranchFailSite") (EVar "rest")))))
(DTypeSig false "guardSet" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Bool")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit"))))))
(DFunDef false "guardSet" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "guardSet" ((PVar "i") (PCons (PCon "True") (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "guardSet") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EApp (EVar "intToString") (EVar "i"))) (ELit LUnit)) (EVar "acc"))))
(DFunDef false "guardSet" ((PVar "i") (PCons (PCon "False") (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "guardSet") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest")) (EVar "acc")))
(DTypeSig false "compileTreeG" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))) (TyCon "CTree"))))
(DFunDef false "compileTreeG" (PWild (PList)) (EApp (EVar "CTFail") (EApp (EVar "NoArm") (EVar "noDeclLoc"))))
(DFunDef false "compileTreeG" ((PVar "guards") (PCons (PVar "row") (PVar "rest"))) (EApp (EApp (EApp (EApp (EVar "compileRows") (EVar "guards")) (EVar "row")) (EVar "rest")) (EBinOp "::" (EVar "row") (EVar "rest"))))
(DTypeSig false "compileRows" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))) (TyCon "CTree"))))))
(DFunDef false "compileRows" ((PVar "guards") (PTuple (PVar "pats") (PVar "i")) (PVar "rest") (PVar "rows")) (EIf (EApp (EVar "allWild") (EVar "pats")) (EApp (EApp (EApp (EVar "leafOrGuard") (EVar "guards")) (EVar "i")) (EVar "rest")) (EIf (EApp (EApp (EVar "anyList") (EVar "rowHasCon")) (EVar "rows")) (EApp (EApp (EVar "buildConSwitch") (EVar "guards")) (EVar "rows")) (EIf (EApp (EApp (EVar "anyList") (EVar "rowHasLit")) (EVar "rows")) (EApp (EApp (EVar "buildLitSwitch") (EVar "guards")) (EVar "rows")) (EIf (EVar "otherwise") (EApp (EVar "CTDrop") (EApp (EApp (EVar "compileTreeG") (EVar "guards")) (EApp (EApp (EMethodRef "map") (EVar "dropHead")) (EVar "rows")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "leafOrGuard" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))) (TyCon "CTree")))))
(DFunDef false "leafOrGuard" ((PVar "guards") (PVar "i") (PVar "rest")) (EIf (EApp (EApp (EVar "omHasKey") (EApp (EVar "intToString") (EVar "i"))) (EVar "guards")) (EApp (EApp (EVar "CTGuard") (EVar "i")) (EApp (EApp (EVar "compileTreeG") (EVar "guards")) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EVar "CTLeaf") (EVar "i")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "buildConSwitch" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))) (TyCon "CTree"))))
(DFunDef false "buildConSwitch" ((PVar "guards") (PVar "rows")) (EBlock (DoLet false false (PVar "buckets") (EApp (EApp (EApp (EVar "conBuckets") (ELit (LInt 0))) (EVar "rows")) (EVar "omEmpty"))) (DoLet false false (PVar "wilds") (EApp (EApp (EVar "wildTailRows") (ELit (LInt 0))) (EVar "rows"))) (DoExpr (EApp (EApp (EVar "CTSwitch") (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EVar "conBranch") (EVar "guards")) (EVar "buckets")) (EVar "wilds"))) (EApp (EVar "distinctConHeads") (EVar "rows")))) (EApp (EApp (EVar "compileTreeG") (EVar "guards")) (EApp (EVar "defaultMatrix") (EVar "rows")))))))
(DTypeSig false "conBranch" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int")))) (TyFun (TyTuple (TyCon "String") (TyCon "Int")) (TyCon "CTBranch"))))))
(DFunDef false "conBranch" ((PVar "guards") (PVar "buckets") (PVar "wilds") (PTuple (PVar "c") (PVar "a"))) (EApp (EApp (EVar "CTBranch") (EApp (EApp (EVar "decodeHead") (EVar "c")) (EVar "a"))) (EApp (EApp (EVar "compileTreeG") (EVar "guards")) (EApp (EApp (EVar "mergeByOrd") (EApp (EVar "reverseL") (EApp (EApp (EVar "bucketRows") (EVar "c")) (EVar "buckets")))) (EApp (EApp (EMethodRef "map") (EApp (EVar "padWildRow") (EVar "a"))) (EVar "wilds"))))))
(DTypeSig false "buildLitSwitch" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))) (TyCon "CTree"))))
(DFunDef false "buildLitSwitch" ((PVar "guards") (PVar "rows")) (EBlock (DoLet false false (PVar "buckets") (EApp (EApp (EApp (EVar "litBuckets") (ELit (LInt 0))) (EVar "rows")) (EVar "omEmpty"))) (DoLet false false (PVar "wilds") (EApp (EApp (EVar "wildTailRows") (ELit (LInt 0))) (EVar "rows"))) (DoExpr (EApp (EApp (EVar "CTSwitch") (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EVar "litBranch") (EVar "guards")) (EVar "buckets")) (EVar "wilds"))) (EApp (EVar "distinctLits") (EVar "rows")))) (EApp (EApp (EVar "compileTreeG") (EVar "guards")) (EApp (EVar "defaultMatrix") (EVar "rows")))))))
(DTypeSig false "litBranch" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int")))) (TyFun (TyCon "Lit") (TyCon "CTBranch"))))))
(DFunDef false "litBranch" ((PVar "guards") (PVar "buckets") (PVar "wilds") (PVar "l")) (EApp (EApp (EVar "CTBranch") (EApp (EVar "HLit") (EVar "l"))) (EApp (EApp (EVar "compileTreeG") (EVar "guards")) (EApp (EApp (EVar "mergeByOrd") (EApp (EVar "reverseL") (EApp (EApp (EVar "bucketRows") (EApp (EVar "litKey") (EVar "l"))) (EVar "buckets")))) (EVar "wilds")))))
(DTypeSig false "decodeHead" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "CHead"))))
(DFunDef false "decodeHead" ((PLit (LString "__cons__")) PWild) (EVar "HCons"))
(DFunDef false "decodeHead" ((PLit (LString "__nil__")) PWild) (EVar "HNil"))
(DFunDef false "decodeHead" ((PLit (LString "__unit__")) PWild) (EVar "HUnit"))
(DFunDef false "decodeHead" ((PLit (LString "__tuple__")) (PVar "a")) (EApp (EVar "HTuple") (EVar "a")))
(DFunDef false "decodeHead" ((PVar "c") (PVar "a")) (EApp (EApp (EVar "HCon") (EVar "c")) (EVar "a")))
(DTypeSig false "tupleName" (TyCon "String"))
(DFunDef false "tupleName" () (ELit (LString "__tuple__")))
(DTypeSig false "consName" (TyCon "String"))
(DFunDef false "consName" () (ELit (LString "__cons__")))
(DTypeSig false "nilName" (TyCon "String"))
(DFunDef false "nilName" () (ELit (LString "__nil__")))
(DTypeSig false "unitName" (TyCon "String"))
(DFunDef false "unitName" () (ELit (LString "__unit__")))
(DTypeSig true "canonPat" (TyFun (TyCon "Pat") (TyCon "Pat")))
(DFunDef false "canonPat" ((PCon "PVar" PWild PWild)) (EVar "PWild"))
(DFunDef false "canonPat" ((PCon "PWild")) (EVar "PWild"))
(DFunDef false "canonPat" ((PCon "PLit" (PCon "LBool" (PCon "True")))) (EApp (EApp (EVar "PCon") (ELit (LString "True"))) (EListLit)))
(DFunDef false "canonPat" ((PCon "PLit" (PCon "LBool" (PCon "False")))) (EApp (EApp (EVar "PCon") (ELit (LString "False"))) (EListLit)))
(DFunDef false "canonPat" ((PCon "PLit" (PCon "LUnit"))) (EApp (EApp (EVar "PCon") (EVar "unitName")) (EListLit)))
(DFunDef false "canonPat" ((PCon "PLit" (PVar "l"))) (EApp (EVar "PLit") (EVar "l")))
(DFunDef false "canonPat" ((PCon "PTuple" (PVar "ps"))) (EApp (EApp (EVar "PCon") (EVar "tupleName")) (EApp (EApp (EMethodRef "map") (EVar "canonPat")) (EVar "ps"))))
(DFunDef false "canonPat" ((PCon "PCon" (PVar "c") (PVar "args"))) (EApp (EApp (EVar "PCon") (EVar "c")) (EApp (EApp (EMethodRef "map") (EVar "canonPat")) (EVar "args"))))
(DFunDef false "canonPat" ((PCon "PCons" (PVar "h") (PVar "t"))) (EApp (EApp (EVar "PCon") (EVar "consName")) (EListLit (EApp (EVar "canonPat") (EVar "h")) (EApp (EVar "canonPat") (EVar "t")))))
(DFunDef false "canonPat" ((PCon "PList" (PList))) (EApp (EApp (EVar "PCon") (EVar "nilName")) (EListLit)))
(DFunDef false "canonPat" ((PCon "PList" (PCons (PVar "h") (PVar "r")))) (EApp (EApp (EVar "PCon") (EVar "consName")) (EListLit (EApp (EVar "canonPat") (EVar "h")) (EApp (EVar "canonPat") (EApp (EVar "PList") (EVar "r"))))))
(DFunDef false "canonPat" ((PCon "PAs" PWild PWild (PVar "p"))) (EApp (EVar "canonPat") (EVar "p")))
(DFunDef false "canonPat" ((PCon "PRng" PWild PWild PWild)) (EVar "PWild"))
(DFunDef false "canonPat" ((PCon "PRec" PWild PWild PWild)) (EVar "PWild"))
(DTypeSig false "allWild" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Bool")))
(DFunDef false "allWild" ((PVar "ps")) (EApp (EApp (EVar "allList") (EVar "isWildPat")) (EVar "ps")))
(DTypeSig false "isWildPat" (TyFun (TyCon "Pat") (TyCon "Bool")))
(DFunDef false "isWildPat" ((PCon "PWild")) (EVar "True"))
(DFunDef false "isWildPat" (PWild) (EVar "False"))
(DTypeSig false "rowHasCon" (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int")) (TyCon "Bool")))
(DFunDef false "rowHasCon" ((PTuple (PCons (PCon "PCon" PWild PWild) PWild) PWild)) (EVar "True"))
(DFunDef false "rowHasCon" (PWild) (EVar "False"))
(DTypeSig false "rowHasLit" (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int")) (TyCon "Bool")))
(DFunDef false "rowHasLit" ((PTuple (PCons (PCon "PLit" PWild) PWild) PWild)) (EVar "True"))
(DFunDef false "rowHasLit" (PWild) (EVar "False"))
(DTypeSig false "dropHead" (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int")) (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))))
(DFunDef false "dropHead" ((PTuple (PCons PWild (PVar "ps")) (PVar "i"))) (ETuple (EVar "ps") (EVar "i")))
(DFunDef false "dropHead" ((PTuple (PList) (PVar "i"))) (ETuple (EListLit) (EVar "i")))
(DTypeSig false "distinctConHeads" (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int")))))
(DFunDef false "distinctConHeads" ((PVar "rows")) (EApp (EApp (EVar "dedupHeads") (EApp (EVar "colHeads") (EVar "rows"))) (EVar "omEmpty")))
(DTypeSig false "colHeads" (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int")))))
(DFunDef false "colHeads" ((PList)) (EListLit))
(DFunDef false "colHeads" ((PCons (PTuple (PCons (PCon "PCon" (PVar "c") (PVar "args")) PWild) PWild) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "c") (EApp (EVar "listLen") (EVar "args"))) (EApp (EVar "colHeads") (EVar "rest"))))
(DFunDef false "colHeads" ((PCons PWild (PVar "rest"))) (EApp (EVar "colHeads") (EVar "rest")))
(DTypeSig false "dedupHeads" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))))))
(DFunDef false "dedupHeads" ((PList) PWild) (EListLit))
(DFunDef false "dedupHeads" ((PCons (PTuple (PVar "c") (PVar "a")) (PVar "rest")) (PVar "seen")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "c")) (EVar "seen")) (EApp (EApp (EVar "dedupHeads") (EVar "rest")) (EVar "seen")) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "c") (EVar "a")) (EApp (EApp (EVar "dedupHeads") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "c")) (ELit LUnit)) (EVar "seen")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "distinctLits" (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))) (TyApp (TyCon "List") (TyCon "Lit"))))
(DFunDef false "distinctLits" ((PVar "rows")) (EApp (EApp (EVar "dedupLits") (EApp (EVar "colLits") (EVar "rows"))) (EVar "omEmpty")))
(DTypeSig false "colLits" (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))) (TyApp (TyCon "List") (TyCon "Lit"))))
(DFunDef false "colLits" ((PList)) (EListLit))
(DFunDef false "colLits" ((PCons (PTuple (PCons (PCon "PLit" (PVar "l")) PWild) PWild) (PVar "rest"))) (EBinOp "::" (EVar "l") (EApp (EVar "colLits") (EVar "rest"))))
(DFunDef false "colLits" ((PCons PWild (PVar "rest"))) (EApp (EVar "colLits") (EVar "rest")))
(DTypeSig false "dedupLits" (TyFun (TyApp (TyCon "List") (TyCon "Lit")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "List") (TyCon "Lit")))))
(DFunDef false "dedupLits" ((PList) PWild) (EListLit))
(DFunDef false "dedupLits" ((PCons (PVar "l") (PVar "rest")) (PVar "seen")) (EBlock (DoLet false false (PVar "k") (EApp (EVar "litKey") (EVar "l"))) (DoExpr (EMatch (EApp (EApp (EVar "omHasKey") (EVar "k")) (EVar "seen")) (arm (PCon "True") () (EApp (EApp (EVar "dedupLits") (EVar "rest")) (EVar "seen"))) (arm (PCon "False") () (EBinOp "::" (EVar "l") (EApp (EApp (EVar "dedupLits") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "k")) (ELit LUnit)) (EVar "seen")))))))))
(DTypeSig false "litKey" (TyFun (TyCon "Lit") (TyCon "String")))
(DFunDef false "litKey" ((PCon "LInt" (PVar "n"))) (EBinOp "++" (ELit (LString "i")) (EApp (EVar "intToString") (EVar "n"))))
(DFunDef false "litKey" ((PCon "LChar" (PVar "c"))) (EBinOp "++" (ELit (LString "c")) (EVar "c")))
(DFunDef false "litKey" ((PCon "LString" (PVar "s"))) (EBinOp "++" (ELit (LString "s")) (EVar "s")))
(DFunDef false "litKey" ((PCon "LFloat" (PVar "f"))) (EBinOp "++" (ELit (LString "f")) (EApp (EVar "floatToString") (EApp (EVar "normLitZero") (EVar "f")))))
(DFunDef false "litKey" ((PCon "LBool" (PCon "True"))) (ELit (LString "bT")))
(DFunDef false "litKey" ((PCon "LBool" (PCon "False"))) (ELit (LString "bF")))
(DFunDef false "litKey" ((PCon "LUnit")) (ELit (LString "u")))
(DFunDef false "litKey" ((PCon "LU64" (PVar "hi") (PVar "lo"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "w")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "hi")))) (ELit (LString "."))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "lo")))) (ELit (LString ""))))
(DFunDef false "litKey" ((PCon "LI64" (PVar "hi") (PVar "lo"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "i")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "hi")))) (ELit (LString "."))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "lo")))) (ELit (LString ""))))
(DTypeSig false "normLitZero" (TyFun (TyCon "Float") (TyCon "Float")))
(DFunDef false "normLitZero" ((PVar "f")) (EIf (EBinOp "==" (EVar "f") (ELit (LFloat 0.0))) (ELit (LFloat 0.0)) (EVar "f")))
(DTypeSig false "filterMapRows" (TyFun (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int")) (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))) (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))))))
(DFunDef false "filterMapRows" (PWild (PList)) (EListLit))
(DFunDef false "filterMapRows" ((PVar "f") (PCons (PVar "r") (PVar "rest"))) (EMatch (EApp (EVar "f") (EVar "r")) (arm (PCon "Some" (PVar "r2")) () (EBinOp "::" (EVar "r2") (EApp (EApp (EVar "filterMapRows") (EVar "f")) (EVar "rest")))) (arm (PCon "None") () (EApp (EApp (EVar "filterMapRows") (EVar "f")) (EVar "rest")))))
(DTypeSig false "bucketRows" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int")))))))
(DFunDef false "bucketRows" ((PVar "k") (PVar "m")) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "k")) (EVar "m"))))
(DTypeSig false "pushBucket" (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "Int") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int")))))))))
(DFunDef false "pushBucket" ((PVar "k") (PVar "r") (PVar "m")) (EApp (EApp (EApp (EVar "omInsert") (EVar "k")) (EBinOp "::" (EVar "r") (EApp (EApp (EVar "bucketRows") (EVar "k")) (EVar "m")))) (EVar "m")))
(DTypeSig false "conBuckets" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int")))))))))
(DFunDef false "conBuckets" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "conBuckets" ((PVar "k") (PCons (PTuple (PCons (PCon "PCon" (PVar "c") (PVar "args")) (PVar "rest")) (PVar "i")) (PVar "more")) (PVar "acc")) (EApp (EApp (EApp (EVar "conBuckets") (EBinOp "+" (EVar "k") (ELit (LInt 1)))) (EVar "more")) (EApp (EApp (EApp (EVar "pushBucket") (EVar "c")) (ETuple (EVar "k") (ETuple (EBinOp "++" (EVar "args") (EVar "rest")) (EVar "i")))) (EVar "acc"))))
(DFunDef false "conBuckets" ((PVar "k") (PCons PWild (PVar "more")) (PVar "acc")) (EApp (EApp (EApp (EVar "conBuckets") (EBinOp "+" (EVar "k") (ELit (LInt 1)))) (EVar "more")) (EVar "acc")))
(DTypeSig false "litBuckets" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int")))))))))
(DFunDef false "litBuckets" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "litBuckets" ((PVar "k") (PCons (PTuple (PCons (PCon "PLit" (PVar "l")) (PVar "rest")) (PVar "i")) (PVar "more")) (PVar "acc")) (EApp (EApp (EApp (EVar "litBuckets") (EBinOp "+" (EVar "k") (ELit (LInt 1)))) (EVar "more")) (EApp (EApp (EApp (EVar "pushBucket") (EApp (EVar "litKey") (EVar "l"))) (ETuple (EVar "k") (ETuple (EVar "rest") (EVar "i")))) (EVar "acc"))))
(DFunDef false "litBuckets" ((PVar "k") (PCons PWild (PVar "more")) (PVar "acc")) (EApp (EApp (EApp (EVar "litBuckets") (EBinOp "+" (EVar "k") (ELit (LInt 1)))) (EVar "more")) (EVar "acc")))
(DTypeSig false "wildTailRows" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int")))))))
(DFunDef false "wildTailRows" (PWild (PList)) (EListLit))
(DFunDef false "wildTailRows" ((PVar "k") (PCons (PTuple (PCons (PCon "PWild") (PVar "rest")) (PVar "i")) (PVar "more"))) (EBinOp "::" (ETuple (EVar "k") (ETuple (EVar "rest") (EVar "i"))) (EApp (EApp (EVar "wildTailRows") (EBinOp "+" (EVar "k") (ELit (LInt 1)))) (EVar "more"))))
(DFunDef false "wildTailRows" ((PVar "k") (PCons PWild (PVar "more"))) (EApp (EApp (EVar "wildTailRows") (EBinOp "+" (EVar "k") (ELit (LInt 1)))) (EVar "more")))
(DTypeSig false "padWildRow" (TyFun (TyCon "Int") (TyFun (TyTuple (TyCon "Int") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))) (TyTuple (TyCon "Int") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))))))
(DFunDef false "padWildRow" ((PVar "arity") (PTuple (PVar "k") (PTuple (PVar "ps") (PVar "i")))) (ETuple (EVar "k") (ETuple (EBinOp "++" (EApp (EApp (EVar "replicate") (EVar "arity")) (EVar "PWild")) (EVar "ps")) (EVar "i"))))
(DTypeSig false "mergeByOrd" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int")))) (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))))))
(DFunDef false "mergeByOrd" ((PList) (PVar "ys")) (EApp (EApp (EMethodRef "map") (EVar "untagRow")) (EVar "ys")))
(DFunDef false "mergeByOrd" ((PVar "xs") (PList)) (EApp (EApp (EMethodRef "map") (EVar "untagRow")) (EVar "xs")))
(DFunDef false "mergeByOrd" ((PCons (PTuple (PVar "ka") (PVar "ra")) (PVar "xs")) (PCons (PTuple (PVar "kb") (PVar "rb")) (PVar "ys"))) (EIf (EBinOp "<" (EVar "ka") (EVar "kb")) (EBinOp "::" (EVar "ra") (EApp (EApp (EVar "mergeByOrd") (EVar "xs")) (EBinOp "::" (ETuple (EVar "kb") (EVar "rb")) (EVar "ys")))) (EBinOp "::" (EVar "rb") (EApp (EApp (EVar "mergeByOrd") (EBinOp "::" (ETuple (EVar "ka") (EVar "ra")) (EVar "xs"))) (EVar "ys")))))
(DTypeSig false "untagRow" (TyFun (TyTuple (TyCon "Int") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))) (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))))
(DFunDef false "untagRow" ((PTuple PWild (PVar "r"))) (EVar "r"))
(DTypeSig false "defaultMatrix" (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))) (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int")))))
(DFunDef false "defaultMatrix" ((PVar "rows")) (EApp (EApp (EVar "filterMapRows") (EVar "defRow")) (EVar "rows")))
(DTypeSig false "defRow" (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int")) (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int")))))
(DFunDef false "defRow" ((PTuple (PCons (PCon "PWild") (PVar "rest")) (PVar "i"))) (EApp (EVar "Some") (ETuple (EVar "rest") (EVar "i"))))
(DFunDef false "defRow" (PWild) (EVar "None"))
(DTypeSig false "lowerField" (TyFun (TyCon "FieldAssign") (TyCon "CField")))
(DFunDef false "lowerField" ((PCon "FieldAssign" (PVar "k") (PVar "e"))) (EApp (EApp (EVar "CField") (EVar "k")) (EApp (EVar "lower") (EVar "e"))))
(DTypeSig false "lowerBind" (TyFun (TyCon "LetBind") (TyCon "CBind")))
(DFunDef false "lowerBind" ((PCon "LetBind" (PVar "name") (PVar "clauses") (PVar "site"))) (EApp (EApp (EApp (EVar "CBind") (EVar "name")) (EApp (EApp (EMethodRef "map") (EVar "lowerClause")) (EVar "clauses"))) (EVar "site")))
(DTypeSig false "lowerClause" (TyFun (TyCon "FunClause") (TyCon "CClause")))
(DFunDef false "lowerClause" ((PCon "FunClause" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "CClause") (EVar "pats")) (EApp (EVar "lower") (EVar "body"))))
(DTypeSig false "lowerStmt" (TyFun (TyCon "DoStmt") (TyCon "CStmt")))
(DFunDef false "lowerStmt" ((PCon "DoExpr" (PVar "e"))) (EApp (EVar "CSExpr") (EApp (EVar "lower") (EVar "e"))))
(DFunDef false "lowerStmt" ((PCon "DoLet" PWild (PVar "recFlag") (PVar "pat") (PVar "e") PWild)) (EApp (EApp (EApp (EVar "CSLet") (EVar "recFlag")) (EVar "pat")) (EApp (EVar "lower") (EVar "e"))))
(DFunDef false "lowerStmt" ((PCon "DoAssign" (PVar "x") (PVar "e"))) (EApp (EApp (EVar "CSAssign") (EVar "x")) (EApp (EVar "lower") (EVar "e"))))
(DFunDef false "lowerStmt" (PWild) (EApp (EVar "panic") (ELit (LString "core_ir lower: unsupported block statement"))))
(DTypeSig true "lowerProgram" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "CProgram")))
(DFunDef false "lowerProgram" ((PVar "prog")) (EApp (EApp (EVar "refoldProgram") (EVar "noLetCheck")) (EApp (EApp (EVar "lowerProgramWith") (EVar "None")) (EVar "prog"))))
(DTypeSig true "lowerTypedProgram" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "CProgram")))
(DFunDef false "lowerTypedProgram" ((PVar "prog")) (EApp (EApp (EVar "refoldProgram") (EVar "noLetCheck")) (EApp (EApp (EVar "lowerProgramWith") (EApp (EVar "Some") (EApp (EVar "installedDispositions") (ELit LUnit)))) (EVar "prog"))))
(DTypeSig false "lowerProgramWith" (TyFun (TyApp (TyCon "Option") (TyCon "DispositionTable")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "CProgram"))))
(DFunDef false "lowerProgramWith" ((PVar "dispositions") (PVar "prog")) (EApp (EApp (EApp (EApp (EVar "CProgram") (EApp (EVar "lowerGroupsRaw") (EVar "prog"))) (EApp (EVar "ctorArities") (EVar "prog"))) (EApp (EVar "buildCtorToType") (EVar "prog"))) (EApp (EApp (EApp (EApp (EVar "lowerImplsRaw") (EApp (EVar "installDispatchTables") (EVar "prog"))) (EApp (EVar "instanceReqCounts") (EVar "prog"))) (EVar "dispositions")) (EVar "prog"))))
(DTypeSig false "noLetCheck" (TyFun (TyCon "Pat") (TyCon "Bool")))
(DFunDef false "noLetCheck" (PWild) (EVar "False"))
(DTypeSig false "patCanMiss" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Bool")) (TyFun (TyCon "Pat") (TyCon "Bool"))))
(DFunDef false "patCanMiss" (PWild (PCon "PWild")) (EVar "False"))
(DFunDef false "patCanMiss" (PWild (PCon "PVar" PWild PWild)) (EVar "False"))
(DFunDef false "patCanMiss" (PWild (PCon "PLit" (PCon "LUnit"))) (EVar "False"))
(DFunDef false "patCanMiss" (PWild (PCon "PLit" PWild)) (EVar "True"))
(DFunDef false "patCanMiss" ((PVar "sib") (PCon "PAs" PWild PWild (PVar "p"))) (EApp (EApp (EVar "patCanMiss") (EVar "sib")) (EVar "p")))
(DFunDef false "patCanMiss" ((PVar "sib") (PCon "PTuple" (PVar "ps"))) (EApp (EApp (EVar "anyList") (EApp (EVar "patCanMiss") (EVar "sib"))) (EVar "ps")))
(DFunDef false "patCanMiss" ((PVar "sib") (PCon "PCon" (PVar "c") (PVar "ps"))) (EBinOp "||" (EApp (EApp (EVar "ctorHasSibling") (EVar "sib")) (EVar "c")) (EApp (EApp (EVar "anyList") (EApp (EVar "patCanMiss") (EVar "sib"))) (EVar "ps"))))
(DFunDef false "patCanMiss" (PWild (PCon "PRec" PWild PWild PWild)) (EVar "False"))
(DFunDef false "patCanMiss" (PWild PWild) (EVar "True"))
(DTypeSig false "ctorHasSibling" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Bool")) (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "ctorHasSibling" ((PVar "sib") (PVar "c")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "c")) (EVar "sib")) (arm (PCon "Some" (PVar "b")) () (EVar "b")) (arm (PCon "None") () (EVar "True"))))
(DTypeSig false "siblingTable" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "OrdMap") (TyCon "Bool"))))
(DFunDef false "siblingTable" ((PVar "t")) (EBlock (DoLet false false (PVar "counts") (EApp (EApp (EVar "typeCtorCounts") (EVar "t")) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EApp (EVar "siblingRows") (EVar "counts")) (EVar "t")) (EVar "omEmpty")))))
(DTypeSig false "typeCtorCounts" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyApp (TyCon "OrdMap") (TyCon "Int")))))
(DFunDef false "typeCtorCounts" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "typeCtorCounts" ((PCons (PTuple PWild (PVar "ty")) (PVar "rest")) (PVar "acc")) (EBlock (DoLet false false (PVar "n") (EMatch (EApp (EApp (EVar "omLookup") (EVar "ty")) (EVar "acc")) (arm (PCon "Some" (PVar "k")) () (EBinOp "+" (EVar "k") (ELit (LInt 1)))) (arm (PCon "None") () (ELit (LInt 1))))) (DoExpr (EApp (EApp (EVar "typeCtorCounts") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "ty")) (EVar "n")) (EVar "acc"))))))
(DTypeSig false "siblingRows" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Bool")) (TyApp (TyCon "OrdMap") (TyCon "Bool"))))))
(DFunDef false "siblingRows" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "siblingRows" ((PVar "counts") (PCons (PTuple (PVar "c") (PVar "ty")) (PVar "rest")) (PVar "acc")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "c")) (EVar "acc")) (EApp (EApp (EApp (EVar "siblingRows") (EVar "counts")) (EVar "rest")) (EVar "acc")) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "many") (EMatch (EApp (EApp (EVar "omLookup") (EVar "ty")) (EVar "counts")) (arm (PCon "Some" (PVar "k")) () (EBinOp ">" (EVar "k") (ELit (LInt 1)))) (arm (PCon "None") () (EVar "True")))) (DoExpr (EApp (EApp (EApp (EVar "siblingRows") (EVar "counts")) (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "c")) (EVar "many")) (EVar "acc"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "letDecisionSite" (TyFun (TyCon "CTree") (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "letDecisionSite" ((PVar "t")) (EMatch (EApp (EVar "treeFailSiteOpt") (EVar "t")) (arm (PCon "Some" (PCon "LetRefuted" (PVar "l"))) () (EApp (EVar "Some") (EVar "l"))) (arm PWild () (EVar "None"))))
(DTypeSig false "refoldProgram" (TyFun (TyFun (TyCon "Pat") (TyCon "Bool")) (TyFun (TyCon "CProgram") (TyCon "CProgram"))))
(DFunDef false "refoldProgram" ((PVar "keep") (PCon "CProgram" (PVar "groups") (PVar "ctorArs") (PVar "ctorTypes") (PVar "implEntries"))) (EApp (EApp (EApp (EApp (EVar "CProgram") (EApp (EApp (EMethodRef "map") (EApp (EVar "refoldBind") (EVar "keep"))) (EVar "groups"))) (EVar "ctorArs")) (EVar "ctorTypes")) (EApp (EApp (EMethodRef "map") (EApp (EVar "refoldImpl") (EVar "keep"))) (EVar "implEntries"))))
(DTypeSig false "refoldBind" (TyFun (TyFun (TyCon "Pat") (TyCon "Bool")) (TyFun (TyCon "CBind") (TyCon "CBind"))))
(DFunDef false "refoldBind" ((PVar "keep") (PCon "CBind" (PVar "n") (PVar "clauses") (PVar "site"))) (EApp (EApp (EApp (EVar "CBind") (EVar "n")) (EApp (EApp (EMethodRef "map") (EApp (EVar "refoldClause") (EVar "keep"))) (EVar "clauses"))) (EVar "site")))
(DTypeSig false "refoldClause" (TyFun (TyFun (TyCon "Pat") (TyCon "Bool")) (TyFun (TyCon "CClause") (TyCon "CClause"))))
(DFunDef false "refoldClause" ((PVar "keep") (PCon "CClause" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "CClause") (EVar "pats")) (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "body"))))
(DTypeSig false "refoldImpl" (TyFun (TyFun (TyCon "Pat") (TyCon "Bool")) (TyFun (TyCon "CImplEntry") (TyCon "CImplEntry"))))
(DFunDef false "refoldImpl" ((PVar "keep") (PCon "CImplEntry" (PVar "n") (PVar "s") (PCon "CImplTagged" (PVar "tag") (PVar "key") (PVar "iface") (PVar "ps") (PVar "pats") (PVar "body")))) (EApp (EApp (EApp (EVar "CImplEntry") (EVar "n")) (EVar "s")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "CImplTagged") (EVar "tag")) (EVar "key")) (EVar "iface")) (EVar "ps")) (EVar "pats")) (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "body")))))
(DFunDef false "refoldImpl" ((PVar "keep") (PCon "CImplEntry" (PVar "n") (PVar "s") (PCon "CImplDefault" (PVar "ifaceId") (PVar "tag") (PVar "key") (PVar "ps") (PVar "pats") (PVar "body")))) (EApp (EApp (EApp (EVar "CImplEntry") (EVar "n")) (EVar "s")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "CImplDefault") (EVar "ifaceId")) (EVar "tag")) (EVar "key")) (EVar "ps")) (EVar "pats")) (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "body")))))
(DTypeSig false "refoldExpr" (TyFun (TyFun (TyCon "Pat") (TyCon "Bool")) (TyFun (TyCon "CExpr") (TyCon "CExpr"))))
(DFunDef false "refoldExpr" ((PVar "keep") (PCon "CDecision" (PVar "scrut") (PList (PCon "CArm" (PVar "pat") (PList) (PVar "body"))) (PVar "tree"))) (EIf (EBinOp "&&" (EApp (EVar "isSomeLoc") (EApp (EVar "letDecisionSite") (EVar "tree"))) (EApp (EVar "not") (EApp (EVar "keep") (EVar "pat")))) (EApp (EApp (EApp (EApp (EVar "CLet") (EVar "False")) (EVar "pat")) (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "scrut"))) (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "body"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "refoldExpr" ((PVar "keep") (PCon "CDecision" (PVar "scrut") (PVar "arms") (PVar "tree"))) (EApp (EApp (EApp (EVar "CDecision") (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "scrut"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "refoldArm") (EVar "keep"))) (EVar "arms"))) (EVar "tree")))
(DFunDef false "refoldExpr" (PWild (PCon "CLit" (PVar "l"))) (EApp (EVar "CLit") (EVar "l")))
(DFunDef false "refoldExpr" (PWild (PCon "CVar" (PVar "x") (PVar "addr"))) (EApp (EApp (EVar "CVar") (EVar "x")) (EVar "addr")))
(DFunDef false "refoldExpr" ((PVar "keep") (PCon "CApp" (PVar "f") (PVar "x"))) (EApp (EApp (EVar "CApp") (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "f"))) (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "x"))))
(DFunDef false "refoldExpr" ((PVar "keep") (PCon "CLam" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "CLam") (EVar "pats")) (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "body"))))
(DFunDef false "refoldExpr" ((PVar "keep") (PCon "CLet" (PVar "r") (PVar "pat") (PVar "e1") (PVar "e2"))) (EApp (EApp (EApp (EApp (EVar "CLet") (EVar "r")) (EVar "pat")) (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "e1"))) (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "e2"))))
(DFunDef false "refoldExpr" ((PVar "keep") (PCon "CLetGroup" (PVar "binds") (PVar "body"))) (EApp (EApp (EVar "CLetGroup") (EApp (EApp (EMethodRef "map") (EApp (EVar "refoldBind") (EVar "keep"))) (EVar "binds"))) (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "body"))))
(DFunDef false "refoldExpr" ((PVar "keep") (PCon "CMatch" (PVar "scrut") (PVar "arms"))) (EApp (EApp (EVar "CMatch") (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "scrut"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "refoldArm") (EVar "keep"))) (EVar "arms"))))
(DFunDef false "refoldExpr" ((PVar "keep") (PCon "CIf" (PVar "c") (PVar "t") (PVar "e"))) (EApp (EApp (EApp (EVar "CIf") (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "c"))) (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "t"))) (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "e"))))
(DFunDef false "refoldExpr" ((PVar "keep") (PCon "CBinPrim" (PVar "op") (PVar "l") (PVar "r") (PVar "tag") (PVar "site"))) (EApp (EApp (EApp (EApp (EApp (EVar "CBinPrim") (EVar "op")) (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "l"))) (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "r"))) (EVar "tag")) (EVar "site")))
(DFunDef false "refoldExpr" ((PVar "keep") (PCon "CUnOp" (PVar "op") (PVar "x"))) (EApp (EApp (EVar "CUnOp") (EVar "op")) (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "x"))))
(DFunDef false "refoldExpr" ((PVar "keep") (PCon "CTuple" (PVar "es"))) (EApp (EVar "CTuple") (EApp (EApp (EMethodRef "map") (EApp (EVar "refoldExpr") (EVar "keep"))) (EVar "es"))))
(DFunDef false "refoldExpr" ((PVar "keep") (PCon "CList" (PVar "es"))) (EApp (EVar "CList") (EApp (EApp (EMethodRef "map") (EApp (EVar "refoldExpr") (EVar "keep"))) (EVar "es"))))
(DFunDef false "refoldExpr" ((PVar "keep") (PCon "CRecord" (PVar "name") (PVar "fields"))) (EApp (EApp (EVar "CRecord") (EVar "name")) (EApp (EApp (EMethodRef "map") (EApp (EVar "refoldField") (EVar "keep"))) (EVar "fields"))))
(DFunDef false "refoldExpr" ((PVar "keep") (PCon "CFieldAccess" (PVar "ex") (PVar "f") (PVar "n"))) (EApp (EApp (EApp (EVar "CFieldAccess") (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "ex"))) (EVar "f")) (EVar "n")))
(DFunDef false "refoldExpr" ((PVar "keep") (PCon "CRecordUpdate" (PVar "name") (PVar "base") (PVar "fields"))) (EApp (EApp (EApp (EVar "CRecordUpdate") (EVar "name")) (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "base"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "refoldField") (EVar "keep"))) (EVar "fields"))))
(DFunDef false "refoldExpr" ((PVar "keep") (PCon "CVariantUpdate" (PVar "con") (PVar "base") (PVar "fields"))) (EApp (EApp (EApp (EVar "CVariantUpdate") (EVar "con")) (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "base"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "refoldField") (EVar "keep"))) (EVar "fields"))))
(DFunDef false "refoldExpr" ((PVar "keep") (PCon "CArray" (PVar "es"))) (EApp (EVar "CArray") (EApp (EApp (EMethodRef "map") (EApp (EVar "refoldExpr") (EVar "keep"))) (EVar "es"))))
(DFunDef false "refoldExpr" ((PVar "keep") (PCon "CRangeList" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EVar "CRangeList") (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "lo"))) (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "refoldExpr" ((PVar "keep") (PCon "CRangeArray" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EVar "CRangeArray") (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "lo"))) (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "refoldExpr" ((PVar "keep") (PCon "CIndex" (PVar "a") (PVar "i"))) (EApp (EApp (EVar "CIndex") (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "a"))) (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "i"))))
(DFunDef false "refoldExpr" ((PVar "keep") (PCon "CSlice" (PVar "a") (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EApp (EVar "CSlice") (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "a"))) (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "lo"))) (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "refoldExpr" ((PVar "keep") (PCon "CStringIndex" (PVar "a") (PVar "i"))) (EApp (EApp (EVar "CStringIndex") (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "a"))) (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "i"))))
(DFunDef false "refoldExpr" ((PVar "keep") (PCon "CStringSlice" (PVar "a") (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EApp (EVar "CStringSlice") (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "a"))) (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "lo"))) (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "refoldExpr" ((PVar "keep") (PCon "CListIndex" (PVar "a") (PVar "i"))) (EApp (EApp (EVar "CListIndex") (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "a"))) (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "i"))))
(DFunDef false "refoldExpr" ((PVar "keep") (PCon "CListSlice" (PVar "a") (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EApp (EVar "CListSlice") (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "a"))) (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "lo"))) (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "refoldExpr" ((PVar "keep") (PCon "CBlock" (PVar "stmts"))) (EApp (EVar "CBlock") (EApp (EApp (EVar "refoldStmts") (EVar "keep")) (EVar "stmts"))))
(DFunDef false "refoldExpr" (PWild (PCon "CMethod" (PVar "name") (PVar "iface") (PVar "arity") (PVar "r") (PVar "ir") (PVar "mr"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "CMethod") (EVar "name")) (EVar "iface")) (EVar "arity")) (EVar "r")) (EVar "ir")) (EVar "mr")))
(DFunDef false "refoldExpr" (PWild (PCon "CDict" (PVar "name") (PVar "rs"))) (EApp (EApp (EVar "CDict") (EVar "name")) (EVar "rs")))
(DTypeSig false "refoldStmts" (TyFun (TyFun (TyCon "Pat") (TyCon "Bool")) (TyFun (TyApp (TyCon "List") (TyCon "CStmt")) (TyApp (TyCon "List") (TyCon "CStmt")))))
(DFunDef false "refoldStmts" (PWild (PList)) (EListLit))
(DFunDef false "refoldStmts" ((PVar "keep") (PList (PCon "CSExpr" (PCon "CDecision" (PVar "scrut") (PList (PCon "CArm" (PVar "pat") (PList) (PCon "CBlock" (PVar "rest")))) (PVar "tree"))))) (EIf (EApp (EVar "isSomeLoc") (EApp (EVar "letDecisionSite") (EVar "tree"))) (EBlock (DoLet false false (PVar "scrut2") (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "scrut"))) (DoExpr (EIf (EApp (EVar "keep") (EVar "pat")) (EBlock (DoLet false false (PVar "body") (EIf (EApp (EVar "isEmptyL") (EVar "rest")) (EApp (EVar "CLit") (EVar "LUnit")) (EApp (EVar "CBlock") (EApp (EApp (EVar "refoldStmts") (EVar "keep")) (EVar "rest"))))) (DoExpr (EListLit (EApp (EVar "CSExpr") (EApp (EApp (EApp (EVar "CDecision") (EVar "scrut2")) (EListLit (EApp (EApp (EApp (EVar "CArm") (EVar "pat")) (EListLit)) (EVar "body")))) (EVar "tree")))))) (EBinOp "::" (EApp (EApp (EApp (EVar "CSLet") (EVar "False")) (EVar "pat")) (EVar "scrut2")) (EApp (EApp (EVar "refoldStmts") (EVar "keep")) (EVar "rest")))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "refoldStmts" ((PVar "keep") (PCons (PVar "s") (PVar "rest"))) (EBinOp "::" (EApp (EApp (EVar "refoldStmt") (EVar "keep")) (EVar "s")) (EApp (EApp (EVar "refoldStmts") (EVar "keep")) (EVar "rest"))))
(DTypeSig false "refoldStmt" (TyFun (TyFun (TyCon "Pat") (TyCon "Bool")) (TyFun (TyCon "CStmt") (TyCon "CStmt"))))
(DFunDef false "refoldStmt" ((PVar "keep") (PCon "CSExpr" (PVar "e"))) (EApp (EVar "CSExpr") (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "e"))))
(DFunDef false "refoldStmt" ((PVar "keep") (PCon "CSLet" (PVar "r") (PVar "pat") (PVar "e"))) (EApp (EApp (EApp (EVar "CSLet") (EVar "r")) (EVar "pat")) (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "e"))))
(DFunDef false "refoldStmt" ((PVar "keep") (PCon "CSAssign" (PVar "x") (PVar "e"))) (EApp (EApp (EVar "CSAssign") (EVar "x")) (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "e"))))
(DTypeSig false "refoldArm" (TyFun (TyFun (TyCon "Pat") (TyCon "Bool")) (TyFun (TyCon "CArm") (TyCon "CArm"))))
(DFunDef false "refoldArm" ((PVar "keep") (PCon "CArm" (PVar "pat") (PVar "guards") (PVar "body"))) (EApp (EApp (EApp (EVar "CArm") (EVar "pat")) (EApp (EApp (EMethodRef "map") (EApp (EVar "refoldGuard") (EVar "keep"))) (EVar "guards"))) (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "body"))))
(DTypeSig false "refoldGuard" (TyFun (TyFun (TyCon "Pat") (TyCon "Bool")) (TyFun (TyCon "CGuard") (TyCon "CGuard"))))
(DFunDef false "refoldGuard" ((PVar "keep") (PCon "CGBool" (PVar "e"))) (EApp (EVar "CGBool") (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "e"))))
(DFunDef false "refoldGuard" ((PVar "keep") (PCon "CGBind" (PVar "p") (PVar "e"))) (EApp (EApp (EVar "CGBind") (EVar "p")) (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "e"))))
(DTypeSig false "refoldField" (TyFun (TyFun (TyCon "Pat") (TyCon "Bool")) (TyFun (TyCon "CField") (TyCon "CField"))))
(DFunDef false "refoldField" ((PVar "keep") (PCon "CField" (PVar "k") (PVar "e"))) (EApp (EApp (EVar "CField") (EVar "k")) (EApp (EApp (EVar "refoldExpr") (EVar "keep")) (EVar "e"))))
(DTypeSig false "isSomeLoc" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Bool")))
(DFunDef false "isSomeLoc" ((PCon "Some" PWild)) (EVar "True"))
(DFunDef false "isSomeLoc" ((PCon "None")) (EVar "False"))
(DData Public "EmitTarget" () ((variant "TargetNative" (ConPos)) (variant "TargetWasm" (ConPos)) (variant "TargetBothUnknown" (ConPos))) ())
(DTypeSig true "lowerProgramEmit" (TyFun (TyCon "EmitTarget") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "CProgram"))))
(DFunDef false "lowerProgramEmit" ((PVar "target") (PVar "prog")) (EBlock (DoLet false false PWild (EApp (EVar "implSymbolCollisionGuard") (EVar "prog"))) (DoLet false false PWild (EApp (EApp (EVar "dictWitnessTagGuard") (EVar "target")) (EVar "prog"))) (DoLet false false (PVar "sited") (EMatch (EVar "target") (arm (PCon "TargetBothUnknown") () (EVar "prog")) (arm PWild () (EApp (EVar "siteTrapCalls") (EVar "prog"))))) (DoLet false false (PVar "raw") (EApp (EApp (EVar "lowerProgramWith") (EApp (EVar "installedDispositionsOpt") (ELit LUnit))) (EVar "sited"))) (DoLet false false (PVar "fo") (EApp (EVar "declaredRecordFieldOrders") (EVar "prog"))) (DoExpr (EApp (EVar "hoistNullaryMemo") (EMatch (EVar "target") (arm (PCon "TargetBothUnknown") () (EApp (EApp (EVar "rewriteProgramRecPats") (EVar "fo")) (EApp (EApp (EVar "refoldProgram") (EVar "noLetCheck")) (EVar "raw")))) (arm PWild () (EBlock (DoLet false false (PVar "rewritten") (EApp (EApp (EVar "rewriteProgramRecPats") (EVar "fo")) (EVar "raw"))) (DoExpr (EApp (EApp (EVar "refoldProgram") (EApp (EVar "patCanMiss") (EApp (EVar "siblingTable") (EApp (EVar "cprogramCtorTypes") (EVar "raw"))))) (EVar "rewritten"))))))))))
(DTypeSig false "cprogramCtorTypes" (TyFun (TyCon "CProgram") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "cprogramCtorTypes" ((PCon "CProgram" PWild PWild (PVar "ctorTypes") PWild)) (EVar "ctorTypes"))
(DTypeSig false "siteTrapCalls" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "siteTrapCalls" ((PVar "prog")) (EBlock (DoLet false false (PVar "twins") (EApp (EVar "indexTwins") (EApp (EApp (EVar "topFunNames") (EVar "prog")) (EVar "omEmpty")))) (DoExpr (EApp (EApp (EMethodRef "map") (EApp (EVar "siteTrapDecl") (EVar "twins"))) (EVar "prog")))))
(DTypeSig false "siteTrapDecl" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "Decl") (TyCon "Decl"))))
(DFunDef false "siteTrapDecl" ((PVar "twins") (PVar "d")) (EBlock (DoLet false false (PVar "panicFree") (EApp (EVar "not") (EApp (EApp (EVar "contains") (ELit (LString "panic"))) (EApp (EVar "declBinders") (EVar "d"))))) (DoExpr (EMatch (EApp (EApp (EVar "mapProg") (EApp (EApp (EVar "siteTrapExpr") (EVar "panicFree")) (EVar "twins"))) (EListLit (EVar "d"))) (arm (PList (PVar "d2")) () (EVar "d2")) (arm PWild () (EVar "d"))))))
(DTypeSig false "siteTrapExpr" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "siteTrapExpr" ((PVar "panicFree") (PVar "twins") (PAs "e" (PCon "EApp" (PVar "h") (PVar "m")))) (EIf (EBinOp "&&" (EVar "panicFree") (EApp (EVar "isPanicHead") (EVar "h"))) (EApp (EApp (EApp (EApp (EVar "sitedCall") (EApp (EVar "exprStartLoc") (EVar "e"))) (EApp (EVar "EVar") (ELit (LString "panicAt")))) (EListLit (EVar "m"))) (EVar "e")) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "siteTrapExpr" (PWild (PVar "twins") (PAs "e" (PCon "EApp" (PCon "EApp" (PVar "h") (PVar "a")) (PVar "i")))) (EMatch (EApp (EApp (EVar "indexTwinOf") (EVar "twins")) (EVar "h")) (arm (PCon "Some" (PVar "twin")) () (EApp (EApp (EApp (EApp (EVar "sitedCall") (EApp (EVar "exprStartLoc") (EVar "e"))) (EApp (EVar "EVar") (EVar "twin"))) (EListLit (EVar "a") (EVar "i"))) (EVar "e"))) (arm (PCon "None") () (EVar "e"))))
(DFunDef false "siteTrapExpr" (PWild PWild (PVar "e")) (EVar "e"))
(DTypeSig false "sitedCall" (TyFun (TyCon "Loc") (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyFun (TyCon "Expr") (TyCon "Expr"))))))
(DFunDef false "sitedCall" ((PCon "Loc" (PLit (LString "")) PWild PWild PWild PWild) PWild PWild (PVar "orig")) (EVar "orig"))
(DFunDef false "sitedCall" ((PCon "Loc" PWild (PLit (LInt 1)) (PLit (LInt 0)) (PLit (LInt 1)) (PLit (LInt 0))) PWild PWild (PVar "orig")) (EVar "orig"))
(DFunDef false "sitedCall" ((PCon "Loc" (PVar "f") (PVar "sl") (PVar "sc") PWild PWild) (PVar "fn") (PVar "args") PWild) (EApp (EApp (EVar "applyAll") (EApp (EApp (EVar "EApp") (EVar "fn")) (EApp (EApp (EApp (EVar "siteLiteral") (EVar "f")) (EVar "sl")) (EVar "sc")))) (EVar "args")))
(DTypeSig false "applyAll" (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyCon "Expr"))))
(DFunDef false "applyAll" ((PVar "f") (PList)) (EVar "f"))
(DFunDef false "applyAll" ((PVar "f") (PCons (PVar "x") (PVar "rest"))) (EApp (EApp (EVar "applyAll") (EApp (EApp (EVar "EApp") (EVar "f")) (EVar "x"))) (EVar "rest")))
(DTypeSig false "siteLiteral" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Expr")))))
(DFunDef false "siteLiteral" ((PVar "f") (PVar "line") (PVar "col")) (EApp (EApp (EVar "EApp") (EApp (EApp (EVar "EApp") (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (EVar "siteSentinelName"))) (EApp (EVar "ELit") (EApp (EVar "LString") (EVar "f"))))) (EApp (EVar "ELit") (EApp (EVar "LInt") (EVar "line"))))) (EApp (EVar "ELit") (EApp (EVar "LInt") (EVar "col")))))
(DTypeSig false "isPanicHead" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isPanicHead" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "isPanicHead") (EVar "e")))
(DFunDef false "isPanicHead" ((PCon "EVar" (PLit (LString "panic")))) (EVar "True"))
(DFunDef false "isPanicHead" ((PCon "EVarId" (PLit (LString "panic")) PWild)) (EVar "True"))
(DFunDef false "isPanicHead" ((PCon "EVarAt" (PLit (LString "panic")) (PCon "AGlobal"))) (EVar "True"))
(DFunDef false "isPanicHead" (PWild) (EVar "False"))
(DTypeSig false "indexTwins" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "String"))))
(DFunDef false "indexTwins" ((PVar "names")) (EApp (EApp (EApp (EVar "indexTwinsGo") (EVar "names")) (EListLit (ETuple (ELit (LString "core::Index|(Array a) Int a|")) (ELit (LString "arrayIndexAt"))) (ETuple (ELit (LString "core::Index|(List a) Int a|")) (ELit (LString "listIndexAt"))) (ETuple (ELit (LString "core::Index|String Int Char|")) (ELit (LString "stringIndexAt"))))) (EVar "omEmpty")))
(DTypeSig false "indexTwinsGo" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyApp (TyCon "OrdMap") (TyCon "String"))))))
(DFunDef false "indexTwinsGo" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "indexTwinsGo" ((PVar "names") (PCons (PTuple (PVar "key") (PVar "twin")) (PVar "rest")) (PVar "acc")) (EMatch (EApp (EApp (EVar "preludeFunName") (EVar "names")) (EVar "twin")) (arm (PCon "Some" (PVar "n")) () (EApp (EApp (EApp (EVar "indexTwinsGo") (EVar "names")) (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "key")) (EVar "n")) (EVar "acc")))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "indexTwinsGo") (EVar "names")) (EVar "rest")) (EVar "acc")))))
(DTypeSig false "preludeFunName" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "preludeFunName" ((PVar "names") (PVar "n")) (EIf (EApp (EApp (EVar "omHasKey") (EBinOp "++" (ELit (LString "core__")) (EVar "n"))) (EVar "names")) (EApp (EVar "Some") (EBinOp "++" (ELit (LString "core__")) (EVar "n"))) (EIf (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "names")) (EApp (EVar "Some") (EVar "n")) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "topFunNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit")))))
(DFunDef false "topFunNames" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "topFunNames" ((PCons (PCon "DFunDef" PWild (PVar "n") PWild PWild PWild) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "topFunNames") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (ELit LUnit)) (EVar "acc"))))
(DFunDef false "topFunNames" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "topFunNames") (EBinOp "::" (EVar "d") (EVar "rest"))) (EVar "acc")))
(DFunDef false "topFunNames" ((PCons PWild (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "topFunNames") (EVar "rest")) (EVar "acc")))
(DTypeSig false "indexTwinOf" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "indexTwinOf" ((PVar "twins") (PCon "ELoc" PWild (PVar "h"))) (EApp (EApp (EVar "indexTwinOf") (EVar "twins")) (EVar "h")))
(DFunDef false "indexTwinOf" ((PVar "twins") (PCon "EMethodAt" (PLit (LString "index")) PWild (PVar "ev"))) (EMatch (EApp (EVar "evMethodRoutes") (EVar "ev")) (arm (PTuple PWild PWild (PCon "RKey" (PVar "key") PWild PWild) PWild PWild) () (EApp (EApp (EVar "omLookup") (EVar "key")) (EVar "twins"))) (arm PWild () (EVar "None"))))
(DFunDef false "indexTwinOf" (PWild PWild) (EVar "None"))
(DTypeSig false "declBinders" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "declBinders" ((PRec "DImpl" ((rf "methods" None)) true)) (EApp (EApp (EDictApp "flatMap") (EVar "implMethodBinders")) (EVar "methods")))
(DFunDef false "declBinders" ((PRec "DInterface" ((rf "methods" None)) true)) (EApp (EApp (EDictApp "flatMap") (EVar "ifaceMethodBinders")) (EVar "methods")))
(DFunDef false "declBinders" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "declBinders") (EVar "d")))
(DFunDef false "declBinders" ((PVar "d")) (EBinOp "++" (EApp (EVar "localBoundNames") (EListLit (EVar "d"))) (EApp (EVar "localFunNames") (EVar "d"))))
(DTypeSig false "implMethodBinders" (TyFun (TyCon "ImplMethod") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "implMethodBinders" ((PCon "ImplMethod" (PVar "n") (PVar "ps") (PVar "body"))) (EApp (EVar "declBinders") (EApp (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "False")) (EVar "n")) (EVar "ps")) (EVar "body")) (EVar "noDeclLoc"))))
(DTypeSig false "ifaceMethodBinders" (TyFun (TyCon "IfaceMethod") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "ifaceMethodBinders" ((PCon "IfaceMethod" (PVar "n") PWild (PCon "Some" (PCon "MethodDefault" (PVar "ps") (PVar "body"))) PWild)) (EApp (EVar "declBinders") (EApp (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "False")) (EVar "n")) (EVar "ps")) (EVar "body")) (EVar "noDeclLoc"))))
(DFunDef false "ifaceMethodBinders" (PWild) (EListLit))
(DTypeSig false "localFunNames" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "localFunNames" ((PVar "d")) (EBlock (DoLet false false (PVar "acc") (EApp (EVar "Ref") (EListLit))) (DoLet false false PWild (EApp (EApp (EVar "mapProg") (EApp (EVar "noteLocalFuns") (EVar "acc"))) (EListLit (EVar "d")))) (DoExpr (EUnOp "!" (EVar "acc")))))
(DTypeSig false "noteLocalFuns" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "Expr") (TyCon "Expr"))))
(DFunDef false "noteLocalFuns" ((PVar "acc") (PAs "e" (PCon "ELetGroup" (PVar "binds") PWild))) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EVar "acc")) (EBinOp "++" (EApp (EApp (EMethodRef "map") (EVar "letBindName")) (EVar "binds")) (EUnOp "!" (EVar "acc"))))) (DoExpr (EVar "e"))))
(DFunDef false "noteLocalFuns" (PWild (PVar "e")) (EVar "e"))
(DTypeSig false "letBindName" (TyFun (TyCon "LetBind") (TyCon "String")))
(DFunDef false "letBindName" ((PCon "LetBind" (PVar "n") PWild PWild)) (EVar "n"))
(DTypeSig true "declaredRecordFieldOrders" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "declaredRecordFieldOrders" ((PVar "prog")) (EApp (EApp (EDictApp "flatMap") (EVar "recPatFieldOrderEntries")) (EVar "prog")))
(DTypeSig false "recPatFieldOrderEntries" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "recPatFieldOrderEntries" ((PRec "DData" ((rf "dataCtors" (PVar "variants"))) false)) (EApp (EApp (EDictApp "flatMap") (EVar "variantNamedOrder")) (EVar "variants")))
(DFunDef false "recPatFieldOrderEntries" ((PCon "DAttrib" PWild (PVar "inner"))) (EApp (EVar "recPatFieldOrderEntries") (EVar "inner")))
(DFunDef false "recPatFieldOrderEntries" (PWild) (EListLit))
(DTypeSig false "variantNamedOrder" (TyFun (TyCon "Variant") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "variantNamedOrder" ((PCon "Variant" (PVar "n") (PCon "ConNamed" (PVar "fs") PWild))) (EListLit (ETuple (EVar "n") (EApp (EApp (EMethodRef "map") (EVar "fieldLabel")) (EVar "fs")))))
(DFunDef false "variantNamedOrder" (PWild) (EListLit))
(DTypeSig false "fieldLabel" (TyFun (TyCon "Field") (TyCon "String")))
(DFunDef false "fieldLabel" ((PCon "Field" (PVar "n") PWild)) (EVar "n"))
(DTypeSig false "rewritePat" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyCon "Pat") (TyCon "Pat"))))
(DFunDef false "rewritePat" ((PVar "fo") (PCon "PRec" (PVar "name") (PVar "recFields") PWild)) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "name")) (EVar "fo")) (arm (PCon "Some" (PVar "labels")) () (EApp (EApp (EVar "PCon") (EVar "name")) (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "recPatForLabel") (EVar "fo")) (EVar "recFields"))) (EVar "labels")))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "PRec") (EVar "name")) (EApp (EApp (EMethodRef "map") (EApp (EVar "rewriteRecPatField") (EVar "fo"))) (EVar "recFields"))) (EVar "False")))))
(DFunDef false "rewritePat" ((PVar "fo") (PCon "PCon" (PVar "c") (PVar "args"))) (EApp (EApp (EVar "PCon") (EVar "c")) (EApp (EApp (EMethodRef "map") (EApp (EVar "rewritePat") (EVar "fo"))) (EVar "args"))))
(DFunDef false "rewritePat" ((PVar "fo") (PCon "PCons" (PVar "h") (PVar "t"))) (EApp (EApp (EVar "PCons") (EApp (EApp (EVar "rewritePat") (EVar "fo")) (EVar "h"))) (EApp (EApp (EVar "rewritePat") (EVar "fo")) (EVar "t"))))
(DFunDef false "rewritePat" ((PVar "fo") (PCon "PTuple" (PVar "ps"))) (EApp (EVar "PTuple") (EApp (EApp (EMethodRef "map") (EApp (EVar "rewritePat") (EVar "fo"))) (EVar "ps"))))
(DFunDef false "rewritePat" ((PVar "fo") (PCon "PList" (PVar "ps"))) (EApp (EVar "PList") (EApp (EApp (EMethodRef "map") (EApp (EVar "rewritePat") (EVar "fo"))) (EVar "ps"))))
(DFunDef false "rewritePat" ((PVar "fo") (PCon "PAs" (PVar "x") (PVar "l") (PVar "p"))) (EApp (EApp (EApp (EVar "PAs") (EVar "x")) (EVar "l")) (EApp (EApp (EVar "rewritePat") (EVar "fo")) (EVar "p"))))
(DFunDef false "rewritePat" (PWild (PVar "p")) (EVar "p"))
(DTypeSig false "recPatForLabel" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyApp (TyCon "List") (TyCon "RecPatField")) (TyFun (TyCon "String") (TyCon "Pat")))))
(DFunDef false "recPatForLabel" ((PVar "fo") (PVar "recFields") (PVar "label")) (EMatch (EApp (EApp (EVar "findRecField") (EVar "label")) (EVar "recFields")) (arm (PCon "Some" (PCon "RecPatField" PWild (PVar "fl") (PCon "Some" (PVar "sub")))) () (EApp (EApp (EVar "rewritePat") (EVar "fo")) (EMethodRef "sub"))) (arm (PCon "Some" (PCon "RecPatField" PWild (PVar "fl") (PCon "None"))) () (EApp (EApp (EVar "PVar") (EVar "label")) (EVar "fl"))) (arm (PCon "None") () (EVar "PWild"))))
(DTypeSig false "findRecField" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "RecPatField")) (TyApp (TyCon "Option") (TyCon "RecPatField")))))
(DFunDef false "findRecField" (PWild (PList)) (EVar "None"))
(DFunDef false "findRecField" ((PVar "label") (PCons (PCon "RecPatField" (PVar "l") (PVar "fl") (PVar "sub")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "l") (EVar "label")) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "RecPatField") (EVar "l")) (EVar "fl")) (EMethodRef "sub"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "findRecField") (EVar "label")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "rewriteRecPatField" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyCon "RecPatField") (TyCon "RecPatField"))))
(DFunDef false "rewriteRecPatField" ((PVar "fo") (PCon "RecPatField" (PVar "l") (PVar "fl") (PCon "Some" (PVar "sub")))) (EApp (EApp (EApp (EVar "RecPatField") (EVar "l")) (EVar "fl")) (EApp (EVar "Some") (EApp (EApp (EVar "rewritePat") (EVar "fo")) (EMethodRef "sub")))))
(DFunDef false "rewriteRecPatField" (PWild (PCon "RecPatField" (PVar "l") (PVar "fl") (PCon "None"))) (EApp (EApp (EApp (EVar "RecPatField") (EVar "l")) (EVar "fl")) (EVar "None")))
(DTypeSig false "rewriteProgramRecPats" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyCon "CProgram") (TyCon "CProgram"))))
(DFunDef false "rewriteProgramRecPats" ((PVar "fo") (PCon "CProgram" (PVar "groups") (PVar "ctorArs") (PVar "ctorTypes") (PVar "implEntries"))) (EApp (EApp (EApp (EApp (EVar "CProgram") (EApp (EApp (EMethodRef "map") (EApp (EVar "rewriteBindRP") (EVar "fo"))) (EVar "groups"))) (EVar "ctorArs")) (EVar "ctorTypes")) (EApp (EApp (EMethodRef "map") (EApp (EVar "rewriteImplRP") (EVar "fo"))) (EVar "implEntries"))))
(DTypeSig false "rewriteBindRP" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyCon "CBind") (TyCon "CBind"))))
(DFunDef false "rewriteBindRP" ((PVar "fo") (PCon "CBind" (PVar "n") (PVar "clauses") (PVar "site"))) (EApp (EApp (EApp (EVar "CBind") (EVar "n")) (EApp (EApp (EMethodRef "map") (EApp (EVar "rewriteClauseRP") (EVar "fo"))) (EVar "clauses"))) (EVar "site")))
(DTypeSig false "rewriteClauseRP" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyCon "CClause") (TyCon "CClause"))))
(DFunDef false "rewriteClauseRP" ((PVar "fo") (PCon "CClause" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "CClause") (EApp (EApp (EMethodRef "map") (EApp (EVar "rewritePat") (EVar "fo"))) (EVar "pats"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "body"))))
(DTypeSig false "rewriteImplRP" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyCon "CImplEntry") (TyCon "CImplEntry"))))
(DFunDef false "rewriteImplRP" ((PVar "fo") (PCon "CImplEntry" (PVar "n") (PVar "s") (PCon "CImplTagged" (PVar "tag") (PVar "key") (PVar "iface") (PVar "ps") (PVar "pats") (PVar "body")))) (EApp (EApp (EApp (EVar "CImplEntry") (EVar "n")) (EVar "s")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "CImplTagged") (EVar "tag")) (EVar "key")) (EVar "iface")) (EVar "ps")) (EApp (EApp (EMethodRef "map") (EApp (EVar "rewritePat") (EVar "fo"))) (EVar "pats"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "body")))))
(DFunDef false "rewriteImplRP" ((PVar "fo") (PCon "CImplEntry" (PVar "n") (PVar "s") (PCon "CImplDefault" (PVar "ifaceId") (PVar "tag") (PVar "key") (PVar "ps") (PVar "pats") (PVar "body")))) (EApp (EApp (EApp (EVar "CImplEntry") (EVar "n")) (EVar "s")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "CImplDefault") (EVar "ifaceId")) (EVar "tag")) (EVar "key")) (EVar "ps")) (EApp (EApp (EMethodRef "map") (EApp (EVar "rewritePat") (EVar "fo"))) (EVar "pats"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "body")))))
(DTypeSig false "rewriteExprRP" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyCon "CExpr") (TyCon "CExpr"))))
(DFunDef false "rewriteExprRP" (PWild (PCon "CLit" (PVar "l"))) (EApp (EVar "CLit") (EVar "l")))
(DFunDef false "rewriteExprRP" (PWild (PCon "CVar" (PVar "x") (PVar "addr"))) (EApp (EApp (EVar "CVar") (EVar "x")) (EVar "addr")))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CApp" (PVar "f") (PVar "x"))) (EApp (EApp (EVar "CApp") (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "f"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "x"))))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CLam" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "CLam") (EApp (EApp (EMethodRef "map") (EApp (EVar "rewritePat") (EVar "fo"))) (EVar "pats"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "body"))))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CLet" (PVar "r") (PVar "pat") (PVar "e1") (PVar "e2"))) (EApp (EApp (EApp (EApp (EVar "CLet") (EVar "r")) (EApp (EApp (EVar "rewritePat") (EVar "fo")) (EVar "pat"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "e1"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "e2"))))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CLetGroup" (PVar "binds") (PVar "body"))) (EApp (EApp (EVar "CLetGroup") (EApp (EApp (EMethodRef "map") (EApp (EVar "rewriteBindRP") (EVar "fo"))) (EVar "binds"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "body"))))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CMatch" (PVar "scrut") (PVar "arms"))) (EApp (EApp (EVar "CMatch") (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "scrut"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "rewriteArmRP") (EVar "fo"))) (EVar "arms"))))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CDecision" (PVar "scrut") (PVar "arms") (PVar "tree"))) (EBlock (DoLet false false (PVar "arms2") (EApp (EApp (EMethodRef "map") (EApp (EVar "rewriteArmRP") (EVar "fo"))) (EVar "arms"))) (DoExpr (EApp (EApp (EApp (EVar "CDecision") (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "scrut"))) (EVar "arms2")) (EApp (EApp (EVar "compileArmsC") (EApp (EVar "treeFailSite") (EVar "tree"))) (EVar "arms2"))))))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CIf" (PVar "c") (PVar "t") (PVar "e"))) (EApp (EApp (EApp (EVar "CIf") (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "c"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "t"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "e"))))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CBinPrim" (PVar "op") (PVar "l") (PVar "r") (PVar "tag") (PVar "site"))) (EApp (EApp (EApp (EApp (EApp (EVar "CBinPrim") (EVar "op")) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "l"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "r"))) (EVar "tag")) (EVar "site")))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CUnOp" (PVar "op") (PVar "x"))) (EApp (EApp (EVar "CUnOp") (EVar "op")) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "x"))))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CTuple" (PVar "es"))) (EApp (EVar "CTuple") (EApp (EApp (EMethodRef "map") (EApp (EVar "rewriteExprRP") (EVar "fo"))) (EVar "es"))))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CList" (PVar "es"))) (EApp (EVar "CList") (EApp (EApp (EMethodRef "map") (EApp (EVar "rewriteExprRP") (EVar "fo"))) (EVar "es"))))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CRecord" (PVar "name") (PVar "fields"))) (EApp (EApp (EApp (EVar "normalizeRecordOrder") (EVar "fo")) (EVar "name")) (EApp (EApp (EMethodRef "map") (EApp (EVar "rewriteFieldRP") (EVar "fo"))) (EVar "fields"))))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CFieldAccess" (PVar "ex") (PVar "f") (PVar "n"))) (EApp (EApp (EApp (EVar "CFieldAccess") (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "ex"))) (EVar "f")) (EVar "n")))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CRecordUpdate" (PVar "name") (PVar "base") (PVar "fields"))) (EApp (EApp (EApp (EVar "CRecordUpdate") (EVar "name")) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "base"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "rewriteFieldRP") (EVar "fo"))) (EVar "fields"))))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CVariantUpdate" (PVar "con") (PVar "base") (PVar "fields"))) (EApp (EApp (EApp (EVar "CVariantUpdate") (EVar "con")) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "base"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "rewriteFieldRP") (EVar "fo"))) (EVar "fields"))))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CArray" (PVar "es"))) (EApp (EVar "CArray") (EApp (EApp (EMethodRef "map") (EApp (EVar "rewriteExprRP") (EVar "fo"))) (EVar "es"))))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CRangeList" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EVar "CRangeList") (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "lo"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CRangeArray" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EVar "CRangeArray") (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "lo"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CIndex" (PVar "a") (PVar "i"))) (EApp (EApp (EVar "CIndex") (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "a"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "i"))))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CSlice" (PVar "a") (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EApp (EVar "CSlice") (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "a"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "lo"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CStringIndex" (PVar "a") (PVar "i"))) (EApp (EApp (EVar "CStringIndex") (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "a"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "i"))))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CStringSlice" (PVar "a") (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EApp (EVar "CStringSlice") (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "a"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "lo"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CListIndex" (PVar "a") (PVar "i"))) (EApp (EApp (EVar "CListIndex") (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "a"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "i"))))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CListSlice" (PVar "a") (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EApp (EVar "CListSlice") (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "a"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "lo"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "rewriteExprRP" ((PVar "fo") (PCon "CBlock" (PVar "stmts"))) (EApp (EVar "CBlock") (EApp (EApp (EMethodRef "map") (EApp (EVar "rewriteStmtRP") (EVar "fo"))) (EVar "stmts"))))
(DFunDef false "rewriteExprRP" (PWild (PCon "CMethod" (PVar "name") (PVar "iface") (PVar "arity") (PVar "r") (PVar "ir") (PVar "mr"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "CMethod") (EVar "name")) (EVar "iface")) (EVar "arity")) (EVar "r")) (EVar "ir")) (EVar "mr")))
(DFunDef false "rewriteExprRP" (PWild (PCon "CDict" (PVar "name") (PVar "rs"))) (EApp (EApp (EVar "CDict") (EVar "name")) (EVar "rs")))
(DTypeSig false "rewriteArmRP" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyCon "CArm") (TyCon "CArm"))))
(DFunDef false "rewriteArmRP" ((PVar "fo") (PCon "CArm" (PVar "pat") (PVar "guards") (PVar "body"))) (EApp (EApp (EApp (EVar "CArm") (EApp (EApp (EVar "rewritePat") (EVar "fo")) (EVar "pat"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "rewriteGuardRP") (EVar "fo"))) (EVar "guards"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "body"))))
(DTypeSig false "rewriteGuardRP" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyCon "CGuard") (TyCon "CGuard"))))
(DFunDef false "rewriteGuardRP" ((PVar "fo") (PCon "CGBool" (PVar "e"))) (EApp (EVar "CGBool") (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "e"))))
(DFunDef false "rewriteGuardRP" ((PVar "fo") (PCon "CGBind" (PVar "p") (PVar "e"))) (EApp (EApp (EVar "CGBind") (EApp (EApp (EVar "rewritePat") (EVar "fo")) (EVar "p"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "e"))))
(DTypeSig false "rewriteStmtRP" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyCon "CStmt") (TyCon "CStmt"))))
(DFunDef false "rewriteStmtRP" ((PVar "fo") (PCon "CSExpr" (PVar "e"))) (EApp (EVar "CSExpr") (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "e"))))
(DFunDef false "rewriteStmtRP" ((PVar "fo") (PCon "CSLet" (PVar "r") (PVar "pat") (PVar "e"))) (EApp (EApp (EApp (EVar "CSLet") (EVar "r")) (EApp (EApp (EVar "rewritePat") (EVar "fo")) (EVar "pat"))) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "e"))))
(DFunDef false "rewriteStmtRP" ((PVar "fo") (PCon "CSAssign" (PVar "x") (PVar "e"))) (EApp (EApp (EVar "CSAssign") (EVar "x")) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "e"))))
(DTypeSig false "rewriteFieldRP" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyCon "CField") (TyCon "CField"))))
(DFunDef false "rewriteFieldRP" ((PVar "fo") (PCon "CField" (PVar "k") (PVar "e"))) (EApp (EApp (EVar "CField") (EVar "k")) (EApp (EApp (EVar "rewriteExprRP") (EVar "fo")) (EVar "e"))))
(DTypeSig false "normalizeRecordOrder" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "CField")) (TyCon "CExpr")))))
(DFunDef false "normalizeRecordOrder" ((PVar "fo") (PVar "name") (PVar "fields")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "name")) (EVar "fo")) (arm (PCon "None") () (EApp (EApp (EVar "CRecord") (EVar "name")) (EVar "fields"))) (arm (PCon "Some" (PVar "labels")) () (EBlock (DoLet false false (PVar "written") (EApp (EApp (EMethodRef "map") (EVar "cFieldLabel")) (EVar "fields"))) (DoExpr (EIf (EBinOp "||" (EBinOp "==" (EVar "written") (EVar "labels")) (EApp (EVar "not") (EApp (EApp (EVar "isPermutationOf") (EVar "written")) (EVar "labels")))) (EApp (EApp (EVar "CRecord") (EVar "name")) (EVar "fields")) (EApp (EApp (EVar "bindFieldTemps") (EVar "fields")) (EApp (EApp (EVar "CRecord") (EVar "name")) (EApp (EApp (EMethodRef "map") (EVar "recTempField")) (EVar "labels"))))))))))
(DTypeSig false "isPermutationOf" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "isPermutationOf" ((PVar "written") (PVar "labels")) (EBinOp "&&" (EBinOp "==" (EApp (EVar "listLen") (EVar "written")) (EApp (EVar "listLen") (EVar "labels"))) (EApp (EApp (EVar "allList") (ELam ((PVar "l")) (EApp (EApp (EVar "contains") (EVar "l")) (EVar "written")))) (EVar "labels"))))
(DTypeSig false "cFieldLabel" (TyFun (TyCon "CField") (TyCon "String")))
(DFunDef false "cFieldLabel" ((PCon "CField" (PVar "k") PWild)) (EVar "k"))
(DTypeSig false "recTempName" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "recTempName" ((PVar "label")) (EBinOp "++" (ELit (LString "$rf$")) (EVar "label")))
(DTypeSig false "recTempField" (TyFun (TyCon "String") (TyCon "CField")))
(DFunDef false "recTempField" ((PVar "label")) (EApp (EApp (EVar "CField") (EVar "label")) (EApp (EApp (EVar "CVar") (EApp (EVar "recTempName") (EVar "label"))) (EVar "AGlobal"))))
(DTypeSig false "bindFieldTemps" (TyFun (TyApp (TyCon "List") (TyCon "CField")) (TyFun (TyCon "CExpr") (TyCon "CExpr"))))
(DFunDef false "bindFieldTemps" ((PList) (PVar "body")) (EVar "body"))
(DFunDef false "bindFieldTemps" ((PCons (PCon "CField" (PVar "k") (PVar "ex")) (PVar "rest")) (PVar "body")) (EApp (EApp (EApp (EApp (EVar "CLet") (EVar "False")) (EApp (EApp (EVar "PVar") (EApp (EVar "recTempName") (EVar "k"))) (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString ""))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))))) (EVar "ex")) (EApp (EApp (EVar "bindFieldTemps") (EVar "rest")) (EVar "body"))))
(DTypeSig false "memoKeys" (TyFun (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String")))))
(DFunDef false "memoKeys" ((PVar "entries")) (EApp (EApp (EVar "memoKeysGo") (EVar "entries")) (EVar "entries")))
(DTypeSig false "memoKeysGo" (TyFun (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyFun (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String"))))))
(DFunDef false "memoKeysGo" (PWild (PList)) (EListLit))
(DFunDef false "memoKeysGo" ((PVar "all") (PCons (PCon "CImplEntry" (PVar "m") PWild (PCon "CImplTagged" (PVar "tag") (PVar "key") PWild (PVar "positions") (PVar "pats") PWild)) (PVar "rest"))) (EIf (EBinOp "&&" (EApp (EVar "isEmptyL") (EVar "positions")) (EApp (EVar "isEmptyL") (EVar "pats"))) (EBinOp "::" (ETuple (EVar "m") (EVar "key") (EApp (EApp (EApp (EApp (EVar "memoSelector") (EDictApp "all")) (EVar "m")) (EVar "tag")) (EVar "key"))) (EApp (EApp (EVar "memoKeysGo") (EDictApp "all")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "memoKeysGo" ((PVar "all") (PCons (PCon "CImplEntry" (PVar "m") PWild (PCon "CImplDefault" PWild (PVar "tag") (PVar "key") (PVar "positions") (PVar "pats") PWild)) (PVar "rest"))) (EIf (EBinOp "&&" (EApp (EVar "isEmptyL") (EVar "positions")) (EApp (EVar "isEmptyL") (EVar "pats"))) (EBinOp "::" (ETuple (EVar "m") (EVar "key") (EApp (EApp (EApp (EApp (EVar "memoSelector") (EDictApp "all")) (EVar "m")) (EVar "tag")) (EVar "key"))) (EApp (EApp (EVar "memoKeysGo") (EDictApp "all")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "memoKeysGo" ((PVar "all") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "memoKeysGo") (EDictApp "all")) (EVar "rest")))
(DTypeSig false "memoSelector" (TyFun (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))))
(DFunDef false "memoSelector" ((PVar "all") (PVar "method") (PVar "tag") (PVar "key")) (EIf (EApp (EApp (EApp (EVar "headTagUniqueL") (EDictApp "all")) (EVar "method")) (EVar "tag")) (EVar "tag") (EVar "key")))
(DTypeSig false "headTagUniqueL" (TyFun (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool")))))
(DFunDef false "headTagUniqueL" ((PVar "entries") (PVar "method") (PVar "tag")) (EBinOp "<=" (EApp (EVar "listLen") (EApp (EApp (EApp (EApp (EVar "distinctKeysAtHeadL") (EVar "entries")) (EVar "method")) (EVar "tag")) (EListLit))) (ELit (LInt 1))))
(DTypeSig false "distinctKeysAtHeadL" (TyFun (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "distinctKeysAtHeadL" ((PList) PWild PWild (PVar "acc")) (EVar "acc"))
(DFunDef false "distinctKeysAtHeadL" ((PCons (PCon "CImplEntry" (PVar "n") PWild (PCon "CImplTagged" (PVar "t") (PVar "k") PWild PWild PWild PWild)) (PVar "rest")) (PVar "method") (PVar "tag") (PVar "acc")) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "n") (EVar "method")) (EBinOp "==" (EVar "t") (EVar "tag"))) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EVar "k")) (EVar "acc")))) (EApp (EApp (EApp (EApp (EVar "distinctKeysAtHeadL") (EVar "rest")) (EVar "method")) (EVar "tag")) (EBinOp "::" (EVar "k") (EVar "acc"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "distinctKeysAtHeadL") (EVar "rest")) (EVar "method")) (EVar "tag")) (EVar "acc")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "distinctKeysAtHeadL" ((PCons (PCon "CImplEntry" (PVar "n") PWild (PCon "CImplDefault" PWild (PVar "t") (PVar "k") PWild PWild PWild)) (PVar "rest")) (PVar "method") (PVar "tag") (PVar "acc")) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "n") (EVar "method")) (EBinOp "==" (EVar "t") (EVar "tag"))) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EVar "k")) (EVar "acc")))) (EApp (EApp (EApp (EApp (EVar "distinctKeysAtHeadL") (EVar "rest")) (EVar "method")) (EVar "tag")) (EBinOp "::" (EVar "k") (EVar "acc"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "distinctKeysAtHeadL") (EVar "rest")) (EVar "method")) (EVar "tag")) (EVar "acc")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "distinctKeysAtHeadL" ((PCons PWild (PVar "rest")) (PVar "method") (PVar "tag") (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "distinctKeysAtHeadL") (EVar "rest")) (EVar "method")) (EVar "tag")) (EVar "acc")))
(DTypeSig false "memoSelectorOf" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "memoSelectorOf" ((PList) PWild PWild) (EVar "None"))
(DFunDef false "memoSelectorOf" ((PCons (PTuple (PVar "m2") (PVar "k2") (PVar "sel")) (PVar "rest")) (PVar "m") (PVar "key")) (EIf (EBinOp "&&" (EBinOp "==" (EVar "m") (EVar "m2")) (EBinOp "==" (EVar "key") (EVar "k2"))) (EApp (EVar "Some") (EVar "sel")) (EApp (EApp (EApp (EVar "memoSelectorOf") (EVar "rest")) (EVar "m")) (EVar "key"))))
(DTypeSig false "soleMemoKeys" (TyFun (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "soleMemoKeys" (PWild (PList)) (EListLit))
(DFunDef false "soleMemoKeys" ((PVar "entries") (PCons (PTuple (PVar "m") (PVar "key") (PVar "sel")) (PVar "rest"))) (EIf (EBinOp "==" (EApp (EApp (EApp (EVar "taggedImplCount") (EVar "entries")) (EVar "m")) (ELit (LInt 1))) (ELit (LInt 1))) (EBinOp "::" (ETuple (EVar "m") (ETuple (EVar "key") (EVar "sel"))) (EApp (EApp (EVar "soleMemoKeys") (EVar "entries")) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "soleMemoKeys") (EVar "entries")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "taggedImplCount" (TyFun (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "taggedImplCount" ((PVar "entries") (PVar "method") (PVar "cap")) (EApp (EVar "listLen") (EApp (EApp (EApp (EApp (EVar "distinctImplKeysL") (EVar "entries")) (EVar "method")) (EVar "cap")) (EListLit))))
(DTypeSig false "distinctImplKeysL" (TyFun (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "distinctImplKeysL" ((PList) PWild PWild (PVar "acc")) (EVar "acc"))
(DFunDef false "distinctImplKeysL" (PWild PWild (PVar "cap") (PVar "acc")) (EIf (EBinOp ">" (EApp (EVar "listLen") (EVar "acc")) (EVar "cap")) (EVar "acc") (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "distinctImplKeysL" ((PCons (PCon "CImplEntry" (PVar "n") PWild (PCon "CImplTagged" PWild (PVar "k") PWild PWild PWild PWild)) (PVar "rest")) (PVar "method") (PVar "cap") (PVar "acc")) (EIf (EBinOp "&&" (EBinOp "==" (EVar "n") (EVar "method")) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EVar "k")) (EVar "acc")))) (EApp (EApp (EApp (EApp (EVar "distinctImplKeysL") (EVar "rest")) (EVar "method")) (EVar "cap")) (EBinOp "::" (EVar "k") (EVar "acc"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "distinctImplKeysL") (EVar "rest")) (EVar "method")) (EVar "cap")) (EVar "acc")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "distinctImplKeysL" ((PCons (PCon "CImplEntry" (PVar "n") PWild (PCon "CImplDefault" PWild PWild (PVar "k") PWild PWild PWild)) (PVar "rest")) (PVar "method") (PVar "cap") (PVar "acc")) (EIf (EBinOp "&&" (EBinOp "==" (EVar "n") (EVar "method")) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EVar "k")) (EVar "acc")))) (EApp (EApp (EApp (EApp (EVar "distinctImplKeysL") (EVar "rest")) (EVar "method")) (EVar "cap")) (EBinOp "::" (EVar "k") (EVar "acc"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "distinctImplKeysL") (EVar "rest")) (EVar "method")) (EVar "cap")) (EVar "acc")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "distinctImplKeysL" ((PCons PWild (PVar "rest")) (PVar "method") (PVar "cap") (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "distinctImplKeysL") (EVar "rest")) (EVar "method")) (EVar "cap")) (EVar "acc")))
(DData Private "LowerState" () ((variant "LowerState" (ConNamed (field "memoKeysAll" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String")))) (field "soleKeys" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyCon "String") (TyCon "String"))))) (field "memoRefs" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String")))))))) ())
(DTypeSig false "memoBindName" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "memoBindName" ((PVar "selector") (PVar "method")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "$memo_")) (EApp (EMethodRef "display") (EApp (EVar "injectiveIdent") (EVar "selector")))) (ELit (LString "_"))) (EApp (EMethodRef "display") (EVar "method"))) (ELit (LString ""))))
(DTypeSig false "recordMemoRef" (TyFun (TyCon "LowerState") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Unit"))))))
(DFunDef false "recordMemoRef" ((PVar "st") (PVar "sel") (PVar "key") (PVar "method")) (ELet false (PVar "refs") (EFieldAccess (EVar "st") "memoRefs") (EApp (EApp (EVar "setRef") (EVar "refs")) (EBinOp "::" (ETuple (EVar "sel") (EVar "key") (EVar "method")) (EUnOp "!" (EVar "refs"))))))
(DTypeSig false "hoistDictNullary" (TyFun (TyCon "LowerState") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Route") (TyCon "CExpr"))))))
(DFunDef false "hoistDictNullary" ((PVar "st") (PVar "name") (PVar "iface") (PVar "route")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "name")) (EFieldAccess (EVar "st") "soleKeys")) (arm (PCon "Some" (PTuple (PVar "key") (PVar "sel"))) () (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "recordMemoRef") (EVar "st")) (EVar "sel")) (EVar "key")) (EVar "name"))) (DoExpr (EApp (EApp (EVar "CVar") (EApp (EApp (EVar "memoBindName") (EVar "sel")) (EVar "name"))) (EVar "AGlobal"))))) (arm (PCon "None") () (EBlock (DoLet false false PWild (EApp (EApp (EVar "recordMultiImplMemo") (EVar "st")) (EVar "name"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "CMethod") (EVar "name")) (EVar "iface")) (ELit (LInt 0))) (EVar "route")) (EListLit)) (EListLit)))))))
(DTypeSig false "recordMultiImplMemo" (TyFun (TyCon "LowerState") (TyFun (TyCon "String") (TyCon "Unit"))))
(DFunDef false "recordMultiImplMemo" ((PVar "st") (PVar "name")) (EApp (EApp (EApp (EVar "recordMultiImplMemoGo") (EVar "st")) (EVar "name")) (EFieldAccess (EVar "st") "memoKeysAll")))
(DTypeSig false "recordMultiImplMemoGo" (TyFun (TyCon "LowerState") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String"))) (TyCon "Unit")))))
(DFunDef false "recordMultiImplMemoGo" (PWild PWild (PList)) (ELit LUnit))
(DFunDef false "recordMultiImplMemoGo" ((PVar "st") (PVar "name") (PCons (PTuple (PVar "m") (PVar "key") (PVar "sel")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "m") (EVar "name")) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "recordMemoRef") (EVar "st")) (EVar "sel")) (EVar "key")) (EVar "name"))) (DoExpr (EApp (EApp (EApp (EVar "recordMultiImplMemoGo") (EVar "st")) (EVar "name")) (EVar "rest")))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "recordMultiImplMemoGo") (EVar "st")) (EVar "name")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "hoistNullaryMemo" (TyFun (TyCon "CProgram") (TyCon "CProgram")))
(DFunDef false "hoistNullaryMemo" ((PCon "CProgram" (PVar "groups") (PVar "ctorArs") (PVar "ctorTypes") (PVar "implEntries"))) (EBlock (DoLet false false (PVar "keys") (EApp (EVar "memoKeys") (EVar "implEntries"))) (DoExpr (EIf (EApp (EVar "isEmptyL") (EVar "keys")) (EApp (EApp (EApp (EApp (EVar "CProgram") (EVar "groups")) (EVar "ctorArs")) (EVar "ctorTypes")) (EVar "implEntries")) (EBlock (DoLet false false (PVar "st") (ERecordCreate "LowerState" ((fa "memoKeysAll" (EVar "keys")) (fa "soleKeys" (EApp (EApp (EVar "soleMemoKeys") (EVar "implEntries")) (EVar "keys"))) (fa "memoRefs" (EApp (EVar "Ref") (EListLit)))))) (DoLet false false (PVar "groups2") (EApp (EApp (EMethodRef "map") (EApp (EVar "hoistBind") (EVar "st"))) (EVar "groups"))) (DoLet false false (PVar "impls2") (EApp (EApp (EMethodRef "map") (EApp (EVar "hoistImpl") (EVar "st"))) (EVar "implEntries"))) (DoLet false false (PVar "refs") (EApp (EVar "dedupPairs") (EApp (EVar "reverseL") (EUnOp "!" (EFieldAccess (EVar "st") "memoRefs"))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "CProgram") (EBinOp "++" (EApp (EApp (EMethodRef "map") (EVar "memoCafBind")) (EVar "refs")) (EVar "groups2"))) (EVar "ctorArs")) (EVar "ctorTypes")) (EVar "impls2"))))))))
(DTypeSig false "memoCafBind" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyCon "String")) (TyCon "CBind")))
(DFunDef false "memoCafBind" ((PTuple (PVar "sel") (PVar "key") (PVar "method"))) (EApp (EApp (EApp (EVar "CBind") (EApp (EApp (EVar "memoBindName") (EVar "sel")) (EVar "method"))) (EListLit (EApp (EApp (EVar "CClause") (EListLit)) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "CMethod") (EVar "method")) (ELit (LString ""))) (ELit (LInt 0))) (EApp (EApp (EApp (EVar "RKey") (EVar "key")) (EListLit)) (EListLit))) (EListLit)) (EListLit))))) (EVar "noDeclLoc")))
(DTypeSig false "dedupPairs" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String")))))
(DFunDef false "dedupPairs" ((PVar "ps")) (EApp (EApp (EVar "dedupBy") (EVar "memoRefKey")) (EVar "ps")))
(DTypeSig false "memoRefKey" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyCon "String")) (TyCon "String")))
(DFunDef false "memoRefKey" ((PTuple (PVar "sel") PWild (PVar "method"))) (EBinOp "++" (EApp (EVar "lenKey") (EVar "sel")) (EVar "method")))
(DTypeSig false "hoistBind" (TyFun (TyCon "LowerState") (TyFun (TyCon "CBind") (TyCon "CBind"))))
(DFunDef false "hoistBind" ((PVar "st") (PCon "CBind" (PVar "n") (PVar "clauses") (PVar "site"))) (EApp (EApp (EApp (EVar "CBind") (EVar "n")) (EApp (EApp (EMethodRef "map") (EApp (EVar "hoistClause") (EVar "st"))) (EVar "clauses"))) (EVar "site")))
(DTypeSig false "hoistClause" (TyFun (TyCon "LowerState") (TyFun (TyCon "CClause") (TyCon "CClause"))))
(DFunDef false "hoistClause" ((PVar "st") (PCon "CClause" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "CClause") (EVar "pats")) (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "body"))))
(DTypeSig false "hoistImpl" (TyFun (TyCon "LowerState") (TyFun (TyCon "CImplEntry") (TyCon "CImplEntry"))))
(DFunDef false "hoistImpl" ((PVar "st") (PCon "CImplEntry" (PVar "n") (PVar "s") (PCon "CImplTagged" (PVar "tag") (PVar "key") (PVar "iface") (PVar "pos") (PVar "pats") (PVar "body")))) (EApp (EApp (EApp (EVar "CImplEntry") (EVar "n")) (EVar "s")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "CImplTagged") (EVar "tag")) (EVar "key")) (EVar "iface")) (EVar "pos")) (EVar "pats")) (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "body")))))
(DFunDef false "hoistImpl" ((PVar "st") (PCon "CImplEntry" (PVar "n") (PVar "s") (PCon "CImplDefault" (PVar "ifaceId") (PVar "tag") (PVar "key") (PVar "pos") (PVar "pats") (PVar "body")))) (EApp (EApp (EApp (EVar "CImplEntry") (EVar "n")) (EVar "s")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "CImplDefault") (EVar "ifaceId")) (EVar "tag")) (EVar "key")) (EVar "pos")) (EVar "pats")) (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "body")))))
(DTypeSig false "hoistExpr" (TyFun (TyCon "LowerState") (TyFun (TyCon "CExpr") (TyCon "CExpr"))))
(DFunDef false "hoistExpr" ((PVar "st") (PCon "CMethod" (PVar "name") (PVar "iface") (PLit (LInt 0)) (PCon "RKey" (PVar "key") (PList) (PVar "sups")) (PList) (PList))) (EMatch (EApp (EApp (EApp (EVar "memoSelectorOf") (EFieldAccess (EVar "st") "memoKeysAll")) (EVar "name")) (EVar "key")) (arm (PCon "Some" (PVar "sel")) () (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "recordMemoRef") (EVar "st")) (EVar "sel")) (EVar "key")) (EVar "name"))) (DoExpr (EApp (EApp (EVar "CVar") (EApp (EApp (EVar "memoBindName") (EVar "sel")) (EVar "name"))) (EVar "AGlobal"))))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "CMethod") (EVar "name")) (EVar "iface")) (ELit (LInt 0))) (EApp (EApp (EApp (EVar "RKey") (EVar "key")) (EListLit)) (EVar "sups"))) (EListLit)) (EListLit)))))
(DFunDef false "hoistExpr" ((PVar "st") (PCon "CMethod" (PVar "name") (PVar "iface") (PLit (LInt 0)) (PCon "RDict" (PVar "d")) (PList) (PList))) (EApp (EApp (EApp (EApp (EVar "hoistDictNullary") (EVar "st")) (EVar "name")) (EVar "iface")) (EApp (EVar "RDict") (EVar "d"))))
(DFunDef false "hoistExpr" ((PVar "st") (PCon "CMethod" (PVar "name") (PVar "iface") (PLit (LInt 0)) (PCon "RDictFwd" (PVar "d")) (PList) (PList))) (EApp (EApp (EApp (EApp (EVar "hoistDictNullary") (EVar "st")) (EVar "name")) (EVar "iface")) (EApp (EVar "RDictFwd") (EVar "d"))))
(DFunDef false "hoistExpr" ((PVar "st") (PCon "CMethod" (PVar "name") (PVar "iface") (PLit (LInt 0)) (PCon "RProj" (PVar "r") (PVar "path")) (PList) (PList))) (EApp (EApp (EApp (EApp (EVar "hoistDictNullary") (EVar "st")) (EVar "name")) (EVar "iface")) (EApp (EApp (EVar "RProj") (EVar "r")) (EVar "path"))))
(DFunDef false "hoistExpr" (PWild (PCon "CMethod" (PVar "name") (PVar "iface") (PVar "arity") (PVar "r") (PVar "ir") (PVar "mr"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "CMethod") (EVar "name")) (EVar "iface")) (EVar "arity")) (EVar "r")) (EVar "ir")) (EVar "mr")))
(DFunDef false "hoistExpr" (PWild (PCon "CLit" (PVar "l"))) (EApp (EVar "CLit") (EVar "l")))
(DFunDef false "hoistExpr" (PWild (PCon "CVar" (PVar "x") (PVar "addr"))) (EApp (EApp (EVar "CVar") (EVar "x")) (EVar "addr")))
(DFunDef false "hoistExpr" ((PVar "st") (PCon "CApp" (PVar "f") (PVar "x"))) (EApp (EApp (EVar "CApp") (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "f"))) (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "x"))))
(DFunDef false "hoistExpr" ((PVar "st") (PCon "CLam" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "CLam") (EVar "pats")) (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "body"))))
(DFunDef false "hoistExpr" ((PVar "st") (PCon "CLet" (PVar "r") (PVar "pat") (PVar "e1") (PVar "e2"))) (EApp (EApp (EApp (EApp (EVar "CLet") (EVar "r")) (EVar "pat")) (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "e1"))) (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "e2"))))
(DFunDef false "hoistExpr" ((PVar "st") (PCon "CLetGroup" (PVar "binds") (PVar "body"))) (EApp (EApp (EVar "CLetGroup") (EApp (EApp (EMethodRef "map") (EApp (EVar "hoistBind") (EVar "st"))) (EVar "binds"))) (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "body"))))
(DFunDef false "hoistExpr" ((PVar "st") (PCon "CMatch" (PVar "scrut") (PVar "arms"))) (EApp (EApp (EVar "CMatch") (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "scrut"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "hoistArm") (EVar "st"))) (EVar "arms"))))
(DFunDef false "hoistExpr" ((PVar "st") (PCon "CDecision" (PVar "scrut") (PVar "arms") (PVar "tree"))) (EApp (EApp (EApp (EVar "CDecision") (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "scrut"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "hoistArm") (EVar "st"))) (EVar "arms"))) (EVar "tree")))
(DFunDef false "hoistExpr" ((PVar "st") (PCon "CIf" (PVar "c") (PVar "t") (PVar "e"))) (EApp (EApp (EApp (EVar "CIf") (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "c"))) (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "t"))) (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "e"))))
(DFunDef false "hoistExpr" ((PVar "st") (PCon "CBinPrim" (PVar "op") (PVar "l") (PVar "r") (PVar "tag") (PVar "site"))) (EApp (EApp (EApp (EApp (EApp (EVar "CBinPrim") (EVar "op")) (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "l"))) (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "r"))) (EVar "tag")) (EVar "site")))
(DFunDef false "hoistExpr" ((PVar "st") (PCon "CUnOp" (PVar "op") (PVar "x"))) (EApp (EApp (EVar "CUnOp") (EVar "op")) (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "x"))))
(DFunDef false "hoistExpr" ((PVar "st") (PCon "CTuple" (PVar "es"))) (EApp (EVar "CTuple") (EApp (EApp (EMethodRef "map") (EApp (EVar "hoistExpr") (EVar "st"))) (EVar "es"))))
(DFunDef false "hoistExpr" ((PVar "st") (PCon "CList" (PVar "es"))) (EApp (EVar "CList") (EApp (EApp (EMethodRef "map") (EApp (EVar "hoistExpr") (EVar "st"))) (EVar "es"))))
(DFunDef false "hoistExpr" ((PVar "st") (PCon "CRecord" (PVar "name") (PVar "fields"))) (EApp (EApp (EVar "CRecord") (EVar "name")) (EApp (EApp (EMethodRef "map") (EApp (EVar "hoistField") (EVar "st"))) (EVar "fields"))))
(DFunDef false "hoistExpr" ((PVar "st") (PCon "CFieldAccess" (PVar "ex") (PVar "f") (PVar "n"))) (EApp (EApp (EApp (EVar "CFieldAccess") (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "ex"))) (EVar "f")) (EVar "n")))
(DFunDef false "hoistExpr" ((PVar "st") (PCon "CRecordUpdate" (PVar "name") (PVar "base") (PVar "fields"))) (EApp (EApp (EApp (EVar "CRecordUpdate") (EVar "name")) (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "base"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "hoistField") (EVar "st"))) (EVar "fields"))))
(DFunDef false "hoistExpr" ((PVar "st") (PCon "CVariantUpdate" (PVar "con") (PVar "base") (PVar "fields"))) (EApp (EApp (EApp (EVar "CVariantUpdate") (EVar "con")) (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "base"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "hoistField") (EVar "st"))) (EVar "fields"))))
(DFunDef false "hoistExpr" ((PVar "st") (PCon "CArray" (PVar "es"))) (EApp (EVar "CArray") (EApp (EApp (EMethodRef "map") (EApp (EVar "hoistExpr") (EVar "st"))) (EVar "es"))))
(DFunDef false "hoistExpr" ((PVar "st") (PCon "CRangeList" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EVar "CRangeList") (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "lo"))) (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "hoistExpr" ((PVar "st") (PCon "CRangeArray" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EVar "CRangeArray") (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "lo"))) (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "hoistExpr" ((PVar "st") (PCon "CIndex" (PVar "a") (PVar "i"))) (EApp (EApp (EVar "CIndex") (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "a"))) (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "i"))))
(DFunDef false "hoistExpr" ((PVar "st") (PCon "CSlice" (PVar "a") (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EApp (EVar "CSlice") (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "a"))) (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "lo"))) (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "hoistExpr" ((PVar "st") (PCon "CStringIndex" (PVar "a") (PVar "i"))) (EApp (EApp (EVar "CStringIndex") (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "a"))) (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "i"))))
(DFunDef false "hoistExpr" ((PVar "st") (PCon "CStringSlice" (PVar "a") (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EApp (EVar "CStringSlice") (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "a"))) (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "lo"))) (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "hoistExpr" ((PVar "st") (PCon "CListIndex" (PVar "a") (PVar "i"))) (EApp (EApp (EVar "CListIndex") (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "a"))) (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "i"))))
(DFunDef false "hoistExpr" ((PVar "st") (PCon "CListSlice" (PVar "a") (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EApp (EVar "CListSlice") (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "a"))) (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "lo"))) (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "hoistExpr" ((PVar "st") (PCon "CBlock" (PVar "stmts"))) (EApp (EVar "CBlock") (EApp (EApp (EMethodRef "map") (EApp (EVar "hoistStmt") (EVar "st"))) (EVar "stmts"))))
(DFunDef false "hoistExpr" (PWild (PCon "CDict" (PVar "name") (PVar "rs"))) (EApp (EApp (EVar "CDict") (EVar "name")) (EVar "rs")))
(DTypeSig false "hoistArm" (TyFun (TyCon "LowerState") (TyFun (TyCon "CArm") (TyCon "CArm"))))
(DFunDef false "hoistArm" ((PVar "st") (PCon "CArm" (PVar "pat") (PVar "guards") (PVar "body"))) (EApp (EApp (EApp (EVar "CArm") (EVar "pat")) (EApp (EApp (EMethodRef "map") (EApp (EVar "hoistGuard") (EVar "st"))) (EVar "guards"))) (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "body"))))
(DTypeSig false "hoistGuard" (TyFun (TyCon "LowerState") (TyFun (TyCon "CGuard") (TyCon "CGuard"))))
(DFunDef false "hoistGuard" ((PVar "st") (PCon "CGBool" (PVar "e"))) (EApp (EVar "CGBool") (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "e"))))
(DFunDef false "hoistGuard" ((PVar "st") (PCon "CGBind" (PVar "p") (PVar "e"))) (EApp (EApp (EVar "CGBind") (EVar "p")) (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "e"))))
(DTypeSig false "hoistStmt" (TyFun (TyCon "LowerState") (TyFun (TyCon "CStmt") (TyCon "CStmt"))))
(DFunDef false "hoistStmt" ((PVar "st") (PCon "CSExpr" (PVar "e"))) (EApp (EVar "CSExpr") (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "e"))))
(DFunDef false "hoistStmt" ((PVar "st") (PCon "CSLet" (PVar "r") (PVar "pat") (PVar "e"))) (EApp (EApp (EApp (EVar "CSLet") (EVar "r")) (EVar "pat")) (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "e"))))
(DFunDef false "hoistStmt" ((PVar "st") (PCon "CSAssign" (PVar "x") (PVar "e"))) (EApp (EApp (EVar "CSAssign") (EVar "x")) (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "e"))))
(DTypeSig false "hoistField" (TyFun (TyCon "LowerState") (TyFun (TyCon "CField") (TyCon "CField"))))
(DFunDef false "hoistField" ((PVar "st") (PCon "CField" (PVar "k") (PVar "e"))) (EApp (EApp (EVar "CField") (EVar "k")) (EApp (EApp (EVar "hoistExpr") (EVar "st")) (EVar "e"))))
(DTypeSig false "compileArmsC" (TyFun (TyCon "FailSite") (TyFun (TyApp (TyCon "List") (TyCon "CArm")) (TyCon "CTree"))))
(DFunDef false "compileArmsC" ((PVar "site") (PVar "arms")) (EApp (EApp (EApp (EVar "compileTree") (EVar "site")) (EApp (EApp (EMethodRef "map") (EVar "carmHasGuard")) (EVar "arms"))) (EApp (EApp (EVar "cInitialRows") (EVar "arms")) (ELit (LInt 0)))))
(DTypeSig false "carmHasGuard" (TyFun (TyCon "CArm") (TyCon "Bool")))
(DFunDef false "carmHasGuard" ((PCon "CArm" (PVar "pat") (PVar "gs") PWild)) (EBinOp "||" (EApp (EVar "isNonEmptyL") (EVar "gs")) (EApp (EVar "patNeedsGuard") (EVar "pat"))))
(DTypeSig false "cInitialRows" (TyFun (TyApp (TyCon "List") (TyCon "CArm")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int"))))))
(DFunDef false "cInitialRows" ((PList) PWild) (EListLit))
(DFunDef false "cInitialRows" ((PCons (PCon "CArm" (PVar "pat") PWild PWild) (PVar "rest")) (PVar "i")) (EBinOp "::" (ETuple (EListLit (EApp (EVar "canonPat") (EVar "pat"))) (EVar "i")) (EApp (EApp (EVar "cInitialRows") (EVar "rest")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))
(DTypeSig true "lowerGroups" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "CBind"))))
(DFunDef false "lowerGroups" ((PVar "prog")) (EApp (EApp (EMethodRef "map") (EApp (EVar "refoldBind") (EVar "noLetCheck"))) (EApp (EVar "lowerGroupsRaw") (EVar "prog"))))
(DTypeSig false "lowerGroupsRaw" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "CBind"))))
(DFunDef false "lowerGroupsRaw" ((PVar "prog")) (EApp (EApp (EVar "lgGroup") (EApp (EApp (EVar "bindSites") (EVar "prog")) (EVar "omEmpty"))) (EApp (EVar "funClausesOf") (EVar "prog"))))
(DTypeSig false "lgGroup" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Loc")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "CClause"))) (TyApp (TyCon "List") (TyCon "CBind")))))
(DFunDef false "lgGroup" ((PVar "sites") (PVar "clauses")) (EBlock (DoLet false false (PVar "groups") (EApp (EVar "lgRuns") (EApp (EVar "lgSortName") (EApp (EApp (EVar "lgTag") (EVar "clauses")) (ELit (LInt 0)))))) (DoExpr (EApp (EApp (EMethodRef "map") (EApp (EVar "lgToBind") (EVar "sites"))) (EApp (EVar "lgSortIdx") (EVar "groups"))))))
(DTypeSig false "lgTag" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "CClause"))) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "Int")) (TyCon "CClause"))))))
(DFunDef false "lgTag" ((PList) PWild) (EListLit))
(DFunDef false "lgTag" ((PCons (PTuple (PVar "n") (PVar "c")) (PVar "rest")) (PVar "i")) (EBinOp "::" (ETuple (ETuple (EVar "n") (EVar "i")) (EVar "c")) (EApp (EApp (EVar "lgTag") (EVar "rest")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))
(DTypeSig false "lgSplit" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyTuple (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "lgSplit" ((PList)) (ETuple (EListLit) (EListLit)))
(DFunDef false "lgSplit" ((PList (PVar "x"))) (ETuple (EListLit (EVar "x")) (EListLit)))
(DFunDef false "lgSplit" ((PCons (PVar "x") (PCons (PVar "y") (PVar "rest")))) (EBlock (DoLet false false (PTuple (PVar "a") (PVar "b")) (EApp (EVar "lgSplit") (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EVar "x") (EVar "a")) (EBinOp "::" (EVar "y") (EVar "b"))))))
(DTypeSig false "lgSortName" (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "Int")) (TyCon "CClause"))) (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "Int")) (TyCon "CClause")))))
(DFunDef false "lgSortName" ((PList)) (EListLit))
(DFunDef false "lgSortName" ((PList (PVar "x"))) (EListLit (EVar "x")))
(DFunDef false "lgSortName" ((PVar "xs")) (EBlock (DoLet false false (PTuple (PVar "a") (PVar "b")) (EApp (EVar "lgSplit") (EVar "xs"))) (DoExpr (EApp (EApp (EVar "lgMergeName") (EApp (EVar "lgSortName") (EVar "a"))) (EApp (EVar "lgSortName") (EVar "b"))))))
(DTypeSig false "lgMergeName" (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "Int")) (TyCon "CClause"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "Int")) (TyCon "CClause"))) (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "Int")) (TyCon "CClause"))))))
(DFunDef false "lgMergeName" ((PList) (PVar "ys")) (EVar "ys"))
(DFunDef false "lgMergeName" ((PVar "xs") (PList)) (EVar "xs"))
(DFunDef false "lgMergeName" ((PCons (PTuple (PTuple (PVar "n1") (PVar "i1")) (PVar "c1")) (PVar "xs")) (PCons (PTuple (PTuple (PVar "n2") (PVar "i2")) (PVar "c2")) (PVar "ys"))) (EMatch (EApp (EApp (EVar "stringCompare") (EVar "n1")) (EVar "n2")) (arm (PCon "Lt") () (EBinOp "::" (ETuple (ETuple (EVar "n1") (EVar "i1")) (EVar "c1")) (EApp (EApp (EVar "lgMergeName") (EVar "xs")) (EBinOp "::" (ETuple (ETuple (EVar "n2") (EVar "i2")) (EVar "c2")) (EVar "ys"))))) (arm (PCon "Gt") () (EBinOp "::" (ETuple (ETuple (EVar "n2") (EVar "i2")) (EVar "c2")) (EApp (EApp (EVar "lgMergeName") (EBinOp "::" (ETuple (ETuple (EVar "n1") (EVar "i1")) (EVar "c1")) (EVar "xs"))) (EVar "ys")))) (arm (PCon "Eq") () (EIf (EBinOp "<=" (EVar "i1") (EVar "i2")) (EBinOp "::" (ETuple (ETuple (EVar "n1") (EVar "i1")) (EVar "c1")) (EApp (EApp (EVar "lgMergeName") (EVar "xs")) (EBinOp "::" (ETuple (ETuple (EVar "n2") (EVar "i2")) (EVar "c2")) (EVar "ys")))) (EBinOp "::" (ETuple (ETuple (EVar "n2") (EVar "i2")) (EVar "c2")) (EApp (EApp (EVar "lgMergeName") (EBinOp "::" (ETuple (ETuple (EVar "n1") (EVar "i1")) (EVar "c1")) (EVar "xs"))) (EVar "ys")))))))
(DTypeSig false "lgRuns" (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "Int")) (TyCon "CClause"))) (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "CClause"))))))
(DFunDef false "lgRuns" ((PList)) (EListLit))
(DFunDef false "lgRuns" ((PCons (PTuple (PTuple (PVar "n") (PVar "i")) (PVar "c")) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "cs") (PVar "others")) (EApp (EApp (EVar "lgSpan") (EVar "n")) (EVar "rest"))) (DoExpr (EBinOp "::" (ETuple (ETuple (EVar "n") (EVar "i")) (EBinOp "::" (EVar "c") (EVar "cs"))) (EApp (EVar "lgRuns") (EVar "others"))))))
(DTypeSig false "lgSpan" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "Int")) (TyCon "CClause"))) (TyTuple (TyApp (TyCon "List") (TyCon "CClause")) (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "Int")) (TyCon "CClause")))))))
(DFunDef false "lgSpan" (PWild (PList)) (ETuple (EListLit) (EListLit)))
(DFunDef false "lgSpan" ((PVar "n") (PCons (PTuple (PTuple (PVar "m") (PVar "j")) (PVar "c")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "m") (EVar "n")) (EBlock (DoLet false false (PTuple (PVar "cs") (PVar "o")) (EApp (EApp (EVar "lgSpan") (EVar "n")) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EVar "c") (EVar "cs")) (EVar "o")))) (ETuple (EListLit) (EBinOp "::" (ETuple (ETuple (EVar "m") (EVar "j")) (EVar "c")) (EVar "rest")))))
(DTypeSig false "lgSortIdx" (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "CClause")))) (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "CClause"))))))
(DFunDef false "lgSortIdx" ((PList)) (EListLit))
(DFunDef false "lgSortIdx" ((PList (PVar "x"))) (EListLit (EVar "x")))
(DFunDef false "lgSortIdx" ((PVar "xs")) (EBlock (DoLet false false (PTuple (PVar "a") (PVar "b")) (EApp (EVar "lgSplit") (EVar "xs"))) (DoExpr (EApp (EApp (EVar "lgMergeIdx") (EApp (EVar "lgSortIdx") (EVar "a"))) (EApp (EVar "lgSortIdx") (EVar "b"))))))
(DTypeSig false "lgMergeIdx" (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "CClause")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "CClause")))) (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "CClause")))))))
(DFunDef false "lgMergeIdx" ((PList) (PVar "ys")) (EVar "ys"))
(DFunDef false "lgMergeIdx" ((PVar "xs") (PList)) (EVar "xs"))
(DFunDef false "lgMergeIdx" ((PCons (PTuple (PTuple (PVar "n1") (PVar "i1")) (PVar "cs1")) (PVar "xs")) (PCons (PTuple (PTuple (PVar "n2") (PVar "i2")) (PVar "cs2")) (PVar "ys"))) (EIf (EBinOp "<=" (EVar "i1") (EVar "i2")) (EBinOp "::" (ETuple (ETuple (EVar "n1") (EVar "i1")) (EVar "cs1")) (EApp (EApp (EVar "lgMergeIdx") (EVar "xs")) (EBinOp "::" (ETuple (ETuple (EVar "n2") (EVar "i2")) (EVar "cs2")) (EVar "ys")))) (EBinOp "::" (ETuple (ETuple (EVar "n2") (EVar "i2")) (EVar "cs2")) (EApp (EApp (EVar "lgMergeIdx") (EBinOp "::" (ETuple (ETuple (EVar "n1") (EVar "i1")) (EVar "cs1")) (EVar "xs"))) (EVar "ys")))))
(DTypeSig false "lgToBind" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Loc")) (TyFun (TyTuple (TyTuple (TyCon "String") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "CClause"))) (TyCon "CBind"))))
(DFunDef false "lgToBind" ((PVar "sites") (PTuple (PTuple (PVar "n") PWild) (PVar "cs"))) (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "sites")) (arm (PCon "Some" (PVar "site")) () (EApp (EApp (EApp (EVar "CBind") (EVar "n")) (EVar "cs")) (EVar "site"))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "CBind") (EVar "n")) (EVar "cs")) (EVar "noDeclLoc")))))
(DTypeSig false "bindSites" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Loc")) (TyApp (TyCon "OrdMap") (TyCon "Loc")))))
(DFunDef false "bindSites" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "bindSites" ((PCons (PCon "DFunDef" PWild (PVar "n") PWild PWild (PVar "site")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "bindSites") (EVar "rest")) (EApp (EApp (EApp (EVar "firstSite") (EVar "n")) (EVar "site")) (EVar "acc"))))
(DFunDef false "bindSites" ((PCons (PCon "DLetGroup" PWild (PVar "binds")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "bindSites") (EVar "rest")) (EApp (EApp (EVar "letBindSites") (EVar "binds")) (EVar "acc"))))
(DFunDef false "bindSites" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "bindSites") (EBinOp "::" (EVar "d") (EVar "rest"))) (EVar "acc")))
(DFunDef false "bindSites" ((PCons PWild (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "bindSites") (EVar "rest")) (EVar "acc")))
(DTypeSig false "letBindSites" (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Loc")) (TyApp (TyCon "OrdMap") (TyCon "Loc")))))
(DFunDef false "letBindSites" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "letBindSites" ((PCons (PCon "LetBind" (PVar "n") PWild (PVar "site")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "letBindSites") (EVar "rest")) (EApp (EApp (EApp (EVar "firstSite") (EVar "n")) (EVar "site")) (EVar "acc"))))
(DTypeSig false "firstSite" (TyFun (TyCon "String") (TyFun (TyCon "Loc") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Loc")) (TyApp (TyCon "OrdMap") (TyCon "Loc"))))))
(DFunDef false "firstSite" ((PVar "n") (PVar "site") (PVar "acc")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "acc")) (EVar "acc") (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (EVar "site")) (EVar "acc"))))
(DTypeSig true "ifaceImplHeadTable" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String") (TyCon "String")))))
(DFunDef false "ifaceImplHeadTable" ((PVar "prog")) (EApp (EApp (EDictApp "flatMap") (EVar "ifaceImplHeadEntries")) (EVar "prog")))
(DTypeSig false "ifaceImplHeadEntries" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String") (TyCon "String")))))
(DFunDef false "ifaceImplHeadEntries" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "ifaceImplHeadEntries") (EVar "d")))
(DFunDef false "ifaceImplHeadEntries" ((PRec "DImpl" ((rf "iface" (PVar "ifaceName")) (rf "implOrigin" (PVar "o")) (rf "tys" (PVar "typeArgs"))) true)) (EListLit (ETuple (EApp (EApp (EVar "ifaceIdentity") (EVar "o")) (EVar "ifaceName")) (EVar "ifaceName") (EApp (EApp (EVar "optionOr") (EVar "noneHeadTag")) (EApp (EVar "headTyconHead") (EVar "typeArgs"))) (EApp (EApp (EApp (EApp (EVar "implRouteKeyWord") (EVar "o")) (EVar "ifaceName")) (EVar "typeArgs")) (EVar "None")))))
(DFunDef false "ifaceImplHeadEntries" (PWild) (EListLit))
(DTypeSig false "implSymbolCollisionGuard" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Unit")))
(DFunDef false "implSymbolCollisionGuard" ((PVar "prog")) (EBlock (DoLet false false (PVar "rows") (EApp (EApp (EVar "dedupImplSymRows") (EApp (EApp (EDictApp "flatMap") (EVar "implSymRowsOf")) (EVar "prog"))) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EApp (EVar "checkImplSymbolsInjective") (EApp (EApp (EApp (EVar "collidingHeads") (EVar "rows")) (EVar "omEmpty")) (EVar "omEmpty"))) (EVar "rows")) (EVar "omEmpty")))))
(DTypeSig false "implSymRowsOf" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String")))))
(DFunDef false "implSymRowsOf" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "implSymRowsOf") (EVar "d")))
(DFunDef false "implSymRowsOf" ((PRec "DImpl" ((rf "iface" (PVar "ifaceName")) (rf "implOrigin" (PVar "o")) (rf "tys" (PVar "typeArgs")) (rf "methods" None)) true)) (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "implSymRow") (EApp (EApp (EVar "optionOr") (EVar "noneHeadTag")) (EApp (EVar "headTyconHead") (EVar "typeArgs")))) (EApp (EApp (EApp (EApp (EVar "implRouteKeyWord") (EVar "o")) (EVar "ifaceName")) (EVar "typeArgs")) (EVar "None")))) (EVar "methods")))
(DFunDef false "implSymRowsOf" (PWild) (EListLit))
(DTypeSig false "implSymRow" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "ImplMethod") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String"))))))
(DFunDef false "implSymRow" ((PVar "tag") (PVar "key") (PCon "ImplMethod" (PVar "mname") PWild PWild)) (ETuple (EVar "mname") (EVar "tag") (EVar "key")))
(DTypeSig false "dedupImplSymRows" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String"))))))
(DFunDef false "dedupImplSymRows" ((PList) PWild) (EListLit))
(DFunDef false "dedupImplSymRows" ((PCons (PTuple (PVar "m") (PVar "tag") (PVar "key")) (PVar "rest")) (PVar "seen")) (EIf (EApp (EApp (EVar "omHasKey") (EApp (EApp (EApp (EVar "implPreImageKey") (EVar "m")) (EVar "tag")) (EVar "key"))) (EVar "seen")) (EApp (EApp (EVar "dedupImplSymRows") (EVar "rest")) (EVar "seen")) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "m") (EVar "tag") (EVar "key")) (EApp (EApp (EVar "dedupImplSymRows") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EApp (EApp (EApp (EVar "implPreImageKey") (EVar "m")) (EVar "tag")) (EVar "key"))) (ELit LUnit)) (EVar "seen")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "implPreImageKey" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "implPreImageKey" ((PVar "m") (PVar "tag") (PVar "key")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "\n"))) (EApp (EMethodRef "display") (EVar "tag"))) (ELit (LString "\n"))) (EApp (EMethodRef "display") (EVar "key"))) (ELit (LString ""))))
(DTypeSig false "collidingHeads" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit"))))))
(DFunDef false "collidingHeads" ((PList) PWild (PVar "acc")) (EVar "acc"))
(DFunDef false "collidingHeads" ((PCons (PTuple (PVar "m") (PVar "tag") (PVar "key")) (PVar "rest")) (PVar "firstKey") (PVar "acc")) (EMatch (EApp (EApp (EVar "omLookup") (EApp (EApp (EVar "implHeadKey") (EVar "m")) (EVar "tag"))) (EVar "firstKey")) (arm (PCon "None") () (EApp (EApp (EApp (EVar "collidingHeads") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EApp (EApp (EVar "implHeadKey") (EVar "m")) (EVar "tag"))) (EVar "key")) (EVar "firstKey"))) (EVar "acc"))) (arm (PCon "Some" (PVar "k0")) () (EIf (EBinOp "==" (EVar "k0") (EVar "key")) (EApp (EApp (EApp (EVar "collidingHeads") (EVar "rest")) (EVar "firstKey")) (EVar "acc")) (EApp (EApp (EApp (EVar "collidingHeads") (EVar "rest")) (EVar "firstKey")) (EApp (EApp (EApp (EVar "omInsert") (EApp (EApp (EVar "implHeadKey") (EVar "m")) (EVar "tag"))) (ELit LUnit)) (EVar "acc")))))))
(DTypeSig false "implHeadKey" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "implHeadKey" ((PVar "m") (PVar "tag")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "\n"))) (EApp (EMethodRef "display") (EVar "tag"))) (ELit (LString ""))))
(DTypeSig false "checkImplSymbolsInjective" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyCon "Unit")))))
(DFunDef false "checkImplSymbolsInjective" (PWild (PList) PWild) (ELit LUnit))
(DFunDef false "checkImplSymbolsInjective" ((PVar "collide") (PCons (PTuple (PVar "m") (PVar "tag") (PVar "key")) (PVar "rest")) (PVar "seen")) (EBlock (DoLet false false (PVar "sym") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "mdk_impl_")) (EApp (EMethodRef "display") (EApp (EApp (EApp (EApp (EVar "implSymTagOf") (EVar "collide")) (EVar "m")) (EVar "tag")) (EVar "key")))) (ELit (LString "_"))) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "")))) (DoExpr (EMatch (EApp (EApp (EVar "omLookup") (EVar "sym")) (EVar "seen")) (arm (PCon "None") () (EApp (EApp (EApp (EVar "checkImplSymbolsInjective") (EVar "collide")) (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "sym")) (EVar "key")) (EVar "seen")))) (arm (PCon "Some" (PVar "prev")) () (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "emitted impl-symbol collision: two DISTINCT impls of method `")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "` are emitted under one symbol.\ncollided symbol: "))) (EApp (EMethodRef "display") (EVar "sym"))) (ELit (LString "\nimpl 1 key: "))) (EApp (EMethodRef "display") (EVar "prev"))) (ELit (LString "\nimpl 2 key: "))) (EApp (EMethodRef "display") (EVar "key"))) (ELit (LString "\nTwo distinct impls cannot share one emitted symbol: the backend would define one body twice (the native link fails) or keep one and silently drop the other. The two keys above are the impls' canonical dispatch keys, spelled `<module>::<Interface>|<type arguments>|`. Since #1950 those keys are spelled into the symbol by `private_mangle.injectiveIdent`, which is INJECTIVE, so this is NOT a naming mistake you can rename your way out of -- it means the emitted-symbol scheme itself lost injectivity. Please report this message, with both keys above.")))))))))
(DTypeSig false "implSymTagOf" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))))
(DFunDef false "implSymTagOf" ((PVar "collide") (PVar "method") (PVar "tag") (PVar "key")) (EIf (EApp (EApp (EVar "omHasKey") (EApp (EApp (EVar "implHeadKey") (EVar "method")) (EVar "tag"))) (EVar "collide")) (EApp (EVar "injectiveIdent") (EVar "key")) (EApp (EVar "injectiveIdent") (EVar "tag"))))
(DTypeSig false "dictWitnessTagGuard" (TyFun (TyCon "EmitTarget") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Unit"))))
(DFunDef false "dictWitnessTagGuard" ((PVar "target") (PVar "prog")) (EBlock (DoLet false false (PVar "rows") (EApp (EApp (EVar "dedupRouteWords") (EApp (EApp (EDictApp "flatMap") (EVar "dictRouteWordsOf")) (EVar "prog"))) (EVar "omEmpty"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "checkDictTagsInjective") (EVar "nativeDictTagSpace")) (EVar "hashName")) (EVar "rows")) (EVar "omEmpty"))) (DoExpr (EMatch (EVar "target") (arm (PCon "TargetNative") () (ELit LUnit)) (arm PWild () (EApp (EApp (EApp (EApp (EVar "checkDictTagsInjective") (EVar "wasmDictTagSpace")) (EVar "dictTag")) (EVar "rows")) (EVar "omEmpty")))))))
(DTypeSig false "nativeDictTagSpace" (TyCon "String"))
(DFunDef false "nativeDictTagSpace" () (ELit (LString "native (LLVM) i64 dict-witness word `hashName` -- BOTH backends, since the wasm tag is this hash masked")))
(DTypeSig false "wasmDictTagSpace" (TyCon "String"))
(DFunDef false "wasmDictTagSpace" () (ELit (LString "wasm (WasmGC) 30-bit i31 dict tag `dictTag` (`hashName` masked to the low 30 bits) -- the full i64 tags are DISTINCT, so native codegen would be correct here; refused anyway because a wasm-target build cannot rule out this narrower width")))
(DTypeSig false "dictRouteWordsOf" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String")))))
(DFunDef false "dictRouteWordsOf" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "dictRouteWordsOf") (EVar "d")))
(DFunDef false "dictRouteWordsOf" ((PRec "DImpl" ((rf "iface" (PVar "ifaceName")) (rf "implOrigin" (PVar "o")) (rf "tys" (PVar "typeArgs")) (rf "methods" None)) true)) (EBlock (DoLet false false (PVar "key") (EApp (EApp (EApp (EApp (EVar "implRouteKeyWord") (EVar "o")) (EVar "ifaceName")) (EVar "typeArgs")) (EVar "None"))) (DoExpr (EApp (EApp (EMethodRef "map") (EApp (EVar "dictRouteWordRowFor") (EVar "key"))) (EVar "methods")))))
(DFunDef false "dictRouteWordsOf" (PWild) (EListLit))
(DTypeSig false "dictRouteWordRowFor" (TyFun (TyCon "String") (TyFun (TyCon "ImplMethod") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String")))))
(DFunDef false "dictRouteWordRowFor" ((PVar "key") (PCon "ImplMethod" (PVar "mname") PWild PWild)) (ETuple (EVar "mname") (EVar "key") (EVar "key")))
(DTypeSig false "dedupRouteWords" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String"))))))
(DFunDef false "dedupRouteWords" ((PList) PWild) (EListLit))
(DFunDef false "dedupRouteWords" ((PCons (PTuple (PVar "m") (PVar "w") (PVar "owner")) (PVar "rest")) (PVar "seen")) (EIf (EApp (EApp (EVar "omHasKey") (EApp (EApp (EVar "dictRouteWordKey") (EVar "m")) (EVar "w"))) (EVar "seen")) (EApp (EApp (EVar "dedupRouteWords") (EVar "rest")) (EVar "seen")) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "m") (EVar "w") (EVar "owner")) (EApp (EApp (EVar "dedupRouteWords") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EApp (EApp (EVar "dictRouteWordKey") (EVar "m")) (EVar "w"))) (ELit LUnit)) (EVar "seen")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "dictRouteWordKey" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "dictRouteWordKey" ((PVar "m") (PVar "w")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "\n"))) (EApp (EMethodRef "display") (EVar "w"))) (ELit (LString ""))))
(DTypeSig false "checkDictTagsInjective" (TyFun (TyCon "String") (TyFun (TyFun (TyCon "String") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "OrdMap") (TyTuple (TyCon "String") (TyCon "String"))) (TyCon "Unit"))))))
(DFunDef false "checkDictTagsInjective" (PWild PWild (PList) PWild) (ELit LUnit))
(DFunDef false "checkDictTagsInjective" ((PVar "space") (PVar "hash") (PCons (PTuple (PVar "m") (PVar "w") (PVar "owner")) (PVar "rest")) (PVar "seen")) (EBlock (DoLet false false (PVar "t") (EApp (EVar "intToString") (EApp (EMethodRef "hash") (EVar "w")))) (DoLet false false (PVar "k") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "\n"))) (EApp (EMethodRef "display") (EVar "t"))) (ELit (LString "")))) (DoExpr (EMatch (EApp (EApp (EVar "omLookup") (EVar "k")) (EVar "seen")) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "checkDictTagsInjective") (EVar "space")) (EMethodRef "hash")) (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "k")) (ETuple (EVar "w") (EVar "owner"))) (EVar "seen")))) (arm (PCon "Some" (PTuple (PVar "w0") (PVar "owner0"))) () (EIf (EBinOp "==" (EVar "owner0") (EVar "owner")) (EApp (EApp (EApp (EApp (EVar "checkDictTagsInjective") (EVar "space")) (EMethodRef "hash")) (EVar "rest")) (EVar "seen")) (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "emitted dict-witness tag collision: two DISTINCT impls of method `")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "` hash to one dispatch tag.\ntag space: "))) (EApp (EMethodRef "display") (EVar "space"))) (ELit (LString "\ncollided tag: "))) (EApp (EMethodRef "display") (EVar "t"))) (ELit (LString "\nroute word 1: "))) (EApp (EMethodRef "display") (EVar "w0"))) (ELit (LString "\nroute word 2: "))) (EApp (EMethodRef "display") (EVar "w"))) (ELit (LString "\nA dict witness carries this tag, and method `"))) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "`'s shared dispatcher selects an impl by comparing it against every OTHER impl of that SAME method name -- these two words ARE compared against each other at that dispatcher, so this collision is live: whichever arm the emitter happened to emit FIRST wins every call through a dictionary, silently, at exit 0. The two words above are the impls' route words: either a bare head tycon or a canonical dispatch key spelled `<module>::<Interface>|<type arguments>|`. This is NOT a naming collision you can rename your way out of by making the names more different -- `hashName` is djb2, a radix-33 polynomial over a 74-code-point alphabet, so it is genuinely non-injective (`hashName \"Az\" == hashName \"BY\"`). One of the two words above may name a type or interface from the prelude or stdlib that you do not own -- rename the OTHER one, one of your own types or interfaces involved in this collision. Please also report this message, with both words above."))))))))))
(DTypeSig true "lowerImplsWith" (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Int")))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyApp (TyCon "Option") (TyCon "DispositionTable")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "CImplEntry")))))))
(DFunDef false "lowerImplsWith" ((PVar "disp") (PVar "reqCounts") (PVar "dispositions") (PVar "prog")) (EApp (EApp (EMethodRef "map") (EApp (EVar "refoldImpl") (EVar "noLetCheck"))) (EApp (EApp (EApp (EApp (EVar "lowerImplsRaw") (EVar "disp")) (EVar "reqCounts")) (EVar "dispositions")) (EVar "prog"))))
(DTypeSig false "lowerImplsRaw" (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Int")))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyApp (TyCon "Option") (TyCon "DispositionTable")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "CImplEntry")))))))
(DFunDef false "lowerImplsRaw" ((PVar "disp") (PVar "reqCounts") (PVar "dispositions") (PVar "prog")) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EVar "lowerDeclImpl") (EVar "disp")) (EVar "reqCounts")) (EVar "dispositions"))) (EVar "prog")))
(DTypeSig false "lowerDeclImpl" (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Int")))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyApp (TyCon "Option") (TyCon "DispositionTable")) (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "CImplEntry")))))))
(DFunDef false "lowerDeclImpl" ((PVar "disp") (PVar "reqCounts") (PVar "dt") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EApp (EApp (EVar "lowerDeclImpl") (EVar "disp")) (EVar "reqCounts")) (EVar "dt")) (EVar "d")))
(DFunDef false "lowerDeclImpl" ((PVar "disp") PWild PWild (PRec "DImpl" ((rf "iface" (PVar "ifaceName")) (rf "implOrigin" (PVar "o")) (rf "tys" (PVar "typeArgs")) (rf "methods" None)) true)) (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EApp (EVar "lowerImplMethod") (EVar "disp")) (EVar "o")) (EVar "ifaceName")) (EVar "typeArgs"))) (EVar "methods")))
(DFunDef false "lowerDeclImpl" ((PVar "disp") (PVar "reqCounts") (PCon "Some" (PVar "dt")) (PRec "DInterface" ((rf "name" (PVar "ifaceName")) (rf "ifaceOrigin" (PVar "o")) (rf "methods" None)) true)) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EApp (EApp (EVar "lowerInheritedDefault") (EVar "disp")) (EVar "reqCounts")) (EVar "dt")) (EVar "o")) (EVar "ifaceName"))) (EVar "methods")))
(DFunDef false "lowerDeclImpl" (PWild PWild PWild PWild) (EListLit))
(DTypeSig false "lowerImplMethod" (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Int")))) (TyFun (TyCon "TyConOrigin") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyCon "ImplMethod") (TyCon "CImplEntry")))))))
(DFunDef false "lowerImplMethod" ((PVar "disp") (PVar "o") (PVar "ifaceName") (PVar "typeArgs") (PCon "ImplMethod" (PVar "mname") (PVar "pats") (PVar "body"))) (EBlock (DoLet false false (PVar "tag") (EApp (EApp (EVar "optionOr") (EVar "noneHeadTag")) (EApp (EVar "headTyconHead") (EVar "typeArgs")))) (DoLet false false (PVar "key") (EApp (EApp (EApp (EApp (EVar "implRouteKeyWord") (EVar "o")) (EVar "ifaceName")) (EVar "typeArgs")) (EVar "None"))) (DoLet false false (PVar "positions") (EApp (EApp (EApp (EApp (EVar "lookupPositions") (EApp (EApp (EVar "ifaceIdentity") (EVar "o")) (EVar "ifaceName"))) (EVar "ifaceName")) (EVar "mname")) (EVar "disp"))) (DoExpr (EApp (EApp (EApp (EVar "CImplEntry") (EVar "mname")) (EApp (EVar "tyvarsInArgs") (EVar "typeArgs"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "CImplTagged") (EVar "tag")) (EVar "key")) (EVar "ifaceName")) (EVar "positions")) (EVar "pats")) (EApp (EVar "lower") (EVar "body")))))))
(DTypeSig false "lowerInheritedDefault" (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Int")))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "DispositionTable") (TyFun (TyCon "TyConOrigin") (TyFun (TyCon "String") (TyFun (TyCon "IfaceMethod") (TyApp (TyCon "List") (TyCon "CImplEntry")))))))))
(DFunDef false "lowerInheritedDefault" (PWild PWild PWild PWild PWild (PCon "IfaceMethod" PWild PWild (PCon "None") PWild)) (EListLit))
(DFunDef false "lowerInheritedDefault" ((PVar "disp") (PVar "reqCounts") (PVar "dt") (PVar "o") (PVar "ifaceName") (PCon "IfaceMethod" (PVar "mname") PWild (PCon "Some" (PCon "MethodDefault" (PVar "pats") (PVar "body"))) PWild)) (EBlock (DoLet false false (PVar "ifaceWord") (EApp (EApp (EVar "ifaceWordOf") (EVar "o")) (EVar "ifaceName"))) (DoLet false false (PVar "positions") (EApp (EApp (EApp (EApp (EVar "lookupPositions") (EApp (EApp (EVar "ifaceIdentity") (EVar "o")) (EVar "ifaceName"))) (EVar "ifaceName")) (EVar "mname")) (EVar "disp"))) (DoLet false false (PVar "nMethodDicts") (EApp (EVar "leadingDictParams") (EVar "pats"))) (DoLet false false (PVar "receiver") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "$dict_")) (EApp (EMethodRef "display") (EVar "mname"))) (ELit (LString "_"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "nMethodDicts")))) (ELit (LString "")))) (DoLet false false (PVar "params") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "take") (EVar "nMethodDicts")) (EVar "pats")) (EListLit (EApp (EApp (EVar "PVar") (EVar "receiver")) (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString ""))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0)))))) (EApp (EApp (EVar "drop") (EVar "nMethodDicts")) (EVar "pats"))) (EApp (EVar "lamParams") (EVar "body")))) (DoLet false false (PVar "lowered") (EApp (EVar "lower") (EApp (EVar "underLam") (EVar "body")))) (DoLet false false (PVar "spec") (ELam ((PVar "shape")) (ERecordCreate "DefaultRow" ((fa "drSelf" (EApp (EVar "defaultReceiverDict") (EVar "mname"))) (fa "drReceiver" (EVar "receiver")) (fa "drIface" (EVar "ifaceWord")) (fa "drWord" (EFieldAccess (EVar "shape") "isWord")) (fa "drSupers" (EApp (EApp (EApp (EVar "receiverFields") (EVar "receiver")) (ELit (LInt 0))) (EApp (EApp (EVar "ifaceSuperCount") (EVar "ifaceWord")) (EVar "dt")))) (fa "drReqs" (EApp (EApp (EApp (EVar "receiverFields") (EVar "receiver")) (EApp (EApp (EVar "ifaceSuperCount") (EVar "ifaceWord")) (EVar "dt"))) (EApp (EApp (EVar "optionOr") (ELit (LInt 0))) (EApp (EApp (EVar "omLookup") (EFieldAccess (EVar "shape") "isWord")) (EVar "reqCounts"))))))))) (DoExpr (EApp (EApp (EMethodRef "map") (ELam ((PVar "shape")) (EApp (EApp (EApp (EVar "CImplEntry") (EVar "mname")) (EApp (EVar "tyvarsInArgs") (EFieldAccess (EVar "shape") "isTys"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "CImplDefault") (EVar "ifaceWord")) (EApp (EApp (EVar "optionOr") (EVar "noneHeadTag")) (EApp (EVar "headTyconHead") (EFieldAccess (EVar "shape") "isTys")))) (EFieldAccess (EVar "shape") "isWord")) (EVar "positions")) (EVar "params")) (EApp (EApp (EVar "specializeRow") (EApp (EVar "spec") (EVar "shape"))) (EVar "lowered")))))) (EApp (EApp (EApp (EVar "inheritorsOf") (EVar "ifaceWord")) (EVar "mname")) (EVar "dt"))))))
(DData Private "DefaultRow" () ((variant "DefaultRow" (ConNamed (field "drSelf" (TyCon "String")) (field "drReceiver" (TyCon "String")) (field "drIface" (TyCon "String")) (field "drWord" (TyCon "String")) (field "drSupers" (TyApp (TyCon "List") (TyCon "Route"))) (field "drReqs" (TyApp (TyCon "List") (TyCon "Route")))))) ())
(DTypeSig false "receiverFields" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Route"))))))
(DFunDef false "receiverFields" ((PVar "recv") (PVar "from") (PVar "n")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "i")) (EApp (EApp (EVar "RProj") (EApp (EVar "RDict") (EVar "recv"))) (EListLit (EVar "i"))))) (EApp (EApp (EVar "range") (EVar "from")) (EBinOp "+" (EVar "from") (EVar "n")))))
(DTypeSig false "specializeRow" (TyFun (TyCon "DefaultRow") (TyFun (TyCon "CExpr") (TyCon "CExpr"))))
(DFunDef false "specializeRow" ((PVar "row") (PCon "CMethod" (PVar "name") (PVar "iface") (PVar "arity") (PVar "route") (PVar "implRoutes") (PVar "methRoutes"))) (EIf (EBinOp "&&" (EBinOp "==" (EVar "iface") (EFieldAccess (EVar "row") "drIface")) (EApp (EApp (EVar "isReceiverRoute") (EVar "row")) (EVar "route"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "CMethod") (EVar "name")) (EVar "iface")) (EVar "arity")) (EApp (EApp (EApp (EVar "RKey") (EFieldAccess (EVar "row") "drWord")) (EListLit)) (EFieldAccess (EVar "row") "drSupers"))) (EFieldAccess (EVar "row") "drReqs")) (EApp (EApp (EMethodRef "map") (EApp (EVar "renameReceiver") (EVar "row"))) (EVar "methRoutes"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "CMethod") (EVar "name")) (EVar "iface")) (EVar "arity")) (EApp (EApp (EVar "renameReceiver") (EVar "row")) (EVar "route"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "renameReceiver") (EVar "row"))) (EVar "implRoutes"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "renameReceiver") (EVar "row"))) (EVar "methRoutes")))))
(DFunDef false "specializeRow" ((PVar "row") (PCon "CDict" (PVar "name") (PVar "routes"))) (EApp (EApp (EVar "CDict") (EVar "name")) (EApp (EApp (EMethodRef "map") (EApp (EVar "renameReceiver") (EVar "row"))) (EVar "routes"))))
(DFunDef false "specializeRow" ((PVar "row") (PCon "CVar" (PVar "x") (PVar "addr"))) (EIf (EBinOp "==" (EVar "x") (EFieldAccess (EVar "row") "drSelf")) (EApp (EApp (EVar "CVar") (EFieldAccess (EVar "row") "drReceiver")) (EVar "addr")) (EApp (EApp (EVar "CVar") (EVar "x")) (EVar "addr"))))
(DFunDef false "specializeRow" (PWild (PCon "CLit" (PVar "l"))) (EApp (EVar "CLit") (EVar "l")))
(DFunDef false "specializeRow" ((PVar "row") (PCon "CApp" (PVar "f") (PVar "x"))) (EApp (EApp (EVar "CApp") (EApp (EApp (EVar "specializeRow") (EVar "row")) (EVar "f"))) (EApp (EApp (EVar "specializeRow") (EVar "row")) (EVar "x"))))
(DFunDef false "specializeRow" ((PVar "row") (PCon "CLam" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "CLam") (EVar "pats")) (EApp (EApp (EVar "specializeRow") (EVar "row")) (EVar "body"))))
(DFunDef false "specializeRow" ((PVar "row") (PCon "CLet" (PVar "r") (PVar "pat") (PVar "e1") (PVar "e2"))) (EApp (EApp (EApp (EApp (EVar "CLet") (EVar "r")) (EVar "pat")) (EApp (EApp (EVar "specializeRow") (EVar "row")) (EVar "e1"))) (EApp (EApp (EVar "specializeRow") (EVar "row")) (EVar "e2"))))
(DFunDef false "specializeRow" ((PVar "row") (PCon "CLetGroup" (PVar "binds") (PVar "body"))) (EApp (EApp (EVar "CLetGroup") (EApp (EApp (EMethodRef "map") (EApp (EVar "specializeBind") (EVar "row"))) (EVar "binds"))) (EApp (EApp (EVar "specializeRow") (EVar "row")) (EVar "body"))))
(DFunDef false "specializeRow" ((PVar "row") (PCon "CMatch" (PVar "scrut") (PVar "arms"))) (EApp (EApp (EVar "CMatch") (EApp (EApp (EVar "specializeRow") (EVar "row")) (EVar "scrut"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "specializeArm") (EVar "row"))) (EVar "arms"))))
(DFunDef false "specializeRow" ((PVar "row") (PCon "CDecision" (PVar "scrut") (PVar "arms") (PVar "tree"))) (EApp (EApp (EApp (EVar "CDecision") (EApp (EApp (EVar "specializeRow") (EVar "row")) (EVar "scrut"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "specializeArm") (EVar "row"))) (EVar "arms"))) (EVar "tree")))
(DFunDef false "specializeRow" ((PVar "row") (PCon "CIf" (PVar "c") (PVar "t") (PVar "e"))) (EApp (EApp (EApp (EVar "CIf") (EApp (EApp (EVar "specializeRow") (EVar "row")) (EVar "c"))) (EApp (EApp (EVar "specializeRow") (EVar "row")) (EVar "t"))) (EApp (EApp (EVar "specializeRow") (EVar "row")) (EVar "e"))))
(DFunDef false "specializeRow" ((PVar "row") (PCon "CBinPrim" (PVar "op") (PVar "l") (PVar "r") (PVar "tag") (PVar "site"))) (EApp (EApp (EApp (EApp (EApp (EVar "CBinPrim") (EVar "op")) (EApp (EApp (EVar "specializeRow") (EVar "row")) (EVar "l"))) (EApp (EApp (EVar "specializeRow") (EVar "row")) (EVar "r"))) (EVar "tag")) (EVar "site")))
(DFunDef false "specializeRow" ((PVar "row") (PCon "CUnOp" (PVar "op") (PVar "x"))) (EApp (EApp (EVar "CUnOp") (EVar "op")) (EApp (EApp (EVar "specializeRow") (EVar "row")) (EVar "x"))))
(DFunDef false "specializeRow" ((PVar "row") (PCon "CTuple" (PVar "es"))) (EApp (EVar "CTuple") (EApp (EApp (EMethodRef "map") (EApp (EVar "specializeRow") (EVar "row"))) (EVar "es"))))
(DFunDef false "specializeRow" ((PVar "row") (PCon "CList" (PVar "es"))) (EApp (EVar "CList") (EApp (EApp (EMethodRef "map") (EApp (EVar "specializeRow") (EVar "row"))) (EVar "es"))))
(DFunDef false "specializeRow" ((PVar "row") (PCon "CRecord" (PVar "name") (PVar "fields"))) (EApp (EApp (EVar "CRecord") (EVar "name")) (EApp (EApp (EMethodRef "map") (EApp (EVar "specializeField") (EVar "row"))) (EVar "fields"))))
(DFunDef false "specializeRow" ((PVar "row") (PCon "CFieldAccess" (PVar "ex") (PVar "f") (PVar "n"))) (EApp (EApp (EApp (EVar "CFieldAccess") (EApp (EApp (EVar "specializeRow") (EVar "row")) (EVar "ex"))) (EVar "f")) (EVar "n")))
(DFunDef false "specializeRow" ((PVar "row") (PCon "CRecordUpdate" (PVar "name") (PVar "base") (PVar "fields"))) (EApp (EApp (EApp (EVar "CRecordUpdate") (EVar "name")) (EApp (EApp (EVar "specializeRow") (EVar "row")) (EVar "base"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "specializeField") (EVar "row"))) (EVar "fields"))))
(DFunDef false "specializeRow" ((PVar "row") (PCon "CVariantUpdate" (PVar "con") (PVar "base") (PVar "fields"))) (EApp (EApp (EApp (EVar "CVariantUpdate") (EVar "con")) (EApp (EApp (EVar "specializeRow") (EVar "row")) (EVar "base"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "specializeField") (EVar "row"))) (EVar "fields"))))
(DFunDef false "specializeRow" ((PVar "row") (PCon "CArray" (PVar "es"))) (EApp (EVar "CArray") (EApp (EApp (EMethodRef "map") (EApp (EVar "specializeRow") (EVar "row"))) (EVar "es"))))
(DFunDef false "specializeRow" ((PVar "row") (PCon "CRangeList" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EVar "CRangeList") (EApp (EApp (EVar "specializeRow") (EVar "row")) (EVar "lo"))) (EApp (EApp (EVar "specializeRow") (EVar "row")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "specializeRow" ((PVar "row") (PCon "CRangeArray" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EVar "CRangeArray") (EApp (EApp (EVar "specializeRow") (EVar "row")) (EVar "lo"))) (EApp (EApp (EVar "specializeRow") (EVar "row")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "specializeRow" ((PVar "row") (PCon "CIndex" (PVar "a") (PVar "i"))) (EApp (EApp (EVar "CIndex") (EApp (EApp (EVar "specializeRow") (EVar "row")) (EVar "a"))) (EApp (EApp (EVar "specializeRow") (EVar "row")) (EVar "i"))))
(DFunDef false "specializeRow" ((PVar "row") (PCon "CSlice" (PVar "a") (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EApp (EVar "CSlice") (EApp (EApp (EVar "specializeRow") (EVar "row")) (EVar "a"))) (EApp (EApp (EVar "specializeRow") (EVar "row")) (EVar "lo"))) (EApp (EApp (EVar "specializeRow") (EVar "row")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "specializeRow" ((PVar "row") (PCon "CStringIndex" (PVar "a") (PVar "i"))) (EApp (EApp (EVar "CStringIndex") (EApp (EApp (EVar "specializeRow") (EVar "row")) (EVar "a"))) (EApp (EApp (EVar "specializeRow") (EVar "row")) (EVar "i"))))
(DFunDef false "specializeRow" ((PVar "row") (PCon "CStringSlice" (PVar "a") (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EApp (EVar "CStringSlice") (EApp (EApp (EVar "specializeRow") (EVar "row")) (EVar "a"))) (EApp (EApp (EVar "specializeRow") (EVar "row")) (EVar "lo"))) (EApp (EApp (EVar "specializeRow") (EVar "row")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "specializeRow" ((PVar "row") (PCon "CListIndex" (PVar "a") (PVar "i"))) (EApp (EApp (EVar "CListIndex") (EApp (EApp (EVar "specializeRow") (EVar "row")) (EVar "a"))) (EApp (EApp (EVar "specializeRow") (EVar "row")) (EVar "i"))))
(DFunDef false "specializeRow" ((PVar "row") (PCon "CListSlice" (PVar "a") (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EApp (EVar "CListSlice") (EApp (EApp (EVar "specializeRow") (EVar "row")) (EVar "a"))) (EApp (EApp (EVar "specializeRow") (EVar "row")) (EVar "lo"))) (EApp (EApp (EVar "specializeRow") (EVar "row")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "specializeRow" ((PVar "row") (PCon "CBlock" (PVar "stmts"))) (EApp (EVar "CBlock") (EApp (EApp (EMethodRef "map") (EApp (EVar "specializeStmt") (EVar "row"))) (EVar "stmts"))))
(DTypeSig false "specializeBind" (TyFun (TyCon "DefaultRow") (TyFun (TyCon "CBind") (TyCon "CBind"))))
(DFunDef false "specializeBind" ((PVar "row") (PCon "CBind" (PVar "n") (PVar "clauses") (PVar "site"))) (EApp (EApp (EApp (EVar "CBind") (EVar "n")) (EApp (EApp (EMethodRef "map") (EApp (EVar "specializeClause") (EVar "row"))) (EVar "clauses"))) (EVar "site")))
(DTypeSig false "specializeClause" (TyFun (TyCon "DefaultRow") (TyFun (TyCon "CClause") (TyCon "CClause"))))
(DFunDef false "specializeClause" ((PVar "row") (PCon "CClause" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "CClause") (EVar "pats")) (EApp (EApp (EVar "specializeRow") (EVar "row")) (EVar "body"))))
(DTypeSig false "specializeArm" (TyFun (TyCon "DefaultRow") (TyFun (TyCon "CArm") (TyCon "CArm"))))
(DFunDef false "specializeArm" ((PVar "row") (PCon "CArm" (PVar "pat") (PVar "guards") (PVar "body"))) (EApp (EApp (EApp (EVar "CArm") (EVar "pat")) (EApp (EApp (EMethodRef "map") (EApp (EVar "specializeGuard") (EVar "row"))) (EVar "guards"))) (EApp (EApp (EVar "specializeRow") (EVar "row")) (EVar "body"))))
(DTypeSig false "specializeGuard" (TyFun (TyCon "DefaultRow") (TyFun (TyCon "CGuard") (TyCon "CGuard"))))
(DFunDef false "specializeGuard" ((PVar "row") (PCon "CGBool" (PVar "e"))) (EApp (EVar "CGBool") (EApp (EApp (EVar "specializeRow") (EVar "row")) (EVar "e"))))
(DFunDef false "specializeGuard" ((PVar "row") (PCon "CGBind" (PVar "p") (PVar "e"))) (EApp (EApp (EVar "CGBind") (EVar "p")) (EApp (EApp (EVar "specializeRow") (EVar "row")) (EVar "e"))))
(DTypeSig false "specializeStmt" (TyFun (TyCon "DefaultRow") (TyFun (TyCon "CStmt") (TyCon "CStmt"))))
(DFunDef false "specializeStmt" ((PVar "row") (PCon "CSExpr" (PVar "e"))) (EApp (EVar "CSExpr") (EApp (EApp (EVar "specializeRow") (EVar "row")) (EVar "e"))))
(DFunDef false "specializeStmt" ((PVar "row") (PCon "CSLet" (PVar "r") (PVar "pat") (PVar "e"))) (EApp (EApp (EApp (EVar "CSLet") (EVar "r")) (EVar "pat")) (EApp (EApp (EVar "specializeRow") (EVar "row")) (EVar "e"))))
(DFunDef false "specializeStmt" ((PVar "row") (PCon "CSAssign" (PVar "x") (PVar "e"))) (EApp (EApp (EVar "CSAssign") (EVar "x")) (EApp (EApp (EVar "specializeRow") (EVar "row")) (EVar "e"))))
(DTypeSig false "specializeField" (TyFun (TyCon "DefaultRow") (TyFun (TyCon "CField") (TyCon "CField"))))
(DFunDef false "specializeField" ((PVar "row") (PCon "CField" (PVar "k") (PVar "e"))) (EApp (EApp (EVar "CField") (EVar "k")) (EApp (EApp (EVar "specializeRow") (EVar "row")) (EVar "e"))))
(DTypeSig false "isReceiverRoute" (TyFun (TyCon "DefaultRow") (TyFun (TyCon "Route") (TyCon "Bool"))))
(DFunDef false "isReceiverRoute" ((PVar "row") (PCon "RDict" (PVar "d"))) (EBinOp "==" (EVar "d") (EFieldAccess (EVar "row") "drSelf")))
(DFunDef false "isReceiverRoute" ((PVar "row") (PCon "RDictFwd" (PVar "d"))) (EBinOp "==" (EVar "d") (EFieldAccess (EVar "row") "drSelf")))
(DFunDef false "isReceiverRoute" (PWild PWild) (EVar "False"))
(DTypeSig false "renameReceiver" (TyFun (TyCon "DefaultRow") (TyFun (TyCon "Route") (TyCon "Route"))))
(DFunDef false "renameReceiver" ((PVar "row") (PCon "RDict" (PVar "d"))) (EApp (EVar "RDict") (EIf (EBinOp "==" (EVar "d") (EFieldAccess (EVar "row") "drSelf")) (EFieldAccess (EVar "row") "drReceiver") (EVar "d"))))
(DFunDef false "renameReceiver" ((PVar "row") (PCon "RDictFwd" (PVar "d"))) (EApp (EVar "RDictFwd") (EIf (EBinOp "==" (EVar "d") (EFieldAccess (EVar "row") "drSelf")) (EFieldAccess (EVar "row") "drReceiver") (EVar "d"))))
(DFunDef false "renameReceiver" ((PVar "row") (PCon "RKey" (PVar "k") (PVar "reqs") (PVar "sups"))) (EApp (EApp (EApp (EVar "RKey") (EVar "k")) (EApp (EApp (EMethodRef "map") (EApp (EVar "renameReceiver") (EVar "row"))) (EVar "reqs"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "renameReceiver") (EVar "row"))) (EVar "sups"))))
(DFunDef false "renameReceiver" ((PVar "row") (PCon "RProj" (PVar "r") (PVar "path"))) (EApp (EApp (EVar "RProj") (EApp (EApp (EVar "renameReceiver") (EVar "row")) (EVar "r"))) (EVar "path")))
(DFunDef false "renameReceiver" ((PVar "row") (PCon "RLocal" (PVar "sym") (PVar "dicts"))) (EApp (EApp (EVar "RLocal") (EVar "sym")) (EApp (EApp (EMethodRef "map") (EApp (EVar "renameReceiver") (EVar "row"))) (EVar "dicts"))))
(DFunDef false "renameReceiver" (PWild (PCon "RNone")) (EVar "RNone"))
(DFunDef false "renameReceiver" (PWild (PCon "RScalar" (PVar "t"))) (EApp (EVar "RScalar") (EVar "t")))
(DTypeSig true "instanceReqCounts" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "OrdMap") (TyCon "Int"))))
(DFunDef false "instanceReqCounts" ((PVar "decls")) (EApp (EApp (EVar "instanceReqCountsGo") (EVar "decls")) (EVar "omEmpty")))
(DTypeSig false "instanceReqCountsGo" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyApp (TyCon "OrdMap") (TyCon "Int")))))
(DFunDef false "instanceReqCountsGo" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "instanceReqCountsGo" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "instanceReqCountsGo") (EBinOp "::" (EVar "d") (EVar "rest"))) (EVar "acc")))
(DFunDef false "instanceReqCountsGo" ((PCons (PRec "DImpl" ((rf "iface" None) (rf "tys" None) (rf "reqs" None) (rf "implOrigin" None)) true) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "instanceReqCountsGo") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EApp (EApp (EApp (EApp (EVar "implRouteKeyWord") (EVar "implOrigin")) (EVar "iface")) (EVar "tys")) (EVar "None"))) (EApp (EVar "listLen") (EVar "reqs"))) (EVar "acc"))))
(DFunDef false "instanceReqCountsGo" ((PCons PWild (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "instanceReqCountsGo") (EVar "rest")) (EVar "acc")))
(DTypeSig false "lamParams" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Pat"))))
(DFunDef false "lamParams" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "lamParams") (EVar "e")))
(DFunDef false "lamParams" ((PCon "ELam" (PVar "ps") PWild)) (EVar "ps"))
(DFunDef false "lamParams" (PWild) (EListLit))
(DTypeSig false "underLam" (TyFun (TyCon "Expr") (TyCon "Expr")))
(DFunDef false "underLam" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "underLam") (EVar "e")))
(DFunDef false "underLam" ((PCon "ELam" PWild (PVar "b"))) (EVar "b"))
(DFunDef false "underLam" ((PVar "e")) (EVar "e"))
(DTypeSig false "leadingDictParams" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int")))
(DFunDef false "leadingDictParams" ((PCons (PCon "PVar" (PVar "x") PWild) (PVar "rest"))) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "$dict"))) (EVar "x")) (EBinOp "+" (ELit (LInt 1)) (EApp (EVar "leadingDictParams") (EVar "rest"))) (ELit (LInt 0))))
(DFunDef false "leadingDictParams" (PWild) (ELit (LInt 0)))
(DTypeSig true "returnsSelfTable" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyCon "Bool")))))
(DFunDef false "returnsSelfTable" ((PVar "prog")) (EApp (EApp (EDictApp "flatMap") (EVar "ifaceReturnsSelfEntries")) (EVar "prog")))
(DTypeSig false "ifaceReturnsSelfEntries" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyCon "Bool")))))
(DFunDef false "ifaceReturnsSelfEntries" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "ifaceReturnsSelfEntries") (EVar "d")))
(DFunDef false "ifaceReturnsSelfEntries" ((PRec "DInterface" ((rf "name" (PVar "ifaceName")) (rf "typarams" (PVar "typeParams")) (rf "methods" None)) true)) (EApp (EApp (EMethodRef "map") (ELam ((PVar "m")) (EApp (EApp (EApp (EVar "ifaceReturnsSelfEntry") (EVar "ifaceName")) (EVar "typeParams")) (EVar "m")))) (EVar "methods")))
(DFunDef false "ifaceReturnsSelfEntries" (PWild) (EListLit))
(DTypeSig false "ifaceReturnsSelfEntry" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "IfaceMethod") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyCon "Bool"))))))
(DFunDef false "ifaceReturnsSelfEntry" ((PVar "ifaceName") (PVar "typeParams") (PCon "IfaceMethod" (PVar "mname") (PVar "mty") PWild PWild)) (ETuple (ETuple (EVar "ifaceName") (EVar "mname")) (EApp (EApp (EVar "tyMentionsParams") (EApp (EVar "methodResultTy") (EVar "mty"))) (EApp (EVar "headParamOnly") (EVar "typeParams")))))
(DTypeSig false "headParamOnly" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "headParamOnly" ((PList)) (EListLit))
(DFunDef false "headParamOnly" ((PCons (PVar "p") PWild)) (EListLit (EVar "p")))
(DTypeSig false "methodResultTy" (TyFun (TyCon "Ty") (TyCon "Ty")))
(DFunDef false "methodResultTy" ((PCon "TyConstrained" PWild (PVar "t"))) (EApp (EVar "methodResultTy") (EVar "t")))
(DFunDef false "methodResultTy" ((PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EVar "methodResultTy") (EVar "t")))
(DFunDef false "methodResultTy" ((PCon "TyFun" PWild (PVar "b"))) (EApp (EVar "methodResultTy") (EVar "b")))
(DFunDef false "methodResultTy" ((PCon "TyQual" (PVar "t") PWild PWild)) (EApp (EVar "methodResultTy") (EVar "t")))
(DFunDef false "methodResultTy" ((PVar "t")) (EVar "t"))
(DTypeSig false "tyMentionsParams" (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "tyMentionsParams" ((PCon "TyVar" (PVar "n")) (PVar "params")) (EApp (EApp (EVar "contains") (EVar "n")) (EVar "params")))
(DFunDef false "tyMentionsParams" ((PRec "TyCon" ((rf "tyConName" PWild)) false) PWild) (EVar "False"))
(DFunDef false "tyMentionsParams" ((PCon "TyApp" (PVar "a") (PVar "b")) (PVar "params")) (EBinOp "||" (EApp (EApp (EVar "tyMentionsParams") (EVar "a")) (EVar "params")) (EApp (EApp (EVar "tyMentionsParams") (EVar "b")) (EVar "params"))))
(DFunDef false "tyMentionsParams" ((PCon "TyFun" (PVar "a") (PVar "b")) (PVar "params")) (EBinOp "||" (EApp (EApp (EVar "tyMentionsParams") (EVar "a")) (EVar "params")) (EApp (EApp (EVar "tyMentionsParams") (EVar "b")) (EVar "params"))))
(DFunDef false "tyMentionsParams" ((PCon "TyTuple" (PVar "ts")) (PVar "params")) (EApp (EApp (EVar "anyList") (ELam ((PVar "t")) (EApp (EApp (EVar "tyMentionsParams") (EVar "t")) (EVar "params")))) (EVar "ts")))
(DFunDef false "tyMentionsParams" ((PCon "TyEffect" PWild PWild (PVar "t")) (PVar "params")) (EApp (EApp (EVar "tyMentionsParams") (EVar "t")) (EVar "params")))
(DFunDef false "tyMentionsParams" ((PCon "TyRow" PWild (PVar "tail") PWild) (PVar "params")) (EApp (EApp (EVar "anyList") (ELam ((PVar "v")) (EApp (EApp (EVar "contains") (EVar "v")) (EVar "params")))) (EVar "tail")))
(DFunDef false "tyMentionsParams" ((PCon "TyAuth" PWild PWild) PWild) (EVar "False"))
(DFunDef false "tyMentionsParams" ((PCon "TyConstrained" PWild (PVar "t")) (PVar "params")) (EApp (EApp (EVar "tyMentionsParams") (EVar "t")) (EVar "params")))
(DFunDef false "tyMentionsParams" ((PCon "TyNamed" PWild (PVar "t") PWild) (PVar "params")) (EApp (EApp (EVar "tyMentionsParams") (EVar "t")) (EVar "params")))
(DFunDef false "tyMentionsParams" ((PCon "TyQual" (PVar "t") PWild PWild) (PVar "params")) (EApp (EApp (EVar "tyMentionsParams") (EVar "t")) (EVar "params")))
(DTypeSig true "selfFnParamTable" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "selfFnParamTable" ((PVar "prog")) (EApp (EApp (EDictApp "flatMap") (EVar "ifaceSelfFnParamEntries")) (EVar "prog")))
(DTypeSig false "ifaceSelfFnParamEntries" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "ifaceSelfFnParamEntries" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "ifaceSelfFnParamEntries") (EVar "d")))
(DFunDef false "ifaceSelfFnParamEntries" ((PRec "DInterface" ((rf "name" (PVar "ifaceName")) (rf "typarams" (PVar "typeParams")) (rf "methods" None)) true)) (EApp (EApp (EMethodRef "map") (ELam ((PVar "m")) (EApp (EApp (EApp (EVar "ifaceSelfFnParamEntry") (EVar "ifaceName")) (EVar "typeParams")) (EVar "m")))) (EVar "methods")))
(DFunDef false "ifaceSelfFnParamEntries" (PWild) (EListLit))
(DTypeSig false "ifaceSelfFnParamEntry" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "IfaceMethod") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Int")))))))
(DFunDef false "ifaceSelfFnParamEntry" ((PVar "ifaceName") (PVar "typeParams") (PCon "IfaceMethod" (PVar "mname") (PVar "mty") PWild PWild)) (ETuple (ETuple (EVar "ifaceName") (EVar "mname")) (EApp (EApp (EApp (EVar "selfFnPositions") (ELit (LInt 0))) (EApp (EVar "methodArgTys") (EVar "mty"))) (EVar "typeParams"))))
(DTypeSig false "methodArgTys" (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyCon "Ty"))))
(DFunDef false "methodArgTys" ((PCon "TyConstrained" PWild (PVar "t"))) (EApp (EVar "methodArgTys") (EVar "t")))
(DFunDef false "methodArgTys" ((PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EVar "methodArgTys") (EVar "t")))
(DFunDef false "methodArgTys" ((PCon "TyFun" (PCon "TyNamed" PWild (PVar "a") PWild) (PVar "b"))) (EBinOp "::" (EVar "a") (EApp (EVar "methodArgTys") (EVar "b"))))
(DFunDef false "methodArgTys" ((PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "::" (EVar "a") (EApp (EVar "methodArgTys") (EVar "b"))))
(DFunDef false "methodArgTys" (PWild) (EListLit))
(DTypeSig true "methodIfaceTable" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Int"))))))
(DFunDef false "methodIfaceTable" ((PVar "prog")) (EApp (EApp (EDictApp "flatMap") (EVar "ifaceMethodArityEntries")) (EVar "prog")))
(DTypeSig false "ifaceMethodArityEntries" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Int"))))))
(DFunDef false "ifaceMethodArityEntries" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "ifaceMethodArityEntries") (EVar "d")))
(DFunDef false "ifaceMethodArityEntries" ((PRec "DInterface" ((rf "name" (PVar "ifaceName")) (rf "ifaceOrigin" (PVar "o")) (rf "methods" None)) true)) (EApp (EApp (EMethodRef "map") (ELam ((PVar "m")) (EApp (EApp (EApp (EVar "ifaceMethodArityEntry") (EApp (EApp (EVar "ifaceWordOf") (EVar "o")) (EVar "ifaceName"))) (EVar "ifaceName")) (EVar "m")))) (EVar "methods")))
(DFunDef false "ifaceMethodArityEntries" (PWild) (EListLit))
(DTypeSig false "ifaceMethodArityEntry" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "IfaceMethod") (TyTuple (TyCon "String") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Int")))))))
(DFunDef false "ifaceMethodArityEntry" ((PVar "ifaceWord") (PVar "ifaceName") (PCon "IfaceMethod" (PVar "mname") (PVar "mty") PWild PWild)) (ETuple (EVar "mname") (ETuple (EVar "ifaceName") (EVar "ifaceWord") (EApp (EVar "listLen") (EApp (EVar "methodArgTys") (EVar "mty"))))))
(DTypeSig true "ifaceMethodArityKey" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "ifaceMethodArityKey" ((PVar "ifaceWord") (PVar "mname")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "ifaceWord"))) (ELit (LString "#"))) (EApp (EMethodRef "display") (EVar "mname"))) (ELit (LString ""))))
(DTypeSig true "ifaceWordOfKey" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "ifaceWordOfKey" ((PVar "key")) (EMatch (EApp (EApp (EVar "splitOnChar") (ELit (LChar "|"))) (EVar "key")) (arm (PCons (PVar "w") PWild) () (EVar "w")) (arm (PList) () (EVar "key"))))
(DTypeSig true "ifaceNameOfWord" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "ifaceNameOfWord" ((PVar "word")) (EMatch (EApp (EVar "reverseL") (EApp (EApp (EVar "splitOnChar") (ELit (LChar ":"))) (EVar "word"))) (arm (PCons (PVar "name") PWild) () (EVar "name")) (arm (PList) () (EVar "word"))))
(DTypeSig true "methodConstraintIfaces" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "methodConstraintIfaces" ((PVar "prog")) (EApp (EApp (EDictApp "flatMap") (EVar "methodConstraintIfaceEntries")) (EVar "prog")))
(DTypeSig false "methodConstraintIfaceEntries" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "methodConstraintIfaceEntries" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "methodConstraintIfaceEntries") (EVar "d")))
(DFunDef false "methodConstraintIfaceEntries" ((PRec "DInterface" ((rf "name" (PVar "ifaceName")) (rf "ifaceOrigin" (PVar "o")) (rf "typarams" None) (rf "methods" None)) true)) (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "m")) (EApp (EApp (EApp (EVar "methodConstraintIfaceEntry") (EApp (EApp (EVar "ifaceWordOf") (EVar "o")) (EVar "ifaceName"))) (EVar "typarams")) (EVar "m")))) (EVar "methods")))
(DFunDef false "methodConstraintIfaceEntries" (PWild) (EListLit))
(DTypeSig false "methodConstraintIfaceEntry" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "IfaceMethod") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "methodConstraintIfaceEntry" ((PVar "ifaceWord") (PVar "typarams") (PCon "IfaceMethod" (PVar "mname") (PVar "mty") PWild PWild)) (EBlock (DoLet false false (PVar "ifaces") (EApp (EApp (EVar "methodLevelConstraintIfaces") (EVar "typarams")) (EVar "mty"))) (DoLet false false (PVar "qualified") (ETuple (EApp (EApp (EVar "ifaceMethodArityKey") (EVar "ifaceWord")) (EVar "mname")) (EVar "ifaces"))) (DoExpr (EIf (EApp (EVar "isEmptyL") (EVar "ifaces")) (EListLit (EVar "qualified")) (EListLit (ETuple (EVar "mname") (EVar "ifaces")) (EVar "qualified"))))))
(DTypeSig false "methodLevelConstraintIfaces" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "methodLevelConstraintIfaces" ((PVar "typarams") (PCon "TyConstrained" (PVar "cs") (PVar "t"))) (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "c")) (EApp (EApp (EVar "constraintIfaceIfMethodLevel") (EVar "typarams")) (EVar "c")))) (EVar "cs")) (EApp (EApp (EVar "methodLevelConstraintIfaces") (EVar "typarams")) (EVar "t"))))
(DFunDef false "methodLevelConstraintIfaces" ((PVar "typarams") (PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EApp (EVar "methodLevelConstraintIfaces") (EVar "typarams")) (EVar "t")))
(DFunDef false "methodLevelConstraintIfaces" (PWild PWild) (EListLit))
(DTypeSig false "constraintIfaceIfMethodLevel" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Constraint") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "constraintIfaceIfMethodLevel" ((PVar "typarams") (PRec "Constraint" ((rf "constraintHead" (PVar "ifaceName")) (rf "constraintArgs" (PVar "args"))) false)) (EIf (EApp (EApp (EVar "constraintArgsMentionNonParam") (EVar "typarams")) (EVar "args")) (EListLit (EVar "ifaceName")) (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "constraintArgsMentionNonParam" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyCon "Bool"))))
(DFunDef false "constraintArgsMentionNonParam" ((PVar "typarams") (PVar "args")) (EApp (EApp (EVar "anyList") (ELam ((PVar "t")) (EApp (EApp (EVar "tyMentionsNonParam") (EVar "t")) (EVar "typarams")))) (EVar "args")))
(DTypeSig false "tyMentionsNonParam" (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "tyMentionsNonParam" ((PCon "TyVar" (PVar "n")) (PVar "params")) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EVar "n")) (EVar "params"))))
(DFunDef false "tyMentionsNonParam" ((PRec "TyCon" ((rf "tyConName" PWild)) false) PWild) (EVar "False"))
(DFunDef false "tyMentionsNonParam" ((PCon "TyApp" (PVar "a") (PVar "b")) (PVar "params")) (EBinOp "||" (EApp (EApp (EVar "tyMentionsNonParam") (EVar "a")) (EVar "params")) (EApp (EApp (EVar "tyMentionsNonParam") (EVar "b")) (EVar "params"))))
(DFunDef false "tyMentionsNonParam" ((PCon "TyFun" (PVar "a") (PVar "b")) (PVar "params")) (EBinOp "||" (EApp (EApp (EVar "tyMentionsNonParam") (EVar "a")) (EVar "params")) (EApp (EApp (EVar "tyMentionsNonParam") (EVar "b")) (EVar "params"))))
(DFunDef false "tyMentionsNonParam" ((PCon "TyTuple" (PVar "ts")) (PVar "params")) (EApp (EApp (EVar "anyList") (ELam ((PVar "t")) (EApp (EApp (EVar "tyMentionsNonParam") (EVar "t")) (EVar "params")))) (EVar "ts")))
(DFunDef false "tyMentionsNonParam" ((PCon "TyEffect" PWild PWild (PVar "t")) (PVar "params")) (EApp (EApp (EVar "tyMentionsNonParam") (EVar "t")) (EVar "params")))
(DFunDef false "tyMentionsNonParam" ((PCon "TyRow" PWild (PVar "tail") PWild) (PVar "params")) (EApp (EApp (EVar "anyList") (ELam ((PVar "v")) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EVar "v")) (EVar "params"))))) (EVar "tail")))
(DFunDef false "tyMentionsNonParam" ((PCon "TyAuth" PWild PWild) PWild) (EVar "False"))
(DFunDef false "tyMentionsNonParam" ((PCon "TyConstrained" PWild (PVar "t")) (PVar "params")) (EApp (EApp (EVar "tyMentionsNonParam") (EVar "t")) (EVar "params")))
(DFunDef false "tyMentionsNonParam" ((PCon "TyNamed" PWild (PVar "t") PWild) (PVar "params")) (EApp (EApp (EVar "tyMentionsNonParam") (EVar "t")) (EVar "params")))
(DFunDef false "tyMentionsNonParam" ((PCon "TyQual" (PVar "t") PWild PWild) (PVar "params")) (EApp (EApp (EVar "tyMentionsNonParam") (EVar "t")) (EVar "params")))
(DTypeSig true "ctorFieldTypeNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "ctorFieldTypeNames" ((PVar "prog")) (EApp (EApp (EDictApp "flatMap") (EVar "ctorFieldTypeEntries")) (EVar "prog")))
(DTypeSig false "ctorFieldTypeEntries" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "ctorFieldTypeEntries" ((PRec "DData" ((rf "dataCtors" (PVar "variants"))) false)) (EApp (EApp (EMethodRef "map") (EVar "variantFieldTypeEntry")) (EVar "variants")))
(DFunDef false "ctorFieldTypeEntries" ((PRec "DNewtype" ((rf "newtypeCtor" (PVar "con")) (rf "newtypeFieldTy" (PVar "fieldTy"))) false)) (EListLit (ETuple (EVar "con") (EListLit (EApp (EVar "tyHeadName") (EVar "fieldTy"))))))
(DFunDef false "ctorFieldTypeEntries" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "ctorFieldTypeEntries") (EVar "d")))
(DFunDef false "ctorFieldTypeEntries" (PWild) (EListLit))
(DTypeSig false "variantFieldTypeEntry" (TyFun (TyCon "Variant") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "variantFieldTypeEntry" ((PCon "Variant" (PVar "name") (PCon "ConPos" (PVar "tys")))) (ETuple (EVar "name") (EApp (EApp (EMethodRef "map") (EVar "tyHeadName")) (EVar "tys"))))
(DFunDef false "variantFieldTypeEntry" ((PCon "Variant" (PVar "name") (PCon "ConNamed" (PVar "fields") PWild))) (ETuple (EVar "name") (EApp (EApp (EMethodRef "map") (EVar "fieldTyHeadName")) (EVar "fields"))))
(DTypeSig false "fieldTyHeadName" (TyFun (TyCon "Field") (TyCon "String")))
(DFunDef false "fieldTyHeadName" ((PCon "Field" PWild (PVar "ty"))) (EApp (EVar "tyHeadName") (EVar "ty")))
(DTypeSig false "tyHeadName" (TyFun (TyCon "Ty") (TyCon "String")))
(DFunDef false "tyHeadName" ((PRec "TyCon" ((rf "tyConName" (PVar "n"))) false)) (EVar "n"))
(DFunDef false "tyHeadName" ((PCon "TyVar" (PVar "n"))) (EVar "n"))
(DFunDef false "tyHeadName" ((PCon "TyApp" (PVar "a") PWild)) (EApp (EVar "tyHeadName") (EVar "a")))
(DFunDef false "tyHeadName" ((PCon "TyConstrained" PWild (PVar "t"))) (EApp (EVar "tyHeadName") (EVar "t")))
(DFunDef false "tyHeadName" ((PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EVar "tyHeadName") (EVar "t")))
(DFunDef false "tyHeadName" ((PCon "TyNamed" PWild (PVar "t") PWild)) (EApp (EVar "tyHeadName") (EVar "t")))
(DFunDef false "tyHeadName" ((PCon "TyQual" (PVar "t") PWild PWild)) (EApp (EVar "tyHeadName") (EVar "t")))
(DFunDef false "tyHeadName" (PWild) (ELit (LString "")))
(DTypeSig true "declSigTypeNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))))
(DFunDef false "declSigTypeNames" ((PVar "prog")) (EApp (EApp (EDictApp "flatMap") (EVar "declSigTypeEntries")) (EVar "prog")))
(DTypeSig false "declSigTypeEntries" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))))
(DFunDef false "declSigTypeEntries" ((PCon "DTypeSig" PWild (PVar "name") (PVar "ty") PWild)) (EListLit (ETuple (EVar "name") (ETuple (EApp (EApp (EMethodRef "map") (EVar "tyHeadName")) (EApp (EVar "methodArgTys") (EVar "ty"))) (EApp (EVar "tyHeadName") (EApp (EVar "methodRetTy") (EVar "ty")))))))
(DFunDef false "declSigTypeEntries" ((PCon "DExtern" PWild (PVar "name") (PVar "ty"))) (EListLit (ETuple (EVar "name") (ETuple (EApp (EApp (EMethodRef "map") (EVar "tyHeadName")) (EApp (EVar "methodArgTys") (EVar "ty"))) (EApp (EVar "tyHeadName") (EApp (EVar "methodRetTy") (EVar "ty")))))))
(DFunDef false "declSigTypeEntries" ((PCon "DAttrib" PWild (PVar "inner"))) (EApp (EVar "declSigTypeEntries") (EVar "inner")))
(DFunDef false "declSigTypeEntries" (PWild) (EListLit))
(DTypeSig true "ffiExternTypeNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))))))
(DFunDef false "ffiExternTypeNames" ((PVar "runtimeDecls") (PVar "userDecls")) (EApp (EVar "validateFfiExternTypeNames") (EApp (EApp (EVar "ffiExternRows") (EApp (EVar "externDeclNamesOf") (EVar "runtimeDecls"))) (EVar "userDecls"))))
(DTypeSig true "validateFfiExternTypeNames" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))))
(DFunDef false "validateFfiExternTypeNames" ((PVar "rows")) (EBlock (DoLet false false PWild (EApp (EApp (EVar "ffiCheckExternRowsDistinct") (EVar "omEmpty")) (EVar "rows"))) (DoExpr (EVar "rows"))))
(DTypeSig false "ffiCheckExternRowsDistinct" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))) (TyCon "Unit"))))
(DFunDef false "ffiCheckExternRowsDistinct" (PWild (PList)) (ELit LUnit))
(DFunDef false "ffiCheckExternRowsDistinct" ((PVar "seen") (PCons (PTuple (PVar "n") (PVar "sh")) (PVar "rest"))) (EBlock (DoLet false false (PVar "k") (EApp (EVar "ffiRowShapeKey") (EVar "sh"))) (DoExpr (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "seen")) (arm (PCon "None") () (EApp (EApp (EVar "ffiCheckExternRowsDistinct") (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (EVar "k")) (EVar "seen"))) (EVar "rest"))) (arm (PCon "Some" (PVar "prev")) ((GBool (EBinOp "==" (EVar "prev") (EVar "k")))) (EApp (EApp (EVar "ffiCheckExternRowsDistinct") (EVar "seen")) (EVar "rest"))) (arm (PCon "Some" (PVar "prev")) () (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "foreign declaration collision: the C symbol `")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "` is declared twice with different signatures.\ncolliding symbol: "))) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "\ndeclaration 1: "))) (EApp (EMethodRef "display") (EVar "prev"))) (ELit (LString "\ndeclaration 2: "))) (EApp (EMethodRef "display") (EVar "k"))) (ELit (LString "\nA foreign declaration's name IS the C symbol it links to, so both declarations name ONE C function and only one of these two signatures can describe it. The other module's calls would be marshalled through the wrong signature -- a wrong value at exit 0, or a memory fault. Give the two declarations the same signature, or declare the differing one against a differently-named C symbol.")))))))))
(DTypeSig false "ffiRowShapeKey" (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")) (TyCon "String")))
(DFunDef false "ffiRowShapeKey" ((PTuple (PVar "args") (PVar "ret"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ","))) (EVar "args")))) (ELit (LString " -> "))) (EApp (EMethodRef "display") (EVar "ret"))) (ELit (LString ""))))
(DTypeSig true "externDeclNamesOf" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "externDeclNamesOf" ((PList)) (EListLit))
(DFunDef false "externDeclNamesOf" ((PCons (PCon "DExtern" PWild (PVar "n") PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "externDeclNamesOf") (EVar "rest"))))
(DFunDef false "externDeclNamesOf" ((PCons (PCon "DAttrib" PWild (PVar "inner")) (PVar "rest"))) (EBinOp "++" (EApp (EVar "externDeclNamesOf") (EListLit (EVar "inner"))) (EApp (EVar "externDeclNamesOf") (EVar "rest"))))
(DFunDef false "externDeclNamesOf" ((PCons PWild (PVar "rest"))) (EApp (EVar "externDeclNamesOf") (EVar "rest")))
(DTypeSig false "ffiExternRows" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))))))
(DFunDef false "ffiExternRows" (PWild (PList)) (EListLit))
(DFunDef false "ffiExternRows" ((PVar "builtins") (PCons (PCon "DExtern" PWild (PVar "n") (PVar "ty")) (PVar "rest"))) (EIf (EApp (EApp (EVar "contains") (EVar "n")) (EVar "builtins")) (EApp (EApp (EVar "ffiExternRows") (EVar "builtins")) (EVar "rest")) (EIf (EVar "otherwise") (EBinOp "::" (ETuple (EVar "n") (ETuple (EApp (EApp (EMethodRef "map") (EVar "tyHeadName")) (EApp (EVar "methodArgTys") (EVar "ty"))) (EApp (EVar "tyHeadName") (EApp (EVar "methodRetTy") (EVar "ty"))))) (EApp (EApp (EVar "ffiExternRows") (EVar "builtins")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "ffiExternRows" ((PVar "builtins") (PCons (PCon "DAttrib" PWild (PVar "inner")) (PVar "rest"))) (EApp (EApp (EVar "ffiExternRows") (EVar "builtins")) (EBinOp "::" (EVar "inner") (EVar "rest"))))
(DFunDef false "ffiExternRows" ((PVar "builtins") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "ffiExternRows") (EVar "builtins")) (EVar "rest")))
(DTypeSig false "methodRetTy" (TyFun (TyCon "Ty") (TyCon "Ty")))
(DFunDef false "methodRetTy" ((PCon "TyConstrained" PWild (PVar "t"))) (EApp (EVar "methodRetTy") (EVar "t")))
(DFunDef false "methodRetTy" ((PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EVar "methodRetTy") (EVar "t")))
(DFunDef false "methodRetTy" ((PCon "TyFun" PWild (PVar "b"))) (EApp (EVar "methodRetTy") (EVar "b")))
(DFunDef false "methodRetTy" ((PCon "TyQual" (PVar "t") PWild PWild)) (EApp (EVar "methodRetTy") (EVar "t")))
(DFunDef false "methodRetTy" ((PVar "t")) (EVar "t"))
(DTypeSig false "selfFnPositions" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "selfFnPositions" (PWild (PList) PWild) (EListLit))
(DFunDef false "selfFnPositions" ((PVar "i") (PCons (PVar "t") (PVar "ts")) (PVar "params")) (EIf (EApp (EApp (EVar "tyIsFunReturningSelf") (EVar "t")) (EVar "params")) (EBinOp "::" (EVar "i") (EApp (EApp (EApp (EVar "selfFnPositions") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "ts")) (EVar "params"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "selfFnPositions") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "ts")) (EVar "params")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "tyIsFunReturningSelf" (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "tyIsFunReturningSelf" ((PCon "TyFun" PWild (PVar "b")) (PVar "params")) (EApp (EApp (EVar "tyMentionsParams") (EApp (EVar "methodResultTy") (EVar "b"))) (EVar "params")))
(DFunDef false "tyIsFunReturningSelf" ((PCon "TyConstrained" PWild (PVar "t")) (PVar "params")) (EApp (EApp (EVar "tyIsFunReturningSelf") (EVar "t")) (EVar "params")))
(DFunDef false "tyIsFunReturningSelf" ((PCon "TyEffect" PWild PWild (PVar "t")) (PVar "params")) (EApp (EApp (EVar "tyIsFunReturningSelf") (EVar "t")) (EVar "params")))
(DFunDef false "tyIsFunReturningSelf" (PWild PWild) (EVar "False"))
(DTypeSig false "funClausesOf" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "CClause")))))
(DFunDef false "funClausesOf" ((PList)) (EListLit))
(DFunDef false "funClausesOf" ((PCons (PCon "DFunDef" PWild (PVar "n") (PVar "pats") (PVar "body") PWild) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "n") (EApp (EApp (EVar "CClause") (EVar "pats")) (EApp (EVar "lower") (EVar "body")))) (EApp (EVar "funClausesOf") (EVar "rest"))))
(DFunDef false "funClausesOf" ((PCons (PCon "DLetGroup" PWild (PVar "binds")) (PVar "rest"))) (EBinOp "++" (EApp (EVar "letGroupClausesOf") (EVar "binds")) (EApp (EVar "funClausesOf") (EVar "rest"))))
(DFunDef false "funClausesOf" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "funClausesOf") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "funClausesOf" ((PCons PWild (PVar "rest"))) (EApp (EVar "funClausesOf") (EVar "rest")))
(DTypeSig false "letGroupClausesOf" (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "CClause")))))
(DFunDef false "letGroupClausesOf" ((PList)) (EListLit))
(DFunDef false "letGroupClausesOf" ((PCons (PCon "LetBind" (PVar "n") (PVar "clauses") PWild) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EMethodRef "map") (EApp (EVar "lowerLetBind") (EVar "n"))) (EVar "clauses")) (EApp (EVar "letGroupClausesOf") (EVar "rest"))))
(DTypeSig false "lowerLetBind" (TyFun (TyCon "String") (TyFun (TyCon "FunClause") (TyTuple (TyCon "String") (TyCon "CClause")))))
(DFunDef false "lowerLetBind" ((PVar "n") (PCon "FunClause" (PVar "pats") (PVar "body"))) (ETuple (EVar "n") (EApp (EApp (EVar "CClause") (EVar "pats")) (EApp (EVar "lower") (EVar "body")))))
(DTypeSig false "ctorArities" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int")))))
(DFunDef false "ctorArities" ((PList)) (EListLit))
(DFunDef false "ctorArities" ((PCons (PRec "DData" ((rf "dataCtors" (PVar "variants"))) false) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EMethodRef "map") (EVar "variantArity")) (EVar "variants")) (EApp (EVar "ctorArities") (EVar "rest"))))
(DFunDef false "ctorArities" ((PCons (PRec "DNewtype" ((rf "newtypeCtor" (PVar "con"))) false) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "con") (ELit (LInt 1))) (EApp (EVar "ctorArities") (EVar "rest"))))
(DFunDef false "ctorArities" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "ctorArities") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "ctorArities" ((PCons PWild (PVar "rest"))) (EApp (EVar "ctorArities") (EVar "rest")))
(DTypeSig false "variantArity" (TyFun (TyCon "Variant") (TyTuple (TyCon "String") (TyCon "Int"))))
(DFunDef false "variantArity" ((PCon "Variant" (PVar "n") (PVar "payload"))) (ETuple (EVar "n") (EApp (EVar "payloadArityL") (EVar "payload"))))
(DTypeSig false "payloadArityL" (TyFun (TyCon "ConPayload") (TyCon "Int")))
(DFunDef false "payloadArityL" ((PCon "ConPos" (PVar "tys"))) (EApp (EVar "listLen") (EVar "tys")))
(DFunDef false "payloadArityL" ((PCon "ConNamed" (PVar "fs") PWild)) (EApp (EVar "listLen") (EVar "fs")))
(DTypeSig false "nodeTag" (TyFun (TyCon "Expr") (TyCon "String")))
(DFunDef false "nodeTag" ((PCon "ESection" PWild)) (ELit (LString "ESection")))
(DFunDef false "nodeTag" ((PCon "EGuards" PWild)) (ELit (LString "EGuards")))
(DFunDef false "nodeTag" ((PCon "EDo" PWild PWild)) (ELit (LString "EDo")))
(DFunDef false "nodeTag" ((PCon "EStringInterp" PWild)) (ELit (LString "EStringInterp")))
(DFunDef false "nodeTag" ((PCon "EVariantUpdate" PWild PWild PWild)) (ELit (LString "EVariantUpdate")))
(DFunDef false "nodeTag" ((PCon "EMapLit" PWild PWild)) (ELit (LString "EMapLit")))
(DFunDef false "nodeTag" ((PCon "ESetLit" PWild PWild)) (ELit (LString "ESetLit")))
(DFunDef false "nodeTag" ((PCon "EAsPat" PWild PWild)) (ELit (LString "EAsPat")))
(DFunDef false "nodeTag" ((PCon "EMethodRef" PWild)) (ELit (LString "EMethodRef")))
(DFunDef false "nodeTag" ((PCon "EDictApp" PWild)) (ELit (LString "EDictApp")))
(DFunDef false "nodeTag" (PWild) (ELit (LString "?")))
