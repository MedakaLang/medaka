# test_process

Assertions for a test that runs a program.

A test whose subject is a whole program (a compiler verb, a script, any
binary) spawns it and grades what came back. `expectSpawnOk`,
`expectSpawnFails` and `expectSpawnOkLine` grade a spawn. `medakaRoot`,
`underRoot` and `medakaBin` locate the tree and the binary under test.
`boundedVerb` puts a time limit on one spawn, and `scratchDir` hands out
a directory to write in.

A test that grades a directory of `medaka test` suites reads their
assertion counts with `testAssertionCount` and checks its roster against
the directory with `testFileStem`, `unrosteredTestFiles` and
`missingTestFiles`.

These assertions spawn a subprocess, which the interpreter does not
support, so a file using them runs under `medaka test --native`.

## Locating the tree

### `medakaRoot`

```
medakaRoot : <IO> String
```

The root of the Medaka tree under test: `MEDAKA_ROOT`, or `"."` when
it is unset.

Files are located through this rather than through the working
directory, which a test does not control.

### `underRoot`

```
underRoot : String -> <IO> String
```

The path `rel`, relative to the tree root, resolved under `medakaRoot`.

### `medakaBin`

```
medakaBin : <IO> String
```

The Medaka binary to spawn: `MEDAKA`, or `medaka` in `medakaRoot`
when it is unset.

The default is a path, so an unset `MEDAKA` never resolves to another
build on `PATH`.

## Spawning

### `spawnTimeoutSeconds`

```
spawnTimeoutSeconds : Int
```

The time limit `boundedVerb` puts on one spawn, in seconds.

With a limit on each spawn, a subject that hangs fails its own row
instead of the whole job.

### `boundedVerb`

```
boundedVerb : String -> List String -> <Exec _> Result String (Int, String, String)
```

Runs `cmd` with `args` as `io.runVerb` does, killing it after
`spawnTimeoutSeconds`.

A killed spawn is an ordinary nonzero exit, not an `Err`.

```medaka
> boundedVerb "sh" ["-c", "printf hi; exit 3"]
Ok (3, "hi", "")
```

### `boundedVerbSeconds`

```
boundedVerbSeconds : Int -> String -> List String -> <Exec _> Result String (Int, String, String)
```

`boundedVerb` with the time limit given as `secs`, for a spawn that
needs longer than `spawnTimeoutSeconds`.

`cmd` is looked up on `PATH` through `env`, so a command that does not
exist reports exit 127 with `env`'s message on stderr rather than a
spawn that never ran. The wording of that message varies between
systems.

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

A fresh, empty directory for a test that has to write files.

Each call returns a directory nothing else holds, so concurrent runs of
the same test do not collide. The caller owns the directory and removes
it.

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

Output is not graded. The failure message carries stdout and stderr
concatenated.

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

Both conditions are required: exit 0 fails whatever was printed, and a
nonzero exit whose output lacks `needle` fails naming what was printed.
`needle` is matched against stdout and stderr concatenated.

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
contains every string in `needles`.

The strings may occur in any order and on different lines, and are
matched against stdout and stderr concatenated. An empty `needles` list
grades the exit code alone. To require the strings on one line, grade
the captured output with `test.expectLineContainsAll`.

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

A line that merely contains `wantLine` does not match. Lines are taken
from stdout and stderr concatenated, with a trailing carriage return
removed.

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

The number of assertions `medaka test --json` reports as passed for the
suite at `path`, or `Err` naming what went wrong.

`extraArgs` are passed to `medaka test` before the path, so a suite that
needs the compiled engine is spawned with `["--native"]`. A suite that
exits nonzero is an `Err`, never a smaller count. The `Err` for a
failing run carries the tail of its output.

### `unrosteredUnits`

```
unrosteredUnits : (String -> Option String) -> List String -> List String -> List String
```

The units `namer` finds among `entries` that are absent from `known`.

`namer` turns a directory entry into the name a roster spells, or `None`
for an entry that is not a unit, which is skipped.

```medaka
> unrosteredUnits testFileStem ["a_test"] ["a_test.mdk", "b_test.mdk", "readme.md"]
["b_test"]
```

### `missingUnits`

```
missingUnits : (String -> Option String) -> List String -> List String -> List String
```

The names in `wanted` for which `namer` finds no entry in `entries`.

The complement of `unrosteredUnits`: it reports a roster row naming a
unit that is no longer present. Both functions take the roster before
the entries.

```medaka
> missingUnits testFileStem ["a_test", "b_test"] ["a_test.mdk"]
["b_test"]
```

### `unrosteredTestFiles`

```
unrosteredTestFiles : String -> List String -> <FileRead _> Result String (List String)
```

The `*_test.mdk` stems in `dir` that are absent from `known`.

`known` is the roster plus any exemptions, so an empty result means every
test file in `dir` is accounted for.

### `missingTestFiles`

```
missingTestFiles : String -> List String -> <FileRead _> Result String (List String)
```

The stems in `wanted` that name no `*_test.mdk` file in `dir`.

Reports a roster row whose file is no longer present.

## Grading a floor roster against its own `test` blocks

### `ungradedRosterRows`

```
ungradedRosterRows : String -> String -> List String -> List String -> List String
```

The names in `roster` that no `test` block in `sourceLines` both names
in its title and grades in its body.

`titlePrefix` is the path prefix the titles are spelled with, such as
`"stdlib/"`, and `callOpen` is the grading call's opening text up to the
quote of its name argument, such as `"floorExpectation \""`.
`sourceLines` is the roster module's own source, read with
`io.readLines`. A block whose title and grading call name different
units counts for neither; `disagreeingFloorBlocks` reports those. The
roster comes before the scanned lines, as in `unrosteredUnits`.

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

A block that grades nothing renders as `<titled> -> grades nothing`.
`ungradedRosterRows` reports the rows such a block leaves ungraded.

```medaka
> disagreeingFloorBlocks "s/" "grade \"" ["test \"s/a.mdk executed >= 1 assertions\" = grade \"b\""]
["a -> b"]
```

