# META
source_lines=699
stages=DESUGAR,MARK
# SOURCE
-- Core IR — STAGE2-DESIGN §2.1.  A serializable, backend-neutral intermediate
-- representation lowered from the elaborated (desugared + typed + dict-routed)
-- AST.  The Stage-2 design's load-bearing discipline (Axis 1, Condition 1) is
-- that this IR lives ABOVE any ISA: bytecode/LLVM are *lowerings* of it, never
-- the IR itself, so the lexical-addressing, decision-tree-match and dict-routing
-- work transfers to whichever backend consumes it.
--
-- What makes this a Core IR rather than a copy of `ast.mdk`'s `Expr`:
--   • DESUGARED — only the core node set survives (sugar already lowered by
--     desugar.mdk: sections, comprehensions, do/blocks, guards→if/fallthrough).
--   • PRIMITIVE — surface operators that are really sugar are lowered away here:
--     `&&`/`||`→`CIf` (short-circuit preserved), `|>`→`CApp`, `>>`/`<<`→`CLam`.
--     Only the genuinely-primitive binops survive as `CBinPrim` (arith, compare,
--     `::`, `++`).
--   • LEXICALLY ADDRESSED — every variable carries its resolved `Addr` (the
--     `(frame,slot)` from STAGE2-DESIGN §2.0).  Slice-1 carries it structurally;
--     the slot-indexing consume-half (eval over array frames) is 2.0's parked
--     supervised rework, so today's `ceval` still resolves by name — exactly the
--     status of the `EVarAt` EMIT half in `ast.mdk`.
--   • DICTS EXPLICIT — typeclass dispatch is the structural `CMethod`/`CDict`
--     carrying the typechecker's resolved `Route`s (immutable here — the AST's
--     `Ref Route` mutable cell is read out at lowering time).  These are the
--     "dictionaries already explicit" the design names as the foundation both
--     backends share.  (Emitted/evaluated from slice 5 on; present now so the IR
--     type is complete.)
--   • EFFECTS FULLY ERASED — the frozen-IR contract for effect-polymorphism
--     (STAGE2-DESIGN §2.3).  Effects are TYPE-level only: they live inside `Ty`
--     (`TyEffect`, `ast.mdk`) and the typechecker's `EffRow`/`Effvar` arrows
--     (`typecheck.mdk`), never as standalone expression nodes, and the language
--     has NO runtime effect construct (no perform/handle/resume — Phase 146 is a
--     typecheck-time discipline: open-row inference, propagation, escape,
--     laundering).  So effects erase WITH types at lowering
--     (`lower (EAnnot e _) = lower e` in core_ir_lower.mdk) and the runtime has
--     nothing to witness.  Representation after erasure, stated as a freeze:
--     an effect-polymorphic function is represented IDENTICALLY to a monomorphic
--     one — no effect node, no effect parameter, no effect-directed dispatch.
--     This is the exact OPPOSITE of typeclass polymorphism: a `=>` constraint
--     carries a runtime witness (the `CMethod`/`CDict` dict above); a `<e>`
--     effect row carries NONE.  Dispatch is type-head directed, not effect
--     directed, so erasure cannot perturb a `Route`.  (Verified by equivalence:
--     a combinator instantiated at an effectful row and at the pure row evaluates
--     identically across tree-walker / Core IR / bytecode VM — fixture
--     `test/eval_fixtures/effect_poly.mdk`; the Core IR dump carries 0 effect
--     tokens.)
--
-- Validation (the net-new-IR oracle problem, §2.1): there is no OCaml reference
-- for Core IR.  It is validated by EQUIVALENCE — lower the elaborated AST to Core
-- IR, evaluate the IR (core_ir_eval.mdk), and diff stdout/pp_value against the
-- AST tree-walker over the whole fixture corpus.  Core IR is correct iff
-- evaluating it matches evaluating the AST.

import frontend.ast.{
  Lit(..),
  Loc,
  Pat(..),
  RecPatField(..),
  Addr,
  Route(..),
  BinderId(..),
  noDeclLoc,
  noBinderId,
}
import types.runtime_types.{BinderRow(..), RuntimeType(..)}
import types.publish.{EntryOutcome}
import support.util.{reverseL}

