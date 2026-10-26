# META
source_lines=915
stages=DESUGAR,MARK
# SOURCE
-- tc_foreign: extern signatures checked against the FFI-ABI crossable set and the FFI-ABI rules on
-- unlabelled, builtin-shadowing, catalog-narrow and nullary externs, with the signature-position
-- helpers they use.
--
-- Spec: FFI-ABI section 1 (the crossable set) and its preamble rules (T-FFI-UNLABELLED,
-- -BUILTIN-SHADOW, -CATALOG-NARROW, -NULLARY); EFFECTS section 2.3 (the `FFI` parameter grammar at
-- a declaration).
--
-- Placement: declarations are placed by R1-R6 of the Phase 4 module table,
-- compiler/ARCHITECTURE-PLAYBOOK.md section 6.
-- Closure rule: this module may not import `types.typecheck`, nor any of `tc_solve_givens`,
-- `tc_solve_entail`, `tc_solve`, `tc_solve_check`, `tc_shadow`, `tc_effects`, `tc_occurrence`,
-- `tc_groups`, `tc_pat`, `tc_infer_records`, `tc_infer`, `tc_elab`, `tc_global`, `tc_module`.

import types.tc_types.{
  SigVars(..),
  GraphCtx,
  ModuleCtx,
}
import types.tc_diag_text.{ffiArrowNote}
import types.tc_diag.{pushTypeErrorAt}
import types.tc_unify.{atomsEscape, freshAuthvar}
import types.tc_decls_types.{atomsOfWrittenIn}
import types.tc_decls.{expandAliasHeadTy, expandAliasHeadTyWith}
import types.effect_authority.{Authvar(..)}
import frontend.ast.{
  Decl(..),
  EffAtomTy(..),
  EffParamTy(..),
  ExternDecl(..),
  Loc(..),
  TabKey(..),
  Ty(..),
  effParamNames,
  externRowCons,
  firstTyLoc,
  isFixedIntHead,
  orElseLoc,
  sameTyConHead,
}
import types.ffi_bindings.{
  FfiDiag(..),
  ffiCatalogNarrowMsg,
  ffiCatalogTailMsg,
  ffiDeclarationDiags,
  ffiNonCrossableMsg,
  ffiShadowMsg,
}
import support.ordmap.{omHasKey, omInsert, omLookup, omSize, OrdMap}
import support.util.{
  allList,
  anyList,
  contains,
  filterList,
  isSome,
  listLen,
  lookupAssoc,
  reverseL,
  sortUniqS,
  zipL,
}
import types.repr.{lookupAssocI, ppTy}
import types.effect_domain.{Param(..)}

-- [start, start+1, .. start+count-1]
export
rangeFromCount : Int -> Int -> List Int
rangeFromCount start count
  | count <= 0 = []
  | otherwise = start :: rangeFromCount (start + 1) (count - 1)

export
externSigsToMap : List Decl ->
  OrdMap (Ty, List (String, Int)) ->
  OrdMap (Ty, List (String, Int))
externSigsToMap [] m = m
externSigsToMap ((DExtern (ExternDecl { edName = n, edTy = ty, ... })) :: rest) m =
  externSigsToMap rest (omInsert n (ty, namedArgOrder ty) m)
externSigsToMap (_ :: rest) m = externSigsToMap rest m

-- Each named argument with its absolute position among the arrows: the
-- position, not the spelling, is what a redeclaration must agree with.
namedArgOrder : Ty -> List (String, Int)
namedArgOrder ty = namedArgPositions ty 0

namedArgPositions : Ty -> Int -> List (String, Int)
namedArgPositions (TyFun (TyNamed n _ _) b) i =
  (n, i) :: namedArgPositions b (i + 1)
namedArgPositions (TyFun _ b) i = namedArgPositions b (i + 1)
namedArgPositions (TyConstrained _ t) i = namedArgPositions t i
namedArgPositions _ _ = []

