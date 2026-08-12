# Stage A sprint — DECISIONS ledger

**Append-only.** Architecture companions and the Phase 0 fan-out write here; every agent reads
here **before** asking anyone anything.

**Every entry carries its derivation, not just its conclusion.** An entry that states a fact
without showing how it was derived (a command run, a file:line read, a probe executed) gets
bounced by the referee. This tree has a long history of ledger prose that was ungated and wrong.

Entry format:

```
## <id> — <unit> — <one-line ruling>
question:   <what was asked>
ruling:     <the decision>
derivation: <the command(s) run / file:line read / probe executed that establish it>
scope:      <what this ruling does and does not cover>
```

---

## RUN-000 — sprint setup — scope re-derived from the tracker, 2026-08-12

question:   Is §1's in-scope table still accurate? The doc says issue state moves — re-derive.
ruling:     Every in-scope node is still live. Scope stands as written, no amendment.
derivation: `gh issue list --state all --limit 200 --json number,state,title` plus individual
            `gh issue view` for #991/#1111/#1112. Observed states:
            OPEN — #1512, #1593, #1557, #1558, #1559, #1354, #1276, #1351, #1319, #991,
                   #1111, #1112.
            CLOSED — #1446 (A-2 tail atom), consistent with §1's "A-2's spine is already done".
            #1110 did not appear in the 200-issue window; #1111/#1112 confirmed OPEN as shells.
scope:      Confirms node liveness only. Does NOT confirm #991's *content* is still live work
            (§1 flags it as "bundled with #1446, which closed without it") — that is a Phase 0
            deliverable, not established here.

## RUN-001 — sprint setup — sole occupancy confirmed

question:   Is any other session or scheduled agent pointed at this tree?
ruling:     No. Sole occupancy holds; §7's precondition for Phase 0 is met.
derivation: `git worktree list` → exactly 2 (main checkout + this trunk, both at 7aae8b83).
            `ListAgents` → 2 peer sessions, both Remote Control, one offline one idle, neither
            in this repo. `ps -eo pid,etime,args` → one `claude -w`, no `make`/`medaka`/gate
            processes.
scope:      Point-in-time. Re-check before any later phase that assumes exclusive access to
            `compiler/types/typecheck.mdk`.

## RUN-002 — sprint setup — trunk identity

question:   What is the trunk, and what base does everything diff against?
ruling:     Worktree `/root/medaka/.claude/worktrees/wiggly-giggling-nygaard`, branch
            `arch/stage-a-sprint`, BASE pinned at `7aae8b83e8b2f7aeef1132b7af0c8b4db784f3f1`.
derivation: `git checkout -b arch/stage-a-sprint`; `git rev-parse HEAD`. Base is pinned as a
            SHA, not as `origin/main` — all worktrees share one `.git`, so a sibling's fetch
            moves `origin/main` under us with no signal.
scope:      All implementers edit in this worktree with absolute paths. No per-implementer
            worktrees exist; none will be created (§4 region discipline).

## RUN-003 — sprint-wide — 🚨 THE TRACKER LAGS THE TREE; Phase 0 re-shaped around it

question:   §1 says "derive from the tracker, not from the epic's table." Is the tracker itself
            a sound basis for the scope table?
ruling:     **No.** The merged tree has moved substantially past issue state, in this arc, within
            the last 48 hours. Every Phase 0 brief was amended to make "derive your unit's ACTUAL
            residue FROM THE TREE" step 1, with "already done" declared a first-class finding.
            `test/registry_keying_ratchet.sh` is designated the primary tree-side ledger.
derivation: `gh pr list --state merged --limit 25 --json number,title,mergedAt`. Merged
            2026-08-11/12, all in this arc:
              #1553 "A-3.2b: retire the overlay pool onto stage K — the first cross_allowed
                     shrink (issue 1512, part of issue 1319 unit 4)"
              #1567 "#1112 A-3.4 PR2: the IE reader flip — cross_allowed 31 → 28"
              #1588 "retire universeAliasTable onto stage K (#1512 A-3.2b residual 1/3)"
              #1590 "A-3.2b slices 2+3 — retire universeDataParamKinds + universeFieldOwners (#1512)"
              #1592 "A-3.5c — CE-only decl-time checks relocated, retires universeIfaceParamKinds
                     (#1557)"
            Decisive instance: **#1592 landed work for #1557 while #1557 is still OPEN** — so
            issue state cannot distinguish "owed" from "landed" here. Corroborated by
            `test/registry_keying_ratchet.sh`'s `declEnvsRef` row, which states in the tree
            itself: *"A-3.5a (universeIfaceRequiredRef) and A-3.5b remain owed"* and
            *"LIVE SINCE A-3.4 PR2"* — neither fact is recoverable from the issues.
scope:      Changes HOW scope is derived, not (yet) what the scope IS. Concrete re-scoping is a
            Phase 0 deliverable, pending the fan-out. Two candidate collapses are flagged to
            agents as questions, NOT asserted here: (a) #1512's remaining work may now live
            entirely in #1593; (b) A-3.4 may be complete via #1510 + #1567.
            ⚠️ This ruling does NOT license trusting the ratchet either — see RUN-004.

## RUN-004 — sprint-wide — the tree-side ledger is UNGATED PROSE and has already lied

question:   If the ratchet is the primary ledger, how far can it be trusted?
ruling:     Cite it, never trust it. **Every symbol named from it must be grepped before use.**
            This instruction is in all seven Phase 0 briefs; it carries into every implementer
            brief for the rest of the run.
derivation: The `declEnvsRef` row of `test/registry_keying_ratchet.sh` contains a block addressed
            to "A-3.6 IMPLEMENTER" stating that an earlier draft of that same row named
            `declEnvSeedRows` and an own-row test `m.demOrd == cur`, and that **both were
            fabrications** — neither exists in the tree. The row also derives WHY nothing caught
            it: `check_agent_doc_symbols.sh` scans `AGENTS.md`, `.claude/**` and `docs/spec/*.md`
            but **not `test/*.sh`**, so the file this arc hands off through is exactly the one its
            symbol police cannot see. Filed as #1574; do not re-file.
scope:      P0-F is tasked with grepping every symbol the `declEnvsRef` and `deImpls` rows name
            and reporting the non-existent ones, as a direct contribution to #1574.
            P0-C (A-3.6) was warned explicitly that its unit is where the fabrications occurred.