-- ── expressions ────────────────────────────────────────────────────────────
public export data CExpr =
  | CLit Lit
  -- a variable, carrying its resolved lexical address (slice-1: by-name lookup,
  -- address unconsumed — see header).  `AGlobal` = top-level / extern / ctor.
  | CVar String Addr
  -- an application: the head, its arguments (never empty) and how the call is
  -- made.  A spine is one node: the head is never itself an application.
  | CApp CExpr (List CExpr) CallSite
  | CLam (List Pat) CExpr
  -- rec? pat = rhs in body
  | CLet Bool Pat CExpr CExpr
  -- a `where` / let-group: mutually-recursive coalesced bindings, then a body
  | CLetGroup (List CBind) CExpr
  | CMatch CExpr (List CArm)
  -- a `match` compiled to a DECISION TREE (the §2.1 decision-tree match
  -- compilation, driven by the same Maranget pattern-matrix analysis as
  -- exhaust.mdk): the scrutinee, the original arms (indexed by the tree's
  -- leaves — re-matched to recover bindings + run guards + bodies), and the
  -- compiled tree.  Lowering emits this in place of `CMatch` for every match
  -- whose arm patterns are tree-able; matches that use record/range patterns
  -- fall back to the ordered-arm `CMatch` above.  Semantically equal — the tree
  -- only changes HOW the arm is selected (each scrutinee field's head tested
  -- once across all arms, instead of re-tested per clause).
  | CDecision CExpr (List CArm) CTree
  | CIf CExpr CExpr CExpr
  -- a primitive binary operator that survives lowering: arithmetic (`+`…),
  -- comparison (`==`,`<`…), `::`, `++`.  (`&&`/`||`/`|>`/`>>`/`<<` are lowered
  -- to CIf/CApp/CLam and never appear here.)  The 4th field is the scalar-type
  -- tag stamped by typecheck for a MONOMORPHIC concrete-primitive arithmetic
  -- operand ("Float"/"Int"; "" = unstamped → today's structural/dict path).  The
  -- native emitter reads it (emitBin → fieldNameToLTy → LTFloat) to pick the
  -- primitive without a structural read of the operands
  -- (SHARED-FLOAT-RESIDUAL-DESIGN §3(C)).
  -- A fixed-width tag ("U8"/"U16"/"U32", `ast.fixedWidthMask`) is not only a hint:
  -- every engine MUST reduce an arithmetic result modulo 2^n on it.
  -- The 5th field is the trap site of an overflow or zero-divisor abort: the start
  -- of the left operand, the span the interpreter's `exprStartLoc` names.  An
  -- engine that cannot print a location ignores it.
  | CBinPrim String CExpr CExpr String Loc
  | CUnOp String CExpr
  | CTuple (List CExpr)
  | CList (List CExpr)
  -- record create / field access / update (slice 3)
  -- Every record node carries each field's DECLARED ordinal, stamped by
  -- `core_ir_lower`; an emitter stores and loads by it and keeps no field-order
  -- table.  A `CRecord`'s fields are listed in declared order (ordinal = position).
  | CRecord String (List CField)
  -- field access `r.f`; 3rd = the resolved record name ("" = unknown), 4th = the
  -- field's declared ordinal.  The label `value` is the `Ref` read (`!r`, `r.value`;
  -- the typechecker refuses `.value` on a record) and is always -1 (unstamped),
  -- even when a record declares a field `value`; every other label is stamped.
  | CFieldAccess CExpr String String Int
  -- functional record update `{ base | f = v … }`.  1st = the receiver's record
  -- name, resolved by `core_ir_lower`.  The overrides are listed in strictly
  -- ascending ordinal order; one written out of declared order is bound to
  -- temporaries in written order first, so each override runs once, as written.
  | CRecordUpdate String CExpr (List CField)
  -- named-field variant (constructor) update: `Con { base | f = v … }` (§2.3)
  | CVariantUpdate String CExpr (List CField)
  -- array / range / index / slice (slice 3)
  | CArray (List CExpr)
  | CRangeList CExpr CExpr Bool
  | CRangeArray CExpr CExpr Bool
  | CIndex CExpr CExpr
  | CSlice CExpr CExpr CExpr Bool
  -- String-receiver index/slice.  No lowering produces these any more (#4261).
  -- The String runtime rep is a packed UTF-8 cell,
  -- NOT an i64-element array, so these emit codepoint-indexed char extract /
  -- substring (via @mdk_string_to_chars / @mdk_string_slice) instead of the
  -- array GEP path.  CIndex/CSlice stay array-only (byte-identical emit).
  | CStringIndex CExpr CExpr
  | CStringSlice CExpr CExpr CExpr Bool
  -- List-receiver index/slice; likewise produced by no lowering (#4261).
  -- A List is a chain of Cons cells ([tag|head@8|
  -- tail@16], Nil = odd immediate), NOT a contiguous i64-element array, so these
  -- emit a cons-cell walk (via @mdk_list_index / @mdk_list_slice) instead of the
  -- array GEP path.  CIndex/CSlice stay array-only (byte-identical emit).
  | CListIndex CExpr CExpr
  | CListSlice CExpr CExpr CExpr Bool
  -- a bare sequential block (desugar's EBlock — imperative IO / let-sequencing)
  | CBlock (List CStmt)
  -- typeclass dispatch, dicts explicit (slice 5; Route read out of the AST's
  -- mutable cell at lowering time so the IR is immutable):
  --   CMethod = a method occurrence: its name and its `MethodEvidence`.
  --   CDict   = a constrained-function occurrence, one Route per `=>` constraint.
  | CMethod String MethodEvidence
  | CDict String (List Route)

-- The evidence a method occurrence carries, exactly as elaboration published it
-- (`route_key.evMethodRoutesIn`): the interface word (`""` when the occurrence
-- denotes no interface method, so no engine may narrow by interface), the
-- selected denotation's pre-use arity, the dispatch answer, the selected
-- instance's prerequisite dictionaries, and the method's own context dictionaries.
public export data MethodEvidence = MethodEvidence {
  meIface : String,
  meArity : Int,
  meDispatch : Route,
  mePrereqs : List Route,
  meContext : List Route,
}

-- Every given dictionary name [r] reads, in order: a given's own name, the givens
-- a dictionary built at the site nests in its requires and supers, the given a
-- projection reads, and the givens a shadowing standalone is applied to.
export
givenNames : Route -> List String
givenNames (RDict d) = [d]
givenNames (RDictFwd d) = [d]
givenNames (RKey _ reqs sups) = flatMap givenNames (reqs ++ sups)
givenNames (RProj r _) = givenNames r
givenNames (RLocal _ dicts) = flatMap givenNames dicts
givenNames RNone = []
givenNames (RScalar _) = []

-- [r] is answered by a dictionary that is only known at run time: a given, or a
-- projection out of one.  Accepts any projection without checking its root;
-- core_validate.givenRooted recurses through RProj to check it.
export
isGivenRooted : Route -> Bool
isGivenRooted (RDict _) = True
isGivenRooted (RDictFwd _) = True
isGivenRooted (RProj _ _) = True
isGivenRooted (RKey _ _ _) = False
isGivenRooted (RLocal _ _) = False
isGivenRooted RNone = False
isGivenRooted (RScalar _) = False

-- The canonical key of the instance [r] selects statically, if it selects one.
export
instanceWord : Route -> Option String
instanceWord (RKey word _ _) = Some word
instanceWord _ = None

-- The dictionary of the instance an occurrence selects statically: its word, the
-- prerequisites the occurrence supplies and the supers its dispatch carries.  An
-- inherited default receives it as its receiver.  Evidence that selects no
-- instance statically is its own dispatch answer.
export
receiverEvidence : MethodEvidence -> Route
receiverEvidence (MethodEvidence _ _ (RKey word _ sups) prereqs _) =
  RKey word prereqs sups
receiverEvidence ev = ev.meDispatch

-- How an application is made, from its head's defined arity k and its n
-- arguments.  `core_ir_lower.stampCallModes` decides it for every application a
-- lowering returns, and `core_validate.validateCalls` refuses one that disagrees
-- with `core_ir_lower.definedArityOf`.  Every argument is evaluated, left to
-- right, before the head is applied to any of them, whatever the mode.
public export data CallMode =
  -- n == k
  | CallExact
  -- n < k; the parameters still missing, k - n
  | CallPartial Int
  -- n > k; the arguments applied to the head's result, n - k
  | CallOver Int
  -- the head has no static arity: a local closure, a lambda, a method reached
  -- through a runtime dictionary, a field read, an extern
  | CallDynamic

-- An application's mode and its tail flag.  `core_ir_lower.markTailSites` sets
-- the flag on an application in tail position that is not a partial one, and
-- `core_validate.validateTails` refuses a program that disagrees.  For
-- `CallOver` the flag means the final application of the result is the tail
-- call.  The flag is positional only: whether an emitter turns it into a jump
-- is the emitter's decision.
public export data CallSite = CallSite CallMode Bool

-- An application whose mode is not decided yet.  A lowering's `stampCallModes`
-- decides every mode it returns, and an emitter's own rewrites read none.  A
-- head that is an application is merged into the new node, and no arguments
-- leave the head as it is.
export
mkApp : CExpr -> List CExpr -> CExpr
mkApp f [] = f
mkApp (CApp f args _) more = CApp f (args ++ more) undecidedCall
mkApp f args = CApp f args undecidedCall

undecidedCall : CallSite
undecidedCall = CallSite CallDynamic False

-- a record field assignment `field = expr`: label, declared ordinal (-1 = unstamped), expr
public export data CField = CField String Int CExpr

-- a match arm: pattern, guard qualifiers (fall through to next arm), body
public export data CArm = CArm Pat (List CGuard) CExpr

public export data CGuard = CGBool CExpr | CGBind Pat CExpr

-- ── decision tree (§2.1 decision-tree match compilation) ───────────────────
-- A `CMatch`'s ordered arms re-test the scrutinee's fields once per clause; the
-- decision tree tests each field's head exactly once and routes to the matching
-- arm.  Driven by the SAME Maranget pattern matrix (specialize / default /
-- head-ctors) the exhaust stage uses — only the OUTPUT differs (a tree, not a
-- usefulness verdict).  Leaves carry an arm INDEX rather than inlined bindings:
-- the evaluator re-matches that one arm's pattern against the scrutinee to
-- recover its variable bindings (a single per-arm walk, vs the per-clause
-- re-walk the ordered arms do), so the tree itself only drives DISCRIMINATION
-- and needs no occurrence/binding bookkeeping.  Guard fall-through is preserved
-- by CTGuard: a failed guard resumes the ordered semantics over the matrix rows
-- below the guarded clause (its `fail` subtree, compiled at the same column
-- context, so it reads the same live sub-values).
public export data CTree =
  -- no arm matches → runtime error (mirrors falling off the ordered arms), raised
  -- as the site says
  | CTFail FailSite
  -- arm i matched unconditionally → re-match it for bindings, eval its body
  | CTLeaf Int
  -- arm i matched but is guarded → eval its guards; on guard failure → CTree
  | CTGuard Int CTree
  -- test the focus value's head: first matching branch wins (heads are
  -- disjoint), else the default subtree
  | CTSwitch (List CTBranch) CTree
  -- the focus column is all-wildcard (nothing to test) → discard it, continue
  | CTDrop CTree

-- Which runtime error a decision tree's miss raises, and where.  `NoArm` is an
-- explicit `match` falling off its arms (E-NONEXHAUSTIVE-MATCH, at the `match`
-- keyword); `LetRefuted` is a refutable `let` whose pattern missed (E-LET-REFUTE,
-- at the `let` keyword).  The placeholder span `noDeclLoc` means no location.
-- Two kinds of miss, not a success and a failure, so not a `Result`.
-- lint-disable-next-line rule-clone-type
public export data FailSite = NoArm Loc | LetRefuted Loc

-- one switch branch: the head to test the focus value against, and the subtree
-- taken when it matches (the head's fields become the new leading columns).
public export data CTBranch = CTBranch CHead CTree

-- a constructor / literal "head" a switch tests a runtime Value against.  It
-- carries just enough to (a) statically partition the pattern matrix and (b)
-- dynamically test + decompose the Value via eval.mdk's `matchPat` — so the
-- evaluator needs NO new value-decomposition code (lists are VList, tuples are
-- VTuple, bools VBool, unit VUnit — `matchPat` already knows each).
public export data CHead =
  | HCon String Int
  -- a named constructor (incl. True/False), with its arity
  | HTuple Int
  -- a tuple of the given arity
  | HCons
  -- list cons (arity 2: head element, tail list)
  | HNil
  -- empty list
  | HUnit
  -- the unit value
  | HLit Lit  -- a literal (Int/Float/String/Char), arity 0

-- one block statement (mirrors ast.DoStmt, post-desugar core subset)
public export data CStmt =
  | CSExpr CExpr
  -- `let [rec] pat = e`; the flag is `rec`, as on `CLet`
  | CSLet Bool Pat CExpr
  | CSAssign String CExpr

-- a let-group / top-level function binding: a name with one or more coalesced
-- clauses (multi-clause dispatch + guard fall-through stay structural — the
-- decision-tree compilation of these into a single match is a later 2.1 step).
-- The `Loc` is the first clause's site, which a call that no clause or guard
-- accepts reports; a synthesized binding carries `noDeclLoc`.  The `BinderId`
-- names the function's row in the program's binder table (`DeclFacts`), which
-- gives the type its body returns: the source function's own id (a coalesced
-- top-level function's first clause), or one `core_ir_lower` minted for a
-- binding it made up.
public export data CBind = CBind String (List CClause) Loc BinderId

-- a binding the compiler makes up, which has no source site.
export
synthBind : String -> List CClause -> CBind
synthBind name clauses = CBind name clauses noDeclLoc noBinderId

-- The head of a trap-site literal: `CApp (CVar siteSentinelName _)
-- [CLit (LString file), CLit (LInt line), CLit (LInt col)] _` is the Int a
-- native build packs that site into.  Only the native lowering writes one (as
-- the site argument of `panicAt` and of an `Index` impl's site-carrying twin),
-- because the packing numbers the files of the one program being emitted.
export
siteSentinelName : String
siteSentinelName = "__site__"
public export data CClause = CClause (List Pat) CExpr

-- ── typeclass impls (slice 5) ───────────────────────────────────────────────
-- A lowered typeclass method binding — one impl-method clause, or one instance's
-- entry for an interface default it inherits.  The dispatch decision (concrete type-head
-- tag, dispatch positions, specificity score) is computed at lowering time from the
-- AST's iface + impl decls — exactly as eval.mdk's `declImplEntries` does — so the IR
-- stays Ty-free; only the method body is lowered to `CExpr`.  core_ir_eval turns each
-- entry into a tagged `VTypedImpl` and coalesces same-named candidates into the one
-- `VMulti` the arg-tag dispatcher (`applyValue`) consumes — identical to the AST
-- walker.  One entry PER CLAUSE (multi-clause impl methods coalesce into a VMulti
-- whose clauses fall through, mirroring the AST path).
-- CImplEntry: method name, specificity score, the method's declared value arity
-- (the arrows of its interface signature; an untyped lowering that cannot see
-- the interface gives the entry's own value arity), body.
-- CImplBody:
--   CImplTagged = a method the impl SUPPLIES (concrete type-head tag, the canonical
--     full-type impl key [for type-arg-distinct same-head dispatch, mirrors
--     eval.mdk's VTypedImpl `k`], the interface word (`route_key.ifaceWordOf`, the
--     same qualified word `CImplDefault` and `CMethod` carry), the emitted-symbol
--     words, dispatch positions, the clause's patterns, its lowered body).
--   CImplDefault = a slot the impl INHERITS from its interface's default body, one
--     entry per `InheritedDefault` row of the disposition table
--     (`types/disposition.mdk`): the interface word (`route_key.ifaceWordOf`,
--     the same word the instance's key carries in its first field), the
--     instance's head tag and canonical key, the dispatch positions, and the
--     default's body specialized to the instance (`core_ir_lower.specializeRow`:
--     a call on the receiver to another method of the interface goes straight to
--     the instance's own entry).  Its parameters are the default's method-level
--     dictionaries, then the RECEIVER -- the dictionary that selected this entry,
--     which every engine passes where a supplied method takes its instance's
--     `requires` -- then the value arguments.  It dispatches exactly like
--     the instance's own `CImplTagged` entries; an engine never chooses between two
--     defaults, because every inherited slot has its own entry.
public export data CImplEntry = CImplEntry String Int Int CImplBody
public export data CImplBody =
  | CImplTagged String String String ImplSym (List Int) (List Pat) CExpr
  | CImplDefault String String String ImplSym (List Int) (List Pat) CExpr

-- The emitted-symbol words of an impl entry, stamped once by
-- `core_ir_lower.stampImplSymbols` and read by both emitters, which only prefix
-- and join them.  Fields: the symbol tag (the encoded head tag when the entry is
-- the sole impl of (method, head), else the encoded canonical key -- the `<tag>` of
-- `mdk_impl_<tag>_<method>` and of `$memo_<tag>_<method>`), then, for an inherited
-- default only, the encoded interface word and the encoded instance key that
-- spell `mdk_default_<iface>_<method>_<key>`; both are "" on a supplied method.
-- `noImplSym` is the unstamped sentinel, which `core_validate` refuses.
public export data ImplSym = ImplSym String String String

export
noImplSym : ImplSym
noImplSym = ImplSym "" "" ""

-- ── programs ───────────────────────────────────────────────────────────────
-- The method-context table, the fifth field of `CProgram`: per interface method of the lowered declarations whose
-- own `=>` context has a slot, keyed by `core_ir_lower.ifaceMethodArityKey`, the
-- number of constraints in that context that mention a type variable.  It is read
-- off the declared signature, not the typechecker's evidence, so
-- `core_validate.validateMethodContexts` can hold a `CMethod`'s method routes and an
-- impl entry's leading dictionaries to it.

-- A lowered program: top-level function groups (coalesced multi-clause), the
-- constructor table (name → arity, for building VCon makers), the ctor→type map
-- eval needs for runtime type tags, (slice 5) the lowered typeclass
-- impl/default entries, the method-context table and the declaration facts.
-- Slice-1 programs carry an empty impl list.
public export data CProgram =
  | CProgram (List CBind) (List (String, Int)) (List (String, String)) (List CImplEntry) (List (String, Int)) DeclFacts

-- The declaration facts a dictionary built at a site is held to
-- (`core_validate.validateDispatchEvidence`): each instance's `requires` count,
-- keyed by its canonical key word (`core_ir_lower.instanceReqCounts`), and each of
-- those instances' interfaces' direct superinterface count, keyed by interface
-- word (`disposition.ifaceSuperCount`).  A dictionary stores the supers, then the
-- requires.  Only an emitting lowering fills them; every other lowering carries
-- `noDeclFacts`.
--
-- `factBinders` is the program's binder table: one row per `BinderId` that a
-- binder pattern or a `CBind` in the program carries, in ordinal order, as the
-- typechecker published it (`types.runtime_types`) or as lowering minted it for a
-- binder of its own.  A binder pattern is a `PVar`, a `PAs`, or a record-pattern
-- pun; a `CBind`'s row also gives the type its body returns (`brReturns`).  The
-- table is a snapshot, so the program is self-contained: a consumer never reads
-- the typechecker's published table.  `core_validate.validateBinderStamps` refuses
-- a binder with no row and a function with no return type.
-- Signature facts use declaration identity; callback positions count only value
-- parameters, before dictionary passing adds leading parameters.
public export data MethodResultFact = MethodResultFact {
  iface : String,
  method : String,
  returnsHead : Bool,
  callbackPositions : List Int,
  valueArity : Int,
}
  deriving (Eq, Debug)

public export data DeclFacts = DeclFacts {
  factRequires : List (String, Int),
  factSupers : List (String, Int),
  factBinders : List BinderRow,
  factMethodResults : List MethodResultFact,
  factEntryOutcome : Option EntryOutcome,
}

export
noDeclFacts : DeclFacts
noDeclFacts = DeclFacts {
  factRequires = [],
  factSupers = [],
  factBinders = [],
  factMethodResults = [],
  factEntryOutcome = None,
}

-- ── binder walk ──────────────────────────────────────────────────────────────
-- One traversal of every binder in a program, in a fixed order, with the id each
-- is given by [visit]: first every binder pattern, then every named function
-- (`CBind`), each in program order.  It serves lowering (which mints and
-- snapshots), the s-expression printer (which lists the ids in walk order) and
-- the parser (which hands them back in the same order), so the three cannot
-- disagree about which occurrence is which.
--
-- [visit] gets what kind of binder it is, the binder's name and its id.
export type BinderVisit = BinderSite -> String -> BinderId -> BinderId

-- A binder pattern carries the expression a `let` binds it to (`None` for a
-- parameter, an arm pattern or anything nested in a pattern); a function carries
-- its clauses.  These are two kinds of binder, not a success and a failure, so
-- `Result` cannot stand in for it.
-- lint-disable-next-line rule-clone-type
public export data BinderSite =
  | PatternBinder (Option CExpr)
  | FunctionBinder (List CClause)

-- Which binders one walk visits.  The function pass rebuilds the same tree but
-- leaves every pattern as it is.
data BinderPass = PatternPass | FunctionPass

-- The runtime type a bound expression states for itself, if it does.  An integer
-- literal does not: it is written the same at every numeric type.
export
obviousRuntimeType : CExpr -> Option RuntimeType
obviousRuntimeType (CLit (LInt _)) = None
obviousRuntimeType (CLit l) = Some (litRuntimeType l)
obviousRuntimeType (CTuple _) = Some RTCon
obviousRuntimeType (CList _) = Some RTCon
obviousRuntimeType _ = None

export
litRuntimeType : Lit -> RuntimeType
litRuntimeType (LInt _) = RTInt
litRuntimeType (LFloat _) = RTFloat
litRuntimeType (LString _) = RTString
litRuntimeType (LChar _) = RTChar
litRuntimeType (LBool _) = RTBool
litRuntimeType LUnit = RTUnit
litRuntimeType (LU64 _ _) = RTU64
litRuntimeType (LI64 _ _) = RTI64

export
mapProgramBinders : BinderVisit -> CProgram -> CProgram
mapProgramBinders f prog =
  mapProgramPass FunctionPass f (mapProgramPass PatternPass f prog)

mapProgramPass : BinderPass -> BinderVisit -> CProgram -> CProgram
mapProgramPass pass f (CProgram binds ctorArs ctorTypes impls mctx facts) =
  let w = BinderWalk pass f
  CProgram
    (map (mapBindBinders w) binds)
    ctorArs
    ctorTypes
    (map (mapEntryBinders w) impls)
    mctx
    facts

data BinderWalk = BinderWalk BinderPass BinderVisit

-- [prog] with [rows] as its binder table.
export
withBinderRows : List BinderRow -> CProgram -> CProgram
withBinderRows rows (CProgram groups ctorArs ctorTypes impls mctx facts) = CProgram
  groups
  ctorArs
  ctorTypes
  impls
  mctx
  DeclFacts {
    factRequires = facts.factRequires,
    factSupers = facts.factSupers,
    factBinders = rows,
    factMethodResults = facts.factMethodResults,
    factEntryOutcome = facts.factEntryOutcome,
  }

-- Every binder id of [prog], in walk order.
export
programBinderIds : CProgram -> List BinderId
programBinderIds prog =
  let seen = Ref []
  let _ =
    mapProgramBinders
      (_ _ bid =>
        seen := bid :: !seen
        bid)
      prog
  reverseL !seen

mapEntryBinders : BinderWalk -> CImplEntry -> CImplEntry
mapEntryBinders f (CImplEntry m s d (CImplTagged tag key iface sym pos pats body)) =
  let pats2 = map (mapPatBinders f None) pats
  CImplEntry
    m
    s
    d
    (CImplTagged tag key iface sym pos pats2 (mapExprBinders f body))
mapEntryBinders f (CImplEntry m s d (CImplDefault w tag key sym pos pats body)) =
  let pats2 = map (mapPatBinders f None) pats
  CImplEntry
    m
    s
    d
    (CImplDefault w tag key sym pos pats2 (mapExprBinders f body))

mapBindBinders : BinderWalk -> CBind -> CBind
mapBindBinders w (CBind name clauses site bid) =
  let clauses2 = map (mapClauseBinders w) clauses
  let bid2 = match w
    BinderWalk FunctionPass f => f (FunctionBinder clauses2) name bid
    BinderWalk PatternPass _ => bid
  CBind name clauses2 site bid2

mapClauseBinders : BinderWalk -> CClause -> CClause
mapClauseBinders f (CClause pats body) =
  let pats2 = map (mapPatBinders f None) pats
  CClause pats2 (mapExprBinders f body)

mapPatBinders : BinderWalk -> Option CExpr -> Pat -> Pat
mapPatBinders (BinderWalk FunctionPass _) _ p = p
mapPatBinders (BinderWalk PatternPass f) hint (PVar x l bid) =
  PVar x l (f (PatternBinder hint) x bid)
mapPatBinders _ _ PWild = PWild
mapPatBinders _ _ (PLit l) = PLit l
mapPatBinders f _ (PCon c ps) = PCon c (map (mapPatBinders f None) ps)
mapPatBinders f _ (PCons a b) =
  let a2 = mapPatBinders f None a
  PCons a2 (mapPatBinders f None b)
mapPatBinders f _ (PTuple ps) = PTuple (map (mapPatBinders f None) ps)
mapPatBinders f _ (PList ps) = PList (map (mapPatBinders f None) ps)
mapPatBinders (w@(BinderWalk _ f)) _ (PAs x l bid p) =
  let bid2 = f (PatternBinder None) x bid
  PAs x l bid2 (mapPatBinders w None p)
mapPatBinders _ _ (PRng lo hi incl) = PRng lo hi incl
mapPatBinders f _ (PRec name fields rest) =
  PRec name (map (mapRecFieldBinders f) fields) rest

mapRecFieldBinders : BinderWalk -> RecPatField -> RecPatField
mapRecFieldBinders (BinderWalk _ f) (RecPatField n l bid None) =
  RecPatField n l (f (PatternBinder None) n bid) None
mapRecFieldBinders f (RecPatField n l bid (Some p)) =
  RecPatField n l bid (Some (mapPatBinders f None p))

mapExprBinders : BinderWalk -> CExpr -> CExpr
mapExprBinders _ (CLit l) = CLit l
mapExprBinders _ (CVar x addr) = CVar x addr
mapExprBinders f (CApp h args site) =
  let h2 = mapExprBinders f h
  CApp h2 (map (mapExprBinders f) args) site
mapExprBinders f (CLam pats body) =
  let pats2 = map (mapPatBinders f None) pats
  CLam pats2 (mapExprBinders f body)
mapExprBinders f (CLet recF pat rhs body) =
  let pat2 = mapPatBinders f (Some rhs) pat
  let rhs2 = mapExprBinders f rhs
  CLet recF pat2 rhs2 (mapExprBinders f body)
mapExprBinders f (CLetGroup binds body) =
  let binds2 = map (mapBindBinders f) binds
  CLetGroup binds2 (mapExprBinders f body)
mapExprBinders f (CMatch scrut arms) =
  let scrut2 = mapExprBinders f scrut
  CMatch scrut2 (map (mapArmBinders f) arms)
mapExprBinders f (CDecision scrut arms tree) =
  let scrut2 = mapExprBinders f scrut
  CDecision scrut2 (map (mapArmBinders f) arms) tree
mapExprBinders f (CIf c t e) =
  let c2 = mapExprBinders f c
  let t2 = mapExprBinders f t
  CIf c2 t2 (mapExprBinders f e)
mapExprBinders f (CBinPrim op l r tag site) =
  let l2 = mapExprBinders f l
  CBinPrim op l2 (mapExprBinders f r) tag site
mapExprBinders f (CUnOp op x) = CUnOp op (mapExprBinders f x)
mapExprBinders f (CTuple es) = CTuple (map (mapExprBinders f) es)
mapExprBinders f (CList es) = CList (map (mapExprBinders f) es)
mapExprBinders f (CRecord name fields) =
  CRecord name (map (mapFieldBinders f) fields)
mapExprBinders f (CFieldAccess x label name ord) =
  CFieldAccess (mapExprBinders f x) label name ord
mapExprBinders f (CRecordUpdate name base fields) =
  let base2 = mapExprBinders f base
  CRecordUpdate name base2 (map (mapFieldBinders f) fields)
mapExprBinders f (CVariantUpdate con base fields) =
  let base2 = mapExprBinders f base
  CVariantUpdate con base2 (map (mapFieldBinders f) fields)
mapExprBinders f (CArray es) = CArray (map (mapExprBinders f) es)
mapExprBinders f (CRangeList lo hi incl) =
  let lo2 = mapExprBinders f lo
  CRangeList lo2 (mapExprBinders f hi) incl
mapExprBinders f (CRangeArray lo hi incl) =
  let lo2 = mapExprBinders f lo
  CRangeArray lo2 (mapExprBinders f hi) incl
mapExprBinders f (CIndex a i) =
  let a2 = mapExprBinders f a
  CIndex a2 (mapExprBinders f i)
mapExprBinders f (CSlice a lo hi incl) =
  let a2 = mapExprBinders f a
  let lo2 = mapExprBinders f lo
  CSlice a2 lo2 (mapExprBinders f hi) incl
mapExprBinders f (CStringIndex a i) =
  let a2 = mapExprBinders f a
  CStringIndex a2 (mapExprBinders f i)
mapExprBinders f (CStringSlice a lo hi incl) =
  let a2 = mapExprBinders f a
  let lo2 = mapExprBinders f lo
  CStringSlice a2 lo2 (mapExprBinders f hi) incl
mapExprBinders f (CListIndex a i) =
  let a2 = mapExprBinders f a
  CListIndex a2 (mapExprBinders f i)
mapExprBinders f (CListSlice a lo hi incl) =
  let a2 = mapExprBinders f a
  let lo2 = mapExprBinders f lo
  CListSlice a2 lo2 (mapExprBinders f hi) incl
mapExprBinders f (CBlock stmts) = CBlock (map (mapStmtBinders f) stmts)
mapExprBinders _ (CMethod name ev) = CMethod name ev
mapExprBinders _ (CDict name rs) = CDict name rs

mapFieldBinders : BinderWalk -> CField -> CField
mapFieldBinders f (CField k o e) = CField k o (mapExprBinders f e)

mapArmBinders : BinderWalk -> CArm -> CArm
mapArmBinders f (CArm pat guards body) =
  let pat2 = mapPatBinders f None pat
  let guards2 = map (mapGuardBinders f) guards
  CArm pat2 guards2 (mapExprBinders f body)

mapGuardBinders : BinderWalk -> CGuard -> CGuard
mapGuardBinders f (CGBool c) = CGBool (mapExprBinders f c)
mapGuardBinders f (CGBind pat e) =
  let pat2 = mapPatBinders f None pat
  CGBind pat2 (mapExprBinders f e)

mapStmtBinders : BinderWalk -> CStmt -> CStmt
mapStmtBinders f (CSExpr e) = CSExpr (mapExprBinders f e)
mapStmtBinders f (CSLet recF pat e) =
  let pat2 = mapPatBinders f (Some e) pat
  CSLet recF pat2 (mapExprBinders f e)
mapStmtBinders f (CSAssign x e) = CSAssign x (mapExprBinders f e)
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Lit" true) (mem "Loc" false) (mem "Pat" true) (mem "RecPatField" true) (mem "Addr" false) (mem "Route" true) (mem "BinderId" true) (mem "noDeclLoc" false) (mem "noBinderId" false))))
(DUse false (UseGroup ("types" "runtime_types") ((mem "BinderRow" true) (mem "RuntimeType" true))))
(DUse false (UseGroup ("types" "publish") ((mem "EntryOutcome" false))))
(DUse false (UseGroup ("support" "util") ((mem "reverseL" false))))
(DData Public "CExpr" () ((variant "CLit" (ConPos (TyCon "Lit"))) (variant "CVar" (ConPos (TyCon "String") (TyCon "Addr"))) (variant "CApp" (ConPos (TyCon "CExpr") (TyApp (TyCon "List") (TyCon "CExpr")) (TyCon "CallSite"))) (variant "CLam" (ConPos (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "CExpr"))) (variant "CLet" (ConPos (TyCon "Bool") (TyCon "Pat") (TyCon "CExpr") (TyCon "CExpr"))) (variant "CLetGroup" (ConPos (TyApp (TyCon "List") (TyCon "CBind")) (TyCon "CExpr"))) (variant "CMatch" (ConPos (TyCon "CExpr") (TyApp (TyCon "List") (TyCon "CArm")))) (variant "CDecision" (ConPos (TyCon "CExpr") (TyApp (TyCon "List") (TyCon "CArm")) (TyCon "CTree"))) (variant "CIf" (ConPos (TyCon "CExpr") (TyCon "CExpr") (TyCon "CExpr"))) (variant "CBinPrim" (ConPos (TyCon "String") (TyCon "CExpr") (TyCon "CExpr") (TyCon "String") (TyCon "Loc"))) (variant "CUnOp" (ConPos (TyCon "String") (TyCon "CExpr"))) (variant "CTuple" (ConPos (TyApp (TyCon "List") (TyCon "CExpr")))) (variant "CList" (ConPos (TyApp (TyCon "List") (TyCon "CExpr")))) (variant "CRecord" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyCon "CField")))) (variant "CFieldAccess" (ConPos (TyCon "CExpr") (TyCon "String") (TyCon "String") (TyCon "Int"))) (variant "CRecordUpdate" (ConPos (TyCon "String") (TyCon "CExpr") (TyApp (TyCon "List") (TyCon "CField")))) (variant "CVariantUpdate" (ConPos (TyCon "String") (TyCon "CExpr") (TyApp (TyCon "List") (TyCon "CField")))) (variant "CArray" (ConPos (TyApp (TyCon "List") (TyCon "CExpr")))) (variant "CRangeList" (ConPos (TyCon "CExpr") (TyCon "CExpr") (TyCon "Bool"))) (variant "CRangeArray" (ConPos (TyCon "CExpr") (TyCon "CExpr") (TyCon "Bool"))) (variant "CIndex" (ConPos (TyCon "CExpr") (TyCon "CExpr"))) (variant "CSlice" (ConPos (TyCon "CExpr") (TyCon "CExpr") (TyCon "CExpr") (TyCon "Bool"))) (variant "CStringIndex" (ConPos (TyCon "CExpr") (TyCon "CExpr"))) (variant "CStringSlice" (ConPos (TyCon "CExpr") (TyCon "CExpr") (TyCon "CExpr") (TyCon "Bool"))) (variant "CListIndex" (ConPos (TyCon "CExpr") (TyCon "CExpr"))) (variant "CListSlice" (ConPos (TyCon "CExpr") (TyCon "CExpr") (TyCon "CExpr") (TyCon "Bool"))) (variant "CBlock" (ConPos (TyApp (TyCon "List") (TyCon "CStmt")))) (variant "CMethod" (ConPos (TyCon "String") (TyCon "MethodEvidence"))) (variant "CDict" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyCon "Route"))))) ())
(DData Public "MethodEvidence" () ((variant "MethodEvidence" (ConNamed (field "meIface" (TyCon "String")) (field "meArity" (TyCon "Int")) (field "meDispatch" (TyCon "Route")) (field "mePrereqs" (TyApp (TyCon "List") (TyCon "Route"))) (field "meContext" (TyApp (TyCon "List") (TyCon "Route")))))) ())
(DTypeSig true "givenNames" (TyFun (TyCon "Route") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "givenNames" ((PCon "RDict" (PVar "d"))) (EListLit (EVar "d")))
(DFunDef false "givenNames" ((PCon "RDictFwd" (PVar "d"))) (EListLit (EVar "d")))
(DFunDef false "givenNames" ((PCon "RKey" PWild (PVar "reqs") (PVar "sups"))) (EApp (EApp (EVar "flatMap") (EVar "givenNames")) (EBinOp "++" (EVar "reqs") (EVar "sups"))))
(DFunDef false "givenNames" ((PCon "RProj" (PVar "r") PWild)) (EApp (EVar "givenNames") (EVar "r")))
(DFunDef false "givenNames" ((PCon "RLocal" PWild (PVar "dicts"))) (EApp (EApp (EVar "flatMap") (EVar "givenNames")) (EVar "dicts")))
(DFunDef false "givenNames" ((PCon "RNone")) (EListLit))
(DFunDef false "givenNames" ((PCon "RScalar" PWild)) (EListLit))
(DTypeSig true "isGivenRooted" (TyFun (TyCon "Route") (TyCon "Bool")))
(DFunDef false "isGivenRooted" ((PCon "RDict" PWild)) (EVar "True"))
(DFunDef false "isGivenRooted" ((PCon "RDictFwd" PWild)) (EVar "True"))
(DFunDef false "isGivenRooted" ((PCon "RProj" PWild PWild)) (EVar "True"))
(DFunDef false "isGivenRooted" ((PCon "RKey" PWild PWild PWild)) (EVar "False"))
(DFunDef false "isGivenRooted" ((PCon "RLocal" PWild PWild)) (EVar "False"))
(DFunDef false "isGivenRooted" ((PCon "RNone")) (EVar "False"))
(DFunDef false "isGivenRooted" ((PCon "RScalar" PWild)) (EVar "False"))
(DTypeSig true "instanceWord" (TyFun (TyCon "Route") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "instanceWord" ((PCon "RKey" (PVar "word") PWild PWild)) (EApp (EVar "Some") (EVar "word")))
(DFunDef false "instanceWord" (PWild) (EVar "None"))
(DTypeSig true "receiverEvidence" (TyFun (TyCon "MethodEvidence") (TyCon "Route")))
(DFunDef false "receiverEvidence" ((PCon "MethodEvidence" PWild PWild (PCon "RKey" (PVar "word") PWild (PVar "sups")) (PVar "prereqs") PWild)) (EApp (EApp (EApp (EVar "RKey") (EVar "word")) (EVar "prereqs")) (EVar "sups")))
(DFunDef false "receiverEvidence" ((PVar "ev")) (EFieldAccess (EVar "ev") "meDispatch"))
(DData Public "CallMode" () ((variant "CallExact" (ConPos)) (variant "CallPartial" (ConPos (TyCon "Int"))) (variant "CallOver" (ConPos (TyCon "Int"))) (variant "CallDynamic" (ConPos))) ())
(DData Public "CallSite" () ((variant "CallSite" (ConPos (TyCon "CallMode") (TyCon "Bool")))) ())
(DTypeSig true "mkApp" (TyFun (TyCon "CExpr") (TyFun (TyApp (TyCon "List") (TyCon "CExpr")) (TyCon "CExpr"))))
(DFunDef false "mkApp" ((PVar "f") (PList)) (EVar "f"))
(DFunDef false "mkApp" ((PCon "CApp" (PVar "f") (PVar "args") PWild) (PVar "more")) (EApp (EApp (EApp (EVar "CApp") (EVar "f")) (EBinOp "++" (EVar "args") (EVar "more"))) (EVar "undecidedCall")))
(DFunDef false "mkApp" ((PVar "f") (PVar "args")) (EApp (EApp (EApp (EVar "CApp") (EVar "f")) (EVar "args")) (EVar "undecidedCall")))
(DTypeSig false "undecidedCall" (TyCon "CallSite"))
(DFunDef false "undecidedCall" () (EApp (EApp (EVar "CallSite") (EVar "CallDynamic")) (EVar "False")))
(DData Public "CField" () ((variant "CField" (ConPos (TyCon "String") (TyCon "Int") (TyCon "CExpr")))) ())
(DData Public "CArm" () ((variant "CArm" (ConPos (TyCon "Pat") (TyApp (TyCon "List") (TyCon "CGuard")) (TyCon "CExpr")))) ())
(DData Public "CGuard" () ((variant "CGBool" (ConPos (TyCon "CExpr"))) (variant "CGBind" (ConPos (TyCon "Pat") (TyCon "CExpr")))) ())
(DData Public "CTree" () ((variant "CTFail" (ConPos (TyCon "FailSite"))) (variant "CTLeaf" (ConPos (TyCon "Int"))) (variant "CTGuard" (ConPos (TyCon "Int") (TyCon "CTree"))) (variant "CTSwitch" (ConPos (TyApp (TyCon "List") (TyCon "CTBranch")) (TyCon "CTree"))) (variant "CTDrop" (ConPos (TyCon "CTree")))) ())
(DData Public "FailSite" () ((variant "NoArm" (ConPos (TyCon "Loc"))) (variant "LetRefuted" (ConPos (TyCon "Loc")))) ())
(DData Public "CTBranch" () ((variant "CTBranch" (ConPos (TyCon "CHead") (TyCon "CTree")))) ())
(DData Public "CHead" () ((variant "HCon" (ConPos (TyCon "String") (TyCon "Int"))) (variant "HTuple" (ConPos (TyCon "Int"))) (variant "HCons" (ConPos)) (variant "HNil" (ConPos)) (variant "HUnit" (ConPos)) (variant "HLit" (ConPos (TyCon "Lit")))) ())
(DData Public "CStmt" () ((variant "CSExpr" (ConPos (TyCon "CExpr"))) (variant "CSLet" (ConPos (TyCon "Bool") (TyCon "Pat") (TyCon "CExpr"))) (variant "CSAssign" (ConPos (TyCon "String") (TyCon "CExpr")))) ())
(DData Public "CBind" () ((variant "CBind" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyCon "CClause")) (TyCon "Loc") (TyCon "BinderId")))) ())
(DTypeSig true "synthBind" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "CClause")) (TyCon "CBind"))))
(DFunDef false "synthBind" ((PVar "name") (PVar "clauses")) (EApp (EApp (EApp (EApp (EVar "CBind") (EVar "name")) (EVar "clauses")) (EVar "noDeclLoc")) (EVar "noBinderId")))
(DTypeSig true "siteSentinelName" (TyCon "String"))
(DFunDef false "siteSentinelName" () (ELit (LString "__site__")))
(DData Public "CClause" () ((variant "CClause" (ConPos (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "CExpr")))) ())
(DData Public "CImplEntry" () ((variant "CImplEntry" (ConPos (TyCon "String") (TyCon "Int") (TyCon "Int") (TyCon "CImplBody")))) ())
(DData Public "CImplBody" () ((variant "CImplTagged" (ConPos (TyCon "String") (TyCon "String") (TyCon "String") (TyCon "ImplSym") (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "CExpr"))) (variant "CImplDefault" (ConPos (TyCon "String") (TyCon "String") (TyCon "String") (TyCon "ImplSym") (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "CExpr")))) ())
(DData Public "ImplSym" () ((variant "ImplSym" (ConPos (TyCon "String") (TyCon "String") (TyCon "String")))) ())
(DTypeSig true "noImplSym" (TyCon "ImplSym"))
(DFunDef false "noImplSym" () (EApp (EApp (EApp (EVar "ImplSym") (ELit (LString ""))) (ELit (LString ""))) (ELit (LString ""))))
(DData Public "CProgram" () ((variant "CProgram" (ConPos (TyApp (TyCon "List") (TyCon "CBind")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyCon "DeclFacts")))) ())
(DData Public "MethodResultFact" () ((variant "MethodResultFact" (ConNamed (field "iface" (TyCon "String")) (field "method" (TyCon "String")) (field "returnsHead" (TyCon "Bool")) (field "callbackPositions" (TyApp (TyCon "List") (TyCon "Int"))) (field "valueArity" (TyCon "Int"))))) ())
(DImpl true "Eq" ((TyCon "MethodResultFact")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PRec "MethodResultFact" ((rf "iface" (PVar "__a0")) (rf "method" (PVar "__a1")) (rf "returnsHead" (PVar "__a2")) (rf "callbackPositions" (PVar "__a3")) (rf "valueArity" (PVar "__a4"))) false) (PRec "MethodResultFact" ((rf "iface" (PVar "__b0")) (rf "method" (PVar "__b1")) (rf "returnsHead" (PVar "__b2")) (rf "callbackPositions" (PVar "__b3")) (rf "valueArity" (PVar "__b4"))) false)) () (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EVar "eq") (EVar "__a2")) (EVar "__b2"))) (EApp (EApp (EVar "eq") (EVar "__a3")) (EVar "__b3"))) (EApp (EApp (EVar "eq") (EVar "__a4")) (EVar "__b4"))))))))
(DImpl true "Debug" ((TyCon "MethodResultFact")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PRec "MethodResultFact" ((rf "iface" (PVar "__a0")) (rf "method" (PVar "__a1")) (rf "returnsHead" (PVar "__a2")) (rf "callbackPositions" (PVar "__a3")) (rf "valueArity" (PVar "__a4"))) false) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "MethodResultFact {")) (ELit (LString " iface = "))) (EApp (EVar "debug") (EVar "__a0"))) (ELit (LString ", method = "))) (EApp (EVar "debug") (EVar "__a1"))) (ELit (LString ", returnsHead = "))) (EApp (EVar "debug") (EVar "__a2"))) (ELit (LString ", callbackPositions = "))) (EApp (EVar "debug") (EVar "__a3"))) (ELit (LString ", valueArity = "))) (EApp (EVar "debug") (EVar "__a4"))) (ELit (LString " }"))))))))
(DData Public "DeclFacts" () ((variant "DeclFacts" (ConNamed (field "factRequires" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int")))) (field "factSupers" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int")))) (field "factBinders" (TyApp (TyCon "List") (TyCon "BinderRow"))) (field "factMethodResults" (TyApp (TyCon "List") (TyCon "MethodResultFact"))) (field "factEntryOutcome" (TyApp (TyCon "Option") (TyCon "EntryOutcome")))))) ())
(DTypeSig true "noDeclFacts" (TyCon "DeclFacts"))
(DFunDef false "noDeclFacts" () (ERecordCreate "DeclFacts" ((fa "factRequires" (EListLit)) (fa "factSupers" (EListLit)) (fa "factBinders" (EListLit)) (fa "factMethodResults" (EListLit)) (fa "factEntryOutcome" (EVar "None")))))
(DTypeAlias true "BinderVisit" () (TyFun (TyCon "BinderSite") (TyFun (TyCon "String") (TyFun (TyCon "BinderId") (TyCon "BinderId")))))
(DData Public "BinderSite" () ((variant "PatternBinder" (ConPos (TyApp (TyCon "Option") (TyCon "CExpr")))) (variant "FunctionBinder" (ConPos (TyApp (TyCon "List") (TyCon "CClause"))))) ())
(DData Private "BinderPass" () ((variant "PatternPass" (ConPos)) (variant "FunctionPass" (ConPos))) ())
(DTypeSig true "obviousRuntimeType" (TyFun (TyCon "CExpr") (TyApp (TyCon "Option") (TyCon "RuntimeType"))))
(DFunDef false "obviousRuntimeType" ((PCon "CLit" (PCon "LInt" PWild))) (EVar "None"))
(DFunDef false "obviousRuntimeType" ((PCon "CLit" (PVar "l"))) (EApp (EVar "Some") (EApp (EVar "litRuntimeType") (EVar "l"))))
(DFunDef false "obviousRuntimeType" ((PCon "CTuple" PWild)) (EApp (EVar "Some") (EVar "RTCon")))
(DFunDef false "obviousRuntimeType" ((PCon "CList" PWild)) (EApp (EVar "Some") (EVar "RTCon")))
(DFunDef false "obviousRuntimeType" (PWild) (EVar "None"))
(DTypeSig true "litRuntimeType" (TyFun (TyCon "Lit") (TyCon "RuntimeType")))
(DFunDef false "litRuntimeType" ((PCon "LInt" PWild)) (EVar "RTInt"))
(DFunDef false "litRuntimeType" ((PCon "LFloat" PWild)) (EVar "RTFloat"))
(DFunDef false "litRuntimeType" ((PCon "LString" PWild)) (EVar "RTString"))
(DFunDef false "litRuntimeType" ((PCon "LChar" PWild)) (EVar "RTChar"))
(DFunDef false "litRuntimeType" ((PCon "LBool" PWild)) (EVar "RTBool"))
(DFunDef false "litRuntimeType" ((PCon "LUnit")) (EVar "RTUnit"))
(DFunDef false "litRuntimeType" ((PCon "LU64" PWild PWild)) (EVar "RTU64"))
(DFunDef false "litRuntimeType" ((PCon "LI64" PWild PWild)) (EVar "RTI64"))
(DTypeSig true "mapProgramBinders" (TyFun (TyCon "BinderVisit") (TyFun (TyCon "CProgram") (TyCon "CProgram"))))
(DFunDef false "mapProgramBinders" ((PVar "f") (PVar "prog")) (EApp (EApp (EApp (EVar "mapProgramPass") (EVar "FunctionPass")) (EVar "f")) (EApp (EApp (EApp (EVar "mapProgramPass") (EVar "PatternPass")) (EVar "f")) (EVar "prog"))))
(DTypeSig false "mapProgramPass" (TyFun (TyCon "BinderPass") (TyFun (TyCon "BinderVisit") (TyFun (TyCon "CProgram") (TyCon "CProgram")))))
(DFunDef false "mapProgramPass" ((PVar "pass") (PVar "f") (PCon "CProgram" (PVar "binds") (PVar "ctorArs") (PVar "ctorTypes") (PVar "impls") (PVar "mctx") (PVar "facts"))) (EBlock (DoLet false false (PVar "w") (EApp (EApp (EVar "BinderWalk") (EVar "pass")) (EVar "f"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "CProgram") (EApp (EApp (EVar "map") (EApp (EVar "mapBindBinders") (EVar "w"))) (EVar "binds"))) (EVar "ctorArs")) (EVar "ctorTypes")) (EApp (EApp (EVar "map") (EApp (EVar "mapEntryBinders") (EVar "w"))) (EVar "impls"))) (EVar "mctx")) (EVar "facts")))))
(DData Private "BinderWalk" () ((variant "BinderWalk" (ConPos (TyCon "BinderPass") (TyCon "BinderVisit")))) ())
(DTypeSig true "withBinderRows" (TyFun (TyApp (TyCon "List") (TyCon "BinderRow")) (TyFun (TyCon "CProgram") (TyCon "CProgram"))))
(DFunDef false "withBinderRows" ((PVar "rows") (PCon "CProgram" (PVar "groups") (PVar "ctorArs") (PVar "ctorTypes") (PVar "impls") (PVar "mctx") (PVar "facts"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "CProgram") (EVar "groups")) (EVar "ctorArs")) (EVar "ctorTypes")) (EVar "impls")) (EVar "mctx")) (ERecordCreate "DeclFacts" ((fa "factRequires" (EFieldAccess (EVar "facts") "factRequires")) (fa "factSupers" (EFieldAccess (EVar "facts") "factSupers")) (fa "factBinders" (EVar "rows")) (fa "factMethodResults" (EFieldAccess (EVar "facts") "factMethodResults")) (fa "factEntryOutcome" (EFieldAccess (EVar "facts") "factEntryOutcome"))))))
(DTypeSig true "programBinderIds" (TyFun (TyCon "CProgram") (TyApp (TyCon "List") (TyCon "BinderId"))))
(DFunDef false "programBinderIds" ((PVar "prog")) (EBlock (DoLet false false (PVar "seen") (EApp (EVar "Ref") (EListLit))) (DoLet false false PWild (EApp (EApp (EVar "mapProgramBinders") (ELam (PWild PWild (PVar "bid")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EVar "seen")) (EBinOp "::" (EVar "bid") (EUnOp "!" (EVar "seen"))))) (DoExpr (EVar "bid"))))) (EVar "prog"))) (DoExpr (EApp (EVar "reverseL") (EUnOp "!" (EVar "seen"))))))
(DTypeSig false "mapEntryBinders" (TyFun (TyCon "BinderWalk") (TyFun (TyCon "CImplEntry") (TyCon "CImplEntry"))))
(DFunDef false "mapEntryBinders" ((PVar "f") (PCon "CImplEntry" (PVar "m") (PVar "s") (PVar "d") (PCon "CImplTagged" (PVar "tag") (PVar "key") (PVar "iface") (PVar "sym") (PVar "pos") (PVar "pats") (PVar "body")))) (EBlock (DoLet false false (PVar "pats2") (EApp (EApp (EVar "map") (EApp (EApp (EVar "mapPatBinders") (EVar "f")) (EVar "None"))) (EVar "pats"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "CImplEntry") (EVar "m")) (EVar "s")) (EVar "d")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "CImplTagged") (EVar "tag")) (EVar "key")) (EVar "iface")) (EVar "sym")) (EVar "pos")) (EVar "pats2")) (EApp (EApp (EVar "mapExprBinders") (EVar "f")) (EVar "body")))))))
(DFunDef false "mapEntryBinders" ((PVar "f") (PCon "CImplEntry" (PVar "m") (PVar "s") (PVar "d") (PCon "CImplDefault" (PVar "w") (PVar "tag") (PVar "key") (PVar "sym") (PVar "pos") (PVar "pats") (PVar "body")))) (EBlock (DoLet false false (PVar "pats2") (EApp (EApp (EVar "map") (EApp (EApp (EVar "mapPatBinders") (EVar "f")) (EVar "None"))) (EVar "pats"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "CImplEntry") (EVar "m")) (EVar "s")) (EVar "d")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "CImplDefault") (EVar "w")) (EVar "tag")) (EVar "key")) (EVar "sym")) (EVar "pos")) (EVar "pats2")) (EApp (EApp (EVar "mapExprBinders") (EVar "f")) (EVar "body")))))))
(DTypeSig false "mapBindBinders" (TyFun (TyCon "BinderWalk") (TyFun (TyCon "CBind") (TyCon "CBind"))))
(DFunDef false "mapBindBinders" ((PVar "w") (PCon "CBind" (PVar "name") (PVar "clauses") (PVar "site") (PVar "bid"))) (EBlock (DoLet false false (PVar "clauses2") (EApp (EApp (EVar "map") (EApp (EVar "mapClauseBinders") (EVar "w"))) (EVar "clauses"))) (DoLet false false (PVar "bid2") (EMatch (EVar "w") (arm (PCon "BinderWalk" (PCon "FunctionPass") (PVar "f")) () (EApp (EApp (EApp (EVar "f") (EApp (EVar "FunctionBinder") (EVar "clauses2"))) (EVar "name")) (EVar "bid"))) (arm (PCon "BinderWalk" (PCon "PatternPass") PWild) () (EVar "bid")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "CBind") (EVar "name")) (EVar "clauses2")) (EVar "site")) (EVar "bid2")))))
(DTypeSig false "mapClauseBinders" (TyFun (TyCon "BinderWalk") (TyFun (TyCon "CClause") (TyCon "CClause"))))
(DFunDef false "mapClauseBinders" ((PVar "f") (PCon "CClause" (PVar "pats") (PVar "body"))) (EBlock (DoLet false false (PVar "pats2") (EApp (EApp (EVar "map") (EApp (EApp (EVar "mapPatBinders") (EVar "f")) (EVar "None"))) (EVar "pats"))) (DoExpr (EApp (EApp (EVar "CClause") (EVar "pats2")) (EApp (EApp (EVar "mapExprBinders") (EVar "f")) (EVar "body"))))))
(DTypeSig false "mapPatBinders" (TyFun (TyCon "BinderWalk") (TyFun (TyApp (TyCon "Option") (TyCon "CExpr")) (TyFun (TyCon "Pat") (TyCon "Pat")))))
(DFunDef false "mapPatBinders" ((PCon "BinderWalk" (PCon "FunctionPass") PWild) PWild (PVar "p")) (EVar "p"))
(DFunDef false "mapPatBinders" ((PCon "BinderWalk" (PCon "PatternPass") (PVar "f")) (PVar "hint") (PCon "PVar" (PVar "x") (PVar "l") (PVar "bid"))) (EApp (EApp (EApp (EVar "PVar") (EVar "x")) (EVar "l")) (EApp (EApp (EApp (EVar "f") (EApp (EVar "PatternBinder") (EVar "hint"))) (EVar "x")) (EVar "bid"))))
(DFunDef false "mapPatBinders" (PWild PWild (PCon "PWild")) (EVar "PWild"))
(DFunDef false "mapPatBinders" (PWild PWild (PCon "PLit" (PVar "l"))) (EApp (EVar "PLit") (EVar "l")))
(DFunDef false "mapPatBinders" ((PVar "f") PWild (PCon "PCon" (PVar "c") (PVar "ps"))) (EApp (EApp (EVar "PCon") (EVar "c")) (EApp (EApp (EVar "map") (EApp (EApp (EVar "mapPatBinders") (EVar "f")) (EVar "None"))) (EVar "ps"))))
(DFunDef false "mapPatBinders" ((PVar "f") PWild (PCon "PCons" (PVar "a") (PVar "b"))) (EBlock (DoLet false false (PVar "a2") (EApp (EApp (EApp (EVar "mapPatBinders") (EVar "f")) (EVar "None")) (EVar "a"))) (DoExpr (EApp (EApp (EVar "PCons") (EVar "a2")) (EApp (EApp (EApp (EVar "mapPatBinders") (EVar "f")) (EVar "None")) (EVar "b"))))))
(DFunDef false "mapPatBinders" ((PVar "f") PWild (PCon "PTuple" (PVar "ps"))) (EApp (EVar "PTuple") (EApp (EApp (EVar "map") (EApp (EApp (EVar "mapPatBinders") (EVar "f")) (EVar "None"))) (EVar "ps"))))
(DFunDef false "mapPatBinders" ((PVar "f") PWild (PCon "PList" (PVar "ps"))) (EApp (EVar "PList") (EApp (EApp (EVar "map") (EApp (EApp (EVar "mapPatBinders") (EVar "f")) (EVar "None"))) (EVar "ps"))))
(DFunDef false "mapPatBinders" ((PAs "w" (PCon "BinderWalk" PWild (PVar "f"))) PWild (PCon "PAs" (PVar "x") (PVar "l") (PVar "bid") (PVar "p"))) (EBlock (DoLet false false (PVar "bid2") (EApp (EApp (EApp (EVar "f") (EApp (EVar "PatternBinder") (EVar "None"))) (EVar "x")) (EVar "bid"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "PAs") (EVar "x")) (EVar "l")) (EVar "bid2")) (EApp (EApp (EApp (EVar "mapPatBinders") (EVar "w")) (EVar "None")) (EVar "p"))))))
(DFunDef false "mapPatBinders" (PWild PWild (PCon "PRng" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EVar "PRng") (EVar "lo")) (EVar "hi")) (EVar "incl")))
(DFunDef false "mapPatBinders" ((PVar "f") PWild (PCon "PRec" (PVar "name") (PVar "fields") (PVar "rest"))) (EApp (EApp (EApp (EVar "PRec") (EVar "name")) (EApp (EApp (EVar "map") (EApp (EVar "mapRecFieldBinders") (EVar "f"))) (EVar "fields"))) (EVar "rest")))
(DTypeSig false "mapRecFieldBinders" (TyFun (TyCon "BinderWalk") (TyFun (TyCon "RecPatField") (TyCon "RecPatField"))))
(DFunDef false "mapRecFieldBinders" ((PCon "BinderWalk" PWild (PVar "f")) (PCon "RecPatField" (PVar "n") (PVar "l") (PVar "bid") (PCon "None"))) (EApp (EApp (EApp (EApp (EVar "RecPatField") (EVar "n")) (EVar "l")) (EApp (EApp (EApp (EVar "f") (EApp (EVar "PatternBinder") (EVar "None"))) (EVar "n")) (EVar "bid"))) (EVar "None")))
(DFunDef false "mapRecFieldBinders" ((PVar "f") (PCon "RecPatField" (PVar "n") (PVar "l") (PVar "bid") (PCon "Some" (PVar "p")))) (EApp (EApp (EApp (EApp (EVar "RecPatField") (EVar "n")) (EVar "l")) (EVar "bid")) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "mapPatBinders") (EVar "f")) (EVar "None")) (EVar "p")))))
(DTypeSig false "mapExprBinders" (TyFun (TyCon "BinderWalk") (TyFun (TyCon "CExpr") (TyCon "CExpr"))))
(DFunDef false "mapExprBinders" (PWild (PCon "CLit" (PVar "l"))) (EApp (EVar "CLit") (EVar "l")))
(DFunDef false "mapExprBinders" (PWild (PCon "CVar" (PVar "x") (PVar "addr"))) (EApp (EApp (EVar "CVar") (EVar "x")) (EVar "addr")))
(DFunDef false "mapExprBinders" ((PVar "f") (PCon "CApp" (PVar "h") (PVar "args") (PVar "site"))) (EBlock (DoLet false false (PVar "h2") (EApp (EApp (EVar "mapExprBinders") (EVar "f")) (EVar "h"))) (DoExpr (EApp (EApp (EApp (EVar "CApp") (EVar "h2")) (EApp (EApp (EVar "map") (EApp (EVar "mapExprBinders") (EVar "f"))) (EVar "args"))) (EVar "site")))))
(DFunDef false "mapExprBinders" ((PVar "f") (PCon "CLam" (PVar "pats") (PVar "body"))) (EBlock (DoLet false false (PVar "pats2") (EApp (EApp (EVar "map") (EApp (EApp (EVar "mapPatBinders") (EVar "f")) (EVar "None"))) (EVar "pats"))) (DoExpr (EApp (EApp (EVar "CLam") (EVar "pats2")) (EApp (EApp (EVar "mapExprBinders") (EVar "f")) (EVar "body"))))))
(DFunDef false "mapExprBinders" ((PVar "f") (PCon "CLet" (PVar "recF") (PVar "pat") (PVar "rhs") (PVar "body"))) (EBlock (DoLet false false (PVar "pat2") (EApp (EApp (EApp (EVar "mapPatBinders") (EVar "f")) (EApp (EVar "Some") (EVar "rhs"))) (EVar "pat"))) (DoLet false false (PVar "rhs2") (EApp (EApp (EVar "mapExprBinders") (EVar "f")) (EVar "rhs"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "CLet") (EVar "recF")) (EVar "pat2")) (EVar "rhs2")) (EApp (EApp (EVar "mapExprBinders") (EVar "f")) (EVar "body"))))))
(DFunDef false "mapExprBinders" ((PVar "f") (PCon "CLetGroup" (PVar "binds") (PVar "body"))) (EBlock (DoLet false false (PVar "binds2") (EApp (EApp (EVar "map") (EApp (EVar "mapBindBinders") (EVar "f"))) (EVar "binds"))) (DoExpr (EApp (EApp (EVar "CLetGroup") (EVar "binds2")) (EApp (EApp (EVar "mapExprBinders") (EVar "f")) (EVar "body"))))))
(DFunDef false "mapExprBinders" ((PVar "f") (PCon "CMatch" (PVar "scrut") (PVar "arms"))) (EBlock (DoLet false false (PVar "scrut2") (EApp (EApp (EVar "mapExprBinders") (EVar "f")) (EVar "scrut"))) (DoExpr (EApp (EApp (EVar "CMatch") (EVar "scrut2")) (EApp (EApp (EVar "map") (EApp (EVar "mapArmBinders") (EVar "f"))) (EVar "arms"))))))
(DFunDef false "mapExprBinders" ((PVar "f") (PCon "CDecision" (PVar "scrut") (PVar "arms") (PVar "tree"))) (EBlock (DoLet false false (PVar "scrut2") (EApp (EApp (EVar "mapExprBinders") (EVar "f")) (EVar "scrut"))) (DoExpr (EApp (EApp (EApp (EVar "CDecision") (EVar "scrut2")) (EApp (EApp (EVar "map") (EApp (EVar "mapArmBinders") (EVar "f"))) (EVar "arms"))) (EVar "tree")))))
(DFunDef false "mapExprBinders" ((PVar "f") (PCon "CIf" (PVar "c") (PVar "t") (PVar "e"))) (EBlock (DoLet false false (PVar "c2") (EApp (EApp (EVar "mapExprBinders") (EVar "f")) (EVar "c"))) (DoLet false false (PVar "t2") (EApp (EApp (EVar "mapExprBinders") (EVar "f")) (EVar "t"))) (DoExpr (EApp (EApp (EApp (EVar "CIf") (EVar "c2")) (EVar "t2")) (EApp (EApp (EVar "mapExprBinders") (EVar "f")) (EVar "e"))))))
(DFunDef false "mapExprBinders" ((PVar "f") (PCon "CBinPrim" (PVar "op") (PVar "l") (PVar "r") (PVar "tag") (PVar "site"))) (EBlock (DoLet false false (PVar "l2") (EApp (EApp (EVar "mapExprBinders") (EVar "f")) (EVar "l"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "CBinPrim") (EVar "op")) (EVar "l2")) (EApp (EApp (EVar "mapExprBinders") (EVar "f")) (EVar "r"))) (EVar "tag")) (EVar "site")))))
(DFunDef false "mapExprBinders" ((PVar "f") (PCon "CUnOp" (PVar "op") (PVar "x"))) (EApp (EApp (EVar "CUnOp") (EVar "op")) (EApp (EApp (EVar "mapExprBinders") (EVar "f")) (EVar "x"))))
(DFunDef false "mapExprBinders" ((PVar "f") (PCon "CTuple" (PVar "es"))) (EApp (EVar "CTuple") (EApp (EApp (EVar "map") (EApp (EVar "mapExprBinders") (EVar "f"))) (EVar "es"))))
(DFunDef false "mapExprBinders" ((PVar "f") (PCon "CList" (PVar "es"))) (EApp (EVar "CList") (EApp (EApp (EVar "map") (EApp (EVar "mapExprBinders") (EVar "f"))) (EVar "es"))))
(DFunDef false "mapExprBinders" ((PVar "f") (PCon "CRecord" (PVar "name") (PVar "fields"))) (EApp (EApp (EVar "CRecord") (EVar "name")) (EApp (EApp (EVar "map") (EApp (EVar "mapFieldBinders") (EVar "f"))) (EVar "fields"))))
(DFunDef false "mapExprBinders" ((PVar "f") (PCon "CFieldAccess" (PVar "x") (PVar "label") (PVar "name") (PVar "ord"))) (EApp (EApp (EApp (EApp (EVar "CFieldAccess") (EApp (EApp (EVar "mapExprBinders") (EVar "f")) (EVar "x"))) (EVar "label")) (EVar "name")) (EVar "ord")))
(DFunDef false "mapExprBinders" ((PVar "f") (PCon "CRecordUpdate" (PVar "name") (PVar "base") (PVar "fields"))) (EBlock (DoLet false false (PVar "base2") (EApp (EApp (EVar "mapExprBinders") (EVar "f")) (EVar "base"))) (DoExpr (EApp (EApp (EApp (EVar "CRecordUpdate") (EVar "name")) (EVar "base2")) (EApp (EApp (EVar "map") (EApp (EVar "mapFieldBinders") (EVar "f"))) (EVar "fields"))))))
(DFunDef false "mapExprBinders" ((PVar "f") (PCon "CVariantUpdate" (PVar "con") (PVar "base") (PVar "fields"))) (EBlock (DoLet false false (PVar "base2") (EApp (EApp (EVar "mapExprBinders") (EVar "f")) (EVar "base"))) (DoExpr (EApp (EApp (EApp (EVar "CVariantUpdate") (EVar "con")) (EVar "base2")) (EApp (EApp (EVar "map") (EApp (EVar "mapFieldBinders") (EVar "f"))) (EVar "fields"))))))
(DFunDef false "mapExprBinders" ((PVar "f") (PCon "CArray" (PVar "es"))) (EApp (EVar "CArray") (EApp (EApp (EVar "map") (EApp (EVar "mapExprBinders") (EVar "f"))) (EVar "es"))))
(DFunDef false "mapExprBinders" ((PVar "f") (PCon "CRangeList" (PVar "lo") (PVar "hi") (PVar "incl"))) (EBlock (DoLet false false (PVar "lo2") (EApp (EApp (EVar "mapExprBinders") (EVar "f")) (EVar "lo"))) (DoExpr (EApp (EApp (EApp (EVar "CRangeList") (EVar "lo2")) (EApp (EApp (EVar "mapExprBinders") (EVar "f")) (EVar "hi"))) (EVar "incl")))))
(DFunDef false "mapExprBinders" ((PVar "f") (PCon "CRangeArray" (PVar "lo") (PVar "hi") (PVar "incl"))) (EBlock (DoLet false false (PVar "lo2") (EApp (EApp (EVar "mapExprBinders") (EVar "f")) (EVar "lo"))) (DoExpr (EApp (EApp (EApp (EVar "CRangeArray") (EVar "lo2")) (EApp (EApp (EVar "mapExprBinders") (EVar "f")) (EVar "hi"))) (EVar "incl")))))
(DFunDef false "mapExprBinders" ((PVar "f") (PCon "CIndex" (PVar "a") (PVar "i"))) (EBlock (DoLet false false (PVar "a2") (EApp (EApp (EVar "mapExprBinders") (EVar "f")) (EVar "a"))) (DoExpr (EApp (EApp (EVar "CIndex") (EVar "a2")) (EApp (EApp (EVar "mapExprBinders") (EVar "f")) (EVar "i"))))))
(DFunDef false "mapExprBinders" ((PVar "f") (PCon "CSlice" (PVar "a") (PVar "lo") (PVar "hi") (PVar "incl"))) (EBlock (DoLet false false (PVar "a2") (EApp (EApp (EVar "mapExprBinders") (EVar "f")) (EVar "a"))) (DoLet false false (PVar "lo2") (EApp (EApp (EVar "mapExprBinders") (EVar "f")) (EVar "lo"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "CSlice") (EVar "a2")) (EVar "lo2")) (EApp (EApp (EVar "mapExprBinders") (EVar "f")) (EVar "hi"))) (EVar "incl")))))
(DFunDef false "mapExprBinders" ((PVar "f") (PCon "CStringIndex" (PVar "a") (PVar "i"))) (EBlock (DoLet false false (PVar "a2") (EApp (EApp (EVar "mapExprBinders") (EVar "f")) (EVar "a"))) (DoExpr (EApp (EApp (EVar "CStringIndex") (EVar "a2")) (EApp (EApp (EVar "mapExprBinders") (EVar "f")) (EVar "i"))))))
(DFunDef false "mapExprBinders" ((PVar "f") (PCon "CStringSlice" (PVar "a") (PVar "lo") (PVar "hi") (PVar "incl"))) (EBlock (DoLet false false (PVar "a2") (EApp (EApp (EVar "mapExprBinders") (EVar "f")) (EVar "a"))) (DoLet false false (PVar "lo2") (EApp (EApp (EVar "mapExprBinders") (EVar "f")) (EVar "lo"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "CStringSlice") (EVar "a2")) (EVar "lo2")) (EApp (EApp (EVar "mapExprBinders") (EVar "f")) (EVar "hi"))) (EVar "incl")))))
(DFunDef false "mapExprBinders" ((PVar "f") (PCon "CListIndex" (PVar "a") (PVar "i"))) (EBlock (DoLet false false (PVar "a2") (EApp (EApp (EVar "mapExprBinders") (EVar "f")) (EVar "a"))) (DoExpr (EApp (EApp (EVar "CListIndex") (EVar "a2")) (EApp (EApp (EVar "mapExprBinders") (EVar "f")) (EVar "i"))))))
(DFunDef false "mapExprBinders" ((PVar "f") (PCon "CListSlice" (PVar "a") (PVar "lo") (PVar "hi") (PVar "incl"))) (EBlock (DoLet false false (PVar "a2") (EApp (EApp (EVar "mapExprBinders") (EVar "f")) (EVar "a"))) (DoLet false false (PVar "lo2") (EApp (EApp (EVar "mapExprBinders") (EVar "f")) (EVar "lo"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "CListSlice") (EVar "a2")) (EVar "lo2")) (EApp (EApp (EVar "mapExprBinders") (EVar "f")) (EVar "hi"))) (EVar "incl")))))
(DFunDef false "mapExprBinders" ((PVar "f") (PCon "CBlock" (PVar "stmts"))) (EApp (EVar "CBlock") (EApp (EApp (EVar "map") (EApp (EVar "mapStmtBinders") (EVar "f"))) (EVar "stmts"))))
(DFunDef false "mapExprBinders" (PWild (PCon "CMethod" (PVar "name") (PVar "ev"))) (EApp (EApp (EVar "CMethod") (EVar "name")) (EVar "ev")))
(DFunDef false "mapExprBinders" (PWild (PCon "CDict" (PVar "name") (PVar "rs"))) (EApp (EApp (EVar "CDict") (EVar "name")) (EVar "rs")))
(DTypeSig false "mapFieldBinders" (TyFun (TyCon "BinderWalk") (TyFun (TyCon "CField") (TyCon "CField"))))
(DFunDef false "mapFieldBinders" ((PVar "f") (PCon "CField" (PVar "k") (PVar "o") (PVar "e"))) (EApp (EApp (EApp (EVar "CField") (EVar "k")) (EVar "o")) (EApp (EApp (EVar "mapExprBinders") (EVar "f")) (EVar "e"))))
(DTypeSig false "mapArmBinders" (TyFun (TyCon "BinderWalk") (TyFun (TyCon "CArm") (TyCon "CArm"))))
(DFunDef false "mapArmBinders" ((PVar "f") (PCon "CArm" (PVar "pat") (PVar "guards") (PVar "body"))) (EBlock (DoLet false false (PVar "pat2") (EApp (EApp (EApp (EVar "mapPatBinders") (EVar "f")) (EVar "None")) (EVar "pat"))) (DoLet false false (PVar "guards2") (EApp (EApp (EVar "map") (EApp (EVar "mapGuardBinders") (EVar "f"))) (EVar "guards"))) (DoExpr (EApp (EApp (EApp (EVar "CArm") (EVar "pat2")) (EVar "guards2")) (EApp (EApp (EVar "mapExprBinders") (EVar "f")) (EVar "body"))))))
(DTypeSig false "mapGuardBinders" (TyFun (TyCon "BinderWalk") (TyFun (TyCon "CGuard") (TyCon "CGuard"))))
(DFunDef false "mapGuardBinders" ((PVar "f") (PCon "CGBool" (PVar "c"))) (EApp (EVar "CGBool") (EApp (EApp (EVar "mapExprBinders") (EVar "f")) (EVar "c"))))
(DFunDef false "mapGuardBinders" ((PVar "f") (PCon "CGBind" (PVar "pat") (PVar "e"))) (EBlock (DoLet false false (PVar "pat2") (EApp (EApp (EApp (EVar "mapPatBinders") (EVar "f")) (EVar "None")) (EVar "pat"))) (DoExpr (EApp (EApp (EVar "CGBind") (EVar "pat2")) (EApp (EApp (EVar "mapExprBinders") (EVar "f")) (EVar "e"))))))
(DTypeSig false "mapStmtBinders" (TyFun (TyCon "BinderWalk") (TyFun (TyCon "CStmt") (TyCon "CStmt"))))
(DFunDef false "mapStmtBinders" ((PVar "f") (PCon "CSExpr" (PVar "e"))) (EApp (EVar "CSExpr") (EApp (EApp (EVar "mapExprBinders") (EVar "f")) (EVar "e"))))
(DFunDef false "mapStmtBinders" ((PVar "f") (PCon "CSLet" (PVar "recF") (PVar "pat") (PVar "e"))) (EBlock (DoLet false false (PVar "pat2") (EApp (EApp (EApp (EVar "mapPatBinders") (EVar "f")) (EApp (EVar "Some") (EVar "e"))) (EVar "pat"))) (DoExpr (EApp (EApp (EApp (EVar "CSLet") (EVar "recF")) (EVar "pat2")) (EApp (EApp (EVar "mapExprBinders") (EVar "f")) (EVar "e"))))))
(DFunDef false "mapStmtBinders" ((PVar "f") (PCon "CSAssign" (PVar "x") (PVar "e"))) (EApp (EApp (EVar "CSAssign") (EVar "x")) (EApp (EApp (EVar "mapExprBinders") (EVar "f")) (EVar "e"))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Lit" true) (mem "Loc" false) (mem "Pat" true) (mem "RecPatField" true) (mem "Addr" false) (mem "Route" true) (mem "BinderId" true) (mem "noDeclLoc" false) (mem "noBinderId" false))))
(DUse false (UseGroup ("types" "runtime_types") ((mem "BinderRow" true) (mem "RuntimeType" true))))
(DUse false (UseGroup ("types" "publish") ((mem "EntryOutcome" false))))
(DUse false (UseGroup ("support" "util") ((mem "reverseL" false))))
(DData Public "CExpr" () ((variant "CLit" (ConPos (TyCon "Lit"))) (variant "CVar" (ConPos (TyCon "String") (TyCon "Addr"))) (variant "CApp" (ConPos (TyCon "CExpr") (TyApp (TyCon "List") (TyCon "CExpr")) (TyCon "CallSite"))) (variant "CLam" (ConPos (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "CExpr"))) (variant "CLet" (ConPos (TyCon "Bool") (TyCon "Pat") (TyCon "CExpr") (TyCon "CExpr"))) (variant "CLetGroup" (ConPos (TyApp (TyCon "List") (TyCon "CBind")) (TyCon "CExpr"))) (variant "CMatch" (ConPos (TyCon "CExpr") (TyApp (TyCon "List") (TyCon "CArm")))) (variant "CDecision" (ConPos (TyCon "CExpr") (TyApp (TyCon "List") (TyCon "CArm")) (TyCon "CTree"))) (variant "CIf" (ConPos (TyCon "CExpr") (TyCon "CExpr") (TyCon "CExpr"))) (variant "CBinPrim" (ConPos (TyCon "String") (TyCon "CExpr") (TyCon "CExpr") (TyCon "String") (TyCon "Loc"))) (variant "CUnOp" (ConPos (TyCon "String") (TyCon "CExpr"))) (variant "CTuple" (ConPos (TyApp (TyCon "List") (TyCon "CExpr")))) (variant "CList" (ConPos (TyApp (TyCon "List") (TyCon "CExpr")))) (variant "CRecord" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyCon "CField")))) (variant "CFieldAccess" (ConPos (TyCon "CExpr") (TyCon "String") (TyCon "String") (TyCon "Int"))) (variant "CRecordUpdate" (ConPos (TyCon "String") (TyCon "CExpr") (TyApp (TyCon "List") (TyCon "CField")))) (variant "CVariantUpdate" (ConPos (TyCon "String") (TyCon "CExpr") (TyApp (TyCon "List") (TyCon "CField")))) (variant "CArray" (ConPos (TyApp (TyCon "List") (TyCon "CExpr")))) (variant "CRangeList" (ConPos (TyCon "CExpr") (TyCon "CExpr") (TyCon "Bool"))) (variant "CRangeArray" (ConPos (TyCon "CExpr") (TyCon "CExpr") (TyCon "Bool"))) (variant "CIndex" (ConPos (TyCon "CExpr") (TyCon "CExpr"))) (variant "CSlice" (ConPos (TyCon "CExpr") (TyCon "CExpr") (TyCon "CExpr") (TyCon "Bool"))) (variant "CStringIndex" (ConPos (TyCon "CExpr") (TyCon "CExpr"))) (variant "CStringSlice" (ConPos (TyCon "CExpr") (TyCon "CExpr") (TyCon "CExpr") (TyCon "Bool"))) (variant "CListIndex" (ConPos (TyCon "CExpr") (TyCon "CExpr"))) (variant "CListSlice" (ConPos (TyCon "CExpr") (TyCon "CExpr") (TyCon "CExpr") (TyCon "Bool"))) (variant "CBlock" (ConPos (TyApp (TyCon "List") (TyCon "CStmt")))) (variant "CMethod" (ConPos (TyCon "String") (TyCon "MethodEvidence"))) (variant "CDict" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyCon "Route"))))) ())
(DData Public "MethodEvidence" () ((variant "MethodEvidence" (ConNamed (field "meIface" (TyCon "String")) (field "meArity" (TyCon "Int")) (field "meDispatch" (TyCon "Route")) (field "mePrereqs" (TyApp (TyCon "List") (TyCon "Route"))) (field "meContext" (TyApp (TyCon "List") (TyCon "Route")))))) ())
(DTypeSig true "givenNames" (TyFun (TyCon "Route") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "givenNames" ((PCon "RDict" (PVar "d"))) (EListLit (EVar "d")))
(DFunDef false "givenNames" ((PCon "RDictFwd" (PVar "d"))) (EListLit (EVar "d")))
(DFunDef false "givenNames" ((PCon "RKey" PWild (PVar "reqs") (PVar "sups"))) (EApp (EApp (EDictApp "flatMap") (EVar "givenNames")) (EBinOp "++" (EVar "reqs") (EVar "sups"))))
(DFunDef false "givenNames" ((PCon "RProj" (PVar "r") PWild)) (EApp (EVar "givenNames") (EVar "r")))
(DFunDef false "givenNames" ((PCon "RLocal" PWild (PVar "dicts"))) (EApp (EApp (EDictApp "flatMap") (EVar "givenNames")) (EVar "dicts")))
(DFunDef false "givenNames" ((PCon "RNone")) (EListLit))
(DFunDef false "givenNames" ((PCon "RScalar" PWild)) (EListLit))
(DTypeSig true "isGivenRooted" (TyFun (TyCon "Route") (TyCon "Bool")))
(DFunDef false "isGivenRooted" ((PCon "RDict" PWild)) (EVar "True"))
(DFunDef false "isGivenRooted" ((PCon "RDictFwd" PWild)) (EVar "True"))
(DFunDef false "isGivenRooted" ((PCon "RProj" PWild PWild)) (EVar "True"))
(DFunDef false "isGivenRooted" ((PCon "RKey" PWild PWild PWild)) (EVar "False"))
(DFunDef false "isGivenRooted" ((PCon "RLocal" PWild PWild)) (EVar "False"))
(DFunDef false "isGivenRooted" ((PCon "RNone")) (EVar "False"))
(DFunDef false "isGivenRooted" ((PCon "RScalar" PWild)) (EVar "False"))
(DTypeSig true "instanceWord" (TyFun (TyCon "Route") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "instanceWord" ((PCon "RKey" (PVar "word") PWild PWild)) (EApp (EVar "Some") (EVar "word")))
(DFunDef false "instanceWord" (PWild) (EVar "None"))
(DTypeSig true "receiverEvidence" (TyFun (TyCon "MethodEvidence") (TyCon "Route")))
(DFunDef false "receiverEvidence" ((PCon "MethodEvidence" PWild PWild (PCon "RKey" (PVar "word") PWild (PVar "sups")) (PVar "prereqs") PWild)) (EApp (EApp (EApp (EVar "RKey") (EVar "word")) (EVar "prereqs")) (EVar "sups")))
(DFunDef false "receiverEvidence" ((PVar "ev")) (EFieldAccess (EVar "ev") "meDispatch"))
(DData Public "CallMode" () ((variant "CallExact" (ConPos)) (variant "CallPartial" (ConPos (TyCon "Int"))) (variant "CallOver" (ConPos (TyCon "Int"))) (variant "CallDynamic" (ConPos))) ())
(DData Public "CallSite" () ((variant "CallSite" (ConPos (TyCon "CallMode") (TyCon "Bool")))) ())
(DTypeSig true "mkApp" (TyFun (TyCon "CExpr") (TyFun (TyApp (TyCon "List") (TyCon "CExpr")) (TyCon "CExpr"))))
(DFunDef false "mkApp" ((PVar "f") (PList)) (EVar "f"))
(DFunDef false "mkApp" ((PCon "CApp" (PVar "f") (PVar "args") PWild) (PVar "more")) (EApp (EApp (EApp (EVar "CApp") (EVar "f")) (EBinOp "++" (EVar "args") (EVar "more"))) (EVar "undecidedCall")))
(DFunDef false "mkApp" ((PVar "f") (PVar "args")) (EApp (EApp (EApp (EVar "CApp") (EVar "f")) (EVar "args")) (EVar "undecidedCall")))
(DTypeSig false "undecidedCall" (TyCon "CallSite"))
(DFunDef false "undecidedCall" () (EApp (EApp (EVar "CallSite") (EVar "CallDynamic")) (EVar "False")))
(DData Public "CField" () ((variant "CField" (ConPos (TyCon "String") (TyCon "Int") (TyCon "CExpr")))) ())
(DData Public "CArm" () ((variant "CArm" (ConPos (TyCon "Pat") (TyApp (TyCon "List") (TyCon "CGuard")) (TyCon "CExpr")))) ())
(DData Public "CGuard" () ((variant "CGBool" (ConPos (TyCon "CExpr"))) (variant "CGBind" (ConPos (TyCon "Pat") (TyCon "CExpr")))) ())
(DData Public "CTree" () ((variant "CTFail" (ConPos (TyCon "FailSite"))) (variant "CTLeaf" (ConPos (TyCon "Int"))) (variant "CTGuard" (ConPos (TyCon "Int") (TyCon "CTree"))) (variant "CTSwitch" (ConPos (TyApp (TyCon "List") (TyCon "CTBranch")) (TyCon "CTree"))) (variant "CTDrop" (ConPos (TyCon "CTree")))) ())
(DData Public "FailSite" () ((variant "NoArm" (ConPos (TyCon "Loc"))) (variant "LetRefuted" (ConPos (TyCon "Loc")))) ())
(DData Public "CTBranch" () ((variant "CTBranch" (ConPos (TyCon "CHead") (TyCon "CTree")))) ())
(DData Public "CHead" () ((variant "HCon" (ConPos (TyCon "String") (TyCon "Int"))) (variant "HTuple" (ConPos (TyCon "Int"))) (variant "HCons" (ConPos)) (variant "HNil" (ConPos)) (variant "HUnit" (ConPos)) (variant "HLit" (ConPos (TyCon "Lit")))) ())
(DData Public "CStmt" () ((variant "CSExpr" (ConPos (TyCon "CExpr"))) (variant "CSLet" (ConPos (TyCon "Bool") (TyCon "Pat") (TyCon "CExpr"))) (variant "CSAssign" (ConPos (TyCon "String") (TyCon "CExpr")))) ())
(DData Public "CBind" () ((variant "CBind" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyCon "CClause")) (TyCon "Loc") (TyCon "BinderId")))) ())
(DTypeSig true "synthBind" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "CClause")) (TyCon "CBind"))))
(DFunDef false "synthBind" ((PVar "name") (PVar "clauses")) (EApp (EApp (EApp (EApp (EVar "CBind") (EVar "name")) (EVar "clauses")) (EVar "noDeclLoc")) (EVar "noBinderId")))
(DTypeSig true "siteSentinelName" (TyCon "String"))
(DFunDef false "siteSentinelName" () (ELit (LString "__site__")))
(DData Public "CClause" () ((variant "CClause" (ConPos (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "CExpr")))) ())
(DData Public "CImplEntry" () ((variant "CImplEntry" (ConPos (TyCon "String") (TyCon "Int") (TyCon "Int") (TyCon "CImplBody")))) ())
(DData Public "CImplBody" () ((variant "CImplTagged" (ConPos (TyCon "String") (TyCon "String") (TyCon "String") (TyCon "ImplSym") (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "CExpr"))) (variant "CImplDefault" (ConPos (TyCon "String") (TyCon "String") (TyCon "String") (TyCon "ImplSym") (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "CExpr")))) ())
(DData Public "ImplSym" () ((variant "ImplSym" (ConPos (TyCon "String") (TyCon "String") (TyCon "String")))) ())
(DTypeSig true "noImplSym" (TyCon "ImplSym"))
(DFunDef false "noImplSym" () (EApp (EApp (EApp (EVar "ImplSym") (ELit (LString ""))) (ELit (LString ""))) (ELit (LString ""))))
(DData Public "CProgram" () ((variant "CProgram" (ConPos (TyApp (TyCon "List") (TyCon "CBind")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyCon "DeclFacts")))) ())
(DData Public "MethodResultFact" () ((variant "MethodResultFact" (ConNamed (field "iface" (TyCon "String")) (field "method" (TyCon "String")) (field "returnsHead" (TyCon "Bool")) (field "callbackPositions" (TyApp (TyCon "List") (TyCon "Int"))) (field "valueArity" (TyCon "Int"))))) ())
(DImpl true "Eq" ((TyCon "MethodResultFact")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PRec "MethodResultFact" ((rf "iface" (PVar "__a0")) (rf "method" (PVar "__a1")) (rf "returnsHead" (PVar "__a2")) (rf "callbackPositions" (PVar "__a3")) (rf "valueArity" (PVar "__a4"))) false) (PRec "MethodResultFact" ((rf "iface" (PVar "__b0")) (rf "method" (PVar "__b1")) (rf "returnsHead" (PVar "__b2")) (rf "callbackPositions" (PVar "__b3")) (rf "valueArity" (PVar "__b4"))) false)) () (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EMethodRef "eq") (EVar "__a2")) (EVar "__b2"))) (EApp (EApp (EMethodRef "eq") (EVar "__a3")) (EVar "__b3"))) (EApp (EApp (EMethodRef "eq") (EVar "__a4")) (EVar "__b4"))))))))
(DImpl true "Debug" ((TyCon "MethodResultFact")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PRec "MethodResultFact" ((rf "iface" (PVar "__a0")) (rf "method" (PVar "__a1")) (rf "returnsHead" (PVar "__a2")) (rf "callbackPositions" (PVar "__a3")) (rf "valueArity" (PVar "__a4"))) false) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "MethodResultFact {")) (ELit (LString " iface = "))) (EApp (EMethodRef "debug") (EVar "__a0"))) (ELit (LString ", method = "))) (EApp (EMethodRef "debug") (EVar "__a1"))) (ELit (LString ", returnsHead = "))) (EApp (EMethodRef "debug") (EVar "__a2"))) (ELit (LString ", callbackPositions = "))) (EApp (EMethodRef "debug") (EVar "__a3"))) (ELit (LString ", valueArity = "))) (EApp (EMethodRef "debug") (EVar "__a4"))) (ELit (LString " }"))))))))
(DData Public "DeclFacts" () ((variant "DeclFacts" (ConNamed (field "factRequires" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int")))) (field "factSupers" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int")))) (field "factBinders" (TyApp (TyCon "List") (TyCon "BinderRow"))) (field "factMethodResults" (TyApp (TyCon "List") (TyCon "MethodResultFact"))) (field "factEntryOutcome" (TyApp (TyCon "Option") (TyCon "EntryOutcome")))))) ())
(DTypeSig true "noDeclFacts" (TyCon "DeclFacts"))
(DFunDef false "noDeclFacts" () (ERecordCreate "DeclFacts" ((fa "factRequires" (EListLit)) (fa "factSupers" (EListLit)) (fa "factBinders" (EListLit)) (fa "factMethodResults" (EListLit)) (fa "factEntryOutcome" (EVar "None")))))
(DTypeAlias true "BinderVisit" () (TyFun (TyCon "BinderSite") (TyFun (TyCon "String") (TyFun (TyCon "BinderId") (TyCon "BinderId")))))
(DData Public "BinderSite" () ((variant "PatternBinder" (ConPos (TyApp (TyCon "Option") (TyCon "CExpr")))) (variant "FunctionBinder" (ConPos (TyApp (TyCon "List") (TyCon "CClause"))))) ())
(DData Private "BinderPass" () ((variant "PatternPass" (ConPos)) (variant "FunctionPass" (ConPos))) ())
(DTypeSig true "obviousRuntimeType" (TyFun (TyCon "CExpr") (TyApp (TyCon "Option") (TyCon "RuntimeType"))))
(DFunDef false "obviousRuntimeType" ((PCon "CLit" (PCon "LInt" PWild))) (EVar "None"))
(DFunDef false "obviousRuntimeType" ((PCon "CLit" (PVar "l"))) (EApp (EVar "Some") (EApp (EVar "litRuntimeType") (EVar "l"))))
(DFunDef false "obviousRuntimeType" ((PCon "CTuple" PWild)) (EApp (EVar "Some") (EVar "RTCon")))
(DFunDef false "obviousRuntimeType" ((PCon "CList" PWild)) (EApp (EVar "Some") (EVar "RTCon")))
(DFunDef false "obviousRuntimeType" (PWild) (EVar "None"))
(DTypeSig true "litRuntimeType" (TyFun (TyCon "Lit") (TyCon "RuntimeType")))
(DFunDef false "litRuntimeType" ((PCon "LInt" PWild)) (EVar "RTInt"))
(DFunDef false "litRuntimeType" ((PCon "LFloat" PWild)) (EVar "RTFloat"))
(DFunDef false "litRuntimeType" ((PCon "LString" PWild)) (EVar "RTString"))
(DFunDef false "litRuntimeType" ((PCon "LChar" PWild)) (EVar "RTChar"))
(DFunDef false "litRuntimeType" ((PCon "LBool" PWild)) (EVar "RTBool"))
(DFunDef false "litRuntimeType" ((PCon "LUnit")) (EVar "RTUnit"))
(DFunDef false "litRuntimeType" ((PCon "LU64" PWild PWild)) (EVar "RTU64"))
(DFunDef false "litRuntimeType" ((PCon "LI64" PWild PWild)) (EVar "RTI64"))
(DTypeSig true "mapProgramBinders" (TyFun (TyCon "BinderVisit") (TyFun (TyCon "CProgram") (TyCon "CProgram"))))
(DFunDef false "mapProgramBinders" ((PVar "f") (PVar "prog")) (EApp (EApp (EApp (EVar "mapProgramPass") (EVar "FunctionPass")) (EVar "f")) (EApp (EApp (EApp (EVar "mapProgramPass") (EVar "PatternPass")) (EVar "f")) (EVar "prog"))))
(DTypeSig false "mapProgramPass" (TyFun (TyCon "BinderPass") (TyFun (TyCon "BinderVisit") (TyFun (TyCon "CProgram") (TyCon "CProgram")))))
(DFunDef false "mapProgramPass" ((PVar "pass") (PVar "f") (PCon "CProgram" (PVar "binds") (PVar "ctorArs") (PVar "ctorTypes") (PVar "impls") (PVar "mctx") (PVar "facts"))) (EBlock (DoLet false false (PVar "w") (EApp (EApp (EVar "BinderWalk") (EVar "pass")) (EVar "f"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "CProgram") (EApp (EApp (EMethodRef "map") (EApp (EVar "mapBindBinders") (EVar "w"))) (EVar "binds"))) (EVar "ctorArs")) (EVar "ctorTypes")) (EApp (EApp (EMethodRef "map") (EApp (EVar "mapEntryBinders") (EVar "w"))) (EVar "impls"))) (EVar "mctx")) (EVar "facts")))))
(DData Private "BinderWalk" () ((variant "BinderWalk" (ConPos (TyCon "BinderPass") (TyCon "BinderVisit")))) ())
(DTypeSig true "withBinderRows" (TyFun (TyApp (TyCon "List") (TyCon "BinderRow")) (TyFun (TyCon "CProgram") (TyCon "CProgram"))))
(DFunDef false "withBinderRows" ((PVar "rows") (PCon "CProgram" (PVar "groups") (PVar "ctorArs") (PVar "ctorTypes") (PVar "impls") (PVar "mctx") (PVar "facts"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "CProgram") (EVar "groups")) (EVar "ctorArs")) (EVar "ctorTypes")) (EVar "impls")) (EVar "mctx")) (ERecordCreate "DeclFacts" ((fa "factRequires" (EFieldAccess (EVar "facts") "factRequires")) (fa "factSupers" (EFieldAccess (EVar "facts") "factSupers")) (fa "factBinders" (EVar "rows")) (fa "factMethodResults" (EFieldAccess (EVar "facts") "factMethodResults")) (fa "factEntryOutcome" (EFieldAccess (EVar "facts") "factEntryOutcome"))))))
(DTypeSig true "programBinderIds" (TyFun (TyCon "CProgram") (TyApp (TyCon "List") (TyCon "BinderId"))))
(DFunDef false "programBinderIds" ((PVar "prog")) (EBlock (DoLet false false (PVar "seen") (EApp (EVar "Ref") (EListLit))) (DoLet false false PWild (EApp (EApp (EVar "mapProgramBinders") (ELam (PWild PWild (PVar "bid")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EVar "seen")) (EBinOp "::" (EVar "bid") (EUnOp "!" (EVar "seen"))))) (DoExpr (EVar "bid"))))) (EVar "prog"))) (DoExpr (EApp (EVar "reverseL") (EUnOp "!" (EVar "seen"))))))
(DTypeSig false "mapEntryBinders" (TyFun (TyCon "BinderWalk") (TyFun (TyCon "CImplEntry") (TyCon "CImplEntry"))))
(DFunDef false "mapEntryBinders" ((PVar "f") (PCon "CImplEntry" (PVar "m") (PVar "s") (PVar "d") (PCon "CImplTagged" (PVar "tag") (PVar "key") (PVar "iface") (PVar "sym") (PVar "pos") (PVar "pats") (PVar "body")))) (EBlock (DoLet false false (PVar "pats2") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "mapPatBinders") (EVar "f")) (EVar "None"))) (EVar "pats"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "CImplEntry") (EVar "m")) (EVar "s")) (EVar "d")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "CImplTagged") (EVar "tag")) (EVar "key")) (EVar "iface")) (EVar "sym")) (EVar "pos")) (EVar "pats2")) (EApp (EApp (EVar "mapExprBinders") (EVar "f")) (EVar "body")))))))
(DFunDef false "mapEntryBinders" ((PVar "f") (PCon "CImplEntry" (PVar "m") (PVar "s") (PVar "d") (PCon "CImplDefault" (PVar "w") (PVar "tag") (PVar "key") (PVar "sym") (PVar "pos") (PVar "pats") (PVar "body")))) (EBlock (DoLet false false (PVar "pats2") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "mapPatBinders") (EVar "f")) (EVar "None"))) (EVar "pats"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "CImplEntry") (EVar "m")) (EVar "s")) (EVar "d")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "CImplDefault") (EVar "w")) (EVar "tag")) (EVar "key")) (EVar "sym")) (EVar "pos")) (EVar "pats2")) (EApp (EApp (EVar "mapExprBinders") (EVar "f")) (EVar "body")))))))
(DTypeSig false "mapBindBinders" (TyFun (TyCon "BinderWalk") (TyFun (TyCon "CBind") (TyCon "CBind"))))
(DFunDef false "mapBindBinders" ((PVar "w") (PCon "CBind" (PVar "name") (PVar "clauses") (PVar "site") (PVar "bid"))) (EBlock (DoLet false false (PVar "clauses2") (EApp (EApp (EMethodRef "map") (EApp (EVar "mapClauseBinders") (EVar "w"))) (EVar "clauses"))) (DoLet false false (PVar "bid2") (EMatch (EVar "w") (arm (PCon "BinderWalk" (PCon "FunctionPass") (PVar "f")) () (EApp (EApp (EApp (EVar "f") (EApp (EVar "FunctionBinder") (EVar "clauses2"))) (EVar "name")) (EVar "bid"))) (arm (PCon "BinderWalk" (PCon "PatternPass") PWild) () (EVar "bid")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "CBind") (EVar "name")) (EVar "clauses2")) (EVar "site")) (EVar "bid2")))))
(DTypeSig false "mapClauseBinders" (TyFun (TyCon "BinderWalk") (TyFun (TyCon "CClause") (TyCon "CClause"))))
(DFunDef false "mapClauseBinders" ((PVar "f") (PCon "CClause" (PVar "pats") (PVar "body"))) (EBlock (DoLet false false (PVar "pats2") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "mapPatBinders") (EVar "f")) (EVar "None"))) (EVar "pats"))) (DoExpr (EApp (EApp (EVar "CClause") (EVar "pats2")) (EApp (EApp (EVar "mapExprBinders") (EVar "f")) (EVar "body"))))))
(DTypeSig false "mapPatBinders" (TyFun (TyCon "BinderWalk") (TyFun (TyApp (TyCon "Option") (TyCon "CExpr")) (TyFun (TyCon "Pat") (TyCon "Pat")))))
(DFunDef false "mapPatBinders" ((PCon "BinderWalk" (PCon "FunctionPass") PWild) PWild (PVar "p")) (EVar "p"))
(DFunDef false "mapPatBinders" ((PCon "BinderWalk" (PCon "PatternPass") (PVar "f")) (PVar "hint") (PCon "PVar" (PVar "x") (PVar "l") (PVar "bid"))) (EApp (EApp (EApp (EVar "PVar") (EVar "x")) (EVar "l")) (EApp (EApp (EApp (EVar "f") (EApp (EVar "PatternBinder") (EVar "hint"))) (EVar "x")) (EVar "bid"))))
(DFunDef false "mapPatBinders" (PWild PWild (PCon "PWild")) (EVar "PWild"))
(DFunDef false "mapPatBinders" (PWild PWild (PCon "PLit" (PVar "l"))) (EApp (EVar "PLit") (EVar "l")))
(DFunDef false "mapPatBinders" ((PVar "f") PWild (PCon "PCon" (PVar "c") (PVar "ps"))) (EApp (EApp (EVar "PCon") (EVar "c")) (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "mapPatBinders") (EVar "f")) (EVar "None"))) (EVar "ps"))))
(DFunDef false "mapPatBinders" ((PVar "f") PWild (PCon "PCons" (PVar "a") (PVar "b"))) (EBlock (DoLet false false (PVar "a2") (EApp (EApp (EApp (EVar "mapPatBinders") (EVar "f")) (EVar "None")) (EVar "a"))) (DoExpr (EApp (EApp (EVar "PCons") (EVar "a2")) (EApp (EApp (EApp (EVar "mapPatBinders") (EVar "f")) (EVar "None")) (EVar "b"))))))
(DFunDef false "mapPatBinders" ((PVar "f") PWild (PCon "PTuple" (PVar "ps"))) (EApp (EVar "PTuple") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "mapPatBinders") (EVar "f")) (EVar "None"))) (EVar "ps"))))
(DFunDef false "mapPatBinders" ((PVar "f") PWild (PCon "PList" (PVar "ps"))) (EApp (EVar "PList") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "mapPatBinders") (EVar "f")) (EVar "None"))) (EVar "ps"))))
(DFunDef false "mapPatBinders" ((PAs "w" (PCon "BinderWalk" PWild (PVar "f"))) PWild (PCon "PAs" (PVar "x") (PVar "l") (PVar "bid") (PVar "p"))) (EBlock (DoLet false false (PVar "bid2") (EApp (EApp (EApp (EVar "f") (EApp (EVar "PatternBinder") (EVar "None"))) (EVar "x")) (EVar "bid"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "PAs") (EVar "x")) (EVar "l")) (EVar "bid2")) (EApp (EApp (EApp (EVar "mapPatBinders") (EVar "w")) (EVar "None")) (EVar "p"))))))
(DFunDef false "mapPatBinders" (PWild PWild (PCon "PRng" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EVar "PRng") (EVar "lo")) (EVar "hi")) (EVar "incl")))
(DFunDef false "mapPatBinders" ((PVar "f") PWild (PCon "PRec" (PVar "name") (PVar "fields") (PVar "rest"))) (EApp (EApp (EApp (EVar "PRec") (EVar "name")) (EApp (EApp (EMethodRef "map") (EApp (EVar "mapRecFieldBinders") (EVar "f"))) (EVar "fields"))) (EVar "rest")))
(DTypeSig false "mapRecFieldBinders" (TyFun (TyCon "BinderWalk") (TyFun (TyCon "RecPatField") (TyCon "RecPatField"))))
(DFunDef false "mapRecFieldBinders" ((PCon "BinderWalk" PWild (PVar "f")) (PCon "RecPatField" (PVar "n") (PVar "l") (PVar "bid") (PCon "None"))) (EApp (EApp (EApp (EApp (EVar "RecPatField") (EVar "n")) (EVar "l")) (EApp (EApp (EApp (EVar "f") (EApp (EVar "PatternBinder") (EVar "None"))) (EVar "n")) (EVar "bid"))) (EVar "None")))
(DFunDef false "mapRecFieldBinders" ((PVar "f") (PCon "RecPatField" (PVar "n") (PVar "l") (PVar "bid") (PCon "Some" (PVar "p")))) (EApp (EApp (EApp (EApp (EVar "RecPatField") (EVar "n")) (EVar "l")) (EVar "bid")) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "mapPatBinders") (EVar "f")) (EVar "None")) (EVar "p")))))
(DTypeSig false "mapExprBinders" (TyFun (TyCon "BinderWalk") (TyFun (TyCon "CExpr") (TyCon "CExpr"))))
(DFunDef false "mapExprBinders" (PWild (PCon "CLit" (PVar "l"))) (EApp (EVar "CLit") (EVar "l")))
(DFunDef false "mapExprBinders" (PWild (PCon "CVar" (PVar "x") (PVar "addr"))) (EApp (EApp (EVar "CVar") (EVar "x")) (EVar "addr")))
(DFunDef false "mapExprBinders" ((PVar "f") (PCon "CApp" (PVar "h") (PVar "args") (PVar "site"))) (EBlock (DoLet false false (PVar "h2") (EApp (EApp (EVar "mapExprBinders") (EVar "f")) (EVar "h"))) (DoExpr (EApp (EApp (EApp (EVar "CApp") (EVar "h2")) (EApp (EApp (EMethodRef "map") (EApp (EVar "mapExprBinders") (EVar "f"))) (EVar "args"))) (EVar "site")))))
(DFunDef false "mapExprBinders" ((PVar "f") (PCon "CLam" (PVar "pats") (PVar "body"))) (EBlock (DoLet false false (PVar "pats2") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "mapPatBinders") (EVar "f")) (EVar "None"))) (EVar "pats"))) (DoExpr (EApp (EApp (EVar "CLam") (EVar "pats2")) (EApp (EApp (EVar "mapExprBinders") (EVar "f")) (EVar "body"))))))
(DFunDef false "mapExprBinders" ((PVar "f") (PCon "CLet" (PVar "recF") (PVar "pat") (PVar "rhs") (PVar "body"))) (EBlock (DoLet false false (PVar "pat2") (EApp (EApp (EApp (EVar "mapPatBinders") (EVar "f")) (EApp (EVar "Some") (EVar "rhs"))) (EVar "pat"))) (DoLet false false (PVar "rhs2") (EApp (EApp (EVar "mapExprBinders") (EVar "f")) (EVar "rhs"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "CLet") (EVar "recF")) (EVar "pat2")) (EVar "rhs2")) (EApp (EApp (EVar "mapExprBinders") (EVar "f")) (EVar "body"))))))
(DFunDef false "mapExprBinders" ((PVar "f") (PCon "CLetGroup" (PVar "binds") (PVar "body"))) (EBlock (DoLet false false (PVar "binds2") (EApp (EApp (EMethodRef "map") (EApp (EVar "mapBindBinders") (EVar "f"))) (EVar "binds"))) (DoExpr (EApp (EApp (EVar "CLetGroup") (EVar "binds2")) (EApp (EApp (EVar "mapExprBinders") (EVar "f")) (EVar "body"))))))
(DFunDef false "mapExprBinders" ((PVar "f") (PCon "CMatch" (PVar "scrut") (PVar "arms"))) (EBlock (DoLet false false (PVar "scrut2") (EApp (EApp (EVar "mapExprBinders") (EVar "f")) (EVar "scrut"))) (DoExpr (EApp (EApp (EVar "CMatch") (EVar "scrut2")) (EApp (EApp (EMethodRef "map") (EApp (EVar "mapArmBinders") (EVar "f"))) (EVar "arms"))))))
(DFunDef false "mapExprBinders" ((PVar "f") (PCon "CDecision" (PVar "scrut") (PVar "arms") (PVar "tree"))) (EBlock (DoLet false false (PVar "scrut2") (EApp (EApp (EVar "mapExprBinders") (EVar "f")) (EVar "scrut"))) (DoExpr (EApp (EApp (EApp (EVar "CDecision") (EVar "scrut2")) (EApp (EApp (EMethodRef "map") (EApp (EVar "mapArmBinders") (EVar "f"))) (EVar "arms"))) (EVar "tree")))))
(DFunDef false "mapExprBinders" ((PVar "f") (PCon "CIf" (PVar "c") (PVar "t") (PVar "e"))) (EBlock (DoLet false false (PVar "c2") (EApp (EApp (EVar "mapExprBinders") (EVar "f")) (EVar "c"))) (DoLet false false (PVar "t2") (EApp (EApp (EVar "mapExprBinders") (EVar "f")) (EVar "t"))) (DoExpr (EApp (EApp (EApp (EVar "CIf") (EVar "c2")) (EVar "t2")) (EApp (EApp (EVar "mapExprBinders") (EVar "f")) (EVar "e"))))))
(DFunDef false "mapExprBinders" ((PVar "f") (PCon "CBinPrim" (PVar "op") (PVar "l") (PVar "r") (PVar "tag") (PVar "site"))) (EBlock (DoLet false false (PVar "l2") (EApp (EApp (EVar "mapExprBinders") (EVar "f")) (EVar "l"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "CBinPrim") (EVar "op")) (EVar "l2")) (EApp (EApp (EVar "mapExprBinders") (EVar "f")) (EVar "r"))) (EVar "tag")) (EVar "site")))))
(DFunDef false "mapExprBinders" ((PVar "f") (PCon "CUnOp" (PVar "op") (PVar "x"))) (EApp (EApp (EVar "CUnOp") (EVar "op")) (EApp (EApp (EVar "mapExprBinders") (EVar "f")) (EVar "x"))))
(DFunDef false "mapExprBinders" ((PVar "f") (PCon "CTuple" (PVar "es"))) (EApp (EVar "CTuple") (EApp (EApp (EMethodRef "map") (EApp (EVar "mapExprBinders") (EVar "f"))) (EVar "es"))))
(DFunDef false "mapExprBinders" ((PVar "f") (PCon "CList" (PVar "es"))) (EApp (EVar "CList") (EApp (EApp (EMethodRef "map") (EApp (EVar "mapExprBinders") (EVar "f"))) (EVar "es"))))
(DFunDef false "mapExprBinders" ((PVar "f") (PCon "CRecord" (PVar "name") (PVar "fields"))) (EApp (EApp (EVar "CRecord") (EVar "name")) (EApp (EApp (EMethodRef "map") (EApp (EVar "mapFieldBinders") (EVar "f"))) (EVar "fields"))))
(DFunDef false "mapExprBinders" ((PVar "f") (PCon "CFieldAccess" (PVar "x") (PVar "label") (PVar "name") (PVar "ord"))) (EApp (EApp (EApp (EApp (EVar "CFieldAccess") (EApp (EApp (EVar "mapExprBinders") (EVar "f")) (EVar "x"))) (EVar "label")) (EVar "name")) (EVar "ord")))
(DFunDef false "mapExprBinders" ((PVar "f") (PCon "CRecordUpdate" (PVar "name") (PVar "base") (PVar "fields"))) (EBlock (DoLet false false (PVar "base2") (EApp (EApp (EVar "mapExprBinders") (EVar "f")) (EVar "base"))) (DoExpr (EApp (EApp (EApp (EVar "CRecordUpdate") (EVar "name")) (EVar "base2")) (EApp (EApp (EMethodRef "map") (EApp (EVar "mapFieldBinders") (EVar "f"))) (EVar "fields"))))))
(DFunDef false "mapExprBinders" ((PVar "f") (PCon "CVariantUpdate" (PVar "con") (PVar "base") (PVar "fields"))) (EBlock (DoLet false false (PVar "base2") (EApp (EApp (EVar "mapExprBinders") (EVar "f")) (EVar "base"))) (DoExpr (EApp (EApp (EApp (EVar "CVariantUpdate") (EVar "con")) (EVar "base2")) (EApp (EApp (EMethodRef "map") (EApp (EVar "mapFieldBinders") (EVar "f"))) (EVar "fields"))))))
(DFunDef false "mapExprBinders" ((PVar "f") (PCon "CArray" (PVar "es"))) (EApp (EVar "CArray") (EApp (EApp (EMethodRef "map") (EApp (EVar "mapExprBinders") (EVar "f"))) (EVar "es"))))
(DFunDef false "mapExprBinders" ((PVar "f") (PCon "CRangeList" (PVar "lo") (PVar "hi") (PVar "incl"))) (EBlock (DoLet false false (PVar "lo2") (EApp (EApp (EVar "mapExprBinders") (EVar "f")) (EVar "lo"))) (DoExpr (EApp (EApp (EApp (EVar "CRangeList") (EVar "lo2")) (EApp (EApp (EVar "mapExprBinders") (EVar "f")) (EVar "hi"))) (EVar "incl")))))
(DFunDef false "mapExprBinders" ((PVar "f") (PCon "CRangeArray" (PVar "lo") (PVar "hi") (PVar "incl"))) (EBlock (DoLet false false (PVar "lo2") (EApp (EApp (EVar "mapExprBinders") (EVar "f")) (EVar "lo"))) (DoExpr (EApp (EApp (EApp (EVar "CRangeArray") (EVar "lo2")) (EApp (EApp (EVar "mapExprBinders") (EVar "f")) (EVar "hi"))) (EVar "incl")))))
(DFunDef false "mapExprBinders" ((PVar "f") (PCon "CIndex" (PVar "a") (PVar "i"))) (EBlock (DoLet false false (PVar "a2") (EApp (EApp (EVar "mapExprBinders") (EVar "f")) (EVar "a"))) (DoExpr (EApp (EApp (EVar "CIndex") (EVar "a2")) (EApp (EApp (EVar "mapExprBinders") (EVar "f")) (EVar "i"))))))
(DFunDef false "mapExprBinders" ((PVar "f") (PCon "CSlice" (PVar "a") (PVar "lo") (PVar "hi") (PVar "incl"))) (EBlock (DoLet false false (PVar "a2") (EApp (EApp (EVar "mapExprBinders") (EVar "f")) (EVar "a"))) (DoLet false false (PVar "lo2") (EApp (EApp (EVar "mapExprBinders") (EVar "f")) (EVar "lo"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "CSlice") (EVar "a2")) (EVar "lo2")) (EApp (EApp (EVar "mapExprBinders") (EVar "f")) (EVar "hi"))) (EVar "incl")))))
(DFunDef false "mapExprBinders" ((PVar "f") (PCon "CStringIndex" (PVar "a") (PVar "i"))) (EBlock (DoLet false false (PVar "a2") (EApp (EApp (EVar "mapExprBinders") (EVar "f")) (EVar "a"))) (DoExpr (EApp (EApp (EVar "CStringIndex") (EVar "a2")) (EApp (EApp (EVar "mapExprBinders") (EVar "f")) (EVar "i"))))))
(DFunDef false "mapExprBinders" ((PVar "f") (PCon "CStringSlice" (PVar "a") (PVar "lo") (PVar "hi") (PVar "incl"))) (EBlock (DoLet false false (PVar "a2") (EApp (EApp (EVar "mapExprBinders") (EVar "f")) (EVar "a"))) (DoLet false false (PVar "lo2") (EApp (EApp (EVar "mapExprBinders") (EVar "f")) (EVar "lo"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "CStringSlice") (EVar "a2")) (EVar "lo2")) (EApp (EApp (EVar "mapExprBinders") (EVar "f")) (EVar "hi"))) (EVar "incl")))))
(DFunDef false "mapExprBinders" ((PVar "f") (PCon "CListIndex" (PVar "a") (PVar "i"))) (EBlock (DoLet false false (PVar "a2") (EApp (EApp (EVar "mapExprBinders") (EVar "f")) (EVar "a"))) (DoExpr (EApp (EApp (EVar "CListIndex") (EVar "a2")) (EApp (EApp (EVar "mapExprBinders") (EVar "f")) (EVar "i"))))))
(DFunDef false "mapExprBinders" ((PVar "f") (PCon "CListSlice" (PVar "a") (PVar "lo") (PVar "hi") (PVar "incl"))) (EBlock (DoLet false false (PVar "a2") (EApp (EApp (EVar "mapExprBinders") (EVar "f")) (EVar "a"))) (DoLet false false (PVar "lo2") (EApp (EApp (EVar "mapExprBinders") (EVar "f")) (EVar "lo"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "CListSlice") (EVar "a2")) (EVar "lo2")) (EApp (EApp (EVar "mapExprBinders") (EVar "f")) (EVar "hi"))) (EVar "incl")))))
(DFunDef false "mapExprBinders" ((PVar "f") (PCon "CBlock" (PVar "stmts"))) (EApp (EVar "CBlock") (EApp (EApp (EMethodRef "map") (EApp (EVar "mapStmtBinders") (EVar "f"))) (EVar "stmts"))))
(DFunDef false "mapExprBinders" (PWild (PCon "CMethod" (PVar "name") (PVar "ev"))) (EApp (EApp (EVar "CMethod") (EVar "name")) (EVar "ev")))
(DFunDef false "mapExprBinders" (PWild (PCon "CDict" (PVar "name") (PVar "rs"))) (EApp (EApp (EVar "CDict") (EVar "name")) (EVar "rs")))
(DTypeSig false "mapFieldBinders" (TyFun (TyCon "BinderWalk") (TyFun (TyCon "CField") (TyCon "CField"))))
(DFunDef false "mapFieldBinders" ((PVar "f") (PCon "CField" (PVar "k") (PVar "o") (PVar "e"))) (EApp (EApp (EApp (EVar "CField") (EVar "k")) (EVar "o")) (EApp (EApp (EVar "mapExprBinders") (EVar "f")) (EVar "e"))))
(DTypeSig false "mapArmBinders" (TyFun (TyCon "BinderWalk") (TyFun (TyCon "CArm") (TyCon "CArm"))))
(DFunDef false "mapArmBinders" ((PVar "f") (PCon "CArm" (PVar "pat") (PVar "guards") (PVar "body"))) (EBlock (DoLet false false (PVar "pat2") (EApp (EApp (EApp (EVar "mapPatBinders") (EVar "f")) (EVar "None")) (EVar "pat"))) (DoLet false false (PVar "guards2") (EApp (EApp (EMethodRef "map") (EApp (EVar "mapGuardBinders") (EVar "f"))) (EVar "guards"))) (DoExpr (EApp (EApp (EApp (EVar "CArm") (EVar "pat2")) (EVar "guards2")) (EApp (EApp (EVar "mapExprBinders") (EVar "f")) (EVar "body"))))))
(DTypeSig false "mapGuardBinders" (TyFun (TyCon "BinderWalk") (TyFun (TyCon "CGuard") (TyCon "CGuard"))))
(DFunDef false "mapGuardBinders" ((PVar "f") (PCon "CGBool" (PVar "c"))) (EApp (EVar "CGBool") (EApp (EApp (EVar "mapExprBinders") (EVar "f")) (EVar "c"))))
(DFunDef false "mapGuardBinders" ((PVar "f") (PCon "CGBind" (PVar "pat") (PVar "e"))) (EBlock (DoLet false false (PVar "pat2") (EApp (EApp (EApp (EVar "mapPatBinders") (EVar "f")) (EVar "None")) (EVar "pat"))) (DoExpr (EApp (EApp (EVar "CGBind") (EVar "pat2")) (EApp (EApp (EVar "mapExprBinders") (EVar "f")) (EVar "e"))))))
(DTypeSig false "mapStmtBinders" (TyFun (TyCon "BinderWalk") (TyFun (TyCon "CStmt") (TyCon "CStmt"))))
(DFunDef false "mapStmtBinders" ((PVar "f") (PCon "CSExpr" (PVar "e"))) (EApp (EVar "CSExpr") (EApp (EApp (EVar "mapExprBinders") (EVar "f")) (EVar "e"))))
(DFunDef false "mapStmtBinders" ((PVar "f") (PCon "CSLet" (PVar "recF") (PVar "pat") (PVar "e"))) (EBlock (DoLet false false (PVar "pat2") (EApp (EApp (EApp (EVar "mapPatBinders") (EVar "f")) (EApp (EVar "Some") (EVar "e"))) (EVar "pat"))) (DoExpr (EApp (EApp (EApp (EVar "CSLet") (EVar "recF")) (EVar "pat2")) (EApp (EApp (EVar "mapExprBinders") (EVar "f")) (EVar "e"))))))
(DFunDef false "mapStmtBinders" ((PVar "f") (PCon "CSAssign" (PVar "x") (PVar "e"))) (EApp (EApp (EVar "CSAssign") (EVar "x")) (EApp (EApp (EVar "mapExprBinders") (EVar "f")) (EVar "e"))))
