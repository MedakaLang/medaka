# PR-HELPER.md — `scripts/pr.sh`, the verified PR lifecycle helper

**Status:** IMPLEMENTED — issue #1414, PR 2026-08-08. Ships five independent
subcommands (`body` / `watch` / `receipt` / `enqueue` / `complete`) that wrap the raw `gh`
sequences behind AGENTS.md's standing rule — *read the state back, never the
return code* — because `gh`'s write exit codes carry no signal for the shapes
#1212 and #1213 record.

## Why it exists

Routine PR orchestration required re-deriving the same fragile `gh` sequences by
hand, and the underlying tools demonstrably lie about success:

- **Safe body write** — `gh pr edit --body-file` can no-op on a Projects-classic
  deprecation error while reporting success; routing around it with
  `gh api -X PATCH -f body=@file` writes the **literal string** `@file` because
  `-f` does not expand `@` (`-F` does). #1212.
- **Concise check watch** — reprinting the whole check matrix every poll obscures
  state changes and floods logs. And a **stale** check-run is indistinguishable
  from a fresh one by name alone (#1213).
- **Compact CI receipt** — a green checkmark does not prove a narrowed PR shard
  executed its grading steps. The selected workflow run must match the intended
  head, and its job-step conclusions must remain visible to review.
- **Verified enqueue** — `gh pr merge --auto --merge`'s banner and exit code
  carry no signal either way, and `autoMergeRequest` reads `null` while queued;
  the only reliable signal is `isInMergeQueue` via GraphQL. #1212.
- **Verified completion** — a commit pushed to an enqueued PR can miss its own
  merge; the branch may be merged as it stood, leaving the later push behind.
  Verifying against the **branch** is the natural-but-wrong check; the right one
  `--is-ancestor` against `main`. #1213.

The helper is **non-interactive** and each subcommand is usable on its own: a
body edit never requires running the whole lifecycle.

## Usage

POSIX sh; `gh` and `git` only. Runs on Linux and macOS.

```sh
scripts/pr.sh body      --number N [--issue] --file F        [--repo OWNER/REPO]
scripts/pr.sh watch     --number N [--interval S] [--timeout S]
scripts/pr.sh receipt   (--number N | --sha SHA) --run ID
scripts/pr.sh enqueue   --number N [--interval S] [--timeout S]
scripts/pr.sh complete  --number N --sha SHA  [--interval S] [--timeout S]
```

- `--repo OWNER/REPO` (default: `$GH_REPO`, else your git `origin`).
- Tests substitute a mock via `$GH` (default `gh`); they never touch a repo.

## The five operations

### 1. `body` — verified body write

`gh api -X PATCH repos/$REPO/{pulls,issues}/$N -F "body=@$file"` (note `-F`, the
file-expanding flag), then reads the body back and **byte-compares** (`cmp -s`)
against the source file. Success is reported only when the readback matches. A
no-op'ing write or a literal `@file` lands is caught by the readback, never by
the PATCH's exit code. Anything containing backticks, `$()`, quotes, a leading
`@`, blank lines, or non-ASCII round-trips byte-identical. Pass `--issue` to
target `issues/N` instead of `pulls/N`.

### 2. `watch` — concise check watching

Polls check-runs for the PR's head commit and prints **one line per state
transition** (`check <name>: queued` / `in_progress` / `completed (success)` /
`FAILED (failure)`) plus a final summary — never the full unchanged matrix. The
**exit status is derived from the checks' final conclusions**, not from the loop
ending: any terminal `failure`/`cancelled`/`timed_out`/`action_required`/`stale`
→ exit 1. Because a *stale* run carries no transition it stays silent unless it
changes; to distinguish a fresh from a stale run, compare the check's `started_at`
against the push time (#1213):

```sh
gh api "repos/OWNER/REPO/commits/$SHA/check-runs" \
  --jq '.check_runs[] | "\(.name) \(.conclusion) \(.started_at)"'
```

### 3. `receipt` — compact exact-head CI evidence

Reads one selected Actions workflow run, verifies its `head_sha` against either
the current head of `--number N` or an explicit `--sha SHA`, and prints one TSV
line for the run plus one TSV line per job. Each job line includes every step's
conclusion, making green-but-skipped narrowed shards explicit without copying the
full Actions response. It exits nonzero for a head mismatch, an incomplete run,
or a non-successful conclusion. Use the explicit SHA form for a `merge_group`
run, whose tested revision is not the PR branch head.

### 4. `enqueue` — verified auto-merge request

Requests `gh pr merge --auto --merge` (ignoring its exit code and banner), then
polls a single GraphQL read of `{isInMergeQueue state}` — the only reliable
signal (#1212). Reports success when `isInMergeQueue == true` **or** `state ==
MERGED` (the race where a green PR merges before queue membership is ever
observable — documented in the helper, handled here). Fails loudly if neither
holds within the timeout.

### 5. `complete` — verified completion

Waits for the PR to reach `MERGED`, then proves the intended head commit is an
**ancestor of the repo's `main`** (fetched authoritatively into a throwaway git
ref from the `--repo`'s clone URL, not this checkout's assumed origin;
`git merge-base --is-ancestor`). This is the #1213 race check: a commit pushed
after enqueue may be absent from what actually landed. On failure it reports
the PR's actual `mergeCommit` so the caller can see what did land. Fails if the
given SHA is not on `main` after the PR closes, or if the repo's `main` cannot
be fetched (never guesses).

## The body self-check

**This is a documentation convention, not helper logic.** `body` takes an
arbitrary file and writes it verbatim; nothing below changes what the script
does, and nothing below is enforced by it.

A PR body is the only artifact a reader gets who never sees the sprint's slice
reports. So the body you hand to `pr.sh body --file F` answers **the same five
questions** a sprint report answers at the end of its Notes section — verbatim,
and with concrete nouns (a path, a function name, or an explicit "none,
because …"; "followed the conventions" is not an answer):

1. **Which `stdlib/` or `compiler/support/` functions were looked for before
   any new helper was written?** Name them, or "no new helper". The reference
   is `docs/stdlib/index.md`; `rule-stdlib-reimpl` in `compiler/tools/lint.mdk`
   is a floor, not the check — it cannot see a renamed reimplementation.
2. **Where did the new code land, and does that match the placement the
   contract stated?** Name the directory; if it differs, say why in one line.
3. **Which existing file was EXTENDED rather than extracted from, and why was
   extending right?** Name it, or "no existing file grew". If it appears in
   `make arch-census`'s largest-files table, the "why" is required.
4. **What does each added comment state that the code cannot show?** Name any
   comment that narrates the PR rather than the code — and delete it first.
5. **Which test vehicle carries the new behaviour, by name?** Gate script,
   fixture path, doctest, property, or must-fail pin. If none, say what would
   fail if the change were reverted; "nothing" is an honest answer and a
   finding.

The canonical wording lives in `.claude/skills/sprint-packet/SKILL.md`
§ "The author self-check"; the placement ground truth they are measured
against is `.claude/skills/architecture/SKILL.md`. Answer them once, in the
body, near the end. `body`'s readback still byte-compares the file, so nothing
here affects verification.

## Testing

`sh test/pr_helper_test.sh` runs all five subcommands against the mock
(`test/fixtures/pr_mock_gh.sh`), verifying command construction from the mock's
argv log and state interpretation from canned responses — including the tricky
body, the `-F`-vs-`-f` distinction, GraphQL queue/state, and multi-poll check
transitions — plus one throwaway local git repo for `complete`'s real ancestry
logic. No external repository is touched. POSIX sh, Linux and macOS.
