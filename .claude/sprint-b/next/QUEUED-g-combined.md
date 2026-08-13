# QUEUED — `B-2.1-g`: THE COMBINED BITE. Step (1) of Val's "3 then 1" ruling.

⚠️ **GATED ON `B-2.1-f`** (re-arm the loud reject). If `f` refused — i.e. loudness could not be re-armed
without re-rejecting the three drains — **do NOT dispatch this.** That outcome is a revert decision and
belongs to the orchestrator/Val, not to this bite.

⚠️ **PREP REQUIRED BEFORE DISPATCH — do not skip this, it is why the last two bites produced S0s.**
Run a prep pass pinned to the commit the implementer will actually start from (NOT an earlier one — a
packet pinned to a pre-drain commit went stale and cost a grep round), and then **run its named
discriminator as a BUILD yourself, at the commit boundary, before dispatching.** The previous prep pass
posed exactly the right question — *"what does the route become when existence says yes and selection
can't find it?"* — and I answered it by reasoning instead of measuring. One build would have prevented
an S0.

## Why this bite is large, and why it must NOT be split

**Three of my scoping rulings tried to move a subset and two produced S0s.** The measured lesson:

- **`b1` (refused):** moved the checker leg alone ⇒ `check` exit 0 over a **segfaulting binary**.
- **`c` (refused):** moved two existence reads and deferred the third ⇒ a located reject became **exit 0
  printing a garbage pointer**. My reason (*"the deferred site has no sibling SELECTION read"*) was true
  and **not sufficient** — it has a sibling **EXISTENCE** read at a different phase, which is the P0-20
  class the site's own comment warns about.
- **`b2` (landed, drained 3 S0s, introduced 1):** left the **method-keyed route word** on the prefix
  table by design (AM-1) ⇒ a **head-collision-count** disagreement ⇒ an arity-2 conditional impl called
  with one argument ⇒ **exit 139**.

**⇒ Everything below moves TOGETHER. There is no smaller correct version. If you find yourself deferring
one member, STOP and report** — that instinct is exactly what produced the last two S0s.

## The set that must move together

1. **The three EXISTENCE reads** — `inferShadowApp`, `definerReceiverDispatches`, and
   `resolveRLocalSite` (the last is the one `c`'s refusal proved cannot be deferred).
2. **`resolveRLocalSite`'s own SELECTION leg** — `routesOfMonosTop … keyTable`. Its `#415` block demands
   existence and selection agree on ONE table. ⚠️ **That block's premise —** *"there is no second table
   in scope to drift TO"* **— is ALREADY FALSE** since `b2` put three selection legs on
   `bodyImplEnvRef`. **Rewrite that comment; it is what licensed the bad scoping.**
3. 🚨 **The METHOD-keyed ROUTE WORD** — `keyForSite` → `matchedEntry` → `matchingEntries`. **This is the
   member `b2` omitted and it is the S0's direct cause.** AM-1 kept it on the prefix table *by design*;
   that design is now the defect. **This bite amends AM-1** — record that explicitly.
4. **Whatever `f` armed.** If `f` added a guard for the collision-count disagreement, this bite should
   make that guard **unreachable** rather than delete it. ⛔ **Do NOT delete a loud reject** — a
   loud→silent transition is a severity increase, and the guard still covers **#1578**. If it becomes
   provably unreachable, say so; that is a separate argued deletion.

**Keep ONE min⊑ selector** (`pickMostSpecificEntry`), index on **`instRefSeq`**, preserve
`candidateBucket`'s empty-headless fast path. Use **`ieByHead`/`ieHeadRows`** for the head-keyed reads —
it exists precisely to make the graph-global lookup affordable (the naive scan cost **+17%** on
`check-self`). **Do not reintroduce a scan.**
🆕 Phase 3′ needs the selector to return **`Option ImplRow`**, not a `String`.

## Required evidence — graded on discrimination, not on green

1. 🚨 **`SA-4c`'s program: `check` 0 AND the built binary CORRECT** (not 139, not garbage). Show the IR:
   the **arity-1 specific impl** must be called, in **both import orders**, with matching argument
   counts at the call site.
2. **`diff_compiler_check_cli_modules.sh` → 85 ok, 0 failing.**
3. 🚨 **`diff_compiler_must_fail.sh` twice, and check the drained NAMES INDIVIDUALLY, not the count.**
   "3 DRAINED" stays true if one drain silently swaps for another — that is the shape that made `b1`
   look successful. Expect **#1564, #1599, #1072** by name, controls passing.
4. **`c`'s five-file import-order corpus** (in `scratchpad/c-REFUSED.patch`) — the `c-imp`/`c-imp2` pair
   must now agree, on `check`, `run`, **and** the built binary.
5. `diff_compiler_flat_vs_onemodule.sh` (13 rows) · `check-self` · `fmt --write` **before** any build ·
   `lint`.
6. **Report whether `shadowKeyTableRef`/`universeKeyBucketsRef` are now fully dead** — that unblocks
   `B-2.1-d`, whose packet (`.claude/sprint-b/design/P-d-packet.md`) is already written and confirms
   their only readers are exactly this set. ⚠️ `d` also reds `agent-doc-symbols` (the spec backticks
   `shadowKeyTableRef` in a scoped tier) — coordination point, do not land `d` blind.

**DO NOT RUN:** `selfcompile_fixpoint.sh`, corpus sweeps, full gate suites. ⚠️ **BUT this bite changes
emitted IR**, so the fixpoint is decisive — CI's `soundness` shard owns it (it PASSED for `b2`'s
IR change, so it is a live, trusted signal). **At any sign of a codegen or dict-arity anomaly beyond the
one you are fixing, STOP and report.**

## Deliverables

`DEBT.md` row + `🔗 DECISIONS.md RUN-B-0xx`. **No `DECISIONS.md` entry — the orchestrator's.**
`engines:` — **all four arms consume the changed `Route`** (LLVM · wasm · eval · `core_ir_eval`); eval and
LLVM already **disagreed in severity** on `c`'s shape (loud `E-PANIC` vs silent garbage), and wasm was
never observed. **Name what each owes.**
**`could move:`** — large, and that is the point. Name the tie-break change (arbitrary ⇒ graph-global
declaration order) verbatim; it is **not** licence to implement T4.
**`nearest miss:`** — the `tys = []` sub-class is still owed, and a goal whose head is not a tycon
(`goalHeadCon = None`) still falls to a prefix-read fallback. **State and TEST both.**

**REFUSE AND REPORT.** Ten briefs corrected that way this run; two of the orchestrator's scoping rulings
created S0s. **If this bite cannot be done as one unit, that is a finding, not a failure.**

## 📊 MANDATORY: TIME ACCOUNTING (~8 lines)
Split · biggest sink · **what you had to derive that the packet should have handed you** (scored against
the orchestrator) · wasted brief content · build cycles + which avoidable. **Reading and thinking are
NOT overhead**; only build churn and report-writing are.
⚠️ Harness friction: the isolation classifier rejects heredocs, `$VAR`, and redirects to scratch paths —
**use `Write` to stage fixtures**, and prefer running an existing gate over hand-staging.
