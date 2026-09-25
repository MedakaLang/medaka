# META
source_lines=765
stages=DESUGAR,MARK
# SOURCE
-- The type REPRESENTATION of the typechecker and its renderers: the monotype
-- (`Mono`, union-find `Tyvar`s), binding schemes (`Scheme`), the interface identity `IfaceRef`
-- and the vector obligation `VecObl` — and every pretty-printer over them
-- (`ppMono`, `ppScheme`, `ppTy`, …) plus `normalize`, the union-find dereference.
--
-- What lives here reads NO typechecker state cell — nothing in this module touches
-- `perRun`, `crossRun`, `driverState` or `graphRun` — and is closed under its own
-- references.  That is the criterion for a file of its own rather than a region of
-- `typecheck.mdk` (#2586); the two scheme printers that DO read state
-- (`ppSchemeNamed`, `ppSchemeNamedFull`, which consult the scheme-obligation tables)
-- stay there.
--
-- Effect domains and rows have their own owners. Import those representations
-- directly from effect_domain/effect_rows rather than through this module.

import types.effect_authority.{
  Authority(..), Authvar(..), authvarId, authvarName, authNorm, authIsTop,
  renderAuthorityWith
}
import types.effect_rows.{
  renderAtoms,
  renderAtomsWith,
  Atom(..),
  effrowNorm,
  effrowLabels,
  rowFlat,
  effvarId,
  isJoinCell,
  EffRow(..),
  Effvar(..),
}
import frontend.ast.{
  Ty(..), Constraint(..), TyConOrigin(..), EffAtomTy(..), effAtomSurface,
  authTermSurface
}
import support.util.{listLen, filterList, isEmptyL, joinWith, sortUniqS, escStr}

-- ── monotypes & schemes ───────────────────────────────────────────────────
public export data Mono =
  | TVar (Ref Tyvar)
  | TCon String TyConOrigin
  -- The GOAL-SIDE dispatch head, and the second field is #1110's module identity
  -- for it (DICT-SEMANTICS §8 I4's `(originModule, name)`).  Same three
  -- inhabitants as `Ty.TyCon`'s `tyConOrigin` and the four decl-layer carriers,
  -- for the reason `frontend/ast.mdk` gives at the type: the layers name the SAME
  -- fact, and a parallel ADT would buy a conversion at every seam relating a
  -- declaration to a head that spells it.
  --
  -- THIS FIELD IS READ, AND IT DECIDES ACCEPTANCE (#1111 Stage A-2 unit
  -- A-2.10).  It said "CARRIER ONLY — NOTHING READS IT YET, and no answer
  -- changes" until A-2.2b, then "IT IS READ, AND STILL NO ANSWER CHANGES" until
  -- this unit.  The first was already FALSE on `main` when it was written
  -- (`headTyconMono` read the field from A-2.2 onward), and a reviewer traced a
  -- shipped S0 to someone believing it — the retained `hd == Some hk` guard in
  -- `implExistsForHeadGo`, which compared an origin-carrying impl head against a
  -- frequently-origin-less goal head inside a bucket keyed by spelling, and so
  -- answered `False` wherever they differed.  The lesson survives both
  -- corrections and is worth more than either: a "nothing reads this" / "no
  -- answer changes" claim is a NEGATIVE ABOUT THE WHOLE FILE, it expires the
  -- moment any unit adds a reader, and no gate notices.
  --
  -- WHAT IS TRUE NOW, in the two halves A-2.2b separated (they are INDEPENDENT
  -- facts and collapsing them is what the wording above kept getting wrong):
  --
  --   * THE COMPARISONS READ IT AND ACCEPTANCE MOVED.  The six "are these the
  --     same type?" tests — `unifyN`, `cohGoR`, `cohStep`, `cohEqR`,
  --     `matchStep`, `monoSameGiven` — all read the field, all through the
  --     single seam `sameTyConHead` (`frontend/ast.mdk`), whose doc-comment owns
  --     the absent-origin rule and its derivation.  Two modules' same-named
  --     types no longer unify (#1208, #1209).
  --   * THE DISPATCH KEY STILL DOES NOT.  `headTyconMono`'s `TCon n o` arm hands
  --     `o` to `headKeyOfCon`, so every goal-side `HeadKey` CARRIES the
  --     identity — and every consumer of that `HeadKey` then projects it BACK to
  --     the bare spelling before comparing: `dispHeadTab` (the bucket key,
  --     `implExistsForHeadGo`'s retest, `countHeadGo` / `ieCountHeadByIfaceGo`,
  --     the obligation universes) or `headKeyName` / `headKeyNameOr` (the
  --     emitted route word).  `headTyconNameMono`, the name-only residual, still
  --     hands out a bare name outright.  (A-2.10's draft of this paragraph also
  --     named `monoHeadCon`; A-2.2b DELETED that projection on `main` — see its
  --     obituary above `mainTypeIsAsync` — and the merge of the two units is
  --     where that was caught.)  The discard is LEDGERED, not incidental:
  --     `dispHeadTab` IS the list of sites whose answer would move the day the
  --     goal side becomes supplied and canonical
  --     (`grep -nw dispHeadTab compiler/types/typecheck.mdk`).
  --
  -- SO A LEDGERED RETEST IS STILL NOT AN IDENTITY COMPARISON, AND PROMOTING
  -- ONE AS A TIDY-UP STILL CHANGES ACCEPTANCE — that is exactly what A-2.2b did
  -- three times before review caught it, and A-2.10 narrowing the COMPARISONS
  -- does not license it on the DISPATCH side.  Derive the reader set rather than
  -- trusting this prose; the grep finds a reader whatever it is called:
  --
  --     grep -n TCon compiler/types/typecheck.mdk \
  --       | grep -vE '^[0-9]+:[[:space:]]*--' | grep -vE 'TCon [^ )]+ _'
  --
  -- THE CONSTRUCTOR IS NEVER APPLIED OUTSIDE THE FOUR MINTS BELOW
  -- (`tconBuiltin` / `tconTupleHead` / `tconFrom` / `tconUnresolved`), and that is
  -- the property this widening rests on rather than "every construction site is
  -- individually right".  There is no stamping pass at this layer and no
  -- first-write immunity rule to lean on — `stampTyHead`'s filter protects the
  -- `Ty` layer only — so identity has to be correct AT CONSTRUCTION.  Funnelling
  -- every construction through four one-line helpers makes that four decisions,
  -- each named after the identity class it claims, and
  -- `test/typecheck_compiler_source.sh` pins the set.  Everything else that
  -- mentions `TCon` in this file is a PATTERN — most with `_` in the origin
  -- slot, and (since A-2.10) a set of them that BIND it.  The ratchet's own
  -- remedy predicted exactly that ("a pattern that legitimately BINDS the origin
  -- is the expected first false positive; list it, and the list stays the
  -- audit"), so THE BINDING SET IS ENUMERATED THERE AND THE ENUMERATION IS THE
  -- AUDIT.  Derive it, do not read it here:
  --
  --   sh test/typecheck_compiler_source.sh   # prints "N Mono.TCon mint(s) +
  --                                          # M origin-binding pattern(s)"
  --   grep -n 'mono_tcon_allowed' -A20 test/typecheck_compiler_source.sh
  --
  -- THIS PARAGRAPH SAID "SEVEN that BIND it: `headTyconMono` plus the six
  -- comparisons above" AND WAS WRONG BY ONE ON ITS FIRST DAY — it omitted
  -- `firstIdConflict` (the diagnostic-side reader that pairs the two conflicting
  -- identities so `Type mismatch: T vs T` can name both modules), which binds
  -- BOTH origins.  A count of the binding sites is an encoded fact with no
  -- derivation, and the number of PATTERN LINES is not even the number of
  -- FUNCTIONS (`cohStep` and `monoSameGiven` contribute two lines each), so the
  -- reader has to pick which is meant.  Do not re-describe this population with a
  -- rule of thumb — `_`-shaped or numeric.
  --
  -- AND NOTHING REBUILDS ONE FROM ITS NAME.  `substMono`/`substMonoP` (reached
  -- from `instantiate`, i.e. every use of every imported binding) return the
  -- MATCHED NODE, never a rebuilt `TCon n => TCon n`, so preservation is
  -- structural rather than a per-site promise — and one allocation per head per
  -- instantiation goes away with it.  `unifyN`'s mismatch arms likewise hand
  -- `typeMismatch` the node they matched.
  | TRigid String
  -- A RIGID type variable: a head fabricated from a type-PARAMETER name, not
  -- from any declaration.  It has exactly two producers — `fromAstTypeE`'s
  -- `TyVar` fallback and `paramMonoOf` — and both mint it from a name the
  -- parser already routed through `TIdent` (`parseTyAtom`,
  -- `compiler/frontend/parser.mdk:2049`).
  --
  -- THE NAMING RULE, STATED CORRECTLY — it is the safety argument for every
  -- consumer that does NOT carry a `TRigid` arm, so getting it wrong silently
  -- changes answers:
  --   * a RIGID name never starts with an UPPERCASE letter.  It is not
  --     necessarily lowercase: `identStartLower` (`frontend/lexer.mdk:1638`) is
  --     `isLower … || … == '_'`, so `_k`/`_v`/`_a` (synthesized by
  --     `frontend/desugar.mdk:964,967`), `_` (`frontend/parser.mdk:2720`) and
  --     `__tuple2__` are all legal rigid spellings.
  --   * a REAL head is uppercase-initial, OR one of the reserved `__tupleN__`
  --     builtin tags (`tupleCtorTyName`, `frontend/parser.mdk:2137`;
  --     `tupleHeadTagTc` below).
  -- So the two populations are disjoint on the UPPERCASE test alone, and they
  -- DO collide on `__tupleN__` — which is why `tupleSpine` and `matchStep` each
  -- carry an explicit answer-preserving `TRigid` arm rather than relying on a
  -- wildcard.  An earlier version of this comment claimed "rigid = lowercase,
  -- real = uppercase"; both halves are false at the edges and the claim is what
  -- let the `matchStep` case through review.  DICT-SEMANTICS §8 I6.2(b) tracks
  -- the `__tupleN__` forgery as OWED-#1110.
  --
  -- WHY IT IS ITS OWN CONSTRUCTOR (#1110, DICT-SEMANTICS §8 I6.1 ∧ I6.3):
  -- a rigid variable must carry NO module identity, a real head MUST carry
  -- one.  While both lived in `TCon String` that field could not be added at
  -- all.  This split is the carrier step only — every arm below reproduces
  -- the answer the shared `TCon` gave, byte for byte.  The field has since
  -- landed on `TCon` (above); `TRigid` deliberately did NOT grow one, which is
  -- the I6.1 half — "a rigid carries no identity" is now unrepresentable-wrong
  -- rather than merely unwritten.
  --
  -- It does NOT yet satisfy I6.1: a rigid is still usable as a dispatch
  -- key wherever `headTyconMono`/`headTyconNameMono` hand one out (both keep an
  -- explicit answer-preserving `TRigid` arm, deliberately).  The gain is that
  -- the violation is now GREPPABLE — `grep -nw TRigid` — instead of invisible
  -- inside `TCon`.  Eliminating it is the follow-on step, not this one.
  | TApp Mono Mono
  | TFun Mono EffRow Mono
  -- arg -> <effect row> result
  | TEff EffRow
  -- A qualified value type `τ @q`: the value's domain-directed abstraction is
  -- bounded by the authority `q`.  Introduced by a signature's named argument
  -- (`(path : String)` elaborates its domain to `String @κ`) or an explicit
  -- `@p`; forgotten safely toward the plain type, never invented from one.
  -- Erases before any runtime layout.
  | TQual Mono Authority
  -- An authority occupying an `Authority`-kinded type-CONSTRUCTOR ARGUMENT
  -- slot (`Handle κ`, `Handle "config/*"`): the twin of `TEff` for the third
  -- variable sort.  Produced only by kind-directed elaboration at such a
  -- slot; invariant under unification (§6.4); erases before runtime layout.
  | TAuth Authority

-- An effect row occupying a type-CONSTRUCTOR ARGUMENT slot, for a data type
-- with an effect-row parameter (`data Async e a = … <e> …`).  Produced ONLY
-- by kind-directed elaboration at a Row-kinded param position; consumed only
-- by unifyN's TApp~TApp recursion.  Never appears in code lacking an
-- effect-poly data type, so its addition is purely additive.

public export data Tyvar =
  | Unbound Int Int  -- Unbound id level | Link
  | Link Mono

-- ── the FOUR mints of `Mono.TCon` (#1110) ─────────────────────────────────
-- These four one-line bodies are the ONLY applications of the `TCon`
-- constructor in this file; `test/typecheck_compiler_source.sh` pins that set,
-- and `Mono`'s own comment says why the property is worth buying.  Each name
-- states the identity class it claims, so a reviewer grades a CALL rather than
-- re-deriving what a bare third argument meant.

-- forall <quantified tyvar ids> <quantified effvar ids> <quantified authvar ids>. mono
-- A generalized term binding: type, row and authority binders scope over BOTH
-- the value and its forcing effect and are instantiated together under one
-- substitution. Strict locals, constructors and functions have an empty
-- forcing row; lazy top-level initializers retain their evaluation row.
public export data Scheme = Forall (List Int) (List Int) (List Int) EffRow Mono

-- #838 I1: the unified obligation record.  `pred.args` is the
-- ALREADY-PROJECTED dispatch/argument vector — exactly the call channel's existing
-- shape (contrast the impl channel's un-projected method type, out of scope this
-- increment).  `originId` is the #837 binding id of the binding this obligation was
-- DEFERRED BY (0 = anchorless/local/cross-module, mirroring incr1's id-0 fallback);
-- populated now so a later increment does not re-key every record (#838 §2.2).
-- `prov` is documentary in I1 — the checker below does not yet branch on it (that is
-- I2's uniform-deferral work); it is carried now so I2 does not need a second
-- migration to add it.
-- ── P1 (#1446): THE INTERFACE HALF OF AN OBLIGATION IS AN IDENTITY, NOT A NAME ──
-- DICT-SEMANTICS §8 I4: a class is a `(module, name)` pair.  `Predicate.iface` used
-- to be a bare `String`, so the whole entailment/obligation channel could not tell
-- two same-spelled interfaces from different modules apart — an imported, unrelated
-- `Sizer` silently satisfied a locally-declared `Sizer` constraint (#1438: `check`
-- clean, `run` panics, the built binary segfaults at 139).
--
-- `irOrigin` is the `TyConOrigin` of the DECLARATION this occurrence denotes, read
-- off whichever carrier the site already has (`Constraint.constraintOrigin`,
-- `Require.requireOrigin`, `DInterface.ifaceOrigin` via `methodIfaceParamsRef`,
-- `DImpl.implOrigin`).  `irName` is kept ALONGSIDE it, not derived from it: every
-- diagnostic in this channel prints the spelling, and `concreteReqMatchByIface`
-- still asks the SPELLING-keyed `KeyBuckets` registry a route-word question that
-- must NOT become an identity question (#1317 T1 / the closed S0 #1277 — see
-- `dispHeadTab`).  One value carrying both halves is what keeps those two questions
-- from drifting apart.
--
-- `OriginUnresolved` IS A LEGAL INHABITANT AND MUST STAY ONE.  A flat user
-- module's own interface is unstamped on BOTH sides (its `interface` decl and its
-- `impl` alike), so it keys `TkBare`/`TkBare` symmetrically and is unaffected by the
-- re-key — that symmetry is why this change is not a mass false-reject.  A TOTAL
-- identity would require #1115 (E-1) to land first, and `stampTyHead`'s immunity
-- rule makes an invented one PERMANENT.  `tabKeyOf`'s `None => TkBare` arm and
-- `tabKeyEq`'s refusal to equate `TkBare` with `TkIdent` are the representation
-- built for exactly this.
public export data IfaceRef = IfaceRef {
  irName : String,  -- the SPELLING; still needed for diagnostics and for the spelling-keyed KeyBuckets question
  irOrigin : TyConOrigin,  -- the I4 identity of the declaration this occurrence denotes
}

-- U1b (#1482): ONE vector obligation — one interface OCCURRENCE (identity-carrying,
-- #1446 P1) applied to one vector of scheme-quantified tyvar ids.  This is the payload
-- of `schemeObligationsRef` and of its three cross-module mirrors.
--
-- The point of the record is not ergonomics.  Before it, this payload was
-- `(String, List Int)` — the SAME shape as `funConstraintsRef`'s `(fn name, slot ids)`
-- entries, 58 lines of the file apart, with nothing but a convention keeping the two
-- meanings from being passed to each other's readers.  Widening the interface half to
-- `IfaceRef` removes M1 from that shape, which leaves the fn-name meaning as its only
-- inhabitant: a cross-family mixup is now an ordinary type error in the compiler's own
-- typechecker, defended by `make check-self` / `typecheck_compiler_source.sh` rather
-- than by care.  The widening IS the disambiguation.
--
-- #1161 (S-obligation-nary-payload): [voArgs] is the predicate's WHOLE argument
-- vector as monos, at the recording site's instantiation — the `Predicate.args`
-- shape, carried here so a predicate with a GROUND argument (`Ix a Bool =>`)
-- survives the channel at all.  `[]` means "no vector was recoverable", exactly
-- the convention `zipSlotArgs`/`enclPreds` already use for the slot channel, and
-- it reproduces the pre-widening ids-only behaviour byte for byte.
--
-- [voIds] IS NOT REDUNDANT WITH IT, AND MUST NOT BE DERIVED FROM IT.  Two
-- producers have only an id (`vecOblsOfSlots` lifts a `CSlot`, whose payload is
-- `csId : Int`; `superSlotVecOf` maps typaram names positionally onto ids), and a
-- `Mono` is a `Ref Tyvar` that cannot be minted from an id.  [voIds] also remains
-- the currency of the dict-slot cardinality (`leadInferredPred`) and of the coverage
-- subset test (`pairsOfVecObls`), neither of which has anything to say about a
-- ground argument.  When [voArgs] is non-empty, [voIds] holds the ids of exactly
-- its BARE-TYVAR positions, in order.
public export data VecObl = VecObl {
  voIface : IfaceRef,
  voIds : List Int,
  voArgs : List Mono,
}

-- ── small helpers ─────────────────────────────────────────────────────────
export
lookupAssocI : Int -> List (Int, b) -> Option b
lookupAssocI _ [] = None
lookupAssocI k ((k2, v) :: rest)
  | k == k2 = Some v
  | otherwise = lookupAssocI k rest

-- ── union-find core ───────────────────────────────────────────────────────
-- PERF (issue #115): this is a union-find FIND, and it PATH-COMPRESSES.  Without
-- compression it was the compiler's worst performance defect: `unifyVars` links the
-- current root to the *fresh* var it meets (`bindVar c1 (TVar c2)`), so inferring a
-- single large declaration — an N-arm `match` whose arms all unify against one
-- result var, an N-element list literal — builds a Link chain of length N.  Every
-- later `normalize`/`rootIdOf` of any var in that class then walked O(N) links, and
-- the post-inference walkers (`walkDispatch`, `setNumlitFloatsGo`, `monoUnboundIds`)
-- plus the Chunk-D numlit scans do that once per literal ⇒ O(N²) link steps, on a
-- non-allocating hot loop that no allocation-graded gate could see.  Compression
-- makes it amortized near-O(1) and leaves the ROOT IDENTITY untouched — this is a
-- representation change only, so no program's inferred type moves.
--
-- Returns the ARGUMENT ITSELF (never a rebuilt `TVar`) when already at a root, so
-- the overwhelmingly common case allocates nothing — the old multi-clause form's
-- `Unbound _ _ => TVar cell` rebuilt a cell on every call.  That is why this matches
-- on the whole parameter instead of destructuring it in the head: a multi-clause
-- definition cannot name the value it matched, so it cannot give it back unchanged.
export
normalize : Mono -> Mono
-- lint-disable-next-line rule-match-on-param
normalize m = match m
  TVar cell => match !cell
    Link t => normalizeLink cell t
    Unbound _ _ => m
  _ => m

-- [cell] is a `Link` to [t]: resolve [t] to its root, re-point [cell] STRAIGHT at
-- that root, and return it.  The write happens only when the chain is longer than
-- one hop — a direct link is already compressed, so re-writing it would be pure cost.
-- Matches on the whole [t] for the same no-rebuild reason as `normalize` above.
export
normalizeLink : Ref Tyvar -> Mono -> Mono
-- lint-disable-next-line rule-match-on-param
normalizeLink cell t = match t
  TVar c2 => match !c2
    Unbound _ _ => t
    Link t2 =>
      let r = normalizeLink c2 t2
      cell := Link r
      r
  _ => t

-- ── rendering ─────────────────────────────────────────────────────────────
export
ppScheme : Scheme -> String
ppScheme (Forall _ _ _ force t) = ppBinding (Ref []) (Ref 0) force t

ppBinding : Ref (List (Int, String)) -> Ref Int -> EffRow -> Mono -> String
ppBinding ctx cnt force t = match rowFlat force
  ([], []) => ppGo ctx cnt 0 t
  flat => ppEffectPrefix ctx cnt flat ++ ppGo ctx cnt 2 t

ppEffectPrefix : Ref (List (Int, String)) ->
  Ref Int ->
  (List Atom, List (Ref Effvar)) ->
  String
ppEffectPrefix _ _ ([], []) = ""
ppEffectPrefix ctx cnt (labels, members) =
  let atoms = renderAtomsWith (ppAuthvarName ctx cnt) labels
  let tails = joinWith " | " (map (ppEffvarName ctx cnt) members)
  let inside =
    if atoms == "" then
      tails
    else if tails == "" then
      atoms
    else
      "\{atoms} | \{tails}"
  "<\{inside}> "

-- Render a scheme WITH its constraint context (`Num a => a -> a -> a`).  The
-- constraint tyvar ids are threaded through the SAME ctx/cnt that renders the
-- body, so a constraint's letter matches the body's (id → letter shared).  The
-- body is rendered FIRST so ctx already carries the body's letter assignments
-- when the constraints reuse it via nameOf.  Constraints are rendered+sorted+
-- deduped for a stable display order.  Empty list ⇒ plain ppScheme (no `=>`).
-- Single-vs-multiple form mirrors ppConstrDoc in tools/doc.mdk (`Num a =>` /
-- `(Num a, Ord b) =>`).
export
ppSchemeCon : List VecObl -> Scheme -> String
ppSchemeCon [] s = ppScheme s
ppSchemeCon cons (Forall _ _ _ force t) =
  let ctx = Ref []
  let cnt = Ref 0
  let body = ppBinding ctx cnt force t
  let rendered = sortUniqS (renderConstraintCtx ctx cnt cons)
  let ctxStr = match rendered
    [c] => c
    _ => "(" ++ joinWith ", " rendered ++ ")"
  "\{ctxStr} => \{body}"

-- a predicate renders with its WHOLE argument vector — `Ix a i =>`, not the
-- `(Ix a, Ix i) =>` two-1-ary-facts rendering the shattered representation produced
-- before #607.
-- Renders the SPELLING (`voIface.irName`).  U1b (#1482) gave this payload an
-- identity-carrying interface half; every DISPLAY surface must keep printing the name
-- the user wrote, or every `Num a => …` in `check --types`, LSP hover, inlay hints and
-- the snapshot corpus moves.
export
renderConstraintCtx : Ref (List (Int, String)) ->
  Ref Int ->
  List VecObl ->
  List String
renderConstraintCtx _ _ [] = []
renderConstraintCtx ctx cnt (o :: rest) =
  -- #1161: a vector-carrying entry renders its WHOLE argument vector under the SAME
  -- naming context as the body, so `Ix a Bool =>` prints with its ground argument
  -- instead of degrading to `Ix a`.  An ids-only entry renders exactly as before.
  -- #1952: ARGUMENT precedence (3), not 2.  At prec 2 `wrapIf (prec > 2)` leaves an
  -- application BARE, so a STRUCTURED predicate argument printed as `Conv Wrap a b =>` —
  -- which is not the same predicate: it reads as a four-argument context and does not
  -- round-trip through the parser.  This is SOURCE SYNTAX (`check --types`, LSP hover,
  -- inlay hints all show it as a signature), so it owes the parens unconditionally, at
  -- arity 1 as much as at arity 2.  Bare-tyvar and nullary-`TCon` arguments are atoms and
  -- render identically at either precedence, so `Num a =>` / `Ix a Bool =>` do not move —
  -- and the compiler's and stdlib's own declared contexts are all bare-tyvar 1-ary, so
  -- neither the snapshot corpus nor the self-compile fixpoint sees this at all.
  let s =
    if isEmptyL o.voArgs then
      joinWith " " (o.voIface.irName :: map (id => nameOf ctx cnt id) o.voIds)
    else
      joinWith " " (o.voIface.irName :: map (ppGo ctx cnt 3) o.voArgs)
  s :: renderConstraintCtx ctx cnt rest

export
ppMono : Mono -> String
ppMono t =
  let ctx = Ref []
  let cnt = Ref 0
  ppGo ctx cnt 0 t

export
letters : String
letters = "abcdefghijklmnopqrstuvwxyz"

export
nameOf : Ref (List (Int, String)) -> Ref Int -> Int -> String
nameOf ctx cnt id = match lookupAssocI id !ctx
  Some s => s
  None => assignName ctx cnt id

export
assignName : Ref (List (Int, String)) -> Ref Int -> Int -> String
assignName ctx cnt id =
  let n = !cnt
  cnt := n + 1
  let s = if n < 26 then stringSlice n (n + 1) letters else "t" ++ intToString n
  ctx := (id, s) :: !ctx
  s

export
ppGo : Ref (List (Int, String)) -> Ref Int -> Int -> Mono -> String
ppGo ctx cnt prec t = match normalize t
  TVar cell => ppVar ctx cnt cell
  TCon n _ => ppConName n
  -- Same renderer as `TCon`: a rigid prints as its own type-parameter name
  -- (`ppConName` is the tuple-tag de-mangler and is the identity on any name
  -- that is not a `__tupleN__` tag).  Byte-identical to the pre-split output.
  TRigid n => ppConName n
  TApp a b => ppApp ctx cnt prec a b
  TFun a eff b => ppFun ctx cnt prec a eff b
  TEff r => ppEffArg ctx cnt r
  TQual inner q => ppQual ctx cnt prec inner q
  TAuth q => ppAuthArg ctx cnt q

-- An index argument: the top is `*`, the spelling a signature writes; any
-- other term renders as it does after `@`.
export
ppAuthArg : Ref (List (Int, String)) -> Ref Int -> Authority -> String
ppAuthArg ctx cnt q =
  if authIsTop (authNorm q) then "*" else ppAuthority ctx cnt q

-- `T @p` outside an arrow domain (an arrow domain renders as the named
-- argument `(p : T)` in `ppFun`, the form a signature writes).
export
ppQual : Ref (List (Int, String)) ->
  Ref Int ->
  Int ->
  Mono ->
  Authority ->
  String
ppQual ctx cnt prec inner q =
  wrapIf (prec > 2) "\{ppGo ctx cnt 3 inner} @\{ppAuthority ctx cnt q}"

-- The authority term without a leading space, under the shared naming context.
export
ppAuthority : Ref (List (Int, String)) -> Ref Int -> Authority -> String
ppAuthority ctx cnt q =
  let s = renderAuthorityWith (ppAuthvarName ctx cnt) q
  if stringLength s > 0 && stringSlice 0 1 s == " " then
    stringSlice 1 (stringLength s) s
  else
    s

-- A signature binder's own name where it has one and is not already taken by
-- a different variable in this context; otherwise a letter from a private
-- namespace, as an effect variable takes one.
export
ppAuthvarName : Ref (List (Int, String)) -> Ref Int -> Ref Authvar -> String
ppAuthvarName ctx cnt cell =
  let key = authvarId cell + 2000000
  match lookupAssocI key !ctx
    Some s => s
    None => match authvarName cell
      Some n =>
        if nameTaken n !ctx then
          assignName ctx cnt key
        else
          ctx := (key, n) :: !ctx
          n
      None => assignName ctx cnt key

nameTaken : String -> List (Int, String) -> Bool
nameTaken _ [] = False
nameTaken n ((_, s) :: rest) = s == n || nameTaken n rest

-- Render a row sitting in type-argument position (the `e` of `Async e a`).  Bare
-- open tail → the row var's name (reads `Async e a`); labels → `<IO>`/`<IO | e>`;
-- closed empty → `<>`.  Effvar ids are offset into a private letter namespace so
-- they never collide with tyvar letters.
export
ppEffArg : Ref (List (Int, String)) -> Ref Int -> EffRow -> String
ppEffArg ctx cnt r = match effrowNorm r
  EffRow labels tail =>
    let lbl = match labels
      [] => ""
      ls => renderAtomsWith (ppAuthvarName ctx cnt) ls
    let tailS = match tail
      Some cell => ppEffvarName ctx cnt cell
      None => ""
    -- #821: a bare join in an index slot renders parenthesised, `(e | e2)`,
    -- which is also its written form; with labels, `<L | e | e2>`.
    match tail
      Some cell =>
        if isJoinCell cell && lbl == "" then
          "(" ++ tailS ++ ")"
        else
          ppEffArgFmt lbl tailS
      None => ppEffArgFmt lbl tailS

export
ppEffvarName : Ref (List (Int, String)) -> Ref Int -> Ref Effvar -> String
ppEffvarName ctx cnt cell =
  joinWith
    " | "
    (map
      (m => nameOf ctx cnt (effvarId m + 1000000))
      (snd (rowFlat (EffRow [] (Some cell)))))

export
ppEffArgFmt : String -> String -> String
ppEffArgFmt l t
  | l == "" && t == "" = "<>"
  | l == "" = t
  | t == "" = "<" ++ l ++ ">"
  | otherwise = "<\{l} | \{t}>"

export
ppVar : Ref (List (Int, String)) -> Ref Int -> Ref Tyvar -> String
ppVar ctx cnt cell = match !cell
  Unbound id _ => nameOf ctx cnt id
  Link _ => "_"

export
ppApp : Ref (List (Int, String)) -> Ref Int -> Int -> Mono -> Mono -> String
ppApp ctx cnt prec a b = match tupleSpine (TApp a b)
  -- a fully-saturated `__tupleN__` spine renders back to surface `(e1, …, eN)`
  Some ts => "(" ++ joinWith ", " (ppEach ctx cnt 0 ts) ++ ")"
  None =>
    let sa = ppGo ctx cnt 2 a
    let sb = ppGo ctx cnt 3 b
    wrapIf (prec > 2) "\{sa} \{sb}"

export
ppFun : Ref (List (Int, String)) ->
  Ref Int ->
  Int ->
  Mono ->
  EffRow ->
  Mono ->
  String
ppFun ctx cnt prec a eff b =
  let sa = ppDomain ctx cnt a
  let se = ppEffectPrefix ctx cnt (rowFlat eff)
  let sb = ppGo ctx cnt 1 b
  wrapIf (prec > 1) "\{sa} -> \{se}\{sb}"

-- A qualified arrow domain renders as the named argument that introduces
-- it, `(p : T)`, so a printed scheme is the signature a user would write.
ppDomain : Ref (List (Int, String)) -> Ref Int -> Mono -> String
ppDomain ctx cnt a = match normalize a
  TQual inner (AVar cell) =>
    if isSome (lookupAssocI (authvarId cell + 2000000) !ctx) then
      ppGo ctx cnt 2 a
    else
      "(\{ppAuthvarName ctx cnt cell} : \{ppGo ctx cnt 0 inner})"
  _ => ppGo ctx cnt 2 a

export
effStr : List Atom -> String
effStr [] = ""
effStr labels = "<" ++ renderAtoms labels ++ "> "

export
ppEach : Ref (List (Int, String)) -> Ref Int -> Int -> List Mono -> List String
ppEach _ _ _ [] = []
ppEach ctx cnt prec (t :: ts) =
  let s = ppGo ctx cnt prec t
  s :: ppEach ctx cnt prec ts

export
wrapIf : Bool -> String -> String
wrapIf True s = "(" ++ s ++ ")"
wrapIf False s = s

-- render a PREDICATE's argument vector against one shared naming ctx, at ARGUMENT
-- precedence — so `List a` in an argument slot prints as `(List a)`.
-- NOT `ppMonosShared`, and not a candidate for merging with it: that one renders
-- the dispatch monos at prec 2, where `wrapIf (prec > 2)` leaves an application
-- BARE.  For a predicate whose arguments are themselves applications that is
-- ambiguous — `Index List a Int a` reads as either a 3-argument or a 5-argument
-- predicate — and the whole value of naming the goal is that the reader can match it
-- against the impl heads printed beside it.  `cohPpEach` (prec 0) has the same
-- problem.  Same shared-naming-context discipline as both, one precedence up.
export
ppPredArgsShared : List Mono -> String
ppPredArgsShared ms = joinWith " " (ppEach (Ref []) (Ref 0) 3 ms)

-- Native Gap C: the arity-distinguished tuple dispatch tag (`__tuple2__`, …),
-- byte-identical to eval.mdk's `tupleHeadTag`.  Stamped as the RKey route tag at a
-- tuple method site so each arity routes to its own impl group / lifted define.
export
tupleHeadTagTc : Int -> String
tupleHeadTagTc n = "__tuple" ++ intToString n ++ "__"

-- collect a left-spine `TApp` into (head, args-in-application-order),
-- normalizing at each level so a linked head resolves.
export
spineParts : Mono -> (Mono, List Mono)
spineParts t = match normalize t
  TApp a b => match spineParts a
    (h, args) => (h, args ++ [b])
  other => (other, [])

-- recognise a fully-saturated tuple spine (arity >= 2 — `()`/Unit stays
-- `TCon "Unit"`, never a tuple); return its element monos in order.
export
tupleSpine : Mono -> Option (List Mono)
tupleSpine t = match spineParts t
  (TCon n _, args) =>
    if listLen args >= 2 && n == tupleHeadTagTc (listLen args) then
      Some args
    else
      None
  -- #1110 answer-preserving, and deliberately not "simplified" away.  A rigid
  -- variable can be the head of an application spine (`fromAstTypeVarApp` builds
  -- `TApp (TRigid h) …` at a row-slot arg), and before the split such a head was
  -- a `TCon` and reached the arm above.  A type parameter spelled `__tupleN__`
  -- is absurd but lexically legal, so dropping this arm would be a real — if
  -- unreachable-in-corpus — answer change.  Keep the answer; fix it with the
  -- rest of I6.1.
  (TRigid n, args) =>
    if listLen args >= 2 && n == tupleHeadTagTc (listLen args) then
      Some args
    else
      None
  _ => None

-- arity a `__tupleN__` tag string names (else None) — bounded probe so a bare
-- or PARTIAL tuple ctor never leaks the raw `__tupleN__` tag into a message.
export
tupleTagArity : String -> Option Int
tupleTagArity n = tupleTagArityGo n 2

export
tupleTagArityGo : String -> Int -> Option Int
tupleTagArityGo n k
  | k > 32 = None
  | tupleHeadTagTc k == n = Some k
  | otherwise = tupleTagArityGo n (k + 1)

export
commaStr : Int -> String
commaStr n = if n <= 0 then "" else "," ++ commaStr (n - 1)

-- render a bare/partial tuple constructor as the surface-less `(,)`/`(,,)` head
-- (only reached when a tuple spine is UNSATURATED, e.g. an arity-mismatch
-- message); a saturated spine renders `(e1, …)` via ppApp before reaching here.
export
ppConName : String -> String
ppConName n = match tupleTagArity n
  Some k => "(" ++ commaStr (k - 1) ++ ")"
  None => n

-- render the dispatch monos space-separated under ONE shared naming context
-- so distinct free vars don't all collapse
-- to "a".  Concrete heads (the only case that reaches an error) render as the
-- type name.
export
ppMonosShared : List Mono -> String
ppMonosShared ms =
  let ctx = Ref []
  let cnt = Ref 0
  joinWith " " (ppEachShared ctx cnt ms)

export
ppEachShared : Ref (List (Int, String)) -> Ref Int -> List Mono -> List String
ppEachShared ctx cnt ms = map (ppGo ctx cnt 2) ms

-- pretty-print an AST type
export
ppTy : Ty -> String
ppTy (TyCon { tyConName = n }) = n
ppTy (TyVar n) = n
ppTy (TyApp a b) = "\{ppTy a} \{ppTyAtom b}"
ppTy (TyFun a b) = "\{ppTyFunArg a} -> \{ppTy b}"
ppTy (TyTuple ts) = "(" ++ joinWith ", " (map ppTy ts) ++ ")"
ppTy (TyEffect effs tail t) = "<\{ppEffInsideTy effs tail}> \{ppTy t}"
-- A label-free join takes the parenthesised type-argument spelling it is
-- written in (`f (e | e2) b`), matching tools/printer.mdk.
ppTy (TyRow [] (a :: b :: rest) _) = "(\{joinWith " | " (a :: b :: rest)})"
-- A bare row atom (#997): same row rendering as `TyEffect` above, minus the
-- wrapped type it has none of.
ppTy (TyRow effs tail _) = "<\{ppEffInsideTy effs tail}>"
ppTy (TyAuth p _) = authTermSurface escStr p
ppTy (TyConstrained cs t) = "\{ppConstraints cs} => \{ppTy t}"
ppTy (TyNamed n t) = "(\{n} : \{ppTy t})"
ppTy (TyQual t n) = "\{ppTyAtom t} @\{n}"

-- shared `<...>` row-body renderer for `TyEffect`/`TyRow` (factored out of
-- `TyEffect`'s arm above so `TyRow` doesn't duplicate it — lint's
-- rule-duplicate-body would flag an inlined copy).
export
ppEffInsideTy : List EffAtomTy -> List String -> String
ppEffInsideTy effs tails =
  let labs = map ppEffAtomTy effs
  match tails
    [] => joinWith ", " labs
    _ =>
      let tls = joinWith " | " tails
      match effs
        [] => tls
        _ => "\{joinWith ", " labs} | \{tls}"

-- effect atom renderer for ppTy: the label and its written parameter.
export
ppEffAtomTy : EffAtomTy -> String
ppEffAtomTy a = effAtomSurface escStr a

-- single constraint: no outer parens; multiple: wrap in parens (mirrors OCaml)
export
ppConstraints : List Constraint -> String
ppConstraints [c] = ppConstraint c
ppConstraints cs = "(" ++ joinWith ", " (map ppConstraint cs) ++ ")"

-- argument of `->`: wrap TyFun (prec>=1) but not TyApp (prec<2)
export
ppTyFunArg : Ty -> String
ppTyFunArg (TyFun a b) = "(" ++ ppTy (TyFun a b) ++ ")"
ppTyFunArg t = ppTy t

-- argument of application: wrap TyFun (prec>=1) and TyApp (prec>=2)
export
ppTyAtom : Ty -> String
ppTyAtom (TyFun a b) = "(" ++ ppTy (TyFun a b) ++ ")"
ppTyAtom (TyApp a b) = "(" ++ ppTy (TyApp a b) ++ ")"
ppTyAtom t = ppTy t

export
ppConstraint : Constraint -> String
ppConstraint (Constraint { constraintHead = iface, constraintArgs = [] }) =
  iface
ppConstraint (Constraint { constraintHead = iface, constraintArgs = tys }) =
  "\{iface} \{joinWith " " (map ppTyAtom tys)}"
# DESUGAR
(DUse false (UseGroup ("types" "effect_authority") ((mem "Authority" true) (mem "Authvar" true) (mem "authvarId" false) (mem "authvarName" false) (mem "authNorm" false) (mem "authIsTop" false) (mem "renderAuthorityWith" false))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "renderAtoms" false) (mem "renderAtomsWith" false) (mem "Atom" true) (mem "effrowNorm" false) (mem "effrowLabels" false) (mem "rowFlat" false) (mem "effvarId" false) (mem "isJoinCell" false) (mem "EffRow" true) (mem "Effvar" true))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Ty" true) (mem "Constraint" true) (mem "TyConOrigin" true) (mem "EffAtomTy" true) (mem "effAtomSurface" false) (mem "authTermSurface" false))))
(DUse false (UseGroup ("support" "util") ((mem "listLen" false) (mem "filterList" false) (mem "isEmptyL" false) (mem "joinWith" false) (mem "sortUniqS" false) (mem "escStr" false))))
(DData Public "Mono" () ((variant "TVar" (ConPos (TyApp (TyCon "Ref") (TyCon "Tyvar")))) (variant "TCon" (ConPos (TyCon "String") (TyCon "TyConOrigin"))) (variant "TRigid" (ConPos (TyCon "String"))) (variant "TApp" (ConPos (TyCon "Mono") (TyCon "Mono"))) (variant "TFun" (ConPos (TyCon "Mono") (TyCon "EffRow") (TyCon "Mono"))) (variant "TEff" (ConPos (TyCon "EffRow"))) (variant "TQual" (ConPos (TyCon "Mono") (TyCon "Authority"))) (variant "TAuth" (ConPos (TyCon "Authority")))) ())
(DData Public "Tyvar" () ((variant "Unbound" (ConPos (TyCon "Int") (TyCon "Int"))) (variant "Link" (ConPos (TyCon "Mono")))) ())
(DData Public "Scheme" () ((variant "Forall" (ConPos (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int")) (TyCon "EffRow") (TyCon "Mono")))) ())
(DData Public "IfaceRef" () ((variant "IfaceRef" (ConNamed (field "irName" (TyCon "String")) (field "irOrigin" (TyCon "TyConOrigin"))))) ())
(DData Public "VecObl" () ((variant "VecObl" (ConNamed (field "voIface" (TyCon "IfaceRef")) (field "voIds" (TyApp (TyCon "List") (TyCon "Int"))) (field "voArgs" (TyApp (TyCon "List") (TyCon "Mono")))))) ())
(DTypeSig true "lookupAssocI" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyVar "b"))) (TyApp (TyCon "Option") (TyVar "b")))))
(DFunDef false "lookupAssocI" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupAssocI" ((PVar "k") (PCons (PTuple (PVar "k2") (PVar "v")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "k2")) (EApp (EVar "Some") (EVar "v")) (EIf (EVar "otherwise") (EApp (EApp (EVar "lookupAssocI") (EVar "k")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "normalize" (TyFun (TyCon "Mono") (TyCon "Mono")))
(DFunDef false "normalize" ((PVar "m")) (EMatch (EVar "m") (arm (PCon "TVar" (PVar "cell")) () (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "Link" (PVar "t")) () (EApp (EApp (EVar "normalizeLink") (EVar "cell")) (EVar "t"))) (arm (PCon "Unbound" PWild PWild) () (EVar "m")))) (arm PWild () (EVar "m"))))
(DTypeSig true "normalizeLink" (TyFun (TyApp (TyCon "Ref") (TyCon "Tyvar")) (TyFun (TyCon "Mono") (TyCon "Mono"))))
(DFunDef false "normalizeLink" ((PVar "cell") (PVar "t")) (EMatch (EVar "t") (arm (PCon "TVar" (PVar "c2")) () (EMatch (EUnOp "!" (EVar "c2")) (arm (PCon "Unbound" PWild PWild) () (EVar "t")) (arm (PCon "Link" (PVar "t2")) () (EBlock (DoLet false false (PVar "r") (EApp (EApp (EVar "normalizeLink") (EVar "c2")) (EVar "t2"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "cell")) (EApp (EVar "Link") (EVar "r")))) (DoExpr (EVar "r")))))) (arm PWild () (EVar "t"))))
(DTypeSig true "ppScheme" (TyFun (TyCon "Scheme") (TyCon "String")))
(DFunDef false "ppScheme" ((PCon "Forall" PWild PWild PWild (PVar "force") (PVar "t"))) (EApp (EApp (EApp (EApp (EVar "ppBinding") (EApp (EVar "Ref") (EListLit))) (EApp (EVar "Ref") (ELit (LInt 0)))) (EVar "force")) (EVar "t")))
(DTypeSig false "ppBinding" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String")))) (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyFun (TyCon "EffRow") (TyFun (TyCon "Mono") (TyCon "String"))))))
(DFunDef false "ppBinding" ((PVar "ctx") (PVar "cnt") (PVar "force") (PVar "t")) (EMatch (EApp (EVar "rowFlat") (EVar "force")) (arm (PTuple (PList) (PList)) () (EApp (EApp (EApp (EApp (EVar "ppGo") (EVar "ctx")) (EVar "cnt")) (ELit (LInt 0))) (EVar "t"))) (arm (PVar "flat") () (EBinOp "++" (EApp (EApp (EApp (EVar "ppEffectPrefix") (EVar "ctx")) (EVar "cnt")) (EVar "flat")) (EApp (EApp (EApp (EApp (EVar "ppGo") (EVar "ctx")) (EVar "cnt")) (ELit (LInt 2))) (EVar "t"))))))
(DTypeSig false "ppEffectPrefix" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String")))) (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Effvar")))) (TyCon "String")))))
(DFunDef false "ppEffectPrefix" (PWild PWild (PTuple (PList) (PList))) (ELit (LString "")))
(DFunDef false "ppEffectPrefix" ((PVar "ctx") (PVar "cnt") (PTuple (PVar "labels") (PVar "members"))) (EBlock (DoLet false false (PVar "atoms") (EApp (EApp (EVar "renderAtomsWith") (EApp (EApp (EVar "ppAuthvarName") (EVar "ctx")) (EVar "cnt"))) (EVar "labels"))) (DoLet false false (PVar "tails") (EApp (EApp (EVar "joinWith") (ELit (LString " | "))) (EApp (EApp (EVar "map") (EApp (EApp (EVar "ppEffvarName") (EVar "ctx")) (EVar "cnt"))) (EVar "members")))) (DoLet false false (PVar "inside") (EIf (EBinOp "==" (EVar "atoms") (ELit (LString ""))) (EVar "tails") (EIf (EBinOp "==" (EVar "tails") (ELit (LString ""))) (EVar "atoms") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "atoms"))) (ELit (LString " | "))) (EApp (EVar "display") (EVar "tails"))) (ELit (LString "")))))) (DoExpr (EBinOp "++" (EBinOp "++" (ELit (LString "<")) (EApp (EVar "display") (EVar "inside"))) (ELit (LString "> "))))))
(DTypeSig true "ppSchemeCon" (TyFun (TyApp (TyCon "List") (TyCon "VecObl")) (TyFun (TyCon "Scheme") (TyCon "String"))))
(DFunDef false "ppSchemeCon" ((PList) (PVar "s")) (EApp (EVar "ppScheme") (EVar "s")))
(DFunDef false "ppSchemeCon" ((PVar "cons") (PCon "Forall" PWild PWild PWild (PVar "force") (PVar "t"))) (EBlock (DoLet false false (PVar "ctx") (EApp (EVar "Ref") (EListLit))) (DoLet false false (PVar "cnt") (EApp (EVar "Ref") (ELit (LInt 0)))) (DoLet false false (PVar "body") (EApp (EApp (EApp (EApp (EVar "ppBinding") (EVar "ctx")) (EVar "cnt")) (EVar "force")) (EVar "t"))) (DoLet false false (PVar "rendered") (EApp (EVar "sortUniqS") (EApp (EApp (EApp (EVar "renderConstraintCtx") (EVar "ctx")) (EVar "cnt")) (EVar "cons")))) (DoLet false false (PVar "ctxStr") (EMatch (EVar "rendered") (arm (PList (PVar "c")) () (EVar "c")) (arm PWild () (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EVar "rendered"))) (ELit (LString ")")))))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "ctxStr"))) (ELit (LString " => "))) (EApp (EVar "display") (EVar "body"))) (ELit (LString ""))))))
(DTypeSig true "renderConstraintCtx" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String")))) (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "VecObl")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "renderConstraintCtx" (PWild PWild (PList)) (EListLit))
(DFunDef false "renderConstraintCtx" ((PVar "ctx") (PVar "cnt") (PCons (PVar "o") (PVar "rest"))) (EBlock (DoLet false false (PVar "s") (EIf (EApp (EVar "isEmptyL") (EFieldAccess (EVar "o") "voArgs")) (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EBinOp "::" (EFieldAccess (EFieldAccess (EVar "o") "voIface") "irName") (EApp (EApp (EVar "map") (ELam ((PVar "id")) (EApp (EApp (EApp (EVar "nameOf") (EVar "ctx")) (EVar "cnt")) (EVar "id")))) (EFieldAccess (EVar "o") "voIds")))) (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EBinOp "::" (EFieldAccess (EFieldAccess (EVar "o") "voIface") "irName") (EApp (EApp (EVar "map") (EApp (EApp (EApp (EVar "ppGo") (EVar "ctx")) (EVar "cnt")) (ELit (LInt 3)))) (EFieldAccess (EVar "o") "voArgs")))))) (DoExpr (EBinOp "::" (EVar "s") (EApp (EApp (EApp (EVar "renderConstraintCtx") (EVar "ctx")) (EVar "cnt")) (EVar "rest"))))))
(DTypeSig true "ppMono" (TyFun (TyCon "Mono") (TyCon "String")))
(DFunDef false "ppMono" ((PVar "t")) (EBlock (DoLet false false (PVar "ctx") (EApp (EVar "Ref") (EListLit))) (DoLet false false (PVar "cnt") (EApp (EVar "Ref") (ELit (LInt 0)))) (DoExpr (EApp (EApp (EApp (EApp (EVar "ppGo") (EVar "ctx")) (EVar "cnt")) (ELit (LInt 0))) (EVar "t")))))
(DTypeSig true "letters" (TyCon "String"))
(DFunDef false "letters" () (ELit (LString "abcdefghijklmnopqrstuvwxyz")))
(DTypeSig true "nameOf" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String")))) (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "nameOf" ((PVar "ctx") (PVar "cnt") (PVar "id")) (EMatch (EApp (EApp (EVar "lookupAssocI") (EVar "id")) (EUnOp "!" (EVar "ctx"))) (arm (PCon "Some" (PVar "s")) () (EVar "s")) (arm (PCon "None") () (EApp (EApp (EApp (EVar "assignName") (EVar "ctx")) (EVar "cnt")) (EVar "id")))))
(DTypeSig true "assignName" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String")))) (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "assignName" ((PVar "ctx") (PVar "cnt") (PVar "id")) (EBlock (DoLet false false (PVar "n") (EUnOp "!" (EVar "cnt"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "cnt")) (EBinOp "+" (EVar "n") (ELit (LInt 1))))) (DoLet false false (PVar "s") (EIf (EBinOp "<" (EVar "n") (ELit (LInt 26))) (EApp (EApp (EApp (EVar "stringSlice") (EVar "n")) (EBinOp "+" (EVar "n") (ELit (LInt 1)))) (EVar "letters")) (EBinOp "++" (ELit (LString "t")) (EApp (EVar "intToString") (EVar "n"))))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "ctx")) (EBinOp "::" (ETuple (EVar "id") (EVar "s")) (EUnOp "!" (EVar "ctx"))))) (DoExpr (EVar "s"))))
(DTypeSig true "ppGo" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String")))) (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Mono") (TyCon "String"))))))
(DFunDef false "ppGo" ((PVar "ctx") (PVar "cnt") (PVar "prec") (PVar "t")) (EMatch (EApp (EVar "normalize") (EVar "t")) (arm (PCon "TVar" (PVar "cell")) () (EApp (EApp (EApp (EVar "ppVar") (EVar "ctx")) (EVar "cnt")) (EVar "cell"))) (arm (PCon "TCon" (PVar "n") PWild) () (EApp (EVar "ppConName") (EVar "n"))) (arm (PCon "TRigid" (PVar "n")) () (EApp (EVar "ppConName") (EVar "n"))) (arm (PCon "TApp" (PVar "a") (PVar "b")) () (EApp (EApp (EApp (EApp (EApp (EVar "ppApp") (EVar "ctx")) (EVar "cnt")) (EVar "prec")) (EVar "a")) (EVar "b"))) (arm (PCon "TFun" (PVar "a") (PVar "eff") (PVar "b")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "ppFun") (EVar "ctx")) (EVar "cnt")) (EVar "prec")) (EVar "a")) (EVar "eff")) (EVar "b"))) (arm (PCon "TEff" (PVar "r")) () (EApp (EApp (EApp (EVar "ppEffArg") (EVar "ctx")) (EVar "cnt")) (EVar "r"))) (arm (PCon "TQual" (PVar "inner") (PVar "q")) () (EApp (EApp (EApp (EApp (EApp (EVar "ppQual") (EVar "ctx")) (EVar "cnt")) (EVar "prec")) (EVar "inner")) (EVar "q"))) (arm (PCon "TAuth" (PVar "q")) () (EApp (EApp (EApp (EVar "ppAuthArg") (EVar "ctx")) (EVar "cnt")) (EVar "q")))))
(DTypeSig true "ppAuthArg" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String")))) (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyFun (TyCon "Authority") (TyCon "String")))))
(DFunDef false "ppAuthArg" ((PVar "ctx") (PVar "cnt") (PVar "q")) (EIf (EApp (EVar "authIsTop") (EApp (EVar "authNorm") (EVar "q"))) (ELit (LString "*")) (EApp (EApp (EApp (EVar "ppAuthority") (EVar "ctx")) (EVar "cnt")) (EVar "q"))))
(DTypeSig true "ppQual" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String")))) (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Mono") (TyFun (TyCon "Authority") (TyCon "String")))))))
(DFunDef false "ppQual" ((PVar "ctx") (PVar "cnt") (PVar "prec") (PVar "inner") (PVar "q")) (EApp (EApp (EVar "wrapIf") (EBinOp ">" (EVar "prec") (ELit (LInt 2)))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EApp (EApp (EApp (EVar "ppGo") (EVar "ctx")) (EVar "cnt")) (ELit (LInt 3))) (EVar "inner")))) (ELit (LString " @"))) (EApp (EVar "display") (EApp (EApp (EApp (EVar "ppAuthority") (EVar "ctx")) (EVar "cnt")) (EVar "q")))) (ELit (LString "")))))
(DTypeSig true "ppAuthority" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String")))) (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyFun (TyCon "Authority") (TyCon "String")))))
(DFunDef false "ppAuthority" ((PVar "ctx") (PVar "cnt") (PVar "q")) (EBlock (DoLet false false (PVar "s") (EApp (EApp (EVar "renderAuthorityWith") (EApp (EApp (EVar "ppAuthvarName") (EVar "ctx")) (EVar "cnt"))) (EVar "q"))) (DoExpr (EIf (EBinOp "&&" (EBinOp ">" (EApp (EVar "stringLength") (EVar "s")) (ELit (LInt 0))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 1))) (EVar "s")) (ELit (LString " ")))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 1))) (EApp (EVar "stringLength") (EVar "s"))) (EVar "s")) (EVar "s")))))
(DTypeSig true "ppAuthvarName" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String")))) (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyFun (TyApp (TyCon "Ref") (TyCon "Authvar")) (TyCon "String")))))
(DFunDef false "ppAuthvarName" ((PVar "ctx") (PVar "cnt") (PVar "cell")) (EBlock (DoLet false false (PVar "key") (EBinOp "+" (EApp (EVar "authvarId") (EVar "cell")) (ELit (LInt 2000000)))) (DoExpr (EMatch (EApp (EApp (EVar "lookupAssocI") (EVar "key")) (EUnOp "!" (EVar "ctx"))) (arm (PCon "Some" (PVar "s")) () (EVar "s")) (arm (PCon "None") () (EMatch (EApp (EVar "authvarName") (EVar "cell")) (arm (PCon "Some" (PVar "n")) () (EIf (EApp (EApp (EVar "nameTaken") (EVar "n")) (EUnOp "!" (EVar "ctx"))) (EApp (EApp (EApp (EVar "assignName") (EVar "ctx")) (EVar "cnt")) (EVar "key")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EVar "ctx")) (EBinOp "::" (ETuple (EVar "key") (EVar "n")) (EUnOp "!" (EVar "ctx"))))) (DoExpr (EVar "n"))))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "assignName") (EVar "ctx")) (EVar "cnt")) (EVar "key")))))))))
(DTypeSig false "nameTaken" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String"))) (TyCon "Bool"))))
(DFunDef false "nameTaken" (PWild (PList)) (EVar "False"))
(DFunDef false "nameTaken" ((PVar "n") (PCons (PTuple PWild (PVar "s")) (PVar "rest"))) (EBinOp "||" (EBinOp "==" (EVar "s") (EVar "n")) (EApp (EApp (EVar "nameTaken") (EVar "n")) (EVar "rest"))))
(DTypeSig true "ppEffArg" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String")))) (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyFun (TyCon "EffRow") (TyCon "String")))))
(DFunDef false "ppEffArg" ((PVar "ctx") (PVar "cnt") (PVar "r")) (EMatch (EApp (EVar "effrowNorm") (EVar "r")) (arm (PCon "EffRow" (PVar "labels") (PVar "tail")) () (EBlock (DoLet false false (PVar "lbl") (EMatch (EVar "labels") (arm (PList) () (ELit (LString ""))) (arm (PVar "ls") () (EApp (EApp (EVar "renderAtomsWith") (EApp (EApp (EVar "ppAuthvarName") (EVar "ctx")) (EVar "cnt"))) (EVar "ls"))))) (DoLet false false (PVar "tailS") (EMatch (EVar "tail") (arm (PCon "Some" (PVar "cell")) () (EApp (EApp (EApp (EVar "ppEffvarName") (EVar "ctx")) (EVar "cnt")) (EVar "cell"))) (arm (PCon "None") () (ELit (LString ""))))) (DoExpr (EMatch (EVar "tail") (arm (PCon "Some" (PVar "cell")) () (EIf (EBinOp "&&" (EApp (EVar "isJoinCell") (EVar "cell")) (EBinOp "==" (EVar "lbl") (ELit (LString "")))) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EVar "tailS")) (ELit (LString ")"))) (EApp (EApp (EVar "ppEffArgFmt") (EVar "lbl")) (EVar "tailS")))) (arm (PCon "None") () (EApp (EApp (EVar "ppEffArgFmt") (EVar "lbl")) (EVar "tailS")))))))))
(DTypeSig true "ppEffvarName" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String")))) (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyFun (TyApp (TyCon "Ref") (TyCon "Effvar")) (TyCon "String")))))
(DFunDef false "ppEffvarName" ((PVar "ctx") (PVar "cnt") (PVar "cell")) (EApp (EApp (EVar "joinWith") (ELit (LString " | "))) (EApp (EApp (EVar "map") (ELam ((PVar "m")) (EApp (EApp (EApp (EVar "nameOf") (EVar "ctx")) (EVar "cnt")) (EBinOp "+" (EApp (EVar "effvarId") (EVar "m")) (ELit (LInt 1000000)))))) (EApp (EVar "snd") (EApp (EVar "rowFlat") (EApp (EApp (EVar "EffRow") (EListLit)) (EApp (EVar "Some") (EVar "cell"))))))))
(DTypeSig true "ppEffArgFmt" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "ppEffArgFmt" ((PVar "l") (PVar "t")) (EIf (EBinOp "&&" (EBinOp "==" (EVar "l") (ELit (LString ""))) (EBinOp "==" (EVar "t") (ELit (LString "")))) (ELit (LString "<>")) (EIf (EBinOp "==" (EVar "l") (ELit (LString ""))) (EVar "t") (EIf (EBinOp "==" (EVar "t") (ELit (LString ""))) (EBinOp "++" (EBinOp "++" (ELit (LString "<")) (EVar "l")) (ELit (LString ">"))) (EIf (EVar "otherwise") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "<")) (EApp (EVar "display") (EVar "l"))) (ELit (LString " | "))) (EApp (EVar "display") (EVar "t"))) (ELit (LString ">"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig true "ppVar" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String")))) (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyFun (TyApp (TyCon "Ref") (TyCon "Tyvar")) (TyCon "String")))))
(DFunDef false "ppVar" ((PVar "ctx") (PVar "cnt") (PVar "cell")) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "Unbound" (PVar "id") PWild) () (EApp (EApp (EApp (EVar "nameOf") (EVar "ctx")) (EVar "cnt")) (EVar "id"))) (arm (PCon "Link" PWild) () (ELit (LString "_")))))
(DTypeSig true "ppApp" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String")))) (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "String")))))))
(DFunDef false "ppApp" ((PVar "ctx") (PVar "cnt") (PVar "prec") (PVar "a") (PVar "b")) (EMatch (EApp (EVar "tupleSpine") (EApp (EApp (EVar "TApp") (EVar "a")) (EVar "b"))) (arm (PCon "Some" (PVar "ts")) () (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EApp (EApp (EVar "ppEach") (EVar "ctx")) (EVar "cnt")) (ELit (LInt 0))) (EVar "ts")))) (ELit (LString ")")))) (arm (PCon "None") () (EBlock (DoLet false false (PVar "sa") (EApp (EApp (EApp (EApp (EVar "ppGo") (EVar "ctx")) (EVar "cnt")) (ELit (LInt 2))) (EVar "a"))) (DoLet false false (PVar "sb") (EApp (EApp (EApp (EApp (EVar "ppGo") (EVar "ctx")) (EVar "cnt")) (ELit (LInt 3))) (EVar "b"))) (DoExpr (EApp (EApp (EVar "wrapIf") (EBinOp ">" (EVar "prec") (ELit (LInt 2)))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "sa"))) (ELit (LString " "))) (EApp (EVar "display") (EVar "sb"))) (ELit (LString "")))))))))
(DTypeSig true "ppFun" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String")))) (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Mono") (TyFun (TyCon "EffRow") (TyFun (TyCon "Mono") (TyCon "String"))))))))
(DFunDef false "ppFun" ((PVar "ctx") (PVar "cnt") (PVar "prec") (PVar "a") (PVar "eff") (PVar "b")) (EBlock (DoLet false false (PVar "sa") (EApp (EApp (EApp (EVar "ppDomain") (EVar "ctx")) (EVar "cnt")) (EVar "a"))) (DoLet false false (PVar "se") (EApp (EApp (EApp (EVar "ppEffectPrefix") (EVar "ctx")) (EVar "cnt")) (EApp (EVar "rowFlat") (EVar "eff")))) (DoLet false false (PVar "sb") (EApp (EApp (EApp (EApp (EVar "ppGo") (EVar "ctx")) (EVar "cnt")) (ELit (LInt 1))) (EVar "b"))) (DoExpr (EApp (EApp (EVar "wrapIf") (EBinOp ">" (EVar "prec") (ELit (LInt 1)))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "sa"))) (ELit (LString " -> "))) (EApp (EVar "display") (EVar "se"))) (ELit (LString ""))) (EApp (EVar "display") (EVar "sb"))) (ELit (LString "")))))))
(DTypeSig false "ppDomain" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String")))) (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyFun (TyCon "Mono") (TyCon "String")))))
(DFunDef false "ppDomain" ((PVar "ctx") (PVar "cnt") (PVar "a")) (EMatch (EApp (EVar "normalize") (EVar "a")) (arm (PCon "TQual" (PVar "inner") (PCon "AVar" (PVar "cell"))) () (EIf (EApp (EVar "isSome") (EApp (EApp (EVar "lookupAssocI") (EBinOp "+" (EApp (EVar "authvarId") (EVar "cell")) (ELit (LInt 2000000)))) (EUnOp "!" (EVar "ctx")))) (EApp (EApp (EApp (EApp (EVar "ppGo") (EVar "ctx")) (EVar "cnt")) (ELit (LInt 2))) (EVar "a")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EVar "display") (EApp (EApp (EApp (EVar "ppAuthvarName") (EVar "ctx")) (EVar "cnt")) (EVar "cell")))) (ELit (LString " : "))) (EApp (EVar "display") (EApp (EApp (EApp (EApp (EVar "ppGo") (EVar "ctx")) (EVar "cnt")) (ELit (LInt 0))) (EVar "inner")))) (ELit (LString ")"))))) (arm PWild () (EApp (EApp (EApp (EApp (EVar "ppGo") (EVar "ctx")) (EVar "cnt")) (ELit (LInt 2))) (EVar "a")))))
(DTypeSig true "effStr" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "String")))
(DFunDef false "effStr" ((PList)) (ELit (LString "")))
(DFunDef false "effStr" ((PVar "labels")) (EBinOp "++" (EBinOp "++" (ELit (LString "<")) (EApp (EVar "renderAtoms") (EVar "labels"))) (ELit (LString "> "))))
(DTypeSig true "ppEach" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String")))) (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "ppEach" (PWild PWild PWild (PList)) (EListLit))
(DFunDef false "ppEach" ((PVar "ctx") (PVar "cnt") (PVar "prec") (PCons (PVar "t") (PVar "ts"))) (EBlock (DoLet false false (PVar "s") (EApp (EApp (EApp (EApp (EVar "ppGo") (EVar "ctx")) (EVar "cnt")) (EVar "prec")) (EVar "t"))) (DoExpr (EBinOp "::" (EVar "s") (EApp (EApp (EApp (EApp (EVar "ppEach") (EVar "ctx")) (EVar "cnt")) (EVar "prec")) (EVar "ts"))))))
(DTypeSig true "wrapIf" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "wrapIf" ((PCon "True") (PVar "s")) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EVar "s")) (ELit (LString ")"))))
(DFunDef false "wrapIf" ((PCon "False") (PVar "s")) (EVar "s"))
(DTypeSig true "ppPredArgsShared" (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "String")))
(DFunDef false "ppPredArgsShared" ((PVar "ms")) (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EApp (EApp (EVar "ppEach") (EApp (EVar "Ref") (EListLit))) (EApp (EVar "Ref") (ELit (LInt 0)))) (ELit (LInt 3))) (EVar "ms"))))
(DTypeSig true "tupleHeadTagTc" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "tupleHeadTagTc" ((PVar "n")) (EBinOp "++" (EBinOp "++" (ELit (LString "__tuple")) (EApp (EVar "intToString") (EVar "n"))) (ELit (LString "__"))))
(DTypeSig true "spineParts" (TyFun (TyCon "Mono") (TyTuple (TyCon "Mono") (TyApp (TyCon "List") (TyCon "Mono")))))
(DFunDef false "spineParts" ((PVar "t")) (EMatch (EApp (EVar "normalize") (EVar "t")) (arm (PCon "TApp" (PVar "a") (PVar "b")) () (EMatch (EApp (EVar "spineParts") (EVar "a")) (arm (PTuple (PVar "h") (PVar "args")) () (ETuple (EVar "h") (EBinOp "++" (EVar "args") (EListLit (EVar "b"))))))) (arm (PVar "other") () (ETuple (EVar "other") (EListLit)))))
(DTypeSig true "tupleSpine" (TyFun (TyCon "Mono") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Mono")))))
(DFunDef false "tupleSpine" ((PVar "t")) (EMatch (EApp (EVar "spineParts") (EVar "t")) (arm (PTuple (PCon "TCon" (PVar "n") PWild) (PVar "args")) () (EIf (EBinOp "&&" (EBinOp ">=" (EApp (EVar "listLen") (EVar "args")) (ELit (LInt 2))) (EBinOp "==" (EVar "n") (EApp (EVar "tupleHeadTagTc") (EApp (EVar "listLen") (EVar "args"))))) (EApp (EVar "Some") (EVar "args")) (EVar "None"))) (arm (PTuple (PCon "TRigid" (PVar "n")) (PVar "args")) () (EIf (EBinOp "&&" (EBinOp ">=" (EApp (EVar "listLen") (EVar "args")) (ELit (LInt 2))) (EBinOp "==" (EVar "n") (EApp (EVar "tupleHeadTagTc") (EApp (EVar "listLen") (EVar "args"))))) (EApp (EVar "Some") (EVar "args")) (EVar "None"))) (arm PWild () (EVar "None"))))
(DTypeSig true "tupleTagArity" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "tupleTagArity" ((PVar "n")) (EApp (EApp (EVar "tupleTagArityGo") (EVar "n")) (ELit (LInt 2))))
(DTypeSig true "tupleTagArityGo" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "tupleTagArityGo" ((PVar "n") (PVar "k")) (EIf (EBinOp ">" (EVar "k") (ELit (LInt 32))) (EVar "None") (EIf (EBinOp "==" (EApp (EVar "tupleHeadTagTc") (EVar "k")) (EVar "n")) (EApp (EVar "Some") (EVar "k")) (EIf (EVar "otherwise") (EApp (EApp (EVar "tupleTagArityGo") (EVar "n")) (EBinOp "+" (EVar "k") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "commaStr" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "commaStr" ((PVar "n")) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (ELit (LString "")) (EBinOp "++" (ELit (LString ",")) (EApp (EVar "commaStr") (EBinOp "-" (EVar "n") (ELit (LInt 1)))))))
(DTypeSig true "ppConName" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "ppConName" ((PVar "n")) (EMatch (EApp (EVar "tupleTagArity") (EVar "n")) (arm (PCon "Some" (PVar "k")) () (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EVar "commaStr") (EBinOp "-" (EVar "k") (ELit (LInt 1))))) (ELit (LString ")")))) (arm (PCon "None") () (EVar "n"))))
(DTypeSig true "ppMonosShared" (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "String")))
(DFunDef false "ppMonosShared" ((PVar "ms")) (EBlock (DoLet false false (PVar "ctx") (EApp (EVar "Ref") (EListLit))) (DoLet false false (PVar "cnt") (EApp (EVar "Ref") (ELit (LInt 0)))) (DoExpr (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EApp (EVar "ppEachShared") (EVar "ctx")) (EVar "cnt")) (EVar "ms"))))))
(DTypeSig true "ppEachShared" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String")))) (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "ppEachShared" ((PVar "ctx") (PVar "cnt") (PVar "ms")) (EApp (EApp (EVar "map") (EApp (EApp (EApp (EVar "ppGo") (EVar "ctx")) (EVar "cnt")) (ELit (LInt 2)))) (EVar "ms")))
(DTypeSig true "ppTy" (TyFun (TyCon "Ty") (TyCon "String")))
(DFunDef false "ppTy" ((PRec "TyCon" ((rf "tyConName" (PVar "n"))) false)) (EVar "n"))
(DFunDef false "ppTy" ((PCon "TyVar" (PVar "n"))) (EVar "n"))
(DFunDef false "ppTy" ((PCon "TyApp" (PVar "a") (PVar "b"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "ppTy") (EVar "a")))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EVar "ppTyAtom") (EVar "b")))) (ELit (LString ""))))
(DFunDef false "ppTy" ((PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "ppTyFunArg") (EVar "a")))) (ELit (LString " -> "))) (EApp (EVar "display") (EApp (EVar "ppTy") (EVar "b")))) (ELit (LString ""))))
(DFunDef false "ppTy" ((PCon "TyTuple" (PVar "ts"))) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "map") (EVar "ppTy")) (EVar "ts")))) (ELit (LString ")"))))
(DFunDef false "ppTy" ((PCon "TyEffect" (PVar "effs") (PVar "tail") (PVar "t"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "<")) (EApp (EVar "display") (EApp (EApp (EVar "ppEffInsideTy") (EVar "effs")) (EVar "tail")))) (ELit (LString "> "))) (EApp (EVar "display") (EApp (EVar "ppTy") (EVar "t")))) (ELit (LString ""))))
(DFunDef false "ppTy" ((PCon "TyRow" (PList) (PCons (PVar "a") (PCons (PVar "b") (PVar "rest"))) PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString " | "))) (EBinOp "::" (EVar "a") (EBinOp "::" (EVar "b") (EVar "rest")))))) (ELit (LString ")"))))
(DFunDef false "ppTy" ((PCon "TyRow" (PVar "effs") (PVar "tail") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "<")) (EApp (EVar "display") (EApp (EApp (EVar "ppEffInsideTy") (EVar "effs")) (EVar "tail")))) (ELit (LString ">"))))
(DFunDef false "ppTy" ((PCon "TyAuth" (PVar "p") PWild)) (EApp (EApp (EVar "authTermSurface") (EVar "escStr")) (EVar "p")))
(DFunDef false "ppTy" ((PCon "TyConstrained" (PVar "cs") (PVar "t"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "ppConstraints") (EVar "cs")))) (ELit (LString " => "))) (EApp (EVar "display") (EApp (EVar "ppTy") (EVar "t")))) (ELit (LString ""))))
(DFunDef false "ppTy" ((PCon "TyNamed" (PVar "n") (PVar "t"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EVar "display") (EVar "n"))) (ELit (LString " : "))) (EApp (EVar "display") (EApp (EVar "ppTy") (EVar "t")))) (ELit (LString ")"))))
(DFunDef false "ppTy" ((PCon "TyQual" (PVar "t") (PVar "n"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "ppTyAtom") (EVar "t")))) (ELit (LString " @"))) (EApp (EVar "display") (EVar "n"))) (ELit (LString ""))))
(DTypeSig true "ppEffInsideTy" (TyFun (TyApp (TyCon "List") (TyCon "EffAtomTy")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))
(DFunDef false "ppEffInsideTy" ((PVar "effs") (PVar "tails")) (EBlock (DoLet false false (PVar "labs") (EApp (EApp (EVar "map") (EVar "ppEffAtomTy")) (EVar "effs"))) (DoExpr (EMatch (EVar "tails") (arm (PList) () (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EVar "labs"))) (arm PWild () (EBlock (DoLet false false (PVar "tls") (EApp (EApp (EVar "joinWith") (ELit (LString " | "))) (EVar "tails"))) (DoExpr (EMatch (EVar "effs") (arm (PList) () (EVar "tls")) (arm PWild () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EVar "labs")))) (ELit (LString " | "))) (EApp (EVar "display") (EVar "tls"))) (ELit (LString ""))))))))))))
(DTypeSig true "ppEffAtomTy" (TyFun (TyCon "EffAtomTy") (TyCon "String")))
(DFunDef false "ppEffAtomTy" ((PVar "a")) (EApp (EApp (EVar "effAtomSurface") (EVar "escStr")) (EVar "a")))
(DTypeSig true "ppConstraints" (TyFun (TyApp (TyCon "List") (TyCon "Constraint")) (TyCon "String")))
(DFunDef false "ppConstraints" ((PList (PVar "c"))) (EApp (EVar "ppConstraint") (EVar "c")))
(DFunDef false "ppConstraints" ((PVar "cs")) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "map") (EVar "ppConstraint")) (EVar "cs")))) (ELit (LString ")"))))
(DTypeSig true "ppTyFunArg" (TyFun (TyCon "Ty") (TyCon "String")))
(DFunDef false "ppTyFunArg" ((PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EVar "ppTy") (EApp (EApp (EVar "TyFun") (EVar "a")) (EVar "b")))) (ELit (LString ")"))))
(DFunDef false "ppTyFunArg" ((PVar "t")) (EApp (EVar "ppTy") (EVar "t")))
(DTypeSig true "ppTyAtom" (TyFun (TyCon "Ty") (TyCon "String")))
(DFunDef false "ppTyAtom" ((PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EVar "ppTy") (EApp (EApp (EVar "TyFun") (EVar "a")) (EVar "b")))) (ELit (LString ")"))))
(DFunDef false "ppTyAtom" ((PCon "TyApp" (PVar "a") (PVar "b"))) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EVar "ppTy") (EApp (EApp (EVar "TyApp") (EVar "a")) (EVar "b")))) (ELit (LString ")"))))
(DFunDef false "ppTyAtom" ((PVar "t")) (EApp (EVar "ppTy") (EVar "t")))
(DTypeSig true "ppConstraint" (TyFun (TyCon "Constraint") (TyCon "String")))
(DFunDef false "ppConstraint" ((PRec "Constraint" ((rf "constraintHead" (PVar "iface")) (rf "constraintArgs" (PList))) false)) (EVar "iface"))
(DFunDef false "ppConstraint" ((PRec "Constraint" ((rf "constraintHead" (PVar "iface")) (rf "constraintArgs" (PVar "tys"))) false)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "iface"))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EVar "map") (EVar "ppTyAtom")) (EVar "tys"))))) (ELit (LString ""))))
# MARK
(DUse false (UseGroup ("types" "effect_authority") ((mem "Authority" true) (mem "Authvar" true) (mem "authvarId" false) (mem "authvarName" false) (mem "authNorm" false) (mem "authIsTop" false) (mem "renderAuthorityWith" false))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "renderAtoms" false) (mem "renderAtomsWith" false) (mem "Atom" true) (mem "effrowNorm" false) (mem "effrowLabels" false) (mem "rowFlat" false) (mem "effvarId" false) (mem "isJoinCell" false) (mem "EffRow" true) (mem "Effvar" true))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Ty" true) (mem "Constraint" true) (mem "TyConOrigin" true) (mem "EffAtomTy" true) (mem "effAtomSurface" false) (mem "authTermSurface" false))))
(DUse false (UseGroup ("support" "util") ((mem "listLen" false) (mem "filterList" false) (mem "isEmptyL" false) (mem "joinWith" false) (mem "sortUniqS" false) (mem "escStr" false))))
(DData Public "Mono" () ((variant "TVar" (ConPos (TyApp (TyCon "Ref") (TyCon "Tyvar")))) (variant "TCon" (ConPos (TyCon "String") (TyCon "TyConOrigin"))) (variant "TRigid" (ConPos (TyCon "String"))) (variant "TApp" (ConPos (TyCon "Mono") (TyCon "Mono"))) (variant "TFun" (ConPos (TyCon "Mono") (TyCon "EffRow") (TyCon "Mono"))) (variant "TEff" (ConPos (TyCon "EffRow"))) (variant "TQual" (ConPos (TyCon "Mono") (TyCon "Authority"))) (variant "TAuth" (ConPos (TyCon "Authority")))) ())
(DData Public "Tyvar" () ((variant "Unbound" (ConPos (TyCon "Int") (TyCon "Int"))) (variant "Link" (ConPos (TyCon "Mono")))) ())
(DData Public "Scheme" () ((variant "Forall" (ConPos (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int")) (TyCon "EffRow") (TyCon "Mono")))) ())
(DData Public "IfaceRef" () ((variant "IfaceRef" (ConNamed (field "irName" (TyCon "String")) (field "irOrigin" (TyCon "TyConOrigin"))))) ())
(DData Public "VecObl" () ((variant "VecObl" (ConNamed (field "voIface" (TyCon "IfaceRef")) (field "voIds" (TyApp (TyCon "List") (TyCon "Int"))) (field "voArgs" (TyApp (TyCon "List") (TyCon "Mono")))))) ())
(DTypeSig true "lookupAssocI" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyVar "b"))) (TyApp (TyCon "Option") (TyVar "b")))))
(DFunDef false "lookupAssocI" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupAssocI" ((PVar "k") (PCons (PTuple (PVar "k2") (PVar "v")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "k2")) (EApp (EVar "Some") (EVar "v")) (EIf (EVar "otherwise") (EApp (EApp (EVar "lookupAssocI") (EVar "k")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "normalize" (TyFun (TyCon "Mono") (TyCon "Mono")))
(DFunDef false "normalize" ((PVar "m")) (EMatch (EVar "m") (arm (PCon "TVar" (PVar "cell")) () (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "Link" (PVar "t")) () (EApp (EApp (EVar "normalizeLink") (EVar "cell")) (EVar "t"))) (arm (PCon "Unbound" PWild PWild) () (EVar "m")))) (arm PWild () (EVar "m"))))
(DTypeSig true "normalizeLink" (TyFun (TyApp (TyCon "Ref") (TyCon "Tyvar")) (TyFun (TyCon "Mono") (TyCon "Mono"))))
(DFunDef false "normalizeLink" ((PVar "cell") (PVar "t")) (EMatch (EVar "t") (arm (PCon "TVar" (PVar "c2")) () (EMatch (EUnOp "!" (EVar "c2")) (arm (PCon "Unbound" PWild PWild) () (EVar "t")) (arm (PCon "Link" (PVar "t2")) () (EBlock (DoLet false false (PVar "r") (EApp (EApp (EVar "normalizeLink") (EVar "c2")) (EVar "t2"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "cell")) (EApp (EVar "Link") (EVar "r")))) (DoExpr (EVar "r")))))) (arm PWild () (EVar "t"))))
(DTypeSig true "ppScheme" (TyFun (TyCon "Scheme") (TyCon "String")))
(DFunDef false "ppScheme" ((PCon "Forall" PWild PWild PWild (PVar "force") (PVar "t"))) (EApp (EApp (EApp (EApp (EVar "ppBinding") (EApp (EVar "Ref") (EListLit))) (EApp (EVar "Ref") (ELit (LInt 0)))) (EVar "force")) (EVar "t")))
(DTypeSig false "ppBinding" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String")))) (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyFun (TyCon "EffRow") (TyFun (TyCon "Mono") (TyCon "String"))))))
(DFunDef false "ppBinding" ((PVar "ctx") (PVar "cnt") (PVar "force") (PVar "t")) (EMatch (EApp (EVar "rowFlat") (EVar "force")) (arm (PTuple (PList) (PList)) () (EApp (EApp (EApp (EApp (EVar "ppGo") (EVar "ctx")) (EVar "cnt")) (ELit (LInt 0))) (EVar "t"))) (arm (PVar "flat") () (EBinOp "++" (EApp (EApp (EApp (EVar "ppEffectPrefix") (EVar "ctx")) (EVar "cnt")) (EDictApp "flat")) (EApp (EApp (EApp (EApp (EVar "ppGo") (EVar "ctx")) (EVar "cnt")) (ELit (LInt 2))) (EVar "t"))))))
(DTypeSig false "ppEffectPrefix" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String")))) (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyApp (TyCon "Ref") (TyCon "Effvar")))) (TyCon "String")))))
(DFunDef false "ppEffectPrefix" (PWild PWild (PTuple (PList) (PList))) (ELit (LString "")))
(DFunDef false "ppEffectPrefix" ((PVar "ctx") (PVar "cnt") (PTuple (PVar "labels") (PVar "members"))) (EBlock (DoLet false false (PVar "atoms") (EApp (EApp (EVar "renderAtomsWith") (EApp (EApp (EVar "ppAuthvarName") (EVar "ctx")) (EVar "cnt"))) (EVar "labels"))) (DoLet false false (PVar "tails") (EApp (EApp (EVar "joinWith") (ELit (LString " | "))) (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "ppEffvarName") (EVar "ctx")) (EVar "cnt"))) (EVar "members")))) (DoLet false false (PVar "inside") (EIf (EBinOp "==" (EVar "atoms") (ELit (LString ""))) (EVar "tails") (EIf (EBinOp "==" (EVar "tails") (ELit (LString ""))) (EVar "atoms") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "atoms"))) (ELit (LString " | "))) (EApp (EMethodRef "display") (EVar "tails"))) (ELit (LString "")))))) (DoExpr (EBinOp "++" (EBinOp "++" (ELit (LString "<")) (EApp (EMethodRef "display") (EVar "inside"))) (ELit (LString "> "))))))
(DTypeSig true "ppSchemeCon" (TyFun (TyApp (TyCon "List") (TyCon "VecObl")) (TyFun (TyCon "Scheme") (TyCon "String"))))
(DFunDef false "ppSchemeCon" ((PList) (PVar "s")) (EApp (EVar "ppScheme") (EVar "s")))
(DFunDef false "ppSchemeCon" ((PVar "cons") (PCon "Forall" PWild PWild PWild (PVar "force") (PVar "t"))) (EBlock (DoLet false false (PVar "ctx") (EApp (EVar "Ref") (EListLit))) (DoLet false false (PVar "cnt") (EApp (EVar "Ref") (ELit (LInt 0)))) (DoLet false false (PVar "body") (EApp (EApp (EApp (EApp (EVar "ppBinding") (EVar "ctx")) (EVar "cnt")) (EVar "force")) (EVar "t"))) (DoLet false false (PVar "rendered") (EApp (EVar "sortUniqS") (EApp (EApp (EApp (EVar "renderConstraintCtx") (EVar "ctx")) (EVar "cnt")) (EVar "cons")))) (DoLet false false (PVar "ctxStr") (EMatch (EVar "rendered") (arm (PList (PVar "c")) () (EVar "c")) (arm PWild () (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EVar "rendered"))) (ELit (LString ")")))))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "ctxStr"))) (ELit (LString " => "))) (EApp (EMethodRef "display") (EVar "body"))) (ELit (LString ""))))))
(DTypeSig true "renderConstraintCtx" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String")))) (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "VecObl")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "renderConstraintCtx" (PWild PWild (PList)) (EListLit))
(DFunDef false "renderConstraintCtx" ((PVar "ctx") (PVar "cnt") (PCons (PVar "o") (PVar "rest"))) (EBlock (DoLet false false (PVar "s") (EIf (EApp (EVar "isEmptyL") (EFieldAccess (EVar "o") "voArgs")) (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EBinOp "::" (EFieldAccess (EFieldAccess (EVar "o") "voIface") "irName") (EApp (EApp (EMethodRef "map") (ELam ((PVar "id")) (EApp (EApp (EApp (EVar "nameOf") (EVar "ctx")) (EVar "cnt")) (EVar "id")))) (EFieldAccess (EVar "o") "voIds")))) (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EBinOp "::" (EFieldAccess (EFieldAccess (EVar "o") "voIface") "irName") (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EVar "ppGo") (EVar "ctx")) (EVar "cnt")) (ELit (LInt 3)))) (EFieldAccess (EVar "o") "voArgs")))))) (DoExpr (EBinOp "::" (EVar "s") (EApp (EApp (EApp (EVar "renderConstraintCtx") (EVar "ctx")) (EVar "cnt")) (EVar "rest"))))))
(DTypeSig true "ppMono" (TyFun (TyCon "Mono") (TyCon "String")))
(DFunDef false "ppMono" ((PVar "t")) (EBlock (DoLet false false (PVar "ctx") (EApp (EVar "Ref") (EListLit))) (DoLet false false (PVar "cnt") (EApp (EVar "Ref") (ELit (LInt 0)))) (DoExpr (EApp (EApp (EApp (EApp (EVar "ppGo") (EVar "ctx")) (EVar "cnt")) (ELit (LInt 0))) (EVar "t")))))
(DTypeSig true "letters" (TyCon "String"))
(DFunDef false "letters" () (ELit (LString "abcdefghijklmnopqrstuvwxyz")))
(DTypeSig true "nameOf" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String")))) (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "nameOf" ((PVar "ctx") (PVar "cnt") (PVar "id")) (EMatch (EApp (EApp (EVar "lookupAssocI") (EVar "id")) (EUnOp "!" (EVar "ctx"))) (arm (PCon "Some" (PVar "s")) () (EVar "s")) (arm (PCon "None") () (EApp (EApp (EApp (EVar "assignName") (EVar "ctx")) (EVar "cnt")) (EVar "id")))))
(DTypeSig true "assignName" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String")))) (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "assignName" ((PVar "ctx") (PVar "cnt") (PVar "id")) (EBlock (DoLet false false (PVar "n") (EUnOp "!" (EVar "cnt"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "cnt")) (EBinOp "+" (EVar "n") (ELit (LInt 1))))) (DoLet false false (PVar "s") (EIf (EBinOp "<" (EVar "n") (ELit (LInt 26))) (EApp (EApp (EApp (EVar "stringSlice") (EVar "n")) (EBinOp "+" (EVar "n") (ELit (LInt 1)))) (EVar "letters")) (EBinOp "++" (ELit (LString "t")) (EApp (EVar "intToString") (EVar "n"))))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "ctx")) (EBinOp "::" (ETuple (EVar "id") (EVar "s")) (EUnOp "!" (EVar "ctx"))))) (DoExpr (EVar "s"))))
(DTypeSig true "ppGo" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String")))) (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Mono") (TyCon "String"))))))
(DFunDef false "ppGo" ((PVar "ctx") (PVar "cnt") (PVar "prec") (PVar "t")) (EMatch (EApp (EVar "normalize") (EVar "t")) (arm (PCon "TVar" (PVar "cell")) () (EApp (EApp (EApp (EVar "ppVar") (EVar "ctx")) (EVar "cnt")) (EVar "cell"))) (arm (PCon "TCon" (PVar "n") PWild) () (EApp (EVar "ppConName") (EVar "n"))) (arm (PCon "TRigid" (PVar "n")) () (EApp (EVar "ppConName") (EVar "n"))) (arm (PCon "TApp" (PVar "a") (PVar "b")) () (EApp (EApp (EApp (EApp (EApp (EVar "ppApp") (EVar "ctx")) (EVar "cnt")) (EVar "prec")) (EVar "a")) (EVar "b"))) (arm (PCon "TFun" (PVar "a") (PVar "eff") (PVar "b")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "ppFun") (EVar "ctx")) (EVar "cnt")) (EVar "prec")) (EVar "a")) (EVar "eff")) (EVar "b"))) (arm (PCon "TEff" (PVar "r")) () (EApp (EApp (EApp (EVar "ppEffArg") (EVar "ctx")) (EVar "cnt")) (EVar "r"))) (arm (PCon "TQual" (PVar "inner") (PVar "q")) () (EApp (EApp (EApp (EApp (EApp (EVar "ppQual") (EVar "ctx")) (EVar "cnt")) (EVar "prec")) (EVar "inner")) (EVar "q"))) (arm (PCon "TAuth" (PVar "q")) () (EApp (EApp (EApp (EVar "ppAuthArg") (EVar "ctx")) (EVar "cnt")) (EVar "q")))))
(DTypeSig true "ppAuthArg" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String")))) (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyFun (TyCon "Authority") (TyCon "String")))))
(DFunDef false "ppAuthArg" ((PVar "ctx") (PVar "cnt") (PVar "q")) (EIf (EApp (EVar "authIsTop") (EApp (EVar "authNorm") (EVar "q"))) (ELit (LString "*")) (EApp (EApp (EApp (EVar "ppAuthority") (EVar "ctx")) (EVar "cnt")) (EVar "q"))))
(DTypeSig true "ppQual" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String")))) (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Mono") (TyFun (TyCon "Authority") (TyCon "String")))))))
(DFunDef false "ppQual" ((PVar "ctx") (PVar "cnt") (PVar "prec") (PVar "inner") (PVar "q")) (EApp (EApp (EVar "wrapIf") (EBinOp ">" (EVar "prec") (ELit (LInt 2)))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EApp (EApp (EApp (EVar "ppGo") (EVar "ctx")) (EVar "cnt")) (ELit (LInt 3))) (EVar "inner")))) (ELit (LString " @"))) (EApp (EMethodRef "display") (EApp (EApp (EApp (EVar "ppAuthority") (EVar "ctx")) (EVar "cnt")) (EVar "q")))) (ELit (LString "")))))
(DTypeSig true "ppAuthority" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String")))) (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyFun (TyCon "Authority") (TyCon "String")))))
(DFunDef false "ppAuthority" ((PVar "ctx") (PVar "cnt") (PVar "q")) (EBlock (DoLet false false (PVar "s") (EApp (EApp (EVar "renderAuthorityWith") (EApp (EApp (EVar "ppAuthvarName") (EVar "ctx")) (EVar "cnt"))) (EVar "q"))) (DoExpr (EIf (EBinOp "&&" (EBinOp ">" (EApp (EVar "stringLength") (EVar "s")) (ELit (LInt 0))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 1))) (EVar "s")) (ELit (LString " ")))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 1))) (EApp (EVar "stringLength") (EVar "s"))) (EVar "s")) (EVar "s")))))
(DTypeSig true "ppAuthvarName" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String")))) (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyFun (TyApp (TyCon "Ref") (TyCon "Authvar")) (TyCon "String")))))
(DFunDef false "ppAuthvarName" ((PVar "ctx") (PVar "cnt") (PVar "cell")) (EBlock (DoLet false false (PVar "key") (EBinOp "+" (EApp (EVar "authvarId") (EVar "cell")) (ELit (LInt 2000000)))) (DoExpr (EMatch (EApp (EApp (EVar "lookupAssocI") (EVar "key")) (EUnOp "!" (EVar "ctx"))) (arm (PCon "Some" (PVar "s")) () (EVar "s")) (arm (PCon "None") () (EMatch (EApp (EVar "authvarName") (EVar "cell")) (arm (PCon "Some" (PVar "n")) () (EIf (EApp (EApp (EVar "nameTaken") (EVar "n")) (EUnOp "!" (EVar "ctx"))) (EApp (EApp (EApp (EVar "assignName") (EVar "ctx")) (EVar "cnt")) (EVar "key")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EVar "ctx")) (EBinOp "::" (ETuple (EVar "key") (EVar "n")) (EUnOp "!" (EVar "ctx"))))) (DoExpr (EVar "n"))))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "assignName") (EVar "ctx")) (EVar "cnt")) (EVar "key")))))))))
(DTypeSig false "nameTaken" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String"))) (TyCon "Bool"))))
(DFunDef false "nameTaken" (PWild (PList)) (EVar "False"))
(DFunDef false "nameTaken" ((PVar "n") (PCons (PTuple PWild (PVar "s")) (PVar "rest"))) (EBinOp "||" (EBinOp "==" (EVar "s") (EVar "n")) (EApp (EApp (EVar "nameTaken") (EVar "n")) (EVar "rest"))))
(DTypeSig true "ppEffArg" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String")))) (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyFun (TyCon "EffRow") (TyCon "String")))))
(DFunDef false "ppEffArg" ((PVar "ctx") (PVar "cnt") (PVar "r")) (EMatch (EApp (EVar "effrowNorm") (EVar "r")) (arm (PCon "EffRow" (PVar "labels") (PVar "tail")) () (EBlock (DoLet false false (PVar "lbl") (EMatch (EVar "labels") (arm (PList) () (ELit (LString ""))) (arm (PVar "ls") () (EApp (EApp (EVar "renderAtomsWith") (EApp (EApp (EVar "ppAuthvarName") (EVar "ctx")) (EVar "cnt"))) (EVar "ls"))))) (DoLet false false (PVar "tailS") (EMatch (EVar "tail") (arm (PCon "Some" (PVar "cell")) () (EApp (EApp (EApp (EVar "ppEffvarName") (EVar "ctx")) (EVar "cnt")) (EVar "cell"))) (arm (PCon "None") () (ELit (LString ""))))) (DoExpr (EMatch (EVar "tail") (arm (PCon "Some" (PVar "cell")) () (EIf (EBinOp "&&" (EApp (EVar "isJoinCell") (EVar "cell")) (EBinOp "==" (EVar "lbl") (ELit (LString "")))) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EVar "tailS")) (ELit (LString ")"))) (EApp (EApp (EVar "ppEffArgFmt") (EVar "lbl")) (EVar "tailS")))) (arm (PCon "None") () (EApp (EApp (EVar "ppEffArgFmt") (EVar "lbl")) (EVar "tailS")))))))))
(DTypeSig true "ppEffvarName" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String")))) (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyFun (TyApp (TyCon "Ref") (TyCon "Effvar")) (TyCon "String")))))
(DFunDef false "ppEffvarName" ((PVar "ctx") (PVar "cnt") (PVar "cell")) (EApp (EApp (EVar "joinWith") (ELit (LString " | "))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "m")) (EApp (EApp (EApp (EVar "nameOf") (EVar "ctx")) (EVar "cnt")) (EBinOp "+" (EApp (EVar "effvarId") (EVar "m")) (ELit (LInt 1000000)))))) (EApp (EVar "snd") (EApp (EVar "rowFlat") (EApp (EApp (EVar "EffRow") (EListLit)) (EApp (EVar "Some") (EVar "cell"))))))))
(DTypeSig true "ppEffArgFmt" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "ppEffArgFmt" ((PVar "l") (PVar "t")) (EIf (EBinOp "&&" (EBinOp "==" (EVar "l") (ELit (LString ""))) (EBinOp "==" (EVar "t") (ELit (LString "")))) (ELit (LString "<>")) (EIf (EBinOp "==" (EVar "l") (ELit (LString ""))) (EVar "t") (EIf (EBinOp "==" (EVar "t") (ELit (LString ""))) (EBinOp "++" (EBinOp "++" (ELit (LString "<")) (EVar "l")) (ELit (LString ">"))) (EIf (EVar "otherwise") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "<")) (EApp (EMethodRef "display") (EVar "l"))) (ELit (LString " | "))) (EApp (EMethodRef "display") (EVar "t"))) (ELit (LString ">"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig true "ppVar" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String")))) (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyFun (TyApp (TyCon "Ref") (TyCon "Tyvar")) (TyCon "String")))))
(DFunDef false "ppVar" ((PVar "ctx") (PVar "cnt") (PVar "cell")) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "Unbound" (PVar "id") PWild) () (EApp (EApp (EApp (EVar "nameOf") (EVar "ctx")) (EVar "cnt")) (EVar "id"))) (arm (PCon "Link" PWild) () (ELit (LString "_")))))
(DTypeSig true "ppApp" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String")))) (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Mono") (TyFun (TyCon "Mono") (TyCon "String")))))))
(DFunDef false "ppApp" ((PVar "ctx") (PVar "cnt") (PVar "prec") (PVar "a") (PVar "b")) (EMatch (EApp (EVar "tupleSpine") (EApp (EApp (EVar "TApp") (EVar "a")) (EVar "b"))) (arm (PCon "Some" (PVar "ts")) () (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EApp (EApp (EVar "ppEach") (EVar "ctx")) (EVar "cnt")) (ELit (LInt 0))) (EVar "ts")))) (ELit (LString ")")))) (arm (PCon "None") () (EBlock (DoLet false false (PVar "sa") (EApp (EApp (EApp (EApp (EVar "ppGo") (EVar "ctx")) (EVar "cnt")) (ELit (LInt 2))) (EVar "a"))) (DoLet false false (PVar "sb") (EApp (EApp (EApp (EApp (EVar "ppGo") (EVar "ctx")) (EVar "cnt")) (ELit (LInt 3))) (EVar "b"))) (DoExpr (EApp (EApp (EVar "wrapIf") (EBinOp ">" (EVar "prec") (ELit (LInt 2)))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "sa"))) (ELit (LString " "))) (EApp (EMethodRef "display") (EVar "sb"))) (ELit (LString "")))))))))
(DTypeSig true "ppFun" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String")))) (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Mono") (TyFun (TyCon "EffRow") (TyFun (TyCon "Mono") (TyCon "String"))))))))
(DFunDef false "ppFun" ((PVar "ctx") (PVar "cnt") (PVar "prec") (PVar "a") (PVar "eff") (PVar "b")) (EBlock (DoLet false false (PVar "sa") (EApp (EApp (EApp (EVar "ppDomain") (EVar "ctx")) (EVar "cnt")) (EVar "a"))) (DoLet false false (PVar "se") (EApp (EApp (EApp (EVar "ppEffectPrefix") (EVar "ctx")) (EVar "cnt")) (EApp (EVar "rowFlat") (EVar "eff")))) (DoLet false false (PVar "sb") (EApp (EApp (EApp (EApp (EVar "ppGo") (EVar "ctx")) (EVar "cnt")) (ELit (LInt 1))) (EVar "b"))) (DoExpr (EApp (EApp (EVar "wrapIf") (EBinOp ">" (EVar "prec") (ELit (LInt 1)))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "sa"))) (ELit (LString " -> "))) (EApp (EMethodRef "display") (EVar "se"))) (ELit (LString ""))) (EApp (EMethodRef "display") (EVar "sb"))) (ELit (LString "")))))))
(DTypeSig false "ppDomain" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String")))) (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyFun (TyCon "Mono") (TyCon "String")))))
(DFunDef false "ppDomain" ((PVar "ctx") (PVar "cnt") (PVar "a")) (EMatch (EApp (EVar "normalize") (EVar "a")) (arm (PCon "TQual" (PVar "inner") (PCon "AVar" (PVar "cell"))) () (EIf (EApp (EVar "isSome") (EApp (EApp (EVar "lookupAssocI") (EBinOp "+" (EApp (EVar "authvarId") (EVar "cell")) (ELit (LInt 2000000)))) (EUnOp "!" (EVar "ctx")))) (EApp (EApp (EApp (EApp (EVar "ppGo") (EVar "ctx")) (EVar "cnt")) (ELit (LInt 2))) (EVar "a")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EMethodRef "display") (EApp (EApp (EApp (EVar "ppAuthvarName") (EVar "ctx")) (EVar "cnt")) (EVar "cell")))) (ELit (LString " : "))) (EApp (EMethodRef "display") (EApp (EApp (EApp (EApp (EVar "ppGo") (EVar "ctx")) (EVar "cnt")) (ELit (LInt 0))) (EVar "inner")))) (ELit (LString ")"))))) (arm PWild () (EApp (EApp (EApp (EApp (EVar "ppGo") (EVar "ctx")) (EVar "cnt")) (ELit (LInt 2))) (EVar "a")))))
(DTypeSig true "effStr" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "String")))
(DFunDef false "effStr" ((PList)) (ELit (LString "")))
(DFunDef false "effStr" ((PVar "labels")) (EBinOp "++" (EBinOp "++" (ELit (LString "<")) (EApp (EVar "renderAtoms") (EVar "labels"))) (ELit (LString "> "))))
(DTypeSig true "ppEach" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String")))) (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "ppEach" (PWild PWild PWild (PList)) (EListLit))
(DFunDef false "ppEach" ((PVar "ctx") (PVar "cnt") (PVar "prec") (PCons (PVar "t") (PVar "ts"))) (EBlock (DoLet false false (PVar "s") (EApp (EApp (EApp (EApp (EVar "ppGo") (EVar "ctx")) (EVar "cnt")) (EVar "prec")) (EVar "t"))) (DoExpr (EBinOp "::" (EVar "s") (EApp (EApp (EApp (EApp (EVar "ppEach") (EVar "ctx")) (EVar "cnt")) (EVar "prec")) (EVar "ts"))))))
(DTypeSig true "wrapIf" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "wrapIf" ((PCon "True") (PVar "s")) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EVar "s")) (ELit (LString ")"))))
(DFunDef false "wrapIf" ((PCon "False") (PVar "s")) (EVar "s"))
(DTypeSig true "ppPredArgsShared" (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "String")))
(DFunDef false "ppPredArgsShared" ((PVar "ms")) (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EApp (EApp (EVar "ppEach") (EApp (EVar "Ref") (EListLit))) (EApp (EVar "Ref") (ELit (LInt 0)))) (ELit (LInt 3))) (EVar "ms"))))
(DTypeSig true "tupleHeadTagTc" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "tupleHeadTagTc" ((PVar "n")) (EBinOp "++" (EBinOp "++" (ELit (LString "__tuple")) (EApp (EVar "intToString") (EVar "n"))) (ELit (LString "__"))))
(DTypeSig true "spineParts" (TyFun (TyCon "Mono") (TyTuple (TyCon "Mono") (TyApp (TyCon "List") (TyCon "Mono")))))
(DFunDef false "spineParts" ((PVar "t")) (EMatch (EApp (EVar "normalize") (EVar "t")) (arm (PCon "TApp" (PVar "a") (PVar "b")) () (EMatch (EApp (EVar "spineParts") (EVar "a")) (arm (PTuple (PVar "h") (PVar "args")) () (ETuple (EVar "h") (EBinOp "++" (EVar "args") (EListLit (EVar "b"))))))) (arm (PVar "other") () (ETuple (EVar "other") (EListLit)))))
(DTypeSig true "tupleSpine" (TyFun (TyCon "Mono") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Mono")))))
(DFunDef false "tupleSpine" ((PVar "t")) (EMatch (EApp (EVar "spineParts") (EVar "t")) (arm (PTuple (PCon "TCon" (PVar "n") PWild) (PVar "args")) () (EIf (EBinOp "&&" (EBinOp ">=" (EApp (EVar "listLen") (EVar "args")) (ELit (LInt 2))) (EBinOp "==" (EVar "n") (EApp (EVar "tupleHeadTagTc") (EApp (EVar "listLen") (EVar "args"))))) (EApp (EVar "Some") (EVar "args")) (EVar "None"))) (arm (PTuple (PCon "TRigid" (PVar "n")) (PVar "args")) () (EIf (EBinOp "&&" (EBinOp ">=" (EApp (EVar "listLen") (EVar "args")) (ELit (LInt 2))) (EBinOp "==" (EVar "n") (EApp (EVar "tupleHeadTagTc") (EApp (EVar "listLen") (EVar "args"))))) (EApp (EVar "Some") (EVar "args")) (EVar "None"))) (arm PWild () (EVar "None"))))
(DTypeSig true "tupleTagArity" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "tupleTagArity" ((PVar "n")) (EApp (EApp (EVar "tupleTagArityGo") (EVar "n")) (ELit (LInt 2))))
(DTypeSig true "tupleTagArityGo" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "tupleTagArityGo" ((PVar "n") (PVar "k")) (EIf (EBinOp ">" (EVar "k") (ELit (LInt 32))) (EVar "None") (EIf (EBinOp "==" (EApp (EVar "tupleHeadTagTc") (EVar "k")) (EVar "n")) (EApp (EVar "Some") (EVar "k")) (EIf (EVar "otherwise") (EApp (EApp (EVar "tupleTagArityGo") (EVar "n")) (EBinOp "+" (EVar "k") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "commaStr" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "commaStr" ((PVar "n")) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (ELit (LString "")) (EBinOp "++" (ELit (LString ",")) (EApp (EVar "commaStr") (EBinOp "-" (EVar "n") (ELit (LInt 1)))))))
(DTypeSig true "ppConName" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "ppConName" ((PVar "n")) (EMatch (EApp (EVar "tupleTagArity") (EVar "n")) (arm (PCon "Some" (PVar "k")) () (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EVar "commaStr") (EBinOp "-" (EVar "k") (ELit (LInt 1))))) (ELit (LString ")")))) (arm (PCon "None") () (EVar "n"))))
(DTypeSig true "ppMonosShared" (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyCon "String")))
(DFunDef false "ppMonosShared" ((PVar "ms")) (EBlock (DoLet false false (PVar "ctx") (EApp (EVar "Ref") (EListLit))) (DoLet false false (PVar "cnt") (EApp (EVar "Ref") (ELit (LInt 0)))) (DoExpr (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EApp (EVar "ppEachShared") (EVar "ctx")) (EVar "cnt")) (EVar "ms"))))))
(DTypeSig true "ppEachShared" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "String")))) (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "ppEachShared" ((PVar "ctx") (PVar "cnt") (PVar "ms")) (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EVar "ppGo") (EVar "ctx")) (EVar "cnt")) (ELit (LInt 2)))) (EVar "ms")))
(DTypeSig true "ppTy" (TyFun (TyCon "Ty") (TyCon "String")))
(DFunDef false "ppTy" ((PRec "TyCon" ((rf "tyConName" (PVar "n"))) false)) (EVar "n"))
(DFunDef false "ppTy" ((PCon "TyVar" (PVar "n"))) (EVar "n"))
(DFunDef false "ppTy" ((PCon "TyApp" (PVar "a") (PVar "b"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "ppTy") (EVar "a")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EVar "ppTyAtom") (EVar "b")))) (ELit (LString ""))))
(DFunDef false "ppTy" ((PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "ppTyFunArg") (EVar "a")))) (ELit (LString " -> "))) (EApp (EMethodRef "display") (EApp (EVar "ppTy") (EVar "b")))) (ELit (LString ""))))
(DFunDef false "ppTy" ((PCon "TyTuple" (PVar "ts"))) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EMethodRef "map") (EVar "ppTy")) (EVar "ts")))) (ELit (LString ")"))))
(DFunDef false "ppTy" ((PCon "TyEffect" (PVar "effs") (PVar "tail") (PVar "t"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "<")) (EApp (EMethodRef "display") (EApp (EApp (EVar "ppEffInsideTy") (EVar "effs")) (EVar "tail")))) (ELit (LString "> "))) (EApp (EMethodRef "display") (EApp (EVar "ppTy") (EVar "t")))) (ELit (LString ""))))
(DFunDef false "ppTy" ((PCon "TyRow" (PList) (PCons (PVar "a") (PCons (PVar "b") (PVar "rest"))) PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString " | "))) (EBinOp "::" (EVar "a") (EBinOp "::" (EVar "b") (EVar "rest")))))) (ELit (LString ")"))))
(DFunDef false "ppTy" ((PCon "TyRow" (PVar "effs") (PVar "tail") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "<")) (EApp (EMethodRef "display") (EApp (EApp (EVar "ppEffInsideTy") (EVar "effs")) (EVar "tail")))) (ELit (LString ">"))))
(DFunDef false "ppTy" ((PCon "TyAuth" (PVar "p") PWild)) (EApp (EApp (EVar "authTermSurface") (EVar "escStr")) (EVar "p")))
(DFunDef false "ppTy" ((PCon "TyConstrained" (PVar "cs") (PVar "t"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "ppConstraints") (EVar "cs")))) (ELit (LString " => "))) (EApp (EMethodRef "display") (EApp (EVar "ppTy") (EVar "t")))) (ELit (LString ""))))
(DFunDef false "ppTy" ((PCon "TyNamed" (PVar "n") (PVar "t"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString " : "))) (EApp (EMethodRef "display") (EApp (EVar "ppTy") (EVar "t")))) (ELit (LString ")"))))
(DFunDef false "ppTy" ((PCon "TyQual" (PVar "t") (PVar "n"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "ppTyAtom") (EVar "t")))) (ELit (LString " @"))) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString ""))))
(DTypeSig true "ppEffInsideTy" (TyFun (TyApp (TyCon "List") (TyCon "EffAtomTy")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))
(DFunDef false "ppEffInsideTy" ((PVar "effs") (PVar "tails")) (EBlock (DoLet false false (PVar "labs") (EApp (EApp (EMethodRef "map") (EVar "ppEffAtomTy")) (EVar "effs"))) (DoExpr (EMatch (EVar "tails") (arm (PList) () (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EVar "labs"))) (arm PWild () (EBlock (DoLet false false (PVar "tls") (EApp (EApp (EVar "joinWith") (ELit (LString " | "))) (EVar "tails"))) (DoExpr (EMatch (EVar "effs") (arm (PList) () (EVar "tls")) (arm PWild () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EVar "labs")))) (ELit (LString " | "))) (EApp (EMethodRef "display") (EVar "tls"))) (ELit (LString ""))))))))))))
(DTypeSig true "ppEffAtomTy" (TyFun (TyCon "EffAtomTy") (TyCon "String")))
(DFunDef false "ppEffAtomTy" ((PVar "a")) (EApp (EApp (EVar "effAtomSurface") (EVar "escStr")) (EVar "a")))
(DTypeSig true "ppConstraints" (TyFun (TyApp (TyCon "List") (TyCon "Constraint")) (TyCon "String")))
(DFunDef false "ppConstraints" ((PList (PVar "c"))) (EApp (EVar "ppConstraint") (EVar "c")))
(DFunDef false "ppConstraints" ((PVar "cs")) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EMethodRef "map") (EVar "ppConstraint")) (EVar "cs")))) (ELit (LString ")"))))
(DTypeSig true "ppTyFunArg" (TyFun (TyCon "Ty") (TyCon "String")))
(DFunDef false "ppTyFunArg" ((PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EVar "ppTy") (EApp (EApp (EVar "TyFun") (EVar "a")) (EVar "b")))) (ELit (LString ")"))))
(DFunDef false "ppTyFunArg" ((PVar "t")) (EApp (EVar "ppTy") (EVar "t")))
(DTypeSig true "ppTyAtom" (TyFun (TyCon "Ty") (TyCon "String")))
(DFunDef false "ppTyAtom" ((PCon "TyFun" (PVar "a") (PVar "b"))) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EVar "ppTy") (EApp (EApp (EVar "TyFun") (EVar "a")) (EVar "b")))) (ELit (LString ")"))))
(DFunDef false "ppTyAtom" ((PCon "TyApp" (PVar "a") (PVar "b"))) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EVar "ppTy") (EApp (EApp (EVar "TyApp") (EVar "a")) (EVar "b")))) (ELit (LString ")"))))
(DFunDef false "ppTyAtom" ((PVar "t")) (EApp (EVar "ppTy") (EVar "t")))
(DTypeSig true "ppConstraint" (TyFun (TyCon "Constraint") (TyCon "String")))
(DFunDef false "ppConstraint" ((PRec "Constraint" ((rf "constraintHead" (PVar "iface")) (rf "constraintArgs" (PList))) false)) (EVar "iface"))
(DFunDef false "ppConstraint" ((PRec "Constraint" ((rf "constraintHead" (PVar "iface")) (rf "constraintArgs" (PVar "tys"))) false)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "iface"))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EMethodRef "map") (EVar "ppTyAtom")) (EVar "tys"))))) (ELit (LString ""))))
