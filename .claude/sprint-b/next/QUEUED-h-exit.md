# QUEUED — the SPRINT EXIT SEQUENCE. Dispatch ONLY if `B-2.1-g` cleared #1514.

⚠️ **GATE ON `g`'s ACTUAL EVIDENCE, not on its verdict word.** This file is reachable only if `g`
reported **both**: (a) `SA-4c`'s program `check`s 0 **and its built binary is correct** (arity-1
specific impl called in **both** import orders, shown in IR), and (b) **#1514 builds and runs
correctly again** — its binary printing `11`/`110`/`7` (`.claude/HANDOFF.md`, the `B-2.1-f` update
section). If #1514 still refuses to build, **this is the wrong file: use `QUEUED-h-revert.md`.**
If `g` cleared #1514 but left `SA-4c` asserting *acceptance over a bad binary*, that is also the
revert file — ⛔ the standing ruling (`HANDOFF.md`) forbids `SA-4c` asserting acceptance over an S0.

**This is FOUR ordered bites, one writer slot, gates between.** Do not fuse them: EX-2's whole job is
to certify that no further source change is coming, and EX-3 is only sound *after* that.

---

## Ordering, and why this order (the argument, so you can refuse it if it is wrong)

```
EX-1  B-2.1-d   delete universeKeyBucketsRef + shadowKeyTableRef   (last source change)
        ↓ gate: d's own floor green (see EX-1)
EX-2  seed re-mint ×2, then selfcompile_fixpoint.sh green          (§8's exit criterion)
        ↓ gate: fixpoint GREEN ⇒ no further source change is expected
EX-3  re-cut the two golden families ONCE, from THAT binary        (§5's zero-goldens rule discharged)
        ↓ gate: both diffs read as predicted per-row (see EX-3)
EX-4  un-safe HANDOFF.md + write the repair-round handoff          (§8's handoff)
```

**Goldens go AFTER the fixpoint, not before.** §5 says goldens are re-cut *once, from the final
binary*. A golden cut before the fixpoint is cut from a binary not yet certified to converge; if the
fixpoint then forces a source fix, the re-cut is wasted **and** you have two conflicting re-cuts of
one file, which is the exact failure the zero-goldens rule exists to prevent. A seed re-mint changes
only `compiler/seed/emitter.ll.gz` and no `.mdk`, so it cannot move a golden — ordering EX-2 before
EX-3 costs nothing and buys the certification. **If you disagree, say so before acting.**

---

## ✅ ALREADY SETTLED — do NOT re-derive, do not re-litigate

An implementer told me this list, not the pointer list, is what keeps a bite short.

1. **The two refs' complete reader/writer sets, the anti-scope list, the three stale comments, and
   the pre-answered `nearest miss:` greps** — all in `.claude/sprint-b/design/P-d-packet.md`,
   §1/§3/§4/§5. Line numbers there are pinned at `1e7cbbbb`; **re-grep the numbers, not the sets.**
2. **`test/typecheck_compiler_source.sh` needs NO change** for the deletion — its `OriginUnresolved`
   allowlist is keyed on line **TEXT**, not line numbers, and none of the deleted lines contains
   `OriginUnresolved` (packet §2c). One line, as promised. *(Note this contradicts
   `QUEUED-d-delete.md`, which warned it was line-keyed. The packet is authoritative and was
   checked; that older warning is retired.)*
3. **The declaration-index defect is FIXED BY this deletion, not by repair** — `buildKeyTable`
   becomes `bucketKeyEntries`' sole caller, so `mergeByDeclIdx`'s ascending precondition holds
   tree-wide. Rewrite the three comments that say otherwise (packet §4a/b/c); do not delete them.
4. **`shadowKeyTableRef` has ZERO ratchet delta**; `universeKeyBucketsRef` has one row
   (packet §2a). **Derive the value, never quote it** — see EX-1.
5. **`refresh_seed.sh` is not idempotent after a codegen change.** Settled; run it twice. Do not
   spend time confirming the claim.
