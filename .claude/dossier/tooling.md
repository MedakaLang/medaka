## [H-FMT] fmt bare-mode silence + tree cleanliness + float literal history

Bare `medaka fmt <file>` (no flag) behaves like `--check` — reports files that aren't
formatted, exit 1 if any; it never writes.

#1348 — the bare `medaka fmt <file>` form used to default to writing, silently, with no
output. Fixed so `--write` is the only mutating mode and always prints a summary
(`formatted N file(s)` / `already formatted`). `medaka fmt --help` (and `--help`/`-h` on any
subcommand) prints that subcommand's flags.

Tree-cleanliness verified 2026-07-14: `sqlite/lib/varint.mdk` and `stdlib/byteparser.mdk` both
fail `fmt --check`. AGENTS.md used to claim "the whole tree is clean" — it isn't.

#1794 (2026-08-22): that hand-typed two-file list rotted, in both directions at once —
`gzip/lib/inflate.mdk` landed on `main` unformatted with no entry anywhere (fixed by
reformatting it in the same PR that added this paragraph, plain `fmt --write` — no deliberate
reason it was left unformatted, unlike a possible varint.mdk/byteparser.mdk rationale that
turned out not to apply either), and separately, by the time anyone re-checked, varint.mdk and
byteparser.mdk had themselves *already* been reformatted clean, so the "known exceptions" were
stale in the other direction too. There was never a documented root cause tying those two files
together (no dossier entry beyond "verified not clean on this date") — so there was nothing to
match `inflate.mdk` against. The fix: stop hand-typing the list. `make fmt-clean-census`
(`test/fmt_clean_census.sh`) derives it fresh from `git ls-files` + `medaka fmt --check`,
excluding `test/` the same way the pre-commit hook does. On-demand only, not a CI gate — see the
script's own header for why (blast-radius caution, same spirit as #1654).

