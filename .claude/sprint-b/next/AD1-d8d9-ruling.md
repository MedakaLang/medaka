# AD-1 — RULING on D8 and D9 (the two selector-free `RKey` stamps)

**Status:** RULING. Adjudication, not design. Unblocks Phase 3′ (`B-2.2`) item 1.
**Pin:** all `file:line` below are `compiler/types/typecheck.mdk` @ **`89a9536b`** (branch
`arch/stage-b-sprint`), read via `git show 89a9536b:compiler/types/typecheck.mdk`.
**Probes:** run read-only on the worktree binary (`MEDAKA_STRICT=1`, exit codes read from a
redirect, never a pipe). Programs kept at `/var/tmp/ad1p/`; each is reproduced verbatim below.
**Inputs:** `.claude/sprint-b/design/D1-phase3-routes.md` §1, §4 (D8/D9 rows), §6.3, §7;
`DECISIONS.md:1869` (the grant nobody took); `test/must_fail_fixtures/1180-*/claim.txt`.

---

## 0. Summary of the ruling

| site | ruling | one line |
|---|---|---|
| **D8** `routeUndeterminedTop` | **(d) DEFER the selection — owner `#1180` / epic `#1122` stage F-3c — with a BINDING interim: NEVER STAMP** | the site's decision is a head-**count** over `prog`, is *not* a selection, and is *not sound today*; identity stamped there would be invented, and its correction is an acceptance narrowing that owes a declared flip list |
| **D9** `resolveRecMono` | **(d) DEFER the re-base — owner `B-2.2-d′` — with the same interim: NEVER STAMP** | the path is **iface-blind** by construction, so no selector *can* run without `d′`'s table widening; and the head tag it stamps **under-determines the instance** (proven), so no `InstId` is derivable from it either |

**Neither (a), (b), nor (c) as offered is correct for either site.** §3 and §4 give the cost of each
and why it fails. The ruling is **one bite-statable transformation** (§5) that changes **no
acceptance and no emitted IR**.

**Payload consequence — the one thing `B-2.2-a` must absorb.** "NEVER STAMP" is free for D1/D2/D7
because those kinds ride `RDict`/`RDictFwd`/`RNone`, constructors that never carried a key. D8 and
D9 construct **`RKey`** — the constructor `B-2.2-a` is making identity-bearing — so absence must be
*expressible on `RKey`*. Ruling: **`B-2.2-a`'s identity field is `Option`-valued on `RKey`** (or
carries an explicit `unselected` value; the choice is `a`'s, the *existence* of the absent state is
this ruling's).

⚠️ **This is a FIELD becoming optional, NOT a new `Route` constructor.** `SupersPath`'s deferral to
B-1 rests on presumption (a), the **two-constructor route** — a statement about the constructor
*set*. An optional field inside `RKey` leaves that set at two, so **this ruling does not disturb
the `SupersPath` deferral and does not need it re-opened.** A third constructor would (see §4c).

