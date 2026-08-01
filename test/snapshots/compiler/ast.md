# META
source_lines=568
stages=DESUGAR,MARK
# SOURCE
-- Self-hosted Medaka AST — mirror of lib/ast.ml's surface (pre-desugar) nodes,
-- the target the self-host parser builds.  Post-parse-only nodes (EMethodRef,
-- EDictApp, EHeadAnnot) are intentionally omitted — the parser never produces
-- them.  Constructor names match lib/ast.ml so the structural dump
-- (compiler/sexp.mdk ↔ dev/astdump.ml) stays in lockstep.
--
-- Coverage grows with the parser port.  This is the core node set; more expr,
-- pat, ty, and decl variants are added per slice.

public export data Lit =
  | LInt Int
  | LFloat Float
  | LString String
  | LChar String
  | LBool Bool
  | LUnit
deriving (Eq)

-- A source-location span for an expression (mirror of lib/ast.ml's `loc`):
-- file, 1-based start line, 0-based start col, 1-based end line, 0-based end col.
-- Carried by the transparent `ELoc` wrapper the parser puts on atom/leaf and
-- statement-form expressions.  The `file` is filled by the caller (B.10.2b) —
-- the parser leaves it "".  Transparent to all semantics: every stage either
-- recurses through `ELoc` or strips it (sexp/Core-IR lowering), so emitted IR
-- and structural dumps are byte-identical to the un-wrapped tree.
public export data Loc = Loc String Int Int Int Int

-- ── Type-constructor identity (#1110, A-1 carrier) ────────────────────────
-- WHERE a type-constructor head was declared.  `DICT-SEMANTICS.md` §8 I4 says
-- a declaration's identity is `(originModule, name)` and that a bare `String`
-- name is not a key; this is the `originModule` half, carried on the AST node
-- so resolve can stamp it ONCE instead of every downstream table re-deriving
-- it from a spelling (#1069, #1070, #1090, #1092, #1208, #1209).
--
-- THREE inhabitants, and the split is forced by spec, not taste:
--
--   * `OriginUnresolved` — the identity has not been ACQUIRED YET.  This is a
--     PIPELINE-STAGE marker, not an identity and not a wildcard: it is what a
--     parser-built node carries before resolve runs.  §8 I6.3 forbids an
--     `Option`-shaped origin precisely because `None` would have to mean
--     "absent" at every cross-module predicate, decided per call site; this
--     constructor instead means "not stamped yet", and NO predicate may
--     compare two of them equal or treat one as matching anything.  Draining
--     it — so that after resolve every head carries `OriginModule` or
--     `OriginBuiltin` — is the job of the LATER A-1 PRs.  It is deliberately
--     greppable, as is its sole producer `tyConUnresolved` below.
--   * `OriginBuiltin` — the reserved origin of a head the LANGUAGE provides
--     rather than a module: the tuple constructors (`TyCon "__tupleN__"`) and
--     any other builtin.  §8 I6.2 (a): `(Int, Int)` written in two modules is
--     ONE type, so a builtin head's origin is NOT the module it is written
--     in.  A mechanical "stamp every head with the module under elaboration"
--     breaks that conjunct silently, which is why the case is named here at
--     design time rather than discovered at the first tuple-instance failure.
--   * `OriginModule mid` — declared by that module.  §8 I6.3: the module id
--     is NON-EMPTY; `""` is not an identity and must never become one.
--
-- ⚠️ A rigid type VARIABLE deliberately has no inhabitant here.  §8's I6.1 ∧
-- I6.3 corollary says a fabricated head must not be carried by the
-- type-CONSTRUCTOR node at all — "carries no identity" has to be a structural
-- fact about the node.  The surface AST already satisfies that: `TyVar` is a
-- separate constructor.  The violation the corollary names is at the `Mono`
-- level (`TCon String`, `types/typecheck.mdk`), which this PR does not touch.
--
-- ⚠️ NOT an encoded/qualified string, and never renderable.  The printer
-- projects a type through `tyConSurface` straight back into the user's source
-- (`tools/printer.mdk`), and an alias-qualified name in TYPE position is a
-- parse error — so a qualified spelling stored here would make `medaka fmt` a
-- source-destroying operation.  Same class as the `__tupleN__` round-trip
-- `tyConSurface`'s own comment records.  Every renderer therefore STRIPS this
-- field exactly the way `ELoc` is stripped.
public export data TyConOrigin =
  | OriginUnresolved
  | OriginBuiltin
  | OriginModule String

public export data Ty =
  -- `origin` is the #1110 identity carrier described above; it is stripped by
  -- every renderer, so structural dumps and printed source are byte-identical
  -- to the pre-#1110 tree.
  --
  -- 🚨 Match it as a PARTIAL record pattern naming only the fields you want —
  -- `TyCon { name = n }`, or `TyCon {}` to bind nothing.  A partial pattern
  -- already tolerates fields added later (`desugarPat`/`lookupRecField`,
  -- `frontend/exhaust.mdk`, fill every unmentioned field with `PWild`), so the
  -- `...` rest marker buys NOTHING here and costs the exhaustiveness check:
  -- `desugarPat _ (PRec _ _ True) = PWild` collapses a `...` pattern to a
  -- CATCH-ALL, which would silently make every `Ty` match in the compiler
  -- trivially "exhaustive" and turn a future missing-constructor error into a
  -- runtime match failure.  Measured both ways on this change.
  | TyCon { name : String, loc : Option Loc, origin : TyConOrigin }
  | TyVar String
  | TyApp Ty Ty
  | TyFun Ty Ty
  | TyTuple (List Ty)
  | TyEffect (List (String, Option String)) (Option String) Ty
  | TyConstrained (List Constraint) Ty
  -- A row/grade written BARE in a type-ARGUMENT slot (#997), e.g. the
  -- `<Stdout>` of `Async <Stdout> Unit`.  Distinct from `TyEffect` — which
  -- always WRAPS an inner type (`<Stdout> Unit` meaning "Unit, performing
  -- Stdout") — because a bare row-argument atom wraps nothing: there is no
  -- inner type to distinguish "no wrapped type" from "wrapped type happens
  -- to be Unit", so a real constructor is required rather than a filler Ty
  -- (a filler is print-ambiguous with a genuine wrapped type of the same
  -- shape, e.g. `Foo (<Stdout> Unit)` where `Unit` is a real payload type).
  | TyRow (List (String, Option String)) (Option String) (Option Loc)

-- Build a `TyCon` whose module identity has NOT been acquired yet (#1110).
-- This is the ONE producer of `OriginUnresolved`, and every construction site
-- in the tree currently goes through it — so `grep -rw tyConUnresolved` is the
-- exact worklist a later A-1 PR has to drain when resolve starts stamping
-- identity.  Kept as a helper rather than inlining the record literal so that
-- adding an identity field does not re-churn the construction sites the way a
-- partial record pattern already spares the match sites.
export tyConUnresolved : String -> Option Loc -> Ty
tyConUnresolved n l = TyCon { name = n, loc = l, origin = OriginUnresolved }

-- an interface constraint `Iface arg…` on the LHS of a `=>` in a type
public export data Constraint = Constraint String (List Ty)

-- ── Loc plumbing (issue 480) ──────────────────────────────────────────────
-- These live HERE, beside `Loc`/`Ty`, because they are diagnostic-quality
-- infrastructure every stage needs: `resolve` locates a duplicate signature,
-- `typecheck` locates an effect/kind/coherence error, all from the same
-- judgment.  They used to be THREE module-private forks of the `Ty` walk
-- (`firstTyLoc` in resolve, `firstTyConLoc` and `tyFirstLoc` in typecheck) and
-- TWO of the combinator (`orElseLoc`/`orElseLocL`), which is exactly how the
-- next one gets written slightly differently.  `rule-duplicate-body` cannot
-- see that class: its floor is 10 nodes and these bodies are smaller.
--
-- ⚠️ The `Expr` walkers are deliberately NOT here.  There are five of them
-- (`exprLoc` in types/typecheck.mdk AND a differently-behaved `exprLoc` in
-- frontend/desugar.mdk, `firstExprLoc` in frontend/resolve.mdk,
-- `clauseBodyLoc` in frontend/exhaust.mdk, `implBodyLoc` in
-- types/typecheck.mdk) and they are five DIFFERENT judgments — shallow vs
-- app-head-descending vs deep pre-order vs guard-arm-descending vs
-- let-chain-only.  Unifying them would move diagnostic locations tree-wide.

-- the first `Some` loc, else the second (so a captured record-site span wins,
-- and a `None` capture still degrades to the live fallback).
export orElseLoc : Option Loc -> Option Loc -> Option Loc
orElseLoc (Some l) _ = Some l
orElseLoc None fallback = fallback

-- First `Loc` in a PRE-ORDER walk of a `Ty`, keep-first, `None` if the type
-- carries none.  Only `TyCon` and `TyRow` carry a span of their own; `TyVar`
-- has none (that residual gap is why a fully-parametric `impl Foo a` head
-- still falls back to the file-start caret), so a type built only from type
-- variables yields `None`.  A `DTypeSig` has no `Loc` of its own — only its
-- `Ty` payload does — so this is how a signature-level diagnostic is located.
export firstTyLoc : Ty -> Option Loc
firstTyLoc (TyCon { loc }) = loc
firstTyLoc (TyVar _) = None
firstTyLoc (TyApp f x) = orElseLoc (firstTyLoc f) (firstTyLoc x)
firstTyLoc (TyFun f x) = orElseLoc (firstTyLoc f) (firstTyLoc x)
firstTyLoc (TyTuple ts) = firstTyLocList ts
firstTyLoc (TyEffect _ _ t) = firstTyLoc t
firstTyLoc (TyConstrained _ t) = firstTyLoc t
firstTyLoc (TyRow _ _ l) = l

-- The same walk across a LIST of types, left to right — an impl head's args
-- (`impl Iface Ty1 Ty2…`), a tuple's elements, a method's signature parts.
export firstTyLocList : List Ty -> Option Loc
firstTyLocList [] = None
firstTyLocList (t::rest) = orElseLoc (firstTyLoc t) (firstTyLocList rest)

-- a resolved typeclass-dispatch route (filled by the typed-pipeline typechecker).
-- RNone = unresolved / no dispatch (eval keeps the VMulti for arg-tag fallback);
-- RKey = a concrete impl head tag (or, for two same-head impls, the canonical impl
--   key — TYPECHECK-AUDIT C7) plus its own requires routes recursively (Phase
--   83/84 #5: the nested element-dict routes so dict_of_route builds a structured
--   VDict carrying every element dict the impl body needs);
-- RDict = read the named dict parameter at runtime (enclosing constraint);
-- RDictFwd = like RDict but for return-position sites: also forward the structured
--   dict's own requires into the selected impl body (Phase 83/84 #5).
-- RLocal = NOT a method dispatch (Phase 112 / TYPECHECK-AUDIT C5): at this call
--   site the interface has no impl for the concrete receiver, but an explicitly-
--   imported/local standalone function shadows the method name, so eval ignores
--   VMulti dispatch and evaluates the bound name as the plain standalone (no
--   narrowing).  Mirrors lib/ast.ml's RLocal.  The carried String is the
--   MANGLED standalone symbol to call ("" = call the EMethodAt's own (bare) name).
--   On the EMIT path (P0-18) a definer-shadow occurrence is marked `EMethodAt` with
--   the BARE dispatch name (so `implFor` finds the impl when the receiver DOES have
--   one), but its RLocal fallback must reach the module-qualified standalone symbol
--   `<mid>__name` that `mangleUnits` renamed the def to — that symbol rides here.
--   On the un-mangled run/check path the symbol is "" and eval/emit uses the bare
--   name.
--   ⚠️ S-1 / SHADOW-SEMANTICS clause S9: RLocal DOES carry dicts.  The `List Route`
--   is the standalone's OWN `=>`-constraint dicts, slot-ordered, exactly as
--   `RKey`'s `List Route` carries a parametric impl's element dicts.  It is
--   NON-EMPTY iff the shadowing standalone is itself constrained (`size : Num a =>
--   a -> a` shadowing `Sizeable.size`): dict_pass gives such a definition leading
--   dict PARAMETERS, so the call site must supply the matching dict WORDS or it
--   silently UNDER-APPLIES (`check` green, `run` type-confused, `build` prints a raw
--   PAP pointer — the S-1 miscompile).  The shadowed interface decides WHICH
--   function (the route's RLocal-vs-RKey choice); the standalone's own constraints
--   decide WHICH DICTS (this list).  They are different interfaces.
--   EMPTY (`RLocal sym []`) for an UNCONSTRAINED standalone — the overwhelmingly
--   common case, incl. all 5 of the compiler's own definer shadows — and every
--   consumer keeps its pre-S1 byte-identical fast path on the empty list.
-- RScalar = NOT a typeclass dispatch route.  Stamped by typecheck's
-- resolveBinopSites onto an ARITHMETIC EBinOp whose operand grounds to a concrete
-- primitive ("Float"/"Int"), so lowering can carry the scalar type into CBinPrim's
-- tag field and the native emitter picks the Float primitive without re-deriving
-- the operand LTy structurally (SHARED-FLOAT-RESIDUAL-DESIGN §3(C), the type-lost
-- monomorphic-Float residual).  Absent → RNone → today's structural/dict path.
public export data Route =
  | RNone
  | RKey String (List Route)
  | RDict String
  | RDictFwd String
  | RLocal String (List Route)
  | RScalar String

-- a resolved lexical address for a variable reference (STAGE2-DESIGN §2.0, the
-- de-risked first half: resolve EMITS the slot; eval does NOT yet consume it —
-- the tree-walker keeps its by-name frame scan).  ALocal frame slot mirrors the
-- runtime env shape `EvalEnv (List (List (String, Ref Value)))` exactly: `frame`
-- is how many frames down the stack the binder sits (0 = innermost), `slot` is
-- its index within that frame (the order matchPat binds names).  AGlobal = not
-- lexically bound (top-level / prelude / extern) — eval resolves it by name, so
-- the slot would not help; the address still records that resolve looked.
public export data Addr = ALocal Int Int | AGlobal

public export data Pat =
  | PVar String Loc
  | PWild
  | PLit Lit
  | PCon String (List Pat)
  | PCons Pat Pat
  | PTuple (List Pat)
  | PList (List Pat)
  | PAs String Loc Pat
  | PRng Lit Lit Bool
  | PRec String (List RecPatField) Bool

-- one field of a record pattern: `field` (pun, None) or `field = pat`
-- The Loc is the field-name token (#913 Inc 2b: a punned field `{x}` binds
-- `x`, and rename must land on the field token, not the enclosing match Loc).
public export data RecPatField = RecPatField String Loc (Option Pat)

public export data Guard = GBool Expr | GBind Pat Expr

-- match arm: pattern, guard qualifiers, body
public export data Arm = Arm Pat (List Guard) Expr

-- statements in a bare block (EBlock) or monadic do-block (EDo)
public export data DoStmt =
  | DoExpr Expr
  | DoBind Pat Expr
  -- DoLet <mut> <rec> pat rhs. NOTE: the `mut` Bool is ALWAYS False — `let mut`
  -- is rejected at the parser (`letKind TMut = failP letMutRemovedMsg`, beta
  -- immutability model), so no `mut`-flag logic remains anywhere downstream.
  -- The field is retained (vs. dropped) only to avoid an ~87-site arity churn
  -- across every pass + the s-expr round-trip.
  | DoLet Bool Bool Pat Expr
  | DoAssign String Expr
  | DoFieldAssign String (List String) Expr

-- parts of an interpolated string `"…\{expr}…"`
public export data InterpPart = InterpStr String | InterpExpr Expr

-- a function/where guard arm: `| guards = body`
public export data GuardArm = GuardArm (List Guard) Expr

-- a record field assignment: `field = expr`
public export data FieldAssign = FieldAssign String Expr

-- an operator section: `(op)` / `(op e)` / `(e op _)`
public export data Section =
  | SecBare String
  | SecRight String Expr
  | SecLeft Expr String

-- one clause of a `where`/let-group binding: parameter patterns + body
public export data FunClause = FunClause (List Pat) Expr

-- a `where`/let-group binding: a name with one or more (coalesced) clauses
public export data LetBind = LetBind String (List FunClause)

public export data Expr =
  | ELit Lit
  | EVar String
  | EApp Expr Expr
  | ELam (List Pat) Expr
  -- ELet <mut> <rec> pat rhs body. The `mut` Bool is ALWAYS False (see DoLet
  -- above): `let mut` is a parser error, so no mut-flag logic exists downstream.
  | ELet Bool Bool Pat Expr Expr
  | EMatch Expr (List Arm)
  | EIf Expr Expr Expr
  -- Phase 151 / Gap G: the trailing route ref is filled by the typed pipeline
  -- (resolveBinopSites) for comparison/equality operators (== != < > <= >=) whose
  -- operand grounds to a NON-primitive Eq/Ord type; dictPass then rewrites such a
  -- stamped node into the method application (==→eq, !=→not(eq …), <→lt, …) so eval
  -- dispatches to the user/derived impl.  RNone for primitives / arithmetic / other
  -- operators → the structural-builtin EBinOp eval path (unchanged, no recursion).
  -- The parser always builds a fresh `Ref RNone`; sexp/astdump ignore the ref.
  | EBinOp String Expr Expr (Ref Route)
  -- Roadmap #18c: the trailing route ref mirrors EBinOp's — filled by
  -- resolveUnopSites for `-` (Num's `negate`) when the operand grounds to a
  -- NON-primitive Num type; dictPass then rewrites such a stamped node into
  -- `EMethodAt "negate"` so eval dispatches to the user impl.  RNone for
  -- Int/Float → the structural-builtin EUnOp eval path (unchanged). `!` never
  -- routes (unopMethod "!" = None). The parser always builds a fresh
  -- `Ref RNone`; sexp/astdump ignore the ref.
  | EUnOp String Expr (Ref Route)
  | EInfix String Expr Expr
  -- field access `r.f`.  The trailing `Ref String` is the resolved record name
  -- (stamped by typecheck's inferFieldAccess; "" = unknown).  The emitter reads
  -- it to pick the record by (recName, label) so two records sharing a field
  -- name at different indices resolve to the correct offset.  Same Ref-stamp
  -- idiom as EIndex/ESlice; sexp/printer ignore the ref.
  | EFieldAccess Expr String (Ref String)
  | ETuple (List Expr)
  | EListLit (List Expr)
  | EArrayLit (List Expr)
  | ERangeList Expr Expr Bool
  | ERangeArray Expr Expr Bool
  -- index/slice sugar.  `a.[lo..hi]` / `a.[lo..=hi]`; the trailing `Bool` is the
  -- inclusive flag.  The trailing `Ref String` is now VESTIGIAL: ESlice is
  -- desugared to a `slice` method call (the `Slice` interface, #670) BEFORE
  -- resolve/typecheck/lower, so nothing stamps or reads the ref any more (the old
  -- `inferSlice`/`indexKind` typecheck arm and the static-tag `CStringSlice`/
  -- `CListSlice`/`CSlice` lowering are dead — tracked for removal in #700).  The
  -- field is kept only so the node's AST/printer shape is unchanged and
  -- `.[lo..hi]` round-trips; sexp/printer ignore the ref.  (`EIndex`'s ref is
  -- likewise vestigial — it desugars to `index`.)
  | ESlice Expr Expr Expr Bool (Ref String)
  | ELetGroup (List LetBind) Expr
  | ESection Section
  | EIndex Expr Expr (Ref String)
  | EAnnot Expr Ty
  -- Head-pinned type annotation (`e :~ T`).  The parser never produces this, but
  -- desugar's container-literal lowering does: `Map { … }`/`Set { … }` become
  -- `(fromEntries [...] :~ Name …)`, pinning the result type so `fromEntries`
  -- dispatches by the literal's named type (mirror of lib/ast.ml's EHeadAnnot).
  | EHeadAnnot Expr Ty
  | EBlock (List DoStmt)
  | EDo (List DoStmt)
  | EStringInterp (List InterpPart)
  | EGuards (List GuardArm)
  | ERecordCreate String (List FieldAssign)
  -- functional record update `{ base | f = v … }`.  The trailing `Ref String` is
  -- the resolved record name of the RECEIVER (stamped by typecheck's
  -- inferRecordUpdate; "" = unknown), exactly as EFieldAccess carries it — and
  -- for the same reason: two records sharing a field name at DIFFERENT slot
  -- indices are indistinguishable from the field label alone, so an emitter that
  -- guesses the record from the first update label writes the wrong slot (bug
  -- #38, a silent miscompile on both backends).  sexp/printer ignore the ref.
  | ERecordUpdate Expr (List FieldAssign) (Ref String)
  | EVariantUpdate String Expr (List FieldAssign)
  | EMapLit String (List (Expr, Expr))
  | ESetLit String (List Expr)
  -- `x@subpat` in a binding LHS (lambda/do-bind param): the parser emits EAsPat,
  -- which exprToPat lowers to PAs.  Elsewhere resolve would reject it, so it
  -- never survives into a typed program (the reference's `EAsPat`).
  | EAsPat String Expr
  -- Method_marker output (the parser never produces these; the typecheck-filled
  -- ref the reference carries is irrelevant pre-typecheck, so just the name).
  | EMethodRef String
  | EDictApp String
  -- A variable reference annotated with its resolved lexical address (STAGE2-
  -- DESIGN §2.0).  The parser never produces this — it emits plain `EVar`; the
  -- self-hosted resolve's `annotateProgram` pass rewrites `EVar n` → `EVarAt n
  -- addr`, carrying the (frame, slot) the eventual slot-indexing eval will read.
  -- The name is kept for the AGlobal by-name fallback and method/shadow lookup.
  -- Unconsumed today (no eval arm, no sexp/astdump clause), so every dump stays
  -- byte-identical: this node only ever lives in resolve's annotated output.
  | EVarAt String Addr
  -- Resolve-only (#837): a variable occurrence stamped by resolve's `stampBindingIds`
  -- pass with the monotonic id of the binding it resolves to.  0 = unidentified —
  -- resolved to a local/pattern/where binder whose id is deferred (increment 1 mints
  -- only TOP-LEVEL binders), or a cross-module/global/unbound name — read as the
  -- bare-name fallback (today's behaviour).  Transparent: sexp/printer render as bare
  -- `n`, lower/mangle strip it to `EVar n`, so all dump/IR gates stay byte-identical.
  -- Only ever lives in the transient tree typecheck infers; never reaches emit/eval.
  | EVarId String Int
  -- Return-position method occurrence (pure/empty/…) rewritten by the self-hosted
  -- typecheck's pre-pass: method name + a mutable route the typechecker resolves.
  -- RKey = the concrete impl's head type — or, when two impls share that head type
  -- (TYPECHECK-AUDIT C7), the canonical impl key (`iface|args|name`); eval narrows the
  -- VMulti by matching EITHER against each candidate's head tag or its key.  RDict =
  -- the enclosing constrained function's dict parameter (read at runtime, then
  -- narrow).  Only appears in the typed eval pipeline, never in parse/mark output.
  --
  -- The second ref carries the SELECTED impl's `requires` dicts (the reference's
  -- res_impl_dicts): when the route resolves to a parametric impl with a `requires`
  -- (e.g. `impl Default (List a) requires Default a`), each constraint becomes one
  -- route, eval folds them onto the narrowed impl value as leading args so the
  -- element dict reaches a return-position ref inside the impl body (`def` in
  -- `def = [def]`).  Empty for every ordinary site (no requires) — eval's fold is a
  -- no-op then.  Single-level only (`def : List Int`); nested dicts are residual #5.
  --
  -- The THIRD ref carries the method's OWN method-level-constraint dicts (the
  -- reference's res_method_dicts): a method whose signature has a `=>` constraint
  -- over a tyvar that is NOT the interface param (the canonical case is
  -- `foldMap : Monoid m => (a -> m) -> t a -> m`, where `Monoid m` constrains the
  -- result monoid `m`, independent of the container `t`).  At a call site the
  -- constraint's concrete type → one RKey route; eval folds them onto the method
  -- value as leading args BEFORE the impl-requires dicts, matching the params
  -- dict_pass prepends to the method's default body / impl clauses, so a
  -- return-position ref inside that body (`empty` in foldMap's default) reads the
  -- caller-supplied dict.  Empty for every ordinary site — eval's fold is a no-op.
  | EMethodAt String (Ref Route) (Ref (List Route)) (Ref (List Route))
  -- Constrained-function occurrence (`f` where `f : C a => …`) rewritten by the
  -- same pre-pass: the function name + one route per `=>` constraint, filled by
  -- the typechecker.  Eval applies the matching dictionaries as leading args,
  -- lining up with the dict params dict_pass prepended to f's definition.
  | EDictAt String (Ref (List Route))
  -- Transparent source-location wrapper (mirror of lib/ast.ml:193 `ELoc of
  -- loc * expr`).  The parser wraps atom/leaf and statement-form productions
  -- (matching parser.mly's atoms + let/if/match/function/do/lambda/as-pat) so
  -- typecheck/resolve can attribute errors to a precise expression span via a
  -- `currentLoc` ref.  Semantically transparent: every stage either recurses
  -- through it or strips it.  sexp.mdk renders it transparently and core_ir_
  -- lower.mdk strips it before Core IR, so all parse/sexp/IR gates stay
  -- byte-identical.  The parser never builds nested binop/app wrappers (it
  -- wraps leaves + statement forms only, exactly like parser.mly).
  | ELoc Loc Expr
  -- Phase 150: transparent marker wrapping a do-lowered andThen/pure chain;
  -- carries the do-block's loc so typecheck can emit a tailored "do requires a
  -- monad" error.  Desugar-introduced, never parsed/round-tripped.
  | EDoOrigin Loc Expr
  -- PLAN.md #11: a *source* integer literal in EXPRESSION position, polymorphic
  -- over `Num a` (mirror of lib/ast.ml's `ENumLit of int * float option ref`).
  -- The parser emits this (never `ELit (LInt)`) for an integer in expression
  -- position; pattern-position int literals stay `PLit (LInt)` Int (locked §0.4).
  -- typecheck infers a fresh `Num`-obligated var; the post-HM defaulting pass
  -- grounds an ambiguous Num-only var to Int; then a final pass stamps the ref
  -- `Some f` iff the literal's inferred type ground to Float.  dictPass rewrites
  -- the node to `ELit (LFloat f)` (float ref = Some f), `ELit (LInt n)` (both
  -- cells empty), or — the #11 soundness arm, mirror of lib/ast.ml's third payload
  -- `resolved option ref` — `EApp (EMethodAt "fromInt" …) (ELit (LInt n))` when the
  -- literal stays a polymorphic `Num a` (the `1` in `inc x = x + 1`): the third
  -- field is the `fromInt`-route cell (`Ref Route`), filled by resolveSites with
  -- the RDictFwd route onto the enclosing `Num a` dict (exactly core.mdk's
  -- `fromInt 0` in `sum`), so the runtime Num dict elaborates the literal and
  -- `inc 2.5` no longer crashes `VFloat + VInt`.  Before eval/emit, dictPass
  -- rewrites every `ENumLit` away, so eval/emit never see it.  sexp/astdump render
  -- it identically to `(ELit (LInt n))` so the OCaml↔compiler sexp diff is unchanged
  -- (the compiler AST node is new but renders to the same S-expression).
  --
  -- The 4th field is the ORIGINAL SOURCE LEXEME of the literal (#458), carried
  -- verbatim from the `TInt` token so `fmt`/the printer can reproduce the author's
  -- radix and separators — `0xD800` stays `0xD800`, not `55296`; `1_000` keeps its
  -- underscore.  A negative fused literal (`-0x…`, tight `f -0x…`) stores the sign
  -- IN the lexeme.  Empty "" means synthesized (desugar, `exprToPat`) → the printer
  -- falls back to `intToString`.  Ignored by every non-printing stage (sexp/eval/
  -- typecheck/lower render from the value), so it does not perturb goldens or Eq.
  | ENumLit Int (Ref (Option Float)) (Ref Route) String

-- import paths: `import q.{members}`, `import q.path`, `import q.*`, `import q as A`
--
-- IMPORT ALIASING — every import binds (ORIGIN name, LOCAL name) pairs.  The origin
-- is the name in the EXPORTING module; the local is the name it lands under HERE.
-- Without an alias the two coincide, which is why every consumer historically used a
-- single bare name.  Two surface forms introduce a divergence:
--
--   `import m.{a as b}`  member alias  → origin `a`, local `b`
--   `import m as A`      module alias  → origin `f`, local `A.f`, for every value
--                                        `f` that `m` exports
--
-- An alias REPLACES the unqualified import: `import m as A` does NOT also bind bare
-- `f`, and `import m.{a as b}` does NOT also bind `a`.  That is what makes a name
-- collision between two modules resolvable (the whole point of aliasing).
--
-- A module alias's local names are DOTTED (`A.f`).  That is deliberate: a dot cannot
-- occur in a surface identifier, so `A.f` can never collide with a user name, and it
-- reads correctly in a diagnostic ("Unbound variable: A.f").  It is only ever a SCOPE
-- KEY — `frontend/desugar.mdk` rewrites the qualified reference `A.f` (parsed as an
-- `EFieldAccess` on the alias) to a plain `EVar "A.f"`, and `backend/private_mangle.mdk`
-- maps it back to the origin module's real symbol, so no dotted name ever reaches the
-- emitted code.
public export data UseMember = UseMember String Bool Loc (Option String)
public export data UsePath =
  | UseName (List String)
  | UseGroup (List String) (List UseMember)
  | UseWild (List String)
  | UseAlias (List String) String

-- the name a UseGroup member has in the EXPORTING module (what to look up).
export useMemberOrigin : UseMember -> String
useMemberOrigin (UseMember n _ _ _) = n

-- the member's alias, if it was written `a as b`.
export useMemberAlias : UseMember -> Option String
useMemberAlias (UseMember _ _ _ alias) = alias

-- the name a UseGroup member binds HERE: its alias if it has one, else its own name.
export useMemberLocal : UseMember -> String
useMemberLocal (UseMember n _ _ alias) = match alias
  Some a => a
  None => n

-- the local name a MODULE alias binds an origin export under: `A` + `f` → `A.f`.
export qualifiedLocal : String -> String -> String
qualifiedLocal alias n = "\{alias}.\{n}"

-- a property-test parameter `(name : ty)`.
-- The Loc is the param-NAME token (#913 Inc 2b: renaming a prop param must
-- land on its own token, not the prop's name string).
public export data PropParam = PropParam String Loc Ty

-- interface / impl pieces
public export data MethodDefault = MethodDefault (List Pat) Expr
public export data IfaceMethod = IfaceMethod String Ty (Option MethodDefault)
public export data Super = Super String (List String)
public export data Require = Require String (List Ty)
public export data ImplMethod = ImplMethod String (List Pat) Expr

-- data/record declarations
public export data DataVis = VisPrivate | VisAbstract | VisPublic
public export data Field = Field String Ty
-- `ConNamed fields nameOmitted`: named-field (record-style) constructor
-- payload.  `nameOmitted` is a pure surface marker — True when the ctor name
-- was omitted in the source short form `data X = { … }` (the synthesized ctor
-- name equals the tycon name).  It changes nothing downstream (typecheck / eval
-- / emit / deriving all use the stored name); only the printer/fmt consults it
-- to round-trip the short form back as `data X = { … }`.
public export data ConPayload = ConPos (List Ty) | ConNamed (List Field) Bool
public export data Variant = Variant String ConPayload

-- declaration attributes: `@deprecated "msg"`, `@inline`, `@must_use`
public export data Attr = AttrDeprecated String | AttrInline | AttrMustUse

-- One name inside a `deriving (…)` clause, carrying the span of the NAME itself
-- so desugar can point a "cannot derive" diagnostic at the offending name rather
-- than at the decl.  The loc is `Some` only on the `parseLocated` path (the same
-- convention as `TyCon`'s `Option Loc`); the pure `parse` path leaves placeholders.
public export data DeriveRef = DeriveRef String (Option Loc)

export deriveRefName : DeriveRef -> String
deriveRefName (DeriveRef n _) = n

public export data Decl =
  | DTypeSig Bool String Ty
  | DExtern Bool String Ty
  | DFunDef Bool String (List Pat) Expr
  | DData DataVis String (List String) (List Variant) (List DeriveRef)
  | DUse Bool UsePath Loc
  -- pub? name domain?  `effect Foo` (atomic host capability),
  -- `effect Net Prefix` (domain-carrying).  v2 Stage 2a: domain = Some "Prefix" or None.
  | DEffect Bool String (Option String)
  | DProp Bool String (List PropParam) Expr
  | DTest Bool String Expr
  | DBench Bool String Expr
  | DInterface {
      pub : Bool,
      def : Bool,
      name : String,
      typarams : List String,
      supers : List Super,
      methods : List IfaceMethod,
    }
  | DImpl {
      pub : Bool,
      iface : String,
      tys : List Ty,
      reqs : List Require,
      methods : List ImplMethod,
    }
  -- pub? name typarams rhs
  | DTypeAlias Bool String (List String) Ty
  -- pub? tyname typarams conname fieldty derives
  | DNewtype Bool String (List String) String Ty (List DeriveRef)
  -- top-level `let rec … with …` mutually-recursive group
  | DLetGroup Bool (List LetBind)
  -- `@attr…` annotations wrapping the next decl
  | DAttrib (List Attr) Decl
# DESUGAR
(DData Public "Lit" () ((variant "LInt" (ConPos (TyCon "Int"))) (variant "LFloat" (ConPos (TyCon "Float"))) (variant "LString" (ConPos (TyCon "String"))) (variant "LChar" (ConPos (TyCon "String"))) (variant "LBool" (ConPos (TyCon "Bool"))) (variant "LUnit" (ConPos))) ())
(DImpl true "Eq" ((TyCon "Lit")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "LInt" (PVar "__a0")) (PCon "LInt" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "LFloat" (PVar "__a0")) (PCon "LFloat" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "LString" (PVar "__a0")) (PCon "LString" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "LChar" (PVar "__a0")) (PCon "LChar" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "LBool" (PVar "__a0")) (PCon "LBool" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "LUnit") (PCon "LUnit")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DData Public "Loc" () ((variant "Loc" (ConPos (TyCon "String") (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int")))) ())
(DData Public "TyConOrigin" () ((variant "OriginUnresolved" (ConPos)) (variant "OriginBuiltin" (ConPos)) (variant "OriginModule" (ConPos (TyCon "String")))) ())
(DData Public "Ty" () ((variant "TyCon" (ConNamed (field "name" (TyCon "String")) (field "loc" (TyApp (TyCon "Option") (TyCon "Loc"))) (field "origin" (TyCon "TyConOrigin")))) (variant "TyVar" (ConPos (TyCon "String"))) (variant "TyApp" (ConPos (TyCon "Ty") (TyCon "Ty"))) (variant "TyFun" (ConPos (TyCon "Ty") (TyCon "Ty"))) (variant "TyTuple" (ConPos (TyApp (TyCon "List") (TyCon "Ty")))) (variant "TyEffect" (ConPos (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))) (TyApp (TyCon "Option") (TyCon "String")) (TyCon "Ty"))) (variant "TyConstrained" (ConPos (TyApp (TyCon "List") (TyCon "Constraint")) (TyCon "Ty"))) (variant "TyRow" (ConPos (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))) (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "Loc"))))) ())
(DTypeSig true "tyConUnresolved" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Ty"))))
(DFunDef false "tyConUnresolved" ((PVar "n") (PVar "l")) (ERecordCreate "TyCon" ((fa "name" (EVar "n")) (fa "loc" (EVar "l")) (fa "origin" (EVar "OriginUnresolved")))))
(DData Public "Constraint" () ((variant "Constraint" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyCon "Ty"))))) ())
(DTypeSig true "orElseLoc" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyApp (TyCon "Option") (TyCon "Loc")))))
(DFunDef false "orElseLoc" ((PCon "Some" (PVar "l")) PWild) (EApp (EVar "Some") (EVar "l")))
(DFunDef false "orElseLoc" ((PCon "None") (PVar "fallback")) (EVar "fallback"))
(DTypeSig true "firstTyLoc" (TyFun (TyCon "Ty") (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "firstTyLoc" ((PRec "TyCon" ((rf "loc" None)) false)) (EVar "loc"))
(DFunDef false "firstTyLoc" ((PCon "TyVar" PWild)) (EVar "None"))
(DFunDef false "firstTyLoc" ((PCon "TyApp" (PVar "f") (PVar "x"))) (EApp (EApp (EVar "orElseLoc") (EApp (EVar "firstTyLoc") (EVar "f"))) (EApp (EVar "firstTyLoc") (EVar "x"))))
(DFunDef false "firstTyLoc" ((PCon "TyFun" (PVar "f") (PVar "x"))) (EApp (EApp (EVar "orElseLoc") (EApp (EVar "firstTyLoc") (EVar "f"))) (EApp (EVar "firstTyLoc") (EVar "x"))))
(DFunDef false "firstTyLoc" ((PCon "TyTuple" (PVar "ts"))) (EApp (EVar "firstTyLocList") (EVar "ts")))
(DFunDef false "firstTyLoc" ((PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EVar "firstTyLoc") (EVar "t")))
(DFunDef false "firstTyLoc" ((PCon "TyConstrained" PWild (PVar "t"))) (EApp (EVar "firstTyLoc") (EVar "t")))
(DFunDef false "firstTyLoc" ((PCon "TyRow" PWild PWild (PVar "l"))) (EVar "l"))
(DTypeSig true "firstTyLocList" (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "firstTyLocList" ((PList)) (EVar "None"))
(DFunDef false "firstTyLocList" ((PCons (PVar "t") (PVar "rest"))) (EApp (EApp (EVar "orElseLoc") (EApp (EVar "firstTyLoc") (EVar "t"))) (EApp (EVar "firstTyLocList") (EVar "rest"))))
(DData Public "Route" () ((variant "RNone" (ConPos)) (variant "RKey" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyCon "Route")))) (variant "RDict" (ConPos (TyCon "String"))) (variant "RDictFwd" (ConPos (TyCon "String"))) (variant "RLocal" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyCon "Route")))) (variant "RScalar" (ConPos (TyCon "String")))) ())
(DData Public "Addr" () ((variant "ALocal" (ConPos (TyCon "Int") (TyCon "Int"))) (variant "AGlobal" (ConPos))) ())
(DData Public "Pat" () ((variant "PVar" (ConPos (TyCon "String") (TyCon "Loc"))) (variant "PWild" (ConPos)) (variant "PLit" (ConPos (TyCon "Lit"))) (variant "PCon" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")))) (variant "PCons" (ConPos (TyCon "Pat") (TyCon "Pat"))) (variant "PTuple" (ConPos (TyApp (TyCon "List") (TyCon "Pat")))) (variant "PList" (ConPos (TyApp (TyCon "List") (TyCon "Pat")))) (variant "PAs" (ConPos (TyCon "String") (TyCon "Loc") (TyCon "Pat"))) (variant "PRng" (ConPos (TyCon "Lit") (TyCon "Lit") (TyCon "Bool"))) (variant "PRec" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyCon "RecPatField")) (TyCon "Bool")))) ())
(DData Public "RecPatField" () ((variant "RecPatField" (ConPos (TyCon "String") (TyCon "Loc") (TyApp (TyCon "Option") (TyCon "Pat"))))) ())
(DData Public "Guard" () ((variant "GBool" (ConPos (TyCon "Expr"))) (variant "GBind" (ConPos (TyCon "Pat") (TyCon "Expr")))) ())
(DData Public "Arm" () ((variant "Arm" (ConPos (TyCon "Pat") (TyApp (TyCon "List") (TyCon "Guard")) (TyCon "Expr")))) ())
(DData Public "DoStmt" () ((variant "DoExpr" (ConPos (TyCon "Expr"))) (variant "DoBind" (ConPos (TyCon "Pat") (TyCon "Expr"))) (variant "DoLet" (ConPos (TyCon "Bool") (TyCon "Bool") (TyCon "Pat") (TyCon "Expr"))) (variant "DoAssign" (ConPos (TyCon "String") (TyCon "Expr"))) (variant "DoFieldAssign" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyCon "String")) (TyCon "Expr")))) ())
(DData Public "InterpPart" () ((variant "InterpStr" (ConPos (TyCon "String"))) (variant "InterpExpr" (ConPos (TyCon "Expr")))) ())
(DData Public "GuardArm" () ((variant "GuardArm" (ConPos (TyApp (TyCon "List") (TyCon "Guard")) (TyCon "Expr")))) ())
(DData Public "FieldAssign" () ((variant "FieldAssign" (ConPos (TyCon "String") (TyCon "Expr")))) ())
(DData Public "Section" () ((variant "SecBare" (ConPos (TyCon "String"))) (variant "SecRight" (ConPos (TyCon "String") (TyCon "Expr"))) (variant "SecLeft" (ConPos (TyCon "Expr") (TyCon "String")))) ())
(DData Public "FunClause" () ((variant "FunClause" (ConPos (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) ())
(DData Public "LetBind" () ((variant "LetBind" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyCon "FunClause"))))) ())
(DData Public "Expr" () ((variant "ELit" (ConPos (TyCon "Lit"))) (variant "EVar" (ConPos (TyCon "String"))) (variant "EApp" (ConPos (TyCon "Expr") (TyCon "Expr"))) (variant "ELam" (ConPos (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))) (variant "ELet" (ConPos (TyCon "Bool") (TyCon "Bool") (TyCon "Pat") (TyCon "Expr") (TyCon "Expr"))) (variant "EMatch" (ConPos (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Arm")))) (variant "EIf" (ConPos (TyCon "Expr") (TyCon "Expr") (TyCon "Expr"))) (variant "EBinOp" (ConPos (TyCon "String") (TyCon "Expr") (TyCon "Expr") (TyApp (TyCon "Ref") (TyCon "Route")))) (variant "EUnOp" (ConPos (TyCon "String") (TyCon "Expr") (TyApp (TyCon "Ref") (TyCon "Route")))) (variant "EInfix" (ConPos (TyCon "String") (TyCon "Expr") (TyCon "Expr"))) (variant "EFieldAccess" (ConPos (TyCon "Expr") (TyCon "String") (TyApp (TyCon "Ref") (TyCon "String")))) (variant "ETuple" (ConPos (TyApp (TyCon "List") (TyCon "Expr")))) (variant "EListLit" (ConPos (TyApp (TyCon "List") (TyCon "Expr")))) (variant "EArrayLit" (ConPos (TyApp (TyCon "List") (TyCon "Expr")))) (variant "ERangeList" (ConPos (TyCon "Expr") (TyCon "Expr") (TyCon "Bool"))) (variant "ERangeArray" (ConPos (TyCon "Expr") (TyCon "Expr") (TyCon "Bool"))) (variant "ESlice" (ConPos (TyCon "Expr") (TyCon "Expr") (TyCon "Expr") (TyCon "Bool") (TyApp (TyCon "Ref") (TyCon "String")))) (variant "ELetGroup" (ConPos (TyApp (TyCon "List") (TyCon "LetBind")) (TyCon "Expr"))) (variant "ESection" (ConPos (TyCon "Section"))) (variant "EIndex" (ConPos (TyCon "Expr") (TyCon "Expr") (TyApp (TyCon "Ref") (TyCon "String")))) (variant "EAnnot" (ConPos (TyCon "Expr") (TyCon "Ty"))) (variant "EHeadAnnot" (ConPos (TyCon "Expr") (TyCon "Ty"))) (variant "EBlock" (ConPos (TyApp (TyCon "List") (TyCon "DoStmt")))) (variant "EDo" (ConPos (TyApp (TyCon "List") (TyCon "DoStmt")))) (variant "EStringInterp" (ConPos (TyApp (TyCon "List") (TyCon "InterpPart")))) (variant "EGuards" (ConPos (TyApp (TyCon "List") (TyCon "GuardArm")))) (variant "ERecordCreate" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyCon "FieldAssign")))) (variant "ERecordUpdate" (ConPos (TyCon "Expr") (TyApp (TyCon "List") (TyCon "FieldAssign")) (TyApp (TyCon "Ref") (TyCon "String")))) (variant "EVariantUpdate" (ConPos (TyCon "String") (TyCon "Expr") (TyApp (TyCon "List") (TyCon "FieldAssign")))) (variant "EMapLit" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "Expr") (TyCon "Expr"))))) (variant "ESetLit" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyCon "Expr")))) (variant "EAsPat" (ConPos (TyCon "String") (TyCon "Expr"))) (variant "EMethodRef" (ConPos (TyCon "String"))) (variant "EDictApp" (ConPos (TyCon "String"))) (variant "EVarAt" (ConPos (TyCon "String") (TyCon "Addr"))) (variant "EVarId" (ConPos (TyCon "String") (TyCon "Int"))) (variant "EMethodAt" (ConPos (TyCon "String") (TyApp (TyCon "Ref") (TyCon "Route")) (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Route"))) (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Route"))))) (variant "EDictAt" (ConPos (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Route"))))) (variant "ELoc" (ConPos (TyCon "Loc") (TyCon "Expr"))) (variant "EDoOrigin" (ConPos (TyCon "Loc") (TyCon "Expr"))) (variant "ENumLit" (ConPos (TyCon "Int") (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "Float"))) (TyApp (TyCon "Ref") (TyCon "Route")) (TyCon "String")))) ())
(DData Public "UseMember" () ((variant "UseMember" (ConPos (TyCon "String") (TyCon "Bool") (TyCon "Loc") (TyApp (TyCon "Option") (TyCon "String"))))) ())
(DData Public "UsePath" () ((variant "UseName" (ConPos (TyApp (TyCon "List") (TyCon "String")))) (variant "UseGroup" (ConPos (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "UseMember")))) (variant "UseWild" (ConPos (TyApp (TyCon "List") (TyCon "String")))) (variant "UseAlias" (ConPos (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))) ())
(DTypeSig true "useMemberOrigin" (TyFun (TyCon "UseMember") (TyCon "String")))
(DFunDef false "useMemberOrigin" ((PCon "UseMember" (PVar "n") PWild PWild PWild)) (EVar "n"))
(DTypeSig true "useMemberAlias" (TyFun (TyCon "UseMember") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "useMemberAlias" ((PCon "UseMember" PWild PWild PWild (PVar "alias"))) (EVar "alias"))
(DTypeSig true "useMemberLocal" (TyFun (TyCon "UseMember") (TyCon "String")))
(DFunDef false "useMemberLocal" ((PCon "UseMember" (PVar "n") PWild PWild (PVar "alias"))) (EMatch (EVar "alias") (arm (PCon "Some" (PVar "a")) () (EVar "a")) (arm (PCon "None") () (EVar "n"))))
(DTypeSig true "qualifiedLocal" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "qualifiedLocal" ((PVar "alias") (PVar "n")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "alias"))) (ELit (LString "."))) (EApp (EVar "display") (EVar "n"))) (ELit (LString ""))))
(DData Public "PropParam" () ((variant "PropParam" (ConPos (TyCon "String") (TyCon "Loc") (TyCon "Ty")))) ())
(DData Public "MethodDefault" () ((variant "MethodDefault" (ConPos (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) ())
(DData Public "IfaceMethod" () ((variant "IfaceMethod" (ConPos (TyCon "String") (TyCon "Ty") (TyApp (TyCon "Option") (TyCon "MethodDefault"))))) ())
(DData Public "Super" () ((variant "Super" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))) ())
(DData Public "Require" () ((variant "Require" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyCon "Ty"))))) ())
(DData Public "ImplMethod" () ((variant "ImplMethod" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) ())
(DData Public "DataVis" () ((variant "VisPrivate" (ConPos)) (variant "VisAbstract" (ConPos)) (variant "VisPublic" (ConPos))) ())
(DData Public "Field" () ((variant "Field" (ConPos (TyCon "String") (TyCon "Ty")))) ())
(DData Public "ConPayload" () ((variant "ConPos" (ConPos (TyApp (TyCon "List") (TyCon "Ty")))) (variant "ConNamed" (ConPos (TyApp (TyCon "List") (TyCon "Field")) (TyCon "Bool")))) ())
(DData Public "Variant" () ((variant "Variant" (ConPos (TyCon "String") (TyCon "ConPayload")))) ())
(DData Public "Attr" () ((variant "AttrDeprecated" (ConPos (TyCon "String"))) (variant "AttrInline" (ConPos)) (variant "AttrMustUse" (ConPos))) ())
(DData Public "DeriveRef" () ((variant "DeriveRef" (ConPos (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc"))))) ())
(DTypeSig true "deriveRefName" (TyFun (TyCon "DeriveRef") (TyCon "String")))
(DFunDef false "deriveRefName" ((PCon "DeriveRef" (PVar "n") PWild)) (EVar "n"))
(DData Public "Decl" () ((variant "DTypeSig" (ConPos (TyCon "Bool") (TyCon "String") (TyCon "Ty"))) (variant "DExtern" (ConPos (TyCon "Bool") (TyCon "String") (TyCon "Ty"))) (variant "DFunDef" (ConPos (TyCon "Bool") (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))) (variant "DData" (ConPos (TyCon "DataVis") (TyCon "String") (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Variant")) (TyApp (TyCon "List") (TyCon "DeriveRef")))) (variant "DUse" (ConPos (TyCon "Bool") (TyCon "UsePath") (TyCon "Loc"))) (variant "DEffect" (ConPos (TyCon "Bool") (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))) (variant "DProp" (ConPos (TyCon "Bool") (TyCon "String") (TyApp (TyCon "List") (TyCon "PropParam")) (TyCon "Expr"))) (variant "DTest" (ConPos (TyCon "Bool") (TyCon "String") (TyCon "Expr"))) (variant "DBench" (ConPos (TyCon "Bool") (TyCon "String") (TyCon "Expr"))) (variant "DInterface" (ConNamed (field "pub" (TyCon "Bool")) (field "def" (TyCon "Bool")) (field "name" (TyCon "String")) (field "typarams" (TyApp (TyCon "List") (TyCon "String"))) (field "supers" (TyApp (TyCon "List") (TyCon "Super"))) (field "methods" (TyApp (TyCon "List") (TyCon "IfaceMethod"))))) (variant "DImpl" (ConNamed (field "pub" (TyCon "Bool")) (field "iface" (TyCon "String")) (field "tys" (TyApp (TyCon "List") (TyCon "Ty"))) (field "reqs" (TyApp (TyCon "List") (TyCon "Require"))) (field "methods" (TyApp (TyCon "List") (TyCon "ImplMethod"))))) (variant "DTypeAlias" (ConPos (TyCon "Bool") (TyCon "String") (TyApp (TyCon "List") (TyCon "String")) (TyCon "Ty"))) (variant "DNewtype" (ConPos (TyCon "Bool") (TyCon "String") (TyApp (TyCon "List") (TyCon "String")) (TyCon "String") (TyCon "Ty") (TyApp (TyCon "List") (TyCon "DeriveRef")))) (variant "DLetGroup" (ConPos (TyCon "Bool") (TyApp (TyCon "List") (TyCon "LetBind")))) (variant "DAttrib" (ConPos (TyApp (TyCon "List") (TyCon "Attr")) (TyCon "Decl")))) ())
# MARK
(DData Public "Lit" () ((variant "LInt" (ConPos (TyCon "Int"))) (variant "LFloat" (ConPos (TyCon "Float"))) (variant "LString" (ConPos (TyCon "String"))) (variant "LChar" (ConPos (TyCon "String"))) (variant "LBool" (ConPos (TyCon "Bool"))) (variant "LUnit" (ConPos))) ())
(DImpl true "Eq" ((TyCon "Lit")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "LInt" (PVar "__a0")) (PCon "LInt" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "LFloat" (PVar "__a0")) (PCon "LFloat" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "LString" (PVar "__a0")) (PCon "LString" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "LChar" (PVar "__a0")) (PCon "LChar" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "LBool" (PVar "__a0")) (PCon "LBool" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "LUnit") (PCon "LUnit")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DData Public "Loc" () ((variant "Loc" (ConPos (TyCon "String") (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int")))) ())
(DData Public "TyConOrigin" () ((variant "OriginUnresolved" (ConPos)) (variant "OriginBuiltin" (ConPos)) (variant "OriginModule" (ConPos (TyCon "String")))) ())
(DData Public "Ty" () ((variant "TyCon" (ConNamed (field "name" (TyCon "String")) (field "loc" (TyApp (TyCon "Option") (TyCon "Loc"))) (field "origin" (TyCon "TyConOrigin")))) (variant "TyVar" (ConPos (TyCon "String"))) (variant "TyApp" (ConPos (TyCon "Ty") (TyCon "Ty"))) (variant "TyFun" (ConPos (TyCon "Ty") (TyCon "Ty"))) (variant "TyTuple" (ConPos (TyApp (TyCon "List") (TyCon "Ty")))) (variant "TyEffect" (ConPos (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))) (TyApp (TyCon "Option") (TyCon "String")) (TyCon "Ty"))) (variant "TyConstrained" (ConPos (TyApp (TyCon "List") (TyCon "Constraint")) (TyCon "Ty"))) (variant "TyRow" (ConPos (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))) (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "Loc"))))) ())
(DTypeSig true "tyConUnresolved" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Ty"))))
(DFunDef false "tyConUnresolved" ((PVar "n") (PVar "l")) (ERecordCreate "TyCon" ((fa "name" (EVar "n")) (fa "loc" (EVar "l")) (fa "origin" (EVar "OriginUnresolved")))))
(DData Public "Constraint" () ((variant "Constraint" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyCon "Ty"))))) ())
(DTypeSig true "orElseLoc" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyApp (TyCon "Option") (TyCon "Loc")))))
(DFunDef false "orElseLoc" ((PCon "Some" (PVar "l")) PWild) (EApp (EVar "Some") (EVar "l")))
(DFunDef false "orElseLoc" ((PCon "None") (PVar "fallback")) (EVar "fallback"))
(DTypeSig true "firstTyLoc" (TyFun (TyCon "Ty") (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "firstTyLoc" ((PRec "TyCon" ((rf "loc" None)) false)) (EVar "loc"))
(DFunDef false "firstTyLoc" ((PCon "TyVar" PWild)) (EVar "None"))
(DFunDef false "firstTyLoc" ((PCon "TyApp" (PVar "f") (PVar "x"))) (EApp (EApp (EVar "orElseLoc") (EApp (EVar "firstTyLoc") (EVar "f"))) (EApp (EVar "firstTyLoc") (EVar "x"))))
(DFunDef false "firstTyLoc" ((PCon "TyFun" (PVar "f") (PVar "x"))) (EApp (EApp (EVar "orElseLoc") (EApp (EVar "firstTyLoc") (EVar "f"))) (EApp (EVar "firstTyLoc") (EVar "x"))))
(DFunDef false "firstTyLoc" ((PCon "TyTuple" (PVar "ts"))) (EApp (EVar "firstTyLocList") (EVar "ts")))
(DFunDef false "firstTyLoc" ((PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EVar "firstTyLoc") (EVar "t")))
(DFunDef false "firstTyLoc" ((PCon "TyConstrained" PWild (PVar "t"))) (EApp (EVar "firstTyLoc") (EVar "t")))
(DFunDef false "firstTyLoc" ((PCon "TyRow" PWild PWild (PVar "l"))) (EVar "l"))
(DTypeSig true "firstTyLocList" (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "firstTyLocList" ((PList)) (EVar "None"))
(DFunDef false "firstTyLocList" ((PCons (PVar "t") (PVar "rest"))) (EApp (EApp (EVar "orElseLoc") (EApp (EVar "firstTyLoc") (EVar "t"))) (EApp (EVar "firstTyLocList") (EVar "rest"))))
(DData Public "Route" () ((variant "RNone" (ConPos)) (variant "RKey" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyCon "Route")))) (variant "RDict" (ConPos (TyCon "String"))) (variant "RDictFwd" (ConPos (TyCon "String"))) (variant "RLocal" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyCon "Route")))) (variant "RScalar" (ConPos (TyCon "String")))) ())
(DData Public "Addr" () ((variant "ALocal" (ConPos (TyCon "Int") (TyCon "Int"))) (variant "AGlobal" (ConPos))) ())
(DData Public "Pat" () ((variant "PVar" (ConPos (TyCon "String") (TyCon "Loc"))) (variant "PWild" (ConPos)) (variant "PLit" (ConPos (TyCon "Lit"))) (variant "PCon" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")))) (variant "PCons" (ConPos (TyCon "Pat") (TyCon "Pat"))) (variant "PTuple" (ConPos (TyApp (TyCon "List") (TyCon "Pat")))) (variant "PList" (ConPos (TyApp (TyCon "List") (TyCon "Pat")))) (variant "PAs" (ConPos (TyCon "String") (TyCon "Loc") (TyCon "Pat"))) (variant "PRng" (ConPos (TyCon "Lit") (TyCon "Lit") (TyCon "Bool"))) (variant "PRec" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyCon "RecPatField")) (TyCon "Bool")))) ())
(DData Public "RecPatField" () ((variant "RecPatField" (ConPos (TyCon "String") (TyCon "Loc") (TyApp (TyCon "Option") (TyCon "Pat"))))) ())
(DData Public "Guard" () ((variant "GBool" (ConPos (TyCon "Expr"))) (variant "GBind" (ConPos (TyCon "Pat") (TyCon "Expr")))) ())
(DData Public "Arm" () ((variant "Arm" (ConPos (TyCon "Pat") (TyApp (TyCon "List") (TyCon "Guard")) (TyCon "Expr")))) ())
(DData Public "DoStmt" () ((variant "DoExpr" (ConPos (TyCon "Expr"))) (variant "DoBind" (ConPos (TyCon "Pat") (TyCon "Expr"))) (variant "DoLet" (ConPos (TyCon "Bool") (TyCon "Bool") (TyCon "Pat") (TyCon "Expr"))) (variant "DoAssign" (ConPos (TyCon "String") (TyCon "Expr"))) (variant "DoFieldAssign" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyCon "String")) (TyCon "Expr")))) ())
(DData Public "InterpPart" () ((variant "InterpStr" (ConPos (TyCon "String"))) (variant "InterpExpr" (ConPos (TyCon "Expr")))) ())
(DData Public "GuardArm" () ((variant "GuardArm" (ConPos (TyApp (TyCon "List") (TyCon "Guard")) (TyCon "Expr")))) ())
(DData Public "FieldAssign" () ((variant "FieldAssign" (ConPos (TyCon "String") (TyCon "Expr")))) ())
(DData Public "Section" () ((variant "SecBare" (ConPos (TyCon "String"))) (variant "SecRight" (ConPos (TyCon "String") (TyCon "Expr"))) (variant "SecLeft" (ConPos (TyCon "Expr") (TyCon "String")))) ())
(DData Public "FunClause" () ((variant "FunClause" (ConPos (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) ())
(DData Public "LetBind" () ((variant "LetBind" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyCon "FunClause"))))) ())
(DData Public "Expr" () ((variant "ELit" (ConPos (TyCon "Lit"))) (variant "EVar" (ConPos (TyCon "String"))) (variant "EApp" (ConPos (TyCon "Expr") (TyCon "Expr"))) (variant "ELam" (ConPos (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))) (variant "ELet" (ConPos (TyCon "Bool") (TyCon "Bool") (TyCon "Pat") (TyCon "Expr") (TyCon "Expr"))) (variant "EMatch" (ConPos (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Arm")))) (variant "EIf" (ConPos (TyCon "Expr") (TyCon "Expr") (TyCon "Expr"))) (variant "EBinOp" (ConPos (TyCon "String") (TyCon "Expr") (TyCon "Expr") (TyApp (TyCon "Ref") (TyCon "Route")))) (variant "EUnOp" (ConPos (TyCon "String") (TyCon "Expr") (TyApp (TyCon "Ref") (TyCon "Route")))) (variant "EInfix" (ConPos (TyCon "String") (TyCon "Expr") (TyCon "Expr"))) (variant "EFieldAccess" (ConPos (TyCon "Expr") (TyCon "String") (TyApp (TyCon "Ref") (TyCon "String")))) (variant "ETuple" (ConPos (TyApp (TyCon "List") (TyCon "Expr")))) (variant "EListLit" (ConPos (TyApp (TyCon "List") (TyCon "Expr")))) (variant "EArrayLit" (ConPos (TyApp (TyCon "List") (TyCon "Expr")))) (variant "ERangeList" (ConPos (TyCon "Expr") (TyCon "Expr") (TyCon "Bool"))) (variant "ERangeArray" (ConPos (TyCon "Expr") (TyCon "Expr") (TyCon "Bool"))) (variant "ESlice" (ConPos (TyCon "Expr") (TyCon "Expr") (TyCon "Expr") (TyCon "Bool") (TyApp (TyCon "Ref") (TyCon "String")))) (variant "ELetGroup" (ConPos (TyApp (TyCon "List") (TyCon "LetBind")) (TyCon "Expr"))) (variant "ESection" (ConPos (TyCon "Section"))) (variant "EIndex" (ConPos (TyCon "Expr") (TyCon "Expr") (TyApp (TyCon "Ref") (TyCon "String")))) (variant "EAnnot" (ConPos (TyCon "Expr") (TyCon "Ty"))) (variant "EHeadAnnot" (ConPos (TyCon "Expr") (TyCon "Ty"))) (variant "EBlock" (ConPos (TyApp (TyCon "List") (TyCon "DoStmt")))) (variant "EDo" (ConPos (TyApp (TyCon "List") (TyCon "DoStmt")))) (variant "EStringInterp" (ConPos (TyApp (TyCon "List") (TyCon "InterpPart")))) (variant "EGuards" (ConPos (TyApp (TyCon "List") (TyCon "GuardArm")))) (variant "ERecordCreate" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyCon "FieldAssign")))) (variant "ERecordUpdate" (ConPos (TyCon "Expr") (TyApp (TyCon "List") (TyCon "FieldAssign")) (TyApp (TyCon "Ref") (TyCon "String")))) (variant "EVariantUpdate" (ConPos (TyCon "String") (TyCon "Expr") (TyApp (TyCon "List") (TyCon "FieldAssign")))) (variant "EMapLit" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "Expr") (TyCon "Expr"))))) (variant "ESetLit" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyCon "Expr")))) (variant "EAsPat" (ConPos (TyCon "String") (TyCon "Expr"))) (variant "EMethodRef" (ConPos (TyCon "String"))) (variant "EDictApp" (ConPos (TyCon "String"))) (variant "EVarAt" (ConPos (TyCon "String") (TyCon "Addr"))) (variant "EVarId" (ConPos (TyCon "String") (TyCon "Int"))) (variant "EMethodAt" (ConPos (TyCon "String") (TyApp (TyCon "Ref") (TyCon "Route")) (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Route"))) (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Route"))))) (variant "EDictAt" (ConPos (TyCon "String") (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Route"))))) (variant "ELoc" (ConPos (TyCon "Loc") (TyCon "Expr"))) (variant "EDoOrigin" (ConPos (TyCon "Loc") (TyCon "Expr"))) (variant "ENumLit" (ConPos (TyCon "Int") (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "Float"))) (TyApp (TyCon "Ref") (TyCon "Route")) (TyCon "String")))) ())
(DData Public "UseMember" () ((variant "UseMember" (ConPos (TyCon "String") (TyCon "Bool") (TyCon "Loc") (TyApp (TyCon "Option") (TyCon "String"))))) ())
(DData Public "UsePath" () ((variant "UseName" (ConPos (TyApp (TyCon "List") (TyCon "String")))) (variant "UseGroup" (ConPos (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "UseMember")))) (variant "UseWild" (ConPos (TyApp (TyCon "List") (TyCon "String")))) (variant "UseAlias" (ConPos (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))) ())
(DTypeSig true "useMemberOrigin" (TyFun (TyCon "UseMember") (TyCon "String")))
(DFunDef false "useMemberOrigin" ((PCon "UseMember" (PVar "n") PWild PWild PWild)) (EVar "n"))
(DTypeSig true "useMemberAlias" (TyFun (TyCon "UseMember") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "useMemberAlias" ((PCon "UseMember" PWild PWild PWild (PVar "alias"))) (EVar "alias"))
(DTypeSig true "useMemberLocal" (TyFun (TyCon "UseMember") (TyCon "String")))
(DFunDef false "useMemberLocal" ((PCon "UseMember" (PVar "n") PWild PWild (PVar "alias"))) (EMatch (EVar "alias") (arm (PCon "Some" (PVar "a")) () (EVar "a")) (arm (PCon "None") () (EVar "n"))))
(DTypeSig true "qualifiedLocal" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "qualifiedLocal" ((PVar "alias") (PVar "n")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "alias"))) (ELit (LString "."))) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString ""))))
(DData Public "PropParam" () ((variant "PropParam" (ConPos (TyCon "String") (TyCon "Loc") (TyCon "Ty")))) ())
(DData Public "MethodDefault" () ((variant "MethodDefault" (ConPos (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) ())
(DData Public "IfaceMethod" () ((variant "IfaceMethod" (ConPos (TyCon "String") (TyCon "Ty") (TyApp (TyCon "Option") (TyCon "MethodDefault"))))) ())
(DData Public "Super" () ((variant "Super" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))) ())
(DData Public "Require" () ((variant "Require" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyCon "Ty"))))) ())
(DData Public "ImplMethod" () ((variant "ImplMethod" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))) ())
(DData Public "DataVis" () ((variant "VisPrivate" (ConPos)) (variant "VisAbstract" (ConPos)) (variant "VisPublic" (ConPos))) ())
(DData Public "Field" () ((variant "Field" (ConPos (TyCon "String") (TyCon "Ty")))) ())
(DData Public "ConPayload" () ((variant "ConPos" (ConPos (TyApp (TyCon "List") (TyCon "Ty")))) (variant "ConNamed" (ConPos (TyApp (TyCon "List") (TyCon "Field")) (TyCon "Bool")))) ())
(DData Public "Variant" () ((variant "Variant" (ConPos (TyCon "String") (TyCon "ConPayload")))) ())
(DData Public "Attr" () ((variant "AttrDeprecated" (ConPos (TyCon "String"))) (variant "AttrInline" (ConPos)) (variant "AttrMustUse" (ConPos))) ())
(DData Public "DeriveRef" () ((variant "DeriveRef" (ConPos (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc"))))) ())
(DTypeSig true "deriveRefName" (TyFun (TyCon "DeriveRef") (TyCon "String")))
(DFunDef false "deriveRefName" ((PCon "DeriveRef" (PVar "n") PWild)) (EVar "n"))
(DData Public "Decl" () ((variant "DTypeSig" (ConPos (TyCon "Bool") (TyCon "String") (TyCon "Ty"))) (variant "DExtern" (ConPos (TyCon "Bool") (TyCon "String") (TyCon "Ty"))) (variant "DFunDef" (ConPos (TyCon "Bool") (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))) (variant "DData" (ConPos (TyCon "DataVis") (TyCon "String") (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Variant")) (TyApp (TyCon "List") (TyCon "DeriveRef")))) (variant "DUse" (ConPos (TyCon "Bool") (TyCon "UsePath") (TyCon "Loc"))) (variant "DEffect" (ConPos (TyCon "Bool") (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))) (variant "DProp" (ConPos (TyCon "Bool") (TyCon "String") (TyApp (TyCon "List") (TyCon "PropParam")) (TyCon "Expr"))) (variant "DTest" (ConPos (TyCon "Bool") (TyCon "String") (TyCon "Expr"))) (variant "DBench" (ConPos (TyCon "Bool") (TyCon "String") (TyCon "Expr"))) (variant "DInterface" (ConNamed (field "pub" (TyCon "Bool")) (field "def" (TyCon "Bool")) (field "name" (TyCon "String")) (field "typarams" (TyApp (TyCon "List") (TyCon "String"))) (field "supers" (TyApp (TyCon "List") (TyCon "Super"))) (field "methods" (TyApp (TyCon "List") (TyCon "IfaceMethod"))))) (variant "DImpl" (ConNamed (field "pub" (TyCon "Bool")) (field "iface" (TyCon "String")) (field "tys" (TyApp (TyCon "List") (TyCon "Ty"))) (field "reqs" (TyApp (TyCon "List") (TyCon "Require"))) (field "methods" (TyApp (TyCon "List") (TyCon "ImplMethod"))))) (variant "DTypeAlias" (ConPos (TyCon "Bool") (TyCon "String") (TyApp (TyCon "List") (TyCon "String")) (TyCon "Ty"))) (variant "DNewtype" (ConPos (TyCon "Bool") (TyCon "String") (TyApp (TyCon "List") (TyCon "String")) (TyCon "String") (TyCon "Ty") (TyApp (TyCon "List") (TyCon "DeriveRef")))) (variant "DLetGroup" (ConPos (TyCon "Bool") (TyApp (TyCon "List") (TyCon "LetBind")))) (variant "DAttrib" (ConPos (TyApp (TyCon "List") (TyCon "Attr")) (TyCon "Decl")))) ())