6. **The Phase-1 LEG A move is NOT additive-only, and a reviewer already pinned the exact shape** —
   `.claude/sprint-b/review/R1-landed-work.md:274-283`. Reproduced in EX-3 so you do not have to
   hunt it.
7. **Zero goldens have been blessed all run, deliberately** (§5). That is not an oversight to
   apologise for; EX-3 is where it is discharged.
8. **The fixpoint is IN-BAND for this sequence.** The standing "do not run the fixpoint" floor is
   suspended for EX-2 **only**, because §8 makes it the exit criterion.

---

## EX-1 — `B-2.1-d`: delete `universeKeyBucketsRef` + `shadowKeyTableRef`

🚨 **Your packet is `.claude/sprint-b/design/P-d-packet.md` — AUTHORITATIVE, read it first.**
`QUEUED-d-delete.md` (this scratchpad directory) is the previously-written brief for this same bite;
it is still accurate except for item 2 above. **I am not restating either.**

**Precondition, and it is the whole gate:** run packet §5's greps *before* deleting. Expected after
`g`: **ZERO** `.mdk` code readers of either ref. A surviving reader means `g` did not land what it
said, and a ref with a reader cannot be deleted — **STOP and report.**

Carry these two hazards forward — they are the ones that bite outside the packet:

- **Ratchet row.** `test/registry_keying_ratchet.sh` holds `universeKeyBucketsRef` as a
  `cross_allowed` row, so deleting it **shrinks the allowlist**. It is a **set-equality** check with
  an expected side and an actual side (packet §2a gives both commands). **Derive both values and
  make them agree; do NOT quote a number from the packet, this brief, `DEBT.md`, or the
  architecture doc.** A count in this arc has been wrong **four times** — including one taken from
  the tree's own comment (*"five"* stampers, actually 7 — `DECISIONS.md` RUN-B-022) and one from the
  architecture doc measured wrong in **both** directions.
- 🚨 **The deletion reds `make agent-doc-symbols`.** `docs/spec/SHADOW-SEMANTICS.md` backticks
  `shadowKeyTableRef` in a **SCOPED** tier and there is no exceptions row (packet §2b lists the
  four cells, and says re-derive them because `g` may have moved them). ⛔ **Do NOT add an
  exceptions row** — the symbol is being deleted, not renamed somewhere the gate cannot see. The
  honest edit names the substrate `g` landed (the `implExistsForHead`-over-`IE` successor) in those
  four cells. `.claude/**` is not in the gate's globs, so the sprint docs cost nothing.

**Floor for EX-1:** `medaka fmt --write` on touched source (**BEFORE** any build — a prior writer
lost ~4 min to a post-build reflow) → `make -C <trunk abs path> medaka` → `make check-self` →
`sh test/diff_compiler_flat_vs_onemodule.sh` (13 rows) → `sh test/registry_keying_ratchet.sh` (it
moves; you own it) → `make agent-doc-symbols` → `make docs-links` → `medaka lint`.
**DO NOT RUN** corpus sweeps or full suites.

---

## EX-2 — seed re-mint ×2, then the final fixpoint (§8's exit criterion)

**This bite is the only place in the run where `selfcompile_fixpoint.sh` is in-band.**

1. `sh test/refresh_seed.sh` — **then run it a SECOND time.** It is **NOT idempotent after a
   codegen change**, and a **stale seed can SEGFAULT the fixpoint on a perfectly correct change**
   (`.claude/STAGE-B-SPRINT.md` §5; `AGENTS.md`). Load the **`benchmark-emitter`** skill first — it
   owns the two-rebuild rule and the re-mint procedure. An agent who does not know the
   non-idempotence will spend the session debugging a phantom.
2. Report whether the **second** run produced a further delta to `compiler/seed/emitter.ll.gz`.
   That is a fact worth having in the ledger either way: a second delta corroborates the
   non-idempotence on this diff; no second delta does **not** mean the first run was unnecessary.
