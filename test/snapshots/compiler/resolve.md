# META
source_lines=4554
stages=DESUGAR,MARK
# SOURCE
-- Self-hosted resolve stage (single-file
-- path: `resolveProgram`).  Runs after desugar.  Collects every binding name
-- into a name environment (seeded with primitives + runtime externs + the
-- prelude) and walks the decls reporting references that aren't in scope:
-- unbound variables, unknown constructors / types / effects / interfaces,
-- methods not in their interface, duplicate definitions, and extern-with-body.
--
-- Pure-functional: each check returns a `List ResError` rather than mutating a
-- ref; locations are dropped (the self-host AST has none), so the dump is the
-- sorted error structure — matching `dev/diagdump.exe --resolve`
-- (test/diff_compiler_resolve.sh).  The multi-module path (imports validated
-- against real exports, privacy, aliases) is the reference's resolve_module and
-- is NOT needed here: single-file mode stubs imports into scope.

import frontend.ast.{
  Loc(..),
  orElseLoc,
  Lit(..),
  Ty(..),
  TyConOrigin(..),
  mapTyInDecl,
  firstTyLoc,
  firstTyLocList,
  Constraint(..),
  Addr(..),
  Pat(..),
  RecPatField(..),
  Guard(..),
  Arm(..),
  DoStmt(..),
  InterpPart(..),
  GuardArm(..),
  FieldAssign(..),
  Section(..),
  FunClause(..),
  LetBind(..),
  Expr(..),
  UseMember(..),
  UsePath(..),
  useMemberLocal,
  qualifiedLocal,
  PropParam(..),
  MethodDefault(..),
  IfaceMethod(..),
  Super(..),
  Require(..),
  ImplMethod(..),
  DataVis(..),
  Field(..),
  ConPayload(..),
  Variant(..),
  Decl(..),
}
import support.ordmap.{
  OrdMap,
  omEmpty,
  omInsert,
  omHasKey,
  omDelete,
  omLookup,
  omFromNames,
  omFromPairs,
  omKeys,
  omSize,
  omMapValues,
}
import support.opcount.{opBump}
import support.util.{
  contains,
  editDistance,
  minI,
  maxI,
  listLen,
  escStr,
  joinNl,
  joinWith,
  lookupAssoc,
  reverseL,
  initList,
  joinDot,
  filterList,
  anyList,
  dedup,
  dedupBy,
}

-- ── Errors ──────────────────────────────────────────────────────────────
-- Stage B (WS-4 / F6): every ctor carries a trailing `Option Loc` — the source
-- span of the offending node, paired with the current location as tracked
-- during the walk.  Expression-position errors carry the enclosing `ELoc` span
-- threaded through the walk; decl/build-phase errors with no node in scope carry
-- `None` (rendered as the oracle's dummy {0,0} range / `<unknown location>`).
public export data ResError =
  -- trailing `Option String` = nearest in-scope name suggestion (edit-distance
  -- "did you mean"), None when no candidate is close enough (ERROR-QUALITY §4.1)
  | UnboundVariable String (Option Loc) (Option String)
  -- an unbound name that IS exported by a module the file already `import`s
  -- (bare or selective-but-missing-this-name): name, exporting module id.
  -- Takes priority over the generic edit-distance UnboundVariable suggestion
  -- (audit finding #5) — the fix is "select this name from the import", not a
  -- typo correction, and a fuzzy edit-distance match against an unrelated name
  -- is actively misleading here.
  | UnboundVariableExported String String (Option Loc)
  -- an unbound name that is itself the id of a module this file `import`s
  -- bare (#514): `import string` then a reference to bare `string` — there is
  -- no qualified access for a bare import, so the generic edit-distance
  -- fallback would otherwise grab an unrelated same-case name.  name only;
  -- the message is a static how-to (ERROR-QUALITY: point at the fix, not a
  -- guess).
  | UnboundVariableIsModule String (Option Loc)
  -- trailing `Option String` = suggested constructor name: today ONLY a
  -- curated Haskell-alias exact match (`Just`→`Some`, …; see
  -- `haskellCtorAliases`), None otherwise — there is no general edit-distance
  -- fallback for constructor patterns.
  | UnknownConstructor String (Option Loc) (Option String)
  -- trailing `Option String` = nearest in-scope TYPE name suggestion (same
  -- did-you-mean policy as UnboundVariable, candidates drawn from env.types)
  | UnknownType String (Option Loc) (Option String)
  | UnknownEffect String (Option Loc)
  | UnknownField String (Option Loc)
  | FieldNotInRecord String String (Option Loc)
  | DuplicateDefinition String String (Option Loc)
  | UnknownInterface String (Option Loc)
  | MethodNotInInterface String String (Option Loc)
  | ExternWithBody String (Option Loc)
  -- multi-module path (resolve_module): import validation against real exports
  | PrivateNameAccess String String (Option Loc)
  -- name, owning module
  | NoExportedConstructors String String (Option Loc)
  -- type, owning module (exported abstractly)
  | NewtypeCtorNotExported String String (Option Loc)
  -- member name as written (the type name for `T(..)`, or the ctor name for a
  -- direct `Ctor` import member), owning module.  A `newtype`'s constructor is
  -- unconditionally module-private (no `public newtype` spelling exists), so
  -- unlike NoExportedConstructors there is no `public export` remedy (#1311).
  | AbstractFieldAccess String String (Option Loc)
  -- type name, field name: a record-pattern field on a type whose fields are not
  -- in scope because the type was exported abstractly (`export` without `public`)
  | UnknownModule String (Option Loc)
  -- `import` of a module not among known exports
  -- misplaced surface constructs that survive desugar
  | NonRecursiveValueLet String (Option Loc)
  -- `let x = … x …` (no `rec`) referencing itself
  | DuplicateBinding String (Option Loc)
  -- Phase 148: non-contiguous clauses of a top-level binding
  -- a nullary top-level VALUE binding (`x = e`, no params) defined >=2× — a
  -- genuine duplicate (a value binding admits exactly one clause), unlike a
  -- multi-clause function whose clauses each carry >=1 discriminating pattern
  | DuplicateValueBinding String (Option Loc)
  -- S-2: a top-level name carries >=2 own type signatures (`f : T` written
  -- twice for the same `f`) — the unambiguous discriminator between a
  -- legitimate multi-clause function (exactly ONE signature, N clause bodies)
  -- and two unrelated definitions that happen to share a name (each with its
  -- OWN signature).  Second String = this occurrence's loc (for the
  -- diagnostic's own position); third = the EARLIER signature's loc (so the
  -- message can name where the first definition is).  A duplicate WITHOUT a
  -- repeated signature (both clauses unsignatured) is deliberately NOT
  -- flagged here — see dupSignatureErrors' doc comment for why that is a
  -- distinct, out-of-scope feature (redundant-clause/exhaustiveness
  -- analysis, not name resolution).
  | DuplicateSignature String (Option Loc) (Option Loc)
  -- a variable bound more than once among binders introduced TOGETHER: a
  -- non-linear pattern (`(x, x)`, `Pair x x`) or a repeated parameter (`f x x`,
  -- `x x => …`).  The binder is non-linear → all but one occurrence is silently
  -- dropped (miscompiles).  First String = the noun phrase for the group
  -- ("pattern" / "parameter list"); second = the offending name.
  | DuplicateBinder String String (Option Loc)
  | AsPatternMisplaced (Option Loc)  -- `x@..` outside a binding LHS
  -- name USED unqualified, exported by ≥2 non-`core` modules (use-time
  -- ambiguity; MAP-SET-AMBIGUITY-DESIGN.md)
  | AmbiguousOccurrence String (List String) (Option Loc)
  -- CONSTRUCTOR (in a pattern or an expression) that ≥2 explicitly-imported
  -- non-`core` modules bring into scope under the same name (#674).  The
  -- constructor peer of AmbiguousOccurrence: without it a cross-module duplicate
  -- public ctor was silently resolved by load/import order, and typecheck's
  -- last-loaded-wins vs the native mangler's first-import-wins DISAGREED — check
  -- accepted, run was right, the native build CRASHED.  Fired at the USE site, so
  -- importing both but never using the ctor stays legal.
  | AmbiguousConstructor String (List String) (Option Loc)
  -- TYPE name (in a signature, an annotation, a record pattern head, or a record
  -- literal head) that ≥2 non-`core` imports bring into scope under one spelling
  -- (#1110 Stage A-1).  The TYPE peer of AmbiguousOccurrence, with the identical
  -- trigger: a SCOPE collision.  ⚠️ It therefore says NOTHING about two modules
  -- that declare the same type name and are never imported together — those never
  -- meet in one scope, so no use-site diagnostic can see them (that is A-2's
  -- registry re-keying, not this).  Fired at the USE site, so importing both and
  -- never naming the type stays legal, and a module's OWN declaration settles the
  -- name rather than participating in the ambiguity.
  | AmbiguousType String (List String) (Option Loc)
  -- INTERFACE name (a `=>` predicate, a superinterface, an impl `requires`, or the
  -- interface an `impl` is of) that ≥2 non-`core` imports bring into scope under
  -- one spelling (#1110 Stage A-1).  Same trigger and same limits as
  -- AmbiguousType; separate because interfaces are a SEPARATE NAMESPACE (a file
  -- may declare both `data Foo` and `interface Foo a` and check clean), so the two
  -- ambiguity sets are computed from disjoint export lists and must never be keyed
  -- together.
  | AmbiguousInterface String (List String) (Option Loc)
  -- an internal-only array-kernel extern (arrayGetUnsafe, …) referenced from a
  -- module that is neither in the standard library nor compiled with
  -- `--allow-internal` (see internalExterns / Env.internalGuard)
  | InternalExternAccess String (Option Loc)
  -- beta mutability model (P0-5): a bare reassignment `x = e` of an existing
  -- binding. Bindings are immutable; `=` (without `let`) is not a declaration.
  -- Carries the reassigned name + span. Mutation lives on `Ref`/`:=`.
  | ReassignImmutable String (Option Loc)
  -- Q1 (Stage B / Phase 4b): TWO interfaces declared in ONE module declare the
  -- same METHOD name.  Fields: the method name, the interface that declared it
  -- FIRST, the interface re-declaring it.  Rejected ON DECLARATION, not at an
  -- ambiguous occurrence — see ifaceMethodCollisions for the ruling and its
  -- deliberate narrowing of acceptance.  Location-less by construction:
  -- `DInterface` carries no `Loc` (declLoc sends it to `None`) and `IfaceMethod`
  -- has none either, so there is no span to point at and none is fabricated.
  | DuplicateInterfaceMethod String String String (Option Loc)

-- The did-you-mean pair (misspelled name, suggested name) for a resolve error,
-- or None.  Only an UnboundVariable that carries a suggestion qualifies today.
-- Consumed by diagnostics.mdk (Stage 2) to build the structured `help`/`fix`
-- JSON fields — the fix span is the misspelled name's own loc-start + its length.
export
resErrorDidYouMean : ResError -> Option (String, String)
resErrorDidYouMean (UnboundVariable n _ (Some sug)) = Some (n, sug)
resErrorDidYouMean (UnknownConstructor n _ (Some sug)) = Some (n, sug)
resErrorDidYouMean (UnknownType n _ (Some sug)) = Some (n, sug)
resErrorDidYouMean _ = None

-- The source span carried by a ResError (Stage B): consumed by diagnostics.mdk
-- to position the Diag (was uniformly `None` pre-Stage-B).
export
resErrorLoc : ResError -> Option Loc
resErrorLoc (UnboundVariable _ l _) = l
resErrorLoc (UnboundVariableExported _ _ l) = l
resErrorLoc (UnboundVariableIsModule _ l) = l
resErrorLoc (UnknownConstructor _ l _) = l
resErrorLoc (UnknownType _ l _) = l
resErrorLoc (UnknownEffect _ l) = l
resErrorLoc (UnknownField _ l) = l
resErrorLoc (FieldNotInRecord _ _ l) = l
resErrorLoc (DuplicateDefinition _ _ l) = l
resErrorLoc (UnknownInterface _ l) = l
resErrorLoc (MethodNotInInterface _ _ l) = l
resErrorLoc (ExternWithBody _ l) = l
resErrorLoc (PrivateNameAccess _ _ l) = l
resErrorLoc (NoExportedConstructors _ _ l) = l
resErrorLoc (NewtypeCtorNotExported _ _ l) = l
resErrorLoc (AbstractFieldAccess _ _ l) = l
resErrorLoc (UnknownModule _ l) = l
resErrorLoc (NonRecursiveValueLet _ l) = l
resErrorLoc (DuplicateBinding _ l) = l
resErrorLoc (DuplicateValueBinding _ l) = l
resErrorLoc (DuplicateSignature _ l _) = l
resErrorLoc (DuplicateBinder _ _ l) = l
resErrorLoc (AsPatternMisplaced l) = l
resErrorLoc (AmbiguousOccurrence _ _ l) = l
resErrorLoc (AmbiguousConstructor _ _ l) = l
resErrorLoc (AmbiguousType _ _ l) = l
resErrorLoc (AmbiguousInterface _ _ l) = l
resErrorLoc (InternalExternAccess _ l) = l
resErrorLoc (ReassignImmutable _ l) = l
resErrorLoc (DuplicateInterfaceMethod _ _ _ l) = l

-- ── The name environment ──────────────────────────────────────────────────
-- `values`/`types`/`ctors`/`imported`/`internalGuard` are membership-tested on
-- every non-local variable/constructor/type reference in the program, so they
-- are OrdMap-backed sets (String -> Unit, O(log n) `omHasKey`) rather than
-- `List String` (an O(n) `contains` there made resolve O(refs × decls) —
-- see issue #78). The remaining fields are only ever iterated, never
-- membership-tested, so they stay plain lists.
-- `fieldOwners` is (field, owner) pairs; `ifaceMethods` is (iface, methods).
public export data Env = Env {
    values : OrdMap Unit,
    types : OrdMap Unit,
    ctors : OrdMap Unit,
    fields : List String,
    fieldOwners : List (String, String),
    fieldOwnersIdx : OrdMap (List String),  -- `fieldOwners` indexed by field name (built ONCE, see `buildFieldOwnerIndex`):
    interfaces : List String,  -- field -> its owners in registration order.  `ownersOf` probes this in
    ifaceMethods : List (String, List String),  -- O(log fields) instead of the O(fields) linear scan of `fieldOwners` it used
    effects : List String,  -- to do per field mention — the wide-record resolve quadratic (#984).  The
    imported : OrdMap Unit,  -- plain `fieldOwners` list is kept only for the rare `ownsAnyField` error path.
    importedModuleValues : List (String, List String),
    ambiguous : List (String, List String),
    ctorAmbiguous : List (String, List String),
    typeAmbiguous : List (String, List String),
    ifaceAmbiguous : List (String, List String),
    internalGuard : OrdMap Unit,
    sugValues : List SugCand,  -- the did-you-mean candidate POOLS, materialized ONCE per `Env`
    sugTypes : List SugCand,  -- (see `SugCand`) instead of per unbound name — #1016.
  }  -- imported module (needs a selective import, not a typo fix; audit #5).
-- (modId, expValues) pairs for every non-`core` module this file `import`s
-- (multi-module path only; single-file `buildEnv` leaves this `[]`) — lets
-- #674: CONSTRUCTOR name → its ≥2 explicitly-importing module ids (ctor peer of `ambiguous`)
-- `checkVar` recognize an unbound name that's an export of an ALREADY

-- use-time ambiguity (MAP-SET-AMBIGUITY-DESIGN.md): name → the ≥2 distinct
-- non-`core` module ids that export it unqualified

-- internal-only externs (arrayGetUnsafe, …) that this module is NOT permitted
-- to reference (empty when the module is trusted: a stdlib module, or any
-- module under `--allow-internal`).  checkVar flags a reference to one of these.

-- ── internal-only externs ──────────────────────────────────────────────────
-- Array-kernel primitives declared in stdlib/runtime.mdk that bypass bounds
-- checks / mutate in place.  They are globally in scope (runtime.mdk is the
-- implicit prelude), so a module that is neither part of the standard library
-- nor compiled with `--allow-internal` must not reference them.  Mirrors the
-- hardcoded-set pattern of builtInEffects.  `__fallthrough__` is deliberately
-- EXCLUDED: it is compiler-generated by desugar for guard fallthrough and so
-- legitimately appears in user programs post-desugar.
export
internalExterns : List String
internalExterns = ["arrayGetUnsafe", "arraySetUnsafe", "arrayBlit", "arrayFill", "bytesToFloat64"]

-- The internal-extern guard list for a module given whether internal access is
-- permitted (a trusted module / `--allow-internal`): empty ⇒ no restriction.
export
internalGuardFor : Bool -> List String
internalGuardFor True = []
internalGuardFor False = internalExterns

-- Build the field-name -> owners index from the flat (field, owner) multimap.
-- Owners are PREPENDED per bucket (O(1)) then every bucket is reversed once
-- (`omMapValues reverseL`), so `ownersOf` yields owners in the SAME registration
-- order the old linear `ownersOf field fieldOwners` scan did — the field-ambiguity
-- diagnostics (`FieldNotInRecord`, and `contains owner owners` in `fieldVerdict`)
-- are therefore byte-identical.  Built ONCE per `Env`; #984.
buildFieldOwnerIndex : List (String, String) -> OrdMap (List String)
buildFieldOwnerIndex pairs = omMapValues reverseL (indexOwners pairs omEmpty)

indexOwners : List (String, String) -> OrdMap (List String) -> OrdMap (List String)
indexOwners [] m = m
indexOwners ((f, owner)::rest) m = match omLookup f m
  Some os => indexOwners rest (omInsert f (owner::os) m)
  None => indexOwners rest (omInsert f [owner] m)

-- the owners registered for a field name in the field-owner multimap.
-- O(log fields) index probe (see `buildFieldOwnerIndex`), NOT the per-mention
-- O(fields) scan it used to be (#984).  `opBump` makes this probe VISIBLE to the
-- perf gate's op-count arm (#884): the `widerecords` shape's resolve-op grade now
-- covers `ownersOf` — one counted op per field mention, so the FIXED path reads
-- LINEAR, while a regression that scans (or returns a superlinear owners list)
-- lifts the resolve-op ratio superlinear and the gate goes red (#880).
ownersOf : String -> OrdMap (List String) -> List String
ownersOf field idx =
  let _ = opBump ()
  match omLookup field idx
    Some owners => owners
    None => []

-- ── pat_bindings ──────────────────────────────────────────────────────────
patBindings : Pat -> List String
patBindings (PVar x _) = [x]
patBindings PWild = []
patBindings (PLit _) = []
patBindings (PCon _ ps) = flatMap patBindings ps
patBindings (PCons a b) = patBindings a ++ patBindings b
patBindings (PTuple ps) = flatMap patBindings ps
patBindings (PList ps) = flatMap patBindings ps
patBindings (PAs x _ p) = x :: patBindings p
patBindings (PRng _ _ _) = []
patBindings (PRec _ fields _) = flatMap recFieldBindings fields

recFieldBindings : RecPatField -> List String
recFieldBindings (RecPatField fname _ None) = [fname]
recFieldBindings (RecPatField _ _ (Some p)) = patBindings p

patsBindings : List Pat -> List String
patsBindings ps = flatMap patBindings ps

-- Non-linearity check for a group of binders introduced TOGETHER — a single
-- match/let/do pattern (`(x, x)`, `Pair x x`) or a parameter list (`f x x`,
-- `x x => …`).  The language binds each variable exactly once; a repeat is not
-- shadowing (these binders share one scope) but a silent drop — `(x, x)` binds
-- only the FIRST component → runtime garbage.  `findDups` yields each repeated
-- name once (keyed on the 2nd occurrence).  Patterns carry no own Loc, so the
-- error is positioned at the enclosing clause/expr span `loc`.  `kind` is the
-- group's noun phrase ("pattern" / "parameter list").
patGroupDupErrors : Option Loc -> String -> List Pat -> List ResError
patGroupDupErrors loc kind ps =
  map (n => DuplicateBinder kind n loc) (findDups [] (patsBindings ps))

-- ── check_type ────────────────────────────────────────────────────────────
-- `cur` (Stage B) is the enclosing `ELoc` span threaded from the expr walk (or
-- `None` at decl level).
checkType : Option Loc -> Env -> Ty -> List ResError
checkType cur env (TyCon { tyConName = n, tyConLoc = loc }) =
  if omHasKey n env.types || omHasKey n env.imported || isTupleCtorTyName n then
    -- in scope — but a cross-module duplicate TYPE name (≥2 explicitly-importing
    -- modules) is AMBIGUOUS at this use site (#1110); a type declared in THIS
    -- module is excluded from `typeAmbiguous`, so this only fires on a genuine
    -- import collision.  Exactly the ctor peer's guard in `checkPat`'s PCon arm.
    ambiguousTypeErrors env n (orElseLoc loc cur)
  else
    [UnknownType n (orElseLoc loc cur) (suggestType env n)]
checkType _ _ (TyVar _) = []
-- (helper below `checkType`) — accept the bare tuple type constructors
-- `(,)`…`(,,,,)` (which the parser lowers to `TyCon "__tupleN__"`, arities 2–5)
-- as known type names WITHOUT adding them to `env.types`/`primitiveTypes`: those
-- feed the emitter's per-head default-method enumeration, and a spurious
-- `__tupleN__` head there makes it try to emit a `Bimappable` default at a tuple
-- with no `bimap` impl.  Kept in sync with the parser's `tupleCtorTyName` and
-- typecheck's `tupleHeadTagTc`.
checkType cur env (TyApp a b) = checkType cur env a ++ checkType cur env b
checkType cur env (TyFun a b) = checkType cur env a ++ checkType cur env b
checkType cur env (TyTuple ts) = flatMap (checkType cur env) ts
checkType cur env (TyEffect labels _ t) = flatMap (checkEffect cur env) (map fst labels)
  ++ checkType cur env t
-- ⚠️ The predicates are checked with `cur` WIDENED by the constrained type's own
-- first span, not with the bare `cur`.  A `Constraint` carries no `Loc` (see
-- `ambiguousIfaceErrors`), and at DECL level `cur` is `None`, so `f : Speak a =>
-- a -> String` had no span anywhere for an interface-position diagnostic to use —
-- the constrained body does, one token away.  `cur` still wins where it exists (it
-- is the nearer enclosing span, from an `EAnnot` inside a body).  This also
-- narrows the pre-existing `UnknownInterface` at this site from `<unknown
-- location>` to the signature it was written in.
checkType cur env (TyConstrained cs t) = flatMap (checkConstraint (orElseLoc cur (firstTyLoc t)) env) cs
  ++ checkType cur env t
-- A bare row atom (#997) wraps no inner type, but its labels are the same
-- written effect labels a `TyEffect` carries — validate them the same way.
checkType cur env (TyRow labels _ _) =
  flatMap (checkEffect cur env) (map fst labels)

builtInEffects : List String
builtInEffects = [
  "IO",
  "Rand",
  "Stdout",
  "Stderr",
  "Stdin",
  "Clock",
  "Env",
  "Exec",
  "Net",
  "FileRead",
  "FileWrite",
  "FFI",
]

checkEffect : Option Loc -> Env -> String -> List ResError
checkEffect cur env e =
  if contains e builtInEffects || contains e env.effects then
    []
  else
    [UnknownEffect e cur]

-- The three type-occurrence sites (`checkType`'s `TyCon` arm, `recPatHead`,
-- `recCreateHead`) share this so the ambiguity verdict cannot differ between a type
-- written in a signature and the same type written as a pattern or literal head —
-- diagnostic visibility is a SET over the positions a name can be written in, and
-- three copies of a guard is how one of them silently loses it.
ambiguousTypeErrors : Env -> String -> Option Loc -> List ResError
ambiguousTypeErrors env n loc =
  whenL (isTypeAmbiguous env n) [AmbiguousType n (typeAmbigMods env n) loc]

-- The CONSTRUCTOR peer, shared by the three constructor-occurrence positions
-- (`checkPat`'s `PCon` arm, `recPatHead`, `recCreateHead`) for exactly the reason stated
-- above: diagnostic visibility is a SET over the positions a name can be written in, and
-- N copies of a guard is how one of them silently loses it.
--
-- 🚨 #1253 (S0) IS PRECISELY THAT LOSS.  The positional form `MkT 1` routed through
-- `PCon`/`checkExpr` and was rejected; the RECORD form `MkT { fx = 1 }` routes through
-- `recPatHead` / `recCreateHead`, which consulted only the TYPE peer — and `typeAmbiguous`
-- is keyed by type NAMES, so for a constructor-only head (`data TA = MkT { fx : Int }`
-- declares no type `MkT`) it could not fire at all.  Two modules each declaring `MkT`,
-- both imported, therefore compiled at exit 0 with NO diagnostic and the winner decided by
-- import-clause ORDER — a silently different impl for a cosmetic edit.
--
-- ⚠️ NO `scopeMem` GUARD, matching `checkPat`'s `PCon` arm and unlike `checkExpr`'s
-- variable arm.  A record head is a type-or-constructor spelling in a syntactic position
-- where a local binder cannot appear, so there is nothing for a scope test to exclude and
-- neither of these two callers even receives the `Scope`.
ambiguousCtorErrors : Env -> String -> Option Loc -> List ResError
ambiguousCtorErrors env n loc = whenL
  (isCtorAmbiguous env n)
  [AmbiguousConstructor n (ctorAmbigMods env n) loc]

-- ── the RECORD-HEAD verdict: exactly ONE of the two peers ──────────────────
-- A record head (`recPatHead` / `recCreateHead`) may be spelled either way — a TYPE
-- name, or a constructor-only name — so it must consult both sets.  It gets ONE
-- verdict, not the concatenation, and the reason is that for the common record shape
-- the two peers describe THE SAME COLLISION: `data Crate = { crateSz : Int }` declares
-- a type `Crate` AND a sole variant `Crate`, so two modules declaring it put the name
-- in BOTH ambiguity sets and concatenating reports one collision twice.  Emitting a
-- duplicate diagnostic where one was emitted before would be a diagnostic-quality
-- regression riding along with a soundness fix; measured on
-- `test/resolve_module_fixtures/ambiguous_type_iface`, whose `t_recpat` / `t_reclit`
-- cells are exactly that shape.
--
-- TYPE FIRST because it is the more specific reading of a head that IS a type name;
-- the constructor peer is the fallback that reaches the constructor-only spelling
-- `typeAmbiguous` is structurally unable to see (#1253).
ambiguousHeadErrors : Env -> String -> Option Loc -> List ResError
ambiguousHeadErrors env n loc = match ambiguousTypeErrors env n loc
  [] => ambiguousCtorErrors env n loc
  es => es

-- The interface peer, shared by all four interface-occurrence positions.
--
-- 🚨 LOCATING AN INTERFACE OCCURRENCE IS BEST-EFFORT, AND THE RESIDUAL IS
-- STRUCTURAL — none of the four occurrence carriers (`Constraint`, `Super`,
-- `Require`, `DImpl.iface`) carries a `Loc`, so there is no span for the head
-- itself anywhere in the AST.  What each caller passes is the nearest real span it
-- can reach, in this order: the `Ty`s written beside the head (`firstTyLocList`),
-- then the enclosing expression span, then — for a `=>` predicate — the constrained
-- type's own first span (`checkType`'s `TyConstrained` arm).
--
-- Two residuals survive that chain, both pre-existing and both shared with the
-- sibling `UnknownInterface` at the same site:
--   * `checkSuper` — `Super` carries `superParams : List String` (type-parameter
--     NAMES, not `Ty`s), so it has NO `Ty` position at all and nothing to borrow.
--   * a predicate whose every type is a variable AND whose constrained body is too
--     (`f : Speak a => a -> a`) — there is no `Loc` in that signature to find.
-- Both are fixed by giving these nodes a `Loc`, which is an AST carrier change and
-- not this unit's.  Reporting them unlocated beats not reporting them: each IS a
-- use site, and silence there is the strictly worse failure.
--
-- The `Require` / `DImpl.iface` locators are a strict IMPROVEMENT on their
-- co-located `UnknownInterface`, which passes a literal `None`.
ambiguousIfaceErrors : Env -> String -> Option Loc -> List ResError
ambiguousIfaceErrors env n loc = whenL
  (isIfaceAmbiguous env n)
  [AmbiguousInterface n (ifaceAmbigMods env n) loc]

checkConstraint : Option Loc -> Env -> Constraint -> List ResError
checkConstraint cur env (Constraint { constraintHead = iface, constraintArgs = args }) = (if contains iface env.interfaces then ambiguousIfaceErrors env iface (orElseLoc (firstTyLocList args) cur) else [UnknownInterface iface cur]) ++ flatMap (checkType cur env) args

-- ── check_pat ─────────────────────────────────────────────────────────────
checkPat : Option Loc -> Env -> Pat -> List ResError
checkPat cur env (PCon c ps) = (if omHasKey c env.ctors || omHasKey c env.imported then
    -- in scope — but a cross-module duplicate ctor (≥2 explicitly-importing
    -- modules) is AMBIGUOUS at this use site (#674); local ctors are excluded
    -- from ctorAmbiguous, so this only fires on a genuine import collision.
    ambiguousCtorErrors env c cur
  else [UnknownConstructor c cur (suggestCtor c)])
  ++ flatMap (checkPat cur env) ps
checkPat cur env (PCons a b) = checkPat cur env a ++ checkPat cur env b
checkPat cur env (PTuple ps) = flatMap (checkPat cur env) ps
checkPat cur env (PList ps) = flatMap (checkPat cur env) ps
checkPat cur env (PAs _ _ p) = checkPat cur env p
checkPat cur env (PRec name fields _) = checkRecPat cur env name fields
checkPat _ _ _ = []

checkRecPat : Option Loc -> Env -> String -> List RecPatField -> List ResError
checkRecPat cur env name fields = recPatHead cur env name
  ++ flatMap (checkRecField cur env name) fields

recPatHead : Option Loc -> Env -> String -> List ResError
recPatHead cur env name =
  if omHasKey name env.types || omHasKey name env.ctors then
    -- #1110: a record PATTERN head names a TYPE **or one of its CONSTRUCTORS** —
    -- which is what the `|| omHasKey name env.ctors` on the line above is for
    -- (`data T = MkT { fx : Int }` gives the head `MkT`, a ctor spelling with no
    -- type of that name).  `checkPat` routes `PRec` here rather than through its
    -- `PCon` arm, so neither ambiguity peer sees this position by default.
    --
    -- Both SETS are consulted, and exactly ONE verdict comes back — `typeAmbiguous`
    -- is keyed by type names and says nothing about a ctor-only head like `MkT`,
    -- `ctorAmbiguous` is keyed by constructor names.  Consulting only the first is
    -- #1253; concatenating them double-reports the ordinary record shape.  See
    -- `ambiguousHeadErrors`, which owns both halves of that story.
    ambiguousHeadErrors env name cur
  else
    [UnknownType name cur (suggestType env name)]

checkRecField : Option Loc -> Env -> String -> RecPatField -> List ResError
checkRecField cur env owner (RecPatField fname _ popt) = fieldCheck cur env owner fname
  ++ recFieldSub cur env popt

fieldCheck : Option Loc -> Env -> String -> String -> List ResError
fieldCheck cur env owner fname =
  let owners = ownersOf fname env.fieldOwnersIdx
  fieldVerdict cur env owner fname owners

-- No record in scope declares `fname`.  If the pattern head `owner` IS a known
-- type (it resolved past recPatHead) yet owns NO fields at all, its fields were
-- never registered — the only way a local record/named-field-variant reaches here
-- with zero owners is that it was exported abstractly (`export` without `public`),
-- whereas a local definition always registers its fields.  Distinguish that case
-- from a genuinely-unknown field with a clearer message.
fieldVerdict : Option Loc -> Env -> String -> String -> List String -> List ResError
fieldVerdict cur env owner fname [] =
  if omHasKey owner env.types && not (ownsAnyField owner env.fieldOwners) then
    [AbstractFieldAccess owner fname cur]
  else
    [UnknownField fname cur]
fieldVerdict cur env owner fname owners =
  if contains owner owners then
    []
  else
    [FieldNotInRecord fname owner cur]

-- does `owner` own ANY field in the field-owner multimap?
ownsAnyField : String -> List (String, String) -> Bool
ownsAnyField _ [] = False
ownsAnyField owner ((_, o)::rest)
  | o == owner = True
  | otherwise = ownsAnyField owner rest

recFieldSub : Option Loc -> Env -> Option Pat -> List ResError
recFieldSub _ _ None = []
recFieldSub cur env (Some p) = checkPat cur env p

-- ── the lexical scope of locally-bound value names ─────────────────────────
-- The walk membership-tests `scope` on EVERY variable reference (checkVar /
-- lookupValue), and a reference to a NON-local name — every top-level function
-- call, for one — scans it to completion (never matching) before falling
-- through to env.values.  As a bare `List String` (an O(scope) `contains`) that
-- made resolve O(references × scope-size): issue #78 P-1's residual quadratic,
-- the peer of the env.values→OrdMap fix above.  So `Scope` carries BOTH:
--   * `names` — the binding-order list (duplicates and all), consumed ONLY by
--     suggestName's did-you-mean, which tries local names first.  Preserved
--     verbatim so suggestions stay byte-identical.
--   * `mem`   — the O(log n) membership set (`omHasKey`), which every
--     `contains n scope` now consults instead.  (`omHasKey` also does not bump
--     the perf op-counter the way `contains` does, so the #78 scan drops off
--     the OP arm of diff_compiler_perf_scaling.sh too — see its `scoperefs` shape.)
data Scope = Scope (List String) (OrdMap Unit)

emptyScope : Scope
emptyScope = Scope [] omEmpty

-- build a scope from a flat list of just-bound names (decl-level / initial scopes)
mkScope : List String -> Scope
mkScope ns = Scope ns (omFromNames ns omEmpty)

-- the in-scope names in binding order (most-recent first), for suggestion ranking
scopeNames : Scope -> List String
scopeNames (Scope ns _) = ns

-- O(log n) membership — the replacement for `contains n scope`
scopeMem : String -> Scope -> Bool
scopeMem n (Scope _ mem) = omHasKey n mem

-- extend with newly-bound names (prepend, mirroring the old `ns ++ scope`)
scopeExtend : List String -> Scope -> Scope
scopeExtend ns (Scope names mem) = Scope (ns ++ names) (omFromNames ns mem)

-- extend with a single name (mirroring the old `n :: scope`)
scopeAdd : String -> Scope -> Scope
scopeAdd n (Scope names mem) = Scope (n::names) (omInsert n () mem)

-- ── check_expr (scope = locally-bound names) ──────────────────────────────
-- `cur` (Stage B): the innermost enclosing `ELoc` span, threaded so every error
-- emitted while walking the expr carries that span, set by the `ELoc` arm
-- below.  `None` until the first ELoc.
checkExpr : Option Loc -> Env -> Scope -> Expr -> List ResError
checkExpr _ _ _ (ELit _) = []
checkExpr _ _ _ (ENumLit _ _ _ _) = []  -- PLAN.md #11: a literal, nothing to bind
checkExpr _ _ _ (EMethodRef _) = []
checkExpr _ _ _ (EDictApp _) = []
-- EVarAt/EMethodAt/EDictAt are elaborated nodes introduced by annotateProgram /
-- typecheck AFTER resolve; checkExpr's input is the desugared pre-resolve AST, so
-- these arms are unreachable.
checkExpr _ _ _ (EVarAt _ _) =
  panic "unreachable: EVarAt is introduced by annotateProgram after resolve"
checkExpr _ _ _ (EMethodAt _ _ _ _) =
  panic
    "unreachable: EMethodAt is introduced by typecheck elaboration after resolve"
checkExpr _ _ _ (EDictAt _ _) =
  panic
    "unreachable: EDictAt is introduced by typecheck elaboration after resolve"
checkExpr cur env scope (EVar n) = checkVar cur env scope n
checkExpr cur env scope (EApp f x) = checkExpr cur env scope f
  ++ checkExpr cur env scope x
checkExpr cur env scope (ELam pats body) = flatMap (checkPat cur env) pats
  ++ patGroupDupErrors cur "parameter list" pats
  ++ checkExpr cur env (scopeExtend (patsBindings pats) scope) body
checkExpr cur env scope (ELet _ isRec pat e1 e2) =
  checkLet cur env scope isRec pat e1 e2
checkExpr cur env scope (ELetGroup binds body) =
  checkLetGroup cur env scope binds body
checkExpr cur env scope (EMatch e0 arms) = checkExpr cur env scope e0
  ++ flatMap (checkArm cur env scope) arms
checkExpr cur env scope (EIf c t el) = checkExpr cur env scope c
  ++ checkExpr cur env scope t
  ++ checkExpr cur env scope el
checkExpr cur env scope (EBinOp _ a b _) = checkExpr cur env scope a
  ++ checkExpr cur env scope b
checkExpr cur env scope (EUnOp _ a _) = checkExpr cur env scope a
checkExpr cur env scope (EInfix op a b) = checkVar cur env scope op
  ++ checkExpr cur env scope a
  ++ checkExpr cur env scope b
checkExpr cur env scope (EFieldAccess e0 _ _) = checkExpr cur env scope e0
-- EMapLit/ESetLit are lowered to `fromEntries …` by desugar's
-- lowerContainerLiterals BEFORE resolve runs, so these arms are unreachable.
checkExpr _ _ _ (EMapLit _ _) =
  panic
    "unreachable: EMapLit is lowered to fromEntries by desugar before resolve"
checkExpr _ _ _ (ESetLit _ _) =
  panic
    "unreachable: ESetLit is lowered to fromEntries by desugar before resolve"
checkExpr cur env scope (ETuple es) = flatMap (checkExpr cur env scope) es
checkExpr cur env scope (EListLit es) = flatMap (checkExpr cur env scope) es
checkExpr cur env scope (EArrayLit es) = flatMap (checkExpr cur env scope) es
checkExpr cur env scope (ERangeList lo hi _) = checkExpr cur env scope lo
  ++ checkExpr cur env scope hi
checkExpr cur env scope (ERangeArray lo hi _) = checkExpr cur env scope lo
  ++ checkExpr cur env scope hi
checkExpr cur env scope (ESlice e0 lo hi _ _) = checkExpr cur env scope e0
  ++ checkExpr cur env scope lo
  ++ checkExpr cur env scope hi
checkExpr cur env scope (EIndex e0 i _) = checkExpr cur env scope e0
  ++ checkExpr cur env scope i
checkExpr cur env scope (EAnnot e0 t) = checkExpr cur env scope e0
  ++ checkType cur env t
-- EHeadAnnot is the synthetic `:~` head-pin desugar emits for Map/Set literals
-- (`fromEntries [...] :~ Map _k _v`).  The container type (Map/Set/…) is a real
-- type, so validate it like EAnnot via checkType — except the multi-module env
-- already carries imported types so an `import map`-bearing program resolves
-- `Map`, while a bare `Map { … }` with no import resolves to UnknownType — both
-- are accepted here without a resolve error (Phase 108).
checkExpr cur env scope (EHeadAnnot e0 t) = checkExpr cur env scope e0
  ++ checkType cur env t
checkExpr cur env scope (EBlock stmts) = checkStmts cur env scope stmts
checkExpr cur env scope (EDo _ stmts) = checkStmts cur env scope stmts
checkExpr cur env scope (EStringInterp parts) =
  flatMap (checkInterp cur env scope) parts
checkExpr cur env scope (EGuards arms) =
  flatMap (checkGuardArm cur env scope) arms
checkExpr cur env scope (ERecordCreate name fs) =
  checkRecordCreate cur env scope name fs
checkExpr cur env scope (ERecordUpdate e0 fs _) =
  checkRecordUpdate cur env scope e0 fs
checkExpr cur env scope (EVariantUpdate con e0 fs) = checkExpr cur env scope e0
  ++ checkRecordCreate cur env scope con fs
checkExpr cur env scope (EAsPat _ e0) =
  AsPatternMisplaced cur :: checkExpr cur env scope e0
checkExpr cur env scope (ESection s) = checkSection cur env scope s
-- ELoc captures its span into `cur` (Stage B), then recurses — so any error in
-- the wrapped subtree is attributed to this span.
checkExpr _ env scope (ELoc l e) = checkExpr (Some l) env scope e
checkExpr cur env scope (EDoOrigin _ e) = checkExpr cur env scope e

-- an `@Name` impl hint is not a value reference (resolve must not flag it)
checkVar : Option Loc -> Env -> Scope -> String -> List ResError
checkVar cur env scope n
  | isHint n = []
  -- internal-only extern referenced (and not locally shadowed) from an
  -- untrusted module ⇒ compile error (see internalExterns / Env.internalGuard).
  | not (scopeMem n scope) && omHasKey n env.internalGuard =
    [InternalExternAccess n cur]
  | not (lookupValue env scope n) = unboundVarErrors cur env scope n
  -- use-time ambiguity: resolves, not shadowed by a local, exported by ≥2
  -- non-core modules (same-module top-levels already excluded from the set).
  | not (scopeMem n scope) && isAmbiguous env n =
    [AmbiguousOccurrence n (ambigMods env n) cur]
  -- a CONSTRUCTOR used as an expression, brought in by ≥2 explicitly-importing
  -- modules under one name (#674) — the expression peer of checkPat's PCon arm.
  | not (scopeMem n scope) && isCtorAmbiguous env n =
    ambiguousCtorErrors env n cur
  | otherwise = []

-- The errors for a name that failed `lookupValue`: if it's exported by an
-- already-imported module (audit #5 — the user needs a selective import, not
-- a typo fix), report that specifically; otherwise fall back to the generic
-- edit-distance/Haskell-alias UnboundVariable suggestion.
unboundVarErrors : Option Loc -> Env -> Scope -> String -> List ResError
unboundVarErrors cur env scope n = match modulesExportingName env n
  m::_ => [UnboundVariableExported n m cur]
  [] =>
    if isImportedModuleName env n then
      [UnboundVariableIsModule n cur]
    else
      [UnboundVariable n cur (suggestName env scope n)]

-- module ids (of modules this file already imports) that export `n` as a
-- value — deliberately NOT scope/local-shadow aware, since `unboundVarErrors`
-- only reaches this after `lookupValue` already failed (so `n` cannot be a
-- shadowed local).
modulesExportingName : Env -> String -> List String
modulesExportingName env n = flatMap (matchesExport n) env.importedModuleValues

matchesExport : String -> (String, List String) -> List String
matchesExport n (mid, vals) = if contains n vals then [mid] else []

-- is `n` itself the module id of something this file `import`s (#514) —
-- e.g. `import string` then a bare reference to `string`.  Checked only
-- after `modulesExportingName` already failed, so `n` is not a value any
-- imported module exports.
isImportedModuleName : Env -> String -> Bool
isImportedModuleName env n = anyList (isModId n) env.importedModuleValues

isModId : String -> (String, List String) -> Bool
isModId n (mid, _) = mid == n

isAmbiguous : Env -> String -> Bool
isAmbiguous env n = match lookupAssoc n env.ambiguous
  Some _ => True
  None => False

ambigMods : Env -> String -> List String
ambigMods env n = match lookupAssoc n env.ambiguous
  Some mods => mods
  None => []

-- constructor peer of isAmbiguous/ambigMods (#674): is this ctor name brought in
-- by ≥2 explicitly-importing modules?
isCtorAmbiguous : Env -> String -> Bool
isCtorAmbiguous env n = match lookupAssoc n env.ctorAmbiguous
  Some _ => True
  None => False

ctorAmbigMods : Env -> String -> List String
ctorAmbigMods env n = match lookupAssoc n env.ctorAmbiguous
  Some mods => mods
  None => []

-- TYPE peer of isAmbiguous/ambigMods (#1110): is this TYPE name brought into scope
-- by ≥2 explicitly-importing modules?  Read at every type-occurrence site — a
-- `TyCon` head, a record-pattern head, a record-literal head.
isTypeAmbiguous : Env -> String -> Bool
isTypeAmbiguous env n = match lookupAssoc n env.typeAmbiguous
  Some _ => True
  None => False

typeAmbigMods : Env -> String -> List String
typeAmbigMods env n = match lookupAssoc n env.typeAmbiguous
  Some mods => mods
  None => []

-- INTERFACE peer.  A SEPARATE lookup over a SEPARATE set rather than a tag on the
-- type one: `typeAmbiguous` is keyed by bare name, and an interface `Foo` and a
-- type `Foo` are two different declarations that may legally coexist in one file —
-- so one shared table would grade them against each other, the collision
-- `tyOriginScope`'s `ifaceKey` tag exists to prevent.  Two tables get the same
-- separation with no key encoding at all, because nothing here is threaded through
-- a signature the way that map is.
--
-- ⚠️ THAT SEPARATION HAS A WITNESS ALREADY IN THE TREE, and it is a better one than
-- anything #1110 added: `test/references_fixtures/iface_ty_collide/main.mdk`
-- (#1044) does `import a.{Foo, mfoo}` then `import b.{Foo}` where a's `Foo` is an
-- INTERFACE and b's is a `data`.  Under one shared bare-name table that is two
-- provenances for `Foo` and a spurious ambiguity error on a file that is correct;
-- under two tables each set sees exactly one and it checks clean — measured, exit
-- 0.  That fixture predates this change and would go red if the tables were ever
-- merged, which is precisely what makes it the regression test for this decision.
isIfaceAmbiguous : Env -> String -> Bool
isIfaceAmbiguous env n = match lookupAssoc n env.ifaceAmbiguous
  Some _ => True
  None => False

ifaceAmbigMods : Env -> String -> List String
ifaceAmbigMods env n = match lookupAssoc n env.ifaceAmbiguous
  Some mods => mods
  None => []

isHint : String -> Bool
isHint n = startsWithAt (stringToChars n)

startsWithAt : Array Char -> Bool
-- Intentional cross-file duplicate of the same helper in annotate.mdk; not consolidating (tiny helper / divergent-by-design backend pair).
-- lint-disable-next-line rule-duplicate-body
startsWithAt cs = arrayLength cs > 0 && arrayGetUnsafe 0 cs == '@'

lookupValue : Env -> Scope -> String -> Bool
lookupValue env scope n = scopeMem n scope
  || omHasKey n env.values
  || omHasKey n env.ctors
  || omHasKey n env.imported

-- "did you mean" for an unbound name: the nearest in-scope value name by
-- Levenshtein distance (ERROR-QUALITY §4.1).  Suggest only when the distance is
-- small absolutely (≤ 2) AND small relative to the name length (≤ max(1, len/3)).
-- Names shorter than 3 chars never suggest: a 1-2 char name sits within edit
-- distance 1 of many unrelated short names (`x` → `e`), which is pure noise.
-- Ties break lexicographically.  Local (`scope`) names are tried first so a
-- mistyped local outranks an equidistant prelude name (a local typo most likely
-- meant a local).
-- ── Curated Haskell→Medaka alias tables (ERROR-QUALITY F-dimension) ───────
-- LLMs are trained heavily on Haskell and reflexively reach for Haskell names
-- that Medaka deliberately renamed.  When an unbound/unknown name EXACTLY
-- matches one of these, the `suggest*` functions below surface the Medaka
-- equivalent with priority over the generic edit-distance did-you-mean: an
-- exact foreign-name match is higher-confidence than a fuzzy same-language
-- one (and often wins where edit distance wouldn't even fire — `fmap`→`map`
-- is edit-distance 2 on a 4-char word).  One table per namespace, kept
-- together here rather than scattered by call site.
haskellTypeAliases : List (String, String)
haskellTypeAliases = [
  ("Functor", "Mappable"),
  ("Monad", "Thenable"),
  ("Maybe", "Option"),
  ("Either", "Result"),
]

haskellValueAliases : List (String, String)
haskellValueAliases = [
  ("fmap", "map"),
  ("return", "pure"),
  ("show", "debug"),
  ("mappend", "append"),
  ("mempty", "empty"),
  ("foldr", "foldRight"),
  ("foldl", "fold"),
  ("error", "panic"),
  ("undefined", "panic"),
]

haskellCtorAliases : List (String, String)
haskellCtorAliases =
  [("Just", "Some"), ("Nothing", "None"), ("Left", "Err"), ("Right", "Ok")]

-- Was `sug` produced by looking `bad` up in one of the three alias tables
-- above (as opposed to falling out of generic edit-distance search)?  Used by
-- `ppResError` to decide whether to append the "(… is Haskell …)" note.
isHaskellAliasPair : String -> String -> Bool
isHaskellAliasPair bad sug = optStrEq (lookupAssoc bad haskellTypeAliases) sug
  || optStrEq (lookupAssoc bad haskellValueAliases) sug
  || optStrEq (lookupAssoc bad haskellCtorAliases) sug

optStrEq : Option String -> String -> Bool
optStrEq (Some x) sug = x == sug
optStrEq None _ = False

-- The CLI-text parenthetical appended after a did-you-mean hint when it came
-- from a curated Haskell alias, e.g. "('fmap' is Haskell; Medaka uses
-- 'map')".  Empty string (no-op append) when the hint is a plain
-- edit-distance suggestion.
haskellNote : String -> String -> String
haskellNote bad sug =
  if isHaskellAliasPair bad sug then
    " ('\{bad}' is Haskell; Medaka uses '\{sug}')"
  else
    ""

-- "did you mean" for an unbound name: an exact curated Haskell-alias match
-- takes priority; otherwise the nearest in-scope value name by Levenshtein
-- distance (ERROR-QUALITY §4.1).  Suggest only when the distance is small
-- absolutely (≤ 2) AND small relative to the name length (≤ max(1, len/3)).
-- Names shorter than 3 chars never suggest: a 1-2 char name sits within edit
-- distance 1 of many unrelated short names (`x` → `e`), which is pure noise.
-- Ties break lexicographically.  Local (`scope`) names are tried first so a
-- mistyped local outranks an equidistant prelude name (a local typo most likely
-- meant a local).
suggestName : Env -> Scope -> String -> Option String
suggestName env scope n = match lookupAssoc n (haskellValueAliases ++ haskellCtorAliases)
  Some sug => Some sug
  None => suggestNameFuzzy env scope n

suggestNameFuzzy : Env -> Scope -> String -> Option String
suggestNameFuzzy env scope n
  | stringLength n < 3 = None
  | otherwise =
    let q = sugQueryOf n
    match bestOfNames q (scopeNames scope)
      Some best => Some best
      None => bestOfPool q env.sugValues

-- "did you mean" for an unknown TYPE name: an exact curated Haskell-alias
-- match takes priority; otherwise same policy as `suggestName` (nearest by
-- edit distance, ≤ min(2, len/3), names shorter than 3 chars never suggest),
-- candidates drawn from the in-scope type names (builtins + user
-- `data`/`type`/`record` + imported) rather than value names.
suggestType : Env -> String -> Option String
suggestType env n = match lookupAssoc n haskellTypeAliases
  Some sug => Some sug
  None => suggestTypeFuzzy env n

suggestTypeFuzzy : Env -> String -> Option String
suggestTypeFuzzy env n
  | stringLength n < 3 = None
  | otherwise = bestOfPool (sugQueryOf n) env.sugTypes

-- "did you mean" for an unknown CONSTRUCTOR (pattern position): today ONLY an
-- exact curated Haskell-alias match (e.g. `Just`→`Some`) — there is no
-- general edit-distance fallback for constructors yet.
suggestCtor : String -> Option String
suggestCtor n = lookupAssoc n haskellCtorAliases

-- ── the did-you-mean candidate pool (#1016) ───────────────────────────────
-- `suggestNameFuzzy` used to rebuild `omKeys env.values ++ omKeys env.ctors ++
-- omKeys env.imported` and run the O(len²) allocating Levenshtein DP against
-- EVERY key of it, once per unbound name — O(unbound × in-scope) on the
-- diagnostics path the LSP recomputes on every keystroke (#1016: 19.3 s to
-- check a file with 1000 typos that takes 0.81 s once they are defined).
--
-- The pool is now materialized ONCE per `Env` (`sugValues` / `sugTypes` — the
-- same once-per-Env discipline as `fieldOwnersIdx`), and every entry carries
-- precomputed keys for O(1), ALLOCATION-FREE prefilters that reject a candidate
-- WITHOUT running the DP at all:
--
--   * `len` — PROOF: `ed a b = d` means some sequence of `d` operations turns
--     `a` into `b`, and each operation changes the length by at most one
--     (insert +1, delete -1, substitute 0), so `|len a - len b| <= d`.  A
--     candidate whose length is outside `[len n - lim, len n + lim]` therefore
--     has `ed > lim` and would have been discarded anyway.
--   * `mask` — bit `hashChar c & 31` set for each character `c` of the name.
--     PROOF, in two steps.  (1) `ed a b <= k` implies the character SETS differ
--     in at most `2k` members: along the optimal edit path `a = x0 -> … -> xd = b`
--     (`d <= k`), one operation changes the set by at most one addition and one
--     removal, so `|S(x i-1) Δ S(x i)| <= 2`, and symmetric difference obeys the
--     triangle inequality, giving `|S a Δ S b| <= 2d <= 2k`.  (2) For ANY slot
--     map `p`, `|M a Δ M b| <= |S a Δ S b|` where `M x = { p c | c in S x }`: if
--     bit `j` is in `M a` but not `M b` then some `c in S a` has `p c = j` and
--     nothing in `S b` maps to `j`, so `c` is in `S a \ S b`; distinct such bits
--     have distinct `p`-values hence distinct witnesses, so the witness map is
--     injective (symmetrically for `M b \ M a`).  Composing: more than `2k`
--     differing mask bits implies `ed > k`.  `bitsAtMost` tests that in O(k)
--     with k <= 4.  Step (2) holds for any `p`, so slot COLLISIONS cannot break
--     the filter — they only shrink the left-hand side, making it strictly more
--     conservative.  The filter therefore does not depend on `hashChar` agreeing
--     across engines, only on it being deterministic within one.
--     THREE independent 32-slot projections of the same character set are kept
--     (hash bits [0,5), [5,10), [10,15)) and ALL THREE must pass.  The bound
--     above holds for ANY projection of the set, so each is exactly as sound.
--     Three, not one, because a 32-slot mask is coarser than it looks: `a`-`z`
--     alone collides down to 15-18 DISTINCT slots (measured, per projection —
--     plain birthday collisions), so one mask on a realistic 8-12 character
--     identifier saturates and admits a large slice of the pool.  Mean
--     Levenshtein scorings per unbound name on the perf gate's `typos` shape at
--     N=1000 (pool 2373): one mask 207, two 71, three 58.  The 2→3 gain is
--     small, which is the signal to stop adding projections: what survives is
--     converging on the IRREDUCIBLE set — candidates whose character sets really
--     do differ by ≤ 2k — and no projection of that set can reject those.  This
--     residue is a LINEAR cost (it is dominated by the fixed prelude, not by the
--     program's own names), so it does not restore the quadratic.
--
--   * `up` — does the name start uppercase.  Not a distance filter: it is the
--     pre-existing `sameCaseClass` reject (see `startsUpper`), precomputed
--     because deriving it needs `stringSlice`, which ALLOCATES.  Re-deriving it
--     per candidate per unbound name is itself an O(unbound × in-scope)
--     ALLOCATION, so leaving it out defeats the whole rewrite (measured: it alone
--     kept resolve allocation quadratic after the pool was hoisted).
--
-- Both distance filters are ONE-SIDED: they can only reject candidates whose
-- distance already exceeds `lim`, which `scoreCand` discards anyway.  The
-- candidate set that reaches `keepBetter` is unchanged, and the ranking below is
-- (distance, name)-lexicographic — i.e. order-independent — so the suggestion
-- text is byte-identical to the old exhaustive scan (verified over 931
-- suggestion-bearing diagnostics plus a whole-tree `medaka check` sweep).
--
-- ⚠️ WHAT THIS IS NOT: the pool is still SCANNED per unbound name, so the
-- prefilter itself remains O(unbound × in-scope) — about four machine ops per
-- pair, allocating nothing.  A true sub-linear index (deletion-neighbourhood /
-- BK-tree) was rejected: it costs O(pool × len²) STRINGS to build, on every
-- compile, to speed up a path that most compiles never take.  What the rewrite
-- removes is the ALLOCATING O(len²) DP from the inner loop, which was ~99.9% of
-- the cost.  The perf gate's `typos` shape grades that; nothing grades the
-- residual scan, on purpose.
data SugCand = SugCand String Int Int Int Int Bool

sugPoolOf : List String -> List SugCand
sugPoolOf ns = map sugCandOf ns

sugCandOf : String -> SugCand
sugCandOf n =
  SugCand
    n
    (stringLength n)
    (charMask 0 n)
    (charMask 5 n)
    (charMask 10 n)
    (startsUpper n)

-- An unbound name prepared for a pool scan: the name, the distance cut
-- (≤ 2 absolutely AND ≤ max(1, len/3) relatively — unchanged), and its five
-- prefilter keys.
data SugQuery = SugQuery String Int Int Int Int Int Bool

sugQueryOf : String -> SugQuery
sugQueryOf n =
  SugQuery
    n
    (minI 2 (maxI 1 (stringLength n / 3)))
    (stringLength n)
    (charMask 0 n)
    (charMask 5 n)
    (charMask 10 n)
    (startsUpper n)

-- Character-set bitmask over 32 slots, taken from bits [sh, sh+5) of each
-- character's hash; see `SugCand`.  32 (not 64) because a Medaka Int is a 63-bit
-- tagged immediate, so `shiftLeft 1 63` would not fit — hence three narrow
-- projections rather than one wide mask.  Extra aliasing only ever merges two
-- characters onto one slot, which makes the filter more conservative, never
-- wrong; the exact hash therefore has no bearing on the suggestion chosen (it
-- need not even agree across engines).
charMask : Int -> String -> Int
charMask sh n = charMaskGo sh (stringToChars n) 0 0

charMaskGo : Int -> Array Char -> Int -> Int -> Int
charMaskGo sh cs i acc
  | i >= arrayLength cs = acc
  | otherwise = charMaskGo sh cs (i + 1) (bitOr acc (shiftLeft 1 (bitAnd (shiftRight (hashChar (arrayGetUnsafe i cs)) sh) 31)))

-- Does `x` have at most `k` bits set?  Clears the lowest set bit (`x & (x - 1)`)
-- at most `k` times — O(k) with k = 2*lim <= 4, never a full popcount.
bitsAtMost : Int -> Int -> Bool
bitsAtMost k x
  | x == 0 = True
  | k <= 0 = False
  | otherwise = bitsAtMost (k - 1) (bitAnd x (x - 1))

-- The env-pool arm: every candidate carries its precomputed length, masks and
-- case class, so the reject test below allocates nothing.
bestOfPool : SugQuery -> List SugCand -> Option String
bestOfPool q cands = map ((best, _) => best) (bestInPool q cands None)

bestInPool : SugQuery -> List SugCand -> Option (String, Int) -> Option (String, Int)
bestInPool _ [] acc = acc
bestInPool q ((SugCand c clen cm1 cm2 cm3 cup)::cs) acc
  | sugRejects q c clen cm1 cm2 cm3 cup = bestInPool q cs acc
  | otherwise = bestInPool q cs (scoreCand q c acc)

-- The local-scope arm: a plain name list, rebuilt constantly and small, so its
-- candidates carry no precomputed keys.  The O(1) length filter still applies
-- (same soundness argument); the mask does not, since deriving one costs about
-- as much as the DP it would save at this list's size.
bestOfNames : SugQuery -> List String -> Option String
bestOfNames q ns = map ((best, _) => best) (bestInNames q ns None)

bestInNames : SugQuery -> List String -> Option (String, Int) -> Option (String, Int)
bestInNames _ [] acc = acc
bestInNames q (c::cs) acc
  | sugRejectsName q c (stringLength c) (startsUpper c) = bestInNames q cs acc
  | otherwise = bestInNames q cs (scoreCand q c acc)

-- The pool arm's reject test.  Deliberately NOT written as `sugRejectsName q …
-- || <mask test>`: `q` would have to be re-boxed at every candidate, which is
-- the per-candidate allocation this rewrite exists to remove.  Cheapest tests
-- first (`c == n` is a String compare and is true at most once); the disjuncts
-- are pure, so their order cannot change the verdict.
-- lint-disable-next-line rule-duplicate-body
sugRejects : SugQuery -> String -> Int -> Int -> Int -> Int -> Bool -> Bool
sugRejects (SugQuery n lim qlen qm1 qm2 qm3 qup) c clen cm1 cm2 cm3 cup = not (sameCase qup cup)
  || clen < qlen - lim
  || clen > qlen + lim
  || not (bitsAtMost (2 * lim) (bitXor qm1 cm1))
  || not (bitsAtMost (2 * lim) (bitXor qm2 cm2))
  || not (bitsAtMost (2 * lim) (bitXor qm3 cm3))
  || c == n

sugRejectsName : SugQuery -> String -> Int -> Bool -> Bool
sugRejectsName (SugQuery n lim qlen _ _ _ qup) c clen cup = not (sameCase qup cup)
  || clen < qlen - lim
  || clen > qlen + lim
  || c == n

-- Monomorphic Bool equality: `==` here would be a dict-dispatched `Eq` method
-- call in the pool scan's inner loop (compiler/AGENTS.md, "the exception that is
-- NOT an exception").
sameCase : Bool -> Bool -> Bool
sameCase True True = True
sameCase False False = True
sameCase _ _ = False

-- The one expensive step: the O(len²) allocating DP, run only on candidates the
-- prefilters admitted.  `opBump` makes exactly that step visible to the perf
-- gate's OP arm (#884/#1016) — the count is the number of Levenshtein scorings,
-- which is what went quadratic and what a filter regression would lift again.
scoreCand : SugQuery -> String -> Option (String, Int) -> Option (String, Int)
scoreCand (SugQuery n lim _ _ _ _ _) c acc =
  let _ = opBump ()
  let d = editDistance n c
  if d > lim then acc else keepBetter c d acc

-- Medaka's naming convention makes leading case a structural signal
-- (constructors start uppercase, values/types-in-scope-of-a-value-query start
-- lowercase), so a candidate whose case class differs from the query's is
-- never the intended correction — surfacing one is worse than suggesting
-- nothing (#514 sub-finding: `string`/`toString`, both lowercase queries,
-- surfaced the unrelated prelude constructor `RString`).
-- (`stringSlice` ALLOCATES, so this is precomputed into `SugCand`/`SugQuery`
-- rather than re-derived per candidate — see `SugCand`.)
startsUpper : String -> Bool
startsUpper s = stringLength s > 0
  && stringSlice 0 1 s >= "A"
  && stringSlice 0 1 s <= "Z"

keepBetter : String -> Int -> Option (String, Int) -> Option (String, Int)
keepBetter c d None = Some (c, d)
keepBetter c d (Some (bc, bd))
  | d < bd = Some (c, d)
  | d == bd && c < bc = Some (c, d)
  | otherwise = Some (bc, bd)

checkLet : Option Loc -> Env -> Scope -> Bool -> Pat -> Expr -> Expr -> List ResError
checkLet cur env scope True (PVar f _) e1 e2 = checkExpr cur env (scopeAdd f scope) e1
  ++ checkExpr cur env (scopeAdd f scope) e2
-- non-recursive (or rec with non-var pat): the bound names are NOT in scope on
-- the RHS.  An UnboundVariable for one of them ⇒ the user likely forgot `rec`,
-- so re-target it as NonRecursiveValueLet.
checkLet cur env scope _ pat e1 e2 =
  let bound = patBindings pat
  checkPat cur env pat
    ++ patGroupDupErrors cur "pattern" [pat]
    ++ map (rewriteNonRec bound) (checkExpr cur env scope e1)
    ++ checkExpr cur env (scopeExtend bound scope) e2

rewriteNonRec : List String -> ResError -> ResError
rewriteNonRec bound (UnboundVariable n l s) =
  if contains n bound then
    NonRecursiveValueLet n l
  else
    UnboundVariable n l s
rewriteNonRec _ e = e

-- where-group: all group names are in scope for every clause body + the result
checkLetGroup : Option Loc -> Env -> Scope -> List LetBind -> Expr -> List ResError
checkLetGroup cur env scope binds body =
  let scope2 = scopeExtend (map letBindName binds) scope
  flatMap (checkLetBind cur env scope2) binds ++ checkExpr cur env scope2 body

letBindName : LetBind -> String
letBindName (LetBind n _) = n

checkLetBind : Option Loc -> Env -> Scope -> LetBind -> List ResError
checkLetBind cur env scope (LetBind n clauses) = letBindDupErrors cur n clauses
  ++ flatMap (checkFunClause cur env scope) clauses

-- A let/where binding whose clause run includes a NULLARY clause (`y = e`, no
-- params) yet has >1 clause is a duplicate value binding — the exact analog of
-- the top-level `int = 4` / `int = 5` case (coalesceClauses merged `y = 1` /
-- `y = 2` into one multi-clause LetBind).  A value binding admits exactly one
-- clause; the extras silently last-win → runtime garbage.  Multi-clause
-- FUNCTIONS (every clause carries >=1 pattern → no nullary clause) are exempt.
-- Flags every clause after the first; loc = that clause's body span.
letBindDupErrors : Option Loc -> String -> List FunClause -> List ResError
letBindDupErrors cur n clauses =
  if hasNullaryClause clauses then
    dupClauseTail cur n False clauses
  else
    []

hasNullaryClause : List FunClause -> Bool
hasNullaryClause [] = False
hasNullaryClause ((FunClause ps _)::rest) = isEmptyL ps || hasNullaryClause rest

dupClauseTail : Option Loc -> String -> Bool -> List FunClause -> List ResError
dupClauseTail _ _ _ [] = []
dupClauseTail cur n seen ((FunClause _ body)::rest) = whenL seen [DuplicateValueBinding n (orElseLoc (firstExprLoc body) cur)]
  ++ dupClauseTail cur n True rest

-- Parameter patterns are checked BEFORE the body's expr walk ever sees an
-- ELoc, so a bare `cur` (often None here — e.g. a top-level where-group)
-- would leave a pattern-position error (unknown record field in a
-- destructuring param) permanently unlocated. Fall back to the clause
-- body's own first ELoc span, same approximation `dupClauseTail`/`declLoc`
-- already use for pattern-adjacent errors.
checkFunClause : Option Loc -> Env -> Scope -> FunClause -> List ResError
checkFunClause cur env scope (FunClause pats body) =
  let patLoc = orElseLoc (firstExprLoc body) cur
  flatMap (checkPat patLoc env) pats
    ++ patGroupDupErrors patLoc "parameter list" pats
    ++ checkExpr cur env (scopeExtend (patsBindings pats) scope) body

checkArm : Option Loc -> Env -> Scope -> Arm -> List ResError
checkArm cur env scope (Arm pat gs body) =
  let scope0 = scopeExtend (patBindings pat) scope
  let (gErrs, scope2) = checkArmGuards cur env scope0 gs
  checkPat cur env pat
    ++ patGroupDupErrors cur "pattern" [pat]
    ++ gErrs
    ++ checkExpr cur env scope2 body

-- Resolve an arm's guard qualifiers left-to-right, threading each pattern-bind's
-- binders into the LATER qualifiers AND the arm body.  Returns the accumulated errors and the body's scope.  A `GBind`
-- also resolves its bind expression in the pre-bind scope and checks its pattern.
checkArmGuards : Option Loc -> Env -> Scope -> List Guard -> (List ResError, Scope)
checkArmGuards _ _ scope [] = ([], scope)
checkArmGuards cur env scope ((GBool e)::rest) =
  let (rErrs, scope2) = checkArmGuards cur env scope rest
  (checkExpr cur env scope e ++ rErrs, scope2)
checkArmGuards cur env scope ((GBind p e)::rest) =
  let here = checkExpr cur env scope e ++ checkPat cur env p ++ patGroupDupErrors cur "pattern" [p]
  let (rErrs, scope2) = checkArmGuards cur env (scopeExtend (patBindings p) scope) rest
  (here ++ rErrs, scope2)

checkGuardArm : Option Loc -> Env -> Scope -> GuardArm -> List ResError
checkGuardArm cur env scope (GuardArm gs body) = flatMap (checkGuard cur env scope) gs
  ++ checkExpr cur env scope body

checkGuard : Option Loc -> Env -> Scope -> Guard -> List ResError
checkGuard cur env scope (GBool e) = checkExpr cur env scope e
checkGuard cur env scope (GBind _ e) = checkExpr cur env scope e

checkStmts : Option Loc -> Env -> Scope -> List DoStmt -> List ResError
checkStmts _ _ _ [] = []
checkStmts cur env scope (s::rest) =
  let (errs, scope2) = checkStmt cur env scope s
  errs ++ checkStmts cur env scope2 rest

checkStmt : Option Loc -> Env -> Scope -> DoStmt -> (List ResError, Scope)
checkStmt cur env scope (DoExpr e) = (checkExpr cur env scope e, scope)
checkStmt cur env scope (DoBind p e) = (
  checkPat cur env p ++ patGroupDupErrors cur "pattern" [p] ++ checkExpr cur env scope e,
  scopeExtend (patBindings p) scope,
)
checkStmt cur env scope (DoLet _ False p e) = (
  checkPat cur env p ++ patGroupDupErrors cur "pattern" [p] ++ checkExpr cur env scope e,
  scopeExtend (patBindings p) scope,
)
checkStmt cur env scope (DoLet _ True p e) = (
  checkPat cur env p ++ patGroupDupErrors cur "pattern" [p] ++ checkExpr cur env (scopeExtend (patBindings p) scope) e,
  scopeExtend (patBindings p) scope,
)
-- beta: a bare reassignment `x = e` (no `let`) of an existing binding is an
-- error — bindings are immutable. Still check the RHS so its errors surface too.
checkStmt cur env scope (DoAssign x e) = (
  ReassignImmutable x (orElseLoc (firstExprLoc e) cur) :: checkExpr cur env scope e,
  scope,
)
checkStmt cur env scope (DoFieldAssign _ _ e) =
  (checkExpr cur env scope e, scope)

checkInterp : Option Loc -> Env -> Scope -> InterpPart -> List ResError
checkInterp _ _ _ (InterpStr _) = []
checkInterp cur env scope (InterpExpr e) = checkExpr cur env scope e

checkFieldAssign : Option Loc -> Env -> Scope -> FieldAssign -> List ResError
checkFieldAssign cur env scope (FieldAssign _ e) = checkExpr cur env scope e

-- record create `C { f = v, … }`: head must be a record type / named ctor; if so,
-- each field must belong to it; then check the value exprs
checkRecordCreate : Option Loc -> Env -> Scope -> String -> List FieldAssign -> List ResError
checkRecordCreate cur env scope name fs = recCreateHead cur env name fs
  ++ flatMap (checkFieldAssign cur env scope) fs

recCreateHead : Option Loc -> Env -> String -> List FieldAssign -> List ResError
recCreateHead cur env name fs
  -- #1110: the expression-position peer of `recPatHead` — same head, same two sets,
  -- same single verdict; see that site's comment and `ambiguousHeadErrors` (#1253).
  | omHasKey name env.types || omHasKey name env.imported || omHasKey name env.ctors = ambiguousHeadErrors env name cur
    ++ flatMap (recCreateField cur env name) fs
  | otherwise = [UnknownType name cur (suggestType env name)]

recCreateField : Option Loc -> Env -> String -> FieldAssign -> List ResError
recCreateField cur env owner (FieldAssign fname _) =
  fieldVerdict cur env owner fname (ownersOf fname env.fieldOwnersIdx)

-- record update `{ e | f = v, … }`: the receiver's type isn't pinned, so only
-- flag a field unknown to *every* record (no FieldNotInRecord here)
checkRecordUpdate : Option Loc -> Env -> Scope -> Expr -> List FieldAssign -> List ResError
checkRecordUpdate cur env scope e0 fs = checkExpr cur env scope e0
  ++ flatMap (recUpdateField cur env scope) fs

recUpdateField : Option Loc -> Env -> Scope -> FieldAssign -> List ResError
recUpdateField cur env scope (FieldAssign fname v) = checkExpr cur env scope v
  ++ fieldKnownErr cur env fname

fieldKnownErr : Option Loc -> Env -> String -> List ResError
fieldKnownErr cur env fname =
  recUpdateVerdict cur fname (ownersOf fname env.fieldOwnersIdx)

recUpdateVerdict : Option Loc -> String -> List String -> List ResError
recUpdateVerdict cur fname [] = [UnknownField fname cur]
recUpdateVerdict _ _ _ = []

checkSection : Option Loc -> Env -> Scope -> Section -> List ResError
checkSection _ _ _ (SecBare _) = []
checkSection cur env scope (SecRight _ e) = checkExpr cur env scope e
checkSection cur env scope (SecLeft e _) = checkExpr cur env scope e

-- ── check_decl ────────────────────────────────────────────────────────────
-- Decl-level entry: `cur` starts at `None` (no enclosing expr span yet); the body's `ELoc`
-- wrappers re-set it as the expr walk descends.
checkDecl : Env -> Decl -> List ResError
checkDecl env (DFunDef _ _ pats body) = flatMap (checkPat (firstExprLoc body) env) pats
  ++ patGroupDupErrors (firstExprLoc body) "parameter list" pats
  ++ checkExpr None env (mkScope (patsBindings pats)) body
checkDecl env (DLetGroup _ binds) =
  -- top-level where-group: all group names are in scope for every clause body
  -- (mutual recursion).
  flatMap (checkLetBind None env (mkScope (map letBindName binds))) binds
checkDecl env (DTypeSig _ _ t) = checkType None env t
checkDecl env (DExtern _ _ t) = checkType None env t
checkDecl env (DData { dataCtors = vs }) = flatMap (checkVariant env) vs
checkDecl env (DProp _ _ params body) = checkProp env params body
checkDecl env (DTest _ _ body) = checkExpr None env emptyScope body
checkDecl env (DBench _ _ body) = checkExpr None env emptyScope body
checkDecl env (DInterface { supers, methods, ... }) =
  checkInterfaceDecl env supers methods
checkDecl env (DImpl { iface, tys, reqs, methods, ... }) =
  checkImplDecl env iface tys reqs methods
checkDecl env (DTypeAlias { tyAliasRhs = rhs }) = checkType None env rhs
checkDecl env (DNewtype { newtypeFieldTy = fty }) = checkType None env fty
checkDecl env (DAttrib _ inner) = checkDecl env inner
checkDecl _ _ = []

checkVariant : Env -> Variant -> List ResError
checkVariant env (Variant _ (ConPos tys)) = flatMap (checkType None env) tys
checkVariant env (Variant _ (ConNamed fs _)) = flatMap (checkFieldType env) fs

checkFieldType : Env -> Field -> List ResError
checkFieldType env (Field _ t) = checkType None env t

checkProp : Env -> List PropParam -> Expr -> List ResError
checkProp env params body = flatMap (checkPropParamTy env) params
  ++ checkExpr None env (mkScope (map propParamName params)) body

checkPropParamTy : Env -> PropParam -> List ResError
checkPropParamTy env (PropParam _ _ t) = checkType None env t

propParamName : PropParam -> String
propParamName (PropParam x _ _) = x

checkInterfaceDecl : Env -> List Super -> List IfaceMethod -> List ResError
checkInterfaceDecl env supers methods = flatMap (checkSuper env) supers
  ++ flatMap (checkIfaceMethod env) methods

-- ⚠️ The `None` is structural, not an oversight — see `ambiguousIfaceErrors`.
checkSuper : Env -> Super -> List ResError
checkSuper env (Super { superHead = iface }) =
  if contains iface env.interfaces then
    ambiguousIfaceErrors env iface None
  else
    [UnknownInterface iface None]

checkIfaceMethod : Env -> IfaceMethod -> List ResError
checkIfaceMethod env (IfaceMethod _ t None _) = checkType None env t
checkIfaceMethod env (IfaceMethod _ t (Some (MethodDefault pats body)) _) = checkType None env t
  ++ flatMap (checkPat (firstExprLoc body) env) pats
  ++ checkExpr None env (mkScope (patsBindings pats)) body

-- `firstTyLocList tyargs` is the impl HEAD's own span (`impl Iface Ty1 Ty2…`) —
-- the locator `firstTyLoc`'s doc comment names for exactly this position, and the
-- best one available for an occurrence carrier that has no `Loc` of its own.
--
-- ⚠️ THE AMBIGUITY CHECK FOR `DImpl.iface` IS HERE, not in `checkImplIface` beside
-- its `UnknownInterface` where the other three occurrence positions put theirs, for
-- two reasons.  `tyargs` — the only span this diagnostic can be located from — is in
-- scope HERE and not there; and threading it in would have added a parameter to
-- `checkImplIface`, whose signature is pinned in
-- `test/selfproc_goldens/legA/frontend.resolve.golden`, forfeiting the
-- ADDITIVE-ONLY recapture that makes this arc's goldens mechanically reviewable
-- (#1211/#1219/#1225 each moved that file additively; so does this).
--
-- No `contains iface env.interfaces` guard is needed to keep this from
-- double-reporting alongside `UnknownInterface`: `ifaceAmbiguousSet` and
-- `env.interfaces`' `iaIfaces` are filtered from the SAME `expInterfaces` over the
-- SAME `importedNamesMM` names, so an ambiguous interface is necessarily in scope
-- and the two verdicts are mutually exclusive by construction.
checkImplDecl : Env -> String -> List Ty -> List Require -> List ImplMethod -> List ResError
checkImplDecl env iface tyargs reqs methods = flatMap (checkType None env) tyargs
  ++ flatMap (checkRequire env) reqs
  ++ flatMap (checkImplMethod env) methods
  ++ checkImplIface env iface methods
  ++ ambiguousIfaceErrors env iface (firstTyLocList tyargs)

checkRequire : Env -> Require -> List ResError
checkRequire env (Require { requireHead = iface, requireArgs = tys }) = (if contains iface env.interfaces then ambiguousIfaceErrors env iface (firstTyLocList tys) else [UnknownInterface iface None])
  ++ flatMap (checkType None env) tys

checkImplMethod : Env -> ImplMethod -> List ResError
checkImplMethod env (ImplMethod _ pats body) = flatMap (checkPat (firstExprLoc body) env) pats
  ++ checkExpr None env (mkScope (patsBindings pats)) body

checkImplIface : Env -> String -> List ImplMethod -> List ResError
checkImplIface env iface methods
  | not (contains iface env.interfaces) = [UnknownInterface iface None]
  | otherwise = flatMap (checkMethodMember iface (ifaceMethodsOf iface env.ifaceMethods)) methods

ifaceMethodsOf : String -> List (String, List String) -> List String
ifaceMethodsOf _ [] = []
ifaceMethodsOf iface ((i, ms)::rest)
  | i == iface = ms
  | otherwise = ifaceMethodsOf iface rest

checkMethodMember : String -> List String -> ImplMethod -> List ResError
checkMethodMember iface known (ImplMethod mname _ _) =
  if contains mname known then
    []
  else
    [MethodNotInInterface mname iface None]

-- ── Primitives (hardcoded) ───────────────────────────────────────────────
isTupleCtorTyName : String -> Bool
isTupleCtorTyName n = contains n tupleCtorTyNames

-- Kept in sync with the parser's `tupleCtorTyName` and typecheck's
-- `tupleHeadTagTc`.  Shared with `builtinTyOrigins` (#1110), which needs the same
-- set to give every tuple head the reserved BUILTIN origin.
tupleCtorTyNames : List String
tupleCtorTyNames = ["__tuple2__", "__tuple3__", "__tuple4__", "__tuple5__"]

primitiveTypes : List String
primitiveTypes =
  ["Int", "Float", "String", "Char", "Bool", "Unit", "List", "Ref", "Array"]

primitiveConstructors : List String
primitiveConstructors = ["True", "False"]

-- ── Name extractors (over runtime / prelude / user decls) ─────────────────
externNames : List Decl -> List String
externNames [] = []
externNames ((DExtern _ n _)::rest) = n :: externNames rest
externNames (_::rest) = externNames rest

dataRecordNames : List Decl -> List String
dataRecordNames [] = []
dataRecordNames ((DData { dataName = n })::rest) = n :: dataRecordNames rest
dataRecordNames ((DTypeAlias { tyAliasName = n })::rest) =
  n :: dataRecordNames rest
dataRecordNames ((DNewtype { newtypeName = n })::rest) =
  n :: dataRecordNames rest
dataRecordNames ((DAttrib _ d)::rest) = dataRecordNames (d::rest)
dataRecordNames (_::rest) = dataRecordNames rest

-- user/platform effect labels declared with `effect Foo` (Phase 146 gap 2)
effectNames : List Decl -> List String
effectNames [] = []
effectNames ((DEffect _ n _)::rest) = n :: effectNames rest
effectNames ((DAttrib _ d)::rest) = effectNames (d::rest)
effectNames (_::rest) = effectNames rest

ctorNames : List Decl -> List String
ctorNames [] = []
ctorNames ((DData { dataCtors = vs })::rest) = map variantName vs
  ++ ctorNames rest
ctorNames ((DNewtype { newtypeCtor = con })::rest) = con :: ctorNames rest
ctorNames ((DAttrib _ d)::rest) = ctorNames (d::rest)
ctorNames (_::rest) = ctorNames rest

variantName : Variant -> String
variantName (Variant n _) = n

ifaceMethodNm : IfaceMethod -> String
ifaceMethodNm (IfaceMethod n _ _ _) = n

implMethodNm : ImplMethod -> String
implMethodNm (ImplMethod n _ _) = n

interfaceList : List Decl -> List (String, List String)
interfaceList [] = []
interfaceList ((DInterface { name = n, methods, ... })::rest) =
  (n, map ifaceMethodNm methods) :: interfaceList rest
interfaceList (_::rest) = interfaceList rest

-- prelude value names (DFunDef/DTypeSig + DImpl & DInterface method names)
preludeValueNames : List Decl -> List String
preludeValueNames [] = []
preludeValueNames ((DFunDef _ n _ _)::rest) = n :: preludeValueNames rest
preludeValueNames ((DTypeSig _ n _)::rest) = n :: preludeValueNames rest
preludeValueNames ((DImpl { methods, ... })::rest) = map implMethodNm methods
  ++ preludeValueNames rest
preludeValueNames ((DInterface { methods, ... })::rest) = map ifaceMethodNm methods
  ++ preludeValueNames rest
preludeValueNames ((DAttrib _ d)::rest) = preludeValueNames (d::rest)
preludeValueNames (_::rest) = preludeValueNames rest

-- user value names (DFunDef/DTypeSig/DExtern + DInterface methods; NOT DImpl)
userValueNames : List Decl -> List String
userValueNames [] = []
userValueNames ((DFunDef _ n _ _)::rest) = n :: userValueNames rest
userValueNames ((DTypeSig _ n _)::rest) = n :: userValueNames rest
userValueNames ((DExtern _ n _)::rest) = n :: userValueNames rest
userValueNames ((DLetGroup _ bs)::rest) = map letBindName bs
  ++ userValueNames rest
userValueNames ((DInterface { methods, ... })::rest) = map ifaceMethodNm methods
  ++ userValueNames rest
userValueNames ((DAttrib _ d)::rest) = userValueNames (d::rest)
userValueNames (_::rest) = userValueNames rest

fieldOwnersOf : List Decl -> List (String, String)
fieldOwnersOf [] = []
fieldOwnersOf ((DData { dataCtors = vs })::rest) = flatMap variantFieldOwners vs
  ++ fieldOwnersOf rest
fieldOwnersOf (_::rest) = fieldOwnersOf rest

recordFieldOwner : String -> Field -> (String, String)
recordFieldOwner owner (Field fname _) = (fname, owner)

variantFieldOwners : Variant -> List (String, String)
variantFieldOwners (Variant cname (ConNamed fs _)) =
  map (recordFieldOwner cname) fs
variantFieldOwners (Variant _ (ConPos _)) = []

-- single-file import stub: names brought into scope (core import = no-op)
importedNames : List Decl -> List String
importedNames [] = []
importedNames ((DUse _ path _)::rest) = useImportNames path
  ++ importedNames rest
importedNames (_::rest) = importedNames rest

useImportNames : UsePath -> List String
useImportNames path = if useModId path == "core" then [] else useStubNames path

useStubNames : UsePath -> List String
useStubNames (UseName ns) = [lastOf ns]
useStubNames (UseGroup _ ms) = map useMemberLocal ms
useStubNames (UseWild _) = []
-- A module alias binds `A.name` per EXPORT, which this single-file stub path cannot
-- enumerate (it has no ModuleExports).  Binding bare `A` here would be a lie — `A`
-- alone is never a value.  A non-core import in a single file is already reported by
-- `singleFileImportErrors`, so contributing nothing is right.
useStubNames (UseAlias _ _) = []

useModId : UsePath -> String
useModId (UseName ns) =
  if listLen ns > 1 then
    joinDot (initList ns)
  else
    firstOr "" ns
useModId (UseGroup ns _) = joinDot ns
useModId (UseWild ns) = joinDot ns
useModId (UseAlias ns _) = joinDot ns

lastOf : List String -> String
lastOf [] = ""
lastOf [x] = x
lastOf (_::rest) = lastOf rest

firstOr : String -> List String -> String
firstOr d [] = d
firstOr _ (x::_) = x

programIsCore : List Decl -> Bool
programIsCore prog = hasOrdering prog && hasFoldable prog

hasOrdering : List Decl -> Bool
hasOrdering [] = False
hasOrdering ((DData { dataName = "Ordering" })::_) = True
hasOrdering (_::rest) = hasOrdering rest

hasFoldable : List Decl -> Bool
hasFoldable [] = False
hasFoldable ((DInterface { name = "Foldable", ... })::_) = True
hasFoldable (_::rest) = hasFoldable rest

-- ── build_env ─────────────────────────────────────────────────────────────
buildEnv : List Decl -> List Decl -> List Decl -> List String -> Env
buildEnv runtimeDecls preludeDecls prog internalGuard =
  let seed = not (programIsCore prog)
  let pTypes = whenL seed (dataRecordNames preludeDecls)
  let pCtors = whenL seed (ctorNames preludeDecls)
  let pIfaces = whenL seed (interfaceList preludeDecls)
  let pValues = whenL seed (preludeValueNames preludeDecls)
  let pFieldOwners = whenL seed (fieldOwnersOf preludeDecls)
  let uIfaces = interfaceList prog
  let imported = importedNames prog
  let valuesM = omFromNames (externNames runtimeDecls ++ pValues ++ userValueNames prog ++ imported) omEmpty
  let typesM = omFromNames (primitiveTypes ++ pTypes ++ dataRecordNames prog ++ imported) omEmpty
  let ctorsM = omFromNames (primitiveConstructors ++ pCtors ++ ctorNames prog) omEmpty
  let importedM = omFromNames imported omEmpty
  Env {
    values = valuesM,
    types = typesM,
    ctors = ctorsM,
    fields = map fst pFieldOwners ++ map fst (fieldOwnersOf prog),
    fieldOwners = pFieldOwners ++ fieldOwnersOf prog,
    fieldOwnersIdx = buildFieldOwnerIndex (pFieldOwners ++ fieldOwnersOf prog),
    interfaces = map fst pIfaces ++ map fst uIfaces,
    ifaceMethods = pIfaces ++ uIfaces,
    effects = effectNames prog,
    imported = importedM,
    importedModuleValues = [],
    ambiguous = [],
    ctorAmbiguous = [],
    typeAmbiguous = [],
    ifaceAmbiguous = [],
    internalGuard = omFromNames internalGuard omEmpty,
    sugValues = sugPoolOf (omKeys valuesM ++ omKeys ctorsM ++ omKeys importedM),
    sugTypes = sugPoolOf (omKeys typesM ++ omKeys importedM),
  }

whenL : Bool -> List a -> List a
whenL True xs = xs
whenL False _ = []

-- ── build-time errors: ExternWithBody + DuplicateDefinition ──────────────
-- S-2: dupSignatureErrors is the unambiguous "two signatures ⇒ two
-- definitions" check (see DuplicateSignature's doc comment).  Its findings
-- take priority over the two older, position-based checks, which can
-- otherwise ALSO fire on the very same name and produce a misleading second
-- message (contiguityErrors' "must be contiguous, merge them" advice is wrong
-- when the two same-named runs are genuinely unrelated definitions):
--   - a name flagged by dupValueBindingErrors (nullary duplicate, case (c))
--     is excluded from dupSignatureErrors' own findings — that check already
--     fires correctly and unconditionally (no signature needed), so it is
--     left untouched rather than doubled up.
--   - a name flagged by dupSignatureErrors is excluded from contiguityErrors'
--     findings — the accurate "already defined at line NNN" message replaces
--     the "must be contiguous" one for that name.
buildErrors : List Decl -> List Decl -> List ResError
buildErrors preludeDecls prog =
  let dupValErrs = dupValueBindingErrors prog
  let nullaryDupNames = map dvbName dupValErrs
  let sigDups = filterOutNamesIn nullaryDupNames dupSigName (dupSignatureErrors prog)
  let sigDupNames = map dupSigName sigDups
  let contigErrs = filterOutNamesIn sigDupNames dbName (contiguityErrors prog)
  externWithBodyErrors (externNames prog) prog
    ++ duplicateErrors preludeDecls prog
    ++ coreUseErrors preludeDecls prog
    ++ sigDups
    ++ contigErrs
    ++ dupValErrs

-- Validate every `core` use-path's members against the prelude's real surface.
--
-- Lives in buildErrors because buildErrors is the ONE import-independent error pass
-- both resolve paths run — `resolveProgram` (single-file: `medaka check one.mdk`, which
-- the CLI routes to whenever the graph is ONE module) and `resolveModuleG` (multi-module).
-- The multi-module path's `oneImport` cannot host this: the single-file path never
-- consults an import table at all, and a module whose only imports are `core` IS a
-- one-module graph — precisely the shape of `stdlib/list.mdk`.  Validating in the import
-- table alone would leave the EXPORT SITE, checked on its own, silent: the exact hole that
-- let `export import core.{filter}` re-export nothing while `medaka check stdlib/list.mdk`
-- reported no problem at all.
--
-- Non-core paths are NOT validated here — they need the loader's `known` exports, which
-- buildErrors does not have; the multi-module path validates them in `oneImport`.
coreUseErrors : List Decl -> List Decl -> List ResError
coreUseErrors preludeDecls prog =
  flatMap (coreUseErrorsOf (coreExports preludeDecls)) prog

coreUseErrorsOf : ModuleExports -> Decl -> List ResError
coreUseErrorsOf coreExp (DAttrib _ d) = coreUseErrorsOf coreExp d
coreUseErrorsOf coreExp (DUse _ path loc)
  | useModId path == "core" =
    let (_, errs) = importedNamesMM path coreExp
    map (withResErrorLoc loc) errs
  | otherwise = []
coreUseErrorsOf _ _ = []

-- name extractors for the three ResError kinds combined in buildErrors — each
-- is only ever applied to a list its OWN producer built, so the wildcard arm
-- (unreachable in practice) just needs to typecheck.
dvbName : ResError -> String
dvbName (DuplicateValueBinding n _) = n
dvbName _ = ""

dupSigName : ResError -> String
dupSigName (DuplicateSignature n _ _) = n
dupSigName _ = ""

dbName : ResError -> String
dbName (DuplicateBinding n _) = n
dbName _ = ""

-- drop entries whose name (per `nameOf`) is in `names`
filterOutNamesIn : List String -> (ResError -> String) -> List ResError -> List ResError
filterOutNamesIn _ _ [] = []
filterOutNamesIn names nameOf (e::rest)
  | contains (nameOf e) names = filterOutNamesIn names nameOf rest
  | otherwise = e :: filterOutNamesIn names nameOf rest

-- S-2 root check: a top-level name with >=2 of its OWN `DTypeSig` entries
-- (anywhere in the file, contiguous or not) is unambiguously two definitions,
-- never one legitimate multi-clause function — a real multi-clause function
-- (`fib 0 = 0` / `fib 1 = 1` / `fib n = …`) has exactly ONE signature shared
-- by all its clauses.  Flags every occurrence from the 2nd onward, keeping
-- the loc of the FIRST occurrence to name in the message.
--
-- Deliberately does NOT flag two same-named clause-groups that share zero
-- signatures (`greet name = "a"` … `greet name = "b"`, no `greet : …`
-- anywhere): telling those two apart (a mistakenly-duplicated definition vs.
-- a legal-but-redundant extra clause whose pattern is unreachable) needs
-- pattern-redundancy/exhaustiveness reasoning over top-level clause groups,
-- which is a distinct, not-yet-built feature — not name resolution. Scoped
-- out of this fix; see AGENTS.md's harden-typechecker/debug-pipeline skills
-- for where that would eventually land (exhaust.mdk-adjacent).
dupSignatureErrors : List Decl -> List ResError
dupSignatureErrors prog = dupSigGo prog omEmpty

dupSigGo : List Decl -> OrdMap (Option Loc) -> List ResError
dupSigGo [] _ = []
dupSigGo (d::rest) seen = match dupSigOf d
  Some (n, loc) => match omLookup n seen
    Some earlierLoc => DuplicateSignature n loc earlierLoc :: dupSigGo rest seen
    None => dupSigGo rest (omInsert n loc seen)
  None => dupSigGo rest seen

-- (name, loc) for a top-level DTypeSig; None for any other decl.
dupSigOf : Decl -> Option (String, Option Loc)
dupSigOf (DAttrib _ d) = dupSigOf d
dupSigOf (DTypeSig _ n ty) = Some (n, firstTyLoc ty)
dupSigOf _ = None

-- A nullary top-level VALUE binding (`x = e`, zero params) admits EXACTLY ONE
-- clause: there is no argument to discriminate on, so a second same-named
-- definition silently last-wins at eval → runtime garbage (`intToString: not an
-- Int`).  Flag the 2nd (and later) occurrence.  A multi-clause FUNCTION
-- (`f Red = 1` / `f Green = 2`) is NOT flagged: every clause carries >=1
-- pattern, so `isNullary` is False and the run stays clean.  Runs on the same
-- post-desugar decl list as contiguityErrors; DTypeSig is transparent (a
-- signature between `int : Int` and `int = 4` does not break the run), any other
-- decl (or a differently-named DFunDef) starts a fresh run.
dupValueBindingErrors : List Decl -> List ResError
dupValueBindingErrors prog = dupValGo None False prog

-- run = Some name of the current contiguous same-name DFunDef run; sawNullary =
-- a nullary clause has already appeared in that run.
dupValGo : Option String -> Bool -> List Decl -> List ResError
dupValGo _ _ [] = []
dupValGo run sawNullary (d::rest)
  | isTransparentDecl d = dupValGo run sawNullary rest
  | otherwise = match dupValClause d
    Some (n, isNull, loc) =>
      let continuing = run == Some n
      let dup = continuing && (sawNullary || isNull)
      let errs = whenL dup [DuplicateValueBinding n loc]
      let sawNullary2 = continuing && sawNullary || isNull
      errs ++ dupValGo (Some n) sawNullary2 rest
    None => dupValGo None False rest

-- (name, isNullary, loc) for a single-clause top-level value/function def;
-- None for any decl that is not a DFunDef (starts a fresh run).
dupValClause : Decl -> Option (String, Bool, Option Loc)
dupValClause (DAttrib _ d) = dupValClause d
dupValClause (DFunDef _ n ps body) = Some (n, isEmptyL ps, firstExprLoc body)
dupValClause _ = None

isEmptyL : List a -> Bool
isEmptyL [] = True
isEmptyL _ = False

-- Phase 148: the clauses of a top-level value binding must be contiguous.  Two
-- same-named DFunDef/DLetGroup clause-runs separated by an intervening clause-body
-- decl are silently coalesced into one multi-clause function; flag the gap.
-- Walk decls tracking opened
-- (names in their current contiguous run of clause bodies) and closed (a run that
-- ended); reaching a closed name re-opens it AND is the error.  A clause-body decl
-- closes every open name it does not itself bind.  Type signatures (DTypeSig) are
-- TRANSPARENT — they neither open nor close a run, so the "all sigs, then all
-- defs" grouping of a mutually-recursive pair is accepted.
declBindNames : Decl -> List String
declBindNames (DAttrib _ d) = declBindNames d
declBindNames (DFunDef _ n _ _) = [n]
declBindNames (DLetGroup _ bs) = map letBindName bs
declBindNames _ = []

-- a transparent decl (DTypeSig) is skipped entirely by the contiguity walk
isTransparentDecl : Decl -> Bool
isTransparentDecl (DAttrib _ d) = isTransparentDecl d
isTransparentDecl (DTypeSig _ _ _) = True
isTransparentDecl _ = False

contiguityErrors : List Decl -> List ResError
contiguityErrors prog = contigGo omEmpty [] prog

-- closed = names whose run ended; opened = names in their current run.
--
-- `closed` is an OrdMap-backed SET, not a list: it accumulates every top-level
-- name in the file and is only ever probed for membership (order is irrelevant —
-- error order comes from `ns`).  As a list it made this walk O(N²) in both time
-- and allocation, since every decl rebuilt the whole accumulator (`unionStr`'s
-- `acc ++ [x]`, then `removeAll`'s full copy).  That was ~100% of the resolve
-- stage's cost on a large file.  `opened` stays a list — by construction it never
-- holds more than a single decl's binders (opened2 ⊆ ns), so it is O(1)-sized.
contigGo : OrdMap Unit -> List String -> List Decl -> List ResError
contigGo _ _ [] = []
contigGo closed opened (d::rest)
  | isTransparentDecl d = contigGo closed opened rest
  | otherwise =
    let ns = declBindNames d
    -- close every open name not bound by this decl
    let stillOpen = filterKeepOpen ns opened
    let nowClosed = closeMissing opened stillOpen closed
    -- process this decl's bound names against the closed set
    let errs = newlyDuplicated (declLoc d) nowClosed ns
    -- re-open the names this decl binds (whether fresh or re-opened)
    let opened2 = unionStr stillOpen ns
    -- a re-opened (previously closed) name leaves the closed set; harmless to keep,
    -- but removing it avoids a second spurious flag on a third occurrence
    let closed2 = deleteAllStr ns nowClosed
    errs ++ contigGo closed2 opened2 rest

-- names from `opened` that are still bound by the current decl (stay open)
filterKeepOpen : List String -> List String -> List String
filterKeepOpen _ [] = []
filterKeepOpen ns (o::os)
  | contains o ns = o :: filterKeepOpen ns os
  | otherwise = filterKeepOpen ns os

-- add every `opened` name NOT in `stillOpen` to the closed set
closeMissing : List String -> List String -> OrdMap Unit -> OrdMap Unit
closeMissing [] _ closed = closed
closeMissing (o::os) stillOpen closed
  | contains o stillOpen = closeMissing os stillOpen closed
  | otherwise = closeMissing os stillOpen (omInsert o () closed)

-- drop every name in `ns` from the closed set
deleteAllStr : List String -> OrdMap Unit -> OrdMap Unit
deleteAllStr [] closed = closed
deleteAllStr (n::ns) closed = deleteAllStr ns (omDelete n closed)

-- a bound name that is in the closed set is a non-contiguous re-appearance.
-- Stage B: carry the offending decl's source span (first ELoc in its body).
newlyDuplicated : Option Loc -> OrdMap Unit -> List String -> List ResError
newlyDuplicated _ _ [] = []
newlyDuplicated loc closed (n::ns)
  | omHasKey n closed = DuplicateBinding n loc :: newlyDuplicated loc closed ns
  | otherwise = newlyDuplicated loc closed ns

-- declLoc: the first ELoc span found in a pre-order walk of a decl's body
-- (walks the body via mapExpr to grab the
-- first ELoc).  DFunDef only; other decls have no body span → None.
declLoc : Decl -> Option Loc
declLoc (DAttrib _ d) = declLoc d
declLoc (DFunDef _ _ _ body) = firstExprLoc body
declLoc _ = None

-- First ELoc span in a pre-order traversal of an expr (None if the subtree has
-- no ELoc wrapper).  Pre-order so it matches map_expr's outermost-first order.
firstExprLoc : Expr -> Option Loc
firstExprLoc (ELoc l _) = Some l
firstExprLoc (EApp f x) = orElseLoc (firstExprLoc f) (firstExprLoc x)
firstExprLoc (ELam _ body) = firstExprLoc body
firstExprLoc (ELet _ _ _ e1 e2) = orElseLoc (firstExprLoc e1) (firstExprLoc e2)
firstExprLoc (ELetGroup _ body) = firstExprLoc body
firstExprLoc (EMatch e0 _) = firstExprLoc e0
firstExprLoc (EIf c t el) =
  orElseLoc (firstExprLoc c) (orElseLoc (firstExprLoc t) (firstExprLoc el))
firstExprLoc (EBinOp _ a b _) = orElseLoc (firstExprLoc a) (firstExprLoc b)
firstExprLoc (EUnOp _ a _) = firstExprLoc a
firstExprLoc (EInfix _ a b) = orElseLoc (firstExprLoc a) (firstExprLoc b)
firstExprLoc (EFieldAccess e0 _ _) = firstExprLoc e0
firstExprLoc (ETuple es) = firstLocList es
firstExprLoc (EListLit es) = firstLocList es
firstExprLoc (EArrayLit es) = firstLocList es
firstExprLoc (EAnnot e0 _) = firstExprLoc e0
firstExprLoc (EHeadAnnot e0 _) = firstExprLoc e0
firstExprLoc (ERangeList lo hi _) =
  orElseLoc (firstExprLoc lo) (firstExprLoc hi)
firstExprLoc (ERangeArray lo hi _) =
  orElseLoc (firstExprLoc lo) (firstExprLoc hi)
firstExprLoc (EIndex e0 i _) = orElseLoc (firstExprLoc e0) (firstExprLoc i)
firstExprLoc (ESlice e0 lo hi _ _) =
  orElseLoc (firstExprLoc e0) (orElseLoc (firstExprLoc lo) (firstExprLoc hi))
firstExprLoc (EDoOrigin _ e) = firstExprLoc e
firstExprLoc _ = None

firstLocList : List Expr -> Option Loc
firstLocList [] = None
firstLocList (e::rest) = orElseLoc (firstExprLoc e) (firstLocList rest)

unionStr : List String -> List String -> List String
unionStr acc [] = acc
unionStr acc (x::xs)
  | contains x acc = unionStr acc xs
  | otherwise = unionStr (acc ++ [x]) xs

externWithBodyErrors : List String -> List Decl -> List ResError
externWithBodyErrors _ [] = []
externWithBodyErrors externs ((DFunDef _ n _ _)::rest) = (if contains n externs then [ExternWithBody n None] else [])
  ++ externWithBodyErrors externs rest
externWithBodyErrors externs (_::rest) = externWithBodyErrors externs rest

duplicateErrors : List Decl -> List Decl -> List ResError
duplicateErrors preludeDecls prog =
  let seed = not (programIsCore prog)
  let typeSeed = primitiveTypes ++ whenL seed (dataRecordNames preludeDecls)
  let ctorSeed = primitiveConstructors ++ whenL seed (ctorNames preludeDecls)
  let ifaceSeed = whenL seed (map fst (interfaceList preludeDecls))
  map (dupErr "type") (findDups typeSeed (dataRecordNames prog))
    ++ map (dupErr "constructor") (findDups ctorSeed (ctorNames prog))
    ++ map (dupErr "interface") (findDups ifaceSeed (map fst (interfaceList prog)))
    ++ ifaceMethodCollisions prog

dupErr : String -> String -> ResError
dupErr kind n = DuplicateDefinition kind n None

-- Q1 (Stage B / Phase 4b): a module whose OWN declarations include two
-- `interface`s declaring the same METHOD name is REJECTED, on the DECLARATION.
--
-- ⚠️ THIS NARROWS ACCEPTANCE, deliberately and with an owner ruling behind it.
-- `interface E1 a where n : a -> Int` + `interface E2 a where n : a -> Int`, with
-- impls at DISJOINT receivers, is a program that compiled and ran correctly before
-- this check (it was test/iface_order_fixtures/control-shared-method-name-disjoint-
-- receivers/). It is rejected now anyway: the point is to make the ambiguity
-- UNREPRESENTABLE so a later unit can key impl selection by interface identity
-- without inheriting an order-dependent supply. Rejecting only at an ambiguous
-- OCCURRENCE would leave the deformed candidate set in the program and merely
-- decline to look at it.
--
-- ⚠️ SCOPE — THE PRELUDE IS OUT, AND THAT IS A SPEC RULING, NOT CAUTION.
-- `preludeDecls` is deliberately NOT consulted here (contrast the three checks
-- above, each of which seeds from it), so this fires on NEITHER prelude sub-case,
-- and the two are NOT the same case:
--   * against a prelude STANDALONE, docs/spec/SHADOW-SEMANTICS.md S1-PRELUDE rules
--     the collision observable but explicitly NOT an error, under the RESERVED
--     code `W-PRELUDE-METHOD-SHADOW` (compiler/DIAGNOSTIC-CODES-DESIGN.md §3),
--     owned by #1499. Rejecting it here would contradict a written ruling and
--     pre-empt that issue's deliverable.
--   * against a prelude INTERFACE METHOD (`eq`, `map`, `hash`, `minBound`) there
--     is no ruling of its own, so the behaviour is left exactly as it is — which
--     is measured NOT uniform: `minBound` shadows cleanly and the program runs at
--     exit 0, while `eq`/`map`/`hash` break the prelude's OWN bodies at exit 1
--     (`Could not deduce 'Same a' from the signature of 'neq'`). Untouched either
--     way; this check never looks at the prelude to find out which.
-- Pinned by test/iface_order_fixtures/control-prelude-method-name-shadow-accepted/.
--
-- SCOPE, the other two edges, achieved BY CONSTRUCTION of this site rather than by
-- a filter: imports never enter (`buildErrors` has no import table at all), and the
-- module's own set is exactly `prog`. So this says nothing about two interfaces in
-- DIFFERENT modules — the residual #1182/#1620 class — which stays live.
--
-- ⚠️ NOT `interfaceList`. That function has no `DAttrib` arm (it falls to its
-- wildcard), so an `@attr`-decorated `interface` is invisible to it — the same gap
-- `interfaceNamesOf` already documents. A `DAttrib` arm was NOT added to
-- `interfaceList` to fix that: the duplicate-interface-NAME check two lines above
-- reads the very same function, so widening it would ALSO widen that check — a
-- second acceptance narrowing, unscoped and unasked for. This walk is attribute-
-- aware on its own instead.
ifaceMethodCollisions : List Decl -> List ResError
ifaceMethodCollisions prog =
  ifaceMethodCollisionsGo omEmpty (ownInterfaceMethods prog)

-- `seen` maps a method name to the FIRST interface that declared it, and is
-- extended only AFTER an interface's own methods have been checked against it —
-- so a method name repeated WITHIN one interface is not reported here. That shape
-- is a different (and today unchecked) defect; folding it in silently would be a
-- third narrowing nobody scoped.
ifaceMethodCollisionsGo : OrdMap String -> List (String, List String) -> List ResError
ifaceMethodCollisionsGo _ [] = []
ifaceMethodCollisionsGo seen ((iname, ms)::rest) = ifaceMethodErrs iname seen ms
  ++ ifaceMethodCollisionsGo (addIfaceMethods iname ms seen) rest

ifaceMethodErrs : String -> OrdMap String -> List String -> List ResError
ifaceMethodErrs _ _ [] = []
ifaceMethodErrs iname seen (m::rest) = match omLookup m seen
  Some prev => DuplicateInterfaceMethod m prev iname None :: ifaceMethodErrs iname seen rest
  None => ifaceMethodErrs iname seen rest

-- first declarer wins, so a name colliding three ways names the SAME first
-- interface in both reports rather than chaining.
addIfaceMethods : String -> List String -> OrdMap String -> OrdMap String
addIfaceMethods _ [] seen = seen
addIfaceMethods iname (m::rest) seen
  | omHasKey m seen = addIfaceMethods iname rest seen
  | otherwise = addIfaceMethods iname rest (omInsert m iname seen)

-- `interfaceList`, made attribute-aware — see ifaceMethodCollisions for why this
-- is a separate walk and not an arm added to `interfaceList`.
ownInterfaceMethods : List Decl -> List (String, List String)
ownInterfaceMethods [] = []
ownInterfaceMethods ((DInterface { name = n, methods, ... })::rest) =
  (n, map ifaceMethodNm methods) :: ownInterfaceMethods rest
ownInterfaceMethods ((DAttrib _ d)::rest) = ownInterfaceMethods (d::rest)
ownInterfaceMethods (_::rest) = ownInterfaceMethods rest

-- names that are already present when declared (order-sensitive, like add_unique).
--
-- `seen` is an OrdMap-backed SET, not a growing `List` scanned by `contains`: the
-- membership test is the only thing this walk does per element, and as a list it was
-- O(elements²) — once per constructor on a wide `data` decl (#906, the `match:resolve`
-- ledger row) and once per interface on a many-interface file (#954, `manyifaces:resolve`),
-- both climbing toward the 4.0 quadratic ratio on the perf gate's op-count arm. Keyed
-- into an OrdMap the walk is O(elements log elements) with BYTE-IDENTICAL output: the
-- yielded duplicates and their order are unchanged (each already-present name emitted
-- once, in input order), only the internal membership structure differs.
findDups : List String -> List String -> List String
findDups seen names = findDupsGo (omFromNames seen omEmpty) names

findDupsGo : OrdMap Unit -> List String -> List String
findDupsGo _ [] = []
findDupsGo seen (n::rest)
  | omHasKey n seen = n :: findDupsGo seen rest
  | otherwise = findDupsGo (omInsert n () seen) rest

-- ── Serialization (matches dev/diagdump.ml's sexp_error) ─────────────────
-- The loc field (Stage B) is dropped here — the sexp form mirrors the OCaml
-- diagdump's location-stripped serialization.
export
resErrorSexp : ResError -> String
-- NOTE: the suggestion field is deliberately NOT serialized — the sexp feeds the
-- resolve_modules gate and must stay stable (the suggestion is cosmetic).
resErrorSexp (UnboundVariable n _ _) = "(UnboundVariable " ++ escStr n ++ ")"
resErrorSexp (UnboundVariableExported n m _) =
  "(UnboundVariableExported \{escStr n} \{escStr m})"
resErrorSexp (UnboundVariableIsModule n _) =
  "(UnboundVariableIsModule \{escStr n})"
resErrorSexp (UnknownConstructor n _ _) = "(UnknownConstructor "
  ++ escStr n
  ++ ")"
-- NOTE: the suggestion field is deliberately NOT serialized here either (mirrors
-- UnboundVariable above) — keeps the resolve_modules gate's sexp stable.
resErrorSexp (UnknownType n _ _) = "(UnknownType " ++ escStr n ++ ")"
resErrorSexp (UnknownEffect n _) = "(UnknownEffect " ++ escStr n ++ ")"
resErrorSexp (UnknownField n _) = "(UnknownField " ++ escStr n ++ ")"
resErrorSexp (FieldNotInRecord f r _) =
  "(FieldNotInRecord \{escStr f} \{escStr r})"
resErrorSexp (DuplicateDefinition k n _) =
  "(DuplicateDefinition \{escStr k} \{escStr n})"
resErrorSexp (InternalExternAccess n _) = "(InternalExternAccess "
  ++ escStr n
  ++ ")"
resErrorSexp (UnknownInterface n _) = "(UnknownInterface " ++ escStr n ++ ")"
resErrorSexp (MethodNotInInterface m i _) =
  "(MethodNotInInterface \{escStr m} \{escStr i})"
resErrorSexp (ExternWithBody n _) = "(ExternWithBody " ++ escStr n ++ ")"
resErrorSexp (PrivateNameAccess n m _) =
  "(PrivateNameAccess \{escStr n} \{escStr m})"
resErrorSexp (NoExportedConstructors n m _) =
  "(NoExportedConstructors \{escStr n} \{escStr m})"
resErrorSexp (NewtypeCtorNotExported n m _) =
  "(NewtypeCtorNotExported \{escStr n} \{escStr m})"
resErrorSexp (AbstractFieldAccess t f _) =
  "(AbstractFieldAccess \{escStr t} \{escStr f})"
resErrorSexp (UnknownModule n _) = "(UnknownModule " ++ escStr n ++ ")"
resErrorSexp (NonRecursiveValueLet n _) = "(NonRecursiveValueLet "
  ++ escStr n
  ++ ")"
resErrorSexp (DuplicateBinding n _) = "(DuplicateBinding " ++ escStr n ++ ")"
resErrorSexp (DuplicateValueBinding n _) = "(DuplicateValueBinding "
  ++ escStr n
  ++ ")"
resErrorSexp (DuplicateSignature n _ _) = "(DuplicateSignature "
  ++ escStr n
  ++ ")"
resErrorSexp (DuplicateBinder k n _) =
  "(DuplicateBinder \{escStr k} \{escStr n})"
resErrorSexp (AsPatternMisplaced _) = "AsPatternMisplaced"
resErrorSexp (AmbiguousOccurrence n mods _) = "(AmbiguousOccurrence "
  ++ joinWith " " (escStr n :: map escStr mods)
  ++ ")"
resErrorSexp (AmbiguousConstructor n mods _) = "(AmbiguousConstructor "
  ++ joinWith " " (escStr n :: map escStr mods)
  ++ ")"
resErrorSexp (AmbiguousType n mods _) = "(AmbiguousType "
  ++ joinWith " " (escStr n :: map escStr mods)
  ++ ")"
resErrorSexp (AmbiguousInterface n mods _) = "(AmbiguousInterface "
  ++ joinWith " " (escStr n :: map escStr mods)
  ++ ")"
resErrorSexp (ReassignImmutable n _) = "(ReassignImmutable " ++ escStr n ++ ")"
resErrorSexp (DuplicateInterfaceMethod m a b _) =
  "(DuplicateInterfaceMethod \{escStr m} \{escStr a} \{escStr b})"

-- String key for an `Option Loc`, used only to distinguish dedup candidates
-- (NOT a serialization contract like resErrorSexp): `None` collapses to a
-- fixed marker (matching UnknownType's un-threaded decl-level errors, which all
-- carry `None`), a real `Loc` renders its span so two errors at DIFFERENT real
-- locations are never conflated.
locKey : Option Loc -> String
locKey None = "-"
locKey (Some (Loc f sl sc el ec)) = "\{f}:\{intToString sl}:\{intToString sc}:\{intToString el}:\{intToString ec}"

-- Collapse consecutive-or-not errors that render identically (same
-- resErrorCode + ppResError message + location).  This mainly hits a typo'd
-- type name reused in more than one position of the same signature (`f :
-- Strng -> Strng`): each occurrence is a genuine separate AST node, but with
-- no real location threaded here (decl-level checks pass `cur = None`,
-- loc-threading is a separate task) the reports are otherwise
-- indistinguishable noise — whereas two errors with the SAME message but
-- DIFFERENT real locations (e.g. the same unbound name used twice in one
-- line) are kept, since the location makes them distinguishable and each is
-- independently actionable. Order-preserving, first occurrence wins.
-- NOTE: keyed on `ppResError`/`resErrorCode` (exhaustive over every ResError
-- constructor), NOT `resErrorSexp`. (`resErrorSexp` is now itself total —
-- including an `InternalExternAccess` arm — but the human `ppResError` key is
-- kept here since it carries the actionable message text.)
-- #242: routed through the canonical O(n·log n) `support.util.dedupBy` (was a
-- private O(n²) `List`-as-a-set scan).  Same key string, same first-occurrence
-- order, so the emitted diagnostic list is unchanged.
dedupResErrors : List ResError -> List ResError
dedupResErrors es = dedupBy resErrorDedupKey es

resErrorDedupKey : ResError -> String
resErrorDedupKey e =
  "\{resErrorCode e}|\{ppResError e}|\{locKey (resErrorLoc e)}"

-- ── resolve_program ───────────────────────────────────────────────────────
-- runtimeDecls = runtime.mdk externs; preludeDecls = core.mdk; prog = target.
export
resolveProgram : List Decl -> List Decl -> List Decl -> List ResError
resolveProgram runtimeDecls preludeDecls prog =
  let env = buildEnv runtimeDecls preludeDecls prog []
  dedupResErrors (buildErrors preludeDecls prog ++ flatMap (checkDecl env) prog)

-- Like resolveProgram but flags references to internal-only externs listed in
-- `internalGuard` (empty ⇒ unrestricted).  The single-file `medaka check` error
-- path passes `internalGuardFor allowInternal`.
export
resolveProgramG2 : List String -> List Decl -> List Decl -> List Decl -> List ResError
resolveProgramG2 internalGuard runtimeDecls preludeDecls prog =
  let env = buildEnv runtimeDecls preludeDecls prog internalGuard
  dedupResErrors (buildErrors preludeDecls prog ++ flatMap (checkDecl env) prog)

-- Human-readable message for a ResError.
-- Used by diagnostics.mdk to produce "error: <msg>" lines.  Loc-independent.
export
ppResError : ResError -> String
ppResError (UnboundVariable n _ s) = match s
  Some sug => "Unbound variable: \{n}. Did you mean '\{sug}'"
    ++ haskellNote n sug
  None => "Unbound variable: \{n}"
ppResError (UnboundVariableExported n m _) =
  "Unbound variable: \{n}. (Did you forget to 'import \{m}.{\{n}}'?)"
ppResError (UnboundVariableIsModule n _) = "Unbound variable: \{n}. '\{n}' is an imported module, not a value — a bare "
  ++ "'import \{n}' binds no names. Bind what you need: 'import \{n}.{name, "
  ++ "...}', or 'import \{n} as M' then 'M.name'"
ppResError (UnknownConstructor n _ s) = match s
  Some sug => "Unknown constructor: \{n}. Did you mean '\{sug}'"
    ++ haskellNote n sug
  None => "Unknown constructor: " ++ n
ppResError (UnknownType n _ s) = match s
  Some sug => "Unknown type: \{n}. Did you mean '\{sug}'" ++ haskellNote n sug
  None => "Unknown type: " ++ n
ppResError (UnknownEffect n _) =
  if n == "Mut" || n == "Panic" then
    "Unknown effect: \{n} — the `Mut`/`Panic` purity labels were removed. Delete the annotation: purity is no longer tracked as an effect label, and effect labels now name host capabilities (`IO`, `Rand`, `FileRead`, …)"
  else
    "Unknown effect: " ++ n
ppResError (UnknownField n _) = "Unknown field: " ++ n
ppResError (FieldNotInRecord f r _) =
  "Unknown field: \{f}. Record '\{r}' has no field '\{f}'"
ppResError (DuplicateDefinition k n _) = "Duplicate \{k}: \{n}"
ppResError (UnknownInterface n _) = "Unknown interface: " ++ n
ppResError (MethodNotInInterface m i _) =
  "Method '\{m}' is not part of interface '\{i}'"
ppResError (ExternWithBody n _) = "Extern '"
  ++ n
  ++ "' must not have a definition body"
ppResError (PrivateNameAccess n m _) =
  "Module '\{m}' has no exported name '\{n}'"
ppResError (NoExportedConstructors n m _) = "'\{n}' exports no constructors from module '\{m}' (exported abstractly). Remove `(..)` or export with `public export`"
ppResError (NewtypeCtorNotExported n m _) = "'\{n}' exports no constructors: a `newtype`'s constructor is always module-private, and `public` is a parse error on `newtype`. Expose it with an accessor function, or declare '\{n}' as a `public export data` with one variant"
ppResError (AbstractFieldAccess t f _) = "'\{t}' is exported abstractly. Field '\{f}' is not accessible; declare it `public export` to expose its fields"
ppResError (UnknownModule n _) = "Unknown module: " ++ n
ppResError (AsPatternMisplaced _) = "`@` as-patterns are only allowed in a binding position (a lambda parameter, a do-block bind, or a match pattern)"
ppResError (NonRecursiveValueLet n _) = "'\{n}' is not in scope in its own binding. Non-function `let` is not recursive; write `let rec \{n} = ...` (RHS must be a lambda)"
ppResError (DuplicateBinding n _) = "Clauses of '\{n}' must be contiguous. An earlier same-named binding is separated by another declaration; group all clauses (and the signature) together"
ppResError (DuplicateValueBinding n _) = "Duplicate binding '\{n}': it is already defined in this scope. A value binding has exactly one definition — rename this one or remove it"
ppResError (DuplicateSignature n _ (Some (Loc _ l _ _ _))) = "'\{n}' is already defined at line \{intToString l}. A name may have only one type signature — rename or remove this duplicate definition, or merge the clauses into a single multi-clause function if that was the intent"
ppResError (DuplicateSignature n _ None) = "'\{n}' is already defined earlier in this file. A name may have only one type signature — rename or remove this duplicate definition, or merge the clauses into a single multi-clause function if that was the intent"
ppResError (DuplicateBinder k n _) = "Duplicate binder: '\{n}' is bound more than once in this \{k}. Each binder must be distinct — rename one occurrence"
ppResError (AmbiguousOccurrence n mods _) = "Ambiguous occurrence: '\{n}' is exported by \{ambigModPhrase mods}. Qualify, or select with `import <mod>.{\{n}}`"
-- No `Type.\{n}` spelling exists (a qualified constructor is a parse error), so the
-- fix is a selective import of ONE owning type: `import <mod>.{T(..)}` — bringing in
-- only that module's constructors — with the other left as a bare `import <mod>` (or
-- without `(..)`), which binds its impls but not its constructors.  Never "qualify".
ppResError (AmbiguousConstructor n mods _) = "Ambiguous constructor: '\{n}' is brought into scope by \{ambigModPhrase mods}. Import the constructors of only one — e.g. `import <mod>.{T(..)}` — and drop the other's `(..)`"
-- Neither remedy the VALUE peer offers exists for a type or an interface, so the
-- copy must not borrow its wording.  "Qualify" is impossible: `import m as A` binds
-- m's VALUES as `A.name`, and an alias-qualified name in TYPE position is a parse
-- error (`docs/spec/SYNTAX.md`, "Import aliasing").  A member alias is impossible
-- too: only a value member may be renamed, so `import m.{Foo as Bar}` is rejected.
-- That leaves exactly one fix — name it, rather than gesture at the two that do not
-- work: import the name from one module and drop it from the other's list.
ppResError (AmbiguousType n mods _) = "Ambiguous type: '\{n}' is brought into scope by \{ambigModPhrase mods}. A type name can be neither qualified nor aliased, so import it from only one — drop '\{n}' from the other's import list"
ppResError (AmbiguousInterface n mods _) = "Ambiguous interface: '\{n}' is brought into scope by \{ambigModPhrase mods}. An interface name can be neither qualified nor aliased, so import it from only one — drop '\{n}' from the other's import list"
ppResError (InternalExternAccess n _) = "'"
  ++ n
  ++ "' is an internal-only primitive. Cannot be used outside the standard library (pass --allow-internal to override)"
-- ⚠️ THE HELP TEXT SAYS THE NARROWING OUT LOUD, DELIBERATELY. This rejects a
-- program shape that compiled before (two interfaces sharing a method name at
-- DISJOINT receivers ran fine), so the message must not pretend the program was
-- always illegal — it says the rule is on the DECLARATION and names the two
-- interfaces plus the fix. The parenthetical bounds the rule: a collision with a
-- PRELUDE method is a different case, ruled a warning-not-error by
-- docs/spec/SHADOW-SEMANTICS.md S1-PRELUDE (#1499), and is NOT what this fires on.
ppResError (DuplicateInterfaceMethod m a b _) = "Method '\{m}' is declared by two interfaces in this module: '\{a}' and '\{b}'. Two interfaces declared together may not share a method name — an occurrence of '\{m}' could not be attributed to either. Rename the method in one of them, or merge the two interfaces. (A method name shared with a PRELUDE interface is a different case and stays legal.)"
ppResError (ReassignImmutable n _) = "Cannot reassign '\{n}' — bindings are immutable. To bind a new value, shadow it with `let \{n} = ...`. For mutable state, use a `Ref`: `let \{n} = Ref 0`, then write `\{n} := !\{n} + 1` (read the cell with `!\{n}`)"

-- Stable diagnostic code (DIAGNOSTIC-CODES-DESIGN §2) for a resolve error — one
-- `R-*` code per ResError constructor.  Authored here (a single chokepoint), so
-- the two ResError→Diag conversion sites need no per-call-site change.  Codes are
-- append-only; never renumber.
export
resErrorCode : ResError -> String
resErrorCode (UnboundVariable _ _ _) = "R-UNBOUND"
resErrorCode (UnboundVariableExported _ _ _) = "R-UNBOUND"
resErrorCode (UnboundVariableIsModule _ _) = "R-UNBOUND"
resErrorCode (UnknownConstructor _ _ _) = "R-UNKNOWN-CTOR"
resErrorCode (UnknownType _ _ _) = "R-UNKNOWN-TYPE"
resErrorCode (UnknownEffect _ _) = "R-UNKNOWN-EFFECT"
resErrorCode (UnknownField _ _) = "R-UNKNOWN-FIELD"
resErrorCode (FieldNotInRecord _ _ _) = "R-FIELD-NOT-IN-RECORD"
resErrorCode (DuplicateDefinition _ _ _) = "R-DUPLICATE-DEF"
resErrorCode (UnknownInterface _ _) = "R-UNKNOWN-INTERFACE"
resErrorCode (MethodNotInInterface _ _ _) = "R-METHOD-NOT-IN-INTERFACE"
resErrorCode (ExternWithBody _ _) = "R-EXTERN-WITH-BODY"
resErrorCode (PrivateNameAccess _ _ _) = "R-PRIVATE-NAME"
resErrorCode (NoExportedConstructors _ _ _) = "R-NO-EXPORTED-CTORS"
resErrorCode (NewtypeCtorNotExported _ _ _) = "R-NEWTYPE-CTOR-PRIVATE"
resErrorCode (AbstractFieldAccess _ _ _) = "R-ABSTRACT-FIELD"
resErrorCode (UnknownModule _ _) = "R-UNKNOWN-MODULE"
resErrorCode (NonRecursiveValueLet _ _) = "R-NONREC-VALUE-LET"
resErrorCode (DuplicateBinding _ _) = "R-DUPLICATE-BINDING"
resErrorCode (DuplicateValueBinding _ _) = "R-DUP-BINDING"
resErrorCode (DuplicateSignature _ _ _) = "R-DUPLICATE-SIGNATURE"
resErrorCode (DuplicateBinder _ _ _) = "R-DUP-BINDER"
resErrorCode (AsPatternMisplaced _) = "R-AS-PATTERN-MISPLACED"
resErrorCode (AmbiguousOccurrence _ _ _) = "R-AMBIGUOUS-OCCURRENCE"
resErrorCode (AmbiguousConstructor _ _ _) = "R-AMBIGUOUS-CTOR"
resErrorCode (AmbiguousType _ _ _) = "R-AMBIGUOUS-TYPE"
resErrorCode (AmbiguousInterface _ _ _) = "R-AMBIGUOUS-INTERFACE"
resErrorCode (InternalExternAccess _ _) = "R-INTERNAL-EXTERN"
resErrorCode (ReassignImmutable _ _) = "R-IMMUTABLE-ASSIGN"
resErrorCode (DuplicateInterfaceMethod _ _ _ _) = "R-DUPLICATE-IFACE-METHOD"

-- Two modules → "both `a` and `b`";
-- otherwise a comma-separated list of backtick-quoted module names.
ambigModPhrase : List String -> String
ambigModPhrase (a::b::[]) = "both `\{a}` and `\{b}`"
ambigModPhrase mods = joinWith ", " (map (m => "`" ++ m ++ "`") mods)

-- one human-readable error message per line (the harness sorts)
export
resolveToLines : List Decl -> List Decl -> List Decl -> String
resolveToLines runtimeDecls preludeDecls prog =
  joinNl (map ppResError (resolveProgram runtimeDecls preludeDecls prog))

-- ── Single-file import validation ─────────────────────────────────────────
-- In single-file mode the loader is absent, so resolve_program stubs unknown
-- imports into scope.
-- This function catches DUse declarations that reference a non-core module and
-- emits UnknownModule — used by check.mdk BEFORE running resolveToLines so the
-- pipeline halts with the correct error category rather than falling through to
-- a spurious typecheck "Unbound variable".
export
singleFileImportErrors : List Decl -> List ResError
singleFileImportErrors [] = []
singleFileImportErrors ((DUse _ path _)::rest) =
  let mid = useModId path
  if mid == "core" || mid == "" then
    singleFileImportErrors rest
  else
    UnknownModule mid None :: singleFileImportErrors rest
singleFileImportErrors (_::rest) = singleFileImportErrors rest

-- ══════════════════════════════════════════════════════════════════════════
-- Multi-module path.
--
-- Resolves one module against the EXPORTS of previously-resolved modules
-- (dependency-first), so imports are validated against what a module actually
-- makes public — the privacy / abstract-ctor / unknown-module checks the
-- single-file path stubs out (PrivateNameAccess / NoExportedConstructors /
-- UnknownModule).  `buildExports` then computes this module's own public
-- interface, threaded into the next module's `known` set by the driver.
-- ══════════════════════════════════════════════════════════════════════════

-- The public interface of a resolved module
-- (exp_fields is dropped — consumers only read field OWNERS).
public export data ModuleExports = ModuleExports {
    modId : String,
    expValues : List String,
    expTypes : List String,
    expCtors : List String,
    expTypeCtors : List (String, List String),
    expFieldOwners : List (String, String),
    expInterfaces : List String,
    expIfaceMethods : List (String, List String),
    expEffects : List String,  -- exported effect labels (Phase 146)
    -- (ctorName, typeName) pairs for `export newtype` decls (#1311) — a
    -- newtype's ctor is unconditionally module-private (typecheck's
    -- `publicDataDecls` never publishes it), so unlike `expCtors`/
    -- `expTypeCtors` this table exists ONLY to let the import path refuse it
    -- with a located, explanatory diagnostic instead of silently admitting it
    -- and leaving typecheck to fail with a bare `Unbound variable`.
    expNewtypeCtors : List (String, String),
  }
-- public type → its exported ctors
-- (field, owner type/ctor)

-- iface → method names

-- ── small generic helpers ──────────────────────────────────────────────────
-- keep the elements of `names` that are members of `domain`
filterContains : List String -> List String -> List String
filterContains _ [] = []
filterContains domain (n::rest)
  | contains n domain = n :: filterContains domain rest
  | otherwise = filterContains domain rest

-- same as `filterContains`, but `domain` is an OrdMap-backed set (O(log n)
-- `omHasKey` per element instead of `filterContains`'s O(n) `contains`).
filterInSet : OrdMap Unit -> List String -> List String
filterInSet _ [] = []
filterInSet domain (n::rest)
  | omHasKey n domain = n :: filterInSet domain rest
  | otherwise = filterInSet domain rest

-- #926: `known` is now a Map keyed by module id (was a `List ModuleExports`
-- scanned linearly, O(N) per import → O(N^2) on a star import that resolves N
-- imports against an N-long list).  `omLookup` is O(log N).  Byte-identical: module
-- ids are unique across a module list, so the single keyed entry is exactly what the
-- old first-match scan returned; and even under a (spurious) duplicate id the driver's
-- `omInsert exp.modId exp known` is last-write-wins, matching the old `exp :: known`
-- prepend + front-to-back scan (both return the most-recently-added module).
findExports : String -> OrdMap ModuleExports -> Option ModuleExports
findExports mid known = omLookup mid known

-- exported under any value/type/ctor/interface category (lib's imported_names is_pub)
isPubExp : ModuleExports -> String -> Bool
isPubExp exp n = contains n exp.expValues
  || contains n exp.expTypes
  || contains n exp.expCtors
  || contains n exp.expInterfaces

typeCtorsOf : String -> ModuleExports -> Option (List String)
typeCtorsOf name exp = lookupAssoc name exp.expTypeCtors

-- newtype's type name, if `name` is that newtype's exported ctor (#1311).
newtypeTypeOfCtor : String -> ModuleExports -> Option String
newtypeTypeOfCtor name exp = lookupAssoc name exp.expNewtypeCtors

-- is `name` a `newtype` this module exports (checked by TYPE name, for `T(..)`)?
isNewtypeExport : String -> ModuleExports -> Bool
isNewtypeExport name exp = contains name (map snd exp.expNewtypeCtors)

-- ── usePaths / pubUsePaths ─────────────────────────────────────────────────
usePathsOf : List Decl -> List UsePath
usePathsOf [] = []
usePathsOf ((DUse _ path _)::rest) = path :: usePathsOf rest
usePathsOf (_::rest) = usePathsOf rest

-- Like usePathsOf but keeps each import's own source Loc alongside its path —
-- used only by the collectImports chain, which attaches the loc to any
-- privacy/abstract-ctor error it raises (F3 Chunk B: real range instead of the
-- dummy {0,0}/`<unknown location>`).
usePathLocsOf : List Decl -> List (UsePath, Loc)
usePathLocsOf [] = []
usePathLocsOf ((DUse _ path loc)::rest) = (path, loc) :: usePathLocsOf rest
usePathLocsOf (_::rest) = usePathLocsOf rest

pubUsePaths : List Decl -> List UsePath
pubUsePaths [] = []
pubUsePaths ((DUse True path _)::rest) = path :: pubUsePaths rest
pubUsePaths (_::rest) = pubUsePaths rest

-- ── imported_names + expand_member ─────────────────────────────────────────
-- Names a use-path brings into scope, plus the privacy / abstract-ctor errors.
importedNamesMM : UsePath -> ModuleExports -> (List String, List ResError)
importedNamesMM (UseName ns) exp =
  if listLen ns > 1 then
    let nm = lastOf ns
    ([nm], pubErr exp nm)
  else ([], [])
importedNamesMM (UseGroup _ members) exp =
  let expanded = flatMap (expandMemberNames exp) members
  let names = map localOfExpanded expanded
  let expandErrs = flatMap (expandMemberErrs exp) members
  (names, expandErrs ++ flatMap (pubErrExpanded exp) expanded)
-- #1311: `.*` silently excludes a private newtype's ctor from `expCtors` —
-- same silent treatment a VisAbstract data type's ctors already get here (they
-- are simply never IN `expCtors` to begin with).  No diagnostic on a wildcard
-- import: the user never named the ctor, so there is no import member to
-- locate a refusal on — same reasoning `.*` already applies to abstract data.
importedNamesMM (UseWild _) exp = (
  exp.expValues ++ exp.expTypes ++ filterList (c => not (contains c (map fst exp.expNewtypeCtors))) exp.expCtors,
  [],
)
-- `import m as A` binds m's exported VALUES as `A.name`, and nothing unqualified.
-- Values only: a qualified reference parses as a field access, whose field must be
-- lowercase, so `A.SomeType` / `A.SomeCtor` cannot be spelled at all (it is a parse
-- error, not a silent miss).  Types and ctors are imported with `import m.{T(..)}`.
importedNamesMM (UseAlias _ a) exp = (map (qualifiedLocal a) exp.expValues, [])

pubErr : ModuleExports -> String -> List ResError
pubErr exp n =
  if isPubExp exp n then
    []
  else
    [PrivateNameAccess n exp.modId None]

-- Like pubErr but carries the offending member's own source Loc (from a
-- UseGroup member) so the diagnostic squiggles just that name, not the whole
-- import statement (RESOLVER-DIAG-LOCATION-DESIGN.md F3 follow-up).
pubErrLoc : ModuleExports -> (String, Loc) -> List ResError
pubErrLoc exp (n, loc) =
  if isPubExp exp n then
    []
  else
    [PrivateNameAccess n exp.modId (Some loc)]

-- expand_member: `T(..)` → the type plus its exported ctors; a plain member is
-- itself.  `T(..)` on an abstractly-exported type is a NoExportedConstructors.
-- Each expanded name carries the source member's own Loc (ctors expanded from
-- `T(..)` inherit T's member loc).
--
-- Each entry is (ORIGIN, LOCAL, loc).  They differ only under a member alias
-- (`import m.{a as b}` → origin `a`, local `b`): the privacy check must ask about the
-- ORIGIN (that is the name m exports), while scope binds the LOCAL.  Conflating the
-- two would make `import m.{privateThing as x}` silently legal.  Ctors expanded from
-- `T(..) as U` keep their OWN names — one alias cannot rename N constructors.
-- #1311: a `newtype`'s ctor is unconditionally module-private (typecheck's
-- `publicDataDecls` never publishes it, and `public newtype` is a parse
-- error — there is no spelling that exports it).  `expNewtypeCtors` still
-- lets resolve's OTHER tables (`expCtors`/`expTypeCtors`) see it, so both
-- arms below refuse it explicitly rather than let it fall through to the
-- generic paths, which would silently admit it exactly as #1311 found.
expandMemberNames : ModuleExports -> UseMember -> List (String, String, Loc)
expandMemberNames exp (m@(UseMember name False loc _)) = match newtypeTypeOfCtor name exp
  Some _ => []  -- refused; see expandMemberErrs
  None => [(name, useMemberLocal m, loc)]
expandMemberNames exp (m@(UseMember name True loc _))
  | isNewtypeExport name exp =
    -- keep the TYPE name bound (mirrors abstract `data`: `NT` itself is
    -- still importable, only its ctor is refused) but do NOT expand to the ctor.
    [(name, useMemberLocal m, loc)]
  | otherwise = match typeCtorsOf name exp
    Some ctors => (name, useMemberLocal m, loc) :: map (c => (c, c, loc)) ctors
    None => [(name, useMemberLocal m, loc)]

localOfExpanded : (String, String, Loc) -> String
localOfExpanded (_, local, _) = local

-- privacy is checked against the ORIGIN name, with the member's own Loc.
pubErrExpanded : ModuleExports -> (String, String, Loc) -> List ResError
pubErrExpanded exp (origin, _, loc) = pubErrLoc exp (origin, loc)

expandMemberErrs : ModuleExports -> UseMember -> List ResError
expandMemberErrs exp (UseMember name False loc _) = match newtypeTypeOfCtor name exp
  Some tyName => [NewtypeCtorNotExported tyName exp.modId (Some loc)]
  None => []
expandMemberErrs exp (UseMember name True loc _)
  | isNewtypeExport name exp =
    [NewtypeCtorNotExported name exp.modId (Some loc)]
  | otherwise = match typeCtorsOf name exp
    Some _ => []
    None =>
      if contains name exp.expTypes then
        [NoExportedConstructors name exp.modId (Some loc)]
      else
        []

-- ── import contributions to the env ────────────────────────────────────────
public export data ImportAdds =
  | ImportAdds {
      iaImported : List String,
      iaValues : List String,
      iaTypes : List String,
      iaCtors : List String,
      iaIfaces : List String,
      iaFieldOwners : List (String, String),
      iaErrors : List ResError,
    }

emptyAdds : ImportAdds
emptyAdds = ImportAdds {
  iaImported = [],
  iaValues = [],
  iaTypes = [],
  iaCtors = [],
  iaIfaces = [],
  iaFieldOwners = [],
  iaErrors = [],
}

mergeAdds : ImportAdds -> ImportAdds -> ImportAdds
mergeAdds a b = ImportAdds {
  iaImported = a.iaImported ++ b.iaImported,
  iaValues = a.iaValues ++ b.iaValues,
  iaTypes = a.iaTypes ++ b.iaTypes,
  iaCtors = a.iaCtors ++ b.iaCtors,
  iaIfaces = a.iaIfaces ++ b.iaIfaces,
  iaFieldOwners = a.iaFieldOwners ++ b.iaFieldOwners,
  iaErrors = a.iaErrors ++ b.iaErrors,
}

collectImports : OrdMap ModuleExports -> List Decl -> ImportAdds
collectImports known prog = foldImports known (usePathLocsOf prog)

-- ── use-time ambiguity (MAP-SET-AMBIGUITY-DESIGN.md) ───────────────────────
-- The VALUE names a single non-core import contributes, attributed to its
-- DIRECTLY-imported module id (not the original definer → re-export safe).
importValueNames : OrdMap ModuleExports -> UsePath -> List String
importValueNames known path =
  if useModId path == "core" then []
  else match findExports (useModId path) known
    None => []
    Some exp =>
      let (names, _) = importedNamesMM path exp
      -- #925: `exp.expValues` GROWS with re-export depth, so the old
      -- `filterContains` (O(len) per name) is O(depth^2) per module → cubic over the
      -- re-export chain.  An OrdMap membership set makes it O(len log len) and — the
      -- point for the op-count arm — routes the per-name test through `omHasKey`
      -- instead of the counted `contains`, byte-identically (same kept names, order).
      filterInSet (omFromNames exp.expValues omEmpty) names

-- Register one (name, mid) into a name→[mid] MAP, deduping mids (mids kept in
-- append order).  #925/#926: this was a `List (String, List String)` assoc rescanned
-- per name (`addProvenance rest` rebuilds the spine to find the key) → O(names^2) per
-- module → CUBIC ALLOC over an `export import m.*` re-export chain (each module's
-- provenance grows with depth).  An OrdMap keyed by name makes each insert O(log n).
-- Byte-identical: `omLookup`/`omInsert` preserve exactly the (name → append-ordered,
-- deduped mids) association the old assoc built; only the map's key ORDER differs from
-- insertion order, and provenance is consumed ONLY by `lookupAssoc` (isAmbiguous /
-- ambigMods and their ctor peers), which is order-independent.
addProvenance : OrdMap (List String) -> String -> String -> OrdMap (List String)
addProvenance prov n mid = match omLookup n prov
  None => omInsert n [mid] prov
  Some mids =>
    if contains mid mids then
      prov
    else
      omInsert n (mids ++ [mid]) prov

-- Fold the value names of one import (all tagged with the same mid) into prov.
addImportProvenance : OrdMap (List String) -> String -> List String -> OrdMap (List String)
addImportProvenance prov _ [] = prov
addImportProvenance prov mid (n::rest) =
  addImportProvenance (addProvenance prov n mid) mid rest

-- Provenance over every non-core import in the program, in decl order
-- (left-to-right, so mod-id order matches declaration order).
valueProvenance : OrdMap ModuleExports -> List UsePath -> OrdMap (List String)
valueProvenance known paths = foldProvenance known omEmpty paths

foldProvenance : OrdMap ModuleExports -> OrdMap (List String) -> List UsePath -> OrdMap (List String)
foldProvenance _ prov [] = prov
foldProvenance known prov (p::rest) =
  let mid = useModId p
  let prov2 = if mid == "core" then
    prov
  else
    addImportProvenance prov mid (importValueNames known p)
  foldProvenance known prov2 rest

-- Materialize the name→mids provenance map into the (name, mids) assoc that
-- `keepAmbiguous` filters and `env.ambiguous`/`env.ctorAmbiguous` store.  Key order is
-- sorted (`omKeys`) rather than first-occurrence, which is byte-equivalent downstream
-- because every consumer looks names up by key (`lookupAssoc`), never iterates in order.
provToPairs : OrdMap (List String) -> List (String, List String)
provToPairs prov = map (k => (k, provMidsOf k prov)) (omKeys prov)

provMidsOf : String -> OrdMap (List String) -> List String
provMidsOf k prov = match omLookup k prov
  Some mids => mids
  None => []

-- Keep only names with ≥2 distinct provenances AND no same-module top-level
-- value shadow (a real local def wins).
ambiguousSet : OrdMap ModuleExports -> List Decl -> List (String, List String)
ambiguousSet known prog =
  let prov = valueProvenance known (usePathsOf prog)
  let sameMod = userValueNames prog
  keepAmbiguous sameMod (provToPairs prov)

keepAmbiguous : List String -> List (String, List String) -> List (String, List String)
keepAmbiguous _ [] = []
keepAmbiguous sameMod ((n, mids)::rest)
  | listLen mids >= 2 && not (contains n sameMod) =
    (n, mids) :: keepAmbiguous sameMod rest
  | otherwise = keepAmbiguous sameMod rest

-- ── constructor-name provenance / ambiguity (#674) ─────────────────────────
-- The exact ctor peer of valueProvenance/ambiguousSet.  Each import contributes
-- the CONSTRUCTOR names it actually binds (a bare `import m` binds NONE — impls
-- only; a selective `import m.{T(..)}` binds T's exported ctors; `import m.*`
-- binds all of m's ctors), attributed to its DIRECTLY-imported module id.  A ctor
-- brought in by ≥2 distinct modules AND not defined locally is AMBIGUOUS: the same
-- name resolves to different modules' constructors, so load/import order (the two
-- check-side resolvers' opposite tie-breaks) can no longer decide it silently.

-- the CONSTRUCTOR names one non-core import contributes, attributed to its
-- directly-imported module id (re-export safe, like importValueNames).
importCtorNames : OrdMap ModuleExports -> UsePath -> List String
importCtorNames known path =
  if useModId path == "core" then []
  else match findExports (useModId path) known
    None => []
    Some exp =>
      let (names, _) = importedNamesMM path exp
      -- #925: same growing-export-list cubic as importValueNames, via expCtors.
      filterInSet (omFromNames exp.expCtors omEmpty) names

ctorProvenance : OrdMap ModuleExports -> List UsePath -> OrdMap (List String)
ctorProvenance known paths = foldCtorProvenance known omEmpty paths

foldCtorProvenance : OrdMap ModuleExports -> OrdMap (List String) -> List UsePath -> OrdMap (List String)
foldCtorProvenance _ prov [] = prov
foldCtorProvenance known prov (p::rest) =
  let mid = useModId p
  let prov2 = if mid == "core" then
    prov
  else
    addImportProvenance prov mid (importCtorNames known p)
  foldCtorProvenance known prov2 rest

-- Keep only ctor names bound by ≥2 distinct modules AND not defined by a
-- same-module top-level `data`/`newtype` (a real local ctor wins).
ctorAmbiguousSet : OrdMap ModuleExports -> List Decl -> List (String, List String)
ctorAmbiguousSet known prog =
  let prov = ctorProvenance known (usePathsOf prog)
  let sameMod = ctorNames prog
  keepAmbiguous sameMod (provToPairs prov)

-- ── type-name / interface-name provenance / ambiguity (#1110) ───────────────
-- The TYPE and INTERFACE peers of the two blocks above, deliberately built from
-- the same three parts (`importedNamesMM` → a namespace filter → `keepAmbiguous`)
-- so all four ambiguity sets have ONE trigger and cannot drift into four rules.
--
-- 🚨 WHAT THIS TRIGGER IS, AND WHAT IT IS NOT.  It is a SCOPE collision: ≥2
-- distinct non-`core` import provenances for one name, visible in THIS module's
-- scope.  It is NOT a TABLE collision — two modules with no import relationship
-- that each declare the same bare name never meet in one scope, so no use-site
-- diagnostic, present or future, has anything to fire on for that shape.  #1047 /
-- #1070 / #1092 are that shape (verified from #1047's own fixture, whose `main.mdk`
-- never imports the colliding interface at all); they are drained by Stage A-2's
-- registry re-keying, NOT by anything in this file.  Do not claim otherwise.
--
-- ⚠️ PROVENANCE IS THE DIRECTLY-IMPORTED MODULE, NOT THE DEFINER — so one
-- declaration reached through two import paths counts as TWO, and is reported.
-- That is not an oversight and it is not new: MEASURED on the shipped VALUE peer
-- before this was written (`import b.{dup}` + `import c.{dup}` where `c` is
-- `export import b.{dup}` → `Ambiguous occurrence: 'dup' is exported by both 'b'
-- and 'c'`).  The definer IS recoverable here — `keepTypeOrigins` does exactly
-- that lookup — but using it would make the type/interface peers reject a shape the
-- value peer accepts and accept a shape it rejects, on the SAME import lines.  One
-- rule for all four namespaces is worth more than a narrower rule for two of them;
-- if that rule should change it should change for all four at once.
--
-- The one asymmetry with the ctor peer is which local declarations settle the name
-- (`dataRecordNames` vs `interfaceNamesOf` vs `ctorNames`), because that is what
-- "declared in this module" means per namespace.

-- The TYPE names one non-core import contributes, attributed to its
-- directly-imported module id.  Mirrors `importCtorNames` through `expTypes`.
importTypeNames : OrdMap ModuleExports -> UsePath -> List String
importTypeNames known path = importNamesIn expTypesOf known path

-- The INTERFACE names one non-core import contributes.  ⚠️ `import m.*` contributes
-- NONE, because `importedNamesMM`'s `UseWild` arm lists values/types/ctors and not
-- interfaces — so a wildcard-imported interface is not in `env.interfaces` either
-- (`realImport`'s `iaIfaces` filters the same list).  Reading the same source keeps
-- the ambiguity set a subset of what is actually in scope, which is the property
-- that matters: this must never flag a name resolve did not bind.
importIfaceNames : OrdMap ModuleExports -> UsePath -> List String
importIfaceNames known path = importNamesIn expInterfacesOf known path

expTypesOf : ModuleExports -> List String
expTypesOf exp = exp.expTypes

expInterfacesOf : ModuleExports -> List String
expInterfacesOf exp = exp.expInterfaces

-- Shared body of the two above: the names one use path binds, narrowed to one
-- export namespace.  `filterInSet` (not `filterContains`) for the same reason
-- `importCtorNames` uses it — an `export import m.*` chain grows both lists with
-- depth, and an O(n) membership test there is the #925 cubic.
importNamesIn : (ModuleExports -> List String) -> OrdMap ModuleExports -> UsePath -> List String
importNamesIn nsOf known path =
  if useModId path == "core" then []
  else match findExports (useModId path) known
    None => []
    Some exp =>
      let (names, _) = importedNamesMM path exp
      filterInSet (omFromNames (nsOf exp) omEmpty) names

foldNamespaceProvenance : (OrdMap ModuleExports -> UsePath -> List String) -> OrdMap ModuleExports -> OrdMap (List String) -> List UsePath -> OrdMap (List String)
foldNamespaceProvenance _ _ prov [] = prov
foldNamespaceProvenance namesOf known prov (p::rest) =
  let mid = useModId p
  let prov2 = if mid == "core" then
    prov
  else
    addImportProvenance prov mid (namesOf known p)
  foldNamespaceProvenance namesOf known prov2 rest

-- Keep only type names bound by ≥2 distinct modules AND not declared by a
-- same-module `data`/`newtype`/`type` (a real local declaration wins, exactly as it
-- does for values and ctors — see `tyOriginScope`'s precedence argument, which
-- states the same rule for identity).
typeAmbiguousSet : OrdMap ModuleExports -> List Decl -> List (String, List String)
typeAmbiguousSet known prog =
  let prov = foldNamespaceProvenance importTypeNames known omEmpty (usePathsOf prog)
  keepAmbiguous (dataRecordNames prog) (provToPairs prov)

-- The interface peer.  `interfaceNamesOf` (not `map fst (interfaceList prog)`) is
-- the local-declaration set, because it has the `DAttrib` arm — an `@attr`-wrapped
-- `interface` still settles its own name.
ifaceAmbiguousSet : OrdMap ModuleExports -> List Decl -> List (String, List String)
ifaceAmbiguousSet known prog =
  let prov = foldNamespaceProvenance importIfaceNames known omEmpty (usePathsOf prog)
  keepAmbiguous (interfaceNamesOf prog) (provToPairs prov)

foldImports : OrdMap ModuleExports -> List (UsePath, Loc) -> ImportAdds
foldImports _ [] = emptyAdds
foldImports known ((p, loc)::rest) =
  mergeAdds (oneImport known p loc) (foldImports known rest)

oneImport : OrdMap ModuleExports -> UsePath -> Loc -> ImportAdds
oneImport known path loc =
  let mid = useModId path
  -- `core` binds NOTHING here: it is the implicit prelude, so every one of its names
  -- is already in scope in every module (buildEnvMM seeds them from preludeDecls).  A
  -- core use-path is a no-op for SCOPE — it documents intent, and (with `export`) widens
  -- this module's export surface.  Its members are still VALIDATED, but in `buildErrors`
  -- (see coreUseErrors), which is the one pass BOTH resolve paths run — validating here
  -- would leave the single-file path, and therefore a lone `medaka check <exporter>.mdk`,
  -- silent.
  if mid == "core" then emptyAdds
  else match findExports mid known
    None => stubOrUnknown known path mid loc
    Some exp => realImport exp path loc

-- module not in `known`: in multi-module mode (known non-empty) this is an
-- UnknownModule; the first module (known empty) keeps the single-file stub.
stubOrUnknown : OrdMap ModuleExports -> UsePath -> String -> Loc -> ImportAdds
stubOrUnknown known path mid loc =
  -- #926: `known` is a Map now; "any prior module known" is `omSize known > 0`
  -- (was `isNonEmpty` on the list).  Same predicate: the first module resolves with
  -- an empty index (single-file stub); every later one has a non-empty index.
  if omSize known > 0 then ImportAdds {
    iaImported = [],
    iaValues = [],
    iaTypes = [],
    iaCtors = [],
    iaIfaces = [],
    iaFieldOwners = [],
    iaErrors = [UnknownModule mid (Some loc)],
  }
  else
    let names = useStubNames path
    ImportAdds {
      iaImported = names,
      iaValues = names,
      iaTypes = names,
      iaCtors = [],
      iaIfaces = [],
      iaFieldOwners = [],
      iaErrors = [],
    }

realImport : ModuleExports -> UsePath -> Loc -> ImportAdds
realImport exp path loc =
  let (names, errs) = importedNamesMM path exp
  ImportAdds {
    iaImported = names,
    -- #925: a wildcard `export import m.*` re-export makes both `names` and
    -- `exp.expValues` grow with depth, so this filter is O(depth^2) per module →
    -- cubic over the chain.  Index the (growing) value set once; `filterInSet`'s
    -- `omHasKey` is uncounted and byte-identical to the `contains` filter.
    iaValues = filterInSet (omFromNames exp.expValues omEmpty) names,
    iaTypes = filterContains exp.expTypes names,
    iaCtors = filterContains exp.expCtors names,
    iaIfaces = filterContains exp.expInterfaces names,
    iaFieldOwners = ownedFieldOwners exp exp.expFieldOwners,
    iaErrors = map (withResErrorLoc loc) errs,
  }

-- Attach a real Loc to a ResError that was constructed with `None` (some
-- privacy/abstract-ctor errors — e.g. from the bare `UseName` case in
-- importedNamesMM — carry no loc of their own, only the ModuleExports, not
-- the importing DUse's span). Errors from a UseGroup member (pubErrLoc /
-- expandMemberErrs) already carry that member's own `Some` loc — PRESERVE it
-- rather than clobbering with the whole-statement loc, so the diagnostic
-- squiggles just the offending name.
withResErrorLoc : Loc -> ResError -> ResError
withResErrorLoc loc (PrivateNameAccess n m None) =
  PrivateNameAccess n m (Some loc)
withResErrorLoc _ (PrivateNameAccess n m (Some l)) =
  PrivateNameAccess n m (Some l)
withResErrorLoc loc (NoExportedConstructors n m None) =
  NoExportedConstructors n m (Some loc)
withResErrorLoc _ (NoExportedConstructors n m (Some l)) =
  NoExportedConstructors n m (Some l)
withResErrorLoc _ e = e

-- field-ownership pairs whose owner is an exported type/ctor (copied into scope
-- so field access / record patterns over imported records resolve)
ownedFieldOwners : ModuleExports -> List (String, String) -> List (String, String)
ownedFieldOwners _ [] = []
ownedFieldOwners exp ((f, o)::rest)
  | contains o exp.expTypes || contains o exp.expCtors =
    (f, o) :: ownedFieldOwners exp rest
  | otherwise = ownedFieldOwners exp rest

-- iface-method memberships for imported interfaces (so an `impl` of an imported
-- interface validates against its real method set — Phase 130).
--
-- #1269: this used to filter each import's `expIfaceMethods` against the
-- PROGRAM-WIDE `baseIfaces` bare-name list (prelude + user + every import's
-- imported-by-name interfaces, flattened together).  That is the same disease
-- `AGENTS.md` names for the `universe*` tables: a bare interface NAME has no
-- module scope, so once ANY import in the file brought a name like `Same`
-- into `baseIfaces`, EVERY OTHER imported module's `Same` — even one never
-- named by this file's own imports — matched that membership test and got
-- spliced into `impIfaceMethods` too.  `ifaceMethodsOf` (first-match) then
-- validated an `impl`'s methods against whichever module's `Same` happened to
-- sort first in `usePathsOf prog`, rejecting a complete, correct `impl` with
-- `R-METHOD-NOT-IN-INTERFACE` naming a method it does implement
-- (`test/analyze_project_fixtures/1269_ifacemethods_genuine_rejects/`).
--
-- The fix: scope each import path to the interface names THAT PATH ITSELF
-- actually binds (`importIfaceNames known path` — the same per-path
-- provenance `ifaceAmbiguousSet` already uses to decide real ambiguity)
-- instead of the flattened whole-program set.  `import gmod.{gdummy}`
-- contributes nothing to `impIfaceMethods` no matter what else `gmod`
-- exports; `import pmod.{Same, pmth}` contributes exactly `pmod`'s `Same`.
-- No import statement's contribution depends on what any OTHER import
-- statement named — but the table underneath is still bare-name-keyed and
-- `ifaceMethodsOf` is still first-match, so when TWO import paths genuinely
-- bind the SAME interface name (an actually ambiguous import, not this
-- fix's target shape) the method-membership verdict is still
-- order-dependent. That residual is never SILENT: a genuine cross-module
-- name collision of that shape is always also flagged by
-- `ambiguousIfaceErrors` (`AmbiguousInterface`), which does not depend on
-- import order, so the order-dependent diagnostic never appears alone.
importedIfaceMethods : OrdMap ModuleExports -> List Decl -> List (String, List String)
importedIfaceMethods known prog =
  flatMap (oneImportIfaceMethods known) (usePathsOf prog)

oneImportIfaceMethods : OrdMap ModuleExports -> UsePath -> List (String, List String)
oneImportIfaceMethods known path =
  let mid = useModId path
  if mid == "core" then []
  else match findExports mid known
    None => []
    Some exp =>
      filterIfaceMethods (importIfaceNames known path) exp.expIfaceMethods

filterIfaceMethods : List String -> List (String, List String) -> List (String, List String)
filterIfaceMethods _ [] = []
filterIfaceMethods pathIfaces ((iface, ms)::rest)
  | contains iface pathIfaces =
    (iface, ms) :: filterIfaceMethods pathIfaces rest
  | otherwise = filterIfaceMethods pathIfaces rest

-- Install exported effect labels from all imported modules (Phase 146).
importedEffects : OrdMap ModuleExports -> List Decl -> List String
importedEffects known prog = flatMap (oneImportEffects known) (usePathsOf prog)

oneImportEffects : OrdMap ModuleExports -> UsePath -> List String
oneImportEffects known path =
  let mid = useModId path
  if mid == "core" then []
  else match findExports mid known
    None => []
    Some exp => exp.expEffects

-- ── buildEnv (multi-module): like buildEnv but validating imports ──────────
buildEnvMM : List Decl -> List Decl -> OrdMap ModuleExports -> List Decl -> List String -> (Env, List ResError)
buildEnvMM runtimeDecls preludeDecls known prog internalGuard =
  let seed = not (programIsCore prog)
  let pTypes = whenL seed (dataRecordNames preludeDecls)
  let pCtors = whenL seed (ctorNames preludeDecls)
  let pIfaces = whenL seed (interfaceList preludeDecls)
  let pValues = whenL seed (preludeValueNames preludeDecls)
  let pFieldOwners = whenL seed (fieldOwnersOf preludeDecls)
  let uIfaces = interfaceList prog
  let adds = collectImports known prog
  let baseIfaces = map fst pIfaces ++ map fst uIfaces ++ adds.iaIfaces
  let impIfaceMethods = importedIfaceMethods known prog
  let impEffects = importedEffects known prog
  let impModValues = importedModuleValueSets known prog
  let valuesM = omFromNames (externNames runtimeDecls ++ pValues ++ userValueNames prog ++ adds.iaValues) omEmpty
  let typesM = omFromNames (primitiveTypes ++ pTypes ++ dataRecordNames prog ++ adds.iaTypes) omEmpty
  let ctorsM = omFromNames (primitiveConstructors ++ pCtors ++ ctorNames prog ++ adds.iaCtors) omEmpty
  let importedM = omFromNames adds.iaImported omEmpty
  let env = Env {
    values = valuesM,
    types = typesM,
    ctors = ctorsM,
    fields = map fst pFieldOwners ++ map fst (fieldOwnersOf prog) ++ map fst adds.iaFieldOwners,
    fieldOwners = pFieldOwners ++ fieldOwnersOf prog ++ adds.iaFieldOwners,
    fieldOwnersIdx = buildFieldOwnerIndex (pFieldOwners ++ fieldOwnersOf prog ++ adds.iaFieldOwners),
    interfaces = baseIfaces,
    ifaceMethods = pIfaces ++ uIfaces ++ impIfaceMethods,
    effects = effectNames prog ++ impEffects,
    imported = importedM,
    importedModuleValues = impModValues,
    ambiguous = ambiguousSet known prog,
    ctorAmbiguous = ctorAmbiguousSet known prog,
    typeAmbiguous = typeAmbiguousSet known prog,
    ifaceAmbiguous = ifaceAmbiguousSet known prog,
    internalGuard = omFromNames internalGuard omEmpty,
    sugValues = sugPoolOf (omKeys valuesM ++ omKeys ctorsM ++ omKeys importedM),
    sugTypes = sugPoolOf (omKeys typesM ++ omKeys importedM),
  }
  (env, adds.iaErrors)

-- (modId, expValues) pairs for every non-`core` import in the program,
-- regardless of import form (bare `UseName`, selective `UseGroup`, wildcard) —
-- used only to answer "is this unbound name exported by a module I already
-- import?" (audit #5), not to bind any names into scope.
importedModuleValueSets : OrdMap ModuleExports -> List Decl -> List (String, List String)
importedModuleValueSets known prog =
  flatMap (oneImportedModuleValues known) (usePathsOf prog)

oneImportedModuleValues : OrdMap ModuleExports -> UsePath -> List (String, List String)
oneImportedModuleValues known path =
  let mid = useModId path
  if mid == "core" then []
  else match findExports mid known
    None => []
    Some exp => [(mid, exp.expValues)]

-- ── core's export surface ──────────────────────────────────────────────────
-- The prelude, viewed as a ModuleExports, so a `core` use-path can be resolved
-- and VALIDATED exactly like any other module's (see overPubUse / coreUseErrors).
--
-- core is never in the driver's `known` list — it is prepended to every module,
-- not imported — so every `mid == "core"` site had to answer "what does core
-- export?" and none could.  They all answered "nothing", which is why an
-- `export import core.{…}` exported nothing AND said nothing.
--
-- Built from the SAME extractors `buildEnvMM` uses to seed prelude names into
-- scope (preludeValueNames / dataRecordNames / ctorNames / interfaceList / …), so
-- "what core exports" is by construction "what core puts in scope".  The prelude
-- ignores visibility markers — every core name is in scope in every module — so
-- its export surface is all of it.
coreExports : List Decl -> ModuleExports
coreExports preludeDecls = ModuleExports {
  modId = "core",
  expValues = preludeValueNames preludeDecls,
  expTypes = dataRecordNames preludeDecls,
  expCtors = ctorNames preludeDecls,
  expTypeCtors = typeCtorsAllOf preludeDecls,
  expFieldOwners = fieldOwnersOf preludeDecls,
  expInterfaces = map fst (interfaceList preludeDecls),
  expIfaceMethods = interfaceList preludeDecls,
  expEffects = effectNames preludeDecls,
  expNewtypeCtors = [],  -- the prelude declares no `newtype` today; nothing to refuse
}

-- type → its ctors, ignoring visibility (the vis-filtered `expTypeCtorsDirect` is
-- for a real module's public surface; the prelude has no private names).  Feeds
-- `T(..)` expansion for `import core.{Option(..)}`.
typeCtorsAllOf : List Decl -> List (String, List String)
typeCtorsAllOf [] = []
typeCtorsAllOf ((DNewtype { newtypeName = n, newtypeCtor = con })::rest) =
  (n, [con]) :: typeCtorsAllOf rest
typeCtorsAllOf ((DData { dataName = n, dataCtors = vs })::rest) =
  (n, map variantName vs) :: typeCtorsAllOf rest
typeCtorsAllOf ((DAttrib _ d)::rest) = typeCtorsAllOf (d::rest)
typeCtorsAllOf (_::rest) = typeCtorsAllOf rest

-- ── build_exports ──────────────────────────────────────────────────────────
buildExports : ModuleExports -> OrdMap ModuleExports -> String -> List Decl -> Env -> ModuleExports
buildExports coreExp known modId prog env = ModuleExports {
  modId = modId,
  expValues = expValuesDirect prog ++ publicIfaceMethodVals prog env ++ reExpValues coreExp known prog,
  expTypes = expTypesDirect prog ++ reExpTypes coreExp known prog,
  expCtors = expCtorsDirect prog ++ reExpCtors coreExp known prog,
  expTypeCtors = expTypeCtorsDirect prog,
  expFieldOwners = expFieldOwnersDirect prog ++ reExpFieldOwners coreExp known prog,
  expInterfaces = expInterfacesDirect prog ++ reExpInterfaces coreExp known prog,
  expIfaceMethods = expIfaceMethodsDirect prog ++ reExpIfaceMethods coreExp known prog,
  expEffects = expEffectsDirect prog ++ reExpEffects coreExp known prog,
  expNewtypeCtors = expNewtypeCtorsDirect prog,
}

-- pub `newtype` (ctorName, typeName) pairs — the deliberately module-private
-- constructors NoExportedConstructors' import path must refuse rather than
-- silently accept (#1311).  Gated on `newtypePub` exactly like
-- `expCtorsDirect`/`expTypeCtorsDirect` (an unexported newtype's ctor is
-- simply not visible to import at all, same as today).
expNewtypeCtorsDirect : List Decl -> List (String, String)
expNewtypeCtorsDirect [] = []
expNewtypeCtorsDirect ((DNewtype { newtypePub = True, newtypeName = n, newtypeCtor = con })::rest) = (con, n) :: expNewtypeCtorsDirect rest
expNewtypeCtorsDirect ((DAttrib _ d)::rest) = expNewtypeCtorsDirect (d::rest)
expNewtypeCtorsDirect (_::rest) = expNewtypeCtorsDirect rest

-- pub DTypeSig/DExtern/DFunDef
expValuesDirect : List Decl -> List String
expValuesDirect [] = []
expValuesDirect ((DTypeSig True n _)::rest) = n :: expValuesDirect rest
expValuesDirect ((DExtern True n _)::rest) = n :: expValuesDirect rest
expValuesDirect ((DFunDef True n _ _)::rest) = n :: expValuesDirect rest
expValuesDirect ((DAttrib _ d)::rest) = expValuesDirect (d::rest)
expValuesDirect (_::rest) = expValuesDirect rest

-- methods of PUBLIC interfaces that are bound as values (lib's final iter loop)
publicIfaceMethodVals : List Decl -> Env -> List String
publicIfaceMethodVals prog env =
  flatMap (keepBoundMethods env) (pubIfaceMethodSets prog)

keepBoundMethods : Env -> List String -> List String
keepBoundMethods env ms = filterInSet env.values ms

pubIfaceMethodSets : List Decl -> List (List String)
pubIfaceMethodSets [] = []
pubIfaceMethodSets ((DInterface { pub = True, methods, ... })::rest) =
  map ifaceMethodNm methods :: pubIfaceMethodSets rest
pubIfaceMethodSets ((DAttrib _ d)::rest) = pubIfaceMethodSets (d::rest)
pubIfaceMethodSets (_::rest) = pubIfaceMethodSets rest

-- pub newtype + VisPublic/VisAbstract data & record (the type name only)
expTypesDirect : List Decl -> List String
expTypesDirect [] = []
expTypesDirect ((DNewtype { newtypePub = True, newtypeName = n })::rest) =
  n :: expTypesDirect rest
expTypesDirect ((DData { dataVis = VisPublic, dataName = n })::rest) =
  n :: expTypesDirect rest
expTypesDirect ((DData { dataVis = VisAbstract, dataName = n })::rest) =
  n :: expTypesDirect rest
expTypesDirect ((DTypeAlias { tyAliasPub = True, tyAliasName = n })::rest) =
  n :: expTypesDirect rest
expTypesDirect ((DAttrib _ d)::rest) = expTypesDirect (d::rest)
expTypesDirect (_::rest) = expTypesDirect rest

-- pub newtype ctor + VisPublic data ctors (VisAbstract exports NO ctors)
expCtorsDirect : List Decl -> List String
expCtorsDirect [] = []
expCtorsDirect ((DNewtype { newtypePub = True, newtypeCtor = con })::rest) =
  con :: expCtorsDirect rest
expCtorsDirect ((DData { dataVis = VisPublic, dataCtors = vs })::rest) = map variantName vs
  ++ expCtorsDirect rest
expCtorsDirect ((DAttrib _ d)::rest) = expCtorsDirect (d::rest)
expCtorsDirect (_::rest) = expCtorsDirect rest

expTypeCtorsDirect : List Decl -> List (String, List String)
expTypeCtorsDirect [] = []
expTypeCtorsDirect ((DNewtype { newtypePub = True, newtypeName = n, newtypeCtor = con })::rest) = (n, [con]) :: expTypeCtorsDirect rest
expTypeCtorsDirect ((DData { dataVis = VisPublic, dataName = n, dataCtors = vs })::rest) = (n, map variantName vs) :: expTypeCtorsDirect rest
expTypeCtorsDirect ((DAttrib _ d)::rest) = expTypeCtorsDirect (d::rest)
expTypeCtorsDirect (_::rest) = expTypeCtorsDirect rest

-- field owners for PUBLIC data (named-field variants) + record
expFieldOwnersDirect : List Decl -> List (String, String)
expFieldOwnersDirect [] = []
expFieldOwnersDirect ((DData { dataVis = VisPublic, dataCtors = vs })::rest) = flatMap variantFieldOwners vs
  ++ expFieldOwnersDirect rest
expFieldOwnersDirect ((DAttrib _ d)::rest) = expFieldOwnersDirect (d::rest)
expFieldOwnersDirect (_::rest) = expFieldOwnersDirect rest

expInterfacesDirect : List Decl -> List String
expInterfacesDirect [] = []
expInterfacesDirect ((DInterface { pub = True, name = n, ... })::rest) =
  n :: expInterfacesDirect rest
expInterfacesDirect ((DAttrib _ d)::rest) = expInterfacesDirect (d::rest)
expInterfacesDirect (_::rest) = expInterfacesDirect rest

expIfaceMethodsDirect : List Decl -> List (String, List String)
expIfaceMethodsDirect [] = []
expIfaceMethodsDirect ((DInterface { pub = True, name = n, methods, ... })::rest) = (n, map ifaceMethodNm methods) :: expIfaceMethodsDirect rest
expIfaceMethodsDirect ((DAttrib _ d)::rest) = expIfaceMethodsDirect (d::rest)
expIfaceMethodsDirect (_::rest) = expIfaceMethodsDirect rest

expEffectsDirect : List Decl -> List String
expEffectsDirect [] = []
expEffectsDirect ((DEffect True n _)::rest) = n :: expEffectsDirect rest
expEffectsDirect ((DAttrib _ d)::rest) = expEffectsDirect (d::rest)
expEffectsDirect (_::rest) = expEffectsDirect rest

reExpEffects : ModuleExports -> OrdMap ModuleExports -> List Decl -> List String
reExpEffects coreExp known prog =
  flatMap (overPubUse coreExp known reExpEffectsFrom) (pubUsePaths prog)

reExpEffectsFrom : UsePath -> ModuleExports -> List String
reExpEffectsFrom (UseWild _) src = src.expEffects
reExpEffectsFrom _ _ = []

-- ── pub-import re-export (export import …) — mirror lib's reexport_name ──────
-- The names a pub use-path re-exports from its source module (errors suppressed
-- here — they were already reported when the module imported them).
-- (ORIGIN, LOCAL) per re-exported name.  The origin is what the SOURCE module exports
-- (so it is what the `filterContains src.expX` guards below must test); the local is
-- the name THIS module re-exports it under.  They differ only for a member alias
-- (`export import m.{a as b}` re-exports m's `a` as `b`).
--
-- A whole-module alias is absent on purpose: `export import m as A` is rejected in the
-- parser.  Re-exporting `A.f` would export a name no importer could write without
-- knowing our private alias.
reexportBindings : UsePath -> ModuleExports -> List (String, String)
reexportBindings (UseName ns) _ =
  if listLen ns > 1 then
    let n = lastOf ns
    [(n, n)]
  else []
reexportBindings (UseGroup _ members) src =
  map dropLocOfExpanded (flatMap (expandMemberNames src) members)
reexportBindings (UseWild _) src =
  map
    selfBinding
    (src.expValues ++ src.expTypes ++ src.expCtors ++ src.expInterfaces)
reexportBindings (UseAlias _ _) _ = []

dropLocOfExpanded : (String, String, Loc) -> (String, String)
dropLocOfExpanded (origin, local, _) = (origin, local)

selfBinding : String -> (String, String)
selfBinding n = (n, n)

-- the LOCAL names whose ORIGIN is one of `origins` (the source module's export list of
-- the relevant kind).  This is the aliased form of the old `filterContains`.
localsExportedFrom : List String -> List (String, String) -> List String
localsExportedFrom origins bindings =
  -- #925: `origins` is the source module's export list, which GROWS with re-export
  -- depth; the old per-binding `contains` was O(len) each → O(depth^2) per module,
  -- cubic over an `export import m.*` chain.  Build the membership set once and test
  -- with `omHasKey` (uncounted, O(log len)) — same kept locals, same order.
  let dom = omFromNames origins omEmpty
  map snd (filterList (b => omHasKey (fst b) dom) bindings)

reExpValues : ModuleExports -> OrdMap ModuleExports -> List Decl -> List String
reExpValues coreExp known prog =
  flatMap (overPubUse coreExp known reExpValuesFrom) (pubUsePaths prog)

reExpValuesFrom : UsePath -> ModuleExports -> List String
reExpValuesFrom path src =
  let bindings = reexportBindings path src
  localsExportedFrom src.expValues bindings
    ++ flatMap (ifaceValsOf src) (map fst bindings)

ifaceValsOf : ModuleExports -> String -> List String
ifaceValsOf src n =
  if contains n src.expInterfaces then
    filterContains src.expValues (ifaceMethodsOf n src.expIfaceMethods)
  else
    []

reExpTypes : ModuleExports -> OrdMap ModuleExports -> List Decl -> List String
reExpTypes coreExp known prog =
  flatMap (overPubUse coreExp known reExpTypesFrom) (pubUsePaths prog)

reExpTypesFrom : UsePath -> ModuleExports -> List String
reExpTypesFrom path src =
  localsExportedFrom src.expTypes (reexportBindings path src)

reExpCtors : ModuleExports -> OrdMap ModuleExports -> List Decl -> List String
reExpCtors coreExp known prog =
  flatMap (overPubUse coreExp known reExpCtorsFrom) (pubUsePaths prog)

reExpCtorsFrom : UsePath -> ModuleExports -> List String
reExpCtorsFrom path src =
  localsExportedFrom src.expCtors (reexportBindings path src)

reExpInterfaces : ModuleExports -> OrdMap ModuleExports -> List Decl -> List String
reExpInterfaces coreExp known prog =
  flatMap (overPubUse coreExp known reExpInterfacesFrom) (pubUsePaths prog)

-- Interfaces / types / ctors / field owners key off the ORIGIN name: only a VALUE
-- member can carry an alias (parser-enforced), so for these kinds origin == local and
-- the origin list is exactly the old behaviour.  Keying an interface by an alias would
-- be unsound anyway — impl coherence is resolved on the real interface name globally.
reexportOrigins : UsePath -> ModuleExports -> List String
reexportOrigins path src = map fst (reexportBindings path src)

reExpInterfacesFrom : UsePath -> ModuleExports -> List String
reExpInterfacesFrom path src =
  filterContains src.expInterfaces (reexportOrigins path src)

reExpIfaceMethods : ModuleExports -> OrdMap ModuleExports -> List Decl -> List (String, List String)
reExpIfaceMethods coreExp known prog =
  flatMap (overPubUse coreExp known reExpIfaceMethodsFrom) (pubUsePaths prog)

reExpIfaceMethodsFrom : UsePath -> ModuleExports -> List (String, List String)
reExpIfaceMethodsFrom path src =
  ifaceMethodPairs
    src
    (filterContains src.expInterfaces (reexportOrigins path src))

ifaceMethodPairs : ModuleExports -> List String -> List (String, List String)
ifaceMethodPairs _ [] = []
ifaceMethodPairs src (i::rest) =
  (i, ifaceMethodsOf i src.expIfaceMethods) :: ifaceMethodPairs src rest

reExpFieldOwners : ModuleExports -> OrdMap ModuleExports -> List Decl -> List (String, String)
reExpFieldOwners coreExp known prog =
  flatMap (overPubUse coreExp known reExpFieldOwnersFrom) (pubUsePaths prog)

reExpFieldOwnersFrom : UsePath -> ModuleExports -> List (String, String)
reExpFieldOwnersFrom path src =
  ownersForTypes
    (filterContains src.expTypes (reexportOrigins path src))
    src.expFieldOwners

ownersForTypes : List String -> List (String, String) -> List (String, String)
ownersForTypes _ [] = []
ownersForTypes types ((f, o)::rest)
  | contains o types = (f, o) :: ownersForTypes types rest
  | otherwise = ownersForTypes types rest

-- run `f` against a pub use-path's resolved source exports (skip unknown).
--
-- `core` resolves against `coreExp`, NOT against `known`: core is the IMPLICIT
-- prelude, so it is prepended to every module rather than imported, and it never
-- appears in the driver's `known` list.  This arm used to be `if mid == "core"
-- then []`, which silently dropped every name an `export import core.{…}` named —
-- so `stdlib/list.mdk`'s `export import core.{Filterable, filter, filterMap}`
-- re-exported NOTHING and `import list.{filter}` failed with "Module 'list' has no
-- exported name 'filter'", while `medaka check stdlib/list.mdk` stayed clean.
overPubUse : ModuleExports -> OrdMap ModuleExports -> (UsePath -> ModuleExports -> List b) -> UsePath -> List b
overPubUse coreExp known f path =
  let mid = useModId path
  if mid == "core" then f path coreExp
  else match findExports mid known
    None => []
    Some src => f path src

-- ── resolve_module + multi-module driver ───────────────────────────────────
export
resolveModule : List Decl -> List Decl -> OrdMap ModuleExports -> String -> List Decl -> (ModuleExports, List ResError)
resolveModule runtimeDecls preludeDecls known modId prog =
  resolveModuleG [] runtimeDecls preludeDecls known modId prog

-- Like resolveModule but with an explicit internal-extern guard list for this
-- module (empty ⇒ trusted: a stdlib module, or `--allow-internal`).
export
resolveModuleG : List String -> List Decl -> List Decl -> OrdMap ModuleExports -> String -> List Decl -> (ModuleExports, List ResError)
resolveModuleG internalGuard runtimeDecls preludeDecls known modId prog =
  let (env, importErrs) = buildEnvMM runtimeDecls preludeDecls known prog internalGuard
  let errs = dedupResErrors (buildErrors preludeDecls prog ++ importErrs ++ flatMap (checkDecl env) prog)
  let exp = buildExports (coreExports preludeDecls) known modId prog env
  (exp, errs)

-- thread resolveModule over modules in dependency-first order, accumulating
-- exports; collect the union of every module's errors (the harness sorts).
resolveModulesErrors : List Decl -> List Decl -> OrdMap ModuleExports -> List (String, List Decl) -> List ResError
resolveModulesErrors rt pre known mods =
  resolveModulesErrorsG True [] rt pre known mods

-- Guarded variant: a module is trusted (no internal-extern restriction) when
-- `allowInternal` is set OR its modId is in `trustedMods` (the stdlib-owned
-- modules, per the loader's owning-root).  Untrusted modules get the
-- internalExterns guard list.
--
-- The ONE recursive walker (#1440 dedup): `resolveModulesErrorsG` and
-- `resolveModulesErrorsByPathGo` used to be two verbatim-identical copies of
-- this recursion, differing only in how each module's errors got rendered.
-- Now there's one walker returning each module's RAW `(modId, errs)` pair;
-- the two renderers (flat union of raw errors vs per-module `file:L:C:`
-- located-by-path) are lifted to the two callers below instead of duplicated
-- here.
resolveModulesErrorsPairsG : Bool -> List String -> List Decl -> List Decl -> OrdMap ModuleExports -> List (String, List Decl) -> List (String, List ResError)
resolveModulesErrorsPairsG _ _ _ _ _ [] = []
resolveModulesErrorsPairsG allowInternal trustedMods rt pre known ((mid, prog)::rest) =
  let guard = if allowInternal || contains mid trustedMods then
    []
  else
    internalExterns
  let (exp, errs) = resolveModuleG guard rt pre known mid prog
  (mid, errs) :: resolveModulesErrorsPairsG allowInternal trustedMods rt pre (omInsert exp.modId exp known) rest

-- Flat union of every module's raw errors, in dependency-first order — the
-- renderer `resolveModulesToLinesG`/`resolveModulesErrors` want.
resolveModulesErrorsG : Bool -> List String -> List Decl -> List Decl -> OrdMap ModuleExports -> List (String, List Decl) -> List ResError
resolveModulesErrorsG allowInternal trustedMods rt pre known mods =
  flatMap
    snd
    (resolveModulesErrorsPairsG allowInternal trustedMods rt pre known mods)

-- one S-expression per diagnostic (the harness sorts); matches
-- `diagdump --resolve-modules` over the same ordered module list.
export
resolveModulesToLines : List Decl -> List Decl -> List (String, List Decl) -> String
resolveModulesToLines runtimeDecls preludeDecls mods =
  joinNl (map
    resErrorSexp
    (resolveModulesErrors runtimeDecls preludeDecls omEmpty mods))

-- Guarded variant of resolveModulesToLines (S-expr output) for the `medaka check`
-- exit-code predicate: `allowInternal` / `trustedMods` decide per-module trust.
export
resolveModulesToLinesG : Bool -> List String -> List Decl -> List Decl -> List (String, List Decl) -> String
resolveModulesToLinesG allowInternal trustedMods runtimeDecls preludeDecls mods = joinNl (map resErrorSexp (resolveModulesErrorsG allowInternal trustedMods runtimeDecls preludeDecls omEmpty mods))

-- (REMOVED, #1440) `resolveModulesToHumane` had zero callers — it was
-- imported by `compiler/tools/check.mdk` and `compiler/driver/medaka_cli.mdk`
-- but never invoked from either.  `resolveModulesToHumaneG`'s own remaining
-- call (from `runCheckModules`) has also been removed — see the note at
-- the `resolveModulesErrorsByFile` block below for why that call could only ever
-- return `""`.

-- (REMOVED, #186/#1360) `resolveModulesToHumaneGF` took a single fallback FILE
-- and stamped it on EVERY module's located resolve errors whose own Loc carried
-- an empty `file` — which, on the multi-module loader, is all of them.  `check`
-- stopped using it in #41; `run`/`build` kept it until #186, which is exactly
-- how an imported module's error kept printing under the entry file's path.  It
-- is wrong by construction for any graph with more than one module, so it is
-- gone rather than deprecated: use `resolveModulesErrorsByFile` below, which
-- takes the loader's modId → path map and attributes each module to its own file.

-- (REMOVED, #2400 F2) `resolveModulesToHumaneByPath` / `ppResErrorLocatedF` /
-- `ppResErrorLocated` / `renderModuleErrorsByPath` / `resolveModulesErrorsByPathGo`
-- were a SECOND human renderer: they hand-built `"\{file}:\{sl}:\{sc}: \{msg}"`
-- with no `error: ` severity prefix and no caret block, so the SAME unbound name
-- printed one way through the single-file arm (which has always gone through
-- `driver.diagnostics.ppDiagCliLines`) and another way through the module graph.
-- They are DELETED rather than deprecated — a dead second face is how a third
-- call site gets written.  Rendering now lives at ONE place,
-- `driver.diagnostics.ppResolveErrorsByFile`, which walks the pairs
-- `resolveModulesErrorsByFile` below hands it and formats each `ResError`
-- through `diagOfResError` + `ppDiagCliLines`.  Rendering could not stay HERE:
-- the caret block needs the module's SOURCE TEXT (resolve is pure, and the
-- loader drops source after parsing), and `diagnostics.mdk` imports THIS module,
-- so the dependency only runs one way.
--
-- The per-module ATTRIBUTION this file owns is unchanged and stays here — see
-- `resolveModulesErrorsByFile`.

-- Attributes each module's resolve errors to that module's OWN file, looked up
-- in `modPaths` (a modId → real file path assoc the loader carries), and stops
-- one step short of rendering.  `check` (#41), `run` and `build` (#186/#1360)
-- all gate on this seam.  Fixes the multi-module misattribution where an
-- IMPORTED module's error printed the ENTRY file's path (#41): the multi-module
-- `parseLocated` Locs carry `file == ""`, so a single shared fallback file sent
-- EVERY module's errors to the entry.  Pairing each error with its module's path
-- fixes the attribution at the render boundary — resolve is re-run per module
-- here anyway (to thread exports), so it is the natural place to do it.
--
-- 🚨 A modId absent from `modPaths` degrades to `""` (which renders as
-- `<unknown location>`), NEVER to another module's file.  That degradation is
-- the whole point of #41/#186/#1360 and must not be "improved" into a
-- single-`target` fallback.
export
resolveModulesErrorsByFile : List (String, String) -> Bool -> List String -> List Decl -> List Decl -> List (String, List Decl) -> List (String, List ResError)
resolveModulesErrorsByFile modPaths allowInternal trustedMods runtimeDecls preludeDecls mods = map (fileOfModuleErrors modPaths) (resolveModulesErrorsPairsG allowInternal trustedMods runtimeDecls preludeDecls omEmpty mods)

fileOfModuleErrors : List (String, String) -> (String, List ResError) -> (String, List ResError)
fileOfModuleErrors modPaths (mid, errs) =
  let file = match lookupAssoc mid modPaths
    Some p => p
    None => ""
  (file, errs)

-- ── #837: binding-id minting (stampBindingIds) ──────────────────────────────
-- Mints a monotonic unique Int per TOP-LEVEL value binder and stamps every
-- surviving plain `EVar x` occurrence with the id of the binding it resolves to
-- (`EVarId x id`), so typecheck's `schemeObligationsRef` can key by (name, id)
-- instead of the bare name — retiring the body-scoped snapshot/restore windows.
--
-- INCREMENT 1 mints only top-level binders.  Local / lambda / pattern / where
-- binders are inserted into scope at the sentinel id 0 so SHADOWING is correct
-- (an inner `g` still hides a top-level `g`), but their occurrences carry the
-- sentinel id 0 and typecheck reads those through the bare-name fallback (exactly
-- today's behaviour).  `bodyLocalSchemesRef` / `isBodyLocalScheme` were retired
-- separately (incr2, PR #861) via a `TcEnv` is-local flag — NOT local-id minting.
-- Minting real local ids to retire the id-0 fallback (#837 Axis B) stays deferred:
-- the fallback is provably sound (substMonos can only drop, never mis-attribute)
-- and the change is byte-identical — pure precision, see #837.
--
-- Runs AFTER mark, BEFORE typecheck.  The walk is a pure deterministic
-- left-to-right traversal, so ids are stable run-to-run and NEVER reach the
-- emitter (the EVarId node is stripped by core_ir_lower).  See #907/#1031 below
-- for how top-level ids and local sentinel-0 shadowing are actually represented.

-- #907/#1031: the scope env is a SINGLE threaded OrdMap (name -> id), extended by
-- shadow-INSERT (never a cons'd frame list).  A local binder inserts its names at
-- the sentinel id 0, overwriting whatever `lookupBindId` would otherwise find —
-- exactly the same shadowing outcome as the old innermost-frame-first list walk,
-- but a lookup is O(log n) regardless of how many scopes deep the reference sits.
-- The old `List BScope` (SLocal frame :: ... :: STop top) made a DEEP local
-- nesting (N sequential lets, references to an outer binding) an O(depth) walk
-- per EVar — O(depth²) over the body (the `scoperefs` shape, #1031).
lookupBindId : OrdMap Int -> String -> Int
lookupBindId env n = match omLookup n env
  Some id => id
  None => 0

-- shadow-insert every name in `names` at sentinel id 0 (a local binder).  Names
-- are inserted left-to-right so a later name in the same list wins a same-name
-- collision — matches the old zeroFrame's within-frame first-match for the
-- (non-duplicate) names every real pattern binds.
insertZero : List String -> OrdMap Int -> OrdMap Int
insertZero [] env = env
insertZero (n::rest) env = insertZero rest (omInsert n 0 env)

-- per-parameter shadow-insert, in signature order — a LATER param's name wins a
-- same-name collision, matching the old paramZeroFrames' reverseL (innermost =
-- last param).
insertParams : List Pat -> OrdMap Int -> OrdMap Int
insertParams [] env = env
insertParams (p::rest) env = insertParams rest (insertZero (patBindings p) env)

-- top-level value binder names, in decl order (DFunDef + DLetGroup members).
topBinderNames : List Decl -> List String
topBinderNames [] = []
topBinderNames ((DFunDef _ n _ _)::rest) = n :: topBinderNames rest
topBinderNames ((DLetGroup _ binds)::rest) = map letBindName binds
  ++ topBinderNames rest
topBinderNames ((DAttrib _ d)::rest) = topBinderNames (d::rest)
topBinderNames (_::rest) = topBinderNames rest

-- number distinct names monotonically from `i` (ids are 1-based; 0 is sentinel).
numberFrom : Int -> List String -> List (String, Int)
numberFrom _ [] = []
numberFrom i (n::rest) = (n, i) :: numberFrom (i + 1) rest

-- ── the walk ────────────────────────────────────────────────────────────────
stampExpr : OrdMap Int -> Expr -> Expr
stampExpr _ (ELit l) = ELit l
stampExpr _ (ENumLit n r d lx) = ENumLit n r d lx
stampExpr _ (EMethodRef m) = EMethodRef m
stampExpr _ (EDictApp d) = EDictApp d
stampExpr _ (EMethodAt name r ir mr) = EMethodAt name r ir mr
stampExpr _ (EDictAt name r) = EDictAt name r
stampExpr _ (EVarAt n a) = EVarAt n a
stampExpr _ (EVarId n i) = EVarId n i
stampExpr env (EVar n)
  | isHint n = EVar n
  | otherwise = EVarId n (lookupBindId env n)
stampExpr env (EApp f x) = EApp (stampExpr env f) (stampExpr env x)
stampExpr env (ELam pats body) =
  ELam pats (stampExpr (insertParams pats env) body)
stampExpr env (ELet m isRec pat e1 e2) = stampLet env m isRec pat e1 e2
stampExpr env (ELetGroup binds body) = stampLetGroup env binds body
stampExpr env (EMatch e0 arms) =
  EMatch (stampExpr env e0) (map (stampArm env) arms)
stampExpr env (EIf c t el) =
  EIf (stampExpr env c) (stampExpr env t) (stampExpr env el)
stampExpr env (EBinOp op a b r) =
  EBinOp op (stampExpr env a) (stampExpr env b) r
stampExpr env (EUnOp op a r) = EUnOp op (stampExpr env a) r
stampExpr env (EInfix op a b) = EInfix op (stampExpr env a) (stampExpr env b)
stampExpr env (EFieldAccess e0 f r) = EFieldAccess (stampExpr env e0) f r
stampExpr env (ETuple es) = ETuple (map (stampExpr env) es)
stampExpr env (EListLit es) = EListLit (map (stampExpr env) es)
stampExpr env (EArrayLit es) = EArrayLit (map (stampExpr env) es)
stampExpr env (ERangeList lo hi incl) =
  ERangeList (stampExpr env lo) (stampExpr env hi) incl
stampExpr env (ERangeArray lo hi incl) =
  ERangeArray (stampExpr env lo) (stampExpr env hi) incl
stampExpr env (ESlice e0 lo hi incl r) =
  ESlice (stampExpr env e0) (stampExpr env lo) (stampExpr env hi) incl r
stampExpr env (EIndex e0 i r) = EIndex (stampExpr env e0) (stampExpr env i) r
stampExpr env (EAnnot e0 t) = EAnnot (stampExpr env e0) t
stampExpr env (EHeadAnnot e0 t) = EHeadAnnot (stampExpr env e0) t
stampExpr env (EBlock stmts) = EBlock (stampStmts env stmts)
stampExpr env (EDo d stmts) = EDo d (stampStmts env stmts)
stampExpr env (EStringInterp parts) =
  EStringInterp (map (stampInterp env) parts)
stampExpr env (EGuards arms) = EGuards (map (stampGuardArm env) arms)
stampExpr env (ERecordCreate name fs) =
  ERecordCreate name (map (stampFieldAssign env) fs)
stampExpr env (ERecordUpdate e0 fs r) =
  ERecordUpdate (stampExpr env e0) (map (stampFieldAssign env) fs) r
stampExpr env (EVariantUpdate con e0 fs) =
  EVariantUpdate con (stampExpr env e0) (map (stampFieldAssign env) fs)
stampExpr env (EMapLit n kvs) = EMapLit n (map (stampKv env) kvs)
stampExpr env (ESetLit n es) = ESetLit n (map (stampExpr env) es)
stampExpr env (EAsPat x e0) = EAsPat x (stampExpr env e0)
stampExpr env (ESection s) = ESection (stampSection env s)
stampExpr env (ELoc l e) = ELoc l (stampExpr env e)
stampExpr env (EDoOrigin l e) = EDoOrigin l (stampExpr env e)

stampLet : OrdMap Int -> Bool -> Bool -> Pat -> Expr -> Expr -> Expr
stampLet env m True (PVar f fl) e1 e2 =
  let inner = insertZero [f] env
  ELet m True (PVar f fl) (stampExpr inner e1) (stampExpr inner e2)
stampLet env m isRec pat e1 e2 =
  ELet
    m
    isRec
    pat
    (stampExpr env e1)
    (stampExpr (insertZero (patBindings pat) env) e2)

stampLetGroup : OrdMap Int -> List LetBind -> Expr -> Expr
stampLetGroup env binds body =
  let groupScope = insertZero (map letBindName binds) env
  ELetGroup (map (stampLetBind groupScope) binds) (stampExpr groupScope body)

stampLetBind : OrdMap Int -> LetBind -> LetBind
stampLetBind groupScope (LetBind name clauses) =
  LetBind name (map (stampClause groupScope) clauses)

stampClause : OrdMap Int -> FunClause -> FunClause
stampClause groupScope (FunClause pats body) =
  FunClause pats (stampExpr (insertParams pats groupScope) body)

stampArm : OrdMap Int -> Arm -> Arm
stampArm env (Arm pat gs body) =
  let scope0 = insertZero (patBindings pat) env
  let (gs2, scope2) = stampGuards scope0 gs
  Arm pat gs2 (stampExpr scope2 body)

stampGuards : OrdMap Int -> List Guard -> (List Guard, OrdMap Int)
stampGuards scope [] = ([], scope)
stampGuards scope ((GBool e)::rest) =
  let (rest2, scope2) = stampGuards scope rest
  (GBool (stampExpr scope e) :: rest2, scope2)
stampGuards scope ((GBind p e)::rest) =
  let e2 = stampExpr scope e
  let (rest2, scope2) = stampGuards (insertZero (patBindings p) scope) rest
  (GBind p e2 :: rest2, scope2)

stampGuardArm : OrdMap Int -> GuardArm -> GuardArm
stampGuardArm env (GuardArm gs body) =
  let (gs2, scope2) = stampGuards env gs
  GuardArm gs2 (stampExpr scope2 body)

stampStmts : OrdMap Int -> List DoStmt -> List DoStmt
stampStmts _ [] = []
stampStmts env ((DoExpr e)::rest) =
  DoExpr (stampExpr env e) :: stampStmts env rest
stampStmts env ((DoLet m r p e)::rest) =
  DoLet m r p (stampExpr env e) ::
    stampStmts (insertZero (patBindings p) env) rest
stampStmts env ((DoBind p e)::rest) =
  DoBind p (stampExpr env e) :: stampStmts (insertZero (patBindings p) env) rest
stampStmts env ((DoAssign x e)::rest) =
  DoAssign x (stampExpr env e) :: stampStmts (insertZero [x] env) rest
stampStmts env ((DoFieldAssign x fs e)::rest) =
  DoFieldAssign x fs (stampExpr env e) :: stampStmts env rest

stampInterp : OrdMap Int -> InterpPart -> InterpPart
stampInterp _ (InterpStr s) = InterpStr s
stampInterp env (InterpExpr e) = InterpExpr (stampExpr env e)

stampFieldAssign : OrdMap Int -> FieldAssign -> FieldAssign
stampFieldAssign env (FieldAssign n e) = FieldAssign n (stampExpr env e)

stampKv : OrdMap Int -> (Expr, Expr) -> (Expr, Expr)
stampKv env (k, v) = (stampExpr env k, stampExpr env v)

stampSection : OrdMap Int -> Section -> Section
stampSection _ (SecBare op) = SecBare op
stampSection env (SecRight op e) = SecRight op (stampExpr env e)
stampSection env (SecLeft e op) = SecLeft (stampExpr env e) op

-- ── decl-level walk ─────────────────────────────────────────────────────────
-- Each top-level fn's params shadow-insert (id 0) over `top`; sibling top-level
-- names resolve through `top` to their minted id.
stampDecl : OrdMap Int -> Decl -> Decl
stampDecl top (DFunDef p n pats body) =
  DFunDef p n pats (stampExpr (insertParams pats top) body)
stampDecl top (DProp p n params body) =
  DProp p n params (stampExpr (insertZero (map propParamName params) top) body)
stampDecl top (DTest p n body) = DTest p n (stampExpr top body)
stampDecl top (DBench p n body) = DBench p n (stampExpr top body)
stampDecl top (DLetGroup p binds) = DLetGroup p (map (stampLetBind top) binds)
stampDecl top (d@(DInterface { methods, ... })) =
  DInterface { d | methods = map (stampIfaceMethod top) methods }
stampDecl top (d@(DImpl { methods, ... })) =
  DImpl { d | methods = map (stampImplMethod top) methods }
stampDecl top (DAttrib attrs inner) = DAttrib attrs (stampDecl top inner)
stampDecl _ d = d

stampIfaceMethod : OrdMap Int -> IfaceMethod -> IfaceMethod
stampIfaceMethod _ (IfaceMethod nm ty None mloc) = IfaceMethod nm ty None mloc
stampIfaceMethod top (IfaceMethod nm ty (Some (MethodDefault pats body)) mloc) = IfaceMethod nm ty (Some (MethodDefault pats (stampExpr (insertParams pats top) body))) mloc

stampImplMethod : OrdMap Int -> ImplMethod -> ImplMethod
stampImplMethod top (ImplMethod nm pats body) =
  ImplMethod nm pats (stampExpr (insertParams pats top) body)

-- Mint per-top-level-binder ids and stamp all occurrences.  Returns the stamped
-- program AND `defIds` (each minted top-level binder → its id), which typecheck's
-- `registerSchemeObligations` reads to key a top-level member's obligations.
-- #907/#1031: the whole scope env — top-level AND every local nesting depth — is
-- ONE threaded OrdMap, so `lookupBindId` is O(log n) regardless of decl count OR
-- local-scope depth; `top` (deduped) is still RETURNED as the pair list its
-- typecheck consumers expect.
export
stampBindingIds : List Decl -> (List Decl, List (String, Int))
stampBindingIds decls =
  let top = numberFrom 1 (dedup (topBinderNames decls))
  (map (stampDecl (omFromPairs top omEmpty)) decls, top)

-- ── #1110: type-constructor ORIGIN acquisition ──────────────────────────────
-- `ast.mdk`'s `TyCon.tyConOrigin` (the A-1 carrier, PR #1211) says WHERE a
-- type-constructor head was declared.  This section is what fills it in, and it
-- is resolve's job for the same reason name binding is: resolve is the phase that
-- knows, for a given module's source text, which declaration a spelling refers to.
--
-- ⚠️ IDENTITY IS ACQUIRED ONCE, AT THE SITE THAT WROTE THE NAME, AND TRAVELS WITH
-- THE TREE.  It is NOT a map a later phase consults at the point of use.  That
-- design was proposed and refuted: the `Ty` trees that need identity CROSS MODULE
-- BOUNDARIES and are elaborated under a DIFFERENT module's state.  An interface
-- method's declared type is stored raw and elaborated under the IMPLEMENTING
-- module's context; a type alias's RHS belongs to the DEFINING module and is
-- expanded in the CONSUMER's.  A map consulted at the point of use is the
-- consumer's map, so it resolves a foreign name against local scope and stamps a
-- CONFIDENTLY WRONG origin — strictly worse than the honest collision it replaces.
-- `stampTyHead` below enforces the discipline structurally: it only ever fills in
-- a head that is still `OriginUnresolved`, so a tree that already carries identity
-- is immune to re-stamping under any scope, on any path, however often a driver
-- re-runs the pass.
--
-- ⚠️ `tyConOrigin` IS READ, AND IT DECIDES ACCEPTANCE.  This paragraph said
-- "NOTHING READS `tyConOrigin` YET … re-keying the bare-name-keyed tables onto it
-- (#1069, #1070, #1090, #1092, #1208, #1209) … are the NEXT A-1 PRs" until
-- 2026-08-04; #1111 Stage A-2 unit A-2.10 landed the last two of that list, so
-- the sentence describes a tree that no longer exists.  Six comparisons in
-- `types/typecheck.mdk` — `unifyN`, `cohGoR`, `cohStep`, `cohEqR`, `matchStep`,
-- `monoSameGiven` — now read the field, all through one seam, `sameTyConHead`
-- (`frontend/ast.mdk`), whose doc-comment owns the rule and its derivation.  Two
-- modules' same-named types no longer unify.
--
-- ⚠️ THE LESSON OUTLIVES THE CORRECTION, and it is why this was worth a paragraph
-- rather than a deletion: a "nothing reads this" claim is a NEGATIVE ABOUT THE
-- WHOLE TREE, it expires the moment ANY unit adds a reader, and no gate notices.
-- The identical sentence stood in `types/typecheck.mdk`'s `Mono` comment
-- ("CARRIER ONLY — NOTHING READS IT YET"), was already false there from A-2.2
-- onward, and a reviewer traced a shipped S0 to someone believing it.  A-2.10
-- fixed that twin and left THIS one standing for a further PR.  So: when you
-- narrow a claim, GREP THE TREE FOR ITS OTHER SPELLINGS before you call it done.
--
-- ⚠️ RESIDUAL INHABITANT (§8 I6.3 drain).  `OriginUnresolved` survives this pass,
-- and it means exactly one thing: **NO IDENTITY WAS AVAILABLE HERE**.  Two ways to
-- get there, and BOTH are honest absence — no head is ever left carrying a claim
-- this pass could not justify:
--
--   1. the name is in no scope at all (`checkType` reports it as `UnknownType`;
--      errors accumulate, so the tree still reaches typecheck);
--   2. the driver had no module graph, so it had no module id to attribute the
--      user's own declarations to — see `stampFlatTyOrigins`.
--
-- ⚠️ An earlier draft of this comment claimed `OriginUnresolved ⟺ the name is
-- unbound`.  That was FALSE IN BOTH DIRECTIONS — case (2) is bound-but-unstamped,
-- and the same draft's flat stamper attributed BOUND prelude names to the user's
-- module, which is not absence but WRONGNESS.  The equivalence is not repaired
-- here, it is RETIRED: do not reason from `OriginUnresolved` to "unbound".
--
-- 🚨 THE CONSUMER RULE IS NOT ONE RULE, AND THIS IS WHERE THAT WAS DISCOVERED.
-- It read: "NO predicate may compare two `OriginUnresolved` heads equal, or treat
-- one as matching anything."  #1111 A-2.10's `tyConIdsConflict`
-- (`frontend/ast.mdk`) does BOTH — its `_ => False` arm makes two absent heads
-- non-conflicting AND makes an absent head non-conflicting with any present one —
-- and it is CORRECT, so the rule as written was falsified by the first consumer
-- that had to answer an acceptance question.  The rule splits by WHAT THE
-- PREDICATE DECIDES, because "conservative" means opposite things on the two:
--
--   * a LOOKUP ("which row does this key select?") — a miss is loud and safe
--     (`No impl of …`, `Unknown type …`), a false hit is silent wrongness.  There
--     absence must never match, not even itself.  `ifaceIdMatches` and `tabKeyEq`
--     are written that way, and the sentence above is still exactly right FOR
--     THEM.
--   * an ACCEPTANCE ("may this program be typed?") — a false REJECT refuses a
--     valid program.  There absence must make NO CLAIM: two heads conflict only
--     when both carry an identity and the identities differ.  Copying the lookup
--     shape here rejects the compiler's own prelude (measured: an extern-sourced
--     `Int` carries no identity and must still meet the `OriginBuiltin` one).
--
-- `sameTyConHead`'s doc-comment (`frontend/ast.mdk`) is the canonical derivation
-- and the place to change either half; this is the pointer to it, not a second
-- statement of it.  ⚠️ Absence-makes-no-claim on the acceptance side is a
-- TRANSITIONAL shape, not the target: within the identity-less population it is
-- operationally a wildcard, and #1279 is the measured bridge it permits.  It
-- closes itself as supply completes — at total supply the predicate IS strict
-- equality, which is §8 I6.3's target state.
--
-- Draining `OriginUnresolved` entirely needs the distinct pre-resolve type §8
-- I6.3 really asks for (A-1's option 1), which is not reachable from a
-- byte-identical PR.  The producer set is pinned by
-- `test/typecheck_compiler_source.sh` (the `soundness` job).

-- ── THE ONE PRECEDENCE RULE (#1245) ─────────────────────────────────────────
-- Type/interface identity in this file is decided in exactly one way, and both
-- functions that decide it are written the same way so the agreement is
-- STRUCTURAL rather than coincidental:
--
--   *build the layers as ONE list, LOWEST precedence first, and fold it with
--    `omFromPairs`, which inserts left to right so a LATER entry wins.*
--
--     builtins < prelude < imports/re-exports < this module's own declarations
--
-- `tyOriginScope` (the consumer-side scope) spells all four layers;
-- `typeOriginExports` (the producer-side export list) spells the last two — it
-- emits a LIST rather than a map, but its consumers fold it with the same
-- last-wins `omFromPairs` (`keepTypeOrigins`) or splice it in order into
-- `tyOriginScope`'s imports layer (`UseWild`), so the same convention decides it.
--
-- ⚠️ Until #1245 the two disagreed: `tyOriginScope` nested its `omFromPairs`
-- calls OUTERMOST-first (own written first in the source but inserted last, so
-- own won), while `typeOriginExports` concatenated own FIRST and re-exports LAST
-- (so re-exports won).  Both were "later wins", but one wrote the winner first
-- and the other wrote it last, and nothing made the mismatch visible.  Keeping a
-- single lowest-first-in-source-order convention is what stops that recurring —
-- do not re-nest either one.
--
-- Every type name in scope in module `mid`, mapped to the identity a `TyCon` head
-- spelling it must carry.  Built lowest-precedence FIRST, per the rule above.
--
-- ⚠️ That ORDER IS A NEW POLICY DECISION, made here, and it is what #1208 will be
-- re-keyed against — so it is argued rather than inherited.  It is NOT read off
-- `buildEnv`: that builds a presence SET (`OrdMap Unit`), which encodes no
-- precedence at all and in fact lists own-declarations BEFORE imports.  An earlier
-- draft of this comment claimed the order came from there; it does not.
--
-- The argument for it, nearest-scope-wins, matching how every other scope in the
-- language resolves a pun:
--   * own declarations beat imports, because a module that declares `data Foo`
--     and also imports one means its own — the same rule a local binding follows
--     against a top-level one.  Resolve's use-time ambiguity machinery
--     (`ambiguousSet`) only ever fires on ≥2 IMPORTED spellings for this reason:
--     a local declaration is not a participant in the ambiguity, it settles it.
--   * imports beat the prelude, because the prelude is implicit and an explicit
--     `import m.{Result}` is a deliberate statement about which `Result` is meant.
--   * the prelude beats builtins only vacuously (they are disjoint today); the
--     order is stated so a future prelude `data List` would resolve to the prelude
--     rather than silently keeping the builtin identity.
-- ⚠️ Precedence here decides IDENTITY only.  It does NOT license a shadowing that
-- resolve would reject: an occurrence resolve reports as ambiguous still gets a
-- diagnostic, and this map merely says which declaration the head would name if it
-- is legal.  Diagnosing the ambiguity is the NEXT PR's job, not this map's.
tyOriginScope : List (String, String) -> OrdMap (List (String, String)) -> String -> List Decl -> OrdMap TyConOrigin
--
-- ⚠️ #1110 PR C: THIS MAP NOW HOLDS TWO NAMESPACES, and they are kept apart by a
-- KEY TAG, not by being two maps — a type under its bare name, an interface under
-- `iface:<Name>` (see `ifaceKey` for why the tag rather than a second parameter).
-- The precedence argument below applies to each namespace independently, because
-- the keys are disjoint by construction.
tyOriginScope coreTypes known mid prog =
  -- one layer per `let`, LOWEST precedence first; concatenated in that order and
  -- folded once, last-wins.  Naming the layers is not decoration: it is what keeps
  -- the order readable after `fmt`, which reflows a bare five-way `++` chain onto
  -- a single line and hides the very thing this function's comment argues about.
  let builtinLayer = builtinTyOrigins
  let preludeLayer = map importedTyOrigin coreTypes
  let importLayer = map importedTyOrigin (flatMap (importedTypeOrigins known) (usePathsOf prog))
  let ownLayer = map (ownTyOrigin mid) (dataRecordNames prog) ++ map (ownIfaceOrigin mid) (interfaceNamesOf prog)
  omFromPairs (builtinLayer ++ preludeLayer ++ importLayer ++ ownLayer) omEmpty

-- `dataRecordNames` is the ALL-declarations extractor (`expTypesDirect` is the
-- public subset) — a module's own private type is in its own scope.
ownTyOrigin : String -> String -> (String, TyConOrigin)
ownTyOrigin mid n = (n, OriginModule mid)

importedTyOrigin : (String, String) -> (String, TyConOrigin)
importedTyOrigin (n, definer) = (n, OriginModule definer)

-- §8 I6.2 (a): a head the LANGUAGE provides has ONE program-global identity, not
-- the identity of whichever module writes it, or two modules' `(Int, Int)` stop
-- being the same type — silently.  The tuple heads are listed for completeness;
-- the parser already builds them with `tyConBuiltin`, so they never reach here
-- unresolved.
builtinTyOrigins : List (String, TyConOrigin)
builtinTyOrigins = map builtinTyOrigin (primitiveTypes ++ tupleCtorTyNames)

builtinTyOrigin : String -> (String, TyConOrigin)
builtinTyOrigin n = (n, OriginBuiltin)

-- The TYPE peer of `valueProvenance` / `ctorProvenance` (#674): which type names a
-- module exports, and which module DECLARED each.
--
-- ⚠️ This is the half `ModuleExports.expTypes` structurally CANNOT answer, and the
-- reason it gets its own carrier rather than a read of that field.  `expTypes` is
-- `expTypesDirect prog ++ reExpTypes …` — the module's own public types
-- CONCATENATED with the ones it re-exports — so by the time any consumer reads it
-- the definer is already gone, and no amount of care at the read site recovers it.
-- Here a re-export carries the ORIGINAL definer through, so a chain of
-- `export import` does not re-attribute a type to a re-exporter that merely
-- passes it along.  (A re-exporter that ALSO declares the name is not an
-- exception to that but a different shape — see the ordering note below.)
--
-- 🚨 A RE-EXPORTER MAY ALSO DECLARE THE NAME ITSELF, and then this list has an
-- entry for each.  The order below is what decides that collision, and it is the
-- ONE PRECEDENCE RULE stated above `tyOriginScope`: lowest first, so RE-EXPORTS
-- FIRST and this module's OWN declarations LAST.  Every consumer resolves it
-- last-wins — `keepTypeOrigins`' `omFromPairs`, or `tyOriginScope`'s own fold
-- after `UseWild` splices this list in order — so own beats re-export, which is
-- what a consumer's `import m.{Foo}` actually BINDS.
--
-- ⚠️ Until #1245 this concatenation ran the other way (own first, re-exports
-- last), so the re-exported source won the fold and a consumer's occurrence was
-- stamped with the id of a module that did not declare the interface it bound.
-- Verified first-hand on both namespaces, before and after: a consumer of such an
-- `m` can use `m`'s OWN interface method and is rejected using the re-exported
-- interface's; the `data` version behaves identically.  Nothing read these origins
-- yet, so no program's accept/reject moved — but `fillIfaceOccOrigin` /
-- `fillDeclOrigin` are first-write-immune, so a wrong id could not have been
-- corrected downstream once Stage A-1 unit D reads one.
--
-- The three shapes this order must satisfy, all of them by the same rule:
--   1. declares only            — no re-export entries, own wins vacuously;
--   2. re-exports only          — no own entries, the definer carried through by
--                                 `keepTypeOrigins` wins vacuously, so a CHAIN of
--                                 `export import` still attributes to the original
--                                 definer rather than the last re-exporter;
--   3. declares AND re-exports  — both present, own is later, own wins.
--
-- ⚠️ #1110 PR C: also carries this module's public INTERFACES, tagged `iface:` (see
-- `ifaceKey`).  The `pubUsePaths` half needs no change — a re-exported interface
-- arrives already tagged, so it behaves exactly as a type does, including the
-- ordering above.  The two namespaces share this function, so they cannot diverge
-- on it.
typeOriginExports : OrdMap (List (String, String)) -> String -> List Decl -> List (String, String)
typeOriginExports known mid prog = flatMap (importedTypeOrigins known) (pubUsePaths prog)
  ++ map (typeDeclaredIn mid) (expTypesDirect prog)
  ++ map (ifaceDeclaredIn mid) (expInterfacesDirect prog)

typeDeclaredIn : String -> String -> (String, String)
typeDeclaredIn mid n = (n, mid)

-- The (localName, definerModId) pairs one use path brings into TYPE scope.
-- `core` is skipped: the prelude is prepended to every module rather than
-- imported, so its types are seeded directly by `tyOriginScope`.
importedTypeOrigins : OrdMap (List (String, String)) -> UsePath -> List (String, String)
importedTypeOrigins known path =
  if useModId path == "core" then []
  else match omLookup (useModId path) known
    None => []
    Some src => importedTypeOriginsFrom path src

importedTypeOriginsFrom : UsePath -> List (String, String) -> List (String, String)
importedTypeOriginsFrom (UseName ns) src =
  if listLen ns > 1 then
    keepTypeOrigins src [(lastOf ns, lastOf ns)]
  else
    []
importedTypeOriginsFrom (UseGroup _ members) src =
  keepTypeOrigins src (map useMemberBinding members)
importedTypeOriginsFrom (UseWild _) src = src
-- `import m as A` binds m's exported VALUES as `A.name` and nothing else — an
-- alias-qualified name in TYPE position is a parse error — so it contributes no
-- type identity at all.
importedTypeOriginsFrom (UseAlias _ _) _ = []

-- (ORIGIN, LOCAL), exactly as `expandMemberNames` splits them.  Only a VALUE member
-- can carry an alias (parser-enforced), so for a type the two coincide; going
-- through `useMemberLocal` anyway keeps this walk from depending on that rule.
useMemberBinding : UseMember -> (String, String)
useMemberBinding (m@(UseMember name _ _ _)) = (name, useMemberLocal m)

-- Keep the bindings whose ORIGIN name is a type the source module exports, and
-- attribute each to the module that source module's own export list names as the
-- definer.
--
-- ⚠️ NOT "never to the re-exporter".  That is what this line said until #1245, and
-- it is FALSE for one shape — on the function that performs the lookup, which is
-- the worst place for it to be wrong.  `definers` is a LAST-WINS fold
-- (`omFromPairs`) over `src`, i.e. over the source module's `typeOriginExports`
-- list, which is ordered re-exports-FIRST and own-declarations-LAST per THE ONE
-- PRECEDENCE RULE (stated above `tyOriginScope`).  So:
--   * a source module that merely PASSES A NAME ALONG yields the original
--     definer, through any length of `export import` chain — the property this
--     line was written for, and it still holds;
--   * a source module that ALSO DECLARES the name yields ITSELF.  That is not a
--     leak, it is correct: its own declaration is what a consumer's
--     `import m.{Foo}` actually binds.
-- Measured, not argued: `test/origin_fixtures/ifaces/` chains `deep` -> `mid` ->
-- `main_ifaces` with `mid` doing both, and the golden reads `Baton 1 mod:mid` /
-- `iface:Relay 1 mod:mid`.
keepTypeOrigins : List (String, String) -> List (String, String) -> List (String, String)
keepTypeOrigins src bindings =
  let definers = omFromPairs src omEmpty
  flatMap (bindTypeOrigin definers) bindings

-- ⚠️ TWO LOOKUPS, ONE PER NAMESPACE (#1110 PR C).  `import m.{Speak}` names a
-- surface spelling with no indication of which namespace it comes from, and `m` may
-- legally export BOTH a type `Speak` and an interface `Speak` — so the untagged
-- member name is checked against the bare key AND against `ifaceKey`, and whichever
-- the source module actually exports is what comes through.  A single lookup on the
-- bare name would silently bind no interface at all: every `iface:` row would miss,
-- and the whole imported-interface layer would be quietly empty.
bindTypeOrigin : OrdMap String -> (String, String) -> List (String, String)
bindTypeOrigin definers (origin, local) = bindOneOrigin definers origin local
  ++ bindOneOrigin definers (ifaceKey origin) (ifaceKey local)

bindOneOrigin : OrdMap String -> String -> String -> List (String, String)
bindOneOrigin definers key local = match omLookup key definers
  Some definer => [(local, definer)]
  None => []

-- ── the stamping walk ───────────────────────────────────────────────────────
-- `mapTyInDecl` (frontend/ast.mdk) is the total Ty-position rewrite; this supplies
-- the per-head decision.  Every Ty position of every decl is covered — signatures,
-- externs, `data` payloads, interface method sigs and defaults, impl heads and
-- `requires`, aliases, newtypes, prop params, and the `EAnnot`/`EHeadAnnot`
-- annotations inside bodies.
export
stampTyOrigins : OrdMap TyConOrigin -> List Decl -> List Decl
stampTyOrigins scope decls = map (stampDeclTyOrigins scope) decls

-- ⚠️ ONE WALK, BOTH OCCURRENCE LAYERS (#1110 PR C).  `mapOriginsInDecl` takes the
-- Ty-position callback AND the interface-occurrence callback, so the type heads and
-- the four interface-occurrence carriers are stamped in a single rebuild of the
-- decl.  A second `mapTyInDecl` pass would have cost a full extra AST rebuild per
-- decl per module in a stage `compiler/AGENTS.md` calls GC-bound, and would have
-- let the agreement probe drive a different traversal from this one.
stampDeclTyOrigins : OrdMap TyConOrigin -> Decl -> Decl
stampDeclTyOrigins scope d =
  mapOriginsInDecl (stampTyHead scope) (fillIfaceOccOrigin scope) d

-- ⚠️ The three arms are enumerated rather than wildcarded ON PURPOSE: a fourth
-- `TyConOrigin` inhabitant should be MADE TO SHOW UP here rather than falling
-- silently into "already has an identity, leave it".
--
-- ⚠️ But do not overstate what that buys, the way an earlier draft did: a
-- non-exhaustive match in this language is a WARNING, exit 0 — verified, not
-- assumed (`non-exhaustive match of 'T'. Missing case: 'C'` printed above `ok (2
-- declaration(s) checked, 0 errors)`).  So this is a REVIEW aid, not a build gate:
-- it puts the new inhabitant on the diff and in `check` output, and nothing more.
stampTyHead : OrdMap TyConOrigin -> Ty -> (Ty, Bool)
stampTyHead scope (t@(TyCon { tyConName = n, tyConOrigin = o })) = match o
  OriginUnresolved => stampHeadWith t (originOfTyName scope n)
  OriginBuiltin => (t, False)
  OriginModule _ => (t, False)
stampTyHead _ t = (t, False)

-- An UNKNOWN type name keeps `OriginUnresolved` — there is no module to attribute
-- it to, and `checkType` has already reported it as `UnknownType`.
originOfTyName : OrdMap TyConOrigin -> String -> TyConOrigin
originOfTyName scope n = optionOr OriginUnresolved (omLookup n scope)

stampHeadWith : Ty -> TyConOrigin -> (Ty, Bool)
stampHeadWith t OriginUnresolved = (t, False)
stampHeadWith t o = (TyCon { t | tyConOrigin = o }, True)

-- ── the DECLARATION layer (#1110, this PR) ──────────────────────────────────
-- The walk above stamps OCCURRENCES — every `TyCon` head written in a signature.
-- This one stamps DECLARATIONS: `DData`/`DNewtype`/`DTypeAlias`/`DInterface` each
-- carry a `…Origin` naming the module they were WRITTEN IN.
--
-- ⚠️ WHY THE OCCURRENCE LAYER IS NOT ENOUGH, i.e. why this is the blocker rather
-- than a convenience.  `registerVariants` (`types/typecheck.mdk`) mints the head
-- `Mono` for every user data type out of the `DData` ALONE — and that mono becomes
-- each constructor's scheme return type, hence the head every dispatch GOAL is read
-- from.  There is no `Ty` in that path to inherit an origin from, so until the
-- declaration carries one the goal side of the dispatch key cannot acquire identity
-- at all (the impl side already has it via `headTyconTy`).  #1110 unit D closed
-- that: `registerVariants` now takes `dataOrigin`/`newtypeOrigin` and mints the head
-- through `tconFrom` (`types/typecheck.mdk`), which is exactly the consumer this
-- carrier was landed for.  The same declaration is also where interface identity
-- (#1047) and constructor identity (#1070) have to come from: interface names live
-- on `DInterface`, constructor names in `DData`'s variants.
--
-- ⚠️ AND IT CANNOT COME FROM AMBIENT STATE AT THE CONSUMER.  `typecheck.mdk` holds
-- no current-module ref, and inventing one would be WRONG rather than merely
-- absent: `registerAllData` runs over `importedCtorTypeDecls` — OTHER modules'
-- declarations — so an ambient id attributes every imported type to the IMPORTER.
-- That is the exact wrongness class #1219 removed from the flat path.  Identity is
-- acquired HERE, where the module id is a fact, and travels with the tree.
--
-- ⚠️ THESE FIELDS ARE READ.  This said "NOTHING READS THESE FIELDS YET.
-- Deliberately: the PR is byte-identical", true at #1110 Stage A-1 and false
-- since Stage A-2 — `DData.dataOrigin` reaches `registerVariants o` and
-- `DInterface.ifaceOrigin` is the write side of A-2.4's `ifaceTabKey o name`
-- (both `types/typecheck.mdk`), plus `lowerDeclImpl`'s default-method identity
-- (`ir/core_ir_lower.mdk`).  The carrier's own comment in `frontend/ast.mdk`
-- holds the derivation and the grep; do not restate the reader set here.
-- (Corrected during #1111 A-2.10's review, by grepping the tree for the OTHER
-- spellings of a claim being narrowed one file over — which is the procedure a
-- "nothing reads this" negative always needs, because nothing else expires it.)
--
-- ⚠️ #1227 NARROWED THIS: it used to read "FLAT (loader-less) DRIVERS GET NOTHING
-- HERE" outright.  That is no longer true for the ONE flat call site that has a
-- real module id in hand: `checkProgramSeededSplit` (`types/typecheck.mdk`) already
-- knows its `coreProg0` argument is the prelude — that is the same fact
-- `stampFlatTyOrigins coreProg0 coreProg0` relies on for the OCCURRENCE layer — so
-- it now also calls `stampDeclOrigins "core" coreProgTy` here (the occurrence-
-- stamped prelude, `coreProg` is the name bound to THIS call's result), stamping
-- the prelude's OWN `DData`/`DNewtype`/`DTypeAlias`/`DInterface` declarations.
--
-- What is still true, and will not stop being true without a loader-derived id:
-- the flat driver's USER half (`userProg0`) has no module id and gets no call to
-- this function.  Every other flat driver (any caller that hands
-- `checkProgramSeededSplit` an empty `coreProg0` because it has already flattened
-- prelude+user together — `checkProgramSeeded`, or an explicit `[]` prelude-free
-- caller) still gets nothing, for the reason the rest of this comment gives: they
-- have no module id, an invented one is made PERMANENT by the immunity rule, and
-- `medaka run` on a no-import file reaches both the flat and the graph arm in ONE
-- process — so an invented id would directly contradict a real one.
-- Under-supplying is correctable later; over-supplying is not.  Residual,
-- greppable as `#1110 flat-identity`.
export
stampDeclOrigins : String -> List Decl -> List Decl
stampDeclOrigins mid decls = map (stampDeclOrigin mid) decls

-- ⚠️ Record UPDATE on a `d@` binding, never re-construction: a total literal would
-- have to respell every field, which is how a field gets silently reset.
-- ⚠️ The `DAttrib` arm is load-bearing — `@deprecated`/`@inline` wrap the decl they
-- annotate, so a `@must_use data Foo` would otherwise never be stamped at all.
stampDeclOrigin : String -> Decl -> Decl
stampDeclOrigin mid (d@(DData { dataOrigin = o })) =
  DData { d | dataOrigin = fillDeclOrigin mid o }
stampDeclOrigin mid (d@(DNewtype { newtypeOrigin = o })) =
  DNewtype { d | newtypeOrigin = fillDeclOrigin mid o }
stampDeclOrigin mid (d@(DTypeAlias { tyAliasOrigin = o })) =
  DTypeAlias { d | tyAliasOrigin = fillDeclOrigin mid o }
stampDeclOrigin mid (d@(DInterface { ifaceOrigin = o })) =
  DInterface { d | ifaceOrigin = fillDeclOrigin mid o }
stampDeclOrigin mid (DAttrib attrs d) = DAttrib attrs (stampDeclOrigin mid d)
stampDeclOrigin _ d = d

-- The decl-layer peer of `stampHeadWith`'s immunity rule: fill in ONLY a
-- still-unresolved origin, so a declaration that already carries identity is immune
-- to re-stamping under any scope, on any path, however often a driver re-runs.
--
-- ⚠️ An EMPTY module id is refused rather than promoted.  §8 I6.3 is explicit that
-- `""` is not an identity, and the failure mode if it were stamped is the worst one
-- available: two modules that both stamped `OriginModule ""` would compare EQUAL,
-- so a sentinel would manufacture exactly the cross-module confusion this carrier
-- exists to prevent.  Leaving `OriginUnresolved` is honest absence, and no
-- predicate may treat two of those as equal.
--
-- ⚠️ The three arms are enumerated rather than wildcarded so a fourth
-- `TyConOrigin` inhabitant is MADE TO SHOW UP here.  But do not overstate it: a
-- non-exhaustive match is a WARNING, exit 0 — a review aid, not a build gate.
-- `OriginBuiltin` is unreachable at this layer (a builtin head has no declaration
-- to stamp); the arm exists so that stays a stated fact rather than a wildcard.
fillDeclOrigin : String -> TyConOrigin -> TyConOrigin
fillDeclOrigin mid OriginUnresolved =
  if mid == "" then
    OriginUnresolved
  else
    OriginModule mid
fillDeclOrigin _ OriginBuiltin = OriginBuiltin
fillDeclOrigin _ (o@(OriginModule _)) = o

-- ── the INTERFACE-OCCURRENCE layer (#1110 PR C) ──────────────────────────────
-- The two layers above are about TYPE names.  This one is about INTERFACE names,
-- and the distinction is not a nicety: Medaka keeps the two in SEPARATE
-- NAMESPACES.  A single file declaring both `data Foo = Foo` and `interface Foo a
-- where …` checks clean — verified on the binary this was written against, not
-- assumed — so an interface `Foo` and a type `Foo` are two different declarations
-- that happen to share a spelling, and nothing may key them together.  That is why
-- this layer gets its own scope map rather than an entry in `tyOriginScope`, and
-- why the agreement probe reports these rows under an `iface:` prefix.
--
-- Four occurrence positions, each carrying a `TyConOrigin` since PR #1235:
--
--   `Constraint`   a `=>` predicate — anywhere a `Ty` can be written, at any
--                  nesting depth, including inside an `EAnnot` in a body.
--   `Super`        `interface Sub a requires Sup a` — the SUPERinterface.
--   `Require`      `impl I (T a) requires Eq a`.
--   `DImpl.iface`  the interface an `impl` is an impl OF.  An `impl` is a USE of
--                  an interface, not a declaration of one, which is why this is an
--                  occurrence carrier and why `declHeadOf` (the agreement probe)
--                  has no `DImpl` arm.
--
-- ⚠️ THREE OF THE FOUR ARE UNREAD.  `implOrigin` IS READ — do not extend the
-- negative to it.  Re-derived 2026-08-04, and stated with the command because a
-- negative about the whole tree has no other expiry.  Note the **`-E`**: in a BRE
-- `|` is a LITERAL, so the alternation this paragraph used to carry ran as a
-- search for the single string `superOrigin|requireOrigin|…` and matched exactly
-- one line — ITS OWN TEXT.  A probe that cannot fail manufactures the confidence
-- the claim needs, which is how the `implOrigin` half of this sentence stayed
-- "verified" while being false.
--
--     grep -rnE --include=*.mdk 'superOrigin|requireOrigin|constraintOrigin' compiler
--     grep -rn  --include=*.mdk 'implOrigin' compiler
--
-- The first prints only `frontend/ast.mdk` (the declarations + the
-- `OriginUnresolved` literals), this file's own stamper/mappers, and
-- `entries/origin_agreement_main.mdk` (the agreement PROBE, which grades them —
-- no compile stage consumes them).  The second prints four genuine READS, and
-- they landed with #1274 on `main`, so the old blanket negative was already false
-- when it was written: `ir/core_ir_lower.mdk` and `eval/eval.mdk`
-- (`ifaceIdentity o ifaceName` in the impl-head row builders) and
-- `types/typecheck.mdk` twice (`checkGradedImplHeadDecl`,
-- `implCompletenessMsgsOfMap`).  ⚠️ The DECL-layer sentence above
-- (`stampGraphTyOrigins`' fields) went FALSE the same way — Stage A-2 reads
-- `dataOrigin`/`ifaceOrigin` — so re-run both greps before reusing any of this.
-- The R-series `AmbiguousInterface` diagnostic and the re-keying of the bare-name
-- dispatch tables (#1047) are later units.  What lands here is the
-- FACT, plus the grading that makes the fact observable (`=== ORIGIN AGREEMENT
-- ===`'s `iface:` rows) — an unobserved carrier is the precondition for every
-- defect this arc exists to catch.
--
-- The immunity rule and the under/over-supply asymmetry are inherited verbatim
-- from the type layer: `fillIfaceOccOrigin` fills in ONLY a still-unresolved
-- origin, so an occurrence that already carries identity is never re-stamped, and
-- a wrong first stamp could never be corrected.  That is why the flat path claims
-- strictly less than the graph path rather than guessing.

-- ONE traversal that rewrites BOTH identity layers of a decl: `fTy` is the
-- Ty-position callback `mapTyInDecl` already takes (the type-occurrence layer),
-- `fIface carrier name origin` returns the origin an interface occurrence should
-- carry.
--
-- `carrier` is the AST FIELD NAME the occurrence was read from — one of
-- `"constraintOrigin"` / `"superOrigin"` / `"requireOrigin"` / `"implOrigin"`.  The
-- stamper ignores it (identity does not depend on which syntactic position spelled
-- the interface).  It is here for the AGREEMENT PROBE, which uses it to assert on
-- each of the four carriers SEPARATELY: without it a probe driving this shared
-- traversal reads all four by position and names none of them, so the
-- carrier-completeness ratchet in `test/typecheck_compiler_source.sh` — which
-- verifies GRADED status by looking for each field NAME in the probe — could not
-- tell "graded through a shared walk" from "not graded at all".  A tag that makes a
-- pin verifiable is worth one string argument.
--
-- 🚨 IT TAKES BOTH CALLBACKS RATHER THAN BEING A SECOND PASS, and that is a design
-- decision with two reasons, neither cosmetic:
--
--   * ALLOCATION.  The argument is structural, not empirical.  `mapTyInDecl`
--     REBUILDS every `Ty` position in a decl, expression bodies included, so a
--     second pass allocates a whole second rewritten decl tree — O(nodes) of fresh
--     garbage per decl per module, in a stage `compiler/AGENTS.md` calls GC-bound.
--     Fusing costs one extra indirect call and one extra pattern test per `Ty` node
--     and rebuilds NOTHING extra.  `diff_compiler_perf_scaling` grades a growth
--     RATIO, so a constant-factor regression of this shape is invisible to CI.
--     ⚠️ Wall-clock timing taken while writing this (a two-pass cut measured ~0.94 s
--     slower on `medaka check compiler/driver/medaka_cli.mdk`) is CONSISTENT WITH
--     that and does not ESTABLISH it: the spread across three unchanged runs of the
--     fused build was 0.92 s, i.e. the same size as the effect.  If a number is ever
--     needed here, measure ALLOCATION (deterministic) rather than time.
--   * DRIFT.  Two passes means two dispatches over the same node set, and the
--     agreement probe would drive one of them while the stamper drove the other —
--     so the probe could silently observe a SMALLER set of positions than the
--     stamper wrote, which is the one property that makes that gate worth having.
--     With one function, a new occurrence position reaches both at once.
--
-- Both consumers pass a real pair: the stamper passes `stampTyHead` +
-- `fillIfaceOccOrigin`, the probe passes its two recorders.
--
-- ⚠️ WHY THIS LIVES HERE AND NOT BESIDE `mapTyInDecl` IN `frontend/ast.mdk`, where
-- cohesion would put it.  `test/typecheck_compiler_source.sh` pins the NUMBER of
-- `TyConOrigin` mentions in `ast.mdk` outside a leading comment — the
-- form-INDEPENDENT half of the carrier ratchet, and the only half that can see a
-- future POSITIONAL carrier (`Variant String ConPayload TyConOrigin`, no field name
-- for the name-set pin to match).  Every helper signature below names
-- `TyConOrigin` twice, so hosting the walk there would need a ~+10 bump whose delta
-- is traversal plumbing rather than carriers — and that ratchet's own comment
-- argues, correctly, that slack of that size is the masking path: a real positional
-- carrier (+1) landing alongside a deleted helper (-1) would keep the count on its
-- pinned value with both pins silent.  Nothing is lost by hosting it here: both
-- consumers already import this module.
export
mapOriginsInDecl : (Ty -> (Ty, Bool)) -> (String -> String -> TyConOrigin -> TyConOrigin) -> Decl -> Decl
mapOriginsInDecl fTy fIface d =
  mapIfaceOccDeclLocal fIface (fst (mapTyInDecl (mapOriginsInTy fTy fIface) d))

-- `Constraint` is the ONE interface occurrence that lives inside a `Ty`, and
-- `TyConstrained` is itself a `Ty` node — so `mapTyInDecl`'s existing total
-- Ty-position walk already reaches every one of them, including the ones nested in
-- an interface method signature or an `EAnnot` inside a function body.  Rolling a
-- second `Ty` walk here would have to be kept in lockstep with `Ty`'s constructor
-- set AND with `mapTyInExpr`, which is exactly how the two drift.
--
-- The constraint rewrite runs BEFORE `fTy` sees the node, so a `fTy` that inspects
-- a `TyConstrained` observes the already-stamped constraints rather than a
-- half-rewritten node.  Nothing in the tree does that today; the order is fixed
-- here so it does not have to be rediscovered.
mapOriginsInTy : (Ty -> (Ty, Bool)) -> (String -> String -> TyConOrigin -> TyConOrigin) -> Ty -> (Ty, Bool)
mapOriginsInTy fTy fIface (TyConstrained cs t) =
  fTy (TyConstrained (map (mapConstraintOcc fIface) cs) t)
mapOriginsInTy fTy _ t = fTy t

-- ⚠️ Record UPDATE on a `c@` binding throughout this group, never re-construction
-- and never `constraintUnresolved`/`requireUnresolved`/`superUnresolved`: a rebuild
-- from projected fields resets an acquired identity, and the immunity rule makes
-- that reset permanent.  `test/typecheck_compiler_source.sh` pins the file set
-- allowed to call those mint helpers, and this file is deliberately not in it.
mapConstraintOcc : (String -> String -> TyConOrigin -> TyConOrigin) -> Constraint -> Constraint
mapConstraintOcc f (c@(Constraint { constraintHead = n, constraintOrigin = o })) = Constraint { c | constraintOrigin = f "constraintOrigin" n o }

mapSuperOcc : (String -> String -> TyConOrigin -> TyConOrigin) -> Super -> Super
mapSuperOcc f (s@(Super { superHead = n, superOrigin = o })) =
  Super { s | superOrigin = f "superOrigin" n o }

mapRequireOcc : (String -> String -> TyConOrigin -> TyConOrigin) -> Require -> Require
mapRequireOcc f (r@(Require { requireHead = n, requireOrigin = o })) =
  Require { r | requireOrigin = f "requireOrigin" n o }

-- The three occurrences that are DECL FIELDS rather than `Ty` positions, so no
-- `Ty`-callback can reach them: `DInterface.supers`, `DImpl.reqs`, `DImpl.iface`.
--
-- ⚠️ Every arm names a label NO SIBLING CONSTRUCTOR HAS (`ifaceOrigin` for
-- `DInterface`, `implOrigin` for `DImpl`).  That USED to be a correctness
-- requirement — the interpreter's record match discarded the constructor, so an
-- arm keyed on the shared `methods` took `DImpl` values into the `DInterface` arm
-- on `run` while the built binary compared correctly.  Fixed by #1217/#1462:
-- `matchPat`'s `VRecord` arm (`eval/eval.mdk`) compares `ctor == ctor2` before it
-- looks at any field, so these arms are safe on their constructors alone.  Keep
-- the discipline as defensive style — it keeps each arm legible.  See
-- `frontend/ast.mdk`'s `Decl` comment for the authoritative statement.
--
-- ⚠️ The `DAttrib` arm is load-bearing for the same reason `stampDeclOrigin`'s is:
-- `@deprecated`/`@inline` WRAP the decl they annotate, so a `@must_use impl …`
-- would otherwise never be stamped at all.
mapIfaceOccDeclLocal : (String -> String -> TyConOrigin -> TyConOrigin) -> Decl -> Decl
mapIfaceOccDeclLocal f (d@(DInterface { ifaceOrigin = _, supers })) =
  DInterface { d | supers = map (mapSuperOcc f) supers }
mapIfaceOccDeclLocal f (d@(DImpl { implOrigin = o, iface = n, reqs })) = DImpl { d | implOrigin = f "implOrigin" n o, reqs = map (mapRequireOcc f) reqs }
mapIfaceOccDeclLocal f (DAttrib attrs d) =
  DAttrib attrs (mapIfaceOccDeclLocal f d)
mapIfaceOccDeclLocal _ d = d

-- The interface peer of `stampHeadWith`/`fillDeclOrigin`: fill in ONLY a
-- still-unresolved origin.  The `carrier` tag is IGNORED here on purpose — which
-- syntactic position spelled an interface name has no bearing on which module
-- declared it, and a stamper that behaved differently per position would be a bug.
-- Only the probe reads the tag.
--
-- An interface name in no scope keeps `OriginUnresolved`
-- — there is no module to attribute it to, and resolve's `checkConstraint` chain
-- has already reported it (`UnknownInterface`; errors accumulate, so the tree still
-- reaches typecheck).
--
-- ⚠️ The lookup is on `ifaceKey n`, NOT on `n`.  `tyOriginScope` is ONE map holding
-- BOTH namespaces, and that is the point of the tag — see `ifaceKey`.
--
-- ⚠️ The three arms are enumerated rather than wildcarded so a fourth
-- `TyConOrigin` inhabitant is MADE TO SHOW UP here.  Do not overstate it: a
-- non-exhaustive match in this language is a WARNING at exit 0, so this is a review
-- aid, not a build gate.  `OriginBuiltin` is unreachable for an interface — the
-- language provides no built-in interfaces, `Eq`/`Ord`/`Debug` are declarations in
-- `stdlib/core.mdk` — and the arm exists so that stays a stated fact.
fillIfaceOccOrigin : OrdMap TyConOrigin -> String -> String -> TyConOrigin -> TyConOrigin
fillIfaceOccOrigin scope _ n OriginUnresolved =
  optionOr OriginUnresolved (omLookup (ifaceKey n) scope)
fillIfaceOccOrigin _ _ _ OriginBuiltin = OriginBuiltin
fillIfaceOccOrigin _ _ _ (o@(OriginModule _)) = o

-- 🚨 THE NAMESPACE TAG.  Type names and interface names are DIFFERENT NAMESPACES in
-- this language — one file may declare both `data Foo = Foo` and `interface Foo a
-- where …` and check clean — so the two populations must never meet on one key.
-- Every table in this section that mixes them (`tyOriginScope` and its layers, the
-- `known` export map threaded through `stampModulesGo`) stores an interface under
-- `iface:<Name>` and a type under the bare name.
--
-- ⚠️ ONE TAGGED MAP RATHER THAN TWO MAPS IS DELIBERATE, and it is what keeps the
-- change ADDITIVE for `test/selfproc_goldens/legA/frontend.resolve.golden`: a second
-- map would have to be threaded as a new parameter through `stampOneModule` /
-- `stampModulesGo` / `tyOriginScope`, changing three PINNED signatures for plumbing.
-- The tag gets the same separation with no signature movement — and it is the same
-- shape `insertIfaceParamKinds`'s `<iface>@<slot>` key already uses in
-- `types/typecheck.mdk` for exactly this reason.
--
-- `:` cannot occur in a Medaka identifier, so a tagged key can never collide with a
-- bare one, and a bare-name lookup can never accidentally hit an interface row.
export
ifaceKey : String -> String
ifaceKey n = "iface:\{n}"

-- The interface peers of `typeDeclaredIn` / `ownTyOrigin`, tagging as they pair.
ifaceDeclaredIn : String -> String -> (String, String)
ifaceDeclaredIn mid n = (ifaceKey n, mid)

ownIfaceOrigin : String -> String -> (String, TyConOrigin)
ownIfaceOrigin mid n = (ifaceKey n, OriginModule mid)

-- ALL interfaces a decl list declares, public or not — a module's own private
-- interface is in its own scope.  The `DAttrib` arm is why this is not
-- `map fst (interfaceList prog)`: `interfaceList` has no such arm, so it misses an
-- `@attr`-wrapped interface.
interfaceNamesOf : List Decl -> List String
interfaceNamesOf [] = []
interfaceNamesOf ((DInterface { name = n, ifaceOrigin = _ })::rest) =
  n :: interfaceNamesOf rest
interfaceNamesOf ((DAttrib _ d)::rest) = interfaceNamesOf (d::rest)
interfaceNamesOf (_::rest) = interfaceNamesOf rest

-- ── the resolve → typecheck channel ─────────────────────────────────────────
-- Resolve's other entries return `List ResError` and nothing else, so the drivers
-- have always typechecked the ORIGINAL tree; there was no channel for resolve to
-- hand anything BACK.  These two are it: a pure `decls -> decls` transform the
-- typecheck module drivers call in their preamble, exactly as `stampBindingIds`
-- (#837, above) is called from `checkBodyImpl`.
--
-- ⚠️ Why a CALL-THROUGH and not decls threaded through the drivers: `medaka build`
-- shells out to a separate `medaka_emitter` process whose pipeline
-- (`driveModules → runEmitWith → mangleUnits → elaborateModules`) never runs
-- resolve at all — resolve's resolution pass is DCE'd out of that binary.  Data
-- threaded from a `check`-path driver cannot reach it, so identity acquired that
-- way would exist on `check` and not on `build`: a new instance of the #1070
-- check≠build divergence class.  Calling from the driver preamble puts the
-- acquisition INSIDE the seam both paths already share.

-- Acquire identity for a whole module GRAPH, dependency-first, threading each
-- module's exported type origins forward the way `resolveModulesErrorsG` threads
-- `ModuleExports`.  Returns the stamped prelude and the stamped modules.
export
stampGraphTyOrigins : List Decl -> List (String, List Decl) -> (List Decl, List (String, List Decl))
stampGraphTyOrigins coreDecls modules =
  let coreTypes = map (typeDeclaredIn "core") (dataRecordNames coreDecls) ++ map (ifaceDeclaredIn "core") (interfaceNamesOf coreDecls)
  let coreS = stampOneModule coreTypes omEmpty "core" coreDecls
  (coreS, stampModulesGo coreTypes omEmpty modules)

-- Both identity layers for ONE module, in one place so the prelude pass above and
-- the per-module walk below cannot drift apart — the `evalModules`/`cevalModules`
-- lockstep hazard, in miniature.  Declarations first, then the occurrence heads
-- (type AND interface, one walk): the two are independent (the occurrence scope is
-- built from `dataRecordNames`/`interfaceNamesOf`, which read names, not origins),
-- so the order is for readability only.
stampOneModule : List (String, String) -> OrdMap (List (String, String)) -> String -> List Decl -> List Decl
stampOneModule coreTypes known mid prog =
  stampTyOrigins
    (tyOriginScope coreTypes known mid prog)
    (stampDeclOrigins mid prog)

stampModulesGo : List (String, String) -> OrdMap (List (String, String)) -> List (String, List Decl) -> List (String, List Decl)
stampModulesGo _ _ [] = []
stampModulesGo coreTypes known ((mid, prog)::rest) =
  (mid, stampOneModule coreTypes known mid prog) ::
    stampModulesGo
      coreTypes
      (omInsert mid (typeOriginExports known mid prog) known)
      rest

-- The FLAT (loader-less) analogue, for the entries that typecheck a program with
-- no module graph.  ⚠️ THE CONSUMER LIST HERE MOVED, 2026-08-26: it used to read
-- "`medaka check` on a no-import file, the LSP, `doc`, `check-policy`, the
-- playground buffer, the repl".  E-1 (#1115) migrated `check`, `doc` and the repl
-- onto the Module arm; what still reaches FLAT is the LSP's completion pass,
-- `check-policy`/`manifest` (deliberately parked — `--fn <name>` is arbitrary user
-- input looked up directly in the effect table, so it needs prelude schemes), the
-- playground buffer, and the probe entries (`typecheck_main`, `check_batch`,
-- `check_match_main`, `origin_agreement_main`, `selfproc_tc_probe`,
-- `check_flat_diags_main`).  Do not trust this sentence over
-- `test/CHECK-WRAPPER-CALLERS.txt`, which is the gated ledger.
--
-- 🚨 IT STAMPS ONLY WHAT A DRIVER WITH NO LOADER ACTUALLY KNOWS: builtin heads, and
-- the PRELUDE's own types when the caller passed the prelude separately.  It does
-- NOT stamp the user program's own declarations, and the omission is the whole
-- point of the function.  ⚠️ It stamps only what is reachable from `coreDecls` — the
-- PRELUDE's own type names plus the builtins — so nothing the USER PROGRAM imports
-- is stamped either, and that half is not said by the line above.  `prog` is not
-- even in scope when the stamping set is built: `flatTyOriginScope` takes ONLY
-- `coreDecls`, so there is no `DUse`/`usePathsOf` term over the user program here at
-- all.  Contrast the GRAPH path's `tyOriginScope`, which does walk `prog`'s real
-- imports (`flatMap (importedTypeOrigins known) (usePathsOf prog)`) — that machinery
-- is exactly what is absent here, which is why flat's claims are a strict subset of
-- graph's.  It matters because `checkProgramSchemesWithRuntime` serves the LSP,
-- `check-policy`/`manifest`, and the playground on buffers that may well have
-- imports (`doc` moved OFF it 2026-08-26 — see the consumer note at the top of
-- this comment), so what this function leaves unstamped reaches further than
-- "the user's own declarations."
--
-- A module id is a fact about a FILE IN A PROJECT, produced by the loader.  These
-- drivers do not have one — `runCheck` receives SOURCE TEXT, the playground has a
-- buffer, the repl has no file at all — so any id minted here would be invented.
-- The first cut of this function invented `"__user__"`, and that is exactly the
-- failure the design forbids: `stampTyHead`'s immunity rule (fill in only an
-- `OriginUnresolved` head) is what makes re-stamping impossible, and it makes a
-- WRONG FIRST STAMP PERMANENT.  `medaka run` on a no-import file reaches BOTH arms
-- in ONE process — the flat arm for diagnostics (`analyzeLocatedG`) and the graph
-- arm for elaboration (`elaborateModules`, module id from the loader) — so the two
-- claims were about the same declarations, and only one of them could be true.
--
-- ⚠️ UNDER-supplying identity is correctable by a later graph pass; OVER-supplying a
-- wrong one is not.  That asymmetry, not convenience, is why this claims less.
--
-- The absence costs nothing to a single-file program: module identity only
-- disambiguates names that meet ACROSS modules, and a flat program has exactly one
-- user module.  Its one genuine second module is the prelude, and that IS stamped
-- (`core`) whenever its boundary is given.  ⚠️ When it is NOT given (`coreDecls =
-- []` while the caller has flattened the prelude into `prog` — the internal
-- `checkProgramSeeded` discovery passes), the boundary is unknown, so the prelude's
-- types are left unstamped rather than being claimed by the user's module.  An
-- earlier cut of this function got that wrong and attributed `Option`/`Result`/
-- `Ordering` to the user module.
--
-- ⚠️ RESIDUAL, greppable as `#1110 flat-identity`: giving the flat path REAL
-- identity needs a loader-derived module id threaded into the `check`/LSP/doc
-- entries, or the single-file path routed through the 1-module graph driver
-- (`checkModulesEntryFull`).  Both are DRIVER changes that move the `check` dump,
-- so neither belongs in a byte-identical stamping PR.
--
-- ⚠️ THE SUBSET PROPERTY ABOVE HAS A PRECONDITION THIS SIGNATURE DOES NOT ENFORCE.
-- Which of the two `List Decl` arguments IS the prelude is POSITIONAL CONVENTION,
-- not a type — `List Decl -> List Decl -> List Decl` cannot distinguish `coreDecls`
-- from `prog`.  A future caller that passes a non-prelude list as `coreDecls`
-- stamps THAT list's types `core`, PERMANENTLY: the immunity rule (`stampTyHead`
-- fills only an `OriginUnresolved` head) means a head that already carries an
-- origin is never re-stamped, so nothing would notice.  This is the SAME CLASS of
-- defect the module-id parameter's removal made unrepresentable (see the
-- `"__user__"` paragraph above) — displaced one argument to the left instead of
-- eliminated.  The subset property holds only while every caller passes the real
-- prelude as `coreDecls`; that is a fact about the CALL SITES, re-verify it there,
-- do not assume it from this signature.
--
-- ⚠️ #1110 PR C ADDED THE INTERFACE-OCCURRENCE LAYER HERE, ON EXACTLY THE SAME
-- TERMS AND WITH NO NEW MACHINERY: `flatTyOriginScope` now also carries the
-- PRELUDE's own interfaces (tagged `iface:<Name>`), and nothing else.  No
-- `interfaceNamesOf prog` term (the buffer has no module id), no `usePathsOf prog`
-- term (there is no `known` map to resolve an import against).  So the flat arm's
-- interface claims are a strict SUBSET of the graph arm's and agree with it on that
-- subset — the graph path stamps the prelude's own interfaces `core` too.
--
-- ⚠️ The one shape that could break the subset property is a buffer that
-- RE-DECLARES a prelude interface name: flat would say `core` where graph says the
-- buffer's module.  It is unreachable in an accepted program — resolve rejects it
-- outright (`Duplicate interface: Eq`, verified on the binary this was written
-- against; the type layer is identical, `Duplicate type: Option`) — so the only way
-- to reach it is a program that is already being rejected on other grounds.  Stated
-- rather than silently relied on, because it is that property, and not the
-- diagnostic's wording, that the subset claim rests on.
export
stampFlatTyOrigins : List Decl -> List Decl -> List Decl
stampFlatTyOrigins coreDecls prog =
  stampTyOrigins (flatTyOriginScope coreDecls) prog

-- Builtins, plus the prelude's own types AND interfaces when the caller told us
-- where the prelude is.  No `dataRecordNames prog` / `interfaceNamesOf prog` term:
-- see `stampFlatTyOrigins`, that omission is the point.  There is no builtins term
-- for the interface namespace and its absence is a fact rather than an oversight —
-- an interface is always DECLARED by some module, so §8 I6.2's "one program-global
-- identity for a language-provided head" has no interface instance; `Eq`/`Ord`/
-- `Debug` are `stdlib/core.mdk` declarations and arrive as `mod:core`.
flatTyOriginScope : List Decl -> OrdMap TyConOrigin
flatTyOriginScope coreDecls =
  omFromPairs
    (map
      importedTyOrigin
      (map (typeDeclaredIn "core") (dataRecordNames coreDecls) ++ map (ifaceDeclaredIn "core") (interfaceNamesOf coreDecls)))
    (omFromPairs builtinTyOrigins omEmpty)

-- ── #1280: the scope `stdlib/runtime.mdk`'s EXTERN signatures are stamped under ─
-- The identity-SUPPLY gap Stage A-2 left open, CLOSED HERE: `externSchemes`
-- (`types/typecheck.mdk`) used to turn each `DExtern`'s declared `Ty` into a
-- `Scheme` OUTSIDE `stampTyOrigins`' walk, so every `Mono` flowing out of an
-- extern's declared type reached its consumers `OriginUnresolved`.  MEASURED
-- before the fix, on this tree, on BOTH driver arms (goal-side dispatch head for
-- a user-declared interface at `Float`):
--
--   probeMeth x            where x : Float   ->  …:type7:builtin0:5:Float
--   probeMeth (intToFloat 1)                 ->  …:type4:bare0:5:Float
--
-- 🚨 THE POPULATION IS NOT UNIFORM, AND EITHER UNIFORM ANSWER IS A FALSE REJECT.
-- Derive the name set, do not read one here:
--
--   grep -E '^extern ' stdlib/runtime.mdk | sed -E 's/--.*$//; s/<[^>]*>//g' \
--     | grep -oE '\b[A-Z][A-Za-z0-9_]*' | sort -u
--
-- It splits: the members of `primitiveTypes` are LANGUAGE-provided heads whose
-- every other occurrence is stamped `OriginBuiltin` by `builtinTyOrigins`, while
-- `Option`/`Ordering`/`Result` are ordinary `data` declarations in
-- `stdlib/core.mdk` whose every other occurrence — and whose `Mono` mint out of
-- `registerVariants`' `dataOrigin` — is `OriginModule "core"`.  `sameTyConHead`
-- (`frontend/ast.mdk`) conflicts two heads exactly when BOTH carry an identity and
-- the identities differ, so stamping this population uniformly `OriginBuiltin`
-- refuses every prelude use of an extern returning `Option`, and stamping it
-- uniformly `core` refuses `1 + 1`.  The only correct answer is the SAME
-- PER-NAME scope every other occurrence of those names is already stamped under,
-- which is what this is.
--
-- ⚠️ ONE scope serves BOTH arms, and that is a property of `runtime.mdk`, not a
-- convenience: it declares NO types of its own (`grep -nE '^(data|newtype|type|
-- interface) ' stdlib/runtime.mdk` is empty), so it has nothing to attribute to a
-- module of its own and needs neither the graph arm's import layer
-- (`tyOriginScope`'s `usePathsOf prog` term — `runtime.mdk` has no `import`) nor
-- an own-declarations layer.  What is left is exactly builtins ⊎ the prelude's own
-- names, i.e. `flatTyOriginScope` — which the GRAPH arm agrees with on this
-- population: `tyOriginScope`'s builtin and prelude layers are the same two lists.
-- So this is deliberately NOT `stampFlatTyOrigins`' "flat drivers claim less"
-- asymmetry; on this population there is nothing more for the graph arm to claim.
--
-- ⚠️ It is a SCOPE and not a stamper because its consumer must be the ONE that
-- also builds the schemes — see `externSchemes`, which takes this rather than a
-- `List Decl` prelude so that no caller can hand it two `List Decl`s the wrong way
-- round (`stampFlatTyOrigins`' own comment records that positional hazard).
export
externTyOriginScope : List Decl -> OrdMap TyConOrigin
externTyOriginScope coreDecls = flatTyOriginScope coreDecls

-- ── the AGREEMENT TAP (#1110) ────────────────────────────────────────────────
-- ⚠️ NOTHING in the compiler reads this, and nothing may.  It exists so a GATE can
-- observe what a driver ACTUALLY stamped — the one fact the two S0s fixed in #1219
-- had in common.  Both (F1: a hardcoded `"__user__"` at one of three call sites;
-- F2: a caller handing this file's flat stamper an EMPTY prelude) were *correct for
-- the arguments they were given*, so a probe that picks its own arguments and calls
-- `stampFlatTyOrigins`/`stampGraphTyOrigins` directly re-encodes the assumption it
-- is meant to test and reports green.  The claim has to be read off the driver.
--
-- The GRAPH drivers need no tap: `elaborateModules` RETURNS the stamped trees, so a
-- probe reads them straight out of its own call.  The FLAT driver
-- (`checkProgramSeededSplit`) returns SCHEMES, not decl trees, so the trees it
-- stamped are otherwise unobservable from outside.  Hence this, and only this.
-- (`Mono.TCon` has carried an origin since #1110 unit D, so the schemes are no
-- longer origin-free — but they only cover heads reaching a top-level binding's
-- type, which is a strictly smaller set than the decls this tap retains.)
--
-- Shape: OFF by default; one `Bool` read on the hot path; and it retains the
-- decl lists BY REFERENCE (no copy, no projection, no rendering) so the probe
-- owns the format and this file owns nothing but the fact.
originTraceEnabled : Ref Bool
originTraceEnabled = Ref False

originTraceLog : Ref (List (String, List Decl))
originTraceLog = Ref []

-- Probe-only.  Enabling CLEARS the log too, so a probe that drives the flat entry
-- once per module can never attribute one module's rows to the next.
export
setOriginTrace : Bool -> Unit
setOriginTrace b =
  originTraceLog := []
  originTraceEnabled := b

-- A flat driver records the decls it is about to hand to typecheck, labelled with
-- WHICH HALF they are.  A no-op unless a probe turned the trace on.
export
noteOriginTrace : String -> List Decl -> Unit
noteOriginTrace label decls =
  if !originTraceEnabled then
    originTraceLog := !originTraceLog ++ [(label, decls)]
  else
    ()

-- Drain: the recorded (label, decls) pairs in call order, log emptied.
export
takeOriginTrace : Unit -> List (String, List Decl)
takeOriginTrace _ =
  let rows = !originTraceLog
  originTraceLog := []
  rows
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "orElseLoc" false) (mem "Lit" true) (mem "Ty" true) (mem "TyConOrigin" true) (mem "mapTyInDecl" false) (mem "firstTyLoc" false) (mem "firstTyLocList" false) (mem "Constraint" true) (mem "Addr" true) (mem "Pat" true) (mem "RecPatField" true) (mem "Guard" true) (mem "Arm" true) (mem "DoStmt" true) (mem "InterpPart" true) (mem "GuardArm" true) (mem "FieldAssign" true) (mem "Section" true) (mem "FunClause" true) (mem "LetBind" true) (mem "Expr" true) (mem "UseMember" true) (mem "UsePath" true) (mem "useMemberLocal" false) (mem "qualifiedLocal" false) (mem "PropParam" true) (mem "MethodDefault" true) (mem "IfaceMethod" true) (mem "Super" true) (mem "Require" true) (mem "ImplMethod" true) (mem "DataVis" true) (mem "Field" true) (mem "ConPayload" true) (mem "Variant" true) (mem "Decl" true))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omInsert" false) (mem "omHasKey" false) (mem "omDelete" false) (mem "omLookup" false) (mem "omFromNames" false) (mem "omFromPairs" false) (mem "omKeys" false) (mem "omSize" false) (mem "omMapValues" false))))
(DUse false (UseGroup ("support" "opcount") ((mem "opBump" false))))
(DUse false (UseGroup ("support" "util") ((mem "contains" false) (mem "editDistance" false) (mem "minI" false) (mem "maxI" false) (mem "listLen" false) (mem "escStr" false) (mem "joinNl" false) (mem "joinWith" false) (mem "lookupAssoc" false) (mem "reverseL" false) (mem "initList" false) (mem "joinDot" false) (mem "filterList" false) (mem "anyList" false) (mem "dedup" false) (mem "dedupBy" false))))
(DData Public "ResError" () ((variant "UnboundVariable" (ConPos (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")) (TyApp (TyCon "Option") (TyCon "String")))) (variant "UnboundVariableExported" (ConPos (TyCon "String") (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "UnboundVariableIsModule" (ConPos (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "UnknownConstructor" (ConPos (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")) (TyApp (TyCon "Option") (TyCon "String")))) (variant "UnknownType" (ConPos (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")) (TyApp (TyCon "Option") (TyCon "String")))) (variant "UnknownEffect" (ConPos (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "UnknownField" (ConPos (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "FieldNotInRecord" (ConPos (TyCon "String") (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "DuplicateDefinition" (ConPos (TyCon "String") (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "UnknownInterface" (ConPos (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "MethodNotInInterface" (ConPos (TyCon "String") (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "ExternWithBody" (ConPos (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "PrivateNameAccess" (ConPos (TyCon "String") (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "NoExportedConstructors" (ConPos (TyCon "String") (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "NewtypeCtorNotExported" (ConPos (TyCon "String") (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "AbstractFieldAccess" (ConPos (TyCon "String") (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "UnknownModule" (ConPos (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "NonRecursiveValueLet" (ConPos (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "DuplicateBinding" (ConPos (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "DuplicateValueBinding" (ConPos (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "DuplicateSignature" (ConPos (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")) (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "DuplicateBinder" (ConPos (TyCon "String") (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "AsPatternMisplaced" (ConPos (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "AmbiguousOccurrence" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "AmbiguousConstructor" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "AmbiguousType" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "AmbiguousInterface" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "InternalExternAccess" (ConPos (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "ReassignImmutable" (ConPos (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "DuplicateInterfaceMethod" (ConPos (TyCon "String") (TyCon "String") (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc"))))) ())
(DTypeSig true "resErrorDidYouMean" (TyFun (TyCon "ResError") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "resErrorDidYouMean" ((PCon "UnboundVariable" (PVar "n") PWild (PCon "Some" (PVar "sug")))) (EApp (EVar "Some") (ETuple (EVar "n") (EVar "sug"))))
(DFunDef false "resErrorDidYouMean" ((PCon "UnknownConstructor" (PVar "n") PWild (PCon "Some" (PVar "sug")))) (EApp (EVar "Some") (ETuple (EVar "n") (EVar "sug"))))
(DFunDef false "resErrorDidYouMean" ((PCon "UnknownType" (PVar "n") PWild (PCon "Some" (PVar "sug")))) (EApp (EVar "Some") (ETuple (EVar "n") (EVar "sug"))))
(DFunDef false "resErrorDidYouMean" (PWild) (EVar "None"))
(DTypeSig true "resErrorLoc" (TyFun (TyCon "ResError") (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "resErrorLoc" ((PCon "UnboundVariable" PWild (PVar "l") PWild)) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "UnboundVariableExported" PWild PWild (PVar "l"))) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "UnboundVariableIsModule" PWild (PVar "l"))) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "UnknownConstructor" PWild (PVar "l") PWild)) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "UnknownType" PWild (PVar "l") PWild)) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "UnknownEffect" PWild (PVar "l"))) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "UnknownField" PWild (PVar "l"))) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "FieldNotInRecord" PWild PWild (PVar "l"))) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "DuplicateDefinition" PWild PWild (PVar "l"))) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "UnknownInterface" PWild (PVar "l"))) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "MethodNotInInterface" PWild PWild (PVar "l"))) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "ExternWithBody" PWild (PVar "l"))) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "PrivateNameAccess" PWild PWild (PVar "l"))) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "NoExportedConstructors" PWild PWild (PVar "l"))) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "NewtypeCtorNotExported" PWild PWild (PVar "l"))) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "AbstractFieldAccess" PWild PWild (PVar "l"))) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "UnknownModule" PWild (PVar "l"))) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "NonRecursiveValueLet" PWild (PVar "l"))) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "DuplicateBinding" PWild (PVar "l"))) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "DuplicateValueBinding" PWild (PVar "l"))) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "DuplicateSignature" PWild (PVar "l") PWild)) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "DuplicateBinder" PWild PWild (PVar "l"))) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "AsPatternMisplaced" (PVar "l"))) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "AmbiguousOccurrence" PWild PWild (PVar "l"))) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "AmbiguousConstructor" PWild PWild (PVar "l"))) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "AmbiguousType" PWild PWild (PVar "l"))) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "AmbiguousInterface" PWild PWild (PVar "l"))) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "InternalExternAccess" PWild (PVar "l"))) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "ReassignImmutable" PWild (PVar "l"))) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "DuplicateInterfaceMethod" PWild PWild PWild (PVar "l"))) (EVar "l"))
(DData Public "Env" () ((variant "Env" (ConNamed (field "values" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "types" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "ctors" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "fields" (TyApp (TyCon "List") (TyCon "String"))) (field "fieldOwners" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (field "fieldOwnersIdx" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String")))) (field "interfaces" (TyApp (TyCon "List") (TyCon "String"))) (field "ifaceMethods" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))) (field "effects" (TyApp (TyCon "List") (TyCon "String"))) (field "imported" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "importedModuleValues" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))) (field "ambiguous" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))) (field "ctorAmbiguous" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))) (field "typeAmbiguous" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))) (field "ifaceAmbiguous" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))) (field "internalGuard" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "sugValues" (TyApp (TyCon "List") (TyCon "SugCand"))) (field "sugTypes" (TyApp (TyCon "List") (TyCon "SugCand")))))) ())
(DTypeSig true "internalExterns" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "internalExterns" () (EListLit (ELit (LString "arrayGetUnsafe")) (ELit (LString "arraySetUnsafe")) (ELit (LString "arrayBlit")) (ELit (LString "arrayFill")) (ELit (LString "bytesToFloat64"))))
(DTypeSig true "internalGuardFor" (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "internalGuardFor" ((PCon "True")) (EListLit))
(DFunDef false "internalGuardFor" ((PCon "False")) (EVar "internalExterns"))
(DTypeSig false "buildFieldOwnerIndex" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "buildFieldOwnerIndex" ((PVar "pairs")) (EApp (EApp (EVar "omMapValues") (EVar "reverseL")) (EApp (EApp (EVar "indexOwners") (EVar "pairs")) (EVar "omEmpty"))))
(DTypeSig false "indexOwners" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "indexOwners" ((PList) (PVar "m")) (EVar "m"))
(DFunDef false "indexOwners" ((PCons (PTuple (PVar "f") (PVar "owner")) (PVar "rest")) (PVar "m")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "f")) (EVar "m")) (arm (PCon "Some" (PVar "os")) () (EApp (EApp (EVar "indexOwners") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "f")) (EBinOp "::" (EVar "owner") (EVar "os"))) (EVar "m")))) (arm (PCon "None") () (EApp (EApp (EVar "indexOwners") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "f")) (EListLit (EVar "owner"))) (EVar "m"))))))
(DTypeSig false "ownersOf" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "ownersOf" ((PVar "field") (PVar "idx")) (EBlock (DoLet false false PWild (EApp (EVar "opBump") (ELit LUnit))) (DoExpr (EMatch (EApp (EApp (EVar "omLookup") (EVar "field")) (EVar "idx")) (arm (PCon "Some" (PVar "owners")) () (EVar "owners")) (arm (PCon "None") () (EListLit))))))
(DTypeSig false "patBindings" (TyFun (TyCon "Pat") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "patBindings" ((PCon "PVar" (PVar "x") PWild)) (EListLit (EVar "x")))
(DFunDef false "patBindings" ((PCon "PWild")) (EListLit))
(DFunDef false "patBindings" ((PCon "PLit" PWild)) (EListLit))
(DFunDef false "patBindings" ((PCon "PCon" PWild (PVar "ps"))) (EApp (EApp (EVar "flatMap") (EVar "patBindings")) (EVar "ps")))
(DFunDef false "patBindings" ((PCon "PCons" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EVar "patBindings") (EVar "a")) (EApp (EVar "patBindings") (EVar "b"))))
(DFunDef false "patBindings" ((PCon "PTuple" (PVar "ps"))) (EApp (EApp (EVar "flatMap") (EVar "patBindings")) (EVar "ps")))
(DFunDef false "patBindings" ((PCon "PList" (PVar "ps"))) (EApp (EApp (EVar "flatMap") (EVar "patBindings")) (EVar "ps")))
(DFunDef false "patBindings" ((PCon "PAs" (PVar "x") PWild (PVar "p"))) (EBinOp "::" (EVar "x") (EApp (EVar "patBindings") (EVar "p"))))
(DFunDef false "patBindings" ((PCon "PRng" PWild PWild PWild)) (EListLit))
(DFunDef false "patBindings" ((PCon "PRec" PWild (PVar "fields") PWild)) (EApp (EApp (EVar "flatMap") (EVar "recFieldBindings")) (EVar "fields")))
(DTypeSig false "recFieldBindings" (TyFun (TyCon "RecPatField") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "recFieldBindings" ((PCon "RecPatField" (PVar "fname") PWild (PCon "None"))) (EListLit (EVar "fname")))
(DFunDef false "recFieldBindings" ((PCon "RecPatField" PWild PWild (PCon "Some" (PVar "p")))) (EApp (EVar "patBindings") (EVar "p")))
(DTypeSig false "patsBindings" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "patsBindings" ((PVar "ps")) (EApp (EApp (EVar "flatMap") (EVar "patBindings")) (EVar "ps")))
(DTypeSig false "patGroupDupErrors" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "patGroupDupErrors" ((PVar "loc") (PVar "kind") (PVar "ps")) (EApp (EApp (EVar "map") (ELam ((PVar "n")) (EApp (EApp (EApp (EVar "DuplicateBinder") (EVar "kind")) (EVar "n")) (EVar "loc")))) (EApp (EApp (EVar "findDups") (EListLit)) (EApp (EVar "patsBindings") (EVar "ps")))))
(DTypeSig false "checkType" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "checkType" ((PVar "cur") (PVar "env") (PRec "TyCon" ((rf "tyConName" (PVar "n")) (rf "tyConLoc" (PVar "loc"))) false)) (EIf (EBinOp "||" (EBinOp "||" (EApp (EApp (EVar "omHasKey") (EVar "n")) (EFieldAccess (EVar "env") "types")) (EApp (EApp (EVar "omHasKey") (EVar "n")) (EFieldAccess (EVar "env") "imported"))) (EApp (EVar "isTupleCtorTyName") (EVar "n"))) (EApp (EApp (EApp (EVar "ambiguousTypeErrors") (EVar "env")) (EVar "n")) (EApp (EApp (EVar "orElseLoc") (EVar "loc")) (EVar "cur"))) (EListLit (EApp (EApp (EApp (EVar "UnknownType") (EVar "n")) (EApp (EApp (EVar "orElseLoc") (EVar "loc")) (EVar "cur"))) (EApp (EApp (EVar "suggestType") (EVar "env")) (EVar "n"))))))
(DFunDef false "checkType" (PWild PWild (PCon "TyVar" PWild)) (EListLit))
(DFunDef false "checkType" ((PVar "cur") (PVar "env") (PCon "TyApp" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EApp (EApp (EVar "checkType") (EVar "cur")) (EVar "env")) (EVar "a")) (EApp (EApp (EApp (EVar "checkType") (EVar "cur")) (EVar "env")) (EVar "b"))))
(DFunDef false "checkType" ((PVar "cur") (PVar "env") (PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EApp (EApp (EVar "checkType") (EVar "cur")) (EVar "env")) (EVar "a")) (EApp (EApp (EApp (EVar "checkType") (EVar "cur")) (EVar "env")) (EVar "b"))))
(DFunDef false "checkType" ((PVar "cur") (PVar "env") (PCon "TyTuple" (PVar "ts"))) (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "checkType") (EVar "cur")) (EVar "env"))) (EVar "ts")))
(DFunDef false "checkType" ((PVar "cur") (PVar "env") (PCon "TyEffect" (PVar "labels") PWild (PVar "t"))) (EBinOp "++" (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "checkEffect") (EVar "cur")) (EVar "env"))) (EApp (EApp (EVar "map") (EVar "fst")) (EVar "labels"))) (EApp (EApp (EApp (EVar "checkType") (EVar "cur")) (EVar "env")) (EVar "t"))))
(DFunDef false "checkType" ((PVar "cur") (PVar "env") (PCon "TyConstrained" (PVar "cs") (PVar "t"))) (EBinOp "++" (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "checkConstraint") (EApp (EApp (EVar "orElseLoc") (EVar "cur")) (EApp (EVar "firstTyLoc") (EVar "t")))) (EVar "env"))) (EVar "cs")) (EApp (EApp (EApp (EVar "checkType") (EVar "cur")) (EVar "env")) (EVar "t"))))
(DFunDef false "checkType" ((PVar "cur") (PVar "env") (PCon "TyRow" (PVar "labels") PWild PWild)) (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "checkEffect") (EVar "cur")) (EVar "env"))) (EApp (EApp (EVar "map") (EVar "fst")) (EVar "labels"))))
(DTypeSig false "builtInEffects" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "builtInEffects" () (EListLit (ELit (LString "IO")) (ELit (LString "Rand")) (ELit (LString "Stdout")) (ELit (LString "Stderr")) (ELit (LString "Stdin")) (ELit (LString "Clock")) (ELit (LString "Env")) (ELit (LString "Exec")) (ELit (LString "Net")) (ELit (LString "FileRead")) (ELit (LString "FileWrite")) (ELit (LString "FFI"))))
(DTypeSig false "checkEffect" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "checkEffect" ((PVar "cur") (PVar "env") (PVar "e")) (EIf (EBinOp "||" (EApp (EApp (EVar "contains") (EVar "e")) (EVar "builtInEffects")) (EApp (EApp (EVar "contains") (EVar "e")) (EFieldAccess (EVar "env") "effects"))) (EListLit) (EListLit (EApp (EApp (EVar "UnknownEffect") (EVar "e")) (EVar "cur")))))
(DTypeSig false "ambiguousTypeErrors" (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "ambiguousTypeErrors" ((PVar "env") (PVar "n") (PVar "loc")) (EApp (EApp (EVar "whenL") (EApp (EApp (EVar "isTypeAmbiguous") (EVar "env")) (EVar "n"))) (EListLit (EApp (EApp (EApp (EVar "AmbiguousType") (EVar "n")) (EApp (EApp (EVar "typeAmbigMods") (EVar "env")) (EVar "n"))) (EVar "loc")))))
(DTypeSig false "ambiguousCtorErrors" (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "ambiguousCtorErrors" ((PVar "env") (PVar "n") (PVar "loc")) (EApp (EApp (EVar "whenL") (EApp (EApp (EVar "isCtorAmbiguous") (EVar "env")) (EVar "n"))) (EListLit (EApp (EApp (EApp (EVar "AmbiguousConstructor") (EVar "n")) (EApp (EApp (EVar "ctorAmbigMods") (EVar "env")) (EVar "n"))) (EVar "loc")))))
(DTypeSig false "ambiguousHeadErrors" (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "ambiguousHeadErrors" ((PVar "env") (PVar "n") (PVar "loc")) (EMatch (EApp (EApp (EApp (EVar "ambiguousTypeErrors") (EVar "env")) (EVar "n")) (EVar "loc")) (arm (PList) () (EApp (EApp (EApp (EVar "ambiguousCtorErrors") (EVar "env")) (EVar "n")) (EVar "loc"))) (arm (PVar "es") () (EVar "es"))))
(DTypeSig false "ambiguousIfaceErrors" (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "ambiguousIfaceErrors" ((PVar "env") (PVar "n") (PVar "loc")) (EApp (EApp (EVar "whenL") (EApp (EApp (EVar "isIfaceAmbiguous") (EVar "env")) (EVar "n"))) (EListLit (EApp (EApp (EApp (EVar "AmbiguousInterface") (EVar "n")) (EApp (EApp (EVar "ifaceAmbigMods") (EVar "env")) (EVar "n"))) (EVar "loc")))))
(DTypeSig false "checkConstraint" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyCon "Constraint") (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "checkConstraint" ((PVar "cur") (PVar "env") (PRec "Constraint" ((rf "constraintHead" (PVar "iface")) (rf "constraintArgs" (PVar "args"))) false)) (EBinOp "++" (EIf (EApp (EApp (EVar "contains") (EVar "iface")) (EFieldAccess (EVar "env") "interfaces")) (EApp (EApp (EApp (EVar "ambiguousIfaceErrors") (EVar "env")) (EVar "iface")) (EApp (EApp (EVar "orElseLoc") (EApp (EVar "firstTyLocList") (EVar "args"))) (EVar "cur"))) (EListLit (EApp (EApp (EVar "UnknownInterface") (EVar "iface")) (EVar "cur")))) (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "checkType") (EVar "cur")) (EVar "env"))) (EVar "args"))))
(DTypeSig false "checkPat" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyCon "Pat") (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "checkPat" ((PVar "cur") (PVar "env") (PCon "PCon" (PVar "c") (PVar "ps"))) (EBinOp "++" (EIf (EBinOp "||" (EApp (EApp (EVar "omHasKey") (EVar "c")) (EFieldAccess (EVar "env") "ctors")) (EApp (EApp (EVar "omHasKey") (EVar "c")) (EFieldAccess (EVar "env") "imported"))) (EApp (EApp (EApp (EVar "ambiguousCtorErrors") (EVar "env")) (EVar "c")) (EVar "cur")) (EListLit (EApp (EApp (EApp (EVar "UnknownConstructor") (EVar "c")) (EVar "cur")) (EApp (EVar "suggestCtor") (EVar "c"))))) (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "checkPat") (EVar "cur")) (EVar "env"))) (EVar "ps"))))
(DFunDef false "checkPat" ((PVar "cur") (PVar "env") (PCon "PCons" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EApp (EApp (EVar "checkPat") (EVar "cur")) (EVar "env")) (EVar "a")) (EApp (EApp (EApp (EVar "checkPat") (EVar "cur")) (EVar "env")) (EVar "b"))))
(DFunDef false "checkPat" ((PVar "cur") (PVar "env") (PCon "PTuple" (PVar "ps"))) (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "checkPat") (EVar "cur")) (EVar "env"))) (EVar "ps")))
(DFunDef false "checkPat" ((PVar "cur") (PVar "env") (PCon "PList" (PVar "ps"))) (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "checkPat") (EVar "cur")) (EVar "env"))) (EVar "ps")))
(DFunDef false "checkPat" ((PVar "cur") (PVar "env") (PCon "PAs" PWild PWild (PVar "p"))) (EApp (EApp (EApp (EVar "checkPat") (EVar "cur")) (EVar "env")) (EVar "p")))
(DFunDef false "checkPat" ((PVar "cur") (PVar "env") (PCon "PRec" (PVar "name") (PVar "fields") PWild)) (EApp (EApp (EApp (EApp (EVar "checkRecPat") (EVar "cur")) (EVar "env")) (EVar "name")) (EVar "fields")))
(DFunDef false "checkPat" (PWild PWild PWild) (EListLit))
(DTypeSig false "checkRecPat" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "RecPatField")) (TyApp (TyCon "List") (TyCon "ResError")))))))
(DFunDef false "checkRecPat" ((PVar "cur") (PVar "env") (PVar "name") (PVar "fields")) (EBinOp "++" (EApp (EApp (EApp (EVar "recPatHead") (EVar "cur")) (EVar "env")) (EVar "name")) (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EVar "checkRecField") (EVar "cur")) (EVar "env")) (EVar "name"))) (EVar "fields"))))
(DTypeSig false "recPatHead" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "recPatHead" ((PVar "cur") (PVar "env") (PVar "name")) (EIf (EBinOp "||" (EApp (EApp (EVar "omHasKey") (EVar "name")) (EFieldAccess (EVar "env") "types")) (EApp (EApp (EVar "omHasKey") (EVar "name")) (EFieldAccess (EVar "env") "ctors"))) (EApp (EApp (EApp (EVar "ambiguousHeadErrors") (EVar "env")) (EVar "name")) (EVar "cur")) (EListLit (EApp (EApp (EApp (EVar "UnknownType") (EVar "name")) (EVar "cur")) (EApp (EApp (EVar "suggestType") (EVar "env")) (EVar "name"))))))
(DTypeSig false "checkRecField" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyFun (TyCon "RecPatField") (TyApp (TyCon "List") (TyCon "ResError")))))))
(DFunDef false "checkRecField" ((PVar "cur") (PVar "env") (PVar "owner") (PCon "RecPatField" (PVar "fname") PWild (PVar "popt"))) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "fieldCheck") (EVar "cur")) (EVar "env")) (EVar "owner")) (EVar "fname")) (EApp (EApp (EApp (EVar "recFieldSub") (EVar "cur")) (EVar "env")) (EVar "popt"))))
(DTypeSig false "fieldCheck" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "ResError")))))))
(DFunDef false "fieldCheck" ((PVar "cur") (PVar "env") (PVar "owner") (PVar "fname")) (EBlock (DoLet false false (PVar "owners") (EApp (EApp (EVar "ownersOf") (EVar "fname")) (EFieldAccess (EVar "env") "fieldOwnersIdx"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "fieldVerdict") (EVar "cur")) (EVar "env")) (EVar "owner")) (EVar "fname")) (EVar "owners")))))
(DTypeSig false "fieldVerdict" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "ResError"))))))))
(DFunDef false "fieldVerdict" ((PVar "cur") (PVar "env") (PVar "owner") (PVar "fname") (PList)) (EIf (EBinOp "&&" (EApp (EApp (EVar "omHasKey") (EVar "owner")) (EFieldAccess (EVar "env") "types")) (EApp (EVar "not") (EApp (EApp (EVar "ownsAnyField") (EVar "owner")) (EFieldAccess (EVar "env") "fieldOwners")))) (EListLit (EApp (EApp (EApp (EVar "AbstractFieldAccess") (EVar "owner")) (EVar "fname")) (EVar "cur"))) (EListLit (EApp (EApp (EVar "UnknownField") (EVar "fname")) (EVar "cur")))))
(DFunDef false "fieldVerdict" ((PVar "cur") (PVar "env") (PVar "owner") (PVar "fname") (PVar "owners")) (EIf (EApp (EApp (EVar "contains") (EVar "owner")) (EVar "owners")) (EListLit) (EListLit (EApp (EApp (EApp (EVar "FieldNotInRecord") (EVar "fname")) (EVar "owner")) (EVar "cur")))))
(DTypeSig false "ownsAnyField" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyCon "Bool"))))
(DFunDef false "ownsAnyField" (PWild (PList)) (EVar "False"))
(DFunDef false "ownsAnyField" ((PVar "owner") (PCons (PTuple PWild (PVar "o")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "o") (EVar "owner")) (EVar "True") (EIf (EVar "otherwise") (EApp (EApp (EVar "ownsAnyField") (EVar "owner")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "recFieldSub" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyApp (TyCon "Option") (TyCon "Pat")) (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "recFieldSub" (PWild PWild (PCon "None")) (EListLit))
(DFunDef false "recFieldSub" ((PVar "cur") (PVar "env") (PCon "Some" (PVar "p"))) (EApp (EApp (EApp (EVar "checkPat") (EVar "cur")) (EVar "env")) (EVar "p")))
(DData Private "Scope" () ((variant "Scope" (ConPos (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "OrdMap") (TyCon "Unit"))))) ())
(DTypeSig false "emptyScope" (TyCon "Scope"))
(DFunDef false "emptyScope" () (EApp (EApp (EVar "Scope") (EListLit)) (EVar "omEmpty")))
(DTypeSig false "mkScope" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Scope")))
(DFunDef false "mkScope" ((PVar "ns")) (EApp (EApp (EVar "Scope") (EVar "ns")) (EApp (EApp (EVar "omFromNames") (EVar "ns")) (EVar "omEmpty"))))
(DTypeSig false "scopeNames" (TyFun (TyCon "Scope") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "scopeNames" ((PCon "Scope" (PVar "ns") PWild)) (EVar "ns"))
(DTypeSig false "scopeMem" (TyFun (TyCon "String") (TyFun (TyCon "Scope") (TyCon "Bool"))))
(DFunDef false "scopeMem" ((PVar "n") (PCon "Scope" PWild (PVar "mem"))) (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "mem")))
(DTypeSig false "scopeExtend" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Scope") (TyCon "Scope"))))
(DFunDef false "scopeExtend" ((PVar "ns") (PCon "Scope" (PVar "names") (PVar "mem"))) (EApp (EApp (EVar "Scope") (EBinOp "++" (EVar "ns") (EVar "names"))) (EApp (EApp (EVar "omFromNames") (EVar "ns")) (EVar "mem"))))
(DTypeSig false "scopeAdd" (TyFun (TyCon "String") (TyFun (TyCon "Scope") (TyCon "Scope"))))
(DFunDef false "scopeAdd" ((PVar "n") (PCon "Scope" (PVar "names") (PVar "mem"))) (EApp (EApp (EVar "Scope") (EBinOp "::" (EVar "n") (EVar "names"))) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (ELit LUnit)) (EVar "mem"))))
(DTypeSig false "checkExpr" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyCon "Scope") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "ResError")))))))
(DFunDef false "checkExpr" (PWild PWild PWild (PCon "ELit" PWild)) (EListLit))
(DFunDef false "checkExpr" (PWild PWild PWild (PCon "ENumLit" PWild PWild PWild PWild)) (EListLit))
(DFunDef false "checkExpr" (PWild PWild PWild (PCon "EMethodRef" PWild)) (EListLit))
(DFunDef false "checkExpr" (PWild PWild PWild (PCon "EDictApp" PWild)) (EListLit))
(DFunDef false "checkExpr" (PWild PWild PWild (PCon "EVarAt" PWild PWild)) (EApp (EVar "panic") (ELit (LString "unreachable: EVarAt is introduced by annotateProgram after resolve"))))
(DFunDef false "checkExpr" (PWild PWild PWild (PCon "EMethodAt" PWild PWild PWild PWild)) (EApp (EVar "panic") (ELit (LString "unreachable: EMethodAt is introduced by typecheck elaboration after resolve"))))
(DFunDef false "checkExpr" (PWild PWild PWild (PCon "EDictAt" PWild PWild)) (EApp (EVar "panic") (ELit (LString "unreachable: EDictAt is introduced by typecheck elaboration after resolve"))))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "EVar" (PVar "n"))) (EApp (EApp (EApp (EApp (EVar "checkVar") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "n")))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "EApp" (PVar "f") (PVar "x"))) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "f")) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "x"))))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "ELam" (PVar "pats") (PVar "body"))) (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "checkPat") (EVar "cur")) (EVar "env"))) (EVar "pats")) (EApp (EApp (EApp (EVar "patGroupDupErrors") (EVar "cur")) (ELit (LString "parameter list"))) (EVar "pats"))) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EApp (EApp (EVar "scopeExtend") (EApp (EVar "patsBindings") (EVar "pats"))) (EVar "scope"))) (EVar "body"))))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "ELet" PWild (PVar "isRec") (PVar "pat") (PVar "e1") (PVar "e2"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkLet") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "isRec")) (EVar "pat")) (EVar "e1")) (EVar "e2")))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "ELetGroup" (PVar "binds") (PVar "body"))) (EApp (EApp (EApp (EApp (EApp (EVar "checkLetGroup") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "binds")) (EVar "body")))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "EMatch" (PVar "e0") (PVar "arms"))) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e0")) (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EVar "checkArm") (EVar "cur")) (EVar "env")) (EVar "scope"))) (EVar "arms"))))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "EIf" (PVar "c") (PVar "t") (PVar "el"))) (EBinOp "++" (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "c")) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "t"))) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "el"))))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "EBinOp" PWild (PVar "a") (PVar "b") PWild)) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "a")) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "b"))))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "EUnOp" PWild (PVar "a") PWild)) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "a")))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "EInfix" (PVar "op") (PVar "a") (PVar "b"))) (EBinOp "++" (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "checkVar") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "op")) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "a"))) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "b"))))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "EFieldAccess" (PVar "e0") PWild PWild)) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e0")))
(DFunDef false "checkExpr" (PWild PWild PWild (PCon "EMapLit" PWild PWild)) (EApp (EVar "panic") (ELit (LString "unreachable: EMapLit is lowered to fromEntries by desugar before resolve"))))
(DFunDef false "checkExpr" (PWild PWild PWild (PCon "ESetLit" PWild PWild)) (EApp (EVar "panic") (ELit (LString "unreachable: ESetLit is lowered to fromEntries by desugar before resolve"))))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "ETuple" (PVar "es"))) (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope"))) (EVar "es")))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "EListLit" (PVar "es"))) (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope"))) (EVar "es")))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "EArrayLit" (PVar "es"))) (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope"))) (EVar "es")))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "ERangeList" (PVar "lo") (PVar "hi") PWild)) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "lo")) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "hi"))))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "ERangeArray" (PVar "lo") (PVar "hi") PWild)) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "lo")) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "hi"))))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "ESlice" (PVar "e0") (PVar "lo") (PVar "hi") PWild PWild)) (EBinOp "++" (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e0")) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "lo"))) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "hi"))))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "EIndex" (PVar "e0") (PVar "i") PWild)) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e0")) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "i"))))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "EAnnot" (PVar "e0") (PVar "t"))) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e0")) (EApp (EApp (EApp (EVar "checkType") (EVar "cur")) (EVar "env")) (EVar "t"))))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "EHeadAnnot" (PVar "e0") (PVar "t"))) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e0")) (EApp (EApp (EApp (EVar "checkType") (EVar "cur")) (EVar "env")) (EVar "t"))))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "EBlock" (PVar "stmts"))) (EApp (EApp (EApp (EApp (EVar "checkStmts") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "stmts")))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "EDo" PWild (PVar "stmts"))) (EApp (EApp (EApp (EApp (EVar "checkStmts") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "stmts")))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "EStringInterp" (PVar "parts"))) (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EVar "checkInterp") (EVar "cur")) (EVar "env")) (EVar "scope"))) (EVar "parts")))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "EGuards" (PVar "arms"))) (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EVar "checkGuardArm") (EVar "cur")) (EVar "env")) (EVar "scope"))) (EVar "arms")))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "ERecordCreate" (PVar "name") (PVar "fs"))) (EApp (EApp (EApp (EApp (EApp (EVar "checkRecordCreate") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "name")) (EVar "fs")))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "ERecordUpdate" (PVar "e0") (PVar "fs") PWild)) (EApp (EApp (EApp (EApp (EApp (EVar "checkRecordUpdate") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e0")) (EVar "fs")))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "EVariantUpdate" (PVar "con") (PVar "e0") (PVar "fs"))) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e0")) (EApp (EApp (EApp (EApp (EApp (EVar "checkRecordCreate") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "con")) (EVar "fs"))))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "EAsPat" PWild (PVar "e0"))) (EBinOp "::" (EApp (EVar "AsPatternMisplaced") (EVar "cur")) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e0"))))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "ESection" (PVar "s"))) (EApp (EApp (EApp (EApp (EVar "checkSection") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "s")))
(DFunDef false "checkExpr" (PWild (PVar "env") (PVar "scope") (PCon "ELoc" (PVar "l") (PVar "e"))) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EApp (EVar "Some") (EVar "l"))) (EVar "env")) (EVar "scope")) (EVar "e")))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "EDoOrigin" PWild (PVar "e"))) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e")))
(DTypeSig false "checkVar" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyCon "Scope") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "ResError")))))))
(DFunDef false "checkVar" ((PVar "cur") (PVar "env") (PVar "scope") (PVar "n")) (EIf (EApp (EVar "isHint") (EVar "n")) (EListLit) (EIf (EBinOp "&&" (EApp (EVar "not") (EApp (EApp (EVar "scopeMem") (EVar "n")) (EVar "scope"))) (EApp (EApp (EVar "omHasKey") (EVar "n")) (EFieldAccess (EVar "env") "internalGuard"))) (EListLit (EApp (EApp (EVar "InternalExternAccess") (EVar "n")) (EVar "cur"))) (EIf (EApp (EVar "not") (EApp (EApp (EApp (EVar "lookupValue") (EVar "env")) (EVar "scope")) (EVar "n"))) (EApp (EApp (EApp (EApp (EVar "unboundVarErrors") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "n")) (EIf (EBinOp "&&" (EApp (EVar "not") (EApp (EApp (EVar "scopeMem") (EVar "n")) (EVar "scope"))) (EApp (EApp (EVar "isAmbiguous") (EVar "env")) (EVar "n"))) (EListLit (EApp (EApp (EApp (EVar "AmbiguousOccurrence") (EVar "n")) (EApp (EApp (EVar "ambigMods") (EVar "env")) (EVar "n"))) (EVar "cur"))) (EIf (EBinOp "&&" (EApp (EVar "not") (EApp (EApp (EVar "scopeMem") (EVar "n")) (EVar "scope"))) (EApp (EApp (EVar "isCtorAmbiguous") (EVar "env")) (EVar "n"))) (EApp (EApp (EApp (EVar "ambiguousCtorErrors") (EVar "env")) (EVar "n")) (EVar "cur")) (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))
(DTypeSig false "unboundVarErrors" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyCon "Scope") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "ResError")))))))
(DFunDef false "unboundVarErrors" ((PVar "cur") (PVar "env") (PVar "scope") (PVar "n")) (EMatch (EApp (EApp (EVar "modulesExportingName") (EVar "env")) (EVar "n")) (arm (PCons (PVar "m") PWild) () (EListLit (EApp (EApp (EApp (EVar "UnboundVariableExported") (EVar "n")) (EVar "m")) (EVar "cur")))) (arm (PList) () (EIf (EApp (EApp (EVar "isImportedModuleName") (EVar "env")) (EVar "n")) (EListLit (EApp (EApp (EVar "UnboundVariableIsModule") (EVar "n")) (EVar "cur"))) (EListLit (EApp (EApp (EApp (EVar "UnboundVariable") (EVar "n")) (EVar "cur")) (EApp (EApp (EApp (EVar "suggestName") (EVar "env")) (EVar "scope")) (EVar "n"))))))))
(DTypeSig false "modulesExportingName" (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "modulesExportingName" ((PVar "env") (PVar "n")) (EApp (EApp (EVar "flatMap") (EApp (EVar "matchesExport") (EVar "n"))) (EFieldAccess (EVar "env") "importedModuleValues")))
(DTypeSig false "matchesExport" (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "matchesExport" ((PVar "n") (PTuple (PVar "mid") (PVar "vals"))) (EIf (EApp (EApp (EVar "contains") (EVar "n")) (EVar "vals")) (EListLit (EVar "mid")) (EListLit)))
(DTypeSig false "isImportedModuleName" (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "isImportedModuleName" ((PVar "env") (PVar "n")) (EApp (EApp (EVar "anyList") (EApp (EVar "isModId") (EVar "n"))) (EFieldAccess (EVar "env") "importedModuleValues")))
(DTypeSig false "isModId" (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))) (TyCon "Bool"))))
(DFunDef false "isModId" ((PVar "n") (PTuple (PVar "mid") PWild)) (EBinOp "==" (EVar "mid") (EVar "n")))
(DTypeSig false "isAmbiguous" (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "isAmbiguous" ((PVar "env") (PVar "n")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EFieldAccess (EVar "env") "ambiguous")) (arm (PCon "Some" PWild) () (EVar "True")) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "ambigMods" (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "ambigMods" ((PVar "env") (PVar "n")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EFieldAccess (EVar "env") "ambiguous")) (arm (PCon "Some" (PVar "mods")) () (EVar "mods")) (arm (PCon "None") () (EListLit))))
(DTypeSig false "isCtorAmbiguous" (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "isCtorAmbiguous" ((PVar "env") (PVar "n")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EFieldAccess (EVar "env") "ctorAmbiguous")) (arm (PCon "Some" PWild) () (EVar "True")) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "ctorAmbigMods" (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "ctorAmbigMods" ((PVar "env") (PVar "n")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EFieldAccess (EVar "env") "ctorAmbiguous")) (arm (PCon "Some" (PVar "mods")) () (EVar "mods")) (arm (PCon "None") () (EListLit))))
(DTypeSig false "isTypeAmbiguous" (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "isTypeAmbiguous" ((PVar "env") (PVar "n")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EFieldAccess (EVar "env") "typeAmbiguous")) (arm (PCon "Some" PWild) () (EVar "True")) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "typeAmbigMods" (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "typeAmbigMods" ((PVar "env") (PVar "n")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EFieldAccess (EVar "env") "typeAmbiguous")) (arm (PCon "Some" (PVar "mods")) () (EVar "mods")) (arm (PCon "None") () (EListLit))))
(DTypeSig false "isIfaceAmbiguous" (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "isIfaceAmbiguous" ((PVar "env") (PVar "n")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EFieldAccess (EVar "env") "ifaceAmbiguous")) (arm (PCon "Some" PWild) () (EVar "True")) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "ifaceAmbigMods" (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "ifaceAmbigMods" ((PVar "env") (PVar "n")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EFieldAccess (EVar "env") "ifaceAmbiguous")) (arm (PCon "Some" (PVar "mods")) () (EVar "mods")) (arm (PCon "None") () (EListLit))))
(DTypeSig false "isHint" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isHint" ((PVar "n")) (EApp (EVar "startsWithAt") (EApp (EVar "stringToChars") (EVar "n"))))
(DTypeSig false "startsWithAt" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyCon "Bool")))
(DFunDef false "startsWithAt" ((PVar "cs")) (EBinOp "&&" (EBinOp ">" (EApp (EVar "arrayLength") (EVar "cs")) (ELit (LInt 0))) (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 0))) (EVar "cs")) (ELit (LChar "@")))))
(DTypeSig false "lookupValue" (TyFun (TyCon "Env") (TyFun (TyCon "Scope") (TyFun (TyCon "String") (TyCon "Bool")))))
(DFunDef false "lookupValue" ((PVar "env") (PVar "scope") (PVar "n")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EApp (EApp (EVar "scopeMem") (EVar "n")) (EVar "scope")) (EApp (EApp (EVar "omHasKey") (EVar "n")) (EFieldAccess (EVar "env") "values"))) (EApp (EApp (EVar "omHasKey") (EVar "n")) (EFieldAccess (EVar "env") "ctors"))) (EApp (EApp (EVar "omHasKey") (EVar "n")) (EFieldAccess (EVar "env") "imported"))))
(DTypeSig false "haskellTypeAliases" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "haskellTypeAliases" () (EListLit (ETuple (ELit (LString "Functor")) (ELit (LString "Mappable"))) (ETuple (ELit (LString "Monad")) (ELit (LString "Thenable"))) (ETuple (ELit (LString "Maybe")) (ELit (LString "Option"))) (ETuple (ELit (LString "Either")) (ELit (LString "Result")))))
(DTypeSig false "haskellValueAliases" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "haskellValueAliases" () (EListLit (ETuple (ELit (LString "fmap")) (ELit (LString "map"))) (ETuple (ELit (LString "return")) (ELit (LString "pure"))) (ETuple (ELit (LString "show")) (ELit (LString "debug"))) (ETuple (ELit (LString "mappend")) (ELit (LString "append"))) (ETuple (ELit (LString "mempty")) (ELit (LString "empty"))) (ETuple (ELit (LString "foldr")) (ELit (LString "foldRight"))) (ETuple (ELit (LString "foldl")) (ELit (LString "fold"))) (ETuple (ELit (LString "error")) (ELit (LString "panic"))) (ETuple (ELit (LString "undefined")) (ELit (LString "panic")))))
(DTypeSig false "haskellCtorAliases" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "haskellCtorAliases" () (EListLit (ETuple (ELit (LString "Just")) (ELit (LString "Some"))) (ETuple (ELit (LString "Nothing")) (ELit (LString "None"))) (ETuple (ELit (LString "Left")) (ELit (LString "Err"))) (ETuple (ELit (LString "Right")) (ELit (LString "Ok")))))
(DTypeSig false "isHaskellAliasPair" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "isHaskellAliasPair" ((PVar "bad") (PVar "sug")) (EBinOp "||" (EBinOp "||" (EApp (EApp (EVar "optStrEq") (EApp (EApp (EVar "lookupAssoc") (EVar "bad")) (EVar "haskellTypeAliases"))) (EVar "sug")) (EApp (EApp (EVar "optStrEq") (EApp (EApp (EVar "lookupAssoc") (EVar "bad")) (EVar "haskellValueAliases"))) (EVar "sug"))) (EApp (EApp (EVar "optStrEq") (EApp (EApp (EVar "lookupAssoc") (EVar "bad")) (EVar "haskellCtorAliases"))) (EVar "sug"))))
(DTypeSig false "optStrEq" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "optStrEq" ((PCon "Some" (PVar "x")) (PVar "sug")) (EBinOp "==" (EVar "x") (EVar "sug")))
(DFunDef false "optStrEq" ((PCon "None") PWild) (EVar "False"))
(DTypeSig false "haskellNote" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "haskellNote" ((PVar "bad") (PVar "sug")) (EIf (EApp (EApp (EVar "isHaskellAliasPair") (EVar "bad")) (EVar "sug")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString " ('")) (EApp (EVar "display") (EVar "bad"))) (ELit (LString "' is Haskell; Medaka uses '"))) (EApp (EVar "display") (EVar "sug"))) (ELit (LString "')"))) (ELit (LString ""))))
(DTypeSig false "suggestName" (TyFun (TyCon "Env") (TyFun (TyCon "Scope") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "suggestName" ((PVar "env") (PVar "scope") (PVar "n")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EBinOp "++" (EVar "haskellValueAliases") (EVar "haskellCtorAliases"))) (arm (PCon "Some" (PVar "sug")) () (EApp (EVar "Some") (EVar "sug"))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "suggestNameFuzzy") (EVar "env")) (EVar "scope")) (EVar "n")))))
(DTypeSig false "suggestNameFuzzy" (TyFun (TyCon "Env") (TyFun (TyCon "Scope") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "suggestNameFuzzy" ((PVar "env") (PVar "scope") (PVar "n")) (EIf (EBinOp "<" (EApp (EVar "stringLength") (EVar "n")) (ELit (LInt 3))) (EVar "None") (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "q") (EApp (EVar "sugQueryOf") (EVar "n"))) (DoExpr (EMatch (EApp (EApp (EVar "bestOfNames") (EVar "q")) (EApp (EVar "scopeNames") (EVar "scope"))) (arm (PCon "Some" (PVar "best")) () (EApp (EVar "Some") (EVar "best"))) (arm (PCon "None") () (EApp (EApp (EVar "bestOfPool") (EVar "q")) (EFieldAccess (EVar "env") "sugValues")))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "suggestType" (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "suggestType" ((PVar "env") (PVar "n")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EVar "haskellTypeAliases")) (arm (PCon "Some" (PVar "sug")) () (EApp (EVar "Some") (EVar "sug"))) (arm (PCon "None") () (EApp (EApp (EVar "suggestTypeFuzzy") (EVar "env")) (EVar "n")))))
(DTypeSig false "suggestTypeFuzzy" (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "suggestTypeFuzzy" ((PVar "env") (PVar "n")) (EIf (EBinOp "<" (EApp (EVar "stringLength") (EVar "n")) (ELit (LInt 3))) (EVar "None") (EIf (EVar "otherwise") (EApp (EApp (EVar "bestOfPool") (EApp (EVar "sugQueryOf") (EVar "n"))) (EFieldAccess (EVar "env") "sugTypes")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "suggestCtor" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "suggestCtor" ((PVar "n")) (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EVar "haskellCtorAliases")))
(DData Private "SugCand" () ((variant "SugCand" (ConPos (TyCon "String") (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Bool")))) ())
(DTypeSig false "sugPoolOf" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "SugCand"))))
(DFunDef false "sugPoolOf" ((PVar "ns")) (EApp (EApp (EVar "map") (EVar "sugCandOf")) (EVar "ns")))
(DTypeSig false "sugCandOf" (TyFun (TyCon "String") (TyCon "SugCand")))
(DFunDef false "sugCandOf" ((PVar "n")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "SugCand") (EVar "n")) (EApp (EVar "stringLength") (EVar "n"))) (EApp (EApp (EVar "charMask") (ELit (LInt 0))) (EVar "n"))) (EApp (EApp (EVar "charMask") (ELit (LInt 5))) (EVar "n"))) (EApp (EApp (EVar "charMask") (ELit (LInt 10))) (EVar "n"))) (EApp (EVar "startsUpper") (EVar "n"))))
(DData Private "SugQuery" () ((variant "SugQuery" (ConPos (TyCon "String") (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Bool")))) ())
(DTypeSig false "sugQueryOf" (TyFun (TyCon "String") (TyCon "SugQuery")))
(DFunDef false "sugQueryOf" ((PVar "n")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "SugQuery") (EVar "n")) (EApp (EApp (EVar "minI") (ELit (LInt 2))) (EApp (EApp (EVar "maxI") (ELit (LInt 1))) (EBinOp "/" (EApp (EVar "stringLength") (EVar "n")) (ELit (LInt 3)))))) (EApp (EVar "stringLength") (EVar "n"))) (EApp (EApp (EVar "charMask") (ELit (LInt 0))) (EVar "n"))) (EApp (EApp (EVar "charMask") (ELit (LInt 5))) (EVar "n"))) (EApp (EApp (EVar "charMask") (ELit (LInt 10))) (EVar "n"))) (EApp (EVar "startsUpper") (EVar "n"))))
(DTypeSig false "charMask" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "Int"))))
(DFunDef false "charMask" ((PVar "sh") (PVar "n")) (EApp (EApp (EApp (EApp (EVar "charMaskGo") (EVar "sh")) (EApp (EVar "stringToChars") (EVar "n"))) (ELit (LInt 0))) (ELit (LInt 0))))
(DTypeSig false "charMaskGo" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "charMaskGo" ((PVar "sh") (PVar "cs") (PVar "i") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "cs"))) (EVar "acc") (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "charMaskGo") (EVar "sh")) (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EApp (EVar "bitOr") (EVar "acc")) (EApp (EApp (EVar "shiftLeft") (ELit (LInt 1))) (EApp (EApp (EVar "bitAnd") (EApp (EApp (EVar "shiftRight") (EApp (EVar "hashChar") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs")))) (EVar "sh"))) (ELit (LInt 31)))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "bitsAtMost" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "bitsAtMost" ((PVar "k") (PVar "x")) (EIf (EBinOp "==" (EVar "x") (ELit (LInt 0))) (EVar "True") (EIf (EBinOp "<=" (EVar "k") (ELit (LInt 0))) (EVar "False") (EIf (EVar "otherwise") (EApp (EApp (EVar "bitsAtMost") (EBinOp "-" (EVar "k") (ELit (LInt 1)))) (EApp (EApp (EVar "bitAnd") (EVar "x")) (EBinOp "-" (EVar "x") (ELit (LInt 1))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "bestOfPool" (TyFun (TyCon "SugQuery") (TyFun (TyApp (TyCon "List") (TyCon "SugCand")) (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "bestOfPool" ((PVar "q") (PVar "cands")) (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "best") PWild)) (EVar "best"))) (EApp (EApp (EApp (EVar "bestInPool") (EVar "q")) (EVar "cands")) (EVar "None"))))
(DTypeSig false "bestInPool" (TyFun (TyCon "SugQuery") (TyFun (TyApp (TyCon "List") (TyCon "SugCand")) (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Int"))) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Int")))))))
(DFunDef false "bestInPool" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "bestInPool" ((PVar "q") (PCons (PCon "SugCand" (PVar "c") (PVar "clen") (PVar "cm1") (PVar "cm2") (PVar "cm3") (PVar "cup")) (PVar "cs")) (PVar "acc")) (EIf (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "sugRejects") (EVar "q")) (EVar "c")) (EVar "clen")) (EVar "cm1")) (EVar "cm2")) (EVar "cm3")) (EVar "cup")) (EApp (EApp (EApp (EVar "bestInPool") (EVar "q")) (EVar "cs")) (EVar "acc")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "bestInPool") (EVar "q")) (EVar "cs")) (EApp (EApp (EApp (EVar "scoreCand") (EVar "q")) (EVar "c")) (EVar "acc"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "bestOfNames" (TyFun (TyCon "SugQuery") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "bestOfNames" ((PVar "q") (PVar "ns")) (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "best") PWild)) (EVar "best"))) (EApp (EApp (EApp (EVar "bestInNames") (EVar "q")) (EVar "ns")) (EVar "None"))))
(DTypeSig false "bestInNames" (TyFun (TyCon "SugQuery") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Int"))) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Int")))))))
(DFunDef false "bestInNames" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "bestInNames" ((PVar "q") (PCons (PVar "c") (PVar "cs")) (PVar "acc")) (EIf (EApp (EApp (EApp (EApp (EVar "sugRejectsName") (EVar "q")) (EVar "c")) (EApp (EVar "stringLength") (EVar "c"))) (EApp (EVar "startsUpper") (EVar "c"))) (EApp (EApp (EApp (EVar "bestInNames") (EVar "q")) (EVar "cs")) (EVar "acc")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "bestInNames") (EVar "q")) (EVar "cs")) (EApp (EApp (EApp (EVar "scoreCand") (EVar "q")) (EVar "c")) (EVar "acc"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "sugRejects" (TyFun (TyCon "SugQuery") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyCon "Bool")))))))))
(DFunDef false "sugRejects" ((PCon "SugQuery" (PVar "n") (PVar "lim") (PVar "qlen") (PVar "qm1") (PVar "qm2") (PVar "qm3") (PVar "qup")) (PVar "c") (PVar "clen") (PVar "cm1") (PVar "cm2") (PVar "cm3") (PVar "cup")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EApp (EVar "not") (EApp (EApp (EVar "sameCase") (EVar "qup")) (EVar "cup"))) (EBinOp "<" (EVar "clen") (EBinOp "-" (EVar "qlen") (EVar "lim")))) (EBinOp ">" (EVar "clen") (EBinOp "+" (EVar "qlen") (EVar "lim")))) (EApp (EVar "not") (EApp (EApp (EVar "bitsAtMost") (EBinOp "*" (ELit (LInt 2)) (EVar "lim"))) (EApp (EApp (EVar "bitXor") (EVar "qm1")) (EVar "cm1"))))) (EApp (EVar "not") (EApp (EApp (EVar "bitsAtMost") (EBinOp "*" (ELit (LInt 2)) (EVar "lim"))) (EApp (EApp (EVar "bitXor") (EVar "qm2")) (EVar "cm2"))))) (EApp (EVar "not") (EApp (EApp (EVar "bitsAtMost") (EBinOp "*" (ELit (LInt 2)) (EVar "lim"))) (EApp (EApp (EVar "bitXor") (EVar "qm3")) (EVar "cm3"))))) (EBinOp "==" (EVar "c") (EVar "n"))))
(DTypeSig false "sugRejectsName" (TyFun (TyCon "SugQuery") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyCon "Bool"))))))
(DFunDef false "sugRejectsName" ((PCon "SugQuery" (PVar "n") (PVar "lim") (PVar "qlen") PWild PWild PWild (PVar "qup")) (PVar "c") (PVar "clen") (PVar "cup")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EApp (EVar "not") (EApp (EApp (EVar "sameCase") (EVar "qup")) (EVar "cup"))) (EBinOp "<" (EVar "clen") (EBinOp "-" (EVar "qlen") (EVar "lim")))) (EBinOp ">" (EVar "clen") (EBinOp "+" (EVar "qlen") (EVar "lim")))) (EBinOp "==" (EVar "c") (EVar "n"))))
(DTypeSig false "sameCase" (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyCon "Bool"))))
(DFunDef false "sameCase" ((PCon "True") (PCon "True")) (EVar "True"))
(DFunDef false "sameCase" ((PCon "False") (PCon "False")) (EVar "True"))
(DFunDef false "sameCase" (PWild PWild) (EVar "False"))
(DTypeSig false "scoreCand" (TyFun (TyCon "SugQuery") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Int"))) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Int")))))))
(DFunDef false "scoreCand" ((PCon "SugQuery" (PVar "n") (PVar "lim") PWild PWild PWild PWild PWild) (PVar "c") (PVar "acc")) (EBlock (DoLet false false PWild (EApp (EVar "opBump") (ELit LUnit))) (DoLet false false (PVar "d") (EApp (EApp (EVar "editDistance") (EVar "n")) (EVar "c"))) (DoExpr (EIf (EBinOp ">" (EVar "d") (EVar "lim")) (EVar "acc") (EApp (EApp (EApp (EVar "keepBetter") (EVar "c")) (EVar "d")) (EVar "acc"))))))
(DTypeSig false "startsUpper" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "startsUpper" ((PVar "s")) (EBinOp "&&" (EBinOp "&&" (EBinOp ">" (EApp (EVar "stringLength") (EVar "s")) (ELit (LInt 0))) (EBinOp ">=" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 1))) (EVar "s")) (ELit (LString "A")))) (EBinOp "<=" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 1))) (EVar "s")) (ELit (LString "Z")))))
(DTypeSig false "keepBetter" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Int"))) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Int")))))))
(DFunDef false "keepBetter" ((PVar "c") (PVar "d") (PCon "None")) (EApp (EVar "Some") (ETuple (EVar "c") (EVar "d"))))
(DFunDef false "keepBetter" ((PVar "c") (PVar "d") (PCon "Some" (PTuple (PVar "bc") (PVar "bd")))) (EIf (EBinOp "<" (EVar "d") (EVar "bd")) (EApp (EVar "Some") (ETuple (EVar "c") (EVar "d"))) (EIf (EBinOp "&&" (EBinOp "==" (EVar "d") (EVar "bd")) (EBinOp "<" (EVar "c") (EVar "bc"))) (EApp (EVar "Some") (ETuple (EVar "c") (EVar "d"))) (EIf (EVar "otherwise") (EApp (EVar "Some") (ETuple (EVar "bc") (EVar "bd"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "checkLet" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyCon "Scope") (TyFun (TyCon "Bool") (TyFun (TyCon "Pat") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "ResError"))))))))))
(DFunDef false "checkLet" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "True") (PCon "PVar" (PVar "f") PWild) (PVar "e1") (PVar "e2")) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EApp (EApp (EVar "scopeAdd") (EVar "f")) (EVar "scope"))) (EVar "e1")) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EApp (EApp (EVar "scopeAdd") (EVar "f")) (EVar "scope"))) (EVar "e2"))))
(DFunDef false "checkLet" ((PVar "cur") (PVar "env") (PVar "scope") PWild (PVar "pat") (PVar "e1") (PVar "e2")) (EBlock (DoLet false false (PVar "bound") (EApp (EVar "patBindings") (EVar "pat"))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EApp (EApp (EApp (EVar "checkPat") (EVar "cur")) (EVar "env")) (EVar "pat")) (EApp (EApp (EApp (EVar "patGroupDupErrors") (EVar "cur")) (ELit (LString "pattern"))) (EListLit (EVar "pat")))) (EApp (EApp (EVar "map") (EApp (EVar "rewriteNonRec") (EVar "bound"))) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e1")))) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EApp (EApp (EVar "scopeExtend") (EVar "bound")) (EVar "scope"))) (EVar "e2"))))))
(DTypeSig false "rewriteNonRec" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "ResError") (TyCon "ResError"))))
(DFunDef false "rewriteNonRec" ((PVar "bound") (PCon "UnboundVariable" (PVar "n") (PVar "l") (PVar "s"))) (EIf (EApp (EApp (EVar "contains") (EVar "n")) (EVar "bound")) (EApp (EApp (EVar "NonRecursiveValueLet") (EVar "n")) (EVar "l")) (EApp (EApp (EApp (EVar "UnboundVariable") (EVar "n")) (EVar "l")) (EVar "s"))))
(DFunDef false "rewriteNonRec" (PWild (PVar "e")) (EVar "e"))
(DTypeSig false "checkLetGroup" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyCon "Scope") (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "ResError"))))))))
(DFunDef false "checkLetGroup" ((PVar "cur") (PVar "env") (PVar "scope") (PVar "binds") (PVar "body")) (EBlock (DoLet false false (PVar "scope2") (EApp (EApp (EVar "scopeExtend") (EApp (EApp (EVar "map") (EVar "letBindName")) (EVar "binds"))) (EVar "scope"))) (DoExpr (EBinOp "++" (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EVar "checkLetBind") (EVar "cur")) (EVar "env")) (EVar "scope2"))) (EVar "binds")) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope2")) (EVar "body"))))))
(DTypeSig false "letBindName" (TyFun (TyCon "LetBind") (TyCon "String")))
(DFunDef false "letBindName" ((PCon "LetBind" (PVar "n") PWild)) (EVar "n"))
(DTypeSig false "checkLetBind" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyCon "Scope") (TyFun (TyCon "LetBind") (TyApp (TyCon "List") (TyCon "ResError")))))))
(DFunDef false "checkLetBind" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "LetBind" (PVar "n") (PVar "clauses"))) (EBinOp "++" (EApp (EApp (EApp (EVar "letBindDupErrors") (EVar "cur")) (EVar "n")) (EVar "clauses")) (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EVar "checkFunClause") (EVar "cur")) (EVar "env")) (EVar "scope"))) (EVar "clauses"))))
(DTypeSig false "letBindDupErrors" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "FunClause")) (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "letBindDupErrors" ((PVar "cur") (PVar "n") (PVar "clauses")) (EIf (EApp (EVar "hasNullaryClause") (EVar "clauses")) (EApp (EApp (EApp (EApp (EVar "dupClauseTail") (EVar "cur")) (EVar "n")) (EVar "False")) (EVar "clauses")) (EListLit)))
(DTypeSig false "hasNullaryClause" (TyFun (TyApp (TyCon "List") (TyCon "FunClause")) (TyCon "Bool")))
(DFunDef false "hasNullaryClause" ((PList)) (EVar "False"))
(DFunDef false "hasNullaryClause" ((PCons (PCon "FunClause" (PVar "ps") PWild) (PVar "rest"))) (EBinOp "||" (EApp (EVar "isEmptyL") (EVar "ps")) (EApp (EVar "hasNullaryClause") (EVar "rest"))))
(DTypeSig false "dupClauseTail" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "FunClause")) (TyApp (TyCon "List") (TyCon "ResError")))))))
(DFunDef false "dupClauseTail" (PWild PWild PWild (PList)) (EListLit))
(DFunDef false "dupClauseTail" ((PVar "cur") (PVar "n") (PVar "seen") (PCons (PCon "FunClause" PWild (PVar "body")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "whenL") (EVar "seen")) (EListLit (EApp (EApp (EVar "DuplicateValueBinding") (EVar "n")) (EApp (EApp (EVar "orElseLoc") (EApp (EVar "firstExprLoc") (EVar "body"))) (EVar "cur"))))) (EApp (EApp (EApp (EApp (EVar "dupClauseTail") (EVar "cur")) (EVar "n")) (EVar "True")) (EVar "rest"))))
(DTypeSig false "checkFunClause" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyCon "Scope") (TyFun (TyCon "FunClause") (TyApp (TyCon "List") (TyCon "ResError")))))))
(DFunDef false "checkFunClause" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "FunClause" (PVar "pats") (PVar "body"))) (EBlock (DoLet false false (PVar "patLoc") (EApp (EApp (EVar "orElseLoc") (EApp (EVar "firstExprLoc") (EVar "body"))) (EVar "cur"))) (DoExpr (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "checkPat") (EVar "patLoc")) (EVar "env"))) (EVar "pats")) (EApp (EApp (EApp (EVar "patGroupDupErrors") (EVar "patLoc")) (ELit (LString "parameter list"))) (EVar "pats"))) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EApp (EApp (EVar "scopeExtend") (EApp (EVar "patsBindings") (EVar "pats"))) (EVar "scope"))) (EVar "body"))))))
(DTypeSig false "checkArm" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyCon "Scope") (TyFun (TyCon "Arm") (TyApp (TyCon "List") (TyCon "ResError")))))))
(DFunDef false "checkArm" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "Arm" (PVar "pat") (PVar "gs") (PVar "body"))) (EBlock (DoLet false false (PVar "scope0") (EApp (EApp (EVar "scopeExtend") (EApp (EVar "patBindings") (EVar "pat"))) (EVar "scope"))) (DoLet false false (PTuple (PVar "gErrs") (PVar "scope2")) (EApp (EApp (EApp (EApp (EVar "checkArmGuards") (EVar "cur")) (EVar "env")) (EVar "scope0")) (EVar "gs"))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EApp (EApp (EApp (EVar "checkPat") (EVar "cur")) (EVar "env")) (EVar "pat")) (EApp (EApp (EApp (EVar "patGroupDupErrors") (EVar "cur")) (ELit (LString "pattern"))) (EListLit (EVar "pat")))) (EVar "gErrs")) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope2")) (EVar "body"))))))
(DTypeSig false "checkArmGuards" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyCon "Scope") (TyFun (TyApp (TyCon "List") (TyCon "Guard")) (TyTuple (TyApp (TyCon "List") (TyCon "ResError")) (TyCon "Scope")))))))
(DFunDef false "checkArmGuards" (PWild PWild (PVar "scope") (PList)) (ETuple (EListLit) (EVar "scope")))
(DFunDef false "checkArmGuards" ((PVar "cur") (PVar "env") (PVar "scope") (PCons (PCon "GBool" (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "rErrs") (PVar "scope2")) (EApp (EApp (EApp (EApp (EVar "checkArmGuards") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "rest"))) (DoExpr (ETuple (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e")) (EVar "rErrs")) (EVar "scope2")))))
(DFunDef false "checkArmGuards" ((PVar "cur") (PVar "env") (PVar "scope") (PCons (PCon "GBind" (PVar "p") (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false (PVar "here") (EBinOp "++" (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e")) (EApp (EApp (EApp (EVar "checkPat") (EVar "cur")) (EVar "env")) (EVar "p"))) (EApp (EApp (EApp (EVar "patGroupDupErrors") (EVar "cur")) (ELit (LString "pattern"))) (EListLit (EVar "p"))))) (DoLet false false (PTuple (PVar "rErrs") (PVar "scope2")) (EApp (EApp (EApp (EApp (EVar "checkArmGuards") (EVar "cur")) (EVar "env")) (EApp (EApp (EVar "scopeExtend") (EApp (EVar "patBindings") (EVar "p"))) (EVar "scope"))) (EVar "rest"))) (DoExpr (ETuple (EBinOp "++" (EVar "here") (EVar "rErrs")) (EVar "scope2")))))
(DTypeSig false "checkGuardArm" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyCon "Scope") (TyFun (TyCon "GuardArm") (TyApp (TyCon "List") (TyCon "ResError")))))))
(DFunDef false "checkGuardArm" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "GuardArm" (PVar "gs") (PVar "body"))) (EBinOp "++" (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EVar "checkGuard") (EVar "cur")) (EVar "env")) (EVar "scope"))) (EVar "gs")) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "body"))))
(DTypeSig false "checkGuard" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyCon "Scope") (TyFun (TyCon "Guard") (TyApp (TyCon "List") (TyCon "ResError")))))))
(DFunDef false "checkGuard" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "GBool" (PVar "e"))) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e")))
(DFunDef false "checkGuard" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "GBind" PWild (PVar "e"))) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e")))
(DTypeSig false "checkStmts" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyCon "Scope") (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyApp (TyCon "List") (TyCon "ResError")))))))
(DFunDef false "checkStmts" (PWild PWild PWild (PList)) (EListLit))
(DFunDef false "checkStmts" ((PVar "cur") (PVar "env") (PVar "scope") (PCons (PVar "s") (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "errs") (PVar "scope2")) (EApp (EApp (EApp (EApp (EVar "checkStmt") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "s"))) (DoExpr (EBinOp "++" (EVar "errs") (EApp (EApp (EApp (EApp (EVar "checkStmts") (EVar "cur")) (EVar "env")) (EVar "scope2")) (EVar "rest"))))))
(DTypeSig false "checkStmt" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyCon "Scope") (TyFun (TyCon "DoStmt") (TyTuple (TyApp (TyCon "List") (TyCon "ResError")) (TyCon "Scope")))))))
(DFunDef false "checkStmt" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "DoExpr" (PVar "e"))) (ETuple (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e")) (EVar "scope")))
(DFunDef false "checkStmt" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "DoBind" (PVar "p") (PVar "e"))) (ETuple (EBinOp "++" (EBinOp "++" (EApp (EApp (EApp (EVar "checkPat") (EVar "cur")) (EVar "env")) (EVar "p")) (EApp (EApp (EApp (EVar "patGroupDupErrors") (EVar "cur")) (ELit (LString "pattern"))) (EListLit (EVar "p")))) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e"))) (EApp (EApp (EVar "scopeExtend") (EApp (EVar "patBindings") (EVar "p"))) (EVar "scope"))))
(DFunDef false "checkStmt" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "DoLet" PWild (PCon "False") (PVar "p") (PVar "e"))) (ETuple (EBinOp "++" (EBinOp "++" (EApp (EApp (EApp (EVar "checkPat") (EVar "cur")) (EVar "env")) (EVar "p")) (EApp (EApp (EApp (EVar "patGroupDupErrors") (EVar "cur")) (ELit (LString "pattern"))) (EListLit (EVar "p")))) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e"))) (EApp (EApp (EVar "scopeExtend") (EApp (EVar "patBindings") (EVar "p"))) (EVar "scope"))))
(DFunDef false "checkStmt" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "DoLet" PWild (PCon "True") (PVar "p") (PVar "e"))) (ETuple (EBinOp "++" (EBinOp "++" (EApp (EApp (EApp (EVar "checkPat") (EVar "cur")) (EVar "env")) (EVar "p")) (EApp (EApp (EApp (EVar "patGroupDupErrors") (EVar "cur")) (ELit (LString "pattern"))) (EListLit (EVar "p")))) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EApp (EApp (EVar "scopeExtend") (EApp (EVar "patBindings") (EVar "p"))) (EVar "scope"))) (EVar "e"))) (EApp (EApp (EVar "scopeExtend") (EApp (EVar "patBindings") (EVar "p"))) (EVar "scope"))))
(DFunDef false "checkStmt" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "DoAssign" (PVar "x") (PVar "e"))) (ETuple (EBinOp "::" (EApp (EApp (EVar "ReassignImmutable") (EVar "x")) (EApp (EApp (EVar "orElseLoc") (EApp (EVar "firstExprLoc") (EVar "e"))) (EVar "cur"))) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e"))) (EVar "scope")))
(DFunDef false "checkStmt" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "DoFieldAssign" PWild PWild (PVar "e"))) (ETuple (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e")) (EVar "scope")))
(DTypeSig false "checkInterp" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyCon "Scope") (TyFun (TyCon "InterpPart") (TyApp (TyCon "List") (TyCon "ResError")))))))
(DFunDef false "checkInterp" (PWild PWild PWild (PCon "InterpStr" PWild)) (EListLit))
(DFunDef false "checkInterp" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "InterpExpr" (PVar "e"))) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e")))
(DTypeSig false "checkFieldAssign" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyCon "Scope") (TyFun (TyCon "FieldAssign") (TyApp (TyCon "List") (TyCon "ResError")))))))
(DFunDef false "checkFieldAssign" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "FieldAssign" PWild (PVar "e"))) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e")))
(DTypeSig false "checkRecordCreate" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyCon "Scope") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "FieldAssign")) (TyApp (TyCon "List") (TyCon "ResError"))))))))
(DFunDef false "checkRecordCreate" ((PVar "cur") (PVar "env") (PVar "scope") (PVar "name") (PVar "fs")) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "recCreateHead") (EVar "cur")) (EVar "env")) (EVar "name")) (EVar "fs")) (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EVar "checkFieldAssign") (EVar "cur")) (EVar "env")) (EVar "scope"))) (EVar "fs"))))
(DTypeSig false "recCreateHead" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "FieldAssign")) (TyApp (TyCon "List") (TyCon "ResError")))))))
(DFunDef false "recCreateHead" ((PVar "cur") (PVar "env") (PVar "name") (PVar "fs")) (EIf (EBinOp "||" (EBinOp "||" (EApp (EApp (EVar "omHasKey") (EVar "name")) (EFieldAccess (EVar "env") "types")) (EApp (EApp (EVar "omHasKey") (EVar "name")) (EFieldAccess (EVar "env") "imported"))) (EApp (EApp (EVar "omHasKey") (EVar "name")) (EFieldAccess (EVar "env") "ctors"))) (EBinOp "++" (EApp (EApp (EApp (EVar "ambiguousHeadErrors") (EVar "env")) (EVar "name")) (EVar "cur")) (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EVar "recCreateField") (EVar "cur")) (EVar "env")) (EVar "name"))) (EVar "fs"))) (EIf (EVar "otherwise") (EListLit (EApp (EApp (EApp (EVar "UnknownType") (EVar "name")) (EVar "cur")) (EApp (EApp (EVar "suggestType") (EVar "env")) (EVar "name")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "recCreateField" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyFun (TyCon "FieldAssign") (TyApp (TyCon "List") (TyCon "ResError")))))))
(DFunDef false "recCreateField" ((PVar "cur") (PVar "env") (PVar "owner") (PCon "FieldAssign" (PVar "fname") PWild)) (EApp (EApp (EApp (EApp (EApp (EVar "fieldVerdict") (EVar "cur")) (EVar "env")) (EVar "owner")) (EVar "fname")) (EApp (EApp (EVar "ownersOf") (EVar "fname")) (EFieldAccess (EVar "env") "fieldOwnersIdx"))))
(DTypeSig false "checkRecordUpdate" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyCon "Scope") (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "FieldAssign")) (TyApp (TyCon "List") (TyCon "ResError"))))))))
(DFunDef false "checkRecordUpdate" ((PVar "cur") (PVar "env") (PVar "scope") (PVar "e0") (PVar "fs")) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e0")) (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EVar "recUpdateField") (EVar "cur")) (EVar "env")) (EVar "scope"))) (EVar "fs"))))
(DTypeSig false "recUpdateField" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyCon "Scope") (TyFun (TyCon "FieldAssign") (TyApp (TyCon "List") (TyCon "ResError")))))))
(DFunDef false "recUpdateField" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "FieldAssign" (PVar "fname") (PVar "v"))) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "v")) (EApp (EApp (EApp (EVar "fieldKnownErr") (EVar "cur")) (EVar "env")) (EVar "fname"))))
(DTypeSig false "fieldKnownErr" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "fieldKnownErr" ((PVar "cur") (PVar "env") (PVar "fname")) (EApp (EApp (EApp (EVar "recUpdateVerdict") (EVar "cur")) (EVar "fname")) (EApp (EApp (EVar "ownersOf") (EVar "fname")) (EFieldAccess (EVar "env") "fieldOwnersIdx"))))
(DTypeSig false "recUpdateVerdict" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "recUpdateVerdict" ((PVar "cur") (PVar "fname") (PList)) (EListLit (EApp (EApp (EVar "UnknownField") (EVar "fname")) (EVar "cur"))))
(DFunDef false "recUpdateVerdict" (PWild PWild PWild) (EListLit))
(DTypeSig false "checkSection" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyCon "Scope") (TyFun (TyCon "Section") (TyApp (TyCon "List") (TyCon "ResError")))))))
(DFunDef false "checkSection" (PWild PWild PWild (PCon "SecBare" PWild)) (EListLit))
(DFunDef false "checkSection" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "SecRight" PWild (PVar "e"))) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e")))
(DFunDef false "checkSection" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "SecLeft" (PVar "e") PWild)) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e")))
(DTypeSig false "checkDecl" (TyFun (TyCon "Env") (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "ResError")))))
(DFunDef false "checkDecl" ((PVar "env") (PCon "DFunDef" PWild PWild (PVar "pats") (PVar "body"))) (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "checkPat") (EApp (EVar "firstExprLoc") (EVar "body"))) (EVar "env"))) (EVar "pats")) (EApp (EApp (EApp (EVar "patGroupDupErrors") (EApp (EVar "firstExprLoc") (EVar "body"))) (ELit (LString "parameter list"))) (EVar "pats"))) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "None")) (EVar "env")) (EApp (EVar "mkScope") (EApp (EVar "patsBindings") (EVar "pats")))) (EVar "body"))))
(DFunDef false "checkDecl" ((PVar "env") (PCon "DLetGroup" PWild (PVar "binds"))) (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EVar "checkLetBind") (EVar "None")) (EVar "env")) (EApp (EVar "mkScope") (EApp (EApp (EVar "map") (EVar "letBindName")) (EVar "binds"))))) (EVar "binds")))
(DFunDef false "checkDecl" ((PVar "env") (PCon "DTypeSig" PWild PWild (PVar "t"))) (EApp (EApp (EApp (EVar "checkType") (EVar "None")) (EVar "env")) (EVar "t")))
(DFunDef false "checkDecl" ((PVar "env") (PCon "DExtern" PWild PWild (PVar "t"))) (EApp (EApp (EApp (EVar "checkType") (EVar "None")) (EVar "env")) (EVar "t")))
(DFunDef false "checkDecl" ((PVar "env") (PRec "DData" ((rf "dataCtors" (PVar "vs"))) false)) (EApp (EApp (EVar "flatMap") (EApp (EVar "checkVariant") (EVar "env"))) (EVar "vs")))
(DFunDef false "checkDecl" ((PVar "env") (PCon "DProp" PWild PWild (PVar "params") (PVar "body"))) (EApp (EApp (EApp (EVar "checkProp") (EVar "env")) (EVar "params")) (EVar "body")))
(DFunDef false "checkDecl" ((PVar "env") (PCon "DTest" PWild PWild (PVar "body"))) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "None")) (EVar "env")) (EVar "emptyScope")) (EVar "body")))
(DFunDef false "checkDecl" ((PVar "env") (PCon "DBench" PWild PWild (PVar "body"))) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "None")) (EVar "env")) (EVar "emptyScope")) (EVar "body")))
(DFunDef false "checkDecl" ((PVar "env") (PRec "DInterface" ((rf "supers" None) (rf "methods" None)) true)) (EApp (EApp (EApp (EVar "checkInterfaceDecl") (EVar "env")) (EVar "supers")) (EVar "methods")))
(DFunDef false "checkDecl" ((PVar "env") (PRec "DImpl" ((rf "iface" None) (rf "tys" None) (rf "reqs" None) (rf "methods" None)) true)) (EApp (EApp (EApp (EApp (EApp (EVar "checkImplDecl") (EVar "env")) (EVar "iface")) (EVar "tys")) (EVar "reqs")) (EVar "methods")))
(DFunDef false "checkDecl" ((PVar "env") (PRec "DTypeAlias" ((rf "tyAliasRhs" (PVar "rhs"))) false)) (EApp (EApp (EApp (EVar "checkType") (EVar "None")) (EVar "env")) (EVar "rhs")))
(DFunDef false "checkDecl" ((PVar "env") (PRec "DNewtype" ((rf "newtypeFieldTy" (PVar "fty"))) false)) (EApp (EApp (EApp (EVar "checkType") (EVar "None")) (EVar "env")) (EVar "fty")))
(DFunDef false "checkDecl" ((PVar "env") (PCon "DAttrib" PWild (PVar "inner"))) (EApp (EApp (EVar "checkDecl") (EVar "env")) (EVar "inner")))
(DFunDef false "checkDecl" (PWild PWild) (EListLit))
(DTypeSig false "checkVariant" (TyFun (TyCon "Env") (TyFun (TyCon "Variant") (TyApp (TyCon "List") (TyCon "ResError")))))
(DFunDef false "checkVariant" ((PVar "env") (PCon "Variant" PWild (PCon "ConPos" (PVar "tys")))) (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "checkType") (EVar "None")) (EVar "env"))) (EVar "tys")))
(DFunDef false "checkVariant" ((PVar "env") (PCon "Variant" PWild (PCon "ConNamed" (PVar "fs") PWild))) (EApp (EApp (EVar "flatMap") (EApp (EVar "checkFieldType") (EVar "env"))) (EVar "fs")))
(DTypeSig false "checkFieldType" (TyFun (TyCon "Env") (TyFun (TyCon "Field") (TyApp (TyCon "List") (TyCon "ResError")))))
(DFunDef false "checkFieldType" ((PVar "env") (PCon "Field" PWild (PVar "t"))) (EApp (EApp (EApp (EVar "checkType") (EVar "None")) (EVar "env")) (EVar "t")))
(DTypeSig false "checkProp" (TyFun (TyCon "Env") (TyFun (TyApp (TyCon "List") (TyCon "PropParam")) (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "checkProp" ((PVar "env") (PVar "params") (PVar "body")) (EBinOp "++" (EApp (EApp (EVar "flatMap") (EApp (EVar "checkPropParamTy") (EVar "env"))) (EVar "params")) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "None")) (EVar "env")) (EApp (EVar "mkScope") (EApp (EApp (EVar "map") (EVar "propParamName")) (EVar "params")))) (EVar "body"))))
(DTypeSig false "checkPropParamTy" (TyFun (TyCon "Env") (TyFun (TyCon "PropParam") (TyApp (TyCon "List") (TyCon "ResError")))))
(DFunDef false "checkPropParamTy" ((PVar "env") (PCon "PropParam" PWild PWild (PVar "t"))) (EApp (EApp (EApp (EVar "checkType") (EVar "None")) (EVar "env")) (EVar "t")))
(DTypeSig false "propParamName" (TyFun (TyCon "PropParam") (TyCon "String")))
(DFunDef false "propParamName" ((PCon "PropParam" (PVar "x") PWild PWild)) (EVar "x"))
(DTypeSig false "checkInterfaceDecl" (TyFun (TyCon "Env") (TyFun (TyApp (TyCon "List") (TyCon "Super")) (TyFun (TyApp (TyCon "List") (TyCon "IfaceMethod")) (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "checkInterfaceDecl" ((PVar "env") (PVar "supers") (PVar "methods")) (EBinOp "++" (EApp (EApp (EVar "flatMap") (EApp (EVar "checkSuper") (EVar "env"))) (EVar "supers")) (EApp (EApp (EVar "flatMap") (EApp (EVar "checkIfaceMethod") (EVar "env"))) (EVar "methods"))))
(DTypeSig false "checkSuper" (TyFun (TyCon "Env") (TyFun (TyCon "Super") (TyApp (TyCon "List") (TyCon "ResError")))))
(DFunDef false "checkSuper" ((PVar "env") (PRec "Super" ((rf "superHead" (PVar "iface"))) false)) (EIf (EApp (EApp (EVar "contains") (EVar "iface")) (EFieldAccess (EVar "env") "interfaces")) (EApp (EApp (EApp (EVar "ambiguousIfaceErrors") (EVar "env")) (EVar "iface")) (EVar "None")) (EListLit (EApp (EApp (EVar "UnknownInterface") (EVar "iface")) (EVar "None")))))
(DTypeSig false "checkIfaceMethod" (TyFun (TyCon "Env") (TyFun (TyCon "IfaceMethod") (TyApp (TyCon "List") (TyCon "ResError")))))
(DFunDef false "checkIfaceMethod" ((PVar "env") (PCon "IfaceMethod" PWild (PVar "t") (PCon "None") PWild)) (EApp (EApp (EApp (EVar "checkType") (EVar "None")) (EVar "env")) (EVar "t")))
(DFunDef false "checkIfaceMethod" ((PVar "env") (PCon "IfaceMethod" PWild (PVar "t") (PCon "Some" (PCon "MethodDefault" (PVar "pats") (PVar "body"))) PWild)) (EBinOp "++" (EBinOp "++" (EApp (EApp (EApp (EVar "checkType") (EVar "None")) (EVar "env")) (EVar "t")) (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "checkPat") (EApp (EVar "firstExprLoc") (EVar "body"))) (EVar "env"))) (EVar "pats"))) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "None")) (EVar "env")) (EApp (EVar "mkScope") (EApp (EVar "patsBindings") (EVar "pats")))) (EVar "body"))))
(DTypeSig false "checkImplDecl" (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyApp (TyCon "List") (TyCon "Require")) (TyFun (TyApp (TyCon "List") (TyCon "ImplMethod")) (TyApp (TyCon "List") (TyCon "ResError"))))))))
(DFunDef false "checkImplDecl" ((PVar "env") (PVar "iface") (PVar "tyargs") (PVar "reqs") (PVar "methods")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "checkType") (EVar "None")) (EVar "env"))) (EVar "tyargs")) (EApp (EApp (EVar "flatMap") (EApp (EVar "checkRequire") (EVar "env"))) (EVar "reqs"))) (EApp (EApp (EVar "flatMap") (EApp (EVar "checkImplMethod") (EVar "env"))) (EVar "methods"))) (EApp (EApp (EApp (EVar "checkImplIface") (EVar "env")) (EVar "iface")) (EVar "methods"))) (EApp (EApp (EApp (EVar "ambiguousIfaceErrors") (EVar "env")) (EVar "iface")) (EApp (EVar "firstTyLocList") (EVar "tyargs")))))
(DTypeSig false "checkRequire" (TyFun (TyCon "Env") (TyFun (TyCon "Require") (TyApp (TyCon "List") (TyCon "ResError")))))
(DFunDef false "checkRequire" ((PVar "env") (PRec "Require" ((rf "requireHead" (PVar "iface")) (rf "requireArgs" (PVar "tys"))) false)) (EBinOp "++" (EIf (EApp (EApp (EVar "contains") (EVar "iface")) (EFieldAccess (EVar "env") "interfaces")) (EApp (EApp (EApp (EVar "ambiguousIfaceErrors") (EVar "env")) (EVar "iface")) (EApp (EVar "firstTyLocList") (EVar "tys"))) (EListLit (EApp (EApp (EVar "UnknownInterface") (EVar "iface")) (EVar "None")))) (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "checkType") (EVar "None")) (EVar "env"))) (EVar "tys"))))
(DTypeSig false "checkImplMethod" (TyFun (TyCon "Env") (TyFun (TyCon "ImplMethod") (TyApp (TyCon "List") (TyCon "ResError")))))
(DFunDef false "checkImplMethod" ((PVar "env") (PCon "ImplMethod" PWild (PVar "pats") (PVar "body"))) (EBinOp "++" (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "checkPat") (EApp (EVar "firstExprLoc") (EVar "body"))) (EVar "env"))) (EVar "pats")) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "None")) (EVar "env")) (EApp (EVar "mkScope") (EApp (EVar "patsBindings") (EVar "pats")))) (EVar "body"))))
(DTypeSig false "checkImplIface" (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "ImplMethod")) (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "checkImplIface" ((PVar "env") (PVar "iface") (PVar "methods")) (EIf (EApp (EVar "not") (EApp (EApp (EVar "contains") (EVar "iface")) (EFieldAccess (EVar "env") "interfaces"))) (EListLit (EApp (EApp (EVar "UnknownInterface") (EVar "iface")) (EVar "None"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "checkMethodMember") (EVar "iface")) (EApp (EApp (EVar "ifaceMethodsOf") (EVar "iface")) (EFieldAccess (EVar "env") "ifaceMethods")))) (EVar "methods")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "ifaceMethodsOf" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "ifaceMethodsOf" (PWild (PList)) (EListLit))
(DFunDef false "ifaceMethodsOf" ((PVar "iface") (PCons (PTuple (PVar "i") (PVar "ms")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "i") (EVar "iface")) (EVar "ms") (EIf (EVar "otherwise") (EApp (EApp (EVar "ifaceMethodsOf") (EVar "iface")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "checkMethodMember" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "ImplMethod") (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "checkMethodMember" ((PVar "iface") (PVar "known") (PCon "ImplMethod" (PVar "mname") PWild PWild)) (EIf (EApp (EApp (EVar "contains") (EVar "mname")) (EVar "known")) (EListLit) (EListLit (EApp (EApp (EApp (EVar "MethodNotInInterface") (EVar "mname")) (EVar "iface")) (EVar "None")))))
(DTypeSig false "isTupleCtorTyName" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isTupleCtorTyName" ((PVar "n")) (EApp (EApp (EVar "contains") (EVar "n")) (EVar "tupleCtorTyNames")))
(DTypeSig false "tupleCtorTyNames" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "tupleCtorTyNames" () (EListLit (ELit (LString "__tuple2__")) (ELit (LString "__tuple3__")) (ELit (LString "__tuple4__")) (ELit (LString "__tuple5__"))))
(DTypeSig false "primitiveTypes" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "primitiveTypes" () (EListLit (ELit (LString "Int")) (ELit (LString "Float")) (ELit (LString "String")) (ELit (LString "Char")) (ELit (LString "Bool")) (ELit (LString "Unit")) (ELit (LString "List")) (ELit (LString "Ref")) (ELit (LString "Array"))))
(DTypeSig false "primitiveConstructors" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "primitiveConstructors" () (EListLit (ELit (LString "True")) (ELit (LString "False"))))
(DTypeSig false "externNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "externNames" ((PList)) (EListLit))
(DFunDef false "externNames" ((PCons (PCon "DExtern" PWild (PVar "n") PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "externNames") (EVar "rest"))))
(DFunDef false "externNames" ((PCons PWild (PVar "rest"))) (EApp (EVar "externNames") (EVar "rest")))
(DTypeSig false "dataRecordNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "dataRecordNames" ((PList)) (EListLit))
(DFunDef false "dataRecordNames" ((PCons (PRec "DData" ((rf "dataName" (PVar "n"))) false) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "dataRecordNames") (EVar "rest"))))
(DFunDef false "dataRecordNames" ((PCons (PRec "DTypeAlias" ((rf "tyAliasName" (PVar "n"))) false) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "dataRecordNames") (EVar "rest"))))
(DFunDef false "dataRecordNames" ((PCons (PRec "DNewtype" ((rf "newtypeName" (PVar "n"))) false) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "dataRecordNames") (EVar "rest"))))
(DFunDef false "dataRecordNames" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "dataRecordNames") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "dataRecordNames" ((PCons PWild (PVar "rest"))) (EApp (EVar "dataRecordNames") (EVar "rest")))
(DTypeSig false "effectNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "effectNames" ((PList)) (EListLit))
(DFunDef false "effectNames" ((PCons (PCon "DEffect" PWild (PVar "n") PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "effectNames") (EVar "rest"))))
(DFunDef false "effectNames" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "effectNames") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "effectNames" ((PCons PWild (PVar "rest"))) (EApp (EVar "effectNames") (EVar "rest")))
(DTypeSig false "ctorNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "ctorNames" ((PList)) (EListLit))
(DFunDef false "ctorNames" ((PCons (PRec "DData" ((rf "dataCtors" (PVar "vs"))) false) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "map") (EVar "variantName")) (EVar "vs")) (EApp (EVar "ctorNames") (EVar "rest"))))
(DFunDef false "ctorNames" ((PCons (PRec "DNewtype" ((rf "newtypeCtor" (PVar "con"))) false) (PVar "rest"))) (EBinOp "::" (EVar "con") (EApp (EVar "ctorNames") (EVar "rest"))))
(DFunDef false "ctorNames" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "ctorNames") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "ctorNames" ((PCons PWild (PVar "rest"))) (EApp (EVar "ctorNames") (EVar "rest")))
(DTypeSig false "variantName" (TyFun (TyCon "Variant") (TyCon "String")))
(DFunDef false "variantName" ((PCon "Variant" (PVar "n") PWild)) (EVar "n"))
(DTypeSig false "ifaceMethodNm" (TyFun (TyCon "IfaceMethod") (TyCon "String")))
(DFunDef false "ifaceMethodNm" ((PCon "IfaceMethod" (PVar "n") PWild PWild PWild)) (EVar "n"))
(DTypeSig false "implMethodNm" (TyFun (TyCon "ImplMethod") (TyCon "String")))
(DFunDef false "implMethodNm" ((PCon "ImplMethod" (PVar "n") PWild PWild)) (EVar "n"))
(DTypeSig false "interfaceList" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "interfaceList" ((PList)) (EListLit))
(DFunDef false "interfaceList" ((PCons (PRec "DInterface" ((rf "name" (PVar "n")) (rf "methods" None)) true) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "n") (EApp (EApp (EVar "map") (EVar "ifaceMethodNm")) (EVar "methods"))) (EApp (EVar "interfaceList") (EVar "rest"))))
(DFunDef false "interfaceList" ((PCons PWild (PVar "rest"))) (EApp (EVar "interfaceList") (EVar "rest")))
(DTypeSig false "preludeValueNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "preludeValueNames" ((PList)) (EListLit))
(DFunDef false "preludeValueNames" ((PCons (PCon "DFunDef" PWild (PVar "n") PWild PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "preludeValueNames") (EVar "rest"))))
(DFunDef false "preludeValueNames" ((PCons (PCon "DTypeSig" PWild (PVar "n") PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "preludeValueNames") (EVar "rest"))))
(DFunDef false "preludeValueNames" ((PCons (PRec "DImpl" ((rf "methods" None)) true) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "map") (EVar "implMethodNm")) (EVar "methods")) (EApp (EVar "preludeValueNames") (EVar "rest"))))
(DFunDef false "preludeValueNames" ((PCons (PRec "DInterface" ((rf "methods" None)) true) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "map") (EVar "ifaceMethodNm")) (EVar "methods")) (EApp (EVar "preludeValueNames") (EVar "rest"))))
(DFunDef false "preludeValueNames" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "preludeValueNames") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "preludeValueNames" ((PCons PWild (PVar "rest"))) (EApp (EVar "preludeValueNames") (EVar "rest")))
(DTypeSig false "userValueNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "userValueNames" ((PList)) (EListLit))
(DFunDef false "userValueNames" ((PCons (PCon "DFunDef" PWild (PVar "n") PWild PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "userValueNames") (EVar "rest"))))
(DFunDef false "userValueNames" ((PCons (PCon "DTypeSig" PWild (PVar "n") PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "userValueNames") (EVar "rest"))))
(DFunDef false "userValueNames" ((PCons (PCon "DExtern" PWild (PVar "n") PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "userValueNames") (EVar "rest"))))
(DFunDef false "userValueNames" ((PCons (PCon "DLetGroup" PWild (PVar "bs")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "map") (EVar "letBindName")) (EVar "bs")) (EApp (EVar "userValueNames") (EVar "rest"))))
(DFunDef false "userValueNames" ((PCons (PRec "DInterface" ((rf "methods" None)) true) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "map") (EVar "ifaceMethodNm")) (EVar "methods")) (EApp (EVar "userValueNames") (EVar "rest"))))
(DFunDef false "userValueNames" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "userValueNames") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "userValueNames" ((PCons PWild (PVar "rest"))) (EApp (EVar "userValueNames") (EVar "rest")))
(DTypeSig false "fieldOwnersOf" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "fieldOwnersOf" ((PList)) (EListLit))
(DFunDef false "fieldOwnersOf" ((PCons (PRec "DData" ((rf "dataCtors" (PVar "vs"))) false) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "flatMap") (EVar "variantFieldOwners")) (EVar "vs")) (EApp (EVar "fieldOwnersOf") (EVar "rest"))))
(DFunDef false "fieldOwnersOf" ((PCons PWild (PVar "rest"))) (EApp (EVar "fieldOwnersOf") (EVar "rest")))
(DTypeSig false "recordFieldOwner" (TyFun (TyCon "String") (TyFun (TyCon "Field") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "recordFieldOwner" ((PVar "owner") (PCon "Field" (PVar "fname") PWild)) (ETuple (EVar "fname") (EVar "owner")))
(DTypeSig false "variantFieldOwners" (TyFun (TyCon "Variant") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "variantFieldOwners" ((PCon "Variant" (PVar "cname") (PCon "ConNamed" (PVar "fs") PWild))) (EApp (EApp (EVar "map") (EApp (EVar "recordFieldOwner") (EVar "cname"))) (EVar "fs")))
(DFunDef false "variantFieldOwners" ((PCon "Variant" PWild (PCon "ConPos" PWild))) (EListLit))
(DTypeSig false "importedNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "importedNames" ((PList)) (EListLit))
(DFunDef false "importedNames" ((PCons (PCon "DUse" PWild (PVar "path") PWild) (PVar "rest"))) (EBinOp "++" (EApp (EVar "useImportNames") (EVar "path")) (EApp (EVar "importedNames") (EVar "rest"))))
(DFunDef false "importedNames" ((PCons PWild (PVar "rest"))) (EApp (EVar "importedNames") (EVar "rest")))
(DTypeSig false "useImportNames" (TyFun (TyCon "UsePath") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "useImportNames" ((PVar "path")) (EIf (EBinOp "==" (EApp (EVar "useModId") (EVar "path")) (ELit (LString "core"))) (EListLit) (EApp (EVar "useStubNames") (EVar "path"))))
(DTypeSig false "useStubNames" (TyFun (TyCon "UsePath") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "useStubNames" ((PCon "UseName" (PVar "ns"))) (EListLit (EApp (EVar "lastOf") (EVar "ns"))))
(DFunDef false "useStubNames" ((PCon "UseGroup" PWild (PVar "ms"))) (EApp (EApp (EVar "map") (EVar "useMemberLocal")) (EVar "ms")))
(DFunDef false "useStubNames" ((PCon "UseWild" PWild)) (EListLit))
(DFunDef false "useStubNames" ((PCon "UseAlias" PWild PWild)) (EListLit))
(DTypeSig false "useModId" (TyFun (TyCon "UsePath") (TyCon "String")))
(DFunDef false "useModId" ((PCon "UseName" (PVar "ns"))) (EIf (EBinOp ">" (EApp (EVar "listLen") (EVar "ns")) (ELit (LInt 1))) (EApp (EVar "joinDot") (EApp (EVar "initList") (EVar "ns"))) (EApp (EApp (EVar "firstOr") (ELit (LString ""))) (EVar "ns"))))
(DFunDef false "useModId" ((PCon "UseGroup" (PVar "ns") PWild)) (EApp (EVar "joinDot") (EVar "ns")))
(DFunDef false "useModId" ((PCon "UseWild" (PVar "ns"))) (EApp (EVar "joinDot") (EVar "ns")))
(DFunDef false "useModId" ((PCon "UseAlias" (PVar "ns") PWild)) (EApp (EVar "joinDot") (EVar "ns")))
(DTypeSig false "lastOf" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "lastOf" ((PList)) (ELit (LString "")))
(DFunDef false "lastOf" ((PList (PVar "x"))) (EVar "x"))
(DFunDef false "lastOf" ((PCons PWild (PVar "rest"))) (EApp (EVar "lastOf") (EVar "rest")))
(DTypeSig false "firstOr" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))
(DFunDef false "firstOr" ((PVar "d") (PList)) (EVar "d"))
(DFunDef false "firstOr" (PWild (PCons (PVar "x") PWild)) (EVar "x"))
(DTypeSig false "programIsCore" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool")))
(DFunDef false "programIsCore" ((PVar "prog")) (EBinOp "&&" (EApp (EVar "hasOrdering") (EVar "prog")) (EApp (EVar "hasFoldable") (EVar "prog"))))
(DTypeSig false "hasOrdering" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool")))
(DFunDef false "hasOrdering" ((PList)) (EVar "False"))
(DFunDef false "hasOrdering" ((PCons (PRec "DData" ((rf "dataName" (PLit (LString "Ordering")))) false) PWild)) (EVar "True"))
(DFunDef false "hasOrdering" ((PCons PWild (PVar "rest"))) (EApp (EVar "hasOrdering") (EVar "rest")))
(DTypeSig false "hasFoldable" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool")))
(DFunDef false "hasFoldable" ((PList)) (EVar "False"))
(DFunDef false "hasFoldable" ((PCons (PRec "DInterface" ((rf "name" (PLit (LString "Foldable")))) true) PWild)) (EVar "True"))
(DFunDef false "hasFoldable" ((PCons PWild (PVar "rest"))) (EApp (EVar "hasFoldable") (EVar "rest")))
(DTypeSig false "buildEnv" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Env"))))))
(DFunDef false "buildEnv" ((PVar "runtimeDecls") (PVar "preludeDecls") (PVar "prog") (PVar "internalGuard")) (EBlock (DoLet false false (PVar "seed") (EApp (EVar "not") (EApp (EVar "programIsCore") (EVar "prog")))) (DoLet false false (PVar "pTypes") (EApp (EApp (EVar "whenL") (EVar "seed")) (EApp (EVar "dataRecordNames") (EVar "preludeDecls")))) (DoLet false false (PVar "pCtors") (EApp (EApp (EVar "whenL") (EVar "seed")) (EApp (EVar "ctorNames") (EVar "preludeDecls")))) (DoLet false false (PVar "pIfaces") (EApp (EApp (EVar "whenL") (EVar "seed")) (EApp (EVar "interfaceList") (EVar "preludeDecls")))) (DoLet false false (PVar "pValues") (EApp (EApp (EVar "whenL") (EVar "seed")) (EApp (EVar "preludeValueNames") (EVar "preludeDecls")))) (DoLet false false (PVar "pFieldOwners") (EApp (EApp (EVar "whenL") (EVar "seed")) (EApp (EVar "fieldOwnersOf") (EVar "preludeDecls")))) (DoLet false false (PVar "uIfaces") (EApp (EVar "interfaceList") (EVar "prog"))) (DoLet false false (PVar "imported") (EApp (EVar "importedNames") (EVar "prog"))) (DoLet false false (PVar "valuesM") (EApp (EApp (EVar "omFromNames") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EApp (EVar "externNames") (EVar "runtimeDecls")) (EVar "pValues")) (EApp (EVar "userValueNames") (EVar "prog"))) (EVar "imported"))) (EVar "omEmpty"))) (DoLet false false (PVar "typesM") (EApp (EApp (EVar "omFromNames") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EVar "primitiveTypes") (EVar "pTypes")) (EApp (EVar "dataRecordNames") (EVar "prog"))) (EVar "imported"))) (EVar "omEmpty"))) (DoLet false false (PVar "ctorsM") (EApp (EApp (EVar "omFromNames") (EBinOp "++" (EBinOp "++" (EVar "primitiveConstructors") (EVar "pCtors")) (EApp (EVar "ctorNames") (EVar "prog")))) (EVar "omEmpty"))) (DoLet false false (PVar "importedM") (EApp (EApp (EVar "omFromNames") (EVar "imported")) (EVar "omEmpty"))) (DoExpr (ERecordCreate "Env" ((fa "values" (EVar "valuesM")) (fa "types" (EVar "typesM")) (fa "ctors" (EVar "ctorsM")) (fa "fields" (EBinOp "++" (EApp (EApp (EVar "map") (EVar "fst")) (EVar "pFieldOwners")) (EApp (EApp (EVar "map") (EVar "fst")) (EApp (EVar "fieldOwnersOf") (EVar "prog"))))) (fa "fieldOwners" (EBinOp "++" (EVar "pFieldOwners") (EApp (EVar "fieldOwnersOf") (EVar "prog")))) (fa "fieldOwnersIdx" (EApp (EVar "buildFieldOwnerIndex") (EBinOp "++" (EVar "pFieldOwners") (EApp (EVar "fieldOwnersOf") (EVar "prog"))))) (fa "interfaces" (EBinOp "++" (EApp (EApp (EVar "map") (EVar "fst")) (EVar "pIfaces")) (EApp (EApp (EVar "map") (EVar "fst")) (EVar "uIfaces")))) (fa "ifaceMethods" (EBinOp "++" (EVar "pIfaces") (EVar "uIfaces"))) (fa "effects" (EApp (EVar "effectNames") (EVar "prog"))) (fa "imported" (EVar "importedM")) (fa "importedModuleValues" (EListLit)) (fa "ambiguous" (EListLit)) (fa "ctorAmbiguous" (EListLit)) (fa "typeAmbiguous" (EListLit)) (fa "ifaceAmbiguous" (EListLit)) (fa "internalGuard" (EApp (EApp (EVar "omFromNames") (EVar "internalGuard")) (EVar "omEmpty"))) (fa "sugValues" (EApp (EVar "sugPoolOf") (EBinOp "++" (EBinOp "++" (EApp (EVar "omKeys") (EVar "valuesM")) (EApp (EVar "omKeys") (EVar "ctorsM"))) (EApp (EVar "omKeys") (EVar "importedM"))))) (fa "sugTypes" (EApp (EVar "sugPoolOf") (EBinOp "++" (EApp (EVar "omKeys") (EVar "typesM")) (EApp (EVar "omKeys") (EVar "importedM"))))))))))
(DTypeSig false "whenL" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "whenL" ((PCon "True") (PVar "xs")) (EVar "xs"))
(DFunDef false "whenL" ((PCon "False") PWild) (EListLit))
(DTypeSig false "buildErrors" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "ResError")))))
(DFunDef false "buildErrors" ((PVar "preludeDecls") (PVar "prog")) (EBlock (DoLet false false (PVar "dupValErrs") (EApp (EVar "dupValueBindingErrors") (EVar "prog"))) (DoLet false false (PVar "nullaryDupNames") (EApp (EApp (EVar "map") (EVar "dvbName")) (EVar "dupValErrs"))) (DoLet false false (PVar "sigDups") (EApp (EApp (EApp (EVar "filterOutNamesIn") (EVar "nullaryDupNames")) (EVar "dupSigName")) (EApp (EVar "dupSignatureErrors") (EVar "prog")))) (DoLet false false (PVar "sigDupNames") (EApp (EApp (EVar "map") (EVar "dupSigName")) (EVar "sigDups"))) (DoLet false false (PVar "contigErrs") (EApp (EApp (EApp (EVar "filterOutNamesIn") (EVar "sigDupNames")) (EVar "dbName")) (EApp (EVar "contiguityErrors") (EVar "prog")))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "externWithBodyErrors") (EApp (EVar "externNames") (EVar "prog"))) (EVar "prog")) (EApp (EApp (EVar "duplicateErrors") (EVar "preludeDecls")) (EVar "prog"))) (EApp (EApp (EVar "coreUseErrors") (EVar "preludeDecls")) (EVar "prog"))) (EVar "sigDups")) (EVar "contigErrs")) (EVar "dupValErrs")))))
(DTypeSig false "coreUseErrors" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "ResError")))))
(DFunDef false "coreUseErrors" ((PVar "preludeDecls") (PVar "prog")) (EApp (EApp (EVar "flatMap") (EApp (EVar "coreUseErrorsOf") (EApp (EVar "coreExports") (EVar "preludeDecls")))) (EVar "prog")))
(DTypeSig false "coreUseErrorsOf" (TyFun (TyCon "ModuleExports") (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "ResError")))))
(DFunDef false "coreUseErrorsOf" ((PVar "coreExp") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EVar "coreUseErrorsOf") (EVar "coreExp")) (EVar "d")))
(DFunDef false "coreUseErrorsOf" ((PVar "coreExp") (PCon "DUse" PWild (PVar "path") (PVar "loc"))) (EIf (EBinOp "==" (EApp (EVar "useModId") (EVar "path")) (ELit (LString "core"))) (EBlock (DoLet false false (PTuple PWild (PVar "errs")) (EApp (EApp (EVar "importedNamesMM") (EVar "path")) (EVar "coreExp"))) (DoExpr (EApp (EApp (EVar "map") (EApp (EVar "withResErrorLoc") (EVar "loc"))) (EVar "errs")))) (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "coreUseErrorsOf" (PWild PWild) (EListLit))
(DTypeSig false "dvbName" (TyFun (TyCon "ResError") (TyCon "String")))
(DFunDef false "dvbName" ((PCon "DuplicateValueBinding" (PVar "n") PWild)) (EVar "n"))
(DFunDef false "dvbName" (PWild) (ELit (LString "")))
(DTypeSig false "dupSigName" (TyFun (TyCon "ResError") (TyCon "String")))
(DFunDef false "dupSigName" ((PCon "DuplicateSignature" (PVar "n") PWild PWild)) (EVar "n"))
(DFunDef false "dupSigName" (PWild) (ELit (LString "")))
(DTypeSig false "dbName" (TyFun (TyCon "ResError") (TyCon "String")))
(DFunDef false "dbName" ((PCon "DuplicateBinding" (PVar "n") PWild)) (EVar "n"))
(DFunDef false "dbName" (PWild) (ELit (LString "")))
(DTypeSig false "filterOutNamesIn" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyFun (TyCon "ResError") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "ResError")) (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "filterOutNamesIn" (PWild PWild (PList)) (EListLit))
(DFunDef false "filterOutNamesIn" ((PVar "names") (PVar "nameOf") (PCons (PVar "e") (PVar "rest"))) (EIf (EApp (EApp (EVar "contains") (EApp (EVar "nameOf") (EVar "e"))) (EVar "names")) (EApp (EApp (EApp (EVar "filterOutNamesIn") (EVar "names")) (EVar "nameOf")) (EVar "rest")) (EIf (EVar "otherwise") (EBinOp "::" (EVar "e") (EApp (EApp (EApp (EVar "filterOutNamesIn") (EVar "names")) (EVar "nameOf")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "dupSignatureErrors" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "ResError"))))
(DFunDef false "dupSignatureErrors" ((PVar "prog")) (EApp (EApp (EVar "dupSigGo") (EVar "prog")) (EVar "omEmpty")))
(DTypeSig false "dupSigGo" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "List") (TyCon "ResError")))))
(DFunDef false "dupSigGo" ((PList) PWild) (EListLit))
(DFunDef false "dupSigGo" ((PCons (PVar "d") (PVar "rest")) (PVar "seen")) (EMatch (EApp (EVar "dupSigOf") (EVar "d")) (arm (PCon "Some" (PTuple (PVar "n") (PVar "loc"))) () (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "seen")) (arm (PCon "Some" (PVar "earlierLoc")) () (EBinOp "::" (EApp (EApp (EApp (EVar "DuplicateSignature") (EVar "n")) (EVar "loc")) (EVar "earlierLoc")) (EApp (EApp (EVar "dupSigGo") (EVar "rest")) (EVar "seen")))) (arm (PCon "None") () (EApp (EApp (EVar "dupSigGo") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (EVar "loc")) (EVar "seen")))))) (arm (PCon "None") () (EApp (EApp (EVar "dupSigGo") (EVar "rest")) (EVar "seen")))))
(DTypeSig false "dupSigOf" (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc"))))))
(DFunDef false "dupSigOf" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "dupSigOf") (EVar "d")))
(DFunDef false "dupSigOf" ((PCon "DTypeSig" PWild (PVar "n") (PVar "ty"))) (EApp (EVar "Some") (ETuple (EVar "n") (EApp (EVar "firstTyLoc") (EVar "ty")))))
(DFunDef false "dupSigOf" (PWild) (EVar "None"))
(DTypeSig false "dupValueBindingErrors" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "ResError"))))
(DFunDef false "dupValueBindingErrors" ((PVar "prog")) (EApp (EApp (EApp (EVar "dupValGo") (EVar "None")) (EVar "False")) (EVar "prog")))
(DTypeSig false "dupValGo" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "dupValGo" (PWild PWild (PList)) (EListLit))
(DFunDef false "dupValGo" ((PVar "run") (PVar "sawNullary") (PCons (PVar "d") (PVar "rest"))) (EIf (EApp (EVar "isTransparentDecl") (EVar "d")) (EApp (EApp (EApp (EVar "dupValGo") (EVar "run")) (EVar "sawNullary")) (EVar "rest")) (EIf (EVar "otherwise") (EMatch (EApp (EVar "dupValClause") (EVar "d")) (arm (PCon "Some" (PTuple (PVar "n") (PVar "isNull") (PVar "loc"))) () (EBlock (DoLet false false (PVar "continuing") (EBinOp "==" (EVar "run") (EApp (EVar "Some") (EVar "n")))) (DoLet false false (PVar "dup") (EBinOp "&&" (EVar "continuing") (EBinOp "||" (EVar "sawNullary") (EVar "isNull")))) (DoLet false false (PVar "errs") (EApp (EApp (EVar "whenL") (EVar "dup")) (EListLit (EApp (EApp (EVar "DuplicateValueBinding") (EVar "n")) (EVar "loc"))))) (DoLet false false (PVar "sawNullary2") (EBinOp "||" (EBinOp "&&" (EVar "continuing") (EVar "sawNullary")) (EVar "isNull"))) (DoExpr (EBinOp "++" (EVar "errs") (EApp (EApp (EApp (EVar "dupValGo") (EApp (EVar "Some") (EVar "n"))) (EVar "sawNullary2")) (EVar "rest")))))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "dupValGo") (EVar "None")) (EVar "False")) (EVar "rest")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "dupValClause" (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Bool") (TyApp (TyCon "Option") (TyCon "Loc"))))))
(DFunDef false "dupValClause" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "dupValClause") (EVar "d")))
(DFunDef false "dupValClause" ((PCon "DFunDef" PWild (PVar "n") (PVar "ps") (PVar "body"))) (EApp (EVar "Some") (ETuple (EVar "n") (EApp (EVar "isEmptyL") (EVar "ps")) (EApp (EVar "firstExprLoc") (EVar "body")))))
(DFunDef false "dupValClause" (PWild) (EVar "None"))
(DTypeSig false "isEmptyL" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "Bool")))
(DFunDef false "isEmptyL" ((PList)) (EVar "True"))
(DFunDef false "isEmptyL" (PWild) (EVar "False"))
(DTypeSig false "declBindNames" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "declBindNames" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "declBindNames") (EVar "d")))
(DFunDef false "declBindNames" ((PCon "DFunDef" PWild (PVar "n") PWild PWild)) (EListLit (EVar "n")))
(DFunDef false "declBindNames" ((PCon "DLetGroup" PWild (PVar "bs"))) (EApp (EApp (EVar "map") (EVar "letBindName")) (EVar "bs")))
(DFunDef false "declBindNames" (PWild) (EListLit))
(DTypeSig false "isTransparentDecl" (TyFun (TyCon "Decl") (TyCon "Bool")))
(DFunDef false "isTransparentDecl" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "isTransparentDecl") (EVar "d")))
(DFunDef false "isTransparentDecl" ((PCon "DTypeSig" PWild PWild PWild)) (EVar "True"))
(DFunDef false "isTransparentDecl" (PWild) (EVar "False"))
(DTypeSig false "contiguityErrors" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "ResError"))))
(DFunDef false "contiguityErrors" ((PVar "prog")) (EApp (EApp (EApp (EVar "contigGo") (EVar "omEmpty")) (EListLit)) (EVar "prog")))
(DTypeSig false "contigGo" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "contigGo" (PWild PWild (PList)) (EListLit))
(DFunDef false "contigGo" ((PVar "closed") (PVar "opened") (PCons (PVar "d") (PVar "rest"))) (EIf (EApp (EVar "isTransparentDecl") (EVar "d")) (EApp (EApp (EApp (EVar "contigGo") (EVar "closed")) (EVar "opened")) (EVar "rest")) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "ns") (EApp (EVar "declBindNames") (EVar "d"))) (DoLet false false (PVar "stillOpen") (EApp (EApp (EVar "filterKeepOpen") (EVar "ns")) (EVar "opened"))) (DoLet false false (PVar "nowClosed") (EApp (EApp (EApp (EVar "closeMissing") (EVar "opened")) (EVar "stillOpen")) (EVar "closed"))) (DoLet false false (PVar "errs") (EApp (EApp (EApp (EVar "newlyDuplicated") (EApp (EVar "declLoc") (EVar "d"))) (EVar "nowClosed")) (EVar "ns"))) (DoLet false false (PVar "opened2") (EApp (EApp (EVar "unionStr") (EVar "stillOpen")) (EVar "ns"))) (DoLet false false (PVar "closed2") (EApp (EApp (EVar "deleteAllStr") (EVar "ns")) (EVar "nowClosed"))) (DoExpr (EBinOp "++" (EVar "errs") (EApp (EApp (EApp (EVar "contigGo") (EVar "closed2")) (EVar "opened2")) (EVar "rest"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "filterKeepOpen" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "filterKeepOpen" (PWild (PList)) (EListLit))
(DFunDef false "filterKeepOpen" ((PVar "ns") (PCons (PVar "o") (PVar "os"))) (EIf (EApp (EApp (EVar "contains") (EVar "o")) (EVar "ns")) (EBinOp "::" (EVar "o") (EApp (EApp (EVar "filterKeepOpen") (EVar "ns")) (EVar "os"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "filterKeepOpen") (EVar "ns")) (EVar "os")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "closeMissing" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit"))))))
(DFunDef false "closeMissing" ((PList) PWild (PVar "closed")) (EVar "closed"))
(DFunDef false "closeMissing" ((PCons (PVar "o") (PVar "os")) (PVar "stillOpen") (PVar "closed")) (EIf (EApp (EApp (EVar "contains") (EVar "o")) (EVar "stillOpen")) (EApp (EApp (EApp (EVar "closeMissing") (EVar "os")) (EVar "stillOpen")) (EVar "closed")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "closeMissing") (EVar "os")) (EVar "stillOpen")) (EApp (EApp (EApp (EVar "omInsert") (EVar "o")) (ELit LUnit)) (EVar "closed"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "deleteAllStr" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit")))))
(DFunDef false "deleteAllStr" ((PList) (PVar "closed")) (EVar "closed"))
(DFunDef false "deleteAllStr" ((PCons (PVar "n") (PVar "ns")) (PVar "closed")) (EApp (EApp (EVar "deleteAllStr") (EVar "ns")) (EApp (EApp (EVar "omDelete") (EVar "n")) (EVar "closed"))))
(DTypeSig false "newlyDuplicated" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "newlyDuplicated" (PWild PWild (PList)) (EListLit))
(DFunDef false "newlyDuplicated" ((PVar "loc") (PVar "closed") (PCons (PVar "n") (PVar "ns"))) (EIf (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "closed")) (EBinOp "::" (EApp (EApp (EVar "DuplicateBinding") (EVar "n")) (EVar "loc")) (EApp (EApp (EApp (EVar "newlyDuplicated") (EVar "loc")) (EVar "closed")) (EVar "ns"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "newlyDuplicated") (EVar "loc")) (EVar "closed")) (EVar "ns")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "declLoc" (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "declLoc" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "declLoc") (EVar "d")))
(DFunDef false "declLoc" ((PCon "DFunDef" PWild PWild PWild (PVar "body"))) (EApp (EVar "firstExprLoc") (EVar "body")))
(DFunDef false "declLoc" (PWild) (EVar "None"))
(DTypeSig false "firstExprLoc" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "firstExprLoc" ((PCon "ELoc" (PVar "l") PWild)) (EApp (EVar "Some") (EVar "l")))
(DFunDef false "firstExprLoc" ((PCon "EApp" (PVar "f") (PVar "x"))) (EApp (EApp (EVar "orElseLoc") (EApp (EVar "firstExprLoc") (EVar "f"))) (EApp (EVar "firstExprLoc") (EVar "x"))))
(DFunDef false "firstExprLoc" ((PCon "ELam" PWild (PVar "body"))) (EApp (EVar "firstExprLoc") (EVar "body")))
(DFunDef false "firstExprLoc" ((PCon "ELet" PWild PWild PWild (PVar "e1") (PVar "e2"))) (EApp (EApp (EVar "orElseLoc") (EApp (EVar "firstExprLoc") (EVar "e1"))) (EApp (EVar "firstExprLoc") (EVar "e2"))))
(DFunDef false "firstExprLoc" ((PCon "ELetGroup" PWild (PVar "body"))) (EApp (EVar "firstExprLoc") (EVar "body")))
(DFunDef false "firstExprLoc" ((PCon "EMatch" (PVar "e0") PWild)) (EApp (EVar "firstExprLoc") (EVar "e0")))
(DFunDef false "firstExprLoc" ((PCon "EIf" (PVar "c") (PVar "t") (PVar "el"))) (EApp (EApp (EVar "orElseLoc") (EApp (EVar "firstExprLoc") (EVar "c"))) (EApp (EApp (EVar "orElseLoc") (EApp (EVar "firstExprLoc") (EVar "t"))) (EApp (EVar "firstExprLoc") (EVar "el")))))
(DFunDef false "firstExprLoc" ((PCon "EBinOp" PWild (PVar "a") (PVar "b") PWild)) (EApp (EApp (EVar "orElseLoc") (EApp (EVar "firstExprLoc") (EVar "a"))) (EApp (EVar "firstExprLoc") (EVar "b"))))
(DFunDef false "firstExprLoc" ((PCon "EUnOp" PWild (PVar "a") PWild)) (EApp (EVar "firstExprLoc") (EVar "a")))
(DFunDef false "firstExprLoc" ((PCon "EInfix" PWild (PVar "a") (PVar "b"))) (EApp (EApp (EVar "orElseLoc") (EApp (EVar "firstExprLoc") (EVar "a"))) (EApp (EVar "firstExprLoc") (EVar "b"))))
(DFunDef false "firstExprLoc" ((PCon "EFieldAccess" (PVar "e0") PWild PWild)) (EApp (EVar "firstExprLoc") (EVar "e0")))
(DFunDef false "firstExprLoc" ((PCon "ETuple" (PVar "es"))) (EApp (EVar "firstLocList") (EVar "es")))
(DFunDef false "firstExprLoc" ((PCon "EListLit" (PVar "es"))) (EApp (EVar "firstLocList") (EVar "es")))
(DFunDef false "firstExprLoc" ((PCon "EArrayLit" (PVar "es"))) (EApp (EVar "firstLocList") (EVar "es")))
(DFunDef false "firstExprLoc" ((PCon "EAnnot" (PVar "e0") PWild)) (EApp (EVar "firstExprLoc") (EVar "e0")))
(DFunDef false "firstExprLoc" ((PCon "EHeadAnnot" (PVar "e0") PWild)) (EApp (EVar "firstExprLoc") (EVar "e0")))
(DFunDef false "firstExprLoc" ((PCon "ERangeList" (PVar "lo") (PVar "hi") PWild)) (EApp (EApp (EVar "orElseLoc") (EApp (EVar "firstExprLoc") (EVar "lo"))) (EApp (EVar "firstExprLoc") (EVar "hi"))))
(DFunDef false "firstExprLoc" ((PCon "ERangeArray" (PVar "lo") (PVar "hi") PWild)) (EApp (EApp (EVar "orElseLoc") (EApp (EVar "firstExprLoc") (EVar "lo"))) (EApp (EVar "firstExprLoc") (EVar "hi"))))
(DFunDef false "firstExprLoc" ((PCon "EIndex" (PVar "e0") (PVar "i") PWild)) (EApp (EApp (EVar "orElseLoc") (EApp (EVar "firstExprLoc") (EVar "e0"))) (EApp (EVar "firstExprLoc") (EVar "i"))))
(DFunDef false "firstExprLoc" ((PCon "ESlice" (PVar "e0") (PVar "lo") (PVar "hi") PWild PWild)) (EApp (EApp (EVar "orElseLoc") (EApp (EVar "firstExprLoc") (EVar "e0"))) (EApp (EApp (EVar "orElseLoc") (EApp (EVar "firstExprLoc") (EVar "lo"))) (EApp (EVar "firstExprLoc") (EVar "hi")))))
(DFunDef false "firstExprLoc" ((PCon "EDoOrigin" PWild (PVar "e"))) (EApp (EVar "firstExprLoc") (EVar "e")))
(DFunDef false "firstExprLoc" (PWild) (EVar "None"))
(DTypeSig false "firstLocList" (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "firstLocList" ((PList)) (EVar "None"))
(DFunDef false "firstLocList" ((PCons (PVar "e") (PVar "rest"))) (EApp (EApp (EVar "orElseLoc") (EApp (EVar "firstExprLoc") (EVar "e"))) (EApp (EVar "firstLocList") (EVar "rest"))))
(DTypeSig false "unionStr" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "unionStr" ((PVar "acc") (PList)) (EVar "acc"))
(DFunDef false "unionStr" ((PVar "acc") (PCons (PVar "x") (PVar "xs"))) (EIf (EApp (EApp (EVar "contains") (EVar "x")) (EVar "acc")) (EApp (EApp (EVar "unionStr") (EVar "acc")) (EVar "xs")) (EIf (EVar "otherwise") (EApp (EApp (EVar "unionStr") (EBinOp "++" (EVar "acc") (EListLit (EVar "x")))) (EVar "xs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "externWithBodyErrors" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "ResError")))))
(DFunDef false "externWithBodyErrors" (PWild (PList)) (EListLit))
(DFunDef false "externWithBodyErrors" ((PVar "externs") (PCons (PCon "DFunDef" PWild (PVar "n") PWild PWild) (PVar "rest"))) (EBinOp "++" (EIf (EApp (EApp (EVar "contains") (EVar "n")) (EVar "externs")) (EListLit (EApp (EApp (EVar "ExternWithBody") (EVar "n")) (EVar "None"))) (EListLit)) (EApp (EApp (EVar "externWithBodyErrors") (EVar "externs")) (EVar "rest"))))
(DFunDef false "externWithBodyErrors" ((PVar "externs") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "externWithBodyErrors") (EVar "externs")) (EVar "rest")))
(DTypeSig false "duplicateErrors" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "ResError")))))
(DFunDef false "duplicateErrors" ((PVar "preludeDecls") (PVar "prog")) (EBlock (DoLet false false (PVar "seed") (EApp (EVar "not") (EApp (EVar "programIsCore") (EVar "prog")))) (DoLet false false (PVar "typeSeed") (EBinOp "++" (EVar "primitiveTypes") (EApp (EApp (EVar "whenL") (EVar "seed")) (EApp (EVar "dataRecordNames") (EVar "preludeDecls"))))) (DoLet false false (PVar "ctorSeed") (EBinOp "++" (EVar "primitiveConstructors") (EApp (EApp (EVar "whenL") (EVar "seed")) (EApp (EVar "ctorNames") (EVar "preludeDecls"))))) (DoLet false false (PVar "ifaceSeed") (EApp (EApp (EVar "whenL") (EVar "seed")) (EApp (EApp (EVar "map") (EVar "fst")) (EApp (EVar "interfaceList") (EVar "preludeDecls"))))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "map") (EApp (EVar "dupErr") (ELit (LString "type")))) (EApp (EApp (EVar "findDups") (EVar "typeSeed")) (EApp (EVar "dataRecordNames") (EVar "prog")))) (EApp (EApp (EVar "map") (EApp (EVar "dupErr") (ELit (LString "constructor")))) (EApp (EApp (EVar "findDups") (EVar "ctorSeed")) (EApp (EVar "ctorNames") (EVar "prog"))))) (EApp (EApp (EVar "map") (EApp (EVar "dupErr") (ELit (LString "interface")))) (EApp (EApp (EVar "findDups") (EVar "ifaceSeed")) (EApp (EApp (EVar "map") (EVar "fst")) (EApp (EVar "interfaceList") (EVar "prog")))))) (EApp (EVar "ifaceMethodCollisions") (EVar "prog"))))))
(DTypeSig false "dupErr" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "ResError"))))
(DFunDef false "dupErr" ((PVar "kind") (PVar "n")) (EApp (EApp (EApp (EVar "DuplicateDefinition") (EVar "kind")) (EVar "n")) (EVar "None")))
(DTypeSig false "ifaceMethodCollisions" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "ResError"))))
(DFunDef false "ifaceMethodCollisions" ((PVar "prog")) (EApp (EApp (EVar "ifaceMethodCollisionsGo") (EVar "omEmpty")) (EApp (EVar "ownInterfaceMethods") (EVar "prog"))))
(DTypeSig false "ifaceMethodCollisionsGo" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyApp (TyCon "List") (TyCon "ResError")))))
(DFunDef false "ifaceMethodCollisionsGo" (PWild (PList)) (EListLit))
(DFunDef false "ifaceMethodCollisionsGo" ((PVar "seen") (PCons (PTuple (PVar "iname") (PVar "ms")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EApp (EVar "ifaceMethodErrs") (EVar "iname")) (EVar "seen")) (EVar "ms")) (EApp (EApp (EVar "ifaceMethodCollisionsGo") (EApp (EApp (EApp (EVar "addIfaceMethods") (EVar "iname")) (EVar "ms")) (EVar "seen"))) (EVar "rest"))))
(DTypeSig false "ifaceMethodErrs" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "ifaceMethodErrs" (PWild PWild (PList)) (EListLit))
(DFunDef false "ifaceMethodErrs" ((PVar "iname") (PVar "seen") (PCons (PVar "m") (PVar "rest"))) (EMatch (EApp (EApp (EVar "omLookup") (EVar "m")) (EVar "seen")) (arm (PCon "Some" (PVar "prev")) () (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "DuplicateInterfaceMethod") (EVar "m")) (EVar "prev")) (EVar "iname")) (EVar "None")) (EApp (EApp (EApp (EVar "ifaceMethodErrs") (EVar "iname")) (EVar "seen")) (EVar "rest")))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "ifaceMethodErrs") (EVar "iname")) (EVar "seen")) (EVar "rest")))))
(DTypeSig false "addIfaceMethods" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyApp (TyCon "OrdMap") (TyCon "String"))))))
(DFunDef false "addIfaceMethods" (PWild (PList) (PVar "seen")) (EVar "seen"))
(DFunDef false "addIfaceMethods" ((PVar "iname") (PCons (PVar "m") (PVar "rest")) (PVar "seen")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "m")) (EVar "seen")) (EApp (EApp (EApp (EVar "addIfaceMethods") (EVar "iname")) (EVar "rest")) (EVar "seen")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "addIfaceMethods") (EVar "iname")) (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "m")) (EVar "iname")) (EVar "seen"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "ownInterfaceMethods" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "ownInterfaceMethods" ((PList)) (EListLit))
(DFunDef false "ownInterfaceMethods" ((PCons (PRec "DInterface" ((rf "name" (PVar "n")) (rf "methods" None)) true) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "n") (EApp (EApp (EVar "map") (EVar "ifaceMethodNm")) (EVar "methods"))) (EApp (EVar "ownInterfaceMethods") (EVar "rest"))))
(DFunDef false "ownInterfaceMethods" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "ownInterfaceMethods") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "ownInterfaceMethods" ((PCons PWild (PVar "rest"))) (EApp (EVar "ownInterfaceMethods") (EVar "rest")))
(DTypeSig false "findDups" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "findDups" ((PVar "seen") (PVar "names")) (EApp (EApp (EVar "findDupsGo") (EApp (EApp (EVar "omFromNames") (EVar "seen")) (EVar "omEmpty"))) (EVar "names")))
(DTypeSig false "findDupsGo" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "findDupsGo" (PWild (PList)) (EListLit))
(DFunDef false "findDupsGo" ((PVar "seen") (PCons (PVar "n") (PVar "rest"))) (EIf (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "seen")) (EBinOp "::" (EVar "n") (EApp (EApp (EVar "findDupsGo") (EVar "seen")) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "findDupsGo") (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (ELit LUnit)) (EVar "seen"))) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "resErrorSexp" (TyFun (TyCon "ResError") (TyCon "String")))
(DFunDef false "resErrorSexp" ((PCon "UnboundVariable" (PVar "n") PWild PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "(UnboundVariable ")) (EApp (EVar "escStr") (EVar "n"))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "UnboundVariableExported" (PVar "n") (PVar "m") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(UnboundVariableExported ")) (EApp (EVar "display") (EApp (EVar "escStr") (EVar "n")))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EVar "escStr") (EVar "m")))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "UnboundVariableIsModule" (PVar "n") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "(UnboundVariableIsModule ")) (EApp (EVar "display") (EApp (EVar "escStr") (EVar "n")))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "UnknownConstructor" (PVar "n") PWild PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "(UnknownConstructor ")) (EApp (EVar "escStr") (EVar "n"))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "UnknownType" (PVar "n") PWild PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "(UnknownType ")) (EApp (EVar "escStr") (EVar "n"))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "UnknownEffect" (PVar "n") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "(UnknownEffect ")) (EApp (EVar "escStr") (EVar "n"))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "UnknownField" (PVar "n") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "(UnknownField ")) (EApp (EVar "escStr") (EVar "n"))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "FieldNotInRecord" (PVar "f") (PVar "r") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(FieldNotInRecord ")) (EApp (EVar "display") (EApp (EVar "escStr") (EVar "f")))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EVar "escStr") (EVar "r")))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "DuplicateDefinition" (PVar "k") (PVar "n") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(DuplicateDefinition ")) (EApp (EVar "display") (EApp (EVar "escStr") (EVar "k")))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EVar "escStr") (EVar "n")))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "InternalExternAccess" (PVar "n") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "(InternalExternAccess ")) (EApp (EVar "escStr") (EVar "n"))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "UnknownInterface" (PVar "n") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "(UnknownInterface ")) (EApp (EVar "escStr") (EVar "n"))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "MethodNotInInterface" (PVar "m") (PVar "i") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(MethodNotInInterface ")) (EApp (EVar "display") (EApp (EVar "escStr") (EVar "m")))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EVar "escStr") (EVar "i")))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "ExternWithBody" (PVar "n") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "(ExternWithBody ")) (EApp (EVar "escStr") (EVar "n"))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "PrivateNameAccess" (PVar "n") (PVar "m") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(PrivateNameAccess ")) (EApp (EVar "display") (EApp (EVar "escStr") (EVar "n")))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EVar "escStr") (EVar "m")))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "NoExportedConstructors" (PVar "n") (PVar "m") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(NoExportedConstructors ")) (EApp (EVar "display") (EApp (EVar "escStr") (EVar "n")))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EVar "escStr") (EVar "m")))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "NewtypeCtorNotExported" (PVar "n") (PVar "m") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(NewtypeCtorNotExported ")) (EApp (EVar "display") (EApp (EVar "escStr") (EVar "n")))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EVar "escStr") (EVar "m")))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "AbstractFieldAccess" (PVar "t") (PVar "f") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(AbstractFieldAccess ")) (EApp (EVar "display") (EApp (EVar "escStr") (EVar "t")))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EVar "escStr") (EVar "f")))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "UnknownModule" (PVar "n") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "(UnknownModule ")) (EApp (EVar "escStr") (EVar "n"))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "NonRecursiveValueLet" (PVar "n") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "(NonRecursiveValueLet ")) (EApp (EVar "escStr") (EVar "n"))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "DuplicateBinding" (PVar "n") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "(DuplicateBinding ")) (EApp (EVar "escStr") (EVar "n"))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "DuplicateValueBinding" (PVar "n") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "(DuplicateValueBinding ")) (EApp (EVar "escStr") (EVar "n"))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "DuplicateSignature" (PVar "n") PWild PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "(DuplicateSignature ")) (EApp (EVar "escStr") (EVar "n"))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "DuplicateBinder" (PVar "k") (PVar "n") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(DuplicateBinder ")) (EApp (EVar "display") (EApp (EVar "escStr") (EVar "k")))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EVar "escStr") (EVar "n")))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "AsPatternMisplaced" PWild)) (ELit (LString "AsPatternMisplaced")))
(DFunDef false "resErrorSexp" ((PCon "AmbiguousOccurrence" (PVar "n") (PVar "mods") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "(AmbiguousOccurrence ")) (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EBinOp "::" (EApp (EVar "escStr") (EVar "n")) (EApp (EApp (EVar "map") (EVar "escStr")) (EVar "mods"))))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "AmbiguousConstructor" (PVar "n") (PVar "mods") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "(AmbiguousConstructor ")) (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EBinOp "::" (EApp (EVar "escStr") (EVar "n")) (EApp (EApp (EVar "map") (EVar "escStr")) (EVar "mods"))))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "AmbiguousType" (PVar "n") (PVar "mods") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "(AmbiguousType ")) (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EBinOp "::" (EApp (EVar "escStr") (EVar "n")) (EApp (EApp (EVar "map") (EVar "escStr")) (EVar "mods"))))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "AmbiguousInterface" (PVar "n") (PVar "mods") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "(AmbiguousInterface ")) (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EBinOp "::" (EApp (EVar "escStr") (EVar "n")) (EApp (EApp (EVar "map") (EVar "escStr")) (EVar "mods"))))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "ReassignImmutable" (PVar "n") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "(ReassignImmutable ")) (EApp (EVar "escStr") (EVar "n"))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "DuplicateInterfaceMethod" (PVar "m") (PVar "a") (PVar "b") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(DuplicateInterfaceMethod ")) (EApp (EVar "display") (EApp (EVar "escStr") (EVar "m")))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EVar "escStr") (EVar "a")))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EVar "escStr") (EVar "b")))) (ELit (LString ")"))))
(DTypeSig false "locKey" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "String")))
(DFunDef false "locKey" ((PCon "None")) (ELit (LString "-")))
(DFunDef false "locKey" ((PCon "Some" (PCon "Loc" (PVar "f") (PVar "sl") (PVar "sc") (PVar "el") (PVar "ec")))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "f"))) (ELit (LString ":"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "sl")))) (ELit (LString ":"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "sc")))) (ELit (LString ":"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "el")))) (ELit (LString ":"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "ec")))) (ELit (LString ""))))
(DTypeSig false "dedupResErrors" (TyFun (TyApp (TyCon "List") (TyCon "ResError")) (TyApp (TyCon "List") (TyCon "ResError"))))
(DFunDef false "dedupResErrors" ((PVar "es")) (EApp (EApp (EVar "dedupBy") (EVar "resErrorDedupKey")) (EVar "es")))
(DTypeSig false "resErrorDedupKey" (TyFun (TyCon "ResError") (TyCon "String")))
(DFunDef false "resErrorDedupKey" ((PVar "e")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "resErrorCode") (EVar "e")))) (ELit (LString "|"))) (EApp (EVar "display") (EApp (EVar "ppResError") (EVar "e")))) (ELit (LString "|"))) (EApp (EVar "display") (EApp (EVar "locKey") (EApp (EVar "resErrorLoc") (EVar "e"))))) (ELit (LString ""))))
(DTypeSig true "resolveProgram" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "resolveProgram" ((PVar "runtimeDecls") (PVar "preludeDecls") (PVar "prog")) (EBlock (DoLet false false (PVar "env") (EApp (EApp (EApp (EApp (EVar "buildEnv") (EVar "runtimeDecls")) (EVar "preludeDecls")) (EVar "prog")) (EListLit))) (DoExpr (EApp (EVar "dedupResErrors") (EBinOp "++" (EApp (EApp (EVar "buildErrors") (EVar "preludeDecls")) (EVar "prog")) (EApp (EApp (EVar "flatMap") (EApp (EVar "checkDecl") (EVar "env"))) (EVar "prog")))))))
(DTypeSig true "resolveProgramG2" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "ResError")))))))
(DFunDef false "resolveProgramG2" ((PVar "internalGuard") (PVar "runtimeDecls") (PVar "preludeDecls") (PVar "prog")) (EBlock (DoLet false false (PVar "env") (EApp (EApp (EApp (EApp (EVar "buildEnv") (EVar "runtimeDecls")) (EVar "preludeDecls")) (EVar "prog")) (EVar "internalGuard"))) (DoExpr (EApp (EVar "dedupResErrors") (EBinOp "++" (EApp (EApp (EVar "buildErrors") (EVar "preludeDecls")) (EVar "prog")) (EApp (EApp (EVar "flatMap") (EApp (EVar "checkDecl") (EVar "env"))) (EVar "prog")))))))
(DTypeSig true "ppResError" (TyFun (TyCon "ResError") (TyCon "String")))
(DFunDef false "ppResError" ((PCon "UnboundVariable" (PVar "n") PWild (PVar "s"))) (EMatch (EVar "s") (arm (PCon "Some" (PVar "sug")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Unbound variable: ")) (EApp (EVar "display") (EVar "n"))) (ELit (LString ". Did you mean '"))) (EApp (EVar "display") (EVar "sug"))) (ELit (LString "'"))) (EApp (EApp (EVar "haskellNote") (EVar "n")) (EVar "sug")))) (arm (PCon "None") () (EBinOp "++" (EBinOp "++" (ELit (LString "Unbound variable: ")) (EApp (EVar "display") (EVar "n"))) (ELit (LString ""))))))
(DFunDef false "ppResError" ((PCon "UnboundVariableExported" (PVar "n") (PVar "m") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Unbound variable: ")) (EApp (EVar "display") (EVar "n"))) (ELit (LString ". (Did you forget to 'import "))) (EApp (EVar "display") (EVar "m"))) (ELit (LString ".{"))) (EApp (EVar "display") (EVar "n"))) (ELit (LString "}'?)"))))
(DFunDef false "ppResError" ((PCon "UnboundVariableIsModule" (PVar "n") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Unbound variable: ")) (EApp (EVar "display") (EVar "n"))) (ELit (LString ". '"))) (EApp (EVar "display") (EVar "n"))) (ELit (LString "' is an imported module, not a value — a bare "))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "'import ")) (EApp (EVar "display") (EVar "n"))) (ELit (LString "' binds no names. Bind what you need: 'import "))) (EApp (EVar "display") (EVar "n"))) (ELit (LString ".{name, ")))) (EBinOp "++" (EBinOp "++" (ELit (LString "...}', or 'import ")) (EApp (EVar "display") (EVar "n"))) (ELit (LString " as M' then 'M.name'")))))
(DFunDef false "ppResError" ((PCon "UnknownConstructor" (PVar "n") PWild (PVar "s"))) (EMatch (EVar "s") (arm (PCon "Some" (PVar "sug")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Unknown constructor: ")) (EApp (EVar "display") (EVar "n"))) (ELit (LString ". Did you mean '"))) (EApp (EVar "display") (EVar "sug"))) (ELit (LString "'"))) (EApp (EApp (EVar "haskellNote") (EVar "n")) (EVar "sug")))) (arm (PCon "None") () (EBinOp "++" (ELit (LString "Unknown constructor: ")) (EVar "n")))))
(DFunDef false "ppResError" ((PCon "UnknownType" (PVar "n") PWild (PVar "s"))) (EMatch (EVar "s") (arm (PCon "Some" (PVar "sug")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Unknown type: ")) (EApp (EVar "display") (EVar "n"))) (ELit (LString ". Did you mean '"))) (EApp (EVar "display") (EVar "sug"))) (ELit (LString "'"))) (EApp (EApp (EVar "haskellNote") (EVar "n")) (EVar "sug")))) (arm (PCon "None") () (EBinOp "++" (ELit (LString "Unknown type: ")) (EVar "n")))))
(DFunDef false "ppResError" ((PCon "UnknownEffect" (PVar "n") PWild)) (EIf (EBinOp "||" (EBinOp "==" (EVar "n") (ELit (LString "Mut"))) (EBinOp "==" (EVar "n") (ELit (LString "Panic")))) (EBinOp "++" (EBinOp "++" (ELit (LString "Unknown effect: ")) (EApp (EVar "display") (EVar "n"))) (ELit (LString " — the `Mut`/`Panic` purity labels were removed. Delete the annotation: purity is no longer tracked as an effect label, and effect labels now name host capabilities (`IO`, `Rand`, `FileRead`, …)"))) (EBinOp "++" (ELit (LString "Unknown effect: ")) (EVar "n"))))
(DFunDef false "ppResError" ((PCon "UnknownField" (PVar "n") PWild)) (EBinOp "++" (ELit (LString "Unknown field: ")) (EVar "n")))
(DFunDef false "ppResError" ((PCon "FieldNotInRecord" (PVar "f") (PVar "r") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Unknown field: ")) (EApp (EVar "display") (EVar "f"))) (ELit (LString ". Record '"))) (EApp (EVar "display") (EVar "r"))) (ELit (LString "' has no field '"))) (EApp (EVar "display") (EVar "f"))) (ELit (LString "'"))))
(DFunDef false "ppResError" ((PCon "DuplicateDefinition" (PVar "k") (PVar "n") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Duplicate ")) (EApp (EVar "display") (EVar "k"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "n"))) (ELit (LString ""))))
(DFunDef false "ppResError" ((PCon "UnknownInterface" (PVar "n") PWild)) (EBinOp "++" (ELit (LString "Unknown interface: ")) (EVar "n")))
(DFunDef false "ppResError" ((PCon "MethodNotInInterface" (PVar "m") (PVar "i") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Method '")) (EApp (EVar "display") (EVar "m"))) (ELit (LString "' is not part of interface '"))) (EApp (EVar "display") (EVar "i"))) (ELit (LString "'"))))
(DFunDef false "ppResError" ((PCon "ExternWithBody" (PVar "n") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "Extern '")) (EVar "n")) (ELit (LString "' must not have a definition body"))))
(DFunDef false "ppResError" ((PCon "PrivateNameAccess" (PVar "n") (PVar "m") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Module '")) (EApp (EVar "display") (EVar "m"))) (ELit (LString "' has no exported name '"))) (EApp (EVar "display") (EVar "n"))) (ELit (LString "'"))))
(DFunDef false "ppResError" ((PCon "NoExportedConstructors" (PVar "n") (PVar "m") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "'")) (EApp (EVar "display") (EVar "n"))) (ELit (LString "' exports no constructors from module '"))) (EApp (EVar "display") (EVar "m"))) (ELit (LString "' (exported abstractly). Remove `(..)` or export with `public export`"))))
(DFunDef false "ppResError" ((PCon "NewtypeCtorNotExported" (PVar "n") (PVar "m") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "'")) (EApp (EVar "display") (EVar "n"))) (ELit (LString "' exports no constructors: a `newtype`'s constructor is always module-private, and `public` is a parse error on `newtype`. Expose it with an accessor function, or declare '"))) (EApp (EVar "display") (EVar "n"))) (ELit (LString "' as a `public export data` with one variant"))))
(DFunDef false "ppResError" ((PCon "AbstractFieldAccess" (PVar "t") (PVar "f") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "'")) (EApp (EVar "display") (EVar "t"))) (ELit (LString "' is exported abstractly. Field '"))) (EApp (EVar "display") (EVar "f"))) (ELit (LString "' is not accessible; declare it `public export` to expose its fields"))))
(DFunDef false "ppResError" ((PCon "UnknownModule" (PVar "n") PWild)) (EBinOp "++" (ELit (LString "Unknown module: ")) (EVar "n")))
(DFunDef false "ppResError" ((PCon "AsPatternMisplaced" PWild)) (ELit (LString "`@` as-patterns are only allowed in a binding position (a lambda parameter, a do-block bind, or a match pattern)")))
(DFunDef false "ppResError" ((PCon "NonRecursiveValueLet" (PVar "n") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "'")) (EApp (EVar "display") (EVar "n"))) (ELit (LString "' is not in scope in its own binding. Non-function `let` is not recursive; write `let rec "))) (EApp (EVar "display") (EVar "n"))) (ELit (LString " = ...` (RHS must be a lambda)"))))
(DFunDef false "ppResError" ((PCon "DuplicateBinding" (PVar "n") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "Clauses of '")) (EApp (EVar "display") (EVar "n"))) (ELit (LString "' must be contiguous. An earlier same-named binding is separated by another declaration; group all clauses (and the signature) together"))))
(DFunDef false "ppResError" ((PCon "DuplicateValueBinding" (PVar "n") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "Duplicate binding '")) (EApp (EVar "display") (EVar "n"))) (ELit (LString "': it is already defined in this scope. A value binding has exactly one definition — rename this one or remove it"))))
(DFunDef false "ppResError" ((PCon "DuplicateSignature" (PVar "n") PWild (PCon "Some" (PCon "Loc" PWild (PVar "l") PWild PWild PWild)))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "'")) (EApp (EVar "display") (EVar "n"))) (ELit (LString "' is already defined at line "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "l")))) (ELit (LString ". A name may have only one type signature — rename or remove this duplicate definition, or merge the clauses into a single multi-clause function if that was the intent"))))
(DFunDef false "ppResError" ((PCon "DuplicateSignature" (PVar "n") PWild (PCon "None"))) (EBinOp "++" (EBinOp "++" (ELit (LString "'")) (EApp (EVar "display") (EVar "n"))) (ELit (LString "' is already defined earlier in this file. A name may have only one type signature — rename or remove this duplicate definition, or merge the clauses into a single multi-clause function if that was the intent"))))
(DFunDef false "ppResError" ((PCon "DuplicateBinder" (PVar "k") (PVar "n") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Duplicate binder: '")) (EApp (EVar "display") (EVar "n"))) (ELit (LString "' is bound more than once in this "))) (EApp (EVar "display") (EVar "k"))) (ELit (LString ". Each binder must be distinct — rename one occurrence"))))
(DFunDef false "ppResError" ((PCon "AmbiguousOccurrence" (PVar "n") (PVar "mods") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Ambiguous occurrence: '")) (EApp (EVar "display") (EVar "n"))) (ELit (LString "' is exported by "))) (EApp (EVar "display") (EApp (EVar "ambigModPhrase") (EVar "mods")))) (ELit (LString ". Qualify, or select with `import <mod>.{"))) (EApp (EVar "display") (EVar "n"))) (ELit (LString "}`"))))
(DFunDef false "ppResError" ((PCon "AmbiguousConstructor" (PVar "n") (PVar "mods") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Ambiguous constructor: '")) (EApp (EVar "display") (EVar "n"))) (ELit (LString "' is brought into scope by "))) (EApp (EVar "display") (EApp (EVar "ambigModPhrase") (EVar "mods")))) (ELit (LString ". Import the constructors of only one — e.g. `import <mod>.{T(..)}` — and drop the other's `(..)`"))))
(DFunDef false "ppResError" ((PCon "AmbiguousType" (PVar "n") (PVar "mods") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Ambiguous type: '")) (EApp (EVar "display") (EVar "n"))) (ELit (LString "' is brought into scope by "))) (EApp (EVar "display") (EApp (EVar "ambigModPhrase") (EVar "mods")))) (ELit (LString ". A type name can be neither qualified nor aliased, so import it from only one — drop '"))) (EApp (EVar "display") (EVar "n"))) (ELit (LString "' from the other's import list"))))
(DFunDef false "ppResError" ((PCon "AmbiguousInterface" (PVar "n") (PVar "mods") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Ambiguous interface: '")) (EApp (EVar "display") (EVar "n"))) (ELit (LString "' is brought into scope by "))) (EApp (EVar "display") (EApp (EVar "ambigModPhrase") (EVar "mods")))) (ELit (LString ". An interface name can be neither qualified nor aliased, so import it from only one — drop '"))) (EApp (EVar "display") (EVar "n"))) (ELit (LString "' from the other's import list"))))
(DFunDef false "ppResError" ((PCon "InternalExternAccess" (PVar "n") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "'")) (EVar "n")) (ELit (LString "' is an internal-only primitive. Cannot be used outside the standard library (pass --allow-internal to override)"))))
(DFunDef false "ppResError" ((PCon "DuplicateInterfaceMethod" (PVar "m") (PVar "a") (PVar "b") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Method '")) (EApp (EVar "display") (EVar "m"))) (ELit (LString "' is declared by two interfaces in this module: '"))) (EApp (EVar "display") (EVar "a"))) (ELit (LString "' and '"))) (EApp (EVar "display") (EVar "b"))) (ELit (LString "'. Two interfaces declared together may not share a method name — an occurrence of '"))) (EApp (EVar "display") (EVar "m"))) (ELit (LString "' could not be attributed to either. Rename the method in one of them, or merge the two interfaces. (A method name shared with a PRELUDE interface is a different case and stays legal.)"))))
(DFunDef false "ppResError" ((PCon "ReassignImmutable" (PVar "n") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Cannot reassign '")) (EApp (EVar "display") (EVar "n"))) (ELit (LString "' — bindings are immutable. To bind a new value, shadow it with `let "))) (EApp (EVar "display") (EVar "n"))) (ELit (LString " = ...`. For mutable state, use a `Ref`: `let "))) (EApp (EVar "display") (EVar "n"))) (ELit (LString " = Ref 0`, then write `"))) (EApp (EVar "display") (EVar "n"))) (ELit (LString " := !"))) (EApp (EVar "display") (EVar "n"))) (ELit (LString " + 1` (read the cell with `!"))) (EApp (EVar "display") (EVar "n"))) (ELit (LString "`)"))))
(DTypeSig true "resErrorCode" (TyFun (TyCon "ResError") (TyCon "String")))
(DFunDef false "resErrorCode" ((PCon "UnboundVariable" PWild PWild PWild)) (ELit (LString "R-UNBOUND")))
(DFunDef false "resErrorCode" ((PCon "UnboundVariableExported" PWild PWild PWild)) (ELit (LString "R-UNBOUND")))
(DFunDef false "resErrorCode" ((PCon "UnboundVariableIsModule" PWild PWild)) (ELit (LString "R-UNBOUND")))
(DFunDef false "resErrorCode" ((PCon "UnknownConstructor" PWild PWild PWild)) (ELit (LString "R-UNKNOWN-CTOR")))
(DFunDef false "resErrorCode" ((PCon "UnknownType" PWild PWild PWild)) (ELit (LString "R-UNKNOWN-TYPE")))
(DFunDef false "resErrorCode" ((PCon "UnknownEffect" PWild PWild)) (ELit (LString "R-UNKNOWN-EFFECT")))
(DFunDef false "resErrorCode" ((PCon "UnknownField" PWild PWild)) (ELit (LString "R-UNKNOWN-FIELD")))
(DFunDef false "resErrorCode" ((PCon "FieldNotInRecord" PWild PWild PWild)) (ELit (LString "R-FIELD-NOT-IN-RECORD")))
(DFunDef false "resErrorCode" ((PCon "DuplicateDefinition" PWild PWild PWild)) (ELit (LString "R-DUPLICATE-DEF")))
(DFunDef false "resErrorCode" ((PCon "UnknownInterface" PWild PWild)) (ELit (LString "R-UNKNOWN-INTERFACE")))
(DFunDef false "resErrorCode" ((PCon "MethodNotInInterface" PWild PWild PWild)) (ELit (LString "R-METHOD-NOT-IN-INTERFACE")))
(DFunDef false "resErrorCode" ((PCon "ExternWithBody" PWild PWild)) (ELit (LString "R-EXTERN-WITH-BODY")))
(DFunDef false "resErrorCode" ((PCon "PrivateNameAccess" PWild PWild PWild)) (ELit (LString "R-PRIVATE-NAME")))
(DFunDef false "resErrorCode" ((PCon "NoExportedConstructors" PWild PWild PWild)) (ELit (LString "R-NO-EXPORTED-CTORS")))
(DFunDef false "resErrorCode" ((PCon "NewtypeCtorNotExported" PWild PWild PWild)) (ELit (LString "R-NEWTYPE-CTOR-PRIVATE")))
(DFunDef false "resErrorCode" ((PCon "AbstractFieldAccess" PWild PWild PWild)) (ELit (LString "R-ABSTRACT-FIELD")))
(DFunDef false "resErrorCode" ((PCon "UnknownModule" PWild PWild)) (ELit (LString "R-UNKNOWN-MODULE")))
(DFunDef false "resErrorCode" ((PCon "NonRecursiveValueLet" PWild PWild)) (ELit (LString "R-NONREC-VALUE-LET")))
(DFunDef false "resErrorCode" ((PCon "DuplicateBinding" PWild PWild)) (ELit (LString "R-DUPLICATE-BINDING")))
(DFunDef false "resErrorCode" ((PCon "DuplicateValueBinding" PWild PWild)) (ELit (LString "R-DUP-BINDING")))
(DFunDef false "resErrorCode" ((PCon "DuplicateSignature" PWild PWild PWild)) (ELit (LString "R-DUPLICATE-SIGNATURE")))
(DFunDef false "resErrorCode" ((PCon "DuplicateBinder" PWild PWild PWild)) (ELit (LString "R-DUP-BINDER")))
(DFunDef false "resErrorCode" ((PCon "AsPatternMisplaced" PWild)) (ELit (LString "R-AS-PATTERN-MISPLACED")))
(DFunDef false "resErrorCode" ((PCon "AmbiguousOccurrence" PWild PWild PWild)) (ELit (LString "R-AMBIGUOUS-OCCURRENCE")))
(DFunDef false "resErrorCode" ((PCon "AmbiguousConstructor" PWild PWild PWild)) (ELit (LString "R-AMBIGUOUS-CTOR")))
(DFunDef false "resErrorCode" ((PCon "AmbiguousType" PWild PWild PWild)) (ELit (LString "R-AMBIGUOUS-TYPE")))
(DFunDef false "resErrorCode" ((PCon "AmbiguousInterface" PWild PWild PWild)) (ELit (LString "R-AMBIGUOUS-INTERFACE")))
(DFunDef false "resErrorCode" ((PCon "InternalExternAccess" PWild PWild)) (ELit (LString "R-INTERNAL-EXTERN")))
(DFunDef false "resErrorCode" ((PCon "ReassignImmutable" PWild PWild)) (ELit (LString "R-IMMUTABLE-ASSIGN")))
(DFunDef false "resErrorCode" ((PCon "DuplicateInterfaceMethod" PWild PWild PWild PWild)) (ELit (LString "R-DUPLICATE-IFACE-METHOD")))
(DTypeSig false "ambigModPhrase" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "ambigModPhrase" ((PCons (PVar "a") (PCons (PVar "b") (PList)))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "both `")) (EApp (EVar "display") (EVar "a"))) (ELit (LString "` and `"))) (EApp (EVar "display") (EVar "b"))) (ELit (LString "`"))))
(DFunDef false "ambigModPhrase" ((PVar "mods")) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "map") (ELam ((PVar "m")) (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EVar "m")) (ELit (LString "`"))))) (EVar "mods"))))
(DTypeSig true "resolveToLines" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "String")))))
(DFunDef false "resolveToLines" ((PVar "runtimeDecls") (PVar "preludeDecls") (PVar "prog")) (EApp (EVar "joinNl") (EApp (EApp (EVar "map") (EVar "ppResError")) (EApp (EApp (EApp (EVar "resolveProgram") (EVar "runtimeDecls")) (EVar "preludeDecls")) (EVar "prog")))))
(DTypeSig true "singleFileImportErrors" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "ResError"))))
(DFunDef false "singleFileImportErrors" ((PList)) (EListLit))
(DFunDef false "singleFileImportErrors" ((PCons (PCon "DUse" PWild (PVar "path") PWild) (PVar "rest"))) (EBlock (DoLet false false (PVar "mid") (EApp (EVar "useModId") (EVar "path"))) (DoExpr (EIf (EBinOp "||" (EBinOp "==" (EVar "mid") (ELit (LString "core"))) (EBinOp "==" (EVar "mid") (ELit (LString "")))) (EApp (EVar "singleFileImportErrors") (EVar "rest")) (EBinOp "::" (EApp (EApp (EVar "UnknownModule") (EVar "mid")) (EVar "None")) (EApp (EVar "singleFileImportErrors") (EVar "rest")))))))
(DFunDef false "singleFileImportErrors" ((PCons PWild (PVar "rest"))) (EApp (EVar "singleFileImportErrors") (EVar "rest")))
(DData Public "ModuleExports" () ((variant "ModuleExports" (ConNamed (field "modId" (TyCon "String")) (field "expValues" (TyApp (TyCon "List") (TyCon "String"))) (field "expTypes" (TyApp (TyCon "List") (TyCon "String"))) (field "expCtors" (TyApp (TyCon "List") (TyCon "String"))) (field "expTypeCtors" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))) (field "expFieldOwners" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (field "expInterfaces" (TyApp (TyCon "List") (TyCon "String"))) (field "expIfaceMethods" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))) (field "expEffects" (TyApp (TyCon "List") (TyCon "String"))) (field "expNewtypeCtors" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))) ())
(DTypeSig false "filterContains" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "filterContains" (PWild (PList)) (EListLit))
(DFunDef false "filterContains" ((PVar "domain") (PCons (PVar "n") (PVar "rest"))) (EIf (EApp (EApp (EVar "contains") (EVar "n")) (EVar "domain")) (EBinOp "::" (EVar "n") (EApp (EApp (EVar "filterContains") (EVar "domain")) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "filterContains") (EVar "domain")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "filterInSet" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "filterInSet" (PWild (PList)) (EListLit))
(DFunDef false "filterInSet" ((PVar "domain") (PCons (PVar "n") (PVar "rest"))) (EIf (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "domain")) (EBinOp "::" (EVar "n") (EApp (EApp (EVar "filterInSet") (EVar "domain")) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "filterInSet") (EVar "domain")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "findExports" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyApp (TyCon "Option") (TyCon "ModuleExports")))))
(DFunDef false "findExports" ((PVar "mid") (PVar "known")) (EApp (EApp (EVar "omLookup") (EVar "mid")) (EVar "known")))
(DTypeSig false "isPubExp" (TyFun (TyCon "ModuleExports") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "isPubExp" ((PVar "exp") (PVar "n")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EApp (EApp (EVar "contains") (EVar "n")) (EFieldAccess (EVar "exp") "expValues")) (EApp (EApp (EVar "contains") (EVar "n")) (EFieldAccess (EVar "exp") "expTypes"))) (EApp (EApp (EVar "contains") (EVar "n")) (EFieldAccess (EVar "exp") "expCtors"))) (EApp (EApp (EVar "contains") (EVar "n")) (EFieldAccess (EVar "exp") "expInterfaces"))))
(DTypeSig false "typeCtorsOf" (TyFun (TyCon "String") (TyFun (TyCon "ModuleExports") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "typeCtorsOf" ((PVar "name") (PVar "exp")) (EApp (EApp (EVar "lookupAssoc") (EVar "name")) (EFieldAccess (EVar "exp") "expTypeCtors")))
(DTypeSig false "newtypeTypeOfCtor" (TyFun (TyCon "String") (TyFun (TyCon "ModuleExports") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "newtypeTypeOfCtor" ((PVar "name") (PVar "exp")) (EApp (EApp (EVar "lookupAssoc") (EVar "name")) (EFieldAccess (EVar "exp") "expNewtypeCtors")))
(DTypeSig false "isNewtypeExport" (TyFun (TyCon "String") (TyFun (TyCon "ModuleExports") (TyCon "Bool"))))
(DFunDef false "isNewtypeExport" ((PVar "name") (PVar "exp")) (EApp (EApp (EVar "contains") (EVar "name")) (EApp (EApp (EVar "map") (EVar "snd")) (EFieldAccess (EVar "exp") "expNewtypeCtors"))))
(DTypeSig false "usePathsOf" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "UsePath"))))
(DFunDef false "usePathsOf" ((PList)) (EListLit))
(DFunDef false "usePathsOf" ((PCons (PCon "DUse" PWild (PVar "path") PWild) (PVar "rest"))) (EBinOp "::" (EVar "path") (EApp (EVar "usePathsOf") (EVar "rest"))))
(DFunDef false "usePathsOf" ((PCons PWild (PVar "rest"))) (EApp (EVar "usePathsOf") (EVar "rest")))
(DTypeSig false "usePathLocsOf" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "UsePath") (TyCon "Loc")))))
(DFunDef false "usePathLocsOf" ((PList)) (EListLit))
(DFunDef false "usePathLocsOf" ((PCons (PCon "DUse" PWild (PVar "path") (PVar "loc")) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "path") (EVar "loc")) (EApp (EVar "usePathLocsOf") (EVar "rest"))))
(DFunDef false "usePathLocsOf" ((PCons PWild (PVar "rest"))) (EApp (EVar "usePathLocsOf") (EVar "rest")))
(DTypeSig false "pubUsePaths" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "UsePath"))))
(DFunDef false "pubUsePaths" ((PList)) (EListLit))
(DFunDef false "pubUsePaths" ((PCons (PCon "DUse" (PCon "True") (PVar "path") PWild) (PVar "rest"))) (EBinOp "::" (EVar "path") (EApp (EVar "pubUsePaths") (EVar "rest"))))
(DFunDef false "pubUsePaths" ((PCons PWild (PVar "rest"))) (EApp (EVar "pubUsePaths") (EVar "rest")))
(DTypeSig false "importedNamesMM" (TyFun (TyCon "UsePath") (TyFun (TyCon "ModuleExports") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "importedNamesMM" ((PCon "UseName" (PVar "ns")) (PVar "exp")) (EIf (EBinOp ">" (EApp (EVar "listLen") (EVar "ns")) (ELit (LInt 1))) (EBlock (DoLet false false (PVar "nm") (EApp (EVar "lastOf") (EVar "ns"))) (DoExpr (ETuple (EListLit (EVar "nm")) (EApp (EApp (EVar "pubErr") (EVar "exp")) (EVar "nm"))))) (ETuple (EListLit) (EListLit))))
(DFunDef false "importedNamesMM" ((PCon "UseGroup" PWild (PVar "members")) (PVar "exp")) (EBlock (DoLet false false (PVar "expanded") (EApp (EApp (EVar "flatMap") (EApp (EVar "expandMemberNames") (EVar "exp"))) (EVar "members"))) (DoLet false false (PVar "names") (EApp (EApp (EVar "map") (EVar "localOfExpanded")) (EVar "expanded"))) (DoLet false false (PVar "expandErrs") (EApp (EApp (EVar "flatMap") (EApp (EVar "expandMemberErrs") (EVar "exp"))) (EVar "members"))) (DoExpr (ETuple (EVar "names") (EBinOp "++" (EVar "expandErrs") (EApp (EApp (EVar "flatMap") (EApp (EVar "pubErrExpanded") (EVar "exp"))) (EVar "expanded")))))))
(DFunDef false "importedNamesMM" ((PCon "UseWild" PWild) (PVar "exp")) (ETuple (EBinOp "++" (EBinOp "++" (EFieldAccess (EVar "exp") "expValues") (EFieldAccess (EVar "exp") "expTypes")) (EApp (EApp (EVar "filterList") (ELam ((PVar "c")) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EVar "c")) (EApp (EApp (EVar "map") (EVar "fst")) (EFieldAccess (EVar "exp") "expNewtypeCtors")))))) (EFieldAccess (EVar "exp") "expCtors"))) (EListLit)))
(DFunDef false "importedNamesMM" ((PCon "UseAlias" PWild (PVar "a")) (PVar "exp")) (ETuple (EApp (EApp (EVar "map") (EApp (EVar "qualifiedLocal") (EVar "a"))) (EFieldAccess (EVar "exp") "expValues")) (EListLit)))
(DTypeSig false "pubErr" (TyFun (TyCon "ModuleExports") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "ResError")))))
(DFunDef false "pubErr" ((PVar "exp") (PVar "n")) (EIf (EApp (EApp (EVar "isPubExp") (EVar "exp")) (EVar "n")) (EListLit) (EListLit (EApp (EApp (EApp (EVar "PrivateNameAccess") (EVar "n")) (EFieldAccess (EVar "exp") "modId")) (EVar "None")))))
(DTypeSig false "pubErrLoc" (TyFun (TyCon "ModuleExports") (TyFun (TyTuple (TyCon "String") (TyCon "Loc")) (TyApp (TyCon "List") (TyCon "ResError")))))
(DFunDef false "pubErrLoc" ((PVar "exp") (PTuple (PVar "n") (PVar "loc"))) (EIf (EApp (EApp (EVar "isPubExp") (EVar "exp")) (EVar "n")) (EListLit) (EListLit (EApp (EApp (EApp (EVar "PrivateNameAccess") (EVar "n")) (EFieldAccess (EVar "exp") "modId")) (EApp (EVar "Some") (EVar "loc"))))))
(DTypeSig false "expandMemberNames" (TyFun (TyCon "ModuleExports") (TyFun (TyCon "UseMember") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Loc"))))))
(DFunDef false "expandMemberNames" ((PVar "exp") (PAs "m" (PCon "UseMember" (PVar "name") (PCon "False") (PVar "loc") PWild))) (EMatch (EApp (EApp (EVar "newtypeTypeOfCtor") (EVar "name")) (EVar "exp")) (arm (PCon "Some" PWild) () (EListLit)) (arm (PCon "None") () (EListLit (ETuple (EVar "name") (EApp (EVar "useMemberLocal") (EVar "m")) (EVar "loc"))))))
(DFunDef false "expandMemberNames" ((PVar "exp") (PAs "m" (PCon "UseMember" (PVar "name") (PCon "True") (PVar "loc") PWild))) (EIf (EApp (EApp (EVar "isNewtypeExport") (EVar "name")) (EVar "exp")) (EListLit (ETuple (EVar "name") (EApp (EVar "useMemberLocal") (EVar "m")) (EVar "loc"))) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "typeCtorsOf") (EVar "name")) (EVar "exp")) (arm (PCon "Some" (PVar "ctors")) () (EBinOp "::" (ETuple (EVar "name") (EApp (EVar "useMemberLocal") (EVar "m")) (EVar "loc")) (EApp (EApp (EVar "map") (ELam ((PVar "c")) (ETuple (EVar "c") (EVar "c") (EVar "loc")))) (EVar "ctors")))) (arm (PCon "None") () (EListLit (ETuple (EVar "name") (EApp (EVar "useMemberLocal") (EVar "m")) (EVar "loc"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "localOfExpanded" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyCon "Loc")) (TyCon "String")))
(DFunDef false "localOfExpanded" ((PTuple PWild (PVar "local") PWild)) (EVar "local"))
(DTypeSig false "pubErrExpanded" (TyFun (TyCon "ModuleExports") (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyCon "Loc")) (TyApp (TyCon "List") (TyCon "ResError")))))
(DFunDef false "pubErrExpanded" ((PVar "exp") (PTuple (PVar "origin") PWild (PVar "loc"))) (EApp (EApp (EVar "pubErrLoc") (EVar "exp")) (ETuple (EVar "origin") (EVar "loc"))))
(DTypeSig false "expandMemberErrs" (TyFun (TyCon "ModuleExports") (TyFun (TyCon "UseMember") (TyApp (TyCon "List") (TyCon "ResError")))))
(DFunDef false "expandMemberErrs" ((PVar "exp") (PCon "UseMember" (PVar "name") (PCon "False") (PVar "loc") PWild)) (EMatch (EApp (EApp (EVar "newtypeTypeOfCtor") (EVar "name")) (EVar "exp")) (arm (PCon "Some" (PVar "tyName")) () (EListLit (EApp (EApp (EApp (EVar "NewtypeCtorNotExported") (EVar "tyName")) (EFieldAccess (EVar "exp") "modId")) (EApp (EVar "Some") (EVar "loc"))))) (arm (PCon "None") () (EListLit))))
(DFunDef false "expandMemberErrs" ((PVar "exp") (PCon "UseMember" (PVar "name") (PCon "True") (PVar "loc") PWild)) (EIf (EApp (EApp (EVar "isNewtypeExport") (EVar "name")) (EVar "exp")) (EListLit (EApp (EApp (EApp (EVar "NewtypeCtorNotExported") (EVar "name")) (EFieldAccess (EVar "exp") "modId")) (EApp (EVar "Some") (EVar "loc")))) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "typeCtorsOf") (EVar "name")) (EVar "exp")) (arm (PCon "Some" PWild) () (EListLit)) (arm (PCon "None") () (EIf (EApp (EApp (EVar "contains") (EVar "name")) (EFieldAccess (EVar "exp") "expTypes")) (EListLit (EApp (EApp (EApp (EVar "NoExportedConstructors") (EVar "name")) (EFieldAccess (EVar "exp") "modId")) (EApp (EVar "Some") (EVar "loc")))) (EListLit)))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DData Public "ImportAdds" () ((variant "ImportAdds" (ConNamed (field "iaImported" (TyApp (TyCon "List") (TyCon "String"))) (field "iaValues" (TyApp (TyCon "List") (TyCon "String"))) (field "iaTypes" (TyApp (TyCon "List") (TyCon "String"))) (field "iaCtors" (TyApp (TyCon "List") (TyCon "String"))) (field "iaIfaces" (TyApp (TyCon "List") (TyCon "String"))) (field "iaFieldOwners" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (field "iaErrors" (TyApp (TyCon "List") (TyCon "ResError")))))) ())
(DTypeSig false "emptyAdds" (TyCon "ImportAdds"))
(DFunDef false "emptyAdds" () (ERecordCreate "ImportAdds" ((fa "iaImported" (EListLit)) (fa "iaValues" (EListLit)) (fa "iaTypes" (EListLit)) (fa "iaCtors" (EListLit)) (fa "iaIfaces" (EListLit)) (fa "iaFieldOwners" (EListLit)) (fa "iaErrors" (EListLit)))))
(DTypeSig false "mergeAdds" (TyFun (TyCon "ImportAdds") (TyFun (TyCon "ImportAdds") (TyCon "ImportAdds"))))
(DFunDef false "mergeAdds" ((PVar "a") (PVar "b")) (ERecordCreate "ImportAdds" ((fa "iaImported" (EBinOp "++" (EFieldAccess (EVar "a") "iaImported") (EFieldAccess (EVar "b") "iaImported"))) (fa "iaValues" (EBinOp "++" (EFieldAccess (EVar "a") "iaValues") (EFieldAccess (EVar "b") "iaValues"))) (fa "iaTypes" (EBinOp "++" (EFieldAccess (EVar "a") "iaTypes") (EFieldAccess (EVar "b") "iaTypes"))) (fa "iaCtors" (EBinOp "++" (EFieldAccess (EVar "a") "iaCtors") (EFieldAccess (EVar "b") "iaCtors"))) (fa "iaIfaces" (EBinOp "++" (EFieldAccess (EVar "a") "iaIfaces") (EFieldAccess (EVar "b") "iaIfaces"))) (fa "iaFieldOwners" (EBinOp "++" (EFieldAccess (EVar "a") "iaFieldOwners") (EFieldAccess (EVar "b") "iaFieldOwners"))) (fa "iaErrors" (EBinOp "++" (EFieldAccess (EVar "a") "iaErrors") (EFieldAccess (EVar "b") "iaErrors"))))))
(DTypeSig false "collectImports" (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "ImportAdds"))))
(DFunDef false "collectImports" ((PVar "known") (PVar "prog")) (EApp (EApp (EVar "foldImports") (EVar "known")) (EApp (EVar "usePathLocsOf") (EVar "prog"))))
(DTypeSig false "importValueNames" (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyCon "UsePath") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "importValueNames" ((PVar "known") (PVar "path")) (EIf (EBinOp "==" (EApp (EVar "useModId") (EVar "path")) (ELit (LString "core"))) (EListLit) (EMatch (EApp (EApp (EVar "findExports") (EApp (EVar "useModId") (EVar "path"))) (EVar "known")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "exp")) () (EBlock (DoLet false false (PTuple (PVar "names") PWild) (EApp (EApp (EVar "importedNamesMM") (EVar "path")) (EVar "exp"))) (DoExpr (EApp (EApp (EVar "filterInSet") (EApp (EApp (EVar "omFromNames") (EFieldAccess (EVar "exp") "expValues")) (EVar "omEmpty"))) (EVar "names"))))))))
(DTypeSig false "addProvenance" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "addProvenance" ((PVar "prov") (PVar "n") (PVar "mid")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "prov")) (arm (PCon "None") () (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (EListLit (EVar "mid"))) (EVar "prov"))) (arm (PCon "Some" (PVar "mids")) () (EIf (EApp (EApp (EVar "contains") (EVar "mid")) (EVar "mids")) (EVar "prov") (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (EBinOp "++" (EVar "mids") (EListLit (EVar "mid")))) (EVar "prov"))))))
(DTypeSig false "addImportProvenance" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "addImportProvenance" ((PVar "prov") PWild (PList)) (EVar "prov"))
(DFunDef false "addImportProvenance" ((PVar "prov") (PVar "mid") (PCons (PVar "n") (PVar "rest"))) (EApp (EApp (EApp (EVar "addImportProvenance") (EApp (EApp (EApp (EVar "addProvenance") (EVar "prov")) (EVar "n")) (EVar "mid"))) (EVar "mid")) (EVar "rest")))
(DTypeSig false "valueProvenance" (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "List") (TyCon "UsePath")) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "valueProvenance" ((PVar "known") (PVar "paths")) (EApp (EApp (EApp (EVar "foldProvenance") (EVar "known")) (EVar "omEmpty")) (EVar "paths")))
(DTypeSig false "foldProvenance" (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "UsePath")) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "foldProvenance" (PWild (PVar "prov") (PList)) (EVar "prov"))
(DFunDef false "foldProvenance" ((PVar "known") (PVar "prov") (PCons (PVar "p") (PVar "rest"))) (EBlock (DoLet false false (PVar "mid") (EApp (EVar "useModId") (EVar "p"))) (DoLet false false (PVar "prov2") (EIf (EBinOp "==" (EVar "mid") (ELit (LString "core"))) (EVar "prov") (EApp (EApp (EApp (EVar "addImportProvenance") (EVar "prov")) (EVar "mid")) (EApp (EApp (EVar "importValueNames") (EVar "known")) (EVar "p"))))) (DoExpr (EApp (EApp (EApp (EVar "foldProvenance") (EVar "known")) (EVar "prov2")) (EVar "rest")))))
(DTypeSig false "provToPairs" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "provToPairs" ((PVar "prov")) (EApp (EApp (EVar "map") (ELam ((PVar "k")) (ETuple (EVar "k") (EApp (EApp (EVar "provMidsOf") (EVar "k")) (EVar "prov"))))) (EApp (EVar "omKeys") (EVar "prov"))))
(DTypeSig false "provMidsOf" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "provMidsOf" ((PVar "k") (PVar "prov")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "k")) (EVar "prov")) (arm (PCon "Some" (PVar "mids")) () (EVar "mids")) (arm (PCon "None") () (EListLit))))
(DTypeSig false "ambiguousSet" (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "ambiguousSet" ((PVar "known") (PVar "prog")) (EBlock (DoLet false false (PVar "prov") (EApp (EApp (EVar "valueProvenance") (EVar "known")) (EApp (EVar "usePathsOf") (EVar "prog")))) (DoLet false false (PVar "sameMod") (EApp (EVar "userValueNames") (EVar "prog"))) (DoExpr (EApp (EApp (EVar "keepAmbiguous") (EVar "sameMod")) (EApp (EVar "provToPairs") (EVar "prov"))))))
(DTypeSig false "keepAmbiguous" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "keepAmbiguous" (PWild (PList)) (EListLit))
(DFunDef false "keepAmbiguous" ((PVar "sameMod") (PCons (PTuple (PVar "n") (PVar "mids")) (PVar "rest"))) (EIf (EBinOp "&&" (EBinOp ">=" (EApp (EVar "listLen") (EVar "mids")) (ELit (LInt 2))) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EVar "n")) (EVar "sameMod")))) (EBinOp "::" (ETuple (EVar "n") (EVar "mids")) (EApp (EApp (EVar "keepAmbiguous") (EVar "sameMod")) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "keepAmbiguous") (EVar "sameMod")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "importCtorNames" (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyCon "UsePath") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "importCtorNames" ((PVar "known") (PVar "path")) (EIf (EBinOp "==" (EApp (EVar "useModId") (EVar "path")) (ELit (LString "core"))) (EListLit) (EMatch (EApp (EApp (EVar "findExports") (EApp (EVar "useModId") (EVar "path"))) (EVar "known")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "exp")) () (EBlock (DoLet false false (PTuple (PVar "names") PWild) (EApp (EApp (EVar "importedNamesMM") (EVar "path")) (EVar "exp"))) (DoExpr (EApp (EApp (EVar "filterInSet") (EApp (EApp (EVar "omFromNames") (EFieldAccess (EVar "exp") "expCtors")) (EVar "omEmpty"))) (EVar "names"))))))))
(DTypeSig false "ctorProvenance" (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "List") (TyCon "UsePath")) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "ctorProvenance" ((PVar "known") (PVar "paths")) (EApp (EApp (EApp (EVar "foldCtorProvenance") (EVar "known")) (EVar "omEmpty")) (EVar "paths")))
(DTypeSig false "foldCtorProvenance" (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "UsePath")) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "foldCtorProvenance" (PWild (PVar "prov") (PList)) (EVar "prov"))
(DFunDef false "foldCtorProvenance" ((PVar "known") (PVar "prov") (PCons (PVar "p") (PVar "rest"))) (EBlock (DoLet false false (PVar "mid") (EApp (EVar "useModId") (EVar "p"))) (DoLet false false (PVar "prov2") (EIf (EBinOp "==" (EVar "mid") (ELit (LString "core"))) (EVar "prov") (EApp (EApp (EApp (EVar "addImportProvenance") (EVar "prov")) (EVar "mid")) (EApp (EApp (EVar "importCtorNames") (EVar "known")) (EVar "p"))))) (DoExpr (EApp (EApp (EApp (EVar "foldCtorProvenance") (EVar "known")) (EVar "prov2")) (EVar "rest")))))
(DTypeSig false "ctorAmbiguousSet" (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "ctorAmbiguousSet" ((PVar "known") (PVar "prog")) (EBlock (DoLet false false (PVar "prov") (EApp (EApp (EVar "ctorProvenance") (EVar "known")) (EApp (EVar "usePathsOf") (EVar "prog")))) (DoLet false false (PVar "sameMod") (EApp (EVar "ctorNames") (EVar "prog"))) (DoExpr (EApp (EApp (EVar "keepAmbiguous") (EVar "sameMod")) (EApp (EVar "provToPairs") (EVar "prov"))))))
(DTypeSig false "importTypeNames" (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyCon "UsePath") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "importTypeNames" ((PVar "known") (PVar "path")) (EApp (EApp (EApp (EVar "importNamesIn") (EVar "expTypesOf")) (EVar "known")) (EVar "path")))
(DTypeSig false "importIfaceNames" (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyCon "UsePath") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "importIfaceNames" ((PVar "known") (PVar "path")) (EApp (EApp (EApp (EVar "importNamesIn") (EVar "expInterfacesOf")) (EVar "known")) (EVar "path")))
(DTypeSig false "expTypesOf" (TyFun (TyCon "ModuleExports") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "expTypesOf" ((PVar "exp")) (EFieldAccess (EVar "exp") "expTypes"))
(DTypeSig false "expInterfacesOf" (TyFun (TyCon "ModuleExports") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "expInterfacesOf" ((PVar "exp")) (EFieldAccess (EVar "exp") "expInterfaces"))
(DTypeSig false "importNamesIn" (TyFun (TyFun (TyCon "ModuleExports") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyCon "UsePath") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "importNamesIn" ((PVar "nsOf") (PVar "known") (PVar "path")) (EIf (EBinOp "==" (EApp (EVar "useModId") (EVar "path")) (ELit (LString "core"))) (EListLit) (EMatch (EApp (EApp (EVar "findExports") (EApp (EVar "useModId") (EVar "path"))) (EVar "known")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "exp")) () (EBlock (DoLet false false (PTuple (PVar "names") PWild) (EApp (EApp (EVar "importedNamesMM") (EVar "path")) (EVar "exp"))) (DoExpr (EApp (EApp (EVar "filterInSet") (EApp (EApp (EVar "omFromNames") (EApp (EVar "nsOf") (EVar "exp"))) (EVar "omEmpty"))) (EVar "names"))))))))
(DTypeSig false "foldNamespaceProvenance" (TyFun (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyCon "UsePath") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "UsePath")) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "foldNamespaceProvenance" (PWild PWild (PVar "prov") (PList)) (EVar "prov"))
(DFunDef false "foldNamespaceProvenance" ((PVar "namesOf") (PVar "known") (PVar "prov") (PCons (PVar "p") (PVar "rest"))) (EBlock (DoLet false false (PVar "mid") (EApp (EVar "useModId") (EVar "p"))) (DoLet false false (PVar "prov2") (EIf (EBinOp "==" (EVar "mid") (ELit (LString "core"))) (EVar "prov") (EApp (EApp (EApp (EVar "addImportProvenance") (EVar "prov")) (EVar "mid")) (EApp (EApp (EVar "namesOf") (EVar "known")) (EVar "p"))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "foldNamespaceProvenance") (EVar "namesOf")) (EVar "known")) (EVar "prov2")) (EVar "rest")))))
(DTypeSig false "typeAmbiguousSet" (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "typeAmbiguousSet" ((PVar "known") (PVar "prog")) (EBlock (DoLet false false (PVar "prov") (EApp (EApp (EApp (EApp (EVar "foldNamespaceProvenance") (EVar "importTypeNames")) (EVar "known")) (EVar "omEmpty")) (EApp (EVar "usePathsOf") (EVar "prog")))) (DoExpr (EApp (EApp (EVar "keepAmbiguous") (EApp (EVar "dataRecordNames") (EVar "prog"))) (EApp (EVar "provToPairs") (EVar "prov"))))))
(DTypeSig false "ifaceAmbiguousSet" (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "ifaceAmbiguousSet" ((PVar "known") (PVar "prog")) (EBlock (DoLet false false (PVar "prov") (EApp (EApp (EApp (EApp (EVar "foldNamespaceProvenance") (EVar "importIfaceNames")) (EVar "known")) (EVar "omEmpty")) (EApp (EVar "usePathsOf") (EVar "prog")))) (DoExpr (EApp (EApp (EVar "keepAmbiguous") (EApp (EVar "interfaceNamesOf") (EVar "prog"))) (EApp (EVar "provToPairs") (EVar "prov"))))))
(DTypeSig false "foldImports" (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "UsePath") (TyCon "Loc"))) (TyCon "ImportAdds"))))
(DFunDef false "foldImports" (PWild (PList)) (EVar "emptyAdds"))
(DFunDef false "foldImports" ((PVar "known") (PCons (PTuple (PVar "p") (PVar "loc")) (PVar "rest"))) (EApp (EApp (EVar "mergeAdds") (EApp (EApp (EApp (EVar "oneImport") (EVar "known")) (EVar "p")) (EVar "loc"))) (EApp (EApp (EVar "foldImports") (EVar "known")) (EVar "rest"))))
(DTypeSig false "oneImport" (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyCon "UsePath") (TyFun (TyCon "Loc") (TyCon "ImportAdds")))))
(DFunDef false "oneImport" ((PVar "known") (PVar "path") (PVar "loc")) (EBlock (DoLet false false (PVar "mid") (EApp (EVar "useModId") (EVar "path"))) (DoExpr (EIf (EBinOp "==" (EVar "mid") (ELit (LString "core"))) (EVar "emptyAdds") (EMatch (EApp (EApp (EVar "findExports") (EVar "mid")) (EVar "known")) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "stubOrUnknown") (EVar "known")) (EVar "path")) (EVar "mid")) (EVar "loc"))) (arm (PCon "Some" (PVar "exp")) () (EApp (EApp (EApp (EVar "realImport") (EVar "exp")) (EVar "path")) (EVar "loc"))))))))
(DTypeSig false "stubOrUnknown" (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyCon "UsePath") (TyFun (TyCon "String") (TyFun (TyCon "Loc") (TyCon "ImportAdds"))))))
(DFunDef false "stubOrUnknown" ((PVar "known") (PVar "path") (PVar "mid") (PVar "loc")) (EIf (EBinOp ">" (EApp (EVar "omSize") (EVar "known")) (ELit (LInt 0))) (ERecordCreate "ImportAdds" ((fa "iaImported" (EListLit)) (fa "iaValues" (EListLit)) (fa "iaTypes" (EListLit)) (fa "iaCtors" (EListLit)) (fa "iaIfaces" (EListLit)) (fa "iaFieldOwners" (EListLit)) (fa "iaErrors" (EListLit (EApp (EApp (EVar "UnknownModule") (EVar "mid")) (EApp (EVar "Some") (EVar "loc"))))))) (EBlock (DoLet false false (PVar "names") (EApp (EVar "useStubNames") (EVar "path"))) (DoExpr (ERecordCreate "ImportAdds" ((fa "iaImported" (EVar "names")) (fa "iaValues" (EVar "names")) (fa "iaTypes" (EVar "names")) (fa "iaCtors" (EListLit)) (fa "iaIfaces" (EListLit)) (fa "iaFieldOwners" (EListLit)) (fa "iaErrors" (EListLit))))))))
(DTypeSig false "realImport" (TyFun (TyCon "ModuleExports") (TyFun (TyCon "UsePath") (TyFun (TyCon "Loc") (TyCon "ImportAdds")))))
(DFunDef false "realImport" ((PVar "exp") (PVar "path") (PVar "loc")) (EBlock (DoLet false false (PTuple (PVar "names") (PVar "errs")) (EApp (EApp (EVar "importedNamesMM") (EVar "path")) (EVar "exp"))) (DoExpr (ERecordCreate "ImportAdds" ((fa "iaImported" (EVar "names")) (fa "iaValues" (EApp (EApp (EVar "filterInSet") (EApp (EApp (EVar "omFromNames") (EFieldAccess (EVar "exp") "expValues")) (EVar "omEmpty"))) (EVar "names"))) (fa "iaTypes" (EApp (EApp (EVar "filterContains") (EFieldAccess (EVar "exp") "expTypes")) (EVar "names"))) (fa "iaCtors" (EApp (EApp (EVar "filterContains") (EFieldAccess (EVar "exp") "expCtors")) (EVar "names"))) (fa "iaIfaces" (EApp (EApp (EVar "filterContains") (EFieldAccess (EVar "exp") "expInterfaces")) (EVar "names"))) (fa "iaFieldOwners" (EApp (EApp (EVar "ownedFieldOwners") (EVar "exp")) (EFieldAccess (EVar "exp") "expFieldOwners"))) (fa "iaErrors" (EApp (EApp (EVar "map") (EApp (EVar "withResErrorLoc") (EVar "loc"))) (EVar "errs"))))))))
(DTypeSig false "withResErrorLoc" (TyFun (TyCon "Loc") (TyFun (TyCon "ResError") (TyCon "ResError"))))
(DFunDef false "withResErrorLoc" ((PVar "loc") (PCon "PrivateNameAccess" (PVar "n") (PVar "m") (PCon "None"))) (EApp (EApp (EApp (EVar "PrivateNameAccess") (EVar "n")) (EVar "m")) (EApp (EVar "Some") (EVar "loc"))))
(DFunDef false "withResErrorLoc" (PWild (PCon "PrivateNameAccess" (PVar "n") (PVar "m") (PCon "Some" (PVar "l")))) (EApp (EApp (EApp (EVar "PrivateNameAccess") (EVar "n")) (EVar "m")) (EApp (EVar "Some") (EVar "l"))))
(DFunDef false "withResErrorLoc" ((PVar "loc") (PCon "NoExportedConstructors" (PVar "n") (PVar "m") (PCon "None"))) (EApp (EApp (EApp (EVar "NoExportedConstructors") (EVar "n")) (EVar "m")) (EApp (EVar "Some") (EVar "loc"))))
(DFunDef false "withResErrorLoc" (PWild (PCon "NoExportedConstructors" (PVar "n") (PVar "m") (PCon "Some" (PVar "l")))) (EApp (EApp (EApp (EVar "NoExportedConstructors") (EVar "n")) (EVar "m")) (EApp (EVar "Some") (EVar "l"))))
(DFunDef false "withResErrorLoc" (PWild (PVar "e")) (EVar "e"))
(DTypeSig false "ownedFieldOwners" (TyFun (TyCon "ModuleExports") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "ownedFieldOwners" (PWild (PList)) (EListLit))
(DFunDef false "ownedFieldOwners" ((PVar "exp") (PCons (PTuple (PVar "f") (PVar "o")) (PVar "rest"))) (EIf (EBinOp "||" (EApp (EApp (EVar "contains") (EVar "o")) (EFieldAccess (EVar "exp") "expTypes")) (EApp (EApp (EVar "contains") (EVar "o")) (EFieldAccess (EVar "exp") "expCtors"))) (EBinOp "::" (ETuple (EVar "f") (EVar "o")) (EApp (EApp (EVar "ownedFieldOwners") (EVar "exp")) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "ownedFieldOwners") (EVar "exp")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "importedIfaceMethods" (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "importedIfaceMethods" ((PVar "known") (PVar "prog")) (EApp (EApp (EVar "flatMap") (EApp (EVar "oneImportIfaceMethods") (EVar "known"))) (EApp (EVar "usePathsOf") (EVar "prog"))))
(DTypeSig false "oneImportIfaceMethods" (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyCon "UsePath") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "oneImportIfaceMethods" ((PVar "known") (PVar "path")) (EBlock (DoLet false false (PVar "mid") (EApp (EVar "useModId") (EVar "path"))) (DoExpr (EIf (EBinOp "==" (EVar "mid") (ELit (LString "core"))) (EListLit) (EMatch (EApp (EApp (EVar "findExports") (EVar "mid")) (EVar "known")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "exp")) () (EApp (EApp (EVar "filterIfaceMethods") (EApp (EApp (EVar "importIfaceNames") (EVar "known")) (EVar "path"))) (EFieldAccess (EVar "exp") "expIfaceMethods"))))))))
(DTypeSig false "filterIfaceMethods" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "filterIfaceMethods" (PWild (PList)) (EListLit))
(DFunDef false "filterIfaceMethods" ((PVar "pathIfaces") (PCons (PTuple (PVar "iface") (PVar "ms")) (PVar "rest"))) (EIf (EApp (EApp (EVar "contains") (EVar "iface")) (EVar "pathIfaces")) (EBinOp "::" (ETuple (EVar "iface") (EVar "ms")) (EApp (EApp (EVar "filterIfaceMethods") (EVar "pathIfaces")) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "filterIfaceMethods") (EVar "pathIfaces")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "importedEffects" (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "importedEffects" ((PVar "known") (PVar "prog")) (EApp (EApp (EVar "flatMap") (EApp (EVar "oneImportEffects") (EVar "known"))) (EApp (EVar "usePathsOf") (EVar "prog"))))
(DTypeSig false "oneImportEffects" (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyCon "UsePath") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "oneImportEffects" ((PVar "known") (PVar "path")) (EBlock (DoLet false false (PVar "mid") (EApp (EVar "useModId") (EVar "path"))) (DoExpr (EIf (EBinOp "==" (EVar "mid") (ELit (LString "core"))) (EListLit) (EMatch (EApp (EApp (EVar "findExports") (EVar "mid")) (EVar "known")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "exp")) () (EFieldAccess (EVar "exp") "expEffects")))))))
(DTypeSig false "buildEnvMM" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyTuple (TyCon "Env") (TyApp (TyCon "List") (TyCon "ResError")))))))))
(DFunDef false "buildEnvMM" ((PVar "runtimeDecls") (PVar "preludeDecls") (PVar "known") (PVar "prog") (PVar "internalGuard")) (EBlock (DoLet false false (PVar "seed") (EApp (EVar "not") (EApp (EVar "programIsCore") (EVar "prog")))) (DoLet false false (PVar "pTypes") (EApp (EApp (EVar "whenL") (EVar "seed")) (EApp (EVar "dataRecordNames") (EVar "preludeDecls")))) (DoLet false false (PVar "pCtors") (EApp (EApp (EVar "whenL") (EVar "seed")) (EApp (EVar "ctorNames") (EVar "preludeDecls")))) (DoLet false false (PVar "pIfaces") (EApp (EApp (EVar "whenL") (EVar "seed")) (EApp (EVar "interfaceList") (EVar "preludeDecls")))) (DoLet false false (PVar "pValues") (EApp (EApp (EVar "whenL") (EVar "seed")) (EApp (EVar "preludeValueNames") (EVar "preludeDecls")))) (DoLet false false (PVar "pFieldOwners") (EApp (EApp (EVar "whenL") (EVar "seed")) (EApp (EVar "fieldOwnersOf") (EVar "preludeDecls")))) (DoLet false false (PVar "uIfaces") (EApp (EVar "interfaceList") (EVar "prog"))) (DoLet false false (PVar "adds") (EApp (EApp (EVar "collectImports") (EVar "known")) (EVar "prog"))) (DoLet false false (PVar "baseIfaces") (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "map") (EVar "fst")) (EVar "pIfaces")) (EApp (EApp (EVar "map") (EVar "fst")) (EVar "uIfaces"))) (EFieldAccess (EVar "adds") "iaIfaces"))) (DoLet false false (PVar "impIfaceMethods") (EApp (EApp (EVar "importedIfaceMethods") (EVar "known")) (EVar "prog"))) (DoLet false false (PVar "impEffects") (EApp (EApp (EVar "importedEffects") (EVar "known")) (EVar "prog"))) (DoLet false false (PVar "impModValues") (EApp (EApp (EVar "importedModuleValueSets") (EVar "known")) (EVar "prog"))) (DoLet false false (PVar "valuesM") (EApp (EApp (EVar "omFromNames") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EApp (EVar "externNames") (EVar "runtimeDecls")) (EVar "pValues")) (EApp (EVar "userValueNames") (EVar "prog"))) (EFieldAccess (EVar "adds") "iaValues"))) (EVar "omEmpty"))) (DoLet false false (PVar "typesM") (EApp (EApp (EVar "omFromNames") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EVar "primitiveTypes") (EVar "pTypes")) (EApp (EVar "dataRecordNames") (EVar "prog"))) (EFieldAccess (EVar "adds") "iaTypes"))) (EVar "omEmpty"))) (DoLet false false (PVar "ctorsM") (EApp (EApp (EVar "omFromNames") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EVar "primitiveConstructors") (EVar "pCtors")) (EApp (EVar "ctorNames") (EVar "prog"))) (EFieldAccess (EVar "adds") "iaCtors"))) (EVar "omEmpty"))) (DoLet false false (PVar "importedM") (EApp (EApp (EVar "omFromNames") (EFieldAccess (EVar "adds") "iaImported")) (EVar "omEmpty"))) (DoLet false false (PVar "env") (ERecordCreate "Env" ((fa "values" (EVar "valuesM")) (fa "types" (EVar "typesM")) (fa "ctors" (EVar "ctorsM")) (fa "fields" (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "map") (EVar "fst")) (EVar "pFieldOwners")) (EApp (EApp (EVar "map") (EVar "fst")) (EApp (EVar "fieldOwnersOf") (EVar "prog")))) (EApp (EApp (EVar "map") (EVar "fst")) (EFieldAccess (EVar "adds") "iaFieldOwners")))) (fa "fieldOwners" (EBinOp "++" (EBinOp "++" (EVar "pFieldOwners") (EApp (EVar "fieldOwnersOf") (EVar "prog"))) (EFieldAccess (EVar "adds") "iaFieldOwners"))) (fa "fieldOwnersIdx" (EApp (EVar "buildFieldOwnerIndex") (EBinOp "++" (EBinOp "++" (EVar "pFieldOwners") (EApp (EVar "fieldOwnersOf") (EVar "prog"))) (EFieldAccess (EVar "adds") "iaFieldOwners")))) (fa "interfaces" (EVar "baseIfaces")) (fa "ifaceMethods" (EBinOp "++" (EBinOp "++" (EVar "pIfaces") (EVar "uIfaces")) (EVar "impIfaceMethods"))) (fa "effects" (EBinOp "++" (EApp (EVar "effectNames") (EVar "prog")) (EVar "impEffects"))) (fa "imported" (EVar "importedM")) (fa "importedModuleValues" (EVar "impModValues")) (fa "ambiguous" (EApp (EApp (EVar "ambiguousSet") (EVar "known")) (EVar "prog"))) (fa "ctorAmbiguous" (EApp (EApp (EVar "ctorAmbiguousSet") (EVar "known")) (EVar "prog"))) (fa "typeAmbiguous" (EApp (EApp (EVar "typeAmbiguousSet") (EVar "known")) (EVar "prog"))) (fa "ifaceAmbiguous" (EApp (EApp (EVar "ifaceAmbiguousSet") (EVar "known")) (EVar "prog"))) (fa "internalGuard" (EApp (EApp (EVar "omFromNames") (EVar "internalGuard")) (EVar "omEmpty"))) (fa "sugValues" (EApp (EVar "sugPoolOf") (EBinOp "++" (EBinOp "++" (EApp (EVar "omKeys") (EVar "valuesM")) (EApp (EVar "omKeys") (EVar "ctorsM"))) (EApp (EVar "omKeys") (EVar "importedM"))))) (fa "sugTypes" (EApp (EVar "sugPoolOf") (EBinOp "++" (EApp (EVar "omKeys") (EVar "typesM")) (EApp (EVar "omKeys") (EVar "importedM")))))))) (DoExpr (ETuple (EVar "env") (EFieldAccess (EVar "adds") "iaErrors")))))
(DTypeSig false "importedModuleValueSets" (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "importedModuleValueSets" ((PVar "known") (PVar "prog")) (EApp (EApp (EVar "flatMap") (EApp (EVar "oneImportedModuleValues") (EVar "known"))) (EApp (EVar "usePathsOf") (EVar "prog"))))
(DTypeSig false "oneImportedModuleValues" (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyCon "UsePath") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "oneImportedModuleValues" ((PVar "known") (PVar "path")) (EBlock (DoLet false false (PVar "mid") (EApp (EVar "useModId") (EVar "path"))) (DoExpr (EIf (EBinOp "==" (EVar "mid") (ELit (LString "core"))) (EListLit) (EMatch (EApp (EApp (EVar "findExports") (EVar "mid")) (EVar "known")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "exp")) () (EListLit (ETuple (EVar "mid") (EFieldAccess (EVar "exp") "expValues")))))))))
(DTypeSig false "coreExports" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "ModuleExports")))
(DFunDef false "coreExports" ((PVar "preludeDecls")) (ERecordCreate "ModuleExports" ((fa "modId" (ELit (LString "core"))) (fa "expValues" (EApp (EVar "preludeValueNames") (EVar "preludeDecls"))) (fa "expTypes" (EApp (EVar "dataRecordNames") (EVar "preludeDecls"))) (fa "expCtors" (EApp (EVar "ctorNames") (EVar "preludeDecls"))) (fa "expTypeCtors" (EApp (EVar "typeCtorsAllOf") (EVar "preludeDecls"))) (fa "expFieldOwners" (EApp (EVar "fieldOwnersOf") (EVar "preludeDecls"))) (fa "expInterfaces" (EApp (EApp (EVar "map") (EVar "fst")) (EApp (EVar "interfaceList") (EVar "preludeDecls")))) (fa "expIfaceMethods" (EApp (EVar "interfaceList") (EVar "preludeDecls"))) (fa "expEffects" (EApp (EVar "effectNames") (EVar "preludeDecls"))) (fa "expNewtypeCtors" (EListLit)))))
(DTypeSig false "typeCtorsAllOf" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "typeCtorsAllOf" ((PList)) (EListLit))
(DFunDef false "typeCtorsAllOf" ((PCons (PRec "DNewtype" ((rf "newtypeName" (PVar "n")) (rf "newtypeCtor" (PVar "con"))) false) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "n") (EListLit (EVar "con"))) (EApp (EVar "typeCtorsAllOf") (EVar "rest"))))
(DFunDef false "typeCtorsAllOf" ((PCons (PRec "DData" ((rf "dataName" (PVar "n")) (rf "dataCtors" (PVar "vs"))) false) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "n") (EApp (EApp (EVar "map") (EVar "variantName")) (EVar "vs"))) (EApp (EVar "typeCtorsAllOf") (EVar "rest"))))
(DFunDef false "typeCtorsAllOf" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "typeCtorsAllOf") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "typeCtorsAllOf" ((PCons PWild (PVar "rest"))) (EApp (EVar "typeCtorsAllOf") (EVar "rest")))
(DTypeSig false "buildExports" (TyFun (TyCon "ModuleExports") (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Env") (TyCon "ModuleExports")))))))
(DFunDef false "buildExports" ((PVar "coreExp") (PVar "known") (PVar "modId") (PVar "prog") (PVar "env")) (ERecordCreate "ModuleExports" ((fa "modId" (EVar "modId")) (fa "expValues" (EBinOp "++" (EBinOp "++" (EApp (EVar "expValuesDirect") (EVar "prog")) (EApp (EApp (EVar "publicIfaceMethodVals") (EVar "prog")) (EVar "env"))) (EApp (EApp (EApp (EVar "reExpValues") (EVar "coreExp")) (EVar "known")) (EVar "prog")))) (fa "expTypes" (EBinOp "++" (EApp (EVar "expTypesDirect") (EVar "prog")) (EApp (EApp (EApp (EVar "reExpTypes") (EVar "coreExp")) (EVar "known")) (EVar "prog")))) (fa "expCtors" (EBinOp "++" (EApp (EVar "expCtorsDirect") (EVar "prog")) (EApp (EApp (EApp (EVar "reExpCtors") (EVar "coreExp")) (EVar "known")) (EVar "prog")))) (fa "expTypeCtors" (EApp (EVar "expTypeCtorsDirect") (EVar "prog"))) (fa "expFieldOwners" (EBinOp "++" (EApp (EVar "expFieldOwnersDirect") (EVar "prog")) (EApp (EApp (EApp (EVar "reExpFieldOwners") (EVar "coreExp")) (EVar "known")) (EVar "prog")))) (fa "expInterfaces" (EBinOp "++" (EApp (EVar "expInterfacesDirect") (EVar "prog")) (EApp (EApp (EApp (EVar "reExpInterfaces") (EVar "coreExp")) (EVar "known")) (EVar "prog")))) (fa "expIfaceMethods" (EBinOp "++" (EApp (EVar "expIfaceMethodsDirect") (EVar "prog")) (EApp (EApp (EApp (EVar "reExpIfaceMethods") (EVar "coreExp")) (EVar "known")) (EVar "prog")))) (fa "expEffects" (EBinOp "++" (EApp (EVar "expEffectsDirect") (EVar "prog")) (EApp (EApp (EApp (EVar "reExpEffects") (EVar "coreExp")) (EVar "known")) (EVar "prog")))) (fa "expNewtypeCtors" (EApp (EVar "expNewtypeCtorsDirect") (EVar "prog"))))))
(DTypeSig false "expNewtypeCtorsDirect" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "expNewtypeCtorsDirect" ((PList)) (EListLit))
(DFunDef false "expNewtypeCtorsDirect" ((PCons (PRec "DNewtype" ((rf "newtypePub" (PCon "True")) (rf "newtypeName" (PVar "n")) (rf "newtypeCtor" (PVar "con"))) false) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "con") (EVar "n")) (EApp (EVar "expNewtypeCtorsDirect") (EVar "rest"))))
(DFunDef false "expNewtypeCtorsDirect" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "expNewtypeCtorsDirect") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "expNewtypeCtorsDirect" ((PCons PWild (PVar "rest"))) (EApp (EVar "expNewtypeCtorsDirect") (EVar "rest")))
(DTypeSig false "expValuesDirect" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "expValuesDirect" ((PList)) (EListLit))
(DFunDef false "expValuesDirect" ((PCons (PCon "DTypeSig" (PCon "True") (PVar "n") PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "expValuesDirect") (EVar "rest"))))
(DFunDef false "expValuesDirect" ((PCons (PCon "DExtern" (PCon "True") (PVar "n") PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "expValuesDirect") (EVar "rest"))))
(DFunDef false "expValuesDirect" ((PCons (PCon "DFunDef" (PCon "True") (PVar "n") PWild PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "expValuesDirect") (EVar "rest"))))
(DFunDef false "expValuesDirect" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "expValuesDirect") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "expValuesDirect" ((PCons PWild (PVar "rest"))) (EApp (EVar "expValuesDirect") (EVar "rest")))
(DTypeSig false "publicIfaceMethodVals" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Env") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "publicIfaceMethodVals" ((PVar "prog") (PVar "env")) (EApp (EApp (EVar "flatMap") (EApp (EVar "keepBoundMethods") (EVar "env"))) (EApp (EVar "pubIfaceMethodSets") (EVar "prog"))))
(DTypeSig false "keepBoundMethods" (TyFun (TyCon "Env") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "keepBoundMethods" ((PVar "env") (PVar "ms")) (EApp (EApp (EVar "filterInSet") (EFieldAccess (EVar "env") "values")) (EVar "ms")))
(DTypeSig false "pubIfaceMethodSets" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "pubIfaceMethodSets" ((PList)) (EListLit))
(DFunDef false "pubIfaceMethodSets" ((PCons (PRec "DInterface" ((rf "pub" (PCon "True")) (rf "methods" None)) true) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EVar "map") (EVar "ifaceMethodNm")) (EVar "methods")) (EApp (EVar "pubIfaceMethodSets") (EVar "rest"))))
(DFunDef false "pubIfaceMethodSets" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "pubIfaceMethodSets") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "pubIfaceMethodSets" ((PCons PWild (PVar "rest"))) (EApp (EVar "pubIfaceMethodSets") (EVar "rest")))
(DTypeSig false "expTypesDirect" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "expTypesDirect" ((PList)) (EListLit))
(DFunDef false "expTypesDirect" ((PCons (PRec "DNewtype" ((rf "newtypePub" (PCon "True")) (rf "newtypeName" (PVar "n"))) false) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "expTypesDirect") (EVar "rest"))))
(DFunDef false "expTypesDirect" ((PCons (PRec "DData" ((rf "dataVis" (PCon "VisPublic")) (rf "dataName" (PVar "n"))) false) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "expTypesDirect") (EVar "rest"))))
(DFunDef false "expTypesDirect" ((PCons (PRec "DData" ((rf "dataVis" (PCon "VisAbstract")) (rf "dataName" (PVar "n"))) false) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "expTypesDirect") (EVar "rest"))))
(DFunDef false "expTypesDirect" ((PCons (PRec "DTypeAlias" ((rf "tyAliasPub" (PCon "True")) (rf "tyAliasName" (PVar "n"))) false) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "expTypesDirect") (EVar "rest"))))
(DFunDef false "expTypesDirect" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "expTypesDirect") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "expTypesDirect" ((PCons PWild (PVar "rest"))) (EApp (EVar "expTypesDirect") (EVar "rest")))
(DTypeSig false "expCtorsDirect" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "expCtorsDirect" ((PList)) (EListLit))
(DFunDef false "expCtorsDirect" ((PCons (PRec "DNewtype" ((rf "newtypePub" (PCon "True")) (rf "newtypeCtor" (PVar "con"))) false) (PVar "rest"))) (EBinOp "::" (EVar "con") (EApp (EVar "expCtorsDirect") (EVar "rest"))))
(DFunDef false "expCtorsDirect" ((PCons (PRec "DData" ((rf "dataVis" (PCon "VisPublic")) (rf "dataCtors" (PVar "vs"))) false) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "map") (EVar "variantName")) (EVar "vs")) (EApp (EVar "expCtorsDirect") (EVar "rest"))))
(DFunDef false "expCtorsDirect" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "expCtorsDirect") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "expCtorsDirect" ((PCons PWild (PVar "rest"))) (EApp (EVar "expCtorsDirect") (EVar "rest")))
(DTypeSig false "expTypeCtorsDirect" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "expTypeCtorsDirect" ((PList)) (EListLit))
(DFunDef false "expTypeCtorsDirect" ((PCons (PRec "DNewtype" ((rf "newtypePub" (PCon "True")) (rf "newtypeName" (PVar "n")) (rf "newtypeCtor" (PVar "con"))) false) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "n") (EListLit (EVar "con"))) (EApp (EVar "expTypeCtorsDirect") (EVar "rest"))))
(DFunDef false "expTypeCtorsDirect" ((PCons (PRec "DData" ((rf "dataVis" (PCon "VisPublic")) (rf "dataName" (PVar "n")) (rf "dataCtors" (PVar "vs"))) false) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "n") (EApp (EApp (EVar "map") (EVar "variantName")) (EVar "vs"))) (EApp (EVar "expTypeCtorsDirect") (EVar "rest"))))
(DFunDef false "expTypeCtorsDirect" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "expTypeCtorsDirect") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "expTypeCtorsDirect" ((PCons PWild (PVar "rest"))) (EApp (EVar "expTypeCtorsDirect") (EVar "rest")))
(DTypeSig false "expFieldOwnersDirect" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "expFieldOwnersDirect" ((PList)) (EListLit))
(DFunDef false "expFieldOwnersDirect" ((PCons (PRec "DData" ((rf "dataVis" (PCon "VisPublic")) (rf "dataCtors" (PVar "vs"))) false) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "flatMap") (EVar "variantFieldOwners")) (EVar "vs")) (EApp (EVar "expFieldOwnersDirect") (EVar "rest"))))
(DFunDef false "expFieldOwnersDirect" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "expFieldOwnersDirect") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "expFieldOwnersDirect" ((PCons PWild (PVar "rest"))) (EApp (EVar "expFieldOwnersDirect") (EVar "rest")))
(DTypeSig false "expInterfacesDirect" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "expInterfacesDirect" ((PList)) (EListLit))
(DFunDef false "expInterfacesDirect" ((PCons (PRec "DInterface" ((rf "pub" (PCon "True")) (rf "name" (PVar "n"))) true) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "expInterfacesDirect") (EVar "rest"))))
(DFunDef false "expInterfacesDirect" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "expInterfacesDirect") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "expInterfacesDirect" ((PCons PWild (PVar "rest"))) (EApp (EVar "expInterfacesDirect") (EVar "rest")))
(DTypeSig false "expIfaceMethodsDirect" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "expIfaceMethodsDirect" ((PList)) (EListLit))
(DFunDef false "expIfaceMethodsDirect" ((PCons (PRec "DInterface" ((rf "pub" (PCon "True")) (rf "name" (PVar "n")) (rf "methods" None)) true) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "n") (EApp (EApp (EVar "map") (EVar "ifaceMethodNm")) (EVar "methods"))) (EApp (EVar "expIfaceMethodsDirect") (EVar "rest"))))
(DFunDef false "expIfaceMethodsDirect" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "expIfaceMethodsDirect") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "expIfaceMethodsDirect" ((PCons PWild (PVar "rest"))) (EApp (EVar "expIfaceMethodsDirect") (EVar "rest")))
(DTypeSig false "expEffectsDirect" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "expEffectsDirect" ((PList)) (EListLit))
(DFunDef false "expEffectsDirect" ((PCons (PCon "DEffect" (PCon "True") (PVar "n") PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "expEffectsDirect") (EVar "rest"))))
(DFunDef false "expEffectsDirect" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "expEffectsDirect") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "expEffectsDirect" ((PCons PWild (PVar "rest"))) (EApp (EVar "expEffectsDirect") (EVar "rest")))
(DTypeSig false "reExpEffects" (TyFun (TyCon "ModuleExports") (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "reExpEffects" ((PVar "coreExp") (PVar "known") (PVar "prog")) (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EVar "overPubUse") (EVar "coreExp")) (EVar "known")) (EVar "reExpEffectsFrom"))) (EApp (EVar "pubUsePaths") (EVar "prog"))))
(DTypeSig false "reExpEffectsFrom" (TyFun (TyCon "UsePath") (TyFun (TyCon "ModuleExports") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "reExpEffectsFrom" ((PCon "UseWild" PWild) (PVar "src")) (EFieldAccess (EVar "src") "expEffects"))
(DFunDef false "reExpEffectsFrom" (PWild PWild) (EListLit))
(DTypeSig false "reexportBindings" (TyFun (TyCon "UsePath") (TyFun (TyCon "ModuleExports") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "reexportBindings" ((PCon "UseName" (PVar "ns")) PWild) (EIf (EBinOp ">" (EApp (EVar "listLen") (EVar "ns")) (ELit (LInt 1))) (EBlock (DoLet false false (PVar "n") (EApp (EVar "lastOf") (EVar "ns"))) (DoExpr (EListLit (ETuple (EVar "n") (EVar "n"))))) (EListLit)))
(DFunDef false "reexportBindings" ((PCon "UseGroup" PWild (PVar "members")) (PVar "src")) (EApp (EApp (EVar "map") (EVar "dropLocOfExpanded")) (EApp (EApp (EVar "flatMap") (EApp (EVar "expandMemberNames") (EVar "src"))) (EVar "members"))))
(DFunDef false "reexportBindings" ((PCon "UseWild" PWild) (PVar "src")) (EApp (EApp (EVar "map") (EVar "selfBinding")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EFieldAccess (EVar "src") "expValues") (EFieldAccess (EVar "src") "expTypes")) (EFieldAccess (EVar "src") "expCtors")) (EFieldAccess (EVar "src") "expInterfaces"))))
(DFunDef false "reexportBindings" ((PCon "UseAlias" PWild PWild) PWild) (EListLit))
(DTypeSig false "dropLocOfExpanded" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyCon "Loc")) (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "dropLocOfExpanded" ((PTuple (PVar "origin") (PVar "local") PWild)) (ETuple (EVar "origin") (EVar "local")))
(DTypeSig false "selfBinding" (TyFun (TyCon "String") (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "selfBinding" ((PVar "n")) (ETuple (EVar "n") (EVar "n")))
(DTypeSig false "localsExportedFrom" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "localsExportedFrom" ((PVar "origins") (PVar "bindings")) (EBlock (DoLet false false (PVar "dom") (EApp (EApp (EVar "omFromNames") (EVar "origins")) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EVar "map") (EVar "snd")) (EApp (EApp (EVar "filterList") (ELam ((PVar "b")) (EApp (EApp (EVar "omHasKey") (EApp (EVar "fst") (EVar "b"))) (EVar "dom")))) (EVar "bindings"))))))
(DTypeSig false "reExpValues" (TyFun (TyCon "ModuleExports") (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "reExpValues" ((PVar "coreExp") (PVar "known") (PVar "prog")) (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EVar "overPubUse") (EVar "coreExp")) (EVar "known")) (EVar "reExpValuesFrom"))) (EApp (EVar "pubUsePaths") (EVar "prog"))))
(DTypeSig false "reExpValuesFrom" (TyFun (TyCon "UsePath") (TyFun (TyCon "ModuleExports") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "reExpValuesFrom" ((PVar "path") (PVar "src")) (EBlock (DoLet false false (PVar "bindings") (EApp (EApp (EVar "reexportBindings") (EVar "path")) (EVar "src"))) (DoExpr (EBinOp "++" (EApp (EApp (EVar "localsExportedFrom") (EFieldAccess (EVar "src") "expValues")) (EVar "bindings")) (EApp (EApp (EVar "flatMap") (EApp (EVar "ifaceValsOf") (EVar "src"))) (EApp (EApp (EVar "map") (EVar "fst")) (EVar "bindings")))))))
(DTypeSig false "ifaceValsOf" (TyFun (TyCon "ModuleExports") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "ifaceValsOf" ((PVar "src") (PVar "n")) (EIf (EApp (EApp (EVar "contains") (EVar "n")) (EFieldAccess (EVar "src") "expInterfaces")) (EApp (EApp (EVar "filterContains") (EFieldAccess (EVar "src") "expValues")) (EApp (EApp (EVar "ifaceMethodsOf") (EVar "n")) (EFieldAccess (EVar "src") "expIfaceMethods"))) (EListLit)))
(DTypeSig false "reExpTypes" (TyFun (TyCon "ModuleExports") (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "reExpTypes" ((PVar "coreExp") (PVar "known") (PVar "prog")) (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EVar "overPubUse") (EVar "coreExp")) (EVar "known")) (EVar "reExpTypesFrom"))) (EApp (EVar "pubUsePaths") (EVar "prog"))))
(DTypeSig false "reExpTypesFrom" (TyFun (TyCon "UsePath") (TyFun (TyCon "ModuleExports") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "reExpTypesFrom" ((PVar "path") (PVar "src")) (EApp (EApp (EVar "localsExportedFrom") (EFieldAccess (EVar "src") "expTypes")) (EApp (EApp (EVar "reexportBindings") (EVar "path")) (EVar "src"))))
(DTypeSig false "reExpCtors" (TyFun (TyCon "ModuleExports") (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "reExpCtors" ((PVar "coreExp") (PVar "known") (PVar "prog")) (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EVar "overPubUse") (EVar "coreExp")) (EVar "known")) (EVar "reExpCtorsFrom"))) (EApp (EVar "pubUsePaths") (EVar "prog"))))
(DTypeSig false "reExpCtorsFrom" (TyFun (TyCon "UsePath") (TyFun (TyCon "ModuleExports") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "reExpCtorsFrom" ((PVar "path") (PVar "src")) (EApp (EApp (EVar "localsExportedFrom") (EFieldAccess (EVar "src") "expCtors")) (EApp (EApp (EVar "reexportBindings") (EVar "path")) (EVar "src"))))
(DTypeSig false "reExpInterfaces" (TyFun (TyCon "ModuleExports") (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "reExpInterfaces" ((PVar "coreExp") (PVar "known") (PVar "prog")) (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EVar "overPubUse") (EVar "coreExp")) (EVar "known")) (EVar "reExpInterfacesFrom"))) (EApp (EVar "pubUsePaths") (EVar "prog"))))
(DTypeSig false "reexportOrigins" (TyFun (TyCon "UsePath") (TyFun (TyCon "ModuleExports") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "reexportOrigins" ((PVar "path") (PVar "src")) (EApp (EApp (EVar "map") (EVar "fst")) (EApp (EApp (EVar "reexportBindings") (EVar "path")) (EVar "src"))))
(DTypeSig false "reExpInterfacesFrom" (TyFun (TyCon "UsePath") (TyFun (TyCon "ModuleExports") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "reExpInterfacesFrom" ((PVar "path") (PVar "src")) (EApp (EApp (EVar "filterContains") (EFieldAccess (EVar "src") "expInterfaces")) (EApp (EApp (EVar "reexportOrigins") (EVar "path")) (EVar "src"))))
(DTypeSig false "reExpIfaceMethods" (TyFun (TyCon "ModuleExports") (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "reExpIfaceMethods" ((PVar "coreExp") (PVar "known") (PVar "prog")) (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EVar "overPubUse") (EVar "coreExp")) (EVar "known")) (EVar "reExpIfaceMethodsFrom"))) (EApp (EVar "pubUsePaths") (EVar "prog"))))
(DTypeSig false "reExpIfaceMethodsFrom" (TyFun (TyCon "UsePath") (TyFun (TyCon "ModuleExports") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "reExpIfaceMethodsFrom" ((PVar "path") (PVar "src")) (EApp (EApp (EVar "ifaceMethodPairs") (EVar "src")) (EApp (EApp (EVar "filterContains") (EFieldAccess (EVar "src") "expInterfaces")) (EApp (EApp (EVar "reexportOrigins") (EVar "path")) (EVar "src")))))
(DTypeSig false "ifaceMethodPairs" (TyFun (TyCon "ModuleExports") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "ifaceMethodPairs" (PWild (PList)) (EListLit))
(DFunDef false "ifaceMethodPairs" ((PVar "src") (PCons (PVar "i") (PVar "rest"))) (EBinOp "::" (ETuple (EVar "i") (EApp (EApp (EVar "ifaceMethodsOf") (EVar "i")) (EFieldAccess (EVar "src") "expIfaceMethods"))) (EApp (EApp (EVar "ifaceMethodPairs") (EVar "src")) (EVar "rest"))))
(DTypeSig false "reExpFieldOwners" (TyFun (TyCon "ModuleExports") (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "reExpFieldOwners" ((PVar "coreExp") (PVar "known") (PVar "prog")) (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EVar "overPubUse") (EVar "coreExp")) (EVar "known")) (EVar "reExpFieldOwnersFrom"))) (EApp (EVar "pubUsePaths") (EVar "prog"))))
(DTypeSig false "reExpFieldOwnersFrom" (TyFun (TyCon "UsePath") (TyFun (TyCon "ModuleExports") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "reExpFieldOwnersFrom" ((PVar "path") (PVar "src")) (EApp (EApp (EVar "ownersForTypes") (EApp (EApp (EVar "filterContains") (EFieldAccess (EVar "src") "expTypes")) (EApp (EApp (EVar "reexportOrigins") (EVar "path")) (EVar "src")))) (EFieldAccess (EVar "src") "expFieldOwners")))
(DTypeSig false "ownersForTypes" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "ownersForTypes" (PWild (PList)) (EListLit))
(DFunDef false "ownersForTypes" ((PVar "types") (PCons (PTuple (PVar "f") (PVar "o")) (PVar "rest"))) (EIf (EApp (EApp (EVar "contains") (EVar "o")) (EVar "types")) (EBinOp "::" (ETuple (EVar "f") (EVar "o")) (EApp (EApp (EVar "ownersForTypes") (EVar "types")) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "ownersForTypes") (EVar "types")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "overPubUse" (TyFun (TyCon "ModuleExports") (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyFun (TyCon "UsePath") (TyFun (TyCon "ModuleExports") (TyApp (TyCon "List") (TyVar "b")))) (TyFun (TyCon "UsePath") (TyApp (TyCon "List") (TyVar "b")))))))
(DFunDef false "overPubUse" ((PVar "coreExp") (PVar "known") (PVar "f") (PVar "path")) (EBlock (DoLet false false (PVar "mid") (EApp (EVar "useModId") (EVar "path"))) (DoExpr (EIf (EBinOp "==" (EVar "mid") (ELit (LString "core"))) (EApp (EApp (EVar "f") (EVar "path")) (EVar "coreExp")) (EMatch (EApp (EApp (EVar "findExports") (EVar "mid")) (EVar "known")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "src")) () (EApp (EApp (EVar "f") (EVar "path")) (EVar "src"))))))))
(DTypeSig true "resolveModule" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyTuple (TyCon "ModuleExports") (TyApp (TyCon "List") (TyCon "ResError")))))))))
(DFunDef false "resolveModule" ((PVar "runtimeDecls") (PVar "preludeDecls") (PVar "known") (PVar "modId") (PVar "prog")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveModuleG") (EListLit)) (EVar "runtimeDecls")) (EVar "preludeDecls")) (EVar "known")) (EVar "modId")) (EVar "prog")))
(DTypeSig true "resolveModuleG" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyTuple (TyCon "ModuleExports") (TyApp (TyCon "List") (TyCon "ResError"))))))))))
(DFunDef false "resolveModuleG" ((PVar "internalGuard") (PVar "runtimeDecls") (PVar "preludeDecls") (PVar "known") (PVar "modId") (PVar "prog")) (EBlock (DoLet false false (PTuple (PVar "env") (PVar "importErrs")) (EApp (EApp (EApp (EApp (EApp (EVar "buildEnvMM") (EVar "runtimeDecls")) (EVar "preludeDecls")) (EVar "known")) (EVar "prog")) (EVar "internalGuard"))) (DoLet false false (PVar "errs") (EApp (EVar "dedupResErrors") (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "buildErrors") (EVar "preludeDecls")) (EVar "prog")) (EVar "importErrs")) (EApp (EApp (EVar "flatMap") (EApp (EVar "checkDecl") (EVar "env"))) (EVar "prog"))))) (DoLet false false (PVar "exp") (EApp (EApp (EApp (EApp (EApp (EVar "buildExports") (EApp (EVar "coreExports") (EVar "preludeDecls"))) (EVar "known")) (EVar "modId")) (EVar "prog")) (EVar "env"))) (DoExpr (ETuple (EVar "exp") (EVar "errs")))))
(DTypeSig false "resolveModulesErrors" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyCon "ResError")))))))
(DFunDef false "resolveModulesErrors" ((PVar "rt") (PVar "pre") (PVar "known") (PVar "mods")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveModulesErrorsG") (EVar "True")) (EListLit)) (EVar "rt")) (EVar "pre")) (EVar "known")) (EVar "mods")))
(DTypeSig false "resolveModulesErrorsPairsG" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "ResError")))))))))))
(DFunDef false "resolveModulesErrorsPairsG" (PWild PWild PWild PWild PWild (PList)) (EListLit))
(DFunDef false "resolveModulesErrorsPairsG" ((PVar "allowInternal") (PVar "trustedMods") (PVar "rt") (PVar "pre") (PVar "known") (PCons (PTuple (PVar "mid") (PVar "prog")) (PVar "rest"))) (EBlock (DoLet false false (PVar "guard") (EIf (EBinOp "||" (EVar "allowInternal") (EApp (EApp (EVar "contains") (EVar "mid")) (EVar "trustedMods"))) (EListLit) (EVar "internalExterns"))) (DoLet false false (PTuple (PVar "exp") (PVar "errs")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveModuleG") (EVar "guard")) (EVar "rt")) (EVar "pre")) (EVar "known")) (EVar "mid")) (EVar "prog"))) (DoExpr (EBinOp "::" (ETuple (EVar "mid") (EVar "errs")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveModulesErrorsPairsG") (EVar "allowInternal")) (EVar "trustedMods")) (EVar "rt")) (EVar "pre")) (EApp (EApp (EApp (EVar "omInsert") (EFieldAccess (EVar "exp") "modId")) (EVar "exp")) (EVar "known"))) (EVar "rest"))))))
(DTypeSig false "resolveModulesErrorsG" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyCon "ResError")))))))))
(DFunDef false "resolveModulesErrorsG" ((PVar "allowInternal") (PVar "trustedMods") (PVar "rt") (PVar "pre") (PVar "known") (PVar "mods")) (EApp (EApp (EVar "flatMap") (EVar "snd")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveModulesErrorsPairsG") (EVar "allowInternal")) (EVar "trustedMods")) (EVar "rt")) (EVar "pre")) (EVar "known")) (EVar "mods"))))
(DTypeSig true "resolveModulesToLines" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "String")))))
(DFunDef false "resolveModulesToLines" ((PVar "runtimeDecls") (PVar "preludeDecls") (PVar "mods")) (EApp (EVar "joinNl") (EApp (EApp (EVar "map") (EVar "resErrorSexp")) (EApp (EApp (EApp (EApp (EVar "resolveModulesErrors") (EVar "runtimeDecls")) (EVar "preludeDecls")) (EVar "omEmpty")) (EVar "mods")))))
(DTypeSig true "resolveModulesToLinesG" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "String")))))))
(DFunDef false "resolveModulesToLinesG" ((PVar "allowInternal") (PVar "trustedMods") (PVar "runtimeDecls") (PVar "preludeDecls") (PVar "mods")) (EApp (EVar "joinNl") (EApp (EApp (EVar "map") (EVar "resErrorSexp")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveModulesErrorsG") (EVar "allowInternal")) (EVar "trustedMods")) (EVar "runtimeDecls")) (EVar "preludeDecls")) (EVar "omEmpty")) (EVar "mods")))))
(DTypeSig true "resolveModulesErrorsByFile" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "ResError")))))))))))
(DFunDef false "resolveModulesErrorsByFile" ((PVar "modPaths") (PVar "allowInternal") (PVar "trustedMods") (PVar "runtimeDecls") (PVar "preludeDecls") (PVar "mods")) (EApp (EApp (EVar "map") (EApp (EVar "fileOfModuleErrors") (EVar "modPaths"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveModulesErrorsPairsG") (EVar "allowInternal")) (EVar "trustedMods")) (EVar "runtimeDecls")) (EVar "preludeDecls")) (EVar "omEmpty")) (EVar "mods"))))
(DTypeSig false "fileOfModuleErrors" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "ResError"))) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "fileOfModuleErrors" ((PVar "modPaths") (PTuple (PVar "mid") (PVar "errs"))) (EBlock (DoLet false false (PVar "file") (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "mid")) (EVar "modPaths")) (arm (PCon "Some" (PVar "p")) () (EVar "p")) (arm (PCon "None") () (ELit (LString ""))))) (DoExpr (ETuple (EVar "file") (EVar "errs")))))
(DTypeSig false "lookupBindId" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "String") (TyCon "Int"))))
(DFunDef false "lookupBindId" ((PVar "env") (PVar "n")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "env")) (arm (PCon "Some" (PVar "id")) () (EVar "id")) (arm (PCon "None") () (ELit (LInt 0)))))
(DTypeSig false "insertZero" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyApp (TyCon "OrdMap") (TyCon "Int")))))
(DFunDef false "insertZero" ((PList) (PVar "env")) (EVar "env"))
(DFunDef false "insertZero" ((PCons (PVar "n") (PVar "rest")) (PVar "env")) (EApp (EApp (EVar "insertZero") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (ELit (LInt 0))) (EVar "env"))))
(DTypeSig false "insertParams" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyApp (TyCon "OrdMap") (TyCon "Int")))))
(DFunDef false "insertParams" ((PList) (PVar "env")) (EVar "env"))
(DFunDef false "insertParams" ((PCons (PVar "p") (PVar "rest")) (PVar "env")) (EApp (EApp (EVar "insertParams") (EVar "rest")) (EApp (EApp (EVar "insertZero") (EApp (EVar "patBindings") (EVar "p"))) (EVar "env"))))
(DTypeSig false "topBinderNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "topBinderNames" ((PList)) (EListLit))
(DFunDef false "topBinderNames" ((PCons (PCon "DFunDef" PWild (PVar "n") PWild PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "topBinderNames") (EVar "rest"))))
(DFunDef false "topBinderNames" ((PCons (PCon "DLetGroup" PWild (PVar "binds")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "map") (EVar "letBindName")) (EVar "binds")) (EApp (EVar "topBinderNames") (EVar "rest"))))
(DFunDef false "topBinderNames" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "topBinderNames") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "topBinderNames" ((PCons PWild (PVar "rest"))) (EApp (EVar "topBinderNames") (EVar "rest")))
(DTypeSig false "numberFrom" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))))))
(DFunDef false "numberFrom" (PWild (PList)) (EListLit))
(DFunDef false "numberFrom" ((PVar "i") (PCons (PVar "n") (PVar "rest"))) (EBinOp "::" (ETuple (EVar "n") (EVar "i")) (EApp (EApp (EVar "numberFrom") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest"))))
(DTypeSig false "stampExpr" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "Expr") (TyCon "Expr"))))
(DFunDef false "stampExpr" (PWild (PCon "ELit" (PVar "l"))) (EApp (EVar "ELit") (EVar "l")))
(DFunDef false "stampExpr" (PWild (PCon "ENumLit" (PVar "n") (PVar "r") (PVar "d") (PVar "lx"))) (EApp (EApp (EApp (EApp (EVar "ENumLit") (EVar "n")) (EVar "r")) (EVar "d")) (EVar "lx")))
(DFunDef false "stampExpr" (PWild (PCon "EMethodRef" (PVar "m"))) (EApp (EVar "EMethodRef") (EVar "m")))
(DFunDef false "stampExpr" (PWild (PCon "EDictApp" (PVar "d"))) (EApp (EVar "EDictApp") (EVar "d")))
(DFunDef false "stampExpr" (PWild (PCon "EMethodAt" (PVar "name") (PVar "r") (PVar "ir") (PVar "mr"))) (EApp (EApp (EApp (EApp (EVar "EMethodAt") (EVar "name")) (EVar "r")) (EVar "ir")) (EVar "mr")))
(DFunDef false "stampExpr" (PWild (PCon "EDictAt" (PVar "name") (PVar "r"))) (EApp (EApp (EVar "EDictAt") (EVar "name")) (EVar "r")))
(DFunDef false "stampExpr" (PWild (PCon "EVarAt" (PVar "n") (PVar "a"))) (EApp (EApp (EVar "EVarAt") (EVar "n")) (EVar "a")))
(DFunDef false "stampExpr" (PWild (PCon "EVarId" (PVar "n") (PVar "i"))) (EApp (EApp (EVar "EVarId") (EVar "n")) (EVar "i")))
(DFunDef false "stampExpr" ((PVar "env") (PCon "EVar" (PVar "n"))) (EIf (EApp (EVar "isHint") (EVar "n")) (EApp (EVar "EVar") (EVar "n")) (EIf (EVar "otherwise") (EApp (EApp (EVar "EVarId") (EVar "n")) (EApp (EApp (EVar "lookupBindId") (EVar "env")) (EVar "n"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "stampExpr" ((PVar "env") (PCon "EApp" (PVar "f") (PVar "x"))) (EApp (EApp (EVar "EApp") (EApp (EApp (EVar "stampExpr") (EVar "env")) (EVar "f"))) (EApp (EApp (EVar "stampExpr") (EVar "env")) (EVar "x"))))
(DFunDef false "stampExpr" ((PVar "env") (PCon "ELam" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "ELam") (EVar "pats")) (EApp (EApp (EVar "stampExpr") (EApp (EApp (EVar "insertParams") (EVar "pats")) (EVar "env"))) (EVar "body"))))
(DFunDef false "stampExpr" ((PVar "env") (PCon "ELet" (PVar "m") (PVar "isRec") (PVar "pat") (PVar "e1") (PVar "e2"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "stampLet") (EVar "env")) (EVar "m")) (EVar "isRec")) (EVar "pat")) (EVar "e1")) (EVar "e2")))
(DFunDef false "stampExpr" ((PVar "env") (PCon "ELetGroup" (PVar "binds") (PVar "body"))) (EApp (EApp (EApp (EVar "stampLetGroup") (EVar "env")) (EVar "binds")) (EVar "body")))
(DFunDef false "stampExpr" ((PVar "env") (PCon "EMatch" (PVar "e0") (PVar "arms"))) (EApp (EApp (EVar "EMatch") (EApp (EApp (EVar "stampExpr") (EVar "env")) (EVar "e0"))) (EApp (EApp (EVar "map") (EApp (EVar "stampArm") (EVar "env"))) (EVar "arms"))))
(DFunDef false "stampExpr" ((PVar "env") (PCon "EIf" (PVar "c") (PVar "t") (PVar "el"))) (EApp (EApp (EApp (EVar "EIf") (EApp (EApp (EVar "stampExpr") (EVar "env")) (EVar "c"))) (EApp (EApp (EVar "stampExpr") (EVar "env")) (EVar "t"))) (EApp (EApp (EVar "stampExpr") (EVar "env")) (EVar "el"))))
(DFunDef false "stampExpr" ((PVar "env") (PCon "EBinOp" (PVar "op") (PVar "a") (PVar "b") (PVar "r"))) (EApp (EApp (EApp (EApp (EVar "EBinOp") (EVar "op")) (EApp (EApp (EVar "stampExpr") (EVar "env")) (EVar "a"))) (EApp (EApp (EVar "stampExpr") (EVar "env")) (EVar "b"))) (EVar "r")))
(DFunDef false "stampExpr" ((PVar "env") (PCon "EUnOp" (PVar "op") (PVar "a") (PVar "r"))) (EApp (EApp (EApp (EVar "EUnOp") (EVar "op")) (EApp (EApp (EVar "stampExpr") (EVar "env")) (EVar "a"))) (EVar "r")))
(DFunDef false "stampExpr" ((PVar "env") (PCon "EInfix" (PVar "op") (PVar "a") (PVar "b"))) (EApp (EApp (EApp (EVar "EInfix") (EVar "op")) (EApp (EApp (EVar "stampExpr") (EVar "env")) (EVar "a"))) (EApp (EApp (EVar "stampExpr") (EVar "env")) (EVar "b"))))
(DFunDef false "stampExpr" ((PVar "env") (PCon "EFieldAccess" (PVar "e0") (PVar "f") (PVar "r"))) (EApp (EApp (EApp (EVar "EFieldAccess") (EApp (EApp (EVar "stampExpr") (EVar "env")) (EVar "e0"))) (EVar "f")) (EVar "r")))
(DFunDef false "stampExpr" ((PVar "env") (PCon "ETuple" (PVar "es"))) (EApp (EVar "ETuple") (EApp (EApp (EVar "map") (EApp (EVar "stampExpr") (EVar "env"))) (EVar "es"))))
(DFunDef false "stampExpr" ((PVar "env") (PCon "EListLit" (PVar "es"))) (EApp (EVar "EListLit") (EApp (EApp (EVar "map") (EApp (EVar "stampExpr") (EVar "env"))) (EVar "es"))))
(DFunDef false "stampExpr" ((PVar "env") (PCon "EArrayLit" (PVar "es"))) (EApp (EVar "EArrayLit") (EApp (EApp (EVar "map") (EApp (EVar "stampExpr") (EVar "env"))) (EVar "es"))))
(DFunDef false "stampExpr" ((PVar "env") (PCon "ERangeList" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EVar "ERangeList") (EApp (EApp (EVar "stampExpr") (EVar "env")) (EVar "lo"))) (EApp (EApp (EVar "stampExpr") (EVar "env")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "stampExpr" ((PVar "env") (PCon "ERangeArray" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EVar "ERangeArray") (EApp (EApp (EVar "stampExpr") (EVar "env")) (EVar "lo"))) (EApp (EApp (EVar "stampExpr") (EVar "env")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "stampExpr" ((PVar "env") (PCon "ESlice" (PVar "e0") (PVar "lo") (PVar "hi") (PVar "incl") (PVar "r"))) (EApp (EApp (EApp (EApp (EApp (EVar "ESlice") (EApp (EApp (EVar "stampExpr") (EVar "env")) (EVar "e0"))) (EApp (EApp (EVar "stampExpr") (EVar "env")) (EVar "lo"))) (EApp (EApp (EVar "stampExpr") (EVar "env")) (EVar "hi"))) (EVar "incl")) (EVar "r")))
(DFunDef false "stampExpr" ((PVar "env") (PCon "EIndex" (PVar "e0") (PVar "i") (PVar "r"))) (EApp (EApp (EApp (EVar "EIndex") (EApp (EApp (EVar "stampExpr") (EVar "env")) (EVar "e0"))) (EApp (EApp (EVar "stampExpr") (EVar "env")) (EVar "i"))) (EVar "r")))
(DFunDef false "stampExpr" ((PVar "env") (PCon "EAnnot" (PVar "e0") (PVar "t"))) (EApp (EApp (EVar "EAnnot") (EApp (EApp (EVar "stampExpr") (EVar "env")) (EVar "e0"))) (EVar "t")))
(DFunDef false "stampExpr" ((PVar "env") (PCon "EHeadAnnot" (PVar "e0") (PVar "t"))) (EApp (EApp (EVar "EHeadAnnot") (EApp (EApp (EVar "stampExpr") (EVar "env")) (EVar "e0"))) (EVar "t")))
(DFunDef false "stampExpr" ((PVar "env") (PCon "EBlock" (PVar "stmts"))) (EApp (EVar "EBlock") (EApp (EApp (EVar "stampStmts") (EVar "env")) (EVar "stmts"))))
(DFunDef false "stampExpr" ((PVar "env") (PCon "EDo" (PVar "d") (PVar "stmts"))) (EApp (EApp (EVar "EDo") (EVar "d")) (EApp (EApp (EVar "stampStmts") (EVar "env")) (EVar "stmts"))))
(DFunDef false "stampExpr" ((PVar "env") (PCon "EStringInterp" (PVar "parts"))) (EApp (EVar "EStringInterp") (EApp (EApp (EVar "map") (EApp (EVar "stampInterp") (EVar "env"))) (EVar "parts"))))
(DFunDef false "stampExpr" ((PVar "env") (PCon "EGuards" (PVar "arms"))) (EApp (EVar "EGuards") (EApp (EApp (EVar "map") (EApp (EVar "stampGuardArm") (EVar "env"))) (EVar "arms"))))
(DFunDef false "stampExpr" ((PVar "env") (PCon "ERecordCreate" (PVar "name") (PVar "fs"))) (EApp (EApp (EVar "ERecordCreate") (EVar "name")) (EApp (EApp (EVar "map") (EApp (EVar "stampFieldAssign") (EVar "env"))) (EVar "fs"))))
(DFunDef false "stampExpr" ((PVar "env") (PCon "ERecordUpdate" (PVar "e0") (PVar "fs") (PVar "r"))) (EApp (EApp (EApp (EVar "ERecordUpdate") (EApp (EApp (EVar "stampExpr") (EVar "env")) (EVar "e0"))) (EApp (EApp (EVar "map") (EApp (EVar "stampFieldAssign") (EVar "env"))) (EVar "fs"))) (EVar "r")))
(DFunDef false "stampExpr" ((PVar "env") (PCon "EVariantUpdate" (PVar "con") (PVar "e0") (PVar "fs"))) (EApp (EApp (EApp (EVar "EVariantUpdate") (EVar "con")) (EApp (EApp (EVar "stampExpr") (EVar "env")) (EVar "e0"))) (EApp (EApp (EVar "map") (EApp (EVar "stampFieldAssign") (EVar "env"))) (EVar "fs"))))
(DFunDef false "stampExpr" ((PVar "env") (PCon "EMapLit" (PVar "n") (PVar "kvs"))) (EApp (EApp (EVar "EMapLit") (EVar "n")) (EApp (EApp (EVar "map") (EApp (EVar "stampKv") (EVar "env"))) (EVar "kvs"))))
(DFunDef false "stampExpr" ((PVar "env") (PCon "ESetLit" (PVar "n") (PVar "es"))) (EApp (EApp (EVar "ESetLit") (EVar "n")) (EApp (EApp (EVar "map") (EApp (EVar "stampExpr") (EVar "env"))) (EVar "es"))))
(DFunDef false "stampExpr" ((PVar "env") (PCon "EAsPat" (PVar "x") (PVar "e0"))) (EApp (EApp (EVar "EAsPat") (EVar "x")) (EApp (EApp (EVar "stampExpr") (EVar "env")) (EVar "e0"))))
(DFunDef false "stampExpr" ((PVar "env") (PCon "ESection" (PVar "s"))) (EApp (EVar "ESection") (EApp (EApp (EVar "stampSection") (EVar "env")) (EVar "s"))))
(DFunDef false "stampExpr" ((PVar "env") (PCon "ELoc" (PVar "l") (PVar "e"))) (EApp (EApp (EVar "ELoc") (EVar "l")) (EApp (EApp (EVar "stampExpr") (EVar "env")) (EVar "e"))))
(DFunDef false "stampExpr" ((PVar "env") (PCon "EDoOrigin" (PVar "l") (PVar "e"))) (EApp (EApp (EVar "EDoOrigin") (EVar "l")) (EApp (EApp (EVar "stampExpr") (EVar "env")) (EVar "e"))))
(DTypeSig false "stampLet" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyFun (TyCon "Pat") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Expr"))))))))
(DFunDef false "stampLet" ((PVar "env") (PVar "m") (PCon "True") (PCon "PVar" (PVar "f") (PVar "fl")) (PVar "e1") (PVar "e2")) (EBlock (DoLet false false (PVar "inner") (EApp (EApp (EVar "insertZero") (EListLit (EVar "f"))) (EVar "env"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "ELet") (EVar "m")) (EVar "True")) (EApp (EApp (EVar "PVar") (EVar "f")) (EVar "fl"))) (EApp (EApp (EVar "stampExpr") (EVar "inner")) (EVar "e1"))) (EApp (EApp (EVar "stampExpr") (EVar "inner")) (EVar "e2"))))))
(DFunDef false "stampLet" ((PVar "env") (PVar "m") (PVar "isRec") (PVar "pat") (PVar "e1") (PVar "e2")) (EApp (EApp (EApp (EApp (EApp (EVar "ELet") (EVar "m")) (EVar "isRec")) (EVar "pat")) (EApp (EApp (EVar "stampExpr") (EVar "env")) (EVar "e1"))) (EApp (EApp (EVar "stampExpr") (EApp (EApp (EVar "insertZero") (EApp (EVar "patBindings") (EVar "pat"))) (EVar "env"))) (EVar "e2"))))
(DTypeSig false "stampLetGroup" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyFun (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "stampLetGroup" ((PVar "env") (PVar "binds") (PVar "body")) (EBlock (DoLet false false (PVar "groupScope") (EApp (EApp (EVar "insertZero") (EApp (EApp (EVar "map") (EVar "letBindName")) (EVar "binds"))) (EVar "env"))) (DoExpr (EApp (EApp (EVar "ELetGroup") (EApp (EApp (EVar "map") (EApp (EVar "stampLetBind") (EVar "groupScope"))) (EVar "binds"))) (EApp (EApp (EVar "stampExpr") (EVar "groupScope")) (EVar "body"))))))
(DTypeSig false "stampLetBind" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "LetBind") (TyCon "LetBind"))))
(DFunDef false "stampLetBind" ((PVar "groupScope") (PCon "LetBind" (PVar "name") (PVar "clauses"))) (EApp (EApp (EVar "LetBind") (EVar "name")) (EApp (EApp (EVar "map") (EApp (EVar "stampClause") (EVar "groupScope"))) (EVar "clauses"))))
(DTypeSig false "stampClause" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "FunClause") (TyCon "FunClause"))))
(DFunDef false "stampClause" ((PVar "groupScope") (PCon "FunClause" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "FunClause") (EVar "pats")) (EApp (EApp (EVar "stampExpr") (EApp (EApp (EVar "insertParams") (EVar "pats")) (EVar "groupScope"))) (EVar "body"))))
(DTypeSig false "stampArm" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "Arm") (TyCon "Arm"))))
(DFunDef false "stampArm" ((PVar "env") (PCon "Arm" (PVar "pat") (PVar "gs") (PVar "body"))) (EBlock (DoLet false false (PVar "scope0") (EApp (EApp (EVar "insertZero") (EApp (EVar "patBindings") (EVar "pat"))) (EVar "env"))) (DoLet false false (PTuple (PVar "gs2") (PVar "scope2")) (EApp (EApp (EVar "stampGuards") (EVar "scope0")) (EVar "gs"))) (DoExpr (EApp (EApp (EApp (EVar "Arm") (EVar "pat")) (EVar "gs2")) (EApp (EApp (EVar "stampExpr") (EVar "scope2")) (EVar "body"))))))
(DTypeSig false "stampGuards" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Guard")) (TyTuple (TyApp (TyCon "List") (TyCon "Guard")) (TyApp (TyCon "OrdMap") (TyCon "Int"))))))
(DFunDef false "stampGuards" ((PVar "scope") (PList)) (ETuple (EListLit) (EVar "scope")))
(DFunDef false "stampGuards" ((PVar "scope") (PCons (PCon "GBool" (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "rest2") (PVar "scope2")) (EApp (EApp (EVar "stampGuards") (EVar "scope")) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EApp (EVar "GBool") (EApp (EApp (EVar "stampExpr") (EVar "scope")) (EVar "e"))) (EVar "rest2")) (EVar "scope2")))))
(DFunDef false "stampGuards" ((PVar "scope") (PCons (PCon "GBind" (PVar "p") (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false (PVar "e2") (EApp (EApp (EVar "stampExpr") (EVar "scope")) (EVar "e"))) (DoLet false false (PTuple (PVar "rest2") (PVar "scope2")) (EApp (EApp (EVar "stampGuards") (EApp (EApp (EVar "insertZero") (EApp (EVar "patBindings") (EVar "p"))) (EVar "scope"))) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EApp (EApp (EVar "GBind") (EVar "p")) (EVar "e2")) (EVar "rest2")) (EVar "scope2")))))
(DTypeSig false "stampGuardArm" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "GuardArm") (TyCon "GuardArm"))))
(DFunDef false "stampGuardArm" ((PVar "env") (PCon "GuardArm" (PVar "gs") (PVar "body"))) (EBlock (DoLet false false (PTuple (PVar "gs2") (PVar "scope2")) (EApp (EApp (EVar "stampGuards") (EVar "env")) (EVar "gs"))) (DoExpr (EApp (EApp (EVar "GuardArm") (EVar "gs2")) (EApp (EApp (EVar "stampExpr") (EVar "scope2")) (EVar "body"))))))
(DTypeSig false "stampStmts" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyApp (TyCon "List") (TyCon "DoStmt")))))
(DFunDef false "stampStmts" (PWild (PList)) (EListLit))
(DFunDef false "stampStmts" ((PVar "env") (PCons (PCon "DoExpr" (PVar "e")) (PVar "rest"))) (EBinOp "::" (EApp (EVar "DoExpr") (EApp (EApp (EVar "stampExpr") (EVar "env")) (EVar "e"))) (EApp (EApp (EVar "stampStmts") (EVar "env")) (EVar "rest"))))
(DFunDef false "stampStmts" ((PVar "env") (PCons (PCon "DoLet" (PVar "m") (PVar "r") (PVar "p") (PVar "e")) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "DoLet") (EVar "m")) (EVar "r")) (EVar "p")) (EApp (EApp (EVar "stampExpr") (EVar "env")) (EVar "e"))) (EApp (EApp (EVar "stampStmts") (EApp (EApp (EVar "insertZero") (EApp (EVar "patBindings") (EVar "p"))) (EVar "env"))) (EVar "rest"))))
(DFunDef false "stampStmts" ((PVar "env") (PCons (PCon "DoBind" (PVar "p") (PVar "e")) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EVar "DoBind") (EVar "p")) (EApp (EApp (EVar "stampExpr") (EVar "env")) (EVar "e"))) (EApp (EApp (EVar "stampStmts") (EApp (EApp (EVar "insertZero") (EApp (EVar "patBindings") (EVar "p"))) (EVar "env"))) (EVar "rest"))))
(DFunDef false "stampStmts" ((PVar "env") (PCons (PCon "DoAssign" (PVar "x") (PVar "e")) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EVar "DoAssign") (EVar "x")) (EApp (EApp (EVar "stampExpr") (EVar "env")) (EVar "e"))) (EApp (EApp (EVar "stampStmts") (EApp (EApp (EVar "insertZero") (EListLit (EVar "x"))) (EVar "env"))) (EVar "rest"))))
(DFunDef false "stampStmts" ((PVar "env") (PCons (PCon "DoFieldAssign" (PVar "x") (PVar "fs") (PVar "e")) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EApp (EVar "DoFieldAssign") (EVar "x")) (EVar "fs")) (EApp (EApp (EVar "stampExpr") (EVar "env")) (EVar "e"))) (EApp (EApp (EVar "stampStmts") (EVar "env")) (EVar "rest"))))
(DTypeSig false "stampInterp" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "InterpPart") (TyCon "InterpPart"))))
(DFunDef false "stampInterp" (PWild (PCon "InterpStr" (PVar "s"))) (EApp (EVar "InterpStr") (EVar "s")))
(DFunDef false "stampInterp" ((PVar "env") (PCon "InterpExpr" (PVar "e"))) (EApp (EVar "InterpExpr") (EApp (EApp (EVar "stampExpr") (EVar "env")) (EVar "e"))))
(DTypeSig false "stampFieldAssign" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "FieldAssign") (TyCon "FieldAssign"))))
(DFunDef false "stampFieldAssign" ((PVar "env") (PCon "FieldAssign" (PVar "n") (PVar "e"))) (EApp (EApp (EVar "FieldAssign") (EVar "n")) (EApp (EApp (EVar "stampExpr") (EVar "env")) (EVar "e"))))
(DTypeSig false "stampKv" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyTuple (TyCon "Expr") (TyCon "Expr")) (TyTuple (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "stampKv" ((PVar "env") (PTuple (PVar "k") (PVar "v"))) (ETuple (EApp (EApp (EVar "stampExpr") (EVar "env")) (EVar "k")) (EApp (EApp (EVar "stampExpr") (EVar "env")) (EVar "v"))))
(DTypeSig false "stampSection" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "Section") (TyCon "Section"))))
(DFunDef false "stampSection" (PWild (PCon "SecBare" (PVar "op"))) (EApp (EVar "SecBare") (EVar "op")))
(DFunDef false "stampSection" ((PVar "env") (PCon "SecRight" (PVar "op") (PVar "e"))) (EApp (EApp (EVar "SecRight") (EVar "op")) (EApp (EApp (EVar "stampExpr") (EVar "env")) (EVar "e"))))
(DFunDef false "stampSection" ((PVar "env") (PCon "SecLeft" (PVar "e") (PVar "op"))) (EApp (EApp (EVar "SecLeft") (EApp (EApp (EVar "stampExpr") (EVar "env")) (EVar "e"))) (EVar "op")))
(DTypeSig false "stampDecl" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "Decl") (TyCon "Decl"))))
(DFunDef false "stampDecl" ((PVar "top") (PCon "DFunDef" (PVar "p") (PVar "n") (PVar "pats") (PVar "body"))) (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "p")) (EVar "n")) (EVar "pats")) (EApp (EApp (EVar "stampExpr") (EApp (EApp (EVar "insertParams") (EVar "pats")) (EVar "top"))) (EVar "body"))))
(DFunDef false "stampDecl" ((PVar "top") (PCon "DProp" (PVar "p") (PVar "n") (PVar "params") (PVar "body"))) (EApp (EApp (EApp (EApp (EVar "DProp") (EVar "p")) (EVar "n")) (EVar "params")) (EApp (EApp (EVar "stampExpr") (EApp (EApp (EVar "insertZero") (EApp (EApp (EVar "map") (EVar "propParamName")) (EVar "params"))) (EVar "top"))) (EVar "body"))))
(DFunDef false "stampDecl" ((PVar "top") (PCon "DTest" (PVar "p") (PVar "n") (PVar "body"))) (EApp (EApp (EApp (EVar "DTest") (EVar "p")) (EVar "n")) (EApp (EApp (EVar "stampExpr") (EVar "top")) (EVar "body"))))
(DFunDef false "stampDecl" ((PVar "top") (PCon "DBench" (PVar "p") (PVar "n") (PVar "body"))) (EApp (EApp (EApp (EVar "DBench") (EVar "p")) (EVar "n")) (EApp (EApp (EVar "stampExpr") (EVar "top")) (EVar "body"))))
(DFunDef false "stampDecl" ((PVar "top") (PCon "DLetGroup" (PVar "p") (PVar "binds"))) (EApp (EApp (EVar "DLetGroup") (EVar "p")) (EApp (EApp (EVar "map") (EApp (EVar "stampLetBind") (EVar "top"))) (EVar "binds"))))
(DFunDef false "stampDecl" ((PVar "top") (PAs "d" (PRec "DInterface" ((rf "methods" None)) true))) (EVariantUpdate "DInterface" (EVar "d") ((fa "methods" (EApp (EApp (EVar "map") (EApp (EVar "stampIfaceMethod") (EVar "top"))) (EVar "methods"))))))
(DFunDef false "stampDecl" ((PVar "top") (PAs "d" (PRec "DImpl" ((rf "methods" None)) true))) (EVariantUpdate "DImpl" (EVar "d") ((fa "methods" (EApp (EApp (EVar "map") (EApp (EVar "stampImplMethod") (EVar "top"))) (EVar "methods"))))))
(DFunDef false "stampDecl" ((PVar "top") (PCon "DAttrib" (PVar "attrs") (PVar "inner"))) (EApp (EApp (EVar "DAttrib") (EVar "attrs")) (EApp (EApp (EVar "stampDecl") (EVar "top")) (EVar "inner"))))
(DFunDef false "stampDecl" (PWild (PVar "d")) (EVar "d"))
(DTypeSig false "stampIfaceMethod" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "IfaceMethod") (TyCon "IfaceMethod"))))
(DFunDef false "stampIfaceMethod" (PWild (PCon "IfaceMethod" (PVar "nm") (PVar "ty") (PCon "None") (PVar "mloc"))) (EApp (EApp (EApp (EApp (EVar "IfaceMethod") (EVar "nm")) (EVar "ty")) (EVar "None")) (EVar "mloc")))
(DFunDef false "stampIfaceMethod" ((PVar "top") (PCon "IfaceMethod" (PVar "nm") (PVar "ty") (PCon "Some" (PCon "MethodDefault" (PVar "pats") (PVar "body"))) (PVar "mloc"))) (EApp (EApp (EApp (EApp (EVar "IfaceMethod") (EVar "nm")) (EVar "ty")) (EApp (EVar "Some") (EApp (EApp (EVar "MethodDefault") (EVar "pats")) (EApp (EApp (EVar "stampExpr") (EApp (EApp (EVar "insertParams") (EVar "pats")) (EVar "top"))) (EVar "body"))))) (EVar "mloc")))
(DTypeSig false "stampImplMethod" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "ImplMethod") (TyCon "ImplMethod"))))
(DFunDef false "stampImplMethod" ((PVar "top") (PCon "ImplMethod" (PVar "nm") (PVar "pats") (PVar "body"))) (EApp (EApp (EApp (EVar "ImplMethod") (EVar "nm")) (EVar "pats")) (EApp (EApp (EVar "stampExpr") (EApp (EApp (EVar "insertParams") (EVar "pats")) (EVar "top"))) (EVar "body"))))
(DTypeSig true "stampBindingIds" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))))))
(DFunDef false "stampBindingIds" ((PVar "decls")) (EBlock (DoLet false false (PVar "top") (EApp (EApp (EVar "numberFrom") (ELit (LInt 1))) (EApp (EVar "dedup") (EApp (EVar "topBinderNames") (EVar "decls"))))) (DoExpr (ETuple (EApp (EApp (EVar "map") (EApp (EVar "stampDecl") (EApp (EApp (EVar "omFromPairs") (EVar "top")) (EVar "omEmpty")))) (EVar "decls")) (EVar "top")))))
(DTypeSig false "tyOriginScope" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "OrdMap") (TyCon "TyConOrigin")))))))
(DFunDef false "tyOriginScope" ((PVar "coreTypes") (PVar "known") (PVar "mid") (PVar "prog")) (EBlock (DoLet false false (PVar "builtinLayer") (EVar "builtinTyOrigins")) (DoLet false false (PVar "preludeLayer") (EApp (EApp (EVar "map") (EVar "importedTyOrigin")) (EVar "coreTypes"))) (DoLet false false (PVar "importLayer") (EApp (EApp (EVar "map") (EVar "importedTyOrigin")) (EApp (EApp (EVar "flatMap") (EApp (EVar "importedTypeOrigins") (EVar "known"))) (EApp (EVar "usePathsOf") (EVar "prog"))))) (DoLet false false (PVar "ownLayer") (EBinOp "++" (EApp (EApp (EVar "map") (EApp (EVar "ownTyOrigin") (EVar "mid"))) (EApp (EVar "dataRecordNames") (EVar "prog"))) (EApp (EApp (EVar "map") (EApp (EVar "ownIfaceOrigin") (EVar "mid"))) (EApp (EVar "interfaceNamesOf") (EVar "prog"))))) (DoExpr (EApp (EApp (EVar "omFromPairs") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EVar "builtinLayer") (EVar "preludeLayer")) (EVar "importLayer")) (EVar "ownLayer"))) (EVar "omEmpty")))))
(DTypeSig false "ownTyOrigin" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyTuple (TyCon "String") (TyCon "TyConOrigin")))))
(DFunDef false "ownTyOrigin" ((PVar "mid") (PVar "n")) (ETuple (EVar "n") (EApp (EVar "OriginModule") (EVar "mid"))))
(DTypeSig false "importedTyOrigin" (TyFun (TyTuple (TyCon "String") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "TyConOrigin"))))
(DFunDef false "importedTyOrigin" ((PTuple (PVar "n") (PVar "definer"))) (ETuple (EVar "n") (EApp (EVar "OriginModule") (EVar "definer"))))
(DTypeSig false "builtinTyOrigins" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TyConOrigin"))))
(DFunDef false "builtinTyOrigins" () (EApp (EApp (EVar "map") (EVar "builtinTyOrigin")) (EBinOp "++" (EVar "primitiveTypes") (EVar "tupleCtorTyNames"))))
(DTypeSig false "builtinTyOrigin" (TyFun (TyCon "String") (TyTuple (TyCon "String") (TyCon "TyConOrigin"))))
(DFunDef false "builtinTyOrigin" ((PVar "n")) (ETuple (EVar "n") (EVar "OriginBuiltin")))
(DTypeSig false "typeOriginExports" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "typeOriginExports" ((PVar "known") (PVar "mid") (PVar "prog")) (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "flatMap") (EApp (EVar "importedTypeOrigins") (EVar "known"))) (EApp (EVar "pubUsePaths") (EVar "prog"))) (EApp (EApp (EVar "map") (EApp (EVar "typeDeclaredIn") (EVar "mid"))) (EApp (EVar "expTypesDirect") (EVar "prog")))) (EApp (EApp (EVar "map") (EApp (EVar "ifaceDeclaredIn") (EVar "mid"))) (EApp (EVar "expInterfacesDirect") (EVar "prog")))))
(DTypeSig false "typeDeclaredIn" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "typeDeclaredIn" ((PVar "mid") (PVar "n")) (ETuple (EVar "n") (EVar "mid")))
(DTypeSig false "importedTypeOrigins" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyFun (TyCon "UsePath") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "importedTypeOrigins" ((PVar "known") (PVar "path")) (EIf (EBinOp "==" (EApp (EVar "useModId") (EVar "path")) (ELit (LString "core"))) (EListLit) (EMatch (EApp (EApp (EVar "omLookup") (EApp (EVar "useModId") (EVar "path"))) (EVar "known")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "src")) () (EApp (EApp (EVar "importedTypeOriginsFrom") (EVar "path")) (EVar "src"))))))
(DTypeSig false "importedTypeOriginsFrom" (TyFun (TyCon "UsePath") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "importedTypeOriginsFrom" ((PCon "UseName" (PVar "ns")) (PVar "src")) (EIf (EBinOp ">" (EApp (EVar "listLen") (EVar "ns")) (ELit (LInt 1))) (EApp (EApp (EVar "keepTypeOrigins") (EVar "src")) (EListLit (ETuple (EApp (EVar "lastOf") (EVar "ns")) (EApp (EVar "lastOf") (EVar "ns"))))) (EListLit)))
(DFunDef false "importedTypeOriginsFrom" ((PCon "UseGroup" PWild (PVar "members")) (PVar "src")) (EApp (EApp (EVar "keepTypeOrigins") (EVar "src")) (EApp (EApp (EVar "map") (EVar "useMemberBinding")) (EVar "members"))))
(DFunDef false "importedTypeOriginsFrom" ((PCon "UseWild" PWild) (PVar "src")) (EVar "src"))
(DFunDef false "importedTypeOriginsFrom" ((PCon "UseAlias" PWild PWild) PWild) (EListLit))
(DTypeSig false "useMemberBinding" (TyFun (TyCon "UseMember") (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "useMemberBinding" ((PAs "m" (PCon "UseMember" (PVar "name") PWild PWild PWild))) (ETuple (EVar "name") (EApp (EVar "useMemberLocal") (EVar "m"))))
(DTypeSig false "keepTypeOrigins" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "keepTypeOrigins" ((PVar "src") (PVar "bindings")) (EBlock (DoLet false false (PVar "definers") (EApp (EApp (EVar "omFromPairs") (EVar "src")) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EVar "flatMap") (EApp (EVar "bindTypeOrigin") (EVar "definers"))) (EVar "bindings")))))
(DTypeSig false "bindTypeOrigin" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "bindTypeOrigin" ((PVar "definers") (PTuple (PVar "origin") (PVar "local"))) (EBinOp "++" (EApp (EApp (EApp (EVar "bindOneOrigin") (EVar "definers")) (EVar "origin")) (EVar "local")) (EApp (EApp (EApp (EVar "bindOneOrigin") (EVar "definers")) (EApp (EVar "ifaceKey") (EVar "origin"))) (EApp (EVar "ifaceKey") (EVar "local")))))
(DTypeSig false "bindOneOrigin" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "bindOneOrigin" ((PVar "definers") (PVar "key") (PVar "local")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "key")) (EVar "definers")) (arm (PCon "Some" (PVar "definer")) () (EListLit (ETuple (EVar "local") (EVar "definer")))) (arm (PCon "None") () (EListLit))))
(DTypeSig true "stampTyOrigins" (TyFun (TyApp (TyCon "OrdMap") (TyCon "TyConOrigin")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "stampTyOrigins" ((PVar "scope") (PVar "decls")) (EApp (EApp (EVar "map") (EApp (EVar "stampDeclTyOrigins") (EVar "scope"))) (EVar "decls")))
(DTypeSig false "stampDeclTyOrigins" (TyFun (TyApp (TyCon "OrdMap") (TyCon "TyConOrigin")) (TyFun (TyCon "Decl") (TyCon "Decl"))))
(DFunDef false "stampDeclTyOrigins" ((PVar "scope") (PVar "d")) (EApp (EApp (EApp (EVar "mapOriginsInDecl") (EApp (EVar "stampTyHead") (EVar "scope"))) (EApp (EVar "fillIfaceOccOrigin") (EVar "scope"))) (EVar "d")))
(DTypeSig false "stampTyHead" (TyFun (TyApp (TyCon "OrdMap") (TyCon "TyConOrigin")) (TyFun (TyCon "Ty") (TyTuple (TyCon "Ty") (TyCon "Bool")))))
(DFunDef false "stampTyHead" ((PVar "scope") (PAs "t" (PRec "TyCon" ((rf "tyConName" (PVar "n")) (rf "tyConOrigin" (PVar "o"))) false))) (EMatch (EVar "o") (arm (PCon "OriginUnresolved") () (EApp (EApp (EVar "stampHeadWith") (EVar "t")) (EApp (EApp (EVar "originOfTyName") (EVar "scope")) (EVar "n")))) (arm (PCon "OriginBuiltin") () (ETuple (EVar "t") (EVar "False"))) (arm (PCon "OriginModule" PWild) () (ETuple (EVar "t") (EVar "False")))))
(DFunDef false "stampTyHead" (PWild (PVar "t")) (ETuple (EVar "t") (EVar "False")))
(DTypeSig false "originOfTyName" (TyFun (TyApp (TyCon "OrdMap") (TyCon "TyConOrigin")) (TyFun (TyCon "String") (TyCon "TyConOrigin"))))
(DFunDef false "originOfTyName" ((PVar "scope") (PVar "n")) (EApp (EApp (EVar "optionOr") (EVar "OriginUnresolved")) (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "scope"))))
(DTypeSig false "stampHeadWith" (TyFun (TyCon "Ty") (TyFun (TyCon "TyConOrigin") (TyTuple (TyCon "Ty") (TyCon "Bool")))))
(DFunDef false "stampHeadWith" ((PVar "t") (PCon "OriginUnresolved")) (ETuple (EVar "t") (EVar "False")))
(DFunDef false "stampHeadWith" ((PVar "t") (PVar "o")) (ETuple (EVariantUpdate "TyCon" (EVar "t") ((fa "tyConOrigin" (EVar "o")))) (EVar "True")))
(DTypeSig true "stampDeclOrigins" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "stampDeclOrigins" ((PVar "mid") (PVar "decls")) (EApp (EApp (EVar "map") (EApp (EVar "stampDeclOrigin") (EVar "mid"))) (EVar "decls")))
(DTypeSig false "stampDeclOrigin" (TyFun (TyCon "String") (TyFun (TyCon "Decl") (TyCon "Decl"))))
(DFunDef false "stampDeclOrigin" ((PVar "mid") (PAs "d" (PRec "DData" ((rf "dataOrigin" (PVar "o"))) false))) (EVariantUpdate "DData" (EVar "d") ((fa "dataOrigin" (EApp (EApp (EVar "fillDeclOrigin") (EVar "mid")) (EVar "o"))))))
(DFunDef false "stampDeclOrigin" ((PVar "mid") (PAs "d" (PRec "DNewtype" ((rf "newtypeOrigin" (PVar "o"))) false))) (EVariantUpdate "DNewtype" (EVar "d") ((fa "newtypeOrigin" (EApp (EApp (EVar "fillDeclOrigin") (EVar "mid")) (EVar "o"))))))
(DFunDef false "stampDeclOrigin" ((PVar "mid") (PAs "d" (PRec "DTypeAlias" ((rf "tyAliasOrigin" (PVar "o"))) false))) (EVariantUpdate "DTypeAlias" (EVar "d") ((fa "tyAliasOrigin" (EApp (EApp (EVar "fillDeclOrigin") (EVar "mid")) (EVar "o"))))))
(DFunDef false "stampDeclOrigin" ((PVar "mid") (PAs "d" (PRec "DInterface" ((rf "ifaceOrigin" (PVar "o"))) false))) (EVariantUpdate "DInterface" (EVar "d") ((fa "ifaceOrigin" (EApp (EApp (EVar "fillDeclOrigin") (EVar "mid")) (EVar "o"))))))
(DFunDef false "stampDeclOrigin" ((PVar "mid") (PCon "DAttrib" (PVar "attrs") (PVar "d"))) (EApp (EApp (EVar "DAttrib") (EVar "attrs")) (EApp (EApp (EVar "stampDeclOrigin") (EVar "mid")) (EVar "d"))))
(DFunDef false "stampDeclOrigin" (PWild (PVar "d")) (EVar "d"))
(DTypeSig false "fillDeclOrigin" (TyFun (TyCon "String") (TyFun (TyCon "TyConOrigin") (TyCon "TyConOrigin"))))
(DFunDef false "fillDeclOrigin" ((PVar "mid") (PCon "OriginUnresolved")) (EIf (EBinOp "==" (EVar "mid") (ELit (LString ""))) (EVar "OriginUnresolved") (EApp (EVar "OriginModule") (EVar "mid"))))
(DFunDef false "fillDeclOrigin" (PWild (PCon "OriginBuiltin")) (EVar "OriginBuiltin"))
(DFunDef false "fillDeclOrigin" (PWild (PAs "o" (PCon "OriginModule" PWild))) (EVar "o"))
(DTypeSig true "mapOriginsInDecl" (TyFun (TyFun (TyCon "Ty") (TyTuple (TyCon "Ty") (TyCon "Bool"))) (TyFun (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "TyConOrigin") (TyCon "TyConOrigin")))) (TyFun (TyCon "Decl") (TyCon "Decl")))))
(DFunDef false "mapOriginsInDecl" ((PVar "fTy") (PVar "fIface") (PVar "d")) (EApp (EApp (EVar "mapIfaceOccDeclLocal") (EVar "fIface")) (EApp (EVar "fst") (EApp (EApp (EVar "mapTyInDecl") (EApp (EApp (EVar "mapOriginsInTy") (EVar "fTy")) (EVar "fIface"))) (EVar "d")))))
(DTypeSig false "mapOriginsInTy" (TyFun (TyFun (TyCon "Ty") (TyTuple (TyCon "Ty") (TyCon "Bool"))) (TyFun (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "TyConOrigin") (TyCon "TyConOrigin")))) (TyFun (TyCon "Ty") (TyTuple (TyCon "Ty") (TyCon "Bool"))))))
(DFunDef false "mapOriginsInTy" ((PVar "fTy") (PVar "fIface") (PCon "TyConstrained" (PVar "cs") (PVar "t"))) (EApp (EVar "fTy") (EApp (EApp (EVar "TyConstrained") (EApp (EApp (EVar "map") (EApp (EVar "mapConstraintOcc") (EVar "fIface"))) (EVar "cs"))) (EVar "t"))))
(DFunDef false "mapOriginsInTy" ((PVar "fTy") PWild (PVar "t")) (EApp (EVar "fTy") (EVar "t")))
(DTypeSig false "mapConstraintOcc" (TyFun (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "TyConOrigin") (TyCon "TyConOrigin")))) (TyFun (TyCon "Constraint") (TyCon "Constraint"))))
(DFunDef false "mapConstraintOcc" ((PVar "f") (PAs "c" (PRec "Constraint" ((rf "constraintHead" (PVar "n")) (rf "constraintOrigin" (PVar "o"))) false))) (EVariantUpdate "Constraint" (EVar "c") ((fa "constraintOrigin" (EApp (EApp (EApp (EVar "f") (ELit (LString "constraintOrigin"))) (EVar "n")) (EVar "o"))))))
(DTypeSig false "mapSuperOcc" (TyFun (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "TyConOrigin") (TyCon "TyConOrigin")))) (TyFun (TyCon "Super") (TyCon "Super"))))
(DFunDef false "mapSuperOcc" ((PVar "f") (PAs "s" (PRec "Super" ((rf "superHead" (PVar "n")) (rf "superOrigin" (PVar "o"))) false))) (EVariantUpdate "Super" (EVar "s") ((fa "superOrigin" (EApp (EApp (EApp (EVar "f") (ELit (LString "superOrigin"))) (EVar "n")) (EVar "o"))))))
(DTypeSig false "mapRequireOcc" (TyFun (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "TyConOrigin") (TyCon "TyConOrigin")))) (TyFun (TyCon "Require") (TyCon "Require"))))
(DFunDef false "mapRequireOcc" ((PVar "f") (PAs "r" (PRec "Require" ((rf "requireHead" (PVar "n")) (rf "requireOrigin" (PVar "o"))) false))) (EVariantUpdate "Require" (EVar "r") ((fa "requireOrigin" (EApp (EApp (EApp (EVar "f") (ELit (LString "requireOrigin"))) (EVar "n")) (EVar "o"))))))
(DTypeSig false "mapIfaceOccDeclLocal" (TyFun (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "TyConOrigin") (TyCon "TyConOrigin")))) (TyFun (TyCon "Decl") (TyCon "Decl"))))
(DFunDef false "mapIfaceOccDeclLocal" ((PVar "f") (PAs "d" (PRec "DInterface" ((rf "ifaceOrigin" PWild) (rf "supers" None)) false))) (EVariantUpdate "DInterface" (EVar "d") ((fa "supers" (EApp (EApp (EVar "map") (EApp (EVar "mapSuperOcc") (EVar "f"))) (EVar "supers"))))))
(DFunDef false "mapIfaceOccDeclLocal" ((PVar "f") (PAs "d" (PRec "DImpl" ((rf "implOrigin" (PVar "o")) (rf "iface" (PVar "n")) (rf "reqs" None)) false))) (EVariantUpdate "DImpl" (EVar "d") ((fa "implOrigin" (EApp (EApp (EApp (EVar "f") (ELit (LString "implOrigin"))) (EVar "n")) (EVar "o"))) (fa "reqs" (EApp (EApp (EVar "map") (EApp (EVar "mapRequireOcc") (EVar "f"))) (EVar "reqs"))))))
(DFunDef false "mapIfaceOccDeclLocal" ((PVar "f") (PCon "DAttrib" (PVar "attrs") (PVar "d"))) (EApp (EApp (EVar "DAttrib") (EVar "attrs")) (EApp (EApp (EVar "mapIfaceOccDeclLocal") (EVar "f")) (EVar "d"))))
(DFunDef false "mapIfaceOccDeclLocal" (PWild (PVar "d")) (EVar "d"))
(DTypeSig false "fillIfaceOccOrigin" (TyFun (TyApp (TyCon "OrdMap") (TyCon "TyConOrigin")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "TyConOrigin") (TyCon "TyConOrigin"))))))
(DFunDef false "fillIfaceOccOrigin" ((PVar "scope") PWild (PVar "n") (PCon "OriginUnresolved")) (EApp (EApp (EVar "optionOr") (EVar "OriginUnresolved")) (EApp (EApp (EVar "omLookup") (EApp (EVar "ifaceKey") (EVar "n"))) (EVar "scope"))))
(DFunDef false "fillIfaceOccOrigin" (PWild PWild PWild (PCon "OriginBuiltin")) (EVar "OriginBuiltin"))
(DFunDef false "fillIfaceOccOrigin" (PWild PWild PWild (PAs "o" (PCon "OriginModule" PWild))) (EVar "o"))
(DTypeSig true "ifaceKey" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "ifaceKey" ((PVar "n")) (EBinOp "++" (EBinOp "++" (ELit (LString "iface:")) (EApp (EVar "display") (EVar "n"))) (ELit (LString ""))))
(DTypeSig false "ifaceDeclaredIn" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "ifaceDeclaredIn" ((PVar "mid") (PVar "n")) (ETuple (EApp (EVar "ifaceKey") (EVar "n")) (EVar "mid")))
(DTypeSig false "ownIfaceOrigin" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyTuple (TyCon "String") (TyCon "TyConOrigin")))))
(DFunDef false "ownIfaceOrigin" ((PVar "mid") (PVar "n")) (ETuple (EApp (EVar "ifaceKey") (EVar "n")) (EApp (EVar "OriginModule") (EVar "mid"))))
(DTypeSig false "interfaceNamesOf" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "interfaceNamesOf" ((PList)) (EListLit))
(DFunDef false "interfaceNamesOf" ((PCons (PRec "DInterface" ((rf "name" (PVar "n")) (rf "ifaceOrigin" PWild)) false) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "interfaceNamesOf") (EVar "rest"))))
(DFunDef false "interfaceNamesOf" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "interfaceNamesOf") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "interfaceNamesOf" ((PCons PWild (PVar "rest"))) (EApp (EVar "interfaceNamesOf") (EVar "rest")))
(DTypeSig true "stampGraphTyOrigins" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))))))
(DFunDef false "stampGraphTyOrigins" ((PVar "coreDecls") (PVar "modules")) (EBlock (DoLet false false (PVar "coreTypes") (EBinOp "++" (EApp (EApp (EVar "map") (EApp (EVar "typeDeclaredIn") (ELit (LString "core")))) (EApp (EVar "dataRecordNames") (EVar "coreDecls"))) (EApp (EApp (EVar "map") (EApp (EVar "ifaceDeclaredIn") (ELit (LString "core")))) (EApp (EVar "interfaceNamesOf") (EVar "coreDecls"))))) (DoLet false false (PVar "coreS") (EApp (EApp (EApp (EApp (EVar "stampOneModule") (EVar "coreTypes")) (EVar "omEmpty")) (ELit (LString "core"))) (EVar "coreDecls"))) (DoExpr (ETuple (EVar "coreS") (EApp (EApp (EApp (EVar "stampModulesGo") (EVar "coreTypes")) (EVar "omEmpty")) (EVar "modules"))))))
(DTypeSig false "stampOneModule" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "stampOneModule" ((PVar "coreTypes") (PVar "known") (PVar "mid") (PVar "prog")) (EApp (EApp (EVar "stampTyOrigins") (EApp (EApp (EApp (EApp (EVar "tyOriginScope") (EVar "coreTypes")) (EVar "known")) (EVar "mid")) (EVar "prog"))) (EApp (EApp (EVar "stampDeclOrigins") (EVar "mid")) (EVar "prog"))))
(DTypeSig false "stampModulesGo" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))))))
(DFunDef false "stampModulesGo" (PWild PWild (PList)) (EListLit))
(DFunDef false "stampModulesGo" ((PVar "coreTypes") (PVar "known") (PCons (PTuple (PVar "mid") (PVar "prog")) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "mid") (EApp (EApp (EApp (EApp (EVar "stampOneModule") (EVar "coreTypes")) (EVar "known")) (EVar "mid")) (EVar "prog"))) (EApp (EApp (EApp (EVar "stampModulesGo") (EVar "coreTypes")) (EApp (EApp (EApp (EVar "omInsert") (EVar "mid")) (EApp (EApp (EApp (EVar "typeOriginExports") (EVar "known")) (EVar "mid")) (EVar "prog"))) (EVar "known"))) (EVar "rest"))))
(DTypeSig true "stampFlatTyOrigins" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "stampFlatTyOrigins" ((PVar "coreDecls") (PVar "prog")) (EApp (EApp (EVar "stampTyOrigins") (EApp (EVar "flatTyOriginScope") (EVar "coreDecls"))) (EVar "prog")))
(DTypeSig false "flatTyOriginScope" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "OrdMap") (TyCon "TyConOrigin"))))
(DFunDef false "flatTyOriginScope" ((PVar "coreDecls")) (EApp (EApp (EVar "omFromPairs") (EApp (EApp (EVar "map") (EVar "importedTyOrigin")) (EBinOp "++" (EApp (EApp (EVar "map") (EApp (EVar "typeDeclaredIn") (ELit (LString "core")))) (EApp (EVar "dataRecordNames") (EVar "coreDecls"))) (EApp (EApp (EVar "map") (EApp (EVar "ifaceDeclaredIn") (ELit (LString "core")))) (EApp (EVar "interfaceNamesOf") (EVar "coreDecls")))))) (EApp (EApp (EVar "omFromPairs") (EVar "builtinTyOrigins")) (EVar "omEmpty"))))
(DTypeSig true "externTyOriginScope" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "OrdMap") (TyCon "TyConOrigin"))))
(DFunDef false "externTyOriginScope" ((PVar "coreDecls")) (EApp (EVar "flatTyOriginScope") (EVar "coreDecls")))
(DTypeSig false "originTraceEnabled" (TyApp (TyCon "Ref") (TyCon "Bool")))
(DFunDef false "originTraceEnabled" () (EApp (EVar "Ref") (EVar "False")))
(DTypeSig false "originTraceLog" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "originTraceLog" () (EApp (EVar "Ref") (EListLit)))
(DTypeSig true "setOriginTrace" (TyFun (TyCon "Bool") (TyCon "Unit")))
(DFunDef false "setOriginTrace" ((PVar "b")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EVar "originTraceLog")) (EListLit))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "originTraceEnabled")) (EVar "b")))))
(DTypeSig true "noteOriginTrace" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Unit"))))
(DFunDef false "noteOriginTrace" ((PVar "label") (PVar "decls")) (EIf (EUnOp "!" (EVar "originTraceEnabled")) (EApp (EApp (EVar "setRef") (EVar "originTraceLog")) (EBinOp "++" (EUnOp "!" (EVar "originTraceLog")) (EListLit (ETuple (EVar "label") (EVar "decls"))))) (ELit LUnit)))
(DTypeSig true "takeOriginTrace" (TyFun (TyCon "Unit") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "takeOriginTrace" (PWild) (EBlock (DoLet false false (PVar "rows") (EUnOp "!" (EVar "originTraceLog"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "originTraceLog")) (EListLit))) (DoExpr (EVar "rows"))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "orElseLoc" false) (mem "Lit" true) (mem "Ty" true) (mem "TyConOrigin" true) (mem "mapTyInDecl" false) (mem "firstTyLoc" false) (mem "firstTyLocList" false) (mem "Constraint" true) (mem "Addr" true) (mem "Pat" true) (mem "RecPatField" true) (mem "Guard" true) (mem "Arm" true) (mem "DoStmt" true) (mem "InterpPart" true) (mem "GuardArm" true) (mem "FieldAssign" true) (mem "Section" true) (mem "FunClause" true) (mem "LetBind" true) (mem "Expr" true) (mem "UseMember" true) (mem "UsePath" true) (mem "useMemberLocal" false) (mem "qualifiedLocal" false) (mem "PropParam" true) (mem "MethodDefault" true) (mem "IfaceMethod" true) (mem "Super" true) (mem "Require" true) (mem "ImplMethod" true) (mem "DataVis" true) (mem "Field" true) (mem "ConPayload" true) (mem "Variant" true) (mem "Decl" true))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omInsert" false) (mem "omHasKey" false) (mem "omDelete" false) (mem "omLookup" false) (mem "omFromNames" false) (mem "omFromPairs" false) (mem "omKeys" false) (mem "omSize" false) (mem "omMapValues" false))))
(DUse false (UseGroup ("support" "opcount") ((mem "opBump" false))))
(DUse false (UseGroup ("support" "util") ((mem "contains" false) (mem "editDistance" false) (mem "minI" false) (mem "maxI" false) (mem "listLen" false) (mem "escStr" false) (mem "joinNl" false) (mem "joinWith" false) (mem "lookupAssoc" false) (mem "reverseL" false) (mem "initList" false) (mem "joinDot" false) (mem "filterList" false) (mem "anyList" false) (mem "dedup" false) (mem "dedupBy" false))))
(DData Public "ResError" () ((variant "UnboundVariable" (ConPos (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")) (TyApp (TyCon "Option") (TyCon "String")))) (variant "UnboundVariableExported" (ConPos (TyCon "String") (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "UnboundVariableIsModule" (ConPos (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "UnknownConstructor" (ConPos (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")) (TyApp (TyCon "Option") (TyCon "String")))) (variant "UnknownType" (ConPos (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")) (TyApp (TyCon "Option") (TyCon "String")))) (variant "UnknownEffect" (ConPos (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "UnknownField" (ConPos (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "FieldNotInRecord" (ConPos (TyCon "String") (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "DuplicateDefinition" (ConPos (TyCon "String") (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "UnknownInterface" (ConPos (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "MethodNotInInterface" (ConPos (TyCon "String") (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "ExternWithBody" (ConPos (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "PrivateNameAccess" (ConPos (TyCon "String") (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "NoExportedConstructors" (ConPos (TyCon "String") (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "NewtypeCtorNotExported" (ConPos (TyCon "String") (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "AbstractFieldAccess" (ConPos (TyCon "String") (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "UnknownModule" (ConPos (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "NonRecursiveValueLet" (ConPos (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "DuplicateBinding" (ConPos (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "DuplicateValueBinding" (ConPos (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "DuplicateSignature" (ConPos (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")) (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "DuplicateBinder" (ConPos (TyCon "String") (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "AsPatternMisplaced" (ConPos (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "AmbiguousOccurrence" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "AmbiguousConstructor" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "AmbiguousType" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "AmbiguousInterface" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "InternalExternAccess" (ConPos (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "ReassignImmutable" (ConPos (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))) (variant "DuplicateInterfaceMethod" (ConPos (TyCon "String") (TyCon "String") (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc"))))) ())
(DTypeSig true "resErrorDidYouMean" (TyFun (TyCon "ResError") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "resErrorDidYouMean" ((PCon "UnboundVariable" (PVar "n") PWild (PCon "Some" (PVar "sug")))) (EApp (EVar "Some") (ETuple (EVar "n") (EVar "sug"))))
(DFunDef false "resErrorDidYouMean" ((PCon "UnknownConstructor" (PVar "n") PWild (PCon "Some" (PVar "sug")))) (EApp (EVar "Some") (ETuple (EVar "n") (EVar "sug"))))
(DFunDef false "resErrorDidYouMean" ((PCon "UnknownType" (PVar "n") PWild (PCon "Some" (PVar "sug")))) (EApp (EVar "Some") (ETuple (EVar "n") (EVar "sug"))))
(DFunDef false "resErrorDidYouMean" (PWild) (EVar "None"))
(DTypeSig true "resErrorLoc" (TyFun (TyCon "ResError") (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "resErrorLoc" ((PCon "UnboundVariable" PWild (PVar "l") PWild)) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "UnboundVariableExported" PWild PWild (PVar "l"))) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "UnboundVariableIsModule" PWild (PVar "l"))) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "UnknownConstructor" PWild (PVar "l") PWild)) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "UnknownType" PWild (PVar "l") PWild)) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "UnknownEffect" PWild (PVar "l"))) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "UnknownField" PWild (PVar "l"))) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "FieldNotInRecord" PWild PWild (PVar "l"))) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "DuplicateDefinition" PWild PWild (PVar "l"))) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "UnknownInterface" PWild (PVar "l"))) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "MethodNotInInterface" PWild PWild (PVar "l"))) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "ExternWithBody" PWild (PVar "l"))) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "PrivateNameAccess" PWild PWild (PVar "l"))) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "NoExportedConstructors" PWild PWild (PVar "l"))) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "NewtypeCtorNotExported" PWild PWild (PVar "l"))) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "AbstractFieldAccess" PWild PWild (PVar "l"))) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "UnknownModule" PWild (PVar "l"))) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "NonRecursiveValueLet" PWild (PVar "l"))) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "DuplicateBinding" PWild (PVar "l"))) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "DuplicateValueBinding" PWild (PVar "l"))) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "DuplicateSignature" PWild (PVar "l") PWild)) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "DuplicateBinder" PWild PWild (PVar "l"))) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "AsPatternMisplaced" (PVar "l"))) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "AmbiguousOccurrence" PWild PWild (PVar "l"))) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "AmbiguousConstructor" PWild PWild (PVar "l"))) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "AmbiguousType" PWild PWild (PVar "l"))) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "AmbiguousInterface" PWild PWild (PVar "l"))) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "InternalExternAccess" PWild (PVar "l"))) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "ReassignImmutable" PWild (PVar "l"))) (EVar "l"))
(DFunDef false "resErrorLoc" ((PCon "DuplicateInterfaceMethod" PWild PWild PWild (PVar "l"))) (EVar "l"))
(DData Public "Env" () ((variant "Env" (ConNamed (field "values" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "types" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "ctors" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "fields" (TyApp (TyCon "List") (TyCon "String"))) (field "fieldOwners" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (field "fieldOwnersIdx" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String")))) (field "interfaces" (TyApp (TyCon "List") (TyCon "String"))) (field "ifaceMethods" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))) (field "effects" (TyApp (TyCon "List") (TyCon "String"))) (field "imported" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "importedModuleValues" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))) (field "ambiguous" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))) (field "ctorAmbiguous" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))) (field "typeAmbiguous" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))) (field "ifaceAmbiguous" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))) (field "internalGuard" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "sugValues" (TyApp (TyCon "List") (TyCon "SugCand"))) (field "sugTypes" (TyApp (TyCon "List") (TyCon "SugCand")))))) ())
(DTypeSig true "internalExterns" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "internalExterns" () (EListLit (ELit (LString "arrayGetUnsafe")) (ELit (LString "arraySetUnsafe")) (ELit (LString "arrayBlit")) (ELit (LString "arrayFill")) (ELit (LString "bytesToFloat64"))))
(DTypeSig true "internalGuardFor" (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "internalGuardFor" ((PCon "True")) (EListLit))
(DFunDef false "internalGuardFor" ((PCon "False")) (EVar "internalExterns"))
(DTypeSig false "buildFieldOwnerIndex" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "buildFieldOwnerIndex" ((PVar "pairs")) (EApp (EApp (EVar "omMapValues") (EVar "reverseL")) (EApp (EApp (EVar "indexOwners") (EVar "pairs")) (EVar "omEmpty"))))
(DTypeSig false "indexOwners" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "indexOwners" ((PList) (PVar "m")) (EVar "m"))
(DFunDef false "indexOwners" ((PCons (PTuple (PVar "f") (PVar "owner")) (PVar "rest")) (PVar "m")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "f")) (EVar "m")) (arm (PCon "Some" (PVar "os")) () (EApp (EApp (EVar "indexOwners") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "f")) (EBinOp "::" (EVar "owner") (EVar "os"))) (EVar "m")))) (arm (PCon "None") () (EApp (EApp (EVar "indexOwners") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "f")) (EListLit (EVar "owner"))) (EVar "m"))))))
(DTypeSig false "ownersOf" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "ownersOf" ((PVar "field") (PVar "idx")) (EBlock (DoLet false false PWild (EApp (EVar "opBump") (ELit LUnit))) (DoExpr (EMatch (EApp (EApp (EVar "omLookup") (EVar "field")) (EVar "idx")) (arm (PCon "Some" (PVar "owners")) () (EVar "owners")) (arm (PCon "None") () (EListLit))))))
(DTypeSig false "patBindings" (TyFun (TyCon "Pat") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "patBindings" ((PCon "PVar" (PVar "x") PWild)) (EListLit (EVar "x")))
(DFunDef false "patBindings" ((PCon "PWild")) (EListLit))
(DFunDef false "patBindings" ((PCon "PLit" PWild)) (EListLit))
(DFunDef false "patBindings" ((PCon "PCon" PWild (PVar "ps"))) (EApp (EApp (EDictApp "flatMap") (EVar "patBindings")) (EVar "ps")))
(DFunDef false "patBindings" ((PCon "PCons" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EVar "patBindings") (EVar "a")) (EApp (EVar "patBindings") (EVar "b"))))
(DFunDef false "patBindings" ((PCon "PTuple" (PVar "ps"))) (EApp (EApp (EDictApp "flatMap") (EVar "patBindings")) (EVar "ps")))
(DFunDef false "patBindings" ((PCon "PList" (PVar "ps"))) (EApp (EApp (EDictApp "flatMap") (EVar "patBindings")) (EVar "ps")))
(DFunDef false "patBindings" ((PCon "PAs" (PVar "x") PWild (PVar "p"))) (EBinOp "::" (EVar "x") (EApp (EVar "patBindings") (EVar "p"))))
(DFunDef false "patBindings" ((PCon "PRng" PWild PWild PWild)) (EListLit))
(DFunDef false "patBindings" ((PCon "PRec" PWild (PVar "fields") PWild)) (EApp (EApp (EDictApp "flatMap") (EVar "recFieldBindings")) (EVar "fields")))
(DTypeSig false "recFieldBindings" (TyFun (TyCon "RecPatField") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "recFieldBindings" ((PCon "RecPatField" (PVar "fname") PWild (PCon "None"))) (EListLit (EVar "fname")))
(DFunDef false "recFieldBindings" ((PCon "RecPatField" PWild PWild (PCon "Some" (PVar "p")))) (EApp (EVar "patBindings") (EVar "p")))
(DTypeSig false "patsBindings" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "patsBindings" ((PVar "ps")) (EApp (EApp (EDictApp "flatMap") (EVar "patBindings")) (EVar "ps")))
(DTypeSig false "patGroupDupErrors" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "patGroupDupErrors" ((PVar "loc") (PVar "kind") (PVar "ps")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "n")) (EApp (EApp (EApp (EVar "DuplicateBinder") (EVar "kind")) (EVar "n")) (EVar "loc")))) (EApp (EApp (EVar "findDups") (EListLit)) (EApp (EVar "patsBindings") (EVar "ps")))))
(DTypeSig false "checkType" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "checkType" ((PVar "cur") (PVar "env") (PRec "TyCon" ((rf "tyConName" (PVar "n")) (rf "tyConLoc" (PVar "loc"))) false)) (EIf (EBinOp "||" (EBinOp "||" (EApp (EApp (EVar "omHasKey") (EVar "n")) (EFieldAccess (EVar "env") "types")) (EApp (EApp (EVar "omHasKey") (EVar "n")) (EFieldAccess (EVar "env") "imported"))) (EApp (EVar "isTupleCtorTyName") (EVar "n"))) (EApp (EApp (EApp (EVar "ambiguousTypeErrors") (EVar "env")) (EVar "n")) (EApp (EApp (EVar "orElseLoc") (EVar "loc")) (EVar "cur"))) (EListLit (EApp (EApp (EApp (EVar "UnknownType") (EVar "n")) (EApp (EApp (EVar "orElseLoc") (EVar "loc")) (EVar "cur"))) (EApp (EApp (EVar "suggestType") (EVar "env")) (EVar "n"))))))
(DFunDef false "checkType" (PWild PWild (PCon "TyVar" PWild)) (EListLit))
(DFunDef false "checkType" ((PVar "cur") (PVar "env") (PCon "TyApp" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EApp (EApp (EVar "checkType") (EVar "cur")) (EVar "env")) (EVar "a")) (EApp (EApp (EApp (EVar "checkType") (EVar "cur")) (EVar "env")) (EVar "b"))))
(DFunDef false "checkType" ((PVar "cur") (PVar "env") (PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EApp (EApp (EVar "checkType") (EVar "cur")) (EVar "env")) (EVar "a")) (EApp (EApp (EApp (EVar "checkType") (EVar "cur")) (EVar "env")) (EVar "b"))))
(DFunDef false "checkType" ((PVar "cur") (PVar "env") (PCon "TyTuple" (PVar "ts"))) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "checkType") (EVar "cur")) (EVar "env"))) (EVar "ts")))
(DFunDef false "checkType" ((PVar "cur") (PVar "env") (PCon "TyEffect" (PVar "labels") PWild (PVar "t"))) (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "checkEffect") (EVar "cur")) (EVar "env"))) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "labels"))) (EApp (EApp (EApp (EVar "checkType") (EVar "cur")) (EVar "env")) (EVar "t"))))
(DFunDef false "checkType" ((PVar "cur") (PVar "env") (PCon "TyConstrained" (PVar "cs") (PVar "t"))) (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "checkConstraint") (EApp (EApp (EVar "orElseLoc") (EVar "cur")) (EApp (EVar "firstTyLoc") (EVar "t")))) (EVar "env"))) (EVar "cs")) (EApp (EApp (EApp (EVar "checkType") (EVar "cur")) (EVar "env")) (EVar "t"))))
(DFunDef false "checkType" ((PVar "cur") (PVar "env") (PCon "TyRow" (PVar "labels") PWild PWild)) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "checkEffect") (EVar "cur")) (EVar "env"))) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "labels"))))
(DTypeSig false "builtInEffects" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "builtInEffects" () (EListLit (ELit (LString "IO")) (ELit (LString "Rand")) (ELit (LString "Stdout")) (ELit (LString "Stderr")) (ELit (LString "Stdin")) (ELit (LString "Clock")) (ELit (LString "Env")) (ELit (LString "Exec")) (ELit (LString "Net")) (ELit (LString "FileRead")) (ELit (LString "FileWrite")) (ELit (LString "FFI"))))
(DTypeSig false "checkEffect" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "checkEffect" ((PVar "cur") (PVar "env") (PVar "e")) (EIf (EBinOp "||" (EApp (EApp (EVar "contains") (EVar "e")) (EVar "builtInEffects")) (EApp (EApp (EVar "contains") (EVar "e")) (EFieldAccess (EVar "env") "effects"))) (EListLit) (EListLit (EApp (EApp (EVar "UnknownEffect") (EVar "e")) (EVar "cur")))))
(DTypeSig false "ambiguousTypeErrors" (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "ambiguousTypeErrors" ((PVar "env") (PVar "n") (PVar "loc")) (EApp (EApp (EVar "whenL") (EApp (EApp (EVar "isTypeAmbiguous") (EVar "env")) (EVar "n"))) (EListLit (EApp (EApp (EApp (EVar "AmbiguousType") (EVar "n")) (EApp (EApp (EVar "typeAmbigMods") (EVar "env")) (EVar "n"))) (EVar "loc")))))
(DTypeSig false "ambiguousCtorErrors" (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "ambiguousCtorErrors" ((PVar "env") (PVar "n") (PVar "loc")) (EApp (EApp (EVar "whenL") (EApp (EApp (EVar "isCtorAmbiguous") (EVar "env")) (EVar "n"))) (EListLit (EApp (EApp (EApp (EVar "AmbiguousConstructor") (EVar "n")) (EApp (EApp (EVar "ctorAmbigMods") (EVar "env")) (EVar "n"))) (EVar "loc")))))
(DTypeSig false "ambiguousHeadErrors" (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "ambiguousHeadErrors" ((PVar "env") (PVar "n") (PVar "loc")) (EMatch (EApp (EApp (EApp (EVar "ambiguousTypeErrors") (EVar "env")) (EVar "n")) (EVar "loc")) (arm (PList) () (EApp (EApp (EApp (EVar "ambiguousCtorErrors") (EVar "env")) (EVar "n")) (EVar "loc"))) (arm (PVar "es") () (EVar "es"))))
(DTypeSig false "ambiguousIfaceErrors" (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "ambiguousIfaceErrors" ((PVar "env") (PVar "n") (PVar "loc")) (EApp (EApp (EVar "whenL") (EApp (EApp (EVar "isIfaceAmbiguous") (EVar "env")) (EVar "n"))) (EListLit (EApp (EApp (EApp (EVar "AmbiguousInterface") (EVar "n")) (EApp (EApp (EVar "ifaceAmbigMods") (EVar "env")) (EVar "n"))) (EVar "loc")))))
(DTypeSig false "checkConstraint" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyCon "Constraint") (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "checkConstraint" ((PVar "cur") (PVar "env") (PRec "Constraint" ((rf "constraintHead" (PVar "iface")) (rf "constraintArgs" (PVar "args"))) false)) (EBinOp "++" (EIf (EApp (EApp (EVar "contains") (EVar "iface")) (EFieldAccess (EVar "env") "interfaces")) (EApp (EApp (EApp (EVar "ambiguousIfaceErrors") (EVar "env")) (EVar "iface")) (EApp (EApp (EVar "orElseLoc") (EApp (EVar "firstTyLocList") (EVar "args"))) (EVar "cur"))) (EListLit (EApp (EApp (EVar "UnknownInterface") (EVar "iface")) (EVar "cur")))) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "checkType") (EVar "cur")) (EVar "env"))) (EVar "args"))))
(DTypeSig false "checkPat" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyCon "Pat") (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "checkPat" ((PVar "cur") (PVar "env") (PCon "PCon" (PVar "c") (PVar "ps"))) (EBinOp "++" (EIf (EBinOp "||" (EApp (EApp (EVar "omHasKey") (EVar "c")) (EFieldAccess (EVar "env") "ctors")) (EApp (EApp (EVar "omHasKey") (EVar "c")) (EFieldAccess (EVar "env") "imported"))) (EApp (EApp (EApp (EVar "ambiguousCtorErrors") (EVar "env")) (EVar "c")) (EVar "cur")) (EListLit (EApp (EApp (EApp (EVar "UnknownConstructor") (EVar "c")) (EVar "cur")) (EApp (EVar "suggestCtor") (EVar "c"))))) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "checkPat") (EVar "cur")) (EVar "env"))) (EVar "ps"))))
(DFunDef false "checkPat" ((PVar "cur") (PVar "env") (PCon "PCons" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EApp (EApp (EVar "checkPat") (EVar "cur")) (EVar "env")) (EVar "a")) (EApp (EApp (EApp (EVar "checkPat") (EVar "cur")) (EVar "env")) (EVar "b"))))
(DFunDef false "checkPat" ((PVar "cur") (PVar "env") (PCon "PTuple" (PVar "ps"))) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "checkPat") (EVar "cur")) (EVar "env"))) (EVar "ps")))
(DFunDef false "checkPat" ((PVar "cur") (PVar "env") (PCon "PList" (PVar "ps"))) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "checkPat") (EVar "cur")) (EVar "env"))) (EVar "ps")))
(DFunDef false "checkPat" ((PVar "cur") (PVar "env") (PCon "PAs" PWild PWild (PVar "p"))) (EApp (EApp (EApp (EVar "checkPat") (EVar "cur")) (EVar "env")) (EVar "p")))
(DFunDef false "checkPat" ((PVar "cur") (PVar "env") (PCon "PRec" (PVar "name") (PVar "fields") PWild)) (EApp (EApp (EApp (EApp (EVar "checkRecPat") (EVar "cur")) (EVar "env")) (EVar "name")) (EVar "fields")))
(DFunDef false "checkPat" (PWild PWild PWild) (EListLit))
(DTypeSig false "checkRecPat" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "RecPatField")) (TyApp (TyCon "List") (TyCon "ResError")))))))
(DFunDef false "checkRecPat" ((PVar "cur") (PVar "env") (PVar "name") (PVar "fields")) (EBinOp "++" (EApp (EApp (EApp (EVar "recPatHead") (EVar "cur")) (EVar "env")) (EVar "name")) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EVar "checkRecField") (EVar "cur")) (EVar "env")) (EVar "name"))) (EVar "fields"))))
(DTypeSig false "recPatHead" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "recPatHead" ((PVar "cur") (PVar "env") (PVar "name")) (EIf (EBinOp "||" (EApp (EApp (EVar "omHasKey") (EVar "name")) (EFieldAccess (EVar "env") "types")) (EApp (EApp (EVar "omHasKey") (EVar "name")) (EFieldAccess (EVar "env") "ctors"))) (EApp (EApp (EApp (EVar "ambiguousHeadErrors") (EVar "env")) (EVar "name")) (EVar "cur")) (EListLit (EApp (EApp (EApp (EVar "UnknownType") (EVar "name")) (EVar "cur")) (EApp (EApp (EVar "suggestType") (EVar "env")) (EVar "name"))))))
(DTypeSig false "checkRecField" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyFun (TyCon "RecPatField") (TyApp (TyCon "List") (TyCon "ResError")))))))
(DFunDef false "checkRecField" ((PVar "cur") (PVar "env") (PVar "owner") (PCon "RecPatField" (PVar "fname") PWild (PVar "popt"))) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "fieldCheck") (EVar "cur")) (EVar "env")) (EVar "owner")) (EVar "fname")) (EApp (EApp (EApp (EVar "recFieldSub") (EVar "cur")) (EVar "env")) (EVar "popt"))))
(DTypeSig false "fieldCheck" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "ResError")))))))
(DFunDef false "fieldCheck" ((PVar "cur") (PVar "env") (PVar "owner") (PVar "fname")) (EBlock (DoLet false false (PVar "owners") (EApp (EApp (EVar "ownersOf") (EVar "fname")) (EFieldAccess (EVar "env") "fieldOwnersIdx"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "fieldVerdict") (EVar "cur")) (EVar "env")) (EVar "owner")) (EVar "fname")) (EVar "owners")))))
(DTypeSig false "fieldVerdict" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "ResError"))))))))
(DFunDef false "fieldVerdict" ((PVar "cur") (PVar "env") (PVar "owner") (PVar "fname") (PList)) (EIf (EBinOp "&&" (EApp (EApp (EVar "omHasKey") (EVar "owner")) (EFieldAccess (EVar "env") "types")) (EApp (EVar "not") (EApp (EApp (EVar "ownsAnyField") (EVar "owner")) (EFieldAccess (EVar "env") "fieldOwners")))) (EListLit (EApp (EApp (EApp (EVar "AbstractFieldAccess") (EVar "owner")) (EVar "fname")) (EVar "cur"))) (EListLit (EApp (EApp (EVar "UnknownField") (EVar "fname")) (EVar "cur")))))
(DFunDef false "fieldVerdict" ((PVar "cur") (PVar "env") (PVar "owner") (PVar "fname") (PVar "owners")) (EIf (EApp (EApp (EVar "contains") (EVar "owner")) (EVar "owners")) (EListLit) (EListLit (EApp (EApp (EApp (EVar "FieldNotInRecord") (EVar "fname")) (EVar "owner")) (EVar "cur")))))
(DTypeSig false "ownsAnyField" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyCon "Bool"))))
(DFunDef false "ownsAnyField" (PWild (PList)) (EVar "False"))
(DFunDef false "ownsAnyField" ((PVar "owner") (PCons (PTuple PWild (PVar "o")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "o") (EVar "owner")) (EVar "True") (EIf (EVar "otherwise") (EApp (EApp (EVar "ownsAnyField") (EVar "owner")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "recFieldSub" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyApp (TyCon "Option") (TyCon "Pat")) (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "recFieldSub" (PWild PWild (PCon "None")) (EListLit))
(DFunDef false "recFieldSub" ((PVar "cur") (PVar "env") (PCon "Some" (PVar "p"))) (EApp (EApp (EApp (EVar "checkPat") (EVar "cur")) (EVar "env")) (EVar "p")))
(DData Private "Scope" () ((variant "Scope" (ConPos (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "OrdMap") (TyCon "Unit"))))) ())
(DTypeSig false "emptyScope" (TyCon "Scope"))
(DFunDef false "emptyScope" () (EApp (EApp (EVar "Scope") (EListLit)) (EVar "omEmpty")))
(DTypeSig false "mkScope" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Scope")))
(DFunDef false "mkScope" ((PVar "ns")) (EApp (EApp (EVar "Scope") (EVar "ns")) (EApp (EApp (EVar "omFromNames") (EVar "ns")) (EVar "omEmpty"))))
(DTypeSig false "scopeNames" (TyFun (TyCon "Scope") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "scopeNames" ((PCon "Scope" (PVar "ns") PWild)) (EVar "ns"))
(DTypeSig false "scopeMem" (TyFun (TyCon "String") (TyFun (TyCon "Scope") (TyCon "Bool"))))
(DFunDef false "scopeMem" ((PVar "n") (PCon "Scope" PWild (PVar "mem"))) (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "mem")))
(DTypeSig false "scopeExtend" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Scope") (TyCon "Scope"))))
(DFunDef false "scopeExtend" ((PVar "ns") (PCon "Scope" (PVar "names") (PVar "mem"))) (EApp (EApp (EVar "Scope") (EBinOp "++" (EVar "ns") (EVar "names"))) (EApp (EApp (EVar "omFromNames") (EVar "ns")) (EVar "mem"))))
(DTypeSig false "scopeAdd" (TyFun (TyCon "String") (TyFun (TyCon "Scope") (TyCon "Scope"))))
(DFunDef false "scopeAdd" ((PVar "n") (PCon "Scope" (PVar "names") (PVar "mem"))) (EApp (EApp (EVar "Scope") (EBinOp "::" (EVar "n") (EVar "names"))) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (ELit LUnit)) (EVar "mem"))))
(DTypeSig false "checkExpr" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyCon "Scope") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "ResError")))))))
(DFunDef false "checkExpr" (PWild PWild PWild (PCon "ELit" PWild)) (EListLit))
(DFunDef false "checkExpr" (PWild PWild PWild (PCon "ENumLit" PWild PWild PWild PWild)) (EListLit))
(DFunDef false "checkExpr" (PWild PWild PWild (PCon "EMethodRef" PWild)) (EListLit))
(DFunDef false "checkExpr" (PWild PWild PWild (PCon "EDictApp" PWild)) (EListLit))
(DFunDef false "checkExpr" (PWild PWild PWild (PCon "EVarAt" PWild PWild)) (EApp (EVar "panic") (ELit (LString "unreachable: EVarAt is introduced by annotateProgram after resolve"))))
(DFunDef false "checkExpr" (PWild PWild PWild (PCon "EMethodAt" PWild PWild PWild PWild)) (EApp (EVar "panic") (ELit (LString "unreachable: EMethodAt is introduced by typecheck elaboration after resolve"))))
(DFunDef false "checkExpr" (PWild PWild PWild (PCon "EDictAt" PWild PWild)) (EApp (EVar "panic") (ELit (LString "unreachable: EDictAt is introduced by typecheck elaboration after resolve"))))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "EVar" (PVar "n"))) (EApp (EApp (EApp (EApp (EVar "checkVar") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "n")))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "EApp" (PVar "f") (PVar "x"))) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "f")) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "x"))))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "ELam" (PVar "pats") (PVar "body"))) (EBinOp "++" (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "checkPat") (EVar "cur")) (EVar "env"))) (EVar "pats")) (EApp (EApp (EApp (EVar "patGroupDupErrors") (EVar "cur")) (ELit (LString "parameter list"))) (EVar "pats"))) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EApp (EApp (EVar "scopeExtend") (EApp (EVar "patsBindings") (EVar "pats"))) (EVar "scope"))) (EVar "body"))))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "ELet" PWild (PVar "isRec") (PVar "pat") (PVar "e1") (PVar "e2"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "checkLet") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "isRec")) (EVar "pat")) (EVar "e1")) (EVar "e2")))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "ELetGroup" (PVar "binds") (PVar "body"))) (EApp (EApp (EApp (EApp (EApp (EVar "checkLetGroup") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "binds")) (EVar "body")))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "EMatch" (PVar "e0") (PVar "arms"))) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e0")) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EVar "checkArm") (EVar "cur")) (EVar "env")) (EVar "scope"))) (EVar "arms"))))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "EIf" (PVar "c") (PVar "t") (PVar "el"))) (EBinOp "++" (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "c")) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "t"))) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "el"))))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "EBinOp" PWild (PVar "a") (PVar "b") PWild)) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "a")) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "b"))))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "EUnOp" PWild (PVar "a") PWild)) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "a")))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "EInfix" (PVar "op") (PVar "a") (PVar "b"))) (EBinOp "++" (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "checkVar") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "op")) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "a"))) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "b"))))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "EFieldAccess" (PVar "e0") PWild PWild)) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e0")))
(DFunDef false "checkExpr" (PWild PWild PWild (PCon "EMapLit" PWild PWild)) (EApp (EVar "panic") (ELit (LString "unreachable: EMapLit is lowered to fromEntries by desugar before resolve"))))
(DFunDef false "checkExpr" (PWild PWild PWild (PCon "ESetLit" PWild PWild)) (EApp (EVar "panic") (ELit (LString "unreachable: ESetLit is lowered to fromEntries by desugar before resolve"))))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "ETuple" (PVar "es"))) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope"))) (EVar "es")))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "EListLit" (PVar "es"))) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope"))) (EVar "es")))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "EArrayLit" (PVar "es"))) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope"))) (EVar "es")))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "ERangeList" (PVar "lo") (PVar "hi") PWild)) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "lo")) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "hi"))))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "ERangeArray" (PVar "lo") (PVar "hi") PWild)) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "lo")) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "hi"))))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "ESlice" (PVar "e0") (PVar "lo") (PVar "hi") PWild PWild)) (EBinOp "++" (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e0")) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "lo"))) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "hi"))))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "EIndex" (PVar "e0") (PVar "i") PWild)) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e0")) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "i"))))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "EAnnot" (PVar "e0") (PVar "t"))) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e0")) (EApp (EApp (EApp (EVar "checkType") (EVar "cur")) (EVar "env")) (EVar "t"))))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "EHeadAnnot" (PVar "e0") (PVar "t"))) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e0")) (EApp (EApp (EApp (EVar "checkType") (EVar "cur")) (EVar "env")) (EVar "t"))))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "EBlock" (PVar "stmts"))) (EApp (EApp (EApp (EApp (EVar "checkStmts") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "stmts")))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "EDo" PWild (PVar "stmts"))) (EApp (EApp (EApp (EApp (EVar "checkStmts") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "stmts")))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "EStringInterp" (PVar "parts"))) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EVar "checkInterp") (EVar "cur")) (EVar "env")) (EVar "scope"))) (EVar "parts")))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "EGuards" (PVar "arms"))) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EVar "checkGuardArm") (EVar "cur")) (EVar "env")) (EVar "scope"))) (EVar "arms")))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "ERecordCreate" (PVar "name") (PVar "fs"))) (EApp (EApp (EApp (EApp (EApp (EVar "checkRecordCreate") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "name")) (EVar "fs")))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "ERecordUpdate" (PVar "e0") (PVar "fs") PWild)) (EApp (EApp (EApp (EApp (EApp (EVar "checkRecordUpdate") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e0")) (EVar "fs")))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "EVariantUpdate" (PVar "con") (PVar "e0") (PVar "fs"))) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e0")) (EApp (EApp (EApp (EApp (EApp (EVar "checkRecordCreate") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "con")) (EVar "fs"))))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "EAsPat" PWild (PVar "e0"))) (EBinOp "::" (EApp (EVar "AsPatternMisplaced") (EVar "cur")) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e0"))))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "ESection" (PVar "s"))) (EApp (EApp (EApp (EApp (EVar "checkSection") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "s")))
(DFunDef false "checkExpr" (PWild (PVar "env") (PVar "scope") (PCon "ELoc" (PVar "l") (PVar "e"))) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EApp (EVar "Some") (EVar "l"))) (EVar "env")) (EVar "scope")) (EVar "e")))
(DFunDef false "checkExpr" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "EDoOrigin" PWild (PVar "e"))) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e")))
(DTypeSig false "checkVar" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyCon "Scope") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "ResError")))))))
(DFunDef false "checkVar" ((PVar "cur") (PVar "env") (PVar "scope") (PVar "n")) (EIf (EApp (EVar "isHint") (EVar "n")) (EListLit) (EIf (EBinOp "&&" (EApp (EVar "not") (EApp (EApp (EVar "scopeMem") (EVar "n")) (EVar "scope"))) (EApp (EApp (EVar "omHasKey") (EVar "n")) (EFieldAccess (EVar "env") "internalGuard"))) (EListLit (EApp (EApp (EVar "InternalExternAccess") (EVar "n")) (EVar "cur"))) (EIf (EApp (EVar "not") (EApp (EApp (EApp (EVar "lookupValue") (EVar "env")) (EVar "scope")) (EVar "n"))) (EApp (EApp (EApp (EApp (EVar "unboundVarErrors") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "n")) (EIf (EBinOp "&&" (EApp (EVar "not") (EApp (EApp (EVar "scopeMem") (EVar "n")) (EVar "scope"))) (EApp (EApp (EVar "isAmbiguous") (EVar "env")) (EVar "n"))) (EListLit (EApp (EApp (EApp (EVar "AmbiguousOccurrence") (EVar "n")) (EApp (EApp (EVar "ambigMods") (EVar "env")) (EVar "n"))) (EVar "cur"))) (EIf (EBinOp "&&" (EApp (EVar "not") (EApp (EApp (EVar "scopeMem") (EVar "n")) (EVar "scope"))) (EApp (EApp (EVar "isCtorAmbiguous") (EVar "env")) (EVar "n"))) (EApp (EApp (EApp (EVar "ambiguousCtorErrors") (EVar "env")) (EVar "n")) (EVar "cur")) (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))
(DTypeSig false "unboundVarErrors" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyCon "Scope") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "ResError")))))))
(DFunDef false "unboundVarErrors" ((PVar "cur") (PVar "env") (PVar "scope") (PVar "n")) (EMatch (EApp (EApp (EVar "modulesExportingName") (EVar "env")) (EVar "n")) (arm (PCons (PVar "m") PWild) () (EListLit (EApp (EApp (EApp (EVar "UnboundVariableExported") (EVar "n")) (EVar "m")) (EVar "cur")))) (arm (PList) () (EIf (EApp (EApp (EVar "isImportedModuleName") (EVar "env")) (EVar "n")) (EListLit (EApp (EApp (EVar "UnboundVariableIsModule") (EVar "n")) (EVar "cur"))) (EListLit (EApp (EApp (EApp (EVar "UnboundVariable") (EVar "n")) (EVar "cur")) (EApp (EApp (EApp (EVar "suggestName") (EVar "env")) (EVar "scope")) (EVar "n"))))))))
(DTypeSig false "modulesExportingName" (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "modulesExportingName" ((PVar "env") (PVar "n")) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "matchesExport") (EVar "n"))) (EFieldAccess (EVar "env") "importedModuleValues")))
(DTypeSig false "matchesExport" (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "matchesExport" ((PVar "n") (PTuple (PVar "mid") (PVar "vals"))) (EIf (EApp (EApp (EVar "contains") (EVar "n")) (EVar "vals")) (EListLit (EVar "mid")) (EListLit)))
(DTypeSig false "isImportedModuleName" (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "isImportedModuleName" ((PVar "env") (PVar "n")) (EApp (EApp (EVar "anyList") (EApp (EVar "isModId") (EVar "n"))) (EFieldAccess (EVar "env") "importedModuleValues")))
(DTypeSig false "isModId" (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))) (TyCon "Bool"))))
(DFunDef false "isModId" ((PVar "n") (PTuple (PVar "mid") PWild)) (EBinOp "==" (EVar "mid") (EVar "n")))
(DTypeSig false "isAmbiguous" (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "isAmbiguous" ((PVar "env") (PVar "n")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EFieldAccess (EVar "env") "ambiguous")) (arm (PCon "Some" PWild) () (EVar "True")) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "ambigMods" (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "ambigMods" ((PVar "env") (PVar "n")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EFieldAccess (EVar "env") "ambiguous")) (arm (PCon "Some" (PVar "mods")) () (EVar "mods")) (arm (PCon "None") () (EListLit))))
(DTypeSig false "isCtorAmbiguous" (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "isCtorAmbiguous" ((PVar "env") (PVar "n")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EFieldAccess (EVar "env") "ctorAmbiguous")) (arm (PCon "Some" PWild) () (EVar "True")) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "ctorAmbigMods" (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "ctorAmbigMods" ((PVar "env") (PVar "n")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EFieldAccess (EVar "env") "ctorAmbiguous")) (arm (PCon "Some" (PVar "mods")) () (EVar "mods")) (arm (PCon "None") () (EListLit))))
(DTypeSig false "isTypeAmbiguous" (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "isTypeAmbiguous" ((PVar "env") (PVar "n")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EFieldAccess (EVar "env") "typeAmbiguous")) (arm (PCon "Some" PWild) () (EVar "True")) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "typeAmbigMods" (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "typeAmbigMods" ((PVar "env") (PVar "n")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EFieldAccess (EVar "env") "typeAmbiguous")) (arm (PCon "Some" (PVar "mods")) () (EVar "mods")) (arm (PCon "None") () (EListLit))))
(DTypeSig false "isIfaceAmbiguous" (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "isIfaceAmbiguous" ((PVar "env") (PVar "n")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EFieldAccess (EVar "env") "ifaceAmbiguous")) (arm (PCon "Some" PWild) () (EVar "True")) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "ifaceAmbigMods" (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "ifaceAmbigMods" ((PVar "env") (PVar "n")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EFieldAccess (EVar "env") "ifaceAmbiguous")) (arm (PCon "Some" (PVar "mods")) () (EVar "mods")) (arm (PCon "None") () (EListLit))))
(DTypeSig false "isHint" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isHint" ((PVar "n")) (EApp (EVar "startsWithAt") (EApp (EVar "stringToChars") (EVar "n"))))
(DTypeSig false "startsWithAt" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyCon "Bool")))
(DFunDef false "startsWithAt" ((PVar "cs")) (EBinOp "&&" (EBinOp ">" (EApp (EVar "arrayLength") (EVar "cs")) (ELit (LInt 0))) (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 0))) (EVar "cs")) (ELit (LChar "@")))))
(DTypeSig false "lookupValue" (TyFun (TyCon "Env") (TyFun (TyCon "Scope") (TyFun (TyCon "String") (TyCon "Bool")))))
(DFunDef false "lookupValue" ((PVar "env") (PVar "scope") (PVar "n")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EApp (EApp (EVar "scopeMem") (EVar "n")) (EVar "scope")) (EApp (EApp (EVar "omHasKey") (EVar "n")) (EFieldAccess (EVar "env") "values"))) (EApp (EApp (EVar "omHasKey") (EVar "n")) (EFieldAccess (EVar "env") "ctors"))) (EApp (EApp (EVar "omHasKey") (EVar "n")) (EFieldAccess (EVar "env") "imported"))))
(DTypeSig false "haskellTypeAliases" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "haskellTypeAliases" () (EListLit (ETuple (ELit (LString "Functor")) (ELit (LString "Mappable"))) (ETuple (ELit (LString "Monad")) (ELit (LString "Thenable"))) (ETuple (ELit (LString "Maybe")) (ELit (LString "Option"))) (ETuple (ELit (LString "Either")) (ELit (LString "Result")))))
(DTypeSig false "haskellValueAliases" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "haskellValueAliases" () (EListLit (ETuple (ELit (LString "fmap")) (ELit (LString "map"))) (ETuple (ELit (LString "return")) (ELit (LString "pure"))) (ETuple (ELit (LString "show")) (ELit (LString "debug"))) (ETuple (ELit (LString "mappend")) (ELit (LString "append"))) (ETuple (ELit (LString "mempty")) (ELit (LString "empty"))) (ETuple (ELit (LString "foldr")) (ELit (LString "foldRight"))) (ETuple (ELit (LString "foldl")) (ELit (LString "fold"))) (ETuple (ELit (LString "error")) (ELit (LString "panic"))) (ETuple (ELit (LString "undefined")) (ELit (LString "panic")))))
(DTypeSig false "haskellCtorAliases" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "haskellCtorAliases" () (EListLit (ETuple (ELit (LString "Just")) (ELit (LString "Some"))) (ETuple (ELit (LString "Nothing")) (ELit (LString "None"))) (ETuple (ELit (LString "Left")) (ELit (LString "Err"))) (ETuple (ELit (LString "Right")) (ELit (LString "Ok")))))
(DTypeSig false "isHaskellAliasPair" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "isHaskellAliasPair" ((PVar "bad") (PVar "sug")) (EBinOp "||" (EBinOp "||" (EApp (EApp (EVar "optStrEq") (EApp (EApp (EVar "lookupAssoc") (EVar "bad")) (EVar "haskellTypeAliases"))) (EVar "sug")) (EApp (EApp (EVar "optStrEq") (EApp (EApp (EVar "lookupAssoc") (EVar "bad")) (EVar "haskellValueAliases"))) (EVar "sug"))) (EApp (EApp (EVar "optStrEq") (EApp (EApp (EVar "lookupAssoc") (EVar "bad")) (EVar "haskellCtorAliases"))) (EVar "sug"))))
(DTypeSig false "optStrEq" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "optStrEq" ((PCon "Some" (PVar "x")) (PVar "sug")) (EBinOp "==" (EVar "x") (EVar "sug")))
(DFunDef false "optStrEq" ((PCon "None") PWild) (EVar "False"))
(DTypeSig false "haskellNote" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "haskellNote" ((PVar "bad") (PVar "sug")) (EIf (EApp (EApp (EVar "isHaskellAliasPair") (EVar "bad")) (EVar "sug")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString " ('")) (EApp (EMethodRef "display") (EVar "bad"))) (ELit (LString "' is Haskell; Medaka uses '"))) (EApp (EMethodRef "display") (EVar "sug"))) (ELit (LString "')"))) (ELit (LString ""))))
(DTypeSig false "suggestName" (TyFun (TyCon "Env") (TyFun (TyCon "Scope") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "suggestName" ((PVar "env") (PVar "scope") (PVar "n")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EBinOp "++" (EVar "haskellValueAliases") (EVar "haskellCtorAliases"))) (arm (PCon "Some" (PVar "sug")) () (EApp (EVar "Some") (EVar "sug"))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "suggestNameFuzzy") (EVar "env")) (EVar "scope")) (EVar "n")))))
(DTypeSig false "suggestNameFuzzy" (TyFun (TyCon "Env") (TyFun (TyCon "Scope") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "suggestNameFuzzy" ((PVar "env") (PVar "scope") (PVar "n")) (EIf (EBinOp "<" (EApp (EVar "stringLength") (EVar "n")) (ELit (LInt 3))) (EVar "None") (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "q") (EApp (EVar "sugQueryOf") (EVar "n"))) (DoExpr (EMatch (EApp (EApp (EVar "bestOfNames") (EVar "q")) (EApp (EVar "scopeNames") (EVar "scope"))) (arm (PCon "Some" (PVar "best")) () (EApp (EVar "Some") (EVar "best"))) (arm (PCon "None") () (EApp (EApp (EVar "bestOfPool") (EVar "q")) (EFieldAccess (EVar "env") "sugValues")))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "suggestType" (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "suggestType" ((PVar "env") (PVar "n")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EVar "haskellTypeAliases")) (arm (PCon "Some" (PVar "sug")) () (EApp (EVar "Some") (EVar "sug"))) (arm (PCon "None") () (EApp (EApp (EVar "suggestTypeFuzzy") (EVar "env")) (EVar "n")))))
(DTypeSig false "suggestTypeFuzzy" (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "suggestTypeFuzzy" ((PVar "env") (PVar "n")) (EIf (EBinOp "<" (EApp (EVar "stringLength") (EVar "n")) (ELit (LInt 3))) (EVar "None") (EIf (EVar "otherwise") (EApp (EApp (EVar "bestOfPool") (EApp (EVar "sugQueryOf") (EVar "n"))) (EFieldAccess (EVar "env") "sugTypes")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "suggestCtor" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "suggestCtor" ((PVar "n")) (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EVar "haskellCtorAliases")))
(DData Private "SugCand" () ((variant "SugCand" (ConPos (TyCon "String") (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Bool")))) ())
(DTypeSig false "sugPoolOf" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "SugCand"))))
(DFunDef false "sugPoolOf" ((PVar "ns")) (EApp (EApp (EMethodRef "map") (EVar "sugCandOf")) (EVar "ns")))
(DTypeSig false "sugCandOf" (TyFun (TyCon "String") (TyCon "SugCand")))
(DFunDef false "sugCandOf" ((PVar "n")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "SugCand") (EVar "n")) (EApp (EVar "stringLength") (EVar "n"))) (EApp (EApp (EVar "charMask") (ELit (LInt 0))) (EVar "n"))) (EApp (EApp (EVar "charMask") (ELit (LInt 5))) (EVar "n"))) (EApp (EApp (EVar "charMask") (ELit (LInt 10))) (EVar "n"))) (EApp (EVar "startsUpper") (EVar "n"))))
(DData Private "SugQuery" () ((variant "SugQuery" (ConPos (TyCon "String") (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Bool")))) ())
(DTypeSig false "sugQueryOf" (TyFun (TyCon "String") (TyCon "SugQuery")))
(DFunDef false "sugQueryOf" ((PVar "n")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "SugQuery") (EVar "n")) (EApp (EApp (EVar "minI") (ELit (LInt 2))) (EApp (EApp (EVar "maxI") (ELit (LInt 1))) (EBinOp "/" (EApp (EVar "stringLength") (EVar "n")) (ELit (LInt 3)))))) (EApp (EVar "stringLength") (EVar "n"))) (EApp (EApp (EVar "charMask") (ELit (LInt 0))) (EVar "n"))) (EApp (EApp (EVar "charMask") (ELit (LInt 5))) (EVar "n"))) (EApp (EApp (EVar "charMask") (ELit (LInt 10))) (EVar "n"))) (EApp (EVar "startsUpper") (EVar "n"))))
(DTypeSig false "charMask" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "Int"))))
(DFunDef false "charMask" ((PVar "sh") (PVar "n")) (EApp (EApp (EApp (EApp (EVar "charMaskGo") (EVar "sh")) (EApp (EVar "stringToChars") (EVar "n"))) (ELit (LInt 0))) (ELit (LInt 0))))
(DTypeSig false "charMaskGo" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "charMaskGo" ((PVar "sh") (PVar "cs") (PVar "i") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "cs"))) (EVar "acc") (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "charMaskGo") (EVar "sh")) (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EApp (EVar "bitOr") (EVar "acc")) (EApp (EApp (EVar "shiftLeft") (ELit (LInt 1))) (EApp (EApp (EVar "bitAnd") (EApp (EApp (EVar "shiftRight") (EApp (EVar "hashChar") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs")))) (EVar "sh"))) (ELit (LInt 31)))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "bitsAtMost" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "bitsAtMost" ((PVar "k") (PVar "x")) (EIf (EBinOp "==" (EVar "x") (ELit (LInt 0))) (EVar "True") (EIf (EBinOp "<=" (EVar "k") (ELit (LInt 0))) (EVar "False") (EIf (EVar "otherwise") (EApp (EApp (EVar "bitsAtMost") (EBinOp "-" (EVar "k") (ELit (LInt 1)))) (EApp (EApp (EVar "bitAnd") (EVar "x")) (EBinOp "-" (EVar "x") (ELit (LInt 1))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "bestOfPool" (TyFun (TyCon "SugQuery") (TyFun (TyApp (TyCon "List") (TyCon "SugCand")) (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "bestOfPool" ((PVar "q") (PVar "cands")) (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "best") PWild)) (EVar "best"))) (EApp (EApp (EApp (EVar "bestInPool") (EVar "q")) (EVar "cands")) (EVar "None"))))
(DTypeSig false "bestInPool" (TyFun (TyCon "SugQuery") (TyFun (TyApp (TyCon "List") (TyCon "SugCand")) (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Int"))) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Int")))))))
(DFunDef false "bestInPool" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "bestInPool" ((PVar "q") (PCons (PCon "SugCand" (PVar "c") (PVar "clen") (PVar "cm1") (PVar "cm2") (PVar "cm3") (PVar "cup")) (PVar "cs")) (PVar "acc")) (EIf (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "sugRejects") (EVar "q")) (EVar "c")) (EVar "clen")) (EVar "cm1")) (EVar "cm2")) (EVar "cm3")) (EVar "cup")) (EApp (EApp (EApp (EVar "bestInPool") (EVar "q")) (EVar "cs")) (EVar "acc")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "bestInPool") (EVar "q")) (EVar "cs")) (EApp (EApp (EApp (EVar "scoreCand") (EVar "q")) (EVar "c")) (EVar "acc"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "bestOfNames" (TyFun (TyCon "SugQuery") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "bestOfNames" ((PVar "q") (PVar "ns")) (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "best") PWild)) (EVar "best"))) (EApp (EApp (EApp (EVar "bestInNames") (EVar "q")) (EVar "ns")) (EVar "None"))))
(DTypeSig false "bestInNames" (TyFun (TyCon "SugQuery") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Int"))) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Int")))))))
(DFunDef false "bestInNames" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "bestInNames" ((PVar "q") (PCons (PVar "c") (PVar "cs")) (PVar "acc")) (EIf (EApp (EApp (EApp (EApp (EVar "sugRejectsName") (EVar "q")) (EVar "c")) (EApp (EVar "stringLength") (EVar "c"))) (EApp (EVar "startsUpper") (EVar "c"))) (EApp (EApp (EApp (EVar "bestInNames") (EVar "q")) (EVar "cs")) (EVar "acc")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "bestInNames") (EVar "q")) (EVar "cs")) (EApp (EApp (EApp (EVar "scoreCand") (EVar "q")) (EVar "c")) (EVar "acc"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "sugRejects" (TyFun (TyCon "SugQuery") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyCon "Bool")))))))))
(DFunDef false "sugRejects" ((PCon "SugQuery" (PVar "n") (PVar "lim") (PVar "qlen") (PVar "qm1") (PVar "qm2") (PVar "qm3") (PVar "qup")) (PVar "c") (PVar "clen") (PVar "cm1") (PVar "cm2") (PVar "cm3") (PVar "cup")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EApp (EVar "not") (EApp (EApp (EVar "sameCase") (EVar "qup")) (EVar "cup"))) (EBinOp "<" (EVar "clen") (EBinOp "-" (EVar "qlen") (EVar "lim")))) (EBinOp ">" (EVar "clen") (EBinOp "+" (EVar "qlen") (EVar "lim")))) (EApp (EVar "not") (EApp (EApp (EVar "bitsAtMost") (EBinOp "*" (ELit (LInt 2)) (EVar "lim"))) (EApp (EApp (EVar "bitXor") (EVar "qm1")) (EVar "cm1"))))) (EApp (EVar "not") (EApp (EApp (EVar "bitsAtMost") (EBinOp "*" (ELit (LInt 2)) (EVar "lim"))) (EApp (EApp (EVar "bitXor") (EVar "qm2")) (EVar "cm2"))))) (EApp (EVar "not") (EApp (EApp (EVar "bitsAtMost") (EBinOp "*" (ELit (LInt 2)) (EVar "lim"))) (EApp (EApp (EVar "bitXor") (EVar "qm3")) (EVar "cm3"))))) (EBinOp "==" (EVar "c") (EVar "n"))))
(DTypeSig false "sugRejectsName" (TyFun (TyCon "SugQuery") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyCon "Bool"))))))
(DFunDef false "sugRejectsName" ((PCon "SugQuery" (PVar "n") (PVar "lim") (PVar "qlen") PWild PWild PWild (PVar "qup")) (PVar "c") (PVar "clen") (PVar "cup")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EApp (EVar "not") (EApp (EApp (EVar "sameCase") (EVar "qup")) (EVar "cup"))) (EBinOp "<" (EVar "clen") (EBinOp "-" (EVar "qlen") (EVar "lim")))) (EBinOp ">" (EVar "clen") (EBinOp "+" (EVar "qlen") (EVar "lim")))) (EBinOp "==" (EVar "c") (EVar "n"))))
(DTypeSig false "sameCase" (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyCon "Bool"))))
(DFunDef false "sameCase" ((PCon "True") (PCon "True")) (EVar "True"))
(DFunDef false "sameCase" ((PCon "False") (PCon "False")) (EVar "True"))
(DFunDef false "sameCase" (PWild PWild) (EVar "False"))
(DTypeSig false "scoreCand" (TyFun (TyCon "SugQuery") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Int"))) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Int")))))))
(DFunDef false "scoreCand" ((PCon "SugQuery" (PVar "n") (PVar "lim") PWild PWild PWild PWild PWild) (PVar "c") (PVar "acc")) (EBlock (DoLet false false PWild (EApp (EVar "opBump") (ELit LUnit))) (DoLet false false (PVar "d") (EApp (EApp (EVar "editDistance") (EVar "n")) (EVar "c"))) (DoExpr (EIf (EBinOp ">" (EVar "d") (EVar "lim")) (EVar "acc") (EApp (EApp (EApp (EVar "keepBetter") (EVar "c")) (EVar "d")) (EVar "acc"))))))
(DTypeSig false "startsUpper" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "startsUpper" ((PVar "s")) (EBinOp "&&" (EBinOp "&&" (EBinOp ">" (EApp (EVar "stringLength") (EVar "s")) (ELit (LInt 0))) (EBinOp ">=" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 1))) (EVar "s")) (ELit (LString "A")))) (EBinOp "<=" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 1))) (EVar "s")) (ELit (LString "Z")))))
(DTypeSig false "keepBetter" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Int"))) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Int")))))))
(DFunDef false "keepBetter" ((PVar "c") (PVar "d") (PCon "None")) (EApp (EVar "Some") (ETuple (EVar "c") (EVar "d"))))
(DFunDef false "keepBetter" ((PVar "c") (PVar "d") (PCon "Some" (PTuple (PVar "bc") (PVar "bd")))) (EIf (EBinOp "<" (EVar "d") (EVar "bd")) (EApp (EVar "Some") (ETuple (EVar "c") (EVar "d"))) (EIf (EBinOp "&&" (EBinOp "==" (EVar "d") (EVar "bd")) (EBinOp "<" (EVar "c") (EVar "bc"))) (EApp (EVar "Some") (ETuple (EVar "c") (EVar "d"))) (EIf (EVar "otherwise") (EApp (EVar "Some") (ETuple (EVar "bc") (EVar "bd"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "checkLet" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyCon "Scope") (TyFun (TyCon "Bool") (TyFun (TyCon "Pat") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "ResError"))))))))))
(DFunDef false "checkLet" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "True") (PCon "PVar" (PVar "f") PWild) (PVar "e1") (PVar "e2")) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EApp (EApp (EVar "scopeAdd") (EVar "f")) (EVar "scope"))) (EVar "e1")) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EApp (EApp (EVar "scopeAdd") (EVar "f")) (EVar "scope"))) (EVar "e2"))))
(DFunDef false "checkLet" ((PVar "cur") (PVar "env") (PVar "scope") PWild (PVar "pat") (PVar "e1") (PVar "e2")) (EBlock (DoLet false false (PVar "bound") (EApp (EVar "patBindings") (EVar "pat"))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EApp (EApp (EApp (EVar "checkPat") (EVar "cur")) (EVar "env")) (EVar "pat")) (EApp (EApp (EApp (EVar "patGroupDupErrors") (EVar "cur")) (ELit (LString "pattern"))) (EListLit (EVar "pat")))) (EApp (EApp (EMethodRef "map") (EApp (EVar "rewriteNonRec") (EVar "bound"))) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e1")))) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EApp (EApp (EVar "scopeExtend") (EVar "bound")) (EVar "scope"))) (EVar "e2"))))))
(DTypeSig false "rewriteNonRec" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "ResError") (TyCon "ResError"))))
(DFunDef false "rewriteNonRec" ((PVar "bound") (PCon "UnboundVariable" (PVar "n") (PVar "l") (PVar "s"))) (EIf (EApp (EApp (EVar "contains") (EVar "n")) (EVar "bound")) (EApp (EApp (EVar "NonRecursiveValueLet") (EVar "n")) (EVar "l")) (EApp (EApp (EApp (EVar "UnboundVariable") (EVar "n")) (EVar "l")) (EVar "s"))))
(DFunDef false "rewriteNonRec" (PWild (PVar "e")) (EVar "e"))
(DTypeSig false "checkLetGroup" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyCon "Scope") (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "ResError"))))))))
(DFunDef false "checkLetGroup" ((PVar "cur") (PVar "env") (PVar "scope") (PVar "binds") (PVar "body")) (EBlock (DoLet false false (PVar "scope2") (EApp (EApp (EVar "scopeExtend") (EApp (EApp (EMethodRef "map") (EVar "letBindName")) (EVar "binds"))) (EVar "scope"))) (DoExpr (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EVar "checkLetBind") (EVar "cur")) (EVar "env")) (EVar "scope2"))) (EVar "binds")) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope2")) (EVar "body"))))))
(DTypeSig false "letBindName" (TyFun (TyCon "LetBind") (TyCon "String")))
(DFunDef false "letBindName" ((PCon "LetBind" (PVar "n") PWild)) (EVar "n"))
(DTypeSig false "checkLetBind" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyCon "Scope") (TyFun (TyCon "LetBind") (TyApp (TyCon "List") (TyCon "ResError")))))))
(DFunDef false "checkLetBind" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "LetBind" (PVar "n") (PVar "clauses"))) (EBinOp "++" (EApp (EApp (EApp (EVar "letBindDupErrors") (EVar "cur")) (EVar "n")) (EVar "clauses")) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EVar "checkFunClause") (EVar "cur")) (EVar "env")) (EVar "scope"))) (EVar "clauses"))))
(DTypeSig false "letBindDupErrors" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "FunClause")) (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "letBindDupErrors" ((PVar "cur") (PVar "n") (PVar "clauses")) (EIf (EApp (EVar "hasNullaryClause") (EVar "clauses")) (EApp (EApp (EApp (EApp (EVar "dupClauseTail") (EVar "cur")) (EVar "n")) (EVar "False")) (EVar "clauses")) (EListLit)))
(DTypeSig false "hasNullaryClause" (TyFun (TyApp (TyCon "List") (TyCon "FunClause")) (TyCon "Bool")))
(DFunDef false "hasNullaryClause" ((PList)) (EVar "False"))
(DFunDef false "hasNullaryClause" ((PCons (PCon "FunClause" (PVar "ps") PWild) (PVar "rest"))) (EBinOp "||" (EApp (EVar "isEmptyL") (EVar "ps")) (EApp (EVar "hasNullaryClause") (EVar "rest"))))
(DTypeSig false "dupClauseTail" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "FunClause")) (TyApp (TyCon "List") (TyCon "ResError")))))))
(DFunDef false "dupClauseTail" (PWild PWild PWild (PList)) (EListLit))
(DFunDef false "dupClauseTail" ((PVar "cur") (PVar "n") (PVar "seen") (PCons (PCon "FunClause" PWild (PVar "body")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "whenL") (EVar "seen")) (EListLit (EApp (EApp (EVar "DuplicateValueBinding") (EVar "n")) (EApp (EApp (EVar "orElseLoc") (EApp (EVar "firstExprLoc") (EVar "body"))) (EVar "cur"))))) (EApp (EApp (EApp (EApp (EVar "dupClauseTail") (EVar "cur")) (EVar "n")) (EVar "True")) (EVar "rest"))))
(DTypeSig false "checkFunClause" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyCon "Scope") (TyFun (TyCon "FunClause") (TyApp (TyCon "List") (TyCon "ResError")))))))
(DFunDef false "checkFunClause" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "FunClause" (PVar "pats") (PVar "body"))) (EBlock (DoLet false false (PVar "patLoc") (EApp (EApp (EVar "orElseLoc") (EApp (EVar "firstExprLoc") (EVar "body"))) (EVar "cur"))) (DoExpr (EBinOp "++" (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "checkPat") (EVar "patLoc")) (EVar "env"))) (EVar "pats")) (EApp (EApp (EApp (EVar "patGroupDupErrors") (EVar "patLoc")) (ELit (LString "parameter list"))) (EVar "pats"))) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EApp (EApp (EVar "scopeExtend") (EApp (EVar "patsBindings") (EVar "pats"))) (EVar "scope"))) (EVar "body"))))))
(DTypeSig false "checkArm" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyCon "Scope") (TyFun (TyCon "Arm") (TyApp (TyCon "List") (TyCon "ResError")))))))
(DFunDef false "checkArm" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "Arm" (PVar "pat") (PVar "gs") (PVar "body"))) (EBlock (DoLet false false (PVar "scope0") (EApp (EApp (EVar "scopeExtend") (EApp (EVar "patBindings") (EVar "pat"))) (EVar "scope"))) (DoLet false false (PTuple (PVar "gErrs") (PVar "scope2")) (EApp (EApp (EApp (EApp (EVar "checkArmGuards") (EVar "cur")) (EVar "env")) (EVar "scope0")) (EVar "gs"))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EApp (EApp (EApp (EVar "checkPat") (EVar "cur")) (EVar "env")) (EVar "pat")) (EApp (EApp (EApp (EVar "patGroupDupErrors") (EVar "cur")) (ELit (LString "pattern"))) (EListLit (EVar "pat")))) (EVar "gErrs")) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope2")) (EVar "body"))))))
(DTypeSig false "checkArmGuards" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyCon "Scope") (TyFun (TyApp (TyCon "List") (TyCon "Guard")) (TyTuple (TyApp (TyCon "List") (TyCon "ResError")) (TyCon "Scope")))))))
(DFunDef false "checkArmGuards" (PWild PWild (PVar "scope") (PList)) (ETuple (EListLit) (EVar "scope")))
(DFunDef false "checkArmGuards" ((PVar "cur") (PVar "env") (PVar "scope") (PCons (PCon "GBool" (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "rErrs") (PVar "scope2")) (EApp (EApp (EApp (EApp (EVar "checkArmGuards") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "rest"))) (DoExpr (ETuple (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e")) (EVar "rErrs")) (EVar "scope2")))))
(DFunDef false "checkArmGuards" ((PVar "cur") (PVar "env") (PVar "scope") (PCons (PCon "GBind" (PVar "p") (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false (PVar "here") (EBinOp "++" (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e")) (EApp (EApp (EApp (EVar "checkPat") (EVar "cur")) (EVar "env")) (EVar "p"))) (EApp (EApp (EApp (EVar "patGroupDupErrors") (EVar "cur")) (ELit (LString "pattern"))) (EListLit (EVar "p"))))) (DoLet false false (PTuple (PVar "rErrs") (PVar "scope2")) (EApp (EApp (EApp (EApp (EVar "checkArmGuards") (EVar "cur")) (EVar "env")) (EApp (EApp (EVar "scopeExtend") (EApp (EVar "patBindings") (EVar "p"))) (EVar "scope"))) (EVar "rest"))) (DoExpr (ETuple (EBinOp "++" (EVar "here") (EVar "rErrs")) (EVar "scope2")))))
(DTypeSig false "checkGuardArm" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyCon "Scope") (TyFun (TyCon "GuardArm") (TyApp (TyCon "List") (TyCon "ResError")))))))
(DFunDef false "checkGuardArm" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "GuardArm" (PVar "gs") (PVar "body"))) (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EVar "checkGuard") (EVar "cur")) (EVar "env")) (EVar "scope"))) (EVar "gs")) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "body"))))
(DTypeSig false "checkGuard" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyCon "Scope") (TyFun (TyCon "Guard") (TyApp (TyCon "List") (TyCon "ResError")))))))
(DFunDef false "checkGuard" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "GBool" (PVar "e"))) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e")))
(DFunDef false "checkGuard" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "GBind" PWild (PVar "e"))) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e")))
(DTypeSig false "checkStmts" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyCon "Scope") (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyApp (TyCon "List") (TyCon "ResError")))))))
(DFunDef false "checkStmts" (PWild PWild PWild (PList)) (EListLit))
(DFunDef false "checkStmts" ((PVar "cur") (PVar "env") (PVar "scope") (PCons (PVar "s") (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "errs") (PVar "scope2")) (EApp (EApp (EApp (EApp (EVar "checkStmt") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "s"))) (DoExpr (EBinOp "++" (EVar "errs") (EApp (EApp (EApp (EApp (EVar "checkStmts") (EVar "cur")) (EVar "env")) (EVar "scope2")) (EVar "rest"))))))
(DTypeSig false "checkStmt" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyCon "Scope") (TyFun (TyCon "DoStmt") (TyTuple (TyApp (TyCon "List") (TyCon "ResError")) (TyCon "Scope")))))))
(DFunDef false "checkStmt" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "DoExpr" (PVar "e"))) (ETuple (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e")) (EVar "scope")))
(DFunDef false "checkStmt" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "DoBind" (PVar "p") (PVar "e"))) (ETuple (EBinOp "++" (EBinOp "++" (EApp (EApp (EApp (EVar "checkPat") (EVar "cur")) (EVar "env")) (EVar "p")) (EApp (EApp (EApp (EVar "patGroupDupErrors") (EVar "cur")) (ELit (LString "pattern"))) (EListLit (EVar "p")))) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e"))) (EApp (EApp (EVar "scopeExtend") (EApp (EVar "patBindings") (EVar "p"))) (EVar "scope"))))
(DFunDef false "checkStmt" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "DoLet" PWild (PCon "False") (PVar "p") (PVar "e"))) (ETuple (EBinOp "++" (EBinOp "++" (EApp (EApp (EApp (EVar "checkPat") (EVar "cur")) (EVar "env")) (EVar "p")) (EApp (EApp (EApp (EVar "patGroupDupErrors") (EVar "cur")) (ELit (LString "pattern"))) (EListLit (EVar "p")))) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e"))) (EApp (EApp (EVar "scopeExtend") (EApp (EVar "patBindings") (EVar "p"))) (EVar "scope"))))
(DFunDef false "checkStmt" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "DoLet" PWild (PCon "True") (PVar "p") (PVar "e"))) (ETuple (EBinOp "++" (EBinOp "++" (EApp (EApp (EApp (EVar "checkPat") (EVar "cur")) (EVar "env")) (EVar "p")) (EApp (EApp (EApp (EVar "patGroupDupErrors") (EVar "cur")) (ELit (LString "pattern"))) (EListLit (EVar "p")))) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EApp (EApp (EVar "scopeExtend") (EApp (EVar "patBindings") (EVar "p"))) (EVar "scope"))) (EVar "e"))) (EApp (EApp (EVar "scopeExtend") (EApp (EVar "patBindings") (EVar "p"))) (EVar "scope"))))
(DFunDef false "checkStmt" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "DoAssign" (PVar "x") (PVar "e"))) (ETuple (EBinOp "::" (EApp (EApp (EVar "ReassignImmutable") (EVar "x")) (EApp (EApp (EVar "orElseLoc") (EApp (EVar "firstExprLoc") (EVar "e"))) (EVar "cur"))) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e"))) (EVar "scope")))
(DFunDef false "checkStmt" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "DoFieldAssign" PWild PWild (PVar "e"))) (ETuple (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e")) (EVar "scope")))
(DTypeSig false "checkInterp" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyCon "Scope") (TyFun (TyCon "InterpPart") (TyApp (TyCon "List") (TyCon "ResError")))))))
(DFunDef false "checkInterp" (PWild PWild PWild (PCon "InterpStr" PWild)) (EListLit))
(DFunDef false "checkInterp" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "InterpExpr" (PVar "e"))) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e")))
(DTypeSig false "checkFieldAssign" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyCon "Scope") (TyFun (TyCon "FieldAssign") (TyApp (TyCon "List") (TyCon "ResError")))))))
(DFunDef false "checkFieldAssign" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "FieldAssign" PWild (PVar "e"))) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e")))
(DTypeSig false "checkRecordCreate" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyCon "Scope") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "FieldAssign")) (TyApp (TyCon "List") (TyCon "ResError"))))))))
(DFunDef false "checkRecordCreate" ((PVar "cur") (PVar "env") (PVar "scope") (PVar "name") (PVar "fs")) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "recCreateHead") (EVar "cur")) (EVar "env")) (EVar "name")) (EVar "fs")) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EVar "checkFieldAssign") (EVar "cur")) (EVar "env")) (EVar "scope"))) (EVar "fs"))))
(DTypeSig false "recCreateHead" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "FieldAssign")) (TyApp (TyCon "List") (TyCon "ResError")))))))
(DFunDef false "recCreateHead" ((PVar "cur") (PVar "env") (PVar "name") (PVar "fs")) (EIf (EBinOp "||" (EBinOp "||" (EApp (EApp (EVar "omHasKey") (EVar "name")) (EFieldAccess (EVar "env") "types")) (EApp (EApp (EVar "omHasKey") (EVar "name")) (EFieldAccess (EVar "env") "imported"))) (EApp (EApp (EVar "omHasKey") (EVar "name")) (EFieldAccess (EVar "env") "ctors"))) (EBinOp "++" (EApp (EApp (EApp (EVar "ambiguousHeadErrors") (EVar "env")) (EVar "name")) (EVar "cur")) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EVar "recCreateField") (EVar "cur")) (EVar "env")) (EVar "name"))) (EVar "fs"))) (EIf (EVar "otherwise") (EListLit (EApp (EApp (EApp (EVar "UnknownType") (EVar "name")) (EVar "cur")) (EApp (EApp (EVar "suggestType") (EVar "env")) (EVar "name")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "recCreateField" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyFun (TyCon "FieldAssign") (TyApp (TyCon "List") (TyCon "ResError")))))))
(DFunDef false "recCreateField" ((PVar "cur") (PVar "env") (PVar "owner") (PCon "FieldAssign" (PVar "fname") PWild)) (EApp (EApp (EApp (EApp (EApp (EVar "fieldVerdict") (EVar "cur")) (EVar "env")) (EVar "owner")) (EVar "fname")) (EApp (EApp (EVar "ownersOf") (EVar "fname")) (EFieldAccess (EVar "env") "fieldOwnersIdx"))))
(DTypeSig false "checkRecordUpdate" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyCon "Scope") (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "FieldAssign")) (TyApp (TyCon "List") (TyCon "ResError"))))))))
(DFunDef false "checkRecordUpdate" ((PVar "cur") (PVar "env") (PVar "scope") (PVar "e0") (PVar "fs")) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e0")) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EVar "recUpdateField") (EVar "cur")) (EVar "env")) (EVar "scope"))) (EVar "fs"))))
(DTypeSig false "recUpdateField" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyCon "Scope") (TyFun (TyCon "FieldAssign") (TyApp (TyCon "List") (TyCon "ResError")))))))
(DFunDef false "recUpdateField" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "FieldAssign" (PVar "fname") (PVar "v"))) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "v")) (EApp (EApp (EApp (EVar "fieldKnownErr") (EVar "cur")) (EVar "env")) (EVar "fname"))))
(DTypeSig false "fieldKnownErr" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "fieldKnownErr" ((PVar "cur") (PVar "env") (PVar "fname")) (EApp (EApp (EApp (EVar "recUpdateVerdict") (EVar "cur")) (EVar "fname")) (EApp (EApp (EVar "ownersOf") (EVar "fname")) (EFieldAccess (EVar "env") "fieldOwnersIdx"))))
(DTypeSig false "recUpdateVerdict" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "recUpdateVerdict" ((PVar "cur") (PVar "fname") (PList)) (EListLit (EApp (EApp (EVar "UnknownField") (EVar "fname")) (EVar "cur"))))
(DFunDef false "recUpdateVerdict" (PWild PWild PWild) (EListLit))
(DTypeSig false "checkSection" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Env") (TyFun (TyCon "Scope") (TyFun (TyCon "Section") (TyApp (TyCon "List") (TyCon "ResError")))))))
(DFunDef false "checkSection" (PWild PWild PWild (PCon "SecBare" PWild)) (EListLit))
(DFunDef false "checkSection" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "SecRight" PWild (PVar "e"))) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e")))
(DFunDef false "checkSection" ((PVar "cur") (PVar "env") (PVar "scope") (PCon "SecLeft" (PVar "e") PWild)) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "cur")) (EVar "env")) (EVar "scope")) (EVar "e")))
(DTypeSig false "checkDecl" (TyFun (TyCon "Env") (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "ResError")))))
(DFunDef false "checkDecl" ((PVar "env") (PCon "DFunDef" PWild PWild (PVar "pats") (PVar "body"))) (EBinOp "++" (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "checkPat") (EApp (EVar "firstExprLoc") (EVar "body"))) (EVar "env"))) (EVar "pats")) (EApp (EApp (EApp (EVar "patGroupDupErrors") (EApp (EVar "firstExprLoc") (EVar "body"))) (ELit (LString "parameter list"))) (EVar "pats"))) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "None")) (EVar "env")) (EApp (EVar "mkScope") (EApp (EVar "patsBindings") (EVar "pats")))) (EVar "body"))))
(DFunDef false "checkDecl" ((PVar "env") (PCon "DLetGroup" PWild (PVar "binds"))) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EVar "checkLetBind") (EVar "None")) (EVar "env")) (EApp (EVar "mkScope") (EApp (EApp (EMethodRef "map") (EVar "letBindName")) (EVar "binds"))))) (EVar "binds")))
(DFunDef false "checkDecl" ((PVar "env") (PCon "DTypeSig" PWild PWild (PVar "t"))) (EApp (EApp (EApp (EVar "checkType") (EVar "None")) (EVar "env")) (EVar "t")))
(DFunDef false "checkDecl" ((PVar "env") (PCon "DExtern" PWild PWild (PVar "t"))) (EApp (EApp (EApp (EVar "checkType") (EVar "None")) (EVar "env")) (EVar "t")))
(DFunDef false "checkDecl" ((PVar "env") (PRec "DData" ((rf "dataCtors" (PVar "vs"))) false)) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "checkVariant") (EVar "env"))) (EVar "vs")))
(DFunDef false "checkDecl" ((PVar "env") (PCon "DProp" PWild PWild (PVar "params") (PVar "body"))) (EApp (EApp (EApp (EVar "checkProp") (EVar "env")) (EVar "params")) (EVar "body")))
(DFunDef false "checkDecl" ((PVar "env") (PCon "DTest" PWild PWild (PVar "body"))) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "None")) (EVar "env")) (EVar "emptyScope")) (EVar "body")))
(DFunDef false "checkDecl" ((PVar "env") (PCon "DBench" PWild PWild (PVar "body"))) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "None")) (EVar "env")) (EVar "emptyScope")) (EVar "body")))
(DFunDef false "checkDecl" ((PVar "env") (PRec "DInterface" ((rf "supers" None) (rf "methods" None)) true)) (EApp (EApp (EApp (EVar "checkInterfaceDecl") (EVar "env")) (EVar "supers")) (EVar "methods")))
(DFunDef false "checkDecl" ((PVar "env") (PRec "DImpl" ((rf "iface" None) (rf "tys" None) (rf "reqs" None) (rf "methods" None)) true)) (EApp (EApp (EApp (EApp (EApp (EVar "checkImplDecl") (EVar "env")) (EVar "iface")) (EVar "tys")) (EVar "reqs")) (EVar "methods")))
(DFunDef false "checkDecl" ((PVar "env") (PRec "DTypeAlias" ((rf "tyAliasRhs" (PVar "rhs"))) false)) (EApp (EApp (EApp (EVar "checkType") (EVar "None")) (EVar "env")) (EVar "rhs")))
(DFunDef false "checkDecl" ((PVar "env") (PRec "DNewtype" ((rf "newtypeFieldTy" (PVar "fty"))) false)) (EApp (EApp (EApp (EVar "checkType") (EVar "None")) (EVar "env")) (EVar "fty")))
(DFunDef false "checkDecl" ((PVar "env") (PCon "DAttrib" PWild (PVar "inner"))) (EApp (EApp (EVar "checkDecl") (EVar "env")) (EVar "inner")))
(DFunDef false "checkDecl" (PWild PWild) (EListLit))
(DTypeSig false "checkVariant" (TyFun (TyCon "Env") (TyFun (TyCon "Variant") (TyApp (TyCon "List") (TyCon "ResError")))))
(DFunDef false "checkVariant" ((PVar "env") (PCon "Variant" PWild (PCon "ConPos" (PVar "tys")))) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "checkType") (EVar "None")) (EVar "env"))) (EVar "tys")))
(DFunDef false "checkVariant" ((PVar "env") (PCon "Variant" PWild (PCon "ConNamed" (PVar "fs") PWild))) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "checkFieldType") (EVar "env"))) (EVar "fs")))
(DTypeSig false "checkFieldType" (TyFun (TyCon "Env") (TyFun (TyCon "Field") (TyApp (TyCon "List") (TyCon "ResError")))))
(DFunDef false "checkFieldType" ((PVar "env") (PCon "Field" PWild (PVar "t"))) (EApp (EApp (EApp (EVar "checkType") (EVar "None")) (EVar "env")) (EVar "t")))
(DTypeSig false "checkProp" (TyFun (TyCon "Env") (TyFun (TyApp (TyCon "List") (TyCon "PropParam")) (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "checkProp" ((PVar "env") (PVar "params") (PVar "body")) (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EApp (EVar "checkPropParamTy") (EVar "env"))) (EVar "params")) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "None")) (EVar "env")) (EApp (EVar "mkScope") (EApp (EApp (EMethodRef "map") (EVar "propParamName")) (EVar "params")))) (EVar "body"))))
(DTypeSig false "checkPropParamTy" (TyFun (TyCon "Env") (TyFun (TyCon "PropParam") (TyApp (TyCon "List") (TyCon "ResError")))))
(DFunDef false "checkPropParamTy" ((PVar "env") (PCon "PropParam" PWild PWild (PVar "t"))) (EApp (EApp (EApp (EVar "checkType") (EVar "None")) (EVar "env")) (EVar "t")))
(DTypeSig false "propParamName" (TyFun (TyCon "PropParam") (TyCon "String")))
(DFunDef false "propParamName" ((PCon "PropParam" (PVar "x") PWild PWild)) (EVar "x"))
(DTypeSig false "checkInterfaceDecl" (TyFun (TyCon "Env") (TyFun (TyApp (TyCon "List") (TyCon "Super")) (TyFun (TyApp (TyCon "List") (TyCon "IfaceMethod")) (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "checkInterfaceDecl" ((PVar "env") (PVar "supers") (PVar "methods")) (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EApp (EVar "checkSuper") (EVar "env"))) (EVar "supers")) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "checkIfaceMethod") (EVar "env"))) (EVar "methods"))))
(DTypeSig false "checkSuper" (TyFun (TyCon "Env") (TyFun (TyCon "Super") (TyApp (TyCon "List") (TyCon "ResError")))))
(DFunDef false "checkSuper" ((PVar "env") (PRec "Super" ((rf "superHead" (PVar "iface"))) false)) (EIf (EApp (EApp (EVar "contains") (EVar "iface")) (EFieldAccess (EVar "env") "interfaces")) (EApp (EApp (EApp (EVar "ambiguousIfaceErrors") (EVar "env")) (EVar "iface")) (EVar "None")) (EListLit (EApp (EApp (EVar "UnknownInterface") (EVar "iface")) (EVar "None")))))
(DTypeSig false "checkIfaceMethod" (TyFun (TyCon "Env") (TyFun (TyCon "IfaceMethod") (TyApp (TyCon "List") (TyCon "ResError")))))
(DFunDef false "checkIfaceMethod" ((PVar "env") (PCon "IfaceMethod" PWild (PVar "t") (PCon "None") PWild)) (EApp (EApp (EApp (EVar "checkType") (EVar "None")) (EVar "env")) (EVar "t")))
(DFunDef false "checkIfaceMethod" ((PVar "env") (PCon "IfaceMethod" PWild (PVar "t") (PCon "Some" (PCon "MethodDefault" (PVar "pats") (PVar "body"))) PWild)) (EBinOp "++" (EBinOp "++" (EApp (EApp (EApp (EVar "checkType") (EVar "None")) (EVar "env")) (EVar "t")) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "checkPat") (EApp (EVar "firstExprLoc") (EVar "body"))) (EVar "env"))) (EVar "pats"))) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "None")) (EVar "env")) (EApp (EVar "mkScope") (EApp (EVar "patsBindings") (EVar "pats")))) (EVar "body"))))
(DTypeSig false "checkImplDecl" (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyApp (TyCon "List") (TyCon "Require")) (TyFun (TyApp (TyCon "List") (TyCon "ImplMethod")) (TyApp (TyCon "List") (TyCon "ResError"))))))))
(DFunDef false "checkImplDecl" ((PVar "env") (PVar "iface") (PVar "tyargs") (PVar "reqs") (PVar "methods")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "checkType") (EVar "None")) (EVar "env"))) (EVar "tyargs")) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "checkRequire") (EVar "env"))) (EVar "reqs"))) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "checkImplMethod") (EVar "env"))) (EVar "methods"))) (EApp (EApp (EApp (EVar "checkImplIface") (EVar "env")) (EVar "iface")) (EVar "methods"))) (EApp (EApp (EApp (EVar "ambiguousIfaceErrors") (EVar "env")) (EVar "iface")) (EApp (EVar "firstTyLocList") (EVar "tyargs")))))
(DTypeSig false "checkRequire" (TyFun (TyCon "Env") (TyFun (TyCon "Require") (TyApp (TyCon "List") (TyCon "ResError")))))
(DFunDef false "checkRequire" ((PVar "env") (PRec "Require" ((rf "requireHead" (PVar "iface")) (rf "requireArgs" (PVar "tys"))) false)) (EBinOp "++" (EIf (EApp (EApp (EVar "contains") (EVar "iface")) (EFieldAccess (EVar "env") "interfaces")) (EApp (EApp (EApp (EVar "ambiguousIfaceErrors") (EVar "env")) (EVar "iface")) (EApp (EVar "firstTyLocList") (EVar "tys"))) (EListLit (EApp (EApp (EVar "UnknownInterface") (EVar "iface")) (EVar "None")))) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "checkType") (EVar "None")) (EVar "env"))) (EVar "tys"))))
(DTypeSig false "checkImplMethod" (TyFun (TyCon "Env") (TyFun (TyCon "ImplMethod") (TyApp (TyCon "List") (TyCon "ResError")))))
(DFunDef false "checkImplMethod" ((PVar "env") (PCon "ImplMethod" PWild (PVar "pats") (PVar "body"))) (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "checkPat") (EApp (EVar "firstExprLoc") (EVar "body"))) (EVar "env"))) (EVar "pats")) (EApp (EApp (EApp (EApp (EVar "checkExpr") (EVar "None")) (EVar "env")) (EApp (EVar "mkScope") (EApp (EVar "patsBindings") (EVar "pats")))) (EVar "body"))))
(DTypeSig false "checkImplIface" (TyFun (TyCon "Env") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "ImplMethod")) (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "checkImplIface" ((PVar "env") (PVar "iface") (PVar "methods")) (EIf (EApp (EVar "not") (EApp (EApp (EVar "contains") (EVar "iface")) (EFieldAccess (EVar "env") "interfaces"))) (EListLit (EApp (EApp (EVar "UnknownInterface") (EVar "iface")) (EVar "None"))) (EIf (EVar "otherwise") (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "checkMethodMember") (EVar "iface")) (EApp (EApp (EVar "ifaceMethodsOf") (EVar "iface")) (EFieldAccess (EVar "env") "ifaceMethods")))) (EVar "methods")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "ifaceMethodsOf" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "ifaceMethodsOf" (PWild (PList)) (EListLit))
(DFunDef false "ifaceMethodsOf" ((PVar "iface") (PCons (PTuple (PVar "i") (PVar "ms")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "i") (EVar "iface")) (EVar "ms") (EIf (EVar "otherwise") (EApp (EApp (EVar "ifaceMethodsOf") (EVar "iface")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "checkMethodMember" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "ImplMethod") (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "checkMethodMember" ((PVar "iface") (PVar "known") (PCon "ImplMethod" (PVar "mname") PWild PWild)) (EIf (EApp (EApp (EVar "contains") (EVar "mname")) (EVar "known")) (EListLit) (EListLit (EApp (EApp (EApp (EVar "MethodNotInInterface") (EVar "mname")) (EVar "iface")) (EVar "None")))))
(DTypeSig false "isTupleCtorTyName" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isTupleCtorTyName" ((PVar "n")) (EApp (EApp (EVar "contains") (EVar "n")) (EVar "tupleCtorTyNames")))
(DTypeSig false "tupleCtorTyNames" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "tupleCtorTyNames" () (EListLit (ELit (LString "__tuple2__")) (ELit (LString "__tuple3__")) (ELit (LString "__tuple4__")) (ELit (LString "__tuple5__"))))
(DTypeSig false "primitiveTypes" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "primitiveTypes" () (EListLit (ELit (LString "Int")) (ELit (LString "Float")) (ELit (LString "String")) (ELit (LString "Char")) (ELit (LString "Bool")) (ELit (LString "Unit")) (ELit (LString "List")) (ELit (LString "Ref")) (ELit (LString "Array"))))
(DTypeSig false "primitiveConstructors" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "primitiveConstructors" () (EListLit (ELit (LString "True")) (ELit (LString "False"))))
(DTypeSig false "externNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "externNames" ((PList)) (EListLit))
(DFunDef false "externNames" ((PCons (PCon "DExtern" PWild (PVar "n") PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "externNames") (EVar "rest"))))
(DFunDef false "externNames" ((PCons PWild (PVar "rest"))) (EApp (EVar "externNames") (EVar "rest")))
(DTypeSig false "dataRecordNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "dataRecordNames" ((PList)) (EListLit))
(DFunDef false "dataRecordNames" ((PCons (PRec "DData" ((rf "dataName" (PVar "n"))) false) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "dataRecordNames") (EVar "rest"))))
(DFunDef false "dataRecordNames" ((PCons (PRec "DTypeAlias" ((rf "tyAliasName" (PVar "n"))) false) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "dataRecordNames") (EVar "rest"))))
(DFunDef false "dataRecordNames" ((PCons (PRec "DNewtype" ((rf "newtypeName" (PVar "n"))) false) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "dataRecordNames") (EVar "rest"))))
(DFunDef false "dataRecordNames" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "dataRecordNames") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "dataRecordNames" ((PCons PWild (PVar "rest"))) (EApp (EVar "dataRecordNames") (EVar "rest")))
(DTypeSig false "effectNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "effectNames" ((PList)) (EListLit))
(DFunDef false "effectNames" ((PCons (PCon "DEffect" PWild (PVar "n") PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "effectNames") (EVar "rest"))))
(DFunDef false "effectNames" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "effectNames") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "effectNames" ((PCons PWild (PVar "rest"))) (EApp (EVar "effectNames") (EVar "rest")))
(DTypeSig false "ctorNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "ctorNames" ((PList)) (EListLit))
(DFunDef false "ctorNames" ((PCons (PRec "DData" ((rf "dataCtors" (PVar "vs"))) false) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EMethodRef "map") (EVar "variantName")) (EVar "vs")) (EApp (EVar "ctorNames") (EVar "rest"))))
(DFunDef false "ctorNames" ((PCons (PRec "DNewtype" ((rf "newtypeCtor" (PVar "con"))) false) (PVar "rest"))) (EBinOp "::" (EVar "con") (EApp (EVar "ctorNames") (EVar "rest"))))
(DFunDef false "ctorNames" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "ctorNames") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "ctorNames" ((PCons PWild (PVar "rest"))) (EApp (EVar "ctorNames") (EVar "rest")))
(DTypeSig false "variantName" (TyFun (TyCon "Variant") (TyCon "String")))
(DFunDef false "variantName" ((PCon "Variant" (PVar "n") PWild)) (EVar "n"))
(DTypeSig false "ifaceMethodNm" (TyFun (TyCon "IfaceMethod") (TyCon "String")))
(DFunDef false "ifaceMethodNm" ((PCon "IfaceMethod" (PVar "n") PWild PWild PWild)) (EVar "n"))
(DTypeSig false "implMethodNm" (TyFun (TyCon "ImplMethod") (TyCon "String")))
(DFunDef false "implMethodNm" ((PCon "ImplMethod" (PVar "n") PWild PWild)) (EVar "n"))
(DTypeSig false "interfaceList" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "interfaceList" ((PList)) (EListLit))
(DFunDef false "interfaceList" ((PCons (PRec "DInterface" ((rf "name" (PVar "n")) (rf "methods" None)) true) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "n") (EApp (EApp (EMethodRef "map") (EVar "ifaceMethodNm")) (EVar "methods"))) (EApp (EVar "interfaceList") (EVar "rest"))))
(DFunDef false "interfaceList" ((PCons PWild (PVar "rest"))) (EApp (EVar "interfaceList") (EVar "rest")))
(DTypeSig false "preludeValueNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "preludeValueNames" ((PList)) (EListLit))
(DFunDef false "preludeValueNames" ((PCons (PCon "DFunDef" PWild (PVar "n") PWild PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "preludeValueNames") (EVar "rest"))))
(DFunDef false "preludeValueNames" ((PCons (PCon "DTypeSig" PWild (PVar "n") PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "preludeValueNames") (EVar "rest"))))
(DFunDef false "preludeValueNames" ((PCons (PRec "DImpl" ((rf "methods" None)) true) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EMethodRef "map") (EVar "implMethodNm")) (EVar "methods")) (EApp (EVar "preludeValueNames") (EVar "rest"))))
(DFunDef false "preludeValueNames" ((PCons (PRec "DInterface" ((rf "methods" None)) true) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EMethodRef "map") (EVar "ifaceMethodNm")) (EVar "methods")) (EApp (EVar "preludeValueNames") (EVar "rest"))))
(DFunDef false "preludeValueNames" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "preludeValueNames") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "preludeValueNames" ((PCons PWild (PVar "rest"))) (EApp (EVar "preludeValueNames") (EVar "rest")))
(DTypeSig false "userValueNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "userValueNames" ((PList)) (EListLit))
(DFunDef false "userValueNames" ((PCons (PCon "DFunDef" PWild (PVar "n") PWild PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "userValueNames") (EVar "rest"))))
(DFunDef false "userValueNames" ((PCons (PCon "DTypeSig" PWild (PVar "n") PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "userValueNames") (EVar "rest"))))
(DFunDef false "userValueNames" ((PCons (PCon "DExtern" PWild (PVar "n") PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "userValueNames") (EVar "rest"))))
(DFunDef false "userValueNames" ((PCons (PCon "DLetGroup" PWild (PVar "bs")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EMethodRef "map") (EVar "letBindName")) (EVar "bs")) (EApp (EVar "userValueNames") (EVar "rest"))))
(DFunDef false "userValueNames" ((PCons (PRec "DInterface" ((rf "methods" None)) true) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EMethodRef "map") (EVar "ifaceMethodNm")) (EVar "methods")) (EApp (EVar "userValueNames") (EVar "rest"))))
(DFunDef false "userValueNames" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "userValueNames") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "userValueNames" ((PCons PWild (PVar "rest"))) (EApp (EVar "userValueNames") (EVar "rest")))
(DTypeSig false "fieldOwnersOf" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "fieldOwnersOf" ((PList)) (EListLit))
(DFunDef false "fieldOwnersOf" ((PCons (PRec "DData" ((rf "dataCtors" (PVar "vs"))) false) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EVar "variantFieldOwners")) (EVar "vs")) (EApp (EVar "fieldOwnersOf") (EVar "rest"))))
(DFunDef false "fieldOwnersOf" ((PCons PWild (PVar "rest"))) (EApp (EVar "fieldOwnersOf") (EVar "rest")))
(DTypeSig false "recordFieldOwner" (TyFun (TyCon "String") (TyFun (TyCon "Field") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "recordFieldOwner" ((PVar "owner") (PCon "Field" (PVar "fname") PWild)) (ETuple (EVar "fname") (EVar "owner")))
(DTypeSig false "variantFieldOwners" (TyFun (TyCon "Variant") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "variantFieldOwners" ((PCon "Variant" (PVar "cname") (PCon "ConNamed" (PVar "fs") PWild))) (EApp (EApp (EMethodRef "map") (EApp (EVar "recordFieldOwner") (EVar "cname"))) (EVar "fs")))
(DFunDef false "variantFieldOwners" ((PCon "Variant" PWild (PCon "ConPos" PWild))) (EListLit))
(DTypeSig false "importedNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "importedNames" ((PList)) (EListLit))
(DFunDef false "importedNames" ((PCons (PCon "DUse" PWild (PVar "path") PWild) (PVar "rest"))) (EBinOp "++" (EApp (EVar "useImportNames") (EVar "path")) (EApp (EVar "importedNames") (EVar "rest"))))
(DFunDef false "importedNames" ((PCons PWild (PVar "rest"))) (EApp (EVar "importedNames") (EVar "rest")))
(DTypeSig false "useImportNames" (TyFun (TyCon "UsePath") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "useImportNames" ((PVar "path")) (EIf (EBinOp "==" (EApp (EVar "useModId") (EVar "path")) (ELit (LString "core"))) (EListLit) (EApp (EVar "useStubNames") (EVar "path"))))
(DTypeSig false "useStubNames" (TyFun (TyCon "UsePath") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "useStubNames" ((PCon "UseName" (PVar "ns"))) (EListLit (EApp (EVar "lastOf") (EVar "ns"))))
(DFunDef false "useStubNames" ((PCon "UseGroup" PWild (PVar "ms"))) (EApp (EApp (EMethodRef "map") (EVar "useMemberLocal")) (EVar "ms")))
(DFunDef false "useStubNames" ((PCon "UseWild" PWild)) (EListLit))
(DFunDef false "useStubNames" ((PCon "UseAlias" PWild PWild)) (EListLit))
(DTypeSig false "useModId" (TyFun (TyCon "UsePath") (TyCon "String")))
(DFunDef false "useModId" ((PCon "UseName" (PVar "ns"))) (EIf (EBinOp ">" (EApp (EVar "listLen") (EVar "ns")) (ELit (LInt 1))) (EApp (EVar "joinDot") (EApp (EVar "initList") (EVar "ns"))) (EApp (EApp (EVar "firstOr") (ELit (LString ""))) (EVar "ns"))))
(DFunDef false "useModId" ((PCon "UseGroup" (PVar "ns") PWild)) (EApp (EVar "joinDot") (EVar "ns")))
(DFunDef false "useModId" ((PCon "UseWild" (PVar "ns"))) (EApp (EVar "joinDot") (EVar "ns")))
(DFunDef false "useModId" ((PCon "UseAlias" (PVar "ns") PWild)) (EApp (EVar "joinDot") (EVar "ns")))
(DTypeSig false "lastOf" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "lastOf" ((PList)) (ELit (LString "")))
(DFunDef false "lastOf" ((PList (PVar "x"))) (EVar "x"))
(DFunDef false "lastOf" ((PCons PWild (PVar "rest"))) (EApp (EVar "lastOf") (EVar "rest")))
(DTypeSig false "firstOr" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))
(DFunDef false "firstOr" ((PVar "d") (PList)) (EVar "d"))
(DFunDef false "firstOr" (PWild (PCons (PVar "x") PWild)) (EVar "x"))
(DTypeSig false "programIsCore" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool")))
(DFunDef false "programIsCore" ((PVar "prog")) (EBinOp "&&" (EApp (EVar "hasOrdering") (EVar "prog")) (EApp (EVar "hasFoldable") (EVar "prog"))))
(DTypeSig false "hasOrdering" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool")))
(DFunDef false "hasOrdering" ((PList)) (EVar "False"))
(DFunDef false "hasOrdering" ((PCons (PRec "DData" ((rf "dataName" (PLit (LString "Ordering")))) false) PWild)) (EVar "True"))
(DFunDef false "hasOrdering" ((PCons PWild (PVar "rest"))) (EApp (EVar "hasOrdering") (EVar "rest")))
(DTypeSig false "hasFoldable" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool")))
(DFunDef false "hasFoldable" ((PList)) (EVar "False"))
(DFunDef false "hasFoldable" ((PCons (PRec "DInterface" ((rf "name" (PLit (LString "Foldable")))) true) PWild)) (EVar "True"))
(DFunDef false "hasFoldable" ((PCons PWild (PVar "rest"))) (EApp (EVar "hasFoldable") (EVar "rest")))
(DTypeSig false "buildEnv" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Env"))))))
(DFunDef false "buildEnv" ((PVar "runtimeDecls") (PVar "preludeDecls") (PVar "prog") (PVar "internalGuard")) (EBlock (DoLet false false (PVar "seed") (EApp (EVar "not") (EApp (EVar "programIsCore") (EVar "prog")))) (DoLet false false (PVar "pTypes") (EApp (EApp (EVar "whenL") (EVar "seed")) (EApp (EVar "dataRecordNames") (EVar "preludeDecls")))) (DoLet false false (PVar "pCtors") (EApp (EApp (EVar "whenL") (EVar "seed")) (EApp (EVar "ctorNames") (EVar "preludeDecls")))) (DoLet false false (PVar "pIfaces") (EApp (EApp (EVar "whenL") (EVar "seed")) (EApp (EVar "interfaceList") (EVar "preludeDecls")))) (DoLet false false (PVar "pValues") (EApp (EApp (EVar "whenL") (EVar "seed")) (EApp (EVar "preludeValueNames") (EVar "preludeDecls")))) (DoLet false false (PVar "pFieldOwners") (EApp (EApp (EVar "whenL") (EVar "seed")) (EApp (EVar "fieldOwnersOf") (EVar "preludeDecls")))) (DoLet false false (PVar "uIfaces") (EApp (EVar "interfaceList") (EVar "prog"))) (DoLet false false (PVar "imported") (EApp (EVar "importedNames") (EVar "prog"))) (DoLet false false (PVar "valuesM") (EApp (EApp (EVar "omFromNames") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EApp (EVar "externNames") (EVar "runtimeDecls")) (EVar "pValues")) (EApp (EVar "userValueNames") (EVar "prog"))) (EVar "imported"))) (EVar "omEmpty"))) (DoLet false false (PVar "typesM") (EApp (EApp (EVar "omFromNames") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EVar "primitiveTypes") (EVar "pTypes")) (EApp (EVar "dataRecordNames") (EVar "prog"))) (EVar "imported"))) (EVar "omEmpty"))) (DoLet false false (PVar "ctorsM") (EApp (EApp (EVar "omFromNames") (EBinOp "++" (EBinOp "++" (EVar "primitiveConstructors") (EVar "pCtors")) (EApp (EVar "ctorNames") (EVar "prog")))) (EVar "omEmpty"))) (DoLet false false (PVar "importedM") (EApp (EApp (EVar "omFromNames") (EVar "imported")) (EVar "omEmpty"))) (DoExpr (ERecordCreate "Env" ((fa "values" (EVar "valuesM")) (fa "types" (EVar "typesM")) (fa "ctors" (EVar "ctorsM")) (fa "fields" (EBinOp "++" (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "pFieldOwners")) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EApp (EVar "fieldOwnersOf") (EVar "prog"))))) (fa "fieldOwners" (EBinOp "++" (EVar "pFieldOwners") (EApp (EVar "fieldOwnersOf") (EVar "prog")))) (fa "fieldOwnersIdx" (EApp (EVar "buildFieldOwnerIndex") (EBinOp "++" (EVar "pFieldOwners") (EApp (EVar "fieldOwnersOf") (EVar "prog"))))) (fa "interfaces" (EBinOp "++" (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "pIfaces")) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "uIfaces")))) (fa "ifaceMethods" (EBinOp "++" (EVar "pIfaces") (EVar "uIfaces"))) (fa "effects" (EApp (EVar "effectNames") (EVar "prog"))) (fa "imported" (EVar "importedM")) (fa "importedModuleValues" (EListLit)) (fa "ambiguous" (EListLit)) (fa "ctorAmbiguous" (EListLit)) (fa "typeAmbiguous" (EListLit)) (fa "ifaceAmbiguous" (EListLit)) (fa "internalGuard" (EApp (EApp (EVar "omFromNames") (EVar "internalGuard")) (EVar "omEmpty"))) (fa "sugValues" (EApp (EVar "sugPoolOf") (EBinOp "++" (EBinOp "++" (EApp (EVar "omKeys") (EVar "valuesM")) (EApp (EVar "omKeys") (EVar "ctorsM"))) (EApp (EVar "omKeys") (EVar "importedM"))))) (fa "sugTypes" (EApp (EVar "sugPoolOf") (EBinOp "++" (EApp (EVar "omKeys") (EVar "typesM")) (EApp (EVar "omKeys") (EVar "importedM"))))))))))
(DTypeSig false "whenL" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "whenL" ((PCon "True") (PVar "xs")) (EVar "xs"))
(DFunDef false "whenL" ((PCon "False") PWild) (EListLit))
(DTypeSig false "buildErrors" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "ResError")))))
(DFunDef false "buildErrors" ((PVar "preludeDecls") (PVar "prog")) (EBlock (DoLet false false (PVar "dupValErrs") (EApp (EVar "dupValueBindingErrors") (EVar "prog"))) (DoLet false false (PVar "nullaryDupNames") (EApp (EApp (EMethodRef "map") (EVar "dvbName")) (EVar "dupValErrs"))) (DoLet false false (PVar "sigDups") (EApp (EApp (EApp (EVar "filterOutNamesIn") (EVar "nullaryDupNames")) (EVar "dupSigName")) (EApp (EVar "dupSignatureErrors") (EVar "prog")))) (DoLet false false (PVar "sigDupNames") (EApp (EApp (EMethodRef "map") (EVar "dupSigName")) (EVar "sigDups"))) (DoLet false false (PVar "contigErrs") (EApp (EApp (EApp (EVar "filterOutNamesIn") (EVar "sigDupNames")) (EVar "dbName")) (EApp (EVar "contiguityErrors") (EVar "prog")))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "externWithBodyErrors") (EApp (EVar "externNames") (EVar "prog"))) (EVar "prog")) (EApp (EApp (EVar "duplicateErrors") (EVar "preludeDecls")) (EVar "prog"))) (EApp (EApp (EVar "coreUseErrors") (EVar "preludeDecls")) (EVar "prog"))) (EVar "sigDups")) (EVar "contigErrs")) (EVar "dupValErrs")))))
(DTypeSig false "coreUseErrors" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "ResError")))))
(DFunDef false "coreUseErrors" ((PVar "preludeDecls") (PVar "prog")) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "coreUseErrorsOf") (EApp (EVar "coreExports") (EVar "preludeDecls")))) (EVar "prog")))
(DTypeSig false "coreUseErrorsOf" (TyFun (TyCon "ModuleExports") (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "ResError")))))
(DFunDef false "coreUseErrorsOf" ((PVar "coreExp") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EVar "coreUseErrorsOf") (EVar "coreExp")) (EVar "d")))
(DFunDef false "coreUseErrorsOf" ((PVar "coreExp") (PCon "DUse" PWild (PVar "path") (PVar "loc"))) (EIf (EBinOp "==" (EApp (EVar "useModId") (EVar "path")) (ELit (LString "core"))) (EBlock (DoLet false false (PTuple PWild (PVar "errs")) (EApp (EApp (EVar "importedNamesMM") (EVar "path")) (EVar "coreExp"))) (DoExpr (EApp (EApp (EMethodRef "map") (EApp (EVar "withResErrorLoc") (EVar "loc"))) (EVar "errs")))) (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "coreUseErrorsOf" (PWild PWild) (EListLit))
(DTypeSig false "dvbName" (TyFun (TyCon "ResError") (TyCon "String")))
(DFunDef false "dvbName" ((PCon "DuplicateValueBinding" (PVar "n") PWild)) (EVar "n"))
(DFunDef false "dvbName" (PWild) (ELit (LString "")))
(DTypeSig false "dupSigName" (TyFun (TyCon "ResError") (TyCon "String")))
(DFunDef false "dupSigName" ((PCon "DuplicateSignature" (PVar "n") PWild PWild)) (EVar "n"))
(DFunDef false "dupSigName" (PWild) (ELit (LString "")))
(DTypeSig false "dbName" (TyFun (TyCon "ResError") (TyCon "String")))
(DFunDef false "dbName" ((PCon "DuplicateBinding" (PVar "n") PWild)) (EVar "n"))
(DFunDef false "dbName" (PWild) (ELit (LString "")))
(DTypeSig false "filterOutNamesIn" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyFun (TyCon "ResError") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "ResError")) (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "filterOutNamesIn" (PWild PWild (PList)) (EListLit))
(DFunDef false "filterOutNamesIn" ((PVar "names") (PVar "nameOf") (PCons (PVar "e") (PVar "rest"))) (EIf (EApp (EApp (EVar "contains") (EApp (EVar "nameOf") (EVar "e"))) (EVar "names")) (EApp (EApp (EApp (EVar "filterOutNamesIn") (EVar "names")) (EVar "nameOf")) (EVar "rest")) (EIf (EVar "otherwise") (EBinOp "::" (EVar "e") (EApp (EApp (EApp (EVar "filterOutNamesIn") (EVar "names")) (EVar "nameOf")) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "dupSignatureErrors" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "ResError"))))
(DFunDef false "dupSignatureErrors" ((PVar "prog")) (EApp (EApp (EVar "dupSigGo") (EVar "prog")) (EVar "omEmpty")))
(DTypeSig false "dupSigGo" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "List") (TyCon "ResError")))))
(DFunDef false "dupSigGo" ((PList) PWild) (EListLit))
(DFunDef false "dupSigGo" ((PCons (PVar "d") (PVar "rest")) (PVar "seen")) (EMatch (EApp (EVar "dupSigOf") (EVar "d")) (arm (PCon "Some" (PTuple (PVar "n") (PVar "loc"))) () (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "seen")) (arm (PCon "Some" (PVar "earlierLoc")) () (EBinOp "::" (EApp (EApp (EApp (EVar "DuplicateSignature") (EVar "n")) (EVar "loc")) (EVar "earlierLoc")) (EApp (EApp (EVar "dupSigGo") (EVar "rest")) (EVar "seen")))) (arm (PCon "None") () (EApp (EApp (EVar "dupSigGo") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (EVar "loc")) (EVar "seen")))))) (arm (PCon "None") () (EApp (EApp (EVar "dupSigGo") (EVar "rest")) (EVar "seen")))))
(DTypeSig false "dupSigOf" (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc"))))))
(DFunDef false "dupSigOf" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "dupSigOf") (EVar "d")))
(DFunDef false "dupSigOf" ((PCon "DTypeSig" PWild (PVar "n") (PVar "ty"))) (EApp (EVar "Some") (ETuple (EVar "n") (EApp (EVar "firstTyLoc") (EVar "ty")))))
(DFunDef false "dupSigOf" (PWild) (EVar "None"))
(DTypeSig false "dupValueBindingErrors" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "ResError"))))
(DFunDef false "dupValueBindingErrors" ((PVar "prog")) (EApp (EApp (EApp (EVar "dupValGo") (EVar "None")) (EVar "False")) (EVar "prog")))
(DTypeSig false "dupValGo" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "dupValGo" (PWild PWild (PList)) (EListLit))
(DFunDef false "dupValGo" ((PVar "run") (PVar "sawNullary") (PCons (PVar "d") (PVar "rest"))) (EIf (EApp (EVar "isTransparentDecl") (EVar "d")) (EApp (EApp (EApp (EVar "dupValGo") (EVar "run")) (EVar "sawNullary")) (EVar "rest")) (EIf (EVar "otherwise") (EMatch (EApp (EVar "dupValClause") (EVar "d")) (arm (PCon "Some" (PTuple (PVar "n") (PVar "isNull") (PVar "loc"))) () (EBlock (DoLet false false (PVar "continuing") (EBinOp "==" (EVar "run") (EApp (EVar "Some") (EVar "n")))) (DoLet false false (PVar "dup") (EBinOp "&&" (EVar "continuing") (EBinOp "||" (EVar "sawNullary") (EVar "isNull")))) (DoLet false false (PVar "errs") (EApp (EApp (EVar "whenL") (EVar "dup")) (EListLit (EApp (EApp (EVar "DuplicateValueBinding") (EVar "n")) (EVar "loc"))))) (DoLet false false (PVar "sawNullary2") (EBinOp "||" (EBinOp "&&" (EVar "continuing") (EVar "sawNullary")) (EVar "isNull"))) (DoExpr (EBinOp "++" (EVar "errs") (EApp (EApp (EApp (EVar "dupValGo") (EApp (EVar "Some") (EVar "n"))) (EVar "sawNullary2")) (EVar "rest")))))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "dupValGo") (EVar "None")) (EVar "False")) (EVar "rest")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "dupValClause" (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Bool") (TyApp (TyCon "Option") (TyCon "Loc"))))))
(DFunDef false "dupValClause" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "dupValClause") (EVar "d")))
(DFunDef false "dupValClause" ((PCon "DFunDef" PWild (PVar "n") (PVar "ps") (PVar "body"))) (EApp (EVar "Some") (ETuple (EVar "n") (EApp (EVar "isEmptyL") (EVar "ps")) (EApp (EVar "firstExprLoc") (EVar "body")))))
(DFunDef false "dupValClause" (PWild) (EVar "None"))
(DTypeSig false "isEmptyL" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "Bool")))
(DFunDef false "isEmptyL" ((PList)) (EVar "True"))
(DFunDef false "isEmptyL" (PWild) (EVar "False"))
(DTypeSig false "declBindNames" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "declBindNames" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "declBindNames") (EVar "d")))
(DFunDef false "declBindNames" ((PCon "DFunDef" PWild (PVar "n") PWild PWild)) (EListLit (EVar "n")))
(DFunDef false "declBindNames" ((PCon "DLetGroup" PWild (PVar "bs"))) (EApp (EApp (EMethodRef "map") (EVar "letBindName")) (EVar "bs")))
(DFunDef false "declBindNames" (PWild) (EListLit))
(DTypeSig false "isTransparentDecl" (TyFun (TyCon "Decl") (TyCon "Bool")))
(DFunDef false "isTransparentDecl" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "isTransparentDecl") (EVar "d")))
(DFunDef false "isTransparentDecl" ((PCon "DTypeSig" PWild PWild PWild)) (EVar "True"))
(DFunDef false "isTransparentDecl" (PWild) (EVar "False"))
(DTypeSig false "contiguityErrors" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "ResError"))))
(DFunDef false "contiguityErrors" ((PVar "prog")) (EApp (EApp (EApp (EVar "contigGo") (EVar "omEmpty")) (EListLit)) (EVar "prog")))
(DTypeSig false "contigGo" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "contigGo" (PWild PWild (PList)) (EListLit))
(DFunDef false "contigGo" ((PVar "closed") (PVar "opened") (PCons (PVar "d") (PVar "rest"))) (EIf (EApp (EVar "isTransparentDecl") (EVar "d")) (EApp (EApp (EApp (EVar "contigGo") (EVar "closed")) (EVar "opened")) (EVar "rest")) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "ns") (EApp (EVar "declBindNames") (EVar "d"))) (DoLet false false (PVar "stillOpen") (EApp (EApp (EVar "filterKeepOpen") (EVar "ns")) (EVar "opened"))) (DoLet false false (PVar "nowClosed") (EApp (EApp (EApp (EVar "closeMissing") (EVar "opened")) (EVar "stillOpen")) (EVar "closed"))) (DoLet false false (PVar "errs") (EApp (EApp (EApp (EVar "newlyDuplicated") (EApp (EVar "declLoc") (EVar "d"))) (EVar "nowClosed")) (EVar "ns"))) (DoLet false false (PVar "opened2") (EApp (EApp (EVar "unionStr") (EVar "stillOpen")) (EVar "ns"))) (DoLet false false (PVar "closed2") (EApp (EApp (EVar "deleteAllStr") (EVar "ns")) (EVar "nowClosed"))) (DoExpr (EBinOp "++" (EVar "errs") (EApp (EApp (EApp (EVar "contigGo") (EVar "closed2")) (EVar "opened2")) (EVar "rest"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "filterKeepOpen" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "filterKeepOpen" (PWild (PList)) (EListLit))
(DFunDef false "filterKeepOpen" ((PVar "ns") (PCons (PVar "o") (PVar "os"))) (EIf (EApp (EApp (EVar "contains") (EVar "o")) (EVar "ns")) (EBinOp "::" (EVar "o") (EApp (EApp (EVar "filterKeepOpen") (EVar "ns")) (EVar "os"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "filterKeepOpen") (EVar "ns")) (EVar "os")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "closeMissing" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit"))))))
(DFunDef false "closeMissing" ((PList) PWild (PVar "closed")) (EVar "closed"))
(DFunDef false "closeMissing" ((PCons (PVar "o") (PVar "os")) (PVar "stillOpen") (PVar "closed")) (EIf (EApp (EApp (EVar "contains") (EVar "o")) (EVar "stillOpen")) (EApp (EApp (EApp (EVar "closeMissing") (EVar "os")) (EVar "stillOpen")) (EVar "closed")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "closeMissing") (EVar "os")) (EVar "stillOpen")) (EApp (EApp (EApp (EVar "omInsert") (EVar "o")) (ELit LUnit)) (EVar "closed"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "deleteAllStr" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit")))))
(DFunDef false "deleteAllStr" ((PList) (PVar "closed")) (EVar "closed"))
(DFunDef false "deleteAllStr" ((PCons (PVar "n") (PVar "ns")) (PVar "closed")) (EApp (EApp (EVar "deleteAllStr") (EVar "ns")) (EApp (EApp (EVar "omDelete") (EVar "n")) (EVar "closed"))))
(DTypeSig false "newlyDuplicated" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "newlyDuplicated" (PWild PWild (PList)) (EListLit))
(DFunDef false "newlyDuplicated" ((PVar "loc") (PVar "closed") (PCons (PVar "n") (PVar "ns"))) (EIf (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "closed")) (EBinOp "::" (EApp (EApp (EVar "DuplicateBinding") (EVar "n")) (EVar "loc")) (EApp (EApp (EApp (EVar "newlyDuplicated") (EVar "loc")) (EVar "closed")) (EVar "ns"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "newlyDuplicated") (EVar "loc")) (EVar "closed")) (EVar "ns")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "declLoc" (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "declLoc" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "declLoc") (EVar "d")))
(DFunDef false "declLoc" ((PCon "DFunDef" PWild PWild PWild (PVar "body"))) (EApp (EVar "firstExprLoc") (EVar "body")))
(DFunDef false "declLoc" (PWild) (EVar "None"))
(DTypeSig false "firstExprLoc" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "firstExprLoc" ((PCon "ELoc" (PVar "l") PWild)) (EApp (EVar "Some") (EVar "l")))
(DFunDef false "firstExprLoc" ((PCon "EApp" (PVar "f") (PVar "x"))) (EApp (EApp (EVar "orElseLoc") (EApp (EVar "firstExprLoc") (EVar "f"))) (EApp (EVar "firstExprLoc") (EVar "x"))))
(DFunDef false "firstExprLoc" ((PCon "ELam" PWild (PVar "body"))) (EApp (EVar "firstExprLoc") (EVar "body")))
(DFunDef false "firstExprLoc" ((PCon "ELet" PWild PWild PWild (PVar "e1") (PVar "e2"))) (EApp (EApp (EVar "orElseLoc") (EApp (EVar "firstExprLoc") (EVar "e1"))) (EApp (EVar "firstExprLoc") (EVar "e2"))))
(DFunDef false "firstExprLoc" ((PCon "ELetGroup" PWild (PVar "body"))) (EApp (EVar "firstExprLoc") (EVar "body")))
(DFunDef false "firstExprLoc" ((PCon "EMatch" (PVar "e0") PWild)) (EApp (EVar "firstExprLoc") (EVar "e0")))
(DFunDef false "firstExprLoc" ((PCon "EIf" (PVar "c") (PVar "t") (PVar "el"))) (EApp (EApp (EVar "orElseLoc") (EApp (EVar "firstExprLoc") (EVar "c"))) (EApp (EApp (EVar "orElseLoc") (EApp (EVar "firstExprLoc") (EVar "t"))) (EApp (EVar "firstExprLoc") (EVar "el")))))
(DFunDef false "firstExprLoc" ((PCon "EBinOp" PWild (PVar "a") (PVar "b") PWild)) (EApp (EApp (EVar "orElseLoc") (EApp (EVar "firstExprLoc") (EVar "a"))) (EApp (EVar "firstExprLoc") (EVar "b"))))
(DFunDef false "firstExprLoc" ((PCon "EUnOp" PWild (PVar "a") PWild)) (EApp (EVar "firstExprLoc") (EVar "a")))
(DFunDef false "firstExprLoc" ((PCon "EInfix" PWild (PVar "a") (PVar "b"))) (EApp (EApp (EVar "orElseLoc") (EApp (EVar "firstExprLoc") (EVar "a"))) (EApp (EVar "firstExprLoc") (EVar "b"))))
(DFunDef false "firstExprLoc" ((PCon "EFieldAccess" (PVar "e0") PWild PWild)) (EApp (EVar "firstExprLoc") (EVar "e0")))
(DFunDef false "firstExprLoc" ((PCon "ETuple" (PVar "es"))) (EApp (EVar "firstLocList") (EVar "es")))
(DFunDef false "firstExprLoc" ((PCon "EListLit" (PVar "es"))) (EApp (EVar "firstLocList") (EVar "es")))
(DFunDef false "firstExprLoc" ((PCon "EArrayLit" (PVar "es"))) (EApp (EVar "firstLocList") (EVar "es")))
(DFunDef false "firstExprLoc" ((PCon "EAnnot" (PVar "e0") PWild)) (EApp (EVar "firstExprLoc") (EVar "e0")))
(DFunDef false "firstExprLoc" ((PCon "EHeadAnnot" (PVar "e0") PWild)) (EApp (EVar "firstExprLoc") (EVar "e0")))
(DFunDef false "firstExprLoc" ((PCon "ERangeList" (PVar "lo") (PVar "hi") PWild)) (EApp (EApp (EVar "orElseLoc") (EApp (EVar "firstExprLoc") (EVar "lo"))) (EApp (EVar "firstExprLoc") (EVar "hi"))))
(DFunDef false "firstExprLoc" ((PCon "ERangeArray" (PVar "lo") (PVar "hi") PWild)) (EApp (EApp (EVar "orElseLoc") (EApp (EVar "firstExprLoc") (EVar "lo"))) (EApp (EVar "firstExprLoc") (EVar "hi"))))
(DFunDef false "firstExprLoc" ((PCon "EIndex" (PVar "e0") (PVar "i") PWild)) (EApp (EApp (EVar "orElseLoc") (EApp (EVar "firstExprLoc") (EVar "e0"))) (EApp (EVar "firstExprLoc") (EVar "i"))))
(DFunDef false "firstExprLoc" ((PCon "ESlice" (PVar "e0") (PVar "lo") (PVar "hi") PWild PWild)) (EApp (EApp (EVar "orElseLoc") (EApp (EVar "firstExprLoc") (EVar "e0"))) (EApp (EApp (EVar "orElseLoc") (EApp (EVar "firstExprLoc") (EVar "lo"))) (EApp (EVar "firstExprLoc") (EVar "hi")))))
(DFunDef false "firstExprLoc" ((PCon "EDoOrigin" PWild (PVar "e"))) (EApp (EVar "firstExprLoc") (EVar "e")))
(DFunDef false "firstExprLoc" (PWild) (EVar "None"))
(DTypeSig false "firstLocList" (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "firstLocList" ((PList)) (EVar "None"))
(DFunDef false "firstLocList" ((PCons (PVar "e") (PVar "rest"))) (EApp (EApp (EVar "orElseLoc") (EApp (EVar "firstExprLoc") (EVar "e"))) (EApp (EVar "firstLocList") (EVar "rest"))))
(DTypeSig false "unionStr" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "unionStr" ((PVar "acc") (PList)) (EVar "acc"))
(DFunDef false "unionStr" ((PVar "acc") (PCons (PVar "x") (PVar "xs"))) (EIf (EApp (EApp (EVar "contains") (EVar "x")) (EVar "acc")) (EApp (EApp (EVar "unionStr") (EVar "acc")) (EVar "xs")) (EIf (EVar "otherwise") (EApp (EApp (EVar "unionStr") (EBinOp "++" (EVar "acc") (EListLit (EVar "x")))) (EVar "xs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "externWithBodyErrors" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "ResError")))))
(DFunDef false "externWithBodyErrors" (PWild (PList)) (EListLit))
(DFunDef false "externWithBodyErrors" ((PVar "externs") (PCons (PCon "DFunDef" PWild (PVar "n") PWild PWild) (PVar "rest"))) (EBinOp "++" (EIf (EApp (EApp (EVar "contains") (EVar "n")) (EVar "externs")) (EListLit (EApp (EApp (EVar "ExternWithBody") (EVar "n")) (EVar "None"))) (EListLit)) (EApp (EApp (EVar "externWithBodyErrors") (EVar "externs")) (EVar "rest"))))
(DFunDef false "externWithBodyErrors" ((PVar "externs") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "externWithBodyErrors") (EVar "externs")) (EVar "rest")))
(DTypeSig false "duplicateErrors" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "ResError")))))
(DFunDef false "duplicateErrors" ((PVar "preludeDecls") (PVar "prog")) (EBlock (DoLet false false (PVar "seed") (EApp (EVar "not") (EApp (EVar "programIsCore") (EVar "prog")))) (DoLet false false (PVar "typeSeed") (EBinOp "++" (EVar "primitiveTypes") (EApp (EApp (EVar "whenL") (EVar "seed")) (EApp (EVar "dataRecordNames") (EVar "preludeDecls"))))) (DoLet false false (PVar "ctorSeed") (EBinOp "++" (EVar "primitiveConstructors") (EApp (EApp (EVar "whenL") (EVar "seed")) (EApp (EVar "ctorNames") (EVar "preludeDecls"))))) (DoLet false false (PVar "ifaceSeed") (EApp (EApp (EVar "whenL") (EVar "seed")) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EApp (EVar "interfaceList") (EVar "preludeDecls"))))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EApp (EApp (EMethodRef "map") (EApp (EVar "dupErr") (ELit (LString "type")))) (EApp (EApp (EVar "findDups") (EVar "typeSeed")) (EApp (EVar "dataRecordNames") (EVar "prog")))) (EApp (EApp (EMethodRef "map") (EApp (EVar "dupErr") (ELit (LString "constructor")))) (EApp (EApp (EVar "findDups") (EVar "ctorSeed")) (EApp (EVar "ctorNames") (EVar "prog"))))) (EApp (EApp (EMethodRef "map") (EApp (EVar "dupErr") (ELit (LString "interface")))) (EApp (EApp (EVar "findDups") (EVar "ifaceSeed")) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EApp (EVar "interfaceList") (EVar "prog")))))) (EApp (EVar "ifaceMethodCollisions") (EVar "prog"))))))
(DTypeSig false "dupErr" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "ResError"))))
(DFunDef false "dupErr" ((PVar "kind") (PVar "n")) (EApp (EApp (EApp (EVar "DuplicateDefinition") (EVar "kind")) (EVar "n")) (EVar "None")))
(DTypeSig false "ifaceMethodCollisions" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "ResError"))))
(DFunDef false "ifaceMethodCollisions" ((PVar "prog")) (EApp (EApp (EVar "ifaceMethodCollisionsGo") (EVar "omEmpty")) (EApp (EVar "ownInterfaceMethods") (EVar "prog"))))
(DTypeSig false "ifaceMethodCollisionsGo" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyApp (TyCon "List") (TyCon "ResError")))))
(DFunDef false "ifaceMethodCollisionsGo" (PWild (PList)) (EListLit))
(DFunDef false "ifaceMethodCollisionsGo" ((PVar "seen") (PCons (PTuple (PVar "iname") (PVar "ms")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EApp (EVar "ifaceMethodErrs") (EVar "iname")) (EVar "seen")) (EVar "ms")) (EApp (EApp (EVar "ifaceMethodCollisionsGo") (EApp (EApp (EApp (EVar "addIfaceMethods") (EVar "iname")) (EVar "ms")) (EVar "seen"))) (EVar "rest"))))
(DTypeSig false "ifaceMethodErrs" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "ifaceMethodErrs" (PWild PWild (PList)) (EListLit))
(DFunDef false "ifaceMethodErrs" ((PVar "iname") (PVar "seen") (PCons (PVar "m") (PVar "rest"))) (EMatch (EApp (EApp (EVar "omLookup") (EVar "m")) (EVar "seen")) (arm (PCon "Some" (PVar "prev")) () (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "DuplicateInterfaceMethod") (EVar "m")) (EVar "prev")) (EVar "iname")) (EVar "None")) (EApp (EApp (EApp (EVar "ifaceMethodErrs") (EVar "iname")) (EVar "seen")) (EVar "rest")))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "ifaceMethodErrs") (EVar "iname")) (EVar "seen")) (EVar "rest")))))
(DTypeSig false "addIfaceMethods" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyApp (TyCon "OrdMap") (TyCon "String"))))))
(DFunDef false "addIfaceMethods" (PWild (PList) (PVar "seen")) (EVar "seen"))
(DFunDef false "addIfaceMethods" ((PVar "iname") (PCons (PVar "m") (PVar "rest")) (PVar "seen")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "m")) (EVar "seen")) (EApp (EApp (EApp (EVar "addIfaceMethods") (EVar "iname")) (EVar "rest")) (EVar "seen")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "addIfaceMethods") (EVar "iname")) (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "m")) (EVar "iname")) (EVar "seen"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "ownInterfaceMethods" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "ownInterfaceMethods" ((PList)) (EListLit))
(DFunDef false "ownInterfaceMethods" ((PCons (PRec "DInterface" ((rf "name" (PVar "n")) (rf "methods" None)) true) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "n") (EApp (EApp (EMethodRef "map") (EVar "ifaceMethodNm")) (EVar "methods"))) (EApp (EVar "ownInterfaceMethods") (EVar "rest"))))
(DFunDef false "ownInterfaceMethods" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "ownInterfaceMethods") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "ownInterfaceMethods" ((PCons PWild (PVar "rest"))) (EApp (EVar "ownInterfaceMethods") (EVar "rest")))
(DTypeSig false "findDups" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "findDups" ((PVar "seen") (PVar "names")) (EApp (EApp (EVar "findDupsGo") (EApp (EApp (EVar "omFromNames") (EVar "seen")) (EVar "omEmpty"))) (EVar "names")))
(DTypeSig false "findDupsGo" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "findDupsGo" (PWild (PList)) (EListLit))
(DFunDef false "findDupsGo" ((PVar "seen") (PCons (PVar "n") (PVar "rest"))) (EIf (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "seen")) (EBinOp "::" (EVar "n") (EApp (EApp (EVar "findDupsGo") (EVar "seen")) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "findDupsGo") (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (ELit LUnit)) (EVar "seen"))) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "resErrorSexp" (TyFun (TyCon "ResError") (TyCon "String")))
(DFunDef false "resErrorSexp" ((PCon "UnboundVariable" (PVar "n") PWild PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "(UnboundVariable ")) (EApp (EVar "escStr") (EVar "n"))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "UnboundVariableExported" (PVar "n") (PVar "m") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(UnboundVariableExported ")) (EApp (EMethodRef "display") (EApp (EVar "escStr") (EVar "n")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EVar "escStr") (EVar "m")))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "UnboundVariableIsModule" (PVar "n") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "(UnboundVariableIsModule ")) (EApp (EMethodRef "display") (EApp (EVar "escStr") (EVar "n")))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "UnknownConstructor" (PVar "n") PWild PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "(UnknownConstructor ")) (EApp (EVar "escStr") (EVar "n"))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "UnknownType" (PVar "n") PWild PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "(UnknownType ")) (EApp (EVar "escStr") (EVar "n"))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "UnknownEffect" (PVar "n") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "(UnknownEffect ")) (EApp (EVar "escStr") (EVar "n"))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "UnknownField" (PVar "n") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "(UnknownField ")) (EApp (EVar "escStr") (EVar "n"))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "FieldNotInRecord" (PVar "f") (PVar "r") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(FieldNotInRecord ")) (EApp (EMethodRef "display") (EApp (EVar "escStr") (EVar "f")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EVar "escStr") (EVar "r")))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "DuplicateDefinition" (PVar "k") (PVar "n") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(DuplicateDefinition ")) (EApp (EMethodRef "display") (EApp (EVar "escStr") (EVar "k")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EVar "escStr") (EVar "n")))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "InternalExternAccess" (PVar "n") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "(InternalExternAccess ")) (EApp (EVar "escStr") (EVar "n"))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "UnknownInterface" (PVar "n") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "(UnknownInterface ")) (EApp (EVar "escStr") (EVar "n"))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "MethodNotInInterface" (PVar "m") (PVar "i") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(MethodNotInInterface ")) (EApp (EMethodRef "display") (EApp (EVar "escStr") (EVar "m")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EVar "escStr") (EVar "i")))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "ExternWithBody" (PVar "n") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "(ExternWithBody ")) (EApp (EVar "escStr") (EVar "n"))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "PrivateNameAccess" (PVar "n") (PVar "m") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(PrivateNameAccess ")) (EApp (EMethodRef "display") (EApp (EVar "escStr") (EVar "n")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EVar "escStr") (EVar "m")))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "NoExportedConstructors" (PVar "n") (PVar "m") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(NoExportedConstructors ")) (EApp (EMethodRef "display") (EApp (EVar "escStr") (EVar "n")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EVar "escStr") (EVar "m")))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "NewtypeCtorNotExported" (PVar "n") (PVar "m") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(NewtypeCtorNotExported ")) (EApp (EMethodRef "display") (EApp (EVar "escStr") (EVar "n")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EVar "escStr") (EVar "m")))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "AbstractFieldAccess" (PVar "t") (PVar "f") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(AbstractFieldAccess ")) (EApp (EMethodRef "display") (EApp (EVar "escStr") (EVar "t")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EVar "escStr") (EVar "f")))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "UnknownModule" (PVar "n") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "(UnknownModule ")) (EApp (EVar "escStr") (EVar "n"))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "NonRecursiveValueLet" (PVar "n") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "(NonRecursiveValueLet ")) (EApp (EVar "escStr") (EVar "n"))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "DuplicateBinding" (PVar "n") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "(DuplicateBinding ")) (EApp (EVar "escStr") (EVar "n"))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "DuplicateValueBinding" (PVar "n") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "(DuplicateValueBinding ")) (EApp (EVar "escStr") (EVar "n"))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "DuplicateSignature" (PVar "n") PWild PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "(DuplicateSignature ")) (EApp (EVar "escStr") (EVar "n"))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "DuplicateBinder" (PVar "k") (PVar "n") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(DuplicateBinder ")) (EApp (EMethodRef "display") (EApp (EVar "escStr") (EVar "k")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EVar "escStr") (EVar "n")))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "AsPatternMisplaced" PWild)) (ELit (LString "AsPatternMisplaced")))
(DFunDef false "resErrorSexp" ((PCon "AmbiguousOccurrence" (PVar "n") (PVar "mods") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "(AmbiguousOccurrence ")) (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EBinOp "::" (EApp (EVar "escStr") (EVar "n")) (EApp (EApp (EMethodRef "map") (EVar "escStr")) (EVar "mods"))))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "AmbiguousConstructor" (PVar "n") (PVar "mods") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "(AmbiguousConstructor ")) (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EBinOp "::" (EApp (EVar "escStr") (EVar "n")) (EApp (EApp (EMethodRef "map") (EVar "escStr")) (EVar "mods"))))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "AmbiguousType" (PVar "n") (PVar "mods") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "(AmbiguousType ")) (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EBinOp "::" (EApp (EVar "escStr") (EVar "n")) (EApp (EApp (EMethodRef "map") (EVar "escStr")) (EVar "mods"))))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "AmbiguousInterface" (PVar "n") (PVar "mods") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "(AmbiguousInterface ")) (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EBinOp "::" (EApp (EVar "escStr") (EVar "n")) (EApp (EApp (EMethodRef "map") (EVar "escStr")) (EVar "mods"))))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "ReassignImmutable" (PVar "n") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "(ReassignImmutable ")) (EApp (EVar "escStr") (EVar "n"))) (ELit (LString ")"))))
(DFunDef false "resErrorSexp" ((PCon "DuplicateInterfaceMethod" (PVar "m") (PVar "a") (PVar "b") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(DuplicateInterfaceMethod ")) (EApp (EMethodRef "display") (EApp (EVar "escStr") (EVar "m")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EVar "escStr") (EVar "a")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EVar "escStr") (EVar "b")))) (ELit (LString ")"))))
(DTypeSig false "locKey" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "String")))
(DFunDef false "locKey" ((PCon "None")) (ELit (LString "-")))
(DFunDef false "locKey" ((PCon "Some" (PCon "Loc" (PVar "f") (PVar "sl") (PVar "sc") (PVar "el") (PVar "ec")))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "f"))) (ELit (LString ":"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "sl")))) (ELit (LString ":"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "sc")))) (ELit (LString ":"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "el")))) (ELit (LString ":"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "ec")))) (ELit (LString ""))))
(DTypeSig false "dedupResErrors" (TyFun (TyApp (TyCon "List") (TyCon "ResError")) (TyApp (TyCon "List") (TyCon "ResError"))))
(DFunDef false "dedupResErrors" ((PVar "es")) (EApp (EApp (EVar "dedupBy") (EVar "resErrorDedupKey")) (EVar "es")))
(DTypeSig false "resErrorDedupKey" (TyFun (TyCon "ResError") (TyCon "String")))
(DFunDef false "resErrorDedupKey" ((PVar "e")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "resErrorCode") (EVar "e")))) (ELit (LString "|"))) (EApp (EMethodRef "display") (EApp (EVar "ppResError") (EVar "e")))) (ELit (LString "|"))) (EApp (EMethodRef "display") (EApp (EVar "locKey") (EApp (EVar "resErrorLoc") (EVar "e"))))) (ELit (LString ""))))
(DTypeSig true "resolveProgram" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "resolveProgram" ((PVar "runtimeDecls") (PVar "preludeDecls") (PVar "prog")) (EBlock (DoLet false false (PVar "env") (EApp (EApp (EApp (EApp (EVar "buildEnv") (EVar "runtimeDecls")) (EVar "preludeDecls")) (EVar "prog")) (EListLit))) (DoExpr (EApp (EVar "dedupResErrors") (EBinOp "++" (EApp (EApp (EVar "buildErrors") (EVar "preludeDecls")) (EVar "prog")) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "checkDecl") (EVar "env"))) (EVar "prog")))))))
(DTypeSig true "resolveProgramG2" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "ResError")))))))
(DFunDef false "resolveProgramG2" ((PVar "internalGuard") (PVar "runtimeDecls") (PVar "preludeDecls") (PVar "prog")) (EBlock (DoLet false false (PVar "env") (EApp (EApp (EApp (EApp (EVar "buildEnv") (EVar "runtimeDecls")) (EVar "preludeDecls")) (EVar "prog")) (EVar "internalGuard"))) (DoExpr (EApp (EVar "dedupResErrors") (EBinOp "++" (EApp (EApp (EVar "buildErrors") (EVar "preludeDecls")) (EVar "prog")) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "checkDecl") (EVar "env"))) (EVar "prog")))))))
(DTypeSig true "ppResError" (TyFun (TyCon "ResError") (TyCon "String")))
(DFunDef false "ppResError" ((PCon "UnboundVariable" (PVar "n") PWild (PVar "s"))) (EMatch (EVar "s") (arm (PCon "Some" (PVar "sug")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Unbound variable: ")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString ". Did you mean '"))) (EApp (EMethodRef "display") (EVar "sug"))) (ELit (LString "'"))) (EApp (EApp (EVar "haskellNote") (EVar "n")) (EVar "sug")))) (arm (PCon "None") () (EBinOp "++" (EBinOp "++" (ELit (LString "Unbound variable: ")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString ""))))))
(DFunDef false "ppResError" ((PCon "UnboundVariableExported" (PVar "n") (PVar "m") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Unbound variable: ")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString ". (Did you forget to 'import "))) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString ".{"))) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "}'?)"))))
(DFunDef false "ppResError" ((PCon "UnboundVariableIsModule" (PVar "n") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Unbound variable: ")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString ". '"))) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "' is an imported module, not a value — a bare "))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "'import ")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "' binds no names. Bind what you need: 'import "))) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString ".{name, ")))) (EBinOp "++" (EBinOp "++" (ELit (LString "...}', or 'import ")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString " as M' then 'M.name'")))))
(DFunDef false "ppResError" ((PCon "UnknownConstructor" (PVar "n") PWild (PVar "s"))) (EMatch (EVar "s") (arm (PCon "Some" (PVar "sug")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Unknown constructor: ")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString ". Did you mean '"))) (EApp (EMethodRef "display") (EVar "sug"))) (ELit (LString "'"))) (EApp (EApp (EVar "haskellNote") (EVar "n")) (EVar "sug")))) (arm (PCon "None") () (EBinOp "++" (ELit (LString "Unknown constructor: ")) (EVar "n")))))
(DFunDef false "ppResError" ((PCon "UnknownType" (PVar "n") PWild (PVar "s"))) (EMatch (EVar "s") (arm (PCon "Some" (PVar "sug")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Unknown type: ")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString ". Did you mean '"))) (EApp (EMethodRef "display") (EVar "sug"))) (ELit (LString "'"))) (EApp (EApp (EVar "haskellNote") (EVar "n")) (EVar "sug")))) (arm (PCon "None") () (EBinOp "++" (ELit (LString "Unknown type: ")) (EVar "n")))))
(DFunDef false "ppResError" ((PCon "UnknownEffect" (PVar "n") PWild)) (EIf (EBinOp "||" (EBinOp "==" (EVar "n") (ELit (LString "Mut"))) (EBinOp "==" (EVar "n") (ELit (LString "Panic")))) (EBinOp "++" (EBinOp "++" (ELit (LString "Unknown effect: ")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString " — the `Mut`/`Panic` purity labels were removed. Delete the annotation: purity is no longer tracked as an effect label, and effect labels now name host capabilities (`IO`, `Rand`, `FileRead`, …)"))) (EBinOp "++" (ELit (LString "Unknown effect: ")) (EVar "n"))))
(DFunDef false "ppResError" ((PCon "UnknownField" (PVar "n") PWild)) (EBinOp "++" (ELit (LString "Unknown field: ")) (EVar "n")))
(DFunDef false "ppResError" ((PCon "FieldNotInRecord" (PVar "f") (PVar "r") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Unknown field: ")) (EApp (EMethodRef "display") (EVar "f"))) (ELit (LString ". Record '"))) (EApp (EMethodRef "display") (EVar "r"))) (ELit (LString "' has no field '"))) (EApp (EMethodRef "display") (EVar "f"))) (ELit (LString "'"))))
(DFunDef false "ppResError" ((PCon "DuplicateDefinition" (PVar "k") (PVar "n") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Duplicate ")) (EApp (EMethodRef "display") (EVar "k"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString ""))))
(DFunDef false "ppResError" ((PCon "UnknownInterface" (PVar "n") PWild)) (EBinOp "++" (ELit (LString "Unknown interface: ")) (EVar "n")))
(DFunDef false "ppResError" ((PCon "MethodNotInInterface" (PVar "m") (PVar "i") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Method '")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "' is not part of interface '"))) (EApp (EMethodRef "display") (EVar "i"))) (ELit (LString "'"))))
(DFunDef false "ppResError" ((PCon "ExternWithBody" (PVar "n") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "Extern '")) (EVar "n")) (ELit (LString "' must not have a definition body"))))
(DFunDef false "ppResError" ((PCon "PrivateNameAccess" (PVar "n") (PVar "m") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Module '")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "' has no exported name '"))) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "'"))))
(DFunDef false "ppResError" ((PCon "NoExportedConstructors" (PVar "n") (PVar "m") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "'")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "' exports no constructors from module '"))) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "' (exported abstractly). Remove `(..)` or export with `public export`"))))
(DFunDef false "ppResError" ((PCon "NewtypeCtorNotExported" (PVar "n") (PVar "m") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "'")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "' exports no constructors: a `newtype`'s constructor is always module-private, and `public` is a parse error on `newtype`. Expose it with an accessor function, or declare '"))) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "' as a `public export data` with one variant"))))
(DFunDef false "ppResError" ((PCon "AbstractFieldAccess" (PVar "t") (PVar "f") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "'")) (EApp (EMethodRef "display") (EVar "t"))) (ELit (LString "' is exported abstractly. Field '"))) (EApp (EMethodRef "display") (EVar "f"))) (ELit (LString "' is not accessible; declare it `public export` to expose its fields"))))
(DFunDef false "ppResError" ((PCon "UnknownModule" (PVar "n") PWild)) (EBinOp "++" (ELit (LString "Unknown module: ")) (EVar "n")))
(DFunDef false "ppResError" ((PCon "AsPatternMisplaced" PWild)) (ELit (LString "`@` as-patterns are only allowed in a binding position (a lambda parameter, a do-block bind, or a match pattern)")))
(DFunDef false "ppResError" ((PCon "NonRecursiveValueLet" (PVar "n") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "'")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "' is not in scope in its own binding. Non-function `let` is not recursive; write `let rec "))) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString " = ...` (RHS must be a lambda)"))))
(DFunDef false "ppResError" ((PCon "DuplicateBinding" (PVar "n") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "Clauses of '")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "' must be contiguous. An earlier same-named binding is separated by another declaration; group all clauses (and the signature) together"))))
(DFunDef false "ppResError" ((PCon "DuplicateValueBinding" (PVar "n") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "Duplicate binding '")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "': it is already defined in this scope. A value binding has exactly one definition — rename this one or remove it"))))
(DFunDef false "ppResError" ((PCon "DuplicateSignature" (PVar "n") PWild (PCon "Some" (PCon "Loc" PWild (PVar "l") PWild PWild PWild)))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "'")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "' is already defined at line "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "l")))) (ELit (LString ". A name may have only one type signature — rename or remove this duplicate definition, or merge the clauses into a single multi-clause function if that was the intent"))))
(DFunDef false "ppResError" ((PCon "DuplicateSignature" (PVar "n") PWild (PCon "None"))) (EBinOp "++" (EBinOp "++" (ELit (LString "'")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "' is already defined earlier in this file. A name may have only one type signature — rename or remove this duplicate definition, or merge the clauses into a single multi-clause function if that was the intent"))))
(DFunDef false "ppResError" ((PCon "DuplicateBinder" (PVar "k") (PVar "n") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Duplicate binder: '")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "' is bound more than once in this "))) (EApp (EMethodRef "display") (EVar "k"))) (ELit (LString ". Each binder must be distinct — rename one occurrence"))))
(DFunDef false "ppResError" ((PCon "AmbiguousOccurrence" (PVar "n") (PVar "mods") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Ambiguous occurrence: '")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "' is exported by "))) (EApp (EMethodRef "display") (EApp (EVar "ambigModPhrase") (EVar "mods")))) (ELit (LString ". Qualify, or select with `import <mod>.{"))) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "}`"))))
(DFunDef false "ppResError" ((PCon "AmbiguousConstructor" (PVar "n") (PVar "mods") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Ambiguous constructor: '")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "' is brought into scope by "))) (EApp (EMethodRef "display") (EApp (EVar "ambigModPhrase") (EVar "mods")))) (ELit (LString ". Import the constructors of only one — e.g. `import <mod>.{T(..)}` — and drop the other's `(..)`"))))
(DFunDef false "ppResError" ((PCon "AmbiguousType" (PVar "n") (PVar "mods") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Ambiguous type: '")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "' is brought into scope by "))) (EApp (EMethodRef "display") (EApp (EVar "ambigModPhrase") (EVar "mods")))) (ELit (LString ". A type name can be neither qualified nor aliased, so import it from only one — drop '"))) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "' from the other's import list"))))
(DFunDef false "ppResError" ((PCon "AmbiguousInterface" (PVar "n") (PVar "mods") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Ambiguous interface: '")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "' is brought into scope by "))) (EApp (EMethodRef "display") (EApp (EVar "ambigModPhrase") (EVar "mods")))) (ELit (LString ". An interface name can be neither qualified nor aliased, so import it from only one — drop '"))) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "' from the other's import list"))))
(DFunDef false "ppResError" ((PCon "InternalExternAccess" (PVar "n") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "'")) (EVar "n")) (ELit (LString "' is an internal-only primitive. Cannot be used outside the standard library (pass --allow-internal to override)"))))
(DFunDef false "ppResError" ((PCon "DuplicateInterfaceMethod" (PVar "m") (PVar "a") (PVar "b") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Method '")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "' is declared by two interfaces in this module: '"))) (EApp (EMethodRef "display") (EVar "a"))) (ELit (LString "' and '"))) (EApp (EMethodRef "display") (EVar "b"))) (ELit (LString "'. Two interfaces declared together may not share a method name — an occurrence of '"))) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "' could not be attributed to either. Rename the method in one of them, or merge the two interfaces. (A method name shared with a PRELUDE interface is a different case and stays legal.)"))))
(DFunDef false "ppResError" ((PCon "ReassignImmutable" (PVar "n") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Cannot reassign '")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "' — bindings are immutable. To bind a new value, shadow it with `let "))) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString " = ...`. For mutable state, use a `Ref`: `let "))) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString " = Ref 0`, then write `"))) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString " := !"))) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString " + 1` (read the cell with `!"))) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "`)"))))
(DTypeSig true "resErrorCode" (TyFun (TyCon "ResError") (TyCon "String")))
(DFunDef false "resErrorCode" ((PCon "UnboundVariable" PWild PWild PWild)) (ELit (LString "R-UNBOUND")))
(DFunDef false "resErrorCode" ((PCon "UnboundVariableExported" PWild PWild PWild)) (ELit (LString "R-UNBOUND")))
(DFunDef false "resErrorCode" ((PCon "UnboundVariableIsModule" PWild PWild)) (ELit (LString "R-UNBOUND")))
(DFunDef false "resErrorCode" ((PCon "UnknownConstructor" PWild PWild PWild)) (ELit (LString "R-UNKNOWN-CTOR")))
(DFunDef false "resErrorCode" ((PCon "UnknownType" PWild PWild PWild)) (ELit (LString "R-UNKNOWN-TYPE")))
(DFunDef false "resErrorCode" ((PCon "UnknownEffect" PWild PWild)) (ELit (LString "R-UNKNOWN-EFFECT")))
(DFunDef false "resErrorCode" ((PCon "UnknownField" PWild PWild)) (ELit (LString "R-UNKNOWN-FIELD")))
(DFunDef false "resErrorCode" ((PCon "FieldNotInRecord" PWild PWild PWild)) (ELit (LString "R-FIELD-NOT-IN-RECORD")))
(DFunDef false "resErrorCode" ((PCon "DuplicateDefinition" PWild PWild PWild)) (ELit (LString "R-DUPLICATE-DEF")))
(DFunDef false "resErrorCode" ((PCon "UnknownInterface" PWild PWild)) (ELit (LString "R-UNKNOWN-INTERFACE")))
(DFunDef false "resErrorCode" ((PCon "MethodNotInInterface" PWild PWild PWild)) (ELit (LString "R-METHOD-NOT-IN-INTERFACE")))
(DFunDef false "resErrorCode" ((PCon "ExternWithBody" PWild PWild)) (ELit (LString "R-EXTERN-WITH-BODY")))
(DFunDef false "resErrorCode" ((PCon "PrivateNameAccess" PWild PWild PWild)) (ELit (LString "R-PRIVATE-NAME")))
(DFunDef false "resErrorCode" ((PCon "NoExportedConstructors" PWild PWild PWild)) (ELit (LString "R-NO-EXPORTED-CTORS")))
(DFunDef false "resErrorCode" ((PCon "NewtypeCtorNotExported" PWild PWild PWild)) (ELit (LString "R-NEWTYPE-CTOR-PRIVATE")))
(DFunDef false "resErrorCode" ((PCon "AbstractFieldAccess" PWild PWild PWild)) (ELit (LString "R-ABSTRACT-FIELD")))
(DFunDef false "resErrorCode" ((PCon "UnknownModule" PWild PWild)) (ELit (LString "R-UNKNOWN-MODULE")))
(DFunDef false "resErrorCode" ((PCon "NonRecursiveValueLet" PWild PWild)) (ELit (LString "R-NONREC-VALUE-LET")))
(DFunDef false "resErrorCode" ((PCon "DuplicateBinding" PWild PWild)) (ELit (LString "R-DUPLICATE-BINDING")))
(DFunDef false "resErrorCode" ((PCon "DuplicateValueBinding" PWild PWild)) (ELit (LString "R-DUP-BINDING")))
(DFunDef false "resErrorCode" ((PCon "DuplicateSignature" PWild PWild PWild)) (ELit (LString "R-DUPLICATE-SIGNATURE")))
(DFunDef false "resErrorCode" ((PCon "DuplicateBinder" PWild PWild PWild)) (ELit (LString "R-DUP-BINDER")))
(DFunDef false "resErrorCode" ((PCon "AsPatternMisplaced" PWild)) (ELit (LString "R-AS-PATTERN-MISPLACED")))
(DFunDef false "resErrorCode" ((PCon "AmbiguousOccurrence" PWild PWild PWild)) (ELit (LString "R-AMBIGUOUS-OCCURRENCE")))
(DFunDef false "resErrorCode" ((PCon "AmbiguousConstructor" PWild PWild PWild)) (ELit (LString "R-AMBIGUOUS-CTOR")))
(DFunDef false "resErrorCode" ((PCon "AmbiguousType" PWild PWild PWild)) (ELit (LString "R-AMBIGUOUS-TYPE")))
(DFunDef false "resErrorCode" ((PCon "AmbiguousInterface" PWild PWild PWild)) (ELit (LString "R-AMBIGUOUS-INTERFACE")))
(DFunDef false "resErrorCode" ((PCon "InternalExternAccess" PWild PWild)) (ELit (LString "R-INTERNAL-EXTERN")))
(DFunDef false "resErrorCode" ((PCon "ReassignImmutable" PWild PWild)) (ELit (LString "R-IMMUTABLE-ASSIGN")))
(DFunDef false "resErrorCode" ((PCon "DuplicateInterfaceMethod" PWild PWild PWild PWild)) (ELit (LString "R-DUPLICATE-IFACE-METHOD")))
(DTypeSig false "ambigModPhrase" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "ambigModPhrase" ((PCons (PVar "a") (PCons (PVar "b") (PList)))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "both `")) (EApp (EMethodRef "display") (EVar "a"))) (ELit (LString "` and `"))) (EApp (EMethodRef "display") (EVar "b"))) (ELit (LString "`"))))
(DFunDef false "ambigModPhrase" ((PVar "mods")) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "m")) (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EVar "m")) (ELit (LString "`"))))) (EVar "mods"))))
(DTypeSig true "resolveToLines" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "String")))))
(DFunDef false "resolveToLines" ((PVar "runtimeDecls") (PVar "preludeDecls") (PVar "prog")) (EApp (EVar "joinNl") (EApp (EApp (EMethodRef "map") (EVar "ppResError")) (EApp (EApp (EApp (EVar "resolveProgram") (EVar "runtimeDecls")) (EVar "preludeDecls")) (EVar "prog")))))
(DTypeSig true "singleFileImportErrors" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "ResError"))))
(DFunDef false "singleFileImportErrors" ((PList)) (EListLit))
(DFunDef false "singleFileImportErrors" ((PCons (PCon "DUse" PWild (PVar "path") PWild) (PVar "rest"))) (EBlock (DoLet false false (PVar "mid") (EApp (EVar "useModId") (EVar "path"))) (DoExpr (EIf (EBinOp "||" (EBinOp "==" (EVar "mid") (ELit (LString "core"))) (EBinOp "==" (EVar "mid") (ELit (LString "")))) (EApp (EVar "singleFileImportErrors") (EVar "rest")) (EBinOp "::" (EApp (EApp (EVar "UnknownModule") (EVar "mid")) (EVar "None")) (EApp (EVar "singleFileImportErrors") (EVar "rest")))))))
(DFunDef false "singleFileImportErrors" ((PCons PWild (PVar "rest"))) (EApp (EVar "singleFileImportErrors") (EVar "rest")))
(DData Public "ModuleExports" () ((variant "ModuleExports" (ConNamed (field "modId" (TyCon "String")) (field "expValues" (TyApp (TyCon "List") (TyCon "String"))) (field "expTypes" (TyApp (TyCon "List") (TyCon "String"))) (field "expCtors" (TyApp (TyCon "List") (TyCon "String"))) (field "expTypeCtors" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))) (field "expFieldOwners" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (field "expInterfaces" (TyApp (TyCon "List") (TyCon "String"))) (field "expIfaceMethods" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))) (field "expEffects" (TyApp (TyCon "List") (TyCon "String"))) (field "expNewtypeCtors" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))) ())
(DTypeSig false "filterContains" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "filterContains" (PWild (PList)) (EListLit))
(DFunDef false "filterContains" ((PVar "domain") (PCons (PVar "n") (PVar "rest"))) (EIf (EApp (EApp (EVar "contains") (EVar "n")) (EVar "domain")) (EBinOp "::" (EVar "n") (EApp (EApp (EVar "filterContains") (EVar "domain")) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "filterContains") (EVar "domain")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "filterInSet" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "filterInSet" (PWild (PList)) (EListLit))
(DFunDef false "filterInSet" ((PVar "domain") (PCons (PVar "n") (PVar "rest"))) (EIf (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "domain")) (EBinOp "::" (EVar "n") (EApp (EApp (EVar "filterInSet") (EVar "domain")) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "filterInSet") (EVar "domain")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "findExports" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyApp (TyCon "Option") (TyCon "ModuleExports")))))
(DFunDef false "findExports" ((PVar "mid") (PVar "known")) (EApp (EApp (EVar "omLookup") (EVar "mid")) (EVar "known")))
(DTypeSig false "isPubExp" (TyFun (TyCon "ModuleExports") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "isPubExp" ((PVar "exp") (PVar "n")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EApp (EApp (EVar "contains") (EVar "n")) (EFieldAccess (EVar "exp") "expValues")) (EApp (EApp (EVar "contains") (EVar "n")) (EFieldAccess (EVar "exp") "expTypes"))) (EApp (EApp (EVar "contains") (EVar "n")) (EFieldAccess (EVar "exp") "expCtors"))) (EApp (EApp (EVar "contains") (EVar "n")) (EFieldAccess (EVar "exp") "expInterfaces"))))
(DTypeSig false "typeCtorsOf" (TyFun (TyCon "String") (TyFun (TyCon "ModuleExports") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "typeCtorsOf" ((PVar "name") (PVar "exp")) (EApp (EApp (EVar "lookupAssoc") (EVar "name")) (EFieldAccess (EVar "exp") "expTypeCtors")))
(DTypeSig false "newtypeTypeOfCtor" (TyFun (TyCon "String") (TyFun (TyCon "ModuleExports") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "newtypeTypeOfCtor" ((PVar "name") (PVar "exp")) (EApp (EApp (EVar "lookupAssoc") (EVar "name")) (EFieldAccess (EVar "exp") "expNewtypeCtors")))
(DTypeSig false "isNewtypeExport" (TyFun (TyCon "String") (TyFun (TyCon "ModuleExports") (TyCon "Bool"))))
(DFunDef false "isNewtypeExport" ((PVar "name") (PVar "exp")) (EApp (EApp (EVar "contains") (EVar "name")) (EApp (EApp (EMethodRef "map") (EVar "snd")) (EFieldAccess (EVar "exp") "expNewtypeCtors"))))
(DTypeSig false "usePathsOf" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "UsePath"))))
(DFunDef false "usePathsOf" ((PList)) (EListLit))
(DFunDef false "usePathsOf" ((PCons (PCon "DUse" PWild (PVar "path") PWild) (PVar "rest"))) (EBinOp "::" (EVar "path") (EApp (EVar "usePathsOf") (EVar "rest"))))
(DFunDef false "usePathsOf" ((PCons PWild (PVar "rest"))) (EApp (EVar "usePathsOf") (EVar "rest")))
(DTypeSig false "usePathLocsOf" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "UsePath") (TyCon "Loc")))))
(DFunDef false "usePathLocsOf" ((PList)) (EListLit))
(DFunDef false "usePathLocsOf" ((PCons (PCon "DUse" PWild (PVar "path") (PVar "loc")) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "path") (EVar "loc")) (EApp (EVar "usePathLocsOf") (EVar "rest"))))
(DFunDef false "usePathLocsOf" ((PCons PWild (PVar "rest"))) (EApp (EVar "usePathLocsOf") (EVar "rest")))
(DTypeSig false "pubUsePaths" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "UsePath"))))
(DFunDef false "pubUsePaths" ((PList)) (EListLit))
(DFunDef false "pubUsePaths" ((PCons (PCon "DUse" (PCon "True") (PVar "path") PWild) (PVar "rest"))) (EBinOp "::" (EVar "path") (EApp (EVar "pubUsePaths") (EVar "rest"))))
(DFunDef false "pubUsePaths" ((PCons PWild (PVar "rest"))) (EApp (EVar "pubUsePaths") (EVar "rest")))
(DTypeSig false "importedNamesMM" (TyFun (TyCon "UsePath") (TyFun (TyCon "ModuleExports") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "importedNamesMM" ((PCon "UseName" (PVar "ns")) (PVar "exp")) (EIf (EBinOp ">" (EApp (EVar "listLen") (EVar "ns")) (ELit (LInt 1))) (EBlock (DoLet false false (PVar "nm") (EApp (EVar "lastOf") (EVar "ns"))) (DoExpr (ETuple (EListLit (EVar "nm")) (EApp (EApp (EVar "pubErr") (EVar "exp")) (EVar "nm"))))) (ETuple (EListLit) (EListLit))))
(DFunDef false "importedNamesMM" ((PCon "UseGroup" PWild (PVar "members")) (PVar "exp")) (EBlock (DoLet false false (PVar "expanded") (EApp (EApp (EDictApp "flatMap") (EApp (EVar "expandMemberNames") (EVar "exp"))) (EVar "members"))) (DoLet false false (PVar "names") (EApp (EApp (EMethodRef "map") (EVar "localOfExpanded")) (EVar "expanded"))) (DoLet false false (PVar "expandErrs") (EApp (EApp (EDictApp "flatMap") (EApp (EVar "expandMemberErrs") (EVar "exp"))) (EVar "members"))) (DoExpr (ETuple (EVar "names") (EBinOp "++" (EVar "expandErrs") (EApp (EApp (EDictApp "flatMap") (EApp (EVar "pubErrExpanded") (EVar "exp"))) (EVar "expanded")))))))
(DFunDef false "importedNamesMM" ((PCon "UseWild" PWild) (PVar "exp")) (ETuple (EBinOp "++" (EBinOp "++" (EFieldAccess (EVar "exp") "expValues") (EFieldAccess (EVar "exp") "expTypes")) (EApp (EApp (EVar "filterList") (ELam ((PVar "c")) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EVar "c")) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EFieldAccess (EVar "exp") "expNewtypeCtors")))))) (EFieldAccess (EVar "exp") "expCtors"))) (EListLit)))
(DFunDef false "importedNamesMM" ((PCon "UseAlias" PWild (PVar "a")) (PVar "exp")) (ETuple (EApp (EApp (EMethodRef "map") (EApp (EVar "qualifiedLocal") (EVar "a"))) (EFieldAccess (EVar "exp") "expValues")) (EListLit)))
(DTypeSig false "pubErr" (TyFun (TyCon "ModuleExports") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "ResError")))))
(DFunDef false "pubErr" ((PVar "exp") (PVar "n")) (EIf (EApp (EApp (EVar "isPubExp") (EVar "exp")) (EVar "n")) (EListLit) (EListLit (EApp (EApp (EApp (EVar "PrivateNameAccess") (EVar "n")) (EFieldAccess (EVar "exp") "modId")) (EVar "None")))))
(DTypeSig false "pubErrLoc" (TyFun (TyCon "ModuleExports") (TyFun (TyTuple (TyCon "String") (TyCon "Loc")) (TyApp (TyCon "List") (TyCon "ResError")))))
(DFunDef false "pubErrLoc" ((PVar "exp") (PTuple (PVar "n") (PVar "loc"))) (EIf (EApp (EApp (EVar "isPubExp") (EVar "exp")) (EVar "n")) (EListLit) (EListLit (EApp (EApp (EApp (EVar "PrivateNameAccess") (EVar "n")) (EFieldAccess (EVar "exp") "modId")) (EApp (EVar "Some") (EVar "loc"))))))
(DTypeSig false "expandMemberNames" (TyFun (TyCon "ModuleExports") (TyFun (TyCon "UseMember") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Loc"))))))
(DFunDef false "expandMemberNames" ((PVar "exp") (PAs "m" (PCon "UseMember" (PVar "name") (PCon "False") (PVar "loc") PWild))) (EMatch (EApp (EApp (EVar "newtypeTypeOfCtor") (EVar "name")) (EVar "exp")) (arm (PCon "Some" PWild) () (EListLit)) (arm (PCon "None") () (EListLit (ETuple (EVar "name") (EApp (EVar "useMemberLocal") (EVar "m")) (EVar "loc"))))))
(DFunDef false "expandMemberNames" ((PVar "exp") (PAs "m" (PCon "UseMember" (PVar "name") (PCon "True") (PVar "loc") PWild))) (EIf (EApp (EApp (EVar "isNewtypeExport") (EVar "name")) (EVar "exp")) (EListLit (ETuple (EVar "name") (EApp (EVar "useMemberLocal") (EVar "m")) (EVar "loc"))) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "typeCtorsOf") (EVar "name")) (EVar "exp")) (arm (PCon "Some" (PVar "ctors")) () (EBinOp "::" (ETuple (EVar "name") (EApp (EVar "useMemberLocal") (EVar "m")) (EVar "loc")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "c")) (ETuple (EVar "c") (EVar "c") (EVar "loc")))) (EVar "ctors")))) (arm (PCon "None") () (EListLit (ETuple (EVar "name") (EApp (EVar "useMemberLocal") (EVar "m")) (EVar "loc"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "localOfExpanded" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyCon "Loc")) (TyCon "String")))
(DFunDef false "localOfExpanded" ((PTuple PWild (PVar "local") PWild)) (EVar "local"))
(DTypeSig false "pubErrExpanded" (TyFun (TyCon "ModuleExports") (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyCon "Loc")) (TyApp (TyCon "List") (TyCon "ResError")))))
(DFunDef false "pubErrExpanded" ((PVar "exp") (PTuple (PVar "origin") PWild (PVar "loc"))) (EApp (EApp (EVar "pubErrLoc") (EVar "exp")) (ETuple (EVar "origin") (EVar "loc"))))
(DTypeSig false "expandMemberErrs" (TyFun (TyCon "ModuleExports") (TyFun (TyCon "UseMember") (TyApp (TyCon "List") (TyCon "ResError")))))
(DFunDef false "expandMemberErrs" ((PVar "exp") (PCon "UseMember" (PVar "name") (PCon "False") (PVar "loc") PWild)) (EMatch (EApp (EApp (EVar "newtypeTypeOfCtor") (EVar "name")) (EVar "exp")) (arm (PCon "Some" (PVar "tyName")) () (EListLit (EApp (EApp (EApp (EVar "NewtypeCtorNotExported") (EVar "tyName")) (EFieldAccess (EVar "exp") "modId")) (EApp (EVar "Some") (EVar "loc"))))) (arm (PCon "None") () (EListLit))))
(DFunDef false "expandMemberErrs" ((PVar "exp") (PCon "UseMember" (PVar "name") (PCon "True") (PVar "loc") PWild)) (EIf (EApp (EApp (EVar "isNewtypeExport") (EVar "name")) (EVar "exp")) (EListLit (EApp (EApp (EApp (EVar "NewtypeCtorNotExported") (EVar "name")) (EFieldAccess (EVar "exp") "modId")) (EApp (EVar "Some") (EVar "loc")))) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "typeCtorsOf") (EVar "name")) (EVar "exp")) (arm (PCon "Some" PWild) () (EListLit)) (arm (PCon "None") () (EIf (EApp (EApp (EVar "contains") (EVar "name")) (EFieldAccess (EVar "exp") "expTypes")) (EListLit (EApp (EApp (EApp (EVar "NoExportedConstructors") (EVar "name")) (EFieldAccess (EVar "exp") "modId")) (EApp (EVar "Some") (EVar "loc")))) (EListLit)))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DData Public "ImportAdds" () ((variant "ImportAdds" (ConNamed (field "iaImported" (TyApp (TyCon "List") (TyCon "String"))) (field "iaValues" (TyApp (TyCon "List") (TyCon "String"))) (field "iaTypes" (TyApp (TyCon "List") (TyCon "String"))) (field "iaCtors" (TyApp (TyCon "List") (TyCon "String"))) (field "iaIfaces" (TyApp (TyCon "List") (TyCon "String"))) (field "iaFieldOwners" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (field "iaErrors" (TyApp (TyCon "List") (TyCon "ResError")))))) ())
(DTypeSig false "emptyAdds" (TyCon "ImportAdds"))
(DFunDef false "emptyAdds" () (ERecordCreate "ImportAdds" ((fa "iaImported" (EListLit)) (fa "iaValues" (EListLit)) (fa "iaTypes" (EListLit)) (fa "iaCtors" (EListLit)) (fa "iaIfaces" (EListLit)) (fa "iaFieldOwners" (EListLit)) (fa "iaErrors" (EListLit)))))
(DTypeSig false "mergeAdds" (TyFun (TyCon "ImportAdds") (TyFun (TyCon "ImportAdds") (TyCon "ImportAdds"))))
(DFunDef false "mergeAdds" ((PVar "a") (PVar "b")) (ERecordCreate "ImportAdds" ((fa "iaImported" (EBinOp "++" (EFieldAccess (EVar "a") "iaImported") (EFieldAccess (EVar "b") "iaImported"))) (fa "iaValues" (EBinOp "++" (EFieldAccess (EVar "a") "iaValues") (EFieldAccess (EVar "b") "iaValues"))) (fa "iaTypes" (EBinOp "++" (EFieldAccess (EVar "a") "iaTypes") (EFieldAccess (EVar "b") "iaTypes"))) (fa "iaCtors" (EBinOp "++" (EFieldAccess (EVar "a") "iaCtors") (EFieldAccess (EVar "b") "iaCtors"))) (fa "iaIfaces" (EBinOp "++" (EFieldAccess (EVar "a") "iaIfaces") (EFieldAccess (EVar "b") "iaIfaces"))) (fa "iaFieldOwners" (EBinOp "++" (EFieldAccess (EVar "a") "iaFieldOwners") (EFieldAccess (EVar "b") "iaFieldOwners"))) (fa "iaErrors" (EBinOp "++" (EFieldAccess (EVar "a") "iaErrors") (EFieldAccess (EVar "b") "iaErrors"))))))
(DTypeSig false "collectImports" (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "ImportAdds"))))
(DFunDef false "collectImports" ((PVar "known") (PVar "prog")) (EApp (EApp (EVar "foldImports") (EVar "known")) (EApp (EVar "usePathLocsOf") (EVar "prog"))))
(DTypeSig false "importValueNames" (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyCon "UsePath") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "importValueNames" ((PVar "known") (PVar "path")) (EIf (EBinOp "==" (EApp (EVar "useModId") (EVar "path")) (ELit (LString "core"))) (EListLit) (EMatch (EApp (EApp (EVar "findExports") (EApp (EVar "useModId") (EVar "path"))) (EVar "known")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "exp")) () (EBlock (DoLet false false (PTuple (PVar "names") PWild) (EApp (EApp (EVar "importedNamesMM") (EVar "path")) (EVar "exp"))) (DoExpr (EApp (EApp (EVar "filterInSet") (EApp (EApp (EVar "omFromNames") (EFieldAccess (EVar "exp") "expValues")) (EVar "omEmpty"))) (EVar "names"))))))))
(DTypeSig false "addProvenance" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "addProvenance" ((PVar "prov") (PVar "n") (PVar "mid")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "prov")) (arm (PCon "None") () (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (EListLit (EVar "mid"))) (EVar "prov"))) (arm (PCon "Some" (PVar "mids")) () (EIf (EApp (EApp (EVar "contains") (EVar "mid")) (EVar "mids")) (EVar "prov") (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (EBinOp "++" (EVar "mids") (EListLit (EVar "mid")))) (EVar "prov"))))))
(DTypeSig false "addImportProvenance" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "addImportProvenance" ((PVar "prov") PWild (PList)) (EVar "prov"))
(DFunDef false "addImportProvenance" ((PVar "prov") (PVar "mid") (PCons (PVar "n") (PVar "rest"))) (EApp (EApp (EApp (EVar "addImportProvenance") (EApp (EApp (EApp (EVar "addProvenance") (EVar "prov")) (EVar "n")) (EVar "mid"))) (EVar "mid")) (EVar "rest")))
(DTypeSig false "valueProvenance" (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "List") (TyCon "UsePath")) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "valueProvenance" ((PVar "known") (PVar "paths")) (EApp (EApp (EApp (EVar "foldProvenance") (EVar "known")) (EVar "omEmpty")) (EVar "paths")))
(DTypeSig false "foldProvenance" (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "UsePath")) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "foldProvenance" (PWild (PVar "prov") (PList)) (EVar "prov"))
(DFunDef false "foldProvenance" ((PVar "known") (PVar "prov") (PCons (PVar "p") (PVar "rest"))) (EBlock (DoLet false false (PVar "mid") (EApp (EVar "useModId") (EVar "p"))) (DoLet false false (PVar "prov2") (EIf (EBinOp "==" (EVar "mid") (ELit (LString "core"))) (EVar "prov") (EApp (EApp (EApp (EVar "addImportProvenance") (EVar "prov")) (EVar "mid")) (EApp (EApp (EVar "importValueNames") (EVar "known")) (EVar "p"))))) (DoExpr (EApp (EApp (EApp (EVar "foldProvenance") (EVar "known")) (EVar "prov2")) (EVar "rest")))))
(DTypeSig false "provToPairs" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "provToPairs" ((PVar "prov")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "k")) (ETuple (EVar "k") (EApp (EApp (EVar "provMidsOf") (EVar "k")) (EVar "prov"))))) (EApp (EVar "omKeys") (EVar "prov"))))
(DTypeSig false "provMidsOf" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "provMidsOf" ((PVar "k") (PVar "prov")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "k")) (EVar "prov")) (arm (PCon "Some" (PVar "mids")) () (EVar "mids")) (arm (PCon "None") () (EListLit))))
(DTypeSig false "ambiguousSet" (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "ambiguousSet" ((PVar "known") (PVar "prog")) (EBlock (DoLet false false (PVar "prov") (EApp (EApp (EVar "valueProvenance") (EVar "known")) (EApp (EVar "usePathsOf") (EVar "prog")))) (DoLet false false (PVar "sameMod") (EApp (EVar "userValueNames") (EVar "prog"))) (DoExpr (EApp (EApp (EVar "keepAmbiguous") (EVar "sameMod")) (EApp (EVar "provToPairs") (EVar "prov"))))))
(DTypeSig false "keepAmbiguous" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "keepAmbiguous" (PWild (PList)) (EListLit))
(DFunDef false "keepAmbiguous" ((PVar "sameMod") (PCons (PTuple (PVar "n") (PVar "mids")) (PVar "rest"))) (EIf (EBinOp "&&" (EBinOp ">=" (EApp (EVar "listLen") (EVar "mids")) (ELit (LInt 2))) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EVar "n")) (EVar "sameMod")))) (EBinOp "::" (ETuple (EVar "n") (EVar "mids")) (EApp (EApp (EVar "keepAmbiguous") (EVar "sameMod")) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "keepAmbiguous") (EVar "sameMod")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "importCtorNames" (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyCon "UsePath") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "importCtorNames" ((PVar "known") (PVar "path")) (EIf (EBinOp "==" (EApp (EVar "useModId") (EVar "path")) (ELit (LString "core"))) (EListLit) (EMatch (EApp (EApp (EVar "findExports") (EApp (EVar "useModId") (EVar "path"))) (EVar "known")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "exp")) () (EBlock (DoLet false false (PTuple (PVar "names") PWild) (EApp (EApp (EVar "importedNamesMM") (EVar "path")) (EVar "exp"))) (DoExpr (EApp (EApp (EVar "filterInSet") (EApp (EApp (EVar "omFromNames") (EFieldAccess (EVar "exp") "expCtors")) (EVar "omEmpty"))) (EVar "names"))))))))
(DTypeSig false "ctorProvenance" (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "List") (TyCon "UsePath")) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "ctorProvenance" ((PVar "known") (PVar "paths")) (EApp (EApp (EApp (EVar "foldCtorProvenance") (EVar "known")) (EVar "omEmpty")) (EVar "paths")))
(DTypeSig false "foldCtorProvenance" (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "UsePath")) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "foldCtorProvenance" (PWild (PVar "prov") (PList)) (EVar "prov"))
(DFunDef false "foldCtorProvenance" ((PVar "known") (PVar "prov") (PCons (PVar "p") (PVar "rest"))) (EBlock (DoLet false false (PVar "mid") (EApp (EVar "useModId") (EVar "p"))) (DoLet false false (PVar "prov2") (EIf (EBinOp "==" (EVar "mid") (ELit (LString "core"))) (EVar "prov") (EApp (EApp (EApp (EVar "addImportProvenance") (EVar "prov")) (EVar "mid")) (EApp (EApp (EVar "importCtorNames") (EVar "known")) (EVar "p"))))) (DoExpr (EApp (EApp (EApp (EVar "foldCtorProvenance") (EVar "known")) (EVar "prov2")) (EVar "rest")))))
(DTypeSig false "ctorAmbiguousSet" (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "ctorAmbiguousSet" ((PVar "known") (PVar "prog")) (EBlock (DoLet false false (PVar "prov") (EApp (EApp (EVar "ctorProvenance") (EVar "known")) (EApp (EVar "usePathsOf") (EVar "prog")))) (DoLet false false (PVar "sameMod") (EApp (EVar "ctorNames") (EVar "prog"))) (DoExpr (EApp (EApp (EVar "keepAmbiguous") (EVar "sameMod")) (EApp (EVar "provToPairs") (EVar "prov"))))))
(DTypeSig false "importTypeNames" (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyCon "UsePath") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "importTypeNames" ((PVar "known") (PVar "path")) (EApp (EApp (EApp (EVar "importNamesIn") (EVar "expTypesOf")) (EVar "known")) (EVar "path")))
(DTypeSig false "importIfaceNames" (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyCon "UsePath") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "importIfaceNames" ((PVar "known") (PVar "path")) (EApp (EApp (EApp (EVar "importNamesIn") (EVar "expInterfacesOf")) (EVar "known")) (EVar "path")))
(DTypeSig false "expTypesOf" (TyFun (TyCon "ModuleExports") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "expTypesOf" ((PVar "exp")) (EFieldAccess (EVar "exp") "expTypes"))
(DTypeSig false "expInterfacesOf" (TyFun (TyCon "ModuleExports") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "expInterfacesOf" ((PVar "exp")) (EFieldAccess (EVar "exp") "expInterfaces"))
(DTypeSig false "importNamesIn" (TyFun (TyFun (TyCon "ModuleExports") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyCon "UsePath") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "importNamesIn" ((PVar "nsOf") (PVar "known") (PVar "path")) (EIf (EBinOp "==" (EApp (EVar "useModId") (EVar "path")) (ELit (LString "core"))) (EListLit) (EMatch (EApp (EApp (EVar "findExports") (EApp (EVar "useModId") (EVar "path"))) (EVar "known")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "exp")) () (EBlock (DoLet false false (PTuple (PVar "names") PWild) (EApp (EApp (EVar "importedNamesMM") (EVar "path")) (EVar "exp"))) (DoExpr (EApp (EApp (EVar "filterInSet") (EApp (EApp (EVar "omFromNames") (EApp (EVar "nsOf") (EVar "exp"))) (EVar "omEmpty"))) (EVar "names"))))))))
(DTypeSig false "foldNamespaceProvenance" (TyFun (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyCon "UsePath") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "UsePath")) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "foldNamespaceProvenance" (PWild PWild (PVar "prov") (PList)) (EVar "prov"))
(DFunDef false "foldNamespaceProvenance" ((PVar "namesOf") (PVar "known") (PVar "prov") (PCons (PVar "p") (PVar "rest"))) (EBlock (DoLet false false (PVar "mid") (EApp (EVar "useModId") (EVar "p"))) (DoLet false false (PVar "prov2") (EIf (EBinOp "==" (EVar "mid") (ELit (LString "core"))) (EVar "prov") (EApp (EApp (EApp (EVar "addImportProvenance") (EVar "prov")) (EVar "mid")) (EApp (EApp (EVar "namesOf") (EVar "known")) (EVar "p"))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "foldNamespaceProvenance") (EVar "namesOf")) (EVar "known")) (EVar "prov2")) (EVar "rest")))))
(DTypeSig false "typeAmbiguousSet" (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "typeAmbiguousSet" ((PVar "known") (PVar "prog")) (EBlock (DoLet false false (PVar "prov") (EApp (EApp (EApp (EApp (EVar "foldNamespaceProvenance") (EVar "importTypeNames")) (EVar "known")) (EVar "omEmpty")) (EApp (EVar "usePathsOf") (EVar "prog")))) (DoExpr (EApp (EApp (EVar "keepAmbiguous") (EApp (EVar "dataRecordNames") (EVar "prog"))) (EApp (EVar "provToPairs") (EVar "prov"))))))
(DTypeSig false "ifaceAmbiguousSet" (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "ifaceAmbiguousSet" ((PVar "known") (PVar "prog")) (EBlock (DoLet false false (PVar "prov") (EApp (EApp (EApp (EApp (EVar "foldNamespaceProvenance") (EVar "importIfaceNames")) (EVar "known")) (EVar "omEmpty")) (EApp (EVar "usePathsOf") (EVar "prog")))) (DoExpr (EApp (EApp (EVar "keepAmbiguous") (EApp (EVar "interfaceNamesOf") (EVar "prog"))) (EApp (EVar "provToPairs") (EVar "prov"))))))
(DTypeSig false "foldImports" (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "UsePath") (TyCon "Loc"))) (TyCon "ImportAdds"))))
(DFunDef false "foldImports" (PWild (PList)) (EVar "emptyAdds"))
(DFunDef false "foldImports" ((PVar "known") (PCons (PTuple (PVar "p") (PVar "loc")) (PVar "rest"))) (EApp (EApp (EVar "mergeAdds") (EApp (EApp (EApp (EVar "oneImport") (EVar "known")) (EVar "p")) (EVar "loc"))) (EApp (EApp (EVar "foldImports") (EVar "known")) (EVar "rest"))))
(DTypeSig false "oneImport" (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyCon "UsePath") (TyFun (TyCon "Loc") (TyCon "ImportAdds")))))
(DFunDef false "oneImport" ((PVar "known") (PVar "path") (PVar "loc")) (EBlock (DoLet false false (PVar "mid") (EApp (EVar "useModId") (EVar "path"))) (DoExpr (EIf (EBinOp "==" (EVar "mid") (ELit (LString "core"))) (EVar "emptyAdds") (EMatch (EApp (EApp (EVar "findExports") (EVar "mid")) (EVar "known")) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "stubOrUnknown") (EVar "known")) (EVar "path")) (EVar "mid")) (EVar "loc"))) (arm (PCon "Some" (PVar "exp")) () (EApp (EApp (EApp (EVar "realImport") (EVar "exp")) (EVar "path")) (EVar "loc"))))))))
(DTypeSig false "stubOrUnknown" (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyCon "UsePath") (TyFun (TyCon "String") (TyFun (TyCon "Loc") (TyCon "ImportAdds"))))))
(DFunDef false "stubOrUnknown" ((PVar "known") (PVar "path") (PVar "mid") (PVar "loc")) (EIf (EBinOp ">" (EApp (EVar "omSize") (EVar "known")) (ELit (LInt 0))) (ERecordCreate "ImportAdds" ((fa "iaImported" (EListLit)) (fa "iaValues" (EListLit)) (fa "iaTypes" (EListLit)) (fa "iaCtors" (EListLit)) (fa "iaIfaces" (EListLit)) (fa "iaFieldOwners" (EListLit)) (fa "iaErrors" (EListLit (EApp (EApp (EVar "UnknownModule") (EVar "mid")) (EApp (EVar "Some") (EVar "loc"))))))) (EBlock (DoLet false false (PVar "names") (EApp (EVar "useStubNames") (EVar "path"))) (DoExpr (ERecordCreate "ImportAdds" ((fa "iaImported" (EVar "names")) (fa "iaValues" (EVar "names")) (fa "iaTypes" (EVar "names")) (fa "iaCtors" (EListLit)) (fa "iaIfaces" (EListLit)) (fa "iaFieldOwners" (EListLit)) (fa "iaErrors" (EListLit))))))))
(DTypeSig false "realImport" (TyFun (TyCon "ModuleExports") (TyFun (TyCon "UsePath") (TyFun (TyCon "Loc") (TyCon "ImportAdds")))))
(DFunDef false "realImport" ((PVar "exp") (PVar "path") (PVar "loc")) (EBlock (DoLet false false (PTuple (PVar "names") (PVar "errs")) (EApp (EApp (EVar "importedNamesMM") (EVar "path")) (EVar "exp"))) (DoExpr (ERecordCreate "ImportAdds" ((fa "iaImported" (EVar "names")) (fa "iaValues" (EApp (EApp (EVar "filterInSet") (EApp (EApp (EVar "omFromNames") (EFieldAccess (EVar "exp") "expValues")) (EVar "omEmpty"))) (EVar "names"))) (fa "iaTypes" (EApp (EApp (EVar "filterContains") (EFieldAccess (EVar "exp") "expTypes")) (EVar "names"))) (fa "iaCtors" (EApp (EApp (EVar "filterContains") (EFieldAccess (EVar "exp") "expCtors")) (EVar "names"))) (fa "iaIfaces" (EApp (EApp (EVar "filterContains") (EFieldAccess (EVar "exp") "expInterfaces")) (EVar "names"))) (fa "iaFieldOwners" (EApp (EApp (EVar "ownedFieldOwners") (EVar "exp")) (EFieldAccess (EVar "exp") "expFieldOwners"))) (fa "iaErrors" (EApp (EApp (EMethodRef "map") (EApp (EVar "withResErrorLoc") (EVar "loc"))) (EVar "errs"))))))))
(DTypeSig false "withResErrorLoc" (TyFun (TyCon "Loc") (TyFun (TyCon "ResError") (TyCon "ResError"))))
(DFunDef false "withResErrorLoc" ((PVar "loc") (PCon "PrivateNameAccess" (PVar "n") (PVar "m") (PCon "None"))) (EApp (EApp (EApp (EVar "PrivateNameAccess") (EVar "n")) (EVar "m")) (EApp (EVar "Some") (EVar "loc"))))
(DFunDef false "withResErrorLoc" (PWild (PCon "PrivateNameAccess" (PVar "n") (PVar "m") (PCon "Some" (PVar "l")))) (EApp (EApp (EApp (EVar "PrivateNameAccess") (EVar "n")) (EVar "m")) (EApp (EVar "Some") (EVar "l"))))
(DFunDef false "withResErrorLoc" ((PVar "loc") (PCon "NoExportedConstructors" (PVar "n") (PVar "m") (PCon "None"))) (EApp (EApp (EApp (EVar "NoExportedConstructors") (EVar "n")) (EVar "m")) (EApp (EVar "Some") (EVar "loc"))))
(DFunDef false "withResErrorLoc" (PWild (PCon "NoExportedConstructors" (PVar "n") (PVar "m") (PCon "Some" (PVar "l")))) (EApp (EApp (EApp (EVar "NoExportedConstructors") (EVar "n")) (EVar "m")) (EApp (EVar "Some") (EVar "l"))))
(DFunDef false "withResErrorLoc" (PWild (PVar "e")) (EVar "e"))
(DTypeSig false "ownedFieldOwners" (TyFun (TyCon "ModuleExports") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "ownedFieldOwners" (PWild (PList)) (EListLit))
(DFunDef false "ownedFieldOwners" ((PVar "exp") (PCons (PTuple (PVar "f") (PVar "o")) (PVar "rest"))) (EIf (EBinOp "||" (EApp (EApp (EVar "contains") (EVar "o")) (EFieldAccess (EVar "exp") "expTypes")) (EApp (EApp (EVar "contains") (EVar "o")) (EFieldAccess (EVar "exp") "expCtors"))) (EBinOp "::" (ETuple (EVar "f") (EVar "o")) (EApp (EApp (EVar "ownedFieldOwners") (EVar "exp")) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "ownedFieldOwners") (EVar "exp")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "importedIfaceMethods" (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "importedIfaceMethods" ((PVar "known") (PVar "prog")) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "oneImportIfaceMethods") (EVar "known"))) (EApp (EVar "usePathsOf") (EVar "prog"))))
(DTypeSig false "oneImportIfaceMethods" (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyCon "UsePath") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "oneImportIfaceMethods" ((PVar "known") (PVar "path")) (EBlock (DoLet false false (PVar "mid") (EApp (EVar "useModId") (EVar "path"))) (DoExpr (EIf (EBinOp "==" (EVar "mid") (ELit (LString "core"))) (EListLit) (EMatch (EApp (EApp (EVar "findExports") (EVar "mid")) (EVar "known")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "exp")) () (EApp (EApp (EVar "filterIfaceMethods") (EApp (EApp (EVar "importIfaceNames") (EVar "known")) (EVar "path"))) (EFieldAccess (EVar "exp") "expIfaceMethods"))))))))
(DTypeSig false "filterIfaceMethods" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "filterIfaceMethods" (PWild (PList)) (EListLit))
(DFunDef false "filterIfaceMethods" ((PVar "pathIfaces") (PCons (PTuple (PVar "iface") (PVar "ms")) (PVar "rest"))) (EIf (EApp (EApp (EVar "contains") (EVar "iface")) (EVar "pathIfaces")) (EBinOp "::" (ETuple (EVar "iface") (EVar "ms")) (EApp (EApp (EVar "filterIfaceMethods") (EVar "pathIfaces")) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "filterIfaceMethods") (EVar "pathIfaces")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "importedEffects" (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "importedEffects" ((PVar "known") (PVar "prog")) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "oneImportEffects") (EVar "known"))) (EApp (EVar "usePathsOf") (EVar "prog"))))
(DTypeSig false "oneImportEffects" (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyCon "UsePath") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "oneImportEffects" ((PVar "known") (PVar "path")) (EBlock (DoLet false false (PVar "mid") (EApp (EVar "useModId") (EVar "path"))) (DoExpr (EIf (EBinOp "==" (EVar "mid") (ELit (LString "core"))) (EListLit) (EMatch (EApp (EApp (EVar "findExports") (EVar "mid")) (EVar "known")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "exp")) () (EFieldAccess (EVar "exp") "expEffects")))))))
(DTypeSig false "buildEnvMM" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyTuple (TyCon "Env") (TyApp (TyCon "List") (TyCon "ResError")))))))))
(DFunDef false "buildEnvMM" ((PVar "runtimeDecls") (PVar "preludeDecls") (PVar "known") (PVar "prog") (PVar "internalGuard")) (EBlock (DoLet false false (PVar "seed") (EApp (EVar "not") (EApp (EVar "programIsCore") (EVar "prog")))) (DoLet false false (PVar "pTypes") (EApp (EApp (EVar "whenL") (EVar "seed")) (EApp (EVar "dataRecordNames") (EVar "preludeDecls")))) (DoLet false false (PVar "pCtors") (EApp (EApp (EVar "whenL") (EVar "seed")) (EApp (EVar "ctorNames") (EVar "preludeDecls")))) (DoLet false false (PVar "pIfaces") (EApp (EApp (EVar "whenL") (EVar "seed")) (EApp (EVar "interfaceList") (EVar "preludeDecls")))) (DoLet false false (PVar "pValues") (EApp (EApp (EVar "whenL") (EVar "seed")) (EApp (EVar "preludeValueNames") (EVar "preludeDecls")))) (DoLet false false (PVar "pFieldOwners") (EApp (EApp (EVar "whenL") (EVar "seed")) (EApp (EVar "fieldOwnersOf") (EVar "preludeDecls")))) (DoLet false false (PVar "uIfaces") (EApp (EVar "interfaceList") (EVar "prog"))) (DoLet false false (PVar "adds") (EApp (EApp (EVar "collectImports") (EVar "known")) (EVar "prog"))) (DoLet false false (PVar "baseIfaces") (EBinOp "++" (EBinOp "++" (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "pIfaces")) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "uIfaces"))) (EFieldAccess (EVar "adds") "iaIfaces"))) (DoLet false false (PVar "impIfaceMethods") (EApp (EApp (EVar "importedIfaceMethods") (EVar "known")) (EVar "prog"))) (DoLet false false (PVar "impEffects") (EApp (EApp (EVar "importedEffects") (EVar "known")) (EVar "prog"))) (DoLet false false (PVar "impModValues") (EApp (EApp (EVar "importedModuleValueSets") (EVar "known")) (EVar "prog"))) (DoLet false false (PVar "valuesM") (EApp (EApp (EVar "omFromNames") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EApp (EVar "externNames") (EVar "runtimeDecls")) (EVar "pValues")) (EApp (EVar "userValueNames") (EVar "prog"))) (EFieldAccess (EVar "adds") "iaValues"))) (EVar "omEmpty"))) (DoLet false false (PVar "typesM") (EApp (EApp (EVar "omFromNames") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EVar "primitiveTypes") (EVar "pTypes")) (EApp (EVar "dataRecordNames") (EVar "prog"))) (EFieldAccess (EVar "adds") "iaTypes"))) (EVar "omEmpty"))) (DoLet false false (PVar "ctorsM") (EApp (EApp (EVar "omFromNames") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EVar "primitiveConstructors") (EVar "pCtors")) (EApp (EVar "ctorNames") (EVar "prog"))) (EFieldAccess (EVar "adds") "iaCtors"))) (EVar "omEmpty"))) (DoLet false false (PVar "importedM") (EApp (EApp (EVar "omFromNames") (EFieldAccess (EVar "adds") "iaImported")) (EVar "omEmpty"))) (DoLet false false (PVar "env") (ERecordCreate "Env" ((fa "values" (EVar "valuesM")) (fa "types" (EVar "typesM")) (fa "ctors" (EVar "ctorsM")) (fa "fields" (EBinOp "++" (EBinOp "++" (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "pFieldOwners")) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EApp (EVar "fieldOwnersOf") (EVar "prog")))) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EFieldAccess (EVar "adds") "iaFieldOwners")))) (fa "fieldOwners" (EBinOp "++" (EBinOp "++" (EVar "pFieldOwners") (EApp (EVar "fieldOwnersOf") (EVar "prog"))) (EFieldAccess (EVar "adds") "iaFieldOwners"))) (fa "fieldOwnersIdx" (EApp (EVar "buildFieldOwnerIndex") (EBinOp "++" (EBinOp "++" (EVar "pFieldOwners") (EApp (EVar "fieldOwnersOf") (EVar "prog"))) (EFieldAccess (EVar "adds") "iaFieldOwners")))) (fa "interfaces" (EVar "baseIfaces")) (fa "ifaceMethods" (EBinOp "++" (EBinOp "++" (EVar "pIfaces") (EVar "uIfaces")) (EVar "impIfaceMethods"))) (fa "effects" (EBinOp "++" (EApp (EVar "effectNames") (EVar "prog")) (EVar "impEffects"))) (fa "imported" (EVar "importedM")) (fa "importedModuleValues" (EVar "impModValues")) (fa "ambiguous" (EApp (EApp (EVar "ambiguousSet") (EVar "known")) (EVar "prog"))) (fa "ctorAmbiguous" (EApp (EApp (EVar "ctorAmbiguousSet") (EVar "known")) (EVar "prog"))) (fa "typeAmbiguous" (EApp (EApp (EVar "typeAmbiguousSet") (EVar "known")) (EVar "prog"))) (fa "ifaceAmbiguous" (EApp (EApp (EVar "ifaceAmbiguousSet") (EVar "known")) (EVar "prog"))) (fa "internalGuard" (EApp (EApp (EVar "omFromNames") (EVar "internalGuard")) (EVar "omEmpty"))) (fa "sugValues" (EApp (EVar "sugPoolOf") (EBinOp "++" (EBinOp "++" (EApp (EVar "omKeys") (EVar "valuesM")) (EApp (EVar "omKeys") (EVar "ctorsM"))) (EApp (EVar "omKeys") (EVar "importedM"))))) (fa "sugTypes" (EApp (EVar "sugPoolOf") (EBinOp "++" (EApp (EVar "omKeys") (EVar "typesM")) (EApp (EVar "omKeys") (EVar "importedM")))))))) (DoExpr (ETuple (EVar "env") (EFieldAccess (EVar "adds") "iaErrors")))))
(DTypeSig false "importedModuleValueSets" (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "importedModuleValueSets" ((PVar "known") (PVar "prog")) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "oneImportedModuleValues") (EVar "known"))) (EApp (EVar "usePathsOf") (EVar "prog"))))
(DTypeSig false "oneImportedModuleValues" (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyCon "UsePath") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "oneImportedModuleValues" ((PVar "known") (PVar "path")) (EBlock (DoLet false false (PVar "mid") (EApp (EVar "useModId") (EVar "path"))) (DoExpr (EIf (EBinOp "==" (EVar "mid") (ELit (LString "core"))) (EListLit) (EMatch (EApp (EApp (EVar "findExports") (EVar "mid")) (EVar "known")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "exp")) () (EListLit (ETuple (EVar "mid") (EFieldAccess (EVar "exp") "expValues")))))))))
(DTypeSig false "coreExports" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "ModuleExports")))
(DFunDef false "coreExports" ((PVar "preludeDecls")) (ERecordCreate "ModuleExports" ((fa "modId" (ELit (LString "core"))) (fa "expValues" (EApp (EVar "preludeValueNames") (EVar "preludeDecls"))) (fa "expTypes" (EApp (EVar "dataRecordNames") (EVar "preludeDecls"))) (fa "expCtors" (EApp (EVar "ctorNames") (EVar "preludeDecls"))) (fa "expTypeCtors" (EApp (EVar "typeCtorsAllOf") (EVar "preludeDecls"))) (fa "expFieldOwners" (EApp (EVar "fieldOwnersOf") (EVar "preludeDecls"))) (fa "expInterfaces" (EApp (EApp (EMethodRef "map") (EVar "fst")) (EApp (EVar "interfaceList") (EVar "preludeDecls")))) (fa "expIfaceMethods" (EApp (EVar "interfaceList") (EVar "preludeDecls"))) (fa "expEffects" (EApp (EVar "effectNames") (EVar "preludeDecls"))) (fa "expNewtypeCtors" (EListLit)))))
(DTypeSig false "typeCtorsAllOf" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "typeCtorsAllOf" ((PList)) (EListLit))
(DFunDef false "typeCtorsAllOf" ((PCons (PRec "DNewtype" ((rf "newtypeName" (PVar "n")) (rf "newtypeCtor" (PVar "con"))) false) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "n") (EListLit (EVar "con"))) (EApp (EVar "typeCtorsAllOf") (EVar "rest"))))
(DFunDef false "typeCtorsAllOf" ((PCons (PRec "DData" ((rf "dataName" (PVar "n")) (rf "dataCtors" (PVar "vs"))) false) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "n") (EApp (EApp (EMethodRef "map") (EVar "variantName")) (EVar "vs"))) (EApp (EVar "typeCtorsAllOf") (EVar "rest"))))
(DFunDef false "typeCtorsAllOf" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "typeCtorsAllOf") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "typeCtorsAllOf" ((PCons PWild (PVar "rest"))) (EApp (EVar "typeCtorsAllOf") (EVar "rest")))
(DTypeSig false "buildExports" (TyFun (TyCon "ModuleExports") (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Env") (TyCon "ModuleExports")))))))
(DFunDef false "buildExports" ((PVar "coreExp") (PVar "known") (PVar "modId") (PVar "prog") (PVar "env")) (ERecordCreate "ModuleExports" ((fa "modId" (EVar "modId")) (fa "expValues" (EBinOp "++" (EBinOp "++" (EApp (EVar "expValuesDirect") (EVar "prog")) (EApp (EApp (EVar "publicIfaceMethodVals") (EVar "prog")) (EVar "env"))) (EApp (EApp (EApp (EVar "reExpValues") (EVar "coreExp")) (EVar "known")) (EVar "prog")))) (fa "expTypes" (EBinOp "++" (EApp (EVar "expTypesDirect") (EVar "prog")) (EApp (EApp (EApp (EVar "reExpTypes") (EVar "coreExp")) (EVar "known")) (EVar "prog")))) (fa "expCtors" (EBinOp "++" (EApp (EVar "expCtorsDirect") (EVar "prog")) (EApp (EApp (EApp (EVar "reExpCtors") (EVar "coreExp")) (EVar "known")) (EVar "prog")))) (fa "expTypeCtors" (EApp (EVar "expTypeCtorsDirect") (EVar "prog"))) (fa "expFieldOwners" (EBinOp "++" (EApp (EVar "expFieldOwnersDirect") (EVar "prog")) (EApp (EApp (EApp (EVar "reExpFieldOwners") (EVar "coreExp")) (EVar "known")) (EVar "prog")))) (fa "expInterfaces" (EBinOp "++" (EApp (EVar "expInterfacesDirect") (EVar "prog")) (EApp (EApp (EApp (EVar "reExpInterfaces") (EVar "coreExp")) (EVar "known")) (EVar "prog")))) (fa "expIfaceMethods" (EBinOp "++" (EApp (EVar "expIfaceMethodsDirect") (EVar "prog")) (EApp (EApp (EApp (EVar "reExpIfaceMethods") (EVar "coreExp")) (EVar "known")) (EVar "prog")))) (fa "expEffects" (EBinOp "++" (EApp (EVar "expEffectsDirect") (EVar "prog")) (EApp (EApp (EApp (EVar "reExpEffects") (EVar "coreExp")) (EVar "known")) (EVar "prog")))) (fa "expNewtypeCtors" (EApp (EVar "expNewtypeCtorsDirect") (EVar "prog"))))))
(DTypeSig false "expNewtypeCtorsDirect" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "expNewtypeCtorsDirect" ((PList)) (EListLit))
(DFunDef false "expNewtypeCtorsDirect" ((PCons (PRec "DNewtype" ((rf "newtypePub" (PCon "True")) (rf "newtypeName" (PVar "n")) (rf "newtypeCtor" (PVar "con"))) false) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "con") (EVar "n")) (EApp (EVar "expNewtypeCtorsDirect") (EVar "rest"))))
(DFunDef false "expNewtypeCtorsDirect" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "expNewtypeCtorsDirect") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "expNewtypeCtorsDirect" ((PCons PWild (PVar "rest"))) (EApp (EVar "expNewtypeCtorsDirect") (EVar "rest")))
(DTypeSig false "expValuesDirect" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "expValuesDirect" ((PList)) (EListLit))
(DFunDef false "expValuesDirect" ((PCons (PCon "DTypeSig" (PCon "True") (PVar "n") PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "expValuesDirect") (EVar "rest"))))
(DFunDef false "expValuesDirect" ((PCons (PCon "DExtern" (PCon "True") (PVar "n") PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "expValuesDirect") (EVar "rest"))))
(DFunDef false "expValuesDirect" ((PCons (PCon "DFunDef" (PCon "True") (PVar "n") PWild PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "expValuesDirect") (EVar "rest"))))
(DFunDef false "expValuesDirect" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "expValuesDirect") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "expValuesDirect" ((PCons PWild (PVar "rest"))) (EApp (EVar "expValuesDirect") (EVar "rest")))
(DTypeSig false "publicIfaceMethodVals" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Env") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "publicIfaceMethodVals" ((PVar "prog") (PVar "env")) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "keepBoundMethods") (EVar "env"))) (EApp (EVar "pubIfaceMethodSets") (EVar "prog"))))
(DTypeSig false "keepBoundMethods" (TyFun (TyCon "Env") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "keepBoundMethods" ((PVar "env") (PVar "ms")) (EApp (EApp (EVar "filterInSet") (EFieldAccess (EVar "env") "values")) (EVar "ms")))
(DTypeSig false "pubIfaceMethodSets" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "pubIfaceMethodSets" ((PList)) (EListLit))
(DFunDef false "pubIfaceMethodSets" ((PCons (PRec "DInterface" ((rf "pub" (PCon "True")) (rf "methods" None)) true) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EMethodRef "map") (EVar "ifaceMethodNm")) (EVar "methods")) (EApp (EVar "pubIfaceMethodSets") (EVar "rest"))))
(DFunDef false "pubIfaceMethodSets" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "pubIfaceMethodSets") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "pubIfaceMethodSets" ((PCons PWild (PVar "rest"))) (EApp (EVar "pubIfaceMethodSets") (EVar "rest")))
(DTypeSig false "expTypesDirect" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "expTypesDirect" ((PList)) (EListLit))
(DFunDef false "expTypesDirect" ((PCons (PRec "DNewtype" ((rf "newtypePub" (PCon "True")) (rf "newtypeName" (PVar "n"))) false) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "expTypesDirect") (EVar "rest"))))
(DFunDef false "expTypesDirect" ((PCons (PRec "DData" ((rf "dataVis" (PCon "VisPublic")) (rf "dataName" (PVar "n"))) false) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "expTypesDirect") (EVar "rest"))))
(DFunDef false "expTypesDirect" ((PCons (PRec "DData" ((rf "dataVis" (PCon "VisAbstract")) (rf "dataName" (PVar "n"))) false) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "expTypesDirect") (EVar "rest"))))
(DFunDef false "expTypesDirect" ((PCons (PRec "DTypeAlias" ((rf "tyAliasPub" (PCon "True")) (rf "tyAliasName" (PVar "n"))) false) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "expTypesDirect") (EVar "rest"))))
(DFunDef false "expTypesDirect" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "expTypesDirect") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "expTypesDirect" ((PCons PWild (PVar "rest"))) (EApp (EVar "expTypesDirect") (EVar "rest")))
(DTypeSig false "expCtorsDirect" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "expCtorsDirect" ((PList)) (EListLit))
(DFunDef false "expCtorsDirect" ((PCons (PRec "DNewtype" ((rf "newtypePub" (PCon "True")) (rf "newtypeCtor" (PVar "con"))) false) (PVar "rest"))) (EBinOp "::" (EVar "con") (EApp (EVar "expCtorsDirect") (EVar "rest"))))
(DFunDef false "expCtorsDirect" ((PCons (PRec "DData" ((rf "dataVis" (PCon "VisPublic")) (rf "dataCtors" (PVar "vs"))) false) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EMethodRef "map") (EVar "variantName")) (EVar "vs")) (EApp (EVar "expCtorsDirect") (EVar "rest"))))
(DFunDef false "expCtorsDirect" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "expCtorsDirect") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "expCtorsDirect" ((PCons PWild (PVar "rest"))) (EApp (EVar "expCtorsDirect") (EVar "rest")))
(DTypeSig false "expTypeCtorsDirect" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "expTypeCtorsDirect" ((PList)) (EListLit))
(DFunDef false "expTypeCtorsDirect" ((PCons (PRec "DNewtype" ((rf "newtypePub" (PCon "True")) (rf "newtypeName" (PVar "n")) (rf "newtypeCtor" (PVar "con"))) false) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "n") (EListLit (EVar "con"))) (EApp (EVar "expTypeCtorsDirect") (EVar "rest"))))
(DFunDef false "expTypeCtorsDirect" ((PCons (PRec "DData" ((rf "dataVis" (PCon "VisPublic")) (rf "dataName" (PVar "n")) (rf "dataCtors" (PVar "vs"))) false) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "n") (EApp (EApp (EMethodRef "map") (EVar "variantName")) (EVar "vs"))) (EApp (EVar "expTypeCtorsDirect") (EVar "rest"))))
(DFunDef false "expTypeCtorsDirect" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "expTypeCtorsDirect") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "expTypeCtorsDirect" ((PCons PWild (PVar "rest"))) (EApp (EVar "expTypeCtorsDirect") (EVar "rest")))
(DTypeSig false "expFieldOwnersDirect" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "expFieldOwnersDirect" ((PList)) (EListLit))
(DFunDef false "expFieldOwnersDirect" ((PCons (PRec "DData" ((rf "dataVis" (PCon "VisPublic")) (rf "dataCtors" (PVar "vs"))) false) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EVar "variantFieldOwners")) (EVar "vs")) (EApp (EVar "expFieldOwnersDirect") (EVar "rest"))))
(DFunDef false "expFieldOwnersDirect" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "expFieldOwnersDirect") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "expFieldOwnersDirect" ((PCons PWild (PVar "rest"))) (EApp (EVar "expFieldOwnersDirect") (EVar "rest")))
(DTypeSig false "expInterfacesDirect" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "expInterfacesDirect" ((PList)) (EListLit))
(DFunDef false "expInterfacesDirect" ((PCons (PRec "DInterface" ((rf "pub" (PCon "True")) (rf "name" (PVar "n"))) true) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "expInterfacesDirect") (EVar "rest"))))
(DFunDef false "expInterfacesDirect" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "expInterfacesDirect") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "expInterfacesDirect" ((PCons PWild (PVar "rest"))) (EApp (EVar "expInterfacesDirect") (EVar "rest")))
(DTypeSig false "expIfaceMethodsDirect" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "expIfaceMethodsDirect" ((PList)) (EListLit))
(DFunDef false "expIfaceMethodsDirect" ((PCons (PRec "DInterface" ((rf "pub" (PCon "True")) (rf "name" (PVar "n")) (rf "methods" None)) true) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "n") (EApp (EApp (EMethodRef "map") (EVar "ifaceMethodNm")) (EVar "methods"))) (EApp (EVar "expIfaceMethodsDirect") (EVar "rest"))))
(DFunDef false "expIfaceMethodsDirect" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "expIfaceMethodsDirect") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "expIfaceMethodsDirect" ((PCons PWild (PVar "rest"))) (EApp (EVar "expIfaceMethodsDirect") (EVar "rest")))
(DTypeSig false "expEffectsDirect" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "expEffectsDirect" ((PList)) (EListLit))
(DFunDef false "expEffectsDirect" ((PCons (PCon "DEffect" (PCon "True") (PVar "n") PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "expEffectsDirect") (EVar "rest"))))
(DFunDef false "expEffectsDirect" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "expEffectsDirect") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "expEffectsDirect" ((PCons PWild (PVar "rest"))) (EApp (EVar "expEffectsDirect") (EVar "rest")))
(DTypeSig false "reExpEffects" (TyFun (TyCon "ModuleExports") (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "reExpEffects" ((PVar "coreExp") (PVar "known") (PVar "prog")) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EVar "overPubUse") (EVar "coreExp")) (EVar "known")) (EVar "reExpEffectsFrom"))) (EApp (EVar "pubUsePaths") (EVar "prog"))))
(DTypeSig false "reExpEffectsFrom" (TyFun (TyCon "UsePath") (TyFun (TyCon "ModuleExports") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "reExpEffectsFrom" ((PCon "UseWild" PWild) (PVar "src")) (EFieldAccess (EVar "src") "expEffects"))
(DFunDef false "reExpEffectsFrom" (PWild PWild) (EListLit))
(DTypeSig false "reexportBindings" (TyFun (TyCon "UsePath") (TyFun (TyCon "ModuleExports") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "reexportBindings" ((PCon "UseName" (PVar "ns")) PWild) (EIf (EBinOp ">" (EApp (EVar "listLen") (EVar "ns")) (ELit (LInt 1))) (EBlock (DoLet false false (PVar "n") (EApp (EVar "lastOf") (EVar "ns"))) (DoExpr (EListLit (ETuple (EVar "n") (EVar "n"))))) (EListLit)))
(DFunDef false "reexportBindings" ((PCon "UseGroup" PWild (PVar "members")) (PVar "src")) (EApp (EApp (EMethodRef "map") (EVar "dropLocOfExpanded")) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "expandMemberNames") (EVar "src"))) (EVar "members"))))
(DFunDef false "reexportBindings" ((PCon "UseWild" PWild) (PVar "src")) (EApp (EApp (EMethodRef "map") (EVar "selfBinding")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EFieldAccess (EVar "src") "expValues") (EFieldAccess (EVar "src") "expTypes")) (EFieldAccess (EVar "src") "expCtors")) (EFieldAccess (EVar "src") "expInterfaces"))))
(DFunDef false "reexportBindings" ((PCon "UseAlias" PWild PWild) PWild) (EListLit))
(DTypeSig false "dropLocOfExpanded" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyCon "Loc")) (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "dropLocOfExpanded" ((PTuple (PVar "origin") (PVar "local") PWild)) (ETuple (EVar "origin") (EVar "local")))
(DTypeSig false "selfBinding" (TyFun (TyCon "String") (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "selfBinding" ((PVar "n")) (ETuple (EVar "n") (EVar "n")))
(DTypeSig false "localsExportedFrom" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "localsExportedFrom" ((PVar "origins") (PVar "bindings")) (EBlock (DoLet false false (PVar "dom") (EApp (EApp (EVar "omFromNames") (EVar "origins")) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EMethodRef "map") (EVar "snd")) (EApp (EApp (EVar "filterList") (ELam ((PVar "b")) (EApp (EApp (EVar "omHasKey") (EApp (EVar "fst") (EVar "b"))) (EVar "dom")))) (EVar "bindings"))))))
(DTypeSig false "reExpValues" (TyFun (TyCon "ModuleExports") (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "reExpValues" ((PVar "coreExp") (PVar "known") (PVar "prog")) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EVar "overPubUse") (EVar "coreExp")) (EVar "known")) (EVar "reExpValuesFrom"))) (EApp (EVar "pubUsePaths") (EVar "prog"))))
(DTypeSig false "reExpValuesFrom" (TyFun (TyCon "UsePath") (TyFun (TyCon "ModuleExports") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "reExpValuesFrom" ((PVar "path") (PVar "src")) (EBlock (DoLet false false (PVar "bindings") (EApp (EApp (EVar "reexportBindings") (EVar "path")) (EVar "src"))) (DoExpr (EBinOp "++" (EApp (EApp (EVar "localsExportedFrom") (EFieldAccess (EVar "src") "expValues")) (EVar "bindings")) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "ifaceValsOf") (EVar "src"))) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "bindings")))))))
(DTypeSig false "ifaceValsOf" (TyFun (TyCon "ModuleExports") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "ifaceValsOf" ((PVar "src") (PVar "n")) (EIf (EApp (EApp (EVar "contains") (EVar "n")) (EFieldAccess (EVar "src") "expInterfaces")) (EApp (EApp (EVar "filterContains") (EFieldAccess (EVar "src") "expValues")) (EApp (EApp (EVar "ifaceMethodsOf") (EVar "n")) (EFieldAccess (EVar "src") "expIfaceMethods"))) (EListLit)))
(DTypeSig false "reExpTypes" (TyFun (TyCon "ModuleExports") (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "reExpTypes" ((PVar "coreExp") (PVar "known") (PVar "prog")) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EVar "overPubUse") (EVar "coreExp")) (EVar "known")) (EVar "reExpTypesFrom"))) (EApp (EVar "pubUsePaths") (EVar "prog"))))
(DTypeSig false "reExpTypesFrom" (TyFun (TyCon "UsePath") (TyFun (TyCon "ModuleExports") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "reExpTypesFrom" ((PVar "path") (PVar "src")) (EApp (EApp (EVar "localsExportedFrom") (EFieldAccess (EVar "src") "expTypes")) (EApp (EApp (EVar "reexportBindings") (EVar "path")) (EVar "src"))))
(DTypeSig false "reExpCtors" (TyFun (TyCon "ModuleExports") (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "reExpCtors" ((PVar "coreExp") (PVar "known") (PVar "prog")) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EVar "overPubUse") (EVar "coreExp")) (EVar "known")) (EVar "reExpCtorsFrom"))) (EApp (EVar "pubUsePaths") (EVar "prog"))))
(DTypeSig false "reExpCtorsFrom" (TyFun (TyCon "UsePath") (TyFun (TyCon "ModuleExports") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "reExpCtorsFrom" ((PVar "path") (PVar "src")) (EApp (EApp (EVar "localsExportedFrom") (EFieldAccess (EVar "src") "expCtors")) (EApp (EApp (EVar "reexportBindings") (EVar "path")) (EVar "src"))))
(DTypeSig false "reExpInterfaces" (TyFun (TyCon "ModuleExports") (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "reExpInterfaces" ((PVar "coreExp") (PVar "known") (PVar "prog")) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EVar "overPubUse") (EVar "coreExp")) (EVar "known")) (EVar "reExpInterfacesFrom"))) (EApp (EVar "pubUsePaths") (EVar "prog"))))
(DTypeSig false "reexportOrigins" (TyFun (TyCon "UsePath") (TyFun (TyCon "ModuleExports") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "reexportOrigins" ((PVar "path") (PVar "src")) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EApp (EApp (EVar "reexportBindings") (EVar "path")) (EVar "src"))))
(DTypeSig false "reExpInterfacesFrom" (TyFun (TyCon "UsePath") (TyFun (TyCon "ModuleExports") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "reExpInterfacesFrom" ((PVar "path") (PVar "src")) (EApp (EApp (EVar "filterContains") (EFieldAccess (EVar "src") "expInterfaces")) (EApp (EApp (EVar "reexportOrigins") (EVar "path")) (EVar "src"))))
(DTypeSig false "reExpIfaceMethods" (TyFun (TyCon "ModuleExports") (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "reExpIfaceMethods" ((PVar "coreExp") (PVar "known") (PVar "prog")) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EVar "overPubUse") (EVar "coreExp")) (EVar "known")) (EVar "reExpIfaceMethodsFrom"))) (EApp (EVar "pubUsePaths") (EVar "prog"))))
(DTypeSig false "reExpIfaceMethodsFrom" (TyFun (TyCon "UsePath") (TyFun (TyCon "ModuleExports") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "reExpIfaceMethodsFrom" ((PVar "path") (PVar "src")) (EApp (EApp (EVar "ifaceMethodPairs") (EVar "src")) (EApp (EApp (EVar "filterContains") (EFieldAccess (EVar "src") "expInterfaces")) (EApp (EApp (EVar "reexportOrigins") (EVar "path")) (EVar "src")))))
(DTypeSig false "ifaceMethodPairs" (TyFun (TyCon "ModuleExports") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "ifaceMethodPairs" (PWild (PList)) (EListLit))
(DFunDef false "ifaceMethodPairs" ((PVar "src") (PCons (PVar "i") (PVar "rest"))) (EBinOp "::" (ETuple (EVar "i") (EApp (EApp (EVar "ifaceMethodsOf") (EVar "i")) (EFieldAccess (EVar "src") "expIfaceMethods"))) (EApp (EApp (EVar "ifaceMethodPairs") (EVar "src")) (EVar "rest"))))
(DTypeSig false "reExpFieldOwners" (TyFun (TyCon "ModuleExports") (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "reExpFieldOwners" ((PVar "coreExp") (PVar "known") (PVar "prog")) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EVar "overPubUse") (EVar "coreExp")) (EVar "known")) (EVar "reExpFieldOwnersFrom"))) (EApp (EVar "pubUsePaths") (EVar "prog"))))
(DTypeSig false "reExpFieldOwnersFrom" (TyFun (TyCon "UsePath") (TyFun (TyCon "ModuleExports") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "reExpFieldOwnersFrom" ((PVar "path") (PVar "src")) (EApp (EApp (EVar "ownersForTypes") (EApp (EApp (EVar "filterContains") (EFieldAccess (EVar "src") "expTypes")) (EApp (EApp (EVar "reexportOrigins") (EVar "path")) (EVar "src")))) (EFieldAccess (EVar "src") "expFieldOwners")))
(DTypeSig false "ownersForTypes" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "ownersForTypes" (PWild (PList)) (EListLit))
(DFunDef false "ownersForTypes" ((PVar "types") (PCons (PTuple (PVar "f") (PVar "o")) (PVar "rest"))) (EIf (EApp (EApp (EVar "contains") (EVar "o")) (EVar "types")) (EBinOp "::" (ETuple (EVar "f") (EVar "o")) (EApp (EApp (EVar "ownersForTypes") (EVar "types")) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "ownersForTypes") (EVar "types")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "overPubUse" (TyFun (TyCon "ModuleExports") (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyFun (TyCon "UsePath") (TyFun (TyCon "ModuleExports") (TyApp (TyCon "List") (TyVar "b")))) (TyFun (TyCon "UsePath") (TyApp (TyCon "List") (TyVar "b")))))))
(DFunDef false "overPubUse" ((PVar "coreExp") (PVar "known") (PVar "f") (PVar "path")) (EBlock (DoLet false false (PVar "mid") (EApp (EVar "useModId") (EVar "path"))) (DoExpr (EIf (EBinOp "==" (EVar "mid") (ELit (LString "core"))) (EApp (EApp (EVar "f") (EVar "path")) (EVar "coreExp")) (EMatch (EApp (EApp (EVar "findExports") (EVar "mid")) (EVar "known")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "src")) () (EApp (EApp (EVar "f") (EVar "path")) (EVar "src"))))))))
(DTypeSig true "resolveModule" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyTuple (TyCon "ModuleExports") (TyApp (TyCon "List") (TyCon "ResError")))))))))
(DFunDef false "resolveModule" ((PVar "runtimeDecls") (PVar "preludeDecls") (PVar "known") (PVar "modId") (PVar "prog")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveModuleG") (EListLit)) (EVar "runtimeDecls")) (EVar "preludeDecls")) (EVar "known")) (EVar "modId")) (EVar "prog")))
(DTypeSig true "resolveModuleG" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyTuple (TyCon "ModuleExports") (TyApp (TyCon "List") (TyCon "ResError"))))))))))
(DFunDef false "resolveModuleG" ((PVar "internalGuard") (PVar "runtimeDecls") (PVar "preludeDecls") (PVar "known") (PVar "modId") (PVar "prog")) (EBlock (DoLet false false (PTuple (PVar "env") (PVar "importErrs")) (EApp (EApp (EApp (EApp (EApp (EVar "buildEnvMM") (EVar "runtimeDecls")) (EVar "preludeDecls")) (EVar "known")) (EVar "prog")) (EVar "internalGuard"))) (DoLet false false (PVar "errs") (EApp (EVar "dedupResErrors") (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "buildErrors") (EVar "preludeDecls")) (EVar "prog")) (EVar "importErrs")) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "checkDecl") (EVar "env"))) (EVar "prog"))))) (DoLet false false (PVar "exp") (EApp (EApp (EApp (EApp (EApp (EVar "buildExports") (EApp (EVar "coreExports") (EVar "preludeDecls"))) (EVar "known")) (EVar "modId")) (EVar "prog")) (EVar "env"))) (DoExpr (ETuple (EVar "exp") (EVar "errs")))))
(DTypeSig false "resolveModulesErrors" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyCon "ResError")))))))
(DFunDef false "resolveModulesErrors" ((PVar "rt") (PVar "pre") (PVar "known") (PVar "mods")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveModulesErrorsG") (EVar "True")) (EListLit)) (EVar "rt")) (EVar "pre")) (EVar "known")) (EVar "mods")))
(DTypeSig false "resolveModulesErrorsPairsG" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "ResError")))))))))))
(DFunDef false "resolveModulesErrorsPairsG" (PWild PWild PWild PWild PWild (PList)) (EListLit))
(DFunDef false "resolveModulesErrorsPairsG" ((PVar "allowInternal") (PVar "trustedMods") (PVar "rt") (PVar "pre") (PVar "known") (PCons (PTuple (PVar "mid") (PVar "prog")) (PVar "rest"))) (EBlock (DoLet false false (PVar "guard") (EIf (EBinOp "||" (EVar "allowInternal") (EApp (EApp (EVar "contains") (EVar "mid")) (EVar "trustedMods"))) (EListLit) (EVar "internalExterns"))) (DoLet false false (PTuple (PVar "exp") (PVar "errs")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveModuleG") (EDictApp "guard")) (EVar "rt")) (EVar "pre")) (EVar "known")) (EVar "mid")) (EVar "prog"))) (DoExpr (EBinOp "::" (ETuple (EVar "mid") (EVar "errs")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveModulesErrorsPairsG") (EVar "allowInternal")) (EVar "trustedMods")) (EVar "rt")) (EVar "pre")) (EApp (EApp (EApp (EVar "omInsert") (EFieldAccess (EVar "exp") "modId")) (EVar "exp")) (EVar "known"))) (EVar "rest"))))))
(DTypeSig false "resolveModulesErrorsG" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyCon "ResError")))))))))
(DFunDef false "resolveModulesErrorsG" ((PVar "allowInternal") (PVar "trustedMods") (PVar "rt") (PVar "pre") (PVar "known") (PVar "mods")) (EApp (EApp (EDictApp "flatMap") (EVar "snd")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveModulesErrorsPairsG") (EVar "allowInternal")) (EVar "trustedMods")) (EVar "rt")) (EVar "pre")) (EVar "known")) (EVar "mods"))))
(DTypeSig true "resolveModulesToLines" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "String")))))
(DFunDef false "resolveModulesToLines" ((PVar "runtimeDecls") (PVar "preludeDecls") (PVar "mods")) (EApp (EVar "joinNl") (EApp (EApp (EMethodRef "map") (EVar "resErrorSexp")) (EApp (EApp (EApp (EApp (EVar "resolveModulesErrors") (EVar "runtimeDecls")) (EVar "preludeDecls")) (EVar "omEmpty")) (EVar "mods")))))
(DTypeSig true "resolveModulesToLinesG" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "String")))))))
(DFunDef false "resolveModulesToLinesG" ((PVar "allowInternal") (PVar "trustedMods") (PVar "runtimeDecls") (PVar "preludeDecls") (PVar "mods")) (EApp (EVar "joinNl") (EApp (EApp (EMethodRef "map") (EVar "resErrorSexp")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveModulesErrorsG") (EVar "allowInternal")) (EVar "trustedMods")) (EVar "runtimeDecls")) (EVar "preludeDecls")) (EVar "omEmpty")) (EVar "mods")))))
(DTypeSig true "resolveModulesErrorsByFile" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "ResError")))))))))))
(DFunDef false "resolveModulesErrorsByFile" ((PVar "modPaths") (PVar "allowInternal") (PVar "trustedMods") (PVar "runtimeDecls") (PVar "preludeDecls") (PVar "mods")) (EApp (EApp (EMethodRef "map") (EApp (EVar "fileOfModuleErrors") (EVar "modPaths"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resolveModulesErrorsPairsG") (EVar "allowInternal")) (EVar "trustedMods")) (EVar "runtimeDecls")) (EVar "preludeDecls")) (EVar "omEmpty")) (EVar "mods"))))
(DTypeSig false "fileOfModuleErrors" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "ResError"))) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "ResError"))))))
(DFunDef false "fileOfModuleErrors" ((PVar "modPaths") (PTuple (PVar "mid") (PVar "errs"))) (EBlock (DoLet false false (PVar "file") (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "mid")) (EVar "modPaths")) (arm (PCon "Some" (PVar "p")) () (EVar "p")) (arm (PCon "None") () (ELit (LString ""))))) (DoExpr (ETuple (EVar "file") (EVar "errs")))))
(DTypeSig false "lookupBindId" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "String") (TyCon "Int"))))
(DFunDef false "lookupBindId" ((PVar "env") (PVar "n")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "env")) (arm (PCon "Some" (PVar "id")) () (EVar "id")) (arm (PCon "None") () (ELit (LInt 0)))))
(DTypeSig false "insertZero" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyApp (TyCon "OrdMap") (TyCon "Int")))))
(DFunDef false "insertZero" ((PList) (PVar "env")) (EVar "env"))
(DFunDef false "insertZero" ((PCons (PVar "n") (PVar "rest")) (PVar "env")) (EApp (EApp (EVar "insertZero") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (ELit (LInt 0))) (EVar "env"))))
(DTypeSig false "insertParams" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyApp (TyCon "OrdMap") (TyCon "Int")))))
(DFunDef false "insertParams" ((PList) (PVar "env")) (EVar "env"))
(DFunDef false "insertParams" ((PCons (PVar "p") (PVar "rest")) (PVar "env")) (EApp (EApp (EVar "insertParams") (EVar "rest")) (EApp (EApp (EVar "insertZero") (EApp (EVar "patBindings") (EVar "p"))) (EVar "env"))))
(DTypeSig false "topBinderNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "topBinderNames" ((PList)) (EListLit))
(DFunDef false "topBinderNames" ((PCons (PCon "DFunDef" PWild (PVar "n") PWild PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "topBinderNames") (EVar "rest"))))
(DFunDef false "topBinderNames" ((PCons (PCon "DLetGroup" PWild (PVar "binds")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EMethodRef "map") (EVar "letBindName")) (EVar "binds")) (EApp (EVar "topBinderNames") (EVar "rest"))))
(DFunDef false "topBinderNames" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "topBinderNames") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "topBinderNames" ((PCons PWild (PVar "rest"))) (EApp (EVar "topBinderNames") (EVar "rest")))
(DTypeSig false "numberFrom" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))))))
(DFunDef false "numberFrom" (PWild (PList)) (EListLit))
(DFunDef false "numberFrom" ((PVar "i") (PCons (PVar "n") (PVar "rest"))) (EBinOp "::" (ETuple (EVar "n") (EVar "i")) (EApp (EApp (EVar "numberFrom") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest"))))
(DTypeSig false "stampExpr" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "Expr") (TyCon "Expr"))))
(DFunDef false "stampExpr" (PWild (PCon "ELit" (PVar "l"))) (EApp (EVar "ELit") (EVar "l")))
(DFunDef false "stampExpr" (PWild (PCon "ENumLit" (PVar "n") (PVar "r") (PVar "d") (PVar "lx"))) (EApp (EApp (EApp (EApp (EVar "ENumLit") (EVar "n")) (EVar "r")) (EVar "d")) (EVar "lx")))
(DFunDef false "stampExpr" (PWild (PCon "EMethodRef" (PVar "m"))) (EApp (EVar "EMethodRef") (EVar "m")))
(DFunDef false "stampExpr" (PWild (PCon "EDictApp" (PVar "d"))) (EApp (EVar "EDictApp") (EVar "d")))
(DFunDef false "stampExpr" (PWild (PCon "EMethodAt" (PVar "name") (PVar "r") (PVar "ir") (PVar "mr"))) (EApp (EApp (EApp (EApp (EVar "EMethodAt") (EVar "name")) (EVar "r")) (EVar "ir")) (EVar "mr")))
(DFunDef false "stampExpr" (PWild (PCon "EDictAt" (PVar "name") (PVar "r"))) (EApp (EApp (EVar "EDictAt") (EVar "name")) (EVar "r")))
(DFunDef false "stampExpr" (PWild (PCon "EVarAt" (PVar "n") (PVar "a"))) (EApp (EApp (EVar "EVarAt") (EVar "n")) (EVar "a")))
(DFunDef false "stampExpr" (PWild (PCon "EVarId" (PVar "n") (PVar "i"))) (EApp (EApp (EVar "EVarId") (EVar "n")) (EVar "i")))
(DFunDef false "stampExpr" ((PVar "env") (PCon "EVar" (PVar "n"))) (EIf (EApp (EVar "isHint") (EVar "n")) (EApp (EVar "EVar") (EVar "n")) (EIf (EVar "otherwise") (EApp (EApp (EVar "EVarId") (EVar "n")) (EApp (EApp (EVar "lookupBindId") (EVar "env")) (EVar "n"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "stampExpr" ((PVar "env") (PCon "EApp" (PVar "f") (PVar "x"))) (EApp (EApp (EVar "EApp") (EApp (EApp (EVar "stampExpr") (EVar "env")) (EVar "f"))) (EApp (EApp (EVar "stampExpr") (EVar "env")) (EVar "x"))))
(DFunDef false "stampExpr" ((PVar "env") (PCon "ELam" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "ELam") (EVar "pats")) (EApp (EApp (EVar "stampExpr") (EApp (EApp (EVar "insertParams") (EVar "pats")) (EVar "env"))) (EVar "body"))))
(DFunDef false "stampExpr" ((PVar "env") (PCon "ELet" (PVar "m") (PVar "isRec") (PVar "pat") (PVar "e1") (PVar "e2"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "stampLet") (EVar "env")) (EVar "m")) (EVar "isRec")) (EVar "pat")) (EVar "e1")) (EVar "e2")))
(DFunDef false "stampExpr" ((PVar "env") (PCon "ELetGroup" (PVar "binds") (PVar "body"))) (EApp (EApp (EApp (EVar "stampLetGroup") (EVar "env")) (EVar "binds")) (EVar "body")))
(DFunDef false "stampExpr" ((PVar "env") (PCon "EMatch" (PVar "e0") (PVar "arms"))) (EApp (EApp (EVar "EMatch") (EApp (EApp (EVar "stampExpr") (EVar "env")) (EVar "e0"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "stampArm") (EVar "env"))) (EVar "arms"))))
(DFunDef false "stampExpr" ((PVar "env") (PCon "EIf" (PVar "c") (PVar "t") (PVar "el"))) (EApp (EApp (EApp (EVar "EIf") (EApp (EApp (EVar "stampExpr") (EVar "env")) (EVar "c"))) (EApp (EApp (EVar "stampExpr") (EVar "env")) (EVar "t"))) (EApp (EApp (EVar "stampExpr") (EVar "env")) (EVar "el"))))
(DFunDef false "stampExpr" ((PVar "env") (PCon "EBinOp" (PVar "op") (PVar "a") (PVar "b") (PVar "r"))) (EApp (EApp (EApp (EApp (EVar "EBinOp") (EVar "op")) (EApp (EApp (EVar "stampExpr") (EVar "env")) (EVar "a"))) (EApp (EApp (EVar "stampExpr") (EVar "env")) (EVar "b"))) (EVar "r")))
(DFunDef false "stampExpr" ((PVar "env") (PCon "EUnOp" (PVar "op") (PVar "a") (PVar "r"))) (EApp (EApp (EApp (EVar "EUnOp") (EVar "op")) (EApp (EApp (EVar "stampExpr") (EVar "env")) (EVar "a"))) (EVar "r")))
(DFunDef false "stampExpr" ((PVar "env") (PCon "EInfix" (PVar "op") (PVar "a") (PVar "b"))) (EApp (EApp (EApp (EVar "EInfix") (EVar "op")) (EApp (EApp (EVar "stampExpr") (EVar "env")) (EVar "a"))) (EApp (EApp (EVar "stampExpr") (EVar "env")) (EVar "b"))))
(DFunDef false "stampExpr" ((PVar "env") (PCon "EFieldAccess" (PVar "e0") (PVar "f") (PVar "r"))) (EApp (EApp (EApp (EVar "EFieldAccess") (EApp (EApp (EVar "stampExpr") (EVar "env")) (EVar "e0"))) (EVar "f")) (EVar "r")))
(DFunDef false "stampExpr" ((PVar "env") (PCon "ETuple" (PVar "es"))) (EApp (EVar "ETuple") (EApp (EApp (EMethodRef "map") (EApp (EVar "stampExpr") (EVar "env"))) (EVar "es"))))
(DFunDef false "stampExpr" ((PVar "env") (PCon "EListLit" (PVar "es"))) (EApp (EVar "EListLit") (EApp (EApp (EMethodRef "map") (EApp (EVar "stampExpr") (EVar "env"))) (EVar "es"))))
(DFunDef false "stampExpr" ((PVar "env") (PCon "EArrayLit" (PVar "es"))) (EApp (EVar "EArrayLit") (EApp (EApp (EMethodRef "map") (EApp (EVar "stampExpr") (EVar "env"))) (EVar "es"))))
(DFunDef false "stampExpr" ((PVar "env") (PCon "ERangeList" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EVar "ERangeList") (EApp (EApp (EVar "stampExpr") (EVar "env")) (EVar "lo"))) (EApp (EApp (EVar "stampExpr") (EVar "env")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "stampExpr" ((PVar "env") (PCon "ERangeArray" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EVar "ERangeArray") (EApp (EApp (EVar "stampExpr") (EVar "env")) (EVar "lo"))) (EApp (EApp (EVar "stampExpr") (EVar "env")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "stampExpr" ((PVar "env") (PCon "ESlice" (PVar "e0") (PVar "lo") (PVar "hi") (PVar "incl") (PVar "r"))) (EApp (EApp (EApp (EApp (EApp (EVar "ESlice") (EApp (EApp (EVar "stampExpr") (EVar "env")) (EVar "e0"))) (EApp (EApp (EVar "stampExpr") (EVar "env")) (EVar "lo"))) (EApp (EApp (EVar "stampExpr") (EVar "env")) (EVar "hi"))) (EVar "incl")) (EVar "r")))
(DFunDef false "stampExpr" ((PVar "env") (PCon "EIndex" (PVar "e0") (PVar "i") (PVar "r"))) (EApp (EApp (EApp (EVar "EIndex") (EApp (EApp (EVar "stampExpr") (EVar "env")) (EVar "e0"))) (EApp (EApp (EVar "stampExpr") (EVar "env")) (EVar "i"))) (EVar "r")))
(DFunDef false "stampExpr" ((PVar "env") (PCon "EAnnot" (PVar "e0") (PVar "t"))) (EApp (EApp (EVar "EAnnot") (EApp (EApp (EVar "stampExpr") (EVar "env")) (EVar "e0"))) (EVar "t")))
(DFunDef false "stampExpr" ((PVar "env") (PCon "EHeadAnnot" (PVar "e0") (PVar "t"))) (EApp (EApp (EVar "EHeadAnnot") (EApp (EApp (EVar "stampExpr") (EVar "env")) (EVar "e0"))) (EVar "t")))
(DFunDef false "stampExpr" ((PVar "env") (PCon "EBlock" (PVar "stmts"))) (EApp (EVar "EBlock") (EApp (EApp (EVar "stampStmts") (EVar "env")) (EVar "stmts"))))
(DFunDef false "stampExpr" ((PVar "env") (PCon "EDo" (PVar "d") (PVar "stmts"))) (EApp (EApp (EVar "EDo") (EVar "d")) (EApp (EApp (EVar "stampStmts") (EVar "env")) (EVar "stmts"))))
(DFunDef false "stampExpr" ((PVar "env") (PCon "EStringInterp" (PVar "parts"))) (EApp (EVar "EStringInterp") (EApp (EApp (EMethodRef "map") (EApp (EVar "stampInterp") (EVar "env"))) (EVar "parts"))))
(DFunDef false "stampExpr" ((PVar "env") (PCon "EGuards" (PVar "arms"))) (EApp (EVar "EGuards") (EApp (EApp (EMethodRef "map") (EApp (EVar "stampGuardArm") (EVar "env"))) (EVar "arms"))))
(DFunDef false "stampExpr" ((PVar "env") (PCon "ERecordCreate" (PVar "name") (PVar "fs"))) (EApp (EApp (EVar "ERecordCreate") (EVar "name")) (EApp (EApp (EMethodRef "map") (EApp (EVar "stampFieldAssign") (EVar "env"))) (EVar "fs"))))
(DFunDef false "stampExpr" ((PVar "env") (PCon "ERecordUpdate" (PVar "e0") (PVar "fs") (PVar "r"))) (EApp (EApp (EApp (EVar "ERecordUpdate") (EApp (EApp (EVar "stampExpr") (EVar "env")) (EVar "e0"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "stampFieldAssign") (EVar "env"))) (EVar "fs"))) (EVar "r")))
(DFunDef false "stampExpr" ((PVar "env") (PCon "EVariantUpdate" (PVar "con") (PVar "e0") (PVar "fs"))) (EApp (EApp (EApp (EVar "EVariantUpdate") (EVar "con")) (EApp (EApp (EVar "stampExpr") (EVar "env")) (EVar "e0"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "stampFieldAssign") (EVar "env"))) (EVar "fs"))))
(DFunDef false "stampExpr" ((PVar "env") (PCon "EMapLit" (PVar "n") (PVar "kvs"))) (EApp (EApp (EVar "EMapLit") (EVar "n")) (EApp (EApp (EMethodRef "map") (EApp (EVar "stampKv") (EVar "env"))) (EVar "kvs"))))
(DFunDef false "stampExpr" ((PVar "env") (PCon "ESetLit" (PVar "n") (PVar "es"))) (EApp (EApp (EVar "ESetLit") (EVar "n")) (EApp (EApp (EMethodRef "map") (EApp (EVar "stampExpr") (EVar "env"))) (EVar "es"))))
(DFunDef false "stampExpr" ((PVar "env") (PCon "EAsPat" (PVar "x") (PVar "e0"))) (EApp (EApp (EVar "EAsPat") (EVar "x")) (EApp (EApp (EVar "stampExpr") (EVar "env")) (EVar "e0"))))
(DFunDef false "stampExpr" ((PVar "env") (PCon "ESection" (PVar "s"))) (EApp (EVar "ESection") (EApp (EApp (EVar "stampSection") (EVar "env")) (EVar "s"))))
(DFunDef false "stampExpr" ((PVar "env") (PCon "ELoc" (PVar "l") (PVar "e"))) (EApp (EApp (EVar "ELoc") (EVar "l")) (EApp (EApp (EVar "stampExpr") (EVar "env")) (EVar "e"))))
(DFunDef false "stampExpr" ((PVar "env") (PCon "EDoOrigin" (PVar "l") (PVar "e"))) (EApp (EApp (EVar "EDoOrigin") (EVar "l")) (EApp (EApp (EVar "stampExpr") (EVar "env")) (EVar "e"))))
(DTypeSig false "stampLet" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyFun (TyCon "Pat") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Expr"))))))))
(DFunDef false "stampLet" ((PVar "env") (PVar "m") (PCon "True") (PCon "PVar" (PVar "f") (PVar "fl")) (PVar "e1") (PVar "e2")) (EBlock (DoLet false false (PVar "inner") (EApp (EApp (EVar "insertZero") (EListLit (EVar "f"))) (EVar "env"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "ELet") (EVar "m")) (EVar "True")) (EApp (EApp (EVar "PVar") (EVar "f")) (EVar "fl"))) (EApp (EApp (EVar "stampExpr") (EVar "inner")) (EVar "e1"))) (EApp (EApp (EVar "stampExpr") (EVar "inner")) (EVar "e2"))))))
(DFunDef false "stampLet" ((PVar "env") (PVar "m") (PVar "isRec") (PVar "pat") (PVar "e1") (PVar "e2")) (EApp (EApp (EApp (EApp (EApp (EVar "ELet") (EVar "m")) (EVar "isRec")) (EVar "pat")) (EApp (EApp (EVar "stampExpr") (EVar "env")) (EVar "e1"))) (EApp (EApp (EVar "stampExpr") (EApp (EApp (EVar "insertZero") (EApp (EVar "patBindings") (EVar "pat"))) (EVar "env"))) (EVar "e2"))))
(DTypeSig false "stampLetGroup" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyFun (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "stampLetGroup" ((PVar "env") (PVar "binds") (PVar "body")) (EBlock (DoLet false false (PVar "groupScope") (EApp (EApp (EVar "insertZero") (EApp (EApp (EMethodRef "map") (EVar "letBindName")) (EVar "binds"))) (EVar "env"))) (DoExpr (EApp (EApp (EVar "ELetGroup") (EApp (EApp (EMethodRef "map") (EApp (EVar "stampLetBind") (EVar "groupScope"))) (EVar "binds"))) (EApp (EApp (EVar "stampExpr") (EVar "groupScope")) (EVar "body"))))))
(DTypeSig false "stampLetBind" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "LetBind") (TyCon "LetBind"))))
(DFunDef false "stampLetBind" ((PVar "groupScope") (PCon "LetBind" (PVar "name") (PVar "clauses"))) (EApp (EApp (EVar "LetBind") (EVar "name")) (EApp (EApp (EMethodRef "map") (EApp (EVar "stampClause") (EVar "groupScope"))) (EVar "clauses"))))
(DTypeSig false "stampClause" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "FunClause") (TyCon "FunClause"))))
(DFunDef false "stampClause" ((PVar "groupScope") (PCon "FunClause" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "FunClause") (EVar "pats")) (EApp (EApp (EVar "stampExpr") (EApp (EApp (EVar "insertParams") (EVar "pats")) (EVar "groupScope"))) (EVar "body"))))
(DTypeSig false "stampArm" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "Arm") (TyCon "Arm"))))
(DFunDef false "stampArm" ((PVar "env") (PCon "Arm" (PVar "pat") (PVar "gs") (PVar "body"))) (EBlock (DoLet false false (PVar "scope0") (EApp (EApp (EVar "insertZero") (EApp (EVar "patBindings") (EVar "pat"))) (EVar "env"))) (DoLet false false (PTuple (PVar "gs2") (PVar "scope2")) (EApp (EApp (EVar "stampGuards") (EVar "scope0")) (EVar "gs"))) (DoExpr (EApp (EApp (EApp (EVar "Arm") (EVar "pat")) (EVar "gs2")) (EApp (EApp (EVar "stampExpr") (EVar "scope2")) (EVar "body"))))))
(DTypeSig false "stampGuards" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Guard")) (TyTuple (TyApp (TyCon "List") (TyCon "Guard")) (TyApp (TyCon "OrdMap") (TyCon "Int"))))))
(DFunDef false "stampGuards" ((PVar "scope") (PList)) (ETuple (EListLit) (EVar "scope")))
(DFunDef false "stampGuards" ((PVar "scope") (PCons (PCon "GBool" (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "rest2") (PVar "scope2")) (EApp (EApp (EVar "stampGuards") (EVar "scope")) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EApp (EVar "GBool") (EApp (EApp (EVar "stampExpr") (EVar "scope")) (EVar "e"))) (EVar "rest2")) (EVar "scope2")))))
(DFunDef false "stampGuards" ((PVar "scope") (PCons (PCon "GBind" (PVar "p") (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false (PVar "e2") (EApp (EApp (EVar "stampExpr") (EVar "scope")) (EVar "e"))) (DoLet false false (PTuple (PVar "rest2") (PVar "scope2")) (EApp (EApp (EVar "stampGuards") (EApp (EApp (EVar "insertZero") (EApp (EVar "patBindings") (EVar "p"))) (EVar "scope"))) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EApp (EApp (EVar "GBind") (EVar "p")) (EVar "e2")) (EVar "rest2")) (EVar "scope2")))))
(DTypeSig false "stampGuardArm" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "GuardArm") (TyCon "GuardArm"))))
(DFunDef false "stampGuardArm" ((PVar "env") (PCon "GuardArm" (PVar "gs") (PVar "body"))) (EBlock (DoLet false false (PTuple (PVar "gs2") (PVar "scope2")) (EApp (EApp (EVar "stampGuards") (EVar "env")) (EVar "gs"))) (DoExpr (EApp (EApp (EVar "GuardArm") (EVar "gs2")) (EApp (EApp (EVar "stampExpr") (EVar "scope2")) (EVar "body"))))))
(DTypeSig false "stampStmts" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyApp (TyCon "List") (TyCon "DoStmt")))))
(DFunDef false "stampStmts" (PWild (PList)) (EListLit))
(DFunDef false "stampStmts" ((PVar "env") (PCons (PCon "DoExpr" (PVar "e")) (PVar "rest"))) (EBinOp "::" (EApp (EVar "DoExpr") (EApp (EApp (EVar "stampExpr") (EVar "env")) (EVar "e"))) (EApp (EApp (EVar "stampStmts") (EVar "env")) (EVar "rest"))))
(DFunDef false "stampStmts" ((PVar "env") (PCons (PCon "DoLet" (PVar "m") (PVar "r") (PVar "p") (PVar "e")) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "DoLet") (EVar "m")) (EVar "r")) (EVar "p")) (EApp (EApp (EVar "stampExpr") (EVar "env")) (EVar "e"))) (EApp (EApp (EVar "stampStmts") (EApp (EApp (EVar "insertZero") (EApp (EVar "patBindings") (EVar "p"))) (EVar "env"))) (EVar "rest"))))
(DFunDef false "stampStmts" ((PVar "env") (PCons (PCon "DoBind" (PVar "p") (PVar "e")) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EVar "DoBind") (EVar "p")) (EApp (EApp (EVar "stampExpr") (EVar "env")) (EVar "e"))) (EApp (EApp (EVar "stampStmts") (EApp (EApp (EVar "insertZero") (EApp (EVar "patBindings") (EVar "p"))) (EVar "env"))) (EVar "rest"))))
(DFunDef false "stampStmts" ((PVar "env") (PCons (PCon "DoAssign" (PVar "x") (PVar "e")) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EVar "DoAssign") (EVar "x")) (EApp (EApp (EVar "stampExpr") (EVar "env")) (EVar "e"))) (EApp (EApp (EVar "stampStmts") (EApp (EApp (EVar "insertZero") (EListLit (EVar "x"))) (EVar "env"))) (EVar "rest"))))
(DFunDef false "stampStmts" ((PVar "env") (PCons (PCon "DoFieldAssign" (PVar "x") (PVar "fs") (PVar "e")) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EApp (EVar "DoFieldAssign") (EVar "x")) (EVar "fs")) (EApp (EApp (EVar "stampExpr") (EVar "env")) (EVar "e"))) (EApp (EApp (EVar "stampStmts") (EVar "env")) (EVar "rest"))))
(DTypeSig false "stampInterp" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "InterpPart") (TyCon "InterpPart"))))
(DFunDef false "stampInterp" (PWild (PCon "InterpStr" (PVar "s"))) (EApp (EVar "InterpStr") (EVar "s")))
(DFunDef false "stampInterp" ((PVar "env") (PCon "InterpExpr" (PVar "e"))) (EApp (EVar "InterpExpr") (EApp (EApp (EVar "stampExpr") (EVar "env")) (EVar "e"))))
(DTypeSig false "stampFieldAssign" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "FieldAssign") (TyCon "FieldAssign"))))
(DFunDef false "stampFieldAssign" ((PVar "env") (PCon "FieldAssign" (PVar "n") (PVar "e"))) (EApp (EApp (EVar "FieldAssign") (EVar "n")) (EApp (EApp (EVar "stampExpr") (EVar "env")) (EVar "e"))))
(DTypeSig false "stampKv" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyTuple (TyCon "Expr") (TyCon "Expr")) (TyTuple (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "stampKv" ((PVar "env") (PTuple (PVar "k") (PVar "v"))) (ETuple (EApp (EApp (EVar "stampExpr") (EVar "env")) (EVar "k")) (EApp (EApp (EVar "stampExpr") (EVar "env")) (EVar "v"))))
(DTypeSig false "stampSection" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "Section") (TyCon "Section"))))
(DFunDef false "stampSection" (PWild (PCon "SecBare" (PVar "op"))) (EApp (EVar "SecBare") (EVar "op")))
(DFunDef false "stampSection" ((PVar "env") (PCon "SecRight" (PVar "op") (PVar "e"))) (EApp (EApp (EVar "SecRight") (EVar "op")) (EApp (EApp (EVar "stampExpr") (EVar "env")) (EVar "e"))))
(DFunDef false "stampSection" ((PVar "env") (PCon "SecLeft" (PVar "e") (PVar "op"))) (EApp (EApp (EVar "SecLeft") (EApp (EApp (EVar "stampExpr") (EVar "env")) (EVar "e"))) (EVar "op")))
(DTypeSig false "stampDecl" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "Decl") (TyCon "Decl"))))
(DFunDef false "stampDecl" ((PVar "top") (PCon "DFunDef" (PVar "p") (PVar "n") (PVar "pats") (PVar "body"))) (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "p")) (EVar "n")) (EVar "pats")) (EApp (EApp (EVar "stampExpr") (EApp (EApp (EVar "insertParams") (EVar "pats")) (EVar "top"))) (EVar "body"))))
(DFunDef false "stampDecl" ((PVar "top") (PCon "DProp" (PVar "p") (PVar "n") (PVar "params") (PVar "body"))) (EApp (EApp (EApp (EApp (EVar "DProp") (EVar "p")) (EVar "n")) (EVar "params")) (EApp (EApp (EVar "stampExpr") (EApp (EApp (EVar "insertZero") (EApp (EApp (EMethodRef "map") (EVar "propParamName")) (EVar "params"))) (EVar "top"))) (EVar "body"))))
(DFunDef false "stampDecl" ((PVar "top") (PCon "DTest" (PVar "p") (PVar "n") (PVar "body"))) (EApp (EApp (EApp (EVar "DTest") (EVar "p")) (EVar "n")) (EApp (EApp (EVar "stampExpr") (EVar "top")) (EVar "body"))))
(DFunDef false "stampDecl" ((PVar "top") (PCon "DBench" (PVar "p") (PVar "n") (PVar "body"))) (EApp (EApp (EApp (EVar "DBench") (EVar "p")) (EVar "n")) (EApp (EApp (EVar "stampExpr") (EVar "top")) (EVar "body"))))
(DFunDef false "stampDecl" ((PVar "top") (PCon "DLetGroup" (PVar "p") (PVar "binds"))) (EApp (EApp (EVar "DLetGroup") (EVar "p")) (EApp (EApp (EMethodRef "map") (EApp (EVar "stampLetBind") (EVar "top"))) (EVar "binds"))))
(DFunDef false "stampDecl" ((PVar "top") (PAs "d" (PRec "DInterface" ((rf "methods" None)) true))) (EVariantUpdate "DInterface" (EVar "d") ((fa "methods" (EApp (EApp (EMethodRef "map") (EApp (EVar "stampIfaceMethod") (EVar "top"))) (EVar "methods"))))))
(DFunDef false "stampDecl" ((PVar "top") (PAs "d" (PRec "DImpl" ((rf "methods" None)) true))) (EVariantUpdate "DImpl" (EVar "d") ((fa "methods" (EApp (EApp (EMethodRef "map") (EApp (EVar "stampImplMethod") (EVar "top"))) (EVar "methods"))))))
(DFunDef false "stampDecl" ((PVar "top") (PCon "DAttrib" (PVar "attrs") (PVar "inner"))) (EApp (EApp (EVar "DAttrib") (EVar "attrs")) (EApp (EApp (EVar "stampDecl") (EVar "top")) (EVar "inner"))))
(DFunDef false "stampDecl" (PWild (PVar "d")) (EVar "d"))
(DTypeSig false "stampIfaceMethod" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "IfaceMethod") (TyCon "IfaceMethod"))))
(DFunDef false "stampIfaceMethod" (PWild (PCon "IfaceMethod" (PVar "nm") (PVar "ty") (PCon "None") (PVar "mloc"))) (EApp (EApp (EApp (EApp (EVar "IfaceMethod") (EVar "nm")) (EVar "ty")) (EVar "None")) (EVar "mloc")))
(DFunDef false "stampIfaceMethod" ((PVar "top") (PCon "IfaceMethod" (PVar "nm") (PVar "ty") (PCon "Some" (PCon "MethodDefault" (PVar "pats") (PVar "body"))) (PVar "mloc"))) (EApp (EApp (EApp (EApp (EVar "IfaceMethod") (EVar "nm")) (EVar "ty")) (EApp (EVar "Some") (EApp (EApp (EVar "MethodDefault") (EVar "pats")) (EApp (EApp (EVar "stampExpr") (EApp (EApp (EVar "insertParams") (EVar "pats")) (EVar "top"))) (EVar "body"))))) (EVar "mloc")))
(DTypeSig false "stampImplMethod" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "ImplMethod") (TyCon "ImplMethod"))))
(DFunDef false "stampImplMethod" ((PVar "top") (PCon "ImplMethod" (PVar "nm") (PVar "pats") (PVar "body"))) (EApp (EApp (EApp (EVar "ImplMethod") (EVar "nm")) (EVar "pats")) (EApp (EApp (EVar "stampExpr") (EApp (EApp (EVar "insertParams") (EVar "pats")) (EVar "top"))) (EVar "body"))))
(DTypeSig true "stampBindingIds" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))))))
(DFunDef false "stampBindingIds" ((PVar "decls")) (EBlock (DoLet false false (PVar "top") (EApp (EApp (EVar "numberFrom") (ELit (LInt 1))) (EApp (EVar "dedup") (EApp (EVar "topBinderNames") (EVar "decls"))))) (DoExpr (ETuple (EApp (EApp (EMethodRef "map") (EApp (EVar "stampDecl") (EApp (EApp (EVar "omFromPairs") (EVar "top")) (EVar "omEmpty")))) (EVar "decls")) (EVar "top")))))
(DTypeSig false "tyOriginScope" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "OrdMap") (TyCon "TyConOrigin")))))))
(DFunDef false "tyOriginScope" ((PVar "coreTypes") (PVar "known") (PVar "mid") (PVar "prog")) (EBlock (DoLet false false (PVar "builtinLayer") (EVar "builtinTyOrigins")) (DoLet false false (PVar "preludeLayer") (EApp (EApp (EMethodRef "map") (EVar "importedTyOrigin")) (EVar "coreTypes"))) (DoLet false false (PVar "importLayer") (EApp (EApp (EMethodRef "map") (EVar "importedTyOrigin")) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "importedTypeOrigins") (EVar "known"))) (EApp (EVar "usePathsOf") (EVar "prog"))))) (DoLet false false (PVar "ownLayer") (EBinOp "++" (EApp (EApp (EMethodRef "map") (EApp (EVar "ownTyOrigin") (EVar "mid"))) (EApp (EVar "dataRecordNames") (EVar "prog"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "ownIfaceOrigin") (EVar "mid"))) (EApp (EVar "interfaceNamesOf") (EVar "prog"))))) (DoExpr (EApp (EApp (EVar "omFromPairs") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EVar "builtinLayer") (EVar "preludeLayer")) (EVar "importLayer")) (EVar "ownLayer"))) (EVar "omEmpty")))))
(DTypeSig false "ownTyOrigin" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyTuple (TyCon "String") (TyCon "TyConOrigin")))))
(DFunDef false "ownTyOrigin" ((PVar "mid") (PVar "n")) (ETuple (EVar "n") (EApp (EVar "OriginModule") (EVar "mid"))))
(DTypeSig false "importedTyOrigin" (TyFun (TyTuple (TyCon "String") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "TyConOrigin"))))
(DFunDef false "importedTyOrigin" ((PTuple (PVar "n") (PVar "definer"))) (ETuple (EVar "n") (EApp (EVar "OriginModule") (EVar "definer"))))
(DTypeSig false "builtinTyOrigins" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TyConOrigin"))))
(DFunDef false "builtinTyOrigins" () (EApp (EApp (EMethodRef "map") (EVar "builtinTyOrigin")) (EBinOp "++" (EVar "primitiveTypes") (EVar "tupleCtorTyNames"))))
(DTypeSig false "builtinTyOrigin" (TyFun (TyCon "String") (TyTuple (TyCon "String") (TyCon "TyConOrigin"))))
(DFunDef false "builtinTyOrigin" ((PVar "n")) (ETuple (EVar "n") (EVar "OriginBuiltin")))
(DTypeSig false "typeOriginExports" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "typeOriginExports" ((PVar "known") (PVar "mid") (PVar "prog")) (EBinOp "++" (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EApp (EVar "importedTypeOrigins") (EVar "known"))) (EApp (EVar "pubUsePaths") (EVar "prog"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "typeDeclaredIn") (EVar "mid"))) (EApp (EVar "expTypesDirect") (EVar "prog")))) (EApp (EApp (EMethodRef "map") (EApp (EVar "ifaceDeclaredIn") (EVar "mid"))) (EApp (EVar "expInterfacesDirect") (EVar "prog")))))
(DTypeSig false "typeDeclaredIn" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "typeDeclaredIn" ((PVar "mid") (PVar "n")) (ETuple (EVar "n") (EVar "mid")))
(DTypeSig false "importedTypeOrigins" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyFun (TyCon "UsePath") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "importedTypeOrigins" ((PVar "known") (PVar "path")) (EIf (EBinOp "==" (EApp (EVar "useModId") (EVar "path")) (ELit (LString "core"))) (EListLit) (EMatch (EApp (EApp (EVar "omLookup") (EApp (EVar "useModId") (EVar "path"))) (EVar "known")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "src")) () (EApp (EApp (EVar "importedTypeOriginsFrom") (EVar "path")) (EVar "src"))))))
(DTypeSig false "importedTypeOriginsFrom" (TyFun (TyCon "UsePath") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "importedTypeOriginsFrom" ((PCon "UseName" (PVar "ns")) (PVar "src")) (EIf (EBinOp ">" (EApp (EVar "listLen") (EVar "ns")) (ELit (LInt 1))) (EApp (EApp (EVar "keepTypeOrigins") (EVar "src")) (EListLit (ETuple (EApp (EVar "lastOf") (EVar "ns")) (EApp (EVar "lastOf") (EVar "ns"))))) (EListLit)))
(DFunDef false "importedTypeOriginsFrom" ((PCon "UseGroup" PWild (PVar "members")) (PVar "src")) (EApp (EApp (EVar "keepTypeOrigins") (EVar "src")) (EApp (EApp (EMethodRef "map") (EVar "useMemberBinding")) (EVar "members"))))
(DFunDef false "importedTypeOriginsFrom" ((PCon "UseWild" PWild) (PVar "src")) (EVar "src"))
(DFunDef false "importedTypeOriginsFrom" ((PCon "UseAlias" PWild PWild) PWild) (EListLit))
(DTypeSig false "useMemberBinding" (TyFun (TyCon "UseMember") (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "useMemberBinding" ((PAs "m" (PCon "UseMember" (PVar "name") PWild PWild PWild))) (ETuple (EVar "name") (EApp (EVar "useMemberLocal") (EVar "m"))))
(DTypeSig false "keepTypeOrigins" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "keepTypeOrigins" ((PVar "src") (PVar "bindings")) (EBlock (DoLet false false (PVar "definers") (EApp (EApp (EVar "omFromPairs") (EVar "src")) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EDictApp "flatMap") (EApp (EVar "bindTypeOrigin") (EVar "definers"))) (EVar "bindings")))))
(DTypeSig false "bindTypeOrigin" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "bindTypeOrigin" ((PVar "definers") (PTuple (PVar "origin") (PVar "local"))) (EBinOp "++" (EApp (EApp (EApp (EVar "bindOneOrigin") (EVar "definers")) (EVar "origin")) (EVar "local")) (EApp (EApp (EApp (EVar "bindOneOrigin") (EVar "definers")) (EApp (EVar "ifaceKey") (EVar "origin"))) (EApp (EVar "ifaceKey") (EVar "local")))))
(DTypeSig false "bindOneOrigin" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "bindOneOrigin" ((PVar "definers") (PVar "key") (PVar "local")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "key")) (EVar "definers")) (arm (PCon "Some" (PVar "definer")) () (EListLit (ETuple (EVar "local") (EVar "definer")))) (arm (PCon "None") () (EListLit))))
(DTypeSig true "stampTyOrigins" (TyFun (TyApp (TyCon "OrdMap") (TyCon "TyConOrigin")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "stampTyOrigins" ((PVar "scope") (PVar "decls")) (EApp (EApp (EMethodRef "map") (EApp (EVar "stampDeclTyOrigins") (EVar "scope"))) (EVar "decls")))
(DTypeSig false "stampDeclTyOrigins" (TyFun (TyApp (TyCon "OrdMap") (TyCon "TyConOrigin")) (TyFun (TyCon "Decl") (TyCon "Decl"))))
(DFunDef false "stampDeclTyOrigins" ((PVar "scope") (PVar "d")) (EApp (EApp (EApp (EVar "mapOriginsInDecl") (EApp (EVar "stampTyHead") (EVar "scope"))) (EApp (EVar "fillIfaceOccOrigin") (EVar "scope"))) (EVar "d")))
(DTypeSig false "stampTyHead" (TyFun (TyApp (TyCon "OrdMap") (TyCon "TyConOrigin")) (TyFun (TyCon "Ty") (TyTuple (TyCon "Ty") (TyCon "Bool")))))
(DFunDef false "stampTyHead" ((PVar "scope") (PAs "t" (PRec "TyCon" ((rf "tyConName" (PVar "n")) (rf "tyConOrigin" (PVar "o"))) false))) (EMatch (EVar "o") (arm (PCon "OriginUnresolved") () (EApp (EApp (EVar "stampHeadWith") (EVar "t")) (EApp (EApp (EVar "originOfTyName") (EVar "scope")) (EVar "n")))) (arm (PCon "OriginBuiltin") () (ETuple (EVar "t") (EVar "False"))) (arm (PCon "OriginModule" PWild) () (ETuple (EVar "t") (EVar "False")))))
(DFunDef false "stampTyHead" (PWild (PVar "t")) (ETuple (EVar "t") (EVar "False")))
(DTypeSig false "originOfTyName" (TyFun (TyApp (TyCon "OrdMap") (TyCon "TyConOrigin")) (TyFun (TyCon "String") (TyCon "TyConOrigin"))))
(DFunDef false "originOfTyName" ((PVar "scope") (PVar "n")) (EApp (EApp (EVar "optionOr") (EVar "OriginUnresolved")) (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "scope"))))
(DTypeSig false "stampHeadWith" (TyFun (TyCon "Ty") (TyFun (TyCon "TyConOrigin") (TyTuple (TyCon "Ty") (TyCon "Bool")))))
(DFunDef false "stampHeadWith" ((PVar "t") (PCon "OriginUnresolved")) (ETuple (EVar "t") (EVar "False")))
(DFunDef false "stampHeadWith" ((PVar "t") (PVar "o")) (ETuple (EVariantUpdate "TyCon" (EVar "t") ((fa "tyConOrigin" (EVar "o")))) (EVar "True")))
(DTypeSig true "stampDeclOrigins" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "stampDeclOrigins" ((PVar "mid") (PVar "decls")) (EApp (EApp (EMethodRef "map") (EApp (EVar "stampDeclOrigin") (EVar "mid"))) (EVar "decls")))
(DTypeSig false "stampDeclOrigin" (TyFun (TyCon "String") (TyFun (TyCon "Decl") (TyCon "Decl"))))
(DFunDef false "stampDeclOrigin" ((PVar "mid") (PAs "d" (PRec "DData" ((rf "dataOrigin" (PVar "o"))) false))) (EVariantUpdate "DData" (EVar "d") ((fa "dataOrigin" (EApp (EApp (EVar "fillDeclOrigin") (EVar "mid")) (EVar "o"))))))
(DFunDef false "stampDeclOrigin" ((PVar "mid") (PAs "d" (PRec "DNewtype" ((rf "newtypeOrigin" (PVar "o"))) false))) (EVariantUpdate "DNewtype" (EVar "d") ((fa "newtypeOrigin" (EApp (EApp (EVar "fillDeclOrigin") (EVar "mid")) (EVar "o"))))))
(DFunDef false "stampDeclOrigin" ((PVar "mid") (PAs "d" (PRec "DTypeAlias" ((rf "tyAliasOrigin" (PVar "o"))) false))) (EVariantUpdate "DTypeAlias" (EVar "d") ((fa "tyAliasOrigin" (EApp (EApp (EVar "fillDeclOrigin") (EVar "mid")) (EVar "o"))))))
(DFunDef false "stampDeclOrigin" ((PVar "mid") (PAs "d" (PRec "DInterface" ((rf "ifaceOrigin" (PVar "o"))) false))) (EVariantUpdate "DInterface" (EVar "d") ((fa "ifaceOrigin" (EApp (EApp (EVar "fillDeclOrigin") (EVar "mid")) (EVar "o"))))))
(DFunDef false "stampDeclOrigin" ((PVar "mid") (PCon "DAttrib" (PVar "attrs") (PVar "d"))) (EApp (EApp (EVar "DAttrib") (EVar "attrs")) (EApp (EApp (EVar "stampDeclOrigin") (EVar "mid")) (EVar "d"))))
(DFunDef false "stampDeclOrigin" (PWild (PVar "d")) (EVar "d"))
(DTypeSig false "fillDeclOrigin" (TyFun (TyCon "String") (TyFun (TyCon "TyConOrigin") (TyCon "TyConOrigin"))))
(DFunDef false "fillDeclOrigin" ((PVar "mid") (PCon "OriginUnresolved")) (EIf (EBinOp "==" (EVar "mid") (ELit (LString ""))) (EVar "OriginUnresolved") (EApp (EVar "OriginModule") (EVar "mid"))))
(DFunDef false "fillDeclOrigin" (PWild (PCon "OriginBuiltin")) (EVar "OriginBuiltin"))
(DFunDef false "fillDeclOrigin" (PWild (PAs "o" (PCon "OriginModule" PWild))) (EVar "o"))
(DTypeSig true "mapOriginsInDecl" (TyFun (TyFun (TyCon "Ty") (TyTuple (TyCon "Ty") (TyCon "Bool"))) (TyFun (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "TyConOrigin") (TyCon "TyConOrigin")))) (TyFun (TyCon "Decl") (TyCon "Decl")))))
(DFunDef false "mapOriginsInDecl" ((PVar "fTy") (PVar "fIface") (PVar "d")) (EApp (EApp (EVar "mapIfaceOccDeclLocal") (EVar "fIface")) (EApp (EVar "fst") (EApp (EApp (EVar "mapTyInDecl") (EApp (EApp (EVar "mapOriginsInTy") (EVar "fTy")) (EVar "fIface"))) (EVar "d")))))
(DTypeSig false "mapOriginsInTy" (TyFun (TyFun (TyCon "Ty") (TyTuple (TyCon "Ty") (TyCon "Bool"))) (TyFun (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "TyConOrigin") (TyCon "TyConOrigin")))) (TyFun (TyCon "Ty") (TyTuple (TyCon "Ty") (TyCon "Bool"))))))
(DFunDef false "mapOriginsInTy" ((PVar "fTy") (PVar "fIface") (PCon "TyConstrained" (PVar "cs") (PVar "t"))) (EApp (EVar "fTy") (EApp (EApp (EVar "TyConstrained") (EApp (EApp (EMethodRef "map") (EApp (EVar "mapConstraintOcc") (EVar "fIface"))) (EVar "cs"))) (EVar "t"))))
(DFunDef false "mapOriginsInTy" ((PVar "fTy") PWild (PVar "t")) (EApp (EVar "fTy") (EVar "t")))
(DTypeSig false "mapConstraintOcc" (TyFun (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "TyConOrigin") (TyCon "TyConOrigin")))) (TyFun (TyCon "Constraint") (TyCon "Constraint"))))
(DFunDef false "mapConstraintOcc" ((PVar "f") (PAs "c" (PRec "Constraint" ((rf "constraintHead" (PVar "n")) (rf "constraintOrigin" (PVar "o"))) false))) (EVariantUpdate "Constraint" (EVar "c") ((fa "constraintOrigin" (EApp (EApp (EApp (EVar "f") (ELit (LString "constraintOrigin"))) (EVar "n")) (EVar "o"))))))
(DTypeSig false "mapSuperOcc" (TyFun (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "TyConOrigin") (TyCon "TyConOrigin")))) (TyFun (TyCon "Super") (TyCon "Super"))))
(DFunDef false "mapSuperOcc" ((PVar "f") (PAs "s" (PRec "Super" ((rf "superHead" (PVar "n")) (rf "superOrigin" (PVar "o"))) false))) (EVariantUpdate "Super" (EVar "s") ((fa "superOrigin" (EApp (EApp (EApp (EVar "f") (ELit (LString "superOrigin"))) (EVar "n")) (EVar "o"))))))
(DTypeSig false "mapRequireOcc" (TyFun (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "TyConOrigin") (TyCon "TyConOrigin")))) (TyFun (TyCon "Require") (TyCon "Require"))))
(DFunDef false "mapRequireOcc" ((PVar "f") (PAs "r" (PRec "Require" ((rf "requireHead" (PVar "n")) (rf "requireOrigin" (PVar "o"))) false))) (EVariantUpdate "Require" (EVar "r") ((fa "requireOrigin" (EApp (EApp (EApp (EVar "f") (ELit (LString "requireOrigin"))) (EVar "n")) (EVar "o"))))))
(DTypeSig false "mapIfaceOccDeclLocal" (TyFun (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "TyConOrigin") (TyCon "TyConOrigin")))) (TyFun (TyCon "Decl") (TyCon "Decl"))))
(DFunDef false "mapIfaceOccDeclLocal" ((PVar "f") (PAs "d" (PRec "DInterface" ((rf "ifaceOrigin" PWild) (rf "supers" None)) false))) (EVariantUpdate "DInterface" (EVar "d") ((fa "supers" (EApp (EApp (EMethodRef "map") (EApp (EVar "mapSuperOcc") (EVar "f"))) (EVar "supers"))))))
(DFunDef false "mapIfaceOccDeclLocal" ((PVar "f") (PAs "d" (PRec "DImpl" ((rf "implOrigin" (PVar "o")) (rf "iface" (PVar "n")) (rf "reqs" None)) false))) (EVariantUpdate "DImpl" (EVar "d") ((fa "implOrigin" (EApp (EApp (EApp (EVar "f") (ELit (LString "implOrigin"))) (EVar "n")) (EVar "o"))) (fa "reqs" (EApp (EApp (EMethodRef "map") (EApp (EVar "mapRequireOcc") (EVar "f"))) (EVar "reqs"))))))
(DFunDef false "mapIfaceOccDeclLocal" ((PVar "f") (PCon "DAttrib" (PVar "attrs") (PVar "d"))) (EApp (EApp (EVar "DAttrib") (EVar "attrs")) (EApp (EApp (EVar "mapIfaceOccDeclLocal") (EVar "f")) (EVar "d"))))
(DFunDef false "mapIfaceOccDeclLocal" (PWild (PVar "d")) (EVar "d"))
(DTypeSig false "fillIfaceOccOrigin" (TyFun (TyApp (TyCon "OrdMap") (TyCon "TyConOrigin")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "TyConOrigin") (TyCon "TyConOrigin"))))))
(DFunDef false "fillIfaceOccOrigin" ((PVar "scope") PWild (PVar "n") (PCon "OriginUnresolved")) (EApp (EApp (EVar "optionOr") (EVar "OriginUnresolved")) (EApp (EApp (EVar "omLookup") (EApp (EVar "ifaceKey") (EVar "n"))) (EVar "scope"))))
(DFunDef false "fillIfaceOccOrigin" (PWild PWild PWild (PCon "OriginBuiltin")) (EVar "OriginBuiltin"))
(DFunDef false "fillIfaceOccOrigin" (PWild PWild PWild (PAs "o" (PCon "OriginModule" PWild))) (EVar "o"))
(DTypeSig true "ifaceKey" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "ifaceKey" ((PVar "n")) (EBinOp "++" (EBinOp "++" (ELit (LString "iface:")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString ""))))
(DTypeSig false "ifaceDeclaredIn" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "ifaceDeclaredIn" ((PVar "mid") (PVar "n")) (ETuple (EApp (EVar "ifaceKey") (EVar "n")) (EVar "mid")))
(DTypeSig false "ownIfaceOrigin" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyTuple (TyCon "String") (TyCon "TyConOrigin")))))
(DFunDef false "ownIfaceOrigin" ((PVar "mid") (PVar "n")) (ETuple (EApp (EVar "ifaceKey") (EVar "n")) (EApp (EVar "OriginModule") (EVar "mid"))))
(DTypeSig false "interfaceNamesOf" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "interfaceNamesOf" ((PList)) (EListLit))
(DFunDef false "interfaceNamesOf" ((PCons (PRec "DInterface" ((rf "name" (PVar "n")) (rf "ifaceOrigin" PWild)) false) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "interfaceNamesOf") (EVar "rest"))))
(DFunDef false "interfaceNamesOf" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "interfaceNamesOf") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "interfaceNamesOf" ((PCons PWild (PVar "rest"))) (EApp (EVar "interfaceNamesOf") (EVar "rest")))
(DTypeSig true "stampGraphTyOrigins" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))))))
(DFunDef false "stampGraphTyOrigins" ((PVar "coreDecls") (PVar "modules")) (EBlock (DoLet false false (PVar "coreTypes") (EBinOp "++" (EApp (EApp (EMethodRef "map") (EApp (EVar "typeDeclaredIn") (ELit (LString "core")))) (EApp (EVar "dataRecordNames") (EVar "coreDecls"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "ifaceDeclaredIn") (ELit (LString "core")))) (EApp (EVar "interfaceNamesOf") (EVar "coreDecls"))))) (DoLet false false (PVar "coreS") (EApp (EApp (EApp (EApp (EVar "stampOneModule") (EVar "coreTypes")) (EVar "omEmpty")) (ELit (LString "core"))) (EVar "coreDecls"))) (DoExpr (ETuple (EVar "coreS") (EApp (EApp (EApp (EVar "stampModulesGo") (EVar "coreTypes")) (EVar "omEmpty")) (EVar "modules"))))))
(DTypeSig false "stampOneModule" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "stampOneModule" ((PVar "coreTypes") (PVar "known") (PVar "mid") (PVar "prog")) (EApp (EApp (EVar "stampTyOrigins") (EApp (EApp (EApp (EApp (EVar "tyOriginScope") (EVar "coreTypes")) (EVar "known")) (EVar "mid")) (EVar "prog"))) (EApp (EApp (EVar "stampDeclOrigins") (EVar "mid")) (EVar "prog"))))
(DTypeSig false "stampModulesGo" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))))))
(DFunDef false "stampModulesGo" (PWild PWild (PList)) (EListLit))
(DFunDef false "stampModulesGo" ((PVar "coreTypes") (PVar "known") (PCons (PTuple (PVar "mid") (PVar "prog")) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "mid") (EApp (EApp (EApp (EApp (EVar "stampOneModule") (EVar "coreTypes")) (EVar "known")) (EVar "mid")) (EVar "prog"))) (EApp (EApp (EApp (EVar "stampModulesGo") (EVar "coreTypes")) (EApp (EApp (EApp (EVar "omInsert") (EVar "mid")) (EApp (EApp (EApp (EVar "typeOriginExports") (EVar "known")) (EVar "mid")) (EVar "prog"))) (EVar "known"))) (EVar "rest"))))
(DTypeSig true "stampFlatTyOrigins" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "stampFlatTyOrigins" ((PVar "coreDecls") (PVar "prog")) (EApp (EApp (EVar "stampTyOrigins") (EApp (EVar "flatTyOriginScope") (EVar "coreDecls"))) (EVar "prog")))
(DTypeSig false "flatTyOriginScope" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "OrdMap") (TyCon "TyConOrigin"))))
(DFunDef false "flatTyOriginScope" ((PVar "coreDecls")) (EApp (EApp (EVar "omFromPairs") (EApp (EApp (EMethodRef "map") (EVar "importedTyOrigin")) (EBinOp "++" (EApp (EApp (EMethodRef "map") (EApp (EVar "typeDeclaredIn") (ELit (LString "core")))) (EApp (EVar "dataRecordNames") (EVar "coreDecls"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "ifaceDeclaredIn") (ELit (LString "core")))) (EApp (EVar "interfaceNamesOf") (EVar "coreDecls")))))) (EApp (EApp (EVar "omFromPairs") (EVar "builtinTyOrigins")) (EVar "omEmpty"))))
(DTypeSig true "externTyOriginScope" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "OrdMap") (TyCon "TyConOrigin"))))
(DFunDef false "externTyOriginScope" ((PVar "coreDecls")) (EApp (EVar "flatTyOriginScope") (EVar "coreDecls")))
(DTypeSig false "originTraceEnabled" (TyApp (TyCon "Ref") (TyCon "Bool")))
(DFunDef false "originTraceEnabled" () (EApp (EVar "Ref") (EVar "False")))
(DTypeSig false "originTraceLog" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "originTraceLog" () (EApp (EVar "Ref") (EListLit)))
(DTypeSig true "setOriginTrace" (TyFun (TyCon "Bool") (TyCon "Unit")))
(DFunDef false "setOriginTrace" ((PVar "b")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EVar "originTraceLog")) (EListLit))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "originTraceEnabled")) (EVar "b")))))
(DTypeSig true "noteOriginTrace" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Unit"))))
(DFunDef false "noteOriginTrace" ((PVar "label") (PVar "decls")) (EIf (EUnOp "!" (EVar "originTraceEnabled")) (EApp (EApp (EVar "setRef") (EVar "originTraceLog")) (EBinOp "++" (EUnOp "!" (EVar "originTraceLog")) (EListLit (ETuple (EVar "label") (EVar "decls"))))) (ELit LUnit)))
(DTypeSig true "takeOriginTrace" (TyFun (TyCon "Unit") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "takeOriginTrace" (PWild) (EBlock (DoLet false false (PVar "rows") (EUnOp "!" (EVar "originTraceLog"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "originTraceLog")) (EListLit))) (DoExpr (EVar "rows"))))
