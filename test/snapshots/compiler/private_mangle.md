# META
source_lines=2039
stages=DESUGAR,MARK
# SOURCE
import frontend.runtime_constructors.{namedRuntimeCtor}
import support.symbol_encoding.{encodePair}
import types.symbol_origins.{
  SymbolOrigins, emptyOrigins, unitOrigins, mergeOrigins
}
-- UNIVERSAL PER-MODULE NAME MANGLING for the flat multi-module EMIT path.
--
-- The gap-tolerant / multi-module emit drivers FLATTEN every module's decls into
-- one program and name each top-level function by its BARE name (`@mdk_<name>`).
-- Two modules that define a same-named top-level function therefore COLLIDE: only
-- one `@mdk_<name>` survives, and references in BOTH modules route to the surviving
-- one → wrong dispatch / SIGSEGV.  This bit (a) the native lexer's `lex_main.emit`
-- vs `lexer.emit` (private/private) and (b) the native CLI's `repl.isIdentChar :
-- String -> Bool` vs `lsp.isIdentChar : Char -> Bool` (private/private, different
-- arity-compatible types) — and equally bites any EXPORTED pair that happens to
-- share a name.
--
-- FIX — universal mangling: EVERY top-level FUNCTION binding (in core + every
-- module) is renamed to a module-qualified unique symbol `<mid>__<name>`, and
-- EVERY reference is rewritten IMPORT-AWARE to its resolved origin module's
-- mangled name.  Collisions are then avoided FOR MODULE IDS THAT DON'T COLLIDE
-- under `sanitizeId`'s mapping — NOT impossible by construction: `sanitizeId`
-- maps every non-`[A-Za-z0-9_]` char (including the loader's own `.` module-id
-- separator) to `_`, so a flat module `lib_plain.mdk` (id `lib_plain`) and a
-- nested module `lib/plain.mdk` (id `lib.plain`) sanitize to the identical
-- string and produce the identical `@mdk_<sym>` symbol for a same-named export
-- — a real, measured collision, not a hypothetical one. See #1677 (open).
--
-- IMPORT-AWARE RESOLUTION is the crux.  For a (non-shadowed) reference to bare
-- name `n` in unit `mid` we must know WHICH module's definition it binds:
--   1. `n` defined locally in `mid`              → `<mid>__<n>`   (local shadows imports)
--   2. else `n` brought in by a `DUse` of module `M` (UseGroup member / UseWild /
--      UseName stub / UseAlias)                  → `<M>__<n>`
--   3. else `n` defined in core (implicit prelude, imported by every unit) → `core__<n>`
--   4. else (extern C symbol, constructor, interface/impl method, unknown free
--      name) → LEFT UNCHANGED.
-- The per-unit import structure comes straight from the unit's `DUse` decls + each
-- module's export surface, which `frontend.visibility.buildExportsWith` builds from
-- the `(mid, decls)` units (`unitSurfaces`, which says how its value set differs
-- from resolve's).  A per-unit LOCAL-name → origin-module map is sufficient.
--
-- IMPORT ALIASING does not perturb any of this, because it only changes what the
-- LOCAL name is, never the shape of the map:
--   `import M.{a as b}`  → local `b`      ↦ `<M>__a`   (origin ≠ local)
--   `import M as A`      → local `A.<n>`  ↦ `<M>__<n>`, for every export `n` of M
-- The `A.<n>` local is the flat name `frontend/desugar.mdk` produces for the qualified
-- reference `A.n` (a dot cannot occur in a surface identifier, so it is collision-free).
-- Mapping it here is exactly what ERASES the alias from the emitted code — no dotted
-- name ever reaches the output.  Note the two-sided consequence: the symbol is always
-- rebuilt from the ORIGIN (`mangledName definer origin`), never from the local, which is
-- why a RE-EXPORTED alias is rejected in the parser — a module's export table maps
-- (name → definer) and could not express "the export `b` is really `a`".
--
-- EXCLUDED (never mangled):
--   • the ENTRY unit's `main` — the emitter emits it as `@main`, the program entry
--     point (llvm_emit.mdk `isFnBind (CBind "main" _ _) = False`); renaming it would
--     lose the entry.  Only the entry unit (the LAST unit: the loader hands modules
--     dependency-first) keeps the key `main` unrenamed (`isEntryMainKey`).  Any other
--     unit's `main` is an ordinary top-level name and mangles to `<mid>__main`, so it
--     cannot merge with the entry's into one two-clause bind.
--   • externs / runtime C symbols (`@mdk_<externName>` → runtime/medaka_rt.c) —
--     they are declared in runtime.mdk (NOT in core/modules), so they never appear
--     as a definition here; a reference to one is excluded by rule 4 (not in any
--     unit's defined-fn set nor import scope).  A module's OWN extern keeps its
--     spelling too unless it has `bind` clauses (`externSymbolName`).
--   • interface/impl method names, dict names — they have their own naming in the
--     emitter (impl keys), and are not DFunDef/DData binders this pass touches.
--   • RESERVED constructors (Cons/Nil/Some/None/Ok/Err/Lt/Eq/Gt/True/False) — the
--     emitter gives these fixed reserved tags (llvm_emit.mdk `reservedTag`); mangling
--     would lose the tag.  Excluded at the ctor-export step (`isReservedCtor`).
--
-- CONSTRUCTOR MANGLING (the cross-module ctor-name-collision fix).  The flat emit
-- path also folds EVERY module's `DData`/`DNewtype` ctors into ONE global
-- bare-name-keyed ctor table (arity / tag / type-id / ordinal in llvm_emit.mdk).
-- Two ADTs in different modules declaring a same-named ctor with DIFFERENT arity
-- therefore COLLAPSE into one entry — a nullary ctor inheriting a payload ctor's
-- arity is emitted as a boxed cell instead of an immediate → corrupted value →
-- SIGSEGV (the interpreter is immune: it is structural, no arity table).  Fix: the
-- SAME universal per-module mangling, extended to constructors — every NON-reserved
-- ctor is renamed `<owningMid>__<ctor>` at its DEFINITION (DData variant /
-- DNewtype con) AND at every USE site (EVar construct, PCon / PRec match,
-- ERecordCreate, EVariantUpdate), import-aware (a `import M.{T(..)}` maps T's ctors
-- to `<M>__<ctor>`).  Collisions are then avoided FOR MODULE IDS THAT DON'T COLLIDE
-- under `sanitizeId`'s mapping — NOT impossible by construction; this reuses the same
-- `mangledName`/`sanitizeId` as the function path above, so it is presumed equally
-- exposed to the same non-injective-id collision (presumed, not independently
-- reproduced — see #1677, routed to #1319 as owed follow-up). Where ids don't collide,
-- the per-site owning module comes from the importing unit's scope, so construct and
-- match always agree.  The gates diff OUTPUT, so a consistent ctor rename is invisible.
--
-- This runs PER UNIT, AFTER elaborateModules and over the trees it produced (#2809):
-- elaboration reads the import structure the mangler does not rewrite (a `DUse` member
-- keeps its bare spelling) and groups two denotations of one name by that name, so a
-- mangled graph made every import-keyed table miss and erased ambiguities the checker
-- exists to report.  `mangleUnitsEv` is the entry every emit driver takes; `mangleUnits`
-- is the plain-tree entry that remains for a driver whose output is discarded.  It lives
-- ONLY in the emit drivers (never the oracle/golden drivers), so every golden/oracle dump
-- is unchanged.  The gates diff program OUTPUT, so a consistent rename is invisible to
-- them — but a reference rewritten to the WRONG origin module's symbol changes output and
-- is caught.
--
-- The reference rewrite is SCOPE-AWARE: a reference to top-level `f` is renamed
-- only where `f` is the FREE top-level name, NOT where a local binder (parameter /
-- let / lambda arg / match-pattern var) named `f` shadows it.  Mirrors the
-- binder-threading of typecheck.mdk's `rewriteArgScoped`.

import types.extern_source.{sourceExternSymbol, externDisplayName}
import frontend.ast.{
  letBindName,
  declBinderNames,
  Decl(..),
  ExternDecl(..),
  Expr(..),
  Pat(..),
  Arm(..),
  Guard(..),
  GuardArm(..),
  DoStmt(..),
  Section(..),
  InterpPart(..),
  FieldAssign(..),
  RecPatField(..),
  LetBind(..),
  FunClause(..),
  IfaceMethod(..),
  MethodDefault(..),
  ImplMethod(..),
  PropParam(..),
  UsePath(..),
  UseMember(..),
  useMemberOrigin,
  useMemberLocal,
  useMemberAlias,
  qualifiedLocal,
  Variant(..),
  DataVis(..),
  Route(..),
  EvVal(..),
  EvEntry(..),
  EvId(..),
  EvTable,
}
import frontend.ast.{SiblingPair(..)}
import frontend.visibility.{
  ModuleExports(..),
  useModId,
  coreExports,
  buildExportsWith,
  pubIfaceMethodSets,
  ExportView(..),
  viewOf,
  fullExportsOf,
  directUnder,
  filterInSet,
  nsValues,
  valueDeclsOf,
  valueDeclOf,
  typeOfCtor,
}
import u64 as U64
import list.{last, zip}
import map.{insertWith}
import support.util.{
  lookupAssoc,
  contains,
  reverseL,
  isEmptyL,
  filterList,
  dedup,
  dedupBy,
  lenKey,
}
-- The per-unit rename map is applied to EVERY reference in the unit (one lookup
-- per EVar / def-name / pattern ctor). Backing it with the String-keyed
-- weight-balanced tree (support.ordmap) makes each lookup O(log n) instead of an
-- O(map) linear `lookupAssoc` scan — and it is built ONCE per unit, by `mangleUnitU`
-- on the plain entry and by `unitRenameMapEntry` on the elaborated one, whose two
-- readers (the decl rename and the evidence remap) share the one map.
import support.ordmap.{
  OrdMap,
  omInsert,
  omLookup,
  omKeys,
  omFromPairs,
  omFromNames,
  omHasKey,
  omEmpty,
  omSize,
}

-- ── entry point ───────────────────────────────────────────────────────────────
-- Given the core unit and every (mid, decls) module, module-qualify EVERY
-- top-level function (except the entry unit's `main`), rewriting all references
-- import-aware to their origin module's mangled name.  Returns the rewritten
-- (coreDecls, modules) in the same shape `runEmit` already threads to
-- elaborateModules.
export
mangleUnits : List Decl ->
  List (String, List Decl) ->
  (List Decl, List (String, List Decl))
mangleUnits coreDecls modules =
  let (coreOut, modsOut, _) = mangleUnitsWithOrigins coreDecls modules
  (coreOut, modsOut)

-- The same rename for the target check's reach (`ir.dce.reachedExternChains`),
-- which must tell which declaration each reference denotes.  Every extern takes
-- its module-scoped name, with `bind` clauses or without, so a reference
-- reaches exactly the declaration it resolves to, and a local binder, which
-- the rename leaves alone, reaches none.  No injectivity guard: two module ids
-- that sanitize alike merge their names, which only widens the reach.
-- `builtins` names the module of declarations every unit sees without an
-- import, as it sees the prelude's, and that the prelude's own bindings shadow.
export
scopeUnitNames : Option (String, List Decl) ->
  List Decl ->
  List (String, List Decl) ->
  (List Decl, List (String, List Decl))
scopeUnitNames None coreDecls modules =
  renameUnits scopedExternName [] coreDecls modules
scopeUnitNames (Some (mid, decls)) coreDecls modules =
  renameUnits
    scopedExternName
    (map (n => (n, mid)) (externDeclNames decls))
    coreDecls
    ((mid, decls) :: modules)

scopedExternName : String -> ExternDecl -> String
scopedExternName mid ed = mangledName mid ed.edName

externDeclNames : List Decl -> List String
externDeclNames decls = map fst (externDeclEntries (ed => ed.edName) decls)

-- `externName` names an extern program-wide from its module and declaration.
-- `implicit` is in scope in every unit after the prelude, each name with the
-- module that defines it.
renameUnits : (String -> ExternDecl -> String) ->
  List (String, String) ->
  List Decl ->
  List (String, List Decl) ->
  (List Decl, List (String, List Decl))
renameUnits externName implicit coreDecls modules =
  let allUnits = ("core", coreDecls) :: modules
  let entryMid = entryUnitMid allUnits
  let surfaces = unitSurfaces allUnits
  let exportsPerUnit =
    withPreludeDefs
      (dedup (unitDefNames ("", coreDecls)))
      implicit
      (fnExportsFrom (_ => ExportedView) allUnits surfaces)
  let ctorExportsPerUnit = ctorExportsFrom surfaces
  let externExports = externExportsFrom externName allUnits surfaces
  let coreOut = mangleUnitU
    entryMid
    exportsPerUnit
    ctorExportsPerUnit
    externName
    externExports
    ("core", coreDecls)
  let modsOut =
    map
      (mangleModule
        entryMid
        exportsPerUnit
        ctorExportsPerUnit
        externName
        externExports)
      modules
  (coreOut, modsOut)

-- The entry unit is the LAST one: the loader hands modules dependency-first (the
-- invariant `driver/main_autoprint.entryPair` also reads), and a single-file
-- program is the sole module after core.
entryUnitMid : List (String, List Decl) -> String
entryUnitMid units = match last units
  Some (mid, _) => mid
  None => ""

-- ── the ELABORATED-graph entry point (#2809) ──────────────────────────────────
-- What every EMIT driver calls.  The same rename as `mangleUnits`, extended to the one
-- place an ELABORATED tree carries a top-level symbol its expression spine does not: the
-- evidence table's `RLocal` route.  `core_ir_lower.lower (EMethodAt name _ ev)` reads the
-- route, not the node's seed, so the emitters' direct call to a shadowing standalone
-- (`llvm_emit.emitMethod`'s and `wasm_emit.emitMethodRef`'s `RLocal` arms, and
-- `wasm_reach.refsRoute`'s reachability) is named THERE and nowhere else.  An entry's
-- `EvId` names the module it was minted in, which is the unit whose rename map resolves
-- its symbols.  [table] is the elaboration's whole evidence table; it is returned
-- renamed.
export
mangleUnitsEv : EvTable ->
  List Decl ->
  List (String, List Decl) ->
  (List Decl, List (String, List Decl), EvTable, SymbolOrigins)
mangleUnitsEv = mangleUnitsEvFor []

-- `mangleUnitsEv` for a graph whose test sibling pairs are [siblings]: each sibling's unit reads its subject's full view, every other
-- unit the exported ones.
export
mangleUnitsEvFor : List SiblingPair ->
  EvTable ->
  List Decl ->
  List (String, List Decl) ->
  (List Decl, List (String, List Decl), EvTable, SymbolOrigins)
mangleUnitsEvFor siblings table coreDecls modules =
  let allUnits = ("core", coreDecls) :: modules
  let entryMid = entryUnitMid allUnits
  let surfaces = unitSurfaces allUnits
  let exportsPerUnit =
    exportsPerUnitOf (_ => ExportedView) coreDecls allUnits surfaces
  let ctorExportsPerUnit = ctorExportsFrom surfaces
  let externExports = externExportsFrom externSymbolName allUnits surfaces
  let siblingMaps = map (siblingUnitMaps coreDecls allUnits surfaces) siblings
  -- ONE map per unit, threaded to both readers: the decl rename and the evidence
  -- remap name the same symbols, and building the map twice was measured at +0.99%
  -- Ir on the emitter child over the compiler's own graph.
  let units =
    map
      (unitEntryFor entryMid siblingMaps (
        exportsPerUnit,
        ctorExportsPerUnit,
        externExports,
      ))
      allUnits
  let renamed = map renameUnitEntry units
  let coreOut = match renamed
    [] => coreDecls
    (_, ds) :: _ => ds
  let modsOut = match renamed
    [] => modules
    _ :: rest => rest
  let remap =
    mangleEvEntry (omFromPairs (reverseL (map dropUnitDecls units)) omEmpty)
  let origins =
    fold
      (acc (mid, (rm, _, decls)) => mergeOrigins acc (unitOrigins mid rm decls))
      emptyOrigins
      units
  (coreOut, modsOut, map remap table, origins)

export
mangleUnitsWithOrigins : List Decl ->
  List (String, List Decl) ->
  (List Decl, List (String, List Decl), SymbolOrigins)
mangleUnitsWithOrigins coreDecls modules =
  let (coreOut, modsOut, _, origins) = mangleUnitsEv [] coreDecls modules
  (coreOut, modsOut, origins)

-- The three export maps, in the order `unitRenameMapEntry` takes them.
type ExportMaps = (List (String, List (String, String)), List (String, List (String, String, List String)), OrdMap (OrdMap String))

-- Each unit's exported function symbols, the prelude's definitions ahead of them.
exportsPerUnitOf : (String -> ExportView) ->
  List Decl ->
  List (String, List Decl) ->
  List (String, ModuleExports) ->
  List (String, List (String, String))
exportsPerUnitOf viewOfUnit coreDecls allUnits surfaces =
  withPreludeDefs
    (dedup (unitDefNames ("", coreDecls)))
    []
    (fnExportsFrom viewOfUnit allUnits surfaces)

-- The export maps the unit of sibling [sib] imports against, with its subject's
-- surface replaced by the full view.
siblingUnitMaps : List Decl ->
  List (String, List Decl) ->
  List (String, ModuleExports) ->
  SiblingPair ->
  (String, ExportMaps)
siblingUnitMaps coreDecls allUnits surfaces pair =
  let subj = pair.spSubject
  let full = fullSurfaces subj allUnits surfaces
  (
    pair.spSibling,
    (
      exportsPerUnitOf (viewOf (Some subj)) coreDecls allUnits full,
      ctorExportsFrom full,
      externExportsFrom externSymbolName allUnits full,
    ),
  )

-- [surfaces] with module [subj]'s entry rebuilt as its full view.  The rest
-- keep their exported surfaces, so no other unit's `export import` of the
-- subject carries a private name.
fullSurfaces : String ->
  List (String, List Decl) ->
  List (String, ModuleExports) ->
  List (String, ModuleExports)
fullSurfaces subj allUnits surfaces =
  let coreExp = coreExportsOf allUnits
  let known = omFromPairs (reverseL surfaces) omEmpty
  map (fullSurfaceOf subj coreExp known allUnits) surfaces

fullSurfaceOf : String ->
  ModuleExports ->
  OrdMap ModuleExports ->
  List (String, List Decl) ->
  (String, ModuleExports) ->
  (String, ModuleExports)
fullSurfaceOf subj coreExp known allUnits (mid, exp) =
  if mid == subj then
    (
      mid,
      optionOr
        exp
        (map
          (decls => fullExportsOf coreExp known mid decls)
          (lookupAssoc mid allUnits)),
    )
  else
    (mid, exp)

-- Unit [mid]'s rename map, built from its own sibling maps in [siblingMaps] when
-- it is a test sibling and from the exported maps otherwise.
unitEntryFor : String ->
  List (String, ExportMaps) ->
  ExportMaps ->
  (String, List Decl) ->
  (String, (OrdMap String, Bool, List Decl))
unitEntryFor entryMid siblingMaps exported (mid, decls) =
  let (fns, ctors, externs) = optionOr exported (lookupAssoc mid siblingMaps)
  unitRenameMapEntry entryMid fns ctors externs (mid, decls)

-- one unit's rename map, keyed by its module id, beside the decls it applies to.  The
-- SAME two builders and the same first-entry-wins fold `mangleUnitU` applies, so a
-- route and the definition it names cannot be renamed differently.
unitRenameMapEntry : String ->
  List (String, List (String, String)) ->
  List (String, List (String, String, List String)) ->
  OrdMap (OrdMap String) ->
  (String, List Decl) ->
  (String, (OrdMap String, Bool, List Decl))
unitRenameMapEntry entryMid exportsPerUnit ctorExportsPerUnit externExports (mid, decls) =
  let rmList =
    buildUnitRenameMap
        entryMid
        mid
        exportsPerUnit
        externSymbolName
        externExports
        decls
      ++ buildUnitCtorRenameMap mid ctorExportsPerUnit decls
  (mid, (omFromPairs (reverseL rmList) omEmpty, isEmptyL rmList, decls))

-- apply an already-built map, exactly as `mangleUnitU`'s tail does.
renameUnitEntry : (String, (OrdMap String, Bool, List Decl)) ->
  (String, List Decl)
renameUnitEntry (mid, (rm, noEntries, decls)) =
  (mid, if noEntries then decls else map (renameDecl rm) decls)

dropUnitDecls : (String, (OrdMap String, Bool, List Decl)) ->
  (String, OrdMap String)
dropUnitDecls (mid, (rm, _, _)) = (mid, rm)

-- An entry stamped by a module this graph does not carry keeps its routes: there is no
-- map that could resolve its symbols, and guessing one would rename against the wrong
-- unit's import scope.  Keyed by an `OrdMap`, not scanned: this runs once per evidence
-- SLOT and the unit list is as long as the module graph.  `omFromPairs` is
-- last-write-wins where the `lookupAssoc` it replaces was first-match, so the caller
-- reverses; two units cannot share a mid anyway, so the winner is the same either way.
mangleEvEntry : OrdMap (OrdMap String) -> EvEntry -> EvEntry
mangleEvEntry maps (EvEntry (EvId m i) v) = match omLookup m maps
  None => EvEntry (EvId m i) v
  Some rm => EvEntry (EvId m i) (mangleEvVal rm v)

mangleEvVal : OrdMap String -> EvVal -> EvVal
mangleEvVal rm (EvOne r) = EvOne (mangleRoute rm r)
mangleEvVal rm (EvMany rs) = EvMany (map (mangleRoute rm) rs)
mangleEvVal rm (EvMethod iface arity r reqs mds) =
  EvMethod
    iface
    arity
    (mangleRoute rm r)
    (map (mangleRoute rm) reqs)
    (map (mangleRoute rm) mds)
mangleEvVal rm (EvLit f r) = EvLit f (mangleRoute rm r)
-- A record head is owner-qualified where it is stamped and never renamed.
mangleEvVal _ (EvHead h) = EvHead h

-- Only `RLocal`'s symbol is a top-level function name.  `RKey` carries an impl head TYPE
-- tag or a canonical impl key (types are not mangled), `RDict`/`RDictFwd` a dict PARAMETER
-- name `dictPass` minted locally, `RScalar` a scalar witness word.  `RLocal`'s own `""`
-- (the bare-name sentinel) is in no rename map, so it passes through unchanged.
mangleRoute : OrdMap String -> Route -> Route
mangleRoute rm (RLocal sym ds) =
  RLocal (renameDefName rm sym) (map (mangleRoute rm) ds)
mangleRoute rm (RKey k ds sups) =
  RKey k (map (mangleRoute rm) ds) (map (mangleRoute rm) sups)
mangleRoute rm (RProj r path) = RProj (mangleRoute rm r) path
mangleRoute _ (r@RNone) = r
mangleRoute _ (r@(RDict _)) = r
mangleRoute _ (r@(RDictFwd _)) = r
mangleRoute _ (r@(RScalar _)) = r

-- ── ctor-collision-only mangling for the UNTYPED eval drivers (#1292) ─────────
-- `eval.runtimeTypeTag` tags a `VCon` by looking its BARE constructor name up in
-- the program-global `ctorToTypeRef` table, so two modules declaring a same-named
-- constructor collapse to ONE entry and every value of the loser's type is tagged
-- with the winner's TYPE — silently dispatching to the wrong impl (#1292, S0).
-- The emit path fixed this bug class in 2026-06-13 with `mangleUnits` above; this
-- is the same rename, narrowed to what an INTERPRETER can afford:
--
--   * CONSTRUCTORS ONLY.  Renaming top-level functions is unnecessary here (eval
--     resolves them through per-module frames, not a flat symbol table) and would
--     put the whole function namespace at risk for no gain.
--   * ONLY NAMES THAT ACTUALLY COLLIDE across units.  `mangleUnits` renames
--     unconditionally, which is invisible on the emit path because the gates diff
--     program OUTPUT — an argument that does NOT transfer to eval, where
--     `ppValue (VCon name …)` prints the constructor name AS the output.  With the
--     rename restricted to colliding names, a program with no cross-unit
--     constructor collision (i.e. every program the corpus contains today) is
--     returned BYTE-IDENTICAL, by construction.
--   * `Pass`/`Fail` are EXEMPT (`evalMangleExemptCtor`).  See its comment.
--
-- Idempotent: after one pass the surviving names are `<mid>__<Ctor>`, distinct per
-- unit, so a second pass finds no collision and returns its input unchanged.  That
-- is what lets the drivers apply it defensively while `tools/test_cmd.mdk` applies
-- it EARLIER (it must: the `test`/prop phases pull their bodies out of the same
-- elaborated module list they hand the driver, so the bodies have to be renamed by
-- the same pass, not merely evaluated in a renamed env).
--
-- Not a total fix for #1292.  One residual stays live, recorded rather than
-- silently inherited: a program that collides on the spellings `Pass`/`Fail` (the
-- exemption).
--
-- The alias-qualified constructor reference (`import m as A` … `A.Ctor`) that used
-- to be the second residual is gone (#1287): resolve now shortens such a reference
-- to the bare ctor name before any tree reaches this pass, so `UseAlias` binds
-- exactly what `UseWild` binds and the arms are written that way.
--
-- [siblings] are the graph's (test sibling, subject) pairs: a sibling's unit binds
-- its subject's constructors through the full view, as `mangleUnitsEvFor` does.
export
mangleCtorCollisions : List SiblingPair ->
  List Decl ->
  List (String, List Decl) ->
  (List Decl, List (String, List Decl))
mangleCtorCollisions siblings coreDecls modules =
  let allUnits = ("core", coreDecls) :: modules
  let collided = collidingCtorNames allUnits
  if omSize collided == 0 then
    (coreDecls, modules)
  else
    let surfaces = unitSurfaces allUnits
    let ctorExportsPerUnit = ctorExportsFrom surfaces
    let siblingCtors =
      map
        (p => (
          p.spSibling,
          ctorExportsFrom (fullSurfaces p.spSubject allUnits surfaces),
        ))
        siblings
    let coreOut =
      mangleCtorUnitU collided ctorExportsPerUnit ("core", coreDecls)
    let modsOut =
      map
        (m =>
          mangleCtorModule
            collided
            (optionOr ctorExportsPerUnit (lookupAssoc (fst m) siblingCtors))
            m)
        modules
    (coreOut, modsOut)

-- pair-shaped convenience wrapper: `elaborateModules` returns exactly this pair,
-- and every caller that needs the renamed decls back (not just a renamed env)
-- wraps its result.
export
mangleCtorCollisionsPair : List SiblingPair ->
  (List Decl, List (String, List Decl)) ->
  (List Decl, List (String, List Decl))
mangleCtorCollisionsPair siblings (coreDecls, modules) =
  mangleCtorCollisions siblings coreDecls modules

-- the constructor names DECLARED by two or more distinct units, as a set.
-- Per-unit `dedup` first, so one unit declaring a name twice (which is a resolve
-- error, not a cross-module collision) never enters the set on its own.
collidingCtorNames : List (String, List Decl) -> OrdMap Unit
collidingCtorNames units =
  collidedGo (flatMap unitMangleCtorNames units) omEmpty omEmpty

collidedGo : List String -> OrdMap Unit -> OrdMap Unit -> OrdMap Unit
collidedGo [] _ dup = dup
collidedGo (n :: rest) seen dup
  | omHasKey n seen = collidedGo rest seen (omInsert n () dup)
  | otherwise = collidedGo rest (omInsert n () seen) dup

-- ⚠️ DATA constructors only -- `unitLocalCtorNames`' `DNewtype` arm is deliberately
-- NOT consulted here.  A newtype constructor is not importable by ANY spelling (see
-- `offeredCtor`'s #1305 note), so counting one as a collision would rename a
-- DATA constructor that has no cross-module ambiguity at all: measured, that turned
-- `test/eval_modules_fixtures/ctor_type_member_newtype_not_bound` (kmodv's
-- `data KT = Wrap Int Int` beside nmodv's `newtype NT = Wrap Int`) from `1 / 9` to
-- an unbound-variable exit.  #1292's newtype half is explicitly out of scope.
unitMangleCtorNames : (String, List Decl) -> List String
unitMangleCtorNames (_, decls) =
  dedup (filterList evalMangleCandidate (flatMap localDataCtorNames decls))

localDataCtorNames : Decl -> List String
localDataCtorNames (DData { dataCtors = variants }) =
  map variantCtorName variants
localDataCtorNames (DAttrib _ d) = localDataCtorNames d
localDataCtorNames _ = []

evalMangleCandidate : String -> Bool
evalMangleCandidate n = not (evalMangleExemptCtor n)

-- Constructors the INTERPRETER ITSELF matches by bare spelling, on top of the
-- emitter's fixed-tag set.  A tree-wide `grep -n 'VCon "' compiler/ --include=*.mdk`
-- finds exactly one such pair beyond `isReservedCtor`'s list: `tools/test_runner.mdk`
-- reads a `test "…"` body's result as `VCon "Pass" [_, _]` / `VCon "Fail" [_, _, _]`
-- (stdlib `test.mdk`'s `Expectation`).  Renaming those would send every test in a
-- program that happens to declare a colliding `Pass`/`Fail` down `runOneTest`'s
-- `other => Errored` arm.
--
-- ⚠️ A BARE-NAME list, deliberately — the module-scoped alternative ("exempt only
-- stdlib's `Pass`/`Fail`") has no input at this seam: `loader.moduleIdOfPath`
-- discards which ROOT a module came from, so a stdlib `test.mdk` and a user
-- `test.mdk` both arrive as the byte-identical mid `"test"`.  The cost is that
-- #1292 stays live for programs colliding on those two spellings — strictly no
-- worse than today, where EVERY spelling collides.
--
-- Kept SEPARATE from `isReservedCtor` rather than added to it: `isReservedCtor` is
-- the EMITTER's fixed-tag set, and widening it would stop `mangleUnits` renaming a
-- genuine `Pass`/`Fail` collision on the emit path, un-fixing a bug the emit path
-- has already fixed.
evalMangleExemptCtor : String -> Bool
evalMangleExemptCtor n = isReservedCtor n || n == "Pass" || n == "Fail"

mangleCtorModule : OrdMap Unit ->
  List (String, List (String, String, List String)) ->
  (String, List Decl) ->
  (String, List Decl)
mangleCtorModule collided ctorExportsPerUnit (mid, decls) =
  (mid, mangleCtorUnitU collided ctorExportsPerUnit (mid, decls))

-- `mangleUnitU`'s constructor half, with the map filtered down to colliding keys
-- and the function half omitted entirely.
mangleCtorUnitU : OrdMap Unit ->
  List (String, List (String, String, List String)) ->
  (String, List Decl) ->
  List Decl
mangleCtorUnitU collided ctorExportsPerUnit (mid, decls) =
  let rmList =
    filterList
      (renameKeyCollides collided)
      (buildUnitCtorRenameMap mid ctorExportsPerUnit decls)
  let rm = omFromPairs (reverseL rmList) omEmpty
  if isEmptyL rmList then decls else map (renameDecl rm) decls

renameKeyCollides : OrdMap Unit -> (String, String) -> Bool
renameKeyCollides collided (n, _) = omHasKey n collided

-- ── the export surfaces the three export maps read ───────────────────────────
-- Every unit's `ModuleExports`, built by the same `frontend.visibility` producer
-- resolve uses, in unit order.  Units arrive dependency-first (the loader's order),
-- so each `export import` reads a surface already built.  Core's surface is
-- `coreExports` and never enters `known`: `buildExportsWith` resolves an `export
-- import core…` through its own core argument.  The values bound beside the
-- decls' own are every public interface's methods, where resolve passes only the
-- bound ones (`keepBoundMethods`), so a re-export carries those as resolve's
-- surface would once it has them.
unitSurfaces : List (String, List Decl) -> List (String, ModuleExports)
unitSurfaces units = surfacesGo (coreExportsOf units) omEmpty units

-- The prelude's surface among [units]; an empty one when no unit is named "core".
coreExportsOf : List (String, List Decl) -> ModuleExports
coreExportsOf units = match lookupAssoc "core" units
  Some coreDecls => coreExports coreDecls
  None => coreExports []

surfacesGo : ModuleExports ->
  OrdMap ModuleExports ->
  List (String, List Decl) ->
  List (String, ModuleExports)
surfacesGo _ _ [] = []
surfacesGo coreExp known ((mid, decls) :: rest)
  | mid == "core" = (mid, coreExp) :: surfacesGo coreExp known rest
  | otherwise =
    let exp =
      buildExportsWith
        coreExp
        known
        mid
        decls
        (flatMap identity (pubIfaceMethodSets decls))
    (mid, exp) :: surfacesGo coreExp (omInsert mid exp known) rest

-- Per unit, the exported FUNCTION symbols, each paired with the module that
-- defines it: a value the surface exports whose declaration (an
-- `expValueOrigins` row, which names the declaring module) is a function that
-- module defines and exports under that name.  An importer of a re-exported name
-- therefore mangles its reference to `<definer>__<name>`, never
-- `<reExporter>__<name>`, which has no backing definition.  An interface method,
-- a body-less signature and an extern are values but not function symbols.
fnExportsFrom : (String -> ExportView) ->
  List (String, List Decl) ->
  List (String, ModuleExports) ->
  List (String, List (String, String))
fnExportsFrom viewOfUnit units surfaces =
  let fnSyms = omFromPairs (map (unitFnSyms viewOfUnit) units) omEmpty
  let methods = omFromPairs (map surfaceMethods surfaces) omEmpty
  map (unitFnExports fnSyms methods) (zip units surfaces)

surfaceMethods : (String, ModuleExports) -> (String, OrdMap Unit)
surfaceMethods (mid, exp) =
  (mid, omFromNames (flatMap snd exp.expIfaceMethods) omEmpty)

-- The functions a unit defines under a name its own decls export.  This reads
-- the module's direct value exports, not its surface, so a private standalone
-- beside a public interface method of the same name is not offered
-- (`test/llvm_fixtures_modules/method_private_standalone_visibility`).  It keeps
-- core to what core marks exported, too: core's surface is every binding (#2640).
unitFnSyms : (String -> ExportView) ->
  (String, List Decl) ->
  (String, OrdMap Unit)
unitFnSyms viewOfUnit (mid, decls) =
  let defined = omFromNames (unitDefNames (mid, decls)) omEmpty
  let exported = directUnder (viewOfUnit mid) nsValues decls
  (mid, omFromNames (filterInSet defined exported) omEmpty)

-- The first row per name wins: a module's own values precede what it re-exports.
unitFnExports : OrdMap (OrdMap Unit) ->
  OrdMap (OrdMap Unit) ->
  ((String, List Decl), (String, ModuleExports)) ->
  (String, List (String, String))
unitFnExports fnSyms methods ((mid, _), (_, exp)) =
  let origins = multiMapOf exp.expValueOrigins
  (
    mid,
    dedupBy fst (flatMap (fnExport fnSyms methods exp origins) exp.expValues),
  )

-- `origins` holds each name's origins in surface order.  An interface method of
-- its declaring module yields to a later origin, as the front end binds the later function
-- over it (`W-IMPORT-METHOD-SHADOW`); any other first origin decides, and gives a
-- row only if it is a function symbol, so an extern carried ahead of a function
-- keeps the name an extern, as the front end binds it.  A name with no recorded
-- origin is declared by the module that exports it.
fnExport : OrdMap (OrdMap Unit) ->
  OrdMap (OrdMap Unit) ->
  ModuleExports ->
  OrdMap (List (String, String)) ->
  String ->
  List (String, String)
fnExport fnSyms methods exp origins v =
  let decls = optionOr [(exp.modId, v)] (omLookup v origins)
  match find (d => not (isMethodDecl fnSyms methods d)) decls
    Some (dm, dn) =>
      if dn == v && isFnSymbol fnSyms dm dn then [(v, dm)] else []
    None => []

isFnSymbol : OrdMap (OrdMap Unit) -> String -> String -> Bool
isFnSymbol fnSyms dm dn = match omLookup dm fnSyms
  Some syms => omHasKey dn syms
  None => False

isMethodDecl : OrdMap (OrdMap Unit) ->
  OrdMap (OrdMap Unit) ->
  (String, String) ->
  Bool
isMethodDecl fnSyms methods (dm, dn) =
  not (isFnSymbol fnSyms dm dn)
    && (match omLookup dm methods
      Some ms => omHasKey dn ms
      None => False)

-- Every value of each key, in list order.
multiMapOf : List (String, a) -> OrdMap (List a)
multiMapOf pairs =
  fold (m (k, v) => insertWith (++) k [v] m) omEmpty (reverseL pairs)

lookupDefiner : String -> List (String, String) -> Option String
lookupDefiner _ [] = None
lookupDefiner k ((n, d) :: rest) =
  if k == n then Some d else lookupDefiner k rest

-- ── per-unit CONSTRUCTOR exports ──────────────────────────────────────────────
-- (mid, [(typeName, definerMid, [ctorName])]) for the constructors the unit's
-- surface offers an importer, its own and whatever its `export import`s carry.
-- `definerMid` is the DECLARING module, because a ctor's rename target is
-- `<definerMid>__<ctor>`: `bmod`'s row can offer `Wid` (declared in `amod`)
-- without `bmod` ever defining an `@amod__Wid`-shaped symbol.  A type row's
-- definer is the first of the type's declaring modules (`expTypeOrigins`) that
-- also declares every ctor in the row (`expCtorOrigins`): two carried types may
-- share a type name, and two may share a ctor spelling, so neither name alone
-- identifies the declaration.  Two carried types sharing both are not told apart.
--
-- This answers a scope question, "may an IMPORTER name this constructor?", not
-- "does this constructor exist?".  The unit's OWN constructors are mangled from a
-- different, deliberately unfiltered peer (`unitLocalCtorNames`, below), so
-- declining an entry here never leaves a local definition unrenamed; it only
-- declines to offer the symbol ACROSS a `DUse`.  Over-offering is not additive: the
-- entry it manufactures SHADOWS whatever the front end actually bound.
--
-- A row per type in `expTypeCtors`, then a single-ctor row for each exported ctor
-- no such row holds.  That second kind is a ctor carried WITHOUT its type: `export
-- import m.{Tq}` where `m` has `data Tq = Mk Int` and `data Sq = Tq Int Int`
-- carries the type `Tq` and the ctor `Tq` of `Sq`, and only the ctor is a
-- constructor symbol here.
ctorExportsFrom : List (String, ModuleExports) ->
  List (String, List (String, String, List String))
ctorExportsFrom surfaces =
  let surfaceMap = omFromPairs surfaces omEmpty
  let newtypeCtors = omFromPairs (map surfaceNewtypeCtors surfaces) omEmpty
  map (unitCtorExports surfaceMap newtypeCtors) surfaces

surfaceNewtypeCtors : (String, ModuleExports) -> (String, OrdMap Unit)
surfaceNewtypeCtors (mid, exp) =
  (mid, omFromNames (map fst exp.expNewtypeCtors) omEmpty)

unitCtorExports : OrdMap ModuleExports ->
  OrdMap (OrdMap Unit) ->
  (String, ModuleExports) ->
  (String, List (String, String, List String))
unitCtorExports surfaceMap newtypeCtors (mid, exp) =
  let typeDefiners = multiMapOf exp.expTypeOrigins
  let ctorDefiners = multiMapOf exp.expCtorOrigins
  let typed =
    map (typeRowDefiner typeDefiners ctorDefiners mid) exp.expTypeCtors
  let covered = multiMapOf (flatMap rowCtorDefiners typed)
  let loose =
    dedupBy
      ((c, d) => "\{lenKey c}\{d}")
      (filterList
        ((c, d) => not (contains d (definersOf covered c)))
        exp.expCtorOrigins)
  (
    mid,
    map (typeCtorRow newtypeCtors) typed
      ++ flatMap (looseCtorRow surfaceMap newtypeCtors) loose,
  )

definersOf : OrdMap (List String) -> String -> List String
definersOf definers n = optionOr [] (omLookup n definers)

typeRowDefiner : OrdMap (List String) ->
  OrdMap (List String) ->
  String ->
  (String, List String) ->
  (String, String, List String)
typeRowDefiner typeDefiners ctorDefiners mid (ty, cs) =
  let declaresRow = d => all (c => contains d (definersOf ctorDefiners c)) cs
  (ty, optionOr mid (find declaresRow (definersOf typeDefiners ty)), cs)

rowCtorDefiners : (String, String, List String) -> List (String, String)
rowCtorDefiners (_, d, cs) = map (c => (c, d)) cs

typeCtorRow : OrdMap (OrdMap Unit) ->
  (String, String, List String) ->
  (String, String, List String)
typeCtorRow newtypeCtors (ty, definer, cs) =
  (ty, definer, filterList (offeredCtor newtypeCtors definer) cs)

-- A ctor carried without its type.  Its type field is the type the declaring
-- module's surface gives it, or `""` when that surface has none; `""` names no
-- importable type, so `lookupCtorTypeEntry` never selects such a row.
looseCtorRow : OrdMap ModuleExports ->
  OrdMap (OrdMap Unit) ->
  (String, String) ->
  List (String, String, List String)
looseCtorRow surfaceMap newtypeCtors (c, definer) =
  if offeredCtor newtypeCtors definer c then
    let ty = match omLookup definer surfaceMap
      Some src => optionOr "" (typeOfCtor c src)
      None => ""
    [(ty, definer, [c])]
  else
    []

-- The surface's constructors an importer may be offered, each with the module
-- that declares it.  A reserved one (the emitter's fixed-tag set) is never
-- mangled: mangling would lose its reserved tag.
--
-- A newtype's constructor is never offered (#1305).  It is not importable by ANY
-- spelling: `import nmod.{NT(..)}`, `import nmod.{NT, Wrap}` and `import nmod.*`
-- all give `T-UNBOUND` `Unbound variable: Wrap`, because typecheck never publishes
-- the ctor's scheme, so an offered `<nmod>__Wrap` would shadow whatever the front
-- end bound under that spelling.  The surface still lists an `export newtype`'s
-- ctor, and only the DECLARING module's surface says it is one (`expNewtypeCtors`
-- crosses no hop), so that is where this reads.  `eval.ctorsByTypeOf`
-- (`compiler/eval/eval.mdk`) is the interpreter-side peer.
--
-- Visibility is the producer's.  A real module's surface holds only the ctors of
-- its `public export data` and those its `export import`s carry; core's is every
-- ctor the prelude declares (`coreExports`).  A module can export a TYPE and
-- privately declare a CONSTRUCTOR of the same spelling:
--     public export data Zz = Mk Int      -- mp exports the TYPE `Zz`
--     data Hidden = Zz Int Int            -- ...and privately declares a CTOR `Zz`
-- and an importer of `mp.{Zz(..)}` and `mq.{Zz}` has `Zz` bound to mq's public
-- ctor, so an offered private `mp__Zz` would win on decl order (`mangleUnitU`'s
-- first-entry-wins `omFromPairs`).  Pinned by
-- `test/llvm_fixtures_modules/ctor_scope_private_ctor_not_offered/` and its
-- import-permuted twin.
offeredCtor : OrdMap (OrdMap Unit) -> String -> String -> Bool
offeredCtor newtypeCtors definer c =
  nonReservedCtor c
    && not (match omLookup definer newtypeCtors
      Some ns => omHasKey c ns
      None => False)

variantCtorName : Variant -> String
variantCtorName (Variant n _) = n

-- The emitter's fixed-tag constructors (reservedTag + True/False immediates in
-- llvm_emit.mdk).  Mangling any of these would break the reserved-tag match.
nonReservedCtor : String -> Bool
nonReservedCtor n = not (isReservedCtor n)

export
isReservedCtor : String -> Bool
isReservedCtor n = isSome (namedRuntimeCtor n)

-- ── the unit's CONSTRUCTOR rename map ─────────────────────────────────────────
-- local ctors → `<mid>__<ctor>` (local shadows imports), then imported ctors →
-- `<originMid>__<ctor>`, then core's ctors as implicit-prelude entries.  Keyed by
-- bare ctor name; reserved ctors are excluded at the export step so they never
-- enter the map.
buildUnitCtorRenameMap : String ->
  List (String, List (String, String, List String)) ->
  List Decl ->
  List (String, String)
buildUnitCtorRenameMap mid ctorExportsPerUnit decls =
  let localCtors = dedup (unitLocalCtorNames decls)
  let localEntries = flatMap (localCtorRenameEntry mid) localCtors
  let importEntries = ctorImportEntries mid ctorExportsPerUnit decls
  localEntries ++ importEntries

-- local (this-unit-declared) constructor names, reserved ones excluded.
unitLocalCtorNames : List Decl -> List String
unitLocalCtorNames decls =
  filterList nonReservedCtor (flatMap localCtorNames decls)

localCtorNames : Decl -> List String
localCtorNames (DData { dataCtors = variants }) = map variantCtorName variants
localCtorNames (DNewtype { newtypeCtor = con }) = [con]
localCtorNames (DAttrib _ d) = localCtorNames d
localCtorNames _ = []

localCtorRenameEntry : String -> String -> List (String, String)
localCtorRenameEntry mid n = [(n, mangledName mid n)]

-- imported ctors: for each `DUse` of a non-core module M, the ctor names it brings
-- in (a `T(..)` member expands to all of M's ctors of type T; a bare `Ctor` member
-- maps that single name if M exports it) → `<M>__<ctor>`.  Plus core's exported
-- ctors as implicit prelude (`Rep`'s RCon/RInt/… — Ordering/Option/Result ctors are
-- reserved and were never entered).  Local-first ordering already shadows these.
ctorImportEntries : String ->
  List (String, List (String, String, List String)) ->
  List Decl ->
  List (String, String)
ctorImportEntries _ ctorExportsPerUnit decls =
  flatMap (declCtorImportEntries ctorExportsPerUnit) decls
    ++ coreCtorImportEntries ctorExportsPerUnit

coreCtorImportEntries : List (String, List (String, String, List String)) ->
  List (String, String)
coreCtorImportEntries ctorExportsPerUnit =
  match lookupCtorExports "core" ctorExportsPerUnit
    Some entries => flatMap typeCtorEntries entries
    None => []

declCtorImportEntries : List (String, List (String, String, List String)) ->
  Decl ->
  List (String, String)
declCtorImportEntries ctorExportsPerUnit (DUse _ path _) =
  useCtorPathEntries ctorExportsPerUnit path
declCtorImportEntries ctorExportsPerUnit (DAttrib _ d) =
  declCtorImportEntries ctorExportsPerUnit d
declCtorImportEntries _ _ = []

useCtorPathEntries : List (String, List (String, String, List String)) ->
  UsePath ->
  List (String, String)
useCtorPathEntries ctorExportsPerUnit path =
  let mid = useModId path
  if mid == "core" then
    []
  else match lookupCtorExports mid ctorExportsPerUnit
    None => []
    Some typeEntries => match path
      UseGroup _ members => flatMap (ctorMemberEntry typeEntries) members
      UseWild _ => flatMap typeCtorEntries typeEntries
      UseName _ => []
      -- `import m as A`: every ctor m exports is reachable as `A.Ctor`, which
      -- resolve has already shortened to `Ctor` by the time a tree gets here —
      -- so the binding set is `UseWild`'s (#1287).
      UseAlias _ _ => flatMap typeCtorEntries typeEntries
-- `import M.{T(..), Ctor, …}`: a `(..)` member is a TYPE whose ctors all come
-- in; a bare member may be either a ctor name or a type — entered if it names
-- a ctor M exports (a type-only member contributes nothing here).

-- `import M.*`: every ctor M exports comes into scope.

-- a UseGroup member → ctor entries.  `UseMember name True` (`name(..)`) expands to
-- all of type `name`'s ctors; EVERY member, wild or not, ALSO enters `name` itself
-- iff `name` is one of M's exported ctors.
--
-- 🚨 THE `(..)` IS A SUFFIX ON A MEMBER, NOT A SEPARATE SYNTACTIC FORM, so the wild
-- branch is ADDITIVE to the bare-member branch rather than an alternative to it
-- (#1300).  `typeEntries` is keyed by TYPE name, so `lookupCtorTypeEntry` asks "is
-- `name` a type?"; when `name` is a CONSTRUCTOR the lookup misses, and treating the
-- miss as `[]` dropped the ctor from the rename map entirely — `import qa.{Jj(..)}`
-- on `public export data QT = Jj Int` built to `E-PANIC: unbound variable 'Jj'`
-- while `check` and `run` were both correct.  Writing the same import WITHOUT `(..)`
-- was fine, because that spelling took the bare branch.
--
-- This mirrors the three ARMS of `frontend/visibility.expandMemberNames` —
-- the scope layer this one has to agree with:
--   * `UseMember name False`      → binds `name`                (bare only)
--   * `UseMember name True`, hit  → binds `name` :: that type's ctors
--   * `UseMember name True`, miss → binds `name`                (bare only)
-- In the hit case resolve binds the member name too, which matters when `name` is
-- both a type of M and a ctor of some other type of M; the bare check is what
-- decides, exactly as it does for a non-wild member.  When the type and its sole
-- ctor share a spelling (`data Foo = Foo Int`) both halves yield the SAME pair, and
-- `mangleUnitU`'s `omFromPairs` collapses the duplicate.
--
-- Mirroring the arms is not mirroring the table.  These arms only ask questions;
-- `ctorExportsFrom` answers them, from the export surface resolve reads, so the
-- arms and resolve agree only while that table is the producer's answer.  Each type
-- entry carries its own `definerMid` (a re-exported entry's differs from the DUse
-- target module), so the mangled name is built from that, never from the import
-- path's own module id.
ctorMemberEntry : List (String, String, List String) ->
  UseMember ->
  List (String, String)
ctorMemberEntry typeEntries (UseMember name wild _ _) =
  if wild then match lookupCtorTypeEntry name typeEntries
    Some (_, definer, ctors) =>
      bareCtorMemberEntry typeEntries name
        ++ flatMap (originCtorEntry definer) ctors
    None => bareCtorMemberEntry typeEntries name
  else
    bareCtorMemberEntry typeEntries name

-- `name` itself, iff M exports a CONSTRUCTOR so spelled.  Scans every type's ctor
-- list because the question is about ctor-ness, not about which type owns it; the
-- OWNING entry's `definerMid`, not the DUse target, names the mangled origin.
bareCtorMemberEntry : List (String, String, List String) ->
  String ->
  List (String, String)
bareCtorMemberEntry [] _ = []
bareCtorMemberEntry ((_, definer, ctors) :: rest) name =
  if contains name ctors then
    originCtorEntry definer name
  else
    bareCtorMemberEntry rest name

typeCtorEntries : (String, String, List String) -> List (String, String)
typeCtorEntries (_, definer, ctors) = flatMap (originCtorEntry definer) ctors

originCtorEntry : String -> String -> List (String, String)
originCtorEntry mid n = [(n, mangledName mid n)]

lookupCtorTypeEntry : String ->
  List (String, String, List String) ->
  Option (String, String, List String)
lookupCtorTypeEntry _ [] = None
lookupCtorTypeEntry k ((e@(t, _, _)) :: rest) =
  if k == t then Some e else lookupCtorTypeEntry k rest

lookupCtorExports : String ->
  List (String, List (String, String, List String)) ->
  Option (List (String, String, List String))
lookupCtorExports _ [] = None
lookupCtorExports k ((m, es) :: rest) =
  if k == m then Some es else lookupCtorExports k rest

-- a module keeps its mid in the output pair.
mangleModule : String ->
  List (String, List (String, String)) ->
  List (String, List (String, String, List String)) ->
  (String -> ExternDecl -> String) ->
  OrdMap (OrdMap String) ->
  (String, List Decl) ->
  (String, List Decl)
mangleModule entryMid exportsPerUnit ctorExportsPerUnit externName externExports (mid, decls) = (
  mid,
  mangleUnitU
    entryMid
    exportsPerUnit
    ctorExportsPerUnit
    externName
    externExports
    (mid, decls),
)

-- ── per-unit universal rename ────────────────────────────────────────────────
-- For one unit: build the combined rename map (own top-level fns → `<mid>__<name>`,
-- PLUS each imported bare name → its origin module's mangled symbol), then rewrite
-- the unit's decls (definition names + all in-scope references).
mangleUnitU : String ->
  List (String, List (String, String)) ->
  List (String, List (String, String, List String)) ->
  (String -> ExternDecl -> String) ->
  OrdMap (OrdMap String) ->
  (String, List Decl) ->
  List Decl
mangleUnitU entryMid exportsPerUnit ctorExportsPerUnit externName externExports (mid, decls) =
  let rmFn =
    buildUnitRenameMap
      entryMid
      mid
      exportsPerUnit
      externName
      externExports
      decls
  let rmCtor = buildUnitCtorRenameMap mid ctorExportsPerUnit decls
  let rmList = rmFn ++ rmCtor
  -- omFromPairs over the REVERSED list so the FIRST list entry wins on a duplicate
  -- key — byte-identical to the old first-match `lookupAssoc n rmList`.
  let rm = omFromPairs (reverseL rmList) omEmpty
  if isEmptyL rmList then decls else map (renameDecl rm) decls
-- Function and constructor names occupy disjoint namespaces (ctors Capitalized,
-- fns lowercase), so the two bare-name maps merge without key conflict.  A merged
-- single map lets renameScoped's existing EVar arm rewrite a nullary/partial ctor
-- reference, and renameDecl/renamePat add the def-site + pattern ctor rewrites.

-- The unit's rename map.  Order matters: LOCAL definitions are prepended LAST so a
-- local def shadows an imported same-named binding (lookupAssoc is first-match).
-- In the entry unit no entry is keyed `main` at all, whether it comes from the
-- unit's own definition, an import, or a `{x as main}` rename: there the key is the
-- program entry and must stay bare.
buildUnitRenameMap : String ->
  String ->
  List (String, List (String, String)) ->
  (String -> ExternDecl -> String) ->
  OrdMap (OrdMap String) ->
  List Decl ->
  List (String, String)
buildUnitRenameMap entryMid mid exportsPerUnit externName externExports decls =
  let localFns = dedup (unitDefNames (mid, decls))
  let localEntries =
    map (n => (n, mangledName mid n)) localFns
      ++ externDeclEntries (externName mid) decls
  let importEntries = importRenameEntries mid exportsPerUnit decls
  let entries =
    localEntries
      ++ importEntries
      ++ flatMap (externImportEntries externExports) decls
  if mid == entryMid then
    filterList (e => not (isEntryMainKey entryMid mid (fst e))) entries
  else
    entries
-- local first ⇒ shadows any imported entry with the same key under lookupAssoc.

-- Extern declarations name host symbols. Their imported spellings must be
-- erased without adding a module prefix, including through re-export chains.
-- Per unit, each value its surface exports whose declaration is an extern, named
-- from the module that declares it.
externExportsFrom : (String -> ExternDecl -> String) ->
  List (String, List Decl) ->
  List (String, ModuleExports) ->
  OrdMap (OrdMap String)
externExportsFrom externName units surfaces =
  let externs = omFromPairs (map unitExternDecls units) omEmpty
  omFromPairs (map (unitExternExports externName externs) surfaces) omEmpty

unitExternDecls : (String, List Decl) -> (String, OrdMap ExternDecl)
unitExternDecls (mid, decls) =
  (mid, omFromPairs (reverseL (externDeclEntries identity decls)) omEmpty)

unitExternExports : (String -> ExternDecl -> String) ->
  OrdMap (OrdMap ExternDecl) ->
  (String, ModuleExports) ->
  (String, OrdMap String)
unitExternExports externName externs (mid, exp) =
  let origins = valueDeclsOf exp
  let entries =
    flatMap (externExport externName externs exp origins) exp.expValues
  (mid, omFromPairs (reverseL entries) omEmpty)

externExport : (String -> ExternDecl -> String) ->
  OrdMap (OrdMap ExternDecl) ->
  ModuleExports ->
  OrdMap (String, String) ->
  String ->
  List (String, String)
externExport externName externs exp origins v = match valueDeclOf exp origins v
  (dm, dn) => match omLookup dm externs
    Some eds => match omLookup dn eds
      Some ed => [(v, externName dm ed)]
      None => []
    None => []

-- `name` is applied to each extern declaration of the unit.
externDeclEntries : (ExternDecl -> a) -> List Decl -> List (String, a)
externDeclEntries _ [] = []
externDeclEntries name ((DExtern ed) :: rest) =
  (ed.edName, name ed) :: externDeclEntries name rest
externDeclEntries name ((DAttrib _ decl) :: rest) =
  externDeclEntries name [decl] ++ externDeclEntries name rest
externDeclEntries name (_ :: rest) = externDeclEntries name rest

-- The program-wide name of an extern declared in module `mid`.  One with `bind`
-- clauses names whatever its clauses bind, which another module may bind
-- differently under the same Medaka name, so like a function it takes the
-- module-scoped name and both emitters key its foreign call by that.  One with
-- none binds the C symbol it is spelled as (`frontend.ast.externBindings`), the
-- one function every module spelling it shares; a `stdlib/runtime.mdk` catalog
-- name is always of this kind (T-FFI-BUILTIN-BIND refuses its clauses) and the
-- emitters dispatch it by that spelling, so it keeps it.
externSymbolName : String -> ExternDecl -> String
externSymbolName mid ed = sourceExternSymbol mid ed.edName

-- The name an extern's declaration wrote, for a message, from its program-wide
-- name and its (host, symbol) bindings.  A declaration without clauses has the
-- implied C binding of its own spelling as its only one and was not renamed;
-- any other was, so its module prefix comes off through the first `__`.  A
-- module id whose sanitized form holds `__` keeps the rest of that prefix.
export
externDeclaredName : String -> List (String, String) -> String
externDeclaredName n binds
  | isSome (externDisplayName n) = optionOr n (externDisplayName n)
  | binds == [("c", n)] = n
  | otherwise = match stringIndexOf "__" n
    Some i => stringSlice (i + 2) (stringLength n) n
    None => n

externImportEntries : OrdMap (OrdMap String) -> Decl -> List (String, String)
externImportEntries exports (DUse _ path _) =
  match omLookup (useModId path) exports
    Some names => externPathEntries names path
    None => []
externImportEntries exports (DAttrib _ decl) = externImportEntries exports decl
externImportEntries _ _ = []

externPathEntries : OrdMap String -> UsePath -> List (String, String)
externPathEntries names (UseGroup _ members) =
  flatMap
    (member =>
      externMemberEntry names (useMemberOrigin member) (useMemberLocal member))
    members
externPathEntries names (UseWild _) =
  flatMap (name => externMemberEntry names name name) (omKeys names)
externPathEntries names (UseName parts) =
  if lenGt1 parts then
    externMemberEntry names (lastOfPM parts) (lastOfPM parts)
  else
    []
externPathEntries names (UseAlias _ alias) =
  flatMap
    (name => externMemberEntry names name (qualifiedLocal alias name))
    (omKeys names)

externMemberEntry : OrdMap String -> String -> String -> List (String, String)
externMemberEntry names origin local = match omLookup origin names
  Some symbol => [(local, symbol)]
  None => []

-- ── a locally declared interface method un-claims its IMPLICIT-PRELUDE entry ──
-- S1-PRELUDE (a) (`docs/spec/SHADOW-SEMANTICS.md`, fixtures `x4_*`/`x5_*`): the
-- implicit prelude is in NEITHER half of S1's left-operand kind partition, so a
-- prelude STANDALONE creates no shadow — when a module declares an interface method
-- of the same name (e.g. `print`, `count`, `isEven`), a bare occurrence of that name
-- denotes the METHOD, and the prelude function is no longer reachable by its bare
-- name anywhere in the module (exactly what W-PRELUDE-METHOD-SHADOW says).
-- `frontend/marker.mdk`'s `markWith` implements that by building its method set as
-- `preludeMethods ++ interfaceMethodNames prog` and rewriting `EVar n` → `EMethodRef n`.
--
-- This pass runs BEFORE marking on the emit path, and an interface method is not a
-- `DFunDef`/`DLetGroup` binder, so it is absent from `unitDefNames` and rule 1 does
-- not fire for it.  Rule 3 (implicit prelude) then claimed the reference and rewrote
-- it to `core__<n>` — by the time the marker ran, the occurrence no longer SPELLED
-- the method's name, so it was never marked, and the emitted binary called the
-- PRELUDE while `check`/`run` called the method.  Measured: `main = println (print 1)`
-- against a local `interface Ifc c where print : c -> Int` emitted
-- `call @mdk_core__print` and printed `1()`, where `run` printed `1` — a silent
-- run/binary disagreement with no diagnostic on either side.
--
-- SCOPE — the core half ONLY.  An EXPLICIT sibling import (`import prov.{size}`) that
-- collides with a local interface method is the DIFFERENT, ruled I1/I2 cell
-- (`test/shadow_fixtures/i1_importer_local_iface/`): there the standalone stays
-- reachable and a no-impl receiver FALLS BACK to it, so its `prov__size` entry must
-- survive or the fallback call site loses its symbol.  Dropping both halves reds six
-- importer assertions in `test/diff_compiler_shadow_semantics_test.mdk` (measured).
--
-- The entry is DROPPED, not redirected: per rule 4 at the top of this file, method
-- names have their own emitter naming (impl keys), and this pass must leave the
-- occurrence unchanged so the marker sees the method's own spelling.
notIfaceMethodKey : OrdMap Unit -> (String, String) -> Bool
notIfaceMethodKey methods (n, _) = not (omHasKey n methods)

-- names of the methods of every `interface` DECLARED in this unit.  Mirrors
-- `frontend/marker.mdk`'s `interfaceMethodNames`, plus the `DAttrib` unwrap that
-- `declBinderNames` here already does.
unitIfaceMethodNames : List Decl -> List String
unitIfaceMethodNames [] = []
unitIfaceMethodNames ((DInterface { methods, ... }) :: rest) =
  map ifaceMethodNameM methods ++ unitIfaceMethodNames rest
unitIfaceMethodNames ((DAttrib _ d) :: rest) =
  unitIfaceMethodNames [d] ++ unitIfaceMethodNames rest
unitIfaceMethodNames (_ :: rest) = unitIfaceMethodNames rest

ifaceMethodNameM : IfaceMethod -> String
ifaceMethodNameM (IfaceMethod n _ _ _) = n

-- `main` is the program entry (`@main`) only in the entry unit, so only there is
-- the key left unmangled.  Keyed by the unit, never by the bare spelling: a library
-- module's `main` is a plain function, and leaving it bare in every unit merged it
-- with the entry's into one two-clause `main`.
isEntryMainKey : String -> String -> String -> Bool
isEntryMainKey entryMid mid n = mid == entryMid && n == "main"

-- ── import-aware reference targets ───────────────────────────────────────────
-- For each `DUse` of a non-core module `M`, the bare names it brings into this
-- unit map to `M`'s mangled symbols.  Plus the implicit prelude: every core
-- export is in scope as `core__<name>` (a local def shadows it via local-first
-- ordering; an explicit import of the same name from a sibling shadows core via
-- import-entry ordering below).
-- explicit sibling imports first (they shadow the implicit prelude), prelude last.
-- The prelude half is filtered by the unit's own interface-method names — see
-- `notIfaceMethodKey` above for why, and why the explicit half is NOT filtered.
importRenameEntries : String ->
  List (String, List (String, String)) ->
  List Decl ->
  List (String, String)
importRenameEntries _ exportsPerUnit decls =
  flatMap (declImportEntries exportsPerUnit) decls
    ++ filterList
      (notIfaceMethodKey (omFromNames (unitIfaceMethodNames decls) omEmpty))
      (coreImportEntries exportsPerUnit)

-- #2089: the implicit prelude is EVERY top-level binding of core, not only its
-- exports.  `check` binds a user occurrence of a private core helper (measured:
-- `main = println (derivedArgNeedsParens "a b")` typechecks from a user file),
-- desugar's `deriving` code references the private `derivedShowWrap`, and the
-- emitter's own `canonFnName` fallback already resolves such a bare name to
-- `core__<n>`.  Mapping every core binding here makes the emit-path typecheck bind
-- the same symbol the emitted code calls, instead of recording an unbound-variable
-- error that nothing read.  Only the "core" row is widened; sibling imports stay
-- export-scoped.  This mirrors `check`'s visibility rule; whether that rule is
-- right (core's private helpers reachable from user code) is #2640's question, and
-- this row must keep every binding until it is answered.  `implicit` follows
-- core's bindings in the row, so a core binding shadows an implicit name.
withPreludeDefs : List String ->
  List (String, String) ->
  List (String, List (String, String)) ->
  List (String, List (String, String))
withPreludeDefs names implicit entries =
  map
    (e =>
      if fst e == "core" then
        ("core", map (n => (n, "core")) names ++ implicit)
      else
        e)
    entries

-- core's bindings as implicit-prelude entries (`name → core__name`).
coreImportEntries : List (String, List (String, String)) ->
  List (String, String)
coreImportEntries exportsPerUnit = match lookupExports "core" exportsPerUnit
  Some names => flatMap coreEntry names
  None => []

coreEntry : (String, String) -> List (String, String)
coreEntry (n, definer) = [(n, mangledName definer n)]

-- a single `DUse path` → the (bareName, originMangled) entries it introduces.
declImportEntries : List (String, List (String, String)) ->
  Decl ->
  List (String, String)
declImportEntries exportsPerUnit (DUse _ path _) =
  usePathEntries exportsPerUnit path
declImportEntries exportsPerUnit (DAttrib _ d) =
  declImportEntries exportsPerUnit d
declImportEntries _ _ = []

-- the LOCAL names a UsePath brings in, each mapped to its ORIGIN's real symbol
-- `<originMid>__<name>`.  Only names that are EXPORTED FUNCTIONS of the origin module
-- are entered (a member that is a type/ctor/value isn't a top-level fn symbol, so leave
-- it unchanged).
--   UseGroup `import M.{a, b}`      → only the listed members ∩ M's exports
--   UseGroup `import M.{a as b}`    → local `b` → M's `a` symbol
--   UseWild  `import M.*`           → every exported fn of M
--   UseName  `import M[.sub]`       → the single stub name (last component), if an export
--   UseAlias `import M as A`        → every exported fn of M, under `A.<name>`
--
-- The UseAlias case is what erases a module alias from the emitted code: desugar turned
-- the qualified reference into the flat name `A.name`, and this maps that name onto M's
-- real symbol.  No dotted name ever reaches the LLVM/Wasm output.
usePathEntries : List (String, List (String, String)) ->
  UsePath ->
  List (String, String)
usePathEntries exportsPerUnit path =
  let mid = useModId path
  if mid == "core" then
    corePathEntries exportsPerUnit path
  else match lookupExports mid exportsPerUnit
    None => []
    Some exports => match path
      UseGroup _ members => flatMap (memberEntry exports) members
      UseWild _ => flatMap originEntryPair exports
      UseName ns => originEntry exports (lastOfPM ns)
      UseAlias _ a => flatMap (aliasEntryPair a) exports

-- The implicit prelude's BARE spellings are already entered for every unit by
-- `coreImportEntries`, so the only prelude rows an explicit `import core …` owes are the
-- ones that introduce a name the bare pass cannot know: the alias-qualified `C.<name>`
-- and a member RENAME's new local.  Everything else stays `[]`, which is what this arm
-- returned for all four spellings before.  The name set is the same `exportsPerUnit`
-- row `coreImportEntries` reads, deliberately: resolve decides what a prelude alias may
-- name, and an entry here for a name resolve refuses is never reachable from emitted
-- code.  Widening THIS row is therefore not the #2640 question; `withPreludeDefs` is.
corePathEntries : List (String, List (String, String)) ->
  UsePath ->
  List (String, String)
corePathEntries exportsPerUnit path = match lookupExports "core" exportsPerUnit
  None => []
  Some exports => match path
    UseAlias _ a => flatMap (aliasEntryPair a) exports
    UseGroup _ members => flatMap (coreRenamedEntry exports) members
    _ => []

coreRenamedEntry : List (String, String) -> UseMember -> List (String, String)
coreRenamedEntry exports m = match useMemberAlias m
  None => []
  Some local => originEntryAs exports (useMemberOrigin m) local

-- a UseGroup member → entry if its ORIGIN names an exported fn of the origin module;
-- the entry is keyed by the member's LOCAL name (its alias, if it has one).
memberEntry : List (String, String) -> UseMember -> List (String, String)
memberEntry exports m =
  originEntryAs exports (useMemberOrigin m) (useMemberLocal m)

-- bare name `n` → `<definer>__<n>` iff `n` is an exported fn of the imported module
-- (`exports` is that module's (name, definer) pairs).  For a RE-EXPORTED name the
-- definer is the ORIGINAL owning module, so the reference points at the real symbol
-- rather than the re-exporter's non-existent one.
originEntry : List (String, String) -> String -> List (String, String)
originEntry exports n = originEntryAs exports n n

-- like originEntry, but the entry is keyed by an arbitrary LOCAL name (an alias).
originEntryAs : List (String, String) ->
  String ->
  String ->
  List (String, String)
originEntryAs exports origin local = match lookupDefiner origin exports
  Some definer => [(local, mangledName definer origin)]
  None => []

-- a wildcard import iterates the (name, definer) pairs directly.
originEntryPair : (String, String) -> List (String, String)
originEntryPair = coreEntry

-- a module alias iterates the same pairs, keying each under `A.<name>`.
aliasEntryPair : String -> (String, String) -> List (String, String)
aliasEntryPair a (n, definer) = [(qualifiedLocal a n, mangledName definer n)]

lenGt1 : List a -> Bool
lenGt1 (_ :: _ :: _) = True
lenGt1 _ = False

lastOfPM : List String -> String
lastOfPM [] = ""
lastOfPM [x] = x
lastOfPM (_ :: rest) = lastOfPM rest

lookupExports : String ->
  List (String, List (String, String)) ->
  Option (List (String, String))
lookupExports _ [] = None
lookupExports k ((m, ns) :: rest) =
  if k == m then Some ns else lookupExports k rest

-- ── collision-name detection (RETAINED — kept available, no longer the trigger) ──
-- all top-level FUNCTION names defined in a unit (DFunDef + DLetGroup binders),
-- wrapped through DAttrib.  Only function-shaped decls can collide as @mdk_<name>.
unitDefNames : (String, List Decl) -> List String
unitDefNames (_, decls) = flatMap declBinderNames decls

-- Encode the module component injectively while retaining the raw name tail.
export
mangledName : String -> String -> String
mangledName mid name = encodePair mid name

export
sanitizeId : String -> String
sanitizeId s = sanitizeGo s 0 (stringLength s) ""

sanitizeGo : String -> Int -> Int -> String -> String
sanitizeGo s i len acc =
  if i >= len then
    acc
  else
    let c = stringSlice i (i + 1) s
    let c2 = if safeChar c then c else "_"
    sanitizeGo s (i + 1) len (acc ++ c2)

export
safeChar : String -> Bool
safeChar c =
  c >= "a" && c <= "z"
    || c >= "A" && c <= "Z"
    || c >= "0" && c <= "9"
    || c == "_"

-- #1950: encode an ARBITRARY String as a legal emitted identifier, INJECTIVELY.
-- This is the ONE definition of that encoding: `core_ir_lower.stampImplSymbols`
-- calls it to spell every impl symbol, and both backends read that stamp, so they
-- and the injectivity guard cannot drift apart about what symbol was emitted.
--
-- ⚠️ It is NOT `sanitizeId`, and must never be reimplemented as a wrapper over it.
-- `sanitizeId` is MANY-TO-ONE — everything outside [A-Za-z0-9_] becomes `_` — which
-- is exactly #1950: the canonical impl keys `main::Sz|(Q A_B C)|` and
-- `main::Sz|(Q A B_C)|` both sanitize to `main__Sz__Q_A_B_C__`, so two DISTINCT
-- impls of one method were minted under one symbol (`run` answered correctly,
-- `build` died at clang with a raw `invalid redefinition of function`).
--
-- The encoding is two branches with DISJOINT IMAGES, which is what makes it
-- injective on all of `String` and not merely on the keys we happen to mint today:
--   * a string already spelled only in [A-Za-z0-9_] that does NOT start with the
--     two-character marker `zZ` maps to ITSELF.  That covers every prelude and
--     builtin head tag (`Int`, `List`, `__tuple2__`), so their symbols read as
--     the type's name.  A module-qualified head tag (`app.T`, #1397) takes the
--     escape branch.
--   * everything else maps to `zZ` ++ escape, where an alphanumeric character is
--     kept verbatim and EVERY other character — `_` included, since `_` is the
--     escape introducer — becomes `_<lowercase hex of its code>_`.  Hex digits are
--     never `_`, so each escape is self-delimiting and the escape inverts.
-- Only the second branch can produce a `zZ`-prefixed result, so the two images are
-- disjoint; each branch is injective on its own domain.  A type head cannot begin
-- with a lowercase letter, so withholding the identity branch from `zZ`-prefixed
-- inputs costs no real tag its byte-identical symbol — and only PARITY rests on
-- that, never correctness.
export
injectiveIdent : String -> String
injectiveIdent s =
  if allSafeChars s 0 (stringLength s) && not (startsZZ s) then
    s
  else
    "zZ\{escapeGo s 0 (stringLength s) ""}"

-- does [s] already begin with the escape marker?  Such a string must take the
-- escape branch even if it is otherwise a plain identifier, or the two images
-- would overlap and injectivity would be lost.
startsZZ : String -> Bool
startsZZ s = stringSlice 0 2 s == "zZ"

-- `safeChar` lifted to a whole string.
allSafeChars : String -> Int -> Int -> Bool
allSafeChars s i len =
  if i >= len then
    True
  else if safeChar (stringSlice i (i + 1) s) then
    allSafeChars s (i + 1) len
  else
    False

escapeGo : String -> Int -> Int -> String -> String
escapeGo s i len acc =
  if i >= len then
    acc
  else
    let c = stringSlice i (i + 1) s
    let c2 = if alnumChar c then c else "_\{hexOfChar c}_"
    escapeGo s (i + 1) len (acc ++ c2)

-- `safeChar` MINUS the underscore: `_` introduces an escape, so it has to be
-- escaped like any other non-alphanumeric character.
alnumChar : String -> Bool
alnumChar c =
  c >= "a" && c <= "z" || c >= "A" && c <= "Z" || c >= "0" && c <= "9"

-- the code of a one-character string in lowercase hex, unpadded — the trailing `_`
-- delimits the escape, so a fixed width would buy nothing.
hexOfChar : String -> String
hexOfChar c = hexOfInt (charCode (arrayGetUnsafe 0 (stringToChars c)))

hexOfInt : Int -> String
hexOfInt n =
  if n < 16 then hexNibble n else hexOfInt (n / 16) ++ hexNibble (n % 16)

hexNibble : Int -> String
hexNibble n = stringSlice n (n + 1) "0123456789abcdef"

-- hashName: a deterministic djb2 string hash (seed 5381), computed in the EMITTER
-- (the emitted IR carries the decimal constant).  Shared by BOTH backends so the
-- dict-witness tag / route-key dispatch agrees across LLVM and WasmGC — the hash
-- MUST be byte-identical between them.
--
-- 🚨 `hashName` IS NOT INJECTIVE, and not merely "astronomically unlikely" to
-- collide — colliding pre-images are CONSTRUCTIBLE, in the FULL i64, with no
-- masking.  djb2 is the radix-33 polynomial `5381*33^n + Σ c_i*33^i`, and the
-- identifier alphabet spans 74 code points (`0` = 48 … `z` = 122) — WIDER than the
-- radix — so `Δ_{i+1} = +1, Δ_i = −33` at two ADJACENT positions is an exact zero:
-- `hashName "Az" == hashName "BY" == 5862176`, `hashName "Mzone" == hashName
-- "NYone" == 210683374574`.  Before #348's guard that was a live S0: two impls at
-- head tycons `Mzone`/`NYone` compiled to one `icmp eq i64 %headTag, 210683374574`
-- in the shared dispatcher, so `build` answered `mzone|mzone` where the
-- interpreter answered `mzone|nyone`, at exit 0 with no diagnostic.  Calling this
-- shape "astronomically unlikely" is wrong about the mechanism: the hash's
-- non-injectivity has nothing to do with the tag alphabet being small, and
-- nothing to do with the mask width.
-- `core_validate.validateDictTags` is what makes it loud; keep the two together.
--
-- Each step is computed in `U64`, which wraps by definition, and narrowed to its
-- low 63 bits: the value the tags have always had, when `Int` itself wrapped.
export
hashName : String -> Int
hashName s = hashChars (stringToChars s) 0 5381

hashChars : Array Char -> Int -> Int -> Int
hashChars cs i acc
  | i >= arrayLength cs = acc
  | otherwise =
    hashChars
      cs
      (i + 1)
      (U64.toIntTruncating
        (U64.truncate acc * 33 + U64.truncate (charCode (arrayGetUnsafe i cs))))

-- the i31-safe dict-witness tag: `hashName` masked into the low 30 bits (positive
-- range of an i31).  The full djb2 hash is an i64 in the LLVM backend (an i64 dict
-- word); a WasmGC dict witness rides an i31 immediate (31 bits), so the raw hash
-- (e.g. `hashName "Color"` = 210671116836, a 38-bit value) overflows `i32.const`.
-- Masking to 30 bits keeps it a positive i32/i31 that `i31.get_s` reads back
-- unchanged, and — being applied identically at witness CREATION
-- (`wasm_emit.routeWitness`) and at the dispatch COMPARISON
-- (`wasm_emit.emitDispatchChain`) — preserves the equality test.  (No bitwise
-- primitive in the compiler subset; `% 2^30` is the mask.)
--
-- Lives HERE, beside `hashName`, rather than in `wasm_emit`, because
-- `core_validate.validateDictTags` must check the WASM tag space with the SAME
-- expression the wasm emitter mints — a second copy of the mask in the guard is a
-- copy that can drift, and a drifted guard certifies the wrong property.  The
-- 30-bit space inherits every `hashName` collision (masking cannot separate equal
-- values) AND adds its own: two pre-images whose full hashes differ by a nonzero
-- multiple of 2^30.
export
dictTag : String -> Int
dictTag s = posMod (hashName s) 1073741824

-- a non-negative remainder (Medaka `%` can be negative for a negative dividend; the
-- djb2 i64 accumulator can wrap negative).
export
posMod : Int -> Int -> Int
posMod n m = (n % m + m) % m

-- ── decl rewrite (rename both the DEFINITION name and all references) ─────────
renameDecl : OrdMap String -> Decl -> Decl
renameDecl rm (DFunDef pub n ps e site bid) =
  DFunDef
    pub
    (renameDefName rm n)
    (renamePatsPM rm ps)
    (renameScoped rm (boundOfListPM (patVarsListPM ps)) e)
    site
    bid
-- a top-level signature (`f : …` / `export f : …`) shares the function's name; it
-- MUST be renamed in lockstep with its DFunDef so the typechecker keys f's scheme
-- under the SAME mangled name the call sites + def now use (else dictPass /
-- the exported-name facet see `clampU` while the def is `<mid>__clampU` → unbound).
renameDecl rm (DTypeSig pub n ty site) =
  DTypeSig pub (renameDefName rm n) ty site
renameDecl rm (d@(DInterface { methods, ... })) =
  DInterface { d | methods = map (renameIfaceMethod rm) methods }
renameDecl rm (d@(DImpl { methods, ... })) =
  DImpl { d | methods = map (renameImplMethod rm) methods }
renameDecl rm (DProp pub name params body) =
  DProp
    pub
    name
    params
    (renameScoped rm (boundOfListPM (propParamNamesPM params)) body)
renameDecl rm (DTest pub name body) =
  DTest pub name (renameScoped rm omEmpty body)
renameDecl rm (DLetGroup pub binds) =
  DLetGroup pub (map (renameLetBindDef rm) binds)
-- DATA / NEWTYPE definition sites: rename the constructor names (which the
-- emitter's ctor tables key on) in lockstep with the use-site rewrites below.  The
-- DData TYPE name is left as-is (it is only the VALUE in buildCtorToType — ctorsOf-
-- Type groups by it but never emits it as a symbol); a record (the `data X = { … }`
-- short form) is a ConNamed variant renamed like any ctor; a DNewtype's con is its
-- ctor.  Reserved ctors are not in `rm`
-- (excluded at export), so renameDefName leaves them unchanged.
-- #1110: record UPDATE, so an already-acquired origin survives the rename.
renameDecl rm (d@(DData { dataCtors = variants })) =
  DData { d | dataCtors = map (renameVariant rm) variants }
renameDecl rm (d@(DNewtype { newtypeCtor = con })) =
  DNewtype { d | newtypeCtor = renameDefName rm con }
renameDecl rm (DAttrib attrs d) = DAttrib attrs (renameDecl rm d)
-- An extern's declaration takes the name its references do (`externSymbolName`):
-- the emitters read its foreign-call row from the declaration, under that name.
renameDecl rm (DExtern ed) =
  DExtern ({ ed | edName = renameDefName rm ed.edName })
-- ── LEAVES, AS AN EXPLICIT LIST ───────────────────────────────────────────────
-- Not a `_ => d` catch-all, for the reason `renameScoped`'s leaf list gives: a new
-- name-carrying `Decl` constructor would be a SILENT leaf ([T-GLOBAL-TABLE]).  Listed,
-- it is a compile error instead.  Derive the audit rather than trusting a count:
--   `grep -n '^  | D' compiler/frontend/ast.mdk` minus its five `Do*` rows (`DoStmt`,
--   a different type) is the constructor total, and every one of them appears exactly
--   once either above or here.
--   * `DUse` is an import FORM; its module path and member names are resolved before
--     this pass and the rename is import-aware through `rm` at the reference sites.
--   * `DEffect` names an effect, which is neither a value nor a constructor.
--   * `DTypeAlias` names a TYPE.  `renameDecl`'s `DData` arm renames `dataCtors` and
--     leaves `dataName` alone for the same reason — an alias arm here would rename half
--     of that split.
renameDecl _ (d@(DUse _ _ _)) = d
renameDecl _ (d@(DEffect _ _ _ _ _ _)) = d
renameDecl _ (d@(DTypeAlias { tyAliasName = _, ... })) = d

-- rename a data variant's constructor name (payload types are unaffected).
renameVariant : OrdMap String -> Variant -> Variant
renameVariant rm (Variant n payload) = Variant (renameDefName rm n) payload

-- top-level LetBind in a DLetGroup: rename the binder name (if in map) AND its
-- clause bodies.  The group's own names are in scope across all clauses.
renameLetBindDef : OrdMap String -> LetBind -> LetBind
renameLetBindDef rm (LetBind n clauses site bid) =
  LetBind
    (renameDefName rm n)
    (map (renameFunClause rm omEmpty) clauses)
    site
    bid

renameDefName : OrdMap String -> String -> String
renameDefName rm n = optionOr n (omLookup n rm)

renameIfaceMethod : OrdMap String -> IfaceMethod -> IfaceMethod
renameIfaceMethod _ (IfaceMethod n ty None mloc) = IfaceMethod n ty None mloc
renameIfaceMethod rm (IfaceMethod n ty (Some (MethodDefault ps e)) mloc) =
  IfaceMethod
    n
    ty
    (Some
      (MethodDefault
        (renamePatsPM rm ps)
        (renameScoped rm (boundOfListPM (patVarsListPM ps)) e)))
    mloc

renameImplMethod : OrdMap String -> ImplMethod -> ImplMethod
renameImplMethod rm (ImplMethod n ps e) =
  ImplMethod
    n
    (renamePatsPM rm ps)
    (renameScoped rm (boundOfListPM (patVarsListPM ps)) e)

propParamNamesPM : List PropParam -> List String
propParamNamesPM ps = map propParamNamePM ps

propParamNamePM : PropParam -> String
propParamNamePM (PropParam n _ _) = n

-- #1031: `bound` is an OrdMap-backed SET (name -> ()), not a `List String`
-- scanned by `contains` — see typecheck.mdk's `boundInsert`/`boundOfList`, which
-- this mirrors exactly (a private copy, per this file's own PM-suffix naming
-- convention for its scope helpers).
boundInsertPM : List String -> OrdMap Unit -> OrdMap Unit
boundInsertPM [] b = b
boundInsertPM (n :: rest) b = boundInsertPM rest (omInsert n () b)

boundOfListPM : List String -> OrdMap Unit
boundOfListPM ns = boundInsertPM ns omEmpty

-- ── the scope-threaded reference rewrite ──────────────────────────────────────
-- `bound` = names shadowed by a local binder at this node.  An EVar is renamed
-- only when it is in the map AND NOT shadowed.  Binders extend `bound`.  Mirrors
-- typecheck.mdk's rewriteArgScoped exactly.
renameScoped : OrdMap String -> OrdMap Unit -> Expr -> Expr
renameScoped rm bound (EVar n)
  | not (omHasKey n bound) = match omLookup n rm
    Some n2 => EVar n2
    None => EVar n
  | otherwise = EVar n
-- #837: strip the resolve-only binding-id tag, renaming exactly as bare EVar.
renameScoped rm bound (EVarId n _)
  | not (omHasKey n bound) = match omLookup n rm
    Some n2 => EVar n2
    None => EVar n
  | otherwise = EVar n
-- #1292: `EVarAt` is NOT a leaf for the eval-side entry point.  `mangleUnits` runs
-- PRE-annotate on the emit path, so this arm is dead there — but
-- `mangleCtorCollisions` runs on trees `types/annotate.annotateProgram` has already
-- rewritten `EVar n` -> `EVarAt n addr` (`entries/core_ir_modules_main.mdk`
-- annotates every module before `cevalModules`), and BOTH consumers still look the
-- name up BY NAME (`eval.eval (EVarAt x addr)` falls through to `lookupAtAddr x`;
-- `core_ir_lower.lower (EVarAt x addr) = CVar x addr` and `core_ir_eval.ceval
-- (CVar x _) = lookupEnv env x`).  Leaving the name un-renamed here would leave a
-- constructor reference pointing at a cell the rename has moved.  The ADDRESS is
-- preserved: renaming a binding changes no frame's composition or ordering.
renameScoped rm bound (EVarAt n addr)
  | not (omHasKey n bound) = match omLookup n rm
    Some n2 => EVarAt n2 addr
    None => EVarAt n addr
  | otherwise = EVarAt n addr
-- binders
renameScoped rm bound (ELam ps body) =
  ELam
    (renamePatsPM rm ps)
    (renameScoped rm (boundInsertPM (patVarsListPM ps) bound) body)
renameScoped rm bound (ELet m r p e1 e2) =
  let pv = patVarsPM p
  let b1 = if r then boundInsertPM pv bound else bound
  ELet
    m
    r
    (renamePat rm p)
    (renameScoped rm b1 e1)
    (renameScoped rm (boundInsertPM pv bound) e2)
renameScoped rm bound (ELetGroup binds e2) =
  let bnd = boundInsertPM (letBindNamesPM binds) bound
  ELetGroup (map (renameLetBind rm bnd) binds) (renameScoped rm bnd e2)
renameScoped rm bound (EMatch e0 arms) =
  EMatch (renameScoped rm bound e0) (map (renameArm rm bound) arms)
renameScoped rm bound (EBlock stmts) = EBlock (renameStmts rm bound stmts)
renameScoped rm bound (EDo d stmts) = EDo d (renameStmts rm bound stmts)
-- non-binder composites: recurse children with the same bound
renameScoped rm bound (ELoc l e) = ELoc l (renameScoped rm bound e)
renameScoped rm bound (EDoOrigin l e) = EDoOrigin l (renameScoped rm bound e)
renameScoped rm bound (EApp f x) =
  EApp (renameScoped rm bound f) (renameScoped rm bound x)
renameScoped rm bound (EIf c t e) =
  EIf
    (renameScoped rm bound c)
    (renameScoped rm bound t)
    (renameScoped rm bound e)
renameScoped rm bound (EBinOp op l r dr) =
  EBinOp op (renameScoped rm bound l) (renameScoped rm bound r) dr
renameScoped rm bound (EUnOp op x dr) = EUnOp op (renameScoped rm bound x) dr
renameScoped rm bound (EInfix op l r) =
  EInfix op (renameScoped rm bound l) (renameScoped rm bound r)
-- The record-head site id is passed through, not renamed.
-- `typecheck.inferFieldAccess` publishes under this id the resolved record's
-- owner-qualified name (`stampedRecordHead`, derived from the record's own declaring
-- module), which is already the spelling this pass gives that record's `DData`.  A
-- `renameDefName` on top would qualify it a second time whenever the importing
-- unit's map happens to hold the stamped string as a key -- which it does exactly when
-- a record's source name already carries its own module's prefix (`data Mm__Cfg`
-- beside `data Cfg` in module `Mm`): measured, the two collapsed onto one head and the
-- built binary projected the wrong slot at exit 0, on a program the parent commit
-- refused outright.  One qualifier, at the stamp.
renameScoped rm bound (EFieldAccess e0 n ev) =
  EFieldAccess (renameScoped rm bound e0) n ev
renameScoped rm bound (ETuple es) = ETuple (map (renameScoped rm bound) es)
renameScoped rm bound (EListLit es) = EListLit (map (renameScoped rm bound) es)
renameScoped rm bound (EArrayLit es) =
  EArrayLit (map (renameScoped rm bound) es)
renameScoped rm bound (ERangeList lo hi i) =
  ERangeList (renameScoped rm bound lo) (renameScoped rm bound hi) i
renameScoped rm bound (ERangeArray lo hi i) =
  ERangeArray (renameScoped rm bound lo) (renameScoped rm bound hi) i
renameScoped rm bound (ESlice e0 lo hi i) =
  ESlice
    (renameScoped rm bound e0)
    (renameScoped rm bound lo)
    (renameScoped rm bound hi)
    i
renameScoped rm bound (EIndex e0 i) =
  EIndex (renameScoped rm bound e0) (renameScoped rm bound i)
renameScoped rm bound (EAnnot e0 t) = EAnnot (renameScoped rm bound e0) t
renameScoped rm bound (EHeadAnnot e0 t) =
  EHeadAnnot (renameScoped rm bound e0) t
renameScoped rm bound (ERecordCreate n fs) =
  ERecordCreate (renameDefName rm n) (map (renameField rm bound) fs)
-- the receiver's resolved record name, published by `inferRecordUpdate` under this id
-- and passed through for the same reason -- see `EFieldAccess` above.
renameScoped rm bound (ERecordUpdate e0 fs ev) =
  ERecordUpdate (renameScoped rm bound e0) (map (renameField rm bound) fs) ev
renameScoped rm bound (EVariantUpdate c e0 fs) =
  EVariantUpdate
    (renameDefName rm c)
    (renameScoped rm bound e0)
    (map (renameField rm bound) fs)
renameScoped rm bound (EStringInterp parts) =
  EStringInterp (map (renameInterp rm bound) parts)
renameScoped rm bound (EGuards arms) =
  EGuards (map (renameGuardArm rm bound) arms)
renameScoped rm bound (ESection (SecRight op e0)) =
  ESection (SecRight op (renameScoped rm bound e0))
renameScoped rm bound (ESection (SecLeft e0 op)) =
  ESection (SecLeft (renameScoped rm bound e0) op)
renameScoped rm bound (EMapLit n kvs) = EMapLit n (map (renameKv rm bound) kvs)
renameScoped rm bound (ESetLit n es) =
  ESetLit n (map (renameScoped rm bound) es)
renameScoped rm bound (EAsPat x sub) = EAsPat x (renameScoped rm bound sub)
renameScoped rm bound (EOrPat es) = EOrPat (map (renameScoped rm bound) es)
-- ── ELABORATED-TREE ARMS (#2809) ──────────────────────────────────────────────
-- These two nodes exist only in a tree `elaborateModules` has already produced, so they
-- were unreachable while the mangler ran FIRST -- and each carries a TOP-LEVEL FUNCTION
-- name the rename map must move.
--   * `EDictAt f ev` names the constrained function whose dict the caller supplies;
--     leaving it bare emits a `CDict` head no `DFunDef` defines (measured: `E-PANIC:
--     CDict head 'debugListItems' is not a known top-level function`).
--   * `EMethodAt m seed ev`'s SECOND field is the shadowing standalone's symbol (see
--     `EMethodAt` in `frontend/ast.mdk`), which `marker.collectVars` reports to
--     `dce.declRefs` as a reference; the FIRST field is an interface METHOD name, which
--     this pass never renames.  `""` is the sentinel for "no standalone", not a name.
renameScoped rm bound (EDictAt n ev)
  | omHasKey n bound = EDictAt n ev
  | otherwise = EDictAt (renameDefName rm n) ev
renameScoped rm _ (EMethodAt m seed ev) = EMethodAt m (renameDefName rm seed) ev
-- ── LEAVES, AS AN EXPLICIT LIST ───────────────────────────────────────────────
-- Not a `_ => e` catch-all: this pass now consumes elaborated trees, so a new `Expr`
-- constructor carrying a name would be a SILENT leaf ([T-GLOBAL-TABLE]).  Listed, it is a
-- compile error instead.  Derive the audit rather than trusting a count:
--   `grep -c '^  | E' compiler/frontend/ast.mdk` minus its three `Ev*` evidence rows is
--   the constructor total, and every one of them appears exactly once either above or
--   here (`grep -o '(E[A-Za-z]*' on this function's arms).
--   * `ELit` carries no name.  `ENumLit`'s fourth field is the source LEXEME, and
--     `dictPass` rewrites every `ENumLit` away before emit sees one.
--   * `EMethodRef` / `EDictApp` are minted by `frontend/marker.mdk` alone, which no
--     production verb runs ([P-NO-MARK-PASS]); a driver that ever pre-marks an emit
--     tree must rename `EDictApp`'s name the way `EDictAt` is renamed above.
--   * `SecBare`'s operator is not a top-level binding, and `desugar` removes every
--     `ESection` before elaboration.
-- `EVarAt` is handled above, not here: it carries a renameable NAME (see its arm).
renameScoped _ _ (e@(ELit _)) = e
renameScoped _ _ (e@(ENumLit _ _ _)) = e
renameScoped _ _ (e@(EWideLit _ _ _ _)) = e
renameScoped _ _ (e@(EMethodRef _)) = e
renameScoped _ _ (e@(EDictApp _)) = e
renameScoped _ _ (e@(ESection (SecBare _))) = e

renameField : OrdMap String -> OrdMap Unit -> FieldAssign -> FieldAssign
renameField rm bound (FieldAssign n e) = FieldAssign n (renameScoped rm bound e)

renameKv : OrdMap String -> OrdMap Unit -> (Expr, Expr) -> (Expr, Expr)
renameKv rm bound (k, v) = (renameScoped rm bound k, renameScoped rm bound v)

renameInterp : OrdMap String -> OrdMap Unit -> InterpPart -> InterpPart
renameInterp _ _ (InterpStr s) = InterpStr s
renameInterp rm bound (InterpExpr e) = InterpExpr (renameScoped rm bound e)

-- A local group's binder is not the module's definition of that name, whatever
-- the rename map says: its uses in scope are left alone (`bound`), so renaming
-- the binder would point every use at the module-level definition (#3519:
-- `where result = 5` bound as the prelude's `core__result`).
renameLetBind : OrdMap String -> OrdMap Unit -> LetBind -> LetBind
renameLetBind rm bound (LetBind n clauses site bid) =
  LetBind n (map (renameFunClause rm bound) clauses) site bid

renameFunClause : OrdMap String -> OrdMap Unit -> FunClause -> FunClause
renameFunClause rm bound (FunClause ps body) =
  FunClause
    (renamePatsPM rm ps)
    (renameScoped rm (boundInsertPM (patVarsListPM ps) bound) body)

renameArm : OrdMap String -> OrdMap Unit -> Arm -> Arm
renameArm rm bound (Arm p gs body) =
  let b0 = boundInsertPM (patVarsPM p) bound
  let (gs2, bnd) = renameGuards rm b0 gs
  Arm (renamePat rm p) gs2 (renameScoped rm bnd body)

renameGuardArm : OrdMap String -> OrdMap Unit -> GuardArm -> GuardArm
renameGuardArm rm bound (GuardArm gs body) =
  let (gs2, bnd) = renameGuards rm bound gs
  GuardArm gs2 (renameScoped rm bnd body)

renameGuards : OrdMap String ->
  OrdMap Unit ->
  List Guard ->
  (List Guard, OrdMap Unit)
renameGuards _ bound [] = ([], bound)
renameGuards rm bound ((GBool e) :: rest) =
  let e2 = renameScoped rm bound e
  let (rest2, bnd) = renameGuards rm bound rest
  (GBool e2 :: rest2, bnd)
renameGuards rm bound ((GBind p e) :: rest) =
  let e2 = renameScoped rm bound e
  let (rest2, bnd) = renameGuards rm (boundInsertPM (patVarsPM p) bound) rest
  (GBind (renamePat rm p) e2 :: rest2, bnd)

renameStmts : OrdMap String -> OrdMap Unit -> List DoStmt -> List DoStmt
renameStmts _ _ [] = []
renameStmts rm bound ((DoExpr e) :: rest) =
  DoExpr (renameScoped rm bound e) :: renameStmts rm bound rest
renameStmts rm bound ((DoBind p e) :: rest) =
  DoBind (renamePat rm p) (renameScoped rm bound e)
    :: renameStmts rm (boundInsertPM (patVarsPM p) bound) rest
renameStmts rm bound ((DoLet m r p e site) :: rest) =
  let b1 = if r then boundInsertPM (patVarsPM p) bound else bound
  DoLet m r (renamePat rm p) (renameScoped rm b1 e) site
    :: renameStmts rm (boundInsertPM (patVarsPM p) bound) rest
renameStmts rm bound ((DoAssign x e) :: rest) =
  DoAssign x (renameScoped rm bound e) :: renameStmts rm bound rest
renameStmts rm bound ((DoFieldAssign x fs e) :: rest) =
  DoFieldAssign x fs (renameScoped rm bound e) :: renameStmts rm bound rest

letBindNamesPM : List LetBind -> List String
letBindNamesPM binds = map letBindName binds

-- ── pattern variables (local copy; covers PRec field/pun binders) ─────────────
patVarsPM : Pat -> List String
patVarsPM (PVar x _ _) = [x]
patVarsPM (PCon _ args) = patVarsListPM args
patVarsPM (PCons h t) = patVarsPM h ++ patVarsPM t
patVarsPM (PTuple ps) = patVarsListPM ps
patVarsPM (PList ps) = patVarsListPM ps
patVarsPM (PAs x _ _ p) = x :: patVarsPM p
patVarsPM (POr (p :: _)) = patVarsPM p
patVarsPM (PRec _ fields _) = flatMap recPatFieldVarsPM fields
patVarsPM _ = []

patVarsListPM : List Pat -> List String
patVarsListPM ps = flatMap patVarsPM ps

-- ── pattern CONSTRUCTOR rewrite ───────────────────────────────────────────────
-- Rewrite the constructor name of every PCon / PRec in a pattern to its mangled
-- form (reserved ctors are not in `rm`, so renameDefName leaves them).  Pattern
-- VARIABLE binders are untouched — they are lowercase value names, never in the
-- ctor/fn map.  Recurses through all sub-patterns so nested ctors are rewritten.
renamePat : OrdMap String -> Pat -> Pat
renamePat rm (PCon n args) = PCon (renameDefName rm n) (map (renamePat rm) args)
renamePat rm (PCons h t) = PCons (renamePat rm h) (renamePat rm t)
renamePat rm (PTuple ps) = PTuple (map (renamePat rm) ps)
renamePat rm (PList ps) = PList (map (renamePat rm) ps)
renamePat rm (PAs x l bid p) = PAs x l bid (renamePat rm p)
renamePat rm (POr ps) = POr (map (renamePat rm) ps)
renamePat rm (PRec n fields open) =
  PRec (renameDefName rm n) (map (renameRecPatField rm) fields) open
-- ── LEAVES, AS AN EXPLICIT LIST ───────────────────────────────────────────────
-- Not a `_ => p` catch-all, for the reason `renameScoped`'s leaf list gives: a new
-- name-carrying `Pat` constructor would be a SILENT leaf ([T-GLOBAL-TABLE]), and a
-- pattern that fails to rename its constructor binds nothing at run time.  Listed, it
-- is a compile error instead.  Derive the audit rather than trusting a count:
--   `grep -n '^  | P' compiler/frontend/ast.mdk` is the constructor total, and every
--   one of them appears exactly once either above or here.
--   * `PVar` / `PAs`' binder are lowercase VALUE binders, never in the ctor/fn map.
--   * `PWild` binds nothing.
--   * `PLit` / `PRng` carry `Lit`s, which name nothing renameable.
renamePat _ (p@(PVar _ _ _)) = p
renamePat _ (p@PWild) = p
renamePat _ (p@(PLit _)) = p
renamePat _ (p@(PRng _ _ _)) = p

renameRecPatField : OrdMap String -> RecPatField -> RecPatField
renameRecPatField _ (RecPatField label l bid None) =
  RecPatField label l bid None
renameRecPatField rm (RecPatField label l bid (Some p)) =
  RecPatField label l bid (Some (renamePat rm p))

renamePatsPM : OrdMap String -> List Pat -> List Pat
renamePatsPM rm ps = map (renamePat rm) ps

recPatFieldVarsPM : RecPatField -> List String
recPatFieldVarsPM (RecPatField label _ _ None) = [label]
recPatFieldVarsPM (RecPatField _ _ _ (Some p)) = patVarsPM p
# DESUGAR
(DUse false (UseGroup ("frontend" "runtime_constructors") ((mem "namedRuntimeCtor" false))))
(DUse false (UseGroup ("support" "symbol_encoding") ((mem "encodePair" false))))
(DUse false (UseGroup ("types" "symbol_origins") ((mem "SymbolOrigins" false) (mem "emptyOrigins" false) (mem "unitOrigins" false) (mem "mergeOrigins" false))))
(DUse false (UseGroup ("types" "extern_source") ((mem "sourceExternSymbol" false) (mem "externDisplayName" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "letBindName" false) (mem "declBinderNames" false) (mem "Decl" true) (mem "ExternDecl" true) (mem "Expr" true) (mem "Pat" true) (mem "Arm" true) (mem "Guard" true) (mem "GuardArm" true) (mem "DoStmt" true) (mem "Section" true) (mem "InterpPart" true) (mem "FieldAssign" true) (mem "RecPatField" true) (mem "LetBind" true) (mem "FunClause" true) (mem "IfaceMethod" true) (mem "MethodDefault" true) (mem "ImplMethod" true) (mem "PropParam" true) (mem "UsePath" true) (mem "UseMember" true) (mem "useMemberOrigin" false) (mem "useMemberLocal" false) (mem "useMemberAlias" false) (mem "qualifiedLocal" false) (mem "Variant" true) (mem "DataVis" true) (mem "Route" true) (mem "EvVal" true) (mem "EvEntry" true) (mem "EvId" true) (mem "EvTable" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "SiblingPair" true))))
(DUse false (UseGroup ("frontend" "visibility") ((mem "ModuleExports" true) (mem "useModId" false) (mem "coreExports" false) (mem "buildExportsWith" false) (mem "pubIfaceMethodSets" false) (mem "ExportView" true) (mem "viewOf" false) (mem "fullExportsOf" false) (mem "directUnder" false) (mem "filterInSet" false) (mem "nsValues" false) (mem "valueDeclsOf" false) (mem "valueDeclOf" false) (mem "typeOfCtor" false))))
(DUse false (UseAlias ("u64") "U64"))
(DUse false (UseGroup ("list") ((mem "last" false) (mem "zip" false))))
(DUse false (UseGroup ("map") ((mem "insertWith" false))))
(DUse false (UseGroup ("support" "util") ((mem "lookupAssoc" false) (mem "contains" false) (mem "reverseL" false) (mem "isEmptyL" false) (mem "filterList" false) (mem "dedup" false) (mem "dedupBy" false) (mem "lenKey" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omInsert" false) (mem "omLookup" false) (mem "omKeys" false) (mem "omFromPairs" false) (mem "omFromNames" false) (mem "omHasKey" false) (mem "omEmpty" false) (mem "omSize" false))))
(DTypeSig true "mangleUnits" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))))))
(DFunDef false "mangleUnits" ((PVar "coreDecls") (PVar "modules")) (EBlock (DoLet false false (PTuple (PVar "coreOut") (PVar "modsOut") PWild) (EApp (EApp (EVar "mangleUnitsWithOrigins") (EVar "coreDecls")) (EVar "modules"))) (DoExpr (ETuple (EVar "coreOut") (EVar "modsOut")))))
(DTypeSig true "scopeUnitNames" (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))))))
(DFunDef false "scopeUnitNames" ((PCon "None") (PVar "coreDecls") (PVar "modules")) (EApp (EApp (EApp (EApp (EVar "renameUnits") (EVar "scopedExternName")) (EListLit)) (EVar "coreDecls")) (EVar "modules")))
(DFunDef false "scopeUnitNames" ((PCon "Some" (PTuple (PVar "mid") (PVar "decls"))) (PVar "coreDecls") (PVar "modules")) (EApp (EApp (EApp (EApp (EVar "renameUnits") (EVar "scopedExternName")) (EApp (EApp (EVar "map") (ELam ((PVar "n")) (ETuple (EVar "n") (EVar "mid")))) (EApp (EVar "externDeclNames") (EVar "decls")))) (EVar "coreDecls")) (EBinOp "::" (ETuple (EVar "mid") (EVar "decls")) (EVar "modules"))))
(DTypeSig false "scopedExternName" (TyFun (TyCon "String") (TyFun (TyCon "ExternDecl") (TyCon "String"))))
(DFunDef false "scopedExternName" ((PVar "mid") (PVar "ed")) (EApp (EApp (EVar "mangledName") (EVar "mid")) (EFieldAccess (EVar "ed") "edName")))
(DTypeSig false "externDeclNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "externDeclNames" ((PVar "decls")) (EApp (EApp (EVar "map") (EVar "fst")) (EApp (EApp (EVar "externDeclEntries") (ELam ((PVar "ed")) (EFieldAccess (EVar "ed") "edName"))) (EVar "decls"))))
(DTypeSig false "renameUnits" (TyFun (TyFun (TyCon "String") (TyFun (TyCon "ExternDecl") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))))))))
(DFunDef false "renameUnits" ((PVar "externName") (PVar "implicit") (PVar "coreDecls") (PVar "modules")) (EBlock (DoLet false false (PVar "allUnits") (EBinOp "::" (ETuple (ELit (LString "core")) (EVar "coreDecls")) (EVar "modules"))) (DoLet false false (PVar "entryMid") (EApp (EVar "entryUnitMid") (EVar "allUnits"))) (DoLet false false (PVar "surfaces") (EApp (EVar "unitSurfaces") (EVar "allUnits"))) (DoLet false false (PVar "exportsPerUnit") (EApp (EApp (EApp (EVar "withPreludeDefs") (EApp (EVar "dedup") (EApp (EVar "unitDefNames") (ETuple (ELit (LString "")) (EVar "coreDecls"))))) (EVar "implicit")) (EApp (EApp (EApp (EVar "fnExportsFrom") (ELam (PWild) (EVar "ExportedView"))) (EVar "allUnits")) (EVar "surfaces")))) (DoLet false false (PVar "ctorExportsPerUnit") (EApp (EVar "ctorExportsFrom") (EVar "surfaces"))) (DoLet false false (PVar "externExports") (EApp (EApp (EApp (EVar "externExportsFrom") (EVar "externName")) (EVar "allUnits")) (EVar "surfaces"))) (DoLet false false (PVar "coreOut") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mangleUnitU") (EVar "entryMid")) (EVar "exportsPerUnit")) (EVar "ctorExportsPerUnit")) (EVar "externName")) (EVar "externExports")) (ETuple (ELit (LString "core")) (EVar "coreDecls")))) (DoLet false false (PVar "modsOut") (EApp (EApp (EVar "map") (EApp (EApp (EApp (EApp (EApp (EVar "mangleModule") (EVar "entryMid")) (EVar "exportsPerUnit")) (EVar "ctorExportsPerUnit")) (EVar "externName")) (EVar "externExports"))) (EVar "modules"))) (DoExpr (ETuple (EVar "coreOut") (EVar "modsOut")))))
(DTypeSig false "entryUnitMid" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "String")))
(DFunDef false "entryUnitMid" ((PVar "units")) (EMatch (EApp (EVar "last") (EVar "units")) (arm (PCon "Some" (PTuple (PVar "mid") PWild)) () (EVar "mid")) (arm (PCon "None") () (ELit (LString "")))))
(DTypeSig true "mangleUnitsEv" (TyFun (TyCon "EvTable") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "EvTable") (TyCon "SymbolOrigins"))))))
(DFunDef false "mangleUnitsEv" () (EApp (EVar "mangleUnitsEvFor") (EListLit)))
(DTypeSig true "mangleUnitsEvFor" (TyFun (TyApp (TyCon "List") (TyCon "SiblingPair")) (TyFun (TyCon "EvTable") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "EvTable") (TyCon "SymbolOrigins")))))))
(DFunDef false "mangleUnitsEvFor" ((PVar "siblings") (PVar "table") (PVar "coreDecls") (PVar "modules")) (EBlock (DoLet false false (PVar "allUnits") (EBinOp "::" (ETuple (ELit (LString "core")) (EVar "coreDecls")) (EVar "modules"))) (DoLet false false (PVar "entryMid") (EApp (EVar "entryUnitMid") (EVar "allUnits"))) (DoLet false false (PVar "surfaces") (EApp (EVar "unitSurfaces") (EVar "allUnits"))) (DoLet false false (PVar "exportsPerUnit") (EApp (EApp (EApp (EApp (EVar "exportsPerUnitOf") (ELam (PWild) (EVar "ExportedView"))) (EVar "coreDecls")) (EVar "allUnits")) (EVar "surfaces"))) (DoLet false false (PVar "ctorExportsPerUnit") (EApp (EVar "ctorExportsFrom") (EVar "surfaces"))) (DoLet false false (PVar "externExports") (EApp (EApp (EApp (EVar "externExportsFrom") (EVar "externSymbolName")) (EVar "allUnits")) (EVar "surfaces"))) (DoLet false false (PVar "siblingMaps") (EApp (EApp (EVar "map") (EApp (EApp (EApp (EVar "siblingUnitMaps") (EVar "coreDecls")) (EVar "allUnits")) (EVar "surfaces"))) (EVar "siblings"))) (DoLet false false (PVar "units") (EApp (EApp (EVar "map") (EApp (EApp (EApp (EVar "unitEntryFor") (EVar "entryMid")) (EVar "siblingMaps")) (ETuple (EVar "exportsPerUnit") (EVar "ctorExportsPerUnit") (EVar "externExports")))) (EVar "allUnits"))) (DoLet false false (PVar "renamed") (EApp (EApp (EVar "map") (EVar "renameUnitEntry")) (EVar "units"))) (DoLet false false (PVar "coreOut") (EMatch (EVar "renamed") (arm (PList) () (EVar "coreDecls")) (arm (PCons (PTuple PWild (PVar "ds")) PWild) () (EVar "ds")))) (DoLet false false (PVar "modsOut") (EMatch (EVar "renamed") (arm (PList) () (EVar "modules")) (arm (PCons PWild (PVar "rest")) () (EVar "rest")))) (DoLet false false (PVar "remap") (EApp (EVar "mangleEvEntry") (EApp (EApp (EVar "omFromPairs") (EApp (EVar "reverseL") (EApp (EApp (EVar "map") (EVar "dropUnitDecls")) (EVar "units")))) (EVar "omEmpty")))) (DoLet false false (PVar "origins") (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PTuple (PVar "mid") (PTuple (PVar "rm") PWild (PVar "decls")))) (EApp (EApp (EVar "mergeOrigins") (EVar "acc")) (EApp (EApp (EApp (EVar "unitOrigins") (EVar "mid")) (EVar "rm")) (EVar "decls"))))) (EVar "emptyOrigins")) (EVar "units"))) (DoExpr (ETuple (EVar "coreOut") (EVar "modsOut") (EApp (EApp (EVar "map") (EVar "remap")) (EVar "table")) (EVar "origins")))))
(DTypeSig true "mangleUnitsWithOrigins" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "SymbolOrigins")))))
(DFunDef false "mangleUnitsWithOrigins" ((PVar "coreDecls") (PVar "modules")) (EBlock (DoLet false false (PTuple (PVar "coreOut") (PVar "modsOut") PWild (PVar "origins")) (EApp (EApp (EApp (EVar "mangleUnitsEv") (EListLit)) (EVar "coreDecls")) (EVar "modules"))) (DoExpr (ETuple (EVar "coreOut") (EVar "modsOut") (EVar "origins")))))
(DTypeAlias false "ExportMaps" () (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "String")))))
(DTypeSig false "exportsPerUnitOf" (TyFun (TyFun (TyCon "String") (TyCon "ExportView")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "ModuleExports"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))))))
(DFunDef false "exportsPerUnitOf" ((PVar "viewOfUnit") (PVar "coreDecls") (PVar "allUnits") (PVar "surfaces")) (EApp (EApp (EApp (EVar "withPreludeDefs") (EApp (EVar "dedup") (EApp (EVar "unitDefNames") (ETuple (ELit (LString "")) (EVar "coreDecls"))))) (EListLit)) (EApp (EApp (EApp (EVar "fnExportsFrom") (EVar "viewOfUnit")) (EVar "allUnits")) (EVar "surfaces"))))
(DTypeSig false "siblingUnitMaps" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "ModuleExports"))) (TyFun (TyCon "SiblingPair") (TyTuple (TyCon "String") (TyCon "ExportMaps")))))))
(DFunDef false "siblingUnitMaps" ((PVar "coreDecls") (PVar "allUnits") (PVar "surfaces") (PVar "pair")) (EBlock (DoLet false false (PVar "subj") (EFieldAccess (EVar "pair") "spSubject")) (DoLet false false (PVar "full") (EApp (EApp (EApp (EVar "fullSurfaces") (EVar "subj")) (EVar "allUnits")) (EVar "surfaces"))) (DoExpr (ETuple (EFieldAccess (EVar "pair") "spSibling") (ETuple (EApp (EApp (EApp (EApp (EVar "exportsPerUnitOf") (EApp (EVar "viewOf") (EApp (EVar "Some") (EVar "subj")))) (EVar "coreDecls")) (EVar "allUnits")) (EVar "full")) (EApp (EVar "ctorExportsFrom") (EVar "full")) (EApp (EApp (EApp (EVar "externExportsFrom") (EVar "externSymbolName")) (EVar "allUnits")) (EVar "full")))))))
(DTypeSig false "fullSurfaces" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "ModuleExports"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "ModuleExports")))))))
(DFunDef false "fullSurfaces" ((PVar "subj") (PVar "allUnits") (PVar "surfaces")) (EBlock (DoLet false false (PVar "coreExp") (EApp (EVar "coreExportsOf") (EVar "allUnits"))) (DoLet false false (PVar "known") (EApp (EApp (EVar "omFromPairs") (EApp (EVar "reverseL") (EVar "surfaces"))) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EVar "map") (EApp (EApp (EApp (EApp (EVar "fullSurfaceOf") (EVar "subj")) (EVar "coreExp")) (EVar "known")) (EVar "allUnits"))) (EVar "surfaces")))))
(DTypeSig false "fullSurfaceOf" (TyFun (TyCon "String") (TyFun (TyCon "ModuleExports") (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyTuple (TyCon "String") (TyCon "ModuleExports")) (TyTuple (TyCon "String") (TyCon "ModuleExports"))))))))
(DFunDef false "fullSurfaceOf" ((PVar "subj") (PVar "coreExp") (PVar "known") (PVar "allUnits") (PTuple (PVar "mid") (PVar "exp"))) (EIf (EBinOp "==" (EVar "mid") (EVar "subj")) (ETuple (EVar "mid") (EApp (EApp (EVar "optionOr") (EVar "exp")) (EApp (EApp (EVar "map") (ELam ((PVar "decls")) (EApp (EApp (EApp (EApp (EVar "fullExportsOf") (EVar "coreExp")) (EVar "known")) (EVar "mid")) (EVar "decls")))) (EApp (EApp (EVar "lookupAssoc") (EVar "mid")) (EVar "allUnits"))))) (ETuple (EVar "mid") (EVar "exp"))))
(DTypeSig false "unitEntryFor" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "ExportMaps"))) (TyFun (TyCon "ExportMaps") (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "OrdMap") (TyCon "String")) (TyCon "Bool") (TyApp (TyCon "List") (TyCon "Decl")))))))))
(DFunDef false "unitEntryFor" ((PVar "entryMid") (PVar "siblingMaps") (PVar "exported") (PTuple (PVar "mid") (PVar "decls"))) (EBlock (DoLet false false (PTuple (PVar "fns") (PVar "ctors") (PVar "externs")) (EApp (EApp (EVar "optionOr") (EVar "exported")) (EApp (EApp (EVar "lookupAssoc") (EVar "mid")) (EVar "siblingMaps")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "unitRenameMapEntry") (EVar "entryMid")) (EVar "fns")) (EVar "ctors")) (EVar "externs")) (ETuple (EVar "mid") (EVar "decls"))))))
(DTypeSig false "unitRenameMapEntry" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "String"))) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "OrdMap") (TyCon "String")) (TyCon "Bool") (TyApp (TyCon "List") (TyCon "Decl"))))))))))
(DFunDef false "unitRenameMapEntry" ((PVar "entryMid") (PVar "exportsPerUnit") (PVar "ctorExportsPerUnit") (PVar "externExports") (PTuple (PVar "mid") (PVar "decls"))) (EBlock (DoLet false false (PVar "rmList") (EBinOp "++" (EApp (EApp (EApp (EApp (EApp (EApp (EVar "buildUnitRenameMap") (EVar "entryMid")) (EVar "mid")) (EVar "exportsPerUnit")) (EVar "externSymbolName")) (EVar "externExports")) (EVar "decls")) (EApp (EApp (EApp (EVar "buildUnitCtorRenameMap") (EVar "mid")) (EVar "ctorExportsPerUnit")) (EVar "decls")))) (DoExpr (ETuple (EVar "mid") (ETuple (EApp (EApp (EVar "omFromPairs") (EApp (EVar "reverseL") (EVar "rmList"))) (EVar "omEmpty")) (EApp (EVar "isEmptyL") (EVar "rmList")) (EVar "decls"))))))
(DTypeSig false "renameUnitEntry" (TyFun (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "OrdMap") (TyCon "String")) (TyCon "Bool") (TyApp (TyCon "List") (TyCon "Decl")))) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "renameUnitEntry" ((PTuple (PVar "mid") (PTuple (PVar "rm") (PVar "noEntries") (PVar "decls")))) (ETuple (EVar "mid") (EIf (EVar "noEntries") (EVar "decls") (EApp (EApp (EVar "map") (EApp (EVar "renameDecl") (EVar "rm"))) (EVar "decls")))))
(DTypeSig false "dropUnitDecls" (TyFun (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "OrdMap") (TyCon "String")) (TyCon "Bool") (TyApp (TyCon "List") (TyCon "Decl")))) (TyTuple (TyCon "String") (TyApp (TyCon "OrdMap") (TyCon "String")))))
(DFunDef false "dropUnitDecls" ((PTuple (PVar "mid") (PTuple (PVar "rm") PWild PWild))) (ETuple (EVar "mid") (EVar "rm")))
(DTypeSig false "mangleEvEntry" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "String"))) (TyFun (TyCon "EvEntry") (TyCon "EvEntry"))))
(DFunDef false "mangleEvEntry" ((PVar "maps") (PCon "EvEntry" (PCon "EvId" (PVar "m") (PVar "i")) (PVar "v"))) (EMatch (EApp (EApp (EVar "omLookup") (EVar "m")) (EVar "maps")) (arm (PCon "None") () (EApp (EApp (EVar "EvEntry") (EApp (EApp (EVar "EvId") (EVar "m")) (EVar "i"))) (EVar "v"))) (arm (PCon "Some" (PVar "rm")) () (EApp (EApp (EVar "EvEntry") (EApp (EApp (EVar "EvId") (EVar "m")) (EVar "i"))) (EApp (EApp (EVar "mangleEvVal") (EVar "rm")) (EVar "v"))))))
(DTypeSig false "mangleEvVal" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "EvVal") (TyCon "EvVal"))))
(DFunDef false "mangleEvVal" ((PVar "rm") (PCon "EvOne" (PVar "r"))) (EApp (EVar "EvOne") (EApp (EApp (EVar "mangleRoute") (EVar "rm")) (EVar "r"))))
(DFunDef false "mangleEvVal" ((PVar "rm") (PCon "EvMany" (PVar "rs"))) (EApp (EVar "EvMany") (EApp (EApp (EVar "map") (EApp (EVar "mangleRoute") (EVar "rm"))) (EVar "rs"))))
(DFunDef false "mangleEvVal" ((PVar "rm") (PCon "EvMethod" (PVar "iface") (PVar "arity") (PVar "r") (PVar "reqs") (PVar "mds"))) (EApp (EApp (EApp (EApp (EApp (EVar "EvMethod") (EVar "iface")) (EVar "arity")) (EApp (EApp (EVar "mangleRoute") (EVar "rm")) (EVar "r"))) (EApp (EApp (EVar "map") (EApp (EVar "mangleRoute") (EVar "rm"))) (EVar "reqs"))) (EApp (EApp (EVar "map") (EApp (EVar "mangleRoute") (EVar "rm"))) (EVar "mds"))))
(DFunDef false "mangleEvVal" ((PVar "rm") (PCon "EvLit" (PVar "f") (PVar "r"))) (EApp (EApp (EVar "EvLit") (EVar "f")) (EApp (EApp (EVar "mangleRoute") (EVar "rm")) (EVar "r"))))
(DFunDef false "mangleEvVal" (PWild (PCon "EvHead" (PVar "h"))) (EApp (EVar "EvHead") (EVar "h")))
(DTypeSig false "mangleRoute" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "Route") (TyCon "Route"))))
(DFunDef false "mangleRoute" ((PVar "rm") (PCon "RLocal" (PVar "sym") (PVar "ds"))) (EApp (EApp (EVar "RLocal") (EApp (EApp (EVar "renameDefName") (EVar "rm")) (EVar "sym"))) (EApp (EApp (EVar "map") (EApp (EVar "mangleRoute") (EVar "rm"))) (EVar "ds"))))
(DFunDef false "mangleRoute" ((PVar "rm") (PCon "RKey" (PVar "k") (PVar "ds") (PVar "sups"))) (EApp (EApp (EApp (EVar "RKey") (EVar "k")) (EApp (EApp (EVar "map") (EApp (EVar "mangleRoute") (EVar "rm"))) (EVar "ds"))) (EApp (EApp (EVar "map") (EApp (EVar "mangleRoute") (EVar "rm"))) (EVar "sups"))))
(DFunDef false "mangleRoute" ((PVar "rm") (PCon "RProj" (PVar "r") (PVar "path"))) (EApp (EApp (EVar "RProj") (EApp (EApp (EVar "mangleRoute") (EVar "rm")) (EVar "r"))) (EVar "path")))
(DFunDef false "mangleRoute" (PWild (PAs "r" (PCon "RNone"))) (EVar "r"))
(DFunDef false "mangleRoute" (PWild (PAs "r" (PCon "RDict" PWild))) (EVar "r"))
(DFunDef false "mangleRoute" (PWild (PAs "r" (PCon "RDictFwd" PWild))) (EVar "r"))
(DFunDef false "mangleRoute" (PWild (PAs "r" (PCon "RScalar" PWild))) (EVar "r"))
(DTypeSig true "mangleCtorCollisions" (TyFun (TyApp (TyCon "List") (TyCon "SiblingPair")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))))))
(DFunDef false "mangleCtorCollisions" ((PVar "siblings") (PVar "coreDecls") (PVar "modules")) (EBlock (DoLet false false (PVar "allUnits") (EBinOp "::" (ETuple (ELit (LString "core")) (EVar "coreDecls")) (EVar "modules"))) (DoLet false false (PVar "collided") (EApp (EVar "collidingCtorNames") (EVar "allUnits"))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "omSize") (EVar "collided")) (ELit (LInt 0))) (ETuple (EVar "coreDecls") (EVar "modules")) (EBlock (DoLet false false (PVar "surfaces") (EApp (EVar "unitSurfaces") (EVar "allUnits"))) (DoLet false false (PVar "ctorExportsPerUnit") (EApp (EVar "ctorExportsFrom") (EVar "surfaces"))) (DoLet false false (PVar "siblingCtors") (EApp (EApp (EVar "map") (ELam ((PVar "p")) (ETuple (EFieldAccess (EVar "p") "spSibling") (EApp (EVar "ctorExportsFrom") (EApp (EApp (EApp (EVar "fullSurfaces") (EFieldAccess (EVar "p") "spSubject")) (EVar "allUnits")) (EVar "surfaces")))))) (EVar "siblings"))) (DoLet false false (PVar "coreOut") (EApp (EApp (EApp (EVar "mangleCtorUnitU") (EVar "collided")) (EVar "ctorExportsPerUnit")) (ETuple (ELit (LString "core")) (EVar "coreDecls")))) (DoLet false false (PVar "modsOut") (EApp (EApp (EVar "map") (ELam ((PVar "m")) (EApp (EApp (EApp (EVar "mangleCtorModule") (EVar "collided")) (EApp (EApp (EVar "optionOr") (EVar "ctorExportsPerUnit")) (EApp (EApp (EVar "lookupAssoc") (EApp (EVar "fst") (EVar "m"))) (EVar "siblingCtors")))) (EVar "m")))) (EVar "modules"))) (DoExpr (ETuple (EVar "coreOut") (EVar "modsOut"))))))))
(DTypeSig true "mangleCtorCollisionsPair" (TyFun (TyApp (TyCon "List") (TyCon "SiblingPair")) (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))) (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))))))
(DFunDef false "mangleCtorCollisionsPair" ((PVar "siblings") (PTuple (PVar "coreDecls") (PVar "modules"))) (EApp (EApp (EApp (EVar "mangleCtorCollisions") (EVar "siblings")) (EVar "coreDecls")) (EVar "modules")))
(DTypeSig false "collidingCtorNames" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "OrdMap") (TyCon "Unit"))))
(DFunDef false "collidingCtorNames" ((PVar "units")) (EApp (EApp (EApp (EVar "collidedGo") (EApp (EApp (EVar "flatMap") (EVar "unitMangleCtorNames")) (EVar "units"))) (EVar "omEmpty")) (EVar "omEmpty")))
(DTypeSig false "collidedGo" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit"))))))
(DFunDef false "collidedGo" ((PList) PWild (PVar "dup")) (EVar "dup"))
(DFunDef false "collidedGo" ((PCons (PVar "n") (PVar "rest")) (PVar "seen") (PVar "dup")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "seen")) (EApp (EApp (EApp (EVar "collidedGo") (EVar "rest")) (EVar "seen")) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (ELit LUnit)) (EVar "dup"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "collidedGo") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (ELit LUnit)) (EVar "seen"))) (EVar "dup")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "unitMangleCtorNames" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "unitMangleCtorNames" ((PTuple PWild (PVar "decls"))) (EApp (EVar "dedup") (EApp (EApp (EVar "filterList") (EVar "evalMangleCandidate")) (EApp (EApp (EVar "flatMap") (EVar "localDataCtorNames")) (EVar "decls")))))
(DTypeSig false "localDataCtorNames" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "localDataCtorNames" ((PRec "DData" ((rf "dataCtors" (PVar "variants"))) false)) (EApp (EApp (EVar "map") (EVar "variantCtorName")) (EVar "variants")))
(DFunDef false "localDataCtorNames" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "localDataCtorNames") (EVar "d")))
(DFunDef false "localDataCtorNames" (PWild) (EListLit))
(DTypeSig false "evalMangleCandidate" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "evalMangleCandidate" ((PVar "n")) (EApp (EVar "not") (EApp (EVar "evalMangleExemptCtor") (EVar "n"))))
(DTypeSig false "evalMangleExemptCtor" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "evalMangleExemptCtor" ((PVar "n")) (EBinOp "||" (EBinOp "||" (EApp (EVar "isReservedCtor") (EVar "n")) (EBinOp "==" (EVar "n") (ELit (LString "Pass")))) (EBinOp "==" (EVar "n") (ELit (LString "Fail")))))
(DTypeSig false "mangleCtorModule" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "mangleCtorModule" ((PVar "collided") (PVar "ctorExportsPerUnit") (PTuple (PVar "mid") (PVar "decls"))) (ETuple (EVar "mid") (EApp (EApp (EApp (EVar "mangleCtorUnitU") (EVar "collided")) (EVar "ctorExportsPerUnit")) (ETuple (EVar "mid") (EVar "decls")))))
(DTypeSig false "mangleCtorUnitU" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "mangleCtorUnitU" ((PVar "collided") (PVar "ctorExportsPerUnit") (PTuple (PVar "mid") (PVar "decls"))) (EBlock (DoLet false false (PVar "rmList") (EApp (EApp (EVar "filterList") (EApp (EVar "renameKeyCollides") (EVar "collided"))) (EApp (EApp (EApp (EVar "buildUnitCtorRenameMap") (EVar "mid")) (EVar "ctorExportsPerUnit")) (EVar "decls")))) (DoLet false false (PVar "rm") (EApp (EApp (EVar "omFromPairs") (EApp (EVar "reverseL") (EVar "rmList"))) (EVar "omEmpty"))) (DoExpr (EIf (EApp (EVar "isEmptyL") (EVar "rmList")) (EVar "decls") (EApp (EApp (EVar "map") (EApp (EVar "renameDecl") (EVar "rm"))) (EVar "decls"))))))
(DTypeSig false "renameKeyCollides" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyTuple (TyCon "String") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "renameKeyCollides" ((PVar "collided") (PTuple (PVar "n") PWild)) (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "collided")))
(DTypeSig false "unitSurfaces" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "ModuleExports")))))
(DFunDef false "unitSurfaces" ((PVar "units")) (EApp (EApp (EApp (EVar "surfacesGo") (EApp (EVar "coreExportsOf") (EVar "units"))) (EVar "omEmpty")) (EVar "units")))
(DTypeSig false "coreExportsOf" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "ModuleExports")))
(DFunDef false "coreExportsOf" ((PVar "units")) (EMatch (EApp (EApp (EVar "lookupAssoc") (ELit (LString "core"))) (EVar "units")) (arm (PCon "Some" (PVar "coreDecls")) () (EApp (EVar "coreExports") (EVar "coreDecls"))) (arm (PCon "None") () (EApp (EVar "coreExports") (EListLit)))))
(DTypeSig false "surfacesGo" (TyFun (TyCon "ModuleExports") (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "ModuleExports")))))))
(DFunDef false "surfacesGo" (PWild PWild (PList)) (EListLit))
(DFunDef false "surfacesGo" ((PVar "coreExp") (PVar "known") (PCons (PTuple (PVar "mid") (PVar "decls")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "mid") (ELit (LString "core"))) (EBinOp "::" (ETuple (EVar "mid") (EVar "coreExp")) (EApp (EApp (EApp (EVar "surfacesGo") (EVar "coreExp")) (EVar "known")) (EVar "rest"))) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "exp") (EApp (EApp (EApp (EApp (EApp (EVar "buildExportsWith") (EVar "coreExp")) (EVar "known")) (EVar "mid")) (EVar "decls")) (EApp (EApp (EVar "flatMap") (EVar "identity")) (EApp (EVar "pubIfaceMethodSets") (EVar "decls"))))) (DoExpr (EBinOp "::" (ETuple (EVar "mid") (EVar "exp")) (EApp (EApp (EApp (EVar "surfacesGo") (EVar "coreExp")) (EApp (EApp (EApp (EVar "omInsert") (EVar "mid")) (EVar "exp")) (EVar "known"))) (EVar "rest"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "fnExportsFrom" (TyFun (TyFun (TyCon "String") (TyCon "ExportView")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "ModuleExports"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))))))
(DFunDef false "fnExportsFrom" ((PVar "viewOfUnit") (PVar "units") (PVar "surfaces")) (EBlock (DoLet false false (PVar "fnSyms") (EApp (EApp (EVar "omFromPairs") (EApp (EApp (EVar "map") (EApp (EVar "unitFnSyms") (EVar "viewOfUnit"))) (EVar "units"))) (EVar "omEmpty"))) (DoLet false false (PVar "methods") (EApp (EApp (EVar "omFromPairs") (EApp (EApp (EVar "map") (EVar "surfaceMethods")) (EVar "surfaces"))) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EVar "map") (EApp (EApp (EVar "unitFnExports") (EVar "fnSyms")) (EVar "methods"))) (EApp (EApp (EVar "zip") (EVar "units")) (EVar "surfaces"))))))
(DTypeSig false "surfaceMethods" (TyFun (TyTuple (TyCon "String") (TyCon "ModuleExports")) (TyTuple (TyCon "String") (TyApp (TyCon "OrdMap") (TyCon "Unit")))))
(DFunDef false "surfaceMethods" ((PTuple (PVar "mid") (PVar "exp"))) (ETuple (EVar "mid") (EApp (EApp (EVar "omFromNames") (EApp (EApp (EVar "flatMap") (EVar "snd")) (EFieldAccess (EVar "exp") "expIfaceMethods"))) (EVar "omEmpty"))))
(DTypeSig false "unitFnSyms" (TyFun (TyFun (TyCon "String") (TyCon "ExportView")) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyApp (TyCon "OrdMap") (TyCon "Unit"))))))
(DFunDef false "unitFnSyms" ((PVar "viewOfUnit") (PTuple (PVar "mid") (PVar "decls"))) (EBlock (DoLet false false (PVar "defined") (EApp (EApp (EVar "omFromNames") (EApp (EVar "unitDefNames") (ETuple (EVar "mid") (EVar "decls")))) (EVar "omEmpty"))) (DoLet false false (PVar "exported") (EApp (EApp (EApp (EVar "directUnder") (EApp (EVar "viewOfUnit") (EVar "mid"))) (EVar "nsValues")) (EVar "decls"))) (DoExpr (ETuple (EVar "mid") (EApp (EApp (EVar "omFromNames") (EApp (EApp (EVar "filterInSet") (EVar "defined")) (EVar "exported"))) (EVar "omEmpty"))))))
(DTypeSig false "unitFnExports" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (TyFun (TyTuple (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyCon "ModuleExports"))) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))))
(DFunDef false "unitFnExports" ((PVar "fnSyms") (PVar "methods") (PTuple (PTuple (PVar "mid") PWild) (PTuple PWild (PVar "exp")))) (EBlock (DoLet false false (PVar "origins") (EApp (EVar "multiMapOf") (EFieldAccess (EVar "exp") "expValueOrigins"))) (DoExpr (ETuple (EVar "mid") (EApp (EApp (EVar "dedupBy") (EVar "fst")) (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EApp (EVar "fnExport") (EVar "fnSyms")) (EVar "methods")) (EVar "exp")) (EVar "origins"))) (EFieldAccess (EVar "exp") "expValues")))))))
(DTypeSig false "fnExport" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (TyFun (TyCon "ModuleExports") (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))))))
(DFunDef false "fnExport" ((PVar "fnSyms") (PVar "methods") (PVar "exp") (PVar "origins") (PVar "v")) (EBlock (DoLet false false (PVar "decls") (EApp (EApp (EVar "optionOr") (EListLit (ETuple (EFieldAccess (EVar "exp") "modId") (EVar "v")))) (EApp (EApp (EVar "omLookup") (EVar "v")) (EVar "origins")))) (DoExpr (EMatch (EApp (EApp (EVar "find") (ELam ((PVar "d")) (EApp (EVar "not") (EApp (EApp (EApp (EVar "isMethodDecl") (EVar "fnSyms")) (EVar "methods")) (EVar "d"))))) (EVar "decls")) (arm (PCon "Some" (PTuple (PVar "dm") (PVar "dn"))) () (EIf (EBinOp "&&" (EBinOp "==" (EVar "dn") (EVar "v")) (EApp (EApp (EApp (EVar "isFnSymbol") (EVar "fnSyms")) (EVar "dm")) (EVar "dn"))) (EListLit (ETuple (EVar "v") (EVar "dm"))) (EListLit))) (arm (PCon "None") () (EListLit))))))
(DTypeSig false "isFnSymbol" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool")))))
(DFunDef false "isFnSymbol" ((PVar "fnSyms") (PVar "dm") (PVar "dn")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "dm")) (EVar "fnSyms")) (arm (PCon "Some" (PVar "syms")) () (EApp (EApp (EVar "omHasKey") (EVar "dn")) (EVar "syms"))) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "isMethodDecl" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (TyFun (TyTuple (TyCon "String") (TyCon "String")) (TyCon "Bool")))))
(DFunDef false "isMethodDecl" ((PVar "fnSyms") (PVar "methods") (PTuple (PVar "dm") (PVar "dn"))) (EBinOp "&&" (EApp (EVar "not") (EApp (EApp (EApp (EVar "isFnSymbol") (EVar "fnSyms")) (EVar "dm")) (EVar "dn"))) (EMatch (EApp (EApp (EVar "omLookup") (EVar "dm")) (EVar "methods")) (arm (PCon "Some" (PVar "ms")) () (EApp (EApp (EVar "omHasKey") (EVar "dn")) (EVar "ms"))) (arm (PCon "None") () (EVar "False")))))
(DTypeSig false "multiMapOf" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a"))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "multiMapOf" ((PVar "pairs")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "m") (PTuple (PVar "k") (PVar "v"))) (EApp (EApp (EApp (EApp (EVar "insertWith") (ELam ((PVar "_a") (PVar "_b")) (EBinOp "++" (EVar "_a") (EVar "_b")))) (EVar "k")) (EListLit (EVar "v"))) (EVar "m")))) (EVar "omEmpty")) (EApp (EVar "reverseL") (EVar "pairs"))))
(DTypeSig false "lookupDefiner" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "lookupDefiner" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupDefiner" ((PVar "k") (PCons (PTuple (PVar "n") (PVar "d")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "n")) (EApp (EVar "Some") (EVar "d")) (EApp (EApp (EVar "lookupDefiner") (EVar "k")) (EVar "rest"))))
(DTypeSig false "ctorExportsFrom" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "ModuleExports"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "ctorExportsFrom" ((PVar "surfaces")) (EBlock (DoLet false false (PVar "surfaceMap") (EApp (EApp (EVar "omFromPairs") (EVar "surfaces")) (EVar "omEmpty"))) (DoLet false false (PVar "newtypeCtors") (EApp (EApp (EVar "omFromPairs") (EApp (EApp (EVar "map") (EVar "surfaceNewtypeCtors")) (EVar "surfaces"))) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EVar "map") (EApp (EApp (EVar "unitCtorExports") (EVar "surfaceMap")) (EVar "newtypeCtors"))) (EVar "surfaces")))))
(DTypeSig false "surfaceNewtypeCtors" (TyFun (TyTuple (TyCon "String") (TyCon "ModuleExports")) (TyTuple (TyCon "String") (TyApp (TyCon "OrdMap") (TyCon "Unit")))))
(DFunDef false "surfaceNewtypeCtors" ((PTuple (PVar "mid") (PVar "exp"))) (ETuple (EVar "mid") (EApp (EApp (EVar "omFromNames") (EApp (EApp (EVar "map") (EVar "fst")) (EFieldAccess (EVar "exp") "expNewtypeCtors"))) (EVar "omEmpty"))))
(DTypeSig false "unitCtorExports" (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (TyFun (TyTuple (TyCon "String") (TyCon "ModuleExports")) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))))
(DFunDef false "unitCtorExports" ((PVar "surfaceMap") (PVar "newtypeCtors") (PTuple (PVar "mid") (PVar "exp"))) (EBlock (DoLet false false (PVar "typeDefiners") (EApp (EVar "multiMapOf") (EFieldAccess (EVar "exp") "expTypeOrigins"))) (DoLet false false (PVar "ctorDefiners") (EApp (EVar "multiMapOf") (EFieldAccess (EVar "exp") "expCtorOrigins"))) (DoLet false false (PVar "typed") (EApp (EApp (EVar "map") (EApp (EApp (EApp (EVar "typeRowDefiner") (EVar "typeDefiners")) (EVar "ctorDefiners")) (EVar "mid"))) (EFieldAccess (EVar "exp") "expTypeCtors"))) (DoLet false false (PVar "covered") (EApp (EVar "multiMapOf") (EApp (EApp (EVar "flatMap") (EVar "rowCtorDefiners")) (EVar "typed")))) (DoLet false false (PVar "loose") (EApp (EApp (EVar "dedupBy") (ELam ((PTuple (PVar "c") (PVar "d"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "lenKey") (EVar "c")))) (ELit (LString ""))) (EApp (EVar "display") (EVar "d"))) (ELit (LString ""))))) (EApp (EApp (EVar "filterList") (ELam ((PTuple (PVar "c") (PVar "d"))) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EVar "d")) (EApp (EApp (EVar "definersOf") (EVar "covered")) (EVar "c")))))) (EFieldAccess (EVar "exp") "expCtorOrigins")))) (DoExpr (ETuple (EVar "mid") (EBinOp "++" (EApp (EApp (EVar "map") (EApp (EVar "typeCtorRow") (EVar "newtypeCtors"))) (EVar "typed")) (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "looseCtorRow") (EVar "surfaceMap")) (EVar "newtypeCtors"))) (EVar "loose")))))))
(DTypeSig false "definersOf" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "definersOf" ((PVar "definers") (PVar "n")) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "definers"))))
(DTypeSig false "typeRowDefiner" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))) (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "typeRowDefiner" ((PVar "typeDefiners") (PVar "ctorDefiners") (PVar "mid") (PTuple (PVar "ty") (PVar "cs"))) (EBlock (DoLet false false (PVar "declaresRow") (ELam ((PVar "d")) (EApp (EApp (EVar "all") (ELam ((PVar "c")) (EApp (EApp (EVar "contains") (EVar "d")) (EApp (EApp (EVar "definersOf") (EVar "ctorDefiners")) (EVar "c"))))) (EVar "cs")))) (DoExpr (ETuple (EVar "ty") (EApp (EApp (EVar "optionOr") (EVar "mid")) (EApp (EApp (EVar "find") (EVar "declaresRow")) (EApp (EApp (EVar "definersOf") (EVar "typeDefiners")) (EVar "ty")))) (EVar "cs")))))
(DTypeSig false "rowCtorDefiners" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "rowCtorDefiners" ((PTuple PWild (PVar "d") (PVar "cs"))) (EApp (EApp (EVar "map") (ELam ((PVar "c")) (ETuple (EVar "c") (EVar "d")))) (EVar "cs")))
(DTypeSig false "typeCtorRow" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))) (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "typeCtorRow" ((PVar "newtypeCtors") (PTuple (PVar "ty") (PVar "definer") (PVar "cs"))) (ETuple (EVar "ty") (EVar "definer") (EApp (EApp (EVar "filterList") (EApp (EApp (EVar "offeredCtor") (EVar "newtypeCtors")) (EVar "definer"))) (EVar "cs"))))
(DTypeSig false "looseCtorRow" (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (TyFun (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "looseCtorRow" ((PVar "surfaceMap") (PVar "newtypeCtors") (PTuple (PVar "c") (PVar "definer"))) (EIf (EApp (EApp (EApp (EVar "offeredCtor") (EVar "newtypeCtors")) (EVar "definer")) (EVar "c")) (EBlock (DoLet false false (PVar "ty") (EMatch (EApp (EApp (EVar "omLookup") (EVar "definer")) (EVar "surfaceMap")) (arm (PCon "Some" (PVar "src")) () (EApp (EApp (EVar "optionOr") (ELit (LString ""))) (EApp (EApp (EVar "typeOfCtor") (EVar "c")) (EVar "src")))) (arm (PCon "None") () (ELit (LString ""))))) (DoExpr (EListLit (ETuple (EVar "ty") (EVar "definer") (EListLit (EVar "c")))))) (EListLit)))
(DTypeSig false "offeredCtor" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool")))))
(DFunDef false "offeredCtor" ((PVar "newtypeCtors") (PVar "definer") (PVar "c")) (EBinOp "&&" (EApp (EVar "nonReservedCtor") (EVar "c")) (EApp (EVar "not") (EMatch (EApp (EApp (EVar "omLookup") (EVar "definer")) (EVar "newtypeCtors")) (arm (PCon "Some" (PVar "ns")) () (EApp (EApp (EVar "omHasKey") (EVar "c")) (EVar "ns"))) (arm (PCon "None") () (EVar "False"))))))
(DTypeSig false "variantCtorName" (TyFun (TyCon "Variant") (TyCon "String")))
(DFunDef false "variantCtorName" ((PCon "Variant" (PVar "n") PWild)) (EVar "n"))
(DTypeSig false "nonReservedCtor" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "nonReservedCtor" ((PVar "n")) (EApp (EVar "not") (EApp (EVar "isReservedCtor") (EVar "n"))))
(DTypeSig true "isReservedCtor" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isReservedCtor" ((PVar "n")) (EApp (EVar "isSome") (EApp (EVar "namedRuntimeCtor") (EVar "n"))))
(DTypeSig false "buildUnitCtorRenameMap" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "buildUnitCtorRenameMap" ((PVar "mid") (PVar "ctorExportsPerUnit") (PVar "decls")) (EBlock (DoLet false false (PVar "localCtors") (EApp (EVar "dedup") (EApp (EVar "unitLocalCtorNames") (EVar "decls")))) (DoLet false false (PVar "localEntries") (EApp (EApp (EVar "flatMap") (EApp (EVar "localCtorRenameEntry") (EVar "mid"))) (EVar "localCtors"))) (DoLet false false (PVar "importEntries") (EApp (EApp (EApp (EVar "ctorImportEntries") (EVar "mid")) (EVar "ctorExportsPerUnit")) (EVar "decls"))) (DoExpr (EBinOp "++" (EVar "localEntries") (EVar "importEntries")))))
(DTypeSig false "unitLocalCtorNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "unitLocalCtorNames" ((PVar "decls")) (EApp (EApp (EVar "filterList") (EVar "nonReservedCtor")) (EApp (EApp (EVar "flatMap") (EVar "localCtorNames")) (EVar "decls"))))
(DTypeSig false "localCtorNames" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "localCtorNames" ((PRec "DData" ((rf "dataCtors" (PVar "variants"))) false)) (EApp (EApp (EVar "map") (EVar "variantCtorName")) (EVar "variants")))
(DFunDef false "localCtorNames" ((PRec "DNewtype" ((rf "newtypeCtor" (PVar "con"))) false)) (EListLit (EVar "con")))
(DFunDef false "localCtorNames" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "localCtorNames") (EVar "d")))
(DFunDef false "localCtorNames" (PWild) (EListLit))
(DTypeSig false "localCtorRenameEntry" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "localCtorRenameEntry" ((PVar "mid") (PVar "n")) (EListLit (ETuple (EVar "n") (EApp (EApp (EVar "mangledName") (EVar "mid")) (EVar "n")))))
(DTypeSig false "ctorImportEntries" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "ctorImportEntries" (PWild (PVar "ctorExportsPerUnit") (PVar "decls")) (EBinOp "++" (EApp (EApp (EVar "flatMap") (EApp (EVar "declCtorImportEntries") (EVar "ctorExportsPerUnit"))) (EVar "decls")) (EApp (EVar "coreCtorImportEntries") (EVar "ctorExportsPerUnit"))))
(DTypeSig false "coreCtorImportEntries" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "coreCtorImportEntries" ((PVar "ctorExportsPerUnit")) (EMatch (EApp (EApp (EVar "lookupCtorExports") (ELit (LString "core"))) (EVar "ctorExportsPerUnit")) (arm (PCon "Some" (PVar "entries")) () (EApp (EApp (EVar "flatMap") (EVar "typeCtorEntries")) (EVar "entries"))) (arm (PCon "None") () (EListLit))))
(DTypeSig false "declCtorImportEntries" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "declCtorImportEntries" ((PVar "ctorExportsPerUnit") (PCon "DUse" PWild (PVar "path") PWild)) (EApp (EApp (EVar "useCtorPathEntries") (EVar "ctorExportsPerUnit")) (EVar "path")))
(DFunDef false "declCtorImportEntries" ((PVar "ctorExportsPerUnit") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EVar "declCtorImportEntries") (EVar "ctorExportsPerUnit")) (EVar "d")))
(DFunDef false "declCtorImportEntries" (PWild PWild) (EListLit))
(DTypeSig false "useCtorPathEntries" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyFun (TyCon "UsePath") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "useCtorPathEntries" ((PVar "ctorExportsPerUnit") (PVar "path")) (EBlock (DoLet false false (PVar "mid") (EApp (EVar "useModId") (EVar "path"))) (DoExpr (EIf (EBinOp "==" (EVar "mid") (ELit (LString "core"))) (EListLit) (EMatch (EApp (EApp (EVar "lookupCtorExports") (EVar "mid")) (EVar "ctorExportsPerUnit")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "typeEntries")) () (EMatch (EVar "path") (arm (PCon "UseGroup" PWild (PVar "members")) () (EApp (EApp (EVar "flatMap") (EApp (EVar "ctorMemberEntry") (EVar "typeEntries"))) (EVar "members"))) (arm (PCon "UseWild" PWild) () (EApp (EApp (EVar "flatMap") (EVar "typeCtorEntries")) (EVar "typeEntries"))) (arm (PCon "UseName" PWild) () (EListLit)) (arm (PCon "UseAlias" PWild PWild) () (EApp (EApp (EVar "flatMap") (EVar "typeCtorEntries")) (EVar "typeEntries"))))))))))
(DTypeSig false "ctorMemberEntry" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyCon "UseMember") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "ctorMemberEntry" ((PVar "typeEntries") (PCon "UseMember" (PVar "name") (PVar "wild") PWild PWild)) (EIf (EVar "wild") (EMatch (EApp (EApp (EVar "lookupCtorTypeEntry") (EVar "name")) (EVar "typeEntries")) (arm (PCon "Some" (PTuple PWild (PVar "definer") (PVar "ctors"))) () (EBinOp "++" (EApp (EApp (EVar "bareCtorMemberEntry") (EVar "typeEntries")) (EVar "name")) (EApp (EApp (EVar "flatMap") (EApp (EVar "originCtorEntry") (EVar "definer"))) (EVar "ctors")))) (arm (PCon "None") () (EApp (EApp (EVar "bareCtorMemberEntry") (EVar "typeEntries")) (EVar "name")))) (EApp (EApp (EVar "bareCtorMemberEntry") (EVar "typeEntries")) (EVar "name"))))
(DTypeSig false "bareCtorMemberEntry" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "bareCtorMemberEntry" ((PList) PWild) (EListLit))
(DFunDef false "bareCtorMemberEntry" ((PCons (PTuple PWild (PVar "definer") (PVar "ctors")) (PVar "rest")) (PVar "name")) (EIf (EApp (EApp (EVar "contains") (EVar "name")) (EVar "ctors")) (EApp (EApp (EVar "originCtorEntry") (EVar "definer")) (EVar "name")) (EApp (EApp (EVar "bareCtorMemberEntry") (EVar "rest")) (EVar "name"))))
(DTypeSig false "typeCtorEntries" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "typeCtorEntries" ((PTuple PWild (PVar "definer") (PVar "ctors"))) (EApp (EApp (EVar "flatMap") (EApp (EVar "originCtorEntry") (EVar "definer"))) (EVar "ctors")))
(DTypeSig false "originCtorEntry" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "originCtorEntry" ((PVar "mid") (PVar "n")) (EListLit (ETuple (EVar "n") (EApp (EApp (EVar "mangledName") (EVar "mid")) (EVar "n")))))
(DTypeSig false "lookupCtorTypeEntry" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "lookupCtorTypeEntry" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupCtorTypeEntry" ((PVar "k") (PCons (PAs "e" (PTuple (PVar "t") PWild PWild)) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "t")) (EApp (EVar "Some") (EVar "e")) (EApp (EApp (EVar "lookupCtorTypeEntry") (EVar "k")) (EVar "rest"))))
(DTypeSig false "lookupCtorExports" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "lookupCtorExports" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupCtorExports" ((PVar "k") (PCons (PTuple (PVar "m") (PVar "es")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "m")) (EApp (EVar "Some") (EVar "es")) (EApp (EApp (EVar "lookupCtorExports") (EVar "k")) (EVar "rest"))))
(DTypeSig false "mangleModule" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyFun (TyFun (TyCon "String") (TyFun (TyCon "ExternDecl") (TyCon "String"))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "String"))) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))))))))
(DFunDef false "mangleModule" ((PVar "entryMid") (PVar "exportsPerUnit") (PVar "ctorExportsPerUnit") (PVar "externName") (PVar "externExports") (PTuple (PVar "mid") (PVar "decls"))) (ETuple (EVar "mid") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mangleUnitU") (EVar "entryMid")) (EVar "exportsPerUnit")) (EVar "ctorExportsPerUnit")) (EVar "externName")) (EVar "externExports")) (ETuple (EVar "mid") (EVar "decls")))))
(DTypeSig false "mangleUnitU" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyFun (TyFun (TyCon "String") (TyFun (TyCon "ExternDecl") (TyCon "String"))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "String"))) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyApp (TyCon "List") (TyCon "Decl")))))))))
(DFunDef false "mangleUnitU" ((PVar "entryMid") (PVar "exportsPerUnit") (PVar "ctorExportsPerUnit") (PVar "externName") (PVar "externExports") (PTuple (PVar "mid") (PVar "decls"))) (EBlock (DoLet false false (PVar "rmFn") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "buildUnitRenameMap") (EVar "entryMid")) (EVar "mid")) (EVar "exportsPerUnit")) (EVar "externName")) (EVar "externExports")) (EVar "decls"))) (DoLet false false (PVar "rmCtor") (EApp (EApp (EApp (EVar "buildUnitCtorRenameMap") (EVar "mid")) (EVar "ctorExportsPerUnit")) (EVar "decls"))) (DoLet false false (PVar "rmList") (EBinOp "++" (EVar "rmFn") (EVar "rmCtor"))) (DoLet false false (PVar "rm") (EApp (EApp (EVar "omFromPairs") (EApp (EVar "reverseL") (EVar "rmList"))) (EVar "omEmpty"))) (DoExpr (EIf (EApp (EVar "isEmptyL") (EVar "rmList")) (EVar "decls") (EApp (EApp (EVar "map") (EApp (EVar "renameDecl") (EVar "rm"))) (EVar "decls"))))))
(DTypeSig false "buildUnitRenameMap" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))) (TyFun (TyFun (TyCon "String") (TyFun (TyCon "ExternDecl") (TyCon "String"))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))))))
(DFunDef false "buildUnitRenameMap" ((PVar "entryMid") (PVar "mid") (PVar "exportsPerUnit") (PVar "externName") (PVar "externExports") (PVar "decls")) (EBlock (DoLet false false (PVar "localFns") (EApp (EVar "dedup") (EApp (EVar "unitDefNames") (ETuple (EVar "mid") (EVar "decls"))))) (DoLet false false (PVar "localEntries") (EBinOp "++" (EApp (EApp (EVar "map") (ELam ((PVar "n")) (ETuple (EVar "n") (EApp (EApp (EVar "mangledName") (EVar "mid")) (EVar "n"))))) (EVar "localFns")) (EApp (EApp (EVar "externDeclEntries") (EApp (EVar "externName") (EVar "mid"))) (EVar "decls")))) (DoLet false false (PVar "importEntries") (EApp (EApp (EApp (EVar "importRenameEntries") (EVar "mid")) (EVar "exportsPerUnit")) (EVar "decls"))) (DoLet false false (PVar "entries") (EBinOp "++" (EBinOp "++" (EVar "localEntries") (EVar "importEntries")) (EApp (EApp (EVar "flatMap") (EApp (EVar "externImportEntries") (EVar "externExports"))) (EVar "decls")))) (DoExpr (EIf (EBinOp "==" (EVar "mid") (EVar "entryMid")) (EApp (EApp (EVar "filterList") (ELam ((PVar "e")) (EApp (EVar "not") (EApp (EApp (EApp (EVar "isEntryMainKey") (EVar "entryMid")) (EVar "mid")) (EApp (EVar "fst") (EVar "e")))))) (EVar "entries")) (EVar "entries")))))
(DTypeSig false "externExportsFrom" (TyFun (TyFun (TyCon "String") (TyFun (TyCon "ExternDecl") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "ModuleExports"))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "String")))))))
(DFunDef false "externExportsFrom" ((PVar "externName") (PVar "units") (PVar "surfaces")) (EBlock (DoLet false false (PVar "externs") (EApp (EApp (EVar "omFromPairs") (EApp (EApp (EVar "map") (EVar "unitExternDecls")) (EVar "units"))) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EVar "omFromPairs") (EApp (EApp (EVar "map") (EApp (EApp (EVar "unitExternExports") (EVar "externName")) (EVar "externs"))) (EVar "surfaces"))) (EVar "omEmpty")))))
(DTypeSig false "unitExternDecls" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyApp (TyCon "OrdMap") (TyCon "ExternDecl")))))
(DFunDef false "unitExternDecls" ((PTuple (PVar "mid") (PVar "decls"))) (ETuple (EVar "mid") (EApp (EApp (EVar "omFromPairs") (EApp (EVar "reverseL") (EApp (EApp (EVar "externDeclEntries") (EVar "identity")) (EVar "decls")))) (EVar "omEmpty"))))
(DTypeSig false "unitExternExports" (TyFun (TyFun (TyCon "String") (TyFun (TyCon "ExternDecl") (TyCon "String"))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "ExternDecl"))) (TyFun (TyTuple (TyCon "String") (TyCon "ModuleExports")) (TyTuple (TyCon "String") (TyApp (TyCon "OrdMap") (TyCon "String")))))))
(DFunDef false "unitExternExports" ((PVar "externName") (PVar "externs") (PTuple (PVar "mid") (PVar "exp"))) (EBlock (DoLet false false (PVar "origins") (EApp (EVar "valueDeclsOf") (EVar "exp"))) (DoLet false false (PVar "entries") (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EApp (EVar "externExport") (EVar "externName")) (EVar "externs")) (EVar "exp")) (EVar "origins"))) (EFieldAccess (EVar "exp") "expValues"))) (DoExpr (ETuple (EVar "mid") (EApp (EApp (EVar "omFromPairs") (EApp (EVar "reverseL") (EVar "entries"))) (EVar "omEmpty"))))))
(DTypeSig false "externExport" (TyFun (TyFun (TyCon "String") (TyFun (TyCon "ExternDecl") (TyCon "String"))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "ExternDecl"))) (TyFun (TyCon "ModuleExports") (TyFun (TyApp (TyCon "OrdMap") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))))))
(DFunDef false "externExport" ((PVar "externName") (PVar "externs") (PVar "exp") (PVar "origins") (PVar "v")) (EMatch (EApp (EApp (EApp (EVar "valueDeclOf") (EVar "exp")) (EVar "origins")) (EVar "v")) (arm (PTuple (PVar "dm") (PVar "dn")) () (EMatch (EApp (EApp (EVar "omLookup") (EVar "dm")) (EVar "externs")) (arm (PCon "Some" (PVar "eds")) () (EMatch (EApp (EApp (EVar "omLookup") (EVar "dn")) (EVar "eds")) (arm (PCon "Some" (PVar "ed")) () (EListLit (ETuple (EVar "v") (EApp (EApp (EVar "externName") (EVar "dm")) (EVar "ed"))))) (arm (PCon "None") () (EListLit)))) (arm (PCon "None") () (EListLit))))))
(DTypeSig false "externDeclEntries" (TyFun (TyFun (TyCon "ExternDecl") (TyVar "a")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a"))))))
(DFunDef false "externDeclEntries" (PWild (PList)) (EListLit))
(DFunDef false "externDeclEntries" ((PVar "name") (PCons (PCon "DExtern" (PVar "ed")) (PVar "rest"))) (EBinOp "::" (ETuple (EFieldAccess (EVar "ed") "edName") (EApp (EVar "name") (EVar "ed"))) (EApp (EApp (EVar "externDeclEntries") (EVar "name")) (EVar "rest"))))
(DFunDef false "externDeclEntries" ((PVar "name") (PCons (PCon "DAttrib" PWild (PVar "decl")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "externDeclEntries") (EVar "name")) (EListLit (EVar "decl"))) (EApp (EApp (EVar "externDeclEntries") (EVar "name")) (EVar "rest"))))
(DFunDef false "externDeclEntries" ((PVar "name") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "externDeclEntries") (EVar "name")) (EVar "rest")))
(DTypeSig false "externSymbolName" (TyFun (TyCon "String") (TyFun (TyCon "ExternDecl") (TyCon "String"))))
(DFunDef false "externSymbolName" ((PVar "mid") (PVar "ed")) (EApp (EApp (EVar "sourceExternSymbol") (EVar "mid")) (EFieldAccess (EVar "ed") "edName")))
(DTypeSig true "externDeclaredName" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyCon "String"))))
(DFunDef false "externDeclaredName" ((PVar "n") (PVar "binds")) (EIf (EApp (EVar "isSome") (EApp (EVar "externDisplayName") (EVar "n"))) (EApp (EApp (EVar "optionOr") (EVar "n")) (EApp (EVar "externDisplayName") (EVar "n"))) (EIf (EBinOp "==" (EVar "binds") (EListLit (ETuple (ELit (LString "c")) (EVar "n")))) (EVar "n") (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "stringIndexOf") (ELit (LString "__"))) (EVar "n")) (arm (PCon "Some" (PVar "i")) () (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "+" (EVar "i") (ELit (LInt 2)))) (EApp (EVar "stringLength") (EVar "n"))) (EVar "n"))) (arm (PCon "None") () (EVar "n"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "externImportEntries" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "String"))) (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "externImportEntries" ((PVar "exports") (PCon "DUse" PWild (PVar "path") PWild)) (EMatch (EApp (EApp (EVar "omLookup") (EApp (EVar "useModId") (EVar "path"))) (EVar "exports")) (arm (PCon "Some" (PVar "names")) () (EApp (EApp (EVar "externPathEntries") (EVar "names")) (EVar "path"))) (arm (PCon "None") () (EListLit))))
(DFunDef false "externImportEntries" ((PVar "exports") (PCon "DAttrib" PWild (PVar "decl"))) (EApp (EApp (EVar "externImportEntries") (EVar "exports")) (EVar "decl")))
(DFunDef false "externImportEntries" (PWild PWild) (EListLit))
(DTypeSig false "externPathEntries" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "UsePath") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "externPathEntries" ((PVar "names") (PCon "UseGroup" PWild (PVar "members"))) (EApp (EApp (EVar "flatMap") (ELam ((PVar "member")) (EApp (EApp (EApp (EVar "externMemberEntry") (EVar "names")) (EApp (EVar "useMemberOrigin") (EVar "member"))) (EApp (EVar "useMemberLocal") (EVar "member"))))) (EVar "members")))
(DFunDef false "externPathEntries" ((PVar "names") (PCon "UseWild" PWild)) (EApp (EApp (EVar "flatMap") (ELam ((PVar "name")) (EApp (EApp (EApp (EVar "externMemberEntry") (EVar "names")) (EVar "name")) (EVar "name")))) (EApp (EVar "omKeys") (EVar "names"))))
(DFunDef false "externPathEntries" ((PVar "names") (PCon "UseName" (PVar "parts"))) (EIf (EApp (EVar "lenGt1") (EVar "parts")) (EApp (EApp (EApp (EVar "externMemberEntry") (EVar "names")) (EApp (EVar "lastOfPM") (EVar "parts"))) (EApp (EVar "lastOfPM") (EVar "parts"))) (EListLit)))
(DFunDef false "externPathEntries" ((PVar "names") (PCon "UseAlias" PWild (PVar "alias"))) (EApp (EApp (EVar "flatMap") (ELam ((PVar "name")) (EApp (EApp (EApp (EVar "externMemberEntry") (EVar "names")) (EVar "name")) (EApp (EApp (EVar "qualifiedLocal") (EVar "alias")) (EVar "name"))))) (EApp (EVar "omKeys") (EVar "names"))))
(DTypeSig false "externMemberEntry" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "externMemberEntry" ((PVar "names") (PVar "origin") (PVar "local")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "origin")) (EVar "names")) (arm (PCon "Some" (PVar "symbol")) () (EListLit (ETuple (EVar "local") (EVar "symbol")))) (arm (PCon "None") () (EListLit))))
(DTypeSig false "notIfaceMethodKey" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyTuple (TyCon "String") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "notIfaceMethodKey" ((PVar "methods") (PTuple (PVar "n") PWild)) (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "methods"))))
(DTypeSig false "unitIfaceMethodNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "unitIfaceMethodNames" ((PList)) (EListLit))
(DFunDef false "unitIfaceMethodNames" ((PCons (PRec "DInterface" ((rf "methods" None)) true) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "map") (EVar "ifaceMethodNameM")) (EVar "methods")) (EApp (EVar "unitIfaceMethodNames") (EVar "rest"))))
(DFunDef false "unitIfaceMethodNames" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EBinOp "++" (EApp (EVar "unitIfaceMethodNames") (EListLit (EVar "d"))) (EApp (EVar "unitIfaceMethodNames") (EVar "rest"))))
(DFunDef false "unitIfaceMethodNames" ((PCons PWild (PVar "rest"))) (EApp (EVar "unitIfaceMethodNames") (EVar "rest")))
(DTypeSig false "ifaceMethodNameM" (TyFun (TyCon "IfaceMethod") (TyCon "String")))
(DFunDef false "ifaceMethodNameM" ((PCon "IfaceMethod" (PVar "n") PWild PWild PWild)) (EVar "n"))
(DTypeSig false "isEntryMainKey" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool")))))
(DFunDef false "isEntryMainKey" ((PVar "entryMid") (PVar "mid") (PVar "n")) (EBinOp "&&" (EBinOp "==" (EVar "mid") (EVar "entryMid")) (EBinOp "==" (EVar "n") (ELit (LString "main")))))
(DTypeSig false "importRenameEntries" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "importRenameEntries" (PWild (PVar "exportsPerUnit") (PVar "decls")) (EBinOp "++" (EApp (EApp (EVar "flatMap") (EApp (EVar "declImportEntries") (EVar "exportsPerUnit"))) (EVar "decls")) (EApp (EApp (EVar "filterList") (EApp (EVar "notIfaceMethodKey") (EApp (EApp (EVar "omFromNames") (EApp (EVar "unitIfaceMethodNames") (EVar "decls"))) (EVar "omEmpty")))) (EApp (EVar "coreImportEntries") (EVar "exportsPerUnit")))))
(DTypeSig false "withPreludeDefs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))))))
(DFunDef false "withPreludeDefs" ((PVar "names") (PVar "implicit") (PVar "entries")) (EApp (EApp (EVar "map") (ELam ((PVar "e")) (EIf (EBinOp "==" (EApp (EVar "fst") (EVar "e")) (ELit (LString "core"))) (ETuple (ELit (LString "core")) (EBinOp "++" (EApp (EApp (EVar "map") (ELam ((PVar "n")) (ETuple (EVar "n") (ELit (LString "core"))))) (EVar "names")) (EVar "implicit"))) (EVar "e")))) (EVar "entries")))
(DTypeSig false "coreImportEntries" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "coreImportEntries" ((PVar "exportsPerUnit")) (EMatch (EApp (EApp (EVar "lookupExports") (ELit (LString "core"))) (EVar "exportsPerUnit")) (arm (PCon "Some" (PVar "names")) () (EApp (EApp (EVar "flatMap") (EVar "coreEntry")) (EVar "names"))) (arm (PCon "None") () (EListLit))))
(DTypeSig false "coreEntry" (TyFun (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "coreEntry" ((PTuple (PVar "n") (PVar "definer"))) (EListLit (ETuple (EVar "n") (EApp (EApp (EVar "mangledName") (EVar "definer")) (EVar "n")))))
(DTypeSig false "declImportEntries" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))) (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "declImportEntries" ((PVar "exportsPerUnit") (PCon "DUse" PWild (PVar "path") PWild)) (EApp (EApp (EVar "usePathEntries") (EVar "exportsPerUnit")) (EVar "path")))
(DFunDef false "declImportEntries" ((PVar "exportsPerUnit") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EVar "declImportEntries") (EVar "exportsPerUnit")) (EVar "d")))
(DFunDef false "declImportEntries" (PWild PWild) (EListLit))
(DTypeSig false "usePathEntries" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))) (TyFun (TyCon "UsePath") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "usePathEntries" ((PVar "exportsPerUnit") (PVar "path")) (EBlock (DoLet false false (PVar "mid") (EApp (EVar "useModId") (EVar "path"))) (DoExpr (EIf (EBinOp "==" (EVar "mid") (ELit (LString "core"))) (EApp (EApp (EVar "corePathEntries") (EVar "exportsPerUnit")) (EVar "path")) (EMatch (EApp (EApp (EVar "lookupExports") (EVar "mid")) (EVar "exportsPerUnit")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "exports")) () (EMatch (EVar "path") (arm (PCon "UseGroup" PWild (PVar "members")) () (EApp (EApp (EVar "flatMap") (EApp (EVar "memberEntry") (EVar "exports"))) (EVar "members"))) (arm (PCon "UseWild" PWild) () (EApp (EApp (EVar "flatMap") (EVar "originEntryPair")) (EVar "exports"))) (arm (PCon "UseName" (PVar "ns")) () (EApp (EApp (EVar "originEntry") (EVar "exports")) (EApp (EVar "lastOfPM") (EVar "ns")))) (arm (PCon "UseAlias" PWild (PVar "a")) () (EApp (EApp (EVar "flatMap") (EApp (EVar "aliasEntryPair") (EVar "a"))) (EVar "exports"))))))))))
(DTypeSig false "corePathEntries" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))) (TyFun (TyCon "UsePath") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "corePathEntries" ((PVar "exportsPerUnit") (PVar "path")) (EMatch (EApp (EApp (EVar "lookupExports") (ELit (LString "core"))) (EVar "exportsPerUnit")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "exports")) () (EMatch (EVar "path") (arm (PCon "UseAlias" PWild (PVar "a")) () (EApp (EApp (EVar "flatMap") (EApp (EVar "aliasEntryPair") (EVar "a"))) (EVar "exports"))) (arm (PCon "UseGroup" PWild (PVar "members")) () (EApp (EApp (EVar "flatMap") (EApp (EVar "coreRenamedEntry") (EVar "exports"))) (EVar "members"))) (arm PWild () (EListLit))))))
(DTypeSig false "coreRenamedEntry" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "UseMember") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "coreRenamedEntry" ((PVar "exports") (PVar "m")) (EMatch (EApp (EVar "useMemberAlias") (EVar "m")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "local")) () (EApp (EApp (EApp (EVar "originEntryAs") (EVar "exports")) (EApp (EVar "useMemberOrigin") (EVar "m"))) (EVar "local")))))
(DTypeSig false "memberEntry" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "UseMember") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "memberEntry" ((PVar "exports") (PVar "m")) (EApp (EApp (EApp (EVar "originEntryAs") (EVar "exports")) (EApp (EVar "useMemberOrigin") (EVar "m"))) (EApp (EVar "useMemberLocal") (EVar "m"))))
(DTypeSig false "originEntry" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "originEntry" ((PVar "exports") (PVar "n")) (EApp (EApp (EApp (EVar "originEntryAs") (EVar "exports")) (EVar "n")) (EVar "n")))
(DTypeSig false "originEntryAs" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "originEntryAs" ((PVar "exports") (PVar "origin") (PVar "local")) (EMatch (EApp (EApp (EVar "lookupDefiner") (EVar "origin")) (EVar "exports")) (arm (PCon "Some" (PVar "definer")) () (EListLit (ETuple (EVar "local") (EApp (EApp (EVar "mangledName") (EVar "definer")) (EVar "origin"))))) (arm (PCon "None") () (EListLit))))
(DTypeSig false "originEntryPair" (TyFun (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "originEntryPair" () (EVar "coreEntry"))
(DTypeSig false "aliasEntryPair" (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "aliasEntryPair" ((PVar "a") (PTuple (PVar "n") (PVar "definer"))) (EListLit (ETuple (EApp (EApp (EVar "qualifiedLocal") (EVar "a")) (EVar "n")) (EApp (EApp (EVar "mangledName") (EVar "definer")) (EVar "n")))))
(DTypeSig false "lenGt1" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "Bool")))
(DFunDef false "lenGt1" ((PCons PWild (PCons PWild PWild))) (EVar "True"))
(DFunDef false "lenGt1" (PWild) (EVar "False"))
(DTypeSig false "lastOfPM" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "lastOfPM" ((PList)) (ELit (LString "")))
(DFunDef false "lastOfPM" ((PList (PVar "x"))) (EVar "x"))
(DFunDef false "lastOfPM" ((PCons PWild (PVar "rest"))) (EApp (EVar "lastOfPM") (EVar "rest")))
(DTypeSig false "lookupExports" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "lookupExports" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupExports" ((PVar "k") (PCons (PTuple (PVar "m") (PVar "ns")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "m")) (EApp (EVar "Some") (EVar "ns")) (EApp (EApp (EVar "lookupExports") (EVar "k")) (EVar "rest"))))
(DTypeSig false "unitDefNames" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "unitDefNames" ((PTuple PWild (PVar "decls"))) (EApp (EApp (EVar "flatMap") (EVar "declBinderNames")) (EVar "decls")))
(DTypeSig true "mangledName" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "mangledName" ((PVar "mid") (PVar "name")) (EApp (EApp (EVar "encodePair") (EVar "mid")) (EVar "name")))
(DTypeSig true "sanitizeId" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "sanitizeId" ((PVar "s")) (EApp (EApp (EApp (EApp (EVar "sanitizeGo") (EVar "s")) (ELit (LInt 0))) (EApp (EVar "stringLength") (EVar "s"))) (ELit (LString ""))))
(DTypeSig false "sanitizeGo" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "String"))))))
(DFunDef false "sanitizeGo" ((PVar "s") (PVar "i") (PVar "len") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "len")) (EVar "acc") (EBlock (DoLet false false (PVar "c") (EApp (EApp (EApp (EVar "stringSlice") (EVar "i")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "s"))) (DoLet false false (PVar "c2") (EIf (EApp (EVar "safeChar") (EVar "c")) (EVar "c") (ELit (LString "_")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "sanitizeGo") (EVar "s")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "len")) (EBinOp "++" (EVar "acc") (EVar "c2")))))))
(DTypeSig true "safeChar" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "safeChar" ((PVar "c")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LString "a"))) (EBinOp "<=" (EVar "c") (ELit (LString "z")))) (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LString "A"))) (EBinOp "<=" (EVar "c") (ELit (LString "Z"))))) (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LString "0"))) (EBinOp "<=" (EVar "c") (ELit (LString "9"))))) (EBinOp "==" (EVar "c") (ELit (LString "_")))))
(DTypeSig true "injectiveIdent" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "injectiveIdent" ((PVar "s")) (EIf (EBinOp "&&" (EApp (EApp (EApp (EVar "allSafeChars") (EVar "s")) (ELit (LInt 0))) (EApp (EVar "stringLength") (EVar "s"))) (EApp (EVar "not") (EApp (EVar "startsZZ") (EVar "s")))) (EVar "s") (EBinOp "++" (EBinOp "++" (ELit (LString "zZ")) (EApp (EVar "display") (EApp (EApp (EApp (EApp (EVar "escapeGo") (EVar "s")) (ELit (LInt 0))) (EApp (EVar "stringLength") (EVar "s"))) (ELit (LString ""))))) (ELit (LString "")))))
(DTypeSig false "startsZZ" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "startsZZ" ((PVar "s")) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 2))) (EVar "s")) (ELit (LString "zZ"))))
(DTypeSig false "allSafeChars" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "allSafeChars" ((PVar "s") (PVar "i") (PVar "len")) (EIf (EBinOp ">=" (EVar "i") (EVar "len")) (EVar "True") (EIf (EApp (EVar "safeChar") (EApp (EApp (EApp (EVar "stringSlice") (EVar "i")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "s"))) (EApp (EApp (EApp (EVar "allSafeChars") (EVar "s")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "len")) (EVar "False"))))
(DTypeSig false "escapeGo" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "String"))))))
(DFunDef false "escapeGo" ((PVar "s") (PVar "i") (PVar "len") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "len")) (EVar "acc") (EBlock (DoLet false false (PVar "c") (EApp (EApp (EApp (EVar "stringSlice") (EVar "i")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "s"))) (DoLet false false (PVar "c2") (EIf (EApp (EVar "alnumChar") (EVar "c")) (EVar "c") (EBinOp "++" (EBinOp "++" (ELit (LString "_")) (EApp (EVar "display") (EApp (EVar "hexOfChar") (EVar "c")))) (ELit (LString "_"))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "escapeGo") (EVar "s")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "len")) (EBinOp "++" (EVar "acc") (EVar "c2")))))))
(DTypeSig false "alnumChar" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "alnumChar" ((PVar "c")) (EBinOp "||" (EBinOp "||" (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LString "a"))) (EBinOp "<=" (EVar "c") (ELit (LString "z")))) (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LString "A"))) (EBinOp "<=" (EVar "c") (ELit (LString "Z"))))) (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LString "0"))) (EBinOp "<=" (EVar "c") (ELit (LString "9"))))))
(DTypeSig false "hexOfChar" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "hexOfChar" ((PVar "c")) (EApp (EVar "hexOfInt") (EApp (EVar "charCode") (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 0))) (EApp (EVar "stringToChars") (EVar "c"))))))
(DTypeSig false "hexOfInt" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "hexOfInt" ((PVar "n")) (EIf (EBinOp "<" (EVar "n") (ELit (LInt 16))) (EApp (EVar "hexNibble") (EVar "n")) (EBinOp "++" (EApp (EVar "hexOfInt") (EBinOp "/" (EVar "n") (ELit (LInt 16)))) (EApp (EVar "hexNibble") (EBinOp "%" (EVar "n") (ELit (LInt 16)))))))
(DTypeSig false "hexNibble" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "hexNibble" ((PVar "n")) (EApp (EApp (EApp (EVar "stringSlice") (EVar "n")) (EBinOp "+" (EVar "n") (ELit (LInt 1)))) (ELit (LString "0123456789abcdef"))))
(DTypeSig true "hashName" (TyFun (TyCon "String") (TyCon "Int")))
(DFunDef false "hashName" ((PVar "s")) (EApp (EApp (EApp (EVar "hashChars") (EApp (EVar "stringToChars") (EVar "s"))) (ELit (LInt 0))) (ELit (LInt 5381))))
(DTypeSig false "hashChars" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "hashChars" ((PVar "cs") (PVar "i") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "cs"))) (EVar "acc") (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "hashChars") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "U64.toIntTruncating") (EBinOp "+" (EBinOp "*" (EApp (EVar "U64.truncate") (EVar "acc")) (ELit (LInt 33))) (EApp (EVar "U64.truncate") (EApp (EVar "charCode") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs"))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "dictTag" (TyFun (TyCon "String") (TyCon "Int")))
(DFunDef false "dictTag" ((PVar "s")) (EApp (EApp (EVar "posMod") (EApp (EVar "hashName") (EVar "s"))) (ELit (LInt 1073741824))))
(DTypeSig true "posMod" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "posMod" ((PVar "n") (PVar "m")) (EBinOp "%" (EBinOp "+" (EBinOp "%" (EVar "n") (EVar "m")) (EVar "m")) (EVar "m")))
(DTypeSig false "renameDecl" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "Decl") (TyCon "Decl"))))
(DFunDef false "renameDecl" ((PVar "rm") (PCon "DFunDef" (PVar "pub") (PVar "n") (PVar "ps") (PVar "e") (PVar "site") (PVar "bid"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "pub")) (EApp (EApp (EVar "renameDefName") (EVar "rm")) (EVar "n"))) (EApp (EApp (EVar "renamePatsPM") (EVar "rm")) (EVar "ps"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EApp (EVar "boundOfListPM") (EApp (EVar "patVarsListPM") (EVar "ps")))) (EVar "e"))) (EVar "site")) (EVar "bid")))
(DFunDef false "renameDecl" ((PVar "rm") (PCon "DTypeSig" (PVar "pub") (PVar "n") (PVar "ty") (PVar "site"))) (EApp (EApp (EApp (EApp (EVar "DTypeSig") (EVar "pub")) (EApp (EApp (EVar "renameDefName") (EVar "rm")) (EVar "n"))) (EVar "ty")) (EVar "site")))
(DFunDef false "renameDecl" ((PVar "rm") (PAs "d" (PRec "DInterface" ((rf "methods" None)) true))) (EVariantUpdate "DInterface" (EVar "d") ((fa "methods" (EApp (EApp (EVar "map") (EApp (EVar "renameIfaceMethod") (EVar "rm"))) (EVar "methods"))))))
(DFunDef false "renameDecl" ((PVar "rm") (PAs "d" (PRec "DImpl" ((rf "methods" None)) true))) (EVariantUpdate "DImpl" (EVar "d") ((fa "methods" (EApp (EApp (EVar "map") (EApp (EVar "renameImplMethod") (EVar "rm"))) (EVar "methods"))))))
(DFunDef false "renameDecl" ((PVar "rm") (PCon "DProp" (PVar "pub") (PVar "name") (PVar "params") (PVar "body"))) (EApp (EApp (EApp (EApp (EVar "DProp") (EVar "pub")) (EVar "name")) (EVar "params")) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EApp (EVar "boundOfListPM") (EApp (EVar "propParamNamesPM") (EVar "params")))) (EVar "body"))))
(DFunDef false "renameDecl" ((PVar "rm") (PCon "DTest" (PVar "pub") (PVar "name") (PVar "body"))) (EApp (EApp (EApp (EVar "DTest") (EVar "pub")) (EVar "name")) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "omEmpty")) (EVar "body"))))
(DFunDef false "renameDecl" ((PVar "rm") (PCon "DLetGroup" (PVar "pub") (PVar "binds"))) (EApp (EApp (EVar "DLetGroup") (EVar "pub")) (EApp (EApp (EVar "map") (EApp (EVar "renameLetBindDef") (EVar "rm"))) (EVar "binds"))))
(DFunDef false "renameDecl" ((PVar "rm") (PAs "d" (PRec "DData" ((rf "dataCtors" (PVar "variants"))) false))) (EVariantUpdate "DData" (EVar "d") ((fa "dataCtors" (EApp (EApp (EVar "map") (EApp (EVar "renameVariant") (EVar "rm"))) (EVar "variants"))))))
(DFunDef false "renameDecl" ((PVar "rm") (PAs "d" (PRec "DNewtype" ((rf "newtypeCtor" (PVar "con"))) false))) (EVariantUpdate "DNewtype" (EVar "d") ((fa "newtypeCtor" (EApp (EApp (EVar "renameDefName") (EVar "rm")) (EVar "con"))))))
(DFunDef false "renameDecl" ((PVar "rm") (PCon "DAttrib" (PVar "attrs") (PVar "d"))) (EApp (EApp (EVar "DAttrib") (EVar "attrs")) (EApp (EApp (EVar "renameDecl") (EVar "rm")) (EVar "d"))))
(DFunDef false "renameDecl" ((PVar "rm") (PCon "DExtern" (PVar "ed"))) (EApp (EVar "DExtern") (ERecordUpdate (EVar "ed") ((fa "edName" (EApp (EApp (EVar "renameDefName") (EVar "rm")) (EFieldAccess (EVar "ed") "edName")))))))
(DFunDef false "renameDecl" (PWild (PAs "d" (PCon "DUse" PWild PWild PWild))) (EVar "d"))
(DFunDef false "renameDecl" (PWild (PAs "d" (PCon "DEffect" PWild PWild PWild PWild PWild PWild))) (EVar "d"))
(DFunDef false "renameDecl" (PWild (PAs "d" (PRec "DTypeAlias" ((rf "tyAliasName" PWild)) true))) (EVar "d"))
(DTypeSig false "renameVariant" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "Variant") (TyCon "Variant"))))
(DFunDef false "renameVariant" ((PVar "rm") (PCon "Variant" (PVar "n") (PVar "payload"))) (EApp (EApp (EVar "Variant") (EApp (EApp (EVar "renameDefName") (EVar "rm")) (EVar "n"))) (EVar "payload")))
(DTypeSig false "renameLetBindDef" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "LetBind") (TyCon "LetBind"))))
(DFunDef false "renameLetBindDef" ((PVar "rm") (PCon "LetBind" (PVar "n") (PVar "clauses") (PVar "site") (PVar "bid"))) (EApp (EApp (EApp (EApp (EVar "LetBind") (EApp (EApp (EVar "renameDefName") (EVar "rm")) (EVar "n"))) (EApp (EApp (EVar "map") (EApp (EApp (EVar "renameFunClause") (EVar "rm")) (EVar "omEmpty"))) (EVar "clauses"))) (EVar "site")) (EVar "bid")))
(DTypeSig false "renameDefName" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "renameDefName" ((PVar "rm") (PVar "n")) (EApp (EApp (EVar "optionOr") (EVar "n")) (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "rm"))))
(DTypeSig false "renameIfaceMethod" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "IfaceMethod") (TyCon "IfaceMethod"))))
(DFunDef false "renameIfaceMethod" (PWild (PCon "IfaceMethod" (PVar "n") (PVar "ty") (PCon "None") (PVar "mloc"))) (EApp (EApp (EApp (EApp (EVar "IfaceMethod") (EVar "n")) (EVar "ty")) (EVar "None")) (EVar "mloc")))
(DFunDef false "renameIfaceMethod" ((PVar "rm") (PCon "IfaceMethod" (PVar "n") (PVar "ty") (PCon "Some" (PCon "MethodDefault" (PVar "ps") (PVar "e"))) (PVar "mloc"))) (EApp (EApp (EApp (EApp (EVar "IfaceMethod") (EVar "n")) (EVar "ty")) (EApp (EVar "Some") (EApp (EApp (EVar "MethodDefault") (EApp (EApp (EVar "renamePatsPM") (EVar "rm")) (EVar "ps"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EApp (EVar "boundOfListPM") (EApp (EVar "patVarsListPM") (EVar "ps")))) (EVar "e"))))) (EVar "mloc")))
(DTypeSig false "renameImplMethod" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "ImplMethod") (TyCon "ImplMethod"))))
(DFunDef false "renameImplMethod" ((PVar "rm") (PCon "ImplMethod" (PVar "n") (PVar "ps") (PVar "e"))) (EApp (EApp (EApp (EVar "ImplMethod") (EVar "n")) (EApp (EApp (EVar "renamePatsPM") (EVar "rm")) (EVar "ps"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EApp (EVar "boundOfListPM") (EApp (EVar "patVarsListPM") (EVar "ps")))) (EVar "e"))))
(DTypeSig false "propParamNamesPM" (TyFun (TyApp (TyCon "List") (TyCon "PropParam")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "propParamNamesPM" ((PVar "ps")) (EApp (EApp (EVar "map") (EVar "propParamNamePM")) (EVar "ps")))
(DTypeSig false "propParamNamePM" (TyFun (TyCon "PropParam") (TyCon "String")))
(DFunDef false "propParamNamePM" ((PCon "PropParam" (PVar "n") PWild PWild)) (EVar "n"))
(DTypeSig false "boundInsertPM" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit")))))
(DFunDef false "boundInsertPM" ((PList) (PVar "b")) (EVar "b"))
(DFunDef false "boundInsertPM" ((PCons (PVar "n") (PVar "rest")) (PVar "b")) (EApp (EApp (EVar "boundInsertPM") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (ELit LUnit)) (EVar "b"))))
(DTypeSig false "boundOfListPM" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "OrdMap") (TyCon "Unit"))))
(DFunDef false "boundOfListPM" ((PVar "ns")) (EApp (EApp (EVar "boundInsertPM") (EVar "ns")) (EVar "omEmpty")))
(DTypeSig false "renameScoped" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EVar" (PVar "n"))) (EIf (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "bound"))) (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "rm")) (arm (PCon "Some" (PVar "n2")) () (EApp (EVar "EVar") (EVar "n2"))) (arm (PCon "None") () (EApp (EVar "EVar") (EVar "n")))) (EIf (EVar "otherwise") (EApp (EVar "EVar") (EVar "n")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EVarId" (PVar "n") PWild)) (EIf (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "bound"))) (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "rm")) (arm (PCon "Some" (PVar "n2")) () (EApp (EVar "EVar") (EVar "n2"))) (arm (PCon "None") () (EApp (EVar "EVar") (EVar "n")))) (EIf (EVar "otherwise") (EApp (EVar "EVar") (EVar "n")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EVarAt" (PVar "n") (PVar "addr"))) (EIf (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "bound"))) (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "rm")) (arm (PCon "Some" (PVar "n2")) () (EApp (EApp (EVar "EVarAt") (EVar "n2")) (EVar "addr"))) (arm (PCon "None") () (EApp (EApp (EVar "EVarAt") (EVar "n")) (EVar "addr")))) (EIf (EVar "otherwise") (EApp (EApp (EVar "EVarAt") (EVar "n")) (EVar "addr")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "ELam" (PVar "ps") (PVar "body"))) (EApp (EApp (EVar "ELam") (EApp (EApp (EVar "renamePatsPM") (EVar "rm")) (EVar "ps"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EApp (EApp (EVar "boundInsertPM") (EApp (EVar "patVarsListPM") (EVar "ps"))) (EVar "bound"))) (EVar "body"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "ELet" (PVar "m") (PVar "r") (PVar "p") (PVar "e1") (PVar "e2"))) (EBlock (DoLet false false (PVar "pv") (EApp (EVar "patVarsPM") (EVar "p"))) (DoLet false false (PVar "b1") (EIf (EVar "r") (EApp (EApp (EVar "boundInsertPM") (EVar "pv")) (EVar "bound")) (EVar "bound"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "ELet") (EVar "m")) (EVar "r")) (EApp (EApp (EVar "renamePat") (EVar "rm")) (EVar "p"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "b1")) (EVar "e1"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EApp (EApp (EVar "boundInsertPM") (EVar "pv")) (EVar "bound"))) (EVar "e2"))))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "ELetGroup" (PVar "binds") (PVar "e2"))) (EBlock (DoLet false false (PVar "bnd") (EApp (EApp (EVar "boundInsertPM") (EApp (EVar "letBindNamesPM") (EVar "binds"))) (EVar "bound"))) (DoExpr (EApp (EApp (EVar "ELetGroup") (EApp (EApp (EVar "map") (EApp (EApp (EVar "renameLetBind") (EVar "rm")) (EVar "bnd"))) (EVar "binds"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bnd")) (EVar "e2"))))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EMatch" (PVar "e0") (PVar "arms"))) (EApp (EApp (EVar "EMatch") (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e0"))) (EApp (EApp (EVar "map") (EApp (EApp (EVar "renameArm") (EVar "rm")) (EVar "bound"))) (EVar "arms"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EBlock" (PVar "stmts"))) (EApp (EVar "EBlock") (EApp (EApp (EApp (EVar "renameStmts") (EVar "rm")) (EVar "bound")) (EVar "stmts"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EDo" (PVar "d") (PVar "stmts"))) (EApp (EApp (EVar "EDo") (EVar "d")) (EApp (EApp (EApp (EVar "renameStmts") (EVar "rm")) (EVar "bound")) (EVar "stmts"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "ELoc" (PVar "l") (PVar "e"))) (EApp (EApp (EVar "ELoc") (EVar "l")) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EDoOrigin" (PVar "l") (PVar "e"))) (EApp (EApp (EVar "EDoOrigin") (EVar "l")) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EApp" (PVar "f") (PVar "x"))) (EApp (EApp (EVar "EApp") (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "f"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "x"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EIf" (PVar "c") (PVar "t") (PVar "e"))) (EApp (EApp (EApp (EVar "EIf") (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "c"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "t"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EBinOp" (PVar "op") (PVar "l") (PVar "r") (PVar "dr"))) (EApp (EApp (EApp (EApp (EVar "EBinOp") (EVar "op")) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "l"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "r"))) (EVar "dr")))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EUnOp" (PVar "op") (PVar "x") (PVar "dr"))) (EApp (EApp (EApp (EVar "EUnOp") (EVar "op")) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "x"))) (EVar "dr")))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EInfix" (PVar "op") (PVar "l") (PVar "r"))) (EApp (EApp (EApp (EVar "EInfix") (EVar "op")) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "l"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "r"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EFieldAccess" (PVar "e0") (PVar "n") (PVar "ev"))) (EApp (EApp (EApp (EVar "EFieldAccess") (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e0"))) (EVar "n")) (EVar "ev")))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "ETuple" (PVar "es"))) (EApp (EVar "ETuple") (EApp (EApp (EVar "map") (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound"))) (EVar "es"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EListLit" (PVar "es"))) (EApp (EVar "EListLit") (EApp (EApp (EVar "map") (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound"))) (EVar "es"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EArrayLit" (PVar "es"))) (EApp (EVar "EArrayLit") (EApp (EApp (EVar "map") (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound"))) (EVar "es"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "ERangeList" (PVar "lo") (PVar "hi") (PVar "i"))) (EApp (EApp (EApp (EVar "ERangeList") (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "lo"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "hi"))) (EVar "i")))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "ERangeArray" (PVar "lo") (PVar "hi") (PVar "i"))) (EApp (EApp (EApp (EVar "ERangeArray") (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "lo"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "hi"))) (EVar "i")))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "ESlice" (PVar "e0") (PVar "lo") (PVar "hi") (PVar "i"))) (EApp (EApp (EApp (EApp (EVar "ESlice") (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e0"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "lo"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "hi"))) (EVar "i")))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EIndex" (PVar "e0") (PVar "i"))) (EApp (EApp (EVar "EIndex") (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e0"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "i"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EAnnot" (PVar "e0") (PVar "t"))) (EApp (EApp (EVar "EAnnot") (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e0"))) (EVar "t")))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EHeadAnnot" (PVar "e0") (PVar "t"))) (EApp (EApp (EVar "EHeadAnnot") (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e0"))) (EVar "t")))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "ERecordCreate" (PVar "n") (PVar "fs"))) (EApp (EApp (EVar "ERecordCreate") (EApp (EApp (EVar "renameDefName") (EVar "rm")) (EVar "n"))) (EApp (EApp (EVar "map") (EApp (EApp (EVar "renameField") (EVar "rm")) (EVar "bound"))) (EVar "fs"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "ERecordUpdate" (PVar "e0") (PVar "fs") (PVar "ev"))) (EApp (EApp (EApp (EVar "ERecordUpdate") (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e0"))) (EApp (EApp (EVar "map") (EApp (EApp (EVar "renameField") (EVar "rm")) (EVar "bound"))) (EVar "fs"))) (EVar "ev")))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EVariantUpdate" (PVar "c") (PVar "e0") (PVar "fs"))) (EApp (EApp (EApp (EVar "EVariantUpdate") (EApp (EApp (EVar "renameDefName") (EVar "rm")) (EVar "c"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e0"))) (EApp (EApp (EVar "map") (EApp (EApp (EVar "renameField") (EVar "rm")) (EVar "bound"))) (EVar "fs"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EStringInterp" (PVar "parts"))) (EApp (EVar "EStringInterp") (EApp (EApp (EVar "map") (EApp (EApp (EVar "renameInterp") (EVar "rm")) (EVar "bound"))) (EVar "parts"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EGuards" (PVar "arms"))) (EApp (EVar "EGuards") (EApp (EApp (EVar "map") (EApp (EApp (EVar "renameGuardArm") (EVar "rm")) (EVar "bound"))) (EVar "arms"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "ESection" (PCon "SecRight" (PVar "op") (PVar "e0")))) (EApp (EVar "ESection") (EApp (EApp (EVar "SecRight") (EVar "op")) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e0")))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "ESection" (PCon "SecLeft" (PVar "e0") (PVar "op")))) (EApp (EVar "ESection") (EApp (EApp (EVar "SecLeft") (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e0"))) (EVar "op"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EMapLit" (PVar "n") (PVar "kvs"))) (EApp (EApp (EVar "EMapLit") (EVar "n")) (EApp (EApp (EVar "map") (EApp (EApp (EVar "renameKv") (EVar "rm")) (EVar "bound"))) (EVar "kvs"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "ESetLit" (PVar "n") (PVar "es"))) (EApp (EApp (EVar "ESetLit") (EVar "n")) (EApp (EApp (EVar "map") (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound"))) (EVar "es"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EAsPat" (PVar "x") (PVar "sub"))) (EApp (EApp (EVar "EAsPat") (EVar "x")) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "sub"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EOrPat" (PVar "es"))) (EApp (EVar "EOrPat") (EApp (EApp (EVar "map") (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound"))) (EVar "es"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EDictAt" (PVar "n") (PVar "ev"))) (EIf (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "bound")) (EApp (EApp (EVar "EDictAt") (EVar "n")) (EVar "ev")) (EIf (EVar "otherwise") (EApp (EApp (EVar "EDictAt") (EApp (EApp (EVar "renameDefName") (EVar "rm")) (EVar "n"))) (EVar "ev")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "renameScoped" ((PVar "rm") PWild (PCon "EMethodAt" (PVar "m") (PVar "seed") (PVar "ev"))) (EApp (EApp (EApp (EVar "EMethodAt") (EVar "m")) (EApp (EApp (EVar "renameDefName") (EVar "rm")) (EVar "seed"))) (EVar "ev")))
(DFunDef false "renameScoped" (PWild PWild (PAs "e" (PCon "ELit" PWild))) (EVar "e"))
(DFunDef false "renameScoped" (PWild PWild (PAs "e" (PCon "ENumLit" PWild PWild PWild))) (EVar "e"))
(DFunDef false "renameScoped" (PWild PWild (PAs "e" (PCon "EWideLit" PWild PWild PWild PWild))) (EVar "e"))
(DFunDef false "renameScoped" (PWild PWild (PAs "e" (PCon "EMethodRef" PWild))) (EVar "e"))
(DFunDef false "renameScoped" (PWild PWild (PAs "e" (PCon "EDictApp" PWild))) (EVar "e"))
(DFunDef false "renameScoped" (PWild PWild (PAs "e" (PCon "ESection" (PCon "SecBare" PWild)))) (EVar "e"))
(DTypeSig false "renameField" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "FieldAssign") (TyCon "FieldAssign")))))
(DFunDef false "renameField" ((PVar "rm") (PVar "bound") (PCon "FieldAssign" (PVar "n") (PVar "e"))) (EApp (EApp (EVar "FieldAssign") (EVar "n")) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e"))))
(DTypeSig false "renameKv" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyTuple (TyCon "Expr") (TyCon "Expr")) (TyTuple (TyCon "Expr") (TyCon "Expr"))))))
(DFunDef false "renameKv" ((PVar "rm") (PVar "bound") (PTuple (PVar "k") (PVar "v"))) (ETuple (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "k")) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "v"))))
(DTypeSig false "renameInterp" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "InterpPart") (TyCon "InterpPart")))))
(DFunDef false "renameInterp" (PWild PWild (PCon "InterpStr" (PVar "s"))) (EApp (EVar "InterpStr") (EVar "s")))
(DFunDef false "renameInterp" ((PVar "rm") (PVar "bound") (PCon "InterpExpr" (PVar "e"))) (EApp (EVar "InterpExpr") (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e"))))
(DTypeSig false "renameLetBind" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "LetBind") (TyCon "LetBind")))))
(DFunDef false "renameLetBind" ((PVar "rm") (PVar "bound") (PCon "LetBind" (PVar "n") (PVar "clauses") (PVar "site") (PVar "bid"))) (EApp (EApp (EApp (EApp (EVar "LetBind") (EVar "n")) (EApp (EApp (EVar "map") (EApp (EApp (EVar "renameFunClause") (EVar "rm")) (EVar "bound"))) (EVar "clauses"))) (EVar "site")) (EVar "bid")))
(DTypeSig false "renameFunClause" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "FunClause") (TyCon "FunClause")))))
(DFunDef false "renameFunClause" ((PVar "rm") (PVar "bound") (PCon "FunClause" (PVar "ps") (PVar "body"))) (EApp (EApp (EVar "FunClause") (EApp (EApp (EVar "renamePatsPM") (EVar "rm")) (EVar "ps"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EApp (EApp (EVar "boundInsertPM") (EApp (EVar "patVarsListPM") (EVar "ps"))) (EVar "bound"))) (EVar "body"))))
(DTypeSig false "renameArm" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "Arm") (TyCon "Arm")))))
(DFunDef false "renameArm" ((PVar "rm") (PVar "bound") (PCon "Arm" (PVar "p") (PVar "gs") (PVar "body"))) (EBlock (DoLet false false (PVar "b0") (EApp (EApp (EVar "boundInsertPM") (EApp (EVar "patVarsPM") (EVar "p"))) (EVar "bound"))) (DoLet false false (PTuple (PVar "gs2") (PVar "bnd")) (EApp (EApp (EApp (EVar "renameGuards") (EVar "rm")) (EVar "b0")) (EVar "gs"))) (DoExpr (EApp (EApp (EApp (EVar "Arm") (EApp (EApp (EVar "renamePat") (EVar "rm")) (EVar "p"))) (EVar "gs2")) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bnd")) (EVar "body"))))))
(DTypeSig false "renameGuardArm" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "GuardArm") (TyCon "GuardArm")))))
(DFunDef false "renameGuardArm" ((PVar "rm") (PVar "bound") (PCon "GuardArm" (PVar "gs") (PVar "body"))) (EBlock (DoLet false false (PTuple (PVar "gs2") (PVar "bnd")) (EApp (EApp (EApp (EVar "renameGuards") (EVar "rm")) (EVar "bound")) (EVar "gs"))) (DoExpr (EApp (EApp (EVar "GuardArm") (EVar "gs2")) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bnd")) (EVar "body"))))))
(DTypeSig false "renameGuards" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "Guard")) (TyTuple (TyApp (TyCon "List") (TyCon "Guard")) (TyApp (TyCon "OrdMap") (TyCon "Unit")))))))
(DFunDef false "renameGuards" (PWild (PVar "bound") (PList)) (ETuple (EListLit) (EVar "bound")))
(DFunDef false "renameGuards" ((PVar "rm") (PVar "bound") (PCons (PCon "GBool" (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false (PVar "e2") (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e"))) (DoLet false false (PTuple (PVar "rest2") (PVar "bnd")) (EApp (EApp (EApp (EVar "renameGuards") (EVar "rm")) (EVar "bound")) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EApp (EVar "GBool") (EVar "e2")) (EVar "rest2")) (EVar "bnd")))))
(DFunDef false "renameGuards" ((PVar "rm") (PVar "bound") (PCons (PCon "GBind" (PVar "p") (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false (PVar "e2") (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e"))) (DoLet false false (PTuple (PVar "rest2") (PVar "bnd")) (EApp (EApp (EApp (EVar "renameGuards") (EVar "rm")) (EApp (EApp (EVar "boundInsertPM") (EApp (EVar "patVarsPM") (EVar "p"))) (EVar "bound"))) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EApp (EApp (EVar "GBind") (EApp (EApp (EVar "renamePat") (EVar "rm")) (EVar "p"))) (EVar "e2")) (EVar "rest2")) (EVar "bnd")))))
(DTypeSig false "renameStmts" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyApp (TyCon "List") (TyCon "DoStmt"))))))
(DFunDef false "renameStmts" (PWild PWild (PList)) (EListLit))
(DFunDef false "renameStmts" ((PVar "rm") (PVar "bound") (PCons (PCon "DoExpr" (PVar "e")) (PVar "rest"))) (EBinOp "::" (EApp (EVar "DoExpr") (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e"))) (EApp (EApp (EApp (EVar "renameStmts") (EVar "rm")) (EVar "bound")) (EVar "rest"))))
(DFunDef false "renameStmts" ((PVar "rm") (PVar "bound") (PCons (PCon "DoBind" (PVar "p") (PVar "e")) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EVar "DoBind") (EApp (EApp (EVar "renamePat") (EVar "rm")) (EVar "p"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e"))) (EApp (EApp (EApp (EVar "renameStmts") (EVar "rm")) (EApp (EApp (EVar "boundInsertPM") (EApp (EVar "patVarsPM") (EVar "p"))) (EVar "bound"))) (EVar "rest"))))
(DFunDef false "renameStmts" ((PVar "rm") (PVar "bound") (PCons (PCon "DoLet" (PVar "m") (PVar "r") (PVar "p") (PVar "e") (PVar "site")) (PVar "rest"))) (EBlock (DoLet false false (PVar "b1") (EIf (EVar "r") (EApp (EApp (EVar "boundInsertPM") (EApp (EVar "patVarsPM") (EVar "p"))) (EVar "bound")) (EVar "bound"))) (DoExpr (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EVar "DoLet") (EVar "m")) (EVar "r")) (EApp (EApp (EVar "renamePat") (EVar "rm")) (EVar "p"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "b1")) (EVar "e"))) (EVar "site")) (EApp (EApp (EApp (EVar "renameStmts") (EVar "rm")) (EApp (EApp (EVar "boundInsertPM") (EApp (EVar "patVarsPM") (EVar "p"))) (EVar "bound"))) (EVar "rest"))))))
(DFunDef false "renameStmts" ((PVar "rm") (PVar "bound") (PCons (PCon "DoAssign" (PVar "x") (PVar "e")) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EVar "DoAssign") (EVar "x")) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e"))) (EApp (EApp (EApp (EVar "renameStmts") (EVar "rm")) (EVar "bound")) (EVar "rest"))))
(DFunDef false "renameStmts" ((PVar "rm") (PVar "bound") (PCons (PCon "DoFieldAssign" (PVar "x") (PVar "fs") (PVar "e")) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EApp (EVar "DoFieldAssign") (EVar "x")) (EVar "fs")) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e"))) (EApp (EApp (EApp (EVar "renameStmts") (EVar "rm")) (EVar "bound")) (EVar "rest"))))
(DTypeSig false "letBindNamesPM" (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "letBindNamesPM" ((PVar "binds")) (EApp (EApp (EVar "map") (EVar "letBindName")) (EVar "binds")))
(DTypeSig false "patVarsPM" (TyFun (TyCon "Pat") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "patVarsPM" ((PCon "PVar" (PVar "x") PWild PWild)) (EListLit (EVar "x")))
(DFunDef false "patVarsPM" ((PCon "PCon" PWild (PVar "args"))) (EApp (EVar "patVarsListPM") (EVar "args")))
(DFunDef false "patVarsPM" ((PCon "PCons" (PVar "h") (PVar "t"))) (EBinOp "++" (EApp (EVar "patVarsPM") (EVar "h")) (EApp (EVar "patVarsPM") (EVar "t"))))
(DFunDef false "patVarsPM" ((PCon "PTuple" (PVar "ps"))) (EApp (EVar "patVarsListPM") (EVar "ps")))
(DFunDef false "patVarsPM" ((PCon "PList" (PVar "ps"))) (EApp (EVar "patVarsListPM") (EVar "ps")))
(DFunDef false "patVarsPM" ((PCon "PAs" (PVar "x") PWild PWild (PVar "p"))) (EBinOp "::" (EVar "x") (EApp (EVar "patVarsPM") (EVar "p"))))
(DFunDef false "patVarsPM" ((PCon "POr" (PCons (PVar "p") PWild))) (EApp (EVar "patVarsPM") (EVar "p")))
(DFunDef false "patVarsPM" ((PCon "PRec" PWild (PVar "fields") PWild)) (EApp (EApp (EVar "flatMap") (EVar "recPatFieldVarsPM")) (EVar "fields")))
(DFunDef false "patVarsPM" (PWild) (EListLit))
(DTypeSig false "patVarsListPM" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "patVarsListPM" ((PVar "ps")) (EApp (EApp (EVar "flatMap") (EVar "patVarsPM")) (EVar "ps")))
(DTypeSig false "renamePat" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "Pat") (TyCon "Pat"))))
(DFunDef false "renamePat" ((PVar "rm") (PCon "PCon" (PVar "n") (PVar "args"))) (EApp (EApp (EVar "PCon") (EApp (EApp (EVar "renameDefName") (EVar "rm")) (EVar "n"))) (EApp (EApp (EVar "map") (EApp (EVar "renamePat") (EVar "rm"))) (EVar "args"))))
(DFunDef false "renamePat" ((PVar "rm") (PCon "PCons" (PVar "h") (PVar "t"))) (EApp (EApp (EVar "PCons") (EApp (EApp (EVar "renamePat") (EVar "rm")) (EVar "h"))) (EApp (EApp (EVar "renamePat") (EVar "rm")) (EVar "t"))))
(DFunDef false "renamePat" ((PVar "rm") (PCon "PTuple" (PVar "ps"))) (EApp (EVar "PTuple") (EApp (EApp (EVar "map") (EApp (EVar "renamePat") (EVar "rm"))) (EVar "ps"))))
(DFunDef false "renamePat" ((PVar "rm") (PCon "PList" (PVar "ps"))) (EApp (EVar "PList") (EApp (EApp (EVar "map") (EApp (EVar "renamePat") (EVar "rm"))) (EVar "ps"))))
(DFunDef false "renamePat" ((PVar "rm") (PCon "PAs" (PVar "x") (PVar "l") (PVar "bid") (PVar "p"))) (EApp (EApp (EApp (EApp (EVar "PAs") (EVar "x")) (EVar "l")) (EVar "bid")) (EApp (EApp (EVar "renamePat") (EVar "rm")) (EVar "p"))))
(DFunDef false "renamePat" ((PVar "rm") (PCon "POr" (PVar "ps"))) (EApp (EVar "POr") (EApp (EApp (EVar "map") (EApp (EVar "renamePat") (EVar "rm"))) (EVar "ps"))))
(DFunDef false "renamePat" ((PVar "rm") (PCon "PRec" (PVar "n") (PVar "fields") (PVar "open"))) (EApp (EApp (EApp (EVar "PRec") (EApp (EApp (EVar "renameDefName") (EVar "rm")) (EVar "n"))) (EApp (EApp (EVar "map") (EApp (EVar "renameRecPatField") (EVar "rm"))) (EVar "fields"))) (EVar "open")))
(DFunDef false "renamePat" (PWild (PAs "p" (PCon "PVar" PWild PWild PWild))) (EVar "p"))
(DFunDef false "renamePat" (PWild (PAs "p" (PCon "PWild"))) (EVar "p"))
(DFunDef false "renamePat" (PWild (PAs "p" (PCon "PLit" PWild))) (EVar "p"))
(DFunDef false "renamePat" (PWild (PAs "p" (PCon "PRng" PWild PWild PWild))) (EVar "p"))
(DTypeSig false "renameRecPatField" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "RecPatField") (TyCon "RecPatField"))))
(DFunDef false "renameRecPatField" (PWild (PCon "RecPatField" (PVar "label") (PVar "l") (PVar "bid") (PCon "None"))) (EApp (EApp (EApp (EApp (EVar "RecPatField") (EVar "label")) (EVar "l")) (EVar "bid")) (EVar "None")))
(DFunDef false "renameRecPatField" ((PVar "rm") (PCon "RecPatField" (PVar "label") (PVar "l") (PVar "bid") (PCon "Some" (PVar "p")))) (EApp (EApp (EApp (EApp (EVar "RecPatField") (EVar "label")) (EVar "l")) (EVar "bid")) (EApp (EVar "Some") (EApp (EApp (EVar "renamePat") (EVar "rm")) (EVar "p")))))
(DTypeSig false "renamePatsPM" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyApp (TyCon "List") (TyCon "Pat")))))
(DFunDef false "renamePatsPM" ((PVar "rm") (PVar "ps")) (EApp (EApp (EVar "map") (EApp (EVar "renamePat") (EVar "rm"))) (EVar "ps")))
(DTypeSig false "recPatFieldVarsPM" (TyFun (TyCon "RecPatField") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "recPatFieldVarsPM" ((PCon "RecPatField" (PVar "label") PWild PWild (PCon "None"))) (EListLit (EVar "label")))
(DFunDef false "recPatFieldVarsPM" ((PCon "RecPatField" PWild PWild PWild (PCon "Some" (PVar "p")))) (EApp (EVar "patVarsPM") (EVar "p")))
# MARK
(DUse false (UseGroup ("frontend" "runtime_constructors") ((mem "namedRuntimeCtor" false))))
(DUse false (UseGroup ("support" "symbol_encoding") ((mem "encodePair" false))))
(DUse false (UseGroup ("types" "symbol_origins") ((mem "SymbolOrigins" false) (mem "emptyOrigins" false) (mem "unitOrigins" false) (mem "mergeOrigins" false))))
(DUse false (UseGroup ("types" "extern_source") ((mem "sourceExternSymbol" false) (mem "externDisplayName" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "letBindName" false) (mem "declBinderNames" false) (mem "Decl" true) (mem "ExternDecl" true) (mem "Expr" true) (mem "Pat" true) (mem "Arm" true) (mem "Guard" true) (mem "GuardArm" true) (mem "DoStmt" true) (mem "Section" true) (mem "InterpPart" true) (mem "FieldAssign" true) (mem "RecPatField" true) (mem "LetBind" true) (mem "FunClause" true) (mem "IfaceMethod" true) (mem "MethodDefault" true) (mem "ImplMethod" true) (mem "PropParam" true) (mem "UsePath" true) (mem "UseMember" true) (mem "useMemberOrigin" false) (mem "useMemberLocal" false) (mem "useMemberAlias" false) (mem "qualifiedLocal" false) (mem "Variant" true) (mem "DataVis" true) (mem "Route" true) (mem "EvVal" true) (mem "EvEntry" true) (mem "EvId" true) (mem "EvTable" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "SiblingPair" true))))
(DUse false (UseGroup ("frontend" "visibility") ((mem "ModuleExports" true) (mem "useModId" false) (mem "coreExports" false) (mem "buildExportsWith" false) (mem "pubIfaceMethodSets" false) (mem "ExportView" true) (mem "viewOf" false) (mem "fullExportsOf" false) (mem "directUnder" false) (mem "filterInSet" false) (mem "nsValues" false) (mem "valueDeclsOf" false) (mem "valueDeclOf" false) (mem "typeOfCtor" false))))
(DUse false (UseAlias ("u64") "U64"))
(DUse false (UseGroup ("list") ((mem "last" false) (mem "zip" false))))
(DUse false (UseGroup ("map") ((mem "insertWith" false))))
(DUse false (UseGroup ("support" "util") ((mem "lookupAssoc" false) (mem "contains" false) (mem "reverseL" false) (mem "isEmptyL" false) (mem "filterList" false) (mem "dedup" false) (mem "dedupBy" false) (mem "lenKey" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omInsert" false) (mem "omLookup" false) (mem "omKeys" false) (mem "omFromPairs" false) (mem "omFromNames" false) (mem "omHasKey" false) (mem "omEmpty" false) (mem "omSize" false))))
(DTypeSig true "mangleUnits" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))))))
(DFunDef false "mangleUnits" ((PVar "coreDecls") (PVar "modules")) (EBlock (DoLet false false (PTuple (PVar "coreOut") (PVar "modsOut") PWild) (EApp (EApp (EVar "mangleUnitsWithOrigins") (EVar "coreDecls")) (EVar "modules"))) (DoExpr (ETuple (EVar "coreOut") (EVar "modsOut")))))
(DTypeSig true "scopeUnitNames" (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))))))
(DFunDef false "scopeUnitNames" ((PCon "None") (PVar "coreDecls") (PVar "modules")) (EApp (EApp (EApp (EApp (EVar "renameUnits") (EVar "scopedExternName")) (EListLit)) (EVar "coreDecls")) (EVar "modules")))
(DFunDef false "scopeUnitNames" ((PCon "Some" (PTuple (PVar "mid") (PVar "decls"))) (PVar "coreDecls") (PVar "modules")) (EApp (EApp (EApp (EApp (EVar "renameUnits") (EVar "scopedExternName")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "n")) (ETuple (EVar "n") (EVar "mid")))) (EApp (EVar "externDeclNames") (EVar "decls")))) (EVar "coreDecls")) (EBinOp "::" (ETuple (EVar "mid") (EVar "decls")) (EVar "modules"))))
(DTypeSig false "scopedExternName" (TyFun (TyCon "String") (TyFun (TyCon "ExternDecl") (TyCon "String"))))
(DFunDef false "scopedExternName" ((PVar "mid") (PVar "ed")) (EApp (EApp (EVar "mangledName") (EVar "mid")) (EFieldAccess (EVar "ed") "edName")))
(DTypeSig false "externDeclNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "externDeclNames" ((PVar "decls")) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EApp (EApp (EVar "externDeclEntries") (ELam ((PVar "ed")) (EFieldAccess (EVar "ed") "edName"))) (EVar "decls"))))
(DTypeSig false "renameUnits" (TyFun (TyFun (TyCon "String") (TyFun (TyCon "ExternDecl") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))))))))
(DFunDef false "renameUnits" ((PVar "externName") (PVar "implicit") (PVar "coreDecls") (PVar "modules")) (EBlock (DoLet false false (PVar "allUnits") (EBinOp "::" (ETuple (ELit (LString "core")) (EVar "coreDecls")) (EVar "modules"))) (DoLet false false (PVar "entryMid") (EApp (EVar "entryUnitMid") (EVar "allUnits"))) (DoLet false false (PVar "surfaces") (EApp (EVar "unitSurfaces") (EVar "allUnits"))) (DoLet false false (PVar "exportsPerUnit") (EApp (EApp (EApp (EVar "withPreludeDefs") (EApp (EVar "dedup") (EApp (EVar "unitDefNames") (ETuple (ELit (LString "")) (EVar "coreDecls"))))) (EVar "implicit")) (EApp (EApp (EApp (EVar "fnExportsFrom") (ELam (PWild) (EVar "ExportedView"))) (EVar "allUnits")) (EVar "surfaces")))) (DoLet false false (PVar "ctorExportsPerUnit") (EApp (EVar "ctorExportsFrom") (EVar "surfaces"))) (DoLet false false (PVar "externExports") (EApp (EApp (EApp (EVar "externExportsFrom") (EVar "externName")) (EVar "allUnits")) (EVar "surfaces"))) (DoLet false false (PVar "coreOut") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mangleUnitU") (EVar "entryMid")) (EVar "exportsPerUnit")) (EVar "ctorExportsPerUnit")) (EVar "externName")) (EVar "externExports")) (ETuple (ELit (LString "core")) (EVar "coreDecls")))) (DoLet false false (PVar "modsOut") (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EApp (EApp (EVar "mangleModule") (EVar "entryMid")) (EVar "exportsPerUnit")) (EVar "ctorExportsPerUnit")) (EVar "externName")) (EVar "externExports"))) (EVar "modules"))) (DoExpr (ETuple (EVar "coreOut") (EVar "modsOut")))))
(DTypeSig false "entryUnitMid" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "String")))
(DFunDef false "entryUnitMid" ((PVar "units")) (EMatch (EApp (EVar "last") (EVar "units")) (arm (PCon "Some" (PTuple (PVar "mid") PWild)) () (EVar "mid")) (arm (PCon "None") () (ELit (LString "")))))
(DTypeSig true "mangleUnitsEv" (TyFun (TyCon "EvTable") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "EvTable") (TyCon "SymbolOrigins"))))))
(DFunDef false "mangleUnitsEv" () (EApp (EVar "mangleUnitsEvFor") (EListLit)))
(DTypeSig true "mangleUnitsEvFor" (TyFun (TyApp (TyCon "List") (TyCon "SiblingPair")) (TyFun (TyCon "EvTable") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "EvTable") (TyCon "SymbolOrigins")))))))
(DFunDef false "mangleUnitsEvFor" ((PVar "siblings") (PVar "table") (PVar "coreDecls") (PVar "modules")) (EBlock (DoLet false false (PVar "allUnits") (EBinOp "::" (ETuple (ELit (LString "core")) (EVar "coreDecls")) (EVar "modules"))) (DoLet false false (PVar "entryMid") (EApp (EVar "entryUnitMid") (EVar "allUnits"))) (DoLet false false (PVar "surfaces") (EApp (EVar "unitSurfaces") (EVar "allUnits"))) (DoLet false false (PVar "exportsPerUnit") (EApp (EApp (EApp (EApp (EVar "exportsPerUnitOf") (ELam (PWild) (EVar "ExportedView"))) (EVar "coreDecls")) (EVar "allUnits")) (EVar "surfaces"))) (DoLet false false (PVar "ctorExportsPerUnit") (EApp (EVar "ctorExportsFrom") (EVar "surfaces"))) (DoLet false false (PVar "externExports") (EApp (EApp (EApp (EVar "externExportsFrom") (EVar "externSymbolName")) (EVar "allUnits")) (EVar "surfaces"))) (DoLet false false (PVar "siblingMaps") (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EVar "siblingUnitMaps") (EVar "coreDecls")) (EVar "allUnits")) (EVar "surfaces"))) (EVar "siblings"))) (DoLet false false (PVar "units") (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EVar "unitEntryFor") (EVar "entryMid")) (EVar "siblingMaps")) (ETuple (EVar "exportsPerUnit") (EVar "ctorExportsPerUnit") (EVar "externExports")))) (EVar "allUnits"))) (DoLet false false (PVar "renamed") (EApp (EApp (EMethodRef "map") (EVar "renameUnitEntry")) (EVar "units"))) (DoLet false false (PVar "coreOut") (EMatch (EVar "renamed") (arm (PList) () (EVar "coreDecls")) (arm (PCons (PTuple PWild (PVar "ds")) PWild) () (EVar "ds")))) (DoLet false false (PVar "modsOut") (EMatch (EVar "renamed") (arm (PList) () (EVar "modules")) (arm (PCons PWild (PVar "rest")) () (EVar "rest")))) (DoLet false false (PVar "remap") (EApp (EVar "mangleEvEntry") (EApp (EApp (EVar "omFromPairs") (EApp (EVar "reverseL") (EApp (EApp (EMethodRef "map") (EVar "dropUnitDecls")) (EVar "units")))) (EVar "omEmpty")))) (DoLet false false (PVar "origins") (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PTuple (PVar "mid") (PTuple (PVar "rm") PWild (PVar "decls")))) (EApp (EApp (EVar "mergeOrigins") (EVar "acc")) (EApp (EApp (EApp (EVar "unitOrigins") (EVar "mid")) (EVar "rm")) (EVar "decls"))))) (EVar "emptyOrigins")) (EVar "units"))) (DoExpr (ETuple (EVar "coreOut") (EVar "modsOut") (EApp (EApp (EMethodRef "map") (EVar "remap")) (EVar "table")) (EVar "origins")))))
(DTypeSig true "mangleUnitsWithOrigins" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "SymbolOrigins")))))
(DFunDef false "mangleUnitsWithOrigins" ((PVar "coreDecls") (PVar "modules")) (EBlock (DoLet false false (PTuple (PVar "coreOut") (PVar "modsOut") PWild (PVar "origins")) (EApp (EApp (EApp (EVar "mangleUnitsEv") (EListLit)) (EVar "coreDecls")) (EVar "modules"))) (DoExpr (ETuple (EVar "coreOut") (EVar "modsOut") (EVar "origins")))))
(DTypeAlias false "ExportMaps" () (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "String")))))
(DTypeSig false "exportsPerUnitOf" (TyFun (TyFun (TyCon "String") (TyCon "ExportView")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "ModuleExports"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))))))
(DFunDef false "exportsPerUnitOf" ((PVar "viewOfUnit") (PVar "coreDecls") (PVar "allUnits") (PVar "surfaces")) (EApp (EApp (EApp (EVar "withPreludeDefs") (EApp (EVar "dedup") (EApp (EVar "unitDefNames") (ETuple (ELit (LString "")) (EVar "coreDecls"))))) (EListLit)) (EApp (EApp (EApp (EVar "fnExportsFrom") (EVar "viewOfUnit")) (EVar "allUnits")) (EVar "surfaces"))))
(DTypeSig false "siblingUnitMaps" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "ModuleExports"))) (TyFun (TyCon "SiblingPair") (TyTuple (TyCon "String") (TyCon "ExportMaps")))))))
(DFunDef false "siblingUnitMaps" ((PVar "coreDecls") (PVar "allUnits") (PVar "surfaces") (PVar "pair")) (EBlock (DoLet false false (PVar "subj") (EFieldAccess (EVar "pair") "spSubject")) (DoLet false false (PVar "full") (EApp (EApp (EApp (EVar "fullSurfaces") (EVar "subj")) (EVar "allUnits")) (EVar "surfaces"))) (DoExpr (ETuple (EFieldAccess (EVar "pair") "spSibling") (ETuple (EApp (EApp (EApp (EApp (EVar "exportsPerUnitOf") (EApp (EVar "viewOf") (EApp (EVar "Some") (EVar "subj")))) (EVar "coreDecls")) (EVar "allUnits")) (EVar "full")) (EApp (EVar "ctorExportsFrom") (EVar "full")) (EApp (EApp (EApp (EVar "externExportsFrom") (EVar "externSymbolName")) (EVar "allUnits")) (EVar "full")))))))
(DTypeSig false "fullSurfaces" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "ModuleExports"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "ModuleExports")))))))
(DFunDef false "fullSurfaces" ((PVar "subj") (PVar "allUnits") (PVar "surfaces")) (EBlock (DoLet false false (PVar "coreExp") (EApp (EVar "coreExportsOf") (EVar "allUnits"))) (DoLet false false (PVar "known") (EApp (EApp (EVar "omFromPairs") (EApp (EVar "reverseL") (EVar "surfaces"))) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EApp (EVar "fullSurfaceOf") (EVar "subj")) (EVar "coreExp")) (EVar "known")) (EVar "allUnits"))) (EVar "surfaces")))))
(DTypeSig false "fullSurfaceOf" (TyFun (TyCon "String") (TyFun (TyCon "ModuleExports") (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyTuple (TyCon "String") (TyCon "ModuleExports")) (TyTuple (TyCon "String") (TyCon "ModuleExports"))))))))
(DFunDef false "fullSurfaceOf" ((PVar "subj") (PVar "coreExp") (PVar "known") (PVar "allUnits") (PTuple (PVar "mid") (PVar "exp"))) (EIf (EBinOp "==" (EVar "mid") (EVar "subj")) (ETuple (EVar "mid") (EApp (EApp (EVar "optionOr") (EVar "exp")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "decls")) (EApp (EApp (EApp (EApp (EVar "fullExportsOf") (EVar "coreExp")) (EVar "known")) (EVar "mid")) (EVar "decls")))) (EApp (EApp (EVar "lookupAssoc") (EVar "mid")) (EVar "allUnits"))))) (ETuple (EVar "mid") (EVar "exp"))))
(DTypeSig false "unitEntryFor" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "ExportMaps"))) (TyFun (TyCon "ExportMaps") (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "OrdMap") (TyCon "String")) (TyCon "Bool") (TyApp (TyCon "List") (TyCon "Decl")))))))))
(DFunDef false "unitEntryFor" ((PVar "entryMid") (PVar "siblingMaps") (PVar "exported") (PTuple (PVar "mid") (PVar "decls"))) (EBlock (DoLet false false (PTuple (PVar "fns") (PVar "ctors") (PVar "externs")) (EApp (EApp (EVar "optionOr") (EVar "exported")) (EApp (EApp (EVar "lookupAssoc") (EVar "mid")) (EVar "siblingMaps")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "unitRenameMapEntry") (EVar "entryMid")) (EVar "fns")) (EVar "ctors")) (EVar "externs")) (ETuple (EVar "mid") (EVar "decls"))))))
(DTypeSig false "unitRenameMapEntry" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "String"))) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "OrdMap") (TyCon "String")) (TyCon "Bool") (TyApp (TyCon "List") (TyCon "Decl"))))))))))
(DFunDef false "unitRenameMapEntry" ((PVar "entryMid") (PVar "exportsPerUnit") (PVar "ctorExportsPerUnit") (PVar "externExports") (PTuple (PVar "mid") (PVar "decls"))) (EBlock (DoLet false false (PVar "rmList") (EBinOp "++" (EApp (EApp (EApp (EApp (EApp (EApp (EVar "buildUnitRenameMap") (EVar "entryMid")) (EVar "mid")) (EVar "exportsPerUnit")) (EVar "externSymbolName")) (EVar "externExports")) (EVar "decls")) (EApp (EApp (EApp (EVar "buildUnitCtorRenameMap") (EVar "mid")) (EVar "ctorExportsPerUnit")) (EVar "decls")))) (DoExpr (ETuple (EVar "mid") (ETuple (EApp (EApp (EVar "omFromPairs") (EApp (EVar "reverseL") (EVar "rmList"))) (EVar "omEmpty")) (EApp (EVar "isEmptyL") (EVar "rmList")) (EVar "decls"))))))
(DTypeSig false "renameUnitEntry" (TyFun (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "OrdMap") (TyCon "String")) (TyCon "Bool") (TyApp (TyCon "List") (TyCon "Decl")))) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "renameUnitEntry" ((PTuple (PVar "mid") (PTuple (PVar "rm") (PVar "noEntries") (PVar "decls")))) (ETuple (EVar "mid") (EIf (EVar "noEntries") (EVar "decls") (EApp (EApp (EMethodRef "map") (EApp (EVar "renameDecl") (EVar "rm"))) (EVar "decls")))))
(DTypeSig false "dropUnitDecls" (TyFun (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "OrdMap") (TyCon "String")) (TyCon "Bool") (TyApp (TyCon "List") (TyCon "Decl")))) (TyTuple (TyCon "String") (TyApp (TyCon "OrdMap") (TyCon "String")))))
(DFunDef false "dropUnitDecls" ((PTuple (PVar "mid") (PTuple (PVar "rm") PWild PWild))) (ETuple (EVar "mid") (EVar "rm")))
(DTypeSig false "mangleEvEntry" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "String"))) (TyFun (TyCon "EvEntry") (TyCon "EvEntry"))))
(DFunDef false "mangleEvEntry" ((PVar "maps") (PCon "EvEntry" (PCon "EvId" (PVar "m") (PVar "i")) (PVar "v"))) (EMatch (EApp (EApp (EVar "omLookup") (EVar "m")) (EVar "maps")) (arm (PCon "None") () (EApp (EApp (EVar "EvEntry") (EApp (EApp (EVar "EvId") (EVar "m")) (EVar "i"))) (EVar "v"))) (arm (PCon "Some" (PVar "rm")) () (EApp (EApp (EVar "EvEntry") (EApp (EApp (EVar "EvId") (EVar "m")) (EVar "i"))) (EApp (EApp (EVar "mangleEvVal") (EVar "rm")) (EVar "v"))))))
(DTypeSig false "mangleEvVal" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "EvVal") (TyCon "EvVal"))))
(DFunDef false "mangleEvVal" ((PVar "rm") (PCon "EvOne" (PVar "r"))) (EApp (EVar "EvOne") (EApp (EApp (EVar "mangleRoute") (EVar "rm")) (EVar "r"))))
(DFunDef false "mangleEvVal" ((PVar "rm") (PCon "EvMany" (PVar "rs"))) (EApp (EVar "EvMany") (EApp (EApp (EMethodRef "map") (EApp (EVar "mangleRoute") (EVar "rm"))) (EVar "rs"))))
(DFunDef false "mangleEvVal" ((PVar "rm") (PCon "EvMethod" (PVar "iface") (PVar "arity") (PVar "r") (PVar "reqs") (PVar "mds"))) (EApp (EApp (EApp (EApp (EApp (EVar "EvMethod") (EVar "iface")) (EVar "arity")) (EApp (EApp (EVar "mangleRoute") (EVar "rm")) (EVar "r"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "mangleRoute") (EVar "rm"))) (EVar "reqs"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "mangleRoute") (EVar "rm"))) (EVar "mds"))))
(DFunDef false "mangleEvVal" ((PVar "rm") (PCon "EvLit" (PVar "f") (PVar "r"))) (EApp (EApp (EVar "EvLit") (EVar "f")) (EApp (EApp (EVar "mangleRoute") (EVar "rm")) (EVar "r"))))
(DFunDef false "mangleEvVal" (PWild (PCon "EvHead" (PVar "h"))) (EApp (EVar "EvHead") (EVar "h")))
(DTypeSig false "mangleRoute" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "Route") (TyCon "Route"))))
(DFunDef false "mangleRoute" ((PVar "rm") (PCon "RLocal" (PVar "sym") (PVar "ds"))) (EApp (EApp (EVar "RLocal") (EApp (EApp (EVar "renameDefName") (EVar "rm")) (EVar "sym"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "mangleRoute") (EVar "rm"))) (EVar "ds"))))
(DFunDef false "mangleRoute" ((PVar "rm") (PCon "RKey" (PVar "k") (PVar "ds") (PVar "sups"))) (EApp (EApp (EApp (EVar "RKey") (EVar "k")) (EApp (EApp (EMethodRef "map") (EApp (EVar "mangleRoute") (EVar "rm"))) (EVar "ds"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "mangleRoute") (EVar "rm"))) (EVar "sups"))))
(DFunDef false "mangleRoute" ((PVar "rm") (PCon "RProj" (PVar "r") (PVar "path"))) (EApp (EApp (EVar "RProj") (EApp (EApp (EVar "mangleRoute") (EVar "rm")) (EVar "r"))) (EVar "path")))
(DFunDef false "mangleRoute" (PWild (PAs "r" (PCon "RNone"))) (EVar "r"))
(DFunDef false "mangleRoute" (PWild (PAs "r" (PCon "RDict" PWild))) (EVar "r"))
(DFunDef false "mangleRoute" (PWild (PAs "r" (PCon "RDictFwd" PWild))) (EVar "r"))
(DFunDef false "mangleRoute" (PWild (PAs "r" (PCon "RScalar" PWild))) (EVar "r"))
(DTypeSig true "mangleCtorCollisions" (TyFun (TyApp (TyCon "List") (TyCon "SiblingPair")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))))))
(DFunDef false "mangleCtorCollisions" ((PVar "siblings") (PVar "coreDecls") (PVar "modules")) (EBlock (DoLet false false (PVar "allUnits") (EBinOp "::" (ETuple (ELit (LString "core")) (EVar "coreDecls")) (EVar "modules"))) (DoLet false false (PVar "collided") (EApp (EVar "collidingCtorNames") (EVar "allUnits"))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "omSize") (EVar "collided")) (ELit (LInt 0))) (ETuple (EVar "coreDecls") (EVar "modules")) (EBlock (DoLet false false (PVar "surfaces") (EApp (EVar "unitSurfaces") (EVar "allUnits"))) (DoLet false false (PVar "ctorExportsPerUnit") (EApp (EVar "ctorExportsFrom") (EVar "surfaces"))) (DoLet false false (PVar "siblingCtors") (EApp (EApp (EMethodRef "map") (ELam ((PVar "p")) (ETuple (EFieldAccess (EVar "p") "spSibling") (EApp (EVar "ctorExportsFrom") (EApp (EApp (EApp (EVar "fullSurfaces") (EFieldAccess (EVar "p") "spSubject")) (EVar "allUnits")) (EVar "surfaces")))))) (EVar "siblings"))) (DoLet false false (PVar "coreOut") (EApp (EApp (EApp (EVar "mangleCtorUnitU") (EVar "collided")) (EVar "ctorExportsPerUnit")) (ETuple (ELit (LString "core")) (EVar "coreDecls")))) (DoLet false false (PVar "modsOut") (EApp (EApp (EMethodRef "map") (ELam ((PVar "m")) (EApp (EApp (EApp (EVar "mangleCtorModule") (EVar "collided")) (EApp (EApp (EVar "optionOr") (EVar "ctorExportsPerUnit")) (EApp (EApp (EVar "lookupAssoc") (EApp (EVar "fst") (EVar "m"))) (EVar "siblingCtors")))) (EVar "m")))) (EVar "modules"))) (DoExpr (ETuple (EVar "coreOut") (EVar "modsOut"))))))))
(DTypeSig true "mangleCtorCollisionsPair" (TyFun (TyApp (TyCon "List") (TyCon "SiblingPair")) (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))) (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))))))
(DFunDef false "mangleCtorCollisionsPair" ((PVar "siblings") (PTuple (PVar "coreDecls") (PVar "modules"))) (EApp (EApp (EApp (EVar "mangleCtorCollisions") (EVar "siblings")) (EVar "coreDecls")) (EVar "modules")))
(DTypeSig false "collidingCtorNames" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "OrdMap") (TyCon "Unit"))))
(DFunDef false "collidingCtorNames" ((PVar "units")) (EApp (EApp (EApp (EVar "collidedGo") (EApp (EApp (EDictApp "flatMap") (EVar "unitMangleCtorNames")) (EVar "units"))) (EVar "omEmpty")) (EVar "omEmpty")))
(DTypeSig false "collidedGo" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit"))))))
(DFunDef false "collidedGo" ((PList) PWild (PVar "dup")) (EVar "dup"))
(DFunDef false "collidedGo" ((PCons (PVar "n") (PVar "rest")) (PVar "seen") (PVar "dup")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "seen")) (EApp (EApp (EApp (EVar "collidedGo") (EVar "rest")) (EVar "seen")) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (ELit LUnit)) (EVar "dup"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "collidedGo") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (ELit LUnit)) (EVar "seen"))) (EVar "dup")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "unitMangleCtorNames" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "unitMangleCtorNames" ((PTuple PWild (PVar "decls"))) (EApp (EVar "dedup") (EApp (EApp (EVar "filterList") (EVar "evalMangleCandidate")) (EApp (EApp (EDictApp "flatMap") (EVar "localDataCtorNames")) (EVar "decls")))))
(DTypeSig false "localDataCtorNames" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "localDataCtorNames" ((PRec "DData" ((rf "dataCtors" (PVar "variants"))) false)) (EApp (EApp (EMethodRef "map") (EVar "variantCtorName")) (EVar "variants")))
(DFunDef false "localDataCtorNames" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "localDataCtorNames") (EVar "d")))
(DFunDef false "localDataCtorNames" (PWild) (EListLit))
(DTypeSig false "evalMangleCandidate" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "evalMangleCandidate" ((PVar "n")) (EApp (EVar "not") (EApp (EVar "evalMangleExemptCtor") (EVar "n"))))
(DTypeSig false "evalMangleExemptCtor" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "evalMangleExemptCtor" ((PVar "n")) (EBinOp "||" (EBinOp "||" (EApp (EVar "isReservedCtor") (EVar "n")) (EBinOp "==" (EVar "n") (ELit (LString "Pass")))) (EBinOp "==" (EVar "n") (ELit (LString "Fail")))))
(DTypeSig false "mangleCtorModule" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "mangleCtorModule" ((PVar "collided") (PVar "ctorExportsPerUnit") (PTuple (PVar "mid") (PVar "decls"))) (ETuple (EVar "mid") (EApp (EApp (EApp (EVar "mangleCtorUnitU") (EVar "collided")) (EVar "ctorExportsPerUnit")) (ETuple (EVar "mid") (EVar "decls")))))
(DTypeSig false "mangleCtorUnitU" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "mangleCtorUnitU" ((PVar "collided") (PVar "ctorExportsPerUnit") (PTuple (PVar "mid") (PVar "decls"))) (EBlock (DoLet false false (PVar "rmList") (EApp (EApp (EVar "filterList") (EApp (EVar "renameKeyCollides") (EVar "collided"))) (EApp (EApp (EApp (EVar "buildUnitCtorRenameMap") (EVar "mid")) (EVar "ctorExportsPerUnit")) (EVar "decls")))) (DoLet false false (PVar "rm") (EApp (EApp (EVar "omFromPairs") (EApp (EVar "reverseL") (EVar "rmList"))) (EVar "omEmpty"))) (DoExpr (EIf (EApp (EVar "isEmptyL") (EVar "rmList")) (EVar "decls") (EApp (EApp (EMethodRef "map") (EApp (EVar "renameDecl") (EVar "rm"))) (EVar "decls"))))))
(DTypeSig false "renameKeyCollides" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyTuple (TyCon "String") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "renameKeyCollides" ((PVar "collided") (PTuple (PVar "n") PWild)) (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "collided")))
(DTypeSig false "unitSurfaces" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "ModuleExports")))))
(DFunDef false "unitSurfaces" ((PVar "units")) (EApp (EApp (EApp (EVar "surfacesGo") (EApp (EVar "coreExportsOf") (EVar "units"))) (EVar "omEmpty")) (EVar "units")))
(DTypeSig false "coreExportsOf" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "ModuleExports")))
(DFunDef false "coreExportsOf" ((PVar "units")) (EMatch (EApp (EApp (EVar "lookupAssoc") (ELit (LString "core"))) (EVar "units")) (arm (PCon "Some" (PVar "coreDecls")) () (EApp (EVar "coreExports") (EVar "coreDecls"))) (arm (PCon "None") () (EApp (EVar "coreExports") (EListLit)))))
(DTypeSig false "surfacesGo" (TyFun (TyCon "ModuleExports") (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "ModuleExports")))))))
(DFunDef false "surfacesGo" (PWild PWild (PList)) (EListLit))
(DFunDef false "surfacesGo" ((PVar "coreExp") (PVar "known") (PCons (PTuple (PVar "mid") (PVar "decls")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "mid") (ELit (LString "core"))) (EBinOp "::" (ETuple (EVar "mid") (EVar "coreExp")) (EApp (EApp (EApp (EVar "surfacesGo") (EVar "coreExp")) (EVar "known")) (EVar "rest"))) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "exp") (EApp (EApp (EApp (EApp (EApp (EVar "buildExportsWith") (EVar "coreExp")) (EVar "known")) (EVar "mid")) (EVar "decls")) (EApp (EApp (EDictApp "flatMap") (EVar "identity")) (EApp (EVar "pubIfaceMethodSets") (EVar "decls"))))) (DoExpr (EBinOp "::" (ETuple (EVar "mid") (EVar "exp")) (EApp (EApp (EApp (EVar "surfacesGo") (EVar "coreExp")) (EApp (EApp (EApp (EVar "omInsert") (EVar "mid")) (EVar "exp")) (EVar "known"))) (EVar "rest"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "fnExportsFrom" (TyFun (TyFun (TyCon "String") (TyCon "ExportView")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "ModuleExports"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))))))
(DFunDef false "fnExportsFrom" ((PVar "viewOfUnit") (PVar "units") (PVar "surfaces")) (EBlock (DoLet false false (PVar "fnSyms") (EApp (EApp (EVar "omFromPairs") (EApp (EApp (EMethodRef "map") (EApp (EVar "unitFnSyms") (EVar "viewOfUnit"))) (EVar "units"))) (EVar "omEmpty"))) (DoLet false false (PVar "methods") (EApp (EApp (EVar "omFromPairs") (EApp (EApp (EMethodRef "map") (EVar "surfaceMethods")) (EVar "surfaces"))) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "unitFnExports") (EVar "fnSyms")) (EVar "methods"))) (EApp (EApp (EVar "zip") (EVar "units")) (EVar "surfaces"))))))
(DTypeSig false "surfaceMethods" (TyFun (TyTuple (TyCon "String") (TyCon "ModuleExports")) (TyTuple (TyCon "String") (TyApp (TyCon "OrdMap") (TyCon "Unit")))))
(DFunDef false "surfaceMethods" ((PTuple (PVar "mid") (PVar "exp"))) (ETuple (EVar "mid") (EApp (EApp (EVar "omFromNames") (EApp (EApp (EDictApp "flatMap") (EVar "snd")) (EFieldAccess (EVar "exp") "expIfaceMethods"))) (EVar "omEmpty"))))
(DTypeSig false "unitFnSyms" (TyFun (TyFun (TyCon "String") (TyCon "ExportView")) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyApp (TyCon "OrdMap") (TyCon "Unit"))))))
(DFunDef false "unitFnSyms" ((PVar "viewOfUnit") (PTuple (PVar "mid") (PVar "decls"))) (EBlock (DoLet false false (PVar "defined") (EApp (EApp (EVar "omFromNames") (EApp (EVar "unitDefNames") (ETuple (EVar "mid") (EVar "decls")))) (EVar "omEmpty"))) (DoLet false false (PVar "exported") (EApp (EApp (EApp (EVar "directUnder") (EApp (EVar "viewOfUnit") (EVar "mid"))) (EVar "nsValues")) (EVar "decls"))) (DoExpr (ETuple (EVar "mid") (EApp (EApp (EVar "omFromNames") (EApp (EApp (EVar "filterInSet") (EVar "defined")) (EVar "exported"))) (EVar "omEmpty"))))))
(DTypeSig false "unitFnExports" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (TyFun (TyTuple (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyCon "ModuleExports"))) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))))
(DFunDef false "unitFnExports" ((PVar "fnSyms") (PVar "methods") (PTuple (PTuple (PVar "mid") PWild) (PTuple PWild (PVar "exp")))) (EBlock (DoLet false false (PVar "origins") (EApp (EVar "multiMapOf") (EFieldAccess (EVar "exp") "expValueOrigins"))) (DoExpr (ETuple (EVar "mid") (EApp (EApp (EVar "dedupBy") (EVar "fst")) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EApp (EVar "fnExport") (EVar "fnSyms")) (EVar "methods")) (EVar "exp")) (EVar "origins"))) (EFieldAccess (EVar "exp") "expValues")))))))
(DTypeSig false "fnExport" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (TyFun (TyCon "ModuleExports") (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))))))
(DFunDef false "fnExport" ((PVar "fnSyms") (PVar "methods") (PVar "exp") (PVar "origins") (PVar "v")) (EBlock (DoLet false false (PVar "decls") (EApp (EApp (EVar "optionOr") (EListLit (ETuple (EFieldAccess (EVar "exp") "modId") (EVar "v")))) (EApp (EApp (EVar "omLookup") (EVar "v")) (EVar "origins")))) (DoExpr (EMatch (EApp (EApp (EDictApp "find") (ELam ((PVar "d")) (EApp (EVar "not") (EApp (EApp (EApp (EVar "isMethodDecl") (EVar "fnSyms")) (EVar "methods")) (EVar "d"))))) (EVar "decls")) (arm (PCon "Some" (PTuple (PVar "dm") (PVar "dn"))) () (EIf (EBinOp "&&" (EBinOp "==" (EVar "dn") (EVar "v")) (EApp (EApp (EApp (EVar "isFnSymbol") (EVar "fnSyms")) (EVar "dm")) (EVar "dn"))) (EListLit (ETuple (EVar "v") (EVar "dm"))) (EListLit))) (arm (PCon "None") () (EListLit))))))
(DTypeSig false "isFnSymbol" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool")))))
(DFunDef false "isFnSymbol" ((PVar "fnSyms") (PVar "dm") (PVar "dn")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "dm")) (EVar "fnSyms")) (arm (PCon "Some" (PVar "syms")) () (EApp (EApp (EVar "omHasKey") (EVar "dn")) (EVar "syms"))) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "isMethodDecl" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (TyFun (TyTuple (TyCon "String") (TyCon "String")) (TyCon "Bool")))))
(DFunDef false "isMethodDecl" ((PVar "fnSyms") (PVar "methods") (PTuple (PVar "dm") (PVar "dn"))) (EBinOp "&&" (EApp (EVar "not") (EApp (EApp (EApp (EVar "isFnSymbol") (EVar "fnSyms")) (EVar "dm")) (EVar "dn"))) (EMatch (EApp (EApp (EVar "omLookup") (EVar "dm")) (EVar "methods")) (arm (PCon "Some" (PVar "ms")) () (EApp (EApp (EVar "omHasKey") (EVar "dn")) (EVar "ms"))) (arm (PCon "None") () (EVar "False")))))
(DTypeSig false "multiMapOf" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a"))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "multiMapOf" ((PVar "pairs")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "m") (PTuple (PVar "k") (PVar "v"))) (EApp (EApp (EApp (EApp (EVar "insertWith") (ELam ((PVar "_a") (PVar "_b")) (EBinOp "++" (EVar "_a") (EVar "_b")))) (EVar "k")) (EListLit (EVar "v"))) (EVar "m")))) (EVar "omEmpty")) (EApp (EVar "reverseL") (EVar "pairs"))))
(DTypeSig false "lookupDefiner" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "lookupDefiner" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupDefiner" ((PVar "k") (PCons (PTuple (PVar "n") (PVar "d")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "n")) (EApp (EVar "Some") (EVar "d")) (EApp (EApp (EVar "lookupDefiner") (EVar "k")) (EVar "rest"))))
(DTypeSig false "ctorExportsFrom" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "ModuleExports"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "ctorExportsFrom" ((PVar "surfaces")) (EBlock (DoLet false false (PVar "surfaceMap") (EApp (EApp (EVar "omFromPairs") (EVar "surfaces")) (EVar "omEmpty"))) (DoLet false false (PVar "newtypeCtors") (EApp (EApp (EVar "omFromPairs") (EApp (EApp (EMethodRef "map") (EVar "surfaceNewtypeCtors")) (EVar "surfaces"))) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "unitCtorExports") (EVar "surfaceMap")) (EVar "newtypeCtors"))) (EVar "surfaces")))))
(DTypeSig false "surfaceNewtypeCtors" (TyFun (TyTuple (TyCon "String") (TyCon "ModuleExports")) (TyTuple (TyCon "String") (TyApp (TyCon "OrdMap") (TyCon "Unit")))))
(DFunDef false "surfaceNewtypeCtors" ((PTuple (PVar "mid") (PVar "exp"))) (ETuple (EVar "mid") (EApp (EApp (EVar "omFromNames") (EApp (EApp (EMethodRef "map") (EVar "fst")) (EFieldAccess (EVar "exp") "expNewtypeCtors"))) (EVar "omEmpty"))))
(DTypeSig false "unitCtorExports" (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (TyFun (TyTuple (TyCon "String") (TyCon "ModuleExports")) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))))
(DFunDef false "unitCtorExports" ((PVar "surfaceMap") (PVar "newtypeCtors") (PTuple (PVar "mid") (PVar "exp"))) (EBlock (DoLet false false (PVar "typeDefiners") (EApp (EVar "multiMapOf") (EFieldAccess (EVar "exp") "expTypeOrigins"))) (DoLet false false (PVar "ctorDefiners") (EApp (EVar "multiMapOf") (EFieldAccess (EVar "exp") "expCtorOrigins"))) (DoLet false false (PVar "typed") (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EVar "typeRowDefiner") (EVar "typeDefiners")) (EVar "ctorDefiners")) (EVar "mid"))) (EFieldAccess (EVar "exp") "expTypeCtors"))) (DoLet false false (PVar "covered") (EApp (EVar "multiMapOf") (EApp (EApp (EDictApp "flatMap") (EVar "rowCtorDefiners")) (EVar "typed")))) (DoLet false false (PVar "loose") (EApp (EApp (EVar "dedupBy") (ELam ((PTuple (PVar "c") (PVar "d"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "lenKey") (EVar "c")))) (ELit (LString ""))) (EApp (EMethodRef "display") (EVar "d"))) (ELit (LString ""))))) (EApp (EApp (EVar "filterList") (ELam ((PTuple (PVar "c") (PVar "d"))) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EVar "d")) (EApp (EApp (EVar "definersOf") (EVar "covered")) (EVar "c")))))) (EFieldAccess (EVar "exp") "expCtorOrigins")))) (DoExpr (ETuple (EVar "mid") (EBinOp "++" (EApp (EApp (EMethodRef "map") (EApp (EVar "typeCtorRow") (EVar "newtypeCtors"))) (EVar "typed")) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "looseCtorRow") (EVar "surfaceMap")) (EVar "newtypeCtors"))) (EVar "loose")))))))
(DTypeSig false "definersOf" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "definersOf" ((PVar "definers") (PVar "n")) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "definers"))))
(DTypeSig false "typeRowDefiner" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))) (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "typeRowDefiner" ((PVar "typeDefiners") (PVar "ctorDefiners") (PVar "mid") (PTuple (PVar "ty") (PVar "cs"))) (EBlock (DoLet false false (PVar "declaresRow") (ELam ((PVar "d")) (EApp (EApp (EDictApp "all") (ELam ((PVar "c")) (EApp (EApp (EVar "contains") (EVar "d")) (EApp (EApp (EVar "definersOf") (EVar "ctorDefiners")) (EVar "c"))))) (EVar "cs")))) (DoExpr (ETuple (EVar "ty") (EApp (EApp (EVar "optionOr") (EVar "mid")) (EApp (EApp (EDictApp "find") (EVar "declaresRow")) (EApp (EApp (EVar "definersOf") (EVar "typeDefiners")) (EVar "ty")))) (EVar "cs")))))
(DTypeSig false "rowCtorDefiners" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "rowCtorDefiners" ((PTuple PWild (PVar "d") (PVar "cs"))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "c")) (ETuple (EVar "c") (EVar "d")))) (EVar "cs")))
(DTypeSig false "typeCtorRow" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))) (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "typeCtorRow" ((PVar "newtypeCtors") (PTuple (PVar "ty") (PVar "definer") (PVar "cs"))) (ETuple (EVar "ty") (EVar "definer") (EApp (EApp (EVar "filterList") (EApp (EApp (EVar "offeredCtor") (EVar "newtypeCtors")) (EVar "definer"))) (EVar "cs"))))
(DTypeSig false "looseCtorRow" (TyFun (TyApp (TyCon "OrdMap") (TyCon "ModuleExports")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (TyFun (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "looseCtorRow" ((PVar "surfaceMap") (PVar "newtypeCtors") (PTuple (PVar "c") (PVar "definer"))) (EIf (EApp (EApp (EApp (EVar "offeredCtor") (EVar "newtypeCtors")) (EVar "definer")) (EVar "c")) (EBlock (DoLet false false (PVar "ty") (EMatch (EApp (EApp (EVar "omLookup") (EVar "definer")) (EVar "surfaceMap")) (arm (PCon "Some" (PVar "src")) () (EApp (EApp (EVar "optionOr") (ELit (LString ""))) (EApp (EApp (EVar "typeOfCtor") (EVar "c")) (EVar "src")))) (arm (PCon "None") () (ELit (LString ""))))) (DoExpr (EListLit (ETuple (EVar "ty") (EVar "definer") (EListLit (EVar "c")))))) (EListLit)))
(DTypeSig false "offeredCtor" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool")))))
(DFunDef false "offeredCtor" ((PVar "newtypeCtors") (PVar "definer") (PVar "c")) (EBinOp "&&" (EApp (EVar "nonReservedCtor") (EVar "c")) (EApp (EVar "not") (EMatch (EApp (EApp (EVar "omLookup") (EVar "definer")) (EVar "newtypeCtors")) (arm (PCon "Some" (PVar "ns")) () (EApp (EApp (EVar "omHasKey") (EVar "c")) (EVar "ns"))) (arm (PCon "None") () (EVar "False"))))))
(DTypeSig false "variantCtorName" (TyFun (TyCon "Variant") (TyCon "String")))
(DFunDef false "variantCtorName" ((PCon "Variant" (PVar "n") PWild)) (EVar "n"))
(DTypeSig false "nonReservedCtor" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "nonReservedCtor" ((PVar "n")) (EApp (EVar "not") (EApp (EVar "isReservedCtor") (EVar "n"))))
(DTypeSig true "isReservedCtor" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isReservedCtor" ((PVar "n")) (EApp (EVar "isSome") (EApp (EVar "namedRuntimeCtor") (EVar "n"))))
(DTypeSig false "buildUnitCtorRenameMap" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "buildUnitCtorRenameMap" ((PVar "mid") (PVar "ctorExportsPerUnit") (PVar "decls")) (EBlock (DoLet false false (PVar "localCtors") (EApp (EVar "dedup") (EApp (EVar "unitLocalCtorNames") (EVar "decls")))) (DoLet false false (PVar "localEntries") (EApp (EApp (EDictApp "flatMap") (EApp (EVar "localCtorRenameEntry") (EVar "mid"))) (EVar "localCtors"))) (DoLet false false (PVar "importEntries") (EApp (EApp (EApp (EVar "ctorImportEntries") (EVar "mid")) (EVar "ctorExportsPerUnit")) (EVar "decls"))) (DoExpr (EBinOp "++" (EVar "localEntries") (EVar "importEntries")))))
(DTypeSig false "unitLocalCtorNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "unitLocalCtorNames" ((PVar "decls")) (EApp (EApp (EVar "filterList") (EVar "nonReservedCtor")) (EApp (EApp (EDictApp "flatMap") (EVar "localCtorNames")) (EVar "decls"))))
(DTypeSig false "localCtorNames" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "localCtorNames" ((PRec "DData" ((rf "dataCtors" (PVar "variants"))) false)) (EApp (EApp (EMethodRef "map") (EVar "variantCtorName")) (EVar "variants")))
(DFunDef false "localCtorNames" ((PRec "DNewtype" ((rf "newtypeCtor" (PVar "con"))) false)) (EListLit (EVar "con")))
(DFunDef false "localCtorNames" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "localCtorNames") (EVar "d")))
(DFunDef false "localCtorNames" (PWild) (EListLit))
(DTypeSig false "localCtorRenameEntry" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "localCtorRenameEntry" ((PVar "mid") (PVar "n")) (EListLit (ETuple (EVar "n") (EApp (EApp (EVar "mangledName") (EVar "mid")) (EVar "n")))))
(DTypeSig false "ctorImportEntries" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "ctorImportEntries" (PWild (PVar "ctorExportsPerUnit") (PVar "decls")) (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EApp (EVar "declCtorImportEntries") (EVar "ctorExportsPerUnit"))) (EVar "decls")) (EApp (EVar "coreCtorImportEntries") (EVar "ctorExportsPerUnit"))))
(DTypeSig false "coreCtorImportEntries" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "coreCtorImportEntries" ((PVar "ctorExportsPerUnit")) (EMatch (EApp (EApp (EVar "lookupCtorExports") (ELit (LString "core"))) (EVar "ctorExportsPerUnit")) (arm (PCon "Some" (PVar "entries")) () (EApp (EApp (EDictApp "flatMap") (EVar "typeCtorEntries")) (EVar "entries"))) (arm (PCon "None") () (EListLit))))
(DTypeSig false "declCtorImportEntries" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "declCtorImportEntries" ((PVar "ctorExportsPerUnit") (PCon "DUse" PWild (PVar "path") PWild)) (EApp (EApp (EVar "useCtorPathEntries") (EVar "ctorExportsPerUnit")) (EVar "path")))
(DFunDef false "declCtorImportEntries" ((PVar "ctorExportsPerUnit") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EVar "declCtorImportEntries") (EVar "ctorExportsPerUnit")) (EVar "d")))
(DFunDef false "declCtorImportEntries" (PWild PWild) (EListLit))
(DTypeSig false "useCtorPathEntries" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyFun (TyCon "UsePath") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "useCtorPathEntries" ((PVar "ctorExportsPerUnit") (PVar "path")) (EBlock (DoLet false false (PVar "mid") (EApp (EVar "useModId") (EVar "path"))) (DoExpr (EIf (EBinOp "==" (EVar "mid") (ELit (LString "core"))) (EListLit) (EMatch (EApp (EApp (EVar "lookupCtorExports") (EVar "mid")) (EVar "ctorExportsPerUnit")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "typeEntries")) () (EMatch (EVar "path") (arm (PCon "UseGroup" PWild (PVar "members")) () (EApp (EApp (EDictApp "flatMap") (EApp (EVar "ctorMemberEntry") (EVar "typeEntries"))) (EVar "members"))) (arm (PCon "UseWild" PWild) () (EApp (EApp (EDictApp "flatMap") (EVar "typeCtorEntries")) (EVar "typeEntries"))) (arm (PCon "UseName" PWild) () (EListLit)) (arm (PCon "UseAlias" PWild PWild) () (EApp (EApp (EDictApp "flatMap") (EVar "typeCtorEntries")) (EVar "typeEntries"))))))))))
(DTypeSig false "ctorMemberEntry" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyCon "UseMember") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "ctorMemberEntry" ((PVar "typeEntries") (PCon "UseMember" (PVar "name") (PVar "wild") PWild PWild)) (EIf (EVar "wild") (EMatch (EApp (EApp (EVar "lookupCtorTypeEntry") (EVar "name")) (EVar "typeEntries")) (arm (PCon "Some" (PTuple PWild (PVar "definer") (PVar "ctors"))) () (EBinOp "++" (EApp (EApp (EVar "bareCtorMemberEntry") (EVar "typeEntries")) (EVar "name")) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "originCtorEntry") (EVar "definer"))) (EVar "ctors")))) (arm (PCon "None") () (EApp (EApp (EVar "bareCtorMemberEntry") (EVar "typeEntries")) (EVar "name")))) (EApp (EApp (EVar "bareCtorMemberEntry") (EVar "typeEntries")) (EVar "name"))))
(DTypeSig false "bareCtorMemberEntry" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "bareCtorMemberEntry" ((PList) PWild) (EListLit))
(DFunDef false "bareCtorMemberEntry" ((PCons (PTuple PWild (PVar "definer") (PVar "ctors")) (PVar "rest")) (PVar "name")) (EIf (EApp (EApp (EVar "contains") (EVar "name")) (EVar "ctors")) (EApp (EApp (EVar "originCtorEntry") (EVar "definer")) (EVar "name")) (EApp (EApp (EVar "bareCtorMemberEntry") (EVar "rest")) (EVar "name"))))
(DTypeSig false "typeCtorEntries" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "typeCtorEntries" ((PTuple PWild (PVar "definer") (PVar "ctors"))) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "originCtorEntry") (EVar "definer"))) (EVar "ctors")))
(DTypeSig false "originCtorEntry" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "originCtorEntry" ((PVar "mid") (PVar "n")) (EListLit (ETuple (EVar "n") (EApp (EApp (EVar "mangledName") (EVar "mid")) (EVar "n")))))
(DTypeSig false "lookupCtorTypeEntry" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "lookupCtorTypeEntry" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupCtorTypeEntry" ((PVar "k") (PCons (PAs "e" (PTuple (PVar "t") PWild PWild)) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "t")) (EApp (EVar "Some") (EVar "e")) (EApp (EApp (EVar "lookupCtorTypeEntry") (EVar "k")) (EVar "rest"))))
(DTypeSig false "lookupCtorExports" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "lookupCtorExports" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupCtorExports" ((PVar "k") (PCons (PTuple (PVar "m") (PVar "es")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "m")) (EApp (EVar "Some") (EVar "es")) (EApp (EApp (EVar "lookupCtorExports") (EVar "k")) (EVar "rest"))))
(DTypeSig false "mangleModule" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyFun (TyFun (TyCon "String") (TyFun (TyCon "ExternDecl") (TyCon "String"))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "String"))) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))))))))
(DFunDef false "mangleModule" ((PVar "entryMid") (PVar "exportsPerUnit") (PVar "ctorExportsPerUnit") (PVar "externName") (PVar "externExports") (PTuple (PVar "mid") (PVar "decls"))) (ETuple (EVar "mid") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mangleUnitU") (EVar "entryMid")) (EVar "exportsPerUnit")) (EVar "ctorExportsPerUnit")) (EVar "externName")) (EVar "externExports")) (ETuple (EVar "mid") (EVar "decls")))))
(DTypeSig false "mangleUnitU" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyFun (TyFun (TyCon "String") (TyFun (TyCon "ExternDecl") (TyCon "String"))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "String"))) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyApp (TyCon "List") (TyCon "Decl")))))))))
(DFunDef false "mangleUnitU" ((PVar "entryMid") (PVar "exportsPerUnit") (PVar "ctorExportsPerUnit") (PVar "externName") (PVar "externExports") (PTuple (PVar "mid") (PVar "decls"))) (EBlock (DoLet false false (PVar "rmFn") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "buildUnitRenameMap") (EVar "entryMid")) (EVar "mid")) (EVar "exportsPerUnit")) (EVar "externName")) (EVar "externExports")) (EVar "decls"))) (DoLet false false (PVar "rmCtor") (EApp (EApp (EApp (EVar "buildUnitCtorRenameMap") (EVar "mid")) (EVar "ctorExportsPerUnit")) (EVar "decls"))) (DoLet false false (PVar "rmList") (EBinOp "++" (EVar "rmFn") (EVar "rmCtor"))) (DoLet false false (PVar "rm") (EApp (EApp (EVar "omFromPairs") (EApp (EVar "reverseL") (EVar "rmList"))) (EVar "omEmpty"))) (DoExpr (EIf (EApp (EVar "isEmptyL") (EVar "rmList")) (EVar "decls") (EApp (EApp (EMethodRef "map") (EApp (EVar "renameDecl") (EVar "rm"))) (EVar "decls"))))))
(DTypeSig false "buildUnitRenameMap" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))) (TyFun (TyFun (TyCon "String") (TyFun (TyCon "ExternDecl") (TyCon "String"))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))))))
(DFunDef false "buildUnitRenameMap" ((PVar "entryMid") (PVar "mid") (PVar "exportsPerUnit") (PVar "externName") (PVar "externExports") (PVar "decls")) (EBlock (DoLet false false (PVar "localFns") (EApp (EVar "dedup") (EApp (EVar "unitDefNames") (ETuple (EVar "mid") (EVar "decls"))))) (DoLet false false (PVar "localEntries") (EBinOp "++" (EApp (EApp (EMethodRef "map") (ELam ((PVar "n")) (ETuple (EVar "n") (EApp (EApp (EVar "mangledName") (EVar "mid")) (EVar "n"))))) (EVar "localFns")) (EApp (EApp (EVar "externDeclEntries") (EApp (EVar "externName") (EVar "mid"))) (EVar "decls")))) (DoLet false false (PVar "importEntries") (EApp (EApp (EApp (EVar "importRenameEntries") (EVar "mid")) (EVar "exportsPerUnit")) (EVar "decls"))) (DoLet false false (PVar "entries") (EBinOp "++" (EBinOp "++" (EVar "localEntries") (EVar "importEntries")) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "externImportEntries") (EVar "externExports"))) (EVar "decls")))) (DoExpr (EIf (EBinOp "==" (EVar "mid") (EVar "entryMid")) (EApp (EApp (EVar "filterList") (ELam ((PVar "e")) (EApp (EVar "not") (EApp (EApp (EApp (EVar "isEntryMainKey") (EVar "entryMid")) (EVar "mid")) (EApp (EVar "fst") (EVar "e")))))) (EVar "entries")) (EVar "entries")))))
(DTypeSig false "externExportsFrom" (TyFun (TyFun (TyCon "String") (TyFun (TyCon "ExternDecl") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "ModuleExports"))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "String")))))))
(DFunDef false "externExportsFrom" ((PVar "externName") (PVar "units") (PVar "surfaces")) (EBlock (DoLet false false (PVar "externs") (EApp (EApp (EVar "omFromPairs") (EApp (EApp (EMethodRef "map") (EVar "unitExternDecls")) (EVar "units"))) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EVar "omFromPairs") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "unitExternExports") (EVar "externName")) (EVar "externs"))) (EVar "surfaces"))) (EVar "omEmpty")))))
(DTypeSig false "unitExternDecls" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyApp (TyCon "OrdMap") (TyCon "ExternDecl")))))
(DFunDef false "unitExternDecls" ((PTuple (PVar "mid") (PVar "decls"))) (ETuple (EVar "mid") (EApp (EApp (EVar "omFromPairs") (EApp (EVar "reverseL") (EApp (EApp (EVar "externDeclEntries") (EVar "identity")) (EVar "decls")))) (EVar "omEmpty"))))
(DTypeSig false "unitExternExports" (TyFun (TyFun (TyCon "String") (TyFun (TyCon "ExternDecl") (TyCon "String"))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "ExternDecl"))) (TyFun (TyTuple (TyCon "String") (TyCon "ModuleExports")) (TyTuple (TyCon "String") (TyApp (TyCon "OrdMap") (TyCon "String")))))))
(DFunDef false "unitExternExports" ((PVar "externName") (PVar "externs") (PTuple (PVar "mid") (PVar "exp"))) (EBlock (DoLet false false (PVar "origins") (EApp (EVar "valueDeclsOf") (EVar "exp"))) (DoLet false false (PVar "entries") (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EApp (EVar "externExport") (EVar "externName")) (EVar "externs")) (EVar "exp")) (EVar "origins"))) (EFieldAccess (EVar "exp") "expValues"))) (DoExpr (ETuple (EVar "mid") (EApp (EApp (EVar "omFromPairs") (EApp (EVar "reverseL") (EVar "entries"))) (EVar "omEmpty"))))))
(DTypeSig false "externExport" (TyFun (TyFun (TyCon "String") (TyFun (TyCon "ExternDecl") (TyCon "String"))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "ExternDecl"))) (TyFun (TyCon "ModuleExports") (TyFun (TyApp (TyCon "OrdMap") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))))))
(DFunDef false "externExport" ((PVar "externName") (PVar "externs") (PVar "exp") (PVar "origins") (PVar "v")) (EMatch (EApp (EApp (EApp (EVar "valueDeclOf") (EVar "exp")) (EVar "origins")) (EVar "v")) (arm (PTuple (PVar "dm") (PVar "dn")) () (EMatch (EApp (EApp (EVar "omLookup") (EVar "dm")) (EVar "externs")) (arm (PCon "Some" (PVar "eds")) () (EMatch (EApp (EApp (EVar "omLookup") (EVar "dn")) (EVar "eds")) (arm (PCon "Some" (PVar "ed")) () (EListLit (ETuple (EVar "v") (EApp (EApp (EVar "externName") (EVar "dm")) (EVar "ed"))))) (arm (PCon "None") () (EListLit)))) (arm (PCon "None") () (EListLit))))))
(DTypeSig false "externDeclEntries" (TyFun (TyFun (TyCon "ExternDecl") (TyVar "a")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyVar "a"))))))
(DFunDef false "externDeclEntries" (PWild (PList)) (EListLit))
(DFunDef false "externDeclEntries" ((PVar "name") (PCons (PCon "DExtern" (PVar "ed")) (PVar "rest"))) (EBinOp "::" (ETuple (EFieldAccess (EVar "ed") "edName") (EApp (EVar "name") (EVar "ed"))) (EApp (EApp (EVar "externDeclEntries") (EVar "name")) (EVar "rest"))))
(DFunDef false "externDeclEntries" ((PVar "name") (PCons (PCon "DAttrib" PWild (PVar "decl")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "externDeclEntries") (EVar "name")) (EListLit (EVar "decl"))) (EApp (EApp (EVar "externDeclEntries") (EVar "name")) (EVar "rest"))))
(DFunDef false "externDeclEntries" ((PVar "name") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "externDeclEntries") (EVar "name")) (EVar "rest")))
(DTypeSig false "externSymbolName" (TyFun (TyCon "String") (TyFun (TyCon "ExternDecl") (TyCon "String"))))
(DFunDef false "externSymbolName" ((PVar "mid") (PVar "ed")) (EApp (EApp (EVar "sourceExternSymbol") (EVar "mid")) (EFieldAccess (EVar "ed") "edName")))
(DTypeSig true "externDeclaredName" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyCon "String"))))
(DFunDef false "externDeclaredName" ((PVar "n") (PVar "binds")) (EIf (EApp (EVar "isSome") (EApp (EVar "externDisplayName") (EVar "n"))) (EApp (EApp (EVar "optionOr") (EVar "n")) (EApp (EVar "externDisplayName") (EVar "n"))) (EIf (EBinOp "==" (EVar "binds") (EListLit (ETuple (ELit (LString "c")) (EVar "n")))) (EVar "n") (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "stringIndexOf") (ELit (LString "__"))) (EVar "n")) (arm (PCon "Some" (PVar "i")) () (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "+" (EVar "i") (ELit (LInt 2)))) (EApp (EVar "stringLength") (EVar "n"))) (EVar "n"))) (arm (PCon "None") () (EVar "n"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "externImportEntries" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "String"))) (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "externImportEntries" ((PVar "exports") (PCon "DUse" PWild (PVar "path") PWild)) (EMatch (EApp (EApp (EVar "omLookup") (EApp (EVar "useModId") (EVar "path"))) (EVar "exports")) (arm (PCon "Some" (PVar "names")) () (EApp (EApp (EVar "externPathEntries") (EVar "names")) (EVar "path"))) (arm (PCon "None") () (EListLit))))
(DFunDef false "externImportEntries" ((PVar "exports") (PCon "DAttrib" PWild (PVar "decl"))) (EApp (EApp (EVar "externImportEntries") (EVar "exports")) (EVar "decl")))
(DFunDef false "externImportEntries" (PWild PWild) (EListLit))
(DTypeSig false "externPathEntries" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "UsePath") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "externPathEntries" ((PVar "names") (PCon "UseGroup" PWild (PVar "members"))) (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "member")) (EApp (EApp (EApp (EVar "externMemberEntry") (EVar "names")) (EApp (EVar "useMemberOrigin") (EVar "member"))) (EApp (EVar "useMemberLocal") (EVar "member"))))) (EVar "members")))
(DFunDef false "externPathEntries" ((PVar "names") (PCon "UseWild" PWild)) (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "name")) (EApp (EApp (EApp (EVar "externMemberEntry") (EVar "names")) (EVar "name")) (EVar "name")))) (EApp (EVar "omKeys") (EVar "names"))))
(DFunDef false "externPathEntries" ((PVar "names") (PCon "UseName" (PVar "parts"))) (EIf (EApp (EVar "lenGt1") (EVar "parts")) (EApp (EApp (EApp (EVar "externMemberEntry") (EVar "names")) (EApp (EVar "lastOfPM") (EVar "parts"))) (EApp (EVar "lastOfPM") (EVar "parts"))) (EListLit)))
(DFunDef false "externPathEntries" ((PVar "names") (PCon "UseAlias" PWild (PVar "alias"))) (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "name")) (EApp (EApp (EApp (EVar "externMemberEntry") (EVar "names")) (EVar "name")) (EApp (EApp (EVar "qualifiedLocal") (EVar "alias")) (EVar "name"))))) (EApp (EVar "omKeys") (EVar "names"))))
(DTypeSig false "externMemberEntry" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "externMemberEntry" ((PVar "names") (PVar "origin") (PVar "local")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "origin")) (EVar "names")) (arm (PCon "Some" (PVar "symbol")) () (EListLit (ETuple (EVar "local") (EVar "symbol")))) (arm (PCon "None") () (EListLit))))
(DTypeSig false "notIfaceMethodKey" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyTuple (TyCon "String") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "notIfaceMethodKey" ((PVar "methods") (PTuple (PVar "n") PWild)) (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "methods"))))
(DTypeSig false "unitIfaceMethodNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "unitIfaceMethodNames" ((PList)) (EListLit))
(DFunDef false "unitIfaceMethodNames" ((PCons (PRec "DInterface" ((rf "methods" None)) true) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EMethodRef "map") (EVar "ifaceMethodNameM")) (EVar "methods")) (EApp (EVar "unitIfaceMethodNames") (EVar "rest"))))
(DFunDef false "unitIfaceMethodNames" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EBinOp "++" (EApp (EVar "unitIfaceMethodNames") (EListLit (EVar "d"))) (EApp (EVar "unitIfaceMethodNames") (EVar "rest"))))
(DFunDef false "unitIfaceMethodNames" ((PCons PWild (PVar "rest"))) (EApp (EVar "unitIfaceMethodNames") (EVar "rest")))
(DTypeSig false "ifaceMethodNameM" (TyFun (TyCon "IfaceMethod") (TyCon "String")))
(DFunDef false "ifaceMethodNameM" ((PCon "IfaceMethod" (PVar "n") PWild PWild PWild)) (EVar "n"))
(DTypeSig false "isEntryMainKey" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool")))))
(DFunDef false "isEntryMainKey" ((PVar "entryMid") (PVar "mid") (PVar "n")) (EBinOp "&&" (EBinOp "==" (EVar "mid") (EVar "entryMid")) (EBinOp "==" (EVar "n") (ELit (LString "main")))))
(DTypeSig false "importRenameEntries" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "importRenameEntries" (PWild (PVar "exportsPerUnit") (PVar "decls")) (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EApp (EVar "declImportEntries") (EVar "exportsPerUnit"))) (EVar "decls")) (EApp (EApp (EVar "filterList") (EApp (EVar "notIfaceMethodKey") (EApp (EApp (EVar "omFromNames") (EApp (EVar "unitIfaceMethodNames") (EVar "decls"))) (EVar "omEmpty")))) (EApp (EVar "coreImportEntries") (EVar "exportsPerUnit")))))
(DTypeSig false "withPreludeDefs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))))))
(DFunDef false "withPreludeDefs" ((PVar "names") (PVar "implicit") (PVar "entries")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "e")) (EIf (EBinOp "==" (EApp (EVar "fst") (EVar "e")) (ELit (LString "core"))) (ETuple (ELit (LString "core")) (EBinOp "++" (EApp (EApp (EMethodRef "map") (ELam ((PVar "n")) (ETuple (EVar "n") (ELit (LString "core"))))) (EVar "names")) (EVar "implicit"))) (EVar "e")))) (EVar "entries")))
(DTypeSig false "coreImportEntries" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "coreImportEntries" ((PVar "exportsPerUnit")) (EMatch (EApp (EApp (EVar "lookupExports") (ELit (LString "core"))) (EVar "exportsPerUnit")) (arm (PCon "Some" (PVar "names")) () (EApp (EApp (EDictApp "flatMap") (EVar "coreEntry")) (EVar "names"))) (arm (PCon "None") () (EListLit))))
(DTypeSig false "coreEntry" (TyFun (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "coreEntry" ((PTuple (PVar "n") (PVar "definer"))) (EListLit (ETuple (EVar "n") (EApp (EApp (EVar "mangledName") (EVar "definer")) (EVar "n")))))
(DTypeSig false "declImportEntries" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))) (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "declImportEntries" ((PVar "exportsPerUnit") (PCon "DUse" PWild (PVar "path") PWild)) (EApp (EApp (EVar "usePathEntries") (EVar "exportsPerUnit")) (EVar "path")))
(DFunDef false "declImportEntries" ((PVar "exportsPerUnit") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EVar "declImportEntries") (EVar "exportsPerUnit")) (EVar "d")))
(DFunDef false "declImportEntries" (PWild PWild) (EListLit))
(DTypeSig false "usePathEntries" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))) (TyFun (TyCon "UsePath") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "usePathEntries" ((PVar "exportsPerUnit") (PVar "path")) (EBlock (DoLet false false (PVar "mid") (EApp (EVar "useModId") (EVar "path"))) (DoExpr (EIf (EBinOp "==" (EVar "mid") (ELit (LString "core"))) (EApp (EApp (EVar "corePathEntries") (EVar "exportsPerUnit")) (EVar "path")) (EMatch (EApp (EApp (EVar "lookupExports") (EVar "mid")) (EVar "exportsPerUnit")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "exports")) () (EMatch (EVar "path") (arm (PCon "UseGroup" PWild (PVar "members")) () (EApp (EApp (EDictApp "flatMap") (EApp (EVar "memberEntry") (EVar "exports"))) (EVar "members"))) (arm (PCon "UseWild" PWild) () (EApp (EApp (EDictApp "flatMap") (EVar "originEntryPair")) (EVar "exports"))) (arm (PCon "UseName" (PVar "ns")) () (EApp (EApp (EVar "originEntry") (EVar "exports")) (EApp (EVar "lastOfPM") (EVar "ns")))) (arm (PCon "UseAlias" PWild (PVar "a")) () (EApp (EApp (EDictApp "flatMap") (EApp (EVar "aliasEntryPair") (EVar "a"))) (EVar "exports"))))))))))
(DTypeSig false "corePathEntries" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))) (TyFun (TyCon "UsePath") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "corePathEntries" ((PVar "exportsPerUnit") (PVar "path")) (EMatch (EApp (EApp (EVar "lookupExports") (ELit (LString "core"))) (EVar "exportsPerUnit")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "exports")) () (EMatch (EVar "path") (arm (PCon "UseAlias" PWild (PVar "a")) () (EApp (EApp (EDictApp "flatMap") (EApp (EVar "aliasEntryPair") (EVar "a"))) (EVar "exports"))) (arm (PCon "UseGroup" PWild (PVar "members")) () (EApp (EApp (EDictApp "flatMap") (EApp (EVar "coreRenamedEntry") (EVar "exports"))) (EVar "members"))) (arm PWild () (EListLit))))))
(DTypeSig false "coreRenamedEntry" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "UseMember") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "coreRenamedEntry" ((PVar "exports") (PVar "m")) (EMatch (EApp (EVar "useMemberAlias") (EVar "m")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "local")) () (EApp (EApp (EApp (EVar "originEntryAs") (EVar "exports")) (EApp (EVar "useMemberOrigin") (EVar "m"))) (EVar "local")))))
(DTypeSig false "memberEntry" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "UseMember") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "memberEntry" ((PVar "exports") (PVar "m")) (EApp (EApp (EApp (EVar "originEntryAs") (EVar "exports")) (EApp (EVar "useMemberOrigin") (EVar "m"))) (EApp (EVar "useMemberLocal") (EVar "m"))))
(DTypeSig false "originEntry" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "originEntry" ((PVar "exports") (PVar "n")) (EApp (EApp (EApp (EVar "originEntryAs") (EVar "exports")) (EVar "n")) (EVar "n")))
(DTypeSig false "originEntryAs" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "originEntryAs" ((PVar "exports") (PVar "origin") (PVar "local")) (EMatch (EApp (EApp (EVar "lookupDefiner") (EVar "origin")) (EVar "exports")) (arm (PCon "Some" (PVar "definer")) () (EListLit (ETuple (EVar "local") (EApp (EApp (EVar "mangledName") (EVar "definer")) (EVar "origin"))))) (arm (PCon "None") () (EListLit))))
(DTypeSig false "originEntryPair" (TyFun (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "originEntryPair" () (EVar "coreEntry"))
(DTypeSig false "aliasEntryPair" (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "aliasEntryPair" ((PVar "a") (PTuple (PVar "n") (PVar "definer"))) (EListLit (ETuple (EApp (EApp (EVar "qualifiedLocal") (EVar "a")) (EVar "n")) (EApp (EApp (EVar "mangledName") (EVar "definer")) (EVar "n")))))
(DTypeSig false "lenGt1" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "Bool")))
(DFunDef false "lenGt1" ((PCons PWild (PCons PWild PWild))) (EVar "True"))
(DFunDef false "lenGt1" (PWild) (EVar "False"))
(DTypeSig false "lastOfPM" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "lastOfPM" ((PList)) (ELit (LString "")))
(DFunDef false "lastOfPM" ((PList (PVar "x"))) (EVar "x"))
(DFunDef false "lastOfPM" ((PCons PWild (PVar "rest"))) (EApp (EVar "lastOfPM") (EVar "rest")))
(DTypeSig false "lookupExports" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "lookupExports" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupExports" ((PVar "k") (PCons (PTuple (PVar "m") (PVar "ns")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "m")) (EApp (EVar "Some") (EVar "ns")) (EApp (EApp (EVar "lookupExports") (EVar "k")) (EVar "rest"))))
(DTypeSig false "unitDefNames" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "unitDefNames" ((PTuple PWild (PVar "decls"))) (EApp (EApp (EDictApp "flatMap") (EVar "declBinderNames")) (EVar "decls")))
(DTypeSig true "mangledName" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "mangledName" ((PVar "mid") (PVar "name")) (EApp (EApp (EVar "encodePair") (EVar "mid")) (EVar "name")))
(DTypeSig true "sanitizeId" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "sanitizeId" ((PVar "s")) (EApp (EApp (EApp (EApp (EVar "sanitizeGo") (EVar "s")) (ELit (LInt 0))) (EApp (EVar "stringLength") (EVar "s"))) (ELit (LString ""))))
(DTypeSig false "sanitizeGo" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "String"))))))
(DFunDef false "sanitizeGo" ((PVar "s") (PVar "i") (PVar "len") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "len")) (EVar "acc") (EBlock (DoLet false false (PVar "c") (EApp (EApp (EApp (EVar "stringSlice") (EVar "i")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "s"))) (DoLet false false (PVar "c2") (EIf (EApp (EVar "safeChar") (EVar "c")) (EVar "c") (ELit (LString "_")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "sanitizeGo") (EVar "s")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "len")) (EBinOp "++" (EVar "acc") (EVar "c2")))))))
(DTypeSig true "safeChar" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "safeChar" ((PVar "c")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LString "a"))) (EBinOp "<=" (EVar "c") (ELit (LString "z")))) (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LString "A"))) (EBinOp "<=" (EVar "c") (ELit (LString "Z"))))) (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LString "0"))) (EBinOp "<=" (EVar "c") (ELit (LString "9"))))) (EBinOp "==" (EVar "c") (ELit (LString "_")))))
(DTypeSig true "injectiveIdent" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "injectiveIdent" ((PVar "s")) (EIf (EBinOp "&&" (EApp (EApp (EApp (EVar "allSafeChars") (EVar "s")) (ELit (LInt 0))) (EApp (EVar "stringLength") (EVar "s"))) (EApp (EVar "not") (EApp (EVar "startsZZ") (EVar "s")))) (EVar "s") (EBinOp "++" (EBinOp "++" (ELit (LString "zZ")) (EApp (EMethodRef "display") (EApp (EApp (EApp (EApp (EVar "escapeGo") (EVar "s")) (ELit (LInt 0))) (EApp (EVar "stringLength") (EVar "s"))) (ELit (LString ""))))) (ELit (LString "")))))
(DTypeSig false "startsZZ" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "startsZZ" ((PVar "s")) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 2))) (EVar "s")) (ELit (LString "zZ"))))
(DTypeSig false "allSafeChars" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "allSafeChars" ((PVar "s") (PVar "i") (PVar "len")) (EIf (EBinOp ">=" (EVar "i") (EVar "len")) (EVar "True") (EIf (EApp (EVar "safeChar") (EApp (EApp (EApp (EVar "stringSlice") (EVar "i")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "s"))) (EApp (EApp (EApp (EVar "allSafeChars") (EVar "s")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "len")) (EVar "False"))))
(DTypeSig false "escapeGo" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "String"))))))
(DFunDef false "escapeGo" ((PVar "s") (PVar "i") (PVar "len") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "len")) (EVar "acc") (EBlock (DoLet false false (PVar "c") (EApp (EApp (EApp (EVar "stringSlice") (EVar "i")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "s"))) (DoLet false false (PVar "c2") (EIf (EApp (EVar "alnumChar") (EVar "c")) (EVar "c") (EBinOp "++" (EBinOp "++" (ELit (LString "_")) (EApp (EMethodRef "display") (EApp (EVar "hexOfChar") (EVar "c")))) (ELit (LString "_"))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "escapeGo") (EVar "s")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "len")) (EBinOp "++" (EVar "acc") (EVar "c2")))))))
(DTypeSig false "alnumChar" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "alnumChar" ((PVar "c")) (EBinOp "||" (EBinOp "||" (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LString "a"))) (EBinOp "<=" (EVar "c") (ELit (LString "z")))) (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LString "A"))) (EBinOp "<=" (EVar "c") (ELit (LString "Z"))))) (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LString "0"))) (EBinOp "<=" (EVar "c") (ELit (LString "9"))))))
(DTypeSig false "hexOfChar" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "hexOfChar" ((PVar "c")) (EApp (EVar "hexOfInt") (EApp (EVar "charCode") (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 0))) (EApp (EVar "stringToChars") (EVar "c"))))))
(DTypeSig false "hexOfInt" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "hexOfInt" ((PVar "n")) (EIf (EBinOp "<" (EVar "n") (ELit (LInt 16))) (EApp (EVar "hexNibble") (EVar "n")) (EBinOp "++" (EApp (EVar "hexOfInt") (EBinOp "/" (EVar "n") (ELit (LInt 16)))) (EApp (EVar "hexNibble") (EBinOp "%" (EVar "n") (ELit (LInt 16)))))))
(DTypeSig false "hexNibble" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "hexNibble" ((PVar "n")) (EApp (EApp (EApp (EVar "stringSlice") (EVar "n")) (EBinOp "+" (EVar "n") (ELit (LInt 1)))) (ELit (LString "0123456789abcdef"))))
(DTypeSig true "hashName" (TyFun (TyCon "String") (TyCon "Int")))
(DFunDef false "hashName" ((PVar "s")) (EApp (EApp (EApp (EVar "hashChars") (EApp (EVar "stringToChars") (EVar "s"))) (ELit (LInt 0))) (ELit (LInt 5381))))
(DTypeSig false "hashChars" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "hashChars" ((PVar "cs") (PVar "i") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "cs"))) (EVar "acc") (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "hashChars") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "U64.toIntTruncating") (EBinOp "+" (EBinOp "*" (EApp (EVar "U64.truncate") (EVar "acc")) (ELit (LInt 33))) (EApp (EVar "U64.truncate") (EApp (EVar "charCode") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs"))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "dictTag" (TyFun (TyCon "String") (TyCon "Int")))
(DFunDef false "dictTag" ((PVar "s")) (EApp (EApp (EVar "posMod") (EApp (EVar "hashName") (EVar "s"))) (ELit (LInt 1073741824))))
(DTypeSig true "posMod" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "posMod" ((PVar "n") (PVar "m")) (EBinOp "%" (EBinOp "+" (EBinOp "%" (EVar "n") (EVar "m")) (EVar "m")) (EVar "m")))
(DTypeSig false "renameDecl" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "Decl") (TyCon "Decl"))))
(DFunDef false "renameDecl" ((PVar "rm") (PCon "DFunDef" (PVar "pub") (PVar "n") (PVar "ps") (PVar "e") (PVar "site") (PVar "bid"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "pub")) (EApp (EApp (EVar "renameDefName") (EVar "rm")) (EVar "n"))) (EApp (EApp (EVar "renamePatsPM") (EVar "rm")) (EVar "ps"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EApp (EVar "boundOfListPM") (EApp (EVar "patVarsListPM") (EVar "ps")))) (EVar "e"))) (EVar "site")) (EVar "bid")))
(DFunDef false "renameDecl" ((PVar "rm") (PCon "DTypeSig" (PVar "pub") (PVar "n") (PVar "ty") (PVar "site"))) (EApp (EApp (EApp (EApp (EVar "DTypeSig") (EVar "pub")) (EApp (EApp (EVar "renameDefName") (EVar "rm")) (EVar "n"))) (EVar "ty")) (EVar "site")))
(DFunDef false "renameDecl" ((PVar "rm") (PAs "d" (PRec "DInterface" ((rf "methods" None)) true))) (EVariantUpdate "DInterface" (EVar "d") ((fa "methods" (EApp (EApp (EMethodRef "map") (EApp (EVar "renameIfaceMethod") (EVar "rm"))) (EVar "methods"))))))
(DFunDef false "renameDecl" ((PVar "rm") (PAs "d" (PRec "DImpl" ((rf "methods" None)) true))) (EVariantUpdate "DImpl" (EVar "d") ((fa "methods" (EApp (EApp (EMethodRef "map") (EApp (EVar "renameImplMethod") (EVar "rm"))) (EVar "methods"))))))
(DFunDef false "renameDecl" ((PVar "rm") (PCon "DProp" (PVar "pub") (PVar "name") (PVar "params") (PVar "body"))) (EApp (EApp (EApp (EApp (EVar "DProp") (EVar "pub")) (EVar "name")) (EVar "params")) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EApp (EVar "boundOfListPM") (EApp (EVar "propParamNamesPM") (EVar "params")))) (EVar "body"))))
(DFunDef false "renameDecl" ((PVar "rm") (PCon "DTest" (PVar "pub") (PVar "name") (PVar "body"))) (EApp (EApp (EApp (EVar "DTest") (EVar "pub")) (EVar "name")) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "omEmpty")) (EVar "body"))))
(DFunDef false "renameDecl" ((PVar "rm") (PCon "DLetGroup" (PVar "pub") (PVar "binds"))) (EApp (EApp (EVar "DLetGroup") (EVar "pub")) (EApp (EApp (EMethodRef "map") (EApp (EVar "renameLetBindDef") (EVar "rm"))) (EVar "binds"))))
(DFunDef false "renameDecl" ((PVar "rm") (PAs "d" (PRec "DData" ((rf "dataCtors" (PVar "variants"))) false))) (EVariantUpdate "DData" (EVar "d") ((fa "dataCtors" (EApp (EApp (EMethodRef "map") (EApp (EVar "renameVariant") (EVar "rm"))) (EVar "variants"))))))
(DFunDef false "renameDecl" ((PVar "rm") (PAs "d" (PRec "DNewtype" ((rf "newtypeCtor" (PVar "con"))) false))) (EVariantUpdate "DNewtype" (EVar "d") ((fa "newtypeCtor" (EApp (EApp (EVar "renameDefName") (EVar "rm")) (EVar "con"))))))
(DFunDef false "renameDecl" ((PVar "rm") (PCon "DAttrib" (PVar "attrs") (PVar "d"))) (EApp (EApp (EVar "DAttrib") (EVar "attrs")) (EApp (EApp (EVar "renameDecl") (EVar "rm")) (EVar "d"))))
(DFunDef false "renameDecl" ((PVar "rm") (PCon "DExtern" (PVar "ed"))) (EApp (EVar "DExtern") (ERecordUpdate (EVar "ed") ((fa "edName" (EApp (EApp (EVar "renameDefName") (EVar "rm")) (EFieldAccess (EVar "ed") "edName")))))))
(DFunDef false "renameDecl" (PWild (PAs "d" (PCon "DUse" PWild PWild PWild))) (EVar "d"))
(DFunDef false "renameDecl" (PWild (PAs "d" (PCon "DEffect" PWild PWild PWild PWild PWild PWild))) (EVar "d"))
(DFunDef false "renameDecl" (PWild (PAs "d" (PRec "DTypeAlias" ((rf "tyAliasName" PWild)) true))) (EVar "d"))
(DTypeSig false "renameVariant" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "Variant") (TyCon "Variant"))))
(DFunDef false "renameVariant" ((PVar "rm") (PCon "Variant" (PVar "n") (PVar "payload"))) (EApp (EApp (EVar "Variant") (EApp (EApp (EVar "renameDefName") (EVar "rm")) (EVar "n"))) (EVar "payload")))
(DTypeSig false "renameLetBindDef" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "LetBind") (TyCon "LetBind"))))
(DFunDef false "renameLetBindDef" ((PVar "rm") (PCon "LetBind" (PVar "n") (PVar "clauses") (PVar "site") (PVar "bid"))) (EApp (EApp (EApp (EApp (EVar "LetBind") (EApp (EApp (EVar "renameDefName") (EVar "rm")) (EVar "n"))) (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "renameFunClause") (EVar "rm")) (EVar "omEmpty"))) (EVar "clauses"))) (EVar "site")) (EVar "bid")))
(DTypeSig false "renameDefName" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "renameDefName" ((PVar "rm") (PVar "n")) (EApp (EApp (EVar "optionOr") (EVar "n")) (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "rm"))))
(DTypeSig false "renameIfaceMethod" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "IfaceMethod") (TyCon "IfaceMethod"))))
(DFunDef false "renameIfaceMethod" (PWild (PCon "IfaceMethod" (PVar "n") (PVar "ty") (PCon "None") (PVar "mloc"))) (EApp (EApp (EApp (EApp (EVar "IfaceMethod") (EVar "n")) (EVar "ty")) (EVar "None")) (EVar "mloc")))
(DFunDef false "renameIfaceMethod" ((PVar "rm") (PCon "IfaceMethod" (PVar "n") (PVar "ty") (PCon "Some" (PCon "MethodDefault" (PVar "ps") (PVar "e"))) (PVar "mloc"))) (EApp (EApp (EApp (EApp (EVar "IfaceMethod") (EVar "n")) (EVar "ty")) (EApp (EVar "Some") (EApp (EApp (EVar "MethodDefault") (EApp (EApp (EVar "renamePatsPM") (EVar "rm")) (EVar "ps"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EApp (EVar "boundOfListPM") (EApp (EVar "patVarsListPM") (EVar "ps")))) (EVar "e"))))) (EVar "mloc")))
(DTypeSig false "renameImplMethod" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "ImplMethod") (TyCon "ImplMethod"))))
(DFunDef false "renameImplMethod" ((PVar "rm") (PCon "ImplMethod" (PVar "n") (PVar "ps") (PVar "e"))) (EApp (EApp (EApp (EVar "ImplMethod") (EVar "n")) (EApp (EApp (EVar "renamePatsPM") (EVar "rm")) (EVar "ps"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EApp (EVar "boundOfListPM") (EApp (EVar "patVarsListPM") (EVar "ps")))) (EVar "e"))))
(DTypeSig false "propParamNamesPM" (TyFun (TyApp (TyCon "List") (TyCon "PropParam")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "propParamNamesPM" ((PVar "ps")) (EApp (EApp (EMethodRef "map") (EVar "propParamNamePM")) (EVar "ps")))
(DTypeSig false "propParamNamePM" (TyFun (TyCon "PropParam") (TyCon "String")))
(DFunDef false "propParamNamePM" ((PCon "PropParam" (PVar "n") PWild PWild)) (EVar "n"))
(DTypeSig false "boundInsertPM" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit")))))
(DFunDef false "boundInsertPM" ((PList) (PVar "b")) (EVar "b"))
(DFunDef false "boundInsertPM" ((PCons (PVar "n") (PVar "rest")) (PVar "b")) (EApp (EApp (EVar "boundInsertPM") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (ELit LUnit)) (EVar "b"))))
(DTypeSig false "boundOfListPM" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "OrdMap") (TyCon "Unit"))))
(DFunDef false "boundOfListPM" ((PVar "ns")) (EApp (EApp (EVar "boundInsertPM") (EVar "ns")) (EVar "omEmpty")))
(DTypeSig false "renameScoped" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EVar" (PVar "n"))) (EIf (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "bound"))) (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "rm")) (arm (PCon "Some" (PVar "n2")) () (EApp (EVar "EVar") (EVar "n2"))) (arm (PCon "None") () (EApp (EVar "EVar") (EVar "n")))) (EIf (EVar "otherwise") (EApp (EVar "EVar") (EVar "n")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EVarId" (PVar "n") PWild)) (EIf (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "bound"))) (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "rm")) (arm (PCon "Some" (PVar "n2")) () (EApp (EVar "EVar") (EVar "n2"))) (arm (PCon "None") () (EApp (EVar "EVar") (EVar "n")))) (EIf (EVar "otherwise") (EApp (EVar "EVar") (EVar "n")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EVarAt" (PVar "n") (PVar "addr"))) (EIf (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "bound"))) (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "rm")) (arm (PCon "Some" (PVar "n2")) () (EApp (EApp (EVar "EVarAt") (EVar "n2")) (EVar "addr"))) (arm (PCon "None") () (EApp (EApp (EVar "EVarAt") (EVar "n")) (EVar "addr")))) (EIf (EVar "otherwise") (EApp (EApp (EVar "EVarAt") (EVar "n")) (EVar "addr")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "ELam" (PVar "ps") (PVar "body"))) (EApp (EApp (EVar "ELam") (EApp (EApp (EVar "renamePatsPM") (EVar "rm")) (EVar "ps"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EApp (EApp (EVar "boundInsertPM") (EApp (EVar "patVarsListPM") (EVar "ps"))) (EVar "bound"))) (EVar "body"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "ELet" (PVar "m") (PVar "r") (PVar "p") (PVar "e1") (PVar "e2"))) (EBlock (DoLet false false (PVar "pv") (EApp (EVar "patVarsPM") (EVar "p"))) (DoLet false false (PVar "b1") (EIf (EVar "r") (EApp (EApp (EVar "boundInsertPM") (EVar "pv")) (EVar "bound")) (EVar "bound"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "ELet") (EVar "m")) (EVar "r")) (EApp (EApp (EVar "renamePat") (EVar "rm")) (EVar "p"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "b1")) (EVar "e1"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EApp (EApp (EVar "boundInsertPM") (EVar "pv")) (EVar "bound"))) (EVar "e2"))))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "ELetGroup" (PVar "binds") (PVar "e2"))) (EBlock (DoLet false false (PVar "bnd") (EApp (EApp (EVar "boundInsertPM") (EApp (EVar "letBindNamesPM") (EVar "binds"))) (EVar "bound"))) (DoExpr (EApp (EApp (EVar "ELetGroup") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "renameLetBind") (EVar "rm")) (EVar "bnd"))) (EVar "binds"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bnd")) (EVar "e2"))))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EMatch" (PVar "e0") (PVar "arms"))) (EApp (EApp (EVar "EMatch") (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e0"))) (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "renameArm") (EVar "rm")) (EVar "bound"))) (EVar "arms"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EBlock" (PVar "stmts"))) (EApp (EVar "EBlock") (EApp (EApp (EApp (EVar "renameStmts") (EVar "rm")) (EVar "bound")) (EVar "stmts"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EDo" (PVar "d") (PVar "stmts"))) (EApp (EApp (EVar "EDo") (EVar "d")) (EApp (EApp (EApp (EVar "renameStmts") (EVar "rm")) (EVar "bound")) (EVar "stmts"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "ELoc" (PVar "l") (PVar "e"))) (EApp (EApp (EVar "ELoc") (EVar "l")) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EDoOrigin" (PVar "l") (PVar "e"))) (EApp (EApp (EVar "EDoOrigin") (EVar "l")) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EApp" (PVar "f") (PVar "x"))) (EApp (EApp (EVar "EApp") (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "f"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "x"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EIf" (PVar "c") (PVar "t") (PVar "e"))) (EApp (EApp (EApp (EVar "EIf") (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "c"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "t"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EBinOp" (PVar "op") (PVar "l") (PVar "r") (PVar "dr"))) (EApp (EApp (EApp (EApp (EVar "EBinOp") (EVar "op")) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "l"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "r"))) (EVar "dr")))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EUnOp" (PVar "op") (PVar "x") (PVar "dr"))) (EApp (EApp (EApp (EVar "EUnOp") (EVar "op")) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "x"))) (EVar "dr")))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EInfix" (PVar "op") (PVar "l") (PVar "r"))) (EApp (EApp (EApp (EVar "EInfix") (EVar "op")) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "l"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "r"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EFieldAccess" (PVar "e0") (PVar "n") (PVar "ev"))) (EApp (EApp (EApp (EVar "EFieldAccess") (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e0"))) (EVar "n")) (EVar "ev")))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "ETuple" (PVar "es"))) (EApp (EVar "ETuple") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound"))) (EVar "es"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EListLit" (PVar "es"))) (EApp (EVar "EListLit") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound"))) (EVar "es"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EArrayLit" (PVar "es"))) (EApp (EVar "EArrayLit") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound"))) (EVar "es"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "ERangeList" (PVar "lo") (PVar "hi") (PVar "i"))) (EApp (EApp (EApp (EVar "ERangeList") (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "lo"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "hi"))) (EVar "i")))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "ERangeArray" (PVar "lo") (PVar "hi") (PVar "i"))) (EApp (EApp (EApp (EVar "ERangeArray") (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "lo"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "hi"))) (EVar "i")))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "ESlice" (PVar "e0") (PVar "lo") (PVar "hi") (PVar "i"))) (EApp (EApp (EApp (EApp (EVar "ESlice") (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e0"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "lo"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "hi"))) (EVar "i")))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EIndex" (PVar "e0") (PVar "i"))) (EApp (EApp (EVar "EIndex") (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e0"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "i"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EAnnot" (PVar "e0") (PVar "t"))) (EApp (EApp (EVar "EAnnot") (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e0"))) (EVar "t")))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EHeadAnnot" (PVar "e0") (PVar "t"))) (EApp (EApp (EVar "EHeadAnnot") (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e0"))) (EVar "t")))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "ERecordCreate" (PVar "n") (PVar "fs"))) (EApp (EApp (EVar "ERecordCreate") (EApp (EApp (EVar "renameDefName") (EVar "rm")) (EVar "n"))) (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "renameField") (EVar "rm")) (EVar "bound"))) (EVar "fs"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "ERecordUpdate" (PVar "e0") (PVar "fs") (PVar "ev"))) (EApp (EApp (EApp (EVar "ERecordUpdate") (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e0"))) (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "renameField") (EVar "rm")) (EVar "bound"))) (EVar "fs"))) (EVar "ev")))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EVariantUpdate" (PVar "c") (PVar "e0") (PVar "fs"))) (EApp (EApp (EApp (EVar "EVariantUpdate") (EApp (EApp (EVar "renameDefName") (EVar "rm")) (EVar "c"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e0"))) (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "renameField") (EVar "rm")) (EVar "bound"))) (EVar "fs"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EStringInterp" (PVar "parts"))) (EApp (EVar "EStringInterp") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "renameInterp") (EVar "rm")) (EVar "bound"))) (EVar "parts"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EGuards" (PVar "arms"))) (EApp (EVar "EGuards") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "renameGuardArm") (EVar "rm")) (EVar "bound"))) (EVar "arms"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "ESection" (PCon "SecRight" (PVar "op") (PVar "e0")))) (EApp (EVar "ESection") (EApp (EApp (EVar "SecRight") (EVar "op")) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e0")))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "ESection" (PCon "SecLeft" (PVar "e0") (PVar "op")))) (EApp (EVar "ESection") (EApp (EApp (EVar "SecLeft") (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e0"))) (EVar "op"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EMapLit" (PVar "n") (PVar "kvs"))) (EApp (EApp (EVar "EMapLit") (EVar "n")) (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "renameKv") (EVar "rm")) (EVar "bound"))) (EVar "kvs"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "ESetLit" (PVar "n") (PVar "es"))) (EApp (EApp (EVar "ESetLit") (EVar "n")) (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound"))) (EVar "es"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EAsPat" (PVar "x") (PVar "sub"))) (EApp (EApp (EVar "EAsPat") (EVar "x")) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EMethodRef "sub"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EOrPat" (PVar "es"))) (EApp (EVar "EOrPat") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound"))) (EVar "es"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EDictAt" (PVar "n") (PVar "ev"))) (EIf (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "bound")) (EApp (EApp (EVar "EDictAt") (EVar "n")) (EVar "ev")) (EIf (EVar "otherwise") (EApp (EApp (EVar "EDictAt") (EApp (EApp (EVar "renameDefName") (EVar "rm")) (EVar "n"))) (EVar "ev")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "renameScoped" ((PVar "rm") PWild (PCon "EMethodAt" (PVar "m") (PVar "seed") (PVar "ev"))) (EApp (EApp (EApp (EVar "EMethodAt") (EVar "m")) (EApp (EApp (EVar "renameDefName") (EVar "rm")) (EVar "seed"))) (EVar "ev")))
(DFunDef false "renameScoped" (PWild PWild (PAs "e" (PCon "ELit" PWild))) (EVar "e"))
(DFunDef false "renameScoped" (PWild PWild (PAs "e" (PCon "ENumLit" PWild PWild PWild))) (EVar "e"))
(DFunDef false "renameScoped" (PWild PWild (PAs "e" (PCon "EWideLit" PWild PWild PWild PWild))) (EVar "e"))
(DFunDef false "renameScoped" (PWild PWild (PAs "e" (PCon "EMethodRef" PWild))) (EVar "e"))
(DFunDef false "renameScoped" (PWild PWild (PAs "e" (PCon "EDictApp" PWild))) (EVar "e"))
(DFunDef false "renameScoped" (PWild PWild (PAs "e" (PCon "ESection" (PCon "SecBare" PWild)))) (EVar "e"))
(DTypeSig false "renameField" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "FieldAssign") (TyCon "FieldAssign")))))
(DFunDef false "renameField" ((PVar "rm") (PVar "bound") (PCon "FieldAssign" (PVar "n") (PVar "e"))) (EApp (EApp (EVar "FieldAssign") (EVar "n")) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e"))))
(DTypeSig false "renameKv" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyTuple (TyCon "Expr") (TyCon "Expr")) (TyTuple (TyCon "Expr") (TyCon "Expr"))))))
(DFunDef false "renameKv" ((PVar "rm") (PVar "bound") (PTuple (PVar "k") (PVar "v"))) (ETuple (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "k")) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "v"))))
(DTypeSig false "renameInterp" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "InterpPart") (TyCon "InterpPart")))))
(DFunDef false "renameInterp" (PWild PWild (PCon "InterpStr" (PVar "s"))) (EApp (EVar "InterpStr") (EVar "s")))
(DFunDef false "renameInterp" ((PVar "rm") (PVar "bound") (PCon "InterpExpr" (PVar "e"))) (EApp (EVar "InterpExpr") (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e"))))
(DTypeSig false "renameLetBind" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "LetBind") (TyCon "LetBind")))))
(DFunDef false "renameLetBind" ((PVar "rm") (PVar "bound") (PCon "LetBind" (PVar "n") (PVar "clauses") (PVar "site") (PVar "bid"))) (EApp (EApp (EApp (EApp (EVar "LetBind") (EVar "n")) (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "renameFunClause") (EVar "rm")) (EVar "bound"))) (EVar "clauses"))) (EVar "site")) (EVar "bid")))
(DTypeSig false "renameFunClause" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "FunClause") (TyCon "FunClause")))))
(DFunDef false "renameFunClause" ((PVar "rm") (PVar "bound") (PCon "FunClause" (PVar "ps") (PVar "body"))) (EApp (EApp (EVar "FunClause") (EApp (EApp (EVar "renamePatsPM") (EVar "rm")) (EVar "ps"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EApp (EApp (EVar "boundInsertPM") (EApp (EVar "patVarsListPM") (EVar "ps"))) (EVar "bound"))) (EVar "body"))))
(DTypeSig false "renameArm" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "Arm") (TyCon "Arm")))))
(DFunDef false "renameArm" ((PVar "rm") (PVar "bound") (PCon "Arm" (PVar "p") (PVar "gs") (PVar "body"))) (EBlock (DoLet false false (PVar "b0") (EApp (EApp (EVar "boundInsertPM") (EApp (EVar "patVarsPM") (EVar "p"))) (EVar "bound"))) (DoLet false false (PTuple (PVar "gs2") (PVar "bnd")) (EApp (EApp (EApp (EVar "renameGuards") (EVar "rm")) (EVar "b0")) (EVar "gs"))) (DoExpr (EApp (EApp (EApp (EVar "Arm") (EApp (EApp (EVar "renamePat") (EVar "rm")) (EVar "p"))) (EVar "gs2")) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bnd")) (EVar "body"))))))
(DTypeSig false "renameGuardArm" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "GuardArm") (TyCon "GuardArm")))))
(DFunDef false "renameGuardArm" ((PVar "rm") (PVar "bound") (PCon "GuardArm" (PVar "gs") (PVar "body"))) (EBlock (DoLet false false (PTuple (PVar "gs2") (PVar "bnd")) (EApp (EApp (EApp (EVar "renameGuards") (EVar "rm")) (EVar "bound")) (EVar "gs"))) (DoExpr (EApp (EApp (EVar "GuardArm") (EVar "gs2")) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bnd")) (EVar "body"))))))
(DTypeSig false "renameGuards" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "Guard")) (TyTuple (TyApp (TyCon "List") (TyCon "Guard")) (TyApp (TyCon "OrdMap") (TyCon "Unit")))))))
(DFunDef false "renameGuards" (PWild (PVar "bound") (PList)) (ETuple (EListLit) (EVar "bound")))
(DFunDef false "renameGuards" ((PVar "rm") (PVar "bound") (PCons (PCon "GBool" (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false (PVar "e2") (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e"))) (DoLet false false (PTuple (PVar "rest2") (PVar "bnd")) (EApp (EApp (EApp (EVar "renameGuards") (EVar "rm")) (EVar "bound")) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EApp (EVar "GBool") (EVar "e2")) (EVar "rest2")) (EVar "bnd")))))
(DFunDef false "renameGuards" ((PVar "rm") (PVar "bound") (PCons (PCon "GBind" (PVar "p") (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false (PVar "e2") (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e"))) (DoLet false false (PTuple (PVar "rest2") (PVar "bnd")) (EApp (EApp (EApp (EVar "renameGuards") (EVar "rm")) (EApp (EApp (EVar "boundInsertPM") (EApp (EVar "patVarsPM") (EVar "p"))) (EVar "bound"))) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EApp (EApp (EVar "GBind") (EApp (EApp (EVar "renamePat") (EVar "rm")) (EVar "p"))) (EVar "e2")) (EVar "rest2")) (EVar "bnd")))))
(DTypeSig false "renameStmts" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyApp (TyCon "List") (TyCon "DoStmt"))))))
(DFunDef false "renameStmts" (PWild PWild (PList)) (EListLit))
(DFunDef false "renameStmts" ((PVar "rm") (PVar "bound") (PCons (PCon "DoExpr" (PVar "e")) (PVar "rest"))) (EBinOp "::" (EApp (EVar "DoExpr") (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e"))) (EApp (EApp (EApp (EVar "renameStmts") (EVar "rm")) (EVar "bound")) (EVar "rest"))))
(DFunDef false "renameStmts" ((PVar "rm") (PVar "bound") (PCons (PCon "DoBind" (PVar "p") (PVar "e")) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EVar "DoBind") (EApp (EApp (EVar "renamePat") (EVar "rm")) (EVar "p"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e"))) (EApp (EApp (EApp (EVar "renameStmts") (EVar "rm")) (EApp (EApp (EVar "boundInsertPM") (EApp (EVar "patVarsPM") (EVar "p"))) (EVar "bound"))) (EVar "rest"))))
(DFunDef false "renameStmts" ((PVar "rm") (PVar "bound") (PCons (PCon "DoLet" (PVar "m") (PVar "r") (PVar "p") (PVar "e") (PVar "site")) (PVar "rest"))) (EBlock (DoLet false false (PVar "b1") (EIf (EVar "r") (EApp (EApp (EVar "boundInsertPM") (EApp (EVar "patVarsPM") (EVar "p"))) (EVar "bound")) (EVar "bound"))) (DoExpr (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EVar "DoLet") (EVar "m")) (EVar "r")) (EApp (EApp (EVar "renamePat") (EVar "rm")) (EVar "p"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "b1")) (EVar "e"))) (EVar "site")) (EApp (EApp (EApp (EVar "renameStmts") (EVar "rm")) (EApp (EApp (EVar "boundInsertPM") (EApp (EVar "patVarsPM") (EVar "p"))) (EVar "bound"))) (EVar "rest"))))))
(DFunDef false "renameStmts" ((PVar "rm") (PVar "bound") (PCons (PCon "DoAssign" (PVar "x") (PVar "e")) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EVar "DoAssign") (EVar "x")) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e"))) (EApp (EApp (EApp (EVar "renameStmts") (EVar "rm")) (EVar "bound")) (EVar "rest"))))
(DFunDef false "renameStmts" ((PVar "rm") (PVar "bound") (PCons (PCon "DoFieldAssign" (PVar "x") (PVar "fs") (PVar "e")) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EApp (EVar "DoFieldAssign") (EVar "x")) (EVar "fs")) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e"))) (EApp (EApp (EApp (EVar "renameStmts") (EVar "rm")) (EVar "bound")) (EVar "rest"))))
(DTypeSig false "letBindNamesPM" (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "letBindNamesPM" ((PVar "binds")) (EApp (EApp (EMethodRef "map") (EVar "letBindName")) (EVar "binds")))
(DTypeSig false "patVarsPM" (TyFun (TyCon "Pat") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "patVarsPM" ((PCon "PVar" (PVar "x") PWild PWild)) (EListLit (EVar "x")))
(DFunDef false "patVarsPM" ((PCon "PCon" PWild (PVar "args"))) (EApp (EVar "patVarsListPM") (EVar "args")))
(DFunDef false "patVarsPM" ((PCon "PCons" (PVar "h") (PVar "t"))) (EBinOp "++" (EApp (EVar "patVarsPM") (EVar "h")) (EApp (EVar "patVarsPM") (EVar "t"))))
(DFunDef false "patVarsPM" ((PCon "PTuple" (PVar "ps"))) (EApp (EVar "patVarsListPM") (EVar "ps")))
(DFunDef false "patVarsPM" ((PCon "PList" (PVar "ps"))) (EApp (EVar "patVarsListPM") (EVar "ps")))
(DFunDef false "patVarsPM" ((PCon "PAs" (PVar "x") PWild PWild (PVar "p"))) (EBinOp "::" (EVar "x") (EApp (EVar "patVarsPM") (EVar "p"))))
(DFunDef false "patVarsPM" ((PCon "POr" (PCons (PVar "p") PWild))) (EApp (EVar "patVarsPM") (EVar "p")))
(DFunDef false "patVarsPM" ((PCon "PRec" PWild (PVar "fields") PWild)) (EApp (EApp (EDictApp "flatMap") (EVar "recPatFieldVarsPM")) (EVar "fields")))
(DFunDef false "patVarsPM" (PWild) (EListLit))
(DTypeSig false "patVarsListPM" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "patVarsListPM" ((PVar "ps")) (EApp (EApp (EDictApp "flatMap") (EVar "patVarsPM")) (EVar "ps")))
(DTypeSig false "renamePat" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "Pat") (TyCon "Pat"))))
(DFunDef false "renamePat" ((PVar "rm") (PCon "PCon" (PVar "n") (PVar "args"))) (EApp (EApp (EVar "PCon") (EApp (EApp (EVar "renameDefName") (EVar "rm")) (EVar "n"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "renamePat") (EVar "rm"))) (EVar "args"))))
(DFunDef false "renamePat" ((PVar "rm") (PCon "PCons" (PVar "h") (PVar "t"))) (EApp (EApp (EVar "PCons") (EApp (EApp (EVar "renamePat") (EVar "rm")) (EVar "h"))) (EApp (EApp (EVar "renamePat") (EVar "rm")) (EVar "t"))))
(DFunDef false "renamePat" ((PVar "rm") (PCon "PTuple" (PVar "ps"))) (EApp (EVar "PTuple") (EApp (EApp (EMethodRef "map") (EApp (EVar "renamePat") (EVar "rm"))) (EVar "ps"))))
(DFunDef false "renamePat" ((PVar "rm") (PCon "PList" (PVar "ps"))) (EApp (EVar "PList") (EApp (EApp (EMethodRef "map") (EApp (EVar "renamePat") (EVar "rm"))) (EVar "ps"))))
(DFunDef false "renamePat" ((PVar "rm") (PCon "PAs" (PVar "x") (PVar "l") (PVar "bid") (PVar "p"))) (EApp (EApp (EApp (EApp (EVar "PAs") (EVar "x")) (EVar "l")) (EVar "bid")) (EApp (EApp (EVar "renamePat") (EVar "rm")) (EVar "p"))))
(DFunDef false "renamePat" ((PVar "rm") (PCon "POr" (PVar "ps"))) (EApp (EVar "POr") (EApp (EApp (EMethodRef "map") (EApp (EVar "renamePat") (EVar "rm"))) (EVar "ps"))))
(DFunDef false "renamePat" ((PVar "rm") (PCon "PRec" (PVar "n") (PVar "fields") (PVar "open"))) (EApp (EApp (EApp (EVar "PRec") (EApp (EApp (EVar "renameDefName") (EVar "rm")) (EVar "n"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "renameRecPatField") (EVar "rm"))) (EVar "fields"))) (EVar "open")))
(DFunDef false "renamePat" (PWild (PAs "p" (PCon "PVar" PWild PWild PWild))) (EVar "p"))
(DFunDef false "renamePat" (PWild (PAs "p" (PCon "PWild"))) (EVar "p"))
(DFunDef false "renamePat" (PWild (PAs "p" (PCon "PLit" PWild))) (EVar "p"))
(DFunDef false "renamePat" (PWild (PAs "p" (PCon "PRng" PWild PWild PWild))) (EVar "p"))
(DTypeSig false "renameRecPatField" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "RecPatField") (TyCon "RecPatField"))))
(DFunDef false "renameRecPatField" (PWild (PCon "RecPatField" (PVar "label") (PVar "l") (PVar "bid") (PCon "None"))) (EApp (EApp (EApp (EApp (EVar "RecPatField") (EVar "label")) (EVar "l")) (EVar "bid")) (EVar "None")))
(DFunDef false "renameRecPatField" ((PVar "rm") (PCon "RecPatField" (PVar "label") (PVar "l") (PVar "bid") (PCon "Some" (PVar "p")))) (EApp (EApp (EApp (EApp (EVar "RecPatField") (EVar "label")) (EVar "l")) (EVar "bid")) (EApp (EVar "Some") (EApp (EApp (EVar "renamePat") (EVar "rm")) (EVar "p")))))
(DTypeSig false "renamePatsPM" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyApp (TyCon "List") (TyCon "Pat")))))
(DFunDef false "renamePatsPM" ((PVar "rm") (PVar "ps")) (EApp (EApp (EMethodRef "map") (EApp (EVar "renamePat") (EVar "rm"))) (EVar "ps")))
(DTypeSig false "recPatFieldVarsPM" (TyFun (TyCon "RecPatField") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "recPatFieldVarsPM" ((PCon "RecPatField" (PVar "label") PWild PWild (PCon "None"))) (EListLit (EVar "label")))
(DFunDef false "recPatFieldVarsPM" ((PCon "RecPatField" PWild PWild PWild (PCon "Some" (PVar "p")))) (EApp (EVar "patVarsPM") (EVar "p")))
