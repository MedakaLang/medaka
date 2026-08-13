# GitHub run protocol

Use stage issue as durable sprint ledger. Prefer comments over tracked process files. Use one compact comment per lifecycle event; edit/update when practical.

## Admission comment

Record base SHA, stage claim, scope/non-goals, fixed semantics, slice DAG, tentative disjointness, verification strategy, repair-round budget, and PR link.

## Slice admission/checkpoint comment

Record slice ID, packet summary or link, writer branch/base, collision proof, dispatch/first-edit/completion/integration times, integrated SHA, minimum check, `could move`, nearest miss, CI checkpoint, and deferred debt.

## Finding/debt update

Record exact SHA, severity, evidence, affected slice/premise, disposition (`fix-now`, `repair`, `defer-out`, `false`, `pre-existing`), owner, and invalidated packets. Never call finding pre-existing without measuring base.

## Final comment

Record stage acceptance results, throughput metrics, repair verdict, local and CI receipts, residual authorities/debt, PR head, and explicit state: `AWAITING OWNER ENQUEUE APPROVAL`.

GitHub writes require readback verification. Tracker prose is claim until source/history/evidence confirms it.
