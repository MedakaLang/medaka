# META
source_lines=333
stages=DESUGAR,MARK
# SOURCE
-- Identity + registry substrate — Stage A-2 unit A-2.0
-- (#1111 / TYPECHECK-TARGET-ARCHITECTURE.md §2 K, §6 A-2; drains #1070's
-- five audit rows across #1047/#1069/#1092/#1090 once LATER units re-key
-- their tables onto this).
--
-- 🚨 THIS UNIT CONVERTS NO TABLE AND HAS ZERO CALL SITES. It lands the
-- `Ident`/`Ns` identity carrier and the `Registry`/`MultiRegistry`/
-- `SetRegistry` combinators so each later A-2 unit has something to re-key
-- ONE table's writer + ALL its readers onto, in a single PR. Nothing in
-- `compiler/` imports this module yet — that is a feature of the staging,
-- not an oversight (see §6 A-2 in the design doc: each conversion is its own
-- reviewable, bisectable PR).
--
-- ── Why one `Ident` type generalizes a pattern already in the tree ─────────
-- `crossModuleFunConstraintsQualRef` (`types/typecheck.mdk`) is already keyed
-- by `(module, name)` because its bare-name twin
-- `crossModuleFunConstraintsRef` collides across modules that declare the
-- same function name. `Ident` generalizes that pair to
-- `(namespace, origin, name)` so the ~15 `universe*`/method/record/kind
-- tables named in #1070 can all re-key onto ONE identity type — one
-- comparator, one collision-free key renderer, one place a namespace can be
-- forgotten — instead of each growing its own ad hoc qualified-pair variant.
--
-- `resolve.mdk` already needs more than one namespace behind a bare `OrdMap
-- TyConOrigin`: the TYPE and IFACE namespaces are held in the SAME map,
-- separated by an `"iface:<Name>"` string tag (`ownTyOrigin` /
-- `ownIfaceOrigin`, `resolve.mdk:3494-3497,3962-3965`), and that separation
-- has its own regression fixture
-- (`test/references_fixtures/iface_ty_collide/`, noted at
-- `resolve.mdk:767-774`) — i.e. the tree already pays for two namespaces
-- colliding when the tag is missed. `Ident`/`Ns` is that same idea done once,
-- generally, for all SIX namespaces (type, interface, method, constructor,
-- field, value) instead of a bespoke string prefix per pair that needs it.
--
-- ── Placement (measured, do not relocate without re-measuring) ─────────────
-- `Ident`/`Ns` are NOT here — they live in `frontend/ast.mdk`, beside
-- `TyConOrigin` which `Ident` wraps: every stage already imports `ast.mdk`,
-- and it is a ~26-gate path (vs. `types/registry.mdk`'s narrower blast
-- radius). The `Registry`/`MultiRegistry`/`SetRegistry` combinators live
-- HERE, in a new `compiler/types/registry.mdk`, not in `compiler/support/`:
-- `test/preflight.sh` maps ANY `compiler/support/*` diff to `mark_full`
-- (the ~103-gate local run `AGENTS.md` forbids as the everyday loop), so
-- putting registry combinators there would make every later A-2
-- table-conversion PR pay that tax merely for touching this file too.
-- Verified directly (both invocations below; see this PR's own body for the
-- exact gate LISTS, not just counts — counts rot, per `AGENTS.md`):
--   PREFLIGHT_DRY=1 PREFLIGHT_CHANGED_FILE=<list containing compiler/support/util.mdk>  sh test/preflight.sh
--   PREFLIGHT_DRY=1 PREFLIGHT_CHANGED_FILE=<list containing compiler/types/typecheck.mdk> sh test/preflight.sh
--
-- ── Backing store ───────────────────────────────────────────────────────────
-- Wraps the EXISTING `OrdMap` (`support/ordmap.mdk`, itself a transparent
-- alias for stdlib `Map String a`) rather than reaching for stdlib `map`/
-- `hash_map` directly. `support/ordmap.mdk` is already imported by
-- `types/typecheck.mdk`, so this pays NOTHING extra: `Map`'s Eq/Ord/Debug/
-- Display/Mappable/Monoid instance surface is already forced into the
-- binary. Importing a stdlib module that defines a brand NEW type (e.g.
-- `map` cold, or `hash_map`) from a module that does not already transitively
-- pull it in is the anti-pattern `AGENTS.md` measures at +34 KB / +4.8%
-- self-compile (DCE keeps a `DImpl`/`DInterface` whole once it is
-- reachable at all) — this module avoids that by riding the SAME `OrdMap`
-- everything else already rides. `list.{sort}` and `map.{toList}` below are
-- likewise both already-forced surface (typecheck.mdk imports `list`
-- directly; `toList` operates on the already-forced `Map` type), so neither
-- adds new retained instance surface.
--
-- ── `identKey`: the ONE renderer, collision-free by construction ───────────
-- Every component (namespace tag, origin tag, origin module-or-empty, name)
-- is rendered through `lenKey` (`support/util.mdk`) — a length-prefixed
-- ("netstring") encoding: `lenKey s = "\{intToString (stringLength s)}:\{s}"`.
-- This is the SAME collision-free composite-key technique
-- `support/util.mdk`'s own callers already rely on (see its `lenKey`
-- doc-comment). Concatenating length-prefixed fields cannot let one field's
-- content bleed into the next boundary REGARDLESS of what characters the
-- fields contain — no separator character to reserve, so there is no
-- "adversarial name contains the separator" case to guard against (the
-- doctests below instead demonstrate the sharper adversarial case: two
-- DIFFERENT `(origin module, name)` pairs that share a character at their
-- boundary, e.g. `("ab", "c")` vs. `("a", "bc")`, which a naive `++`
-- concatenation WOULD collide on and `lenKey`-prefixing does not).
--
-- `identKey`'s output is OPAQUE: nothing may parse it back. `regEntries`
-- therefore does not reconstruct an `Ident` from the rendered key — it keeps
-- the original `Ident` alongside its value in the backing map instead (see
-- `Registry` below), so recovering identities never depends on the key being
-- decodable.
--
-- ── `regInsert` conflict handling (decided for THIS unit only) ─────────────
-- Per `docs/spec/DICT-SEMANTICS.md` §8 I4, declarations are never rejected —
-- only USE sites are — so once every table is keyed by `Ident`, two
-- genuinely distinct declarations get genuinely distinct identities and
-- coexist; a `regInsert` collision after re-keying means the REGISTRY'S OWN
-- KEYING is broken (a compiler bug), not a user error to diagnose at the
-- declaration. `regInsertChecked` is therefore last-write-wins (matching
-- every existing `universe*` table's current behavior, so a later unit's
-- conversion PR is a pure re-keying with no behavior change to also review)
-- but returns a `Bool` alongside the new registry saying whether an existing
-- entry under that exact `Ident` was overwritten — the signal a later unit
-- (A-2.8) can turn into a diagnostic once the diagnostic-code family
-- question (`T-INTERNAL-REGISTRY-CONFLICT` vs. a resolve-phase
-- `R-AMBIGUOUS-*` code) is settled. Deliberately NOT decided here.

