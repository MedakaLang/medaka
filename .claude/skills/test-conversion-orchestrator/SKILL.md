---
name: test-conversion-orchestrator
description: Run a wave of shell-gate → native-test conversions (`native-wrap`/`native-rewrite` rows of test/gates.toml) with Haiku workers (`test-converter`, `conversion-auditor`), each under the 100k-token pricing tier, without reading their output into your own context. For the orchestrating session (Sonnet+). Selection, sizing, packets, dispatch, token ledger, verification, registry bookkeeping, PR, review.
---

# Orchestrate a test-conversion wave (epic #2600)

Your context is the costliest in the wave: re-sent on every call. So you read only
workers' short final messages and the verifier's verdict lines, never test files,
full reports or transcripts. Haiku auditors do the reading. Only you run anything
wider than one file, edit registry/CI/docs/`compiler/`/`stdlib/`, delete scripts, commit.

| Role | Agent type | Job |
|---|---|---|
| Orchestrator | you (Sonnet+) | select, size, packet, verify, bookkeeping, PR |
| Converter | `test-converter` (Haiku) | one script/section → one `_test.mdk`; FIX packets |
| Auditor | `conversion-auditor` (Haiku) | per-file check map, vacuity scan, mutation proofs; RECHECK |
| Reviewer | `sprint-reviewer` (Sonnet) | once per PR |

Haiku roles: omitClaudeMd, 4 tools, preloaded `convert-shell-gate` → **~11.5k
startup** (`general-purpose` was ~40k: never dispatch conversions as it). Agent
types missing → session predates `.claude/agents/` entries; restart.

Measured 2026-10-08 (6 native-rewrite gates; default effort): converter peak 41–50k on
113–142-line scripts, 93–125k on 207–367 lines; auditor 30–63k; fixer 17–33k. Wave 1
(general-purpose, old skill) was 61–187k. Converter `effort: low` (the default in its
agent file) cut the 367-line case 123k → 72k at equal audit findings, but it skipped
reading lint output; the verifier catches that. If audits of low-effort conversions keep
finding ≥3 real defects per file, set `effort: medium` in `.claude/agents/test-converter.md`.
A headless Sonnet orchestrator ran a wave unattended (2 gates converted, 6 booked) for $1.52
total, its own context peaking at 96k.

## 0. Setup
```sh
git rev-parse HEAD                  # pin BASE
make -C <abs worktree> medaka       # once; workers never build
gh issue list --label known-red
```
Scratch under your scratchpad. Ledger file there: `gate | packet | agentId | tokens | calls | verdict`.