**Consistency with the `assum`/`super` NEVER-STAMP rule (#203's class, DICT §3 precedence).** This
ruling *extends* D1's D1/D2/D7 verdict with the same mechanism (absence of identity) and re-resolves
no rigid goal. Nothing in it touches the forwarding requirement.

**Consequence for `B-2.2-f` — this is the useful unblocking result.** D1 §6.3/§7 sized `f` as
"✅ ~7-9 sites **if D9 demotes**; ❌ (re-cut needed) if D9 **re-bases**". This ruling is *neither*:
defer + never-stamp is, **for `f`'s purposes only**, behaviourally identical to demotion — no
identity crosses the recursive fill path, so §6's boundary carrier for that path is discharged for
free — **without** demoting the route word. **`B-2.2-f` therefore keeps its ✅ ~7-9-site sizing,
and D1's `d → f → b1` ordering is satisfied by this document.**

---

## 1. D8 — what the site does TODAY

```
routeUndeterminedTop : List Decl -> ImplBuckets -> KeyBuckets -> String -> Route   :19836
  | iface == ""  = RNone                                                          :19838
  | otherwise = match implHeadTagsForIface prog iface                             :19839
      []    => RNone                                                              :19840
      [tag] => RKey tag (argImplRequiresRoutes … (tconUnresolved tag) [] 0)        :19847  ← THE STAMP
      _     => reportAmbiguousImpl iface                                          :19848
implHeadTagsForIface prog iface = dedup (flatMap (implHeadTagForIface iface) prog) :19858-19860
```

**D1's two claims, both VERIFIED at the pin:**

1. **"decides by a dedup'd impl COUNT"** — ✅. The scrutinee is a `List String` of impl **head
   tycon names**, `dedup`'d at `:19860`; the three arms are a pure cardinality test on it
   (`0 / 1 / ≥2`, `:19840`/`:19847`/`:19848`). Nothing about the *goal* enters the decision.
2. **"reads `prog`, not `IE`"** — ✅. Its first parameter is `List Decl` (`:19836`) and the decision
   reads only `implHeadTagsForIface prog iface`. `implTable`/`keyTable` are threaded past the
   decision into `argImplRequiresRoutes` for the **sub-`requires`** routes (`:19847`) — they take no
   part in choosing the tag. D1's "a residual candidacy reader, i.e. population" is accurate.

**A third fact D1 does not state, and it is the one that decides the ruling.** D8 is reachable
**only on a goal that has no head tycon at all**:

```
entail … = match entailAssum …                                                    :19613-19618
  None => match headTyconNameMono m
    Some tag => entailInst …                    -- the selector legs
    None     => (entailFallback implTable kind, [])   ← the ONLY route to D8
entailFallback implTable (EKNestedTop keyTable _ policy _ _) = undeterminedRoute … :19728-19729
undeterminedRoute implTable keyTable (CountImpls prog iface) = routeUndeterminedTop …:19765-19766
```

and the §5 selector's domain is **exactly the complement** of that condition:

```
ieSelectRowByIface env iface goals = match goalHeadCon goals                      :18994-18997
  Some hk => ieRowOfEntry env (pickMostSpecificEntry goals (ieCandidatesForIface …))
  None    => None
-- its own header: "A goal with no head tycon keys no bucket and selects nothing"  :18992-18993
```

**⇒ At D8 the row-returning selector returns `None` by construction.** Option (b) is not expensive
at D8; it is **structurally unavailable** without redefining what the selector selects *on*. That
redefinition is F-3c's acceptance work, not a stamping bite.

### 1.1 The discriminating program for D8

Two files differing in **one dimension**: whether the interface's two impls have the **same** head
tycon or **different** ones. Nothing else changes — same interface, same signature, same body, same
call.

`/var/tmp/ad1p/dedup.mdk` — two impls, **one** head tycon `T`:

```medaka
interface Mk a where
  mk : Int -> a
  un : a -> Int
data T a = T a
impl Mk (T Int) where
  mk n = T (n + 1)
  un (T n) = n
impl Mk (T Bool) where
  mk n = T (n > 0)
  un (T b) = if b then 777 else 888
roundtrip : Mk a => Int -> Int
roundtrip n = un (mk n)
main : <IO> Unit
main = putStrLn (intToString (roundtrip 10))
```

`/var/tmp/ad1p/twoheads.mdk` — the control; the only change is `data W = W Int` / `data V = V Int`
in place of `T Int` / `T Bool`, i.e. **two distinct** head tycons.

**Measured, first-hand, on the worktree binary at this pin:**

```
=== dedup : check      exit=0    roundtrip : Int -> Int
                                 -- dedup.mdk: ok (2 declaration(s) checked, 0 errors)
=== dedup : run        exit=0    11
=== twoheads : check   exit=1    twoheads.mdk:13:14: Ambiguous instance for `Mk`.
                                 Cannot determine which impl; add a type annotation
=== twoheads : run     exit=1    (same diagnostic)
```

**What it discriminates — three things at once:**

- **The decision is a head-count, not a selection.** Same program shape; two heads ⇒ rejected, one
  dedup'd head ⇒ silently committed. `11` is `impl Mk (T Int)`'s body at `n = 10`, so the
  *committed* instance is identifiable and the other impl is invisible to the counter.
- **No `InstId` is derivable from the tag.** The stamped word is `RKey "T"`, and **two distinct
  instances answer to `"T"`**. So even the optimistic reading — "the tag already names the
  instance, just look it up" — is refuted by execution, not by argument. This kills (b)-by-derivation
  as well as (b)-by-selector.
- **The commitment is not merely selector-free, it is unsound.** Two instances match a goal that is
  neither ground nor rigid; DICT §6.2 T3 permits `inst` only on a closed goal. Stamping identity
  here would not be *recording* a decision, it would be **certifying an S0**.

🚨 **This is a SECOND, apparently UNFILED instance of #1180's class.** `#1180`'s pinned mechanism is
the *bare-tyvar head* variant (`headTyconTy` answers `None` for `impl Sz a`, so the head is dropped
from the count). The program above is the *dedup-collapse* variant: **two concrete heads sharing a
tycon**, counted as one. Same consumer (`routeUndeterminedTop`), same silent-commitment S0, a
different gate in `implHeadTagForIface`/`dedup`. **I did not file it** — read-only mandate. It is
flagged here for the orchestrator, and it strengthens rather than changes the ruling: whatever fixes
#1180 must cover this shape too, and until then D8 must not acquire identity.

---

## 2. D9 — what the site does TODAY

```
realizeRecDictApps ((RecDictApp routesRef callee encl mono)::rest) =                :20086
  let ids = fromOption [] (lookupAssocSL2 callee perRun.value.funConstraintsRef.value)  :20087
  let routes = recRoutes encl mono ids                                             :20088
recRoutes : String -> Mono -> List Int -> List Route                               :20092  ← NO iface
recRoute encl mono id = match findTvarInMono mono id                               :20101-20104
  None => RNone
  Some m => resolveRecMono encl m
resolveRecMono encl m = match headTyconNameMono m                                  :20106-20111
  Some tag => RKey tag []                                                          :20108  ← THE STAMP
  None => match enclSlot encl m
    Some slot => RDict (dictParamName encl slot)                                   :20110
    None => routeOf omEmpty omEmpty "" "" KeepNone m                               :20111
```

**Verified:** the path is **iface-blind**, and the blindness is in the *type*, not a lost argument —
`recRoutes`' third parameter is a `List Int` of constraint tyvar ids (`:20092`), sourced from
`funConstraintsRef` (`:20087`), whose payload carries no interface. Registration
(`:9185`) records only `(routesRef, callee, encl, mono)`. The **sibling** non-recursive arm at
`:9176` *does* pass `map (s => s.csIface.irName) expanded` — so the asymmetry is deliberate: the
recursive arm is reached exactly when the callee is a monomorphic placeholder (`anyIdPinned` False,
`:9164`/`:9192`), i.e. when its slots are not yet known.

**⇒ (b) at D9 requires `B-2.2-d′`** (thread the per-slot iface into the iface-blind fill paths) —
a table/population change. D1 §1 already says `d′`'s `resolveRecMono` half **is** D9's edit; that
remains true and this ruling does not re-derive it.

Also noted, out of scope, not ruled: `RKey tag []` stamps **empty reqs**, so a selected impl's own
`requires` are dropped on this path. Not this ruling's; recorded so `d′`'s owner sees it.

### 2.1 The discriminating program for D9

A mutual-recursion pair (`f` ↔ `g`) so that when `f`'s body is checked, `g` is an in-group
monomorphic placeholder and its call is deferred as a `RecDictApp` (`:9185` is the only path for an
in-group callee). `g` carries a real constraint; the group pins its slot to a **concrete** head, so
`headTyconNameMono` answers `Some "T"` and `:20108` is the arm taken. **The two files differ only in
which of two impls sharing the head tycon `T` is pinned.**

`/var/tmp/ad1p/rec.mdk` (pins `T Bool`) / `/var/tmp/ad1p/rec4.mdk` (pins `T Int`):

```medaka
interface Sz a where
  szc : a -> Int
data T a = T a
impl Sz (T Int) where
  szc (T n) = n + 100          -- rec4 only; rec.mdk has `szc (T n) = n`
impl Sz (T Bool) where
  szc (T b) = if b then 777 else 888
f : Int -> Int
f n = if n <= 0 then 0 else g (T True)     -- rec.mdk
-- f n = if n <= 0 then 0 else g (T n)     -- rec4.mdk  (n : Int ⇒ pins T Int)
g : Sz a => a -> Int
g x = szc x + f 0
main : <IO> Unit
main = putStrLn (intToString (f 1))
```

**Measured:**

```
=== rec  : check  exit=0   f : Int -> Int / g : T Bool -> Int / main : Unit   (0 errors)
=== rec  : run    exit=0   777            ← impl Sz (T Bool)
=== rec4 : check  exit=0   f : Int -> Int / g : T Int  -> Int / main : Unit   (0 errors)
=== rec4 : run    exit=0   101            ← impl Sz (T Int),  szc (T 1) = 1 + 100
```

**Positive control** (`/var/tmp/ad1p/rec2.mdk`, `f n = … g (T True) + g (T 5)`) is **REJECTED**,
`exit=1`, `rec2.mdk:9:46: Type mismatch: Int literal vs Bool`. That is the control proving the
mechanism the discriminator depends on: an in-group callee's constraint slot really is a **single
monomorphic var**, which is *why* its mono can ground to a concrete head at all and reach `:20108`.
Without this control the pair above would not establish that D9 is the arm exercised.

**What it discriminates — all four options at once:**

- Both programs are **correct today**, and their stamped word is the **same**: `headTyconNameMono`
  of a `T …` mono is `Some "T"` in both, so `:20108` yields `RKey "T" []` in both. **One word, two
  different selected instances.** ⇒ no `InstId` is derivable from the payload (kills (b)-by-
  derivation, exactly as at D8), and the *actual* choice is made downstream of the stamp, not at it.
- The routes are **load-bearing and currently right** ⇒ **(a) demote is a live IR change on a
  working path**, at every in-group recursive constrained call whose slot grounds concrete. Rejected.
- Nothing at this site is newly *determined* — it hands a head to a downstream resolver ⇒ **(c) is
  unnecessary**; there is no distinct state to name.
- **(d) + never-stamp is the only option that changes nothing observable.**

⚠️ **Epistemic scope, stated rather than glossed.** I did **not** instrument the compiler, so
"`RKey "T" []` is the word stamped" is read from the source at the pin (`:20106-20108`) plus
`check`'s own `g : T Bool -> Int` / `g : T Int -> Int` reports. The **discriminating property** —
two different selected instances behind one identical head tag — does not depend on instrumentation.

---

## 3. Cost of each option — D8

| option | acceptance? | emitted IR? | verdict |
|---|---|---|---|
| **(a) demote to `RNone`** | **CHANGES IT** | **CHANGES IT** | ❌ **Rejected.** `RNone` at a top-level undetermined constraint is precisely the empty/null dict the site's own header warns about (`:19768-19777`: "yields an empty dict → runtime `intToString: not an Int` / a null build dict"; and `:26097`: "`routeUndeterminedTop ""` → RNone → a NULL Num dict word → build SIGTRAP"). It re-opens the class `test/build_diff_fixtures/{undet_sole,ambns,undet_chain3b}.mdk` exist to pin. **Loud→silent is not even the failure here; it is working→broken.** |
| **(b) re-base onto the selector** | n/a | n/a | ❌ **Structurally unavailable** (§1): D8's reachability condition (`headTyconNameMono m = None`, `:19616-19618`) is the exact complement of the selector's domain (`goalHeadCon goals = Some _`, `:18995`). Not a cost question. |
| **(c) third `Route` constructor** | no | no | ❌ **Unnecessary and expensive.** The state is expressible as an *absent identity on `RKey`*; a new constructor moves every `Route` match arm in the tree (a re-cut, not a bite) **and** collides with `SupersPath`'s two-constructor presumption (a), forcing a deferral to be re-opened for nothing. |
| **(d) DEFER + never-stamp** | **no** | **no** | ✅ **RULED.** The word stays `RKey <tag>` byte-for-byte; only the new identity field is absent. Owner of the real fix: **#1180**, epic **#1122** stage **F-3c**. |

**Why (d) is legitimate here and not a punt.** #1180's own `claim.txt` closes with *"Closing it is an
acceptance NARROWING and owes a declared flip list."* An acceptance narrowing with an owed flip list
cannot be discharged inside a payload-typing phase, and Phase 3′ does not need it discharged — it
needs to know **whether to stamp**. That question is answered, in the negative, and the answer is
final rather than provisional: *no fix to #1180 can make D8 a selection site*, because a
selector-shaped fix would move the site into `entailInst`'s legs and out of `entailFallback`
altogether. Either way D8-as-it-exists never stamps.

## 4. Cost of each option — D9

| option | acceptance? | emitted IR? | verdict |
|---|---|---|---|
| **(a) demote to `RNone`** | probably not | **CHANGES IT** | ❌ **Rejected on measurement** (§2.1): `rec.mdk`/`rec4.mdk` are correct today via this arm. Demoting drops a live concrete dispatch word on a working path — a plausible working→broken, and at minimum an unforced IR change inside a phase whose thesis is that the *payload* changes and the *word* does not. |
| **(b) re-base onto the selector** | possibly | possibly | ❌ **Not statable in Phase 3′.** Needs `B-2.2-d′`'s per-slot iface threaded through `funConstraintsRef` (`:20087`, `:20092`) — a table payload widening, D1's own reason for moving `d′` out. Doing it inside a simultaneous payload type change is the shape D1 §1 warned against: a wrong re-base would surface as a wrong *identity* rather than a diffable wrong *word*. |
| **(c) third `Route` constructor** | no | no | ❌ Same as D8(c), plus: §2.1 shows nothing is *determined* at this site to name. |
| **(d) DEFER + never-stamp** | **no** | **no** | ✅ **RULED.** Owner: **`B-2.2-d′`** — which is where D1 §1 already placed D9's edit, so this creates no new owner and no new bite. |

---

## 5. Is the ruling statable as a §4 bite?

**✅ YES for the transformation, ❌ NO for the two selection fixes — and the split is the point.**

**Bite `B-2.2-a-D89` (fold into `B-2.2-a`; do NOT land separately).**
*Transform:* `B-2.2-a`'s identity field on `RKey` admits an **absent / unselected** value; the two
selector-free construction sites stamp it; each acquires an assertion-comment naming its owner.

| # | site | edit |
|---|---|---|
| 1 | `routeUndeterminedTop` — `typecheck.mdk:19847` | stamp the absent identity; comment: *no selector runs on this arm — the decision is a dedup'd head COUNT over `prog` (`:19858-19860`) and is reachable only on a goal with no head tycon (`:19616-19618`), which is exactly the selector's `None` domain (`:18995`). Two instances can share the stamped tag (AD-1 §1.1). Selection is **#1180** / #1122 F-3c.* |
| 2 | `resolveRecMono` — `typecheck.mdk:20108` | stamp the absent identity; comment: *iface-blind by type (`recRoutes:20092`, `funConstraintsRef:20087`); one head tag serves two instances (AD-1 §2.1). Re-base is **`B-2.2-d′`**.* |

**Preconditions, all discharged:** the field's optionality is `B-2.2-a`'s own type change (no extra
site); no new `Route` constructor (so `SupersPath`/presumption (a) untouched); no acceptance change;
no emitted-IR change; consistent with D1/D2/D7 NEVER STAMP and with #203/DICT §3.
**Verification it owes:** the sites are `RKey`-construction only, so the existing selfproc LEG A +
snapshot goldens plus the fixpoint are the right oracles; **the D8/D9 arms must produce a
byte-identical route word**, and `dedup.mdk`/`twoheads.mdk`/`rec.mdk`/`rec4.mdk`/`rec2.mdk` above are
five cheap before/after checks for that. ⚠️ Note `rec2.mdk` is a *reject* control — grade its
diagnostic, not just its exit code.

**❌ NOT statable, and I refuse to state them:**
- **D8's selection fix** — an acceptance narrowing owing a declared flip list (#1180's own words),
  plus a second unfiled variant found here (§1.1). Needs a design run, not an adjudication.
