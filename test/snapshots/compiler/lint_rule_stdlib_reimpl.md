# META
source_lines=526
stages=DESUGAR,MARK
# SOURCE
-- lint rule rule-stdlib-reimpl: a top-level function that reimplements an exported stdlib function under another name (same declared signature) (STYLE §7a).

import frontend.ast.{
  Loc(..), Ty(..), EffAtomTy(..), effAtomSurface, binderDomainSurface,
  Constraint(..), Pat(..), UsePath(..), Expr(..), Decl(..), qualifierSource,
  authTermsSurface
}
import frontend.parser.{Positions(..)}
import driver.diagnostics.{Severity(..)}
import support.util.{
  escStr, anyList, filterList, reverseL, joinWith, startsWith, endsWith, dedup
}
import hash_map.{HashMap, new, get, setInPlace, has}
import tools.lint_core.{
  Category(..),
  FileFacts(..),
  Finding(..),
  Fixability(..),
  Need(..),
  Ratchet(..),
  Rule,
  RuleMeta(..),
  Scope(..),
  StdlibIndex,
  mkRule,
  stdlibEntriesOf,
  stdlibIndexNames,
}
import tools.lint_shared.{
  appSpineOf,
  clausesOf,
  dedupeNamesLoc,
  declLocList,
  lastSegOf,
  memberLocalIfOrigin,
  nameSetOf,
  paramNameOf,
  ruleNameStdlibReimpl,
  sortUniqS,
  stdlibModuleOf,
  stripELoc,
  topDefNameL,
}

export
rule : Rule
rule =
  mkRule
    RuleMeta {
      name = ruleNameStdlibReimpl,
      summary =
        "top-level function reimplements a stdlib function under a different name (same declared signature) (STYLE §7a)",
      doc =
        "A top-level function whose declared signature equals that of an exported stdlib function, and whose body does the same work, reimplements the stdlib under another name. The rule compares against the stdlib signature index. Call the stdlib function.\n\nBefore:\n  sumAll : List Int -> Int\n  sumAll xs = foldl (+) 0 xs\nAfter:\n  use `sum` from the stdlib",
      category = Style,
      scope = Universal,
      ratchet = Baselined,
      defaultSeverity = SevWarning,
      fixability = NotFixable,
      needs = [NeedsStdlibIndex],
    }
    ruleStdlibReimpl
    None

-- ── rule: stdlib-reimpl (STYLE §7a) ───────────────────────────────────────────
-- A top-level definition that REIMPLEMENTS a stdlib export.  Two conjuncts, and
-- both are load-bearing (#2248 Miss 2, plus the measurements this rule was cut
-- from):
--
--   RECALL comes from NAME RELAXATION.  Matching a hand-curated
--   15-name list EXACTLY makes `listReverse` / `takeN` / `reverseList` — the shapes
--   people actually write — invisible.  A candidate is any
--   top-level def whose lowercased name has some exported stdlib name (length
--   >= 4, lowercased) as a PREFIX or a SUFFIX.  An exact name match is just the
--   empty-remainder case, so nothing the old curated list caught is lost.
--
--   PRECISION comes from SIGNATURE EQUALITY.  Relaxation ALONE yields 1,866
--   candidates tree-wide, which is unshippable; requiring the def's DECLARED
--   signature to alpha-normalize-equal the stdlib export's DECLARED signature
--   takes that to 60, overwhelmingly genuine.  The filter is not decoration:
--   `initList : List a -> List a` relaxes onto `list.init`, whose real signature
--   is `List a -> Option (List a)`, and only the filter keeps that quiet.
--
-- The CONVERSE — signature equality as the CANDIDATE GENERATOR, with no name
-- relation at all — is MEASURED FALSE and must not be built here (it is what
-- `TYPE-AWARE-LINT-DESIGN.md` §7c describes): 940 net-new findings, 650 of them
-- ambiguous.  The signature is a FILTER on a name-relaxed set, never the set.
--
-- Compare DECLARED signatures on both sides, never rendered SCHEMES.
-- `ppScheme` erases effect rows (32 of `stdlib/list.mdk`'s own 77 signatures
-- differ under it), and lint has no type environment to infer a scheme from in
-- any case.  Both sides here come from the same place — a source `DTypeSig`'s
-- `Ty` — the user's from this file, the stdlib's from `StdlibIndex`.
--
-- A def with NO declared signature therefore never fires.  That is deliberate,
-- not a hole: with nothing to compare against, all that is left is the name
-- relaxation, i.e. the 1,866-candidate rule above.  `rule-missing-signature` is
-- what covers an unsigned top-level binding.
--
-- AMBIGUITY.  A stdlib name is NOT unique — `reverse` is declared by three
-- modules with three different signatures (see `StdlibIndex`), and 55 of the 396
-- exported names are declared more than once.  So the rule fires when the def's
-- signature matches ANY ONE candidate for the relaxed name, and names the module
-- that matched: `listReverse : List a -> List a` selects `list.reverse` out of
-- the three rather than being defeated by whichever entry happened to be first.
--
-- Skip only the TRUE OWNER of a name, not every stdlib file: `stdlib/list.mdk`
-- defining `reverse` is the canonical definition the rule points other code
-- at, so it must not fire on itself — but `stdlib/toml.mdk` defining
-- `listReverse` does not OWN `list.reverse`, so a blanket "this path is under
-- stdlib/" skip would wrongly exempt it too (#2248 Miss 1).  Ownership is
-- decided per matched candidate, not per file: `path`'s own module
-- (`stdlibModuleOf path`) is threaded through so a candidate whose module IS that
-- file is never offered as a match (`firstMatchingModule` below).
--
-- Ownership needs BOTH conjuncts.  A basename match alone is not ownership:
-- `/tmp/whatever/list.mdk` is not `stdlib/list.mdk`, and keying the exemption
-- on the basename ALONE re-created #2248 Miss 1 one level down — any file
-- anywhere named `list.mdk` became blanket-exempt from every `list` export.
-- So the linted file must ALSO actually be under `stdlib/` (`isStdlibPath`)
-- before it can own anything; outside stdlib the owner is `None` and no
-- candidate is ever skipped.
ruleStdlibReimpl : StdlibIndex ->
  String ->
  FileFacts ->
  Positions ->
  List Decl ->
  List Finding
ruleStdlibReimpl idx path _ pos prog =
  -- both hoisted out of the per-def loop: `stdlibIndexNames` sorts the whole
  -- key set on every call, and the signature map is one pass over the file.
  let ownMod = stdlibModuleOf path
  let names = stdlibIndexNames idx
  let sigs = sigTyMapOf prog
  -- every NAME this file itself declares in a type-ish namespace (#2327
  -- finding 2) — see `localTyNamesOf`.
  let locals = nameSetOf (flatMap localTyNamesL prog)
  -- dedupe by name so a multi-clause function (consecutive DFunDefs) fires once,
  -- keeping the FIRST clause's location.
  flatMap
    (reimplHit idx ownMod names sigs locals prog)
    (dedupeNamesLoc (flatMap topDefNameL (declLocList pos prog)))

