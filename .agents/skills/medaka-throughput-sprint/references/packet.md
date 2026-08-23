# v8 slice packet and report

Write a packet just in time at
`/var/tmp/medaka-sprints/<stage>/packets/<slice-id>.md`. Target 80 lines and
never exceed 120. It should let a writer start coding without rediscovering
the stage.

## Required sections, in order

1. **Identity** — descriptive slice ID, issues with names, exact sprint base
   SHA, target writer branch/worktree, and report path.
2. **Setup** — the transport-approved sync/build commands. See
   [transport.md](transport.md); do not assume a harness-minted worktree.
3. **Mission** — desired transformation, observable result, and whether it is
   parity or behavior-changing.
4. **Already settled** — contract facts the writer must trust, each with its
   proof command. Everything else the writer relies upon needs first-hand
   confirmation.
5. **Sites** — best-effort complete files/functions and known mirrors. A
   missing same-question site is a refusal, not silent scope expansion.
6. **Acceptance** — exactly 3–5 checks, with expected results. One check is
   always a green build of the exact post-edit revision (normally `make
   medaka` in the named writer tree); the report records that revision/SHA.
   The remaining checks cover formatted and linted touched Medaka files, a
   strict primary probe, and the one focused gate/snapshot whose result the
   slice moves. List each golden path the writer may bless. Unlisted goldens
   are findings, never blessing authority.

§6 is a ceiling as well as a floor. Broader gates, property testing, and CI
belong to the whole-diff review and merge queue unless the packet names them.
State expected values from the semantics before capturing output.

## Refusal and spike rule

When source contact contradicts the packet — false premise, missing sibling,
or incompatible transform — stop coding and obtain the smallest discriminating
measurement. Report `REFUSED`; a measured refusal is useful work. Do not
silently implement either personal theory or stale instructions. Mid-task
messages cannot amend an immutable packet; decline and note them.

A spike produces knowledge, not code. Attempt only what is necessary, revert
its changes, prove the tree is clean, report the discovered sites/prerequisite
order, and use `SPIKE-DONE`.

## Writer report

Writers update the packet's report incrementally. First line is exactly one
of `LANDED @<sha>`, `REFUSED`, `BLOCKED`, or `SPIKE-DONE`, followed by:

- **Evidence** — worktree/base proof and actual output for every §6 check, or
  the refusal's discriminating measurement.
- **Notes** — findings, deviations, declined messages, or `NONE`.

The return message is only the verdict and report path. A reviewer or retro
without write permission returns the same content to the conductor, which
persists it at the named path verbatim.
