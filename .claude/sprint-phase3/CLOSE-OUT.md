# Stage B / Phase 3′ (`B-2.2`) — CLOSE-OUT CHECKLIST

**What this is.** The executable form of the sprint contract's §6 (Phase 2), §7 (the repair
round) and §8 (exit criteria), plus the sweep of everything `DECISIONS.md` states as **owed with
no owner**. It exists because the referee audit found six owed follow-ups recoverable only by
reading ~1500 lines of ledger. **Nothing here is new policy** — every line cites its `RUN-P3-0NN`
entry or a `file:line`.

**BASE pin:** `68f84bf1` (RUN-P3-001). **Branch:** `arch/stage-b-phase3-b22`.
**State at writing** (DERIVED, `git log --oneline` + `git status --short`): `a` (`cd1f2c8d`), `f`
(`d5948e3a`) and **`b1`+`e` (`ec1cda37`, with its `DEBT.md` row)** are **committed**; the tree is
clean. **`c` has NOT landed** — no commit, and the three comment corrections RUN-P3-033 scopes
(`:19397`'s stale nested-`requires` justification, `:18354-18360`'s wrong-tier warning,
`entailInst`'s header) are not in the tree. **`b2` is DROPPED** (RUN-P3-032).
**Phase 2 does not start until `c` is committed** — it edits `typecheck.mdk`, so it moves that
file's snapshot, and a golden cut before it is cut from the wrong binary.

**Labels.** `DERIVED` = re-run first-hand while writing this file. `RELAYED` = taken from the
ledger with its entry cited, not re-run. **No count appears without the command that produced it.**

---

# 1. Phase 2 — the in-band close-out, in execution order

Contract §6. Not deferrable: this unit changes emitted IR.

### Step 0 — quiescence and preconditions

| | |
|---|---|
| **do** | `git status --short` clean; **`c` committed** (`a`/`f`/`b1`+`e` already are); **one writer only**, no sibling agent building in this worktree |
| **expect** | empty status; `git log --oneline` shows `a` `cd1f2c8d`, `f` `d5948e3a`, `b1`+`e` `ec1cda37`, and `c` |
| **wrong ⇒** | a dirty tree at this point means **every golden re-cut below is cut from a binary nobody can reproduce.** Stop and commit first — a re-cut golden is only meaningful against a named SHA |

### Step 1 — the FINAL binary

| | |
|---|---|
| **do** | `make -C /root/medaka/.claude/worktrees/expressive-prancing-minsky medaka` then `make -C … check-self` |
| **expect** | exit 0; `check-self` PASS (~20 s) |
| **wrong ⇒** | an ill-typed compiler builds green without `check-self` — the bootstrap emit path does not gate on type errors (`AGENTS.md`). A red here is a real break, not a golden question |
| ⚠️ | **Everything below re-cuts from THIS binary.** Any later source edit — including a `fmt` reflow — invalidates every golden cut after it. If you edit, restart at step 1 |

### Step 2 — `test/refresh_seed.sh`, run **TWICE**

| | |
|---|---|
| **do** | `sh test/refresh_seed.sh` — **then run it again.** Contract §6.1 |
| **why** | it is **not idempotent after a codegen change**: pass 1 mints a seed from the new emitter, pass 2 mints from an emitter *built by that seed*. A stale seed **segfaults the fixpoint on a perfectly correct change** (`AGENTS.md` `benchmark-emitter`; `HANDOFF.md:26-28`) |
| **wrong ⇒** | a segfault or mismatch in step 3 is the **stale-seed signature**, not your change. Come back here and re-run before debugging anything semantic |
| ⚠️ | do not stop after one run because "the second one changed nothing" — that is the *expected* end state, not evidence the second run was unnecessary |
| **expected outcome, MEASURED at `ec1cda37`** | **a no-op.** `b1`+`e`'s row records `selfcompile_fixpoint.sh` reporting **C3a YES** (IR1 byte-identical to the seed-bootstrapped reference) **and C3b YES** — *"the seed does not need re-minting, measured rather than hoped"* (`DEBT.md` `b1`+`e`, `could move:` (4)). **So a non-empty `git diff -- compiler/seed/` here is the SURPRISE, not the expectation** — if the seed moves, `c` or the golden work changed emitted IR and that needs explaining before step 3. Run it anyway: that measurement predates `c` |

### Step 3 — `sh test/selfcompile_fixpoint.sh` on the twice-refreshed seed — **MANDATORY**

🚨 **`f`'s `DEBT.md` row tried to WAIVE this and the waiver is INVALIDATED.** The row's
`unchecked:` (4) reads *"no fixpoint … `llvm_typed_ir` passing byte-for-byte makes the fixpoint's
question already answered for this diff."* R-1 refuted it (RUN-P3-036, finding 2): **those gates'
corpus is 54 single-file, prelude-free fixtures**, so the qual arm, both module seed/snapshot
pairs and the joint-discovery snapshot are **never reached** — it covers **~1 of 6 changed
regions**. The commit message carrying the same claim over-claims for the same reason.
**The fixpoint is not optional for this sprint.**

| | |
|---|---|
| **expect** | green |
| **wrong ⇒** | segfault → step 2 (stale seed). Genuine IR mismatch → the emitter is not at fixpoint; that is a real defect and it is the decisive gate for a compiler-source change |
| **record** | **say which stage ran.** "CI fixpoint passed" covers **C3b only**; a local `selfcompile_fixpoint.sh` run must name C3a *and* C3b in the close-out note, or the next reader over-reads it. The `b1`+`e` row already names both — re-confirm on the post-`c` binary and say so |

### Step 4 — rebuild the oracles the re-cuts read (BEFORE any capture)

| | |
|---|---|
| **do** | `FORCE=1 JOBS=1 sh test/build_oracles.sh --build-one check_all_main` and the same for `llvm_emit_typed_main` |
| **why** | the `selfproc_legA` capture arm **requires `test/bin/check_all_main`** and exits 2 without it (`test/capture_goldens.sh:181-182`, DERIVED); `diff_compiler_llvm_typed_ir.sh` captures from `test/bin/llvm_emit_typed_main` (`:41-42`). **A stale oracle exits 2, which reads like a skip, not a failure** (`AGENTS.md`) |
| **wrong ⇒** | a golden cut from a stale oracle records the *previous* compiler's answer — the single most expensive mistake available in this step |

### Step 5 — the goldens, re-cut **exactly once**, from the final binary

Contract §6.3. **Never merged, never hand-resolved.** On any rebase: take base's version of both
families and **re-derive** — a golden three-way-merges with no conflict marker and the blend
becomes the new oracle (`AGENTS.md`; it happened three times in one 2026-08-11 session).

**Do not work from a list of families — derive the set.** `grep -rln 'CAPTURE:-0\|CAPTURE=1'
test/*.sh` → **26 files** (DERIVED). Run the gates, re-cut only what actually reds, each by name.
The families below are the ones the ledger *predicts* will move.

#### 5a — the snapshot corpus

**One suite owns every compiler source** (DERIVED, `test/diff_compiler_snapshot_frontend.sh:164-168`):
family `compiler`, stages `desugar,mark`, globbing
`compiler/{frontend,types,ir,backend,eval,driver,tools,support}/*.mdk` → `test/snapshots/compiler/`.
The other seven `diff_compiler_snapshot_*.sh` suites do **not** carry compiler sources.

| | |
|---|---|
| **do** | `sh test/diff_compiler_snapshot_frontend.sh --bless compiler/types/typecheck.mdk compiler/eval/eval.mdk compiler/ir/core_ir_lower.mdk` (+ any other file the run reds on, **named**) |
| **expect** | the gate then reports every existing snapshot compared and matching |
| **wrong ⇒** | `--bless` naming nothing is refused by design (`:100-104`) — there is no whole-suite bless. A `--bless` that "fixes" a red without your having decided the new output is correct is a rubber stamp |
| ⚠️ | the diff **is** the review gate. Read it |

#### 5b — 🚨 `route_key.mdk` needs a snapshot **CREATE (`--new`)**, not a re-bless

`B-2.2-a` created `compiler/types/route_key.mdk`, which **auto-enrolled** in the shared snapshot
corpus via the `compiler/types/*.mdk` glob — a corpus **ADD, not a golden move** (measured at the
bite's landing: 201 of 201 existing snapshots compared and matching, zero goldens moved —
RUN-P3-021, `DEBT.md` `a`, `HANDOFF.md:20`). `--bless` cannot create it. **The gate's own header
warns against `--new`, so this is a deliberate decision, not a reflex.** Three guards, all DERIVED
from the script:

1. **`--new` takes NO path argument** (`:138` — `[ "${1:-}" = "--new" ] && MODE="--new"`). It is
   suite-wide and creates **every** missing snapshot. **Before running it, confirm the run reports
   exactly one `FAIL no snapshot` row, and that row is `route_key.mdk`.** Any second missing
   snapshot is created silently in the same breath.
2. **Re-run the gate WITHOUT `--new` afterwards.** Under `--new` every existing fixture is
   *skipped*, and the summary historically read *"all snapshots match"* having compared **nothing**
   (the gate's own post-mortem, `:170-185`). Only the no-flag run proves the corpus still matches.
3. **Read the created file.** `--new` writes a golden from current output; the created snapshot is
   the *only* thing that will ever grade `route_key.mdk`'s desugar/mark rendering.

#### 5c — `selfproc_legA`

| | |
|---|---|
| **do** | `sh test/capture_goldens.sh --frozen selfproc_legA` (`capture_goldens.sh:174-196`) |
| **moves** | `test/selfproc_goldens/legA/types.typecheck.golden` (`f` + `b1`+`e` + `c`) and `eval.eval.golden` (`e`) |
| 🚨 **correction** | the `b1`+`e` `DEBT.md` row says *"all three edited modules are LEG A."* **Two of three.** `compiler/ir/core_ir_lower.mdk` is **NOT** in the LEG A corpus — the module list is fixed at `capture_goldens.sh:191` (`… ir.sexp … types.typecheck eval.eval tools.check`) and `AGENTS.md` names `ir.core_ir_lower` as excluded explicitly. **DERIVED.** Expecting a third golden and not getting one must not be read as a missing re-cut |
| **CI only** | this family reds in the CI `backend` shard, green locally unless you run `diff_compiler_selfproc.sh` — and that gate phantom-skips (exit 2 → `FAIL*`) without its oracles, which is why step 4 is not optional |

🚨 **The `types.typecheck` re-cut will NOT be additive-only, and that is expected.** R-1 derived the
expected shape (RUN-P3-036): **4 deletions + 4 additions + 5 MODIFIED rows.** `AGENTS.md` forbids
modified rows by default ("no *existing* binding's inferred type may change"), so the reviewer's
question is **not** *"were rows deleted"* but:

> **Is each modified row a strict generalization — the old type an instance of the new at
> `a := List X` — and did nothing else move?**

- **The 4 deletions are accounted for:** `f` collapsed two structural-duplicate pairs into one
  polymorphic function each — `attributeModuleArities` + `attributeModuleArrIfaces` →
  `attributeModuleEntries`, and `lookupQualArity` + `lookupQualIfaces` → `lookupQualPayload`
  (`DEBT.md` `f`, `sites:`).
- **Two bindings are REQUIRED to be UNCHANGED: `declaredConstraintSlots` and `qualConstraintFor`**
  (RUN-P3-036). `declaredConstraintSlots` was demoted to a projection of `declaredConstraintFor`,
  and R-1 held its byte-identity on an *identity* (`qualConstraintKey ≡ hasImportDefiner`), not a
  contingency — if either row moved, that identity broke.
- **A sixth modified row is a regression.** Do not bless it; derive what moved.

#### 5d — `llvm_typed_ir` — **it did NOT move. Question ANSWERED; do not capture**

**MEASURED at `ec1cda37`: `llvm_typed_ir` 54/54 byte-identical** (`DEBT.md` `b1`+`e`, `could move:`
(5)). So `HANDOFF.md:18`'s prediction that it moves is **stale**, and contract §6.3's *"it did not
move in Stage B, and that green proves less than it looks"* is the accurate reading.

| | |
|---|---|
| **do** | run `sh test/diff_compiler_llvm_typed_ir.sh` to confirm on the final binary. **Do not `CAPTURE=1` a green gate** |
| 🚨 | **the green is not evidence.** The corpus is **54 single-file, prelude-free fixtures** ⇒ absent origin ⇒ `ifaceWordOf` falls back to the bare name — *"which is exactly why it cannot see this bite; do not read its green as multi-module evidence"* (the row's own words). The multi-module evidence is the new `dict_semantics` IR assertions, not this gate |
| **wrong ⇒** | a **red** here would mean a single-file word moved, i.e. the bare-name fallback broke — a regression on the flat drivers (`check <single file>`, lsp, repl, doc, lint, snapshot), **not** a golden to re-cut |

#### 5e — the `dict_fixtures` shared corpus (`b1`'s five new fixture directories)

**Consumers, DERIVED and word-bounded** (`grep -rln '[^_a-z]dict_fixtures' test/*.sh
.github/workflows/*.yml`): **exactly one — `test/diff_compiler_dict_semantics.sh`.**
`test/diff_compiler_import_order.sh` mentions the corpus only in a comment; its own `FIXDIR` is
`test/import_order_fixtures` (`:143`). *(The unbounded grep matches `eval_dict_fixtures` and
`build_diff_fixtures` and inflates this to 20+ files — bound it, per `AGENTS.md`'s shared-corpus
trap.)*

⚠️ **Section 4 of that gate (the impl-block permutation section) is scoped to `*.mdk` files
DIRECTLY in `FIXDIR`, no recursion** (`:906-911`) — so the five new **directories** are excluded
from it by the glob. Confirm the new fixtures are actually opened and graded by sections 1 and 3,
and that the gate **prints** them. A fixture nothing opens is the "didn't run is indistinguishable
from passed" shape this whole suite exists to prevent.

### Step 6 — re-show the drain claims on the final binary, **TWICE**, quiescent

Contract §6.4 (`EX`-equivalent).

| | |
|---|---|
| **do** | `sh test/diff_compiler_must_fail.sh` plus each claim the PR body will make, run **twice** on the final binary with no other writer live |
| **expect** | a red naming a pinned issue is a **drain deliverable**, not a break (`HANDOFF.md:19`); a red naming anything else is yours |
| 🚨 **the drain this sprint actually produced** | **`test/must_fail_fixtures/1514-xmod-same-spelled-iface-impl-selection` DRAINED** (`DEBT.md` `b1`+`e`, `could move:` (1); the fixture is still present, DERIVED). Two unrelated modules each declaring `interface Same` + `impl Same Blob` used to collapse onto one route word and answer both call sites with one module's impl — import-order dependent, exit 0, no diagnostic. Now `11 / 110 / 7`, the fixture's own **hand-derived** correct answer. **The close-out owns closing #1514 and DELETING the fixture** — nothing was blessed or deleted by the bite, per the packet |
| ⚠️ | **#1182's pin still reproduces and must stay** (`run` → 1, control → 2). `b1` makes it **quieter → differently wrong**: where the head-tag hedge used to mask the mis-selection, the wrongly-selected instance's identity is now stamped directly. That is a severity *increase* in the ladder's terms and it is recorded, not fixed |
| 🚨 | **the drain list itself is stale — see §5 item 4.** #1072 and #1071 are CLOSED (drained by *Stage B*); **#1062 is EVAL-ONLY and this sprint's route-word half does not touch it.** Do not re-show, and do not cite, #1062 as drained here (RUN-P3-037) |
| **wrong ⇒** | a claim that shows once and not twice is not a claim. Two runs, same tree, same binary |

### Step 7 — assemble the PR body

Only from §5's allowed set. §8.7: **the PR title's severity claims must match the body's own table.**

---

# 2. Phase 3 — the repair round's attack list

Contract §7. Built from `DEBT.md`'s `could move:` / `nearest miss:` columns — *"this is what
produced the attack lists that found the regressions in both sprints."* Each row is a **thing to
attack**, with its grading rule.

> **Standing rule for this round (§7 delta 1):** a `DEBT.md` row is owed for **any** delta the
> differential DETECTS, not only ones an implementer recognized — written at detection time, by
> the round that found it.

### A1 — the same-spelled-interface pair (`a`'s and `f`'s `nearest miss:`, RUN-P3-003)

Two modules each declaring `interface Speak`, each with an impl at the same head. Pre-bite both
route on the bare word `Speak|T|`; post-`b1`+`e` they must separate on `<mid>::Speak|T|`.
**Grade against BOTH LLVM consumers, not one:** `implEntryRouteKey`
(`compiler/backend/llvm_emit.mdk:1486-1492`) is a *second, module-scoped* route-key decision, and
its sibling `implEntryRouteWords:1512-1518` **unions** the key with the bare tag — so the union arm
can accept a word whose direct arm has diverged. That union is precisely the channel that hides a
skew (RUN-P3-003).

### A2 — `e` **changes a collision verdict** (RUN-P3-026) — landed, row written, **not yet attacked**

`ifaceDeclHeadUnique` → `declKeysAtHead` dedups by canonical key, so an identity-bearing key
flips `unique` from `True` to `False` for two same-spelled interfaces at one head, closing a skew
that was live and masked by `implEntryRouteWords`' union arm. **The delta is recorded** (`DEBT.md`
`b1`+`e`, `could move:` (2)) — what is *not* done is the attack: **acceptance survives only because
that union arm emits `{routeKey, headTag}`** (the new colliding-heads fixture shows the `icmp eq`
against **both**). Attack the case where the union is the only thing holding it up — a program
where the direct arm's word and the tag disagree — and check the **wasm** family, which does not
consume the shared table at all.

### A3 — the dict-pass sites leave a **STALE** prefix, not an absent one (R-1 finding 1, RUN-P3-036)

`resetState ()` fires at exactly two sites, **neither** between the last `checkBodyImpl` and
`dictPassModules*`, so the declared table still holds the *previous module's* entries. A reader
there gets a **present, wrong** prefix — the one state `CDPUnknown` exists to make impossible.
**Fail-closed is not achieved by not writing; it requires writing `[]`.** Relayed to the live
implementer as a one-token fix. **Attack: verify it actually landed**, and if not, that no `b1`
read reaches the define side.

### A4 — `f`'s witnessed arithmetic trap has **no landed test** (`DEBT.md` `f` `unchecked:` (1))

`twice : (Shw a, Shw a) => a -> Int` — one tyvar, duplicated constraint; `dedupSlots` collapses
2→1, **witnessed** by an instrumented build (RUN-P3-024), and it fired **nowhere in a full `make
medaka`**, so *"the self-build is clean"* is not evidence. The program is carried only as a comment
and a `nearest miss:` line. **Now that `b1` makes the prefix observable, land it as a fixture — or
state in the round's own row why it still cannot be asserted.**

### A5 — F-5: the `ImplBuckets` second deciding population (RUN-P3-008 / -032 / -038)

`selectReqImpl`'s `iface == ""` arm decides via `findImplEntry` — a **first-match, head-tag-bucketed
linear scan in declaration order**, over a population that **omits no-requires impls**. Four static
callers reach it via `routeOf … "" ""` (`:19848`, `:19882`, `:19934`).

🚨 **OWED-3's probe answered and did NOT discriminate** (RUN-P3-038): it went through `entail
EKNestedTop` with `iface != ""`, i.e. very likely the *other* arm, so its clean `2/2` result is
**not** evidence F-5 is absent. **The round owes a program that provably reaches `routesOfMonos*`,
or an instrumented build confirming the arm was entered.** Grading: swap two impl blocks with no
other change and see whether the answer moves (the #1154 shape). File only if it reproduces.

### A6 — the P4 tripwire's uncovered copy sites (RUN-P3-011)

The tripwire has **≥3 copy sites** and R3 named the wrong one for the common case:
`inferDictAtFound:9170-9176` is the **common** case, `shadowStandaloneDictSlots:12374` the third,
`resolveRecMono:20159` the recursive one. `b1`'s new dict fixtures pin depth-1, one appended slot.
**Attack the two things RUN-P3-011 records a still-green P4 would NOT mean:** a **transitive**
chain (`Top requires Mid requires Base` — `expandSupersFix:9433` is a fixpoint and forges two
slots), and **nesting depth ≥ 2** (contract §3 item 3: `b1`'s `nearest miss:` is depth ≥ 2 because
D4, not `argReqRoute`, is the recursion hub).

### A7 — F-6: `sanitizeId` is not injective and `e` widens the alphabet reaching it

`sanitizeId` (`compiler/backend/private_mangle.mdk:682-698`) maps every char outside
`[A-Za-z0-9_]` to a **single** `_`. Module ids are loader-derived **paths**, so `a.b::I|T|`,
`a/b::I|T|` and `a-b::I|T|` **all** collapse to `a_b__I_T_` (RUN-P3-030). A second, independent
channel is `hashName key` (djb2), which no `sanitizeId` reasoning covers. **Owed fixture (`e`'s
`nearest miss:`): two modules whose sanitized `<mid>::<iface>` spellings collide, asserting
DISTINCT emitted symbols.** ⚠️ Use the **path** example only — see §5 item 7.

### A8 — the engines leg (§7.4)

- **eval is a known-wrong oracle on exactly the shapes this unit moves.** Hand-compute every moved
  golden's winner **with its DICT clause cited**; do not capture.
- **The two engine families resolve a multi-candidate `__none__` bucket by different rules**
  (RUN-P3-013): LLVM's `findByTag` takes the **first** in program order; eval's `pickTagFallback` →
  `oneOrMultiV` **punts to the untyped arg-tag path**. That is a divergence surface, recorded for
  this leg.
- **#1608** (S1, filed by the previous sprint, un-pinnable): `core_ir_eval` selects a cross-module
  impl by **import order**, and it is `eval.mdk`'s lockstep peer — a file this sprint edits.
  **Any `b1`/`e` fixture asserting on `run` in a cross-module shape may be measuring #1608**
  (RUN-P3-037). Cross-check every such row with a permuted import order.
- **F-2 and F-8 controls are expected EQUALLY BROKEN on both arms** — `e` unifies the *printers*
  (the word), not the *head projections* (the tag). A DIFFERS on either is a finding.

### A9 — the base-vs-branch differential (`/var/tmp/p3/r3/`)

Instrument: 15 programs × 4 channels × 2 arms, **graded on stdout and diagnostic text; exit codes
reported, never graded** — two of Stage B's four known differences had identical exit codes in
every channel. Base arm: `/var/tmp/p3/base-arm` (RUN-P3-034), verified sound because a `medaka`
binary resolves its emitter *and* stdlib from **`exeDir`**; all four exe-adjacent items present
(`medaka`, `medaka_emitter`, `stdlib`, `runtime` — DERIVED, still present at writing), and
`route_key.mdk` **ABSENT**, which is what makes it a base rather than a mirror.

🚨 **The ledger says the harness has NEVER BEEN RUN. That is STALE — it has been run once, and the
CONTROL IS RED.** DERIVED from `/var/tmp/p3/r3/run1.log` (written 02:35, after RUN-P3-036 at 02:28):

```
programs 15 · channel rows SAME 51 · DIFFER 9 · EXITONLY 0 · normalization leaks 0
both-arms-check-fail 4   (vacuous programs)
🚨 THE CONTROL (p01_control) DIFFERS. THE HARNESS IS SUSPECT.
```

**Read the rows before adjudicating anything: the p01 difference is on the `build` channel and the
two texts differ only in the arm name embedded in the output path** —
`built <CORPUS>/p01_control/main.mdk -> <OUT>/p01_control/base/prog` vs `…/branch/prog`. That is a
**normalization gap in the harness, not a compiler difference**, and the harness's own
`normalization leaks: 0` counter did not see it. Three things this round owes, in order:

1. **Fix `normalize()`** to canonicalize the arm segment (or drop the output path from the graded
   build text), then **re-run**. Until the control is SAME, **no other row is adjudicable** — the
   harness says so itself.
2. **Explain the 4 `both-arms-check-fail` rows.** A corpus of unparseable programs otherwise
   reports a clean all-SAME (the harness has the counter for exactly this reason).
3. **Re-run against the FINAL binary**, not the branch arm as built mid-flight — check the branch
   arm's provenance before quoting any row.

**Refusals the harness already enforces (exit 2, before measurement):** `MEDAKA_ROOT` /
`MEDAKA_EMITTER` set (they cross both arms silently), both arms resolving to one directory, and a
missing `runtime/medaka_rt.c` — the last bites only on the **first `build`**, so `check`/`run`
succeeding does not prove an arm is complete.

**Landing rule (§7 delta 2): a probe whose verdict gates the merge must be LANDED.** Route,
DERIVED: `test/diff_compiler_ci_shard_coverage.sh` enumerates **every tracked `.sh` in the whole
repo** via `git ls-files` (`:157-166`) — not just `test/diff_compiler_*.sh` — and a script that is
in no shard pattern, named by no job, in no EXCEPTIONS ledger and not in
`test/CI-COVERAGE-TOOLS.txt` **fails that gate**. A two-worktree differential is a **tool, not a
gate**: land it and add its path to `test/CI-COVERAGE-TOOLS.txt`. *(RUN-P3-029's "a new `test/*.sh`
trips the coverage gate" is right and understates the scope.)*

⚠️ **Smoke-test before citing.** `repro/run.sh` was **broken on its first run** — a `set -e` killed
it at F-2's first intentionally-failing `build` and it silently reported a subset as the whole
(RUN-P3-022). This is the *"reviewers' programs are unrun by construction"* trap **inside a harness
written to preserve findings**.

### A10 — the C4/I2 conjunction question, asked again at the end (§7.3)

On a **hand-derived permutation differential**: same instance set **and** same evidence, with
**P4 included explicitly** (Q5). One **Fable consult** is available for this and only this (§9).
Two constraints on how the answer may be stated:

- **P4 green after `b1` means less than it looks** (RUN-P3-011): not that the appended slot carries
  `Base`'s identity (one impl per interface ⇒ a wrongly-stamped identity still lands on the right
  row via the fallback tier — **only the IR/mechanism assertion discriminates**); not that the other
  two copy sites are covered; not that transitive chains are covered; not that `f`'s flag is
  non-vacuous; not that #1127 is drained.
- **#1127's repro carries an `assum`-vs-`super` control that is exactly the P4 axis** — adopt it
  rather than authoring fresh (RUN-P3-037).

### A11 — the perf note nobody owns (R-1, RUN-P3-036)

`f`'s read side calls `lookupAssoc`, which calls **`opBump`**, so the perf gate's op-count metric
moves by ~one table scan per constrained call site — **for a value nobody reads**. Not quadratic;
**owed a perf run.** `test/diff_compiler_perf_scaling.sh` is 654–748 s and **foreground-unsafe** —
background it, or shrink with `PERF_N=<n>`.

---

# 3. Exit criteria — with an owner per line

Contract §8, plus the audit's addition (criterion 5). **Owner roles:** `ORCH` = this sprint's
orchestrator · `IMPL` = the bite's implementer · `RR` = the repair round (Phase 3) · `FILE` = the
exit-phase filing pass.

| # | criterion | owner | done when |
|---|---|---|---|
| 1 | every in-scope bite landed; tree builds and self-typechecks. **In scope after Phase 0: `a` ✅, `f` ✅, `b1`+`e` (uncommitted), `c` (not landed). `b2` is DROPPED** (RUN-P3-032) | IMPL → ORCH | §1 step 1 green |
| 2 | fixpoint green **on a twice-refreshed seed** | ORCH | §1 steps 2–3, **stage named** (C3a/C3b) |
| 3 | goldens re-cut **once**, each moved family with a **hand-derived** justification | ORCH | §1 step 5; legA reviewed against the 4+4+5 expectation |
| 4 | repair-round findings **fixed or filed** | RR → FILE | §2 worked; every DETECTED delta has a `DEBT.md` row |
| 5 | **every verified desk close executed or handed to a named owner** | ORCH | table below, no blank owners |
| 6 | the `D2 §3` carrier ruling written to `DECISIONS.md` **and filed to #1113** | ORCH | RUN-P3-009 ✅ written; **the filing to #1113 is still owed** |
| 7 | PR **title's severity claims match the body's own table** | ORCH | §5 respected |

### Criterion 5 — the desk closes (RUN-P3-037, R-4; each DERIVED tracker-side, RELAYED here)

| issue | action | owner | note |
|---|---|---|---|
| **#1512** | **CLOSE** | ORCH | its three owed fixtures all exist at HEAD |
| **#1557** | **CLOSE** | ORCH | `ieCandidacyVisibleAt _ _ = True`; `universeIfaceRequiredRef` survives as 11 comment tombstones, zero code sites |
| **#1558** | **CLOSE — but the close comment MUST carry the re-scope** | ORCH | it landed as an owner-ruled **SPLIT, not the deletion its body specifies**; `test/registry_keying_ratchet.sh` says so in its own words. Close it silently and the next reader takes the title as evidence the name axis flipped too. **It did not** |
| **#1559** | **CLOSE** | ORCH | `checkCoherence` takes `ImplEnv`; `CohImpl` carries an `IfaceRef` |
| **#994** | 🚨 **ANTI-CLOSE — must NOT be closed, and this sprint WIDENED it** | ORCH | #994's third bullet is that CrossRun's mirror pairs reset *"only by whole-record re-mint."* At HEAD there are **eight lockstep `setRef`s at one site — two of them `f`'s.** PR #1605's *"Implements B-3 (#994)"* is true of the PerRun pairs and **false of the CrossRun snapshot.** Closing it would bury a live drift surface **a `b1` bug lands squarely on.** Partial-identity-reads-as-done, with our own bite now part of it |
| **#1113** | **do NOT close** (implement-don't-close). **Update the body** | ORCH | its *"depends on Stage A"* dependency is discharged (Stage A merged 08-12); its drain line is two-thirds spent — see §5 item 4 |
| **#1514** | 🚨 **CLOSE, and DELETE its fixture** — `test/must_fail_fixtures/1514-xmod-same-spelled-iface-impl-selection` **DRAINED** on this branch (§1 step 6). This is the sprint's one measured acceptance win; the pin is red *because* it drained, and the fixture must go with the close or the gate stays red on `main` | ORCH |
| **#1122** | update: its serialized lane still reads as though B-2 were gated behind U2/U4, which have not landed and are being overtaken | FILE | RUN-P3-037 |

### Criterion 4 — the findings worklist (`FINDINGS.md`, routed by R-4)

| row | routing | owner |
|---|---|---|
| **F-1** prelude-method-name collision | **cell on #1450** — routing **CONFIRMED and now IR-derived** (OWED-2, RUN-P3-038: `@mdk_impl_T_sub` takes **two** params against the control's one, i.e. `Num.sub`'s arity — #1450's mechanism read the way #1450 read it) | FILE |
| **F-2** function-typed impl head | **file separately** (S0 + S1) | FILE |
| **F-8** effect-carrying impl head | **file separately** — same root arm, **different fixes** (F-2 needs `TyFun` to get a tag; F-8 needs two projections to agree). Merging gives one pin two fixes | FILE |
| **F-3** same-file two-interface method collision | ✅ **now REPRODUCED first-hand by the orchestrator with its own control** (`repro/f3_method_collide/`), so the "do not file until reproduced" hold is **discharged** → **FILE NEW.** The dedup discriminator is measured, not argued: the emitted symbols are **correct and distinct** (`@mdk_impl_Alpha_T__ping` / `@mdk_impl_Beta_T__ping`), so the wrongness is downstream of naming — not #1265 (defaults only) and not #1182 (this needs no permutation). Three-way divergence in one program: `check` 0 · `run` 1 (E-PANIC) · **built binary exit 0 printing a raw word** — the build arm is the S0 | FILE |
| **F-4** `expandSupersIfaceEntry` non-idempotence | file, **labelled derived-not-measured** | FILE |
| **F-5** `ImplBuckets` second population | **RR first** (§2 A5); may be a cell on **#1154**. File only if it reproduces | RR |
| **F-6** `sanitizeId` non-injectivity | **cell on #347** (OPEN, `needs-repro`, and its body says *"nobody has built two modules whose paths differ only in a separator char"* — F-6 supplies exactly that) | FILE |
| **F-7** two stale in-tree comments | **in scope — bite `c`**, which has **not landed**. Now **three** comments (RUN-P3-033) | IMPL (`c`) |

---

# 4. 🚨 The orphaned follow-ups — the reason this file exists

Everything `DECISIONS.md` states as owed with no named owner, **each re-checked against the tree
before being listed**. Two of the six the audit named are **DISCHARGED** and are marked so — a
discharged debt advertised as owed invites the next agent to re-spend a quiet window on it
(R-2 caught exactly that pattern in `FINDINGS.md`).

### O-1 — the fixture with nowhere to live — ✅ **DISCHARGED and COMMITTED** (`ec1cda37`)

**Claim (RUN-P3-029):** `diff_compiler_llvm_typed_ir.sh` reads a single-file corpus and
`diff_compiler_llvm_modules.sh` grades native stdout against an eval golden — **no corpus gives an
IR golden for a multi-module program**, which is exactly what `b1`'s cross-module fixture needs.

**Status, DERIVED (`git show ec1cda37 --stat`, `DEBT.md` `b1`+`e` `sites:`):** the writer solved it
**without an IR golden and without a new gate file** — **5 table rows + 8 IR rows** in
`test/diff_compiler_dict_semantics.sh` and five new `test/dict_fixtures/` directories, i.e.
directory fixtures in section 1 plus IR `HAS`/`LACKS` assertions in section 3
(`@mdk_default_sz_Box`, `@mdk_impl_Cup_sz`, the two-`@mdk_dc_0` P4 row, the qualified
`@mdk_impl_base__Base__Box_Int___btag` **HAS** paired with the bare
`@mdk_impl_Base__Box_Int___btag` **LACKS**, and the two-distinct-dict-constants row). That is a
better answer than the one RUN-P3-029 proposed, and it adds no `test/*.sh`.

**Residual owner: ORCH, at §1 step 5e** — one check remains: that the gate **actually opens** the
five directories (section 4's `*.mdk`-direct glob excludes them, so their grading rests entirely on
sections 1 and 3). `dict_semantics` reporting **176/176** at the landing (`DEBT.md` `could move:`
(5)) against **163/163** during `e`'s M4 experiment is consistent with 13 new assertions being run
— confirm it, don't infer it. Not owed as a design decision any more.

### O-2 — the snapshot `--new` decision — ⏳ **STILL OWED**

RUN-P3-021 item 3; `HANDOFF.md:20`. **Owner: ORCH, §1 step 5b**, with the three guards derived
there (no path argument ⇒ suite-wide creation; re-run without `--new` or the summary lies; read the
created file). Decision to record in `DECISIONS.md` at the close-out: **create it** — the
alternative is a compiler module that no snapshot ever grades.

### O-3 — the **#1457 time-bomb** — ⏳ **STILL OWED, and nothing fires today**

**The debt (RUN-P3-017):** today the population of cross-module appended super slots is restricted
to callees that declare a super-implied constraint but **never call the super method**, because a
body calling a superclass method is **false-rejected on the multi-module path** (#1457, OPEN,
`verified`, S1). **`f`'s and `b1`'s blast radius grows the moment #1457 is fixed, and a fixture
written before that fix will not exercise the shape that matters after it.**

**Verified still owed, DERIVED:** the pin `test/must_fail_fixtures/1457-superclass-entail-xmod-false-reject/`
exists and **self-drains** — but its `claim.txt` ends *"A fix that makes `check main.mdk` accept
this program flips the pin and drains this row… Close #1457 and delete this fixture then."* It says
**nothing** about the dict fixtures whose population widens. **So the drain fires, and the message
it carries does not mention us.**

**Owner: RR (Phase 3), one-line deliverable —** add a `why-note:` line to that `claim.txt` naming
`test/dict_fixtures/b1-p4-super-slot-*` and `b1-xmod-default-*` as fixtures whose covered shape
widens when this drains, and mirror it as a comment on #1457. Two properties make this the cheapest
firing mechanism available (both DERIVED): `why-note:` is an **existing repeated key** in that
file, so it adds no parse surface; and the fixture's line-sensitive pin is on **`sm.mdk`**, not
`claim.txt`, so an added line moves nothing. **If RR declines, it must be FILED as an issue —
"unowned" is not an allowed outcome.**

### O-4 — the **"15 reading sites"** claim — ⏳ **STILL OWED**

It is *"the entire justification for refusing the design of record"* (RUN-P3-036, R-2), and the
supporting table lives in an agent report that **does not ship with the PR**. Verified still owed,
DERIVED (`grep -rn '15 read' .claude/sprint-phase3/`): three hits — `DECISIONS.md:745` asserts it,
`:1378` flags it unverifiable, and `packets/A-packet.md:23` **repeats the count without
enumerating**. **No enumeration exists in any shipping artifact.**

**Owner: ORCH, before the PR body is written.** Two acceptable discharges:
1. paste the enumeration into RUN-P3-019 **with the command that reproduces it**; or
2. **delete the claim** and rest the refusal on RUN-P3-019's other two derivations, which are
   independently checkable — the cross-stage import-edge closure (`eval.mdk` and `core_ir_lower.mdk`
   cannot reach `typecheck.mdk`, so D1's mint siting would have made a **third** mirrored copy),
   and the tree's own ruling at `keyForSite` / `ieCountHeadByIface` (*"the question is inherently
   SPELLING-scoped… answering it with identities is wrong at ANY supply level"*).

**Not acceptable: the number `15` appearing in the PR body or the #1113 close-out unsourced.**

### O-5 — the **third `headTyconTy` asymmetry** (`TyConstrained`) — ⏳ **STILL OWED**

**Verified and now DERIVED first-hand** (at `d5948e3a`, `git show`):

```
compiler/eval/eval.mdk:546   headTycon (TyConstrained _ t) = headTycon t     ← strips
compiler/eval/eval.mdk:547   headTycon (TyEffect _ _ t)    = headTycon t     ← strips
compiler/types/typecheck.mdk:19383-19385  headTyNode (TyApp a _) = …; headTyNode t = t   ← strips NEITHER
compiler/types/typecheck.mdk:19402-19406  headTyconTy … _ => None
```

So the `_ => None` arm swallows **`TyFun` (F-2), `TyEffect` (F-8) and `TyConstrained` (unfiled)** —
the known set is **three, not two**. RUN-P3-037 states it and adds *"I wrote 'audit the arms as a
SET' and then shipped a set one arm short."*

**Owner: FILE.** F-2 and F-8 file separately (different fixes), and **each body must name the
`TyConstrained` arm as the third member**, with the instruction that the fix audits the arm as a
SET rather than patching an instance. **Filing two of three is refused.**

### O-6 — **#1068** and the wasm arm — ⏳ **STILL OWED**

#1113's blast list says #1068's fix *"would build in wasm the superset arm this task deletes; **do
them together**"* — and RUN-P3-003 independently re-derived wasm's separate uniqueness family
(`headTagUniqueW`, `distinctKeysAtHeadW`, `headTagForKeyW`, `methodImplKey`, `findByTagW`, with
**zero hits** for `ifaceImplRouteKeys`/`ifaceDeclHeadUnique`) **without citing #1068**.

🚨 **Verified still owed, and the window to discharge it cheaply has CLOSED.** The `b1`+`e`
`engines:` clause is now **written and committed** (`ec1cda37`) — it names the owed peers
(`llvm_emit.implEntryRouteKey` / `implEntryRouteWords` / `headTagUnique` / `distinctKeysAtHead`,
wasm's independent family, `core_ir_lower.distinctKeysAtHeadL`) and **does not cite #1068**.
DERIVED: `grep -c '1068' .claude/sprint-phase3/DEBT.md` → **0**.

**Owner: ORCH, at the close-out** (the implementer's window is gone). Discharge by **either**
appending an erratum row to `DEBT.md` citing #1068 against `e`'s `engines:` clause, **or** carrying
it explicitly in the PR body and the #1113 close-out. Standing arc risk to relay with it
(RUN-P3-003): if wasm truly has no consumer of the shared table, wasm's method-less-impl
default-dispatch coverage rests entirely on a separately-maintained parallel family — an
`evalModules`/`cevalModules`-class lockstep hazard — and #1113's blast list says the two must be
done **together**.

### Also unowned, found by sweeping the ledger — assigned here rather than left blank

| item | where | owner |
|---|---|---|
| the deferred **`keyTable`/`KeyBuckets` deletion** — *"filed as a named follow-up"*, **no issue number anywhere in the ledger**. It must carry P0-1's derivation **and** the `stampKeyTable` correction (true residue **99 lines across 2 binders**, not 91), or Phase 5 sizes it off the wrong count | RUN-P3-007 | **FILE** |
| the **`b2` drop** — *"filed as a follow-up carrying the D4 `iface == ""` finding"*, **no issue number**. Without it Phase 5 re-plans `b2` off D1's stale ✅ | RUN-P3-032 | **FILE** |
| **#1180** — a known-wrong `noneHeadTag` bucket sitting **under `b1`'s preserved fallback arm**; R-4 says it *"belongs in `DEBT.md`"* and no row carries it | RUN-P3-037 | **IMPL (`b1` row)** |
| **#1127**'s `assum`-vs-`super` control — *"adopt rather than author fresh"*; relayed, adoption unconfirmed | RUN-P3-037 | **RR** |
| the **`opBump` perf run** owed by `f`'s read side | RUN-P3-036 (R-1) | **RR** (§2 A11) |
| **`c` has not landed** — it owns all three stale-comment corrections, including the one whose absence *"nearly shipped a break"* | RUN-P3-033 | **IMPL (`c`)** |
| the **F-6 / `sanitizeId` fixture** — `e`'s own `nearest miss:` states the hazard (path ids `a.b`/`a/b`/`a-b` collapsing, plus the independent `hashName` djb2 channel) but **no fixture was landed** asserting distinct emitted symbols | `DEBT.md` `b1`+`e` `nearest miss:` | **RR** (§2 A7) |
| **not run by any bite: perf/scaling, the wasm gates, `diff_compiler_selfproc`** (`unchecked:` (8)) | `DEBT.md` `b1`+`e` | **ORCH** (§1 steps 4–5) / **RR** (perf, wasm) |
| **`DEBT.md`'s `a` row is factually wrong on one line** — `unchecked:` (4) says `rule-duplicate-body` is *"RED and deliberately left un-silenced"* while the directive is committed at `route_key.mdk:230`; and `b1`+`e`'s `unchecked:` (7) **refuses** `a`'s instruction to retire it (measured: with it removed, `lint --deny=rule-duplicate-body` exits 1 naming two files). The file is append-only ⇒ discharge with an appended **erratum**, not an edit | R-2 (RUN-P3-036); `DEBT.md` `b1`+`e` (7) | **ORCH** |

**Every item above has an owner. Nothing in this sweep is unassigned.**

---

# 5. What must NOT go in the PR body

Claims the audit found **wrong or unsupported**. They are listed here so they cannot be quoted by
accident out of a `#`-level heading or a commit message.

1. 🚨 **"This fixes #1182" / any #1182 framing.** The substitution does **NOT** fix it. #1182's
   selection runs on `contains name ms` — **method-name membership plus head match, no interface
   component** — and the word is minted *downstream of the already-selected row*; in #1182's own
   repro **the word does not even move**. Adjudicated **three times independently, all against the
   earlier framing** (R-2 source-side, R-4 tracker-side, the implementer in-tree), corrected in
   **nine** places. What the substitution serves is the **#1047 family** — and #1047 is **CLOSED**,
   so that means its live members: **#1265**, **#1514**, and the bare-compat leg of `oblIfaceKeys`.
   **Citable ticket: #1113.** (RUN-P3-003 correction, RUN-P3-035, RUN-P3-036, RUN-P3-037.)
   **Now measured, not only derived:** the landed row records **#1182's pin still reproducing**
   (`run` → 1, control → 2), and its repro is a single file — absent origin, bare-name fallback,
   *"the word does not even move."* **What the sprint may claim instead is #1514's drain** (§1 step
   6), which is the same-spelled-interface family and is hand-derived, not captured.
2. 🚨 **"byte-identical IR on programs with no head collision."** **FALSE.** The defensible form is
   *"…no head collision **and no two same-spelled interfaces in the module graph**"* — because
   `ifaceDeclHeadUnique` → `declKeysAtHead` dedups by canonical key, so the collision **verdict**
   changes (RUN-P3-026). **A green `diff_compiler_llvm` may not be read as the wider claim.**
3. 🚨 **Anything sourced from the Phase 0 gate table (RUN-P3-018). ALL SIX ROWS ARE STALE** —
   superseded by RUN-P3-019 (`a`), -023 (`f`), -025 (`b1`), -027 (`e`), -032 (`b2` DROPPED), -033
   (`c`). It is the most consultable thing in the ledger (a `#` heading reading **"GO"**), which is
   exactly why it is the most likely thing to be quoted.
4. 🚨 **#1113's own drain list.** *"Drains #1072/#1071/#1062"* is two-thirds spent: **#1072 and
   #1071 are CLOSED**, drained by **Stage B**, not by B-2 (#1071 as a duplicate of #1062). **B-2's
   remaining drain claim is #1062 alone — and #1062 is EVAL-ONLY**, which nothing in B-2.2's
   route-word half touches. **Do not cite #1062 as drained by this sprint** (RUN-P3-037).
5. **"The route selectors now all read one graph-global population."** **FALSE at this pin** —
   `ImplBuckets`/`implTable` rides the same parameter positions and **does** decide, by a different
   rule over a different population. Binding on `DEBT.md` rows, commit messages, the PR body and
   the #1113 close-out (RUN-P3-008, restated as `FINDINGS.md` F-5).
6. **`f`'s fixpoint waiver, and the "typed IR byte-unchanged" claim as a whole-diff statement.**
   The gates behind it run **54 single-file, prelude-free fixtures** — ~1 of 6 changed regions
   (R-1, RUN-P3-036). The waiver does not survive; the narrow claim must be scoped to the corpus
   that produced it.
7. **The retracted `sanitizeId` example.** File the **path** example (`a.b` / `a/b` / `a-b` →
   `a_b__Alpha_T_`) — **never** the `a_` + `_Alpha` one, which was **refuted** (`safeChar` maps each
   offending char to a *single* `_`, giving four underscores). Shipping it would ship a repro that
   does not reproduce (RUN-P3-030, `FINDINGS.md` F-6 filing note).
8. **`HANDOFF.md:10`'s *"This unit changes `RKey`'s payload type"*.** Stale since RUN-P3-019:
   **`data Route` is unchanged and `RKey`'s first field stays `String`.** Quoting the handoff's
   framing into the PR body imports a superseded fact from a doc that still reads as current.
9. **Any count without its command.** Measured wrong in this sprint alone: `DEBT.md`'s *"374
   lines"* (is **396**); *"`fromOption` 99 **uses**"* (99 *lines*, **78** occurrences — the design
   argument survives either); the doc's *"86 / 91"* `KeyBuckets`/`keyTable` residue (true residue
   **99 lines across 2 binders**, the second being `stampKeyTable`); *"nine probe drivers"* (**7**);
   *"`CProgram` constructed at exactly ONE site"* (**13**). Write the command, not the number.
10. **"CI green" as corroboration for a specific gate's numbers.** A green rollup is not proof that
    a cited gate ran with the cited result — `pull_request` runs are **narrowed** and a shard can go
    green in seconds having run nothing. Verify per-shard step conclusions, or cite the
    `merge_group` run (`AGENTS.md`).
