# META
source_lines=1453
stages=DESUGAR,MARK
# SOURCE
-- tc_diag_text: the context-free message text of the typechecker: every message, help and fix
-- builder, diagnostic key (`locKey`, `msgAtKey`, `locGoalKey`) and rewrite of diagnostic text
-- (`writtenDiag`, `prependDiagOpt`) whose operands are values (`Mono`, `Ty`, atoms, kinds,
-- `IfaceRef`, `Loc`, AST nodes, names) and whose closure is `tc_types`, `tc_mono`, `repr`, the
-- AST and the effect leaves; no row takes a context record, an environment or a cell (D3).
--
-- Spec: ERROR-QUALITY.md; A5. Precedent: GHC.Tc.Errors.Ppr (unsourced here: a leaf that
-- imports only Tc.Errors, Tc.Types and TcType); Medaka has text builders without a message data
-- type, so a diagnostic's code is still passed at each emit site.
--
-- Placement: declarations are placed by R1-R6 of the Phase 4 module table,
-- compiler/ARCHITECTURE-PLAYBOOK.md section 6.
-- Closure rule: this module may not import `types.typecheck`, nor any of `tc_state`, `tc_env`,
-- `tc_diag`, `tc_scope`, `tc_unify`, `tc_decls_variance`, `tc_decls_types`, `tc_decls`,
-- `tc_foreign`, `tc_solve_givens`, `tc_solve_entail`, `tc_solve`, `tc_solve_check`, `tc_shadow`,
-- `tc_effects`, `tc_occurrence`, `tc_groups`, `tc_pat`, `tc_infer_records`, `tc_infer`, `tc_elab`,
-- `tc_global`, `tc_module`.

import types.tc_mono.{
  cohPpPair,
  dedupI,
  findTvName,
  firstIdConflict,
  headIdConflict,
  headTyconNameMono,
  isPreludeOrigin,
  recordOwnerModule,
  recordResultMono,
}
import frontend.ast.{
  authTermsSurface,
  EffAtomTy(..),
  EffParamTy(..),
  Expr(..),
  KindAnn(..),
  kindAnnSource,
  Lit(..),
  Loc(..),
  patternMark,
  qualifierSource,
  TabKey(..),
  tabKeyName,
  Ty(..),
  TyConOrigin(..),
}
import types.repr.{
  normalize,
  IfaceRef(..),
  Mono(..),
  ppAuthority,
  ppConName,
  ppEach,
  ppEffArgFmt,
  ppEffInsideTy,
  ppEffvarName,
  ppGo,
  ppMono,
  ppMonosShared,
  ppPredArgsShared,
  ppTy,
  ppTyAtom,
  tupleHeadTagTc,
}
import types.tc_types.{
  DeclaringBinder(..),
  KeyEntry,
  Kind(..),
  MethodBodyKind(..),
  RecordInfo,
}
import types.publish.{TcDiag(..)}
import support.util.{
  contains,
  dedup,
  dedupBy,
  escStr,
  isEmptyL,
  isNonEmptyL,
  joinWith,
  listLen,
  reverseL,
  sortUniqS,
  splitOnChar,
  startsWith,
}
import types.effect_rows.{Atom(..), effLabelName, Effvar(..), renderAtoms}
import types.effect_authority.{authIsTop, Authority(..)}

