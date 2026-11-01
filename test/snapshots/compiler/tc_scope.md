# META
source_lines=1774
stages=DESUGAR,MARK
# SOURCE
-- tc_scope: name visibility across imports, read off the envelopes: the method-scope ladder (the
-- own, imported and undecided rungs, admission, the method scheme rows it selects
-- (`pickSchemesByDecl`, `admittedRowFor`, `admittedSchemeFor`, `undecidedSchemeFor`,
-- `annotateImportedMethodRows`), the dispatch-index and impl-existence reads scoped by it), the
-- ctor and record scoped views (candidates, overrides, scoped entries), the interface rows an import
-- makes visible (`importedIfaceRows`), and the alias-qualified
-- supply (`import m as A` rows, keys, spellings, ambiguity message, dictionary names and constraint
-- entries).
--
-- Spec: SHADOW section 1.0, S1-NS, S2-DECL; language-design Module System, Import Details; SYNTAX
-- Import aliasing.
--
-- Placement: declarations are placed by R1-R6 of the Phase 4 module table,
-- compiler/ARCHITECTURE-PLAYBOOK.md section 6.
-- Closure rule: this module may not import `types.typecheck`, nor any of `tc_unify`,
-- `tc_decls_variance`, `tc_decls_types`, `tc_decls`, `tc_foreign`, `tc_solve_givens`,
-- `tc_solve_entail`, `tc_solve`, `tc_solve_check`, `tc_shadow`, `tc_effects`, `tc_occurrence`,
-- `tc_groups`, `tc_pat`, `tc_infer_records`, `tc_infer`, `tc_elab`, `tc_global`, `tc_module`.

import support.diag_codes.{DiagCode(..)}
import types.tc_types.{
  AbsorptionEvent(..),
  MethodScope(..),
  Predicate(..),
  UObligation(..),
  Windowed(..),
  DeclEnvs,
  EnvBinding,
  GraphCtx,
  ImplEnv,
  Kind,
  MethodEntry,
  MethodEnv,
  MethodRow,
  MethodSchemeRow,
  ModuleCtx,
  RecordInfo,
  TcEnv,
}
import types.tc_mono.{locEq}
import types.tc_env.{
  addCtor,
  ctorExportsIndex,
  declEnvVisibleAt,
  declTopFnNames,
  extendMethodRow,
  graphAmbigValues,
  graphPubDefiners,
  ieImplExistsForHeadOf,
  ifaceMethodNames,
  importedBindings,
  importTableMid,
  lookupBinding,
  lookupCtor,
  lookupIdxById,
  lookupMethodRowById,
  lookupRecordByName,
  lookupSchemeById,
  methodEnvBinding,
  methodExportsIndex,
  methodPreludeRow,
  methodRowById,
  methodRowCanCarry,
  methodRowCand,
  methodRowIface,
  namesToSet,
  ordinaryEnvBinding,
  originMethodName,
  recordCandInfo,
  variantNamed,
  selectIfaceRows,
}
import types.tc_diag.{pushTypeErrorHelpFixAt, pushTypeErrorOnceAt}
import types.tc_diag_text.{ambigReexportHelp, ambigReexportMsg, backticked}
import frontend.ast.{
  ConPayload(..),
  Decl(..),
  Ident(..),
  Loc(..),
  Ns(..),
  Ty(..),
  TyConOrigin(..),
  UseMember(..),
  UsePath(..),
  Variant(..),
  ifaceIdentity,
  mkIdent,
  qualifiedLocal,
  useMemberAlias,
  useMemberLocal,
  useMemberOrigin,
}
import types.repr.{IfaceRef(..), Scheme(..), VecObl(..)}
import support.util.{
  anyList,
  contains,
  dedup,
  filterList,
  isEmptyL,
  isNonEmptyL,
  joinDot,
  joinWith,
  listLen,
  lookupAssoc,
  sortUniqS,
}
import string.{endsWith}
import types.registry.{
  HeadKey(..), Registry, spCollided, SpellingPop, spInsert, spRows
}
import support.ordmap.{
  omEmpty, omFromNames, omHasKey, omInsert, omKeys, omLookup, OrdMap
}
import types.disposition.{MethodDisposition(..)}
import types.route_key.{ifaceWordOf}
import types.solver_contract.{Wanted(..)}
import frontend.visibility.{useModId}

-- Canonical order for an admitted set: `(originModule, name)` — §8 I4's own identity
-- pair, rendered through `ifaceIdentity` so an unstamped declaration sorts by its bare
-- name rather than colliding with every other unstamped one.
export
ifaceSortKey : IfaceRef -> String
ifaceSortKey ir = "\{ifaceIdentity ir.irOrigin ir.irName}|\{ir.irName}"

export
sortIfaceRefs : List IfaceRef -> List IfaceRef
sortIfaceRefs xs = sortIfaceRefsGo xs []

sortIfaceRefsGo : List IfaceRef -> List IfaceRef -> List IfaceRef
sortIfaceRefsGo [] acc = acc
sortIfaceRefsGo (x :: xs) acc = sortIfaceRefsGo xs (sortInsertIfaceRef x acc)

sortInsertIfaceRef : IfaceRef -> List IfaceRef -> List IfaceRef
sortInsertIfaceRef x [] = [x]
-- no dedup arm.  Two declarations with an ABSENT origin render the same sort key
-- (`ifaceIdentity` maps absence to `""`), and dropping one would silently shrink the
-- admitted set — S2-DECL (d) decides BY CARDINALITY, so a merge here is a verdict
-- change.  Sorting is all this does.
sortInsertIfaceRef x (y :: ys)
  | ifaceSortKey x < ifaceSortKey y = x :: y :: ys
  | otherwise = y :: sortInsertIfaceRef x ys

-- This module's own interface declaring [n], as an identity.
ownMethodIdent : List Decl -> String -> Option Ident
ownMethodIdent [] _ = None
ownMethodIdent ((DAttrib _ d) :: rest) n = match ownMethodIdent [d] n
  Some i => Some i
  None => ownMethodIdent rest n
ownMethodIdent ((DInterface { methods, ifaceOrigin, ... }) :: rest) n =
  if contains n (ifaceMethodNames methods) then
    mkIdent NsMethod ifaceOrigin n
  else
    ownMethodIdent rest n
ownMethodIdent (_ :: rest) n = ownMethodIdent rest n

-- The MEMBER filter combined with the `depExportsMethodIdent` identity conjunct
-- prevents #1275 bystander cases: a same-named interface in another module is refused
-- because its spelling passes the member filter but its `Ident` does not appear in
-- `dep`'s export row. `[wide]` is False at `methodScopeAt`'s rung 1
-- (method-name imports decide when they say anything) and True only at rung 2, where
-- rung 1 admitted nothing. See the ladder argument at `methodScopeAt`, and
-- docs/spec/DICT-SEMANTICS.md § "8. Identity, arity, and cross-module elaboration"
-- (I8) for why widening this filter is safe while deciding a declaration by spelling
-- is not.
usePathAdmitsDecl : UsePath -> Bool -> String -> IfaceRef -> Bool
usePathAdmitsDecl path wide n iface =
  usePathBindsName path n || wide && usePathBindsName path iface.irName

-- `None` from importedBindings is the WILDCARD form (`import m.*`), which binds every
-- name the dependency exports — and that is safe: the export test above still admits only
-- the declarations the dependency really provides.  `UseAlias` yields `Some []` and so witnesses
-- nothing — see the #1276 paragraph above for why that is a different defect rather than this
-- one's residue.
usePathBindsName : UsePath -> String -> Bool
usePathBindsName path n = match importedBindings path
  None => True
  Some bs => contains n (map snd bs)

-- Monomorphic and short-circuiting on purpose (`compiler/AGENTS.md`): this runs only for
-- a COLLIDED method name, but when it runs it walks one module's exported-method list.
exportsIdentFor : String -> Ident -> List (String, Ident) -> Bool
exportsIdentFor _ _ [] = False
exportsIdentFor n ident ((en, ei) :: rest)
  | en == n && ei == ident = True
  | otherwise = exportsIdentFor n ident rest

-- resolve one imported bare member name to its actual key in a dependency's public
-- schemes.  The golden path keys schemes by the bare name; the EMIT path runs after
-- universal mangling (types.private_mangle), which rewrites a definition `member`
-- to `<dep>__member` but leaves the importer's `DUse` member name BARE — so the key
-- is the SUFFIX-matching scheme `…__member` (uniquely identified within THIS dep's
-- own schemes; distinct members never share an `__<name>` suffix).  Try the bare
-- key first (golden), then the `__<name>` suffix (mangled emit path).
memberSuffix : String -> String
memberSuffix n = "__" ++ n