-- Apply the four user-extern declaration rules unless the program under check is
-- stdlib-owned, OR the run has no builtin-extern catalog at all.
--
-- The second conjunct is not an ownership test — it is a "does this run know
-- what a foreign declaration IS" test.  `builtinExternNamesRef` is seeded ONLY by
-- `noteBuiltinExternNames`, inside `externSchemes … runtimeDecls`; the eight call
-- sites that build the catalog all pass `runtimeDecls` (138 rows), so for every
-- REAL entry point — `medaka check`/`build`/`test`/`lint`/`mcp`, the LSP, and
-- every graph driver — this map is non-empty and the guards fire exactly as before.
-- It is empty only when a compiler-internal one-module entry explicitly supplies no
-- runtime declarations, as `compiler/entries/typecheck_main.mdk` and
-- `compiler/entries/selfproc_tc_probe.mdk` do. There, `ffiIsBuiltinExternName`
-- reads an empty map, so the catalog exemption the other three rules depend on
-- cannot engage, and a bare HM fixture writing the catalog's own `extern Ref : a
-- -> Ref a` (`stdlib/runtime.mdk`'s real row, borrowed by
-- `test/typecheck_error_fixtures/value_restriction_ref.mdk` purely because
-- `extern` is the one syntax that introduces a non-generalizing name) was judged
-- an honest, non-exempt foreign declaration and failed both the label and the
-- crossable rule.  Exempting the whole no-catalog run restores that driver to its
-- pre-FFI behaviour — it accepted every `extern` — rather than half-applying a
-- rule whose exemption test is structurally blind on that path.
export
ffiStampMode : GraphCtx -> String -> Bool
ffiStampMode gctx mid =
  omSize gctx.builtinExternNamesRef.value > 0 && ffiStampModeOwned gctx mid

-- The ownership half, unchanged.  See `driveInputsFor` for why the two arms
-- read two different fields and why the default is "apply them".
ffiStampModeOwned : GraphCtx -> String -> Bool
-- `"__user__"` is the flat entry, not A LOADED MODULE, and this arm is what
-- actually fires on `medaka check <file>`.  The single-file front door does not
-- reach the `Flat` arm at all: `runCheck` → `checkOneToLinesWithRuntime` wraps the
-- program as the ONE-module graph `[("__user__", userProg)]`, the same synthetic id
-- ~10 drivers already use for "the single program under check".  Reading the flat
-- Bool here is exact rather than approximate — that id means "the entry", and the
-- Bool is the entry's ownership.  Dropping this clause turns
-- `medaka check stdlib/runtime.mdk` into a wall of declaration errors — the 132
-- catalog rows that do not name `FFI` (the same 132 that used to GAIN the atom
-- here, back when this Bool gated a stamp) would each fail the label rule.
ffiStampModeOwned gctx "__user__" = not gctx.config.value.tcFlatEntryIsStdlib
ffiStampModeOwned gctx mid = not (omHasKey mid gctx.config.value.tcStdlibOwned)

-- The row a user extern's terminal result carries, read as elaboration reads
-- it: each step of the arrow spine expands an alias at its head, so `type Eff r
-- = <FFI "c"> r; extern f : Int -> Eff Int` declares `<FFI "c">`, and `type CFn
-- = Int -> <> Int; extern g : CFn` declares an arrow (#3638).  An absent row is
-- `Some []`.  `None` = the signature has no arrow, so it has nowhere to carry a
-- row (`extern k : Int`), which the label rule refuses rather than passes.  A
-- constrained alias right-hand side unwraps like a constrained signature.
ffiDeclaredRow : ModuleCtx -> Ty -> Option (List EffAtomTy)
ffiDeclaredRow mctx t = match expandAliasHeadTy mctx t
  TyConstrained _ inner => ffiDeclaredRow mctx inner
  TyFun _ r => Some (ffiResultRow mctx r)
  _ => None

ffiResultRow : ModuleCtx -> Ty -> List EffAtomTy
ffiResultRow mctx t = match expandAliasHeadTy mctx t
  TyFun _ r => ffiResultRow mctx r
  TyEffect ls _ _ => ls
  _ => []

-- ── the FFI-ABI.md §1 CROSSABLE SET ─────────────────────────────────────────
--
-- This is the single definition of "may this value cross the C boundary".
-- The lowering (#2074) consumes THIS predicate; it must not grow a second
-- notion of crossable in `compiler/backend/`, because the two would drift and
-- the drift is silent — an emitter that marshals a shape `check` rejected is
-- dead code, and one that marshals a shape `check` accepted but the emitter
-- does not know is a wrong-answer path.
--
-- The rows are `compiler/FFI-ABI.md` §1 verbatim: `Int`, `Float`, `Bool`,
-- `Char`, `String`, `Array Int`, `Unit`.  (`Unit` was added to §1/§2.6 on
-- 2026-08-27: it has NO runtime representation, so it crosses trivially — a
-- `Unit` parameter marshals to nothing and a `Unit` return is a C `void`.
-- Without it no void-returning C function, the commonest FFI shape, is
-- expressible at all.)  §1's closing sentence makes the set CLOSED
-- ("every other value kind … is explicitly not in the v1 crossable set"), so
-- this predicate is a whitelist, not a blacklist of §3's enumeration — a type
-- §3 forgot to name is still not crossable.
ffiCrossableTy : ModuleCtx -> Ty -> Bool
ffiCrossableTy mctx t = match expandAliasHeadTy mctx t
  TyCon { tyConName = n } => ffiCrossableConName n
  -- A named argument crosses as its type; the name is the authority the
  -- declared row charges, which is compile-time only.
  TyNamed _ inner _ => ffiCrossableTy mctx inner
  TyQual inner _ _ => ffiCrossableTy mctx inner
  -- `Array Int` and nothing else: §2.4 specifies only the all-immediate-element
  -- case, so `Array String` / `Array (Array Int)` fall through to False.
  TyApp a b => match (expandAliasHeadTy mctx a, expandAliasHeadTy mctx b)
    (TyCon { tyConName = "Array" }, TyCon { tyConName = "Int" }) => True
    _ => False
  _ => False

ffiCrossableConName : String -> Bool
ffiCrossableConName n =
  n == "Int"
    || n == "Float"
    || n == "Bool"
    || n == "Char"
    || n == "String"
    || n == "Unit"
    || isFixedIntHead n

-- Reject a user extern that names a non-crossable type (#2074, acceptance
-- bullet 2).  Gated on the SAME `ffiStampMode` Bool as the `<FFI>` stamp
-- itself: a signature the stamp does not touch is not a foreign declaration
-- this rule owns.  `stdlib/runtime.mdk`'s catalog and every compiler-internal
-- extern are therefore untouched, by construction rather than by a second
-- ownership test that could disagree with the first.
export
ffiCheckExternsCrossable : ModuleCtx -> Bool -> List Decl -> Unit
ffiCheckExternsCrossable mctx False _ = ()
ffiCheckExternsCrossable mctx True ds = ffiCheckExternsGo mctx (externDecls ds)

ffiCheckExternsGo : ModuleCtx -> List Decl -> Unit
ffiCheckExternsGo mctx [] = ()
ffiCheckExternsGo mctx ((DExtern (ExternDecl { edName = n, edTy = ty, ... })) :: rest) =
  let _ =
    if ffiIsBuiltinExternName mctx.mcGraph n then
      ()
    else
      ffiCheckExternSig mctx n (firstTyLoc ty) ty
  ffiCheckExternsGo mctx rest
ffiCheckExternsGo mctx (_ :: rest) = ffiCheckExternsGo mctx rest

-- The one exemption, and it is A semantic fact, not A TEST-CORPUS WORKAROUND.
--
-- A local `extern` whose name matches a `stdlib/runtime.mdk` catalog name is
-- NEVER lowered as a new foreign call.  `isAnyExtern`
-- (`compiler/backend/llvm_emit.mdk`), which feeds `emitApp`'s CVar-head ladder,
-- dispatches purely by NAME against the fixed extern catalog — it has no
-- awareness of which `DExtern` declared the name or what that declaration
-- claims.  So the redeclared name is emitted through the BUILTIN's existing
-- codegen regardless of the local signature.  MEASURED, twice:
--
--   extern bitAnd : Int -> Int -> <FFI> Int      -- deliberately narrow local row
--   ⇒ ./out prints 240 for `bitAnd 255 240`      -- the real builtin ran
--
--   extern getEnv : String -> <Env> Option String   -- non-crossable row
--   ⇒ ./out prints the REAL environment variable        -- the real builtin ran,
--                                                       -- not an unbound symbol
--
-- Checking such a signature against the crossable set would therefore be
-- validating a claim that has no bearing on anything the compiler will ever do
-- with the name, and would reject a redeclaration idiom the effect-domain
-- fixtures use ON PURPOSE (`test/effect_param_fixtures/*`, whose gate's header
-- calls out "per-program LOCAL extern redeclarations" as its design).
--
-- It is keyed on the name set the SEED was built from, recorded once by
-- `externSchemes` — not on a hand-copied list here, which would rot the moment
-- `stdlib/runtime.mdk` gains a row.  `builtinExternNamesRef` maps each catalog
-- name to that row's written signature and its named-argument positions rather
-- than to `Unit`: this predicate reads only the key set, but
-- `ffiCheckExternsShadow` below matches a redeclaration against the catalog's
-- own signature, and `ffiCheckExternsCatalogRow` (#2163) compares its rows; a
-- second table keyed the same way could fall out of step with this one.  (The field
-- carries no comment of its own — `GraphCtx`'s header forbids one, #829 /
-- [T-PERRUN-COMMENTS] — so its prose lives here, on its reader.)
--
-- And the measurement above only ever covered A *COMPATIBLE* REDECLARATION.
-- Both measured rows (`bitAnd`, `getEnv`) are instances of the catalog row's
-- type, so "the real builtin ran" is the right answer for them.  A redeclaration
-- at a different type gets the same name-only exemption and the same builtin
-- codegen, which is then the wrong answer, silently: `extern log : String
-- -> <FFI "mylog"> Unit` compiles to `call double @mdk_log(double <String cell
-- pointer>)` at exit 0, and the user's own C `log` is never called or even
-- declared.  So a bare name match is not enough to say "this declaration is not a
-- foreign-call contract": the type has to agree too, which is
-- `ffiCheckExternsShadow` below.  Callers of this predicate are still exempting on
-- the name alone, and that is correct because the shadow rule has already made a
-- name match at any other type a hard error: the exemption never has to reason
-- about a declaration that survived.
ffiIsBuiltinExternName : GraphCtx -> String -> Bool
ffiIsBuiltinExternName gctx n = omHasKey n gctx.builtinExternNamesRef.value

-- ── the CATALOG-SHADOW rule (S0-3, review round of `ffi-lower-and-link`) ─────
--
-- The admission test for the exemption above, and it has to be A REJECTION.
--
-- The obvious lighter fix — "on a shape mismatch, stop exempting and route the
-- declaration through the crossable and label guards instead" — does not close the
-- HOLE, and that was measured, not assumed.  `extern log : String -> <FFI "mylog">
-- Unit` PASSES both of those guards on its own terms (`String` and `Unit` are both
-- in the §1 crossable set; the row names `FFI`), so routing it through them changes
-- nothing at all and the program still emits `call double @mdk_log`.  The reason is
-- that the emitter's half of the exemption is a SEPARATE, NAME-ONLY mechanism that
-- no typecheck verdict reaches: the checked FFI facts consumed by the emitter
-- subtracts the runtime catalog's names from the FFI index outright, and
-- `emitApp`'s ladder tests `isAnyExtern` BEFORE the FFI arm.  A catalog name is
-- lowered as the builtin no matter what typecheck concluded about it.
--
-- So a shape-incompatible redeclaration of a catalog name is a declaration the
-- compiler can never honour in either reading: it will not become a foreign call
-- (the emitter routes it to the builtin), and it does not describe the builtin (the
-- shapes differ).  There is no verdict other than "reject" that leaves the source
-- and the emitted program describing the same thing.
--
-- Deliberately NOT the `mdk_*` ban's mechanism (`T-FFI-RESERVED-NAME`).
-- That one refuses an `mdk_` C symbol at any signature, because no user extern
-- may bind a runtime-internal symbol.  This one admits the compatible redeclaration idiom the
-- effect-domain fixtures use on purpose, and rejects only the contradiction.
--
-- The comparison is the whole type, not its heads: callers are typed against
-- the local declaration while the built-in runs, so the declaration must be an
-- INSTANCE of the catalog's type (`ffiSigInstance`). It may fix the built-in's
-- type variables and authorities (`Array Int` for `Array a`, `Socket "a.com/*"`
-- for `Socket h`) and nothing else. A head-only comparison let `extern
-- stringIndexOf : String -> String -> Option (Socket "a.com/*")` type any
-- number as a socket. Rows are part of the type; only the row each arrow's
-- result carries may differ, and that is the next rule's business,
-- instantiated by the same match.
export
ffiCheckExternsShadow : ModuleCtx -> Bool -> List Decl -> Unit
ffiCheckExternsShadow mctx False _ = ()
ffiCheckExternsShadow mctx True ds = ffiCheckShadowGo mctx (externDecls ds)

ffiCheckShadowGo : ModuleCtx -> List Decl -> Unit
ffiCheckShadowGo mctx [] = ()
ffiCheckShadowGo mctx ((DExtern (ExternDecl { edName = n, edTy = ty, ... })) :: rest) =
  let _ = match omLookup n mctx.mcGraph.builtinExternNamesRef.value
    Some (cat, _) => match ffiSigInstance mctx cat ty
      Some _ => ()
      None =>
        pushTypeErrorAt
          mctx
          "T-FFI-BUILTIN-SHADOW"
          (firstTyLoc ty)
          (ffiShadowMsg n (ppTy cat) (ppTy ty))
    None => ()
  ffiCheckShadowGo mctx rest
ffiCheckShadowGo mctx (_ :: rest) = ffiCheckShadowGo mctx rest

-- The substitution under which `decl` is the catalog signature `cat` with
-- some of its variables fixed, or `None` when it is not. A catalog type, row
-- or authority variable binds to whatever the declaration writes at its first
-- occurrence and must meet the same thing at every later one; the
-- declaration's own variables are rigid. An argument's binder (`host` in
-- `(host : String) -> … Socket host`) is fixed by the argument's value, not by
-- the declaration, so it is bound up front to the binder the declaration
-- writes at the same position. Rows are part of the type: off the arrow spine
-- they match exactly. The row each arrow's result carries is what calling the
-- built-in performs, which a declaration may widen, so the match peels it and
-- `ffiCheckExternsCatalogRow` compares it, arrow by arrow.
ffiSigInstance : ModuleCtx -> Ty -> Ty -> Option (List (String, Ty))
ffiSigInstance mctx cat decl =
  ffiMatchSpine
    mctx.mcCells.aliasTableRef.value
    cat
    decl
    (Some (ffiBinderSeed (namedArgOrder cat) (namedArgOrder decl)))

-- Each catalog binder against the declaration's binder at its position, or a
-- name no declaration can write when the declaration names none there.
ffiBinderSeed : List (String, Int) -> List (String, Int) -> List (String, Ty)
ffiBinderSeed cat decl =
  let byPos = map (p => (snd p, fst p)) decl
  map (p => (fst p, TyVar (optionOr "" (lookupAssocI (snd p) byPos)))) cat

ffiMatchSpine : List (TabKey, (List String, Ty)) ->
  Ty ->
  Ty ->
  Option (List (String, Ty)) ->
  Option (List (String, Ty))
ffiMatchSpine aliases cat decl acc = match (
  ffiSigStrip aliases cat,
  ffiSigStrip aliases decl,
)
  (TyFun a r, TyFun c d) =>
    ffiMatchSpine
      aliases
      (ffiRowBody r)
      (ffiRowBody d)
      (ffiMatchTy aliases a c acc)
  (c, d) => ffiMatchTy aliases c d acc

ffiMatchTy : List (TabKey, (List String, Ty)) ->
  Ty ->
  Ty ->
  Option (List (String, Ty)) ->
  Option (List (String, Ty))
ffiMatchTy _ _ _ None = None
ffiMatchTy aliases cat decl (Some sub) = match (
  ffiSigStrip aliases cat,
  ffiSigStrip aliases decl,
)
  (TyVar v, d) => match lookupAssoc v sub
    Some bound => if ffiSameTy aliases bound d then Some sub else None
    None => Some ((v, d) :: sub)
  (TyEffect l1 t1 a, TyEffect l2 t2 c) =>
    ffiMatchTy aliases a c (ffiMatchRow l1 t1 l2 t2 (Some sub))
  (TyEffect l1 t1 a, c) =>
    ffiMatchTy aliases a c (ffiMatchRow l1 t1 [] [] (Some sub))
  (a, TyEffect l2 t2 c) =>
    ffiMatchTy aliases a c (ffiMatchRow [] [] l2 t2 (Some sub))
  (TyRow l1 t1 _, TyRow l2 t2 _) => ffiMatchRow l1 t1 l2 t2 (Some sub)
  (TyApp a b, TyApp c d) =>
    ffiMatchTy aliases b d (ffiMatchTy aliases a c (Some sub))
  (TyFun a b, TyFun c d) =>
    ffiMatchTy aliases b d (ffiMatchTy aliases a c (Some sub))
  (TyTuple xs, TyTuple ys) => ffiMatchTys aliases xs ys (Some sub)
  (TyQual a _ _, TyQual c _ _) => ffiMatchTy aliases a c (Some sub)
  (c, d) => if ffiSameTy aliases c d then Some sub else None

ffiMatchTys : List (TabKey, (List String, Ty)) ->
  List Ty ->
  List Ty ->
  Option (List (String, Ty)) ->
  Option (List (String, Ty))
ffiMatchTys _ [] [] acc = acc
ffiMatchTys aliases (c :: cs) (d :: ds) acc =
  ffiMatchTys aliases cs ds (ffiMatchTy aliases c d acc)
ffiMatchTys _ _ _ _ = None

-- A catalog row against a written one, exactly: each catalog atom meets an
-- atom of the same label whose authority it matches, and what the
-- declaration writes beyond them is the catalog's row variable, or nothing
-- when the catalog row is closed.
ffiMatchRow : List EffAtomTy ->
  List String ->
  List EffAtomTy ->
  List String ->
  Option (List (String, Ty)) ->
  Option (List (String, Ty))
ffiMatchRow _ _ _ _ None = None
ffiMatchRow l1 t1 l2 t2 (Some sub) = match ffiMatchAtoms l1 l2 sub
  None => None
  Some (sub2, rest) => match t1
    [] => match (rest, t2)
      ([], []) => Some sub2
      _ => None
    [v] => match lookupAssoc v sub2
      Some (TyRow bl bt _) =>
        if ffiSameRow bl bt rest t2 then Some sub2 else None
      Some _ => None
      None => Some ((v, TyRow rest t2 None) :: sub2)
    _ => match rest
      [] => if ffiSameNames t1 t2 then Some sub2 else None
      _ => None

ffiMatchAtoms : List EffAtomTy ->
  List EffAtomTy ->
  List (String, Ty) ->
  Option (List (String, Ty), List EffAtomTy)
ffiMatchAtoms [] rest sub = Some (sub, rest)
ffiMatchAtoms (a :: more) ds sub = match ffiTakeAtom a ds [] sub
  Some (sub2, ds2) => ffiMatchAtoms more ds2 sub2
  None => None

ffiTakeAtom : EffAtomTy ->
  List EffAtomTy ->
  List EffAtomTy ->
  List (String, Ty) ->
  Option (List (String, Ty), List EffAtomTy)
ffiTakeAtom _ [] _ _ = None
ffiTakeAtom a (d :: ds) skipped sub = match ffiMatchAtom a d sub
  Some sub2 => Some (sub2, reverseL skipped ++ ds)
  None => ffiTakeAtom a ds (d :: skipped) sub

ffiMatchAtom : EffAtomTy ->
  EffAtomTy ->
  List (String, Ty) ->
  Option (List (String, Ty))
ffiMatchAtom a d sub =
  if sameTyConHead
    a.eatLabel
    a.eatOrigin
    d.eatLabel
    d.eatOrigin then match a.eatParam
    EPName v => match lookupAssoc v sub
      Some bound => match ffiParamOf bound
        Some p => if ffiSameParam p d.eatParam then Some sub else None
        None => None
      None => Some ((v, ffiParamTy d.eatParam) :: sub)
    p => if ffiSameParam p d.eatParam then Some sub else None
  else
    None

-- An authority as a substitution holds it: a name as a variable, anything
-- written as the authority term.
ffiParamTy : EffParamTy -> Ty
ffiParamTy (EPName n) = TyVar n
ffiParamTy p = TyAuth [p] None

ffiParamOf : Ty -> Option EffParamTy
ffiParamOf (TyAuth [p] _) = Some p
ffiParamOf (TyVar m) = Some (EPName m)
ffiParamOf _ = None

ffiSameParam : EffParamTy -> EffParamTy -> Bool
ffiSameParam p q = ppTy (TyAuth [p] None) == ppTy (TyAuth [q] None)

-- Two written rows are the same row: the same set of atoms, each label by its
-- declared identity, and the same set of row variables. A row is a set, so a
-- repeated atom is that atom once and never stands in for another.
ffiSameRow : List EffAtomTy ->
  List String ->
  List EffAtomTy ->
  List String ->
  Bool
ffiSameRow l1 t1 l2 t2 =
  ffiAtomsWithin l1 l2 && ffiAtomsWithin l2 l1 && ffiSameNames t1 t2

ffiAtomsWithin : List EffAtomTy -> List EffAtomTy -> Bool
ffiAtomsWithin xs ys = allList (a => anyList (b => ffiSameAtom a b) ys) xs

ffiSameAtom : EffAtomTy -> EffAtomTy -> Bool
ffiSameAtom a b =
  sameTyConHead a.eatLabel a.eatOrigin b.eatLabel b.eatOrigin
    && ffiSameParam a.eatParam b.eatParam

ffiSameNames : List String -> List String -> Bool
ffiSameNames xs ys =
  allList (x => contains x ys) xs && allList (y => contains y xs) ys

-- Two written types are the same type: heads by identity, variables by
-- name, rows by `ffiSameRow`, authorities by their rendering.
ffiSameTy : List (TabKey, (List String, Ty)) -> Ty -> Ty -> Bool
ffiSameTy aliases a b = match (ffiSigStrip aliases a, ffiSigStrip aliases b)
  (TyEffect l1 t1 x, y) => match ffiRowParts y
    (l2, t2, y2) => ffiSameRow l1 t1 l2 t2 && ffiSameTy aliases x y2
  (x, TyEffect l2 t2 y) => ffiSameRow [] [] l2 t2 && ffiSameTy aliases x y
  (TyCon { tyConName = n1, tyConOrigin = o1 }, TyCon { tyConName = n2, tyConOrigin = o2 }) =>
    sameTyConHead n1 o1 n2 o2
  (TyVar x, TyVar y) => x == y
  (TyApp a1 b1, TyApp a2 b2) =>
    ffiSameTy aliases a1 a2 && ffiSameTy aliases b1 b2
  (TyFun a1 b1, TyFun a2 b2) =>
    ffiSameTy aliases a1 a2 && ffiSameTy aliases b1 b2
  (TyTuple xs, TyTuple ys) =>
    listLen xs == listLen ys
      && allList (p => ffiSameTy aliases (fst p) (snd p)) (zipL xs ys)
  (TyQual x _ _, TyQual y _ _) => ffiSameTy aliases x y
  (TyAuth ps _, TyAuth qs _) => ppTy (TyAuth ps None) == ppTy (TyAuth qs None)
  (TyRow l1 t1 _, TyRow l2 t2 _) => ffiSameRow l1 t1 l2 t2
  _ => False

-- A written type with its outer row, which an unwritten row leaves empty.
ffiRowParts : Ty -> (List EffAtomTy, List String, Ty)
ffiRowParts (TyEffect l t inner) = (l, t, inner)
ffiRowParts t = ([], [], t)

ffiRowBody : Ty -> Ty
ffiRowBody t = match ffiRowParts t
  (_, _, inner) => inner

ffiSigStrip : List (TabKey, (List String, Ty)) -> Ty -> Ty
ffiSigStrip aliases t = match expandAliasHeadTyWith aliases t
  TyConstrained _ inner => ffiSigStrip aliases inner
  TyNamed _ inner _ => ffiSigStrip aliases inner
  u => u

-- The row each arrow of a signature's spine carries on its result, in order.
ffiSpineRows : List (TabKey, (List String, Ty)) ->
  Ty ->
  List (List EffAtomTy, List String)
ffiSpineRows aliases t = match ffiSigStrip aliases t
  TyFun _ r => match ffiRowParts r
    (l, tl, inner) => (l, tl) :: ffiSpineRows aliases inner
  _ => []

-- The catalog row with each index binder the declaration fixed replaced by
-- what it wrote there: `<Net h>` against `Socket "a.com/*"` is
-- `<Net "a.com/*">`, and against a join `Socket ("a.com/*" | "b.com/*")` one
-- atom per term. An argument's binder is left as written, since the row
-- rule pairs those by position.
ffiInstRow : List (String, Int) ->
  List (String, Ty) ->
  List EffAtomTy ->
  List EffAtomTy
ffiInstRow names sub ls =
  let free = filterList (p => isNone (lookupAssoc (fst p) names)) sub
  flatMap (ffiInstAtom free) ls

ffiInstAtom : List (String, Ty) -> EffAtomTy -> List EffAtomTy
ffiInstAtom sub a = match a.eatParam
  EPName n => match lookupAssoc n sub
    Some (TyAuth ps _) => map (p => { a | eatParam = p }) ps
    Some (TyVar m) => [{ a | eatParam = EPName m }]
    _ => [a]
  _ => [a]

-- ── the CATALOG-ROW rule (#2163, epic #2070 R2) ─────────────────────────────
--
-- The fifth declaration rule, and it is about the effect row, not the shape.
--
-- `ffiCheckExternsShadow` above leaves the row each arrow's result carries to
-- this rule, so `<>` and `<FileWrite>` on `writeFile`'s last arrow are one type
-- to it.  Without this rule, R2's own escape-hatch sentence stays live for every
-- catalog name: a local
--
--   extern writeFile : String -> String -> <> Result String Unit
--
-- is an instance of the catalog's type, passes every rule above, and types a caller as
-- `String -> Unit` — while the emitter, which is name-keyed and never sees a
-- typecheck verdict (`isAnyExtern` and the selected extern facts), lowers the call to the REAL
-- `writeFile` and the file is really written.  `medaka check` printed
-- `innocent : String -> Unit` for a function that writes to disk, at exit 0.
--
-- The rule is subsumption, not equality, and not a ban.  At each arrow of the
-- spine, the declared row must cover the catalog's row at the same arrow
-- (declared ⊇ catalog), instantiated by the shadow rule's match; it may be
-- wider.  A row written at an earlier arrow does not cover a later one.  Two reasons
-- it is not the blunter "refuse catalog redeclaration outright":
--
--   * the compatible-redeclaration idiom is load-bearing in the tree, DERIVED not
--     assumed — cross-referencing every `^extern ` line under `test/`, `demo/`,
--     `playground/`, `compiler/`, `sqlite/` and `pds/` against the 138 catalog
--     names finds live users in `test/wasm/fixtures/stagea_extern_probe.mdk` and
--     `stageb_float_reinterpret.mdk`, `test/effect_param_fixtures/{env,exec}_*.mdk`,
--     `test/effect_builtin_param_fixtures/ffi_cross_builtin_name_accept.mdk`,
--     `test/parse_fixtures/imports.mdk`, `test/typecheck_error_fixtures/
--     value_restriction_ref*.mdk` and `test/diff_compiler_llvm_ffi.sh`, plus the
--     `extern putStrLn : String -> <IO> Unit` example in `docs/spec/SYNTAX.md`;
--   * a WIDER row is not a lie.  It over-declares what the caller must permit,
--     which is the safe direction — the same direction a declared bound already
--     stands in to an inferred body row everywhere else in this file.
--
-- `atomsEscape`, not bare `atomsDiff`: the catalog row is the "inferred" side
-- (what is really performed) and the DECLARED row is the BOUND, so the bound's
-- `IO` must be widened to its security-label alias first (`expandIoInBound`).
-- Without that widening `extern putStrLn : String -> <IO> Unit` — the spelling
-- `docs/spec/SYNTAX.md` teaches, and `test/parse_fixtures/imports.mdk` uses —
-- would be rejected against the catalog's `<Stdout>`, which is strictly narrower.
-- `atomsEscape` IS `atomsDiff` with that one widening; it is not a second subset
-- predicate.
--
-- Both rows are lifted to atoms HERE, at the check seam, never at the seed seam
-- — see `noteBuiltinExternNames` for why (the effect-domain registry).
--
-- A catalog row with no written effects at all (`bitAnd`, `arrayBlit`, the 100-odd
-- pure rows) yields the empty atom set, which every declared row covers, so this
-- rule is silent for them by construction rather than by an exemption list.
export
ffiCheckExternsCatalogRow : ModuleCtx -> Bool -> List Decl -> Unit
ffiCheckExternsCatalogRow mctx False _ = ()
ffiCheckExternsCatalogRow mctx True ds =
  ffiCheckCatalogRowGo mctx (externDecls ds)

ffiCheckCatalogRowGo : ModuleCtx -> List Decl -> Unit
ffiCheckCatalogRowGo mctx [] = ()
ffiCheckCatalogRowGo mctx ((DExtern (ExternDecl { edName = n, edTy = ty, ... })) :: rest) =
  let _ = match omLookup n mctx.mcGraph.builtinExternNamesRef.value
    Some (cat, catNames) => match ffiSigInstance mctx cat ty
      Some sub =>
        let aliases = mctx.mcCells.aliasTableRef.value
        let pairs = zipL (ffiSpineRows aliases cat) (ffiSpineRows aliases ty)
        let arrows = listLen pairs
        fold
          (_ ip =>
            ffiCheckSpineRow
              mctx
              n
              ty
              catNames
              sub
              (ffiArrowNote (fst ip) arrows)
              (fst (snd ip))
              (snd (snd ip)))
          ()
          (zipL (rangeFromCount 1 arrows) pairs)
      -- the shadow rule has refused the declaration
      None => ()
    None => ()
  ffiCheckCatalogRowGo mctx rest
ffiCheckCatalogRowGo mctx (_ :: rest) = ffiCheckCatalogRowGo mctx rest

-- One arrow of the spine: the catalog's row there, instantiated by the match
-- (its row variable becomes the row the declaration wrote for it), against the
-- row the declaration writes at the same arrow.
ffiCheckSpineRow : ModuleCtx ->
  String ->
  Ty ->
  List (String, Int) ->
  List (String, Ty) ->
  String ->
  (List EffAtomTy, List String) ->
  (List EffAtomTy, List String) ->
  Unit
ffiCheckSpineRow mctx n ty catNames sub arrow cat decl =
  let tails = ffiExpandTails sub (snd cat)
  let _ =
    ffiCheckCatalogRowOne
      mctx
      n
      ty
      arrow
      (ffiInstRow catNames sub (fst cat) ++ fst tails)
      catNames
      (fst decl)
  match filterList (v => not (contains v (snd decl))) (snd tails)
    [] => ()
    missing =>
      pushTypeErrorAt
        mctx
        "T-FFI-CATALOG-NARROW"
        (firstTyLoc ty)
        (ffiCatalogTailMsg n arrow missing)

ffiExpandTails : List (String, Ty) ->
  List String ->
  (List EffAtomTy, List String)
ffiExpandTails _ [] = ([], [])
ffiExpandTails sub (v :: vs) =
  let rest = ffiExpandTails sub vs
  match lookupAssoc v sub
    Some (TyRow bl bt _) => (bl ++ fst rest, bt ++ snd rest)
    _ => (fst rest, v :: snd rest)

-- Both rows are lifted with the SAME authority variable per argument
-- position, so a binder covers the catalog's binder only when it names the
-- same argument; a bare label (the top) covers any binder, and a binder never
-- covers a bare catalog label. Any other name, an index variable such as the
-- `h` of `Socket ("a.com/*" | h)`, is one variable on both sides too: it
-- covers itself and nothing else, as it does at a call.
ffiCheckCatalogRowOne : ModuleCtx ->
  String ->
  Ty ->
  String ->
  List EffAtomTy ->
  List (String, Int) ->
  List EffAtomTy ->
  Unit
ffiCheckCatalogRowOne mctx n ty arrow catRow catNames declRow =
  let declNames = namedArgOrder ty
  let cells = positionCells mctx (catNames ++ declNames)
  let free =
    map
      (x => (x, freshAuthvar mctx PUnit (Some x)))
      (freeAuthorityNames (map fst (catNames ++ declNames)) (catRow ++ declRow))
  let catAtoms =
    atomsOfWrittenIn
      mctx.mcGraph
      (withFreeAuths free (positionalSigVars catNames cells))
      catRow
  let declAtoms =
    atomsOfWrittenIn
      mctx.mcGraph
      (withFreeAuths free (positionalSigVars declNames cells))
      declRow
  match atomsEscape mctx.mcGraph catAtoms declAtoms
    [] => ()
    missing =>
      pushTypeErrorAt
        mctx
        "T-FFI-CATALOG-NARROW"
        (firstTyLoc ty)
        (ffiCatalogNarrowMsg n arrow catAtoms declAtoms missing)

-- One variable per argument position named by either row, carrying the
-- first binder spelling seen for that position so a message reads as written.
positionCells : ModuleCtx -> List (String, Int) -> List (Int, Ref Authvar)
positionCells mctx [] = []
positionCells mctx ((binder, pos) :: rest) =
  let others = positionCells mctx rest
  if isSome (lookupAssocI pos others) then
    others
  else
    (pos, freshAuthvar mctx PUnit (Some binder)) :: others

-- The names a row's atoms write that no argument binds, each once.
freeAuthorityNames : List String -> List EffAtomTy -> List String
freeAuthorityNames bound ls =
  sortUniqS
    (flatMap
      (a => filterList (x => not (contains x bound)) (effParamNames a.eatParam))
      ls)

withFreeAuths : List (String, Ref Authvar) -> SigVars -> SigVars
withFreeAuths free sv = { sv | svAuths = sv.svAuths ++ free }

positionalSigVars : List (String, Int) -> List (Int, Ref Authvar) -> SigVars
positionalSigVars names cells = SigVars {
  svRows = [],
  svAuths =
    flatMap
      (p => match lookupAssocI (snd p) cells
        Some cell => [(fst p, cell)]
        None => [])
      names,
}

-- ── signature heads, for the emitter's FFI rows ─────────────────────────────
--
-- The `(argument heads, return head)` projection of a signature, the granularity
-- the checked FFI facts consumed by the emitter records for the emitter's FFI
-- index: a foreign call's representation is decided by its heads.  A type
-- variable projects to `_`, so renaming one changes nothing.  This projection
-- says nothing about whether a redeclaration of a catalog name is honest; that
-- is `ffiSigInstance`, over the whole type.
--
-- `expandAliasHeadTy` at each step for the reason `ffiCheckExternSig` needs it: an
-- alias-named arrow is invisible to a purely syntactic walk.  Cycles cannot recur
-- here: `rejectCyclicAliases` has emptied the table of them before the check seam.
ffiSigArgHeadsWith : List (TabKey, (List String, Ty)) -> Ty -> List String
ffiSigArgHeadsWith aliases ty = match expandAliasHeadTyWith aliases ty
  TyConstrained _ inner => ffiSigArgHeadsWith aliases inner
  TyEffect _ _ inner => ffiSigArgHeadsWith aliases inner
  TyFun a r => ffiTyHeadNameWith aliases a :: ffiSigArgHeadsWith aliases r
  _ => []

ffiSigRetHeadWith : List (TabKey, (List String, Ty)) -> Ty -> String
ffiSigRetHeadWith aliases ty = match expandAliasHeadTyWith aliases ty
  TyConstrained _ inner => ffiSigRetHeadWith aliases inner
  TyEffect _ _ inner => ffiSigRetHeadWith aliases inner
  TyFun _ r => ffiSigRetHeadWith aliases r
  t => ffiTyHeadNameWith aliases t

ffiTyHeadNameWith : List (TabKey, (List String, Ty)) -> Ty -> String
ffiTyHeadNameWith aliases ty = match expandAliasHeadTyWith aliases ty
  TyCon { tyConName = n } => n
  TyApp a _ => ffiTyHeadNameWith aliases a
  TyVar _ => "_"
  TyConstrained _ t => ffiTyHeadNameWith aliases t
  TyEffect _ _ t => ffiTyHeadNameWith aliases t
  TyNamed _ t _ => ffiTyHeadNameWith aliases t
  TyQual t _ _ => ffiTyHeadNameWith aliases t
  -- A parenthesised arrow in a VALUE position (a function-typed parameter).  It
  -- gets its own token rather than falling into the catch-all so that two
  -- unrelated exotic shapes do not compare equal and re-open the exemption.
  TyFun _ _ => "->"
  _ => "?"

export
ffiExternTypeRowsWith : OrdMap (Ty, List (String, Int)) ->
  List (TabKey, (List String, Ty)) ->
  List Decl ->
  List (String, (List (String, String), (List String, String)))
ffiExternTypeRowsWith _ _ [] = []
ffiExternTypeRowsWith catalog aliases ((DExtern d) :: rest) =
  externRowCons
    (omHasKey d.edName catalog)
    d
    (ffiSigArgHeadsWith aliases d.edTy, ffiSigRetHeadWith aliases d.edTy)
    (ffiExternTypeRowsWith catalog aliases rest)
ffiExternTypeRowsWith catalog aliases ((DAttrib _ inner) :: rest) =
  ffiExternTypeRowsWith catalog aliases (inner :: rest)
ffiExternTypeRowsWith catalog aliases (_ :: rest) =
  ffiExternTypeRowsWith catalog aliases rest

-- Walk the arrow spine.  Every PARAM position and the final RESULT position is
-- a value that actually crosses; the row wrappers and the constraint prefix are
-- not values and are walked THROUGH, not checked.  `expandAliasHeadTy` at each
-- step for the same reason `ffiDeclaredRow` needs it: `type CFn = List Int -> <> Int`
-- hides the offending type behind a name a syntactic walk falls through.
-- `fb` is the WHOLE SIGNATURE's first located head, computed once at the decl and
-- used only when the offending position itself carries no location.  That case is
-- real, not theoretical: a bare `TyVar` has `firstTyLoc = None` (`ast.mdk`), so
-- `extern wrapL : a -> List a` reported its `a` parameter at `:1:0` — a caret on
-- line 1 of a file whose defect is on line 7, which ERROR-QUALITY §2.1 rules out.
-- `DExtern` has a `Loc` this diagnostic does not use (`edLoc`), so the
-- signature's own first `TyCon` is the nearest true anchor available.
ffiCheckExternSig : ModuleCtx -> String -> Option Loc -> Ty -> Unit
ffiCheckExternSig mctx n fb ty = match expandAliasHeadTy mctx ty
  TyConstrained _ inner => ffiCheckExternSig mctx n fb inner
  TyFun a r =>
    let _ = ffiCheckExternPos mctx n fb a
    ffiCheckExternSig mctx n fb r
  TyEffect _ _ inner => ffiCheckExternSig mctx n fb inner
  t => ffiCheckExternPos mctx n fb t

-- A VALUE position.  A function type landing here is the closure cell §3 rules
-- out, and it reaches this arm rather than `ffiCheckExternSig`'s `TyFun` arm
-- because a parenthesised arrow is an ARGUMENT, not the spine.
ffiCheckExternPos : ModuleCtx -> String -> Option Loc -> Ty -> Unit
ffiCheckExternPos mctx n fb t
  | ffiCrossableTy mctx t = ()
  | otherwise =
    pushTypeErrorAt
      mctx
      "T-FFI-NONCROSSABLE"
      (orElseLoc (firstTyLoc t) fb)
      (ffiNonCrossableMsg n t)

-- ── the DECLARED-ROW HONESTY rule (F1, epic #2070) ──────────────────────────
--
-- The rule this replaces was A silent rewrite, and that is why it is A CHECK.
-- `userExternSchemes` used to ADD `FFI` to a user extern's terminal row whenever
-- the label was absent, so the row a reader sees in the source and the row the
-- effect system enforces were two different rows.  It fired on EVERY shape, not
-- just the empty one: `<Net "a.com/*">` was rewritten to `<FFI, Net "a.com/*">`
-- with no diagnostic, so a declaration could not even be WRITTEN honestly and be
-- believed.  The rule now runs in the only direction that keeps the source and
-- the type the same object: the author writes `FFI`, or the declaration fails.
--
-- Every user `extern` is a foreign call by construction (`compiler/FFI-ABI.md`;
-- nothing in the language distinguishes "models a real foreign symbol" from "is
-- effect-domain test furniture"), so there is no carve-out for a row that names
-- some other domain — `<Net "a.com/*">` must be written `<FFI, Net "a.com/*">`.
--
-- Gated on the SAME `ffiStampMode` Bool as the crossable guard, and exempting the
-- SAME builtin-name set: a redeclaration of a `stdlib/runtime.mdk` catalog name is
-- lowered as the builtin regardless of what its local row claims
-- (`ffiIsBuiltinExternName` carries that measurement), so its signature is not a
-- foreign-call contract and this rule does not own it either.  Both guards keying
-- on one Bool and one exemption is deliberate: two ownership tests could disagree.
export
ffiCheckExternsLabelled : ModuleCtx -> Bool -> List Decl -> Unit
ffiCheckExternsLabelled mctx False _ = ()
ffiCheckExternsLabelled mctx True ds = ffiCheckLabelsGo mctx (externDecls ds)

ffiCheckLabelsGo : ModuleCtx -> List Decl -> Unit
ffiCheckLabelsGo mctx [] = ()
ffiCheckLabelsGo mctx ((DExtern d) :: rest) =
  let diags =
    ffiDeclarationDiags
      (ffiIsBuiltinExternName mctx.mcGraph d.edName)
      d
      (ffiDeclaredRow mctx d.edTy)
  let _ = fold (_ diag => pushFfiDiag mctx diag) () diags
  ffiCheckLabelsGo mctx rest
ffiCheckLabelsGo mctx (_ :: rest) = ffiCheckLabelsGo mctx rest

pushFfiDiag : ModuleCtx -> FfiDiag -> Unit
pushFfiDiag mctx (FfiDiag code loc msg) = pushTypeErrorAt mctx code loc msg

-- The `DExtern` sublist, in order.  Its own clause rather than a `filter` with a
-- lambda predicate: `Decl` has no cheap "is an extern" projection, so the pattern
-- match IS the predicate.
export
externDecls : List Decl -> List Decl
externDecls [] = []
externDecls ((d@(DExtern _)) :: rest) = d :: externDecls rest
externDecls (_ :: rest) = externDecls rest
# DESUGAR
(DUse false (UseGroup ("types" "tc_types") ((mem "SigVars" true) (mem "GraphCtx" false) (mem "ModuleCtx" false))))
(DUse false (UseGroup ("types" "tc_diag_text") ((mem "ffiArrowNote" false))))
(DUse false (UseGroup ("types" "tc_diag") ((mem "pushTypeErrorAt" false))))
(DUse false (UseGroup ("types" "tc_unify") ((mem "atomsEscape" false) (mem "freshAuthvar" false))))
(DUse false (UseGroup ("types" "tc_decls_types") ((mem "atomsOfWrittenIn" false))))
(DUse false (UseGroup ("types" "tc_decls") ((mem "expandAliasHeadTy" false) (mem "expandAliasHeadTyWith" false))))
(DUse false (UseGroup ("types" "effect_authority") ((mem "Authvar" true))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "EffAtomTy" true) (mem "EffParamTy" true) (mem "ExternDecl" true) (mem "Loc" true) (mem "TabKey" true) (mem "Ty" true) (mem "effParamNames" false) (mem "externRowCons" false) (mem "firstTyLoc" false) (mem "isFixedIntHead" false) (mem "orElseLoc" false) (mem "sameTyConHead" false))))
(DUse false (UseGroup ("types" "ffi_bindings") ((mem "FfiDiag" true) (mem "ffiCatalogNarrowMsg" false) (mem "ffiCatalogTailMsg" false) (mem "ffiDeclarationDiags" false) (mem "ffiNonCrossableMsg" false) (mem "ffiShadowMsg" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "omHasKey" false) (mem "omInsert" false) (mem "omLookup" false) (mem "omSize" false) (mem "OrdMap" false))))
(DUse false (UseGroup ("support" "util") ((mem "allList" false) (mem "anyList" false) (mem "contains" false) (mem "filterList" false) (mem "isSome" false) (mem "listLen" false) (mem "lookupAssoc" false) (mem "reverseL" false) (mem "sortUniqS" false) (mem "zipL" false))))
(DUse false (UseGroup ("types" "repr") ((mem "lookupAssocI" false) (mem "ppTy" false))))
(DUse false (UseGroup ("types" "effect_domain") ((mem "Param" true))))
(DTypeSig true "rangeFromCount" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "rangeFromCount" ((PVar "start") (PVar "count")) (EIf (EBinOp "<=" (EVar "count") (ELit (LInt 0))) (EListLit) (EIf (EVar "otherwise") (EBinOp "::" (EVar "start") (EApp (EApp (EVar "rangeFromCount") (EBinOp "+" (EVar "start") (ELit (LInt 1)))) (EBinOp "-" (EVar "count") (ELit (LInt 1))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "externSigsToMap" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "OrdMap") (TyTuple (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))))) (TyApp (TyCon "OrdMap") (TyTuple (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))))))))
(DFunDef false "externSigsToMap" ((PList) (PVar "m")) (EVar "m"))
(DFunDef false "externSigsToMap" ((PCons (PCon "DExtern" (PRec "ExternDecl" ((rf "edName" (PVar "n")) (rf "edTy" (PVar "ty"))) true)) (PVar "rest")) (PVar "m")) (EApp (EApp (EVar "externSigsToMap") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (ETuple (EVar "ty") (EApp (EVar "namedArgOrder") (EVar "ty")))) (EVar "m"))))
(DFunDef false "externSigsToMap" ((PCons PWild (PVar "rest")) (PVar "m")) (EApp (EApp (EVar "externSigsToMap") (EVar "rest")) (EVar "m")))
(DTypeSig false "namedArgOrder" (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int")))))
(DFunDef false "namedArgOrder" ((PVar "ty")) (EApp (EApp (EVar "namedArgPositions") (EVar "ty")) (ELit (LInt 0))))
(DTypeSig false "namedArgPositions" (TyFun (TyCon "Ty") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))))))
(DFunDef false "namedArgPositions" ((PCon "TyFun" (PCon "TyNamed" (PVar "n") PWild PWild) (PVar "b")) (PVar "i")) (EBinOp "::" (ETuple (EVar "n") (EVar "i")) (EApp (EApp (EVar "namedArgPositions") (EVar "b")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))
(DFunDef false "namedArgPositions" ((PCon "TyFun" PWild (PVar "b")) (PVar "i")) (EApp (EApp (EVar "namedArgPositions") (EVar "b")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))))
(DFunDef false "namedArgPositions" ((PCon "TyConstrained" PWild (PVar "t")) (PVar "i")) (EApp (EApp (EVar "namedArgPositions") (EVar "t")) (EVar "i")))
(DFunDef false "namedArgPositions" (PWild PWild) (EListLit))
(DTypeSig true "ffiStampMode" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "ffiStampMode" ((PVar "gctx") (PVar "mid")) (EBinOp "&&" (EBinOp ">" (EApp (EVar "omSize") (EFieldAccess (EFieldAccess (EVar "gctx") "builtinExternNamesRef") "value")) (ELit (LInt 0))) (EApp (EApp (EVar "ffiStampModeOwned") (EVar "gctx")) (EVar "mid"))))
(DTypeSig false "ffiStampModeOwned" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "ffiStampModeOwned" ((PVar "gctx") (PLit (LString "__user__"))) (EApp (EVar "not") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "config") "value") "tcFlatEntryIsStdlib")))
(DFunDef false "ffiStampModeOwned" ((PVar "gctx") (PVar "mid")) (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EVar "mid")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "config") "value") "tcStdlibOwned"))))
(DTypeSig false "ffiDeclaredRow" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Ty") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "EffAtomTy"))))))
(DFunDef false "ffiDeclaredRow" ((PVar "mctx") (PVar "t")) (EMatch (EApp (EApp (EVar "expandAliasHeadTy") (EVar "mctx")) (EVar "t")) (arm (PCon "TyConstrained" PWild (PVar "inner")) () (EApp (EApp (EVar "ffiDeclaredRow") (EVar "mctx")) (EVar "inner"))) (arm (PCon "TyFun" PWild (PVar "r")) () (EApp (EVar "Some") (EApp (EApp (EVar "ffiResultRow") (EVar "mctx")) (EVar "r")))) (arm PWild () (EVar "None"))))
(DTypeSig false "ffiResultRow" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyCon "EffAtomTy")))))
(DFunDef false "ffiResultRow" ((PVar "mctx") (PVar "t")) (EMatch (EApp (EApp (EVar "expandAliasHeadTy") (EVar "mctx")) (EVar "t")) (arm (PCon "TyFun" PWild (PVar "r")) () (EApp (EApp (EVar "ffiResultRow") (EVar "mctx")) (EVar "r"))) (arm (PCon "TyEffect" (PVar "ls") PWild PWild) () (EVar "ls")) (arm PWild () (EListLit))))
(DTypeSig false "ffiCrossableTy" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Ty") (TyCon "Bool"))))
(DFunDef false "ffiCrossableTy" ((PVar "mctx") (PVar "t")) (EMatch (EApp (EApp (EVar "expandAliasHeadTy") (EVar "mctx")) (EVar "t")) (arm (PRec "TyCon" ((rf "tyConName" (PVar "n"))) false) () (EApp (EVar "ffiCrossableConName") (EVar "n"))) (arm (PCon "TyNamed" PWild (PVar "inner") PWild) () (EApp (EApp (EVar "ffiCrossableTy") (EVar "mctx")) (EVar "inner"))) (arm (PCon "TyQual" (PVar "inner") PWild PWild) () (EApp (EApp (EVar "ffiCrossableTy") (EVar "mctx")) (EVar "inner"))) (arm (PCon "TyApp" (PVar "a") (PVar "b")) () (EMatch (ETuple (EApp (EApp (EVar "expandAliasHeadTy") (EVar "mctx")) (EVar "a")) (EApp (EApp (EVar "expandAliasHeadTy") (EVar "mctx")) (EVar "b"))) (arm (PTuple (PRec "TyCon" ((rf "tyConName" (PLit (LString "Array")))) false) (PRec "TyCon" ((rf "tyConName" (PLit (LString "Int")))) false)) () (EVar "True")) (arm PWild () (EVar "False")))) (arm PWild () (EVar "False"))))
(DTypeSig false "ffiCrossableConName" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "ffiCrossableConName" ((PVar "n")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "n") (ELit (LString "Int"))) (EBinOp "==" (EVar "n") (ELit (LString "Float")))) (EBinOp "==" (EVar "n") (ELit (LString "Bool")))) (EBinOp "==" (EVar "n") (ELit (LString "Char")))) (EBinOp "==" (EVar "n") (ELit (LString "String")))) (EBinOp "==" (EVar "n") (ELit (LString "Unit")))) (EApp (EVar "isFixedIntHead") (EVar "n"))))
(DTypeSig true "ffiCheckExternsCrossable" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Unit")))))
(DFunDef false "ffiCheckExternsCrossable" ((PVar "mctx") (PCon "False") PWild) (ELit LUnit))
(DFunDef false "ffiCheckExternsCrossable" ((PVar "mctx") (PCon "True") (PVar "ds")) (EApp (EApp (EVar "ffiCheckExternsGo") (EVar "mctx")) (EApp (EVar "externDecls") (EVar "ds"))))
(DTypeSig false "ffiCheckExternsGo" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Unit"))))
(DFunDef false "ffiCheckExternsGo" ((PVar "mctx") (PList)) (ELit LUnit))
(DFunDef false "ffiCheckExternsGo" ((PVar "mctx") (PCons (PCon "DExtern" (PRec "ExternDecl" ((rf "edName" (PVar "n")) (rf "edTy" (PVar "ty"))) true)) (PVar "rest"))) (EBlock (DoLet false false PWild (EIf (EApp (EApp (EVar "ffiIsBuiltinExternName") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "n")) (ELit LUnit) (EApp (EApp (EApp (EApp (EVar "ffiCheckExternSig") (EVar "mctx")) (EVar "n")) (EApp (EVar "firstTyLoc") (EVar "ty"))) (EVar "ty")))) (DoExpr (EApp (EApp (EVar "ffiCheckExternsGo") (EVar "mctx")) (EVar "rest")))))
(DFunDef false "ffiCheckExternsGo" ((PVar "mctx") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "ffiCheckExternsGo") (EVar "mctx")) (EVar "rest")))
(DTypeSig false "ffiIsBuiltinExternName" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "ffiIsBuiltinExternName" ((PVar "gctx") (PVar "n")) (EApp (EApp (EVar "omHasKey") (EVar "n")) (EFieldAccess (EFieldAccess (EVar "gctx") "builtinExternNamesRef") "value")))
(DTypeSig true "ffiCheckExternsShadow" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Unit")))))
(DFunDef false "ffiCheckExternsShadow" ((PVar "mctx") (PCon "False") PWild) (ELit LUnit))
(DFunDef false "ffiCheckExternsShadow" ((PVar "mctx") (PCon "True") (PVar "ds")) (EApp (EApp (EVar "ffiCheckShadowGo") (EVar "mctx")) (EApp (EVar "externDecls") (EVar "ds"))))
(DTypeSig false "ffiCheckShadowGo" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Unit"))))
(DFunDef false "ffiCheckShadowGo" ((PVar "mctx") (PList)) (ELit LUnit))
(DFunDef false "ffiCheckShadowGo" ((PVar "mctx") (PCons (PCon "DExtern" (PRec "ExternDecl" ((rf "edName" (PVar "n")) (rf "edTy" (PVar "ty"))) true)) (PVar "rest"))) (EBlock (DoLet false false PWild (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "builtinExternNamesRef") "value")) (arm (PCon "Some" (PTuple (PVar "cat") PWild)) () (EMatch (EApp (EApp (EApp (EVar "ffiSigInstance") (EVar "mctx")) (EVar "cat")) (EVar "ty")) (arm (PCon "Some" PWild) () (ELit LUnit)) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "pushTypeErrorAt") (EVar "mctx")) (ELit (LString "T-FFI-BUILTIN-SHADOW"))) (EApp (EVar "firstTyLoc") (EVar "ty"))) (EApp (EApp (EApp (EVar "ffiShadowMsg") (EVar "n")) (EApp (EVar "ppTy") (EVar "cat"))) (EApp (EVar "ppTy") (EVar "ty"))))))) (arm (PCon "None") () (ELit LUnit)))) (DoExpr (EApp (EApp (EVar "ffiCheckShadowGo") (EVar "mctx")) (EVar "rest")))))
(DFunDef false "ffiCheckShadowGo" ((PVar "mctx") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "ffiCheckShadowGo") (EVar "mctx")) (EVar "rest")))
(DTypeSig false "ffiSigInstance" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Ty") (TyFun (TyCon "Ty") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))))))))
(DFunDef false "ffiSigInstance" ((PVar "mctx") (PVar "cat") (PVar "decl")) (EApp (EApp (EApp (EApp (EVar "ffiMatchSpine") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "aliasTableRef") "value")) (EVar "cat")) (EVar "decl")) (EApp (EVar "Some") (EApp (EApp (EVar "ffiBinderSeed") (EApp (EVar "namedArgOrder") (EVar "cat"))) (EApp (EVar "namedArgOrder") (EVar "decl"))))))
(DTypeSig false "ffiBinderSeed" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))))))
(DFunDef false "ffiBinderSeed" ((PVar "cat") (PVar "decl")) (EBlock (DoLet false false (PVar "byPos") (EApp (EApp (EVar "map") (ELam ((PVar "p")) (ETuple (EApp (EVar "snd") (EVar "p")) (EApp (EVar "fst") (EVar "p"))))) (EVar "decl"))) (DoExpr (EApp (EApp (EVar "map") (ELam ((PVar "p")) (ETuple (EApp (EVar "fst") (EVar "p")) (EApp (EVar "TyVar") (EApp (EApp (EVar "optionOr") (ELit (LString ""))) (EApp (EApp (EVar "lookupAssocI") (EApp (EVar "snd") (EVar "p"))) (EVar "byPos"))))))) (EVar "cat")))))
(DTypeSig false "ffiMatchSpine" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Ty")))) (TyFun (TyCon "Ty") (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty")))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty")))))))))
(DFunDef false "ffiMatchSpine" ((PVar "aliases") (PVar "cat") (PVar "decl") (PVar "acc")) (EMatch (ETuple (EApp (EApp (EVar "ffiSigStrip") (EVar "aliases")) (EVar "cat")) (EApp (EApp (EVar "ffiSigStrip") (EVar "aliases")) (EVar "decl"))) (arm (PTuple (PCon "TyFun" (PVar "a") (PVar "r")) (PCon "TyFun" (PVar "c") (PVar "d"))) () (EApp (EApp (EApp (EApp (EVar "ffiMatchSpine") (EVar "aliases")) (EApp (EVar "ffiRowBody") (EVar "r"))) (EApp (EVar "ffiRowBody") (EVar "d"))) (EApp (EApp (EApp (EApp (EVar "ffiMatchTy") (EVar "aliases")) (EVar "a")) (EVar "c")) (EVar "acc")))) (arm (PTuple (PVar "c") (PVar "d")) () (EApp (EApp (EApp (EApp (EVar "ffiMatchTy") (EVar "aliases")) (EVar "c")) (EVar "d")) (EVar "acc")))))
(DTypeSig false "ffiMatchTy" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Ty")))) (TyFun (TyCon "Ty") (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty")))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty")))))))))
(DFunDef false "ffiMatchTy" (PWild PWild PWild (PCon "None")) (EVar "None"))
(DFunDef false "ffiMatchTy" ((PVar "aliases") (PVar "cat") (PVar "decl") (PCon "Some" (PVar "sub"))) (EMatch (ETuple (EApp (EApp (EVar "ffiSigStrip") (EVar "aliases")) (EVar "cat")) (EApp (EApp (EVar "ffiSigStrip") (EVar "aliases")) (EVar "decl"))) (arm (PTuple (PCon "TyVar" (PVar "v")) (PVar "d")) () (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "v")) (EVar "sub")) (arm (PCon "Some" (PVar "bound")) () (EIf (EApp (EApp (EApp (EVar "ffiSameTy") (EVar "aliases")) (EVar "bound")) (EVar "d")) (EApp (EVar "Some") (EVar "sub")) (EVar "None"))) (arm (PCon "None") () (EApp (EVar "Some") (EBinOp "::" (ETuple (EVar "v") (EVar "d")) (EVar "sub")))))) (arm (PTuple (PCon "TyEffect" (PVar "l1") (PVar "t1") (PVar "a")) (PCon "TyEffect" (PVar "l2") (PVar "t2") (PVar "c"))) () (EApp (EApp (EApp (EApp (EVar "ffiMatchTy") (EVar "aliases")) (EVar "a")) (EVar "c")) (EApp (EApp (EApp (EApp (EApp (EVar "ffiMatchRow") (EVar "l1")) (EVar "t1")) (EVar "l2")) (EVar "t2")) (EApp (EVar "Some") (EVar "sub"))))) (arm (PTuple (PCon "TyEffect" (PVar "l1") (PVar "t1") (PVar "a")) (PVar "c")) () (EApp (EApp (EApp (EApp (EVar "ffiMatchTy") (EVar "aliases")) (EVar "a")) (EVar "c")) (EApp (EApp (EApp (EApp (EApp (EVar "ffiMatchRow") (EVar "l1")) (EVar "t1")) (EListLit)) (EListLit)) (EApp (EVar "Some") (EVar "sub"))))) (arm (PTuple (PVar "a") (PCon "TyEffect" (PVar "l2") (PVar "t2") (PVar "c"))) () (EApp (EApp (EApp (EApp (EVar "ffiMatchTy") (EVar "aliases")) (EVar "a")) (EVar "c")) (EApp (EApp (EApp (EApp (EApp (EVar "ffiMatchRow") (EListLit)) (EListLit)) (EVar "l2")) (EVar "t2")) (EApp (EVar "Some") (EVar "sub"))))) (arm (PTuple (PCon "TyRow" (PVar "l1") (PVar "t1") PWild) (PCon "TyRow" (PVar "l2") (PVar "t2") PWild)) () (EApp (EApp (EApp (EApp (EApp (EVar "ffiMatchRow") (EVar "l1")) (EVar "t1")) (EVar "l2")) (EVar "t2")) (EApp (EVar "Some") (EVar "sub")))) (arm (PTuple (PCon "TyApp" (PVar "a") (PVar "b")) (PCon "TyApp" (PVar "c") (PVar "d"))) () (EApp (EApp (EApp (EApp (EVar "ffiMatchTy") (EVar "aliases")) (EVar "b")) (EVar "d")) (EApp (EApp (EApp (EApp (EVar "ffiMatchTy") (EVar "aliases")) (EVar "a")) (EVar "c")) (EApp (EVar "Some") (EVar "sub"))))) (arm (PTuple (PCon "TyFun" (PVar "a") (PVar "b")) (PCon "TyFun" (PVar "c") (PVar "d"))) () (EApp (EApp (EApp (EApp (EVar "ffiMatchTy") (EVar "aliases")) (EVar "b")) (EVar "d")) (EApp (EApp (EApp (EApp (EVar "ffiMatchTy") (EVar "aliases")) (EVar "a")) (EVar "c")) (EApp (EVar "Some") (EVar "sub"))))) (arm (PTuple (PCon "TyTuple" (PVar "xs")) (PCon "TyTuple" (PVar "ys"))) () (EApp (EApp (EApp (EApp (EVar "ffiMatchTys") (EVar "aliases")) (EVar "xs")) (EVar "ys")) (EApp (EVar "Some") (EVar "sub")))) (arm (PTuple (PCon "TyQual" (PVar "a") PWild PWild) (PCon "TyQual" (PVar "c") PWild PWild)) () (EApp (EApp (EApp (EApp (EVar "ffiMatchTy") (EVar "aliases")) (EVar "a")) (EVar "c")) (EApp (EVar "Some") (EVar "sub")))) (arm (PTuple (PVar "c") (PVar "d")) () (EIf (EApp (EApp (EApp (EVar "ffiSameTy") (EVar "aliases")) (EVar "c")) (EVar "d")) (EApp (EVar "Some") (EVar "sub")) (EVar "None")))))
(DTypeSig false "ffiMatchTys" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Ty")))) (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty")))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty")))))))))
(DFunDef false "ffiMatchTys" (PWild (PList) (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "ffiMatchTys" ((PVar "aliases") (PCons (PVar "c") (PVar "cs")) (PCons (PVar "d") (PVar "ds")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "ffiMatchTys") (EVar "aliases")) (EVar "cs")) (EVar "ds")) (EApp (EApp (EApp (EApp (EVar "ffiMatchTy") (EVar "aliases")) (EVar "c")) (EVar "d")) (EVar "acc"))))
(DFunDef false "ffiMatchTys" (PWild PWild PWild PWild) (EVar "None"))
(DTypeSig false "ffiMatchRow" (TyFun (TyApp (TyCon "List") (TyCon "EffAtomTy")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "EffAtomTy")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty")))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))))))))))
(DFunDef false "ffiMatchRow" (PWild PWild PWild PWild (PCon "None")) (EVar "None"))
(DFunDef false "ffiMatchRow" ((PVar "l1") (PVar "t1") (PVar "l2") (PVar "t2") (PCon "Some" (PVar "sub"))) (EMatch (EApp (EApp (EApp (EVar "ffiMatchAtoms") (EVar "l1")) (EVar "l2")) (EVar "sub")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PTuple (PVar "sub2") (PVar "rest"))) () (EMatch (EVar "t1") (arm (PList) () (EMatch (ETuple (EVar "rest") (EVar "t2")) (arm (PTuple (PList) (PList)) () (EApp (EVar "Some") (EVar "sub2"))) (arm PWild () (EVar "None")))) (arm (PList (PVar "v")) () (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "v")) (EVar "sub2")) (arm (PCon "Some" (PCon "TyRow" (PVar "bl") (PVar "bt") PWild)) () (EIf (EApp (EApp (EApp (EApp (EVar "ffiSameRow") (EVar "bl")) (EVar "bt")) (EVar "rest")) (EVar "t2")) (EApp (EVar "Some") (EVar "sub2")) (EVar "None"))) (arm (PCon "Some" PWild) () (EVar "None")) (arm (PCon "None") () (EApp (EVar "Some") (EBinOp "::" (ETuple (EVar "v") (EApp (EApp (EApp (EVar "TyRow") (EVar "rest")) (EVar "t2")) (EVar "None"))) (EVar "sub2")))))) (arm PWild () (EMatch (EVar "rest") (arm (PList) () (EIf (EApp (EApp (EVar "ffiSameNames") (EVar "t1")) (EVar "t2")) (EApp (EVar "Some") (EVar "sub2")) (EVar "None"))) (arm PWild () (EVar "None"))))))))
(DTypeSig false "ffiMatchAtoms" (TyFun (TyApp (TyCon "List") (TyCon "EffAtomTy")) (TyFun (TyApp (TyCon "List") (TyCon "EffAtomTy")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyApp (TyCon "List") (TyCon "EffAtomTy"))))))))
(DFunDef false "ffiMatchAtoms" ((PList) (PVar "rest") (PVar "sub")) (EApp (EVar "Some") (ETuple (EVar "sub") (EVar "rest"))))
(DFunDef false "ffiMatchAtoms" ((PCons (PVar "a") (PVar "more")) (PVar "ds") (PVar "sub")) (EMatch (EApp (EApp (EApp (EApp (EVar "ffiTakeAtom") (EVar "a")) (EVar "ds")) (EListLit)) (EVar "sub")) (arm (PCon "Some" (PTuple (PVar "sub2") (PVar "ds2"))) () (EApp (EApp (EApp (EVar "ffiMatchAtoms") (EVar "more")) (EVar "ds2")) (EVar "sub2"))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "ffiTakeAtom" (TyFun (TyCon "EffAtomTy") (TyFun (TyApp (TyCon "List") (TyCon "EffAtomTy")) (TyFun (TyApp (TyCon "List") (TyCon "EffAtomTy")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyApp (TyCon "List") (TyCon "EffAtomTy")))))))))
(DFunDef false "ffiTakeAtom" (PWild (PList) PWild PWild) (EVar "None"))
(DFunDef false "ffiTakeAtom" ((PVar "a") (PCons (PVar "d") (PVar "ds")) (PVar "skipped") (PVar "sub")) (EMatch (EApp (EApp (EApp (EVar "ffiMatchAtom") (EVar "a")) (EVar "d")) (EVar "sub")) (arm (PCon "Some" (PVar "sub2")) () (EApp (EVar "Some") (ETuple (EVar "sub2") (EBinOp "++" (EApp (EVar "reverseL") (EVar "skipped")) (EVar "ds"))))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "ffiTakeAtom") (EVar "a")) (EVar "ds")) (EBinOp "::" (EVar "d") (EVar "skipped"))) (EVar "sub")))))
(DTypeSig false "ffiMatchAtom" (TyFun (TyCon "EffAtomTy") (TyFun (TyCon "EffAtomTy") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))))))))
(DFunDef false "ffiMatchAtom" ((PVar "a") (PVar "d") (PVar "sub")) (EIf (EApp (EApp (EApp (EApp (EVar "sameTyConHead") (EFieldAccess (EVar "a") "eatLabel")) (EFieldAccess (EVar "a") "eatOrigin")) (EFieldAccess (EVar "d") "eatLabel")) (EFieldAccess (EVar "d") "eatOrigin")) (EMatch (EFieldAccess (EVar "a") "eatParam") (arm (PCon "EPName" (PVar "v")) () (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "v")) (EVar "sub")) (arm (PCon "Some" (PVar "bound")) () (EMatch (EApp (EVar "ffiParamOf") (EVar "bound")) (arm (PCon "Some" (PVar "p")) () (EIf (EApp (EApp (EVar "ffiSameParam") (EVar "p")) (EFieldAccess (EVar "d") "eatParam")) (EApp (EVar "Some") (EVar "sub")) (EVar "None"))) (arm (PCon "None") () (EVar "None")))) (arm (PCon "None") () (EApp (EVar "Some") (EBinOp "::" (ETuple (EVar "v") (EApp (EVar "ffiParamTy") (EFieldAccess (EVar "d") "eatParam"))) (EVar "sub")))))) (arm (PVar "p") () (EIf (EApp (EApp (EVar "ffiSameParam") (EVar "p")) (EFieldAccess (EVar "d") "eatParam")) (EApp (EVar "Some") (EVar "sub")) (EVar "None")))) (EVar "None")))
(DTypeSig false "ffiParamTy" (TyFun (TyCon "EffParamTy") (TyCon "Ty")))
(DFunDef false "ffiParamTy" ((PCon "EPName" (PVar "n"))) (EApp (EVar "TyVar") (EVar "n")))
(DFunDef false "ffiParamTy" ((PVar "p")) (EApp (EApp (EVar "TyAuth") (EListLit (EVar "p"))) (EVar "None")))
(DTypeSig false "ffiParamOf" (TyFun (TyCon "Ty") (TyApp (TyCon "Option") (TyCon "EffParamTy"))))
(DFunDef false "ffiParamOf" ((PCon "TyAuth" (PList (PVar "p")) PWild)) (EApp (EVar "Some") (EVar "p")))
(DFunDef false "ffiParamOf" ((PCon "TyVar" (PVar "m"))) (EApp (EVar "Some") (EApp (EVar "EPName") (EVar "m"))))
(DFunDef false "ffiParamOf" (PWild) (EVar "None"))
(DTypeSig false "ffiSameParam" (TyFun (TyCon "EffParamTy") (TyFun (TyCon "EffParamTy") (TyCon "Bool"))))
(DFunDef false "ffiSameParam" ((PVar "p") (PVar "q")) (EBinOp "==" (EApp (EVar "ppTy") (EApp (EApp (EVar "TyAuth") (EListLit (EVar "p"))) (EVar "None"))) (EApp (EVar "ppTy") (EApp (EApp (EVar "TyAuth") (EListLit (EVar "q"))) (EVar "None")))))
(DTypeSig false "ffiSameRow" (TyFun (TyApp (TyCon "List") (TyCon "EffAtomTy")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "EffAtomTy")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))))
(DFunDef false "ffiSameRow" ((PVar "l1") (PVar "t1") (PVar "l2") (PVar "t2")) (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "ffiAtomsWithin") (EVar "l1")) (EVar "l2")) (EApp (EApp (EVar "ffiAtomsWithin") (EVar "l2")) (EVar "l1"))) (EApp (EApp (EVar "ffiSameNames") (EVar "t1")) (EVar "t2"))))
(DTypeSig false "ffiAtomsWithin" (TyFun (TyApp (TyCon "List") (TyCon "EffAtomTy")) (TyFun (TyApp (TyCon "List") (TyCon "EffAtomTy")) (TyCon "Bool"))))
(DFunDef false "ffiAtomsWithin" ((PVar "xs") (PVar "ys")) (EApp (EApp (EVar "allList") (ELam ((PVar "a")) (EApp (EApp (EVar "anyList") (ELam ((PVar "b")) (EApp (EApp (EVar "ffiSameAtom") (EVar "a")) (EVar "b")))) (EVar "ys")))) (EVar "xs")))
(DTypeSig false "ffiSameAtom" (TyFun (TyCon "EffAtomTy") (TyFun (TyCon "EffAtomTy") (TyCon "Bool"))))
(DFunDef false "ffiSameAtom" ((PVar "a") (PVar "b")) (EBinOp "&&" (EApp (EApp (EApp (EApp (EVar "sameTyConHead") (EFieldAccess (EVar "a") "eatLabel")) (EFieldAccess (EVar "a") "eatOrigin")) (EFieldAccess (EVar "b") "eatLabel")) (EFieldAccess (EVar "b") "eatOrigin")) (EApp (EApp (EVar "ffiSameParam") (EFieldAccess (EVar "a") "eatParam")) (EFieldAccess (EVar "b") "eatParam"))))
(DTypeSig false "ffiSameNames" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "ffiSameNames" ((PVar "xs") (PVar "ys")) (EBinOp "&&" (EApp (EApp (EVar "allList") (ELam ((PVar "x")) (EApp (EApp (EVar "contains") (EVar "x")) (EVar "ys")))) (EVar "xs")) (EApp (EApp (EVar "allList") (ELam ((PVar "y")) (EApp (EApp (EVar "contains") (EVar "y")) (EVar "xs")))) (EVar "ys"))))
(DTypeSig false "ffiSameTy" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Ty")))) (TyFun (TyCon "Ty") (TyFun (TyCon "Ty") (TyCon "Bool")))))
(DFunDef false "ffiSameTy" ((PVar "aliases") (PVar "a") (PVar "b")) (EMatch (ETuple (EApp (EApp (EVar "ffiSigStrip") (EVar "aliases")) (EVar "a")) (EApp (EApp (EVar "ffiSigStrip") (EVar "aliases")) (EVar "b"))) (arm (PTuple (PCon "TyEffect" (PVar "l1") (PVar "t1") (PVar "x")) (PVar "y")) () (EMatch (EApp (EVar "ffiRowParts") (EVar "y")) (arm (PTuple (PVar "l2") (PVar "t2") (PVar "y2")) () (EBinOp "&&" (EApp (EApp (EApp (EApp (EVar "ffiSameRow") (EVar "l1")) (EVar "t1")) (EVar "l2")) (EVar "t2")) (EApp (EApp (EApp (EVar "ffiSameTy") (EVar "aliases")) (EVar "x")) (EVar "y2")))))) (arm (PTuple (PVar "x") (PCon "TyEffect" (PVar "l2") (PVar "t2") (PVar "y"))) () (EBinOp "&&" (EApp (EApp (EApp (EApp (EVar "ffiSameRow") (EListLit)) (EListLit)) (EVar "l2")) (EVar "t2")) (EApp (EApp (EApp (EVar "ffiSameTy") (EVar "aliases")) (EVar "x")) (EVar "y")))) (arm (PTuple (PRec "TyCon" ((rf "tyConName" (PVar "n1")) (rf "tyConOrigin" (PVar "o1"))) false) (PRec "TyCon" ((rf "tyConName" (PVar "n2")) (rf "tyConOrigin" (PVar "o2"))) false)) () (EApp (EApp (EApp (EApp (EVar "sameTyConHead") (EVar "n1")) (EVar "o1")) (EVar "n2")) (EVar "o2"))) (arm (PTuple (PCon "TyVar" (PVar "x")) (PCon "TyVar" (PVar "y"))) () (EBinOp "==" (EVar "x") (EVar "y"))) (arm (PTuple (PCon "TyApp" (PVar "a1") (PVar "b1")) (PCon "TyApp" (PVar "a2") (PVar "b2"))) () (EBinOp "&&" (EApp (EApp (EApp (EVar "ffiSameTy") (EVar "aliases")) (EVar "a1")) (EVar "a2")) (EApp (EApp (EApp (EVar "ffiSameTy") (EVar "aliases")) (EVar "b1")) (EVar "b2")))) (arm (PTuple (PCon "TyFun" (PVar "a1") (PVar "b1")) (PCon "TyFun" (PVar "a2") (PVar "b2"))) () (EBinOp "&&" (EApp (EApp (EApp (EVar "ffiSameTy") (EVar "aliases")) (EVar "a1")) (EVar "a2")) (EApp (EApp (EApp (EVar "ffiSameTy") (EVar "aliases")) (EVar "b1")) (EVar "b2")))) (arm (PTuple (PCon "TyTuple" (PVar "xs")) (PCon "TyTuple" (PVar "ys"))) () (EBinOp "&&" (EBinOp "==" (EApp (EVar "listLen") (EVar "xs")) (EApp (EVar "listLen") (EVar "ys"))) (EApp (EApp (EVar "allList") (ELam ((PVar "p")) (EApp (EApp (EApp (EVar "ffiSameTy") (EVar "aliases")) (EApp (EVar "fst") (EVar "p"))) (EApp (EVar "snd") (EVar "p"))))) (EApp (EApp (EVar "zipL") (EVar "xs")) (EVar "ys"))))) (arm (PTuple (PCon "TyQual" (PVar "x") PWild PWild) (PCon "TyQual" (PVar "y") PWild PWild)) () (EApp (EApp (EApp (EVar "ffiSameTy") (EVar "aliases")) (EVar "x")) (EVar "y"))) (arm (PTuple (PCon "TyAuth" (PVar "ps") PWild) (PCon "TyAuth" (PVar "qs") PWild)) () (EBinOp "==" (EApp (EVar "ppTy") (EApp (EApp (EVar "TyAuth") (EVar "ps")) (EVar "None"))) (EApp (EVar "ppTy") (EApp (EApp (EVar "TyAuth") (EVar "qs")) (EVar "None"))))) (arm (PTuple (PCon "TyRow" (PVar "l1") (PVar "t1") PWild) (PCon "TyRow" (PVar "l2") (PVar "t2") PWild)) () (EApp (EApp (EApp (EApp (EVar "ffiSameRow") (EVar "l1")) (EVar "t1")) (EVar "l2")) (EVar "t2"))) (arm PWild () (EVar "False"))))
(DTypeSig false "ffiRowParts" (TyFun (TyCon "Ty") (TyTuple (TyApp (TyCon "List") (TyCon "EffAtomTy")) (TyApp (TyCon "List") (TyCon "String")) (TyCon "Ty"))))
(DFunDef false "ffiRowParts" ((PCon "TyEffect" (PVar "l") (PVar "t") (PVar "inner"))) (ETuple (EVar "l") (EVar "t") (EVar "inner")))
(DFunDef false "ffiRowParts" ((PVar "t")) (ETuple (EListLit) (EListLit) (EVar "t")))
(DTypeSig false "ffiRowBody" (TyFun (TyCon "Ty") (TyCon "Ty")))
(DFunDef false "ffiRowBody" ((PVar "t")) (EMatch (EApp (EVar "ffiRowParts") (EVar "t")) (arm (PTuple PWild PWild (PVar "inner")) () (EVar "inner"))))
(DTypeSig false "ffiSigStrip" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Ty")))) (TyFun (TyCon "Ty") (TyCon "Ty"))))
(DFunDef false "ffiSigStrip" ((PVar "aliases") (PVar "t")) (EMatch (EApp (EApp (EVar "expandAliasHeadTyWith") (EVar "aliases")) (EVar "t")) (arm (PCon "TyConstrained" PWild (PVar "inner")) () (EApp (EApp (EVar "ffiSigStrip") (EVar "aliases")) (EVar "inner"))) (arm (PCon "TyNamed" PWild (PVar "inner") PWild) () (EApp (EApp (EVar "ffiSigStrip") (EVar "aliases")) (EVar "inner"))) (arm (PVar "u") () (EVar "u"))))
(DTypeSig false "ffiSpineRows" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Ty")))) (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "EffAtomTy")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "ffiSpineRows" ((PVar "aliases") (PVar "t")) (EMatch (EApp (EApp (EVar "ffiSigStrip") (EVar "aliases")) (EVar "t")) (arm (PCon "TyFun" PWild (PVar "r")) () (EMatch (EApp (EVar "ffiRowParts") (EVar "r")) (arm (PTuple (PVar "l") (PVar "tl") (PVar "inner")) () (EBinOp "::" (ETuple (EVar "l") (EVar "tl")) (EApp (EApp (EVar "ffiSpineRows") (EVar "aliases")) (EVar "inner")))))) (arm PWild () (EListLit))))
(DTypeSig false "ffiInstRow" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyFun (TyApp (TyCon "List") (TyCon "EffAtomTy")) (TyApp (TyCon "List") (TyCon "EffAtomTy"))))))
(DFunDef false "ffiInstRow" ((PVar "names") (PVar "sub") (PVar "ls")) (EBlock (DoLet false false (PVar "free") (EApp (EApp (EVar "filterList") (ELam ((PVar "p")) (EApp (EVar "isNone") (EApp (EApp (EVar "lookupAssoc") (EApp (EVar "fst") (EVar "p"))) (EVar "names"))))) (EVar "sub"))) (DoExpr (EApp (EApp (EVar "flatMap") (EApp (EVar "ffiInstAtom") (EVar "free"))) (EVar "ls")))))
(DTypeSig false "ffiInstAtom" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyFun (TyCon "EffAtomTy") (TyApp (TyCon "List") (TyCon "EffAtomTy")))))
(DFunDef false "ffiInstAtom" ((PVar "sub") (PVar "a")) (EMatch (EFieldAccess (EVar "a") "eatParam") (arm (PCon "EPName" (PVar "n")) () (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EVar "sub")) (arm (PCon "Some" (PCon "TyAuth" (PVar "ps") PWild)) () (EApp (EApp (EVar "map") (ELam ((PVar "p")) (ERecordUpdate (EVar "a") ((fa "eatParam" (EVar "p")))))) (EVar "ps"))) (arm (PCon "Some" (PCon "TyVar" (PVar "m"))) () (EListLit (ERecordUpdate (EVar "a") ((fa "eatParam" (EApp (EVar "EPName") (EVar "m"))))))) (arm PWild () (EListLit (EVar "a"))))) (arm PWild () (EListLit (EVar "a")))))
(DTypeSig true "ffiCheckExternsCatalogRow" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Unit")))))
(DFunDef false "ffiCheckExternsCatalogRow" ((PVar "mctx") (PCon "False") PWild) (ELit LUnit))
(DFunDef false "ffiCheckExternsCatalogRow" ((PVar "mctx") (PCon "True") (PVar "ds")) (EApp (EApp (EVar "ffiCheckCatalogRowGo") (EVar "mctx")) (EApp (EVar "externDecls") (EVar "ds"))))
(DTypeSig false "ffiCheckCatalogRowGo" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Unit"))))
(DFunDef false "ffiCheckCatalogRowGo" ((PVar "mctx") (PList)) (ELit LUnit))
(DFunDef false "ffiCheckCatalogRowGo" ((PVar "mctx") (PCons (PCon "DExtern" (PRec "ExternDecl" ((rf "edName" (PVar "n")) (rf "edTy" (PVar "ty"))) true)) (PVar "rest"))) (EBlock (DoLet false false PWild (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "builtinExternNamesRef") "value")) (arm (PCon "Some" (PTuple (PVar "cat") (PVar "catNames"))) () (EMatch (EApp (EApp (EApp (EVar "ffiSigInstance") (EVar "mctx")) (EVar "cat")) (EVar "ty")) (arm (PCon "Some" (PVar "sub")) () (EBlock (DoLet false false (PVar "aliases") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "aliasTableRef") "value")) (DoLet false false (PVar "pairs") (EApp (EApp (EVar "zipL") (EApp (EApp (EVar "ffiSpineRows") (EVar "aliases")) (EVar "cat"))) (EApp (EApp (EVar "ffiSpineRows") (EVar "aliases")) (EVar "ty")))) (DoLet false false (PVar "arrows") (EApp (EVar "listLen") (EVar "pairs"))) (DoExpr (EApp (EApp (EApp (EVar "fold") (ELam (PWild (PVar "ip")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "ffiCheckSpineRow") (EVar "mctx")) (EVar "n")) (EVar "ty")) (EVar "catNames")) (EVar "sub")) (EApp (EApp (EVar "ffiArrowNote") (EApp (EVar "fst") (EVar "ip"))) (EVar "arrows"))) (EApp (EVar "fst") (EApp (EVar "snd") (EVar "ip")))) (EApp (EVar "snd") (EApp (EVar "snd") (EVar "ip")))))) (ELit LUnit)) (EApp (EApp (EVar "zipL") (EApp (EApp (EVar "rangeFromCount") (ELit (LInt 1))) (EVar "arrows"))) (EVar "pairs")))))) (arm (PCon "None") () (ELit LUnit)))) (arm (PCon "None") () (ELit LUnit)))) (DoExpr (EApp (EApp (EVar "ffiCheckCatalogRowGo") (EVar "mctx")) (EVar "rest")))))
(DFunDef false "ffiCheckCatalogRowGo" ((PVar "mctx") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "ffiCheckCatalogRowGo") (EVar "mctx")) (EVar "rest")))
(DTypeSig false "ffiCheckSpineRow" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyFun (TyCon "String") (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "EffAtomTy")) (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "EffAtomTy")) (TyApp (TyCon "List") (TyCon "String"))) (TyCon "Unit"))))))))))
(DFunDef false "ffiCheckSpineRow" ((PVar "mctx") (PVar "n") (PVar "ty") (PVar "catNames") (PVar "sub") (PVar "arrow") (PVar "cat") (PVar "decl")) (EBlock (DoLet false false (PVar "tails") (EApp (EApp (EVar "ffiExpandTails") (EVar "sub")) (EApp (EVar "snd") (EVar "cat")))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "ffiCheckCatalogRowOne") (EVar "mctx")) (EVar "n")) (EVar "ty")) (EVar "arrow")) (EBinOp "++" (EApp (EApp (EApp (EVar "ffiInstRow") (EVar "catNames")) (EVar "sub")) (EApp (EVar "fst") (EVar "cat"))) (EApp (EVar "fst") (EVar "tails")))) (EVar "catNames")) (EApp (EVar "fst") (EVar "decl")))) (DoExpr (EMatch (EApp (EApp (EVar "filterList") (ELam ((PVar "v")) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EVar "v")) (EApp (EVar "snd") (EVar "decl")))))) (EApp (EVar "snd") (EVar "tails"))) (arm (PList) () (ELit LUnit)) (arm (PVar "missing") () (EApp (EApp (EApp (EApp (EVar "pushTypeErrorAt") (EVar "mctx")) (ELit (LString "T-FFI-CATALOG-NARROW"))) (EApp (EVar "firstTyLoc") (EVar "ty"))) (EApp (EApp (EApp (EVar "ffiCatalogTailMsg") (EVar "n")) (EVar "arrow")) (EVar "missing"))))))))
(DTypeSig false "ffiExpandTails" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyTuple (TyApp (TyCon "List") (TyCon "EffAtomTy")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "ffiExpandTails" (PWild (PList)) (ETuple (EListLit) (EListLit)))
(DFunDef false "ffiExpandTails" ((PVar "sub") (PCons (PVar "v") (PVar "vs"))) (EBlock (DoLet false false (PVar "rest") (EApp (EApp (EVar "ffiExpandTails") (EVar "sub")) (EVar "vs"))) (DoExpr (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "v")) (EVar "sub")) (arm (PCon "Some" (PCon "TyRow" (PVar "bl") (PVar "bt") PWild)) () (ETuple (EBinOp "++" (EVar "bl") (EApp (EVar "fst") (EVar "rest"))) (EBinOp "++" (EVar "bt") (EApp (EVar "snd") (EVar "rest"))))) (arm PWild () (ETuple (EApp (EVar "fst") (EVar "rest")) (EBinOp "::" (EVar "v") (EApp (EVar "snd") (EVar "rest")))))))))
(DTypeSig false "ffiCheckCatalogRowOne" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "Ty") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "EffAtomTy")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyCon "EffAtomTy")) (TyCon "Unit")))))))))
(DFunDef false "ffiCheckCatalogRowOne" ((PVar "mctx") (PVar "n") (PVar "ty") (PVar "arrow") (PVar "catRow") (PVar "catNames") (PVar "declRow")) (EBlock (DoLet false false (PVar "declNames") (EApp (EVar "namedArgOrder") (EVar "ty"))) (DoLet false false (PVar "cells") (EApp (EApp (EVar "positionCells") (EVar "mctx")) (EBinOp "++" (EVar "catNames") (EVar "declNames")))) (DoLet false false (PVar "free") (EApp (EApp (EVar "map") (ELam ((PVar "x")) (ETuple (EVar "x") (EApp (EApp (EApp (EVar "freshAuthvar") (EVar "mctx")) (EVar "PUnit")) (EApp (EVar "Some") (EVar "x")))))) (EApp (EApp (EVar "freeAuthorityNames") (EApp (EApp (EVar "map") (EVar "fst")) (EBinOp "++" (EVar "catNames") (EVar "declNames")))) (EBinOp "++" (EVar "catRow") (EVar "declRow"))))) (DoLet false false (PVar "catAtoms") (EApp (EApp (EApp (EVar "atomsOfWrittenIn") (EFieldAccess (EVar "mctx") "mcGraph")) (EApp (EApp (EVar "withFreeAuths") (EVar "free")) (EApp (EApp (EVar "positionalSigVars") (EVar "catNames")) (EVar "cells")))) (EVar "catRow"))) (DoLet false false (PVar "declAtoms") (EApp (EApp (EApp (EVar "atomsOfWrittenIn") (EFieldAccess (EVar "mctx") "mcGraph")) (EApp (EApp (EVar "withFreeAuths") (EVar "free")) (EApp (EApp (EVar "positionalSigVars") (EVar "declNames")) (EVar "cells")))) (EVar "declRow"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "atomsEscape") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "catAtoms")) (EVar "declAtoms")) (arm (PList) () (ELit LUnit)) (arm (PVar "missing") () (EApp (EApp (EApp (EApp (EVar "pushTypeErrorAt") (EVar "mctx")) (ELit (LString "T-FFI-CATALOG-NARROW"))) (EApp (EVar "firstTyLoc") (EVar "ty"))) (EApp (EApp (EApp (EApp (EApp (EVar "ffiCatalogNarrowMsg") (EVar "n")) (EVar "arrow")) (EVar "catAtoms")) (EVar "declAtoms")) (EVar "missing"))))))))
(DTypeSig false "positionCells" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyApp (TyCon "Ref") (TyCon "Authvar")))))))
(DFunDef false "positionCells" ((PVar "mctx") (PList)) (EListLit))
(DFunDef false "positionCells" ((PVar "mctx") (PCons (PTuple (PVar "binder") (PVar "pos")) (PVar "rest"))) (EBlock (DoLet false false (PVar "others") (EApp (EApp (EVar "positionCells") (EVar "mctx")) (EVar "rest"))) (DoExpr (EIf (EApp (EVar "isSome") (EApp (EApp (EVar "lookupAssocI") (EVar "pos")) (EVar "others"))) (EVar "others") (EBinOp "::" (ETuple (EVar "pos") (EApp (EApp (EApp (EVar "freshAuthvar") (EVar "mctx")) (EVar "PUnit")) (EApp (EVar "Some") (EVar "binder")))) (EVar "others"))))))
(DTypeSig false "freeAuthorityNames" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "EffAtomTy")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "freeAuthorityNames" ((PVar "bound") (PVar "ls")) (EApp (EVar "sortUniqS") (EApp (EApp (EVar "flatMap") (ELam ((PVar "a")) (EApp (EApp (EVar "filterList") (ELam ((PVar "x")) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EVar "x")) (EVar "bound"))))) (EApp (EVar "effParamNames") (EFieldAccess (EVar "a") "eatParam"))))) (EVar "ls"))))
(DTypeSig false "withFreeAuths" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyCon "Authvar")))) (TyFun (TyCon "SigVars") (TyCon "SigVars"))))
(DFunDef false "withFreeAuths" ((PVar "free") (PVar "sv")) (ERecordUpdate (EVar "sv") ((fa "svAuths" (EBinOp "++" (EFieldAccess (EVar "sv") "svAuths") (EVar "free"))))))
(DTypeSig false "positionalSigVars" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyApp (TyCon "Ref") (TyCon "Authvar")))) (TyCon "SigVars"))))
(DFunDef false "positionalSigVars" ((PVar "names") (PVar "cells")) (ERecordCreate "SigVars" ((fa "svRows" (EListLit)) (fa "svAuths" (EApp (EApp (EVar "flatMap") (ELam ((PVar "p")) (EMatch (EApp (EApp (EVar "lookupAssocI") (EApp (EVar "snd") (EVar "p"))) (EVar "cells")) (arm (PCon "Some" (PVar "cell")) () (EListLit (ETuple (EApp (EVar "fst") (EVar "p")) (EVar "cell")))) (arm (PCon "None") () (EListLit))))) (EVar "names"))))))
(DTypeSig false "ffiSigArgHeadsWith" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Ty")))) (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "ffiSigArgHeadsWith" ((PVar "aliases") (PVar "ty")) (EMatch (EApp (EApp (EVar "expandAliasHeadTyWith") (EVar "aliases")) (EVar "ty")) (arm (PCon "TyConstrained" PWild (PVar "inner")) () (EApp (EApp (EVar "ffiSigArgHeadsWith") (EVar "aliases")) (EVar "inner"))) (arm (PCon "TyEffect" PWild PWild (PVar "inner")) () (EApp (EApp (EVar "ffiSigArgHeadsWith") (EVar "aliases")) (EVar "inner"))) (arm (PCon "TyFun" (PVar "a") (PVar "r")) () (EBinOp "::" (EApp (EApp (EVar "ffiTyHeadNameWith") (EVar "aliases")) (EVar "a")) (EApp (EApp (EVar "ffiSigArgHeadsWith") (EVar "aliases")) (EVar "r")))) (arm PWild () (EListLit))))
(DTypeSig false "ffiSigRetHeadWith" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Ty")))) (TyFun (TyCon "Ty") (TyCon "String"))))
(DFunDef false "ffiSigRetHeadWith" ((PVar "aliases") (PVar "ty")) (EMatch (EApp (EApp (EVar "expandAliasHeadTyWith") (EVar "aliases")) (EVar "ty")) (arm (PCon "TyConstrained" PWild (PVar "inner")) () (EApp (EApp (EVar "ffiSigRetHeadWith") (EVar "aliases")) (EVar "inner"))) (arm (PCon "TyEffect" PWild PWild (PVar "inner")) () (EApp (EApp (EVar "ffiSigRetHeadWith") (EVar "aliases")) (EVar "inner"))) (arm (PCon "TyFun" PWild (PVar "r")) () (EApp (EApp (EVar "ffiSigRetHeadWith") (EVar "aliases")) (EVar "r"))) (arm (PVar "t") () (EApp (EApp (EVar "ffiTyHeadNameWith") (EVar "aliases")) (EVar "t")))))
(DTypeSig false "ffiTyHeadNameWith" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Ty")))) (TyFun (TyCon "Ty") (TyCon "String"))))
(DFunDef false "ffiTyHeadNameWith" ((PVar "aliases") (PVar "ty")) (EMatch (EApp (EApp (EVar "expandAliasHeadTyWith") (EVar "aliases")) (EVar "ty")) (arm (PRec "TyCon" ((rf "tyConName" (PVar "n"))) false) () (EVar "n")) (arm (PCon "TyApp" (PVar "a") PWild) () (EApp (EApp (EVar "ffiTyHeadNameWith") (EVar "aliases")) (EVar "a"))) (arm (PCon "TyVar" PWild) () (ELit (LString "_"))) (arm (PCon "TyConstrained" PWild (PVar "t")) () (EApp (EApp (EVar "ffiTyHeadNameWith") (EVar "aliases")) (EVar "t"))) (arm (PCon "TyEffect" PWild PWild (PVar "t")) () (EApp (EApp (EVar "ffiTyHeadNameWith") (EVar "aliases")) (EVar "t"))) (arm (PCon "TyNamed" PWild (PVar "t") PWild) () (EApp (EApp (EVar "ffiTyHeadNameWith") (EVar "aliases")) (EVar "t"))) (arm (PCon "TyQual" (PVar "t") PWild PWild) () (EApp (EApp (EVar "ffiTyHeadNameWith") (EVar "aliases")) (EVar "t"))) (arm (PCon "TyFun" PWild PWild) () (ELit (LString "->"))) (arm PWild () (ELit (LString "?")))))
(DTypeSig true "ffiExternTypeRowsWith" (TyFun (TyApp (TyCon "OrdMap") (TyTuple (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Ty")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))))))))
(DFunDef false "ffiExternTypeRowsWith" (PWild PWild (PList)) (EListLit))
(DFunDef false "ffiExternTypeRowsWith" ((PVar "catalog") (PVar "aliases") (PCons (PCon "DExtern" (PVar "d")) (PVar "rest"))) (EApp (EApp (EApp (EApp (EVar "externRowCons") (EApp (EApp (EVar "omHasKey") (EFieldAccess (EVar "d") "edName")) (EVar "catalog"))) (EVar "d")) (ETuple (EApp (EApp (EVar "ffiSigArgHeadsWith") (EVar "aliases")) (EFieldAccess (EVar "d") "edTy")) (EApp (EApp (EVar "ffiSigRetHeadWith") (EVar "aliases")) (EFieldAccess (EVar "d") "edTy")))) (EApp (EApp (EApp (EVar "ffiExternTypeRowsWith") (EVar "catalog")) (EVar "aliases")) (EVar "rest"))))
(DFunDef false "ffiExternTypeRowsWith" ((PVar "catalog") (PVar "aliases") (PCons (PCon "DAttrib" PWild (PVar "inner")) (PVar "rest"))) (EApp (EApp (EApp (EVar "ffiExternTypeRowsWith") (EVar "catalog")) (EVar "aliases")) (EBinOp "::" (EVar "inner") (EVar "rest"))))
(DFunDef false "ffiExternTypeRowsWith" ((PVar "catalog") (PVar "aliases") (PCons PWild (PVar "rest"))) (EApp (EApp (EApp (EVar "ffiExternTypeRowsWith") (EVar "catalog")) (EVar "aliases")) (EVar "rest")))
(DTypeSig false "ffiCheckExternSig" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Ty") (TyCon "Unit"))))))
(DFunDef false "ffiCheckExternSig" ((PVar "mctx") (PVar "n") (PVar "fb") (PVar "ty")) (EMatch (EApp (EApp (EVar "expandAliasHeadTy") (EVar "mctx")) (EVar "ty")) (arm (PCon "TyConstrained" PWild (PVar "inner")) () (EApp (EApp (EApp (EApp (EVar "ffiCheckExternSig") (EVar "mctx")) (EVar "n")) (EVar "fb")) (EVar "inner"))) (arm (PCon "TyFun" (PVar "a") (PVar "r")) () (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "ffiCheckExternPos") (EVar "mctx")) (EVar "n")) (EVar "fb")) (EVar "a"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "ffiCheckExternSig") (EVar "mctx")) (EVar "n")) (EVar "fb")) (EVar "r"))))) (arm (PCon "TyEffect" PWild PWild (PVar "inner")) () (EApp (EApp (EApp (EApp (EVar "ffiCheckExternSig") (EVar "mctx")) (EVar "n")) (EVar "fb")) (EVar "inner"))) (arm (PVar "t") () (EApp (EApp (EApp (EApp (EVar "ffiCheckExternPos") (EVar "mctx")) (EVar "n")) (EVar "fb")) (EVar "t")))))
(DTypeSig false "ffiCheckExternPos" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Ty") (TyCon "Unit"))))))
(DFunDef false "ffiCheckExternPos" ((PVar "mctx") (PVar "n") (PVar "fb") (PVar "t")) (EIf (EApp (EApp (EVar "ffiCrossableTy") (EVar "mctx")) (EVar "t")) (ELit LUnit) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "pushTypeErrorAt") (EVar "mctx")) (ELit (LString "T-FFI-NONCROSSABLE"))) (EApp (EApp (EVar "orElseLoc") (EApp (EVar "firstTyLoc") (EVar "t"))) (EVar "fb"))) (EApp (EApp (EVar "ffiNonCrossableMsg") (EVar "n")) (EVar "t"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "ffiCheckExternsLabelled" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Unit")))))
(DFunDef false "ffiCheckExternsLabelled" ((PVar "mctx") (PCon "False") PWild) (ELit LUnit))
(DFunDef false "ffiCheckExternsLabelled" ((PVar "mctx") (PCon "True") (PVar "ds")) (EApp (EApp (EVar "ffiCheckLabelsGo") (EVar "mctx")) (EApp (EVar "externDecls") (EVar "ds"))))
(DTypeSig false "ffiCheckLabelsGo" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Unit"))))
(DFunDef false "ffiCheckLabelsGo" ((PVar "mctx") (PList)) (ELit LUnit))
(DFunDef false "ffiCheckLabelsGo" ((PVar "mctx") (PCons (PCon "DExtern" (PVar "d")) (PVar "rest"))) (EBlock (DoLet false false (PVar "diags") (EApp (EApp (EApp (EVar "ffiDeclarationDiags") (EApp (EApp (EVar "ffiIsBuiltinExternName") (EFieldAccess (EVar "mctx") "mcGraph")) (EFieldAccess (EVar "d") "edName"))) (EVar "d")) (EApp (EApp (EVar "ffiDeclaredRow") (EVar "mctx")) (EFieldAccess (EVar "d") "edTy")))) (DoLet false false PWild (EApp (EApp (EApp (EVar "fold") (ELam (PWild (PVar "diag")) (EApp (EApp (EVar "pushFfiDiag") (EVar "mctx")) (EVar "diag")))) (ELit LUnit)) (EVar "diags"))) (DoExpr (EApp (EApp (EVar "ffiCheckLabelsGo") (EVar "mctx")) (EVar "rest")))))
(DFunDef false "ffiCheckLabelsGo" ((PVar "mctx") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "ffiCheckLabelsGo") (EVar "mctx")) (EVar "rest")))
(DTypeSig false "pushFfiDiag" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "FfiDiag") (TyCon "Unit"))))
(DFunDef false "pushFfiDiag" ((PVar "mctx") (PCon "FfiDiag" (PVar "code") (PVar "loc") (PVar "msg"))) (EApp (EApp (EApp (EApp (EVar "pushTypeErrorAt") (EVar "mctx")) (EVar "code")) (EVar "loc")) (EVar "msg")))
(DTypeSig true "externDecls" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "externDecls" ((PList)) (EListLit))
(DFunDef false "externDecls" ((PCons (PAs "d" (PCon "DExtern" PWild)) (PVar "rest"))) (EBinOp "::" (EVar "d") (EApp (EVar "externDecls") (EVar "rest"))))
(DFunDef false "externDecls" ((PCons PWild (PVar "rest"))) (EApp (EVar "externDecls") (EVar "rest")))
# MARK
(DUse false (UseGroup ("types" "tc_types") ((mem "SigVars" true) (mem "GraphCtx" false) (mem "ModuleCtx" false))))
(DUse false (UseGroup ("types" "tc_diag_text") ((mem "ffiArrowNote" false))))
(DUse false (UseGroup ("types" "tc_diag") ((mem "pushTypeErrorAt" false))))
(DUse false (UseGroup ("types" "tc_unify") ((mem "atomsEscape" false) (mem "freshAuthvar" false))))
(DUse false (UseGroup ("types" "tc_decls_types") ((mem "atomsOfWrittenIn" false))))
(DUse false (UseGroup ("types" "tc_decls") ((mem "expandAliasHeadTy" false) (mem "expandAliasHeadTyWith" false))))
(DUse false (UseGroup ("types" "effect_authority") ((mem "Authvar" true))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "EffAtomTy" true) (mem "EffParamTy" true) (mem "ExternDecl" true) (mem "Loc" true) (mem "TabKey" true) (mem "Ty" true) (mem "effParamNames" false) (mem "externRowCons" false) (mem "firstTyLoc" false) (mem "isFixedIntHead" false) (mem "orElseLoc" false) (mem "sameTyConHead" false))))
(DUse false (UseGroup ("types" "ffi_bindings") ((mem "FfiDiag" true) (mem "ffiCatalogNarrowMsg" false) (mem "ffiCatalogTailMsg" false) (mem "ffiDeclarationDiags" false) (mem "ffiNonCrossableMsg" false) (mem "ffiShadowMsg" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "omHasKey" false) (mem "omInsert" false) (mem "omLookup" false) (mem "omSize" false) (mem "OrdMap" false))))
(DUse false (UseGroup ("support" "util") ((mem "allList" false) (mem "anyList" false) (mem "contains" false) (mem "filterList" false) (mem "isSome" false) (mem "listLen" false) (mem "lookupAssoc" false) (mem "reverseL" false) (mem "sortUniqS" false) (mem "zipL" false))))
(DUse false (UseGroup ("types" "repr") ((mem "lookupAssocI" false) (mem "ppTy" false))))
(DUse false (UseGroup ("types" "effect_domain") ((mem "Param" true))))
(DTypeSig true "rangeFromCount" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "rangeFromCount" ((PVar "start") (PVar "count")) (EIf (EBinOp "<=" (EDictApp "count") (ELit (LInt 0))) (EListLit) (EIf (EVar "otherwise") (EBinOp "::" (EVar "start") (EApp (EApp (EVar "rangeFromCount") (EBinOp "+" (EVar "start") (ELit (LInt 1)))) (EBinOp "-" (EDictApp "count") (ELit (LInt 1))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "externSigsToMap" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "OrdMap") (TyTuple (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))))) (TyApp (TyCon "OrdMap") (TyTuple (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))))))))
(DFunDef false "externSigsToMap" ((PList) (PVar "m")) (EVar "m"))
(DFunDef false "externSigsToMap" ((PCons (PCon "DExtern" (PRec "ExternDecl" ((rf "edName" (PVar "n")) (rf "edTy" (PVar "ty"))) true)) (PVar "rest")) (PVar "m")) (EApp (EApp (EVar "externSigsToMap") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (ETuple (EVar "ty") (EApp (EVar "namedArgOrder") (EVar "ty")))) (EVar "m"))))
(DFunDef false "externSigsToMap" ((PCons PWild (PVar "rest")) (PVar "m")) (EApp (EApp (EVar "externSigsToMap") (EVar "rest")) (EVar "m")))
(DTypeSig false "namedArgOrder" (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int")))))
(DFunDef false "namedArgOrder" ((PVar "ty")) (EApp (EApp (EVar "namedArgPositions") (EVar "ty")) (ELit (LInt 0))))
(DTypeSig false "namedArgPositions" (TyFun (TyCon "Ty") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))))))
(DFunDef false "namedArgPositions" ((PCon "TyFun" (PCon "TyNamed" (PVar "n") PWild PWild) (PVar "b")) (PVar "i")) (EBinOp "::" (ETuple (EVar "n") (EVar "i")) (EApp (EApp (EVar "namedArgPositions") (EVar "b")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))
(DFunDef false "namedArgPositions" ((PCon "TyFun" PWild (PVar "b")) (PVar "i")) (EApp (EApp (EVar "namedArgPositions") (EVar "b")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))))
(DFunDef false "namedArgPositions" ((PCon "TyConstrained" PWild (PVar "t")) (PVar "i")) (EApp (EApp (EVar "namedArgPositions") (EVar "t")) (EVar "i")))
(DFunDef false "namedArgPositions" (PWild PWild) (EListLit))
(DTypeSig true "ffiStampMode" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "ffiStampMode" ((PVar "gctx") (PVar "mid")) (EBinOp "&&" (EBinOp ">" (EApp (EVar "omSize") (EFieldAccess (EFieldAccess (EVar "gctx") "builtinExternNamesRef") "value")) (ELit (LInt 0))) (EApp (EApp (EVar "ffiStampModeOwned") (EVar "gctx")) (EVar "mid"))))
(DTypeSig false "ffiStampModeOwned" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "ffiStampModeOwned" ((PVar "gctx") (PLit (LString "__user__"))) (EApp (EVar "not") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "config") "value") "tcFlatEntryIsStdlib")))
(DFunDef false "ffiStampModeOwned" ((PVar "gctx") (PVar "mid")) (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EVar "mid")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "gctx") "config") "value") "tcStdlibOwned"))))
(DTypeSig false "ffiDeclaredRow" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Ty") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "EffAtomTy"))))))
(DFunDef false "ffiDeclaredRow" ((PVar "mctx") (PVar "t")) (EMatch (EApp (EApp (EVar "expandAliasHeadTy") (EVar "mctx")) (EVar "t")) (arm (PCon "TyConstrained" PWild (PVar "inner")) () (EApp (EApp (EVar "ffiDeclaredRow") (EVar "mctx")) (EVar "inner"))) (arm (PCon "TyFun" PWild (PVar "r")) () (EApp (EVar "Some") (EApp (EApp (EVar "ffiResultRow") (EVar "mctx")) (EVar "r")))) (arm PWild () (EVar "None"))))
(DTypeSig false "ffiResultRow" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyCon "EffAtomTy")))))
(DFunDef false "ffiResultRow" ((PVar "mctx") (PVar "t")) (EMatch (EApp (EApp (EVar "expandAliasHeadTy") (EVar "mctx")) (EVar "t")) (arm (PCon "TyFun" PWild (PVar "r")) () (EApp (EApp (EVar "ffiResultRow") (EVar "mctx")) (EVar "r"))) (arm (PCon "TyEffect" (PVar "ls") PWild PWild) () (EVar "ls")) (arm PWild () (EListLit))))
(DTypeSig false "ffiCrossableTy" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Ty") (TyCon "Bool"))))
(DFunDef false "ffiCrossableTy" ((PVar "mctx") (PVar "t")) (EMatch (EApp (EApp (EVar "expandAliasHeadTy") (EVar "mctx")) (EVar "t")) (arm (PRec "TyCon" ((rf "tyConName" (PVar "n"))) false) () (EApp (EVar "ffiCrossableConName") (EVar "n"))) (arm (PCon "TyNamed" PWild (PVar "inner") PWild) () (EApp (EApp (EVar "ffiCrossableTy") (EVar "mctx")) (EVar "inner"))) (arm (PCon "TyQual" (PVar "inner") PWild PWild) () (EApp (EApp (EVar "ffiCrossableTy") (EVar "mctx")) (EVar "inner"))) (arm (PCon "TyApp" (PVar "a") (PVar "b")) () (EMatch (ETuple (EApp (EApp (EVar "expandAliasHeadTy") (EVar "mctx")) (EVar "a")) (EApp (EApp (EVar "expandAliasHeadTy") (EVar "mctx")) (EVar "b"))) (arm (PTuple (PRec "TyCon" ((rf "tyConName" (PLit (LString "Array")))) false) (PRec "TyCon" ((rf "tyConName" (PLit (LString "Int")))) false)) () (EVar "True")) (arm PWild () (EVar "False")))) (arm PWild () (EVar "False"))))
(DTypeSig false "ffiCrossableConName" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "ffiCrossableConName" ((PVar "n")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "n") (ELit (LString "Int"))) (EBinOp "==" (EVar "n") (ELit (LString "Float")))) (EBinOp "==" (EVar "n") (ELit (LString "Bool")))) (EBinOp "==" (EVar "n") (ELit (LString "Char")))) (EBinOp "==" (EVar "n") (ELit (LString "String")))) (EBinOp "==" (EVar "n") (ELit (LString "Unit")))) (EApp (EVar "isFixedIntHead") (EVar "n"))))
(DTypeSig true "ffiCheckExternsCrossable" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Unit")))))
(DFunDef false "ffiCheckExternsCrossable" ((PVar "mctx") (PCon "False") PWild) (ELit LUnit))
(DFunDef false "ffiCheckExternsCrossable" ((PVar "mctx") (PCon "True") (PVar "ds")) (EApp (EApp (EVar "ffiCheckExternsGo") (EVar "mctx")) (EApp (EVar "externDecls") (EVar "ds"))))
(DTypeSig false "ffiCheckExternsGo" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Unit"))))
(DFunDef false "ffiCheckExternsGo" ((PVar "mctx") (PList)) (ELit LUnit))
(DFunDef false "ffiCheckExternsGo" ((PVar "mctx") (PCons (PCon "DExtern" (PRec "ExternDecl" ((rf "edName" (PVar "n")) (rf "edTy" (PVar "ty"))) true)) (PVar "rest"))) (EBlock (DoLet false false PWild (EIf (EApp (EApp (EVar "ffiIsBuiltinExternName") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "n")) (ELit LUnit) (EApp (EApp (EApp (EApp (EVar "ffiCheckExternSig") (EVar "mctx")) (EVar "n")) (EApp (EVar "firstTyLoc") (EVar "ty"))) (EVar "ty")))) (DoExpr (EApp (EApp (EVar "ffiCheckExternsGo") (EVar "mctx")) (EVar "rest")))))
(DFunDef false "ffiCheckExternsGo" ((PVar "mctx") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "ffiCheckExternsGo") (EVar "mctx")) (EVar "rest")))
(DTypeSig false "ffiIsBuiltinExternName" (TyFun (TyCon "GraphCtx") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "ffiIsBuiltinExternName" ((PVar "gctx") (PVar "n")) (EApp (EApp (EVar "omHasKey") (EVar "n")) (EFieldAccess (EFieldAccess (EVar "gctx") "builtinExternNamesRef") "value")))
(DTypeSig true "ffiCheckExternsShadow" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Unit")))))
(DFunDef false "ffiCheckExternsShadow" ((PVar "mctx") (PCon "False") PWild) (ELit LUnit))
(DFunDef false "ffiCheckExternsShadow" ((PVar "mctx") (PCon "True") (PVar "ds")) (EApp (EApp (EVar "ffiCheckShadowGo") (EVar "mctx")) (EApp (EVar "externDecls") (EVar "ds"))))
(DTypeSig false "ffiCheckShadowGo" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Unit"))))
(DFunDef false "ffiCheckShadowGo" ((PVar "mctx") (PList)) (ELit LUnit))
(DFunDef false "ffiCheckShadowGo" ((PVar "mctx") (PCons (PCon "DExtern" (PRec "ExternDecl" ((rf "edName" (PVar "n")) (rf "edTy" (PVar "ty"))) true)) (PVar "rest"))) (EBlock (DoLet false false PWild (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "builtinExternNamesRef") "value")) (arm (PCon "Some" (PTuple (PVar "cat") PWild)) () (EMatch (EApp (EApp (EApp (EVar "ffiSigInstance") (EVar "mctx")) (EVar "cat")) (EVar "ty")) (arm (PCon "Some" PWild) () (ELit LUnit)) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "pushTypeErrorAt") (EVar "mctx")) (ELit (LString "T-FFI-BUILTIN-SHADOW"))) (EApp (EVar "firstTyLoc") (EVar "ty"))) (EApp (EApp (EApp (EVar "ffiShadowMsg") (EVar "n")) (EApp (EVar "ppTy") (EVar "cat"))) (EApp (EVar "ppTy") (EVar "ty"))))))) (arm (PCon "None") () (ELit LUnit)))) (DoExpr (EApp (EApp (EVar "ffiCheckShadowGo") (EVar "mctx")) (EVar "rest")))))
(DFunDef false "ffiCheckShadowGo" ((PVar "mctx") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "ffiCheckShadowGo") (EVar "mctx")) (EVar "rest")))
(DTypeSig false "ffiSigInstance" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Ty") (TyFun (TyCon "Ty") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))))))))
(DFunDef false "ffiSigInstance" ((PVar "mctx") (PVar "cat") (PVar "decl")) (EApp (EApp (EApp (EApp (EVar "ffiMatchSpine") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "aliasTableRef") "value")) (EVar "cat")) (EVar "decl")) (EApp (EVar "Some") (EApp (EApp (EVar "ffiBinderSeed") (EApp (EVar "namedArgOrder") (EVar "cat"))) (EApp (EVar "namedArgOrder") (EVar "decl"))))))
(DTypeSig false "ffiBinderSeed" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))))))
(DFunDef false "ffiBinderSeed" ((PVar "cat") (PVar "decl")) (EBlock (DoLet false false (PVar "byPos") (EApp (EApp (EMethodRef "map") (ELam ((PVar "p")) (ETuple (EApp (EVar "snd") (EVar "p")) (EApp (EVar "fst") (EVar "p"))))) (EVar "decl"))) (DoExpr (EApp (EApp (EMethodRef "map") (ELam ((PVar "p")) (ETuple (EApp (EVar "fst") (EVar "p")) (EApp (EVar "TyVar") (EApp (EApp (EVar "optionOr") (ELit (LString ""))) (EApp (EApp (EVar "lookupAssocI") (EApp (EVar "snd") (EVar "p"))) (EVar "byPos"))))))) (EVar "cat")))))
(DTypeSig false "ffiMatchSpine" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Ty")))) (TyFun (TyCon "Ty") (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty")))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty")))))))))
(DFunDef false "ffiMatchSpine" ((PVar "aliases") (PVar "cat") (PVar "decl") (PVar "acc")) (EMatch (ETuple (EApp (EApp (EVar "ffiSigStrip") (EVar "aliases")) (EVar "cat")) (EApp (EApp (EVar "ffiSigStrip") (EVar "aliases")) (EVar "decl"))) (arm (PTuple (PCon "TyFun" (PVar "a") (PVar "r")) (PCon "TyFun" (PVar "c") (PVar "d"))) () (EApp (EApp (EApp (EApp (EVar "ffiMatchSpine") (EVar "aliases")) (EApp (EVar "ffiRowBody") (EVar "r"))) (EApp (EVar "ffiRowBody") (EVar "d"))) (EApp (EApp (EApp (EApp (EVar "ffiMatchTy") (EVar "aliases")) (EVar "a")) (EVar "c")) (EVar "acc")))) (arm (PTuple (PVar "c") (PVar "d")) () (EApp (EApp (EApp (EApp (EVar "ffiMatchTy") (EVar "aliases")) (EVar "c")) (EVar "d")) (EVar "acc")))))
(DTypeSig false "ffiMatchTy" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Ty")))) (TyFun (TyCon "Ty") (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty")))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty")))))))))
(DFunDef false "ffiMatchTy" (PWild PWild PWild (PCon "None")) (EVar "None"))
(DFunDef false "ffiMatchTy" ((PVar "aliases") (PVar "cat") (PVar "decl") (PCon "Some" (PVar "sub"))) (EMatch (ETuple (EApp (EApp (EVar "ffiSigStrip") (EVar "aliases")) (EVar "cat")) (EApp (EApp (EVar "ffiSigStrip") (EVar "aliases")) (EVar "decl"))) (arm (PTuple (PCon "TyVar" (PVar "v")) (PVar "d")) () (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "v")) (EMethodRef "sub")) (arm (PCon "Some" (PVar "bound")) () (EIf (EApp (EApp (EApp (EVar "ffiSameTy") (EVar "aliases")) (EVar "bound")) (EVar "d")) (EApp (EVar "Some") (EMethodRef "sub")) (EVar "None"))) (arm (PCon "None") () (EApp (EVar "Some") (EBinOp "::" (ETuple (EVar "v") (EVar "d")) (EMethodRef "sub")))))) (arm (PTuple (PCon "TyEffect" (PVar "l1") (PVar "t1") (PVar "a")) (PCon "TyEffect" (PVar "l2") (PVar "t2") (PVar "c"))) () (EApp (EApp (EApp (EApp (EVar "ffiMatchTy") (EVar "aliases")) (EVar "a")) (EVar "c")) (EApp (EApp (EApp (EApp (EApp (EVar "ffiMatchRow") (EVar "l1")) (EVar "t1")) (EVar "l2")) (EVar "t2")) (EApp (EVar "Some") (EMethodRef "sub"))))) (arm (PTuple (PCon "TyEffect" (PVar "l1") (PVar "t1") (PVar "a")) (PVar "c")) () (EApp (EApp (EApp (EApp (EVar "ffiMatchTy") (EVar "aliases")) (EVar "a")) (EVar "c")) (EApp (EApp (EApp (EApp (EApp (EVar "ffiMatchRow") (EVar "l1")) (EVar "t1")) (EListLit)) (EListLit)) (EApp (EVar "Some") (EMethodRef "sub"))))) (arm (PTuple (PVar "a") (PCon "TyEffect" (PVar "l2") (PVar "t2") (PVar "c"))) () (EApp (EApp (EApp (EApp (EVar "ffiMatchTy") (EVar "aliases")) (EVar "a")) (EVar "c")) (EApp (EApp (EApp (EApp (EApp (EVar "ffiMatchRow") (EListLit)) (EListLit)) (EVar "l2")) (EVar "t2")) (EApp (EVar "Some") (EMethodRef "sub"))))) (arm (PTuple (PCon "TyRow" (PVar "l1") (PVar "t1") PWild) (PCon "TyRow" (PVar "l2") (PVar "t2") PWild)) () (EApp (EApp (EApp (EApp (EApp (EVar "ffiMatchRow") (EVar "l1")) (EVar "t1")) (EVar "l2")) (EVar "t2")) (EApp (EVar "Some") (EMethodRef "sub")))) (arm (PTuple (PCon "TyApp" (PVar "a") (PVar "b")) (PCon "TyApp" (PVar "c") (PVar "d"))) () (EApp (EApp (EApp (EApp (EVar "ffiMatchTy") (EVar "aliases")) (EVar "b")) (EVar "d")) (EApp (EApp (EApp (EApp (EVar "ffiMatchTy") (EVar "aliases")) (EVar "a")) (EVar "c")) (EApp (EVar "Some") (EMethodRef "sub"))))) (arm (PTuple (PCon "TyFun" (PVar "a") (PVar "b")) (PCon "TyFun" (PVar "c") (PVar "d"))) () (EApp (EApp (EApp (EApp (EVar "ffiMatchTy") (EVar "aliases")) (EVar "b")) (EVar "d")) (EApp (EApp (EApp (EApp (EVar "ffiMatchTy") (EVar "aliases")) (EVar "a")) (EVar "c")) (EApp (EVar "Some") (EMethodRef "sub"))))) (arm (PTuple (PCon "TyTuple" (PVar "xs")) (PCon "TyTuple" (PVar "ys"))) () (EApp (EApp (EApp (EApp (EVar "ffiMatchTys") (EVar "aliases")) (EVar "xs")) (EVar "ys")) (EApp (EVar "Some") (EMethodRef "sub")))) (arm (PTuple (PCon "TyQual" (PVar "a") PWild PWild) (PCon "TyQual" (PVar "c") PWild PWild)) () (EApp (EApp (EApp (EApp (EVar "ffiMatchTy") (EVar "aliases")) (EVar "a")) (EVar "c")) (EApp (EVar "Some") (EMethodRef "sub")))) (arm (PTuple (PVar "c") (PVar "d")) () (EIf (EApp (EApp (EApp (EVar "ffiSameTy") (EVar "aliases")) (EVar "c")) (EVar "d")) (EApp (EVar "Some") (EMethodRef "sub")) (EVar "None")))))
(DTypeSig false "ffiMatchTys" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Ty")))) (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty")))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty")))))))))
(DFunDef false "ffiMatchTys" (PWild (PList) (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "ffiMatchTys" ((PVar "aliases") (PCons (PVar "c") (PVar "cs")) (PCons (PVar "d") (PVar "ds")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "ffiMatchTys") (EVar "aliases")) (EVar "cs")) (EVar "ds")) (EApp (EApp (EApp (EApp (EVar "ffiMatchTy") (EVar "aliases")) (EVar "c")) (EVar "d")) (EVar "acc"))))
(DFunDef false "ffiMatchTys" (PWild PWild PWild PWild) (EVar "None"))
(DTypeSig false "ffiMatchRow" (TyFun (TyApp (TyCon "List") (TyCon "EffAtomTy")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "EffAtomTy")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty")))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))))))))))
(DFunDef false "ffiMatchRow" (PWild PWild PWild PWild (PCon "None")) (EVar "None"))
(DFunDef false "ffiMatchRow" ((PVar "l1") (PVar "t1") (PVar "l2") (PVar "t2") (PCon "Some" (PVar "sub"))) (EMatch (EApp (EApp (EApp (EVar "ffiMatchAtoms") (EVar "l1")) (EVar "l2")) (EMethodRef "sub")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PTuple (PVar "sub2") (PVar "rest"))) () (EMatch (EVar "t1") (arm (PList) () (EMatch (ETuple (EVar "rest") (EVar "t2")) (arm (PTuple (PList) (PList)) () (EApp (EVar "Some") (EVar "sub2"))) (arm PWild () (EVar "None")))) (arm (PList (PVar "v")) () (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "v")) (EVar "sub2")) (arm (PCon "Some" (PCon "TyRow" (PVar "bl") (PVar "bt") PWild)) () (EIf (EApp (EApp (EApp (EApp (EVar "ffiSameRow") (EVar "bl")) (EVar "bt")) (EVar "rest")) (EVar "t2")) (EApp (EVar "Some") (EVar "sub2")) (EVar "None"))) (arm (PCon "Some" PWild) () (EVar "None")) (arm (PCon "None") () (EApp (EVar "Some") (EBinOp "::" (ETuple (EVar "v") (EApp (EApp (EApp (EVar "TyRow") (EVar "rest")) (EVar "t2")) (EVar "None"))) (EVar "sub2")))))) (arm PWild () (EMatch (EVar "rest") (arm (PList) () (EIf (EApp (EApp (EVar "ffiSameNames") (EVar "t1")) (EVar "t2")) (EApp (EVar "Some") (EVar "sub2")) (EVar "None"))) (arm PWild () (EVar "None"))))))))
(DTypeSig false "ffiMatchAtoms" (TyFun (TyApp (TyCon "List") (TyCon "EffAtomTy")) (TyFun (TyApp (TyCon "List") (TyCon "EffAtomTy")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyApp (TyCon "List") (TyCon "EffAtomTy"))))))))
(DFunDef false "ffiMatchAtoms" ((PList) (PVar "rest") (PVar "sub")) (EApp (EVar "Some") (ETuple (EMethodRef "sub") (EVar "rest"))))
(DFunDef false "ffiMatchAtoms" ((PCons (PVar "a") (PVar "more")) (PVar "ds") (PVar "sub")) (EMatch (EApp (EApp (EApp (EApp (EVar "ffiTakeAtom") (EVar "a")) (EVar "ds")) (EListLit)) (EMethodRef "sub")) (arm (PCon "Some" (PTuple (PVar "sub2") (PVar "ds2"))) () (EApp (EApp (EApp (EVar "ffiMatchAtoms") (EVar "more")) (EVar "ds2")) (EVar "sub2"))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "ffiTakeAtom" (TyFun (TyCon "EffAtomTy") (TyFun (TyApp (TyCon "List") (TyCon "EffAtomTy")) (TyFun (TyApp (TyCon "List") (TyCon "EffAtomTy")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyApp (TyCon "List") (TyCon "EffAtomTy")))))))))
(DFunDef false "ffiTakeAtom" (PWild (PList) PWild PWild) (EVar "None"))
(DFunDef false "ffiTakeAtom" ((PVar "a") (PCons (PVar "d") (PVar "ds")) (PVar "skipped") (PVar "sub")) (EMatch (EApp (EApp (EApp (EVar "ffiMatchAtom") (EVar "a")) (EVar "d")) (EMethodRef "sub")) (arm (PCon "Some" (PVar "sub2")) () (EApp (EVar "Some") (ETuple (EVar "sub2") (EBinOp "++" (EApp (EVar "reverseL") (EVar "skipped")) (EVar "ds"))))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "ffiTakeAtom") (EVar "a")) (EVar "ds")) (EBinOp "::" (EVar "d") (EVar "skipped"))) (EMethodRef "sub")))))
(DTypeSig false "ffiMatchAtom" (TyFun (TyCon "EffAtomTy") (TyFun (TyCon "EffAtomTy") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))))))))
(DFunDef false "ffiMatchAtom" ((PVar "a") (PVar "d") (PVar "sub")) (EIf (EApp (EApp (EApp (EApp (EVar "sameTyConHead") (EFieldAccess (EVar "a") "eatLabel")) (EFieldAccess (EVar "a") "eatOrigin")) (EFieldAccess (EVar "d") "eatLabel")) (EFieldAccess (EVar "d") "eatOrigin")) (EMatch (EFieldAccess (EVar "a") "eatParam") (arm (PCon "EPName" (PVar "v")) () (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "v")) (EMethodRef "sub")) (arm (PCon "Some" (PVar "bound")) () (EMatch (EApp (EVar "ffiParamOf") (EVar "bound")) (arm (PCon "Some" (PVar "p")) () (EIf (EApp (EApp (EVar "ffiSameParam") (EVar "p")) (EFieldAccess (EVar "d") "eatParam")) (EApp (EVar "Some") (EMethodRef "sub")) (EVar "None"))) (arm (PCon "None") () (EVar "None")))) (arm (PCon "None") () (EApp (EVar "Some") (EBinOp "::" (ETuple (EVar "v") (EApp (EVar "ffiParamTy") (EFieldAccess (EVar "d") "eatParam"))) (EMethodRef "sub")))))) (arm (PVar "p") () (EIf (EApp (EApp (EVar "ffiSameParam") (EVar "p")) (EFieldAccess (EVar "d") "eatParam")) (EApp (EVar "Some") (EMethodRef "sub")) (EVar "None")))) (EVar "None")))
(DTypeSig false "ffiParamTy" (TyFun (TyCon "EffParamTy") (TyCon "Ty")))
(DFunDef false "ffiParamTy" ((PCon "EPName" (PVar "n"))) (EApp (EVar "TyVar") (EVar "n")))
(DFunDef false "ffiParamTy" ((PVar "p")) (EApp (EApp (EVar "TyAuth") (EListLit (EVar "p"))) (EVar "None")))
(DTypeSig false "ffiParamOf" (TyFun (TyCon "Ty") (TyApp (TyCon "Option") (TyCon "EffParamTy"))))
(DFunDef false "ffiParamOf" ((PCon "TyAuth" (PList (PVar "p")) PWild)) (EApp (EVar "Some") (EVar "p")))
(DFunDef false "ffiParamOf" ((PCon "TyVar" (PVar "m"))) (EApp (EVar "Some") (EApp (EVar "EPName") (EVar "m"))))
(DFunDef false "ffiParamOf" (PWild) (EVar "None"))
(DTypeSig false "ffiSameParam" (TyFun (TyCon "EffParamTy") (TyFun (TyCon "EffParamTy") (TyCon "Bool"))))
(DFunDef false "ffiSameParam" ((PVar "p") (PVar "q")) (EBinOp "==" (EApp (EVar "ppTy") (EApp (EApp (EVar "TyAuth") (EListLit (EVar "p"))) (EVar "None"))) (EApp (EVar "ppTy") (EApp (EApp (EVar "TyAuth") (EListLit (EVar "q"))) (EVar "None")))))
(DTypeSig false "ffiSameRow" (TyFun (TyApp (TyCon "List") (TyCon "EffAtomTy")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "EffAtomTy")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))))
(DFunDef false "ffiSameRow" ((PVar "l1") (PVar "t1") (PVar "l2") (PVar "t2")) (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "ffiAtomsWithin") (EVar "l1")) (EVar "l2")) (EApp (EApp (EVar "ffiAtomsWithin") (EVar "l2")) (EVar "l1"))) (EApp (EApp (EVar "ffiSameNames") (EVar "t1")) (EVar "t2"))))
(DTypeSig false "ffiAtomsWithin" (TyFun (TyApp (TyCon "List") (TyCon "EffAtomTy")) (TyFun (TyApp (TyCon "List") (TyCon "EffAtomTy")) (TyCon "Bool"))))
(DFunDef false "ffiAtomsWithin" ((PVar "xs") (PVar "ys")) (EApp (EApp (EVar "allList") (ELam ((PVar "a")) (EApp (EApp (EVar "anyList") (ELam ((PVar "b")) (EApp (EApp (EVar "ffiSameAtom") (EVar "a")) (EVar "b")))) (EVar "ys")))) (EVar "xs")))
(DTypeSig false "ffiSameAtom" (TyFun (TyCon "EffAtomTy") (TyFun (TyCon "EffAtomTy") (TyCon "Bool"))))
(DFunDef false "ffiSameAtom" ((PVar "a") (PVar "b")) (EBinOp "&&" (EApp (EApp (EApp (EApp (EVar "sameTyConHead") (EFieldAccess (EVar "a") "eatLabel")) (EFieldAccess (EVar "a") "eatOrigin")) (EFieldAccess (EVar "b") "eatLabel")) (EFieldAccess (EVar "b") "eatOrigin")) (EApp (EApp (EVar "ffiSameParam") (EFieldAccess (EVar "a") "eatParam")) (EFieldAccess (EVar "b") "eatParam"))))
(DTypeSig false "ffiSameNames" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "ffiSameNames" ((PVar "xs") (PVar "ys")) (EBinOp "&&" (EApp (EApp (EVar "allList") (ELam ((PVar "x")) (EApp (EApp (EVar "contains") (EVar "x")) (EVar "ys")))) (EVar "xs")) (EApp (EApp (EVar "allList") (ELam ((PVar "y")) (EApp (EApp (EVar "contains") (EVar "y")) (EVar "xs")))) (EVar "ys"))))
(DTypeSig false "ffiSameTy" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Ty")))) (TyFun (TyCon "Ty") (TyFun (TyCon "Ty") (TyCon "Bool")))))
(DFunDef false "ffiSameTy" ((PVar "aliases") (PVar "a") (PVar "b")) (EMatch (ETuple (EApp (EApp (EVar "ffiSigStrip") (EVar "aliases")) (EVar "a")) (EApp (EApp (EVar "ffiSigStrip") (EVar "aliases")) (EVar "b"))) (arm (PTuple (PCon "TyEffect" (PVar "l1") (PVar "t1") (PVar "x")) (PVar "y")) () (EMatch (EApp (EVar "ffiRowParts") (EVar "y")) (arm (PTuple (PVar "l2") (PVar "t2") (PVar "y2")) () (EBinOp "&&" (EApp (EApp (EApp (EApp (EVar "ffiSameRow") (EVar "l1")) (EVar "t1")) (EVar "l2")) (EVar "t2")) (EApp (EApp (EApp (EVar "ffiSameTy") (EVar "aliases")) (EVar "x")) (EVar "y2")))))) (arm (PTuple (PVar "x") (PCon "TyEffect" (PVar "l2") (PVar "t2") (PVar "y"))) () (EBinOp "&&" (EApp (EApp (EApp (EApp (EVar "ffiSameRow") (EListLit)) (EListLit)) (EVar "l2")) (EVar "t2")) (EApp (EApp (EApp (EVar "ffiSameTy") (EVar "aliases")) (EVar "x")) (EVar "y")))) (arm (PTuple (PRec "TyCon" ((rf "tyConName" (PVar "n1")) (rf "tyConOrigin" (PVar "o1"))) false) (PRec "TyCon" ((rf "tyConName" (PVar "n2")) (rf "tyConOrigin" (PVar "o2"))) false)) () (EApp (EApp (EApp (EApp (EVar "sameTyConHead") (EVar "n1")) (EVar "o1")) (EVar "n2")) (EVar "o2"))) (arm (PTuple (PCon "TyVar" (PVar "x")) (PCon "TyVar" (PVar "y"))) () (EBinOp "==" (EVar "x") (EVar "y"))) (arm (PTuple (PCon "TyApp" (PVar "a1") (PVar "b1")) (PCon "TyApp" (PVar "a2") (PVar "b2"))) () (EBinOp "&&" (EApp (EApp (EApp (EVar "ffiSameTy") (EVar "aliases")) (EVar "a1")) (EVar "a2")) (EApp (EApp (EApp (EVar "ffiSameTy") (EVar "aliases")) (EVar "b1")) (EVar "b2")))) (arm (PTuple (PCon "TyFun" (PVar "a1") (PVar "b1")) (PCon "TyFun" (PVar "a2") (PVar "b2"))) () (EBinOp "&&" (EApp (EApp (EApp (EVar "ffiSameTy") (EVar "aliases")) (EVar "a1")) (EVar "a2")) (EApp (EApp (EApp (EVar "ffiSameTy") (EVar "aliases")) (EVar "b1")) (EVar "b2")))) (arm (PTuple (PCon "TyTuple" (PVar "xs")) (PCon "TyTuple" (PVar "ys"))) () (EBinOp "&&" (EBinOp "==" (EApp (EVar "listLen") (EVar "xs")) (EApp (EVar "listLen") (EVar "ys"))) (EApp (EApp (EVar "allList") (ELam ((PVar "p")) (EApp (EApp (EApp (EVar "ffiSameTy") (EVar "aliases")) (EApp (EVar "fst") (EVar "p"))) (EApp (EVar "snd") (EVar "p"))))) (EApp (EApp (EVar "zipL") (EVar "xs")) (EVar "ys"))))) (arm (PTuple (PCon "TyQual" (PVar "x") PWild PWild) (PCon "TyQual" (PVar "y") PWild PWild)) () (EApp (EApp (EApp (EVar "ffiSameTy") (EVar "aliases")) (EVar "x")) (EVar "y"))) (arm (PTuple (PCon "TyAuth" (PVar "ps") PWild) (PCon "TyAuth" (PVar "qs") PWild)) () (EBinOp "==" (EApp (EVar "ppTy") (EApp (EApp (EVar "TyAuth") (EVar "ps")) (EVar "None"))) (EApp (EVar "ppTy") (EApp (EApp (EVar "TyAuth") (EVar "qs")) (EVar "None"))))) (arm (PTuple (PCon "TyRow" (PVar "l1") (PVar "t1") PWild) (PCon "TyRow" (PVar "l2") (PVar "t2") PWild)) () (EApp (EApp (EApp (EApp (EVar "ffiSameRow") (EVar "l1")) (EVar "t1")) (EVar "l2")) (EVar "t2"))) (arm PWild () (EVar "False"))))
(DTypeSig false "ffiRowParts" (TyFun (TyCon "Ty") (TyTuple (TyApp (TyCon "List") (TyCon "EffAtomTy")) (TyApp (TyCon "List") (TyCon "String")) (TyCon "Ty"))))
(DFunDef false "ffiRowParts" ((PCon "TyEffect" (PVar "l") (PVar "t") (PVar "inner"))) (ETuple (EVar "l") (EVar "t") (EVar "inner")))
(DFunDef false "ffiRowParts" ((PVar "t")) (ETuple (EListLit) (EListLit) (EVar "t")))
(DTypeSig false "ffiRowBody" (TyFun (TyCon "Ty") (TyCon "Ty")))
(DFunDef false "ffiRowBody" ((PVar "t")) (EMatch (EApp (EVar "ffiRowParts") (EVar "t")) (arm (PTuple PWild PWild (PVar "inner")) () (EVar "inner"))))
(DTypeSig false "ffiSigStrip" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Ty")))) (TyFun (TyCon "Ty") (TyCon "Ty"))))
(DFunDef false "ffiSigStrip" ((PVar "aliases") (PVar "t")) (EMatch (EApp (EApp (EVar "expandAliasHeadTyWith") (EVar "aliases")) (EVar "t")) (arm (PCon "TyConstrained" PWild (PVar "inner")) () (EApp (EApp (EVar "ffiSigStrip") (EVar "aliases")) (EVar "inner"))) (arm (PCon "TyNamed" PWild (PVar "inner") PWild) () (EApp (EApp (EVar "ffiSigStrip") (EVar "aliases")) (EVar "inner"))) (arm (PVar "u") () (EVar "u"))))
(DTypeSig false "ffiSpineRows" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Ty")))) (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "EffAtomTy")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "ffiSpineRows" ((PVar "aliases") (PVar "t")) (EMatch (EApp (EApp (EVar "ffiSigStrip") (EVar "aliases")) (EVar "t")) (arm (PCon "TyFun" PWild (PVar "r")) () (EMatch (EApp (EVar "ffiRowParts") (EVar "r")) (arm (PTuple (PVar "l") (PVar "tl") (PVar "inner")) () (EBinOp "::" (ETuple (EVar "l") (EVar "tl")) (EApp (EApp (EVar "ffiSpineRows") (EVar "aliases")) (EVar "inner")))))) (arm PWild () (EListLit))))
(DTypeSig false "ffiInstRow" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyFun (TyApp (TyCon "List") (TyCon "EffAtomTy")) (TyApp (TyCon "List") (TyCon "EffAtomTy"))))))
(DFunDef false "ffiInstRow" ((PVar "names") (PVar "sub") (PVar "ls")) (EBlock (DoLet false false (PVar "free") (EApp (EApp (EVar "filterList") (ELam ((PVar "p")) (EApp (EVar "isNone") (EApp (EApp (EVar "lookupAssoc") (EApp (EVar "fst") (EVar "p"))) (EVar "names"))))) (EMethodRef "sub"))) (DoExpr (EApp (EApp (EDictApp "flatMap") (EApp (EVar "ffiInstAtom") (EVar "free"))) (EVar "ls")))))
(DTypeSig false "ffiInstAtom" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyFun (TyCon "EffAtomTy") (TyApp (TyCon "List") (TyCon "EffAtomTy")))))
(DFunDef false "ffiInstAtom" ((PVar "sub") (PVar "a")) (EMatch (EFieldAccess (EVar "a") "eatParam") (arm (PCon "EPName" (PVar "n")) () (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "n")) (EMethodRef "sub")) (arm (PCon "Some" (PCon "TyAuth" (PVar "ps") PWild)) () (EApp (EApp (EMethodRef "map") (ELam ((PVar "p")) (ERecordUpdate (EVar "a") ((fa "eatParam" (EVar "p")))))) (EVar "ps"))) (arm (PCon "Some" (PCon "TyVar" (PVar "m"))) () (EListLit (ERecordUpdate (EVar "a") ((fa "eatParam" (EApp (EVar "EPName") (EVar "m"))))))) (arm PWild () (EListLit (EVar "a"))))) (arm PWild () (EListLit (EVar "a")))))
(DTypeSig true "ffiCheckExternsCatalogRow" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Unit")))))
(DFunDef false "ffiCheckExternsCatalogRow" ((PVar "mctx") (PCon "False") PWild) (ELit LUnit))
(DFunDef false "ffiCheckExternsCatalogRow" ((PVar "mctx") (PCon "True") (PVar "ds")) (EApp (EApp (EVar "ffiCheckCatalogRowGo") (EVar "mctx")) (EApp (EVar "externDecls") (EVar "ds"))))
(DTypeSig false "ffiCheckCatalogRowGo" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Unit"))))
(DFunDef false "ffiCheckCatalogRowGo" ((PVar "mctx") (PList)) (ELit LUnit))
(DFunDef false "ffiCheckCatalogRowGo" ((PVar "mctx") (PCons (PCon "DExtern" (PRec "ExternDecl" ((rf "edName" (PVar "n")) (rf "edTy" (PVar "ty"))) true)) (PVar "rest"))) (EBlock (DoLet false false PWild (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcGraph") "builtinExternNamesRef") "value")) (arm (PCon "Some" (PTuple (PVar "cat") (PVar "catNames"))) () (EMatch (EApp (EApp (EApp (EVar "ffiSigInstance") (EVar "mctx")) (EVar "cat")) (EVar "ty")) (arm (PCon "Some" (PVar "sub")) () (EBlock (DoLet false false (PVar "aliases") (EFieldAccess (EFieldAccess (EFieldAccess (EVar "mctx") "mcCells") "aliasTableRef") "value")) (DoLet false false (PVar "pairs") (EApp (EApp (EVar "zipL") (EApp (EApp (EVar "ffiSpineRows") (EVar "aliases")) (EVar "cat"))) (EApp (EApp (EVar "ffiSpineRows") (EVar "aliases")) (EVar "ty")))) (DoLet false false (PVar "arrows") (EApp (EVar "listLen") (EVar "pairs"))) (DoExpr (EApp (EApp (EApp (EMethodRef "fold") (ELam (PWild (PVar "ip")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "ffiCheckSpineRow") (EVar "mctx")) (EVar "n")) (EVar "ty")) (EVar "catNames")) (EMethodRef "sub")) (EApp (EApp (EVar "ffiArrowNote") (EApp (EVar "fst") (EVar "ip"))) (EVar "arrows"))) (EApp (EVar "fst") (EApp (EVar "snd") (EVar "ip")))) (EApp (EVar "snd") (EApp (EVar "snd") (EVar "ip")))))) (ELit LUnit)) (EApp (EApp (EVar "zipL") (EApp (EApp (EVar "rangeFromCount") (ELit (LInt 1))) (EVar "arrows"))) (EVar "pairs")))))) (arm (PCon "None") () (ELit LUnit)))) (arm (PCon "None") () (ELit LUnit)))) (DoExpr (EApp (EApp (EVar "ffiCheckCatalogRowGo") (EVar "mctx")) (EVar "rest")))))
(DFunDef false "ffiCheckCatalogRowGo" ((PVar "mctx") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "ffiCheckCatalogRowGo") (EVar "mctx")) (EVar "rest")))
(DTypeSig false "ffiCheckSpineRow" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyFun (TyCon "String") (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "EffAtomTy")) (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "EffAtomTy")) (TyApp (TyCon "List") (TyCon "String"))) (TyCon "Unit"))))))))))
(DFunDef false "ffiCheckSpineRow" ((PVar "mctx") (PVar "n") (PVar "ty") (PVar "catNames") (PVar "sub") (PVar "arrow") (PVar "cat") (PVar "decl")) (EBlock (DoLet false false (PVar "tails") (EApp (EApp (EVar "ffiExpandTails") (EMethodRef "sub")) (EApp (EVar "snd") (EVar "cat")))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "ffiCheckCatalogRowOne") (EVar "mctx")) (EVar "n")) (EVar "ty")) (EVar "arrow")) (EBinOp "++" (EApp (EApp (EApp (EVar "ffiInstRow") (EVar "catNames")) (EMethodRef "sub")) (EApp (EVar "fst") (EVar "cat"))) (EApp (EVar "fst") (EVar "tails")))) (EVar "catNames")) (EApp (EVar "fst") (EVar "decl")))) (DoExpr (EMatch (EApp (EApp (EVar "filterList") (ELam ((PVar "v")) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EVar "v")) (EApp (EVar "snd") (EVar "decl")))))) (EApp (EVar "snd") (EVar "tails"))) (arm (PList) () (ELit LUnit)) (arm (PVar "missing") () (EApp (EApp (EApp (EApp (EVar "pushTypeErrorAt") (EVar "mctx")) (ELit (LString "T-FFI-CATALOG-NARROW"))) (EApp (EVar "firstTyLoc") (EVar "ty"))) (EApp (EApp (EApp (EVar "ffiCatalogTailMsg") (EVar "n")) (EVar "arrow")) (EVar "missing"))))))))
(DTypeSig false "ffiExpandTails" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Ty"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyTuple (TyApp (TyCon "List") (TyCon "EffAtomTy")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "ffiExpandTails" (PWild (PList)) (ETuple (EListLit) (EListLit)))
(DFunDef false "ffiExpandTails" ((PVar "sub") (PCons (PVar "v") (PVar "vs"))) (EBlock (DoLet false false (PVar "rest") (EApp (EApp (EVar "ffiExpandTails") (EMethodRef "sub")) (EVar "vs"))) (DoExpr (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "v")) (EMethodRef "sub")) (arm (PCon "Some" (PCon "TyRow" (PVar "bl") (PVar "bt") PWild)) () (ETuple (EBinOp "++" (EVar "bl") (EApp (EVar "fst") (EVar "rest"))) (EBinOp "++" (EVar "bt") (EApp (EVar "snd") (EVar "rest"))))) (arm PWild () (ETuple (EApp (EVar "fst") (EVar "rest")) (EBinOp "::" (EVar "v") (EApp (EVar "snd") (EVar "rest")))))))))
(DTypeSig false "ffiCheckCatalogRowOne" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyCon "Ty") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "EffAtomTy")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyCon "EffAtomTy")) (TyCon "Unit")))))))))
(DFunDef false "ffiCheckCatalogRowOne" ((PVar "mctx") (PVar "n") (PVar "ty") (PVar "arrow") (PVar "catRow") (PVar "catNames") (PVar "declRow")) (EBlock (DoLet false false (PVar "declNames") (EApp (EVar "namedArgOrder") (EVar "ty"))) (DoLet false false (PVar "cells") (EApp (EApp (EVar "positionCells") (EVar "mctx")) (EBinOp "++" (EVar "catNames") (EVar "declNames")))) (DoLet false false (PVar "free") (EApp (EApp (EMethodRef "map") (ELam ((PVar "x")) (ETuple (EVar "x") (EApp (EApp (EApp (EVar "freshAuthvar") (EVar "mctx")) (EVar "PUnit")) (EApp (EVar "Some") (EVar "x")))))) (EApp (EApp (EVar "freeAuthorityNames") (EApp (EApp (EMethodRef "map") (EVar "fst")) (EBinOp "++" (EVar "catNames") (EVar "declNames")))) (EBinOp "++" (EVar "catRow") (EVar "declRow"))))) (DoLet false false (PVar "catAtoms") (EApp (EApp (EApp (EVar "atomsOfWrittenIn") (EFieldAccess (EVar "mctx") "mcGraph")) (EApp (EApp (EVar "withFreeAuths") (EVar "free")) (EApp (EApp (EVar "positionalSigVars") (EVar "catNames")) (EVar "cells")))) (EVar "catRow"))) (DoLet false false (PVar "declAtoms") (EApp (EApp (EApp (EVar "atomsOfWrittenIn") (EFieldAccess (EVar "mctx") "mcGraph")) (EApp (EApp (EVar "withFreeAuths") (EVar "free")) (EApp (EApp (EVar "positionalSigVars") (EVar "declNames")) (EVar "cells")))) (EVar "declRow"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "atomsEscape") (EFieldAccess (EVar "mctx") "mcGraph")) (EVar "catAtoms")) (EVar "declAtoms")) (arm (PList) () (ELit LUnit)) (arm (PVar "missing") () (EApp (EApp (EApp (EApp (EVar "pushTypeErrorAt") (EVar "mctx")) (ELit (LString "T-FFI-CATALOG-NARROW"))) (EApp (EVar "firstTyLoc") (EVar "ty"))) (EApp (EApp (EApp (EApp (EApp (EVar "ffiCatalogNarrowMsg") (EVar "n")) (EVar "arrow")) (EVar "catAtoms")) (EVar "declAtoms")) (EVar "missing"))))))))
(DTypeSig false "positionCells" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyApp (TyCon "Ref") (TyCon "Authvar")))))))
(DFunDef false "positionCells" ((PVar "mctx") (PList)) (EListLit))
(DFunDef false "positionCells" ((PVar "mctx") (PCons (PTuple (PVar "binder") (PVar "pos")) (PVar "rest"))) (EBlock (DoLet false false (PVar "others") (EApp (EApp (EVar "positionCells") (EVar "mctx")) (EVar "rest"))) (DoExpr (EIf (EApp (EVar "isSome") (EApp (EApp (EVar "lookupAssocI") (EVar "pos")) (EVar "others"))) (EVar "others") (EBinOp "::" (ETuple (EVar "pos") (EApp (EApp (EApp (EVar "freshAuthvar") (EVar "mctx")) (EVar "PUnit")) (EApp (EVar "Some") (EVar "binder")))) (EVar "others"))))))
(DTypeSig false "freeAuthorityNames" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "EffAtomTy")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "freeAuthorityNames" ((PVar "bound") (PVar "ls")) (EApp (EVar "sortUniqS") (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "a")) (EApp (EApp (EVar "filterList") (ELam ((PVar "x")) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EVar "x")) (EVar "bound"))))) (EApp (EVar "effParamNames") (EFieldAccess (EVar "a") "eatParam"))))) (EVar "ls"))))
(DTypeSig false "withFreeAuths" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Ref") (TyCon "Authvar")))) (TyFun (TyCon "SigVars") (TyCon "SigVars"))))
(DFunDef false "withFreeAuths" ((PVar "free") (PVar "sv")) (ERecordUpdate (EVar "sv") ((fa "svAuths" (EBinOp "++" (EFieldAccess (EVar "sv") "svAuths") (EVar "free"))))))
(DTypeSig false "positionalSigVars" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyApp (TyCon "Ref") (TyCon "Authvar")))) (TyCon "SigVars"))))
(DFunDef false "positionalSigVars" ((PVar "names") (PVar "cells")) (ERecordCreate "SigVars" ((fa "svRows" (EListLit)) (fa "svAuths" (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "p")) (EMatch (EApp (EApp (EVar "lookupAssocI") (EApp (EVar "snd") (EVar "p"))) (EVar "cells")) (arm (PCon "Some" (PVar "cell")) () (EListLit (ETuple (EApp (EVar "fst") (EVar "p")) (EVar "cell")))) (arm (PCon "None") () (EListLit))))) (EVar "names"))))))
(DTypeSig false "ffiSigArgHeadsWith" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Ty")))) (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "ffiSigArgHeadsWith" ((PVar "aliases") (PVar "ty")) (EMatch (EApp (EApp (EVar "expandAliasHeadTyWith") (EVar "aliases")) (EVar "ty")) (arm (PCon "TyConstrained" PWild (PVar "inner")) () (EApp (EApp (EVar "ffiSigArgHeadsWith") (EVar "aliases")) (EVar "inner"))) (arm (PCon "TyEffect" PWild PWild (PVar "inner")) () (EApp (EApp (EVar "ffiSigArgHeadsWith") (EVar "aliases")) (EVar "inner"))) (arm (PCon "TyFun" (PVar "a") (PVar "r")) () (EBinOp "::" (EApp (EApp (EVar "ffiTyHeadNameWith") (EVar "aliases")) (EVar "a")) (EApp (EApp (EVar "ffiSigArgHeadsWith") (EVar "aliases")) (EVar "r")))) (arm PWild () (EListLit))))
(DTypeSig false "ffiSigRetHeadWith" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Ty")))) (TyFun (TyCon "Ty") (TyCon "String"))))
(DFunDef false "ffiSigRetHeadWith" ((PVar "aliases") (PVar "ty")) (EMatch (EApp (EApp (EVar "expandAliasHeadTyWith") (EVar "aliases")) (EVar "ty")) (arm (PCon "TyConstrained" PWild (PVar "inner")) () (EApp (EApp (EVar "ffiSigRetHeadWith") (EVar "aliases")) (EVar "inner"))) (arm (PCon "TyEffect" PWild PWild (PVar "inner")) () (EApp (EApp (EVar "ffiSigRetHeadWith") (EVar "aliases")) (EVar "inner"))) (arm (PCon "TyFun" PWild (PVar "r")) () (EApp (EApp (EVar "ffiSigRetHeadWith") (EVar "aliases")) (EVar "r"))) (arm (PVar "t") () (EApp (EApp (EVar "ffiTyHeadNameWith") (EVar "aliases")) (EVar "t")))))
(DTypeSig false "ffiTyHeadNameWith" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Ty")))) (TyFun (TyCon "Ty") (TyCon "String"))))
(DFunDef false "ffiTyHeadNameWith" ((PVar "aliases") (PVar "ty")) (EMatch (EApp (EApp (EVar "expandAliasHeadTyWith") (EVar "aliases")) (EVar "ty")) (arm (PRec "TyCon" ((rf "tyConName" (PVar "n"))) false) () (EVar "n")) (arm (PCon "TyApp" (PVar "a") PWild) () (EApp (EApp (EVar "ffiTyHeadNameWith") (EVar "aliases")) (EVar "a"))) (arm (PCon "TyVar" PWild) () (ELit (LString "_"))) (arm (PCon "TyConstrained" PWild (PVar "t")) () (EApp (EApp (EVar "ffiTyHeadNameWith") (EVar "aliases")) (EVar "t"))) (arm (PCon "TyEffect" PWild PWild (PVar "t")) () (EApp (EApp (EVar "ffiTyHeadNameWith") (EVar "aliases")) (EVar "t"))) (arm (PCon "TyNamed" PWild (PVar "t") PWild) () (EApp (EApp (EVar "ffiTyHeadNameWith") (EVar "aliases")) (EVar "t"))) (arm (PCon "TyQual" (PVar "t") PWild PWild) () (EApp (EApp (EVar "ffiTyHeadNameWith") (EVar "aliases")) (EVar "t"))) (arm (PCon "TyFun" PWild PWild) () (ELit (LString "->"))) (arm PWild () (ELit (LString "?")))))
(DTypeSig true "ffiExternTypeRowsWith" (TyFun (TyApp (TyCon "OrdMap") (TyTuple (TyCon "Ty") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "TabKey") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Ty")))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))))))))
(DFunDef false "ffiExternTypeRowsWith" (PWild PWild (PList)) (EListLit))
(DFunDef false "ffiExternTypeRowsWith" ((PVar "catalog") (PVar "aliases") (PCons (PCon "DExtern" (PVar "d")) (PVar "rest"))) (EApp (EApp (EApp (EApp (EVar "externRowCons") (EApp (EApp (EVar "omHasKey") (EFieldAccess (EVar "d") "edName")) (EVar "catalog"))) (EVar "d")) (ETuple (EApp (EApp (EVar "ffiSigArgHeadsWith") (EVar "aliases")) (EFieldAccess (EVar "d") "edTy")) (EApp (EApp (EVar "ffiSigRetHeadWith") (EVar "aliases")) (EFieldAccess (EVar "d") "edTy")))) (EApp (EApp (EApp (EVar "ffiExternTypeRowsWith") (EVar "catalog")) (EVar "aliases")) (EVar "rest"))))
(DFunDef false "ffiExternTypeRowsWith" ((PVar "catalog") (PVar "aliases") (PCons (PCon "DAttrib" PWild (PVar "inner")) (PVar "rest"))) (EApp (EApp (EApp (EVar "ffiExternTypeRowsWith") (EVar "catalog")) (EVar "aliases")) (EBinOp "::" (EVar "inner") (EVar "rest"))))
(DFunDef false "ffiExternTypeRowsWith" ((PVar "catalog") (PVar "aliases") (PCons PWild (PVar "rest"))) (EApp (EApp (EApp (EVar "ffiExternTypeRowsWith") (EVar "catalog")) (EVar "aliases")) (EVar "rest")))
(DTypeSig false "ffiCheckExternSig" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Ty") (TyCon "Unit"))))))
(DFunDef false "ffiCheckExternSig" ((PVar "mctx") (PVar "n") (PVar "fb") (PVar "ty")) (EMatch (EApp (EApp (EVar "expandAliasHeadTy") (EVar "mctx")) (EVar "ty")) (arm (PCon "TyConstrained" PWild (PVar "inner")) () (EApp (EApp (EApp (EApp (EVar "ffiCheckExternSig") (EVar "mctx")) (EVar "n")) (EVar "fb")) (EVar "inner"))) (arm (PCon "TyFun" (PVar "a") (PVar "r")) () (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "ffiCheckExternPos") (EVar "mctx")) (EVar "n")) (EVar "fb")) (EVar "a"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "ffiCheckExternSig") (EVar "mctx")) (EVar "n")) (EVar "fb")) (EVar "r"))))) (arm (PCon "TyEffect" PWild PWild (PVar "inner")) () (EApp (EApp (EApp (EApp (EVar "ffiCheckExternSig") (EVar "mctx")) (EVar "n")) (EVar "fb")) (EVar "inner"))) (arm (PVar "t") () (EApp (EApp (EApp (EApp (EVar "ffiCheckExternPos") (EVar "mctx")) (EVar "n")) (EVar "fb")) (EVar "t")))))
(DTypeSig false "ffiCheckExternPos" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Ty") (TyCon "Unit"))))))
(DFunDef false "ffiCheckExternPos" ((PVar "mctx") (PVar "n") (PVar "fb") (PVar "t")) (EIf (EApp (EApp (EVar "ffiCrossableTy") (EVar "mctx")) (EVar "t")) (ELit LUnit) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "pushTypeErrorAt") (EVar "mctx")) (ELit (LString "T-FFI-NONCROSSABLE"))) (EApp (EApp (EVar "orElseLoc") (EApp (EVar "firstTyLoc") (EVar "t"))) (EVar "fb"))) (EApp (EApp (EVar "ffiNonCrossableMsg") (EVar "n")) (EVar "t"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "ffiCheckExternsLabelled" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Unit")))))
(DFunDef false "ffiCheckExternsLabelled" ((PVar "mctx") (PCon "False") PWild) (ELit LUnit))
(DFunDef false "ffiCheckExternsLabelled" ((PVar "mctx") (PCon "True") (PVar "ds")) (EApp (EApp (EVar "ffiCheckLabelsGo") (EVar "mctx")) (EApp (EVar "externDecls") (EVar "ds"))))
(DTypeSig false "ffiCheckLabelsGo" (TyFun (TyCon "ModuleCtx") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Unit"))))
(DFunDef false "ffiCheckLabelsGo" ((PVar "mctx") (PList)) (ELit LUnit))
(DFunDef false "ffiCheckLabelsGo" ((PVar "mctx") (PCons (PCon "DExtern" (PVar "d")) (PVar "rest"))) (EBlock (DoLet false false (PVar "diags") (EApp (EApp (EApp (EVar "ffiDeclarationDiags") (EApp (EApp (EVar "ffiIsBuiltinExternName") (EFieldAccess (EVar "mctx") "mcGraph")) (EFieldAccess (EVar "d") "edName"))) (EVar "d")) (EApp (EApp (EVar "ffiDeclaredRow") (EVar "mctx")) (EFieldAccess (EVar "d") "edTy")))) (DoLet false false PWild (EApp (EApp (EApp (EMethodRef "fold") (ELam (PWild (PVar "diag")) (EApp (EApp (EVar "pushFfiDiag") (EVar "mctx")) (EVar "diag")))) (ELit LUnit)) (EVar "diags"))) (DoExpr (EApp (EApp (EVar "ffiCheckLabelsGo") (EVar "mctx")) (EVar "rest")))))
(DFunDef false "ffiCheckLabelsGo" ((PVar "mctx") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "ffiCheckLabelsGo") (EVar "mctx")) (EVar "rest")))
(DTypeSig false "pushFfiDiag" (TyFun (TyCon "ModuleCtx") (TyFun (TyCon "FfiDiag") (TyCon "Unit"))))
(DFunDef false "pushFfiDiag" ((PVar "mctx") (PCon "FfiDiag" (PVar "code") (PVar "loc") (PVar "msg"))) (EApp (EApp (EApp (EApp (EVar "pushTypeErrorAt") (EVar "mctx")) (EVar "code")) (EVar "loc")) (EVar "msg")))
(DTypeSig true "externDecls" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "externDecls" ((PList)) (EListLit))
(DFunDef false "externDecls" ((PCons (PAs "d" (PCon "DExtern" PWild)) (PVar "rest"))) (EBinOp "::" (EVar "d") (EApp (EVar "externDecls") (EVar "rest"))))
(DFunDef false "externDecls" ((PCons PWild (PVar "rest"))) (EApp (EVar "externDecls") (EVar "rest")))
