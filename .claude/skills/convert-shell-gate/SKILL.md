---
name: convert-shell-gate
description: Convert one `migration = "native-wrap"` shell gate (a test/*.sh that drives ./medaka and compares text) into a native `*_test.mdk` gate-test. Self-contained recipe, template and helper cheat sheet; load this instead of reading stdlib or support-module sources.
---

# Convert a shell gate to a gate-test (epic #2600, wave 1 #2592)

The replacement does the same spawns and comparisons in Medaka. It lives at
`test/<name>_test.mdk`, runs under `./medaka test <abs file>` (native), and must
grade at least as much as the script did. The orchestrator flips the registry
row and deletes the script; you only write the test file.

## Recipe

1. Read the script once. Number every check it makes (each `ok`/`FAIL`, `diff`,
   exit-code test). The test keeps ALL of them; a dropped check is a silent
   regression. Note the fixture/golden paths and leave them where they are.
2. Write the file from the skeleton below, one `test` block per original script
   (batched assignments) or per check group.
3. `fmt --write`, `lint`, `check`, `test` on your file only, absolute paths.
   `check` prints "N further diagnostics in imported modules": ignore it.
4. Parity-plus-red: run the OLD script once (green) and your file (green); make
   ONE deliberate break the old gate would have caught (a golden line or pinned
   string that only your gate owns); show your file RED; restore with
   `git checkout -- <path>`; green again.
5. Report (under 25 lines): files created; the numbered checks with the `test`
   block carrying each; the four transcripts, last lines only; anything not
   expressible, with the reason.

Stuck on one obstacle after ~3 attempts: stop, report `BLOCKED: <obstacle>`.
Do not re-read files you just wrote. Do not run `make`, `run_gates.sh`,
`preflight`, `gate verify`, or any suite; do not edit `test/gates.toml`, the
Makefile, docs, or any file outside your assignment.

## Rules that the pilot hit (each one reds a gate or hides a bug)

- **Grade the exit code of every spawn**, in the literal shape
  `if code /= 0 then fail "…exited \{intToString code}" else <compare stdout>`.
  `medaka gate verify` looks for the text `code /=`/`code ==` (or an
  `expectSpawn*`/`expectCheck*` helper); `expectEqual 0 code` is NOT recognised.
  A script that discarded stderr/exit still gets its exit pinned.
- **Never add `-- lint-disable-…`.** A lint hit is usually right: search
  `stdlib/string.mdk`, `list.mdk` before hand-rolling a helper (`replaceAll`,
  `join`, `lines`, `unwords`, `split` all exist). If you believe a rule is
  wrong, report it instead.
- **File IO is native**: `fs.{mkdirAll}`, `readFile path`, `writeFile path text`
  (each returns a `Result`). Do not shell out to `cat`, `printf >`, `mkdir`.
  Chain several `Result`s with a `do` block or `map`, not a six-deep `match`
  staircase.
- **Enumerate fixtures, never hardcode the list.** `compiler_cli_test_support.
  fixtureStems dir` gives the top-level `.mdk` stems; for another extension use
  `fs.fixtureFiles dir` (all paths) then `filter (endsWith ".jsonl")` and
  `path.stem`. Add `expectAtLeast <today's count> (length stems)` so a
  shrunken corpus is red.
- **Spell the fixture directory literally in your test file** (e.g.
  `underRoot "test/lsp_fixtures"`), even when a built harness reads it. The
  corpus-coverage gate finds a corpus's consumer by that literal path in a
  tracked `.sh` or `_test.mdk`; a compiled program that reads it internally is
  invisible once the script is gone. Add a `expectAtLeast <n> (length files)`
  floor on it.
- **`string.contains NEEDLE HAYSTACK` takes the needle FIRST**, and so do
  `startsWith PREFIX s`, `endsWith SUFFIX s`. A reversed call turns a "must NOT
  contain" check into one that can never fire. Every absence check needs its own
  red proof: make the absent text present and watch the test fail.
- **`length (lines "")` is 1, not 0.** Test emptiness with `text == ""`.
- **A spawn that fails to launch must not satisfy a "must fail" check.** `env`
  exits 126/127 when the command is missing; treat those as errors, not rejections.
- **A floor equals today's corpus size**, not 1: `expectAtLeast <count> (length
  stems)`; otherwise most of a corpus can vanish and the test stays green.
- **If the script rejected a fixture directory with no entry file**, keep that:
  enumerate the DIRECTORIES and require the file, do not enumerate entry files.
- **Carry design rationale across.** If the script's header explains what each
  state or message means (a table, a rule that fixtures must be path-stable, what
  the gate does NOT cover), port it into the test's header; live files cite it.
- **Grade every spawn's exit code in the file that spawns**, including cleanup
  `rm` calls; a `refuse` row is `if code /= 1 then fail …`, not stderr text alone.
- **No working-directory parameter exists.** For a cwd-relative run use
  `boundedVerb "sh" ["-c", "cd \"$1\" && shift && exec \"$@\"", "medaka", dir, medakaBin, …args]`.
- **Use `test_process.withScratchDir (dir => <Expectation>)` for every scratch
  directory.** It makes a fresh directory per call, runs the body, and removes the
  directory afterwards (graded, and also when the body fails). Do NOT use the bare
  `scratchDir`: it is a value, evaluated ONCE per process, so every `test` block
  of a file shares one directory and one block's files or `rm -rf` break the next.
  Prove independence: run every block alone with `medaka test --filter
  "<name substring>" <file>` AND with two blocks swapped; a file that is green only
  in source order is wrong. If the script removed its temp tree with a `trap`, the
  native test gets this for free from `withScratchDir`.
- **Normalise paths** the way the script did (`sed s|$ROOT/|ROOT/|`): replace
  both `medakaRoot ++ "/"` and, when `medakaRoot` is relative, `$PWD ++ "/"`,
  using `replaceAll` from the `string` module.
- `CAPTURE=1` re-capture modes have no native equivalent; do not invent one,
  report that the script had it.

## Skeleton

```
{- | Gate for <invariant>, over <fixture dir>. Replaces <script>.sh.
   <one line on why it needs the binary>.

   Runs under `medaka test --native`: it spawns subprocesses and reads
   fixtures, neither of which the interpreter binds. -}

import test_process.{medakaBin, medakaRoot, underRoot, boundedVerb}
import test.{Expectation, expectAll, expectEach, expectGolden, fail}

corpus : <IO> String
corpus = underRoot "test/<fixtures>"

row : String -> <Exec, IO, FileRead> Expectation
row name = match boundedVerb medakaBin ["run", "\{corpus}/\{name}.mdk"]
  Err e => fail "could not spawn on \{name}: \{e}"
  Ok (code, out, _) =>
    if code /= 0 then
      fail "\{name}: exited \{intToString code}"
    else
      expectGolden "\{medakaRoot}/test/<goldens>/\{name}.golden" out

test "<script name>: <what it checks>" = expectEach [("<label>", row "<name>")]
```

## Helper cheat sheet (exact names; signatures are real)

- `test_process`: `medakaRoot : <IO> String`, `medakaBin`, `underRoot rel`,
  `boundedVerb cmd args : <Exec> Result String (Int, stdout, stderr)`,
  `boundedVerbSeconds secs cmd args`,
  `withScratchDir : (String -> <Exec, IO, FileRead, FileWrite> Expectation) -> <Exec, IO, FileRead, FileWrite> Expectation`,
  `expectSpawnOk cmd args`, `expectSpawnOkLine cmd args wholeLine`,
  `expectSpawnFails` / `expectSpawnFailsAll` (nonzero exit AND a diagnostic).
- `compiler_cli_test_support`: `runMedaka args : Result String (Int, out++err)`,
  `boundedInTree secs cmd args` (passes MEDAKA_ROOT/EMITTER), `fixtureIn
  corpus name`, `fixtureStems dir : Result String (List String)`,
  `expectCheckAccept path`, `expectCheckReject path needles`.
- `test`: `expectGolden path actual` and `expectEqualText exp act` both strip a
  trailing `()` suffix, or else a whole last line `0`, from BOTH sides before
  comparing (a driver artefact normaliser, `stdlib/test.mdk` `normalizeTrailingUnit`),
  so they are LOOSER than the shell `diff`/`cmp`/`[ "$a" = "$b" ]` they replace.
  `expectEqualLines exp act` is exact. Use it (reading the golden yourself) where
  the output is not an auto-printed program value, or where a trailing `()`/`0`
  line could be real data. `expectTextContainsAll needles text`,
  `expectLineContainsAll`, `expectAll [e…]`, `expectEach [(label, e)…]`,
  `expectAtLeast n m` (a corpus floor: "0 checked" must be red), `expectTrue`,
  `expectFalse`, `expectEqual`, `fail msg`, `pass`.
- Full vocabulary and when to use which: the `write-tests` skill.