3. `sh test/selfcompile_fixpoint.sh` — **must be green.** ⚠️ This is one of the slowest things in
   the tree and the harness kills a foreground call at 600 s with `exit 143` (SIGTERM) — **that is
   the ceiling, not a hang.** Run it **detached/backgrounded and poll**; do not burn the slot on a
   blocking call.
   ⚠️ **Its exit code does not survive a pipe.** Redirect to a file, read `$?`, *then* read the file.
   Do not shorten to `2>&1 | tail`.
4. ⚠️ **OWED, not derivable read-only:** the wall-clock cost of a re-mint + fixpoint on this box
   under load. `⚠️ OWED: time sh test/refresh_seed.sh` and `⚠️ OWED: time sh test/selfcompile_fixpoint.sh`
   — measure and record them; the next sprint's exit budget is currently a guess.

🚨 **If the fixpoint is red, STOP. Do not proceed to EX-3.** A red fixpoint on a twice-refreshed
seed is a codegen non-convergence and it is a finding, not a chore — report it with the stage that
diverged. Any source fix for it re-opens EX-2 from step 1.

---

## EX-3 — re-cut the two golden families ONCE, from the binary EX-2 certified

**Two families move, and both have been unblessed for the entire run** (§5, and every `DEBT.md`
row from `B-3-a` onward records its own contribution):

1. `test/snapshots/compiler/typecheck.md` — bless **by naming the path**:
   `sh test/diff_compiler_snapshot_frontend.sh --bless <the source file>`. ⛔ **Never
   `medaka snapshot --bless`** — it looks for the `.md` beside the source and exits 1.
   ⚠️ Also check the other snapshot suites (`…_eval.sh`, `…_types.sh`) and the **S-expr / Core-IR
   golden families** (`diff_compiler_core_ir*`) — `HANDOFF.md`'s expected-red table lists them as
   moved *by design* this run (the frozen-admissibility carrier is a 5th positional `CProgram`
   field rendered by `core_ir_sexp`). **Derive the moved set from the gates, do not assume it is
   two files.**
2. `test/selfproc_goldens/legA/types.typecheck.golden` — re-capture with
   `sh test/capture_goldens.sh --frozen selfproc_legA`. **CI-only signal** (the `backend` shard);
   it stays green locally, which is exactly how three perf PRs reddened only this shard.

🚨 **The usual "additive-only" bar DOES NOT APPLY to this re-cut.** It is cumulative over the whole
run and it contains deletions and re-types. Assemble the expected shape from the rows, then check
the diff against it **line by line** — *anything else in that diff is a finding*:

| contributor | expected LEG A shape | source |
|---|---|---|
| Phase 1 (`B-3-a`/`c`) | golden line **1040** `keptConstraintIfaces : List (IfaceRef, Mono) -> List IfaceRef` **DELETED**; line **1427** `registerMemberSlots` **RE-TYPED** to `String -> Int -> List (IfaceRef, Mono) -> List CSlot`; **6 additions** (`setFunConstraintEntry`, `setFunConstraintTables`, `setCrossFunConstraintTables`, `setMethodConstraintEntry`, `buildFlatImplEnv`, `ieIndexRows`); `expandSupersTable` **unchanged** (`List Decl -> Unit`) | `review/R1-landed-work.md:274-283` — a reviewer pinned this exactly, and `DECISIONS.md` RUN-B-… confirms *"anything else in that diff is a finding"* |
| `a2`/`a3` | additive-only (new bindings, nothing deleted or re-typed) | `DEBT.md` (`a3` row) |
| `b2` (`1e7cbbbb`) | **+14 bindings, −6, exactly 2 re-signatures** (`keyForSiteByIface`, `selectReqImpl` — each lost a parameter) | `DEBT.md:1244-1252` |
| `f` (`086aeb35`) | **purely additive: 6 new bindings** (`ieCountHeadByMethod`, `ieCountHeadByMethodGo`, `ieHeadCollidesByMethod`, `routeWordHeadSkew`, `reportRouteWordSkew`, `routeWordAmbiguousMsg`) | `DEBT.md:1638-1643` |
| `g` | ⚠️ **OWED — read it off `g`'s own `DEBT.md` row's `unchecked:` clause.** Do not guess. |
| EX-1 (`d`) | deletions only, plus whatever `d`'s own row records |