`fmt --write` on a file holding a float literal ≥ 1e15 (#51, CLOSED 2026-07-15; re-probed
2026-07-16 per #361): it still writes `9e+15`, but the lexer now reads that back correctly
(`main = println 9000000000000000.0` → `fmt --write` → `main = println 9e+15` →
`check`/`run` both round-trip to the same `9e+15`, verified on the current binary at the time).
No longer a destructive operation.

## [H-LINT] why the hook also runs a whole-project scan

The tree is at 0 findings and the hook is a MAX RATCHET: all ~20 rules gated, so any NEW
finding of any rule fails the commit. The cross-file rule `rule-duplicate-body` can't be
checked per-staged-file (it needs the whole project graph to detect a duplicate), so the hook
additionally runs one whole-project scan, `medaka lint compiler stdlib sqlite`, on top of the
per-file checks.

## [H-SNAPSHOT] what the snapshot check actually covers

Gates on `test/diff_compiler_snapshot_frontend.sh` over ANY staged `.mdk` — `test/` fixtures
included, since they're in the corpus too — plus `test/snapshots/*.md` itself. The reason it
must cover fixtures and the `.md` goldens both: a compiler-source change, or even a pure
`medaka fmt` reflow with no semantic change, can move a snapshot. A stale snapshot fails the
commit rather than reading as unrelated tooling breakage.

## [H-SNAPSHOT-NEW] --new is suite-wide, not --bless's sibling

Measured 2026-08-14 creating `test/snapshots/compiler/route_key.md`: running `--new` produced
1 new, 0 blessed, 201 skipped, honestly reporting "0 compared, 201 skipped: NOTHING COMPARED
(this is not a pass)". The subsequent plain check read 202/202 — that re-check is what makes it
a pass. The lesson: `--new` never overwrites existing goldens, but by itself it proves nothing
about the rest of the corpus.

## [H-SNAPSHOT-UNSTAGED] unstaged snapshot diff invisibility, fixed by #1179

Before #1179, a `--bless` an agent forgot to `git add` was invisible to the pre-commit snapshot
check — it "passed" because the disk looked current, while the commit about to be made still
carried the OLD golden. This was a SILENT version of the exact "bless in the same commit" hazard
the check exists to prevent. Fixed: an unstaged snapshot diff now fails check 4 outright,
unconditionally, before the suite runs.

## [H-DEFER] why the defer flag is sound despite skipping check 4

"Bless in the same commit" and "goldens are re-cut in their own terminal commit" are only in
tension for a source-only commit whose golden isn't blessed yet — that legitimately fails check
4, since the golden for the staged source is by construction not staged. That's correct: the
property check 4 protects (`main` never observes a moved source with a stale golden) is a
per-push, not per-commit, property — the merge queue tests the PR's merged result, not each
intermediate commit — so a source commit followed by a separate terminal golden-recut commit
within the same PR already satisfies it. That's the reasoning `PRECOMMIT_SNAPSHOT_DEFER=1`
relies on: it only needs to buy one commit room, not weaken the real guarantee.

## [H-DEFER-VS-GUARD] PR #1638 — DEFER doesn't reach the unstaged guard

Measured 2026-08-14 on PR #1638, where the intended commit order was source → pin (a `.mdk`) →
goldens. `PRECOMMIT_SNAPSHOT_DEFER=1` opts a commit out of check 4's *suite*, but the
unstaged-snapshot guard ([H-SNAPSHOT-UNSTAGED]) is a separate mechanism it doesn't reach — so a
later `.mdk`-staging commit still tripped on the blessed-but-unstaged snapshot from the earlier
deferred commit. This is why "goldens in their own terminal commit" and any later `.mdk`-staging
commit are mutually exclusive under this hook, and why the remedy is to bless/stage goldens LAST.

## [D-JSON-HOLE] #1362 discovery narrative

Confirmed over a real JSON-RPC call to the `medaka mcp` `medaka_check` tool (`isError: false`)
on a multi-module project with an internal-extern restriction violation: exit 0, empty
diagnostics, where the human `check` arm correctly rejects at exit 1. Root cause:
`analyzeProject`'s `resolvePass` calls the unguarded `resolveModule` instead of the guarded
`resolveModulesErrorsG` variant. Scope was derived, not assumed: `env.internalGuard` has exactly
one read site, confirming this is specifically the internal-extern restriction and not the whole
diagnostic channel; a single-file target is unaffected (different code path); `run --json` does
not share the omission. This is silent wrongness in the very tool used to detect wrongness —
notable because it inverts the general advice ("prefer `--json`, key off `code`") in exactly the
one place that advice bites back.

## [D-RUN-VS-BUILD] why the pair is a genuine codegen/runtime test

`medaka run` and `medaka build` share the whole front end — both typecheck with the same
binary; they differ only in the execution engine (interpreter vs emitted native + runtime). So
comparing `run` against `build` is a genuine test of codegen and runtime behavior — it is how
several miscompiles were caught — but it is not two independent observations of anything at or
before typecheck.

## [D-CORE-IR-TYPED] the 2026-07-16 dict-routing investigation

An agent chasing a run-path dict bug on 2026-07-16 called
`compiler/entries/core_ir_typed_modules_dump_main.mdk` *"the single highest-value tool here — it
turned three days of plausible speculation into a 10-minute proof"*. It disproved a wrong root
cause that had been briefed to that agent — printing the actual `CDict`/`CMethod` route settled
in minutes what days of source-reading couldn't.

## [D-CORE-IR-TRAP] why the obvious-named tool is a trap

`core_ir_dump_main.mdk` is prelude-free and typecheck-free, so on a dict-routing bug it shows a
clean tree with no `$dict` param at all — and reads as confirmation there is no bug, when really
it just never reaches the typed/dict-passed lowering. The typed sibling's own header states this
explicitly; the problem was it wasn't reachable/discoverable from AGENTS.md before this trap was
written up.

## [D-KEEP-IR] the "prints it" wording bug and the dict-routing S0

AGENTS.md said `medaka build --keep-ir` "prints it" until 2026-07-17 — actually it only prints
the *path* (`kept IR: <path>`), never the IR text. This cost an agent a grep cycle looking for IR
that was never going to arrive on stdout.

Separately, an agent debugging a dict-routing S0 on 2026-07-16 called `--keep-ir` the single
highest-value tool in that investigation — it turned "I think the wrong impl is selected" into
`call @mdk_impl_S__List_a___s` visible on screen, which disproved the filed root cause outright.

## [D-EMITTER-CLI] the exit-0-empty-stdout history, fixed by #440

Until 2026-07-17, every error path of `./medaka_emitter` (wrong CLI usage, nonexistent input
file, or a real typecheck error — not just a wrong arity) exited **0** with **empty stdout**.
That handed a redirecting harness an empty artifact plus apparent success. Fixed (#440,
`compiler/entries/entry_support.mdk`'s `failWith`): every error path now exits 1 with a stderr
diagnostic.

## [D-BUILD-PIPE] the near-miss

Two reviewers in one session nearly reported *"build fails at exit 0"* as a defect after piping
build output through `tail` to keep it short — the compiler was exiting 1 correctly the whole
time; `tail`'s own exit code was what they were reading. Same trap the must-fail suite's own
header calls out for `run` (`test/diff_compiler_must_fail.sh`) — it applies to every verb, and
bites hardest on `build` because its interesting output is on stderr, which invites `2>&1 | tail`.

## [D-TWO-ARM] the exeDir mechanism and why it makes a two-worktree comparison sound

`exeDir = dirOf (executablePath ())`, `defaultMedakaRoot = exeDir`, `defaultMedakaEmitter =
joinPath exeDir "medaka_emitter"` (`compiler/driver/build_cmd.mdk`, the "exe-relative
install-layout defaults" block); every `<root>/stdlib/...` read goes through `envOr
"MEDAKA_ROOT" defaultMedakaRoot`. This is what makes a two-worktree comparison sound: a
base-arm binary invoked on files in a branch worktree still uses base's stdlib and base's
emitter, so the only variable is the compiler under test. Verify from the consequence, not the
source: copy `./medaka` alone into an empty directory and run it from inside a real checkout —
it reports `cannot read the stdlib prelude at "<that-empty-dir>/stdlib/runtime.mdk"`, naming
the binary's own directory, with cwd and the source file both elsewhere. The miss diagnostic
offers "run from the project root" as a remedy; measured, cwd being a directory that HAS
`stdlib/` did not rescue it — only `MEDAKA_ROOT` or an exe-adjacent `stdlib/` did.

## [D-TWO-ARM-STDLIB] PR #1640 — fourteen retracted findings

Measured 2026-08-15 on PR #1640: a reviewer reported 14 `base=1 → pr=0` stdlib divergences
running a base binary against a branch worktree's `stdlib/*.mdk` files, then **retracted all
14** after swapping which tree each binary pointed at reversed the direction entirely. The
variable was the file's location relative to the binary (the internal-extern guard trusts a
stdlib file only when it sits under the binary's own `MEDAKA_ROOT`), not the compiler under
test. Re-running with each binary against its own tree's `stdlib/` (tree prefix normalized
before diffing) produced 0 divergences across all 29 modules.

## [D-TWO-ARM-RUNTIME] the 2026-08-11 session

The complete exe-adjacent set is `medaka` + `medaka_emitter` + `stdlib/` + `runtime/`:
`runBuildNativeRoots` (`compiler/driver/build_cmd.mdk`) computes
`rtC = joinPath root "runtime/medaka_rt.c"` off that same `root`, and hands it to `clangLink`
as a clang input — so a binary with only `stdlib/` beside it checks and runs perfectly and then
dies at the link step. Derive the mechanism rather than trusting a paragraph:
`grep -n 'medaka_rt.c' compiler/driver/build_cmd.mdk` shows the `joinPath root` site and the
`clangLink cc rtC …` call.

Two reviewers in one 2026-08-11 session independently hit the missing `runtime/` symlink in an
alt-dir two-arm setup: `check` and `run` succeed and "prove" the alt-dir arm is fully wired up,
and the first `build` — usually exactly where a two-arm differential review gets interesting —
is where it breaks, failing at the clang link step with a `medaka_rt.c` not-found error.

## [D-GATE-OVERRIDE] #1431 and the "Four honour an override" miscount

AGENTS.md said "Four honour an override" until 2026-08-09, *while citing the very
`grep -rln 'MEDAKA="${MEDAKA:-' test/*.sh` command that returns more than twice that*. Nobody
had actually run it — the number came from a report, was repeated verbatim into issue #1431,
and reached AGENTS.md unverified. The correction: a claim that ships its own derivation command
is only honest if someone executed it; this one failed at the last inch. `test/preflight.sh`'s
own "Word-boundaries" comment models the discipline this trap is asking for. Also noted: this
harness mangles a `${…}` inside a quoted inline shell argument and returns zero matches for a
pattern that is really there — run the grep through a script file, not inline.