- **D9's re-base** — `B-2.2-d′`'s `funConstraintsRef` payload widening; unsized here on purpose.

**What is missing (named, not hidden):** whether `B-2.2-a` spells absence as `Option InstId` or as a
sentinel constructor. That is `a`'s call; this ruling requires only that the absent state **exist**.

---

## 6. Refusals

1. **Refused to demote either site to `RNone`.** Both are live and currently correct on measured
   programs; demotion is an emitted-IR change on a working path (§3, §4).
2. **Refused a third `Route` constructor.** Unnecessary (nothing is "determined without selection"
   at either site once §1.1/§2.1 are read) and it would force the `SupersPath` two-constructor
   deferral back open for no gain.
3. **Refused to file the new dedup-collapse S0** found at §1.1 (read-only mandate). Flagged to the
   orchestrator: it is #1180's class at a different gate, and it must be covered by #1180's fix.
4. **Refused to size `B-2.2-d′`** or to design D8's acceptance narrowing. Out of an adjudication's
   scope; both are named with owners.
5. **Quoted no count without its command.** The only cardinalities asserted here are the three arms
   of `:19839-19848` and the two-vs-one impl heads in the probes, each read off the pinned source or
   the probe output printed above. I did **not** re-derive D1's "12 discharge kinds" or the
   "6 `RKey` construction sites"; nothing in this ruling depends on either.
6. **Did not conflate `InstRef`'s two uses.** No part of this ruling derives a NAME from `seq`; it
   derives no name at all, which is the ruling.
