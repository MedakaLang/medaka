# META
source_lines=1425
stages=DESUGAR,MARK
# SOURCE
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
-- The per-unit import structure comes straight from the unit's `DUse` decls + the
-- per-module set of EXPORTED (pub) function names — both already present at the
-- mangle point (the `(mid, decls)` units).  No resolve.mdk change is needed: a
-- per-unit LOCAL-name → origin-module map is sufficient.
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
--   • the entry `main` — the emitter emits it as `@main`, the program entry point
--     (llvm_emit.mdk `isFnBind (CBind "main" _) = False`); renaming it would lose
--     the entry.  Excluded as both a definition and a reference target.
--   • externs / runtime C symbols (`@mdk_<externName>` → runtime/medaka_rt.c) —
--     they are declared in runtime.mdk (NOT in core/modules), so they never appear
--     as a definition here; a reference to one is excluded by rule 4 (not in any
--     unit's defined-fn set nor import scope).
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
-- This runs PER UNIT, BEFORE elaborateModules flattens the boundaries away.  It
-- lives ONLY in the emit drivers (never the oracle/golden drivers), so every
-- golden/oracle dump is unchanged.  The gates diff program OUTPUT, so a consistent
-- rename is invisible to them — but a reference rewritten to the WRONG origin
-- module's symbol changes output and is caught.
--
-- The reference rewrite is SCOPE-AWARE: a reference to top-level `f` is renamed
-- only where `f` is the FREE top-level name, NOT where a local binder (parameter /
-- let / lambda arg / match-pattern var) named `f` shadows it.  Mirrors the
-- binder-threading of typecheck.mdk's `rewriteArgScoped`.

import frontend.ast.{
  Decl(..),
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
  qualifiedLocal,
  Variant(..),
  DataVis(..),
}
import support.util.{
  contains,
  reverseL,
  isEmptyL,
  filterList,
  initList,
  joinDot,
  dedup,
  dedupBy,
}
-- The per-unit rename map is applied to EVERY reference in the unit (one lookup
-- per EVar / def-name / pattern ctor). Backing it with the String-keyed
-- weight-balanced tree (support.ordmap) makes each lookup O(log n) instead of an
-- O(map) linear `lookupAssoc` scan — the map is built once per unit in mangleUnitU.
import support.ordmap.{
  OrdMap,
  omInsert,
  omLookup,
  omFromPairs,
  omFromNames,
  omHasKey,
  omEmpty,
  omSize,
}

-- ── entry point ───────────────────────────────────────────────────────────────
-- Given the core unit and every (mid, decls) module, module-qualify EVERY
-- top-level function (except `main` / excluded), rewriting all references
-- import-aware to their origin module's mangled name.  Returns the rewritten
-- (coreDecls, modules) in the same shape `runEmit` already threads to
-- elaborateModules.
export
mangleUnits : List Decl -> List (String, List Decl) -> (List Decl, List (String, List Decl))
mangleUnits coreDecls modules =
  let allUnits = ("core", coreDecls)::modules
  let _ = symbolInjectivityGuard allUnits
  let exportsPerUnit = buildExportsPerUnit [] allUnits
  let ctorExportsPerUnit = map unitCtorExportEntry allUnits
  let coreOut = mangleUnitU exportsPerUnit ctorExportsPerUnit ("core", coreDecls)
  let modsOut = map (mangleModule exportsPerUnit ctorExportsPerUnit) modules
  (coreOut, modsOut)

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
-- ⚠️ NOT a total fix for #1292.  Two residuals stay live, both recorded rather than
-- silently inherited:
--   * a program that collides on the spellings `Pass`/`Fail` (the exemption);
--   * an alias-qualified constructor reference (`import m as A` … `A.Ctor`) —
--     `useCtorPathEntries`' `UseAlias` arm contributes no entry, so such a
--     reference is left bare while the definition is renamed.  Colliding-ctor
--     programs only; it fails LOUDLY (unbound) rather than silently.
export
mangleCtorCollisions : List Decl -> List (String, List Decl) -> (List Decl, List (String, List Decl))
mangleCtorCollisions coreDecls modules =
  let allUnits = ("core", coreDecls)::modules
  let collided = collidingCtorNames allUnits
  if omSize collided == 0 then (coreDecls, modules)
  else
    let ctorExportsPerUnit = map unitCtorExportEntry allUnits
    let coreOut = mangleCtorUnitU collided ctorExportsPerUnit ("core", coreDecls)
    let modsOut = map (mangleCtorModule collided ctorExportsPerUnit) modules
    (coreOut, modsOut)

-- pair-shaped convenience wrapper: `elaborateModules` returns exactly this pair,
-- and every caller that needs the renamed decls back (not just a renamed env)
-- wraps its result.
export
mangleCtorCollisionsPair : (List Decl, List (String, List Decl)) -> (List Decl, List (String, List Decl))
mangleCtorCollisionsPair (coreDecls, modules) =
  mangleCtorCollisions coreDecls modules

-- the constructor names DECLARED by two or more distinct units, as a set.
-- Per-unit `dedup` first, so one unit declaring a name twice (which is a resolve
-- error, not a cross-module collision) never enters the set on its own.
collidingCtorNames : List (String, List Decl) -> OrdMap Unit
collidingCtorNames units =
  collidedGo (flatMap unitMangleCtorNames units) omEmpty omEmpty

collidedGo : List String -> OrdMap Unit -> OrdMap Unit -> OrdMap Unit
collidedGo [] _ dup = dup
collidedGo (n::rest) seen dup
  | omHasKey n seen = collidedGo rest seen (omInsert n () dup)
  | otherwise = collidedGo rest (omInsert n () seen) dup

-- ⚠️ DATA constructors only -- `unitLocalCtorNames`' `DNewtype` arm is deliberately
-- NOT consulted here.  A newtype constructor is not importable by ANY spelling (see
-- `unitCtorExportEntry`'s #1305 note), so counting one as a collision would rename a
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
-- reads a `test "…"` body's result as `VCon "Pass" []` / `VCon "Fail" [_]`
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

mangleCtorModule : OrdMap Unit -> List (String, List (String, List String)) -> (String, List Decl) -> (String, List Decl)
mangleCtorModule collided ctorExportsPerUnit (mid, decls) =
  (mid, mangleCtorUnitU collided ctorExportsPerUnit (mid, decls))

-- `mangleUnitU`'s constructor half, with the map filtered down to colliding keys
-- and the function half omitted entirely.
mangleCtorUnitU : OrdMap Unit -> List (String, List (String, List String)) -> (String, List Decl) -> List Decl
mangleCtorUnitU collided ctorExportsPerUnit (mid, decls) =
  let rmList = filterList (renameKeyCollides collided) (buildUnitCtorRenameMap mid ctorExportsPerUnit decls)
  let rm = omFromPairs (reverseL rmList) omEmpty
  if isEmptyL rmList then decls else map (renameDecl rm) decls

renameKeyCollides : OrdMap Unit -> (String, String) -> Bool
renameKeyCollides collided (n, _) = omHasKey n collided

-- ── emitted-symbol injectivity guard (X-L.H / #348 / #748; drains #1677) ──────
-- `mangledName` is `"\{sanitizeId mid}__\{name}"`, and `sanitizeId` is MANY-TO-ONE
-- (`lib_plain.mdk` and `lib/plain.mdk` both sanitize to `lib_plain`).  Two distinct
-- `(module, name)` pre-images could therefore land on ONE emitted symbol, and
-- nothing downstream noticed: `core_ir_lower.lgGroup`'s bare-name merge folds them
-- into one `define` with an unreachable second clause, the binary links, runs the
-- wrong one, and exits 0 with no diagnostic anywhere (#1677's pinned repro).
--
-- This turns that fold into a build refusal, at the ONE site every emit driver
-- already funnels through, so all eight callers inherit it (VAL-EMIT-001) instead
-- of six per-driver copies desyncing.  The mangling SCHEME is unchanged: this only
-- observes the map `mangleUnitU` is about to build.
--
-- SCOPE — deliberately stated, because a partial check cited as a total one is how
-- this bug class survives:
--   * covers the MODULE-MANGLED domain only — the definition sites `mangleUnitU`
--     renames: top-level functions (`unitDefNames`, `main` excluded exactly as
--     `localRenameEntry` excludes it) and local constructors (`unitLocalCtorNames`,
--     reserved fixed-tag ctors already filtered out).  Ctors travel the identical
--     `mangledName`/`sanitizeId` collapse, so leaving them out would leave half the
--     map unchecked while claiming the map is injective for distinct module ids.
--   * does NOT cover emitter-MINTED symbols (gensym'd lambdas/etas/impls, and
--     `llvm_emit.ensureDefaultEmitted`'s `fname`-keyed dedup-on-mint, which silently
--     suppresses a second definition of an already-minted name).  Those pre-images
--     do not exist here.  This guard does not make that domain safe.
--   * the `(module, name) -> symbol` map is made injective ONLY for DISTINCT module
--     ids.  `checkSymbolsInjective`'s `prev == pre` skip (below) treats two entries
--     with the SAME pre-image label as one pre-image seen twice, so two distinct
--     source units that happen to share ONE canonical module id collapse invisibly
--     — this guard cannot see them.  Whether THAT literal blind spot is reachable
--     (two DISTINCT modules BOTH loaded, BOTH reaching `checkSymbolsInjective`,
--     colliding on module id) remains UNPROVEN either way — neither confirmed nor
--     derived unreachable.
--   * #1792 CONFIRMED reachable (not merely theoretical) a DIFFERENT, upstream
--     claim: entry-path substitution at LOAD time, not the guard mis-handling two
--     loaded modules.  `moduleIdOfPath` (`driver/loader.mdk`) collapses a flat file
--     with a literal `.` in its name (`<root>/a.b.mdk`) and a nested file
--     (`<root>/a/b.mdk`) to the identical module id "a.b", and
--     `loadProgramFilesE` resolves the entry's file BY that collapsed id
--     (`fileOfModuleId`) rather than by the entry's own path, so only ONE file is
--     ever loaded: `medaka run <root>/a.b.mdk` silently loads and runs
--     `<root>/a/b.mdk`'s bytes instead — exit 0, no diagnostic. The flat file's own
--     content never reaches the guard at all. Repro: `test/must_fail_fixtures/
--     1792-flat-dotted-file-collides-nested-path/`.
-- Functions and constructors are checked as SEPARATE domains: they are emitted into
-- separate symbol namespaces (a ctor becomes `@mdk_ctorpap_<sym>_<n>`), so merging
-- them could only manufacture a false positive, never catch a real collision.
--
-- INTENTIONALLY OVER-INCLUSIVE (RUN-EMIT-018): it refuses on the NAME MAP, never on
-- reachability.  `dce.dceFilter` runs AFTER this site in every driver, and
-- non-uniformly across them (`llvm_emit_modules_main` half 0 only,
-- `wasm_emit_gaps_main` not at all), so a DCE-aware check would refuse different
-- programs per driver.  A collision masked only because one side is currently dead
-- is a latent silent mis-link waiting for the edit that makes it live.
symbolInjectivityGuard : List (String, List Decl) -> Unit
symbolInjectivityGuard allUnits =
  let _ = checkSymbolsInjective "function" (flatMap unitFnSymbolPairs allUnits) omEmpty
  let _ = checkSymbolsInjective "constructor" (flatMap unitCtorSymbolPairs allUnits) omEmpty
  ()

-- (emitted symbol, pre-image label) for the top-level FUNCTIONS this unit defines
-- and `mangleUnitU` will rename.  Mirrors `buildUnitRenameMap`'s local half
-- (`dedup (unitDefNames …)` minus `isExcludedName`) so the domain is the same set
-- of definition sites, not a re-derived approximation.
unitFnSymbolPairs : (String, List Decl) -> List (String, String)
unitFnSymbolPairs (mid, decls) = map
  (symbolPreImagePair mid)
  (filterList notExcludedName (dedup (unitDefNames (mid, decls))))

notExcludedName : String -> Bool
notExcludedName n = not (isExcludedName n)

-- (emitted symbol, pre-image label) for the CONSTRUCTORS this unit declares.
-- Mirrors `buildUnitCtorRenameMap`'s local half.
unitCtorSymbolPairs : (String, List Decl) -> List (String, String)
unitCtorSymbolPairs (mid, decls) =
  map (symbolPreImagePair mid) (dedup (unitLocalCtorNames decls))

-- the pre-image label is the `(module, name)` pair itself, spelled `<mid>.<name>` --
-- the diagnostic has to name the SOURCES, not just the collided symbol string.
symbolPreImagePair : String -> String -> (String, String)
symbolPreImagePair mid n = (mangledName mid n, "\{mid}.\{n}")

-- Injectivity, one pass, O(n log n) via the same weight-balanced tree the rename
-- map uses (the compiler's own emission is ~9.6k module-mangled symbols; a
-- `List`-as-a-map here would be the fourteenth quadratic).  Two entries agreeing on
-- BOTH symbol and pre-image are the SAME pre-image seen twice (a duplicate unit id
-- in `allUnits`), not a collision.  Anything else refuses, naming BOTH sources.
checkSymbolsInjective : String -> List (String, String) -> OrdMap String -> Unit
checkSymbolsInjective _ [] _ = ()
checkSymbolsInjective what ((sym, pre)::rest) seen = match omLookup sym seen
  None => checkSymbolsInjective what rest (omInsert sym pre seen)
  Some prev =>
    if prev == pre then
      checkSymbolsInjective what rest seen
    else
      panic "emitted-symbol collision: \{what}s `\{prev}` and `\{pre}` both mangle to `\{sym}` -- two distinct (module, name) pairs cannot share one emitted symbol, so the emitter would silently keep one and drop the other. Rename one of the two modules so their ids differ after `sanitizeId` (which maps `.`, `/` and `-` all to `_`), or rename one of the two definitions."
-- Per-unit CONSTRUCTOR exports: (mid, [(typeName, [ctorName])]).  Mirrors
-- exportsPerUnit but for data/record ctors, so an importing unit can map
-- `import M.{T(..)}` / `import M.{Ctor}` to `<M>__<Ctor>` (see ctorImportEntries).

-- exported (pub) top-level function names of a unit, each paired with the module
-- that ACTUALLY defines it.  For a locally-defined pub fn the definer is the unit
-- itself; for a name brought in by `export import` (a `DUse True` re-export) the
-- definer is chased through the re-export chain to the ORIGINAL owning module
-- (mirroring eval.mdk's `pubReexports`), so an importer of a re-exported name
-- mangles its reference to `<originalDefiner>__<name>`, NOT `<reExporter>__<name>`
-- (the re-exporter has no backing DFunDef → the reference would be orphaned/unbound
-- at emit).  Built as a dependency-ordered fold so a re-export can consult the
-- source module's already-computed exports (loader order is dependency-first — the
-- same invariant eval.mdk's buildModInfos relies on).
buildExportsPerUnit : List (String, List (String, String)) -> List (String, List Decl) -> List (String, List (String, String))
buildExportsPerUnit _ [] = []
buildExportsPerUnit acc ((mid, decls)::rest) =
  let entry = unitExportEntry acc (mid, decls)
  entry :: buildExportsPerUnit (entry::acc) rest

unitExportEntry : List (String, List (String, String)) -> (String, List Decl) -> (String, List (String, String))
unitExportEntry acc (mid, decls) =
  let locals = map (n => (n, mid)) (dedup (pubFnNames decls))
  let reexs = flatMap (reexportFnEntries acc) decls
  (mid, dedupPairsByName (locals ++ reexs))

-- names a `DUse True` (re-export) decl brings in, each paired with its ORIGINAL
-- definer (looked up transitively in `acc` — the source module's already-computed
-- export pairs, so a >1-hop re-export chain still resolves to the true owner).
-- Mirrors eval.mdk's `reexport`/`resolveMembers`.
reexportFnEntries : List (String, List (String, String)) -> Decl -> List (String, String)
reexportFnEntries acc (DUse True path _) =
  let srcMid = useModIdU path
  match lookupExports srcMid acc
    None => []
    Some srcExports => reexportMembers path srcExports
reexportFnEntries acc (DAttrib _ d) = reexportFnEntries acc d
reexportFnEntries _ _ = []

reexportMembers : UsePath -> List (String, String) -> List (String, String)
reexportMembers (UseGroup _ members) srcExports =
  flatMap (reexportMember srcExports) members
reexportMembers (UseWild _) srcExports = srcExports
reexportMembers (UseName ns) srcExports =
  if lenGt1 ns then
    reexportOne srcExports (lastOfPM ns)
  else
    []
reexportMembers (UseAlias _ _) _ = []

reexportMember : List (String, String) -> UseMember -> List (String, String)
reexportMember srcExports m = reexportOne srcExports (useMemberOrigin m)

reexportOne : List (String, String) -> String -> List (String, String)
reexportOne srcExports n = match lookupDefiner n srcExports
  Some definer => [(n, definer)]
  None => []

-- keep the FIRST occurrence of each name — locals are prepended, so a locally
-- defined pub fn wins over a re-export of the same name.
-- #242: the name key is already a String, so this is the canonical
-- `support.util.dedupBy` verbatim (was a private O(n²) `List`-as-a-set scan).
dedupPairsByName : List (String, String) -> List (String, String)
dedupPairsByName pairs = dedupBy fst pairs

lookupDefiner : String -> List (String, String) -> Option String
lookupDefiner _ [] = None
lookupDefiner k ((n, d)::rest) = if k == n then Some d else lookupDefiner k rest

-- ── per-unit CONSTRUCTOR exports ──────────────────────────────────────────────
-- (mid, [(typeName, [ctorName])]) for the PUBLIC data/record types the unit
-- declares.  A reserved constructor (Cons/Nil/Some/None/Ok/Err/Lt/Eq/Gt/True/False —
-- the emitter's fixed-tag set) is OMITTED so it is never mangled (mangling would
-- lose its reserved tag).
--
-- 🚨 THIS ANSWERS A SCOPE QUESTION — "may an IMPORTER name this constructor?" — not
-- "does this constructor exist?".  The unit's OWN constructors are mangled from a
-- different, deliberately unfiltered peer (`unitLocalCtorNames`, below), so
-- declining an entry here never leaves a local definition unrenamed; it only
-- declines to offer the symbol ACROSS a `DUse`.  Over-offering is not additive: the
-- entry it manufactures SHADOWS whatever the front end actually bound.
--
-- ⚠️ THE `VisPublic` GATE IS LOAD-BEARING, and this comment used to say the opposite
-- — *"Visibility is not gated here … unmangled-because-private is harmless (an
-- unimported ctor is never referenced cross-unit)"*.  That was measurably false, and
-- the counter-example is not exotic: a module can export a TYPE and privately declare
-- a CONSTRUCTOR of the same spelling.
--     public export data Zz = Mk Int      -- mp exports the TYPE `Zz`
--     data Hidden = Zz Int Int            -- ...and privately declares a CTOR `Zz`
-- An importer writing `import mp.{Zz(..)}` then `import mq.{Zz, unQ}` has `Zz` bound
-- by the front end to mq's public arity-1 constructor (`run` prints the correct `7`),
-- but an ungated table answers "is `Zz` a constructor of mp?" with YES — off mp's
-- PRIVATE one — and, being first in decl order, that entry wins
-- (`mangleUnitU`'s first-entry-wins `omFromPairs`).  Measured: the built binary died
-- `E-NONEXHAUSTIVE-MATCH`, with `store i64 ptrtoint (ptr @mdk_ctorpap_mp__Zz_0 …)` in
-- the IR and `mq__Zz` emitted nowhere.  Swapping only the two import lines made the
-- same program correct again, which is the tell that a rename map is being keyed off
-- something with no scope.
--     So the gate mirrors `frontend/resolve.expCtorsDirect` (`:2903`) and
-- `expTypeCtorsDirect` (`:2911`), both `DData VisPublic`, and `eval.ctorsByTypeOf`
-- (`compiler/eval/eval.mdk`), which is `DData VisPublic` too.  Pinned by
-- `test/llvm_fixtures_modules/ctor_scope_private_ctor_not_offered/` and its
-- import-permuted twin.
--
-- ⚠️ NO `DNewtype` ARM, deliberately (#1305).  A newtype's constructor is not
-- importable by ANY spelling — measured on this binary with no collision present,
-- `import nmod.{NT(..)}`, `import nmod.{NT, Wrap}` and `import nmod.*` all give
-- `T-UNBOUND` `Unbound variable: Wrap` — because `types/typecheck.publicDataDecls`
-- (`:21219`) publishes `DData VisPublic` / `DInterface pub` / `DImpl pub` /
-- `DTypeAlias pub` and has no `DNewtype` arm, so the ctor's scheme is never
-- published.  An arm here offered `<nmod>__Wrap` for a name the front end had bound
-- elsewhere, so `medaka build` mis-bound it while `run` was correct.
--     ⚠️ Gating the arm on `newtypePub` LOOKS like the fix and is a NO-OP: `export
-- newtype` SETS `newtypePub` (`frontend/resolve.expTypeCtorsDirect`, `:2913`, is
-- gated on it and still indexes the ctor).  The arm has to be ABSENT, not filtered.
--     This matches `eval.ctorsByTypeOf` (`compiler/eval/eval.mdk`), the
-- interpreter-side peer, which reached the same shape from the same derivation.
unitCtorExportEntry : (String, List Decl) -> (String, List (String, List String))
unitCtorExportEntry (mid, decls) = (mid, flatMap ctorExportEntries decls)

ctorExportEntries : Decl -> List (String, List String)
ctorExportEntries (DData { dataVis = VisPublic, dataName = tyname, dataCtors = variants }) = [(tyname, filterList nonReservedCtor (map variantCtorName variants))]
ctorExportEntries (DAttrib _ d) = ctorExportEntries d
ctorExportEntries _ = []

variantCtorName : Variant -> String
variantCtorName (Variant n _) = n

-- The emitter's fixed-tag constructors (reservedTag + True/False immediates in
-- llvm_emit.mdk).  Mangling any of these would break the reserved-tag match.
nonReservedCtor : String -> Bool
nonReservedCtor n = not (isReservedCtor n)

isReservedCtor : String -> Bool
isReservedCtor n = n == "Cons"
  || n == "Nil"
  || n == "Some"
  || n == "None"
  || n == "Ok"
  || n == "Err"
  || n == "Lt"
  || n == "Eq"
  || n == "Gt"
  || n == "True"
  || n == "False"

-- ── the unit's CONSTRUCTOR rename map ─────────────────────────────────────────
-- local ctors → `<mid>__<ctor>` (local shadows imports), then imported ctors →
-- `<originMid>__<ctor>`, then core's ctors as implicit-prelude entries.  Keyed by
-- bare ctor name; reserved ctors are excluded at the export step so they never
-- enter the map.
buildUnitCtorRenameMap : String -> List (String, List (String, List String)) -> List Decl -> List (String, String)
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
ctorImportEntries : String -> List (String, List (String, List String)) -> List Decl -> List (String, String)
ctorImportEntries _ ctorExportsPerUnit decls = flatMap (declCtorImportEntries ctorExportsPerUnit) decls
  ++ coreCtorImportEntries ctorExportsPerUnit

coreCtorImportEntries : List (String, List (String, List String)) -> List (String, String)
coreCtorImportEntries ctorExportsPerUnit = match lookupCtorExports "core" ctorExportsPerUnit
  Some entries => flatMap coreCtorEntry entries
  None => []

coreCtorEntry : (String, List String) -> List (String, String)
coreCtorEntry (_, ctors) = flatMap (n => [(n, mangledName "core" n)]) ctors

declCtorImportEntries : List (String, List (String, List String)) -> Decl -> List (String, String)
declCtorImportEntries ctorExportsPerUnit (DUse _ path _) =
  useCtorPathEntries ctorExportsPerUnit path
declCtorImportEntries ctorExportsPerUnit (DAttrib _ d) =
  declCtorImportEntries ctorExportsPerUnit d
declCtorImportEntries _ _ = []

useCtorPathEntries : List (String, List (String, List String)) -> UsePath -> List (String, String)
useCtorPathEntries ctorExportsPerUnit path =
  let mid = useModIdU path
  if mid == "core" then []
  else match lookupCtorExports mid ctorExportsPerUnit
    None => []
    Some typeEntries => match path
      UseGroup _ members => flatMap (ctorMemberEntry mid typeEntries) members
      UseWild _ => flatMap (typeCtorEntries mid) typeEntries
      UseName _ => []
      UseAlias _ _ => []
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
-- This mirrors the three ARMS of `frontend/resolve.expandMemberNames` (`:2327`) —
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
-- 🚨 MIRRORING THE ARMS IS NOT MIRRORING THE TABLE, AND SAYING OTHERWISE ALREADY
-- SHIPPED A REGRESSION.  These arms only ask questions; `unitCtorExportEntry`
-- ANSWERS them, and matching arms against a table that disagrees with resolve's just
-- routes the disagreement through a new spelling.  Adding the bare check to the wild
-- branch did exactly that: it was correct as an arm and wrong as a whole, because the
-- table it consults was ungated on visibility (see the `VisPublic` note on
-- `unitCtorExportEntry`).  Whoever touches these arms next must ask what the table
-- underneath them says.  Residual table-level divergences from resolve, at the time
-- of writing:
--   * VISIBILITY — closed, see the `VisPublic` gate above.
--   * RE-EXPORT — `unitCtorExportEntry` has no `DUse True` arm, while the FUNCTION
--     map's `reexportOne` (above) does.  So a ctor reaching an importer through
--     `export import` reproduces #1300's exact symptom.  Filed and pinned as #1359;
--     deliberately NOT fixed here.
--   * `DAttrib` — this file recurses through it, resolve's `expCtorsDirect` /
--     `expTypeCtorsDirect` swallow it in their `_::rest` wildcard (that asymmetry is
--     #1228).  Not exploitable: an attributed public data decl is not importable at
--     all, so nothing reaches these arms to disagree about.
ctorMemberEntry : String -> List (String, List String) -> UseMember -> List (String, String)
ctorMemberEntry mid typeEntries (UseMember name wild _ _) =
  if wild then match lookupCtorTypeEntry name typeEntries
    Some ctors => bareCtorMemberEntry mid typeEntries name
      ++ flatMap (originCtorEntry mid) ctors
    None => bareCtorMemberEntry mid typeEntries name
  else bareCtorMemberEntry mid typeEntries name

-- `name` itself, iff M exports a CONSTRUCTOR so spelled.  Scans every type's ctor
-- list because the question is about ctor-ness, not about which type owns it.
bareCtorMemberEntry : String -> List (String, List String) -> String -> List (String, String)
bareCtorMemberEntry mid typeEntries name =
  if contains name (flatMap snd typeEntries) then
    originCtorEntry mid name
  else
    []

typeCtorEntries : String -> (String, List String) -> List (String, String)
typeCtorEntries mid (_, ctors) = flatMap (originCtorEntry mid) ctors

originCtorEntry : String -> String -> List (String, String)
originCtorEntry mid n = [(n, mangledName mid n)]

lookupCtorTypeEntry : String -> List (String, List String) -> Option (List String)
lookupCtorTypeEntry _ [] = None
lookupCtorTypeEntry k ((t, cs)::rest) =
  if k == t then
    Some cs
  else
    lookupCtorTypeEntry k rest

lookupCtorExports : String -> List (String, List (String, List String)) -> Option (List (String, List String))
lookupCtorExports _ [] = None
lookupCtorExports k ((m, es)::rest) =
  if k == m then
    Some es
  else
    lookupCtorExports k rest

-- a module keeps its mid in the output pair.
mangleModule : List (String, List (String, String)) -> List (String, List (String, List String)) -> (String, List Decl) -> (String, List Decl)
mangleModule exportsPerUnit ctorExportsPerUnit (mid, decls) =
  (mid, mangleUnitU exportsPerUnit ctorExportsPerUnit (mid, decls))

-- ── per-unit universal rename ────────────────────────────────────────────────
-- For one unit: build the combined rename map (own top-level fns → `<mid>__<name>`,
-- PLUS each imported bare name → its origin module's mangled symbol), then rewrite
-- the unit's decls (definition names + all in-scope references).
mangleUnitU : List (String, List (String, String)) -> List (String, List (String, List String)) -> (String, List Decl) -> List Decl
mangleUnitU exportsPerUnit ctorExportsPerUnit (mid, decls) =
  let rmFn = buildUnitRenameMap mid exportsPerUnit decls
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
buildUnitRenameMap : String -> List (String, List (String, String)) -> List Decl -> List (String, String)
buildUnitRenameMap mid exportsPerUnit decls =
  let localFns = dedup (unitDefNames (mid, decls))
  let localEntries = flatMap (localRenameEntry mid) localFns
  let importEntries = importRenameEntries mid exportsPerUnit decls
  localEntries ++ importEntries
-- local first ⇒ shadows any imported entry with the same key under lookupAssoc.

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
-- importer assertions in `diff_compiler_shadow_semantics.sh` (measured).
--
-- The entry is DROPPED, not redirected: per rule 4 at the top of this file, method
-- names have their own emitter naming (impl keys), and this pass must leave the
-- occurrence unchanged so the marker sees the method's own spelling.
notIfaceMethodKey : OrdMap Unit -> (String, String) -> Bool
notIfaceMethodKey methods (n, _) = not (omHasKey n methods)

-- names of the methods of every `interface` DECLARED in this unit.  Mirrors
-- `frontend/marker.mdk`'s `interfaceMethodNames`, plus the `DAttrib` unwrap that
-- `declDefNames` here already does.
unitIfaceMethodNames : List Decl -> List String
unitIfaceMethodNames [] = []
unitIfaceMethodNames ((DInterface { methods, ... })::rest) = map ifaceMethodNameM methods
  ++ unitIfaceMethodNames rest
unitIfaceMethodNames ((DAttrib _ d)::rest) = unitIfaceMethodNames [d]
  ++ unitIfaceMethodNames rest
unitIfaceMethodNames (_::rest) = unitIfaceMethodNames rest

ifaceMethodNameM : IfaceMethod -> String
ifaceMethodNameM (IfaceMethod n _ _ _) = n

-- a local top-level fn → its module-qualified symbol, UNLESS excluded (`main`).
localRenameEntry : String -> String -> List (String, String)
localRenameEntry mid n
  | isExcludedName n = []
  | otherwise = [(n, mangledName mid n)]

-- `main` is the program entry (`@main`); never mangle it.
isExcludedName : String -> Bool
isExcludedName n = n == "main"

-- ── import-aware reference targets ───────────────────────────────────────────
-- For each `DUse` of a non-core module `M`, the bare names it brings into this
-- unit map to `M`'s mangled symbols.  Plus the implicit prelude: every core
-- export is in scope as `core__<name>` (a local def shadows it via local-first
-- ordering; an explicit import of the same name from a sibling shadows core via
-- import-entry ordering below).
-- explicit sibling imports first (they shadow the implicit prelude), prelude last.
-- The prelude half is filtered by the unit's own interface-method names — see
-- `notIfaceMethodKey` above for why, and why the explicit half is NOT filtered.
importRenameEntries : String -> List (String, List (String, String)) -> List Decl -> List (String, String)
importRenameEntries _ exportsPerUnit decls = flatMap (declImportEntries exportsPerUnit) decls
  ++ filterList (notIfaceMethodKey (omFromNames (unitIfaceMethodNames decls) omEmpty)) (coreImportEntries exportsPerUnit)

-- core's exports as implicit-prelude entries (`name → core__name`), excluding
-- `main` (core has none, but be safe).
coreImportEntries : List (String, List (String, String)) -> List (String, String)
coreImportEntries exportsPerUnit = match lookupExports "core" exportsPerUnit
  Some names => flatMap coreEntry names
  None => []

coreEntry : (String, String) -> List (String, String)
coreEntry (n, definer)
  | isExcludedName n = []
  | otherwise = [(n, mangledName definer n)]

-- a single `DUse path` → the (bareName, originMangled) entries it introduces.
declImportEntries : List (String, List (String, String)) -> Decl -> List (String, String)
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
usePathEntries : List (String, List (String, String)) -> UsePath -> List (String, String)
usePathEntries exportsPerUnit path =
  let mid = useModIdU path
  if mid == "core" then []
  else match lookupExports mid exportsPerUnit
    None => []
    Some exports => match path
      UseGroup _ members => flatMap (memberEntry exports) members
      UseWild _ => flatMap originEntryPair exports
      UseName ns => originEntry exports (lastOfPM ns)
      UseAlias _ a => flatMap (aliasEntryPair a) exports

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
originEntryAs : List (String, String) -> String -> String -> List (String, String)
originEntryAs exports origin local
  | isExcludedName origin = []
  | otherwise = match lookupDefiner origin exports
    Some definer => [(local, mangledName definer origin)]
    None => []

-- a wildcard import iterates the (name, definer) pairs directly.
originEntryPair : (String, String) -> List (String, String)
originEntryPair = coreEntry

-- a module alias iterates the same pairs, keying each under `A.<name>`.
aliasEntryPair : String -> (String, String) -> List (String, String)
aliasEntryPair a (n, definer)
  | isExcludedName n = []
  | otherwise = [(qualifiedLocal a n, mangledName definer n)]

useModIdU : UsePath -> String
useModIdU (UseName ns) =
  if lenGt1 ns then
    joinDot (initList ns)
  else
    firstOrU "" ns
useModIdU (UseGroup ns _) = joinDot ns
useModIdU (UseWild ns) = joinDot ns
useModIdU (UseAlias ns _) = joinDot ns

lenGt1 : List a -> Bool
lenGt1 (_::_::_) = True
lenGt1 _ = False

firstOrU : String -> List String -> String
firstOrU d [] = d
firstOrU _ (x::_) = x

lastOfPM : List String -> String
lastOfPM [] = ""
lastOfPM [x] = x
lastOfPM (_::rest) = lastOfPM rest

lookupExports : String -> List (String, List (String, String)) -> Option (List (String, String))
lookupExports _ [] = None
lookupExports k ((m, ns)::rest) =
  if k == m then
    Some ns
  else
    lookupExports k rest

-- ── exported (pub) function names of a unit ──────────────────────────────────
-- A name is an exported function symbol if EITHER its DFunDef clause carries
-- `pub = True`, OR a `pub` DTypeSig/DExtern of that name precedes it (the `export`
-- keyword precedes the SIGNATURE; the definition clause parses as a private
-- DFunDef — mirroring resolve.mdk's `expValuesDirect`).  We also count pub
-- DLetGroup binders.  Restricted to names that are ALSO defined as functions in
-- this unit (a pub DTypeSig with no body isn't an emittable symbol).
-- #352: `defined` is a MEMBERSHIP SET, and it was a `List` scanned once per pub name
-- — O(pubNames × unitFns) per unit, which on a unit whose pub names are most of its
-- functions is O(unitFns²).  Measured through profile_main's `mangle` stage on a
-- one-unit shape of N `export`ed fns, net of the prelude baseline: counted-op ratio
-- r1=3.99 r2=3.99 per doubling at N=500/1000/2000 (2,003,000 net scan steps at
-- N=2000) — textbook quadratic.  After: 500 -> 1000 -> 2000, r=2.00/2.00.
-- `filterList` keeps the SAME order and the SAME duplicates — only the membership
-- test changes — so every downstream export list, and therefore every mangled symbol,
-- is byte-identical (fixpoint C3a/C3b).
-- ⚠️ TWO corrections to what #352 filed, both measured, both worth keeping:
--   * "(ALLOCATES — gate-visible)" is WRONG. The scan is PURE; the `mangle` allocation
--     ratio on this shape is r1=2.12 r2=2.11 net / 1.84/1.96 raw — linear BEFORE the
--     fix as well as after. It is visible on the OP arm, not the alloc arm.
--   * This swap is NOT allocation-free either, and that cuts the other way from the
--     #1010 trap in compiler/AGENTS.md. The key projection IS the identity on an
--     already-built String, so nothing allocates PER PROBE — but the one-time set
--     costs O(unitFns log unitFns) nodes, measured at +15% mangle-stage allocation at
--     N=2000 on this shape (net 12.1 -> 13.9 MB) and +5% on a mixed shape. Still a
--     clear win (op count falls 1000x, and mangle is ~15 MB of a ~2 GB compile), but
--     it is a TRADE, not a free one.
pubFnNames : List Decl -> List String
pubFnNames decls =
  let defined = omFromNames (unitDefNames ("", decls)) omEmpty
  let pubSigs = pubSigNames decls
  let pubDefs = pubDefNames decls
  filterList (n => omHasKey n defined) (pubSigs ++ pubDefs)

-- names whose DFunDef / DLetGroup binder is itself `pub = True`.
pubDefNames : List Decl -> List String
pubDefNames [] = []
pubDefNames ((DFunDef True n _ _)::rest) = n :: pubDefNames rest
pubDefNames ((DLetGroup True binds)::rest) = map letBindName binds
  ++ pubDefNames rest
pubDefNames ((DAttrib _ d)::rest) = pubDefNames [d] ++ pubDefNames rest
pubDefNames (_::rest) = pubDefNames rest

-- ── collision-name detection (RETAINED — kept available, no longer the trigger) ──
-- all top-level FUNCTION names defined in a unit (DFunDef + DLetGroup binders),
-- wrapped through DAttrib.  Only function-shaped decls can collide as @mdk_<name>.
unitDefNames : (String, List Decl) -> List String
unitDefNames (_, decls) = flatMap declDefNames decls

declDefNames : Decl -> List String
declDefNames (DFunDef _ n _ _) = [n]
declDefNames (DLetGroup _ binds) = map letBindName binds
declDefNames (DAttrib _ d) = declDefNames d
declDefNames _ = []

letBindName : LetBind -> String
letBindName (LetBind n _) = n

-- names exported via a `pub` DTypeSig/DExtern in this unit (so their DFunDef
-- clauses, which parse private, still count as exported function symbols).
pubSigNames : List Decl -> List String
pubSigNames [] = []
pubSigNames ((DTypeSig True n _)::rest) = n :: pubSigNames rest
pubSigNames ((DExtern True n _)::rest) = n :: pubSigNames rest
pubSigNames ((DAttrib _ d)::rest) = pubSigNames [d] ++ pubSigNames rest
pubSigNames (_::rest) = pubSigNames rest

-- `<mid>__<name>` with the mid sanitized to a valid identifier (`/`, `.`, `-` →
-- `_`).  The emitted symbol is `@mdk_<thisname>`, so only [A-Za-z0-9_] are safe.
export
mangledName : String -> String -> String
mangledName mid name = "\{sanitizeId mid}__\{name}"

export
sanitizeId : String -> String
sanitizeId s = sanitizeGo s 0 (stringLength s) ""

sanitizeGo : String -> Int -> Int -> String -> String
sanitizeGo s i len acc =
  if i >= len then acc
  else
    let c = stringSlice i (i + 1) s
    let c2 = if safeChar c then c else "_"
    sanitizeGo s (i + 1) len (acc ++ c2)

export
safeChar : String -> Bool
safeChar c = c >= "a" && c <= "z"
  || c >= "A" && c <= "Z"
  || c >= "0" && c <= "9"
  || c == "_"

-- #1950: encode an ARBITRARY String as a legal emitted identifier, INJECTIVELY.
-- This is the ONE definition of that encoding: `llvm_emit.defaultFnName` and
-- `llvm_emit.implFnSymTag`, `wasm_emit.implSymTagW`/`implFnSymTagW`, and
-- `core_ir_lower.memoBindName`/`implSymTagOf` all call THIS, so the two backends
-- and the injectivity guard cannot drift apart about what symbol was emitted.
--
-- ⚠️ It is NOT `sanitizeId`, and must never be reimplemented as a wrapper over it.
-- `sanitizeId` is MANY-TO-ONE — everything outside [A-Za-z0-9_] becomes `_` — which
-- is exactly #1950: the canonical impl keys `main::Sz|(Q A_B C)|` and
-- `main::Sz|(Q A B_C)|` both sanitize to `main__Sz__Q_A_B_C__`, so two DISTINCT
-- impls of one method were minted under one symbol (`run` answered correctly,
-- `build` died at clang with a raw `invalid redefinition of function`).
-- `sanitizeId` keeps its lossy mapping because it also spells the module-mangled
-- compiler symbols, whose names are fixpoint-load-bearing.
--
-- The encoding is two branches with DISJOINT IMAGES, which is what makes it
-- injective on all of `String` and not merely on the keys we happen to mint today:
--   * a string already spelled only in [A-Za-z0-9_] that does NOT start with the
--     two-character marker `zZ` maps to ITSELF.  That covers every bare head tag
--     (`Int`, `MyType`, `__tuple2__`), so every symbol the compiler and every
--     collision-free program already emits stays byte-identical — this branch is
--     what keeps the change fixpoint-neutral.
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
  if i >= len then acc
  else
    let c = stringSlice i (i + 1) s
    let c2 = if alnumChar c then c else "_\{hexOfChar c}_"
    escapeGo s (i + 1) len (acc ++ c2)

-- `safeChar` MINUS the underscore: `_` introduces an escape, so it has to be
-- escaped like any other non-alphanumeric character.
alnumChar : String -> Bool
alnumChar c = c >= "a" && c <= "z"
  || c >= "A" && c <= "Z"
  || c >= "0" && c <= "9"

-- the code of a one-character string in lowercase hex, unpadded — the trailing `_`
-- delimits the escape, so a fixed width would buy nothing.
hexOfChar : String -> String
hexOfChar c = hexOfInt (charCode (arrayGetUnsafe 0 (stringToChars c)))

hexOfInt : Int -> String
hexOfInt n =
  if n < 16 then
    hexNibble n
  else
    hexOfInt (n / 16) ++ hexNibble (n % 16)

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
-- interpreter answered `mzone|nyone`, at exit 0 with no diagnostic.  The comment
-- that used to stand at `wasm_emit.dictTag` calling this shape "astronomically
-- unlikely" was wrong about the mechanism: the hash's non-injectivity has nothing
-- to do with the tag alphabet being small, and nothing to do with the mask width.
-- `core_ir_lower.dictWitnessTagGuard` is what makes it loud; keep the two together.
export
hashName : String -> Int
hashName s = hashChars (stringToChars s) 0 5381

hashChars : Array Char -> Int -> Int -> Int
hashChars cs i acc
  | i >= arrayLength cs = acc
  | otherwise = hashChars cs (i + 1) (acc * 33 + charCode (arrayGetUnsafe i cs))

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
-- `core_ir_lower.dictWitnessTagGuard` must check the WASM tag space with the SAME
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
renameDecl rm (DFunDef pub n ps e) =
  DFunDef
    pub
    (renameDefName rm n)
    (renamePatsPM rm ps)
    (renameScoped rm (boundOfListPM (patVarsListPM ps)) e)
-- a top-level signature (`f : …` / `export f : …`) shares the function's name; it
-- MUST be renamed in lockstep with its DFunDef so the typechecker keys f's scheme
-- under the SAME mangled name the call sites + def now use (else dictPass /
-- publicValNames see `clampU` while the def is `<mid>__clampU` → unbound).
renameDecl rm (DTypeSig pub n ty) = DTypeSig pub (renameDefName rm n) ty
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
renameDecl rm (DBench pub name body) =
  DBench pub name (renameScoped rm omEmpty body)
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
renameDecl _ d = d

-- rename a data variant's constructor name (payload types are unaffected).
renameVariant : OrdMap String -> Variant -> Variant
renameVariant rm (Variant n payload) = Variant (renameDefName rm n) payload

-- top-level LetBind in a DLetGroup: rename the binder name (if in map) AND its
-- clause bodies.  The group's own names are in scope across all clauses.
renameLetBindDef : OrdMap String -> LetBind -> LetBind
renameLetBindDef rm (LetBind n clauses) =
  LetBind (renameDefName rm n) (map (renameFunClause rm omEmpty) clauses)

renameDefName : OrdMap String -> String -> String
renameDefName rm n = match omLookup n rm
  Some n2 => n2
  None => n

renameIfaceMethod : OrdMap String -> IfaceMethod -> IfaceMethod
renameIfaceMethod _ (IfaceMethod n ty None mloc) = IfaceMethod n ty None mloc
renameIfaceMethod rm (IfaceMethod n ty (Some (MethodDefault ps e)) mloc) =
  IfaceMethod
    n
    ty
    (Some (MethodDefault
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
boundInsertPM (n::rest) b = boundInsertPM rest (omInsert n () b)

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
renameScoped rm bound (EFieldAccess e0 n r) =
  EFieldAccess (renameScoped rm bound e0) n r
renameScoped rm bound (ETuple es) = ETuple (map (renameScoped rm bound) es)
renameScoped rm bound (EListLit es) = EListLit (map (renameScoped rm bound) es)
renameScoped rm bound (EArrayLit es) =
  EArrayLit (map (renameScoped rm bound) es)
renameScoped rm bound (ERangeList lo hi i) =
  ERangeList (renameScoped rm bound lo) (renameScoped rm bound hi) i
renameScoped rm bound (ERangeArray lo hi i) =
  ERangeArray (renameScoped rm bound lo) (renameScoped rm bound hi) i
renameScoped rm bound (ESlice e0 lo hi i r) =
  ESlice
    (renameScoped rm bound e0)
    (renameScoped rm bound lo)
    (renameScoped rm bound hi)
    i
    r
renameScoped rm bound (EIndex e0 i r) =
  EIndex (renameScoped rm bound e0) (renameScoped rm bound i) r
renameScoped rm bound (EAnnot e0 t) = EAnnot (renameScoped rm bound e0) t
renameScoped rm bound (EHeadAnnot e0 t) =
  EHeadAnnot (renameScoped rm bound e0) t
renameScoped rm bound (ERecordCreate n fs) =
  ERecordCreate (renameDefName rm n) (map (renameField rm bound) fs)
renameScoped rm bound (ERecordUpdate e0 fs r) =
  ERecordUpdate (renameScoped rm bound e0) (map (renameField rm bound) fs) r
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
-- leaves (ELit / EMethodRef / EDictApp / EMethodAt / EDictAt / SecBare) -- EVarAt
-- is handled above, not here: it carries a renameable NAME (see its arm).
renameScoped _ _ e = e

renameField : OrdMap String -> OrdMap Unit -> FieldAssign -> FieldAssign
renameField rm bound (FieldAssign n e) = FieldAssign n (renameScoped rm bound e)

renameKv : OrdMap String -> OrdMap Unit -> (Expr, Expr) -> (Expr, Expr)
renameKv rm bound (k, v) = (renameScoped rm bound k, renameScoped rm bound v)

renameInterp : OrdMap String -> OrdMap Unit -> InterpPart -> InterpPart
renameInterp _ _ (InterpStr s) = InterpStr s
renameInterp rm bound (InterpExpr e) = InterpExpr (renameScoped rm bound e)

renameLetBind : OrdMap String -> OrdMap Unit -> LetBind -> LetBind
renameLetBind rm bound (LetBind n clauses) =
  LetBind (renameDefName rm n) (map (renameFunClause rm bound) clauses)

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

renameGuards : OrdMap String -> OrdMap Unit -> List Guard -> (List Guard, OrdMap Unit)
renameGuards _ bound [] = ([], bound)
renameGuards rm bound ((GBool e)::rest) =
  let e2 = renameScoped rm bound e
  let (rest2, bnd) = renameGuards rm bound rest
  (GBool e2 :: rest2, bnd)
renameGuards rm bound ((GBind p e)::rest) =
  let e2 = renameScoped rm bound e
  let (rest2, bnd) = renameGuards rm (boundInsertPM (patVarsPM p) bound) rest
  (GBind (renamePat rm p) e2 :: rest2, bnd)

renameStmts : OrdMap String -> OrdMap Unit -> List DoStmt -> List DoStmt
renameStmts _ _ [] = []
renameStmts rm bound ((DoExpr e)::rest) =
  DoExpr (renameScoped rm bound e) :: renameStmts rm bound rest
renameStmts rm bound ((DoBind p e)::rest) =
  DoBind (renamePat rm p) (renameScoped rm bound e) ::
    renameStmts rm (boundInsertPM (patVarsPM p) bound) rest
renameStmts rm bound ((DoLet m r p e)::rest) =
  let b1 = if r then boundInsertPM (patVarsPM p) bound else bound
  DoLet m r (renamePat rm p) (renameScoped rm b1 e) :: renameStmts rm (boundInsertPM (patVarsPM p) bound) rest
renameStmts rm bound ((DoAssign x e)::rest) =
  DoAssign x (renameScoped rm bound e) :: renameStmts rm bound rest
renameStmts rm bound ((DoFieldAssign x fs e)::rest) =
  DoFieldAssign x fs (renameScoped rm bound e) :: renameStmts rm bound rest

letBindNamesPM : List LetBind -> List String
letBindNamesPM binds = map letBindName binds

-- ── pattern variables (local copy; covers PRec field/pun binders) ─────────────
patVarsPM : Pat -> List String
patVarsPM (PVar x _) = [x]
patVarsPM (PCon _ args) = patVarsListPM args
patVarsPM (PCons h t) = patVarsPM h ++ patVarsPM t
patVarsPM (PTuple ps) = patVarsListPM ps
patVarsPM (PList ps) = patVarsListPM ps
patVarsPM (PAs x _ p) = x :: patVarsPM p
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
renamePat rm (PAs x l p) = PAs x l (renamePat rm p)
renamePat rm (PRec n fields open) =
  PRec (renameDefName rm n) (map (renameRecPatField rm) fields) open
renamePat _ p = p

renameRecPatField : OrdMap String -> RecPatField -> RecPatField
renameRecPatField _ (RecPatField label l None) = RecPatField label l None
renameRecPatField rm (RecPatField label l (Some p)) =
  RecPatField label l (Some (renamePat rm p))

renamePatsPM : OrdMap String -> List Pat -> List Pat
renamePatsPM rm ps = map (renamePat rm) ps

recPatFieldVarsPM : RecPatField -> List String
recPatFieldVarsPM (RecPatField label _ None) = [label]
recPatFieldVarsPM (RecPatField _ _ (Some p)) = patVarsPM p
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "Expr" true) (mem "Pat" true) (mem "Arm" true) (mem "Guard" true) (mem "GuardArm" true) (mem "DoStmt" true) (mem "Section" true) (mem "InterpPart" true) (mem "FieldAssign" true) (mem "RecPatField" true) (mem "LetBind" true) (mem "FunClause" true) (mem "IfaceMethod" true) (mem "MethodDefault" true) (mem "ImplMethod" true) (mem "PropParam" true) (mem "UsePath" true) (mem "UseMember" true) (mem "useMemberOrigin" false) (mem "useMemberLocal" false) (mem "qualifiedLocal" false) (mem "Variant" true) (mem "DataVis" true))))
(DUse false (UseGroup ("support" "util") ((mem "contains" false) (mem "reverseL" false) (mem "isEmptyL" false) (mem "filterList" false) (mem "initList" false) (mem "joinDot" false) (mem "dedup" false) (mem "dedupBy" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omInsert" false) (mem "omLookup" false) (mem "omFromPairs" false) (mem "omFromNames" false) (mem "omHasKey" false) (mem "omEmpty" false) (mem "omSize" false))))
(DTypeSig true "mangleUnits" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))))))
(DFunDef false "mangleUnits" ((PVar "coreDecls") (PVar "modules")) (EBlock (DoLet false false (PVar "allUnits") (EBinOp "::" (ETuple (ELit (LString "core")) (EVar "coreDecls")) (EVar "modules"))) (DoLet false false PWild (EApp (EVar "symbolInjectivityGuard") (EVar "allUnits"))) (DoLet false false (PVar "exportsPerUnit") (EApp (EApp (EVar "buildExportsPerUnit") (EListLit)) (EVar "allUnits"))) (DoLet false false (PVar "ctorExportsPerUnit") (EApp (EApp (EVar "map") (EVar "unitCtorExportEntry")) (EVar "allUnits"))) (DoLet false false (PVar "coreOut") (EApp (EApp (EApp (EVar "mangleUnitU") (EVar "exportsPerUnit")) (EVar "ctorExportsPerUnit")) (ETuple (ELit (LString "core")) (EVar "coreDecls")))) (DoLet false false (PVar "modsOut") (EApp (EApp (EVar "map") (EApp (EApp (EVar "mangleModule") (EVar "exportsPerUnit")) (EVar "ctorExportsPerUnit"))) (EVar "modules"))) (DoExpr (ETuple (EVar "coreOut") (EVar "modsOut")))))
(DTypeSig true "mangleCtorCollisions" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))))))
(DFunDef false "mangleCtorCollisions" ((PVar "coreDecls") (PVar "modules")) (EBlock (DoLet false false (PVar "allUnits") (EBinOp "::" (ETuple (ELit (LString "core")) (EVar "coreDecls")) (EVar "modules"))) (DoLet false false (PVar "collided") (EApp (EVar "collidingCtorNames") (EVar "allUnits"))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "omSize") (EVar "collided")) (ELit (LInt 0))) (ETuple (EVar "coreDecls") (EVar "modules")) (EBlock (DoLet false false (PVar "ctorExportsPerUnit") (EApp (EApp (EVar "map") (EVar "unitCtorExportEntry")) (EVar "allUnits"))) (DoLet false false (PVar "coreOut") (EApp (EApp (EApp (EVar "mangleCtorUnitU") (EVar "collided")) (EVar "ctorExportsPerUnit")) (ETuple (ELit (LString "core")) (EVar "coreDecls")))) (DoLet false false (PVar "modsOut") (EApp (EApp (EVar "map") (EApp (EApp (EVar "mangleCtorModule") (EVar "collided")) (EVar "ctorExportsPerUnit"))) (EVar "modules"))) (DoExpr (ETuple (EVar "coreOut") (EVar "modsOut"))))))))
(DTypeSig true "mangleCtorCollisionsPair" (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))) (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "mangleCtorCollisionsPair" ((PTuple (PVar "coreDecls") (PVar "modules"))) (EApp (EApp (EVar "mangleCtorCollisions") (EVar "coreDecls")) (EVar "modules")))
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
(DTypeSig false "mangleCtorModule" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "mangleCtorModule" ((PVar "collided") (PVar "ctorExportsPerUnit") (PTuple (PVar "mid") (PVar "decls"))) (ETuple (EVar "mid") (EApp (EApp (EApp (EVar "mangleCtorUnitU") (EVar "collided")) (EVar "ctorExportsPerUnit")) (ETuple (EVar "mid") (EVar "decls")))))
(DTypeSig false "mangleCtorUnitU" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "mangleCtorUnitU" ((PVar "collided") (PVar "ctorExportsPerUnit") (PTuple (PVar "mid") (PVar "decls"))) (EBlock (DoLet false false (PVar "rmList") (EApp (EApp (EVar "filterList") (EApp (EVar "renameKeyCollides") (EVar "collided"))) (EApp (EApp (EApp (EVar "buildUnitCtorRenameMap") (EVar "mid")) (EVar "ctorExportsPerUnit")) (EVar "decls")))) (DoLet false false (PVar "rm") (EApp (EApp (EVar "omFromPairs") (EApp (EVar "reverseL") (EVar "rmList"))) (EVar "omEmpty"))) (DoExpr (EIf (EApp (EVar "isEmptyL") (EVar "rmList")) (EVar "decls") (EApp (EApp (EVar "map") (EApp (EVar "renameDecl") (EVar "rm"))) (EVar "decls"))))))
(DTypeSig false "renameKeyCollides" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyTuple (TyCon "String") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "renameKeyCollides" ((PVar "collided") (PTuple (PVar "n") PWild)) (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "collided")))
(DTypeSig false "symbolInjectivityGuard" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "Unit")))
(DFunDef false "symbolInjectivityGuard" ((PVar "allUnits")) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "checkSymbolsInjective") (ELit (LString "function"))) (EApp (EApp (EVar "flatMap") (EVar "unitFnSymbolPairs")) (EVar "allUnits"))) (EVar "omEmpty"))) (DoLet false false PWild (EApp (EApp (EApp (EVar "checkSymbolsInjective") (ELit (LString "constructor"))) (EApp (EApp (EVar "flatMap") (EVar "unitCtorSymbolPairs")) (EVar "allUnits"))) (EVar "omEmpty"))) (DoExpr (ELit LUnit))))
(DTypeSig false "unitFnSymbolPairs" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "unitFnSymbolPairs" ((PTuple (PVar "mid") (PVar "decls"))) (EApp (EApp (EVar "map") (EApp (EVar "symbolPreImagePair") (EVar "mid"))) (EApp (EApp (EVar "filterList") (EVar "notExcludedName")) (EApp (EVar "dedup") (EApp (EVar "unitDefNames") (ETuple (EVar "mid") (EVar "decls")))))))
(DTypeSig false "notExcludedName" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "notExcludedName" ((PVar "n")) (EApp (EVar "not") (EApp (EVar "isExcludedName") (EVar "n"))))
(DTypeSig false "unitCtorSymbolPairs" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "unitCtorSymbolPairs" ((PTuple (PVar "mid") (PVar "decls"))) (EApp (EApp (EVar "map") (EApp (EVar "symbolPreImagePair") (EVar "mid"))) (EApp (EVar "dedup") (EApp (EVar "unitLocalCtorNames") (EVar "decls")))))
(DTypeSig false "symbolPreImagePair" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "symbolPreImagePair" ((PVar "mid") (PVar "n")) (ETuple (EApp (EApp (EVar "mangledName") (EVar "mid")) (EVar "n")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "mid"))) (ELit (LString "."))) (EApp (EVar "display") (EVar "n"))) (ELit (LString "")))))
(DTypeSig false "checkSymbolsInjective" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyCon "Unit")))))
(DFunDef false "checkSymbolsInjective" (PWild (PList) PWild) (ELit LUnit))
(DFunDef false "checkSymbolsInjective" ((PVar "what") (PCons (PTuple (PVar "sym") (PVar "pre")) (PVar "rest")) (PVar "seen")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "sym")) (EVar "seen")) (arm (PCon "None") () (EApp (EApp (EApp (EVar "checkSymbolsInjective") (EVar "what")) (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "sym")) (EVar "pre")) (EVar "seen")))) (arm (PCon "Some" (PVar "prev")) () (EIf (EBinOp "==" (EVar "prev") (EVar "pre")) (EApp (EApp (EApp (EVar "checkSymbolsInjective") (EVar "what")) (EVar "rest")) (EVar "seen")) (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "emitted-symbol collision: ")) (EApp (EVar "display") (EVar "what"))) (ELit (LString "s `"))) (EApp (EVar "display") (EVar "prev"))) (ELit (LString "` and `"))) (EApp (EVar "display") (EVar "pre"))) (ELit (LString "` both mangle to `"))) (EApp (EVar "display") (EVar "sym"))) (ELit (LString "` -- two distinct (module, name) pairs cannot share one emitted symbol, so the emitter would silently keep one and drop the other. Rename one of the two modules so their ids differ after `sanitizeId` (which maps `.`, `/` and `-` all to `_`), or rename one of the two definitions."))))))))
(DTypeSig false "buildExportsPerUnit" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))))
(DFunDef false "buildExportsPerUnit" (PWild (PList)) (EListLit))
(DFunDef false "buildExportsPerUnit" ((PVar "acc") (PCons (PTuple (PVar "mid") (PVar "decls")) (PVar "rest"))) (EBlock (DoLet false false (PVar "entry") (EApp (EApp (EVar "unitExportEntry") (EVar "acc")) (ETuple (EVar "mid") (EVar "decls")))) (DoExpr (EBinOp "::" (EVar "entry") (EApp (EApp (EVar "buildExportsPerUnit") (EBinOp "::" (EVar "entry") (EVar "acc"))) (EVar "rest"))))))
(DTypeSig false "unitExportEntry" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "unitExportEntry" ((PVar "acc") (PTuple (PVar "mid") (PVar "decls"))) (EBlock (DoLet false false (PVar "locals") (EApp (EApp (EVar "map") (ELam ((PVar "n")) (ETuple (EVar "n") (EVar "mid")))) (EApp (EVar "dedup") (EApp (EVar "pubFnNames") (EVar "decls"))))) (DoLet false false (PVar "reexs") (EApp (EApp (EVar "flatMap") (EApp (EVar "reexportFnEntries") (EVar "acc"))) (EVar "decls"))) (DoExpr (ETuple (EVar "mid") (EApp (EVar "dedupPairsByName") (EBinOp "++" (EVar "locals") (EVar "reexs")))))))
(DTypeSig false "reexportFnEntries" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))) (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "reexportFnEntries" ((PVar "acc") (PCon "DUse" (PCon "True") (PVar "path") PWild)) (EBlock (DoLet false false (PVar "srcMid") (EApp (EVar "useModIdU") (EVar "path"))) (DoExpr (EMatch (EApp (EApp (EVar "lookupExports") (EVar "srcMid")) (EVar "acc")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "srcExports")) () (EApp (EApp (EVar "reexportMembers") (EVar "path")) (EVar "srcExports")))))))
(DFunDef false "reexportFnEntries" ((PVar "acc") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EVar "reexportFnEntries") (EVar "acc")) (EVar "d")))
(DFunDef false "reexportFnEntries" (PWild PWild) (EListLit))
(DTypeSig false "reexportMembers" (TyFun (TyCon "UsePath") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "reexportMembers" ((PCon "UseGroup" PWild (PVar "members")) (PVar "srcExports")) (EApp (EApp (EVar "flatMap") (EApp (EVar "reexportMember") (EVar "srcExports"))) (EVar "members")))
(DFunDef false "reexportMembers" ((PCon "UseWild" PWild) (PVar "srcExports")) (EVar "srcExports"))
(DFunDef false "reexportMembers" ((PCon "UseName" (PVar "ns")) (PVar "srcExports")) (EIf (EApp (EVar "lenGt1") (EVar "ns")) (EApp (EApp (EVar "reexportOne") (EVar "srcExports")) (EApp (EVar "lastOfPM") (EVar "ns"))) (EListLit)))
(DFunDef false "reexportMembers" ((PCon "UseAlias" PWild PWild) PWild) (EListLit))
(DTypeSig false "reexportMember" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "UseMember") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "reexportMember" ((PVar "srcExports") (PVar "m")) (EApp (EApp (EVar "reexportOne") (EVar "srcExports")) (EApp (EVar "useMemberOrigin") (EVar "m"))))
(DTypeSig false "reexportOne" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "reexportOne" ((PVar "srcExports") (PVar "n")) (EMatch (EApp (EApp (EVar "lookupDefiner") (EVar "n")) (EVar "srcExports")) (arm (PCon "Some" (PVar "definer")) () (EListLit (ETuple (EVar "n") (EVar "definer")))) (arm (PCon "None") () (EListLit))))
(DTypeSig false "dedupPairsByName" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "dedupPairsByName" ((PVar "pairs")) (EApp (EApp (EVar "dedupBy") (EVar "fst")) (EVar "pairs")))
(DTypeSig false "lookupDefiner" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "lookupDefiner" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupDefiner" ((PVar "k") (PCons (PTuple (PVar "n") (PVar "d")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "n")) (EApp (EVar "Some") (EVar "d")) (EApp (EApp (EVar "lookupDefiner") (EVar "k")) (EVar "rest"))))
(DTypeSig false "unitCtorExportEntry" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "unitCtorExportEntry" ((PTuple (PVar "mid") (PVar "decls"))) (ETuple (EVar "mid") (EApp (EApp (EVar "flatMap") (EVar "ctorExportEntries")) (EVar "decls"))))
(DTypeSig false "ctorExportEntries" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "ctorExportEntries" ((PRec "DData" ((rf "dataVis" (PCon "VisPublic")) (rf "dataName" (PVar "tyname")) (rf "dataCtors" (PVar "variants"))) false)) (EListLit (ETuple (EVar "tyname") (EApp (EApp (EVar "filterList") (EVar "nonReservedCtor")) (EApp (EApp (EVar "map") (EVar "variantCtorName")) (EVar "variants"))))))
(DFunDef false "ctorExportEntries" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "ctorExportEntries") (EVar "d")))
(DFunDef false "ctorExportEntries" (PWild) (EListLit))
(DTypeSig false "variantCtorName" (TyFun (TyCon "Variant") (TyCon "String")))
(DFunDef false "variantCtorName" ((PCon "Variant" (PVar "n") PWild)) (EVar "n"))
(DTypeSig false "nonReservedCtor" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "nonReservedCtor" ((PVar "n")) (EApp (EVar "not") (EApp (EVar "isReservedCtor") (EVar "n"))))
(DTypeSig false "isReservedCtor" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isReservedCtor" ((PVar "n")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "n") (ELit (LString "Cons"))) (EBinOp "==" (EVar "n") (ELit (LString "Nil")))) (EBinOp "==" (EVar "n") (ELit (LString "Some")))) (EBinOp "==" (EVar "n") (ELit (LString "None")))) (EBinOp "==" (EVar "n") (ELit (LString "Ok")))) (EBinOp "==" (EVar "n") (ELit (LString "Err")))) (EBinOp "==" (EVar "n") (ELit (LString "Lt")))) (EBinOp "==" (EVar "n") (ELit (LString "Eq")))) (EBinOp "==" (EVar "n") (ELit (LString "Gt")))) (EBinOp "==" (EVar "n") (ELit (LString "True")))) (EBinOp "==" (EVar "n") (ELit (LString "False")))))
(DTypeSig false "buildUnitCtorRenameMap" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))))
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
(DTypeSig false "ctorImportEntries" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "ctorImportEntries" (PWild (PVar "ctorExportsPerUnit") (PVar "decls")) (EBinOp "++" (EApp (EApp (EVar "flatMap") (EApp (EVar "declCtorImportEntries") (EVar "ctorExportsPerUnit"))) (EVar "decls")) (EApp (EVar "coreCtorImportEntries") (EVar "ctorExportsPerUnit"))))
(DTypeSig false "coreCtorImportEntries" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "coreCtorImportEntries" ((PVar "ctorExportsPerUnit")) (EMatch (EApp (EApp (EVar "lookupCtorExports") (ELit (LString "core"))) (EVar "ctorExportsPerUnit")) (arm (PCon "Some" (PVar "entries")) () (EApp (EApp (EVar "flatMap") (EVar "coreCtorEntry")) (EVar "entries"))) (arm (PCon "None") () (EListLit))))
(DTypeSig false "coreCtorEntry" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "coreCtorEntry" ((PTuple PWild (PVar "ctors"))) (EApp (EApp (EVar "flatMap") (ELam ((PVar "n")) (EListLit (ETuple (EVar "n") (EApp (EApp (EVar "mangledName") (ELit (LString "core"))) (EVar "n")))))) (EVar "ctors")))
(DTypeSig false "declCtorImportEntries" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "declCtorImportEntries" ((PVar "ctorExportsPerUnit") (PCon "DUse" PWild (PVar "path") PWild)) (EApp (EApp (EVar "useCtorPathEntries") (EVar "ctorExportsPerUnit")) (EVar "path")))
(DFunDef false "declCtorImportEntries" ((PVar "ctorExportsPerUnit") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EVar "declCtorImportEntries") (EVar "ctorExportsPerUnit")) (EVar "d")))
(DFunDef false "declCtorImportEntries" (PWild PWild) (EListLit))
(DTypeSig false "useCtorPathEntries" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyFun (TyCon "UsePath") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "useCtorPathEntries" ((PVar "ctorExportsPerUnit") (PVar "path")) (EBlock (DoLet false false (PVar "mid") (EApp (EVar "useModIdU") (EVar "path"))) (DoExpr (EIf (EBinOp "==" (EVar "mid") (ELit (LString "core"))) (EListLit) (EMatch (EApp (EApp (EVar "lookupCtorExports") (EVar "mid")) (EVar "ctorExportsPerUnit")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "typeEntries")) () (EMatch (EVar "path") (arm (PCon "UseGroup" PWild (PVar "members")) () (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "ctorMemberEntry") (EVar "mid")) (EVar "typeEntries"))) (EVar "members"))) (arm (PCon "UseWild" PWild) () (EApp (EApp (EVar "flatMap") (EApp (EVar "typeCtorEntries") (EVar "mid"))) (EVar "typeEntries"))) (arm (PCon "UseName" PWild) () (EListLit)) (arm (PCon "UseAlias" PWild PWild) () (EListLit)))))))))
(DTypeSig false "ctorMemberEntry" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyCon "UseMember") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "ctorMemberEntry" ((PVar "mid") (PVar "typeEntries") (PCon "UseMember" (PVar "name") (PVar "wild") PWild PWild)) (EIf (EVar "wild") (EMatch (EApp (EApp (EVar "lookupCtorTypeEntry") (EVar "name")) (EVar "typeEntries")) (arm (PCon "Some" (PVar "ctors")) () (EBinOp "++" (EApp (EApp (EApp (EVar "bareCtorMemberEntry") (EVar "mid")) (EVar "typeEntries")) (EVar "name")) (EApp (EApp (EVar "flatMap") (EApp (EVar "originCtorEntry") (EVar "mid"))) (EVar "ctors")))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "bareCtorMemberEntry") (EVar "mid")) (EVar "typeEntries")) (EVar "name")))) (EApp (EApp (EApp (EVar "bareCtorMemberEntry") (EVar "mid")) (EVar "typeEntries")) (EVar "name"))))
(DTypeSig false "bareCtorMemberEntry" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "bareCtorMemberEntry" ((PVar "mid") (PVar "typeEntries") (PVar "name")) (EIf (EApp (EApp (EVar "contains") (EVar "name")) (EApp (EApp (EVar "flatMap") (EVar "snd")) (EVar "typeEntries"))) (EApp (EApp (EVar "originCtorEntry") (EVar "mid")) (EVar "name")) (EListLit)))
(DTypeSig false "typeCtorEntries" (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "typeCtorEntries" ((PVar "mid") (PTuple PWild (PVar "ctors"))) (EApp (EApp (EVar "flatMap") (EApp (EVar "originCtorEntry") (EVar "mid"))) (EVar "ctors")))
(DTypeSig false "originCtorEntry" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "originCtorEntry" ((PVar "mid") (PVar "n")) (EListLit (ETuple (EVar "n") (EApp (EApp (EVar "mangledName") (EVar "mid")) (EVar "n")))))
(DTypeSig false "lookupCtorTypeEntry" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "lookupCtorTypeEntry" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupCtorTypeEntry" ((PVar "k") (PCons (PTuple (PVar "t") (PVar "cs")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "t")) (EApp (EVar "Some") (EVar "cs")) (EApp (EApp (EVar "lookupCtorTypeEntry") (EVar "k")) (EVar "rest"))))
(DTypeSig false "lookupCtorExports" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "lookupCtorExports" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupCtorExports" ((PVar "k") (PCons (PTuple (PVar "m") (PVar "es")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "m")) (EApp (EVar "Some") (EVar "es")) (EApp (EApp (EVar "lookupCtorExports") (EVar "k")) (EVar "rest"))))
(DTypeSig false "mangleModule" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "mangleModule" ((PVar "exportsPerUnit") (PVar "ctorExportsPerUnit") (PTuple (PVar "mid") (PVar "decls"))) (ETuple (EVar "mid") (EApp (EApp (EApp (EVar "mangleUnitU") (EVar "exportsPerUnit")) (EVar "ctorExportsPerUnit")) (ETuple (EVar "mid") (EVar "decls")))))
(DTypeSig false "mangleUnitU" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "mangleUnitU" ((PVar "exportsPerUnit") (PVar "ctorExportsPerUnit") (PTuple (PVar "mid") (PVar "decls"))) (EBlock (DoLet false false (PVar "rmFn") (EApp (EApp (EApp (EVar "buildUnitRenameMap") (EVar "mid")) (EVar "exportsPerUnit")) (EVar "decls"))) (DoLet false false (PVar "rmCtor") (EApp (EApp (EApp (EVar "buildUnitCtorRenameMap") (EVar "mid")) (EVar "ctorExportsPerUnit")) (EVar "decls"))) (DoLet false false (PVar "rmList") (EBinOp "++" (EVar "rmFn") (EVar "rmCtor"))) (DoLet false false (PVar "rm") (EApp (EApp (EVar "omFromPairs") (EApp (EVar "reverseL") (EVar "rmList"))) (EVar "omEmpty"))) (DoExpr (EIf (EApp (EVar "isEmptyL") (EVar "rmList")) (EVar "decls") (EApp (EApp (EVar "map") (EApp (EVar "renameDecl") (EVar "rm"))) (EVar "decls"))))))
(DTypeSig false "buildUnitRenameMap" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "buildUnitRenameMap" ((PVar "mid") (PVar "exportsPerUnit") (PVar "decls")) (EBlock (DoLet false false (PVar "localFns") (EApp (EVar "dedup") (EApp (EVar "unitDefNames") (ETuple (EVar "mid") (EVar "decls"))))) (DoLet false false (PVar "localEntries") (EApp (EApp (EVar "flatMap") (EApp (EVar "localRenameEntry") (EVar "mid"))) (EVar "localFns"))) (DoLet false false (PVar "importEntries") (EApp (EApp (EApp (EVar "importRenameEntries") (EVar "mid")) (EVar "exportsPerUnit")) (EVar "decls"))) (DoExpr (EBinOp "++" (EVar "localEntries") (EVar "importEntries")))))
(DTypeSig false "notIfaceMethodKey" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyTuple (TyCon "String") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "notIfaceMethodKey" ((PVar "methods") (PTuple (PVar "n") PWild)) (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "methods"))))
(DTypeSig false "unitIfaceMethodNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "unitIfaceMethodNames" ((PList)) (EListLit))
(DFunDef false "unitIfaceMethodNames" ((PCons (PRec "DInterface" ((rf "methods" None)) true) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "map") (EVar "ifaceMethodNameM")) (EVar "methods")) (EApp (EVar "unitIfaceMethodNames") (EVar "rest"))))
(DFunDef false "unitIfaceMethodNames" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EBinOp "++" (EApp (EVar "unitIfaceMethodNames") (EListLit (EVar "d"))) (EApp (EVar "unitIfaceMethodNames") (EVar "rest"))))
(DFunDef false "unitIfaceMethodNames" ((PCons PWild (PVar "rest"))) (EApp (EVar "unitIfaceMethodNames") (EVar "rest")))
(DTypeSig false "ifaceMethodNameM" (TyFun (TyCon "IfaceMethod") (TyCon "String")))
(DFunDef false "ifaceMethodNameM" ((PCon "IfaceMethod" (PVar "n") PWild PWild PWild)) (EVar "n"))
(DTypeSig false "localRenameEntry" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "localRenameEntry" ((PVar "mid") (PVar "n")) (EIf (EApp (EVar "isExcludedName") (EVar "n")) (EListLit) (EIf (EVar "otherwise") (EListLit (ETuple (EVar "n") (EApp (EApp (EVar "mangledName") (EVar "mid")) (EVar "n")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "isExcludedName" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isExcludedName" ((PVar "n")) (EBinOp "==" (EVar "n") (ELit (LString "main"))))
(DTypeSig false "importRenameEntries" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "importRenameEntries" (PWild (PVar "exportsPerUnit") (PVar "decls")) (EBinOp "++" (EApp (EApp (EVar "flatMap") (EApp (EVar "declImportEntries") (EVar "exportsPerUnit"))) (EVar "decls")) (EApp (EApp (EVar "filterList") (EApp (EVar "notIfaceMethodKey") (EApp (EApp (EVar "omFromNames") (EApp (EVar "unitIfaceMethodNames") (EVar "decls"))) (EVar "omEmpty")))) (EApp (EVar "coreImportEntries") (EVar "exportsPerUnit")))))
(DTypeSig false "coreImportEntries" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "coreImportEntries" ((PVar "exportsPerUnit")) (EMatch (EApp (EApp (EVar "lookupExports") (ELit (LString "core"))) (EVar "exportsPerUnit")) (arm (PCon "Some" (PVar "names")) () (EApp (EApp (EVar "flatMap") (EVar "coreEntry")) (EVar "names"))) (arm (PCon "None") () (EListLit))))
(DTypeSig false "coreEntry" (TyFun (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "coreEntry" ((PTuple (PVar "n") (PVar "definer"))) (EIf (EApp (EVar "isExcludedName") (EVar "n")) (EListLit) (EIf (EVar "otherwise") (EListLit (ETuple (EVar "n") (EApp (EApp (EVar "mangledName") (EVar "definer")) (EVar "n")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "declImportEntries" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))) (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "declImportEntries" ((PVar "exportsPerUnit") (PCon "DUse" PWild (PVar "path") PWild)) (EApp (EApp (EVar "usePathEntries") (EVar "exportsPerUnit")) (EVar "path")))
(DFunDef false "declImportEntries" ((PVar "exportsPerUnit") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EVar "declImportEntries") (EVar "exportsPerUnit")) (EVar "d")))
(DFunDef false "declImportEntries" (PWild PWild) (EListLit))
(DTypeSig false "usePathEntries" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))) (TyFun (TyCon "UsePath") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "usePathEntries" ((PVar "exportsPerUnit") (PVar "path")) (EBlock (DoLet false false (PVar "mid") (EApp (EVar "useModIdU") (EVar "path"))) (DoExpr (EIf (EBinOp "==" (EVar "mid") (ELit (LString "core"))) (EListLit) (EMatch (EApp (EApp (EVar "lookupExports") (EVar "mid")) (EVar "exportsPerUnit")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "exports")) () (EMatch (EVar "path") (arm (PCon "UseGroup" PWild (PVar "members")) () (EApp (EApp (EVar "flatMap") (EApp (EVar "memberEntry") (EVar "exports"))) (EVar "members"))) (arm (PCon "UseWild" PWild) () (EApp (EApp (EVar "flatMap") (EVar "originEntryPair")) (EVar "exports"))) (arm (PCon "UseName" (PVar "ns")) () (EApp (EApp (EVar "originEntry") (EVar "exports")) (EApp (EVar "lastOfPM") (EVar "ns")))) (arm (PCon "UseAlias" PWild (PVar "a")) () (EApp (EApp (EVar "flatMap") (EApp (EVar "aliasEntryPair") (EVar "a"))) (EVar "exports"))))))))))
(DTypeSig false "memberEntry" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "UseMember") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "memberEntry" ((PVar "exports") (PVar "m")) (EApp (EApp (EApp (EVar "originEntryAs") (EVar "exports")) (EApp (EVar "useMemberOrigin") (EVar "m"))) (EApp (EVar "useMemberLocal") (EVar "m"))))
(DTypeSig false "originEntry" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "originEntry" ((PVar "exports") (PVar "n")) (EApp (EApp (EApp (EVar "originEntryAs") (EVar "exports")) (EVar "n")) (EVar "n")))
(DTypeSig false "originEntryAs" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "originEntryAs" ((PVar "exports") (PVar "origin") (PVar "local")) (EIf (EApp (EVar "isExcludedName") (EVar "origin")) (EListLit) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "lookupDefiner") (EVar "origin")) (EVar "exports")) (arm (PCon "Some" (PVar "definer")) () (EListLit (ETuple (EVar "local") (EApp (EApp (EVar "mangledName") (EVar "definer")) (EVar "origin"))))) (arm (PCon "None") () (EListLit))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "originEntryPair" (TyFun (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "originEntryPair" () (EVar "coreEntry"))
(DTypeSig false "aliasEntryPair" (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "aliasEntryPair" ((PVar "a") (PTuple (PVar "n") (PVar "definer"))) (EIf (EApp (EVar "isExcludedName") (EVar "n")) (EListLit) (EIf (EVar "otherwise") (EListLit (ETuple (EApp (EApp (EVar "qualifiedLocal") (EVar "a")) (EVar "n")) (EApp (EApp (EVar "mangledName") (EVar "definer")) (EVar "n")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "useModIdU" (TyFun (TyCon "UsePath") (TyCon "String")))
(DFunDef false "useModIdU" ((PCon "UseName" (PVar "ns"))) (EIf (EApp (EVar "lenGt1") (EVar "ns")) (EApp (EVar "joinDot") (EApp (EVar "initList") (EVar "ns"))) (EApp (EApp (EVar "firstOrU") (ELit (LString ""))) (EVar "ns"))))
(DFunDef false "useModIdU" ((PCon "UseGroup" (PVar "ns") PWild)) (EApp (EVar "joinDot") (EVar "ns")))
(DFunDef false "useModIdU" ((PCon "UseWild" (PVar "ns"))) (EApp (EVar "joinDot") (EVar "ns")))
(DFunDef false "useModIdU" ((PCon "UseAlias" (PVar "ns") PWild)) (EApp (EVar "joinDot") (EVar "ns")))
(DTypeSig false "lenGt1" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "Bool")))
(DFunDef false "lenGt1" ((PCons PWild (PCons PWild PWild))) (EVar "True"))
(DFunDef false "lenGt1" (PWild) (EVar "False"))
(DTypeSig false "firstOrU" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))
(DFunDef false "firstOrU" ((PVar "d") (PList)) (EVar "d"))
(DFunDef false "firstOrU" (PWild (PCons (PVar "x") PWild)) (EVar "x"))
(DTypeSig false "lastOfPM" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "lastOfPM" ((PList)) (ELit (LString "")))
(DFunDef false "lastOfPM" ((PList (PVar "x"))) (EVar "x"))
(DFunDef false "lastOfPM" ((PCons PWild (PVar "rest"))) (EApp (EVar "lastOfPM") (EVar "rest")))
(DTypeSig false "lookupExports" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "lookupExports" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupExports" ((PVar "k") (PCons (PTuple (PVar "m") (PVar "ns")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "m")) (EApp (EVar "Some") (EVar "ns")) (EApp (EApp (EVar "lookupExports") (EVar "k")) (EVar "rest"))))
(DTypeSig false "pubFnNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "pubFnNames" ((PVar "decls")) (EBlock (DoLet false false (PVar "defined") (EApp (EApp (EVar "omFromNames") (EApp (EVar "unitDefNames") (ETuple (ELit (LString "")) (EVar "decls")))) (EVar "omEmpty"))) (DoLet false false (PVar "pubSigs") (EApp (EVar "pubSigNames") (EVar "decls"))) (DoLet false false (PVar "pubDefs") (EApp (EVar "pubDefNames") (EVar "decls"))) (DoExpr (EApp (EApp (EVar "filterList") (ELam ((PVar "n")) (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "defined")))) (EBinOp "++" (EVar "pubSigs") (EVar "pubDefs"))))))
(DTypeSig false "pubDefNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "pubDefNames" ((PList)) (EListLit))
(DFunDef false "pubDefNames" ((PCons (PCon "DFunDef" (PCon "True") (PVar "n") PWild PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "pubDefNames") (EVar "rest"))))
(DFunDef false "pubDefNames" ((PCons (PCon "DLetGroup" (PCon "True") (PVar "binds")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "map") (EVar "letBindName")) (EVar "binds")) (EApp (EVar "pubDefNames") (EVar "rest"))))
(DFunDef false "pubDefNames" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EBinOp "++" (EApp (EVar "pubDefNames") (EListLit (EVar "d"))) (EApp (EVar "pubDefNames") (EVar "rest"))))
(DFunDef false "pubDefNames" ((PCons PWild (PVar "rest"))) (EApp (EVar "pubDefNames") (EVar "rest")))
(DTypeSig false "unitDefNames" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "unitDefNames" ((PTuple PWild (PVar "decls"))) (EApp (EApp (EVar "flatMap") (EVar "declDefNames")) (EVar "decls")))
(DTypeSig false "declDefNames" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "declDefNames" ((PCon "DFunDef" PWild (PVar "n") PWild PWild)) (EListLit (EVar "n")))
(DFunDef false "declDefNames" ((PCon "DLetGroup" PWild (PVar "binds"))) (EApp (EApp (EVar "map") (EVar "letBindName")) (EVar "binds")))
(DFunDef false "declDefNames" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "declDefNames") (EVar "d")))
(DFunDef false "declDefNames" (PWild) (EListLit))
(DTypeSig false "letBindName" (TyFun (TyCon "LetBind") (TyCon "String")))
(DFunDef false "letBindName" ((PCon "LetBind" (PVar "n") PWild)) (EVar "n"))
(DTypeSig false "pubSigNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "pubSigNames" ((PList)) (EListLit))
(DFunDef false "pubSigNames" ((PCons (PCon "DTypeSig" (PCon "True") (PVar "n") PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "pubSigNames") (EVar "rest"))))
(DFunDef false "pubSigNames" ((PCons (PCon "DExtern" (PCon "True") (PVar "n") PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "pubSigNames") (EVar "rest"))))
(DFunDef false "pubSigNames" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EBinOp "++" (EApp (EVar "pubSigNames") (EListLit (EVar "d"))) (EApp (EVar "pubSigNames") (EVar "rest"))))
(DFunDef false "pubSigNames" ((PCons PWild (PVar "rest"))) (EApp (EVar "pubSigNames") (EVar "rest")))
(DTypeSig true "mangledName" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "mangledName" ((PVar "mid") (PVar "name")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "sanitizeId") (EVar "mid")))) (ELit (LString "__"))) (EApp (EVar "display") (EVar "name"))) (ELit (LString ""))))
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
(DFunDef false "hashChars" ((PVar "cs") (PVar "i") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "cs"))) (EVar "acc") (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "hashChars") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EBinOp "*" (EVar "acc") (ELit (LInt 33))) (EApp (EVar "charCode") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "dictTag" (TyFun (TyCon "String") (TyCon "Int")))
(DFunDef false "dictTag" ((PVar "s")) (EApp (EApp (EVar "posMod") (EApp (EVar "hashName") (EVar "s"))) (ELit (LInt 1073741824))))
(DTypeSig true "posMod" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "posMod" ((PVar "n") (PVar "m")) (EBinOp "%" (EBinOp "+" (EBinOp "%" (EVar "n") (EVar "m")) (EVar "m")) (EVar "m")))
(DTypeSig false "renameDecl" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "Decl") (TyCon "Decl"))))
(DFunDef false "renameDecl" ((PVar "rm") (PCon "DFunDef" (PVar "pub") (PVar "n") (PVar "ps") (PVar "e"))) (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "pub")) (EApp (EApp (EVar "renameDefName") (EVar "rm")) (EVar "n"))) (EApp (EApp (EVar "renamePatsPM") (EVar "rm")) (EVar "ps"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EApp (EVar "boundOfListPM") (EApp (EVar "patVarsListPM") (EVar "ps")))) (EVar "e"))))
(DFunDef false "renameDecl" ((PVar "rm") (PCon "DTypeSig" (PVar "pub") (PVar "n") (PVar "ty"))) (EApp (EApp (EApp (EVar "DTypeSig") (EVar "pub")) (EApp (EApp (EVar "renameDefName") (EVar "rm")) (EVar "n"))) (EVar "ty")))
(DFunDef false "renameDecl" ((PVar "rm") (PAs "d" (PRec "DInterface" ((rf "methods" None)) true))) (EVariantUpdate "DInterface" (EVar "d") ((fa "methods" (EApp (EApp (EVar "map") (EApp (EVar "renameIfaceMethod") (EVar "rm"))) (EVar "methods"))))))
(DFunDef false "renameDecl" ((PVar "rm") (PAs "d" (PRec "DImpl" ((rf "methods" None)) true))) (EVariantUpdate "DImpl" (EVar "d") ((fa "methods" (EApp (EApp (EVar "map") (EApp (EVar "renameImplMethod") (EVar "rm"))) (EVar "methods"))))))
(DFunDef false "renameDecl" ((PVar "rm") (PCon "DProp" (PVar "pub") (PVar "name") (PVar "params") (PVar "body"))) (EApp (EApp (EApp (EApp (EVar "DProp") (EVar "pub")) (EVar "name")) (EVar "params")) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EApp (EVar "boundOfListPM") (EApp (EVar "propParamNamesPM") (EVar "params")))) (EVar "body"))))
(DFunDef false "renameDecl" ((PVar "rm") (PCon "DTest" (PVar "pub") (PVar "name") (PVar "body"))) (EApp (EApp (EApp (EVar "DTest") (EVar "pub")) (EVar "name")) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "omEmpty")) (EVar "body"))))
(DFunDef false "renameDecl" ((PVar "rm") (PCon "DBench" (PVar "pub") (PVar "name") (PVar "body"))) (EApp (EApp (EApp (EVar "DBench") (EVar "pub")) (EVar "name")) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "omEmpty")) (EVar "body"))))
(DFunDef false "renameDecl" ((PVar "rm") (PCon "DLetGroup" (PVar "pub") (PVar "binds"))) (EApp (EApp (EVar "DLetGroup") (EVar "pub")) (EApp (EApp (EVar "map") (EApp (EVar "renameLetBindDef") (EVar "rm"))) (EVar "binds"))))
(DFunDef false "renameDecl" ((PVar "rm") (PAs "d" (PRec "DData" ((rf "dataCtors" (PVar "variants"))) false))) (EVariantUpdate "DData" (EVar "d") ((fa "dataCtors" (EApp (EApp (EVar "map") (EApp (EVar "renameVariant") (EVar "rm"))) (EVar "variants"))))))
(DFunDef false "renameDecl" ((PVar "rm") (PAs "d" (PRec "DNewtype" ((rf "newtypeCtor" (PVar "con"))) false))) (EVariantUpdate "DNewtype" (EVar "d") ((fa "newtypeCtor" (EApp (EApp (EVar "renameDefName") (EVar "rm")) (EVar "con"))))))
(DFunDef false "renameDecl" ((PVar "rm") (PCon "DAttrib" (PVar "attrs") (PVar "d"))) (EApp (EApp (EVar "DAttrib") (EVar "attrs")) (EApp (EApp (EVar "renameDecl") (EVar "rm")) (EVar "d"))))
(DFunDef false "renameDecl" (PWild (PVar "d")) (EVar "d"))
(DTypeSig false "renameVariant" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "Variant") (TyCon "Variant"))))
(DFunDef false "renameVariant" ((PVar "rm") (PCon "Variant" (PVar "n") (PVar "payload"))) (EApp (EApp (EVar "Variant") (EApp (EApp (EVar "renameDefName") (EVar "rm")) (EVar "n"))) (EVar "payload")))
(DTypeSig false "renameLetBindDef" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "LetBind") (TyCon "LetBind"))))
(DFunDef false "renameLetBindDef" ((PVar "rm") (PCon "LetBind" (PVar "n") (PVar "clauses"))) (EApp (EApp (EVar "LetBind") (EApp (EApp (EVar "renameDefName") (EVar "rm")) (EVar "n"))) (EApp (EApp (EVar "map") (EApp (EApp (EVar "renameFunClause") (EVar "rm")) (EVar "omEmpty"))) (EVar "clauses"))))
(DTypeSig false "renameDefName" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "renameDefName" ((PVar "rm") (PVar "n")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "rm")) (arm (PCon "Some" (PVar "n2")) () (EVar "n2")) (arm (PCon "None") () (EVar "n"))))
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
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EFieldAccess" (PVar "e0") (PVar "n") (PVar "r"))) (EApp (EApp (EApp (EVar "EFieldAccess") (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e0"))) (EVar "n")) (EVar "r")))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "ETuple" (PVar "es"))) (EApp (EVar "ETuple") (EApp (EApp (EVar "map") (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound"))) (EVar "es"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EListLit" (PVar "es"))) (EApp (EVar "EListLit") (EApp (EApp (EVar "map") (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound"))) (EVar "es"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EArrayLit" (PVar "es"))) (EApp (EVar "EArrayLit") (EApp (EApp (EVar "map") (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound"))) (EVar "es"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "ERangeList" (PVar "lo") (PVar "hi") (PVar "i"))) (EApp (EApp (EApp (EVar "ERangeList") (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "lo"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "hi"))) (EVar "i")))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "ERangeArray" (PVar "lo") (PVar "hi") (PVar "i"))) (EApp (EApp (EApp (EVar "ERangeArray") (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "lo"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "hi"))) (EVar "i")))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "ESlice" (PVar "e0") (PVar "lo") (PVar "hi") (PVar "i") (PVar "r"))) (EApp (EApp (EApp (EApp (EApp (EVar "ESlice") (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e0"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "lo"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "hi"))) (EVar "i")) (EVar "r")))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EIndex" (PVar "e0") (PVar "i") (PVar "r"))) (EApp (EApp (EApp (EVar "EIndex") (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e0"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "i"))) (EVar "r")))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EAnnot" (PVar "e0") (PVar "t"))) (EApp (EApp (EVar "EAnnot") (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e0"))) (EVar "t")))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EHeadAnnot" (PVar "e0") (PVar "t"))) (EApp (EApp (EVar "EHeadAnnot") (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e0"))) (EVar "t")))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "ERecordCreate" (PVar "n") (PVar "fs"))) (EApp (EApp (EVar "ERecordCreate") (EApp (EApp (EVar "renameDefName") (EVar "rm")) (EVar "n"))) (EApp (EApp (EVar "map") (EApp (EApp (EVar "renameField") (EVar "rm")) (EVar "bound"))) (EVar "fs"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "ERecordUpdate" (PVar "e0") (PVar "fs") (PVar "r"))) (EApp (EApp (EApp (EVar "ERecordUpdate") (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e0"))) (EApp (EApp (EVar "map") (EApp (EApp (EVar "renameField") (EVar "rm")) (EVar "bound"))) (EVar "fs"))) (EVar "r")))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EVariantUpdate" (PVar "c") (PVar "e0") (PVar "fs"))) (EApp (EApp (EApp (EVar "EVariantUpdate") (EApp (EApp (EVar "renameDefName") (EVar "rm")) (EVar "c"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e0"))) (EApp (EApp (EVar "map") (EApp (EApp (EVar "renameField") (EVar "rm")) (EVar "bound"))) (EVar "fs"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EStringInterp" (PVar "parts"))) (EApp (EVar "EStringInterp") (EApp (EApp (EVar "map") (EApp (EApp (EVar "renameInterp") (EVar "rm")) (EVar "bound"))) (EVar "parts"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EGuards" (PVar "arms"))) (EApp (EVar "EGuards") (EApp (EApp (EVar "map") (EApp (EApp (EVar "renameGuardArm") (EVar "rm")) (EVar "bound"))) (EVar "arms"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "ESection" (PCon "SecRight" (PVar "op") (PVar "e0")))) (EApp (EVar "ESection") (EApp (EApp (EVar "SecRight") (EVar "op")) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e0")))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "ESection" (PCon "SecLeft" (PVar "e0") (PVar "op")))) (EApp (EVar "ESection") (EApp (EApp (EVar "SecLeft") (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e0"))) (EVar "op"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EMapLit" (PVar "n") (PVar "kvs"))) (EApp (EApp (EVar "EMapLit") (EVar "n")) (EApp (EApp (EVar "map") (EApp (EApp (EVar "renameKv") (EVar "rm")) (EVar "bound"))) (EVar "kvs"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "ESetLit" (PVar "n") (PVar "es"))) (EApp (EApp (EVar "ESetLit") (EVar "n")) (EApp (EApp (EVar "map") (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound"))) (EVar "es"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EAsPat" (PVar "x") (PVar "sub"))) (EApp (EApp (EVar "EAsPat") (EVar "x")) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "sub"))))
(DFunDef false "renameScoped" (PWild PWild (PVar "e")) (EVar "e"))
(DTypeSig false "renameField" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "FieldAssign") (TyCon "FieldAssign")))))
(DFunDef false "renameField" ((PVar "rm") (PVar "bound") (PCon "FieldAssign" (PVar "n") (PVar "e"))) (EApp (EApp (EVar "FieldAssign") (EVar "n")) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e"))))
(DTypeSig false "renameKv" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyTuple (TyCon "Expr") (TyCon "Expr")) (TyTuple (TyCon "Expr") (TyCon "Expr"))))))
(DFunDef false "renameKv" ((PVar "rm") (PVar "bound") (PTuple (PVar "k") (PVar "v"))) (ETuple (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "k")) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "v"))))
(DTypeSig false "renameInterp" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "InterpPart") (TyCon "InterpPart")))))
(DFunDef false "renameInterp" (PWild PWild (PCon "InterpStr" (PVar "s"))) (EApp (EVar "InterpStr") (EVar "s")))
(DFunDef false "renameInterp" ((PVar "rm") (PVar "bound") (PCon "InterpExpr" (PVar "e"))) (EApp (EVar "InterpExpr") (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e"))))
(DTypeSig false "renameLetBind" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "LetBind") (TyCon "LetBind")))))
(DFunDef false "renameLetBind" ((PVar "rm") (PVar "bound") (PCon "LetBind" (PVar "n") (PVar "clauses"))) (EApp (EApp (EVar "LetBind") (EApp (EApp (EVar "renameDefName") (EVar "rm")) (EVar "n"))) (EApp (EApp (EVar "map") (EApp (EApp (EVar "renameFunClause") (EVar "rm")) (EVar "bound"))) (EVar "clauses"))))
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
(DFunDef false "renameStmts" ((PVar "rm") (PVar "bound") (PCons (PCon "DoLet" (PVar "m") (PVar "r") (PVar "p") (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false (PVar "b1") (EIf (EVar "r") (EApp (EApp (EVar "boundInsertPM") (EApp (EVar "patVarsPM") (EVar "p"))) (EVar "bound")) (EVar "bound"))) (DoExpr (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "DoLet") (EVar "m")) (EVar "r")) (EApp (EApp (EVar "renamePat") (EVar "rm")) (EVar "p"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "b1")) (EVar "e"))) (EApp (EApp (EApp (EVar "renameStmts") (EVar "rm")) (EApp (EApp (EVar "boundInsertPM") (EApp (EVar "patVarsPM") (EVar "p"))) (EVar "bound"))) (EVar "rest"))))))
(DFunDef false "renameStmts" ((PVar "rm") (PVar "bound") (PCons (PCon "DoAssign" (PVar "x") (PVar "e")) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EVar "DoAssign") (EVar "x")) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e"))) (EApp (EApp (EApp (EVar "renameStmts") (EVar "rm")) (EVar "bound")) (EVar "rest"))))
(DFunDef false "renameStmts" ((PVar "rm") (PVar "bound") (PCons (PCon "DoFieldAssign" (PVar "x") (PVar "fs") (PVar "e")) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EApp (EVar "DoFieldAssign") (EVar "x")) (EVar "fs")) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e"))) (EApp (EApp (EApp (EVar "renameStmts") (EVar "rm")) (EVar "bound")) (EVar "rest"))))
(DTypeSig false "letBindNamesPM" (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "letBindNamesPM" ((PVar "binds")) (EApp (EApp (EVar "map") (EVar "letBindName")) (EVar "binds")))
(DTypeSig false "patVarsPM" (TyFun (TyCon "Pat") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "patVarsPM" ((PCon "PVar" (PVar "x") PWild)) (EListLit (EVar "x")))
(DFunDef false "patVarsPM" ((PCon "PCon" PWild (PVar "args"))) (EApp (EVar "patVarsListPM") (EVar "args")))
(DFunDef false "patVarsPM" ((PCon "PCons" (PVar "h") (PVar "t"))) (EBinOp "++" (EApp (EVar "patVarsPM") (EVar "h")) (EApp (EVar "patVarsPM") (EVar "t"))))
(DFunDef false "patVarsPM" ((PCon "PTuple" (PVar "ps"))) (EApp (EVar "patVarsListPM") (EVar "ps")))
(DFunDef false "patVarsPM" ((PCon "PList" (PVar "ps"))) (EApp (EVar "patVarsListPM") (EVar "ps")))
(DFunDef false "patVarsPM" ((PCon "PAs" (PVar "x") PWild (PVar "p"))) (EBinOp "::" (EVar "x") (EApp (EVar "patVarsPM") (EVar "p"))))
(DFunDef false "patVarsPM" ((PCon "PRec" PWild (PVar "fields") PWild)) (EApp (EApp (EVar "flatMap") (EVar "recPatFieldVarsPM")) (EVar "fields")))
(DFunDef false "patVarsPM" (PWild) (EListLit))
(DTypeSig false "patVarsListPM" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "patVarsListPM" ((PVar "ps")) (EApp (EApp (EVar "flatMap") (EVar "patVarsPM")) (EVar "ps")))
(DTypeSig false "renamePat" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "Pat") (TyCon "Pat"))))
(DFunDef false "renamePat" ((PVar "rm") (PCon "PCon" (PVar "n") (PVar "args"))) (EApp (EApp (EVar "PCon") (EApp (EApp (EVar "renameDefName") (EVar "rm")) (EVar "n"))) (EApp (EApp (EVar "map") (EApp (EVar "renamePat") (EVar "rm"))) (EVar "args"))))
(DFunDef false "renamePat" ((PVar "rm") (PCon "PCons" (PVar "h") (PVar "t"))) (EApp (EApp (EVar "PCons") (EApp (EApp (EVar "renamePat") (EVar "rm")) (EVar "h"))) (EApp (EApp (EVar "renamePat") (EVar "rm")) (EVar "t"))))
(DFunDef false "renamePat" ((PVar "rm") (PCon "PTuple" (PVar "ps"))) (EApp (EVar "PTuple") (EApp (EApp (EVar "map") (EApp (EVar "renamePat") (EVar "rm"))) (EVar "ps"))))
(DFunDef false "renamePat" ((PVar "rm") (PCon "PList" (PVar "ps"))) (EApp (EVar "PList") (EApp (EApp (EVar "map") (EApp (EVar "renamePat") (EVar "rm"))) (EVar "ps"))))
(DFunDef false "renamePat" ((PVar "rm") (PCon "PAs" (PVar "x") (PVar "l") (PVar "p"))) (EApp (EApp (EApp (EVar "PAs") (EVar "x")) (EVar "l")) (EApp (EApp (EVar "renamePat") (EVar "rm")) (EVar "p"))))
(DFunDef false "renamePat" ((PVar "rm") (PCon "PRec" (PVar "n") (PVar "fields") (PVar "open"))) (EApp (EApp (EApp (EVar "PRec") (EApp (EApp (EVar "renameDefName") (EVar "rm")) (EVar "n"))) (EApp (EApp (EVar "map") (EApp (EVar "renameRecPatField") (EVar "rm"))) (EVar "fields"))) (EVar "open")))
(DFunDef false "renamePat" (PWild (PVar "p")) (EVar "p"))
(DTypeSig false "renameRecPatField" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "RecPatField") (TyCon "RecPatField"))))
(DFunDef false "renameRecPatField" (PWild (PCon "RecPatField" (PVar "label") (PVar "l") (PCon "None"))) (EApp (EApp (EApp (EVar "RecPatField") (EVar "label")) (EVar "l")) (EVar "None")))
(DFunDef false "renameRecPatField" ((PVar "rm") (PCon "RecPatField" (PVar "label") (PVar "l") (PCon "Some" (PVar "p")))) (EApp (EApp (EApp (EVar "RecPatField") (EVar "label")) (EVar "l")) (EApp (EVar "Some") (EApp (EApp (EVar "renamePat") (EVar "rm")) (EVar "p")))))
(DTypeSig false "renamePatsPM" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyApp (TyCon "List") (TyCon "Pat")))))
(DFunDef false "renamePatsPM" ((PVar "rm") (PVar "ps")) (EApp (EApp (EVar "map") (EApp (EVar "renamePat") (EVar "rm"))) (EVar "ps")))
(DTypeSig false "recPatFieldVarsPM" (TyFun (TyCon "RecPatField") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "recPatFieldVarsPM" ((PCon "RecPatField" (PVar "label") PWild (PCon "None"))) (EListLit (EVar "label")))
(DFunDef false "recPatFieldVarsPM" ((PCon "RecPatField" PWild PWild (PCon "Some" (PVar "p")))) (EApp (EVar "patVarsPM") (EVar "p")))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "Expr" true) (mem "Pat" true) (mem "Arm" true) (mem "Guard" true) (mem "GuardArm" true) (mem "DoStmt" true) (mem "Section" true) (mem "InterpPart" true) (mem "FieldAssign" true) (mem "RecPatField" true) (mem "LetBind" true) (mem "FunClause" true) (mem "IfaceMethod" true) (mem "MethodDefault" true) (mem "ImplMethod" true) (mem "PropParam" true) (mem "UsePath" true) (mem "UseMember" true) (mem "useMemberOrigin" false) (mem "useMemberLocal" false) (mem "qualifiedLocal" false) (mem "Variant" true) (mem "DataVis" true))))
(DUse false (UseGroup ("support" "util") ((mem "contains" false) (mem "reverseL" false) (mem "isEmptyL" false) (mem "filterList" false) (mem "initList" false) (mem "joinDot" false) (mem "dedup" false) (mem "dedupBy" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omInsert" false) (mem "omLookup" false) (mem "omFromPairs" false) (mem "omFromNames" false) (mem "omHasKey" false) (mem "omEmpty" false) (mem "omSize" false))))
(DTypeSig true "mangleUnits" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))))))
(DFunDef false "mangleUnits" ((PVar "coreDecls") (PVar "modules")) (EBlock (DoLet false false (PVar "allUnits") (EBinOp "::" (ETuple (ELit (LString "core")) (EVar "coreDecls")) (EVar "modules"))) (DoLet false false PWild (EApp (EVar "symbolInjectivityGuard") (EVar "allUnits"))) (DoLet false false (PVar "exportsPerUnit") (EApp (EApp (EVar "buildExportsPerUnit") (EListLit)) (EVar "allUnits"))) (DoLet false false (PVar "ctorExportsPerUnit") (EApp (EApp (EMethodRef "map") (EVar "unitCtorExportEntry")) (EVar "allUnits"))) (DoLet false false (PVar "coreOut") (EApp (EApp (EApp (EVar "mangleUnitU") (EVar "exportsPerUnit")) (EVar "ctorExportsPerUnit")) (ETuple (ELit (LString "core")) (EVar "coreDecls")))) (DoLet false false (PVar "modsOut") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "mangleModule") (EVar "exportsPerUnit")) (EVar "ctorExportsPerUnit"))) (EVar "modules"))) (DoExpr (ETuple (EVar "coreOut") (EVar "modsOut")))))
(DTypeSig true "mangleCtorCollisions" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))))))
(DFunDef false "mangleCtorCollisions" ((PVar "coreDecls") (PVar "modules")) (EBlock (DoLet false false (PVar "allUnits") (EBinOp "::" (ETuple (ELit (LString "core")) (EVar "coreDecls")) (EVar "modules"))) (DoLet false false (PVar "collided") (EApp (EVar "collidingCtorNames") (EVar "allUnits"))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "omSize") (EVar "collided")) (ELit (LInt 0))) (ETuple (EVar "coreDecls") (EVar "modules")) (EBlock (DoLet false false (PVar "ctorExportsPerUnit") (EApp (EApp (EMethodRef "map") (EVar "unitCtorExportEntry")) (EVar "allUnits"))) (DoLet false false (PVar "coreOut") (EApp (EApp (EApp (EVar "mangleCtorUnitU") (EVar "collided")) (EVar "ctorExportsPerUnit")) (ETuple (ELit (LString "core")) (EVar "coreDecls")))) (DoLet false false (PVar "modsOut") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "mangleCtorModule") (EVar "collided")) (EVar "ctorExportsPerUnit"))) (EVar "modules"))) (DoExpr (ETuple (EVar "coreOut") (EVar "modsOut"))))))))
(DTypeSig true "mangleCtorCollisionsPair" (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))) (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "mangleCtorCollisionsPair" ((PTuple (PVar "coreDecls") (PVar "modules"))) (EApp (EApp (EVar "mangleCtorCollisions") (EVar "coreDecls")) (EVar "modules")))
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
(DTypeSig false "mangleCtorModule" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "mangleCtorModule" ((PVar "collided") (PVar "ctorExportsPerUnit") (PTuple (PVar "mid") (PVar "decls"))) (ETuple (EVar "mid") (EApp (EApp (EApp (EVar "mangleCtorUnitU") (EVar "collided")) (EVar "ctorExportsPerUnit")) (ETuple (EVar "mid") (EVar "decls")))))
(DTypeSig false "mangleCtorUnitU" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "mangleCtorUnitU" ((PVar "collided") (PVar "ctorExportsPerUnit") (PTuple (PVar "mid") (PVar "decls"))) (EBlock (DoLet false false (PVar "rmList") (EApp (EApp (EVar "filterList") (EApp (EVar "renameKeyCollides") (EVar "collided"))) (EApp (EApp (EApp (EVar "buildUnitCtorRenameMap") (EVar "mid")) (EVar "ctorExportsPerUnit")) (EVar "decls")))) (DoLet false false (PVar "rm") (EApp (EApp (EVar "omFromPairs") (EApp (EVar "reverseL") (EVar "rmList"))) (EVar "omEmpty"))) (DoExpr (EIf (EApp (EVar "isEmptyL") (EVar "rmList")) (EVar "decls") (EApp (EApp (EMethodRef "map") (EApp (EVar "renameDecl") (EVar "rm"))) (EVar "decls"))))))
(DTypeSig false "renameKeyCollides" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyTuple (TyCon "String") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "renameKeyCollides" ((PVar "collided") (PTuple (PVar "n") PWild)) (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "collided")))
(DTypeSig false "symbolInjectivityGuard" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "Unit")))
(DFunDef false "symbolInjectivityGuard" ((PVar "allUnits")) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "checkSymbolsInjective") (ELit (LString "function"))) (EApp (EApp (EDictApp "flatMap") (EVar "unitFnSymbolPairs")) (EVar "allUnits"))) (EVar "omEmpty"))) (DoLet false false PWild (EApp (EApp (EApp (EVar "checkSymbolsInjective") (ELit (LString "constructor"))) (EApp (EApp (EDictApp "flatMap") (EVar "unitCtorSymbolPairs")) (EVar "allUnits"))) (EVar "omEmpty"))) (DoExpr (ELit LUnit))))
(DTypeSig false "unitFnSymbolPairs" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "unitFnSymbolPairs" ((PTuple (PVar "mid") (PVar "decls"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "symbolPreImagePair") (EVar "mid"))) (EApp (EApp (EVar "filterList") (EVar "notExcludedName")) (EApp (EVar "dedup") (EApp (EVar "unitDefNames") (ETuple (EVar "mid") (EVar "decls")))))))
(DTypeSig false "notExcludedName" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "notExcludedName" ((PVar "n")) (EApp (EVar "not") (EApp (EVar "isExcludedName") (EVar "n"))))
(DTypeSig false "unitCtorSymbolPairs" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "unitCtorSymbolPairs" ((PTuple (PVar "mid") (PVar "decls"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "symbolPreImagePair") (EVar "mid"))) (EApp (EVar "dedup") (EApp (EVar "unitLocalCtorNames") (EVar "decls")))))
(DTypeSig false "symbolPreImagePair" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "symbolPreImagePair" ((PVar "mid") (PVar "n")) (ETuple (EApp (EApp (EVar "mangledName") (EVar "mid")) (EVar "n")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "mid"))) (ELit (LString "."))) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "")))))
(DTypeSig false "checkSymbolsInjective" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyCon "Unit")))))
(DFunDef false "checkSymbolsInjective" (PWild (PList) PWild) (ELit LUnit))
(DFunDef false "checkSymbolsInjective" ((PVar "what") (PCons (PTuple (PVar "sym") (PVar "pre")) (PVar "rest")) (PVar "seen")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "sym")) (EVar "seen")) (arm (PCon "None") () (EApp (EApp (EApp (EVar "checkSymbolsInjective") (EVar "what")) (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "sym")) (EVar "pre")) (EVar "seen")))) (arm (PCon "Some" (PVar "prev")) () (EIf (EBinOp "==" (EVar "prev") (EVar "pre")) (EApp (EApp (EApp (EVar "checkSymbolsInjective") (EVar "what")) (EVar "rest")) (EVar "seen")) (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "emitted-symbol collision: ")) (EApp (EMethodRef "display") (EVar "what"))) (ELit (LString "s `"))) (EApp (EMethodRef "display") (EVar "prev"))) (ELit (LString "` and `"))) (EApp (EMethodRef "display") (EVar "pre"))) (ELit (LString "` both mangle to `"))) (EApp (EMethodRef "display") (EVar "sym"))) (ELit (LString "` -- two distinct (module, name) pairs cannot share one emitted symbol, so the emitter would silently keep one and drop the other. Rename one of the two modules so their ids differ after `sanitizeId` (which maps `.`, `/` and `-` all to `_`), or rename one of the two definitions."))))))))
(DTypeSig false "buildExportsPerUnit" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))))
(DFunDef false "buildExportsPerUnit" (PWild (PList)) (EListLit))
(DFunDef false "buildExportsPerUnit" ((PVar "acc") (PCons (PTuple (PVar "mid") (PVar "decls")) (PVar "rest"))) (EBlock (DoLet false false (PVar "entry") (EApp (EApp (EVar "unitExportEntry") (EVar "acc")) (ETuple (EVar "mid") (EVar "decls")))) (DoExpr (EBinOp "::" (EVar "entry") (EApp (EApp (EVar "buildExportsPerUnit") (EBinOp "::" (EVar "entry") (EVar "acc"))) (EVar "rest"))))))
(DTypeSig false "unitExportEntry" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "unitExportEntry" ((PVar "acc") (PTuple (PVar "mid") (PVar "decls"))) (EBlock (DoLet false false (PVar "locals") (EApp (EApp (EMethodRef "map") (ELam ((PVar "n")) (ETuple (EVar "n") (EVar "mid")))) (EApp (EVar "dedup") (EApp (EVar "pubFnNames") (EVar "decls"))))) (DoLet false false (PVar "reexs") (EApp (EApp (EDictApp "flatMap") (EApp (EVar "reexportFnEntries") (EVar "acc"))) (EVar "decls"))) (DoExpr (ETuple (EVar "mid") (EApp (EVar "dedupPairsByName") (EBinOp "++" (EVar "locals") (EVar "reexs")))))))
(DTypeSig false "reexportFnEntries" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))) (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "reexportFnEntries" ((PVar "acc") (PCon "DUse" (PCon "True") (PVar "path") PWild)) (EBlock (DoLet false false (PVar "srcMid") (EApp (EVar "useModIdU") (EVar "path"))) (DoExpr (EMatch (EApp (EApp (EVar "lookupExports") (EVar "srcMid")) (EVar "acc")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "srcExports")) () (EApp (EApp (EVar "reexportMembers") (EVar "path")) (EVar "srcExports")))))))
(DFunDef false "reexportFnEntries" ((PVar "acc") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EVar "reexportFnEntries") (EVar "acc")) (EVar "d")))
(DFunDef false "reexportFnEntries" (PWild PWild) (EListLit))
(DTypeSig false "reexportMembers" (TyFun (TyCon "UsePath") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "reexportMembers" ((PCon "UseGroup" PWild (PVar "members")) (PVar "srcExports")) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "reexportMember") (EVar "srcExports"))) (EVar "members")))
(DFunDef false "reexportMembers" ((PCon "UseWild" PWild) (PVar "srcExports")) (EVar "srcExports"))
(DFunDef false "reexportMembers" ((PCon "UseName" (PVar "ns")) (PVar "srcExports")) (EIf (EApp (EVar "lenGt1") (EVar "ns")) (EApp (EApp (EVar "reexportOne") (EVar "srcExports")) (EApp (EVar "lastOfPM") (EVar "ns"))) (EListLit)))
(DFunDef false "reexportMembers" ((PCon "UseAlias" PWild PWild) PWild) (EListLit))
(DTypeSig false "reexportMember" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "UseMember") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "reexportMember" ((PVar "srcExports") (PVar "m")) (EApp (EApp (EVar "reexportOne") (EVar "srcExports")) (EApp (EVar "useMemberOrigin") (EVar "m"))))
(DTypeSig false "reexportOne" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "reexportOne" ((PVar "srcExports") (PVar "n")) (EMatch (EApp (EApp (EVar "lookupDefiner") (EVar "n")) (EVar "srcExports")) (arm (PCon "Some" (PVar "definer")) () (EListLit (ETuple (EVar "n") (EVar "definer")))) (arm (PCon "None") () (EListLit))))
(DTypeSig false "dedupPairsByName" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "dedupPairsByName" ((PVar "pairs")) (EApp (EApp (EVar "dedupBy") (EVar "fst")) (EVar "pairs")))
(DTypeSig false "lookupDefiner" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "lookupDefiner" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupDefiner" ((PVar "k") (PCons (PTuple (PVar "n") (PVar "d")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "n")) (EApp (EVar "Some") (EVar "d")) (EApp (EApp (EVar "lookupDefiner") (EVar "k")) (EVar "rest"))))
(DTypeSig false "unitCtorExportEntry" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "unitCtorExportEntry" ((PTuple (PVar "mid") (PVar "decls"))) (ETuple (EVar "mid") (EApp (EApp (EDictApp "flatMap") (EVar "ctorExportEntries")) (EVar "decls"))))
(DTypeSig false "ctorExportEntries" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "ctorExportEntries" ((PRec "DData" ((rf "dataVis" (PCon "VisPublic")) (rf "dataName" (PVar "tyname")) (rf "dataCtors" (PVar "variants"))) false)) (EListLit (ETuple (EVar "tyname") (EApp (EApp (EVar "filterList") (EVar "nonReservedCtor")) (EApp (EApp (EMethodRef "map") (EVar "variantCtorName")) (EVar "variants"))))))
(DFunDef false "ctorExportEntries" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "ctorExportEntries") (EVar "d")))
(DFunDef false "ctorExportEntries" (PWild) (EListLit))
(DTypeSig false "variantCtorName" (TyFun (TyCon "Variant") (TyCon "String")))
(DFunDef false "variantCtorName" ((PCon "Variant" (PVar "n") PWild)) (EVar "n"))
(DTypeSig false "nonReservedCtor" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "nonReservedCtor" ((PVar "n")) (EApp (EVar "not") (EApp (EVar "isReservedCtor") (EVar "n"))))
(DTypeSig false "isReservedCtor" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isReservedCtor" ((PVar "n")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "n") (ELit (LString "Cons"))) (EBinOp "==" (EVar "n") (ELit (LString "Nil")))) (EBinOp "==" (EVar "n") (ELit (LString "Some")))) (EBinOp "==" (EVar "n") (ELit (LString "None")))) (EBinOp "==" (EVar "n") (ELit (LString "Ok")))) (EBinOp "==" (EVar "n") (ELit (LString "Err")))) (EBinOp "==" (EVar "n") (ELit (LString "Lt")))) (EBinOp "==" (EVar "n") (ELit (LString "Eq")))) (EBinOp "==" (EVar "n") (ELit (LString "Gt")))) (EBinOp "==" (EVar "n") (ELit (LString "True")))) (EBinOp "==" (EVar "n") (ELit (LString "False")))))
(DTypeSig false "buildUnitCtorRenameMap" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))))
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
(DTypeSig false "ctorImportEntries" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "ctorImportEntries" (PWild (PVar "ctorExportsPerUnit") (PVar "decls")) (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EApp (EVar "declCtorImportEntries") (EVar "ctorExportsPerUnit"))) (EVar "decls")) (EApp (EVar "coreCtorImportEntries") (EVar "ctorExportsPerUnit"))))
(DTypeSig false "coreCtorImportEntries" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "coreCtorImportEntries" ((PVar "ctorExportsPerUnit")) (EMatch (EApp (EApp (EVar "lookupCtorExports") (ELit (LString "core"))) (EVar "ctorExportsPerUnit")) (arm (PCon "Some" (PVar "entries")) () (EApp (EApp (EDictApp "flatMap") (EVar "coreCtorEntry")) (EVar "entries"))) (arm (PCon "None") () (EListLit))))
(DTypeSig false "coreCtorEntry" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "coreCtorEntry" ((PTuple PWild (PVar "ctors"))) (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "n")) (EListLit (ETuple (EVar "n") (EApp (EApp (EVar "mangledName") (ELit (LString "core"))) (EVar "n")))))) (EVar "ctors")))
(DTypeSig false "declCtorImportEntries" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "declCtorImportEntries" ((PVar "ctorExportsPerUnit") (PCon "DUse" PWild (PVar "path") PWild)) (EApp (EApp (EVar "useCtorPathEntries") (EVar "ctorExportsPerUnit")) (EVar "path")))
(DFunDef false "declCtorImportEntries" ((PVar "ctorExportsPerUnit") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EVar "declCtorImportEntries") (EVar "ctorExportsPerUnit")) (EVar "d")))
(DFunDef false "declCtorImportEntries" (PWild PWild) (EListLit))
(DTypeSig false "useCtorPathEntries" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyFun (TyCon "UsePath") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "useCtorPathEntries" ((PVar "ctorExportsPerUnit") (PVar "path")) (EBlock (DoLet false false (PVar "mid") (EApp (EVar "useModIdU") (EVar "path"))) (DoExpr (EIf (EBinOp "==" (EVar "mid") (ELit (LString "core"))) (EListLit) (EMatch (EApp (EApp (EVar "lookupCtorExports") (EVar "mid")) (EVar "ctorExportsPerUnit")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "typeEntries")) () (EMatch (EVar "path") (arm (PCon "UseGroup" PWild (PVar "members")) () (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "ctorMemberEntry") (EVar "mid")) (EVar "typeEntries"))) (EVar "members"))) (arm (PCon "UseWild" PWild) () (EApp (EApp (EDictApp "flatMap") (EApp (EVar "typeCtorEntries") (EVar "mid"))) (EVar "typeEntries"))) (arm (PCon "UseName" PWild) () (EListLit)) (arm (PCon "UseAlias" PWild PWild) () (EListLit)))))))))
(DTypeSig false "ctorMemberEntry" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyCon "UseMember") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "ctorMemberEntry" ((PVar "mid") (PVar "typeEntries") (PCon "UseMember" (PVar "name") (PVar "wild") PWild PWild)) (EIf (EVar "wild") (EMatch (EApp (EApp (EVar "lookupCtorTypeEntry") (EVar "name")) (EVar "typeEntries")) (arm (PCon "Some" (PVar "ctors")) () (EBinOp "++" (EApp (EApp (EApp (EVar "bareCtorMemberEntry") (EVar "mid")) (EVar "typeEntries")) (EVar "name")) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "originCtorEntry") (EVar "mid"))) (EVar "ctors")))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "bareCtorMemberEntry") (EVar "mid")) (EVar "typeEntries")) (EVar "name")))) (EApp (EApp (EApp (EVar "bareCtorMemberEntry") (EVar "mid")) (EVar "typeEntries")) (EVar "name"))))
(DTypeSig false "bareCtorMemberEntry" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "bareCtorMemberEntry" ((PVar "mid") (PVar "typeEntries") (PVar "name")) (EIf (EApp (EApp (EVar "contains") (EVar "name")) (EApp (EApp (EDictApp "flatMap") (EVar "snd")) (EVar "typeEntries"))) (EApp (EApp (EVar "originCtorEntry") (EVar "mid")) (EVar "name")) (EListLit)))
(DTypeSig false "typeCtorEntries" (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "typeCtorEntries" ((PVar "mid") (PTuple PWild (PVar "ctors"))) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "originCtorEntry") (EVar "mid"))) (EVar "ctors")))
(DTypeSig false "originCtorEntry" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "originCtorEntry" ((PVar "mid") (PVar "n")) (EListLit (ETuple (EVar "n") (EApp (EApp (EVar "mangledName") (EVar "mid")) (EVar "n")))))
(DTypeSig false "lookupCtorTypeEntry" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "lookupCtorTypeEntry" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupCtorTypeEntry" ((PVar "k") (PCons (PTuple (PVar "t") (PVar "cs")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "t")) (EApp (EVar "Some") (EVar "cs")) (EApp (EApp (EVar "lookupCtorTypeEntry") (EVar "k")) (EVar "rest"))))
(DTypeSig false "lookupCtorExports" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "lookupCtorExports" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupCtorExports" ((PVar "k") (PCons (PTuple (PVar "m") (PVar "es")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "m")) (EApp (EVar "Some") (EVar "es")) (EApp (EApp (EVar "lookupCtorExports") (EVar "k")) (EVar "rest"))))
(DTypeSig false "mangleModule" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "mangleModule" ((PVar "exportsPerUnit") (PVar "ctorExportsPerUnit") (PTuple (PVar "mid") (PVar "decls"))) (ETuple (EVar "mid") (EApp (EApp (EApp (EVar "mangleUnitU") (EVar "exportsPerUnit")) (EVar "ctorExportsPerUnit")) (ETuple (EVar "mid") (EVar "decls")))))
(DTypeSig false "mangleUnitU" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "mangleUnitU" ((PVar "exportsPerUnit") (PVar "ctorExportsPerUnit") (PTuple (PVar "mid") (PVar "decls"))) (EBlock (DoLet false false (PVar "rmFn") (EApp (EApp (EApp (EVar "buildUnitRenameMap") (EVar "mid")) (EVar "exportsPerUnit")) (EVar "decls"))) (DoLet false false (PVar "rmCtor") (EApp (EApp (EApp (EVar "buildUnitCtorRenameMap") (EVar "mid")) (EVar "ctorExportsPerUnit")) (EVar "decls"))) (DoLet false false (PVar "rmList") (EBinOp "++" (EVar "rmFn") (EVar "rmCtor"))) (DoLet false false (PVar "rm") (EApp (EApp (EVar "omFromPairs") (EApp (EVar "reverseL") (EVar "rmList"))) (EVar "omEmpty"))) (DoExpr (EIf (EApp (EVar "isEmptyL") (EVar "rmList")) (EVar "decls") (EApp (EApp (EMethodRef "map") (EApp (EVar "renameDecl") (EVar "rm"))) (EVar "decls"))))))
(DTypeSig false "buildUnitRenameMap" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "buildUnitRenameMap" ((PVar "mid") (PVar "exportsPerUnit") (PVar "decls")) (EBlock (DoLet false false (PVar "localFns") (EApp (EVar "dedup") (EApp (EVar "unitDefNames") (ETuple (EVar "mid") (EVar "decls"))))) (DoLet false false (PVar "localEntries") (EApp (EApp (EDictApp "flatMap") (EApp (EVar "localRenameEntry") (EVar "mid"))) (EVar "localFns"))) (DoLet false false (PVar "importEntries") (EApp (EApp (EApp (EVar "importRenameEntries") (EVar "mid")) (EVar "exportsPerUnit")) (EVar "decls"))) (DoExpr (EBinOp "++" (EVar "localEntries") (EVar "importEntries")))))
(DTypeSig false "notIfaceMethodKey" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyTuple (TyCon "String") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "notIfaceMethodKey" ((PVar "methods") (PTuple (PVar "n") PWild)) (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "methods"))))
(DTypeSig false "unitIfaceMethodNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "unitIfaceMethodNames" ((PList)) (EListLit))
(DFunDef false "unitIfaceMethodNames" ((PCons (PRec "DInterface" ((rf "methods" None)) true) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EMethodRef "map") (EVar "ifaceMethodNameM")) (EVar "methods")) (EApp (EVar "unitIfaceMethodNames") (EVar "rest"))))
(DFunDef false "unitIfaceMethodNames" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EBinOp "++" (EApp (EVar "unitIfaceMethodNames") (EListLit (EVar "d"))) (EApp (EVar "unitIfaceMethodNames") (EVar "rest"))))
(DFunDef false "unitIfaceMethodNames" ((PCons PWild (PVar "rest"))) (EApp (EVar "unitIfaceMethodNames") (EVar "rest")))
(DTypeSig false "ifaceMethodNameM" (TyFun (TyCon "IfaceMethod") (TyCon "String")))
(DFunDef false "ifaceMethodNameM" ((PCon "IfaceMethod" (PVar "n") PWild PWild PWild)) (EVar "n"))
(DTypeSig false "localRenameEntry" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "localRenameEntry" ((PVar "mid") (PVar "n")) (EIf (EApp (EVar "isExcludedName") (EVar "n")) (EListLit) (EIf (EVar "otherwise") (EListLit (ETuple (EVar "n") (EApp (EApp (EVar "mangledName") (EVar "mid")) (EVar "n")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "isExcludedName" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isExcludedName" ((PVar "n")) (EBinOp "==" (EVar "n") (ELit (LString "main"))))
(DTypeSig false "importRenameEntries" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "importRenameEntries" (PWild (PVar "exportsPerUnit") (PVar "decls")) (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EApp (EVar "declImportEntries") (EVar "exportsPerUnit"))) (EVar "decls")) (EApp (EApp (EVar "filterList") (EApp (EVar "notIfaceMethodKey") (EApp (EApp (EVar "omFromNames") (EApp (EVar "unitIfaceMethodNames") (EVar "decls"))) (EVar "omEmpty")))) (EApp (EVar "coreImportEntries") (EVar "exportsPerUnit")))))
(DTypeSig false "coreImportEntries" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "coreImportEntries" ((PVar "exportsPerUnit")) (EMatch (EApp (EApp (EVar "lookupExports") (ELit (LString "core"))) (EVar "exportsPerUnit")) (arm (PCon "Some" (PVar "names")) () (EApp (EApp (EDictApp "flatMap") (EVar "coreEntry")) (EVar "names"))) (arm (PCon "None") () (EListLit))))
(DTypeSig false "coreEntry" (TyFun (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "coreEntry" ((PTuple (PVar "n") (PVar "definer"))) (EIf (EApp (EVar "isExcludedName") (EVar "n")) (EListLit) (EIf (EVar "otherwise") (EListLit (ETuple (EVar "n") (EApp (EApp (EVar "mangledName") (EVar "definer")) (EVar "n")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "declImportEntries" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))) (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "declImportEntries" ((PVar "exportsPerUnit") (PCon "DUse" PWild (PVar "path") PWild)) (EApp (EApp (EVar "usePathEntries") (EVar "exportsPerUnit")) (EVar "path")))
(DFunDef false "declImportEntries" ((PVar "exportsPerUnit") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EVar "declImportEntries") (EVar "exportsPerUnit")) (EVar "d")))
(DFunDef false "declImportEntries" (PWild PWild) (EListLit))
(DTypeSig false "usePathEntries" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))) (TyFun (TyCon "UsePath") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "usePathEntries" ((PVar "exportsPerUnit") (PVar "path")) (EBlock (DoLet false false (PVar "mid") (EApp (EVar "useModIdU") (EVar "path"))) (DoExpr (EIf (EBinOp "==" (EVar "mid") (ELit (LString "core"))) (EListLit) (EMatch (EApp (EApp (EVar "lookupExports") (EVar "mid")) (EVar "exportsPerUnit")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "exports")) () (EMatch (EVar "path") (arm (PCon "UseGroup" PWild (PVar "members")) () (EApp (EApp (EDictApp "flatMap") (EApp (EVar "memberEntry") (EVar "exports"))) (EVar "members"))) (arm (PCon "UseWild" PWild) () (EApp (EApp (EDictApp "flatMap") (EVar "originEntryPair")) (EVar "exports"))) (arm (PCon "UseName" (PVar "ns")) () (EApp (EApp (EVar "originEntry") (EVar "exports")) (EApp (EVar "lastOfPM") (EVar "ns")))) (arm (PCon "UseAlias" PWild (PVar "a")) () (EApp (EApp (EDictApp "flatMap") (EApp (EVar "aliasEntryPair") (EVar "a"))) (EVar "exports"))))))))))
(DTypeSig false "memberEntry" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "UseMember") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "memberEntry" ((PVar "exports") (PVar "m")) (EApp (EApp (EApp (EVar "originEntryAs") (EVar "exports")) (EApp (EVar "useMemberOrigin") (EVar "m"))) (EApp (EVar "useMemberLocal") (EVar "m"))))
(DTypeSig false "originEntry" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "originEntry" ((PVar "exports") (PVar "n")) (EApp (EApp (EApp (EVar "originEntryAs") (EVar "exports")) (EVar "n")) (EVar "n")))
(DTypeSig false "originEntryAs" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "originEntryAs" ((PVar "exports") (PVar "origin") (PVar "local")) (EIf (EApp (EVar "isExcludedName") (EVar "origin")) (EListLit) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "lookupDefiner") (EVar "origin")) (EVar "exports")) (arm (PCon "Some" (PVar "definer")) () (EListLit (ETuple (EVar "local") (EApp (EApp (EVar "mangledName") (EVar "definer")) (EVar "origin"))))) (arm (PCon "None") () (EListLit))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "originEntryPair" (TyFun (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "originEntryPair" () (EVar "coreEntry"))
(DTypeSig false "aliasEntryPair" (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "String") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "aliasEntryPair" ((PVar "a") (PTuple (PVar "n") (PVar "definer"))) (EIf (EApp (EVar "isExcludedName") (EVar "n")) (EListLit) (EIf (EVar "otherwise") (EListLit (ETuple (EApp (EApp (EVar "qualifiedLocal") (EVar "a")) (EVar "n")) (EApp (EApp (EVar "mangledName") (EVar "definer")) (EVar "n")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "useModIdU" (TyFun (TyCon "UsePath") (TyCon "String")))
(DFunDef false "useModIdU" ((PCon "UseName" (PVar "ns"))) (EIf (EApp (EVar "lenGt1") (EVar "ns")) (EApp (EVar "joinDot") (EApp (EVar "initList") (EVar "ns"))) (EApp (EApp (EVar "firstOrU") (ELit (LString ""))) (EVar "ns"))))
(DFunDef false "useModIdU" ((PCon "UseGroup" (PVar "ns") PWild)) (EApp (EVar "joinDot") (EVar "ns")))
(DFunDef false "useModIdU" ((PCon "UseWild" (PVar "ns"))) (EApp (EVar "joinDot") (EVar "ns")))
(DFunDef false "useModIdU" ((PCon "UseAlias" (PVar "ns") PWild)) (EApp (EVar "joinDot") (EVar "ns")))
(DTypeSig false "lenGt1" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "Bool")))
(DFunDef false "lenGt1" ((PCons PWild (PCons PWild PWild))) (EVar "True"))
(DFunDef false "lenGt1" (PWild) (EVar "False"))
(DTypeSig false "firstOrU" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))
(DFunDef false "firstOrU" ((PVar "d") (PList)) (EVar "d"))
(DFunDef false "firstOrU" (PWild (PCons (PVar "x") PWild)) (EVar "x"))
(DTypeSig false "lastOfPM" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "lastOfPM" ((PList)) (ELit (LString "")))
(DFunDef false "lastOfPM" ((PList (PVar "x"))) (EVar "x"))
(DFunDef false "lastOfPM" ((PCons PWild (PVar "rest"))) (EApp (EVar "lastOfPM") (EVar "rest")))
(DTypeSig false "lookupExports" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "lookupExports" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupExports" ((PVar "k") (PCons (PTuple (PVar "m") (PVar "ns")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "m")) (EApp (EVar "Some") (EVar "ns")) (EApp (EApp (EVar "lookupExports") (EVar "k")) (EVar "rest"))))
(DTypeSig false "pubFnNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "pubFnNames" ((PVar "decls")) (EBlock (DoLet false false (PVar "defined") (EApp (EApp (EVar "omFromNames") (EApp (EVar "unitDefNames") (ETuple (ELit (LString "")) (EVar "decls")))) (EVar "omEmpty"))) (DoLet false false (PVar "pubSigs") (EApp (EVar "pubSigNames") (EVar "decls"))) (DoLet false false (PVar "pubDefs") (EApp (EVar "pubDefNames") (EVar "decls"))) (DoExpr (EApp (EApp (EVar "filterList") (ELam ((PVar "n")) (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "defined")))) (EBinOp "++" (EVar "pubSigs") (EVar "pubDefs"))))))
(DTypeSig false "pubDefNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "pubDefNames" ((PList)) (EListLit))
(DFunDef false "pubDefNames" ((PCons (PCon "DFunDef" (PCon "True") (PVar "n") PWild PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "pubDefNames") (EVar "rest"))))
(DFunDef false "pubDefNames" ((PCons (PCon "DLetGroup" (PCon "True") (PVar "binds")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EMethodRef "map") (EVar "letBindName")) (EVar "binds")) (EApp (EVar "pubDefNames") (EVar "rest"))))
(DFunDef false "pubDefNames" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EBinOp "++" (EApp (EVar "pubDefNames") (EListLit (EVar "d"))) (EApp (EVar "pubDefNames") (EVar "rest"))))
(DFunDef false "pubDefNames" ((PCons PWild (PVar "rest"))) (EApp (EVar "pubDefNames") (EVar "rest")))
(DTypeSig false "unitDefNames" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "unitDefNames" ((PTuple PWild (PVar "decls"))) (EApp (EApp (EDictApp "flatMap") (EVar "declDefNames")) (EVar "decls")))
(DTypeSig false "declDefNames" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "declDefNames" ((PCon "DFunDef" PWild (PVar "n") PWild PWild)) (EListLit (EVar "n")))
(DFunDef false "declDefNames" ((PCon "DLetGroup" PWild (PVar "binds"))) (EApp (EApp (EMethodRef "map") (EVar "letBindName")) (EVar "binds")))
(DFunDef false "declDefNames" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "declDefNames") (EVar "d")))
(DFunDef false "declDefNames" (PWild) (EListLit))
(DTypeSig false "letBindName" (TyFun (TyCon "LetBind") (TyCon "String")))
(DFunDef false "letBindName" ((PCon "LetBind" (PVar "n") PWild)) (EVar "n"))
(DTypeSig false "pubSigNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "pubSigNames" ((PList)) (EListLit))
(DFunDef false "pubSigNames" ((PCons (PCon "DTypeSig" (PCon "True") (PVar "n") PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "pubSigNames") (EVar "rest"))))
(DFunDef false "pubSigNames" ((PCons (PCon "DExtern" (PCon "True") (PVar "n") PWild) (PVar "rest"))) (EBinOp "::" (EVar "n") (EApp (EVar "pubSigNames") (EVar "rest"))))
(DFunDef false "pubSigNames" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EBinOp "++" (EApp (EVar "pubSigNames") (EListLit (EVar "d"))) (EApp (EVar "pubSigNames") (EVar "rest"))))
(DFunDef false "pubSigNames" ((PCons PWild (PVar "rest"))) (EApp (EVar "pubSigNames") (EVar "rest")))
(DTypeSig true "mangledName" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "mangledName" ((PVar "mid") (PVar "name")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "sanitizeId") (EVar "mid")))) (ELit (LString "__"))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString ""))))
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
(DFunDef false "hashChars" ((PVar "cs") (PVar "i") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "cs"))) (EVar "acc") (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "hashChars") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EBinOp "*" (EVar "acc") (ELit (LInt 33))) (EApp (EVar "charCode") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "dictTag" (TyFun (TyCon "String") (TyCon "Int")))
(DFunDef false "dictTag" ((PVar "s")) (EApp (EApp (EVar "posMod") (EApp (EVar "hashName") (EVar "s"))) (ELit (LInt 1073741824))))
(DTypeSig true "posMod" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "posMod" ((PVar "n") (PVar "m")) (EBinOp "%" (EBinOp "+" (EBinOp "%" (EVar "n") (EVar "m")) (EVar "m")) (EVar "m")))
(DTypeSig false "renameDecl" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "Decl") (TyCon "Decl"))))
(DFunDef false "renameDecl" ((PVar "rm") (PCon "DFunDef" (PVar "pub") (PVar "n") (PVar "ps") (PVar "e"))) (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "pub")) (EApp (EApp (EVar "renameDefName") (EVar "rm")) (EVar "n"))) (EApp (EApp (EVar "renamePatsPM") (EVar "rm")) (EVar "ps"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EApp (EVar "boundOfListPM") (EApp (EVar "patVarsListPM") (EVar "ps")))) (EVar "e"))))
(DFunDef false "renameDecl" ((PVar "rm") (PCon "DTypeSig" (PVar "pub") (PVar "n") (PVar "ty"))) (EApp (EApp (EApp (EVar "DTypeSig") (EVar "pub")) (EApp (EApp (EVar "renameDefName") (EVar "rm")) (EVar "n"))) (EVar "ty")))
(DFunDef false "renameDecl" ((PVar "rm") (PAs "d" (PRec "DInterface" ((rf "methods" None)) true))) (EVariantUpdate "DInterface" (EVar "d") ((fa "methods" (EApp (EApp (EMethodRef "map") (EApp (EVar "renameIfaceMethod") (EVar "rm"))) (EVar "methods"))))))
(DFunDef false "renameDecl" ((PVar "rm") (PAs "d" (PRec "DImpl" ((rf "methods" None)) true))) (EVariantUpdate "DImpl" (EVar "d") ((fa "methods" (EApp (EApp (EMethodRef "map") (EApp (EVar "renameImplMethod") (EVar "rm"))) (EVar "methods"))))))
(DFunDef false "renameDecl" ((PVar "rm") (PCon "DProp" (PVar "pub") (PVar "name") (PVar "params") (PVar "body"))) (EApp (EApp (EApp (EApp (EVar "DProp") (EVar "pub")) (EVar "name")) (EVar "params")) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EApp (EVar "boundOfListPM") (EApp (EVar "propParamNamesPM") (EVar "params")))) (EVar "body"))))
(DFunDef false "renameDecl" ((PVar "rm") (PCon "DTest" (PVar "pub") (PVar "name") (PVar "body"))) (EApp (EApp (EApp (EVar "DTest") (EVar "pub")) (EVar "name")) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "omEmpty")) (EVar "body"))))
(DFunDef false "renameDecl" ((PVar "rm") (PCon "DBench" (PVar "pub") (PVar "name") (PVar "body"))) (EApp (EApp (EApp (EVar "DBench") (EVar "pub")) (EVar "name")) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "omEmpty")) (EVar "body"))))
(DFunDef false "renameDecl" ((PVar "rm") (PCon "DLetGroup" (PVar "pub") (PVar "binds"))) (EApp (EApp (EVar "DLetGroup") (EVar "pub")) (EApp (EApp (EMethodRef "map") (EApp (EVar "renameLetBindDef") (EVar "rm"))) (EVar "binds"))))
(DFunDef false "renameDecl" ((PVar "rm") (PAs "d" (PRec "DData" ((rf "dataCtors" (PVar "variants"))) false))) (EVariantUpdate "DData" (EVar "d") ((fa "dataCtors" (EApp (EApp (EMethodRef "map") (EApp (EVar "renameVariant") (EVar "rm"))) (EVar "variants"))))))
(DFunDef false "renameDecl" ((PVar "rm") (PAs "d" (PRec "DNewtype" ((rf "newtypeCtor" (PVar "con"))) false))) (EVariantUpdate "DNewtype" (EVar "d") ((fa "newtypeCtor" (EApp (EApp (EVar "renameDefName") (EVar "rm")) (EVar "con"))))))
(DFunDef false "renameDecl" ((PVar "rm") (PCon "DAttrib" (PVar "attrs") (PVar "d"))) (EApp (EApp (EVar "DAttrib") (EVar "attrs")) (EApp (EApp (EVar "renameDecl") (EVar "rm")) (EVar "d"))))
(DFunDef false "renameDecl" (PWild (PVar "d")) (EVar "d"))
(DTypeSig false "renameVariant" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "Variant") (TyCon "Variant"))))
(DFunDef false "renameVariant" ((PVar "rm") (PCon "Variant" (PVar "n") (PVar "payload"))) (EApp (EApp (EVar "Variant") (EApp (EApp (EVar "renameDefName") (EVar "rm")) (EVar "n"))) (EVar "payload")))
(DTypeSig false "renameLetBindDef" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "LetBind") (TyCon "LetBind"))))
(DFunDef false "renameLetBindDef" ((PVar "rm") (PCon "LetBind" (PVar "n") (PVar "clauses"))) (EApp (EApp (EVar "LetBind") (EApp (EApp (EVar "renameDefName") (EVar "rm")) (EVar "n"))) (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "renameFunClause") (EVar "rm")) (EVar "omEmpty"))) (EVar "clauses"))))
(DTypeSig false "renameDefName" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "renameDefName" ((PVar "rm") (PVar "n")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "rm")) (arm (PCon "Some" (PVar "n2")) () (EVar "n2")) (arm (PCon "None") () (EVar "n"))))
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
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EFieldAccess" (PVar "e0") (PVar "n") (PVar "r"))) (EApp (EApp (EApp (EVar "EFieldAccess") (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e0"))) (EVar "n")) (EVar "r")))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "ETuple" (PVar "es"))) (EApp (EVar "ETuple") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound"))) (EVar "es"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EListLit" (PVar "es"))) (EApp (EVar "EListLit") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound"))) (EVar "es"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EArrayLit" (PVar "es"))) (EApp (EVar "EArrayLit") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound"))) (EVar "es"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "ERangeList" (PVar "lo") (PVar "hi") (PVar "i"))) (EApp (EApp (EApp (EVar "ERangeList") (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "lo"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "hi"))) (EVar "i")))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "ERangeArray" (PVar "lo") (PVar "hi") (PVar "i"))) (EApp (EApp (EApp (EVar "ERangeArray") (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "lo"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "hi"))) (EVar "i")))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "ESlice" (PVar "e0") (PVar "lo") (PVar "hi") (PVar "i") (PVar "r"))) (EApp (EApp (EApp (EApp (EApp (EVar "ESlice") (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e0"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "lo"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "hi"))) (EVar "i")) (EVar "r")))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EIndex" (PVar "e0") (PVar "i") (PVar "r"))) (EApp (EApp (EApp (EVar "EIndex") (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e0"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "i"))) (EVar "r")))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EAnnot" (PVar "e0") (PVar "t"))) (EApp (EApp (EVar "EAnnot") (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e0"))) (EVar "t")))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EHeadAnnot" (PVar "e0") (PVar "t"))) (EApp (EApp (EVar "EHeadAnnot") (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e0"))) (EVar "t")))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "ERecordCreate" (PVar "n") (PVar "fs"))) (EApp (EApp (EVar "ERecordCreate") (EApp (EApp (EVar "renameDefName") (EVar "rm")) (EVar "n"))) (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "renameField") (EVar "rm")) (EVar "bound"))) (EVar "fs"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "ERecordUpdate" (PVar "e0") (PVar "fs") (PVar "r"))) (EApp (EApp (EApp (EVar "ERecordUpdate") (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e0"))) (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "renameField") (EVar "rm")) (EVar "bound"))) (EVar "fs"))) (EVar "r")))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EVariantUpdate" (PVar "c") (PVar "e0") (PVar "fs"))) (EApp (EApp (EApp (EVar "EVariantUpdate") (EApp (EApp (EVar "renameDefName") (EVar "rm")) (EVar "c"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e0"))) (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "renameField") (EVar "rm")) (EVar "bound"))) (EVar "fs"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EStringInterp" (PVar "parts"))) (EApp (EVar "EStringInterp") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "renameInterp") (EVar "rm")) (EVar "bound"))) (EVar "parts"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EGuards" (PVar "arms"))) (EApp (EVar "EGuards") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "renameGuardArm") (EVar "rm")) (EVar "bound"))) (EVar "arms"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "ESection" (PCon "SecRight" (PVar "op") (PVar "e0")))) (EApp (EVar "ESection") (EApp (EApp (EVar "SecRight") (EVar "op")) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e0")))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "ESection" (PCon "SecLeft" (PVar "e0") (PVar "op")))) (EApp (EVar "ESection") (EApp (EApp (EVar "SecLeft") (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e0"))) (EVar "op"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EMapLit" (PVar "n") (PVar "kvs"))) (EApp (EApp (EVar "EMapLit") (EVar "n")) (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "renameKv") (EVar "rm")) (EVar "bound"))) (EVar "kvs"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "ESetLit" (PVar "n") (PVar "es"))) (EApp (EApp (EVar "ESetLit") (EVar "n")) (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound"))) (EVar "es"))))
(DFunDef false "renameScoped" ((PVar "rm") (PVar "bound") (PCon "EAsPat" (PVar "x") (PVar "sub"))) (EApp (EApp (EVar "EAsPat") (EVar "x")) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EMethodRef "sub"))))
(DFunDef false "renameScoped" (PWild PWild (PVar "e")) (EVar "e"))
(DTypeSig false "renameField" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "FieldAssign") (TyCon "FieldAssign")))))
(DFunDef false "renameField" ((PVar "rm") (PVar "bound") (PCon "FieldAssign" (PVar "n") (PVar "e"))) (EApp (EApp (EVar "FieldAssign") (EVar "n")) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e"))))
(DTypeSig false "renameKv" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyTuple (TyCon "Expr") (TyCon "Expr")) (TyTuple (TyCon "Expr") (TyCon "Expr"))))))
(DFunDef false "renameKv" ((PVar "rm") (PVar "bound") (PTuple (PVar "k") (PVar "v"))) (ETuple (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "k")) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "v"))))
(DTypeSig false "renameInterp" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "InterpPart") (TyCon "InterpPart")))))
(DFunDef false "renameInterp" (PWild PWild (PCon "InterpStr" (PVar "s"))) (EApp (EVar "InterpStr") (EVar "s")))
(DFunDef false "renameInterp" ((PVar "rm") (PVar "bound") (PCon "InterpExpr" (PVar "e"))) (EApp (EVar "InterpExpr") (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e"))))
(DTypeSig false "renameLetBind" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "LetBind") (TyCon "LetBind")))))
(DFunDef false "renameLetBind" ((PVar "rm") (PVar "bound") (PCon "LetBind" (PVar "n") (PVar "clauses"))) (EApp (EApp (EVar "LetBind") (EApp (EApp (EVar "renameDefName") (EVar "rm")) (EVar "n"))) (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "renameFunClause") (EVar "rm")) (EVar "bound"))) (EVar "clauses"))))
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
(DFunDef false "renameStmts" ((PVar "rm") (PVar "bound") (PCons (PCon "DoLet" (PVar "m") (PVar "r") (PVar "p") (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false (PVar "b1") (EIf (EVar "r") (EApp (EApp (EVar "boundInsertPM") (EApp (EVar "patVarsPM") (EVar "p"))) (EVar "bound")) (EVar "bound"))) (DoExpr (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "DoLet") (EVar "m")) (EVar "r")) (EApp (EApp (EVar "renamePat") (EVar "rm")) (EVar "p"))) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "b1")) (EVar "e"))) (EApp (EApp (EApp (EVar "renameStmts") (EVar "rm")) (EApp (EApp (EVar "boundInsertPM") (EApp (EVar "patVarsPM") (EVar "p"))) (EVar "bound"))) (EVar "rest"))))))
(DFunDef false "renameStmts" ((PVar "rm") (PVar "bound") (PCons (PCon "DoAssign" (PVar "x") (PVar "e")) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EVar "DoAssign") (EVar "x")) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e"))) (EApp (EApp (EApp (EVar "renameStmts") (EVar "rm")) (EVar "bound")) (EVar "rest"))))
(DFunDef false "renameStmts" ((PVar "rm") (PVar "bound") (PCons (PCon "DoFieldAssign" (PVar "x") (PVar "fs") (PVar "e")) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EApp (EVar "DoFieldAssign") (EVar "x")) (EVar "fs")) (EApp (EApp (EApp (EVar "renameScoped") (EVar "rm")) (EVar "bound")) (EVar "e"))) (EApp (EApp (EApp (EVar "renameStmts") (EVar "rm")) (EVar "bound")) (EVar "rest"))))
(DTypeSig false "letBindNamesPM" (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "letBindNamesPM" ((PVar "binds")) (EApp (EApp (EMethodRef "map") (EVar "letBindName")) (EVar "binds")))
(DTypeSig false "patVarsPM" (TyFun (TyCon "Pat") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "patVarsPM" ((PCon "PVar" (PVar "x") PWild)) (EListLit (EVar "x")))
(DFunDef false "patVarsPM" ((PCon "PCon" PWild (PVar "args"))) (EApp (EVar "patVarsListPM") (EVar "args")))
(DFunDef false "patVarsPM" ((PCon "PCons" (PVar "h") (PVar "t"))) (EBinOp "++" (EApp (EVar "patVarsPM") (EVar "h")) (EApp (EVar "patVarsPM") (EVar "t"))))
(DFunDef false "patVarsPM" ((PCon "PTuple" (PVar "ps"))) (EApp (EVar "patVarsListPM") (EVar "ps")))
(DFunDef false "patVarsPM" ((PCon "PList" (PVar "ps"))) (EApp (EVar "patVarsListPM") (EVar "ps")))
(DFunDef false "patVarsPM" ((PCon "PAs" (PVar "x") PWild (PVar "p"))) (EBinOp "::" (EVar "x") (EApp (EVar "patVarsPM") (EVar "p"))))
(DFunDef false "patVarsPM" ((PCon "PRec" PWild (PVar "fields") PWild)) (EApp (EApp (EDictApp "flatMap") (EVar "recPatFieldVarsPM")) (EVar "fields")))
(DFunDef false "patVarsPM" (PWild) (EListLit))
(DTypeSig false "patVarsListPM" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "patVarsListPM" ((PVar "ps")) (EApp (EApp (EDictApp "flatMap") (EVar "patVarsPM")) (EVar "ps")))
(DTypeSig false "renamePat" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "Pat") (TyCon "Pat"))))
(DFunDef false "renamePat" ((PVar "rm") (PCon "PCon" (PVar "n") (PVar "args"))) (EApp (EApp (EVar "PCon") (EApp (EApp (EVar "renameDefName") (EVar "rm")) (EVar "n"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "renamePat") (EVar "rm"))) (EVar "args"))))
(DFunDef false "renamePat" ((PVar "rm") (PCon "PCons" (PVar "h") (PVar "t"))) (EApp (EApp (EVar "PCons") (EApp (EApp (EVar "renamePat") (EVar "rm")) (EVar "h"))) (EApp (EApp (EVar "renamePat") (EVar "rm")) (EVar "t"))))
(DFunDef false "renamePat" ((PVar "rm") (PCon "PTuple" (PVar "ps"))) (EApp (EVar "PTuple") (EApp (EApp (EMethodRef "map") (EApp (EVar "renamePat") (EVar "rm"))) (EVar "ps"))))
(DFunDef false "renamePat" ((PVar "rm") (PCon "PList" (PVar "ps"))) (EApp (EVar "PList") (EApp (EApp (EMethodRef "map") (EApp (EVar "renamePat") (EVar "rm"))) (EVar "ps"))))
(DFunDef false "renamePat" ((PVar "rm") (PCon "PAs" (PVar "x") (PVar "l") (PVar "p"))) (EApp (EApp (EApp (EVar "PAs") (EVar "x")) (EVar "l")) (EApp (EApp (EVar "renamePat") (EVar "rm")) (EVar "p"))))
(DFunDef false "renamePat" ((PVar "rm") (PCon "PRec" (PVar "n") (PVar "fields") (PVar "open"))) (EApp (EApp (EApp (EVar "PRec") (EApp (EApp (EVar "renameDefName") (EVar "rm")) (EVar "n"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "renameRecPatField") (EVar "rm"))) (EVar "fields"))) (EVar "open")))
(DFunDef false "renamePat" (PWild (PVar "p")) (EVar "p"))
(DTypeSig false "renameRecPatField" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyCon "RecPatField") (TyCon "RecPatField"))))
(DFunDef false "renameRecPatField" (PWild (PCon "RecPatField" (PVar "label") (PVar "l") (PCon "None"))) (EApp (EApp (EApp (EVar "RecPatField") (EVar "label")) (EVar "l")) (EVar "None")))
(DFunDef false "renameRecPatField" ((PVar "rm") (PCon "RecPatField" (PVar "label") (PVar "l") (PCon "Some" (PVar "p")))) (EApp (EApp (EApp (EVar "RecPatField") (EVar "label")) (EVar "l")) (EApp (EVar "Some") (EApp (EApp (EVar "renamePat") (EVar "rm")) (EVar "p")))))
(DTypeSig false "renamePatsPM" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyApp (TyCon "List") (TyCon "Pat")))))
(DFunDef false "renamePatsPM" ((PVar "rm") (PVar "ps")) (EApp (EApp (EMethodRef "map") (EApp (EVar "renamePat") (EVar "rm"))) (EVar "ps")))
(DTypeSig false "recPatFieldVarsPM" (TyFun (TyCon "RecPatField") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "recPatFieldVarsPM" ((PCon "RecPatField" (PVar "label") PWild (PCon "None"))) (EListLit (EVar "label")))
(DFunDef false "recPatFieldVarsPM" ((PCon "RecPatField" PWild PWild (PCon "Some" (PVar "p")))) (EApp (EVar "patVarsPM") (EVar "p")))
