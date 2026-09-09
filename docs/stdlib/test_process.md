# test_process

Assertions for a test that runs a program.

A test whose subject is a whole toolchain (a compiler verb, a script, any
binary) cannot compute its answer; it has to spawn the thing and grade
what came back. `expectSpawnOk`, `expectSpawnFails` and
`expectSpawnOkLine` grade a spawn, and `medakaRoot`, `underRoot` and
`medakaBin` say which files and which binary a test addresses.

The two jobs are deliberately separate: a grader that also resolved the
binary would have to name a verb, and callers need `check`, `run` and
`test`.

A test that spawns many subjects in one sweep reaches for `boundedVerb`,
so one hanging subject fails its own row instead of the job, and
`scratchDir`, so concurrent gate runs do not write over each other.

A test that grades a whole directory of `medaka test` suites reads their
executed-assertion counts with `testAssertionCount`, and keeps its roster
closed over the directory with `testFileStem`, `unrosteredTestFiles` and
`missingTestFiles`.

These assertions reach a subprocess extern, which `medaka test` does not
bind under the interpreter, so a file using them runs under `medaka test
--native`.

Import what you need: `import test_process.{expectSpawnOk, medakaBin}`.

## Locating the tree

### `medakaRoot`

```
medakaRoot : <IO> String
```

The root of the Medaka tree under test, from `MEDAKA_ROOT`, or `"."`
when that is unset.

Files are located through this rather than through the working
directory: a test runner exports the root and inherits whatever
directory its own caller happened to be in.

### `underRoot`

```
underRoot : String -> <IO> String
```

The path `rel`, which is relative to the tree root, resolved under
`medakaRoot`.

### `medakaBin`

```
medakaBin : <IO> String
```

The Medaka binary to spawn, from `MEDAKA`, defaulting to the one in
`medakaRoot`.

The default is a path, never the bare name `medaka`, so an unset
`MEDAKA` cannot resolve to some other build on `PATH`, or to nothing at
all, which still spawns and exits 127 with no output, an outcome any
assertion phrased over the output would accept.

## Spawning

### `spawnTimeoutSeconds`

```
spawnTimeoutSeconds : Int
```

The wall-clock ceiling `boundedVerb` puts on one spawn, in seconds.

A sweep that spawns a compiler once per fixture has to distinguish "this
fixture hangs" from "the whole job hung": without a per-spawn ceiling the
first hanging fixture consumes the job's own timeout and the sweep names
nothing.

### `boundedVerb`

```
boundedVerb : String -> List String -> <Exec _> Result String (Int, String, String)
```

`runVerb`, with `cmd` killed after `spawnTimeoutSeconds`.

A killed spawn is an ordinary nonzero exit, not an `Err`, so a caller
grading exit codes sees a failure on the row that hung rather than losing
the whole run. `perl` carries the alarm because it is the one interval
timer present on both Linux and macOS without a coreutils dependency.

```medaka
> boundedVerb "sh" ["-c", "printf hi; exit 3"]
Ok (3, "hi", "")
```

### `scratchDir`

```
scratchDir : <Exec _> Result String String
```

A fresh, empty directory of the host's choosing, for a test that has to
write files.

Gates run concurrently over one tree, so a scratch path spelled as a
constant collides between two runs of the same test; only the host can
hand out a name nothing else holds. The caller owns the directory and is
responsible for removing it.

```medaka
> map (startsWith "/") scratchDir
Ok True
```

## Grading a spawn

### `expectSpawnOk`

```
expectSpawnOk : String -> List String -> <Exec _> Expectation
```

Passes when running `cmd` with `args` exits 0.

The exit code is the whole assertion: a program that produced no output
at all still has to have exited 0. The failure message carries stdout
and stderr concatenated, since which stream a diagnostic lands on is not
what this asserts on.

```medaka
> expectSpawnOk "true" []
Pass "exit 0" "exit 0"
> expectSpawnOk "false" []
Fail "`false` exited 1: \"\"" "exit 0" "exit 1"
```

### `expectSpawnFails`

```
expectSpawnFails : String -> List String -> String -> <Exec _> Expectation
```

