# Packet `B-2.2-c` — the comment-only bite (the sprint's terminal bite)

**Worktree (absolute, always):** `/root/medaka/.claude/worktrees/expressive-prancing-minsky`
**Base:** the commit landing `b1`+`e` — **re-pin it yourself**; do not trust a SHA written here.

---

## 0. Concurrency

**You are the ONLY writer live.** If the tree moves under you, **STOP and report** — do not adapt.

## 1. What this bite is, and why it is not cosmetic

`c` leaves behind sentences the next refactor cannot silently violate. **Three of the four edits
correct comments that are measurably WRONG and were relayed forward through design documents
unverified — one of them twice.** A wrong comment in this tree has already cost this sprint a
near-miss: `keyForSite`'s wrong-tier warning is what made `b1`'s original design delete
`fromOption tag`, which would have broken every cross-module default-inheritance call site.

**`b2` was DROPPED** (RUN-P3-032), so `c` is the sprint's terminal bite.

## 2. The four edits

Line numbers drift — **find each by symbol**. Two of the three corrections may already be done: the
`b1`+`e` implementer was asked to fix the wrong-tier comment and the `#1182` attributions. **Check
first; if a site is already correct, say so and skip it.**

### Site 1 — `keyForSite`'s wrong-tier warning (~`:18446-18452`)

It claims behaviour rests on the emitter's general-instance tier (`emitGeneralRKey` →
`findByTag noneHeadTag`). **Measured false.** A `Some __none__` word is a **direct** hit (the general
is itself registered under `noneHeadTag`, so tier 1 matches), and the `None` arm **cannot reach the
general tier at all** — the headless bucket is unioned into the candidate scan, so a general that
provides the method always makes the function answer `Some`. What catches `None` is
**`emitDefaultRKey`**'s `mdk_default_<method>_<TAG>`, keyed on the tag `fromOption tag` supplies.

The replacement must carry the consequence, not just the correction:

> ⇒ `fromOption tag` is **not** a hedge over a selector result: at the sites where it fires it is the
> **ONLY** source of that TAG, and deleting it breaks every cross-module method-less impl inheriting
> an interface default. A green suite here is evidence about the **DEFAULT** tier, not about the
> route word.

🚨 **Do not compress this to preserve line count** — see §3. That last sentence is the one whose
absence nearly shipped a break.

### Site 2 — `implDictRoutesForFull`'s stale `keyTable` justification (~`:19489`)

It claims the threading is live for the nested-`requires` re-bucketing. **It is inert.** The
recursion ends at `selectReqImpl`, which takes no `KeyBuckets` at all — **and its own header already
says so** (*"the `KeyBuckets` parameter is REMOVED rather than ignored — it had exactly one reader,
this arm"*). `bucketOf`, the only reader, is never applied to a threaded `keyTable`. Replace with a
statement that it is a **dead parameter awaiting the sweep**, not a live re-bucketing.

### Site 3 — `entailInst`'s header (~`:19796-19800`) — **found late; nobody had flagged it**

It says `EKNestedTop → bare head tag`. **False since #203** — the arm stamps the canonical key of the
min⊑ winner, bare only when the collision gate is False — and **its own body comment says so eleven
lines later**, as does the `EntailKind` ladder comment. *Two of three descriptions of this arm are
right and the one an implementer reads first is wrong.* Line-count-neutral fix:

```
-- (implRef-bound); EKNestedTop → the min⊑ winner's canonical key (bare head only when the
-- iface-keyed collision gate is False — see the arm's own body comment) with requires PACKED
-- into the primary RKey;
```

### Site 4 — the precedence + reachability block (new, above `entail`)

**Put it above `entail` — a FUNCTION.** Not inside `data EntailKind` (§3, #829).

The property to inscribe, **verified at the pin by enumerating every selector call site**:

> Every impl-row **selector** call reachable from `entail` lies in an `inst` arm (`entailInst`) or in
> an element-route helper called from one. No selector call may be reachable from `entailAssum`,
> `entailAssumVar`, `entailAssumRoute` or `entailFallback`.

It must carry three guards, each earned:

1. **Why it matters:** `assum` strictly precedes `inst` precedes `fallback` (DICT §3). Letting a
   later rung answer a goal an earlier rung could have **re-routes a dict cell from a
   caller-supplied parameter to a statically selected impl** — wrong value, exit 0, no diagnostic.
2. 🚨 **It is a REACHABILITY property, NOT A COUNT, and the count form is FALSE on a correct tree.**
   There are legitimately **two** selector calls per `inst` arm — one for the primary word, one in
   the element helper — and at `EKArg`/`EKOp` the two ask about **different methods**
   (`innerDefaultMethod`-reduced), deliberately. Any *"one selector call per arm"* rule licenses
   collapsing those, which changes which impl's context is discharged. **Do not restate the count
   form.**
3. **A grep of `ieSelectRowBy*` is not the check:** `concreteReqMatchByIface` is a **legitimate**
   selector call outside this ladder (the obligation channel), and is not in scope for the property.
   Name it, or a future grep-based audit reports a false violation.

## 3. The two traps — both checked, both discharged, and one inverts the usual advice

**Line-count neutrality is NOT required here, and compressing to achieve it is the wrong trade.**
Derived: the snapshot embeds the source verbatim, but its **graded sections carry no source
locations**, so a line-shifting comment edit diffs exactly the edited lines plus the `source_lines=`
count — no cascade. **No golden pins a line inside `typecheck.mdk`**, and the two in-tree
`typecheck.mdk:NNNN` citations from other modules sit **above** every edit site, so none rot.

**#829 cannot fire.** The file's only three two-line-header **record** decls are >12 000 lines from
every edit site. `KeyEntry` and `EntailKind` are two-line-header but **positional, not record** — a
shape #829's measurement does not cover and nobody has tested. ⇒ **one rule: put no new comment
inside `data EntailKind`'s body.** Site 4 goes above `entail`, a function, sidestepping it entirely.

## 4. Verify

```sh
make -C <worktree> medaka && make -C <worktree> check-self
./medaka fmt --check compiler/types/typecheck.mdk     # then eyeball the edited decls
./medaka lint compiler/types/typecheck.mdk
```

Comment-only ⇒ **no behaviour may change.** `check-self` PASS and an unchanged build are the bar.
🚨 **BLESS ZERO GOLDENS.** The snapshot will move (it embeds the source); it is re-cut **once** at
the close-out. If anything *other* than the snapshot moves, **stop and report** — that contradicts
"comment-only".

## 5. `DEBT.md` row

Standard six fields. `could move:` is *"nothing — no expression changes"*, **with the reason**, not
silence. `nearest miss:` should name what the reachability property does **not** cover: the
`D1-leak` fall-through (a rigid in-scope goal whose lookup misses and the ladder falls to `inst`) is
a real re-resolution **today**, this bite does not fix it, and #1127 legs 1–2 are B-1's.

## 6. Refuse, explicitly

**Report disagreements rather than resolving them silently.** Every prep pass in this sprint re-cut
the bite it was handed by refusing the ruling: `a` lost its type change, `f` lost its field, `b1`
lost its four-arm edit, `b2` was dropped outright. **If a comment you are asked to "correct" is
actually right, or a site does not exist, STOP and report with your derivation.** A refused bite is
landed work.

## 7. Closing section, mandatory

**TIME ACCOUNTING**: split (orientation · derivation · edits · build/gate · report) · biggest sink ·
**what did you have to DERIVE that this packet could have handed you?** · what of this packet was
wasted · build cycles and which were avoidable. Reading and thinking are PRODUCTIVE; only build churn
and report-writing are overhead.