-- Look the member up by its ORIGIN name, bind it under its LOCAL name.  Without an
-- alias the two coincide and this is the historical behaviour.
--
-- On the MANGLED emit path the bare origin is absent (the dep's keys are `<dep>__name`)
-- AND the reference in this module's body has itself been mangled to `<dep>__name` by
-- types/private_mangle — so the suffix-matched entries are passed through under their
-- MANGLED keys, which is exactly the key the mangled reference will look up.  (A member
-- alias is erased by the same mangling, so it needs no rebinding there.)
-- PAYLOAD-GENERIC on purpose (RUN-XMOD-062).  This is the member-resolution half of the
-- ONE admission predicate — "which of a dependency's exported rows does this import form
-- admit, and under which local key" — and it is shared by every consumer of that
-- question rather than re-derived per payload.  Its callers today carry `Scheme`
-- payloads (`importFormSchemes`) and `(definer module, origin name)` payloads
-- (`importDefinersOf`); nothing in the body inspects the payload.
export
resolveMemberRows : (String, String) -> List (String, a) -> List (String, a)
resolveMemberRows (origin, local) depRows = match lookupAssoc origin depRows
  Some s => [(local, s)]
  None => filter (kv => endsWith (memberSuffix origin) (fst kv)) depRows

-- ── THE admission predicate for VALUES, payload-generic (RUN-XMOD-062) ─────────
-- "What does this import form admit out of a dependency's exported rows?", answered
-- ONCE for every caller that asks it.  The forms live in `importedBindings` (wildcard /
-- member list / bare-or-dotted / module alias) and are resolved here; the ALIAS arm is
-- deliberately not special-cased here, because what `A.name` re-keying means is
-- payload-specific — each caller handles `UseAlias` before delegating (see
-- `importFormSchemes`, which routes it to `aliasSchemes`).
--
-- A caller must not re-enumerate the forms.  Three consecutive repairs to the
-- dict-arity identity seam (#1425 F1 and its two relocations) each scoped their fix by
-- enumerating import forms by hand, and each enumeration missed a member the next
-- review found — wildcard, then selective re-export, then wildcard re-export.  Routing
-- through this function makes "did we cover every form" a property of ONE definition
-- instead of a hope: a form added to `importedBindings` reaches every caller by
-- construction.  `selectIfaceRows`/`narrowRowToNamed` are the same predicate for
-- interface ROWS (a row is a name plus a list of methods, so its narrowing is
-- per-method rather than per-key) — deliberate mirrors; move them in lockstep.
export
importFormRows : UsePath -> List (String, a) -> List (String, a)
importFormRows path depRows = match importedBindings path
  None => depRows
  Some bindings => flatMap (b => resolveMemberRows b depRows) bindings

-- The declarations of [n] visible at ordinal [cur], in ordinal order.
methodCandsAt : String -> Int -> MethodEnv -> List MethodRow
methodCandsAt n cur env =
  filterList
    (r => declEnvVisibleAt cur r.mrOrd)
    (optionOr [] (omLookup n env.meByName))

-- Is [n] the spelling of an interface method some module at or before ordinal [cur]
-- declares, whatever its export or `pub`?  The membership test S1's shadow builders
-- take (`definerShadowsFromSet`, `standaloneShadowsFromSet`): a point query on the
-- whole-graph table, so no per-module set is ever built.
export
methodNameDeclaredAt : Int -> MethodEnv -> String -> Bool
methodNameDeclaredAt cur env n = isNonEmptyL (methodCandsAt n cur env)

-- The nearest-scope-wins ladder `tyOriginScope` (`frontend/resolve.mdk`) argues for
-- the TYPE namespace, run once per (module, spelling) and only when two or more
-- declarations are visible:
--   own    this module's own interface declares [n];
--   rung 1 a use-path that binds the METHOD name and witnesses the declaration;
--   rung 2 only if rung 1 admits nothing: a use-path that names the declaration's
--          INTERFACE and witnesses it (F23, #1351).  Skipped in favour of the
--          prelude's row for a METHOD-BOUND spelling (below);
--   prelude the implicit prelude's declaration, reached only when no rung admitted
--          anything;
--   alias  only without a prelude row: a module alias whose module carries the
--          declaration (`methodAliasedScope`).
-- A rung that admits exactly one declaration decides.  A rung that admits two or more
-- is `MsMany`.  When no rung admits anything, the answer is the prelude's row if it
-- has one, else the alias rung's, else `MsAbsent`: no visible declaration is nameable
-- here.  The ladder never chooses a declaration by its ordinal, which would make the
-- answer a function of module-processing order (S2-DECL (e)); a reader handed `MsMany`
-- must reject the occurrence, not pick a member.  Rungs 1 and 2 read only the imports
-- the source wrote (`writtenImportsOf`): `import m as A` binds no bare method name.
--
-- Rung 1's precedence over rung 2 is grounded in RUN-METHID-116, not S2-DECL (c): a
-- pick is legitimate when the source carries a discriminator, and `import msa.{MA,
-- mth}` beside `import msb.{MB}` names the method on one path only.  A WILDCARD import
-- carries no discriminator yet reaches rung 1 (`usePathBindsName` is True for every
-- name under `UseWild`), so `import msb.*` can make rung 1 admit two and answer
-- `MsMany`; that gap is RUN-METHID-116's and unfixed.
--
-- [standalone] says whether a standalone function binds [n] in this module (an
-- importer or definer shadow, `standaloneValuesRef`).  When none does, the spelling is
-- METHOD-BOUND: resolve bound a bare occurrence of it through this module's own
-- interface, a use-path naming the method (rung 1), or the prelude, and through
-- nothing else, since `import m.{I}` and `import m as A` bind no bare method name.
-- That declaration answers the occurrence (docs/spec/SHADOW-SEMANTICS.md S2-DECL,
-- "a method-bound occurrence"), so a prelude row outranks rung 2 there.  Rung 2 still
-- answers a method-bound spelling with no prelude row: resolve rejects every bare
-- occurrence of it, so only readers that answer no occurrence (an `impl` this module
-- writes, say) see that answer.  A standalone-bound spelling keeps the whole ladder,
-- which is S2-DECL (c)'s admitted set.
methodScopeAt : GraphCtx ->
  Bool ->
  List Decl ->
  String ->
  Int ->
  DeclEnvs ->
  MethodScope
methodScopeAt gctx standalone prog n cur envs =
  match methodCandsAt n cur envs.deMethods
    [] => MsAbsent
    [only] => MsOne only
    cs => methodOwnScope gctx standalone prog n cs

methodOwnScope : GraphCtx ->
  Bool ->
  List Decl ->
  String ->
  List MethodRow ->
  MethodScope
methodOwnScope gctx standalone prog n cs = match ownMethodIdent prog n
  Some ident => match methodRowById ident cs
    Some r => MsOne r
    None => methodImportedScope gctx standalone prog n cs
  None => methodImportedScope gctx standalone prog n cs

methodImportedScope : GraphCtx ->
  Bool ->
  List Decl ->
  String ->
  List MethodRow ->
  MethodScope
methodImportedScope gctx standalone prog0 n cs =
  let prog = writtenImportsOf prog0
  match filterList (r => methodCandImported gctx prog n (methodRowCand r)) cs
    [only] => MsOne only
    [] => match if standalone then None else methodPreludeRow n cs
      Some r => MsOne r
      None =>
        match (filterList
          (r => methodCandAdmitted gctx prog n (methodRowCand r))
          cs)
          [only] => MsOne only
          rung2 => methodUndecided gctx prog n cs rung2
    rung1 => methodUndecided gctx prog n cs rung1

-- [prog] without the method imports `deAliasMethodImports` appends beside each
-- `import m as A`.  That import exists so the elaborated tree has the origin name the
-- alias-qualified spelling resolves to after inference; the source never wrote it, and
-- an alias binds no bare method name (docs/spec/SYNTAX.md § "Import aliasing"), so it
-- must not witness a declaration on rung 1 or 2.  It is recognised by carrying the
-- alias import's own module path and location.
writtenImportsOf : List Decl -> List Decl
writtenImportsOf prog = match aliasImportSites prog
  [] => prog
  sites => filterList (d => not (isAliasMethodImport sites d)) prog

aliasImportSites : List Decl -> List (List String, Loc)
aliasImportSites [] = []
aliasImportSites ((DAttrib _ d) :: rest) =
  aliasImportSites [d] ++ aliasImportSites rest
aliasImportSites ((DUse _ (UseAlias quals _) loc) :: rest) =
  (quals, loc) :: aliasImportSites rest
aliasImportSites (_ :: rest) = aliasImportSites rest

-- Only a `UseGroup` import is ever synthesized, so the final catch-all answering False
-- for every other declaration is exhaustive by construction.
isAliasMethodImport : List (List String, Loc) -> Decl -> Bool
isAliasMethodImport sites (DAttrib _ d) = isAliasMethodImport sites d
isAliasMethodImport sites (DUse _ (UseGroup quals _) loc) =
  anyList (s => fst s == quals && locEq (snd s) loc) sites
isAliasMethodImport _ _ = False

-- No rung decided.  [admitted] is the deciding rung's survivors (zero or two-plus).
methodUndecided : GraphCtx ->
  List Decl ->
  String ->
  List MethodRow ->
  List MethodRow ->
  MethodScope
methodUndecided gctx prog n cs [] = match methodPreludeRow n cs
  Some r => MsOne r
  None => methodAliasedScope gctx prog n cs
methodUndecided _gctx _ _ _ admitted =
  MsMany (sortIfaceRefs (map methodRowIface admitted))

-- The last rung: a declaration reached only through a module alias.  The alias binds
-- no bare name, so it never outranks a written import or the prelude, but S1-NS (a)(ii)
-- still admits its method into S1's operand.  A bare spelling something else binds (an
-- imported or own standalone) therefore reads the aliased declaration here, and S2-DECL
-- takes the receiver argument and the impl query from it.
methodAliasedScope : GraphCtx ->
  List Decl ->
  String ->
  List MethodRow ->
  MethodScope
methodAliasedScope gctx prog n cs =
  let sites = aliasImportSites prog
  match filterList (r => aliasWitnessesMethod gctx sites n r.mrIdent) cs
    [] => MsAbsent
    [only] => MsOne only
    aliased => MsMany (sortIfaceRefs (map methodRowIface aliased))

aliasWitnessesMethod : GraphCtx ->
  List (List String, Loc) ->
  String ->
  Ident ->
  Bool
aliasWitnessesMethod gctx sites n ident =
  anyList
    (s =>
      let dep = joinDot (fst s)
      dep /= "core" && depExportsMethodIdent gctx dep n ident)
    sites

-- THIS module's answer for [n]: the reading module's declarations and ordinal are
-- installed by `checkBodyImpl` (`methodScopeCtxRef`); before that point, and in a
-- `ModuleCtx` no module installed, every spelling is absent.
methodScopeHere : ModuleCtx -> String -> MethodScope
methodScopeHere mctx n = match mctx.mcCells.methodScopeCtxRef.value
  None => MsAbsent
  Some (prog, cur) => match omLookup n mctx.mcCells.methodScopeMemoRef.value
    Some s => s
    None =>
      let s =
        methodScopeAt
          mctx.mcGraph
          (omHasKey n mctx.mcCells.standaloneValuesRef.value)
          prog
          n
          cur
          mctx.mcGraph.declEnvsRef.value
      mctx.mcCells.methodScopeMemoRef :=
        omInsert n s mctx.mcCells.methodScopeMemoRef.value
      s

-- The declaration this module's scope decides for [n], as the payload every
-- single-winner reader consumes: `None` when no declaration is visible, none is
-- nameable, or two or more are admitted (`methodAdmittedHere` holds that set).
-- Alias spellings (`A.mth`, and a member alias's local name) are a separate supply
-- (`aliasQualifiedMethodEntries`), read first: an alias key is a name one of this
-- module's imports binds to that declaration, which is the binding resolve chose.
export
methodEntryHere : ModuleCtx -> String -> Option MethodEntry
methodEntryHere mctx n =
  match omLookup n mctx.mcCells.methodAliasEntriesRef.value
    Some e => Some e
    None => match methodScopeHere mctx n
      MsOne r => Some r.mrEntry
      _ => None

-- The interface of `methodEntryHere`'s declaration.
export
methodIfaceHere : ModuleCtx -> String -> Option IfaceRef
methodIfaceHere mctx n =
  map ((iface, _, _, _) => iface) (methodEntryHere mctx n)

-- The admitted SET for [n] — non-empty ONLY when two or more declarations are
-- admitted, so `[]` means "the single-winner projection is correct here", not
-- "nothing is admitted".
export
methodAdmittedHere : ModuleCtx -> String -> List IfaceRef
methodAdmittedHere mctx n = match methodScopeHere mctx n
  MsMany ifs => ifs
  _ => []

-- The interfaces an impl query about [n] may be answered by: the one declaration the
-- scope decides, or NONE when two or more are admitted.  An impl query is asked about
-- one goal, built from one declaration's receiver position, so no row of the admitted
-- set is answerable for it by the set alone: the union would admit an impl of the
-- other declaration's interface (S2-DECL (b)).  The per-declaration queries S2-DECL (d)
-- asks pass their declaration explicitly (`admittedDeclHits`).  `None` only when this
-- module's scope admits nothing for [n], which `ieRowAdmittedBy` reads as the
-- bare-name answer.
export
methodAdmissionHere : ModuleCtx -> String -> Option (List IfaceRef)
methodAdmissionHere mctx n = match methodIfaceHere mctx n
  Some iface => Some [iface]
  None => if isEmptyL (methodAdmittedHere mctx n) then None else Some []

-- The visible declarations of [n] at the reading module's ordinal, for the
-- alias-qualified supply (`aliasMethodKeyEntry`) and the admitted-set readers.
export
methodVisibleHere : ModuleCtx -> String -> List MethodRow
methodVisibleHere mctx n = match mctx.mcCells.methodScopeCtxRef.value
  None => []
  Some (_, cur) => methodCandsAt n cur mctx.mcGraph.declEnvsRef.value.deMethods

-- C5: the dispatch-arg index of an interface method, from the graph-wide map
-- methodDispatchIdxByIdRef (built by checkModuleFullImpl from every interface decl).
-- Ungated, unlike argDispatchOf — RLocal detection must run on the eval path too.
export
methodDispatchIdx : ModuleCtx -> String -> Option Int
methodDispatchIdx mctx name =
  dispatchIdxScoped mctx name mctx.mcCells.methodDispatchIdxByIdRef.value

-- the dispatch-arg index of an arg-position method, but only when stamping is
-- enabled (the emit path) — off, every EMethodAt is a return-position site.
export
argDispatchOf : ModuleCtx -> String -> Option Int
argDispatchOf mctx name =
  dispatchIdxScoped mctx name mctx.mcGraph.argDispatchIdxByIdRef.value

-- ── the IDENTITY-SCOPED dispatch-index read ─────────────────────────────────────
--
-- Both readers answer "which argument position is dispatch-relevant for the bare name
-- [name]" from the declaration `methodScopeAt` admits for [name] in THIS module, then that
-- declaration's own row out of the identity-keyed table.  It is a LOOKUP, not a second
-- resolver: the resolution happens in `methodScopeAt` (RUN-METHID-056).  A first-match
-- `lookupAssoc` over the decl-walk order of `argDispatchIndices` would not do: when two
-- interfaces declare the same method name at DIFFERENT dispatch indices that order is
-- module-processing order, so import-clause order would decide the RECEIVER ARGUMENT of an
-- occurrence (#1351; measured `idx=0` on three orderings and `idx=1` on the other three,
-- on all three arms).
--
-- Both readers go through ONE accessor on purpose.  `argDispatchOf` has THREE callers
-- (`inferMethodAt`'s return-route decision, `inferDefinerShadowApp`'s arg-stamp push, and
-- `stampWorthyMethod`'s predicate) and `methodDispatchIdx` has one (`recordRLocalSite`).
-- They answer ONE question, so they move as a SET (RUN-METHID-004/093); one shared accessor
-- makes a partial move unrepresentable.
--
-- A miss is `None`, with no fall-back to a bare-name table: that table's first-match
-- answer IS #1351's order-dependence.  `None` never stands in for an index the scope could
-- have supplied:
--
--   * `methodEntryHere` answers from `methodScopeAt`: an entry when the scope decides
--     one declaration, `None` when none is visible or nameable, and `None` when two or
--     more are admitted.  The last case has no single declaration whose index could
--     be the answer, and a bare-name table would only pick one by decl-walk order;
--     an importer-shadow occurrence of such a name reads each admitted declaration's
--     own index instead (`importerDispatchIdxOuter`, `admittedDeclHits`).
--   * `argNames`' consumer is already scoped: `moduleMarkCtx` keeps only
--     `filterList keep argNames` (keep = `nameableIfaceMethodSet` of the module's own
--     decls) for the group marker, so a name this module cannot name is never marked
--     `EMethodAt` and never reaches here.
--   * Measured with the fall-back arm panic-instrumented: across 327 programs
--     (`shadow_fixtures`, `import_order_fixtures`, `must_fail_fixtures`) on `check`,
--     `run` AND `build` — the last being the only path where `argDispatchOf`'s stamping
--     gate is open — plus the compiler's own self-compile, the fall-back arm decided
--     ZERO sites.  `methodIfaceHere` never missed at all; the id-table miss did occur
--     (`fromInt`) and the bare table missed there too, so both spellings answer `None`.
--
-- ── The two fields this reader consumes ──
-- `argDispatchIdxByIdRef` (`GraphCtx`) / `methodDispatchIdxByIdRef` (`ModuleCtx`), keyed
-- `(IfaceRef, method name)`.  The `IfaceRef` half carries `irOrigin`, the module-identity
-- component, so a bare method name shared by two interfaces in different modules gets
-- distinct rows instead of colliding.  They are the ONLY dispatch-index tables.
--
-- Their prose lives HERE, not on the fields, because `data GraphCtx` has the
-- two-line `data X =` / `  | X {` header shape that #829 ([T-PERRUN-COMMENTS])
-- corrupts: a trailing `--` comment on a field survives `fmt --write` only by moving
-- onto a DIFFERENT field, and `fmt --check` does not catch it — measured live at L1,
-- where one `fmt --write` silently relocated two field comments.
--
-- No bare-name dispatch-index table exists.  `argNames` — the one use of such a table that
-- was a NAME SET rather than an index lookup — is a pure local
-- `map fst (argDispatchIndices …)` at both of its sites (`markSetsOf`): the same
-- structural walk, so no third copy of the universe survives.
dispatchIdxScoped : ModuleCtx ->
  String ->
  List ((IfaceRef, String), Int) ->
  Option Int
dispatchIdxScoped mctx name byId = match methodIfaceHere mctx name
  None => None
  Some iface => lookupIdxById iface (originMethodName mctx name) byId

-- The impl-existence test uses graph-global semantics: it ranges over EVERY module of
-- the loaded graph (SHADOW-SEMANTICS.md:226), never filtered by what the querying
-- module can name.
--
-- The three existence reads (`inferShadowApp`, `definerReceiverDispatches`,
-- `resolveRLocalSite`) form ONE scoping decision and must move together: they must
-- name ONE population and ask ONE question. Threading the scope through three call
-- sites would let a future edit give them three, which would let typecheck and the
-- route resolver disagree on whether an impl exists for the same occurrence. The
-- admitted declaration is read HERE, inside the one query, from `name` alone, so
-- `inferShadowApp`, `definerReceiverDispatches` and `resolveRLocalSite` are not edited
-- at all and a partial move is unrepresentable.
--
-- Reaches the DEFINER arm from neither shadow caller: both short-circuit on
-- `isDefinerShadow` first (S2's inversion routes a definer shadow to the standalone
-- unconditionally), so this widening cannot re-erase a user's own top-level function.
--
-- The query is scoped to a DECLARATION (S2-DECL (b), `docs/spec/SHADOW-SEMANTICS.md`):
-- the importer arm's one declaration supplies both the receiver argument and the impl
-- query, which asks *"does an `impl` of THAT interface exist at the receiver's head
-- tycon"* — never merely *"does some impl declaring a method spelled `name` exist at
-- that head"*, which would answer True about an impl of a declaration the module
-- cannot even name (S2-DECL (c)'s non-conformance). The impl universe itself is
-- unchanged (`DICT-SEMANTICS.md` §8 I5): this narrows what the query ASKS, never which
-- modules' instances may answer — `ieHeadRows … env` is still the graph-global bucket,
-- unfiltered.
export
ieImplExistsForHead : ModuleCtx -> ImplEnv -> String -> HeadKey -> Bool
ieImplExistsForHead mctx env name hk =
  -- goal-side key AND the admitted declaration both projected ONCE, here — see
  -- `headTabOf` for why the goal key is hoisted; the `omLookup` is hoisted for the
  -- same reason ([T-PERF-HUNT]: Medaka is strict, so an in-loop projection is rebuilt
  -- once per row).  The scan itself stays the same single linear walk of `ieHeadRows`
  -- with one more conjunct per row — no rescan, no new bucket.
  ieImplExistsForHeadOf mctx env name hk (methodAdmissionHere mctx name)

-- The admission `methodIfaceHere` reads, rendered as the word an impl's dispatch entry carries for its
-- interface (`route_key.ifaceWordOf`, the first field of its canonical route key),
-- so an engine can compare the two with `==`.  `""` for a name this module admits
-- no interface method for.
export
admittedIfaceWord : ModuleCtx -> String -> String
admittedIfaceWord mctx name = match methodIfaceHere mctx name
  Some iface => ifaceWordOf iface.irOrigin iface.irName
  None => ""

-- ── #1386 / #1276: SUPPLY the ALIAS-QUALIFIED method spellings ──────────────────
-- `import m as A` … `A.mth` keeps its `A.mth` spelling all the way through inference,
-- on every driver, so every reader keyed by the OCCURRENCE name misses unless it is
-- supplied.  `recordImplObligation` is one of them, which is why an alias-qualified
-- method call had NO impl obligation recorded at all (#1386, S0 — `check` exits 0 on a
-- program with no matching impl anywhere).
--
-- The remedy is a SUPPLY, not a re-key and not a rewrite: add `A.<method>` → the entry
-- `m`'s OWN declaration identity gives, for every method `m` exports.  Additive against
-- the bare-name scope answer (`methodScopeAt`) — a bare method name can never be spelled
-- with a dot, so no name that already had an answer gets a different one.
--
-- NOT additive against THIS BLOCK'S OWN entries.  Two DIFFERENT modules aliased under the
-- SAME name (`import ifa as A` beside `import ifb as A`) that both export a method spelled
-- `mth` mint the SAME key `A.mth`, and a plain `omInsert` lets the later `import` silently
-- overwrite the earlier one.  MEASURED with such an insert: two interfaces `IA`/`IB` each
-- declaring `mth`, an entry with both aliases and `impl IA Blob` only — with `ifa as A` FIRST the
-- program is REJECTED `No impl of IB for Blob`, and with the two `import … as A` lines SWAPPED
-- (nothing else changed) it is ACCEPTED and prints 1.  Permuting two imports flipped the
-- accept/reject verdict, on `check`, `run` and `build` alike.
--
-- The fix is decided PER KEY, not per insertion: gather every (alias import × exported
-- method) candidate row first, group by the `A.<method>` key, and insert only where all
-- the rows under that key name ONE declaration IDENTITY.  Identity, not module id, is
-- the discriminator — a re-export hop reaches the same declaration through two module
-- ids and is NOT ambiguous.  A key that several distinct declarations claim gets
-- `T-AMBIGUOUS-ALIAS-METHOD` and NO entry at all, so the two orderings agree: both
-- reject, with the same message at the same span, and neither picks a winner.  Rejected
-- at the IMPORT rather than at the occurrence, for the reason `R-DUPLICATE-IFACE-METHOD`
-- (`frontend/resolve.mdk`) is: the ambiguity becomes unrepresentable rather than merely
-- unreported.  That is an acceptance NARROWING — a program carrying the colliding
-- alias pair but never spelling `A.mth` is rejected too.
--
-- NOT a de-aliasing rewrite of the occurrence.  Rewriting `A.mth` to bare `mth` on
-- this path (the other candidate shape) ERASES the very distinction that makes the
-- occurrence decidable: `import fmod.{mth}` beside `import ifacea as A` then makes
-- `A.mth` and `mth` the same name, and the standalone shadow wins — #1386's Repro B,
-- measured to survive that shape unchanged.
export
aliasQualifiedMethodEntries : ModuleCtx ->
  List Decl ->
  OrdMap (IfaceRef, List String, Ty, List (String, List Kind)) ->
  OrdMap (IfaceRef, List String, Ty, List (String, List Kind))
aliasQualifiedMethodEntries mctx prog tab =
  let grouped =
    aliasMethodKeyGroup (aliasMethodKeyCands mctx.mcGraph prog) omEmpty
  aliasMethodKeyApply mctx grouped (omKeys grouped) tab

-- one CANDIDATE row per (alias import × method the aliased module exports):
-- (the local `A.<method>` key, the bare method name, the aliased module id, that
-- method's own declaration identity, the `import … as A` span the row came from).
-- Gathering before inserting is what makes the answer independent of import order.
-- A member alias (`import m.{mth as loc}`) contributes a row the same way, keyed `loc`.
aliasMethodKeyCands : GraphCtx ->
  List Decl ->
  List (String, String, String, Ident, Loc)
aliasMethodKeyCands gctx prog =
  useKeyCands (moduleAliasKeys gctx) prog ++ memberAliasCands gctx prog

-- The member-alias rows of [prog], less any whose local name [prog] itself declares
-- at top level: an own top-level value shadows an import of the same local name, so
-- that occurrence is the module's declaration and the import supplies no spelling.
export
memberAliasCands : GraphCtx ->
  List Decl ->
  List (String, String, String, Ident, Loc)
memberAliasCands gctx prog =
  let own = namesToSet (declTopFnNames prog) omEmpty
  filterList
    (r => not (omHasKey (aliasRowKey r) own))
    (useKeyCands (memberAliasKeys gctx) prog)

export
useKeyCands : (UsePath -> Loc -> List (String, String, String, Ident, Loc)) ->
  List Decl ->
  List (String, String, String, Ident, Loc)
useKeyCands _ [] = []
useKeyCands f ((DAttrib _ d) :: rest) = useKeyCands f [d] ++ useKeyCands f rest
useKeyCands f ((DUse _ path loc) :: rest) = f path loc ++ useKeyCands f rest
useKeyCands f (_ :: rest) = useKeyCands f rest

export
moduleAliasKeys : GraphCtx ->
  UsePath ->
  Loc ->
  List (String, String, String, Ident, Loc)
moduleAliasKeys gctx (path@(UseAlias _ a)) loc =
  aliasMethodKeysFor gctx a (useModId path) loc
moduleAliasKeys _gctx _ _ = []

memberAliasKeys : GraphCtx ->
  UsePath ->
  Loc ->
  List (String, String, String, Ident, Loc)
memberAliasKeys gctx (path@(UseGroup _ ms)) loc =
  flatMap (memberAliasMethodKeys gctx (useModId path) loc) ms
memberAliasKeys _gctx _ _ = []

-- `import m.{mth as loc}`: the local `loc` is a spelling of `m`'s method `mth`, keyed
-- under the local name.  It binds `loc` and nothing else, so a bare `mth` in the same
-- module is answered by whatever else binds it (the prelude, another import).
memberAliasMethodKeys : GraphCtx ->
  String ->
  Loc ->
  UseMember ->
  List (String, String, String, Ident, Loc)
memberAliasMethodKeys gctx mid loc m = match useMemberAlias m
  None => []
  Some local => match omLookup mid (methodExportsIndex gctx ())
    None => []
    Some rows =>
      let origin = useMemberOrigin m
      map
        (r => (local, origin, mid, snd r, loc))
        (filterList (r => fst r == origin) rows)

-- every method the aliased module EXPORTS, under the local `A.<method>` spelling and
-- carrying that method's own declaration identity, never a bare-name last-write-wins pick.
aliasMethodKeysFor : GraphCtx ->
  String ->
  String ->
  Loc ->
  List (String, String, String, Ident, Loc)
aliasMethodKeysFor gctx a mid loc =
  match omLookup mid (methodExportsIndex gctx ())
    None => []
    Some rows => aliasMethodKeyRows a mid loc rows

aliasMethodKeyRows : String ->
  String ->
  Loc ->
  List (String, Ident) ->
  List (String, String, String, Ident, Loc)
aliasMethodKeyRows _ _ _ [] = []
aliasMethodKeyRows a mid loc ((mname, ident) :: rest) =
  (qualifiedLocal a mname, mname, mid, ident, loc)
    :: aliasMethodKeyRows a mid loc rest

-- Group the candidate rows BY KEY.  An OrdMap rather than a per-key `filterList` over
-- the whole row list: aliases × exported methods is small but the pairwise shape is the
-- quadratic compiler/AGENTS.md keeps finding, and there is no reason to mint another.
aliasMethodKeyGroup : List (String, String, String, Ident, Loc) ->
  OrdMap (List (String, String, String, Ident, Loc)) ->
  OrdMap (List (String, String, String, Ident, Loc))
aliasMethodKeyGroup [] g = g
aliasMethodKeyGroup (r :: rest) g =
  let k = aliasRowKey r
  aliasMethodKeyGroup rest (omInsert k (optionOr [] (omLookup k g) ++ [r]) g)

-- One decision per KEY.  Exactly one declaration identity behind it ⇒ supply the entry
-- (the #1386 / #1276 remedy, unchanged).  Two or more ⇒ no entry and a hard ambiguity
-- diagnostic; suppressing the entry is what keeps the follow-on `No impl of <the loser>`
-- message — which named an interface the occurrence never unambiguously picked — from
-- being reported instead of the real cause.
aliasMethodKeyApply : ModuleCtx ->
  OrdMap (List (String, String, String, Ident, Loc)) ->
  List String ->
  OrdMap (IfaceRef, List String, Ty, List (String, List Kind)) ->
  OrdMap (IfaceRef, List String, Ty, List (String, List Kind))
aliasMethodKeyApply _mctx _ [] tab = tab
aliasMethodKeyApply mctx g (k :: rest) tab =
  let hits = optionOr [] (omLookup k g)
  let tab2 = match aliasRowIdents hits []
    [] => tab
    [_] => aliasMethodKeyEntry mctx k hits tab
    _ =>
      pushTypeErrorOnceAt
        mctx
        TAmbiguousAliasMethod
        (aliasRowLastLoc hits)
        (aliasAmbiguityMsg k hits)
      tab
  aliasMethodKeyApply mctx g rest tab2

aliasMethodKeyEntry : ModuleCtx ->
  String ->
  List (String, String, String, Ident, Loc) ->
  OrdMap (IfaceRef, List String, Ty, List (String, List Kind)) ->
  OrdMap (IfaceRef, List String, Ty, List (String, List Kind))
aliasMethodKeyEntry _mctx _ [] tab = tab
aliasMethodKeyEntry mctx k ((_, mname, _, ident, _) :: _) tab =
  match methodRowById ident (methodVisibleHere mctx mname)
    None => tab
    Some r => omInsert k r.mrEntry tab

aliasRowKey : (String, String, String, Ident, Loc) -> String
aliasRowKey (k, _, _, _, _) = k

-- ── #1386: the alias-qualified spellings, as a NAME MAP ─────────────────────────
-- The candidate rows above answer "what does `A.mth` mean"; three readers downstream
-- ask the cheaper question "which occurrence spellings are a method of this module's
-- import scope, and what is the origin name behind each".  This projection is over
-- the RAW candidate rows; the supply (`aliasMethodKeyApply`) additionally drops a
-- key whose candidates are ambiguous (`T-AMBIGUOUS-ALIAS-METHOD`, loud) or whose
-- method lookup misses (silent).  So the three readers below see a SUPERSET of the
-- supply's spellings: on the ambiguous key the program is rejected anyway; on the
-- miss the readers treat a spelling as a method the supply has no entry for — no
-- program reaching that arm has been constructed, and the invariant is stated here
-- rather than assumed:
--   * `moduleMarkCtx` — the mark sets are keyed by the OCCURRENCE, so the dotted
--     spelling has to join them or `rewriteArgScoped` never marks the occurrence.
--   * `originMethodName` — the by-identity dispatch-index rows are keyed by the
--     method's own declared name, which the dotted spelling is not.
--   * `resolveAliasMethodSpellings` — after inference, the dotted spelling goes back
--     to the origin so every bare-name method table downstream (eval's coalesced
--     cells and per-tag `requires` counts, the emitter's method tables) is unchanged.
export
aliasMethodSpellings : GraphCtx -> List Decl -> List (String, String)
aliasMethodSpellings gctx prog =
  map aliasRowSpelling (aliasMethodKeyCands gctx prog)

export
aliasRowSpelling : (String, String, String, Ident, Loc) -> (String, String)
aliasRowSpelling (k, mname, _, _, _) = (k, mname)

aliasRowModule : (String, String, String, Ident, Loc) -> String
aliasRowModule (_, _, m, _, _) = m

-- The DISTINCT declaration identities behind one key.  IDENTITY, not module id: the
-- same declaration reached through a re-export hop arrives twice under two module ids
-- and must NOT read as ambiguous.
aliasRowIdents : List (String, String, String, Ident, Loc) ->
  List Ident ->
  List Ident
aliasRowIdents [] acc = acc
aliasRowIdents ((_, _, _, i, _) :: rest) acc
  | anyList (== i) acc = aliasRowIdents rest acc
  | otherwise = aliasRowIdents rest (acc ++ [i])

-- The LAST colliding import's span — the one a plain insert would let silently overwrite.  Both
-- orderings of the same two imports land on the same line, so the diagnostic's span is
-- as order-independent as its verdict.
aliasRowLastLoc : List (String, String, String, Ident, Loc) -> Option Loc
aliasRowLastLoc [] = None
aliasRowLastLoc [(_, _, _, _, l)] = Some l
aliasRowLastLoc (_ :: rest) = aliasRowLastLoc rest

-- Phrased after `ppResError (DuplicateInterfaceMethod …)`: name the two things that
-- collide, say the occurrence cannot be attributed to either, then name both fixes.
-- The module list is `sortUniqS`-ordered so the message does not encode import order.
aliasAmbiguityMsg : String ->
  List (String, String, String, Ident, Loc) ->
  String
aliasAmbiguityMsg k hits =
  let mods =
    joinWith " and " (map backticked (sortUniqS (map aliasRowModule hits)))
  "`\{k}` is ambiguous: the alias names more than one module declaring a method `\{aliasRowMethodOf hits}` (\{mods}); give those imports different alias names"

aliasRowMethodOf : List (String, String, String, Ident, Loc) -> String
aliasRowMethodOf [] = ""
aliasRowMethodOf ((_, m, _, _, _) :: _) = m

-- Is candidate [c] the declaration of [n] that one of THIS module's imports brings in?
-- Rung 1 of `methodScopeAt`'s ladder: the METHOD name must come through the
-- path.  [wide] = False, so a path that names only the candidate's interface does
-- NOT witness it here.
methodCandImported : GraphCtx ->
  List Decl ->
  String ->
  (Ident, (IfaceRef, List String, Ty, List (String, List Kind))) ->
  Bool
methodCandImported gctx prog n c = anyUsePathBinds gctx prog False n c

-- RUNG 2 (F23): the same question with the INTERFACE-nameability reading also
-- admitted.  Reached only when rung 1 admitted nothing — see `methodScopeAt`,
-- where the precedence between the two rungs is argued and grounded (RUN-METHID-116;
-- NOT in S2-DECL (c), which does not govern a corpus with no standalone).
methodCandAdmitted : GraphCtx ->
  List Decl ->
  String ->
  (Ident, (IfaceRef, List String, Ty, List (String, List Kind))) ->
  Bool
methodCandAdmitted gctx prog n c = anyUsePathBinds gctx prog True n c

anyUsePathBinds : GraphCtx ->
  List Decl ->
  Bool ->
  String ->
  (Ident, (IfaceRef, List String, Ty, List (String, List Kind))) ->
  Bool
anyUsePathBinds _gctx [] _ _ _ = False
anyUsePathBinds gctx ((DAttrib _ d) :: rest) wide n c =
  anyUsePathBinds gctx [d] wide n c || anyUsePathBinds gctx rest wide n c
anyUsePathBinds gctx ((DUse _ path _) :: rest) wide n c =
  usePathWitnesses gctx path wide n c || anyUsePathBinds gctx rest wide n c
anyUsePathBinds gctx (_ :: rest) wide n c = anyUsePathBinds gctx rest wide n c

-- ── the witness reads IDENTITY, not spelling ──
-- An import witnesses a candidate when TWO things hold:
--   * the path lets the name through — `usePathBindsName`, the member filter;
--   * the dependency's row CARRIES *that declaration* of the name — asked of
--     `meExports`, the graph's (module id → name → declaring `Ident`)
--     index, so a re-export chain resolves transitively and by identity.
--     "carries", not "exports": the row has no `pub` filter (F3, `declMethodIdentsOf`).
--
-- The second conjunct is not a bare-INTERFACE-NAME comparison, because interface names
-- are NOT globally unique, and a spelling compare mis-witnesses in two ways:
--   #1275 — an unrelated BYSTANDER module declaring a same-named interface with the same
--           method name would be witnessed by an import that names neither it nor anything
--           of it, so the guard would see two matches and the scope would decide neither;
--   #1272 — a WILDCARD import of a re-exporter (`import mid.*`) names no member, so a name
--           test cannot fire for it; letting a wildcard satisfy a NAME test makes it "name"
--           every interface and witness every candidate.  Under an EXPORT test that dilemma
--           disappears — a wildcard admits every name, and the index still admits only the
--           declarations `mid` really re-exports.
-- L2 (`compiler/TYPECHECK-TARGET-ARCHITECTURE.md`): identity is resolved, never re-derived
-- from spelling, so the candidate's `iface` string is not read here.
--
-- There is no module-id disjunct (`mkIdent NsMethod (OriginModule dep) n == Some ident`):
-- it is the case where `dep` declares the method itself, and `meExports` seeds every module
-- with its OWN declarations, so the export test subsumes it.  Keeping both would be a
-- parallel near-copy.
--
-- The ALIAS spelling (`import m as A` … `A.mth`, #1276) is NOT witnessed here, and a
-- `UseAlias` arm in `usePathWitnesses` does not help: with such an arm #1276's repro still
-- printed `2` at exit 0.  `A.mth` never becomes a bare-`mth` occurrence for this table on
-- any path: `renameAliasedMethods` has one caller (`elaborateModules`), which the `check`
-- drivers do not use, and it has no module-alias arm.  That does not mean no surface
-- reports anything: with `import ifacea as A`, `data Blob` and NO impl anywhere, `medaka
-- check` exits 0 with no diagnostic while `medaka run` panics `unbound identifier: mth`.
-- The fix is a driver / AST-carrier change.
--
-- `core` is the implicit prelude, never an explicit provenance (importDefinersOf skips it
-- for the same reason); the ladder's last rung (`methodUndecided`) reads it.
--
-- CONVERGENCE UNDER #1280 (identity SUPPLY), stated because the direction is not
-- obvious: a declaration with no module id mints no `Ident` and so contributes NO row
-- (`ifaceMethodIdentPair`).  Every such gap today makes `depExportsMethodIdent` answer
-- False, i.e. the index is an UNDER-approximation and the overlay declines more often
-- than it should.  When #1280 makes supply total, rows appear that are missing now, so
-- the overlay STRENGTHENS — strictly more candidates witnessed, never fewer.  A shape
-- that the scope leaves undecided today can therefore start being decided correctly then;
-- the change is monotone in the right direction, but it IS a behaviour change and this
-- unit's fixtures do not cover it.
usePathWitnesses : GraphCtx ->
  UsePath ->
  Bool ->
  String ->
  (Ident, (IfaceRef, List String, Ty, List (String, List Kind))) ->
  Bool
usePathWitnesses gctx path wide n (ident, (iface, _, _, _)) =
  let dep = useModId path
  dep /= "core"
    && usePathAdmitsDecl path wide n iface
    && depExportsMethodIdent gctx dep n ident

-- Does [dep]'s row carry a method spelled [n] whose DECLARATION is [ident]?
--
-- "Row carries", not "dep exports": the row has no `pub` filter, so it also holds a
-- private interface's methods (F3, `declMethodIdentsOf`).
--
-- A per-`dep` miss is the honest answer to "this dependency's row does not carry that
-- declaration".  A miss does not always decline: the ladder decides on exactly one
-- witnessed declaration, so dropping one of two witnesses turns "2 → undecided" into
-- "1 → that one".  A wholesale miss — the index absent — is a programming error;
-- `meExports` lives on `DeclEnvs`, which the one Module-mode driver entry
-- (`graphPreamble`) overwrites whole and nothing resets in between.
depExportsMethodIdent : GraphCtx -> String -> String -> Ident -> Bool
depExportsMethodIdent gctx dep n ident =
  match omLookup dep (methodExportsIndex gctx ())
    None => False
    Some es => exportsIdentFor n ident es

-- Grow the constructor population by THIS module's PUBLIC data decls.
--
-- The scheme is read back out of [env] rather than re-derived, and that is the whole
-- reason this runs in `appendDataUniverse`: [env] is the universe env immediately after
-- `registerAllDataScoped … pubDecls`, so a row holds the very scheme object the floor
-- holds, and no extra `registerVariants` call is made (which would mint fresh tyvars,
-- re-run `recordParamKinds`, and re-write `recordByNameRef`).
--
-- Within ONE module a constructor name is unique (a duplicate is rejected upstream), so
-- `lookupCtor env cn` after that registration is unambiguously THIS module's `cn`.  A
-- constructor with no scheme in [env] (an abstract decl whose ctors were never
-- registered) is not inserted, so neither its floor nor its rows change.  An unstamped
-- declaration mints no identity and reaches the floor alone (`spInsert`).
export
insertCtorPop : TcEnv -> List Decl -> SpellingPop Scheme -> SpellingPop Scheme
insertCtorPop _env [] pop = pop
insertCtorPop env ((DAttrib _ d) :: rest) pop =
  insertCtorPop env rest (insertCtorPop env [d] pop)
insertCtorPop env ((DData { dataName, dataCtors, dataOrigin, ... }) :: rest) pop =
  insertCtorPop
    env
    rest
    (insertCtorVariants env dataName dataOrigin dataCtors pop)
insertCtorPop env ((DNewtype { newtypeName, newtypeCtor, newtypeOrigin, ... }) :: rest) pop =
  insertCtorPop
    env
    rest
    (insertCtorRow env newtypeName newtypeOrigin newtypeCtor pop)
insertCtorPop env (_ :: rest) pop = insertCtorPop env rest pop

insertCtorVariants : TcEnv ->
  String ->
  TyConOrigin ->
  List Variant ->
  SpellingPop Scheme ->
  SpellingPop Scheme
insertCtorVariants _env _ _ [] pop = pop
insertCtorVariants env tyName o ((Variant cn _) :: rest) pop =
  insertCtorVariants env tyName o rest (insertCtorRow env tyName o cn pop)

insertCtorRow : TcEnv ->
  String ->
  TyConOrigin ->
  String ->
  SpellingPop Scheme ->
  SpellingPop Scheme
insertCtorRow env tyName o cn pop = match lookupCtor env cn
  None => pop
  Some s => spInsert (mkIdent NsCtor o cn) cn tyName s pop

-- ── THIS module's scoped view of the bare-name constructor env ─────────────
-- Overlay [env] (the fully-registered `dataEnv`: universe < import overlay < prog0) with
-- the declaration each COLLIDED constructor name resolves to in this module'S SCOPE.
-- Iterates the collided list — not the table — so a program with no constructor-name
-- collision pays ONE `[]` match per module and returns [env] itself, unchanged and
-- unallocated.
--
-- An overlay, never a rebuild: anything this cannot resolve keeps [env]'s answer,
-- which is today's behaviour.  It can
-- only ever REPLACE an entry, never add or remove one — a collided name has ≥2 candidates
-- in the universe, so it is registered in [env] by construction.
export
applyCtorScopeOverrides : List Decl -> TcEnv -> TcEnv
applyCtorScopeOverrides prog env =
  let pop = env.teDyn.dcModule.mcGraph.crossRun.universeCtorPop.value
  overrideScopedCtors prog (spRows pop) (spCollided pop) env

overrideScopedCtors : List Decl ->
  OrdMap (List (Ident, String, Scheme)) ->
  List String ->
  TcEnv ->
  TcEnv
overrideScopedCtors _ _ [] env = env
overrideScopedCtors prog cands (n :: rest) env =
  let env2 = match omLookup n cands
    None => env
    Some cs => match scopedCtorEntry env.teDyn.dcModule.mcGraph prog n cs
      None => env
      Some s => addCtor env n s
  overrideScopedCtors prog cands rest env2

-- Which declaration of constructor [n] does THIS module mean?  Same nearest-scope-wins
-- ladder as `methodScopeAt` and `tyOriginScope`, with one rung fewer (see the
-- no-prelude-rung note above).  `None` at any rung means "this module's scope does not
-- decide it" and the caller keeps the floor — never a guess.
--
-- THE OWN-declaration rung is A DECLINE, NOT A LOOKUP, and the asymmetry with
-- `methodScopeAt` is deliberate: the companion is grown in `appendDataUniverse`,
-- which runs at the END of this module's own arm, so this module's declarations are not
-- in [cs] yet.  They do not need to be — `registerAllData base prog0` registered them
-- LAST at the call site, so the floor already holds the own-declaration answer and
-- overriding it could only make it worse.
scopedCtorEntry : GraphCtx ->
  List Decl ->
  String ->
  List (Ident, String, Scheme) ->
  Option Scheme
scopedCtorEntry gctx prog n cs =
  if declaresCtorNamed prog n then None else importedCtorEntry gctx prog n cs

-- Exactly one of this name's declarations is reachable through an import of THIS module:
-- that is what the occurrence names.  Two would be an ambiguous occurrence, which resolve
-- already rejects (`R-AMBIGUOUS-CTOR`), so declining there costs nothing an ACCEPTED
-- program can observe — and, per the ambiguity note above, it is what keeps this from
-- re-deciding a question resolve owns.
importedCtorEntry : GraphCtx ->
  List Decl ->
  String ->
  List (Ident, String, Scheme) ->
  Option Scheme
importedCtorEntry gctx prog n cs =
  match filterList (c => ctorCandImported gctx prog n c) cs
    [only] => Some (ctorCandScheme only)
    _ => None

ctorCandScheme : (Ident, String, Scheme) -> Scheme
ctorCandScheme (_, _, s) = s

-- Does THIS module declare a constructor spelled [n]?  Monomorphic and short-circuiting
-- on purpose (`compiler/AGENTS.md`); runs only for a COLLIDED name.
--
-- THE `DAttrib` arm recurses into itself (`declaresCtorNamed [d] n`), it does NOT
-- unwrap one layer with `declCtorNamed n d`.  `DAttrib` CAN wrap another `DAttrib`
-- (`parseAttrib` calls `parseDecl` recursively — `frontend/parser.mdk`'s own comment
-- names the case), and `declCtorNamed`'s `_ => False` arm swallows a nested one
-- silently.  Both siblings on this path already recurse (`insertCtorPop`,
-- `anyUsePathBindsCtor`); this one did not, and the divergence was caught in review
-- rather than by any gate.
--
-- It is latent today, which is why it is written down instead of shrugged off: an
-- attribute on a `data` declaration currently destroys that declaration's constructors
-- (a separate, pre-existing S1), so no doubly-attributed data decl reaches here with
-- constructors to find.  When THAT is fixed this goes live, and its failure mode is
-- precisely the counterfactual `ctor_scope_ident_local_ctor_bystander/bystand.mdk`
-- measures: the own-declaration rung fails to decline, the single import witness wins,
-- and the module's own constructor is clobbered by an imported same-named one.
declaresCtorNamed : List Decl -> String -> Bool
declaresCtorNamed [] _ = False
declaresCtorNamed ((DAttrib _ d) :: rest) n =
  declaresCtorNamed [d] n || declaresCtorNamed rest n
declaresCtorNamed (d :: rest) n = declCtorNamed n d || declaresCtorNamed rest n

ctorCandImported : GraphCtx ->
  List Decl ->
  String ->
  (Ident, String, Scheme) ->
  Bool
ctorCandImported gctx prog n (ident, owner, _) =
  anyUsePathBindsCtor gctx prog n owner ident

anyUsePathBindsCtor : GraphCtx -> List Decl -> String -> String -> Ident -> Bool
anyUsePathBindsCtor _gctx [] _ _ _ = False
anyUsePathBindsCtor gctx ((DAttrib _ d) :: rest) n owner ident =
  anyUsePathBindsCtor gctx [d] n owner ident
    || anyUsePathBindsCtor gctx rest n owner ident
anyUsePathBindsCtor gctx ((DUse _ path _) :: rest) n owner ident =
  usePathWitnessesCtor gctx path n owner ident
    || anyUsePathBindsCtor gctx rest n owner ident
anyUsePathBindsCtor gctx (_ :: rest) n owner ident =
  anyUsePathBindsCtor gctx rest n owner ident

-- An import witnesses a candidate when TWO things hold — the identical conjunction
-- `usePathWitnesses` states for methods:
--   * the path lets the CONSTRUCTOR through — `usePathBindsCtor`;
--   * the dependency's row CARRIES *that declaration* of it — asked of
--     `deCtorExports`, so a re-export chain resolves transitively and BY IDENTITY.
--     That second conjunct is what drains #1283: the re-exporter's row carries the
--     DECLARING module's `Ident`, so naming the re-exporter and naming the definer are
--     the same question with the same answer.
usePathWitnessesCtor : GraphCtx -> UsePath -> String -> String -> Ident -> Bool
usePathWitnessesCtor gctx path n owner ident =
  let dep = useModId path
  dep /= "core"
    && usePathBindsCtor path n owner
    && depExportsCtorIdent gctx dep n ident

-- `usePathBindsName` — A-2.5's member filter — is not reusable here, and reusing it
-- is how this unit would have reproduced the #1272 / #1275 class one namespace over.
-- It tests whether a member SPELLS the name; `import m.{T(..)}` binds constructor `C`
-- without spelling it anywhere.  So the ctor filter is given the candidate's OWNING TYPE
-- NAME alongside the ctor name, and `memberBindsCtorName` is the ONE predicate that
-- answers "does this member bind this constructor" — shared with the re-export expansion
-- (`rowBoundByMember`) so the two cannot drift into two rules.
--
-- `UseWild` (`import m.*`) binds every constructor `m` exports, and that is safe for the
-- same reason it is safe for methods: the export test still admits only the declarations
-- `m` really provides.  `UseAlias` (`import m as A`) binds every constructor `m` exports
-- too, spelled `A.C`; resolve strips the prefix before typecheck, so the occurrence that
-- reaches the bare-keyed table is indistinguishable from a wildcard import's and
-- witnesses on the same terms.  `UseName` (bare `import m`) binds NO names — it exists
-- to bring impls into scope for dispatch (`AGENTS.md`) — so it alone witnesses nothing.
--
-- Nothing here reads the ALIAS: the caller's second conjunct
-- (`depExportsCtorIdent`) already restricts the witness to a declaration the aliased
-- module really carries, and an alias-qualified spelling whose base the module does not
-- export is never stripped in the first place (`unqualCtor`'s guard,
-- `frontend/resolve.mdk`).
usePathBindsCtor : UsePath -> String -> String -> Bool
usePathBindsCtor (UseGroup _ ms) n owner = anyMemberBindsCtor n owner ms
usePathBindsCtor (UseWild _) _ _ = True
usePathBindsCtor (UseAlias _ _) _ _ = True
usePathBindsCtor _ _ _ = False

anyMemberBindsCtor : String -> String -> List UseMember -> Bool
anyMemberBindsCtor _ _ [] = False
anyMemberBindsCtor n owner (m :: rest) =
  memberBindsCtorName n owner m || anyMemberBindsCtor n owner rest

-- The two spellings that bind a constructor: naming it, or naming its type with `(..)`.
-- The member's ORIGIN spelling is what is compared — `UseMember`'s first field, the name
-- in the EXPORTING module (`useMemberOrigin`) — because the candidate table is keyed by
-- the constructor's DECLARED name and no constructor is ever registered under an alias.
--
-- An earlier version of this comment drew the opposite consequence from the same
-- (correct) premise, claiming that an aliased member `{C as D}` "therefore does not
-- witness".  It is the origin that is compared, so such a member WOULD witness.  The
-- point is moot either way — `import m.{C as D}` is REJECTED upstream ("is a type or
-- constructor and cannot be aliased"), so no aliased constructor member reaches here —
-- but a wrong consequence beside a right premise is exactly the sentence a later reader
-- builds on, so it is corrected rather than deleted.  A WHOLE-MODULE alias is a
-- different statement, decided by `usePathBindsCtor` above and not by this predicate.
export
memberBindsCtorName : String -> String -> UseMember -> Bool
memberBindsCtorName n owner (UseMember mn ctors _ _) =
  mn == n || ctors && mn == owner

-- Does [dep]'s row carry a constructor spelled [n] whose DECLARATION is [ident]?
--
-- A per-`dep` miss is the honest answer to "this dependency's row does not carry that
-- declaration"; a WHOLESALE miss — the index absent — is a programming error, and the
-- property that forbids it is the same two-part conjunction stated on
-- `meExports` (overwritten at every Module-mode driver entry AND no reset point
-- in between); `deCtorExports` rides the same `DeclEnvs` write.
depExportsCtorIdent : GraphCtx -> String -> String -> Ident -> Bool
depExportsCtorIdent gctx dep n ident =
  match omLookup dep (ctorExportsIndex gctx ())
    None => False
    Some es => exportsCtorIdentFor n ident es

exportsCtorIdentFor : String -> Ident -> List (String, String, Ident) -> Bool
exportsCtorIdentFor _ _ [] = False
exportsCtorIdentFor n ident ((cn, _, ci) :: rest)
  | cn == n && ci == ident = True
  | otherwise = exportsCtorIdentFor n ident rest

-- Grow the record population by THIS module's PUBLIC record declarations.
--
-- The `RecordInfo` is read back out of `recordByNameRef` rather than re-derived, for the
-- same reason `insertCtorPop` reads its `Scheme` out of `env2`: this runs immediately
-- after `registerAllDataScoped … pubDecls` in `appendDataUniverse`, so
-- `lookupRecordByName key` is THIS module's just-registered entry.  Re-deriving would
-- call `registerRecordInfoKeyed` a second time, minting a second set of `freshVars` for
-- the same declaration — two RecordInfos for one record.
--
-- Only `ConNamed` variants are inserted, because only they are registered:
-- `registerNamedFieldVariants` skips a positional variant.  The short-form record
-- `data X = { … }` IS a `ConNamed` variant (its key and its type name coincide); a
-- `DNewtype` is `ConPos` and contributes nothing here.
export
insertRecordPop : ModuleCtx ->
  List Decl ->
  SpellingPop RecordInfo ->
  SpellingPop RecordInfo
insertRecordPop _mctx [] pop = pop
insertRecordPop mctx ((DAttrib _ d) :: rest) pop =
  insertRecordPop mctx rest (insertRecordPop mctx [d] pop)
insertRecordPop mctx ((DData { dataName, dataCtors, dataOrigin, ... }) :: rest) pop =
  insertRecordPop
    mctx
    rest
    (insertRecordVariants mctx dataName dataOrigin dataCtors pop)
insertRecordPop mctx (_ :: rest) pop = insertRecordPop mctx rest pop

insertRecordVariants : ModuleCtx ->
  String ->
  TyConOrigin ->
  List Variant ->
  SpellingPop RecordInfo ->
  SpellingPop RecordInfo
insertRecordVariants _mctx _ _ [] pop = pop
insertRecordVariants mctx tyName o ((Variant cn (ConNamed _ _)) :: rest) pop =
  insertRecordVariants mctx tyName o rest (insertRecordRow mctx tyName o cn pop)
insertRecordVariants mctx tyName o (_ :: rest) pop =
  insertRecordVariants mctx tyName o rest pop

insertRecordRow : ModuleCtx ->
  String ->
  TyConOrigin ->
  String ->
  SpellingPop RecordInfo ->
  SpellingPop RecordInfo
insertRecordRow mctx tyName o cn pop = match lookupRecordByName mctx cn
  None => pop
  Some ri => spInsert (mkIdent NsCtor o cn) cn tyName ri pop

-- ── THIS module's scoped view of `recordByNameRef` ─────────────────────────
-- Runs at the `dataEnv` binding, immediately after `registerAllData … prog0` has written
-- the floor (universe < import overlay < prog0) into the per-run ref, and iterates the
-- collided-KEY list — a program in which no two modules declare the same record /
-- named-field-variant name pays one `[]` match per module and mutates nothing.
--
-- "NORMALLY EMPTY" IS A claim about record keys, not about field names, and the
-- distinction is load-bearing rather than pedantic.  Keying the same machinery on
-- collided FIELD names (`fieldOwnersRef`) fails: that list is routinely non-empty (any two
-- records anywhere in the graph sharing `name`/`id`/`size` put a name on it), and the
-- per-module walk became 5.6x net allocation at 240 modules.  A collided record KEY means two modules declare a
-- record spelled the same, which is the collision this unit exists for and is genuinely
-- rare — but it is an empirical claim, so `gen_modules` in
-- `test/diff_compiler_perf_scaling.sh` declares records per module; without that no
-- multi-module generator in the gate exercises this code path.  Derive the generator set rather than trusting this
-- sentence: `grep -n '^gen_[a-z_]*() {' test/diff_compiler_perf_scaling.sh`.
--
-- OVERLAY, never a rebuild: anything a module's scope does not decide keeps the floor's
-- answer.
--
-- The scoped view must not reach the universe, and it does not — but only because of
-- where `appendDataUniverse` reloads.  The overlay mutates the PER-RUN ref, and
-- `appendDataUniverse` (the end of this module's arm) opens with `loadDataUniverse`,
-- which overwrites that ref from the cross-run universe — and, for the alias table,
-- from stage K at this module's ordinal — BEFORE this module's public decls
-- are registered into it.  So one module's scope decision is invisible to the next.
-- Moving the reload, or growing the universe from the per-run refs as they stand at the
-- end of the arm, would make module A's import scope decide module B's records.
--
-- This breaks the `#415` lockstep.  `registerRecordInfoKeyed` is the sole registration
-- writer of `recordByNameRef` and `fieldOwnersRef`, and this overlay writes
-- `recordByNameRef` ALONE.  Re-pointing key `K` does not change WHICH keys own a field
-- name (the key is the same string), but it does change which FIELDS `K` declares: with
-- two same-named records having DISJOINT field sets, `fieldOwnersRef` can name `K` as the
-- owner of a field the newly-selected `K` does not have.  That has a consequence (#1377):
-- a module that names one `Cfg` and holds a value of the OTHER `Cfg` was refused, `Field
-- 'beta' does not belong to record 'Cfg'`, where `5` is correct.  `resolveFieldRecord`'s
-- arm (a) no longer reads this overlay's answer for a receiver whose type carries an
-- identity, which removes that question but not the write asymmetry; do not state the
-- asymmetry as harmless.
--
-- ── the rule this overlay now states, and its boundary ──────────────────────
-- **The declaration this module NAMES wins for every occurrence of that name written in this
-- MODULE'S SOURCE** — a record literal, a record pattern, a variant update, an annotation.
--
-- A projection of a value whose type this module never named is decided by the
-- RECEIVER's identity (`lookupRecordForReceiver`), not here.
--
-- What is left is the SPELLING question, and for that a per-module scope decision is the
-- right instrument rather than a stopgap — `docs/spec/DICT-SEMANTICS.md` §8 I4 qualification
-- 2 says record construction and record patterns *are* ambiguous exactly when the name is.
-- The overlay is still **scaffolding** for a different reason: it is a further implementation
-- of a fact `resolve.mdk` derives, and #1288 owns the consolidation.  Unit 4 owns retiring it.
export
applyRecordScopeOverrides : ModuleCtx -> List Decl -> Unit
applyRecordScopeOverrides mctx prog =
  let pop = mctx.mcGraph.crossRun.universeRecordPop.value
  overrideScopedRecords mctx prog (spRows pop) (spCollided pop)

overrideScopedRecords : ModuleCtx ->
  List Decl ->
  OrdMap (List (Ident, String, RecordInfo)) ->
  List String ->
  Unit
overrideScopedRecords _mctx _ _ [] = ()
overrideScopedRecords mctx prog cands (n :: rest) =
  match omLookup n cands
    None => ()
    Some cs => match scopedRecordEntry mctx.mcGraph prog n cs
      None => ()
      Some ri =>
        mctx.mcCells.recordByNameRef :=
          omInsert n ri mctx.mcCells.recordByNameRef.value
  overrideScopedRecords mctx prog cands rest

-- Which declaration of registry key [n] does THIS module mean?  The same ladder as
-- `scopedCtorEntry`, using the SAME two predicates — see the mirror-discipline note above
-- for why they are shared rather than copied.  The own-declaration rung is a DECLINE for
-- the same reason it is there: `registerAllData base prog0` registered this module's own
-- records LAST, so the floor already holds the own-declaration answer.
scopedRecordEntry : GraphCtx ->
  List Decl ->
  String ->
  List (Ident, String, RecordInfo) ->
  Option RecordInfo
scopedRecordEntry gctx prog n cs =
  if declaresCtorNamed prog n then None else importedRecordEntry gctx prog n cs

importedRecordEntry : GraphCtx ->
  List Decl ->
  String ->
  List (Ident, String, RecordInfo) ->
  Option RecordInfo
importedRecordEntry gctx prog n cs =
  match filterList (c => recordCandImported gctx prog n c) cs
    [only] => Some (recordCandInfo only)
    _ => None

recordCandImported : GraphCtx ->
  List Decl ->
  String ->
  (Ident, String, RecordInfo) ->
  Bool
recordCandImported gctx prog n (ident, owner, _) =
  anyUsePathBindsCtor gctx prog n owner ident

-- ── #1351 L2 (MIGRATE Leg 2b): the IDENTITY-SCOPED picker for the shadow layer ──
--
-- `pickSchemes` above answers "which scheme does the bare name [n] have" with
-- `lookupAssoc` — FIRST MATCH over the method-row decl-walk order.  When two
-- interfaces declare the same method name, that order is module-processing order, so
-- the scheme an importer shadow is CHECKED AGAINST is decided by import-clause order.
-- MEASURED six-for-six (RUN-METHID-058): on `#1351`'s corpus the accept/reject split
-- tracks this row's identity with zero exceptions — `IA.mth : a -> Int -> Int`
-- unifies at `a := String` and accepts (wrongly, silently, value `7`); `IZ.mth : Int
-- -> b -> Int` does not and rejects loudly.  This is Leg 2b.
--
-- The successor asks `methodScopeAt`'s ALREADY-RESOLVED answer — the
-- declaration THIS module's own import scope admits for [n] — and takes that
-- declaration's own scheme row out of L1's identity-keyed table.  It is a LOOKUP, not
-- a second resolver: the resolution happened at `methodEntryHere`'s population
-- site and is only consulted here (the named prohibition in this leaf's packet).
--
-- Miss falls back to `pickSchemes`' OWN ANSWER, deliberately.  Both misses are
-- real: `methodEntryHere` holds no entry for [n] (not an interface method at
-- all), or the admitted declaration contributes no method row
-- (its interface is not among `implDecls`).  A miss must not DROP the binding — that
-- would remove a name from the shadow layer, i.e. turn a checked occurrence into an
-- unchecked one, `exit 1 → exit 0`, a severity INCREASE.  Falling back keeps exactly
-- today's answer for every shape this leaf does not decide.
--
-- Two or more admitted declarations are not a miss.  The scope decides none of them,
-- so the first match would be one declaration's scheme picked by decl-walk order; the
-- name is bound to the imported standalone's scheme ([sources]) instead.  An applied
-- occurrence is then decided by S2-DECL (d)'s verdict (`importerAdmittedVerdict`),
-- which types it as the standalone or rejects it, and a value occurrence is the
-- standalone already.
export
pickSchemesByDecl : ModuleCtx ->
  List String ->
  List (String, Scheme) ->
  Registry MethodSchemeRow ->
  OrdMap Scheme ->
  List (String, EnvBinding)
pickSchemesByDecl _mctx [] _ _ _ = []
pickSchemesByDecl mctx (n :: ns) table byId sources =
  let rest = pickSchemesByDecl mctx ns table byId sources
  match admittedRowFor mctx n byId
    Some row => (n, methodEnvBinding row) :: rest
    None => match admittedSchemeFor mctx n byId
      Some s => (n, ordinaryEnvBinding s) :: rest
      None => match undecidedSchemeFor mctx n table sources
        Some s => (n, ordinaryEnvBinding s) :: rest
        None => rest

undecidedSchemeFor : ModuleCtx ->
  String ->
  List (String, Scheme) ->
  OrdMap Scheme ->
  Option Scheme
undecidedSchemeFor mctx n table sources =
  if isEmptyL (methodAdmittedHere mctx n) then
    lookupAssoc n table
  else
    omLookup n sources

export
importedMemberBindingNames : List Decl -> List String
importedMemberBindingNames [] = []
importedMemberBindingNames ((DAttrib _ decl) :: rest) =
  importedMemberBindingNames [decl] ++ importedMemberBindingNames rest
importedMemberBindingNames ((DUse _ path _) :: rest) =
  map snd (optionOr [] (importedBindings path))
    ++ importedMemberBindingNames rest
importedMemberBindingNames (_ :: rest) = importedMemberBindingNames rest

export
annotateImportedMethodRows : TcEnv ->
  List String ->
  OrdMap Unit ->
  OrdMap Unit ->
  Registry MethodSchemeRow ->
  TcEnv
annotateImportedMethodRows env [] _ _ _ = env
annotateImportedMethodRows env (name :: rest) nameable shadows rows =
  let originName = originMethodName env.teDyn.dcModule name
  let env2 =
    if omHasKey originName nameable
      && not (omHasKey name shadows)
      && isSome
        (lookupBinding
          env
          name) then match admittedRowFor env.teDyn.dcModule name rows
      Some row => extendMethodRow env name row
      None => env
    else
      env
  annotateImportedMethodRows env2 rest nameable shadows rows

admittedRowFor : ModuleCtx ->
  String ->
  Registry MethodSchemeRow ->
  Option MethodSchemeRow
admittedRowFor mctx n byId =
  if listLen (methodAdmittedHere mctx n) >= 2 then
    None
  else do
    (iface, _, _, _) <- methodEntryHere mctx n
    row <- lookupMethodRowById iface (originMethodName mctx n) byId
    if methodRowCanCarry row then Some row else None

-- The declaration `methodScopeAt` resolved for [n] in this module, then
-- that declaration's own scheme row.  `None` at either step means "this module's
-- scope does not decide it", and the caller answers without a declaration (the
-- bare-name scheme when nothing is admitted, the standalone when two or more are;
-- `pickSchemesByDecl`) — never a guess, the same discipline `methodScopeAt` states
-- for the table itself.
admittedSchemeFor : ModuleCtx ->
  String ->
  Registry MethodSchemeRow ->
  Option Scheme
-- #1386: the row half is keyed by the method's OWN declared name, the same asymmetry
-- `dispatchIdxScoped` carries — an alias-qualified occurrence resolves its interface
-- from the spelling and its row from the origin.  Both projections are read HERE, off
-- the one name, so they cannot be given two different scopes.
admittedSchemeFor mctx n byId = match methodEntryHere mctx n
  None => None
  Some (iface, _, _, _) => lookupSchemeById iface (originMethodName mctx n) byId

export
schemeOblEntriesFor : String ->
  UsePath ->
  List ((String, String), List VecObl) ->
  List (String, List VecObl)
-- `import m as A` → every constrained binding m defines is written `A.<name>` here.
schemeOblEntriesFor mid (UseAlias _ a) qual =
  flatMap (moduleAliasEntry mid a) qual
-- `import m.*` → every constrained binding m defines is written under its OWN name here.
schemeOblEntriesFor mid (UseWild _) qual = flatMap (wildSchemeOblEntry mid) qual
-- `import m.{x}` / `import m.{x as y}` → `x` (resp. `y`) carries x's scheme context.
schemeOblEntriesFor mid (UseGroup _ ms) qual =
  flatMap (memberSchemeOblEntry mid qual) ms
-- `import m` binds NO names (it exists to bring m's impls into scope), so nothing here.
schemeOblEntriesFor _ _ _ = []

wildSchemeOblEntry : String ->
  ((String, String), List VecObl) ->
  List (String, List VecObl)
wildSchemeOblEntry mid ((defMid, n), obs)
  | defMid == mid = [(n, obs)]
  | otherwise = []

memberSchemeOblEntry : String ->
  List ((String, String), List VecObl) ->
  UseMember ->
  List (String, List VecObl)
memberSchemeOblEntry mid qual m =
  let local = useMemberLocal m
  let origin = useMemberOrigin m
  map
    (e => (local, snd e))
    (filterList (e => fst (fst e) == mid && snd (fst e) == origin) qual)

-- B-2.2-f (#1113): the payload is `a`, not `List a`.  The declared-prefix sidecar's
-- qual table carries a per-entry SCALAR (`CDeclaredPrefix`), which does not fit a
-- list-shaped payload; every existing caller instantiates `a := List X` unchanged.
export
aliasConstraintEntries : GraphCtx ->
  List Decl ->
  List ((String, String), a) ->
  List (String, a)
aliasConstraintEntries _gctx [] _ = []
aliasConstraintEntries gctx ((DAttrib _ d) :: rest) qual =
  aliasConstraintEntries gctx [d] qual ++ aliasConstraintEntries gctx rest qual
aliasConstraintEntries gctx ((DUse _ path _) :: rest) qual =
  aliasEntriesFor gctx (importTableMid path) path qual
    ++ aliasConstraintEntries gctx rest qual
aliasConstraintEntries gctx (_ :: rest) qual =
  aliasConstraintEntries gctx rest qual

aliasEntriesFor : GraphCtx ->
  String ->
  UsePath ->
  List ((String, String), a) ->
  List (String, a)
-- `import m as A` → every constrained fn `m` defines is callable as `A.<name>`.
-- #1427: resolve `m`'s exports via `graphPubDefiners` (chasing re-exports to their
-- actual definer) instead of matching `qual`'s definer key against the SPELLED
-- module.  Mirrors `memberDefinerRow`'s "resolve identity off the graph, not the
-- spelling" shape.  A re-exporting `m` never itself DEFINES the name, so the old
-- `defMid == mid` test (`moduleAliasEntry`, still used unchanged by
-- `schemeOblEntriesFor`) was always false for it and the alias entry silently
-- dropped — `R.f 1` on a constrained re-exported callee panicked at build.
-- No direct-match fallback: like the wildcard tier of `useDefinerRows`, this arm
-- can't enumerate without the graph — safe here because `aliasConstraintEntries`
-- runs only in `Module` mode, where the envelope always exists.
-- The prelude (`importTableMid` → `""`) has no import-graph node, so `graphPubDefiners`
-- cannot enumerate it; it also re-exports nothing, so the definer key on its own rows is
-- already final and the direct `defMid == mid` match `schemeOblEntriesFor` uses is exact
-- here for the same reason it is inexact for a re-exporting module.
aliasEntriesFor gctx mid (UseAlias _ a) qual
  | mid == "" = flatMap (moduleAliasEntry mid a) qual
  | otherwise = flatMap (graphAliasEntry a qual) (graphPubDefiners gctx mid)
-- `import m.{x as y}` → `y` carries `x`'s dict arity.
aliasEntriesFor _gctx mid (UseGroup _ ms) qual =
  flatMap (memberAliasEntry mid qual) ms
aliasEntriesFor _gctx _ _ _ = []

-- IMPORT ALIASING: the LOCAL names, across every module, under which a CONSTRAINED
-- function is reachable through an alias.  These must join dictNames or the aliased
-- call site is never marked as a dict application (see the call site of this fn).
--
-- [bare] is the un-aliased dictNames; [unitDecls] is (mid, decls) for core + every
-- module, used to ask which fns a given module actually DEFINES — so `import m as A`
-- contributes `A.<n>` only for m's own constrained fns, never for a same-named
-- constrained fn belonging to some other module.
-- [bare] is a SET below this line: the walk asks `is this name constrained?` once per
-- name a dependency defines and once per name it re-exports, so a `contains` over the
-- graph's whole dict-name list was O(names x dictNames) per alias import.
export
aliasDictNames : GraphCtx ->
  List String ->
  List (String, List Decl) ->
  List (String, List Decl) ->
  List String
aliasDictNames gctx bare unitDecls modules =
  let bareSet = namesToSet bare omEmpty
  flatMap (u => aliasDictNamesOfUnit gctx bareSet unitDecls (snd u)) modules

aliasDictNamesOfUnit : GraphCtx ->
  OrdMap Unit ->
  List (String, List Decl) ->
  List Decl ->
  List String
aliasDictNamesOfUnit gctx bare unitDecls decls =
  flatMap (aliasDictNamesOfDecl gctx bare unitDecls) decls

aliasDictNamesOfDecl : GraphCtx ->
  OrdMap Unit ->
  List (String, List Decl) ->
  Decl ->
  List String
aliasDictNamesOfDecl gctx bare unitDecls (DAttrib _ d) =
  aliasDictNamesOfDecl gctx bare unitDecls d
aliasDictNamesOfDecl gctx bare unitDecls (DUse _ path _) =
  aliasDictNamesOfPath gctx bare unitDecls (useModId path) path
aliasDictNamesOfDecl _gctx _ _ _ = []

aliasDictNamesOfPath : GraphCtx ->
  OrdMap Unit ->
  List (String, List Decl) ->
  String ->
  UsePath ->
  List String
-- #2840: the alias arm answers off the GRAPH as well as off `mid`'s own decls.
-- `declTopFnNames` alone asks what the SPELLED module DEFINES, and a pure
-- re-exporter (`export import lib.decl.{f}`) defines nothing — so `R.f` never
-- joined the set, the call site was never marked, and the aliased constrained
-- callee ran with no dictionary (`run` read the dict where an `Int` belonged).
-- `graphPubDefiners` chases the re-export to its true definer, the same
-- identity-off-the-graph resolution `aliasEntriesFor` makes for the dict-ARITY
-- table; a row counts when the DEFINER's own name is in [bare].  The
-- decl-derived half stays because the graph is empty on the loader-less Flat
-- drivers, where a directly-imported definer must still contribute.
aliasDictNamesOfPath gctx bare unitDecls mid (UseAlias _ a) =
  let own = match lookupAssoc mid unitDecls
    Some ds => filter (n => omHasKey n bare) (declTopFnNames ds)
    None => []
  let reexported =
    map
      fst
      (filterList
        (r => omHasKey (snd (snd r)) bare)
        (graphPubDefiners gctx mid))
  map (qualifiedLocal a) (dedup (own ++ reexported))
aliasDictNamesOfPath _gctx bare _ _ (UseGroup _ ms) =
  flatMap (memberDictName bare) ms
aliasDictNamesOfPath _gctx _ _ _ _ = []

memberDictName : OrdMap Unit -> UseMember -> List String
memberDictName bare m = match useMemberAlias m
  Some local => if omHasKey (useMemberOrigin m) bare then [local] else []
  None => []

-- B-2.2-f (#1113): payload generalized `List a` -> `a` along with `aliasEntriesFor`
-- above (a bare `a` there cannot flow into a `List a` parameter here).  Every existing
-- caller — including `schemeOblEntriesFor`'s — instantiates `a := List X` unchanged.
moduleAliasEntry : String -> String -> ((String, String), a) -> List (String, a)
moduleAliasEntry mid a ((defMid, n), ids)
  | defMid == mid = [(qualifiedLocal a n, ids)]
  | otherwise = []

memberAliasEntry : String ->
  List ((String, String), a) ->
  UseMember ->
  List (String, a)
memberAliasEntry mid qual m = match useMemberAlias m
  None => []
  Some local =>
    let origin = useMemberOrigin m
    map
      (e => (local, snd e))
      (filter (e => fst (fst e) == mid && snd (fst e) == origin) qual)

-- one row of `graphPubDefiners mid`: `(localName, (defMid, origin))` — a name `mid`
-- exports and who actually DEFINES it, re-exports already chased.  Alias-qualify
-- `localName` when `qual` carries an entry keyed by that SAME `(defMid, origin)`,
-- not by `mid` itself — see `aliasEntriesFor`'s `UseAlias` arm (#1427).
graphAliasEntry : String ->
  List ((String, String), a) ->
  (String, (String, String)) ->
  List (String, a)
graphAliasEntry a qual (localName, (defMid, origin)) =
  map
    (e => (qualifiedLocal a localName, snd e))
    (filterList (e => fst (fst e) == defMid && snd (fst e) == origin) qual)

export
reportAmbiguousImportsIn : ModuleCtx -> OrdMap Unit -> List Decl -> Unit
reportAmbiguousImportsIn _mctx _ [] = ()
reportAmbiguousImportsIn mctx occ ((DAttrib _ d) :: rest) =
  reportAmbiguousImportsIn mctx occ [d]
  reportAmbiguousImportsIn mctx occ rest
reportAmbiguousImportsIn mctx occ ((DUse _ path loc) :: rest) =
  reportAmbiguousImport mctx occ (useModId path) path loc
  reportAmbiguousImportsIn mctx occ rest
reportAmbiguousImportsIn mctx occ (_ :: rest) =
  reportAmbiguousImportsIn mctx occ rest

reportAmbiguousImport : ModuleCtx ->
  OrdMap Unit ->
  String ->
  UsePath ->
  Loc ->
  Unit
reportAmbiguousImport mctx occ depId path loc =
  match graphAmbigValues mctx.mcGraph depId
    [] => ()
    amb => pushAmbiguousImports mctx depId loc (ambiguousAdmitted occ path amb)

-- which of the dependency's ambiguous names THIS import form makes this module actually
-- ambiguous ABOUT.  Two independent filters, and both must hold:
--
--   (1) the form BINDS the name.  A selective `{g}` / `{g as h}` binds a fixed member
--       list, which `importedBindings` enumerates; a wildcard (`None`) and a whole-module
--       alias (`Some []` — it cannot enumerate a member list, and must not be read as
--       "binds nothing") both bind every export.  Every form routes through
--       `importedBindings` exactly as `importFormRows` does, so a form added there
--       reaches this check by construction rather than by a case here.
--
--   (2) this module WRITES the name, in the spelling the form binds it under — `A.g` for
--       `import m as A`, bare `g` for everything else.  `occ` is `moduleRefNameSet`'s
--       set of every name occurring in the module's own decl bodies.
--
-- The selective arm needs no occurrence test: naming a member in the import list IS the
-- write, and demanding a second one would let `import m.{g}` pass while `g` sits unused,
-- which is not a narrowing anyone asked for.
ambiguousAdmitted : OrdMap Unit ->
  UsePath ->
  List (String, List String) ->
  List (String, List String)
ambiguousAdmitted occ (UseAlias _ a) amb =
  filterList (r => omHasKey (qualifiedLocal a (fst r)) occ) amb
ambiguousAdmitted occ path amb = match importedBindings path
  None => filterList (r => omHasKey (fst r) occ) amb
  Some bindings => filterList (r => anyList (b => fst b == fst r) bindings) amb

pushAmbiguousImports : ModuleCtx ->
  String ->
  Loc ->
  List (String, List String) ->
  Unit
pushAmbiguousImports _mctx _ _ [] = ()
pushAmbiguousImports mctx depId loc ((n, mids) :: rest) =
  pushTypeErrorHelpFixAt
    mctx
    TAmbiguousReexport
    (Some loc)
    (ambigReexportMsg n depId mids)
    (ambigReexportHelp n depId mids)
    None
  pushAmbiguousImports mctx depId loc rest

export
declCtorNamed : String -> Decl -> Bool
declCtorNamed n (DData { dataCtors = vs }) = variantNamed n vs
declCtorNamed n (DNewtype { newtypeCtor = cn }) = cn == n
declCtorNamed _ _ = False

-- #1386: the alias-qualified spellings of the methods ALREADY in [set], added to it.
-- The dotted spelling is a second spelling of one of the module's own in-scope
-- methods, so it inherits whatever decided the origin's membership — including the
-- S1 filter above, which is why this wraps each set rather than joining the raw
-- name lists ahead of it.  A method the filter dropped contributes no spelling.
export
withAliasMethodNames : List (String, String) -> OrdMap Unit -> OrdMap Unit
withAliasMethodNames rows set =
  omFromNames (map fst (filterList (r => omHasKey (snd r) set) rows)) set

export
importedIfaceRows : OrdMap (List (String, List String)) ->
  List Decl ->
  List (String, List String)
importedIfaceRows _ [] = []
importedIfaceRows idx ((DAttrib _ d) :: rest) =
  importedIfaceRows idx [d] ++ importedIfaceRows idx rest
importedIfaceRows idx ((DUse _ path _) :: rest) =
  (match omLookup (useModId path) idx
      None => []
      Some src => selectIfaceRows path src)
    ++ importedIfaceRows idx rest
importedIfaceRows idx (_ :: rest) = importedIfaceRows idx rest
# DESUGAR
(DUse false (UseGroup ("support" "diag_codes") ((mem "DiagCode" true))))
(DUse false (UseGroup ("types" "tc_types") ((mem "AbsorptionEvent" true) (mem "MethodScope" true) (mem "Predicate" true) (mem "UObligation" true) (mem "Windowed" true) (mem "DeclEnvs" false) (mem "EnvBinding" false) (mem "GraphCtx" false) (mem "ImplEnv" false) (mem "Kind" false) (mem "MethodEntry" false) (mem "MethodEnv" false) (mem "MethodRow" false) (mem "MethodSchemeRow" false) (mem "ModuleCtx" false) (mem "RecordInfo" false) (mem "TcEnv" false))))
(DUse false (UseGroup ("types" "tc_mono") ((mem "locEq" false))))
(DUse false (UseGroup ("types" "tc_env") ((mem "addCtor" false) (mem "ctorExportsIndex" false) (mem "declEnvVisibleAt" false) (mem "declTopFnNames" false) (mem "extendMethodRow" false) (mem "graphAmbigValues" false) (mem "graphPubDefiners" false) (mem "ieImplExistsForHeadOf" false) (mem "ifaceMethodNames" false) (mem "importedBindings" false) (mem "importTableMid" false) (mem "lookupBinding" false) (mem "lookupCtor" false) (mem "lookupIdxById" false) (mem "lookupMethodRowById" false) (mem "lookupRecordByName" false) (mem "lookupSchemeById" false) (mem "methodEnvBinding" false) (mem "methodExportsIndex" false) (mem "methodPreludeRow" false) (mem "methodRowById" false) (mem "methodRowCanCarry" false) (mem "methodRowCand" false) (mem "methodRowIface" false) (mem "namesToSet" false) (mem "ordinaryEnvBinding" false) (mem "originMethodName" false) (mem "recordCandInfo" false) (mem "variantNamed" false) (mem "selectIfaceRows" false))))
(DUse false (UseGroup ("types" "tc_diag") ((mem "pushTypeErrorHelpFixAt" false) (mem "pushTypeErrorOnceAt" false))))
(DUse false (UseGroup ("types" "tc_diag_text") ((mem "ambigReexportHelp" false) (mem "ambigReexportMsg" false) (mem "backticked" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "ConPayload" true) (mem "Decl" true) (mem "Ident" true) (mem "Loc" true) (mem "Ns" true) (mem "Ty" true) (mem "TyConOrigin" true) (mem "UseMember" true) (mem "UsePath" true) (mem "Variant" true) (mem "ifaceIdentity" false) (mem "mkIdent" false) (mem "qualifiedLocal" false) (mem "useMemberAlias" false) (mem "useMemberLocal" false) (mem "useMemberOrigin" false))))
(DUse false (UseGroup ("types" "repr") ((mem "IfaceRef" true) (mem "Scheme" true) (mem "VecObl" true))))
(DUse false (UseGroup ("support" "util") ((mem "anyList" false) (mem "contains" false) (mem "dedup" false) (mem "filterList" false) (mem "isEmptyL" false) (mem "isNonEmptyL" false) (mem "joinDot" false) (mem "joinWith" false) (mem "listLen" false) (mem "lookupAssoc" false) (mem "sortUniqS" false))))
(DUse false (UseGroup ("string") ((mem "endsWith" false))))
(DUse false (UseGroup ("types" "registry") ((mem "HeadKey" true) (mem "Registry" false) (mem "spCollided" false) (mem "SpellingPop" false) (mem "spInsert" false) (mem "spRows" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "omEmpty" false) (mem "omFromNames" false) (mem "omHasKey" false) (mem "omInsert" false) (mem "omKeys" false) (mem "omLookup" false) (mem "OrdMap" false))))
(DUse false (UseGroup ("types" "disposition") ((mem "MethodDisposition" true))))
(DUse false (UseGroup ("types" "route_key") ((mem "ifaceWordOf" false))))
(DUse false (UseGroup ("types" "solver_contract") ((mem "Wanted" true))))
(DUse false (UseGroup ("frontend" "visibility") ((mem "useModId" false))))
(DTypeSig true "ifaceSortKey" (TyFun (TyCon "IfaceRef") (TyCon "String")))
(DFunDef false "ifaceSortKey" ((PVar "ir")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EApp (EVar "ifaceIdentity") (EFieldAccess (EVar "ir") "irOrigin")) (EFieldAccess (EVar "ir") "irName")))) (ELit (LString "|"))) (EApp (EVar "display") (EFieldAccess (EVar "ir") "irName"))) (ELit (LString ""))))
(DTypeSig true "sortIfaceRefs" (TyFun (TyApp (TyCon "List") (TyCon "IfaceRef")) (TyApp (TyCon "List") (TyCon "IfaceRef"))))
(DFunDef false "sortIfaceRefs" ((PVar "xs")) (EApp (EApp (EVar "sortIfaceRefsGo") (EVar "xs")) (EListLit)))
(DTypeSig false "sortIfaceRefsGo" (TyFun (TyApp (TyCon "List") (TyCon "IfaceRef")) (TyFun (TyApp (TyCon "List") (TyCon "IfaceRef")) (TyApp (TyCon "List") (TyCon "IfaceRef")))))
(DFunDef false "sortIfaceRefsGo" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "sortIfaceRefsGo" ((PCons (PVar "x") (PVar "xs")) (PVar "acc")) (EApp (EApp (EVar "sortIfaceRefsGo") (EVar "xs")) (EApp (EApp (EVar "sortInsertIfaceRef") (EVar "x")) (EVar "acc"))))
(DTypeSig false "sortInsertIfaceRef" (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "IfaceRef")) (TyApp (TyCon "List") (TyCon "IfaceRef")))))
(DFunDef false "sortInsertIfaceRef" ((PVar "x") (PList)) (EListLit (EVar "x")))
(DFunDef false "sortInsertIfaceRef" ((PVar "x") (PCons (PVar "y") (PVar "ys"))) (EIf (EBinOp "<" (EApp (EVar "ifaceSortKey") (EVar "x")) (EApp (EVar "ifaceSortKey") (EVar "y"))) (EBinOp "::" (EVar "x") (EBinOp "::" (EVar "y") (EVar "ys"))) (EIf (EVar "otherwise") (EBinOp "::" (EVar "y") (EApp (EApp (EVar "sortInsertIfaceRef") (EVar "x")) (EVar "ys"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "ownMethodIdent" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Ident")))))
(DFunDef false "ownMethodIdent" ((PList) PWild) (EVar "None"))
(DFunDef false "ownMethodIdent" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest")) (PVar "n")) (EMatch (EApp (EApp (EVar "ownMethodIdent") (EListLit (EVar "d"))) (EVar "n")) (arm (PCon "Some" (PVar "i")) () (EApp (EVar "Some") (EVar "i"))) (arm (PCon "None") () (EApp (EApp (EVar "ownMethodIdent") (EVar "rest")) (EVar "n")))))
(DFunDef false "ownMethodIdent" ((PCons (PRec "DInterface" ((rf "methods" None) (rf "ifaceOrigin" None)) true) (PVar "rest")) (PVar "n")) (EIf (EApp (EApp (EVar "contains") (EVar "n")) (EApp (EVar "ifaceMethodNames") (EVar "methods"))) (EApp (EApp (EApp (EVar "mkIdent") (EVar "NsMethod")) (EVar "ifaceOrigin")) (EVar "n")) (EApp (EApp (EVar "ownMethodIdent") (EVar "rest")) (EVar "n"))))
(DFunDef false "ownMethodIdent" ((PCons PWild (PVar "rest")) (PVar "n")) (EApp (EApp (EVar "ownMethodIdent") (EVar "rest")) (EVar "n")))
(DTypeSig false "usePathAdmitsDecl" (TyFun (TyCon "UsePath") (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "IfaceRef") (TyCon "Bool"))))))
(DFunDef false "usePathAdmitsDecl" ((PVar "path") (PVar "wide") (PVar "n") (PVar "iface")) (EBinOp "||" (EApp (EApp (EVar "usePathBindsName") (EVar "path")) (EVar "n")) (EBinOp "&&" (EVar "wide") (EApp (EApp (EVar "usePathBindsName") (EVar "path")) (EFieldAccess (EVar "iface") "irName")))))
(DTypeSig false "usePathBindsName" (TyFun (TyCon "UsePath") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "usePathBindsName" ((PVar "path") (PVar "n")) (EMatch (EApp (EVar "importedBindings") (EVar "path")) (arm (PCon "None") () (EVar "True")) (arm (PCon "Some" (PVar "bs")) () (EApp (EApp (EVar "contains") (EVar "n")) (EApp (EApp (EVar "map") (EVar "snd")) (EVar "bs"))))))
(DTypeSig false "exportsIdentFor" (TyFun (TyCon "String") (TyFun (TyCon "Ident") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ident"))) (TyCon "Bool")))))
(DFunDef false "exportsIdentFor" (PWild PWild (PList)) (EVar "False"))
(DFunDef false "exportsIdentFor" ((PVar "n") (PVar "ident") (PCons (PTuple (PVar "en") (PVar "ei")) (PVar "rest"))) (EIf (EBinOp "&&" (EBinOp "==" (EVar "en") (EVar "n")) (EBinOp "==" (EVar "ei") (EVar "ident"))) (EVar "True") (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "exportsIdentFor") (EVar "n")) (EVar "ident")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "memberSuffix" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "memberSuffix" ((PVar "n")) (EBinOp "++" (ELit (LString "__")) (EVar "n")))
(DTypeSig true "resolveMemberRows" (TyFun (TyTuple (TyCon "String") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a"))))))
(DFunDef false "resolveMemberRows" ((PTuple (PVar "origin") (PVar "local")) (PVar "depRows")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "origin")) (EVar "depRows")) (arm (PCon "Some" (PVar "s")) () (EListLit (ETuple (EVar "local") (EVar "s")))) (arm (PCon "None") () (EApp (EApp (EVar "filter") (ELam ((PVar "kv")) (EApp (EApp (EVar "endsWith") (EApp (EVar "memberSuffix") (EVar "origin"))) (EApp (EVar "fst") (EVar "kv"))))) (EVar "depRows")))))
(DTypeSig true "importFormRows" (TyFun (TyCon "UsePath") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a"))))))
(DFunDef false "importFormRows" ((PVar "path") (PVar "depRows")) (EMatch (EApp (EVar "importedBindings") (EVar "path")) (arm (PCon "None") () (EVar "depRows")) (arm (PCon "Some" (PVar "bindings")) () (EApp (EApp (EVar "flatMap") (ELam ((PVar "b")) (EApp (EApp (EVar "resolveMemberRows") (EVar "b")) (EVar "depRows")))) (EVar "bindings")))))
(DTypeSig false "methodCandsAt" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "MethodEnv") (TyApp (TyCon "List") (TyCon "MethodRow"))))))
(DFunDef false "methodCandsAt" ((PVar "n") (PVar "cur") (PVar "env")) (EApp (EApp (EVar "filterList") (ELam ((PVar "r")) (EApp (EApp (EVar "declEnvVisibleAt") (EVar "cur")) (EFieldAccess (EVar "r") "mrOrd")))) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "n")) (EFieldAccess (EVar "env") "meByName")))))
(DTypeSig true "methodNameDeclaredAt" (TyFun (TyCon "Int") (TyFun (TyCon "MethodEnv") (TyFun (TyCon "String") (TyCon "Bool")))))
(DFunDef false "methodNameDeclaredAt" ((PVar "cur") (PVar "env") (PVar "n")) (EApp (EVar "isNonEmptyL") (EApp (EApp (EApp (EVar "methodCandsAt") (EVar "n")) (EVar "cur")) (EVar "env"))))
(DTypeSig false "methodScopeAt" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "DeclEnvs") (TyCon "MethodScope"))))))))
(DFunDef false "methodScopeAt" ((PVar "gctx") (PVar "standalone") (PVar "prog") (PVar "n") (PVar "cur") (PVar "envs")) (EMatch (EApp (EApp (EApp (EVar "methodCandsAt") (EVar "n")) (EVar "cur")) (EFieldAccess (EVar "envs") "deMethods")) (arm (PList) () (EVar "MsAbsent")) (arm (PList (PVar "only")) () (EApp (EVar "MsOne") (EVar "only"))) (arm (PVar "cs") () (EApp (EApp (EApp (EApp (EApp (EVar "methodOwnScope") (EVar "gctx")) (EVar "standalone")) (EVar "prog")) (EVar "n")) (EVar "cs")))))
(DTypeSig false "methodOwnScope" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "MethodRow")) (TyCon "MethodScope")))))))
(DFunDef false "methodOwnScope" ((PVar "gctx") (PVar "standalone") (PVar "prog") (PVar "n") (PVar "cs")) (EMatch (EApp (EApp (EVar "ownMethodIdent") (EVar "prog")) (EVar "n")) (arm (PCon "Some" (PVar "ident")) () (EMatch (EApp (EApp (EVar "methodRowById") (EVar "ident")) (EVar "cs")) (arm (PCon "Some" (PVar "r")) () (EApp (EVar "MsOne") (EVar "r"))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EVar "methodImportedScope") (EVar "gctx")) (EVar "standalone")) (EVar "prog")) (EVar "n")) (EVar "cs"))))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EVar "methodImportedScope") (EVar "gctx")) (EVar "standalone")) (EVar "prog")) (EVar "n")) (EVar "cs")))))
(DTypeSig false "methodImportedScope" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "MethodRow")) (TyCon "MethodScope")))))))
(DFunDef false "methodImportedScope" ((PVar "gctx") (PVar "standalone") (PVar "prog0") (PVar "n") (PVar "cs")) (EBlock (DoLet false false (PVar "prog") (EApp (EVar "writtenImportsOf") (EVar "prog0"))) (DoExpr (EMatch (EApp (EApp (EVar "filterList") (ELam ((PVar "r")) (EApp (EApp (EApp (EApp (EVar "methodCandImported") (EVar "gctx")) (EVar "prog")) (EVar "n")) (EApp (EVar "methodRowCand") (EVar "r"))))) (EVar "cs")) (arm (PList (PVar "only")) () (EApp (EVar "MsOne") (EVar "only"))) (arm (PList) () (EMatch (EIf (EVar "standalone") (EVar "None") (EApp (EApp (EVar "methodPreludeRow") (EVar "n")) (EVar "cs"))) (arm (PCon "Some" (PVar "r")) () (EApp (EVar "MsOne") (EVar "r"))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "filterList") (ELam ((PVar "r")) (EApp (EApp (EApp (EApp (EVar "methodCandAdmitted") (EVar "gctx")) (EVar "prog")) (EVar "n")) (EApp (EVar "methodRowCand") (EVar "r"))))) (EVar "cs")) (arm (PList (PVar "only")) () (EApp (EVar "MsOne") (EVar "only"))) (arm (PVar "rung2") () (EApp (EApp (EApp (EApp (EApp (EVar "methodUndecided") (EVar "gctx")) (EVar "prog")) (EVar "n")) (EVar "cs")) (EVar "rung2"))))))) (arm (PVar "rung1") () (EApp (EApp (EApp (EApp (EApp (EVar "methodUndecided") (EVar "gctx")) (EVar "prog")) (EVar "n")) (EVar "cs")) (EVar "rung1")))))))
(DTypeSig false "writtenImportsOf" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "writtenImportsOf" ((PVar "prog")) (EMatch (EApp (EVar "aliasImportSites") (EVar "prog")) (arm (PList) () (EVar "prog")) (arm (PVar "sites") () (EApp (EApp (EVar "filterList") (ELam ((PVar "d")) (EApp (EVar "not") (EApp (EApp (EVar "isAliasMethodImport") (EVar "sites")) (EVar "d"))))) (EVar "prog")))))
(DTypeSig false "aliasImportSites" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Loc")))))
(DFunDef false "aliasImportSites" ((PList)) (EListLit))
(DFunDef false "aliasImportSites" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EBinOp "++" (EApp (EVar "aliasImportSites") (EListLit (EVar "d"))) (EApp (EVar "aliasImportSites") (EVar "rest"))))
(DFunDef false "aliasImportSites" ((PCons (PCon "DUse" PWild (PCon "UseAlias" (PVar "quals") PWild) (PVar "loc")) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "quals") (EVar "loc")) (EApp (EVar "aliasImportSites") (EVar "rest"))))
(DFunDef false "aliasImportSites" ((PCons PWild (PVar "rest"))) (EApp (EVar "aliasImportSites") (EVar "rest")))
(DTypeSig false "isAliasMethodImport" (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Loc"))) (TyFun (TyCon "Decl") (TyCon "Bool"))))
(DFunDef false "isAliasMethodImport" ((PVar "sites") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EVar "isAliasMethodImport") (EVar "sites")) (EVar "d")))
(DFunDef false "isAliasMethodImport" ((PVar "sites") (PCon "DUse" PWild (PCon "UseGroup" (PVar "quals") PWild) (PVar "loc"))) (EApp (EApp (EVar "anyList") (ELam ((PVar "s")) (EBinOp "&&" (EBinOp "==" (EApp (EVar "fst") (EVar "s")) (EVar "quals")) (EApp (EApp (EVar "locEq") (EApp (EVar "snd") (EVar "s"))) (EVar "loc"))))) (EVar "sites")))
(DFunDef false "isAliasMethodImport" (PWild PWild) (EVar "False"))
(DTypeSig false "methodUndecided" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "MethodRow")) (TyFun (TyApp (TyCon "List") (TyCon "MethodRow")) (TyCon "MethodScope")))))))
(DFunDef false "methodUndecided" ((PVar "gctx") (PVar "prog") (PVar "n") (PVar "cs") (PList)) (EMatch (EApp (EApp (EVar "methodPreludeRow") (EVar "n")) (EVar "cs")) (arm (PCon "Some" (PVar "r")) () (EApp (EVar "MsOne") (EVar "r"))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "methodAliasedScope") (EVar "gctx")) (EVar "prog")) (EVar "n")) (EVar "cs")))))
(DFunDef false "methodUndecided" ((PVar "_gctx") PWild PWild PWild (PVar "admitted")) (EApp (EVar "MsMany") (EApp (EVar "sortIfaceRefs") (EApp (EApp (EVar "map") (EVar "methodRowIface")) (EVar "admitted")))))
(DTypeSig false "methodAliasedScope" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "MethodRow")) (TyCon "MethodScope"))))))
(DFunDef false "methodAliasedScope" ((PVar "gctx") (PVar "prog") (PVar "n") (PVar "cs")) (EBlock (DoLet false false (PVar "sites") (EApp (EVar "aliasImportSites") (EVar "prog"))) (DoExpr (EMatch (EApp (EApp (EVar "filterList") (ELam ((PVar "r")) (EApp (EApp (EApp (EApp (EVar "aliasWitnessesMethod") (EVar "gctx")) (EVar "sites")) (EVar "n")) (EFieldAccess (EVar "r") "mrIdent")))) (EVar "cs")) (arm (PList) () (EVar "MsAbsent")) (arm (PList (PVar "only")) () (EApp (EVar "MsOne") (EVar "only"))) (arm (PVar "aliased") () (EApp (EVar "MsMany") (EApp (EVar "sortIfaceRefs") (EApp (EApp (EVar "map") (EVar "methodRowIface")) (EVar "aliased")))))))))
(DTypeSig false "aliasWitnessesMethod" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Loc"))) (TyFun (TyCon "String") (TyFun (TyCon "Ident") (TyCon "Bool"))))))
(DFunDef false "aliasWitnessesMethod" ((PVar "gctx") (PVar "sites") (PVar "n") (PVar "ident")) (EApp (EApp (EVar "anyList") (ELam ((PVar "s")) (EBlock (DoLet false false (PVar "dep") (EApp (EVar "joinDot") (EApp (EVar "fst") (EVar "s")))) (DoExpr (EBinOp "&&" (EBinOp "/=" (EVar "dep") (ELit (LString "core"))) (EApp (EApp (EApp (EApp (EVar "depExportsMethodIdent") (EVar "gctx")) (EVar "dep")) (EVar "n")) (EVar "ident"))))))) (EVar "sites")))
(DTypeSig false "methodScopeHere" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyCon "MethodScope"))))
(DFunDef false "methodScopeHere" ((PVar "mctx") (PVar "n")) (EMatch (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "methodScopeCtxRef") "value") (arm (PCon "None") () (EVar "MsAbsent")) (arm (PCon "Some" (PTuple (PVar "prog") (PVar "cur"))) () (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "methodScopeMemoRef") "value")) (arm (PCon "Some" (PVar "s")) () (EVar "s")) (arm (PCon "None") () (EBlock (DoLet false false (PVar "s") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "methodScopeAt") (EFieldAccess (EVar "mctx") "mcGraph")) (EApp (EApp (EVar "omHasKey") (EVar "n")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "standaloneValuesRef") "value"))) (EVar "prog")) (EVar "n")) (EVar "cur")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "declEnvsRef") "value"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "methodScopeMemoRef")) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (EVar "s")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "methodScopeMemoRef") "value")))) (DoExpr (EVar "s"))))))))
(DTypeSig true "methodEntryHere" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "MethodEntry")))))
(DFunDef false "methodEntryHere" ((PVar "mctx") (PVar "n")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "methodAliasEntriesRef") "value")) (arm (PCon "Some" (PVar "e")) () (EApp (EVar "Some") (EVar "e"))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "methodScopeHere") (EVar "mctx")) (EVar "n")) (arm (PCon "MsOne" (PVar "r")) () (EApp (EVar "Some") (EFieldAccess (EVar "r") "mrEntry"))) (arm PWild () (EVar "None"))))))
(DTypeSig true "methodIfaceHere" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "IfaceRef")))))
(DFunDef false "methodIfaceHere" ((PVar "mctx") (PVar "n")) (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "iface") PWild PWild PWild)) (EVar "iface"))) (EApp (EApp (EVar "methodEntryHere") (EVar "mctx")) (EVar "n"))))
(DTypeSig true "methodAdmittedHere" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "IfaceRef")))))
(DFunDef false "methodAdmittedHere" ((PVar "mctx") (PVar "n")) (EMatch (EApp (EApp (EVar "methodScopeHere") (EVar "mctx")) (EVar "n")) (arm (PCon "MsMany" (PVar "ifs")) () (EVar "ifs")) (arm PWild () (EListLit))))
(DTypeSig true "methodAdmissionHere" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "IfaceRef"))))))
(DFunDef false "methodAdmissionHere" ((PVar "mctx") (PVar "n")) (EMatch (EApp (EApp (EVar "methodIfaceHere") (EVar "mctx")) (EVar "n")) (arm (PCon "Some" (PVar "iface")) () (EApp (EVar "Some") (EListLit (EVar "iface")))) (arm (PCon "None") () (EIf (EApp (EVar "isEmptyL") (EApp (EApp (EVar "methodAdmittedHere") (EVar "mctx")) (EVar "n"))) (EVar "None") (EApp (EVar "Some") (EListLit))))))
(DTypeSig true "methodVisibleHere" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "MethodRow")))))
(DFunDef false "methodVisibleHere" ((PVar "mctx") (PVar "n")) (EMatch (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "methodScopeCtxRef") "value") (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PTuple PWild (PVar "cur"))) () (EApp (EApp (EApp (EVar "methodCandsAt") (EVar "n")) (EVar "cur")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "declEnvsRef") "value") "deMethods")))))
(DTypeSig true "methodDispatchIdx" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "methodDispatchIdx" ((PVar "mctx") (PVar "name")) (EApp (EApp (EApp (EVar "dispatchIdxScoped") (EVar "mctx")) (EVar "name")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "methodDispatchIdxByIdRef") "value")))
(DTypeSig true "argDispatchOf" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "argDispatchOf" ((PVar "mctx") (PVar "name")) (EApp (EApp (EApp (EVar "dispatchIdxScoped") (EVar "mctx")) (EVar "name")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "argDispatchIdxByIdRef") "value")))
(DTypeSig false "dispatchIdxScoped" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "IfaceRef") (TyCon "String")) (TyCon "Int"))) (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "dispatchIdxScoped" ((PVar "mctx") (PVar "name") (PVar "byId")) (EMatch (EApp (EApp (EVar "methodIfaceHere") (EVar "mctx")) (EVar "name")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "iface")) () (EApp (EApp (EApp (EVar "lookupIdxById") (EVar "iface")) (EApp (EApp (EVar "originMethodName") (EVar "mctx")) (EVar "name"))) (EVar "byId")))))
(DTypeSig true "ieImplExistsForHead" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ImplEnv") (TyFun (TyCon "String") (TyFun (TyCon "HeadKey") (TyCon "Bool"))))))
(DFunDef false "ieImplExistsForHead" ((PVar "mctx") (PVar "env") (PVar "name") (PVar "hk")) (EApp (EApp (EApp (EApp (EApp (EVar "ieImplExistsForHeadOf") (EVar "mctx")) (EVar "env")) (EVar "name")) (EVar "hk")) (EApp (EApp (EVar "methodAdmissionHere") (EVar "mctx")) (EVar "name"))))
(DTypeSig true "admittedIfaceWord" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "admittedIfaceWord" ((PVar "mctx") (PVar "name")) (EMatch (EApp (EApp (EVar "methodIfaceHere") (EVar "mctx")) (EVar "name")) (arm (PCon "Some" (PVar "iface")) () (EApp (EApp (EVar "ifaceWordOf") (EFieldAccess (EVar "iface") "irOrigin")) (EFieldAccess (EVar "iface") "irName"))) (arm (PCon "None") () (ELit (LString "")))))
(DTypeSig true "aliasQualifiedMethodEntries" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "OrdMap") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "String")) (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind")))))) (TyApp (TyCon "OrdMap") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "String")) (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind"))))))))))
(DFunDef false "aliasQualifiedMethodEntries" ((PVar "mctx") (PVar "prog") (PVar "tab")) (EBlock (DoLet false false (PVar "grouped") (EApp (EApp (EVar "aliasMethodKeyGroup") (EApp (EApp (EVar "aliasMethodKeyCands") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "prog"))) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "aliasMethodKeyApply") (EVar "mctx")) (EVar "grouped")) (EApp (EVar "omKeys") (EVar "grouped"))) (EVar "tab")))))
(DTypeSig false "aliasMethodKeyCands" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String") (TyCon "Ident") (TyCon "Loc"))))))
(DFunDef false "aliasMethodKeyCands" ((PVar "gctx") (PVar "prog")) (EBinOp "++" (EApp (EApp (EVar "useKeyCands") (EApp (EVar "moduleAliasKeys") (EVar "gctx"))) (EVar "prog")) (EApp (EApp (EVar "memberAliasCands") (EVar "gctx")) (EVar "prog"))))
(DTypeSig true "memberAliasCands" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String") (TyCon "Ident") (TyCon "Loc"))))))
(DFunDef false "memberAliasCands" ((PVar "gctx") (PVar "prog")) (EBlock (DoLet false false (PVar "own") (EApp (EApp (EVar "namesToSet") (EApp (EVar "declTopFnNames") (EVar "prog"))) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EVar "filterList") (ELam ((PVar "r")) (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EApp (EVar "aliasRowKey") (EVar "r"))) (EVar "own"))))) (EApp (EApp (EVar "useKeyCands") (EApp (EVar "memberAliasKeys") (EVar "gctx"))) (EVar "prog"))))))
(DTypeSig true "useKeyCands" (TyFun (TyFun (TyCon "UsePath") (TyFun (TyCon "Loc") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String") (TyCon "Ident") (TyCon "Loc"))))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String") (TyCon "Ident") (TyCon "Loc"))))))
(DFunDef false "useKeyCands" (PWild (PList)) (EListLit))
(DFunDef false "useKeyCands" ((PVar "f") (PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "useKeyCands") (EVar "f")) (EListLit (EVar "d"))) (EApp (EApp (EVar "useKeyCands") (EVar "f")) (EVar "rest"))))
(DFunDef false "useKeyCands" ((PVar "f") (PCons (PCon "DUse" PWild (PVar "path") (PVar "loc")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "f") (EVar "path")) (EVar "loc")) (EApp (EApp (EVar "useKeyCands") (EVar "f")) (EVar "rest"))))
(DFunDef false "useKeyCands" ((PVar "f") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "useKeyCands") (EVar "f")) (EVar "rest")))
(DTypeSig true "moduleAliasKeys" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "UsePath") (TyFun (TyCon "Loc") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String") (TyCon "Ident") (TyCon "Loc")))))))
(DFunDef false "moduleAliasKeys" ((PVar "gctx") (PAs "path" (PCon "UseAlias" PWild (PVar "a"))) (PVar "loc")) (EApp (EApp (EApp (EApp (EVar "aliasMethodKeysFor") (EVar "gctx")) (EVar "a")) (EApp (EVar "useModId") (EVar "path"))) (EVar "loc")))
(DFunDef false "moduleAliasKeys" ((PVar "_gctx") PWild PWild) (EListLit))
(DTypeSig false "memberAliasKeys" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "UsePath") (TyFun (TyCon "Loc") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String") (TyCon "Ident") (TyCon "Loc")))))))
(DFunDef false "memberAliasKeys" ((PVar "gctx") (PAs "path" (PCon "UseGroup" PWild (PVar "ms"))) (PVar "loc")) (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EVar "memberAliasMethodKeys") (EVar "gctx")) (EApp (EVar "useModId") (EVar "path"))) (EVar "loc"))) (EVar "ms")))
(DFunDef false "memberAliasKeys" ((PVar "_gctx") PWild PWild) (EListLit))
(DTypeSig false "memberAliasMethodKeys" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyFun (TyCon "Loc") (TyFun (TyCon "UseMember") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String") (TyCon "Ident") (TyCon "Loc"))))))))
(DFunDef false "memberAliasMethodKeys" ((PVar "gctx") (PVar "mid") (PVar "loc") (PVar "m")) (EMatch (EApp (EVar "useMemberAlias") (EVar "m")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "local")) () (EMatch (EApp (EApp (EVar "omLookup") (EVar "mid")) (EApp (EApp (EVar "methodExportsIndex") (EVar "gctx")) (ELit LUnit))) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "rows")) () (EBlock (DoLet false false (PVar "origin") (EApp (EVar "useMemberOrigin") (EVar "m"))) (DoExpr (EApp (EApp (EVar "map") (ELam ((PVar "r")) (ETuple (EVar "local") (EVar "origin") (EVar "mid") (EApp (EVar "snd") (EVar "r")) (EVar "loc")))) (EApp (EApp (EVar "filterList") (ELam ((PVar "r")) (EBinOp "==" (EApp (EVar "fst") (EVar "r")) (EVar "origin")))) (EVar "rows"))))))))))
(DTypeSig false "aliasMethodKeysFor" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Loc") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String") (TyCon "Ident") (TyCon "Loc"))))))))
(DFunDef false "aliasMethodKeysFor" ((PVar "gctx") (PVar "a") (PVar "mid") (PVar "loc")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "mid")) (EApp (EApp (EVar "methodExportsIndex") (EVar "gctx")) (ELit LUnit))) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "rows")) () (EApp (EApp (EApp (EApp (EVar "aliasMethodKeyRows") (EVar "a")) (EVar "mid")) (EVar "loc")) (EVar "rows")))))
(DTypeSig false "aliasMethodKeyRows" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Loc") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ident"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String") (TyCon "Ident") (TyCon "Loc"))))))))
(DFunDef false "aliasMethodKeyRows" (PWild PWild PWild (PList)) (EListLit))
(DFunDef false "aliasMethodKeyRows" ((PVar "a") (PVar "mid") (PVar "loc") (PCons (PTuple (PVar "mname") (PVar "ident")) (PVar "rest"))) (EBinOp "::" (ETuple (EApp (EApp (EVar "qualifiedLocal") (EVar "a")) (EVar "mname")) (EVar "mname") (EVar "mid") (EVar "ident") (EVar "loc")) (EApp (EApp (EApp (EApp (EVar "aliasMethodKeyRows") (EVar "a")) (EVar "mid")) (EVar "loc")) (EVar "rest"))))
(DTypeSig false "aliasMethodKeyGroup" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String") (TyCon "Ident") (TyCon "Loc"))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String") (TyCon "Ident") (TyCon "Loc")))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String") (TyCon "Ident") (TyCon "Loc")))))))
(DFunDef false "aliasMethodKeyGroup" ((PList) (PVar "g")) (EVar "g"))
(DFunDef false "aliasMethodKeyGroup" ((PCons (PVar "r") (PVar "rest")) (PVar "g")) (EBlock (DoLet false false (PVar "k") (EApp (EVar "aliasRowKey") (EVar "r"))) (DoExpr (EApp (EApp (EVar "aliasMethodKeyGroup") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "k")) (EBinOp "++" (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "k")) (EVar "g"))) (EListLit (EVar "r")))) (EVar "g"))))))
(DTypeSig false "aliasMethodKeyApply" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String") (TyCon "Ident") (TyCon "Loc")))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "String")) (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind")))))) (TyApp (TyCon "OrdMap") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "String")) (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind")))))))))))
(DFunDef false "aliasMethodKeyApply" ((PVar "_mctx") PWild (PList) (PVar "tab")) (EVar "tab"))
(DFunDef false "aliasMethodKeyApply" ((PVar "mctx") (PVar "g") (PCons (PVar "k") (PVar "rest")) (PVar "tab")) (EBlock (DoLet false false (PVar "hits") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "k")) (EVar "g")))) (DoLet false false (PVar "tab2") (EMatch (EApp (EApp (EVar "aliasRowIdents") (EVar "hits")) (EListLit)) (arm (PList) () (EVar "tab")) (arm (PList PWild) () (EApp (EApp (EApp (EApp (EVar "aliasMethodKeyEntry") (EVar "mctx")) (EVar "k")) (EVar "hits")) (EVar "tab"))) (arm PWild () (EBlock (DoExpr (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOnceAt") (EVar "mctx")) (EVar "TAmbiguousAliasMethod")) (EApp (EVar "aliasRowLastLoc") (EVar "hits"))) (EApp (EApp (EVar "aliasAmbiguityMsg") (EVar "k")) (EVar "hits")))) (DoExpr (EVar "tab")))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "aliasMethodKeyApply") (EVar "mctx")) (EVar "g")) (EVar "rest")) (EVar "tab2")))))
(DTypeSig false "aliasMethodKeyEntry" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String") (TyCon "Ident") (TyCon "Loc"))) (TyFun (TyApp (TyCon "OrdMap") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "String")) (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind")))))) (TyApp (TyCon "OrdMap") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "String")) (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind")))))))))))
(DFunDef false "aliasMethodKeyEntry" ((PVar "_mctx") PWild (PList) (PVar "tab")) (EVar "tab"))
(DFunDef false "aliasMethodKeyEntry" ((PVar "mctx") (PVar "k") (PCons (PTuple PWild (PVar "mname") PWild (PVar "ident") PWild) PWild) (PVar "tab")) (EMatch (EApp (EApp (EVar "methodRowById") (EVar "ident")) (EApp (EApp (EVar "methodVisibleHere") (EVar "mctx")) (EVar "mname"))) (arm (PCon "None") () (EVar "tab")) (arm (PCon "Some" (PVar "r")) () (EApp (EApp (EApp (EVar "omInsert") (EVar "k")) (EFieldAccess (EVar "r") "mrEntry")) (EVar "tab")))))
(DTypeSig false "aliasRowKey" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyCon "String") (TyCon "Ident") (TyCon "Loc")) (TyCon "String")))
(DFunDef false "aliasRowKey" ((PTuple (PVar "k") PWild PWild PWild PWild)) (EVar "k"))
(DTypeSig true "aliasMethodSpellings" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "aliasMethodSpellings" ((PVar "gctx") (PVar "prog")) (EApp (EApp (EVar "map") (EVar "aliasRowSpelling")) (EApp (EApp (EVar "aliasMethodKeyCands") (EVar "gctx")) (EVar "prog"))))
(DTypeSig true "aliasRowSpelling" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyCon "String") (TyCon "Ident") (TyCon "Loc")) (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "aliasRowSpelling" ((PTuple (PVar "k") (PVar "mname") PWild PWild PWild)) (ETuple (EVar "k") (EVar "mname")))
(DTypeSig false "aliasRowModule" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyCon "String") (TyCon "Ident") (TyCon "Loc")) (TyCon "String")))
(DFunDef false "aliasRowModule" ((PTuple PWild PWild (PVar "m") PWild PWild)) (EVar "m"))
(DTypeSig false "aliasRowIdents" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String") (TyCon "Ident") (TyCon "Loc"))) (TyFun (TyApp (TyCon "List") (TyCon "Ident")) (TyApp (TyCon "List") (TyCon "Ident")))))
(DFunDef false "aliasRowIdents" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "aliasRowIdents" ((PCons (PTuple PWild PWild PWild (PVar "i") PWild) (PVar "rest")) (PVar "acc")) (EIf (EApp (EApp (EVar "anyList") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EVar "i")))) (EVar "acc")) (EApp (EApp (EVar "aliasRowIdents") (EVar "rest")) (EVar "acc")) (EIf (EVar "otherwise") (EApp (EApp (EVar "aliasRowIdents") (EVar "rest")) (EBinOp "++" (EVar "acc") (EListLit (EVar "i")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "aliasRowLastLoc" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String") (TyCon "Ident") (TyCon "Loc"))) (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "aliasRowLastLoc" ((PList)) (EVar "None"))
(DFunDef false "aliasRowLastLoc" ((PList (PTuple PWild PWild PWild PWild (PVar "l")))) (EApp (EVar "Some") (EVar "l")))
(DFunDef false "aliasRowLastLoc" ((PCons PWild (PVar "rest"))) (EApp (EVar "aliasRowLastLoc") (EVar "rest")))
(DTypeSig false "aliasAmbiguityMsg" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String") (TyCon "Ident") (TyCon "Loc"))) (TyCon "String"))))
(DFunDef false "aliasAmbiguityMsg" ((PVar "k") (PVar "hits")) (EBlock (DoLet false false (PVar "mods") (EApp (EApp (EVar "joinWith") (ELit (LString " and "))) (EApp (EApp (EVar "map") (EVar "backticked")) (EApp (EVar "sortUniqS") (EApp (EApp (EVar "map") (EVar "aliasRowModule")) (EVar "hits")))))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "display") (EVar "k"))) (ELit (LString "` is ambiguous: the alias names more than one module declaring a method `"))) (EApp (EVar "display") (EApp (EVar "aliasRowMethodOf") (EVar "hits")))) (ELit (LString "` ("))) (EApp (EVar "display") (EVar "mods"))) (ELit (LString "); give those imports different alias names"))))))
(DTypeSig false "aliasRowMethodOf" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String") (TyCon "Ident") (TyCon "Loc"))) (TyCon "String")))
(DFunDef false "aliasRowMethodOf" ((PList)) (ELit (LString "")))
(DFunDef false "aliasRowMethodOf" ((PCons (PTuple PWild (PVar "m") PWild PWild PWild) PWild)) (EVar "m"))
(DTypeSig false "methodCandImported" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "Ident") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "String")) (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind")))))) (TyCon "Bool"))))))
(DFunDef false "methodCandImported" ((PVar "gctx") (PVar "prog") (PVar "n") (PVar "c")) (EApp (EApp (EApp (EApp (EApp (EVar "anyUsePathBinds") (EVar "gctx")) (EVar "prog")) (EVar "False")) (EVar "n")) (EVar "c")))
(DTypeSig false "methodCandAdmitted" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "Ident") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "String")) (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind")))))) (TyCon "Bool"))))))
(DFunDef false "methodCandAdmitted" ((PVar "gctx") (PVar "prog") (PVar "n") (PVar "c")) (EApp (EApp (EApp (EApp (EApp (EVar "anyUsePathBinds") (EVar "gctx")) (EVar "prog")) (EVar "True")) (EVar "n")) (EVar "c")))
(DTypeSig false "anyUsePathBinds" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "Ident") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "String")) (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind")))))) (TyCon "Bool")))))))
(DFunDef false "anyUsePathBinds" ((PVar "_gctx") (PList) PWild PWild PWild) (EVar "False"))
(DFunDef false "anyUsePathBinds" ((PVar "gctx") (PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest")) (PVar "wide") (PVar "n") (PVar "c")) (EBinOp "||" (EApp (EApp (EApp (EApp (EApp (EVar "anyUsePathBinds") (EVar "gctx")) (EListLit (EVar "d"))) (EVar "wide")) (EVar "n")) (EVar "c")) (EApp (EApp (EApp (EApp (EApp (EVar "anyUsePathBinds") (EVar "gctx")) (EVar "rest")) (EVar "wide")) (EVar "n")) (EVar "c"))))
(DFunDef false "anyUsePathBinds" ((PVar "gctx") (PCons (PCon "DUse" PWild (PVar "path") PWild) (PVar "rest")) (PVar "wide") (PVar "n") (PVar "c")) (EBinOp "||" (EApp (EApp (EApp (EApp (EApp (EVar "usePathWitnesses") (EVar "gctx")) (EVar "path")) (EVar "wide")) (EVar "n")) (EVar "c")) (EApp (EApp (EApp (EApp (EApp (EVar "anyUsePathBinds") (EVar "gctx")) (EVar "rest")) (EVar "wide")) (EVar "n")) (EVar "c"))))
(DFunDef false "anyUsePathBinds" ((PVar "gctx") (PCons PWild (PVar "rest")) (PVar "wide") (PVar "n") (PVar "c")) (EApp (EApp (EApp (EApp (EApp (EVar "anyUsePathBinds") (EVar "gctx")) (EVar "rest")) (EVar "wide")) (EVar "n")) (EVar "c")))
(DTypeSig false "usePathWitnesses" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "UsePath") (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "Ident") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "String")) (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind")))))) (TyCon "Bool")))))))
(DFunDef false "usePathWitnesses" ((PVar "gctx") (PVar "path") (PVar "wide") (PVar "n") (PTuple (PVar "ident") (PTuple (PVar "iface") PWild PWild PWild))) (EBlock (DoLet false false (PVar "dep") (EApp (EVar "useModId") (EVar "path"))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EBinOp "/=" (EVar "dep") (ELit (LString "core"))) (EApp (EApp (EApp (EApp (EVar "usePathAdmitsDecl") (EVar "path")) (EVar "wide")) (EVar "n")) (EVar "iface"))) (EApp (EApp (EApp (EApp (EVar "depExportsMethodIdent") (EVar "gctx")) (EVar "dep")) (EVar "n")) (EVar "ident"))))))
(DTypeSig false "depExportsMethodIdent" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Ident") (TyCon "Bool"))))))
(DFunDef false "depExportsMethodIdent" ((PVar "gctx") (PVar "dep") (PVar "n") (PVar "ident")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "dep")) (EApp (EApp (EVar "methodExportsIndex") (EVar "gctx")) (ELit LUnit))) (arm (PCon "None") () (EVar "False")) (arm (PCon "Some" (PVar "es")) () (EApp (EApp (EApp (EVar "exportsIdentFor") (EVar "n")) (EVar "ident")) (EVar "es")))))
(DTypeSig true "insertCtorPop" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "SpellingPop") (TyCon "Scheme")) (TyApp (TyCon "SpellingPop") (TyCon "Scheme"))))))
(DFunDef false "insertCtorPop" ((PVar "_env") (PList) (PVar "pop")) (EVar "pop"))
(DFunDef false "insertCtorPop" ((PVar "env") (PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest")) (PVar "pop")) (EApp (EApp (EApp (EVar "insertCtorPop") (EVar "env")) (EVar "rest")) (EApp (EApp (EApp (EVar "insertCtorPop") (EVar "env")) (EListLit (EVar "d"))) (EVar "pop"))))
(DFunDef false "insertCtorPop" ((PVar "env") (PCons (PRec "DData" ((rf "dataName" None) (rf "dataCtors" None) (rf "dataOrigin" None)) true) (PVar "rest")) (PVar "pop")) (EApp (EApp (EApp (EVar "insertCtorPop") (EVar "env")) (EVar "rest")) (EApp (EApp (EApp (EApp (EApp (EVar "insertCtorVariants") (EVar "env")) (EVar "dataName")) (EVar "dataOrigin")) (EVar "dataCtors")) (EVar "pop"))))
(DFunDef false "insertCtorPop" ((PVar "env") (PCons (PRec "DNewtype" ((rf "newtypeName" None) (rf "newtypeCtor" None) (rf "newtypeOrigin" None)) true) (PVar "rest")) (PVar "pop")) (EApp (EApp (EApp (EVar "insertCtorPop") (EVar "env")) (EVar "rest")) (EApp (EApp (EApp (EApp (EApp (EVar "insertCtorRow") (EVar "env")) (EVar "newtypeName")) (EVar "newtypeOrigin")) (EVar "newtypeCtor")) (EVar "pop"))))
(DFunDef false "insertCtorPop" ((PVar "env") (PCons PWild (PVar "rest")) (PVar "pop")) (EApp (EApp (EApp (EVar "insertCtorPop") (EVar "env")) (EVar "rest")) (EVar "pop")))
(DTypeSig false "insertCtorVariants" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyCon "TyConOrigin") (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyFun (TyApp (TyCon "SpellingPop") (TyCon "Scheme")) (TyApp (TyCon "SpellingPop") (TyCon "Scheme"))))))))
(DFunDef false "insertCtorVariants" ((PVar "_env") PWild PWild (PList) (PVar "pop")) (EVar "pop"))
(DFunDef false "insertCtorVariants" ((PVar "env") (PVar "tyName") (PVar "o") (PCons (PCon "Variant" (PVar "cn") PWild) (PVar "rest")) (PVar "pop")) (EApp (EApp (EApp (EApp (EApp (EVar "insertCtorVariants") (EVar "env")) (EVar "tyName")) (EVar "o")) (EVar "rest")) (EApp (EApp (EApp (EApp (EApp (EVar "insertCtorRow") (EVar "env")) (EVar "tyName")) (EVar "o")) (EVar "cn")) (EVar "pop"))))
(DTypeSig false "insertCtorRow" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyCon "TyConOrigin") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "SpellingPop") (TyCon "Scheme")) (TyApp (TyCon "SpellingPop") (TyCon "Scheme"))))))))
(DFunDef false "insertCtorRow" ((PVar "env") (PVar "tyName") (PVar "o") (PVar "cn") (PVar "pop")) (EMatch (EApp (EApp (EVar "lookupCtor") (EVar "env")) (EVar "cn")) (arm (PCon "None") () (EVar "pop")) (arm (PCon "Some" (PVar "s")) () (EApp (EApp (EApp (EApp (EApp (EVar "spInsert") (EApp (EApp (EApp (EVar "mkIdent") (EVar "NsCtor")) (EVar "o")) (EVar "cn"))) (EVar "cn")) (EVar "tyName")) (EVar "s")) (EVar "pop")))))
(DTypeSig true "applyCtorScopeOverrides" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "TcEnv") (TyCon "TcEnv"))))
(DFunDef false "applyCtorScopeOverrides" ((PVar "prog") (PVar "env")) (EBlock (DoLet false false (PVar "pop") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph") "crossRun") "universeCtorPop") "value")) (DoExpr (EApp (EApp (EApp (EApp (EVar "overrideScopedCtors") (EVar "prog")) (EApp (EVar "spRows") (EVar "pop"))) (EApp (EVar "spCollided") (EVar "pop"))) (EVar "env")))))
(DTypeSig false "overrideScopedCtors" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "Ident") (TyCon "String") (TyCon "Scheme")))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "TcEnv") (TyCon "TcEnv"))))))
(DFunDef false "overrideScopedCtors" (PWild PWild (PList) (PVar "env")) (EVar "env"))
(DFunDef false "overrideScopedCtors" ((PVar "prog") (PVar "cands") (PCons (PVar "n") (PVar "rest")) (PVar "env")) (EBlock (DoLet false false (PVar "env2") (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "cands")) (arm (PCon "None") () (EVar "env")) (arm (PCon "Some" (PVar "cs")) () (EMatch (EApp (EApp (EApp (EApp (EVar "scopedCtorEntry") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (EVar "prog")) (EVar "n")) (EVar "cs")) (arm (PCon "None") () (EVar "env")) (arm (PCon "Some" (PVar "s")) () (EApp (EApp (EApp (EVar "addCtor") (EVar "env")) (EVar "n")) (EVar "s"))))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "overrideScopedCtors") (EVar "prog")) (EVar "cands")) (EVar "rest")) (EVar "env2")))))
(DTypeSig false "scopedCtorEntry" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Ident") (TyCon "String") (TyCon "Scheme"))) (TyApp (TyCon "Option") (TyCon "Scheme")))))))
(DFunDef false "scopedCtorEntry" ((PVar "gctx") (PVar "prog") (PVar "n") (PVar "cs")) (EIf (EApp (EApp (EVar "declaresCtorNamed") (EVar "prog")) (EVar "n")) (EVar "None") (EApp (EApp (EApp (EApp (EVar "importedCtorEntry") (EVar "gctx")) (EVar "prog")) (EVar "n")) (EVar "cs"))))
(DTypeSig false "importedCtorEntry" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Ident") (TyCon "String") (TyCon "Scheme"))) (TyApp (TyCon "Option") (TyCon "Scheme")))))))
(DFunDef false "importedCtorEntry" ((PVar "gctx") (PVar "prog") (PVar "n") (PVar "cs")) (EMatch (EApp (EApp (EVar "filterList") (ELam ((PVar "c")) (EApp (EApp (EApp (EApp (EVar "ctorCandImported") (EVar "gctx")) (EVar "prog")) (EVar "n")) (EVar "c")))) (EVar "cs")) (arm (PList (PVar "only")) () (EApp (EVar "Some") (EApp (EVar "ctorCandScheme") (EVar "only")))) (arm PWild () (EVar "None"))))
(DTypeSig false "ctorCandScheme" (TyFun (TyTuple (TyCon "Ident") (TyCon "String") (TyCon "Scheme")) (TyCon "Scheme")))
(DFunDef false "ctorCandScheme" ((PTuple PWild PWild (PVar "s"))) (EVar "s"))
(DTypeSig false "declaresCtorNamed" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "declaresCtorNamed" ((PList) PWild) (EVar "False"))
(DFunDef false "declaresCtorNamed" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest")) (PVar "n")) (EBinOp "||" (EApp (EApp (EVar "declaresCtorNamed") (EListLit (EVar "d"))) (EVar "n")) (EApp (EApp (EVar "declaresCtorNamed") (EVar "rest")) (EVar "n"))))
(DFunDef false "declaresCtorNamed" ((PCons (PVar "d") (PVar "rest")) (PVar "n")) (EBinOp "||" (EApp (EApp (EVar "declCtorNamed") (EVar "n")) (EVar "d")) (EApp (EApp (EVar "declaresCtorNamed") (EVar "rest")) (EVar "n"))))
(DTypeSig false "ctorCandImported" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "Ident") (TyCon "String") (TyCon "Scheme")) (TyCon "Bool"))))))
(DFunDef false "ctorCandImported" ((PVar "gctx") (PVar "prog") (PVar "n") (PTuple (PVar "ident") (PVar "owner") PWild)) (EApp (EApp (EApp (EApp (EApp (EVar "anyUsePathBindsCtor") (EVar "gctx")) (EVar "prog")) (EVar "n")) (EVar "owner")) (EVar "ident")))
(DTypeSig false "anyUsePathBindsCtor" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Ident") (TyCon "Bool")))))))
(DFunDef false "anyUsePathBindsCtor" ((PVar "_gctx") (PList) PWild PWild PWild) (EVar "False"))
(DFunDef false "anyUsePathBindsCtor" ((PVar "gctx") (PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest")) (PVar "n") (PVar "owner") (PVar "ident")) (EBinOp "||" (EApp (EApp (EApp (EApp (EApp (EVar "anyUsePathBindsCtor") (EVar "gctx")) (EListLit (EVar "d"))) (EVar "n")) (EVar "owner")) (EVar "ident")) (EApp (EApp (EApp (EApp (EApp (EVar "anyUsePathBindsCtor") (EVar "gctx")) (EVar "rest")) (EVar "n")) (EVar "owner")) (EVar "ident"))))
(DFunDef false "anyUsePathBindsCtor" ((PVar "gctx") (PCons (PCon "DUse" PWild (PVar "path") PWild) (PVar "rest")) (PVar "n") (PVar "owner") (PVar "ident")) (EBinOp "||" (EApp (EApp (EApp (EApp (EApp (EVar "usePathWitnessesCtor") (EVar "gctx")) (EVar "path")) (EVar "n")) (EVar "owner")) (EVar "ident")) (EApp (EApp (EApp (EApp (EApp (EVar "anyUsePathBindsCtor") (EVar "gctx")) (EVar "rest")) (EVar "n")) (EVar "owner")) (EVar "ident"))))
(DFunDef false "anyUsePathBindsCtor" ((PVar "gctx") (PCons PWild (PVar "rest")) (PVar "n") (PVar "owner") (PVar "ident")) (EApp (EApp (EApp (EApp (EApp (EVar "anyUsePathBindsCtor") (EVar "gctx")) (EVar "rest")) (EVar "n")) (EVar "owner")) (EVar "ident")))
(DTypeSig false "usePathWitnessesCtor" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "UsePath") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Ident") (TyCon "Bool")))))))
(DFunDef false "usePathWitnessesCtor" ((PVar "gctx") (PVar "path") (PVar "n") (PVar "owner") (PVar "ident")) (EBlock (DoLet false false (PVar "dep") (EApp (EVar "useModId") (EVar "path"))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EBinOp "/=" (EVar "dep") (ELit (LString "core"))) (EApp (EApp (EApp (EVar "usePathBindsCtor") (EVar "path")) (EVar "n")) (EVar "owner"))) (EApp (EApp (EApp (EApp (EVar "depExportsCtorIdent") (EVar "gctx")) (EVar "dep")) (EVar "n")) (EVar "ident"))))))
(DTypeSig false "usePathBindsCtor" (TyFun (TyCon "UsePath") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool")))))
(DFunDef false "usePathBindsCtor" ((PCon "UseGroup" PWild (PVar "ms")) (PVar "n") (PVar "owner")) (EApp (EApp (EApp (EVar "anyMemberBindsCtor") (EVar "n")) (EVar "owner")) (EVar "ms")))
(DFunDef false "usePathBindsCtor" ((PCon "UseWild" PWild) PWild PWild) (EVar "True"))
(DFunDef false "usePathBindsCtor" ((PCon "UseAlias" PWild PWild) PWild PWild) (EVar "True"))
(DFunDef false "usePathBindsCtor" (PWild PWild PWild) (EVar "False"))
(DTypeSig false "anyMemberBindsCtor" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "UseMember")) (TyCon "Bool")))))
(DFunDef false "anyMemberBindsCtor" (PWild PWild (PList)) (EVar "False"))
(DFunDef false "anyMemberBindsCtor" ((PVar "n") (PVar "owner") (PCons (PVar "m") (PVar "rest"))) (EBinOp "||" (EApp (EApp (EApp (EVar "memberBindsCtorName") (EVar "n")) (EVar "owner")) (EVar "m")) (EApp (EApp (EApp (EVar "anyMemberBindsCtor") (EVar "n")) (EVar "owner")) (EVar "rest"))))
(DTypeSig true "memberBindsCtorName" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "UseMember") (TyCon "Bool")))))
(DFunDef false "memberBindsCtorName" ((PVar "n") (PVar "owner") (PCon "UseMember" (PVar "mn") (PVar "ctors") PWild PWild)) (EBinOp "||" (EBinOp "==" (EVar "mn") (EVar "n")) (EBinOp "&&" (EVar "ctors") (EBinOp "==" (EVar "mn") (EVar "owner")))))
(DTypeSig false "depExportsCtorIdent" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Ident") (TyCon "Bool"))))))
(DFunDef false "depExportsCtorIdent" ((PVar "gctx") (PVar "dep") (PVar "n") (PVar "ident")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "dep")) (EApp (EApp (EVar "ctorExportsIndex") (EVar "gctx")) (ELit LUnit))) (arm (PCon "None") () (EVar "False")) (arm (PCon "Some" (PVar "es")) () (EApp (EApp (EApp (EVar "exportsCtorIdentFor") (EVar "n")) (EVar "ident")) (EVar "es")))))
(DTypeSig false "exportsCtorIdentFor" (TyFun (TyCon "String") (TyFun (TyCon "Ident") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Ident"))) (TyCon "Bool")))))
(DFunDef false "exportsCtorIdentFor" (PWild PWild (PList)) (EVar "False"))
(DFunDef false "exportsCtorIdentFor" ((PVar "n") (PVar "ident") (PCons (PTuple (PVar "cn") PWild (PVar "ci")) (PVar "rest"))) (EIf (EBinOp "&&" (EBinOp "==" (EVar "cn") (EVar "n")) (EBinOp "==" (EVar "ci") (EVar "ident"))) (EVar "True") (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "exportsCtorIdentFor") (EVar "n")) (EVar "ident")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "insertRecordPop" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "SpellingPop") (TyCon "RecordInfo")) (TyApp (TyCon "SpellingPop") (TyCon "RecordInfo"))))))
(DFunDef false "insertRecordPop" ((PVar "_mctx") (PList) (PVar "pop")) (EVar "pop"))
(DFunDef false "insertRecordPop" ((PVar "mctx") (PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest")) (PVar "pop")) (EApp (EApp (EApp (EVar "insertRecordPop") (EVar "mctx")) (EVar "rest")) (EApp (EApp (EApp (EVar "insertRecordPop") (EVar "mctx")) (EListLit (EVar "d"))) (EVar "pop"))))
(DFunDef false "insertRecordPop" ((PVar "mctx") (PCons (PRec "DData" ((rf "dataName" None) (rf "dataCtors" None) (rf "dataOrigin" None)) true) (PVar "rest")) (PVar "pop")) (EApp (EApp (EApp (EVar "insertRecordPop") (EVar "mctx")) (EVar "rest")) (EApp (EApp (EApp (EApp (EApp (EVar "insertRecordVariants") (EVar "mctx")) (EVar "dataName")) (EVar "dataOrigin")) (EVar "dataCtors")) (EVar "pop"))))
(DFunDef false "insertRecordPop" ((PVar "mctx") (PCons PWild (PVar "rest")) (PVar "pop")) (EApp (EApp (EApp (EVar "insertRecordPop") (EVar "mctx")) (EVar "rest")) (EVar "pop")))
(DTypeSig false "insertRecordVariants" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "TyConOrigin") (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyFun (TyApp (TyCon "SpellingPop") (TyCon "RecordInfo")) (TyApp (TyCon "SpellingPop") (TyCon "RecordInfo"))))))))
(DFunDef false "insertRecordVariants" ((PVar "_mctx") PWild PWild (PList) (PVar "pop")) (EVar "pop"))
(DFunDef false "insertRecordVariants" ((PVar "mctx") (PVar "tyName") (PVar "o") (PCons (PCon "Variant" (PVar "cn") (PCon "ConNamed" PWild PWild)) (PVar "rest")) (PVar "pop")) (EApp (EApp (EApp (EApp (EApp (EVar "insertRecordVariants") (EVar "mctx")) (EVar "tyName")) (EVar "o")) (EVar "rest")) (EApp (EApp (EApp (EApp (EApp (EVar "insertRecordRow") (EVar "mctx")) (EVar "tyName")) (EVar "o")) (EVar "cn")) (EVar "pop"))))
(DFunDef false "insertRecordVariants" ((PVar "mctx") (PVar "tyName") (PVar "o") (PCons PWild (PVar "rest")) (PVar "pop")) (EApp (EApp (EApp (EApp (EApp (EVar "insertRecordVariants") (EVar "mctx")) (EVar "tyName")) (EVar "o")) (EVar "rest")) (EVar "pop")))
(DTypeSig false "insertRecordRow" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "TyConOrigin") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "SpellingPop") (TyCon "RecordInfo")) (TyApp (TyCon "SpellingPop") (TyCon "RecordInfo"))))))))
(DFunDef false "insertRecordRow" ((PVar "mctx") (PVar "tyName") (PVar "o") (PVar "cn") (PVar "pop")) (EMatch (EApp (EApp (EVar "lookupRecordByName") (EVar "mctx")) (EVar "cn")) (arm (PCon "None") () (EVar "pop")) (arm (PCon "Some" (PVar "ri")) () (EApp (EApp (EApp (EApp (EApp (EVar "spInsert") (EApp (EApp (EApp (EVar "mkIdent") (EVar "NsCtor")) (EVar "o")) (EVar "cn"))) (EVar "cn")) (EVar "tyName")) (EVar "ri")) (EVar "pop")))))
(DTypeSig true "applyRecordScopeOverrides" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Unit"))))
(DFunDef false "applyRecordScopeOverrides" ((PVar "mctx") (PVar "prog")) (EBlock (DoLet false false (PVar "pop") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "crossRun") "universeRecordPop") "value")) (DoExpr (EApp (EApp (EApp (EApp (EVar "overrideScopedRecords") (EVar "mctx")) (EVar "prog")) (EApp (EVar "spRows") (EVar "pop"))) (EApp (EVar "spCollided") (EVar "pop"))))))
(DTypeSig false "overrideScopedRecords" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "Ident") (TyCon "String") (TyCon "RecordInfo")))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Unit"))))))
(DFunDef false "overrideScopedRecords" ((PVar "_mctx") PWild PWild (PList)) (ELit LUnit))
(DFunDef false "overrideScopedRecords" ((PVar "mctx") (PVar "prog") (PVar "cands") (PCons (PVar "n") (PVar "rest"))) (EBlock (DoExpr (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "cands")) (arm (PCon "None") () (ELit LUnit)) (arm (PCon "Some" (PVar "cs")) () (EMatch (EApp (EApp (EApp (EApp (EVar "scopedRecordEntry") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "prog")) (EVar "n")) (EVar "cs")) (arm (PCon "None") () (ELit LUnit)) (arm (PCon "Some" (PVar "ri")) () (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "recordByNameRef")) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (EVar "ri")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "recordByNameRef") "value")))))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "overrideScopedRecords") (EVar "mctx")) (EVar "prog")) (EVar "cands")) (EVar "rest")))))
(DTypeSig false "scopedRecordEntry" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Ident") (TyCon "String") (TyCon "RecordInfo"))) (TyApp (TyCon "Option") (TyCon "RecordInfo")))))))
(DFunDef false "scopedRecordEntry" ((PVar "gctx") (PVar "prog") (PVar "n") (PVar "cs")) (EIf (EApp (EApp (EVar "declaresCtorNamed") (EVar "prog")) (EVar "n")) (EVar "None") (EApp (EApp (EApp (EApp (EVar "importedRecordEntry") (EVar "gctx")) (EVar "prog")) (EVar "n")) (EVar "cs"))))
(DTypeSig false "importedRecordEntry" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Ident") (TyCon "String") (TyCon "RecordInfo"))) (TyApp (TyCon "Option") (TyCon "RecordInfo")))))))
(DFunDef false "importedRecordEntry" ((PVar "gctx") (PVar "prog") (PVar "n") (PVar "cs")) (EMatch (EApp (EApp (EVar "filterList") (ELam ((PVar "c")) (EApp (EApp (EApp (EApp (EVar "recordCandImported") (EVar "gctx")) (EVar "prog")) (EVar "n")) (EVar "c")))) (EVar "cs")) (arm (PList (PVar "only")) () (EApp (EVar "Some") (EApp (EVar "recordCandInfo") (EVar "only")))) (arm PWild () (EVar "None"))))
(DTypeSig false "recordCandImported" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "Ident") (TyCon "String") (TyCon "RecordInfo")) (TyCon "Bool"))))))
(DFunDef false "recordCandImported" ((PVar "gctx") (PVar "prog") (PVar "n") (PTuple (PVar "ident") (PVar "owner") PWild)) (EApp (EApp (EApp (EApp (EApp (EVar "anyUsePathBindsCtor") (EVar "gctx")) (EVar "prog")) (EVar "n")) (EVar "owner")) (EVar "ident")))
(DTypeSig true "pickSchemesByDecl" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyFun (TyApp (TyCon "Registry") (TyCon "MethodSchemeRow")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Scheme")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EnvBinding")))))))))
(DFunDef false "pickSchemesByDecl" ((PVar "_mctx") (PList) PWild PWild PWild) (EListLit))
(DFunDef false "pickSchemesByDecl" ((PVar "mctx") (PCons (PVar "n") (PVar "ns")) (PVar "table") (PVar "byId") (PVar "sources")) (EBlock (DoLet false false (PVar "rest") (EApp (EApp (EApp (EApp (EApp (EVar "pickSchemesByDecl") (EVar "mctx")) (EVar "ns")) (EVar "table")) (EVar "byId")) (EVar "sources"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "admittedRowFor") (EVar "mctx")) (EVar "n")) (EVar "byId")) (arm (PCon "Some" (PVar "row")) () (EBinOp "::" (ETuple (EVar "n") (EApp (EVar "methodEnvBinding") (EVar "row"))) (EVar "rest"))) (arm (PCon "None") () (EMatch (EApp (EApp (EApp (EVar "admittedSchemeFor") (EVar "mctx")) (EVar "n")) (EVar "byId")) (arm (PCon "Some" (PVar "s")) () (EBinOp "::" (ETuple (EVar "n") (EApp (EVar "ordinaryEnvBinding") (EVar "s"))) (EVar "rest"))) (arm (PCon "None") () (EMatch (EApp (EApp (EApp (EApp (EVar "undecidedSchemeFor") (EVar "mctx")) (EVar "n")) (EVar "table")) (EVar "sources")) (arm (PCon "Some" (PVar "s")) () (EBinOp "::" (ETuple (EVar "n") (EApp (EVar "ordinaryEnvBinding") (EVar "s"))) (EVar "rest"))) (arm (PCon "None") () (EVar "rest"))))))))))
(DTypeSig false "undecidedSchemeFor" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Scheme")) (TyApp (TyCon "Option") (TyCon "Scheme")))))))
(DFunDef false "undecidedSchemeFor" ((PVar "mctx") (PVar "n") (PVar "table") (PVar "sources")) (EIf (EApp (EVar "isEmptyL") (EApp (EApp (EVar "methodAdmittedHere") (EVar "mctx")) (EVar "n"))) (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EVar "table")) (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "sources"))))
(DTypeSig true "importedMemberBindingNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "importedMemberBindingNames" ((PList)) (EListLit))
(DFunDef false "importedMemberBindingNames" ((PCons (PCon "DAttrib" PWild (PVar "decl")) (PVar "rest"))) (EBinOp "++" (EApp (EVar "importedMemberBindingNames") (EListLit (EVar "decl"))) (EApp (EVar "importedMemberBindingNames") (EVar "rest"))))
(DFunDef false "importedMemberBindingNames" ((PCons (PCon "DUse" PWild (PVar "path") PWild) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "map") (EVar "snd")) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EVar "importedBindings") (EVar "path")))) (EApp (EVar "importedMemberBindingNames") (EVar "rest"))))
(DFunDef false "importedMemberBindingNames" ((PCons PWild (PVar "rest"))) (EApp (EVar "importedMemberBindingNames") (EVar "rest")))
(DTypeSig true "annotateImportedMethodRows" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "Registry") (TyCon "MethodSchemeRow")) (TyCon "TcEnv")))))))
(DFunDef false "annotateImportedMethodRows" ((PVar "env") (PList) PWild PWild PWild) (EVar "env"))
(DFunDef false "annotateImportedMethodRows" ((PVar "env") (PCons (PVar "name") (PVar "rest")) (PVar "nameable") (PVar "shadows") (PVar "rows")) (EBlock (DoLet false false (PVar "originName") (EApp (EApp (EVar "originMethodName") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name"))) (DoLet false false (PVar "env2") (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "omHasKey") (EVar "originName")) (EVar "nameable")) (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EVar "name")) (EVar "shadows")))) (EApp (EVar "isSome") (EApp (EApp (EVar "lookupBinding") (EVar "env")) (EVar "name")))) (EMatch (EApp (EApp (EApp (EVar "admittedRowFor") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name")) (EVar "rows")) (arm (PCon "Some" (PVar "row")) () (EApp (EApp (EApp (EVar "extendMethodRow") (EVar "env")) (EVar "name")) (EVar "row"))) (arm (PCon "None") () (EVar "env"))) (EVar "env"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "annotateImportedMethodRows") (EVar "env2")) (EVar "rest")) (EVar "nameable")) (EVar "shadows")) (EVar "rows")))))
(DTypeSig false "admittedRowFor" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Registry") (TyCon "MethodSchemeRow")) (TyApp (TyCon "Option") (TyCon "MethodSchemeRow"))))))
(DFunDef false "admittedRowFor" ((PVar "mctx") (PVar "n") (PVar "byId")) (EIf (EBinOp ">=" (EApp (EVar "listLen") (EApp (EApp (EVar "methodAdmittedHere") (EVar "mctx")) (EVar "n"))) (ELit (LInt 2))) (EVar "None") (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "methodEntryHere") (EVar "mctx")) (EVar "n"))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PTuple (PVar "iface") PWild PWild PWild) () (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "lookupMethodRowById") (EVar "iface")) (EApp (EApp (EVar "originMethodName") (EVar "mctx")) (EVar "n"))) (EVar "byId"))) (ELam ((PVar "row")) (EIf (EApp (EVar "methodRowCanCarry") (EVar "row")) (EApp (EVar "Some") (EVar "row")) (EVar "None"))))))))))
(DTypeSig false "admittedSchemeFor" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Registry") (TyCon "MethodSchemeRow")) (TyApp (TyCon "Option") (TyCon "Scheme"))))))
(DFunDef false "admittedSchemeFor" ((PVar "mctx") (PVar "n") (PVar "byId")) (EMatch (EApp (EApp (EVar "methodEntryHere") (EVar "mctx")) (EVar "n")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PTuple (PVar "iface") PWild PWild PWild)) () (EApp (EApp (EApp (EVar "lookupSchemeById") (EVar "iface")) (EApp (EApp (EVar "originMethodName") (EVar "mctx")) (EVar "n"))) (EVar "byId")))))
(DTypeSig true "schemeOblEntriesFor" (TyFun (TyCon "String") (TyFun (TyCon "UsePath") (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "VecObl")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "VecObl"))))))))
(DFunDef false "schemeOblEntriesFor" ((PVar "mid") (PCon "UseAlias" PWild (PVar "a")) (PVar "qual")) (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "moduleAliasEntry") (EVar "mid")) (EVar "a"))) (EVar "qual")))
(DFunDef false "schemeOblEntriesFor" ((PVar "mid") (PCon "UseWild" PWild) (PVar "qual")) (EApp (EApp (EVar "flatMap") (EApp (EVar "wildSchemeOblEntry") (EVar "mid"))) (EVar "qual")))
(DFunDef false "schemeOblEntriesFor" ((PVar "mid") (PCon "UseGroup" PWild (PVar "ms")) (PVar "qual")) (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "memberSchemeOblEntry") (EVar "mid")) (EVar "qual"))) (EVar "ms")))
(DFunDef false "schemeOblEntriesFor" (PWild PWild PWild) (EListLit))
(DTypeSig false "wildSchemeOblEntry" (TyFun (TyCon "String") (TyFun (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "VecObl"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "VecObl")))))))
(DFunDef false "wildSchemeOblEntry" ((PVar "mid") (PTuple (PTuple (PVar "defMid") (PVar "n")) (PVar "obs"))) (EIf (EBinOp "==" (EVar "defMid") (EVar "mid")) (EListLit (ETuple (EVar "n") (EVar "obs"))) (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "memberSchemeOblEntry" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "VecObl")))) (TyFun (TyCon "UseMember") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "VecObl"))))))))
(DFunDef false "memberSchemeOblEntry" ((PVar "mid") (PVar "qual") (PVar "m")) (EBlock (DoLet false false (PVar "local") (EApp (EVar "useMemberLocal") (EVar "m"))) (DoLet false false (PVar "origin") (EApp (EVar "useMemberOrigin") (EVar "m"))) (DoExpr (EApp (EApp (EVar "map") (ELam ((PVar "e")) (ETuple (EVar "local") (EApp (EVar "snd") (EVar "e"))))) (EApp (EApp (EVar "filterList") (ELam ((PVar "e")) (EBinOp "&&" (EBinOp "==" (EApp (EVar "fst") (EApp (EVar "fst") (EVar "e"))) (EVar "mid")) (EBinOp "==" (EApp (EVar "snd") (EApp (EVar "fst") (EVar "e"))) (EVar "origin"))))) (EVar "qual"))))))
(DTypeSig true "aliasConstraintEntries" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyVar "a"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a")))))))
(DFunDef false "aliasConstraintEntries" ((PVar "_gctx") (PList) PWild) (EListLit))
(DFunDef false "aliasConstraintEntries" ((PVar "gctx") (PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest")) (PVar "qual")) (EBinOp "++" (EApp (EApp (EApp (EVar "aliasConstraintEntries") (EVar "gctx")) (EListLit (EVar "d"))) (EVar "qual")) (EApp (EApp (EApp (EVar "aliasConstraintEntries") (EVar "gctx")) (EVar "rest")) (EVar "qual"))))
(DFunDef false "aliasConstraintEntries" ((PVar "gctx") (PCons (PCon "DUse" PWild (PVar "path") PWild) (PVar "rest")) (PVar "qual")) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "aliasEntriesFor") (EVar "gctx")) (EApp (EVar "importTableMid") (EVar "path"))) (EVar "path")) (EVar "qual")) (EApp (EApp (EApp (EVar "aliasConstraintEntries") (EVar "gctx")) (EVar "rest")) (EVar "qual"))))
(DFunDef false "aliasConstraintEntries" ((PVar "gctx") (PCons PWild (PVar "rest")) (PVar "qual")) (EApp (EApp (EApp (EVar "aliasConstraintEntries") (EVar "gctx")) (EVar "rest")) (EVar "qual")))
(DTypeSig false "aliasEntriesFor" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyFun (TyCon "UsePath") (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyVar "a"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a"))))))))
(DFunDef false "aliasEntriesFor" ((PVar "gctx") (PVar "mid") (PCon "UseAlias" PWild (PVar "a")) (PVar "qual")) (EIf (EBinOp "==" (EVar "mid") (ELit (LString ""))) (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "moduleAliasEntry") (EVar "mid")) (EVar "a"))) (EVar "qual")) (EIf (EVar "otherwise") (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "graphAliasEntry") (EVar "a")) (EVar "qual"))) (EApp (EApp (EVar "graphPubDefiners") (EVar "gctx")) (EVar "mid"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "aliasEntriesFor" ((PVar "_gctx") (PVar "mid") (PCon "UseGroup" PWild (PVar "ms")) (PVar "qual")) (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "memberAliasEntry") (EVar "mid")) (EVar "qual"))) (EVar "ms")))
(DFunDef false "aliasEntriesFor" ((PVar "_gctx") PWild PWild PWild) (EListLit))
(DTypeSig true "aliasDictNames" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "aliasDictNames" ((PVar "gctx") (PVar "bare") (PVar "unitDecls") (PVar "modules")) (EBlock (DoLet false false (PVar "bareSet") (EApp (EApp (EVar "namesToSet") (EVar "bare")) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EVar "flatMap") (ELam ((PVar "u")) (EApp (EApp (EApp (EApp (EVar "aliasDictNamesOfUnit") (EVar "gctx")) (EVar "bareSet")) (EVar "unitDecls")) (EApp (EVar "snd") (EVar "u"))))) (EVar "modules")))))
(DTypeSig false "aliasDictNamesOfUnit" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "aliasDictNamesOfUnit" ((PVar "gctx") (PVar "bare") (PVar "unitDecls") (PVar "decls")) (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EVar "aliasDictNamesOfDecl") (EVar "gctx")) (EVar "bare")) (EVar "unitDecls"))) (EVar "decls")))
(DTypeSig false "aliasDictNamesOfDecl" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "aliasDictNamesOfDecl" ((PVar "gctx") (PVar "bare") (PVar "unitDecls") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EApp (EApp (EVar "aliasDictNamesOfDecl") (EVar "gctx")) (EVar "bare")) (EVar "unitDecls")) (EVar "d")))
(DFunDef false "aliasDictNamesOfDecl" ((PVar "gctx") (PVar "bare") (PVar "unitDecls") (PCon "DUse" PWild (PVar "path") PWild)) (EApp (EApp (EApp (EApp (EApp (EVar "aliasDictNamesOfPath") (EVar "gctx")) (EVar "bare")) (EVar "unitDecls")) (EApp (EVar "useModId") (EVar "path"))) (EVar "path")))
(DFunDef false "aliasDictNamesOfDecl" ((PVar "_gctx") PWild PWild PWild) (EListLit))
(DTypeSig false "aliasDictNamesOfPath" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyCon "String") (TyFun (TyCon "UsePath") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "aliasDictNamesOfPath" ((PVar "gctx") (PVar "bare") (PVar "unitDecls") (PVar "mid") (PCon "UseAlias" PWild (PVar "a"))) (EBlock (DoLet false false (PVar "own") (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "mid")) (EVar "unitDecls")) (arm (PCon "Some" (PVar "ds")) () (EApp (EApp (EVar "filter") (ELam ((PVar "n")) (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "bare")))) (EApp (EVar "declTopFnNames") (EVar "ds")))) (arm (PCon "None") () (EListLit)))) (DoLet false false (PVar "reexported") (EApp (EApp (EVar "map") (EVar "fst")) (EApp (EApp (EVar "filterList") (ELam ((PVar "r")) (EApp (EApp (EVar "omHasKey") (EApp (EVar "snd") (EApp (EVar "snd") (EVar "r")))) (EVar "bare")))) (EApp (EApp (EVar "graphPubDefiners") (EVar "gctx")) (EVar "mid"))))) (DoExpr (EApp (EApp (EVar "map") (EApp (EVar "qualifiedLocal") (EVar "a"))) (EApp (EVar "dedup") (EBinOp "++" (EVar "own") (EVar "reexported")))))))
(DFunDef false "aliasDictNamesOfPath" ((PVar "_gctx") (PVar "bare") PWild PWild (PCon "UseGroup" PWild (PVar "ms"))) (EApp (EApp (EVar "flatMap") (EApp (EVar "memberDictName") (EVar "bare"))) (EVar "ms")))
(DFunDef false "aliasDictNamesOfPath" ((PVar "_gctx") PWild PWild PWild PWild) (EListLit))
(DTypeSig false "memberDictName" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "UseMember") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "memberDictName" ((PVar "bare") (PVar "m")) (EMatch (EApp (EVar "useMemberAlias") (EVar "m")) (arm (PCon "Some" (PVar "local")) () (EIf (EApp (EApp (EVar "omHasKey") (EApp (EVar "useMemberOrigin") (EVar "m"))) (EVar "bare")) (EListLit (EVar "local")) (EListLit))) (arm (PCon "None") () (EListLit))))
(DTypeSig false "moduleAliasEntry" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyVar "a")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a")))))))
(DFunDef false "moduleAliasEntry" ((PVar "mid") (PVar "a") (PTuple (PTuple (PVar "defMid") (PVar "n")) (PVar "ids"))) (EIf (EBinOp "==" (EVar "defMid") (EVar "mid")) (EListLit (ETuple (EApp (EApp (EVar "qualifiedLocal") (EVar "a")) (EVar "n")) (EVar "ids"))) (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "memberAliasEntry" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyVar "a"))) (TyFun (TyCon "UseMember") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a")))))))
(DFunDef false "memberAliasEntry" ((PVar "mid") (PVar "qual") (PVar "m")) (EMatch (EApp (EVar "useMemberAlias") (EVar "m")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "local")) () (EBlock (DoLet false false (PVar "origin") (EApp (EVar "useMemberOrigin") (EVar "m"))) (DoExpr (EApp (EApp (EVar "map") (ELam ((PVar "e")) (ETuple (EVar "local") (EApp (EVar "snd") (EVar "e"))))) (EApp (EApp (EVar "filter") (ELam ((PVar "e")) (EBinOp "&&" (EBinOp "==" (EApp (EVar "fst") (EApp (EVar "fst") (EVar "e"))) (EVar "mid")) (EBinOp "==" (EApp (EVar "snd") (EApp (EVar "fst") (EVar "e"))) (EVar "origin"))))) (EVar "qual"))))))))
(DTypeSig false "graphAliasEntry" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyVar "a"))) (TyFun (TyTuple (TyCon "String") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a")))))))
(DFunDef false "graphAliasEntry" ((PVar "a") (PVar "qual") (PTuple (PVar "localName") (PTuple (PVar "defMid") (PVar "origin")))) (EApp (EApp (EVar "map") (ELam ((PVar "e")) (ETuple (EApp (EApp (EVar "qualifiedLocal") (EVar "a")) (EVar "localName")) (EApp (EVar "snd") (EVar "e"))))) (EApp (EApp (EVar "filterList") (ELam ((PVar "e")) (EBinOp "&&" (EBinOp "==" (EApp (EVar "fst") (EApp (EVar "fst") (EVar "e"))) (EVar "defMid")) (EBinOp "==" (EApp (EVar "snd") (EApp (EVar "fst") (EVar "e"))) (EVar "origin"))))) (EVar "qual"))))
(DTypeSig true "reportAmbiguousImportsIn" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Unit")))))
(DFunDef false "reportAmbiguousImportsIn" ((PVar "_mctx") PWild (PList)) (ELit LUnit))
(DFunDef false "reportAmbiguousImportsIn" ((PVar "mctx") (PVar "occ") (PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EBlock (DoExpr (EApp (EApp (EApp (EVar "reportAmbiguousImportsIn") (EVar "mctx")) (EVar "occ")) (EListLit (EVar "d")))) (DoExpr (EApp (EApp (EApp (EVar "reportAmbiguousImportsIn") (EVar "mctx")) (EVar "occ")) (EVar "rest")))))
(DFunDef false "reportAmbiguousImportsIn" ((PVar "mctx") (PVar "occ") (PCons (PCon "DUse" PWild (PVar "path") (PVar "loc")) (PVar "rest"))) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "reportAmbiguousImport") (EVar "mctx")) (EVar "occ")) (EApp (EVar "useModId") (EVar "path"))) (EVar "path")) (EVar "loc"))) (DoExpr (EApp (EApp (EApp (EVar "reportAmbiguousImportsIn") (EVar "mctx")) (EVar "occ")) (EVar "rest")))))
(DFunDef false "reportAmbiguousImportsIn" ((PVar "mctx") (PVar "occ") (PCons PWild (PVar "rest"))) (EApp (EApp (EApp (EVar "reportAmbiguousImportsIn") (EVar "mctx")) (EVar "occ")) (EVar "rest")))
(DTypeSig false "reportAmbiguousImport" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "String") (TyFun (TyCon "UsePath") (TyFun (TyCon "Loc") (TyCon "Unit")))))))
(DFunDef false "reportAmbiguousImport" ((PVar "mctx") (PVar "occ") (PVar "depId") (PVar "path") (PVar "loc")) (EMatch (EApp (EApp (EVar "graphAmbigValues") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "depId")) (arm (PList) () (ELit LUnit)) (arm (PVar "amb") () (EApp (EApp (EApp (EApp (EVar "pushAmbiguousImports") (EVar "mctx")) (EVar "depId")) (EVar "loc")) (EApp (EApp (EApp (EVar "ambiguousAdmitted") (EVar "occ")) (EVar "path")) (EVar "amb"))))))
(DTypeSig false "ambiguousAdmitted" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "UsePath") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "ambiguousAdmitted" ((PVar "occ") (PCon "UseAlias" PWild (PVar "a")) (PVar "amb")) (EApp (EApp (EVar "filterList") (ELam ((PVar "r")) (EApp (EApp (EVar "omHasKey") (EApp (EApp (EVar "qualifiedLocal") (EVar "a")) (EApp (EVar "fst") (EVar "r")))) (EVar "occ")))) (EVar "amb")))
(DFunDef false "ambiguousAdmitted" ((PVar "occ") (PVar "path") (PVar "amb")) (EMatch (EApp (EVar "importedBindings") (EVar "path")) (arm (PCon "None") () (EApp (EApp (EVar "filterList") (ELam ((PVar "r")) (EApp (EApp (EVar "omHasKey") (EApp (EVar "fst") (EVar "r"))) (EVar "occ")))) (EVar "amb"))) (arm (PCon "Some" (PVar "bindings")) () (EApp (EApp (EVar "filterList") (ELam ((PVar "r")) (EApp (EApp (EVar "anyList") (ELam ((PVar "b")) (EBinOp "==" (EApp (EVar "fst") (EVar "b")) (EApp (EVar "fst") (EVar "r"))))) (EVar "bindings")))) (EVar "amb")))))
(DTypeSig false "pushAmbiguousImports" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "Loc") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyCon "Unit"))))))
(DFunDef false "pushAmbiguousImports" ((PVar "_mctx") PWild PWild (PList)) (ELit LUnit))
(DFunDef false "pushAmbiguousImports" ((PVar "mctx") (PVar "depId") (PVar "loc") (PCons (PTuple (PVar "n") (PVar "mids")) (PVar "rest"))) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "pushTypeErrorHelpFixAt") (EVar "mctx")) (EVar "TAmbiguousReexport")) (EApp (EVar "Some") (EVar "loc"))) (EApp (EApp (EApp (EVar "ambigReexportMsg") (EVar "n")) (EVar "depId")) (EVar "mids"))) (EApp (EApp (EApp (EVar "ambigReexportHelp") (EVar "n")) (EVar "depId")) (EVar "mids"))) (EVar "None"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "pushAmbiguousImports") (EVar "mctx")) (EVar "depId")) (EVar "loc")) (EVar "rest")))))
(DTypeSig true "declCtorNamed" (TyFun (TyCon "String") (TyFun (TyCon "Decl") (TyCon "Bool"))))
(DFunDef false "declCtorNamed" ((PVar "n") (PRec "DData" ((rf "dataCtors" (PVar "vs"))) false)) (EApp (EApp (EVar "variantNamed") (EVar "n")) (EVar "vs")))
(DFunDef false "declCtorNamed" ((PVar "n") (PRec "DNewtype" ((rf "newtypeCtor" (PVar "cn"))) false)) (EBinOp "==" (EVar "cn") (EVar "n")))
(DFunDef false "declCtorNamed" (PWild PWild) (EVar "False"))
(DTypeSig true "withAliasMethodNames" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit")))))
(DFunDef false "withAliasMethodNames" ((PVar "rows") (PVar "set")) (EApp (EApp (EVar "omFromNames") (EApp (EApp (EVar "map") (EVar "fst")) (EApp (EApp (EVar "filterList") (ELam ((PVar "r")) (EApp (EApp (EVar "omHasKey") (EApp (EVar "snd") (EVar "r"))) (EVar "set")))) (EVar "rows")))) (EVar "set")))
(DTypeSig true "importedIfaceRows" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "importedIfaceRows" (PWild (PList)) (EListLit))
(DFunDef false "importedIfaceRows" ((PVar "idx") (PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "importedIfaceRows") (EVar "idx")) (EListLit (EVar "d"))) (EApp (EApp (EVar "importedIfaceRows") (EVar "idx")) (EVar "rest"))))
(DFunDef false "importedIfaceRows" ((PVar "idx") (PCons (PCon "DUse" PWild (PVar "path") PWild) (PVar "rest"))) (EBinOp "++" (EMatch (EApp (EApp (EVar "omLookup") (EApp (EVar "useModId") (EVar "path"))) (EVar "idx")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "src")) () (EApp (EApp (EVar "selectIfaceRows") (EVar "path")) (EVar "src")))) (EApp (EApp (EVar "importedIfaceRows") (EVar "idx")) (EVar "rest"))))
(DFunDef false "importedIfaceRows" ((PVar "idx") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "importedIfaceRows") (EVar "idx")) (EVar "rest")))
# MARK
(DUse false (UseGroup ("support" "diag_codes") ((mem "DiagCode" true))))
(DUse false (UseGroup ("types" "tc_types") ((mem "AbsorptionEvent" true) (mem "MethodScope" true) (mem "Predicate" true) (mem "UObligation" true) (mem "Windowed" true) (mem "DeclEnvs" false) (mem "EnvBinding" false) (mem "GraphCtx" false) (mem "ImplEnv" false) (mem "Kind" false) (mem "MethodEntry" false) (mem "MethodEnv" false) (mem "MethodRow" false) (mem "MethodSchemeRow" false) (mem "ModuleCtx" false) (mem "RecordInfo" false) (mem "TcEnv" false))))
(DUse false (UseGroup ("types" "tc_mono") ((mem "locEq" false))))
(DUse false (UseGroup ("types" "tc_env") ((mem "addCtor" false) (mem "ctorExportsIndex" false) (mem "declEnvVisibleAt" false) (mem "declTopFnNames" false) (mem "extendMethodRow" false) (mem "graphAmbigValues" false) (mem "graphPubDefiners" false) (mem "ieImplExistsForHeadOf" false) (mem "ifaceMethodNames" false) (mem "importedBindings" false) (mem "importTableMid" false) (mem "lookupBinding" false) (mem "lookupCtor" false) (mem "lookupIdxById" false) (mem "lookupMethodRowById" false) (mem "lookupRecordByName" false) (mem "lookupSchemeById" false) (mem "methodEnvBinding" false) (mem "methodExportsIndex" false) (mem "methodPreludeRow" false) (mem "methodRowById" false) (mem "methodRowCanCarry" false) (mem "methodRowCand" false) (mem "methodRowIface" false) (mem "namesToSet" false) (mem "ordinaryEnvBinding" false) (mem "originMethodName" false) (mem "recordCandInfo" false) (mem "variantNamed" false) (mem "selectIfaceRows" false))))
(DUse false (UseGroup ("types" "tc_diag") ((mem "pushTypeErrorHelpFixAt" false) (mem "pushTypeErrorOnceAt" false))))
(DUse false (UseGroup ("types" "tc_diag_text") ((mem "ambigReexportHelp" false) (mem "ambigReexportMsg" false) (mem "backticked" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "ConPayload" true) (mem "Decl" true) (mem "Ident" true) (mem "Loc" true) (mem "Ns" true) (mem "Ty" true) (mem "TyConOrigin" true) (mem "UseMember" true) (mem "UsePath" true) (mem "Variant" true) (mem "ifaceIdentity" false) (mem "mkIdent" false) (mem "qualifiedLocal" false) (mem "useMemberAlias" false) (mem "useMemberLocal" false) (mem "useMemberOrigin" false))))
(DUse false (UseGroup ("types" "repr") ((mem "IfaceRef" true) (mem "Scheme" true) (mem "VecObl" true))))
(DUse false (UseGroup ("support" "util") ((mem "anyList" false) (mem "contains" false) (mem "dedup" false) (mem "filterList" false) (mem "isEmptyL" false) (mem "isNonEmptyL" false) (mem "joinDot" false) (mem "joinWith" false) (mem "listLen" false) (mem "lookupAssoc" false) (mem "sortUniqS" false))))
(DUse false (UseGroup ("string") ((mem "endsWith" false))))
(DUse false (UseGroup ("types" "registry") ((mem "HeadKey" true) (mem "Registry" false) (mem "spCollided" false) (mem "SpellingPop" false) (mem "spInsert" false) (mem "spRows" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "omEmpty" false) (mem "omFromNames" false) (mem "omHasKey" false) (mem "omInsert" false) (mem "omKeys" false) (mem "omLookup" false) (mem "OrdMap" false))))
(DUse false (UseGroup ("types" "disposition") ((mem "MethodDisposition" true))))
(DUse false (UseGroup ("types" "route_key") ((mem "ifaceWordOf" false))))
(DUse false (UseGroup ("types" "solver_contract") ((mem "Wanted" true))))
(DUse false (UseGroup ("frontend" "visibility") ((mem "useModId" false))))
(DTypeSig true "ifaceSortKey" (TyFun (TyCon "IfaceRef") (TyCon "String")))
(DFunDef false "ifaceSortKey" ((PVar "ir")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EApp (EVar "ifaceIdentity") (EFieldAccess (EVar "ir") "irOrigin")) (EFieldAccess (EVar "ir") "irName")))) (ELit (LString "|"))) (EApp (EMethodRef "display") (EFieldAccess (EVar "ir") "irName"))) (ELit (LString ""))))
(DTypeSig true "sortIfaceRefs" (TyFun (TyApp (TyCon "List") (TyCon "IfaceRef")) (TyApp (TyCon "List") (TyCon "IfaceRef"))))
(DFunDef false "sortIfaceRefs" ((PVar "xs")) (EApp (EApp (EVar "sortIfaceRefsGo") (EVar "xs")) (EListLit)))
(DTypeSig false "sortIfaceRefsGo" (TyFun (TyApp (TyCon "List") (TyCon "IfaceRef")) (TyFun (TyApp (TyCon "List") (TyCon "IfaceRef")) (TyApp (TyCon "List") (TyCon "IfaceRef")))))
(DFunDef false "sortIfaceRefsGo" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "sortIfaceRefsGo" ((PCons (PVar "x") (PVar "xs")) (PVar "acc")) (EApp (EApp (EVar "sortIfaceRefsGo") (EVar "xs")) (EApp (EApp (EVar "sortInsertIfaceRef") (EVar "x")) (EVar "acc"))))
(DTypeSig false "sortInsertIfaceRef" (TyFun (TyCon "IfaceRef") (TyFun (TyApp (TyCon "List") (TyCon "IfaceRef")) (TyApp (TyCon "List") (TyCon "IfaceRef")))))
(DFunDef false "sortInsertIfaceRef" ((PVar "x") (PList)) (EListLit (EVar "x")))
(DFunDef false "sortInsertIfaceRef" ((PVar "x") (PCons (PVar "y") (PVar "ys"))) (EIf (EBinOp "<" (EApp (EVar "ifaceSortKey") (EVar "x")) (EApp (EVar "ifaceSortKey") (EVar "y"))) (EBinOp "::" (EVar "x") (EBinOp "::" (EVar "y") (EVar "ys"))) (EIf (EVar "otherwise") (EBinOp "::" (EVar "y") (EApp (EApp (EVar "sortInsertIfaceRef") (EVar "x")) (EVar "ys"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "ownMethodIdent" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Ident")))))
(DFunDef false "ownMethodIdent" ((PList) PWild) (EVar "None"))
(DFunDef false "ownMethodIdent" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest")) (PVar "n")) (EMatch (EApp (EApp (EVar "ownMethodIdent") (EListLit (EVar "d"))) (EVar "n")) (arm (PCon "Some" (PVar "i")) () (EApp (EVar "Some") (EVar "i"))) (arm (PCon "None") () (EApp (EApp (EVar "ownMethodIdent") (EVar "rest")) (EVar "n")))))
(DFunDef false "ownMethodIdent" ((PCons (PRec "DInterface" ((rf "methods" None) (rf "ifaceOrigin" None)) true) (PVar "rest")) (PVar "n")) (EIf (EApp (EApp (EVar "contains") (EVar "n")) (EApp (EVar "ifaceMethodNames") (EVar "methods"))) (EApp (EApp (EApp (EVar "mkIdent") (EVar "NsMethod")) (EVar "ifaceOrigin")) (EVar "n")) (EApp (EApp (EVar "ownMethodIdent") (EVar "rest")) (EVar "n"))))
(DFunDef false "ownMethodIdent" ((PCons PWild (PVar "rest")) (PVar "n")) (EApp (EApp (EVar "ownMethodIdent") (EVar "rest")) (EVar "n")))
(DTypeSig false "usePathAdmitsDecl" (TyFun (TyCon "UsePath") (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "IfaceRef") (TyCon "Bool"))))))
(DFunDef false "usePathAdmitsDecl" ((PVar "path") (PVar "wide") (PVar "n") (PVar "iface")) (EBinOp "||" (EApp (EApp (EVar "usePathBindsName") (EVar "path")) (EVar "n")) (EBinOp "&&" (EVar "wide") (EApp (EApp (EVar "usePathBindsName") (EVar "path")) (EFieldAccess (EVar "iface") "irName")))))
(DTypeSig false "usePathBindsName" (TyFun (TyCon "UsePath") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "usePathBindsName" ((PVar "path") (PVar "n")) (EMatch (EApp (EVar "importedBindings") (EVar "path")) (arm (PCon "None") () (EVar "True")) (arm (PCon "Some" (PVar "bs")) () (EApp (EApp (EVar "contains") (EVar "n")) (EApp (EApp (EMethodRef "map") (EVar "snd")) (EVar "bs"))))))
(DTypeSig false "exportsIdentFor" (TyFun (TyCon "String") (TyFun (TyCon "Ident") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ident"))) (TyCon "Bool")))))
(DFunDef false "exportsIdentFor" (PWild PWild (PList)) (EVar "False"))
(DFunDef false "exportsIdentFor" ((PVar "n") (PVar "ident") (PCons (PTuple (PVar "en") (PVar "ei")) (PVar "rest"))) (EIf (EBinOp "&&" (EBinOp "==" (EVar "en") (EVar "n")) (EBinOp "==" (EVar "ei") (EVar "ident"))) (EVar "True") (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "exportsIdentFor") (EVar "n")) (EVar "ident")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "memberSuffix" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "memberSuffix" ((PVar "n")) (EBinOp "++" (ELit (LString "__")) (EVar "n")))
(DTypeSig true "resolveMemberRows" (TyFun (TyTuple (TyCon "String") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a"))))))
(DFunDef false "resolveMemberRows" ((PTuple (PVar "origin") (PVar "local")) (PVar "depRows")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "origin")) (EVar "depRows")) (arm (PCon "Some" (PVar "s")) () (EListLit (ETuple (EVar "local") (EVar "s")))) (arm (PCon "None") () (EApp (EApp (EMethodRef "filter") (ELam ((PVar "kv")) (EApp (EApp (EVar "endsWith") (EApp (EVar "memberSuffix") (EVar "origin"))) (EApp (EVar "fst") (EVar "kv"))))) (EVar "depRows")))))
(DTypeSig true "importFormRows" (TyFun (TyCon "UsePath") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a"))))))
(DFunDef false "importFormRows" ((PVar "path") (PVar "depRows")) (EMatch (EApp (EVar "importedBindings") (EVar "path")) (arm (PCon "None") () (EVar "depRows")) (arm (PCon "Some" (PVar "bindings")) () (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "b")) (EApp (EApp (EVar "resolveMemberRows") (EVar "b")) (EVar "depRows")))) (EVar "bindings")))))
(DTypeSig false "methodCandsAt" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "MethodEnv") (TyApp (TyCon "List") (TyCon "MethodRow"))))))
(DFunDef false "methodCandsAt" ((PVar "n") (PVar "cur") (PVar "env")) (EApp (EApp (EVar "filterList") (ELam ((PVar "r")) (EApp (EApp (EVar "declEnvVisibleAt") (EVar "cur")) (EFieldAccess (EVar "r") "mrOrd")))) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "n")) (EFieldAccess (EVar "env") "meByName")))))
(DTypeSig true "methodNameDeclaredAt" (TyFun (TyCon "Int") (TyFun (TyCon "MethodEnv") (TyFun (TyCon "String") (TyCon "Bool")))))
(DFunDef false "methodNameDeclaredAt" ((PVar "cur") (PVar "env") (PVar "n")) (EApp (EVar "isNonEmptyL") (EApp (EApp (EApp (EVar "methodCandsAt") (EVar "n")) (EVar "cur")) (EVar "env"))))
(DTypeSig false "methodScopeAt" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "DeclEnvs") (TyCon "MethodScope"))))))))
(DFunDef false "methodScopeAt" ((PVar "gctx") (PVar "standalone") (PVar "prog") (PVar "n") (PVar "cur") (PVar "envs")) (EMatch (EApp (EApp (EApp (EVar "methodCandsAt") (EVar "n")) (EVar "cur")) (EFieldAccess (EVar "envs") "deMethods")) (arm (PList) () (EVar "MsAbsent")) (arm (PList (PVar "only")) () (EApp (EVar "MsOne") (EVar "only"))) (arm (PVar "cs") () (EApp (EApp (EApp (EApp (EApp (EVar "methodOwnScope") (EVar "gctx")) (EVar "standalone")) (EVar "prog")) (EVar "n")) (EVar "cs")))))
(DTypeSig false "methodOwnScope" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "MethodRow")) (TyCon "MethodScope")))))))
(DFunDef false "methodOwnScope" ((PVar "gctx") (PVar "standalone") (PVar "prog") (PVar "n") (PVar "cs")) (EMatch (EApp (EApp (EVar "ownMethodIdent") (EVar "prog")) (EVar "n")) (arm (PCon "Some" (PVar "ident")) () (EMatch (EApp (EApp (EVar "methodRowById") (EVar "ident")) (EVar "cs")) (arm (PCon "Some" (PVar "r")) () (EApp (EVar "MsOne") (EVar "r"))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EVar "methodImportedScope") (EVar "gctx")) (EVar "standalone")) (EVar "prog")) (EVar "n")) (EVar "cs"))))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EVar "methodImportedScope") (EVar "gctx")) (EVar "standalone")) (EVar "prog")) (EVar "n")) (EVar "cs")))))
(DTypeSig false "methodImportedScope" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "MethodRow")) (TyCon "MethodScope")))))))
(DFunDef false "methodImportedScope" ((PVar "gctx") (PVar "standalone") (PVar "prog0") (PVar "n") (PVar "cs")) (EBlock (DoLet false false (PVar "prog") (EApp (EVar "writtenImportsOf") (EVar "prog0"))) (DoExpr (EMatch (EApp (EApp (EVar "filterList") (ELam ((PVar "r")) (EApp (EApp (EApp (EApp (EVar "methodCandImported") (EVar "gctx")) (EVar "prog")) (EVar "n")) (EApp (EVar "methodRowCand") (EVar "r"))))) (EVar "cs")) (arm (PList (PVar "only")) () (EApp (EVar "MsOne") (EVar "only"))) (arm (PList) () (EMatch (EIf (EVar "standalone") (EVar "None") (EApp (EApp (EVar "methodPreludeRow") (EVar "n")) (EVar "cs"))) (arm (PCon "Some" (PVar "r")) () (EApp (EVar "MsOne") (EVar "r"))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "filterList") (ELam ((PVar "r")) (EApp (EApp (EApp (EApp (EVar "methodCandAdmitted") (EVar "gctx")) (EVar "prog")) (EVar "n")) (EApp (EVar "methodRowCand") (EVar "r"))))) (EVar "cs")) (arm (PList (PVar "only")) () (EApp (EVar "MsOne") (EVar "only"))) (arm (PVar "rung2") () (EApp (EApp (EApp (EApp (EApp (EVar "methodUndecided") (EVar "gctx")) (EVar "prog")) (EVar "n")) (EVar "cs")) (EVar "rung2"))))))) (arm (PVar "rung1") () (EApp (EApp (EApp (EApp (EApp (EVar "methodUndecided") (EVar "gctx")) (EVar "prog")) (EVar "n")) (EVar "cs")) (EVar "rung1")))))))
(DTypeSig false "writtenImportsOf" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "writtenImportsOf" ((PVar "prog")) (EMatch (EApp (EVar "aliasImportSites") (EVar "prog")) (arm (PList) () (EVar "prog")) (arm (PVar "sites") () (EApp (EApp (EVar "filterList") (ELam ((PVar "d")) (EApp (EVar "not") (EApp (EApp (EVar "isAliasMethodImport") (EVar "sites")) (EVar "d"))))) (EVar "prog")))))
(DTypeSig false "aliasImportSites" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Loc")))))
(DFunDef false "aliasImportSites" ((PList)) (EListLit))
(DFunDef false "aliasImportSites" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EBinOp "++" (EApp (EVar "aliasImportSites") (EListLit (EVar "d"))) (EApp (EVar "aliasImportSites") (EVar "rest"))))
(DFunDef false "aliasImportSites" ((PCons (PCon "DUse" PWild (PCon "UseAlias" (PVar "quals") PWild) (PVar "loc")) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "quals") (EVar "loc")) (EApp (EVar "aliasImportSites") (EVar "rest"))))
(DFunDef false "aliasImportSites" ((PCons PWild (PVar "rest"))) (EApp (EVar "aliasImportSites") (EVar "rest")))
(DTypeSig false "isAliasMethodImport" (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Loc"))) (TyFun (TyCon "Decl") (TyCon "Bool"))))
(DFunDef false "isAliasMethodImport" ((PVar "sites") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EVar "isAliasMethodImport") (EVar "sites")) (EVar "d")))
(DFunDef false "isAliasMethodImport" ((PVar "sites") (PCon "DUse" PWild (PCon "UseGroup" (PVar "quals") PWild) (PVar "loc"))) (EApp (EApp (EVar "anyList") (ELam ((PVar "s")) (EBinOp "&&" (EBinOp "==" (EApp (EVar "fst") (EVar "s")) (EVar "quals")) (EApp (EApp (EVar "locEq") (EApp (EVar "snd") (EVar "s"))) (EVar "loc"))))) (EVar "sites")))
(DFunDef false "isAliasMethodImport" (PWild PWild) (EVar "False"))
(DTypeSig false "methodUndecided" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "MethodRow")) (TyFun (TyApp (TyCon "List") (TyCon "MethodRow")) (TyCon "MethodScope")))))))
(DFunDef false "methodUndecided" ((PVar "gctx") (PVar "prog") (PVar "n") (PVar "cs") (PList)) (EMatch (EApp (EApp (EVar "methodPreludeRow") (EVar "n")) (EVar "cs")) (arm (PCon "Some" (PVar "r")) () (EApp (EVar "MsOne") (EVar "r"))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "methodAliasedScope") (EVar "gctx")) (EVar "prog")) (EVar "n")) (EVar "cs")))))
(DFunDef false "methodUndecided" ((PVar "_gctx") PWild PWild PWild (PVar "admitted")) (EApp (EVar "MsMany") (EApp (EVar "sortIfaceRefs") (EApp (EApp (EMethodRef "map") (EVar "methodRowIface")) (EVar "admitted")))))
(DTypeSig false "methodAliasedScope" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "MethodRow")) (TyCon "MethodScope"))))))
(DFunDef false "methodAliasedScope" ((PVar "gctx") (PVar "prog") (PVar "n") (PVar "cs")) (EBlock (DoLet false false (PVar "sites") (EApp (EVar "aliasImportSites") (EVar "prog"))) (DoExpr (EMatch (EApp (EApp (EVar "filterList") (ELam ((PVar "r")) (EApp (EApp (EApp (EApp (EVar "aliasWitnessesMethod") (EVar "gctx")) (EVar "sites")) (EVar "n")) (EFieldAccess (EVar "r") "mrIdent")))) (EVar "cs")) (arm (PList) () (EVar "MsAbsent")) (arm (PList (PVar "only")) () (EApp (EVar "MsOne") (EVar "only"))) (arm (PVar "aliased") () (EApp (EVar "MsMany") (EApp (EVar "sortIfaceRefs") (EApp (EApp (EMethodRef "map") (EVar "methodRowIface")) (EVar "aliased")))))))))
(DTypeSig false "aliasWitnessesMethod" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Loc"))) (TyFun (TyCon "String") (TyFun (TyCon "Ident") (TyCon "Bool"))))))
(DFunDef false "aliasWitnessesMethod" ((PVar "gctx") (PVar "sites") (PVar "n") (PVar "ident")) (EApp (EApp (EVar "anyList") (ELam ((PVar "s")) (EBlock (DoLet false false (PVar "dep") (EApp (EVar "joinDot") (EApp (EVar "fst") (EVar "s")))) (DoExpr (EBinOp "&&" (EBinOp "/=" (EVar "dep") (ELit (LString "core"))) (EApp (EApp (EApp (EApp (EVar "depExportsMethodIdent") (EVar "gctx")) (EVar "dep")) (EVar "n")) (EVar "ident"))))))) (EVar "sites")))
(DTypeSig false "methodScopeHere" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyCon "MethodScope"))))
(DFunDef false "methodScopeHere" ((PVar "mctx") (PVar "n")) (EMatch (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "methodScopeCtxRef") "value") (arm (PCon "None") () (EVar "MsAbsent")) (arm (PCon "Some" (PTuple (PVar "prog") (PVar "cur"))) () (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "methodScopeMemoRef") "value")) (arm (PCon "Some" (PVar "s")) () (EVar "s")) (arm (PCon "None") () (EBlock (DoLet false false (PVar "s") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "methodScopeAt") (EFieldAccess (EVar "mctx") "mcGraph")) (EApp (EApp (EVar "omHasKey") (EVar "n")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "standaloneValuesRef") "value"))) (EVar "prog")) (EVar "n")) (EVar "cur")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "declEnvsRef") "value"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "methodScopeMemoRef")) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (EVar "s")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "methodScopeMemoRef") "value")))) (DoExpr (EVar "s"))))))))
(DTypeSig true "methodEntryHere" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "MethodEntry")))))
(DFunDef false "methodEntryHere" ((PVar "mctx") (PVar "n")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "methodAliasEntriesRef") "value")) (arm (PCon "Some" (PVar "e")) () (EApp (EVar "Some") (EVar "e"))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "methodScopeHere") (EVar "mctx")) (EVar "n")) (arm (PCon "MsOne" (PVar "r")) () (EApp (EVar "Some") (EFieldAccess (EVar "r") "mrEntry"))) (arm PWild () (EVar "None"))))))
(DTypeSig true "methodIfaceHere" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "IfaceRef")))))
(DFunDef false "methodIfaceHere" ((PVar "mctx") (PVar "n")) (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "iface") PWild PWild PWild)) (EVar "iface"))) (EApp (EApp (EVar "methodEntryHere") (EVar "mctx")) (EVar "n"))))
(DTypeSig true "methodAdmittedHere" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "IfaceRef")))))
(DFunDef false "methodAdmittedHere" ((PVar "mctx") (PVar "n")) (EMatch (EApp (EApp (EVar "methodScopeHere") (EVar "mctx")) (EVar "n")) (arm (PCon "MsMany" (PVar "ifs")) () (EVar "ifs")) (arm PWild () (EListLit))))
(DTypeSig true "methodAdmissionHere" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "IfaceRef"))))))
(DFunDef false "methodAdmissionHere" ((PVar "mctx") (PVar "n")) (EMatch (EApp (EApp (EVar "methodIfaceHere") (EVar "mctx")) (EVar "n")) (arm (PCon "Some" (PVar "iface")) () (EApp (EVar "Some") (EListLit (EVar "iface")))) (arm (PCon "None") () (EIf (EApp (EVar "isEmptyL") (EApp (EApp (EVar "methodAdmittedHere") (EVar "mctx")) (EVar "n"))) (EVar "None") (EApp (EVar "Some") (EListLit))))))
(DTypeSig true "methodVisibleHere" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "MethodRow")))))
(DFunDef false "methodVisibleHere" ((PVar "mctx") (PVar "n")) (EMatch (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "methodScopeCtxRef") "value") (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PTuple PWild (PVar "cur"))) () (EApp (EApp (EApp (EVar "methodCandsAt") (EVar "n")) (EVar "cur")) (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "declEnvsRef") "value") "deMethods")))))
(DTypeSig true "methodDispatchIdx" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "methodDispatchIdx" ((PVar "mctx") (PVar "name")) (EApp (EApp (EApp (EVar "dispatchIdxScoped") (EVar "mctx")) (EVar "name")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "methodDispatchIdxByIdRef") "value")))
(DTypeSig true "argDispatchOf" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "argDispatchOf" ((PVar "mctx") (PVar "name")) (EApp (EApp (EApp (EVar "dispatchIdxScoped") (EVar "mctx")) (EVar "name")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "argDispatchIdxByIdRef") "value")))
(DTypeSig false "dispatchIdxScoped" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "IfaceRef") (TyCon "String")) (TyCon "Int"))) (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "dispatchIdxScoped" ((PVar "mctx") (PVar "name") (PVar "byId")) (EMatch (EApp (EApp (EVar "methodIfaceHere") (EVar "mctx")) (EVar "name")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "iface")) () (EApp (EApp (EApp (EVar "lookupIdxById") (EVar "iface")) (EApp (EApp (EVar "originMethodName") (EVar "mctx")) (EVar "name"))) (EVar "byId")))))
(DTypeSig true "ieImplExistsForHead" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "ImplEnv") (TyFun (TyCon "String") (TyFun (TyCon "HeadKey") (TyCon "Bool"))))))
(DFunDef false "ieImplExistsForHead" ((PVar "mctx") (PVar "env") (PVar "name") (PVar "hk")) (EApp (EApp (EApp (EApp (EApp (EVar "ieImplExistsForHeadOf") (EVar "mctx")) (EVar "env")) (EVar "name")) (EVar "hk")) (EApp (EApp (EVar "methodAdmissionHere") (EVar "mctx")) (EVar "name"))))
(DTypeSig true "admittedIfaceWord" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "admittedIfaceWord" ((PVar "mctx") (PVar "name")) (EMatch (EApp (EApp (EVar "methodIfaceHere") (EVar "mctx")) (EVar "name")) (arm (PCon "Some" (PVar "iface")) () (EApp (EApp (EVar "ifaceWordOf") (EFieldAccess (EVar "iface") "irOrigin")) (EFieldAccess (EVar "iface") "irName"))) (arm (PCon "None") () (ELit (LString "")))))
(DTypeSig true "aliasQualifiedMethodEntries" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "OrdMap") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "String")) (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind")))))) (TyApp (TyCon "OrdMap") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "String")) (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind"))))))))))
(DFunDef false "aliasQualifiedMethodEntries" ((PVar "mctx") (PVar "prog") (PVar "tab")) (EBlock (DoLet false false (PVar "grouped") (EApp (EApp (EVar "aliasMethodKeyGroup") (EApp (EApp (EVar "aliasMethodKeyCands") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "prog"))) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "aliasMethodKeyApply") (EVar "mctx")) (EVar "grouped")) (EApp (EVar "omKeys") (EVar "grouped"))) (EVar "tab")))))
(DTypeSig false "aliasMethodKeyCands" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String") (TyCon "Ident") (TyCon "Loc"))))))
(DFunDef false "aliasMethodKeyCands" ((PVar "gctx") (PVar "prog")) (EBinOp "++" (EApp (EApp (EVar "useKeyCands") (EApp (EVar "moduleAliasKeys") (EVar "gctx"))) (EVar "prog")) (EApp (EApp (EVar "memberAliasCands") (EVar "gctx")) (EVar "prog"))))
(DTypeSig true "memberAliasCands" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String") (TyCon "Ident") (TyCon "Loc"))))))
(DFunDef false "memberAliasCands" ((PVar "gctx") (PVar "prog")) (EBlock (DoLet false false (PVar "own") (EApp (EApp (EVar "namesToSet") (EApp (EVar "declTopFnNames") (EVar "prog"))) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EVar "filterList") (ELam ((PVar "r")) (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EApp (EVar "aliasRowKey") (EVar "r"))) (EVar "own"))))) (EApp (EApp (EVar "useKeyCands") (EApp (EVar "memberAliasKeys") (EVar "gctx"))) (EVar "prog"))))))
(DTypeSig true "useKeyCands" (TyFun (TyFun (TyCon "UsePath") (TyFun (TyCon "Loc") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String") (TyCon "Ident") (TyCon "Loc"))))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String") (TyCon "Ident") (TyCon "Loc"))))))
(DFunDef false "useKeyCands" (PWild (PList)) (EListLit))
(DFunDef false "useKeyCands" ((PVar "f") (PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "useKeyCands") (EVar "f")) (EListLit (EVar "d"))) (EApp (EApp (EVar "useKeyCands") (EVar "f")) (EVar "rest"))))
(DFunDef false "useKeyCands" ((PVar "f") (PCons (PCon "DUse" PWild (PVar "path") (PVar "loc")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "f") (EVar "path")) (EVar "loc")) (EApp (EApp (EVar "useKeyCands") (EVar "f")) (EVar "rest"))))
(DFunDef false "useKeyCands" ((PVar "f") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "useKeyCands") (EVar "f")) (EVar "rest")))
(DTypeSig true "moduleAliasKeys" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "UsePath") (TyFun (TyCon "Loc") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String") (TyCon "Ident") (TyCon "Loc")))))))
(DFunDef false "moduleAliasKeys" ((PVar "gctx") (PAs "path" (PCon "UseAlias" PWild (PVar "a"))) (PVar "loc")) (EApp (EApp (EApp (EApp (EVar "aliasMethodKeysFor") (EVar "gctx")) (EVar "a")) (EApp (EVar "useModId") (EVar "path"))) (EVar "loc")))
(DFunDef false "moduleAliasKeys" ((PVar "_gctx") PWild PWild) (EListLit))
(DTypeSig false "memberAliasKeys" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "UsePath") (TyFun (TyCon "Loc") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String") (TyCon "Ident") (TyCon "Loc")))))))
(DFunDef false "memberAliasKeys" ((PVar "gctx") (PAs "path" (PCon "UseGroup" PWild (PVar "ms"))) (PVar "loc")) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EVar "memberAliasMethodKeys") (EVar "gctx")) (EApp (EVar "useModId") (EVar "path"))) (EVar "loc"))) (EVar "ms")))
(DFunDef false "memberAliasKeys" ((PVar "_gctx") PWild PWild) (EListLit))
(DTypeSig false "memberAliasMethodKeys" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyFun (TyCon "Loc") (TyFun (TyCon "UseMember") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String") (TyCon "Ident") (TyCon "Loc"))))))))
(DFunDef false "memberAliasMethodKeys" ((PVar "gctx") (PVar "mid") (PVar "loc") (PVar "m")) (EMatch (EApp (EVar "useMemberAlias") (EVar "m")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "local")) () (EMatch (EApp (EApp (EVar "omLookup") (EVar "mid")) (EApp (EApp (EVar "methodExportsIndex") (EVar "gctx")) (ELit LUnit))) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "rows")) () (EBlock (DoLet false false (PVar "origin") (EApp (EVar "useMemberOrigin") (EVar "m"))) (DoExpr (EApp (EApp (EMethodRef "map") (ELam ((PVar "r")) (ETuple (EVar "local") (EVar "origin") (EVar "mid") (EApp (EVar "snd") (EVar "r")) (EVar "loc")))) (EApp (EApp (EVar "filterList") (ELam ((PVar "r")) (EBinOp "==" (EApp (EVar "fst") (EVar "r")) (EVar "origin")))) (EVar "rows"))))))))))
(DTypeSig false "aliasMethodKeysFor" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Loc") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String") (TyCon "Ident") (TyCon "Loc"))))))))
(DFunDef false "aliasMethodKeysFor" ((PVar "gctx") (PVar "a") (PVar "mid") (PVar "loc")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "mid")) (EApp (EApp (EVar "methodExportsIndex") (EVar "gctx")) (ELit LUnit))) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "rows")) () (EApp (EApp (EApp (EApp (EVar "aliasMethodKeyRows") (EVar "a")) (EVar "mid")) (EVar "loc")) (EVar "rows")))))
(DTypeSig false "aliasMethodKeyRows" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Loc") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ident"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String") (TyCon "Ident") (TyCon "Loc"))))))))
(DFunDef false "aliasMethodKeyRows" (PWild PWild PWild (PList)) (EListLit))
(DFunDef false "aliasMethodKeyRows" ((PVar "a") (PVar "mid") (PVar "loc") (PCons (PTuple (PVar "mname") (PVar "ident")) (PVar "rest"))) (EBinOp "::" (ETuple (EApp (EApp (EVar "qualifiedLocal") (EVar "a")) (EVar "mname")) (EVar "mname") (EVar "mid") (EVar "ident") (EVar "loc")) (EApp (EApp (EApp (EApp (EVar "aliasMethodKeyRows") (EVar "a")) (EVar "mid")) (EVar "loc")) (EVar "rest"))))
(DTypeSig false "aliasMethodKeyGroup" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String") (TyCon "Ident") (TyCon "Loc"))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String") (TyCon "Ident") (TyCon "Loc")))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String") (TyCon "Ident") (TyCon "Loc")))))))
(DFunDef false "aliasMethodKeyGroup" ((PList) (PVar "g")) (EVar "g"))
(DFunDef false "aliasMethodKeyGroup" ((PCons (PVar "r") (PVar "rest")) (PVar "g")) (EBlock (DoLet false false (PVar "k") (EApp (EVar "aliasRowKey") (EVar "r"))) (DoExpr (EApp (EApp (EVar "aliasMethodKeyGroup") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "k")) (EBinOp "++" (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "k")) (EVar "g"))) (EListLit (EVar "r")))) (EVar "g"))))))
(DTypeSig false "aliasMethodKeyApply" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String") (TyCon "Ident") (TyCon "Loc")))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "String")) (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind")))))) (TyApp (TyCon "OrdMap") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "String")) (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind")))))))))))
(DFunDef false "aliasMethodKeyApply" ((PVar "_mctx") PWild (PList) (PVar "tab")) (EVar "tab"))
(DFunDef false "aliasMethodKeyApply" ((PVar "mctx") (PVar "g") (PCons (PVar "k") (PVar "rest")) (PVar "tab")) (EBlock (DoLet false false (PVar "hits") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "k")) (EVar "g")))) (DoLet false false (PVar "tab2") (EMatch (EApp (EApp (EVar "aliasRowIdents") (EVar "hits")) (EListLit)) (arm (PList) () (EVar "tab")) (arm (PList PWild) () (EApp (EApp (EApp (EApp (EVar "aliasMethodKeyEntry") (EVar "mctx")) (EVar "k")) (EVar "hits")) (EVar "tab"))) (arm PWild () (EBlock (DoExpr (EApp (EApp (EApp (EApp (EVar "pushTypeErrorOnceAt") (EVar "mctx")) (EVar "TAmbiguousAliasMethod")) (EApp (EVar "aliasRowLastLoc") (EVar "hits"))) (EApp (EApp (EVar "aliasAmbiguityMsg") (EVar "k")) (EVar "hits")))) (DoExpr (EVar "tab")))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "aliasMethodKeyApply") (EVar "mctx")) (EVar "g")) (EVar "rest")) (EVar "tab2")))))
(DTypeSig false "aliasMethodKeyEntry" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String") (TyCon "Ident") (TyCon "Loc"))) (TyFun (TyApp (TyCon "OrdMap") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "String")) (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind")))))) (TyApp (TyCon "OrdMap") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "String")) (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind")))))))))))
(DFunDef false "aliasMethodKeyEntry" ((PVar "_mctx") PWild (PList) (PVar "tab")) (EVar "tab"))
(DFunDef false "aliasMethodKeyEntry" ((PVar "mctx") (PVar "k") (PCons (PTuple PWild (PVar "mname") PWild (PVar "ident") PWild) PWild) (PVar "tab")) (EMatch (EApp (EApp (EVar "methodRowById") (EVar "ident")) (EApp (EApp (EVar "methodVisibleHere") (EVar "mctx")) (EVar "mname"))) (arm (PCon "None") () (EVar "tab")) (arm (PCon "Some" (PVar "r")) () (EApp (EApp (EApp (EVar "omInsert") (EVar "k")) (EFieldAccess (EVar "r") "mrEntry")) (EVar "tab")))))
(DTypeSig false "aliasRowKey" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyCon "String") (TyCon "Ident") (TyCon "Loc")) (TyCon "String")))
(DFunDef false "aliasRowKey" ((PTuple (PVar "k") PWild PWild PWild PWild)) (EVar "k"))
(DTypeSig true "aliasMethodSpellings" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "aliasMethodSpellings" ((PVar "gctx") (PVar "prog")) (EApp (EApp (EMethodRef "map") (EVar "aliasRowSpelling")) (EApp (EApp (EVar "aliasMethodKeyCands") (EVar "gctx")) (EVar "prog"))))
(DTypeSig true "aliasRowSpelling" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyCon "String") (TyCon "Ident") (TyCon "Loc")) (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "aliasRowSpelling" ((PTuple (PVar "k") (PVar "mname") PWild PWild PWild)) (ETuple (EVar "k") (EVar "mname")))
(DTypeSig false "aliasRowModule" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyCon "String") (TyCon "Ident") (TyCon "Loc")) (TyCon "String")))
(DFunDef false "aliasRowModule" ((PTuple PWild PWild (PVar "m") PWild PWild)) (EVar "m"))
(DTypeSig false "aliasRowIdents" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String") (TyCon "Ident") (TyCon "Loc"))) (TyFun (TyApp (TyCon "List") (TyCon "Ident")) (TyApp (TyCon "List") (TyCon "Ident")))))
(DFunDef false "aliasRowIdents" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "aliasRowIdents" ((PCons (PTuple PWild PWild PWild (PVar "i") PWild) (PVar "rest")) (PVar "acc")) (EIf (EApp (EApp (EVar "anyList") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EVar "i")))) (EVar "acc")) (EApp (EApp (EVar "aliasRowIdents") (EVar "rest")) (EVar "acc")) (EIf (EVar "otherwise") (EApp (EApp (EVar "aliasRowIdents") (EVar "rest")) (EBinOp "++" (EVar "acc") (EListLit (EVar "i")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "aliasRowLastLoc" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String") (TyCon "Ident") (TyCon "Loc"))) (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "aliasRowLastLoc" ((PList)) (EVar "None"))
(DFunDef false "aliasRowLastLoc" ((PList (PTuple PWild PWild PWild PWild (PVar "l")))) (EApp (EVar "Some") (EVar "l")))
(DFunDef false "aliasRowLastLoc" ((PCons PWild (PVar "rest"))) (EApp (EVar "aliasRowLastLoc") (EVar "rest")))
(DTypeSig false "aliasAmbiguityMsg" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String") (TyCon "Ident") (TyCon "Loc"))) (TyCon "String"))))
(DFunDef false "aliasAmbiguityMsg" ((PVar "k") (PVar "hits")) (EBlock (DoLet false false (PVar "mods") (EApp (EApp (EVar "joinWith") (ELit (LString " and "))) (EApp (EApp (EMethodRef "map") (EVar "backticked")) (EApp (EVar "sortUniqS") (EApp (EApp (EMethodRef "map") (EVar "aliasRowModule")) (EVar "hits")))))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EMethodRef "display") (EVar "k"))) (ELit (LString "` is ambiguous: the alias names more than one module declaring a method `"))) (EApp (EMethodRef "display") (EApp (EVar "aliasRowMethodOf") (EVar "hits")))) (ELit (LString "` ("))) (EApp (EMethodRef "display") (EVar "mods"))) (ELit (LString "); give those imports different alias names"))))))
(DTypeSig false "aliasRowMethodOf" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String") (TyCon "Ident") (TyCon "Loc"))) (TyCon "String")))
(DFunDef false "aliasRowMethodOf" ((PList)) (ELit (LString "")))
(DFunDef false "aliasRowMethodOf" ((PCons (PTuple PWild (PVar "m") PWild PWild PWild) PWild)) (EVar "m"))
(DTypeSig false "methodCandImported" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "Ident") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "String")) (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind")))))) (TyCon "Bool"))))))
(DFunDef false "methodCandImported" ((PVar "gctx") (PVar "prog") (PVar "n") (PVar "c")) (EApp (EApp (EApp (EApp (EApp (EVar "anyUsePathBinds") (EVar "gctx")) (EVar "prog")) (EVar "False")) (EVar "n")) (EVar "c")))
(DTypeSig false "methodCandAdmitted" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "Ident") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "String")) (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind")))))) (TyCon "Bool"))))))
(DFunDef false "methodCandAdmitted" ((PVar "gctx") (PVar "prog") (PVar "n") (PVar "c")) (EApp (EApp (EApp (EApp (EApp (EVar "anyUsePathBinds") (EVar "gctx")) (EVar "prog")) (EVar "True")) (EVar "n")) (EVar "c")))
(DTypeSig false "anyUsePathBinds" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "Ident") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "String")) (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind")))))) (TyCon "Bool")))))))
(DFunDef false "anyUsePathBinds" ((PVar "_gctx") (PList) PWild PWild PWild) (EVar "False"))
(DFunDef false "anyUsePathBinds" ((PVar "gctx") (PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest")) (PVar "wide") (PVar "n") (PVar "c")) (EBinOp "||" (EApp (EApp (EApp (EApp (EApp (EVar "anyUsePathBinds") (EVar "gctx")) (EListLit (EVar "d"))) (EVar "wide")) (EVar "n")) (EVar "c")) (EApp (EApp (EApp (EApp (EApp (EVar "anyUsePathBinds") (EVar "gctx")) (EVar "rest")) (EVar "wide")) (EVar "n")) (EVar "c"))))
(DFunDef false "anyUsePathBinds" ((PVar "gctx") (PCons (PCon "DUse" PWild (PVar "path") PWild) (PVar "rest")) (PVar "wide") (PVar "n") (PVar "c")) (EBinOp "||" (EApp (EApp (EApp (EApp (EApp (EVar "usePathWitnesses") (EVar "gctx")) (EVar "path")) (EVar "wide")) (EVar "n")) (EVar "c")) (EApp (EApp (EApp (EApp (EApp (EVar "anyUsePathBinds") (EVar "gctx")) (EVar "rest")) (EVar "wide")) (EVar "n")) (EVar "c"))))
(DFunDef false "anyUsePathBinds" ((PVar "gctx") (PCons PWild (PVar "rest")) (PVar "wide") (PVar "n") (PVar "c")) (EApp (EApp (EApp (EApp (EApp (EVar "anyUsePathBinds") (EVar "gctx")) (EVar "rest")) (EVar "wide")) (EVar "n")) (EVar "c")))
(DTypeSig false "usePathWitnesses" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "UsePath") (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "Ident") (TyTuple (TyCon "IfaceRef") (TyApp (TyCon "List") (TyCon "String")) (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Kind")))))) (TyCon "Bool")))))))
(DFunDef false "usePathWitnesses" ((PVar "gctx") (PVar "path") (PVar "wide") (PVar "n") (PTuple (PVar "ident") (PTuple (PVar "iface") PWild PWild PWild))) (EBlock (DoLet false false (PVar "dep") (EApp (EVar "useModId") (EVar "path"))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EBinOp "/=" (EVar "dep") (ELit (LString "core"))) (EApp (EApp (EApp (EApp (EVar "usePathAdmitsDecl") (EVar "path")) (EVar "wide")) (EVar "n")) (EVar "iface"))) (EApp (EApp (EApp (EApp (EVar "depExportsMethodIdent") (EVar "gctx")) (EVar "dep")) (EVar "n")) (EVar "ident"))))))
(DTypeSig false "depExportsMethodIdent" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Ident") (TyCon "Bool"))))))
(DFunDef false "depExportsMethodIdent" ((PVar "gctx") (PVar "dep") (PVar "n") (PVar "ident")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "dep")) (EApp (EApp (EVar "methodExportsIndex") (EVar "gctx")) (ELit LUnit))) (arm (PCon "None") () (EVar "False")) (arm (PCon "Some" (PVar "es")) () (EApp (EApp (EApp (EVar "exportsIdentFor") (EVar "n")) (EVar "ident")) (EVar "es")))))
(DTypeSig true "insertCtorPop" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "SpellingPop") (TyCon "Scheme")) (TyApp (TyCon "SpellingPop") (TyCon "Scheme"))))))
(DFunDef false "insertCtorPop" ((PVar "_env") (PList) (PVar "pop")) (EVar "pop"))
(DFunDef false "insertCtorPop" ((PVar "env") (PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest")) (PVar "pop")) (EApp (EApp (EApp (EVar "insertCtorPop") (EVar "env")) (EVar "rest")) (EApp (EApp (EApp (EVar "insertCtorPop") (EVar "env")) (EListLit (EVar "d"))) (EVar "pop"))))
(DFunDef false "insertCtorPop" ((PVar "env") (PCons (PRec "DData" ((rf "dataName" None) (rf "dataCtors" None) (rf "dataOrigin" None)) true) (PVar "rest")) (PVar "pop")) (EApp (EApp (EApp (EVar "insertCtorPop") (EVar "env")) (EVar "rest")) (EApp (EApp (EApp (EApp (EApp (EVar "insertCtorVariants") (EVar "env")) (EVar "dataName")) (EVar "dataOrigin")) (EVar "dataCtors")) (EVar "pop"))))
(DFunDef false "insertCtorPop" ((PVar "env") (PCons (PRec "DNewtype" ((rf "newtypeName" None) (rf "newtypeCtor" None) (rf "newtypeOrigin" None)) true) (PVar "rest")) (PVar "pop")) (EApp (EApp (EApp (EVar "insertCtorPop") (EVar "env")) (EVar "rest")) (EApp (EApp (EApp (EApp (EApp (EVar "insertCtorRow") (EVar "env")) (EVar "newtypeName")) (EVar "newtypeOrigin")) (EVar "newtypeCtor")) (EVar "pop"))))
(DFunDef false "insertCtorPop" ((PVar "env") (PCons PWild (PVar "rest")) (PVar "pop")) (EApp (EApp (EApp (EVar "insertCtorPop") (EVar "env")) (EVar "rest")) (EVar "pop")))
(DTypeSig false "insertCtorVariants" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyCon "TyConOrigin") (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyFun (TyApp (TyCon "SpellingPop") (TyCon "Scheme")) (TyApp (TyCon "SpellingPop") (TyCon "Scheme"))))))))
(DFunDef false "insertCtorVariants" ((PVar "_env") PWild PWild (PList) (PVar "pop")) (EVar "pop"))
(DFunDef false "insertCtorVariants" ((PVar "env") (PVar "tyName") (PVar "o") (PCons (PCon "Variant" (PVar "cn") PWild) (PVar "rest")) (PVar "pop")) (EApp (EApp (EApp (EApp (EApp (EVar "insertCtorVariants") (EVar "env")) (EVar "tyName")) (EVar "o")) (EVar "rest")) (EApp (EApp (EApp (EApp (EApp (EVar "insertCtorRow") (EVar "env")) (EVar "tyName")) (EVar "o")) (EVar "cn")) (EVar "pop"))))
(DTypeSig false "insertCtorRow" (TyFun (TyCon "TcEnv") (TyFun (TyCon "String") (TyFun (TyCon "TyConOrigin") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "SpellingPop") (TyCon "Scheme")) (TyApp (TyCon "SpellingPop") (TyCon "Scheme"))))))))
(DFunDef false "insertCtorRow" ((PVar "env") (PVar "tyName") (PVar "o") (PVar "cn") (PVar "pop")) (EMatch (EApp (EApp (EVar "lookupCtor") (EVar "env")) (EVar "cn")) (arm (PCon "None") () (EVar "pop")) (arm (PCon "Some" (PVar "s")) () (EApp (EApp (EApp (EApp (EApp (EVar "spInsert") (EApp (EApp (EApp (EVar "mkIdent") (EVar "NsCtor")) (EVar "o")) (EVar "cn"))) (EVar "cn")) (EVar "tyName")) (EVar "s")) (EVar "pop")))))
(DTypeSig true "applyCtorScopeOverrides" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "TcEnv") (TyCon "TcEnv"))))
(DFunDef false "applyCtorScopeOverrides" ((PVar "prog") (PVar "env")) (EBlock (DoLet false false (PVar "pop") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph") "crossRun") "universeCtorPop") "value")) (DoExpr (EApp (EApp (EApp (EApp (EVar "overrideScopedCtors") (EVar "prog")) (EApp (EVar "spRows") (EVar "pop"))) (EApp (EVar "spCollided") (EVar "pop"))) (EVar "env")))))
(DTypeSig false "overrideScopedCtors" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "Ident") (TyCon "String") (TyCon "Scheme")))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "TcEnv") (TyCon "TcEnv"))))))
(DFunDef false "overrideScopedCtors" (PWild PWild (PList) (PVar "env")) (EVar "env"))
(DFunDef false "overrideScopedCtors" ((PVar "prog") (PVar "cands") (PCons (PVar "n") (PVar "rest")) (PVar "env")) (EBlock (DoLet false false (PVar "env2") (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "cands")) (arm (PCon "None") () (EVar "env")) (arm (PCon "Some" (PVar "cs")) () (EMatch (EApp (EApp (EApp (EApp (EVar "scopedCtorEntry") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule") "mcGraph")) (EVar "prog")) (EVar "n")) (EVar "cs")) (arm (PCon "None") () (EVar "env")) (arm (PCon "Some" (PVar "s")) () (EApp (EApp (EApp (EVar "addCtor") (EVar "env")) (EVar "n")) (EVar "s"))))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "overrideScopedCtors") (EVar "prog")) (EVar "cands")) (EVar "rest")) (EVar "env2")))))
(DTypeSig false "scopedCtorEntry" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Ident") (TyCon "String") (TyCon "Scheme"))) (TyApp (TyCon "Option") (TyCon "Scheme")))))))
(DFunDef false "scopedCtorEntry" ((PVar "gctx") (PVar "prog") (PVar "n") (PVar "cs")) (EIf (EApp (EApp (EVar "declaresCtorNamed") (EVar "prog")) (EVar "n")) (EVar "None") (EApp (EApp (EApp (EApp (EVar "importedCtorEntry") (EVar "gctx")) (EVar "prog")) (EVar "n")) (EVar "cs"))))
(DTypeSig false "importedCtorEntry" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Ident") (TyCon "String") (TyCon "Scheme"))) (TyApp (TyCon "Option") (TyCon "Scheme")))))))
(DFunDef false "importedCtorEntry" ((PVar "gctx") (PVar "prog") (PVar "n") (PVar "cs")) (EMatch (EApp (EApp (EVar "filterList") (ELam ((PVar "c")) (EApp (EApp (EApp (EApp (EVar "ctorCandImported") (EVar "gctx")) (EVar "prog")) (EVar "n")) (EVar "c")))) (EVar "cs")) (arm (PList (PVar "only")) () (EApp (EVar "Some") (EApp (EVar "ctorCandScheme") (EVar "only")))) (arm PWild () (EVar "None"))))
(DTypeSig false "ctorCandScheme" (TyFun (TyTuple (TyCon "Ident") (TyCon "String") (TyCon "Scheme")) (TyCon "Scheme")))
(DFunDef false "ctorCandScheme" ((PTuple PWild PWild (PVar "s"))) (EVar "s"))
(DTypeSig false "declaresCtorNamed" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "declaresCtorNamed" ((PList) PWild) (EVar "False"))
(DFunDef false "declaresCtorNamed" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest")) (PVar "n")) (EBinOp "||" (EApp (EApp (EVar "declaresCtorNamed") (EListLit (EVar "d"))) (EVar "n")) (EApp (EApp (EVar "declaresCtorNamed") (EVar "rest")) (EVar "n"))))
(DFunDef false "declaresCtorNamed" ((PCons (PVar "d") (PVar "rest")) (PVar "n")) (EBinOp "||" (EApp (EApp (EVar "declCtorNamed") (EVar "n")) (EVar "d")) (EApp (EApp (EVar "declaresCtorNamed") (EVar "rest")) (EVar "n"))))
(DTypeSig false "ctorCandImported" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "Ident") (TyCon "String") (TyCon "Scheme")) (TyCon "Bool"))))))
(DFunDef false "ctorCandImported" ((PVar "gctx") (PVar "prog") (PVar "n") (PTuple (PVar "ident") (PVar "owner") PWild)) (EApp (EApp (EApp (EApp (EApp (EVar "anyUsePathBindsCtor") (EVar "gctx")) (EVar "prog")) (EVar "n")) (EVar "owner")) (EVar "ident")))
(DTypeSig false "anyUsePathBindsCtor" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Ident") (TyCon "Bool")))))))
(DFunDef false "anyUsePathBindsCtor" ((PVar "_gctx") (PList) PWild PWild PWild) (EVar "False"))
(DFunDef false "anyUsePathBindsCtor" ((PVar "gctx") (PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest")) (PVar "n") (PVar "owner") (PVar "ident")) (EBinOp "||" (EApp (EApp (EApp (EApp (EApp (EVar "anyUsePathBindsCtor") (EVar "gctx")) (EListLit (EVar "d"))) (EVar "n")) (EVar "owner")) (EVar "ident")) (EApp (EApp (EApp (EApp (EApp (EVar "anyUsePathBindsCtor") (EVar "gctx")) (EVar "rest")) (EVar "n")) (EVar "owner")) (EVar "ident"))))
(DFunDef false "anyUsePathBindsCtor" ((PVar "gctx") (PCons (PCon "DUse" PWild (PVar "path") PWild) (PVar "rest")) (PVar "n") (PVar "owner") (PVar "ident")) (EBinOp "||" (EApp (EApp (EApp (EApp (EApp (EVar "usePathWitnessesCtor") (EVar "gctx")) (EVar "path")) (EVar "n")) (EVar "owner")) (EVar "ident")) (EApp (EApp (EApp (EApp (EApp (EVar "anyUsePathBindsCtor") (EVar "gctx")) (EVar "rest")) (EVar "n")) (EVar "owner")) (EVar "ident"))))
(DFunDef false "anyUsePathBindsCtor" ((PVar "gctx") (PCons PWild (PVar "rest")) (PVar "n") (PVar "owner") (PVar "ident")) (EApp (EApp (EApp (EApp (EApp (EVar "anyUsePathBindsCtor") (EVar "gctx")) (EVar "rest")) (EVar "n")) (EVar "owner")) (EVar "ident")))
(DTypeSig false "usePathWitnessesCtor" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "UsePath") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Ident") (TyCon "Bool")))))))
(DFunDef false "usePathWitnessesCtor" ((PVar "gctx") (PVar "path") (PVar "n") (PVar "owner") (PVar "ident")) (EBlock (DoLet false false (PVar "dep") (EApp (EVar "useModId") (EVar "path"))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EBinOp "/=" (EVar "dep") (ELit (LString "core"))) (EApp (EApp (EApp (EVar "usePathBindsCtor") (EVar "path")) (EVar "n")) (EVar "owner"))) (EApp (EApp (EApp (EApp (EVar "depExportsCtorIdent") (EVar "gctx")) (EVar "dep")) (EVar "n")) (EVar "ident"))))))
(DTypeSig false "usePathBindsCtor" (TyFun (TyCon "UsePath") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool")))))
(DFunDef false "usePathBindsCtor" ((PCon "UseGroup" PWild (PVar "ms")) (PVar "n") (PVar "owner")) (EApp (EApp (EApp (EVar "anyMemberBindsCtor") (EVar "n")) (EVar "owner")) (EVar "ms")))
(DFunDef false "usePathBindsCtor" ((PCon "UseWild" PWild) PWild PWild) (EVar "True"))
(DFunDef false "usePathBindsCtor" ((PCon "UseAlias" PWild PWild) PWild PWild) (EVar "True"))
(DFunDef false "usePathBindsCtor" (PWild PWild PWild) (EVar "False"))
(DTypeSig false "anyMemberBindsCtor" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "UseMember")) (TyCon "Bool")))))
(DFunDef false "anyMemberBindsCtor" (PWild PWild (PList)) (EVar "False"))
(DFunDef false "anyMemberBindsCtor" ((PVar "n") (PVar "owner") (PCons (PVar "m") (PVar "rest"))) (EBinOp "||" (EApp (EApp (EApp (EVar "memberBindsCtorName") (EVar "n")) (EVar "owner")) (EVar "m")) (EApp (EApp (EApp (EVar "anyMemberBindsCtor") (EVar "n")) (EVar "owner")) (EVar "rest"))))
(DTypeSig true "memberBindsCtorName" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "UseMember") (TyCon "Bool")))))
(DFunDef false "memberBindsCtorName" ((PVar "n") (PVar "owner") (PCon "UseMember" (PVar "mn") (PVar "ctors") PWild PWild)) (EBinOp "||" (EBinOp "==" (EVar "mn") (EVar "n")) (EBinOp "&&" (EVar "ctors") (EBinOp "==" (EVar "mn") (EVar "owner")))))
(DTypeSig false "depExportsCtorIdent" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Ident") (TyCon "Bool"))))))
(DFunDef false "depExportsCtorIdent" ((PVar "gctx") (PVar "dep") (PVar "n") (PVar "ident")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "dep")) (EApp (EApp (EVar "ctorExportsIndex") (EVar "gctx")) (ELit LUnit))) (arm (PCon "None") () (EVar "False")) (arm (PCon "Some" (PVar "es")) () (EApp (EApp (EApp (EVar "exportsCtorIdentFor") (EVar "n")) (EVar "ident")) (EVar "es")))))
(DTypeSig false "exportsCtorIdentFor" (TyFun (TyCon "String") (TyFun (TyCon "Ident") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "Ident"))) (TyCon "Bool")))))
(DFunDef false "exportsCtorIdentFor" (PWild PWild (PList)) (EVar "False"))
(DFunDef false "exportsCtorIdentFor" ((PVar "n") (PVar "ident") (PCons (PTuple (PVar "cn") PWild (PVar "ci")) (PVar "rest"))) (EIf (EBinOp "&&" (EBinOp "==" (EVar "cn") (EVar "n")) (EBinOp "==" (EVar "ci") (EVar "ident"))) (EVar "True") (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "exportsCtorIdentFor") (EVar "n")) (EVar "ident")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "insertRecordPop" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "SpellingPop") (TyCon "RecordInfo")) (TyApp (TyCon "SpellingPop") (TyCon "RecordInfo"))))))
(DFunDef false "insertRecordPop" ((PVar "_mctx") (PList) (PVar "pop")) (EVar "pop"))
(DFunDef false "insertRecordPop" ((PVar "mctx") (PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest")) (PVar "pop")) (EApp (EApp (EApp (EVar "insertRecordPop") (EVar "mctx")) (EVar "rest")) (EApp (EApp (EApp (EVar "insertRecordPop") (EVar "mctx")) (EListLit (EVar "d"))) (EVar "pop"))))
(DFunDef false "insertRecordPop" ((PVar "mctx") (PCons (PRec "DData" ((rf "dataName" None) (rf "dataCtors" None) (rf "dataOrigin" None)) true) (PVar "rest")) (PVar "pop")) (EApp (EApp (EApp (EVar "insertRecordPop") (EVar "mctx")) (EVar "rest")) (EApp (EApp (EApp (EApp (EApp (EVar "insertRecordVariants") (EVar "mctx")) (EVar "dataName")) (EVar "dataOrigin")) (EVar "dataCtors")) (EVar "pop"))))
(DFunDef false "insertRecordPop" ((PVar "mctx") (PCons PWild (PVar "rest")) (PVar "pop")) (EApp (EApp (EApp (EVar "insertRecordPop") (EVar "mctx")) (EVar "rest")) (EVar "pop")))
(DTypeSig false "insertRecordVariants" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "TyConOrigin") (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyFun (TyApp (TyCon "SpellingPop") (TyCon "RecordInfo")) (TyApp (TyCon "SpellingPop") (TyCon "RecordInfo"))))))))
(DFunDef false "insertRecordVariants" ((PVar "_mctx") PWild PWild (PList) (PVar "pop")) (EVar "pop"))
(DFunDef false "insertRecordVariants" ((PVar "mctx") (PVar "tyName") (PVar "o") (PCons (PCon "Variant" (PVar "cn") (PCon "ConNamed" PWild PWild)) (PVar "rest")) (PVar "pop")) (EApp (EApp (EApp (EApp (EApp (EVar "insertRecordVariants") (EVar "mctx")) (EVar "tyName")) (EVar "o")) (EVar "rest")) (EApp (EApp (EApp (EApp (EApp (EVar "insertRecordRow") (EVar "mctx")) (EVar "tyName")) (EVar "o")) (EVar "cn")) (EVar "pop"))))
(DFunDef false "insertRecordVariants" ((PVar "mctx") (PVar "tyName") (PVar "o") (PCons PWild (PVar "rest")) (PVar "pop")) (EApp (EApp (EApp (EApp (EApp (EVar "insertRecordVariants") (EVar "mctx")) (EVar "tyName")) (EVar "o")) (EVar "rest")) (EVar "pop")))
(DTypeSig false "insertRecordRow" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "TyConOrigin") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "SpellingPop") (TyCon "RecordInfo")) (TyApp (TyCon "SpellingPop") (TyCon "RecordInfo"))))))))
(DFunDef false "insertRecordRow" ((PVar "mctx") (PVar "tyName") (PVar "o") (PVar "cn") (PVar "pop")) (EMatch (EApp (EApp (EVar "lookupRecordByName") (EVar "mctx")) (EVar "cn")) (arm (PCon "None") () (EVar "pop")) (arm (PCon "Some" (PVar "ri")) () (EApp (EApp (EApp (EApp (EApp (EVar "spInsert") (EApp (EApp (EApp (EVar "mkIdent") (EVar "NsCtor")) (EVar "o")) (EVar "cn"))) (EVar "cn")) (EVar "tyName")) (EVar "ri")) (EVar "pop")))))
(DTypeSig true "applyRecordScopeOverrides" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Unit"))))
(DFunDef false "applyRecordScopeOverrides" ((PVar "mctx") (PVar "prog")) (EBlock (DoLet false false (PVar "pop") (EFieldAccess (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "crossRun") "universeRecordPop") "value")) (DoExpr (EApp (EApp (EApp (EApp (EVar "overrideScopedRecords") (EVar "mctx")) (EVar "prog")) (EApp (EVar "spRows") (EVar "pop"))) (EApp (EVar "spCollided") (EVar "pop"))))))
(DTypeSig false "overrideScopedRecords" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "Ident") (TyCon "String") (TyCon "RecordInfo")))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Unit"))))))
(DFunDef false "overrideScopedRecords" ((PVar "_mctx") PWild PWild (PList)) (ELit LUnit))
(DFunDef false "overrideScopedRecords" ((PVar "mctx") (PVar "prog") (PVar "cands") (PCons (PVar "n") (PVar "rest"))) (EBlock (DoExpr (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "cands")) (arm (PCon "None") () (ELit LUnit)) (arm (PCon "Some" (PVar "cs")) () (EMatch (EApp (EApp (EApp (EApp (EVar "scopedRecordEntry") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "prog")) (EVar "n")) (EVar "cs")) (arm (PCon "None") () (ELit LUnit)) (arm (PCon "Some" (PVar "ri")) () (EApp (EApp (EVar "setRef") (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "recordByNameRef")) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (EVar "ri")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "recordByNameRef") "value")))))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "overrideScopedRecords") (EVar "mctx")) (EVar "prog")) (EVar "cands")) (EVar "rest")))))
(DTypeSig false "scopedRecordEntry" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Ident") (TyCon "String") (TyCon "RecordInfo"))) (TyApp (TyCon "Option") (TyCon "RecordInfo")))))))
(DFunDef false "scopedRecordEntry" ((PVar "gctx") (PVar "prog") (PVar "n") (PVar "cs")) (EIf (EApp (EApp (EVar "declaresCtorNamed") (EVar "prog")) (EVar "n")) (EVar "None") (EApp (EApp (EApp (EApp (EVar "importedRecordEntry") (EVar "gctx")) (EVar "prog")) (EVar "n")) (EVar "cs"))))
(DTypeSig false "importedRecordEntry" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Ident") (TyCon "String") (TyCon "RecordInfo"))) (TyApp (TyCon "Option") (TyCon "RecordInfo")))))))
(DFunDef false "importedRecordEntry" ((PVar "gctx") (PVar "prog") (PVar "n") (PVar "cs")) (EMatch (EApp (EApp (EVar "filterList") (ELam ((PVar "c")) (EApp (EApp (EApp (EApp (EVar "recordCandImported") (EVar "gctx")) (EVar "prog")) (EVar "n")) (EVar "c")))) (EVar "cs")) (arm (PList (PVar "only")) () (EApp (EVar "Some") (EApp (EVar "recordCandInfo") (EVar "only")))) (arm PWild () (EVar "None"))))
(DTypeSig false "recordCandImported" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "Ident") (TyCon "String") (TyCon "RecordInfo")) (TyCon "Bool"))))))
(DFunDef false "recordCandImported" ((PVar "gctx") (PVar "prog") (PVar "n") (PTuple (PVar "ident") (PVar "owner") PWild)) (EApp (EApp (EApp (EApp (EApp (EVar "anyUsePathBindsCtor") (EVar "gctx")) (EVar "prog")) (EVar "n")) (EVar "owner")) (EVar "ident")))
(DTypeSig true "pickSchemesByDecl" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyFun (TyApp (TyCon "Registry") (TyCon "MethodSchemeRow")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Scheme")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EnvBinding")))))))))
(DFunDef false "pickSchemesByDecl" ((PVar "_mctx") (PList) PWild PWild PWild) (EListLit))
(DFunDef false "pickSchemesByDecl" ((PVar "mctx") (PCons (PVar "n") (PVar "ns")) (PVar "table") (PVar "byId") (PVar "sources")) (EBlock (DoLet false false (PVar "rest") (EApp (EApp (EApp (EApp (EApp (EVar "pickSchemesByDecl") (EVar "mctx")) (EVar "ns")) (EVar "table")) (EVar "byId")) (EVar "sources"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "admittedRowFor") (EVar "mctx")) (EVar "n")) (EVar "byId")) (arm (PCon "Some" (PVar "row")) () (EBinOp "::" (ETuple (EVar "n") (EApp (EVar "methodEnvBinding") (EVar "row"))) (EVar "rest"))) (arm (PCon "None") () (EMatch (EApp (EApp (EApp (EVar "admittedSchemeFor") (EVar "mctx")) (EVar "n")) (EVar "byId")) (arm (PCon "Some" (PVar "s")) () (EBinOp "::" (ETuple (EVar "n") (EApp (EVar "ordinaryEnvBinding") (EVar "s"))) (EVar "rest"))) (arm (PCon "None") () (EMatch (EApp (EApp (EApp (EApp (EVar "undecidedSchemeFor") (EVar "mctx")) (EVar "n")) (EVar "table")) (EVar "sources")) (arm (PCon "Some" (PVar "s")) () (EBinOp "::" (ETuple (EVar "n") (EApp (EVar "ordinaryEnvBinding") (EVar "s"))) (EVar "rest"))) (arm (PCon "None") () (EVar "rest"))))))))))
(DTypeSig false "undecidedSchemeFor" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Scheme")) (TyApp (TyCon "Option") (TyCon "Scheme")))))))
(DFunDef false "undecidedSchemeFor" ((PVar "mctx") (PVar "n") (PVar "table") (PVar "sources")) (EIf (EApp (EVar "isEmptyL") (EApp (EApp (EVar "methodAdmittedHere") (EVar "mctx")) (EVar "n"))) (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EVar "table")) (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "sources"))))
(DTypeSig true "importedMemberBindingNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "importedMemberBindingNames" ((PList)) (EListLit))
(DFunDef false "importedMemberBindingNames" ((PCons (PCon "DAttrib" PWild (PVar "decl")) (PVar "rest"))) (EBinOp "++" (EApp (EVar "importedMemberBindingNames") (EListLit (EVar "decl"))) (EApp (EVar "importedMemberBindingNames") (EVar "rest"))))
(DFunDef false "importedMemberBindingNames" ((PCons (PCon "DUse" PWild (PVar "path") PWild) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EMethodRef "map") (EVar "snd")) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EVar "importedBindings") (EVar "path")))) (EApp (EVar "importedMemberBindingNames") (EVar "rest"))))
(DFunDef false "importedMemberBindingNames" ((PCons PWild (PVar "rest"))) (EApp (EVar "importedMemberBindingNames") (EVar "rest")))
(DTypeSig true "annotateImportedMethodRows" (TyFun (TyCon "TcEnv") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "Registry") (TyCon "MethodSchemeRow")) (TyCon "TcEnv")))))))
(DFunDef false "annotateImportedMethodRows" ((PVar "env") (PList) PWild PWild PWild) (EVar "env"))
(DFunDef false "annotateImportedMethodRows" ((PVar "env") (PCons (PVar "name") (PVar "rest")) (PVar "nameable") (PVar "shadows") (PVar "rows")) (EBlock (DoLet false false (PVar "originName") (EApp (EApp (EVar "originMethodName") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name"))) (DoLet false false (PVar "env2") (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "omHasKey") (EVar "originName")) (EVar "nameable")) (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EVar "name")) (EVar "shadows")))) (EApp (EVar "isSome") (EApp (EApp (EVar "lookupBinding") (EVar "env")) (EVar "name")))) (EMatch (EApp (EApp (EApp (EVar "admittedRowFor") (EFieldAccess (EFieldAccess (EVar "env") "teDyn") "dcModule")) (EVar "name")) (EVar "rows")) (arm (PCon "Some" (PVar "row")) () (EApp (EApp (EApp (EVar "extendMethodRow") (EVar "env")) (EVar "name")) (EVar "row"))) (arm (PCon "None") () (EVar "env"))) (EVar "env"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "annotateImportedMethodRows") (EVar "env2")) (EVar "rest")) (EVar "nameable")) (EVar "shadows")) (EVar "rows")))))
(DTypeSig false "admittedRowFor" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Registry") (TyCon "MethodSchemeRow")) (TyApp (TyCon "Option") (TyCon "MethodSchemeRow"))))))
(DFunDef false "admittedRowFor" ((PVar "mctx") (PVar "n") (PVar "byId")) (EIf (EBinOp ">=" (EApp (EVar "listLen") (EApp (EApp (EVar "methodAdmittedHere") (EVar "mctx")) (EVar "n"))) (ELit (LInt 2))) (EVar "None") (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "methodEntryHere") (EVar "mctx")) (EVar "n"))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PTuple (PVar "iface") PWild PWild PWild) () (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "lookupMethodRowById") (EVar "iface")) (EApp (EApp (EVar "originMethodName") (EVar "mctx")) (EVar "n"))) (EVar "byId"))) (ELam ((PVar "row")) (EIf (EApp (EVar "methodRowCanCarry") (EVar "row")) (EApp (EVar "Some") (EVar "row")) (EVar "None"))))))))))
(DTypeSig false "admittedSchemeFor" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Registry") (TyCon "MethodSchemeRow")) (TyApp (TyCon "Option") (TyCon "Scheme"))))))
(DFunDef false "admittedSchemeFor" ((PVar "mctx") (PVar "n") (PVar "byId")) (EMatch (EApp (EApp (EVar "methodEntryHere") (EVar "mctx")) (EVar "n")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PTuple (PVar "iface") PWild PWild PWild)) () (EApp (EApp (EApp (EVar "lookupSchemeById") (EVar "iface")) (EApp (EApp (EVar "originMethodName") (EVar "mctx")) (EVar "n"))) (EVar "byId")))))
(DTypeSig true "schemeOblEntriesFor" (TyFun (TyCon "String") (TyFun (TyCon "UsePath") (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "VecObl")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "VecObl"))))))))
(DFunDef false "schemeOblEntriesFor" ((PVar "mid") (PCon "UseAlias" PWild (PVar "a")) (PVar "qual")) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "moduleAliasEntry") (EVar "mid")) (EVar "a"))) (EVar "qual")))
(DFunDef false "schemeOblEntriesFor" ((PVar "mid") (PCon "UseWild" PWild) (PVar "qual")) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "wildSchemeOblEntry") (EVar "mid"))) (EVar "qual")))
(DFunDef false "schemeOblEntriesFor" ((PVar "mid") (PCon "UseGroup" PWild (PVar "ms")) (PVar "qual")) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "memberSchemeOblEntry") (EVar "mid")) (EVar "qual"))) (EVar "ms")))
(DFunDef false "schemeOblEntriesFor" (PWild PWild PWild) (EListLit))
(DTypeSig false "wildSchemeOblEntry" (TyFun (TyCon "String") (TyFun (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "VecObl"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "VecObl")))))))
(DFunDef false "wildSchemeOblEntry" ((PVar "mid") (PTuple (PTuple (PVar "defMid") (PVar "n")) (PVar "obs"))) (EIf (EBinOp "==" (EVar "defMid") (EVar "mid")) (EListLit (ETuple (EVar "n") (EVar "obs"))) (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "memberSchemeOblEntry" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyCon "VecObl")))) (TyFun (TyCon "UseMember") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "VecObl"))))))))
(DFunDef false "memberSchemeOblEntry" ((PVar "mid") (PVar "qual") (PVar "m")) (EBlock (DoLet false false (PVar "local") (EApp (EVar "useMemberLocal") (EVar "m"))) (DoLet false false (PVar "origin") (EApp (EVar "useMemberOrigin") (EVar "m"))) (DoExpr (EApp (EApp (EMethodRef "map") (ELam ((PVar "e")) (ETuple (EVar "local") (EApp (EVar "snd") (EVar "e"))))) (EApp (EApp (EVar "filterList") (ELam ((PVar "e")) (EBinOp "&&" (EBinOp "==" (EApp (EVar "fst") (EApp (EVar "fst") (EVar "e"))) (EVar "mid")) (EBinOp "==" (EApp (EVar "snd") (EApp (EVar "fst") (EVar "e"))) (EVar "origin"))))) (EVar "qual"))))))
(DTypeSig true "aliasConstraintEntries" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyVar "a"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a")))))))
(DFunDef false "aliasConstraintEntries" ((PVar "_gctx") (PList) PWild) (EListLit))
(DFunDef false "aliasConstraintEntries" ((PVar "gctx") (PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest")) (PVar "qual")) (EBinOp "++" (EApp (EApp (EApp (EVar "aliasConstraintEntries") (EVar "gctx")) (EListLit (EVar "d"))) (EVar "qual")) (EApp (EApp (EApp (EVar "aliasConstraintEntries") (EVar "gctx")) (EVar "rest")) (EVar "qual"))))
(DFunDef false "aliasConstraintEntries" ((PVar "gctx") (PCons (PCon "DUse" PWild (PVar "path") PWild) (PVar "rest")) (PVar "qual")) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "aliasEntriesFor") (EVar "gctx")) (EApp (EVar "importTableMid") (EVar "path"))) (EVar "path")) (EVar "qual")) (EApp (EApp (EApp (EVar "aliasConstraintEntries") (EVar "gctx")) (EVar "rest")) (EVar "qual"))))
(DFunDef false "aliasConstraintEntries" ((PVar "gctx") (PCons PWild (PVar "rest")) (PVar "qual")) (EApp (EApp (EApp (EVar "aliasConstraintEntries") (EVar "gctx")) (EVar "rest")) (EVar "qual")))
(DTypeSig false "aliasEntriesFor" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyFun (TyCon "UsePath") (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyVar "a"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a"))))))))
(DFunDef false "aliasEntriesFor" ((PVar "gctx") (PVar "mid") (PCon "UseAlias" PWild (PVar "a")) (PVar "qual")) (EIf (EBinOp "==" (EVar "mid") (ELit (LString ""))) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "moduleAliasEntry") (EVar "mid")) (EVar "a"))) (EVar "qual")) (EIf (EVar "otherwise") (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "graphAliasEntry") (EVar "a")) (EVar "qual"))) (EApp (EApp (EVar "graphPubDefiners") (EVar "gctx")) (EVar "mid"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "aliasEntriesFor" ((PVar "_gctx") (PVar "mid") (PCon "UseGroup" PWild (PVar "ms")) (PVar "qual")) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "memberAliasEntry") (EVar "mid")) (EVar "qual"))) (EVar "ms")))
(DFunDef false "aliasEntriesFor" ((PVar "_gctx") PWild PWild PWild) (EListLit))
(DTypeSig true "aliasDictNames" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "aliasDictNames" ((PVar "gctx") (PVar "bare") (PVar "unitDecls") (PVar "modules")) (EBlock (DoLet false false (PVar "bareSet") (EApp (EApp (EVar "namesToSet") (EVar "bare")) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "u")) (EApp (EApp (EApp (EApp (EVar "aliasDictNamesOfUnit") (EVar "gctx")) (EVar "bareSet")) (EVar "unitDecls")) (EApp (EVar "snd") (EVar "u"))))) (EVar "modules")))))
(DTypeSig false "aliasDictNamesOfUnit" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "aliasDictNamesOfUnit" ((PVar "gctx") (PVar "bare") (PVar "unitDecls") (PVar "decls")) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EVar "aliasDictNamesOfDecl") (EVar "gctx")) (EVar "bare")) (EVar "unitDecls"))) (EVar "decls")))
(DTypeSig false "aliasDictNamesOfDecl" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "aliasDictNamesOfDecl" ((PVar "gctx") (PVar "bare") (PVar "unitDecls") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EApp (EApp (EVar "aliasDictNamesOfDecl") (EVar "gctx")) (EVar "bare")) (EVar "unitDecls")) (EVar "d")))
(DFunDef false "aliasDictNamesOfDecl" ((PVar "gctx") (PVar "bare") (PVar "unitDecls") (PCon "DUse" PWild (PVar "path") PWild)) (EApp (EApp (EApp (EApp (EApp (EVar "aliasDictNamesOfPath") (EVar "gctx")) (EVar "bare")) (EVar "unitDecls")) (EApp (EVar "useModId") (EVar "path"))) (EVar "path")))
(DFunDef false "aliasDictNamesOfDecl" ((PVar "_gctx") PWild PWild PWild) (EListLit))
(DTypeSig false "aliasDictNamesOfPath" (TyFun (TyCon "GraphCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyCon "String") (TyFun (TyCon "UsePath") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "aliasDictNamesOfPath" ((PVar "gctx") (PVar "bare") (PVar "unitDecls") (PVar "mid") (PCon "UseAlias" PWild (PVar "a"))) (EBlock (DoLet false false (PVar "own") (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "mid")) (EVar "unitDecls")) (arm (PCon "Some" (PVar "ds")) () (EApp (EApp (EMethodRef "filter") (ELam ((PVar "n")) (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "bare")))) (EApp (EVar "declTopFnNames") (EVar "ds")))) (arm (PCon "None") () (EListLit)))) (DoLet false false (PVar "reexported") (EApp (EApp (EMethodRef "map") (EVar "fst")) (EApp (EApp (EVar "filterList") (ELam ((PVar "r")) (EApp (EApp (EVar "omHasKey") (EApp (EVar "snd") (EApp (EVar "snd") (EVar "r")))) (EVar "bare")))) (EApp (EApp (EVar "graphPubDefiners") (EVar "gctx")) (EVar "mid"))))) (DoExpr (EApp (EApp (EMethodRef "map") (EApp (EVar "qualifiedLocal") (EVar "a"))) (EApp (EVar "dedup") (EBinOp "++" (EVar "own") (EVar "reexported")))))))
(DFunDef false "aliasDictNamesOfPath" ((PVar "_gctx") (PVar "bare") PWild PWild (PCon "UseGroup" PWild (PVar "ms"))) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "memberDictName") (EVar "bare"))) (EVar "ms")))
(DFunDef false "aliasDictNamesOfPath" ((PVar "_gctx") PWild PWild PWild PWild) (EListLit))
(DTypeSig false "memberDictName" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "UseMember") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "memberDictName" ((PVar "bare") (PVar "m")) (EMatch (EApp (EVar "useMemberAlias") (EVar "m")) (arm (PCon "Some" (PVar "local")) () (EIf (EApp (EApp (EVar "omHasKey") (EApp (EVar "useMemberOrigin") (EVar "m"))) (EVar "bare")) (EListLit (EVar "local")) (EListLit))) (arm (PCon "None") () (EListLit))))
(DTypeSig false "moduleAliasEntry" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyVar "a")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a")))))))
(DFunDef false "moduleAliasEntry" ((PVar "mid") (PVar "a") (PTuple (PTuple (PVar "defMid") (PVar "n")) (PVar "ids"))) (EIf (EBinOp "==" (EVar "defMid") (EVar "mid")) (EListLit (ETuple (EApp (EApp (EVar "qualifiedLocal") (EVar "a")) (EVar "n")) (EVar "ids"))) (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "memberAliasEntry" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyVar "a"))) (TyFun (TyCon "UseMember") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a")))))))
(DFunDef false "memberAliasEntry" ((PVar "mid") (PVar "qual") (PVar "m")) (EMatch (EApp (EVar "useMemberAlias") (EVar "m")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "local")) () (EBlock (DoLet false false (PVar "origin") (EApp (EVar "useMemberOrigin") (EVar "m"))) (DoExpr (EApp (EApp (EMethodRef "map") (ELam ((PVar "e")) (ETuple (EVar "local") (EApp (EVar "snd") (EVar "e"))))) (EApp (EApp (EMethodRef "filter") (ELam ((PVar "e")) (EBinOp "&&" (EBinOp "==" (EApp (EVar "fst") (EApp (EVar "fst") (EVar "e"))) (EVar "mid")) (EBinOp "==" (EApp (EVar "snd") (EApp (EVar "fst") (EVar "e"))) (EVar "origin"))))) (EVar "qual"))))))))
(DTypeSig false "graphAliasEntry" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyTuple (TyCon "String") (TyCon "String")) (TyVar "a"))) (TyFun (TyTuple (TyCon "String") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a")))))))
(DFunDef false "graphAliasEntry" ((PVar "a") (PVar "qual") (PTuple (PVar "localName") (PTuple (PVar "defMid") (PVar "origin")))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "e")) (ETuple (EApp (EApp (EVar "qualifiedLocal") (EVar "a")) (EVar "localName")) (EApp (EVar "snd") (EVar "e"))))) (EApp (EApp (EVar "filterList") (ELam ((PVar "e")) (EBinOp "&&" (EBinOp "==" (EApp (EVar "fst") (EApp (EVar "fst") (EVar "e"))) (EVar "defMid")) (EBinOp "==" (EApp (EVar "snd") (EApp (EVar "fst") (EVar "e"))) (EVar "origin"))))) (EVar "qual"))))
(DTypeSig true "reportAmbiguousImportsIn" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Unit")))))
(DFunDef false "reportAmbiguousImportsIn" ((PVar "_mctx") PWild (PList)) (ELit LUnit))
(DFunDef false "reportAmbiguousImportsIn" ((PVar "mctx") (PVar "occ") (PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EBlock (DoExpr (EApp (EApp (EApp (EVar "reportAmbiguousImportsIn") (EVar "mctx")) (EVar "occ")) (EListLit (EVar "d")))) (DoExpr (EApp (EApp (EApp (EVar "reportAmbiguousImportsIn") (EVar "mctx")) (EVar "occ")) (EVar "rest")))))
(DFunDef false "reportAmbiguousImportsIn" ((PVar "mctx") (PVar "occ") (PCons (PCon "DUse" PWild (PVar "path") (PVar "loc")) (PVar "rest"))) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "reportAmbiguousImport") (EVar "mctx")) (EVar "occ")) (EApp (EVar "useModId") (EVar "path"))) (EVar "path")) (EVar "loc"))) (DoExpr (EApp (EApp (EApp (EVar "reportAmbiguousImportsIn") (EVar "mctx")) (EVar "occ")) (EVar "rest")))))
(DFunDef false "reportAmbiguousImportsIn" ((PVar "mctx") (PVar "occ") (PCons PWild (PVar "rest"))) (EApp (EApp (EApp (EVar "reportAmbiguousImportsIn") (EVar "mctx")) (EVar "occ")) (EVar "rest")))
(DTypeSig false "reportAmbiguousImport" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "String") (TyFun (TyCon "UsePath") (TyFun (TyCon "Loc") (TyCon "Unit")))))))
(DFunDef false "reportAmbiguousImport" ((PVar "mctx") (PVar "occ") (PVar "depId") (PVar "path") (PVar "loc")) (EMatch (EApp (EApp (EVar "graphAmbigValues") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "depId")) (arm (PList) () (ELit LUnit)) (arm (PVar "amb") () (EApp (EApp (EApp (EApp (EVar "pushAmbiguousImports") (EVar "mctx")) (EVar "depId")) (EVar "loc")) (EApp (EApp (EApp (EVar "ambiguousAdmitted") (EVar "occ")) (EVar "path")) (EVar "amb"))))))
(DTypeSig false "ambiguousAdmitted" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "UsePath") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "ambiguousAdmitted" ((PVar "occ") (PCon "UseAlias" PWild (PVar "a")) (PVar "amb")) (EApp (EApp (EVar "filterList") (ELam ((PVar "r")) (EApp (EApp (EVar "omHasKey") (EApp (EApp (EVar "qualifiedLocal") (EVar "a")) (EApp (EVar "fst") (EVar "r")))) (EVar "occ")))) (EVar "amb")))
(DFunDef false "ambiguousAdmitted" ((PVar "occ") (PVar "path") (PVar "amb")) (EMatch (EApp (EVar "importedBindings") (EVar "path")) (arm (PCon "None") () (EApp (EApp (EVar "filterList") (ELam ((PVar "r")) (EApp (EApp (EVar "omHasKey") (EApp (EVar "fst") (EVar "r"))) (EVar "occ")))) (EVar "amb"))) (arm (PCon "Some" (PVar "bindings")) () (EApp (EApp (EVar "filterList") (ELam ((PVar "r")) (EApp (EApp (EVar "anyList") (ELam ((PVar "b")) (EBinOp "==" (EApp (EVar "fst") (EVar "b")) (EApp (EVar "fst") (EVar "r"))))) (EVar "bindings")))) (EVar "amb")))))
(DTypeSig false "pushAmbiguousImports" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "Loc") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyCon "Unit"))))))
(DFunDef false "pushAmbiguousImports" ((PVar "_mctx") PWild PWild (PList)) (ELit LUnit))
(DFunDef false "pushAmbiguousImports" ((PVar "mctx") (PVar "depId") (PVar "loc") (PCons (PTuple (PVar "n") (PVar "mids")) (PVar "rest"))) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "pushTypeErrorHelpFixAt") (EVar "mctx")) (EVar "TAmbiguousReexport")) (EApp (EVar "Some") (EVar "loc"))) (EApp (EApp (EApp (EVar "ambigReexportMsg") (EVar "n")) (EVar "depId")) (EVar "mids"))) (EApp (EApp (EApp (EVar "ambigReexportHelp") (EVar "n")) (EVar "depId")) (EVar "mids"))) (EVar "None"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "pushAmbiguousImports") (EVar "mctx")) (EVar "depId")) (EVar "loc")) (EVar "rest")))))
(DTypeSig true "declCtorNamed" (TyFun (TyCon "String") (TyFun (TyCon "Decl") (TyCon "Bool"))))
(DFunDef false "declCtorNamed" ((PVar "n") (PRec "DData" ((rf "dataCtors" (PVar "vs"))) false)) (EApp (EApp (EVar "variantNamed") (EVar "n")) (EVar "vs")))
(DFunDef false "declCtorNamed" ((PVar "n") (PRec "DNewtype" ((rf "newtypeCtor" (PVar "cn"))) false)) (EBinOp "==" (EVar "cn") (EVar "n")))
(DFunDef false "declCtorNamed" (PWild PWild) (EVar "False"))
(DTypeSig true "withAliasMethodNames" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit")))))
(DFunDef false "withAliasMethodNames" ((PVar "rows") (PVar "set")) (EApp (EApp (EVar "omFromNames") (EApp (EApp (EMethodRef "map") (EVar "fst")) (EApp (EApp (EVar "filterList") (ELam ((PVar "r")) (EApp (EApp (EVar "omHasKey") (EApp (EVar "snd") (EVar "r"))) (EVar "set")))) (EVar "rows")))) (EVar "set")))
(DTypeSig true "importedIfaceRows" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "importedIfaceRows" (PWild (PList)) (EListLit))
(DFunDef false "importedIfaceRows" ((PVar "idx") (PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "importedIfaceRows") (EVar "idx")) (EListLit (EVar "d"))) (EApp (EApp (EVar "importedIfaceRows") (EVar "idx")) (EVar "rest"))))
(DFunDef false "importedIfaceRows" ((PVar "idx") (PCons (PCon "DUse" PWild (PVar "path") PWild) (PVar "rest"))) (EBinOp "++" (EMatch (EApp (EApp (EVar "omLookup") (EApp (EVar "useModId") (EVar "path"))) (EVar "idx")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "src")) () (EApp (EApp (EVar "selectIfaceRows") (EVar "path")) (EVar "src")))) (EApp (EApp (EVar "importedIfaceRows") (EVar "idx")) (EVar "rest"))))
(DFunDef false "importedIfaceRows" ((PVar "idx") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "importedIfaceRows") (EVar "idx")) (EVar "rest")))