-- ── homonym guard (#2327 finding 2) ───────────────────────────────────────────
-- `tyCanon` compares type constructors, constraint heads and effect labels by
-- BARE NAME — it has no resolver, so it cannot tell stdlib's `Set` from a `Set`
-- the linted file declares itself.  Without a guard, a file that defines its own
-- `data Set a` and an `insertSet : Ord a => a -> Set a -> Set a` alpha-matches
-- `set.insert` and is told to "use the stdlib version" — advice that is not
-- merely noisy but TYPE-INCORRECT, since the two `Set`s are unrelated types.
--
-- This is exactly the bare-name-across-modules hazard the stdlib INDEX is keyed
-- to avoid for stdlib VALUE names; it was never applied to the TYPE names inside
-- signature comparison.
--
-- The guard is declared-signature-only (no resolve/typecheck is available to a
-- lint rule): if a candidate's own signature mentions a name this file declares
-- locally, that name cannot be the stdlib one — a file that defines its own
-- `Set` is talking about its own `Set` — so the candidate is skipped before any
-- signature comparison happens.  It is a PRE-FILTER; `tyCanon` itself is
-- untouched.
--
-- Audit the three namespaces as a SET, not one member: `tyCanon` emits a bare
-- name in exactly three places — `#n` for a `TyCon`, `[h …]` for a constraint
-- HEAD, and a row atom for an effect LABEL.  So a local declaration in ANY of
-- the three namespaces can shadow a stdlib name inside a canonical string, and
-- all three declaring forms must be collected here: types (`DData`, `DNewtype`,
-- `DTypeAlias`), interfaces (`DInterface`, the constraint heads), and effects
-- (`DEffect`, the row labels).
localTyNamesL : Decl -> List String
localTyNamesL (DData { dataName = n }) = [n]
localTyNamesL (DNewtype { newtypeName = n }) = [n]
localTyNamesL (DTypeAlias { tyAliasName = n }) = [n]
localTyNamesL (DInterface { name = n }) = [n]
localTyNamesL (DEffect _ n _ _ _ _) = [n]
localTyNamesL (DAttrib _ d) = localTyNamesL d
localTyNamesL _ = []

-- Every bare name a declared `Ty` contributes to its canonical string: type
-- constructor names, constraint heads, and effect-row labels.  Kept in lockstep
-- with `tyCanonIn`/`constrCanon`/`rowAtomCanon` — a new bare-name-emitting arm
-- there needs an arm here.
tyNamesOf : Ty -> List String
tyNamesOf (TyVar _) = []
tyNamesOf (TyCon { tyConName = n }) = [n]
tyNamesOf (TyApp f x) = tyNamesOf f ++ tyNamesOf x
tyNamesOf (TyFun a b) = tyNamesOf a ++ tyNamesOf b
tyNamesOf (TyTuple ts) = flatMap tyNamesOf ts
tyNamesOf (TyEffect es _ t) = map effAtomLabel es ++ tyNamesOf t
tyNamesOf (TyRow es _ _) = map effAtomLabel es
tyNamesOf (TyAuth _ _) = []
tyNamesOf (TyConstrained cs t) = flatMap constrTyNames cs ++ tyNamesOf t
tyNamesOf (TyNamed _ t _) = tyNamesOf t
tyNamesOf (TyQual t _ _) = tyNamesOf t

effAtomLabel : EffAtomTy -> String
effAtomLabel a = a.eatLabel

constrTyNames : Constraint -> List String
constrTyNames (Constraint { constraintHead = h, constraintArgs = args }) =
  h :: flatMap tyNamesOf args

-- Does this signature mention any name the linted file declares itself?
mentionsLocalTy : HashMap String Unit -> Ty -> Bool
mentionsLocalTy locals ty = anyList (n => has n locals) (tyNamesOf ty)

-- One def's findings: at most one, naming the stdlib module whose declared
-- signature this def's own declared signature alpha-matches.  No signature in
-- this file for the name ⇒ nothing to compare ⇒ no finding.  `ownMod` is the
-- linted file's own module id when the file is under `stdlib/`, else `None` —
-- a candidate owned by `ownMod` is the true owner's canonical definition,
-- never a "reimplementation" of itself.
-- `locals` is the homonym guard (`localTyNamesL`): a signature naming a type,
-- interface or effect this very file declares cannot be talking about stdlib's
-- name of the same spelling, so it is skipped before comparison.
-- `prog` is the whole file's raw decls, needed only to test the matched def
-- for the delegation exemption below (#2620) — a plain forwarding wrapper is
-- not a reimplementation.
reimplHit : StdlibIndex ->
  Option String ->
  List String ->
  HashMap String Ty ->
  HashMap String Unit ->
  List Decl ->
  (String, Option Loc) ->
  List Finding
reimplHit idx ownMod names sigs locals prog (name, loc) = match get name sigs
  None => []
  Some ty =>
    if mentionsLocalTy locals ty then
      []
    else match (firstMatchingExport
      idx
      ownMod
      (tyCanon ty)
      (filterList (relaxesOnto name) names))
      None => []
      Some (modName, stdName) =>
        if isDelegationOf prog name modName stdName then
          []
        else
          [stdlibFinding name modName stdName loc]

-- ── delegation exemption (#2620) ────────────────────────────────────────────
-- A delegation (`take n xs = List.take n xs`) reimplements nothing — it is a
-- one-line forwarding wrapper, and the rule exists to flag DUPLICATED logic.
-- Exempt iff `name`'s SOLE `DFunDef` clause applies a name this file imports
-- from `modName` under `stdName` to the clause's own parameters, in the same
-- ORDER they were declared — or the clause is a bare zero-param alias
-- (`f = m.g`).  A multi-clause def is pattern-matching, not forwarding, so it
-- never qualifies; an argument reorder (`f a b = g b a`) is deliberately NOT
-- exempt — the `listContains`/`elemInt` flipped-twin class (#2312) is exactly
-- what a naive "does the body call the stdlib name" check would wrongly wave
-- through.
isDelegationOf : List Decl -> String -> String -> String -> Bool
isDelegationOf prog name modName stdName =
  match localNameForStdlib prog modName stdName
    None => False
    Some local => match soleClauseOf name prog
      None => False
      Some (ps, body) => forwardsParams local ps body

-- `name`'s params/body, if it has EXACTLY one `DFunDef` clause in this file.
soleClauseOf : String -> List Decl -> Option (List Pat, Expr)
soleClauseOf name prog = match clausesOf name prog
  [one] => Some one
  _ => None

-- Does `body` apply `local` to exactly `ps`'s own parameters, left to right?
-- Zero params is the bare-alias shape: `body` must be the variable `local`
-- itself.  Any non-variable param or argument (a destructured pattern, a
-- literal, a reordered/extra/missing argument) fails the comparison rather
-- than being coerced into a match.
forwardsParams : String -> List Pat -> Expr -> Bool
forwardsParams local [] body = match stripELoc body
  EVar n => n == local
  _ => False
forwardsParams local ps body =
  let (headE, args) = appSpineOf body
  match headE
    EVar n => n == local && paramsMatchArgs ps args
    _ => False

-- Every param must be a bound VARIABLE and every arg a variable REFERENCE,
-- with the two resulting name lists equal in order — comparing the raw
-- `Option String` lists directly would let a wildcard param and a hardcoded
-- literal argument both read `None` at the same position and coincidentally
-- "match".
paramsMatchArgs : List Pat -> List Expr -> Bool
paramsMatchArgs ps args = match (
  allSome (paramNamesOf ps),
  allSome (argNamesOf args),
)
  (Some pns, Some ans) => pns == ans
  _ => False

-- `None` if any element of `xs` is `None`; otherwise `Some` of the unwrapped
-- values, in order.
allSome : List (Option String) -> Option (List String)
allSome [] = Some []
allSome (None :: _) = None
allSome ((Some x) :: rest) = map (x :: _) (allSome rest)

paramNamesOf : List Pat -> List (Option String)
paramNamesOf ps = map paramNameOf ps

argNamesOf : List Expr -> List (Option String)
argNamesOf args = map argNameOf args

argNameOf : Expr -> Option String
argNameOf e = match stripELoc e
  EVar n => Some n
  _ => None

-- The LOCAL name this file's own `import` decls bind to `modName.stdName`, if
-- any — read straight off the raw `DUse` decls, never a resolved binding
-- (lint has no resolver).  `None` when the file never imports that module, or
-- imports it without binding that particular name (a bare `import m`, per
-- [P-IMPORT-BINDS], binds no names at all).
localNameForStdlib : List Decl -> String -> String -> Option String
localNameForStdlib prog modName stdName =
  firstJustL (localNameForStdlibInDecl modName stdName) prog

firstJustL : (a -> Option b) -> List a -> Option b
firstJustL _ [] = None
firstJustL f (x :: rest) = match f x
  Some y => Some y
  None => firstJustL f rest

localNameForStdlibInDecl : String -> String -> Decl -> Option String
localNameForStdlibInDecl modName stdName (DUse _ path _) =
  localNameForStdlibInPath modName stdName path
localNameForStdlibInDecl modName stdName (DAttrib _ d) =
  localNameForStdlibInDecl modName stdName d
localNameForStdlibInDecl _ _ _ = None

localNameForStdlibInPath : String -> String -> UsePath -> Option String
localNameForStdlibInPath modName stdName (UseGroup path members) =
  if lastSegOf path == modName then
    firstJustL (memberLocalIfOrigin stdName) members
  else
    None
localNameForStdlibInPath modName stdName (UseWild path) =
  if lastSegOf path == modName then Some stdName else None
localNameForStdlibInPath _ _ _ = None

-- `user` is a RELAXATION of the stdlib name `std` iff, case-insensitively, it
-- starts or ends with it (`listReverse` ⊇ `reverse`, `takeN` ⊇ `take`).  The
-- `>= 4` floor is the noise gate: without it `map`, `id`, `at`, `abs`, `not`
-- match half the tree by accident (`mapValues`, `idle`, `absPath`).
relaxesOnto : String -> String -> Bool
relaxesOnto user std =
  let s = stringToLower std
  let u = stringToLower user
  stringLength s >= 4 && (startsWith s u || endsWith s u)

-- The first (module, stdlib name) whose declared signature canonicalises to
-- `canon`, over the relaxed candidate names in index order — never the
-- linted file's own module (`ownMod`), which is the true owner rather than a
-- reimplementation of itself.
firstMatchingExport : StdlibIndex ->
  Option String ->
  String ->
  List String ->
  Option (String, String)
firstMatchingExport _ _ _ [] = None
firstMatchingExport idx ownMod canon (std :: rest) =
  match firstMatchingModule ownMod canon (stdlibEntriesOf idx std)
    Some modName => Some (modName, std)
    None => firstMatchingExport idx ownMod canon rest

-- Skip a candidate OWNED by `ownMod` (the linted file's own module) before
-- testing the signature at all: the true owner's definition can never be a
-- "reimplementation" of itself, regardless of what its signature canonicalises to.
-- `ownMod` is `None` for any file outside `stdlib/`, which owns nothing.
firstMatchingModule : Option String ->
  String ->
  List (String, Ty) ->
  Option String
firstMatchingModule _ _ [] = None
firstMatchingModule ownMod canon ((modName, ty) :: rest)
  | ownsModule ownMod modName = firstMatchingModule ownMod canon rest
  | tyCanon ty == canon = Some modName
  | otherwise = firstMatchingModule ownMod canon rest

-- The linted file owns a candidate module iff it HAS an owning module id at all
-- (i.e. it is under `stdlib/`) and that id is the candidate's.
ownsModule : Option String -> String -> Bool
ownsModule None _ = False
ownsModule (Some own) modName = modName == own

-- name → the `Ty` its top-level `DTypeSig` declares.  Built by walking the
-- reversed decl list with an unconditional `setInPlace`, so the FIRST
-- signature in the file wins (a file with two signatures for one name is already a resolve error;
-- this only fixes which one lint reads).
sigTyMapOf : List Decl -> HashMap String Ty
sigTyMapOf prog =
  let m = new ()
  sigTyInto (reverseL (flatMap topSigPairL prog)) m
  m

sigTyInto : List (String, Ty) -> HashMap String Ty -> Unit
sigTyInto [] _ = ()
sigTyInto ((n, t) :: rest) m =
  setInPlace n t m
  sigTyInto rest m

topSigPairL : Decl -> List (String, Ty)
topSigPairL (DTypeSig _ name ty _) = [(name, ty)]
topSigPairL (DAttrib _ d) = topSigPairL d
topSigPairL _ = []

stdlibFinding : String -> String -> String -> Option Loc -> Finding
stdlibFinding name modName stdName loc = Finding {
  rule = ruleNameStdlibReimpl,
  message =
    "top-level '\{name}' reimplements stdlib '\{modName}.\{stdName}' (same declared signature) — use the stdlib version",
  severity = SevWarning,
  loc = loc,
  fix = None,
}

-- ── declared-signature identity, up to renaming ───────────────────────────────
-- `tyCanon` renders a declared `Ty` to a canonical string in which every type
-- variable and every effect-ROW variable is replaced by its FIRST-OCCURRENCE
-- index.  So `List a -> List a` and `List xs -> List xs` share one string while
-- `List a -> List b` does not, and string equality on the result IS alpha-
-- equivalence of the two declarations.
--
-- Two normalizations beyond renaming, both because the written form is not the
-- meaning: an effect ROW is a SET, so its atoms are sorted and deduped, and a
-- CONSTRAINT list likewise.  Everything else — argument order, application
-- spine shape, tuple arity — is structural and preserved exactly.
--
-- This is a canonicaliser, NOT a printer: its output is never shown to anyone,
-- so it is free to be unambiguous rather than pretty.  Every constructor gets
-- its own bracketed head so no two distinct shapes can render to one string —
-- do not "simplify" it into something that reads like source, which is exactly
-- how a canonical form starts answering `a -> b` and `a b` the same way.
tyCanon : Ty -> String
tyCanon t = tyCanonIn (dedup (tyVarsOf t)) (dedup (rowVarsOf t)) t

-- type variables, in first-occurrence order (with repeats; `dedup` above keeps
-- the first of each).
tyVarsOf : Ty -> List String
tyVarsOf (TyVar v) = [v]
tyVarsOf (TyCon { tyConName = _ }) = []
tyVarsOf (TyApp f x) = tyVarsOf f ++ tyVarsOf x
tyVarsOf (TyFun a b) = tyVarsOf a ++ tyVarsOf b
tyVarsOf (TyTuple ts) = flatMap tyVarsOf ts
tyVarsOf (TyEffect _ _ t) = tyVarsOf t
tyVarsOf (TyConstrained cs t) = flatMap constrTyVars cs ++ tyVarsOf t
tyVarsOf (TyRow _ _ _) = []
tyVarsOf (TyAuth _ _) = []
tyVarsOf (TyNamed _ t _) = tyVarsOf t
tyVarsOf (TyQual t _ _) = tyVarsOf t

constrTyVars : Constraint -> List String
constrTyVars (Constraint { constraintArgs = args }) = flatMap tyVarsOf args

-- effect-ROW variables (a row TAIL, `<Stdout | e>`), a namespace of their own:
-- an `e` here and an `e` in type position are different binders, so they get
-- different counters and can never be confused by the renaming.
rowVarsOf : Ty -> List String
rowVarsOf (TyVar _) = []
rowVarsOf (TyCon { tyConName = _ }) = []
rowVarsOf (TyApp f x) = rowVarsOf f ++ rowVarsOf x
rowVarsOf (TyFun a b) = rowVarsOf a ++ rowVarsOf b
rowVarsOf (TyTuple ts) = flatMap rowVarsOf ts
rowVarsOf (TyEffect _ tl t) = tl ++ rowVarsOf t
rowVarsOf (TyConstrained cs t) = flatMap constrRowVars cs ++ rowVarsOf t
rowVarsOf (TyRow _ tl _) = tl
rowVarsOf (TyAuth _ _) = []
rowVarsOf (TyNamed _ t _) = rowVarsOf t
rowVarsOf (TyQual t _ _) = rowVarsOf t

constrRowVars : Constraint -> List String
constrRowVars (Constraint { constraintArgs = args }) = flatMap rowVarsOf args

tyCanonIn : List String -> List String -> Ty -> String
tyCanonIn tvs _ (TyVar v) = "%t" ++ intToString (indexIn v tvs)
tyCanonIn _ _ (TyCon { tyConName = n }) = "#" ++ n
tyCanonIn tvs rvs (TyApp f x) =
  "(@ \{tyCanonIn tvs rvs f} \{tyCanonIn tvs rvs x})"
tyCanonIn tvs rvs (TyFun a b) =
  "(-> \{tyCanonIn tvs rvs a} \{tyCanonIn tvs rvs b})"
tyCanonIn tvs rvs (TyTuple ts) =
  "(, \{joinWith " " (map (tyCanonIn tvs rvs) ts)})"
tyCanonIn tvs rvs (TyEffect es tl t) =
  "(eff \{rowCanon rvs es tl} \{tyCanonIn tvs rvs t})"
tyCanonIn _ rvs (TyRow es tl _) = "(row " ++ rowCanon rvs es tl ++ ")"
tyCanonIn _ _ (TyAuth ps _) = "(auth " ++ authTermsSurface escStr ps ++ ")"
-- An authority binder and a qualifier are part of what a declared type
-- means: two signatures differing only in them are different signatures.
tyCanonIn tvs rvs (TyNamed n t d) =
  "(named \{n} \{tyCanonIn tvs rvs t}\{binderDomainSurface d})"
tyCanonIn tvs rvs (TyQual t ns _) =
  "(qual \{tyCanonIn tvs rvs t} \{qualifierSource escStr ns})"
tyCanonIn tvs rvs (TyConstrained cs t) =
  "(=> \{joinWith " " (sortUniqS (map (constrCanon tvs rvs) cs))} \{tyCanonIn tvs rvs t})"

constrCanon : List String -> List String -> Constraint -> String
constrCanon tvs rvs (Constraint { constraintHead = h, constraintArgs = args }) =
  "[\{h} \{joinWith " " (map (tyCanonIn tvs rvs) args)}]"

rowCanon : List String -> List EffAtomTy -> List String -> String
rowCanon rvs es tl =
  "{\{joinWith " " (sortUniqS (map rowAtomCanon es))}\{rowTailCanon rvs tl}}"

rowAtomCanon : EffAtomTy -> String
rowAtomCanon a = effAtomSurface escStr a

rowTailCanon : List String -> List String -> String
rowTailCanon rvs tls =
  joinWith "" (map (v => " |%r" ++ intToString (indexIn v rvs)) tls)

-- position of `x` in `xs`, or -1 when absent — unreachable, since the order
-- lists are collected from the very type being rendered.
indexIn : String -> List String -> Int
indexIn x xs = indexInGo x xs 0

indexInGo : String -> List String -> Int -> Int
indexInGo _ [] _ = -1
indexInGo x (y :: ys) i
  | x == y = i
  | otherwise = indexInGo x ys (i + 1)
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Ty" true) (mem "EffAtomTy" true) (mem "effAtomSurface" false) (mem "binderDomainSurface" false) (mem "Constraint" true) (mem "Pat" true) (mem "UsePath" true) (mem "Expr" true) (mem "Decl" true) (mem "qualifierSource" false) (mem "authTermsSurface" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("support" "util") ((mem "escStr" false) (mem "anyList" false) (mem "filterList" false) (mem "reverseL" false) (mem "joinWith" false) (mem "startsWith" false) (mem "endsWith" false) (mem "dedup" false))))
(DUse false (UseGroup ("hash_map") ((mem "HashMap" false) (mem "new" false) (mem "get" false) (mem "setInPlace" false) (mem "has" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fixability" true) (mem "Need" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "mkRule" false) (mem "stdlibEntriesOf" false) (mem "stdlibIndexNames" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "appSpineOf" false) (mem "clausesOf" false) (mem "dedupeNamesLoc" false) (mem "declLocList" false) (mem "lastSegOf" false) (mem "memberLocalIfOrigin" false) (mem "nameSetOf" false) (mem "paramNameOf" false) (mem "ruleNameStdlibReimpl" false) (mem "sortUniqS" false) (mem "stdlibModuleOf" false) (mem "stripELoc" false) (mem "topDefNameL" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameStdlibReimpl")) (fa "summary" (ELit (LString "top-level function reimplements a stdlib function under a different name (same declared signature) (STYLE §7a)"))) (fa "doc" (ELit (LString "A top-level function whose declared signature equals that of an exported stdlib function, and whose body does the same work, reimplements the stdlib under another name. The rule compares against the stdlib signature index. Call the stdlib function.\n\nBefore:\n  sumAll : List Int -> Int\n  sumAll xs = foldl (+) 0 xs\nAfter:\n  use `sum` from the stdlib"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Baselined")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "NotFixable")) (fa "needs" (EListLit (EVar "NeedsStdlibIndex")))))) (EVar "ruleStdlibReimpl")) (EVar "None")))
(DTypeSig false "ruleStdlibReimpl" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "ruleStdlibReimpl" ((PVar "idx") (PVar "path") PWild (PVar "pos") (PVar "prog")) (EBlock (DoLet false false (PVar "ownMod") (EApp (EVar "stdlibModuleOf") (EVar "path"))) (DoLet false false (PVar "names") (EApp (EVar "stdlibIndexNames") (EVar "idx"))) (DoLet false false (PVar "sigs") (EApp (EVar "sigTyMapOf") (EVar "prog"))) (DoLet false false (PVar "locals") (EApp (EVar "nameSetOf") (EApp (EApp (EVar "flatMap") (EVar "localTyNamesL")) (EVar "prog")))) (DoExpr (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "reimplHit") (EVar "idx")) (EVar "ownMod")) (EVar "names")) (EVar "sigs")) (EVar "locals")) (EVar "prog"))) (EApp (EVar "dedupeNamesLoc") (EApp (EApp (EVar "flatMap") (EVar "topDefNameL")) (EApp (EApp (EVar "declLocList") (EVar "pos")) (EVar "prog"))))))))
(DTypeSig false "localTyNamesL" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "localTyNamesL" ((PRec "DData" ((rf "dataName" (PVar "n"))) false)) (EListLit (EVar "n")))
(DFunDef false "localTyNamesL" ((PRec "DNewtype" ((rf "newtypeName" (PVar "n"))) false)) (EListLit (EVar "n")))
(DFunDef false "localTyNamesL" ((PRec "DTypeAlias" ((rf "tyAliasName" (PVar "n"))) false)) (EListLit (EVar "n")))
(DFunDef false "localTyNamesL" ((PRec "DInterface" ((rf "name" (PVar "n"))) false)) (EListLit (EVar "n")))
(DFunDef false "localTyNamesL" ((PCon "DEffect" PWild (PVar "n") PWild PWild PWild PWild)) (EListLit (EVar "n")))
(DFunDef false "localTyNamesL" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "localTyNamesL") (EVar "d")))
(DFunDef false "localTyNamesL" (PWild) (EListLit))
(DTypeSig false "tyNamesOf" (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "tyNamesOf" ((PCon "TyVar" PWild)) (EListLit))
(DFunDef false "tyNamesOf" ((PRec "TyCon" ((rf "tyConName" (PVar "n"))) false)) (EListLit (EVar "n")))
(DFunDef false "tyNamesOf" ((PCon "TyApp" (PVar "f") (PVar "x"))) (EBinOp "++" (EApp (EVar "tyNamesOf") (EVar "f")) (EApp (EVar "tyNamesOf") (EVar "x"))))
(DFunDef false "tyNamesOf" ((PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EVar "tyNamesOf") (EVar "a")) (EApp (EVar "tyNamesOf") (EVar "b"))))
(DFunDef false "tyNamesOf" ((PCon "TyTuple" (PVar "ts"))) (EApp (EApp (EVar "flatMap") (EVar "tyNamesOf")) (EVar "ts")))
(DFunDef false "tyNamesOf" ((PCon "TyEffect" (PVar "es") PWild (PVar "t"))) (EBinOp "++" (EApp (EApp (EVar "map") (EVar "effAtomLabel")) (EVar "es")) (EApp (EVar "tyNamesOf") (EVar "t"))))
(DFunDef false "tyNamesOf" ((PCon "TyRow" (PVar "es") PWild PWild)) (EApp (EApp (EVar "map") (EVar "effAtomLabel")) (EVar "es")))
(DFunDef false "tyNamesOf" ((PCon "TyAuth" PWild PWild)) (EListLit))
(DFunDef false "tyNamesOf" ((PCon "TyConstrained" (PVar "cs") (PVar "t"))) (EBinOp "++" (EApp (EApp (EVar "flatMap") (EVar "constrTyNames")) (EVar "cs")) (EApp (EVar "tyNamesOf") (EVar "t"))))
(DFunDef false "tyNamesOf" ((PCon "TyNamed" PWild (PVar "t") PWild)) (EApp (EVar "tyNamesOf") (EVar "t")))
(DFunDef false "tyNamesOf" ((PCon "TyQual" (PVar "t") PWild PWild)) (EApp (EVar "tyNamesOf") (EVar "t")))
(DTypeSig false "effAtomLabel" (TyFun (TyCon "EffAtomTy") (TyCon "String")))
(DFunDef false "effAtomLabel" ((PVar "a")) (EFieldAccess (EVar "a") "eatLabel"))
(DTypeSig false "constrTyNames" (TyFun (TyCon "Constraint") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "constrTyNames" ((PRec "Constraint" ((rf "constraintHead" (PVar "h")) (rf "constraintArgs" (PVar "args"))) false)) (EBinOp "::" (EVar "h") (EApp (EApp (EVar "flatMap") (EVar "tyNamesOf")) (EVar "args"))))
(DTypeSig false "mentionsLocalTy" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyCon "Ty") (TyCon "Bool"))))
(DFunDef false "mentionsLocalTy" ((PVar "locals") (PVar "ty")) (EApp (EApp (EVar "anyList") (ELam ((PVar "n")) (EApp (EApp (EVar "has") (EVar "n")) (EVar "locals")))) (EApp (EVar "tyNamesOf") (EVar "ty"))))
(DTypeSig false "reimplHit" (TyFun (TyCon "StdlibIndex") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Ty")) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "List") (TyCon "Finding"))))))))))
(DFunDef false "reimplHit" ((PVar "idx") (PVar "ownMod") (PVar "names") (PVar "sigs") (PVar "locals") (PVar "prog") (PTuple (PVar "name") (PVar "loc"))) (EMatch (EApp (EApp (EVar "get") (EVar "name")) (EVar "sigs")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "ty")) () (EIf (EApp (EApp (EVar "mentionsLocalTy") (EVar "locals")) (EVar "ty")) (EListLit) (EMatch (EApp (EApp (EApp (EApp (EVar "firstMatchingExport") (EVar "idx")) (EVar "ownMod")) (EApp (EVar "tyCanon") (EVar "ty"))) (EApp (EApp (EVar "filterList") (EApp (EVar "relaxesOnto") (EVar "name"))) (EVar "names"))) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PTuple (PVar "modName") (PVar "stdName"))) () (EIf (EApp (EApp (EApp (EApp (EVar "isDelegationOf") (EVar "prog")) (EVar "name")) (EVar "modName")) (EVar "stdName")) (EListLit) (EListLit (EApp (EApp (EApp (EApp (EVar "stdlibFinding") (EVar "name")) (EVar "modName")) (EVar "stdName")) (EVar "loc"))))))))))
(DTypeSig false "isDelegationOf" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))))
(DFunDef false "isDelegationOf" ((PVar "prog") (PVar "name") (PVar "modName") (PVar "stdName")) (EMatch (EApp (EApp (EApp (EVar "localNameForStdlib") (EVar "prog")) (EVar "modName")) (EVar "stdName")) (arm (PCon "None") () (EVar "False")) (arm (PCon "Some" (PVar "local")) () (EMatch (EApp (EApp (EVar "soleClauseOf") (EVar "name")) (EVar "prog")) (arm (PCon "None") () (EVar "False")) (arm (PCon "Some" (PTuple (PVar "ps") (PVar "body"))) () (EApp (EApp (EApp (EVar "forwardsParams") (EVar "local")) (EVar "ps")) (EVar "body")))))))
(DTypeSig false "soleClauseOf" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))))))
(DFunDef false "soleClauseOf" ((PVar "name") (PVar "prog")) (EMatch (EApp (EApp (EVar "clausesOf") (EVar "name")) (EVar "prog")) (arm (PList (PVar "one")) () (EApp (EVar "Some") (EVar "one"))) (arm PWild () (EVar "None"))))
(DTypeSig false "forwardsParams" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Expr") (TyCon "Bool")))))
(DFunDef false "forwardsParams" ((PVar "local") (PList) (PVar "body")) (EMatch (EApp (EVar "stripELoc") (EVar "body")) (arm (PCon "EVar" (PVar "n")) () (EBinOp "==" (EVar "n") (EVar "local"))) (arm PWild () (EVar "False"))))
(DFunDef false "forwardsParams" ((PVar "local") (PVar "ps") (PVar "body")) (EBlock (DoLet false false (PTuple (PVar "headE") (PVar "args")) (EApp (EVar "appSpineOf") (EVar "body"))) (DoExpr (EMatch (EVar "headE") (arm (PCon "EVar" (PVar "n")) () (EBinOp "&&" (EBinOp "==" (EVar "n") (EVar "local")) (EApp (EApp (EVar "paramsMatchArgs") (EVar "ps")) (EVar "args")))) (arm PWild () (EVar "False"))))))
(DTypeSig false "paramsMatchArgs" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyCon "Bool"))))
(DFunDef false "paramsMatchArgs" ((PVar "ps") (PVar "args")) (EMatch (ETuple (EApp (EVar "allSome") (EApp (EVar "paramNamesOf") (EVar "ps"))) (EApp (EVar "allSome") (EApp (EVar "argNamesOf") (EVar "args")))) (arm (PTuple (PCon "Some" (PVar "pns")) (PCon "Some" (PVar "ans"))) () (EBinOp "==" (EVar "pns") (EVar "ans"))) (arm PWild () (EVar "False"))))
(DTypeSig false "allSome" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "String"))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "allSome" ((PList)) (EApp (EVar "Some") (EListLit)))
(DFunDef false "allSome" ((PCons (PCon "None") PWild)) (EVar "None"))
(DFunDef false "allSome" ((PCons (PCon "Some" (PVar "x")) (PVar "rest"))) (EApp (EApp (EVar "map") (ELam ((PVar "_s")) (EBinOp "::" (EVar "x") (EVar "_s")))) (EApp (EVar "allSome") (EVar "rest"))))
(DTypeSig false "paramNamesOf" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "paramNamesOf" ((PVar "ps")) (EApp (EApp (EVar "map") (EVar "paramNameOf")) (EVar "ps")))
(DTypeSig false "argNamesOf" (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "argNamesOf" ((PVar "args")) (EApp (EApp (EVar "map") (EVar "argNameOf")) (EVar "args")))
(DTypeSig false "argNameOf" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "argNameOf" ((PVar "e")) (EMatch (EApp (EVar "stripELoc") (EVar "e")) (arm (PCon "EVar" (PVar "n")) () (EApp (EVar "Some") (EVar "n"))) (arm PWild () (EVar "None"))))
(DTypeSig false "localNameForStdlib" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "localNameForStdlib" ((PVar "prog") (PVar "modName") (PVar "stdName")) (EApp (EApp (EVar "firstJustL") (EApp (EApp (EVar "localNameForStdlibInDecl") (EVar "modName")) (EVar "stdName"))) (EVar "prog")))
(DTypeSig false "firstJustL" (TyFun (TyFun (TyVar "a") (TyApp (TyCon "Option") (TyVar "b"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "Option") (TyVar "b")))))
(DFunDef false "firstJustL" (PWild (PList)) (EVar "None"))
(DFunDef false "firstJustL" ((PVar "f") (PCons (PVar "x") (PVar "rest"))) (EMatch (EApp (EVar "f") (EVar "x")) (arm (PCon "Some" (PVar "y")) () (EApp (EVar "Some") (EVar "y"))) (arm (PCon "None") () (EApp (EApp (EVar "firstJustL") (EVar "f")) (EVar "rest")))))
(DTypeSig false "localNameForStdlibInDecl" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "localNameForStdlibInDecl" ((PVar "modName") (PVar "stdName") (PCon "DUse" PWild (PVar "path") PWild)) (EApp (EApp (EApp (EVar "localNameForStdlibInPath") (EVar "modName")) (EVar "stdName")) (EVar "path")))
(DFunDef false "localNameForStdlibInDecl" ((PVar "modName") (PVar "stdName") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EApp (EVar "localNameForStdlibInDecl") (EVar "modName")) (EVar "stdName")) (EVar "d")))
(DFunDef false "localNameForStdlibInDecl" (PWild PWild PWild) (EVar "None"))
(DTypeSig false "localNameForStdlibInPath" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "UsePath") (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "localNameForStdlibInPath" ((PVar "modName") (PVar "stdName") (PCon "UseGroup" (PVar "path") (PVar "members"))) (EIf (EBinOp "==" (EApp (EVar "lastSegOf") (EVar "path")) (EVar "modName")) (EApp (EApp (EVar "firstJustL") (EApp (EVar "memberLocalIfOrigin") (EVar "stdName"))) (EVar "members")) (EVar "None")))
(DFunDef false "localNameForStdlibInPath" ((PVar "modName") (PVar "stdName") (PCon "UseWild" (PVar "path"))) (EIf (EBinOp "==" (EApp (EVar "lastSegOf") (EVar "path")) (EVar "modName")) (EApp (EVar "Some") (EVar "stdName")) (EVar "None")))
(DFunDef false "localNameForStdlibInPath" (PWild PWild PWild) (EVar "None"))
(DTypeSig false "relaxesOnto" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "relaxesOnto" ((PVar "user") (PVar "std")) (EBlock (DoLet false false (PVar "s") (EApp (EVar "stringToLower") (EVar "std"))) (DoLet false false (PVar "u") (EApp (EVar "stringToLower") (EVar "user"))) (DoExpr (EBinOp "&&" (EBinOp ">=" (EApp (EVar "stringLength") (EVar "s")) (ELit (LInt 4))) (EBinOp "||" (EApp (EApp (EVar "startsWith") (EVar "s")) (EVar "u")) (EApp (EApp (EVar "endsWith") (EVar "s")) (EVar "u")))))))
(DTypeSig false "firstMatchingExport" (TyFun (TyCon "StdlibIndex") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String"))))))))
(DFunDef false "firstMatchingExport" (PWild PWild PWild (PList)) (EVar "None"))
(DFunDef false "firstMatchingExport" ((PVar "idx") (PVar "ownMod") (PVar "canon") (PCons (PVar "std") (PVar "rest"))) (EMatch (EApp (EApp (EApp (EVar "firstMatchingModule") (EVar "ownMod")) (EVar "canon")) (EApp (EApp (EVar "stdlibEntriesOf") (EVar "idx")) (EVar "std"))) (arm (PCon "Some" (PVar "modName")) () (EApp (EVar "Some") (ETuple (EVar "modName") (EVar "std")))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "firstMatchingExport") (EVar "idx")) (EVar "ownMod")) (EVar "canon")) (EVar "rest")))))
(DTypeSig false "firstMatchingModule" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "firstMatchingModule" (PWild PWild (PList)) (EVar "None"))
(DFunDef false "firstMatchingModule" ((PVar "ownMod") (PVar "canon") (PCons (PTuple (PVar "modName") (PVar "ty")) (PVar "rest"))) (EIf (EApp (EApp (EVar "ownsModule") (EVar "ownMod")) (EVar "modName")) (EApp (EApp (EApp (EVar "firstMatchingModule") (EVar "ownMod")) (EVar "canon")) (EVar "rest")) (EIf (EBinOp "==" (EApp (EVar "tyCanon") (EVar "ty")) (EVar "canon")) (EApp (EVar "Some") (EVar "modName")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "firstMatchingModule") (EVar "ownMod")) (EVar "canon")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "ownsModule" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "ownsModule" ((PCon "None") PWild) (EVar "False"))
(DFunDef false "ownsModule" ((PCon "Some" (PVar "own")) (PVar "modName")) (EBinOp "==" (EVar "modName") (EVar "own")))
(DTypeSig false "sigTyMapOf" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Ty"))))
(DFunDef false "sigTyMapOf" ((PVar "prog")) (EBlock (DoLet false false (PVar "m") (EApp (EVar "new") (ELit LUnit))) (DoExpr (EApp (EApp (EVar "sigTyInto") (EApp (EVar "reverseL") (EApp (EApp (EVar "flatMap") (EVar "topSigPairL")) (EVar "prog")))) (EVar "m"))) (DoExpr (EVar "m"))))
(DTypeSig false "sigTyInto" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Ty")) (TyCon "Unit"))))
(DFunDef false "sigTyInto" ((PList) PWild) (ELit LUnit))
(DFunDef false "sigTyInto" ((PCons (PTuple (PVar "n") (PVar "t")) (PVar "rest")) (PVar "m")) (EBlock (DoExpr (EApp (EApp (EApp (EVar "setInPlace") (EVar "n")) (EVar "t")) (EVar "m"))) (DoExpr (EApp (EApp (EVar "sigTyInto") (EVar "rest")) (EVar "m")))))
(DTypeSig false "topSigPairL" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty")))))
(DFunDef false "topSigPairL" ((PCon "DTypeSig" PWild (PVar "name") (PVar "ty") PWild)) (EListLit (ETuple (EVar "name") (EVar "ty"))))
(DFunDef false "topSigPairL" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "topSigPairL") (EVar "d")))
(DFunDef false "topSigPairL" (PWild) (EListLit))
(DTypeSig false "stdlibFinding" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Finding"))))))
(DFunDef false "stdlibFinding" ((PVar "name") (PVar "modName") (PVar "stdName") (PVar "loc")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameStdlibReimpl")) (fa "message" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "top-level '")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "' reimplements stdlib '"))) (EApp (EVar "display") (EVar "modName"))) (ELit (LString "."))) (EApp (EVar "display") (EVar "stdName"))) (ELit (LString "' (same declared signature) — use the stdlib version")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")) (fa "fix" (EVar "None")))))
(DTypeSig false "tyCanon" (TyFun (TyCon "Ty") (TyCon "String")))
(DFunDef false "tyCanon" ((PVar "t")) (EApp (EApp (EApp (EVar "tyCanonIn") (EApp (EVar "dedup") (EApp (EVar "tyVarsOf") (EVar "t")))) (EApp (EVar "dedup") (EApp (EVar "rowVarsOf") (EVar "t")))) (EVar "t")))
(DTypeSig false "tyVarsOf" (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "tyVarsOf" ((PCon "TyVar" (PVar "v"))) (EListLit (EVar "v")))
(DFunDef false "tyVarsOf" ((PRec "TyCon" ((rf "tyConName" PWild)) false)) (EListLit))
(DFunDef false "tyVarsOf" ((PCon "TyApp" (PVar "f") (PVar "x"))) (EBinOp "++" (EApp (EVar "tyVarsOf") (EVar "f")) (EApp (EVar "tyVarsOf") (EVar "x"))))
(DFunDef false "tyVarsOf" ((PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EVar "tyVarsOf") (EVar "a")) (EApp (EVar "tyVarsOf") (EVar "b"))))
(DFunDef false "tyVarsOf" ((PCon "TyTuple" (PVar "ts"))) (EApp (EApp (EVar "flatMap") (EVar "tyVarsOf")) (EVar "ts")))
(DFunDef false "tyVarsOf" ((PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EVar "tyVarsOf") (EVar "t")))
(DFunDef false "tyVarsOf" ((PCon "TyConstrained" (PVar "cs") (PVar "t"))) (EBinOp "++" (EApp (EApp (EVar "flatMap") (EVar "constrTyVars")) (EVar "cs")) (EApp (EVar "tyVarsOf") (EVar "t"))))
(DFunDef false "tyVarsOf" ((PCon "TyRow" PWild PWild PWild)) (EListLit))
(DFunDef false "tyVarsOf" ((PCon "TyAuth" PWild PWild)) (EListLit))
(DFunDef false "tyVarsOf" ((PCon "TyNamed" PWild (PVar "t") PWild)) (EApp (EVar "tyVarsOf") (EVar "t")))
(DFunDef false "tyVarsOf" ((PCon "TyQual" (PVar "t") PWild PWild)) (EApp (EVar "tyVarsOf") (EVar "t")))
(DTypeSig false "constrTyVars" (TyFun (TyCon "Constraint") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "constrTyVars" ((PRec "Constraint" ((rf "constraintArgs" (PVar "args"))) false)) (EApp (EApp (EVar "flatMap") (EVar "tyVarsOf")) (EVar "args")))
(DTypeSig false "rowVarsOf" (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "rowVarsOf" ((PCon "TyVar" PWild)) (EListLit))
(DFunDef false "rowVarsOf" ((PRec "TyCon" ((rf "tyConName" PWild)) false)) (EListLit))
(DFunDef false "rowVarsOf" ((PCon "TyApp" (PVar "f") (PVar "x"))) (EBinOp "++" (EApp (EVar "rowVarsOf") (EVar "f")) (EApp (EVar "rowVarsOf") (EVar "x"))))
(DFunDef false "rowVarsOf" ((PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EVar "rowVarsOf") (EVar "a")) (EApp (EVar "rowVarsOf") (EVar "b"))))
(DFunDef false "rowVarsOf" ((PCon "TyTuple" (PVar "ts"))) (EApp (EApp (EVar "flatMap") (EVar "rowVarsOf")) (EVar "ts")))
(DFunDef false "rowVarsOf" ((PCon "TyEffect" PWild (PVar "tl") (PVar "t"))) (EBinOp "++" (EVar "tl") (EApp (EVar "rowVarsOf") (EVar "t"))))
(DFunDef false "rowVarsOf" ((PCon "TyConstrained" (PVar "cs") (PVar "t"))) (EBinOp "++" (EApp (EApp (EVar "flatMap") (EVar "constrRowVars")) (EVar "cs")) (EApp (EVar "rowVarsOf") (EVar "t"))))
(DFunDef false "rowVarsOf" ((PCon "TyRow" PWild (PVar "tl") PWild)) (EVar "tl"))
(DFunDef false "rowVarsOf" ((PCon "TyAuth" PWild PWild)) (EListLit))
(DFunDef false "rowVarsOf" ((PCon "TyNamed" PWild (PVar "t") PWild)) (EApp (EVar "rowVarsOf") (EVar "t")))
(DFunDef false "rowVarsOf" ((PCon "TyQual" (PVar "t") PWild PWild)) (EApp (EVar "rowVarsOf") (EVar "t")))
(DTypeSig false "constrRowVars" (TyFun (TyCon "Constraint") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "constrRowVars" ((PRec "Constraint" ((rf "constraintArgs" (PVar "args"))) false)) (EApp (EApp (EVar "flatMap") (EVar "rowVarsOf")) (EVar "args")))
(DTypeSig false "tyCanonIn" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Ty") (TyCon "String")))))
(DFunDef false "tyCanonIn" ((PVar "tvs") PWild (PCon "TyVar" (PVar "v"))) (EBinOp "++" (ELit (LString "%t")) (EApp (EVar "intToString") (EApp (EApp (EVar "indexIn") (EVar "v")) (EVar "tvs")))))
(DFunDef false "tyCanonIn" (PWild PWild (PRec "TyCon" ((rf "tyConName" (PVar "n"))) false)) (EBinOp "++" (ELit (LString "#")) (EVar "n")))
(DFunDef false "tyCanonIn" ((PVar "tvs") (PVar "rvs") (PCon "TyApp" (PVar "f") (PVar "x"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(@ ")) (EApp (EVar "display") (EApp (EApp (EApp (EVar "tyCanonIn") (EVar "tvs")) (EVar "rvs")) (EVar "f")))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EApp (EApp (EVar "tyCanonIn") (EVar "tvs")) (EVar "rvs")) (EVar "x")))) (ELit (LString ")"))))
(DFunDef false "tyCanonIn" ((PVar "tvs") (PVar "rvs") (PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(-> ")) (EApp (EVar "display") (EApp (EApp (EApp (EVar "tyCanonIn") (EVar "tvs")) (EVar "rvs")) (EVar "a")))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EApp (EApp (EVar "tyCanonIn") (EVar "tvs")) (EVar "rvs")) (EVar "b")))) (ELit (LString ")"))))
(DFunDef false "tyCanonIn" ((PVar "tvs") (PVar "rvs") (PCon "TyTuple" (PVar "ts"))) (EBinOp "++" (EBinOp "++" (ELit (LString "(, ")) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EVar "map") (EApp (EApp (EVar "tyCanonIn") (EVar "tvs")) (EVar "rvs"))) (EVar "ts"))))) (ELit (LString ")"))))
(DFunDef false "tyCanonIn" ((PVar "tvs") (PVar "rvs") (PCon "TyEffect" (PVar "es") (PVar "tl") (PVar "t"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(eff ")) (EApp (EVar "display") (EApp (EApp (EApp (EVar "rowCanon") (EVar "rvs")) (EVar "es")) (EVar "tl")))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EApp (EApp (EVar "tyCanonIn") (EVar "tvs")) (EVar "rvs")) (EVar "t")))) (ELit (LString ")"))))
(DFunDef false "tyCanonIn" (PWild (PVar "rvs") (PCon "TyRow" (PVar "es") (PVar "tl") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "(row ")) (EApp (EApp (EApp (EVar "rowCanon") (EVar "rvs")) (EVar "es")) (EVar "tl"))) (ELit (LString ")"))))
(DFunDef false "tyCanonIn" (PWild PWild (PCon "TyAuth" (PVar "ps") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "(auth ")) (EApp (EApp (EVar "authTermsSurface") (EVar "escStr")) (EVar "ps"))) (ELit (LString ")"))))
(DFunDef false "tyCanonIn" ((PVar "tvs") (PVar "rvs") (PCon "TyNamed" (PVar "n") (PVar "t") (PVar "d"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(named ")) (EApp (EVar "display") (EVar "n"))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EApp (EApp (EVar "tyCanonIn") (EVar "tvs")) (EVar "rvs")) (EVar "t")))) (ELit (LString ""))) (EApp (EVar "display") (EApp (EVar "binderDomainSurface") (EVar "d")))) (ELit (LString ")"))))
(DFunDef false "tyCanonIn" ((PVar "tvs") (PVar "rvs") (PCon "TyQual" (PVar "t") (PVar "ns") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(qual ")) (EApp (EVar "display") (EApp (EApp (EApp (EVar "tyCanonIn") (EVar "tvs")) (EVar "rvs")) (EVar "t")))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EApp (EVar "qualifierSource") (EVar "escStr")) (EVar "ns")))) (ELit (LString ")"))))
(DFunDef false "tyCanonIn" ((PVar "tvs") (PVar "rvs") (PCon "TyConstrained" (PVar "cs") (PVar "t"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(=> ")) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EVar "sortUniqS") (EApp (EApp (EVar "map") (EApp (EApp (EVar "constrCanon") (EVar "tvs")) (EVar "rvs"))) (EVar "cs")))))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EApp (EApp (EVar "tyCanonIn") (EVar "tvs")) (EVar "rvs")) (EVar "t")))) (ELit (LString ")"))))
(DTypeSig false "constrCanon" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Constraint") (TyCon "String")))))
(DFunDef false "constrCanon" ((PVar "tvs") (PVar "rvs") (PRec "Constraint" ((rf "constraintHead" (PVar "h")) (rf "constraintArgs" (PVar "args"))) false)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "[")) (EApp (EVar "display") (EVar "h"))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EVar "map") (EApp (EApp (EVar "tyCanonIn") (EVar "tvs")) (EVar "rvs"))) (EVar "args"))))) (ELit (LString "]"))))
(DTypeSig false "rowCanon" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "EffAtomTy")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))))
(DFunDef false "rowCanon" ((PVar "rvs") (PVar "es") (PVar "tl")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "{")) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EVar "sortUniqS") (EApp (EApp (EVar "map") (EVar "rowAtomCanon")) (EVar "es")))))) (ELit (LString ""))) (EApp (EVar "display") (EApp (EApp (EVar "rowTailCanon") (EVar "rvs")) (EVar "tl")))) (ELit (LString "}"))))
(DTypeSig false "rowAtomCanon" (TyFun (TyCon "EffAtomTy") (TyCon "String")))
(DFunDef false "rowAtomCanon" ((PVar "a")) (EApp (EApp (EVar "effAtomSurface") (EVar "escStr")) (EVar "a")))
(DTypeSig false "rowTailCanon" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))
(DFunDef false "rowTailCanon" ((PVar "rvs") (PVar "tls")) (EApp (EApp (EVar "joinWith") (ELit (LString ""))) (EApp (EApp (EVar "map") (ELam ((PVar "v")) (EBinOp "++" (ELit (LString " |%r")) (EApp (EVar "intToString") (EApp (EApp (EVar "indexIn") (EVar "v")) (EVar "rvs")))))) (EVar "tls"))))
(DTypeSig false "indexIn" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Int"))))
(DFunDef false "indexIn" ((PVar "x") (PVar "xs")) (EApp (EApp (EApp (EVar "indexInGo") (EVar "x")) (EVar "xs")) (ELit (LInt 0))))
(DTypeSig false "indexInGo" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "indexInGo" (PWild (PList) PWild) (EUnOp "-" (ELit (LInt 1))))
(DFunDef false "indexInGo" ((PVar "x") (PCons (PVar "y") (PVar "ys")) (PVar "i")) (EIf (EBinOp "==" (EVar "x") (EVar "y")) (EVar "i") (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "indexInGo") (EVar "x")) (EVar "ys")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Ty" true) (mem "EffAtomTy" true) (mem "effAtomSurface" false) (mem "binderDomainSurface" false) (mem "Constraint" true) (mem "Pat" true) (mem "UsePath" true) (mem "Expr" true) (mem "Decl" true) (mem "qualifierSource" false) (mem "authTermsSurface" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("support" "util") ((mem "escStr" false) (mem "anyList" false) (mem "filterList" false) (mem "reverseL" false) (mem "joinWith" false) (mem "startsWith" false) (mem "endsWith" false) (mem "dedup" false))))
(DUse false (UseGroup ("hash_map") ((mem "HashMap" false) (mem "new" false) (mem "get" false) (mem "setInPlace" false) (mem "has" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fixability" true) (mem "Need" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "mkRule" false) (mem "stdlibEntriesOf" false) (mem "stdlibIndexNames" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "appSpineOf" false) (mem "clausesOf" false) (mem "dedupeNamesLoc" false) (mem "declLocList" false) (mem "lastSegOf" false) (mem "memberLocalIfOrigin" false) (mem "nameSetOf" false) (mem "paramNameOf" false) (mem "ruleNameStdlibReimpl" false) (mem "sortUniqS" false) (mem "stdlibModuleOf" false) (mem "stripELoc" false) (mem "topDefNameL" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameStdlibReimpl")) (fa "summary" (ELit (LString "top-level function reimplements a stdlib function under a different name (same declared signature) (STYLE §7a)"))) (fa "doc" (ELit (LString "A top-level function whose declared signature equals that of an exported stdlib function, and whose body does the same work, reimplements the stdlib under another name. The rule compares against the stdlib signature index. Call the stdlib function.\n\nBefore:\n  sumAll : List Int -> Int\n  sumAll xs = foldl (+) 0 xs\nAfter:\n  use `sum` from the stdlib"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Baselined")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "NotFixable")) (fa "needs" (EListLit (EVar "NeedsStdlibIndex")))))) (EVar "ruleStdlibReimpl")) (EVar "None")))
(DTypeSig false "ruleStdlibReimpl" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "ruleStdlibReimpl" ((PVar "idx") (PVar "path") PWild (PVar "pos") (PVar "prog")) (EBlock (DoLet false false (PVar "ownMod") (EApp (EVar "stdlibModuleOf") (EVar "path"))) (DoLet false false (PVar "names") (EApp (EVar "stdlibIndexNames") (EVar "idx"))) (DoLet false false (PVar "sigs") (EApp (EVar "sigTyMapOf") (EVar "prog"))) (DoLet false false (PVar "locals") (EApp (EVar "nameSetOf") (EApp (EApp (EDictApp "flatMap") (EVar "localTyNamesL")) (EVar "prog")))) (DoExpr (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "reimplHit") (EVar "idx")) (EVar "ownMod")) (EVar "names")) (EVar "sigs")) (EVar "locals")) (EVar "prog"))) (EApp (EVar "dedupeNamesLoc") (EApp (EApp (EDictApp "flatMap") (EVar "topDefNameL")) (EApp (EApp (EVar "declLocList") (EVar "pos")) (EVar "prog"))))))))
(DTypeSig false "localTyNamesL" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "localTyNamesL" ((PRec "DData" ((rf "dataName" (PVar "n"))) false)) (EListLit (EVar "n")))
(DFunDef false "localTyNamesL" ((PRec "DNewtype" ((rf "newtypeName" (PVar "n"))) false)) (EListLit (EVar "n")))
(DFunDef false "localTyNamesL" ((PRec "DTypeAlias" ((rf "tyAliasName" (PVar "n"))) false)) (EListLit (EVar "n")))
(DFunDef false "localTyNamesL" ((PRec "DInterface" ((rf "name" (PVar "n"))) false)) (EListLit (EVar "n")))
(DFunDef false "localTyNamesL" ((PCon "DEffect" PWild (PVar "n") PWild PWild PWild PWild)) (EListLit (EVar "n")))
(DFunDef false "localTyNamesL" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "localTyNamesL") (EVar "d")))
(DFunDef false "localTyNamesL" (PWild) (EListLit))
(DTypeSig false "tyNamesOf" (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "tyNamesOf" ((PCon "TyVar" PWild)) (EListLit))
(DFunDef false "tyNamesOf" ((PRec "TyCon" ((rf "tyConName" (PVar "n"))) false)) (EListLit (EVar "n")))
(DFunDef false "tyNamesOf" ((PCon "TyApp" (PVar "f") (PVar "x"))) (EBinOp "++" (EApp (EVar "tyNamesOf") (EVar "f")) (EApp (EVar "tyNamesOf") (EVar "x"))))
(DFunDef false "tyNamesOf" ((PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EVar "tyNamesOf") (EVar "a")) (EApp (EVar "tyNamesOf") (EVar "b"))))
(DFunDef false "tyNamesOf" ((PCon "TyTuple" (PVar "ts"))) (EApp (EApp (EDictApp "flatMap") (EVar "tyNamesOf")) (EVar "ts")))
(DFunDef false "tyNamesOf" ((PCon "TyEffect" (PVar "es") PWild (PVar "t"))) (EBinOp "++" (EApp (EApp (EMethodRef "map") (EVar "effAtomLabel")) (EVar "es")) (EApp (EVar "tyNamesOf") (EVar "t"))))
(DFunDef false "tyNamesOf" ((PCon "TyRow" (PVar "es") PWild PWild)) (EApp (EApp (EMethodRef "map") (EVar "effAtomLabel")) (EVar "es")))
(DFunDef false "tyNamesOf" ((PCon "TyAuth" PWild PWild)) (EListLit))
(DFunDef false "tyNamesOf" ((PCon "TyConstrained" (PVar "cs") (PVar "t"))) (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EVar "constrTyNames")) (EVar "cs")) (EApp (EVar "tyNamesOf") (EVar "t"))))
(DFunDef false "tyNamesOf" ((PCon "TyNamed" PWild (PVar "t") PWild)) (EApp (EVar "tyNamesOf") (EVar "t")))
(DFunDef false "tyNamesOf" ((PCon "TyQual" (PVar "t") PWild PWild)) (EApp (EVar "tyNamesOf") (EVar "t")))
(DTypeSig false "effAtomLabel" (TyFun (TyCon "EffAtomTy") (TyCon "String")))
(DFunDef false "effAtomLabel" ((PVar "a")) (EFieldAccess (EVar "a") "eatLabel"))
(DTypeSig false "constrTyNames" (TyFun (TyCon "Constraint") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "constrTyNames" ((PRec "Constraint" ((rf "constraintHead" (PVar "h")) (rf "constraintArgs" (PVar "args"))) false)) (EBinOp "::" (EVar "h") (EApp (EApp (EDictApp "flatMap") (EVar "tyNamesOf")) (EVar "args"))))
(DTypeSig false "mentionsLocalTy" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyCon "Ty") (TyCon "Bool"))))
(DFunDef false "mentionsLocalTy" ((PVar "locals") (PVar "ty")) (EApp (EApp (EVar "anyList") (ELam ((PVar "n")) (EApp (EApp (EVar "has") (EVar "n")) (EVar "locals")))) (EApp (EVar "tyNamesOf") (EVar "ty"))))
(DTypeSig false "reimplHit" (TyFun (TyCon "StdlibIndex") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Ty")) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "List") (TyCon "Finding"))))))))))
(DFunDef false "reimplHit" ((PVar "idx") (PVar "ownMod") (PVar "names") (PVar "sigs") (PVar "locals") (PVar "prog") (PTuple (PVar "name") (PVar "loc"))) (EMatch (EApp (EApp (EVar "get") (EVar "name")) (EVar "sigs")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "ty")) () (EIf (EApp (EApp (EVar "mentionsLocalTy") (EVar "locals")) (EVar "ty")) (EListLit) (EMatch (EApp (EApp (EApp (EApp (EVar "firstMatchingExport") (EVar "idx")) (EVar "ownMod")) (EApp (EVar "tyCanon") (EVar "ty"))) (EApp (EApp (EVar "filterList") (EApp (EVar "relaxesOnto") (EVar "name"))) (EVar "names"))) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PTuple (PVar "modName") (PVar "stdName"))) () (EIf (EApp (EApp (EApp (EApp (EVar "isDelegationOf") (EVar "prog")) (EVar "name")) (EVar "modName")) (EVar "stdName")) (EListLit) (EListLit (EApp (EApp (EApp (EApp (EVar "stdlibFinding") (EVar "name")) (EVar "modName")) (EVar "stdName")) (EVar "loc"))))))))))
(DTypeSig false "isDelegationOf" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))))
(DFunDef false "isDelegationOf" ((PVar "prog") (PVar "name") (PVar "modName") (PVar "stdName")) (EMatch (EApp (EApp (EApp (EVar "localNameForStdlib") (EVar "prog")) (EVar "modName")) (EVar "stdName")) (arm (PCon "None") () (EVar "False")) (arm (PCon "Some" (PVar "local")) () (EMatch (EApp (EApp (EVar "soleClauseOf") (EVar "name")) (EVar "prog")) (arm (PCon "None") () (EVar "False")) (arm (PCon "Some" (PTuple (PVar "ps") (PVar "body"))) () (EApp (EApp (EApp (EVar "forwardsParams") (EVar "local")) (EVar "ps")) (EVar "body")))))))
(DTypeSig false "soleClauseOf" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))))))
(DFunDef false "soleClauseOf" ((PVar "name") (PVar "prog")) (EMatch (EApp (EApp (EVar "clausesOf") (EVar "name")) (EVar "prog")) (arm (PList (PVar "one")) () (EApp (EVar "Some") (EVar "one"))) (arm PWild () (EVar "None"))))
(DTypeSig false "forwardsParams" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Expr") (TyCon "Bool")))))
(DFunDef false "forwardsParams" ((PVar "local") (PList) (PVar "body")) (EMatch (EApp (EVar "stripELoc") (EVar "body")) (arm (PCon "EVar" (PVar "n")) () (EBinOp "==" (EVar "n") (EVar "local"))) (arm PWild () (EVar "False"))))
(DFunDef false "forwardsParams" ((PVar "local") (PVar "ps") (PVar "body")) (EBlock (DoLet false false (PTuple (PVar "headE") (PVar "args")) (EApp (EVar "appSpineOf") (EVar "body"))) (DoExpr (EMatch (EVar "headE") (arm (PCon "EVar" (PVar "n")) () (EBinOp "&&" (EBinOp "==" (EVar "n") (EVar "local")) (EApp (EApp (EVar "paramsMatchArgs") (EVar "ps")) (EVar "args")))) (arm PWild () (EVar "False"))))))
(DTypeSig false "paramsMatchArgs" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyCon "Bool"))))
(DFunDef false "paramsMatchArgs" ((PVar "ps") (PVar "args")) (EMatch (ETuple (EApp (EVar "allSome") (EApp (EVar "paramNamesOf") (EVar "ps"))) (EApp (EVar "allSome") (EApp (EVar "argNamesOf") (EVar "args")))) (arm (PTuple (PCon "Some" (PVar "pns")) (PCon "Some" (PVar "ans"))) () (EBinOp "==" (EVar "pns") (EVar "ans"))) (arm PWild () (EVar "False"))))
(DTypeSig false "allSome" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "String"))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "allSome" ((PList)) (EApp (EVar "Some") (EListLit)))
(DFunDef false "allSome" ((PCons (PCon "None") PWild)) (EVar "None"))
(DFunDef false "allSome" ((PCons (PCon "Some" (PVar "x")) (PVar "rest"))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "_s")) (EBinOp "::" (EVar "x") (EVar "_s")))) (EApp (EVar "allSome") (EVar "rest"))))
(DTypeSig false "paramNamesOf" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "paramNamesOf" ((PVar "ps")) (EApp (EApp (EMethodRef "map") (EVar "paramNameOf")) (EVar "ps")))
(DTypeSig false "argNamesOf" (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "argNamesOf" ((PVar "args")) (EApp (EApp (EMethodRef "map") (EVar "argNameOf")) (EVar "args")))
(DTypeSig false "argNameOf" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "argNameOf" ((PVar "e")) (EMatch (EApp (EVar "stripELoc") (EVar "e")) (arm (PCon "EVar" (PVar "n")) () (EApp (EVar "Some") (EVar "n"))) (arm PWild () (EVar "None"))))
(DTypeSig false "localNameForStdlib" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "localNameForStdlib" ((PVar "prog") (PVar "modName") (PVar "stdName")) (EApp (EApp (EVar "firstJustL") (EApp (EApp (EVar "localNameForStdlibInDecl") (EVar "modName")) (EVar "stdName"))) (EVar "prog")))
(DTypeSig false "firstJustL" (TyFun (TyFun (TyVar "a") (TyApp (TyCon "Option") (TyVar "b"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "Option") (TyVar "b")))))
(DFunDef false "firstJustL" (PWild (PList)) (EVar "None"))
(DFunDef false "firstJustL" ((PVar "f") (PCons (PVar "x") (PVar "rest"))) (EMatch (EApp (EVar "f") (EVar "x")) (arm (PCon "Some" (PVar "y")) () (EApp (EVar "Some") (EVar "y"))) (arm (PCon "None") () (EApp (EApp (EVar "firstJustL") (EVar "f")) (EVar "rest")))))
(DTypeSig false "localNameForStdlibInDecl" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "localNameForStdlibInDecl" ((PVar "modName") (PVar "stdName") (PCon "DUse" PWild (PVar "path") PWild)) (EApp (EApp (EApp (EVar "localNameForStdlibInPath") (EVar "modName")) (EVar "stdName")) (EVar "path")))
(DFunDef false "localNameForStdlibInDecl" ((PVar "modName") (PVar "stdName") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EApp (EVar "localNameForStdlibInDecl") (EVar "modName")) (EVar "stdName")) (EVar "d")))
(DFunDef false "localNameForStdlibInDecl" (PWild PWild PWild) (EVar "None"))
(DTypeSig false "localNameForStdlibInPath" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "UsePath") (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "localNameForStdlibInPath" ((PVar "modName") (PVar "stdName") (PCon "UseGroup" (PVar "path") (PVar "members"))) (EIf (EBinOp "==" (EApp (EVar "lastSegOf") (EVar "path")) (EVar "modName")) (EApp (EApp (EVar "firstJustL") (EApp (EVar "memberLocalIfOrigin") (EVar "stdName"))) (EVar "members")) (EVar "None")))
(DFunDef false "localNameForStdlibInPath" ((PVar "modName") (PVar "stdName") (PCon "UseWild" (PVar "path"))) (EIf (EBinOp "==" (EApp (EVar "lastSegOf") (EVar "path")) (EVar "modName")) (EApp (EVar "Some") (EVar "stdName")) (EVar "None")))
(DFunDef false "localNameForStdlibInPath" (PWild PWild PWild) (EVar "None"))
(DTypeSig false "relaxesOnto" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "relaxesOnto" ((PVar "user") (PVar "std")) (EBlock (DoLet false false (PVar "s") (EApp (EVar "stringToLower") (EVar "std"))) (DoLet false false (PVar "u") (EApp (EVar "stringToLower") (EVar "user"))) (DoExpr (EBinOp "&&" (EBinOp ">=" (EApp (EVar "stringLength") (EVar "s")) (ELit (LInt 4))) (EBinOp "||" (EApp (EApp (EVar "startsWith") (EVar "s")) (EVar "u")) (EApp (EApp (EVar "endsWith") (EVar "s")) (EVar "u")))))))
(DTypeSig false "firstMatchingExport" (TyFun (TyCon "StdlibIndex") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String"))))))))
(DFunDef false "firstMatchingExport" (PWild PWild PWild (PList)) (EVar "None"))
(DFunDef false "firstMatchingExport" ((PVar "idx") (PVar "ownMod") (PVar "canon") (PCons (PVar "std") (PVar "rest"))) (EMatch (EApp (EApp (EApp (EVar "firstMatchingModule") (EVar "ownMod")) (EVar "canon")) (EApp (EApp (EVar "stdlibEntriesOf") (EVar "idx")) (EVar "std"))) (arm (PCon "Some" (PVar "modName")) () (EApp (EVar "Some") (ETuple (EVar "modName") (EVar "std")))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "firstMatchingExport") (EVar "idx")) (EVar "ownMod")) (EVar "canon")) (EVar "rest")))))
(DTypeSig false "firstMatchingModule" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "firstMatchingModule" (PWild PWild (PList)) (EVar "None"))
(DFunDef false "firstMatchingModule" ((PVar "ownMod") (PVar "canon") (PCons (PTuple (PVar "modName") (PVar "ty")) (PVar "rest"))) (EIf (EApp (EApp (EVar "ownsModule") (EVar "ownMod")) (EVar "modName")) (EApp (EApp (EApp (EVar "firstMatchingModule") (EVar "ownMod")) (EVar "canon")) (EVar "rest")) (EIf (EBinOp "==" (EApp (EVar "tyCanon") (EVar "ty")) (EVar "canon")) (EApp (EVar "Some") (EVar "modName")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "firstMatchingModule") (EVar "ownMod")) (EVar "canon")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "ownsModule" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "ownsModule" ((PCon "None") PWild) (EVar "False"))
(DFunDef false "ownsModule" ((PCon "Some" (PVar "own")) (PVar "modName")) (EBinOp "==" (EVar "modName") (EVar "own")))
(DTypeSig false "sigTyMapOf" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Ty"))))
(DFunDef false "sigTyMapOf" ((PVar "prog")) (EBlock (DoLet false false (PVar "m") (EApp (EVar "new") (ELit LUnit))) (DoExpr (EApp (EApp (EVar "sigTyInto") (EApp (EVar "reverseL") (EApp (EApp (EDictApp "flatMap") (EVar "topSigPairL")) (EVar "prog")))) (EVar "m"))) (DoExpr (EVar "m"))))
(DTypeSig false "sigTyInto" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Ty")) (TyCon "Unit"))))
(DFunDef false "sigTyInto" ((PList) PWild) (ELit LUnit))
(DFunDef false "sigTyInto" ((PCons (PTuple (PVar "n") (PVar "t")) (PVar "rest")) (PVar "m")) (EBlock (DoExpr (EApp (EApp (EApp (EVar "setInPlace") (EVar "n")) (EVar "t")) (EVar "m"))) (DoExpr (EApp (EApp (EVar "sigTyInto") (EVar "rest")) (EVar "m")))))
(DTypeSig false "topSigPairL" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty")))))
(DFunDef false "topSigPairL" ((PCon "DTypeSig" PWild (PVar "name") (PVar "ty") PWild)) (EListLit (ETuple (EVar "name") (EVar "ty"))))
(DFunDef false "topSigPairL" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "topSigPairL") (EVar "d")))
(DFunDef false "topSigPairL" (PWild) (EListLit))
(DTypeSig false "stdlibFinding" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Finding"))))))
(DFunDef false "stdlibFinding" ((PVar "name") (PVar "modName") (PVar "stdName") (PVar "loc")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameStdlibReimpl")) (fa "message" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "top-level '")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "' reimplements stdlib '"))) (EApp (EMethodRef "display") (EVar "modName"))) (ELit (LString "."))) (EApp (EMethodRef "display") (EVar "stdName"))) (ELit (LString "' (same declared signature) — use the stdlib version")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")) (fa "fix" (EVar "None")))))
(DTypeSig false "tyCanon" (TyFun (TyCon "Ty") (TyCon "String")))
(DFunDef false "tyCanon" ((PVar "t")) (EApp (EApp (EApp (EVar "tyCanonIn") (EApp (EVar "dedup") (EApp (EVar "tyVarsOf") (EVar "t")))) (EApp (EVar "dedup") (EApp (EVar "rowVarsOf") (EVar "t")))) (EVar "t")))
(DTypeSig false "tyVarsOf" (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "tyVarsOf" ((PCon "TyVar" (PVar "v"))) (EListLit (EVar "v")))
(DFunDef false "tyVarsOf" ((PRec "TyCon" ((rf "tyConName" PWild)) false)) (EListLit))
(DFunDef false "tyVarsOf" ((PCon "TyApp" (PVar "f") (PVar "x"))) (EBinOp "++" (EApp (EVar "tyVarsOf") (EVar "f")) (EApp (EVar "tyVarsOf") (EVar "x"))))
(DFunDef false "tyVarsOf" ((PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EVar "tyVarsOf") (EVar "a")) (EApp (EVar "tyVarsOf") (EVar "b"))))
(DFunDef false "tyVarsOf" ((PCon "TyTuple" (PVar "ts"))) (EApp (EApp (EDictApp "flatMap") (EVar "tyVarsOf")) (EVar "ts")))
(DFunDef false "tyVarsOf" ((PCon "TyEffect" PWild PWild (PVar "t"))) (EApp (EVar "tyVarsOf") (EVar "t")))
(DFunDef false "tyVarsOf" ((PCon "TyConstrained" (PVar "cs") (PVar "t"))) (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EVar "constrTyVars")) (EVar "cs")) (EApp (EVar "tyVarsOf") (EVar "t"))))
(DFunDef false "tyVarsOf" ((PCon "TyRow" PWild PWild PWild)) (EListLit))
(DFunDef false "tyVarsOf" ((PCon "TyAuth" PWild PWild)) (EListLit))
(DFunDef false "tyVarsOf" ((PCon "TyNamed" PWild (PVar "t") PWild)) (EApp (EVar "tyVarsOf") (EVar "t")))
(DFunDef false "tyVarsOf" ((PCon "TyQual" (PVar "t") PWild PWild)) (EApp (EVar "tyVarsOf") (EVar "t")))
(DTypeSig false "constrTyVars" (TyFun (TyCon "Constraint") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "constrTyVars" ((PRec "Constraint" ((rf "constraintArgs" (PVar "args"))) false)) (EApp (EApp (EDictApp "flatMap") (EVar "tyVarsOf")) (EVar "args")))
(DTypeSig false "rowVarsOf" (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "rowVarsOf" ((PCon "TyVar" PWild)) (EListLit))
(DFunDef false "rowVarsOf" ((PRec "TyCon" ((rf "tyConName" PWild)) false)) (EListLit))
(DFunDef false "rowVarsOf" ((PCon "TyApp" (PVar "f") (PVar "x"))) (EBinOp "++" (EApp (EVar "rowVarsOf") (EVar "f")) (EApp (EVar "rowVarsOf") (EVar "x"))))
(DFunDef false "rowVarsOf" ((PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EVar "rowVarsOf") (EVar "a")) (EApp (EVar "rowVarsOf") (EVar "b"))))
(DFunDef false "rowVarsOf" ((PCon "TyTuple" (PVar "ts"))) (EApp (EApp (EDictApp "flatMap") (EVar "rowVarsOf")) (EVar "ts")))
(DFunDef false "rowVarsOf" ((PCon "TyEffect" PWild (PVar "tl") (PVar "t"))) (EBinOp "++" (EVar "tl") (EApp (EVar "rowVarsOf") (EVar "t"))))
(DFunDef false "rowVarsOf" ((PCon "TyConstrained" (PVar "cs") (PVar "t"))) (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EVar "constrRowVars")) (EVar "cs")) (EApp (EVar "rowVarsOf") (EVar "t"))))
(DFunDef false "rowVarsOf" ((PCon "TyRow" PWild (PVar "tl") PWild)) (EVar "tl"))
(DFunDef false "rowVarsOf" ((PCon "TyAuth" PWild PWild)) (EListLit))
(DFunDef false "rowVarsOf" ((PCon "TyNamed" PWild (PVar "t") PWild)) (EApp (EVar "rowVarsOf") (EVar "t")))
(DFunDef false "rowVarsOf" ((PCon "TyQual" (PVar "t") PWild PWild)) (EApp (EVar "rowVarsOf") (EVar "t")))
(DTypeSig false "constrRowVars" (TyFun (TyCon "Constraint") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "constrRowVars" ((PRec "Constraint" ((rf "constraintArgs" (PVar "args"))) false)) (EApp (EApp (EDictApp "flatMap") (EVar "rowVarsOf")) (EVar "args")))
(DTypeSig false "tyCanonIn" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Ty") (TyCon "String")))))
(DFunDef false "tyCanonIn" ((PVar "tvs") PWild (PCon "TyVar" (PVar "v"))) (EBinOp "++" (ELit (LString "%t")) (EApp (EVar "intToString") (EApp (EApp (EVar "indexIn") (EVar "v")) (EVar "tvs")))))
(DFunDef false "tyCanonIn" (PWild PWild (PRec "TyCon" ((rf "tyConName" (PVar "n"))) false)) (EBinOp "++" (ELit (LString "#")) (EVar "n")))
(DFunDef false "tyCanonIn" ((PVar "tvs") (PVar "rvs") (PCon "TyApp" (PVar "f") (PVar "x"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(@ ")) (EApp (EMethodRef "display") (EApp (EApp (EApp (EVar "tyCanonIn") (EVar "tvs")) (EVar "rvs")) (EVar "f")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EApp (EApp (EVar "tyCanonIn") (EVar "tvs")) (EVar "rvs")) (EVar "x")))) (ELit (LString ")"))))
(DFunDef false "tyCanonIn" ((PVar "tvs") (PVar "rvs") (PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(-> ")) (EApp (EMethodRef "display") (EApp (EApp (EApp (EVar "tyCanonIn") (EVar "tvs")) (EVar "rvs")) (EVar "a")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EApp (EApp (EVar "tyCanonIn") (EVar "tvs")) (EVar "rvs")) (EVar "b")))) (ELit (LString ")"))))
(DFunDef false "tyCanonIn" ((PVar "tvs") (PVar "rvs") (PCon "TyTuple" (PVar "ts"))) (EBinOp "++" (EBinOp "++" (ELit (LString "(, ")) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "tyCanonIn") (EVar "tvs")) (EVar "rvs"))) (EVar "ts"))))) (ELit (LString ")"))))
(DFunDef false "tyCanonIn" ((PVar "tvs") (PVar "rvs") (PCon "TyEffect" (PVar "es") (PVar "tl") (PVar "t"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(eff ")) (EApp (EMethodRef "display") (EApp (EApp (EApp (EVar "rowCanon") (EVar "rvs")) (EVar "es")) (EVar "tl")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EApp (EApp (EVar "tyCanonIn") (EVar "tvs")) (EVar "rvs")) (EVar "t")))) (ELit (LString ")"))))
(DFunDef false "tyCanonIn" (PWild (PVar "rvs") (PCon "TyRow" (PVar "es") (PVar "tl") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "(row ")) (EApp (EApp (EApp (EVar "rowCanon") (EVar "rvs")) (EVar "es")) (EVar "tl"))) (ELit (LString ")"))))
(DFunDef false "tyCanonIn" (PWild PWild (PCon "TyAuth" (PVar "ps") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "(auth ")) (EApp (EApp (EVar "authTermsSurface") (EVar "escStr")) (EVar "ps"))) (ELit (LString ")"))))
(DFunDef false "tyCanonIn" ((PVar "tvs") (PVar "rvs") (PCon "TyNamed" (PVar "n") (PVar "t") (PVar "d"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(named ")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EApp (EApp (EVar "tyCanonIn") (EVar "tvs")) (EVar "rvs")) (EVar "t")))) (ELit (LString ""))) (EApp (EMethodRef "display") (EApp (EVar "binderDomainSurface") (EVar "d")))) (ELit (LString ")"))))
(DFunDef false "tyCanonIn" ((PVar "tvs") (PVar "rvs") (PCon "TyQual" (PVar "t") (PVar "ns") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(qual ")) (EApp (EMethodRef "display") (EApp (EApp (EApp (EVar "tyCanonIn") (EVar "tvs")) (EVar "rvs")) (EVar "t")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "qualifierSource") (EVar "escStr")) (EVar "ns")))) (ELit (LString ")"))))
(DFunDef false "tyCanonIn" ((PVar "tvs") (PVar "rvs") (PCon "TyConstrained" (PVar "cs") (PVar "t"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(=> ")) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EVar "sortUniqS") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "constrCanon") (EVar "tvs")) (EVar "rvs"))) (EVar "cs")))))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EApp (EApp (EVar "tyCanonIn") (EVar "tvs")) (EVar "rvs")) (EVar "t")))) (ELit (LString ")"))))
(DTypeSig false "constrCanon" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Constraint") (TyCon "String")))))
(DFunDef false "constrCanon" ((PVar "tvs") (PVar "rvs") (PRec "Constraint" ((rf "constraintHead" (PVar "h")) (rf "constraintArgs" (PVar "args"))) false)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "[")) (EApp (EMethodRef "display") (EVar "h"))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "tyCanonIn") (EVar "tvs")) (EVar "rvs"))) (EVar "args"))))) (ELit (LString "]"))))
(DTypeSig false "rowCanon" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "EffAtomTy")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))))
(DFunDef false "rowCanon" ((PVar "rvs") (PVar "es") (PVar "tl")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "{")) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EVar "sortUniqS") (EApp (EApp (EMethodRef "map") (EVar "rowAtomCanon")) (EVar "es")))))) (ELit (LString ""))) (EApp (EMethodRef "display") (EApp (EApp (EVar "rowTailCanon") (EVar "rvs")) (EVar "tl")))) (ELit (LString "}"))))
(DTypeSig false "rowAtomCanon" (TyFun (TyCon "EffAtomTy") (TyCon "String")))
(DFunDef false "rowAtomCanon" ((PVar "a")) (EApp (EApp (EVar "effAtomSurface") (EVar "escStr")) (EVar "a")))
(DTypeSig false "rowTailCanon" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))
(DFunDef false "rowTailCanon" ((PVar "rvs") (PVar "tls")) (EApp (EApp (EVar "joinWith") (ELit (LString ""))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "v")) (EBinOp "++" (ELit (LString " |%r")) (EApp (EVar "intToString") (EApp (EApp (EVar "indexIn") (EVar "v")) (EVar "rvs")))))) (EVar "tls"))))
(DTypeSig false "indexIn" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Int"))))
(DFunDef false "indexIn" ((PVar "x") (PVar "xs")) (EApp (EApp (EApp (EVar "indexInGo") (EVar "x")) (EVar "xs")) (ELit (LInt 0))))
(DTypeSig false "indexInGo" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "indexInGo" (PWild (PList) PWild) (EUnOp "-" (ELit (LInt 1))))
(DFunDef false "indexInGo" ((PVar "x") (PCons (PVar "y") (PVar "ys")) (PVar "i")) (EIf (EBinOp "==" (EVar "x") (EVar "y")) (EVar "i") (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "indexInGo") (EVar "x")) (EVar "ys")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
