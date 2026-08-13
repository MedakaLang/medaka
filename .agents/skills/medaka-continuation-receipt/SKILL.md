---
name: medaka-continuation-receipt
description: Builds compact derived packets for staged Medaka compiler continuation work. Use when handing one epic slice across design, implementation, verification, review, PR prose, and tracker handoff without repeating history or encoding stale counts.
---

# Medaka Continuation Receipt

Use a task-owned scratch receipt as a disposable, revision-and-phase-scoped
projection of the conductor's authoritative conversation ledger for an already
established compiler epic. It is a template, never a state carrier or a new
architecture/workflow authority. Generate it immediately before one named use;
never use it to update the ledger. Derive every set, count, SHA, issue state, and
result from the current ledger plus source, Git, GitHub, or an exact command
receipt; never copy a prior handoff's number forward.

## 1. Admission

Record commands and their actual direct output captured immediately before
dispatch:

- parent and daughter absolute worktree paths and owners where applicable;
- pinned base and exact HEAD for each relevant worktree;
- branch or detached state for each relevant worktree;
- empty porcelain status;
- explicit no-shared-worktree and no-shared-branch conclusion.

Agents without Git tools accept this receipt rather than spending a turn asking
the conductor to repeat it.

## 2. Continuation delta

Keep only:

- selected milestone and latest decisive tracker/history/source evidence;
- completed carriers that the slice must not duplicate;
- normalized live authority or residual set, with its derivation command/method;
- candidate families and the reason the selected family is the smallest coherent
  boundary;
- exact files, symbols, callers, mirrors, and authorized paths;
- invariant, acceptance criteria, route classification, and unresolved premise.

Do not restate the epic, full issue history, or unchanged formal architecture.

## 3. Apparatus and mutation

For each semantic field record P, U, private reader, controlled artifact/failure,
and whether each route is rendering, event-only, or aborting. Separate data
correctness from ownership correctness. A discarded result is not observable.
Name the finite reviewed mutation rows and earliest stable expected-red rule;
state the claim each row proves.

## 4. Verification and inheritance

Record exact commands, prerequisites, actual grades, artifacts adjudicated,
deferred CI breadth, and no-skip status. For receipt inheritance, name:

- fully verified SHA;
- final head SHA;
- every intervening path;
- why those paths cannot affect each inherited property;
- delta-specific checks actually run.

## 5. Final projections

Generate concise, consistent subsets from the same receipt:

- implementer brief: edit boundary and invariant;
- reviewer brief: exact-head evidence and unresolved risks;
- PR body: outcome, semantics, verification, deferrals, inheritance;
- tracker handoff: landed carrier, authoritative merge-group run, residual set,
  and next bounded derivation question.

Before each projection, compare the receipt's revision and phase with the
conversation ledger. After any rebase, repair, plan delta, implementation
revision, verification revision, review finding, or tracker-state change,
discard and regenerate the mutable projection. A valid SHA-256 proves only byte
integrity, never freshness. Keep immutable command/verifier receipts separate so
they can inherit only under the explicit revision rules.

Store the receipt under a unique task scratch path, provide its SHA-256 to the
reviewer, never commit it, and delete it during wrap-up.
