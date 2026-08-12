---
name: medaka-continuation-receipt
description: Builds compact derived packets for staged Medaka compiler continuation work. Use when handing one epic slice across design, implementation, verification, review, PR prose, and tracker handoff without repeating history or encoding stale counts.
---

# Medaka Continuation Receipt

Use one task-owned scratch receipt as the compact state carrier for an already
established compiler epic. This is a template, not a new architecture authority.
Derive every set, count, SHA, issue state, and result from current source, Git,
GitHub, or an exact command receipt; never copy a prior handoff's number forward.

## 1. Admission

Record direct command output captured immediately before dispatch:

- absolute worktree path and owner;
- pinned base and exact HEAD;
- branch or detached state;
- empty porcelain status;
- daughter/parent path distinction when applicable.

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

Store the receipt under a unique task scratch path, provide its SHA-256 to the
reviewer, never commit it, and delete it during wrap-up.