**Derive the actual numbers rather than trusting that table** (both `DEBT.md` rows hand you the
same command):
```sh
git diff -U0 <BASE>..HEAD -- compiler/types/typecheck.mdk | grep '^[+-][a-zA-Z]' | grep ' : '
```
Pin `BASE=$(git rev-parse 2b9dc798)` — **do not use `origin/main` or a bare ref.** Every worktree
shares one `.git` and a sibling's `git fetch` advances refs under you with no signal.

🚨 **Do not hand-resolve, and do not accept a clean auto-merge, of either golden family on a
rebase.** The LEG A golden is a ~1700-line text file with no merge driver, so two re-cuts in
different regions three-way-merge with **no conflict marker** — that happened to three agents on
this exact file in one session, and **no gate can flag the blend, because the golden IS the
oracle.** If you rebase: `git checkout $BASE -- test/selfproc_goldens/legA test/snapshots`,
rebuild, re-derive.

⚠️ **This stage's bar is NOT byte-identical, by design — selection is semantics** (§5). Every moved
golden cell whose *value* changed gets a **hand-computed** winner with its DICT clause cited. And
**eval is a known-wrong oracle on exactly the shapes this stage moves** (#1071/#1062 are eval-only
S0s) — working the right answer out from the spec first is not optional here. A golden that merely
matches today's output has tested nothing.

**Floor for EX-3:** the snapshot/selfproc gates you blessed, re-run; `git diff` on both families
read by eye against the table above. No rebuild is needed unless you touched source (you should
not have).

---

## EX-4 — un-safe `HANDOFF.md`, and write the repair-round handoff

**`HANDOFF.md` currently carries two stacked UNSAFE markings** (the `B-2.1-f` update section, and
the *"BRANCH `arch/stage-b-sprint` IS UNSAFE AS OF `95359281`"* section). **You may remove them only
by SHOWING the S0 class builds and runs correctly on the FINAL binary** — not by citing `g`'s report.
Re-run, on the binary EX-2 certified:

- **`SA-4c`'s program** — `check` 0, `build` 0, **and the built binary prints `wrap-int-specific`**,
  in **both** import orders. `scratchpad/sa4c/` + `probe.sh` reproduce this against any binary
  (`sh probe.sh <medaka> <root> <label>`) — `f` left them there for exactly this.
- **#1514** — builds, and its binary prints `11`/`110`/`7`. **#1397** — builds correctly.
  `scratchpad/probe4.sh` reproduces both readings.
- **`sh test/diff_compiler_check_cli_modules.sh`** → 0 failing. ⚠️ **Derive the `ok` count; do not
  quote one.** `HANDOFF.md` says 86 after `f`, `QUEUED-g-combined.md` briefed 85, and `f` added
  legs to that gate — the number moved twice already. Also: `1112-A34/later-invisible` is recorded
  as a **pre-existing** red that fails by ACCEPTING, and `f`'s row says that HANDOFF line went
  **stale**. Read the gate output, not the ledger.