## 1. Select
```sh
python3 - <abs worktree>/test/gates.toml <<'EOF'
import re, sys
for b in open(sys.argv[1]).read().split('[[gate]]')[1:]:
    g = lambda k: (re.search(k + r' = "([^"]*)"', b) or [0, ''])[1]
    if g('migration') in ('native-wrap', 'native-rewrite'):
        print(g('shard'), g('name'), g('run'), re.search(r'toolchain = (\[.*\])', b)[1], re.search(r'oracles = (\[.*\])', b)[1])
EOF
```
First: a gates_N shard, no `node`/`wasm-tools`. Hold back: `other-job` (a workflow
step runs the script, often in a job without `medaka`; decide the CI move before
dispatch); non-empty `oracles` (probe retirement, #2594); `blocked:*`, `shell:*`,
`inverted-polarity` (never). A script with its own `--write`/`CAPTURE` mode that docs
tell humans to run: converting deletes that mode; keep the writer or skip.

## 2. Size (100k rule)
Cost ≈ 11.5k + script read once + file written + iterations + **thinking** (the biggest
term on hard logic: 54k of catch_all_census's 125k). Size by script lines PLUS the lines
of any helper it runs whose logic must be ported (`.py`, sourced `.sh`): catch_all_census
= 123 + 244 → 125k; perf_stage_census = 207 (inline python) → 93k.

| Script | Packet |
|---|---|
| ≤60 lines, shared corpus | batch 2–3 into one file, a `test` block each |
| ≤~150 lines of logic to port | one converter (113–142 measured at 41–50k) |
| ~150–250 | one converter, expect 80–100k; facts in the packet matter most here |
| >~250 (script + ported helper) | serial parts at section boundaries; part 1 writes helpers + `-- CONTINUE: next section starts at script line N (<name>)`; part k appends |
| `xargs -P`, `&`/`wait`, daemons, interactive | don't dispatch; `blocked:*` |

Packet carries every fact the worker would otherwise search for (search = Haiku tokens).

## 3. Packets
Run the old script yourself first; its output gives the exact counts.
**Convert**
```
Repo: <abs worktree>. Binary: <abs worktree>/medaka (built; do not build).
Scratch dir: <abs scratch>/<gate> (create with mkdir -p).
Report path: <abs scratch>/<gate>.report.txt
CONVERT (<native-wrap|native-rewrite>): <abs>/test/<gate>.sh (<N> lines) into
<abs>/test/<gate>_test.mdk. Create only that file.
Facts: <inputs read; fixture/golden dirs; today's EXACT counts (script output); helpers to reuse>.
Mutation subjects allowed: <files only this worker breaks this wave>.
Known hazards: <needs bash; reads git; …>.
```
**Part k/n**: + "APPEND to <file> (part k-1's helpers at lines a–b). Convert script lines
<from>–<to> (<sections>). Red-check only those. Not last → end with CONTINUE marker."
**Audit**: "AUDIT <script> -> <test>, converter report <…>.report.txt. Report path:
<…>.audit.txt. Mutation subjects allowed: <…>. Focus: <verifier WARNs | none>." Before
deleting the script (or `git show BASE:<path>` into scratch).
**Fix**: "FIX <test>: apply findings <1,3> of <…>.audit.txt (skip <2>: <ruling>). Report
path: <…>.fix.txt. Mutation subjects allowed: <…>." Fixer reads the audit file; you never paste findings.
**Recheck**: "RECHECK <test> for findings <1,3> of <…>.audit.txt; fixer report <…>.fix.txt.
Report path: <…>.recheck.txt. Mutation subjects allowed: <…>."

Mutation subjects disjoint across all concurrent workers. Tree-wide scanners (gates
reading every tracked file) see everyone's breaks: audit them alone.

## 4. Dispatch, track
- 4–6 background workers, disjoint files.
- Notification `subagent_tokens` ≈ final context = tier number → ledger.
- >100k or surprising: `python3 <repo>/.claude/skills/test-conversion-orchestrator/agent_usage.py --detail <agentId>`
  (every tool result's size, in order). Fix the cause (missing fact, skill gap, oversize packet).
- `BLOCKED:`/`PARTIAL:` = good outcome; re-packet from it. Never resume a worker past 100k.

## 5. Verify without reading
1. Read only the converter's ≤6-line final message.
2. `git status --short`: only the packet's file new; nothing tracked modified.
3. `python3 <repo>/.claude/skills/test-conversion-orchestrator/verify_conversion.py <repo> test/<gate>_test.mdk test/<gate>.sh`
   → ~10 OK/WARN/FAIL lines (green whole + per block, lint/fmt, suppression, bare
   `scratchDir`, ungraded spawns, unfloored enumerations, check counts). FAIL → Fix packet
   quoting the line; WARN → auditor's Focus.
4. Every file passing 3 → one `conversion-auditor` (2–3 files if each <150 lines), in
   parallel with further conversions. Final message: `CLEAN` | one line per finding.
5. Findings → Fix packet → verifier again → RECHECK. Before a ruling (accept a DROPPED,
   reject a finding, accept a PARTIAL red proof): read only that spot,
   `sed -n '<l-3>,<l+3>p' <file>`, or the script lines named.
In the 2026-10-08 trial the converters' own red checks passed; the auditors still found 5
real holes in 3 of 4 files (walk `Err` → `[]`, floor below count, duplicate ledger rows).
Don't skip the audit.

## 6. Bookkeeping per gate (yours)
1. `python3 <repo>/.claude/skills/test-conversion-orchestrator/flip_row.py <repo> <gate> test/<gate>_test.mdk`;
   then by eye: `sources` += `test/compiler_cli_test_support.mdk` if imported; `corpus` = dirs read.
2. `git rm test/<gate>.sh`.
3. `git grep -n '<gate>.sh'`, then sort each hit:
   - Executes it (workflow step or path filter, Makefile, `test/preflight.sh`, scripts): repoint.
   - A live doc cites it: repoint to the `_test.mdk`.
   - History, or a comment in `compiler/**`/`stdlib/**`: a `REF` line in
     `test/DOC-LINK-EXCEPTIONS.txt` (copy the wave-1 format). Never edit
     compiler/stdlib text for a citation (it moves the fingerprint and snapshots).
4. Per wave, after `git add -N` on new files (the doc checks scan only tracked files, so an
   untracked new skill or test passes vacuously): `medaka gate verify`; `make docs-links`; `make agent-doc-symbols`;
   `make gen-ci`; `sh test/run_gates.sh diff_compiler_gate_registry diff_compiler_ci_gen_drift diff_compiler_ci_shard_coverage diff_compiler_tier_drift diff_compiler_fixture_corpus_coverage diff_compiler_lint_baseline diff_compiler_preflight_base`
   (preflight_base copies the registry into a scratch tree; a converted gate preflight always
   adds must resolve there).
   Rows merged/removed → `sh test/gate_cost_ingest.sh --baseline test/gate_cost_baseline.json --registry test/gates.toml`.

## 7. PR, review, wrap-up
- One branch and one PR per wave (`scripts/pr.sh`, `docs/ops/PR-HELPER.md`). Body: gates
  converted; gates not converted, with reasons; the ledger's token column. Serves #2600 (and
  #2592 for wave-1 rows).
- Sonnet reviewer packet when the auditors covered every file: bookkeeping + a 1-in-3
  mutation sample, not a re-audit (wave 1's full re-audit cost ~700k). Triage at the line → Fix packets.
- Fold the lessons into `convert-shell-gate`, tersely. **Replace, don't append**: it is
  preloaded into every worker, so every byte is paid on every call. Keep it ≤ ~8 KB.
