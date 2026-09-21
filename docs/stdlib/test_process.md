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
all — which runs no verb and exits 127, an outcome an assertion phrased
over stdout alone would accept.

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

### `boundedVerbSeconds`

```
boundedVerbSeconds : Int -> String -> List String -> <Exec _> Result String (Int, String, String)
```

`boundedVerb` with the ceiling named at the call site, for a sweep whose
one spawn is genuinely slower than `spawnTimeoutSeconds` allows.

A sweep that spawns a whole compile-and-link pipeline per row needs a
ceiling sized to that pipeline, and one sized to it would be far too loose
for the sweeps that spawn a single verb, so the ceiling is a parameter
rather than one constant stretched to cover both.

`cmd` is resolved through `env` rather than execed directly, so a `cmd`
that does not exist reports `env`'s own nonzero exit and stderr instead
of `perl`'s `exec` failing silently and this returning `Ok (0, "", "")`
for a command that never ran. The example below asserts the code and that
stderr is non-empty, never the wording: that sentence is `env`'s, and it
is neither the same across implementations nor stable under `LC_ALL`.

```medaka
> boundedVerbSeconds 5 "sh" ["-c", "printf hi; exit 3"]
Ok (3, "hi", "")
> map ((c, o, e) => (c, o, e /= "")) (boundedVerbSeconds 5 "medaka-no-such-verb" [])
Ok (127, "", True)
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

### `expectSpawnFailsAll`

```
expectSpawnFailsAll : String -> List String -> List String -> <Exec _> Expectation
```

Passes when running `cmd` with `args` exits nonzero and its output
contains EVERY string in `needles`.

`expectSpawnFails` for a rejection whose diagnostic has to say more than
one thing: which rule fired, which file, and what to do instead. A single
needle grades only the part it names, so a diagnostic that keeps its
headline and drops its location still passes. The needles are matched in
any order, against stdout and stderr concatenated, and need not share a
line; `test.expectLineContainsAll` is the one that binds them
together.

An empty `needles` list grades the exit code alone, which is
`expectSpawnFails` with an empty needle.

```medaka
> expectSpawnFailsAll "sh" ["-c", "printf alpha-beta; exit 3"] ["alpha", "beta"]
Pass "nonzero exit, output containing [\"alpha\", \"beta\"]" "exit 3, output \"alpha-beta\""
> expectSpawnFailsAll "sh" ["-c", "printf alpha; exit 3"] ["alpha", "beta"]
Fail "`sh -c printf alpha; exit 3` exited 3 but its output does not contain \"beta\": \"alpha\"" "nonzero exit, output containing [\"alpha\", \"beta\"]" "exit 3, output \"alpha\""
> expectSpawnFailsAll "true" [] ["alpha"]
Fail "`true` exited 0, expected it to fail" "nonzero exit, output containing [\"alpha\"]" "exit 0, output \"\""
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
number of passing ones. A failing run's captured output is carried as its
tail (`outputTail`) rather than whole, since the message is read in a
test transcript beside dozens of others.

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

The roster is argument 2 in both, matching `unrosteredUnits`. The two
share a type, so an argument order that differed between them would make
a swapped call a silent `[]` — "no orphans", green — rather than an error.

```medaka
> missingUnits testFileStem ["a_test", "b_test"] ["a_test.mdk"]
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

## Grading a floor roster against its own `test` blocks

### `ungradedRosterRows`

```
ungradedRosterRows : String -> String -> List String -> List String -> List String
```

The names in `roster` that no block in `sourceLines` both names in its
title and grades in its body.

`titlePrefix` is the path prefix the titles are spelled with (`"stdlib/"`,
`"pds/test/"`, `"sqlite/lib/"`), and `callOpen` is the grading call's
opening text up to its name argument's quote (`"floorExpectation \""`).
`sourceLines` is the roster module's own source, read with `io.readLines`
— never a `medaka test --json` self-spawn, which would recurse into
re-spawning every unit the module already spawns.

A block whose title and argument disagree counts for neither name: the
titled row is not graded by it, and the graded row is covered by its own
block or not at all. `disagreeingFloorBlocks` is what names that case.

The roster is argument 3 and the scanned lines argument 4, matching
`unrosteredUnits`' `known`/`entries` order; the two share a type, so an
order that differed would make a swapped call a silent `[]`.

```medaka
> ungradedRosterRows "s/" "grade \"" ["a", "b"] ["test \"s/a.mdk executed >= 1 assertions\" = grade \"a\""]
["b"]
```

### `disagreeingFloorBlocks`

```
disagreeingFloorBlocks : String -> String -> List String -> List String
```

The blocks in `sourceLines` whose title and grading call name different
units, each rendered as `<titled> -> <graded>`.

The other half of `ungradedRosterRows`, which only reports a row nothing
grades: a block that grades the wrong row leaves the titled row's floor
unapplied while the row still reads as covered, and only this names it.

```medaka
> disagreeingFloorBlocks "s/" "grade \"" ["test \"s/a.mdk executed >= 1 assertions\" = grade \"b\""]
["a -> b"]
```

