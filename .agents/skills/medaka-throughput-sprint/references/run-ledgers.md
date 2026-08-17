# Run ledgers and rulings

Create `/var/tmp/medaka-sprints/<stage>/` with `packets/`, `reports/`, `rulings/`, `receipts/`, `DECISIONS.md`, `OBLIGATIONS.md`, `FINDINGS.md`, and `FRICTION.md`.

## Judgment seat

Every consult names question, triggering escalation rule, primary artifact paths, and next reserved `RUN-<stage>-NNN`. Brain reads artifacts, verifies one load-bearing fact with independent instrument, then writes one self-contained file per decision: `rulings/RUN-<stage>-NNN.md`. First line must be `## RUN-<stage>-NNN (<slug>)`.

Ruling contains: `Ruling`, `Derivation`, `Actions`, `Escalate`. Code-changing action separates binding `property`, advisory `mechanism`, and fail-capable `acceptance`. One decision per number; multi-decision response reserves contiguous numbers and lists them.

Conductor checks numbering/files, concatenates each file verbatim into `DECISIONS.md`, and adds each action as terminally checkable `OBLIGATIONS.md` row. Confirm scribing by number with next already-needed brain message. Missing/gapped ruling → re-request by number; never summarize or dedupe.

Escalate user decisions that change accepted programs, formal semantics, standing sprint contract, or settled prior ruling. Brain may re-cut sequencing and scope within contract. Conflicting first-hand reports require third discriminating probe.

Record each user decision as `VAL-<stage>-NNN (<slug>)` with five nonblank fields: `decision` verbatim, binding `scope`, durable in-repo `destination`, executing `owner`, and readback `executed`. Track destination as obligation; record directory alone is invalid. Then send brain one invalidation consult naming block: which landed/in-flight settled premises it falsifies and which lanes require re-cut.

## Mechanics

Derive next ruling number from headings, not mentions. At phase boundaries and pre-enqueue, compare allocated consult numbers, ruling files, decision headings, and obligation rows. Sprint cannot exit with missing ruling, open obligation, open finding, or unadjudicated refusal.

Mid-flight agent messages: `fact:` advisory derived fact or `stop:` abort only. Log declined amendments verbatim in decision ledger and refusal table.
