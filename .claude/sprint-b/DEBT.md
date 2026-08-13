# Stage B sprint — DEBT.md

**Append-only, one row per bite.** The sub-orchestrator is the single writer of history;
implementers hand back a row and the sub-orchestrator commits it with the bite.

> ⚠️ **This run trades verification latency for implementation throughput. That trade is only
> safe because the debt is WRITTEN DOWN.** An agent that skips a row has not saved time — it has
> converted a deferred check into **a check nobody will ever know to make.**

## Row format (contract §4)

```
### <bite id> — <unit> — <one-line description>
sites:        <the files:lines actually touched>
transform:    <what was applied>
could move:   <what acceptance behavior could plausibly have changed, incl. "nothing — pure rename">
nearest miss: <the nearest program this does NOT cover, and what it does today>
engines:      <LLVM / wasm / eval — which arms this bite moved, and which peers it owes>
unchecked:    <what I did not verify, and why>
```

**`could move:` and `nearest miss:` may not be left blank.** *"Nothing, and here is why"* is
valid; **silence is not.** The referee bounces any row missing `could move:`, `nearest miss:` or
`engines:`.

Why each field exists — these are earned, not ceremonial:

- **`could move:`** is what the repair round reads. It cost nothing in Stage A and produced the
  attack list that found 2 S0 regressions, an architectural contradiction, and a pre-existing S0.
- **`nearest miss:`** — *state and TEST the nearest program your fix does NOT cover.* Stage A's
  repair round exists because that went unasked and **an S0 survived one added type signature.**
  Once mandatory it found a live S0 on the first try (#1599). A fix verified only against its own
  repro is verified against the **bug report**, not the defect.
- **`engines:`** is specific to this stage. B-2 moves dispatch in **three** engines. A bite that
  lands the LLVM arm without naming its wasm and eval peers has created a divergence that
  `diff_compiler_engines` — deferred to the repair round — **will not see until then.**

## Standing hazards for every row in this ledger

- **The gate suite is structurally blind to this run's characteristic failures:** value goldens
  cannot see a diagnostic-only change; absence probes cannot see an undercount; **eval agreement
  proves nothing on a dispatch shape.** Do not offer any of those three as verification.
- **eval is a known-wrong oracle on exactly the shapes this stage moves** (#1071, #1062 are
  eval-only S0s on the drain list). Deriving expected behaviour from what eval prints **enshrines
  the bug.** Work the answer out from the DICT spec first.
- **Zero goldens are blessed for the entire run.** They are re-cut **once**, from the final
  binary, never merged and never hand-resolved.

---

*(Bite rows are appended below, in landing order.)*
