---
name: medaka-verification-scope
description: Selects a proportional Medaka local verification set and defers redundant breadth to CI. Use before choosing or running tests for compiler, stdlib, runtime, harness, or documentation changes.
---

# Medaka Verification Scope

Use local verification to answer concrete pre-push questions, not to serially replay CI on a shared machine. The merge queue's full `merge_group` run is authoritative, but CI is not a substitute for the local evidence needed to know what the change should do.

Repository instructions remain authoritative. This skill never waives an `AGENTS.md` requirement such as targeted format/lint, an actual graded regression gate, compiler-source typechecking, snapshot or selfproc obligations, or a locally required backend fixpoint.

## 1. State the questions before commands

Write a short verification packet:

- changed paths and semantic blast radius;
- the regression or acceptance property that could fail;
- mandatory local obligations derived from `AGENTS.md` and touched representations;
- the cheapest command able to falsify each property;
- prerequisites or oracles shared by those commands;
- broad checks deliberately deferred to PR or merge-queue CI;
- what new evidence would widen local scope.

Do not run a command merely because it is customary. Every local command must answer one of those questions.

## 2. Run locally when there is a local reason

Local execution is justified when at least one condition holds:

1. **Discriminator:** it proves the reported defect before the fix, distinguishes the planned mechanism, or mutation-tests a new regression check.
2. **Fast feedback:** it cheaply catches a likely syntax, type, formatting, lint, shell, documentation, or focused-output error before a CI round trip.
3. **Artifact adjudication:** its snapshot, selfproc scheme, or other generated diff must be independently justified, inspected, and committed in this PR.
4. **Unique route:** CI cannot establish the needed provenance, same-process isolation, determinism, local platform behavior, or exact engine/path consequence.
5. **Repository mandate:** current instructions explicitly require the local check for this path or risk class. Backend fixpoint and any other named mandatory checks are not optional because they are expensive.
6. **Review unblocker:** a focused result resolves a concrete designer or reviewer uncertainty before push.

Prefer the cheapest fail-capable command. A passing command that could not fail for this change is not signal.

## 3. Defer breadth when CI is the better executor

After adequate local signal, defer a check when all of these are true:

- it is a broad regression net rather than the direct acceptance test;
- no output or golden from it is expected to move or needs local adjudication;
- it repeats semantics already established by a focused local check;
- it has no special local-only provenance requirement;
- current repository instructions do not require it locally; and
- PR or merge-queue CI will actually schedule it.

Typical deferrals are unrelated shards, a full engine corpus after a focused cross-engine discriminator, the full suite on a blast-radius path, and expensive performance breadth when the diff makes no performance claim and the targeted scaling invariant is already covered.

Do not build an oracle solely for a check already deferred to CI. Do not turn a fresh worktree into a broad oracle build by reversing `--for --list` arguments.

## 4. Use a cost ladder

Run in this order and stop when the questions are answered:

1. static inspection, targeted format/lint, `sh -n`, documentation gates, or MCP checks;
2. one fast compile/typecheck or direct reproduction/control;
3. the focused regression gate with only its narrow prerequisites;
4. mandatory compiler-source, snapshot, selfproc, or fixpoint obligations;
5. additional expensive local suites only when a named uncertainty survives.

Use `PREFLIGHT_DRY=1 sh test/preflight.sh` to derive candidate gates, not as an instruction to run all of them. Remember that dry mode does not reveal the forced backend fixpoint, and blast-radius paths can turn preflight into the prohibited full local suite. Prefer targeted `run_gates.sh` patterns or let CI parallelize genuine breadth.

Documentation checks are complementary. If a Markdown `**Status:**` banner
changes, run `make docs-index`, inspect and stage the generated
`docs/README.md`, then run `make docs-links` and `make agent-doc-symbols` as
applicable. Links and symbol checks do not prove that the generated index is
fresh; finish by requiring no regeneration diff in `docs/README.md`.

Keep prose-only edits to existing diagnostic-bearing fixtures line-count-neutral
where possible and record `git diff --numstat`. If line count changes, enumerate
the fixture's consumers and independently justify every moved location/golden.

For a long mandatory check, background and poll it as repository guidance requires; do not replace it with several redundant foreground checks.

Treat cold compiler/oracle construction as a shared prerequisite when allocating
verifier worktrees. Prefer one daughter and one build for several bounded groups
when the combined commands fit its turn. Split into parallel daughters only when
the wall-clock gain justifies duplicate cold builds and shared-box load; each
brief must name the sibling-owned checks so neither agent reports them as gaps.

## 5. Push once local signal is adequate

Do not wait for broad local duplication before opening the PR. Push after the direct acceptance property, cheap source hygiene, and mandatory local obligations are green. Let narrowed PR CI and independent review run concurrently; let merge-queue CI grade the full integrated tree.

A green PR check is not proof that a narrowed shard executed a cited gate. Verify job steps when making a claim about a specific CI result. Record the merge-group run as the final authority.

## 6. Receipt format

For every selected check record:

- command and reason;
- prerequisites and freshness;
- actual grade versus skip or phantom skip;
- decisive output;
- duration when material.

For every deferred check record:

- exact check or family;
- why local execution would be redundant;
- which CI event is expected to grade it;
- whether the PR event may narrow it away;
- the condition that would bring it back local.

Never summarize a phantom skip as green, a narrowed-away PR shard as coverage, or captured output as semantic authority.

Snapshot summary labels are not artifact disposition. A focused gate may
intentionally create a temporary one-shot snapshot and report `new` while
passing with a clean tracked tree. First derive whether the gate owns a tracked
corpus path or temporary storage. If a required tracked artifact is absent, run
that gate's `--new` and require the resulting tracked status change; if the gate
explicitly uses temporary storage, a passing result and clean tracked tree owe
no golden. For a large generated snapshot, report layered section-to-source
adjudication and any uninspected remainder instead of claiming exhaustive review.

Receipts are revision-scoped. A later delta may inherit one only when every
intervening path is audited and cannot affect the property; record both SHAs,
the paths, the rationale, and delta-specific checks. Do not rerun expensive
compiler checks after a prose-only delta merely to change the receipt SHA.