-- The directed judgment `required <= allowed` failed against an allowed row the
-- body cannot solve: a signature's own row variable, or a row the caller
-- supplies through an argument or callback. The message names what escaped
-- (concrete labels, or the caller's whole row) and the two honest repairs,
-- because the same judgment now covers what several site-specific checks used
-- to explain separately. [required, allowed] are rendered with one shared
-- variable-naming context so the two rows spell a shared tail the same way.
export
effectInclusionMsg : String -> List Atom -> List String -> String
effectInclusionMsg name escaping [required, allowed] =
  if isNonEmptyL escaping then
    let labels = renderAtoms escaping
    "`\{name}` performs <\{labels}> on a caller-chosen row \{rowText allowed}; \{declareRemedy labels allowed}, or perform it through an argument"
  else
    "`\{name}` runs the caller-chosen row \{rowText required} where only \{rowText allowed} is allowed; declare it on the arrow that runs it, `-> \{rowText required} ...`"
effectInclusionMsg name _ rows =
  "cannot prove effect row inclusion in `\{name}`: \{joinWith ", " rows}"

-- A bare tail renders without brackets; the prose reads better with them.
rowText : String -> String
rowText s = if stringSlice 0 1 s == "<" then s else "<\{s}>"

-- The repair, spelled against the row as the message rendered it: a bare tail
-- gains the labels beside its variable; a row that already has labels gains one.
declareRemedy : String -> String -> String
declareRemedy labels allowed =
  if stringSlice 0 1 allowed == "<" then
    "declare <\{labels}> in that row"
  else
    "declare it, `<\{labels} | \{allowed}>`"

export
patternIndexMsg : Authority -> String
patternIndexMsg term =
  let t = authorityTermTextIn (Ref []) (Ref 0) term
  "a pattern-ranging `Authority L*` index is equated with \{t}, which is not a pattern; write a pattern there, such as `\"data/*\"` or `*`"

export
renderFlatRow : (List Atom, List (Ref Effvar)) -> String
renderFlatRow f =
  let ctx = Ref []
  let cnt = Ref 0
  ppEffArgFmt
    (renderAtomsOrEmpty (fst f))
    (joinWith " | " (map (m => ppEffvarName ctx cnt m) (snd f)))

renderAtomsOrEmpty : List Atom -> String
renderAtomsOrEmpty [] = ""
renderAtomsOrEmpty ls = renderAtoms ls

export
joinMismatchMsg : String -> String -> String
joinMismatchMsg a b =
  "effect rows \{a} and \{b} cannot be made equal: each carries an effect variable the other has no room for; keep the method's effect variables distinct, or join them in the result index, `f (e | e2) b`"

-- ERROR-QUALITY.md: deliberately NOT `effectLeakMsg`'s wording.  "Effectful value used
-- where <> is allowed, but it performs <Stdout>" is the ARROW message and reads as a lie
-- here — nothing is being performed at the point of mismatch; two types simply differ.
-- Symmetric phrasing because `unify` has no expected/actual role.
export
indexRowMismatchMsg : List Atom -> List Atom -> String
indexRowMismatchMsg l1 l2 =
  "effect index mismatch: <\{renderAtoms l1}> vs <\{renderAtoms l2}>; an effect row in a type argument is invariant, so write the same row on both sides or use a row variable, \{openRowHint l1}"

-- The "make it row-polymorphic" spelling for a row that may be EMPTY: `<>` has no
-- labels, so the naive `<\{renderAtoms l1} | e>` renders the un-writable `< | e>`.
openRowHint : List Atom -> String
openRowHint [] = "`e`"
openRowHint atoms = "`<\{renderAtoms atoms} | e>`"

-- ERROR-QUALITY.md: symmetric phrasing, because `unify` cannot name a culprit
-- side here; the remedy names the seams where a purer value IS accepted.
export
closedRowMismatchMsg : List Atom -> List Atom -> String
closedRowMismatchMsg l1 l2 =
  "effect rows <\{renderAtoms l1}> and <\{renderAtoms l2}> cannot be made equal: the two values must have one type, and this position neither widens nor narrows a row; write the same row on both sides"

export
patternDomainMsg : String -> String -> String
patternDomainMsg written l =
  "`\{written}` ranges over patterns, but `\{l}` is not a `Prefix` domain and has none; drop the `*`"

export
authorityAtomicLabelMsg : String -> String
authorityAtomicLabelMsg l =
  "`Authority \{l}` needs a domain, but `\{l}` is an atomic label and declares none; declare it `effect \{l} Prefix`"

export
phantomExportMsg : String -> String -> String -> String
phantomExportMsg tyName ctor p =
  "constructor `\{ctor}` of public type `\{tyName}` carries its authority parameter `\{p}` in no field, so another module could invent an authority; export `\{tyName}` abstractly with `export data`, or give `\{ctor}` a field that carries `\{p}`"

export
authorityParamAsRowMsg : String -> String -> String
authorityParamAsRowMsg name p =
  "type `\{name}` declares `\{p}` as an authority, but a field uses it as an effect row; write a different variable for the row"

export
authorityParamAsTypeMsg : String -> String -> String
authorityParamAsTypeMsg name p =
  "type `\{name}` declares `\{p}` as an authority, but a field uses it as a type; write a different variable for the type"

export
ifaceParamAuthorityKindMsg : String -> String -> String
ifaceParamAuthorityKindMsg name p =
  "interface `\{name}` declares `\{p}` as an authority, but an interface parameter is a type or a graded constructor; index a data type with `(\{p} : Authority L)` and implement the interface for it"

export
unannotatedRowParamMsg : String -> String -> String
unannotatedRowParamMsg name p =
  "type parameter `\{p}` of `\{name}` is used as an effect row, but its head does not declare it one; declare the head as `\{name} (\{p} : Effect) ...`"

export
typeParamAsRowMsg : String -> String -> String
typeParamAsRowMsg name p =
  "type parameter `\{p}` of `\{name}` is declared `(\{p} : Type)` but is used as an effect row; declare it `(\{p} : Effect)`"

export
effectParamAsTypeMsg : String -> String -> String
effectParamAsTypeMsg name p =
  "type parameter `\{p}` of `\{name}` is declared `(\{p} : Effect)` but is used as an ordinary type; drop the annotation, or move `\{p}` into an effect position such as `Unit -> <\{p}> a`"

export
effectArrowOnDataHeadMsg : String -> String -> KindAnn -> String
effectArrowOnDataHeadMsg name p k =
  "type parameter `\{p}` of `\{name}` is declared with kind `\{kindAnnSource k}`, but an arrow kind containing `Effect` is allowed on interface heads only; declare it `Effect` or an Effect-free kind"

export
ifaceSlotDeclaredTypeMsg : String -> String -> KindAnn -> String
ifaceSlotDeclaredTypeMsg name p k =
  "type parameter `\{p}` of interface `\{name}` is declared `(\{p} : \{kindAnnSource k})`, but a method uses one of its `Type` slots as an effect row; declare that slot `Effect`"

export
ifaceParamEffectKindMsg : String -> String -> String
ifaceParamEffectKindMsg name p =
  "type parameter `\{p}` of interface `\{name}` is declared `(\{p} : Effect)`, but an interface parameter is a type constructor; write `(\{p} : Effect -> Type -> Type)` for an effect-indexed constructor"

export
unannotatedGradedParamMsg : String -> String -> List Kind -> String
unannotatedGradedParamMsg name p inferred =
  "type parameter `\{p}` of interface `\{name}` is used as an effect-indexed constructor, but its head does not declare it one; declare the head as `\{name} (\{p} : \{renderKindArrow inferred}) ...`"

export
requiresKindMsg : String -> String -> String
requiresKindMsg name sh =
  "interface `\{name}` requires `\{sh}` at a parameter whose kind differs from `\{sh}`'s own, and there is no coercion between `Type` and `Effect`; declare both heads at the same kind"

-- #1103: the UNCOVERED-ATOMS arm now covers ordinary top-level signatures as
-- well as interface methods, and the two cases get DIFFERENT prose — a top-level
-- function has no interface to name and no impl to blame.  The interface wording
-- is byte-frozen (`test/typecheck_error_fixtures/iface_effvar_arg_*.tc.golden`
-- pin it).  There is no `None` counterpart for `argOnlyEffVarMsg`: the
-- argument-only arm is method-only, see `checkArgEffVars`.
export
argAtomsMsgFor : Option String -> String -> String -> List Atom -> String
argAtomsMsgFor (Some iface) mname v esc = argAtomsUncoveredMsg iface mname v esc
argAtomsMsgFor None fname v esc = argAtomsUncoveredFnMsg fname v esc

argAtomsUncoveredFnMsg : String -> String -> List Atom -> String
argAtomsUncoveredFnMsg fname v esc =
  "effect variable <\{v}> in function `\{fname}` carries <\{renderAtoms esc}> at an argument position, but a row carrying <\{v}> does not include it; declare <\{renderAtoms esc}> at every row where <\{v}> appears"

export
argOnlyEffVarMsg : String -> String -> String -> String
argOnlyEffVarMsg iface mname v =
  "argument-only effect variable <\{v}> in method `\{mname}` of interface `\{iface}`: it rides an argument but appears in none of the method's own effect rows; thread it through the method's row, `-> <\{v}> ...`"

argAtomsUncoveredMsg : String -> String -> String -> List Atom -> String
argAtomsUncoveredMsg iface mname v esc =
  "effect variable <\{v}> in method `\{mname}` of interface `\{iface}` carries <\{renderAtoms esc}> at an argument position, but a method row carrying <\{v}> does not include it; declare <\{renderAtoms esc}> at every row where <\{v}> appears"

renderEffTailVars : List String -> String
renderEffTailVars vs = joinWith ", " (map (v => "<\{v}>") vs)

export
effectUndeterminedMsg : String -> String -> List String -> String
effectUndeterminedMsg iface mname vars =
  "under-determined effect variable \{renderEffTailVars vars} in method `\{mname}` of interface `\{iface}`: it appears only in the return type, pinned by no argument; use a concrete row such as `<Stdout>`, or thread it through a callback `a -> <e> b`"

export
kindName : Kind -> String
kindName KType = "Type"
kindName KRow = "Effect"
kindName (KAuth l pat) = "Authority \{effLabelName l}\{patternMark pat}"

export
renderKindArrow : List Kind -> String
renderKindArrow ks = joinWith " -> " (map kindName ks ++ ["Type"])

-- [ctor] is a RAW head tag and must reach the reader through `ppConName` — a tuple
-- head arrives as `__tuple2__`, and leaking that is exactly what ppConName exists to
-- prevent.
export
implKindMismatchMsg : String ->
  String ->
  Int ->
  List Kind ->
  List Kind ->
  String
implKindMismatchMsg iface ctor nApplied want got =
  "instance head has the wrong kind for interface `\{iface}`: its type parameter is graded, kind `\{renderKindArrow want}`, but \{implHeadKindClause ctor nApplied got}; \{implKindMismatchFix iface ctor nApplied}"

-- The "but …" clause: an UNAPPLIED head states its own kind; a partially applied one
-- (`impl I (Async e)` — the fixed-row shape a graded interface forbids) must say so,
-- because the leftover kind is NOT the constructor's kind and reporting it as such is
-- simply false (`Async` is `Row -> Type -> Type`; `Async e` is `Type -> Type`).
argumentNoun : Int -> String
argumentNoun n = if n == 1 then "argument" else "arguments"

implHeadKindClause : String -> Int -> List Kind -> String
implHeadKindClause ctor nApplied got
  | nApplied <= 0 = "`\{ppConName ctor}` has kind `\{renderKindArrow got}`"
  | otherwise =
    "this head applies \{intToString nApplied} \{argumentNoun nApplied} to `\{ppConName ctor}`, leaving kind `\{renderKindArrow got}`"

-- The remedy, conditioned on which mistake was actually made.  Telling an author who
-- wrote `impl GThenable Box` to "write `impl GThenable Box`" is a tautology — that
-- advice is only useful when the head was APPLIED, where dropping the argument is
-- literally the fix.
implKindMismatchFix : String -> String -> Int -> String
implKindMismatchFix iface ctor nApplied
  | nApplied > 0 =
    "a graded interface binds the whole row-indexed family, so write `impl \{iface} \{ppConName ctor}` with no arguments"
  | otherwise =
    "give `\{ppConName ctor}` a parameter used in an effect position at each `Row` slot, such as a field `Unit -> <e> a`, or implement a non-graded interface for it"

-- A saturated TUPLE head, which needs its own message: a tuple is kind `Type` and cannot
-- be given a row parameter, so the ordinary "add a `Unit -> <e> a` field" remedy would
-- send the author after something that does not exist.
export
implTupleHeadKindMsg : String -> Int -> List Kind -> String
implTupleHeadKindMsg iface n want =
  "instance head `\{ppConName (tupleHeadTagTc n)}` has the wrong kind for interface `\{iface}`: its type parameter is graded, kind `\{renderKindArrow want}`, but a tuple is kind `Type`; implement a non-graded interface for it, or use a row-indexed data type as the head"

export
binderDomainTypeMsg : String -> String -> String
binderDomainTypeMsg n ty =
  "named argument `\{n}` has type `\{ty}` but is written with a domain, and only a `String` argument has an authority; give `\{n}` the type `String` or drop the domain"

export
binderTypeMsg : String -> String -> String
binderTypeMsg n ty =
  "named argument `\{n}` has type `\{ty}`, but an effect atom names it as an authority, and only a `String` argument can be one; give `\{n}` the type `String` or write the label bare"

export
binderDomainMsg : String -> String
binderDomainMsg n =
  "authority `\{n}` is used at labels from different domains, and one authority has one domain; name a second binder for the other label"

-- [diags] (newest first, as the sticky list holds them) in push order, deduplicated
-- per goal.
export
stickyDiagsInPushOrder : List (String, TcDiag) -> List (String, TcDiag)
stickyDiagsInPushOrder diags = dedupBy tcDiagGoalKey (reverseL diags)

export
tcDiagGoalKey : (String, TcDiag) -> String
tcDiagGoalKey (mid, TcDiag code _ loc msg _ _) =
  "\{mid}|\{code}|\{locGoalKey loc}|\{msg}"

export
authorityIndexMsg : Authority -> Authority -> String
authorityIndexMsg a b =
  let ctx = Ref []
  let cnt = Ref 0
  let sa = authorityTermTextIn ctx cnt a
  let sb = authorityTermTextIn ctx cnt b
  let (x, y) = if sa <= sb then (sa, sb) else (sb, sa)
  "authority index mismatch: \{x} vs \{y}; an authority in a type argument is invariant, so write the same index on both sides or name it, `Handle p`"

-- An index row's atom its other side cannot absorb must lie within that
-- side's authority for the label: coverage, not equality.
export
authorityCoverMsg : Authority -> Authority -> String
authorityCoverMsg lower upper =
  let ctx = Ref []
  let cnt = Ref 0
  let lo = authorityTermTextIn ctx cnt lower
  let hi = authorityTermTextIn ctx cnt upper
  "authority index mismatch: \{lo} is not covered by \{hi}; stay within \{hi}, or widen the row's authority for the label"

-- An authority as a message names it: the top as the whole domain, a term
-- as it is written, under a naming context shared by every term of one
-- message, so two distinct variables with one binder name read apart.
export
authorityTermTextIn : Ref (List (Int, String)) -> Ref Int -> Authority -> String
authorityTermTextIn ctx cnt q =
  if authIsTop q then "the whole domain" else ppAuthority ctx cnt q

-- A residual of [callee]'s inferred scheme that this use does not satisfy:
-- the relation is the callee's, so the bound is not one this binding wrote.
export
residualFailureMsg : String -> String -> String -> String
residualFailureMsg callee lo hi =
  "`\{callee}` needs \{lo} to lie within \{hi} here, but this use does not satisfy it; pass values whose authorities do"

-- The pattern-ranging spelling of binder [n], on label [l] when it is known.
export
starSpelling : String -> Option String -> String
starSpelling n (Some l) =
  "`\{n}` pattern-ranging, `(\{n} : String @\{l}*)` or `(\{n} : Authority \{l}*)`"
starSpelling n None = "`\{n}` pattern-ranging, `@L*` or `Authority L*`"

-- ERROR-QUALITY.md: a distinct surface from BOTH `effectLeakMsg` (nothing is
-- being performed here) and `indexRowMismatchMsg` (that one is about a row
-- WRITTEN as a type argument; this one is about an ordinary function type that
-- happens to SIT in one, and its remedy is different — write the same row, or
-- move the value, not "make the type row-polymorphic").  Symmetric phrasing,
-- because `unify` has no expected/actual role to name one side the culprit.
--
-- #2109 (over-reject at the safe direction): the second sentence names the
-- ETA-EXPANSION recovery, because the `this does narrow acceptance in the sound
-- direction too` caveat on `paramVarianceGuard` (`tc_unify`) is otherwise INVISIBLE
-- to the person who hit it.  `handler : Ref (String -> <Stdout> Unit); handler = Ref noop` is
-- REJECTED while `handler = Ref (s => noop s)` is ACCEPTED — MEASURED, both at
-- this commit.  The two programs have identical semantics; the second is
-- accepted only because a lambda's latent row is still an unsolved variable, so
-- the closed~closed row arm is never reached.  That accident is now stated
-- as the remedy rather than left for the reader to rediscover.
--
-- The recovery is not A laundering hole, and that is measured, not assumed.
-- Eta-expanding in the UNSAFE direction still rejects: `handler : Ref (String ->
-- <> Unit); handler = Ref (s => shouty s)` fails with T-EFFECT-LEAK
-- (`Effectful value used where <> is allowed, but it performs <Stdout>`),
-- byte-identical to the un-expanded `Ref shouty`.  The open row the lambda
-- restores is still bounded by the slot, so eta-expansion buys back exactly the
-- narrowing direction and nothing else — which is why naming it here is safe.
--
-- No rule keyed on TYPES can separate the two directions at this seam:
-- `handler = Ref noop` (safe narrowing, #2109) and `alias = idr box` (the #1098
-- laundering) reach `paramVarianceGuard` with the SAME two Monos and render the
-- SAME row pair.  What separates them is expression-level provenance — a value
-- flowing INTO a cell being built here, versus an already-typed cell being
-- coerced — and that is now read where it is visible: a signed clause's body
-- is inferred RESULT-FIRST against its signature (`inferExpected`), so a fresh
-- construction meets the declaration while its slot is still a metavariable
-- and this guard abstains, while an already-typed cell still arrives closed
-- and is rejected here.  The eta-expansion recovery the message names is what
-- remains for the shapes result-first inference does not reach (an unsigned
-- binding, a lambda-argument head).
export
paramVarianceMismatchMsg : List Atom -> List Atom -> String
paramVarianceMismatchMsg l1 l2 =
  "effect row mismatch inside a non-covariant type argument: <\{renderAtoms l1}> vs <\{renderAtoms l2}>; the two rows must be equal here, so write the same row on both sides, or eta-expand a freshly built function, `(s => f s)`"

export
elselessIfHelp : String
elselessIfHelp =
  "an `if` without `else` has type Unit, so add an `else` branch or make the `then` branch Unit"

export
constrainedApplicationText : Mono -> Mono -> List String -> String
constrainedApplicationText app plain ifaces =
  let names = joinWith " and " (map (i => "`\{i}`") ifaces)
  "`\{ppMono app}` is a value whose type implements \{names}, and `\{ppMono plain}` is not"

-- ── same-spelling mismatch hint (#1111 A-2.10) ─────────────────────────────
-- Fires ONLY when the two sides RENDER identically and some head inside them
-- carries two conflicting module identities — i.e. exactly the mismatch this
-- unit newly reports.  Both conditions matter: the render test is what makes
-- the hint appear where the message is otherwise unreadable, and the conflict
-- search is what lets it name the two modules instead of hand-waving.
--
-- It cannot move an existing golden, and that is structural rather than
-- lucky: `firstIdConflict` answers `Some` only where both origins are present
-- and differ, and before this unit every such pair UNIFIED — so no diagnostic
-- that exists today can reach this arm.  (The other in-tree source of two
-- identically-rendering sides, the `__tupleN__` rigid-vs-builtin forgery at
-- `unifyN`'s cross-population arms, is a `TRigid`: it carries no origin, so it
-- yields `None` here and its message is untouched.  That residual is #1243.)
-- A program's own type may shadow a prelude type (#3465), so two sides whose
-- heads share a spelling but not an identity can also differ in shape
-- (`Result vs Result a b`): their heads are compared as well.
export
sameSpellingHint : Mono -> Mono -> Option String
sameSpellingHint a b
  | ppMono a /= ppMono b = map idConflictHelp (headIdConflict a b)
  | otherwise = map idConflictHelp (firstIdConflict a b)

idConflictHelp : (String, TyConOrigin, TyConOrigin) -> String
idConflictHelp (name, o1, o2) =
  let remedy =
    if isPreludeOrigin o1 || isPreludeOrigin o2 then
      "build this value with the constructors of the type this position expects"
    else
      "import the one you mean instead of declaring a second type with that name"
  "two different types share the name `\{name}`: one comes from \{originPhrase o1}, the other from \{originPhrase o2}; \{remedy}"

-- User vocabulary, never a constructor spelling (ERROR-QUALITY.md §1).  The
-- unresolved case is unreachable from `firstIdConflict` (a conflict needs two
-- present identities) and is answered rather than omitted so this stays total.
originPhrase : TyConOrigin -> String
originPhrase (OriginModule "core") = "the prelude"
originPhrase (OriginModule "__user__") = "this program"
originPhrase (OriginModule m) = "module `\{m}`"
originPhrase OriginBuiltin = "the language itself"
originPhrase OriginUnresolved = "an unknown module"

export
doRequiresMonadMsg : String
doRequiresMonadMsg =
  "`do` needs a value whose type implements `Thenable`, such as `Option` or `Result`; for IO sequencing use a bare indented block instead of `do`"

export
deferRequiresMonadMsg : String
deferRequiresMonadMsg =
  "`defer` needs a value whose type implements `DeferredThenable`, such as `Async`; for `Option`, `Result` or `List` use `do` instead"

-- SYMMETRIC complement of doRequiresMonadMsg: a `<-` bind reached a bare
-- (non-`do`) block.  `<-` is monadic-`do`-only; a bare indented block is IO
-- sequencing and does not allow it (language-design.md; "IO is not a monad").
export
bindOutsideDoMsg : String
bindOutsideDoMsg =
  "`<-` is only valid inside a `do` block; outside one, bind the value with `let x = ...`"

export
qualifierBinderTypeMsg : String -> String -> String
qualifierBinderTypeMsg n ty =
  "named argument `\{n}` has type `\{ty}`, but a qualifier names it as an authority, and only a `String` argument has one; qualify by a `String` argument or drop `\{n}` from the qualifier"

export
binderNoDomainMsg : String -> String
binderNoDomainMsg n =
  "the qualifier names `\{n}`, but no binder domain, effect atom or index in this signature gives it a domain; write one on the binder, `(\{n} : String @FileRead)`, or name the label it bounds, `<FileRead \{n}>`"

export
joinDomainMsg : List String -> String
joinDomainMsg ns =
  "the joined qualifier \{qualifierSource escStr (map EPName ns)} joins authorities from different domains; qualify by authorities of one label's domain"

export
nameNotAuthorityMsg : String -> String
nameNotAuthorityMsg n =
  "`\{n}` is used as an authority, but nothing binds it as one; bind it as a named argument, `(\{n} : String) ->`, or an `Authority`-kinded index"

-- ppTy's own TyRow rendering (below, in the AST pretty-printer section) isn't
-- visible yet at this point in the file, so render the row body directly with
-- the SAME row-body renderer that feeds it (`ppEffInsideTy`, further down —
-- forward reference, fine: this module is resolved as a whole, not top-down).
export
rowKindMismatchMsg : List EffAtomTy -> List String -> String
rowKindMismatchMsg labels tail =
  "the row <\{ppEffInsideTy labels tail}> is written at a type-argument position that is not row-kinded; write an ordinary type here"

-- A type alias applied to the wrong number of arguments — over-applied,
-- under-applied, or (got=0) used unapplied.  v1 requires a parameterized alias
-- to be saturated; an alias is not a first-class type constructor (DESIGN §3/§9
-- fork 2).  Deduped (pushTypeErrorOnce) since a signature's `Ty` is converted to
-- `Mono` repeatedly during inference.
export
aliasArityMsg : String -> Int -> Int -> String
aliasArityMsg n expected got =
  "type alias `\{n}` takes \{argumentCount expected} but is applied to \{intToString got}"

-- Count-correct `1 argument` / `2 arguments`.
argumentCount : Int -> String
argumentCount 1 = "1 argument"
argumentCount n = "\{intToString n} arguments"

-- A pattern slot (`Authority L*`) filled by a binder that ranges over the
-- whole domain: the caller could choose an exact element for it.
export
ordinaryInPatternSlotMsg : String -> String -> String
ordinaryInPatternSlotMsg n l =
  "`\{n}` ranges over every authority of `\{l}`, but it fills an `Authority \{l}*` slot, which takes only patterns; declare `\{n}` pattern-ranging, `(\{n} : String @\{l}*)` or `(\{n} : Authority \{l}*)`"

-- A pattern slot filled by a written exact element.
export
exactInPatternSlotMsg : String -> String -> String -> String
exactInPatternSlotMsg l written closed =
  "`\{written}` is an exact element of `\{l}`, but it fills an `Authority \{l}*` slot, which takes only patterns; write the pattern it begins, `\{closed}`, or `*`"

export
authorityAsTypeMsg : String -> String
authorityAsTypeMsg n =
  "`\{n}` is an authority binder but is used here as a type; write a different name for the type variable"

export
authorityTermAsTypeMsg : List EffParamTy -> String
authorityTermAsTypeMsg p =
  "the authority term `\{authTermsSurface escStr p}` is written where a type goes; it belongs in an `Authority`-kinded type argument such as `Handle \{authTermsSurface escStr p}`"

export
typeVarAsAuthorityMsg : String -> String -> String
typeVarAsAuthorityMsg n l =
  "`\{n}` is a type variable, but this slot is `Authority \{l}`; write an authority here: a binder's name, or a term such as `\"pattern/*\"` or `*`"

export
typeAsAuthorityMsg : String -> String -> String
typeAsAuthorityMsg ty l =
  "`\{ty}` is a type, but this slot is `Authority \{l}`; write an authority here: a binder's name, a literal of the label's domain, or `*`"

-- Names the offending type.  The report is per site (`pushTypeErrorOncePerSite`): a
-- signature elaborated twice folds into one diagnostic, while two bad slots holding the
-- same offending type (`weird : Box Int Int`, `alsoWeird : Box Int Unit`) are two.
export
typeInRowSlotMsg : Ty -> String
typeInRowSlotMsg ty =
  "the type `\{ppTy ty}` is written at a row-kinded type-argument position; write an effect row here, such as `<>`, `<Stdout>` or `<IO | e>`"

export
existentialScopeMsg : Option String -> String
existentialScopeMsg name =
  "this pattern opens the existential authority `\{optionOr "?" name}`, which only a `match` arm or a function clause can scope; match on the value, or take it as a clause parameter"

export
discardedValueMsg : String -> String
discardedValueMsg desc =
  "this statement's value (\{desc}) is discarded; only a `Unit` expression may stand alone as a statement"

export
discardedValueFix : Option Loc -> Option (Loc, String)
discardedValueFix (Some (Loc f sl sc _ _)) =
  Some (Loc f sl sc sl sc, "let _ = ")
discardedValueFix None = None

export
fieldNotInAllCtorsMsg : String -> String -> String -> String
fieldNotInAllCtorsMsg fname tname sib =
  "field `\{fname}` is not declared by every constructor of `\{tname}`: `\{sib}` has no `\{fname}`; match on the constructor instead of using `.\{fname}`"

export
fieldPositionDiffersMsg : String ->
  String ->
  (String, Int) ->
  (String, Int) ->
  String
fieldPositionDiffersMsg fname tname (a, i) (b, j) =
  "field `\{fname}` is at different positions in the constructors of `\{tname}`: it is field \{intToString (i + 1)} of `\{a}` but field \{intToString (j + 1)} of `\{b}`; match on the constructor instead of using `.\{fname}`"

-- The two types render under one naming context, so a parameter shared by both
-- prints as the same letter.
export
fieldTypeDiffersMsg : String ->
  String ->
  String ->
  Mono ->
  String ->
  Mono ->
  String
fieldTypeDiffersMsg fname tname a ta b tb =
  let ctx = Ref []
  let cnt = Ref 0
  let sa = ppGo ctx cnt 0 ta
  let sb = ppGo ctx cnt 0 tb
  "field `\{fname}` has different types in the constructors of `\{tname}`: it is `\{sa}` in `\{a}` but `\{sb}` in `\{b}`; match on the constructor instead of using `.\{fname}`"

-- The hint rebuilds the value from the constructor's pattern rather than
-- suggesting `Con { v | f = e }`, which does not check that `v` was built by
-- `Con`.
export
updateMultiCtorMsg : String ->
  String ->
  String ->
  List String ->
  List String ->
  String
updateMultiCtorMsg fn tname rname others ctors =
  let pat = if isEmptyL others then "..." else joinWith ", " others
  let rebuilt = joinWith ", " ("\{fn} = ..." :: others)
  "cannot update field `\{fn}` on `\{tname}`, which has more than one constructor (\{joinWith ", " (map backticked ctors)}); match on the constructor and rebuild the value in its arm, as in `\{rname} { \{pat} } => \{rname} { \{rebuilt} }`"

-- Distinct owner keys keep the owner-list message.  When one key holds two of the
-- declarations, the key alone cannot tell them apart, so each is named by its type
-- and declaring module, sorted so the text does not depend on import-clause order.
export
ambiguousFieldDeclsMsg : String ->
  List String ->
  List (String, RecordInfo) ->
  String
ambiguousFieldDeclsMsg fname owners cands =
  let keys = map fst cands
  if listLen (dedup keys) == listLen keys then
    ambiguousFieldMsg fname owners
  else
    let tys = sortUniqS (map fieldDeclTypeName cands)
    let descrs = sortUniqS (map fieldDeclDescr cands)
    "ambiguous field `.\{fname}`: it is declared by \{joinWith " and by " descrs} and the record type is undetermined; annotate the record, as in `(r : \{headL tys}).\{fname}`"

fieldDeclTypeName : (String, RecordInfo) -> String
fieldDeclTypeName (k, ri) = optionOr k (headTyconNameMono (recordResultMono ri))

fieldDeclDescr : (String, RecordInfo) -> String
fieldDeclDescr (k, ri) = match recordOwnerModule ri
  Some mid => "`\{fieldDeclTypeName (k, ri)}` from module `\{mid}`"
  None => "`\{fieldDeclTypeName (k, ri)}`"

headL : List String -> String
headL [] = ""
headL (x :: _) = x

-- The field name itself carries no Loc in the AST (`EFieldAccess Expr String
-- (Ref String)` — no per-field span).  The unknown-field check is located at
-- the RECEIVER's own span (the field access names its receiver's span) —
-- verified empirically:
-- `p.aeg` reports receiver span (sc, sc+1) for `p`, `somebody.aeg` reports
-- (sc, sc+8) for `somebody`.  The field name immediately follows the
-- receiver's end column + the `.`, so its span is computable from the
-- receiver's end column.  Valid for the common single-level `recv.field`
-- access; a chained `a.b.cty` receiver is itself a field access with no own
-- ELoc, so this would misplace the fix there — accepted for now (the
-- common-case gain is worth the narrow miss).
-- The misspelled name's span, from the receiver's end: past the `.`, as long
-- as the name WRITTEN (not the suggestion).  The field name carries no span
-- of its own, so a receiver separated from its `.` by whitespace still
-- mislocates it.
export
fieldFixFrom : Option Loc -> String -> String -> Option (Loc, String)
fieldFixFrom (Some (Loc f _ _ el ec)) written sug =
  Some (Loc f el (ec + 1) el (ec + 1 + stringLength written), sug)
fieldFixFrom None _ _ = None

export
unknownFieldMsg : String -> String -> String
unknownFieldMsg fname rname = "no field `\{fname}` in `\{rname}`"

-- Dot-access on a type exported abstractly: byte-identical to resolve.mdk's
-- AbstractFieldAccess ppResError, so a destructure (`Point { x }`, caught in
-- resolve) and a dot-access (`p.x`, caught here in typecheck) read the same.
export
abstractFieldMsg : String -> String -> String
abstractFieldMsg tname fname =
  "`\{tname}` is exported abstractly, so its field `\{fname}` is not accessible; declare it `public export` to expose its fields"

-- TYPECHECK-AUDIT OBS4.
export
missingFieldMsg : String -> String -> String
missingFieldMsg fname rname = "missing field `\{fname}` in `\{rname}`"

export
ambiguousFieldMsg : String -> List String -> String
ambiguousFieldMsg fname owners =
  "ambiguous field `.\{fname}`: it is declared by \{joinAnd (map backticked owners)} and the record type is undetermined; annotate the record, as in `(r : \{headL owners}).\{fname}`"

-- TYPECHECK-AUDIT D1: convert resolve-not-pre-screened error shapes (unknown
-- record / constructor, unbound variable) from uncatchable interpreter panics
-- into accumulated typeErrors + a fresh-var placeholder, so inference continues.
export
unknownRecordMsg : String -> String
unknownRecordMsg name = "unknown record type `" ++ name ++ "`"

export
unknownCtorMsg : String -> String
unknownCtorMsg name = "unknown constructor `" ++ name ++ "`"

export
unboundVarMsg : String -> String
unboundVarMsg name = "unbound variable `" ++ name ++ "`"

export
u64RangeText : String
u64RangeText = "0..18446744073709551615"

export
i64RangeText : String
i64RangeText = "-9223372036854775808..9223372036854775807"

-- A negated wide literal fits only an `I64`, so that is the annotation to suggest.
export
wideAnnotateHelp : String -> Bool -> String
wideAnnotateHelp shown negated =
  let ty = if negated then "I64" else "U64"
  "only a `U64` or an `I64` holds a literal above 2^62; annotate it as `(\{shown} : \{ty})`"

export
bangOnBoolMsg : String
bangOnBoolMsg =
  "`!` dereferences a `Ref` and does not negate a `Bool`; use `not x`"

export
bangOnBoolHelp : String
bangOnBoolHelp =
  "use `not x`; `!x` reads a `Ref` cell, so it needs a `Ref a`, not a `Bool`"

export
contraRowMsg : List Atom -> List Atom -> List Atom -> String
contraRowMsg le la extras =
  "a function whose parameter admits only <\{renderAtoms la}> is used where one admitting <\{renderAtoms le}> is expected, so a caller could pass an argument performing <\{renderAtoms extras}>; declare that parameter with <\{renderAtoms le}>"

-- Chunk C messages (T-NOT-A-FUNCTION): a value of a ground non-function type is
-- being applied.  Base wording names the offending type; the context-aware
-- form names the over-applied callee and its arity.
export
notAFunctionMsg : String -> String
notAFunctionMsg tyName = notAFunctionMsgFor None tyName

export
notAFunctionMsgFor : Option String -> String -> String
notAFunctionMsgFor (Some name) tyName =
  "`\{name}` has type \{tyName} and is not a function; it cannot be applied to an argument"
notAFunctionMsgFor None tyName =
  "this expression has type \{tyName} and is not a function; it cannot be applied to an argument"

-- F-dimension actionable-fix hint carried as the `help` of `notAFunctionMsg`
-- (2026-07-04): names the offending value when the spine head is a plain
-- variable, else falls back to a name-free phrasing.  No mechanical `fix` — the
-- caller decides whether to drop the argument or call a different function.
export
notAFunctionHint : Option String -> String
notAFunctionHint (Some name) =
  "`\{name}` is a value, not a function; remove the argument"
notAFunctionHint None = "this is a value, not a function; remove the argument"

export
overAppliedMsg : String -> Int -> Int -> String
overAppliedMsg name takes applied =
  "`\{name}` takes \{argumentCount takes} but is applied to \{intToString applied}"

export
containerArgMsg : Option String -> String -> String
containerArgMsg fn argTy =
  let who = match fn
    Some n => "`\{n}`"
    None => "this function"
  "\{who} expects a container such as `List` here but got `\{argTy}`; \{containerArgHint argTy}"

-- Actionable-fix hint appended to `containerArgMsg`.  Special-cases `String`
-- (the most common scalar handed to `map`): a String's characters are reachable
-- via `string.toChars`, so name that conversion rather than a generic one.
export
containerArgHint : String -> String
containerArgHint "String" =
  "to work over the string's characters, convert it with `string.toChars` first"
containerArgHint argTy = "convert the `\{argTy}` to a `List` first"

-- #894: `containerArgMsg` above hard-codes "a container (like List or Array)",
-- which is right for a genuine container-consuming HOF (`map`, `filter`, …) but
-- actively WRONG for the SAME reframe firing on a `do`-lowered `andThen` call —
-- `x <- b` / a bare statement line inside `do` lowers to `andThen b (...)`
-- (`lowerDo`, `compiler/frontend/desugar.mdk`), so a non-monadic `b` (e.g. `Bool`
-- in a `Result` do-block) hits this same container-vs-scalar detector.  "Pass a
-- List or Array" tells the user to convert their `Bool` into a list, which is
-- not the fix — the fix is `let` instead of `<-`, because the value was never
-- meant to be a container at all.  The concrete monad (`Result`) is NOT yet known
-- here (its tyvar is still free — nothing has pinned it), so this stays honest by
-- naming the shape ("Thenable", `do`'s own vocabulary — see `doRequiresMonadMsg`)
-- rather than guessing a specific type.  Fires ONLY on the exact callee `lowerDo`
-- synthesizes (`isDoLoweredAndThenCallee`, in `typecheck.mdk`) — an explicit user call to
-- `andThen` on a scalar argument, even one textually nested inside a do-bind's
-- own scrutinee, keeps the original List/Array message, which is the right
-- advice there.
export
doBindArgMsg : String -> String
doBindArgMsg argTy =
  "this `do` block needs a `Thenable` value here, such as `Option` or `Result`, but got `\{argTy}`; \{doBindArgHint argTy}"

export
doBindArgHint : String -> String
doBindArgHint argTy = "bind a plain `\{argTy}` with `let` instead of `<-`"

-- render a tuple element to source-ish text for the `add 1 2` fix, for the simple
-- literal/var/negation cases; None for anything a full printer would be needed for.
renderCallArg : Expr -> Option String
renderCallArg (ELoc _ e) = renderCallArg e
renderCallArg (EAnnot e _) = renderCallArg e
renderCallArg (ENumLit n _ _) = Some (intToString n)
renderCallArg (EWideLit _ _ _ lx) = Some lx
renderCallArg (ELit (LInt n)) = Some (intToString n)
renderCallArg (ELit (LBool True)) = Some "True"
renderCallArg (ELit (LBool False)) = Some "False"
renderCallArg (ELit (LString s)) = Some ("\"" ++ s ++ "\"")
renderCallArg (ELit (LChar c)) = Some ("'" ++ c ++ "'")
renderCallArg (EVar n) = Some n
renderCallArg (EVarId n _) = Some n
renderCallArg (EMethodAt n _ _) = Some n
renderCallArg (EDictAt n _) = Some n
renderCallArg (EUnOp "-" e _) = map ("-" ++ _) (renderCallArg e)
renderCallArg _ = None

-- all-or-nothing render of every tuple element.
export
renderCallArgs : List Expr -> Option (List String)
renderCallArgs [] = Some []
renderCallArgs (e :: rest) = match renderCallArg e
  None => None
  Some s => map (s :: _) (renderCallArgs rest)

-- The non-exhaustive-`match` warning (note the em-dash).  Coverage only; the
-- redundancy pass has its own string, `unreachableArmWarning`.  When the witness
-- algorithm can name the uncovered case (`nonExhaustiveMsg`) the message is
-- specialised to name the scrutinee type + the missing constructor; this
-- generic form is the fallback if no witness is recoverable.
export
nonExhaustiveMatchWarning : String
nonExhaustiveMatchWarning =
  "Warning: non-exhaustive match; not every case is covered"

-- ── unreachable / redundant match-arm warning (W-UNREACHABLE-ARM) ──────────
-- An arm is unreachable when an EARLIER *unguarded* arm already covers its pattern
-- (the detection is `patUnreachable` in `frontend.exhaust`; this module holds the
-- text only).  The warning carries the ARM's own loc (its body span) so the caret
-- points at the dead arm, not the match head.
export
unreachableArmWarning : String
unreachableArmWarning =
  "Warning: unreachable match arm; an earlier arm already covers this pattern"

-- Name the scrutinee type (skip the synthetic tuple type names, which aren't
-- user-facing — the witness pattern already reads as a tuple).
-- Reads the bare NAME out of the key (`tabKeyName`) on purpose: this is
-- witness PROSE, not a lookup, and its text must not change for any program
-- whose diagnostic does not change.
export
tyOfMsg : Option TabKey -> String
tyOfMsg None = ""
tyOfMsg (Some k) =
  let t = tabKeyName k
  if isTupleTyName t then "" else " on `\{t}`"

isTupleTyName : String -> Bool
isTupleTyName t = stringLength t >= 7 && stringSlice 0 7 t == "__tuple"

export
existentialEscapeMsg : Option String -> String
existentialEscapeMsg name =
  "the existential authority `\{optionOr "?" name}` escapes the arm or clause that opened it; consume the value inside it, or return it repacked in its existential constructor"

export
partialExistentialUpdateMsg : String -> List String -> String
partialExistentialUpdateMsg rname names =
  "updating `\{rname}` replaces a field under an existential authority binder, but the binder's fields \{quotedNames names} must change together; replace them all, or rebuild the record"

export
letRecNonFunctionMsg : String -> String
letRecNonFunctionMsg name =
  "`"
    ++ name
    ++ "` is bound by `let rec` but its right-hand side is not a function"

export
ambiguousShadowHelp : String
ambiguousShadowHelp =
  "bring only one of those interfaces into scope by importing the other module without naming its interface, or rename one of the methods"

export
shadowIfaceLabel : IfaceRef -> String
shadowIfaceLabel ir = match ir.irOrigin
  OriginModule m => "`\{ir.irName}` (from `\{m}`)"
  _ => "`\{ir.irName}`"

export
implHeadIndexMsg : String -> String -> String
implHeadIndexMsg head written =
  "impl head `\{head} \{written}` writes an `Authority` index, but an instance is chosen by the type's head and covers every index; write a name in the slot instead of `\{written}`"

-- the coherence error string for one conflicting pair (OverlappingImpls).  Reached
-- ONLY by the HARD class since F-3d — two mutually-⊑ (α-equal up to renaming) heads,
-- for which "make them disjoint" really is the fix, because no third impl can rank
-- them.  The ⊑-INCOMPARABLE class takes `cohIncomparableMsg` instead, whose remedy
-- is the opposite one (declare the common instance).  #614 filed the old wording as
-- an S2 precisely because it gave the disjointness advice to the incomparable class,
-- where it is both wrong and ineffective.
export
cohOverlapMsg : String -> List Mono -> List Mono -> String
cohOverlapMsg iface xs ys = match cohPpPair xs ys
  (s1, s2) =>
    "overlapping impls of \{iface}: \{s1} and \{s2} can match the same type; make them disjoint or wrap one type in a newtype"

-- a program impl α-equal to a prelude impl.  The prelude cannot be edited, so the
-- remedy is the newtype, not disjointness of the program's two impls.
export
cohPreludeOverlapMsg : String -> List Mono -> List Mono -> String
cohPreludeOverlapMsg iface xs ys = match cohPpPair xs ys
  (s1, s2) =>
    "overlapping impls of \{iface}: \{s1} and the prelude's \{s2} can match the same type; the prelude's impl cannot be replaced, so wrap the type in a newtype and implement \{iface} for that"

-- ERROR-QUALITY dim F: the actionable half, carried as structured `help` rather than
-- crammed into the message.  Both remedies are real and the FIRST one is the spec's
-- (§6.1's separating case): a third impl at the pair's common instance is ⊑ both, so
-- every goal matching both has a unique ⊑-minimum again.
-- The second clause is CONDITIONED on closedness, and that is not pedantry: the
-- first draft read "without one, a goal that matches both is rejected as ambiguous",
-- which is FALSE on exactly the shape this warning newly permits.  At a goal still
-- carrying an undetermined type the goal-site reject is gated off (§6.2 T3/T4) and
-- the selector COMMITS to the first-declared impl — `s6-2-t4-open-goal-deferred.mdk`
-- matches both and prints `1` at exit 0.  A reader told "is rejected" draws exactly
-- the wrong inference about the program in front of them.
export
cohIncomparableHelp : String
cohIncomparableHelp =
  "add an impl at the two heads' common instance so it is more specific than both, or make the two heads disjoint"

-- cross-module conflict wording: names the interface and BOTH owning modules.
export
cohCrossModuleMsg : String -> String -> String -> String
cohCrossModuleMsg iface mid1 mid2 =
  "conflicting `impl \{iface}`: defined in both `\{mid2}` and `\{mid1}`"

export
superContextUndeclaredMsg : String ->
  Bool ->
  String ->
  String ->
  String ->
  String
superContextUndeclaredMsg subject derived superGoal pred predBare
  | derived =
    "`\{subject}` (derived) must provide its superinterface `\{superGoal}`, whose instance requires `\{pred}`, which the derived impl does not declare; a `deriving` clause takes no `requires`, so write the impl by hand with `requires \{predBare}`"
  | otherwise =
    "`\{subject}` must provide its superinterface `\{superGoal}`, whose instance requires `\{pred}`, which the impl does not declare; add `requires \{predBare}` to the impl"

export
superContextNoImplMsg : String -> Bool -> String -> String -> String -> String
superContextNoImplMsg subject derived superGoal pred predBare
  | derived =
    "`\{subject}` (derived) must provide its superinterface `\{superGoal}`, whose instance requires `\{pred}`, and no impl provides it; add `impl \{predBare}`, and write the derived impl by hand if its `requires` must change"
  | otherwise =
    "`\{subject}` must provide its superinterface `\{superGoal}`, whose instance requires `\{pred}`, and no impl provides it; add `impl \{predBare}`"

export
missingImplMethodMsg : String -> List Ty -> String -> String
missingImplMethodMsg iface tys method =
  "`impl \{iface} \{joinWith " " (map ppTyAtom tys)}` is missing the method `\{method}`; define `\{method}` in the impl"

export
ordinalSentinelMsg : String
ordinalSentinelMsg =
  "internal error: the whole-program final checks (coherence, interface cycles, phantom methods, superinterface existence) were reached with an unknown module ordinal, so they cannot say what is in scope here. This is a compiler bug, not a problem with this program — please report it. The checks below this point may be incomplete"

-- e.g. ["A", "B", "A"] → "cyclic superinterface: A requires B requires A"
export
cyclicSuperIfaceMsg : List String -> String
cyclicSuperIfaceMsg path =
  "cyclic superinterface: " ++ joinWith " requires " (map backticked path)

-- #1155: names the GOAL and every competing impl head, not just the interface, so the
-- reader can find the impls that collided (ERROR-QUALITY §1: "in the user's
-- vocabulary", "actionable"). The goal's monos render through ONE shared naming
-- context so a variable in two argument positions prints as the same letter, matching
-- `cohOverlapMsg`'s declaration-time conflict rendering.
--
-- Wording is arity-neutral: three mutually incomparable impls are constructible
-- (`C (T Int b c)` / `C (T a Int c)` / `C (T a b Int)`), so every count-bearing word is
-- derived from `listLen cands`, never hardcoded to two.
--
-- The remedy clause suggests annotation rather than editing, because a competing impl
-- may be prelude or imported code the reader does not own — `KeyEntry` carries no
-- module id, so the message cannot name which impl that is.
export
ambiguousOverlapMsg : String -> List Mono -> List KeyEntry -> String
ambiguousOverlapMsg iface goals cands =
  "ambiguous instance for `\{iface}`: the goal `\{iface} \{ppPredArgsShared goals}` matches \{joinAnd (map (implHeadLabel iface) cands)}, and \{noMinimumClause (listLen cands)}; make them disjoint, or annotate this expression with a type only one of them matches"

-- "neither is more specific than the other" reads better than the general form at the
-- overwhelmingly common arity, and presupposes exactly two, so it is gated on two.
noMinimumClause : Int -> String
noMinimumClause n
  | n == 2 = "neither is more specific than the other"
  | otherwise = "none of them is more specific than all the others"

-- "A", "A and B", "A, B and C" — `joinWith " and "` gives "A and B and C" at n>=3.
joinAnd : List String -> String
joinAnd [] = ""
joinAnd [x] = x
joinAnd [x, y] = "\{x} and \{y}"
joinAnd (x :: rest) = "\{x}, \{joinAnd rest}"

implHeadLabel : String -> KeyEntry -> String
implHeadLabel iface (KeyEntry _ _ _ _ _ itys _ _) =
  "`impl \{iface} \{joinWith " " (map ppTyAtom itys)}`"

export
ambiguousImplMsg : String -> String
ambiguousImplMsg iface =
  "ambiguous instance for `"
    ++ iface
    ++ "`: the type here does not determine which impl applies; add a type annotation"

-- An interface's name qualified by its declaring module (`mb.Sz`), for a diagnostic
-- that must say WHICH declaration lacks an impl when two modules declare the same
-- spelling.  An interface with no module origin renders bare, and so does one
-- declared by the flat single-file entry: `"__user__"` is a synthetic id, not a
-- name the user wrote (`originPhrase` treats it the same way).
export
qualifiedIfaceLabel : IfaceRef -> String
qualifiedIfaceLabel ir = match ir.irOrigin
  OriginModule "__user__" => ir.irName
  OriginModule m => "\{m}.\{ir.irName}"
  _ => ir.irName

-- The goal is rendered with each declared variable under its declared name; the
-- renderer names every other variable with a letter those names leave free.
export
sigVarGoalMsg : DeclaringBinder ->
  List (String, Ty, List (String, Mono)) ->
  List Int ->
  IfaceRef ->
  List Mono ->
  String
sigVarGoalMsg binder sigTvMaps sigVarIds iface args =
  let owners = flatMap (sigVarOwner sigTvMaps) (dedupI sigVarIds)
  let named = map snd owners
  let pred =
    "\{iface.irName} \{joinWith " " (ppEach (Ref named) (Ref 0) 3 args)}"
  let vars = joinWith " and " (map (owner => "`\{snd (snd owner)}`") owners)
  match binder
    DeclaredBySignature =>
      let member = match owners
        (m, _) :: _ => m
        [] => ""
      "the body of `\{member}` requires `\{pred}`, which its signature does not declare and which only a specific \{vars} satisfies; write that type in the signature or add `\{pred} =>`"
    DeclaredByAnnotation =>
      let written = match sigTvMaps
        (_, ty, _) :: _ => ppTy ty
        [] => ""
      "this expression requires `\{pred}`, which its annotation `\{written}` does not declare and which only a specific \{vars} satisfies; write that type in the annotation or add `\{pred} =>`"

-- (member, (id, declared name)) for the signature in [sigTvMaps] that declares [id].
sigVarOwner : List (String, Ty, List (String, Mono)) ->
  Int ->
  List (String, (Int, String))
sigVarOwner [] _ = []
sigVarOwner ((m, _, tvs) :: rest) id = match findTvName id tvs
  Some n => [(m, (id, n))]
  None => sigVarOwner rest id

export
methodBodySubject : MethodBodyKind -> String -> String -> String
methodBodySubject (ImplBody _) iface mname = implSubject iface mname
methodBodySubject DefaultBody iface mname = defaultSubject iface mname

export
methodBodyLaunderMsg : MethodBodyKind -> String -> String -> List Atom -> String
methodBodyLaunderMsg (ImplBody _) iface mname escaping =
  effectLaunderMsg iface mname escaping
methodBodyLaunderMsg DefaultBody iface mname escaping =
  defaultEffectLaunderMsg (defaultSubject iface mname) escaping

effectLaunderMsg : String -> String -> List Atom -> String
effectLaunderMsg iface mname escaping =
  "effect laundering in impl of `\{mname}` for `\{iface}`: the body performs <\{renderAtoms escaping}>, which no argument sources and the method's row does not declare; declare <\{renderAtoms escaping}> in the method's row, or perform it through an argument"

export
aliasesHeadRowMsg : String -> Ty -> String
aliasesHeadRowMsg subject mty =
  "\{subject} identifies a method effect variable with the instance head's own effect-row parameter, which the declared type `\{ppTy mty}` keeps distinct; keep the method's effect variable independent of the head's"

implSubject : String -> String -> String
implSubject iface mname = "impl of `\{mname}` for `\{iface}`"

defaultSubject : String -> String -> String
defaultSubject iface mname = "default body of `\{mname}` in `\{iface}`"

export
narrowsImplHeadMsg : String -> List String -> String -> String
narrowsImplHeadMsg subject narrowed head =
  "\{subject} fixes the instance-head type \{tyVarNoun narrowed} \{quotedNames narrowed}, but the impl is declared for every type in their place; narrow the head to `\{head}`, or make the body parametric in \{quotedNames narrowed}"

export
indexEagerMsg : String -> String -> String
indexEagerMsg subject evar =
  "\{subject} performs the effect variable <\{evar}> at call time, but the signature charges <\{evar}> only in a result index, `f \{evar} ...`; defer it under the container's own <\{evar}> thunk, or charge the method's arrow, `-> <\{evar}> ...`"

tyVarNoun : List String -> String
tyVarNoun [_] = "variable"
tyVarNoun _ = "variables"

export
pinsTyvarMsg : String -> Ty -> List String -> String
pinsTyvarMsg subject mty pinned =
  "\{subject} pins the method's quantified type \{tyVarNoun pinned} \{quotedNames pinned}, which the declared type `\{ppTy mty}` leaves to the caller; make the body parametric in \{quotedNames pinned}"

export
undeclaredConstraintMsg : String -> Ty -> String -> String -> String
undeclaredConstraintMsg subject mty oiface vname =
  "\{subject} requires `\{oiface}` on the method's quantified type variable `\{vname}`, which the declared type `\{ppTy mty}` does not; add `\{oiface} \{vname} =>` to the method's signature"

export
undeclaredImplPrerequisiteMsg : String -> String -> String -> String
undeclaredImplPrerequisiteMsg subject oiface vname =
  "\{subject} requires `\{oiface}` on the instance-head type variable `\{vname}`, which the impl does not declare; add `requires \{oiface} \{vname}` to the impl"

export
implGoalFixesHeadMsg : String -> String -> List String -> String
implGoalFixesHeadMsg subject pred fixed =
  "\{subject} requires `\{pred}`, which only a specific instance-head type \{tyVarNoun fixed} \{quotedNames fixed} satisfies, but the impl is declared for every type in their place; make the body parametric in \{quotedNames fixed}, or narrow the head"

export
undeclaredImplPredicateMsg : String -> String -> String
undeclaredImplPredicateMsg subject pred =
  "\{subject} requires `\{pred}` on the instance head's type variables, which the impl does not declare; add `requires \{pred}` to the impl"

export
collapsesTyvarsMsg : String -> Ty -> String
collapsesTyvarsMsg subject mty =
  "\{subject} identifies quantified type variables that the declared type `\{ppTy mty}` keeps distinct; keep them independent in the body"

defaultEffectLaunderMsg : String -> List Atom -> String
defaultEffectLaunderMsg subject escaping =
  "\{subject} launders an effect: the body performs <\{renderAtoms escaping}>, which no argument sources and the method's row does not declare; declare <\{renderAtoms escaping}> in the method's row, or perform it through an argument"

export
collapsesEffvarsMsg : String -> Ty -> String
collapsesEffvarsMsg subject mty =
  "\{subject} identifies effect variables that the declared type `\{ppTy mty}` keeps distinct; keep the body's effects on the variable the signature declares at each position"

export
effVarLaunderMsg : String -> String -> List Atom -> String
effVarLaunderMsg subject evar escaping =
  "\{subject} launders an effect: the body performs <\{renderAtoms escaping}> inside the effect variable <\{evar}> at a position whose declared row does not include it; declare <\{renderAtoms escaping}> at that position, or perform it through an argument"

-- Which arrow a spine row belongs to, for a signature with more than one: a
-- row written on another arrow of the declaration does not cover it.
export
ffiArrowNote : Int -> Int -> String
ffiArrowNote i arrows =
  if arrows > 1 then
    " on the result of argument \{display i} of \{display arrows}"
  else
    ""

-- #797: [tail] renders alongside the atoms so an argument-carried open row —
-- the one shape that still reaches this message with a tail — reports the row
-- that was actually written (`<e>`, `<Stdout | e>`) instead of the false `<>`.
-- A closed row passes no tail at all and renders exactly as before.
export
effectEscapeMsg : String -> List Atom -> List String -> List Atom -> String
effectEscapeMsg name declared tail extras =
  "`\{name}` performs <\{renderAtoms extras}> but its signature allows only \{renderDeclaredRow declared tail}; add <\{renderAtoms extras}> to the declared row"

renderDeclaredRow : List Atom -> List String -> String
renderDeclaredRow declared [] = "<\{renderAtoms declared}>"
renderDeclaredRow [] tails = "<\{joinWith " | " tails}>"
renderDeclaredRow declared tails =
  "<\{renderAtoms declared} | \{joinWith " | " tails}>"

export
sigOverExpansiveMsg : String -> Ty -> String
sigOverExpansiveMsg name ty =
  "the signature of `\{name}` is polymorphic (`\{ppTy ty}`) but its body is not a value, so it cannot be generalized; give `\{name}` a parameter or declare a monomorphic type"

export
sigTooGeneralMsg : String -> Ty -> String
sigTooGeneralMsg name ty =
  "the signature of `\{name}` is more general than its body: `\{ppTy ty}` claims type variables that inference makes the same type"

export
annotTooGeneralMsg : Ty -> String
annotTooGeneralMsg ty =
  "type annotation `"
    ++ ppTy ty
    ++ "` is more polymorphic than the expression: a type variable in it is a specific type, or two of its variables are the same type"

-- `T-REQUIRES-UNROUTED` (issue 1564).  Root-cause-honest: it must NOT say the impl is
-- missing, because it is not — saying so would send the reader off to write an `impl`
-- that already exists.  It names the impl as present, names the limitation as the
-- compiler's, and gives the edit that actually works today: import the defining module
-- (MEASURED on 1564's fixture — adding `import wrapimpl` to `nest.mdk` alone restores the
-- dict parameter and the program prints `wrap(int)`).
--
-- One string, two call sites, and that sharing is load-BEARING — see
-- `unroutedGroundReqs`.  `pushTypeErrorOnceAt` dedups on MESSAGE TEXT and a DEFERRED goal
-- reaches both guards, so any wording that differs between them DOUBLE-REPORTS at one
-- span (MEASURED: two `T-REQUIRES-UNROUTED` diagnostics at range 2:16-2:21, and #1564's
-- must-fail pin flipped to DRAINED on a live bug).  Reword it here or not at all.
--
-- ⚖️ SA-5 (RUN-055) — two clauses were wrong, and both were measured wrong, not argued:
--  1. *"route its evidence into the module where this binding is GENERALIZED"* is false
--     at the ground site: nothing is generalized at a fully-concrete use site, and that
--     site has reached this text since SA-1.  It now says "to this code".
--  2. The remedy sent the DECLARED-GIVEN shape to a dead end.  MEASURED on
--     `export nest : Tag (Wrap a) => a -> String`: adding the advised `import wrapimpl`
--     to `nest.mdk` does not make the program compile — it produces a DIFFERENT error,
--     *"Could not deduce 'Tag a' from the signature of 'nest' … add 'Tag a =>'"*.  The
--     import is necessary and is real progress; it is just not sufficient when the
--     signature is hand-written, because a declared context must carry every constraint
--     the body needs.  Saying only the first half reads as "do this and it works", so the
--     reader concludes the advice failed.  The text now says the import may not be enough
--     for a signatured binding and that the next error names the missing constraint —
--     which is what actually happens.
-- Do NOT fix (2) by splitting the text per shape.  That is exactly the double-report
-- above.  The wording must be true of the residual, ground and declared-given shapes at
-- once, which is why it is conditional ("if this binding carries a signature") rather
-- than shape-specific.
export
requiresUnroutedMsg : IfaceRef -> List Mono -> String
requiresUnroutedMsg iface args =
  "cannot pass a dictionary for `\{iface.irName} \{ppPredArgsShared args}`: a matching `impl \{iface.irName} ...` exists but is declared in a module this one does not import; import that module here, and if this binding has a signature, declare the constraint there too"

export
missingConstraintVecMsg : String -> String -> List String -> String
missingConstraintVecMsg name iface varNames =
  let pred = joinWith " " (iface :: varNames)
  "the body of `\{name}` requires `\{pred}`, which its signature does not declare; add `\{pred} =>`"

-- recover the sig-tyvar NAME for a constraint var id (for a readable message);
-- falls back to "a" if the id isn't found among the member's sig tyvars.
export
varNameForId : List (String, Ty, List (String, Mono)) -> String -> Int -> String
varNameForId sigTvMaps m id = match findSigTvMap m sigTvMaps
  None => "a"
  Some tvMap => match findTvName id tvMap
    None => "a"
    Some n => n

findSigTvMap : String ->
  List (String, Ty, List (String, Mono)) ->
  Option (List (String, Mono))
findSigTvMap _ [] = None
findSigTvMap m ((n, _, tvMap) :: rest)
  | n == m = Some tvMap
  | otherwise = findSigTvMap m rest

export
missingConstraintMsg : String -> String -> String -> String
missingConstraintMsg name iface varName =
  "the body of `\{name}` requires `\{iface} \{varName}`, which its signature does not declare; add `\{iface} \{varName} =>`"

-- wording mirrors `cohCrossModuleMsg`'s shape — name the thing, then name BOTH owners —
-- without reusing its sentence, which is about a conflicting `impl` and would misname
-- this cause.
export
ambigReexportMsg : String -> String -> List String -> String
ambigReexportMsg n depId mids =
  "ambiguous `\{n}` imported from `\{depId}`: defined in both \{joinAnd (map backticked mids)}"

export
ambigReexportHelp : String -> String -> List String -> String
ambigReexportHelp n depId mids =
  "`\{depId}` re-exports more than one `\{n}`; import the definition you mean directly, as in `import \{firstMid mids}.{\{n}}`"

firstMid : List String -> String
firstMid (m :: _) = m
firstMid [] = "<module>"

export
locGoalKey : Option Loc -> String
locGoalKey None = ""
locGoalKey (Some (Loc file sl sc el ec)) =
  "\{file}:\{intToString sl}:\{intToString sc}:\{intToString el}:\{intToString ec}"

allDigits : String -> Bool
allDigits n = stringLength n > 0 && allDigitsFrom n 0

allDigitsFrom : String -> Int -> Bool
allDigitsFrom n i
  | i >= stringLength n = True
  | otherwise =
    let c = stringSlice i (i + 1) n
    c >= "0" && c <= "9" && allDigitsFrom n (i + 1)

export
backticked : String -> String
backticked s = "`\{s}`"

-- Chunk C: recover the ultimate callee name of an application spine (the
-- leftmost head), stripping transparent wrappers.  `None` when the head is not
-- a plain variable (so no name to blame in an over-application message).
export
appSpineName : Expr -> Option String
appSpineName (ELoc _ e) = appSpineName e
appSpineName (EDoOrigin _ e) = appSpineName e
appSpineName (EAnnot e _) = appSpineName e
appSpineName (EApp f _) = appSpineName f
appSpineName (EVar n) = Some n
appSpineName (EVarId n _) = Some n
appSpineName (EVarAt n _) = Some n
-- #2705: every driver marks now, so a callee can arrive as the marked occurrence
-- shape; it still has the name a message wants.
appSpineName (EMethodAt n _ _) = Some n
appSpineName (EDictAt n _) = Some n
appSpineName _ = None

-- The ordinal of the zero-based position [i].
export
ordinalWord : Int -> String
ordinalWord 0 = "first"
ordinalWord 1 = "second"
ordinalWord 2 = "third"
ordinalWord 3 = "fourth"
ordinalWord 4 = "fifth"
ordinalWord i = "\{intToString (i + 1)}th"

-- #1952: a MULTI-ARGUMENT goal names its arguments at ARGUMENT precedence, so
-- `Conv (Wrap a) Int` no longer prints as `Conv for Wrap a Int` — which reads as a
-- three-argument predicate and cannot be matched against the impl heads printed beside
-- it.  The length gate is the whole disambiguation and is not a hedge: with exactly
-- ONE argument the entire remainder of the message IS that argument, so there is nothing
-- to mis-group, and `ppMonosShared` is kept there so every existing single-argument
-- reject (`No impl of Eq for List Int`) renders byte-identically.  This message is prose,
-- not source — `renderConstraintCtx` is the surface that owes parens unconditionally.
export
noImplFoundMsg : String -> List Mono -> String
noImplFoundMsg iface [arg] = "no impl of \{iface} for \{ppMonosShared [arg]}"
noImplFoundMsg iface args = "no impl of \{iface} for \{ppPredArgsShared args}"

-- Roadmap #18a: only a DERIVABLE interface may be suggested via `deriving`.  A
-- `deriving <iface>` for anything outside that set is silently DROPPED by desugar's
-- `deriveImpls` (its `deriveForData`/`deriveForNewtype` return None), so the old
-- unconditional "add 'deriving X'" sent the user down a dead end for every other
-- interface — including the `Semigroup` reject `a ++ b` now raises, and the
-- pre-existing user-interface case (`No impl of Printable for Foo`).  For those the
-- only real fix is to write the impl, so that is all we advise.
export
noImplAdvice : String -> String -> String
noImplAdvice iface n
  | derivableIface iface =
    "add `deriving \{iface}` to `\{n}` or write `impl \{iface} \{n}`"
  | otherwise = "write `impl \{iface} \{n}`"

-- The interfaces desugar.mdk can actually synthesize an impl for (deriveForData /
-- deriveForNewtype).  `Generic` is data-only; the other four cover both.
export
derivableIface : String -> Bool
derivableIface iface =
  contains iface ["Eq", "Ord", "Debug", "Display", "Generic"]

export
quotedNames : List String -> String
quotedNames names = joinWith ", " (map (n => "`" ++ n ++ "`") names)

export
locKey : Option Loc -> String
locKey None = ""
locKey (Some (Loc file line col _ _)) =
  "\{file}:\{intToString line}:\{intToString col}"

-- Membership key for "this message at this span".  A located diagnostic is a
-- duplicate only of the same text at the same span, so two sites with identical
-- text each report; an unlocated one folds on text alone.
export
msgAtKey : String -> Option Loc -> String
msgAtKey msg at = "\{msg}\t@@\t\{locKey at}"

-- Diagnostic text with every renamed local binder (`f$m$3$lb`) shown as written.
writtenNames : String -> String
writtenNames text = match splitOnChar '$' text
  [only] => only
  parts => dropRenameSuffixes parts

dropRenameSuffixes : List String -> String
dropRenameSuffixes [] = ""
dropRenameSuffixes [a] = a
dropRenameSuffixes (a :: _ :: n :: lb :: more)
  | allDigits n && startsWith "lb" lb =
    a ++ dropRenameSuffixes (stringSlice 2 (stringLength lb) lb :: more)
dropRenameSuffixes (a :: rest) = "\{a}$\{dropRenameSuffixes rest}"

-- A diagnostic as the user reads it: binder names as written.
export
writtenDiag : TcDiag -> TcDiag
writtenDiag (TcDiag code sev loc msg help fix) =
  TcDiag code sev loc (writtenNames msg) (map writtenNames help) fix

export
findTupleCand : String ->
  List (Mono, String, Option (Loc, String)) ->
  Option (String, Option (Loc, String))
findTupleCand _ [] = None
findTupleCand key ((res, help, fix) :: rest)
  | ppMono (normalize res) == key = Some (help, fix)
  | otherwise = findTupleCand key rest

-- prepend an optional bare-message diagnostic (code, severity, help) to a TcDiag list.
export
prependDiagOpt : String ->
  Int ->
  Option String ->
  Option String ->
  List TcDiag ->
  List TcDiag
prependDiagOpt _ _ _ None ds = ds
prependDiagOpt code sev help (Some msg) ds =
  writtenDiag (TcDiag code sev None msg help None) :: ds
# DESUGAR
(DUse false (UseGroup ("types" "tc_mono") ((mem "cohPpPair" false) (mem "dedupI" false) (mem "findTvName" false) (mem "firstIdConflict" false) (mem "headIdConflict" false) (mem "headTyconNameMono" false) (mem "isPreludeOrigin" false) (mem "recordOwnerModule" false) (mem "recordResultMono" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "authTermsSurface" false) (mem "EffAtomTy" true) (mem "EffParamTy" true) (mem "Expr" true) (mem "KindAnn" true) (mem "kindAnnSource" false) (mem "Lit" true) (mem "Loc" true) (mem "patternMark" false) (mem "qualifierSource" false) (mem "TabKey" true) (mem "tabKeyName" false) (mem "Ty" true) (mem "TyConOrigin" true))))
(DUse false (UseGroup ("types" "repr") ((mem "normalize" false) (mem "IfaceRef" true) (mem "Mono" true) (mem "ppAuthority" false) (mem "ppConName" false) (mem "ppEach" false) (mem "ppEffArgFmt" false) (mem "ppEffInsideTy" false) (mem "ppEffvarName" false) (mem "ppGo" false) (mem "ppMono" false) (mem "ppMonosShared" false) (mem "ppPredArgsShared" false) (mem "ppTy" false) (mem "ppTyAtom" false) (mem "tupleHeadTagTc" false))))
(DUse false (UseGroup ("types" "tc_types") ((mem "DeclaringBinder" true) (mem "KeyEntry" false) (mem "Kind" true) (mem "MethodBodyKind" true) (mem "RecordInfo" false))))
(DUse false (UseGroup ("types" "publish") ((mem "TcDiag" true))))
(DUse false (UseGroup ("support" "util") ((mem "contains" false) (mem "dedup" false) (mem "dedupBy" false) (mem "escStr" false) (mem "isEmptyL" false) (mem "isNonEmptyL" false) (mem "joinWith" false) (mem "listLen" false) (mem "reverseL" false) (mem "sortUniqS" false) (mem "splitOnChar" false) (mem "startsWith" false))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "Atom" true) (mem "effLabelName" false) (mem "Effvar" true) (mem "renderAtoms" false))))
(DUse false (UseGroup ("types" "effect_authority") ((mem "authIsTop" false) (mem "Authority" true))))
(DTypeSig true "effectInclusionMsg" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))))
(DFunDef false "effectInclusionMsg" ((PVar "name") (PVar "escaping") (PList (PVar "required") (PVar "allowed"))) (EIf (EApp (EVar "isNonEmptyL") (EVar "escaping")) (EBlock (DoLet false false (PVar "labels") (EApp (EVar "renderAtoms") (EVar "escaping"))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "` performs <"))) (EApp (EVar "display") (EVar "labels"))) (ELit (LString "> on a caller-chosen row "))) (EApp (EVar "display") (EApp (EVar "rowText") (EVar "allowed")))) (ELit (LString "; "))) (EApp (EVar "display") (EApp (EApp (EVar "declareRemedy") (EVar "labels")) (EVar "allowed")))) (ELit (LString ", or perform it through an argument"))))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "` runs the caller-chosen row "))) (EApp (EVar "display") (EApp (EVar "rowText") (EVar "required")))) (ELit (LString " where only "))) (EApp (EVar "display") (EApp (EVar "rowText") (EVar "allowed")))) (ELit (LString " is allowed; declare it on the arrow that runs it, `-> "))) (EApp (EVar "display") (EApp (EVar "rowText") (EVar "required")))) (ELit (LString " ...`")))))
(DFunDef false "effectInclusionMsg" ((PVar "name") PWild (PVar "rows")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "cannot prove effect row inclusion in `")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "`: "))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EVar "rows")))) (ELit (LString ""))))
(DTypeSig false "rowText" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "rowText" ((PVar "s")) (EIf (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 1))) (EVar "s")) (ELit (LString "<"))) (EVar "s") (EBinOp "++" (EBinOp "++" (ELit (LString "<")) (EApp (EVar "display") (EVar "s"))) (ELit (LString ">")))))
(DTypeSig false "declareRemedy" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "declareRemedy" ((PVar "labels") (PVar "allowed")) (EIf (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 1))) (EVar "allowed")) (ELit (LString "<"))) (EBinOp "++" (EBinOp "++" (ELit (LString "declare <")) (EApp (EVar "display") (EVar "labels"))) (ELit (LString "> in that row"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "declare it, `<")) (EApp (EVar "display") (EVar "labels"))) (ELit (LString " | "))) (EApp (EVar "display") (EVar "allowed"))) (ELit (LString ">`")))))
(DTypeSig true "patternIndexMsg" (TyFun (TyCon "Authority") (TyCon "String")))
(DFunDef false "patternIndexMsg" ((PVar "term")) (EBlock (DoLet false false (PVar "t") (EApp (EApp (EApp (EVar "authorityTermTextIn") (EApp (EVar "Ref") (EListLit))) (EApp (EVar "Ref") (ELit (LInt 0)))) (EVar "term"))) (DoExpr (EBinOp "++" (EBinOp "++" (ELit (LString "a pattern-ranging `Authority L*` index is equated with ")) (EApp (EVar "display") (EVar "t"))) (ELit (LString ", which is not a pattern; write a pattern there, such as `\"data/*\"` or `*`"))))))
(DTypeSig true "renderFlatRow" (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Effvar")))) (TyCon "String")))
(DFunDef false "renderFlatRow" ((PVar "f")) (EBlock (DoLet false false (PVar "ctx") (EApp (EVar "Ref") (EListLit))) (DoLet false false (PVar "cnt") (EApp (EVar "Ref") (ELit (LInt 0)))) (DoExpr (EApp (EApp (EVar "ppEffArgFmt") (EApp (EVar "renderAtomsOrEmpty") (EApp (EVar "fst") (EVar "f")))) (EApp (EApp (EVar "joinWith") (ELit (LString " | "))) (EApp (EApp (EVar "map") (ELam ((PVar "m")) (EApp (EApp (EApp (EVar "ppEffvarName") (EVar "ctx")) (EVar "cnt")) (EVar "m")))) (EApp (EVar "snd") (EVar "f"))))))))
(DTypeSig false "renderAtomsOrEmpty" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "String")))
(DFunDef false "renderAtomsOrEmpty" ((PList)) (ELit (LString "")))
(DFunDef false "renderAtomsOrEmpty" ((PVar "ls")) (EApp (EVar "renderAtoms") (EVar "ls")))
(DTypeSig true "joinMismatchMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "joinMismatchMsg" ((PVar "a") (PVar "b")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "effect rows ")) (EApp (EVar "display") (EVar "a"))) (ELit (LString " and "))) (EApp (EVar "display") (EVar "b"))) (ELit (LString " cannot be made equal: each carries an effect variable the other has no room for; keep the method's effect variables distinct, or join them in the result index, `f (e | e2) b`"))))
(DTypeSig true "indexRowMismatchMsg" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "String"))))
(DFunDef false "indexRowMismatchMsg" ((PVar "l1") (PVar "l2")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "effect index mismatch: <")) (EApp (EVar "display") (EApp (EVar "renderAtoms") (EVar "l1")))) (ELit (LString "> vs <"))) (EApp (EVar "display") (EApp (EVar "renderAtoms") (EVar "l2")))) (ELit (LString ">; an effect row in a type argument is invariant, so write the same row on both sides or use a row variable, "))) (EApp (EVar "display") (EApp (EVar "openRowHint") (EVar "l1")))) (ELit (LString ""))))
(DTypeSig false "openRowHint" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "String")))
(DFunDef false "openRowHint" ((PList)) (ELit (LString "`e`")))
(DFunDef false "openRowHint" ((PVar "atoms")) (EBinOp "++" (EBinOp "++" (ELit (LString "`<")) (EApp (EVar "display") (EApp (EVar "renderAtoms") (EVar "atoms")))) (ELit (LString " | e>`"))))
(DTypeSig true "closedRowMismatchMsg" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "String"))))
(DFunDef false "closedRowMismatchMsg" ((PVar "l1") (PVar "l2")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "effect rows <")) (EApp (EVar "display") (EApp (EVar "renderAtoms") (EVar "l1")))) (ELit (LString "> and <"))) (EApp (EVar "display") (EApp (EVar "renderAtoms") (EVar "l2")))) (ELit (LString "> cannot be made equal: the two values must have one type, and this position neither widens nor narrows a row; write the same row on both sides"))))
(DTypeSig true "patternDomainMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "patternDomainMsg" ((PVar "written") (PVar "l")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "display") (EVar "written"))) (ELit (LString "` ranges over patterns, but `"))) (EApp (EVar "display") (EVar "l"))) (ELit (LString "` is not a `Prefix` domain and has none; drop the `*`"))))
(DTypeSig true "authorityAtomicLabelMsg" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "authorityAtomicLabelMsg" ((PVar "l")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`Authority ")) (EApp (EVar "display") (EVar "l"))) (ELit (LString "` needs a domain, but `"))) (EApp (EVar "display") (EVar "l"))) (ELit (LString "` is an atomic label and declares none; declare it `effect "))) (EApp (EVar "display") (EVar "l"))) (ELit (LString " Prefix`"))))
(DTypeSig true "phantomExportMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "phantomExportMsg" ((PVar "tyName") (PVar "ctor") (PVar "p")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "constructor `")) (EApp (EVar "display") (EVar "ctor"))) (ELit (LString "` of public type `"))) (EApp (EVar "display") (EVar "tyName"))) (ELit (LString "` carries its authority parameter `"))) (EApp (EVar "display") (EVar "p"))) (ELit (LString "` in no field, so another module could invent an authority; export `"))) (EApp (EVar "display") (EVar "tyName"))) (ELit (LString "` abstractly with `export data`, or give `"))) (EApp (EVar "display") (EVar "ctor"))) (ELit (LString "` a field that carries `"))) (EApp (EVar "display") (EVar "p"))) (ELit (LString "`"))))
(DTypeSig true "authorityParamAsRowMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "authorityParamAsRowMsg" ((PVar "name") (PVar "p")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "type `")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "` declares `"))) (EApp (EVar "display") (EVar "p"))) (ELit (LString "` as an authority, but a field uses it as an effect row; write a different variable for the row"))))
(DTypeSig true "authorityParamAsTypeMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "authorityParamAsTypeMsg" ((PVar "name") (PVar "p")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "type `")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "` declares `"))) (EApp (EVar "display") (EVar "p"))) (ELit (LString "` as an authority, but a field uses it as a type; write a different variable for the type"))))
(DTypeSig true "ifaceParamAuthorityKindMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "ifaceParamAuthorityKindMsg" ((PVar "name") (PVar "p")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "interface `")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "` declares `"))) (EApp (EVar "display") (EVar "p"))) (ELit (LString "` as an authority, but an interface parameter is a type or a graded constructor; index a data type with `("))) (EApp (EVar "display") (EVar "p"))) (ELit (LString " : Authority L)` and implement the interface for it"))))
(DTypeSig true "unannotatedRowParamMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "unannotatedRowParamMsg" ((PVar "name") (PVar "p")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "type parameter `")) (EApp (EVar "display") (EVar "p"))) (ELit (LString "` of `"))) (EApp (EVar "display") (EVar "name"))) (ELit (LString "` is used as an effect row, but its head does not declare it one; declare the head as `"))) (EApp (EVar "display") (EVar "name"))) (ELit (LString " ("))) (EApp (EVar "display") (EVar "p"))) (ELit (LString " : Effect) ...`"))))
(DTypeSig true "typeParamAsRowMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "typeParamAsRowMsg" ((PVar "name") (PVar "p")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "type parameter `")) (EApp (EVar "display") (EVar "p"))) (ELit (LString "` of `"))) (EApp (EVar "display") (EVar "name"))) (ELit (LString "` is declared `("))) (EApp (EVar "display") (EVar "p"))) (ELit (LString " : Type)` but is used as an effect row; declare it `("))) (EApp (EVar "display") (EVar "p"))) (ELit (LString " : Effect)`"))))
(DTypeSig true "effectParamAsTypeMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "effectParamAsTypeMsg" ((PVar "name") (PVar "p")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "type parameter `")) (EApp (EVar "display") (EVar "p"))) (ELit (LString "` of `"))) (EApp (EVar "display") (EVar "name"))) (ELit (LString "` is declared `("))) (EApp (EVar "display") (EVar "p"))) (ELit (LString " : Effect)` but is used as an ordinary type; drop the annotation, or move `"))) (EApp (EVar "display") (EVar "p"))) (ELit (LString "` into an effect position such as `Unit -> <"))) (EApp (EVar "display") (EVar "p"))) (ELit (LString "> a`"))))
(DTypeSig true "effectArrowOnDataHeadMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "KindAnn") (TyCon "String")))))
(DFunDef false "effectArrowOnDataHeadMsg" ((PVar "name") (PVar "p") (PVar "k")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "type parameter `")) (EApp (EVar "display") (EVar "p"))) (ELit (LString "` of `"))) (EApp (EVar "display") (EVar "name"))) (ELit (LString "` is declared with kind `"))) (EApp (EVar "display") (EApp (EVar "kindAnnSource") (EVar "k")))) (ELit (LString "`, but an arrow kind containing `Effect` is allowed on interface heads only; declare it `Effect` or an Effect-free kind"))))
(DTypeSig true "ifaceSlotDeclaredTypeMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "KindAnn") (TyCon "String")))))
(DFunDef false "ifaceSlotDeclaredTypeMsg" ((PVar "name") (PVar "p") (PVar "k")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "type parameter `")) (EApp (EVar "display") (EVar "p"))) (ELit (LString "` of interface `"))) (EApp (EVar "display") (EVar "name"))) (ELit (LString "` is declared `("))) (EApp (EVar "display") (EVar "p"))) (ELit (LString " : "))) (EApp (EVar "display") (EApp (EVar "kindAnnSource") (EVar "k")))) (ELit (LString ")`, but a method uses one of its `Type` slots as an effect row; declare that slot `Effect`"))))
(DTypeSig true "ifaceParamEffectKindMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "ifaceParamEffectKindMsg" ((PVar "name") (PVar "p")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "type parameter `")) (EApp (EVar "display") (EVar "p"))) (ELit (LString "` of interface `"))) (EApp (EVar "display") (EVar "name"))) (ELit (LString "` is declared `("))) (EApp (EVar "display") (EVar "p"))) (ELit (LString " : Effect)`, but an interface parameter is a type constructor; write `("))) (EApp (EVar "display") (EVar "p"))) (ELit (LString " : Effect -> Type -> Type)` for an effect-indexed constructor"))))
(DTypeSig true "unannotatedGradedParamMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Kind")) (TyCon "String")))))
(DFunDef false "unannotatedGradedParamMsg" ((PVar "name") (PVar "p") (PVar "inferred")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "type parameter `")) (EApp (EVar "display") (EVar "p"))) (ELit (LString "` of interface `"))) (EApp (EVar "display") (EVar "name"))) (ELit (LString "` is used as an effect-indexed constructor, but its head does not declare it one; declare the head as `"))) (EApp (EVar "display") (EVar "name"))) (ELit (LString " ("))) (EApp (EVar "display") (EVar "p"))) (ELit (LString " : "))) (EApp (EVar "display") (EApp (EVar "renderKindArrow") (EVar "inferred")))) (ELit (LString ") ...`"))))
(DTypeSig true "requiresKindMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "requiresKindMsg" ((PVar "name") (PVar "sh")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "interface `")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "` requires `"))) (EApp (EVar "display") (EVar "sh"))) (ELit (LString "` at a parameter whose kind differs from `"))) (EApp (EVar "display") (EVar "sh"))) (ELit (LString "`'s own, and there is no coercion between `Type` and `Effect`; declare both heads at the same kind"))))
(DTypeSig true "argAtomsMsgFor" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "String"))))))
(DFunDef false "argAtomsMsgFor" ((PCon "Some" (PVar "iface")) (PVar "mname") (PVar "v") (PVar "esc")) (EApp (EApp (EApp (EApp (EVar "argAtomsUncoveredMsg") (EVar "iface")) (EVar "mname")) (EVar "v")) (EVar "esc")))
(DFunDef false "argAtomsMsgFor" ((PCon "None") (PVar "fname") (PVar "v") (PVar "esc")) (EApp (EApp (EApp (EVar "argAtomsUncoveredFnMsg") (EVar "fname")) (EVar "v")) (EVar "esc")))
(DTypeSig false "argAtomsUncoveredFnMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "String")))))
(DFunDef false "argAtomsUncoveredFnMsg" ((PVar "fname") (PVar "v") (PVar "esc")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "effect variable <")) (EApp (EVar "display") (EVar "v"))) (ELit (LString "> in function `"))) (EApp (EVar "display") (EVar "fname"))) (ELit (LString "` carries <"))) (EApp (EVar "display") (EApp (EVar "renderAtoms") (EVar "esc")))) (ELit (LString "> at an argument position, but a row carrying <"))) (EApp (EVar "display") (EVar "v"))) (ELit (LString "> does not include it; declare <"))) (EApp (EVar "display") (EApp (EVar "renderAtoms") (EVar "esc")))) (ELit (LString "> at every row where <"))) (EApp (EVar "display") (EVar "v"))) (ELit (LString "> appears"))))
(DTypeSig true "argOnlyEffVarMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "argOnlyEffVarMsg" ((PVar "iface") (PVar "mname") (PVar "v")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "argument-only effect variable <")) (EApp (EVar "display") (EVar "v"))) (ELit (LString "> in method `"))) (EApp (EVar "display") (EVar "mname"))) (ELit (LString "` of interface `"))) (EApp (EVar "display") (EVar "iface"))) (ELit (LString "`: it rides an argument but appears in none of the method's own effect rows; thread it through the method's row, `-> <"))) (EApp (EVar "display") (EVar "v"))) (ELit (LString "> ...`"))))
(DTypeSig false "argAtomsUncoveredMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "String"))))))
(DFunDef false "argAtomsUncoveredMsg" ((PVar "iface") (PVar "mname") (PVar "v") (PVar "esc")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "effect variable <")) (EApp (EVar "display") (EVar "v"))) (ELit (LString "> in method `"))) (EApp (EVar "display") (EVar "mname"))) (ELit (LString "` of interface `"))) (EApp (EVar "display") (EVar "iface"))) (ELit (LString "` carries <"))) (EApp (EVar "display") (EApp (EVar "renderAtoms") (EVar "esc")))) (ELit (LString "> at an argument position, but a method row carrying <"))) (EApp (EVar "display") (EVar "v"))) (ELit (LString "> does not include it; declare <"))) (EApp (EVar "display") (EApp (EVar "renderAtoms") (EVar "esc")))) (ELit (LString "> at every row where <"))) (EApp (EVar "display") (EVar "v"))) (ELit (LString "> appears"))))
(DTypeSig false "renderEffTailVars" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "renderEffTailVars" ((PVar "vs")) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "map") (ELam ((PVar "v")) (EBinOp "++" (EBinOp "++" (ELit (LString "<")) (EApp (EVar "display") (EVar "v"))) (ELit (LString ">"))))) (EVar "vs"))))
(DTypeSig true "effectUndeterminedMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))))
(DFunDef false "effectUndeterminedMsg" ((PVar "iface") (PVar "mname") (PVar "vars")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "under-determined effect variable ")) (EApp (EVar "display") (EApp (EVar "renderEffTailVars") (EVar "vars")))) (ELit (LString " in method `"))) (EApp (EVar "display") (EVar "mname"))) (ELit (LString "` of interface `"))) (EApp (EVar "display") (EVar "iface"))) (ELit (LString "`: it appears only in the return type, pinned by no argument; use a concrete row such as `<Stdout>`, or thread it through a callback `a -> <e> b`"))))
(DTypeSig true "kindName" (TyFun (TyCon "Kind") (TyCon "String")))
(DFunDef false "kindName" ((PCon "KType")) (ELit (LString "Type")))
(DFunDef false "kindName" ((PCon "KRow")) (ELit (LString "Effect")))
(DFunDef false "kindName" ((PCon "KAuth" (PVar "l") (PVar "pat"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Authority ")) (EApp (EVar "display") (EApp (EVar "effLabelName") (EVar "l")))) (ELit (LString ""))) (EApp (EVar "display") (EApp (EVar "patternMark") (EVar "pat")))) (ELit (LString ""))))
(DTypeSig true "renderKindArrow" (TyFun (TyApp (TyCon "List") (TyCon "Kind")) (TyCon "String")))
(DFunDef false "renderKindArrow" ((PVar "ks")) (EApp (EApp (EVar "joinWith") (ELit (LString " -> "))) (EBinOp "++" (EApp (EApp (EVar "map") (EVar "kindName")) (EVar "ks")) (EListLit (ELit (LString "Type"))))))
(DTypeSig true "implKindMismatchMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Kind")) (TyFun (TyApp (TyCon "List") (TyCon "Kind")) (TyCon "String")))))))
(DFunDef false "implKindMismatchMsg" ((PVar "iface") (PVar "ctor") (PVar "nApplied") (PVar "want") (PVar "got")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "instance head has the wrong kind for interface `")) (EApp (EVar "display") (EVar "iface"))) (ELit (LString "`: its type parameter is graded, kind `"))) (EApp (EVar "display") (EApp (EVar "renderKindArrow") (EVar "want")))) (ELit (LString "`, but "))) (EApp (EVar "display") (EApp (EApp (EApp (EVar "implHeadKindClause") (EVar "ctor")) (EVar "nApplied")) (EVar "got")))) (ELit (LString "; "))) (EApp (EVar "display") (EApp (EApp (EApp (EVar "implKindMismatchFix") (EVar "iface")) (EVar "ctor")) (EVar "nApplied")))) (ELit (LString ""))))
(DTypeSig false "argumentNoun" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "argumentNoun" ((PVar "n")) (EIf (EBinOp "==" (EVar "n") (ELit (LInt 1))) (ELit (LString "argument")) (ELit (LString "arguments"))))
(DTypeSig false "implHeadKindClause" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Kind")) (TyCon "String")))))
(DFunDef false "implHeadKindClause" ((PVar "ctor") (PVar "nApplied") (PVar "got")) (EIf (EBinOp "<=" (EVar "nApplied") (ELit (LInt 0))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "display") (EApp (EVar "ppConName") (EVar "ctor")))) (ELit (LString "` has kind `"))) (EApp (EVar "display") (EApp (EVar "renderKindArrow") (EVar "got")))) (ELit (LString "`"))) (EIf (EVar "otherwise") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "this head applies ")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "nApplied")))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EVar "argumentNoun") (EVar "nApplied")))) (ELit (LString " to `"))) (EApp (EVar "display") (EApp (EVar "ppConName") (EVar "ctor")))) (ELit (LString "`, leaving kind `"))) (EApp (EVar "display") (EApp (EVar "renderKindArrow") (EVar "got")))) (ELit (LString "`"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "implKindMismatchFix" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "implKindMismatchFix" ((PVar "iface") (PVar "ctor") (PVar "nApplied")) (EIf (EBinOp ">" (EVar "nApplied") (ELit (LInt 0))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "a graded interface binds the whole row-indexed family, so write `impl ")) (EApp (EVar "display") (EVar "iface"))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EVar "ppConName") (EVar "ctor")))) (ELit (LString "` with no arguments"))) (EIf (EVar "otherwise") (EBinOp "++" (EBinOp "++" (ELit (LString "give `")) (EApp (EVar "display") (EApp (EVar "ppConName") (EVar "ctor")))) (ELit (LString "` a parameter used in an effect position at each `Row` slot, such as a field `Unit -> <e> a`, or implement a non-graded interface for it"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "implTupleHeadKindMsg" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Kind")) (TyCon "String")))))
(DFunDef false "implTupleHeadKindMsg" ((PVar "iface") (PVar "n") (PVar "want")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "instance head `")) (EApp (EVar "display") (EApp (EVar "ppConName") (EApp (EVar "tupleHeadTagTc") (EVar "n"))))) (ELit (LString "` has the wrong kind for interface `"))) (EApp (EVar "display") (EVar "iface"))) (ELit (LString "`: its type parameter is graded, kind `"))) (EApp (EVar "display") (EApp (EVar "renderKindArrow") (EVar "want")))) (ELit (LString "`, but a tuple is kind `Type`; implement a non-graded interface for it, or use a row-indexed data type as the head"))))
(DTypeSig true "binderDomainTypeMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "binderDomainTypeMsg" ((PVar "n") (PVar "ty")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "named argument `")) (EApp (EVar "display") (EVar "n"))) (ELit (LString "` has type `"))) (EApp (EVar "display") (EVar "ty"))) (ELit (LString "` but is written with a domain, and only a `String` argument has an authority; give `"))) (EApp (EVar "display") (EVar "n"))) (ELit (LString "` the type `String` or drop the domain"))))
(DTypeSig true "binderTypeMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "binderTypeMsg" ((PVar "n") (PVar "ty")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "named argument `")) (EApp (EVar "display") (EVar "n"))) (ELit (LString "` has type `"))) (EApp (EVar "display") (EVar "ty"))) (ELit (LString "`, but an effect atom names it as an authority, and only a `String` argument can be one; give `"))) (EApp (EVar "display") (EVar "n"))) (ELit (LString "` the type `String` or write the label bare"))))
(DTypeSig true "binderDomainMsg" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "binderDomainMsg" ((PVar "n")) (EBinOp "++" (EBinOp "++" (ELit (LString "authority `")) (EApp (EVar "display") (EVar "n"))) (ELit (LString "` is used at labels from different domains, and one authority has one domain; name a second binder for the other label"))))
(DTypeSig true "stickyDiagsInPushOrder" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TcDiag"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TcDiag")))))
(DFunDef false "stickyDiagsInPushOrder" ((PVar "diags")) (EApp (EApp (EVar "dedupBy") (EVar "tcDiagGoalKey")) (EApp (EVar "reverseL") (EVar "diags"))))
(DTypeSig true "tcDiagGoalKey" (TyFun (TyTuple (TyCon "String") (TyCon "TcDiag")) (TyCon "String")))
(DFunDef false "tcDiagGoalKey" ((PTuple (PVar "mid") (PCon "TcDiag" (PVar "code") PWild (PVar "loc") (PVar "msg") PWild PWild))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "mid"))) (ELit (LString "|"))) (EApp (EVar "display") (EVar "code"))) (ELit (LString "|"))) (EApp (EVar "display") (EApp (EVar "locGoalKey") (EVar "loc")))) (ELit (LString "|"))) (EApp (EVar "display") (EVar "msg"))) (ELit (LString ""))))
(DTypeSig true "authorityIndexMsg" (TyFun (TyCon "Authority") (TyFun (TyCon "Authority") (TyCon "String"))))
(DFunDef false "authorityIndexMsg" ((PVar "a") (PVar "b")) (EBlock (DoLet false false (PVar "ctx") (EApp (EVar "Ref") (EListLit))) (DoLet false false (PVar "cnt") (EApp (EVar "Ref") (ELit (LInt 0)))) (DoLet false false (PVar "sa") (EApp (EApp (EApp (EVar "authorityTermTextIn") (EVar "ctx")) (EVar "cnt")) (EVar "a"))) (DoLet false false (PVar "sb") (EApp (EApp (EApp (EVar "authorityTermTextIn") (EVar "ctx")) (EVar "cnt")) (EVar "b"))) (DoLet false false (PTuple (PVar "x") (PVar "y")) (EIf (EBinOp "<=" (EVar "sa") (EVar "sb")) (ETuple (EVar "sa") (EVar "sb")) (ETuple (EVar "sb") (EVar "sa")))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "authority index mismatch: ")) (EApp (EVar "display") (EVar "x"))) (ELit (LString " vs "))) (EApp (EVar "display") (EVar "y"))) (ELit (LString "; an authority in a type argument is invariant, so write the same index on both sides or name it, `Handle p`"))))))
(DTypeSig true "authorityCoverMsg" (TyFun (TyCon "Authority") (TyFun (TyCon "Authority") (TyCon "String"))))
(DFunDef false "authorityCoverMsg" ((PVar "lower") (PVar "upper")) (EBlock (DoLet false false (PVar "ctx") (EApp (EVar "Ref") (EListLit))) (DoLet false false (PVar "cnt") (EApp (EVar "Ref") (ELit (LInt 0)))) (DoLet false false (PVar "lo") (EApp (EApp (EApp (EVar "authorityTermTextIn") (EVar "ctx")) (EVar "cnt")) (EVar "lower"))) (DoLet false false (PVar "hi") (EApp (EApp (EApp (EVar "authorityTermTextIn") (EVar "ctx")) (EVar "cnt")) (EVar "upper"))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "authority index mismatch: ")) (EApp (EVar "display") (EVar "lo"))) (ELit (LString " is not covered by "))) (EApp (EVar "display") (EVar "hi"))) (ELit (LString "; stay within "))) (EApp (EVar "display") (EVar "hi"))) (ELit (LString ", or widen the row's authority for the label"))))))
(DTypeSig true "authorityTermTextIn" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String")))) (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyFun (TyCon "Authority") (TyCon "String")))))
(DFunDef false "authorityTermTextIn" ((PVar "ctx") (PVar "cnt") (PVar "q")) (EIf (EApp (EVar "authIsTop") (EVar "q")) (ELit (LString "the whole domain")) (EApp (EApp (EApp (EVar "ppAuthority") (EVar "ctx")) (EVar "cnt")) (EVar "q"))))
(DTypeSig true "residualFailureMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "residualFailureMsg" ((PVar "callee") (PVar "lo") (PVar "hi")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "display") (EVar "callee"))) (ELit (LString "` needs "))) (EApp (EVar "display") (EVar "lo"))) (ELit (LString " to lie within "))) (EApp (EVar "display") (EVar "hi"))) (ELit (LString " here, but this use does not satisfy it; pass values whose authorities do"))))
(DTypeSig true "starSpelling" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyCon "String"))))
(DFunDef false "starSpelling" ((PVar "n") (PCon "Some" (PVar "l"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "display") (EVar "n"))) (ELit (LString "` pattern-ranging, `("))) (EApp (EVar "display") (EVar "n"))) (ELit (LString " : String @"))) (EApp (EVar "display") (EVar "l"))) (ELit (LString "*)` or `("))) (EApp (EVar "display") (EVar "n"))) (ELit (LString " : Authority "))) (EApp (EVar "display") (EVar "l"))) (ELit (LString "*)`"))))
(DFunDef false "starSpelling" ((PVar "n") (PCon "None")) (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "display") (EVar "n"))) (ELit (LString "` pattern-ranging, `@L*` or `Authority L*`"))))
(DTypeSig true "paramVarianceMismatchMsg" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "String"))))
(DFunDef false "paramVarianceMismatchMsg" ((PVar "l1") (PVar "l2")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "effect row mismatch inside a non-covariant type argument: <")) (EApp (EVar "display") (EApp (EVar "renderAtoms") (EVar "l1")))) (ELit (LString "> vs <"))) (EApp (EVar "display") (EApp (EVar "renderAtoms") (EVar "l2")))) (ELit (LString ">; the two rows must be equal here, so write the same row on both sides, or eta-expand a freshly built function, `(s => f s)`"))))
(DTypeSig true "elselessIfHelp" (TyCon "String"))
(DFunDef false "elselessIfHelp" () (ELit (LString "an `if` without `else` has type Unit, so add an `else` branch or make the `then` branch Unit")))
(DTypeSig true "constrainedApplicationText" (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))))
(DFunDef false "constrainedApplicationText" ((PVar "app") (PVar "plain") (PVar "ifaces")) (EBlock (DoLet false false (PVar "names") (EApp (EApp (EVar "joinWith") (ELit (LString " and "))) (EApp (EApp (EVar "map") (ELam ((PVar "i")) (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "display") (EVar "i"))) (ELit (LString "`"))))) (EVar "ifaces")))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "display") (EApp (EVar "ppMono") (EVar "app")))) (ELit (LString "` is a value whose type implements "))) (EApp (EVar "display") (EVar "names"))) (ELit (LString ", and `"))) (EApp (EVar "display") (EApp (EVar "ppMono") (EVar "plain")))) (ELit (LString "` is not"))))))
(DTypeSig true "sameSpellingHint" (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "sameSpellingHint" ((PVar "a") (PVar "b")) (EIf (EBinOp "/=" (EApp (EVar "ppMono") (EVar "a")) (EApp (EVar "ppMono") (EVar "b"))) (EApp (EApp (EVar "map") (EVar "idConflictHelp")) (EApp (EApp (EVar "headIdConflict") (EVar "a")) (EVar "b"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "map") (EVar "idConflictHelp")) (EApp (EApp (EVar "firstIdConflict") (EVar "a")) (EVar "b"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "idConflictHelp" (TyFun (TyTuple (TyCon "String") (TyCon "TyConOrigin") (TyCon "TyConOrigin")) (TyCon "String")))
(DFunDef false "idConflictHelp" ((PTuple (PVar "name") (PVar "o1") (PVar "o2"))) (EBlock (DoLet false false (PVar "remedy") (EIf (EBinOp "||" (EApp (EVar "isPreludeOrigin") (EVar "o1")) (EApp (EVar "isPreludeOrigin") (EVar "o2"))) (ELit (LString "build this value with the constructors of the type this position expects")) (ELit (LString "import the one you mean instead of declaring a second type with that name")))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "two different types share the name `")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "`: one comes from "))) (EApp (EVar "display") (EApp (EVar "originPhrase") (EVar "o1")))) (ELit (LString ", the other from "))) (EApp (EVar "display") (EApp (EVar "originPhrase") (EVar "o2")))) (ELit (LString "; "))) (EApp (EVar "display") (EVar "remedy"))) (ELit (LString ""))))))
(DTypeSig false "originPhrase" (TyFun (TyCon "TyConOrigin") (TyCon "String")))
(DFunDef false "originPhrase" ((PCon "OriginModule" (PLit (LString "core")))) (ELit (LString "the prelude")))
(DFunDef false "originPhrase" ((PCon "OriginModule" (PLit (LString "__user__")))) (ELit (LString "this program")))
(DFunDef false "originPhrase" ((PCon "OriginModule" (PVar "m"))) (EBinOp "++" (EBinOp "++" (ELit (LString "module `")) (EApp (EVar "display") (EVar "m"))) (ELit (LString "`"))))
(DFunDef false "originPhrase" ((PCon "OriginBuiltin")) (ELit (LString "the language itself")))
(DFunDef false "originPhrase" ((PCon "OriginUnresolved")) (ELit (LString "an unknown module")))
(DTypeSig true "doRequiresMonadMsg" (TyCon "String"))
(DFunDef false "doRequiresMonadMsg" () (ELit (LString "`do` needs a value whose type implements `Thenable`, such as `Option` or `Result`; for IO sequencing use a bare indented block instead of `do`")))
(DTypeSig true "deferRequiresMonadMsg" (TyCon "String"))
(DFunDef false "deferRequiresMonadMsg" () (ELit (LString "`defer` needs a value whose type implements `DeferredThenable`, such as `Async`; for `Option`, `Result` or `List` use `do` instead")))
(DTypeSig true "bindOutsideDoMsg" (TyCon "String"))
(DFunDef false "bindOutsideDoMsg" () (ELit (LString "`<-` is only valid inside a `do` block; outside one, bind the value with `let x = ...`")))
(DTypeSig true "qualifierBinderTypeMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "qualifierBinderTypeMsg" ((PVar "n") (PVar "ty")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "named argument `")) (EApp (EVar "display") (EVar "n"))) (ELit (LString "` has type `"))) (EApp (EVar "display") (EVar "ty"))) (ELit (LString "`, but a qualifier names it as an authority, and only a `String` argument has one; qualify by a `String` argument or drop `"))) (EApp (EVar "display") (EVar "n"))) (ELit (LString "` from the qualifier"))))
(DTypeSig true "binderNoDomainMsg" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "binderNoDomainMsg" ((PVar "n")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "the qualifier names `")) (EApp (EVar "display") (EVar "n"))) (ELit (LString "`, but no binder domain, effect atom or index in this signature gives it a domain; write one on the binder, `("))) (EApp (EVar "display") (EVar "n"))) (ELit (LString " : String @FileRead)`, or name the label it bounds, `<FileRead "))) (EApp (EVar "display") (EVar "n"))) (ELit (LString ">`"))))
(DTypeSig true "joinDomainMsg" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "joinDomainMsg" ((PVar "ns")) (EBinOp "++" (EBinOp "++" (ELit (LString "the joined qualifier ")) (EApp (EVar "display") (EApp (EApp (EVar "qualifierSource") (EVar "escStr")) (EApp (EApp (EVar "map") (EVar "EPName")) (EVar "ns"))))) (ELit (LString " joins authorities from different domains; qualify by authorities of one label's domain"))))
(DTypeSig true "nameNotAuthorityMsg" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "nameNotAuthorityMsg" ((PVar "n")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "display") (EVar "n"))) (ELit (LString "` is used as an authority, but nothing binds it as one; bind it as a named argument, `("))) (EApp (EVar "display") (EVar "n"))) (ELit (LString " : String) ->`, or an `Authority`-kinded index"))))
(DTypeSig true "rowKindMismatchMsg" (TyFun (TyApp (TyCon "List") (TyCon "EffAtomTy")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))
(DFunDef false "rowKindMismatchMsg" ((PVar "labels") (PVar "tail")) (EBinOp "++" (EBinOp "++" (ELit (LString "the row <")) (EApp (EVar "display") (EApp (EApp (EVar "ppEffInsideTy") (EVar "labels")) (EVar "tail")))) (ELit (LString "> is written at a type-argument position that is not row-kinded; write an ordinary type here"))))
(DTypeSig true "aliasArityMsg" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "aliasArityMsg" ((PVar "n") (PVar "expected") (PVar "got")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "type alias `")) (EApp (EVar "display") (EVar "n"))) (ELit (LString "` takes "))) (EApp (EVar "display") (EApp (EVar "argumentCount") (EVar "expected")))) (ELit (LString " but is applied to "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "got")))) (ELit (LString ""))))
(DTypeSig false "argumentCount" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "argumentCount" ((PLit (LInt 1))) (ELit (LString "1 argument")))
(DFunDef false "argumentCount" ((PVar "n")) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString " arguments"))))
(DTypeSig true "ordinaryInPatternSlotMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "ordinaryInPatternSlotMsg" ((PVar "n") (PVar "l")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "display") (EVar "n"))) (ELit (LString "` ranges over every authority of `"))) (EApp (EVar "display") (EVar "l"))) (ELit (LString "`, but it fills an `Authority "))) (EApp (EVar "display") (EVar "l"))) (ELit (LString "*` slot, which takes only patterns; declare `"))) (EApp (EVar "display") (EVar "n"))) (ELit (LString "` pattern-ranging, `("))) (EApp (EVar "display") (EVar "n"))) (ELit (LString " : String @"))) (EApp (EVar "display") (EVar "l"))) (ELit (LString "*)` or `("))) (EApp (EVar "display") (EVar "n"))) (ELit (LString " : Authority "))) (EApp (EVar "display") (EVar "l"))) (ELit (LString "*)`"))))
(DTypeSig true "exactInPatternSlotMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "exactInPatternSlotMsg" ((PVar "l") (PVar "written") (PVar "closed")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "display") (EVar "written"))) (ELit (LString "` is an exact element of `"))) (EApp (EVar "display") (EVar "l"))) (ELit (LString "`, but it fills an `Authority "))) (EApp (EVar "display") (EVar "l"))) (ELit (LString "*` slot, which takes only patterns; write the pattern it begins, `"))) (EApp (EVar "display") (EVar "closed"))) (ELit (LString "`, or `*`"))))
(DTypeSig true "authorityAsTypeMsg" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "authorityAsTypeMsg" ((PVar "n")) (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "display") (EVar "n"))) (ELit (LString "` is an authority binder but is used here as a type; write a different name for the type variable"))))
(DTypeSig true "authorityTermAsTypeMsg" (TyFun (TyApp (TyCon "List") (TyCon "EffParamTy")) (TyCon "String")))
(DFunDef false "authorityTermAsTypeMsg" ((PVar "p")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "the authority term `")) (EApp (EVar "display") (EApp (EApp (EVar "authTermsSurface") (EVar "escStr")) (EVar "p")))) (ELit (LString "` is written where a type goes; it belongs in an `Authority`-kinded type argument such as `Handle "))) (EApp (EVar "display") (EApp (EApp (EVar "authTermsSurface") (EVar "escStr")) (EVar "p")))) (ELit (LString "`"))))
(DTypeSig true "typeVarAsAuthorityMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "typeVarAsAuthorityMsg" ((PVar "n") (PVar "l")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "display") (EVar "n"))) (ELit (LString "` is a type variable, but this slot is `Authority "))) (EApp (EVar "display") (EVar "l"))) (ELit (LString "`; write an authority here: a binder's name, or a term such as `\"pattern/*\"` or `*`"))))
(DTypeSig true "typeAsAuthorityMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "typeAsAuthorityMsg" ((PVar "ty") (PVar "l")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "display") (EVar "ty"))) (ELit (LString "` is a type, but this slot is `Authority "))) (EApp (EVar "display") (EVar "l"))) (ELit (LString "`; write an authority here: a binder's name, a literal of the label's domain, or `*`"))))
(DTypeSig true "typeInRowSlotMsg" (TyFun (TyCon "Ty") (TyCon "String")))
(DFunDef false "typeInRowSlotMsg" ((PVar "ty")) (EBinOp "++" (EBinOp "++" (ELit (LString "the type `")) (EApp (EVar "display") (EApp (EVar "ppTy") (EVar "ty")))) (ELit (LString "` is written at a row-kinded type-argument position; write an effect row here, such as `<>`, `<Stdout>` or `<IO | e>`"))))
(DTypeSig true "existentialScopeMsg" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyCon "String")))
(DFunDef false "existentialScopeMsg" ((PVar "name")) (EBinOp "++" (EBinOp "++" (ELit (LString "this pattern opens the existential authority `")) (EApp (EVar "display") (EApp (EApp (EVar "optionOr") (ELit (LString "?"))) (EVar "name")))) (ELit (LString "`, which only a `match` arm or a function clause can scope; match on the value, or take it as a clause parameter"))))
(DTypeSig true "discardedValueMsg" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "discardedValueMsg" ((PVar "desc")) (EBinOp "++" (EBinOp "++" (ELit (LString "this statement's value (")) (EApp (EVar "display") (EVar "desc"))) (ELit (LString ") is discarded; only a `Unit` expression may stand alone as a statement"))))
(DTypeSig true "discardedValueFix" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyApp (TyCon "Option") (TyTuple (TyCon "Loc") (TyCon "String")))))
(DFunDef false "discardedValueFix" ((PCon "Some" (PCon "Loc" (PVar "f") (PVar "sl") (PVar "sc") PWild PWild))) (EApp (EVar "Some") (ETuple (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "f")) (EVar "sl")) (EVar "sc")) (EVar "sl")) (EVar "sc")) (ELit (LString "let _ = ")))))
(DFunDef false "discardedValueFix" ((PCon "None")) (EVar "None"))
(DTypeSig true "fieldNotInAllCtorsMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "fieldNotInAllCtorsMsg" ((PVar "fname") (PVar "tname") (PVar "sib")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "field `")) (EApp (EVar "display") (EVar "fname"))) (ELit (LString "` is not declared by every constructor of `"))) (EApp (EVar "display") (EVar "tname"))) (ELit (LString "`: `"))) (EApp (EVar "display") (EVar "sib"))) (ELit (LString "` has no `"))) (EApp (EVar "display") (EVar "fname"))) (ELit (LString "`; match on the constructor instead of using `."))) (EApp (EVar "display") (EVar "fname"))) (ELit (LString "`"))))
(DTypeSig true "fieldPositionDiffersMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "String") (TyCon "Int")) (TyFun (TyTuple (TyCon "String") (TyCon "Int")) (TyCon "String"))))))
(DFunDef false "fieldPositionDiffersMsg" ((PVar "fname") (PVar "tname") (PTuple (PVar "a") (PVar "i")) (PTuple (PVar "b") (PVar "j"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "field `")) (EApp (EVar "display") (EVar "fname"))) (ELit (LString "` is at different positions in the constructors of `"))) (EApp (EVar "display") (EVar "tname"))) (ELit (LString "`: it is field "))) (EApp (EVar "display") (EApp (EVar "intToString") (EBinOp "+" (EVar "i") (ELit (LInt 1)))))) (ELit (LString " of `"))) (EApp (EVar "display") (EVar "a"))) (ELit (LString "` but field "))) (EApp (EVar "display") (EApp (EVar "intToString") (EBinOp "+" (EVar "j") (ELit (LInt 1)))))) (ELit (LString " of `"))) (EApp (EVar "display") (EVar "b"))) (ELit (LString "`; match on the constructor instead of using `."))) (EApp (EVar "display") (EVar "fname"))) (ELit (LString "`"))))
(DTypeSig true "fieldTypeDiffersMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Mono") (TyFun (TyCon "String") (TyFun (TyCon "Mono") (TyCon "String"))))))))
(DFunDef false "fieldTypeDiffersMsg" ((PVar "fname") (PVar "tname") (PVar "a") (PVar "ta") (PVar "b") (PVar "tb")) (EBlock (DoLet false false (PVar "ctx") (EApp (EVar "Ref") (EListLit))) (DoLet false false (PVar "cnt") (EApp (EVar "Ref") (ELit (LInt 0)))) (DoLet false false (PVar "sa") (EApp (EApp (EApp (EApp (EVar "ppGo") (EVar "ctx")) (EVar "cnt")) (ELit (LInt 0))) (EVar "ta"))) (DoLet false false (PVar "sb") (EApp (EApp (EApp (EApp (EVar "ppGo") (EVar "ctx")) (EVar "cnt")) (ELit (LInt 0))) (EVar "tb"))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "field `")) (EApp (EVar "display") (EVar "fname"))) (ELit (LString "` has different types in the constructors of `"))) (EApp (EVar "display") (EVar "tname"))) (ELit (LString "`: it is `"))) (EApp (EVar "display") (EVar "sa"))) (ELit (LString "` in `"))) (EApp (EVar "display") (EVar "a"))) (ELit (LString "` but `"))) (EApp (EVar "display") (EVar "sb"))) (ELit (LString "` in `"))) (EApp (EVar "display") (EVar "b"))) (ELit (LString "`; match on the constructor instead of using `."))) (EApp (EVar "display") (EVar "fname"))) (ELit (LString "`"))))))
(DTypeSig true "updateMultiCtorMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))))))
(DFunDef false "updateMultiCtorMsg" ((PVar "fn") (PVar "tname") (PVar "rname") (PVar "others") (PVar "ctors")) (EBlock (DoLet false false (PVar "pat") (EIf (EApp (EVar "isEmptyL") (EVar "others")) (ELit (LString "...")) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EVar "others")))) (DoLet false false (PVar "rebuilt") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EBinOp "::" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "fn"))) (ELit (LString " = ..."))) (EVar "others")))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "cannot update field `")) (EApp (EVar "display") (EVar "fn"))) (ELit (LString "` on `"))) (EApp (EVar "display") (EVar "tname"))) (ELit (LString "`, which has more than one constructor ("))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "map") (EVar "backticked")) (EVar "ctors"))))) (ELit (LString "); match on the constructor and rebuild the value in its arm, as in `"))) (EApp (EVar "display") (EVar "rname"))) (ELit (LString " { "))) (EApp (EVar "display") (EVar "pat"))) (ELit (LString " } => "))) (EApp (EVar "display") (EVar "rname"))) (ELit (LString " { "))) (EApp (EVar "display") (EVar "rebuilt"))) (ELit (LString " }`"))))))
(DTypeSig true "ambiguousFieldDeclsMsg" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "RecordInfo"))) (TyCon "String")))))
(DFunDef false "ambiguousFieldDeclsMsg" ((PVar "fname") (PVar "owners") (PVar "cands")) (EBlock (DoLet false false (PVar "keys") (EApp (EApp (EVar "map") (EVar "fst")) (EVar "cands"))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "listLen") (EApp (EVar "dedup") (EVar "keys"))) (EApp (EVar "listLen") (EVar "keys"))) (EApp (EApp (EVar "ambiguousFieldMsg") (EVar "fname")) (EVar "owners")) (EBlock (DoLet false false (PVar "tys") (EApp (EVar "sortUniqS") (EApp (EApp (EVar "map") (EVar "fieldDeclTypeName")) (EVar "cands")))) (DoLet false false (PVar "descrs") (EApp (EVar "sortUniqS") (EApp (EApp (EVar "map") (EVar "fieldDeclDescr")) (EVar "cands")))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "ambiguous field `.")) (EApp (EVar "display") (EVar "fname"))) (ELit (LString "`: it is declared by "))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString " and by "))) (EVar "descrs")))) (ELit (LString " and the record type is undetermined; annotate the record, as in `(r : "))) (EApp (EVar "display") (EApp (EVar "headL") (EVar "tys")))) (ELit (LString ")."))) (EApp (EVar "display") (EVar "fname"))) (ELit (LString "`")))))))))
(DTypeSig false "fieldDeclTypeName" (TyFun (TyTuple (TyCon "String") (TyCon "RecordInfo")) (TyCon "String")))
(DFunDef false "fieldDeclTypeName" ((PTuple (PVar "k") (PVar "ri"))) (EApp (EApp (EVar "optionOr") (EVar "k")) (EApp (EVar "headTyconNameMono") (EApp (EVar "recordResultMono") (EVar "ri")))))
(DTypeSig false "fieldDeclDescr" (TyFun (TyTuple (TyCon "String") (TyCon "RecordInfo")) (TyCon "String")))
(DFunDef false "fieldDeclDescr" ((PTuple (PVar "k") (PVar "ri"))) (EMatch (EApp (EVar "recordOwnerModule") (EVar "ri")) (arm (PCon "Some" (PVar "mid")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "display") (EApp (EVar "fieldDeclTypeName") (ETuple (EVar "k") (EVar "ri"))))) (ELit (LString "` from module `"))) (EApp (EVar "display") (EVar "mid"))) (ELit (LString "`")))) (arm (PCon "None") () (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "display") (EApp (EVar "fieldDeclTypeName") (ETuple (EVar "k") (EVar "ri"))))) (ELit (LString "`"))))))
(DTypeSig false "headL" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "headL" ((PList)) (ELit (LString "")))
(DFunDef false "headL" ((PCons (PVar "x") PWild)) (EVar "x"))
(DTypeSig true "fieldFixFrom" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyTuple (TyCon "Loc") (TyCon "String")))))))
(DFunDef false "fieldFixFrom" ((PCon "Some" (PCon "Loc" (PVar "f") PWild PWild (PVar "el") (PVar "ec"))) (PVar "written") (PVar "sug")) (EApp (EVar "Some") (ETuple (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "f")) (EVar "el")) (EBinOp "+" (EVar "ec") (ELit (LInt 1)))) (EVar "el")) (EBinOp "+" (EBinOp "+" (EVar "ec") (ELit (LInt 1))) (EApp (EVar "stringLength") (EVar "written")))) (EVar "sug"))))
(DFunDef false "fieldFixFrom" ((PCon "None") PWild PWild) (EVar "None"))
(DTypeSig true "unknownFieldMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "unknownFieldMsg" ((PVar "fname") (PVar "rname")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "no field `")) (EApp (EVar "display") (EVar "fname"))) (ELit (LString "` in `"))) (EApp (EVar "display") (EVar "rname"))) (ELit (LString "`"))))
(DTypeSig true "abstractFieldMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "abstractFieldMsg" ((PVar "tname") (PVar "fname")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "display") (EVar "tname"))) (ELit (LString "` is exported abstractly, so its field `"))) (EApp (EVar "display") (EVar "fname"))) (ELit (LString "` is not accessible; declare it `public export` to expose its fields"))))
(DTypeSig true "missingFieldMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "missingFieldMsg" ((PVar "fname") (PVar "rname")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "missing field `")) (EApp (EVar "display") (EVar "fname"))) (ELit (LString "` in `"))) (EApp (EVar "display") (EVar "rname"))) (ELit (LString "`"))))
(DTypeSig true "ambiguousFieldMsg" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))
(DFunDef false "ambiguousFieldMsg" ((PVar "fname") (PVar "owners")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "ambiguous field `.")) (EApp (EVar "display") (EVar "fname"))) (ELit (LString "`: it is declared by "))) (EApp (EVar "display") (EApp (EVar "joinAnd") (EApp (EApp (EVar "map") (EVar "backticked")) (EVar "owners"))))) (ELit (LString " and the record type is undetermined; annotate the record, as in `(r : "))) (EApp (EVar "display") (EApp (EVar "headL") (EVar "owners")))) (ELit (LString ")."))) (EApp (EVar "display") (EVar "fname"))) (ELit (LString "`"))))
(DTypeSig true "unknownRecordMsg" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "unknownRecordMsg" ((PVar "name")) (EBinOp "++" (EBinOp "++" (ELit (LString "unknown record type `")) (EVar "name")) (ELit (LString "`"))))
(DTypeSig true "unknownCtorMsg" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "unknownCtorMsg" ((PVar "name")) (EBinOp "++" (EBinOp "++" (ELit (LString "unknown constructor `")) (EVar "name")) (ELit (LString "`"))))
(DTypeSig true "unboundVarMsg" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "unboundVarMsg" ((PVar "name")) (EBinOp "++" (EBinOp "++" (ELit (LString "unbound variable `")) (EVar "name")) (ELit (LString "`"))))
(DTypeSig true "u64RangeText" (TyCon "String"))
(DFunDef false "u64RangeText" () (ELit (LString "0..18446744073709551615")))
(DTypeSig true "i64RangeText" (TyCon "String"))
(DFunDef false "i64RangeText" () (ELit (LString "-9223372036854775808..9223372036854775807")))
(DTypeSig true "wideAnnotateHelp" (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyCon "String"))))
(DFunDef false "wideAnnotateHelp" ((PVar "shown") (PVar "negated")) (EBlock (DoLet false false (PVar "ty") (EIf (EVar "negated") (ELit (LString "I64")) (ELit (LString "U64")))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "only a `U64` or an `I64` holds a literal above 2^62; annotate it as `(")) (EApp (EVar "display") (EVar "shown"))) (ELit (LString " : "))) (EApp (EVar "display") (EVar "ty"))) (ELit (LString ")`"))))))
(DTypeSig true "bangOnBoolMsg" (TyCon "String"))
(DFunDef false "bangOnBoolMsg" () (ELit (LString "`!` dereferences a `Ref` and does not negate a `Bool`; use `not x`")))
(DTypeSig true "bangOnBoolHelp" (TyCon "String"))
(DFunDef false "bangOnBoolHelp" () (ELit (LString "use `not x`; `!x` reads a `Ref` cell, so it needs a `Ref a`, not a `Bool`")))
(DTypeSig true "contraRowMsg" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "String")))))
(DFunDef false "contraRowMsg" ((PVar "le") (PVar "la") (PVar "extras")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "a function whose parameter admits only <")) (EApp (EVar "display") (EApp (EVar "renderAtoms") (EVar "la")))) (ELit (LString "> is used where one admitting <"))) (EApp (EVar "display") (EApp (EVar "renderAtoms") (EVar "le")))) (ELit (LString "> is expected, so a caller could pass an argument performing <"))) (EApp (EVar "display") (EApp (EVar "renderAtoms") (EVar "extras")))) (ELit (LString ">; declare that parameter with <"))) (EApp (EVar "display") (EApp (EVar "renderAtoms") (EVar "le")))) (ELit (LString ">"))))
(DTypeSig true "notAFunctionMsg" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "notAFunctionMsg" ((PVar "tyName")) (EApp (EApp (EVar "notAFunctionMsgFor") (EVar "None")) (EVar "tyName")))
(DTypeSig true "notAFunctionMsgFor" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "notAFunctionMsgFor" ((PCon "Some" (PVar "name")) (PVar "tyName")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "` has type "))) (EApp (EVar "display") (EVar "tyName"))) (ELit (LString " and is not a function; it cannot be applied to an argument"))))
(DFunDef false "notAFunctionMsgFor" ((PCon "None") (PVar "tyName")) (EBinOp "++" (EBinOp "++" (ELit (LString "this expression has type ")) (EApp (EVar "display") (EVar "tyName"))) (ELit (LString " and is not a function; it cannot be applied to an argument"))))
(DTypeSig true "notAFunctionHint" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyCon "String")))
(DFunDef false "notAFunctionHint" ((PCon "Some" (PVar "name"))) (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "` is a value, not a function; remove the argument"))))
(DFunDef false "notAFunctionHint" ((PCon "None")) (ELit (LString "this is a value, not a function; remove the argument")))
(DTypeSig true "overAppliedMsg" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "overAppliedMsg" ((PVar "name") (PVar "takes") (PVar "applied")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "` takes "))) (EApp (EVar "display") (EApp (EVar "argumentCount") (EVar "takes")))) (ELit (LString " but is applied to "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "applied")))) (ELit (LString ""))))
(DTypeSig true "containerArgMsg" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "containerArgMsg" ((PVar "fn") (PVar "argTy")) (EBlock (DoLet false false (PVar "who") (EMatch (EVar "fn") (arm (PCon "Some" (PVar "n")) () (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "display") (EVar "n"))) (ELit (LString "`")))) (arm (PCon "None") () (ELit (LString "this function"))))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "who"))) (ELit (LString " expects a container such as `List` here but got `"))) (EApp (EVar "display") (EVar "argTy"))) (ELit (LString "`; "))) (EApp (EVar "display") (EApp (EVar "containerArgHint") (EVar "argTy")))) (ELit (LString ""))))))
(DTypeSig true "containerArgHint" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "containerArgHint" ((PLit (LString "String"))) (ELit (LString "to work over the string's characters, convert it with `string.toChars` first")))
(DFunDef false "containerArgHint" ((PVar "argTy")) (EBinOp "++" (EBinOp "++" (ELit (LString "convert the `")) (EApp (EVar "display") (EVar "argTy"))) (ELit (LString "` to a `List` first"))))
(DTypeSig true "doBindArgMsg" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "doBindArgMsg" ((PVar "argTy")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "this `do` block needs a `Thenable` value here, such as `Option` or `Result`, but got `")) (EApp (EVar "display") (EVar "argTy"))) (ELit (LString "`; "))) (EApp (EVar "display") (EApp (EVar "doBindArgHint") (EVar "argTy")))) (ELit (LString ""))))
(DTypeSig true "doBindArgHint" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "doBindArgHint" ((PVar "argTy")) (EBinOp "++" (EBinOp "++" (ELit (LString "bind a plain `")) (EApp (EVar "display") (EVar "argTy"))) (ELit (LString "` with `let` instead of `<-`"))))
(DTypeSig false "renderCallArg" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "renderCallArg" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "renderCallArg") (EVar "e")))
(DFunDef false "renderCallArg" ((PCon "EAnnot" (PVar "e") PWild)) (EApp (EVar "renderCallArg") (EVar "e")))
(DFunDef false "renderCallArg" ((PCon "ENumLit" (PVar "n") PWild PWild)) (EApp (EVar "Some") (EApp (EVar "intToString") (EVar "n"))))
(DFunDef false "renderCallArg" ((PCon "EWideLit" PWild PWild PWild (PVar "lx"))) (EApp (EVar "Some") (EVar "lx")))
(DFunDef false "renderCallArg" ((PCon "ELit" (PCon "LInt" (PVar "n")))) (EApp (EVar "Some") (EApp (EVar "intToString") (EVar "n"))))
(DFunDef false "renderCallArg" ((PCon "ELit" (PCon "LBool" (PCon "True")))) (EApp (EVar "Some") (ELit (LString "True"))))
(DFunDef false "renderCallArg" ((PCon "ELit" (PCon "LBool" (PCon "False")))) (EApp (EVar "Some") (ELit (LString "False"))))
(DFunDef false "renderCallArg" ((PCon "ELit" (PCon "LString" (PVar "s")))) (EApp (EVar "Some") (EBinOp "++" (EBinOp "++" (ELit (LString "\"")) (EVar "s")) (ELit (LString "\"")))))
(DFunDef false "renderCallArg" ((PCon "ELit" (PCon "LChar" (PVar "c")))) (EApp (EVar "Some") (EBinOp "++" (EBinOp "++" (ELit (LString "'")) (EVar "c")) (ELit (LString "'")))))
(DFunDef false "renderCallArg" ((PCon "EVar" (PVar "n"))) (EApp (EVar "Some") (EVar "n")))
(DFunDef false "renderCallArg" ((PCon "EVarId" (PVar "n") PWild)) (EApp (EVar "Some") (EVar "n")))
(DFunDef false "renderCallArg" ((PCon "EMethodAt" (PVar "n") PWild PWild)) (EApp (EVar "Some") (EVar "n")))
(DFunDef false "renderCallArg" ((PCon "EDictAt" (PVar "n") PWild)) (EApp (EVar "Some") (EVar "n")))
(DFunDef false "renderCallArg" ((PCon "EUnOp" (PLit (LString "-")) (PVar "e") PWild)) (EApp (EApp (EVar "map") (ELam ((PVar "_s")) (EBinOp "++" (ELit (LString "-")) (EVar "_s")))) (EApp (EVar "renderCallArg") (EVar "e"))))
(DFunDef false "renderCallArg" (PWild) (EVar "None"))
(DTypeSig true "renderCallArgs" (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "renderCallArgs" ((PList)) (EApp (EVar "Some") (EListLit)))
(DFunDef false "renderCallArgs" ((PCons (PVar "e") (PVar "rest"))) (EMatch (EApp (EVar "renderCallArg") (EVar "e")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "s")) () (EApp (EApp (EVar "map") (ELam ((PVar "_s")) (EBinOp "::" (EVar "s") (EVar "_s")))) (EApp (EVar "renderCallArgs") (EVar "rest"))))))
(DTypeSig true "nonExhaustiveMatchWarning" (TyCon "String"))
(DFunDef false "nonExhaustiveMatchWarning" () (ELit (LString "Warning: non-exhaustive match; not every case is covered")))
(DTypeSig true "unreachableArmWarning" (TyCon "String"))
(DFunDef false "unreachableArmWarning" () (ELit (LString "Warning: unreachable match arm; an earlier arm already covers this pattern")))
(DTypeSig true "tyOfMsg" (TyFun (TyApp (TyCon "Option") (TyCon "TabKey")) (TyCon "String")))
(DFunDef false "tyOfMsg" ((PCon "None")) (ELit (LString "")))
(DFunDef false "tyOfMsg" ((PCon "Some" (PVar "k"))) (EBlock (DoLet false false (PVar "t") (EApp (EVar "tabKeyName") (EVar "k"))) (DoExpr (EIf (EApp (EVar "isTupleTyName") (EVar "t")) (ELit (LString "")) (EBinOp "++" (EBinOp "++" (ELit (LString " on `")) (EApp (EVar "display") (EVar "t"))) (ELit (LString "`")))))))
(DTypeSig false "isTupleTyName" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isTupleTyName" ((PVar "t")) (EBinOp "&&" (EBinOp ">=" (EApp (EVar "stringLength") (EVar "t")) (ELit (LInt 7))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 7))) (EVar "t")) (ELit (LString "__tuple")))))
(DTypeSig true "existentialEscapeMsg" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyCon "String")))
(DFunDef false "existentialEscapeMsg" ((PVar "name")) (EBinOp "++" (EBinOp "++" (ELit (LString "the existential authority `")) (EApp (EVar "display") (EApp (EApp (EVar "optionOr") (ELit (LString "?"))) (EVar "name")))) (ELit (LString "` escapes the arm or clause that opened it; consume the value inside it, or return it repacked in its existential constructor"))))
(DTypeSig true "partialExistentialUpdateMsg" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))
(DFunDef false "partialExistentialUpdateMsg" ((PVar "rname") (PVar "names")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "updating `")) (EApp (EVar "display") (EVar "rname"))) (ELit (LString "` replaces a field under an existential authority binder, but the binder's fields "))) (EApp (EVar "display") (EApp (EVar "quotedNames") (EVar "names")))) (ELit (LString " must change together; replace them all, or rebuild the record"))))
(DTypeSig true "letRecNonFunctionMsg" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "letRecNonFunctionMsg" ((PVar "name")) (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EVar "name")) (ELit (LString "` is bound by `let rec` but its right-hand side is not a function"))))
(DTypeSig true "ambiguousShadowHelp" (TyCon "String"))
(DFunDef false "ambiguousShadowHelp" () (ELit (LString "bring only one of those interfaces into scope by importing the other module without naming its interface, or rename one of the methods")))
(DTypeSig true "shadowIfaceLabel" (TyFun (TyCon "IfaceRef") (TyCon "String")))
(DFunDef false "shadowIfaceLabel" ((PVar "ir")) (EMatch (EFieldAccess (EVar "ir") "irOrigin") (arm (PCon "OriginModule" (PVar "m")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "display") (EFieldAccess (EVar "ir") "irName"))) (ELit (LString "` (from `"))) (EApp (EVar "display") (EVar "m"))) (ELit (LString "`)")))) (arm PWild () (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "display") (EFieldAccess (EVar "ir") "irName"))) (ELit (LString "`"))))))
(DTypeSig true "implHeadIndexMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "implHeadIndexMsg" ((PVar "head") (PVar "written")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "impl head `")) (EApp (EVar "display") (EVar "head"))) (ELit (LString " "))) (EApp (EVar "display") (EVar "written"))) (ELit (LString "` writes an `Authority` index, but an instance is chosen by the type's head and covers every index; write a name in the slot instead of `"))) (EApp (EVar "display") (EVar "written"))) (ELit (LString "`"))))
(DTypeSig true "cohOverlapMsg" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "String")))))
(DFunDef false "cohOverlapMsg" ((PVar "iface") (PVar "xs") (PVar "ys")) (EMatch (EApp (EApp (EVar "cohPpPair") (EVar "xs")) (EVar "ys")) (arm (PTuple (PVar "s1") (PVar "s2")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "overlapping impls of ")) (EApp (EVar "display") (EVar "iface"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "s1"))) (ELit (LString " and "))) (EApp (EVar "display") (EVar "s2"))) (ELit (LString " can match the same type; make them disjoint or wrap one type in a newtype"))))))
(DTypeSig true "cohPreludeOverlapMsg" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "String")))))
(DFunDef false "cohPreludeOverlapMsg" ((PVar "iface") (PVar "xs") (PVar "ys")) (EMatch (EApp (EApp (EVar "cohPpPair") (EVar "xs")) (EVar "ys")) (arm (PTuple (PVar "s1") (PVar "s2")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "overlapping impls of ")) (EApp (EVar "display") (EVar "iface"))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "s1"))) (ELit (LString " and the prelude's "))) (EApp (EVar "display") (EVar "s2"))) (ELit (LString " can match the same type; the prelude's impl cannot be replaced, so wrap the type in a newtype and implement "))) (EApp (EVar "display") (EVar "iface"))) (ELit (LString " for that"))))))
(DTypeSig true "cohIncomparableHelp" (TyCon "String"))
(DFunDef false "cohIncomparableHelp" () (ELit (LString "add an impl at the two heads' common instance so it is more specific than both, or make the two heads disjoint")))
(DTypeSig true "cohCrossModuleMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "cohCrossModuleMsg" ((PVar "iface") (PVar "mid1") (PVar "mid2")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "conflicting `impl ")) (EApp (EVar "display") (EVar "iface"))) (ELit (LString "`: defined in both `"))) (EApp (EVar "display") (EVar "mid2"))) (ELit (LString "` and `"))) (EApp (EVar "display") (EVar "mid1"))) (ELit (LString "`"))))
(DTypeSig true "superContextUndeclaredMsg" (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String")))))))
(DFunDef false "superContextUndeclaredMsg" ((PVar "subject") (PVar "derived") (PVar "superGoal") (PVar "pred") (PVar "predBare")) (EIf (EVar "derived") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "display") (EVar "subject"))) (ELit (LString "` (derived) must provide its superinterface `"))) (EApp (EVar "display") (EVar "superGoal"))) (ELit (LString "`, whose instance requires `"))) (EApp (EVar "display") (EVar "pred"))) (ELit (LString "`, which the derived impl does not declare; a `deriving` clause takes no `requires`, so write the impl by hand with `requires "))) (EApp (EVar "display") (EVar "predBare"))) (ELit (LString "`"))) (EIf (EVar "otherwise") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "display") (EVar "subject"))) (ELit (LString "` must provide its superinterface `"))) (EApp (EVar "display") (EVar "superGoal"))) (ELit (LString "`, whose instance requires `"))) (EApp (EVar "display") (EVar "pred"))) (ELit (LString "`, which the impl does not declare; add `requires "))) (EApp (EVar "display") (EVar "predBare"))) (ELit (LString "` to the impl"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "superContextNoImplMsg" (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String")))))))
(DFunDef false "superContextNoImplMsg" ((PVar "subject") (PVar "derived") (PVar "superGoal") (PVar "pred") (PVar "predBare")) (EIf (EVar "derived") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "display") (EVar "subject"))) (ELit (LString "` (derived) must provide its superinterface `"))) (EApp (EVar "display") (EVar "superGoal"))) (ELit (LString "`, whose instance requires `"))) (EApp (EVar "display") (EVar "pred"))) (ELit (LString "`, and no impl provides it; add `impl "))) (EApp (EVar "display") (EVar "predBare"))) (ELit (LString "`, and write the derived impl by hand if its `requires` must change"))) (EIf (EVar "otherwise") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "display") (EVar "subject"))) (ELit (LString "` must provide its superinterface `"))) (EApp (EVar "display") (EVar "superGoal"))) (ELit (LString "`, whose instance requires `"))) (EApp (EVar "display") (EVar "pred"))) (ELit (LString "`, and no impl provides it; add `impl "))) (EApp (EVar "display") (EVar "predBare"))) (ELit (LString "`"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "missingImplMethodMsg" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "missingImplMethodMsg" ((PVar "iface") (PVar "tys") (PVar "method")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`impl ")) (EApp (EVar "display") (EVar "iface"))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EVar "map") (EVar "ppTyAtom")) (EVar "tys"))))) (ELit (LString "` is missing the method `"))) (EApp (EVar "display") (EVar "method"))) (ELit (LString "`; define `"))) (EApp (EVar "display") (EVar "method"))) (ELit (LString "` in the impl"))))
(DTypeSig true "ordinalSentinelMsg" (TyCon "String"))
(DFunDef false "ordinalSentinelMsg" () (ELit (LString "internal error: the whole-program final checks (coherence, interface cycles, phantom methods, superinterface existence) were reached with an unknown module ordinal, so they cannot say what is in scope here. This is a compiler bug, not a problem with this program — please report it. The checks below this point may be incomplete")))
(DTypeSig true "cyclicSuperIfaceMsg" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "cyclicSuperIfaceMsg" ((PVar "path")) (EBinOp "++" (ELit (LString "cyclic superinterface: ")) (EApp (EApp (EVar "joinWith") (ELit (LString " requires "))) (EApp (EApp (EVar "map") (EVar "backticked")) (EVar "path")))))
(DTypeSig true "ambiguousOverlapMsg" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyApp (TyCon "List") (TyCon "KeyEntry")) (TyCon "String")))))
(DFunDef false "ambiguousOverlapMsg" ((PVar "iface") (PVar "goals") (PVar "cands")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "ambiguous instance for `")) (EApp (EVar "display") (EVar "iface"))) (ELit (LString "`: the goal `"))) (EApp (EVar "display") (EVar "iface"))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EVar "ppPredArgsShared") (EVar "goals")))) (ELit (LString "` matches "))) (EApp (EVar "display") (EApp (EVar "joinAnd") (EApp (EApp (EVar "map") (EApp (EVar "implHeadLabel") (EVar "iface"))) (EVar "cands"))))) (ELit (LString ", and "))) (EApp (EVar "display") (EApp (EVar "noMinimumClause") (EApp (EVar "listLen") (EVar "cands"))))) (ELit (LString "; make them disjoint, or annotate this expression with a type only one of them matches"))))
(DTypeSig false "noMinimumClause" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "noMinimumClause" ((PVar "n")) (EIf (EBinOp "==" (EVar "n") (ELit (LInt 2))) (ELit (LString "neither is more specific than the other")) (EIf (EVar "otherwise") (ELit (LString "none of them is more specific than all the others")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "joinAnd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "joinAnd" ((PList)) (ELit (LString "")))
(DFunDef false "joinAnd" ((PList (PVar "x"))) (EVar "x"))
(DFunDef false "joinAnd" ((PList (PVar "x") (PVar "y"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "x"))) (ELit (LString " and "))) (EApp (EVar "display") (EVar "y"))) (ELit (LString ""))))
(DFunDef false "joinAnd" ((PCons (PVar "x") (PVar "rest"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "x"))) (ELit (LString ", "))) (EApp (EVar "display") (EApp (EVar "joinAnd") (EVar "rest")))) (ELit (LString ""))))
(DTypeSig false "implHeadLabel" (TyFun (TyCon "String") (TyFun (TyCon "KeyEntry") (TyCon "String"))))
(DFunDef false "implHeadLabel" ((PVar "iface") (PCon "KeyEntry" PWild PWild PWild PWild PWild (PVar "itys") PWild PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`impl ")) (EApp (EVar "display") (EVar "iface"))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EVar "map") (EVar "ppTyAtom")) (EVar "itys"))))) (ELit (LString "`"))))
(DTypeSig true "ambiguousImplMsg" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "ambiguousImplMsg" ((PVar "iface")) (EBinOp "++" (EBinOp "++" (ELit (LString "ambiguous instance for `")) (EVar "iface")) (ELit (LString "`: the type here does not determine which impl applies; add a type annotation"))))
(DTypeSig true "qualifiedIfaceLabel" (TyFun (TyCon "IfaceRef") (TyCon "String")))
(DFunDef false "qualifiedIfaceLabel" ((PVar "ir")) (EMatch (EFieldAccess (EVar "ir") "irOrigin") (arm (PCon "OriginModule" (PLit (LString "__user__"))) () (EFieldAccess (EVar "ir") "irName")) (arm (PCon "OriginModule" (PVar "m")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "m"))) (ELit (LString "."))) (EApp (EVar "display") (EFieldAccess (EVar "ir") "irName"))) (ELit (LString "")))) (arm PWild () (EFieldAccess (EVar "ir") "irName"))))
(DTypeSig true "sigVarGoalMsg" (TyFun (TyCon "DeclaringBinder") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))))) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "String")))))))
(DFunDef false "sigVarGoalMsg" ((PVar "binder") (PVar "sigTvMaps") (PVar "sigVarIds") (PVar "iface") (PVar "args")) (EBlock (DoLet false false (PVar "owners") (EApp (EApp (EVar "flatMap") (EApp (EVar "sigVarOwner") (EVar "sigTvMaps"))) (EApp (EVar "dedupI") (EVar "sigVarIds")))) (DoLet false false (PVar "named") (EApp (EApp (EVar "map") (EVar "snd")) (EVar "owners"))) (DoLet false false (PVar "pred") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EFieldAccess (EVar "iface") "irName"))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EApp (EApp (EVar "ppEach") (EApp (EVar "Ref") (EVar "named"))) (EApp (EVar "Ref") (ELit (LInt 0)))) (ELit (LInt 3))) (EVar "args"))))) (ELit (LString "")))) (DoLet false false (PVar "vars") (EApp (EApp (EVar "joinWith") (ELit (LString " and "))) (EApp (EApp (EVar "map") (ELam ((PVar "owner")) (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "display") (EApp (EVar "snd") (EApp (EVar "snd") (EVar "owner"))))) (ELit (LString "`"))))) (EVar "owners")))) (DoExpr (EMatch (EVar "binder") (arm (PCon "DeclaredBySignature") () (EBlock (DoLet false false (PVar "member") (EMatch (EVar "owners") (arm (PCons (PTuple (PVar "m") PWild) PWild) () (EVar "m")) (arm (PList) () (ELit (LString ""))))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "the body of `")) (EApp (EVar "display") (EVar "member"))) (ELit (LString "` requires `"))) (EApp (EVar "display") (EVar "pred"))) (ELit (LString "`, which its signature does not declare and which only a specific "))) (EApp (EVar "display") (EVar "vars"))) (ELit (LString " satisfies; write that type in the signature or add `"))) (EApp (EVar "display") (EVar "pred"))) (ELit (LString " =>`")))))) (arm (PCon "DeclaredByAnnotation") () (EBlock (DoLet false false (PVar "written") (EMatch (EVar "sigTvMaps") (arm (PCons (PTuple PWild (PVar "ty") PWild) PWild) () (EApp (EVar "ppTy") (EVar "ty"))) (arm (PList) () (ELit (LString ""))))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "this expression requires `")) (EApp (EVar "display") (EVar "pred"))) (ELit (LString "`, which its annotation `"))) (EApp (EVar "display") (EVar "written"))) (ELit (LString "` does not declare and which only a specific "))) (EApp (EVar "display") (EVar "vars"))) (ELit (LString " satisfies; write that type in the annotation or add `"))) (EApp (EVar "display") (EVar "pred"))) (ELit (LString " =>`"))))))))))
(DTypeSig false "sigVarOwner" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))))) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyCon "Int") (TyCon "String")))))))
(DFunDef false "sigVarOwner" ((PList) PWild) (EListLit))
(DFunDef false "sigVarOwner" ((PCons (PTuple (PVar "m") PWild (PVar "tvs")) (PVar "rest")) (PVar "id")) (EMatch (EApp (EApp (EVar "findTvName") (EVar "id")) (EVar "tvs")) (arm (PCon "Some" (PVar "n")) () (EListLit (ETuple (EVar "m") (ETuple (EVar "id") (EVar "n"))))) (arm (PCon "None") () (EApp (EApp (EVar "sigVarOwner") (EVar "rest")) (EVar "id")))))
(DTypeSig true "methodBodySubject" (TyFun (TyCon "MethodBodyKind") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "methodBodySubject" ((PCon "ImplBody" PWild) (PVar "iface") (PVar "mname")) (EApp (EApp (EVar "implSubject") (EVar "iface")) (EVar "mname")))
(DFunDef false "methodBodySubject" ((PCon "DefaultBody") (PVar "iface") (PVar "mname")) (EApp (EApp (EVar "defaultSubject") (EVar "iface")) (EVar "mname")))
(DTypeSig true "methodBodyLaunderMsg" (TyFun (TyCon "MethodBodyKind") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "String"))))))
(DFunDef false "methodBodyLaunderMsg" ((PCon "ImplBody" PWild) (PVar "iface") (PVar "mname") (PVar "escaping")) (EApp (EApp (EApp (EVar "effectLaunderMsg") (EVar "iface")) (EVar "mname")) (EVar "escaping")))
(DFunDef false "methodBodyLaunderMsg" ((PCon "DefaultBody") (PVar "iface") (PVar "mname") (PVar "escaping")) (EApp (EApp (EVar "defaultEffectLaunderMsg") (EApp (EApp (EVar "defaultSubject") (EVar "iface")) (EVar "mname"))) (EVar "escaping")))
(DTypeSig false "effectLaunderMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "String")))))
(DFunDef false "effectLaunderMsg" ((PVar "iface") (PVar "mname") (PVar "escaping")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "effect laundering in impl of `")) (EApp (EVar "display") (EVar "mname"))) (ELit (LString "` for `"))) (EApp (EVar "display") (EVar "iface"))) (ELit (LString "`: the body performs <"))) (EApp (EVar "display") (EApp (EVar "renderAtoms") (EVar "escaping")))) (ELit (LString ">, which no argument sources and the method's row does not declare; declare <"))) (EApp (EVar "display") (EApp (EVar "renderAtoms") (EVar "escaping")))) (ELit (LString "> in the method's row, or perform it through an argument"))))
(DTypeSig true "aliasesHeadRowMsg" (TyFun (TyCon "String") (TyFun (TyCon "Ty") (TyCon "String"))))
(DFunDef false "aliasesHeadRowMsg" ((PVar "subject") (PVar "mty")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "subject"))) (ELit (LString " identifies a method effect variable with the instance head's own effect-row parameter, which the declared type `"))) (EApp (EVar "display") (EApp (EVar "ppTy") (EVar "mty")))) (ELit (LString "` keeps distinct; keep the method's effect variable independent of the head's"))))
(DTypeSig false "implSubject" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "implSubject" ((PVar "iface") (PVar "mname")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "impl of `")) (EApp (EVar "display") (EVar "mname"))) (ELit (LString "` for `"))) (EApp (EVar "display") (EVar "iface"))) (ELit (LString "`"))))
(DTypeSig false "defaultSubject" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "defaultSubject" ((PVar "iface") (PVar "mname")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "default body of `")) (EApp (EVar "display") (EVar "mname"))) (ELit (LString "` in `"))) (EApp (EVar "display") (EVar "iface"))) (ELit (LString "`"))))
(DTypeSig true "narrowsImplHeadMsg" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "narrowsImplHeadMsg" ((PVar "subject") (PVar "narrowed") (PVar "head")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "subject"))) (ELit (LString " fixes the instance-head type "))) (EApp (EVar "display") (EApp (EVar "tyVarNoun") (EVar "narrowed")))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EVar "quotedNames") (EVar "narrowed")))) (ELit (LString ", but the impl is declared for every type in their place; narrow the head to `"))) (EApp (EVar "display") (EVar "head"))) (ELit (LString "`, or make the body parametric in "))) (EApp (EVar "display") (EApp (EVar "quotedNames") (EVar "narrowed")))) (ELit (LString ""))))
(DTypeSig true "indexEagerMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "indexEagerMsg" ((PVar "subject") (PVar "evar")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "subject"))) (ELit (LString " performs the effect variable <"))) (EApp (EVar "display") (EVar "evar"))) (ELit (LString "> at call time, but the signature charges <"))) (EApp (EVar "display") (EVar "evar"))) (ELit (LString "> only in a result index, `f "))) (EApp (EVar "display") (EVar "evar"))) (ELit (LString " ...`; defer it under the container's own <"))) (EApp (EVar "display") (EVar "evar"))) (ELit (LString "> thunk, or charge the method's arrow, `-> <"))) (EApp (EVar "display") (EVar "evar"))) (ELit (LString "> ...`"))))
(DTypeSig false "tyVarNoun" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "tyVarNoun" ((PList PWild)) (ELit (LString "variable")))
(DFunDef false "tyVarNoun" (PWild) (ELit (LString "variables")))
(DTypeSig true "pinsTyvarMsg" (TyFun (TyCon "String") (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))))
(DFunDef false "pinsTyvarMsg" ((PVar "subject") (PVar "mty") (PVar "pinned")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "subject"))) (ELit (LString " pins the method's quantified type "))) (EApp (EVar "display") (EApp (EVar "tyVarNoun") (EVar "pinned")))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EVar "quotedNames") (EVar "pinned")))) (ELit (LString ", which the declared type `"))) (EApp (EVar "display") (EApp (EVar "ppTy") (EVar "mty")))) (ELit (LString "` leaves to the caller; make the body parametric in "))) (EApp (EVar "display") (EApp (EVar "quotedNames") (EVar "pinned")))) (ELit (LString ""))))
(DTypeSig true "undeclaredConstraintMsg" (TyFun (TyCon "String") (TyFun (TyCon "Ty") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))))
(DFunDef false "undeclaredConstraintMsg" ((PVar "subject") (PVar "mty") (PVar "oiface") (PVar "vname")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "subject"))) (ELit (LString " requires `"))) (EApp (EVar "display") (EVar "oiface"))) (ELit (LString "` on the method's quantified type variable `"))) (EApp (EVar "display") (EVar "vname"))) (ELit (LString "`, which the declared type `"))) (EApp (EVar "display") (EApp (EVar "ppTy") (EVar "mty")))) (ELit (LString "` does not; add `"))) (EApp (EVar "display") (EVar "oiface"))) (ELit (LString " "))) (EApp (EVar "display") (EVar "vname"))) (ELit (LString " =>` to the method's signature"))))
(DTypeSig true "undeclaredImplPrerequisiteMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "undeclaredImplPrerequisiteMsg" ((PVar "subject") (PVar "oiface") (PVar "vname")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "subject"))) (ELit (LString " requires `"))) (EApp (EVar "display") (EVar "oiface"))) (ELit (LString "` on the instance-head type variable `"))) (EApp (EVar "display") (EVar "vname"))) (ELit (LString "`, which the impl does not declare; add `requires "))) (EApp (EVar "display") (EVar "oiface"))) (ELit (LString " "))) (EApp (EVar "display") (EVar "vname"))) (ELit (LString "` to the impl"))))
(DTypeSig true "implGoalFixesHeadMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))))
(DFunDef false "implGoalFixesHeadMsg" ((PVar "subject") (PVar "pred") (PVar "fixed")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "subject"))) (ELit (LString " requires `"))) (EApp (EVar "display") (EVar "pred"))) (ELit (LString "`, which only a specific instance-head type "))) (EApp (EVar "display") (EApp (EVar "tyVarNoun") (EVar "fixed")))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EVar "quotedNames") (EVar "fixed")))) (ELit (LString " satisfies, but the impl is declared for every type in their place; make the body parametric in "))) (EApp (EVar "display") (EApp (EVar "quotedNames") (EVar "fixed")))) (ELit (LString ", or narrow the head"))))
(DTypeSig true "undeclaredImplPredicateMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "undeclaredImplPredicateMsg" ((PVar "subject") (PVar "pred")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "subject"))) (ELit (LString " requires `"))) (EApp (EVar "display") (EVar "pred"))) (ELit (LString "` on the instance head's type variables, which the impl does not declare; add `requires "))) (EApp (EVar "display") (EVar "pred"))) (ELit (LString "` to the impl"))))
(DTypeSig true "collapsesTyvarsMsg" (TyFun (TyCon "String") (TyFun (TyCon "Ty") (TyCon "String"))))
(DFunDef false "collapsesTyvarsMsg" ((PVar "subject") (PVar "mty")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "subject"))) (ELit (LString " identifies quantified type variables that the declared type `"))) (EApp (EVar "display") (EApp (EVar "ppTy") (EVar "mty")))) (ELit (LString "` keeps distinct; keep them independent in the body"))))
(DTypeSig false "defaultEffectLaunderMsg" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "String"))))
(DFunDef false "defaultEffectLaunderMsg" ((PVar "subject") (PVar "escaping")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "subject"))) (ELit (LString " launders an effect: the body performs <"))) (EApp (EVar "display") (EApp (EVar "renderAtoms") (EVar "escaping")))) (ELit (LString ">, which no argument sources and the method's row does not declare; declare <"))) (EApp (EVar "display") (EApp (EVar "renderAtoms") (EVar "escaping")))) (ELit (LString "> in the method's row, or perform it through an argument"))))
(DTypeSig true "collapsesEffvarsMsg" (TyFun (TyCon "String") (TyFun (TyCon "Ty") (TyCon "String"))))
(DFunDef false "collapsesEffvarsMsg" ((PVar "subject") (PVar "mty")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "subject"))) (ELit (LString " identifies effect variables that the declared type `"))) (EApp (EVar "display") (EApp (EVar "ppTy") (EVar "mty")))) (ELit (LString "` keeps distinct; keep the body's effects on the variable the signature declares at each position"))))
(DTypeSig true "effVarLaunderMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "String")))))
(DFunDef false "effVarLaunderMsg" ((PVar "subject") (PVar "evar") (PVar "escaping")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "subject"))) (ELit (LString " launders an effect: the body performs <"))) (EApp (EVar "display") (EApp (EVar "renderAtoms") (EVar "escaping")))) (ELit (LString "> inside the effect variable <"))) (EApp (EVar "display") (EVar "evar"))) (ELit (LString "> at a position whose declared row does not include it; declare <"))) (EApp (EVar "display") (EApp (EVar "renderAtoms") (EVar "escaping")))) (ELit (LString "> at that position, or perform it through an argument"))))
(DTypeSig true "ffiArrowNote" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "ffiArrowNote" ((PVar "i") (PVar "arrows")) (EIf (EBinOp ">" (EVar "arrows") (ELit (LInt 1))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString " on the result of argument ")) (EApp (EVar "display") (EApp (EVar "display") (EVar "i")))) (ELit (LString " of "))) (EApp (EVar "display") (EApp (EVar "display") (EVar "arrows")))) (ELit (LString ""))) (ELit (LString ""))))
(DTypeSig true "effectEscapeMsg" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "String"))))))
(DFunDef false "effectEscapeMsg" ((PVar "name") (PVar "declared") (PVar "tail") (PVar "extras")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "` performs <"))) (EApp (EVar "display") (EApp (EVar "renderAtoms") (EVar "extras")))) (ELit (LString "> but its signature allows only "))) (EApp (EVar "display") (EApp (EApp (EVar "renderDeclaredRow") (EVar "declared")) (EVar "tail")))) (ELit (LString "; add <"))) (EApp (EVar "display") (EApp (EVar "renderAtoms") (EVar "extras")))) (ELit (LString "> to the declared row"))))
(DTypeSig false "renderDeclaredRow" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))
(DFunDef false "renderDeclaredRow" ((PVar "declared") (PList)) (EBinOp "++" (EBinOp "++" (ELit (LString "<")) (EApp (EVar "display") (EApp (EVar "renderAtoms") (EVar "declared")))) (ELit (LString ">"))))
(DFunDef false "renderDeclaredRow" ((PList) (PVar "tails")) (EBinOp "++" (EBinOp "++" (ELit (LString "<")) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString " | "))) (EVar "tails")))) (ELit (LString ">"))))
(DFunDef false "renderDeclaredRow" ((PVar "declared") (PVar "tails")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "<")) (EApp (EVar "display") (EApp (EVar "renderAtoms") (EVar "declared")))) (ELit (LString " | "))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString " | "))) (EVar "tails")))) (ELit (LString ">"))))
(DTypeSig true "sigOverExpansiveMsg" (TyFun (TyCon "String") (TyFun (TyCon "Ty") (TyCon "String"))))
(DFunDef false "sigOverExpansiveMsg" ((PVar "name") (PVar "ty")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "the signature of `")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "` is polymorphic (`"))) (EApp (EVar "display") (EApp (EVar "ppTy") (EVar "ty")))) (ELit (LString "`) but its body is not a value, so it cannot be generalized; give `"))) (EApp (EVar "display") (EVar "name"))) (ELit (LString "` a parameter or declare a monomorphic type"))))
(DTypeSig true "sigTooGeneralMsg" (TyFun (TyCon "String") (TyFun (TyCon "Ty") (TyCon "String"))))
(DFunDef false "sigTooGeneralMsg" ((PVar "name") (PVar "ty")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "the signature of `")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "` is more general than its body: `"))) (EApp (EVar "display") (EApp (EVar "ppTy") (EVar "ty")))) (ELit (LString "` claims type variables that inference makes the same type"))))
(DTypeSig true "annotTooGeneralMsg" (TyFun (TyCon "Ty") (TyCon "String")))
(DFunDef false "annotTooGeneralMsg" ((PVar "ty")) (EBinOp "++" (EBinOp "++" (ELit (LString "type annotation `")) (EApp (EVar "ppTy") (EVar "ty"))) (ELit (LString "` is more polymorphic than the expression: a type variable in it is a specific type, or two of its variables are the same type"))))
(DTypeSig true "requiresUnroutedMsg" (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "String"))))
(DFunDef false "requiresUnroutedMsg" ((PVar "iface") (PVar "args")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "cannot pass a dictionary for `")) (EApp (EVar "display") (EFieldAccess (EVar "iface") "irName"))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EVar "ppPredArgsShared") (EVar "args")))) (ELit (LString "`: a matching `impl "))) (EApp (EVar "display") (EFieldAccess (EVar "iface") "irName"))) (ELit (LString " ...` exists but is declared in a module this one does not import; import that module here, and if this binding has a signature, declare the constraint there too"))))
(DTypeSig true "missingConstraintVecMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))))
(DFunDef false "missingConstraintVecMsg" ((PVar "name") (PVar "iface") (PVar "varNames")) (EBlock (DoLet false false (PVar "pred") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EBinOp "::" (EVar "iface") (EVar "varNames")))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "the body of `")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "` requires `"))) (EApp (EVar "display") (EVar "pred"))) (ELit (LString "`, which its signature does not declare; add `"))) (EApp (EVar "display") (EVar "pred"))) (ELit (LString " =>`"))))))
(DTypeSig true "varNameForId" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))))) (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "varNameForId" ((PVar "sigTvMaps") (PVar "m") (PVar "id")) (EMatch (EApp (EApp (EVar "findSigTvMap") (EVar "m")) (EVar "sigTvMaps")) (arm (PCon "None") () (ELit (LString "a"))) (arm (PCon "Some" (PVar "tvMap")) () (EMatch (EApp (EApp (EVar "findTvName") (EVar "id")) (EVar "tvMap")) (arm (PCon "None") () (ELit (LString "a"))) (arm (PCon "Some" (PVar "n")) () (EVar "n"))))))
(DTypeSig false "findSigTvMap" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono")))))))
(DFunDef false "findSigTvMap" (PWild (PList)) (EVar "None"))
(DFunDef false "findSigTvMap" ((PVar "m") (PCons (PTuple (PVar "n") PWild (PVar "tvMap")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "n") (EVar "m")) (EApp (EVar "Some") (EVar "tvMap")) (EIf (EVar "otherwise") (EApp (EApp (EVar "findSigTvMap") (EVar "m")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "missingConstraintMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "missingConstraintMsg" ((PVar "name") (PVar "iface") (PVar "varName")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "the body of `")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "` requires `"))) (EApp (EVar "display") (EVar "iface"))) (ELit (LString " "))) (EApp (EVar "display") (EVar "varName"))) (ELit (LString "`, which its signature does not declare; add `"))) (EApp (EVar "display") (EVar "iface"))) (ELit (LString " "))) (EApp (EVar "display") (EVar "varName"))) (ELit (LString " =>`"))))
(DTypeSig true "ambigReexportMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))))
(DFunDef false "ambigReexportMsg" ((PVar "n") (PVar "depId") (PVar "mids")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "ambiguous `")) (EApp (EVar "display") (EVar "n"))) (ELit (LString "` imported from `"))) (EApp (EVar "display") (EVar "depId"))) (ELit (LString "`: defined in both "))) (EApp (EVar "display") (EApp (EVar "joinAnd") (EApp (EApp (EVar "map") (EVar "backticked")) (EVar "mids"))))) (ELit (LString ""))))
(DTypeSig true "ambigReexportHelp" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))))
(DFunDef false "ambigReexportHelp" ((PVar "n") (PVar "depId") (PVar "mids")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "display") (EVar "depId"))) (ELit (LString "` re-exports more than one `"))) (EApp (EVar "display") (EVar "n"))) (ELit (LString "`; import the definition you mean directly, as in `import "))) (EApp (EVar "display") (EApp (EVar "firstMid") (EVar "mids")))) (ELit (LString ".{"))) (EApp (EVar "display") (EVar "n"))) (ELit (LString "}`"))))
(DTypeSig false "firstMid" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "firstMid" ((PCons (PVar "m") PWild)) (EVar "m"))
(DFunDef false "firstMid" ((PList)) (ELit (LString "<module>")))
(DTypeSig true "locGoalKey" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "String")))
(DFunDef false "locGoalKey" ((PCon "None")) (ELit (LString "")))
(DFunDef false "locGoalKey" ((PCon "Some" (PCon "Loc" (PVar "file") (PVar "sl") (PVar "sc") (PVar "el") (PVar "ec")))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "file"))) (ELit (LString ":"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "sl")))) (ELit (LString ":"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "sc")))) (ELit (LString ":"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "el")))) (ELit (LString ":"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "ec")))) (ELit (LString ""))))
(DTypeSig false "allDigits" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "allDigits" ((PVar "n")) (EBinOp "&&" (EBinOp ">" (EApp (EVar "stringLength") (EVar "n")) (ELit (LInt 0))) (EApp (EApp (EVar "allDigitsFrom") (EVar "n")) (ELit (LInt 0)))))
(DTypeSig false "allDigitsFrom" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "allDigitsFrom" ((PVar "n") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "stringLength") (EVar "n"))) (EVar "True") (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "c") (EApp (EApp (EApp (EVar "stringSlice") (EVar "i")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n"))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LString "0"))) (EBinOp "<=" (EVar "c") (ELit (LString "9")))) (EApp (EApp (EVar "allDigitsFrom") (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "backticked" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "backticked" ((PVar "s")) (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "display") (EVar "s"))) (ELit (LString "`"))))
(DTypeSig true "appSpineName" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "appSpineName" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "appSpineName") (EVar "e")))
(DFunDef false "appSpineName" ((PCon "EDoOrigin" PWild (PVar "e"))) (EApp (EVar "appSpineName") (EVar "e")))
(DFunDef false "appSpineName" ((PCon "EAnnot" (PVar "e") PWild)) (EApp (EVar "appSpineName") (EVar "e")))
(DFunDef false "appSpineName" ((PCon "EApp" (PVar "f") PWild)) (EApp (EVar "appSpineName") (EVar "f")))
(DFunDef false "appSpineName" ((PCon "EVar" (PVar "n"))) (EApp (EVar "Some") (EVar "n")))
(DFunDef false "appSpineName" ((PCon "EVarId" (PVar "n") PWild)) (EApp (EVar "Some") (EVar "n")))
(DFunDef false "appSpineName" ((PCon "EVarAt" (PVar "n") PWild)) (EApp (EVar "Some") (EVar "n")))
(DFunDef false "appSpineName" ((PCon "EMethodAt" (PVar "n") PWild PWild)) (EApp (EVar "Some") (EVar "n")))
(DFunDef false "appSpineName" ((PCon "EDictAt" (PVar "n") PWild)) (EApp (EVar "Some") (EVar "n")))
(DFunDef false "appSpineName" (PWild) (EVar "None"))
(DTypeSig true "ordinalWord" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "ordinalWord" ((PLit (LInt 0))) (ELit (LString "first")))
(DFunDef false "ordinalWord" ((PLit (LInt 1))) (ELit (LString "second")))
(DFunDef false "ordinalWord" ((PLit (LInt 2))) (ELit (LString "third")))
(DFunDef false "ordinalWord" ((PLit (LInt 3))) (ELit (LString "fourth")))
(DFunDef false "ordinalWord" ((PLit (LInt 4))) (ELit (LString "fifth")))
(DFunDef false "ordinalWord" ((PVar "i")) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "intToString") (EBinOp "+" (EVar "i") (ELit (LInt 1)))))) (ELit (LString "th"))))
(DTypeSig true "noImplFoundMsg" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "String"))))
(DFunDef false "noImplFoundMsg" ((PVar "iface") (PList (PVar "arg"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "no impl of ")) (EApp (EVar "display") (EVar "iface"))) (ELit (LString " for "))) (EApp (EVar "display") (EApp (EVar "ppMonosShared") (EListLit (EVar "arg"))))) (ELit (LString ""))))
(DFunDef false "noImplFoundMsg" ((PVar "iface") (PVar "args")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "no impl of ")) (EApp (EVar "display") (EVar "iface"))) (ELit (LString " for "))) (EApp (EVar "display") (EApp (EVar "ppPredArgsShared") (EVar "args")))) (ELit (LString ""))))
(DTypeSig true "noImplAdvice" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "noImplAdvice" ((PVar "iface") (PVar "n")) (EIf (EApp (EVar "derivableIface") (EVar "iface")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "add `deriving ")) (EApp (EVar "display") (EVar "iface"))) (ELit (LString "` to `"))) (EApp (EVar "display") (EVar "n"))) (ELit (LString "` or write `impl "))) (EApp (EVar "display") (EVar "iface"))) (ELit (LString " "))) (EApp (EVar "display") (EVar "n"))) (ELit (LString "`"))) (EIf (EVar "otherwise") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "write `impl ")) (EApp (EVar "display") (EVar "iface"))) (ELit (LString " "))) (EApp (EVar "display") (EVar "n"))) (ELit (LString "`"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "derivableIface" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "derivableIface" ((PVar "iface")) (EApp (EApp (EVar "contains") (EVar "iface")) (EListLit (ELit (LString "Eq")) (ELit (LString "Ord")) (ELit (LString "Debug")) (ELit (LString "Display")) (ELit (LString "Generic")))))
(DTypeSig true "quotedNames" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "quotedNames" ((PVar "names")) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "map") (ELam ((PVar "n")) (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EVar "n")) (ELit (LString "`"))))) (EVar "names"))))
(DTypeSig true "locKey" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "String")))
(DFunDef false "locKey" ((PCon "None")) (ELit (LString "")))
(DFunDef false "locKey" ((PCon "Some" (PCon "Loc" (PVar "file") (PVar "line") (PVar "col") PWild PWild))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "file"))) (ELit (LString ":"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "line")))) (ELit (LString ":"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "col")))) (ELit (LString ""))))
(DTypeSig true "msgAtKey" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "String"))))
(DFunDef false "msgAtKey" ((PVar "msg") (PVar "at")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "msg"))) (ELit (LString "\t@@\t"))) (EApp (EVar "display") (EApp (EVar "locKey") (EVar "at")))) (ELit (LString ""))))
(DTypeSig false "writtenNames" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "writtenNames" ((PVar "text")) (EMatch (EApp (EApp (EVar "splitOnChar") (ELit (LChar "$"))) (EVar "text")) (arm (PList (PVar "only")) () (EVar "only")) (arm (PVar "parts") () (EApp (EVar "dropRenameSuffixes") (EVar "parts")))))
(DTypeSig false "dropRenameSuffixes" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "dropRenameSuffixes" ((PList)) (ELit (LString "")))
(DFunDef false "dropRenameSuffixes" ((PList (PVar "a"))) (EVar "a"))
(DFunDef false "dropRenameSuffixes" ((PCons (PVar "a") (PCons PWild (PCons (PVar "n") (PCons (PVar "lb") (PVar "more")))))) (EIf (EBinOp "&&" (EApp (EVar "allDigits") (EVar "n")) (EApp (EApp (EVar "startsWith") (ELit (LString "lb"))) (EVar "lb"))) (EBinOp "++" (EVar "a") (EApp (EVar "dropRenameSuffixes") (EBinOp "::" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 2))) (EApp (EVar "stringLength") (EVar "lb"))) (EVar "lb")) (EVar "more")))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "dropRenameSuffixes" ((PCons (PVar "a") (PVar "rest"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "a"))) (ELit (LString "$"))) (EApp (EVar "display") (EApp (EVar "dropRenameSuffixes") (EVar "rest")))) (ELit (LString ""))))
(DTypeSig true "writtenDiag" (TyFun (TyCon "TcDiag") (TyCon "TcDiag")))
(DFunDef false "writtenDiag" ((PCon "TcDiag" (PVar "code") (PVar "sev") (PVar "loc") (PVar "msg") (PVar "help") (PVar "fix"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "TcDiag") (EVar "code")) (EVar "sev")) (EVar "loc")) (EApp (EVar "writtenNames") (EVar "msg"))) (EApp (EApp (EVar "map") (EVar "writtenNames")) (EVar "help"))) (EVar "fix")))
(DTypeSig true "findTupleCand" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Mono") (TyCon "String") (TyApp (TyCon "Option") (TyTuple (TyCon "Loc") (TyCon "String"))))) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyTuple (TyCon "Loc") (TyCon "String"))))))))
(DFunDef false "findTupleCand" (PWild (PList)) (EVar "None"))
(DFunDef false "findTupleCand" ((PVar "key") (PCons (PTuple (PVar "res") (PVar "help") (PVar "fix")) (PVar "rest"))) (EIf (EBinOp "==" (EApp (EVar "ppMono") (EApp (EVar "normalize") (EVar "res"))) (EVar "key")) (EApp (EVar "Some") (ETuple (EVar "help") (EVar "fix"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "findTupleCand") (EVar "key")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "prependDiagOpt" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "TcDiag")) (TyApp (TyCon "List") (TyCon "TcDiag"))))))))
(DFunDef false "prependDiagOpt" (PWild PWild PWild (PCon "None") (PVar "ds")) (EVar "ds"))
(DFunDef false "prependDiagOpt" ((PVar "code") (PVar "sev") (PVar "help") (PCon "Some" (PVar "msg")) (PVar "ds")) (EBinOp "::" (EApp (EVar "writtenDiag") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "TcDiag") (EVar "code")) (EVar "sev")) (EVar "None")) (EVar "msg")) (EVar "help")) (EVar "None"))) (EVar "ds")))
# MARK
(DUse false (UseGroup ("types" "tc_mono") ((mem "cohPpPair" false) (mem "dedupI" false) (mem "findTvName" false) (mem "firstIdConflict" false) (mem "headIdConflict" false) (mem "headTyconNameMono" false) (mem "isPreludeOrigin" false) (mem "recordOwnerModule" false) (mem "recordResultMono" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "authTermsSurface" false) (mem "EffAtomTy" true) (mem "EffParamTy" true) (mem "Expr" true) (mem "KindAnn" true) (mem "kindAnnSource" false) (mem "Lit" true) (mem "Loc" true) (mem "patternMark" false) (mem "qualifierSource" false) (mem "TabKey" true) (mem "tabKeyName" false) (mem "Ty" true) (mem "TyConOrigin" true))))
(DUse false (UseGroup ("types" "repr") ((mem "normalize" false) (mem "IfaceRef" true) (mem "Mono" true) (mem "ppAuthority" false) (mem "ppConName" false) (mem "ppEach" false) (mem "ppEffArgFmt" false) (mem "ppEffInsideTy" false) (mem "ppEffvarName" false) (mem "ppGo" false) (mem "ppMono" false) (mem "ppMonosShared" false) (mem "ppPredArgsShared" false) (mem "ppTy" false) (mem "ppTyAtom" false) (mem "tupleHeadTagTc" false))))
(DUse false (UseGroup ("types" "tc_types") ((mem "DeclaringBinder" true) (mem "KeyEntry" false) (mem "Kind" true) (mem "MethodBodyKind" true) (mem "RecordInfo" false))))
(DUse false (UseGroup ("types" "publish") ((mem "TcDiag" true))))
(DUse false (UseGroup ("support" "util") ((mem "contains" false) (mem "dedup" false) (mem "dedupBy" false) (mem "escStr" false) (mem "isEmptyL" false) (mem "isNonEmptyL" false) (mem "joinWith" false) (mem "listLen" false) (mem "reverseL" false) (mem "sortUniqS" false) (mem "splitOnChar" false) (mem "startsWith" false))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "Atom" true) (mem "effLabelName" false) (mem "Effvar" true) (mem "renderAtoms" false))))
(DUse false (UseGroup ("types" "effect_authority") ((mem "authIsTop" false) (mem "Authority" true))))
(DTypeSig true "effectInclusionMsg" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))))
(DFunDef false "effectInclusionMsg" ((PVar "name") (PVar "escaping") (PList (PVar "required") (PVar "allowed"))) (EIf (EApp (EVar "isNonEmptyL") (EVar "escaping")) (EBlock (DoLet false false (PVar "labels") (EApp (EVar "renderAtoms") (EVar "escaping"))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "` performs <"))) (EApp (EMethodRef "display") (EVar "labels"))) (ELit (LString "> on a caller-chosen row "))) (EApp (EMethodRef "display") (EApp (EVar "rowText") (EVar "allowed")))) (ELit (LString "; "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "declareRemedy") (EVar "labels")) (EVar "allowed")))) (ELit (LString ", or perform it through an argument"))))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "` runs the caller-chosen row "))) (EApp (EMethodRef "display") (EApp (EVar "rowText") (EVar "required")))) (ELit (LString " where only "))) (EApp (EMethodRef "display") (EApp (EVar "rowText") (EVar "allowed")))) (ELit (LString " is allowed; declare it on the arrow that runs it, `-> "))) (EApp (EMethodRef "display") (EApp (EVar "rowText") (EVar "required")))) (ELit (LString " ...`")))))
(DFunDef false "effectInclusionMsg" ((PVar "name") PWild (PVar "rows")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "cannot prove effect row inclusion in `")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "`: "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EVar "rows")))) (ELit (LString ""))))
(DTypeSig false "rowText" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "rowText" ((PVar "s")) (EIf (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 1))) (EVar "s")) (ELit (LString "<"))) (EVar "s") (EBinOp "++" (EBinOp "++" (ELit (LString "<")) (EApp (EMethodRef "display") (EVar "s"))) (ELit (LString ">")))))
(DTypeSig false "declareRemedy" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "declareRemedy" ((PVar "labels") (PVar "allowed")) (EIf (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 1))) (EVar "allowed")) (ELit (LString "<"))) (EBinOp "++" (EBinOp "++" (ELit (LString "declare <")) (EApp (EMethodRef "display") (EVar "labels"))) (ELit (LString "> in that row"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "declare it, `<")) (EApp (EMethodRef "display") (EVar "labels"))) (ELit (LString " | "))) (EApp (EMethodRef "display") (EVar "allowed"))) (ELit (LString ">`")))))
(DTypeSig true "patternIndexMsg" (TyFun (TyCon "Authority") (TyCon "String")))
(DFunDef false "patternIndexMsg" ((PVar "term")) (EBlock (DoLet false false (PVar "t") (EApp (EApp (EApp (EVar "authorityTermTextIn") (EApp (EVar "Ref") (EListLit))) (EApp (EVar "Ref") (ELit (LInt 0)))) (EVar "term"))) (DoExpr (EBinOp "++" (EBinOp "++" (ELit (LString "a pattern-ranging `Authority L*` index is equated with ")) (EApp (EMethodRef "display") (EVar "t"))) (ELit (LString ", which is not a pattern; write a pattern there, such as `\"data/*\"` or `*`"))))))
(DTypeSig true "renderFlatRow" (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Effvar")))) (TyCon "String")))
(DFunDef false "renderFlatRow" ((PVar "f")) (EBlock (DoLet false false (PVar "ctx") (EApp (EVar "Ref") (EListLit))) (DoLet false false (PVar "cnt") (EApp (EVar "Ref") (ELit (LInt 0)))) (DoExpr (EApp (EApp (EVar "ppEffArgFmt") (EApp (EVar "renderAtomsOrEmpty") (EApp (EVar "fst") (EVar "f")))) (EApp (EApp (EVar "joinWith") (ELit (LString " | "))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "m")) (EApp (EApp (EApp (EVar "ppEffvarName") (EVar "ctx")) (EVar "cnt")) (EVar "m")))) (EApp (EVar "snd") (EVar "f"))))))))
(DTypeSig false "renderAtomsOrEmpty" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "String")))
(DFunDef false "renderAtomsOrEmpty" ((PList)) (ELit (LString "")))
(DFunDef false "renderAtomsOrEmpty" ((PVar "ls")) (EApp (EVar "renderAtoms") (EVar "ls")))
(DTypeSig true "joinMismatchMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "joinMismatchMsg" ((PVar "a") (PVar "b")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "effect rows ")) (EApp (EMethodRef "display") (EVar "a"))) (ELit (LString " and "))) (EApp (EMethodRef "display") (EVar "b"))) (ELit (LString " cannot be made equal: each carries an effect variable the other has no room for; keep the method's effect variables distinct, or join them in the result index, `f (e | e2) b`"))))
(DTypeSig true "indexRowMismatchMsg" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "String"))))
(DFunDef false "indexRowMismatchMsg" ((PVar "l1") (PVar "l2")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "effect index mismatch: <")) (EApp (EMethodRef "display") (EApp (EVar "renderAtoms") (EVar "l1")))) (ELit (LString "> vs <"))) (EApp (EMethodRef "display") (EApp (EVar "renderAtoms") (EVar "l2")))) (ELit (LString ">; an effect row in a type argument is invariant, so write the same row on both sides or use a row variable, "))) (EApp (EMethodRef "display") (EApp (EVar "openRowHint") (EVar "l1")))) (ELit (LString ""))))
(DTypeSig false "openRowHint" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "String")))
(DFunDef false "openRowHint" ((PList)) (ELit (LString "`e`")))
(DFunDef false "openRowHint" ((PVar "atoms")) (EBinOp "++" (EBinOp "++" (ELit (LString "`<")) (EApp (EMethodRef "display") (EApp (EVar "renderAtoms") (EVar "atoms")))) (ELit (LString " | e>`"))))
(DTypeSig true "closedRowMismatchMsg" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "String"))))
(DFunDef false "closedRowMismatchMsg" ((PVar "l1") (PVar "l2")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "effect rows <")) (EApp (EMethodRef "display") (EApp (EVar "renderAtoms") (EVar "l1")))) (ELit (LString "> and <"))) (EApp (EMethodRef "display") (EApp (EVar "renderAtoms") (EVar "l2")))) (ELit (LString "> cannot be made equal: the two values must have one type, and this position neither widens nor narrows a row; write the same row on both sides"))))
(DTypeSig true "patternDomainMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "patternDomainMsg" ((PVar "written") (PVar "l")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EMethodRef "display") (EVar "written"))) (ELit (LString "` ranges over patterns, but `"))) (EApp (EMethodRef "display") (EVar "l"))) (ELit (LString "` is not a `Prefix` domain and has none; drop the `*`"))))
(DTypeSig true "authorityAtomicLabelMsg" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "authorityAtomicLabelMsg" ((PVar "l")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`Authority ")) (EApp (EMethodRef "display") (EVar "l"))) (ELit (LString "` needs a domain, but `"))) (EApp (EMethodRef "display") (EVar "l"))) (ELit (LString "` is an atomic label and declares none; declare it `effect "))) (EApp (EMethodRef "display") (EVar "l"))) (ELit (LString " Prefix`"))))
(DTypeSig true "phantomExportMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "phantomExportMsg" ((PVar "tyName") (PVar "ctor") (PVar "p")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "constructor `")) (EApp (EMethodRef "display") (EVar "ctor"))) (ELit (LString "` of public type `"))) (EApp (EMethodRef "display") (EVar "tyName"))) (ELit (LString "` carries its authority parameter `"))) (EApp (EMethodRef "display") (EVar "p"))) (ELit (LString "` in no field, so another module could invent an authority; export `"))) (EApp (EMethodRef "display") (EVar "tyName"))) (ELit (LString "` abstractly with `export data`, or give `"))) (EApp (EMethodRef "display") (EVar "ctor"))) (ELit (LString "` a field that carries `"))) (EApp (EMethodRef "display") (EVar "p"))) (ELit (LString "`"))))
(DTypeSig true "authorityParamAsRowMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "authorityParamAsRowMsg" ((PVar "name") (PVar "p")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "type `")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "` declares `"))) (EApp (EMethodRef "display") (EVar "p"))) (ELit (LString "` as an authority, but a field uses it as an effect row; write a different variable for the row"))))
(DTypeSig true "authorityParamAsTypeMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "authorityParamAsTypeMsg" ((PVar "name") (PVar "p")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "type `")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "` declares `"))) (EApp (EMethodRef "display") (EVar "p"))) (ELit (LString "` as an authority, but a field uses it as a type; write a different variable for the type"))))
(DTypeSig true "ifaceParamAuthorityKindMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "ifaceParamAuthorityKindMsg" ((PVar "name") (PVar "p")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "interface `")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "` declares `"))) (EApp (EMethodRef "display") (EVar "p"))) (ELit (LString "` as an authority, but an interface parameter is a type or a graded constructor; index a data type with `("))) (EApp (EMethodRef "display") (EVar "p"))) (ELit (LString " : Authority L)` and implement the interface for it"))))
(DTypeSig true "unannotatedRowParamMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "unannotatedRowParamMsg" ((PVar "name") (PVar "p")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "type parameter `")) (EApp (EMethodRef "display") (EVar "p"))) (ELit (LString "` of `"))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "` is used as an effect row, but its head does not declare it one; declare the head as `"))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString " ("))) (EApp (EMethodRef "display") (EVar "p"))) (ELit (LString " : Effect) ...`"))))
(DTypeSig true "typeParamAsRowMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "typeParamAsRowMsg" ((PVar "name") (PVar "p")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "type parameter `")) (EApp (EMethodRef "display") (EVar "p"))) (ELit (LString "` of `"))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "` is declared `("))) (EApp (EMethodRef "display") (EVar "p"))) (ELit (LString " : Type)` but is used as an effect row; declare it `("))) (EApp (EMethodRef "display") (EVar "p"))) (ELit (LString " : Effect)`"))))
(DTypeSig true "effectParamAsTypeMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "effectParamAsTypeMsg" ((PVar "name") (PVar "p")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "type parameter `")) (EApp (EMethodRef "display") (EVar "p"))) (ELit (LString "` of `"))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "` is declared `("))) (EApp (EMethodRef "display") (EVar "p"))) (ELit (LString " : Effect)` but is used as an ordinary type; drop the annotation, or move `"))) (EApp (EMethodRef "display") (EVar "p"))) (ELit (LString "` into an effect position such as `Unit -> <"))) (EApp (EMethodRef "display") (EVar "p"))) (ELit (LString "> a`"))))
(DTypeSig true "effectArrowOnDataHeadMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "KindAnn") (TyCon "String")))))
(DFunDef false "effectArrowOnDataHeadMsg" ((PVar "name") (PVar "p") (PVar "k")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "type parameter `")) (EApp (EMethodRef "display") (EVar "p"))) (ELit (LString "` of `"))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "` is declared with kind `"))) (EApp (EMethodRef "display") (EApp (EVar "kindAnnSource") (EVar "k")))) (ELit (LString "`, but an arrow kind containing `Effect` is allowed on interface heads only; declare it `Effect` or an Effect-free kind"))))
(DTypeSig true "ifaceSlotDeclaredTypeMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "KindAnn") (TyCon "String")))))
(DFunDef false "ifaceSlotDeclaredTypeMsg" ((PVar "name") (PVar "p") (PVar "k")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "type parameter `")) (EApp (EMethodRef "display") (EVar "p"))) (ELit (LString "` of interface `"))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "` is declared `("))) (EApp (EMethodRef "display") (EVar "p"))) (ELit (LString " : "))) (EApp (EMethodRef "display") (EApp (EVar "kindAnnSource") (EVar "k")))) (ELit (LString ")`, but a method uses one of its `Type` slots as an effect row; declare that slot `Effect`"))))
(DTypeSig true "ifaceParamEffectKindMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "ifaceParamEffectKindMsg" ((PVar "name") (PVar "p")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "type parameter `")) (EApp (EMethodRef "display") (EVar "p"))) (ELit (LString "` of interface `"))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "` is declared `("))) (EApp (EMethodRef "display") (EVar "p"))) (ELit (LString " : Effect)`, but an interface parameter is a type constructor; write `("))) (EApp (EMethodRef "display") (EVar "p"))) (ELit (LString " : Effect -> Type -> Type)` for an effect-indexed constructor"))))
(DTypeSig true "unannotatedGradedParamMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Kind")) (TyCon "String")))))
(DFunDef false "unannotatedGradedParamMsg" ((PVar "name") (PVar "p") (PVar "inferred")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "type parameter `")) (EApp (EMethodRef "display") (EVar "p"))) (ELit (LString "` of interface `"))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "` is used as an effect-indexed constructor, but its head does not declare it one; declare the head as `"))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString " ("))) (EApp (EMethodRef "display") (EVar "p"))) (ELit (LString " : "))) (EApp (EMethodRef "display") (EApp (EVar "renderKindArrow") (EVar "inferred")))) (ELit (LString ") ...`"))))
(DTypeSig true "requiresKindMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "requiresKindMsg" ((PVar "name") (PVar "sh")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "interface `")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "` requires `"))) (EApp (EMethodRef "display") (EVar "sh"))) (ELit (LString "` at a parameter whose kind differs from `"))) (EApp (EMethodRef "display") (EVar "sh"))) (ELit (LString "`'s own, and there is no coercion between `Type` and `Effect`; declare both heads at the same kind"))))
(DTypeSig true "argAtomsMsgFor" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "String"))))))
(DFunDef false "argAtomsMsgFor" ((PCon "Some" (PVar "iface")) (PVar "mname") (PVar "v") (PVar "esc")) (EApp (EApp (EApp (EApp (EVar "argAtomsUncoveredMsg") (EVar "iface")) (EVar "mname")) (EVar "v")) (EVar "esc")))
(DFunDef false "argAtomsMsgFor" ((PCon "None") (PVar "fname") (PVar "v") (PVar "esc")) (EApp (EApp (EApp (EVar "argAtomsUncoveredFnMsg") (EVar "fname")) (EVar "v")) (EVar "esc")))
(DTypeSig false "argAtomsUncoveredFnMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "String")))))
(DFunDef false "argAtomsUncoveredFnMsg" ((PVar "fname") (PVar "v") (PVar "esc")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "effect variable <")) (EApp (EMethodRef "display") (EVar "v"))) (ELit (LString "> in function `"))) (EApp (EMethodRef "display") (EVar "fname"))) (ELit (LString "` carries <"))) (EApp (EMethodRef "display") (EApp (EVar "renderAtoms") (EVar "esc")))) (ELit (LString "> at an argument position, but a row carrying <"))) (EApp (EMethodRef "display") (EVar "v"))) (ELit (LString "> does not include it; declare <"))) (EApp (EMethodRef "display") (EApp (EVar "renderAtoms") (EVar "esc")))) (ELit (LString "> at every row where <"))) (EApp (EMethodRef "display") (EVar "v"))) (ELit (LString "> appears"))))
(DTypeSig true "argOnlyEffVarMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "argOnlyEffVarMsg" ((PVar "iface") (PVar "mname") (PVar "v")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "argument-only effect variable <")) (EApp (EMethodRef "display") (EVar "v"))) (ELit (LString "> in method `"))) (EApp (EMethodRef "display") (EVar "mname"))) (ELit (LString "` of interface `"))) (EApp (EMethodRef "display") (EVar "iface"))) (ELit (LString "`: it rides an argument but appears in none of the method's own effect rows; thread it through the method's row, `-> <"))) (EApp (EMethodRef "display") (EVar "v"))) (ELit (LString "> ...`"))))
(DTypeSig false "argAtomsUncoveredMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "String"))))))
(DFunDef false "argAtomsUncoveredMsg" ((PVar "iface") (PVar "mname") (PVar "v") (PVar "esc")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "effect variable <")) (EApp (EMethodRef "display") (EVar "v"))) (ELit (LString "> in method `"))) (EApp (EMethodRef "display") (EVar "mname"))) (ELit (LString "` of interface `"))) (EApp (EMethodRef "display") (EVar "iface"))) (ELit (LString "` carries <"))) (EApp (EMethodRef "display") (EApp (EVar "renderAtoms") (EVar "esc")))) (ELit (LString "> at an argument position, but a method row carrying <"))) (EApp (EMethodRef "display") (EVar "v"))) (ELit (LString "> does not include it; declare <"))) (EApp (EMethodRef "display") (EApp (EVar "renderAtoms") (EVar "esc")))) (ELit (LString "> at every row where <"))) (EApp (EMethodRef "display") (EVar "v"))) (ELit (LString "> appears"))))
(DTypeSig false "renderEffTailVars" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "renderEffTailVars" ((PVar "vs")) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "v")) (EBinOp "++" (EBinOp "++" (ELit (LString "<")) (EApp (EMethodRef "display") (EVar "v"))) (ELit (LString ">"))))) (EVar "vs"))))
(DTypeSig true "effectUndeterminedMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))))
(DFunDef false "effectUndeterminedMsg" ((PVar "iface") (PVar "mname") (PVar "vars")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "under-determined effect variable ")) (EApp (EMethodRef "display") (EApp (EVar "renderEffTailVars") (EVar "vars")))) (ELit (LString " in method `"))) (EApp (EMethodRef "display") (EVar "mname"))) (ELit (LString "` of interface `"))) (EApp (EMethodRef "display") (EVar "iface"))) (ELit (LString "`: it appears only in the return type, pinned by no argument; use a concrete row such as `<Stdout>`, or thread it through a callback `a -> <e> b`"))))
(DTypeSig true "kindName" (TyFun (TyCon "Kind") (TyCon "String")))
(DFunDef false "kindName" ((PCon "KType")) (ELit (LString "Type")))
(DFunDef false "kindName" ((PCon "KRow")) (ELit (LString "Effect")))
(DFunDef false "kindName" ((PCon "KAuth" (PVar "l") (PVar "pat"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Authority ")) (EApp (EMethodRef "display") (EApp (EVar "effLabelName") (EVar "l")))) (ELit (LString ""))) (EApp (EMethodRef "display") (EApp (EVar "patternMark") (EVar "pat")))) (ELit (LString ""))))
(DTypeSig true "renderKindArrow" (TyFun (TyApp (TyCon "List") (TyCon "Kind")) (TyCon "String")))
(DFunDef false "renderKindArrow" ((PVar "ks")) (EApp (EApp (EVar "joinWith") (ELit (LString " -> "))) (EBinOp "++" (EApp (EApp (EMethodRef "map") (EVar "kindName")) (EVar "ks")) (EListLit (ELit (LString "Type"))))))
(DTypeSig true "implKindMismatchMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Kind")) (TyFun (TyApp (TyCon "List") (TyCon "Kind")) (TyCon "String")))))))
(DFunDef false "implKindMismatchMsg" ((PVar "iface") (PVar "ctor") (PVar "nApplied") (PVar "want") (PVar "got")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "instance head has the wrong kind for interface `")) (EApp (EMethodRef "display") (EVar "iface"))) (ELit (LString "`: its type parameter is graded, kind `"))) (EApp (EMethodRef "display") (EApp (EVar "renderKindArrow") (EVar "want")))) (ELit (LString "`, but "))) (EApp (EMethodRef "display") (EApp (EApp (EApp (EVar "implHeadKindClause") (EVar "ctor")) (EVar "nApplied")) (EVar "got")))) (ELit (LString "; "))) (EApp (EMethodRef "display") (EApp (EApp (EApp (EVar "implKindMismatchFix") (EVar "iface")) (EVar "ctor")) (EVar "nApplied")))) (ELit (LString ""))))
(DTypeSig false "argumentNoun" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "argumentNoun" ((PVar "n")) (EIf (EBinOp "==" (EVar "n") (ELit (LInt 1))) (ELit (LString "argument")) (ELit (LString "arguments"))))
(DTypeSig false "implHeadKindClause" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Kind")) (TyCon "String")))))
(DFunDef false "implHeadKindClause" ((PVar "ctor") (PVar "nApplied") (PVar "got")) (EIf (EBinOp "<=" (EVar "nApplied") (ELit (LInt 0))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EMethodRef "display") (EApp (EVar "ppConName") (EVar "ctor")))) (ELit (LString "` has kind `"))) (EApp (EMethodRef "display") (EApp (EVar "renderKindArrow") (EVar "got")))) (ELit (LString "`"))) (EIf (EVar "otherwise") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "this head applies ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "nApplied")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EVar "argumentNoun") (EVar "nApplied")))) (ELit (LString " to `"))) (EApp (EMethodRef "display") (EApp (EVar "ppConName") (EVar "ctor")))) (ELit (LString "`, leaving kind `"))) (EApp (EMethodRef "display") (EApp (EVar "renderKindArrow") (EVar "got")))) (ELit (LString "`"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "implKindMismatchFix" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "implKindMismatchFix" ((PVar "iface") (PVar "ctor") (PVar "nApplied")) (EIf (EBinOp ">" (EVar "nApplied") (ELit (LInt 0))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "a graded interface binds the whole row-indexed family, so write `impl ")) (EApp (EMethodRef "display") (EVar "iface"))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EVar "ppConName") (EVar "ctor")))) (ELit (LString "` with no arguments"))) (EIf (EVar "otherwise") (EBinOp "++" (EBinOp "++" (ELit (LString "give `")) (EApp (EMethodRef "display") (EApp (EVar "ppConName") (EVar "ctor")))) (ELit (LString "` a parameter used in an effect position at each `Row` slot, such as a field `Unit -> <e> a`, or implement a non-graded interface for it"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "implTupleHeadKindMsg" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Kind")) (TyCon "String")))))
(DFunDef false "implTupleHeadKindMsg" ((PVar "iface") (PVar "n") (PVar "want")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "instance head `")) (EApp (EMethodRef "display") (EApp (EVar "ppConName") (EApp (EVar "tupleHeadTagTc") (EVar "n"))))) (ELit (LString "` has the wrong kind for interface `"))) (EApp (EMethodRef "display") (EVar "iface"))) (ELit (LString "`: its type parameter is graded, kind `"))) (EApp (EMethodRef "display") (EApp (EVar "renderKindArrow") (EVar "want")))) (ELit (LString "`, but a tuple is kind `Type`; implement a non-graded interface for it, or use a row-indexed data type as the head"))))
(DTypeSig true "binderDomainTypeMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "binderDomainTypeMsg" ((PVar "n") (PVar "ty")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "named argument `")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "` has type `"))) (EApp (EMethodRef "display") (EVar "ty"))) (ELit (LString "` but is written with a domain, and only a `String` argument has an authority; give `"))) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "` the type `String` or drop the domain"))))
(DTypeSig true "binderTypeMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "binderTypeMsg" ((PVar "n") (PVar "ty")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "named argument `")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "` has type `"))) (EApp (EMethodRef "display") (EVar "ty"))) (ELit (LString "`, but an effect atom names it as an authority, and only a `String` argument can be one; give `"))) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "` the type `String` or write the label bare"))))
(DTypeSig true "binderDomainMsg" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "binderDomainMsg" ((PVar "n")) (EBinOp "++" (EBinOp "++" (ELit (LString "authority `")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "` is used at labels from different domains, and one authority has one domain; name a second binder for the other label"))))
(DTypeSig true "stickyDiagsInPushOrder" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TcDiag"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TcDiag")))))
(DFunDef false "stickyDiagsInPushOrder" ((PVar "diags")) (EApp (EApp (EVar "dedupBy") (EVar "tcDiagGoalKey")) (EApp (EVar "reverseL") (EVar "diags"))))
(DTypeSig true "tcDiagGoalKey" (TyFun (TyTuple (TyCon "String") (TyCon "TcDiag")) (TyCon "String")))
(DFunDef false "tcDiagGoalKey" ((PTuple (PVar "mid") (PCon "TcDiag" (PVar "code") PWild (PVar "loc") (PVar "msg") PWild PWild))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "mid"))) (ELit (LString "|"))) (EApp (EMethodRef "display") (EVar "code"))) (ELit (LString "|"))) (EApp (EMethodRef "display") (EApp (EVar "locGoalKey") (EVar "loc")))) (ELit (LString "|"))) (EApp (EMethodRef "display") (EVar "msg"))) (ELit (LString ""))))
(DTypeSig true "authorityIndexMsg" (TyFun (TyCon "Authority") (TyFun (TyCon "Authority") (TyCon "String"))))
(DFunDef false "authorityIndexMsg" ((PVar "a") (PVar "b")) (EBlock (DoLet false false (PVar "ctx") (EApp (EVar "Ref") (EListLit))) (DoLet false false (PVar "cnt") (EApp (EVar "Ref") (ELit (LInt 0)))) (DoLet false false (PVar "sa") (EApp (EApp (EApp (EVar "authorityTermTextIn") (EVar "ctx")) (EVar "cnt")) (EVar "a"))) (DoLet false false (PVar "sb") (EApp (EApp (EApp (EVar "authorityTermTextIn") (EVar "ctx")) (EVar "cnt")) (EVar "b"))) (DoLet false false (PTuple (PVar "x") (PVar "y")) (EIf (EBinOp "<=" (EVar "sa") (EVar "sb")) (ETuple (EVar "sa") (EVar "sb")) (ETuple (EVar "sb") (EVar "sa")))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "authority index mismatch: ")) (EApp (EMethodRef "display") (EVar "x"))) (ELit (LString " vs "))) (EApp (EMethodRef "display") (EVar "y"))) (ELit (LString "; an authority in a type argument is invariant, so write the same index on both sides or name it, `Handle p`"))))))
(DTypeSig true "authorityCoverMsg" (TyFun (TyCon "Authority") (TyFun (TyCon "Authority") (TyCon "String"))))
(DFunDef false "authorityCoverMsg" ((PVar "lower") (PVar "upper")) (EBlock (DoLet false false (PVar "ctx") (EApp (EVar "Ref") (EListLit))) (DoLet false false (PVar "cnt") (EApp (EVar "Ref") (ELit (LInt 0)))) (DoLet false false (PVar "lo") (EApp (EApp (EApp (EVar "authorityTermTextIn") (EVar "ctx")) (EVar "cnt")) (EVar "lower"))) (DoLet false false (PVar "hi") (EApp (EApp (EApp (EVar "authorityTermTextIn") (EVar "ctx")) (EVar "cnt")) (EVar "upper"))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "authority index mismatch: ")) (EApp (EMethodRef "display") (EVar "lo"))) (ELit (LString " is not covered by "))) (EApp (EMethodRef "display") (EVar "hi"))) (ELit (LString "; stay within "))) (EApp (EMethodRef "display") (EVar "hi"))) (ELit (LString ", or widen the row's authority for the label"))))))
(DTypeSig true "authorityTermTextIn" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String")))) (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyFun (TyCon "Authority") (TyCon "String")))))
(DFunDef false "authorityTermTextIn" ((PVar "ctx") (PVar "cnt") (PVar "q")) (EIf (EApp (EVar "authIsTop") (EVar "q")) (ELit (LString "the whole domain")) (EApp (EApp (EApp (EVar "ppAuthority") (EVar "ctx")) (EVar "cnt")) (EVar "q"))))
(DTypeSig true "residualFailureMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "residualFailureMsg" ((PVar "callee") (PVar "lo") (PVar "hi")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EMethodRef "display") (EVar "callee"))) (ELit (LString "` needs "))) (EApp (EMethodRef "display") (EVar "lo"))) (ELit (LString " to lie within "))) (EApp (EMethodRef "display") (EVar "hi"))) (ELit (LString " here, but this use does not satisfy it; pass values whose authorities do"))))
(DTypeSig true "starSpelling" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyCon "String"))))
(DFunDef false "starSpelling" ((PVar "n") (PCon "Some" (PVar "l"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "` pattern-ranging, `("))) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString " : String @"))) (EApp (EMethodRef "display") (EVar "l"))) (ELit (LString "*)` or `("))) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString " : Authority "))) (EApp (EMethodRef "display") (EVar "l"))) (ELit (LString "*)`"))))
(DFunDef false "starSpelling" ((PVar "n") (PCon "None")) (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "` pattern-ranging, `@L*` or `Authority L*`"))))
(DTypeSig true "paramVarianceMismatchMsg" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "String"))))
(DFunDef false "paramVarianceMismatchMsg" ((PVar "l1") (PVar "l2")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "effect row mismatch inside a non-covariant type argument: <")) (EApp (EMethodRef "display") (EApp (EVar "renderAtoms") (EVar "l1")))) (ELit (LString "> vs <"))) (EApp (EMethodRef "display") (EApp (EVar "renderAtoms") (EVar "l2")))) (ELit (LString ">; the two rows must be equal here, so write the same row on both sides, or eta-expand a freshly built function, `(s => f s)`"))))
(DTypeSig true "elselessIfHelp" (TyCon "String"))
(DFunDef false "elselessIfHelp" () (ELit (LString "an `if` without `else` has type Unit, so add an `else` branch or make the `then` branch Unit")))
(DTypeSig true "constrainedApplicationText" (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))))
(DFunDef false "constrainedApplicationText" ((PVar "app") (PVar "plain") (PVar "ifaces")) (EBlock (DoLet false false (PVar "names") (EApp (EApp (EVar "joinWith") (ELit (LString " and "))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "i")) (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EMethodRef "display") (EVar "i"))) (ELit (LString "`"))))) (EVar "ifaces")))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EMethodRef "display") (EApp (EVar "ppMono") (EVar "app")))) (ELit (LString "` is a value whose type implements "))) (EApp (EMethodRef "display") (EVar "names"))) (ELit (LString ", and `"))) (EApp (EMethodRef "display") (EApp (EVar "ppMono") (EVar "plain")))) (ELit (LString "` is not"))))))
(DTypeSig true "sameSpellingHint" (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "sameSpellingHint" ((PVar "a") (PVar "b")) (EIf (EBinOp "/=" (EApp (EVar "ppMono") (EVar "a")) (EApp (EVar "ppMono") (EVar "b"))) (EApp (EApp (EMethodRef "map") (EVar "idConflictHelp")) (EApp (EApp (EVar "headIdConflict") (EVar "a")) (EVar "b"))) (EIf (EVar "otherwise") (EApp (EApp (EMethodRef "map") (EVar "idConflictHelp")) (EApp (EApp (EVar "firstIdConflict") (EVar "a")) (EVar "b"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "idConflictHelp" (TyFun (TyTuple (TyCon "String") (TyCon "TyConOrigin") (TyCon "TyConOrigin")) (TyCon "String")))
(DFunDef false "idConflictHelp" ((PTuple (PVar "name") (PVar "o1") (PVar "o2"))) (EBlock (DoLet false false (PVar "remedy") (EIf (EBinOp "||" (EApp (EVar "isPreludeOrigin") (EVar "o1")) (EApp (EVar "isPreludeOrigin") (EVar "o2"))) (ELit (LString "build this value with the constructors of the type this position expects")) (ELit (LString "import the one you mean instead of declaring a second type with that name")))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "two different types share the name `")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "`: one comes from "))) (EApp (EMethodRef "display") (EApp (EVar "originPhrase") (EVar "o1")))) (ELit (LString ", the other from "))) (EApp (EMethodRef "display") (EApp (EVar "originPhrase") (EVar "o2")))) (ELit (LString "; "))) (EApp (EMethodRef "display") (EVar "remedy"))) (ELit (LString ""))))))
(DTypeSig false "originPhrase" (TyFun (TyCon "TyConOrigin") (TyCon "String")))
(DFunDef false "originPhrase" ((PCon "OriginModule" (PLit (LString "core")))) (ELit (LString "the prelude")))
(DFunDef false "originPhrase" ((PCon "OriginModule" (PLit (LString "__user__")))) (ELit (LString "this program")))
(DFunDef false "originPhrase" ((PCon "OriginModule" (PVar "m"))) (EBinOp "++" (EBinOp "++" (ELit (LString "module `")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "`"))))
(DFunDef false "originPhrase" ((PCon "OriginBuiltin")) (ELit (LString "the language itself")))
(DFunDef false "originPhrase" ((PCon "OriginUnresolved")) (ELit (LString "an unknown module")))
(DTypeSig true "doRequiresMonadMsg" (TyCon "String"))
(DFunDef false "doRequiresMonadMsg" () (ELit (LString "`do` needs a value whose type implements `Thenable`, such as `Option` or `Result`; for IO sequencing use a bare indented block instead of `do`")))
(DTypeSig true "deferRequiresMonadMsg" (TyCon "String"))
(DFunDef false "deferRequiresMonadMsg" () (ELit (LString "`defer` needs a value whose type implements `DeferredThenable`, such as `Async`; for `Option`, `Result` or `List` use `do` instead")))
(DTypeSig true "bindOutsideDoMsg" (TyCon "String"))
(DFunDef false "bindOutsideDoMsg" () (ELit (LString "`<-` is only valid inside a `do` block; outside one, bind the value with `let x = ...`")))
(DTypeSig true "qualifierBinderTypeMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "qualifierBinderTypeMsg" ((PVar "n") (PVar "ty")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "named argument `")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "` has type `"))) (EApp (EMethodRef "display") (EVar "ty"))) (ELit (LString "`, but a qualifier names it as an authority, and only a `String` argument has one; qualify by a `String` argument or drop `"))) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "` from the qualifier"))))
(DTypeSig true "binderNoDomainMsg" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "binderNoDomainMsg" ((PVar "n")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "the qualifier names `")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "`, but no binder domain, effect atom or index in this signature gives it a domain; write one on the binder, `("))) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString " : String @FileRead)`, or name the label it bounds, `<FileRead "))) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString ">`"))))
(DTypeSig true "joinDomainMsg" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "joinDomainMsg" ((PVar "ns")) (EBinOp "++" (EBinOp "++" (ELit (LString "the joined qualifier ")) (EApp (EMethodRef "display") (EApp (EApp (EVar "qualifierSource") (EVar "escStr")) (EApp (EApp (EMethodRef "map") (EVar "EPName")) (EVar "ns"))))) (ELit (LString " joins authorities from different domains; qualify by authorities of one label's domain"))))
(DTypeSig true "nameNotAuthorityMsg" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "nameNotAuthorityMsg" ((PVar "n")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "` is used as an authority, but nothing binds it as one; bind it as a named argument, `("))) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString " : String) ->`, or an `Authority`-kinded index"))))
(DTypeSig true "rowKindMismatchMsg" (TyFun (TyApp (TyCon "List") (TyCon "EffAtomTy")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))
(DFunDef false "rowKindMismatchMsg" ((PVar "labels") (PVar "tail")) (EBinOp "++" (EBinOp "++" (ELit (LString "the row <")) (EApp (EMethodRef "display") (EApp (EApp (EVar "ppEffInsideTy") (EVar "labels")) (EVar "tail")))) (ELit (LString "> is written at a type-argument position that is not row-kinded; write an ordinary type here"))))
(DTypeSig true "aliasArityMsg" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "aliasArityMsg" ((PVar "n") (PVar "expected") (PVar "got")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "type alias `")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "` takes "))) (EApp (EMethodRef "display") (EApp (EVar "argumentCount") (EVar "expected")))) (ELit (LString " but is applied to "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "got")))) (ELit (LString ""))))
(DTypeSig false "argumentCount" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "argumentCount" ((PLit (LInt 1))) (ELit (LString "1 argument")))
(DFunDef false "argumentCount" ((PVar "n")) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString " arguments"))))
(DTypeSig true "ordinaryInPatternSlotMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "ordinaryInPatternSlotMsg" ((PVar "n") (PVar "l")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "` ranges over every authority of `"))) (EApp (EMethodRef "display") (EVar "l"))) (ELit (LString "`, but it fills an `Authority "))) (EApp (EMethodRef "display") (EVar "l"))) (ELit (LString "*` slot, which takes only patterns; declare `"))) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "` pattern-ranging, `("))) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString " : String @"))) (EApp (EMethodRef "display") (EVar "l"))) (ELit (LString "*)` or `("))) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString " : Authority "))) (EApp (EMethodRef "display") (EVar "l"))) (ELit (LString "*)`"))))
(DTypeSig true "exactInPatternSlotMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "exactInPatternSlotMsg" ((PVar "l") (PVar "written") (PVar "closed")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EMethodRef "display") (EVar "written"))) (ELit (LString "` is an exact element of `"))) (EApp (EMethodRef "display") (EVar "l"))) (ELit (LString "`, but it fills an `Authority "))) (EApp (EMethodRef "display") (EVar "l"))) (ELit (LString "*` slot, which takes only patterns; write the pattern it begins, `"))) (EApp (EMethodRef "display") (EVar "closed"))) (ELit (LString "`, or `*`"))))
(DTypeSig true "authorityAsTypeMsg" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "authorityAsTypeMsg" ((PVar "n")) (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "` is an authority binder but is used here as a type; write a different name for the type variable"))))
(DTypeSig true "authorityTermAsTypeMsg" (TyFun (TyApp (TyCon "List") (TyCon "EffParamTy")) (TyCon "String")))
(DFunDef false "authorityTermAsTypeMsg" ((PVar "p")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "the authority term `")) (EApp (EMethodRef "display") (EApp (EApp (EVar "authTermsSurface") (EVar "escStr")) (EVar "p")))) (ELit (LString "` is written where a type goes; it belongs in an `Authority`-kinded type argument such as `Handle "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "authTermsSurface") (EVar "escStr")) (EVar "p")))) (ELit (LString "`"))))
(DTypeSig true "typeVarAsAuthorityMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "typeVarAsAuthorityMsg" ((PVar "n") (PVar "l")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "` is a type variable, but this slot is `Authority "))) (EApp (EMethodRef "display") (EVar "l"))) (ELit (LString "`; write an authority here: a binder's name, or a term such as `\"pattern/*\"` or `*`"))))
(DTypeSig true "typeAsAuthorityMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "typeAsAuthorityMsg" ((PVar "ty") (PVar "l")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EMethodRef "display") (EVar "ty"))) (ELit (LString "` is a type, but this slot is `Authority "))) (EApp (EMethodRef "display") (EVar "l"))) (ELit (LString "`; write an authority here: a binder's name, a literal of the label's domain, or `*`"))))
(DTypeSig true "typeInRowSlotMsg" (TyFun (TyCon "Ty") (TyCon "String")))
(DFunDef false "typeInRowSlotMsg" ((PVar "ty")) (EBinOp "++" (EBinOp "++" (ELit (LString "the type `")) (EApp (EMethodRef "display") (EApp (EVar "ppTy") (EVar "ty")))) (ELit (LString "` is written at a row-kinded type-argument position; write an effect row here, such as `<>`, `<Stdout>` or `<IO | e>`"))))
(DTypeSig true "existentialScopeMsg" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyCon "String")))
(DFunDef false "existentialScopeMsg" ((PVar "name")) (EBinOp "++" (EBinOp "++" (ELit (LString "this pattern opens the existential authority `")) (EApp (EMethodRef "display") (EApp (EApp (EVar "optionOr") (ELit (LString "?"))) (EVar "name")))) (ELit (LString "`, which only a `match` arm or a function clause can scope; match on the value, or take it as a clause parameter"))))
(DTypeSig true "discardedValueMsg" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "discardedValueMsg" ((PVar "desc")) (EBinOp "++" (EBinOp "++" (ELit (LString "this statement's value (")) (EApp (EMethodRef "display") (EVar "desc"))) (ELit (LString ") is discarded; only a `Unit` expression may stand alone as a statement"))))
(DTypeSig true "discardedValueFix" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyApp (TyCon "Option") (TyTuple (TyCon "Loc") (TyCon "String")))))
(DFunDef false "discardedValueFix" ((PCon "Some" (PCon "Loc" (PVar "f") (PVar "sl") (PVar "sc") PWild PWild))) (EApp (EVar "Some") (ETuple (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "f")) (EVar "sl")) (EVar "sc")) (EVar "sl")) (EVar "sc")) (ELit (LString "let _ = ")))))
(DFunDef false "discardedValueFix" ((PCon "None")) (EVar "None"))
(DTypeSig true "fieldNotInAllCtorsMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "fieldNotInAllCtorsMsg" ((PVar "fname") (PVar "tname") (PVar "sib")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "field `")) (EApp (EMethodRef "display") (EVar "fname"))) (ELit (LString "` is not declared by every constructor of `"))) (EApp (EMethodRef "display") (EVar "tname"))) (ELit (LString "`: `"))) (EApp (EMethodRef "display") (EVar "sib"))) (ELit (LString "` has no `"))) (EApp (EMethodRef "display") (EVar "fname"))) (ELit (LString "`; match on the constructor instead of using `."))) (EApp (EMethodRef "display") (EVar "fname"))) (ELit (LString "`"))))
(DTypeSig true "fieldPositionDiffersMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "String") (TyCon "Int")) (TyFun (TyTuple (TyCon "String") (TyCon "Int")) (TyCon "String"))))))
(DFunDef false "fieldPositionDiffersMsg" ((PVar "fname") (PVar "tname") (PTuple (PVar "a") (PVar "i")) (PTuple (PVar "b") (PVar "j"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "field `")) (EApp (EMethodRef "display") (EVar "fname"))) (ELit (LString "` is at different positions in the constructors of `"))) (EApp (EMethodRef "display") (EVar "tname"))) (ELit (LString "`: it is field "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EBinOp "+" (EVar "i") (ELit (LInt 1)))))) (ELit (LString " of `"))) (EApp (EMethodRef "display") (EVar "a"))) (ELit (LString "` but field "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EBinOp "+" (EVar "j") (ELit (LInt 1)))))) (ELit (LString " of `"))) (EApp (EMethodRef "display") (EVar "b"))) (ELit (LString "`; match on the constructor instead of using `."))) (EApp (EMethodRef "display") (EVar "fname"))) (ELit (LString "`"))))
(DTypeSig true "fieldTypeDiffersMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Mono") (TyFun (TyCon "String") (TyFun (TyCon "Mono") (TyCon "String"))))))))
(DFunDef false "fieldTypeDiffersMsg" ((PVar "fname") (PVar "tname") (PVar "a") (PVar "ta") (PVar "b") (PVar "tb")) (EBlock (DoLet false false (PVar "ctx") (EApp (EVar "Ref") (EListLit))) (DoLet false false (PVar "cnt") (EApp (EVar "Ref") (ELit (LInt 0)))) (DoLet false false (PVar "sa") (EApp (EApp (EApp (EApp (EVar "ppGo") (EVar "ctx")) (EVar "cnt")) (ELit (LInt 0))) (EVar "ta"))) (DoLet false false (PVar "sb") (EApp (EApp (EApp (EApp (EVar "ppGo") (EVar "ctx")) (EVar "cnt")) (ELit (LInt 0))) (EVar "tb"))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "field `")) (EApp (EMethodRef "display") (EVar "fname"))) (ELit (LString "` has different types in the constructors of `"))) (EApp (EMethodRef "display") (EVar "tname"))) (ELit (LString "`: it is `"))) (EApp (EMethodRef "display") (EVar "sa"))) (ELit (LString "` in `"))) (EApp (EMethodRef "display") (EVar "a"))) (ELit (LString "` but `"))) (EApp (EMethodRef "display") (EVar "sb"))) (ELit (LString "` in `"))) (EApp (EMethodRef "display") (EVar "b"))) (ELit (LString "`; match on the constructor instead of using `."))) (EApp (EMethodRef "display") (EVar "fname"))) (ELit (LString "`"))))))
(DTypeSig true "updateMultiCtorMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))))))
(DFunDef false "updateMultiCtorMsg" ((PVar "fn") (PVar "tname") (PVar "rname") (PVar "others") (PVar "ctors")) (EBlock (DoLet false false (PVar "pat") (EIf (EApp (EVar "isEmptyL") (EVar "others")) (ELit (LString "...")) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EVar "others")))) (DoLet false false (PVar "rebuilt") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EBinOp "::" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "fn"))) (ELit (LString " = ..."))) (EVar "others")))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "cannot update field `")) (EApp (EMethodRef "display") (EVar "fn"))) (ELit (LString "` on `"))) (EApp (EMethodRef "display") (EVar "tname"))) (ELit (LString "`, which has more than one constructor ("))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EMethodRef "map") (EVar "backticked")) (EVar "ctors"))))) (ELit (LString "); match on the constructor and rebuild the value in its arm, as in `"))) (EApp (EMethodRef "display") (EVar "rname"))) (ELit (LString " { "))) (EApp (EMethodRef "display") (EVar "pat"))) (ELit (LString " } => "))) (EApp (EMethodRef "display") (EVar "rname"))) (ELit (LString " { "))) (EApp (EMethodRef "display") (EVar "rebuilt"))) (ELit (LString " }`"))))))
(DTypeSig true "ambiguousFieldDeclsMsg" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "RecordInfo"))) (TyCon "String")))))
(DFunDef false "ambiguousFieldDeclsMsg" ((PVar "fname") (PVar "owners") (PVar "cands")) (EBlock (DoLet false false (PVar "keys") (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "cands"))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "listLen") (EApp (EVar "dedup") (EVar "keys"))) (EApp (EVar "listLen") (EVar "keys"))) (EApp (EApp (EVar "ambiguousFieldMsg") (EVar "fname")) (EVar "owners")) (EBlock (DoLet false false (PVar "tys") (EApp (EVar "sortUniqS") (EApp (EApp (EMethodRef "map") (EVar "fieldDeclTypeName")) (EVar "cands")))) (DoLet false false (PVar "descrs") (EApp (EVar "sortUniqS") (EApp (EApp (EMethodRef "map") (EVar "fieldDeclDescr")) (EVar "cands")))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "ambiguous field `.")) (EApp (EMethodRef "display") (EVar "fname"))) (ELit (LString "`: it is declared by "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString " and by "))) (EVar "descrs")))) (ELit (LString " and the record type is undetermined; annotate the record, as in `(r : "))) (EApp (EMethodRef "display") (EApp (EVar "headL") (EVar "tys")))) (ELit (LString ")."))) (EApp (EMethodRef "display") (EVar "fname"))) (ELit (LString "`")))))))))
(DTypeSig false "fieldDeclTypeName" (TyFun (TyTuple (TyCon "String") (TyCon "RecordInfo")) (TyCon "String")))
(DFunDef false "fieldDeclTypeName" ((PTuple (PVar "k") (PVar "ri"))) (EApp (EApp (EVar "optionOr") (EVar "k")) (EApp (EVar "headTyconNameMono") (EApp (EVar "recordResultMono") (EVar "ri")))))
(DTypeSig false "fieldDeclDescr" (TyFun (TyTuple (TyCon "String") (TyCon "RecordInfo")) (TyCon "String")))
(DFunDef false "fieldDeclDescr" ((PTuple (PVar "k") (PVar "ri"))) (EMatch (EApp (EVar "recordOwnerModule") (EVar "ri")) (arm (PCon "Some" (PVar "mid")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EMethodRef "display") (EApp (EVar "fieldDeclTypeName") (ETuple (EVar "k") (EVar "ri"))))) (ELit (LString "` from module `"))) (EApp (EMethodRef "display") (EVar "mid"))) (ELit (LString "`")))) (arm (PCon "None") () (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EMethodRef "display") (EApp (EVar "fieldDeclTypeName") (ETuple (EVar "k") (EVar "ri"))))) (ELit (LString "`"))))))
(DTypeSig false "headL" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "headL" ((PList)) (ELit (LString "")))
(DFunDef false "headL" ((PCons (PVar "x") PWild)) (EVar "x"))
(DTypeSig true "fieldFixFrom" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyTuple (TyCon "Loc") (TyCon "String")))))))
(DFunDef false "fieldFixFrom" ((PCon "Some" (PCon "Loc" (PVar "f") PWild PWild (PVar "el") (PVar "ec"))) (PVar "written") (PVar "sug")) (EApp (EVar "Some") (ETuple (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "f")) (EVar "el")) (EBinOp "+" (EVar "ec") (ELit (LInt 1)))) (EVar "el")) (EBinOp "+" (EBinOp "+" (EVar "ec") (ELit (LInt 1))) (EApp (EVar "stringLength") (EVar "written")))) (EVar "sug"))))
(DFunDef false "fieldFixFrom" ((PCon "None") PWild PWild) (EVar "None"))
(DTypeSig true "unknownFieldMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "unknownFieldMsg" ((PVar "fname") (PVar "rname")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "no field `")) (EApp (EMethodRef "display") (EVar "fname"))) (ELit (LString "` in `"))) (EApp (EMethodRef "display") (EVar "rname"))) (ELit (LString "`"))))
(DTypeSig true "abstractFieldMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "abstractFieldMsg" ((PVar "tname") (PVar "fname")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EMethodRef "display") (EVar "tname"))) (ELit (LString "` is exported abstractly, so its field `"))) (EApp (EMethodRef "display") (EVar "fname"))) (ELit (LString "` is not accessible; declare it `public export` to expose its fields"))))
(DTypeSig true "missingFieldMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "missingFieldMsg" ((PVar "fname") (PVar "rname")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "missing field `")) (EApp (EMethodRef "display") (EVar "fname"))) (ELit (LString "` in `"))) (EApp (EMethodRef "display") (EVar "rname"))) (ELit (LString "`"))))
(DTypeSig true "ambiguousFieldMsg" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))
(DFunDef false "ambiguousFieldMsg" ((PVar "fname") (PVar "owners")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "ambiguous field `.")) (EApp (EMethodRef "display") (EVar "fname"))) (ELit (LString "`: it is declared by "))) (EApp (EMethodRef "display") (EApp (EVar "joinAnd") (EApp (EApp (EMethodRef "map") (EVar "backticked")) (EVar "owners"))))) (ELit (LString " and the record type is undetermined; annotate the record, as in `(r : "))) (EApp (EMethodRef "display") (EApp (EVar "headL") (EVar "owners")))) (ELit (LString ")."))) (EApp (EMethodRef "display") (EVar "fname"))) (ELit (LString "`"))))
(DTypeSig true "unknownRecordMsg" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "unknownRecordMsg" ((PVar "name")) (EBinOp "++" (EBinOp "++" (ELit (LString "unknown record type `")) (EVar "name")) (ELit (LString "`"))))
(DTypeSig true "unknownCtorMsg" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "unknownCtorMsg" ((PVar "name")) (EBinOp "++" (EBinOp "++" (ELit (LString "unknown constructor `")) (EVar "name")) (ELit (LString "`"))))
(DTypeSig true "unboundVarMsg" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "unboundVarMsg" ((PVar "name")) (EBinOp "++" (EBinOp "++" (ELit (LString "unbound variable `")) (EVar "name")) (ELit (LString "`"))))
(DTypeSig true "u64RangeText" (TyCon "String"))
(DFunDef false "u64RangeText" () (ELit (LString "0..18446744073709551615")))
(DTypeSig true "i64RangeText" (TyCon "String"))
(DFunDef false "i64RangeText" () (ELit (LString "-9223372036854775808..9223372036854775807")))
(DTypeSig true "wideAnnotateHelp" (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyCon "String"))))
(DFunDef false "wideAnnotateHelp" ((PVar "shown") (PVar "negated")) (EBlock (DoLet false false (PVar "ty") (EIf (EVar "negated") (ELit (LString "I64")) (ELit (LString "U64")))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "only a `U64` or an `I64` holds a literal above 2^62; annotate it as `(")) (EApp (EMethodRef "display") (EVar "shown"))) (ELit (LString " : "))) (EApp (EMethodRef "display") (EVar "ty"))) (ELit (LString ")`"))))))
(DTypeSig true "bangOnBoolMsg" (TyCon "String"))
(DFunDef false "bangOnBoolMsg" () (ELit (LString "`!` dereferences a `Ref` and does not negate a `Bool`; use `not x`")))
(DTypeSig true "bangOnBoolHelp" (TyCon "String"))
(DFunDef false "bangOnBoolHelp" () (ELit (LString "use `not x`; `!x` reads a `Ref` cell, so it needs a `Ref a`, not a `Bool`")))
(DTypeSig true "contraRowMsg" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "String")))))
(DFunDef false "contraRowMsg" ((PVar "le") (PVar "la") (PVar "extras")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "a function whose parameter admits only <")) (EApp (EMethodRef "display") (EApp (EVar "renderAtoms") (EVar "la")))) (ELit (LString "> is used where one admitting <"))) (EApp (EMethodRef "display") (EApp (EVar "renderAtoms") (EVar "le")))) (ELit (LString "> is expected, so a caller could pass an argument performing <"))) (EApp (EMethodRef "display") (EApp (EVar "renderAtoms") (EVar "extras")))) (ELit (LString ">; declare that parameter with <"))) (EApp (EMethodRef "display") (EApp (EVar "renderAtoms") (EVar "le")))) (ELit (LString ">"))))
(DTypeSig true "notAFunctionMsg" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "notAFunctionMsg" ((PVar "tyName")) (EApp (EApp (EVar "notAFunctionMsgFor") (EVar "None")) (EVar "tyName")))
(DTypeSig true "notAFunctionMsgFor" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "notAFunctionMsgFor" ((PCon "Some" (PVar "name")) (PVar "tyName")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "` has type "))) (EApp (EMethodRef "display") (EVar "tyName"))) (ELit (LString " and is not a function; it cannot be applied to an argument"))))
(DFunDef false "notAFunctionMsgFor" ((PCon "None") (PVar "tyName")) (EBinOp "++" (EBinOp "++" (ELit (LString "this expression has type ")) (EApp (EMethodRef "display") (EVar "tyName"))) (ELit (LString " and is not a function; it cannot be applied to an argument"))))
(DTypeSig true "notAFunctionHint" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyCon "String")))
(DFunDef false "notAFunctionHint" ((PCon "Some" (PVar "name"))) (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "` is a value, not a function; remove the argument"))))
(DFunDef false "notAFunctionHint" ((PCon "None")) (ELit (LString "this is a value, not a function; remove the argument")))
(DTypeSig true "overAppliedMsg" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "overAppliedMsg" ((PVar "name") (PVar "takes") (PVar "applied")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "` takes "))) (EApp (EMethodRef "display") (EApp (EVar "argumentCount") (EVar "takes")))) (ELit (LString " but is applied to "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "applied")))) (ELit (LString ""))))
(DTypeSig true "containerArgMsg" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "containerArgMsg" ((PVar "fn") (PVar "argTy")) (EBlock (DoLet false false (PVar "who") (EMatch (EVar "fn") (arm (PCon "Some" (PVar "n")) () (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "`")))) (arm (PCon "None") () (ELit (LString "this function"))))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "who"))) (ELit (LString " expects a container such as `List` here but got `"))) (EApp (EMethodRef "display") (EVar "argTy"))) (ELit (LString "`; "))) (EApp (EMethodRef "display") (EApp (EVar "containerArgHint") (EVar "argTy")))) (ELit (LString ""))))))
(DTypeSig true "containerArgHint" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "containerArgHint" ((PLit (LString "String"))) (ELit (LString "to work over the string's characters, convert it with `string.toChars` first")))
(DFunDef false "containerArgHint" ((PVar "argTy")) (EBinOp "++" (EBinOp "++" (ELit (LString "convert the `")) (EApp (EMethodRef "display") (EVar "argTy"))) (ELit (LString "` to a `List` first"))))
(DTypeSig true "doBindArgMsg" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "doBindArgMsg" ((PVar "argTy")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "this `do` block needs a `Thenable` value here, such as `Option` or `Result`, but got `")) (EApp (EMethodRef "display") (EVar "argTy"))) (ELit (LString "`; "))) (EApp (EMethodRef "display") (EApp (EVar "doBindArgHint") (EVar "argTy")))) (ELit (LString ""))))
(DTypeSig true "doBindArgHint" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "doBindArgHint" ((PVar "argTy")) (EBinOp "++" (EBinOp "++" (ELit (LString "bind a plain `")) (EApp (EMethodRef "display") (EVar "argTy"))) (ELit (LString "` with `let` instead of `<-`"))))
(DTypeSig false "renderCallArg" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "renderCallArg" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "renderCallArg") (EVar "e")))
(DFunDef false "renderCallArg" ((PCon "EAnnot" (PVar "e") PWild)) (EApp (EVar "renderCallArg") (EVar "e")))
(DFunDef false "renderCallArg" ((PCon "ENumLit" (PVar "n") PWild PWild)) (EApp (EVar "Some") (EApp (EVar "intToString") (EVar "n"))))
(DFunDef false "renderCallArg" ((PCon "EWideLit" PWild PWild PWild (PVar "lx"))) (EApp (EVar "Some") (EVar "lx")))
(DFunDef false "renderCallArg" ((PCon "ELit" (PCon "LInt" (PVar "n")))) (EApp (EVar "Some") (EApp (EVar "intToString") (EVar "n"))))
(DFunDef false "renderCallArg" ((PCon "ELit" (PCon "LBool" (PCon "True")))) (EApp (EVar "Some") (ELit (LString "True"))))
(DFunDef false "renderCallArg" ((PCon "ELit" (PCon "LBool" (PCon "False")))) (EApp (EVar "Some") (ELit (LString "False"))))
(DFunDef false "renderCallArg" ((PCon "ELit" (PCon "LString" (PVar "s")))) (EApp (EVar "Some") (EBinOp "++" (EBinOp "++" (ELit (LString "\"")) (EVar "s")) (ELit (LString "\"")))))
(DFunDef false "renderCallArg" ((PCon "ELit" (PCon "LChar" (PVar "c")))) (EApp (EVar "Some") (EBinOp "++" (EBinOp "++" (ELit (LString "'")) (EVar "c")) (ELit (LString "'")))))
(DFunDef false "renderCallArg" ((PCon "EVar" (PVar "n"))) (EApp (EVar "Some") (EVar "n")))
(DFunDef false "renderCallArg" ((PCon "EVarId" (PVar "n") PWild)) (EApp (EVar "Some") (EVar "n")))
(DFunDef false "renderCallArg" ((PCon "EMethodAt" (PVar "n") PWild PWild)) (EApp (EVar "Some") (EVar "n")))
(DFunDef false "renderCallArg" ((PCon "EDictAt" (PVar "n") PWild)) (EApp (EVar "Some") (EVar "n")))
(DFunDef false "renderCallArg" ((PCon "EUnOp" (PLit (LString "-")) (PVar "e") PWild)) (EApp (EApp (EMethodRef "map") (ELam ((PVar "_s")) (EBinOp "++" (ELit (LString "-")) (EVar "_s")))) (EApp (EVar "renderCallArg") (EVar "e"))))
(DFunDef false "renderCallArg" (PWild) (EVar "None"))
(DTypeSig true "renderCallArgs" (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "renderCallArgs" ((PList)) (EApp (EVar "Some") (EListLit)))
(DFunDef false "renderCallArgs" ((PCons (PVar "e") (PVar "rest"))) (EMatch (EApp (EVar "renderCallArg") (EVar "e")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "s")) () (EApp (EApp (EMethodRef "map") (ELam ((PVar "_s")) (EBinOp "::" (EVar "s") (EVar "_s")))) (EApp (EVar "renderCallArgs") (EVar "rest"))))))
(DTypeSig true "nonExhaustiveMatchWarning" (TyCon "String"))
(DFunDef false "nonExhaustiveMatchWarning" () (ELit (LString "Warning: non-exhaustive match; not every case is covered")))
(DTypeSig true "unreachableArmWarning" (TyCon "String"))
(DFunDef false "unreachableArmWarning" () (ELit (LString "Warning: unreachable match arm; an earlier arm already covers this pattern")))
(DTypeSig true "tyOfMsg" (TyFun (TyApp (TyCon "Option") (TyCon "TabKey")) (TyCon "String")))
(DFunDef false "tyOfMsg" ((PCon "None")) (ELit (LString "")))
(DFunDef false "tyOfMsg" ((PCon "Some" (PVar "k"))) (EBlock (DoLet false false (PVar "t") (EApp (EVar "tabKeyName") (EVar "k"))) (DoExpr (EIf (EApp (EVar "isTupleTyName") (EVar "t")) (ELit (LString "")) (EBinOp "++" (EBinOp "++" (ELit (LString " on `")) (EApp (EMethodRef "display") (EVar "t"))) (ELit (LString "`")))))))
(DTypeSig false "isTupleTyName" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isTupleTyName" ((PVar "t")) (EBinOp "&&" (EBinOp ">=" (EApp (EVar "stringLength") (EVar "t")) (ELit (LInt 7))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 7))) (EVar "t")) (ELit (LString "__tuple")))))
(DTypeSig true "existentialEscapeMsg" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyCon "String")))
(DFunDef false "existentialEscapeMsg" ((PVar "name")) (EBinOp "++" (EBinOp "++" (ELit (LString "the existential authority `")) (EApp (EMethodRef "display") (EApp (EApp (EVar "optionOr") (ELit (LString "?"))) (EVar "name")))) (ELit (LString "` escapes the arm or clause that opened it; consume the value inside it, or return it repacked in its existential constructor"))))
(DTypeSig true "partialExistentialUpdateMsg" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))
(DFunDef false "partialExistentialUpdateMsg" ((PVar "rname") (PVar "names")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "updating `")) (EApp (EMethodRef "display") (EVar "rname"))) (ELit (LString "` replaces a field under an existential authority binder, but the binder's fields "))) (EApp (EMethodRef "display") (EApp (EVar "quotedNames") (EVar "names")))) (ELit (LString " must change together; replace them all, or rebuild the record"))))
(DTypeSig true "letRecNonFunctionMsg" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "letRecNonFunctionMsg" ((PVar "name")) (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EVar "name")) (ELit (LString "` is bound by `let rec` but its right-hand side is not a function"))))
(DTypeSig true "ambiguousShadowHelp" (TyCon "String"))
(DFunDef false "ambiguousShadowHelp" () (ELit (LString "bring only one of those interfaces into scope by importing the other module without naming its interface, or rename one of the methods")))
(DTypeSig true "shadowIfaceLabel" (TyFun (TyCon "IfaceRef") (TyCon "String")))
(DFunDef false "shadowIfaceLabel" ((PVar "ir")) (EMatch (EFieldAccess (EVar "ir") "irOrigin") (arm (PCon "OriginModule" (PVar "m")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EMethodRef "display") (EFieldAccess (EVar "ir") "irName"))) (ELit (LString "` (from `"))) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "`)")))) (arm PWild () (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EMethodRef "display") (EFieldAccess (EVar "ir") "irName"))) (ELit (LString "`"))))))
(DTypeSig true "implHeadIndexMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "implHeadIndexMsg" ((PVar "head") (PVar "written")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "impl head `")) (EApp (EMethodRef "display") (EVar "head"))) (ELit (LString " "))) (EApp (EMethodRef "display") (EVar "written"))) (ELit (LString "` writes an `Authority` index, but an instance is chosen by the type's head and covers every index; write a name in the slot instead of `"))) (EApp (EMethodRef "display") (EVar "written"))) (ELit (LString "`"))))
(DTypeSig true "cohOverlapMsg" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "String")))))
(DFunDef false "cohOverlapMsg" ((PVar "iface") (PVar "xs") (PVar "ys")) (EMatch (EApp (EApp (EVar "cohPpPair") (EVar "xs")) (EVar "ys")) (arm (PTuple (PVar "s1") (PVar "s2")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "overlapping impls of ")) (EApp (EMethodRef "display") (EVar "iface"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "s1"))) (ELit (LString " and "))) (EApp (EMethodRef "display") (EVar "s2"))) (ELit (LString " can match the same type; make them disjoint or wrap one type in a newtype"))))))
(DTypeSig true "cohPreludeOverlapMsg" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "String")))))
(DFunDef false "cohPreludeOverlapMsg" ((PVar "iface") (PVar "xs") (PVar "ys")) (EMatch (EApp (EApp (EVar "cohPpPair") (EVar "xs")) (EVar "ys")) (arm (PTuple (PVar "s1") (PVar "s2")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "overlapping impls of ")) (EApp (EMethodRef "display") (EVar "iface"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "s1"))) (ELit (LString " and the prelude's "))) (EApp (EMethodRef "display") (EVar "s2"))) (ELit (LString " can match the same type; the prelude's impl cannot be replaced, so wrap the type in a newtype and implement "))) (EApp (EMethodRef "display") (EVar "iface"))) (ELit (LString " for that"))))))
(DTypeSig true "cohIncomparableHelp" (TyCon "String"))
(DFunDef false "cohIncomparableHelp" () (ELit (LString "add an impl at the two heads' common instance so it is more specific than both, or make the two heads disjoint")))
(DTypeSig true "cohCrossModuleMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "cohCrossModuleMsg" ((PVar "iface") (PVar "mid1") (PVar "mid2")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "conflicting `impl ")) (EApp (EMethodRef "display") (EVar "iface"))) (ELit (LString "`: defined in both `"))) (EApp (EMethodRef "display") (EVar "mid2"))) (ELit (LString "` and `"))) (EApp (EMethodRef "display") (EVar "mid1"))) (ELit (LString "`"))))
(DTypeSig true "superContextUndeclaredMsg" (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String")))))))
(DFunDef false "superContextUndeclaredMsg" ((PVar "subject") (PVar "derived") (PVar "superGoal") (PVar "pred") (PVar "predBare")) (EIf (EVar "derived") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EMethodRef "display") (EVar "subject"))) (ELit (LString "` (derived) must provide its superinterface `"))) (EApp (EMethodRef "display") (EVar "superGoal"))) (ELit (LString "`, whose instance requires `"))) (EApp (EMethodRef "display") (EVar "pred"))) (ELit (LString "`, which the derived impl does not declare; a `deriving` clause takes no `requires`, so write the impl by hand with `requires "))) (EApp (EMethodRef "display") (EVar "predBare"))) (ELit (LString "`"))) (EIf (EVar "otherwise") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EMethodRef "display") (EVar "subject"))) (ELit (LString "` must provide its superinterface `"))) (EApp (EMethodRef "display") (EVar "superGoal"))) (ELit (LString "`, whose instance requires `"))) (EApp (EMethodRef "display") (EVar "pred"))) (ELit (LString "`, which the impl does not declare; add `requires "))) (EApp (EMethodRef "display") (EVar "predBare"))) (ELit (LString "` to the impl"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "superContextNoImplMsg" (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String")))))))
(DFunDef false "superContextNoImplMsg" ((PVar "subject") (PVar "derived") (PVar "superGoal") (PVar "pred") (PVar "predBare")) (EIf (EVar "derived") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EMethodRef "display") (EVar "subject"))) (ELit (LString "` (derived) must provide its superinterface `"))) (EApp (EMethodRef "display") (EVar "superGoal"))) (ELit (LString "`, whose instance requires `"))) (EApp (EMethodRef "display") (EVar "pred"))) (ELit (LString "`, and no impl provides it; add `impl "))) (EApp (EMethodRef "display") (EVar "predBare"))) (ELit (LString "`, and write the derived impl by hand if its `requires` must change"))) (EIf (EVar "otherwise") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EMethodRef "display") (EVar "subject"))) (ELit (LString "` must provide its superinterface `"))) (EApp (EMethodRef "display") (EVar "superGoal"))) (ELit (LString "`, whose instance requires `"))) (EApp (EMethodRef "display") (EVar "pred"))) (ELit (LString "`, and no impl provides it; add `impl "))) (EApp (EMethodRef "display") (EVar "predBare"))) (ELit (LString "`"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "missingImplMethodMsg" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "missingImplMethodMsg" ((PVar "iface") (PVar "tys") (PVar "method")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`impl ")) (EApp (EMethodRef "display") (EVar "iface"))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EMethodRef "map") (EVar "ppTyAtom")) (EVar "tys"))))) (ELit (LString "` is missing the method `"))) (EApp (EMethodRef "display") (EVar "method"))) (ELit (LString "`; define `"))) (EApp (EMethodRef "display") (EVar "method"))) (ELit (LString "` in the impl"))))
(DTypeSig true "ordinalSentinelMsg" (TyCon "String"))
(DFunDef false "ordinalSentinelMsg" () (ELit (LString "internal error: the whole-program final checks (coherence, interface cycles, phantom methods, superinterface existence) were reached with an unknown module ordinal, so they cannot say what is in scope here. This is a compiler bug, not a problem with this program — please report it. The checks below this point may be incomplete")))
(DTypeSig true "cyclicSuperIfaceMsg" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "cyclicSuperIfaceMsg" ((PVar "path")) (EBinOp "++" (ELit (LString "cyclic superinterface: ")) (EApp (EApp (EVar "joinWith") (ELit (LString " requires "))) (EApp (EApp (EMethodRef "map") (EVar "backticked")) (EVar "path")))))
(DTypeSig true "ambiguousOverlapMsg" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyApp (TyCon "List") (TyCon "KeyEntry")) (TyCon "String")))))
(DFunDef false "ambiguousOverlapMsg" ((PVar "iface") (PVar "goals") (PVar "cands")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "ambiguous instance for `")) (EApp (EMethodRef "display") (EVar "iface"))) (ELit (LString "`: the goal `"))) (EApp (EMethodRef "display") (EVar "iface"))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EVar "ppPredArgsShared") (EVar "goals")))) (ELit (LString "` matches "))) (EApp (EMethodRef "display") (EApp (EVar "joinAnd") (EApp (EApp (EMethodRef "map") (EApp (EVar "implHeadLabel") (EVar "iface"))) (EVar "cands"))))) (ELit (LString ", and "))) (EApp (EMethodRef "display") (EApp (EVar "noMinimumClause") (EApp (EVar "listLen") (EVar "cands"))))) (ELit (LString "; make them disjoint, or annotate this expression with a type only one of them matches"))))
(DTypeSig false "noMinimumClause" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "noMinimumClause" ((PVar "n")) (EIf (EBinOp "==" (EVar "n") (ELit (LInt 2))) (ELit (LString "neither is more specific than the other")) (EIf (EVar "otherwise") (ELit (LString "none of them is more specific than all the others")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "joinAnd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "joinAnd" ((PList)) (ELit (LString "")))
(DFunDef false "joinAnd" ((PList (PVar "x"))) (EVar "x"))
(DFunDef false "joinAnd" ((PList (PVar "x") (PVar "y"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "x"))) (ELit (LString " and "))) (EApp (EMethodRef "display") (EVar "y"))) (ELit (LString ""))))
(DFunDef false "joinAnd" ((PCons (PVar "x") (PVar "rest"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "x"))) (ELit (LString ", "))) (EApp (EMethodRef "display") (EApp (EVar "joinAnd") (EVar "rest")))) (ELit (LString ""))))
(DTypeSig false "implHeadLabel" (TyFun (TyCon "String") (TyFun (TyCon "KeyEntry") (TyCon "String"))))
(DFunDef false "implHeadLabel" ((PVar "iface") (PCon "KeyEntry" PWild PWild PWild PWild PWild (PVar "itys") PWild PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`impl ")) (EApp (EMethodRef "display") (EVar "iface"))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EMethodRef "map") (EVar "ppTyAtom")) (EVar "itys"))))) (ELit (LString "`"))))
(DTypeSig true "ambiguousImplMsg" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "ambiguousImplMsg" ((PVar "iface")) (EBinOp "++" (EBinOp "++" (ELit (LString "ambiguous instance for `")) (EVar "iface")) (ELit (LString "`: the type here does not determine which impl applies; add a type annotation"))))
(DTypeSig true "qualifiedIfaceLabel" (TyFun (TyCon "IfaceRef") (TyCon "String")))
(DFunDef false "qualifiedIfaceLabel" ((PVar "ir")) (EMatch (EFieldAccess (EVar "ir") "irOrigin") (arm (PCon "OriginModule" (PLit (LString "__user__"))) () (EFieldAccess (EVar "ir") "irName")) (arm (PCon "OriginModule" (PVar "m")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "."))) (EApp (EMethodRef "display") (EFieldAccess (EVar "ir") "irName"))) (ELit (LString "")))) (arm PWild () (EFieldAccess (EVar "ir") "irName"))))
(DTypeSig true "sigVarGoalMsg" (TyFun (TyCon "DeclaringBinder") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))))) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "String")))))))
(DFunDef false "sigVarGoalMsg" ((PVar "binder") (PVar "sigTvMaps") (PVar "sigVarIds") (PVar "iface") (PVar "args")) (EBlock (DoLet false false (PVar "owners") (EApp (EApp (EDictApp "flatMap") (EApp (EVar "sigVarOwner") (EVar "sigTvMaps"))) (EApp (EVar "dedupI") (EVar "sigVarIds")))) (DoLet false false (PVar "named") (EApp (EApp (EMethodRef "map") (EVar "snd")) (EVar "owners"))) (DoLet false false (PVar "pred") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EFieldAccess (EVar "iface") "irName"))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EApp (EApp (EVar "ppEach") (EApp (EVar "Ref") (EVar "named"))) (EApp (EVar "Ref") (ELit (LInt 0)))) (ELit (LInt 3))) (EVar "args"))))) (ELit (LString "")))) (DoLet false false (PVar "vars") (EApp (EApp (EVar "joinWith") (ELit (LString " and "))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "owner")) (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EMethodRef "display") (EApp (EVar "snd") (EApp (EVar "snd") (EVar "owner"))))) (ELit (LString "`"))))) (EVar "owners")))) (DoExpr (EMatch (EVar "binder") (arm (PCon "DeclaredBySignature") () (EBlock (DoLet false false (PVar "member") (EMatch (EVar "owners") (arm (PCons (PTuple (PVar "m") PWild) PWild) () (EVar "m")) (arm (PList) () (ELit (LString ""))))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "the body of `")) (EApp (EMethodRef "display") (EVar "member"))) (ELit (LString "` requires `"))) (EApp (EMethodRef "display") (EVar "pred"))) (ELit (LString "`, which its signature does not declare and which only a specific "))) (EApp (EMethodRef "display") (EVar "vars"))) (ELit (LString " satisfies; write that type in the signature or add `"))) (EApp (EMethodRef "display") (EVar "pred"))) (ELit (LString " =>`")))))) (arm (PCon "DeclaredByAnnotation") () (EBlock (DoLet false false (PVar "written") (EMatch (EVar "sigTvMaps") (arm (PCons (PTuple PWild (PVar "ty") PWild) PWild) () (EApp (EVar "ppTy") (EVar "ty"))) (arm (PList) () (ELit (LString ""))))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "this expression requires `")) (EApp (EMethodRef "display") (EVar "pred"))) (ELit (LString "`, which its annotation `"))) (EApp (EMethodRef "display") (EVar "written"))) (ELit (LString "` does not declare and which only a specific "))) (EApp (EMethodRef "display") (EVar "vars"))) (ELit (LString " satisfies; write that type in the annotation or add `"))) (EApp (EMethodRef "display") (EVar "pred"))) (ELit (LString " =>`"))))))))))
(DTypeSig false "sigVarOwner" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))))) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyCon "Int") (TyCon "String")))))))
(DFunDef false "sigVarOwner" ((PList) PWild) (EListLit))
(DFunDef false "sigVarOwner" ((PCons (PTuple (PVar "m") PWild (PVar "tvs")) (PVar "rest")) (PVar "id")) (EMatch (EApp (EApp (EVar "findTvName") (EVar "id")) (EVar "tvs")) (arm (PCon "Some" (PVar "n")) () (EListLit (ETuple (EVar "m") (ETuple (EVar "id") (EVar "n"))))) (arm (PCon "None") () (EApp (EApp (EVar "sigVarOwner") (EVar "rest")) (EVar "id")))))
(DTypeSig true "methodBodySubject" (TyFun (TyCon "MethodBodyKind") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "methodBodySubject" ((PCon "ImplBody" PWild) (PVar "iface") (PVar "mname")) (EApp (EApp (EVar "implSubject") (EVar "iface")) (EVar "mname")))
(DFunDef false "methodBodySubject" ((PCon "DefaultBody") (PVar "iface") (PVar "mname")) (EApp (EApp (EVar "defaultSubject") (EVar "iface")) (EVar "mname")))
(DTypeSig true "methodBodyLaunderMsg" (TyFun (TyCon "MethodBodyKind") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "String"))))))
(DFunDef false "methodBodyLaunderMsg" ((PCon "ImplBody" PWild) (PVar "iface") (PVar "mname") (PVar "escaping")) (EApp (EApp (EApp (EVar "effectLaunderMsg") (EVar "iface")) (EVar "mname")) (EVar "escaping")))
(DFunDef false "methodBodyLaunderMsg" ((PCon "DefaultBody") (PVar "iface") (PVar "mname") (PVar "escaping")) (EApp (EApp (EVar "defaultEffectLaunderMsg") (EApp (EApp (EVar "defaultSubject") (EVar "iface")) (EVar "mname"))) (EVar "escaping")))
(DTypeSig false "effectLaunderMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "String")))))
(DFunDef false "effectLaunderMsg" ((PVar "iface") (PVar "mname") (PVar "escaping")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "effect laundering in impl of `")) (EApp (EMethodRef "display") (EVar "mname"))) (ELit (LString "` for `"))) (EApp (EMethodRef "display") (EVar "iface"))) (ELit (LString "`: the body performs <"))) (EApp (EMethodRef "display") (EApp (EVar "renderAtoms") (EVar "escaping")))) (ELit (LString ">, which no argument sources and the method's row does not declare; declare <"))) (EApp (EMethodRef "display") (EApp (EVar "renderAtoms") (EVar "escaping")))) (ELit (LString "> in the method's row, or perform it through an argument"))))
(DTypeSig true "aliasesHeadRowMsg" (TyFun (TyCon "String") (TyFun (TyCon "Ty") (TyCon "String"))))
(DFunDef false "aliasesHeadRowMsg" ((PVar "subject") (PVar "mty")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "subject"))) (ELit (LString " identifies a method effect variable with the instance head's own effect-row parameter, which the declared type `"))) (EApp (EMethodRef "display") (EApp (EVar "ppTy") (EVar "mty")))) (ELit (LString "` keeps distinct; keep the method's effect variable independent of the head's"))))
(DTypeSig false "implSubject" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "implSubject" ((PVar "iface") (PVar "mname")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "impl of `")) (EApp (EMethodRef "display") (EVar "mname"))) (ELit (LString "` for `"))) (EApp (EMethodRef "display") (EVar "iface"))) (ELit (LString "`"))))
(DTypeSig false "defaultSubject" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "defaultSubject" ((PVar "iface") (PVar "mname")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "default body of `")) (EApp (EMethodRef "display") (EVar "mname"))) (ELit (LString "` in `"))) (EApp (EMethodRef "display") (EVar "iface"))) (ELit (LString "`"))))
(DTypeSig true "narrowsImplHeadMsg" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "narrowsImplHeadMsg" ((PVar "subject") (PVar "narrowed") (PVar "head")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "subject"))) (ELit (LString " fixes the instance-head type "))) (EApp (EMethodRef "display") (EApp (EVar "tyVarNoun") (EVar "narrowed")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EVar "quotedNames") (EVar "narrowed")))) (ELit (LString ", but the impl is declared for every type in their place; narrow the head to `"))) (EApp (EMethodRef "display") (EVar "head"))) (ELit (LString "`, or make the body parametric in "))) (EApp (EMethodRef "display") (EApp (EVar "quotedNames") (EVar "narrowed")))) (ELit (LString ""))))
(DTypeSig true "indexEagerMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "indexEagerMsg" ((PVar "subject") (PVar "evar")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "subject"))) (ELit (LString " performs the effect variable <"))) (EApp (EMethodRef "display") (EVar "evar"))) (ELit (LString "> at call time, but the signature charges <"))) (EApp (EMethodRef "display") (EVar "evar"))) (ELit (LString "> only in a result index, `f "))) (EApp (EMethodRef "display") (EVar "evar"))) (ELit (LString " ...`; defer it under the container's own <"))) (EApp (EMethodRef "display") (EVar "evar"))) (ELit (LString "> thunk, or charge the method's arrow, `-> <"))) (EApp (EMethodRef "display") (EVar "evar"))) (ELit (LString "> ...`"))))
(DTypeSig false "tyVarNoun" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "tyVarNoun" ((PList PWild)) (ELit (LString "variable")))
(DFunDef false "tyVarNoun" (PWild) (ELit (LString "variables")))
(DTypeSig true "pinsTyvarMsg" (TyFun (TyCon "String") (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))))
(DFunDef false "pinsTyvarMsg" ((PVar "subject") (PVar "mty") (PVar "pinned")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "subject"))) (ELit (LString " pins the method's quantified type "))) (EApp (EMethodRef "display") (EApp (EVar "tyVarNoun") (EVar "pinned")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EVar "quotedNames") (EVar "pinned")))) (ELit (LString ", which the declared type `"))) (EApp (EMethodRef "display") (EApp (EVar "ppTy") (EVar "mty")))) (ELit (LString "` leaves to the caller; make the body parametric in "))) (EApp (EMethodRef "display") (EApp (EVar "quotedNames") (EVar "pinned")))) (ELit (LString ""))))
(DTypeSig true "undeclaredConstraintMsg" (TyFun (TyCon "String") (TyFun (TyCon "Ty") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))))
(DFunDef false "undeclaredConstraintMsg" ((PVar "subject") (PVar "mty") (PVar "oiface") (PVar "vname")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "subject"))) (ELit (LString " requires `"))) (EApp (EMethodRef "display") (EVar "oiface"))) (ELit (LString "` on the method's quantified type variable `"))) (EApp (EMethodRef "display") (EVar "vname"))) (ELit (LString "`, which the declared type `"))) (EApp (EMethodRef "display") (EApp (EVar "ppTy") (EVar "mty")))) (ELit (LString "` does not; add `"))) (EApp (EMethodRef "display") (EVar "oiface"))) (ELit (LString " "))) (EApp (EMethodRef "display") (EVar "vname"))) (ELit (LString " =>` to the method's signature"))))
(DTypeSig true "undeclaredImplPrerequisiteMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "undeclaredImplPrerequisiteMsg" ((PVar "subject") (PVar "oiface") (PVar "vname")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "subject"))) (ELit (LString " requires `"))) (EApp (EMethodRef "display") (EVar "oiface"))) (ELit (LString "` on the instance-head type variable `"))) (EApp (EMethodRef "display") (EVar "vname"))) (ELit (LString "`, which the impl does not declare; add `requires "))) (EApp (EMethodRef "display") (EVar "oiface"))) (ELit (LString " "))) (EApp (EMethodRef "display") (EVar "vname"))) (ELit (LString "` to the impl"))))
(DTypeSig true "implGoalFixesHeadMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))))
(DFunDef false "implGoalFixesHeadMsg" ((PVar "subject") (PVar "pred") (PVar "fixed")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "subject"))) (ELit (LString " requires `"))) (EApp (EMethodRef "display") (EVar "pred"))) (ELit (LString "`, which only a specific instance-head type "))) (EApp (EMethodRef "display") (EApp (EVar "tyVarNoun") (EVar "fixed")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EVar "quotedNames") (EVar "fixed")))) (ELit (LString " satisfies, but the impl is declared for every type in their place; make the body parametric in "))) (EApp (EMethodRef "display") (EApp (EVar "quotedNames") (EVar "fixed")))) (ELit (LString ", or narrow the head"))))
(DTypeSig true "undeclaredImplPredicateMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "undeclaredImplPredicateMsg" ((PVar "subject") (PVar "pred")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "subject"))) (ELit (LString " requires `"))) (EApp (EMethodRef "display") (EVar "pred"))) (ELit (LString "` on the instance head's type variables, which the impl does not declare; add `requires "))) (EApp (EMethodRef "display") (EVar "pred"))) (ELit (LString "` to the impl"))))
(DTypeSig true "collapsesTyvarsMsg" (TyFun (TyCon "String") (TyFun (TyCon "Ty") (TyCon "String"))))
(DFunDef false "collapsesTyvarsMsg" ((PVar "subject") (PVar "mty")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "subject"))) (ELit (LString " identifies quantified type variables that the declared type `"))) (EApp (EMethodRef "display") (EApp (EVar "ppTy") (EVar "mty")))) (ELit (LString "` keeps distinct; keep them independent in the body"))))
(DTypeSig false "defaultEffectLaunderMsg" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "String"))))
(DFunDef false "defaultEffectLaunderMsg" ((PVar "subject") (PVar "escaping")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "subject"))) (ELit (LString " launders an effect: the body performs <"))) (EApp (EMethodRef "display") (EApp (EVar "renderAtoms") (EVar "escaping")))) (ELit (LString ">, which no argument sources and the method's row does not declare; declare <"))) (EApp (EMethodRef "display") (EApp (EVar "renderAtoms") (EVar "escaping")))) (ELit (LString "> in the method's row, or perform it through an argument"))))
(DTypeSig true "collapsesEffvarsMsg" (TyFun (TyCon "String") (TyFun (TyCon "Ty") (TyCon "String"))))
(DFunDef false "collapsesEffvarsMsg" ((PVar "subject") (PVar "mty")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "subject"))) (ELit (LString " identifies effect variables that the declared type `"))) (EApp (EMethodRef "display") (EApp (EVar "ppTy") (EVar "mty")))) (ELit (LString "` keeps distinct; keep the body's effects on the variable the signature declares at each position"))))
(DTypeSig true "effVarLaunderMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "String")))))
(DFunDef false "effVarLaunderMsg" ((PVar "subject") (PVar "evar") (PVar "escaping")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "subject"))) (ELit (LString " launders an effect: the body performs <"))) (EApp (EMethodRef "display") (EApp (EVar "renderAtoms") (EVar "escaping")))) (ELit (LString "> inside the effect variable <"))) (EApp (EMethodRef "display") (EVar "evar"))) (ELit (LString "> at a position whose declared row does not include it; declare <"))) (EApp (EMethodRef "display") (EApp (EVar "renderAtoms") (EVar "escaping")))) (ELit (LString "> at that position, or perform it through an argument"))))
(DTypeSig true "ffiArrowNote" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "ffiArrowNote" ((PVar "i") (PVar "arrows")) (EIf (EBinOp ">" (EVar "arrows") (ELit (LInt 1))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString " on the result of argument ")) (EApp (EMethodRef "display") (EApp (EMethodRef "display") (EVar "i")))) (ELit (LString " of "))) (EApp (EMethodRef "display") (EApp (EMethodRef "display") (EVar "arrows")))) (ELit (LString ""))) (ELit (LString ""))))
(DTypeSig true "effectEscapeMsg" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "String"))))))
(DFunDef false "effectEscapeMsg" ((PVar "name") (PVar "declared") (PVar "tail") (PVar "extras")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "` performs <"))) (EApp (EMethodRef "display") (EApp (EVar "renderAtoms") (EVar "extras")))) (ELit (LString "> but its signature allows only "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "renderDeclaredRow") (EVar "declared")) (EVar "tail")))) (ELit (LString "; add <"))) (EApp (EMethodRef "display") (EApp (EVar "renderAtoms") (EVar "extras")))) (ELit (LString "> to the declared row"))))
(DTypeSig false "renderDeclaredRow" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))
(DFunDef false "renderDeclaredRow" ((PVar "declared") (PList)) (EBinOp "++" (EBinOp "++" (ELit (LString "<")) (EApp (EMethodRef "display") (EApp (EVar "renderAtoms") (EVar "declared")))) (ELit (LString ">"))))
(DFunDef false "renderDeclaredRow" ((PList) (PVar "tails")) (EBinOp "++" (EBinOp "++" (ELit (LString "<")) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString " | "))) (EVar "tails")))) (ELit (LString ">"))))
(DFunDef false "renderDeclaredRow" ((PVar "declared") (PVar "tails")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "<")) (EApp (EMethodRef "display") (EApp (EVar "renderAtoms") (EVar "declared")))) (ELit (LString " | "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString " | "))) (EVar "tails")))) (ELit (LString ">"))))
(DTypeSig true "sigOverExpansiveMsg" (TyFun (TyCon "String") (TyFun (TyCon "Ty") (TyCon "String"))))
(DFunDef false "sigOverExpansiveMsg" ((PVar "name") (PVar "ty")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "the signature of `")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "` is polymorphic (`"))) (EApp (EMethodRef "display") (EApp (EVar "ppTy") (EVar "ty")))) (ELit (LString "`) but its body is not a value, so it cannot be generalized; give `"))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "` a parameter or declare a monomorphic type"))))
(DTypeSig true "sigTooGeneralMsg" (TyFun (TyCon "String") (TyFun (TyCon "Ty") (TyCon "String"))))
(DFunDef false "sigTooGeneralMsg" ((PVar "name") (PVar "ty")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "the signature of `")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "` is more general than its body: `"))) (EApp (EMethodRef "display") (EApp (EVar "ppTy") (EVar "ty")))) (ELit (LString "` claims type variables that inference makes the same type"))))
(DTypeSig true "annotTooGeneralMsg" (TyFun (TyCon "Ty") (TyCon "String")))
(DFunDef false "annotTooGeneralMsg" ((PVar "ty")) (EBinOp "++" (EBinOp "++" (ELit (LString "type annotation `")) (EApp (EVar "ppTy") (EVar "ty"))) (ELit (LString "` is more polymorphic than the expression: a type variable in it is a specific type, or two of its variables are the same type"))))
(DTypeSig true "requiresUnroutedMsg" (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "String"))))
(DFunDef false "requiresUnroutedMsg" ((PVar "iface") (PVar "args")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "cannot pass a dictionary for `")) (EApp (EMethodRef "display") (EFieldAccess (EVar "iface") "irName"))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EVar "ppPredArgsShared") (EVar "args")))) (ELit (LString "`: a matching `impl "))) (EApp (EMethodRef "display") (EFieldAccess (EVar "iface") "irName"))) (ELit (LString " ...` exists but is declared in a module this one does not import; import that module here, and if this binding has a signature, declare the constraint there too"))))
(DTypeSig true "missingConstraintVecMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))))
(DFunDef false "missingConstraintVecMsg" ((PVar "name") (PVar "iface") (PVar "varNames")) (EBlock (DoLet false false (PVar "pred") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EBinOp "::" (EVar "iface") (EVar "varNames")))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "the body of `")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "` requires `"))) (EApp (EMethodRef "display") (EVar "pred"))) (ELit (LString "`, which its signature does not declare; add `"))) (EApp (EMethodRef "display") (EVar "pred"))) (ELit (LString " =>`"))))))
(DTypeSig true "varNameForId" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))))) (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "varNameForId" ((PVar "sigTvMaps") (PVar "m") (PVar "id")) (EMatch (EApp (EApp (EVar "findSigTvMap") (EVar "m")) (EVar "sigTvMaps")) (arm (PCon "None") () (ELit (LString "a"))) (arm (PCon "Some" (PVar "tvMap")) () (EMatch (EApp (EApp (EVar "findTvName") (EVar "id")) (EVar "tvMap")) (arm (PCon "None") () (ELit (LString "a"))) (arm (PCon "Some" (PVar "n")) () (EVar "n"))))))
(DTypeSig false "findSigTvMap" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono"))))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Mono")))))))
(DFunDef false "findSigTvMap" (PWild (PList)) (EVar "None"))
(DFunDef false "findSigTvMap" ((PVar "m") (PCons (PTuple (PVar "n") PWild (PVar "tvMap")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "n") (EVar "m")) (EApp (EVar "Some") (EVar "tvMap")) (EIf (EVar "otherwise") (EApp (EApp (EVar "findSigTvMap") (EVar "m")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "missingConstraintMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "missingConstraintMsg" ((PVar "name") (PVar "iface") (PVar "varName")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "the body of `")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "` requires `"))) (EApp (EMethodRef "display") (EVar "iface"))) (ELit (LString " "))) (EApp (EMethodRef "display") (EVar "varName"))) (ELit (LString "`, which its signature does not declare; add `"))) (EApp (EMethodRef "display") (EVar "iface"))) (ELit (LString " "))) (EApp (EMethodRef "display") (EVar "varName"))) (ELit (LString " =>`"))))
(DTypeSig true "ambigReexportMsg" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))))
(DFunDef false "ambigReexportMsg" ((PVar "n") (PVar "depId") (PVar "mids")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "ambiguous `")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "` imported from `"))) (EApp (EMethodRef "display") (EVar "depId"))) (ELit (LString "`: defined in both "))) (EApp (EMethodRef "display") (EApp (EVar "joinAnd") (EApp (EApp (EMethodRef "map") (EVar "backticked")) (EVar "mids"))))) (ELit (LString ""))))
(DTypeSig true "ambigReexportHelp" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))))
(DFunDef false "ambigReexportHelp" ((PVar "n") (PVar "depId") (PVar "mids")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EMethodRef "display") (EVar "depId"))) (ELit (LString "` re-exports more than one `"))) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "`; import the definition you mean directly, as in `import "))) (EApp (EMethodRef "display") (EApp (EVar "firstMid") (EVar "mids")))) (ELit (LString ".{"))) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "}`"))))
(DTypeSig false "firstMid" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "firstMid" ((PCons (PVar "m") PWild)) (EVar "m"))
(DFunDef false "firstMid" ((PList)) (ELit (LString "<module>")))
(DTypeSig true "locGoalKey" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "String")))
(DFunDef false "locGoalKey" ((PCon "None")) (ELit (LString "")))
(DFunDef false "locGoalKey" ((PCon "Some" (PCon "Loc" (PVar "file") (PVar "sl") (PVar "sc") (PVar "el") (PVar "ec")))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "file"))) (ELit (LString ":"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "sl")))) (ELit (LString ":"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "sc")))) (ELit (LString ":"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "el")))) (ELit (LString ":"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "ec")))) (ELit (LString ""))))
(DTypeSig false "allDigits" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "allDigits" ((PVar "n")) (EBinOp "&&" (EBinOp ">" (EApp (EVar "stringLength") (EVar "n")) (ELit (LInt 0))) (EApp (EApp (EVar "allDigitsFrom") (EVar "n")) (ELit (LInt 0)))))
(DTypeSig false "allDigitsFrom" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "allDigitsFrom" ((PVar "n") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "stringLength") (EVar "n"))) (EVar "True") (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "c") (EApp (EApp (EApp (EVar "stringSlice") (EVar "i")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n"))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LString "0"))) (EBinOp "<=" (EVar "c") (ELit (LString "9")))) (EApp (EApp (EVar "allDigitsFrom") (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "backticked" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "backticked" ((PVar "s")) (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EMethodRef "display") (EVar "s"))) (ELit (LString "`"))))
(DTypeSig true "appSpineName" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "appSpineName" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "appSpineName") (EVar "e")))
(DFunDef false "appSpineName" ((PCon "EDoOrigin" PWild (PVar "e"))) (EApp (EVar "appSpineName") (EVar "e")))
(DFunDef false "appSpineName" ((PCon "EAnnot" (PVar "e") PWild)) (EApp (EVar "appSpineName") (EVar "e")))
(DFunDef false "appSpineName" ((PCon "EApp" (PVar "f") PWild)) (EApp (EVar "appSpineName") (EVar "f")))
(DFunDef false "appSpineName" ((PCon "EVar" (PVar "n"))) (EApp (EVar "Some") (EVar "n")))
(DFunDef false "appSpineName" ((PCon "EVarId" (PVar "n") PWild)) (EApp (EVar "Some") (EVar "n")))
(DFunDef false "appSpineName" ((PCon "EVarAt" (PVar "n") PWild)) (EApp (EVar "Some") (EVar "n")))
(DFunDef false "appSpineName" ((PCon "EMethodAt" (PVar "n") PWild PWild)) (EApp (EVar "Some") (EVar "n")))
(DFunDef false "appSpineName" ((PCon "EDictAt" (PVar "n") PWild)) (EApp (EVar "Some") (EVar "n")))
(DFunDef false "appSpineName" (PWild) (EVar "None"))
(DTypeSig true "ordinalWord" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "ordinalWord" ((PLit (LInt 0))) (ELit (LString "first")))
(DFunDef false "ordinalWord" ((PLit (LInt 1))) (ELit (LString "second")))
(DFunDef false "ordinalWord" ((PLit (LInt 2))) (ELit (LString "third")))
(DFunDef false "ordinalWord" ((PLit (LInt 3))) (ELit (LString "fourth")))
(DFunDef false "ordinalWord" ((PLit (LInt 4))) (ELit (LString "fifth")))
(DFunDef false "ordinalWord" ((PVar "i")) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EBinOp "+" (EVar "i") (ELit (LInt 1)))))) (ELit (LString "th"))))
(DTypeSig true "noImplFoundMsg" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "String"))))
(DFunDef false "noImplFoundMsg" ((PVar "iface") (PList (PVar "arg"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "no impl of ")) (EApp (EMethodRef "display") (EVar "iface"))) (ELit (LString " for "))) (EApp (EMethodRef "display") (EApp (EVar "ppMonosShared") (EListLit (EVar "arg"))))) (ELit (LString ""))))
(DFunDef false "noImplFoundMsg" ((PVar "iface") (PVar "args")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "no impl of ")) (EApp (EMethodRef "display") (EVar "iface"))) (ELit (LString " for "))) (EApp (EMethodRef "display") (EApp (EVar "ppPredArgsShared") (EVar "args")))) (ELit (LString ""))))
(DTypeSig true "noImplAdvice" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "noImplAdvice" ((PVar "iface") (PVar "n")) (EIf (EApp (EVar "derivableIface") (EVar "iface")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "add `deriving ")) (EApp (EMethodRef "display") (EVar "iface"))) (ELit (LString "` to `"))) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "` or write `impl "))) (EApp (EMethodRef "display") (EVar "iface"))) (ELit (LString " "))) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "`"))) (EIf (EVar "otherwise") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "write `impl ")) (EApp (EMethodRef "display") (EVar "iface"))) (ELit (LString " "))) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "`"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "derivableIface" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "derivableIface" ((PVar "iface")) (EApp (EApp (EVar "contains") (EVar "iface")) (EListLit (ELit (LString "Eq")) (ELit (LString "Ord")) (ELit (LString "Debug")) (ELit (LString "Display")) (ELit (LString "Generic")))))
(DTypeSig true "quotedNames" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "quotedNames" ((PVar "names")) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "n")) (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EVar "n")) (ELit (LString "`"))))) (EVar "names"))))
(DTypeSig true "locKey" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "String")))
(DFunDef false "locKey" ((PCon "None")) (ELit (LString "")))
(DFunDef false "locKey" ((PCon "Some" (PCon "Loc" (PVar "file") (PVar "line") (PVar "col") PWild PWild))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "file"))) (ELit (LString ":"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "line")))) (ELit (LString ":"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "col")))) (ELit (LString ""))))
(DTypeSig true "msgAtKey" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "String"))))
(DFunDef false "msgAtKey" ((PVar "msg") (PVar "at")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "msg"))) (ELit (LString "\t@@\t"))) (EApp (EMethodRef "display") (EApp (EVar "locKey") (EVar "at")))) (ELit (LString ""))))
(DTypeSig false "writtenNames" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "writtenNames" ((PVar "text")) (EMatch (EApp (EApp (EVar "splitOnChar") (ELit (LChar "$"))) (EVar "text")) (arm (PList (PVar "only")) () (EVar "only")) (arm (PVar "parts") () (EApp (EVar "dropRenameSuffixes") (EVar "parts")))))
(DTypeSig false "dropRenameSuffixes" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "dropRenameSuffixes" ((PList)) (ELit (LString "")))
(DFunDef false "dropRenameSuffixes" ((PList (PVar "a"))) (EVar "a"))
(DFunDef false "dropRenameSuffixes" ((PCons (PVar "a") (PCons PWild (PCons (PVar "n") (PCons (PVar "lb") (PVar "more")))))) (EIf (EBinOp "&&" (EApp (EVar "allDigits") (EVar "n")) (EApp (EApp (EVar "startsWith") (ELit (LString "lb"))) (EVar "lb"))) (EBinOp "++" (EVar "a") (EApp (EVar "dropRenameSuffixes") (EBinOp "::" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 2))) (EApp (EVar "stringLength") (EVar "lb"))) (EVar "lb")) (EVar "more")))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "dropRenameSuffixes" ((PCons (PVar "a") (PVar "rest"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "a"))) (ELit (LString "$"))) (EApp (EMethodRef "display") (EApp (EVar "dropRenameSuffixes") (EVar "rest")))) (ELit (LString ""))))
(DTypeSig true "writtenDiag" (TyFun (TyCon "TcDiag") (TyCon "TcDiag")))
(DFunDef false "writtenDiag" ((PCon "TcDiag" (PVar "code") (PVar "sev") (PVar "loc") (PVar "msg") (PVar "help") (PVar "fix"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "TcDiag") (EVar "code")) (EVar "sev")) (EVar "loc")) (EApp (EVar "writtenNames") (EVar "msg"))) (EApp (EApp (EMethodRef "map") (EVar "writtenNames")) (EVar "help"))) (EVar "fix")))
(DTypeSig true "findTupleCand" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Mono") (TyCon "String") (TyApp (TyCon "Option") (TyTuple (TyCon "Loc") (TyCon "String"))))) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyTuple (TyCon "Loc") (TyCon "String"))))))))
(DFunDef false "findTupleCand" (PWild (PList)) (EVar "None"))
(DFunDef false "findTupleCand" ((PVar "key") (PCons (PTuple (PVar "res") (PVar "help") (PVar "fix")) (PVar "rest"))) (EIf (EBinOp "==" (EApp (EVar "ppMono") (EApp (EVar "normalize") (EVar "res"))) (EVar "key")) (EApp (EVar "Some") (ETuple (EVar "help") (EVar "fix"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "findTupleCand") (EVar "key")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "prependDiagOpt" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "TcDiag")) (TyApp (TyCon "List") (TyCon "TcDiag"))))))))
(DFunDef false "prependDiagOpt" (PWild PWild PWild (PCon "None") (PVar "ds")) (EVar "ds"))
(DFunDef false "prependDiagOpt" ((PVar "code") (PVar "sev") (PVar "help") (PCon "Some" (PVar "msg")) (PVar "ds")) (EBinOp "::" (EApp (EVar "writtenDiag") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "TcDiag") (EVar "code")) (EVar "sev")) (EVar "None")) (EVar "msg")) (EVar "help")) (EVar "None"))) (EVar "ds")))