import frontend.ast.{Ns(..), Ident(..), TyConOrigin(..)}
import support.ordmap.{OrdMap, omEmpty, omInsert, omLookup, omHasKey}
import support.util.{lenKey, listLen}
import list.{sort}
import map.{toList}

-- ── identKey ─────────────────────────────────────────────────────────────

nsTag : Ns -> String
nsTag NsType = "type"
nsTag NsIface = "iface"
nsTag NsMethod = "method"
nsTag NsCtor = "ctor"
nsTag NsField = "field"
nsTag NsValue = "value"

originTag : TyConOrigin -> String
originTag OriginUnresolved = "unresolved"
originTag OriginBuiltin = "builtin"
originTag (OriginModule _) = "module"

originModuleOf : TyConOrigin -> String
originModuleOf (OriginModule m) = m
originModuleOf OriginUnresolved = ""
originModuleOf OriginBuiltin = ""

-- The one renderer — see the module doc-comment above for the collision
-- argument. Treat the result as OPAQUE.
export identKey : Ident -> String
identKey (Ident ns origin name) = lenKey (nsTag ns)
  ++ lenKey (originTag origin)
  ++ lenKey (originModuleOf origin)
  ++ lenKey name

-- ── Registry: write-once-or-diagnose map from Ident to ONE value ──────────
-- Stores the ORIGINAL `Ident` alongside each value (not just its rendered
-- key) so `regEntries` can hand identities back out without ever parsing
-- `identKey`'s opaque output.
public export data Registry v = Registry (OrdMap (Ident, v))

export regEmpty : Registry v
regEmpty = Registry omEmpty

export regLookup : Ident -> Registry v -> Option v
regLookup ident (Registry m) = map ((_, v) => v) (omLookup (identKey ident) m)

-- Last-write-wins; the `Bool` says whether an entry under this exact `Ident`
-- already existed (an OVERWRITE, not a fresh key) — see the module
-- doc-comment "regInsert conflict handling" above for why that is the right
-- shape for this unit.
export regInsertChecked : Ident -> v -> Registry v -> (Registry v, Bool)
regInsertChecked ident v (Registry m) = (Registry (omInsert (identKey ident) (ident, v) m), omHasKey (identKey ident) m)

export regInsert : Ident -> v -> Registry v -> Registry v
regInsert ident v r = fst (regInsertChecked ident v r)

export regEntries : Registry v -> List (Ident, v)
regEntries (Registry m) = map snd (toList m)

-- ── MultiRegistry: explicitly commutative — no entry can be lost to order ──
-- Unlike `Registry`, `mregAdd` never overwrites: every value ever added under
-- an `Ident` is kept, so which order two calls happen in cannot make one
-- registration disappear (the failure mode `Registry`'s last-write-wins
-- accepts on purpose). The internal LIST order under one `Ident` may still
-- differ by call order — the "order-free" guarantee is about completeness
-- (nothing is dropped), not about the enumeration order of `mregLookup`'s
-- result.
public export data MultiRegistry v = MultiRegistry (OrdMap (List v))

export mregEmpty : MultiRegistry v
mregEmpty = MultiRegistry omEmpty

export mregAdd : Ident -> v -> MultiRegistry v -> MultiRegistry v
mregAdd ident v (MultiRegistry m) =
  let key = identKey ident
  match omLookup key m
    Some vs => MultiRegistry (omInsert key (v::vs) m)
    None => MultiRegistry (omInsert key [v] m)

export mregLookup : Ident -> MultiRegistry v -> List v
mregLookup ident (MultiRegistry m) = match omLookup (identKey ident) m
  Some vs => vs
  None => []

-- ── SetRegistry: membership only ──────────────────────────────────────────
public export data SetRegistry = SetRegistry (OrdMap Unit)

export sregEmpty : SetRegistry
sregEmpty = SetRegistry omEmpty

export sregAdd : Ident -> SetRegistry -> SetRegistry
sregAdd ident (SetRegistry m) = SetRegistry (omInsert (identKey ident) () m)

