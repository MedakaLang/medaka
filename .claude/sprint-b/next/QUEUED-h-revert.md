# QUEUED — the REVERT BRANCH. Dispatch ONLY if `B-2.1-g` reported it cannot clear #1514.

**The standing ruling** (`.claude/HANDOFF.md`, the `B-2.1-f` update section, orchestrator under
standing authority, 2026-08-13): *"`B-2.1-g` MUST clear #1514's capability loss — if `g` cannot,
`f` and the drain should be reverted together rather than shipping a build-refusal on a working
program."* This file executes that ruling.

**Why together and not `f` alone:** reverting `f` alone restores the **silent segfault**
(`SA-4c`'s binary at exit 139 with `check` reporting 0), which is strictly worse than a loud false
reject. Reverting `1e7cbbbb` alone is not available either — `f`'s guard is built on the drain's
substrate reads. The pair is the smallest safe unit.

🚨 **THIS IS A REVERT, NOT A REDESIGN.** ⛔ **Do not design the re-landing here.** Bite RV-3 below
names *the set that must move together* and stops. Anything past that is the next implementer's, and
a design written now would be discarded — three scoping rulings in this run tried to move a subset
and **two produced S0s.**

---

## ⚠️ WHAT THIS REVERT COSTS — state it, do not soften it

**Reverting LOSES three drained S0s: #1564, #1599, #1072.** They return to REPRO. #1072 is the
strongest of the three and is a **silent-wrongness** drain (its binary printed `general` where
most-specific-wins requires `specific`, exit 0, no diagnostic — `1e7cbbbb`'s commit message).

**This is ACCEPTED, and the reason is the run's own severity contract:** a **build refusal on a
legal, previously-working program (#1514, whose binary printed `11`/`110`/`7`) is not shippable**,
and the alternative to the refusal is the segfault. Three known-and-pinned S0s are worth more than
one capability regression plus one silent 139. **Say this in the `DEBT.md` row in those words** — a
later reader must not find a bare revert and conclude the drain was wrong. It was not; its *scope*
was.

⛔ **Do NOT close #1397 or #1514, and do NOT re-close or re-open #1564/#1599/#1072 in either
direction.** §1's issue-closure policy is *implement, do not close.* Their pins going back to RED is
the correct, expected outcome — it is **not** a regression to explain away.

---

## ✅ ALREADY SETTLED — do NOT re-derive, do not re-litigate

1. **The revert set is exactly two commits: `086aeb35` (`f`) and `1e7cbbbb` (`b2`).** Derived, not
   assumed: `git show --numstat 95359281` (bite `c`) touches **only** `.claude/sprint-b/DEBT.md` and
   `.claude/sprint-b/design/P-d-packet.md`, and `git show --numstat 3ba7817b` (bite `e`) touches
   **only** `.claude/HANDOFF.md`. `c` reverted its own source edits before committing, and `e` never
   made any. **No other commit on `2b9dc798..086aeb35` carries drain source.** Re-run both
   `--numstat` commands to confirm nothing moved under you; do not re-derive the reasoning.
2. **`a2`/`a3`/`a4`/`85ceec1f` STAY.** The substrate (`bodyImplEnvRef`, `buildFlatImplEnv`), the
   head-across-interfaces index (`ieByHead`/`ieHeadRows`/`ieIndexRows`), `a4`'s probes and the
   `#1110 OriginUnresolved` ratchet entry are all **preconditions**, not the drain. They cost `+70/0`
   and `+8/-2` and have no behavioural reader once the drain is out.
3. **After the revert, `bodyImplEnvRef` and `ieByHead` become write-only again — that is CORRECT,
   not a leftover.** R1 confirmed `a2`'s no-reader state first-hand at `604278bb`
   (`review/R1-landed-work.md:265-268`: 6 hits, 4 of them writes, no read site in the tree). Do not
   "clean up" an unread ref; the re-land needs it.
4. **`test/diff_compiler_flat_vs_onemodule.sh` and its 13 rows SURVIVE.** The gate was built by
   `a1`/`a2` *before* the change it grades; the 4 extra rows are `a4`'s probes, and `1e7cbbbb`'s own
   commit message records that they were **"pinned green on the BASE binary first so they pin the
   pre-state rather than this bite's output."** They are drain-independent **by construction and by
   measurement** — see RV-2's positive control.
5. **`refresh_seed.sh` is not idempotent after a codegen change; run it twice.** Settled.
6. **`test/typecheck_compiler_source.sh`'s allowlist is keyed on line TEXT, not line numbers**
   (`P-d-packet.md` §2c). A revert that restores text restores agreement.

---

## RV-1 — the revert, and exactly what is KEPT out of it

**Order: newest first.** `git revert --no-commit 086aeb35`, then `git revert --no-commit 1e7cbbbb`.
Reverting `b2` first will conflict, because `f`'s `typecheck.mdk` additions sit on `b2`'s.

Pin your base before you start — every worktree shares one `.git` and a sibling's `git fetch`
advances refs under you with no signal:
```sh
BASE=$(git rev-parse 2b9dc798)      # the sprint BASE; PIN it, never diff against origin/main
```

### The file-by-file disposition. **Derive each with `git show --numstat`; do not trust this table.**

| file | in | disposition |
|---|---|---|
| `compiler/types/typecheck.mdk` | both | **REVERT** — the whole point |
| `compiler/ir/core_ir_lower.mdk` (`+9/-3`) | `b2` | **REVERT** |
| `compiler/types/registry.mdk` (`+5/-2`) | `b2` | **REVERT** |
| `docs/spec/DICT-SEMANTICS.md` (1 line) | `b2` | **REVERT.** It is a symbol-names-only citation cell renamed `selectImplEntryByIface` → `ieSelectRowByIface` *following the function `b2` deleted*. The revert restores the function, so the old spelling is again the true one. ⚠️ Then run `make agent-doc-symbols` — the whole point of that cell is that the symbol must resolve. |
| `compiler/DIAGNOSTIC-CODES-DESIGN.md` (`+2/-1`) | `f` | **REVERT** — it registers `T-ROUTE-WORD-AMBIGUOUS`, a code that ceases to exist. A registered code with no emitter is a lie in the taxonomy. |
| `test/diff_compiler_flat_vs_onemodule.sh` (`+66/-1`) | `b2` | 🚨 **KEEP — do NOT let the revert take it.** Settled item 4. |
| `test/diff_compiler_check_cli_modules.sh` (`+100/-20`) | `f` | **REVERT** — and read the diff before you accept it. Its added legs (`SA-4/overlap-check-blind-to-route-word` and the `SA-4c` verb-split row) pin **`f`'s own residual**, so they are meaningless once `f` is out; and reverting is precisely what returns **`SA-4c` to asserting a REJECT**, which the standing ruling requires. ⚠️ **Read every reverted leg and confirm none of them covers a class that survives the revert.** If one does, keep that leg and say why. ⛔ Never delete a loud-reject assertion that still covers a live class (#1578). |
| `.claude/sprint-b/DEBT.md` (both) | both | **KEEP** — history. `DEBT.md` is append-only and single-writer; a reverted bite's row stays, and RV-4 appends the revert's own row. |
| `.claude/sprint-b/design/P-c-packet.md` (`+377`) | `b2` | **KEEP** — a design packet, read by no gate. |
| `.claude/HANDOFF.md` (`+37`) | `f` | **KEEP** — RV-4 rewrites it rather than reverting it. |

**Mechanically:** after the two `--no-commit` reverts, restore the keepers from `HEAD` before
committing (`git checkout HEAD -- <path>` for each KEEP row), then confirm with
`git diff --numstat --cached` that **only** the REVERT rows appear.

**Sanity identity, and it is the cheapest possible check:** for every reverted `compiler/*` file the
staged content must be **byte-identical to `85ceec1f`** (the last commit before the drain):
```sh
git diff --stat 85ceec1f -- compiler/   # expected: EMPTY
```
A non-empty result means the revert is not a revert. **STOP and report** rather than reconciling.

**Floor for RV-1:** `medaka fmt --check` on the reverted source (**before** any build — a revert
should need no reflow; if `--check` is dirty, something is not a revert) → `make -C <trunk abs path>
medaka` → `make check-self` → `medaka lint` → `make agent-doc-symbols` → `make docs-links`.

---

## RV-2 — prove the revert is CLEAN: three readings, each against a pre-drain control

🚨 **A revert is verified by AGREEMENT WITH THE PRE-STATE, not by green.** Every reading below is a
**two-arm** comparison: the reverted binary versus a binary built at `85ceec1f`. ⭐ **A base binary
may already be in scratch** (`baseB/`, `ctl.bin`, `sa4cc.bin`) — **check before building one**;
`compiler/**` is a whole-compiler compile (~3/min under load).
⚠️ **Two-arm hygiene:** a `medaka` binary resolves its emitter *and* its stdlib from **the directory
the binary sits in**, so an alt-dir arm needs `medaka` + `medaka_emitter` + `stdlib/` + **`runtime/`**
beside it — the missing `runtime/` bites only on the first `build`, which is exactly where this gets
interesting. And check that neither `MEDAKA_ROOT` nor `MEDAKA_EMITTER` is exported in your shell:
either one silently crosses the arms.

1. **The S0 class returns to its PRE-DRAIN behaviour — a LOUD, LOCATED reject.**
   `scratchpad/sa4c/probe.sh` reproduces every reading `f` took, against any binary:
   `sh probe.sh <medaka> <root> <label>`. Assert on **both** arms, in **both** import orders:
   `check` exit 1 **with a `file:L:C:` location**, `build` exit 1, **no executable produced**, and
   the control order still building and printing `wrap-int-specific`. **The diagnostic text and the
   exit codes must match the `85ceec1f` arm.** ⚠️ Grade the **diagnostic**, not the exit code — an
   exit-code-graded control answers the wrong question here (both a located reject and a bare refusal
   exit 1).
   ⚠️ `medaka build`'s exit code **does not survive a pipe** — redirect to a file, read `$?`, then
   read the file. Never `2>&1 | tail`.
2. **`sh test/diff_compiler_must_fail.sh`, TWICE.** Expected: **`0 DRAINED`, `0 control-broke`,
   `0 malformed`.**
   🚨 **Assert the DRAINED set is EMPTY by name, and do not assert a total.** *"5 DRAINED"* stayed
   true all run while **two of the five were over-fire** — the count is the one number that has
   never carried information here. ⚠️ **OWED:** the pre-drain REPRO total is *implied* to be 100
   (`b2` measured 97/3, `f` measured 95/5), but a pin was **authored during this run** (#1075), so
   **read the total off the gate on the `85ceec1f` (pre-drain) arm** rather than trusting the
   arithmetic: `⚠️ OWED: sh test/diff_compiler_must_fail.sh` on the pre-drain binary, both arms
   compared.
   ⚠️ A **malformed** pin reports as DRAINED-or-benign — that verdict has been wrong three times in
   this project — so `0 malformed` is load-bearing, not decoration.
   **Must STAY REPRO** (a flip is a finding): `test/must_fail_fixtures/1597-*`, the #1075 pin, #1046.
3. **#1514 and #1397 build correctly again.** `scratchpad/probe4.sh` reproduces both readings.
   #1514's binary must print `11`/`110`/`7`. #1397 must build. ⚠️ #1397's pre-drain state was
   **silently picking an impl** — so its revert restores a *silent* wrongness, which is a
   loud → silent transition for that one issue. **Record it explicitly in the row as a known cost of
   the revert**, alongside the three drains; do not let it pass unnamed.
4. **`sh test/diff_compiler_check_cli_modules.sh` → 0 failing**, and its `ok` count must equal the
   `85ceec1f` arm's. ⚠️ **Derive both; quote neither.** The published numbers for this gate have
   moved three times (`e`: 81 ok/4 failing post-drain; `HANDOFF`: 86 ok after `f`;
   `QUEUED-g-combined`: 85 briefed). Also: `1112-A34/later-invisible` is a **pre-existing** red that
   fails by ACCEPTING, and `f`'s row records that the HANDOFF line about it went **stale** — read
   the gate, not the ledger.
5. 🚨 **`sh test/diff_compiler_flat_vs_onemodule.sh` → 13 rows PASS. This is the POSITIVE CONTROL
   for the keep decision.** Those 4 kept rows were pinned green on the *pre-drain* binary, so if any
   of them reds on a reverted binary, either the keep was wrong or the revert was not clean —
   **STOP and report which.** A revert with no positive control is indistinguishable from a revert
   that also removed a working gate.
6. **`sh test/registry_keying_ratchet.sh`** — `b2` and `f` added no ratchet row, so it should be
   **unmoved**;
   **derive both sides** (the expected allowlist and the extracted record) and confirm they agree,
   rather than assuming a revert cannot move a set-equality check.

**DO NOT RUN:** `selfcompile_fixpoint.sh`, corpus sweeps, full suites — CI's `soundness` shard owns
them and **its fixpoint step is passing.** ⚠️ **But say plainly in `unchecked:` that a revert of an
IR-changing diff owes the fixpoint**, and that the seed may owe a re-mint (twice, non-idempotent).
🚨 **At any sign of a codegen or dict-arity anomaly, STOP and report** — a revert that leaves an
arity skew is worse than either arm.

---

## RV-3 — write the RE-LAND PLAN as ONE unit. Name the set; do not design it.

The three drains **re-land together, as one correct unit, in a later bite.** Your deliverable here is
**a short section in `DEBT.md`** naming the set and the lesson. Nothing more.

**The set that must move together** — this is `b2` ∪ `c` ∪ the member `b2` omitted, i.e. exactly
what `g` was attempting (`QUEUED-g-combined.md`, "The set that must move together"):

1. **All three EXISTENCE reads** — `inferShadowApp`, `definerReceiverDispatches`, and
   `resolveRLocalSite`. `c`'s refusal **measured** that the third cannot be deferred (deferring it
   turned a located reject into **exit 0 printing a garbage pointer**).
2. **`resolveRLocalSite`'s own SELECTION leg** (`routesOfMonosTop … keyTable`). Its `#415` block
   demands existence and selection agree on ONE table — and **that block's premise, *"there is no
   second table in scope to drift TO"*, is already FALSE** since `b2`. The comment must be rewritten
   by whoever lands this; **it is what licensed the bad scoping.**
3. **The three SELECTION legs onto the unified substrate** (`bodyImplEnvRef` + `ieByHead`) — `b2`'s
   own content, which is what actually drains #1564/#1599/#1072.
4. 🚨 **The METHOD-keyed ROUTE WORD** — `keyForSite` → `matchedEntry` → `matchingEntries`. AM-1 left
   it on the topological-prefix table **by design**; that design is the defect, and this is the
   member `b2` omitted. **A re-land amends AM-1 and must say so.**

**The lesson, stated so the next implementer inherits it rather than rediscovering it:**
**three scoping rulings tried to move a subset, and two produced S0s.**
`b1` moved the checker leg alone ⇒ `check` exit 0 over a **segfaulting** binary.
`c` moved two existence reads and deferred the third ⇒ located reject became **exit 0 printing
garbage**; the stated reason (*"the deferred site has no sibling SELECTION read"*) was **true and not
sufficient** — it has a sibling **EXISTENCE** read at a different phase.
`b2` left the method-keyed route word behind ⇒ a **head-collision-count** disagreement ⇒ an arity-2
conditional impl called with **one** argument ⇒ **exit 139**.
**⇒ If a future bite finds itself deferring one member, that is a finding, not a plan.**

Carry forward two constraints already derived, so they are not lost with the revert:
- Phase 3′ needs the selector to return **`Option ImplRow`**, not a `String` (`DECISIONS.md`
  RUN-B-028) — and there are **three** entry points, not one.
- The **naive graph-global scan cost `+17%`** on `check-self`, which is why `ieByHead`/`ieHeadRows`
  exist. **Do not reintroduce a scan.** Keep ONE min⊑ selector (`pickMostSpecificEntry`), index on
  `instRefSeq`, preserve `candidateBucket`'s empty-headless fast path.

---

## RV-4 — rewrite `HANDOFF.md`, and hand the branch over honestly

`HANDOFF.md` carries two stacked UNSAFE markings (the `B-2.1-f` update section and *"BRANCH
`arch/stage-b-sprint` IS UNSAFE AS OF `95359281`"*). After a verified revert the branch is **no
longer unsafe in the S0 sense** — but it is also **no longer the drain**. Rewrite, do not delete:

- What the branch now contains (B-3's fusions, `a1`–`a4`'s substrate/index/gate, the ratchet entry)
  and what it does **not** (the drain).
- The three S0s that returned to REPRO, by name and by pin path, **with the reason the revert was
  accepted** (see the cost section at the top, in those words).
- #1397's loud → silent revert cost, named.
- RV-3's set-that-moves-together, as the re-land's entry point.
- ⚠️ Keep the run's expected-red table: goldens are still unblessed (§5, zero for the whole run) and
  a **snapshot / selfproc LEG A re-cut is still owed** for `B-3-a`/`c`/`a2`/`a3`. The revert removes
  `b2`'s and `f`'s golden contributions but **not** Phase 1's, whose LEG A move is **not
  additive-only** — a reviewer pinned the exact expected shape at
  `.claude/sprint-b/review/R1-landed-work.md:274-283` (golden line 1040 deleted, line 1427 re-typed,
  6 additions, `expandSupersTable` unchanged; *anything else in that diff is a finding*). Point at
  it; the re-cut is not this bite's.
- ⚠️ **OWED:** whether §8's exit criterion (fixpoint green on a twice-refreshed seed) has been met
  on the reverted tree. `⚠️ OWED: sh test/refresh_seed.sh` ×2 then
  `⚠️ OWED: sh test/selfcompile_fixpoint.sh` — background it and poll; the harness kills a
  foreground call at 600 s with `exit 143`, which is the ceiling, not a hang, and its exit code does
  not survive a pipe.

---

## Standing requirements

- **Every claim carries its derivation.** Cite `file:line @<commit>` and **say which commit** — this
  ledger's line numbers are per-row against that row's own landing commit and it says so nowhere
  (an S3 R1 filed); the same citation resolves to a plausible *wrong* line ±50-80 at other commits.
- **Never state a count without the command that produces it.** Four counts have been corrected in
  this arc, including one taken from the tree's own comment (*"five"* stampers — actually 7) and one
  from the architecture doc measured wrong in **both** directions. That includes every count in
  *this* brief.
- **Reduced verification floor:** `fmt` (**before** any build) → `make medaka` → `check-self` → the
  targeted gates → `lint`. **No** fixpoint, **no** corpus sweeps, **no** full suites — CI's
  `soundness` shard owns them and its fixpoint step is passing. Record what you did not run and why.
- 🚨 **Never edit an assertion to expect acceptance** where the compiler newly accepts; **never
  delete a loud reject** that still covers a live class (#1578). Loud → silent is a **severity
  INCREASE** even when the old behaviour was also broken. Both rules bite directly on RV-1's
  `check_cli_modules` row.
- 🚨 **Drain claims check drained NAMES individually, never the count.**
- **`engines:` is a FOUR-arm ledger** — LLVM · wasm · eval · `core_ir_eval`. **A revert of an
  IR-changing diff moves all four**, in the reverse direction: eval and LLVM already **disagreed in
  severity** on `c`'s shape (loud `E-PANIC` vs silent garbage) and **wasm was never observed on this
  class at all.** Name what each arm owes; one line with a bare word is not acceptable here, because
  compiled bytes do reach the engines.
- **Deliverable:** a `DEBT.md` row (`sites:` / `transform:` / `could move:` / `nearest miss:` /
  `engines:` / `unchecked:`) + `🔗 DECISIONS.md RUN-B-0xx`. **No `DECISIONS.md` entry — the
  orchestrator's.** For a revert, `could move:` is *"acceptance returns to the pre-drain answer on
  these named classes"* — **enumerate them**; and `nearest miss:` is *the nearest program whose
  behaviour this revert does NOT restore.* Neither may be blank.
- **REFUSE AND REPORT.** Eleven briefs corrected that way this run; **two of the orchestrator's own
  scoping rulings created S0s.** If the revert cannot be done as a clean two-commit revert with the
  four keepers, **that is a finding, not a failure.** An implementer whose region changed under it
  **STOPS; it does not adapt.**
- ⚠️ **Harness friction:** the isolation classifier rejects heredocs, `$VAR`, and redirects to
  scratch paths — **use `Write` to stage fixtures**, and prefer running an existing gate or an
  existing scratch probe (`sa4c/probe.sh`, `probe4.sh`, `c-imp`/`c-imp2`) over hand-staging.

## 📊 MANDATORY: TIME ACCOUNTING (~8 lines; cannot affect your verdict)
Split · biggest sink · **what you had to derive that this brief should have handed you** (scored
against ME, not you) · what of this brief was wasted · build cycles + which were avoidable · **the
OWED items you closed and the ones you left open.** **Reading and thinking are NOT overhead and will
never be counted against you**; only build churn and report-writing are.
