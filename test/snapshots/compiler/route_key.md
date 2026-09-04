# META
source_lines=552
stages=DESUGAR,MARK
# SOURCE
-- The SHARED ROUTE-WORD MINT — Stage B / Phase 3′ (ARCH B-2, #1113).
--
-- 🚨 THE TICKET IN THIS HEADER USED TO READ #1182 AND THAT WAS WRONG — nine
-- instances of the same mis-citation propagated from one packet sentence, and a
-- reader greps the HEADER, so it is corrected here rather than only in the body.
-- Qualifying the route word does NOT fix #1182: that bug is
-- `ieCandidatesForMethod`'s candidate key — method-name membership plus a head
-- match, with NO interface component — which is UPSTREAM of this word; the row is
-- already chosen wrong before anything here is minted. And on #1182's own repro
-- the word does not even move: it is a SINGLE FILE, so `ifaceIdentity` answers
-- `""`, `ifaceWordOf` falls back to the bare name, and the output is byte-
-- identical to the pre-bite word. What this mint closes is the residual of the
-- #1047/#1265 family — #1047 (two modules declaring same-SPELLED interfaces) is
-- CLOSED, and #1265's own title records what was left: *"#1264 fixed only the
-- interface-NAME half"*, i.e. the TABLES were qualified and the ROUTE WORD was
-- not.  That word is what this module mints.
--
-- 🚨 THAT STAGING IS OVER. `B-2.2-e` + `B-2.2-b1` WIRED THE CALLERS UP: this
-- module is now imported by `types/typecheck.mdk` (the caller side of the
-- dict-word seam), `eval/eval.mdk` and `ir/core_ir_lower.mdk` (the definition
-- side), and it is the ONLY mint of an impl route word in the tree. The two
-- mirrors it replaced — `eval.implKeyOf` with its private `ppTyK` printer family,
-- and `typecheck.implKeyTc`'s hand-spelled body — are DELETED. Everything below
-- that reads as "available and applied nowhere" describes `a`'s landing and is
-- annotated where it is now false.
--
-- ⚠️ THE DESIGN DOC IS WRONG FOR THIS BITE, DELIBERATELY.
-- `.claude/sprint-b/design/D1-phase3-routes.md` §`B-2.2-a` says to change
-- `RKey`'s field to a two-component carrier (identity + word). That was
-- REFUSED in Phase 0 on a consumer-side derivation — `DECISIONS.md`
-- RUN-P3-019. The short form: `Route` crosses out of `types/` into `ir/`,
-- `backend/` and `eval/`, where the only namespaces that exist are `String`
-- symbol names and `hashName`'d i64 dict words; all 15 reading sites need the
-- WORD and none can consume an identity. So the identity belongs INSIDE the
-- word (content-derived), which is what `ifaceWordOf` does below.
-- `data Route` (`frontend/ast.mdk`) is unchanged and must stay so.
--
-- ── Why its OWN module, rather than an existing one ────────────────────────
-- Each of the four candidates was rejected for a reason that is a property of
-- the tree, not a preference:
--   * `types/typecheck.mdk` — `eval/eval.mdk` and `ir/core_ir_lower.mdk`
--     cannot import it, so siting the mint there would make it a THIRD
--     mirrored copy beside `implKeyTc` and `implKeyOf` — the P0-9 shape the
--     later bites exist to DELETE.
--   * `compiler/support/util.mdk` — `test/preflight.sh` maps
--     `compiler/support/*` onto its `mark_full` blast-radius arm, i.e. the
--     whole-suite run on every touch, forever.
--   * `compiler/frontend/ast.mdk` — imports NOTHING today
--     (`grep -Hn '^import' compiler/frontend/ast.mdk` → zero hits); the mint
--     needs `joinWith`/`escStr` from `support/util.mdk`, which would give the
--     zero-import base module its first import.
--   * inlining at each caller — that is the status quo this bite removes.
-- NO CYCLE: `frontend/ast.mdk` imports nothing, and `support/util.mdk` imports
-- only `support.ordmap`, `support.opcount`, `list`, `string` — not
-- `frontend.ast`. So `types/route_key.mdk` sits strictly BELOW `eval`,
-- `typecheck` and `core_ir_lower`, which is what lets all three reach it.
-- `compiler/types/registry.mdk` is the precedent for a new `types/` module
-- with exactly this import shape.
--
-- ── ⚠️ HISTORICAL, and no longer the verification story ───────────────────
-- The paragraph below was `a`'s: with the callers wired up this module is in
-- `medaka_cli.mdk`'s import closure, so `make medaka`, `make check-self` and
-- `test/typecheck_compiler_source.sh` all cover it now, and every gate that
-- grades a route word grades it. **Keep the `Makefile` `test:` line anyway** —
-- it is the only thing that RUNS the doctests below, which are the compatibility
-- pins (byte-identity with the pre-fold word on the absent-origin arm).
--
-- 🚨 "NO CALL SITES" ALSO MEANS "IN NO GATE" UNLESS SAID OTHERWISE, and that
-- is measured, not feared: `compiler/types/registry.mdk`'s header records the
-- 2026-08-03 measurement that a module outside every entry's import closure is
-- invisible to `make medaka`, to `make check-self`, and to
-- `test/typecheck_compiler_source.sh` (pass 1 walks
-- `compiler/driver/medaka_cli.mdk`, pass 2 covers `compiler/entries/*.mdk`;
-- this file is in neither) — with a deliberately broken body injected, both
-- reported PASS. So `Makefile`'s `test:` target names this module explicitly,
-- exactly as it names `registry.mdk`: `medaka test <file>` TYPECHECKS the file
-- before running its doctests, which puts both halves inside the required
-- `inlang` check. A later bite that lands a call-site-free module and forgets
-- that line has shipped unverified code with every gate green.
--
-- ── What the three exports are ────────────────────────────────────────────
-- `implRouteKeyWord` is BYTE-IDENTICAL to today's `implKeyTc`
-- (`types/typecheck.mdk`) and `implKeyOf` (`eval/eval.mdk`) whenever the
-- origin is absent, and carries `module::Iface` in place of the bare
-- interface name when it is not. ⚠️ That substitution is NOT #1182's fix — see
-- the header for the full retraction. It closes the ROUTE-WORD residual of the
-- #1047/#1265 family (two same-SPELLED interfaces in different modules
-- collapsing onto one word). `B-2.2-b1` APPLIES it, at
-- `keyForSite`/`keyForSiteByIface`.
--
-- `routeWordFor` is `core_ir_lower.declRouteKey`'s body and the
-- `if ieHeadCollidesBy… then implKeyTc … else headKeyNameOr …` shape of
-- `keyForSite`/`keyForSiteByIface` (`types/typecheck.mdk`), unified — the
-- caller supplies the collision verdict and the bare head tag, both of which
-- are computed from tables this module cannot see.
--
-- `rkTy`/`rkTyFunArg`/`rkTyAtom` are ONE prec-2 `Ty` printer, the eventual
-- single replacement for the mirrored `ppTyAtom` (`types/typecheck.mdk`) and
-- `ppTyAtomK` (`eval/eval.mdk`).
--
-- 🚨 THE TWO ORIGINALS ARE NOW DELETED (`B-2.2-e`), AND THEY DIVERGED OFF THE
-- REACHABLE SUBSET, so the collapse WIDENED eval's words. The divergence, kept
-- because it is what the fold changed and a future reader needs to know which
-- direction it moved:
--   * `TyEffect effs tail t` — typecheck prints `<row> t`; eval prints `t`,
--     dropping the row entirely.
--   * `TyConstrained cs t`   — typecheck prints `cs => t`; eval prints `t`.
--   * `TyRow`                — both print `<row>`; these agree.
-- `rkTy` is based on typecheck's `ppTy`/`ppTyAtom`, the MORE COMPLETE of the
-- two, so adopting it at eval's callers WIDENED eval's words for the two rows
-- above: two impls differing only in an effect row or a constraint used to
-- collapse onto one `implKeyOf` word there and no longer do.
-- ✅ MEASURED SAFE, and this is the derivation rather than the assertion: a
-- program that could OBSERVE the collapse does not typecheck. `impl Sz Int`
-- beside `impl Sz (<Stdout> Int)` — and `impl Sz a` beside `impl Sz (Eq a => a)`
-- — are both rejected by coherence at exit 1 on `check` AND `run`, with a
-- diagnostic that STRIPS the row itself (*"Overlapping impls of Sz: Int and Int
-- can match the same type"*). So no accepted program has two impls differing
-- only on that axis, and the widening cannot separate two words that any
-- accepted program's routes depended on being equal.

-- `constraintUnresolved` is reached ONLY from the `TyConstrained` doctests
-- below (it is `Constraint`'s one legal mint for an unstamped occurrence).
-- Deleting it as unused fails at doctest RUN time, not at `check`.
import frontend.ast.{
  Ty(..),
  Constraint(..),
  TyConOrigin(..),
  Route,
  EvId(..),
  EvVal(..),
  EvEntry(..),
  EvTable,
  constraintUnresolved,
  ifaceIdentity,
}
import support.util.{joinWith, escStr}

-- ── the published evidence table (#2549 M2) ───────────────────────────────
-- `EDictAt` carries an `EvId`, not a route cell, so a reader answers "what did
-- the solver decide here" by looking the id up rather than by dereferencing a
-- pointer the typechecker handed it.  The lookup lives HERE because this module
-- is the one below all three readers of a solved route — `types/typecheck.mdk`
-- (dict passing), `eval/eval.mdk` and `ir/core_ir_lower.mdk` — exactly the three
-- the header above names as this seam's consumers.  A cell inside any one of
-- them would be unreachable from the other two, and `frontend/ast.mdk` (the only
-- lower module) imports nothing and holds no state.
--
-- The table is INSTALLED once per elaboration by the module that produces it, so
-- there is no per-driver install to forget; `evidenceRef` holding `None` means no
-- elaboration has run, which is why the lookup panics on it rather than answering
-- "no routes" — a driver that grew an `EDictAt` without an elaboration would
-- otherwise dispatch on an empty route list and be wrong in silence.
--
-- The index is an ARRAY over the id's ordinal, not a scan of the spine: the table
-- has one entry per solver goal (838 on a four-file fixture), so a per-site linear
-- scan would be the List-as-a-map quadratic `compiler/AGENTS.md` records thirteen
-- instances of.  Ordinals are dense and graph-global (see `freshEvId`), so the
-- ordinal IS the index; the id's MODULE half is still compared on every hit, so a
-- cross-module ordinal collision is a panic and not a wrong answer.
evidenceRef : Ref (Option (Array (Option EvEntry)))
evidenceRef = Ref None

-- Replace the installed evidence with this elaboration's.  Called once per
-- elaboration, so the table never outlives the program it describes.
export
installEvidence : EvTable -> Unit
installEvidence entries =
  let arr = arrayMake (evSlotCount entries 0) None
  let _ = fillEvidence arr entries
  evidenceRef := Some arr

-- one past the largest ordinal in [entries]
evSlotCount : EvTable -> Int -> Int
evSlotCount [] acc = acc
evSlotCount ((EvEntry (EvId _ i) _) :: rest) acc =
  evSlotCount rest (max (i + 1) acc)

-- Two entries under one ordinal would mean two goals published under one name,
-- and the reader below could then answer with either.  The cell scheme this
-- replaces could not express that (one node, one cell), so it is a tripwire
-- rather than a case with a policy: no program in the gate corpus, the 59-fixture
-- module arm, or the compiler's own self-compile reaches it.
fillEvidence : Array (Option EvEntry) -> EvTable -> Unit
fillEvidence _ [] = ()
fillEvidence arr ((e@(EvEntry (EvId m i) _)) :: rest) =
  let _ = match arrayGetUnsafe i arr
    None => arraySetUnsafe i (Some e) arr
    Some _ =>
      panic "evidence table: two goals published under \{m}#\{intToString i}"
  fillEvidence arr rest

-- The dictionary routes solved for [ev], slot-ordered.
--
-- An id with NO entry is EMPTY, not an error: a constrained-function occurrence
-- whose callee turns out to need no dict routing records no goal at all (the #739
-- bare-name-collision arm of `inferDictAtFound` returns without pushing one), and
-- the cell scheme answered that case with the untouched `Ref []` this returns.
export
evDictRoutes : EvId -> List Route
evDictRoutes (EvId m i) = match !evidenceRef
  None =>
    panic
      "evidence table: no elaboration has published one (looking up \{m}#\{intToString i})"
  Some arr =>
    if i >= arrayLength arr then
      []
    else match arrayGetUnsafe i arr
      None => []
      Some (EvEntry (EvId m2 _) v) =>
        if m2 == m then
          evRoutesOf v
        else
          panic "evidence table: \{m}#\{intToString i} answered by module \{m2}"

evRoutesOf : EvVal -> List Route
evRoutesOf (EvMany rs) = rs
evRoutesOf (EvOne _) =
  panic "evidence table: a dictionary application solved to a single route"

-- ── the interface half of the word ────────────────────────────────────────
-- `module::Iface` when the interface's origin is known, and the BARE name when
-- it is not.
--
-- 🚨 THE FALLBACK IS THE WHOLE POINT OF THIS FUNCTION — DO NOT DELETE IT AS
-- REDUNDANT. `ifaceIdentity` answers `""` on both loader-less arms
-- (`OriginUnresolved`, `OriginBuiltin`) and the tree states that `""` IS
-- ABSENCE, NOT AN IDENTITY (`frontend/ast.mdk`, `ifaceIdentity`'s own
-- doc-comment; `ifaceIdMatches` is the ONLY legal comparison on two of these
-- strings and absence never matches even itself). The flat drivers
-- deliberately stamp no origin, so a word built from a RAW `ifaceIdentity`
-- would spell `"|T|"` for EVERY interface under `medaka check <single file>`,
-- lsp, repl, doc, lint and snapshot — collapsing onto one word the instances
-- that the present bare-name word keeps apart. That is a silent-wrongness
-- regression, and it would be invisible to any golden that only exercises the
-- module path.
--
-- ⚠️ THE PROPERTY THE FALLBACK RESTS ON, stated because this is precisely
-- where a silent collapse would live: the bare-name arm is safe only because
-- two same-spelled interfaces cannot both have absent origins AND be in scope
-- together — the flat path is ONE module and therefore one namespace, and
-- cross-module the origins are stamped. A future change that lets a
-- loader-less driver see two modules at once breaks that premise, and this is
-- the line it breaks.
export
ifaceWordOf : TyConOrigin -> String -> String
ifaceWordOf o name = match ifaceIdentity o name
  "" => name
  ident => ident

-- ── the FUNCTION head tag ─────────────────────────────────────────────────
-- The dispatch/impl-tag of an ARROW-headed impl (`impl Sz (Int -> Int)`) —
-- #1617.  Sited HERE, beside the route word, for the reason this module exists
-- at all: the tag is derived independently on three sides of the seam
-- (`typecheck.headTyconTy`/`headTyconMono`, `eval.headTycon`, and through the
-- latter `core_ir_lower.headTyconHead`), and a mirrored constant is exactly the
-- drift `tupleHeadTag`/`tupleHeadTagTc` still carries.  One mint, three readers.
--
-- 🚨 IT IS DELIBERATELY ARITY-FREE, and that is the opposite of the nearest
-- precedent (`tupleHeadTag n = "__tuple<n>__"`), so the divergence is derived
-- rather than assumed.  A tuple's arity is the ONLY thing that separates
-- `(Int, Int)` from `(Int, Int, Int)` at the head, and the runtime cell carries
-- it (`HTuple`), so an arity-erased tuple tag coalesced impls that a value could
-- still be told apart by.  An arrow has NO runtime tag at all (a closure carries
-- no cell tag — that is the very E-PANIC #1617 reports on `build`), and its arity
-- does not separate the pair the bug is about: `Int -> Int` and `Bool -> Bool`
-- are both arity-1.  So NO tag drawn from an arrow's shape can discriminate two
-- arrow-headed impls, and the discrimination has to come — and already does come
-- — from `implRouteKeyWord` above, which prints the FULL type args.  The single
-- tag's job is only to make the two impls COLLIDE, because a collision is
-- precisely what makes `routeWordFor`/`keyForSite` upgrade the site to that
-- canonical word.  This is the same mechanism `Pair Int Bool` vs `Pair Bool Int`
-- already rides (`KeyEntry`'s C7 note, `types/typecheck.mdk`), not a new one.
export
funHeadTag : String
funHeadTag = "__fun__"

-- ── the impl route word ───────────────────────────────────────────────────
-- `<iface word>|<type args, prec-2, space-joined>|<method name or empty>`.
--
-- Built from the same source (an impl's AST type args) on BOTH sides of the
-- seam — the definition side at install time and the caller side at each
-- ground `RKey` route site — so the two strings agree BY CONSTRUCTION rather
-- than by two mirrored implementations happening to stay in lockstep. Two
-- impls sharing a head tycon but differing in type args (`Pair Int Bool` vs
-- `Pair Bool Int`) get DISTINCT words, which is what lets narrowing pick the
-- impl the typechecker chose instead of falling back to first-impl-wins.
--
-- ⚠️ The `|` separators are NOT collision-free the way `support/util.mdk`'s
-- `lenKey` netstrings are; this is the EXISTING wire format, reproduced
-- verbatim, because its consumers in `ir/`, `backend/` and `eval/` are plain
-- `String` namespaces that already carry it. Changing the format is a
-- different bite with a different blast radius.
export
implRouteKeyWord : TyConOrigin -> String -> List Ty -> Option String -> String
implRouteKeyWord o iface tys nm =
  "\{ifaceWordOf o iface}|\{joinWith " " (map rkTyAtom tys)}|\{optionOr "" nm}"

-- ── the route word a SITE gets ───────────────────────────────────────────
-- [headIsUnique] is the caller's collision verdict — "is this head the head of
-- exactly ONE declared impl of this interface?" — and [tag] the bare head
-- tycon word to use when it is. Unique head ⇒ the bare tag, exactly as today;
-- otherwise the canonical impl word, which is the only thing that can tell two
-- impls at one head apart.
--
-- ⚠️ THE VERDICT IS AN ARGUMENT ON PURPOSE. Both existing spellings compute it
-- from a table this module cannot see and must not acquire — `ifaceImplHeadsRef`
-- in `ir/core_ir_lower.mdk` (`ifaceDeclHeadUnique`) and the `IE` in
-- `types/typecheck.mdk` (`ieHeadCollidesByMethod`/`…ByIface`, whose sense is
-- INVERTED relative to this parameter: it answers "collides", this answers
-- "unique"). Unifying those two populations is not this bite's business; what
-- is unified here is the WORD each produces once it has its verdict.
export
routeWordFor : Bool -> String -> TyConOrigin -> String -> List Ty -> String
routeWordFor headIsUnique tag o iface tys =
  if headIsUnique then tag else implRouteKeyWord o iface tys None

-- ── the ONE prec-2 `Ty` printer ──────────────────────────────────────────
-- Mirrors `types/typecheck.mdk`'s `ppTy` family byte-for-byte (which in turn
-- mirrors the retired OCaml `pp_ty_prec`): `rkTy` is prec 0, `rkTyFunArg`
-- prec 1 (wraps arrows), `rkTyAtom` prec 2 (wraps arrows AND applications).
--
-- `tyConOrigin` is deliberately NOT rendered: the identity that this bite
-- threads into a route word is the INTERFACE's (see `ifaceWordOf`), and a type
-- ARGUMENT's origin is a separate question with its own consumers. Rendering
-- it here would change every word for every program at once.
rkTy : Ty -> String
rkTy (TyCon { tyConName = n }) = n
rkTy (TyVar n) = n
rkTy (TyApp a b) = "\{rkTy a} \{rkTyAtom b}"
rkTy (TyFun a b) = "\{rkTyFunArg a} -> \{rkTy b}"
rkTy (TyTuple ts) = "(" ++ joinWith ", " (map rkTy ts) ++ ")"
rkTy (TyEffect effs tail t) = "<\{rkRowBody effs tail}> \{rkTy t}"
-- A bare row atom (#997) wraps no type, so there is nothing to fall back to.
rkTy (TyRow effs tail _) = "<\{rkRowBody effs tail}>"
rkTy (TyConstrained cs t) = "\{rkConstraints cs} => \{rkTy t}"

-- argument of `->`: wrap `TyFun` (prec ≥ 1) but not `TyApp` (prec < 2).
rkTyFunArg : Ty -> String
rkTyFunArg (TyFun a b) = "(" ++ rkTy (TyFun a b) ++ ")"
rkTyFunArg t = rkTy t

-- argument of an application: wrap `TyFun` and `TyApp` (both prec ≥ 2).
rkTyAtom : Ty -> String
rkTyAtom (TyFun a b) = "(" ++ rkTy (TyFun a b) ++ ")"
rkTyAtom (TyApp a b) = "(" ++ rkTy (TyApp a b) ++ ")"
rkTyAtom t = rkTy t

-- shared `<…>` row-body renderer for the `TyEffect`/`TyRow` arms above.
rkRowBody : List (String, Option String) -> List String -> String
rkRowBody effs [] = joinWith ", " (map rkEffAtom effs)
rkRowBody [] tails = joinWith " | " tails
rkRowBody effs tails =
  "\{joinWith ", " (map rkEffAtom effs)} | \{joinWith " | " tails}"

-- One effect atom, with its optional domain parameter. The domain IS part of
-- what a written row means, so it is kept: dropping it would collide
-- `Net "a/*"` and `Net "b/*"` onto one word.
--
-- 🚨 `a` LEFT THIS DIRECTIVE MARKED "TRANSITIONAL, `B-2.2-e` OWNS DELETING IT".
-- `e` LANDED AND REFUSED TO DELETE IT, because the premise was wrong: `e` deletes
-- `eval.mdk`'s copy (`ppEffAtomK`, which only `implKeyOf` reached), but
-- `types/typecheck.mdk`'s `ppEffAtomTy` and `tools/doc.mdk`'s `ppEffAtomDoc` are
-- reached by the DIAGNOSTIC printers, which `e` does not touch — so this copy
-- does NOT become the only one; it becomes one of THREE.  MEASURED, not reasoned:
-- with the directive removed,
--   medaka lint --only=rule-duplicate-body --deny=rule-duplicate-body \
--     compiler stdlib sqlite
-- exits 1 with *"'rkEffAtom' has a body structurally identical to a definition in
-- compiler/tools/doc.mdk, compiler/types/typecheck.mdk"*.  The directive stays
-- until someone folds the DIAGNOSTIC printers too, which is a different bite with
-- a different blast radius (every error message that renders a type).
--
-- 🚨 PLACEMENT IS LOAD-BEARING, and the diagnostic's own line number misleads.
-- `-- lint-disable-next-line rule-duplicate-body` must sit immediately above
-- THE SPECIFIC DUPLICATED EQUATION (here the `Some s` arm, exactly as
-- `eval.mdk` places its copy).  Above the signature, or above the first
-- equation, it does NOT suppress — measured, three placements, same command:
--   medaka lint --only=rule-duplicate-body --deny=rule-duplicate-body \
--     compiler stdlib sqlite
-- The finding is REPORTED at the declaration's first line, which is a
-- decl-level anchor and NOT the line the directive is matched against; putting
-- the directive where the diagnostic points is the natural move and it fails.
rkEffAtom : (String, Option String) -> String
rkEffAtom (l, None) = l
-- lint-disable-next-line rule-duplicate-body
rkEffAtom (l, Some s) = if s == "_" then l ++ " _" else "\{l} \{escStr s}"

-- single constraint: no outer parens; multiple: parenthesised.
rkConstraints : List Constraint -> String
rkConstraints [c] = rkConstraint c
rkConstraints cs = "(" ++ joinWith ", " (map rkConstraint cs) ++ ")"

rkConstraint : Constraint -> String
rkConstraint (Constraint { constraintHead = iface, constraintArgs = [] }) =
  iface
rkConstraint (Constraint { constraintHead = iface, constraintArgs = tys }) =
  "\{iface} \{joinWith " " (map rkTyAtom tys)}"

-- ── doctests ─────────────────────────────────────────────────────────────
-- 🚨 THESE ARE THE ONLY THING THAT RUNS THIS MODULE (see the header): with no
-- call sites, `make medaka`, `make check-self` and
-- `test/typecheck_compiler_source.sh` are all blind to it. Deleting the
-- `Makefile` `test:` line that names this file would silently un-run every
-- assertion below.

-- Fixtures. `rkTyInt`/`rkTyBool` are the unresolved-origin `TyCon`s a flat
-- driver builds; `rkTyIntM` is the same head with a module origin stamped, and
-- it renders IDENTICALLY — pinning that a type argument's origin is not in the
-- word (see `rkTy`'s doc-comment).
rkTyInt : Ty
rkTyInt =
  TyCon { tyConName = "Int", tyConLoc = None, tyConOrigin = OriginUnresolved }

rkTyBool : Ty
rkTyBool =
  TyCon { tyConName = "Bool", tyConLoc = None, tyConOrigin = OriginUnresolved }

rkTyIntM : Ty
rkTyIntM =
  TyCon { tyConName = "Int", tyConLoc = None, tyConOrigin = OriginModule "m" }

rkTyList : Ty
rkTyList =
  TyCon { tyConName = "List", tyConLoc = None, tyConOrigin = OriginUnresolved }

-- `ifaceWordOf`: the module arm qualifies, and BOTH absent arms fall back to
-- the bare name rather than to `""`. The last two lines are the ones that red
-- if the fallback is deleted — without it they would both read `""`, i.e. the
-- every-interface-collapses-to-one-word regression the doc-comment describes.
-- > ifaceWordOf (OriginModule "b") "Speak"
-- "b::Speak"
-- > ifaceWordOf OriginUnresolved "Speak"
-- "Speak"
-- > ifaceWordOf OriginBuiltin "Speak"
-- "Speak"

-- Two DIFFERENT modules declaring the same interface name stay apart…
-- > ifaceWordOf (OriginModule "a") "Speak" == ifaceWordOf (OriginModule "b") "Speak"
-- False

-- …and the bare arm is NOT equal to any qualified one, so a stamped and an
-- unstamped occurrence never silently share a word.
-- > ifaceWordOf OriginUnresolved "Speak" == ifaceWordOf (OriginModule "a") "Speak"
-- False

-- `implRouteKeyWord`, origin ABSENT: byte-identical to what `implKeyTc` and
-- `implKeyOf` produce today. These are the compatibility pins — if one of them
-- moves, the mint is no longer a drop-in for the two originals.
-- > implRouteKeyWord OriginUnresolved "Show" [rkTyInt] None
-- "Show|Int|"
-- > implRouteKeyWord OriginUnresolved "Show" [] None
-- "Show||"
-- > implRouteKeyWord OriginUnresolved "Show" [rkTyInt] (Some "show")
-- "Show|Int|show"
-- > implRouteKeyWord OriginUnresolved "Pair" [rkTyInt, rkTyBool] None
-- "Pair|Int Bool|"

-- Argument ORDER is preserved, which is what keeps `Pair Int Bool` and
-- `Pair Bool Int` on distinct words.
-- > implRouteKeyWord OriginUnresolved "P" [rkTyInt, rkTyBool] None == implRouteKeyWord OriginUnresolved "P" [rkTyBool, rkTyInt] None
-- False

-- An APPLIED argument is parenthesised (prec 2), so `Show (List Int)` cannot
-- be confused with a two-argument impl.
-- > implRouteKeyWord OriginUnresolved "Show" [TyApp rkTyList rkTyInt] None
-- "Show|(List Int)|"
-- > implRouteKeyWord OriginUnresolved "Show" [TyApp rkTyList rkTyInt] None == implRouteKeyWord OriginUnresolved "Show" [rkTyList, rkTyInt] None
-- False

-- A type argument's own origin is NOT in the word.
-- > implRouteKeyWord OriginUnresolved "Show" [rkTyIntM] None == implRouteKeyWord OriginUnresolved "Show" [rkTyInt] None
-- True

-- `implRouteKeyWord`, origin PRESENT: the #1047/#1265 route-word substitution
-- (NOT #1182 — see the header). Applied by `B-2.2-b1` at `keyForSite`.
-- > implRouteKeyWord (OriginModule "b") "Speak" [rkTyInt] None
-- "b::Speak|Int|"
-- > implRouteKeyWord (OriginModule "a") "Speak" [rkTyInt] None == implRouteKeyWord (OriginModule "b") "Speak" [rkTyInt] None
-- False

-- `routeWordFor`: unique head ⇒ the caller's bare tag verbatim; colliding head
-- ⇒ the canonical impl word, with the method slot empty.
-- > routeWordFor True "Int" OriginUnresolved "Show" [rkTyInt]
-- "Int"
-- > routeWordFor False "Int" OriginUnresolved "Show" [rkTyInt]
-- "Show|Int|"
-- > routeWordFor False "Int" OriginUnresolved "Show" [rkTyInt] == implRouteKeyWord OriginUnresolved "Show" [rkTyInt] None
-- True

-- The unique arm ignores the interface entirely — that is `declRouteKey`'s
-- existing behaviour, reproduced, not a new one.
-- > routeWordFor True "Int" (OriginModule "b") "Speak" [rkTyBool]
-- "Int"

-- The `Ty` printer, at the three precedences. `rkTyAtom` wraps an application
-- and an arrow; `rkTy` wraps neither.
-- > rkTy (TyApp rkTyList rkTyInt)
-- "List Int"
-- > rkTyAtom (TyApp rkTyList rkTyInt)
-- "(List Int)"
-- > rkTy (TyFun rkTyInt rkTyBool)
-- "Int -> Bool"
-- > rkTyAtom (TyFun rkTyInt rkTyBool)
-- "(Int -> Bool)"

-- Right-associativity of `->` is visible: the LEFT argument of an arrow is
-- parenthesised, the right is not.
-- > rkTy (TyFun (TyFun rkTyInt rkTyBool) rkTyInt)
-- "(Int -> Bool) -> Int"
-- > rkTy (TyFun rkTyInt (TyFun rkTyBool rkTyInt))
-- "Int -> Bool -> Int"

-- An application is NOT parenthesised in an arrow argument (prec 1 < 2).
-- > rkTy (TyFun (TyApp rkTyList rkTyInt) rkTyBool)
-- "List Int -> Bool"
-- > rkTy (TyVar "a")
-- "a"
-- > rkTy (TyTuple [rkTyInt, rkTyBool])
-- "(Int, Bool)"

-- The three arms where this printer is the COMPLETE one and `eval`'s
-- `ppTyAtomK` is not (see the header). These assertions are the record of what
-- a later bite's caller collapse would change on the eval side.
-- > rkTy (TyEffect [("Stdout", None)] [] rkTyInt)
-- "<Stdout> Int"
-- > rkTy (TyRow [("Stdout", None)] [] None)
-- "<Stdout>"
-- > rkTy (TyRow [("Stdout", None), ("Rand", None)] [] None)
-- "<Stdout, Rand>"
-- > rkTy (TyRow [] ["e"] None)
-- "<e>"
-- > rkTy (TyRow [("Stdout", None)] ["e"] None)
-- "<Stdout | e>"

-- A domain parameter is kept, so two rows differing only by domain do not
-- collide onto one word.
-- > rkTy (TyRow [("Net", Some "a/*")] [] None) == rkTy (TyRow [("Net", Some "b/*")] [] None)
-- False
-- > rkTy (TyRow [("Net", Some "_")] [] None)
-- "<Net _>"

-- A constraint prefix: bare for one, parenthesised for two.
-- > rkTy (TyConstrained [constraintUnresolved "Eq" [TyVar "a"]] (TyVar "a"))
-- "Eq a => a"
-- > rkTy (TyConstrained [constraintUnresolved "Eq" [], constraintUnresolved "Ord" [TyVar "a"]] (TyVar "a"))
-- "(Eq, Ord a) => a"

-- Two impls differing ONLY in an effect row get distinct words here — the
-- property eval's printer does not have today.
-- > implRouteKeyWord OriginUnresolved "A" [TyEffect [("Stdout", None)] [] rkTyInt] None == implRouteKeyWord OriginUnresolved "A" [TyEffect [("Rand", None)] [] rkTyInt] None
-- False
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Ty" true) (mem "Constraint" true) (mem "TyConOrigin" true) (mem "Route" false) (mem "EvId" true) (mem "EvVal" true) (mem "EvEntry" true) (mem "EvTable" false) (mem "constraintUnresolved" false) (mem "ifaceIdentity" false))))
(DUse false (UseGroup ("support" "util") ((mem "joinWith" false) (mem "escStr" false))))
(DTypeSig false "evidenceRef" (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyApp (TyCon "Array") (TyApp (TyCon "Option") (TyCon "EvEntry"))))))
(DFunDef false "evidenceRef" () (EApp (EVar "Ref") (EVar "None")))
(DTypeSig true "installEvidence" (TyFun (TyCon "EvTable") (TyCon "Unit")))
(DFunDef false "installEvidence" ((PVar "entries")) (EBlock (DoLet false false (PVar "arr") (EApp (EApp (EVar "arrayMake") (EApp (EApp (EVar "evSlotCount") (EVar "entries")) (ELit (LInt 0)))) (EVar "None"))) (DoLet false false PWild (EApp (EApp (EVar "fillEvidence") (EVar "arr")) (EVar "entries"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "evidenceRef")) (EApp (EVar "Some") (EVar "arr"))))))
(DTypeSig false "evSlotCount" (TyFun (TyCon "EvTable") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "evSlotCount" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "evSlotCount" ((PCons (PCon "EvEntry" (PCon "EvId" PWild (PVar "i")) PWild) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "evSlotCount") (EVar "rest")) (EApp (EApp (EVar "max") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "acc"))))
(DTypeSig false "fillEvidence" (TyFun (TyApp (TyCon "Array") (TyApp (TyCon "Option") (TyCon "EvEntry"))) (TyFun (TyCon "EvTable") (TyCon "Unit"))))
(DFunDef false "fillEvidence" (PWild (PList)) (ELit LUnit))
(DFunDef false "fillEvidence" ((PVar "arr") (PCons (PAs "e" (PCon "EvEntry" (PCon "EvId" (PVar "m") (PVar "i")) PWild)) (PVar "rest"))) (EBlock (DoLet false false PWild (EMatch (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (arm (PCon "None") () (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "i")) (EApp (EVar "Some") (EVar "e"))) (EVar "arr"))) (arm (PCon "Some" PWild) () (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "evidence table: two goals published under ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString "#"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ""))))))) (DoExpr (EApp (EApp (EVar "fillEvidence") (EVar "arr")) (EVar "rest")))))
(DTypeSig true "evDictRoutes" (TyFun (TyCon "EvId") (TyApp (TyCon "List") (TyCon "Route"))))
(DFunDef false "evDictRoutes" ((PCon "EvId" (PVar "m") (PVar "i"))) (EMatch (EUnOp "!" (EVar "evidenceRef")) (arm (PCon "None") () (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "evidence table: no elaboration has published one (looking up ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString "#"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ")"))))) (arm (PCon "Some" (PVar "arr")) () (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr"))) (EListLit) (EMatch (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PCon "EvEntry" (PCon "EvId" (PVar "m2") PWild) (PVar "v"))) () (EIf (EBinOp "==" (EVar "m2") (EVar "m")) (EApp (EVar "evRoutesOf") (EVar "v")) (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "evidence table: ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString "#"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString " answered by module "))) (EApp (EVar "display") (EVar "m2"))) (ELit (LString "")))))))))))
(DTypeSig false "evRoutesOf" (TyFun (TyCon "EvVal") (TyApp (TyCon "List") (TyCon "Route"))))
(DFunDef false "evRoutesOf" ((PCon "EvMany" (PVar "rs"))) (EVar "rs"))
(DFunDef false "evRoutesOf" ((PCon "EvOne" PWild)) (EApp (EVar "panic") (ELit (LString "evidence table: a dictionary application solved to a single route"))))
(DTypeSig true "ifaceWordOf" (TyFun (TyCon "TyConOrigin") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "ifaceWordOf" ((PVar "o") (PVar "name")) (EMatch (EApp (EApp (EVar "ifaceIdentity") (EVar "o")) (EVar "name")) (arm (PLit (LString "")) () (EVar "name")) (arm (PVar "ident") () (EVar "ident"))))
(DTypeSig true "funHeadTag" (TyCon "String"))
(DFunDef false "funHeadTag" () (ELit (LString "__fun__")))
(DTypeSig true "implRouteKeyWord" (TyFun (TyCon "TyConOrigin") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyCon "String"))))))
(DFunDef false "implRouteKeyWord" ((PVar "o") (PVar "iface") (PVar "tys") (PVar "nm")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EApp (EVar "ifaceWordOf") (EVar "o")) (EVar "iface")))) (ELit (LString "|"))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EVar "map") (EVar "rkTyAtom")) (EVar "tys"))))) (ELit (LString "|"))) (EApp (EVar "display") (EApp (EApp (EVar "optionOr") (ELit (LString ""))) (EVar "nm")))) (ELit (LString ""))))
(DTypeSig true "routeWordFor" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "TyConOrigin") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyCon "String")))))))
(DFunDef false "routeWordFor" ((PVar "headIsUnique") (PVar "tag") (PVar "o") (PVar "iface") (PVar "tys")) (EIf (EVar "headIsUnique") (EVar "tag") (EApp (EApp (EApp (EApp (EVar "implRouteKeyWord") (EVar "o")) (EVar "iface")) (EVar "tys")) (EVar "None"))))
(DTypeSig false "rkTy" (TyFun (TyCon "Ty") (TyCon "String")))
(DFunDef false "rkTy" ((PRec "TyCon" ((rf "tyConName" (PVar "n"))) false)) (EVar "n"))
(DFunDef false "rkTy" ((PCon "TyVar" (PVar "n"))) (EVar "n"))
(DFunDef false "rkTy" ((PCon "TyApp" (PVar "a") (PVar "b"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "rkTy") (EVar "a")))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EVar "rkTyAtom") (EVar "b")))) (ELit (LString ""))))
(DFunDef false "rkTy" ((PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "rkTyFunArg") (EVar "a")))) (ELit (LString " -> "))) (EApp (EVar "display") (EApp (EVar "rkTy") (EVar "b")))) (ELit (LString ""))))
(DFunDef false "rkTy" ((PCon "TyTuple" (PVar "ts"))) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "map") (EVar "rkTy")) (EVar "ts")))) (ELit (LString ")"))))
(DFunDef false "rkTy" ((PCon "TyEffect" (PVar "effs") (PVar "tail") (PVar "t"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "<")) (EApp (EVar "display") (EApp (EApp (EVar "rkRowBody") (EVar "effs")) (EVar "tail")))) (ELit (LString "> "))) (EApp (EVar "display") (EApp (EVar "rkTy") (EVar "t")))) (ELit (LString ""))))
(DFunDef false "rkTy" ((PCon "TyRow" (PVar "effs") (PVar "tail") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "<")) (EApp (EVar "display") (EApp (EApp (EVar "rkRowBody") (EVar "effs")) (EVar "tail")))) (ELit (LString ">"))))
(DFunDef false "rkTy" ((PCon "TyConstrained" (PVar "cs") (PVar "t"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "rkConstraints") (EVar "cs")))) (ELit (LString " => "))) (EApp (EVar "display") (EApp (EVar "rkTy") (EVar "t")))) (ELit (LString ""))))
(DTypeSig false "rkTyFunArg" (TyFun (TyCon "Ty") (TyCon "String")))
(DFunDef false "rkTyFunArg" ((PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EVar "rkTy") (EApp (EApp (EVar "TyFun") (EVar "a")) (EVar "b")))) (ELit (LString ")"))))
(DFunDef false "rkTyFunArg" ((PVar "t")) (EApp (EVar "rkTy") (EVar "t")))
(DTypeSig false "rkTyAtom" (TyFun (TyCon "Ty") (TyCon "String")))
(DFunDef false "rkTyAtom" ((PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EVar "rkTy") (EApp (EApp (EVar "TyFun") (EVar "a")) (EVar "b")))) (ELit (LString ")"))))
(DFunDef false "rkTyAtom" ((PCon "TyApp" (PVar "a") (PVar "b"))) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EVar "rkTy") (EApp (EApp (EVar "TyApp") (EVar "a")) (EVar "b")))) (ELit (LString ")"))))
(DFunDef false "rkTyAtom" ((PVar "t")) (EApp (EVar "rkTy") (EVar "t")))
(DTypeSig false "rkRowBody" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))
(DFunDef false "rkRowBody" ((PVar "effs") (PList)) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "map") (EVar "rkEffAtom")) (EVar "effs"))))
(DFunDef false "rkRowBody" ((PList) (PVar "tails")) (EApp (EApp (EVar "joinWith") (ELit (LString " | "))) (EVar "tails")))
(DFunDef false "rkRowBody" ((PVar "effs") (PVar "tails")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "map") (EVar "rkEffAtom")) (EVar "effs"))))) (ELit (LString " | "))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString " | "))) (EVar "tails")))) (ELit (LString ""))))
(DTypeSig false "rkEffAtom" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyCon "String")))
(DFunDef false "rkEffAtom" ((PTuple (PVar "l") (PCon "None"))) (EVar "l"))
(DFunDef false "rkEffAtom" ((PTuple (PVar "l") (PCon "Some" (PVar "s")))) (EIf (EBinOp "==" (EVar "s") (ELit (LString "_"))) (EBinOp "++" (EVar "l") (ELit (LString " _"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "l"))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EVar "escStr") (EVar "s")))) (ELit (LString "")))))
(DTypeSig false "rkConstraints" (TyFun (TyApp (TyCon "List") (TyCon "Constraint")) (TyCon "String")))
(DFunDef false "rkConstraints" ((PList (PVar "c"))) (EApp (EVar "rkConstraint") (EVar "c")))
(DFunDef false "rkConstraints" ((PVar "cs")) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "map") (EVar "rkConstraint")) (EVar "cs")))) (ELit (LString ")"))))
(DTypeSig false "rkConstraint" (TyFun (TyCon "Constraint") (TyCon "String")))
(DFunDef false "rkConstraint" ((PRec "Constraint" ((rf "constraintHead" (PVar "iface")) (rf "constraintArgs" (PList))) false)) (EVar "iface"))
(DFunDef false "rkConstraint" ((PRec "Constraint" ((rf "constraintHead" (PVar "iface")) (rf "constraintArgs" (PVar "tys"))) false)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "iface"))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EVar "map") (EVar "rkTyAtom")) (EVar "tys"))))) (ELit (LString ""))))
(DTypeSig false "rkTyInt" (TyCon "Ty"))
(DFunDef false "rkTyInt" () (ERecordCreate "TyCon" ((fa "tyConName" (ELit (LString "Int"))) (fa "tyConLoc" (EVar "None")) (fa "tyConOrigin" (EVar "OriginUnresolved")))))
(DTypeSig false "rkTyBool" (TyCon "Ty"))
(DFunDef false "rkTyBool" () (ERecordCreate "TyCon" ((fa "tyConName" (ELit (LString "Bool"))) (fa "tyConLoc" (EVar "None")) (fa "tyConOrigin" (EVar "OriginUnresolved")))))
(DTypeSig false "rkTyIntM" (TyCon "Ty"))
(DFunDef false "rkTyIntM" () (ERecordCreate "TyCon" ((fa "tyConName" (ELit (LString "Int"))) (fa "tyConLoc" (EVar "None")) (fa "tyConOrigin" (EApp (EVar "OriginModule") (ELit (LString "m")))))))
(DTypeSig false "rkTyList" (TyCon "Ty"))
(DFunDef false "rkTyList" () (ERecordCreate "TyCon" ((fa "tyConName" (ELit (LString "List"))) (fa "tyConLoc" (EVar "None")) (fa "tyConOrigin" (EVar "OriginUnresolved")))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Ty" true) (mem "Constraint" true) (mem "TyConOrigin" true) (mem "Route" false) (mem "EvId" true) (mem "EvVal" true) (mem "EvEntry" true) (mem "EvTable" false) (mem "constraintUnresolved" false) (mem "ifaceIdentity" false))))
(DUse false (UseGroup ("support" "util") ((mem "joinWith" false) (mem "escStr" false))))
(DTypeSig false "evidenceRef" (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyApp (TyCon "Array") (TyApp (TyCon "Option") (TyCon "EvEntry"))))))
(DFunDef false "evidenceRef" () (EApp (EVar "Ref") (EVar "None")))
(DTypeSig true "installEvidence" (TyFun (TyCon "EvTable") (TyCon "Unit")))
(DFunDef false "installEvidence" ((PVar "entries")) (EBlock (DoLet false false (PVar "arr") (EApp (EApp (EVar "arrayMake") (EApp (EApp (EVar "evSlotCount") (EVar "entries")) (ELit (LInt 0)))) (EVar "None"))) (DoLet false false PWild (EApp (EApp (EVar "fillEvidence") (EVar "arr")) (EVar "entries"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "evidenceRef")) (EApp (EVar "Some") (EVar "arr"))))))
(DTypeSig false "evSlotCount" (TyFun (TyCon "EvTable") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "evSlotCount" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "evSlotCount" ((PCons (PCon "EvEntry" (PCon "EvId" PWild (PVar "i")) PWild) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "evSlotCount") (EVar "rest")) (EApp (EApp (EMethodRef "max") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "acc"))))
(DTypeSig false "fillEvidence" (TyFun (TyApp (TyCon "Array") (TyApp (TyCon "Option") (TyCon "EvEntry"))) (TyFun (TyCon "EvTable") (TyCon "Unit"))))
(DFunDef false "fillEvidence" (PWild (PList)) (ELit LUnit))
(DFunDef false "fillEvidence" ((PVar "arr") (PCons (PAs "e" (PCon "EvEntry" (PCon "EvId" (PVar "m") (PVar "i")) PWild)) (PVar "rest"))) (EBlock (DoLet false false PWild (EMatch (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (arm (PCon "None") () (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "i")) (EApp (EVar "Some") (EVar "e"))) (EVar "arr"))) (arm (PCon "Some" PWild) () (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "evidence table: two goals published under ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "#"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ""))))))) (DoExpr (EApp (EApp (EVar "fillEvidence") (EVar "arr")) (EVar "rest")))))
(DTypeSig true "evDictRoutes" (TyFun (TyCon "EvId") (TyApp (TyCon "List") (TyCon "Route"))))
(DFunDef false "evDictRoutes" ((PCon "EvId" (PVar "m") (PVar "i"))) (EMatch (EUnOp "!" (EVar "evidenceRef")) (arm (PCon "None") () (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "evidence table: no elaboration has published one (looking up ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "#"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ")"))))) (arm (PCon "Some" (PVar "arr")) () (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr"))) (EListLit) (EMatch (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PCon "EvEntry" (PCon "EvId" (PVar "m2") PWild) (PVar "v"))) () (EIf (EBinOp "==" (EVar "m2") (EVar "m")) (EApp (EVar "evRoutesOf") (EVar "v")) (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "evidence table: ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "#"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString " answered by module "))) (EApp (EMethodRef "display") (EVar "m2"))) (ELit (LString "")))))))))))
(DTypeSig false "evRoutesOf" (TyFun (TyCon "EvVal") (TyApp (TyCon "List") (TyCon "Route"))))
(DFunDef false "evRoutesOf" ((PCon "EvMany" (PVar "rs"))) (EVar "rs"))
(DFunDef false "evRoutesOf" ((PCon "EvOne" PWild)) (EApp (EVar "panic") (ELit (LString "evidence table: a dictionary application solved to a single route"))))
(DTypeSig true "ifaceWordOf" (TyFun (TyCon "TyConOrigin") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "ifaceWordOf" ((PVar "o") (PVar "name")) (EMatch (EApp (EApp (EVar "ifaceIdentity") (EVar "o")) (EVar "name")) (arm (PLit (LString "")) () (EVar "name")) (arm (PVar "ident") () (EVar "ident"))))
(DTypeSig true "funHeadTag" (TyCon "String"))
(DFunDef false "funHeadTag" () (ELit (LString "__fun__")))
(DTypeSig true "implRouteKeyWord" (TyFun (TyCon "TyConOrigin") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyCon "String"))))))
(DFunDef false "implRouteKeyWord" ((PVar "o") (PVar "iface") (PVar "tys") (PVar "nm")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EApp (EVar "ifaceWordOf") (EVar "o")) (EVar "iface")))) (ELit (LString "|"))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EMethodRef "map") (EVar "rkTyAtom")) (EVar "tys"))))) (ELit (LString "|"))) (EApp (EMethodRef "display") (EApp (EApp (EVar "optionOr") (ELit (LString ""))) (EVar "nm")))) (ELit (LString ""))))
(DTypeSig true "routeWordFor" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "TyConOrigin") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyCon "String")))))))
(DFunDef false "routeWordFor" ((PVar "headIsUnique") (PVar "tag") (PVar "o") (PVar "iface") (PVar "tys")) (EIf (EVar "headIsUnique") (EVar "tag") (EApp (EApp (EApp (EApp (EVar "implRouteKeyWord") (EVar "o")) (EVar "iface")) (EVar "tys")) (EVar "None"))))
(DTypeSig false "rkTy" (TyFun (TyCon "Ty") (TyCon "String")))
(DFunDef false "rkTy" ((PRec "TyCon" ((rf "tyConName" (PVar "n"))) false)) (EVar "n"))
(DFunDef false "rkTy" ((PCon "TyVar" (PVar "n"))) (EVar "n"))
(DFunDef false "rkTy" ((PCon "TyApp" (PVar "a") (PVar "b"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "rkTy") (EVar "a")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EVar "rkTyAtom") (EVar "b")))) (ELit (LString ""))))
(DFunDef false "rkTy" ((PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "rkTyFunArg") (EVar "a")))) (ELit (LString " -> "))) (EApp (EMethodRef "display") (EApp (EVar "rkTy") (EVar "b")))) (ELit (LString ""))))
(DFunDef false "rkTy" ((PCon "TyTuple" (PVar "ts"))) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EMethodRef "map") (EVar "rkTy")) (EVar "ts")))) (ELit (LString ")"))))
(DFunDef false "rkTy" ((PCon "TyEffect" (PVar "effs") (PVar "tail") (PVar "t"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "<")) (EApp (EMethodRef "display") (EApp (EApp (EVar "rkRowBody") (EVar "effs")) (EVar "tail")))) (ELit (LString "> "))) (EApp (EMethodRef "display") (EApp (EVar "rkTy") (EVar "t")))) (ELit (LString ""))))
(DFunDef false "rkTy" ((PCon "TyRow" (PVar "effs") (PVar "tail") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "<")) (EApp (EMethodRef "display") (EApp (EApp (EVar "rkRowBody") (EVar "effs")) (EVar "tail")))) (ELit (LString ">"))))
(DFunDef false "rkTy" ((PCon "TyConstrained" (PVar "cs") (PVar "t"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "rkConstraints") (EVar "cs")))) (ELit (LString " => "))) (EApp (EMethodRef "display") (EApp (EVar "rkTy") (EVar "t")))) (ELit (LString ""))))
(DTypeSig false "rkTyFunArg" (TyFun (TyCon "Ty") (TyCon "String")))
(DFunDef false "rkTyFunArg" ((PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EVar "rkTy") (EApp (EApp (EVar "TyFun") (EVar "a")) (EVar "b")))) (ELit (LString ")"))))
(DFunDef false "rkTyFunArg" ((PVar "t")) (EApp (EVar "rkTy") (EVar "t")))
(DTypeSig false "rkTyAtom" (TyFun (TyCon "Ty") (TyCon "String")))
(DFunDef false "rkTyAtom" ((PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EVar "rkTy") (EApp (EApp (EVar "TyFun") (EVar "a")) (EVar "b")))) (ELit (LString ")"))))
(DFunDef false "rkTyAtom" ((PCon "TyApp" (PVar "a") (PVar "b"))) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EVar "rkTy") (EApp (EApp (EVar "TyApp") (EVar "a")) (EVar "b")))) (ELit (LString ")"))))
(DFunDef false "rkTyAtom" ((PVar "t")) (EApp (EVar "rkTy") (EVar "t")))
(DTypeSig false "rkRowBody" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))
(DFunDef false "rkRowBody" ((PVar "effs") (PList)) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EMethodRef "map") (EVar "rkEffAtom")) (EVar "effs"))))
(DFunDef false "rkRowBody" ((PList) (PVar "tails")) (EApp (EApp (EVar "joinWith") (ELit (LString " | "))) (EVar "tails")))
(DFunDef false "rkRowBody" ((PVar "effs") (PVar "tails")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EMethodRef "map") (EVar "rkEffAtom")) (EVar "effs"))))) (ELit (LString " | "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString " | "))) (EVar "tails")))) (ELit (LString ""))))
(DTypeSig false "rkEffAtom" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyCon "String")))
(DFunDef false "rkEffAtom" ((PTuple (PVar "l") (PCon "None"))) (EVar "l"))
(DFunDef false "rkEffAtom" ((PTuple (PVar "l") (PCon "Some" (PVar "s")))) (EIf (EBinOp "==" (EVar "s") (ELit (LString "_"))) (EBinOp "++" (EVar "l") (ELit (LString " _"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "l"))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EVar "escStr") (EVar "s")))) (ELit (LString "")))))
(DTypeSig false "rkConstraints" (TyFun (TyApp (TyCon "List") (TyCon "Constraint")) (TyCon "String")))
(DFunDef false "rkConstraints" ((PList (PVar "c"))) (EApp (EVar "rkConstraint") (EVar "c")))
(DFunDef false "rkConstraints" ((PVar "cs")) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EMethodRef "map") (EVar "rkConstraint")) (EVar "cs")))) (ELit (LString ")"))))
(DTypeSig false "rkConstraint" (TyFun (TyCon "Constraint") (TyCon "String")))
(DFunDef false "rkConstraint" ((PRec "Constraint" ((rf "constraintHead" (PVar "iface")) (rf "constraintArgs" (PList))) false)) (EVar "iface"))
(DFunDef false "rkConstraint" ((PRec "Constraint" ((rf "constraintHead" (PVar "iface")) (rf "constraintArgs" (PVar "tys"))) false)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "iface"))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EMethodRef "map") (EVar "rkTyAtom")) (EVar "tys"))))) (ELit (LString ""))))
(DTypeSig false "rkTyInt" (TyCon "Ty"))
(DFunDef false "rkTyInt" () (ERecordCreate "TyCon" ((fa "tyConName" (ELit (LString "Int"))) (fa "tyConLoc" (EVar "None")) (fa "tyConOrigin" (EVar "OriginUnresolved")))))
(DTypeSig false "rkTyBool" (TyCon "Ty"))
(DFunDef false "rkTyBool" () (ERecordCreate "TyCon" ((fa "tyConName" (ELit (LString "Bool"))) (fa "tyConLoc" (EVar "None")) (fa "tyConOrigin" (EVar "OriginUnresolved")))))
(DTypeSig false "rkTyIntM" (TyCon "Ty"))
(DFunDef false "rkTyIntM" () (ERecordCreate "TyCon" ((fa "tyConName" (ELit (LString "Int"))) (fa "tyConLoc" (EVar "None")) (fa "tyConOrigin" (EApp (EVar "OriginModule") (ELit (LString "m")))))))
(DTypeSig false "rkTyList" (TyCon "Ty"))
(DFunDef false "rkTyList" () (ERecordCreate "TyCon" ((fa "tyConName" (ELit (LString "List"))) (fa "tyConLoc" (EVar "None")) (fa "tyConOrigin" (EVar "OriginUnresolved")))))