Passes when running `cmd` with `args` exits nonzero and its output
contains `needle`.

Both halves are required. A rejection graded on the exit code alone
stays green once the diagnostic it was written for has been deleted, and
one graded on the text alone accepts a program that never ran. `needle`
is matched against stdout and stderr concatenated.

```medaka
> expectSpawnFails "sh" ["-c", "exit 3"] ""
Pass "nonzero exit, output containing \"\"" "exit 3, output \"\""
> expectSpawnFails "true" [] "boom"
Fail "`true` exited 0, expected it to fail" "nonzero exit, output containing \"boom\"" "exit 0, output \"\""
```

### `expectSpawnOkLine`

```
expectSpawnOkLine : String -> List String -> String -> <Exec _> Expectation
```

Passes when running `cmd` with `args` exits 0 and one whole line of its
output equals `wantLine`.

The control-case peer of `expectSpawnFails`: exit 0 alone accepts a
program that ran and printed the wrong answer, and a substring accepts a
line that merely contains the expected one, so a longer or differently
prefixed line still passes. `wantLine` is matched against a whole line of
stdout and stderr concatenated, with a trailing carriage return removed.

```medaka
> expectSpawnOkLine "echo" ["hi"] "hi"
Pass "exit 0, output with a line \"hi\"" "exit 0, output \"hi\\n\""
> expectSpawnOkLine "echo" ["said hi"] "hi"
Fail "`echo said hi` exited 0 but no output line equals \"hi\": \"said hi\\n\"" "exit 0, output with a line \"hi\"" "exit 0, output \"said hi\\n\""
```

## Grading a directory of suites

### `testFileStem`

```
testFileStem : String -> Option String
```

The stem of a `*_test.mdk` file name, or `None` when `name` is not one.

```medaka
> testFileStem "expr_test.mdk"
Some "expr_test"
> testFileStem "expr.mdk"
None
```

### `testAssertionCount`

```
testAssertionCount : String -> List String -> <Exec _, IO> Result String Int
```

The executed-assertion count of `path`, from the `summary.passed` field
of `medaka test --json`, or `Err` naming what went wrong.

`extraArgs` are passed to `medaka test` before the path, so a suite that
needs the compiled engine is spawned with `["--native"]`. The count comes
from `--json` rather than the human transcript, so a change to the
transcript's shape cannot silently zero it. A suite that exits nonzero is
an `Err`, never a count, because a failed assertion is not a smaller
number of passing ones.

### `unrosteredUnits`

```
unrosteredUnits : (String -> Option String) -> List String -> List String -> List String
```

The units `namer` finds among `entries` that are absent from `known`.

The general form behind `unrosteredTestFiles`: `namer` turns one
directory entry into the unit name a roster spells, or `None` when the
entry names no unit at all, so an entry that is not a unit (an unrelated
file, a fixture directory's own helper file) is silently skipped rather
than counted as a stray one.

```medaka
> unrosteredUnits testFileStem ["a_test"] ["a_test.mdk", "b_test.mdk", "readme.md"]
["b_test"]
```

### `missingUnits`

```
missingUnits : (String -> Option String) -> List String -> List String -> List String
```

The names in `wanted` that `namer` finds in none of `entries`.

The other half of `unrosteredUnits`: a roster or exemption row naming a
unit that was renamed or deleted still reads as coverage, and only this
reports it.

```medaka
> missingUnits testFileStem ["a_test.mdk"] ["a_test", "b_test"]
["b_test"]
```

### `unrosteredTestFiles`

```
unrosteredTestFiles : String -> List String -> <FileRead _> Result String (List String)
```

The `*_test.mdk` stems in `dir` that are absent from `known`.

`known` is the caller's roster plus whatever it deliberately exempts, so
an empty result means the roster is closed over the directory and a new
test file cannot be added without either joining the roster or taking an
exemption.

### `missingTestFiles`

```
missingTestFiles : String -> List String -> <FileRead _> Result String (List String)
```

The stems in `wanted` that name no `*_test.mdk` file in `dir`.

The other half of a closed roster: a roster or exemption row naming a file
that was renamed or deleted still reads as coverage, and only this
reports it.

