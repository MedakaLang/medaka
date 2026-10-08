---
name: convert-shell-gate
description: Convert one shell gate (test/*.sh, `migration = "native-wrap"` or `"native-rewrite"`) into a native `*_test.mdk` gate-test. Recipe, skeletons, shell-to-Medaka table, helper names. Load instead of reading stdlib or support sources. Preloaded by `test-converter` and `conversion-auditor`.
---

# Shell gate → native gate-test (epic #2600)

Target `test/<name>_test.mdk` (or `<project>/test/…`), run by `medaka test <abs file>`.
Must grade ≥ what the script graded. You write only the test file; registry, script
deletion, references = orchestrator (`test-conversion-orchestrator`).

- **native-wrap**: script spawns `./medaka`/a binary, compares text → same spawns (Skeleton A).
- **native-rewrite**: script is grep/sed/awk/python over repo files → Medaka over
  `readFile` (Skeleton B). Never spawn `grep`/`sed`/`python3`; `git` is OK.

## Recipe
1. Read script once. Number every check (`ok`/`FAIL`, `diff`, exit test, "ZERO extracted"
   guard). Keep all. Leave fixtures/goldens in place.
2. Write from a skeleton; one `test` block per check group.
3. `fmt --write`, `lint`, `check`, `test` on your file only, abs paths. Ignore "N further
   diagnostics in imported modules". **Lint exits 0 even with warnings: clean = empty
   output.** Fix every warning before reporting DONE.
4. Parity + red: old script green once; file green; one break the old gate also catches →
   file RED; `git checkout -- <path>` → green. Break a fixture/golden/doc/JSON/JS side,
   never `compiler/**`/`stdlib/**` (moves the source fingerprint). Each absence check
   ("must NOT contain") needs its own red: make the text present.
5. Report per your agent def / packet.

## Rules (each one shipped a bug before)
- Grade every spawn's exit, literally `if code /= 0 then fail "…exited \{intToString code}" else …`
  (incl. cleanup `rm`). `gate verify` matches text `code /=`/`code ==` or an
  `expectSpawn*`/`expectCheck*` helper; `expectEqual 0 code` not recognised. Refuse row:
  `if code /= 1 then fail …`.
- Exit 126/127 = launch failure, never a "must fail" pass.
- No `-- lint-disable`. Hand-rolling a helper? `sig.py` first. Rule looks wrong → report.
- `contains NEEDLE HAYSTACK`, `startsWith PREFIX s`, `endsWith SUFFIX s`: needle first.
- `length (lines "")` is 1. Empty = `text == ""`.
- Floors = today's EXACT count (`expectAtLeast <n> (length xs)`) on every fixture corpus,
  ledger and extraction the script guarded with "0 checked"/"ZERO". Exception: a
  tree-wide scan (every tracked file) shrinks legitimately as files are deleted, so its
  floor only catches a broken scan: ~80% of today's count, with a comment saying so.
- Subject in `compiler/**`/`stdlib/**` (can't be mutated): make the extractor a pure
  `String -> List …` fn and red-prove it with an inline-string `test` block in the file.
- Enumerate, never hardcode: `fixtureStems dir`; `fixtureFiles dir` + `filter (endsWith ".x")`;
  `fixtureDirs` when the script walked dirs (dir without its entry file = red).
- A listing/walk `Err` is a `fail`, never `[]` (one bad entry would hide every peer).
- Ledger/set compares: a duplicate row, an extra ` : ` field or a missing final newline must
  go red (python dict/list semantics differ from membership). Each wave's auditors found this.
- Spell each corpus dir literally (`underRoot "test/lsp_fixtures"`); corpus-coverage greps it.
- File IO native: `readFile`/`writeFile` (no import, return `Result`), `readFileBytes` for
  raw bytes, `fs.{mkdirAll}`. No `cat`/`printf >`/`mkdir` spawns. Chain `Result`s with `do`.
- Scratch dirs: `withScratchDir (dir => …)` only; bare `scratchDir` is one dir shared by all
  blocks. Prove order independence: `python3 <repo>/.claude/skills/convert-shell-gate/run_blocks.py <medaka> <file>`.
- No cwd parameter: `boundedVerb "sh" ["-c", "cd \"$1\" && shift && exec \"$@\"", "medaka", dir, medakaBin, …args]`.
- Path normalising (`sed s|$ROOT/|ROOT/|`): `replaceAll (medakaRoot ++ "/") "ROOT/" s` (string).
- `expectGolden`/`expectEqualText` strip a trailing `()` or final `0` line both sides (looser
  than `diff`). `expectEqualLines` is exact.
- Port the header's "proves / does NOT prove" into the test header.
- `CAPTURE=1`/`--write` modes: no native equivalent; report, don't invent.
- `BLOCKED:` on `xargs -P`, `&`+`wait`, daemons, interactive handles, or `node`/`wasm-tools`/`valgrind`.
- A scenario needing a new repo file or symlink: argue it, or use scratch state (e.g. a temp
  `GIT_INDEX_FILE`); never create files in the repo.

## Compile traps
- Import non-prelude names: `import string.{lines, split, startsWith}`, `import list.{nub, sort}`.
  `core`/`runtime` names (`map`, `filter`, `length`, `readFile`, `intToString`) are never
  qualified (`S.map` errors). `string`/`list`/`regex` share `split`/`replaceAll`: import
  selectively or `import string as S`. Follow the compiler's "add `import …`" hint.
- Effect rows on every spawning/reading/writing fn, else "performs <…> where only <> is
  allowed": usually `<Exec, IO, FileRead>`, `+ FileWrite` if writing. Pure fns: none.
- Multi-line `match` can't sit inside a parenthesised lambda/arg list → named helper:
  ```
  quoted : String -> String
  quoted l = match split "\"" l
    _ :: k :: _ => k
    _ => ""
  ```
  List patterns: `x :: rest`, `[]`. No `[a, b, ..]`.
- `boundedVerb` → `Result String (Int, String, String)`: match `Err e` / `Ok (code, out, err)`.

## Shell → Medaka (native-rewrite)
| shell | Medaka |
|---|---|
| `cat f` | `readFile f` |
| `grep -n PAT` | `lines t` → `filter (contains "lit")` / `isMatch re`; numbers via `indexed` (0-based) |
| `grep -o RE` | `map (m => m.text) (findAll re s)` |
| `sed 's/a/b/g'` | string `replaceAll "a" "b" s`; regex `replaceAll re "b" s` |
| `sed -n '/a/,/b/p'` | `dropWhile`/`takeWhile` over `lines` |
| `sort -u` | `nub (sort xs)` |
| `comm -23 a b` | `filter (x => not (elem x b)) a` |
| `tr '\|' '\n'` | `split "\|" s` |
| python `json.load` | `json.parse`, `get`, `asString`, `asArray` |
| offending-lines report | `expectNoFindings "<what>" (Ok hits)` |

Name lookup (one line per hit; cheap):
`python3 <repo>/.claude/skills/convert-shell-gate/sig.py NAME…` · `-m MODULE` · `-s SUBSTRING`

## Skeleton A (native-wrap)
```
{- | Gate for <invariant>, over <fixture dir>. Replaces <script>.sh.
   <proves / does NOT prove>. Runs under `medaka test --native`. -}

import test_process.{medakaBin, medakaRoot, underRoot, boundedVerb}
import test.{Expectation, expectEach, expectGolden, fail}

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

## Skeleton B (native-rewrite)
```
{- | <invariant>. Replaces <script>.sh. <proves / does NOT prove>. -}

import test_process.{underRoot}
import test.{Expectation, expectAll, expectAtLeast, expectNoFindings, fail}

items : String -> List String      -- the script's extraction, pure
items text = …

check : <IO, FileRead> Expectation
check = match readFile (underRoot "<repo-relative path>")
  Err e => fail "could not read <path>: \{e}"
  Ok text =>
    let xs = items text
    expectAll
      [ expectAtLeast <today's count> (length xs)
      , expectNoFindings "<what drifted>" (Ok (filter (x => …) xs))
      ]

test "<script name>: <what it checks>" = check
```

## Helpers (exact names)
- `test_process`: `medakaRoot`, `medakaBin`, `underRoot rel`, `boundedVerb cmd args`,
  `boundedVerbSeconds secs cmd args`, `withScratchDir`, `expectSpawnOk`, `expectSpawnOkLine`,
  `expectSpawnFails`/`expectSpawnFailsAll` (nonzero exit AND a diagnostic).
- `compiler_cli_test_support` (test/): `runMedaka args` (out++err), `boundedInTree secs cmd args`
  (sets MEDAKA_ROOT/EMITTER), fixtureIn, fixtureStems, `expectCheckAccept`, `expectCheckReject`.
- `fs`: `fixtureFiles`, `fixtureDirs`, `walkDir`, `mkdirAll`, `isFile`, `isDir`.
- `test`: `expectGolden`, `expectEqualText`, `expectEqualLines`, `expectTextContainsAll`,
  `expectLineContainsAll`, `expectAll`, `expectEach`, `expectAtLeast`, `expectNoFindings`,
  `expectFindings`, `expectTrue`, `expectFalse`, `expectEqual`, `fail`, `pass`.
- Anything else: `sig.py`.