export sregMember : Ident -> SetRegistry -> Bool
sregMember ident (SetRegistry m) = omHasKey (identKey ident) m

-- ── Doctest fixtures ───────────────────────────────────────────────────────
-- These `Ident`s exist only to give the doctests below short, readable
-- expressions. Each pair differs from its sibling along exactly ONE axis
-- (Ns, TyConOrigin, or name) so each doctest isolates one collision
-- dimension.

identTypeFooM : Ident
identTypeFooM = Ident NsType (OriginModule "m") "Foo"

identIfaceFooM : Ident
identIfaceFooM = Ident NsIface (OriginModule "m") "Foo"

identTypeFooN : Ident
identTypeFooN = Ident NsType (OriginModule "n") "Foo"

identTypeBarM : Ident
identTypeBarM = Ident NsType (OriginModule "m") "Bar"

identTypeFooUnresolved : Ident
identTypeFooUnresolved = Ident NsType OriginUnresolved "Foo"

identTypeFooBuiltin : Ident
identTypeFooBuiltin = Ident NsType OriginBuiltin "Foo"

-- Adversarial: two DIFFERENT Idents whose (origin-module, name) pair shifts
-- a character across the module/name boundary — `"ab" ++ "c" == "a" ++
-- "bc"`. A naive un-prefixed concatenation of fields WOULD collide these;
-- `identKey`'s `lenKey`-prefixing does not.
identShiftA : Ident
identShiftA = Ident NsType (OriginModule "ab") "c"

identShiftB : Ident
identShiftB = Ident NsType (OriginModule "a") "bc"

regBothNs : Registry Int
regBothNs = regInsert identIfaceFooM 2 (regInsert identTypeFooM 1 regEmpty)

regBothOrigin : Registry Int
regBothOrigin = regInsert identTypeFooN 20 (regInsert identTypeFooM 10 regEmpty)

regAllOriginKinds : Registry Int
regAllOriginKinds =
  regInsert
    identTypeFooBuiltin
    3
    (regInsert identTypeFooUnresolved 2 (regInsert identTypeFooM 1 regEmpty))

regBothNames : Registry Int
regBothNames =
  regInsert identTypeBarM 200 (regInsert identTypeFooM 100 regEmpty)

regShift : Registry Int
regShift = regInsert identShiftB 2 (regInsert identShiftA 1 regEmpty)

-- mregAdd, called in OPPOSITE orders under the SAME Ident with the SAME two
-- values — demonstrates no registration is lost to call order.
mregOrderA : MultiRegistry Int
mregOrderA = mregAdd identTypeFooM 2 (mregAdd identTypeFooM 1 mregEmpty)

mregOrderB : MultiRegistry Int
mregOrderB = mregAdd identTypeFooM 1 (mregAdd identTypeFooM 2 mregEmpty)

-- Round-trip: insert then lookup under the SAME Ident finds the value; a
-- DIFFERENT Ident (differing only in name) finds nothing.
-- > regLookup identTypeFooM (regInsert identTypeFooM 42 regEmpty)
-- Some 42
-- > regLookup identTypeBarM (regInsert identTypeFooM 42 regEmpty)
-- None

-- Two Idents differing ONLY in Ns (same origin, same name) do not collide:
-- both coexist and each lookup finds its own value.
-- > regLookup identTypeFooM regBothNs
-- Some 1
-- > regLookup identIfaceFooM regBothNs
-- Some 2

-- Two Idents differing ONLY in TyConOrigin's module string do not collide.
-- > regLookup identTypeFooM regBothOrigin
-- Some 10
-- > regLookup identTypeFooN regBothOrigin
-- Some 20

-- All three TyConOrigin KINDS (module / unresolved / builtin) coexist under
-- the same Ns + name — the origin TAG, not just the module string, is part
-- of the key.
-- > regLookup identTypeFooM regAllOriginKinds
-- Some 1
-- > regLookup identTypeFooUnresolved regAllOriginKinds
-- Some 2
-- > regLookup identTypeFooBuiltin regAllOriginKinds
-- Some 3

-- Two Idents differing ONLY in name do not collide.
-- > regLookup identTypeFooM regBothNames
-- Some 100
-- > regLookup identTypeBarM regBothNames
-- Some 200