- 🚨 **`sh test/diff_compiler_must_fail.sh`, TWICE**, and **check the drained NAMES individually,
  never the count.** *"5 DRAINED"* stayed true across this run while **two of the five were
  over-fire, not progress** (#1397, #1514). Expect **#1564, #1599, #1072** by name, `0
  control-broke`, `0 malformed`. ⚠️ A **malformed** pin reports as DRAINED/benign — that verdict has
  been wrong three times in this project; treat `0 malformed` as load-bearing.
  ⛔ **Do NOT close #1397, #1514, #1564, #1599, or #1072.** §1's issue-closure policy is *implement,
  do not close*; closure is the repair round's.
- **Must STAY put** (a flip is a finding, not a deliverable): `test/must_fail_fixtures/1597-*`,
  the #1075 pin, #1046. A B-2 that "drains" #1046 or #1075 did something out of scope.

Then write the handoff §8 asks for: **the branch, `DEBT.md`, `DECISIONS.md`, and the set of
must-fail pins that flipped red** — plus the repair round's first job, which §8 names: work
`DEBT.md`'s `could move:` / `nearest miss:` columns, because *value goldens cannot see a
diagnostic-only change, absence probes cannot see an undercount, and eval agreement proves nothing
on a dispatch shape.* And ask the Phase 0 question again: **does C4/I2 hold as a CONJUNCTION** —
same instance set *and* same evidence — on a hand-derived permutation differential?

⚠️ **Nothing in this sequence merges the branch.** §8's exit is "the sprint is done", explicitly
**not** "it is verified in any other sense — that is the design."

---

## Standing requirements for every bite above

- **Every claim carries its derivation.** Cite `file:line @<commit>` and **say which commit** — the
  ledger's line numbers are per-row against that row's own landing commit and it says so nowhere
  (an S3 R1 filed); B-3-a's citations are off by −53/−80 at BASE and +70/+76 at `604278bb`.
- **Never state a count without the command that produces it.** Four counts have been corrected in
  this arc.
- **Reduced verification floor:** `fmt --write` (**before** any build) → `make medaka` →
  `check-self` → the targeted gates → `lint`. **No** corpus sweeps, **no** full suites — CI's
  `soundness` shard owns those and **its fixpoint step is passing.** ⚠️ **The one exception is
  EX-2's fixpoint**, which §8 makes the exit criterion.
- 🚨 **Never edit an assertion to expect acceptance** where the compiler newly accepts — that pins a
  bug as expected behaviour (the standing `SA-4c` ruling). And **never delete a loud reject** that
  still covers a live class (#1578): loud → silent is a **severity INCREASE**, even when the old
  behaviour was also broken.
- **`engines:` is a FOUR-arm ledger** — LLVM · wasm · eval · `core_ir_eval` (`core_ir_eval` was the
  omitted fourth arm, RUN-B-007 AM-3). One line is fine when no compiled byte reaches an engine —
  **but state the reason, not the word.** For EX-1 the reason is that a pure deletion of two
  write-only refs emits no changed byte; for EX-3 it is that a golden is not code.
- **Deliverable per bite:** a `DEBT.md` row (`sites:` / `transform:` / `could move:` /
  `nearest miss:` / `engines:` / `unchecked:`) + a `🔗 DECISIONS.md RUN-B-0xx` cross-reference.
  **No `DECISIONS.md` entry — that ledger is the orchestrator's.** `could move:` and `nearest miss:`
  **may not be blank**; "nothing, and here is why" is valid, silence is not.
- **REFUSE AND REPORT.** Eleven briefs were corrected that way this run, and **two of the
  orchestrator's own scoping rulings created S0s.** An implementer whose region changed under it
  **STOPS; it does not adapt.**
- ⚠️ **Harness friction:** the isolation classifier rejects heredocs, `$VAR`, and redirects to
  scratch paths — **use `Write` to stage fixtures**, and prefer running an existing gate over
  hand-staging one.
- ⭐ **Base/branch binaries may already exist in scratch** (`baseB/`, `postB/`, `mine/`, `ctl.bin`,
  `sa4cc.bin`) — **check before building one.** `compiler/**` files are whole-compiler compiles
  (~3/min under load).

## 📊 MANDATORY: TIME ACCOUNTING (~8 lines, per bite; cannot affect your verdict)
Split · biggest sink · **what you had to derive that this brief should have handed you** (scored
against ME, not you) · what of this brief was wasted · build cycles + which were avoidable ·
**the two OWED timings from EX-2.** **Reading and thinking are NOT overhead and will never be
counted against you**; only build churn and report-writing are.