-- Adversarial boundary-shift case: identKey itself must differ (this is the
-- property that keeps regShift's two entries apart above).
-- > identKey identShiftA == identKey identShiftB
-- False
-- > regLookup identShiftA regShift
-- Some 1
-- > regLookup identShiftB regShift
-- Some 2

-- regInsertChecked's overwrite signal fires both ways: True when an entry
-- under the exact same Ident already existed, False when the key was fresh.
-- > snd (regInsertChecked identTypeFooM 99 (regInsert identTypeFooM 1 regEmpty))
-- True
-- > snd (regInsertChecked identTypeFooM 99 regEmpty)
-- False

-- regEntries hands back both original Idents (via lookup, since Ident has no
-- derived Eq to compare directly) plus the right count.
-- > listLen (regEntries regBothNs)
-- 2

-- mregAdd never drops a registration to call order: both orders keep BOTH
-- values (as a multiset — sorted before comparing, since the internal list
-- order is not itself the guarantee).
-- > listLen (mregLookup identTypeFooM mregOrderA)
-- 2
-- > listLen (mregLookup identTypeFooM mregOrderB)
-- 2
-- > sort (mregLookup identTypeFooM mregOrderA) == sort (mregLookup identTypeFooM mregOrderB)
-- True
-- > mregLookup identTypeBarM mregOrderA
-- []

-- SetRegistry: membership only.
-- > sregMember identTypeFooM (sregAdd identTypeFooM sregEmpty)
-- True
-- > sregMember identTypeBarM (sregAdd identTypeFooM sregEmpty)
-- False
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Ns" true) (mem "Ident" true) (mem "TyConOrigin" true))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omInsert" false) (mem "omLookup" false) (mem "omHasKey" false))))
(DUse false (UseGroup ("support" "util") ((mem "lenKey" false) (mem "listLen" false))))
(DUse false (UseGroup ("list") ((mem "sort" false))))
(DUse false (UseGroup ("map") ((mem "toList" false))))
(DTypeSig false "nsTag" (TyFun (TyCon "Ns") (TyCon "String")))
(DFunDef false "nsTag" ((PCon "NsType")) (ELit (LString "type")))
(DFunDef false "nsTag" ((PCon "NsIface")) (ELit (LString "iface")))
(DFunDef false "nsTag" ((PCon "NsMethod")) (ELit (LString "method")))
(DFunDef false "nsTag" ((PCon "NsCtor")) (ELit (LString "ctor")))
(DFunDef false "nsTag" ((PCon "NsField")) (ELit (LString "field")))
(DFunDef false "nsTag" ((PCon "NsValue")) (ELit (LString "value")))
(DTypeSig false "originTag" (TyFun (TyCon "TyConOrigin") (TyCon "String")))
(DFunDef false "originTag" ((PCon "OriginUnresolved")) (ELit (LString "unresolved")))
(DFunDef false "originTag" ((PCon "OriginBuiltin")) (ELit (LString "builtin")))
(DFunDef false "originTag" ((PCon "OriginModule" PWild)) (ELit (LString "module")))
(DTypeSig false "originModuleOf" (TyFun (TyCon "TyConOrigin") (TyCon "String")))
(DFunDef false "originModuleOf" ((PCon "OriginModule" (PVar "m"))) (EVar "m"))
(DFunDef false "originModuleOf" ((PCon "OriginUnresolved")) (ELit (LString "")))
(DFunDef false "originModuleOf" ((PCon "OriginBuiltin")) (ELit (LString "")))
(DTypeSig true "identKey" (TyFun (TyCon "Ident") (TyCon "String")))
(DFunDef false "identKey" ((PCon "Ident" (PVar "ns") (PVar "origin") (PVar "name"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EApp (EVar "lenKey") (EApp (EVar "nsTag") (EVar "ns"))) (EApp (EVar "lenKey") (EApp (EVar "originTag") (EVar "origin")))) (EApp (EVar "lenKey") (EApp (EVar "originModuleOf") (EVar "origin")))) (EApp (EVar "lenKey") (EVar "name"))))
(DData Public "Registry" ("v") ((variant "Registry" (ConPos (TyApp (TyCon "OrdMap") (TyTuple (TyCon "Ident") (TyVar "v")))))) ())
(DTypeSig true "regEmpty" (TyApp (TyCon "Registry") (TyVar "v")))
(DFunDef false "regEmpty" () (EApp (EVar "Registry") (EVar "omEmpty")))
(DTypeSig true "regLookup" (TyFun (TyCon "Ident") (TyFun (TyApp (TyCon "Registry") (TyVar "v")) (TyApp (TyCon "Option") (TyVar "v")))))
(DFunDef false "regLookup" ((PVar "ident") (PCon "Registry" (PVar "m"))) (EApp (EApp (EVar "map") (ELam ((PTuple PWild (PVar "v"))) (EVar "v"))) (EApp (EApp (EVar "omLookup") (EApp (EVar "identKey") (EVar "ident"))) (EVar "m"))))
(DTypeSig true "regInsertChecked" (TyFun (TyCon "Ident") (TyFun (TyVar "v") (TyFun (TyApp (TyCon "Registry") (TyVar "v")) (TyTuple (TyApp (TyCon "Registry") (TyVar "v")) (TyCon "Bool"))))))
(DFunDef false "regInsertChecked" ((PVar "ident") (PVar "v") (PCon "Registry" (PVar "m"))) (ETuple (EApp (EVar "Registry") (EApp (EApp (EApp (EVar "omInsert") (EApp (EVar "identKey") (EVar "ident"))) (ETuple (EVar "ident") (EVar "v"))) (EVar "m"))) (EApp (EApp (EVar "omHasKey") (EApp (EVar "identKey") (EVar "ident"))) (EVar "m"))))
(DTypeSig true "regInsert" (TyFun (TyCon "Ident") (TyFun (TyVar "v") (TyFun (TyApp (TyCon "Registry") (TyVar "v")) (TyApp (TyCon "Registry") (TyVar "v"))))))
(DFunDef false "regInsert" ((PVar "ident") (PVar "v") (PVar "r")) (EApp (EVar "fst") (EApp (EApp (EApp (EVar "regInsertChecked") (EVar "ident")) (EVar "v")) (EVar "r"))))
(DTypeSig true "regEntries" (TyFun (TyApp (TyCon "Registry") (TyVar "v")) (TyApp (TyCon "List") (TyTuple (TyCon "Ident") (TyVar "v")))))
(DFunDef false "regEntries" ((PCon "Registry" (PVar "m"))) (EApp (EApp (EVar "map") (EVar "snd")) (EApp (EVar "toList") (EVar "m"))))
(DData Public "MultiRegistry" ("v") ((variant "MultiRegistry" (ConPos (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyVar "v")))))) ())
(DTypeSig true "mregEmpty" (TyApp (TyCon "MultiRegistry") (TyVar "v")))
(DFunDef false "mregEmpty" () (EApp (EVar "MultiRegistry") (EVar "omEmpty")))
(DTypeSig true "mregAdd" (TyFun (TyCon "Ident") (TyFun (TyVar "v") (TyFun (TyApp (TyCon "MultiRegistry") (TyVar "v")) (TyApp (TyCon "MultiRegistry") (TyVar "v"))))))
(DFunDef false "mregAdd" ((PVar "ident") (PVar "v") (PCon "MultiRegistry" (PVar "m"))) (EBlock (DoLet false false (PVar "key") (EApp (EVar "identKey") (EVar "ident"))) (DoExpr (EMatch (EApp (EApp (EVar "omLookup") (EVar "key")) (EVar "m")) (arm (PCon "Some" (PVar "vs")) () (EApp (EVar "MultiRegistry") (EApp (EApp (EApp (EVar "omInsert") (EVar "key")) (EBinOp "::" (EVar "v") (EVar "vs"))) (EVar "m")))) (arm (PCon "None") () (EApp (EVar "MultiRegistry") (EApp (EApp (EApp (EVar "omInsert") (EVar "key")) (EListLit (EVar "v"))) (EVar "m"))))))))
(DTypeSig true "mregLookup" (TyFun (TyCon "Ident") (TyFun (TyApp (TyCon "MultiRegistry") (TyVar "v")) (TyApp (TyCon "List") (TyVar "v")))))
(DFunDef false "mregLookup" ((PVar "ident") (PCon "MultiRegistry" (PVar "m"))) (EMatch (EApp (EApp (EVar "omLookup") (EApp (EVar "identKey") (EVar "ident"))) (EVar "m")) (arm (PCon "Some" (PVar "vs")) () (EVar "vs")) (arm (PCon "None") () (EListLit))))
(DData Public "SetRegistry" () ((variant "SetRegistry" (ConPos (TyApp (TyCon "OrdMap") (TyCon "Unit"))))) ())
(DTypeSig true "sregEmpty" (TyCon "SetRegistry"))
(DFunDef false "sregEmpty" () (EApp (EVar "SetRegistry") (EVar "omEmpty")))
(DTypeSig true "sregAdd" (TyFun (TyCon "Ident") (TyFun (TyCon "SetRegistry") (TyCon "SetRegistry"))))
(DFunDef false "sregAdd" ((PVar "ident") (PCon "SetRegistry" (PVar "m"))) (EApp (EVar "SetRegistry") (EApp (EApp (EApp (EVar "omInsert") (EApp (EVar "identKey") (EVar "ident"))) (ELit LUnit)) (EVar "m"))))
(DTypeSig true "sregMember" (TyFun (TyCon "Ident") (TyFun (TyCon "SetRegistry") (TyCon "Bool"))))
(DFunDef false "sregMember" ((PVar "ident") (PCon "SetRegistry" (PVar "m"))) (EApp (EApp (EVar "omHasKey") (EApp (EVar "identKey") (EVar "ident"))) (EVar "m")))
(DTypeSig false "identTypeFooM" (TyCon "Ident"))
(DFunDef false "identTypeFooM" () (EApp (EApp (EApp (EVar "Ident") (EVar "NsType")) (EApp (EVar "OriginModule") (ELit (LString "m")))) (ELit (LString "Foo"))))
(DTypeSig false "identIfaceFooM" (TyCon "Ident"))
(DFunDef false "identIfaceFooM" () (EApp (EApp (EApp (EVar "Ident") (EVar "NsIface")) (EApp (EVar "OriginModule") (ELit (LString "m")))) (ELit (LString "Foo"))))
(DTypeSig false "identTypeFooN" (TyCon "Ident"))
(DFunDef false "identTypeFooN" () (EApp (EApp (EApp (EVar "Ident") (EVar "NsType")) (EApp (EVar "OriginModule") (ELit (LString "n")))) (ELit (LString "Foo"))))
(DTypeSig false "identTypeBarM" (TyCon "Ident"))
(DFunDef false "identTypeBarM" () (EApp (EApp (EApp (EVar "Ident") (EVar "NsType")) (EApp (EVar "OriginModule") (ELit (LString "m")))) (ELit (LString "Bar"))))
(DTypeSig false "identTypeFooUnresolved" (TyCon "Ident"))
(DFunDef false "identTypeFooUnresolved" () (EApp (EApp (EApp (EVar "Ident") (EVar "NsType")) (EVar "OriginUnresolved")) (ELit (LString "Foo"))))
(DTypeSig false "identTypeFooBuiltin" (TyCon "Ident"))
(DFunDef false "identTypeFooBuiltin" () (EApp (EApp (EApp (EVar "Ident") (EVar "NsType")) (EVar "OriginBuiltin")) (ELit (LString "Foo"))))
(DTypeSig false "identShiftA" (TyCon "Ident"))
(DFunDef false "identShiftA" () (EApp (EApp (EApp (EVar "Ident") (EVar "NsType")) (EApp (EVar "OriginModule") (ELit (LString "ab")))) (ELit (LString "c"))))
(DTypeSig false "identShiftB" (TyCon "Ident"))
(DFunDef false "identShiftB" () (EApp (EApp (EApp (EVar "Ident") (EVar "NsType")) (EApp (EVar "OriginModule") (ELit (LString "a")))) (ELit (LString "bc"))))
(DTypeSig false "regBothNs" (TyApp (TyCon "Registry") (TyCon "Int")))
(DFunDef false "regBothNs" () (EApp (EApp (EApp (EVar "regInsert") (EVar "identIfaceFooM")) (ELit (LInt 2))) (EApp (EApp (EApp (EVar "regInsert") (EVar "identTypeFooM")) (ELit (LInt 1))) (EVar "regEmpty"))))
(DTypeSig false "regBothOrigin" (TyApp (TyCon "Registry") (TyCon "Int")))
(DFunDef false "regBothOrigin" () (EApp (EApp (EApp (EVar "regInsert") (EVar "identTypeFooN")) (ELit (LInt 20))) (EApp (EApp (EApp (EVar "regInsert") (EVar "identTypeFooM")) (ELit (LInt 10))) (EVar "regEmpty"))))
(DTypeSig false "regAllOriginKinds" (TyApp (TyCon "Registry") (TyCon "Int")))
(DFunDef false "regAllOriginKinds" () (EApp (EApp (EApp (EVar "regInsert") (EVar "identTypeFooBuiltin")) (ELit (LInt 3))) (EApp (EApp (EApp (EVar "regInsert") (EVar "identTypeFooUnresolved")) (ELit (LInt 2))) (EApp (EApp (EApp (EVar "regInsert") (EVar "identTypeFooM")) (ELit (LInt 1))) (EVar "regEmpty")))))
(DTypeSig false "regBothNames" (TyApp (TyCon "Registry") (TyCon "Int")))
(DFunDef false "regBothNames" () (EApp (EApp (EApp (EVar "regInsert") (EVar "identTypeBarM")) (ELit (LInt 200))) (EApp (EApp (EApp (EVar "regInsert") (EVar "identTypeFooM")) (ELit (LInt 100))) (EVar "regEmpty"))))
(DTypeSig false "regShift" (TyApp (TyCon "Registry") (TyCon "Int")))
(DFunDef false "regShift" () (EApp (EApp (EApp (EVar "regInsert") (EVar "identShiftB")) (ELit (LInt 2))) (EApp (EApp (EApp (EVar "regInsert") (EVar "identShiftA")) (ELit (LInt 1))) (EVar "regEmpty"))))
(DTypeSig false "mregOrderA" (TyApp (TyCon "MultiRegistry") (TyCon "Int")))
(DFunDef false "mregOrderA" () (EApp (EApp (EApp (EVar "mregAdd") (EVar "identTypeFooM")) (ELit (LInt 2))) (EApp (EApp (EApp (EVar "mregAdd") (EVar "identTypeFooM")) (ELit (LInt 1))) (EVar "mregEmpty"))))
(DTypeSig false "mregOrderB" (TyApp (TyCon "MultiRegistry") (TyCon "Int")))
(DFunDef false "mregOrderB" () (EApp (EApp (EApp (EVar "mregAdd") (EVar "identTypeFooM")) (ELit (LInt 1))) (EApp (EApp (EApp (EVar "mregAdd") (EVar "identTypeFooM")) (ELit (LInt 2))) (EVar "mregEmpty"))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Ns" true) (mem "Ident" true) (mem "TyConOrigin" true))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omInsert" false) (mem "omLookup" false) (mem "omHasKey" false))))
(DUse false (UseGroup ("support" "util") ((mem "lenKey" false) (mem "listLen" false))))
(DUse false (UseGroup ("list") ((mem "sort" false))))
(DUse false (UseGroup ("map") ((mem "toList" false))))
(DTypeSig false "nsTag" (TyFun (TyCon "Ns") (TyCon "String")))
(DFunDef false "nsTag" ((PCon "NsType")) (ELit (LString "type")))
(DFunDef false "nsTag" ((PCon "NsIface")) (ELit (LString "iface")))
(DFunDef false "nsTag" ((PCon "NsMethod")) (ELit (LString "method")))
(DFunDef false "nsTag" ((PCon "NsCtor")) (ELit (LString "ctor")))
(DFunDef false "nsTag" ((PCon "NsField")) (ELit (LString "field")))
(DFunDef false "nsTag" ((PCon "NsValue")) (ELit (LString "value")))
(DTypeSig false "originTag" (TyFun (TyCon "TyConOrigin") (TyCon "String")))
(DFunDef false "originTag" ((PCon "OriginUnresolved")) (ELit (LString "unresolved")))
(DFunDef false "originTag" ((PCon "OriginBuiltin")) (ELit (LString "builtin")))
(DFunDef false "originTag" ((PCon "OriginModule" PWild)) (ELit (LString "module")))
(DTypeSig false "originModuleOf" (TyFun (TyCon "TyConOrigin") (TyCon "String")))
(DFunDef false "originModuleOf" ((PCon "OriginModule" (PVar "m"))) (EVar "m"))
(DFunDef false "originModuleOf" ((PCon "OriginUnresolved")) (ELit (LString "")))
(DFunDef false "originModuleOf" ((PCon "OriginBuiltin")) (ELit (LString "")))
(DTypeSig true "identKey" (TyFun (TyCon "Ident") (TyCon "String")))
(DFunDef false "identKey" ((PCon "Ident" (PVar "ns") (PVar "origin") (PVar "name"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EApp (EVar "lenKey") (EApp (EVar "nsTag") (EVar "ns"))) (EApp (EVar "lenKey") (EApp (EVar "originTag") (EVar "origin")))) (EApp (EVar "lenKey") (EApp (EVar "originModuleOf") (EVar "origin")))) (EApp (EVar "lenKey") (EVar "name"))))
(DData Public "Registry" ("v") ((variant "Registry" (ConPos (TyApp (TyCon "OrdMap") (TyTuple (TyCon "Ident") (TyVar "v")))))) ())
(DTypeSig true "regEmpty" (TyApp (TyCon "Registry") (TyVar "v")))
(DFunDef false "regEmpty" () (EApp (EVar "Registry") (EVar "omEmpty")))
(DTypeSig true "regLookup" (TyFun (TyCon "Ident") (TyFun (TyApp (TyCon "Registry") (TyVar "v")) (TyApp (TyCon "Option") (TyVar "v")))))
(DFunDef false "regLookup" ((PVar "ident") (PCon "Registry" (PVar "m"))) (EApp (EApp (EMethodRef "map") (ELam ((PTuple PWild (PVar "v"))) (EVar "v"))) (EApp (EApp (EVar "omLookup") (EApp (EVar "identKey") (EVar "ident"))) (EVar "m"))))
(DTypeSig true "regInsertChecked" (TyFun (TyCon "Ident") (TyFun (TyVar "v") (TyFun (TyApp (TyCon "Registry") (TyVar "v")) (TyTuple (TyApp (TyCon "Registry") (TyVar "v")) (TyCon "Bool"))))))
(DFunDef false "regInsertChecked" ((PVar "ident") (PVar "v") (PCon "Registry" (PVar "m"))) (ETuple (EApp (EVar "Registry") (EApp (EApp (EApp (EVar "omInsert") (EApp (EVar "identKey") (EVar "ident"))) (ETuple (EVar "ident") (EVar "v"))) (EVar "m"))) (EApp (EApp (EVar "omHasKey") (EApp (EVar "identKey") (EVar "ident"))) (EVar "m"))))
(DTypeSig true "regInsert" (TyFun (TyCon "Ident") (TyFun (TyVar "v") (TyFun (TyApp (TyCon "Registry") (TyVar "v")) (TyApp (TyCon "Registry") (TyVar "v"))))))
(DFunDef false "regInsert" ((PVar "ident") (PVar "v") (PVar "r")) (EApp (EVar "fst") (EApp (EApp (EApp (EVar "regInsertChecked") (EVar "ident")) (EVar "v")) (EVar "r"))))
(DTypeSig true "regEntries" (TyFun (TyApp (TyCon "Registry") (TyVar "v")) (TyApp (TyCon "List") (TyTuple (TyCon "Ident") (TyVar "v")))))
(DFunDef false "regEntries" ((PCon "Registry" (PVar "m"))) (EApp (EApp (EMethodRef "map") (EVar "snd")) (EApp (EMethodRef "toList") (EVar "m"))))
(DData Public "MultiRegistry" ("v") ((variant "MultiRegistry" (ConPos (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyVar "v")))))) ())
(DTypeSig true "mregEmpty" (TyApp (TyCon "MultiRegistry") (TyVar "v")))
(DFunDef false "mregEmpty" () (EApp (EVar "MultiRegistry") (EVar "omEmpty")))
(DTypeSig true "mregAdd" (TyFun (TyCon "Ident") (TyFun (TyVar "v") (TyFun (TyApp (TyCon "MultiRegistry") (TyVar "v")) (TyApp (TyCon "MultiRegistry") (TyVar "v"))))))
(DFunDef false "mregAdd" ((PVar "ident") (PVar "v") (PCon "MultiRegistry" (PVar "m"))) (EBlock (DoLet false false (PVar "key") (EApp (EVar "identKey") (EVar "ident"))) (DoExpr (EMatch (EApp (EApp (EVar "omLookup") (EVar "key")) (EVar "m")) (arm (PCon "Some" (PVar "vs")) () (EApp (EVar "MultiRegistry") (EApp (EApp (EApp (EVar "omInsert") (EVar "key")) (EBinOp "::" (EVar "v") (EVar "vs"))) (EVar "m")))) (arm (PCon "None") () (EApp (EVar "MultiRegistry") (EApp (EApp (EApp (EVar "omInsert") (EVar "key")) (EListLit (EVar "v"))) (EVar "m"))))))))
(DTypeSig true "mregLookup" (TyFun (TyCon "Ident") (TyFun (TyApp (TyCon "MultiRegistry") (TyVar "v")) (TyApp (TyCon "List") (TyVar "v")))))
(DFunDef false "mregLookup" ((PVar "ident") (PCon "MultiRegistry" (PVar "m"))) (EMatch (EApp (EApp (EVar "omLookup") (EApp (EVar "identKey") (EVar "ident"))) (EVar "m")) (arm (PCon "Some" (PVar "vs")) () (EVar "vs")) (arm (PCon "None") () (EListLit))))
(DData Public "SetRegistry" () ((variant "SetRegistry" (ConPos (TyApp (TyCon "OrdMap") (TyCon "Unit"))))) ())
(DTypeSig true "sregEmpty" (TyCon "SetRegistry"))
(DFunDef false "sregEmpty" () (EApp (EVar "SetRegistry") (EVar "omEmpty")))
(DTypeSig true "sregAdd" (TyFun (TyCon "Ident") (TyFun (TyCon "SetRegistry") (TyCon "SetRegistry"))))
(DFunDef false "sregAdd" ((PVar "ident") (PCon "SetRegistry" (PVar "m"))) (EApp (EVar "SetRegistry") (EApp (EApp (EApp (EVar "omInsert") (EApp (EVar "identKey") (EVar "ident"))) (ELit LUnit)) (EVar "m"))))
(DTypeSig true "sregMember" (TyFun (TyCon "Ident") (TyFun (TyCon "SetRegistry") (TyCon "Bool"))))
(DFunDef false "sregMember" ((PVar "ident") (PCon "SetRegistry" (PVar "m"))) (EApp (EApp (EVar "omHasKey") (EApp (EVar "identKey") (EVar "ident"))) (EVar "m")))
(DTypeSig false "identTypeFooM" (TyCon "Ident"))
(DFunDef false "identTypeFooM" () (EApp (EApp (EApp (EVar "Ident") (EVar "NsType")) (EApp (EVar "OriginModule") (ELit (LString "m")))) (ELit (LString "Foo"))))
(DTypeSig false "identIfaceFooM" (TyCon "Ident"))
(DFunDef false "identIfaceFooM" () (EApp (EApp (EApp (EVar "Ident") (EVar "NsIface")) (EApp (EVar "OriginModule") (ELit (LString "m")))) (ELit (LString "Foo"))))
(DTypeSig false "identTypeFooN" (TyCon "Ident"))
(DFunDef false "identTypeFooN" () (EApp (EApp (EApp (EVar "Ident") (EVar "NsType")) (EApp (EVar "OriginModule") (ELit (LString "n")))) (ELit (LString "Foo"))))
(DTypeSig false "identTypeBarM" (TyCon "Ident"))
(DFunDef false "identTypeBarM" () (EApp (EApp (EApp (EVar "Ident") (EVar "NsType")) (EApp (EVar "OriginModule") (ELit (LString "m")))) (ELit (LString "Bar"))))
(DTypeSig false "identTypeFooUnresolved" (TyCon "Ident"))
(DFunDef false "identTypeFooUnresolved" () (EApp (EApp (EApp (EVar "Ident") (EVar "NsType")) (EVar "OriginUnresolved")) (ELit (LString "Foo"))))
(DTypeSig false "identTypeFooBuiltin" (TyCon "Ident"))
(DFunDef false "identTypeFooBuiltin" () (EApp (EApp (EApp (EVar "Ident") (EVar "NsType")) (EVar "OriginBuiltin")) (ELit (LString "Foo"))))
(DTypeSig false "identShiftA" (TyCon "Ident"))
(DFunDef false "identShiftA" () (EApp (EApp (EApp (EVar "Ident") (EVar "NsType")) (EApp (EVar "OriginModule") (ELit (LString "ab")))) (ELit (LString "c"))))
(DTypeSig false "identShiftB" (TyCon "Ident"))
(DFunDef false "identShiftB" () (EApp (EApp (EApp (EVar "Ident") (EVar "NsType")) (EApp (EVar "OriginModule") (ELit (LString "a")))) (ELit (LString "bc"))))
(DTypeSig false "regBothNs" (TyApp (TyCon "Registry") (TyCon "Int")))
(DFunDef false "regBothNs" () (EApp (EApp (EApp (EVar "regInsert") (EVar "identIfaceFooM")) (ELit (LInt 2))) (EApp (EApp (EApp (EVar "regInsert") (EVar "identTypeFooM")) (ELit (LInt 1))) (EVar "regEmpty"))))
(DTypeSig false "regBothOrigin" (TyApp (TyCon "Registry") (TyCon "Int")))
(DFunDef false "regBothOrigin" () (EApp (EApp (EApp (EVar "regInsert") (EVar "identTypeFooN")) (ELit (LInt 20))) (EApp (EApp (EApp (EVar "regInsert") (EVar "identTypeFooM")) (ELit (LInt 10))) (EVar "regEmpty"))))
(DTypeSig false "regAllOriginKinds" (TyApp (TyCon "Registry") (TyCon "Int")))
(DFunDef false "regAllOriginKinds" () (EApp (EApp (EApp (EVar "regInsert") (EVar "identTypeFooBuiltin")) (ELit (LInt 3))) (EApp (EApp (EApp (EVar "regInsert") (EVar "identTypeFooUnresolved")) (ELit (LInt 2))) (EApp (EApp (EApp (EVar "regInsert") (EVar "identTypeFooM")) (ELit (LInt 1))) (EVar "regEmpty")))))
(DTypeSig false "regBothNames" (TyApp (TyCon "Registry") (TyCon "Int")))
(DFunDef false "regBothNames" () (EApp (EApp (EApp (EVar "regInsert") (EVar "identTypeBarM")) (ELit (LInt 200))) (EApp (EApp (EApp (EVar "regInsert") (EVar "identTypeFooM")) (ELit (LInt 100))) (EVar "regEmpty"))))
(DTypeSig false "regShift" (TyApp (TyCon "Registry") (TyCon "Int")))
(DFunDef false "regShift" () (EApp (EApp (EApp (EVar "regInsert") (EVar "identShiftB")) (ELit (LInt 2))) (EApp (EApp (EApp (EVar "regInsert") (EVar "identShiftA")) (ELit (LInt 1))) (EVar "regEmpty"))))
(DTypeSig false "mregOrderA" (TyApp (TyCon "MultiRegistry") (TyCon "Int")))
(DFunDef false "mregOrderA" () (EApp (EApp (EApp (EVar "mregAdd") (EVar "identTypeFooM")) (ELit (LInt 2))) (EApp (EApp (EApp (EVar "mregAdd") (EVar "identTypeFooM")) (ELit (LInt 1))) (EVar "mregEmpty"))))
(DTypeSig false "mregOrderB" (TyApp (TyCon "MultiRegistry") (TyCon "Int")))
(DFunDef false "mregOrderB" () (EApp (EApp (EApp (EVar "mregAdd") (EVar "identTypeFooM")) (ELit (LInt 1))) (EApp (EApp (EApp (EVar "mregAdd") (EVar "identTypeFooM")) (ELit (LInt 2))) (EVar "mregEmpty"))))
